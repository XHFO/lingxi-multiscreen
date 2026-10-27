import AppKit

/// Design-preview targets. A nil gray depth deliberately makes no hardware capability claim.
enum PicoPreviewTarget: String, CaseIterable, Identifiable, Codable, Sendable {
    case pico, picoLandscape, oracle, excerpt
    var id: String { rawValue }
    var title: String {
        switch self { case .pico: return "小纸 Pico"; case .picoLandscape: return "小纸 Pico · 横屏"; case .oracle: return "口袋先知"; case .excerpt: return "摘录" }
    }
    var size: CGSize {
        switch self {
        case .pico: return CGSize(width: 684, height: 1216)
        case .picoLandscape: return CGSize(width: 1216, height: 684)
        case .oracle: return CGSize(width: 200, height: 200)
        case .excerpt: return CGSize(width: 296, height: 152)
        }
    }
    var grayLevels: Int? { self == .pico || self == .picoLandscape ? 16 : nil }
}

enum PicoPhotoCropRatio: String, CaseIterable, Identifiable, Codable, Sendable {
    case target, original, square, fourThree, threeTwo, sixteenNine, free
    var id: String { rawValue }
    var title: String {
        switch self {
        case .target: return "目标屏幕"
        case .original: return "原图"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        case .free: return "自由"
        }
    }
    func value(source: CGSize, target: PicoPreviewTarget) -> Double? {
        switch self {
        case .target: return target.size.width / target.size.height
        case .original: return source.width / source.height
        case .square: return 1
        case .fourThree: return 4 / 3
        case .threeTwo: return 3 / 2
        case .sixteenNine: return 16 / 9
        case .free: return nil
        }
    }
}

/// Coordinates refer to a fixed plane of the original image's width × height.
/// Pan/crop are normalized, so window resizing never changes saved composition.
/// Source image bytes are never stored or modified by this value.
struct PicoPhotoEdit: Codable, Equatable, Sendable {
    var version = 1
    var panX: Double = 0
    var panY: Double = 0
    var scale: Double = 1
    var rotation: Double = 0
    var straighten: Double = 0
    var flipX = false
    var flipY = false
    var cropX: Double = 0
    var cropY: Double = 0
    var cropWidth: Double = 1
    var cropHeight: Double = 1
    var ratio: PicoPhotoCropRatio = .target
    var fillTarget = false

    init() {}

    var crop: CGRect { CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight) }
    var totalAngle: Double { rotation + straighten }

    func normalized() -> Self {
        var result = self
        func finite(_ value: Double, _ fallback: Double) -> Double { value.isFinite ? value : fallback }
        func bounded(_ value: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, value)) }
        result.version = 1
        result.panX = bounded(finite(panX, 0), -2, 2)
        result.panY = bounded(finite(panY, 0), -2, 2)
        result.scale = bounded(finite(scale, 1), 0.000001, 6)
        result.rotation = (finite(rotation, 0) / 90).rounded() * 90
        result.rotation = result.rotation.truncatingRemainder(dividingBy: 360)
        if result.rotation < 0 { result.rotation += 360 }
        result.straighten = bounded(finite(straighten, 0), -45, 45)
        result.cropWidth = bounded(finite(cropWidth, 1), 0.000001, 1)
        result.cropHeight = bounded(finite(cropHeight, 1), 0.000001, 1)
        result.cropX = bounded(finite(cropX, 0), 0, 1 - result.cropWidth)
        result.cropY = bounded(finite(cropY, 0), 0, 1 - result.cropHeight)
        return result
    }

    mutating func fitCrop(_ ratio: PicoPhotoCropRatio, source: CGSize, target: PicoPreviewTarget) {
        self.ratio = ratio
        guard let value = ratio.value(source: source, target: target) else { return }
        let centerX = cropX + cropWidth / 2, centerY = cropY + cropHeight / 2
        let normalizedRatio = value * source.height / source.width
        cropWidth = min(1, normalizedRatio)
        cropHeight = min(1, 1 / normalizedRatio)
        cropX = min(1 - cropWidth, max(0, centerX - cropWidth / 2))
        cropY = min(1 - cropHeight, max(0, centerY - cropHeight / 2))
    }

    static func centered(source: CGSize, target: PicoPreviewTarget) -> Self {
        var result = Self()
        result.fitCrop(.target, source: source, target: target)
        return result
    }
}

/// Shared native renderer for the editor, saved thumbnails, and design-preview destinations.
/// It only creates an NSImage; it has no transport, file, or device side effects.
enum PicoPhotoRenderer {
    static func sourceSize(image: NSImage) -> CGSize {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cg.width, height: cg.height)
        }
        return CGSize(width: max(1, image.size.width), height: max(1, image.size.height))
    }

    /// Unquantized RGB composition for production effects (gray channels, ASCII and dithering).
    /// This never replaces the source image or performs device/file operations.
    static func composeColor(image: NSImage, edit: PicoPhotoEdit, target: PicoPreviewTarget) -> NSImage {
        compose(image: image, edit: edit, target: target, quantize: false)
    }

    static func render(image: NSImage, edit: PicoPhotoEdit, target: PicoPreviewTarget) -> NSImage {
        compose(image: image, edit: edit, target: target, quantize: true)
    }

    private static func compose(image: NSImage, edit: PicoPhotoEdit, target: PicoPreviewTarget, quantize: Bool) -> NSImage {
        let size = target.size, width = Int(size.width), height = Int(size.height)
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            return NSImage(size: size)
        }
        let edit = edit.normalized(), sw = Double(source.width), sh = Double(source.height)
        let cw = edit.cropWidth * sw, ch = edit.cropHeight * sh
        let factor = edit.fillTarget ? max(size.width / cw, size.height / ch) : min(size.width / cw, size.height / ch)
        let output = CGRect(x: (size.width - cw * factor) / 2, y: (size.height - ch * factor) / 2,
                            width: cw * factor, height: ch * factor)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        context.saveGState()
        // Work in the same top-left coordinates as the SwiftUI editing plane.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: output)
        context.translateBy(x: output.minX, y: output.minY)
        context.scaleBy(x: factor, y: factor)
        context.translateBy(x: -edit.cropX * sw, y: -edit.cropY * sh)
        context.translateBy(x: sw * (0.5 + edit.panX), y: sh * (0.5 + edit.panY))
        context.rotate(by: edit.totalAngle * .pi / 180)
        context.scaleBy(x: edit.scale * (edit.flipX ? -1 : 1), y: edit.scale * (edit.flipY ? -1 : 1))
        context.translateBy(x: -sw / 2, y: -sh / 2)
        // CGImage pixels have the opposite vertical convention to the editing plane.
        context.translateBy(x: 0, y: sh)
        context.scaleBy(x: 1, y: -1)
        context.draw(source, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        context.restoreGState()
        if quantize, target.grayLevels == 16, let data = context.data {
            let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            for index in stride(from: 0, to: width * height * 4, by: 4) {
                let luminance = 0.2126 * Double(bytes[index]) + 0.7152 * Double(bytes[index + 1]) + 0.0722 * Double(bytes[index + 2])
                let gray = UInt8(min(255, max(0, (luminance / 17).rounded() * 17)))
                bytes[index] = gray; bytes[index + 1] = gray; bytes[index + 2] = gray; bytes[index + 3] = 255
            }
        }
        guard let outputImage = context.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: outputImage, size: size)
    }
}
