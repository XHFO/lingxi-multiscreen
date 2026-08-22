// LinxDisplay 冒烟测试（不依赖 XCTest，任何带 Swift 工具链的环境均可运行）
// 覆盖：四套主题 × 三种卡片的 JPEG 渲染、自定义图片裁剪、番茄钟状态机、
//       Codex 用量解析、自动同步规划、系统监控采样、设置往返。
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import LinxDisplayCore

var failures: [String] = []
var passed = 0

func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failures.append("\(message) (\((file as NSString).lastPathComponent):\(line))")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String,
                              file: String = #file, line: Int = #line) {
    check(actual == expected, "\(message)：期望 \(expected)，实际 \(actual)", file: file, line: line)
}

/// 生成递增的模拟网络速率历史（避免 .map 触发编译器类型检查超时）
func makeNetworkHistory(_ count: Int) -> [NetworkSample] {
    var result: [NetworkSample] = []
    result.reserveCapacity(count)
    for i in 0..<count {
        let index = Double(i)
        result.append(NetworkSample(
            downloadBytesPerSecond: 100_000.0 + index * 40_000.0,
            uploadBytesPerSecond: 20_000.0 + index * 2_500.0))
    }
    return result
}

/// 波动形的网络速率历史（用于折线图视觉预览）
func makeWavyNetworkHistory(_ count: Int) -> [NetworkSample] {
    var result: [NetworkSample] = []
    result.reserveCapacity(count)
    for i in 0..<count {
        let index = Double(i)
        result.append(NetworkSample(
            downloadBytesPerSecond: 300_000.0 + 250_000.0 * sin(index * 0.45) + index * 8_000.0,
            uploadBytesPerSecond: 60_000.0 + 30_000.0 * cos(index * 0.6) + index * 800.0))
    }
    return result
}

