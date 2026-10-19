import CoreGraphics
import Foundation

/// 屏幕调色板，与原版 SkiaSharp 渲染器一一对应。
public struct ScreenPalette {
    public var background: (CGFloat, CGFloat, CGFloat)
    public var card: (CGFloat, CGFloat, CGFloat)
    public var inset: (CGFloat, CGFloat, CGFloat)
    public var border: (CGFloat, CGFloat, CGFloat)
    public var accent: (CGFloat, CGFloat, CGFloat)
    public var secondaryAccent: (CGFloat, CGFloat, CGFloat)
    public var primaryText: (CGFloat, CGFloat, CGFloat)
    public var secondaryText: (CGFloat, CGFloat, CGFloat)
    public var tertiaryText: (CGFloat, CGFloat, CGFloat)

    public init(background: String, card: String, inset: String, border: String,
                accent: String, secondaryAccent: String,
                primaryText: String, secondaryText: String, tertiaryText: String) {
        self.background = ScreenPalette.parse(background)
        self.card = ScreenPalette.parse(card)
        self.inset = ScreenPalette.parse(inset)
        self.border = ScreenPalette.parse(border)
        self.accent = ScreenPalette.parse(accent)
        self.secondaryAccent = ScreenPalette.parse(secondaryAccent)
        self.primaryText = ScreenPalette.parse(primaryText)
        self.secondaryText = ScreenPalette.parse(secondaryText)
        self.tertiaryText = ScreenPalette.parse(tertiaryText)
    }

    public init(background: (CGFloat, CGFloat, CGFloat),
                card: (CGFloat, CGFloat, CGFloat),
                inset: (CGFloat, CGFloat, CGFloat),
                border: (CGFloat, CGFloat, CGFloat),
                accent: (CGFloat, CGFloat, CGFloat),
                secondaryAccent: (CGFloat, CGFloat, CGFloat),
                primaryText: (CGFloat, CGFloat, CGFloat),
                secondaryText: (CGFloat, CGFloat, CGFloat),
                tertiaryText: (CGFloat, CGFloat, CGFloat)) {
        self.background = background
        self.card = card
        self.inset = inset
        self.border = border
        self.accent = accent
        self.secondaryAccent = secondaryAccent
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.tertiaryText = tertiaryText
    }

    private static func parse(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        return (
            CGFloat((value >> 16) & 0xFF) / 255,
            CGFloat((value >> 8) & 0xFF) / 255,
            CGFloat(value & 0xFF) / 255
        )
    }

    public func cg(_ channel: (CGFloat, CGFloat, CGFloat)) -> CGColor {
        CGColor(red: channel.0, green: channel.1, blue: channel.2, alpha: 1)
    }

    public var backgroundCG: CGColor { cg(background) }
    public var cardCG: CGColor { cg(card) }
    public var insetCG: CGColor { cg(inset) }
    public var borderCG: CGColor { cg(border) }
    public var accentCG: CGColor { cg(accent) }
    public var secondaryAccentCG: CGColor { cg(secondaryAccent) }
    public var primaryTextCG: CGColor { cg(primaryText) }
    public var secondaryTextCG: CGColor { cg(secondaryText) }
    public var tertiaryTextCG: CGColor { cg(tertiaryText) }
}

public enum ScreenThemes {
    /// 纯黑白墨水屏调色板（口袋先知画板 / Rand/0：黑白帧转换前保证最大对比度）
    public static let einkMono = ScreenPalette(
        background: (1, 1, 1), card: (1, 1, 1), inset: (1, 1, 1),
        border: (0.3, 0.3, 0.3),
        accent: (0, 0, 0), secondaryAccent: (0.3, 0.3, 0.3),
        primaryText: (0, 0, 0), secondaryText: (0.25, 0.25, 0.25),
        tertiaryText: (0.4, 0.4, 0.4))

    /// 浅色墨水屏调色板（摘录画板 / Dot：白底黑字灰阶，适配抖动灰度渲染）
    public static let einkLight = ScreenPalette(
        background: (1, 1, 1), card: (1, 1, 1), inset: (1, 1, 1),
        border: (0.62, 0.62, 0.62),
        accent: (0.1, 0.1, 0.1), secondaryAccent: (0.35, 0.35, 0.35),
        primaryText: (0.06, 0.06, 0.06), secondaryText: (0.3, 0.3, 0.3),
        tertiaryText: (0.45, 0.45, 0.45))

