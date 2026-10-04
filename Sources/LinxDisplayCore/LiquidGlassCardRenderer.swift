import Accelerate
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Captures layout layers before the classic renderer flattens its opaque panels.
/// Scope is synchronous and thread-local: ink renders and unrelated bitmap helpers
/// must never inherit a color device's capture context.
internal final class ColorCardSceneCapture {
    private static let scopeKey = "com.lingxi.multiscreen.color-card-scene"
    private static var current: ColorCardSceneCapture? {
        Thread.current.threadDictionary[scopeKey] as? ColorCardSceneCapture
    }
    static var isActive: Bool { current != nil }
    static func isCapturing(_ ctx: CGContext) -> Bool { current?.context === ctx }

    struct Pane {
        var bounds: CGRect // Core Graphics device coordinates (bottom-left)
        var radius: CGFloat
        var tint: CGColor
    }
    enum Layer {
        case bitmap(CGImage)
        case pane(Pane)
    }
    var palette: ScreenPalette
    var layers: [Layer] = []
    private var context: CGContext?
    private var lastPane: CGRect?
    private var paneCount = 0
    var size: CGSize { context.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }

    init(palette: ScreenPalette) { self.palette = palette }

    func run<T>(_ body: () throws -> T) rethrows -> T {
        let previous = Thread.current.threadDictionary[Self.scopeKey]
        Thread.current.threadDictionary[Self.scopeKey] = self
        defer {
            if let previous { Thread.current.threadDictionary[Self.scopeKey] = previous }
            else { Thread.current.threadDictionary.removeObject(forKey: Self.scopeKey) }
        }
        let result = try body()
        if let context { flush(context, clear: false) }
        return result
    }

    static func attach(_ ctx: CGContext) {
        guard let capture = current, capture.context == nil else { return }
        capture.context = ctx
    }

    @discardableResult
    static func background(_ ctx: CGContext, palette: ScreenPalette) -> Bool {
        guard let capture = current else { return false }
        attach(ctx)
        guard capture.context === ctx else { return false }
        capture.palette = palette
        return true
    }

    @discardableResult
    static func panel(_ ctx: CGContext, bounds: CGRect, radius: CGFloat, color: CGColor) -> Bool {
        guard let capture = current, capture.context === ctx,
              capture.paneCount < 24 else { return false }
        let transformed = bounds.applying(ctx.ctm).standardized
        let rgb = components(color)
        // Keep thin progress tracks, saturated progress fills, small badges and
        // translucent artwork glows as ordinary foreground drawing.
        guard transformed.width >= 26, transformed.height >= 18,
              transformed.width * transformed.height >= 700,
              color.alpha >= 0.55,
              max(rgb.0, rgb.1, rgb.2) - min(rgb.0, rgb.1, rgb.2) < 0.46,
              transformed.intersects(CGRect(origin: .zero, size: capture.size)) else { return false }
        capture.flush(ctx, clear: true)
        let scale = hypot(ctx.ctm.a, ctx.ctm.b)
        capture.layers.append(.pane(Pane(bounds: transformed, radius: radius * scale, tint: color)))
        capture.lastPane = transformed
        capture.paneCount += 1
        return true
    }

    static func suppressStroke(_ ctx: CGContext, bounds: CGRect) -> Bool {
        guard let capture = current, capture.context === ctx else { return false }
        return capture.lastPane == bounds.applying(ctx.ctm).standardized
    }

    private func flush(_ ctx: CGContext, clear: Bool) {
        if let image = ctx.makeImage() { layers.append(.bitmap(image)) }
        guard clear else { return }
        ctx.saveGState()
        ctx.resetClip()
        ctx.concatenate(ctx.ctm.inverted())
        ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.restoreGState()
    }

    static func components(_ color: CGColor) -> (Double, Double, Double) {
        let rgb = color.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)
        let values = rgb?.components ?? [0, 0, 0, 1]
        return (Double(values[0]), Double(values[1]), Double(values[2]))
    }
}

/// Exportable SwiftUI glass styling, not Apple's live `.glassEffect` material.
/// Native glass cannot reliably be exported with ImageRenderer; these explicit
/// layers retain all existing text/image layout and require no visible window.
@MainActor
public enum LiquidGlassCardRenderer {
    private struct Entry { var key: SHA256.Digest; var image: CGImage }
    private static var cache: [Entry] = []
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static var coreImageBlurUnavailable = false
    public static func clearCache() { cache.removeAll() }
    private static func trace(_ message: String) {
        if ProcessInfo.processInfo.environment["LINGXI_GLASS_DEBUG"] == "1" {
            print("Liquid Glass: \(message)")
        }
    }