func decodeJPEG(_ data: Data) -> CGImage {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

// MARK: - 主题

func testThemes() {
    let themes: [CardTheme] = [.deepSpace, .minimalLight, .neonPurple, .amberTerminal]
    var backgrounds: [String] = []
    for theme in themes {
        let palette = ScreenThemes.get(theme)
        backgrounds.append("\(palette.background)")
        check(palette.accent != palette.secondaryAccent, "\(theme.title) accent 应区别于 secondaryAccent")
        check(palette.primaryText != palette.tertiaryText, "\(theme.title) primaryText 应区别于 tertiaryText")
    }
    checkEqual(Set(backgrounds).count, 4, "四套主题背景色应各不相同")
}

// MARK: - 渲染

func testRenderAllModesAndThemes() throws {
    let settings = AppSettings()
    let pomodoroSnapshot = PomodoroSnapshot(
        phase: .focus, effectivePhase: .focus, taskName: "写周报",
        remaining: 900, duration: 1500, completedFocusSessions: 2,
        endsAt: Date().addingTimeInterval(900))
    let system = SystemSnapshot(
        cpuPercent: 23.5, memoryPercent: 61.2,
        usedMemoryBytes: 8_000_000_000, totalMemoryBytes: 16_000_000_000,
        downloadBytesPerSecond: 1_234_567, uploadBytesPerSecond: 89_012,
        uptime: 3 * 86400 + 7200, sampledAt: Date())

    for theme in CardTheme.allCases {
        settings.cardTheme = theme
        let results: [(String, RenderResult)] = [
            ("usage", try ScreenRenderer.renderUsage(.sample, settings: settings)),
            ("pomodoro", try ScreenRenderer.renderPomodoro(pomodoroSnapshot, settings: settings)),
            ("system", try ScreenRenderer.renderSystem(system, settings: settings)),
            ("qwenwork", try ScreenRenderer.renderQwenWork(.sample, settings: settings))
        ]
        for (name, result) in results {
            check(result.data.count <= ScreenRenderer.maximumFileSize, "\(theme.title)/\(name) JPEG 超过 512KB")
            let image = decodeJPEG(result.data)
            checkEqual(image.width, ScreenRenderer.width, "\(theme.title)/\(name) 宽度")
            checkEqual(image.height, ScreenRenderer.height, "\(theme.title)/\(name) 高度")
        }
    }
    print("  渲染 16 张卡片 JPEG 通过")
}

func testRenderCustomImage() throws {
    // 生成 400×400 红色测试图
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
    let image = ctx.makeImage()!
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("linx-custom-\(UUID().uuidString).png")
    let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    check(CGImageDestinationFinalize(dest), "测试图写入失败")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let settings = AppSettings()
    let result = try ScreenRenderer.renderCustomImage(path: tempURL.path, settings: settings)
    check(result.data.count <= ScreenRenderer.maximumFileSize, "自定义图片 JPEG 超过 512KB")
    let decoded = decodeJPEG(result.data)
    checkEqual(decoded.width, 142, "自定义图片宽度")
    checkEqual(decoded.height, 428, "自定义图片高度")
    print("  自定义图片居中裁剪渲染通过")
}

// MARK: - 番茄钟

func testPomodoro() {
    let service = PomodoroService(state: PomodoroState())
    let now = Date()
    service.startOrResume(now: now)
    checkEqual(service.state.phase, .focus, "开始后应为专注")
    check(service.state.endsAt != nil, "开始后应有结束时间")

    service.state.endsAt = now.addingTimeInterval(-1)
    check(service.tick(now: now), "倒计时结束应触发切换")
    checkEqual(service.state.phase, .shortBreak, "第 1 轮结束应进入短休息")
    checkEqual(service.state.completedFocusSessions, 1, "已完成轮数")

    service.state.endsAt = now.addingTimeInterval(-1)
    _ = service.tick(now: now)
    checkEqual(service.state.phase, .focus, "短休息结束应回到专注")

    service.pause(now: now)
    checkEqual(service.state.phase, .paused, "应进入暂停")
    check(service.state.pausedRemainingSeconds > 0, "暂停应保留剩余秒数")
    service.startOrResume(now: now)
    checkEqual(service.state.phase, .focus, "继续应回到专注")

    service.skip(now: now)
    checkEqual(service.state.phase, .shortBreak, "跳过应进入休息")

    service.reset()
    checkEqual(service.state.phase, .idle, "重置应回到空闲")
    checkEqual(service.state.completedFocusSessions, 0, "重置应清零完成数")

    // 4 轮后长休息
    let s2 = PomodoroService(state: PomodoroState())
    s2.startOrResume(now: now) // 空闲 → 专注
    for _ in 0..<4 {
        s2.state.endsAt = now.addingTimeInterval(-1)
        _ = s2.tick(now: now) // 专注 → 休息
        if s2.state.phase != .longBreak {
            s2.state.endsAt = now.addingTimeInterval(-1)
            _ = s2.tick(now: now) // 休息 → 专注
        }
    }
    checkEqual(s2.state.completedFocusSessions, 4, "应完成 4 轮")
    checkEqual(s2.state.phase, .longBreak, "第 4 轮结束应进入长休息")

    // 暂停快照剩余时间
    let s3 = PomodoroService(state: PomodoroState())
    s3.startOrResume(now: now)
    s3.state.endsAt = now.addingTimeInterval(300)
    s3.pause(now: now)
    let snapshot = s3.snapshot(now: now)
    check(snapshot.isPaused, "快照应标记暂停")
    check(abs(snapshot.remaining - 300) < 1, "暂停剩余应为 300 秒")
    print("  番茄钟状态机通过")
}

// MARK: - Codex 解析

func testCodexParse() throws {
    let json: [String: Any] = [
        "rateLimitsByLimitId": [
            "codex": [
                "primary": ["usedPercent": 20.0, "windowDurationMins": 300, "resetsAt": 1_800_000_000],
                "secondary": ["usedPercent": 65.0, "windowDurationMins": 30, "resetsAt": 1_800_000_000],
                "planType": "plus"
            ]
        ],
        "rateLimitResetCredits": ["availableCount": 2]
    ]
    let snapshot = try CodexRateLimitClient.parseRateLimitResult(json)
    checkEqual(snapshot.remainingPercent, 80, "剩余百分比应为 100-20（取窗口更大的 primary）")
    checkEqual(snapshot.windowMinutes, 300, "窗口应为 300 分钟")
    checkEqual(snapshot.availableResetCount, 2, "可用重置次数")
    checkEqual(snapshot.planType, "plus", "套餐类型")
    check(snapshot.resetDate != nil, "应有重置时间")

    let legacy: [String: Any] = [
        "rateLimits": ["primary": ["usedPercent": 100.0, "windowDurationMins": 1_440]],
        "rateLimitResetCredits": ["availableCount": 1]
    ]
    let legacySnapshot = try CodexRateLimitClient.parseRateLimitResult(legacy)
    checkEqual(legacySnapshot.remainingPercent, 0, "旧格式 100% 用尽")
    checkEqual(legacySnapshot.windowMinutes, 1_440, "旧格式窗口")

    do {
        _ = try CodexRateLimitClient.parseRateLimitResult([:])
        check(false, "空数据应抛错")
    } catch {
        check(true, "空数据抛错")
    }
    print("  Codex 用量解析通过")
}

// MARK: - 同步规划

func testSyncPlanner() {
    let now = Date()
    checkEqual(SyncPlanner.forCodex(now: now, lastRefresh: nil, lastPush: nil, refreshSeconds: 300),
               .refreshAndPush, "从未刷新应刷新并推送")
    checkEqual(SyncPlanner.forCodex(now: now, lastRefresh: now, lastPush: now, refreshSeconds: 300),
               .none, "同一分钟已推送应无动作")
    let earlier = now.addingTimeInterval(-90)
    checkEqual(SyncPlanner.forCodex(now: now, lastRefresh: now, lastPush: earlier, refreshSeconds: 300),
               .push, "跨分钟应仅推送")
    let stale = now.addingTimeInterval(-301)
    checkEqual(SyncPlanner.forCodex(now: now, lastRefresh: stale, lastPush: earlier, refreshSeconds: 300),
               .refreshAndPush, "刷新过期应刷新并推送")
    print("  自动同步规划通过")
}

// MARK: - 系统监控

func testSystemMonitor() {
    let monitor = SystemMonitor()
    _ = monitor.sample()
    Thread.sleep(forTimeInterval: 0.2)
    let snapshot = monitor.sample()
    check(snapshot.totalMemoryBytes > 0, "内存总量应大于 0")
    check(snapshot.memoryPercent >= 0 && snapshot.memoryPercent <= 100, "内存占用应在 0-100%")
    check(snapshot.uptime > 0, "运行时间应大于 0")
    print("  系统监控采样通过（CPU \(Int(snapshot.cpuPercent.rounded()))% / 内存 \(Int(snapshot.memoryPercent.rounded()))%）")
}

// MARK: - 设置与工具

func testSettingsAndUtilities() {
    let settings = AppSettings()
    settings.endpoint = "http://10.0.0.5/image/upload"
    settings.cardTheme = .neonPurple
    settings.displayMode = .pomodoro
    settings.safeAreaHeight = 70
    settings.appearanceMode = .dark
    settings.backgroundTone = .custom
    settings.customBackgroundHex = "#112233"
    settings.accentTone = .orange
    settings.customAccentHex = "#FF4500"
    let data = try! JSONEncoder().encode(settings)
    let decoded = try! JSONDecoder().decode(AppSettings.self, from: data)
    checkEqual(decoded.endpoint, "http://10.0.0.5/image/upload", "设置往返 endpoint")
    checkEqual(decoded.cardTheme, .neonPurple, "设置往返主题")
    checkEqual(decoded.displayMode, .pomodoro, "设置往返模式")
    checkEqual(decoded.safeAreaHeight, 70, "设置往返安全区")
    checkEqual(decoded.appearanceMode, .dark, "设置往返外观")
    checkEqual(decoded.backgroundTone, .custom, "设置往返背景底色")
    checkEqual(decoded.customBackgroundHex, "#112233", "设置往返自定义背景")
    checkEqual(decoded.accentTone, .orange, "设置往返强调色")
    checkEqual(decoded.customAccentHex, "#FF4500", "设置往返自定义强调色")

    let state = PomodoroState()
    state.phase = .focus
    state.taskName = "读论文"
    state.completedFocusSessions = 3
    let stateData = try! JSONEncoder().encode(state)
    let stateDecoded = try! JSONDecoder().decode(PomodoroState.self, from: stateData)
    checkEqual(stateDecoded.phase, .focus, "番茄钟往返 phase")
    checkEqual(stateDecoded.taskName, "读论文", "番茄钟往返任务名")

    checkEqual(ScreenRenderer.formatRate(500), "500 B/s", "速率格式 B/s")
    checkEqual(ScreenRenderer.formatRate(2048), "2.0 KB/s", "速率格式 KB/s")
    checkEqual(ScreenRenderer.formatRate(5 * 1024 * 1024), "5.0 MB/s", "速率格式 MB/s")

    let weekly = UsageSnapshot(remainingPercent: 50, resetDate: nil, windowMinutes: 10_080,
                               availableResetCount: 0, planType: nil)
    checkEqual(weekly.windowTitle, "本周剩余", "周窗口标题")
    checkEqual(weekly.windowDescription, "7 天周期", "周窗口描述")
    print("  设置往返与工具函数通过")
}

// MARK: - 视觉预览导出（swift run LinxDisplaySmokeTests --previews <目录>）

func exportPreviews(to directory: String) throws {
    let settings = AppSettings()
    let pomodoroSnapshot = PomodoroSnapshot(
        phase: .focus, effectivePhase: .focus, taskName: "写周报",
        remaining: 900, duration: 1500, completedFocusSessions: 2,
        endsAt: Date().addingTimeInterval(900))
    let system = SystemSnapshot(
        cpuPercent: 23.5, memoryPercent: 61.2,
        usedMemoryBytes: 8_000_000_000, totalMemoryBytes: 16_000_000_000,
        downloadBytesPerSecond: 1_234_567, uploadBytesPerSecond: 89_012,
        uptime: 3 * 86400 + 7200, sampledAt: Date())

    let scale: CGFloat = 3
    let outURL = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

    for theme in CardTheme.allCases {
        settings.cardTheme = theme
        let results: [(String, RenderResult)] = [
            ("codex", try ScreenRenderer.renderUsage(.sample, settings: settings)),
            ("pomodoro", try ScreenRenderer.renderPomodoro(pomodoroSnapshot, settings: settings)),
            ("system", try ScreenRenderer.renderSystem(system, settings: settings)),
            ("qwenwork", try ScreenRenderer.renderQwenWork(.sample, settings: settings)),
            ("nowplaying", try ScreenRenderer.renderNowPlaying(.sample, settings: settings))
        ]
        for (name, result) in results {
            let ctx = CGContext(data: nil, width: Int(142 * scale), height: Int(428 * scale),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(result.image, in: CGRect(x: 0, y: 0, width: 142 * scale, height: 428 * scale))
            let scaled = ctx.makeImage()!
            let fileURL = outURL.appendingPathComponent("\(theme.title)-\(name).png")
            let dest = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, scaled, nil)
            _ = CGImageDestinationFinalize(dest)
            print("已导出 \(fileURL.path)")
        }
    }

    // 系统监控折线图预览（深空主题 + 四板块）
    do {
        func savePreview(_ result: RenderResult, name: String) {
            let ctx = CGContext(data: nil, width: Int(142 * scale), height: Int(428 * scale),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(result.image, in: CGRect(x: 0, y: 0, width: 142 * scale, height: 428 * scale))
            let url = outURL.appendingPathComponent("\(name).png")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            _ = CGImageDestinationFinalize(dest)
            print("已导出 \(url.path)")
        }
        let chartSettings = AppSettings()
        chartSettings.cardTheme = .deepSpace
        chartSettings.networkChart = true
        let history = makeWavyNetworkHistory(40)
        savePreview(try ScreenRenderer.renderSystem(system, history: history, settings: chartSettings),
                    name: "系统监控-网络折线图")
        let numbersSettings = AppSettings()
        numbersSettings.cardTheme = .deepSpace
        savePreview(try ScreenRenderer.renderSystem(system, settings: numbersSettings),
                    name: "系统监控-数字四板块")
    }

    // 自定义外观覆盖效果（深色底 + 紫色强调）
    let custom = AppSettings()
    custom.cardTheme = .deepSpace
    custom.backgroundTone = .custom
    custom.customBackgroundHex = "#1B1B2F"
    custom.accentTone = .purple
    let customResult = try ScreenRenderer.renderUsage(.sample, settings: custom)
    let customCtx = CGContext(data: nil, width: Int(142 * scale), height: Int(428 * scale),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    customCtx.interpolationQuality = .high
    customCtx.draw(customResult.image, in: CGRect(x: 0, y: 0, width: 142 * scale, height: 428 * scale))
    let customScaled = customCtx.makeImage()!
    let customURL = outURL.appendingPathComponent("自定义外观-深底紫强调.png")
    let customDest = CGImageDestinationCreateWithURL(customURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(customDest, customScaled, nil)
    _ = CGImageDestinationFinalize(customDest)
    print("已导出 \(customURL.path)")

    // 正在播放卡片（带封面）
    let artCtx = CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    artCtx.setFillColor(CGColor(red: 0.55, green: 0.2, blue: 0.75, alpha: 1))
    artCtx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
    artCtx.setFillColor(CGColor(red: 0.95, green: 0.85, blue: 0.3, alpha: 1))
    artCtx.fillEllipse(in: CGRect(x: 90, y: 90, width: 120, height: 120))
    let artImage = artCtx.makeImage()!
    let artData = NSMutableData()
    let artDest = CGImageDestinationCreateWithData(artData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(artDest, artImage, nil)
    _ = CGImageDestinationFinalize(artDest)
    var playingSample = NowPlayingInfo.sample
    playingSample.artwork = artData as Data
    playingSample.title = "星辰大海"
    playingSample.artist = "示例歌手"
    let playingResult = try ScreenRenderer.renderNowPlaying(playingSample, settings: AppSettings())
    let playingCtx = CGContext(data: nil, width: Int(142 * scale), height: Int(428 * scale),
                               bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    playingCtx.interpolationQuality = .high
    playingCtx.draw(playingResult.image, in: CGRect(x: 0, y: 0, width: 142 * scale, height: 428 * scale))
    let playingScaled = playingCtx.makeImage()!
    let playingURL = outURL.appendingPathComponent("正在播放-带封面.png")
    let playingDest = CGImageDestinationCreateWithURL(playingURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(playingDest, playingScaled, nil)
    _ = CGImageDestinationFinalize(playingDest)
    print("已导出 \(playingURL.path)")

    // 系统监控动态排版：仅 CPU
    let sysSettings = AppSettings()
    sysSettings.showCpu = true
    sysSettings.showMemory = false
    sysSettings.showNetwork = false
    sysSettings.showUptime = false
    let sysOnly = try ScreenRenderer.renderSystem(
        SystemSnapshot(cpuPercent: 37, memoryPercent: 60,
                       usedMemoryBytes: 8 * 1024 * 1024 * 1024, totalMemoryBytes: 16 * 1024 * 1024 * 1024,
                       downloadBytesPerSecond: 1_048_576, uploadBytesPerSecond: 512_000,
                       uptime: 90000, sampledAt: Date()),
        settings: sysSettings)
    let sysCtx = CGContext(data: nil, width: Int(142 * scale), height: Int(428 * scale),
                           bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    sysCtx.interpolationQuality = .high
    sysCtx.draw(sysOnly.image, in: CGRect(x: 0, y: 0, width: 142 * scale, height: 428 * scale))
    let sysOut = outURL.appendingPathComponent("系统监控-仅CPU.png")
    let sysDest = CGImageDestinationCreateWithURL(sysOut as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(sysDest, sysCtx.makeImage()!, nil)
    _ = CGImageDestinationFinalize(sysDest)
    print("已导出 \(sysOut.path)")
}

// MARK: - 设置迁移

func testMigration() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("linx-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: base.appendingPathComponent("LinxDisplay", isDirectory: true),
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    // 模拟原版 (.NET/Avalonia) 的 PascalCase 设置文件
    let originalSettings = """
    {
      "Endpoint": "http://192.168.100.170/image/upload",
      "CodexRefreshSeconds": 300,
      "DynamicUploadSeconds": 2,
      "SafeAreaHeight": 56,
      "JpegQuality": 94,
      "DisplayMode": 2,
      "CardTheme": 3,
      "CustomImagePath": null,
      "CustomImageName": null,
      "StartWithSystem": false,
      "CodexCliPath": null
    }
    """
    let originalPomodoro = """
    {
      "Phase": 1,
      "ResumePhase": 1,
      "EndsAt": "2026-08-20T13:30:00+08:00",
      "PausedRemainingSeconds": 0,
      "CompletedFocusSessions": 2,
      "TaskName": "读论文",
      "FocusMinutes": 40,
      "ShortBreakMinutes": 5,
      "LongBreakMinutes": 15
    }
    """
    try originalSettings.write(to: base.appendingPathComponent("LinxDisplay/settings-v2.json"), atomically: true, encoding: .utf8)
    try originalPomodoro.write(to: base.appendingPathComponent("LinxDisplay/pomodoro.json"), atomically: true, encoding: .utf8)

    let store = SettingsStore(dataDirectory: base)
    let settings = store.load()
    checkEqual(settings.endpoint, "http://192.168.100.170/image/upload", "迁移 endpoint")
    checkEqual(settings.displayMode, .systemMonitor, "迁移显示模式（2=系统监控）")
    checkEqual(settings.cardTheme, .amberTerminal, "迁移主题（3=琥珀终端）")
    checkEqual(settings.jpegQuality, 94, "迁移 JPEG 质量")

    let pomodoro = store.loadPomodoro()
    checkEqual(pomodoro.phase, .focus, "迁移番茄钟阶段")
    checkEqual(pomodoro.taskName, "读论文", "迁移番茄钟任务名")
    checkEqual(pomodoro.focusMinutes, 40, "迁移专注时长")
    checkEqual(pomodoro.completedFocusSessions, 2, "迁移完成轮数")

    // 迁移后应已写入自身格式
    check(FileManager.default.fileExists(atPath: store.settingsURL.path), "迁移后应生成本身设置文件")
    print("  原版设置迁移通过")
}

// MARK: - 千问办公额度

func testQuotaParse() throws {
    // 模拟本地 MCP 端点的 JSON-RPC 响应
    let inner: [String: Any] = [
        "ok": true,
        "key": "qwenwork.usage",
        "data": [
            "available": true,
            "isQuotaExceeded": false,
            "summary": ["hasPlanCredits": false],
            "segments": [
                ["id": "plan", "kind": "plan_credits", "total": 0, "used": 0,
                 "remaining": 2061.8672, "percentageUsed": 0, "unit": "credits"]
            ],
            "planCredits": [
                "total": 0, "used": 0, "remaining": 2061.8672,
                "percentage": 0, "unit": "credits"
            ]
        ]
    ]
    let innerData = try JSONSerialization.data(withJSONObject: inner)
    let innerText = String(data: innerData, encoding: .utf8)!
    let outer: [String: Any] = [
        "jsonrpc": "2.0",
        "result": ["content": [["type": "text", "text": innerText]]]
    ]
    let body = try JSONSerialization.data(withJSONObject: outer)

    let quota = try QwenWorkQuotaClient.parseResponse(body)
    check(abs(quota.remainingCredits - 2061.8672) < 0.001, "额度解析剩余值")
    checkEqual(quota.unit, "credits", "额度解析单位")
    checkEqual(quota.segments.count, 1, "额度解析分段数")
    check(abs(quota.progress - 1) < 0.001, "额度进度（未使用应为 1）")

    // 空数据应抛错
    let empty: [String: Any] = ["result": ["content": []]]
    let emptyBody = try JSONSerialization.data(withJSONObject: empty)
    do {
        _ = try QwenWorkQuotaClient.parseResponse(emptyBody)
        check(false, "空额度响应应抛错")
    } catch {
        check(true, "空额度响应抛错")
    }

    // 额度百分比：手动捕获基线为 100%，按 当前/基线 计算；未设基线返回 nil、上涨钳制 100%
    check(QwenWorkQuota.trackedQuotaProgress(current: 2000, baseline: nil) == nil, "未设基线应返回 nil")
    check(abs((QwenWorkQuota.trackedQuotaProgress(current: 1500, baseline: 2000) ?? 0) - 0.75) < 0.001,
          "额度 1500/2000 应剩 75%")
    check(abs((QwenWorkQuota.trackedQuotaProgress(current: 500, baseline: 2000) ?? 0) - 0.25) < 0.001,
          "额度 500/2000 应剩 25%")
    check(abs((QwenWorkQuota.trackedQuotaProgress(current: 2500, baseline: 2000) ?? 0) - 1) < 0.001,
          "额度上涨应钳制 100%（基线不变）")
    check(abs((QwenWorkQuota.trackedQuotaProgress(current: 0, baseline: 2500) ?? 1) - 0) < 0.001,
          "额度耗尽进度应为 0")
    // 跟踪进度覆盖 percentageUsed 口径
    var tracked = quota
    tracked.trackedProgress = 0.75
    check(abs(tracked.progress - 0.75) < 0.001, "跟踪进度应优先于百分比口径")

    // 百分比显示：不同剩余进度渲染出不同的「剩余 %」
    let q100 = quota
    var q75 = quota
    q75.trackedProgress = 0.75
    let percentCard100 = try ScreenRenderer.renderQwenWork(q100, settings: AppSettings())
    let percentCard75 = try ScreenRenderer.renderQwenWork(q75, settings: AppSettings())
    check(percentCard100.data != percentCard75.data, "剩余百分比不同应改变卡片渲染")
    print("  千问办公额度解析通过")
}

/// 从本机千问办公客户端拉取真实额度（配置缺失时跳过，不视为失败）
func testQuotaLiveFetch() async {
    do {
        let quota = try await QwenWorkQuotaClient().fetch()
        check(quota.remainingCredits >= 0, "本机额度拉取应非负")
        print("  本机千问办公额度拉取通过：剩余 \(String(format: "%.1f", quota.remainingCredits)) \(quota.unit)"
              + (quota.plan.map { "（\($0)）" } ?? ""))
    } catch QuotaError.configNotFound {
        print("  ⚠️ 未检测到千问办公本机服务，跳过真实拉取验证（不视为失败）")
    } catch {
        failures.append("本机额度拉取失败：\(error.localizedDescription)")
    }
}

func testEndpointBuilder() {
    checkEqual(EndpointBuilder.host(from: "http://192.168.100.170/image/upload"),
               "192.168.100.170", "提取主机")
    checkEqual(EndpointBuilder.host(from: "http://192.168.1.5:8080/image/upload"),
               "192.168.1.5:8080", "提取主机含端口")
    checkEqual(EndpointBuilder.endpoint(fromHost: "192.168.100.170"),
               "http://192.168.100.170/image/upload", "IP 拼端点")
    checkEqual(EndpointBuilder.endpoint(fromHost: "http://192.168.100.170/image/upload"),
               "http://192.168.100.170/image/upload", "粘贴完整地址归一化")
    checkEqual(EndpointBuilder.endpoint(fromHost: ""), "", "空输入")
    print("  键盘 IP 端点拼接通过")
}

func testAppearanceColors() {
    func checkRGB(_ actual: (CGFloat, CGFloat, CGFloat)?, _ expected: (CGFloat, CGFloat, CGFloat)?,
                  _ message: String, tolerance: CGFloat = 0.001) {
        guard let actual, let expected else {
            check(actual == nil && expected == nil, "\(message)：应同为 nil")
            return
        }
        check(abs(actual.0 - expected.0) < tolerance
              && abs(actual.1 - expected.1) < tolerance
              && abs(actual.2 - expected.2) < tolerance, "\(message)：\(actual) vs \(expected)")
    }

    checkRGB(HexColor.parse("#55E6B8"), (0x55 / 255, 0xE6 / 255, 0xB8 / 255), "hex 解析")
    check(HexColor.parse("not-a-color") == nil, "非法 hex 应返回 nil")
    checkEqual(HexColor.string(from: 1, 0, 0), "#FF0000", "hex 生成")

    checkRGB(AppearanceResolver.backgroundRGB(tone: .system, customHex: nil), nil,
             "背景跟随软件明暗由 resolved 解析（backgroundRGB 返回 nil）")
    checkRGB(AppearanceResolver.backgroundRGB(tone: .dark, customHex: nil), (0.11, 0.11, 0.13), "背景深色")
    checkRGB(AppearanceResolver.backgroundRGB(tone: .custom, customHex: "#112233"),
             (17 / 255, 34 / 255, 51 / 255), "背景自定义")
    checkRGB(AppearanceResolver.backgroundRGB(tone: .custom, customHex: nil), nil, "背景自定义无值 → nil")

    checkRGB(AppearanceResolver.accentRGB(tone: .blue, customHex: nil), (0.0, 0.478, 1.0), "强调蓝")
    checkRGB(AppearanceResolver.accentRGB(tone: .system, customHex: nil), nil, "强调跟随主题 → nil")
    checkRGB(AppearanceResolver.accentRGB(tone: .custom, customHex: "#FF4500"),
             (1, 69 / 255, 0), "强调自定义")
    print("  外观颜色解析通过")
}

func testResolvedPalette() throws {
    func near(_ a: (CGFloat, CGFloat, CGFloat)?, _ b: (CGFloat, CGFloat, CGFloat)?,
              _ message: String, tolerance: CGFloat = 0.001) {
        guard let a, let b else {
            check(a == nil && b == nil, "\(message)：应同为 nil")
            return
        }
        check(abs(a.0 - b.0) < tolerance && abs(a.1 - b.1) < tolerance && abs(a.2 - b.2) < tolerance,
              "\(message)：\(a) vs \(b)")
    }

    // 跟随软件明暗（软件为深色）→ 深色背景 + 强调色用所选主题
    let base = ScreenThemes.get(.deepSpace)
    let resolved = ScreenThemes.resolved(theme: .deepSpace, backgroundTone: .system,
                                         customBackgroundHex: nil, accentTone: .system,
                                         customAccentHex: nil, softwareIsDark: true)
    near(resolved.background, (0.11, 0.11, 0.13), "跟随软件深色 → 深色背景")
    near(resolved.accent, base.accent, "强调色跟随主题 → 使用主题强调色")
    near(resolved.primaryText, base.primaryText, "深底自动配浅色文字")

    // 跟随软件明暗（软件为浅色）→ 浅色背景 + 浅色体系文字
    let lightSoft = ScreenThemes.resolved(theme: .deepSpace, backgroundTone: .system,
                                          customBackgroundHex: nil, accentTone: .system,
                                          customAccentHex: nil, softwareIsDark: false)
    near(lightSoft.background, (0.95, 0.95, 0.97), "跟随软件浅色 → 浅色背景")
    near(lightSoft.primaryText, ScreenThemes.get(.minimalLight).primaryText, "浅底自动配深色文字")

    // 深色背景覆盖在浅色主题上 → 底色变深、文字切换为浅色体系
    let dark = ScreenThemes.resolved(theme: .minimalLight, backgroundTone: .dark,
                                     customBackgroundHex: nil, accentTone: .system, customAccentHex: nil)
    near(dark.background, (0.11, 0.11, 0.13), "深色背景覆盖")
    near(dark.card, (0.11, 0.11, 0.13), "深色卡片覆盖")
    let deepText = ScreenThemes.get(.deepSpace)
    near(dark.primaryText, deepText.primaryText, "深底自动配浅色文字")
    // 强调色「跟随主题」→ 使用所选主题（minimalLight）的强调色
    near(dark.accent, ScreenThemes.get(.minimalLight).accent, "强调色跟随所选主题")

    // 仅强调色覆盖 → 强调色替换
    let accent = ScreenThemes.resolved(theme: .deepSpace, backgroundTone: .system,
                                       customBackgroundHex: nil, accentTone: .custom, customAccentHex: "#FF4500")
    near(accent.accent, (1, 69 / 255, 0), "自定义强调色")

    // 次要文字可读性：深底上次要/三级文字亮度与底色拉开足够距离
    func lumOf(_ c: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2
    }
    let darkText = ScreenThemes.resolved(theme: .deepSpace, backgroundTone: .dark,
                                         customBackgroundHex: nil, accentTone: .system, customAccentHex: nil)
    check(lumOf(darkText.secondaryText) - lumOf(darkText.background) > 0.45,
          "深底次要文字应与底色拉开亮度差（可读性）")
    check(lumOf(darkText.tertiaryText) - lumOf(darkText.background) > 0.30,
          "深底三级文字应与底色拉开亮度差（可读性）")
    // 浅底：次要文字为深色，与底色亮度差足够
    let lightText = ScreenThemes.resolved(theme: .minimalLight, backgroundTone: .light,
                                          customBackgroundHex: nil, accentTone: .system, customAccentHex: nil)
    check(lumOf(lightText.background) - lumOf(lightText.secondaryText) > 0.45,
          "浅底次要文字应与底色拉开亮度差（可读性）")

    // 带覆盖的设置仍产出合法 JPEG
    let settings = AppSettings()
    settings.backgroundTone = .custom
    settings.customBackgroundHex = "#1B1B2F"
    settings.accentTone = .purple
    let result = try ScreenRenderer.renderUsage(.sample, settings: settings)
    check(result.data.count <= ScreenRenderer.maximumFileSize, "覆盖调色板渲染 JPEG 大小")
    let image = decodeJPEG(result.data)
    checkEqual(image.width, 142, "覆盖调色板渲染宽度")
    checkEqual(image.height, 428, "覆盖调色板渲染高度")
    print("  卡片调色板覆盖通过")
}

func testNowPlaying() throws {
    // 解析
    let dict: [String: Any] = [
        "kMRMediaRemoteNowPlayingInfoTitle": "测试歌曲",
        "kMRMediaRemoteNowPlayingInfoArtist": "测试歌手",
        "kMRMediaRemoteNowPlayingInfoAlbum": "测试专辑",
        "kMRMediaRemoteNowPlayingInfoDuration": 240.0,
        "kMRMediaRemoteNowPlayingInfoElapsedTime": 60.0,
        "kMRMediaRemoteNowPlayingInfoPlaybackRate": 1.0
    ]
    let parsed = NowPlayingClient.parseInfo(dict)
    check(parsed != nil, "正在播放解析应成功")
    checkEqual(parsed?.title, "测试歌曲", "正在播放标题")
    checkEqual(parsed?.artist, "测试歌手", "正在播放艺术家")
    check(parsed?.isPlaying == true, "正在播放状态")
    check(abs((parsed?.duration ?? 0) - 240) < 0.001, "正在播放时长")
    check(abs((parsed?.progress ?? 0) - 0.25) < 0.001, "正在播放进度")

    // 无媒体 → nil
    check(NowPlayingClient.parseInfo([:]) == nil, "空数据应返回 nil")
    check(NowPlayingClient.parseInfo(["kMRMediaRemoteNowPlayingInfoTitle": ""]) == nil, "空标题应返回 nil")

    // 渲染（无封面 → 占位）
    let settings = AppSettings()
    let noArt = try ScreenRenderer.renderNowPlaying(.sample, settings: settings)
    check(noArt.data.count <= ScreenRenderer.maximumFileSize, "正在播放 JPEG 大小")
    let img = decodeJPEG(noArt.data)
    checkEqual(img.width, 142, "正在播放宽度")
    checkEqual(img.height, 428, "正在播放高度")

    // 渲染（带封面）
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    let cover = ctx.makeImage()!
    let coverData = NSMutableData()
    let dest = CGImageDestinationCreateWithData(coverData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cover, nil)
    check(CGImageDestinationFinalize(dest), "封面测试图生成")
    var withArt = NowPlayingInfo.sample
    withArt.artwork = coverData as Data
    let artResult = try ScreenRenderer.renderNowPlaying(withArt, settings: settings)
    check(artResult.data.count <= ScreenRenderer.maximumFileSize, "带封面 JPEG 大小")
    checkEqual(decodeJPEG(artResult.data).width, 142, "带封面宽度")

    // 页脚顺序：上=时钟(强调色)，下=日期(主色)
    let footImg = noArt.image
    let fp = footImg.dataProvider!.data! as Data
    let fbpr = footImg.bytesPerRow
    var accentInTimeBand = 0
    for sy in 346...378 {
        var sx = 20
        while sx < 122 {
            let i = sy * fbpr + sx * 4
            let r = Int(fp[i]); let g = Int(fp[i + 1]); let b = Int(fp[i + 2])
            if g > 150 && g > r + 20 && g > b { accentInTimeBand += 1 }
            sx += 2
        }
    }
    check(accentInTimeBand > 20, "页脚上方应为时钟（强调色像素），实际 \(accentInTimeBand)")
    var whiteInDateBand = 0
    for sy in 382...402 {
        var sx = 30
        while sx < 112 {
            let i = sy * fbpr + sx * 4
            let r = Int(fp[i]); let g = Int(fp[i + 1]); let b = Int(fp[i + 2])
            if r > 200 && g > 200 && b > 200 { whiteInDateBand += 1 }
            sx += 2
        }
    }
    check(whiteInDateBand > 20, "页脚下方应为日期（主色像素），实际 \(whiteInDateBand)")

    // 歌名自适应字号逻辑
    let shortSize = ScreenRenderer.adaptiveFontSize("短标题", maxSize: 10, minSize: 5.5, bold: true, maxWidth: 104)
    checkEqual(shortSize, 10, "短标题保持最大字号")
    let longTitle = String(repeating: "歌", count: 16)
    let shrunk = ScreenRenderer.adaptiveFontSize(longTitle, maxSize: 10, minSize: 5.5, bold: true, maxWidth: 104)
    check(shrunk < 10 && shrunk >= 5.5, "超宽标题字号缩减（\(shrunk)）")
    let megaTitle = String(repeating: "歌", count: 40)
    checkEqual(ScreenRenderer.adaptiveFontSize(megaTitle, maxSize: 10, minSize: 5.5, bold: true, maxWidth: 104),
               5.5, "极长标题缩到下限字号")
    // 超长歌名渲染：缩小后铺满可用宽度
    var longSong = NowPlayingInfo.sample
    longSong.title = longTitle
    let longResult = try ScreenRenderer.renderNowPlaying(longSong, settings: settings)
    let longImg = longResult.image
    let lp = longImg.dataProvider!.data! as Data
    let lbpr = longImg.bytesPerRow
    var minXpx = 999, maxXpx = 0
    for sy in 206...224 {
        var sx = 12
        while sx < 130 {
            let i = sy * lbpr + sx * 4
            if Int(lp[i]) > 180 || Int(lp[i + 1]) > 180 || Int(lp[i + 2]) > 180 {
                if sx < minXpx { minXpx = sx }
                if sx > maxXpx { maxXpx = sx }
            }
            sx += 1
        }
    }
    check(maxXpx - minXpx > 60, "长歌名渲染铺满可用宽度（实际跨度 \(maxXpx - minXpx)）")

    // 歌名/歌手信息字号设置：分别调整应改变渲染
    let sizeSettings = AppSettings()
    sizeSettings.nowPlayingTitleSize = 10
    sizeSettings.nowPlayingArtistSize = 8
    let sizeSmall = try ScreenRenderer.renderNowPlaying(withArt, settings: sizeSettings)
    sizeSettings.nowPlayingTitleSize = 20
    sizeSettings.nowPlayingArtistSize = 16
    let sizeBig = try ScreenRenderer.renderNowPlaying(withArt, settings: sizeSettings)
    check(sizeSmall.data != sizeBig.data, "歌名字号调整应改变渲染")
    check(sizeBig.data.count <= ScreenRenderer.maximumFileSize, "大字号渲染大小")

    // 底部时间/日期：格式、字号自定义与隐藏布局
    let footerSettings = AppSettings()
    footerSettings.nowPlayingTimeFormat = "HH:mm:ss"
    footerSettings.nowPlayingDateFormat = "yyyy年M月d日 EEE"
    let fmtResult = try ScreenRenderer.renderNowPlaying(withArt, settings: footerSettings)
    check(fmtResult.data != artResult.data, "底部时间/日期格式自定义应改变渲染")
    footerSettings.nowPlayingTimeSize = 36
    let bigTime = try ScreenRenderer.renderNowPlaying(withArt, settings: footerSettings)
    check(bigTime.data != fmtResult.data, "底部时间字号调整应改变渲染")
    footerSettings.nowPlayingTimeSize = 22
    footerSettings.nowPlayingFooterVisible = false
    let hiddenResult = try ScreenRenderer.renderNowPlaying(withArt, settings: footerSettings)
    check(hiddenResult.data != artResult.data, "隐藏底部时间/日期应改变渲染")

    // 隐藏时封面在可用空间内垂直居中：扫描封面填充色（深蓝，g<140 且 b>220 且 g-r>45），
    // 要求连续 16 行命中才算封面本体（封面光晕带更薄，避免误判为上边缘）；
    // 上边缘应显著低于默认贴顶位置；卡片底色（1.18 系数偏亮）不会误命中
    func coverTopRow(_ result: RenderResult) -> Int {
        let img = result.image
        let w = img.width, h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var runStart = -1
        var run = 0
        for y in 40..<320 {
            var matches = 0
            for x in 55...85 {
                let i = (y * w + x) * 4
                let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                if b > 220 && g < 140 && g - r > 45 { matches += 1 }
            }
            if matches >= 15 {
                if run == 0 { runStart = y }
                run += 1
                if run >= 16 { return runStart }
            } else {
                run = 0
                runStart = -1
            }
        }
        return -1
    }
    let visibleCoverTop = coverTopRow(artResult)
    let hiddenCoverTop = coverTopRow(hiddenResult)
    check(visibleCoverTop > 0 && hiddenCoverTop > visibleCoverTop + 40,
          "隐藏底部时间/日期后封面应在可用空间内垂直居中下移（visible=\(visibleCoverTop) hidden=\(hiddenCoverTop)）")

    // 封面背后光晕：浅色封面与同色系背景对比弱，改用深色封面验证——
    // 深色封面主色被提亮后，封面上方蓝色通道应显著高于远处（无光晕处）
    func avgBlue(_ result: RenderResult, _ y: Int) -> Double {
        let img = result.image
        let w = img.width, h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        var count = 0.0
        for x in stride(from: 60, through: 82, by: 2) {
            let i = (y * w + x) * 4
            sum += Double(p[i + 2])
            count += 1
        }
        return sum / count
    }
    let darkCtx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    darkCtx.setFillColor(CGColor(red: 0.05, green: 0.1, blue: 0.5, alpha: 1))
    darkCtx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    let darkMD = NSMutableData()
    let darkDest = CGImageDestinationCreateWithData(darkMD, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(darkDest, darkCtx.makeImage()!, nil)
    check(CGImageDestinationFinalize(darkDest), "光晕测试深色封面生成")
    var darkNP = NowPlayingInfo.sample
    darkNP.artwork = darkMD as Data
    let darkSettings = AppSettings()
    darkSettings.nowPlayingFooterVisible = false
    let darkResult = try ScreenRenderer.renderNowPlaying(darkNP, settings: darkSettings)
    // 隐藏页脚时封面顶边在 y≈174（安全区 56），光晕带从封面向上延伸约 48px；
    // 在封面上方 2–9px 取最大亮度与远处背景对比
    var darkNear = 0.0
    for yy in 165...172 { darkNear = max(darkNear, avgBlue(darkResult, yy)) }
    let darkFar = avgBlue(darkResult, 114)
    check(darkNear > darkFar + 15,
          "封面背后应有主色光晕（nearB=\(darkNear) farB=\(darkFar)）")

    // 推送质量：JPEG 质量默认 100（4:4:4 无彩色抽样）；PNG 编码保留（摘录画板推送用）
    let pngCard = try ScreenRenderer.renderNowPlaying(withArt, settings: settings)
    let pngBytes = ScreenRenderer.pngData(from: pngCard.image)
    check(pngBytes != nil, "PNG 编码应成功")
    if let pngBytes {
        check(pngBytes.count <= ScreenRenderer.maximumFileSize, "PNG 体积不超过上限")
        let pngImage = decodeJPEG(pngBytes)
        checkEqual(pngImage.width, 142, "PNG 宽度")
        checkEqual(pngImage.height, 428, "PNG 高度")
    }
    let jpegRT = AppSettings()
    jpegRT.jpegQuality = 95
    let jpegDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(jpegRT))
    checkEqual(jpegDecoded.jpegQuality, 95, "JPEG 质量往返")
    checkEqual(AppSettings().jpegQuality, 100, "JPEG 质量默认 100（4:4:4 无彩色抽样）")
    let pngClamp = AppSettings()
    pngClamp.jpegQuality = 999
    pngClamp.clamped()
    checkEqual(pngClamp.jpegQuality, 100, "JPEG 质量上界钳制 100")

    // 字号调小后底部行距应收紧（行间距释放出来）：「当前时间」行随字号缩小而贴近底部时间
    func footerLabelTop(_ result: RenderResult) -> Int {
        let img = result.image
        let w = img.width, h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 300..<400 {
            var matches = 0
            for x in 45...95 {
                let i = (y * w + x) * 4
                let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                if r > 130 && g > 130 && b > 130 && abs(r - g) < 25 && abs(g - b) < 30 { matches += 1 }
            }
            if matches >= 4 { return y }
        }
        return -1
    }
    footerSettings.nowPlayingFooterVisible = true
    footerSettings.nowPlayingTimeSize = 22
    footerSettings.nowPlayingDateSize = 17
    let footerDefault = try ScreenRenderer.renderNowPlaying(withArt, settings: footerSettings)
    let labelDefault = footerLabelTop(footerDefault)
    footerSettings.nowPlayingTimeSize = 12
    footerSettings.nowPlayingDateSize = 8
    let footerSmall = try ScreenRenderer.renderNowPlaying(withArt, settings: footerSettings)
    let labelSmall = footerLabelTop(footerSmall)
    check(labelDefault > 0 && labelSmall > labelDefault + 8,
          "字号调小后底部「当前时间」行应随之上移收紧（default=\(labelDefault) small=\(labelSmall)）")

    // 进度合并：MediaRemote elapsed 停滞时保留本地推进值，防止进度条回跳
    let stale = NowPlayingInfo(title: "同一首歌", artist: "歌手", album: "专辑",
                               duration: 240, elapsedTime: 60, playbackRate: 1)
    let progressed = NowPlayingInfo(title: "同一首歌", artist: "歌手", album: "专辑",
                                    duration: 240, elapsedTime: 72, playbackRate: 1)
    checkEqual(stale.mergedWithProgressed(current: progressed).elapsedTime, 72,
               "同曲停滞值应保留本地推进")
    let ahead = NowPlayingInfo(title: "同一首歌", artist: "歌手", album: "专辑",
                               duration: 240, elapsedTime: 90, playbackRate: 1)
    checkEqual(ahead.mergedWithProgressed(current: progressed).elapsedTime, 90,
               "同曲拉取值更前应采用拉取值")
    let switched = NowPlayingInfo(title: "新歌", artist: "歌手", album: "专辑",
                                  duration: 200, elapsedTime: 5, playbackRate: 1)
    checkEqual(switched.mergedWithProgressed(current: progressed).elapsedTime, 5,
               "换曲应采用新值")
    let pausedCurrent = NowPlayingInfo(title: "同一首歌", artist: "歌手", album: "专辑",
                                       duration: 240, elapsedTime: 72, playbackRate: 0)
    checkEqual(stale.mergedWithProgressed(current: pausedCurrent).elapsedTime, 60,
               "暂停状态应采用拉取值")

    print("  正在播放解析与渲染通过")
}

/// 从本机系统拉取真实正在播放状态（无媒体时跳过，不视为失败）
func testNowPlayingLiveFetch() async {
    do {
        let info = try await NowPlayingClient().fetch()
        let state = info.isPlaying ? "播放中" : "已暂停"
        print("  本机正在播放拉取通过：\(info.title) · \(info.artist)（\(state)）")
    } catch NowPlayingError.notPlaying {
        print("  ℹ️ 当前无媒体在播，跳过真实拉取验证（不视为失败）")
    } catch {
        failures.append("正在播放拉取失败：\(error.localizedDescription)")
    }
}

func testSystemToggleLayouts() throws {
    let settings = AppSettings()
    let system = SystemSnapshot(cpuPercent: 42, memoryPercent: 60,
                                usedMemoryBytes: 8 * 1024 * 1024 * 1024, totalMemoryBytes: 16 * 1024 * 1024 * 1024,
                                downloadBytesPerSecond: 1_048_576, uploadBytesPerSecond: 512_000,
                                uptime: 90000, sampledAt: Date())
    func render() throws -> RenderResult { try ScreenRenderer.renderSystem(system, settings: settings) }

    // 默认全开
    let all = try render()
    check(all.data.count <= ScreenRenderer.maximumFileSize, "系统全板块渲染大小")
    checkEqual(decodeJPEG(all.data).width, 142, "系统全板块宽度")
    checkEqual(decodeJPEG(all.data).height, 428, "系统全板块高度")

    // 仅 CPU
    settings.showCpu = true; settings.showMemory = false; settings.showNetwork = false; settings.showUptime = false
    check(try render().data.count > 0, "仅 CPU 渲染")

    // 仅内存
    settings.showCpu = false; settings.showMemory = true; settings.showNetwork = false; settings.showUptime = false
    check(try render().data.count > 0, "仅内存渲染")

    // 仅网络
    settings.showCpu = false; settings.showMemory = false; settings.showNetwork = true; settings.showUptime = false
    check(try render().data.count > 0, "仅网络渲染")

    // 全关 → 至少回退一项
    settings.showCpu = false; settings.showMemory = false; settings.showNetwork = false; settings.showUptime = false
    check(try render().data.count > 0, "全关渲染（回退 CPU）")

    // CPU + 网络
    settings.showCpu = true; settings.showMemory = false; settings.showNetwork = true; settings.showUptime = false
    check(try render().data.count > 0, "CPU+网络渲染")
    print("  系统监控动态排版通过")
}

func testArtworkColorExtraction() throws {
    // 生成纯色红/白封面
    func solidImage(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx.makeImage()!
    }
    let red = solidImage(0.85, 0.1, 0.1)
    let d = ScreenRenderer.dominantColor(of: red)
    check(d.0 > 0.65 && d.0 > d.1 && d.0 > d.2, "红色封面主色应为红色为主")

    let white = solidImage(0.95, 0.95, 0.95)
    let lightPalette = ScreenRenderer.artworkPalette(baseColor: ScreenRenderer.dominantColor(of: white),
                                                     themeAccent: (0, 0.48, 1))
    check(lightPalette.primaryText.0 < 0.4, "浅色封面应配深色文字")

    let dark = solidImage(0.05, 0.05, 0.1)
    let darkPalette = ScreenRenderer.artworkPalette(baseColor: ScreenRenderer.dominantColor(of: dark),
                                                    themeAccent: (0, 0.48, 1))
    check(darkPalette.primaryText.0 > 0.6, "深色封面应配浅色文字")

    // 带封面渲染
    let info = NowPlayingInfo(title: "测试歌曲", artist: "测试歌手", album: "测试专辑",
                              duration: 200, elapsedTime: 45, playbackRate: 1,
                              artwork: nil, sampledAt: Date())
    let result = try ScreenRenderer.renderNowPlaying(info, settings: AppSettings(), artworkImage: red)
    check(result.data.count > 0, "带封面渲染")
    checkEqual(decodeJPEG(result.data).width, 142, "带封面宽度")
    checkEqual(decodeJPEG(result.data).height, 428, "带封面高度")
    print("  封面取色与渲染通过")
}

func testImageCropper() throws {
    // 1000×1000 图片，裁切框显示尺寸对应实际显示区域 (142:372)
    let cropDisplay = CGSize(width: 142, height: 372)
    let display = CGSize(width: 400, height: 500)
    // 默认居中：裁剪应位于正中央的竖直条
    let rect = ImageCropper.cropRect(imageSize: CGSize(width: 1000, height: 1000),
                                     displaySize: display, imageOffset: .zero,
                                     zoom: 1, cropDisplaySize: cropDisplay)
    check(rect != nil, "居中裁切矩形应存在")
    if let rect {
        check(abs(rect.midX - 500) < 1, "裁切应水平居中")
        check(abs(rect.minY) < 1, "裁切应覆盖全高")
        // 裁切比例应匹配显示区域比例
        let ratio = rect.width / rect.height
        check(abs(ratio - 142.0 / 372.0) < 0.01, "裁切比例应匹配显示区域比例")
    }
    // 平移后裁切位置移动
    let moved = ImageCropper.cropRect(imageSize: CGSize(width: 1000, height: 1000),
                                      displaySize: display,
                                      imageOffset: CGSize(width: -50, height: 0),
                                      zoom: 1, cropDisplaySize: cropDisplay)
    if let moved {
        check(moved.midX > 500, "图片向左移时裁切中心应右移（显示图片右侧区域）")
    }
    // 缩放后裁切变小
    let zoomed = ImageCropper.cropRect(imageSize: CGSize(width: 1000, height: 1000),
                                       displaySize: display, imageOffset: .zero,
                                       zoom: 2, cropDisplaySize: cropDisplay)
    if let zoomed, let rect {
        check(zoomed.width < rect.width, "放大后裁切区域应更小")
    }
    // 偏移钳制
    let clamped = ImageCropper.clampedOffset(CGSize(width: 9999, height: -9999),
                                             imageSize: CGSize(width: 1000, height: 1000),
                                             displaySize: display, zoom: 1,
                                             cropDisplaySize: cropDisplay)
    let maxX = 1000 * 0.372 / 2 - cropDisplay.width / 2
    check(abs(clamped.width - maxX) < 0.5, "过大偏移应被钳制到覆盖范围上界")
    print("  ImageCropper 裁切数学通过")
}

func testCropRenderPipeline() throws {
    // 生成一张与屏幕显示区域等比例 (142:372) 的图片：左半红、右半蓝
    let imgW = 142, imgH = 372
    let ctx = CGContext(data: nil, width: imgW, height: imgH, bitsPerComponent: 8, bytesPerRow: imgW * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: imgW / 2, height: imgH))
    ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: imgW / 2, y: 0, width: imgW / 2, height: imgH))
    let img = ctx.makeImage()!
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("linx-pipeline-\(UUID().uuidString).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    check(CGImageDestinationFinalize(dest), "管线测试图写入")
    defer { try? FileManager.default.removeItem(at: url) }

    // 裁切比例匹配 → renderCustomImage 应不二次裁切、完整绘制
    let settings = AppSettings()
    let result = try ScreenRenderer.renderCustomImage(path: url.path, settings: settings)
    let out = decodeJPEG(result.data)
    checkEqual(out.width, 142, "裁切渲染宽度")
    checkEqual(out.height, 428, "裁切渲染高度")
    check(result.data.count <= ScreenRenderer.maximumFileSize, "裁切渲染大小")
    print("  裁切→渲染管线通过")
}

// MARK: - 自定义图片历史

func testImageHistory() throws {
    // 1) upsert：去重、置顶、最多保留 9 条
    var entries: [RecentImage] = []
    for i in 1...10 {
        entries = RecentImage.upsert(entries, new: RecentImage(path: "/img/\(i).png", name: "图片\(i)"), limit: 9)
    }
    checkEqual(entries.count, 9, "历史记录上限为 9")
    checkEqual(entries.first?.path, "/img/10.png", "最新记录置顶")
    check(!entries.contains(where: { $0.path == "/img/1.png" }), "最旧记录被挤出")
    // 重复插入同路径：去重并置顶
    entries = RecentImage.upsert(entries, new: RecentImage(path: "/img/5.png", name: "图片5"), limit: 9)
    checkEqual(entries.count, 9, "重复插入不增加条数")
    checkEqual(entries.first?.path, "/img/5.png", "重复插入会置顶")

    // 2) 设置持久化往返（含历史）
    let settings = AppSettings()
    settings.customImageHistory = [
        RecentImage(path: "/a.png", name: "A"),
        RecentImage(path: "/b.jpg", name: "B"),
    ]
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    checkEqual(decoded.customImageHistory.count, 2, "历史条数往返")
    checkEqual(decoded.customImageHistory.first?.name, "A", "历史内容往返")

    // 3) 历史文件存储与清理
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linx-history-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let store = SettingsStore(dataDirectory: tempDir)
    // 造一个假图片源
    let fake = Data([0x89, 0x50, 0x4E, 0x47])
    let source = tempDir.appendingPathComponent("src.png")
    try fake.write(to: source)
    let saved = try store.saveHistoryImage(from: source)
    check(FileManager.default.fileExists(atPath: saved.path), "历史副本已写入")
    check(saved.lastPathComponent.hasSuffix(".png"), "历史副本保留扩展名")
    check(saved.path.hasPrefix(store.historyDirectory.path), "历史副本位于历史目录")
    // 再造一个将被清除的副本
    let other = try store.saveHistoryImage(from: source)
    // 清理：保留当前图片（saved），删除其他（other）
    store.clearHistoryFiles(keepingCurrentPath: saved.path)
    check(FileManager.default.fileExists(atPath: saved.path), "清理后当前图片保留")
    check(!FileManager.default.fileExists(atPath: other.path), "清理后其他历史副本删除")
    // 全部清理（不保留任何当前图片）
    store.clearHistoryFiles(keepingCurrentPath: nil)
    check(!FileManager.default.fileExists(atPath: saved.path), "清除全部时副本也被删除")
    print("  图片历史记录通过")
}

// MARK: - 网络折线图

func testNetworkChart() throws {
    let system = SystemSnapshot(
        cpuPercent: 23.5, memoryPercent: 61.2,
        usedMemoryBytes: 8_000_000_000, totalMemoryBytes: 16_000_000_000,
        downloadBytesPerSecond: 1_234_567, uploadBytesPerSecond: 89_012,
        uptime: 3 * 86400 + 7200, sampledAt: Date())
    let history = makeNetworkHistory(30)

    // 数字模式（默认）正常渲染
    let numbers = AppSettings()
    let r1 = try ScreenRenderer.renderSystem(system, history: history, settings: numbers)
    checkEqual(r1.image.width, ScreenRenderer.width, "数字模式宽度")
    checkEqual(r1.image.height, ScreenRenderer.height, "数字模式高度")

    // 折线图模式渲染
    let chart = AppSettings()
    chart.networkChart = true
    let r2 = try ScreenRenderer.renderSystem(system, history: history, settings: chart)
    checkEqual(r2.image.width, ScreenRenderer.width, "折线图模式宽度")
    check(r2.data.count <= ScreenRenderer.maximumFileSize, "折线图模式文件大小")

    // 折线图模式但无历史 → 回退为数字显示，不崩溃
    let r3 = try ScreenRenderer.renderSystem(system, settings: chart)
    checkEqual(r3.image.height, ScreenRenderer.height, "无历史回退数字渲染")

    // 四板块全开（槽位最紧凑），验证渲染仍成功（布局钳制不溢出）
    let tight = AppSettings()
    tight.networkChart = true
    let r4 = try ScreenRenderer.renderSystem(system, history: history, settings: tight)
    checkEqual(r4.image.height, ScreenRenderer.height, "四板块紧凑布局渲染高度")
    check(r4.data.count <= ScreenRenderer.maximumFileSize, "四板块紧凑布局文件大小")

    // networkChart 设置往返
    let data = try JSONEncoder().encode(chart)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    checkEqual(decoded.networkChart, true, "networkChart 往返")

    // 回归：网络文字必须绘制在网络盒子带内（skia y 262-302，x 30-130）。
    // 此前 CG/Skia 坐标混用导致文字画到 CPU/内存板块、盒内为空（堆叠问题根因）。
    let image = r1.image
    let pxData = image.dataProvider!.data! as Data
    let bpr = image.bytesPerRow
    var boxBright = 0
    for sy in 262...302 {
        var sx = 30
        while sx < 130 {
            let i = sy * bpr + sx * 4
            let r = Int(pxData[i]); let g = Int(pxData[i + 1]); let b = Int(pxData[i + 2])
            if r > 180 || g > 180 || b > 180 { boxBright += 1 }
            sx += 2
        }
    }
    check(boxBright > 20, "网络盒子带内应含文字亮像素（回归：坐标混用堆叠），实际 \(boxBright)")
    print("  网络折线图通过")
}

// MARK: - 侧栏排序

func testSidebarOrdering() throws {
    let available = ["qwenWork", "codex", "pomodoro", "system", "nowPlaying", "customImage"]
    // 空配置 = 默认顺序
    checkEqual(MenuOrdering.ordered([], available: available), available, "空排序 = 默认顺序")
    // 自定义顺序：完全遵循配置
    let custom = ["customImage", "pomodoro", "nowPlaying", "codex", "system", "qwenWork"]
    checkEqual(MenuOrdering.ordered(custom, available: available), custom, "自定义顺序生效")
    // 缺失项补在末尾（按可用顺序）
    let partial = MenuOrdering.ordered(["nowPlaying", "customImage"], available: available)
    checkEqual(partial, ["nowPlaying", "customImage", "qwenWork", "codex", "pomodoro", "system"],
               "缺失项按默认顺序补在末尾")
    // 未知标识被忽略
    let withUnknown = MenuOrdering.ordered(["foo", "customImage", "bar"], available: available)
    checkEqual(withUnknown, ["customImage", "qwenWork", "codex", "pomodoro", "system", "nowPlaying"],
               "未知标识被忽略")
    // 重复项去重（保留首次出现位置）
    let dup = MenuOrdering.ordered(["codex", "pomodoro", "codex"], available: available)
    checkEqual(dup, ["codex", "pomodoro", "qwenWork", "system", "nowPlaying", "customImage"],
               "重复项去重且保留首次位置")
    // 设置往返
    let settings = AppSettings()
    settings.sidebarOrder = ["customImage", "codex", "pomodoro"]
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    checkEqual(decoded.sidebarOrder, ["customImage", "codex", "pomodoro"], "sidebarOrder 往返")

    // 分组排序：键盘功能项与设备画板各自独立分组，互不串组
    let allMain = ["qwenWork", "codex", "pomodoro", "system", "nowPlaying",
                   "customImage", "canvas", "oracleCanvas", "excerptCanvas"]
    let mixed = MenuOrdering.ordered(["excerptCanvas", "pomodoro", "oracleCanvas", "system"], available: allMain)
    let keyboardGroup: Set<String> = ["qwenWork", "codex", "pomodoro", "system", "nowPlaying", "customImage", "canvas"]
    let canvasGroup: Set<String> = ["oracleCanvas", "excerptCanvas"]
    checkEqual(MenuOrdering.grouped(mixed, in: keyboardGroup),
               ["pomodoro", "system", "qwenWork", "codex", "nowPlaying", "customImage", "canvas"],
               "键盘分组只含键盘项且保持相对顺序")
    checkEqual(MenuOrdering.grouped(mixed, in: canvasGroup), ["excerptCanvas", "oracleCanvas"],
               "设备画板分组只含画板项且保持相对顺序")
    print("  侧栏排序通过")
}

// MARK: - 最近图片轮换

func testRotationInterval() throws {
    // 边界：0→5 秒，1→300 秒
    checkEqual(RotationInterval.seconds(fromSlider: 0), 5, "滑杆 0 = 5 秒")
    checkEqual(RotationInterval.seconds(fromSlider: 1), 300, "滑杆 1 = 300 秒")
    // 非线性：等距滑杆步长，低段秒数增量 < 高段秒数增量（时间越长档位越粗）
    let lowOverlap = RotationInterval.seconds(fromSlider: 0.1) - RotationInterval.seconds(fromSlider: 0)
    let highOverlap = RotationInterval.seconds(fromSlider: 1.0) - RotationInterval.seconds(fromSlider: 0.9)
    check(lowOverlap < highOverlap, "低段档位应细于高段（低段 +\(lowOverlap)s vs 高段 +\(highOverlap)s）")
    // 滑杆与秒数互逆
    let mid = RotationInterval.seconds(fromSlider: 0.5)
    let back = RotationInterval.slider(fromSeconds: mid)
    check(abs(RotationInterval.seconds(fromSlider: back) - mid) <= 1, "滑杆/秒数互逆（\(mid) 秒 ↔ 位置 \(back)）")
    // 文案
    checkEqual(RotationInterval.label(forSeconds: 5), "5 秒", "秒级文案")
    checkEqual(RotationInterval.label(forSeconds: 60), "1 分钟", "整分文案")
    checkEqual(RotationInterval.label(forSeconds: 150), "2 分 30 秒", "分秒文案")
    // 模式枚举
    checkEqual(ImageRotationMode.sequential.title, "顺序切换", "顺序模式标题")
    checkEqual(ImageRotationMode.random.title, "随机切换", "随机模式标题")
    checkEqual(ImageRotationMode.sequential.rawValue, 0, "顺序模式 rawValue")

    // 设置往返
    let settings = AppSettings()
    settings.imageRotationEnabled = true
    settings.imageRotationSeconds = 90
    settings.imageRotationMode = .random
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    checkEqual(decoded.imageRotationEnabled, true, "轮换开关往返")
    checkEqual(decoded.imageRotationSeconds, 90, "轮换秒数往返")
    checkEqual(decoded.imageRotationMode, .random, "轮换模式往返")
    print("  最近图片轮换通过")
}

// MARK: - 自定义图片时钟叠加

func testClockOverlay() throws {
    // 造一张测试图
    let imgW = 284, imgH = 744 // 与 142:372 同比例（2x）
    let ctx = CGContext(data: nil, width: imgW, height: imgH, bitsPerComponent: 8,
                        bytesPerRow: imgW * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.25, green: 0.45, blue: 0.65, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: imgW, height: imgH))
    let img = ctx.makeImage()!
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linx-clock-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("test.png")
    let dest = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    check(CGImageDestinationFinalize(dest), "时钟测试图生成")

    // 固定时间基准（保证断言确定性）
    let base = Date(timeIntervalSince1970: 1_752_000_000) // 不指定语义，仅用于确定性
    let settings = AppSettings()
    settings.customImagePath = path.path

    // 各布局渲染成功且尺寸正确
    for overlay in CustomImageClockOverlay.allCases {
        settings.customImageClock = overlay
        let result = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
        checkEqual(result.image.width, 142, "时钟叠加 \(overlay.title) 宽度")
        checkEqual(result.image.height, 428, "时钟叠加 \(overlay.title) 高度")
        check(result.data.count <= ScreenRenderer.maximumFileSize, "时钟叠加 \(overlay.title) 大小")
    }

    // 叠加与不叠加渲染结果不同（时钟确实画上去了）
    settings.customImageClock = .none
    let noneResult = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.customImageClock = .horizontalTop
    let pillResult = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(noneResult.data != pillResult.data, "叠加时钟后画面应变化")

    // 同一分钟内渲染结果一致（分钟级刷新，非秒级）
    settings.customImageClock = .verticalCenter
    let r1 = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    let r2 = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings,
                                                 now: base.addingTimeInterval(40))
    check(r1.data == r2.data, "同一分钟内时钟画面应一致")

    // 跨分钟渲染结果不同（跟随系统分钟刷新）
    let r3 = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings,
                                                 now: base.addingTimeInterval(60))
    check(r1.data != r3.data, "跨分钟时钟画面应变化")

    // 横向底部与横向顶部布局不同
    settings.customImageClock = .horizontalTop
    let ht = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.customImageClock = .horizontalBottom
    let hb = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(ht.data != hb.data, "横向顶部/底部布局应不同")
    settings.customImageClock = .verticalLeft
    let vl = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(vl.data != ht.data, "竖向布局应与横向布局不同")

    // 设置往返
    let roundTrip = AppSettings()
    roundTrip.customImageClock = .horizontalBottom
    let encoded = try JSONEncoder().encode(roundTrip)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
    checkEqual(decoded.customImageClock, .horizontalBottom, "时钟叠加设置往返")

    // 字体粗细：枚举/字体名、设置往返、不同字重渲染不同
    checkEqual(ClockFontWeight.allCases.count, 5, "时钟字重数量")
    checkEqual(ClockFontWeight.thin.title, "纤细", "时钟字重标题")
    checkEqual(ClockFontWeight.thin.fontName, "HelveticaNeue-Thin", "纤细对应字体名")
    checkEqual(ClockFontWeight.ultraLight.fontName, "HelveticaNeue-UltraLight", "极细字体名")
    checkEqual(ClockFontWeight.medium.fontName, "HelveticaNeue-Medium", "中粗字体名")
    let weightRT = AppSettings()
    weightRT.clockFontWeight = .medium
    let weightDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(weightRT))
    checkEqual(weightDecoded.clockFontWeight, .medium, "时钟字重设置往返")
    checkEqual(AppSettings().clockFontWeight, .thin, "时钟字重默认纤细")
    settings.customImageClock = .verticalCenter
    let thinRender = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.clockFontWeight = .medium
    let mediumRender = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(thinRender.data != mediumRender.data, "时钟字重调整应改变渲染")

    // 字号调节：不同字号渲染结果不同
    settings.customImageClock = .horizontalTop
    settings.clockFontSize = 24
    let small = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.clockFontSize = 52
    let big = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(small.data != big.data, "字号 24/52 渲染应不同")

    // 时间格式：不同格式渲染不同
    settings.clockFontSize = 36
    settings.clockTimeFormat = "HH:mm"
    let fmtHM = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.clockTimeFormat = "HH:mm:ss"
    let fmtHMS = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(fmtHM.data != fmtHMS.data, "HH:mm 与 HH:mm:ss 渲染应不同")
    // 用下午时间对比（HH:mm=14:40 vs hh:mm=02:40 必然不同）
    let afternoon = base.addingTimeInterval(12 * 3600)
    settings.clockTimeFormat = "HH:mm"
    let hmAfternoon = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: afternoon)
    settings.clockTimeFormat = "hh:mm"
    let fmt12 = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: afternoon)
    check(fmt12.data != hmAfternoon.data, "12/24 小时制渲染应不同")

    // 无效格式回退 HH:mm（不崩溃且与 HH:mm 一致）
    settings.clockTimeFormat = ""
    let fallback = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.clockTimeFormat = "HH:mm"
    let plain = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(fallback.data == plain.data, "空格式应回退 HH:mm")

    // 字号/格式设置往返
    let rt2 = AppSettings()
    rt2.clockFontSize = 44
    rt2.clockTimeFormat = "HH:mm:ss"
    let data2 = try JSONEncoder().encode(rt2)
    let decoded2 = try JSONDecoder().decode(AppSettings.self, from: data2)
    checkEqual(decoded2.clockFontSize, 44, "时钟字号往返")
    checkEqual(decoded2.clockTimeFormat, "HH:mm:ss", "时钟格式往返")
    print("  时钟叠加通过")
}

// MARK: - 安全区卡片几何（第二个底色框顶边须随安全区同步移动）

func testSafeAreaCardGeometry() throws {
    func edges(safeArea: Int) throws -> (top: Int, bottom: Int) {
        let s = AppSettings()
        s.safeAreaHeight = safeArea
        let r = try ScreenRenderer.renderUsage(.sample, settings: s)
        let data = r.image.dataProvider!.data! as Data
        let bpr = r.image.bytesPerRow
        func lum(_ y: Int) -> Double {
            let i = y * bpr + 71 * 4
            return 0.299 * Double(data[i]) + 0.587 * Double(data[i + 1]) + 0.114 * Double(data[i + 2])
        }
        // 「跟随软件明暗」下背景与卡片同色（读回亮度≈38），只能靠边框（≈52）定位卡片上下边
        var top = -1
        for y in 0..<428 where lum(y) > 45 { top = y; break }
        var bottom = -1
        for y in (0..<428).reversed() where lum(y) > 45 { bottom = y; break }
        return (top, bottom)
    }
    let e44 = try edges(safeArea: 44)
    let e56 = try edges(safeArea: 56)
    let e80 = try edges(safeArea: 80)
    check(abs(e44.top - 44) <= 1 && abs(e56.top - 56) <= 1 && abs(e80.top - 80) <= 1,
          "卡片顶边应随安全区同步移动（44/56/80 → \(e44.top)/\(e56.top)/\(e80.top)）")
    check(e80.top - e44.top > 25, "安全区 44→80 顶边应显著下移（实际差 \(e80.top - e44.top)）")
    check(abs(e44.bottom - 419) <= 1 && abs(e80.bottom - 419) <= 1,
          "卡片底边应固定在 419（实际 \(e44.bottom)/\(e80.bottom)）")
    print("  安全区卡片几何通过")
}

// MARK: - 系统监控负载指示灯

func testSystemLoadIndicator() throws {
    func dotColor(cpu: Double) throws -> (r: Double, g: Double, b: Double) {
        let snap = SystemSnapshot(cpuPercent: cpu, memoryPercent: 50,
                                  usedMemoryBytes: 0, totalMemoryBytes: 0,
                                  downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
                                  uptime: 0, sampledAt: Date())
        let result = try ScreenRenderer.renderSystem(snap, settings: AppSettings())
        let data = result.image.dataProvider!.data! as Data
        let bpr = result.image.bytesPerRow
        // 指示灯 skia 位置 ≈ (22, 75)：card.minX+13.5 / card.minY+18.5
        var r = 0.0; var g = 0.0; var b = 0.0
        var count = 0
        for dy in -1...1 {
            for dx in -1...1 {
                let i = (75 + dy) * bpr + (22 + dx) * 4
                r += Double(data[i]); g += Double(data[i + 1]); b += Double(data[i + 2])
                count += 1
            }
        }
        return (r / Double(count) / 255, g / Double(count) / 255, b / Double(count) / 255)
    }
    let low = try dotColor(cpu: 15)
    let mid = try dotColor(cpu: 55)
    let high = try dotColor(cpu: 85)
    check(low.g > low.r && low.g > low.b,
          String(format: "低负载应为绿灯 (r %.2f g %.2f b %.2f)", low.r, low.g, low.b))
    check(mid.r > mid.b && mid.g > mid.b && mid.r > 0.6,
          String(format: "适中负载应为黄灯 (r %.2f g %.2f b %.2f)", mid.r, mid.g, mid.b))
    check(high.r > high.g && high.r > high.b,
          String(format: "高负载应为红灯 (r %.2f g %.2f b %.2f)", high.r, high.g, high.b))
    print("  负载指示灯通过")
}

// MARK: - 画板

func testCanvas() throws {
    let system = SystemSnapshot(cpuPercent: 35, memoryPercent: 62,
                                usedMemoryBytes: 8_000_000_000, totalMemoryBytes: 16_000_000_000,
                                downloadBytesPerSecond: 500_000, uploadBytesPerSecond: 50_000,
                                uptime: 86_400 + 7_200, sampledAt: Date())
    let pomodoro = PomodoroSnapshot(phase: .focus, effectivePhase: .focus, taskName: "画板",
                                    remaining: 900, duration: 1500, completedFocusSessions: 1,
                                    endsAt: Date().addingTimeInterval(900))
    let np = NowPlayingInfo.sample
    let settings = AppSettings()

    // 全部模块渲染
    settings.canvasModules = CanvasModule.allCases.map(\.rawValue)
    let all = try ScreenRenderer.renderCanvas(modules: settings.canvasModuleList, system: system,
                                              nowPlaying: np, pomodoro: pomodoro,
                                              customText: "Hello Canvas", settings: settings)
    checkEqual(all.image.width, 142, "画板全模块宽度")
    checkEqual(all.image.height, 428, "画板全模块高度")
    check(all.data.count <= ScreenRenderer.maximumFileSize, "画板全模块大小")

    // 空画板与全模块不同
    settings.canvasModules = []
    let empty = try ScreenRenderer.renderCanvas(modules: settings.canvasModuleList, system: system,
                                                nowPlaying: np, pomodoro: pomodoro,
                                                customText: "", settings: settings)
    check(empty.data != all.data, "空画板与全模块渲染应不同")

    // 时钟模块：同分钟一致、跨分钟不同
    settings.canvasModules = [CanvasModule.clock.rawValue]
    let fixed = Date(timeIntervalSince1970: 1_752_000_000)
    let c1 = try ScreenRenderer.renderCanvas(modules: settings.canvasModuleList, system: system,
                                             nowPlaying: np, pomodoro: pomodoro,
                                             customText: "", settings: settings, now: fixed)
    let c2 = try ScreenRenderer.renderCanvas(modules: settings.canvasModuleList, system: system,
                                             nowPlaying: np, pomodoro: pomodoro,
                                             customText: "", settings: settings,
                                             now: fixed.addingTimeInterval(30))
    check(c1.data == c2.data, "时钟模块同分钟渲染应一致")
    let c3 = try ScreenRenderer.renderCanvas(modules: settings.canvasModuleList, system: system,
                                             nowPlaying: np, pomodoro: pomodoro,
                                             customText: "", settings: settings,
                                             now: fixed.addingTimeInterval(120))
    check(c1.data != c3.data, "时钟模块跨分钟渲染应不同")

    // 设置往返
    let rt = AppSettings()
    rt.canvasModules = [0, 2, 4, 8]
    rt.canvasText = "测试"
    let data = try JSONEncoder().encode(rt)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    checkEqual(decoded.canvasModules, [0, 2, 4, 8], "画板模块往返")
    checkEqual(decoded.canvasText, "测试", "画板文字往返")
    checkEqual(decoded.canvasModuleList.count, 4, "画板模块列表数量")
    print("  画板通过")
}

// MARK: - 番茄钟夸夸与任务名字号

func testPraiseAndTaskFont() throws {
    // 夸夸卡渲染
    let settings = AppSettings()
    let praise = try ScreenRenderer.renderPraise(text: "太棒了！你又完成了一个专注时段", sessions: 3, settings: settings)
    checkEqual(praise.image.width, 142, "夸夸卡宽度")
    checkEqual(praise.image.height, 428, "夸夸卡高度")
    check(praise.data.count <= ScreenRenderer.maximumFileSize, "夸夸卡大小")
    // 超长夸夸文本也正常（自适应缩字号）
    let longPraise = try ScreenRenderer.renderPraise(text: String(repeating: "太棒了", count: 30), sessions: 1, settings: settings)
    check(longPraise.data.count <= ScreenRenderer.maximumFileSize, "长夸夸文本大小")
    check(praise.data != longPraise.data, "不同夸夸文本渲染应不同")
    // 内置夸夸语
    check(!PomodoroService.randomPraisePhrase().isEmpty, "内置夸夸语非空")
    checkEqual(PomodoroService.praisePhrases.count, 8, "内置夸夸语数量")

    // 任务名字号：7 vs 16 渲染不同
    let snap = PomodoroSnapshot(phase: .focus, effectivePhase: .focus, taskName: "写周报",
                                remaining: 900, duration: 1500, completedFocusSessions: 2,
                                endsAt: Date().addingTimeInterval(900))
    let small = AppSettings(); small.pomodoroTaskFontSize = 7
    let large = AppSettings(); large.pomodoroTaskFontSize = 16
    let rSmall = try ScreenRenderer.renderPomodoro(snap, settings: small)
    let rLarge = try ScreenRenderer.renderPomodoro(snap, settings: large)
    check(rSmall.data != rLarge.data, "任务名字号 7/16 渲染应不同")

    // 设置往返
    let rt = AppSettings()
    rt.pomodoroPraiseEnabled = true
    rt.pomodoroPraiseSource = .hitokoto
    rt.pomodoroTaskFontSize = 13
    let data = try JSONEncoder().encode(rt)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    checkEqual(decoded.pomodoroPraiseEnabled, true, "夸夸开关往返")
    checkEqual(decoded.pomodoroPraiseSource, .hitokoto, "夸夸来源往返")
    checkEqual(decoded.pomodoroTaskFontSize, 13, "任务名字号往返")
    checkEqual(PraiseSource.builtin.title, "内置夸夸语（随机轮换）", "内置来源标题")
    print("  夸夸与任务名字号通过")
}

// MARK: - 画板自定义（时钟/日期格式、大封面、自定义图像）

func testCanvasCustomization() throws {
    // 造一张测试图（同比例）
    let imgW = 284, imgH = 744
    let ctx = CGContext(data: nil, width: imgW, height: imgH, bitsPerComponent: 8,
                        bytesPerRow: imgW * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: imgW, height: imgH))
    let img = ctx.makeImage()!
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linx-canvas-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("bg.png")
    let dest = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    check(CGImageDestinationFinalize(dest), "画板测试图生成")

    let system = SystemSnapshot(cpuPercent: 30, memoryPercent: 55,
                                usedMemoryBytes: 0, totalMemoryBytes: 0,
                                downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
                                uptime: 0, sampledAt: Date())
    let np = NowPlayingInfo.sample
    let pomodoro = PomodoroSnapshot(phase: .focus, effectivePhase: .focus, taskName: "任务",
                                    remaining: 100, duration: 1500, completedFocusSessions: 1,
                                    endsAt: Date().addingTimeInterval(100))
    let fixed = Date(timeIntervalSince1970: 1_752_000_000)

    let s = AppSettings()
    s.canvasModules = [CanvasModule.clock.rawValue, CanvasModule.date.rawValue]
    func render() throws -> RenderResult {
        try ScreenRenderer.renderCanvas(modules: s.canvasModuleList, system: system,
                                        nowPlaying: np, pomodoro: pomodoro,
                                        customText: "", settings: s, now: fixed)
    }
    let fmtDefault = try render()
    s.canvasClockFormat = "HH:mm:ss"
    s.canvasDateFormat = "M/d"
    let fmtCustom = try render()
    check(fmtDefault.data != fmtCustom.data, "画板时钟/日期格式自定义应改变渲染")
    check(fmtCustom.data.count <= ScreenRenderer.maximumFileSize, "自定义格式渲染大小")

    // 画板底色模式：手动深/浅色，不随软件明暗同步；深浅渲染不同
    func canvasModePalette(_ dark: Bool) -> ScreenPalette {
        ScreenThemes.resolved(theme: s.cardTheme,
                              backgroundTone: dark ? .dark : .light,
                              customBackgroundHex: nil,
                              accentTone: s.accentTone,
                              customAccentHex: s.customAccentHex,
                              softwareIsDark: dark)
    }
    let darkPaletteSoftFalse = ScreenThemes.resolved(theme: s.cardTheme, backgroundTone: .dark,
                                                     customBackgroundHex: nil, accentTone: s.accentTone,
                                                     customAccentHex: s.customAccentHex, softwareIsDark: false)
    let darkPaletteSoftTrue = ScreenThemes.resolved(theme: s.cardTheme, backgroundTone: .dark,
                                                    customBackgroundHex: nil, accentTone: s.accentTone,
                                                    customAccentHex: s.customAccentHex, softwareIsDark: true)
    let lightPaletteSoftFalse = ScreenThemes.resolved(theme: s.cardTheme, backgroundTone: .light,
                                                      customBackgroundHex: nil, accentTone: s.accentTone,
                                                      customAccentHex: s.customAccentHex, softwareIsDark: false)
    let lightPaletteSoftTrue = ScreenThemes.resolved(theme: s.cardTheme, backgroundTone: .light,
                                                     customBackgroundHex: nil, accentTone: s.accentTone,
                                                     customAccentHex: s.customAccentHex, softwareIsDark: true)
    check(darkPaletteSoftFalse.background == darkPaletteSoftTrue.background, "深色底色不随软件明暗变化")
    check(lightPaletteSoftFalse.background == lightPaletteSoftTrue.background, "浅色底色不随软件明暗变化")
    let darkCanvas = try ScreenRenderer.renderCanvas(modules: s.canvasModuleList, system: system,
                                                     nowPlaying: np, pomodoro: pomodoro,
                                                     customText: "", settings: s,
                                                     palette: canvasModePalette(true))
    let lightCanvas = try ScreenRenderer.renderCanvas(modules: s.canvasModuleList, system: system,
                                                      nowPlaying: np, pomodoro: pomodoro,
                                                      customText: "", settings: s,
                                                      palette: canvasModePalette(false))
    check(darkCanvas.data != lightCanvas.data, "画板深色/浅色底色渲染应不同")

    // 大封面模式（无封面时回退文字版式，不崩溃）
    s.canvasModules = [CanvasModule.nowPlaying.rawValue]
    s.canvasClockFormat = "HH:mm"
    s.canvasDateFormat = "yyyy年M月d日 EEE"
    s.canvasNowPlayingCover = false
    let coverOff = try render()
    s.canvasNowPlayingCover = true
    let coverOn = try render()
    checkEqual(coverOff.image.width, 142, "大封面关闭版式宽度")
    checkEqual(coverOn.image.width, 142, "大封面开启版式宽度")
    check(coverOn.data.count <= ScreenRenderer.maximumFileSize, "大封面渲染大小")

    // 智能封面取色背景：构造带封面的播放信息，对比开/关
    let coverCtx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    coverCtx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1))
    coverCtx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    let coverMD = NSMutableData()
    let coverDest = CGImageDestinationCreateWithData(coverMD, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(coverDest, coverCtx.makeImage()!, nil)
    check(CGImageDestinationFinalize(coverDest), "智能背景测试封面生成")
    var npWithArt = np
    npWithArt.artwork = coverMD as Data
    s.canvasModules = [CanvasModule.nowPlaying.rawValue]
    s.canvasNowPlayingCover = false
    s.canvasNowPlayingSmartBg = false
    let smartOff = try ScreenRenderer.renderCanvas(modules: s.canvasModuleList, system: system,
                                                   nowPlaying: npWithArt, pomodoro: pomodoro,
                                                   customText: "", settings: s, now: fixed)
    s.canvasNowPlayingSmartBg = true
    let smartOn = try ScreenRenderer.renderCanvas(modules: s.canvasModuleList, system: system,
                                                  nowPlaying: npWithArt, pomodoro: pomodoro,
                                                  customText: "", settings: s, now: fixed)
    check(smartOff.data != smartOn.data, "智能封面取色背景开关应改变渲染")
    check(smartOn.data.count <= ScreenRenderer.maximumFileSize, "智能封面取色背景渲染大小")

    // 整卡背景替换：开启后画布角落背景应为封面主色（不再局限于正在播放模块底）。
    // CGContext 填充读回有 ±0.05~0.1 色彩管理偏移，按相对色相断言（红系封面 → 红通道主导）
    let smartOnCorner = pixelAt(smartOn.image, 2, 2)
    check(smartOnCorner.0 > 0.85 && smartOnCorner.1 < 0.6 && smartOnCorner.2 < 0.6
          && smartOnCorner.0 - smartOnCorner.1 > 0.3,
          "智能背景开启后整卡背景应为封面主色（实测 \(smartOnCorner)）")
    let smartOffCorner = pixelAt(smartOff.image, 2, 2)
    check(smartOffCorner.0 < 0.3 && smartOffCorner.1 < 0.3 && smartOffCorner.2 < 0.3,
          "智能背景关闭时整卡背景应保持主题深色（实测 \(smartOffCorner)）")

    // 浅色封面：整卡背景替换为浅色主色（文字自适应深色）
    let lightCtx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    lightCtx.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.80, alpha: 1))
    lightCtx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    let lightMD = NSMutableData()
    let lightDest = CGImageDestinationCreateWithData(lightMD, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(lightDest, lightCtx.makeImage()!, nil)
    check(CGImageDestinationFinalize(lightDest), "浅色封面测试图生成")
    var npLight = np
    npLight.artwork = lightMD as Data
    let lightOn = try ScreenRenderer.renderCanvas(modules: s.canvasModuleList, system: system,
                                                  nowPlaying: npLight, pomodoro: pomodoro,
                                                  customText: "", settings: s, now: fixed)
    let lightCorner = pixelAt(lightOn.image, 2, 2)
    check(lightCorner.0 > 0.7 && lightCorner.1 > 0.7,
          "浅色封面应替换整卡背景为浅色主色（实测 \(lightCorner)）")

    // 画板「正在播放」模块字号：歌名/歌手分别调整应改变渲染
    s.canvasNowPlayingSmartBg = false
    s.canvasNowPlayingCover = false
    s.canvasNowPlayingTitleSize = 12
    s.canvasNowPlayingArtistSize = 9
    let npSizeBase = try render()
    s.canvasNowPlayingTitleSize = 18
    let npSizeTitle = try render()
    check(npSizeBase.data != npSizeTitle.data, "画板歌名字号调整应改变渲染")
    s.canvasNowPlayingTitleSize = 12
    s.canvasNowPlayingArtistSize = 15
    let npSizeArtist = try render()
    check(npSizeBase.data != npSizeArtist.data, "画板歌手字号调整应改变渲染")

    // 墨水屏画板「正在播放」：不使用智能取色背景（保持手动底色）；横向排布开关只影响所属画板
    s.oracleCanvasModules = [CanvasModule.nowPlaying.rawValue]
    s.canvasNowPlayingCover = true
    s.canvasNowPlayingSmartBg = false
    s.oracleNowPlayingHorizontal = false
    func renderOracle(_ settings: AppSettings) -> CGImage {
        ScreenRenderer.renderDeviceCanvas(modules: settings.oracleCanvasModuleList, system: system,
                                          nowPlaying: npWithArt, pomodoro: pomodoro,
                                          customText: "", settings: settings, now: fixed,
                                          width: ScreenRenderer.oracleCanvasSize,
                                          height: ScreenRenderer.oracleCanvasSize,
                                          palette: ScreenThemes.einkMono,
                                          nowPlayingHorizontal: settings.oracleNowPlayingHorizontal)
    }
    let oraVertical = renderOracle(s)
    s.oracleNowPlayingHorizontal = true
    let oraHorizontal = renderOracle(s)
    check(!bitmapEqual(oraVertical, oraHorizontal), "先知画板横向排布开关应改变其渲染")
    // 横向排布长歌名：自适应字号 + 断句换行，超长标题/作者完整渲染不崩溃
    var npLong = npWithArt
    npLong.title = "这是一首非常长的歌曲名字，用来验证横向排布的自适应字号和断句换行显示是否正常"
    npLong.artist = "很长的歌手名与专辑信息，用来验证作者信息的自适应换行"
    let oraLong = ScreenRenderer.renderDeviceCanvas(modules: s.oracleCanvasModuleList, system: system,
                                                    nowPlaying: npLong, pomodoro: pomodoro,
                                                    customText: "", settings: s, now: fixed,
                                                    width: ScreenRenderer.oracleCanvasSize,
                                                    height: ScreenRenderer.oracleCanvasSize,
                                                    palette: ScreenThemes.einkMono,
                                                    nowPlayingHorizontal: true)
    checkEqual(oraLong.width, 200, "长歌名横向排布可渲染")
    check(!bitmapEqual(oraHorizontal, oraLong), "长歌名应触发换行改变渲染")
    s.oracleNowPlayingHorizontal = false
    s.canvasNowPlayingSmartBg = true
    let oraKeyOn = renderOracle(s)
    check(bitmapEqual(oraVertical, oraKeyOn), "键盘画板智能取色开关不应影响先知画板渲染")

    // 自定义图像模块：背景 / 叠加两种模式
    s.canvasModules = [CanvasModule.image.rawValue, CanvasModule.clock.rawValue]
    s.customImagePath = path.path
    s.canvasImageMode = .background
    let bgMode = try render()
    checkEqual(bgMode.image.height, 428, "图像背景模式高度")
    check(bgMode.data.count <= ScreenRenderer.maximumFileSize, "图像背景模式大小")
    s.canvasImageMode = .overlay
    let overlayMode = try render()
    check(overlayMode.data.count <= ScreenRenderer.maximumFileSize, "图像叠加模式大小")
    check(bgMode.data != overlayMode.data, "背景/叠加两模式渲染应不同")

    // 设置往返
    let rt = AppSettings()
    rt.canvasClockFormat = "hh:mm a"
    rt.canvasDateFormat = "M/d/yy"
    rt.canvasNowPlayingCover = true
    rt.canvasNowPlayingSmartBg = true
    rt.oracleNowPlayingHorizontal = true
    rt.excerptNowPlayingHorizontal = true
    rt.nowPlayingTitleSize = 18
    rt.nowPlayingArtistSize = 14
    rt.nowPlayingFooterVisible = false
    rt.nowPlayingTimeFormat = "HH:mm:ss"
    rt.nowPlayingDateFormat = "yyyy年M月d日"
    rt.nowPlayingTimeSize = 32
    rt.nowPlayingDateSize = 24
    rt.canvasNowPlayingTitleSize = 20
    rt.canvasNowPlayingArtistSize = 16
    rt.oracleBackgroundMode = .light
    rt.canvasImageMode = .overlay
    let data = try JSONEncoder().encode(rt)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    checkEqual(decoded.canvasClockFormat, "hh:mm a", "画板时钟格式往返")
    checkEqual(decoded.canvasDateFormat, "M/d/yy", "画板日期格式往返")
    checkEqual(decoded.canvasNowPlayingCover, true, "画板大封面往返")
    checkEqual(decoded.canvasNowPlayingSmartBg, true, "画板智能取色背景往返")
    checkEqual(decoded.oracleNowPlayingHorizontal, true, "先知画板横向排布往返")
    checkEqual(decoded.excerptNowPlayingHorizontal, true, "摘录画板横向排布往返")
    checkEqual(decoded.nowPlayingTitleSize, 18, "歌名字号往返")
    checkEqual(decoded.nowPlayingArtistSize, 14, "歌手信息字号往返")
    checkEqual(decoded.nowPlayingFooterVisible, false, "底部时间日期显示开关往返")
    checkEqual(decoded.nowPlayingTimeFormat, "HH:mm:ss", "底部时间格式往返")
    checkEqual(decoded.nowPlayingDateFormat, "yyyy年M月d日", "底部日期格式往返")
    checkEqual(decoded.nowPlayingTimeSize, 32, "底部时间字号往返")
    checkEqual(decoded.nowPlayingDateSize, 24, "底部日期字号往返")
    checkEqual(decoded.canvasNowPlayingTitleSize, 20, "画板歌名字号往返")
    checkEqual(decoded.canvasNowPlayingArtistSize, 16, "画板歌手信息字号往返")
    checkEqual(decoded.oracleBackgroundMode, .light, "先知画板底色模式往返")
    checkEqual(decoded.canvasImageMode, .overlay, "画板图像模式往返")

    // 字号钳制：越界值钳制到合法范围
    let sizeClamp = AppSettings()
    sizeClamp.nowPlayingTitleSize = 99
    sizeClamp.nowPlayingArtistSize = -3
    sizeClamp.canvasNowPlayingTitleSize = 99
    sizeClamp.canvasNowPlayingArtistSize = 99
    sizeClamp.clamped()
    checkEqual(sizeClamp.nowPlayingTitleSize, 24, "歌名字号上界钳制")
    checkEqual(sizeClamp.nowPlayingArtistSize, 6, "歌手字号下界钳制")
    sizeClamp.nowPlayingTimeSize = 99
    sizeClamp.nowPlayingDateSize = 1
    sizeClamp.clamped()
    checkEqual(sizeClamp.nowPlayingTimeSize, 40, "底部时间字号上界钳制")
    checkEqual(sizeClamp.nowPlayingDateSize, 8, "底部日期字号下界钳制")
    checkEqual(sizeClamp.canvasNowPlayingTitleSize, 24, "画板歌名字号上界钳制")
    checkEqual(sizeClamp.canvasNowPlayingArtistSize, 20, "画板歌手字号上界钳制")
    print("  画板自定义通过")
}