    public static func get(_ theme: CardTheme) -> ScreenPalette {
        switch theme {
        case .minimalLight:
            return ScreenPalette(
                background: "eef2f7", card: "ffffff", inset: "f3f6fa", border: "cbd5e1",
                accent: "0f766e", secondaryAccent: "2563eb",
                primaryText: "0f172a", secondaryText: "414d61", tertiaryText: "5d6c82")
        case .neonPurple:
            return ScreenPalette(
                background: "090617", card: "17102b", inset: "100b20", border: "49316e",
                accent: "c084fc", secondaryAccent: "22d3ee",
                primaryText: "faf5ff", secondaryText: "d8b4fe", tertiaryText: "8b7ba8")
        case .amberTerminal:
            return ScreenPalette(
                background: "0b0a07", card: "1a160d", inset: "100e08", border: "5b4720",
                accent: "fbbf24", secondaryAccent: "fb923c",
                primaryText: "fff7d6", secondaryText: "d6b96c", tertiaryText: "8c7540")
        case .laserOrange:
            return laserDark
        case .deepSpace:
            return ScreenPalette(
                background: "080b12", card: "111827", inset: "0b1220", border: "26344a",
                accent: "55e6b8", secondaryAccent: "60a5fa",
                primaryText: "f8fafc", secondaryText: "b9c4d6", tertiaryText: "8a9ab0")
        }
    }

    /// 在所选主题基础上应用外观覆盖（背景底色 / 强调色），返回最终卡片调色板。
    /// 「跟随软件明暗」时背景按软件当前明暗解析为深/浅色；文字与边框按底色明暗
    /// 自动选择深/浅体系保证可读性；强调色「跟随主题」时使用所选主题的强调色。
    public static func resolved(theme: CardTheme,
                                backgroundTone: BackgroundTone,
                                customBackgroundHex: String?,
                                accentTone: AccentTone,
                                customAccentHex: String?,
                                softwareIsDark: Bool = true,
                                renderingMode: CardRenderingMode = .classic) -> ScreenPalette {
        let base = get(theme)

        // 「跟随软件明暗」：按软件当前明暗解析为深色/浅色底色
        let effectiveTone: BackgroundTone
        if backgroundTone == .system {
            effectiveTone = softwareIsDark ? .dark : .light
        } else {
            effectiveTone = backgroundTone
        }
        guard let bg = AppearanceResolver.backgroundRGB(tone: effectiveTone, customHex: customBackgroundHex) else {
            // 自定义色无效等极端情况：回退主题配色，仅应用强调色覆盖
            if let accent = AppearanceResolver.accentRGB(tone: accentTone, customHex: customAccentHex) {
                var palette = base
                palette.accent = accent
                return palette
            }
            return base
        }

        let luminance = 0.299 * bg.0 + 0.587 * bg.1 + 0.114 * bg.2
        // 独立的工业橙黑主题，不替换玻璃默认颜色，也不覆盖用户明确指定的底色。
        // 浅色模式采用深橙文字，避免亮橙在白底上失去对比度。
        if theme == .laserOrange && backgroundTone != .custom {
            var palette = luminance < 0.5 ? laserDark : laserLight
            if let accent = AppearanceResolver.accentRGB(tone: accentTone, customHex: customAccentHex) {
                palette.accent = accent
            }
            return palette
        }
        let baseForText = luminance >= 0.5 ? get(.minimalLight) : get(.deepSpace)

        var palette = base
        palette.background = bg
        palette.card = bg
        palette.inset = bg
        palette.border = baseForText.border
        palette.primaryText = baseForText.primaryText
        palette.secondaryText = baseForText.secondaryText
        palette.tertiaryText = baseForText.tertiaryText
        palette.secondaryAccent = baseForText.secondaryAccent
        if let accent = AppearanceResolver.accentRGB(tone: accentTone, customHex: customAccentHex) {
            palette.accent = accent
        } else {
            // 强调色「跟随主题」：使用所选主题的强调色，保持主题个性
            palette.accent = base.accent
        }
        // 只更新玻璃的默认配色；经典、霓虹/琥珀主题及明确选择的颜色保持原样。
        guard renderingMode == .liquidGlass,
              theme == .deepSpace || theme == .minimalLight,
              backgroundTone != .custom, accentTone == .system else { return palette }
        return luminance < 0.5 ? glassDark : glassLight
    }

    /// 冷灰玻璃底色 + 雾蓝 / 鸢尾紫，避免旧版高饱和薄荷绿的终端感。
    public static let glassDark = ScreenPalette(
        background: "11151f", card: "171d2a", inset: "141a26", border: "354053",
        accent: "9dbbff", secondaryAccent: "b9abed",
        primaryText: "f2f4fa", secondaryText: "abb6ca", tertiaryText: "8896ae")
    public static let glassLight = ScreenPalette(
        background: "eef1f7", card: "f8faff", inset: "e8edf6", border: "c4ccdc",
        accent: "3658c9", secondaryAccent: "8066b6",
        primaryText: "182334", secondaryText: "48576d", tertiaryText: "667287")

    public static let laserDark = ScreenPalette(
        background: "000000", card: "111111", inset: "0a0a0a", border: "383838",
        accent: "ff5500", secondaryAccent: "ffc09b",
        primaryText: "f5f4f0", secondaryText: "ababab", tertiaryText: "8c8c8c")
    public static let laserLight = ScreenPalette(
        background: "f3f2ef", card: "ffffff", inset: "e9e7e3", border: "ccc8c2",
        accent: "a63c00", secondaryAccent: "80563e",
        primaryText: "24231f", secondaryText: "62615c", tertiaryText: "6d6b66")
}
