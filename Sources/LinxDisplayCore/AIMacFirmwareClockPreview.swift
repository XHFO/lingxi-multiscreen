import CoreGraphics
import Foundation

/// 复刻内置 AI Mac 0.8.6 固件的设备端桌面时钟。
///
/// 固件使用 TFT_eSPI Font 2（16px 位图字）与 Font 7（48px RLE 数码字）。
/// 预览沿用相同字形、RGB565 配色、尺寸和坐标，避免软件效果图与设备实机
/// 显示成两套不同的界面。
enum AIMacFirmwareClockPreview {
    private struct BitmapGlyph {
        let width: Int
        let rows: Data

        init(_ width: Int, _ base64: String) {
            self.width = width
            rows = Data(base64Encoded: base64) ?? Data()
        }
    }

    private struct RLEGlyph {
        let width: Int
        let runs: Data

        init(_ width: Int, _ base64: String) {
            self.width = width
            runs = Data(base64Encoded: base64) ?? Data()
        }
    }

    // TFT_eSPI Font 2 中时钟标题、日期和秒数实际会用到的字形。
    private static let font2: [Character: BitmapGlyph] = [
        " ": .init(6, "AAAAAAAAAAAAAAAAAAAAAA=="),
        ".": .init(5, "AAAAAAAAAAAAAADAwAAAAA=="),
        "0": .init(8, "AAAAOEREgoKCgkREOAAAAA=="),
        "1": .init(8, "AAAAEDBQEBAQEBAQfAAAAA=="),
        "2": .init(8, "AAAAOESCAgQYIECA/gAAAA=="),
        "3": .init(8, "AAAAeIQCBDgEAgKEeAAAAA=="),
        "4": .init(8, "AAAABAwUJESE/gQEBAAAAA=="),
        "5": .init(8, "AAAA/ICAgPgEAgKEeAAAAA=="),
        "6": .init(8, "AAAAPECAgLjEgoJEOAAAAA=="),
        "7": .init(8, "AAAAfgICBAQICBAQEAAAAA=="),
        "8": .init(8, "AAAAOESCRDhEgoJEOAAAAA=="),
        "9": .init(8, "AAAAOESCgkY6AgIEeAAAAA=="),
        "A": .init(8, "AAAAEBAoKEREfIKCggAAAA=="),
        "C": .init(8, "AAAAPEKAgICAgIBCPAAAAA=="),
        "D": .init(8, "AAAA+ISCgoKCgoKE+AAAAA=="),
        "E": .init(8, "AAAA/oCAgPyAgICA/gAAAA=="),
        "F": .init(8, "AAAA/oCAgPiAgICAgAAAAA=="),
        "H": .init(8, "AAAAhISEhPyEhISEhAAAAA=="),
        "I": .init(4, "AAAA4EBAQEBAQEBA4AAAAA=="),
        "K": .init(8, "AAAAhIiQoMCgkIiEggAAAA=="),
        "L": .init(7, "AAAAgICAgICAgICA/AAAAA=="),
        "M": .init(10, "AAAAAAAAwYDBgKKAooCUgJSAiICIgICAgIAAAAAAAAA="),
        "N": .init(8, "AAAAwsKiopKSioqGhgAAAA=="),
        "O": .init(8, "AAAAOESCgoKCgoJEOAAAAA=="),
        "P": .init(8, "AAAA+ISCgoKE+ICAgAAAAA=="),
        "R": .init(8, "AAAA+ISCgoT4kIiEggAAAA=="),
        "S": .init(8, "AAAAOESCgGAcAoJEOAAAAA=="),
        "T": .init(8, "AAAA/hAQEBAQEBAQEAAAAA=="),
        "U": .init(8, "AAAAgoKCgoKCgoJEOAAAAA=="),
        "W": .init(10, "AAAAAAAAgICAgICAiICIgEkAVQBVACIAIgAAAAAAAAA="),
        "Y": .init(8, "AAAAgoKCRCgQEBAQEAAAAA==")
    ]