// MARK: - 画板额度模块

func testCanvasQuotaModules() throws {
    let system = SystemSnapshot(cpuPercent: 0, memoryPercent: 0,
                                usedMemoryBytes: 0, totalMemoryBytes: 0,
                                downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
                                uptime: 0, sampledAt: Date())
    let np = NowPlayingInfo.sample
    let pomodoro = PomodoroSnapshot(phase: .focus, effectivePhase: .focus, taskName: "任务",
                                    remaining: 100, duration: 1500, completedFocusSessions: 1,
                                    endsAt: Date().addingTimeInterval(100))
    let settings = AppSettings()
    settings.canvasModules = [CanvasModule.codex.rawValue, CanvasModule.qwenQuota.rawValue]
    var usage = UsageSnapshot.sample
    usage.remainingPercent = 72
    let quota = QwenWorkQuota.sample

    let r = try ScreenRenderer.renderCanvas(modules: settings.canvasModuleList, system: system,
                                            nowPlaying: np, pomodoro: pomodoro,
                                            customText: "", settings: settings,
                                            codex: usage, qwenQuota: quota)
    checkEqual(r.image.width, 142, "画板额度模块宽度")
    checkEqual(r.image.height, 428, "画板额度模块高度")
    check(r.data.count <= ScreenRenderer.maximumFileSize, "画板额度模块大小")

    // 不同 Codex 数值渲染不同
    let r2 = try ScreenRenderer.renderCanvas(modules: settings.canvasModuleList, system: system,
                                             nowPlaying: np, pomodoro: pomodoro,
                                             customText: "", settings: settings,
                                             codex: UsageSnapshot.sample, qwenQuota: quota)
    check(r.data != r2.data, "不同 Codex 数值渲染应不同")

    // 不同千问额度渲染不同
    var quota2 = quota
    quota2.remainingCredits = 88.5
    let r3 = try ScreenRenderer.renderCanvas(modules: settings.canvasModuleList, system: system,
                                             nowPlaying: np, pomodoro: pomodoro,
                                             customText: "", settings: settings,
                                             codex: usage, qwenQuota: quota2)
    check(r.data != r3.data, "不同千问额度数值渲染应不同")

    // 十二种模块全渲染（含新额度模块）不崩溃
    settings.canvasModules = CanvasModule.allCases.map(\.rawValue)
    let all = try ScreenRenderer.renderCanvas(modules: settings.canvasModuleList, system: system,
                                              nowPlaying: np, pomodoro: pomodoro,
                                              customText: "", settings: settings,
                                              codex: usage, qwenQuota: quota)
    check(all.data.count <= ScreenRenderer.maximumFileSize, "十二种模块全渲染大小")
    print("  画板额度模块通过")
}

