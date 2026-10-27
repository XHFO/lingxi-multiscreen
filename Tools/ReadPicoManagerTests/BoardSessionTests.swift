import AppKit
import Foundation
import LinxDisplayCore

private actor BoardSessionDevice: ReadPicoManagerDeviceClient {
    private var frames: [Data] = []
    private var appFrames = 0
    private var channels: [ReadPicoContentChannel] = []
    func deliveredChannels() -> [ReadPicoContentChannel] { channels }
    private var gated = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var failing = false
    private var saved = false
    private var gateNextCapability = false
    private var capabilityEntered = false
    private var capabilityContinuation: CheckedContinuation<Void, Never>?
    func configure(gated: Bool = false, failing: Bool = false, saved: Bool = false) { self.gated = gated; self.failing = failing; self.saved = saved }
    func confirmDisplay() { saved = false }
    func count() -> Int { frames.count }
    func lastFrame() -> Data? { frames.last }
    func release() { gated = false; continuation?.resume(); continuation = nil }
    func holdNextCapability() { gateNextCapability = true; capabilityEntered = false }
    func waitForHeldCapability() async throws {
        for _ in 0..<1000 {
            if capabilityEntered { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw ReadPicoManagerError.invalid("Receipt capability did not enter its isolated gate")
    }
    func releaseCapability() { capabilityContinuation?.resume(); capabilityContinuation = nil }
    func home() async throws -> ReadPicoHomeSnapshot {
        let config = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ReadPicoHomeConfiguration()))
        return try JSONDecoder().decode(ReadPicoHomeSnapshot.self, from: JSONSerialization.data(withJSONObject: ["config": config, "saved_wifi": [], "network_online": true]))
    }
    func saveHome(_ config: ReadPicoHomeConfiguration, token: String) async throws {}
    func capabilities() async throws -> ReadPicoCapabilities {
        if gateNextCapability {
            gateNextCapability = false; capabilityEntered = true
            // Deliberately return late even after cancellation to exercise stale-read isolation.
            await withCheckedContinuation { capabilityContinuation = $0 }
        }
        return try JSONDecoder().decode(ReadPicoCapabilities.self, from: JSONSerialization.data(withJSONObject: [
            "protocol": 1, "canvas": ["supported": true, "width": 684, "height": 1216,
                "formats": ["image/bmp"], "max_bytes": 420000, "gray_levels": 16,
                "bit_depths": [1, 4], "display_intent": true, "dual_orientation": true, "pair_max_bytes": 840032,
                "state": saved && !frames.isEmpty ? "saved" : "displayed", "revision": 1 + frames.count,
                "app_channels": ["cloudflare"], "app_receipts": ["cloudflare": ["state": saved && appFrames > 0 ? "saved" : "displayed", "revision": 1 + appFrames, "orientation": "portrait"]]]
        ]))
    }
    func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities { try await capabilities() }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability,
                             onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities {
        frames.append(bmp); channels.append(.canvas)
        if let onAccepted { await onAccepted() }
        if gated { await withCheckedContinuation { continuation = $0 } }
        if failing { throw ReadPicoManagerError.unavailable("设备未确认显示测试画面") }
        return try await capabilities()
    }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, display: Bool,
                             contentChannel: ReadPicoContentChannel,
                             onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities {
        if contentChannel == .canvas { return try await pushCanvasConfirmed(bmp, capability: capability, onAccepted: onAccepted) }
        frames.append(bmp); channels.append(contentChannel); appFrames += 1
        await onAccepted?()
        if gated { await withCheckedContinuation { continuation = $0 } }
        if failing { throw ReadPicoManagerError.unavailable("设备未确认显示测试画面") }
        return try await capabilities()
    }
}

private actor BoardDirectProbe {
    private var frames: [Data] = []
    func push(_ bitmap: Data) -> ReadPicoUSBBoardReceipt {
        frames.append(bitmap)
        return .init(taskID: String(repeating: "d", count: 32), state: "saved")
    }
    func count() -> Int { frames.count }
}

private final class BoardOwnerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var discoveries = 0, starts = 0
    func ports() -> [String] {
        lock.withLock { discoveries += 1; return ["/dev/cu.usbmodem-owner-b-fixture"] }
    }
    func start() -> ReadPicoUSBStartResult {
        lock.withLock { starts += 1; return .init(deviceIdentity: "reader-b") }
    }
    var counts: (Int, Int) { lock.withLock { (discoveries, starts) } }
}

