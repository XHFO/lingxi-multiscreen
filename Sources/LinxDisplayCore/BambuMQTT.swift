import Foundation
import Network
import Security
import CryptoKit

public enum BambuDataSource: String, Codable, CaseIterable {
    case homeAssistant, localMQTT
    public var title: String { self == .localMQTT ? String(localized: "局域网 MQTT") : "Home Assistant" }
}

public struct BambuMQTTSettings: Codable, Equatable {
    public var namespace: String?
    public var host = ""
    public var serial = ""
    /// User-approved leaf-certificate SHA256, never globally disable TLS verification.
    public var certificateSHA256 = ""
    public var certificatePEM: String?
    public init() {}
    public var entityPrefix: String {
        "sensor.lingxi_mqtt_" + (namespace ?? serial).lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) } + "_"
    }
    public var isValid: Bool {
        !host.isEmpty && !host.contains(":") && !host.contains("/") && !host.contains(" ")
        && !serial.isEmpty && serial.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    public func applying(to input: BambuLabCardSettings) -> BambuLabCardSettings {
        var c = input
        c.statusEntityID = entityPrefix + "status"
        c.progressEntityID = entityPrefix + "progress"
        c.taskEntityID = entityPrefix + "task"
        c.nozzleTempEntityID = entityPrefix + "nozzle"
        c.bedTempEntityID = entityPrefix + "bed"
        c.remainingEntityID = entityPrefix + "remaining"
        c.endTimeEntityID = entityPrefix + "end"
        c.errorEntityID = entityPrefix + "error"
        // Native MQTT does not transport camera frames or task thumbnails.
        c.imageEntityID = ""; c.taskImageEntityID = ""
        return c
    }
}

public enum BambuMQTTSecretStore {
    private static let subdirectory = "bambu-mqtt-credentials"
    public static func read(deviceID: UUID) -> String {
        SealedCredentialStore.read(account: deviceID.uuidString, subdirectory: subdirectory)
    }
    @discardableResult public static func save(_ value: String, deviceID: UUID) -> Bool {
        SealedCredentialStore.save(value, account: deviceID.uuidString, subdirectory: subdirectory)
    }
}

public struct BambuMQTTReport {
    public private(set) var fields: [String: Any] = [:]
    public init() {}
    @discardableResult public mutating func merge(_ data: Data) throws -> Bool {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let print = root["print"] as? [String: Any] else { return false }
        for (key, value) in print { fields[key] = value }
        return true
    }
    public func entities(config: BambuMQTTSettings, now: Date = Date()) -> [HAEntity] {
        func text(_ key: String) -> String? {
            if let value = fields[key] as? String { return value }
            if let value = fields[key] as? NSNumber { return value.stringValue }
            return nil
        }
        var result: [HAEntity] = []
        func add(_ suffix: String, _ value: String?, _ unit: String? = nil) {
            guard let value else { return }
            result.append(HAEntity(entityId: config.entityPrefix + suffix, friendlyName: suffix,
                state: value, unitOfMeasurement: unit, lastChanged: now))
        }
        let raw = text("gcode_state")?.lowercased()
        add("status", raw == "finish" ? "finished" : raw == "running" ? "printing" : raw)
        add("progress", text("mc_percent"), "%")
        add("task", text("subtask_name") ?? text("gcode_file"))
        add("nozzle", text("nozzle_temper"), "°C")
        add("bed", text("bed_temper"), "°C")
        add("remaining", text("mc_remaining_time"), "min")
        add("error", text("print_error"))
        if let minutes = text("mc_remaining_time").flatMap(Double.init), minutes >= 0 {
            add("end", ISO8601DateFormatter().string(from: now.addingTimeInterval(minutes * 60)))
        }
        return result
    }
}

public enum BambuMQTTCodec {
    public static func string(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]) + bytes
    }
    public static func packet(_ header: UInt8, _ body: Data) -> Data {
        var length = body.count, result = Data([header])
        repeat {
            var byte = UInt8(length % 128); length /= 128
            if length > 0 { byte |= 128 }; result.append(byte)
        } while length > 0
        return result + body
    }
    /// Bounded incremental parsing: TCP reads are not MQTT packet boundaries.
    public static func pop(from buffer: inout Data) throws -> (UInt8, Data)? {
        guard buffer.count >= 2 else { return nil }
        let bytes = [UInt8](buffer.prefix(5))
        var length = 0, multiplier = 1, offset = 1
        while offset < bytes.count {
            let byte = bytes[offset]; length += Int(byte & 127) * multiplier; offset += 1
            if byte & 128 == 0 {
                guard length <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
                guard buffer.count >= offset + length else { return nil }
                let header = buffer.first!, payload = Data(buffer.dropFirst(offset).prefix(length))
                buffer = Data(buffer.dropFirst(offset + length))
                return (header, payload)
            }
            guard offset < 5 else { throw CocoaError(.fileReadCorruptFile) }
            multiplier *= 128
        }
        return nil
    }
}

