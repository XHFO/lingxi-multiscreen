import CryptoKit
import Foundation

/// 多屏灵犀内置的 AI Mac 小屏幕固件信息。
public enum EmbeddedAIMacFirmware {
    public static let version = "0.7.0-lossless-rgb565"
    public static let fileName = "aimac-screen-0.7.0.bin"
    public static let helperName = "lingxi-esptool"
    public static let sha256 = "0283b882808bd55cb31210e32659fb1d0dc901cfdf49fc9d717bf777999a3831"
    public static let flashAddress = "0x0"

    public static func validate(_ data: Data) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }
}

public struct ESPSerialPort: Identifiable, Equatable, Hashable {
    public let path: String
    public var id: String { path }

    public var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    public init(path: String) { self.path = path }
}

public enum ESP8266FlashError: Error, LocalizedError {
    case noPort
    case invalidPort
    case missingResource(String)
    case invalidFirmware
    case helperLaunch(String)
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noPort: return "请选择通过 USB 连接的小屏幕串口。"
        case .invalidPort: return "所选串口已经断开，请重新连接设备并刷新列表。"
        case .missingResource(let name): return "应用内置资源缺失：\(name)。"
        case .invalidFirmware: return "内置固件完整性校验失败，已停止刷写。"
        case .helperLaunch(let detail): return "无法启动内置刷机助手：\(detail)"
        case .cancelled: return "刷写已取消；请重新刷入完整固件后再使用设备。"
        case .failed(let detail): return detail.isEmpty ? "固件刷写失败。" : "固件刷写失败：\(detail)"
        }
    }
}

/// 独立进程执行 Espressif ROM 刷写协议。主应用只接收日志与进度，避免串口阻塞 UI。
public final class ESP8266FirmwareFlasher {
    private let processLock = NSLock()
    private var runningProcess: Process?

    public init() {}

    private func setRunningProcess(_ process: Process?) {
        processLock.lock()
        runningProcess = process
        processLock.unlock()
    }

    private func clearRunningProcess(if process: Process) {
        processLock.lock()
        if runningProcess === process { runningProcess = nil }
        processLock.unlock()
    }

    public static func serialPorts(in deviceNames: [String]) -> [ESPSerialPort] {
        let supportedPrefixes = [
            "cu.usbserial", "cu.wchusbserial", "cu.SLAB_USBtoUART",
            "cu.usbmodem", "cu.CH34", "cu.cp210"
        ]
        return deviceNames
            .filter { name in supportedPrefixes.contains(where: { name.hasPrefix($0) }) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ESPSerialPort(path: "/dev/\($0)") }
    }

    public static func discoverSerialPorts() -> [ESPSerialPort] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return serialPorts(in: names)
    }

    public func cancel() {
        processLock.lock()
        let process = runningProcess
        processLock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    public func flash(
        port: ESPSerialPort,
        helperURL: URL,
        firmwareURL: URL,
        progress: @escaping @Sendable (Double) -> Void,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        guard FileManager.default.fileExists(atPath: port.path) else {
            throw ESP8266FlashError.invalidPort
        }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw ESP8266FlashError.missingResource(EmbeddedAIMacFirmware.helperName)
        }
        guard let firmware = try? Data(contentsOf: firmwareURL),
              EmbeddedAIMacFirmware.validate(firmware) else {
            throw ESP8266FlashError.invalidFirmware
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = helperURL
        process.arguments = [
            "--chip", "esp8266",
            "--port", port.path,
            "--baud", "115200",
            "--before", "default_reset",
            "--after", "hard_reset",
            "write_flash",
            "--flash_mode", "dio",
            "--flash_freq", "40m",
            "--flash_size", "detect",
            EmbeddedAIMacFirmware.flashAddress,
            firmwareURL.path
        ]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        setRunningProcess(process)
        defer { clearRunningProcess(if: process) }

        final class OutputState: @unchecked Sendable {
            let lock = NSLock()
            var text = ""
        }
        let state = OutputState()

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                state.lock.lock()
                state.text += chunk
                state.lock.unlock()
                log(chunk)
                if let percent = Self.latestPercent(in: chunk) {
                    progress(Double(percent) / 100.0)
                }
            }
            process.terminationHandler = { finished in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                let tail = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if let tailText = String(data: tail, encoding: .utf8), !tailText.isEmpty {
                    state.lock.lock()
                    state.text += tailText
                    state.lock.unlock()
                    log(tailText)
                }
                state.lock.lock()
                let fullOutput = state.text
                state.lock.unlock()
                if finished.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: ESP8266FlashError.cancelled)
                } else if finished.terminationStatus == 0 {
                    progress(1)
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ESP8266FlashError.failed(
                        Self.conciseFailure(from: fullOutput)))
                }
            }
            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: ESP8266FlashError.helperLaunch(
                    error.localizedDescription))
            }
        }
    }

    private static func latestPercent(in text: String) -> Int? {
        let pattern = #"\(([0-9]{1,3})\s*%\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
        return min(max(Int(text[swiftRange]) ?? 0, 0), 100)
    }

    private static func conciseFailure(from output: String) -> String {
        output.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(4)
            .joined(separator: " ")
    }
}
