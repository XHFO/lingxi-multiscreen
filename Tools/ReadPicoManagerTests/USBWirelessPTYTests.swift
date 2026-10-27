import Foundation
import Darwin

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// This server creates its own private pseudo-terminal. No /dev/cu.* discovery,
/// physical serial opening, mounted volume, App or user-setting access is used.
private final class WirelessPico: @unchecked Sendable {
    typealias Handler = @Sendable ([String: Any], Int) throws -> Data?
    private let queue = DispatchQueue(label: "readpico.wireless.private-pty")
    private let lock = NSLock()
    private var master: Int32 = -1
    private var stopped = false
    private var requests: [[String: Any]] = []
    private var failure: String?
    let path: String
    init(chunks: [Int] = [7, 1, 31, 3], handler: @escaping Handler) throws {
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0, let name = ttyname(slave) else { throw POSIXError(.EIO) }
        path = String(cString: name)
        guard path.hasPrefix("/dev/ttys") || path.hasPrefix("/dev/pts/") else { Darwin.close(slave); Darwin.close(master); throw POSIXError(.EIO) }
        Darwin.close(slave)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        queue.async { [self] in
            var buffer = Data()
            while true {
                lock.lock(); let done = stopped; lock.unlock()
                if done { return }
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = Darwin.read(master, &bytes, bytes.count)
                if count > 0 { buffer.append(contentsOf: bytes.prefix(count)) }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer.prefix(upTo: newline)); buffer.removeSubrange(...newline)
                    if line.isEmpty { continue }
                    guard line.count + 1 <= 512, line.starts(with: Data("PICO_WIFI1 ".utf8)),
                          line.allSatisfy({ (32...126).contains($0) }),
                          let object = try? JSONSerialization.jsonObject(with: line.dropFirst(11)) as? [String: Any] else {
                        fail("malformed or oversized native request"); return
                    }
                    lock.lock(); requests.append(object); let index = requests.count - 1; lock.unlock()
                    do { if let reply = try handler(object, index) { try send(reply, chunks: chunks) } }
                    catch { fail("script assertion failed"); return }
                }
                usleep(500)
            }
        }
    }
    private func fail(_ reason: String) { lock.lock(); failure = reason; lock.unlock() }
    private func send(_ bytes: Data, chunks: [Int]) throws {
        var offset = 0, chunk = 0
        while offset < bytes.count {
            lock.lock(); let done = stopped; lock.unlock()
            if done { return }
            let size = min(chunks[chunk % chunks.count], bytes.count - offset)
            let count = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress!.advanced(by: offset), size) }
            if count > 0 { offset += count; chunk += 1 }
            else if count < 0 && (errno == EAGAIN || errno == EINTR) { usleep(500); continue }
            else { throw POSIXError(.EIO) }
            usleep(50)
        }
    }
    func finish() throws -> [[String: Any]] {
        lock.lock(); stopped = true; lock.unlock()
        queue.sync {}
        defer { Darwin.close(master); master = -1 }
        lock.lock(); defer { lock.unlock() }
        if failure != nil { throw ReadPicoUSBWirelessError.invalidResponse }
        return requests
    }
}

