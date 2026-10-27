import CoreGraphics
import Foundation
import LinxDisplayCore

private final class Fixture: @unchecked Sendable {
    let lock = NSLock(), port = "/dev/cu.usbmodem-wireless-fixture", identity = "AABBCCDDEEFF"
    let root: URL
    var online = true, mounted = false, ejectFails = false, registryIdentity = "AA:BB:CC:DD:EE:FF", block = false
    var operations: [String] = [], starts = 0, ejects = 0, display = "", serialOverMount = false, joins = 0
    var now = Date(timeIntervalSince1970: 1000)
    init(root: URL) throws { self.root = root; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func modify(_ body: (Fixture) -> Void) { lock.lock(); body(self); lock.unlock() }
    func snapshot() -> ([String], Int, Int, Bool, Int) { lock.withLock { (operations, starts, ejects, serialOverMount, joins) } }
    func clock() -> Date { lock.withLock { now } }
    func registry() -> String { lock.withLock { registryIdentity } }
    func volumes() -> [ReadPicoMountedVolume] { lock.withLock { mounted ? [.init(rootURL: root, name: "Fixture", capacity: 100000000, free: 90000000, readOnly: false, hasPicoFolders: false, identity: "temporary-card")] : [] } }
    func run(_ action: ReadPicoUSBWirelessAction, cancelled: @escaping @Sendable () -> Bool) async throws -> ReadPicoUSBWirelessResult {
        while lock.withLock({ block }) { if cancelled() { throw CancellationError() }; try await Task.sleep(nanoseconds: 1_000_000) }
        return try lock.withLock {
            if mounted { serialOverMount = true; throw ReadPicoUSBWirelessError.busy }
            switch action {
            case .status:
                operations.append("status")
                return .status(.init(identity: identity, ready: true, enabled: true, connected: online, ip: online ? "192.168.1.25" : "", ssid: online ? "Home" : "", busy: false))
            case .open:
                operations.append("open"); guard online else { throw ReadPicoUSBWirelessError.networkRequired }
                return .management(management())
            case .scan:
                operations.append("scan")
                return .networks([.init(ssid: "Home", rssi: -40, requiresPassword: true, supported: true), .init(ssid: "Unsupported", rssi: -60, requiresPassword: true, supported: false)])
            case .connect(let ssid, let password):
                operations.append("connect"); joins += 1
                guard ssid == "Home", password == "fixture-password" else { throw ReadPicoUSBWirelessError.failed }
                online = true; return .management(management())
            }
        }
    }
    private func management() -> ReadPicoUSBWirelessManagement { .init(identity: identity, url: URL(string: "http://192.168.1.25/")!, key: String(repeating: "a", count: 32), ttlSeconds: 900) }
    func start() -> ReadPicoUSBStartResult { lock.withLock { starts += 1; mounted = true; return .init(deviceIdentity: identity, backgroundSupported: true) } }
    func eject(_ url: URL) throws {
        try lock.withLock {
            precondition(url.standardizedFileURL == root.standardizedFileURL)
            if ejectFails { throw ReadPicoUSBWirelessError.busy }
            ejects += 1; mounted = false
            let packet = root.appendingPathComponent("readpico/desktop/usb-board.pcb")
            if FileManager.default.fileExists(atPath: packet.path) {
                let bytes = try Data(contentsOf: packet); display = String(decoding: bytes[24..<56], as: UTF8.self)
                try FileManager.default.removeItem(at: packet)
            }
        }
    }
    func boardStatus() -> ReadPicoUSBBoardStatus { lock.withLock { .init(taskID: display, state: display.isEmpty ? "idle" : "displayed") } }
    @MainActor func model(_ http: Device) -> ReadPicoManagerModel {
        .init(usbClient: .init { _, _ in self.start() }, wirelessClient: .init { _, _, action, cancelled in try await self.run(action, cancelled: cancelled) },
              discoverVolumes: { self.volumes() }, discoverUSBPorts: { [self.port] }, identifyUSBPort: { _ in self.registry() },
              ejectVolume: { try self.eject($0) }, volumeUSBIdentity: { _ in self.identity },
              boardClient: .init(environment: .init(ports: { [self.port] }, identity: { _ in self.registry() }, volumes: { self.volumes() }, status: { _ in self.boardStatus() }, start: { _ in self.modify { $0.mounted = true } }, ejectRetryWait: { _ in })),
              boardNow: { self.clock() }, wirelessResumeWait: 0.02, makeClient: { _ in http })
    }
}
private actor Device: ReadPicoManagerDeviceClient {
    enum Failure { case none, offline, auth, post, authAfterPost }
    var failure = Failure.none, pushes = 0, reads = 0
    private var receiptState = "displayed", foreignRevision = 0
    func set(_ value: Failure) { failure = value }
    func setReceipt(_ value: String, foreignRevision: Int = 0) { receiptState = value; self.foreignRevision = foreignRevision }
    func count() -> Int { pushes }
    func readCount() -> Int { reads }
    func home() async throws -> ReadPicoHomeSnapshot {
        let config = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ReadPicoHomeConfiguration()))
        return try JSONDecoder().decode(ReadPicoHomeSnapshot.self, from: JSONSerialization.data(withJSONObject: ["config":config,"saved_wifi":["Home"],"network_online":true]))
    }
    func capabilities() async throws -> ReadPicoCapabilities {
        reads += 1
        if failure == .offline { throw URLError(.cannotConnectToHost) }
        if failure == .auth { throw ReadPicoManagerError.expired }
        return try value()
    }
    func value() throws -> ReadPicoCapabilities {
        try JSONDecoder().decode(ReadPicoCapabilities.self, from: JSONSerialization.data(withJSONObject: ["protocol":1,"canvas":["supported":true,"width":684,"height":1216,"formats":["image/bmp"],"max_bytes":420000,"gray_levels":16,"bit_depths":[1,4],"state":receiptState,"revision":1+pushes+foreignRevision],"config":["auto_sleep_minutes":5,"double_tap_wake":true,"state":0,"revision":1]]))
    }
    func saveHome(_ config: ReadPicoHomeConfiguration, token: String) async throws {}
    func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities { try value() }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities {
        pushes += 1; await onAccepted?()
        if failure == .post { throw URLError(.networkConnectionLost) }
        if failure == .authAfterPost { throw ReadPicoManagerError.expired }
        return try value()
    }
}
@main struct USBWirelessModelTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ text: String) { checks += 1; precondition(value, text) }
        func idle(_ model: ReadPicoManagerModel) async throws {
            for _ in 0..<5000 { if !model.busy { return }; try await Task.sleep(nanoseconds: 1_000_000) }
            fatalError("model did not finish")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pico-wireless-model-"+UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func fixture(_ name: String) throws -> Fixture { try .init(root: root.appendingPathComponent(name)) }
        let device = Device(), live = try fixture("online"), model = live.model(device)
        check(model.autoConnectWireless(), "one click begins")
        try await idle(model)
        check(model.connection?.baseURL.host == "192.168.1.25" && model.provisioningPhase == .connected && !model.isError, "USB actual address is HTTP authenticated")
        check(live.snapshot().0 == ["status","open"], "already online avoids Wi-Fi scan and password")
        model.home.enabled = true; model.homeToken = "unsaved-token"; model.deviceConfiguration.autoSleepMinutes = 30
        check(model.autoConnectWireless(), "healthy session can verify with drafts")
        try await idle(model)
        check(model.home.enabled && model.homeToken == "unsaved-token" && model.deviceConfiguration.autoSleepMinutes == 30, "healthy reuse preserves both drafts")
        check(live.snapshot().0 == ["status","open"], "healthy authenticated reuse does not reopen USB")
        model.transportPreference = .usb; model.boardTransportPreference = .wifi
        check(model.transportPreference == .usb && model.boardTransportPreference == .wifi, "Board mode is independent from file choice")
        model.discardPendingDeviceChanges()

        let offline = try fixture("offline"), offlineDevice = Device(); offline.modify { $0.online = false }
        let setup = offline.model(offlineDevice)
        setup.autoConnectWireless(); try await idle(setup)
        check(setup.provisioningPhase == .selectNetwork && setup.wirelessNetworks.count == 2, "offline automatically scans device networks")
        check(!setup.joinWirelessNetwork(ssid: "Unsupported", password: ""), "unsupported enterprise network refused before password")
        check(offline.snapshot().4 == 0, "no unsupported password command")
        check(setup.joinWirelessNetwork(ssid: "Home", password: "fixture-password"), "network form begins join")
        try await idle(setup)
        check(setup.connection != nil && setup.provisioningPhase == .connected && offline.snapshot().4 == 1, "join automatically HTTP pairs")
        check(!setup.wirelessStatus.contains("fixture-password") && !setup.message.contains(String(repeating:"a",count:32)), "status text contains no credentials")
        let changed = try fixture("changed"), changedDevice = Device(); changed.modify { $0.online = false }
        let changedModel = changed.model(changedDevice); changedModel.autoConnectWireless(); try await idle(changedModel)
        changed.modify { $0.registryIdentity = "112233445566" }
        changedModel.joinWirelessNetwork(ssid: "Home", password: "fixture-password"); try await idle(changedModel)
        check(changedModel.isError && changed.snapshot().4 == 0, "renamed/different USB registry prevents secret command")

        let mounted = try fixture("mounted"), mountedDevice = Device(); mounted.modify { $0.mounted = true }
        let mountedModel = mounted.model(mountedDevice); mountedModel.selectCard(mounted.root); try await idle(mountedModel)
        mountedModel.autoConnectWireless(); try await idle(mountedModel)
        check(mountedModel.connection != nil && mountedModel.store == nil && mounted.snapshot().2 == 1, "automatic wireless safely ejects mapped TF first")
        check(!mounted.snapshot().3, "no serial runner while host filesystem mounted")
        let ejectFailure = try fixture("eject-failure"), ejectDevice = Device(); ejectFailure.modify { $0.mounted = true; $0.ejectFails = true }
        let ejectModel = ejectFailure.model(ejectDevice); ejectModel.selectCard(ejectFailure.root); try await idle(ejectModel)
        ejectModel.autoConnectWireless(); try await idle(ejectModel)
        check(ejectModel.store != nil && ejectModel.isError && ejectFailure.snapshot().0.isEmpty, "failed safe eject retains storage and sends zero USB wireless commands")
        let cancel = try fixture("cancel"), cancelDevice = Device(); cancel.modify { $0.block = true }
        let cancelModel = cancel.model(cancelDevice); cancelModel.autoConnectWireless()
        try await Task.sleep(nanoseconds: 20_000_000); cancelModel.cancelOperation(); try await idle(cancelModel)
        check(cancelModel.provisioningPhase == .idle && !cancelModel.busy, "cancel releases wireless operation and serial lease")
        cancel.modify { $0.block = false }; cancelModel.autoConnectWireless(); try await idle(cancelModel)
        check(cancelModel.connection != nil, "subsequent same-port setup succeeds after cancellation")

        let cg = CGContext(data:nil,width:16,height:16,bitsPerComponent:8,bytesPerRow:16,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue)!
        cg.setFillColor(CGColor(gray:0.4,alpha:1));cg.fill(CGRect(x:0,y:0,width:16,height:16))
        let bmp = try ReadPicoBitmap.makeGray16(image:cg.makeImage()!,width:684,height:1216)
        let fresh = try fixture("fresh-board"), freshDevice = Device(), freshModel = fresh.model(freshDevice)
        var sent = false
        freshModel.transportPreference = .wifi
        freshModel.sendBoard(bmp) { sent = $0 }; try await idle(freshModel)
        check(sent && fresh.snapshot().1 == 1 && !freshModel.boardSubmissionUncertain, "first explicit no-LAN send prepares sole trusted USB and confirms display")
        check(freshModel.transportPreference == .wifi, "USB Board does not overwrite file-only Wi-Fi preference")
        let saved = try fixture("saved-LAN"), savedDevice = Device(), savedModel = saved.model(savedDevice)
        savedModel.autoConnectWireless(); try await idle(savedModel)
        await savedDevice.setReceipt("saved")
        savedModel.sendBoard(bmp) { sent = $0 }; try await idle(savedModel)
        let receiptID = savedModel.boardDelivery!.id
        check(sent && !savedModel.boardSubmissionUncertain && savedModel.boardDelivery?.displayed == false && savedModel.message.contains("尚未显示"), "LAN saved clears delivery uncertainty without display confirmation")
        let stillSaved = try await savedModel.refreshBoardDelivery(receiptID)
        let savedPushCount = await savedDevice.count()
        check(stillSaved?.displayed == false && savedPushCount == 1 && saved.snapshot().1 == 0, "Saved LAN receipt polling never resends or starts USB")
        await savedDevice.setReceipt("displayed")
        let confirmedSaved = try await savedModel.refreshBoardDelivery(receiptID)
        check(confirmedSaved?.id == receiptID && confirmedSaved?.displayed == true, "Same exact LAN revision later confirms display")
        await savedDevice.setReceipt("saved")
        savedModel.sendBoard(bmp) { sent = $0 }; try await idle(savedModel)
        let supersededID = savedModel.boardDelivery!.id
        await savedDevice.setReceipt("displayed", foreignRevision: 1)
        do { _ = try await savedModel.refreshBoardDelivery(supersededID); fatalError("Foreign revision confirmed saved frame") }
        catch { check(savedModel.boardDelivery?.displayed == false, "Another displayed revision never confirms this saved frame") }
        savedModel.deactivate()
        check(try await savedModel.refreshBoardDelivery(supersededID) == nil, "Ended owner cannot sample or acknowledge a saved receipt")
        let route = try fixture("routing"), routeDevice = Device(), routeModel = route.model(routeDevice)
        routeModel.transportPreference = .usb; routeModel.autoConnectWireless(); try await idle(routeModel)
        routeModel.sendBoard(bmp) { sent = $0 }; try await idle(routeModel)
        let observedCount1 = await routeDevice.count()
        check(sent && observedCount1 == 1 && route.snapshot().1 == 0, "auto Board uses validated LAN even when files prefer USB")
        route.modify { $0.now = $0.now.addingTimeInterval(20) }; await routeDevice.set(.offline)
        routeModel.sendBoard(bmp) { sent = $0 }; try await idle(routeModel)
        check(sent && route.snapshot().1 == 1 && routeModel.connection != nil, "offline authenticated preflight uses only same-device USB fallback and retains session")
        await routeDevice.set(.none)
        routeModel.sendBoard(bmp) { sent = $0 }; try await idle(routeModel)
        let observedCount2 = await routeDevice.count()
        check(sent && observedCount2 == 2 && route.snapshot().1 == 1, "next boundary after USB returns automatically to recovered LAN")
        check(routeModel.transportPreference == .usb, "all Board route changes preserve file choice")
        route.modify { $0.now = $0.now.addingTimeInterval(20); $0.online = false }; await routeDevice.set(.offline)
        routeModel.sendBoard(bmp) { sent = $0 }; try await idle(routeModel)
        check(sent && route.snapshot().1 == 2, "second real LAN outage still uses USB")
        routeModel.sendBoard(bmp) { sent = $0 }; try await idle(routeModel)
        check(sent && route.snapshot().1 == 3 && routeModel.boardLANState == .offline, "STA offline during self-induced key renewal remains same-device USB fallback")
        let beforeOfflineRepeat = route.snapshot().0.count
        routeModel.sendBoard(bmp) { sent = $0 }; try await idle(routeModel)
        check(sent && route.snapshot().1 == 4 && route.snapshot().0.count == beforeOfflineRepeat, "offline repeated sends do not reopen wireless setup before bounded retry interval")
        routeModel.boardTransportPreference = .wifi
        routeModel.sendBoard(bmp) { sent = $0 }; try await idle(routeModel)
        check(!sent && route.snapshot().1 == 4, "explicit Wi-Fi preference never lowers to USB while STA offline")
        routeModel.boardTransportPreference = .automatic
        route.modify { $0.now = $0.now.addingTimeInterval(20); $0.online = true }; await routeDevice.set(.none)
        routeModel.sendBoard(bmp) { sent = $0 }; try await idle(routeModel)
        let afterRejoinCount = await routeDevice.count()
        check(sent && afterRejoinCount == 3 && route.snapshot().1 == 4, "renewal retry automatically returns to LAN after STA recovery")

        route.modify { $0.now = $0.now.addingTimeInterval(20) }; await routeDevice.set(.auth)
        routeModel.sendBoard(bmp) { sent = $0 }; try await idle(routeModel)
        check(!sent && route.snapshot().1 == 4 && !routeModel.boardSubmissionUncertain && routeModel.boardLANState == .authenticationRequired, "expired authentication requires reconnect and never falls back USB")

        let uncertain = try fixture("uncertain"), uncertainDevice = Device(), uncertainModel = uncertain.model(uncertainDevice)
        uncertainModel.autoConnectWireless(); try await idle(uncertainModel); await uncertainDevice.set(.post)
        uncertainModel.sendBoard(bmp) { sent = $0 }; try await idle(uncertainModel)
        let observedCount3 = await uncertainDevice.count()
        check(!sent && uncertainModel.boardSubmissionUncertain && observedCount3 == 1 && uncertain.snapshot().1 == 0, "lost POST acknowledgement records uncertainty without USB replay")
        uncertainModel.sendBoard(bmp); try await idle(uncertainModel)
        let observedCount4 = await uncertainDevice.count()
        check(observedCount4 == 1 && uncertain.snapshot().1 == 0, "uncertain repeated send is blocked")
        await uncertainDevice.set(.none); uncertainModel.autoConnectWireless(); try await idle(uncertainModel)
        check(uncertainModel.boardSubmissionUncertain, "healthy read and session verification cannot clear uncertain submission")
        uncertainModel.reconcileBoardSubmission(); uncertainModel.sendBoard(bmp) { sent = $0 }; try await idle(uncertainModel)
        let observedCount5 = await uncertainDevice.count()
        check(sent && !uncertainModel.boardSubmissionUncertain && observedCount5 == 2, "explicit reader-result reconciliation permits next send")

        await uncertainDevice.set(.authAfterPost)
        uncertainModel.sendBoard(bmp) { sent = $0 }; try await idle(uncertainModel)
        check(!sent && uncertainModel.boardSubmissionUncertain, "authentication lost after accepted POST keeps uncertainty and forbids replay")
        uncertainModel.sendUSBBoard(bmp); uncertainModel.pushUSBBoard(bmp); try await idle(uncertainModel)
        let compatibilityCount = await uncertainDevice.count()
        check(compatibilityCount == 3 && uncertain.snapshot().1 == 0, "legacy USB aliases cannot bypass pending display acknowledgement")

        let wrong = try fixture("wrong-fallback"), wrongDevice = Device(), wrongModel = wrong.model(wrongDevice)
        wrongModel.autoConnectWireless(); try await idle(wrongModel)
        wrong.modify { $0.registryIdentity = "112233445566"; $0.now = $0.now.addingTimeInterval(20) }; await wrongDevice.set(.offline)
        wrongModel.sendBoard(bmp) { sent = $0 }; try await idle(wrongModel)
        check(!sent && wrong.snapshot().1 == 0, "paired LAN never falls back to different attached Pico")
        let seamless = try fixture("storage-to-LAN"), seamlessDevice = Device(), seamlessModel = seamless.model(seamlessDevice)
        seamlessModel.autoConnectWireless(); try await idle(seamlessModel)
        seamless.modify { $0.mounted = true }; seamlessModel.selectCard(seamless.root); try await idle(seamlessModel)
        seamlessModel.sendBoard(bmp) { sent = $0 }; try await idle(seamlessModel)
        let observedCount6 = await seamlessDevice.count()
        check(sent && seamlessModel.store == nil && seamless.snapshot().2 == 1 && observedCount6 == 1, "explicit LAN Board send safely returns mapped USB TF and renews management before sending")
        check(!seamless.snapshot().3 && seamless.snapshot().0 == ["status","open","status","open"], "TF-to-LAN transition never overlaps filesystem and serial or reuses expired setup key")
        print("PASS USB wireless + LAN-first Manager: \(checks) checks; injected device/registry and actual production USB Board commit to temporary TF only")
    }
}