// MARK: - 画板模块边距（紧凑度）

func testCanvasModuleMargins() throws {
    // 边距存取与钳制
    let settings = AppSettings()
    settings.setCanvasMargin(20, for: .clock)
    checkEqual(settings.canvasMargin(for: .clock), 20, "设置边距")
    settings.setCanvasMargin(99, for: .clock)
    checkEqual(settings.canvasMargin(for: .clock), 40, "边距上界钳制 40")
    settings.setCanvasMargin(0, for: .clock)
    checkEqual(settings.canvasMargin(for: .clock), 0, "边距归零移除")

    // 加权渲染：边距不同渲染结果不同
    let system = SystemSnapshot(cpuPercent: 35, memoryPercent: 62,
                                usedMemoryBytes: 0, totalMemoryBytes: 0,
                                downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
                                uptime: 0, sampledAt: Date())
    let np = NowPlayingInfo.sample
    let pomodoro = PomodoroSnapshot(phase: .focus, effectivePhase: .focus, taskName: "任务",
                                    remaining: 100, duration: 1500, completedFocusSessions: 1,
                                    endsAt: Date().addingTimeInterval(100))
    let s = AppSettings()
    s.canvasModules = [CanvasModule.clock.rawValue, CanvasModule.cpu.rawValue, CanvasModule.memory.rawValue]
    let normal = try ScreenRenderer.renderCanvas(modules: s.canvasModuleList, system: system,
                                                 nowPlaying: np, pomodoro: pomodoro,
                                                 customText: "", settings: s)
    s.setCanvasMargin(30, for: .clock)
    let tighter = try ScreenRenderer.renderCanvas(modules: s.canvasModuleList, system: system,
                                                  nowPlaying: np, pomodoro: pomodoro,
                                                  customText: "", settings: s)
    check(normal.data != tighter.data, "边距变化应改变画板渲染")
    check(tighter.data.count <= ScreenRenderer.maximumFileSize, "紧凑渲染大小")

    // 设置往返
    let rt = AppSettings()
    rt.canvasModuleMargins = [0: 15, 2: 30]
    let data = try JSONEncoder().encode(rt)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    checkEqual(decoded.canvasModuleMargins[0], 15, "边距字典往返 clock")
    checkEqual(decoded.canvasModuleMargins[2], 30, "边距字典往返 cpu")
    print("  画板模块边距通过")
}

