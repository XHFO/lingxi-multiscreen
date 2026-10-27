import Foundation

private var checks = 0
private func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
private func rejected(_ expected: ReadPicoFirmwareUSBRecovery.RecoveryError, _ body: () async throws -> Void) async {
    do { try await body(); fatalError("Expected \(expected)") }
    catch let error as ReadPicoFirmwareUSBRecovery.RecoveryError { check(error == expected, "Expected \(expected), received \(error)") }
    catch { fatalError("Unexpected failure: \(error)") }
}
private typealias Recovery = ReadPicoFirmwareUSBRecovery
private final class Fixture: @unchecked Sendable {
    let lock = NSLock()
    var volumes: [ReadPicoMountedVolume] = [], descriptors: [String: Recovery.USBDescriptor] = [:]
    var ports: [String] = [], identities: [String: String] = [:]
    var elapsed: TimeInterval = 0, waits = 0, ejects: [ReadPicoMountedVolume] = [], ejectError: Error?
    var onWait: (@Sendable (Fixture) -> Void)?
    func client() -> Recovery { Recovery(environment: .init(
        volumes: { self.lock.withLock { self.volumes } },
        descriptor: { url in self.lock.withLock { self.descriptors[url.path] } },
        ports: { self.lock.withLock { self.ports } },
        serialIdentity: { port in self.lock.withLock { self.identities[port] } },
        eject: { volume in try self.lock.withLock {
            self.ejects.append(volume)
            if let error = self.ejectError { throw error }
            self.volumes.removeAll { $0.identity == volume.identity && $0.rootURL == volume.rootURL }
        } },
        now: { self.lock.withLock { self.elapsed } },
        wait: {
            try Task.checkCancellation()
            self.lock.withLock { self.elapsed += 0.2; self.waits += 1 }
            self.onWait?(self)
            await Task.yield()
        })) }
    func add(_ name: String, serial: String, folders: Bool = false) -> ReadPicoMountedVolume {
        let volume = ReadPicoMountedVolume(rootURL: URL(fileURLWithPath: "/offline-recovery-fixture/" + name), name: name,
                                          capacity: 64_000_000_000, free: 50_000_000_000,
                                          readOnly: false, hasPicoFolders: folders, identity: "uuid-" + name)
        volumes.append(volume)
        descriptors[volume.rootURL.path] = .init(vendorID: 0x303a, productID: 0x4002, product: "Read Pico TF", serial: serial)
        return volume
    }
}
@main struct USBRecoveryTests {
    static func main() async throws {
        let mac = "14C19FD14CE4", otherMAC = "AABBCCDDEEFF"
        let descriptor = Recovery.USBDescriptor(vendorID: 0x303a, productID: 0x4002, product: "Read Pico TF", serial: "14:c1:9f:d1:4c:e4")
        check(descriptor.picoIdentity == mac, "Complete CDC/MSC MAC forms normalize to one hardware identity")
        for invalid in [
            Recovery.USBDescriptor(vendorID: 0xffff, productID: 0x4002, product: "Read Pico TF", serial: mac),
            Recovery.USBDescriptor(vendorID: 0x303a, productID: 0xffff, product: "Read Pico TF", serial: mac),
            Recovery.USBDescriptor(vendorID: 0x303a, productID: 0x4002, product: "Other product", serial: mac),
            Recovery.USBDescriptor(vendorID: 0x303a, productID: 0x4002, product: "Read Pico TF ", serial: mac),
            Recovery.USBDescriptor(vendorID: 0x303a, productID: 0x4002, product: "Read Pico TF", serial: "14C19F"),
            Recovery.USBDescriptor(vendorID: 0x303a, productID: 0x4002, product: "Read Pico TF", serial: " " + mac),
            Recovery.USBDescriptor(vendorID: 0x303a, productID: 0x4002, product: "Read Pico TF", serial: "")
        ] { check(invalid.picoIdentity == nil, "All USB descriptor fields and the complete serial are required") }

        let metadata = Fixture(), validVolume = metadata.add("NO NAME", serial: mac)
        let unrelated = metadata.add("Read Pico TF", serial: otherMAC, folders: true)
        metadata.descriptors[unrelated.rootURL.path] = nil
        check(metadata.client().candidates().map(\.volume) == [validVolume], "Volume label and Pico folders never establish USB hardware identity")

        let multiple = Fixture(), firstVolume = multiple.add("first", serial: mac), secondVolume = multiple.add("second", serial: otherMAC)
        let choices = multiple.client().candidates()
        check(choices.count == 2 && Set(choices.map(\.id)).count == 2, "Multiple verified Picos remain separate user-selectable choices")
        let selected = choices.first { $0.volume == secondVolume }!
        multiple.ports = ["/dev/cu.usbmodem-unrelated"]
        multiple.identities[multiple.ports[0]] = mac
        multiple.onWait = { f in f.lock.withLock {
            if f.waits == 2 { f.ports.append("/dev/cu.usbmodem-chosen"); f.identities["/dev/cu.usbmodem-chosen"] = "aa:bb:cc:dd:ee:ff" }
        } }
        let connected = try await multiple.client().recover(selected)
        check(connected == "/dev/cu.usbmodem-chosen" && multiple.waits == 2, "An unrelated CDC arrival is ignored until the chosen MAC returns")
        check(multiple.ejects == [secondVolume] && multiple.volumes == [firstVolume], "Only the explicitly chosen original volume is passed to safe eject")

        let changed = Fixture(), changedVolume = changed.add("changed", serial: mac)
        let changedChoice = changed.client().candidates()[0]
        changed.descriptors[changedVolume.rootURL.path] = .init(vendorID: 0x303a, productID: 0x4002, product: "Read Pico TF", serial: otherMAC)
        await rejected(.changedDevice) { _ = try await changed.client().recover(changedChoice) }
        check(changed.ejects.isEmpty && changed.waits == 0, "USB ancestry is rechecked before eject and no replacement device is touched")
        let replaced = Fixture(), replacedVolume = replaced.add("replaced", serial: mac)
        let replacedChoice = replaced.client().candidates()[0]
        replaced.volumes = [.init(rootURL: replacedVolume.rootURL, name: "same label", capacity: replacedVolume.capacity,
                                  free: 1, readOnly: false, hasPicoFolders: true, identity: "different-uuid")]
        await rejected(.changedDevice) { _ = try await replaced.client().recover(replacedChoice) }
        check(replaced.ejects.isEmpty, "A replaced disk at the old mount path cannot be ejected")

        let busy = Fixture(); _ = busy.add("busy", serial: mac); busy.ejectError = POSIXError(.EBUSY)
        let busyChoice = busy.client().candidates()[0]
        await rejected(.diskBusy) { _ = try await busy.client().recover(busyChoice) }
        check(busy.waits == 0 && busy.volumes.count == 1 && busy.ejects.count == 1, "Busy eject leaves storage mounted and never waits for or chooses a different serial")
        busy.ejectError = nil; busy.ports = ["/dev/cu.usbmodem-retry"]; busy.identities[busy.ports[0]] = mac
        check(try await busy.client().recover(busyChoice) == busy.ports[0], "A normal user retry can recover after the host releases its disk")

        let ambiguous = Fixture(); _ = ambiguous.add("ambiguous", serial: mac)
        ambiguous.ports = ["/dev/cu.usbmodem-one", "/dev/cu.usbmodem-two"]
        for port in ambiguous.ports { ambiguous.identities[port] = mac }
        await rejected(.ambiguousSerial) { _ = try await ambiguous.client().recover(ambiguous.client().candidates()[0]) }
        check(ambiguous.waits == 0, "Duplicate matching serials fail instead of guessing")
        let timed = Fixture(); _ = timed.add("timed", serial: mac)
        timed.ports = ["/dev/cu.usbmodem-other"]; timed.identities[timed.ports[0]] = otherMAC
        await rejected(.timeout) { _ = try await timed.client().recover(timed.client().candidates()[0], timeout: 90) }
        check(timed.elapsed >= 30 && timed.elapsed < 30.3 && timed.ejects.count == 1, "CDC wait is bounded to 30 seconds even when a longer limit is requested")

        let cancelled = Fixture(); _ = cancelled.add("cancelled", serial: mac)
        let selectedCancel = cancelled.client().candidates()[0]
        let task = Task { try await cancelled.client().recover(selectedCancel) }
        while cancelled.lock.withLock({ cancelled.waits == 0 }) { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; fatalError("Expected cancellation") } catch is CancellationError { checks += 1 }
        check(cancelled.ejects.count == 1, "Cancelling the bounded wait never retries disk eject or starts a firmware helper")
        print("PASS USB firmware recovery: \(checks) checks; injected USB metadata/eject/clock only, no physical disk or serial accessed.")
    }
}
