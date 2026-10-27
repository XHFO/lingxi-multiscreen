import Foundation
import CoreFoundation
import Darwin

public enum ReadPicoWirelessSetupPhase: String, Sendable {
    case idle, checking, scanning, selectNetwork, connecting, pairing, connected, failed
}

public struct ReadPicoUSBWirelessNetwork: Identifiable, Sendable, Equatable {
    public let ssid: String, rssi: Int, requiresPassword: Bool, supported: Bool
    public var id: String { ssid }
    public init(ssid: String, rssi: Int, requiresPassword: Bool, supported: Bool) {
        self.ssid = ssid; self.rssi = rssi; self.requiresPassword = requiresPassword; self.supported = supported
    }
}

public struct ReadPicoUSBWirelessStatus: Sendable, Equatable {
    public let identity: String, ready: Bool, enabled: Bool, connected: Bool, ip: String, ssid: String, busy: Bool
    public init(identity: String, ready: Bool, enabled: Bool, connected: Bool, ip: String, ssid: String, busy: Bool) {
        self.identity = identity; self.ready = ready; self.enabled = enabled; self.connected = connected
        self.ip = ip; self.ssid = ssid; self.busy = busy
    }
}

/// Temporary credentials exist in memory only. Never include this value in diagnostics or persistence.
public struct ReadPicoUSBWirelessManagement: Sendable, Equatable {
    public let identity: String, url: URL, key: String, ttlSeconds: Int
    public init(identity: String, url: URL, key: String, ttlSeconds: Int) {
        self.identity = identity; self.url = url; self.key = key; self.ttlSeconds = ttlSeconds
    }
}

public enum ReadPicoUSBWirelessError: LocalizedError, Equatable {
    case invalidInput, invalidResponse, identityMismatch, unavailable, busy, networkRequired, failed, timeout, expired
    public var errorDescription: String? {
        switch self {
        case .invalidInput: return "网络名称或密码不符合要求，请检查后重试。"
        case .invalidResponse: return "设备没有返回有效的无线配置确认，请更新固件后重试。"
        case .identityMismatch: return "USB 设备身份与所选 Pico 不一致，未发送网络密码。请重新连接正确的设备。"
        case .unavailable: return "暂时无法与 Pico 通信，请保持 USB 连接并唤醒设备后重试。"
        case .busy: return "设备仍在进行 USB 文件传输或其他操作，请安全结束后重试。"
        case .networkRequired: return "Pico 尚未连接 Wi-Fi，请选择网络并输入密码。"
        case .failed: return "Pico 未能连接网络，请核对密码、信号和网络类型后重试。"
        case .timeout: return "等待 Pico 的无线配置超时，请保持连接后重试。"
        case .expired: return "本次临时配对已过期，请点击自动连接重新配对。"
        }
    }
}

public enum ReadPicoUSBWirelessAction: Sendable {
    case status, open, scan, connect(ssid: String, password: String)
}
public enum ReadPicoUSBWirelessResult: Sendable {
    case status(ReadPicoUSBWirelessStatus), management(ReadPicoUSBWirelessManagement), networks([ReadPicoUSBWirelessNetwork])
}

