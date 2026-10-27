import AppKit
import Foundation
import LinxDisplayCore

private enum ForcedCommitError: LocalizedError {
    case settings
    var errorDescription: String? { "forced-settings-failure" }
}
@main struct WallpaperTransactionChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("lingxi-wallpaper-transaction-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1; print("PASS " + message)
        }
        @discardableResult func fails(_ message: String, _ action: () throws -> Void) -> Error {
            do { try action(); preconditionFailure(message + " unexpectedly succeeded") }
            catch { checks += 1; print("PASS " + message + " throws"); return error }
        }
        let image = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 160,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        image.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1)); image.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let pixels = image.makeImage()!
        let input = base.appendingPathComponent("source.png")
        try NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:])!.write(to: input)
        let libraryRoot = base.appendingPathComponent("library")
        let library = PicoNativeLibrary.production(rootURL: libraryRoot, previewRootURL: base.appendingPathComponent("absent-preview"))
        await library.importImages(from: [input])
        check(library.assets.count == 1 && library.isWritable, "transaction uses a real imported production asset without fixture seed")
        let asset = library.assets[0], key = "device.\(UUID().uuidString).module.\(UUID().uuidString)"
        var oldEdit = PicoPhotoEdit(); oldEdit.scale = 1.2
        var newEdit = oldEdit; newEdit.scale = 2.7; newEdit.panX = 0.3
        check(library.saveUse(assetID: asset.id, key: key, target: .oracle, edit: oldEdit), "baseline use saves normally")
        let index = libraryRoot.appendingPathComponent("library.json")
        // Preserve exact previous bytes, including formatting a normal re-encode would replace.
        let prior = Data(" \n".utf8) + (try Data(contentsOf: index)) + Data("\n ".utf8)
        try prior.write(to: index, options: .atomic)
        var calls = 0
        fails("external settings commit failure") {
            try library.commitUse(assetID: asset.id, key: key, target: .oracle, edit: newEdit) {
                calls += 1
                check(library.use(for: key)?.edit == oldEdit, "candidate use is not published while settings commit runs")
                throw ForcedCommitError.settings
            }
        }
        check(calls == 1 && library.use(for: key)?.edit == oldEdit && library.isWritable, "failed settings commit retains old in-memory use and writable recovery")
        check(try Data(contentsOf: index) == prior, "failed settings commit restores exact prior index bytes")
        let backupIndex = libraryRoot.appendingPathComponent("retained-index.json")
        try fm.moveItem(at: index, to: backupIndex); try fm.createDirectory(at: index, withIntermediateDirectories: false)
        calls = 0
        fails("candidate index write failure") {
            try library.commitUse(assetID: asset.id, key: key, target: .oracle, edit: newEdit) { calls += 1 }
        }
        check(calls == 0 && library.use(for: key)?.edit == oldEdit, "blocked index never invokes or changes external settings")
        check(try Data(contentsOf: backupIndex) == prior, "blocked index preserves retained prior file")
        try fm.removeItem(at: index); try fm.moveItem(at: backupIndex, to: index)
        calls = 0
        fails("missing source asset") {
            try library.commitUse(assetID: UUID(), key: key, target: .oracle, edit: newEdit) { calls += 1 }
        }
        check(calls == 0 && library.use(for: key)?.edit == oldEdit, "missing source cannot commit active settings")
        try library.commitUse(assetID: asset.id, key: key, target: .oracle, edit: newEdit) { calls += 1 }
        check(calls == 1 && library.use(for: key)?.edit == newEdit, "successful transaction invokes one commit and publishes its use")
        let libraryReload = PicoNativeLibrary.production(rootURL: libraryRoot, previewRootURL: base.appendingPathComponent("absent-preview"))
        check(libraryReload.use(for: key)?.edit == newEdit, "successful transaction reopens the same saved use")

        // Exercise the exact production model method against real AppSettings/SettingsStore and snapshots.
        for owner in [WallpaperModelFixture.CanvasOwner.oracle, .excerpt] {
            let settingsRoot = base.appendingPathComponent("settings-\(owner)")
            let model = WallpaperModelFixture(root: settingsRoot)
            try model.store.saveChecked(model.settings)
            let originalSettings = try Data(contentsOf: model.store.settingsURL)
            let originalPath = model.canvasImagePath(for: owner), originalName = model.canvasImageName(for: owner)
            let originalOracle = model.settings.oracleCanvasBoards, originalExcerpt = model.settings.excerptCanvasBoards, originalDevices = model.settings.devices
            let originalUse = library.use(for: key)!.edit, originalIndex = try Data(contentsOf: index)
            let retained = model.store.dataDirectory.appendingPathComponent("retained-settings.json")
            try fm.moveItem(at: model.store.settingsURL, to: retained)
            try fm.createDirectory(at: model.store.settingsURL, withIntermediateDirectories: false)
            calls = 0
            fails("actual model settings write fails for \(owner)") {
                try library.commitUse(assetID: asset.id, key: key, target: .oracle, edit: oldEdit) {
                    calls += 1; try model.setSharedCanvasImage(url: input, displayName: "新图", owner: owner)
                }
            }
            check(calls == 1 && model.canvasImagePath(for: owner) == originalPath && model.canvasImageName(for: owner) == originalName,
                  "\(owner) failure restores active image path and name")
            check(model.settings.oracleCanvasBoards == originalOracle && model.settings.excerptCanvasBoards == originalExcerpt && model.settings.devices == originalDevices,
                  "\(owner) failure restores editable boards and active device snapshots")
            check(model.unguardedChanges == 0 && model.previewCalls == 0 && model.syncCalls == 0,
                  "\(owner) failure exposes no callback persistence, intermediate preview or automatic sync")
            check(!model.canvasBoardAutosaveInFlight && !model.settings.deviceSyncInFlight, "\(owner) failure restores initial guard values")
            check(try Data(contentsOf: retained) == originalSettings && Data(contentsOf: index) == originalIndex && library.use(for: key)?.edit == originalUse,
                  "\(owner) failure preserves settings file, exact library index and memory use")
            try fm.removeItem(at: model.store.settingsURL); try fm.moveItem(at: retained, to: model.store.settingsURL)
            model.canvasBoardAutosaveInFlight = true; model.settings.deviceSyncInFlight = true
            calls = 0
            try library.commitUse(assetID: asset.id, key: key, target: .oracle, edit: oldEdit) {
                calls += 1; try model.setSharedCanvasImage(url: input, displayName: "新图", owner: owner)
            }
            check(calls == 1 && model.canvasBoardAutosaveInFlight && model.settings.deviceSyncInFlight, "\(owner) success restores pre-existing nested guard values")
            check(model.unguardedChanges == 0 && model.previewCalls == 1 && model.syncCalls == 1,
                  "\(owner) success refreshes exactly once after the checked settings commit")
            let reopened = model.store.load(), expected = model.canvasImagePath(for: owner)!
            check(expected != originalPath && fm.fileExists(atPath: expected), "\(owner) success retains an owned image copy")
            if owner == .oracle {
                check(reopened.oracleCanvasImagePath == expected && reopened.oracleCanvasBoards[0].imagePath == expected && reopened.devices[0].settings.canvasImagePath == expected,
                      "oracle success persists image, current board and device snapshot together")
                check(model.settings.excerptCanvasBoards == originalExcerpt, "oracle commit preserves other owner board")
            } else {
                check(reopened.excerptCanvasImagePath == expected && reopened.excerptCanvasBoards[0].imagePath == expected && reopened.devices[1].settings.canvasImagePath == expected,
                      "excerpt success persists image, current board and device snapshot together")
                check(model.settings.oracleCanvasBoards == originalOracle, "excerpt commit preserves other owner board")
            }
        }

        // Portable .picolock source/parameters are authoritative, with no library asset on this Mac.
        let lockDraft = ReadPicoLockScreenDraft()
        try lockDraft.setImage(pixels, name: "便携锁屏")
        var options = lockDraft.options; options.wallpaperAssetID = UUID(); lockDraft.updateOptions(options)
        let portableFile = base.appendingPathComponent("portable.picolock")
        try lockDraft.save(to: portableFile)
        let portable = ReadPicoLockScreenDraft(); try portable.load(data: Data(contentsOf: portableFile))
        let lockFixture = LockCompositionFixture(editor: portable)
        let beforeLockLibrary = try Data(contentsOf: index)
        check(lockFixture.applyComposition(newEdit), "portable lock draft applies crop without its original library asset")
        let expectedLockEdit = try JSONEncoder().encode(newEdit.normalized())
        check(lockFixture.model.errors.isEmpty && portable.options.wallpaperAssetID == options.wallpaperAssetID && portable.options.photoEditData == expectedLockEdit && portable.hasUnsavedChanges,
              "portable edit remains only in its own editable draft")
        check(try Data(contentsOf: index) == beforeLockLibrary, "applying a lock crop never writes global library uses")
        portable.discardChanges()
        check(portable.options.photoEditData == nil && !portable.hasUnsavedChanges, "discard also discards portable lock crop parameters")
        check(lockFixture.applyComposition(newEdit), "portable crop can be applied again after discard")
        try portable.save(to: portableFile)
        let portableReload = ReadPicoLockScreenDraft(); try portableReload.load(data: Data(contentsOf: portableFile))
        check(portableReload.options.photoEditData == portable.options.photoEditData && !portableReload.hasUnsavedChanges,
              "portable crop persists only when the local draft is explicitly saved")

        // If restoring the index itself fails, report both errors and stop further writes.
        let rollbackError = fails("rollback write failure") {
            try library.commitUse(assetID: asset.id, key: key, target: .oracle, edit: newEdit) {
                try fm.moveItem(at: index, to: backupIndex)
                try fm.createDirectory(at: index, withIntermediateDirectories: false)
                throw ForcedCommitError.settings
            }
        }
        check(rollbackError.localizedDescription.contains("forced-settings-failure") && rollbackError.localizedDescription.contains("回滚失败") && !library.isWritable,
              "rollback failure explicitly reports the original failure and disables library writes")
        calls = 0
        fails("write after failed rollback") {
            try library.commitUse(assetID: asset.id, key: key, target: .oracle, edit: oldEdit) { calls += 1 }
        }
        check(calls == 0, "paused library never invokes another settings commit")
        print("Wallpaper transactional / portable: \(checks) checks passed")
    }
}