    // TFT_eSPI Font 7s 的原始 RLE 数据；数码字宽 32px，冒号宽 12px，高 48px。
    private static let font7: [Character: RLEGlyph] = [
        "0": .init(32, "J44PkA2SDZABgAiBAY4BggaDEIQEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIQQhASCFIIEgBiAJIAeghWBBIQRgwSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBYMQgweBAY4BgQuQDZINkA+OKA=="),
        "1": .init(32, "fxmAHYIbhBmFGYUZhRmFGYUZhRmFGYUZhRmFGYUZhRmFGoQcgh6AXYEbgxmFGYUZhRmFGYUZhRmFGYUZhRmFGYUZhRmFGYUagxyBfyQ="),
        "2": .init(32, "J44PkA2SDZABgAyOAYIbhBmFGYUZhRmFGYUZhRmFGYUZhRmFGYUZhRmFGoQKjgKCCJICgAaWBoABlAeCAZAJhBqFGYUZhRmFGYUZhRmFGYUZhRmFGYUZhRmFGYUagxyBAY4PkA2SDZAPjig="),
        "3": .init(32, "J44PkA2SDZABgAyOAYIbhBmFGYUZhRmFGYUZhRmFGYUZhRmFGYUZhRmFGoQKjgKCCJICgAaWCZQMkAKBG4MZhRmFGYUZhRmFGYUZhRmFGYUZhRmFGYUZhRmFGoMLjgGBC5ANkg2QD44o"),
        "4": .init(32, "fxmACIESggaDEIQEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIQQhASCAo4CggSAApICgAaWCZQMkAKBG4MZhRmFGYUZhRmFGYUZhRmFGYUZhRmFGYUZhRmFGoMcgX8k"),
        "5": .init(32, "J44PkA2SDZALgQGOC4MahRmFGYUZhRmFGYUZhRmFGYUZhRmFGYUZhRmEGoICjgqAApIKlgmUDJACgRuDGYUZhRmFGYUZhRmFGYUZhRmFGYUZhRmFGYUZhRqDC44BgQuQDZINkA+OKA=="),
        "6": .init(32, "J44PkA2SDZALgQGOC4MahRmFGYUZhRmFGYUZhRmFGYUZhRmFGYUZhRmEGoICjgqAApIKlgaAAZQHggGQAoEEhBGDBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUFgxCDB4EBjgGBC5ANkg2QD44o"),
        "7": .init(32, "J44PkA2SDZABgAyOAYIbhBmFGYUZhRmFGYUZhRmFGYUZhRmFGYUZhRmFGoQcgh6AXYEbgxmFGYUZhRmFGYUZhRmFGYUZhRmFGYUZhRmFGYUagxyBfyQ="),
        "8": .init(32, "J44PkA2SDZABgAiBAY4BggaDEIQEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIQQhASCAo4CggSAApICgAaWBoABlAeCAZACgQSEEYMEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQWDEIMHgQGOAYELkA2SDZAPjig="),
        "9": .init(32, "J44PkA2SDZABgAiBAY4BggaDEIQEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIUOhQSFDoUEhQ6FBIQQhASCAo4CggSAApICgAaWCZQMkAKBG4MZhRmFGYUZhRmFGYUZhRmFGYUZhRmFGYUZhRmFGoMLjgGBC5ANkg2QD44o"),
        ":": .init(12, "fx+CB4QGhAaEB4J/GIIHhAaEBoQHgn8g")
    ]

