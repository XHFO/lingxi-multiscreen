import CoreGraphics
import Foundation
import LinxDisplayCore

private var checks = 0
@MainActor private func check(_ value: Bool, _ text: String) { checks += 1; precondition(value, text) }
@MainActor private func idle(_ model: ReadPicoManagerModel) async throws {
    for _ in 0..<3000 { if !model.busy { return }; try await Task.sleep(nanoseconds: 1_000_000) }
    fatalError("USB model did not finish")
}
private let livePower = ReadPicoPowerStatus(known: true, charging: true, batteryPercent: 73, revision: 5, externalPower: true)

private final class USBFixture: @unchecked Sendable {
    private let lock = NSLock()
    let card: ReadPicoMountedVolume, unrelated: ReadPicoMountedVolume
    let port = "/dev/cu.usbmodem-one-click-fixture"
    let identity: String
    let mountedIdentity: String
    private var mounted = false, extraPort = false
    private var usbPresentation = 0
    private var initialStarts = 0, boardStarts = 0, ejects = 0
    private var directSends = 0
    private var directPayload = Data(), requestedDisplay = false
    private var displayed = "", events: [String] = []
    init(card: URL, other: URL, identity: String = "one-click-reader", mountedIdentity: String? = nil) {
        self.identity = identity; self.mountedIdentity = mountedIdentity ?? identity
        self.card = .init(rootURL: card, name: "Card", capacity: 100_000_000, free: 90_000_000,
                          readOnly: false, hasPicoFolders: false, identity: "fixture-original-volume")
        unrelated = .init(rootURL: other, name: "Unrelated", capacity: 100_000_000, free: 80_000_000,
                          readOnly: false, hasPicoFolders: true, identity: "fixture-unrelated-volume")
    }
    func setMultiple() { lock.withLock { extraPort = true } }
    func setUSBPresentation(_ value: Int) { lock.withLock { usbPresentation = value } }
    func portIdentity(_ candidate: String) -> String? {
        lock.withLock {
            if usbPresentation == 2 { return nil }
            return candidate == port + "-foreign" ? "unrelated-device" : identity
        }
    }
    func volumes() -> [ReadPicoMountedVolume] { lock.withLock { mounted ? [unrelated, card] : [unrelated] } }
    func ports() -> [String] {
        lock.withLock {
            if usbPresentation == 1 { return [] }
            if usbPresentation == 3 { return [port + "-foreign"] }
            return extraPort ? [port, port + "-second"] : [port]
        }
    }
    func usbIdentity(_ root: URL) -> String? { root.path == card.rootURL.path ? mountedIdentity : nil }
    func start() -> ReadPicoUSBStartResult { lock.withLock { initialStarts += 1; mounted = true; events.append("prepare"); return .init(deviceIdentity: identity, backgroundSupported: true, power: livePower) } }
    func boardStart() { lock.withLock { boardStarts += 1; mounted = true; events.append("board-start") } }
    func eject(_ root: URL) throws {
        try lock.withLock {
            precondition(root.path == card.rootURL.path, "An unrelated disk must never be ejected")
            ejects += 1; mounted = false; events.append("eject")
            let packet = root.appendingPathComponent("readpico/desktop/usb-board.pcb")
            if FileManager.default.fileExists(atPath: packet.path) {
                let data = try Data(contentsOf: packet)
                displayed = String(decoding: data[24..<56], as: UTF8.self)
                try FileManager.default.removeItem(at: packet)
            }
        }
    }
    func status() -> ReadPicoUSBBoardStatus { lock.withLock { .init(taskID: displayed, state: displayed.isEmpty ? "idle" : "displayed", power: livePower, directProtocol: 1, chunkBytes: 1024, displayIntent: true) } }
    func direct(_ data: Data, display: Bool) -> ReadPicoUSBBoardReceipt {
        lock.withLock {
            directSends += 1; directPayload = data; requestedDisplay = display; events.append("direct")
            displayed = String(repeating: "a", count: 32)
            return .init(taskID: displayed, state: display ? "displayed" : "saved", power: livePower)
        }
    }
    func directResult() -> (Int, Data, Bool) { lock.withLock { (directSends, directPayload, requestedDisplay) } }
    func counts() -> (Int, Int, Int) { lock.withLock { (initialStarts, boardStarts, ejects) } }
    func order() -> [String] { lock.withLock { events } }
    func client() -> ReadPicoUSBBoardClient {
        .init(environment: .init(ports: { self.ports() }, identity: { self.portIdentity($0) }, volumes: { self.volumes() },
                               status: { _ in self.status() }, start: { _ in self.boardStart() }, ejectRetryWait: { _ in },
                               direct: { _, data, display, _ in self.direct(data, display: display) }))
    }
    @MainActor func model(mapped: Bool = true) -> ReadPicoManagerModel {
        .init(usbClient: .init { _, _ in self.start() }, discoverVolumes: { self.volumes() }, discoverUSBPorts: { self.ports() },
              identifyUSBPort: { self.portIdentity($0) }, ejectVolume: { try self.eject($0) },
              volumeUSBIdentity: { mapped ? self.usbIdentity($0) : nil }, boardClient: client(), readUSBPower: { _ in livePower })
    }
}
private actor DelayedCapabilities: ReadPicoManagerDeviceClient {
    var pending: CheckedContinuation<ReadPicoCapabilities, Never>?
    var shouldPause = false
    var entered = false
    func home() async throws -> ReadPicoHomeSnapshot {
        try JSONDecoder().decode(ReadPicoHomeSnapshot.self, from: Data("{\"config\":{\"enabled\":false,\"local\":\"\",\"external\":\"\",\"home_wifi\":\"\",\"external_enabled\":false,\"external_control\":false,\"has_token\":false},\"saved_wifi\":[],\"network_online\":true}".utf8))
    }
    func value() throws -> ReadPicoCapabilities {
        try JSONDecoder().decode(ReadPicoCapabilities.self, from: Data("{\"protocol\":1,\"canvas\":{\"supported\":true,\"width\":684,\"height\":1216,\"formats\":[\"image/bmp\"],\"maxBytes\":420000,\"max_bytes\":420000,\"gray_levels\":16,\"bit_depths\":[1,4],\"state\":\"displayed\",\"revision\":1},\"power\":{\"known\":true,\"charging\":true,\"external_power\":true,\"battery_percent\":73,\"revision\":5}}".utf8))
    }
    func capabilities() async throws -> ReadPicoCapabilities {
        if shouldPause { entered = true; return await withCheckedContinuation { pending = $0 } }
        return try value()
    }
    func pause() { shouldPause = true }
    func waitForRead() async { while !entered { await Task.yield() } }
    func release() throws { pending?.resume(returning: try value()); pending = nil; shouldPause = false }
    func saveHome(_ config: ReadPicoHomeConfiguration, token: String) async throws {}
    func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities { try value() }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities { try value() }
}
@main struct USBOneClickModelTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pico-one-click-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func fixture(_ name: String, identity: String = "one-click-reader", mountedIdentity: String? = nil) throws -> USBFixture {
            let card = root.appendingPathComponent(name + "-card"), other = root.appendingPathComponent(name + "-other")
            for url in [card, other] { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
            return .init(card: card, other: other, identity: identity, mountedIdentity: mountedIdentity)
        }
        let matches = ReadPicoManagerModel.usbBoardVolumeIdentityMatches
        check(matches("12ABCDEF3456", "12:AB:CD:EF:34:56"), "MSC compact MAC matches CDC colon MAC")
        check(matches("12:ab:cd:ef:34:56", "12ABCDEF3456"), "Reversed MAC presentation and lowercase match")
        check(matches("12abcdef3456", "12ABCDEF3456"), "Complete compact ASCII MAC is case-insensitive")
        check(matches("12:ab:cd:ef:34:56", "12:AB:CD:EF:34:56"), "Complete colon ASCII MAC is case-insensitive")
        check(matches("one-click-reader", "one-click-reader"), "Non-MAC serial remains exactly comparable")
        check(!matches("One-Click-Reader", "one-click-reader"), "Non-MAC serial comparison remains case-sensitive")
        check(!matches("12AB-CDEF-3456", "12:AB:CD:EF:34:56"), "Hyphens cannot be filtered from arbitrary serials")
        check(!matches("12:AB:CD:EF:34:57", "12ABCDEF3456"), "A distinct hardware MAC cannot match")
        check(!matches(" 12ABCDEF3456", "12:AB:CD:EF:34:56"), "Whitespace cannot be removed from registry serials")
        check(!matches("usb-12ABCDEF3456", "12:AB:CD:EF:34:56"), "Prefix-bearing serial cannot match a MAC substring")
        check(!matches("12:AB:C:DEF:34:56", "12ABCDEF3456"), "MAC colon grouping must be exactly six pairs")
        check(!matches("12:AB:CD:EF:34:5G", "12ABCDEF3456"), "Only ASCII hexadecimal MAC digits are accepted")
        check(!matches("12ＡＢＣＤＥＦ3456", "12:AB:CD:EF:34:56"), "Unicode lookalike digits cannot identify a reader")
        check(!matches(nil, "12:AB:CD:EF:34:56"), "Unknown mounted registry identity cannot match")
        let cg = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        cg.setFillColor(CGColor(gray: 0.4, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let bmp = try ReadPicoBitmap.makeGray16(image: cg.makeImage()!, width: 684, height: 1216)
        let formatted = try fixture("formatted", identity: "12:AB:CD:EF:34:56", mountedIdentity: "12abcdef3456")
        let formattedModel = formatted.model()
        formattedModel.prepareUSBBoardConnection(); try await idle(formattedModel)
        check(formattedModel.store == nil && !formattedModel.usbBoardNeedsSelection && formatted.counts() == (0, 0, 0),
              "Preparing USB board only verifies capabilities, never mounts or ejects TF")
        var formattedSent = false
        formattedModel.sendUSBBoard(bmp) { formattedSent = $0 }; try await idle(formattedModel)
        check(formattedSent && formatted.directResult().0 == 1 && formatted.directResult().1 == bmp && formatted.counts() == (0, 0, 0), "Native direct route keeps TF local and preserves exact pixels")
        let wrongSerial = try fixture("wrong-card-serial", identity: "one-click-reader", mountedIdentity: "One-Click-Reader")
        let wrongSerialModel = wrongSerial.model()
        var differentCardSucceeded = false
        wrongSerialModel.sendUSBBoard(bmp) { differentCardSucceeded = $0 }; try await idle(wrongSerialModel)
        check(differentCardSucceeded && wrongSerial.directResult().0 == 1 && wrongSerial.counts() == (0, 0, 0),
              "Direct board delivery does not depend on TF registry labels or historical model binding")
        let single = try fixture("single"), model = single.model()
        var success = false, completionCount = 0
        model.sendBoard(bmp, display: true) { success = $0; completionCount += 1 }
        try await idle(model)
        check(success && completionCount == 1 && !model.isError, "One click confirms direct board delivery")
        check(single.counts() == (0, 0, 0) && single.directResult().2, "Manual show intent reaches direct sender without MSC preparation")
        check(single.order() == ["direct"] && single.directResult().1 == bmp, "Only direct transfer occurs")
        check(model.store == nil && !model.waitingForUSBVolume && model.usbBoardProgress == nil, "Direct completion leaves no transient TF state")
        check(model.powerStatus == livePower && model.powerStatusReceivedAt != nil, "Final USB receipt supplies actual power telemetry")
        check(model.boardConnectionIdentity == "usb:one-click-reader", "Destination identity is current USB service, independent of card")
        check(!fm.fileExists(atPath: single.unrelated.rootURL.appendingPathComponent("readpico").path), "Unrelated mounted volume is never selected or written")
        model.prepareUSBBoardConnection(); try await idle(model)
        check(single.counts() == (0, 0, 0), "Repeated connection checks never start file transfer")
        let confirmedDestination = model.boardConnectionIdentity
        single.setUSBPresentation(1); await model.refreshCardAvailability()
        check(!model.hasUSBBoardConnectionCandidate && model.boardConnectionIdentity == nil, "Disconnected reader cannot reuse old display identity")
        single.setUSBPresentation(2); await model.refreshCardAvailability()
        check(model.boardConnectionIdentity == nil, "Unidentified USB modem cannot reuse old display identity")
        single.setUSBPresentation(3); await model.refreshCardAvailability()
        check(model.boardConnectionIdentity == nil, "Replacement serial does not inherit old pixel receipt")
        model.boardTransportPreference = .usb
        model.sendUSBBoard(bmp); try await idle(model)
        check(single.directResult().0 == 2 && model.boardConnectionIdentity == "usb:unrelated-device", "Explicit USB route accepts a capability-compatible replacement instead of rejecting old MAC mismatch")
        single.setUSBPresentation(0); await model.refreshCardAvailability()
        model.sendUSBBoard(bmp); try await idle(model)
        check(model.boardConnectionIdentity == confirmedDestination, "Switching the physical reader back obtains a freshly verified destination")
        let multiple = try fixture("multiple"), multiModel = multiple.model(); multiple.setMultiple()
        multiModel.sendUSBBoard(bmp); try await idle(multiModel)
        check(multiModel.usbBoardNeedsSelection && multiple.directResult().0 == 0, "Multiple devices require explicit choice before any send")
        multiModel.selectUSBBoard(port: multiple.port); try await idle(multiModel)
        multiModel.sendUSBBoard(bmp); try await idle(multiModel)
        check(multiple.directResult().0 == 1 && !multiModel.usbBoardNeedsSelection, "Explicit selected compatible target works with multiple connected readers")
        let unknown = try fixture("unknown-card-map"), unknownModel = unknown.model(mapped: false)
        unknownModel.sendUSBBoard(bmp); try await idle(unknownModel)
        check(unknown.directResult().0 == 1 && unknownModel.store == nil && unknown.counts() == (0, 0, 0), "Missing TF map is irrelevant to direct USB push")
        let entry = try fixture("file-management"), entryModel = entry.model()
        _ = entry.start(); entryModel.selectCard(entry.card.rootURL); try await idle(entryModel)
        entryModel.boardTransportPreference = .usb
        entryModel.sendUSBBoard(bmp); try await idle(entryModel)
        check(entry.directResult().0 == 1 && entry.counts() == (1, 0, 1), "Existing file management is safely ended once, with no subsequent remount or MSC restart")
        let dirty = try fixture("dirty"), dirtyModel = dirty.model(); dirtyModel.pendingLockImage = Data([1])
        dirtyModel.sendUSBBoard(bmp); dirtyModel.prepareUSBBoardConnection(); try await idle(dirtyModel)
        check(dirty.directResult().0 == 1 && dirtyModel.pendingLockImage == Data([1]), "Direct board delivery preserves independent pending lock-image draft")

        let endpoint = "http://one-click-offline/manage#key=" + String(repeating: "a", count: 32)
        let device = DelayedCapabilities(), http = ReadPicoManagerModel(
            discoverVolumes: { [] }, discoverUSBPorts: { ["/dev/cu.usbmodem-unrelated"] },
            identifyUSBPort: { _ in "unrelated-device" }, makeClient: { _ in device })
        http.connect(address: endpoint, key: ""); try await idle(http)
        check(http.powerStatus == livePower && http.powerStatusReceivedAt != nil, "HTTP connect consumes the optional real power snapshot")
        let wifiDestination = http.boardConnectionIdentity
        await http.refreshCardAvailability()
        check(!http.hasUSBBoardConnectionCandidate, "An unrelated visible USB modem does not override a paired Wi-Fi reader")
        check(http.boardConnectionIdentity == wifiDestination && wifiDestination?.hasPrefix("wifi:") == true, "Wi-Fi keeps its display identity when an unrelated USB modem is present")
        check(http.boardConnectionIdentity?.contains(String(repeating: "a", count: 32)) == false, "Destination identity never contains a temporary setup key")
        http.prepareUSBBoardConnection(); check(http.connection != nil && !http.busy, "Automatic preparation preserves an active Wi-Fi management session")
        let previousDestination = http.boardConnectionIdentity
        http.connect(address: endpoint, key: ""); try await idle(http)
        check(http.boardConnectionIdentity != previousDestination, "Re-pairing the same IP obtains a new non-secret display destination generation")
        await device.pause()
        let sample = Task { await http.refreshDevicePowerStatus() }
        await device.waitForRead()
        http.disconnect(); check(http.powerStatus == nil && http.powerStatusReceivedAt == nil, "Disconnect clears power freshness with its session")
        try await device.release(); await sample.value
        check(http.powerStatus == nil, "Late HTTP power sample cannot contaminate a replacement or disconnected session")
        let fresh = Date(); http.acceptPowerStatus(livePower, receivedAt: fresh)
        let older = ReadPicoPowerStatus(known: true, charging: false, batteryPercent: 22, revision: 1, externalPower: false)
        http.acceptPowerStatus(older, receivedAt: fresh.addingTimeInterval(-1))
        check(http.powerStatus == livePower && http.powerStatusReceivedAt == fresh, "Out-of-order telemetry cannot replace newer freshness")
        print("PASS direct USB ManagerModel: \(checks) checks; production direct BoardClient/display intent/current compatible target; zero implicit MSC handoffs, temporary fixture directories only, no hardware/network/user settings")
    }
}
