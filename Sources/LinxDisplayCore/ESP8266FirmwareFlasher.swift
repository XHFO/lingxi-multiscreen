import CryptoKit
import Foundation

/// 多屏灵犀内置的 AI Mac 小屏幕固件信息。
public enum EmbeddedAIMacFirmware {
    public static let version = "0.8.1-wifi-portal-fix"
    public static let fileName = "aimac-screen-0.8.1.bin"
    public static let helperName = "lingxi-esptool"
    public static let sha256 = "411ef4b0799939bad09887a78a594e0727c9d06b170b58f530cfaedfa7bf2c35"
    public static let flashAddress = "0x0"

    public static func validate(_ data: Data) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }
}

public enum AIMacWiFiProvisioningError: Error, LocalizedError, Equatable {
    case emptySSID
    case ssidTooLong
    case invalidPasswordLength

    public var errorDescription: String? {
        switch self {
        case .emptySSID: return "请输入要连接的 Wi-Fi 名称（SSID）。"
        case .ssidTooLong: return "Wi-Fi 名称不能超过 32 个 UTF-8 字节。"
        case .invalidPasswordLength:
            return "Wi-Fi 密码应留空（开放网络），或为 8–64 个 UTF-8 字节。"
        }
    }
}

/// 由应用在刷写时临时生成的 4KB 配网区。固件连接成功后会擦除这个区域；
/// 应用也会在刷机助手退出后立即删除 Mac 上的临时文件。
public enum AIMacWiFiProvisioning {
    public static let flashAddress = "0x100000"
    public static let sectorBytes = 4096
    public static let recordBytes = 116
    private static let magic = Data("LXWIFI01".utf8)

    public static func validateCredentials(ssid: String, password: String) throws {
        let ssidBytes = Data(ssid.utf8)
        let passwordBytes = Data(password.utf8)
        guard !ssidBytes.isEmpty else { throw AIMacWiFiProvisioningError.emptySSID }
        guard ssidBytes.count <= 32 else { throw AIMacWiFiProvisioningError.ssidTooLong }
        guard passwordBytes.isEmpty || (8...64).contains(passwordBytes.count) else {
            throw AIMacWiFiProvisioningError.invalidPasswordLength
        }
    }

    public static func makeImage(ssid: String, password: String) throws -> Data {
        try validateCredentials(ssid: ssid, password: password)
        let ssidBytes = Data(ssid.utf8)
        let passwordBytes = Data(password.utf8)
        var record = Data()
        record.append(magic)
        record.append(1) // format version
        record.append(UInt8(ssidBytes.count))
        record.append(UInt8(passwordBytes.count))
        record.append(0) // flags
        record.append(fixedField(ssidBytes, count: 33))
        record.append(fixedField(passwordBytes, count: 65))
        record.append(contentsOf: [0, 0])
        appendLittleEndian(crc32(record), to: &record)
        precondition(record.count == recordBytes)

        var image = record
        image.append(Data(repeating: 0xFF, count: sectorBytes - image.count))
        return image
    }

    public static func validateImage(_ image: Data) -> Bool {
        guard image.count == sectorBytes,
              image.prefix(magic.count) == magic,
              image[8] == 1,
              image[9] > 0, image[9] <= 32,
              image[10] <= 64 else { return false }
        let storedOffset = recordBytes - 4
        let stored = UInt32(image[storedOffset])
            | (UInt32(image[storedOffset + 1]) << 8)
            | (UInt32(image[storedOffset + 2]) << 16)
            | (UInt32(image[storedOffset + 3]) << 24)
        return stored == crc32(image.prefix(storedOffset))
    }

    /// esptool 的写入日志包含芯片 MAC；后 3 字节与 ESP.getChipId() 一致，
    /// 因而可提前推导固件启动后的唯一 mDNS 主机名。
    public static func macAddress(in log: String) -> String? {
        let pattern = #"(?i)\bMAC:\s*([0-9a-f]{2}(?::[0-9a-f]{2}){5})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: log,
                                           range: NSRange(log.startIndex..., in: log)),
              let range = Range(match.range(at: 1), in: log) else { return nil }
        return String(log[range]).lowercased()
    }

    public static func hostname(forMAC mac: String) -> String? {
        let parts = mac.lowercased().split(separator: ":")
        guard parts.count == 6,
              parts.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }) else { return nil }
        return "lingxi-aimac-" + parts.suffix(3).joined()
    }

    private static func fixedField(_ value: Data, count: Int) -> Data {
        var result = Data(repeating: 0, count: count)
        result.replaceSubrange(0..<value.count, with: value)
        return result
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func crc32<T: DataProtocol>(_ bytes: T) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0)
            }
        }
        return crc ^ UInt32.max
    }
}

public struct ESP8266FlashResult: Equatable, Sendable {
    public var macAddress: String?
    public var expectedHostname: String?

    public init(macAddress: String?, expectedHostname: String?) {
        self.macAddress = macAddress
        self.expectedHostname = expectedHostname
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
        wifiProvisioningImage: Data? = nil,
        progress: @escaping @Sendable (Double) -> Void,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> ESP8266FlashResult {
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

        var temporaryDirectory: URL?
        var provisioningURL: URL?
        if let wifiProvisioningImage {
            guard AIMacWiFiProvisioning.validateImage(wifiProvisioningImage) else {
                throw ESP8266FlashError.failed("Wi-Fi 配网数据生成失败。")
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lingxi-aimac-provision-\(UUID().uuidString)",
                                        isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("wifi-provision.bin")
                try wifiProvisioningImage.write(to: url, options: [.atomic])
                temporaryDirectory = directory
                provisioningURL = url
            } catch {
                if let temporaryDirectory {
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                }
                throw ESP8266FlashError.failed("无法准备临时配网数据：\(error.localizedDescription)")
            }
        }
        defer {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = helperURL
        var arguments = [
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
        if let provisioningURL {
            arguments += [AIMacWiFiProvisioning.flashAddress, provisioningURL.path]
        }
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        setRunningProcess(process)
        defer { clearRunningProcess(if: process) }

        final class OutputState: @unchecked Sendable {
            let lock = NSLock()
            var text = ""
        }
        let state = OutputState()

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ESP8266FlashResult, Error>) in
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
                    let mac = AIMacWiFiProvisioning.macAddress(in: fullOutput)
                    continuation.resume(returning: ESP8266FlashResult(
                        macAddress: mac,
                        expectedHostname: mac.flatMap(AIMacWiFiProvisioning.hostname(forMAC:))))
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