/// Bounded, correlated PICO_WIFI1 JSON lines. A single exclusive lease/FD covers identity verification,
/// the secret-bearing command and all polls. No reset, modem-line changes, Keychain or credential storage.
public final class ReadPicoUSBWirelessClient: @unchecked Sendable {
    public typealias Runner = @Sendable (String, String, ReadPicoUSBWirelessAction, @escaping @Sendable () -> Bool) async throws -> ReadPicoUSBWirelessResult
    private let runner: Runner?
    public init(runner: Runner? = nil) { self.runner = runner }
    public static func normalizedIdentity(_ value: String) -> String? {
        let input = Array(value.utf8)
        guard input.count == 12 || input.count == 17 else { return nil }
        if input.count == 17 {
            guard input.enumerated().allSatisfy({ $0.offset % 3 != 2 || $0.element == 58 }) else { return nil }
        }
        let bytes = input.enumerated().filter { input.count != 17 || $0.offset % 3 != 2 }.map(\.element)
        guard bytes.count == 12, bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self).uppercased()
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    public func status(port: String, expectedIdentity: String) async throws -> ReadPicoUSBWirelessStatus {
        guard case .status(let value) = try await run(port: port, identity: expectedIdentity, action: .status) else { throw ReadPicoUSBWirelessError.invalidResponse }
        return value
    }
    public func open(port: String, expectedIdentity: String) async throws -> ReadPicoUSBWirelessManagement {
        guard case .management(let value) = try await run(port: port, identity: expectedIdentity, action: .open) else { throw ReadPicoUSBWirelessError.invalidResponse }
        return value
    }
    public func scan(port: String, expectedIdentity: String) async throws -> [ReadPicoUSBWirelessNetwork] {
        guard case .networks(let value) = try await run(port: port, identity: expectedIdentity, action: .scan) else { throw ReadPicoUSBWirelessError.invalidResponse }
        return value
    }
    public func connect(port: String, expectedIdentity: String, ssid: String, password: String) async throws -> ReadPicoUSBWirelessManagement {
        guard Self.validText(ssid, min: 1, max: 32), Self.validText(password, min: 0, max: 64) else { throw ReadPicoUSBWirelessError.invalidInput }
        guard case .management(let value) = try await run(port: port, identity: expectedIdentity, action: .connect(ssid: ssid, password: password)) else { throw ReadPicoUSBWirelessError.invalidResponse }
        return value
    }
    private func run(port: String, identity: String, action: ReadPicoUSBWirelessAction) async throws -> ReadPicoUSBWirelessResult {
        guard port.hasPrefix("/dev/cu.usbmodem"), URL(fileURLWithPath: port).deletingLastPathComponent().path == "/dev",
              let identity = Self.normalizedIdentity(identity) else { throw ReadPicoUSBWirelessError.identityMismatch }
        try Task.checkCancellation()
        let lease = try ReadPicoUSBSerialLease.acquire(path: port); defer { lease.release() }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            let result: ReadPicoUSBWirelessResult
            if let runner { result = try await runner(port, identity, action, { cancellation.isCancelled() }) }
            else { result = try await Task.detached { try Self.exchange(port: port, identity: identity, action: action, cancelled: { cancellation.isCancelled() }) }.value }
            try Task.checkCancellation(); return result
        } onCancel: { cancellation.cancel() }
    }
    private static func validText(_ value: String, min: Int, max: Int) -> Bool {
        (min...max).contains(value.utf8.count) && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func decodedText(_ value: Any?, min: Int, max: Int) throws -> String {
        guard let encoded = value as? String, let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded,
              let text = String(data: data, encoding: .utf8), validText(text, min: min, max: max) else { throw ReadPicoUSBWirelessError.invalidResponse }
        return text
    }
    private static func validIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.utf8.allSatisfy { (48...57).contains($0) }
                && Int(part).map { (0...255).contains($0) } == true
        }
    }
    private static func mappedError(_ value: Any?) -> ReadPicoUSBWirelessError {
        switch value as? String {
        case "identity_mismatch": return .identityMismatch
        case "msc_active", "busy": return .busy
        case "not_connected": return .networkRequired
        case "timeout": return .timeout
        case "pairing_expired": return .expired
        case "operation_failed", "start_failed": return .failed
        case "not_ready": return .unavailable
        default: return .invalidResponse
        }
    }
    private static func management(_ object: [String: Any], identity: String) throws -> ReadPicoUSBWirelessManagement {
        guard let value = object["manage"] as? [String: Any], let address = value["url"] as? String,
              address.utf8.count <= 96, let parts = URLComponents(string: address), parts.scheme == "http",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let host = parts.host,
              validIPv4(host), let url = parts.url, parts.port == nil || (1...65535).contains(parts.port!),
              let key = value["key"] as? String, key.utf8.count == 32,
              key.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let ttl = integer(value["ttl_seconds"]), (1...900).contains(ttl) else { throw ReadPicoUSBWirelessError.invalidResponse }
        return .init(identity: identity, url: url, key: key, ttlSeconds: ttl)
    }
    /// Internal native entry point is exercised against private PTYs by the contract suite.
    static func exchange(port: String, identity: String, action: ReadPicoUSBWirelessAction,
                         cancelled: @escaping @Sendable () -> Bool, pollInterval: TimeInterval = 0.5,
                         scanTimeout: TimeInterval = 20, connectTimeout: TimeInterval = 45) throws -> ReadPicoUSBWirelessResult {
        let channel = try Channel(port: port, cancelled: cancelled)
        defer { channel.close() }
        var sequence = Int.random(in: 1...1_000_000_000)
        func request(_ op: String, fields: [String: Any] = [:], deadline: TimeInterval = 6) throws -> [String: Any] {
            try channel.check()
            sequence += 1
            var body: [String: Any] = ["v": 1, "id": sequence, "op": op]
            fields.forEach { body[$0.key] = $0.value }
            let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            var line = Data("PICO_WIFI1 ".utf8); line.append(json); line.append(10)
            guard line.count <= 512, line.dropLast().allSatisfy({ (32...126).contains($0) }) else { throw ReadPicoUSBWirelessError.invalidInput }
            try channel.write(line)
            let response = try channel.response(timeout: deadline)
            guard integer(response["v"]) == 1, integer(response["id"]) == sequence,
                  response["op"] as? String == op, response["device"] as? String == "read-pico",
                  let serial = response["usb_serial"] as? String, serial.utf8.count == 12, normalizedIdentity(serial) == identity else {
                throw ReadPicoUSBWirelessError.identityMismatch
            }
            guard let status = integer(response["status"]), let ok = boolean(response["ok"]),
                  let phase = response["phase"] as? String, !phase.isEmpty, phase.utf8.count <= 32,
                  ok == (200...299).contains(status) else { throw ReadPicoUSBWirelessError.invalidResponse }
            guard ok else { throw mappedError(response["error"]) }
            return response
        }
        let initial = try request("status")
        guard integer(initial["status"]) == 200, let ready = boolean(initial["ready"]), let enabled = boolean(initial["enabled"]),
              let connected = boolean(initial["connected"]), let ip = initial["ip"] as? String, ip.utf8.count <= 15,
              connected ? validIPv4(ip) : (ip.isEmpty || validIPv4(ip)),
              let busy = boolean(initial["busy"]) else { throw ReadPicoUSBWirelessError.invalidResponse }
        let ssid = try decodedText(initial["ssid_b64"], min: 0, max: 32)
        let status = ReadPicoUSBWirelessStatus(identity: identity, ready: ready, enabled: enabled, connected: connected, ip: ip, ssid: ssid, busy: busy)
        if case .status = action { return .status(status) }
        guard !busy else { throw ReadPicoUSBWirelessError.busy }
        guard ready else { throw ReadPicoUSBWirelessError.unavailable }
        let response: [String: Any], timeout: TimeInterval
        switch action {
        case .status: throw ReadPicoUSBWirelessError.invalidResponse
        case .open:
            guard connected else { throw ReadPicoUSBWirelessError.networkRequired }
            let opened = try request("open", fields: ["expected_serial": identity])
            guard integer(opened["status"]) == 200, opened["phase"] as? String == "ready" else { throw ReadPicoUSBWirelessError.invalidResponse }
            return .management(try management(opened, identity: identity))
        case .scan:
            response = try request("scan"); timeout = scanTimeout
        case .connect(let ssid, let password):
            guard validText(ssid, min: 1, max: 32), validText(password, min: 0, max: 64) else { throw ReadPicoUSBWirelessError.invalidInput }
            response = try request("connect", fields: ["expected_serial": identity,
                "ssid_b64": Data(ssid.utf8).base64EncodedString(), "password_b64": Data(password.utf8).base64EncodedString()])
            timeout = connectTimeout
        }
        guard integer(response["status"]) == 202, let operation = integer(response["op_id"]), (1...Int(Int32.max)).contains(operation) else { throw ReadPicoUSBWirelessError.invalidResponse }
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < end {
            try channel.sleep(pollInterval)
            let value = try request("poll", fields: ["expected_serial": identity, "op_id": operation], deadline: min(6, max(0.05, end - ProcessInfo.processInfo.systemUptime)))
            guard integer(value["op_id"]) == operation else { throw ReadPicoUSBWirelessError.invalidResponse }
            if integer(value["status"]) == 202 { continue }
            guard integer(value["status"]) == 200 else { throw ReadPicoUSBWirelessError.invalidResponse }
            if case .scan = action {
                guard value["phase"] as? String == "done", let values = value["networks"] as? [[String: Any]], values.count <= 16 else { throw ReadPicoUSBWirelessError.invalidResponse }
                var networks: [ReadPicoUSBWirelessNetwork] = []
                for row in values {
                    let ssid = try decodedText(row["ssid_b64"], min: 1, max: 32)
                    guard let rssi = integer(row["rssi"]), (-127...0).contains(rssi), let password = boolean(row["requires_password"]), let supported = boolean(row["supported"]) else { throw ReadPicoUSBWirelessError.invalidResponse }
                    if !networks.contains(where: { $0.ssid == ssid }) { networks.append(.init(ssid: ssid, rssi: rssi, requiresPassword: password, supported: supported)) }
                }
                return .networks(networks.sorted { $0.rssi > $1.rssi })
            }
            guard value["phase"] as? String == "ready" else { throw ReadPicoUSBWirelessError.invalidResponse }
            return .management(try management(value, identity: identity))
        }
        throw ReadPicoUSBWirelessError.timeout
    }

    private final class Channel {
        private var descriptor: Int32
        private let cancelled: @Sendable () -> Bool
        private var buffered = Data()
        init(port: String, cancelled: @escaping @Sendable () -> Bool) throws {
            self.cancelled = cancelled
            descriptor = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard descriptor >= 0 else { throw ReadPicoUSBWirelessError.unavailable }
            do {
                guard Darwin.ioctl(descriptor, TIOCEXCL) == 0 else { throw ReadPicoUSBWirelessError.busy }
                var config = termios()
                guard tcgetattr(descriptor, &config) == 0 else { throw ReadPicoUSBWirelessError.unavailable }
                cfmakeraw(&config); config.c_cflag |= tcflag_t(CLOCAL | CREAD); config.c_cflag &= ~tcflag_t(HUPCL)
                guard cfsetspeed(&config, speed_t(B115200)) == 0, tcsetattr(descriptor, TCSANOW, &config) == 0 else { throw ReadPicoUSBWirelessError.unavailable }
            } catch { Darwin.close(descriptor); descriptor = -1; throw error }
        }
        func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
        deinit { close() }
        func check() throws { if cancelled() { throw CancellationError() } }
        func sleep(_ interval: TimeInterval) throws {
            let end = ProcessInfo.processInfo.systemUptime + interval
            repeat { try check(); usleep(10_000) } while ProcessInfo.processInfo.systemUptime < end
        }
        func write(_ data: Data) throws {
            var offset = 0; let end = ProcessInfo.processInfo.systemUptime + 2
            while offset < data.count {
                try check()
                let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset) }
                if count > 0 { offset += count; continue }
                guard count < 0, errno == EAGAIN || errno == EINTR, ProcessInfo.processInfo.systemUptime < end else { throw ReadPicoUSBWirelessError.unavailable }
                usleep(10_000)
            }
        }
        func response(timeout: TimeInterval) throws -> [String: Any] {
            let end = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < end {
                try check()
                while let index = buffered.firstIndex(of: 10) {
                    let raw = Data(buffered.prefix(upTo: index)); buffered.removeSubrange(...index)
                    guard raw.starts(with: Data("PICO_WIFI1 ".utf8)) else { continue }
                    var line = raw; if line.last == 13 { line.removeLast() }
                    guard line.count + 1 <= 4096, line.allSatisfy({ (32...126).contains($0) }),
                          let json = String(data: line.dropFirst(11), encoding: .utf8)?.data(using: .utf8),
                          UniqueJSONKeys.valid(json), let value = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw ReadPicoUSBWirelessError.invalidResponse }
                    return value
                }
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 {
                    buffered.append(contentsOf: bytes.prefix(count))
                    guard buffered.count <= 8192 else { throw ReadPicoUSBWirelessError.invalidResponse }
                } else if count < 0 && errno != EAGAIN && errno != EINTR { throw ReadPicoUSBWirelessError.unavailable }
                else { usleep(10_000) }
            }
            throw ReadPicoUSBWirelessError.timeout
        }
    }
}

