import AppKit
import CoreGraphics
import CoreText
import Foundation

/// 软件预览和设备推送共用的沉浸天空；不绘制设备固件的状态栏。
/// 与 C6 本地固件的旧色表分离，避免更改未在本次范围内的离线页面。
public struct WeatherSkyPalette {
    public let top: UInt32
    public let sky: UInt32
    public let foreground: UInt32 = 0xF7FAFF
    public let secondary: UInt32
    public let night: Bool

    public init(weather: WeatherSnapshot) {
        night = weather.isDay == false
        secondary = night ? 0xB8C9DE : 0xD9E6F4
        if night { top = 0x0A1730; sky = 0x2A466E; return }
        switch weather.condition {
        case .sunny: top = 0x205B99; sky = 0x81B9E2
        case .cloudy: top = 0x285E8F; sky = 0x82B5D4
        case .overcast, .unknown: top = 0x35536F; sky = 0x7192B1
        case .fog: top = 0x405B70; sky = 0x98ACB9
        case .drizzle, .rain:
            let heavy = [65, 67, 82].contains(weather.code)
            top = heavy ? 0x213B59 : 0x2D4B68
            sky = heavy ? 0x54738F : 0x7A98B2
        case .snow:
            let heavy = [75, 86].contains(weather.code)
            top = heavy ? 0x304C68 : 0x385A78
            sky = heavy ? 0x99B2C6 : 0xA1BDCE
        case .thunderstorm: top = 0x25304E; sky = 0x59617E
        }
    }

