import AppKit
import Foundation
import LinxDisplayCore

private func image(width: Int = 160, height: Int = 120, draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height)); draw(context)
    return context.makeImage()!
}
private func rawSolid(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> CGImage {
    let context = CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    for index in 0..<(160 * 120) { let at = index * 4; pixels[at] = red; pixels[at + 1] = green; pixels[at + 2] = blue; pixels[at + 3] = 255 }
    return context.makeImage()!
}
private func solid(_ gray: CGFloat) -> CGImage { rawSolid(UInt8(gray * 255), UInt8(gray * 255), UInt8(gray * 255)) }
private struct Bitmap {
    let data: [UInt8]
    init(_ data: Data) { self.data = Array(data) }
    func u16(_ p: Int) -> Int { Int(data[p]) | Int(data[p + 1]) << 8 }
    func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
    var width: Int { u32(18) }; var height: Int { u32(22) }
    func isBlack(_ x: Int, _ y: Int) -> Bool {
        data[u32(10) + (height - 1 - y) * ((width + 31) / 32 * 4) + x / 8] & (0x80 >> (x % 8)) == 0
    }
    var blackCount: Int { (0..<height).reduce(0) { sum, y in sum + (0..<width).filter { isBlack($0, y) }.count } }
    var centroid: CGPoint {
        var xsum = 0, ysum = 0, count = 0
        for y in 0..<height { for x in 0..<width where isBlack(x, y) { xsum += x; ysum += y; count += 1 } }
        return CGPoint(x: Double(xsum) / Double(max(1, count)), y: Double(ysum) / Double(max(1, count)))
    }
}

@main struct LockScreenEditorTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1; print("PASS " + message)
        }
        let destination = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var options = ReadPicoLockScreenOptions()
        options.output = .monochrome
        let gradient = image { context in
            for x in 0..<160 { context.setFillColor(CGColor(red: CGFloat(x) / 159, green: CGFloat(159 - x) / 159, blue: CGFloat(x % 40) / 39, alpha: 1)); context.fill(CGRect(x: x, y: 0, width: 1, height: 120)) }
        }
        var outputs = Set<Data>()
        for algorithm in ReadPicoLockScreenOptions.Gray.allCases {
            options.gray = algorithm
            let data = try ReadPicoLockScreenRenderer.render(gradient, options: options)
            check(data.count == 107070, "portrait \(algorithm.rawValue) exact 1bit aligned size")
            let bmp = Bitmap(data)
            check(bmp.u16(28) == 1 && bmp.u32(10) == 62 && bmp.width == 684 && bmp.height == 1216 && bmp.u32(2) == data.count, "\(algorithm.rawValue) valid BMP header")
            outputs.insert(data)
        }
        check(outputs.count == 6, "six gray conversions produce distinct color responses")
        options.gray = .luminosity
        for algorithm in ReadPicoLockScreenOptions.Dither.allCases {
            options.dither = algorithm
            let data = try ReadPicoLockScreenRenderer.render(gradient, options: options)
            check(data.count <= 110000 && NSImage(data: data) != nil, "\(algorithm.rawValue) decodes within lock-image contract")
        }
        options.layout = .fill; options.dither = .threshold
        let white = try ReadPicoLockScreenRenderer.render(solid(1), options: options)
        let black = try ReadPicoLockScreenRenderer.render(solid(0), options: options)
        check(Bitmap(white).blackCount == 0 && Bitmap(black).blackCount == options.width * options.height, "white and black remain exact palette endpoints")
        options.dither = .ordered
        let middleGray = Bitmap(try ReadPicoLockScreenRenderer.render(solid(0.5), options: options))
        let coverage = Double(middleGray.blackCount) / Double(options.width * options.height)
        check((0.45...0.55).contains(coverage), "Bayer middle gray preserves approximately fifty percent black coverage")
        let red = rawSolid(255, 0, 0)
        options.gray = .red
        let redChannel = Bitmap(try ReadPicoLockScreenRenderer.render(red, options: options))
        options.gray = .green
        let greenChannel = Bitmap(try ReadPicoLockScreenRenderer.render(red, options: options))
        check(redChannel.blackCount == 0 && greenChannel.blackCount == options.width * options.height, "selected gray conversion applies before Bayer thresholds")
        options.gray = .luminosity; options.dither = .threshold
        let partial = image(width: 100, height: 100) { c in c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 30, y: 30, width: 40, height: 40)) }
        options.layout = .fit
        let centered = Bitmap(try ReadPicoLockScreenRenderer.render(partial, options: options)).centroid
        options.offsetX = 0.1; options.offsetY = 0.1
        let moved = Bitmap(try ReadPicoLockScreenRenderer.render(partial, options: options)).centroid
        check(abs(moved.x - centered.x - 68.4) < 2, "positive X moves final pixels right by requested fraction")
        check(abs(moved.y - centered.y - 121.6) < 2, "positive Y moves final pixels down by requested fraction")
        options.offsetX = 0; options.offsetY = 0
        let fit = ReadPicoLockScreenRenderer.imageRect(source: CGSize(width: 160, height: 120), options: options)
        options.layout = .fill
        let fill = ReadPicoLockScreenRenderer.imageRect(source: CGSize(width: 160, height: 120), options: options)
        check(fit.width <= 684 && fit.height <= 1216 && fill.width >= 684 && fill.height >= 1216, "fit includes entire image and fill covers canvas")
        options.mode = .ascii
        let asciiBlack = try ReadPicoLockScreenRenderer.render(solid(0), options: options)
        let asciiWhite = try ReadPicoLockScreenRenderer.render(solid(1), options: options)
        check(Bitmap(asciiWhite).blackCount == 0, "ASCII leaves white source cells blank")
        check(Bitmap(asciiBlack).blackCount > 10000 && Bitmap(asciiBlack).blackCount < options.width * options.height / 2, "ASCII renders actual sparse black glyphs, not a dither alias")
        let topHalf = image { c in c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 60, width: 160, height: 60)) }
        var photoOptions = options; photoOptions.mode = .image; photoOptions.dither = .threshold
        let photoCentroid = Bitmap(try ReadPicoLockScreenRenderer.render(topHalf, options: photoOptions)).centroid
        let asciiCentroid = Bitmap(try ReadPicoLockScreenRenderer.render(topHalf, options: options)).centroid
        check(abs(photoCentroid.y - asciiCentroid.y) < 30, "ASCII silhouette preserves photograph vertical orientation")
        try asciiBlack.write(to: destination.appendingPathComponent("ascii-black.bmp"))
        options.asciiCellSize = 24
        let largerASCII = try ReadPicoLockScreenRenderer.render(solid(0), options: options)
        check(largerASCII != asciiBlack, "ASCII character size changes actual wire pixels")
        options.landscape = true
        let landscape = try ReadPicoLockScreenRenderer.render(gradient, options: options)
        check(Bitmap(landscape).width == 1216 && Bitmap(landscape).height == 684 && landscape.count == 104030, "landscape ASCII uses exact supported dimensions")
        options.zoom = .nan
        do { _ = try ReadPicoLockScreenRenderer.render(gradient, options: options); preconditionFailure("NaN accepted") } catch { check(true, "invalid nonfinite transforms rejected") }

        var native = ReadPicoLockScreenOptions()
        let nativeRamp = image(width: 256, height: 16) { context in
            for x in 0..<256 { let value = CGFloat(x) / 255; context.setFillColor(CGColor(red: value, green: value, blue: value, alpha: 1)); context.fill(CGRect(x: x, y: 0, width: 1, height: 16)) }
        }
        let nativeImage = try ReadPicoLockScreenRenderer.render(nativeRamp, options: native)
        let nativeBMP = Bitmap(nativeImage)
        check(nativeBMP.u16(28) == 4 && nativeBMP.u32(10) == 118 && nativeImage.count == 418422, "default automatic render preserves native 4bit portrait wire format")
        func levels(_ data: Data) -> Set<UInt8> {
            let bmp = Bitmap(data), stride = (bmp.width * 4 + 31) / 32 * 4
            var result = Set<UInt8>()
            for y in 0..<bmp.height { for x in 0..<bmp.width {
                let value = data[bmp.u32(10) + y * stride + x / 2]
                result.insert((value >> (x.isMultiple(of: 2) ? 4 : 0)) & 15)
            } }
            return result
        }
        check(levels(nativeImage).count == 16, "native gradient contains all sixteen real pixel levels")
        check((0..<16).allSatisfy { level in (0..<3).allSatisfy { nativeImage[54 + level * 4 + $0] == UInt8(level * 17) } }, "native palette contains all exact panel luminances")
        native.dither = .stucki
        let nativeUnchanged = try ReadPicoLockScreenRenderer.render(nativeRamp, options: native)
        check(nativeUnchanged == nativeImage, "native output never applies a binary dither algorithm")
        native.layout = .fill; native.gray = .red
        let nativeRed = try ReadPicoLockScreenRenderer.render(red, options: native)
        native.gray = .green
        let nativeGreen = try ReadPicoLockScreenRenderer.render(red, options: native)
        check(levels(nativeRed) == [15] && levels(nativeGreen) == [0], "selected channel is preserved by native gray16 conversion")
        native.gray = .luminosity; native.landscape = true
        let nativeLandscape = try ReadPicoLockScreenRenderer.render(gradient, options: native)
        check(Bitmap(nativeLandscape).width == 1216 && Bitmap(nativeLandscape).height == 684 && nativeLandscape.count == 415990, "native landscape rows retain exact supported 4bit alignment")
        native.mode = .ascii
        let nativeASCII = try ReadPicoLockScreenRenderer.render(gradient, options: native)
        check(levels(nativeASCII).contains(where: { $0 > 0 && $0 < 15 }), "native ASCII retains gray antialiased character edges")

        let draft = ReadPicoLockScreenDraft(renderer: { source, options in try ReadPicoLockScreenRenderer.render(source, options: options) })
        let tooWide = image(width: 2049, height: 1) { _ in }
        do { try draft.setImage(tooWide, name: "oversized.png"); preconditionFailure("oversized source accepted") } catch { check(!draft.hasImage, "original decode bound rejects dimensions above 2048 without mutation") }
        var delivered: [Data] = [], invalidations = 0
        draft.onRendered = { delivered.append($0) }; draft.onInvalidated = { invalidations += 1 }
        try draft.setImage(gradient, name: "原图.png")
        await ready(draft)
        check(draft.hasUnsavedChanges && draft.bitmap == delivered.last, "new original dirty; displayed and delivered bitmap identical")
        let initialBitmap = draft.bitmap, initialDelivered = delivered.count
        draft.updateOptions(draft.options)
        check(delivered.count == initialDelivered && !draft.rendering, "same edit parameters do not rerender")
        let originalURL = destination.appendingPathComponent("test.picolock")
        try draft.save(to: originalURL)
        check(!draft.hasUnsavedChanges, "saving original marks precisely current source and options clean")
        var modified = draft.options; modified.mode = .ascii; modified.zoom = 1.5; modified.offsetX = 0.12; modified.offsetY = -0.2
        draft.updateOptions(modified)
        check(draft.rendering && invalidations >= 2, "new parameters immediately invalidate old pending payload")
        await ready(draft)
        check(draft.hasUnsavedChanges && draft.bitmap != initialBitmap, "mode and positioning dirty and change real preview")
        try draft.save(to: originalURL)
        let reopened = ReadPicoLockScreenDraft(renderer: { source, options in try ReadPicoLockScreenRenderer.render(source, options: options) })
        try reopened.load(data: Data(contentsOf: originalURL)); await ready(reopened)
        check(!reopened.hasUnsavedChanges && reopened.options == modified && reopened.bitmap == draft.bitmap && reopened.name == "原图.png", "original roundtrip preserves pixels, name and all controls")
        var other = modified; other.offsetX = -0.4
        reopened.updateOptions(other); await ready(reopened)
        var discardDelivered = 0; reopened.onRendered = { _ in discardDelivered += 1 }
        reopened.discardChanges(); await ready(reopened)
        check(reopened.options == modified && !reopened.hasUnsavedChanges && discardDelivered == 0, "discard restores stored original without publishing a new pending upload")
        let retained = reopened.bitmap
        var bad = try JSONSerialization.jsonObject(with: reopened.documentData()) as! [String: Any]; bad["version"] = 99
        do { try reopened.load(data: JSONSerialization.data(withJSONObject: bad)); preconditionFailure("unknown version accepted") } catch { check(reopened.bitmap == retained && reopened.options == modified, "invalid original cannot partially replace current edits") }

        var externalDocument = try JSONSerialization.jsonObject(with: reopened.documentData()) as! [String: Any]
        var externalSnapshot = externalDocument["draft"] as! [String: Any]
        externalSnapshot["image"] = NSBitmapImageRep(cgImage: tooWide).representation(using: .png, properties: [:])!.base64EncodedString()
        externalDocument["draft"] = externalSnapshot
        let bounded = ReadPicoLockScreenDraft(renderer: { _, _ in Data([1]) })
        try bounded.load(data: JSONSerialization.data(withJSONObject: externalDocument)); await ready(bounded)
        var boundedEdit = bounded.options; boundedEdit.zoom = 2; bounded.updateOptions(boundedEdit); await ready(bounded)
        bounded.discardChanges(); await ready(bounded)
        check(bounded.source?.width == 2048 && bounded.source?.height == 1 && !bounded.hasUnsavedChanges, "discarding an external original preserves the same bounded decode as loading")

        var legacyDocument = try JSONSerialization.jsonObject(with: reopened.documentData()) as! [String: Any]
        var legacySnapshot = legacyDocument["draft"] as! [String: Any]
        var legacyOptions = legacySnapshot["options"] as! [String: Any]; legacyOptions["output"] = nil
        legacySnapshot["options"] = legacyOptions; legacyDocument["draft"] = legacySnapshot
        try bounded.load(data: JSONSerialization.data(withJSONObject: legacyDocument)); await ready(bounded)
        check(bounded.options.output == .monochrome, "old original without output field retains its original binary appearance")

        let matched = ReadPicoLockScreenDraft(renderer: { image, options in try ReadPicoLockScreenRenderer.render(image, options: options) })
        var matchedPayload: Data?; matched.onRendered = { matchedPayload = $0 }; matched.onInvalidated = { matchedPayload = nil }
        try matched.setImage(gradient, name: "matched.png"); await ready(matched)
        check(matched.outputBitDepth == 4 && Bitmap(matched.bitmap!).u16(28) == 4 && matched.bitmap == matchedPayload, "offline new draft defaults to exact native preview payload")
        try matched.save(to: destination.appendingPathComponent("matched.picolock"))
        matched.configureOutputCapability(false)
        check(matchedPayload == nil && matched.rendering, "legacy pairing immediately invalidates pending native upload")
        await ready(matched)
        check(matched.outputBitDepth == 1 && Bitmap(matched.bitmap!).u16(28) == 1 && !matched.hasUnsavedChanges, "automatic mode falls back to binary for old capability without dirtying the original")
        matched.configureOutputCapability(true); await ready(matched)
        check(matched.outputBitDepth == 4 && Bitmap(matched.bitmap!).u16(28) == 4 && matched.bitmap == matchedPayload, "new capability upgrades automatic preview and delivered payload together")
        var binaryChoice = matched.options; binaryChoice.output = .monochrome; matched.updateOptions(binaryChoice); await ready(matched)
        check(matched.outputBitDepth == 1 && Bitmap(matched.bitmap!).u16(28) == 1, "explicit binary choice retains all legacy algorithms on a gray16 device")

        let race = ReadPicoLockScreenDraft(renderer: { _, options in
            Thread.sleep(forTimeInterval: options.zoom == 1 ? 0.35 : 0.02)
            return Data([UInt8(options.zoom)])
        })
        var raceOutputs: [Data] = []; race.onRendered = { raceOutputs.append($0) }
        try race.setImage(gradient, name: "race.png")
        try await Task.sleep(nanoseconds: 150_000_000)
        var next = race.options; next.zoom = 2; race.updateOptions(next)
        await ready(race)
        try await Task.sleep(nanoseconds: 300_000_000)
        check(race.bitmap == Data([2]) && raceOutputs == [Data([2])], "slow obsolete render never replaces or delivers newer parameter generation")
        let errorDraft = ReadPicoLockScreenDraft(renderer: { _, options in
            if options.zoom == 2 { throw ReadPicoManagerError.invalid("fixture") }; return Data([1])
        })
        var pending: Data?; errorDraft.onRendered = { pending = $0 }; errorDraft.onInvalidated = { pending = nil }
        try errorDraft.setImage(gradient, name: "error.png"); await ready(errorDraft)
        var fail = errorDraft.options; fail.zoom = 2; errorDraft.updateOptions(fail); await ready(errorDraft)
        check(errorDraft.error != nil && errorDraft.bitmap == nil && pending == nil && errorDraft.hasImage, "failed new render preserves original and prevents stale upload")
        try race.setImage(gradient, name: "clear.png")
        race.clear()
        try await Task.sleep(nanoseconds: 180_000_000)
        check(!race.hasImage && race.bitmap == nil && !race.rendering && raceOutputs == [Data([2])], "clearing original cancels pending publication")

        let report: [String: Any] = ["result":"PASS", "checks":checks, "physical_device_accessed":false, "actual_shared_engine":true, "wire_format":"1bit and 4bit BMP", "native_gray_levels":16, "legacy_capability_fallback":true, "stale_render_rejected":true]
        try JSONSerialization.data(withJSONObject: report, options:[.prettyPrinted,.sortedKeys]).write(to: destination.appendingPathComponent("tests.json"))
        print("PASS \(checks) lock-screen renderer/draft/workflow checks")
    }
    @MainActor static func ready(_ draft: ReadPicoLockScreenDraft) async {
        for _ in 0..<1000 {
            if !draft.rendering { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("render timeout")
    }
}