    static func draw(in context: CGContext, now: Date, timeZone: TimeZone = .current) {
        let background = rgb565(7, 11, 22)
        let panel = rgb565(16, 24, 40)
        let panelBorder = rgb565(39, 56, 79)
        let accent = rgb565(80, 230, 184)
        let secondary = rgb565(158, 173, 194)

        context.saveGState()
        defer { context.restoreGState() }
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)

        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))

        context.setFillColor(panel)
        context.addPath(CGPath(roundedRect: CGRect(x: 12, y: 12, width: 216, height: 216),
                               cornerWidth: 22, cornerHeight: 22, transform: nil))
        context.fillPath()
        context.setStrokeColor(panelBorder)
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: CGRect(x: 12.5, y: 12.5,
                                                  width: 215, height: 215),
                               cornerWidth: 21.5, cornerHeight: 21.5, transform: nil))
        context.strokePath()

        context.setFillColor(accent)
        context.addPath(CGPath(roundedRect: topRect(x: 27, y: 29, width: 8, height: 8),
                               cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()

        let components = calendarComponents(for: now, timeZone: timeZone)
        let timeText = String(format: "%02d:%02d", components.hour ?? 0,
                              components.minute ?? 0)
        let secondsText = String(format: "%02d", components.second ?? 0)
        let weekdays = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        let weekday = weekdays[min(max((components.weekday ?? 1) - 1, 0), 6)]
        let dateText = String(format: "%04d.%02d.%02d  %@", components.year ?? 1970,
                              components.month ?? 1, components.day ?? 1, weekday)

        drawFont2("DESKTOP CLOCK", x: 44, topY: 25, color: secondary, in: context)
        drawFont7Centered(timeText, centerX: 120, centerTopY: 101,
                          color: rgb565(255, 255, 255), in: context)
        drawFont2Centered(secondsText, centerX: 120, centerTopY: 146,
                          color: accent, in: context)

        context.setFillColor(panelBorder)
        context.fill(topRect(x: 30, y: 171, width: 180, height: 1))
        drawFont2Centered(dateText, centerX: 120, centerTopY: 194,
                          color: secondary, in: context)
    }

    private static func calendarComponents(for date: Date,
                                           timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .weekday,
                                        .hour, .minute, .second], from: date)
    }

    /// 固件先把 8 位 RGB 压到 RGB565；预览也使用同样量化后的显示颜色。
    private static func rgb565(_ red: Int, _ green: Int, _ blue: Int) -> CGColor {
        let r = CGFloat((red >> 3) & 0x1F) / 31
        let g = CGFloat((green >> 2) & 0x3F) / 63
        let b = CGFloat((blue >> 3) & 0x1F) / 31
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// 把固件的左上角坐标转换到 Core Graphics 左下角坐标。
    private static func topRect(x: Int, y: Int, width: Int, height: Int) -> CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(240 - y - height),
               width: CGFloat(width), height: CGFloat(height))
    }

    private static func font2Width(_ text: String) -> Int {
        text.reduce(0) { $0 + (font2[$1]?.width ?? 6) }
    }

    private static func drawFont2Centered(_ text: String, centerX: Int,
                                          centerTopY: Int, color: CGColor,
                                          in context: CGContext) {
        drawFont2(text, x: centerX - font2Width(text) / 2,
                  topY: centerTopY - 8, color: color, in: context)
    }

    private static func drawFont2(_ text: String, x: Int, topY: Int,
                                  color: CGColor, in context: CGContext) {
        context.setFillColor(color)
        var cursor = x
        for character in text {
            guard let glyph = font2[character] else {
                cursor += 6
                continue
            }
            let bytesPerRow = (glyph.width + 6) / 8
            for row in 0..<16 {
                for column in 0..<glyph.width {
                    let byteIndex = row * bytesPerRow + column / 8
                    guard byteIndex < glyph.rows.count else { continue }
                    let mask = UInt8(0x80 >> (column % 8))
                    if glyph.rows[byteIndex] & mask != 0 {
                        context.fill(topRect(x: cursor + column, y: topY + row,
                                             width: 1, height: 1))
                    }
                }
            }
            cursor += glyph.width
        }
    }

    private static func drawFont7Centered(_ text: String, centerX: Int,
                                          centerTopY: Int, color: CGColor,
                                          in context: CGContext) {
        let width = text.reduce(0) { $0 + (font7[$1]?.width ?? 12) }
        var cursor = centerX - width / 2
        context.setFillColor(color)
        for character in text {
            guard let glyph = font7[character] else {
                cursor += 12
                continue
            }
            var pixel = 0
            for encoded in glyph.runs where pixel < glyph.width * 48 {
                let count = Int(encoded & 0x7F) + 1
                if encoded & 0x80 != 0 {
                    var runStart = pixel
                    var remaining = min(count, glyph.width * 48 - pixel)
                    while remaining > 0 {
                        let row = runStart / glyph.width
                        let column = runStart % glyph.width
                        let rowCount = min(remaining, glyph.width - column)
                        context.fill(topRect(x: cursor + column,
                                             y: centerTopY - 24 + row,
                                             width: rowCount, height: 1))
                        runStart += rowCount
                        remaining -= rowCount
                    }
                }
                pixel += count
            }
            cursor += glyph.width
        }
    }
}
