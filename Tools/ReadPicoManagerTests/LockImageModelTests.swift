import AppKit
import Foundation
import LinxDisplayCore

private actor ImageGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
private actor ImageDevice: ReadPicoManagerDeviceClient {
    var config = ReadPicoDeviceConfiguration(lockStyle: 0)
    var revision = 1, available = false, saves = 0
    var fail = false, stale = false, protocolVersion = 1
    var nativeGray16 = false, loseNativeOnSave = false
    var gate: ImageGate?
    var savedImage = Data()
    func setup(fail: Bool = false, stale: Bool = false, protocolVersion: Int = 1, gate: ImageGate? = nil,
               nativeGray16: Bool = false, loseNativeOnSave: Bool = false) {
        self.fail = fail; self.stale = stale; self.protocolVersion = protocolVersion; self.gate = gate
        self.nativeGray16 = nativeGray16; self.loseNativeOnSave = loseNativeOnSave
    }
    func count() -> Int { saves }
    func home() async throws -> ReadPicoHomeSnapshot {
        let home = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ReadPicoHomeConfiguration()))
        return try JSONDecoder().decode(ReadPicoHomeSnapshot.self, from: JSONSerialization.data(withJSONObject: ["config": home, "saved_wifi": [], "network_online": true]))
    }
    func capabilities() async throws -> ReadPicoCapabilities {
        let power = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        var imageLock: [String: Any] = ["supported": true, "available": available, "state": "saved", "revision": revision,
            "width": available ? 684 : 0, "height": available ? 1216 : 0, "formats": ["image/bmp"], "max_bytes": nativeGray16 ? 420000 : 110000]
        if nativeGray16 { imageLock["bit_depths"] = [1, 4]; imageLock["gray_levels"] = 16 }
        return try JSONDecoder().decode(ReadPicoCapabilities.self, from: JSONSerialization.data(withJSONObject: ["protocol": protocolVersion, "config": power,
            "canvas": ["supported": true, "width": 684, "height": 1216, "formats": ["image/bmp"], "max_bytes": 110000, "state": "idle", "revision": 0],
            "image_lock": imageLock]))
    }
    func saveHome(_ config: ReadPicoHomeConfiguration, token: String) async throws {}
    func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities {
        if fail { throw URLError(.cannotWriteToFile) }
        let previous = config.revision; config = configuration; config.state = 2; config.revision = previous + 1
        return try await capabilities()
    }
    func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities { try await capabilities() }
    func saveLockImageConfirmed(_ bmp: Data, onAccepted: (@Sendable () async -> Void)?) async throws -> ReadPicoCapabilities {
        saves += 1; await onAccepted?()
        if let gate { await gate.wait() }
        if fail { throw URLError(.cannotWriteToFile) }
        if !stale { revision += 1 }; available = true; savedImage = bmp
        if loseNativeOnSave { nativeGray16 = false }
        return try await capabilities()
    }
    func lockImage() async throws -> Data { savedImage }
}
@main struct LockImageModelTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
        func idle(_ model: ReadPicoManagerModel) async throws {
            for _ in 0..<300 { if !model.busy { return }; try await Task.sleep(nanoseconds: 5_000_000) }
            fatalError("model did not settle")
        }
        let device = ImageDevice(), model = ReadPicoManagerModel { _ in device }
        model.connect(address: "http://fixture.invalid/manage#key=" + String(repeating: "a", count: 32), key: "")
        try await idle(model)
        check(model.imageLock?.supported == true && model.imageLock?.width == 0, "no-image zero dimensions still advertises lock support")
        let context = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let original = try ReadPicoBitmap.make(image: context.makeImage()!, width: 684, height: 1216)
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let newer = try ReadPicoBitmap.make(image: context.makeImage()!, width: 1216, height: 684)
        let drafts = ReadPicoDraftGuard(model: model)
        var departures = 0
        model.pendingLockImage = original
        check(model.hasUnsavedDeviceChanges && drafts.hasChanges(.device), "pending image participates in global departure")
        drafts.request(.device, title: "leave") { departures += 1 }
        check(drafts.showPrompt, "pending image prompts before leaving device")
        drafts.resolve(.cancel)
        check(departures == 0 && model.pendingLockImage == original, "cancel preserves pending image")
        drafts.request(.device, title: "leave") { departures += 1 }
        await device.setup(fail: true); drafts.resolve(.save); try await idle(model)
        check(departures == 0 && model.pendingLockImage == original && model.isError, "failed save keeps pending image and page")
        drafts.request(.device, title: "leave") { departures += 1 }; drafts.resolve(.discard)
        check(departures == 1 && model.pendingLockImage == nil && !model.hasUnsavedDeviceChanges, "explicit discard clears only pending image")
        model.pendingLockImage = original
        await device.setup(); drafts.request(.device, title: "leave") { departures += 1 }; drafts.resolve(.save)
        try await idle(model)
        check(departures == 2 && model.pendingLockImage == nil && model.lockImagePreview == original, "confirmed save clears matching image then leaves")
        check(model.imageLock?.available == true, "confirmed image becomes selectable")
        model.deviceConfiguration.lockStyle = 4
        check(model.hasUnsavedPowerChanges, "style is an editable device draft")
        model.saveDeviceSettings(); try await idle(model)
        check(model.confirmedDeviceConfig?.lockStyle == 4 && !model.hasUnsavedPowerChanges, "style confirmation updates baseline")
        model.pendingLockImage = newer
        let retainedRevision = model.imageLock?.revision
        await device.setup(stale: true); model.uploadLockImage(newer); try await idle(model)
        check(model.pendingLockImage == newer && model.imageLock?.revision == retainedRevision && model.isError, "stale saved revision never clears draft")
        await device.setup(protocolVersion: 2); model.uploadLockImage(newer); try await idle(model)
        check(model.pendingLockImage == newer && model.isError, "incompatible result never confirms image")
        await device.setup()
        let gate = ImageGate(); await device.setup(gate: gate)
        model.pendingLockImage = original; model.uploadLockImage(original)
        try await Task.sleep(nanoseconds: 25_000_000)
        check(model.busy && model.pendingLockImage == original, "accepted request alone preserves pending image")
        model.pendingLockImage = newer
        await gate.open(); try await idle(model)
        check(model.pendingLockImage == newer && model.lockImagePreview == original, "older acknowledgement preserves newer pending image")
        await device.setup(); model.uploadLockImage(newer); try await idle(model)
        check(model.pendingLockImage == nil && model.lockImagePreview == newer, "newer image clears only after its own save")
        model.lockImagePreview = nil; model.readLockImage(); try await idle(model)
        check(model.lockImagePreview == newer, "read saved image through shared manager")
        let gray16 = try ReadPicoBitmap.makeGray16(image: context.makeImage()!, width: 684, height: 1216)
        let previousSaveCount = await device.count()
        model.pendingLockImage = gray16; model.uploadLockImage(gray16); try await idle(model)
        check(await device.count() == previousSaveCount && model.pendingLockImage == gray16 && model.isError,
              "manager rejects native image before client save on legacy firmware")
        check(model.lockImagePreview == newer, "rejected native upload preserves confirmed binary preview")
        check(model.disconnect(discardChanges: true), "explicit discard permits native capability reconnect")
        await device.setup(nativeGray16: true)
        model.connect(address: "http://fixture.invalid/manage#key=" + String(repeating: "a", count: 32), key: "")
        try await idle(model)
        check(model.imageLock?.supportsNativeGray16 == true, "manager reads explicit native lock capability")
        model.pendingLockImage = gray16; model.uploadLockImage(gray16); try await idle(model)
        check(await device.count() == previousSaveCount + 1 && model.pendingLockImage == nil && model.lockImagePreview == gray16,
              "manager sends exact native payload and clears draft only after compatible saved receipt")
        model.lockImagePreview = nil; model.readLockImage(); try await idle(model)
        check(model.lockImagePreview == gray16, "manager reads exact native image without binary conversion")
        var invalidGray16 = gray16; invalidGray16[55] = 1
        model.pendingLockImage = invalidGray16; model.uploadLockImage(invalidGray16); try await idle(model)
        check(await device.count() == previousSaveCount + 1 && model.pendingLockImage == invalidGray16 && model.isError,
              "manager rejects malformed native palette before client save")
        await device.setup(nativeGray16: true, loseNativeOnSave: true)
        let nativeRevision = model.imageLock?.revision
        model.pendingLockImage = gray16; model.uploadLockImage(gray16); try await idle(model)
        check(await device.count() == previousSaveCount + 2 && model.pendingLockImage == gray16 && model.isError && model.imageLock?.revision == nativeRevision,
              "manager leaves native draft unconfirmed when saved receipt loses native capability")
        model.pendingLockImage = original
        check(!model.disconnect(), "dirty image cannot silently disconnect")
        check(model.disconnect(discardChanges: true) && model.pendingLockImage == nil && model.lockImagePreview == nil, "explicit disconnect clears paired image state")
        print("PASS: \(checks) actual lock-image model/departure save-discard-cancel, style, stale receipt and newer-draft checks; no real device.")
    }
}