// MARK: - 口袋先知 / 摘录 独立画板（模块组合移植）

/// 逐像素比较两张 CGImage（重绘到统一位图后比较字节）
func bitmapEqual(_ a: CGImage, _ b: CGImage) -> Bool {
    guard a.width == b.width, a.height == b.height else { return false }
    func bytes(_ img: CGImage) -> Data? {
        let w = img.width
        let h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let p = ctx.data else { return nil }
        return Data(bytes: p, count: w * h * 4)
    }
    return bytes(a) == bytes(b)
}

/// 生成 200×200 纯色图像（用于灰阶/帧转换测试）
func makeSolidOracleImage(r: UInt8, g: UInt8, b: UInt8) -> CGImage {
    let size = 200
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                             blue: CGFloat(b) / 255, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

/// 读取图像在顶部原点坐标 (x, y) 处的 RGB（重绘到新位图后采样，避免共享缓冲区）
func pixelAt(_ img: CGImage, _ x: Int, _ y: Int) -> (Double, Double, Double) {
    let w = img.width
    let h = img.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let i = (y * w + x) * 4
    return (Double(p[i]) / 255, Double(p[i + 1]) / 255, Double(p[i + 2]) / 255)
}

/// 扫描整图是否含橙色调像素（用于验证墨水屏设备画板无品牌色文字）
func containsOrangePixel(_ img: CGImage) -> Bool {
    let w = img.width
    let h = img.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            let r = Double(p[i]) / 255, g = Double(p[i + 1]) / 255, b = Double(p[i + 2]) / 255
            if r > 0.72, g > 0.25, g < 0.58, b < 0.45 { return true }
        }
    }
    return false
}

