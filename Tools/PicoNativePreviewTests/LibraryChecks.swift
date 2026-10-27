import AppKit
import ImageIO
import Foundation

@main
struct PicoNativeLibraryChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("pico-native-library-check-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("library")
        let library = PicoNativeLibrary(rootURL: root)
        ensure(library.error == nil && library.assets.count == 3 && library.isWritable, "seed model")
        for asset in library.assets {
            let object = root.appendingPathComponent("objects/\(asset.id.uuidString)")
            let dimensions = try pixelSize(object.appendingPathComponent(asset.originalFilename))
            ensure(dimensions == [asset.width, asset.height], "sample dimensions match metadata")
            let thumb = try pixelSize(object.appendingPathComponent(asset.thumbnailFilename))
            ensure(thumb.max()! <= 640, "real bounded thumbnail")
        }
        let sampleIDs = library.assets.map(\.id)
        let sample = library.assets[0]
        var board = PicoPhotoEdit(); board.scale = 1.7; board.panX = 0.2
        var lock = PicoPhotoEdit(); lock.scale = 1.1; lock.panX = -0.3
        ensure(library.saveUse(assetID: sample.id, key: "board", target: .pico, edit: board), "save board")
        ensure(library.saveUse(assetID: sample.id, key: "lock", target: .pico, edit: lock), "save lock")
        let reload = PicoNativeLibrary(rootURL: root)
        ensure(reload.assets.map(\.id) == sampleIDs, "stable seeded IDs on reload")
        ensure(reload.use(for: "board")?.edit == board && reload.use(for: "lock")?.edit == lock, "independent uses reload")

        let source = base.appendingPathComponent("wide-source.png")
        try writePNG(source, width: 8000, height: 1000, gray: 0.25)
        let originalBytes = try Data(contentsOf: source)
        await library.importImages(from: [source])
        ensure(library.error == nil && library.assets.count == 4, "import decoded image")
        let imported = library.assets.last!
        ensure(!imported.isSample && imported.width == 8000 && imported.height == 1000, "import metadata")
        let owned = root.appendingPathComponent("objects/\(imported.id.uuidString)/\(imported.originalFilename)")
        try ensure(try Data(contentsOf: owned) == originalBytes, "byte-identical owned original")
        try ensure(try pixelSize(root.appendingPathComponent("objects/\(imported.id.uuidString)/thumbnail.png")).max()! <= 640, "import thumbnail bounded")
        await library.importImages(from: [source])
        ensure(library.assets.count == 4 && library.error == nil, "duplicate hash no new asset")
        try fm.removeItem(at: source)
        let preview = await waitForPreview(library, imported)
        ensure(preview != nil, "source removed but preview still opens owned copy")
        if let preview {
            let dimensions = PicoPhotoRenderer.sourceSize(image: preview)
            ensure(dimensions.width == 4096 && dimensions.height == 512, "editor preview uses original and 4096px budget")
        }
        let manifest = root.appendingPathComponent("library.json")
        let beforeBad = try Data(contentsOf: manifest)
        let bad = base.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: bad)
        await library.importImages(from: [bad])
        ensure(library.error != nil && library.assets.count == 4, "bad image rejected")
        try ensure(try Data(contentsOf: manifest) == beforeBad, "bad import leaves manifest byte-identical")
        try ensure(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path).isEmpty, "bad/duplicate staging cleaned")
        let fresh = base.appendingPathComponent("fresh.png")
        try writePNG(fresh, width: 900, height: 600, gray: 0.7)
        let savedManifest = root.appendingPathComponent("saved-library.json")
        try fm.moveItem(at: manifest, to: savedManifest)
        try fm.createDirectory(at: manifest, withIntermediateDirectories: false)
        let objectsBefore = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("objects").path).sorted()
        await library.importImages(from: [fresh])
        ensure(library.error != nil && library.assets.count == 4, "failed manifest commit retains in-memory assets")
        try ensure(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("objects").path).sorted() == objectsBefore, "failed commit rolls back only new object")
        var unsaved = board; unsaved.scale = 2.9
        ensure(!library.saveUse(assetID: sample.id, key: "board", target: .pico, edit: unsaved), "save returns failure")
        ensure(library.use(for: "board")?.edit == board, "failed save retains previous use")
        try fm.removeItem(at: manifest)
        try fm.moveItem(at: savedManifest, to: manifest)
        var nan = board; nan.scale = .nan
        ensure(!library.saveUse(assetID: sample.id, key: "board", target: .pico, edit: nan), "invalid edit does not report saved")
        ensure(library.use(for: "board")?.edit == board, "invalid edit retains previous use")
        try ensure(try Data(contentsOf: manifest) == beforeBad, "failed saves preserve prior manifest")

        let corruptRoot = base.appendingPathComponent("corrupt")
        let seededCorrupt = PicoNativeLibrary(rootURL: corruptRoot)
        ensure(seededCorrupt.assets.count == 3, "corrupt fixture seeded")
        let corruptIndex = corruptRoot.appendingPathComponent("library.json")
        let corruptBytes = Data("{broken original index".utf8)
        try corruptBytes.write(to: corruptIndex)
        let corrupt = PicoNativeLibrary(rootURL: corruptRoot)
        ensure(!corrupt.isWritable && corrupt.error != nil, "corrupt index is read-only")
        await corrupt.importImages(from: [fresh])
        try ensure(try Data(contentsOf: corruptIndex) == corruptBytes, "import cannot overwrite corrupt index")
        ensure(!corrupt.saveUse(assetID: sample.id, key: "board", target: .pico, edit: board), "use cannot overwrite corrupt index")
        try ensure(try Data(contentsOf: corruptIndex) == corruptBytes, "save preserves corrupt index")
        try ensure(try fm.contentsOfDirectory(atPath: corruptRoot.appendingPathComponent("objects").path).count == 3, "corrupt index preserves owned objects")

        let missingThumb = root.appendingPathComponent("objects/\(sample.id.uuidString)/thumbnail.png")
        try fm.removeItem(at: missingThumb)
        let thumbFallback = PicoNativeLibrary(rootURL: root).thumbnail(for: sample)
        ensure(thumbFallback.size.width < 1600, "missing thumbnail never falls back to full original")

        let unreadableRoot = base.appendingPathComponent("unreadable-original")
        let unreadable = PicoNativeLibrary(rootURL: unreadableRoot)
        await unreadable.importImages(from: [fresh])
        ensure(unreadable.error == nil && unreadable.assets.count == 4, "unreadable fixture imports normally")
        let unreadableAsset = unreadable.assets.last!
        let unreadableOriginal = unreadableRoot.appendingPathComponent("objects/\(unreadableAsset.id.uuidString)/\(unreadableAsset.originalFilename)")
        try Data("corrupted owned original after import".utf8).write(to: unreadableOriginal, options: .atomic)
        ensure(unreadable.image(for: unreadableAsset) == nil, "corrupt original does not produce preview")
        for _ in 0..<200 {
            if unreadable.imageLoadFailed(for: unreadableAsset) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        ensure(unreadable.imageLoadFailed(for: unreadableAsset), "background decode exposes terminal failure state")
        ensure(unreadable.image(for: unreadableAsset) == nil, "failed preview remains unavailable")
        ensure(unreadable.error?.contains(unreadableAsset.name) == true && unreadable.error?.contains("无法读取图片") == true, "failure names unreadable image")
        unreadable.error = nil // Simulate dismissing the presentation's error alert.
        for _ in 0..<5 {
            ensure(unreadable.image(for: unreadableAsset) == nil, "repeated failed preview request remains nil")
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        ensure(unreadable.imageLoadFailed(for: unreadableAsset) && unreadable.error == nil, "repeated failed requests do not raise the dismissed error again")
        print("PASS: corrupt owned original -> background nil, terminal failure state, named error, no repeated error after dismissal")

        var largeIndex = try JSONSerialization.jsonObject(with: beforeBad) as! [String: Any]
        let assetJSON = (largeIndex["assets"] as! [[String: Any]])[0]
        largeIndex["uses"] = [String: Any]()
        largeIndex["assets"] = (0..<10000).map { _ -> [String: Any] in var value = assetJSON; value["id"] = UUID().uuidString; return value }
        let fullRoot = base.appendingPathComponent("full")
        try fm.createDirectory(at: fullRoot, withIntermediateDirectories: true)
        let fullIndex = fullRoot.appendingPathComponent("library.json")
        let fullData = try JSONSerialization.data(withJSONObject: largeIndex)
        try fullData.write(to: fullIndex)
        let full = PicoNativeLibrary(rootURL: fullRoot)
        ensure(full.assets.count == 10000 && full.isWritable, "maximum-size index accepted")
        await full.importImages(from: [fresh])
        ensure(full.assets.count == 10000 && full.error != nil, "capacity rejected before committing new object")
        try ensure(try Data(contentsOf: fullIndex) == fullData, "full index unchanged")
        try ensure(try fm.contentsOfDirectory(atPath: fullRoot.appendingPathComponent("objects").path).isEmpty, "capacity failure leaves no object")
        print("PASS: seed dimensions, independent uses, reload, real import, immutable source copy, dedup, bounded preview, bad-image cleanup, atomic rollback, save errors, corrupt-index protection, thumbnail fallback, capacity boundary")
        try await checkProduction(base: base, preview: library, imported: imported, originalBytes: originalBytes, sourceImage: fresh)
    }

    @MainActor static func checkProduction(base: URL, preview: PicoNativeLibrary, imported: PicoNativeAsset,
                                          originalBytes: Data, sourceImage: URL) async throws {
        let manager = FileManager.default
        let emptyRoot = base.appendingPathComponent("production-empty")
        let absentPreview = base.appendingPathComponent("no-preview-library")
        let empty = PicoNativeLibrary.production(rootURL: emptyRoot, previewRootURL: absentPreview)
        ensure(empty.isWritable && empty.error == nil && empty.assets.isEmpty, "production starts empty without fixtures")
        let emptyManifest = try Data(contentsOf: emptyRoot.appendingPathComponent("library.json"))
        let emptyReload = PicoNativeLibrary.production(rootURL: emptyRoot, previewRootURL: absentPreview)
        ensure(emptyReload.assets.isEmpty && emptyReload.error == nil, "empty production reload never seeds fixtures")

        let firstDevice = UUID(), secondDevice = UUID(), module = UUID()
        let firstKey = "device.\(firstDevice.uuidString).lock"
        let secondKey = "device.\(secondDevice.uuidString).lock"
        let moduleKey = "device.\(firstDevice.uuidString).module.\(module.uuidString)"
        var firstEdit = PicoPhotoEdit(); firstEdit.panX = 0.15; firstEdit.scale = 2.2
        var secondEdit = PicoPhotoEdit(); secondEdit.panX = -0.25; secondEdit.scale = 1.4
        var moduleEdit = PicoPhotoEdit(); moduleEdit.rotation = 90; moduleEdit.scale = 1.2
        ensure(preview.saveUse(assetID: imported.id, key: "lock", target: .pico, edit: firstEdit), "legacy actual-image use saved before migration")
        ensure(preview.saveUse(assetID: imported.id, key: firstKey.lowercased(), target: .pico, edit: firstEdit), "structured lowercase UUID key accepted")
        ensure(preview.saveUse(assetID: imported.id, key: secondKey, target: .pico, edit: secondEdit), "second device use saved independently")
        ensure(preview.saveUse(assetID: imported.id, key: moduleKey, target: .pico, edit: moduleEdit), "module use saved independently")
        ensure(preview.use(for: firstKey)?.edit == firstEdit, "UUID spelling normalized for lookup")
        let previewIndex = preview.rootURL.appendingPathComponent("library.json")
        let previewBefore = try Data(contentsOf: previewIndex)
        let invalidKeys = ["lock:\(firstDevice.uuidString)", "device.no-uuid.lock", "device.\(firstDevice.uuidString).module.no-uuid", "device.\(firstDevice.uuidString).board.extra", "device..lock", "device.\(firstDevice.uuidString).../lock"]
        for key in invalidKeys {
            ensure(!preview.saveUse(assetID: imported.id, key: key, target: .pico, edit: secondEdit), "malformed dynamic key rejected: \(key)")
        }
        try ensure(try Data(contentsOf: previewIndex) == previewBefore, "invalid-key saves leave source index byte-identical")

        let productionRoot = base.appendingPathComponent("production-migrated")
        let production = PicoNativeLibrary.production(rootURL: productionRoot, previewRootURL: preview.rootURL)
        ensure(production.isWritable && production.error == nil && production.assets.count == 1, "first production creation migrates only actual assets")
        let asset = production.assets[0]
        ensure(asset.id == imported.id && asset.name == imported.name && asset.sha256 == imported.sha256 && !asset.isSample, "migration preserves asset identity and original metadata")
        let ownedCopy = productionRoot.appendingPathComponent("objects/\(asset.id.uuidString)/\(asset.originalFilename)")
        try ensure(try Data(contentsOf: ownedCopy) == originalBytes, "migration original is byte-identical")
        let thumbSize = try pixelSize(productionRoot.appendingPathComponent("objects/\(asset.id.uuidString)/thumbnail.png"))
        ensure(thumbSize.max()! <= 640, "migration owns a real bounded thumbnail")
        ensure(production.use(for: "board") == nil, "uses referencing preview fixtures are excluded")
        ensure(production.use(for: "lock")?.edit == firstEdit, "legacy actual-image use preserved")
        ensure(production.use(for: firstKey)?.edit == firstEdit && production.use(for: secondKey)?.edit == secondEdit,
               "different devices preserve independent compositions")
        ensure(production.use(for: moduleKey.lowercased())?.edit == moduleEdit, "module composition survives migration")
        try ensure(try Data(contentsOf: previewIndex) == previewBefore, "migration leaves preview index unchanged")
        let oldOriginal = preview.rootURL.appendingPathComponent("objects/\(imported.id.uuidString)/\(imported.originalFilename)")
        try ensure(try Data(contentsOf: oldOriginal) == originalBytes, "migration preserves preview original bytes")
        let productionReload = PicoNativeLibrary.production(rootURL: productionRoot, previewRootURL: absentPreview)
        ensure(productionReload.assets.map(\.id) == [imported.id] && productionReload.use(for: firstKey)?.edit == firstEdit,
               "production assets and device parameters reload without migration source")
        let existingEmpty = PicoNativeLibrary.production(rootURL: emptyRoot, previewRootURL: preview.rootURL)
        ensure(existingEmpty.assets.isEmpty && existingEmpty.error == nil, "existing production is never replaced by preview migration")
        try ensure(try Data(contentsOf: emptyRoot.appendingPathComponent("library.json")) == emptyManifest, "existing production index is unchanged")

        let brokenPreviewRoot = base.appendingPathComponent("migration-broken-preview")
        let brokenPreview = PicoNativeLibrary(rootURL: brokenPreviewRoot)
        await brokenPreview.importImages(from: [sourceImage])
        ensure(brokenPreview.assets.count == 4 && brokenPreview.error == nil, "broken migration fixture initially valid")
        let brokenAsset = brokenPreview.assets.last!
        let brokenOriginal = brokenPreviewRoot.appendingPathComponent("objects/\(brokenAsset.id.uuidString)/\(brokenAsset.originalFilename)")
        try writePNG(brokenOriginal, width: brokenAsset.width, height: brokenAsset.height, gray: 0.19)
        let brokenIndexURL = brokenPreviewRoot.appendingPathComponent("library.json")
        let brokenIndex = try Data(contentsOf: brokenIndexURL)
        let brokenOriginalBytes = try Data(contentsOf: brokenOriginal)
        let failedRoot = base.appendingPathComponent("production-failed-migration")
        let failed = PicoNativeLibrary.production(rootURL: failedRoot, previewRootURL: brokenPreviewRoot)
        ensure(!failed.isWritable && failed.error != nil && failed.assets.isEmpty, "mismatched original hash blocks migration")
        ensure(!manager.fileExists(atPath: failedRoot.path), "failed migration does not create partial or empty production")
        let siblings = try manager.contentsOfDirectory(atPath: base.path)
        ensure(!siblings.contains(where: { $0.hasPrefix(".production-failed-migration-migration-") }), "failed migration removes its own staging root")
        try ensure(try Data(contentsOf: brokenIndexURL) == brokenIndex && Data(contentsOf: brokenOriginal) == brokenOriginalBytes,
                   "failed migration preserves source index and source file")
        try Data(contentsOf: sourceImage).write(to: brokenOriginal, options: .atomic)
        let retried = PicoNativeLibrary.production(rootURL: failedRoot, previewRootURL: brokenPreviewRoot)
        ensure(retried.isWritable && retried.error == nil && retried.assets.map(\.id) == [brokenAsset.id], "migration can retry after source repair")

        let invalidRoot = base.appendingPathComponent("production-invalid-key")
        try manager.createDirectory(at: invalidRoot, withIntermediateDirectories: true)
        var malformedIndex = try JSONSerialization.jsonObject(with: Data(contentsOf: productionRoot.appendingPathComponent("library.json"))) as! [String: Any]
        var malformedUses = malformedIndex["uses"] as! [String: Any]
        malformedUses["device.not-a-uuid.lock"] = malformedUses["lock"]
        malformedIndex["uses"] = malformedUses
        let invalidData = try JSONSerialization.data(withJSONObject: malformedIndex)
        let invalidURL = invalidRoot.appendingPathComponent("library.json")
        try invalidData.write(to: invalidURL)
        let invalid = PicoNativeLibrary.production(rootURL: invalidRoot, previewRootURL: preview.rootURL)
        ensure(!invalid.isWritable && invalid.error != nil, "load uses the same strict key validation as save")
        try ensure(try Data(contentsOf: invalidURL) == invalidData, "invalid existing production is never overwritten")
        print("PASS: empty production, no fixtures, copy-only migration, stable IDs, fixture-reference exclusion, device/module key isolation, UUID normalization, malformed-key rejection, existing-production preservation, migration hash rollback and repair retry")
    }

    static func ensure(_ value: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !value() { fatalError("FAIL: \(message)") }
    }
    static func pixelSize(_ url: URL) throws -> [Int] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        return [props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int]
    }
    static func writePNG(_ url: URL, width: Int, height: Int, gray: CGFloat) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        ensure(CGImageDestinationFinalize(destination), "fixture PNG")
    }
    @MainActor static func waitForPreview(_ library: PicoNativeLibrary, _ asset: PicoNativeAsset) async -> NSImage? {
        for _ in 0..<200 {
            if let preview = library.image(for: asset) { return preview }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }
}
