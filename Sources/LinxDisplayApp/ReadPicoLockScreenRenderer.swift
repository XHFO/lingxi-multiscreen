import AppKit
import CoreText
import LinxDisplayCore

/// Adapts the existing Oracle image engine to Pico's native 16-gray or legacy binary lock-image contract.
/// The returned BMP is both the displayed preview and the transmitted payload.
enum ReadPicoLockScreenRenderer {
    static func imageRect(source: CGSize, options: ReadPicoLockScreenOptions) -> CGRect {
        let width = CGFloat(options.width), height = CGFloat(options.height)
        let xScale = width / source.width, yScale = height / source.height
        let scale = (options.layout == .fit ? min(xScale, yScale) : max(xScale, yScale)) * options.zoom
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (width - size.width) / 2 + options.offsetX * width,
                      y: (height - size.height) / 2 - options.offsetY * height,
                      width: size.width, height: size.height)
    }
    /// Exact affine migration from the v1 target-relative placement into source-relative composition.
    /// Used only to initialize the native editor; opening/cancelling never changes a legacy draft.
    static func legacyComposition(source: CGSize, options: ReadPicoLockScreenOptions) -> PicoPhotoEdit {
        let sw = max(1, source.width), sh = max(1, source.height)
        let tw = Double(options.width), th = Double(options.height)
        let ratio = (tw / th) * (sh / sw)
        let cw = min(1, ratio), ch = min(1, 1 / ratio)
        let q = max(tw / sw, th / sh)
        let base = options.layout == .fit ? min(tw / sw, th / sh) : q
        var edit = PicoPhotoEdit()
        edit.cropWidth = cw; edit.cropHeight = ch
        edit.cropX = (1 - cw) / 2; edit.cropY = (1 - ch) / 2
        edit.scale = base * options.zoom / q
        edit.panX = options.offsetX * tw / (q * sw)
        edit.panY = options.offsetY * th / (q * sh)
        return edit.normalized()
    }
    static func render(_ source: CGImage, options: ReadPicoLockScreenOptions) throws -> Data {
        guard options.isValid, source.width > 0, source.height > 0,
              let context = CGContext(data: nil, width: options.width, height: options.height, bitsPerComponent: 8, bytesPerRow: options.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ReadPicoManagerError.invalid("图片锁屏的画面参数无效。")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: options.width, height: options.height))
        context.interpolationQuality = .high
        if let data = options.photoEditData {
            let edit: PicoPhotoEdit
            do { edit = try JSONDecoder().decode(PicoPhotoEdit.self, from: data) }
            catch { throw ReadPicoManagerError.invalid("图片构图参数无法读取，请重新调整构图。") }
            guard edit.version == 1 else { throw ReadPicoManagerError.invalid("图片构图版本不受支持，请更新软件。") }
            let target: PicoPreviewTarget = options.landscape ? .picoLandscape : .pico
            let composed = PicoPhotoRenderer.composeColor(image: NSImage(cgImage: source, size: CGSize(width: source.width, height: source.height)), edit: edit, target: target)
            guard let pixels = composed.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ReadPicoManagerError.unavailable("未能生成图片构图。")
            }
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: options.width, height: options.height))
        } else {
            // Do not migrate or reinterpret v1 placement until the user applies a native edit.
            context.draw(source, in: imageRect(source: CGSize(width: source.width, height: source.height), options: options))
        }
        guard let composed = context.makeImage() else { throw ReadPicoManagerError.unavailable("未能生成锁屏排布。") }
        if options.output != .monochrome {
            let image = options.mode == .ascii ? try ascii(composed, options: options) : try grayscale(context, options: options)
            return try ReadPicoBitmap.makeGray16(image: image, width: options.width, height: options.height)
        }
        if options.mode == .image && options.dither == .ordered {
            // Pico's existing Bayer packer compares full-range luminance with a
            // 4×4 threshold. Preserve its correct 50% coverage at middle gray.
            let image = try grayscale(context, options: options)
            return try ReadPicoBitmap.make(image: image, width: options.width, height: options.height, dither: true)
        }
        let final: CGImage
        if options.mode == .ascii { final = try ascii(composed, options: options) }
        else {
            final = ScreenRenderer.grayscaleCanvasImage(from: composed, algorithm: gray(options.gray), mode: .bw,
                                                       dither: dither(options.dither), width: options.width, height: options.height)
        }
        // Already quantized. Disabling a second dither keeps preview/wire pixels identical.
        return try ReadPicoBitmap.make(image: final, width: options.width, height: options.height, dither: false)
    }
    private static func grayscale(_ context: CGContext, options: ReadPicoLockScreenOptions) throws -> CGImage {
        guard let outputContext = CGContext(data: nil, width: options.width, height: options.height, bitsPerComponent: 8, bytesPerRow: options.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let input = context.data?.assumingMemoryBound(to: UInt8.self),
              let output = outputContext.data?.assumingMemoryBound(to: UInt8.self) else {
            throw ReadPicoManagerError.unavailable("无法生成灰阶锁屏图片。")
        }
        let algorithm = gray(options.gray)
        for index in 0..<(options.width * options.height) {
            let at = index * 4
            output[index] = ScreenRenderer.oracleGrayValue(input[at], input[at + 1], input[at + 2], algorithm: algorithm)
        }
        guard let image = outputContext.makeImage() else { throw ReadPicoManagerError.unavailable("无法生成灰阶锁屏图片。") }
        return image
    }
    private static func gray(_ algorithm: ReadPicoLockScreenOptions.Gray) -> OracleGrayAlgorithm {
        switch algorithm { case .luminosity: return .luminosity; case .average: return .average; case .lightness: return .lightness; case .red: return .redChannel; case .green: return .greenChannel; case .blue: return .blueChannel }
    }
    private static func dither(_ algorithm: ReadPicoLockScreenOptions.Dither) -> OracleDitherKernel {
        switch algorithm { case .threshold: return .threshold; case .ordered: return .ordered; case .floydSteinberg: return .floydSteinberg; case .atkinson: return .atkinson; case .burkes: return .burkes; case .sierra2: return .sierra2; case .stucki: return .stucki; case .jarvisJudiceNinke: return .jarvisJudiceNinke }
    }
    private static func ascii(_ image: CGImage, options: ReadPicoLockScreenOptions) throws -> CGImage {
        let width = options.width, height = options.height
        guard let sample = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ReadPicoManagerError.unavailable("ASCII 字符画转换未完成。")
        }
        sample.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = sample.data?.assumingMemoryBound(to: UInt8.self) else { throw ReadPicoManagerError.unavailable("无法读取字符画像素。") }
        destination.setFillColor(CGColor(gray: 1, alpha: 1)); destination.fill(CGRect(x: 0, y: 0, width: width, height: height))
        destination.setShouldAntialias(options.output != .monochrome); destination.setAllowsAntialiasing(options.output != .monochrome)
        let cellWidth = options.asciiCellSize, cellHeight = options.asciiCellSize * 2
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, CGFloat(cellHeight) * 0.82, nil)
        let characters = Array("@%#*+=-:. ")
        let lines = characters.map { character -> CTLine in
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            return CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: attributes))
        }
        let algorithm = gray(options.gray)
        for y in stride(from: 0, to: height, by: cellHeight) {
            for x in stride(from: 0, to: width, by: cellWidth) {
                var sum = 0, count = 0
                for sampleY in y..<min(y + cellHeight, height) {
                    for sampleX in x..<min(x + cellWidth, width) {
                        let at = (sampleY * width + sampleX) * 4
                        sum += Int(ScreenRenderer.oracleGrayValue(pixels[at], pixels[at + 1], pixels[at + 2], algorithm: algorithm)); count += 1
                    }
                }
                let level = min(characters.count - 1, sum * (characters.count - 1) / max(1, count * 255))
                guard characters[level] != " " else { continue }
                let line = lines[level]
                let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
                destination.textPosition = CGPoint(x: CGFloat(x) + (CGFloat(cellWidth) - textWidth) / 2,
                                                   y: CGFloat(height - y - cellHeight) + CGFloat(cellHeight) * 0.2)
                CTLineDraw(line, destination)
            }
        }
        guard let result = destination.makeImage() else { throw ReadPicoManagerError.unavailable("无法生成字符画。") }
        return result
    }
}
