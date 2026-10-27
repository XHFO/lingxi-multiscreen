import Foundation
import LinxDisplayCore

private var checks = 0
private func check(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
private func reject(_ message: String, _ action: () throws -> Void) {
    do { try action(); fatalError("accepted invalid " + message) } catch { checks += 1 }
}
private func rejectAsync(_ message: String, _ action: () async throws -> Void) async {
    do { try await action(); fatalError("accepted invalid " + message) } catch { checks += 1 }
}
private actor Gate {
    var running = false
    func run(_ cancelled: @escaping @Sendable () -> Bool) async throws -> ReadPicoUSBStartResult {
        running = true
        while !cancelled() { try await Task.sleep(nanoseconds: 5_000_000) }
        throw CancellationError()
    }
}
private actor AcceptedGate {
    var running = false
    var acknowledged = false
    func returnAfterCancellation(_ cancelled: @escaping @Sendable () -> Bool) async -> ReadPicoUSBStartResult {
        running = true
        while !cancelled() { try? await Task.sleep(nanoseconds: 1_000_000) }
        return .init()
    }
    func recordAcknowledgement() { acknowledged = true }
}
private func status(_ extra: String = "") -> String {
    "RPICO {\"device\":\"read-pico\",\"route\":3,\"mounted\":true,\"read_verified\":true,\"write_verified\":true,\"storage_busy\":false" + extra + "}\n"
}
// Exact storage/USB fields recorded from a healthy dev44 cold boot. Verification
// flags describe an explicit temporary-file check, which boot mounting does not run.
private func coldBootStatus(_ changes: [String: Any] = [:], removing: [String] = []) throws -> String {
    var fields: [String: Any] = ["device": "read-pico", "version": "0.28.2-dev44", "route": 0,
        "storage_busy": false, "present": true, "mounted": true, "state": 3, "stage": 7,
        "read_verified": false, "write_verified": false, "error": 0,
        "usb_held": false, "usb_active": false, "usb_connected": false, "usb_host_ejected": false,
        "usb_debug_restored": true, "usb_error": 0, "bytes": 62599987200, "free": 62584422400]
    fields.merge(changes) { _, new in new }
    for key in removing { fields.removeValue(forKey: key) }
    return "RPICO " + String(data: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), encoding: .utf8)! + "\n"
}
@main struct USBTransferTests {
    static func main() async throws {
        _ = try ReadPicoUSBTransferClient.parseStatus(status())
        check(true, "current maintenance status accepted")
        check(try ReadPicoUSBTransferClient.parseStatus(status()).backgroundSupported == false, "old firmware remains legacy")
        check(try ReadPicoUSBTransferClient.parseStatus(status(",\"usb_background_supported\":true")).backgroundSupported, "background support negotiated")
        for field in ["usb_background_supported", "usb_background"] {
            for value in ["1", "\"true\"", "null"] {
                reject("malformed background mode") { _ = try ReadPicoUSBTransferClient.parseStatus(status(",\"\(field)\":\(value)")) }
            }
        }
        _ = try ReadPicoUSBTransferClient.parseStatus(status().replacingOccurrences(of: "\"device\":\"read-pico\",", with: ""))
        check(true, "legacy maintenance status accepted")
        _ = try ReadPicoUSBTransferClient.parseStatus(coldBootStatus())
        check(true, "actual dev44 healthy cold boot accepts flags for an unperformed optional check")
        _ = try ReadPicoUSBTransferClient.parseStatus(coldBootStatus().replacingOccurrences(of: "\n", with: "\r\n"))
        check(true, "actual cold-boot CRLF framing accepted")
        _ = try ReadPicoUSBTransferClient.parseStatus(coldBootStatus(["read_verified": true, "write_verified": true]))
        check(true, "current explicit read/write check accepted")
        for missing in ["device", "present", "error", "state", "stage", "usb_active", "usb_held"] {
            reject("incomplete cold-boot identity or health: " + missing) {
                _ = try ReadPicoUSBTransferClient.parseStatus(coldBootStatus(removing: [missing]))
            }
        }
        for missing in ["present", "error", "state", "stage", "usb_active", "usb_held"] {
            reject("partial metadata cannot be bypassed by verified flags: " + missing) {
                _ = try ReadPicoUSBTransferClient.parseStatus(coldBootStatus(["read_verified": true, "write_verified": true], removing: [missing]))
            }
        }
        for changes: [String: Any] in [
            ["present": false], ["present": 1], ["present": NSNull()], ["device": 1],
            ["mounted": false], ["storage_busy": true], ["error": 1], ["error": false],
            ["state": 2], ["state": 7], ["state": 8], ["state": 9], ["state": true], ["state": 3.5],
            ["stage": 0], ["stage": 5], ["stage": 6], ["stage": 8], ["stage": true],
            ["usb_active": true], ["usb_held": true], ["exported": true], ["exported": 0],
            ["read_verified": true], ["write_verified": true]
        ] {
            reject("unhealthy/malformed cold-boot status") { _ = try ReadPicoUSBTransferClient.parseStatus(coldBootStatus(changes)) }
        }
        for changes: [String: Any] in [["present": false], ["error": 1], ["state": 7], ["state": 8], ["stage": 5], ["stage": 8], ["exported": true]] {
            var stale = changes; stale["read_verified"] = true; stale["write_verified"] = true
            reject("stale verified flags cannot hide a failed/currently busy state") {
                _ = try ReadPicoUSBTransferClient.parseStatus(coldBootStatus(stale))
            }
        }
        reject("legacy unverified card remains rejected") {
            _ = try ReadPicoUSBTransferClient.parseStatus(status().replacingOccurrences(of: "\"read_verified\":true", with: "\"read_verified\":false"))
        }
        try ReadPicoUSBTransferClient.parseAcknowledgement("RPICO {\"accepted\":true}\n")
        check(true, "complete positive acknowledgement")
        try ReadPicoUSBTransferClient.parseAcknowledgement("RPICO {\"accepted\":true}\r\n")
        check(true, "real-device CRLF acknowledgement accepted")
        try ReadPicoUSBTransferClient.parseAcknowledgement("RPICO {\"accepted\":true,\"busy\":false}\r\n")
        check(true, "explicit non-busy CRLF acknowledgement accepted")
        for bad in ["{\"accepted\":true}\n", "RPICO {\"accepted\":true}", "RPICO {\"accepted\":1}\n", "RPICO {\"accepted\":false}\n", "RPICO {\"accepted\":false,\"busy\":true}\n",
                    "RPICO {\"accepted\":true,\"busy\":true}\r\n", "RPICO {\"accepted\":true,\"busy\":0}\n",
                    "RPICO {\"accepted\":true,\"busy\":null}\n", "RPICO {\n\"accepted\":true}\n",
                    "RPICO {\r\"accepted\":true}\n", "RPICO {\"accepted\":true}\r\r\n",
                    "RPICO {\"accepted\":true}\nRPICO {\"accepted\":true}\n",
                    "I (1) log: RPICO {\"accepted\":true}\r\n", "RPICO {\"accepted\":true} trailing\r\n"] {
            reject("incomplete/negative acknowledgement") { try ReadPicoUSBTransferClient.parseAcknowledgement(bad) }
        }
        for bad in [status().replacingOccurrences(of: "\"route\":3", with: "\"route\":true"),
                    status().replacingOccurrences(of: "\"mounted\":true", with: "\"mounted\":1"),
                    status().replacingOccurrences(of: "read-pico", with: "another-device"),
                    status().replacingOccurrences(of: "\"write_verified\":true", with: "\"write_verified\":false"),
                    status(",\"usb_held\":true"), status(",\"usb_active\":true"), status(",\"usb_active\":1"),
                    "RPICO {\"mounted\":true}\n"] {
            reject("unsafe storage status") { _ = try ReadPicoUSBTransferClient.parseStatus(bad) }
        }
        let port = "/dev/cu.usbmodem-offline-test"
        let lease = try ReadPicoUSBSerialLease.acquire(path: port)
        reject("shared lease conflict") { _ = try ReadPicoUSBSerialLease.acquire(path: port) }
        lease.release(); lease.release()
        do { let another = try ReadPicoUSBSerialLease.acquire(path: port); another.release() }
        let gate = Gate(), client = ReadPicoUSBTransferClient { _, cancelled in try await gate.run(cancelled) }
        let task = Task { try await client.start(port: port) }
        while !(await gate.running) { try await Task.sleep(nanoseconds: 1_000_000) }
        reject("firmware cannot claim while handoff waits") { _ = try ReadPicoUSBSerialLease.acquire(path: port) }
        task.cancel()
        await rejectAsync("cancelled handoff") { _ = try await task.value }
        do { let released = try ReadPicoUSBSerialLease.acquire(path: port); released.release(); check(true, "cancel releases lease after transport returns") }
        let failed = ReadPicoUSBTransferClient { _, _ in throw ReadPicoUSBTransferError.unavailable("timeout") }
        await rejectAsync("transport timeout") { _ = try await failed.start(port: port) }
        do { let released = try ReadPicoUSBSerialLease.acquire(path: port); released.release(); check(true, "timeout releases serial lease") }
        let success = ReadPicoUSBTransferClient { _, _ in .init(deviceIdentity: "offline-fixture") }
        check(try await success.start(port: port).deviceIdentity == "offline-fixture", "accepted handoff returns after transport closes")
        await rejectAsync("path traversal") { _ = try await success.start(port: "/dev/cu.usbmodem/../../other") }
        let acceptedGate = AcceptedGate()
        let justAccepted = ReadPicoUSBTransferClient { _, cancelled in await acceptedGate.returnAfterCancellation(cancelled) }
        let acceptedTask = Task { try await justAccepted.start(port: port) { await acceptedGate.recordAcknowledgement() } }
        while !(await acceptedGate.running) { try await Task.sleep(nanoseconds: 1_000_000) }
        acceptedTask.cancel()
        await rejectAsync("cancelled wait after real acknowledgement") { _ = try await acceptedTask.value }
        check(await acceptedGate.acknowledged, "received ACK callback survives concurrent cancellation")
        do { let released = try ReadPicoUSBSerialLease.acquire(path: port); released.release(); check(true, "post-ACK cancellation releases lease") }

        let files = FileManager.default, temp = files.temporaryDirectory.appendingPathComponent("pico-tf-handoff-" + UUID().uuidString)
        try files.createDirectory(at: temp, withIntermediateDirectories: true); defer { try? files.removeItem(at: temp) }
        let root = temp.appendingPathComponent("card"), input = temp.appendingPathComponent("input.txt")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("书的正文".utf8).write(to: input)
        let store = try ReadPicoTFStore(rootURL: root)
        _ = try await store.importFile(input, kind: .book)
        let items = try await store.scan()
        check(items.count == 1 && items[0].relativePath == "books/input.txt", "normal import uses firmware visible book root")
        reject("nested directory selection") { _ = try ReadPicoTFStore(rootURL: root.appendingPathComponent("books")) }
        let oldRoot = temp.appendingPathComponent("removed-card")
        try files.moveItem(at: root, to: oldRoot)
        await rejectAsync("detached card scan") { _ = try await store.scan() }
        await rejectAsync("detached card write") { _ = try await store.importFile(input, kind: .book) }
        check(!files.fileExists(atPath: root.path), "write cannot recreate removed mountpoint")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        await rejectAsync("different card at same mountpoint") { _ = try await store.importFile(input, kind: .book) }
        check((try files.contentsOfDirectory(atPath: root.path)).isEmpty, "replacement directory untouched")
        let fresh = try ReadPicoTFStore(rootURL: root)
        _ = try await fresh.importFile(input, kind: .book)
        check(try await fresh.scan().count == 1, "explicit reselect permits newly mounted card")
        print("PASS: \(checks) USB protocol, shared-port cancellation, volume identity and detached TF checks; no physical USB or mounted card accessed.")
    }
}