func testCanvasOracleExcerpt() async throws {
    let fixed = Date(timeIntervalSince1970: 1_752_000_000)
    let system = SystemSnapshot(cpuPercent: 30, memoryPercent: 55,
                                usedMemoryBytes: 0, totalMemoryBytes: 0,
                                downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
                                uptime: 0, sampledAt: fixed)
    let np = NowPlayingInfo.sample
    let pomodoro = PomodoroSnapshot(phase: .focus, effectivePhase: .focus, taskName: "任务",
                                    remaining: 100, duration: 1500, completedFocusSessions: 1,
                                    endsAt: fixed.addingTimeInterval(100))

    // 模块作用域：键盘画板不含语录模块，两个独立画板各含自己的语录模块
    check(!CanvasModule.keyboardModules.contains(.oracleText), "键盘画板不应含先知语录")
    check(!CanvasModule.keyboardModules.contains(.excerptText), "键盘画板不应含摘录语录")
    check(CanvasModule.oraclePanelModules.contains(.oracleText), "口袋先知画板应含先知语录")
    check(!CanvasModule.oraclePanelModules.contains(.excerptText), "口袋先知画板不应含摘录语录")
    check(CanvasModule.excerptPanelModules.contains(.excerptText), "摘录画板应含摘录语录")
    check(!CanvasModule.excerptPanelModules.contains(.oracleText), "摘录画板不应含先知语录")

    // 模块列表设置往返：去重 + 过滤无效值
    let rt = AppSettings()
    rt.oracleCanvasModules = [CanvasModule.oracleText.rawValue, CanvasModule.cpu.rawValue, 99,
                              CanvasModule.oracleText.rawValue]
    rt.excerptCanvasModules = [CanvasModule.excerptText.rawValue, CanvasModule.clock.rawValue]
    rt.dotApiKey = "test-key"
    rt.dotDeviceId = "9C9E6E3B6E74"
    rt.rand0IP = "192.168.100.170"
    rt.oracleAutoPushEnabled = true
    rt.oracleAutoPushMinutes = 45
    rt.excerptAutoPushEnabled = true
    rt.excerptAutoPushMinutes = 90
    rt.excerptImageRotate180 = true
    rt.excerptBackgroundMode = .light
    let data = try JSONEncoder().encode(rt)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    checkEqual(decoded.oracleCanvasModuleList, [.oracleText, .cpu], "先知画板模块列表去重/过滤后往返")
    checkEqual(decoded.excerptCanvasModuleList, [.excerptText, .clock], "摘录画板模块列表往返")
    checkEqual(decoded.dotApiKey, "test-key", "Dot API Key 往返")
    checkEqual(decoded.dotDeviceId, "9C9E6E3B6E74", "Dot 设备序列号往返")
    checkEqual(decoded.rand0IP, "192.168.100.170", "Rand/0 IP 往返")
    checkEqual(decoded.oracleAutoPushEnabled, true, "先知定时推送开关往返")
    checkEqual(decoded.oracleAutoPushMinutes, 45, "先知定时推送间隔往返")
    checkEqual(decoded.excerptAutoPushEnabled, true, "摘录定时推送开关往返")
    checkEqual(decoded.excerptAutoPushMinutes, 90, "摘录定时推送间隔往返")
    checkEqual(decoded.excerptImageRotate180, true, "摘录旋转 180° 往返")
    checkEqual(decoded.excerptBackgroundMode, .light, "摘录底色模式往返")

    // 定时推送间隔钳制：1 分钟 – 24 小时
    let autoPushClamp = AppSettings()
    autoPushClamp.oracleAutoPushMinutes = 0
    autoPushClamp.excerptAutoPushMinutes = 99999
    autoPushClamp.clamped()
    checkEqual(autoPushClamp.oracleAutoPushMinutes, 1, "先知推送间隔下界钳制")
    checkEqual(autoPushClamp.excerptAutoPushMinutes, 1440, "摘录推送间隔上界钳制")

    // 口袋先知画板：200×200 黑白模块组合渲染
    let settings = AppSettings()
    settings.oracleCanvasModules = [CanvasModule.oracleText.rawValue]
    let oracleImage = ScreenRenderer.renderDeviceCanvas(
        modules: settings.oracleCanvasModuleList, system: system, nowPlaying: np,
        pomodoro: pomodoro, customText: "", settings: settings, now: fixed,
        width: ScreenRenderer.oracleCanvasSize, height: ScreenRenderer.oracleCanvasSize,
        palette: ScreenThemes.einkMono)
    checkEqual(oracleImage.width, 200, "口袋先知画板宽度")
    checkEqual(oracleImage.height, 200, "口袋先知画板高度")
    let frame = ScreenRenderer.oracleBWFrame(from: oracleImage)
    checkEqual(frame.count, 5000, "Rand/0 黑白帧应为 5000 字节")

    // 语录模块轮换：同分钟渲染一致、跨分钟变化（用黑白帧字节比较，确定性）
    let oracleSame = ScreenRenderer.renderDeviceCanvas(
        modules: settings.oracleCanvasModuleList, system: system, nowPlaying: np,
        pomodoro: pomodoro, customText: "", settings: settings,
        now: fixed.addingTimeInterval(30),
        width: ScreenRenderer.oracleCanvasSize, height: ScreenRenderer.oracleCanvasSize,
        palette: ScreenThemes.einkMono)
    check(ScreenRenderer.oracleBWFrame(from: oracleImage) ==
          ScreenRenderer.oracleBWFrame(from: oracleSame), "先知画板同分钟渲染应一致")
    let oracleNext = ScreenRenderer.renderDeviceCanvas(
        modules: settings.oracleCanvasModuleList, system: system, nowPlaying: np,
        pomodoro: pomodoro, customText: "", settings: settings,
        now: fixed.addingTimeInterval(60),
        width: ScreenRenderer.oracleCanvasSize, height: ScreenRenderer.oracleCanvasSize,
        palette: ScreenThemes.einkMono)
    check(ScreenRenderer.oracleBWFrame(from: oracleImage) !=
          ScreenRenderer.oracleBWFrame(from: oracleNext), "先知画板跨分钟应轮换")

    // 摘录画板：固定 296×152 横屏（Dot 屏幕原生分辨率 1:1）
    settings.excerptCanvasModules = [CanvasModule.excerptText.rawValue]
    let excerptImage = ScreenRenderer.renderDeviceCanvas(
        modules: settings.excerptCanvasModuleList, system: system, nowPlaying: np,
        pomodoro: pomodoro, customText: "", settings: settings, now: fixed,
        width: ScreenRenderer.excerptCanvasWidth, height: ScreenRenderer.excerptCanvasHeight,
        palette: ScreenThemes.einkLight)
    checkEqual(excerptImage.width, 296, "摘录画板宽度应为 296")
    checkEqual(excerptImage.height, 152, "摘录画板高度应为 152")
    checkEqual(ScreenRenderer.excerptCanvasWidth, 296, "摘录固定宽度常量")
    checkEqual(ScreenRenderer.excerptCanvasHeight, 152, "摘录固定高度常量")

    // 摘录画板旋转 180°：直接整体旋转改变渲染，且与真正几何旋转一致（非镜像翻转）。
    // 用非对称模块组合（时钟在上居中、网络在左对齐）验证
    settings.excerptCanvasModules = [CanvasModule.clock.rawValue, CanvasModule.network.rawValue]
    func excerptRender(_ rotate: Bool) -> CGImage {
        settings.excerptImageRotate180 = rotate
        return ScreenRenderer.renderDeviceCanvas(
            modules: settings.excerptCanvasModuleList, system: system, nowPlaying: np,
            pomodoro: pomodoro, customText: "", settings: settings, now: fixed,
            width: ScreenRenderer.excerptCanvasWidth, height: ScreenRenderer.excerptCanvasHeight,
            palette: ScreenThemes.einkLight,
            flipVertical: rotate, flipHorizontal: rotate)
    }
    func rotate180(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: CGFloat(w), y: CGFloat(h))
        ctx.rotate(by: .pi)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
    let excerptBase = excerptRender(false)
    let excerptRotated = excerptRender(true)
    settings.excerptImageRotate180 = false
    settings.excerptCanvasModules = [CanvasModule.excerptText.rawValue]
    check(!bitmapEqual(excerptBase, excerptRotated), "摘录旋转 180° 应改变渲染")
    if let rotated = rotate180(excerptBase) {
        check(bitmapEqual(rotated, excerptRotated), "摘录旋转 180° 应为整体旋转（非镜像翻转）")
    } else {
        check(false, "旋转比较图生成失败")
    }
    let excerptSame = ScreenRenderer.renderDeviceCanvas(
        modules: settings.excerptCanvasModuleList, system: system, nowPlaying: np,
        pomodoro: pomodoro, customText: "", settings: settings,
        now: fixed.addingTimeInterval(30),
        width: ScreenRenderer.excerptCanvasWidth, height: ScreenRenderer.excerptCanvasHeight,
        palette: ScreenThemes.einkLight)
    check(bitmapEqual(excerptImage, excerptSame), "摘录画板同分钟渲染应一致")

    // 混合模块组合（时钟 + CPU + 摘录语录）仍按固定尺寸渲染
    settings.excerptCanvasModules = [CanvasModule.clock.rawValue, CanvasModule.cpu.rawValue,
                                     CanvasModule.excerptText.rawValue]
    let mixed = ScreenRenderer.renderDeviceCanvas(
        modules: settings.excerptCanvasModuleList, system: system, nowPlaying: np,
        pomodoro: pomodoro, customText: "", settings: settings, now: fixed,
        width: ScreenRenderer.excerptCanvasWidth, height: ScreenRenderer.excerptCanvasHeight,
        palette: ScreenThemes.einkLight)
    checkEqual(mixed.width, 296, "混合模块摘录画板宽度")
    checkEqual(mixed.height, 152, "混合模块摘录画板高度")
    check(!bitmapEqual(mixed, excerptImage), "混合模块渲染应不同于单语录")

    // 双列布局：同模块组双列排列与单列不同；摘录语录占满整行；尺寸仍为 296×152
    let twoCol = ScreenRenderer.renderDeviceCanvas(
        modules: settings.excerptCanvasModuleList, system: system, nowPlaying: np,
        pomodoro: pomodoro, customText: "", settings: settings, now: fixed,
        width: ScreenRenderer.excerptCanvasWidth, height: ScreenRenderer.excerptCanvasHeight,
        palette: ScreenThemes.einkLight,
        columns: 2, fullWidthModules: [CanvasModule.excerptText.rawValue])
    checkEqual(twoCol.width, 296, "双列布局宽度")
    checkEqual(twoCol.height, 152, "双列布局高度")
    check(!bitmapEqual(twoCol, mixed), "双列布局渲染应不同于单列")
    let twoColNoFull = ScreenRenderer.renderDeviceCanvas(
        modules: settings.excerptCanvasModuleList, system: system, nowPlaying: np,
        pomodoro: pomodoro, customText: "", settings: settings, now: fixed,
        width: ScreenRenderer.excerptCanvasWidth, height: ScreenRenderer.excerptCanvasHeight,
        palette: ScreenThemes.einkLight,
        columns: 2, fullWidthModules: [])
    check(!bitmapEqual(twoCol, twoColNoFull), "占满整行模块应改变双列渲染")
    // 双列 + 整行模块（时钟、CPU 双列，摘录语录整行）仍可灰度化
    let twoColGray = ScreenRenderer.grayscaleCanvasImage(from: twoCol,
                                                         algorithm: .luminosity, mode: .gray4,
                                                         dither: .floydSteinberg,
                                                         width: 296, height: 152)
    checkEqual(twoColGray.width, 296, "双列灰度图宽度")
    checkEqual(twoColGray.height, 152, "双列灰度图高度")

    // 摘录画板「正在播放」跨单元（占满整行）：横向布局——封面居左、歌名/歌手居右
    let npArtCtx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    npArtCtx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1))
    npArtCtx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    let npArtMD = NSMutableData()
    let npArtDest = CGImageDestinationCreateWithData(npArtMD, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(npArtDest, npArtCtx.makeImage()!, nil)
    check(CGImageDestinationFinalize(npArtDest), "摘录横向封面测试图生成")
    var npCover = np
    npCover.artwork = npArtMD as Data
    let npSettings = AppSettings()
    npSettings.canvasNowPlayingCover = true
    npSettings.excerptCanvasModules = [CanvasModule.nowPlaying.rawValue, CanvasModule.clock.rawValue]
    let npFull = ScreenRenderer.renderDeviceCanvas(
        modules: npSettings.excerptCanvasModuleList, system: system, nowPlaying: npCover,
        pomodoro: pomodoro, customText: "", settings: npSettings, now: fixed,
        width: ScreenRenderer.excerptCanvasWidth, height: ScreenRenderer.excerptCanvasHeight,
        palette: ScreenThemes.einkLight,
        columns: 2, fullWidthModules: [CanvasModule.nowPlaying.rawValue])
    let npNarrow = ScreenRenderer.renderDeviceCanvas(
        modules: npSettings.excerptCanvasModuleList, system: system, nowPlaying: npCover,
        pomodoro: pomodoro, customText: "", settings: npSettings, now: fixed,
        width: ScreenRenderer.excerptCanvasWidth, height: ScreenRenderer.excerptCanvasHeight,
        palette: ScreenThemes.einkLight,
        columns: 2, fullWidthModules: [])
    check(!bitmapEqual(npFull, npNarrow), "跨单元应切换为横向布局")
    let narrowPix = pixelAt(npNarrow, 100, 40)
    check(narrowPix.0 > 0.7 && narrowPix.1 < 0.6 && narrowPix.2 < 0.6,
          "非跨单元时封面应居中铺在列内（实测 \(narrowPix)）")
    let fullPix = pixelAt(npFull, 100, 40)
    check(!(fullPix.0 > 0.7 && fullPix.1 < 0.6 && fullPix.2 < 0.6),
          "跨单元横向布局时该点应为文字/背景而非封面（实测 \(fullPix)）")

    // 设备画板「正在播放」封面：2px 黑色描边，浅色背景上不融合
    let strokeArtCtx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                                 bytesPerRow: 100 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    strokeArtCtx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1))
    strokeArtCtx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    let strokeArtMD = NSMutableData()
    let strokeArtDest = CGImageDestinationCreateWithData(strokeArtMD, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(strokeArtDest, strokeArtCtx.makeImage()!, nil)
    check(CGImageDestinationFinalize(strokeArtDest), "封面描边测试图生成")
    var strokeNP = np
    strokeNP.artwork = strokeArtMD as Data
    let strokeSettings = AppSettings()
    strokeSettings.canvasNowPlayingCover = true
    strokeSettings.excerptCanvasModules = [CanvasModule.nowPlaying.rawValue]
    let stroked = ScreenRenderer.renderDeviceCanvas(
        modules: strokeSettings.excerptCanvasModuleList, system: system, nowPlaying: strokeNP,
        pomodoro: pomodoro, customText: "", settings: strokeSettings, now: fixed,
        width: ScreenRenderer.excerptCanvasWidth, height: ScreenRenderer.excerptCanvasHeight,
        palette: ScreenThemes.einkLight)
    let strokeEdge = pixelAt(stroked, 104, 53)
    check(strokeEdge.0 < 0.6 && strokeEdge.1 < 0.6 && strokeEdge.2 < 0.6,
          "设备画板封面边缘应有黑色描边（实测 \(strokeEdge)）")
    let strokeCenter = pixelAt(stroked, 130, 53)
    check(strokeCenter.0 > 0.7,
          "封面中心仍为封面主色（实测 \(strokeCenter)）")

    // 摘录灰阶管线：296×152 灰度图尺寸正确、抖动算法输出不同
    let exGray = ScreenRenderer.grayscaleCanvasImage(from: mixed,
                                                     algorithm: .luminosity, mode: .gray4,
                                                     dither: .floydSteinberg,
                                                     width: 296, height: 152)
    checkEqual(exGray.width, 296, "摘录灰度图宽度")
    checkEqual(exGray.height, 152, "摘录灰度图高度")
    let exGrayNone = ScreenRenderer.grayscaleCanvasImage(from: mixed,
                                                         algorithm: .luminosity, mode: .gray4,
                                                         dither: .none,
                                                         width: 296, height: 152)
    check(!bitmapEqual(exGray, exGrayNone), "摘录灰度图抖动应不同于直接量化")
    // 黑白模式下纯白/纯黑为二值
    let exWhite = ScreenRenderer.grayscaleCanvasImage(from: makeSolidOracleImage(r: 255, g: 255, b: 255),
                                                      algorithm: .luminosity,
                                                      mode: .bw, dither: .floydSteinberg,
                                                      width: 296, height: 152)
    let exBlack = ScreenRenderer.grayscaleCanvasImage(from: makeSolidOracleImage(r: 0, g: 0, b: 0),
                                                      algorithm: .luminosity,
                                                      mode: .bw, dither: .floydSteinberg,
                                                      width: 296, height: 152)
    checkEqual(exWhite.width, 296, "摘录黑白模式纯白图宽度")
    let whiteCtx = CGContext(data: nil, width: 296, height: 152, bitsPerComponent: 8,
                             bytesPerRow: 296 * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    whiteCtx.draw(exWhite, in: CGRect(x: 0, y: 0, width: 296, height: 152))
    let whitePixels = whiteCtx.data!.bindMemory(to: UInt8.self, capacity: 296 * 152 * 4)
    var allWhite = true
    var allBlack = true
    for i in stride(from: 0, to: 296 * 152 * 4, by: 4) {
        if whitePixels[i] != 255 { allWhite = false }
    }
    let blackCtx = CGContext(data: nil, width: 296, height: 152, bitsPerComponent: 8,
                             bytesPerRow: 296 * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    blackCtx.draw(exBlack, in: CGRect(x: 0, y: 0, width: 296, height: 152))
    let blackPixels = blackCtx.data!.bindMemory(to: UInt8.self, capacity: 296 * 152 * 4)
    for i in stride(from: 0, to: 296 * 152 * 4, by: 4) {
        if blackPixels[i] != 0 { allBlack = false }
    }
    check(allWhite, "摘录黑白模式纯白图应为全白")
    check(allBlack, "摘录黑白模式纯黑图应为全黑")

    // 口袋先知显示设置往返：上下/左右反转 / 显示模式 / 灰阶算法 / 抖动算法
    let ds = AppSettings()
    ds.oracleImageRotate180 = true
    ds.oracleDisplayMode = .gray4
    ds.oracleGrayAlgorithm = .average
    ds.oracleDitherKernel = .atkinson
    ds.excerptDisplayMode = .gray4
    ds.excerptGrayAlgorithm = .average
    ds.excerptDitherKernel = .atkinson
    ds.excerptLayoutColumns = 2
    ds.excerptPushRawImage = true
    ds.excerptServerDitherType = .ordered
    ds.excerptServerDitherKernel = .atkinson
    ds.excerptFullWidthModules = [CanvasModule.excerptText.rawValue, CanvasModule.clock.rawValue, 99,
                                  CanvasModule.excerptText.rawValue]
    let dsData = try JSONEncoder().encode(ds)
    let dsDecoded = try JSONDecoder().decode(AppSettings.self, from: dsData)
    checkEqual(dsDecoded.oracleImageRotate180, true, "先知旋转 180° 往返")
    checkEqual(dsDecoded.oracleDisplayMode, OracleDisplayMode.gray4, "显示模式设置往返")
    checkEqual(dsDecoded.oracleGrayAlgorithm, OracleGrayAlgorithm.average, "灰阶算法设置往返")
    checkEqual(dsDecoded.oracleDitherKernel, OracleDitherKernel.atkinson, "抖动算法设置往返")
    checkEqual(dsDecoded.excerptDisplayMode, OracleDisplayMode.gray4, "摘录显示模式设置往返")
    checkEqual(dsDecoded.excerptGrayAlgorithm, OracleGrayAlgorithm.average, "摘录灰阶算法设置往返")
    checkEqual(dsDecoded.excerptDitherKernel, OracleDitherKernel.atkinson, "摘录抖动算法设置往返")
    checkEqual(dsDecoded.excerptLayoutColumns, 2, "摘录布局列数往返")
    checkEqual(dsDecoded.excerptPushRawImage, true, "摘录推送原始图片开关往返")
    checkEqual(dsDecoded.excerptServerDitherType, DotServerDitherType.ordered, "服务端抖动方式往返")
    checkEqual(dsDecoded.excerptServerDitherKernel, DotServerDitherKernel.atkinson, "服务端抖动核往返")
    checkEqual(DotServerDitherType.diffusion.apiValue, "DIFFUSION", "ditherType 官方值")
    checkEqual(DotServerDitherKernel.floydSteinberg.apiValue, "FLOYD_STEINBERG", "ditherKernel 官方值")
    checkEqual(DotServerDitherKernel.diffusion2D.apiValue, "DIFFUSION_2D", "ditherKernel 2D 官方值")
    // 服务端抖动算法 → 本地近似（预览对齐）
    checkEqual(ScreenRenderer.localDitherKernel(for: .diffusion, kernel: .atkinson), OracleDitherKernel.atkinson,
               "服务端 ATKINSON 映射本地")
    checkEqual(ScreenRenderer.localDitherKernel(for: .diffusion, kernel: .stucki), OracleDitherKernel.stucki,
               "服务端 STUCKI 映射本地")
    checkEqual(ScreenRenderer.localDitherKernel(for: .ordered, kernel: .floydSteinberg), OracleDitherKernel.ordered,
               "服务端 ORDERED 映射本地")
    checkEqual(ScreenRenderer.localDitherKernel(for: .none, kernel: .floydSteinberg), OracleDitherKernel.none,
               "服务端 NONE 映射本地")
    checkEqual(ScreenRenderer.localDitherKernel(for: .diffusion, kernel: .diffusion2D), OracleDitherKernel.floydSteinberg,
               "服务端 2D 扩散回退本地 FS")
    checkEqual(dsDecoded.excerptFullWidthModules, [CanvasModule.excerptText.rawValue,
                                                   CanvasModule.clock.rawValue],
               "摘录占满整行模块去重/过滤后往返")

    // 灰阶算法逐像素灰值
    checkEqual(ScreenRenderer.oracleGrayValue(255, 0, 0, algorithm: .luminosity), 76, "亮度加权-纯红")
    checkEqual(ScreenRenderer.oracleGrayValue(255, 0, 0, algorithm: .average), 85, "平均值-纯红")
    checkEqual(ScreenRenderer.oracleGrayValue(255, 0, 0, algorithm: .lightness), 127, "明度法-纯红")
    checkEqual(ScreenRenderer.oracleGrayValue(10, 200, 30, algorithm: .redChannel), 10, "红通道取红")
    checkEqual(ScreenRenderer.oracleGrayValue(10, 200, 30, algorithm: .greenChannel), 200, "绿通道取绿")
    checkEqual(ScreenRenderer.oracleGrayValue(10, 200, 30, algorithm: .blueChannel), 30, "蓝通道取蓝")
    checkEqual(ScreenRenderer.oracleGrayValue(255, 255, 255, algorithm: .luminosity), 255, "亮度加权-纯白")

    // 帧转换：黑白 5000 字节（1=白），灰阶 10000 字节（00=白 11=黑）
    let white = makeSolidOracleImage(r: 255, g: 255, b: 255)
    let black = makeSolidOracleImage(r: 0, g: 0, b: 0)
    let bwWhite = ScreenRenderer.oracleFrame(from: white, algorithm: .average, mode: .bw)
    let bwBlack = ScreenRenderer.oracleFrame(from: black, algorithm: .average, mode: .bw)
    checkEqual(bwWhite.count, 5000, "黑白帧字节数")
    checkEqual(bwWhite[0], 0xFF, "黑白帧纯白应为 0xFF")
    checkEqual(bwBlack[0], 0x00, "黑白帧纯黑应为 0x00")
    let g4White = ScreenRenderer.oracleFrame(from: white, algorithm: .average, mode: .gray4)
    let g4Black = ScreenRenderer.oracleFrame(from: black, algorithm: .average, mode: .gray4)
    checkEqual(g4White.count, 10000, "灰阶帧字节数")
    checkEqual(g4White[0], 0x00, "灰阶帧纯白应为 00（白）")
    checkEqual(g4Black[0], 0xFF, "灰阶帧纯黑应为 11（黑）")

    // 超大输入图片不会让帧/预览超出 200×200 原生分辨率（184 PPI 屏幕）
    let bigCtx = CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8,
                           bytesPerRow: 1600 * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bigCtx.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1))
    bigCtx.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
    bigCtx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    bigCtx.fill(CGRect(x: 200, y: 300, width: 800, height: 400))
    let bigImage = bigCtx.makeImage()!
    checkEqual(bigImage.width, 1600, "超大输入图像宽度")
    let bigBW = ScreenRenderer.oracleFrame(from: bigImage, algorithm: .luminosity, mode: .bw)
    let bigG4 = ScreenRenderer.oracleFrame(from: bigImage, algorithm: .luminosity, mode: .gray4)
    checkEqual(bigBW.count, 5000, "大图输入黑白帧仍为 5000 字节")
    checkEqual(bigG4.count, 10000, "大图输入灰阶帧仍为 10000 字节")
    let bigPreview = ScreenRenderer.oraclePreviewImage(from: bigImage,
                                                       algorithm: .luminosity, mode: .gray4)
    checkEqual(bigPreview.width, 200, "大图输入预览宽度仍为 200")
    checkEqual(bigPreview.height, 200, "大图输入预览高度仍为 200")

    // 官方抖动算法：渐变图下各算法输出不同且帧尺寸正确
    let gradientCtx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                                bytesPerRow: 200 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in 0..<200 {
        let v = CGFloat(x) / 199
        gradientCtx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
        gradientCtx.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: 200))
    }
    let gradient = gradientCtx.makeImage()!
    let gNone = ScreenRenderer.oracleFrame(from: gradient, algorithm: .luminosity, mode: .gray4, dither: .none)
    let gFS = ScreenRenderer.oracleFrame(from: gradient, algorithm: .luminosity, mode: .gray4, dither: .floydSteinberg)
    let gOrdered = ScreenRenderer.oracleFrame(from: gradient, algorithm: .luminosity, mode: .gray4, dither: .ordered)
    let gJJN = ScreenRenderer.oracleFrame(from: gradient, algorithm: .luminosity, mode: .gray4, dither: .jarvisJudiceNinke)
    checkEqual(gNone.count, 10000, "不抖动灰阶帧尺寸")
    checkEqual(gFS.count, 10000, "Floyd-Steinberg 灰阶帧尺寸")
    checkEqual(gOrdered.count, 10000, "有序抖动灰阶帧尺寸")
    checkEqual(gJJN.count, 10000, "Jarvis-Judice-Ninke 灰阶帧尺寸")
    check(gFS != gNone, "Floyd-Steinberg 抖动应不同于直接量化")
    check(gOrdered != gNone, "有序抖动应不同于直接量化")
    check(gJJN != gFS, "Jarvis-Judice-Ninke 与 Floyd-Steinberg 输出不同")
    // 纯白/纯黑在误差扩散下仍为全白/全黑（误差为 0，不产生杂点）
    let bwWhiteFS = ScreenRenderer.oracleFrame(from: white, algorithm: .average, mode: .bw, dither: .floydSteinberg)
    let bwBlackFS = ScreenRenderer.oracleFrame(from: black, algorithm: .average, mode: .bw, dither: .floydSteinberg)
    checkEqual(bwWhiteFS[0], 0xFF, "纯白+FS 黑白帧应为 0xFF")
    checkEqual(bwBlackFS[0], 0x00, "纯黑+FS 黑白帧应为 0x00")

    // 上下反转：翻转后帧应等于原帧行序颠倒
    settings.oracleCanvasModules = [CanvasModule.oracleText.rawValue]
    let upright = ScreenRenderer.renderDeviceCanvas(
        modules: settings.oracleCanvasModuleList, system: system, nowPlaying: np,
        pomodoro: pomodoro, customText: "", settings: settings, now: fixed,
        width: ScreenRenderer.oracleCanvasSize, height: ScreenRenderer.oracleCanvasSize,
        palette: ScreenThemes.einkMono, flipVertical: false)
    let flipped = ScreenRenderer.renderDeviceCanvas(
        modules: settings.oracleCanvasModuleList, system: system, nowPlaying: np,
        pomodoro: pomodoro, customText: "", settings: settings, now: fixed,
        width: ScreenRenderer.oracleCanvasSize, height: ScreenRenderer.oracleCanvasSize,
        palette: ScreenThemes.einkMono, flipVertical: true)
    check(!bitmapEqual(upright, flipped), "上下反转应改变画面")
    let upFrame = ScreenRenderer.oracleFrame(from: upright, algorithm: .luminosity, mode: .bw)
    let flipFrame = ScreenRenderer.oracleFrame(from: flipped, algorithm: .luminosity, mode: .bw)
    var rowReversed = Data(count: 5000)
    for row in 0..<200 {
        let src = (199 - row) * 25
        let dst = row * 25
        rowReversed[dst..<(dst + 25)] = upFrame[src..<(src + 25)]
    }
    check(flipFrame == rowReversed, "上下反转帧应为原帧行序颠倒")

    // 左右反转：帧 = 每行字节倒序 + 字节内位倒序（bit7↔bit0）
    func reverseBits(_ value: UInt8) -> UInt8 {
        var x = value
        x = (x & 0xF0) >> 4 | (x & 0x0F) << 4
        x = (x & 0xCC) >> 2 | (x & 0x33) << 2
        x = (x & 0xAA) >> 1 | (x & 0x55) << 1
        return x
    }
    let hFlippedCanvas = ScreenRenderer.renderDeviceCanvas(
        modules: settings.oracleCanvasModuleList, system: system, nowPlaying: np,
        pomodoro: pomodoro, customText: "", settings: settings, now: fixed,
        width: ScreenRenderer.oracleCanvasSize, height: ScreenRenderer.oracleCanvasSize,
        palette: ScreenThemes.einkMono, flipVertical: false, flipHorizontal: true)
    var hExpected = Data(count: 5000)
    for row in 0..<200 {
        for col in 0..<25 {
            hExpected[row * 25 + col] = reverseBits(upFrame[row * 25 + (24 - col)])
        }
    }
    let hFrame = ScreenRenderer.oracleFrame(from: hFlippedCanvas, algorithm: .luminosity, mode: .bw)
    check(hFrame == hExpected, "左右反转帧应为每行字节倒序+位倒序")

    // 上下+左右 = 旋转 180°：行倒序 + 字节倒序 + 位倒序（不会出现左右镜像）
    let rotatedCanvas = ScreenRenderer.renderDeviceCanvas(
        modules: settings.oracleCanvasModuleList, system: system, nowPlaying: np,
        pomodoro: pomodoro, customText: "", settings: settings, now: fixed,
        width: ScreenRenderer.oracleCanvasSize, height: ScreenRenderer.oracleCanvasSize,
        palette: ScreenThemes.einkMono, flipVertical: true, flipHorizontal: true)
    var rotatedExpected = Data(count: 5000)
    for row in 0..<200 {
        for col in 0..<25 {
            rotatedExpected[row * 25 + col] = reverseBits(upFrame[(199 - row) * 25 + (24 - col)])
        }
    }
    let rotatedFrame = ScreenRenderer.oracleFrame(from: rotatedCanvas, algorithm: .luminosity, mode: .bw)
    check(rotatedFrame == rotatedExpected, "上下+左右反转帧应为旋转 180°（行+字节+位全倒序）")

    // Dot 客户端：缺凭据报错（不发起真实网络请求）
    let missing = try? await DotImageAPIClient.push(pngData: Data([0x89, 0x50]),
                                                    deviceId: "", apiKey: "")
    check(missing == nil, "缺凭据应抛出错误")
    do {
        _ = try await DotImageAPIClient.push(pngData: Data([0x89, 0x50]), deviceId: "", apiKey: "")
        check(false, "缺凭据不应成功")
    } catch {
        check(true, "缺凭据抛错")
    }
    let noStatus = try? await DotImageAPIClient.fetchStatus(deviceId: "", apiKey: "")
    check(noStatus == nil, "设备状态查询缺凭据应抛出错误")

    // Dot 内容列表解码（官方示例结构：TEXT_API / IMAGE_API）
    let taskJson = """
    [{"type":"TEXT_API","key":"text_task_1","refreshNow":true,"title":"Hello","message":"World"},
     {"type":"IMAGE_API","key":"image_task_1","refreshNow":true,"border":0}]
    """
    let tasks = try JSONDecoder().decode([DotImageAPIClient.DotTaskItem].self, from: Data(taskJson.utf8))
    checkEqual(tasks.count, 2, "Dot 任务列表解码数量")
    checkEqual(tasks[0].typeLabel, "文本", "Dot 任务类型标签-文本")
    checkEqual(tasks[1].typeLabel, "图片", "Dot 任务类型标签-图片")
    checkEqual(tasks[0].key, "text_task_1", "Dot 任务 key")
    checkEqual(tasks[1].id, "image_task_1", "Dot 任务 id 用 key")

    // 内容列表 / 切换下一个：缺凭据报错（不发起真实网络请求）
    let noTasks = try? await DotImageAPIClient.listTasks(deviceId: "", apiKey: "")
    check(noTasks == nil, "任务列表查询缺凭据应抛出错误")
    let noNext = try? await DotImageAPIClient.switchNext(deviceId: "", apiKey: "")
    check(noNext == nil, "切换下一个内容缺凭据应抛出错误")

    // 自动推送「内容变化立即推送」基础：封面变化、时间变化都会改变画布帧内容
    func makeArtPNG(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Data {
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let md = NSMutableData()
        let dest = CGImageDestinationCreateWithData(md, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        _ = CGImageDestinationFinalize(dest)
        return md as Data
    }
    var npArtA = np
    npArtA.artwork = makeArtPNG(0.9, 0.2, 0.2)
    var npArtB = np
    npArtB.artwork = makeArtPNG(0.9, 0.9, 0.8)
    let changeSettings = AppSettings()
    changeSettings.oracleCanvasModules = [CanvasModule.nowPlaying.rawValue]
    changeSettings.canvasNowPlayingCover = true
    func oracleFrameFor(_ playing: NowPlayingInfo, at date: Date) -> Data {
        let img = ScreenRenderer.renderDeviceCanvas(modules: changeSettings.oracleCanvasModuleList,
                                                    system: system, nowPlaying: playing,
                                                    pomodoro: pomodoro, customText: "",
                                                    settings: changeSettings, now: date,
                                                    width: ScreenRenderer.oracleCanvasSize,
                                                    height: ScreenRenderer.oracleCanvasSize,
                                                    palette: ScreenThemes.einkMono)
        return ScreenRenderer.oracleFrame(from: img, algorithm: .luminosity, mode: .bw)
    }
    check(oracleFrameFor(npArtA, at: fixed) != oracleFrameFor(npArtB, at: fixed),
          "封面变化应改变先知画布帧内容（内容变化立即推送依据）")
    changeSettings.oracleCanvasModules = [CanvasModule.clock.rawValue]
    check(oracleFrameFor(np, at: fixed) != oracleFrameFor(np, at: fixed.addingTimeInterval(61)),
          "时间变化应改变先知画布帧内容（内容变化立即推送依据）")

    // 摘录语录键盘卡片：独立模式可渲染 142×428、每分钟轮换语录
    let quoteCard = try ScreenRenderer.renderExcerptQuote(settings: AppSettings(), now: fixed)
    checkEqual(quoteCard.image.width, 142, "摘录语录卡片宽度")
    checkEqual(quoteCard.image.height, 428, "摘录语录卡片高度")
    check(quoteCard.data.count <= ScreenRenderer.maximumFileSize, "摘录语录卡片大小")
    let quoteCardNext = try ScreenRenderer.renderExcerptQuote(settings: AppSettings(), now: fixed.addingTimeInterval(61))
    check(quoteCard.data != quoteCardNext.data, "摘录语录卡片每分钟应轮换语录")
    checkEqual(DisplayMode.excerptQuote.title, "摘录语录", "摘录语录模式标题")
    check(DisplayMode.allCases.contains(.excerptQuote), "摘录语录模式应参与卡片轮换选项")
    // 手动指定语录渲染 + 换行标点优化（不应出现单独成行的标点）
    let quoteFixed = try ScreenRenderer.renderExcerptQuote(quote: "手动指定语录", settings: AppSettings(), now: fixed)
    checkEqual(quoteFixed.image.width, 142, "手动指定语录宽度")
    checkEqual(quoteFixed.image.height, 428, "手动指定语录高度")
    let punctSet: Set<Character> = ["，", "。", "、", "；", "：", "！", "？", "”", "』", "）", "…", "—"]
    let wrapped = ScreenRenderer.wrapText("知之者不如好之者，好之者不如乐之者。", maxWidth: 55, size: 18)
    check(wrapped.count >= 2, "长语录应拆行（\(wrapped)）")
    for line in wrapped {
        let t = line.trimmingCharacters(in: .whitespaces)
        check(!(t.count == 1 && punctSet.contains(t.first ?? " ")),
              "换行不应让标点单独成行（\(wrapped)）")
    }
    // 竖向排布：列拆分规则（后置标点不置列首、无单标点列、长语录按列完整拆分）
    let vCols = ScreenRenderer.wrapVertical("知之者不如好之者，好之者不如乐之者。", maxChars: 8)
    check(vCols.count >= 2, "竖排长语录应拆成多列（\(vCols)）")
    for col in vCols {
        let t = col.trimmingCharacters(in: .whitespaces)
        check(!(t.count == 1 && punctSet.contains(t.first ?? " ")),
              "竖排不应出现单独标点列（\(vCols)）")
    }
    for col in vCols.dropFirst() {
        check(!punctSet.contains(col.first ?? " "),
              "竖排非首列不应以标点开头（\(vCols)）")
    }
    check(ScreenRenderer.wrapVertical("这是一段足以撑满一整列的语录文本。", maxChars: 5).allSatisfy { $0.count <= 5 },
          "竖排列长度不应超过 maxChars（含标点并入允许超出一字）")
    let vOpen = ScreenRenderer.wrapVertical("他说「竖排很好看」，确实如此。", maxChars: 5)
    for col in vOpen {
        let last = col.last ?? " "
        check(!["“", "「", "『", "（", "【", "《"].contains(last),
              "竖排开括号不应置于列尾（\(vOpen)）")
    }
    // 竖向布局渲染：长语录完整渲染不崩溃、尺寸正确
    let longQuote = "世界上只有一种真正的英雄主义，那就是认清生活的真相之后依然热爱生活。"
    let verticalCard = try ScreenRenderer.renderExcerptQuote(quote: longQuote, settings: AppSettings(), now: fixed)
    checkEqual(verticalCard.image.width, 142, "竖向语录卡片宽度")
    checkEqual(verticalCard.image.height, 428, "竖向语录卡片高度")
    check(verticalCard.data.count <= ScreenRenderer.maximumFileSize, "竖向语录卡片大小")

    // 摘录语录分类：枚举/标题、按分类过滤池、分类轮换、设置往返与钳制
    checkEqual(ExcerptQuoteCategory.allCases.count, 4, "语录分类数量")
    checkEqual(ExcerptQuoteCategory.famousSayings.title, "名人名言", "分类标题-名言")
    checkEqual(ExcerptQuoteCategory.movieQuotes.title, "经典电影台词", "分类标题-电影")
    checkEqual(ExcerptQuoteCategory.poetry.title, "诗词名句", "分类标题-诗词")
    checkEqual(ExcerptQuoteCategory.proverbs.title, "谚语俗语", "分类标题-谚语")
    let moviePool = ScreenRenderer.excerptQuotes(in: [ExcerptQuoteCategory.movieQuotes.rawValue])
    check(!moviePool.isEmpty, "电影分类池非空")
    check(moviePool.allSatisfy { quote in
        ScreenRenderer.excerptQuoteCategoryPool[.movieQuotes]?.contains(quote) ?? false
    }, "仅勾选电影分类时池内全部为电影台词")
    let allPool = ScreenRenderer.excerptQuotes(in: [])
    checkEqual(allPool.count, ScreenRenderer.excerptQuotes.count, "空勾选回退全部分类池")
    let allRaw = ExcerptQuoteCategory.allCases.map(\.rawValue)
    checkEqual(ScreenRenderer.excerptQuotes(in: allRaw).count, ScreenRenderer.excerptQuotes.count, "全勾选等于全部池")
    checkEqual(ScreenRenderer.excerptQuotes(in: [99]).count, ScreenRenderer.excerptQuotes.count, "非法分类回退全部池")
    let movieQuoteAtFixed = ScreenRenderer.rotatingExcerptText(fixed, categories: [ExcerptQuoteCategory.movieQuotes.rawValue])
    check(moviePool.contains(movieQuoteAtFixed), "按分类轮换的语录应来自所选分类池")
    checkEqual(ScreenRenderer.rotatingExcerptText(fixed, categories: [ExcerptQuoteCategory.movieQuotes.rawValue]),
               ScreenRenderer.rotatingExcerptText(fixed.addingTimeInterval(30), categories: [ExcerptQuoteCategory.movieQuotes.rawValue]),
               "同分钟分类轮换一致")
    let quoteCatRT = AppSettings()
    quoteCatRT.excerptQuoteCategories = [ExcerptQuoteCategory.poetry.rawValue, ExcerptQuoteCategory.proverbs.rawValue]
    let quoteCatDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(quoteCatRT))
    checkEqual(quoteCatDecoded.excerptQuoteCategories, [2, 3], "语录分类往返值")
    let quoteCatClamp = AppSettings()
    quoteCatClamp.excerptQuoteCategories = [1, 1, 2, 99, 2]
    quoteCatClamp.clamped()
    checkEqual(quoteCatClamp.excerptQuoteCategories, [1, 2], "语录分类去重/过滤无效")
    checkEqual(AppSettings().excerptQuoteCategories.count, ExcerptQuoteCategory.allCases.count, "语录分类默认全选")
    // 仅勾选部分分类时卡片仍可渲染（分类变化不影响渲染路径）
    let partialCatSettings = AppSettings()
    partialCatSettings.excerptQuoteCategories = [ExcerptQuoteCategory.movieQuotes.rawValue]
    let partialCard = try ScreenRenderer.renderExcerptQuote(quote: movieQuoteAtFixed,
                                                            settings: partialCatSettings, now: fixed)
    checkEqual(partialCard.image.width, 142, "部分分类语录卡片宽度")
    checkEqual(partialCard.image.height, 428, "部分分类语录卡片高度")
    check(partialCard.data.count <= ScreenRenderer.maximumFileSize, "部分分类语录卡片大小")

    // 少数派推荐：客户端解析（优先编辑推荐、按推荐时间倒序）+ 卡片渲染 + 模式/设置
    let sspaiJSON = """
    {"list":[
      {"id":3,"title":"未推荐文章","author":{"nickname":"作者丙"}},
      {"id":1,"title":"最新推荐","author":{"nickname":"作者甲"},"recommend_to_home_at":1752000100},
      {"id":2,"title":"较早推荐","author":"作者乙","recommend_to_home_at":1752000000}
    ],"total":3}
    """
    let sspaiParsed = try SspaiClient.parseArticles(Data(sspaiJSON.utf8))
    checkEqual(sspaiParsed.count, 2, "少数派解析应只保留编辑推荐")
    checkEqual(sspaiParsed.first?.title, "最新推荐", "少数派推荐应按推荐时间倒序")
    checkEqual(sspaiParsed.first?.author, "作者甲", "少数派作者解析")
    let sspaiFallbackJSON = """
    {"list":[{"id":3,"title":"第三篇","author":"作者C"},{"id":1,"title":"第一篇","author":"作者A"}]}
    """
    let sspaiFallback = try SspaiClient.parseArticles(Data(sspaiFallbackJSON.utf8))
    checkEqual(sspaiFallback.first?.id, 3, "无推荐时按最新文章回退")
    let sspaiCard = try ScreenRenderer.renderSspai(articles: sspaiParsed, settings: AppSettings(), now: fixed)
    checkEqual(sspaiCard.image.width, 142, "少数派卡片宽度")
    checkEqual(sspaiCard.image.height, 428, "少数派卡片高度")
    check(sspaiCard.data.count <= ScreenRenderer.maximumFileSize, "少数派卡片大小")
    checkEqual(DisplayMode.sspai.title, "少数派推荐", "少数派模式标题")
    check(DisplayMode.allCases.contains(.sspai), "少数派模式应参与卡片轮换选项")
    let sspaiRT = AppSettings()
    sspaiRT.sspaiRefreshMinutes = 45
    let sspaiDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(sspaiRT))
    checkEqual(sspaiDecoded.sspaiRefreshMinutes, 45, "少数派刷新周期往返")
    let sspaiClamp = AppSettings()
    sspaiClamp.sspaiRefreshMinutes = 999
    sspaiClamp.clamped()
    checkEqual(sspaiClamp.sspaiRefreshMinutes, 240, "少数派刷新周期上界钳制")

    // 少数派推荐画板模块：三个画板可选、设置往返/钳制、画板渲染
    checkEqual(CanvasModule.sspai.rawValue, 14, "少数派模块枚举值")
    checkEqual(CanvasModule.sspai.title, "少数派推荐", "少数派模块标题")
    check(CanvasModule.keyboardModules.contains(.sspai), "灵犀画板可选少数派模块")
    check(CanvasModule.oraclePanelModules.contains(.sspai), "口袋先知画板可选少数派模块")
    check(CanvasModule.excerptPanelModules.contains(.sspai), "摘录画板可选少数派模块")
    let canvasSspaiRT = AppSettings()
    canvasSspaiRT.canvasSspaiCount = 5
    canvasSspaiRT.oracleSspaiCount = 2
    canvasSspaiRT.excerptSspaiCount = 6
    canvasSspaiRT.canvasSspaiRandom = true
    canvasSspaiRT.oracleSspaiRandom = true
    canvasSspaiRT.excerptSspaiRandom = true
    let canvasSspaiDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(canvasSspaiRT))
    checkEqual(canvasSspaiDecoded.canvasSspaiCount, 5, "灵犀显示条数往返")
    checkEqual(canvasSspaiDecoded.oracleSspaiCount, 2, "先知显示条数往返")
    checkEqual(canvasSspaiDecoded.excerptSspaiCount, 6, "摘录显示条数往返")
    checkEqual(canvasSspaiDecoded.canvasSspaiRandom, true, "灵犀随机显示往返")
    checkEqual(canvasSspaiDecoded.oracleSspaiRandom, true, "先知随机显示往返")
    checkEqual(canvasSspaiDecoded.excerptSspaiRandom, true, "摘录随机显示往返")
    let canvasSspaiClamp = AppSettings()
    canvasSspaiClamp.canvasSspaiCount = 99
    canvasSspaiClamp.oracleSspaiCount = 0
    canvasSspaiClamp.excerptSspaiCount = -3
    canvasSspaiClamp.clamped()
    checkEqual(canvasSspaiClamp.canvasSspaiCount, 6, "灵犀显示条数上界钳制")
    checkEqual(canvasSspaiClamp.oracleSspaiCount, 1, "先知显示条数下界钳制")
    checkEqual(canvasSspaiClamp.excerptSspaiCount, 1, "摘录显示条数下界钳制")
    // 画板模块渲染：键盘画板（142×428）、先知（200×200）、摘录（296×152）含少数派模块均可渲染
    let sspaiSystem = SystemSnapshot(cpuPercent: 35, memoryPercent: 62,
                                     usedMemoryBytes: 8_000_000_000, totalMemoryBytes: 16_000_000_000,
                                     downloadBytesPerSecond: 500_000, uploadBytesPerSecond: 50_000,
                                     uptime: 86_400 + 7_200, sampledAt: Date())
    let sspaiPomodoro = PomodoroSnapshot(phase: .focus, effectivePhase: .focus, taskName: "画板",
                                         remaining: 900, duration: 1500, completedFocusSessions: 1,
                                         endsAt: Date().addingTimeInterval(900))
    let sspaiCanvasSettings = AppSettings()
    sspaiCanvasSettings.canvasModules = [CanvasModule.sspai.rawValue]
    let canvasWithSspai = try ScreenRenderer.renderCanvas(modules: [.sspai], system: sspaiSystem,
                                                          nowPlaying: .sample, pomodoro: sspaiPomodoro,
                                                          customText: "", settings: sspaiCanvasSettings,
                                                          sspaiArticles: sspaiParsed)
    checkEqual(canvasWithSspai.image.width, 142, "灵犀画板少数派模块宽度")
    checkEqual(canvasWithSspai.image.height, 428, "灵犀画板少数派模块高度")
    check(canvasWithSspai.data.count <= ScreenRenderer.maximumFileSize, "灵犀画板少数派模块大小")
    let oracleWithSspai = ScreenRenderer.renderDeviceCanvas(modules: [.sspai], system: sspaiSystem,
                                                            nowPlaying: .sample, pomodoro: sspaiPomodoro,
                                                            customText: "", settings: sspaiCanvasSettings,
                                                            sspaiArticles: sspaiParsed,
                                                            width: ScreenRenderer.oracleCanvasSize,
                                                            height: ScreenRenderer.oracleCanvasSize,
                                                            palette: ScreenThemes.resolved(theme: .deepSpace, backgroundTone: .dark, customBackgroundHex: nil, accentTone: .system, customAccentHex: nil, softwareIsDark: true))
    checkEqual(oracleWithSspai.width, 200, "先知画板少数派模块宽度")
    checkEqual(oracleWithSspai.height, 200, "先知画板少数派模块高度")
    let excerptWithSspai = ScreenRenderer.renderDeviceCanvas(modules: [.sspai], system: sspaiSystem,
                                                             nowPlaying: .sample, pomodoro: sspaiPomodoro,
                                                             customText: "", settings: sspaiCanvasSettings,
                                                             sspaiArticles: sspaiParsed,
                                                             width: ScreenRenderer.excerptCanvasWidth,
                                                             height: ScreenRenderer.excerptCanvasHeight,
                                                             palette: ScreenThemes.resolved(theme: .deepSpace, backgroundTone: .dark, customBackgroundHex: nil, accentTone: .system, customAccentHex: nil, softwareIsDark: true))
    checkEqual(excerptWithSspai.width, 296, "摘录画板少数派模块宽度")
    checkEqual(excerptWithSspai.height, 152, "摘录画板少数派模块高度")
    // 无文章时的占位提示也能渲染
    let emptySspaiCanvas = ScreenRenderer.renderDeviceCanvas(modules: [.sspai], system: sspaiSystem,
                                                             nowPlaying: .sample, pomodoro: sspaiPomodoro,
                                                             customText: "", settings: AppSettings(),
                                                             width: ScreenRenderer.excerptCanvasWidth,
                                                             height: ScreenRenderer.excerptCanvasHeight,
                                                             palette: ScreenThemes.resolved(theme: .deepSpace, backgroundTone: .dark, customBackgroundHex: nil, accentTone: .system, customAccentHex: nil, softwareIsDark: true))
    checkEqual(emptySspaiCanvas.width, 296, "无文章时摘录画板仍可渲染")

    // 墨水屏设备画板：少数派编号不允许带品牌橙色，统一为最深对比色
    let sspaiLightCanvas = ScreenRenderer.renderDeviceCanvas(modules: [.sspai], system: sspaiSystem,
                                                             nowPlaying: .sample, pomodoro: sspaiPomodoro,
                                                             customText: "", settings: sspaiCanvasSettings,
                                                             sspaiArticles: sspaiParsed,
                                                             width: ScreenRenderer.excerptCanvasWidth,
                                                             height: ScreenRenderer.excerptCanvasHeight,
                                                             palette: ScreenThemes.einkLight)
    check(!containsOrangePixel(sspaiLightCanvas), "墨水屏画板少数派编号不应带品牌橙色")

    // 长标题/长语录自适应多行：少数派卡片、画板模块、语录模块均能完整渲染不崩溃
    let longTitleArticles = [SspaiArticle(id: 101, title: "这是一条特别长的少数派推荐文章标题，用来验证自适应字号和多行显示，在小屏幕上不会截断成省略号",
                                          author: "作者甲", recommendTime: Date(timeIntervalSince1970: 1_752_000_000)),
                             SspaiArticle(id: 102, title: "第二条很长的标题，用于验证多行换行与小屏幕可读性优化",
                                          author: "作者乙", recommendTime: Date(timeIntervalSince1970: 1_752_000_001))]
    let longSspaiCard = try ScreenRenderer.renderSspai(articles: longTitleArticles, settings: AppSettings(), now: fixed)
    checkEqual(longSspaiCard.image.width, 142, "长标题少数派卡片宽度")
    check(longSspaiCard.data.count <= ScreenRenderer.maximumFileSize, "长标题少数派卡片大小")
    let longSspaiCanvas = ScreenRenderer.renderDeviceCanvas(modules: [.sspai], system: sspaiSystem,
                                                            nowPlaying: .sample, pomodoro: sspaiPomodoro,
                                                            customText: "", settings: sspaiCanvasSettings,
                                                            sspaiArticles: longTitleArticles,
                                                            width: ScreenRenderer.excerptCanvasWidth,
                                                            height: ScreenRenderer.excerptCanvasHeight,
                                                            palette: ScreenThemes.resolved(theme: .deepSpace, backgroundTone: .dark, customBackgroundHex: nil, accentTone: .system, customAccentHex: nil, softwareIsDark: true))
    checkEqual(longSspaiCanvas.width, 296, "长标题少数派画板模块可渲染")
    let longQuoteSettings = AppSettings()
    longQuoteSettings.excerptCanvasModules = [CanvasModule.excerptText.rawValue]
    let longQuoteCanvas = ScreenRenderer.renderDeviceCanvas(modules: [.excerptText], system: sspaiSystem,
                                                            nowPlaying: .sample, pomodoro: sspaiPomodoro,
                                                            customText: "", settings: longQuoteSettings,
                                                            width: ScreenRenderer.oracleCanvasSize,
                                                            height: ScreenRenderer.oracleCanvasSize,
                                                            palette: ScreenThemes.resolved(theme: .deepSpace, backgroundTone: .dark, customBackgroundHex: nil, accentTone: .system, customAccentHex: nil, softwareIsDark: true))
    checkEqual(longQuoteCanvas.width, 200, "长语录模块可渲染")
    let longQuoteKeyboard = ScreenRenderer.renderDeviceCanvas(modules: [.excerptText], system: sspaiSystem,
                                                              nowPlaying: .sample, pomodoro: sspaiPomodoro,
                                                              customText: "", settings: longQuoteSettings,
                                                              width: ScreenRenderer.excerptCanvasWidth,
                                                              height: ScreenRenderer.excerptCanvasHeight,
                                                              palette: ScreenThemes.resolved(theme: .deepSpace, backgroundTone: .dark, customBackgroundHex: nil, accentTone: .system, customAccentHex: nil, softwareIsDark: true))
    checkEqual(longQuoteKeyboard.width, 296, "摘录画板长语录模块可渲染")

    // Rand/0 显示模式按键事件解析（display mode 会把按键信号回传给当前连接的客户端）：
    // 下键/上键短按正确解析，非按键帧与非法帧忽略
    let downEvent = Rand0DisplaySession.parseKeyEvent(#"{"type":"key","key":"down","action":"short"}"#)
    checkEqual(downEvent?.key, "down", "按键事件-键名")
    checkEqual(downEvent?.action, "short", "按键事件-动作")
    let upEvent = Rand0DisplaySession.parseKeyEvent(#"{"type":"key","key":"up","action":"short"}"#)
    checkEqual(upEvent?.key, "up", "上键事件解析")
    let longEvent = Rand0DisplaySession.parseKeyEvent(#"{"type":"key","key":"down","action":"long"}"#)
    checkEqual(longEvent?.action, "long", "长按动作解析")
    check(Rand0DisplaySession.parseKeyEvent(#"{"type":"binary"}"#) == nil, "非按键帧应忽略")
    check(Rand0DisplaySession.parseKeyEvent("not json") == nil, "非法帧应忽略")
    check(Rand0DisplaySession.parseKeyEvent("") == nil, "空帧应忽略")

    // WebSocket 帧编解码（自研会话的帧层）：标准文本帧往返、服务端加掩码容错、
    // 扩展长度、保留 opcode 容错、不完整帧不消费、连续多帧解析
    let keyJSON = Data(#"{"type":"key","key":"down","action":"short"}"#.utf8)
    let textFrame = WSFraming.build(opcode: WSFraming.opcodeText, payload: keyJSON, masked: false)
    var textBuf = textFrame
    if let parsed = WSFraming.parse(from: &textBuf) {
        checkEqual(parsed.opcode, WSFraming.opcodeText, "帧解析-opcode")
        check(parsed.fin, "帧解析-FIN")
        checkEqual(parsed.payload, keyJSON, "帧解析-负载")
    } else {
        check(false, "标准文本帧应可解析")
    }
    check(textBuf.isEmpty, "标准文本帧应完整消费")

    // 服务端（设备）错误地对帧加掩码：解析应自动解除掩码
    let maskedFrame = WSFraming.build(opcode: WSFraming.opcodeText, payload: keyJSON, masked: true)
    var maskedBuf = maskedFrame
    if let parsed = WSFraming.parse(from: &maskedBuf) {
        checkEqual(parsed.payload, keyJSON, "掩码帧自动解除掩码")
    } else {
        check(false, "掩码文本帧应可解析")
    }
    // 掩码帧解除后内容应能被按键事件解析
    var freshMasked = maskedFrame
    let maskedPayload = WSFraming.parse(from: &freshMasked)!.payload
    let maskedText = String(data: maskedPayload, encoding: .utf8)
    checkEqual(Rand0DisplaySession.parseKeyEvent(maskedText ?? "")?.key, "down", "掩码帧内容可解析为按键事件")

    // 二进制帧携带按键 JSON（个别固件可能按二进制发）：按 UTF-8 解码后可解析
    let binaryFrame = WSFraming.build(opcode: WSFraming.opcodeBinary, payload: keyJSON, masked: true)
    var binaryBuf = binaryFrame
    let binaryText = String(data: WSFraming.parse(from: &binaryBuf)!.payload, encoding: .utf8)
    checkEqual(Rand0DisplaySession.parseKeyEvent(binaryText ?? "")?.action, "short", "二进制帧内的按键 JSON 可解析")

    // 扩展长度（>=126）：bw 帧 5000 字节走 2 字节扩展长度
    let bigPayload = Data(repeating: 0xAB, count: 5000)
    let bigFrame = WSFraming.build(opcode: WSFraming.opcodeBinary, payload: bigPayload, masked: true)
    checkEqual(bigFrame.count, 5000 + 2 + 2 + 4, "扩展长度帧头尺寸") // 2头+2扩展长+4掩码
    var bigBuf = bigFrame
    checkEqual(WSFraming.parse(from: &bigBuf)?.payload.count, 5000, "扩展长度帧负载")
    check(bigBuf.isEmpty, "扩展长度帧完整消费")

    // 保留 opcode（如 0x0B，设备曾发过这类非标准帧）不应破坏流同步：
    // 先解析保留 opcode 帧，再解析紧随其后的文本帧
    var mixedBuf = Data([0x8B, 0x00]) // FIN + 保留 opcode 0x0B，空负载
    mixedBuf.append(textFrame)
    if let reserved = WSFraming.parse(from: &mixedBuf) {
        checkEqual(reserved.opcode, 0x0B, "保留 opcode 帧可消费")
        check(reserved.payload.isEmpty, "保留 opcode 帧空负载")
    } else {
        check(false, "保留 opcode 帧应可消费")
    }
    checkEqual(WSFraming.parse(from: &mixedBuf)?.payload, keyJSON, "保留帧后文本帧仍同步")

    // 不完整帧：返回 nil 且不消费字节
    var partialBuf = Data(textFrame.prefix(textFrame.count - 3))
    let before = partialBuf
    check(WSFraming.parse(from: &partialBuf) == nil, "不完整帧返回 nil")
    checkEqual(partialBuf, before, "不完整帧不消费字节")

    // 口袋先知按键控制设备：枚举/说明、设置往返、键盘翻页算法
    checkEqual(Rand0ButtonTarget.allCases.count, 3, "按键控制设备选项数量")
    checkEqual(Rand0ButtonTarget.keyboard.title, "灵犀68 键盘", "按键控制-键盘标题")
    checkEqual(Rand0ButtonTarget.excerpt.title, "摘录", "按键控制-摘录标题")
    let targetRT = AppSettings()
    targetRT.rand0ButtonTarget = .keyboard
    let targetDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(targetRT))
    checkEqual(targetDecoded.rand0ButtonTarget, .keyboard, "按键控制设备设置往返")
    checkEqual(AppSettings().rand0ButtonTarget, .oracle, "按键控制设备默认口袋先知自身")
    let pageModes: [DisplayMode] = [.codex, .canvas, .sspai]
    checkEqual(ScreenRenderer.pagedMode(from: .codex, direction: 1, modes: pageModes), .canvas, "翻页下一张")
    checkEqual(ScreenRenderer.pagedMode(from: .sspai, direction: 1, modes: pageModes), .codex, "翻页循环回第一张")
    checkEqual(ScreenRenderer.pagedMode(from: .codex, direction: -1, modes: pageModes), .sspai, "翻页上一张循环")
    checkEqual(ScreenRenderer.pagedMode(from: .nowPlaying, direction: 1, modes: pageModes), .codex, "当前不在列表取第一张")
    checkEqual(ScreenRenderer.pagedMode(from: .codex, direction: 1, modes: []), .pomodoro, "空列表回退全部卡片模式")
    print("  口袋先知/摘录通过")
}

// MARK: - 卡片页面自动轮换

func testCardRotation() throws {
    // 设置往返与过滤
    let rt = AppSettings()
    rt.cardRotationEnabled = true
    rt.cardRotationMinutes = 15
    rt.cardRotationModes = [0, 2, 4, 0, 99]   // 含重复与非法值
    let data = try JSONEncoder().encode(rt)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    checkEqual(decoded.cardRotationEnabled, true, "轮换开关往返")
    checkEqual(decoded.cardRotationMinutes, 15, "轮换间隔往返")
    checkEqual(decoded.cardRotationModes, [0, 2, 4], "轮换卡片去重/过滤非法后往返")
    checkEqual(decoded.cardRotationModeList.count, 3, "轮换模式列表数量")
    checkEqual(decoded.cardRotationModeList, [.codex, .systemMonitor, .qwenWork], "轮换模式内容")

    // 间隔钳制：超界回落到 1–60
    let clamp = AppSettings()
    clamp.cardRotationMinutes = 120
    clamp.clamped()
    checkEqual(clamp.cardRotationMinutes, 60, "间隔应钳制到 60 分钟")
    clamp.cardRotationMinutes = 0
    clamp.clamped()
    checkEqual(clamp.cardRotationMinutes, 1, "间隔应钳制到 1 分钟")

    // 移除某卡片后不进入轮换列表
    var modes = DisplayMode.allCases.map(\.rawValue)
    modes.removeAll { $0 == DisplayMode.customImage.rawValue }
    let s2 = AppSettings()
    s2.cardRotationModes = modes
    check(!s2.cardRotationModeList.contains(.customImage), "移除的卡片不应进入轮换")
    checkEqual(s2.cardRotationModeList.count, DisplayMode.allCases.count - 1, "移除后数量减一")
    print("  卡片轮换通过")
}

// MARK: - Emoji 壁纸

func testEmojiWallpaper() throws {
    let fixed = Date(timeIntervalSince1970: 1_752_000_000)
    // 模式/枚举
    checkEqual(DisplayMode.emojiWallpaper.rawValue, 9, "Emoji 壁纸模式枚举值")
    checkEqual(DisplayMode.emojiWallpaper.title, "Emoji 壁纸", "Emoji 壁纸模式标题")
    check(DisplayMode.allCases.contains(.emojiWallpaper), "Emoji 壁纸应参与卡片轮换选项")
    checkEqual(EmojiWallpaperLayout.allCases.count, 3, "Emoji 壁纸排列方式数量")
    checkEqual(EmojiWallpaperLayout.mixedSize.title, "大小混合", "排列方式标题-大小混合")
    checkEqual(EmojiWallpaperLayout.grid.title, "网格排列", "排列方式标题-网格")
    checkEqual(EmojiWallpaperLayout.spiral.title, "螺旋", "排列方式标题-螺旋")

    // 渲染：三种排列方式各渲染一张 142×428
    var renders: [Data] = []
    for layout in EmojiWallpaperLayout.allCases {
        let s = AppSettings()
        s.emojiWallpaperLayout = layout
        s.emojiWallpaperSize = 48
        s.emojiWallpaperSpacing = 8
        s.nowPlayingFooterVisible = false
        let r = try ScreenRenderer.renderEmojiWallpaper(settings: s, now: fixed)
        checkEqual(r.image.width, 142, "Emoji 壁纸宽度（\(layout.title)）")
        checkEqual(r.image.height, 428, "Emoji 壁纸高度（\(layout.title)）")
        check(r.data.count <= ScreenRenderer.maximumFileSize, "Emoji 壁纸大小（\(layout.title)）")
        renders.append(r.data)
    }
    // 三种排列彼此不同
    check(renders[0] != renders[1], "大小混合与网格排列应不同")
    check(renders[1] != renders[2], "网格排列与螺旋应不同")
    check(renders[0] != renders[2], "大小混合与螺旋应不同")

    // 确定性：同一设置多次渲染结果一致（避免每次渲染都触发推送）
    let s1 = AppSettings(); s1.emojiWallpaperLayout = .grid; s1.emojiWallpaperSize = 40
    s1.emojiWallpaperSpacing = 8; s1.nowPlayingFooterVisible = false
    let d1 = try ScreenRenderer.renderEmojiWallpaper(settings: s1, now: fixed).data
    let d2 = try ScreenRenderer.renderEmojiWallpaper(settings: s1, now: fixed.addingTimeInterval(3600)).data
    check(d1 == d2, "同一设置渲染应确定性一致（不随时间变化）")

    // 字号改变布局
    let sBig = AppSettings(); sBig.emojiWallpaperLayout = .grid; sBig.emojiWallpaperSize = 80
    sBig.emojiWallpaperSpacing = 8; sBig.nowPlayingFooterVisible = false
    let dBig = try ScreenRenderer.renderEmojiWallpaper(settings: sBig, now: fixed).data
    check(d1 != dBig, "字号变化应改变壁纸")

    // 间隔改变布局（间隔可调的核心验证）
    let sGap = AppSettings(); sGap.emojiWallpaperLayout = .grid; sGap.emojiWallpaperSize = 40
    sGap.emojiWallpaperSpacing = 24; sGap.nowPlayingFooterVisible = false
    let dGap = try ScreenRenderer.renderEmojiWallpaper(settings: sGap, now: fixed).data
    check(d1 != dGap, "间隔变化应改变壁纸")

    // 表情串改变布局
    let sText = AppSettings(); sText.emojiWallpaperLayout = .grid; sText.emojiWallpaperSize = 40
    sText.emojiWallpaperSpacing = 8; sText.nowPlayingFooterVisible = false
    sText.emojiWallpaperText = "🐱🐶"
    let dText = try ScreenRenderer.renderEmojiWallpaper(settings: sText, now: fixed).data
    check(d1 != dText, "表情串变化应改变壁纸")

    // 空表情串：占位提示也能渲染
    let sEmpty = AppSettings(); sEmpty.emojiWallpaperText = ""; sEmpty.nowPlayingFooterVisible = false
    let emptyRender = try ScreenRenderer.renderEmojiWallpaper(settings: sEmpty, now: fixed)
    checkEqual(emptyRender.image.width, 142, "空表情串壁纸宽度")

    // 页脚时钟开关
    let sFooter = AppSettings(); sFooter.emojiWallpaperLayout = .grid; sFooter.nowPlayingFooterVisible = true
    let withFooter = try ScreenRenderer.renderEmojiWallpaper(settings: sFooter, now: fixed).data
    sFooter.nowPlayingFooterVisible = false
    let noFooter = try ScreenRenderer.renderEmojiWallpaper(settings: sFooter, now: fixed).data
    check(withFooter != noFooter, "页脚时钟开关应改变壁纸")

    // 设置往返与钳制
    let rt = AppSettings()
    rt.emojiWallpaperText = "🌸🦋"
    rt.emojiWallpaperSize = 64
    rt.emojiWallpaperLayout = .spiral
    rt.emojiWallpaperSpacing = 16
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(rt))
    checkEqual(decoded.emojiWallpaperText, "🌸🦋", "表情串往返")
    checkEqual(decoded.emojiWallpaperSize, 64, "壁纸字号往返")
    checkEqual(decoded.emojiWallpaperLayout, .spiral, "壁纸排列往返")
    checkEqual(decoded.emojiWallpaperSpacing, 16, "壁纸间隔往返")
    let clamp = AppSettings()
    clamp.emojiWallpaperSize = 200
    clamp.emojiWallpaperSpacing = 999
    clamp.clamped()
    checkEqual(clamp.emojiWallpaperSize, 96, "壁纸字号上界钳制")
    checkEqual(clamp.emojiWallpaperSpacing, 40, "壁纸间隔上界钳制")
    clamp.emojiWallpaperSize = 4
    clamp.emojiWallpaperSpacing = -5
    clamp.clamped()
    checkEqual(clamp.emojiWallpaperSize, 16, "壁纸字号下界钳制")
    checkEqual(clamp.emojiWallpaperSpacing, 0, "壁纸间隔下界钳制")
    print("  Emoji 壁纸通过")
}

// MARK: - 设备管理

func testDeviceManagement() throws {
    // 设备类型
    checkEqual(DeviceType.allCases.count, 3, "设备类型数量")
    checkEqual(DeviceType.keyboard.title, "灵犀68 键盘", "设备类型标题-键盘")
    checkEqual(DeviceType.oracle.title, "口袋先知", "设备类型标题-先知")
    checkEqual(DeviceType.excerpt.title, "摘录", "设备类型标题-摘录")

    // 设置快照 捕获→套用 往返
    let source = AppSettings()
    source.canvasModules = [1, 5, 14]
    source.canvasText = "测试画板"
    source.safeAreaHeight = 60
    source.jpegQuality = 95
    source.cardRotationEnabled = true
    source.cardRotationMinutes = 10
    source.cardRotationModes = [0, 6]
    source.clockFontWeight = .medium
    source.emojiWallpaperLayout = .spiral
    source.oracleCanvasModules = [12, 2]
    source.oracleImageRotate180 = true
    source.rand0ButtonTarget = .keyboard
    let targetDeviceUUID = UUID()
    source.rand0ButtonTargetDeviceID = targetDeviceUUID
    source.excerptCanvasModules = [13, 0]
    source.excerptPushRawImage = true
    let captured = DeviceSettings.capture(from: source, type: .keyboard)
    checkEqual(captured.canvasModules, [1, 5, 14], "键盘快照-模块")
    checkEqual(captured.canvasText, "测试画板", "键盘快照-文字")
    checkEqual(captured.safeAreaHeight, 60, "键盘快照-安全区")
    checkEqual(captured.jpegQuality, 95, "键盘快照-推送质量")
    checkEqual(captured.cardRotationMinutes, 10, "键盘快照-轮换间隔")
    checkEqual(captured.cardRotationModes, [0, 6], "键盘快照-轮换池")
    checkEqual(captured.clockFontWeight, .medium, "键盘快照-时钟字重")
    checkEqual(captured.emojiWallpaperLayout, .spiral, "键盘快照-Emoji壁纸布局")
    let target = AppSettings()
    captured.apply(to: target, type: .keyboard)
    checkEqual(target.canvasModules, [1, 5, 14], "键盘套用-模块")
    checkEqual(target.canvasText, "测试画板", "键盘套用-文字")
    checkEqual(target.safeAreaHeight, 60, "键盘套用-安全区")
    checkEqual(target.cardRotationEnabled, true, "键盘套用-轮换开关")
    checkEqual(target.clockFontWeight, .medium, "键盘套用-时钟字重")
    checkEqual(target.emojiWallpaperLayout, .spiral, "键盘套用-Emoji壁纸布局")
    let oraCap = DeviceSettings.capture(from: source, type: .oracle)
    checkEqual(oraCap.oracleCanvasModules, [12, 2], "先知快照-模块")
    checkEqual(oraCap.rand0ButtonTarget, .keyboard, "先知快照-按键控制")
    checkEqual(oraCap.rand0ButtonTargetDeviceID, targetDeviceUUID, "先知快照-按键控制设备ID")
    let oraTarget = AppSettings()
    oraCap.apply(to: oraTarget, type: .oracle)
    checkEqual(oraTarget.oracleCanvasModules, [12, 2], "先知套用-模块")
    checkEqual(oraTarget.rand0ButtonTarget, .keyboard, "先知套用-按键控制")
    checkEqual(oraTarget.rand0ButtonTargetDeviceID, targetDeviceUUID, "先知套用-按键控制设备ID")

    // 口袋先知多画板：捕获当前配置为画板、套用画板恢复字段、设备快照/编码往返、钳制
    let boardA = OracleCanvasBoard.capture(from: source)
    checkEqual(boardA.modules, [12, 2], "画板捕获-模块")
    checkEqual(boardA.name, "画板 1", "画板捕获-默认名")
    var boardB = boardA
    boardB.name = "我的画板"
    boardB.modules = [10, 5]
    boardB.displayMode = .gray4
    let applied = AppSettings()
    boardB.apply(to: applied)
    checkEqual(applied.oracleCanvasModules, [10, 5], "画板套用-模块")
    checkEqual(applied.oracleDisplayMode, .gray4, "画板套用-显示模式")
    // 设备快照捕获/套用包含画板列表与下标
    source.oracleCanvasBoards = [boardA, boardB]
    source.oracleCanvasBoardIndex = 1
    let oraCap2 = DeviceSettings.capture(from: source, type: .oracle)
    checkEqual(oraCap2.oracleCanvasBoards?.count, 2, "设备快照-画板数量")
    checkEqual(oraCap2.oracleCanvasBoardIndex, 1, "设备快照-画板下标")
    let oraTarget2 = AppSettings()
    oraCap2.apply(to: oraTarget2, type: .oracle)
    checkEqual(oraTarget2.oracleCanvasBoards.count, 2, "设备套用-画板数量")
    checkEqual(oraTarget2.oracleCanvasBoardIndex, 1, "设备套用-画板下标")
    checkEqual(oraTarget2.oracleCanvasBoards[1].modules, [10, 5], "设备套用-画板内容")
    // 编码往返
    let boardRT = AppSettings()
    boardRT.oracleCanvasBoards = [boardB]
    boardRT.oracleCanvasBoardIndex = 0
    let boardDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(boardRT))
    checkEqual(boardDecoded.oracleCanvasBoards.count, 1, "画板编码往返")
    checkEqual(boardDecoded.oracleCanvasBoards[0].name, "我的画板", "画板编码往返-名称")
    checkEqual(boardDecoded.oracleCanvasBoardIndex, 0, "画板下标往返")
    // 钳制：越界下标回退，无效模块被清理
    let clamp = AppSettings()
    clamp.oracleCanvasBoards = [boardA]
    clamp.oracleCanvasBoardIndex = 99
    clamp.oracleCanvasBoards[0].modules = [12, 999, 2]
    clamp.clamped()
    checkEqual(clamp.oracleCanvasBoardIndex, 0, "画板下标钳制")
    checkEqual(clamp.oracleCanvasBoards[0].modules, [12, 2], "画板模块清理无效值")
    let clampEmpty = AppSettings()
    clampEmpty.oracleCanvasBoards = []
    clampEmpty.oracleCanvasBoardIndex = 5
    clampEmpty.clamped()
    checkEqual(clampEmpty.oracleCanvasBoardIndex, 0, "空画板列表下标归零")
    let exCap = DeviceSettings.capture(from: source, type: .excerpt)
    checkEqual(exCap.excerptCanvasModules, [13, 0], "摘录快照-模块")
    checkEqual(exCap.excerptPushRawImage, true, "摘录快照-原始推送")
    let exTarget = AppSettings()
    exCap.apply(to: exTarget, type: .excerpt)
    checkEqual(exTarget.excerptCanvasModules, [13, 0], "摘录套用-模块")
    checkEqual(exTarget.excerptPushRawImage, true, "摘录套用-原始推送")

    // ManagedDevice 编码往返
    let device = ManagedDevice(type: .excerpt, name: "书房摘录",
                               settings: DeviceSettings.capture(from: source, type: .excerpt))
    let data = try JSONEncoder().encode(device)
    let decoded = try JSONDecoder().decode(ManagedDevice.self, from: data)
    checkEqual(decoded.name, "书房摘录", "设备名往返")
    checkEqual(decoded.type, .excerpt, "设备类型往返")
    checkEqual(decoded.settings.excerptCanvasModules, [13, 0], "设备设置往返")
    checkEqual(ManagedDevice.defaultName(for: .keyboard, index: 0), "灵犀68 键盘 1", "默认设备名")
    // 启用开关：往返保留；旧档案缺键回退为启用
    var disabledDevice = device
    disabledDevice.isEnabled = false
    let disabledRT = try JSONDecoder().decode(ManagedDevice.self, from: JSONEncoder().encode(disabledDevice))
    checkEqual(disabledRT.isEnabled, false, "设备启用开关往返")
    checkEqual(decoded.isEnabled, true, "设备默认启用")
    let legacyJSON = try JSONEncoder().encode(device)
    let legacyObject = try JSONSerialization.jsonObject(with: legacyJSON) as? [String: Any] ?? [:]
    var legacyDict = legacyObject
    legacyDict.removeValue(forKey: "isEnabled")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyDict)
    let legacyDecoded = try JSONDecoder().decode(ManagedDevice.self, from: legacyData)
    checkEqual(legacyDecoded.isEnabled, true, "旧档案缺 isEnabled 键回退启用")

    // 首次使用不自动创建设备：空列表由界面引导到设备管理添加；添加设备后才产生设备档案
    let fresh = AppSettings()
    check(fresh.devices.isEmpty, "首次使用不应自动创建设备")
    // 删除设备允许删光（不再强制每类至少一台）
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("linx-device-test-\(UUID().uuidString)")
    var emptyTest = AppSettings()
    let tmpDevice = ManagedDevice(type: .keyboard, name: "临时",
                                  settings: DeviceSettings.capture(from: fresh, type: .keyboard))
    emptyTest.devices = [tmpDevice]
    let store2 = SettingsStore(dataDirectory: base)
    store2.save(emptyTest)
    let reloaded = store2.load()
    checkEqual(reloaded.devices.count, 1, "设备档案往返")
    checkEqual(reloaded.devices[0].name, "临时", "设备名往返-删除测试")
    checkEqual(fresh.devices.isEmpty, true, "全新设置无设备")
    print("  设备管理通过")
}

// MARK: - 侧边栏设置

func testSidebarSettings() throws {
    let rt = AppSettings()
    rt.sidebarWidth = 240
    let data = try JSONEncoder().encode(rt)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    checkEqual(decoded.sidebarWidth, 240, "侧边栏宽度往返")
    let clamp = AppSettings()
    clamp.sidebarWidth = 999
    clamp.clamped()
    checkEqual(clamp.sidebarWidth, 280, "侧边栏宽度上界钳制")
    clamp.sidebarWidth = 50
    clamp.clamped()
    checkEqual(clamp.sidebarWidth, 140, "侧边栏宽度下界钳制")
    // 键盘设备可见卡片列表（卡片管理）：编码往返 + 缺键回退 nil + 设备快照捕获套用
    let hiddenRT = AppSettings()
    hiddenRT.keyboardCardPanels = ["codex", "pomodoro"]
    let hiddenDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(hiddenRT))
    checkEqual(hiddenDecoded.keyboardCardPanels, ["codex", "pomodoro"], "卡片列表往返")
    check(AppSettings().keyboardCardPanels == nil, "卡片列表默认未配置")
    // 菜单栏目标键盘：编码往返 + 缺键回退 nil
    let menuRT = AppSettings()
    menuRT.menuBarKeyboardDeviceID = UUID()
    let menuDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(menuRT))
    check(menuDecoded.menuBarKeyboardDeviceID != nil, "菜单栏目标键盘往返")
    check(AppSettings().menuBarKeyboardDeviceID == nil, "菜单栏目标键盘默认跟随活动")
    let kbdCap = DeviceSettings.capture(from: hiddenRT, type: .keyboard)
    checkEqual(kbdCap.keyboardCardPanels, ["codex", "pomodoro"], "卡片列表设备快照")
    let kbdTarget = AppSettings()
    kbdCap.apply(to: kbdTarget, type: .keyboard)
    checkEqual(kbdTarget.keyboardCardPanels, ["codex", "pomodoro"], "卡片列表设备套用")
    print("  侧边栏设置通过")
}

