import AppKit
import CoreText
import CPicoBoardRenderer

/// Shares the firmware's parser and card layout; only the drawing backend is CoreGraphics.
public enum ReadPicoNativeBoardRenderer {
    private final class Drawing {
        let context: CGContext
        var fonts: [Int: CTFont] = [:]
        init(_ context: CGContext) { self.context = context }
        func font(_ size: Int) -> CTFont {
            if let font = fonts[size] { return font }
            let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, CGFloat(size), nil)
            fonts[size] = font; return font
        }
        func line(_ text: String, size: Int, gray: Int = 0) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: font(size), .foregroundColor: NSColor(white: CGFloat(gray) / 15, alpha: 1)
            ]))
        }
    }
    private static func drawing(_ context: UnsafeMutableRawPointer?) -> Drawing {
        Unmanaged<Drawing>.fromOpaque(context!).takeUnretainedValue()
    }
    public static func validate(_ data: Data) throws {
        _ = try ReadPicoBoardModel.decode(data)
        var error: UnsafePointer<CChar>?
        let model = data.withUnsafeBytes { ps_board_model_parse_ex($0.baseAddress, $0.count, &error) }
        guard let model else { throw ReadPicoManagerError.invalid("设备原生排版无法读取画板数据（\(error.map { String(cString: $0) } ?? "unknown")）。") }
        ps_board_model_free(model)
    }
    public static func render(_ data: Data, landscape: Bool, now: Date = Date(), timeZone: TimeZone = .current) throws -> CGImage {
        _ = try ReadPicoBoardModel.decode(data)
        var error: UnsafePointer<CChar>?
        let model = data.withUnsafeBytes { ps_board_model_parse_ex($0.baseAddress, $0.count, &error) }
        guard let model else {
            throw ReadPicoManagerError.invalid("设备原生排版无法读取画板数据（\(error.map { String(cString: $0) } ?? "unknown")）。")
        }
        defer { ps_board_model_free(model) }
        _ = ps_board_model_tick_at(model, 0, now.timeIntervalSince1970)
        _ = ps_board_model_set_timezone(model, Int32(timeZone.secondsFromGMT(for: now) / 60))
        let width = landscape ? 1216 : 684, height = landscape ? 684 : 1216
        let logicalWidth: Int32 = landscape ? 640 : 360, logicalHeight: Int32 = landscape ? 360 : 640
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ReadPicoManagerError.invalid("无法创建原生16灰阶预览。")
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / CGFloat(logicalWidth), y: -CGFloat(height) / CGFloat(logicalHeight))
        let state = Drawing(context)
        var painter = ps_board_painter_t(context: Unmanaged.passUnretained(state).toOpaque(), width: logicalWidth, height: logicalHeight,
            fill: { pointer, x, y, w, h, gray in
                let context = ReadPicoNativeBoardRenderer.drawing(pointer).context
                context.setFillColor(gray: CGFloat(gray) / 15, alpha: 1)
                context.fill(CGRect(x: Int(x), y: Int(y), width: Int(w), height: Int(h)))
            }, line: { pointer, x0, y0, x1, y1, gray in
                let context = ReadPicoNativeBoardRenderer.drawing(pointer).context
                context.setStrokeColor(gray: CGFloat(gray) / 15, alpha: 1); context.setLineWidth(1)
                context.move(to: CGPoint(x: Int(x0), y: Int(y0))); context.addLine(to: CGPoint(x: Int(x1), y: Int(y1))); context.strokePath()
            }, text: { pointer, x, y, size, raw, gray in
                guard let raw else { return }
                let state = ReadPicoNativeBoardRenderer.drawing(pointer), context = state.context
                let font = state.font(Int(size)), line = state.line(String(cString: raw), size: Int(size), gray: Int(gray))
                context.saveGState()
                context.translateBy(x: CGFloat(x), y: CGFloat(y) + CTFontGetAscent(font))
                context.scaleBy(x: 1, y: -1); context.textMatrix = .identity; context.textPosition = .zero
                CTLineDraw(line, context); context.restoreGState()
            }, measure: { pointer, size, raw in
                guard let raw else { return 0 }
                let line = ReadPicoNativeBoardRenderer.drawing(pointer).line(String(cString: raw), size: Int(size))
                return Int32(min(ceil(CTLineGetTypographicBounds(line, nil, nil, nil)), Double(Int32.max)))
            }, image: { pointer, value, x, y, w, h in
                guard let value, let pixels = value.pointee.pixels else { return }
                let width = Int(value.pointee.width), height = Int(value.pointee.height), stride = (Int(value.pointee.width) + 1) / 2
                var expanded = Data(repeating: 255, count: width * height)
                for row in 0..<height { for column in 0..<width {
                    let byte = pixels[row * stride + column / 2]
                    expanded[row * width + column] = (column % 2 == 0 ? byte >> 4 : byte & 15) * 17
                } }
                guard let provider = CGDataProvider(data: expanded as CFData),
                      let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
                let context = ReadPicoNativeBoardRenderer.drawing(pointer).context
                context.saveGState(); context.interpolationQuality = .none
                context.translateBy(x: CGFloat(x), y: CGFloat(y + h)); context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: 0, y: 0, width: Int(w), height: Int(h))); context.restoreGState()
            })
        withExtendedLifetime(state) { ps_board_model_paint(model, &painter) }
        guard let buffer = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ReadPicoManagerError.invalid("原生预览缓冲区不可用。") }
        for index in 0..<(width * height) { buffer[index] = UInt8((Int(buffer[index]) + 8) / 17) * 17 }
        guard let image = context.makeImage() else { throw ReadPicoManagerError.invalid("原生预览生成失败。") }
        return image
    }
}
