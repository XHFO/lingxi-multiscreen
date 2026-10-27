import AppKit
import LinxDisplayCore

/// A frozen information frame. The same monochrome bitmap is previewed and sent.
struct ReadPicoInformationFrame {
    struct Row { var label: String; var value: String }
    enum Layout { case clock, information, media, image }
    var layout: Layout = .information
    var title: String
    var subtitle = ""
    var primary = ""
    var rows: [Row] = []
    var image: CGImage?
    var sampledAt = Date()
    var footer = "多屏灵犀 · 小纸 Pico"
    var unavailableReason: String?
}

enum ReadPicoInformationRenderer {
    struct Result {
        let bitmap: Data
        let preview: NSImage
        let width: Int
        let height: Int
        let pairedBitmap: Data?
        var transferData: Data { pairedBitmap ?? bitmap }
        init(bitmap: Data, preview: NSImage, width: Int, height: Int, pairedBitmap: Data? = nil) {
            self.bitmap = bitmap; self.preview = preview; self.width = width; self.height = height; self.pairedBitmap = pairedBitmap
        }
    }

    @MainActor static func render(_ frame: ReadPicoInformationFrame,
                                  landscape: Bool, dither: Bool) throws -> Result {
        let portrait = try renderSingle(frame, landscape: false)
        let horizontal = try renderSingle(frame, landscape: true)
        let selected = landscape ? horizontal : portrait
        return Result(bitmap: selected.bitmap, preview: selected.preview, width: selected.width, height: selected.height,
                      pairedBitmap: try ReadPicoCanvasPair.encode(portrait: portrait.bitmap, landscape: horizontal.bitmap))
    }
    @MainActor private static func renderSingle(_ frame: ReadPicoInformationFrame, landscape: Bool) throws -> Result {
        let width = landscape ? 1216 : 684, height = landscape ? 684 : 1216
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ReadPicoManagerError.unavailable("无法创建信息画面，请稍后重试。")
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let w = CGFloat(width), h = CGFloat(height), margin: CGFloat = 48
        let contentWidth = w - margin * 2
        func text(_ value: String, rect: CGRect, size: CGFloat, weight: NSFont.Weight = .regular,
                  alignment: NSTextAlignment = .left, lines: Bool = false, monospaced: Bool = false) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = lines ? .byWordWrapping : .byTruncatingTail
            let font = monospaced ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
            NSGraphicsContext.saveGraphicsState(); context.clip(to: rect)
            (value as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], attributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        func rule(_ y: CGFloat) {
            context.setStrokeColor(NSColor.black.cgColor); context.setLineWidth(2)
            context.move(to: CGPoint(x: margin, y: y)); context.addLine(to: CGPoint(x: w - margin, y: y)); context.strokePath()
        }
        func drawImage(_ image: CGImage, in rect: CGRect) {
            let ratio = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let imageWidth = CGFloat(image.width) * ratio, imageHeight = CGFloat(image.height) * ratio
            let target = CGRect(x: rect.midX - imageWidth / 2, y: rect.midY - imageHeight / 2, width: imageWidth, height: imageHeight)
            // CGImage's row origin is the inverse of AppKit's flipped text context.
            context.saveGState(); context.translateBy(x: 0, y: target.minY * 2 + target.height)
            context.scaleBy(x: 1, y: -1); context.interpolationQuality = .high
            context.draw(image, in: target); context.restoreGState()
        }
        if frame.layout == .image, let image = frame.image {
            drawImage(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        } else {
            text(frame.title, rect: CGRect(x: margin, y: 46, width: contentWidth, height: 66), size: 42, weight: .semibold)
            if !frame.subtitle.isEmpty {
                text(frame.subtitle, rect: CGRect(x: margin, y: 120, width: contentWidth, height: landscape ? 48 : 88), size: 28, lines: true)
            }
            let start: CGFloat = landscape ? 202 : 250
            if let unavailable = frame.unavailableReason {
                text("等待内容", rect: CGRect(x: margin, y: start + 56, width: contentWidth, height: 80), size: 54, weight: .semibold)
                text(unavailable, rect: CGRect(x: margin, y: start + 160, width: contentWidth, height: h - start - 300), size: 32, lines: true)
            } else if frame.layout == .clock {
                let fontSize: CGFloat = landscape ? 248 : 184
                text(frame.primary, rect: CGRect(x: margin, y: landscape ? 210 : 350, width: contentWidth, height: fontSize * 1.3), size: fontSize, weight: .medium, alignment: .center, monospaced: true)
                if let row = frame.rows.first {
                    text(row.value, rect: CGRect(x: margin, y: landscape ? 496 : 650, width: contentWidth, height: 80), size: landscape ? 36 : 42, alignment: .center)
                }
            } else if frame.layout == .media, let image = frame.image {
                let side: CGFloat = landscape ? 334 : 388
                let imageRect = CGRect(x: margin, y: start, width: side, height: side)
                drawImage(image, in: imageRect)
                let left = landscape ? margin + side + 42 : margin
                let top = landscape ? start : start + side + 42
                let availableWidth = landscape ? w - left - margin : contentWidth
                text(frame.primary, rect: CGRect(x: left, y: top, width: availableWidth, height: 150), size: 48, weight: .semibold, lines: true)
                for (index, row) in frame.rows.prefix(landscape ? 3 : 4).enumerated() {
                    text(row.value, rect: CGRect(x: left, y: top + 160 + CGFloat(index) * 58, width: availableWidth, height: 56), size: 30)
                }
            } else {
                var y = start
                if !frame.primary.isEmpty {
                    text(frame.primary, rect: CGRect(x: margin, y: y, width: contentWidth, height: landscape ? 130 : 190), size: landscape ? 106 : 136, weight: .medium)
                    y += landscape ? 160 : 230
                }
                let availableHeight = max(1, h - y - 130)
                // At native panel density, fewer secondary rows are preferable to unreadably small type.
                let maximumRows = max(1, min(6, Int(availableHeight / (landscape ? 84 : 100))))
                let rows = Array(frame.rows.prefix(maximumRows))
                let rowHeight = min(landscape ? 106 : 126, availableHeight / CGFloat(max(1, rows.count)))
                for (index, row) in rows.enumerated() {
                    let rowY = y + CGFloat(index) * rowHeight
                    if landscape {
                        text(row.label, rect: CGRect(x: margin, y: rowY + 9, width: contentWidth * 0.47, height: rowHeight - 12), size: min(34, rowHeight * 0.42))
                        text(row.value, rect: CGRect(x: margin + contentWidth * 0.48, y: rowY + 9, width: contentWidth * 0.52, height: rowHeight - 12), size: min(38, rowHeight * 0.48), weight: .medium, alignment: .right)
                    } else {
                        text(row.label, rect: CGRect(x: margin, y: rowY + 4, width: contentWidth, height: rowHeight * 0.4), size: min(28, rowHeight * 0.30))
                        text(row.value, rect: CGRect(x: margin, y: rowY + rowHeight * 0.4, width: contentWidth, height: rowHeight * 0.6), size: min(44, rowHeight * 0.46), weight: .medium)
                    }
                }
            }
            rule(h - 92)
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "MM-dd HH:mm"
            text(frame.footer, rect: CGRect(x: margin, y: h - 66, width: contentWidth * 0.62, height: 36), size: 23)
            text(formatter.string(from: frame.sampledAt), rect: CGRect(x: margin + contentWidth * 0.62, y: h - 66, width: contentWidth * 0.38, height: 36), size: 23, alignment: .right)
        }
        guard let image = context.makeImage() else { throw ReadPicoManagerError.unavailable("信息画面生成失败。") }
        let bitmap = try ReadPicoBitmap.makeGray16(image: image, width: width, height: height)
        guard let preview = NSImage(data: bitmap) else { throw ReadPicoManagerError.unavailable("黑白预览生成失败。") }
        return Result(bitmap: bitmap, preview: preview, width: width, height: height)
    }
}
