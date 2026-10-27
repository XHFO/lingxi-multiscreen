import AppKit
import Foundation
import LinxDisplayCore

private actor GuardDevice: ReadPicoManagerDeviceClient {
    var config = ReadPicoHomeConfiguration()
    var power = ReadPicoDeviceConfiguration()
    var fail = false
    var lockImageSaves = 0
    func setFailure(_ value: Bool) { fail = value }
    func imageSaveCount() -> Int { lockImageSaves }
    func home() async throws -> ReadPicoHomeSnapshot {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        return try JSONDecoder().decode(ReadPicoHomeSnapshot.self, from: JSONSerialization.data(withJSONObject: ["config": object, "saved_wifi": ["Home"], "network_online": true]))
    }
    func capabilities() async throws -> ReadPicoCapabilities {
        let configuration = try JSONSerialization.jsonObject(with: JSONEncoder().encode(power))
        return try JSONDecoder().decode(ReadPicoCapabilities.self, from: JSONSerialization.data(withJSONObject: ["protocol": 1, "config": configuration, "canvas": ["supported": true, "width": 684, "height": 1216, "formats": ["image/bmp"], "max_bytes": 110000, "state": "displayed", "revision": 1]]))
    }
    func saveHome(_ config: ReadPicoHomeConfiguration, token: String) async throws {
        try await Task.sleep(nanoseconds: 20_000_000)
        if fail { throw URLError(.cannotConnectToHost) }
        self.config = config; self.config.hasToken = config.hasToken || !token.isEmpty
    }
    func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities {
        if fail { throw URLError(.cannotConnectToHost) }
        power = configuration; power.state = 2; power.revision += 1
        return try await capabilities()
    }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability,
                             onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities { try await capabilities() }
    func saveLockImageConfirmed(_ bmp: Data, onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities {
        lockImageSaves += 1
        throw ReadPicoManagerError.invalid("Departure must not upload a prepared local image")
    }
}
private final class OriginalDelegate: NSObject, NSWindowDelegate {
    var calls = 0
    var closed = 0
    var permitsClose = false
    func windowShouldClose(_ sender: NSWindow) -> Bool { calls += 1; return permitsClose }
    func windowWillClose(_ notification: Notification) { closed += 1 }
}
@main struct DraftGuardTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) { checks += 1; precondition(value(), label) }
        func idle(_ model: ReadPicoManagerModel) async throws {
            for _ in 0..<300 { if !model.busy { return }; try await Task.sleep(nanoseconds: 5_000_000) }
            fatalError("device operation did not finish")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let device = GuardDevice()
        let model = ReadPicoManagerModel { _ in device }
        model.connect(address: "http://reader.local/manage#key=" + String(repeating: "a", count: 32), key: "")
        try await idle(model)
        check(model.connection != nil, "fixture is connected")
        let canvas = ReadPicoCanvasDraft()
        var saveChoice = 0
        let draftURL = temp.appendingPathComponent("draft.picocanvas")
        let drafts = ReadPicoDraftGuard(model: model, canvas: canvas) { draft in
            if saveChoice == 1 { return false }
            if saveChoice == 2 { throw URLError(.cannotCreateFile) }
            try draft.save(to: draftURL); return true
        }
        let preparedImage = Data([1, 2, 3])
        model.pendingLockImage = preparedImage
        var preparedDepartures = 0
        drafts.request(.device, title: "leave prepared image") { preparedDepartures += 1 }
        check(preparedDepartures == 1 && !drafts.showPrompt && !drafts.hasChanges(.device),
              "a prepared local image alone neither forces a connection nor a device save prompt")
        model.deviceConfiguration.autoSleepMinutes = 15
        drafts.request(.device, title: "save settings only") { preparedDepartures += 1 }
        drafts.resolve(.save)
        try await idle(model)
        let imageSaves = await device.imageSaveCount()
        check(preparedDepartures == 2 && imageSaves == 0 && model.pendingLockImage == preparedImage,
              "departure saves changed configurations without submitting or losing a pending lock image")
        check(!model.hasUnsavedDeviceConfigurationChanges && model.hasUnsavedDeviceChanges,
              "configuration-only and complete device dirty states remain independent")
        model.pendingLockImage = nil
        var departed = 0
        let leave = { departed += 1 }
        drafts.request(title: "close", action: leave)
        check(departed == 1 && !drafts.showPrompt, "clean close is immediate")
        model.home.local = "http://new-home.local:8123"
        model.homeToken = "unsaved-only-in-memory"
        drafts.request(.device, title: "change connection", action: leave)
        check(drafts.showPrompt && departed == 1, "dirty settings block departure")
        drafts.resolve(.cancel)
        check(model.homeToken == "unsaved-only-in-memory" && !drafts.isHandlingDeparture, "cancel preserves secret draft and releases request")
        drafts.request(.device, title: "change connection", action: leave)
        await device.setFailure(true)
        drafts.resolve(.save)
        check(model.busy && departed == 1, "save waits for actual device confirmation")
        try await idle(model)
        check(departed == 1 && model.hasUnsavedDeviceChanges && model.isError, "failed save stays on source with draft")
        check(!drafts.isHandlingDeparture, "failed save permits retry")
        await device.setFailure(false)
        drafts.request(.device, title: "change connection", action: leave)
        drafts.resolve(.save)
        try await idle(model)
        check(departed == 2 && !model.hasUnsavedDeviceChanges && model.homeToken.isEmpty, "readback confirmation permits departure")
        canvas.canvasMode = 1; canvas.strokes = [[CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.9, y: 0.8)]]
        drafts.request(.device, title: "disconnect", action: leave)
        check(departed == 3 && canvas.hasUnsavedChanges, "disconnect retains local canvas without unrelated confirmation")
        let deliveredDrawing = try canvas.makePushSnapshot(); deliveredDrawing.acknowledge()
        check(!canvas.hasUnsavedChanges && canvas.hasUnsavedLocalChanges,
              "a displayed drawing remains an unsaved local original")
        saveChoice = 1
        drafts.request(title: "close", action: leave); drafts.resolve(.save)
        check(departed == 3 && canvas.hasUnsavedLocalChanges && !drafts.isHandlingDeparture, "cancelled file panel preserves a displayed but unsaved drawing")
        saveChoice = 2
        drafts.request(title: "close", action: leave); drafts.resolve(.save)
        check(departed == 3 && canvas.hasUnsavedLocalChanges && model.isError, "failed draft write preserves drawing")
        saveChoice = 0
        model.deviceConfiguration.autoSleepMinutes = 5
        drafts.request(title: "close", action: leave); drafts.resolve(.save)
        try await idle(model)
        let restored = ReadPicoCanvasDraft(); try restored.load(from: draftURL)
        check(departed == 4 && !canvas.hasUnsavedChanges && !model.hasUnsavedDeviceChanges, "all save confirms both local and device content")
        check(restored.strokes == canvas.strokes, "local drawing remains editable after re-open")
        let bytes = try Data(contentsOf: draftURL)
        model.home.local = "http://discard.local:8123"; canvas.strokes.append([CGPoint(x: 0.4, y: 0.4)])
        drafts.request(title: "close", action: leave); drafts.resolve(.discard)
        check(departed == 5 && !canvas.hasUnsavedChanges && !model.hasUnsavedDeviceChanges, "explicit discard permits departure")
        let afterDiscard = try Data(contentsOf: draftURL)
        check(afterDiscard == bytes, "discard never rewrites saved original")
        var childCalls = 0
        drafts.childDeparture = { _ in childCalls += 1; drafts.cancelChildDeparture() }
        drafts.request(title: "close", action: leave)
        check(childCalls == 1 && departed == 5 && !drafts.isHandlingDeparture, "child cancellation preserves parent and releases gate")
        drafts.childDeparture = { continuation in childCalls += 1; drafts.childDeparture = nil; continuation() }
        drafts.request(title: "close", action: leave)
        check(childCalls == 2 && departed == 6 && !drafts.isHandlingDeparture, "child confirmation continues original departure once")
        let firstOwner = UUID(), secondOwner = UUID()
        check(drafts.registerChildDeparture(owner: firstOwner) { _ in }, "child installs its own departure handler")
        check(!drafts.registerChildDeparture(owner: secondOwner) { _ in }, "another editor cannot replace an active departure handler")
        drafts.clearChildDeparture(owner: secondOwner)
        check(drafts.childDeparture != nil, "an unrelated editor cannot clear the active handler")
        drafts.childDeparture = { _ in }
        drafts.clearChildDeparture(owner: firstOwner)
        check(drafts.childDeparture != nil, "an old sheet cannot clear a directly installed Web handler")
        drafts.childDeparture = nil
        check(drafts.registerChildDeparture(owner: secondOwner) { _ in }, "next editor registers after prior departure closes")
        drafts.clearChildDeparture(owner: secondOwner)
        check(drafts.childDeparture == nil, "the current child can release its own handler")
        drafts.externalBusy = true
        drafts.request(title: "close", action: leave)
        check(departed == 6 && !drafts.showPrompt && drafts.blocksDismissal, "firmware operation blocks every departure path")
        drafts.externalBusy = false
        model.homeToken = "quit-draft"
        drafts.activate()
        check(!ReadPicoDraftGuard.prepareForApplicationTermination() && drafts.showPrompt, "Cmd-Q uses same draft gate")
        drafts.resolve(.cancel)
        check(model.homeToken == "quit-draft", "cancelled Cmd-Q retains credentials only in memory")
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let original = OriginalDelegate(); window.delegate = original
        let bridge = ReadPicoWindowCloseGuard.Coordinator(drafts: drafts)
        bridge.attach(window)
        check(!bridge.windowShouldClose(window) && drafts.showPrompt && original.calls == 0, "window close intercepts dirty state before original delegate")
        drafts.resolve(.cancel)
        model.discardPendingDeviceChanges()
        check(!bridge.windowShouldClose(window) && original.calls == 1, "clean close forwards original decision")
        bridge.attach(nil)
        check(window.delegate === original, "window delegate is restored on detach")
        let closable = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        closable.isReleasedWhenClosed = false
        original.permitsClose = true; closable.delegate = original
        bridge.attach(closable)
        model.homeToken = "window-close-draft"
        closable.orderFront(nil); closable.performClose(nil)
        check(drafts.showPrompt && original.closed == 0, "real close waits for an explicit draft decision")
        drafts.resolve(.discard)
        check(original.closed == 1 && !closable.isVisible, "discard completes actual window close and forwards notification")
        bridge.attach(nil)
        drafts.deactivate(); window.close()
        check(ReadPicoDraftGuard.prepareForApplicationTermination(), "closed workbench unregisters termination gate")
        check(model.connection == nil && model.homeToken.isEmpty, "final close clears session credentials")
        print("Draft departure protection: \(checks) checks passed")
    }
}
