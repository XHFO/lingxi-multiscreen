import AppKit
import Foundation
import LinxDisplayCore

/// Exercises the production BMP path; no device, USB volume or live app is used.
@main struct NativeLockScreenCompositionTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1; print("PASS " + message)
        }
        func source(_ red: UInt8, _ green: UInt8, _ blue: UInt8, patterned: Bool = false) -> CGImage {
            let c = CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 640,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            let p = c.data!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<120 { for x in 0..<160 {
                let at = (y * 160 + x) * 4
                p[at] = patterned ? UInt8(x * 255 / 159) : red
                p[at + 1] = patterned ? UInt8(y * 255 / 119) : green
                p[at + 2] = patterned ? UInt8((x + y) * 255 / 278) : blue
                p[at + 3] = 255
            } }
            return c.makeImage()!
        }
        func rgba(_ image: NSImage) -> [UInt8] {
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let c = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            c.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: cg.width * cg.height * 4))
        }
        func u16(_ data: Data, _ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ data: Data, _ at: Int) -> Int { u16(data, at) | u16(data, at + 2) << 16 }
        func levels(_ data: Data) -> [UInt8] {
            let w = u32(data, 18), h = u32(data, 22), offset = u32(data, 10), stride = (w * 4 + 31) / 32 * 4
            return (0..<(w * h)).map { index in
                let x = index % w, y = index / w
                return (data[offset + y * stride + x / 2] >> (x.isMultiple(of: 2) ? 4 : 0)) & 15
            }
        }
        let original = source(0, 0, 0, patterned: true)
        let retainedPixels = original.dataProvider!.data! as Data
        let ns = NSImage(cgImage: original, size: CGSize(width: original.width, height: original.height))
        var edit = PicoPhotoEdit.centered(source: CGSize(width: 160, height: 120), target: .pico)
        edit.rotation = 90; edit.straighten = 12; edit.flipX = true; edit.panX = 0.12
        let color = PicoPhotoRenderer.composeColor(image: ns, edit: edit, target: .picoLandscape)
        check(PicoPhotoRenderer.sourceSize(image: color) == CGSize(width: 1216, height: 684), "color composition uses the native landscape dimensions")
        let colorPixels = rgba(color)
        check(stride(from: 0, to: colorPixels.count, by: 4).contains { colorPixels[$0] != colorPixels[$0 + 1] }, "composition preserves RGB before production gray/channel/ASCII effects")
        check(original.dataProvider!.data! as Data == retainedPixels, "compose never modifies original image pixels")
        let quantized = rgba(PicoPhotoRenderer.render(image: ns, edit: edit, target: .picoLandscape))
        check(stride(from: 0, to: quantized.count, by: 4).allSatisfy { quantized[$0] == quantized[$0 + 1] && quantized[$0] == quantized[$0 + 2] && quantized[$0] % 17 == 0 && quantized[$0 + 3] == 255 }, "editor landscape preview contains only exact opaque 16-gray values")

        let red = source(255, 0, 0)
        var native = ReadPicoLockScreenOptions()
        native.output = .gray16
        native.photoEditData = try JSONEncoder().encode(PicoPhotoEdit.centered(source: CGSize(width: 160, height: 120), target: .pico))
        native.gray = .red
        let redChannel = try ReadPicoLockScreenRenderer.render(red, options: native)
        native.gray = .green
        let greenChannel = try ReadPicoLockScreenRenderer.render(red, options: native)
        check(Set(levels(redChannel)) == [15] && Set(levels(greenChannel)) == [0], "native geometry passes true color to the existing channel conversion")
        for landscape in [false, true] {
            native.landscape = landscape; native.gray = .luminosity
            let output = try ReadPicoLockScreenRenderer.render(original, options: native)
            check(u32(output, 18) == native.width && u32(output, 22) == native.height && u16(output, 28) == 4, "production geometry emits exact \(native.width)x\(native.height) 4-bit BMP")
            check((0..<16).allSatisfy { n in (0..<3).allSatisfy { output[54 + n * 4 + $0] == UInt8(n * 17) } }, "production native palette remains the physical 16-gray palette")
            native.mode = .ascii
            let ascii = try ReadPicoLockScreenRenderer.render(original, options: native)
            check(ascii != output && Set(levels(ascii)).contains { $0 > 0 && $0 < 15 }, "native composition retains the actual antialiased ASCII effect")
            native.mode = .image
            native.output = .monochrome
            for kernel in ReadPicoLockScreenOptions.Dither.allCases {
                native.dither = kernel
                let bitmap = try ReadPicoLockScreenRenderer.render(original, options: native)
                check(u16(bitmap, 28) == 1 && NSImage(data: bitmap) != nil, "native composition preserves \(kernel.rawValue) binary output")
            }
            native.output = .gray16
        }
        for layout in ReadPicoLockScreenOptions.Layout.allCases {
            var legacy = ReadPicoLockScreenOptions(); legacy.output = .gray16; legacy.layout = layout
            legacy.zoom = 0.25; legacy.offsetX = 0.11; legacy.offsetY = -0.09
            let before = try ReadPicoLockScreenRenderer.render(original, options: legacy)
            let migrated = ReadPicoLockScreenRenderer.legacyComposition(source: CGSize(width: 160, height: 120), options: legacy)
            if layout == .fit { check(migrated.scale < 0.25, "legacy minimum fit zoom is migrated without the old native scale clamp") }
            legacy.photoEditData = try JSONEncoder().encode(migrated)
            let after = try ReadPicoLockScreenRenderer.render(original, options: legacy)
            let a = levels(before), b = levels(after)
            let difference = zip(a, b).filter { abs(Int($0) - Int($1)) > 1 }.count
            check(difference < 1500, "legacy \(layout.rawValue) placement retains its visible pixels when opening native geometry")
        }
        let draft = ReadPicoLockScreenDraft(renderer: { image, options in try ReadPicoLockScreenRenderer.render(image, options: options) })
        try draft.setImage(original, name: "original.png")
        await ready(draft)
        let oldData = try draft.documentData()
        let oldDocument = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
        check(oldDocument["version"] as? Int == 1 && draft.options.photoEditData == nil, "unmodified source continues to save a legacy v1 document")
        var next = draft.options
        next.wallpaperAssetID = UUID()
        next.photoEditData = try JSONEncoder().encode(edit)
        draft.updateOptions(next); await ready(draft)
        let document = try draft.documentData()
        let parsed = try JSONSerialization.jsonObject(with: document) as! [String: Any]
        check(parsed["version"] as? Int == 2, "native composition is saved with explicit document version 2")
        check((oldDocument["draft"] as! [String: Any])["image"] as? String == (parsed["draft"] as! [String: Any])["image"] as? String, "native edits preserve the same embedded source bytes")
        let restored = ReadPicoLockScreenDraft(renderer: { image, options in try ReadPicoLockScreenRenderer.render(image, options: options) })
        try restored.load(data: document); await ready(restored)
        check(restored.options == draft.options && restored.bitmap == draft.bitmap && !restored.hasUnsavedChanges, "v2 source plus geometry roundtrip preserves exact outgoing pixels")
        try restored.load(data: oldData); await ready(restored)
        check(restored.options.photoEditData == nil && restored.bitmap != draft.bitmap, "old v1 source still restores through the unchanged legacy renderer")
        var oversized = restored.options; oversized.photoEditData = Data(repeating: 1, count: 16385)
        check(!oversized.isValid, "draft rejects oversized opaque edit parameters")
        try draft.setImage(red, name: "another.png"); await ready(draft)
        check(draft.options.photoEditData == nil && draft.options.wallpaperAssetID == nil, "replacing a source clears the prior image association and geometry")
        print("PASS \(checks) native lock-screen production composition checks; no hardware accessed")
    }
    @MainActor private static func ready(_ draft: ReadPicoLockScreenDraft) async {
        for _ in 0..<1000 { if !draft.rendering { precondition(draft.error == nil, draft.error ?? ""); return }; try? await Task.sleep(for: .milliseconds(10)) }
        preconditionFailure("render timeout")
    }
}
