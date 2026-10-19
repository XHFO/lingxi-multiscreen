import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import LinxDisplayCore

@MainActor
func testWeatherCardVisuals() throws {
    let mappings: [(WeatherCondition, [Int], String)] = [
        (.sunny, [0], "sun.max.fill"),
        (.cloudy, [1, 2], "cloud.sun.fill"),
        (.overcast, [3], "cloud.fill"),
        (.fog, [45, 48], "cloud.fog.fill"),
        (.drizzle, [51, 53, 55, 56, 57], "cloud.drizzle.fill"),
        (.rain, [61, 63, 65, 66, 67, 80, 81, 82], "cloud.rain.fill"),
        (.snow, [71, 73, 75, 77, 85, 86], "cloud.snow.fill"),
        (.thunderstorm, [95, 96, 99], "cloud.bolt.rain.fill")
    ]
    for (condition, codes, symbol) in mappings {
        for code in codes {
            checkEqual(WeatherCondition(code: code), condition, "天气 WMO \(code) 分类")
            checkEqual(WeatherSnapshot.description(code), condition.title, "天气 WMO \(code) 文案")
        }
        checkEqual(condition.symbolName, symbol, "天气分类 \(condition.rawValue) 图标")
        check(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
              "天气分类 \(condition.rawValue) 图标可用")
    }
    for code in [-1, 4, 44, 100, Int.max] {
        checkEqual(WeatherCondition(code: code), .unknown, "未知天气码安全回退 \(code)")
    }
    check(NSImage(systemSymbolName: WeatherCondition.unknown.symbolName,
                  accessibilityDescription: nil) != nil, "未知天气图标可用")
    func luminance(_ hex: UInt32) -> Double {
        let values = [Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)]
        let linear = values.map { value -> Double in
            let s = value / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
    func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    for dark in [false, true] {
        var backgrounds = Set<UInt32>()
        for condition in WeatherCondition.allCases {
            let palette = condition.palette(dark: dark)
            backgrounds.insert(palette.background)
            let skySamples = (0...20).map { palette.background(at: Double($0) / 20) }
            check(skySamples.allSatisfy { contrast(palette.foreground, $0) >= 4.5 },
                  "天气 \(condition.rawValue) 天空渐变所有采样位置主文字达到4.5:1")
            check(skySamples.allSatisfy { contrast(palette.secondary, $0) >= 4.5 },
                  "天气 \(condition.rawValue) 天空渐变所有采样位置次文字达到4.5:1")
            checkEqual(palette, condition.palette(dark: !dark), "彩屏天气氛围不被电脑深/浅模式改变")
            let ink = condition.palette(dark: dark, monochrome: true)
            checkEqual(ink.background, dark ? 0x000000 : 0xFFFFFF, "天气墨水屏纯黑白背景")
            checkEqual(ink.foreground, dark ? 0xFFFFFF : 0x000000, "天气墨水屏高反差文字")
            checkEqual(ink.secondary, ink.foreground, "天气墨水屏建议不使用浅灰文字")
        }
        checkEqual(backgrounds.count, WeatherCondition.allCases.count - 1,
                   "晴天与多云共用晴朗蓝天，其他天气拥有对应天空氛围")
    }
    checkEqual(WeatherCondition.sunny.palette(dark: false).background,
               WeatherCondition.cloudy.palette(dark: false).background, "多云是在晴朗蓝天基础增加云层")
    let clearSky = WeatherCondition.sunny.palette(dark: false)
    check((clearSky.background & 255) > ((clearSky.background >> 16) & 255), "晴天主天空是蓝色而非黄棕色")
    check((clearSky.symbol >> 16) & 255 > (clearSky.symbol & 255), "晴天太阳采用暖黄色")
    checkEqual(clearSky.background(at: 0), clearSky.background, "天空渐变顶部端点")
    checkEqual(clearSky.background(at: 1), clearSky.backgroundBottom, "天空渐变底部端点")
    checkEqual(clearSky.background(at: .nan), clearSky.background, "天空渐变拒绝非有限比例")
    for text in ["24°", "-12°", "100°"] {
        let typography = ScreenRenderer.weatherTextLayout(text, maxWidth: 97.2, maxHeight: 81.68,
            preferredSize: 64, minSize: 9, fontName: ScreenRenderer.weatherTemperatureFontName)
        checkEqual(typography.text, text, "窄屏天气温度完整保留数字、负号和度数")
        check(typography.fits && typography.width <= 96.2 && typography.height <= 80.68,
              "窄屏天气 \(text) 使用真实字形度量并留余量，不会触发省略或裁切")
    }
    for text in ["上海 · 多云", "呼和浩特 · 毛毛雨", "19–27°", "降雨 100%", "轻薄透气衣物"] {
        let typography = ScreenRenderer.weatherTextLayout(text, maxWidth: 97.2, maxHeight: 28,
                                                           preferredSize: 20, minSize: 9)
        check(typography.fits && typography.text == text, "天气真实标题/详情完整容纳：\(text)")
    }

    let now = Date(timeIntervalSince1970: 1_789_200_000)
    let settings = AppSettings()
    settings.cardRenderingMode = .classic
    settings.safeAreaHeight = 56
    settings.canvasModuleMargins = [:]
    let system = SystemSnapshot.empty
    let song = NowPlayingInfo(title: "", artist: "", album: "", duration: 0,
                              elapsedTime: 0, playbackRate: 0, sampledAt: now)
    let pomodoro = PomodoroSnapshot(phase: .idle, effectivePhase: .idle, taskName: "",
                                   remaining: 0, duration: 0, completedFocusSessions: 0)
    func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                    | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                        count: image.width * image.height * 4))
    }
    func foregroundPixels(_ bytes: [UInt8], matching hex: UInt32) -> Int {
        let red = Int((hex >> 16) & 255), green = Int((hex >> 8) & 255), blue = Int(hex & 255)
        var count = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            if abs(Int(bytes[i]) - red) <= 2 && abs(Int(bytes[i + 1]) - green) <= 2
                && abs(Int(bytes[i + 2]) - blue) <= 2 && bytes[i + 3] == 255 {
                count += 1
            }
        }
        return count
    }
    func rgb565(_ hex: UInt32) -> UInt16 {
        UInt16(((hex >> 16) & 0xF8) << 8 | ((hex >> 8) & 0xFC) << 3 | (hex & 0xFF) >> 3)
    }
    func closeColor(_ actual: UInt32, _ expected: UInt32) -> Bool {
        [UInt32(16), 8, 0].allSatisfy {
            abs(Int((actual >> $0) & 255) - Int((expected >> $0) & 255)) <= 2
        }
    }
    func render(code: Int, width: Int = 240, height: Int = 240,
                palette: ScreenPalette = ScreenThemes.get(.minimalLight), ink: Bool = false,
                modules: [CanvasModule] = [.weather]) -> CGImage {
        settings.weatherSnapshot = WeatherSnapshot(city: "上海", temperature: 24, apparent: 25,
                                                   low: 19, high: 27, rainProbability: 35,
                                                   code: code, updatedAt: now)
        return ScreenRenderer.renderDeviceCanvas(modules: modules, system: system,
            nowPlaying: song, pomodoro: pomodoro, customText: "相邻模块不受天气背景影响",
            settings: settings, now: now, width: width, height: height,
            palette: palette, optimizeForEInk: ink)
    }
    let previewDirectory = (ProcessInfo.processInfo.environment["LINGXI_WEATHER_PREVIEW_DIR"]
        ?? ProcessInfo.processInfo.environment["LINGXI_C6_PREVIEW_DIR"])
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    if let previewDirectory {
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
    }
    func export(_ image: CGImage, name: String) throws {
        guard let previewDirectory else { return }
        let url = previewDirectory.appendingPathComponent(name + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                    UTType.png.identifier as CFString, 1, nil) else { throw RenderError.encodeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encodeFailed }
    }
    var squareImages = Set<Data>()
    for (condition, codes, _) in mappings {
        let image = render(code: codes[0])
        let bytes = pixels(image)
        squareImages.insert(Data(bytes))
        let x = 1, y = 120, i = (y * image.width + x) * 4
        let palette = WeatherSkyPalette(weather: settings.weatherSnapshot!)
        let sampled = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
        let middleBackground = palette.background(x: CGFloat(x), y: CGFloat(y), width: 240, height: 240)
        check(closeColor(sampled, middleBackground), "正方形天气 \(condition.rawValue) 实际应用天空渐变中段（sRGB合成舍入≤2）")
        let upperIndex = (20 * image.width + x) * 4, lowerIndex = (220 * image.width + x) * 4
        let upper = UInt32(bytes[upperIndex]) << 16 | UInt32(bytes[upperIndex + 1]) << 8 | UInt32(bytes[upperIndex + 2])
        let lower = UInt32(bytes[lowerIndex]) << 16 | UInt32(bytes[lowerIndex + 1]) << 8 | UInt32(bytes[lowerIndex + 2])
        checkEqual(upper, palette.background(x: CGFloat(x), y: 20, width: 240, height: 240), "正方形天气 \(condition.rawValue) 实际天空上部色值")
        check(closeColor(lower, palette.background(x: CGFloat(x), y: 220, width: 240, height: 240)), "正方形天气 \(condition.rawValue) 实际天空下部色值")
        check(upper != lower, "正方形天气 \(condition.rawValue) 使用真实天空渐变而非纯色背景")
        check(foregroundPixels(bytes, matching: palette.foreground) >= 120,
              "正方形天气 \(condition.rawValue) 真实文字/图标有充足高反差像素")
        for (x, y) in [(12, 12), (12, 36), (12, 133), (12, 165), (12, 191), (12, 218)] {
            let background = palette.background(x: CGFloat(x), y: CGFloat(y), width: 240, height: 240)
            check(contrast(background, y == 218 ? palette.secondary : palette.foreground) >= 4.5,
                  "沉浸天气 \(condition.rawValue) 正文位置\(x),\(y)反差4.5:1")
        }
        let transport = try AIMacScreenSupport.encodeRGB565(image)
        let offset = (y * image.width + x) * 2
        let sentBackground = UInt16(transport[offset]) << 8 | UInt16(transport[offset + 1])
        checkEqual(sentBackground, rgb565(sampled),
                   "正方形天气 \(condition.rawValue) 实际RGB565传输保持软件预览主题色")
        try export(image, name: "square-light-" + condition.rawValue)
    }
    checkEqual(squareImages.count, mappings.count, "不同天气生成不同图标和背景")
    let sunnyBytes = pixels(render(code: 0)), cloudyBytes = pixels(render(code: 2))
    let cloudIndex = (85 * 240 + 205) * 4
    check(cloudyBytes[cloudIndex] > 190
        && Int(cloudyBytes[cloudIndex + 2]) > Int(sunnyBytes[cloudIndex + 2]) + 40,
          "多云蓝天中的白云是真实背景图案层，不只是天气文字和状态图标")
    var warmSunPixels = 0
    for i in stride(from: 0, to: sunnyBytes.count, by: 4) {
        if sunnyBytes[i] >= 245 && sunnyBytes[i + 1] >= 180 && sunnyBytes[i + 2] <= 135 {
            warmSunPixels += 1
        }
    }
    check(warmSunPixels >= 40, "晴天蓝天空中包含清晰的暖黄太阳")
    let darkImage = render(code: 0, palette: ScreenThemes.get(.deepSpace))
    let darkBytes = pixels(darkImage)
    let darkIndex = (120 * darkImage.width + 1) * 4
    let darkBackground = UInt32(darkBytes[darkIndex]) << 16
        | UInt32(darkBytes[darkIndex + 1]) << 8 | UInt32(darkBytes[darkIndex + 2])
    let immersiveSunny = WeatherSkyPalette(weather: settings.weatherSnapshot!)
    check(closeColor(darkBackground, immersiveSunny.background(x: 1, y: 120, width: 240, height: 240)),
               "电脑深色模式仍显示晴朗蓝天，不变为暖棕色")
    let darkForeground = immersiveSunny.foreground
    check(foregroundPixels(darkBytes, matching: darkForeground) >= 120,
          "电脑深色模式下天气仍保留充足天空主题高反差内容")
    checkEqual(pixels(darkImage), sunnyBytes, "天气昼夜取决于数据，不取决于电脑深色模式")
    try export(darkImage, name: "square-dark-sunny")

    for (width, height, name) in [(142, 428, "long"), (296, 128, "wide"), (240, 240, "square")] {
        let image = render(code: 95, width: width, height: height)
        checkEqual(image.width, width, "天气 \(name) 卡片实际宽度")
        checkEqual(image.height, height, "天气 \(name) 卡片实际高度")
        try export(image, name: name + "-light-thunderstorm")
        let sunshine = render(code: 0, width: width, height: height)
        let sunshinePixels = pixels(sunshine)
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if sunshinePixels[offset] >= 245 && sunshinePixels[offset + 1] >= 180 && sunshinePixels[offset + 2] <= 210 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        let aspect = Double(maxX - minX + 1) / Double(max(1, maxY - minY + 1))
        check(maxX >= minX && aspect >= (width < 150 ? 0.5 : 0.85) && aspect <= 1.15,
              "实际\(name)天气画面太阳保持正圆，长屏在边缘自然裁切")
        try export(sunshine, name: name + "-light-sunny")
        let inkImage = render(code: 95, width: width, height: height,
                              palette: ScreenThemes.einkMono, ink: true)
        let inkBytes = pixels(inkImage)
        var isGray = true
        for i in stride(from: 0, to: inkBytes.count, by: 4) {
            if inkBytes[i] != inkBytes[i + 1] || inkBytes[i] != inkBytes[i + 2] {
                isGray = false; break
            }
        }
        check(isGray, "天气 \(name) 墨水屏所有像素均为灰阶")
        check(inkBytes.contains(0) && inkBytes.contains(255), "天气 \(name) 墨水屏保留纯黑白对比")
        try export(inkImage, name: name + "-ink-thunderstorm")
    }
    let sunnyMixed = pixels(render(code: 0, modules: [.weather, .text]))
    let rainyMixed = pixels(render(code: 61, modules: [.weather, .text]))
    let bottomStart = 240 * 180 * 4
    checkEqual(Array(sunnyMixed[bottomStart...]), Array(rainyMixed[bottomStart...]),
               "天气主题和图标被限制在自己的模块，不改变相邻文本模块")
    for bandHeight in [50, 64] {
        let compact = render(code: 61, height: bandHeight + 16)
        checkEqual(compact.height, bandHeight + 16, "天气紧凑\(bandHeight)像素模块正常渲染")
        check(foregroundPixels(pixels(compact), matching: WeatherCondition.rain.palette(dark: false).foreground) >= 40,
              "天气紧凑\(bandHeight)像素模块保留充足温度/状态文字和图标像素")
        try export(compact, name: "compact-\(bandHeight)-rain")
    }
    settings.weatherSnapshot = WeatherSnapshot(city: "上海", temperature: 24, apparent: 25,
        low: 19, high: 27, rainProbability: 35, code: 0, updatedAt: now)
    let keyboard = try ScreenRenderer.renderCanvas(modules: [.weather], system: system,
        nowPlaying: song, pomodoro: pomodoro, customText: "", settings: settings,
        now: now, palette: ScreenThemes.get(.minimalLight))
    checkEqual(keyboard.image.width, 142, "键盘天气卡保持原生142像素宽")
    checkEqual(keyboard.image.height, 428, "键盘天气卡保持原生428像素高")
    // 对实际142×428成图做温度区域连通域检查。完整「24°」有三个字形；
    // 曾出现的「2…」会生成数字+三个省略点，不能仅凭图片非空通过回归。
    let keyboardPixels = pixels(keyboard.image)
    let crop = CGRect(x: 8, y: 126, width: 104, height: 70)
    let cropW = Int(crop.width), cropH = Int(crop.height)
    let targetRGB = [Int((immersiveSunny.foreground >> 16) & 255),
                     Int((immersiveSunny.foreground >> 8) & 255), Int(immersiveSunny.foreground & 255)]
    var mask = [Bool](repeating: false, count: cropW * cropH)
    for y in 0..<cropH {
        for x in 0..<cropW {
            let offset = ((Int(crop.minY) + y) * 142 + Int(crop.minX) + x) * 4
            mask[y * cropW + x] = (0..<3).allSatisfy { abs(Int(keyboardPixels[offset + $0]) - targetRGB[$0]) <= 12 }
        }
    }
    var components: [Int] = []
    for start in mask.indices where mask[start] {
        var queue = [start], cursor = 0, area = 0
        mask[start] = false
        while cursor < queue.count {
            let index = queue[cursor]; cursor += 1; area += 1
            let x = index % cropW, y = index / cropW
            for dy in -1...1 {
                for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < cropW, yy < cropH else { continue }
                    let neighbor = yy * cropW + xx
                    if mask[neighbor] { mask[neighbor] = false; queue.append(neighbor) }
                }
            }
        }
        if area >= 8 { components.append(area) }
    }
    checkEqual(components.count, 3, "实际键盘温度成图包含完整2、4、°三个字形，没有变成2…")
    var sunMinX = 142, sunMaxX = -1, sunMinY = 428, sunMaxY = -1
    for y in 120..<200 {
        for x in 90..<142 {
            let offset = (y * 142 + x) * 4
            if keyboardPixels[offset] >= 245 && keyboardPixels[offset + 1] >= 180 && keyboardPixels[offset + 2] <= 210 {
                sunMinX = min(sunMinX, x); sunMaxX = max(sunMaxX, x)
                sunMinY = min(sunMinY, y); sunMaxY = max(sunMaxY, y)
            }
        }
    }
    let sunAspect = Double(sunMaxX - sunMinX + 1) / Double(max(1, sunMaxY - sunMinY + 1))
    check(sunMaxX >= sunMinX && sunAspect > 0.5,
          "实际窄屏天气太阳在屏幕边缘自然裁切而非拉伸")
    try export(keyboard.image, name: "keyboard-light-sunny")
    for safe in [44, 56, 80] {
        settings.safeAreaHeight = safe
        let result = try ScreenRenderer.renderCanvas(modules: [.weather], system: system,
            nowPlaying: song, pomodoro: pomodoro, customText: "", settings: settings,
            now: now, palette: ScreenThemes.get(.minimalLight))
        let bytes = pixels(result.image)
        var untouched = true
        for y in 0..<safe {
            for x in 0..<142 {
                let expected = immersiveSunny.background(x: CGFloat(x), y: CGFloat(y),
                    width: 142, height: 428, safeArea: CGFloat(safe))
                let i = (y * 142 + x) * 4
                let actual = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
                if actual != expected { untouched = false }
            }
        }
        check(untouched, "键盘\(safe)像素安全区只有连续天空，没有电池、文字或系统UI")
        let boundary = (safe * 142 + 1) * 4
        let previous = ((safe - 1) * 142 + 1) * 4
        check((0..<3).allSatisfy { abs(Int(bytes[boundary + $0]) - Int(bytes[previous + $0])) <= 2 },
              "键盘\(safe)像素安全区底部没有色带或分隔线")
        let source = CGImageSourceCreateWithData(result.data as CFData, nil)!
        let transmitted = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        checkEqual(transmitted.width, result.image.width, "天气JPEG与预览宽度一致")
        checkEqual(transmitted.height, result.image.height, "天气JPEG与预览高度一致")
        let sentPixels = pixels(transmitted)
        let meanDifference = zip(bytes, sentPixels).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
            / Double(bytes.count)
        check(meanDifference < 10, "实际推送JPEG与预览仅有编码压缩误差，平均通道差小于10")
        try export(result.image, name: "keyboard-safe-\(safe)")
    }
    settings.safeAreaHeight = 56
    for value in [-12.0, 100.0] {
        settings.weatherSnapshot?.temperature = value
        let extreme = try ScreenRenderer.renderCanvas(modules: [.weather], system: system,
            nowPlaying: song, pomodoro: pomodoro, customText: "", settings: settings, now: now)
        check(extreme.data.count < ScreenRenderer.maximumFileSize, "极端温度在原生窄屏正常渲染和编码")
        try export(extreme.image, name: "keyboard-temperature-\(Int(value))")
    }
    for code in [0, 2, 65, 75] {
        _ = render(code: code)
        settings.weatherSnapshot?.isDay = false
        let night = ScreenRenderer.renderDeviceCanvas(modules: [.weather], system: system,
            nowPlaying: song, pomodoro: pomodoro, customText: "", settings: settings,
            now: now, width: 240, height: 240, palette: ScreenThemes.get(.minimalLight),
            optimizeForEInk: false)
        let nightBytes = pixels(night)
        let theme = WeatherSkyPalette(weather: settings.weatherSnapshot!)
        checkEqual(theme.top, 0x0A1730, "夜间天空由真实is_day驱动")
        check(foregroundPixels(nightBytes, matching: theme.foreground) >= 120, "夜间天气可读")
        if code == 0 {
            // 月盘左上切口是真天空，不是一个深色圆形覆盖物。
            let x = 240 - 28 - 48 + 9, y = 32 + 7, i = (y * 240 + x) * 4
            let actual = UInt32(nightBytes[i]) << 16 | UInt32(nightBytes[i + 1]) << 8 | UInt32(nightBytes[i + 2])
            checkEqual(actual, theme.background(x: CGFloat(x), y: CGFloat(y), width: 240, height: 240),
                       "夜间月牙切口完整透明，没有突兀的深色遮盖圆盘")
        }
        try export(night, name: "square-night-\(code)")
        let nightKeyboard = try ScreenRenderer.renderCanvas(modules: [.weather], system: system,
            nowPlaying: song, pomodoro: pomodoro, customText: "", settings: settings, now: now)
        try export(nightKeyboard.image, name: "keyboard-night-\(code)")
    }
    _ = render(code: 0)
    let oldCache = try JSONEncoder().encode(settings.weatherSnapshot!)
    let cacheObject = try JSONSerialization.jsonObject(with: oldCache) as! [String: Any]
    var legacyCache = cacheObject; legacyCache.removeValue(forKey: "isDay")
    let decoded = try JSONDecoder().decode(WeatherSnapshot.self,
        from: JSONSerialization.data(withJSONObject: legacyCache))
    check(decoded.isDay == nil && decoded.city == "上海", "旧天气缓存无需重置，可解码新增可选昼夜字段")
    var request = WeatherSettings(); request.city = "上海"; request.latitude = 31; request.longitude = 121
    check(WeatherClient.url(for: request)?.absoluteString.contains("is_day") == true,
          "天气请求获取当地昼夜状态，不使用电脑外观判断夜间")
    let payload = Data(#"{"current":{"temperature_2m":17,"apparent_temperature":18,"weather_code":0,"is_day":0},"daily":{"temperature_2m_max":[24],"temperature_2m_min":[16],"precipitation_probability_max":[0]}}"#.utf8)
    checkEqual(try WeatherClient.parse(payload, settings: request, now: now).isDay, false,
               "真实天气响应解析夜间状态")
    settings.cardRenderingMode = .liquidGlass
    let glassSquare = try LiquidGlassCardRenderer.renderImage(for: .aiMacScreen, mode: .liquidGlass,
        palette: ScreenThemes.get(.minimalLight)) {
            render(code: 0)
        }
    let glassBytes = pixels(glassSquare)
    let glassSkyIndex = (120 * 240 + 1) * 4
    let glassSky = UInt32(glassBytes[glassSkyIndex]) << 16
        | UInt32(glassBytes[glassSkyIndex + 1]) << 8 | UInt32(glassBytes[glassSkyIndex + 2])
    check(closeColor(glassSky, immersiveSunny.background(x: 1, y: 120, width: 240, height: 240)),
               "Liquid Glass彩屏合成后保留真实蓝天渐变，不被外层玻璃底层吞掉")
    check(foregroundPixels(glassBytes, matching: immersiveSunny.foreground) >= 120,
          "Liquid Glass天气保留真实高反差文字")
    try export(glassSquare, name: "square-glass-sunny")
    let glassKeyboard = try LiquidGlassCardRenderer.renderKeyboard(settings: settings) {
        try ScreenRenderer.renderCanvas(modules: [.weather], system: system,
            nowPlaying: song, pomodoro: pomodoro, customText: "", settings: settings,
            now: now, palette: ScreenThemes.get(.minimalLight))
    }
    let classicKeyboardBytes = pixels(keyboard.image), glassKeyboardBytes = pixels(glassKeyboard.image)
    let keyboardSkyIndex = (230 * 142 + 28) * 4
    checkEqual(Array(glassKeyboardBytes[keyboardSkyIndex..<(keyboardSkyIndex + 3)]),
               Array(classicKeyboardBytes[keyboardSkyIndex..<(keyboardSkyIndex + 3)]),
               "Liquid Glass键盘合成后保持天气天空局部颜色")
    check(Int(glassKeyboardBytes[keyboardSkyIndex + 2]) > Int(glassKeyboardBytes[keyboardSkyIndex]) + 20,
          "Liquid Glass键盘天气仍以蓝天空为主")
    try export(glassKeyboard.image, name: "keyboard-glass-sunny")
    settings.cardRenderingMode = .classic
    print("  天气图标、天气主题、对比度及彩屏/墨水屏多比例卡片通过")
}