    /// 用于逐像素绘制及实际文本背景反差的回归检查（坐标为模块内左上）。
    public func background(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                           safeArea: CGFloat = 0, includingWash: Bool = true) -> UInt32 {
        let t = min(1, max(0, 0.55 * y / height + 0.45 * x / width))
        let light = t < 0.63 ? t / 0.63 : (1 - t) / 0.37
        let tall = height > width * 1.5
        let washStart: CGFloat = tall ? safeArea + 140 : 112
        let washLength: CGFloat = tall ? 100 : 72
        let wash = includingWash ? min(1, max(0, (y - washStart) / washLength)) : 0
        // 左侧正文比右侧景物更暗；这层柔和的空气透视不形成卡片底框。
        let leftShade = 0.32 * (1 - min(1, max(0, x / width)))
        let blend = light * (1 - wash) * (1 - leftShade)
        func channel(_ shift: UInt32) -> UInt32 {
            let a = Double((top >> shift) & 255), b = Double((sky >> shift) & 255)
            return UInt32((a + (b - a) * Double(blend)).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }
}

enum WeatherSkyRenderer {
    static func draw(_ ctx: CGContext, weather: WeatherSnapshot, bounds: CGRect,
                     coordinateHeight: CGFloat, safeArea: CGFloat, now: Date) {
        let palette = WeatherSkyPalette(weather: weather)
        let w = bounds.width, h = bounds.height
        let tall = h > w * 1.5
        let scale = tall ? min(w / 142, (h - safeArea) / 372) : min(w / 240, h / 240)
        let base = tall ? safeArea : 0
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255,
                CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha])!
        }
        func cg(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: bounds.minX + x, y: coordinateHeight - bounds.minY - y - height,
                   width: width, height: height)
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: bounds.minX + x, y: coordinateHeight - bounds.minY - y)
        }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: cg(0, 0, w, h))
        // 原生分辨率绘制，sRGB 渐变没有显示器色域或缩放差异。
        let bw = Int(ceil(w)), bh = Int(ceil(h))
        var bytes = [UInt8](repeating: 255, count: bw * bh * 4)
        for y in 0..<bh {
            for x in 0..<bw {
                let value = palette.background(x: CGFloat(x), y: CGFloat(y), width: w,
                    height: h, safeArea: safeArea, includingWash: false)
                let i = (y * bw + x) * 4
                bytes[i] = UInt8((value >> 16) & 255)
                bytes[i + 1] = UInt8((value >> 8) & 255)
                bytes[i + 2] = UInt8(value & 255)
            }
        }
        if let provider = CGDataProvider(data: Data(bytes) as CFData),
           let sky = CGImage(width: bw, height: bh, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bw * 4, space: cs,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            ctx.draw(sky, in: cg(0, 0, w, h))
        }

        // 景物只能在安全区下面出现；安全区保留连续天空，不画电池/系统 UI。
        ctx.saveGState()
        ctx.clip(to: cg(0, safeArea, w, h - safeArea))
        func cloud(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, opacity: CGFloat) {
            let path = CGMutablePath()
            path.addRoundedRect(in: cg(x, y + height * 0.52, width, height * 0.48),
                                cornerWidth: height * 0.24, cornerHeight: height * 0.24)
            path.addEllipse(in: cg(x + width * 0.19, y, width * 0.51, height * 0.88))
            path.addEllipse(in: cg(x + width * 0.53, y + height * 0.22, width * 0.36, height * 0.65))
            ctx.saveGState()
            ctx.setAlpha(opacity)
            ctx.addPath(path); ctx.clip()
            let colors = palette.night ? [color(0x627493), color(0x2C3D5C)]
                : [color(weather.condition == .rain ? 0xB0C5D6 : 0xEDF5FB), color(0x9BB5CA)]
            if let gradient = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: point(x, y), end: point(x, y + height),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
        }
        let clear = weather.condition == .sunny || weather.condition == .cloudy
        if clear {
            let side: CGFloat = (palette.night ? 48 : (tall ? 64 : 61)) * scale
            let wideNumber = String(format: "%.0f", weather.temperature).count > 2
            let normalX = w - (palette.night ? (tall ? 7 : 28) : (tall ? -27 : 24)) * scale - side
            let x = tall && wideNumber ? max(normalX, w - 10 * scale) : normalX
            let y = base + (palette.night ? (tall ? 64 : 32) : (tall ? 68 : 43)) * scale
            let disk = cg(x, y, side, side)
            ctx.saveGState()
            ctx.addEllipse(in: disk); ctx.clip()
            if palette.night {
                // 真正从月盘减去透明圆弧；绝不使用天空色圆盘盖住月亮。
                let mask = CGMutablePath()
                mask.addRect(disk.insetBy(dx: -side, dy: -side))
                mask.addEllipse(in: cg(x - side * 0.20, y - side * 0.13, side * 0.92, side * 0.92))
                ctx.addPath(mask); ctx.clip(using: .evenOdd)
            }
            let shades = palette.night ? [color(0xFFF8DF), color(0xC9BDA4)]
                : [color(0xFFF4C7), color(0xFFD780), color(0xF8B95D)]
            if let gradient = CGGradient(colorsSpace: cs, colors: shades as CFArray, locations: nil) {
                ctx.drawRadialGradient(gradient, startCenter: point(x + side * 0.34, y + side * 0.3),
                    startRadius: 0, endCenter: point(x + side / 2, y + side / 2),
                    endRadius: side * 0.68, options: [.drawsAfterEndLocation])
            }
            ctx.restoreGState()
        }
        if palette.night {
            for (x, y, r) in [(0.74, 0.09, 1.0), (0.96, 0.15, 0.8), (0.55, 0.16, 0.7)] {
                ctx.setFillColor(color(0xDCE9FA, alpha: 0.7))
                ctx.fillEllipse(in: cg(w * x, base + (h - base) * y, r * 2, r * 2))
            }
        }
        let sceneY = base + (tall ? 131 : 64) * scale
        if weather.condition == .fog {
            for i in 0..<3 {
                let y = sceneY + CGFloat(i) * 22 * scale
                ctx.setFillColor(color(0xDCE7ED, alpha: 0.22))
                ctx.fill(cg(w * 0.5, y, w * 0.65, 6 * scale))
            }
        } else {
            if weather.condition != .sunny {
                cloud(x: w - (tall ? 65 : 85) * scale, y: sceneY,
                      width: 96 * scale, height: 55 * scale, opacity: palette.night ? 0.38 : 0.5)
            }
            let smallCloud = weather.condition == .sunny
            cloud(x: w - (tall ? (smallCloud ? 40 : 62) : (smallCloud ? 68 : 115)) * scale,
                  y: base + (tall ? (smallCloud ? 177 : 137) : (smallCloud ? 110 : 72)) * scale,
                  width: (smallCloud ? 83 : 127) * scale, height: (smallCloud ? 44 : 67) * scale,
                  opacity: weather.condition == .sunny ? (palette.night ? 0.18 : 0.38) : 0.84)
        }
        let wet = [.rain, .drizzle, .thunderstorm].contains(weather.condition)
        if wet || weather.condition == .snow {
            let heavy = [65, 67, 75, 82, 86, 99].contains(weather.code)
            for i in 0..<(heavy ? 9 : 5) {
                let x = w - CGFloat(i * (heavy ? 10 : 17) + 8) * scale
                let y = base + (tall ? 199 : 140) * scale + CGFloat(i % 2) * 8 * scale
                if weather.condition == .snow {
                    ctx.setFillColor(color(0xF4FAFF, alpha: 0.8))
                    ctx.fillEllipse(in: cg(x, y, 3 * scale, 3 * scale))
                } else {
                    ctx.setStrokeColor(color(0xB4D3ED, alpha: 0.7)); ctx.setLineWidth(1.5 * scale)
                    ctx.move(to: point(x, y)); ctx.addLine(to: point(x - 4 * scale, y + 10 * scale))
                    ctx.strokePath()
                }
            }
        }
        if weather.condition == .thunderstorm {
            let x = w - 30 * scale, y = base + (tall ? 175 : 110) * scale
            let bolt = CGMutablePath()
            bolt.move(to: point(x, y)); bolt.addLine(to: point(x - 12 * scale, y + 18 * scale))
            bolt.addLine(to: point(x - 3 * scale, y + 18 * scale))
            bolt.addLine(to: point(x - 8 * scale, y + 32 * scale))
            bolt.addLine(to: point(x + 8 * scale, y + 12 * scale))
            bolt.addLine(to: point(x, y + 12 * scale)); bolt.closeSubpath()
            ctx.setFillColor(color(0xFFDB9A)); ctx.addPath(bolt); ctx.fillPath()
        }
        ctx.restoreGState()

        // 景物和天空一同回落到较深的下半区，避免云层压低降水/建议文字反差。
        let washStart = tall ? safeArea + 140 : CGFloat(112)
        let washLength: CGFloat = tall ? 100 : 72
        for y in max(0, Int(washStart))..<bh {
            let opacity = min(1, max(0, (CGFloat(y) - washStart) / washLength))
            ctx.setFillColor(color(palette.top, alpha: opacity))
            ctx.fill(cg(0, CGFloat(y), w, 1))
        }

        // CoreText 以字形边界对齐，不依赖缩小后重新放大的位图文字。
        func text(_ value: String, x: CGFloat = 12, y: CGFloat, width: CGFloat? = nil,
                  size: CGFloat, tint: UInt32? = nil, right: Bool = false,
                  fontName: String = "PingFangSC-Medium") {
            let available = width.map { $0 * scale } ?? (w - x * scale - 12 * scale)
            var fontSize = size * scale
            func line(_ size: CGFloat) -> CTLine {
                CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
                    .font: CTFontCreateWithName(fontName as CFString, size, nil),
                    .foregroundColor: color(tint ?? palette.foreground)]))
            }
            var glyphs = line(fontSize)
            var box = CTLineGetBoundsWithOptions(glyphs, [.useGlyphPathBounds])
            if box.width > available {
                fontSize *= available / box.width
                glyphs = line(fontSize); box = CTLineGetBoundsWithOptions(glyphs, [.useGlyphPathBounds])
            }
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: bounds.minX + x * scale - box.minX + (right ? available - box.width : 0),
                y: coordinateHeight - bounds.minY - y - box.maxY)
            CTLineDraw(glyphs, ctx)
        }
        text(weather.city, y: base + (tall ? 16 : 12) * scale, size: 16,
             fontName: "PingFangSC-Semibold")
        let description = palette.night && clear
            ? (weather.condition == .sunny ? "晴朗夜间" : "多云夜间") : weather.description
        text(description, y: base + (tall ? 41 : 36) * scale, size: 14)
        let temperature = String(format: "%.0f", weather.temperature)
        let preferred: CGFloat = (tall ? 68 : 72) * scale
        let heroWidth = w - 20 * scale
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, preferred, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: temperature, attributes: [.font: font]))
        let measured = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).width
        let heroSize = min(preferred, preferred * (heroWidth - 27 * scale) / max(1, measured))
        let numberWidth = measured * heroSize / preferred
        let heroY = base + (tall ? 74 : 57) * scale
        text(temperature, x: 10, y: heroY, width: numberWidth / scale + 1,
             size: heroSize / scale, fontName: "HelveticaNeue-Bold")
        text("°", x: 10 + numberWidth / scale + 3, y: heroY + 7 * scale,
             size: heroSize / scale * 0.43, fontName: "HelveticaNeue-Medium")
        text(String(format: "最低%.0f°  最高%.0f°", weather.low, weather.high),
             y: base + (tall ? 156 : 133) * scale, size: 13)
        let rainY = base + (tall ? 198 : 165) * scale
        text("降水概率", y: rainY + 4 * scale, width: tall ? 60 : 130, size: 14)
        text("\(min(100, max(0, weather.rainProbability)))%", x: tall ? 78 : 158,
             y: rainY, size: tall ? 22 : 20, right: true, fontName: "HelveticaNeue-Bold")
        if tall {
            let adviceY = base + 236 * scale
            text("今日建议", y: adviceY, size: 13, tint: palette.secondary)
            text(weather.clothing, y: adviceY + 28 * scale, size: 14)
            text(weather.carWash, y: adviceY + 58 * scale, size: 14)
        } else {
            text(weather.advice, y: 191 * scale, size: 14)
        }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
        let stale = now.timeIntervalSince(weather.updatedAt) > 3 * 3600
        let stamp = formatter.string(from: weather.updatedAt) + (stale ? " 缓存" : " 更新")
        text(tall ? stamp : stamp + " · Open-Meteo", y: h - (tall ? 43 : 22) * scale,
             size: 11, tint: palette.secondary)
        if tall { text("Open-Meteo", y: h - 25 * scale, size: 11, tint: palette.secondary) }
    }
}
