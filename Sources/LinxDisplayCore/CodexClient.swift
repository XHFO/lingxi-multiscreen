import Foundation

public enum CodexError: Error, LocalizedError {
    case notFound
    case connectionClosed
    case startFailed(String)
    case serverError(String)
    case unexpectedData
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "未找到 Codex CLI。请在设置中填写终端执行 which codex 返回的完整路径（例如 /opt/homebrew/bin/codex）。"
        case .connectionClosed:
            return "Codex 数据连接意外关闭。"
        case .startFailed(let message):
            return "Codex 启动失败：\(message)。请检查应用中的“Codex CLI”路径或 CODEX_CLI_PATH。"
        case .serverError(let message):
            return "Codex 返回错误：\(message)"
        case .unexpectedData:
            return "Codex 返回了无法识别的用量数据。"
        case .timeout:
            return "读取 Codex 用量超时。"
        }
    }
}

/// 依次检查应用设置、CODEX_CLI_PATH、PATH 与常见安装位置（Homebrew / npm / nvm / fnm / Volta / asdf / mise / pnpm）。
public enum CodexCliLocator {
    public static func resolve(configured: String? = nil) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []

        func addConfigured(_ value: String?) {
            guard let value = value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            var path = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if path == "~" {
                path = home
            } else if path.hasPrefix("~/") {
                path = home + path.dropFirst(1)
            }
            candidates.append(path)
        }

        addConfigured(configured)
        addConfigured(ProcessInfo.processInfo.environment["CODEX_CLI_PATH"])

        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathEnv.split(separator: ":").map({ String($0) }) {
            candidates.append((directory as NSString).appendingPathComponent("codex"))
        }

        candidates += [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home + "/.local/bin/codex",
            home + "/.npm-global/bin/codex",
            home + "/.volta/bin/codex",
            home + "/.asdf/shims/codex",
            home + "/.local/share/mise/shims/codex",
            home + "/.local/share/pnpm/codex",
            home + "/Library/pnpm/codex"
        ]

        // nvm 版本目录
        let nvmRoot = home + "/.nvm/versions/node"
        if FileManager.default.fileExists(atPath: nvmRoot) {
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvmRoot))?
                .sorted { left, right in
                    let l = fileModification(nvmRoot + "/" + left)
                    let r = fileModification(nvmRoot + "/" + right)
                    return l > r
                } ?? []
            for version in versions {
                candidates.append((nvmRoot as NSString).appendingPathComponent(version + "/bin/codex"))
            }
        }

        // fnm 版本目录
        for fnmRoot in [home + "/.local/share/fnm/node-versions",
                        home + "/Library/Application Support/fnm/node-versions"] {
            if FileManager.default.fileExists(atPath: fnmRoot) {
                let versions = (try? FileManager.default.contentsOfDirectory(atPath: fnmRoot))?
                    .sorted { left, right in
                        let l = fileModification(fnmRoot + "/" + left)
                        let r = fileModification(fnmRoot + "/" + right)
                        return l > r
                    } ?? []
                for version in versions {
                    candidates.append((fnmRoot as NSString).appendingPathComponent(version + "/installation/bin/codex"))
                }
            }
        }

        var seen = Set<String>()
        for candidate in candidates where !candidate.isEmpty {
            guard !seen.contains(candidate) else { continue }
            seen.insert(candidate)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw CodexError.notFound
    }

    private static func fileModification(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }
}

/// 通过 Codex CLI 的 app-server --stdio JSON-RPC 协议读取账号用量。
public final class CodexRateLimitClient {

    public init() {}

    public func fetch(executable: String? = nil, timeout: TimeInterval = 12) async throws -> UsageSnapshot {
        let resolved = try CodexCliLocator.resolve(configured: executable)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = ["app-server", "--stdio"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var errorText = ""
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                errorPipe.fileHandleForReading.readabilityHandler = nil
            } else if let text = String(data: data, encoding: .utf8) {
                errorText += text
            }
        }