// MARK: - 用量数据统一调取（Codex 用量 + 千问办公额度一次并行拉取）

func testUsageDataAggregator() async {
    let codexSnap = UsageSnapshot(remainingPercent: 80, resetDate: nil, windowMinutes: 1440,
                                  availableResetCount: 2, planType: "plus")
    let quotaSnap = QwenWorkQuota(available: true, remainingCredits: 100, usedCredits: 50,
                                  totalCredits: 150, percentageUsed: 33.3, unit: "credits",
                                  plan: "Free", segments: [], sampledAt: Date())

    // 两源成功：一次调用同时取回两个数据源，各只调一次
    var codexCalls = 0
    var quotaCalls = 0
    let agg = UsageDataAggregator(
        fetchCodex: { _ in codexCalls += 1; return codexSnap },
        fetchQuota: { quotaCalls += 1; return quotaSnap })
    let r = await agg.fetch(codexCliPath: nil)
    checkEqual(codexCalls, 1, "统一调取时 Codex 只调用一次")
    checkEqual(quotaCalls, 1, "统一调取时千问额度只调用一次")
    check(r.usage == codexSnap && r.quota == quotaSnap, "统一调取应同时返回两个数据源")
    check(r.failures.isEmpty, "两源成功无失败记录")

    // 单源失败不影响另一源（失败字段为 nil，保留旧缓存）
    let aggPartial = UsageDataAggregator(
        fetchCodex: { _ in throw CodexError.notFound },
        fetchQuota: { quotaSnap })
    let rp = await aggPartial.fetch(codexCliPath: nil)
    check(rp.usage == nil && rp.quota == quotaSnap, "Codex 失败不应影响千问取回")
    checkEqual(rp.failures.count, 1, "单源失败只记录一条")

    // 两源全挂：各自记录失败，无新数据
    let aggBoth = UsageDataAggregator(
        fetchCodex: { _ in throw CodexError.notFound },
        fetchQuota: { throw QuotaError.unreachable })
    let rb = await aggBoth.fetch(codexCliPath: nil)
    check(rb.usage == nil && rb.quota == nil, "两源全挂时无新数据")
    checkEqual(rb.failures.count, 2, "两源全挂各记录一条失败")
    print("  用量统一调取通过")
}

