import AppKit
import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func pixels(_ image: NSImage) -> (Int, Int, [UInt8]) {
    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    return (cg.width, cg.height, Array(cg.dataProvider!.data! as Data))
}
let sourceWidth = 300, sourceHeight = 180
let colorSpace = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: sourceWidth, height: sourceHeight,
                        bitsPerComponent: 8, bytesPerRow: sourceWidth * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
for x in 0..<sourceWidth {
    context.setFillColor(CGColor(red: Double(x) / 299, green: Double(x) / 450, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: x, y: 0, width: 1, height: sourceHeight))
}
context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
let source = NSImage(cgImage: context.makeImage()!, size: CGSize(width: sourceWidth, height: sourceHeight))
let original = pixels(source).2
for target in PicoPreviewTarget.allCases {
    let edit = PicoPhotoEdit.centered(source: CGSize(width: sourceWidth, height: sourceHeight), target: target)
    let output = pixels(PicoPhotoRenderer.render(image: source, edit: edit, target: target))
    expect(output.0 == Int(target.size.width) && output.1 == Int(target.size.height), "native target dimensions \(target)")
    let repeated = pixels(PicoPhotoRenderer.render(image: source, edit: edit, target: target))
    expect(output.2 == repeated.2, "deterministic committed preview \(target)")
    if target.grayLevels == 16 {
        let cg = PicoPhotoRenderer.render(image: source, edit: edit, target: target).cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let bytes = Array(cg.dataProvider!.data! as Data)
        expect(cg.bitsPerPixel == 32, "RGBA output")
        var levels = Set<UInt8>()
        var allGray16 = true
        for i in stride(from: 0, to: bytes.count, by: 4) {
            allGray16 = allGray16 && bytes[i] == bytes[i+1] && bytes[i] == bytes[i+2] && bytes[i] % 17 == 0
            levels.insert(bytes[i])
        }
        expect(allGray16, "every output pixel is one of 16 gray levels")
        print("Pico gray levels:", levels.sorted())
        expect(levels.count > 2 && levels.count <= 16, "meaningful quantized gray ramp")
    }
    var flipped = edit; flipped.flipX = true
    expect(output.2 != pixels(PicoPhotoRenderer.render(image: source, edit: flipped, target: target)).2, "flip changes asymmetric source \(target)")
}
expect(pixels(source).2 == original, "render preserves original pixels")
var edit = PicoPhotoEdit(); edit.fitCrop(.threeTwo, source: CGSize(width: 300, height: 180), target: .pico)
expect(abs((edit.cropWidth * 300) / (edit.cropHeight * 180) - 1.5) < 0.000001, "3:2 source coordinate crop")
let encoded = try JSONEncoder().encode(edit)
let decoded = try JSONDecoder().decode(PicoPhotoEdit.self, from: encoded)
expect(decoded == edit, "lossless parameter round trip")
print("PASS: \(checks) native renderer and composition checks")
