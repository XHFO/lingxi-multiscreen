import Foundation
import LinxDisplayCore

private var checks = 0
@MainActor private func check(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
@MainActor private func idle(_ model: ReadPicoManagerModel) async throws {
    for _ in 0..<1000 { if !model.busy { return }; try await Task.sleep(nanoseconds: 2_000_000) }
    fatalError("model never returned idle")
}
private final class Fixture: @unchecked Sendable {
    private let lock = NSLock()
    var volumes: [ReadPicoMountedVolume] = []
    var ports = ["/dev/cu.usbmodem-offline-pico"]
    var identity: String? = "pico-serial-a"
    var failEject = false
    private var starts = 0
    func listVolumes() -> [ReadPicoMountedVolume] { lock.lock(); defer { lock.unlock() }; return volumes }
    func listPorts() -> [String] { lock.lock(); defer { lock.unlock() }; return ports }
    func identify(_ port: String) -> String? { lock.lock(); defer { lock.unlock() }; return identity }
    func start() -> ReadPicoUSBStartResult { lock.lock(); defer { lock.unlock() }; starts += 1; return .init(deviceIdentity: identity) }
    func startCount() -> Int { lock.lock(); defer { lock.unlock() }; return starts }
    func eject(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        if failEject { throw ReadPicoUSBTransferError.unavailable("fixture busy") }
        volumes.removeAll { $0.rootURL == url }
    }
}
private actor LateACK {
    var entered = false
    func result(_ cancelled: @escaping @Sendable () -> Bool) async -> ReadPicoUSBStartResult {
        entered = true
        while !cancelled() { try? await Task.sleep(nanoseconds: 1_000_000) }
        return .init()
    }
}
@main struct USBModelTests {
    @MainActor static func main() async throws {
        let fixture = Fixture(), port = fixture.ports[0]
        let model = ReadPicoManagerModel(usbClient: .init { _, _ in fixture.start() },
                                        discoverVolumes: { fixture.listVolumes() }, discoverUSBPorts: { fixture.listPorts() },
                                        identifyUSBPort: { fixture.identify($0) }, ejectVolume: { try fixture.eject($0) })
        await model.refreshCardAvailability()
        check(model.usbPorts == [port] && model.mountedVolumes.isEmpty, "serial presence is separate from a mounted TF card")
        check(model.automaticUSBPreparationCandidate(selectedPort: "") == port && !model.isTrustedUSBPort(port), "first device requires product confirmation")
        model.markAutomaticUSBPreparationAttempt(port: port)
        check(model.automaticUSBPreparationCandidate(selectedPort: "") == nil, "confirmation cancellation does not loop each tick")
        model.resumeAutomaticUSBPreparation()
        model.home.enabled = true
        model.startUSB(port: port)
        check(!model.busy && fixture.startCount() == 0 && model.home.enabled, "pending settings cannot be dropped by USB auto preparation")
        model.home.enabled = false
        let key = String(repeating: "a", count: 32)
        model.connection = try ReadPicoConnection(address: "http://offline-fixture/manage#key=" + key)
        model.startUSB(port: port); try await idle(model)
        check(fixture.startCount() == 1 && model.waitingForUSBVolume && model.store == nil, "positive ACK only starts volume wait")
        check(model.connection == nil && model.capability == nil && model.isTrustedUSBPort(port), "accepted USB handoff invalidates Wi-Fi session and remembers registry identity")
        await model.refreshCardAvailability(now: Date().addingTimeInterval(31))
        check(model.cardError && model.cardMessage.contains("尚未挂载") && model.cardMessage.contains("串口"), "configured device is not reported as a mounted card")
        model.stopWaitingForUSB()
        check(!model.waitingForUSBVolume && model.automaticUSBPreparationCandidate(selectedPort: port) == nil, "stop wait recovers UI and prevents immediate auto retry")
        model.resumeAutomaticUSBPreparation()
        check(model.automaticUSBPreparationCandidate(selectedPort: port) == port, "next intentional entry can retry")
        fixture.identity = "pico-serial-b"
        check(!model.isTrustedUSBPort(port), "different device at same serial path requires confirmation")
        fixture.identity = nil
        check(!model.isTrustedUSBPort(port), "missing USB identity never inherits trust")
        fixture.identity = "pico-serial-a"

        let files = FileManager.default, temp = files.temporaryDirectory.appendingPathComponent("pico-usb-model-" + UUID().uuidString).resolvingSymlinksInPath()
        try files.createDirectory(at: temp, withIntermediateDirectories: true); defer { try? files.removeItem(at: temp) }
        let a = temp.appendingPathComponent("card-a"), b = temp.appendingPathComponent("card-b")
        for root in [a, b] { try files.createDirectory(at: root, withIntermediateDirectories: true) }
        try Data("正文".utf8).write(to: a.appendingPathComponent("book.txt"))
        fixture.volumes = [.init(rootURL: a, name: "TF A", capacity: 32_000_000_000, free: 31_000_000_000, readOnly: false, hasPicoFolders: true, identity: "volume-a"),
                           .init(rootURL: b, name: "Other disk", capacity: 64_000_000_000, free: 50_000_000_000, readOnly: false, hasPicoFolders: false, identity: "volume-b")]
        await model.refreshCardAvailability()
        check(model.mountedVolumes.count == 2 && model.store == nil, "even plausible Pico folders do not silently bind a volume")
        model.selectCard(a); try await idle(model)
        check(model.files.count == 1 && model.canEjectCard && model.store?.rootURL.path == a.path, "user selection establishes actual TF store")
        fixture.failEject = true
        model.ejectCard(); try await idle(model)
        check(model.isError && model.store != nil && model.files.count == 1 && model.message.contains("未能安全弹出"), "failed host eject retains selected card and real error")
        fixture.failEject = false
        model.ejectCard(); try await idle(model)
        check(!model.isError && model.store == nil && model.files.isEmpty && model.message.contains("安全弹出"), "successful host eject releases UI only after completion")
        check(model.automaticUSBPreparationCandidate(selectedPort: port) == nil, "safe eject does not immediately reopen USB")
        fixture.volumes.append(.init(rootURL: a, name: "TF A reconnected", capacity: 32_000_000_000, free: 30_000_000_000, readOnly: false, hasPicoFolders: true, identity: "volume-a"))
        model.resumeAutomaticUSBPreparation(); await model.refreshCardAvailability(); try await idle(model)
        check(model.store?.rootURL.path == a.path, "same confirmed volume UUID and capacity can reconnect within the device session")
        model.forgetCard(); fixture.identity = "another-pico-at-same-port"
        model.startUSB(port: port); try await idle(model)
        await model.refreshCardAvailability(); try await idle(model)
        check(model.store == nil && model.mountedVolumes.count == 2, "new USB identity cannot inherit and automatically bind the previous device card")
        model.selectCard(a); try await idle(model)
        model.forgetCard(); fixture.identity = nil
        model.startUSB(port: port); try await idle(model)
        await model.refreshCardAvailability(); try await idle(model)
        check(model.store == nil, "unidentified USB handoff cannot inherit a previous card binding")
        model.selectCard(a); try await idle(model)
        try files.moveItem(at: a, to: temp.appendingPathComponent("removed-a"))
        await model.refreshCardAvailability()
        check(model.store == nil && model.files.isEmpty && model.cardError, "physical removal clears stale store and operations")
        model.deactivate()
        check(!model.waitingForUSBVolume && !model.isTrustedUSBPort(port), "ending device session drops transient USB trust")
        try await verifyAutomaticHandoffLifetime(in: temp)
        let late = LateACK()
        let cancelling = ReadPicoManagerModel(usbClient: .init { _, cancelled in await late.result(cancelled) },
                                             discoverVolumes: { [] }, discoverUSBPorts: { [port] }, identifyUSBPort: { _ in "late-ack-device" })
        cancelling.connection = try ReadPicoConnection(address: "http://offline-fixture/manage#key=" + key)
        cancelling.startUSB(port: port)
        while !(await late.entered) { try await Task.sleep(nanoseconds: 1_000_000) }
        cancelling.cancelOperation(); try await idle(cancelling)
        check(!cancelling.busy && cancelling.waitingForUSBVolume && cancelling.connection == nil,
              "received ACK still clears Wi-Fi and waits for TF when user cancels concurrently")
        check(cancelling.message.contains("已停止等待") && cancelling.automaticUSBPreparationCandidate(selectedPort: port) == nil,
              "concurrent cancellation states uncertainty and cannot trigger automatic duplicate START")
        print("PASS: \(checks) actual USB manager start, automatic intent, identity, mount, eject, timeout and removal checks; no physical device accessed.")
    }

    @MainActor private static func verifyAutomaticHandoffLifetime(in temp: URL) async throws {
        let fixture = Fixture(), firstPort = fixture.ports[0], returnedPort = firstPort + "-returned"
        let root = temp.appendingPathComponent("handoff-card"), detached = temp.appendingPathComponent("handoff-detached")
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fixture book".utf8).write(to: root.appendingPathComponent("book.txt"))
        let volume = ReadPicoMountedVolume(rootURL: root, name: "Handoff TF", capacity: 32_000_000_000,
                                          free: 31_000_000_000, readOnly: false, hasPicoFolders: true, identity: "handoff-volume")
        let model = ReadPicoManagerModel(usbClient: .init { _, _ in fixture.start() },
                                        discoverVolumes: { fixture.listVolumes() }, discoverUSBPorts: { fixture.listPorts() },
                                        identifyUSBPort: { fixture.identify($0) }, ejectVolume: { try fixture.eject($0) },
                                        volumeUSBIdentity: { _ in fixture.identify("") })
        await model.refreshCardAvailability()
        check(model.automaticUSBPreparationCandidate(selectedPort: firstPort) == firstPort, "new file-page intent can prepare USB")
        model.startUSB(port: firstPort); try await idle(model)
        fixture.ports = []; fixture.volumes = [volume]
        await model.refreshCardAvailability(); try await idle(model)
        check(model.store != nil && fixture.startCount() == 1, "accepted handoff may remove CDC while its TF volume is adopted")

        // Drop only the UI selection, leaving the ACK consumed. This isolates the
        // CDC-cycle guard from the separate volume-loss recovery below.
        model.forgetCard(); fixture.volumes = []; fixture.ports = [returnedPort]
        for _ in 0..<4 { await model.refreshCardAvailability() }
        check(model.automaticUSBPreparationCandidate(selectedPort: returnedPort) == nil && fixture.startCount() == 1,
              "accepted MSC handoff consumes automatic intent across CDC removal and a renumbered return")

        // A user action is allowed to connect again without needing to reset the
        // auto state; its accepted request consumes the next handoff as well.
        model.startUSB(port: returnedPort); try await idle(model)
        fixture.ports = []; fixture.volumes = [volume]
        await model.refreshCardAvailability(); try await idle(model)
        check(model.store != nil && fixture.startCount() == 2, "explicit connection can resume a paused automatic handoff")
        try files.moveItem(at: root, to: detached)
        fixture.volumes = []; fixture.ports = [returnedPort]
        await model.refreshCardAvailability()
        check(model.store == nil && model.cardError && model.automaticUSBPreparationCandidate(selectedPort: returnedPort) == nil,
              "external safe eject releases stale content and pauses automatic reopening")
        try files.moveItem(at: detached, to: root)
        fixture.volumes = [volume]
        for _ in 0..<4 { await model.refreshCardAvailability() }
        check(model.store == nil && fixture.startCount() == 2,
              "external volume reappearance cannot silently resume a paused file session")
        model.resumeAutomaticUSBPreparation()
        await model.refreshCardAvailability(); try await idle(model)
        check(model.store?.rootURL.path == root.path, "a fresh file-page intent can explicitly resume its previously confirmed volume")

        // A TF volume may also have been selected while already exported, without
        // this model issuing START. Host eject must pause that path independently.
        model.forgetCard(); model.resumeAutomaticUSBPreparation(); model.selectCard(root); try await idle(model)
        try files.moveItem(at: root, to: detached)
        fixture.volumes = []
        await model.refreshCardAvailability()
        check(model.automaticUSBPreparationCandidate(selectedPort: returnedPort) == nil,
              "external eject of an already-exported selected volume pauses even without a local START")
        model.resumeAutomaticUSBPreparation()
        check(model.automaticUSBPreparationCandidate(selectedPort: returnedPort) == returnedPort,
              "reentering file management explicitly renews automatic preparation after external eject")
        model.deactivate()
    }
}