/// JSONSerialization accepts duplicate members; reject them before interpreting identity or credentials.
private enum UniqueJSONKeys {
    static func valid(_ data: Data) -> Bool {
        var parser = Parser(bytes: Array(data)); return parser.value(depth: 0) && parser.finish()
    }
    private struct Parser {
        let bytes: [UInt8]; var index = 0
        mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func finish() -> Bool { whitespace(); return index == bytes.count }
        mutating func string() -> String? {
            guard index < bytes.count, bytes[index] == 34 else { return nil }
            let start = index; index += 1; var escaped = false
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 && !escaped {
                    let fragment = Data(bytes[start..<index])
                    guard let value = try? JSONSerialization.jsonObject(with: fragment, options: [.fragmentsAllowed]) as? String else { return nil }
                    return value
                }
                if byte == 92 && !escaped { escaped = true } else { escaped = false }
            }
            return nil
        }
        mutating func value(depth: Int) -> Bool {
            whitespace(); guard depth <= 8, index < bytes.count else { return false }
            if bytes[index] == 34 { return string() != nil }
            if bytes[index] == 123 {
                index += 1; whitespace(); var keys = Set<String>()
                if index < bytes.count && bytes[index] == 125 { index += 1; return true }
                while index < bytes.count {
                    whitespace(); guard let key = string(), keys.insert(key).inserted else { return false }
                    whitespace(); guard index < bytes.count, bytes[index] == 58 else { return false }; index += 1
                    guard value(depth: depth + 1) else { return false }; whitespace()
                    guard index < bytes.count else { return false }
                    if bytes[index] == 125 { index += 1; return true }
                    guard bytes[index] == 44 else { return false }; index += 1
                }
                return false
            }
            if bytes[index] == 91 {
                index += 1; whitespace(); if index < bytes.count && bytes[index] == 93 { index += 1; return true }
                while value(depth: depth + 1) {
                    whitespace(); guard index < bytes.count else { return false }
                    if bytes[index] == 93 { index += 1; return true }
                    guard bytes[index] == 44 else { return false }; index += 1
                }
                return false
            }
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { return false }
            return (try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed])) != nil
        }
    }
}