    public static func renderKeyboard(settings: AppSettings,
                                      render: () throws -> RenderResult) throws -> RenderResult {
        // Emoji 是完整壁纸，不应因全局卡片风格改变底色、模糊或增加玻璃遮罩。
        guard settings.cardRenderingMode == .liquidGlass,
              settings.displayMode != .emojiWallpaper else { return try render() }
        let capture = ColorCardSceneCapture(palette: settings.resolvedPalette)
        let original = try capture.run(render)
        guard capture.size != .zero else { return original }
        guard let image = compose(capture) else {
            // Never transmit an incomplete captured foreground if export fails.
            return try render()
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { throw RenderError.encodeFailed }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality:
            Double(min(max(settings.jpegQuality, 50), 100)) / 100] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encodeFailed }
        guard data.length <= ScreenRenderer.maximumFileSize else { throw RenderError.tooLarge(data.length) }
        return RenderResult(data: data as Data, image: image)
    }

    public static func renderImage(for deviceType: DeviceType, mode: CardRenderingMode,
                                   palette: ScreenPalette,
                                   render: () throws -> CGImage) throws -> CGImage {
        guard mode == .liquidGlass, CardRenderingMode.supports(deviceType) else { return try render() }
        let capture = ColorCardSceneCapture(palette: palette)
        let original = try capture.run(render)
        guard capture.size != .zero else { return original }
        if let image = compose(capture) { return image }
        return try render()
    }

    private static func sceneKey(_ scene: ColorCardSceneCapture) -> SHA256.Digest {
        var hash = SHA256()
        func add(_ text: String) { hash.update(data: Data(text.utf8)) }
        add("\(scene.size)|\(scene.palette.background)|\(scene.palette.accent)|\(scene.palette.secondaryAccent)")
        for layer in scene.layers {
            switch layer {
            case .bitmap(let image):
                add("image:\(image.width),\(image.height),\(image.bytesPerRow),\(image.bitmapInfo.rawValue)")
                if let data = image.dataProvider?.data { hash.update(data: data as Data) }
            case .pane(let pane):
                add("pane:\(pane.bounds),\(pane.radius),\(ColorCardSceneCapture.components(pane.tint)),\(pane.tint.alpha)")
            }
        }
        return hash.finalize()
    }

    private static func compose(_ scene: ColorCardSceneCapture) -> CGImage? {
        guard scene.size.width > 0, scene.size.height > 0 else { return nil }
        let key = sceneKey(scene)
        if let index = cache.firstIndex(where: { $0.key == key }) {
            let entry = cache.remove(at: index)
            cache.append(entry)
            return entry.image
        }
        let size = scene.size
        let baseRenderer = ImageRenderer(content: GlassBackdrop(palette: scene.palette, size: size)
            .frame(width: size.width, height: size.height))
        baseRenderer.scale = 1
        baseRenderer.isOpaque = true
        guard let base = baseRenderer.cgImage,
              let backdrop = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                  bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            trace("backdrop ImageRenderer failed")
            return nil
        }
        let full = CGRect(origin: .zero, size: size)
        backdrop.draw(base, in: full)
        var layers: [GlassExportLayer] = []
        for layer in scene.layers {
            switch layer {
            case .bitmap(let image):
                layers.append(.bitmap(image))
                backdrop.draw(image, in: full)
            case .pane(let pane):
                guard let underlying = backdrop.makeImage() else { return nil }
                guard let glass = blurBackdrop(underlying) else { return nil }
                layers.append(.pane(pane, glass))
                // A cheap underlay approximation for subsequent nested panes;
                // actual highlights and edges are composed once by SwiftUI.
                backdrop.saveGState()
                backdrop.addPath(CGPath(roundedRect: pane.bounds, cornerWidth: pane.radius,
                                       cornerHeight: pane.radius, transform: nil))
                backdrop.clip()
                backdrop.draw(glass, in: full)
                backdrop.setFillColor(pane.tint.copy(alpha: 0.35) ?? pane.tint)
                backdrop.fill(pane.bounds)
                backdrop.restoreGState()
            }
        }
        let renderer = ImageRenderer(content: GlassExportView(base: base, layers: layers, size: size))
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage, image.width == Int(size.width),
              image.height == Int(size.height) else {
            trace("composition ImageRenderer failed: \(String(describing: renderer.cgImage.map { CGSize(width: $0.width, height: $0.height) }))")
            return nil
        }
        cache.append(Entry(key: key, image: image))
        // Six native-resolution frames retain < 1.5 MB and share no device state.
        if cache.count > 6 { cache.removeFirst(cache.count - 6) }
        return image
    }

    private static func blurBackdrop(_ image: CGImage) -> CGImage? {
        if !coreImageBlurUnavailable {
            let source = CIImage(cgImage: image)
            let blurred = source.clampedToExtent().applyingFilter("CIGaussianBlur",
                parameters: [kCIInputRadiusKey: 7.0]).cropped(to: source.extent)
            if let result = ciContext.createCGImage(blurred, from: source.extent) { return result }
            // Even Core Image's software renderer can depend on unavailable
            // graphics services. Stop retrying it for every pane in this process.
            coreImageBlurUnavailable = true
            trace("Core Image unavailable; using CPU bitmap blur")
        }
        let width = image.width
        let height = image.height
        func context() -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let first = context(), let second = context(),
              let firstData = first.data, let secondData = second.data else { return nil }
        first.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var input = vImage_Buffer(data: firstData, height: vImagePixelCount(height),
                                  width: vImagePixelCount(width), rowBytes: width * 4)
        var output = vImage_Buffer(data: secondData, height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: width * 4)
        // Three 13px boxes approximate the 7px Gaussian while retaining clamped
        // edges. Buffers are native screen size and released after each pane.
        for _ in 0..<3 {
            guard vImageBoxConvolve_ARGB8888(&input, &output, nil, 0, 0, 13, 13,
                nil, vImage_Flags(kvImageEdgeExtend)) == kvImageNoError else { return nil }
            swap(&input, &output)
        }
        return second.makeImage()
    }
}