/// Read-only Bambu LAN protocol: TLS/8883, bblp + access code, report subscription.
/// Only pushall (state query) is published. No motion/heating/print-control commands.
@MainActor public final class BambuMQTTClient {
    public var onReport: ((BambuMQTTReport) -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onCertificate: ((String) -> Void)?
    public var onVerifiedCertificate: ((String) -> Void)?
    private let settings: BambuMQTTSettings
    private let accessCode: String
    private var connection: NWConnection?
    private var buffer = Data(), report = BambuMQTTReport()
    private var keepalive: Task<Void, Never>?, reconnect: Task<Void, Never>?
    private var stopped = false, retry = 0
    private var lastReceived = Date()
    public init(settings: BambuMQTTSettings, accessCode: String) {
        self.settings = settings; self.accessCode = accessCode
    }
    public func start() {
        guard settings.isValid, !accessCode.isEmpty else { onStatus?("请填写打印机 IP、序列号和访问码"); return }
        stopped = false; connect()
    }
    public func stop() {
        stopped = true; reconnect?.cancel(); keepalive?.cancel(); connection?.cancel(); connection = nil
    }
    private func connect() {
        buffer = Data(); lastReceived = Date()
        onStatus?("正在连接局域网 MQTT…")
        let tls = NWProtocolTLS.Options()
        let expected = settings.certificateSHA256.lowercased()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let cert = SecTrustGetCertificateAtIndex(secTrust, 0) else { complete(false); return }
            let data = SecCertificateCopyData(cert) as Data
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if fingerprint != expected {
                Task { @MainActor in self?.onCertificate?(fingerprint) }
                complete(false)
            } else {
                let base64 = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
                let pem = "-----BEGIN CERTIFICATE-----\n" + base64 + "\n-----END CERTIFICATE-----\n"
                Task { @MainActor in self?.onVerifiedCertificate?(pem) }
                complete(true)
            }
        }, .main)
        let conn = NWConnection(host: NWEndpoint.Host(settings.host), port: 8883,
            using: NWParameters(tls: tls))
        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor in
            guard let self, let conn, self.connection === conn else { return }
            switch state {
            case .ready:
                var body = BambuMQTTCodec.string("MQTT") + Data([4, 0xc2, 0, 30])
                body += BambuMQTTCodec.string("lingxi-" + String(UUID().uuidString.prefix(12)))
                body += BambuMQTTCodec.string("bblp") + BambuMQTTCodec.string(self.accessCode)
                self.send(BambuMQTTCodec.packet(0x10, body)); self.receive(conn)
            case .failed, .waiting: self.failed(conn)
            default: break
            }
            }
        }
        conn.start(queue: .main)
    }
    private func failed(_ conn: NWConnection) {
        guard connection === conn else { return }
        conn.cancel(); connection = nil; keepalive?.cancel()
        onStatus?(settings.certificateSHA256.isEmpty ? "需要确认打印机 TLS 证书" : "MQTT 断开，请检查网络、访问码及打印机局域网权限")
        guard !stopped, !settings.certificateSHA256.isEmpty else { return }
        retry = min(retry + 1, 5)
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(1 << self.retry) * 1_000_000_000)
            guard !Task.isCancelled, !self.stopped else { return }; self.connect()
        }
    }
    private func send(_ data: Data) {
        guard let conn = connection else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self, weak conn] error in
            Task { @MainActor in
            if error != nil, let conn { self?.failed(conn) }
            }
        })
    }
    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] data, _, done, error in
            Task { @MainActor in
            guard let self, let conn, self.connection === conn else { return }
            if let data {
                self.lastReceived = Date(); self.buffer += data
                do {
                    guard self.buffer.count <= 1_048_581 else { throw CocoaError(.fileReadTooLarge) }
                    while let (header, body) = try BambuMQTTCodec.pop(from: &self.buffer) {
                        try self.handle(header, body)
                    }
                } catch { self.failed(conn); return }
            }
            if done || error != nil { self.failed(conn) } else { self.receive(conn) }
            }
        }
    }
    private func handle(_ header: UInt8, _ body: Data) throws {
        let bytes = [UInt8](body)
        switch header >> 4 {
        case 2:
            guard bytes.count == 2, bytes[1] == 0 else { throw CocoaError(.userCancelled) }
            let subscription = Data([0, 1]) + BambuMQTTCodec.string("device/\(settings.serial)/report") + Data([0])
            send(BambuMQTTCodec.packet(0x82, subscription))
        case 9:
            guard bytes.count >= 3, bytes[0] == 0, bytes[1] == 1, bytes[2] < 0x80 else { throw CocoaError(.fileReadCorruptFile) }
            retry = 0; onStatus?("MQTT 已连接 · 等待打印机状态")
            let query = Data("{\"pushing\":{\"sequence_id\":\"1\",\"command\":\"pushall\"}}".utf8)
            send(BambuMQTTCodec.packet(0x30, BambuMQTTCodec.string("device/\(settings.serial)/request") + query))
            keepalive?.cancel()
            keepalive = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled, let self, let conn = self.connection else { return }
                    if Date().timeIntervalSince(self.lastReceived) > 60 { self.failed(conn); return }
                    self.send(Data([0xc0, 0]))
                }
            }
        case 3:
            guard bytes.count >= 2 else { throw CocoaError(.fileReadCorruptFile) }
            let n = Int(bytes[0]) * 256 + Int(bytes[1]), qos = (header >> 1) & 3
            guard bytes.count >= 2+n, qos <= 1,
                  String(data: body.dropFirst(2).prefix(n), encoding: .utf8) == "device/\(settings.serial)/report"
            else { throw CocoaError(.fileReadCorruptFile) }
            var offset = 2+n
            if qos == 1 {
                guard bytes.count >= offset+2 else { throw CocoaError(.fileReadCorruptFile) }
                send(Data([0x40, 2, bytes[offset], bytes[offset+1]])); offset += 2
            }
            if try report.merge(Data(body.dropFirst(offset))) {
                onStatus?("MQTT 实时状态已更新"); onReport?(report)
            }
        default: break
        }
    }
    deinit { connection?.cancel(); reconnect?.cancel(); keepalive?.cancel() }
}
