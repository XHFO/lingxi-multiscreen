import Foundation
import JavaScriptCore
#if canImport(Darwin)
import Darwin
#endif

/// Codex 额度来源。默认继续使用 Codex CLI；选择 CC Switch 后会只读跟随
/// `~/.cc-switch/cc-switch.db` 中当前启用的 Codex 供应商。
public enum CodexUsageSource: String, Codable, CaseIterable, Identifiable {
    case codexCLI
    case ccSwitch

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codexCLI: return "Codex 官方"
        case .ccSwitch: return "CC Switch"
        }
    }
}

public enum CCSwitchQuotaError: Error, LocalizedError {
    case notInstalled
    case databaseReadFailed
    case noCurrentProvider
    case usageDisabled(String)
    case invalidConfiguration
    case unsafeEndpoint
    case requestFailed
    case invalidResponse
    case scriptFailed

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "未找到 CC Switch 数据库，请先安装并运行 CC Switch。"
        case .databaseReadFailed:
            return "无法读取 CC Switch 的本地数据。"
        case .noCurrentProvider:
            return "CC Switch 尚未选择 Codex 供应商。"
        case .usageDisabled(let name):
            return "CC Switch 当前供应商“\(name)”尚未启用用量查询。"
        case .invalidConfiguration:
            return "CC Switch 当前供应商的额度查询配置不完整。"
        case .unsafeEndpoint:
            return "CC Switch 额度查询地址必须使用 HTTPS（本机地址除外）。"
        case .requestFailed:
            return "无法连接 CC Switch 当前供应商的额度服务。"
        case .invalidResponse:
            return "CC Switch 当前供应商返回了无法识别的额度数据。"
        case .scriptFailed:
            return "无法执行 CC Switch 当前供应商的额度解析规则。"
        }
    }
}

