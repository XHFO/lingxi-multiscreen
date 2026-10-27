import AppKit
import LinxDisplayCore

@main struct LockScreenDraftGuardTests {
    @MainActor static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lock-screen-guard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let context = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = context.makeImage()!
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message); count += 1; print("PASS " + message) }
        let editor = ReadPicoLockScreenDraft()
        try editor.setImage(image, name: "原图.png")
        let manager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] })
        defer { manager.deactivate() }
        var saveMode = 0, localSaves = 0
        let drafts = ReadPicoDraftGuard(model: manager, lockScreen: editor, saveLockScreen: { value in
            localSaves += 1
            if saveMode == 0 { return false }
            if saveMode == 1 { throw ReadPicoManagerError.invalid("fixture") }
            try value.save(to: temporary.appendingPathComponent("original.picolock")); return true
        })
        var departures = 0
        check(drafts.hasChanges(.device) && drafts.hasChanges(.all) && !drafts.hasChanges(.canvas), "original scope belongs to device and all, not canvas")
        drafts.request(.device, title: "fixture") { departures += 1 }
        check(drafts.showPrompt && drafts.departureMessage.contains("锁屏原图"), "device departure describes local original protection")
        drafts.resolve(.cancel)
        check(departures == 0 && editor.hasUnsavedChanges, "cancel departure preserves original")
        drafts.request(.device, title: "fixture") { departures += 1 }; drafts.resolve(.save)
        check(departures == 0 && editor.hasUnsavedChanges && localSaves == 1, "cancel original save prevents departure")
        saveMode = 1
        drafts.request(.device, title: "fixture") { departures += 1 }; drafts.resolve(.save)
        check(departures == 0 && editor.hasUnsavedChanges && manager.isError, "failed original save preserves original and page")
        saveMode = 2
        drafts.request(.device, title: "fixture") { departures += 1 }; drafts.resolve(.save)
        check(departures == 1 && !editor.hasUnsavedChanges && localSaves == 3, "confirmed original save releases departure")
        check(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("original.picolock").path), "original save creates actual local document")
        editor.updateOptions(editor.options)
        check(!drafts.hasChanges(.device), "unchanged edit parameters stay clean")
        var edited = editor.options; edited.zoom = 2; editor.updateOptions(edited)
        check(drafts.hasChanges(.device), "changed source geometry is protected")
        drafts.request(.device, title: "fixture") { departures += 1 }; drafts.resolve(.discard)
        check(departures == 2 && !editor.hasUnsavedChanges && editor.options.zoom == 1 && editor.hasImage, "discard restores saved original and keeps it available")
        let fresh = ReadPicoLockScreenDraft()
        let secondManager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] })
        defer { secondManager.deactivate() }
        let second = ReadPicoDraftGuard(model: secondManager, lockScreen: fresh)
        fresh.configureRenderer { _, options in Data([UInt8(options.zoom)]) }
        try fresh.setImage(image, name: "new.png")
        check(fresh.rendering && second.blocksDismissal, "rendering blocks closure before a current wire image exists")
        second.request(.device, title: "fixture") { departures += 1 }
        check(!second.showPrompt && departures == 2, "departure cannot bypass a pending render")
        await ready(fresh)
        check(secondManager.pendingLockImage == Data([1]) && secondManager.pendingLockImage == fresh.bitmap, "guard receives exact displayed bitmap after completion")
        var moved = fresh.options; moved.zoom = 2; fresh.updateOptions(moved)
        check(secondManager.pendingLockImage == nil && fresh.rendering, "starting newer render removes stale sendable bitmap immediately")
        await ready(fresh)
        check(secondManager.pendingLockImage == Data([2]), "only newer edit becomes pending payload")
        second.request(.device, title: "fixture") { departures += 1 }; second.resolve(.discard)
        try await Task.sleep(nanoseconds: 180_000_000)
        check(!fresh.hasImage && secondManager.pendingLockImage == nil && departures == 3, "discard fresh original cannot repopulate pending image after departure")
        let offlineEditor = ReadPicoLockScreenDraft()
        let offlineManager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] })
        defer { offlineManager.deactivate() }
        let offlineFile = temporary.appendingPathComponent("offline.picolock")
        let offlineDrafts = ReadPicoDraftGuard(model: offlineManager, lockScreen: offlineEditor,
            saveLockScreen: { value in try value.save(to: offlineFile); return true })
        offlineEditor.configureRenderer { _, options in Data([UInt8(options.zoom), 7, 9]) }
        try offlineEditor.setImage(image, name: "offline.png")
        await ready(offlineEditor)
        let offlineBitmap = offlineEditor.bitmap
        check(offlineBitmap != nil && offlineManager.pendingLockImage == offlineBitmap && offlineManager.connection == nil,
              "a rendered lock-screen original is editable while fully offline")
        offlineDrafts.request(.device, title: "offline local save") { departures += 1 }
        offlineDrafts.resolve(.save)
        check(departures == 4 && !offlineEditor.hasUnsavedChanges && !offlineManager.busy && !offlineManager.isError,
              "saving and leaving a local lock-screen original never requires a device connection")
        check(offlineManager.pendingLockImage == offlineBitmap && FileManager.default.fileExists(atPath: offlineFile.path),
              "offline local save preserves the exact prepared bitmap for a later explicit upload")
        let reloaded = ReadPicoLockScreenDraft(); try reloaded.load(data: Data(contentsOf: offlineFile))
        check(reloaded.hasImage && reloaded.name == "offline.png" && !reloaded.hasUnsavedChanges,
              "offline local original reopens independently of any device delivery")
        print("PASS \(count) lock-screen original/guard integration checks")
    }
    @MainActor static func ready(_ draft: ReadPicoLockScreenDraft) async {
        for _ in 0..<300 { if !draft.rendering { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        preconditionFailure("render timeout")
    }
}