        let lineSource = LineSource()
        let lines = AsyncStream<String> { continuation in
            lineSource.continuation = continuation
        }
        var buffer = Data()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                lineSource.finish()
                outputPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let line = String(data: lineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !line.isEmpty {
                        lineSource.yield(line)
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw CodexError.startFailed(error.localizedDescription)
        }

        let task = Task { try await runProtocol(process: process, inputPipe: inputPipe,
                                                lines: lines, errorText: { errorText }) }
        let result: UsageSnapshot
        do {
            result = try await withThrowingTaskGroup(of: UsageSnapshot.self) { group in
                group.addTask { try await task.value }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw CodexError.timeout
                }
                let first = try await group.next()
                group.cancelAll()
                guard let value = first else { throw CodexError.connectionClosed }
                return value
            }
        } catch {
            cleanup(process: process, inputPipe: inputPipe, lineSource: lineSource,
                    outputHandle: outputPipe.fileHandleForReading)
            throw error
        }
        cleanup(process: process, inputPipe: inputPipe, lineSource: lineSource,
                outputHandle: outputPipe.fileHandleForReading)
        return result
    }

    // MARK: - JSON-RPC 协议

    private func runProtocol(process: Process, inputPipe: Pipe, lines: AsyncStream<String>,
                             errorText: @escaping () -> String) async throws -> UsageSnapshot {
        var iterator = lines.makeAsyncIterator()
        let writer = inputPipe.fileHandleForWriting

        func send(_ message: [String: Any]) throws {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else {
                throw CodexError.startFailed("JSON 序列化失败")
            }
            var line = data
            line.append(0x0A)
            try writer.write(contentsOf: line)
        }

        // initialize
        try send([
            "method": "initialize",
            "id": 0,
            "params": [
                "clientInfo": [
                    "name": "codex_linx_display",
                    "title": "LinxDisplay",
                    "version": "0.1.0"
                ],
                "capabilities": ["experimentalApi": true]
            ]
        ])

        // 等待 initialize 响应
        var didRequestRateLimits = false
        while let line = try await iterator.next() {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = root["id"] as? Int else { continue }

            if id == 0 && !didRequestRateLimits {
                try throwIfServerError(root)
                didRequestRateLimits = true
                try send(["method": "initialized", "params": [:]])
                try send(["method": "account/rateLimits/read", "id": 1, "params": NSNull()])
                continue
            }

            if id == 1 {
                try throwIfServerError(root)
                guard let result = root["result"] as? [String: Any] else {
                    throw CodexError.unexpectedData
                }
                return try Self.parseRateLimitResult(result)
            }
        }

        let error = errorText()
        if error.isEmpty {
            throw CodexError.connectionClosed
        } else {
            throw CodexError.startFailed(error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func throwIfServerError(_ root: [String: Any]) throws {
        guard let error = root["error"] as? [String: Any] else { return }
        let message = error["message"] as? String ?? "未知错误"
        throw CodexError.serverError(message)
    }

    // MARK: - 解析

    /// 解析 account/rateLimits/read 的 result，逻辑与原版完全一致。
    public static func parseRateLimitResult(_ result: [String: Any]) throws -> UsageSnapshot {
        var limits: [String: Any]? = nil
        if let byId = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = byId["codex"] as? [String: Any] {
            limits = codex
        } else if let rateLimits = result["rateLimits"] as? [String: Any] {
            limits = rateLimits
        }
        guard let limits else { throw CodexError.unexpectedData }

        var windows: [[String: Any]] = []
        if let primary = limits["primary"] as? [String: Any] { windows.append(primary) }
        if let secondary = limits["secondary"] as? [String: Any] { windows.append(secondary) }
        guard !windows.isEmpty else { throw CodexError.unexpectedData }

        func windowMinutes(_ window: [String: Any]) -> Int {
            if let value = window["windowDurationMins"] as? Int { return value }
            if let value = window["windowDurationMins"] as? Double { return Int(value) }
            if let value = window["windowDurationMins"] as? NSNumber { return value.intValue }
            return 0
        }
        let selected = windows.max { windowMinutes($0) < windowMinutes($1) } ?? windows[0]

        let usedPercent: Int
        if let value = selected["usedPercent"] as? Double {
            usedPercent = Int(value.rounded())
        } else if let value = selected["usedPercent"] as? Int {
            usedPercent = value
        } else if let value = selected["usedPercent"] as? NSNumber {
            usedPercent = value.intValue
        } else {
            throw CodexError.unexpectedData
        }
        let minutes = windowMinutes(selected)
        var resetDate: Date? = nil
        if let seconds = selected["resetsAt"] as? Int64 {
            resetDate = Date(timeIntervalSince1970: TimeInterval(seconds))
        } else if let seconds = selected["resetsAt"] as? Double {
            resetDate = Date(timeIntervalSince1970: seconds)
        } else if let seconds = selected["resetsAt"] as? NSNumber {
            resetDate = Date(timeIntervalSince1970: seconds.doubleValue)
        }

        var resetCount = 0
        if let credits = result["rateLimitResetCredits"] as? [String: Any],
           let available = credits["availableCount"] as? Int {
            resetCount = max(0, available)
        }

        let planType = limits["planType"] as? String
        return UsageSnapshot(
            remainingPercent: min(max(100 - usedPercent, 0), 100),
            resetDate: resetDate,
            windowMinutes: minutes == 0 ? nil : minutes,
            availableResetCount: resetCount,
            planType: planType,
            sourceName: "Codex 官方",
            sampledAt: Date()
        )
    }

    private func cleanup(process: Process, inputPipe: Pipe, lineSource: LineSource,
                         outputHandle: FileHandle) {
        inputPipe.fileHandleForWriting.closeFile()
        lineSource.finish()
        if process.isRunning {
            process.terminate()
            DispatchQueue.global().async {
                process.waitUntilExit()
            }
        }
    }
}

/// 把 FileHandle 的字节流按行拆分，通过 AsyncStream 输出。
private final class LineSource {
    var continuation: AsyncStream<String>.Continuation?

    func yield(_ line: String) {
        continuation?.yield(line)
    }

    func finish() {
        continuation?.finish()
    }
}