/// CC Switch 当前供应商额度读取器。
///
/// 数据库始终以只读方式打开；每次刷新重新读取 current provider，因此用户在
/// CC Switch 中切换供应商后，下次刷新会自然跟随。凭据只在本次请求的内存中使用，
/// 不会写入多屏灵犀设置或日志。
public final class CCSwitchQuotaClient {
    private final class WorkerOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data) {
            lock.lock()
            if storage.count < CCSwitchQuotaClient.maximumResponseBytes {
                storage.append(data.prefix(CCSwitchQuotaClient.maximumResponseBytes - storage.count))
            }
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cc-switch/cc-switch.db")
    }

    public init() {}

    public func fetch(databaseURL: URL = CCSwitchQuotaClient.defaultDatabaseURL) async throws
        -> UsageSnapshot {
        // 数据库读取和 JavaScript 解析都会启动短生命周期子进程；放到后台执行，
        // 防止设置页刷新或自动推送时阻塞 SwiftUI 主线程。
        let prepared = try await Task.detached(priority: .utility) {
            let provider = try Self.readCurrentProvider(databaseURL: databaseURL)
            guard let script = provider.usageScript, script.enabled else {
                throw CCSwitchQuotaError.usageDisabled(provider.name)
            }
            let credentials = Self.resolveCredentials(settings: provider.settings,
                                                       script: script)
            let code = Self.substituteVariables(
                in: script.code,
                apiKey: credentials.apiKey,
                baseURL: credentials.baseURL,
                accessToken: script.accessToken ?? "",
                userID: script.userID ?? "")
            return PreparedFetch(providerName: provider.name, code: code,
                                 requestTimeout: script.timeout ?? 10,
                                 plan: try Self.evaluatePlan(script: code))
        }.value
        guard let url = URL(string: prepared.plan.url), Self.isAllowedEndpoint(url) else {
            throw CCSwitchQuotaError.unsafeEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = prepared.plan.method
        request.timeoutInterval = TimeInterval(min(max(prepared.requestTimeout, 2), 30))
        for (key, value) in prepared.plan.headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body = prepared.plan.body { request.httpBody = Data(body.utf8) }

        let data: Data
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw CCSwitchQuotaError.requestFailed
            }
            data = responseData
        } catch let error as CCSwitchQuotaError {
            throw error
        } catch {
            throw CCSwitchQuotaError.requestFailed
        }

        guard data.count <= Self.maximumResponseBytes else {
            throw CCSwitchQuotaError.invalidResponse
        }
        let items = try await Task.detached(priority: .utility) {
            guard let responseObject = try? JSONSerialization.jsonObject(with: data) else {
                throw CCSwitchQuotaError.invalidResponse
            }
            return try Self.extractUsageItems(script: prepared.code,
                                              responseObject: responseObject)
        }.value
        return try Self.makeSnapshot(items: items, providerName: prepared.providerName)
    }

    // MARK: - CC Switch database

    private struct ProviderRow: Decodable {
        let name: String
        let settings_config: String
        let meta: String
    }

    private struct ProviderRecord {
        let name: String
        let settings: [String: Any]
        let usageScript: UsageScript?
    }

    private struct PreparedFetch {
        let providerName: String
        let code: String
        let requestTimeout: Int
        let plan: RequestPlan
    }

    private struct ProviderMeta: Decodable {
        let usage_script: UsageScript?
    }

    private struct UsageScript: Decodable {
        let enabled: Bool
        let code: String
        let timeout: Int?
        let apiKey: String?
        let baseURL: String?
        let accessToken: String?
        let userID: String?

        private enum CodingKeys: String, CodingKey {
            case enabled, code, timeout, apiKey, accessToken
            case baseURL = "baseUrl"
            case userID = "userId"
        }
    }

    private static func readCurrentProvider(databaseURL: URL) throws -> ProviderRecord {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CCSwitchQuotaError.notInstalled
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly", "-json", databaseURL.path,
            "SELECT name, settings_config, meta FROM providers "
                + "WHERE app_type='codex' AND is_current=1 LIMIT 1;"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  data.count <= maximumResponseBytes,
                  let rows = try? JSONDecoder().decode([ProviderRow].self, from: data) else {
                throw CCSwitchQuotaError.databaseReadFailed
            }
            guard let row = rows.first else { throw CCSwitchQuotaError.noCurrentProvider }
            guard let settingsData = row.settings_config.data(using: .utf8),
                  let settings = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any]
            else { throw CCSwitchQuotaError.invalidConfiguration }
            let meta = row.meta.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode(ProviderMeta.self, from: $0) }
            return ProviderRecord(name: row.name, settings: settings, usageScript: meta?.usage_script)
        } catch {
            if let known = error as? CCSwitchQuotaError { throw known }
            throw CCSwitchQuotaError.databaseReadFailed
        }
    }

    // MARK: - Provider credentials and script plan

    private static func resolveCredentials(settings: [String: Any], script: UsageScript)
        -> (baseURL: String, apiKey: String) {
        let config = settings["config"] as? String ?? ""
        let auth = settings["auth"] as? [String: Any]
        let storedKey = auth?["OPENAI_API_KEY"] as? String
            ?? tomlValue(named: "experimental_bearer_token", in: config)
            ?? ""
        let base = script.baseURL?.nonEmpty
            ?? activeCodexBaseURL(in: config)
            ?? ""
        return (base.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "/+$", with: "", options: .regularExpression),
                script.apiKey?.nonEmpty ?? storedKey)
    }

    /// 仅解析 CC Switch 生成的 Codex TOML 中当前 model provider 的地址；不会读取
    /// 非当前 provider 残留的 base_url，避免额度请求串到错误供应商。
    public static func activeCodexBaseURL(in text: String) -> String? {
        let active = topLevelTomlValue(named: "model_provider", in: text)
        var currentSection = ""
        var topLevelBase: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                continue
            }
            guard let value = assignmentValue(named: "base_url", in: line) else { continue }
            if currentSection.isEmpty { topLevelBase = value }
            if let active, currentSection == "model_providers.\(active)" { return value }
        }
        return topLevelBase
    }

    private static func topLevelTomlValue(named key: String, in text: String) -> String? {
        var inSection = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = true }
            if !inSection, let value = assignmentValue(named: key, in: line) { return value }
        }
        return nil
    }

    private static func tomlValue(named key: String, in text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            if let value = assignmentValue(named: key,
                                           in: rawLine.trimmingCharacters(in: .whitespaces)) {
                return value
            }
        }
        return nil
    }

    private static func assignmentValue(named key: String, in line: String) -> String? {
        guard !line.hasPrefix("#"), let equal = line.firstIndex(of: "=") else { return nil }
        let lhs = line[..<equal].trimmingCharacters(in: .whitespaces)
        guard lhs == key else { return nil }
        var value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
        if let comment = value.firstIndex(of: "#") { value = value[..<comment].trimmingCharacters(in: .whitespaces) }
        guard value.count >= 2 else { return nil }
        if (value.first == "\"" && value.last == "\"")
            || (value.first == "'" && value.last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        return value.nonEmpty
    }

    public static func substituteVariables(in script: String, apiKey: String, baseURL: String,
                                           accessToken: String, userID: String) -> String {
        script.replacingOccurrences(of: "{{apiKey}}", with: apiKey)
            .replacingOccurrences(of: "{{baseUrl}}", with: baseURL)
            .replacingOccurrences(of: "{{accessToken}}", with: accessToken)
            .replacingOccurrences(of: "{{userId}}", with: userID)
    }

    private struct RequestPlan: Codable {
        let url: String
        let method: String
        let headers: [String: String]
        let body: String?
    }

    private static func evaluatePlan(script: String) throws -> RequestPlan {
        let result = try runScriptWorker(mode: .request, script: script, responseObject: nil)
        guard let plan = result.plan else { throw CCSwitchQuotaError.scriptFailed }
        return plan
    }

    /// 提供给设置校验和冒烟测试的安全入口。规则始终在独立进程中执行，超时后会被
    /// 强制结束，不会让主程序的刷新线程持续占用 CPU。
    public static func validateUsageScript(_ script: String,
                                           timeout: TimeInterval = 5) throws {
        _ = try runScriptWorker(mode: .request, script: script,
                                responseObject: nil, timeout: timeout)
    }

    private static func evaluatePlanInWorker(script: String) throws -> RequestPlan {
        let context = JSContext()!
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        guard let config = context.evaluateScript(script), exception == nil,
              let request = config.forProperty("request"), !request.isUndefined,
              let url = request.forProperty("url")?.toString(), !url.isEmpty else {
            throw CCSwitchQuotaError.scriptFailed
        }
        let method = request.forProperty("method")?.toString()?.uppercased() ?? "GET"
        guard ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method) else {
            throw CCSwitchQuotaError.invalidConfiguration
        }
        var headers: [String: String] = [:]
        if let raw = request.forProperty("headers")?.toDictionary() {
            for (key, value) in raw { headers[String(describing: key)] = String(describing: value) }
        }
        let bodyValue = request.forProperty("body")
        let body = bodyValue == nil || bodyValue!.isUndefined || bodyValue!.isNull
            ? nil : bodyValue!.toString()
        return RequestPlan(url: url, method: method, headers: headers, body: body)
    }

    // MARK: - Script response and UsageSnapshot

    public struct UsageItem: Equatable, Codable {
        public var planName: String?
        public var extra: String?
        public var isValid: Bool?
        public var invalidMessage: String?
        public var total: Double?
        public var used: Double?
        public var remaining: Double?
        public var unit: String?

        public init(planName: String? = nil, extra: String? = nil,
                    isValid: Bool? = nil, invalidMessage: String? = nil,
                    total: Double? = nil, used: Double? = nil,
                    remaining: Double? = nil, unit: String? = nil) {
            self.planName = planName
            self.extra = extra
            self.isValid = isValid
            self.invalidMessage = invalidMessage
            self.total = total
            self.used = used
            self.remaining = remaining
            self.unit = unit
        }
    }

    private static func extractUsageItems(script: String, responseObject: Any) throws -> [UsageItem] {
        let result = try runScriptWorker(mode: .response, script: script,
                                         responseObject: responseObject)
        guard let items = result.items, !items.isEmpty else {
            throw CCSwitchQuotaError.invalidResponse
        }
        return items
    }

    private static func extractUsageItemsInWorker(script: String,
                                                  responseObject: Any) throws -> [UsageItem] {
        let context = JSContext()!
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        guard let config = context.evaluateScript(script), exception == nil,
              let extractor = config.forProperty("extractor"), !extractor.isUndefined,
              let result = extractor.call(withArguments: [responseObject]), exception == nil else {
            throw CCSwitchQuotaError.scriptFailed
        }
        let rawItems: [Any]
        if result.isArray { rawItems = result.toArray() ?? [] }
        else if let dictionary = result.toDictionary() { rawItems = [dictionary] }
        else { throw CCSwitchQuotaError.invalidResponse }
        let items = rawItems.compactMap { raw -> UsageItem? in
            guard let item = raw as? [AnyHashable: Any] else { return nil }
            func number(_ key: String) -> Double? {
                if let value = item[key] as? NSNumber { return value.doubleValue }
                return nil
            }
            return UsageItem(
                planName: item["planName"] as? String,
                extra: item["extra"] as? String,
                isValid: item["isValid"] as? Bool,
                invalidMessage: item["invalidMessage"] as? String,
                total: number("total"), used: number("used"),
                remaining: number("remaining"), unit: item["unit"] as? String)
        }
        guard !items.isEmpty else { throw CCSwitchQuotaError.invalidResponse }
        return items
    }

    // MARK: - Isolated JavaScript worker

    private enum WorkerMode: String, Codable {
        case request
        case response
    }

    private struct WorkerInput: Codable {
        let mode: WorkerMode
        let script: String
        let responseJSON: Data?
    }

    private struct WorkerOutput: Codable {
        var plan: RequestPlan?
        var items: [UsageItem]?
        var error: String?
    }

    private static let workerArgument = "--cc-switch-script-worker"
    private static let maximumScriptBytes = 1_048_576
    private static let maximumResponseBytes = 16_777_216

    private static func runScriptWorker(mode: WorkerMode, script: String,
                                        responseObject: Any?, timeout: TimeInterval = 5) throws
        -> WorkerOutput {
        guard script.utf8.count <= maximumScriptBytes else {
            throw CCSwitchQuotaError.invalidConfiguration
        }
        let responseJSON: Data?
        if let responseObject {
            guard JSONSerialization.isValidJSONObject(responseObject),
                  let encoded = try? JSONSerialization.data(withJSONObject: responseObject),
                  encoded.count <= maximumResponseBytes else {
                throw CCSwitchQuotaError.invalidResponse
            }
            responseJSON = encoded
        } else {
            responseJSON = nil
        }
        let input = WorkerInput(mode: mode, script: script, responseJSON: responseJSON)
        guard let payload = try? JSONEncoder().encode(input),
              let executable = Bundle.main.executableURL else {
            throw CCSwitchQuotaError.scriptFailed
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = [workerArgument]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        let outputBuffer = WorkerOutputBuffer()
        let outputFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            outputBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            outputFinished.signal()
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            stdinPipe.fileHandleForWriting.write(payload)
            try? stdinPipe.fileHandleForWriting.close()
        } catch {
            throw CCSwitchQuotaError.scriptFailed
        }

        let wait = finished.wait(timeout: .now() + min(max(timeout, 0.1), 10))
        if wait == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut {
                #if canImport(Darwin)
                kill(process.processIdentifier, SIGKILL)
                #endif
                _ = finished.wait(timeout: .now() + 0.25)
            }
            throw CCSwitchQuotaError.scriptFailed
        }
        guard process.terminationStatus == 0 else {
            throw CCSwitchQuotaError.scriptFailed
        }
        guard outputFinished.wait(timeout: .now() + 1) == .success else {
            throw CCSwitchQuotaError.scriptFailed
        }
        let data = outputBuffer.data
        guard data.count <= maximumResponseBytes,
              let output = try? JSONDecoder().decode(WorkerOutput.self, from: data),
              output.error == nil else {
            throw CCSwitchQuotaError.scriptFailed
        }
        return output
    }

    /// 必须在 App / 测试程序真正启动前调用。返回 true 表示当前进程是额度脚本工作进程，
    /// 调用方应立即退出，避免创建窗口、菜单栏或启动测试。
    public static func runScriptWorkerIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().first == workerArgument else { return false }
        let inputData = FileHandle.standardInput.readDataToEndOfFile()
        let output: WorkerOutput
        do {
            guard inputData.count <= maximumResponseBytes,
                  let input = try? JSONDecoder().decode(WorkerInput.self, from: inputData) else {
                throw CCSwitchQuotaError.invalidConfiguration
            }
            switch input.mode {
            case .request:
                output = WorkerOutput(plan: try evaluatePlanInWorker(script: input.script),
                                      items: nil, error: nil)
            case .response:
                guard let data = input.responseJSON,
                      data.count <= maximumResponseBytes,
                      let object = try? JSONSerialization.jsonObject(with: data) else {
                    throw CCSwitchQuotaError.invalidResponse
                }
                output = WorkerOutput(
                    plan: nil,
                    items: try extractUsageItemsInWorker(script: input.script,
                                                         responseObject: object),
                    error: nil)
            }
        } catch {
            output = WorkerOutput(plan: nil, items: nil, error: "script_failed")
        }
        if let data = try? JSONEncoder().encode(output) {
            FileHandle.standardOutput.write(data)
        }
        return true
    }

    public static func makeSnapshot(items: [UsageItem], providerName: String,
                                    now: Date = Date()) throws -> UsageSnapshot {
        let valid = items.filter { $0.isValid != false }
        guard !valid.isEmpty else { throw CCSwitchQuotaError.invalidResponse }
        // 多周期额度优先采用最长周期（周/月）；未知周期保持 CC Switch 原顺序。
        let selected = valid.max { inferredWindowMinutes($0.planName) < inferredWindowMinutes($1.planName) }
            ?? valid[0]
        let total = selected.total
        let remaining = selected.remaining
            ?? (total.flatMap { total in selected.used.map { max(total - $0, 0) } })
        let percent: Int
        if let total, total > 0, let remaining {
            percent = Int(min(max(remaining / total * 100, 0), 100).rounded())
        } else if selected.unit == "%", let remaining {
            percent = Int(min(max(remaining, 0), 100).rounded())
        } else {
            throw CCSwitchQuotaError.invalidResponse
        }
        return UsageSnapshot(
            remainingPercent: percent,
            resetDate: parseResetDate(selected.extra),
            windowMinutes: inferredWindowMinutes(selected.planName).nonZero,
            availableResetCount: 0,
            planType: selected.planName?.nonEmpty ?? providerName,
            sourceName: "CC Switch · \(providerName)",
            remainingValue: remaining,
            usageUnit: selected.unit,
            sampledAt: now)
    }

    private static func inferredWindowMinutes(_ name: String?) -> Int {
        let value = name?.lowercased() ?? ""
        if value.contains("month") || value.contains("月") || value.contains("30 day") { return 43_200 }
        if value.contains("week") || value.contains("周") || value.contains("7 day") { return 10_080 }
        if value.contains("day") || value.contains("日") || value.contains("24 hour") { return 1_440 }
        if value.contains("5 hour") || value.contains("5-hour") || value.contains("5 小时") { return 300 }
        return 0
    }

    private static func parseResetDate(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { return nil }
        let candidates = [value, value.replacingOccurrences(of: "Reset:", with: "")
            .trimmingCharacters(in: .whitespaces)]
        let iso = ISO8601DateFormatter()
        for candidate in candidates {
            if let date = iso.date(from: candidate) { return date }
        }
        return nil
    }

    private static func isAllowedEndpoint(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
