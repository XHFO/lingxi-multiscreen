import AppKit
import CoreGraphics
import Foundation
import ImageIO

@main struct Gray16Tests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(value(), message)
    }
    static func capability(_ native: Bool = true) throws -> ReadPicoCanvasCapability {
        let extra = native ? ",\"gray_levels\":16,\"bit_depths\":[1,4]" : ""
        return try JSONDecoder().decode(ReadPicoCanvasCapability.self, from: Data("{\"supported\":true,\"width\":684,\"height\":1216,\"formats\":[\"image/bmp\"],\"max_bytes\":420000\(extra)}".utf8))
    }
    static func rejects(_ data: Data, _ cap: ReadPicoCanvasCapability) {
        do { try ReadPicoBitmap.validateCanvas(data, capability: cap); fatalError("invalid bitmap accepted") }
        catch { checks += 1 }
    }
    static func image(_ width: Int, _ height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let level = min(15, x * 16 / width)
            pixels[y * width + x] = UInt8((y < height / 2 ? level : 15 - level) * 17)
        } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func main() throws {
        let native = try capability(), legacy = try capability(false)
        check(native.supportsNativeGray16, "native capability")
        check(!legacy.supportsNativeGray16, "missing capability must not imply gray16")
        let out = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (w, h) in [(684, 1216), (1216, 684)] {
            let source = image(w, h)
            let bmp = try ReadPicoBitmap.makeGray16(image: source, width: w, height: h)
            try ReadPicoBitmap.validateCanvas(bmp, capability: native)
            check(bmp.count == (w == 684 ? 418422 : 415990), "full-resolution aligned payload")
            check(bmp[28] == 4, "four-bit image")
            check(Set(stride(from: 54, to: 118, by: 4).map { bmp[$0] }).count == 16, "sixteen distinct palette levels")
            let url = out.appendingPathComponent("gray16-\(w)x\(h).bmp")
            try bmp.write(to: url)
            guard let decodedSource = CGImageSourceCreateWithData(bmp as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(decodedSource, 0, nil) else { fatalError("system decoder rejected BMP4") }
            check(decoded.width == w && decoded.height == h, "independent system decoder dimensions")
            let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: w, height: h))
            let actual = context.data!.assumingMemoryBound(to: UInt8.self)
            for y in [h / 4, h * 3 / 4] { for level in 0..<16 {
                let x = (2 * level + 1) * w / 32
                let expected = (y < h / 2 ? level : 15 - level) * 17
                check(abs(Int(actual[y * w + x]) - expected) <= 1, "gray value and top/bottom orientation")
            } }
            rejects(Data(bmp.dropLast()), native)
            rejects(bmp, legacy)
            var badPalette = bmp; badPalette[58] = badPalette[54]; badPalette[59] = badPalette[55]; badPalette[60] = badPalette[56]
            rejects(badPalette, native)
            var colored = bmp; colored[54] = 17
            rejects(colored, native)
            for field in [6, 8, 57, 50] {
                var reserved = bmp; reserved[field] = 1
                rejects(reserved, native)
            }
            var size = bmp; size[34] ^= 1
            rejects(size, native)
            var depth = bmp; depth[28] = 8
            rejects(depth, native)
            let wrapped = Data([123]) + bmp
            try ReadPicoBitmap.validateCanvas(wrapped.dropFirst(), capability: native)
            checks += 1
            let blackWhite = try ReadPicoBitmap.make(image: source, width: w, height: h)
            try ReadPicoBitmap.validateCanvas(blackWhite, capability: legacy)
            checks += 1
        }
        for size in [0, 2, 61, 62, 117] { rejects(Data(repeating: 0, count: size), native) }
        print("PASS \(checks) gray16 encoding, system decode, orientation, capability and malformed-payload checks")
    }
}
