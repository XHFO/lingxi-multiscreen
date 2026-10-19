import Foundation
import LinxDisplayCore

@MainActor
func testProjectGuidanceAndGlassDefaults() {
    checkEqual(C6ProjectResources.websiteURL.absoluteString, "https://xhfo.net/", "C6指南使用正式HTTPS官网入口")
    check(C6ProjectResources.hardwareName.contains("ESP32-C6-LCD-1.3"), "C6指南明确完整板型")
    checkEqual(C6ProjectResources.productName, "XH Multiscreen", "C6沿用产品系列命名")
    checkEqual(C6ProjectResources.branchName, "多屏灵犀分支", "通用C6分支不冒充Formlabs专用固件")
    for resource in [C6ProjectResources.enclosureURL, C6ProjectResources.firmwareURL] {
        check(resource == nil || resource?.scheme == "https", "尚无项目文件时不生成伪下载地址")
    }

    func same(_ lhs: (CGFloat, CGFloat, CGFloat), _ rhs: (CGFloat, CGFloat, CGFloat)) -> Bool {
        abs(lhs.0 - rhs.0) < 1e-8 && abs(lhs.1 - rhs.1) < 1e-8 && abs(lhs.2 - rhs.2) < 1e-8
    }
    func contrast(_ foreground: (CGFloat, CGFloat, CGFloat), _ background: (CGFloat, CGFloat, CGFloat)) -> Double {
        func luminance(_ color: (CGFloat, CGFloat, CGFloat)) -> Double {
            let components = [color.0, color.1, color.2].map { value -> Double in
                let c = Double(value)
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
        }
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    let settings = AppSettings()
    settings.cardRenderingMode = .liquidGlass
    settings.backgroundTone = .system
    for dark in [false, true] {
        settings.softwareIsDark = dark
        let palette = settings.resolvedPalette
        let expected = dark ? ScreenThemes.glassDark : ScreenThemes.glassLight
        check(same(palette.background, expected.background), "玻璃默认底色跟随明暗")
        check(same(palette.accent, expected.accent) && same(palette.secondaryAccent, expected.secondaryAccent),
              "玻璃默认采用雾蓝与鸢尾紫，不沿用薄荷绿")
        check(contrast(palette.primaryText, palette.card) >= 7, "玻璃主文本在基础卡片底色上的对比度至少7:1")
        check(contrast(palette.secondaryText, palette.card) >= 4.5, "玻璃辅助文本在基础卡片底色上的对比度至少4.5:1")
    }

    for theme in [CardTheme.deepSpace, .minimalLight, .neonPurple, .amberTerminal] {
        settings.cardTheme = theme
        settings.cardRenderingMode = .classic
        let classic = settings.resolvedPalette
        let original = ScreenThemes.resolved(theme: theme, backgroundTone: settings.backgroundTone,
            customBackgroundHex: nil, accentTone: .system, customAccentHex: nil, softwareIsDark: true)
        check(same(classic.background, original.background) && same(classic.accent, original.accent),
              "经典模式及默认解析保持原配色")
        if theme == .neonPurple || theme == .amberTerminal {
            settings.cardRenderingMode = .liquidGlass
            check(same(settings.resolvedPalette.accent, classic.accent), "玻璃不重写霓虹及琥珀主题")
        }
    }

    settings.cardTheme = .deepSpace
    settings.accentTone = .custom
    settings.customAccentHex = "#F08199"
    settings.cardRenderingMode = .classic
    let custom = settings.resolvedPalette
    settings.cardRenderingMode = .liquidGlass
    check(same(settings.resolvedPalette.accent, custom.accent), "玻璃保留用户自定义强调色")
    settings.accentTone = .system
    settings.backgroundTone = .custom
    settings.customBackgroundHex = "#123456"
    settings.cardRenderingMode = .classic
    let customBackground = settings.resolvedPalette
    settings.cardRenderingMode = .liquidGlass
    check(same(settings.resolvedPalette.background, customBackground.background)
        && same(settings.resolvedPalette.accent, customBackground.accent), "玻璃保留自定义底色与对应配色")

    checkEqual(CardTheme.deepSpace.rawValue, 0, "旧深空主题标识不变")
    checkEqual(CardTheme.minimalLight.rawValue, 1, "旧极简主题标识不变")
    checkEqual(CardTheme.neonPurple.rawValue, 2, "旧霓虹主题标识不变")
    checkEqual(CardTheme.amberTerminal.rawValue, 3, "旧琥珀主题标识不变")
    let encodedTheme = try? JSONEncoder().encode(CardTheme.laserOrange)
    let decodedTheme = encodedTheme.flatMap { try? JSONDecoder().decode(CardTheme.self, from: $0) }
    checkEqual(decodedTheme, .laserOrange, "橙黑主题可编码保存并重新读取")
    settings.cardTheme = .laserOrange
    settings.accentTone = .system
    for dark in [false, true] {
        settings.backgroundTone = .system
        settings.softwareIsDark = dark
        for mode in CardRenderingMode.allCases {
            settings.cardRenderingMode = mode
            let palette = settings.resolvedPalette
            let expected = dark ? ScreenThemes.laserDark : ScreenThemes.laserLight
            check(same(palette.background, expected.background) && same(palette.accent, expected.accent),
                  "橙黑主题兼容两种渲染及明暗模式")
            for surface in [palette.background, palette.card, palette.inset] {
                check(contrast(palette.primaryText, surface) >= 7, "橙黑主题主文字对比度至少7:1")
                check(contrast(palette.secondaryText, surface) >= 4.5, "橙黑主题辅助文字对比度至少4.5:1")
                check(contrast(palette.accent, surface) >= 4.5, "橙黑主题强调文字对比度至少4.5:1")
            }
        }
    }
    settings.backgroundTone = .dark
    settings.accentTone = .custom
    settings.customAccentHex = "#F08199"
    check(same(settings.resolvedPalette.accent, custom.accent), "橙黑主题保留自定义强调色")
    settings.backgroundTone = .custom
    settings.customBackgroundHex = "#123456"
    check(same(settings.resolvedPalette.background, customBackground.background), "橙黑主题保留自定义底色")
    settings.cardTheme = .deepSpace
    settings.backgroundTone = .dark
    settings.accentTone = .system
    settings.cardRenderingMode = .liquidGlass
    check(same(settings.resolvedPalette.accent, ScreenThemes.glassDark.accent), "新增主题不改变默认玻璃配色")
    check(same(ScreenThemes.einkMono.accent, (0, 0, 0)), "墨水屏继续使用黑白强调色")
    print("  C6项目资源引导、橙黑主题及玻璃默认配色隔离通过")
}