// MARK: - 主入口

if CommandLine.arguments.contains("--previews") {
    if let index = CommandLine.arguments.firstIndex(of: "--previews"),
       CommandLine.arguments.indices.contains(index + 1) {
        try? exportPreviews(to: CommandLine.arguments[index + 1])
        exit(0)
    }
}

Task {
    do {
        testThemes()
        try testRenderAllModesAndThemes()
        try testRenderCustomImage()
        testPomodoro()
        try testCodexParse()
        testSyncPlanner()
        testSystemMonitor()
        testSettingsAndUtilities()
        try testMigration()
        try testQuotaParse()
        await testQuotaLiveFetch()
        testEndpointBuilder()
        testAppearanceColors()
        try testResolvedPalette()
        try testSystemToggleLayouts()
        try testArtworkColorExtraction()
        try testImageCropper()
        try testCropRenderPipeline()
        try testImageHistory()
        try testNetworkChart()
        try testSidebarOrdering()
        try testRotationInterval()
        try testClockOverlay()
        try testSafeAreaCardGeometry()
        try testSystemLoadIndicator()
        try testCanvas()
        try testCanvasCustomization()
        try testCanvasQuotaModules()
        try testCanvasModuleMargins()
        try await testCanvasOracleExcerpt()
        try testCardRotation()
        try testEmojiWallpaper()
        try testDeviceManagement()
        try testPraiseAndTaskFont()
        try testSidebarSettings()
        await testUsageDataAggregator()
        try testNowPlaying()
        await testNowPlayingLiveFetch()
    } catch {
        failures.append("测试执行抛出异常：\(error)")
    }

    print("")
    if failures.isEmpty {
        print("✅ 全部通过（\(passed) 项断言）")
        exit(0)
    } else {
        print("❌ 共 \(failures.count) 项失败：")
        for failure in failures {
            print("   - \(failure)")
        }
        exit(1)
    }
}
dispatchMain()