@main struct BoardSessionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) { checks += 1; precondition(condition(), label) }
        func idle(_ manager: ReadPicoManagerModel) async throws {
            for _ in 0..<500 { if !manager.busy { return }; try await Task.sleep(nanoseconds: 5_000_000) }
            fatalError("device operation timed out")
        }
        func received(_ count: Int, from device: BoardSessionDevice, line: UInt = #line) async throws {
            for _ in 0..<500 { if await device.count() >= count { return }; try await Task.sleep(nanoseconds: 5_000_000) }
            let actual = await device.count()
            fatalError("device request not received: call line \(line), expected \(count), received \(actual)")
        }
        func scheduled(_ session: ReadPicoLingxiBoardSession) async throws {
            for _ in 0..<1000 {
                if session.nextUpdate != nil { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            fatalError("Automatic schedule did not release its preliminary power read")
        }
        func makeFrame(_ gray: CGFloat, width: Int = 684, height: Int = 1216) throws -> ReadPicoLingxiBoardRenderer.Result {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let bitmap = try ReadPicoBitmap.makeGray16(image: context.makeImage()!, width: width, height: height)
            return .init(bitmap: bitmap, preview: NSImage(data: bitmap)!, width: width, height: height)
        }
        func draft(_ title: String) -> ReadPicoCanvasDraft {
            let value = ReadPicoCanvasDraft(); value.canvasMode = 2; value.board.modules = [0, 1]; value.board.name = title
            return value
        }
        let first = try makeFrame(0.2), second = try makeFrame(0.8)
        check(first.bitmap != second.bitmap, "Test frames differ")
        let copySource = draft("冻结完整来源")
        copySource.image = first.preview
        copySource.strokes = [[CGPoint(x: 0.2, y: 0.3)]]
        let copied = ReadPicoLingxiBoardSession.frozenCopy(of: copySource)
        copySource.board.text = "之后的文字"; copySource.strokes[0].append(CGPoint(x: 0.8, y: 0.7))
        copySource.image = second.preview
        check(copied.board.text.isEmpty && copied.strokes[0].count == 1,
              "Frozen board options and normalized strokes do not follow later edits")
        check(copied.image != nil && copied.image !== copySource.image && copied.image?.size == first.preview.size,
              "Frozen images survive replacing the editable source")
        let device = BoardSessionDevice()
        let manager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] }, makeClient: { _ in device })
        manager.connect(address: "http://127.0.0.1/#key=" + String(repeating: "0", count: 32), key: "")
        try await idle(manager)
        check(manager.connection != nil && manager.capability?.supportsNativeGray16 == true, "Injected device connects without network")
        check(!ReadPicoLingxiBoardSession.prefersUSB(manager) && manager.boardConnectionIdentity?.hasPrefix("wifi:") == true,
              "Auto uses verified native-gray Wi-Fi and the same destination identity")
        manager.boardTransportPreference = .usb
        check(ReadPicoLingxiBoardSession.prefersUSB(manager) && manager.boardConnectionIdentity == nil,
              "Forced USB never reuses a Wi-Fi display receipt when no USB identity exists")
        manager.boardTransportPreference = .wifi
        check(!ReadPicoLingxiBoardSession.prefersUSB(manager), "Forced Wi-Fi cannot initiate USB preparation")
        let nativeCapability = manager.capability
        manager.capability = try JSONDecoder().decode(ReadPicoCanvasCapability.self, from: Data(#"{"supported":true,"width":684,"height":1216,"formats":["image/bmp"],"max_bytes":110000}"#.utf8))
        manager.boardTransportPreference = .automatic
        check(ReadPicoLingxiBoardSession.prefersUSB(manager) && manager.boardConnectionIdentity == nil,
              "Legacy Wi-Fi capability cannot label a USB transfer identity as wireless")
        manager.capability = nativeCapability

        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let charging = ReadPicoPowerStatus(known: true, charging: true, batteryPercent: 72, revision: 1, externalPower: true)
        let battery = ReadPicoPowerStatus(known: true, charging: false, batteryPercent: 72, revision: 2, externalPower: false)
        let full = ReadPicoPowerStatus(known: true, charging: false, batteryPercent: 100, revision: 3, externalPower: true)
        let unknown = ReadPicoPowerStatus(known: false, charging: false, batteryPercent: -1, revision: 4, externalPower: false)
        func cadence(_ requested: Int = -1, _ power: ReadPicoPowerStatus?, age: TimeInterval = 0, usb: Bool = false) -> Int? {
            ReadPicoBoardRefreshPolicy.effectiveInterval(requested: requested, power: power,
                receivedAt: fixedNow.addingTimeInterval(-age), usb: usb, now: fixedNow)
        }
        check(cadence(-1, charging) == 5, "Charging Wi-Fi uses five seconds")
        check(cadence(-1, charging, usb: true) == 5, "USB reuses the shared check cadence without an extra thirty second pause")
        check(cadence(-1, full) == 5, "Full external power remains fast without claiming charging")
        check(cadence(-1, battery) == 30, "Battery reuses the static ink-display content check")
        check(cadence(-1, unknown) == 30 && cadence(-1, nil) == 30, "Unknown power uses shared ink-display checks without claiming charging")
        check(cadence(-1, charging, age: 45) == 5 && cadence(-1, charging, age: 45.001) == 30,
              "Old charging telemetry expires at the explicit freshness boundary")
        check(cadence(-1, charging, age: -1) == 30, "Future telemetry is not trusted")
        check(cadence(900, charging) == 900 && cadence(5, battery) == 30 && cadence(5, charging, usb: true) == 5,
              "Explicit slower intervals persist while battery content checks are respected")
        check(ReadPicoBoardRefreshPolicy.effectiveInterval(requested: -1, power: charging,
                receivedAt: fixedNow, usb: false, now: fixedNow,
                context: .init(dynamicSeconds: 2, contentCheckSeconds: 5)) == 2,
              "Charging follows the actual software dynamic interval")
        check(ReadPicoBoardRefreshPolicy.effectiveInterval(requested: -1, power: battery,
                receivedAt: fixedNow, usb: false, now: fixedNow,
                context: .init(dynamicSeconds: 2, contentCheckSeconds: 5)) == 5,
              "Battery live content follows the common ink-display policy")
        check(cadence(0, charging) == nil && cadence(7, charging) == nil, "Manual and unsupported intervals never schedule")
        check(ReadPicoBoardRefreshPolicy.summary(requested: -1, power: full, receivedAt: fixedNow, usb: false, now: fixedNow).contains("外接供电"),
              "Full external supply has a precise status label")
        check(ReadPicoBoardRefreshPolicy.summary(requested: -1, power: charging, receivedAt: fixedNow.addingTimeInterval(-46), usb: false, now: fixedNow).contains("等待设备供电信息"),
              "Stale display never labels the device charging")

        let original = draft("发送源")
        let session = ReadPicoLingxiBoardSession()
        var supplied = first
        session.activate(manager: manager, draft: original) { supplied }
        check(session.frame?.bitmap == first.bitmap, "Preview starts with provider frame")
        await device.configure(gated: true)
        session.start(interval: 60)
        check(session.automatic && session.nextUpdate == nil, "Explicit automatic updates send first and wait for acknowledgement")
        try await received(1, from: device)
        check(manager.busy && session.lastConfirmed == nil && session.nextUpdate == nil, "Acceptance does not claim display")
        supplied = second; session.refresh()
        check(session.frame?.bitmap == first.bitmap, "Live updates cannot replace in-flight preview")
        original.board.text = "较新的编辑"
        session.edited()
        check(session.automatic && session.frame?.bitmap == first.bitmap, "Edit preserves the enabled automatic source and the in-flight preview")
        session.disappear()
        check(manager.busy && !manager.cancelling, "Leaving editor does not cancel a submitted frame")
        check(session.automatic && session.nextUpdate == nil, "Leaving during submission preserves automatic work while awaiting the display acknowledgement")
        await device.release(); try await idle(manager)
        let receivedFirst = await device.lastFrame()
        check(receivedFirst == first.bitmap, "Transport receives the exact frozen preview")
        check(session.lastConfirmed != nil && session.automatic, "Offscreen display acknowledgement continues the app-owned automatic session")
        check(original.hasUnsavedChanges, "Acknowledgement never confirms newer edits")
        original.board.text = ""
        check(!original.hasUnsavedChanges, "Only the frozen original source was acknowledged")
        session.stop()
        check(!session.automatic && session.nextUpdate == nil, "Explicit stop clears background automatic work")

        let releasedDraft = draft("View已释放")
        var releasedSession: ReadPicoLingxiBoardSession? = ReadPicoLingxiBoardSession()
        weak var weakSession = releasedSession
        releasedSession!.activate(manager: manager, draft: releasedDraft) { second }
        await device.configure(gated: true)
        releasedSession!.send(); try await received(2, from: device)
        releasedSession!.disappear(); releasedSession = nil
        check(weakSession == nil, "Pending completion does not retain the editor")
        await device.release(); try await idle(manager)
        check(!releasedDraft.hasUnsavedChanges, "Frozen source is acknowledged even after editor deallocation")

        let previousDraft = draft("旧上下文"), replacementDraft = draft("新上下文")
        let replacementSession = ReadPicoLingxiBoardSession()
        replacementSession.activate(manager: manager, draft: previousDraft) { first }
        await device.configure(gated: true)
        replacementSession.send(); try await received(3, from: device)
        replacementSession.activate(manager: manager, draft: replacementDraft) { second }
        await device.release(); try await idle(manager)
        check(!previousDraft.hasUnsavedChanges, "Old completion confirms only old frozen source")
        check(replacementDraft.hasUnsavedChanges && replacementSession.lastConfirmed == nil, "Old completion cannot confirm replacement context")
        check(replacementSession.frame?.bitmap == second.bitmap, "Replacement context keeps its own preview")

        var changingFrame = first
        let visibleDraft = draft("可见草稿")
        let visibleSession = ReadPicoLingxiBoardSession()
        visibleSession.activate(manager: manager, draft: visibleDraft) { changingFrame }
        await device.configure(gated: true)
        visibleSession.send(); try await received(4, from: device)
        changingFrame = second; visibleDraft.board.text = "发送期间编辑"; visibleSession.edited()
        check(visibleSession.frame?.bitmap == first.bitmap, "Visible send keeps its frozen preview")
        await device.release(); try await idle(manager)
        check(visibleSession.frame?.bitmap == second.bitmap && visibleDraft.hasUnsavedChanges,
              "Confirmation releases queued preview without confirming the newer draft")
        visibleSession.disappear()

        await device.configure(gated: true)
        replacementSession.start(interval: 60); replacementSession.send(interval: 60)
        try await received(5, from: device)
        manager.cancelOperation(); await device.release(); try await idle(manager)
        check(!replacementSession.automatic && replacementSession.nextUpdate == nil, "Explicit cancellation stops automatic updates")
        check(!replacementSession.isError && replacementSession.status.contains("已停止等待"), "Cancellation retains manager's explicit non-error uncertainty")
        check(replacementSession.lastConfirmed == nil && replacementDraft.hasUnsavedChanges, "Cancellation cannot claim display or confirm the draft")

        manager.reconcileBoardSubmission()
        await device.configure(failing: true)
        replacementSession.send(); try await idle(manager)
        check(replacementSession.isError && replacementSession.status.contains("未确认显示"), "Actual failure remains a visible error")
        check(manager.boardSubmissionUncertain, "Missing display receipt requires explicit reconciliation")
        manager.reconcileBoardSubmission()
        await device.configure()
        replacementSession.send(); try await idle(manager)
        check(replacementSession.lastConfirmed != nil && !replacementSession.isError && !replacementDraft.hasUnsavedChanges, "Retry success confirms exactly its own source")
        manager.boardTransportPreference = .usb
        replacementSession.send(usb: true)
        try await idle(manager)
        check(replacementSession.isError && replacementSession.lastConfirmed != nil,
              "Missing USB reader reports a failed automatic preparation without erasing the previous receipt")
        manager.boardTransportPreference = .automatic
        // Real Session + injected HTTP transport: the timer is only installed after the device receipt.
        let automaticDraft = draft("自动供电更新")
        let automaticSession = ReadPicoLingxiBoardSession()
        automaticSession.activate(manager: manager, draft: automaticDraft) { first }
        manager.acceptPowerStatus(battery)
        await device.configure(gated: true)
        let beforeAutomatic = await device.count()
        automaticSession.start(interval: -1)
        try await received(beforeAutomatic + 1, from: device)
        automaticSession.send()
        let countDuringAutomatic = await device.count()
        check(countDuringAutomatic == beforeAutomatic + 1, "A second send cannot overlap an in-flight frame")
        check(automaticSession.nextUpdate == nil && automaticSession.lastConfirmed == nil, "No update deadline or confirmation before display acknowledgement")
        await device.release(); try await idle(manager)
        for _ in 0..<20 { if automaticSession.nextUpdate != nil { break }; await Task.yield() }
        check(automaticSession.effectiveSeconds == 30 && automaticSession.nextUpdate != nil, "Shared battery cadence begins only after acknowledgement")
        manager.acceptPowerStatus(charging)
        automaticSession.powerChanged()
        for _ in 0..<20 { if automaticSession.effectiveSeconds == 5 { break }; await Task.yield() }
        check(automaticSession.effectiveSeconds == 5, "Fresh charging projection reschedules the active session")
        let beforeSkip = await device.count()
        automaticSession.send(interval: -1)
        for _ in 0..<20 { await Task.yield() }
        let countAfterSkip = await device.count()
        check(countAfterSkip == beforeSkip && automaticSession.status.contains("没有变化"), "Automatic unchanged image skips physical transfer")
        automaticSession.send()
        try await received(beforeSkip + 1, from: device); try await idle(manager)
        let countAfterManual = await device.count()
        check(countAfterManual == beforeSkip + 1, "Manual resend is available for the same image")
        automaticSession.setInterval(0)
        check(!automaticSession.automatic && automaticSession.nextUpdate == nil, "Manual mode immediately cancels the deadline")
        automaticSession.disappear()

        // A slow USB-like handoff must not add another full update interval after its display ACK.
        let slowDraft = draft("慢传输后的尾随更新")
        let slowSession = ReadPicoLingxiBoardSession()
        var newestFrame = first
        slowSession.activate(manager: manager, draft: slowDraft,
            cadence: { .init(dynamicSeconds: 2, contentCheckSeconds: 5) }) { newestFrame }
        manager.acceptPowerStatus(charging)
        await device.configure(gated: true)
        let beforeSlow = await device.count()
        slowSession.start(interval: -1)
        try await received(beforeSlow + 1, from: device)
        newestFrame = second; slowSession.refresh()
        try await Task.sleep(nanoseconds: 2_050_000_000)
        let whileSlow = await device.count()
        check(whileSlow == beforeSlow + 1 && slowSession.nextUpdate == nil,
              "Updates coalesce while a display acknowledgement is pending")
        let releasedAt = Date()
        await device.release()
        try await received(beforeSlow + 2, from: device); try await idle(manager)
        check(Date().timeIntervalSince(releasedAt) < 1,
              "An overdue content change follows display acknowledgement without a second two-second wait")
        let newestReceived = await device.lastFrame()
        check(newestReceived == second.bitmap && slowSession.effectiveSeconds == 2,
              "Tail work renders only the latest image at the configured global interval")
        slowSession.disappear()

        let frozenDraft = draft("后台冻结源")
        frozenDraft.board.text = "启用时的内容"
        let frozenSession = ReadPicoLingxiBoardSession()
        var dynamicValue = first
        var observedFrozenText = ""
        func installFrozenEditor() {
            frozenSession.activate(manager: manager, draft: frozenDraft,
                cadence: { .init(dynamicSeconds: 2, contentCheckSeconds: 5) },
                automaticSource: {
                    let copy = ReadPicoLingxiBoardSession.frozenCopy(of: frozenDraft)
                    return .init(draft: copy, render: {
                        observedFrozenText = copy.board.text
                        return dynamicValue
                    }, cadence: { .init(dynamicSeconds: 2, contentCheckSeconds: 5) })
                }) { dynamicValue }
        }
        installFrozenEditor()
        manager.acceptPowerStatus(charging)
        frozenSession.start(interval: -1); try await idle(manager)
        let frozenReceipt = frozenSession.lastConfirmed
        check(!frozenDraft.hasUnsavedChanges && observedFrozenText == "启用时的内容",
              "First automatic display acknowledges only its exact editable source snapshot")
        frozenDraft.board.text = "尚未应用的新编辑"; frozenSession.edited()
        frozenSession.disappear()
        dynamicValue = second
        let beforeBackground = await device.count()
        try await received(beforeBackground + 1, from: device); try await idle(manager)
        check(frozenSession.automatic && observedFrozenText == "启用时的内容" && frozenDraft.hasUnsavedChanges,
              "Background updates use the frozen board with live data and never submit un-applied edits")
        installFrozenEditor()
        check(frozenSession.automatic && frozenSession.lastConfirmed != nil && frozenSession.lastConfirmed != frozenReceipt,
              "Reopening the same device preserves its automatic session and latest display receipt")
        frozenSession.start(interval: -1)
        for _ in 0..<20 { await Task.yield() }
        check(observedFrozenText == "尚未应用的新编辑", "Explicit apply replaces the automatic source")
        try await idle(manager)
        frozenSession.shutdown()
        check(!frozenSession.automatic && frozenSession.nextUpdate == nil && frozenSession.automaticModules.isEmpty,
              "Removing a managed device cancels the timer and releases the frozen source")

        let invalidSession = ReadPicoLingxiBoardSession()
        invalidSession.activate(manager: manager, draft: draft("无效渲染")) {
            throw ReadPicoManagerError.invalid("无法生成测试预览")
        }
        invalidSession.start(interval: 60)
        check(invalidSession.frame == nil && invalidSession.isError && !invalidSession.automatic && invalidSession.nextUpdate == nil,
              "Rendering failure stops automatic work and keeps its visible error")
        invalidSession.disappear()
        session.disappear(); replacementSession.disappear(); manager.deactivate()

        let ownerDevice = BoardSessionDevice(), ownerProbe = BoardOwnerProbe()
        let ownerManager = ReadPicoManagerModel(usbClient: .init { _, _ in ownerProbe.start() },
            discoverVolumes: { [] }, discoverUSBPorts: { ownerProbe.ports() }, identifyUSBPort: { _ in "reader-b" },
            readUSBPower: { _ in nil }, makeClient: { _ in ownerDevice })
        let initialOwner = ownerManager.ownerGeneration
        ownerManager.connect(address: "http://owner-a.invalid/#key=" + String(repeating: "a", count: 32), key: "")
        try await idle(ownerManager)
        check(ownerManager.ownerGeneration == initialOwner, "Pairing preserves the current device-owner lifetime")
        ownerManager.disconnect()
        check(ownerManager.ownerGeneration == initialOwner, "An ordinary connection clear does not revoke its device owner")
        ownerManager.startUSB(port: "/dev/cu.usbmodem-owner-b-fixture")
        try await idle(ownerManager)
        check(ownerManager.ownerGeneration == initialOwner && ownerManager.waitingForUSBVolume,
              "A legitimate USB handoff can clear its connection without revoking the owner")
        ownerManager.stopWaitingForUSB()
        ownerManager.connect(address: "http://owner-a.invalid/#key=" + String(repeating: "a", count: 32), key: "")
        try await idle(ownerManager)
        ownerManager.pendingLockImage = first.bitmap
        var configurationOnlySave: Bool?
        ownerManager.savePendingDeviceChanges(includeLockImage: false) { configurationOnlySave = $0 }
        check(configurationOnlySave == true && ownerManager.pendingLockImage == first.bitmap,
              "Configuration-only departure leaves a local lock image pending for explicit delivery")
        ownerManager.pendingLockImage = nil
        let ownerSession = ReadPicoLingxiBoardSession()
        let ownerDraft = draft("Owner A")
        ownerSession.activate(manager: ownerManager, draft: ownerDraft, cadence: { .init(contentCheckSeconds: 1) }) { first }
        ownerManager.acceptPowerStatus(charging)
        ownerSession.start(interval: 1); try await idle(ownerManager)
        for _ in 0..<50 { if ownerSession.nextUpdate != nil { break }; await Task.yield() }
        check(ownerSession.automatic && ownerSession.nextUpdate != nil, "Owner A has a scheduled automatic frame before leaving")
        ownerSession.disappear(); ownerManager.deactivate()
        let afterDeparture = ownerProbe.counts
        check(ownerManager.ownerGeneration != initialOwner, "Owner deactivation revokes automatic work independently of transport state")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        check(!ownerSession.automatic && ownerSession.nextUpdate == nil,
              "An offscreen timer stops when its originating device owner ends")
        check(ownerProbe.counts == afterDeparture,
              "An ended owner never discovers or claims the sole currently attached reader B")
        let beforeStaleSend = ownerProbe.counts
        ownerSession.send(interval: 1)
        check(ownerProbe.counts == beforeStaleSend && !ownerManager.busy,
              "A stale automatic send cannot start a USB operation for another reader")
        ownerSession.shutdown()

        // Background storage acknowledges delivery and advances rotation without claiming panel display.
        let savedDevice = BoardSessionDevice()
        await savedDevice.configure(saved: true)
        let savedManager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] }, makeClient: { _ in savedDevice })
        savedManager.connect(address: "http://saved.invalid/#key=" + String(repeating: "c", count: 32), key: "")
        try await idle(savedManager)
        let savedSession = ReadPicoLingxiBoardSession(), firstSavedDraft = draft("画板 A"), secondSavedDraft = draft("画板 B")
        let firstSavedID = UUID(), secondSavedID = UUID()
        var currentSavedFrame = first, renderedSecondBoard = false
        savedSession.activate(manager: savedManager, draft: firstSavedDraft, automaticSource: {
            .init(draft: firstSavedDraft, render: { currentSavedFrame }, cadence: { .init() }, boards: [
                .init(id: firstSavedID, name: "画板 A", durationSeconds: 5, draft: firstSavedDraft,
                      render: { currentSavedFrame }, cadence: { .init() }),
                .init(id: secondSavedID, name: "画板 B", durationSeconds: 5, draft: secondSavedDraft,
                      render: { renderedSecondBoard = true; return first }, cadence: { .init() })
            ])
        }) { currentSavedFrame }
        savedSession.start(interval: 60); try await idle(savedManager)
        check(savedSession.automatic && savedSession.lastConfirmed == nil && savedSession.deliveredBoardName == "画板 A" && !firstSavedDraft.hasUnsavedChanges,
              "Saved receipt confirms safe delivery and starts background rotation without claiming display")
        savedSession.send(interval: 60)
        for _ in 0..<200 { if savedSession.status.contains("不重复") { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let savedCountAfterPoll = await savedDevice.count()
        check(savedCountAfterPoll == 1 && savedSession.status.contains("不重复") && savedSession.lastConfirmed == nil,
              "Identical saved frame is checked read-only rather than repeatedly uploaded")
        currentSavedFrame = second
        savedSession.send(interval: 60); try await idle(savedManager)
        let savedCountAfterChange = await savedDevice.count()
        check(savedCountAfterChange == 2 && !renderedSecondBoard && savedSession.deliveredBoardName == "画板 A" && savedSession.lastConfirmed == nil,
              "Background live data updates within the current dwell without claiming display")
        for _ in 0..<1400 {
            if await savedDevice.count() >= 3 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await received(3, from: savedDevice); try await idle(savedManager)
        check(renderedSecondBoard && savedSession.deliveredBoardName == "画板 B" && savedSession.lastConfirmed == nil,
              "A saved-only receipt advances background rotation after dwell without requiring a page switch")
        // schedule() may first sample power; receipt reads intentionally refuse to overlap that read.
        try await scheduled(savedSession)
        await savedDevice.confirmDisplay()
        savedSession.send(interval: 60)
        for _ in 0..<200 { if savedSession.lastConfirmed != nil { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let savedCountAfterDisplay = await savedDevice.count()
        check(savedCountAfterDisplay == 3 && savedSession.lastConfirmed != nil && savedSession.deliveredBoardName == "画板 B" && !firstSavedDraft.hasUnsavedChanges,
              "Only matching actual display updates display confirmation; receipt checks do not POST again")
        savedSession.shutdown(); savedManager.deactivate()

        // Stopping and immediately restarting must revoke a saved-receipt read before its late return.
        let restartDevice = BoardSessionDevice()
        await restartDevice.configure(saved: true)
        let restartManager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] }, makeClient: { _ in restartDevice })
        restartManager.connect(address: "http://restart.invalid/#key=" + String(repeating: "e", count: 32), key: "")
        try await idle(restartManager)
        let restartSession = ReadPicoLingxiBoardSession(), restartDraft = draft("重新开启")
        var restartFrame = first
        restartSession.activate(manager: restartManager, draft: restartDraft) { restartFrame }
        restartSession.start(interval: 60); try await idle(restartManager)
        try await scheduled(restartSession)
        await restartDevice.holdNextCapability()
        restartSession.send(interval: 60)
        try await restartDevice.waitForHeldCapability()
        check(!restartManager.busy, "A held saved-receipt read does not mark the manager as a transfer")
        restartSession.stop()
        restartFrame = second
        restartSession.start(interval: 60)
        check(restartManager.busy && restartSession.automatic,
              "Immediate restart owns a new send while the canceled old read releases its resources")
        await restartDevice.releaseCapability()
        try await received(2, from: restartDevice); try await idle(restartManager)
        try await scheduled(restartSession)
        let restartedFrame = await restartDevice.lastFrame()
        check(restartSession.automatic && !restartSession.isError && restartSession.nextUpdate != nil && restartedFrame == second.bitmap,
              "A late canceled saved read cannot stop, relabel or steal scheduling from the restarted session")
        restartSession.shutdown(); restartManager.deactivate()

        // A transport change invalidates an old saved receipt even when the pixels are identical.
        let routeDevice = BoardSessionDevice(), directProbe = BoardDirectProbe()
        await routeDevice.configure(saved: true)
        let routePort = "/dev/cu.usbmodem-session-route-fixture", routeIdentity = "usb-reader-b"
        let directClient = ReadPicoUSBBoardClient(environment: .init(ports: { [routePort] }, identity: { _ in routeIdentity },
            volumes: { [] }, status: { _ in .init(taskID: String(repeating: "d", count: 32), state: "saved",
                directProtocol: 1, chunkBytes: 1024, displayIntent: true) },
            direct: { _, data, _, _ in await directProbe.push(data) }))
        let routeManager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [routePort] },
            identifyUSBPort: { _ in routeIdentity }, boardClient: directClient, readUSBPower: { _ in nil }, makeClient: { _ in routeDevice })
        routeManager.connect(address: "http://route-a.invalid/#key=" + String(repeating: "f", count: 32), key: "")
        try await idle(routeManager)
        let routeSession = ReadPicoLingxiBoardSession(), nestedDraft = draft("嵌套轮播"), otherDraft = draft("其他画板")
        nestedDraft.playlist.mode = .carousel
        nestedDraft.playlist.items = [.init(module: 5, name: "音乐"), .init(module: 0, name: "停用时钟"), .init(module: 27, name: "天气")]
        nestedDraft.playlist.items[1].enabled = false
        otherDraft.board.modules = [2]
        routeSession.activate(manager: routeManager, draft: nestedDraft, automaticSource: {
            .init(draft: nestedDraft, render: { first }, cadence: { .init() }, boards: [
                .init(id: UUID(), name: "嵌套轮播", durationSeconds: 60, draft: nestedDraft, render: { first }, cadence: { .init() }),
                .init(id: UUID(), name: "其他画板", durationSeconds: 60, draft: otherDraft, render: { second }, cadence: { .init() })
            ])
        }) { first }
        routeSession.start(interval: 60); try await idle(routeManager)
        check(routeSession.automaticModules == [2, 5, 27],
              "Automatic dependencies include all enabled nested modules and other boards while excluding disabled items")
        try await scheduled(routeSession)
        routeManager.boardTransportPreference = .usb
        routeSession.send(interval: 60); try await idle(routeManager)
        let wirelessRouteCount = await routeDevice.count(), directRouteCount = await directProbe.count()
        check(wirelessRouteCount == 1 && directRouteCount == 1 && routeManager.boardConnectionIdentity == "usb:" + routeIdentity,
              "Identical saved Wi-Fi pixels never suppress a fresh send to the currently selected USB device")
        check(routeSession.automatic && routeSession.lastConfirmed == nil && routeSession.status.contains("尚未显示"),
              "Switching saved-receipt destination confirms only background delivery to the new device")
        routeManager.boardTransportPreference = .wifi
        routeSession.send(interval: 60); try await idle(routeManager)
        try await scheduled(routeSession)
        await routeDevice.holdNextCapability()
        routeSession.send(interval: 60)
        try await routeDevice.waitForHeldCapability()
        routeManager.boardTransportPreference = .usb
        await routeDevice.releaseCapability()
        for _ in 0..<1000 {
            if await directProbe.count() == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await idle(routeManager)
        let lateWirelessRouteCount = await routeDevice.count(), lateDirectRouteCount = await directProbe.count()
        check(lateWirelessRouteCount == 2 && lateDirectRouteCount == 2 && routeSession.automatic && routeSession.lastConfirmed == nil,
              "Changing destination during an old receipt read routes a new send instead of relabeling that old receipt")
        routeSession.shutdown(); routeManager.deactivate()

        // The selected preview direction never narrows a frozen two-orientation transmission.
        let horizontalFirst = try makeFrame(0.3, width: 1216, height: 684)
        let horizontalSecond = try makeFrame(0.7, width: 1216, height: 684)
        let firstPair = try ReadPicoCanvasPair.encode(portrait: first.bitmap, landscape: horizontalFirst.bitmap)
        let changedPair = try ReadPicoCanvasPair.encode(portrait: first.bitmap, landscape: horizontalSecond.bitmap)
        let pairDevice = BoardSessionDevice()
        let pairManager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] }, makeClient: { _ in pairDevice })
        pairManager.connect(address: "http://127.0.0.1/#key=" + String(repeating: "1", count: 32), key: "")
        try await idle(pairManager)
        let pairDraft = draft("双方向同一内容")
        var pairFrame = ReadPicoLingxiBoardRenderer.Result(bitmap: first.bitmap, preview: first.preview, width: 684, height: 1216, pairedBitmap: firstPair)
        let pairSession = ReadPicoLingxiBoardSession()
        pairSession.activate(manager: pairManager, draft: pairDraft) { pairFrame }
        pairSession.start(interval: 60)
        try await received(1, from: pairDevice); try await idle(pairManager); try await scheduled(pairSession)
        let initialPair = await pairDevice.lastFrame()
        check(initialPair == firstPair, "Session transmits one complete frozen pair")
        pairFrame = .init(bitmap: horizontalFirst.bitmap, preview: horizontalFirst.preview, width: 1216, height: 684, pairedBitmap: firstPair)
        pairDraft.landscape = true
        pairSession.send(interval: 60)
        try await scheduled(pairSession)
        let afterPreviewDirection = await pairDevice.count()
        check(afterPreviewDirection == 1, "Changing preview direction does not resend an identical complete pair")
        pairFrame = .init(bitmap: first.bitmap, preview: first.preview, width: 684, height: 1216, pairedBitmap: changedPair)
        pairSession.send(interval: 60)
        try await received(2, from: pairDevice); try await idle(pairManager)
        let updatedPair = await pairDevice.lastFrame()
        check(updatedPair == changedPair, "A changed landscape layout sends a new pair even when portrait pixels are identical")
        pairSession.stop()
        let imageSource = ReadPicoCanvasDraft(); imageSource.image = first.preview; imageSource.canvasMode = 0
        pairSession.activate(manager: pairManager, draft: imageSource) { pairFrame }
        pairSession.send(); try await received(3, from: pairDevice); try await idle(pairManager)
        let imagePair = await pairDevice.lastFrame()
        check(imagePair == changedPair, "Image-source acknowledgement cannot replace the rendered pair with a single bitmap")
        pairSession.shutdown(); pairManager.deactivate()

        // Identical pixels in different destinations are independent deliveries.
        let appDevice = BoardSessionDevice()
        await appDevice.configure(saved: true)
        let appManager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] }, makeClient: { _ in appDevice })
        appManager.connect(address: "http://app.invalid/#key=" + String(repeating: "d", count: 32), key: "")
        try await idle(appManager)
        let appDraft = draft("Cloudflare 独立应用")
        var appFrame = ReadPicoLingxiBoardRenderer.Result(bitmap: first.bitmap, preview: first.preview, width: 684, height: 1216,
            pairedBitmap: firstPair, contentChannel: .cloudflare)
        let appSession = ReadPicoLingxiBoardSession()
        appSession.activate(manager: appManager, draft: appDraft) { appFrame }
        appSession.start(interval: 60); try await received(1, from: appDevice); try await idle(appManager)
        check(appManager.boardDelivery?.contentChannel == .cloudflare && appManager.boardDelivery?.displayed == false,
              "App saved receipt retains its destination without claiming display")
        appSession.send(interval: 60)
        for _ in 0..<200 { if appSession.status.contains("不重复") { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let appSavedCount = await appDevice.count()
        check(appSavedCount == 1 && appSession.status.contains("不重复"), "Saved app content is checked read-only within its own channel")
        appFrame = .init(bitmap: first.bitmap, preview: first.preview, width: 684, height: 1216, pairedBitmap: firstPair, contentChannel: .canvas)
        appSession.send(interval: 60); try await received(2, from: appDevice); try await idle(appManager)
        let differentChannelCount = await appDevice.count(), deliveredChannels = await appDevice.deliveredChannels()
        check(differentChannelCount == 2 && deliveredChannels == [.cloudflare, .canvas],
              "Same pixels moving from app to shared board are sent again to the correct destination")
        check(appManager.boardDelivery?.contentChannel == .canvas, "Shared board receipt cannot be relabeled as an app receipt")
        appSession.shutdown(); appManager.deactivate()

        check(ReadPicoBoardModuleOrder.moving(0, before: 3, in: [0, 1, 2, 3]) == [1, 2, 0, 3], "Downward drag lands before target")
        check(ReadPicoBoardModuleOrder.moving(3, before: 1, in: [0, 1, 2, 3]) == [0, 3, 1, 2], "Upward drag lands before target")
        check(ReadPicoBoardModuleOrder.moving(2, before: 2, in: [0, 1, 2, 3]) == [0, 1, 2, 3], "Self drop preserves module order")
        check(ReadPicoBoardModuleOrder.moving(8, before: 1, in: [0, 1, 2, 3]) == [0, 1, 2, 3], "Foreign drag preserves module order")
        check(ReadPicoBoardModuleOrder.moving(1, before: 8, in: [0, 1, 2, 3]) == [0, 1, 2, 3], "Missing target preserves module order")
        print("Board session lifecycle: \(checks) checks passed; injected transport; no network, user settings or hardware")
    }
}