@main private struct USBWirelessPTYTests {
    static let identity = "AABBCCDDEEFF"
    static let key = String(repeating: "1", count: 32)
    static let management: [String: Any] = ["url": "http://192.0.2.42/", "key": key, "ttl_seconds": 900]
    static func b64(_ value: String) -> String { Data(value.utf8).base64EncodedString() }
    static func response(_ request: [String: Any], _ fields: [String: Any] = [:], ending: String = "\n") throws -> Data {
        var value: [String: Any] = ["v": 1, "id": request["id"]!, "op": request["op"]!, "ok": true,
                                  "status": 200, "phase": "ready", "device": "read-pico", "usb_serial": identity]
        fields.forEach { value[$0.key] = $0.value }
        var data = Data("PICO_WIFI1 ".utf8)
        data.append(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])); data.append(contentsOf: ending.utf8)
        return data
    }
    static func status(_ request: [String: Any], connected: Bool = true, fields: [String: Any] = [:], ending: String = "\n") throws -> Data {
        var value: [String: Any] = ["ready": true, "enabled": true, "connected": connected,
                                  "ip": connected ? "192.0.2.42" : "", "ssid_b64": b64(connected ? "测试网络" : ""), "busy": false]
        fields.forEach { value[$0.key] = $0.value }
        return try response(request, value, ending: ending)
    }
    static func main() throws {
        var checks = 0, exchanges = 0
        func check(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
        func exchange(_ fake: WirelessPico, action: ReadPicoUSBWirelessAction = .open,
                      cancelled: @escaping @Sendable () -> Bool = { false },
                      scanTimeout: TimeInterval = 1, connectTimeout: TimeInterval = 1) throws -> ReadPicoUSBWirelessResult {
            exchanges += 1
            return try ReadPicoUSBWirelessClient.exchange(port: fake.path, identity: identity, action: action,
                cancelled: cancelled, pollInterval: 0.001, scanTimeout: scanTimeout, connectTimeout: connectTimeout)
        }
        func expect(_ name: String, error expected: ReadPicoUSBWirelessError,
                    action: ReadPicoUSBWirelessAction = .open, _ handler: @escaping WirelessPico.Handler) throws -> [[String: Any]] {
            let fake = try WirelessPico(handler: handler)
            do { _ = try exchange(fake, action: action); preconditionFailure("Accepted invalid fixture: " + name) }
            catch let error as ReadPicoUSBWirelessError { check(error == expected, name + " returned wrong failure") }
            catch { preconditionFailure("Wrong error class: " + name) }
            return try fake.finish()
        }
        func ops(_ requests: [[String: Any]]) -> [String] { requests.compactMap { $0["op"] as? String } }

        check(ReadPicoUSBWirelessClient.normalizedIdentity("aabbccddeeff") == identity,
              "Complete lower-case registry MAC canonicalizes")
        check(ReadPicoUSBWirelessClient.normalizedIdentity("aa:bb:cc:dd:ee:ff") == identity,
              "Standard colon-delimited registry MAC canonicalizes")
        for malformed in ["AA-BB-CC-DD-EE-FF", "AABBCCDDEEFF---", "A:ABBCCDDEEFF", "AABBCCDDEEF", " AABBCCDDEEFF", "AABBCCDDEEFG"] {
            check(ReadPicoUSBWirelessClient.normalizedIdentity(malformed) == nil,
                  "Malformed or partial registry identity cannot become trusted")
        }

        for ending in ["\n", "\r\n"] {
            let fake = try WirelessPico(chunks: ending == "\n" ? [1] : [64, 2, 13, 1]) { request, index in
                if index == 0 { return Data("idf log with PICO_WIFI1 ignored\r\n".utf8) + (try status(request, ending: ending)) }
                guard request["expected_serial"] as? String == identity else { throw ReadPicoUSBWirelessError.identityMismatch }
                return try response(request, ["manage": management], ending: ending)
            }
            guard case .management(let value) = try exchange(fake) else { preconditionFailure("Missing online management") }
            let requests = try fake.finish()
            check(value.identity == identity && value.key == key && value.ttlSeconds == 900 && value.url.host == "192.0.2.42", "Online open returns actual bounded management capability")
            check(ops(requests) == ["status", "open"], "One identity read precedes opening management")
            check(requests.allSatisfy { ($0["v"] as? Int) == 1 && ($0["id"] as? Int).map { (1...Int(Int32.max)).contains($0) } == true }, "Native request carries v1 bounded positive correlation IDs")
        }

        let readOnly = try WirelessPico { request, _ in try status(request, connected: false) }
        guard case .status(let offline) = try exchange(readOnly, action: .status) else { preconditionFailure("Missing status") }
        check(!offline.connected && offline.ssid.isEmpty && offline.ready, "Offline status remains usable before saved network exists")
        check(ops(try readOnly.finish()) == ["status"], "Read-only status has no management or mutation commands")

        let scan = try WirelessPico { request, index in
            if index == 0 { return try status(request, connected: false) }
            if request["op"] as? String == "scan" { return try response(request, ["status": 202, "phase": "scanning", "op_id": 17]) }
            guard request["expected_serial"] as? String == identity, request["op_id"] as? Int == 17 else { throw ReadPicoUSBWirelessError.identityMismatch }
            if index < 3 { return try response(request, ["status": 202, "phase": "scanning", "op_id": 17]) }
            return try response(request, ["phase": "done", "op_id": 17, "networks": [
                ["ssid_b64": b64("较弱"), "rssi": -80, "requires_password": false, "supported": true],
                ["ssid_b64": b64("测试网络"), "rssi": -30, "requires_password": true, "supported": true],
                ["ssid_b64": b64("测试网络"), "rssi": -40, "requires_password": true, "supported": true]]])
        }
        guard case .networks(let networks) = try exchange(scan, action: .scan) else { preconditionFailure("Missing scan") }
        check(networks.map(\.ssid) == ["测试网络", "较弱"] && networks.first?.requiresPassword == true, "Asynchronous offline scan sorts and deduplicates real response rows")
        check(ops(try scan.finish()) == ["status", "scan", "poll", "poll"], "Scan correlates terminal response to accepted operation")

        let connect = try WirelessPico { request, index in
            if index == 0 { return try status(request, connected: false) }
            guard request["expected_serial"] as? String == identity else { throw ReadPicoUSBWirelessError.identityMismatch }
            if index == 1 {
                guard request["ssid_b64"] as? String == b64("测试网络"), request["password_b64"] as? String == b64("pty-test-password") else { throw ReadPicoUSBWirelessError.invalidInput }
                return try response(request, ["status": 202, "phase": "connecting", "op_id": 23])
            }
            guard request["op_id"] as? Int == 23 else { throw ReadPicoUSBWirelessError.invalidResponse }
            if index < 4 { return try response(request, ["status": 202, "phase": "connecting", "op_id": 23]) }
            return try response(request, ["phase": "ready", "op_id": 23, "manage": management])
        }
        guard case .management(let joined) = try exchange(connect, action: .connect(ssid: "测试网络", password: "pty-test-password")) else { preconditionFailure("Missing join") }
        check(joined.key == key, "Connected management token follows terminal readiness")
        check(ops(try connect.finish()) == ["status", "connect", "poll", "poll", "poll"], "Connect remains asynchronous through multiple progress replies")

        let identityFields: [[String: Any]] = [["usb_serial": "001122334455"], ["usb_serial": "AA:BB:CC:DD:EE:FF"],
            ["usb_serial": "AABBCCDDEEFF---"], ["device": "another-device"], ["v": 2], ["id": 0], ["op": "open"]]
        for (index, fields) in identityFields.enumerated() {
            let requests = try expect("identity/correlation \(index)", error: .identityMismatch,
                action: .connect(ssid: "测试网络", password: "pty-test-password")) { request, _ in try status(request, fields: fields) }
            check(ops(requests) == ["status"] && requests.allSatisfy { $0["password_b64"] == nil }, "Wrong device or stale status never receives password")
        }
        for fields: [String: Any] in [["id": 0], ["op": "scan"], ["usb_serial": "001122334455"]] {
            _ = try expect("open response identity/correlation", error: .identityMismatch) { request, index in
                if index == 0 { return try status(request) }
                return try response(request, fields.merging(["manage": management], uniquingKeysWith: { old, _ in old }))
            }
        }
        _ = try expect("wrong poll operation", error: .invalidResponse, action: .scan) { request, index in
            if index == 0 { return try status(request, connected: false) }
            return try response(request, ["status": index == 1 ? 202 : 200, "phase": "done", "op_id": index == 1 ? 19 : 20, "networks": []])
        }

        let statusInvalid: [[String: Any]] = [
            ["ready": 1], ["enabled": "true"], ["busy": 0], ["connected": 1],
            ["status": true], ["ok": 1], ["phase": ""], ["status": 500],
            ["ssid_b64": "!!"], ["ssid_b64": "Zh=="], ["ssid_b64": Data([255]).base64EncodedString()],
            ["ssid_b64": b64("bad\nname")], ["ssid_b64": b64(String(repeating: "x", count: 33))],
            ["ip": "not-an-ip"], ["ip": "999.0.2.42"]
        ]
        for (index, fields) in statusInvalid.enumerated() {
            _ = try expect("invalid typed/base64 status \(index)", error: .invalidResponse) { request, _ in try status(request, fields: fields) }
        }
        let malformed: [@Sendable ([String: Any]) throws -> Data] = [
            { request in let normal = try status(request); return Data(normal.dropLast(2)) + Data(",\"id\":0}\n".utf8) },
            { request in let normal = try status(request); return Data(normal.dropLast(2)) + Data(",\"\\u0069d\":0}\n".utf8) },
            { _ in Data("PICO_WIFI1 []\n".utf8) },
            { _ in Data("PICO_WIFI1 {invalid}\n".utf8) },
            { _ in Data("PICO_WIFI1 ".utf8) + Data(repeating: 120, count: 4096) + Data([10]) },
            { _ in Data("PICO_WIFI1 ".utf8) + Data(repeating: 120, count: 9000) + Data([10]) },
            { request in let normal = try status(request); return Data(normal.dropLast(2)) + Data(",\"extra\":\"é\"}\n".utf8) }
        ]
        for (index, fixture) in malformed.enumerated() {
            _ = try expect("malformed/duplicate/oversized \(index)", error: .invalidResponse) { request, _ in try fixture(request) }
        }
        _ = try expect("nested duplicate keys", error: .invalidResponse) { request, index in
            if index == 0 { return try status(request) }
            let normal = try response(request)
            return Data(normal.dropLast(2)) + Data((",\"manage\":{\"url\":\"http://192.0.2.42/\",\"key\":\"" + key + "\",\"key\":\"" + key + "\",\"ttl_seconds\":900}}\n").utf8)
        }
        let badManage: [[String: Any]] = [
            ["url": "https://192.0.2.42/"], ["url": "http://192.0.2.42/?key=bad"],
            ["url": "http://192.0.2.42/#key=bad"], ["url": "http://user@192.0.2.42/"],
            ["url": "http://999.0.2.42/"], ["url": "http://pico.local/"], ["key": "short"],
            ["ttl_seconds": 0], ["ttl_seconds": 901], ["ttl_seconds": true]
        ]
        for (index, fields) in badManage.enumerated() {
            _ = try expect("bad temporary management \(index)", error: .invalidResponse) { request, requestIndex in
                requestIndex == 0 ? try status(request) : try response(request, ["manage": management.merging(fields, uniquingKeysWith: { _, new in new })])
            }
        }
        for (label, fields): (String, [String: Any]) in [
            ("too many scan rows", ["networks": Array(repeating: ["ssid_b64": b64("a"), "rssi": -30, "requires_password": false, "supported": true], count: 17)]),
            ("boolean RSSI", ["networks": [["ssid_b64": b64("a"), "rssi": true, "requires_password": false, "supported": true]]]),
            ("RSSI above range", ["networks": [["ssid_b64": b64("a"), "rssi": 1, "requires_password": false, "supported": true]]])
        ] {
            _ = try expect(label, error: .invalidResponse, action: .scan) { request, index in
                if index == 0 { return try status(request, connected: false) }
                return try response(request, (["status": index == 1 ? 202 : 200, "phase": "done", "op_id": 3] as [String: Any]).merging(index == 1 ? [:] : fields, uniquingKeysWith: { _, new in new }))
            }
        }
        let errors: [(String, Int, ReadPicoUSBWirelessError)] = [
            ("identity_mismatch", 403, .identityMismatch), ("busy", 409, .busy), ("msc_active", 409, .busy),
            ("not_connected", 409, .networkRequired), ("operation_failed", 503, .failed),
            ("start_failed", 503, .failed), ("not_ready", 503, .unavailable),
            ("timeout", 504, .timeout), ("pairing_expired", 410, .expired), ("unknown_operation", 404, .invalidResponse)
        ]
        for (name, code, expected) in errors {
            _ = try expect("mapped " + name, error: expected) { request, _ in try response(request, ["ok": false, "status": code, "error": name]) }
        }
        _ = try expect("busy preflight", error: .busy) { request, _ in try status(request, fields: ["busy": true]) }
        _ = try expect("unready preflight", error: .unavailable) { request, _ in try status(request, fields: ["ready": false]) }
        _ = try expect("open while offline", error: .networkRequired) { request, _ in try status(request, connected: false) }
        for invalid in [ReadPicoUSBWirelessAction.connect(ssid: String(repeating: "x", count: 33), password: ""),
                        .connect(ssid: "good", password: String(repeating: "x", count: 65)),
                        .connect(ssid: "bad\0ssid", password: "")] {
            let requests = try expect("invalid connect input", error: .invalidInput, action: invalid) { request, _ in try status(request, connected: false) }
            check(ops(requests) == ["status"], "Internal invalid input never sends password-bearing command")
        }

        let cancellation = Flag()
        let cancelFake = try WirelessPico { _, _ in cancellation.set(); return nil }
        let started = ProcessInfo.processInfo.systemUptime
        do { _ = try exchange(cancelFake, cancelled: { cancellation.get() }); preconditionFailure("Cancellation not honored") }
        catch is CancellationError { check(ProcessInfo.processInfo.systemUptime - started < 1, "Native response wait cancels promptly") }
        check(ops(try cancelFake.finish()) == ["status"], "Cancellation sends no follow-up mutation")
        let pollCancellation = Flag()
        let cancelPoll = try WirelessPico { request, index in
            if index == 0 { return try status(request, connected: false) }
            if index == 1 { return try response(request, ["status": 202, "phase": "connecting", "op_id": 11]) }
            pollCancellation.set(); return nil
        }
        do {
            _ = try exchange(cancelPoll, action: .connect(ssid: "测试网络", password: "pty-test-password"), cancelled: { pollCancellation.get() })
            preconditionFailure("Polling cancellation not honored")
        } catch is CancellationError { check(true, "Polling wait cancels without resending connect") }
        check(ops(try cancelPoll.finish()) == ["status", "connect", "poll"], "Cancellation after acceptance never repeats secret-bearing command")
        let timeoutFake = try WirelessPico { request, index in
            if index == 0 { return try status(request, connected: false) }
            return try response(request, ["status": 202, "phase": "scanning", "op_id": 9])
        }
        do { _ = try exchange(timeoutFake, action: .scan, scanTimeout: 0.05); preconditionFailure("Scan deadline ignored") }
        catch let error as ReadPicoUSBWirelessError { check(error == .timeout, "Bounded asynchronous scan deadline terminates") }
        let timed = try timeoutFake.finish()
        check(ops(timed).prefix(2).elementsEqual(["status", "scan"]) && timed.count < 10, "Timeout retains bounded poll count")
        let connectTimeout = try WirelessPico { request, index in
            if index == 0 { return try status(request, connected: false) }
            return try response(request, ["status": 202, "phase": "connecting", "op_id": 12])
        }
        do {
            _ = try exchange(connectTimeout, action: .connect(ssid: "测试网络", password: "pty-test-password"), connectTimeout: 0.05)
            preconditionFailure("Connect deadline ignored")
        } catch let error as ReadPicoUSBWirelessError { check(error == .timeout, "Bounded asynchronous connect deadline terminates") }
        check(ops(try connectTimeout.finish()).filter { $0 == "connect" }.count == 1, "Connection deadline never retries the password command")
        print("USB wireless PTY: \(checks) checks passed across \(exchanges) real private-PTY exchanges; no hardware, mounted volumes, App or user settings")
    }
}