private struct GlassBackdrop: View {
    var palette: ScreenPalette
    var size: CGSize
    var body: some View {
            let width = size.width
            let height = size.height
            ZStack {
                Color(cgColor: palette.backgroundCG)
                Ellipse().fill(Color(cgColor: palette.accentCG).opacity(0.62))
                    .frame(width: width * 1.45, height: height * 0.63)
                    .blur(radius: width * 0.30)
                    .position(x: width * 0.12, y: height * 0.18)
                Ellipse().fill(Color(cgColor: palette.secondaryAccentCG).opacity(0.50))
                    .frame(width: width * 1.45, height: height * 0.52)
                    .blur(radius: width * 0.34)
                    .position(x: width * 0.94, y: height * 0.78)
            }.frame(width: width, height: height).clipped()
    }
}

private enum GlassExportLayer {
    case bitmap(CGImage)
    case pane(ColorCardSceneCapture.Pane, CGImage)
}

private struct GlassExportView: View {
    var base: CGImage
    var layers: [GlassExportLayer]
    var size: CGSize
    var body: some View {
        ZStack(alignment: .topLeading) {
            image(base)
            ForEach(layers.indices, id: \.self) { index in
                switch layers[index] {
                case .bitmap(let bitmap): image(bitmap)
                case .pane(let pane, let backdrop):
                    glass(pane, backdrop: backdrop)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .environment(\.displayScale, 1)
    }

    private func image(_ bitmap: CGImage) -> some View {
        Image(decorative: bitmap, scale: 1).resizable().interpolation(.none)
            .frame(width: size.width, height: size.height)
    }

    private func glass(_ pane: ColorCardSceneCapture.Pane, backdrop: CGImage) -> some View {
        let rect = CGRect(x: pane.bounds.minX, y: size.height - pane.bounds.maxY,
                          width: pane.bounds.width, height: pane.bounds.height)
        let shape = RoundedRectangle(cornerRadius: pane.radius, style: .continuous)
        let rgb = ColorCardSceneCapture.components(pane.tint)
        let dark = rgb.0 * 0.299 + rgb.1 * 0.587 + rgb.2 * 0.114 < 0.5
        return ZStack {
            image(backdrop).offset(x: -rect.minX, y: -rect.minY)
                .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            Color(cgColor: pane.tint).opacity(dark ? 0.46 : 0.60)
            LinearGradient(colors: [.white.opacity(dark ? 0.10 : 0.36), .clear,
                                    .white.opacity(dark ? 0.02 : 0.09)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(
            colors: [.white.opacity(dark ? 0.58 : 0.95), .white.opacity(0.12),
                     .white.opacity(dark ? 0.28 : 0.72)],
            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
        .shadow(color: .black.opacity(dark ? 0.18 : 0.10), radius: 3, x: 0, y: 2)
        .offset(x: rect.minX, y: rect.minY)
    }
}
