// LinxDisplay 冒烟测试（不依赖 XCTest，任何带 Swift 工具链的环境均可运行）
// 覆盖：四套主题 × 三种卡片的 JPEG 渲染、自定义图片裁剪、番茄钟状态机、
//       Codex 用量解析、自动同步规划、系统监控采样、设置往返。
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import LinxDisplayCore

// 仅测试和视觉预览使用的样本数据。放在测试目标中，确保正式 App 二进制不携带示例账号数据。
extension UsageSnapshot {
    static var sample: UsageSnapshot {
        UsageSnapshot(
            remainingPercent: 98,
            resetDate: Date().addingTimeInterval(5 * 24 * 3600),
            windowMinutes: 10_080,
            availableResetCount: 3,
            planType: "plus")
    }
}

extension QwenWorkQuota {
    static var sample: QwenWorkQuota {
        QwenWorkQuota(
            available: true, remainingCredits: 2061.9, usedCredits: 0, totalCredits: 0,
            percentageUsed: 0, unit: "credits", plan: "Free",
            segments: [Segment(id: "plan", remaining: 2061.9, unit: "credits")],
            sampledAt: Date())
    }
}

extension NowPlayingInfo {
    static var sample: NowPlayingInfo {
        NowPlayingInfo(
            title: "示例歌曲", artist: "示例歌手", album: "示例专辑",
            duration: 210, elapsedTime: 63, playbackRate: 1,
            artwork: nil, sampledAt: Date())
    }
}

var failures: [String] = []
var passed = 0

private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func set() {
        lock.lock(); storage = true; lock.unlock()
    }

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

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

    // 自定义图片忽略全局顶部安全区：图片铺满全屏，顶部（原安全区位置）也应显示图片色而非黑色
    let safeSettings = AppSettings()
    safeSettings.safeAreaHeight = 56
    let fillResult = try ScreenRenderer.renderCustomImage(path: tempURL.path, settings: safeSettings)
    let fillImg = fillResult.image
    let fillData = fillImg.dataProvider!.data! as Data
    let fbpr = fillImg.bytesPerRow
    let topLum = 0.299 * Double(fillData[10 * fbpr + 71 * 4])
        + 0.587 * Double(fillData[10 * fbpr + 71 * 4 + 1])
        + 0.114 * Double(fillData[10 * fbpr + 71 * 4 + 2])
    check(topLum > 40, "自定义图片应铺满顶部、忽略安全区（顶部亮度 \(topLum)）")
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
    checkEqual(SystemMonitor.monotonicCounterDelta(current: 150, previous: 100), 50,
               "网络累计计数正常递增时返回差值")
    checkEqual(SystemMonitor.monotonicCounterDelta(current: 20, previous: 100), 0,
               "网络接口重建导致计数回退时不发生 UInt64 下溢")
    checkEqual(SystemMonitor.monotonicCounterDelta(current: 0, previous: UInt64.max), 0,
               "网络累计计数极端回退时仍安全归零")
    let monitor = SystemMonitor()
    _ = monitor.sample()
    Thread.sleep(forTimeInterval: 0.2)
    let snapshot = monitor.sample()
    check(snapshot.totalMemoryBytes > 0, "内存总量应大于 0")
    check(snapshot.memoryPercent >= 0 && snapshot.memoryPercent <= 100, "内存占用应在 0-100%")
    check(snapshot.totalDiskBytes > 0, "磁盘总量应大于 0")
    check(snapshot.diskPercent >= 0 && snapshot.diskPercent <= 100, "磁盘占用应在 0-100%")
    check(snapshot.uptime > 0, "运行时间应大于 0")
    print("  系统监控采样通过（CPU \(Int(snapshot.cpuPercent.rounded()))% / 内存 \(Int(snapshot.memoryPercent.rounded()))% / 磁盘 \(Int(snapshot.diskPercent.rounded()))%）")
}

/// 口袋先知会话在目标/显示模式切换时必须让旧重连循环退出，
/// 否则新 connect 会永久排在旧 socketQueue 后面，并在应用层诱发不断新建会话。
func testRand0SessionLifecycle() async {
    let session = Rand0DisplaySession()
    // 本机 1 端口会立即拒绝，首次 connect 返回后内部仍处于退避重连。
    await session.connect(ip: "127.0.0.1:1", endpoint: .bw)
    check(session.isActive, "Rand/0 首次失败后保持单个自动重连循环")

    let switched = ThreadSafeFlag()
    let switchTask = Task {
        await session.connect(ip: "127.0.0.1:1", endpoint: .gray4)
        switched.set()
    }
    try? await Task.sleep(nanoseconds: 750_000_000)
    check(switched.value, "Rand/0 目标切换应在退避期及时淘汰旧循环")

    session.disconnect()
    await switchTask.value
    check(!session.isActive, "Rand/0 disconnect 后不再保留重连循环")
    print("  Rand/0 会话生命周期通过")
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
                                space: CGColorSpace(name: CGColorSpace.sRGB)
                                    ?? CGColorSpaceCreateDeviceRGB(),
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

    // Bambu 大字布局：状态背景字 + 前景百分比 + 摄像头/任务图片区块。
    let bambuPreviewSettings = AppSettings()
    bambuPreviewSettings.cardTheme = .deepSpace
    let bambuPreviewConfig = BambuLabCardSettings(
        name: "X2D", statusEntityID: "sensor.x2d_status",
        progressEntityID: "sensor.x2d_progress", taskEntityID: "sensor.x2d_task",
        nozzleTempEntityID: "sensor.x2d_nozzle", bedTempEntityID: "sensor.x2d_bed",
        remainingEntityID: "sensor.x2d_remaining", imageEntityID: "camera.x2d",
        taskImageEntityID: "image.x2d_cover", layout: .large)
    let bambuPreviewEntities = [
        HAEntity(entityId: "sensor.x2d_status", friendlyName: "X2D 状态", state: "printing", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.x2d_progress", friendlyName: "X2D 进度", state: "50", unitOfMeasurement: "%"),
        HAEntity(entityId: "sensor.x2d_task", friendlyName: "X2D 任务", state: "Luna 头饰", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.x2d_nozzle", friendlyName: "X2D 喷嘴", state: "220", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.x2d_bed", friendlyName: "X2D 热床", state: "55", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.x2d_remaining", friendlyName: "X2D 剩余", state: "42", unitOfMeasurement: "min")
    ]
    let bambuPreview = try ScreenRenderer.renderBambuLab(
        bambuPreviewConfig, entities: bambuPreviewEntities, image: artData as Data,
        settings: bambuPreviewSettings, dataUpdatedAt: Date())
    let bambuCtx = CGContext(data: nil, width: Int(142 * scale), height: Int(428 * scale),
                             bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bambuCtx.interpolationQuality = .high
    bambuCtx.draw(bambuPreview.image, in: CGRect(x: 0, y: 0, width: 142 * scale, height: 428 * scale))
    let bambuURL = outURL.appendingPathComponent("Bambu-大字布局.png")
    let bambuDest = CGImageDestinationCreateWithURL(
        bambuURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(bambuDest, bambuCtx.makeImage()!, nil)
    _ = CGImageDestinationFinalize(bambuDest)
    print("已导出 \(bambuURL.path)")

    let bambuLightSettings = AppSettings()
    bambuLightSettings.cardTheme = .minimalLight
    bambuLightSettings.backgroundTone = .light
    bambuLightSettings.softwareIsDark = false
    let bambuLightPreview = try ScreenRenderer.renderBambuLab(
        bambuPreviewConfig, entities: bambuPreviewEntities, image: artData as Data,
        settings: bambuLightSettings, dataUpdatedAt: Date())
    let bambuLightCtx = CGContext(data: nil, width: Int(142 * scale), height: Int(428 * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bambuLightCtx.interpolationQuality = .none
    bambuLightCtx.draw(bambuLightPreview.image,
                       in: CGRect(x: 0, y: 0, width: 142 * scale, height: 428 * scale))
    let bambuLightURL = outURL.appendingPathComponent("Bambu-浅色实况光晕.png")
    let bambuLightDest = CGImageDestinationCreateWithURL(
        bambuLightURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(bambuLightDest, bambuLightCtx.makeImage()!, nil)
    _ = CGImageDestinationFinalize(bambuLightDest)
    print("已导出 \(bambuLightURL.path)")

    // 独立打印机标准布局：开启画面、任务、温度、时间等完整详情，并给出超长阶段。
    // 用于验证长状态会收成图标胶囊，下面的详情仍保持稳定间距。
    var bambuDetailedConfig = bambuPreviewConfig
    bambuDetailedConfig.layout = .standard
    var bambuDetailedEntities = bambuPreviewEntities
    bambuDetailedEntities[0].state = "moving_toolhead_to_center_of_heatbed"
    let bambuDetailedPreview = try ScreenRenderer.renderBambuLab(
        bambuDetailedConfig, entities: bambuDetailedEntities, image: artData as Data,
        settings: bambuPreviewSettings, dataUpdatedAt: Date())
    let bambuDetailedCtx = CGContext(data: nil, width: Int(142 * scale), height: Int(428 * scale),
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bambuDetailedCtx.interpolationQuality = .none
    bambuDetailedCtx.draw(bambuDetailedPreview.image,
                          in: CGRect(x: 0, y: 0, width: 142 * scale, height: 428 * scale))
    let bambuDetailedURL = outURL.appendingPathComponent("Bambu-标准全详情长状态.png")
    let bambuDetailedDest = CGImageDestinationCreateWithURL(
        bambuDetailedURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(bambuDetailedDest, bambuDetailedCtx.makeImage()!, nil)
    _ = CGImageDestinationFinalize(bambuDetailedDest)
    print("已导出 \(bambuDetailedURL.path)")

    // 灵犀画板三台打印机：验证真实 142×428 画面下的大字号摘要与长状态换行。
    let multiSettings = AppSettings()
    let multiConfigs = [
        BambuLabCardSettings(name: "工作室 X2D", statusEntityID: "sensor.p1_status",
                             progressEntityID: "sensor.p1_progress", taskEntityID: "sensor.p1_task",
                             nozzleTempEntityID: "sensor.p1_nozzle", bedTempEntityID: "sensor.p1_bed",
                             remainingEntityID: "sensor.p1_remaining"),
        BambuLabCardSettings(name: "客厅 P1S", statusEntityID: "sensor.p2_status",
                             progressEntityID: "sensor.p2_progress", taskEntityID: "sensor.p2_task",
                             nozzleTempEntityID: "sensor.p2_nozzle", bedTempEntityID: "sensor.p2_bed",
                             remainingEntityID: "sensor.p2_remaining"),
        BambuLabCardSettings(name: "书房 A1", statusEntityID: "sensor.p3_status",
                             progressEntityID: "sensor.p3_progress", taskEntityID: "sensor.p3_task",
                             nozzleTempEntityID: "sensor.p3_nozzle", bedTempEntityID: "sensor.p3_bed",
                             remainingEntityID: "sensor.p3_remaining")
    ]
    multiSettings.devices = multiConfigs.map { config in
        var fields = DeviceSettings()
        config.apply(to: &fields)
        return ManagedDevice(type: .bambuLab, name: config.name, settings: fields)
    }
    let multiModules: [CanvasModule] = [.bambuLab, .bambuLab2, .bambuLab3]
    let richFields = CanvasPrinterFields(showStatus: true, showProgress: true, showTask: true,
                                         showNozzleTemp: true, showBedTemp: true,
                                         showRemaining: true, showError: true)
    let multiPrinterFields = Dictionary(uniqueKeysWithValues: multiModules.map {
        ($0.rawValue, richFields)
    })
    let multiEntities: [HAEntity] = [
        HAEntity(entityId: "sensor.p1_status", friendlyName: "状态", state: "moving_toolhead_to_center_of_heatbed", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.p1_progress", friendlyName: "进度", state: "18", unitOfMeasurement: "%"),
        HAEntity(entityId: "sensor.p1_task", friendlyName: "任务", state: "Luna_头饰.3mf", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.p1_nozzle", friendlyName: "喷嘴", state: "220", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.p1_bed", friendlyName: "热床", state: "55", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.p1_remaining", friendlyName: "剩余", state: "0", unitOfMeasurement: "min"),
        HAEntity(entityId: "sensor.p2_status", friendlyName: "状态", state: "printing", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.p2_progress", friendlyName: "进度", state: "52", unitOfMeasurement: "%"),
        HAEntity(entityId: "sensor.p2_task", friendlyName: "任务", state: "多色支架", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.p2_nozzle", friendlyName: "喷嘴", state: "218", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.p2_bed", friendlyName: "热床", state: "50", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.p2_remaining", friendlyName: "剩余", state: "42", unitOfMeasurement: "min"),
        HAEntity(entityId: "sensor.p3_status", friendlyName: "状态", state: "paused_chamber_temperature_control_error", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.p3_progress", friendlyName: "进度", state: "76", unitOfMeasurement: "%"),
        HAEntity(entityId: "sensor.p3_task", friendlyName: "任务", state: "齿轮箱外壳", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.p3_nozzle", friendlyName: "喷嘴", state: "210", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.p3_bed", friendlyName: "热床", state: "60", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.p3_remaining", friendlyName: "剩余", state: "17", unitOfMeasurement: "min")
    ]
    let multiSystem = SystemSnapshot(
        cpuPercent: 0, memoryPercent: 0, usedMemoryBytes: 0, totalMemoryBytes: 1,
        downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
        uptime: 0, sampledAt: Date())
    let multiPomodoro = PomodoroSnapshot(
        phase: .idle, effectivePhase: .idle, taskName: "",
        remaining: 0, duration: 0, completedFocusSessions: 0)
    let multiPreview = try ScreenRenderer.renderCanvas(
        modules: multiModules, system: multiSystem, nowPlaying: .sample,
        pomodoro: multiPomodoro, customText: "", settings: multiSettings,
        ha: HASnapshot(entities: multiEntities), printerFields: multiPrinterFields)
    let multiCtx = CGContext(data: nil, width: Int(142 * scale), height: Int(428 * scale),
                             bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    multiCtx.interpolationQuality = .none
    multiCtx.draw(multiPreview.image, in: CGRect(x: 0, y: 0, width: 142 * scale, height: 428 * scale))
    let multiURL = outURL.appendingPathComponent("灵犀画板-三台打印机.png")
    let multiDest = CGImageDestinationCreateWithURL(multiURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(multiDest, multiCtx.makeImage()!, nil)
    _ = CGImageDestinationFinalize(multiDest)
    print("已导出 \(multiURL.path)")

    // Formlabs 在三种真实画板尺寸下的响应式布局预览。
    let formConnection = FormlabsConnectionSettings(
        printerSerial: "FORM-4-PREVIEW", clientID: "preview", clientSecret: "preview",
        showThumbnail: true, showLayers: true, showMaterial: true)
    let formPrint = FormlabsPrintInfo(
        name: "Dental Model 前壳（轻量化）", status: "printing",
        currentLayer: 275, layerCount: 1711,
        estimatedTimeRemainingMS: 9_180_000,
        materialName: "Grey V5")
    let formSnapshot = FormlabsSnapshot(
        device: FormlabsDeviceInfo(id: "FORM-4-PREVIEW", productName: "Form 4",
                                   status: "printing", isConnected: true),
        print: formPrint, thumbnail: artData as Data, sampledAt: Date(), cloudError: nil)
    let formItem = FormlabsCanvasItem(deviceName: "Formlabs 1",
                                      connection: formConnection, snapshot: formSnapshot)
    let formKeyboard = try ScreenRenderer.renderCanvas(
        modules: [.formlabs], system: multiSystem, nowPlaying: .sample,
        pomodoro: multiPomodoro, customText: "", settings: multiSettings,
        formlabsItems: [formItem])
    func saveCanvasPreview(_ image: CGImage, name: String, previewScale: CGFloat = 3) {
        let previewWidth = Int(CGFloat(image.width) * previewScale)
        let previewHeight = Int(CGFloat(image.height) * previewScale)
        let previewContext = CGContext(data: nil, width: previewWidth, height: previewHeight,
                                       bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        previewContext.interpolationQuality = .none
        previewContext.draw(image, in: CGRect(x: 0, y: 0,
                                              width: previewWidth, height: previewHeight))
        let previewURL = outURL.appendingPathComponent("\(name).png")
        let destination = CGImageDestinationCreateWithURL(
            previewURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, previewContext.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        print("已导出 \(previewURL.path)")
    }
    saveCanvasPreview(formKeyboard.image, name: "Formlabs-灵犀画板")
    let formStandalone = try ScreenRenderer.renderFormlabs(
        deviceName: "Formlabs 1", connection: formConnection,
        snapshot: formSnapshot, settings: multiSettings)
    saveCanvasPreview(formStandalone.image, name: "Formlabs-独立卡片")
    let formOracle = ScreenRenderer.renderDeviceCanvas(
        modules: [.formlabs], system: multiSystem, nowPlaying: .sample,
        pomodoro: multiPomodoro, customText: "", settings: multiSettings,
        formlabsItems: [formItem], width: 200, height: 200,
        palette: multiSettings.resolvedPalette)
    saveCanvasPreview(formOracle, name: "Formlabs-口袋先知")
    let formExcerpt = ScreenRenderer.renderDeviceCanvas(
        modules: [.formlabs], system: multiSystem, nowPlaying: .sample,
        pomodoro: multiPomodoro, customText: "", settings: multiSettings,
        formlabsItems: [formItem], width: 296, height: 152,
        palette: multiSettings.resolvedPalette)
    saveCanvasPreview(formExcerpt, name: "Formlabs-摘录")
    let bambuOracle = ScreenRenderer.renderDeviceCanvas(
        modules: [.bambuLab], system: multiSystem, nowPlaying: .sample,
        pomodoro: multiPomodoro, customText: "", settings: multiSettings,
        ha: HASnapshot(entities: multiEntities), width: 200, height: 200,
        palette: multiSettings.resolvedPalette,
        printerFields: [CanvasModule.bambuLab.rawValue: richFields],
        optimizeBambuForOracleEInk: true, bambuHeroLayout: true,
        showBambuCamera: false)
    saveCanvasPreview(bambuOracle, name: "Bambu-口袋先知")
    let bambuExcerpt = ScreenRenderer.renderDeviceCanvas(
        modules: [.bambuLab], system: multiSystem, nowPlaying: .sample,
        pomodoro: multiPomodoro, customText: "", settings: multiSettings,
        ha: HASnapshot(entities: multiEntities), width: 296, height: 152,
        palette: multiSettings.resolvedPalette,
        printerFields: [CanvasModule.bambuLab.rawValue: richFields],
        optimizeBambuForOracleEInk: true, bambuHeroLayout: true,
        showBambuCamera: false)
    saveCanvasPreview(bambuExcerpt, name: "Bambu-摘录")

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

    // 基线自动采样：首次采样、跨天重新采样、额度回升拉高基线、额度为 0 不动基线
    let day1 = "2026-08-24"
    let day2 = "2026-08-25"
    let first = QuotaBaselineSampler.sample(baseline: nil, baselineDay: nil, remaining: 2061.9, today: day1)
    check(first.baseline == 2061.9 && first.day == day1, "首次采样应以当前额度为基线")
    let sameDayDown = QuotaBaselineSampler.sample(baseline: 2061.9, baselineDay: day1, remaining: 1500, today: day1)
    check(sameDayDown.baseline == 2061.9 && sameDayDown.day == day1, "同日额度下降不应动基线")
    let sameDayUp = QuotaBaselineSampler.sample(baseline: 1500, baselineDay: day1, remaining: 2500, today: day1)
    check(sameDayUp.baseline == 2500 && sameDayUp.day == day1, "同日额度回升超过基线应拉高基线")
    let nextDay = QuotaBaselineSampler.sample(baseline: 1500, baselineDay: day1, remaining: 2000, today: day2)
    check(nextDay.baseline == 2000 && nextDay.day == day2, "跨天应以当天额度重新采样")
    let zeroRemaining = QuotaBaselineSampler.sample(baseline: 2000, baselineDay: day1, remaining: 0, today: day2)
    check(zeroRemaining.baseline == 2000 && zeroRemaining.day == day1, "额度为 0 不应动基线")
    let zeroFirst = QuotaBaselineSampler.sample(baseline: nil, baselineDay: nil, remaining: 0, today: day1)
    check(zeroFirst.baseline == nil && zeroFirst.day == nil, "额度为 0 且无基线时保持未设置")
    check(QuotaBaselineSampler.dayKey(Date()).count == 10, "基线日键应为 yyyy-MM-dd 格式")

    // 额度数值两位小数拆分（整数/小数，供半字号小数渲染）
    let n1 = ScreenRenderer.quotaNumberParts(2270.2671)
    checkEqual(n1.whole, "2270", "额度整数部分")
    checkEqual(n1.fraction, "27", "额度小数部分（两位小数）")
    let n2 = ScreenRenderer.quotaNumberParts(88.5)
    checkEqual(n2.whole, "88", "88.5 整数部分")
    checkEqual(n2.fraction, "50", "88.5 小数部分补零")
    let n3 = ScreenRenderer.quotaNumberParts(10.999)
    checkEqual(n3.whole, "11", "四舍五入进位整数部分")
    checkEqual(n3.fraction, "00", "四舍五入进位小数部分")
    let n4 = ScreenRenderer.quotaNumberParts(0)
    checkEqual(n4.whole, "0", "零值整数部分")
    checkEqual(n4.fraction, "00", "零值小数部分")

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

    // 页脚顺序：上=时钟(强调色)，下=日期(强调色)——正在播放页脚跟随封面/全局强调色
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
    var accentInDateBand = 0
    for sy in 382...402 {
        var sx = 30
        while sx < 112 {
            let i = sy * fbpr + sx * 4
            let r = Int(fp[i]); let g = Int(fp[i + 1]); let b = Int(fp[i + 2])
            if g > 150 && g > r + 20 && g > b { accentInDateBand += 1 }
            sx += 2
        }
    }
    check(accentInDateBand > 20, "页脚下方应为日期（强调色像素），实际 \(accentInDateBand)")

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
    footerSettings.timeFormat = "HH:mm:ss"
    footerSettings.dateFormat = "yyyy年M月d日 EEE"
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

    // 字号调小后底部行距应收紧（行间距释放出来）：「当前时间」行随字号缩小而贴近底部时间。
    // 用无封面渲染：页脚文字为全局强调色（绿）、背景深色、无封面光晕干扰，可按强调色唯一定位
    func footerLabelTop(_ result: RenderResult) -> Int {
        let img = result.image
        let w = img.width, h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 315..<400 {
            var matches = 0
            for x in 45...95 {
                let i = (y * w + x) * 4
                let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                // 绿色强调色（无封面时页脚跟随全局强调色）
                if g > 150 && g > r + 20 && g > b { matches += 1 }
            }
            if matches >= 4 { return y }
        }
        return -1
    }
    footerSettings.nowPlayingFooterVisible = true
    footerSettings.nowPlayingTimeSize = 22
    footerSettings.nowPlayingDateSize = 17
    let footerDefault = try ScreenRenderer.renderNowPlaying(.sample, settings: footerSettings)
    let labelDefault = footerLabelTop(footerDefault)
    footerSettings.nowPlayingTimeSize = 12
    footerSettings.nowPlayingDateSize = 8
    let footerSmall = try ScreenRenderer.renderNowPlaying(.sample, settings: footerSettings)
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

    // 仅运行时间（无其他板块时整槽居中渲染）
    settings.showCpu = false; settings.showMemory = false; settings.showNetwork = false; settings.showUptime = true
    check(try render().data.count > 0, "仅运行时间渲染")

    // 运行时间 + CPU + 内存 + 网络：运行时间压缩为底部紧凑行，其余板块均分剩余（默认全开即覆盖该路径）
    settings.showCpu = true; settings.showMemory = true; settings.showNetwork = true; settings.showUptime = true
    check(try render().data.count > 0, "运行时间紧凑行渲染")

    // 全关 → 至少回退一项
    settings.showCpu = false; settings.showMemory = false; settings.showNetwork = false; settings.showUptime = false
    check(try render().data.count > 0, "全关渲染（回退 CPU）")

    // CPU + 网络
    settings.showCpu = true; settings.showMemory = false; settings.showNetwork = true; settings.showUptime = false
    check(try render().data.count > 0, "CPU+网络渲染")

    // 仅磁盘（含磁盘用量数据）
    let diskSystem = SystemSnapshot(cpuPercent: 0, memoryPercent: 0,
                                    usedMemoryBytes: 0, totalMemoryBytes: 0,
                                    diskPercent: 68,
                                    usedDiskBytes: 340 * 1024 * 1024 * 1024,
                                    totalDiskBytes: 500 * 1024 * 1024 * 1024,
                                    downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
                                    uptime: 0, sampledAt: Date())
    let diskSettings = AppSettings()
    diskSettings.showCpu = false; diskSettings.showMemory = false
    diskSettings.showNetwork = false; diskSettings.showUptime = false
    diskSettings.showDisk = true
    let diskRender = try ScreenRenderer.renderSystem(diskSystem, settings: diskSettings)
    check(diskRender.data.count > 0, "仅磁盘渲染")
    checkEqual(decodeJPEG(diskRender.data).width, 142, "仅磁盘宽度")
    checkEqual(decodeJPEG(diskRender.data).height, 428, "仅磁盘高度")
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

    // 回归：网络文字必须绘制在网络盒子带内（skia 语义：网络是最后一个主板块，盒子带位于内存之下、
    // 运行时间紧凑行之上，对应图像行约 268-350、x 30-130）。
    // 此前 CG/Skia 坐标混用导致文字画到 CPU/内存板块、盒内为空（堆叠问题根因）。
    let image = r1.image
    let pxData = image.dataProvider!.data! as Data
    let bpr = image.bytesPerRow
    var boxBright = 0
    for sy in 268...350 {
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

    checkEqual(CustomImageClockOverlay.horizontalTop.title, "Pixel 大时钟 · 顶部", "Pixel 顶部样式标题")
    checkEqual(CustomImageClockOverlay.verticalCenter.title, "Pixel 叠排大时钟 · 居中", "Pixel 叠排样式标题")
    checkEqual(CustomImageClockOverlay.allCases,
               [.none, .verticalLeft, .verticalCenter], "时钟叠加只提供两种 Pixel 叠排布局")
    checkEqual(CustomImageClockOverlay.horizontalTop.stackedOnly, .verticalLeft,
               "旧顶部横向时钟迁移到上方叠排")
    checkEqual(CustomImageClockOverlay.horizontalBottom.stackedOnly, .verticalCenter,
               "旧底部横向时钟迁移到居中叠排")

    // 图片强调色按壁纸采样，纯红/纯蓝均保留自己的色相，并自动提升反差。
    func solidImage(_ color: CGColor) -> CGImage {
        let colorContext = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                     bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        colorContext.setFillColor(color)
        colorContext.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return colorContext.makeImage()!
    }
    let redAccent = ScreenRenderer.wallpaperAccentColor(
        of: solidImage(CGColor(red: 0.72, green: 0.06, blue: 0.04, alpha: 1)))
    let blueAccent = ScreenRenderer.wallpaperAccentColor(
        of: solidImage(CGColor(red: 0.04, green: 0.12, blue: 0.76, alpha: 1)))
    check(redAccent.0 > redAccent.1 && redAccent.0 > redAccent.2,
          "红色图片应采样出偏红强调色")
    check(blueAccent.2 > blueAccent.0 && blueAccent.2 > blueAccent.1,
          "蓝色图片应采样出偏蓝强调色")
    check(redAccent != blueAccent, "不同壁纸应得到不同强调色")
    func linear(_ value: CGFloat) -> Double {
        let value = Double(value)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    func luminance(_ color: (CGFloat, CGFloat, CGFloat)) -> Double {
        0.2126 * linear(color.0) + 0.7152 * linear(color.1) + 0.0722 * linear(color.2)
    }
    func contrast(_ first: (CGFloat, CGFloat, CGFloat),
                  _ second: (CGFloat, CGFloat, CGFloat)) -> Double {
        let values = [luminance(first), luminance(second)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }
    let redBackground: (CGFloat, CGFloat, CGFloat) = (0.72, 0.06, 0.04)
    let redTones = ScreenRenderer.wallpaperClockColors(
        of: solidImage(CGColor(red: redBackground.0, green: redBackground.1,
                               blue: redBackground.2, alpha: 1)))
    check(redTones.usesLightTones, "深色壁纸应选择 Material You 浅色调阶")
    check(contrast(redTones.primary, redBackground) >= 5,
          "深色壁纸与主时钟色应有强烈对比")
    check(redTones.primary != redTones.secondary, "同色系主次色调应有明暗层级")
    check(luminance(redTones.primaryOutline) > luminance(redTones.primary),
          "每个数字应具有比本体更浅的同色系外轮廓")
    check(contrast(redTones.primaryOutline, redBackground) >= 5,
          "深色壁纸上的浅描边应保持强对比")
    check(redTones.primary.0 - max(redTones.primary.1, redTones.primary.2) > 0.08,
          "Material Accent 1 应保留明显的红色种子色")
    let lightBackground: (CGFloat, CGFloat, CGFloat) = (0.92, 0.84, 0.30)
    let lightTones = ScreenRenderer.wallpaperClockColors(
        of: solidImage(CGColor(red: lightBackground.0, green: lightBackground.1,
                               blue: lightBackground.2, alpha: 1)))
    check(!lightTones.usesLightTones, "浅色壁纸应选择 Material You 深色调阶")
    check(contrast(lightTones.primary, lightBackground) >= 5,
          "浅色壁纸与主时钟色应有强烈对比")
    check(luminance(lightTones.primaryOutline) < luminance(lightTones.primary),
          "浅色壁纸应自动切换为比数字本体更深的外轮廓")
    check(contrast(lightTones.primaryOutline, lightBackground) >= 5,
          "浅色壁纸上的深描边应保持强对比")
    let stackedFont = CTFontCreateWithName("Arial-Black" as CFString, 40, nil)
    checkEqual(CTFontCopyPostScriptName(stackedFont) as String,
               "Arial-Black", "叠排时钟使用 Arial Black 字体")
    checkEqual(WallpaperColorStyle.allCases.count, 3, "Pixel 动态取色提供三种样式")
    checkEqual(WallpaperColorStyle.natural.title, "自然", "自然取色标题")
    checkEqual(WallpaperColorStyle.vibrant.title, "鲜艳", "鲜艳取色标题")
    checkEqual(WallpaperColorStyle.expressive.title, "表现力", "表现力取色标题")
    let redImage = solidImage(CGColor(red: redBackground.0, green: redBackground.1,
                                      blue: redBackground.2, alpha: 1))
    let naturalColors = ScreenRenderer.wallpaperClockColors(of: redImage, style: .natural)
    let vibrantColors = ScreenRenderer.wallpaperClockColors(of: redImage, style: .vibrant)
    let expressiveColors = ScreenRenderer.wallpaperClockColors(of: redImage, style: .expressive)
    check(naturalColors.primary != vibrantColors.primary, "鲜艳样式应改变动态色板")
    check(naturalColors.primary != expressiveColors.primary, "表现力样式应改变动态色板")
    check(contrast(vibrantColors.primary, redBackground) >= 5,
          "鲜艳样式仍应保持强对比")
    check(contrast(expressiveColors.primary, redBackground) >= 5,
          "表现力样式仍应保持强对比")

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
    settings.customImageClock = .verticalLeft
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

    // 两种保留布局的位置不同；旧横向值渲染时直接归一为相应叠排样式
    settings.customImageClock = .verticalLeft
    let vl = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.customImageClock = .verticalCenter
    let vc = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(vl.data != vc.data, "上方/居中叠排布局应不同")
    settings.customImageClock = .horizontalTop
    let legacyTop = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(legacyTop.data == vl.data, "旧横向顶部渲染归一为上方叠排")

    // 设置往返
    let roundTrip = AppSettings()
    roundTrip.customImageClock = .horizontalBottom
    let encoded = try JSONEncoder().encode(roundTrip)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
    checkEqual(decoded.customImageClock, .verticalCenter, "旧横向时钟设置解码迁移为叠排")
    checkEqual(decoded.wallpaperColorStyle, .natural, "旧设置默认使用自然取色")
    checkEqual(decoded.clockDateVisible, true, "旧设置默认显示叠排时钟日期")
    roundTrip.wallpaperColorStyle = .expressive
    let styleDecoded = try JSONDecoder().decode(AppSettings.self,
                                                from: JSONEncoder().encode(roundTrip))
    checkEqual(styleDecoded.wallpaperColorStyle, .expressive, "动态取色样式设置往返")

    // 日期可独立隐藏；关闭后连同日期间距一起释放，四位数字仍保持完整图层组布局。
    settings.customImageClock = .verticalCenter
    settings.clockDateVisible = true
    let withClockDate = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.clockDateVisible = false
    let withoutClockDate = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(withClockDate.data != withoutClockDate.data, "日期开关应改变叠排时钟渲染")
    settings.clockDateVisible = true

    // 旧字体设置仍可解码，但 Pixel 叠排时钟固定使用 Arial Black，不再受其影响
    checkEqual(ClockFontWeight.allCases.count, 6, "时钟字重数量")
    checkEqual(ClockFontWeight.modernCases, [.regular, .medium, .bold], "现代时钟可选字重")
    checkEqual(ClockFontWeight.thin.title, "纤细", "时钟字重标题")
    checkEqual(ClockFontWeight.thin.fontName, "HelveticaNeue-Thin", "纤细对应字体名")
    checkEqual(ClockFontWeight.ultraLight.fontName, "HelveticaNeue-UltraLight", "极细字体名")
    checkEqual(ClockFontWeight.medium.fontName, "HelveticaNeue-Medium", "中粗字体名")
    checkEqual(ClockFontWeight.bold.fontName, "HelveticaNeue-Bold", "粗体字体名")
    checkEqual(ClockFontWeight.thin.modernized, .medium, "旧纤细字重自动提升为中粗")
    let weightRT = AppSettings()
    weightRT.clockFontWeight = .medium
    let weightDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(weightRT))
    checkEqual(weightDecoded.clockFontWeight, .medium, "时钟字重设置往返")
    checkEqual(AppSettings().clockFontWeight, .medium, "时钟字重默认中粗")
    settings.customImageClock = .verticalCenter
    settings.clockFontWeight = .medium
    let mediumRender = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.clockFontWeight = .bold
    let boldRender = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(boldRender.data == mediumRender.data, "Pixel 叠排时钟固定 Arial Black，不受旧字重影响")

    // 整体大小：有效范围每一端都会统一缩放整个时钟组
    checkEqual(StackedClockSizing.minimum, 32, "叠排时钟整体大小下界")
    checkEqual(StackedClockSizing.maximum, 42, "叠排时钟整体大小上界")
    checkEqual(StackedClockSizing.outlineExpansion, 5, "数字浅色外轮廓扩展半径")
    checkEqual(StackedClockSizing.percent(for: 32), 76, "最小整体缩放比例")
    checkEqual(StackedClockSizing.percent(for: 42), 100, "最大整体缩放比例")
    settings.customImageClock = .verticalCenter
    settings.clockFontSize = 32
    let small = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.clockFontSize = 42
    let big = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(small.data != big.data, "整体大小 76%/100% 渲染应不同")

    // 时间格式：不同格式渲染不同
    settings.clockFontSize = StackedClockSizing.defaultValue
    settings.timeFormat = "HH:mm"
    let fmtHM = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.timeFormat = "HH:mm:ss"
    let fmtHMS = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(fmtHM.data == fmtHMS.data, "叠排四位时钟忽略秒字段并保持紧密 2×2 布局")
    settings.timeFormat = "a hh:mm:ss zzzz"
    settings.dateFormat = "yyyy年MM月dd日 EEEE"
    let longFormat = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    checkEqual(longFormat.image.width, 142, "长时间格式仍保持画布宽度")
    check(longFormat.data.count <= ScreenRenderer.maximumFileSize,
          "长时间与日期格式应自适应并保持文件大小限制")
    // 用下午时间对比（HH:mm=14:40 vs hh:mm=02:40 必然不同）
    let afternoon = base.addingTimeInterval(12 * 3600)
    settings.timeFormat = "HH:mm"
    let hmAfternoon = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: afternoon)
    settings.timeFormat = "hh:mm"
    let fmt12 = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: afternoon)
    check(fmt12.data != hmAfternoon.data, "12/24 小时制渲染应不同")

    // 无效格式回退 HH:mm（不崩溃且与 HH:mm 一致）
    settings.timeFormat = ""
    let fallback = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.timeFormat = "HH:mm"
    let plain = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(fallback.data == plain.data, "空格式应回退 HH:mm")

    // 字号/格式设置往返
    let rt2 = AppSettings()
    rt2.clockFontSize = 40
    rt2.clockTimeFormat = "HH:mm:ss"
    rt2.clockDateVisible = false
    let data2 = try JSONEncoder().encode(rt2)
    let decoded2 = try JSONDecoder().decode(AppSettings.self, from: data2)
    checkEqual(decoded2.clockFontSize, 40, "时钟整体大小往返")
    checkEqual(decoded2.clockTimeFormat, "HH:mm:ss", "时钟格式往返")
    checkEqual(decoded2.clockDateVisible, false, "时钟日期开关往返")

    // 字体家族：枚举数量/标题/字重映射、设置往返、不同字体渲染不同
    checkEqual(ClockFont.allCases.count, 7, "时钟字体数量")
    checkEqual(ClockFont.pingfang.fontName(weight: .thin), "PingFangSC-Thin", "苹方纤细字体名")
    checkEqual(ClockFont.songti.fontName(weight: .regular), "STSongti-SC-Regular", "宋体常规字体名")
    checkEqual(ClockFont.songti.fontName(weight: .medium), "STSongti-SC-Bold", "宋体中粗回退粗体")
    checkEqual(ClockFont.menlo.fontName(weight: .regular), "Menlo-Regular", "Menlo 常规字体名")
    checkEqual(ClockFont.menlo.fontName(weight: .bold), "Menlo-Bold", "Menlo 粗体字体名")
    checkEqual(AppSettings().clockFont, .helveticaNeue, "时钟字体默认 Helvetica Neue")
    let fontRT = AppSettings()
    fontRT.clockFont = .songti
    let fontDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(fontRT))
    checkEqual(fontDecoded.clockFont, .songti, "时钟字体设置往返")
    settings.customImageClock = .verticalCenter
    settings.clockFontWeight = .regular
    settings.clockFont = .helveticaNeue
    let hnRender = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.clockFont = .songti
    let songtiRender = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(hnRender.data == songtiRender.data, "Pixel 叠排时钟不受旧字体家族影响")

    // 偏移设置：X/Y 往返、钳制、偏移改变渲染
    let offRT = AppSettings()
    offRT.clockOffsetX = 24
    offRT.clockOffsetY = -16
    let offDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(offRT))
    checkEqual(offDecoded.clockOffsetX, 24, "时钟 X 偏移往返")
    checkEqual(offDecoded.clockOffsetY, -16, "时钟 Y 偏移往返")
    let offClamp = AppSettings()
    offClamp.clockOffsetX = 99
    offClamp.clockOffsetY = -200
    offClamp.clockFontSize = 200
    offClamp.clamped()
    checkEqual(offClamp.clockOffsetX, 60, "X 偏移上界钳制")
    checkEqual(offClamp.clockOffsetY, -160, "Y 偏移下界钳制")
    offClamp.clockOffsetY = 200
    offClamp.clamped()
    checkEqual(offClamp.clockOffsetY, 160, "Y 偏移上界钳制")
    checkEqual(offClamp.clockFontSize, 42, "时钟整体大小钳制到有效上界")
    offClamp.clockFontSize = 0
    offClamp.clamped()
    checkEqual(offClamp.clockFontSize, 32, "时钟整体大小钳制到有效下界")
    settings.clockFont = .helveticaNeue
    settings.clockOffsetX = 0
    settings.clockOffsetY = 0
    let noOffset = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.clockOffsetX = 20
    let xOffset = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    settings.clockOffsetX = 0
    settings.clockOffsetY = 30
    let yOffset = try ScreenRenderer.renderCustomImage(path: path.path, settings: settings, now: base)
    check(noOffset.data != xOffset.data, "X 偏移应改变渲染")
    check(noOffset.data != yOffset.data, "Y 偏移应改变渲染")

    // 设备快照：字体/偏移随键盘设备捕获与套用
    let devSrc = AppSettings()
    devSrc.clockFont = .menlo
    devSrc.wallpaperColorStyle = .vibrant
    devSrc.clockDateVisible = false
    devSrc.clockOffsetX = -12
    devSrc.clockOffsetY = 40
    let devCap = DeviceSettings.capture(from: devSrc, type: .keyboard)
    checkEqual(devCap.clockFont, .menlo, "键盘快照-时钟字体")
    checkEqual(devCap.wallpaperColorStyle, .vibrant, "键盘快照-动态取色样式")
    checkEqual(devCap.clockDateVisible, false, "键盘快照-时钟日期开关")
    checkEqual(devCap.clockOffsetX, -12, "键盘快照-时钟 X 偏移")
    checkEqual(devCap.clockOffsetY, 40, "键盘快照-时钟 Y 偏移")
    let devTgt = AppSettings()
    devCap.apply(to: devTgt, type: .keyboard)
    checkEqual(devTgt.clockFont, .menlo, "键盘套用-时钟字体")
    checkEqual(devTgt.wallpaperColorStyle, .vibrant, "键盘套用-动态取色样式")
    checkEqual(devTgt.clockDateVisible, false, "键盘套用-时钟日期开关")
    checkEqual(devTgt.clockOffsetX, -12, "键盘套用-时钟 X 偏移")
    checkEqual(devTgt.clockOffsetY, 40, "键盘套用-时钟 Y 偏移")
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

    // 磁盘模块渲染（标签+百分比+进度条+已用/总容量小字）
    let diskCanvas = try ScreenRenderer.renderCanvas(modules: [.disk], system: system,
                                                     nowPlaying: np, pomodoro: pomodoro,
                                                     customText: "", settings: AppSettings(), now: fixed)
    checkEqual(diskCanvas.image.width, 142, "磁盘模块画板宽度")
    checkEqual(diskCanvas.image.height, 428, "磁盘模块画板高度")
    check(diskCanvas.data.count <= ScreenRenderer.maximumFileSize, "磁盘模块画板大小")

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
    // 打印完成庆祝卡：🎉 + 打印机名，正常尺寸且与夸夸卡不同
    let printDone = try ScreenRenderer.renderPrintSuccess(printerName: "X2D", settings: settings)
    checkEqual(printDone.image.width, 142, "打印完成卡宽度")
    checkEqual(printDone.image.height, 428, "打印完成卡高度")
    check(printDone.data.count <= ScreenRenderer.maximumFileSize, "打印完成卡大小")
    check(printDone.data != praise.data, "打印完成卡与夸夸卡渲染应不同")
    let printDoneEmptyName = try ScreenRenderer.renderPrintSuccess(printerName: "", settings: settings)
    check(printDoneEmptyName.data.count <= ScreenRenderer.maximumFileSize, "打印完成卡-空名渲染正常")
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
    let typography = ScreenRenderer.canvasTypography()
    checkEqual(typography.label, 9, "画板信息模块统一标签字号")
    checkEqual(typography.value, 12, "画板信息模块统一主数值字号")
    checkEqual(typography.body, 10, "画板信息模块统一正文字号")
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
    s.timeFormat = "HH:mm:ss"
    s.dateFormat = "M/d"
    let fmtCustom = try render()
    check(fmtDefault.data != fmtCustom.data, "画板时钟/日期格式自定义应改变渲染")
    // 画板 Home Assistant 模块：长实体名折两行、状态与图标不错位
    let longA = HAEntity(entityId: "sensor.x2d_20p6bj652500750_print_status",
                         friendlyName: "X2D_20P6BJ652500750 打印状态", state: "printing", unitOfMeasurement: nil)
    let longB = HAEntity(entityId: "image.xh_fo9636_gamerpic",
                         friendlyName: "XH FO9636 玩家头像", state: "2026-08-29T16:50:35", unitOfMeasurement: nil)
    let shortA = HAEntity(entityId: "sensor.temp", friendlyName: "温度", state: "23", unitOfMeasurement: "°C")
    let shortB = HAEntity(entityId: "switch.fan", friendlyName: "风扇", state: "on", unitOfMeasurement: nil)
    var haCanvasS = AppSettings()
    let haLong = HASnapshot(entities: [longA, longB], selectedEntities: [longA, longB])
    let haShort = HASnapshot(entities: [shortA, shortB], selectedEntities: [shortA, shortB])
    let haLongRender = try ScreenRenderer.renderCanvas(modules: [.homeAssistant], system: system,
                                                     nowPlaying: np, pomodoro: pomodoro,
                                                     customText: "", settings: haCanvasS, ha: haLong)
    let haShortRender = try ScreenRenderer.renderCanvas(modules: [.homeAssistant], system: system,
                                                      nowPlaying: np, pomodoro: pomodoro,
                                                      customText: "", settings: haCanvasS, ha: haShort)
    check(haLongRender.data != haShortRender.data, "长名与短名实体列表渲染不同（长名折行生效）")
    checkEqual(haLongRender.image.width, 142, "长名折行不破坏画板宽度")
    // HA 模块画面占比随本画板实体数量单调增长，并设上限避免挤占全部其他模块。
    let haHeightWeights = (0...9).map {
        ScreenRenderer.homeAssistantCanvasHeightMultiplier(entityCount: $0)
    }
    checkEqual(haHeightWeights[0], 0.5, "HA 未选实体保留最小提示高度")
    checkEqual(haHeightWeights[1], 0.5, "HA 单实体使用紧凑高度")
    check(abs(haHeightWeights[4] - 1.7857) < 0.001, "HA 四实体扩大画面占比")
    check(zip(haHeightWeights.dropFirst(), haHeightWeights.dropFirst(2)).allSatisfy { pair in
        pair.0 < pair.1
    },
          "HA 模块高度无硬性封顶，实体减少时始终释放空间")

    // Bambu 模块也必须按实际显示项回收外层分带，不能只隐藏文字却留下空行。
    let hiddenPrinterFields = CanvasPrinterFields(
        showStatus: false, showProgress: false, showTask: false,
        showNozzleTemp: false, showBedTemp: false, showRemaining: false,
        showError: false, showImage: false)
    let summaryPrinterFields = CanvasPrinterFields.default
    var detailedPrinterFields = summaryPrinterFields
    detailedPrinterFields.showTask = true
    detailedPrinterFields.showNozzleTemp = true
    detailedPrinterFields.showBedTemp = true
    detailedPrinterFields.showRemaining = true
    var picturedPrinterFields = detailedPrinterFields
    picturedPrinterFields.showImage = true
    let hiddenPrinterWeight = ScreenRenderer.bambuCanvasHeightMultiplier(
        fields: hiddenPrinterFields, compactSummary: true)
    let summaryPrinterWeight = ScreenRenderer.bambuCanvasHeightMultiplier(
        fields: summaryPrinterFields, compactSummary: true)
    let detailedPrinterWeight = ScreenRenderer.bambuCanvasHeightMultiplier(
        fields: detailedPrinterFields, compactSummary: true)
    let picturedPrinterWeight = ScreenRenderer.bambuCanvasHeightMultiplier(
        fields: picturedPrinterFields, compactSummary: true)
    check(hiddenPrinterWeight < summaryPrinterWeight,
          "打印机隐藏全部详情后应释放外层模块空间")
    check(summaryPrinterWeight < detailedPrinterWeight,
          "打印机开启任务/温度/时间后应增加模块占比")
    check(detailedPrinterWeight < picturedPrinterWeight,
          "打印机开启画面后应获得更高模块区域")
    check(ScreenRenderer.bambuCanvasHeightMultiplier(
        fields: detailedPrinterFields, compactSummary: true)
        < ScreenRenderer.bambuCanvasHeightMultiplier(
            fields: detailedPrinterFields, compactSummary: false),
          "多打印机摘要合并温度和时间后应进一步释放空间")

    // 与其他模块混排时，1 个与 5 个实体应产生不同的分带与渲染结果；多实体不再固定截断前三个。
    let dynamicEntities = (1...5).map {
        HAEntity(entityId: "sensor.dynamic_\($0)", friendlyName: "实体 \($0)",
                 state: "\($0)", unitOfMeasurement: nil)
    }
    let oneEntityHA = HASnapshot(entities: dynamicEntities,
                                 selectedEntities: Array(dynamicEntities.prefix(1)))
    let fiveEntityHA = HASnapshot(entities: dynamicEntities,
                                  selectedEntities: dynamicEntities)
    let oneEntityCanvas = try ScreenRenderer.renderCanvas(modules: [.homeAssistant, .clock],
                                                          system: system, nowPlaying: np,
                                                          pomodoro: pomodoro, customText: "",
                                                          settings: haCanvasS, ha: oneEntityHA,
                                                          now: fixed)
    let fiveEntityCanvas = try ScreenRenderer.renderCanvas(modules: [.homeAssistant, .clock],
                                                           system: system, nowPlaying: np,
                                                           pomodoro: pomodoro, customText: "",
                                                           settings: haCanvasS, ha: fiveEntityHA,
                                                           now: fixed)
    check(oneEntityCanvas.data != fiveEntityCanvas.data,
          "HA 实体数量变化应动态改变画板模块占比与内容")

    // 全局时间/日期格式：一份设置，各界面统一生效
    var unified = AppSettings()
    unified.canvasModules = [CanvasModule.clock.rawValue]
    let unifiedClockDefault = try ScreenRenderer.renderCanvas(modules: [.clock], system: system,
                                                             nowPlaying: np, pomodoro: pomodoro,
                                                             customText: "", settings: unified, now: fixed)
    unified.timeFormat = "HH:mm:ss"
    let unifiedClockSeconds = try ScreenRenderer.renderCanvas(modules: [.clock], system: system,
                                                              nowPlaying: np, pomodoro: pomodoro,
                                                              customText: "", settings: unified, now: fixed)
    check(unifiedClockDefault.data != unifiedClockSeconds.data, "全局时间格式改变画板时钟模块")
    let compactClockSize = ScreenRenderer.adaptiveFontSize(
        "23:59", maxSize: 32, minSize: 5.5, bold: true, maxWidth: 120)
    let longClockSize = ScreenRenderer.adaptiveFontSize(
        "下午 11:59:59 中国标准时间", maxSize: 32, minSize: 5.5,
        bold: true, maxWidth: 120)
    check(longClockSize < compactClockSize,
          "全局时间格式变长时应按可用宽度自动缩小字号")
    var longGlobalFormat = AppSettings()
    longGlobalFormat.timeFormat = "a hh:mm:ss zzzz"
    longGlobalFormat.dateFormat = "yyyy年MM月dd日 EEEE"
    longGlobalFormat.nowPlayingFooterVisible = true
    longGlobalFormat.nowPlayingTimeSize = 40
    longGlobalFormat.nowPlayingDateSize = 30
    let longFormatCanvas = try ScreenRenderer.renderCanvas(
        modules: [.clock, .date], system: system,
        nowPlaying: np, pomodoro: pomodoro,
        customText: "", settings: longGlobalFormat, now: fixed)
    checkEqual(longFormatCanvas.image.width, ScreenRenderer.width,
               "灵犀画板可渲染长时间与日期格式")
    let longFormatFooter = try ScreenRenderer.renderNowPlaying(
        NowPlayingInfo(title: "歌", artist: "手"),
        settings: longGlobalFormat, now: fixed)
    checkEqual(longFormatFooter.image.height, ScreenRenderer.height,
               "卡片页脚可渲染长时间与日期格式并自适应字号")
    let footerDefault = try ScreenRenderer.renderNowPlaying(NowPlayingInfo(title: "歌", artist: "手"),
                                                            settings: { var x = AppSettings(); x.nowPlayingFooterVisible = true; return x }(),
                                                            now: fixed)
    let footerSeconds = try ScreenRenderer.renderNowPlaying(NowPlayingInfo(title: "歌", artist: "手"),
                                                            settings: { var x = AppSettings(); x.nowPlayingFooterVisible = true; x.timeFormat = "HH:mm:ss"; x.dateFormat = "yyyy-MM-dd"; return x }(),
                                                            now: fixed)
    check(footerDefault.data != footerSeconds.data, "同一份全局格式同样改变正在播放页脚")
    // 格式设置不再按设备搬运：切键盘不会换格式
    var fmtDevice = AppSettings()
    fmtDevice.timeFormat = "HH:mm:ss"
    fmtDevice.dateFormat = "yyyy-MM-dd"
    let fmtSnap = DeviceSettings.capture(from: fmtDevice, type: .keyboard)
    checkEqual(fmtSnap.canvasClockFormat, nil, "键盘快照不再携带画板时钟格式")
    checkEqual(fmtSnap.nowPlayingTimeFormat, nil, "键盘快照不再携带页脚时间格式")
    checkEqual(fmtSnap.clockTimeFormat, nil, "键盘快照不再携带时钟卡片格式")
    var fmtTarget = AppSettings()
    fmtTarget.timeFormat = "HH:mm"
    fmtTarget.dateFormat = "M/d"
    fmtSnap.apply(to: fmtTarget, type: .keyboard)
    checkEqual(fmtTarget.timeFormat, "HH:mm", "切换键盘不改动全局时间格式")
    checkEqual(fmtTarget.dateFormat, "M/d", "切换键盘不改动全局日期格式")
    // 旧档案迁移：把用户改过的分界面格式收拢为全局一对
    var legacyFmt = AppSettings()
    legacyFmt.nowPlayingTimeFormat = "HH:mm:ss"
    legacyFmt.canvasDateFormat = "yyyy-MM-dd"
    let fmtNote = legacyFmt.migrateTimeDateFormat()
    check(fmtNote != nil, "旧档案格式迁移有留痕")
    checkEqual(legacyFmt.timeFormat, "HH:mm:ss", "时间格式收拢自正在播放页脚")
    checkEqual(legacyFmt.dateFormat, "yyyy-MM-dd", "日期格式收拢自画板日期")
    checkEqual(legacyFmt.migrateTimeDateFormat(), nil, "格式迁移幂等")
    // 空格式回退默认（不崩溃）
    var blankFmt = AppSettings()
    blankFmt.timeFormat = "   "
    blankFmt.dateFormat = ""
    blankFmt.clamped()
    checkEqual(blankFmt.timeFormat, "HH:mm", "空时间格式回退默认")
    checkEqual(blankFmt.dateFormat, "yyyy年M月d日 EEE", "空日期格式回退默认")
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

    // 正在播放模块空间不足时自动转横向排布（侧边栏式封面居左）：
    // 高条带保持竖排大封面居中；多模块短条带自动横排、封面居左、中部无封面
    func countRedPixels(_ result: RenderResult, _ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>) -> Int {
        let img = result.image
        let w = img.width, h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var count = 0
        for y in ys {
            for x in xs {
                let i = (y * w + x) * 4
                let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                if r > 200 && g < 130 && b < 130 { count += 1 }
            }
        }
        return count
    }
    var tallS = AppSettings()
    tallS.canvasModules = [CanvasModule.nowPlaying.rawValue, CanvasModule.clock.rawValue]
    tallS.canvasNowPlayingCover = true
    tallS.canvasNowPlayingSmartBg = false
    let tallRender = try ScreenRenderer.renderCanvas(modules: tallS.canvasModuleList, system: system,
                                                     nowPlaying: npWithArt, pomodoro: pomodoro,
                                                     customText: "", settings: tallS, now: fixed)
    var shortS = AppSettings()
    shortS.canvasModules = [CanvasModule.nowPlaying.rawValue, CanvasModule.clock.rawValue,
                            CanvasModule.cpu.rawValue, CanvasModule.memory.rawValue,
                            CanvasModule.network.rawValue, CanvasModule.disk.rawValue,
                            CanvasModule.codex.rawValue, CanvasModule.qwenQuota.rawValue]
    shortS.canvasNowPlayingCover = true
    shortS.canvasNowPlayingSmartBg = false
    let shortRender = try ScreenRenderer.renderCanvas(modules: shortS.canvasModuleList, system: system,
                                                      nowPlaying: npWithArt, pomodoro: pomodoro,
                                                      customText: "", settings: shortS, now: fixed)
    let tallCenter = countRedPixels(tallRender, 46...95, 104...200)
    let shortLeft = countRedPixels(shortRender, 19...66, 104...150)
    let shortCenter = countRedPixels(shortRender, 67...95, 104...150)
    check(tallCenter > 200, "高条带应保持竖排大封面居中（red=\(tallCenter)）")
    check(shortLeft > 200, "短条带应自动转横向排布、封面居左（red=\(shortLeft)）")
    check(shortCenter < 5, "短条带横排时中部应无封面（red=\(shortCenter)）")

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
    func renderDeviceImageModes(_ settings: AppSettings) -> CGImage {
        ScreenRenderer.renderDeviceCanvas(modules: [CanvasModule.image, .clock], system: system,
                                          nowPlaying: npWithArt, pomodoro: pomodoro,
                                          customText: "", settings: settings, now: fixed,
                                          width: ScreenRenderer.oracleCanvasSize,
                                          height: ScreenRenderer.oracleCanvasSize,
                                          palette: ScreenThemes.einkMono)
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

    // 自定义图像模块：键盘画板背景 / 叠加两模式渲染应不同；墨水屏画板固定叠加不受模式影响
    s.canvasModules = [CanvasModule.image.rawValue, CanvasModule.clock.rawValue]
    s.customImagePath = path.path
    s.canvasImageMode = .background
    let bgMode = try render()
    checkEqual(bgMode.image.height, 428, "图像背景模式高度")
    check(bgMode.data.count <= ScreenRenderer.maximumFileSize, "图像背景模式大小")
    s.canvasImageMode = .overlay
    let overlayMode = try render()
    check(overlayMode.data.count <= ScreenRenderer.maximumFileSize, "图像叠加模式大小")
    check(bgMode.data != overlayMode.data, "键盘画板背景/叠加两模式渲染应不同")
    // 墨水屏画板：图片模块固定叠加，两种模式设置渲染一致
    s.canvasImageMode = .background
    let einkBG = renderDeviceImageModes(s)
    s.canvasImageMode = .overlay
    let einkOV = renderDeviceImageModes(s)
    check(bitmapEqual(einkBG, einkOV), "墨水屏画板不受图像模式影响")

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
    rt.qwenQuotaBaseline = 2061.9
    rt.qwenQuotaBaselineDay = "2026-08-24"
    rt.qwenQuotaShowPercent = false
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
    checkEqual(decoded.qwenQuotaBaseline, 2061.9, "千问额度基线往返")
    checkEqual(decoded.qwenQuotaBaselineDay, "2026-08-24", "千问额度基线采样日往返")
    checkEqual(decoded.qwenQuotaShowPercent, false, "千问额度显示方式往返")
    checkEqual(AppSettings().qwenQuotaShowPercent, true, "千问额度显示方式默认百分比")

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

    // 显示方式切换：百分比（默认）与额度数值渲染结果应不同
    var valueSettings = settings
    valueSettings.qwenQuotaShowPercent = false
    let rValue = try ScreenRenderer.renderCanvas(modules: settings.canvasModuleList, system: system,
                                                 nowPlaying: np, pomodoro: pomodoro,
                                                 customText: "", settings: valueSettings,
                                                 codex: usage, qwenQuota: quota)
    check(r.data != rValue.data, "千问额度显示方式切换渲染应不同")

    // 额度数值模式：不同额度数值渲染应不同（百分比模式下数值被隐藏，须在数值模式验证）
    var quota2 = quota
    quota2.remainingCredits = 88.5
    var valueSettings2 = valueSettings
    let r3 = try ScreenRenderer.renderCanvas(modules: settings.canvasModuleList, system: system,
                                             nowPlaying: np, pomodoro: pomodoro,
                                             customText: "", settings: valueSettings2,
                                             codex: usage, qwenQuota: quota2)
    check(rValue.data != r3.data, "不同千问额度数值渲染应不同（额度数值模式）")

    // 标头徽标字号：8pt 下「灵犀画板」文字占 x∈[91,123]，徽标行（y 68–86）x∈[90,100] 应出现强调色像素
    // （6pt 时徽标仅占 x∈[99,123]，该区域左侧无强调色；放大后必然命中）
    func badgeAccentCount(_ result: RenderResult) -> Int {
        let img = result.image
        let w = img.width, h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var count = 0
        for y in 68...86 {
            for x in 90...100 {
                let i = (y * w + x) * 4
                let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                if g > 150 && g > r + 20 && g > b { count += 1 }
            }
        }
        return count
    }
    check(badgeAccentCount(r) > 3, "画板标头徽标放大：x∈[90,100] 徽标行应出现强调色像素")

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
    checkEqual(settings.manualCanvasMargin(for: .clock), 20, "手动边距读取")
    settings.setCanvasMargin(99, for: .clock)
    checkEqual(settings.canvasMargin(for: .clock), 40, "边距上界钳制 40")
    // 归零 = 自适应调节模式：移除手动值，回落到该模块默认自适应边距
    settings.setCanvasMargin(0, for: .clock)
    checkEqual(settings.canvasMargin(for: .clock), 2, "边距归零回落到自适应默认 2")
    checkEqual(settings.manualCanvasMargin(for: .clock), 0, "归零后手动值为 0（自适应）")

    // 自适应默认边距：未设置时按模块类型给默认值（用户通常无需手动调节）
    let def = AppSettings()
    checkEqual(def.canvasMargin(for: .clock), 2, "时钟默认边距 2")
    checkEqual(def.canvasMargin(for: .cpu), 4, "CPU 默认边距 4")
    checkEqual(def.canvasMargin(for: .nowPlaying), 6, "正在播放默认边距 6")
    checkEqual(def.canvasMargin(for: .image), 6, "图像默认边距 6")

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
    // 0 = 自适应：编码/解码丢弃显式 0 条目
    let rtZero = AppSettings()
    rtZero.canvasModuleMargins = [0: 0, 2: 30]
    let decodedZero = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(rtZero))
    checkEqual(decodedZero.canvasModuleMargins[0], nil, "边距 0 条目解码时丢弃（自适应）")
    checkEqual(decodedZero.canvasModuleMargins[2], 30, "非零边距保留")
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
    rt.oracleBoardRotationEnabled = true
    rt.oracleBoardRotationMinutes = 12
    rt.excerptAutoPushEnabled = true
    rt.excerptAutoPushMinutes = 90
    rt.excerptBoardRotationEnabled = true
    rt.excerptBoardRotationMinutes = 18
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
    checkEqual(decoded.oracleBoardRotationEnabled, true, "先知画板轮换开关往返")
    checkEqual(decoded.oracleBoardRotationMinutes, 12, "先知画板轮换间隔往返")
    checkEqual(decoded.excerptAutoPushEnabled, true, "摘录定时推送开关往返")
    checkEqual(decoded.excerptAutoPushMinutes, 90, "摘录定时推送间隔往返")
    checkEqual(decoded.excerptBoardRotationEnabled, true, "摘录画板轮换开关往返")
    checkEqual(decoded.excerptBoardRotationMinutes, 18, "摘录画板轮换间隔往返")
    checkEqual(decoded.excerptImageRotate180, true, "摘录旋转 180° 往返")
    checkEqual(decoded.excerptBackgroundMode, .light, "摘录底色模式往返")

    // 定时推送间隔钳制：1 分钟 – 24 小时
    let autoPushClamp = AppSettings()
    autoPushClamp.oracleAutoPushMinutes = 0
    autoPushClamp.oracleBoardRotationMinutes = 99999
    autoPushClamp.excerptAutoPushMinutes = 99999
    autoPushClamp.excerptBoardRotationMinutes = 0
    autoPushClamp.clamped()
    checkEqual(autoPushClamp.oracleAutoPushMinutes, 1, "先知推送间隔下界钳制")
    checkEqual(autoPushClamp.oracleBoardRotationMinutes, 1440, "先知画板轮换间隔上界钳制")
    checkEqual(autoPushClamp.excerptAutoPushMinutes, 1440, "摘录推送间隔上界钳制")
    checkEqual(autoPushClamp.excerptBoardRotationMinutes, 1, "摘录画板轮换间隔下界钳制")

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

    // 显示语录出处：出处查询（有出处的返回来源、谚语/未知语录返回空）、设置往返与默认关闭、开启后渲染替换时钟
    checkEqual(ScreenRenderer.excerptSource(for: "能力越大，责任越大。"), "《蜘蛛侠》", "语录出处查询-电影")
    checkEqual(ScreenRenderer.excerptSource(for: "天生我材必有用，千金散尽还复来。"), "李白《将进酒》", "语录出处查询-诗词")
    checkEqual(ScreenRenderer.excerptSource(for: "走自己的路，让别人说去吧。"), "但丁", "语录出处查询-名人名言")
    check(ScreenRenderer.excerptSource(for: "塞翁失马，焉知非福。") == nil, "谚语无确切出处应返回空")
    check(ScreenRenderer.excerptSource(for: "不存在的语录") == nil, "未知语录出处返回空")
    let sourceRT = AppSettings()
    sourceRT.showExcerptSource = true
    let sourceDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(sourceRT))
    check(sourceDecoded.showExcerptSource, "显示语录出处往返为开启")
    check(!AppSettings().showExcerptSource, "显示语录出处默认关闭")
    let sourceSettings = AppSettings()
    sourceSettings.showExcerptSource = true
    let noSourceCard = try ScreenRenderer.renderExcerptQuote(quote: "能力越大，责任越大。",
                                                             settings: AppSettings(), now: fixed)
    let sourceCard = try ScreenRenderer.renderExcerptQuote(quote: "能力越大，责任越大。",
                                                           settings: sourceSettings, now: fixed)
    checkEqual(sourceCard.image.width, 142, "显示出处语录卡片宽度")
    checkEqual(sourceCard.image.height, 428, "显示出处语录卡片高度")
    check(sourceCard.data.count <= ScreenRenderer.maximumFileSize, "显示出处语录卡片大小")
    check(sourceCard.data != noSourceCard.data, "显示出处应改变语录卡片渲染（出处替换时钟）")

    // 少数派推荐：客户端解析（优先编辑推荐、按推荐时间倒序）+ 卡片渲染 + 模式/设置
    let sspaiJSON = """
    {"list":[
      {"id":3,"title":"未推荐文章","author":{"nickname":"作者丙"}},
      {"id":1,"title":"最新推荐","author":{"nickname":"作者甲"},"recommend_to_home_at":1752000100},
      {"id":2,"title":"较早推荐","author":"作者乙","recommend_to_home_at":1752000000}
    ],"total":3}
    """
    let sspaiParsed = try SspaiClient.parseArticles(Data(sspaiJSON.utf8))
    checkEqual(sspaiParsed.count, 3, "少数派解析：推荐优先 + 最新补齐")
    checkEqual(sspaiParsed.first?.title, "最新推荐", "少数派推荐应按推荐时间倒序")
    checkEqual(sspaiParsed.first?.author, "作者甲", "少数派作者解析")
    checkEqual(sspaiParsed[2].id, 3, "推荐不足时用最新文章补齐（键盘卡片始终够 3 条）")
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
    // GitHub 更新版本比较
    check(GitHubReleaseClient.isNewer(latest: "v1.4.0", than: "1.3.0"), "更新版本比较-新版本")
    check(!GitHubReleaseClient.isNewer(latest: "v1.2.0", than: "1.3.0"), "更新版本比较-旧版本")
    check(!GitHubReleaseClient.isNewer(latest: "v1.3.0", than: "1.3.0"), "更新版本比较-相同版本")
    check(GitHubReleaseClient.isNewer(latest: "1.10.0", than: "1.9.9"), "更新版本比较-多段数值")
    check(GitHubReleaseClient.isNewer(latest: "v2.0", than: "1.3.0"), "更新版本比较-跨主版本")
    // 版本号从重定向后 URL 解析（网页端点 302 → /releases/tag/<版本>）
    checkEqual(GitHubReleaseClient.extractTag(from: URL(string: "https://github.com/XHFO/lingxi-multiscreen/releases/tag/v1.4.0")!),
               "v1.4.0", "解析正常 tag")
    checkEqual(GitHubReleaseClient.extractTag(from: URL(string: "https://github.com/XHFO/lingxi-multiscreen/releases/tag/v1.4.0/")!),
               "v1.4.0", "解析尾斜杠 tag")
    checkEqual(GitHubReleaseClient.extractTag(from: URL(string: "https://github.com/XHFO/lingxi-multiscreen/releases/tag/1.3.1?foo=bar")!),
               "1.3.1", "解析带查询参数 tag")
    check(GitHubReleaseClient.extractTag(from: URL(string: "https://github.com/XHFO/lingxi-multiscreen/releases")!) == nil,
          "无 tag 路径返回 nil")
    check(GitHubReleaseClient.extractTag(from: URL(string: "https://github.com/XHFO/lingxi-multiscreen")!) == nil,
          "仓库主页无 tag 返回 nil")
    checkEqual(GitHubReleaseError.unreachable.errorDescription,
               "无法连接 GitHub，请检查网络。", "网络错误提示文案")
    checkEqual(GitHubReleaseError.invalidResponse.errorDescription,
               "检查过于频繁，请稍后再试。", "限流提示文案")
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

    // 高斯模糊遮罩：底部条带被遮罩改变；遮罩顶缘淡入区上方（Skia y=300，默认字号 bandTop≈314）
    // 像素应与无遮罩完全一致——证明遮罩从上方开始平滑淡入、无硬边覆盖
    let blurFooterOn = AppSettings(); blurFooterOn.emojiWallpaperLayout = .grid; blurFooterOn.nowPlayingFooterVisible = true
    let blurOn = try ScreenRenderer.renderEmojiWallpaper(settings: blurFooterOn, now: fixed)
    let blurFooterOff = AppSettings(); blurFooterOff.emojiWallpaperLayout = .grid; blurFooterOff.nowPlayingFooterVisible = false
    let blurOff = try ScreenRenderer.renderEmojiWallpaper(settings: blurFooterOff, now: fixed)
    let aboveOn = pixelAt(blurOn.image, 71, 300)
    let aboveOff = pixelAt(blurOff.image, 71, 300)
    check(abs(aboveOn.0 - aboveOff.0) < 0.02 && abs(aboveOn.1 - aboveOff.1) < 0.02
          && abs(aboveOn.2 - aboveOff.2) < 0.02,
          "遮罩淡入区上方像素应与无遮罩一致（平滑过渡起点）")
    let bandOn = pixelAt(blurOn.image, 71, 390)
    let bandOff = pixelAt(blurOff.image, 71, 390)
    check(abs(bandOn.0 - bandOff.0) > 0.02 || abs(bandOn.1 - bandOff.1) > 0.02
          || abs(bandOn.2 - bandOff.2) > 0.02,
          "底部条带应被高斯模糊遮罩改变")

    // 页脚文字动态取色：时间/日期/「当前时间」标签文字色从背景采样（颜色不固定），
    // 验证方式：日期行（y≈388–412）带页脚渲染应被文字绘制显著改变（与无页脚渲染像素差异）
    let tintOn = AppSettings()
    tintOn.emojiWallpaperLayout = .grid
    tintOn.emojiWallpaperText = "🔴🟣"
    tintOn.emojiWallpaperSize = 40
    tintOn.nowPlayingFooterVisible = true
    let tintRender = try ScreenRenderer.renderEmojiWallpaper(settings: tintOn, now: fixed)
    tintOn.nowPlayingFooterVisible = false
    let tintOffRender = try ScreenRenderer.renderEmojiWallpaper(settings: tintOn, now: fixed)
    let tintImg = tintRender.image
    let tintCtx = CGContext(data: nil, width: tintImg.width, height: tintImg.height, bitsPerComponent: 8,
                            bytesPerRow: tintImg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    tintCtx.draw(tintImg, in: CGRect(x: 0, y: 0, width: tintImg.width, height: tintImg.height))
    let tp = tintCtx.data!.assumingMemoryBound(to: UInt8.self)
    let tintOffCtx = CGContext(data: nil, width: tintImg.width, height: tintImg.height, bitsPerComponent: 8,
                               bytesPerRow: tintImg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    tintOffCtx.draw(tintOffRender.image, in: CGRect(x: 0, y: 0, width: tintImg.width, height: tintImg.height))
    let top = tintOffCtx.data!.assumingMemoryBound(to: UInt8.self)
    var dateDiff = 0
    for y in 388..<413 {
        for x in 30..<112 {
            let i = (y * tintImg.width + x) * 4
            let dr = abs(Int(tp[i]) - Int(top[i]))
            let dg = abs(Int(tp[i + 1]) - Int(top[i + 1]))
            let db = abs(Int(tp[i + 2]) - Int(top[i + 2]))
            if dr + dg + db > 40 { dateDiff += 1 }
        }
    }
    check(dateDiff > 10, "日期行应被文字绘制改变（动态取色，diff=\(dateDiff)）")

    // 浅色模式下遮罩不加深：带页脚浅色渲染的遮罩带平均亮度应与无页脚渲染相近（无压暗）。
    // 若误加 0.22 压暗，亮度会降到约 78%
    let lightOn = AppSettings()
    lightOn.emojiWallpaperLayout = .grid
    lightOn.emojiWallpaperText = "🔴🟣"
    lightOn.emojiWallpaperSize = 40
    lightOn.backgroundTone = .light
    lightOn.nowPlayingFooterVisible = true
    let lightOnRender = try ScreenRenderer.renderEmojiWallpaper(settings: lightOn, now: fixed)
    lightOn.nowPlayingFooterVisible = false
    let lightOffRender = try ScreenRenderer.renderEmojiWallpaper(settings: lightOn, now: fixed)
    func avgLum(_ img: CGImage, _ y0: Int, _ y1: Int) -> Double {
        let data = img.dataProvider!.data! as Data
        let bpr = img.bytesPerRow
        var sum = 0.0, n = 0.0
        for y in y0..<y1 {
            for x in 4..<138 {
                let i = y * bpr + x * 4
                sum += 0.299 * Double(data[i]) + 0.587 * Double(data[i + 1]) + 0.114 * Double(data[i + 2])
                n += 1
            }
        }
        return sum / n
    }
    let lightBandOn = avgLum(lightOnRender.image, 322, 338)
    let lightBandOff = avgLum(lightOffRender.image, 322, 338)
    // 浅色模式遮罩只轻微压暗（约 0.10 → 亮度 ≈90%）：不低于 85%（排除误用深色 0.22 压暗），
    // 且确实比无遮罩略暗（排除完全不加深）
    check(lightBandOn > lightBandOff * 0.85 && lightBandOn < lightBandOff,
          "浅色模式遮罩应轻微压暗约 10%（on=\(lightBandOn) off=\(lightBandOff)）")

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
    checkEqual(DeviceType.allCases.count, 7, "设备类型数量")
    checkEqual(DeviceType.keyboard.title, "灵犀68 键盘", "设备类型标题-键盘")
    checkEqual(DeviceType.oracle.title, "口袋先知", "设备类型标题-先知")
    checkEqual(DeviceType.excerpt.title, "摘录", "设备类型标题-摘录")
    checkEqual(DeviceType.homeAssistant.title, "Home Assistant", "设备类型标题-HA")
    checkEqual(DeviceType.bambuLab.title, "Bambu Lab 打印机", "设备类型标题-Bambu")
    checkEqual(DeviceType.aiMacScreen.title, "AI Mac 小屏幕", "设备类型标题-AI Mac")

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
    let blankOracleBoard = OracleCanvasBoard.blank(from: source)
    checkEqual(blankOracleBoard.name, "未命名", "先知新画板初始为未命名")
    check(blankOracleBoard.modules.isEmpty, "先知新画板不继承当前功能模块")
    checkEqual(CanvasBoardNamingPolicy.nameAfterAddingFirstModule(
        currentName: blankOracleBoard.name,
        currentModules: blankOracleBoard.modules,
        moduleTitle: CanvasModule.clock.title), "时钟", "首个模块成为画板默认名称")
    checkEqual(CanvasBoardNamingPolicy.nameAfterAddingFirstModule(
        currentName: "用户命名",
        currentModules: [],
        moduleTitle: CanvasModule.clock.title), "用户命名", "首个模块不覆盖用户名称")
    checkEqual(CanvasBoardNamingPolicy.nameAfterAddingFirstModule(
        currentName: "未命名",
        currentModules: [CanvasModule.date.rawValue],
        moduleTitle: CanvasModule.clock.title), "未命名", "已有模块时不再次自动命名")
    var boardB = boardA
    boardB.name = "我的画板"
    boardB.modules = [10, 5]
    boardB.displayMode = .gray4
    let applied = AppSettings()
    boardB.apply(to: applied)
    checkEqual(applied.oracleCanvasModules, [10, 5], "画板套用-模块")
    checkEqual(applied.oracleDisplayMode, .gray4, "画板套用-显示模式")
    // 自动保存：更新配置但保留画板 ID/名称，并覆盖扩展字段（图片、HA 实体、打印机选项）。
    let oracleAutoSettings = AppSettings()
    oracleAutoSettings.oracleCanvasModules = [CanvasModule.clock.rawValue]
    var oracleAutoBoard = OracleCanvasBoard.capture(from: oracleAutoSettings)
    oracleAutoBoard.name = "常驻状态"
    oracleAutoBoard.sidebarVisible = false
    oracleAutoBoard.rotationEnabled = false
    let oracleAutoID = oracleAutoBoard.id
    oracleAutoSettings.oracleCanvasModules = [CanvasModule.homeAssistant.rawValue]
    oracleAutoSettings.oracleCanvasHAEntityIDs = ["sensor.oracle"]
    oracleAutoSettings.oracleCanvasImagePath = "/oracle-auto.png"
    oracleAutoSettings.oracleCanvasPrinterFields = [
        CanvasModule.bambuLab.rawValue: CanvasPrinterFields(showTask: true)
    ]
    oracleAutoBoard = oracleAutoBoard.updatingConfiguration(from: oracleAutoSettings)
    checkEqual(oracleAutoBoard.id, oracleAutoID, "先知画板自动保存保留 ID")
    checkEqual(oracleAutoBoard.name, "常驻状态", "先知画板自动保存保留名称")
    checkEqual(oracleAutoBoard.isSidebarVisible, false, "先知画板自动保存保留侧栏隐藏状态")
    checkEqual(oracleAutoBoard.participatesInRotation, false, "先知画板自动保存保留轮播关闭状态")
    checkEqual(oracleAutoBoard.modules, [CanvasModule.homeAssistant.rawValue],
               "先知画板自动保存更新模块")
    checkEqual(oracleAutoBoard.haEntityIDs, ["sensor.oracle"], "先知画板自动保存 HA 实体")
    checkEqual(oracleAutoBoard.imagePath, "/oracle-auto.png", "先知画板自动保存图片")
    let oracleAutoApplied = AppSettings()
    oracleAutoBoard.apply(to: oracleAutoApplied)
    checkEqual(oracleAutoApplied.oracleCanvasHAEntityIDs, ["sensor.oracle"],
               "先知画板扩展字段可恢复")
    // 设备快照捕获/套用包含画板列表与下标
    source.oracleCanvasBoards = [boardA, boardB]
    source.oracleCanvasBoardIndex = 1
    source.oracleBoardRotationEnabled = true
    source.oracleBoardRotationMinutes = 8
    let oraCap2 = DeviceSettings.capture(from: source, type: .oracle)
    checkEqual(oraCap2.oracleCanvasBoards?.count, 2, "设备快照-画板数量")
    checkEqual(oraCap2.oracleCanvasBoardIndex, 1, "设备快照-画板下标")
    checkEqual(oraCap2.oracleBoardRotationEnabled, true, "设备快照-画板轮换开关")
    checkEqual(oraCap2.oracleBoardRotationMinutes, 8, "设备快照-画板轮换间隔")
    let oraTarget2 = AppSettings()
    oraCap2.apply(to: oraTarget2, type: .oracle)
    checkEqual(oraTarget2.oracleCanvasBoards.count, 2, "设备套用-画板数量")
    checkEqual(oraTarget2.oracleCanvasBoardIndex, 1, "设备套用-画板下标")
    checkEqual(oraTarget2.oracleBoardRotationEnabled, true, "设备套用-画板轮换开关")
    checkEqual(oraTarget2.oracleBoardRotationMinutes, 8, "设备套用-画板轮换间隔")
    checkEqual(oraTarget2.oracleCanvasBoards[1].modules, [10, 5], "设备套用-画板内容")
    // 旧设备快照没有新字段时回退默认关闭，不能沿用上一台先知的轮换设置。
    let legacyOracleSnapshot = DeviceSettings()
    let legacyOracleTarget = AppSettings()
    legacyOracleTarget.oracleBoardRotationEnabled = true
    legacyOracleTarget.oracleBoardRotationMinutes = 99
    legacyOracleSnapshot.apply(to: legacyOracleTarget, type: .oracle)
    checkEqual(legacyOracleTarget.oracleBoardRotationEnabled, false, "旧先知快照默认关闭画板轮换")
    checkEqual(legacyOracleTarget.oracleBoardRotationMinutes, 5, "旧先知快照使用默认轮换间隔")
    // 编码往返
    let boardRT = AppSettings()
    boardRT.oracleCanvasBoards = [boardB]
    boardRT.oracleCanvasBoardIndex = 0
    let boardDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(boardRT))
    checkEqual(boardDecoded.oracleCanvasBoards.count, 1, "画板编码往返")
    checkEqual(boardDecoded.oracleCanvasBoards[0].name, "我的画板", "画板编码往返-名称")
    checkEqual(boardDecoded.oracleCanvasBoardIndex, 0, "画板下标往返")
    var hiddenBoard = boardB
    hiddenBoard.sidebarVisible = false
    hiddenBoard.rotationEnabled = false
    let hiddenDecoded = try JSONDecoder().decode(
        OracleCanvasBoard.self, from: JSONEncoder().encode(hiddenBoard))
    checkEqual(hiddenDecoded.isSidebarVisible, false, "画板侧栏隐藏状态编码往返")
    checkEqual(hiddenDecoded.participatesInRotation, false, "画板轮播关闭状态编码往返")
    // 旧版本画板不含两个管理字段时默认仍显示并参与轮播，升级后不会让已有画板消失。
    var legacyBoardObject = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(boardB)) as! [String: Any]
    legacyBoardObject.removeValue(forKey: "sidebarVisible")
    legacyBoardObject.removeValue(forKey: "rotationEnabled")
    let legacyBoardData = try JSONSerialization.data(withJSONObject: legacyBoardObject)
    let legacyBoardDecoded = try JSONDecoder().decode(OracleCanvasBoard.self, from: legacyBoardData)
    checkEqual(legacyBoardDecoded.isSidebarVisible, true, "旧画板默认显示在侧栏")
    checkEqual(legacyBoardDecoded.participatesInRotation, true, "旧画板默认参与轮播")
    let oracleProfileA = AppSettings()
    oracleProfileA.oracleCanvasBoards = [boardA]
    let oracleProfileB = AppSettings()
    oracleProfileB.oracleCanvasBoards = [hiddenBoard]
    let oracleDeviceA = DeviceSettings.capture(from: oracleProfileA, type: .oracle)
    let oracleDeviceB = DeviceSettings.capture(from: oracleProfileB, type: .oracle)
    let oracleSwitchMirror = AppSettings()
    oracleDeviceA.apply(to: oracleSwitchMirror, type: .oracle)
    checkEqual(oracleSwitchMirror.oracleCanvasBoards[0].isSidebarVisible, true,
               "口袋先知 A 保留自己的侧栏画板")
    oracleDeviceB.apply(to: oracleSwitchMirror, type: .oracle)
    checkEqual(oracleSwitchMirror.oracleCanvasBoards[0].isSidebarVisible, false,
               "切换口袋先知 B 后使用自己的隐藏设置，不串用 A")
    checkEqual(oracleSwitchMirror.oracleCanvasBoards[0].participatesInRotation, false,
               "口袋先知 B 的轮播选择独立")
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

    // 画板图像模块独立图片：先知/摘录各自独立，与键盘自定义图片解耦
    let imgSource = AppSettings()
    imgSource.customImagePath = "/kbd.png"
    imgSource.oracleCanvasImagePath = "/oracle.png"
    imgSource.oracleCanvasImageName = "先知图"
    imgSource.excerptCanvasImagePath = "/excerpt.png"
    let oraImgCap = DeviceSettings.capture(from: imgSource, type: .oracle)
    checkEqual(oraImgCap.canvasImagePath, "/oracle.png", "先知画板图片独立捕获")
    checkEqual(oraImgCap.canvasImageName, "先知图", "先知画板图片名捕获")
    let exImgCap = DeviceSettings.capture(from: imgSource, type: .excerpt)
    checkEqual(exImgCap.canvasImagePath, "/excerpt.png", "摘录画板图片独立捕获")
    let imgTarget = AppSettings()
    oraImgCap.apply(to: imgTarget, type: .oracle)
    checkEqual(imgTarget.oracleCanvasImagePath, "/oracle.png", "先知画板图片独立套用")
    check(imgTarget.customImagePath == nil, "先知画板图片不影响键盘自定义图片")
    let imgRT = AppSettings()
    imgRT.oracleCanvasImagePath = "/o.png"
    let imgDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(imgRT))
    checkEqual(imgDecoded.oracleCanvasImagePath, "/o.png", "先知画板图片编码往返")
    let exCap = DeviceSettings.capture(from: source, type: .excerpt)
    checkEqual(exCap.excerptCanvasModules, [13, 0], "摘录快照-模块")
    checkEqual(exCap.excerptPushRawImage, true, "摘录快照-原始推送")
    let exTarget = AppSettings()
    exCap.apply(to: exTarget, type: .excerpt)
    checkEqual(exTarget.excerptCanvasModules, [13, 0], "摘录套用-模块")
    checkEqual(exTarget.excerptPushRawImage, true, "摘录套用-原始推送")

    // 摘录多画板：完整配置捕获/套用、持久化与多设备隔离。
    let excerptBoardSource = AppSettings()
    excerptBoardSource.excerptCanvasModules = [CanvasModule.excerptText.rawValue,
                                               CanvasModule.homeAssistant.rawValue]
    excerptBoardSource.excerptBackgroundMode = .dark
    excerptBoardSource.excerptImageRotate180 = true
    excerptBoardSource.excerptLayoutColumns = 2
    excerptBoardSource.excerptFullWidthModules = [CanvasModule.excerptText.rawValue]
    excerptBoardSource.excerptPushRawImage = true
    excerptBoardSource.excerptServerDitherType = .diffusion
    excerptBoardSource.excerptServerDitherKernel = .atkinson
    excerptBoardSource.excerptDisplayMode = .bw
    excerptBoardSource.excerptSspaiCount = 6
    excerptBoardSource.excerptSspaiRandom = true
    excerptBoardSource.excerptNowPlayingHorizontal = true
    excerptBoardSource.excerptCanvasHAEntityIDs = ["sensor.room_a"]
    excerptBoardSource.excerptCanvasImagePath = "/excerpt-a.png"
    excerptBoardSource.excerptCanvasImageName = "设备 A 图片"
    excerptBoardSource.excerptQuoteCategories = [ExcerptQuoteCategory.famousSayings.rawValue]
    excerptBoardSource.showExcerptSource = true
    excerptBoardSource.excerptCanvasPrinterFields = [
        CanvasModule.bambuLab.rawValue: CanvasPrinterFields(showTask: true, showImage: true)
    ]
    var excerptBoardA = ExcerptCanvasBoard.capture(from: excerptBoardSource)
    excerptBoardA.name = "设备 A · 状态板"
    let blankExcerptBoard = ExcerptCanvasBoard.blank(from: excerptBoardSource)
    checkEqual(blankExcerptBoard.name, "未命名", "摘录新画板初始为未命名")
    check(blankExcerptBoard.modules.isEmpty, "摘录新画板不继承当前功能模块")
    check(blankExcerptBoard.fullWidthModules.isEmpty, "摘录空画板不保留已移除模块的跨列布局")
    check(blankExcerptBoard.isSidebarVisible, "摘录新画板默认显示在侧边栏")
    check(blankExcerptBoard.participatesInRotation, "摘录新画板默认参加自动轮播")
    checkEqual(excerptBoardA.layoutColumns, 2, "摘录画板捕获布局")
    checkEqual(excerptBoardA.haEntityIDs, ["sensor.room_a"], "摘录画板捕获 HA 实体")
    checkEqual(excerptBoardA.imagePath, "/excerpt-a.png", "摘录画板捕获独立图片")
    checkEqual(excerptBoardA.printerFields[CanvasModule.bambuLab.rawValue]?.showImage, true,
               "摘录画板捕获打印机显示项")
    let excerptBoardApplied = AppSettings()
    excerptBoardA.apply(to: excerptBoardApplied)
    checkEqual(excerptBoardApplied.excerptCanvasModules, excerptBoardA.modules, "摘录画板套用模块")
    checkEqual(excerptBoardApplied.excerptLayoutColumns, 2, "摘录画板套用布局")
    checkEqual(excerptBoardApplied.excerptCanvasHAEntityIDs, ["sensor.room_a"], "摘录画板套用 HA 实体")
    checkEqual(excerptBoardApplied.excerptCanvasImageName, "设备 A 图片", "摘录画板套用图片名")
    checkEqual(excerptBoardApplied.showExcerptSource, true, "摘录画板套用语录出处")
    let excerptAutoID = excerptBoardA.id
    excerptBoardSource.excerptCanvasModules = [CanvasModule.date.rawValue]
    let excerptAutoBoard = excerptBoardA.updatingConfiguration(from: excerptBoardSource)
    checkEqual(excerptAutoBoard.id, excerptAutoID, "摘录画板自动保存保留 ID")
    checkEqual(excerptAutoBoard.name, "设备 A · 状态板", "摘录画板自动保存保留名称")
    checkEqual(excerptAutoBoard.modules, [CanvasModule.date.rawValue], "摘录画板自动保存更新模块")
    check(excerptAutoBoard.isSidebarVisible, "摘录画板自动保存保留侧栏显示状态")
    check(excerptAutoBoard.participatesInRotation, "摘录画板自动保存保留轮播状态")
    var hiddenExcerptBoard = excerptBoardA
    hiddenExcerptBoard.sidebarVisible = false
    hiddenExcerptBoard.rotationEnabled = false
    let hiddenExcerptUpdate = hiddenExcerptBoard.updatingConfiguration(from: excerptBoardSource)
    checkEqual(hiddenExcerptUpdate.isSidebarVisible, false, "摘录画板自动保存保留侧栏隐藏状态")
    checkEqual(hiddenExcerptUpdate.participatesInRotation, false, "摘录画板自动保存保留轮播关闭状态")
    var legacyExcerptBoard = excerptBoardA
    legacyExcerptBoard.sidebarVisible = nil
    legacyExcerptBoard.rotationEnabled = nil
    check(legacyExcerptBoard.isSidebarVisible, "旧摘录画板默认显示在侧边栏")
    check(legacyExcerptBoard.participatesInRotation, "旧摘录画板默认参加自动轮播")

    var excerptBoardB = excerptBoardA
    excerptBoardB.id = UUID()
    excerptBoardB.name = "设备 B · 极简板"
    excerptBoardB.modules = [CanvasModule.clock.rawValue]
    excerptBoardB.haEntityIDs = ["sensor.room_b"]
    excerptBoardB.imagePath = "/excerpt-b.png"
    excerptBoardB.imageName = "设备 B 图片"
    excerptBoardB.layoutColumns = 1
    excerptBoardB.showQuoteSource = false

    let excerptDeviceASettings = AppSettings()
    excerptBoardA.apply(to: excerptDeviceASettings)
    excerptDeviceASettings.excerptCanvasBoards = [excerptBoardA]
    excerptDeviceASettings.excerptCanvasBoardIndex = 0
    excerptDeviceASettings.excerptBoardRotationEnabled = true
    excerptDeviceASettings.excerptBoardRotationMinutes = 11
    let excerptDeviceBSettings = AppSettings()
    excerptBoardB.apply(to: excerptDeviceBSettings)
    excerptDeviceBSettings.excerptCanvasBoards = [excerptBoardB]
    excerptDeviceBSettings.excerptCanvasBoardIndex = 0
    let excerptAID = UUID()
    let excerptBID = UUID()
    var excerptDeviceA = ManagedDevice(type: .excerpt, name: "摘录 A",
                                       settings: DeviceSettings.capture(from: excerptDeviceASettings,
                                                                        type: .excerpt))
    excerptDeviceA.id = excerptAID
    var excerptDeviceB = ManagedDevice(type: .excerpt, name: "摘录 B",
                                       settings: DeviceSettings.capture(from: excerptDeviceBSettings,
                                                                        type: .excerpt))
    excerptDeviceB.id = excerptBID
    let excerptScoped = AppSettings()
    excerptScoped.devices = [excerptDeviceA, excerptDeviceB]
    excerptScoped.activeExcerptDeviceID = excerptAID
    excerptDeviceA.settings.apply(to: excerptScoped, type: .excerpt)
    excerptScoped.captureActiveDeviceSnapshots()
    checkEqual(excerptScoped.excerptCanvasBoards.first?.name, "设备 A · 状态板",
               "摘录设备 A 初始画板")
    check(excerptScoped.switchActiveDevice(of: .excerpt, to: excerptBID) != nil,
          "摘录多画板切换到设备 B")
    checkEqual(excerptScoped.excerptCanvasBoards.first?.name, "设备 B · 极简板",
               "设备 B 只加载自己的画板")
    checkEqual(excerptScoped.excerptCanvasModules, [CanvasModule.clock.rawValue],
               "设备 B 当前画布随快照恢复")
    checkEqual(excerptScoped.excerptCanvasHAEntityIDs, ["sensor.room_b"],
               "设备 B 画板实体不继承设备 A")
    check(excerptScoped.switchActiveDevice(of: .excerpt, to: excerptAID) != nil,
          "摘录多画板切回设备 A")
    checkEqual(excerptScoped.excerptCanvasBoards.first?.name, "设备 A · 状态板",
               "A→B→A 后设备 A 画板未串扰")
    checkEqual(excerptScoped.excerptCanvasHAEntityIDs, ["sensor.room_a"],
               "A→B→A 后 HA 实体未串扰")

    let excerptRoundTrip = try JSONDecoder().decode(AppSettings.self,
                                                     from: JSONEncoder().encode(excerptScoped))
    checkEqual(excerptRoundTrip.devices.first { $0.id == excerptAID }?
        .settings.excerptCanvasBoards?.first?.name, "设备 A · 状态板",
               "摘录设备 A 画板持久化")
    checkEqual(excerptRoundTrip.devices.first { $0.id == excerptAID }?
        .settings.excerptBoardRotationEnabled, true, "摘录设备 A 轮播开关持久化")
    checkEqual(excerptRoundTrip.devices.first { $0.id == excerptAID }?
        .settings.excerptBoardRotationMinutes, 11, "摘录设备 A 轮播间隔持久化")
    checkEqual(excerptRoundTrip.devices.first { $0.id == excerptBID }?
        .settings.excerptCanvasBoards?.first?.name, "设备 B · 极简板",
               "摘录设备 B 画板持久化")
    let legacyExcerptSnapshot = DeviceSettings()
    let legacyExcerptTarget = AppSettings()
    legacyExcerptTarget.excerptCanvasBoards = [excerptBoardA]
    legacyExcerptTarget.excerptCanvasBoardIndex = 9
    legacyExcerptSnapshot.apply(to: legacyExcerptTarget, type: .excerpt)
    check(legacyExcerptTarget.excerptCanvasBoards.isEmpty,
          "旧摘录设备快照不会沿用上一台设备的画板")
    checkEqual(legacyExcerptTarget.excerptCanvasBoardIndex, 0, "旧摘录设备画板下标归零")
    checkEqual(legacyExcerptTarget.excerptBoardRotationEnabled, false,
               "旧摘录设备快照默认关闭画板轮播")
    checkEqual(legacyExcerptTarget.excerptBoardRotationMinutes, 5,
               "旧摘录设备快照使用默认轮播间隔")
    let excerptClamp = AppSettings()
    var invalidExcerptBoard = excerptBoardA
    invalidExcerptBoard.modules = [CanvasModule.clock.rawValue, 999]
    invalidExcerptBoard.fullWidthModules = [CanvasModule.clock.rawValue, 999]
    invalidExcerptBoard.layoutColumns = 8
    invalidExcerptBoard.haEntityIDs = ["sensor.a", "", "sensor.a"]
    invalidExcerptBoard.quoteCategories = [ExcerptQuoteCategory.famousSayings.rawValue, 999,
                                            ExcerptQuoteCategory.famousSayings.rawValue]
    excerptClamp.excerptCanvasBoards = [invalidExcerptBoard]
    excerptClamp.excerptCanvasBoardIndex = 8
    excerptClamp.clamped()
    checkEqual(excerptClamp.excerptCanvasBoards[0].modules, [CanvasModule.clock.rawValue],
               "摘录画板清理无效模块")
    checkEqual(excerptClamp.excerptCanvasBoards[0].layoutColumns, 2, "摘录画板列数钳制")
    checkEqual(excerptClamp.excerptCanvasBoards[0].haEntityIDs, ["sensor.a"],
               "摘录画板 HA 实体去空去重")
    checkEqual(excerptClamp.excerptCanvasBoardIndex, 0, "摘录画板下标钳制")

    // ManagedDevice 编码往返
    let device = ManagedDevice(type: .excerpt, name: "书房摘录",
                               settings: DeviceSettings.capture(from: source, type: .excerpt))
    let data = try JSONEncoder().encode(device)
    let decoded = try JSONDecoder().decode(ManagedDevice.self, from: data)
    checkEqual(decoded.name, "书房摘录", "设备名往返")
    checkEqual(decoded.type, .excerpt, "设备类型往返")
    checkEqual(decoded.settings.excerptCanvasModules, [13, 0], "设备设置往返")
    checkEqual(ManagedDevice.defaultName(for: .keyboard, index: 0), "灵犀68 键盘 1", "默认设备名")
    var renamedPrinter = ManagedDevice(type: .bambuLab, name: "打印机 1", settings: DeviceSettings())
    renamedPrinter.rename(to: "")
    checkEqual(renamedPrinter.name, "", "编辑打印机名清空时不应回填默认名")
    renamedPrinter.rename(to: "  工作室 X1C  ")
    checkEqual(renamedPrinter.name, "  工作室 X1C  ", "编辑打印机名时应原样保留输入")
    let haEntryModes: Set<DisplayMode> = [.homeAssistant, .bambuLab, .bambuLab2, .bambuLab3,
                                          .bambuLab4, .bambuLab5]
    for mode in DisplayMode.allCases {
        checkEqual(mode.refreshesHomeAssistantOnEntry, haEntryModes.contains(mode),
                   "HA 即时刷新入口策略-\(mode.title)")
    }
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
    check(DeviceOnboardingPolicy.shouldShow(for: fresh.devices), "全新配置应进入设备添加引导")
    check(fresh.endpoint.isEmpty, "全新配置不应包含键盘地址")
    check(fresh.rand0IP.isEmpty, "全新配置不应包含口袋先知地址")
    check(fresh.dotApiKey.isEmpty && fresh.dotDeviceId.isEmpty, "全新配置不应包含摘录凭据")
    check(fresh.haServerURL.isEmpty && fresh.haToken.isEmpty, "全新配置不应包含 HA 连接参数")
    check(fresh.haEntities.isEmpty, "全新配置不应包含 HA 测试实体")
    check(fresh.customImagePath == nil && fresh.customImageHistory.isEmpty,
          "全新配置不应包含测试图片或历史记录")
    check(!UsageSnapshot.empty.isAvailable, "Codex 正式初始状态不应使用示例数据")
    check(!QwenWorkQuota.unavailable.available, "千问正式初始状态不应使用示例额度")
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
    check(!DeviceOnboardingPolicy.shouldShow(for: reloaded.devices), "已有设备时不应显示首次添加引导")

    // 从完全不存在的数据目录加载：必须得到空白设置，且不能生成或迁入测试参数。
    let virginBase = FileManager.default.temporaryDirectory
        .appendingPathComponent("linx-virgin-release-test-\(UUID().uuidString)")
    let virginStore = SettingsStore(dataDirectory: virginBase)
    let virgin = virginStore.load()
    check(virgin.devices.isEmpty, "发布版全新数据目录应为 0 台设备")
    check(virgin.endpoint.isEmpty && virgin.rand0IP.isEmpty,
          "发布版全新数据目录不应带设备地址")
    check(virgin.dotApiKey.isEmpty && virgin.dotDeviceId.isEmpty
          && virgin.haServerURL.isEmpty && virgin.haToken.isEmpty,
          "发布版全新数据目录不应带任何连接凭据")
    check(DeviceOnboardingPolicy.shouldShow(for: virgin.devices),
          "发布版全新数据目录应触发设备添加引导")

    // 恢复初始设定：设置/番茄钟/自定义图片/图片缓存移入废纸篓，重新加载为全新默认
    let resetBase = FileManager.default.temporaryDirectory.appendingPathComponent("linx-reset-test-\(UUID().uuidString)")
    let resetStore = SettingsStore(dataDirectory: resetBase)
    let resetSettings = AppSettings()
    resetSettings.devices = [tmpDevice]
    resetSettings.customImagePath = "/tmp/测试图.png"
    resetStore.save(resetSettings)
    try FileManager.default.createDirectory(at: resetStore.historyDirectory, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: resetStore.historyDirectory.appendingPathComponent("hist.png"))
    try Data([4, 5]).write(to: resetStore.customImageURL)
    resetStore.saveFormlabsTaskCache([
        UUID(): FormlabsSnapshot(print: FormlabsPrintInfo(name: "发布前缓存清理测试"))
    ])
    check(FileManager.default.fileExists(atPath: resetStore.settingsURL.path), "重置前设置文件存在")
    check(FileManager.default.fileExists(atPath: resetStore.customImageURL.path), "重置前自定义图片存在")
    check(FileManager.default.fileExists(atPath: resetStore.historyDirectory.path), "重置前图片缓存存在")
    check(FileManager.default.fileExists(atPath: resetStore.formlabsTaskCacheURL.path),
          "重置前 Formlabs 最近任务缓存存在")
    let resetTrash = resetBase.appendingPathComponent("trash")
    resetStore.resetAllData(trashRoot: resetTrash)
    check(!FileManager.default.fileExists(atPath: resetStore.settingsURL.path), "重置后设置文件已清除")
    check(!FileManager.default.fileExists(atPath: resetStore.customImageURL.path), "重置后自定义图片已清除")
    check(!FileManager.default.fileExists(atPath: resetStore.historyDirectory.path), "重置后图片缓存目录已清除")
    check(!FileManager.default.fileExists(atPath: resetStore.formlabsTaskCacheURL.path),
          "重置后 Formlabs 最近任务缓存已清除")
    let resetReloaded = resetStore.load()
    check(resetReloaded.devices.isEmpty, "重置后重新加载为全新默认（无设备）")
    check(resetReloaded.customImagePath == nil, "重置后自定义图片路径已清空")
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
    checkEqual(clamp.sidebarWidth, 320, "侧边栏宽度上界钳制")
    clamp.sidebarWidth = 20
    clamp.clamped()
    checkEqual(clamp.sidebarWidth, 48, "侧边栏宽度下界钳制")
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
        await testRand0SessionLifecycle()
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
        try testPomodoroCentering()
        try testGlobalShortcuts()
        try testHomeAssistant()
        try testFormlabs()
        try testAIMacScreen()
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

// MARK: - AI Mac 240×240 小屏幕

func testAIMacScreen() throws {
    check(DeviceType.allCases.contains(.aiMacScreen), "AI Mac 小屏幕设备类型存在")
    checkEqual(DeviceType.aiMacScreen.title, "AI Mac 小屏幕", "AI Mac 小屏幕设备标题")
    checkEqual(ManagedDevice.defaultName(for: .aiMacScreen, index: 0),
               "AI Mac 小屏幕 1", "AI Mac 小屏幕默认名称")
    checkEqual(AIMacScreenDeviceSettings().mode, .canvas,
               "新 AI Mac 小屏幕默认进入彩色画板模式")

    checkEqual(EmbeddedAIMacFirmware.version, "0.8.1-wifi-portal-fix",
               "内置小屏幕固件版本稳定")
    checkEqual(EmbeddedAIMacFirmware.flashAddress, "0x0",
               "ESP8266 固件写入地址稳定")
    check(!EmbeddedAIMacFirmware.validate(Data()), "空数据不能通过固件完整性校验")
    let provisionImage = try AIMacWiFiProvisioning.makeImage(
        ssid: "Lingxi-2.4G", password: "test-only-password")
    checkEqual(provisionImage.count, 4096, "Wi-Fi 配网区固定为一个 4KB 扇区")
    check(AIMacWiFiProvisioning.validateImage(provisionImage),
          "Wi-Fi 配网区格式与 CRC 校验通过")
    checkEqual(AIMacWiFiProvisioning.flashAddress, "0x100000",
               "Wi-Fi 配网区写入地址稳定")
    do {
        _ = try AIMacWiFiProvisioning.makeImage(ssid: "", password: "12345678")
        check(false, "空 SSID 必须被拒绝")
    } catch {
        checkEqual(error as? AIMacWiFiProvisioningError, .emptySSID,
                   "空 SSID 返回明确错误")
    }
    do {
        _ = try AIMacWiFiProvisioning.makeImage(ssid: "Home", password: "short")
        check(false, "过短 Wi-Fi 密码必须被拒绝")
    } catch {
        checkEqual(error as? AIMacWiFiProvisioningError, .invalidPasswordLength,
                   "过短 Wi-Fi 密码返回明确错误")
    }
    let flashLog = "Chip is ESP8266EX\nMAC: 84:f3:eb:12:34:56\nWriting at 0x00000000"
    let parsedMAC = AIMacWiFiProvisioning.macAddress(in: flashLog)
    checkEqual(parsedMAC, "84:f3:eb:12:34:56", "从 esptool 日志读取芯片 MAC")
    checkEqual(parsedMAC.flatMap(AIMacWiFiProvisioning.hostname(forMAC:)),
               "lingxi-aimac-123456", "由 MAC 推导唯一 mDNS 主机名")
    let discoveredInfo = """
    {"device":"esp8266-ai-screen","ip":"192.168.31.88"}
    """.data(using: .utf8)!
    checkEqual(AIMacScreenDiscovery.discoveredIP(from: discoveredInfo),
               "192.168.31.88", "从设备能力接口读取自动发现 IP")
    let ports = ESP8266FirmwareFlasher.serialPorts(in: [
        "cu.usbserial-11440", "cu.wchusbserial1420", "cu.SLAB_USBtoUART",
        "cu.usbmodem2101", "cu.CH341", "cu.cp210-test",
        "cu.Bluetooth-Incoming-Port", "cu.debug-console", "tty.usbserial-ignored"
    ])
    checkEqual(Set(ports.map(\.path)), Set([
        "/dev/cu.usbserial-11440", "/dev/cu.wchusbserial1420",
        "/dev/cu.SLAB_USBtoUART", "/dev/cu.usbmodem2101",
        "/dev/cu.CH341", "/dev/cu.cp210-test"
    ]), "刷机串口只保留支持的 USB 设备")

    checkEqual(AIMacScreenSupport.normalizedHost(" http://192.168.1.66/path "),
               "192.168.1.66", "小屏幕地址去协议与路径")
    checkEqual(AIMacScreenSupport.normalizedHost("https://screen.local/"),
               "screen.local", "小屏幕域名地址标准化")

    let rgbInfo = """
    {"device":"esp8266-ai-screen","screen":{"width":240,"height":240},
     "rgb565_api":{"path":"/frame/rgb565","content_type":"application/x-rgb565",
     "byte_order":"big-endian","bytes":115200}}
    """.data(using: .utf8)!
    let rgbCapabilities = try AIMacScreenSupport.parseCapabilities(
        data: rgbInfo, host: "192.168.1.66")
    check(rgbCapabilities.supportsLosslessRGB565, "能力接口识别 RGB565 无损模式")
    checkEqual(rgbCapabilities.rgb565UploadURL?.path, "/frame/rgb565",
               "能力接口使用固件声明的 RGB565 路径")

    let jpegInfo = """
    {"device":"esp8266-ai-screen","screen":{"width":240,"height":240}}
    """.data(using: .utf8)!
    let jpegCapabilities = try AIMacScreenSupport.parseCapabilities(
        data: jpegInfo, host: "screen.local")
    check(!jpegCapabilities.supportsLosslessRGB565, "旧固件能力信息回退 JPEG")
    checkEqual(jpegCapabilities.jpegUploadURL.path, "/image/upload",
               "JPEG 兼容上传路径稳定")

    var stored = AIMacScreenDeviceSettings(host: "10.0.0.8", mode: .clock,
                                           autoPush: false, pushIntervalSeconds: 9,
                                           jpegQuality: 71)
    var fields = DeviceSettings()
    fields.aiMacScreen = stored
    var managed = ManagedDevice(type: .aiMacScreen, name: "桌面圆屏", settings: fields)
    let encodedDevice = try JSONEncoder().encode(managed)
    let decodedDevice = try JSONDecoder().decode(ManagedDevice.self, from: encodedDevice)
    checkEqual(decodedDevice.settings.aiMacScreen, stored, "小屏幕设备设置 JSON 往返")

    stored.host = "10.0.0.9"
    var fields2 = DeviceSettings()
    fields2.aiMacScreen = stored
    let managed2 = ManagedDevice(type: .aiMacScreen, name: "副屏", settings: fields2)
    checkEqual(managed.settings.aiMacScreen?.host, "10.0.0.8", "第一台小屏幕连接设置独立")
    checkEqual(managed2.settings.aiMacScreen?.host, "10.0.0.9", "第二台小屏幕连接设置独立")
    managed.settings.aiMacScreen = AIMacScreenDeviceSettings()
    checkEqual(managed.settings.aiMacScreen?.host, "", "新小屏幕默认不继承测试地址")

    var aiBoard = AIMacCanvasBoard(modules: [CanvasModule.clock.rawValue,
                                             CanvasModule.cpu.rawValue,
                                             CanvasModule.clock.rawValue],
                                   backgroundMode: .light,
                                   haEntityIDs: ["sensor.room", "sensor.room", ""])
    aiBoard.clamp()
    checkEqual(aiBoard.moduleList, [.clock, .cpu], "AI Mac 画板模块去重且保持顺序")
    checkEqual(aiBoard.haEntityIDs, ["sensor.room"], "AI Mac 画板实体去空去重")
    check(aiBoard.isSidebarVisible && aiBoard.participatesInRotation,
          "AI Mac 新画板默认显示在侧栏并参与轮播")
    check(aiBoard.usesNowPlayingSmartBackground,
          "AI Mac 新彩色画板默认启用专辑封面取色背景")
    let aiCanvasConfig = AIMacScreenDeviceSettings(
        host: "10.0.0.20", mode: .canvas, canvasBoards: [aiBoard],
        boardRotationEnabled: true, boardRotationMinutes: 8)
    let aiCanvasRoundTrip = try JSONDecoder().decode(
        AIMacScreenDeviceSettings.self, from: JSONEncoder().encode(aiCanvasConfig))
    checkEqual(aiCanvasRoundTrip, aiCanvasConfig, "AI Mac 多画板配置 JSON 往返")

    let legacyAIMacConfig = """
    {"host":"10.0.0.8","mode":"clock","autoPush":true,
     "pushIntervalSeconds":2,"jpegQuality":82}
    """.data(using: .utf8)!
    let migratedAIMacConfig = try JSONDecoder().decode(
        AIMacScreenDeviceSettings.self, from: legacyAIMacConfig)
    checkEqual(migratedAIMacConfig.mode, .clock, "旧 AI Mac 显示模式保持不变")
    check(migratedAIMacConfig.canvasBoards.isEmpty,
          "旧 AI Mac 配置缺少画板字段时可安全迁移为空列表")

    let legacyAIMacBoard = """
    {"id":"\(UUID().uuidString)","name":"旧彩色画板","modules":[6],
     "backgroundMode":0,"sspaiCount":3,"sspaiRandom":false,
     "nowPlayingHorizontal":false,"printerFields":{},"haEntityIDs":[]}
    """.data(using: .utf8)!
    let migratedAIMacBoard = try JSONDecoder().decode(AIMacCanvasBoard.self,
                                                       from: legacyAIMacBoard)
    check(migratedAIMacBoard.usesNowPlayingSmartBackground,
          "旧 AI Mac 画板缺少取色字段时默认启用")

    let legacyJSON = """
    {"id":"\(UUID().uuidString)","type":6,"name":"旧小屏幕","isEnabled":true,"settings":{}}
    """.data(using: .utf8)!
    let legacy = try JSONDecoder().decode(ManagedDevice.self, from: legacyJSON)
    checkEqual(legacy.settings.aiMacScreen, nil, "旧设置缺少小屏幕字段仍可解码")

    let snapshot = SystemSnapshot(cpuPercent: 42, memoryPercent: 68,
                                  usedMemoryBytes: 8_000_000_000,
                                  totalMemoryBytes: 16_000_000_000,
                                  downloadBytesPerSecond: 1_024_000,
                                  uploadBytesPerSecond: 512_000,
                                  uptime: 3600, sampledAt: Date())
    let dashboard = try AIMacScreenSupport.render(
        settings: AIMacScreenDeviceSettings(mode: .dashboard), system: snapshot)
    let blankCanvas = try AIMacScreenSupport.render(
        settings: AIMacScreenDeviceSettings(mode: .canvas), system: snapshot)
    let clock = try AIMacScreenSupport.render(
        settings: AIMacScreenDeviceSettings(mode: .clock), system: snapshot)
    checkEqual(dashboard.width, 240, "小屏幕仪表盘宽度")
    checkEqual(dashboard.height, 240, "小屏幕仪表盘高度")
    checkEqual(clock.width, 240, "小屏幕时钟宽度")
    checkEqual(clock.height, 240, "小屏幕时钟高度")
    checkEqual(blankCanvas.width, 240, "空白彩色画板仍生成有效 240×240 帧")

    let coverContext = CGContext(data: nil, width: 64, height: 64,
                                 bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    coverContext.setFillColor(CGColor(red: 0.92, green: 0.22, blue: 0.16, alpha: 1))
    coverContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let coverData = NSMutableData()
    let coverDestination = CGImageDestinationCreateWithData(
        coverData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(coverDestination, coverContext.makeImage()!, nil)
    check(CGImageDestinationFinalize(coverDestination), "AI Mac 彩色取色测试封面生成")
    var colorNowPlaying = NowPlayingInfo.sample
    colorNowPlaying.artwork = coverData as Data
    let colorSettings = AppSettings()
    let colorPomodoro = PomodoroSnapshot(phase: .idle, effectivePhase: .idle,
                                         taskName: "", remaining: 0, duration: 0,
                                         completedFocusSessions: 0)
    let colorPalette = ScreenThemes.resolved(theme: colorSettings.cardTheme,
                                             backgroundTone: .dark,
                                             customBackgroundHex: nil,
                                             accentTone: colorSettings.accentTone,
                                             customAccentHex: colorSettings.customAccentHex,
                                             softwareIsDark: true)
    let smartColorCanvas = ScreenRenderer.renderDeviceCanvas(
        modules: [.nowPlaying, .cpu], system: snapshot,
        nowPlaying: colorNowPlaying, pomodoro: colorPomodoro,
        customText: "", settings: colorSettings,
        width: 240, height: 240, palette: colorPalette,
        optimizeForEInk: false, nowPlayingSmartBackground: true)
    let plainColorCanvas = ScreenRenderer.renderDeviceCanvas(
        modules: [.nowPlaying, .cpu], system: snapshot,
        nowPlaying: colorNowPlaying, pomodoro: colorPomodoro,
        customText: "", settings: colorSettings,
        width: 240, height: 240, palette: colorPalette,
        optimizeForEInk: false, nowPlayingSmartBackground: false)
    let smartCorner = pixelAt(smartColorCanvas, 2, 2)
    check(smartCorner.0 > smartCorner.1 + 0.35 && smartCorner.0 > smartCorner.2 + 0.35,
          "AI Mac 智能取色应把封面主色填充到整块彩色画板（实测 \(smartCorner)）")
    check(!bitmapEqual(smartColorCanvas, plainColorCanvas),
          "AI Mac 关闭智能取色后应恢复手动主题背景")
    let jpeg = try AIMacScreenSupport.encodeJPEG(dashboard, preferredQuality: 82)
    check(jpeg.count <= AIMacScreenSupport.maximumJPEGBytes, "JPEG 兼容帧不超过 24KB")

    func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 240, height: 240,
                                bitsPerComponent: 8, bytesPerRow: 240 * 4,
                                space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: colorSpace,
                                     components: [red, green, blue, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
        return context.makeImage()!
    }
    let red = try AIMacScreenSupport.encodeRGB565(
        solidImage(red: 1, green: 0, blue: 0))
    let green = try AIMacScreenSupport.encodeRGB565(
        solidImage(red: 0, green: 1, blue: 0))
    let blue = try AIMacScreenSupport.encodeRGB565(
        solidImage(red: 0, green: 0, blue: 1))
    checkEqual(red.count, 115_200, "RGB565 帧严格为 115200 字节")
    checkEqual(Array(red.prefix(2)), [0xF8, 0x00], "RGB565 纯红大端字节序")
    checkEqual(Array(green.prefix(2)), [0x07, 0xE0], "RGB565 纯绿大端字节序")
    checkEqual(Array(blue.prefix(2)), [0x00, 0x1F], "RGB565 纯蓝大端字节序")
    print("  AI Mac 240×240 小屏幕通过")
}

// MARK: - Formlabs 云端模式

func testFormlabs() throws {
    checkEqual(CanvasModule.formlabs.rawValue, 22, "Formlabs 画板第 1 槽枚举值稳定")
    checkEqual(CanvasModule.formlabs2.rawValue, 23, "Formlabs 画板第 2 槽枚举值稳定")
    checkEqual(CanvasModule.formlabs3.rawValue, 24, "Formlabs 画板第 3 槽枚举值稳定")
    checkEqual(CanvasModule.formlabs4.rawValue, 25, "Formlabs 画板第 4 槽枚举值稳定")
    checkEqual(CanvasModule.formlabs5.rawValue, 26, "Formlabs 画板第 5 槽枚举值稳定")
    checkEqual(CanvasModule.formlabs.formlabsSlotIndex, 0, "Formlabs 画板第 1 槽映射")
    checkEqual(CanvasModule.formlabs5.formlabsSlotIndex, 4, "Formlabs 画板第 5 槽映射")
    check(CanvasModule.keyboardModules.contains(.formlabs), "灵犀画板包含 Formlabs 模块")
    check(CanvasModule.oraclePanelModules.contains(.formlabs), "口袋先知画板包含 Formlabs 模块")
    check(CanvasModule.excerptPanelModules.contains(.formlabs), "摘录画板包含 Formlabs 模块")

    let byLayer = FormlabsPrintInfo(name: "Dental Model", status: "printing",
                                    currentLayer: 25, layerCount: 100,
                                    elapsedDurationMS: 90_000, estimatedDurationMS: 180_000,
                                    estimatedTimeRemainingMS: 90_000,
                                    materialName: "Grey V5", layerThicknessMM: 0.05)
    checkEqual(byLayer.progress, 0.25, "Formlabs 进度优先按当前层/总层数计算")
    let byTime = FormlabsPrintInfo(elapsedDurationMS: 120_000, estimatedDurationMS: 240_000)
    checkEqual(byTime.progress, 0.5, "Formlabs 无层数时按时长回退计算")
    checkEqual(FormlabsPrintInfo.configuredMaterialName(
        materialName: "Grey V5", material: "material-id",
        printSettingsName: "Grey V5 50 µm"), "Grey V5",
        "Formlabs 优先显示打印任务提供的耗材名称")
    checkEqual(FormlabsPrintInfo.configuredMaterialName(
        materialName: "", material: "Clear V5", printSettingsName: "Clear 100 µm"),
        "Clear 100 µm", "Formlabs 缺少材料名时优先显示人类可读的打印配置")
    checkEqual(FormlabsPrintInfo.configuredMaterialName(
        materialName: "unknown", material: nil, printSettingsName: "Tough 1500 100 µm"),
        "Tough 1500 100 µm", "Formlabs 可从打印配置名回退识别耗材种类")
    checkEqual(FormlabsPrintInfo.configuredMaterialName(
        materialName: "未分配", material: "Grey V5", printSettingsName: "Grey V5 50 µm"),
        "Grey V5 50 µm", "Formlabs 中文未分配占位值不应阻断打印配置回退")
    checkEqual(FormlabsPrintInfo.configuredMaterialName(
        materialName: "未分配", material: "RDGPCL06", printSettingsName: "Clear V5 50 µm"),
        "Clear V5 50 µm", "Formlabs 打印配置名称应优先于内部材料代码")
    checkEqual(FormlabsPrintInfo.configuredMaterialName(
        materialName: "未分配", material: "RDGPCL06", printSettingsName: "Default",
        printerMaterial: "TYPE_UNSPECIFIED"),
        "RDGPCL06", "Formlabs 应跳过未指定的料盒类型并回退到稳定材料代码")
    checkEqual(FormlabsPrintInfo.configuredMaterialName(
        materialName: "UNASSIGNED", material: nil, printSettingsName: "Clear V5 100 µm",
        printerMaterial: "未设置"),
        "Clear V5 100 µm", "Formlabs 英文占位值应回退到打印配置材料")
    checkEqual(ScreenRenderer.formlabsStatusText("printing"), "打印中", "Formlabs 状态汉化")
    checkEqual(ScreenRenderer.formlabsStatusText("cancelled"), "已取消", "Formlabs 取消状态汉化")
    checkEqual(ScreenRenderer.formlabsStatusText("custom_state"), "custom_state", "未知状态保留原文")

    let retainedCompleted = FormlabsTaskCachePolicy.retainedPrint(previous: byLayer, latest: nil)
    checkEqual(retainedCompleted?.name, "Dental Model", "Formlabs 空闲后保留最近任务名")
    checkEqual(retainedCompleted?.status, "finished", "Formlabs 当前任务消失后固化为已完成")
    checkEqual(retainedCompleted?.currentLayer, 100, "Formlabs 已完成缓存补齐最终层数")
    checkEqual(retainedCompleted?.estimatedTimeRemainingMS, 0,
               "Formlabs 已完成缓存清零剩余时间")
    let nextTask = FormlabsPrintInfo(name: "Next Model", status: "printing",
                                     currentLayer: 1, layerCount: 50)
    checkEqual(FormlabsTaskCachePolicy.retainedPrint(previous: byLayer, latest: nextTask),
               nextTask, "Formlabs 新任务出现时替换最近任务缓存")
    var sameTaskMissingMaterial = byLayer
    sameTaskMissingMaterial.currentLayer = 26
    sameTaskMissingMaterial.materialName = ""
    checkEqual(FormlabsTaskCachePolicy.retainedPrint(previous: byLayer,
                                                     latest: sameTaskMissingMaterial)?.materialName,
               "Grey V5", "Formlabs 同一任务短暂缺少耗材时保留最近有效材料")
    var sameTaskPlaceholderMaterial = byLayer
    sameTaskPlaceholderMaterial.currentLayer = 27
    sameTaskPlaceholderMaterial.materialName = "未分配"
    checkEqual(FormlabsTaskCachePolicy.retainedPrint(previous: byLayer,
                                                     latest: sameTaskPlaceholderMaterial)?.materialName,
               "Grey V5", "Formlabs 同一任务占位耗材不应覆盖有效缓存")
    var signedA = byLayer
    signedA.thumbnailURL = "https://cdn.example/model.png?signature=old"
    var signedB = byLayer
    signedB.thumbnailURL = "https://cdn.example/model.png?signature=new"
    check(FormlabsTaskCachePolicy.isSameTask(signedA, signedB),
          "Formlabs 缩略图签名变化不应误判为新任务")

    let cacheBase = FileManager.default.temporaryDirectory
        .appendingPathComponent("linx-formlabs-cache-test-\(UUID().uuidString)")
    let cacheStore = SettingsStore(dataDirectory: cacheBase)
    let cacheID = UUID()
    let cachedSnapshot = FormlabsSnapshot(
        device: FormlabsDeviceInfo(id: "CACHE-PRINTER"),
        print: retainedCompleted, thumbnail: Data([1, 2, 3, 4]), sampledAt: Date(),
        cloudError: "不应持久化")
    cacheStore.saveFormlabsTaskCache([cacheID: cachedSnapshot])
    let restoredCache = cacheStore.loadFormlabsTaskCache()[cacheID]
    checkEqual(restoredCache?.print?.name, "Dental Model", "Formlabs 最近任务缓存可跨启动恢复")
    checkEqual(restoredCache?.thumbnail, Data([1, 2, 3, 4]), "Formlabs 最近任务封面可跨启动恢复")
    checkEqual(restoredCache?.cloudError, nil, "Formlabs 缓存不保留临时云端错误")

    var deviceSettings = DeviceSettings()
    deviceSettings.formlabsConnection = FormlabsConnectionSettings(
        printerSerial: "SERIAL-TEST", clientID: "client", clientSecret: "secret",
        showThumbnail: false, showLayers: true, showMaterial: false)
    let roundTrip = try JSONDecoder().decode(DeviceSettings.self,
                                              from: JSONEncoder().encode(deviceSettings))
    checkEqual(roundTrip.formlabsConnection, deviceSettings.formlabsConnection,
               "Formlabs 连接设置 Codable 往返")
    let legacyConnection = try JSONDecoder().decode(
        FormlabsConnectionSettings.self,
        from: Data("{\"printerSerial\":\"LEGACY\",\"clientID\":\"id\",\"clientSecret\":\"secret\",\"showThumbnail\":true,\"showLayers\":true,\"showMaterial\":true}".utf8))
    checkEqual(legacyConnection.useBrandAccent, true,
               "Formlabs 旧配置缺少强调色开关时保留品牌蓝")

    let orchestration = AppSettings()
    for index in 0..<5 {
        var snapshot = DeviceSettings()
        snapshot.formlabsConnection = FormlabsConnectionSettings(printerSerial: "F\(index)")
        orchestration.devices.append(ManagedDevice(type: .formlabs,
                                                    name: "Formlabs \(index + 1)", settings: snapshot))
    }
    check(!orchestration.canAddDevice(of: .formlabs), "Formlabs 最多五台")
    check(orchestration.deviceLimitNotice(for: .formlabs) != nil, "Formlabs 达到上限显示说明")
    let keyboard = ManagedDevice(type: .keyboard, name: "Keyboard", settings: DeviceSettings())
    orchestration.devices.append(keyboard)
    let filtered = orchestration.keyboardCardPanelRawValues(
        for: keyboard.id,
        fallback: ["formlabs", "formlabs5", "bambuLab"])
    check(filtered.contains("formlabs") && filtered.contains("formlabs5"),
          "已存在 Formlabs 卡片位应保留")
    check(!filtered.contains("bambuLab"), "没有 Bambu 设备时不显示其空卡片")

    let snapshot = FormlabsSnapshot(
        device: FormlabsDeviceInfo(id: "FORM-4-TEST", productName: "Form 4",
                                   status: "printing", isConnected: true,
                                   ipAddress: "192.0.2.10", estimatedPrintTimeRemainingMS: 90_000),
        print: byLayer, sampledAt: Date(), cloudError: nil)
    let rendered = try ScreenRenderer.renderFormlabs(
        deviceName: "工作室 Form 4", connection: deviceSettings.formlabsConnection!,
        snapshot: snapshot, settings: AppSettings())
    checkEqual(rendered.image.width, ScreenRenderer.width, "Formlabs 卡片宽度")
    checkEqual(rendered.image.height, ScreenRenderer.height, "Formlabs 卡片高度")
    check(rendered.data.count > 1_000, "Formlabs 卡片 JPEG 有有效内容")
    let renamedRendered = try ScreenRenderer.renderFormlabs(
        deviceName: "另一台 Form 4", connection: deviceSettings.formlabsConnection!,
        snapshot: snapshot, settings: AppSettings())
    check(rendered.data != renamedRendered.data,
          "Formlabs 独立卡片标头应显示用户设定的设备名称")
    var themedConnection = deviceSettings.formlabsConnection!
    themedConnection.useBrandAccent = false
    let themedRendered = try ScreenRenderer.renderFormlabs(
        deviceName: "工作室 Form 4", connection: themedConnection,
        snapshot: snapshot, settings: AppSettings())
    check(rendered.data != themedRendered.data,
          "Formlabs 品牌强调色与跟随全局主题应渲染不同")

    // 三种画板尺寸均可渲染 Formlabs；缩略图开关及设备槽位必须反映到最终画面。
    let thumbnailContext = CGContext(data: nil, width: 48, height: 48,
                                     bitsPerComponent: 8, bytesPerRow: 48 * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    thumbnailContext.setFillColor(CGColor(red: 0.12, green: 0.55, blue: 0.88, alpha: 1))
    thumbnailContext.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
    thumbnailContext.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.98, alpha: 1))
    thumbnailContext.fill(CGRect(x: 12, y: 8, width: 24, height: 32))
    let thumbnailData = NSMutableData()
    let thumbnailDestination = CGImageDestinationCreateWithData(
        thumbnailData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(thumbnailDestination, thumbnailContext.makeImage()!, nil)
    check(CGImageDestinationFinalize(thumbnailDestination), "Formlabs 画板测试缩略图生成")

    var imageConnection = deviceSettings.formlabsConnection!
    imageConnection.showThumbnail = true
    imageConnection.showLayers = true
    imageConnection.showMaterial = true
    let imageSnapshot = FormlabsSnapshot(device: snapshot.device, print: snapshot.print,
                                          thumbnail: thumbnailData as Data,
                                          sampledAt: snapshot.sampledAt, cloudError: nil)
    let imageItem = FormlabsCanvasItem(deviceName: "工作室 Form 4",
                                       connection: imageConnection, snapshot: imageSnapshot)
    var plainConnection = imageConnection
    plainConnection.showThumbnail = false
    let plainItem = FormlabsCanvasItem(deviceName: "工作室 Form 4",
                                       connection: plainConnection, snapshot: imageSnapshot)
    let otherPrint = FormlabsPrintInfo(name: "Build Platform 2", status: "paused",
                                       currentLayer: 8, layerCount: 80,
                                       estimatedTimeRemainingMS: 300_000,
                                       materialName: "Clear V5")
    let otherItem = FormlabsCanvasItem(
        deviceName: "Form 4B", connection: imageConnection,
        snapshot: FormlabsSnapshot(device: snapshot.device, print: otherPrint,
                                    thumbnail: thumbnailData as Data,
                                    sampledAt: snapshot.sampledAt, cloudError: nil))
    let canvasSettings = AppSettings()
    let canvasSystem = SystemSnapshot(cpuPercent: 12, memoryPercent: 34,
                                      usedMemoryBytes: 4_000_000_000,
                                      totalMemoryBytes: 16_000_000_000,
                                      downloadBytesPerSecond: 0,
                                      uploadBytesPerSecond: 0,
                                      uptime: 3_600, sampledAt: Date())
    let canvasPomodoro = PomodoroSnapshot(phase: .idle, effectivePhase: .idle,
                                          taskName: "", remaining: 0, duration: 1,
                                          completedFocusSessions: 0)
    let keyboardCanvas = try ScreenRenderer.renderCanvas(
        modules: [.formlabs], system: canvasSystem, nowPlaying: .sample,
        pomodoro: canvasPomodoro, customText: "", settings: canvasSettings,
        formlabsItems: [imageItem])
    checkEqual(keyboardCanvas.image.width, 142, "灵犀画板 Formlabs 宽度")
    checkEqual(keyboardCanvas.image.height, 428, "灵犀画板 Formlabs 高度")
    check(keyboardCanvas.data.count <= ScreenRenderer.maximumFileSize,
          "灵犀画板 Formlabs 输出大小")
    let keyboardWithoutThumbnail = try ScreenRenderer.renderCanvas(
        modules: [.formlabs], system: canvasSystem, nowPlaying: .sample,
        pomodoro: canvasPomodoro, customText: "", settings: canvasSettings,
        formlabsItems: [plainItem])
    check(keyboardCanvas.data != keyboardWithoutThumbnail.data,
          "Formlabs 画板缩略图开关应改变渲染结果")

    let oracleCanvas = ScreenRenderer.renderDeviceCanvas(
        modules: [.formlabs], system: canvasSystem, nowPlaying: .sample,
        pomodoro: canvasPomodoro, customText: "", settings: canvasSettings,
        formlabsItems: [imageItem], width: 200, height: 200,
        palette: canvasSettings.resolvedPalette)
    checkEqual(oracleCanvas.width, 200, "口袋先知画板 Formlabs 宽度")
    checkEqual(oracleCanvas.height, 200, "口袋先知画板 Formlabs 高度")
    let excerptCanvas = ScreenRenderer.renderDeviceCanvas(
        modules: [.formlabs], system: canvasSystem, nowPlaying: .sample,
        pomodoro: canvasPomodoro, customText: "", settings: canvasSettings,
        formlabsItems: [imageItem], width: 296, height: 152,
        palette: canvasSettings.resolvedPalette)
    checkEqual(excerptCanvas.width, 296, "摘录画板 Formlabs 宽度")
    checkEqual(excerptCanvas.height, 152, "摘录画板 Formlabs 高度")
    let slotOne = ScreenRenderer.renderDeviceCanvas(
        modules: [.formlabs], system: canvasSystem, nowPlaying: .sample,
        pomodoro: canvasPomodoro, customText: "", settings: canvasSettings,
        formlabsItems: [imageItem, otherItem], width: 200, height: 200,
        palette: canvasSettings.resolvedPalette)
    let slotTwo = ScreenRenderer.renderDeviceCanvas(
        modules: [.formlabs2], system: canvasSystem, nowPlaying: .sample,
        pomodoro: canvasPomodoro, customText: "", settings: canvasSettings,
        formlabsItems: [imageItem, otherItem], width: 200, height: 200,
        palette: canvasSettings.resolvedPalette)
    check(slotOne.dataProvider?.data as Data? != slotTwo.dataProvider?.data as Data?,
          "Formlabs 第 1/第 2 台设备画板应渲染不同内容")
    print("  Formlabs 云端模式通过")
}

// MARK: - 全局快捷键

func testGlobalShortcuts() throws {
    // 默认组合与显示
    checkEqual(GlobalShortcut.defaultToggle.keyCode, 49, "默认开始/暂停键码 Space")
    checkEqual(GlobalShortcut.defaultSkip.keyCode, 124, "默认跳过键码 →")
    checkEqual(GlobalShortcut.defaultReset.keyCode, 51, "默认重置键码 ⌫")
    checkEqual(GlobalShortcut.defaultPageUp.keyCode, 126, "默认上一页键码 ↑")
    checkEqual(GlobalShortcut.defaultPageDown.keyCode, 125, "默认下一页键码 ↓")
    checkEqual(GlobalShortcut.defaultToggle.modifiers,
               GlobalShortcut.controlKey | GlobalShortcut.optionKey, "默认修饰键 ⌃⌥")
    checkEqual(GlobalShortcut.defaultToggle.displayString, "⌃⌥Space", "默认显示字符串")
    checkEqual(GlobalShortcut(keyCode: 124, modifiers: GlobalShortcut.controlKey | GlobalShortcut.optionKey).displayString,
               "⌃⌥→", "方向键显示")
    checkEqual(GlobalShortcut(keyCode: 18, modifiers: GlobalShortcut.cmdKey).displayString, "⌘1", "⌘1 显示")
    checkEqual(GlobalShortcut(keyCode: 122, modifiers: 0).displayString, "F1", "功能键显示")

    // 设置往返
    let rt = AppSettings()
    rt.pomodoroToggleShortcut = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcut.cmdKey) // ⌘1
    rt.pomodoroSkipShortcut = GlobalShortcut(keyCode: 26, modifiers: GlobalShortcut.controlKey | GlobalShortcut.shiftKey)
    rt.keyboardPageUpShortcut = GlobalShortcut(keyCode: 116, modifiers: GlobalShortcut.cmdKey)
    rt.keyboardPageDownShortcut = GlobalShortcut(keyCode: 121, modifiers: GlobalShortcut.optionKey)
    rt.lingxi68KnobPagingEnabled = true
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(rt))
    checkEqual(decoded.pomodoroToggleShortcut.keyCode, 18, "快捷键往返 keyCode")
    checkEqual(decoded.pomodoroToggleShortcut.modifiers, GlobalShortcut.cmdKey, "快捷键往返 modifiers")
    checkEqual(decoded.pomodoroSkipShortcut.keyCode, 26, "跳过快捷键往返")
    checkEqual(decoded.pomodoroResetShortcut, GlobalShortcut.defaultReset, "未修改项保留默认")
    checkEqual(decoded.keyboardPageUpShortcut,
               GlobalShortcut(keyCode: 116, modifiers: GlobalShortcut.cmdKey), "上一页快捷键往返")
    checkEqual(decoded.keyboardPageDownShortcut,
               GlobalShortcut(keyCode: 121, modifiers: GlobalShortcut.optionKey), "下一页快捷键往返")
    checkEqual(decoded.lingxi68KnobPagingEnabled, true, "Fn + 旋钮翻页开关往返")
    checkEqual(AppSettings().lingxi68KnobPagingEnabled, false, "Fn + 旋钮翻页默认关闭")

    // 钳制：键码越界回落、修饰键只保留 ⌘⇧⌥⌃
    var clamp = AppSettings()
    clamp.pomodoroToggleShortcut = GlobalShortcut(keyCode: 999, modifiers: 0xFFFF)
    clamp.keyboardPageDownShortcut = GlobalShortcut(keyCode: 888, modifiers: 0xFFFF)
    clamp.clamped()
    checkEqual(clamp.pomodoroToggleShortcut.keyCode, 127, "快捷键键码上界钳制")
    checkEqual(clamp.pomodoroToggleShortcut.modifiers, 0x1B00, "快捷键修饰键掩码钳制")
    checkEqual(clamp.keyboardPageDownShortcut.keyCode, 127, "翻页快捷键键码上界钳制")
    checkEqual(clamp.keyboardPageDownShortcut.modifiers, 0x1B00, "翻页快捷键修饰键掩码钳制")

    // 恢复默认
    var d = AppSettings()
    d.pomodoroSkipShortcut = GlobalShortcut(keyCode: 18, modifiers: GlobalShortcut.cmdKey)
    d.pomodoroSkipShortcut = .defaultSkip
    checkEqual(d.pomodoroSkipShortcut.keyCode, 124, "恢复默认跳过")
    print("  全局快捷键通过")
}

// MARK: - Home Assistant

func testHomeAssistant() throws {
    checkEqual(ScreenRenderer.haStandalonePageLimit, 4, "HA 独立卡片单页最多四个实体")
    checkEqual(HAEntityPicker.pictureEntityIDs(in: [
        "sensor.room_temperature", " camera.front_door ", "image.weather_map",
        "camera.front_door", "light.desk"
    ]), ["camera.front_door", "image.weather_map"],
               "HA 卡片仅按用户顺序抓取 camera/image 静态帧并去重")
    // 实体较少时均匀分配顶部/行间/底部留白；密集时回落到固定 4pt 行距。
    let roomyFrames = ScreenRenderer.haAdaptiveRowFrames(
        minimumHeights: [24, 24], region: CGRect(x: 0, y: 0, width: 120, height: 120))
    checkEqual(roomyFrames.count, 2, "HA 自适应布局保留全部实体")
    check(roomyFrames[0].minY > 10 && roomyFrames[1].maxY < 110,
          "HA 少量实体应在显示范围内上下舒展")
    check(roomyFrames[1].minY - roomyFrames[0].maxY > 4,
          "HA 少量实体应增加实体间视觉间距")
    let denseFrames = ScreenRenderer.haAdaptiveRowFrames(
        minimumHeights: [30, 30, 30, 30],
        region: CGRect(x: 0, y: 0, width: 120, height: 132))
    checkEqual(denseFrames.count, 4, "HA 密集布局容纳可显示实体")
    checkEqual(denseFrames[1].minY - denseFrames[0].maxY, 4, "HA 密集布局保持基础行距")
    let mixedFrames = ScreenRenderer.haAdaptiveRowFrames(
        minimumHeights: [30, 50, 40],
        region: CGRect(x: 0, y: 0, width: 120, height: 180))
    checkEqual(mixedFrames.count, 3, "HA 不同文本高度仍保留全部实体")
    check(mixedFrames.allSatisfy { $0.height == mixedFrames[0].height },
          "HA 同页实体状态卡片必须严格等高")
    // URL 构造：自动补 /api/states、去尾部斜杠、空地址返回 nil
    checkEqual(HomeAssistantClient.statesURL(server: "http://192.168.1.5:8123")?.absoluteString,
               "http://192.168.1.5:8123/api/states", "HA 实体列表 URL 构造")
    checkEqual(HomeAssistantClient.statesURL(server: "http://192.168.1.5:8123/")?.absoluteString,
               "http://192.168.1.5:8123/api/states", "HA URL 尾部斜杠处理")
    check(HomeAssistantClient.statesURL(server: "   ") == nil, "HA 空地址返回 nil")

    // Bearer 认证头（token 不打印）
    let request = HomeAssistantClient.makeStatesRequest(server: "http://192.168.1.5:8123", token: "ha-test-token")
    check(request?.url?.absoluteString == "http://192.168.1.5:8123/api/states", "HA 请求 URL")
    checkEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer ha-test-token", "HA Bearer 认证头")

    // 状态解析：friendly_name / unit_of_measurement / on-off 映射
    let json = """
    [
      {"entity_id": "sensor.living_temp", "state": "23.5",
       "attributes": {"friendly_name": "客厅温度", "unit_of_measurement": "°C"}},
      {"entity_id": "light.office", "state": "on", "attributes": {"friendly_name": "办公室灯"}},
      {"entity_id": "binary_sensor.door", "state": "off", "attributes": {}},
      {"entity_id": "sensor.no_name", "state": "42", "attributes": {}}
    ]
    """
    let entities = try HomeAssistantClient.parseStates(data: Data(json.utf8))
    checkEqual(entities.count, 4, "HA 实体解析数量")
    checkEqual(entities[0].displayName, "客厅温度", "HA 实体名优先 friendly_name")
    checkEqual(entities[0].displayValue, "23.5 °C", "HA 数值含单位")
    checkEqual(HAEntity.compactDisplayState("unknown"), "未知", "HA unknown 状态中文化")
    checkEqual(HAEntity.compactDisplayState("unavailable"), "不可用", "HA unavailable 状态中文化")
    checkEqual(HAEntity.compactDisplayState("printing"), "printing",
               "HA 普通状态无需进入时间解析路径")
    let compactTimestamp = HAEntity.compactDisplayState(
        "2026-08-30T14:29:40.714650+00:00", timeZone: TimeZone(secondsFromGMT: 0)!)
    checkEqual(compactTimestamp, "08-30 14:29", "HA ISO 时间戳压缩为小屏短时间")
    check(!ScreenRenderer.haRowUsesStackedLayout(name: "温度", value: "23 °C", availableWidth: 94),
          "HA 短名称与短状态保持左右布局")
    check(ScreenRenderer.haRowUsesStackedLayout(name: "X2D_20P6BJ652500750 摄像头",
                                                value: compactTimestamp, availableWidth: 94),
          "HA 长名称与长状态自动切换上下布局")
    checkEqual(entities[1].displayState, "开", "HA on 映射为开")
    checkEqual(entities[2].displayState, "关", "HA off 映射为关")
    checkEqual(entities[3].displayName, "sensor.no_name", "HA 无名称回退 entity_id")
    var threw = false
    do { _ = try HomeAssistantClient.parseStates(data: Data("not json".utf8)) } catch { threw = true }
    check(threw, "HA 非法 JSON 应抛错")

    // 快照选中逻辑（多实体列表；单实体兼容）
    let snapshot = HASnapshot(entities: entities,
                              selectedEntities: [entities.first { $0.entityId == "light.office" }!])
    checkEqual(snapshot.selected?.displayName, "办公室灯", "HA 快照选中实体")
    checkEqual(snapshot.selectedEntities.count, 1, "HA 快照多实体列表数量")
    let largePool = (0..<2_000).map {
        HAEntity(entityId: "sensor.bulk_\($0)", friendlyName: "实体 \($0)",
                 state: "\($0)", unitOfMeasurement: nil)
    }
    let selectedLarge = HASnapshot(entities: largePool).selecting(
        entityIDs: ["sensor.bulk_1999", "sensor.bulk_3"])
    checkEqual(selectedLarge.selectedEntities.map(\.entityId),
               ["sensor.bulk_1999", "sensor.bulk_3"],
               "大型 HA 实体池只构建所需选择视图并保持用户顺序")

    // 运行时刷新策略：静态 HA/Bambu 画板不再每秒重绘；真正动态内容仍保持实时。
    let staticCanvas: [CanvasModule] = [.nowPlaying, .homeAssistant, .bambuLab]
    checkEqual(PomodoroRefreshPolicy.defaultIntervalSeconds, 5, "键盘番茄钟默认 5 秒刷新")
    checkEqual(PomodoroRefreshPolicy.alignedRemainingSeconds(
        1500, duration: 1500, intervalSeconds: 5), 1500,
               "番茄钟整刻保持不变")
    checkEqual(PomodoroRefreshPolicy.alignedRemainingSeconds(
        1499.2, duration: 1500, intervalSeconds: 5), 1500,
               "番茄钟未跨过下一个 5 秒刻度时不提前刷新")
    checkEqual(PomodoroRefreshPolicy.alignedRemainingSeconds(
        1494.8, duration: 1500, intervalSeconds: 5), 1495,
               "番茄钟跨过刻度后对齐到 24:55")
    checkEqual(PomodoroRefreshPolicy.alignedRemainingSeconds(
        0, duration: 1500, intervalSeconds: 5), 0,
               "番茄钟结束刻度对齐到零")
    checkEqual(PomodoroRefreshPolicy.alignedRemainingSeconds(
        1492.8, duration: 1500, intervalSeconds: 7), 1493,
               "非整除间隔也以番茄钟起点对齐")
    checkEqual(RuntimePerformancePolicy.previewInterval(
        mode: .pomodoro, canvasModules: [], timeFormat: "HH:mm",
        nowPlaying: false, pomodoroRunning: true, dynamicUploadSeconds: 60,
        pomodoroUploadSeconds: 7),
        7, "键盘番茄钟预览与自定义推送间隔对齐，不受全局周期影响")
    checkEqual(RuntimePerformancePolicy.previewInterval(
        mode: .canvas, canvasModules: staticCanvas, timeFormat: "HH:mm",
        nowPlaying: false, pomodoroRunning: false, dynamicUploadSeconds: 5),
        5, "静态画板预览按推送周期刷新")
    checkEqual(RuntimePerformancePolicy.previewInterval(
        mode: .canvas, canvasModules: staticCanvas, timeFormat: "HH:mm",
        nowPlaying: true, pomodoroRunning: false, dynamicUploadSeconds: 5),
        1, "媒体播放时画板保持每秒进度刷新")
    checkEqual(RuntimePerformancePolicy.deviceCanvasContentCheckInterval(
        modules: staticCanvas, timeFormat: "HH:mm", nowPlaying: false,
        pomodoroRunning: false),
        30, "静态独立画板内容比较降频到 30 秒")
    checkEqual(RuntimePerformancePolicy.deviceCanvasContentCheckInterval(
        modules: staticCanvas, timeFormat: "HH:mm", nowPlaying: true,
        pomodoroRunning: false),
        5, "媒体播放时独立画板保持 5 秒内容比较")
    check(!RuntimePerformancePolicy.needsSystemSample(modules: staticCanvas),
          "无系统指标模块时不采集系统状态")
    check(RuntimePerformancePolicy.needsSystemSample(modules: [.cpu, .homeAssistant]),
          "存在 CPU 模块时仍采集系统状态")
    let inkFingerprintA = Data([1, 2, 3])
    let inkFingerprintB = Data([1, 2, 4])
    check(RuntimePerformancePolicy.shouldPushInkDisplay(
        previousFingerprint: nil, currentFingerprint: inkFingerprintA),
        "墨水屏没有成功推送基线时必须发送首帧")
    check(!RuntimePerformancePolicy.shouldPushInkDisplay(
        previousFingerprint: inkFingerprintA, currentFingerprint: inkFingerprintA),
        "墨水屏最终内容无变化时跳过自动推送")
    check(RuntimePerformancePolicy.shouldPushInkDisplay(
        previousFingerprint: inkFingerprintA, currentFingerprint: inkFingerprintB),
        "墨水屏最终内容变化后才执行自动推送")
    check(!RuntimePerformancePolicy.shouldPushInkDisplay(
        previousFingerprint: inkFingerprintA, currentFingerprint: nil),
        "墨水屏渲染失败时不得发起空内容推送")

    // 设置往返（token 为敏感字段：仅验证值往返，不打印明文）
    let rt = AppSettings()
    rt.pomodoroUploadSeconds = 7
    rt.haServerURL = "http://192.168.1.100:8123"
    rt.haToken = "secret-token-do-not-log"
    rt.haRefreshMinutes = 3
    rt.haEntityID = "sensor.living_temp"
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(rt))
    checkEqual(decoded.pomodoroUploadSeconds, 7, "番茄钟推送间隔往返")
    let pomodoroKeyboardSnapshot = DeviceSettings.capture(from: rt, type: .keyboard)
    checkEqual(pomodoroKeyboardSnapshot.pomodoroUploadSeconds, 7,
               "番茄钟推送间隔随键盘设置快照保存")
    let restoredPomodoroKeyboard = AppSettings()
    pomodoroKeyboardSnapshot.apply(to: restoredPomodoroKeyboard, type: .keyboard)
    checkEqual(restoredPomodoroKeyboard.pomodoroUploadSeconds, 7,
               "切换键盘时恢复各自的番茄钟推送间隔")
    checkEqual(decoded.haServerURL, "http://192.168.1.100:8123", "HA 服务器地址往返")
    checkEqual(decoded.haToken, "secret-token-do-not-log", "HA 令牌往返")
    checkEqual(decoded.haRefreshMinutes, 3, "HA 刷新间隔往返")
    checkEqual(decoded.haEntityID, "sensor.living_temp", "HA 实体选择往返")
    var clamp = AppSettings()
    clamp.haRefreshMinutes = 999
    clamp.clamped()
    checkEqual(clamp.haRefreshMinutes, 60, "HA 刷新间隔上界钳制")

    // 多实体列表编码往返 + 解码即清洗（init(from:) 末尾调用 clamped() 去空去重）
    let rt2 = AppSettings()
    rt2.haEntities = ["sensor.a", "", "light.b", "sensor.a"]
    let decoded2 = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(rt2))
    checkEqual(decoded2.haEntities, ["sensor.a", "light.b"], "HA 多实体列表解码即去空去重")

    // 渲染：HA 键盘卡片含实体名与数值；多实体列表排布；未配置/错误时不同
    let entity = entities[0]
    let haSettings = AppSettings()
    let withEntity = try ScreenRenderer.renderHA([entity], errorText: nil, settings: haSettings)
    checkEqual(withEntity.image.width, 142, "HA 卡片宽度")
    checkEqual(withEntity.image.height, 428, "HA 卡片高度")
    check(withEntity.data.count <= ScreenRenderer.maximumFileSize, "HA 卡片大小")
    let multi = try ScreenRenderer.renderHA(Array(entities.prefix(3)), errorText: nil, settings: haSettings)
    check(multi.data != withEntity.data, "HA 多实体与单实体渲染应不同")
    let multi5 = try ScreenRenderer.renderHA(Array(entities.prefix(5)), errorText: nil, settings: haSettings)
    check(multi5.data != multi.data, "HA 实体数量不同渲染应不同")
    // 排布优化：超长名称完整显示（自适应字号/换行，不截断）渲染不抛错、尺寸正常
    let longNameEntities = [
        HAEntity(entityId: "sensor.very_long_name_01", friendlyName: "客厅空气净化器PM2.5浓度传感器一", state: "35", unitOfMeasurement: "µg/m³"),
        HAEntity(entityId: "sensor.very_long_name_02", friendlyName: "卧室智能窗帘开合状态检测传感器", state: "closed", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.very_long_name_03", friendlyName: "厨房", state: "on", unitOfMeasurement: nil),
    ]
    let longNameCard = try ScreenRenderer.renderHA(longNameEntities, errorText: nil, settings: haSettings)
    checkEqual(longNameCard.image.width, 142, "超长名称多实体卡片宽度")
    checkEqual(longNameCard.image.height, 428, "超长名称多实体卡片高度")
    check(longNameCard.data.count <= ScreenRenderer.maximumFileSize, "超长名称多实体卡片大小")
    // 名称长度不同 → 自适应字号/换行布局不同（渲染结果不同）
    let shortNameEntities = [
        HAEntity(entityId: "sensor.a", friendlyName: "灯", state: "on", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.b", friendlyName: "开关", state: "off", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.c", friendlyName: "温度", state: "23", unitOfMeasurement: "°C"),
    ]
    let shortNameCard = try ScreenRenderer.renderHA(shortNameEntities, errorText: nil, settings: haSettings)
    check(longNameCard.data != shortNameCard.data, "超长名称与短名称排布渲染应不同")
    // 两端对齐：长名称 + 长状态值（错误码）渲染正常、不重叠抛错
    let alignEntities = [
        HAEntity(entityId: "sensor.long_name", friendlyName: "客厅空气净化器PM2.5浓度传感器", state: "35", unitOfMeasurement: "µg/m³"),
        HAEntity(entityId: "sensor.error_code", friendlyName: "打印机错误码", state: "0x03080005", unitOfMeasurement: nil),
    ]
    let alignCard = try ScreenRenderer.renderHA(alignEntities, errorText: nil, settings: haSettings)
    checkEqual(alignCard.image.width, 142, "两端对齐卡片宽度")
    checkEqual(alignCard.image.height, 428, "两端对齐卡片高度")
    check(alignCard.data.count <= ScreenRenderer.maximumFileSize, "两端对齐卡片大小")
    // 轮询刷新：同实体状态变化 → 卡片渲染不同（最新状态反映到显示层）
    let stateA = HAEntity(entityId: "sensor.t", friendlyName: "温度", state: "23", unitOfMeasurement: "°C")
    let stateB = HAEntity(entityId: "sensor.t", friendlyName: "温度", state: "25", unitOfMeasurement: "°C")
    let cardA = try ScreenRenderer.renderHA([stateA], errorText: nil, settings: haSettings)
    let cardB = try ScreenRenderer.renderHA([stateB], errorText: nil, settings: haSettings)
    check(cardA.data != cardB.data, "状态变化渲染应不同（轮询刷新反映到显示）")
    let multiA = try ScreenRenderer.renderHA([stateA, alignEntities[0]], errorText: nil, settings: haSettings)
    let multiB = try ScreenRenderer.renderHA([stateB, alignEntities[0]], errorText: nil, settings: haSettings)
    check(multiA.data != multiB.data, "多实体状态变化渲染应不同")
    // 时间戳解析：last_changed 带/不带小数秒均解析；缺省为 nil
    let tsJSON = """
    [
      {"entity_id": "sensor.t", "state": "1",
       "attributes": {"friendly_name": "温度"},
       "last_changed": "2026-08-26T04:00:00.123456+00:00"},
      {"entity_id": "sensor.t2", "state": "2",
       "attributes": {"friendly_name": "温度2"},
       "last_changed": "2026-08-26T05:00:00+00:00"},
      {"entity_id": "sensor.t3", "state": "3", "attributes": {}}
    ]
    """
    let tsEntities = try HomeAssistantClient.parseStates(data: Data(tsJSON.utf8))
    check(tsEntities[0].lastChanged != nil, "带小数秒时间戳解析")
    check(tsEntities[1].lastChanged != nil, "不带小数秒时间戳解析")
    check(tsEntities[2].lastChanged == nil, "缺省时间戳为 nil")
    // 错误码新鲜度：10 分钟内视为当前错误码，更早忽略；无时间戳视为新鲜
    let now = Date()
    let freshError = HAEntity(entityId: "sensor.bambu_error", friendlyName: "错误码",
                              state: "0x03080005", unitOfMeasurement: nil,
                              lastChanged: now.addingTimeInterval(-60))
    let staleError = HAEntity(entityId: "sensor.bambu_error", friendlyName: "错误码",
                              state: "0x03080005", unitOfMeasurement: nil,
                              lastChanged: now.addingTimeInterval(-660))
    check(HAErrorCodePolicy.isFresh(entity: freshError, now: now, staleSeconds: 600), "新鲜错误码判定新鲜")
    check(!HAErrorCodePolicy.isFresh(entity: staleError, now: now, staleSeconds: 600), "过期错误码判定过期")
    check(HAErrorCodePolicy.isFresh(entity: staleError, now: now, staleSeconds: nil), "无阈值不做时间过滤")
    let noTsError = HAEntity(entityId: "sensor.e", friendlyName: "错误码", state: "x", unitOfMeasurement: nil)
    check(HAErrorCodePolicy.isFresh(entity: noTsError, now: now, staleSeconds: 600), "无时间戳视为新鲜")
    // monitor：新鲜错误码异常、过期错误码正常（忽略残留旧值）
    let mFresh = HomeAssistantClient.monitor(entities: [freshError], monitorEntityID: "", expectedState: "",
                                             errorEntityID: "sensor.bambu_error",
                                             staleErrorSeconds: 600, now: now)
    check(mFresh.isAbnormal, "新鲜错误码触发异常")
    let mStale = HomeAssistantClient.monitor(entities: [staleError], monitorEntityID: "", expectedState: "",
                                             errorEntityID: "sensor.bambu_error",
                                             staleErrorSeconds: 600, now: now)
    check(!mStale.isAbnormal, "过期错误码忽略（视为已恢复）")
    // HMS 错误码映射：已知码返回原因、未知码 nil、无连字符/0x 格式归一化
    checkEqual(BambuHMSCode.reason(for: "07FE-4500-0002-0003"),
               "切刀刀柄未松开：刀柄或刀片可能被卡住，或耗材霍尔接线异常", "HMS 已知码映射")
    check(BambuHMSCode.reason(for: "07FE-9999-9999-9999") == nil, "HMS 未知码返回 nil")
    checkEqual(BambuHMSCode.reason(for: "07FE450000020003"),
               "切刀刀柄未松开：刀柄或刀片可能被卡住，或耗材霍尔接线异常", "HMS 无连字符归一化匹配")
    checkEqual(BambuHMSCode.reason(for: "0x07FE450000020003"),
               "切刀刀柄未松开：刀柄或刀片可能被卡住，或耗材霍尔接线异常", "HMS 0x 前缀归一化匹配")
    check(BambuHMSCode.reason(for: "") == nil, "HMS 空码返回 nil")
    // 状态汉化补充：running/busy 等映射（渲染层验证不同状态渲染不同）
    let idleEntity = HAEntity(entityId: "sensor.bambu_status", friendlyName: "打印机状态", state: "idle", unitOfMeasurement: nil)
    let busyEntity = HAEntity(entityId: "sensor.bambu_status", friendlyName: "打印机状态", state: "busy", unitOfMeasurement: nil)
    let bambuSettings = BambuLabCardSettings(statusEntityID: "sensor.bambu_status")
    let cardIdle = try ScreenRenderer.renderBambuLab(bambuSettings, entities: [idleEntity], settings: haSettings)
    let cardBusy = try ScreenRenderer.renderBambuLab(bambuSettings, entities: [busyEntity], settings: haSettings)
    check(cardIdle.data != cardBusy.data, "不同打印状态渲染应不同")
    // 多打印机：BambuLabCardSettings Codable 往返 + 设备快照 capture/apply
    let printerA = BambuLabCardSettings(name: "客厅 A1", statusEntityID: "sensor.a")
    let printerB = BambuLabCardSettings(name: "工作室 P1S", statusEntityID: "sensor.b")
    var p8 = AppSettings()
    p8.bambuPrinters = [printerA, printerB]
    let snap8 = DeviceSettings.capture(from: p8, type: .homeAssistant)
    checkEqual(snap8.bambuPrinters?.count, 2, "多打印机快照捕获数量")
    checkEqual(snap8.bambuPrinters?[1].name, "工作室 P1S", "第二台打印机名称")
    var p9 = AppSettings()
    snap8.apply(to: p9, type: .homeAssistant)
    checkEqual(p9.bambuPrinters[0].statusEntityID, "sensor.a", "多打印机快照套用字段")
    let enc8 = try JSONEncoder().encode([printerA, printerB])
    let dec8 = try JSONDecoder().decode([BambuLabCardSettings].self, from: enc8)
    checkEqual(dec8[1].name, "工作室 P1S", "BambuLabCardSettings Codable 往返")
    // 多打印机卡片防串扰：同一实体池下，两台打印机各自只取自己的实体渲染
    // （名称徽标不同、状态实体不同 → 卡片不同；完全相同配置 → 卡片一致）
    let crosstalkEntities = [
        HAEntity(entityId: "sensor.a", friendlyName: "A 状态", state: "printing", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.b", friendlyName: "B 状态", state: "idle", unitOfMeasurement: nil)
    ]
    let crosstalkNow = Date(timeIntervalSince1970: 1_750_000_000)
    let printerCardA = try ScreenRenderer.renderBambuLab(printerA, entities: crosstalkEntities, settings: haSettings, now: crosstalkNow)
    let printerCardB = try ScreenRenderer.renderBambuLab(printerB, entities: crosstalkEntities, settings: haSettings, now: crosstalkNow)
    check(printerCardA.data != printerCardB.data, "两台打印机卡片应各自渲染自身数据（名称/状态不同）")
    let printerCardA2 = try ScreenRenderer.renderBambuLab(printerA, entities: crosstalkEntities, settings: haSettings, now: crosstalkNow)
    check(printerCardA.data == printerCardA2.data, "同一台打印机重复渲染应一致（不受另一台影响）")
    let dataUpdateAt = Date(timeIntervalSince1970: 1_749_999_900)
    let dataFooterA = try ScreenRenderer.renderBambuLab(
        printerA, entities: crosstalkEntities, settings: haSettings,
        now: crosstalkNow, dataUpdatedAt: dataUpdateAt)
    let dataFooterSame = try ScreenRenderer.renderBambuLab(
        printerA, entities: crosstalkEntities, settings: haSettings,
        now: crosstalkNow.addingTimeInterval(86_400), dataUpdatedAt: dataUpdateAt)
    checkEqual(dataFooterA.data, dataFooterSame.data,
               "Bambu 页脚只随数据更新时间变化，不再显示当前时间/日期")
    let dataFooterNew = try ScreenRenderer.renderBambuLab(
        printerA, entities: crosstalkEntities, settings: haSettings,
        now: crosstalkNow, dataUpdatedAt: dataUpdateAt.addingTimeInterval(1))
    check(dataFooterA.data != dataFooterNew.data, "Bambu 页脚应显示最新数据更新时间")
    var renamedPrinterA = printerA
    renamedPrinterA.name = "书房 A1"
    let renamedPrinterCardA = try ScreenRenderer.renderBambuLab(renamedPrinterA, entities: crosstalkEntities,
                                                                 settings: haSettings, now: crosstalkNow)
    check(renamedPrinterCardA.data != printerCardA.data, "键盘卡片头部应明确渲染对应打印机设备名")
    var printerA3 = printerA
    printerA3.statusEntityID = "sensor.b"
    let printerCardA3 = try ScreenRenderer.renderBambuLab(printerA3, entities: crosstalkEntities, settings: haSettings, now: crosstalkNow)
    check(printerCardA3.data != printerCardA.data, "更换实体映射后卡片应变化（字段独立生效）")
    // 显示选项：旧“紧凑”设置迁移到标准；各区块开关仍正常往返
    var displayBambu = BambuLabCardSettings(statusEntityID: "sensor.a", progressEntityID: "sensor.p1p_progress",
                                            layout: .compact, showStatus: false)
    var displaySnap = DeviceSettings()
    displayBambu.apply(to: &displaySnap)
    let displayBack = BambuLabCardSettings.from(displaySnap)
    checkEqual(displayBack.layout, .standard, "旧紧凑布局自动迁移为标准")
    checkEqual(BambuCardLayout.selectableCases, [.standard, .large],
               "布局选择器只保留标准与大字")
    checkEqual(displayBack.showStatus, false, "显示状态开关 apply/from 往返")
    checkEqual(displayBack.showProgress, true, "显示进度开关默认开启")
    let cardNoStatus = try ScreenRenderer.renderBambuLab(displayBambu, entities: crosstalkEntities, settings: haSettings, now: crosstalkNow)
    check(cardNoStatus.data != printerCardA3.data, "关闭显示状态后卡片渲染应不同")
    var clearedStatus = displayBambu
    clearedStatus.statusEntityID = ""
    clearedStatus.showStatus = true
    var clearedStatusHidden = clearedStatus
    clearedStatusHidden.showStatus = false
    let clearedStatusCard = try ScreenRenderer.renderBambuLab(
        clearedStatus, entities: crosstalkEntities, settings: haSettings, now: crosstalkNow)
    let clearedStatusHiddenCard = try ScreenRenderer.renderBambuLab(
        clearedStatusHidden, entities: crosstalkEntities, settings: haSettings, now: crosstalkNow)
    checkEqual(clearedStatusCard.data, clearedStatusHiddenCard.data,
               "解除工作状态实体关联后应直接隐藏该项，不再显示未配置占位")
    var displayLarge = displayBambu
    displayLarge.layout = .large
    displayLarge.showStatus = true
    let cardLarge = try ScreenRenderer.renderBambuLab(displayLarge, entities: crosstalkEntities, settings: haSettings, now: crosstalkNow)
    check(cardLarge.data != cardNoStatus.data, "大字布局渲染应不同于标准布局")
    let largeProgressEntity = HAEntity(entityId: "sensor.p1p_progress", friendlyName: "打印进度",
                                       state: "68", unitOfMeasurement: "%")
    let cardLargeWithProgress = try ScreenRenderer.renderBambuLab(
        displayLarge, entities: crosstalkEntities + [largeProgressEntity],
        settings: haSettings, now: crosstalkNow)
    check(cardLargeWithProgress.data != cardLarge.data,
          "大字布局应在顶部渲染进度条与带百分号的放大打印进度")
    checkEqual(ScreenRenderer.bambuLargeProgressNumberSize, 34,
               "大字布局进度数字保持原有字号")
    checkEqual(ScreenRenderer.bambuLargeProgressPercentSize,
               ScreenRenderer.bambuLargeProgressNumberSize / 2,
               "大字布局百分号字号应为数字的一半")
    let cameraPictureSize = ScreenRenderer.bambuPictureSize(
        source: .camera, maxWidth: 114, maxHeight: 160)
    checkEqual(cameraPictureSize.width, 114, "Bambu 摄像头画面使用完整可用宽度")
    checkEqual(cameraPictureSize.height, 114, "Bambu 摄像头画面固定为正方形")
    let constrainedCameraSize = ScreenRenderer.bambuPictureSize(
        source: .camera, maxWidth: 114, maxHeight: 72)
    checkEqual(constrainedCameraSize.width, 72, "Bambu 摄像头空间不足时等比缩小宽度")
    checkEqual(constrainedCameraSize.height, 72, "Bambu 摄像头空间不足时保持正方形")
    let taskCoverSize = ScreenRenderer.bambuPictureSize(
        source: .taskCover, maxWidth: 114, maxHeight: 160)
    check(abs(taskCoverSize.width / taskCoverSize.height - 16.0 / 9.0) < 0.001,
          "Bambu 任务封面继续保持 16:9")
    let smallCenterObject = CGRect(x: 0.46, y: 0.44, width: 0.08, height: 0.11)
    let earlyZoom = BambuCameraAutoZoom.plannedState(
        candidate: smallCenterObject, confidence: 0.8, progress: 5,
        previous: BambuCameraZoomState())
    check(earlyZoom.crop.width <= 0.46, "激进自动聚焦在早期小模型时应达到约 2.5 倍放大")
    check(abs(earlyZoom.crop.width - earlyZoom.crop.height) < 0.001,
          "自动聚焦裁切区域必须保持正方形")
    let laterZoom = BambuCameraAutoZoom.plannedState(
        candidate: smallCenterObject, confidence: 0.8, progress: 80,
        previous: earlyZoom)
    check(laterZoom.crop.width > earlyZoom.crop.width,
          "打印进度增加时自动聚焦必须主动扩大取景范围")
    check(laterZoom.crop.width >= 0.80,
          "打印进入后期时必须恢复足够宽的画面，避免大模型被裁掉")
    let largerObject = CGRect(x: 0.30, y: 0.28, width: 0.42, height: 0.36)
    let grownModelZoom = BambuCameraAutoZoom.plannedState(
        candidate: largerObject, confidence: 0.85, progress: 82,
        previous: laterZoom)
    check(grownModelZoom.crop.width >= laterZoom.crop.width,
          "识别到模型体积增大时取景范围不能反向缩小")
    let firstMiss = BambuCameraAutoZoom.plannedState(
        candidate: nil, confidence: 0, progress: 83, previous: grownModelZoom)
    check(firstMiss.crop.width >= grownModelZoom.crop.width,
          "单帧识别失败时先放宽取景而不是继续放大")
    let secondMiss = BambuCameraAutoZoom.plannedState(
        candidate: nil, confidence: 0, progress: 84, previous: firstMiss)
    checkEqual(secondMiss.crop, CGRect(x: 0, y: 0, width: 1, height: 1),
               "连续两帧识别失败时恢复完整画面")
    let restartedZoom = BambuCameraAutoZoom.plannedState(
        candidate: smallCenterObject, confidence: 0.8, progress: 3,
        previous: laterZoom)
    check(restartedZoom.crop.width < laterZoom.crop.width,
          "新任务进度回退后应重置上一任务的取景范围")
    let invalidZoomImage = Data([0x00, 0x01, 0x02])
    let invalidZoomOutput = BambuCameraAutoZoom.process(
        imageData: invalidZoomImage, progress: 20, previous: BambuCameraZoomState())
    checkEqual(invalidZoomOutput.imageData, invalidZoomImage,
               "自动聚焦无法解码时原样返回输入，不能阻断推送")
    check(!invalidZoomOutput.usedZoom, "无效图片不得标记为已裁切")
    check(ScreenRenderer.bambuLargeStatusBackdropSize > ScreenRenderer.bambuLargeProgressNumberSize,
          "大字布局状态背景字应比进度数字更大")
    checkEqual(ScreenRenderer.bambuRegularStatusSize, 20,
               "Bambu 与 Formlabs 的常规打印状态字号统一")
    check(ScreenRenderer.bambuDataFooterSize >= 9,
          "Bambu 数据更新时间字号应在实体屏幕上清晰可读")
    // 主题色：Bambu Lab 强调色选项在 apply/from/Codable 往返保留，且渲染不同于跟随全局
    var accentBambu = displayBambu
    accentBambu.themeAccent = .bambuLab
    var accentSnap = DeviceSettings()
    accentBambu.apply(to: &accentSnap)
    checkEqual(BambuLabCardSettings.from(accentSnap).themeAccent, .bambuLab, "主题色 apply/from 往返")
    let accentGlobalCard = try ScreenRenderer.renderBambuLab(displayBambu, entities: crosstalkEntities, settings: haSettings, now: crosstalkNow)
    let accentBambuCard = try ScreenRenderer.renderBambuLab(accentBambu, entities: crosstalkEntities, settings: haSettings, now: crosstalkNow)
    check(accentBambuCard.data != accentGlobalCard.data, "Bambu Lab 主题色渲染应不同于跟随全局")
    let accentRoundtrip = try JSONDecoder().decode(BambuLabCardSettings.self,
                                                   from: JSONEncoder().encode(accentBambu))
    checkEqual(accentRoundtrip.themeAccent, .bambuLab, "主题色 Codable 往返")
    var autoZoomBambu = displayBambu
    autoZoomBambu.autoCameraZoom = true
    let autoZoomRoundtrip = try JSONDecoder().decode(
        BambuLabCardSettings.self, from: JSONEncoder().encode(autoZoomBambu))
    checkEqual(autoZoomRoundtrip.autoCameraZoom, true, "自动放大小模型设置 Codable 往返")
    // 旧档案兼容：缺失显示选项字段的老 JSON 可正常解码（回退默认值）
    let legacyJSON = #"{"name":"打印机","enableAlert":true,"statusEntityID":"sensor.a"}"#
    let legacyDecoded = try JSONDecoder().decode(BambuLabCardSettings.self, from: Data(legacyJSON.utf8))
    checkEqual(legacyDecoded.name, "打印机", "旧档案解码-名称")
    checkEqual(legacyDecoded.layout, .standard, "旧档案解码-布局回退标准")
    checkEqual(legacyDecoded.showStatus, true, "旧档案解码-显示开关回退开启")
    // 自动匹配隔离：两台打印机使用不同前缀实体，自动匹配应只填充各自字段
    let multiPrinterEntities = [
        HAEntity(entityId: "sensor.p1p_status", friendlyName: "P1P 状态", state: "printing", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.p1p_progress", friendlyName: "P1P 进度", state: "50", unitOfMeasurement: "%"),
        HAEntity(entityId: "sensor.p1p_nozzle_temp", friendlyName: "P1P 喷嘴温度", state: "200", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.a1_status", friendlyName: "A1 状态", state: "idle", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.a1_progress", friendlyName: "A1 进度", state: "30", unitOfMeasurement: "%"),
        HAEntity(entityId: "sensor.a1_nozzle_temp", friendlyName: "A1 喷嘴温度", state: "180", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.other_temp", friendlyName: "其他温度", state: "25", unitOfMeasurement: "°C"),
    ]
    let p1pKnown = multiPrinterEntities[0]  // sensor.p1p_status
    let a1Known = multiPrinterEntities[3]   // sensor.a1_status
    let p1pMatched = BambuEntityMatcher.detect(from: p1pKnown, allEntities: multiPrinterEntities)
    let a1Matched = BambuEntityMatcher.detect(from: a1Known, allEntities: multiPrinterEntities)
    checkEqual(p1pMatched.statusEntityID, "sensor.p1p_status", "P1P 自动匹配应使用 P1P 前缀实体")
    checkEqual(p1pMatched.progressEntityID, "sensor.p1p_progress", "P1P 自动匹配进度应使用 P1P 前缀实体")
    checkEqual(p1pMatched.nozzleTempEntityID, "sensor.p1p_nozzle_temp", "P1P 自动匹配喷嘴温度应使用 P1P 前缀实体")
    checkEqual(a1Matched.statusEntityID, "sensor.a1_status", "A1 自动匹配应使用 A1 前缀实体")
    checkEqual(a1Matched.progressEntityID, "sensor.a1_progress", "A1 自动匹配进度应使用 A1 前缀实体")
    checkEqual(a1Matched.nozzleTempEntityID, "sensor.a1_nozzle_temp", "A1 自动匹配喷嘴温度应使用 A1 前缀实体")
    check(p1pMatched.statusEntityID != a1Matched.statusEntityID, "两台打印机自动匹配结果应互不串扰")
    check(p1pMatched.progressEntityID != a1Matched.progressEntityID, "两台打印机进度实体应互不串扰")
    // 自动匹配入口只接受打印状态实体；普通进度/通用状态传感器不能触发匹配
    let genericStatus = HAEntity(entityId: "sensor.living_status", friendlyName: "客厅状态",
                                 state: "on", unitOfMeasurement: nil)
    check(BambuEntityMatcher.isPrintStatusEntity(p1pKnown), "P1P 状态识别为打印状态实体")
    check(!BambuEntityMatcher.isPrintStatusEntity(multiPrinterEntities[1]), "打印进度不能作为自动匹配种子")
    check(!BambuEntityMatcher.isPrintStatusEntity(genericStatus), "普通状态传感器不进入打印状态候选")
    checkEqual(BambuEntityMatcher.printStatusCandidates(multiPrinterEntities + [genericStatus]).count,
               2, "自动匹配候选只保留两台打印机的状态实体")
    // 用户改显示名称后仍按稳定 ID / 同前缀兄弟实体 / 状态值识别，不依赖 friendly_name。
    let renamedExact = HAEntity(entityId: "sensor.x2d_serial_print_status",
                                friendlyName: "书房设备", state: "printing", unitOfMeasurement: nil)
    let renamedLegacy = HAEntity(entityId: "sensor.custom_machine_status",
                                 friendlyName: "角落设备", state: "unknown", unitOfMeasurement: nil)
    let renamedSiblings = [
        HAEntity(entityId: "sensor.custom_machine_progress", friendlyName: "数值一",
                 state: "50", unitOfMeasurement: "%"),
        HAEntity(entityId: "sensor.custom_machine_nozzle_temp", friendlyName: "数值二",
                 state: "200", unitOfMeasurement: "°C"),
    ]
    let customIDStatus = HAEntity(entityId: "sensor.user_renamed_entity",
                                  friendlyName: "我的设备", state: "printing", unitOfMeasurement: nil)
    let renamePool = [renamedLegacy, customIDStatus, renamedExact] + renamedSiblings + [genericStatus]
    let renameCandidates = BambuEntityMatcher.printStatusCandidates(renamePool)
    check(renameCandidates.contains { $0.entityId == renamedExact.entityId },
          "标准打印状态 ID 改显示名称后仍在候选中")
    check(renameCandidates.contains { $0.entityId == renamedLegacy.entityId },
          "旧状态实体改显示名称后由同前缀兄弟实体识别")
    check(renameCandidates.contains { $0.entityId == customIDStatus.entityId },
          "用户改 entity_id 后由打印状态值保留候选")
    checkEqual(renameCandidates.first?.entityId, renamedExact.entityId,
               "明确 print_status 后缀在默认排序中优先")
    check(!renameCandidates.contains { $0.entityId == genericStatus.entityId },
          "普通状态传感器不会因放宽改名兼容而误入")
    let invalidSeedMatch = BambuEntityMatcher.detect(from: multiPrinterEntities[1],
                                                     allEntities: multiPrinterEntities)
    checkEqual(invalidSeedMatch.statusEntityID, "", "非打印状态实体不会启动自动匹配")
    // 用户关闭默认筛选后，可明确指定任意 sensor 作为状态起点（适配设备名/entity_id 改动）。
    let fullyRenamedSeed = HAEntity(entityId: "sensor.my_custom_device", friendlyName: "自定义名称",
                                    state: "unknown", unitOfMeasurement: nil)
    checkEqual(BambuEntityMatcher.detect(from: fullyRenamedSeed,
                                         allEntities: [fullyRenamedSeed]).statusEntityID,
               "", "默认筛选仍拒绝无打印机特征的自定义实体")
    checkEqual(BambuEntityMatcher.detect(from: fullyRenamedSeed,
                                         allEntities: [fullyRenamedSeed],
                                         allowUnfilteredSeed: true).statusEntityID,
               fullyRenamedSeed.entityId, "关闭默认筛选后信任用户选择的 sensor")
    let nonSensorSeed = HAEntity(entityId: "switch.my_custom_device", friendlyName: "错误类型",
                                 state: "on", unitOfMeasurement: nil)
    let popupCandidates = [fullyRenamedSeed, renamedExact, nonSensorSeed]
    checkEqual(BambuEntityMatcher.printStatusCandidates(
        popupCandidates, useDefaultFilter: true).map(\.entityId),
        [renamedExact.entityId], "弹窗开启默认筛选时只显示可信打印状态实体")
    checkEqual(Set(BambuEntityMatcher.printStatusCandidates(
        popupCandidates, useDefaultFilter: false).map(\.entityId)),
        Set([fullyRenamedSeed.entityId, renamedExact.entityId]),
        "弹窗关闭默认筛选时立即显示全部 sensor 实体")
    checkEqual(BambuEntityMatcher.detect(from: nonSensorSeed,
                                         allEntities: [nonSensorSeed],
                                         allowUnfilteredSeed: true).statusEntityID,
               "", "关闭筛选仍只允许 sensor 作为打印状态")
    var filterPreference = DeviceSettings()
    filterPreference.bambuUseDefaultEntityFilter = false
    let filterPreferenceRoundTrip = try JSONDecoder().decode(
        DeviceSettings.self, from: JSONEncoder().encode(filterPreference))
    checkEqual(filterPreferenceRoundTrip.bambuUseDefaultEntityFilter, false,
               "打印机默认筛选开关按设备持久化")
    checkEqual(DeviceSettings().bambuUseDefaultEntityFilter, nil,
               "旧设备缺筛选字段时由界面回退为默认开启")
    // 独立打印机设备架构：DeviceType.bambuLab capture/apply 往返（每台打印机 = 独立设备）
    var prS = AppSettings()
    prS.bambuPrinterName = "客厅 A1"
    prS.bambuEnableAlert = false
    prS.bambuStatusEntityID = "sensor.a1_status"
    prS.bambuProgressEntityID = "sensor.a1_progress"
    prS.bambuEndTimeEntityID = "sensor.a1_finish_time"
    prS.bambuTimeDisplayMode = .endTime
    prS.bambuAutoCameraZoom = true
    let prSnap = DeviceSettings.capture(from: prS, type: .bambuLab)
    checkEqual(prSnap.bambuPrinterName, "客厅 A1", "Bambu 设备快照捕获-名称")
    checkEqual(prSnap.bambuStatusEntityID, "sensor.a1_status", "Bambu 设备快照捕获-状态实体")
    checkEqual(prSnap.bambuEnableAlert, false, "Bambu 设备快照捕获-告警开关")
    checkEqual(prSnap.bambuAutoCameraZoom, true, "Bambu 设备快照捕获-自动放大小模型")
    checkEqual(prSnap.bambuEndTimeEntityID, "sensor.a1_finish_time", "Bambu 设备快照捕获-结束时间实体")
    checkEqual(prSnap.bambuTimeDisplayMode, .endTime, "Bambu 设备快照捕获-时间显示模式")
    var prS2 = AppSettings()
    prSnap.apply(to: prS2, type: .bambuLab)
    checkEqual(prS2.bambuPrinterName, "客厅 A1", "Bambu 设备快照套用-名称")
    checkEqual(prS2.bambuProgressEntityID, "sensor.a1_progress", "Bambu 设备快照套用-进度实体")
    checkEqual(prS2.bambuAutoCameraZoom, true, "Bambu 设备快照套用-自动放大小模型")
    checkEqual(prS2.bambuEndTimeEntityID, "sensor.a1_finish_time", "Bambu 设备快照套用-结束时间实体")
    checkEqual(prS2.bambuTimeDisplayMode, .endTime, "Bambu 设备快照套用-时间显示模式")
    // activeBambuLabSettings：多台打印机设备时按活动 ID 取对应设备
    var archS = AppSettings()
    var dev1 = DeviceSettings()
    dev1.bambuPrinterName = "打印机 1"
    dev1.bambuStatusEntityID = "sensor.p1p_status"
    var dev2 = DeviceSettings()
    dev2.bambuPrinterName = "打印机 2"
    dev2.bambuStatusEntityID = "sensor.2_print_status"
    let printer1 = ManagedDevice(type: .bambuLab, name: "打印机 1", settings: dev1)
    let printer2 = ManagedDevice(type: .bambuLab, name: "打印机 2", settings: dev2)
    archS.devices = [printer1, printer2]
    archS.activeBambuLabDeviceID = printer2.id
    checkEqual(archS.activeBambuLabSettings()?.name, "打印机 2", "活动打印机设备解析-按活动 ID")
    checkEqual(archS.activeBambuLabSettings()?.statusEntityID, "sensor.2_print_status", "活动打印机实体-第二台")
    archS.activeBambuLabDeviceID = printer1.id
    checkEqual(archS.activeBambuLabSettings()?.statusEntityID, "sensor.p1p_status", "活动打印机实体-第一台")
    // 卡片徽标优先用设备名（即使旧版 bambuPrinterName 字段不同）
    var devNameMismatch = DeviceSettings()
    devNameMismatch.bambuPrinterName = "打印机"          // 旧字段残留默认名
    let devNameMismatchDevice = ManagedDevice(type: .bambuLab, name: "打印机 2", settings: devNameMismatch)
    checkEqual(BambuLabCardSettings.from(devNameMismatchDevice).name, "打印机 2", "卡片徽标优先设备名")
    // 旧架构迁移：HA 设备内嵌 bambuPrinters → 独立打印机设备（幂等）
    var legacyS = AppSettings()
    var haDev = DeviceSettings()
    haDev.haServerURL = "http://192.168.1.10:8123"
    haDev.bambuPrinters = [printerA, printerB]
    legacyS.devices = [ManagedDevice(type: .homeAssistant, name: "Home Assistant", settings: haDev)]
    let migratedCount = legacyS.migrateBambuPrintersToDevices()
    checkEqual(migratedCount, 2, "旧架构迁移-打印机设备数量")
    checkEqual(legacyS.devices.filter { $0.type == .bambuLab }.count, 2, "迁移后 Bambu 设备数量")
    let migratedP = legacyS.devices.filter { $0.type == .bambuLab }
    checkEqual(migratedP[0].name, "客厅 A1", "迁移后第一台设备名")
    checkEqual(migratedP[0].settings.bambuStatusEntityID, "sensor.a", "迁移后第一台状态实体")
    checkEqual(migratedP[1].settings.bambuStatusEntityID, "sensor.b", "迁移后第二台状态实体")
    checkEqual(legacyS.activeBambuLabDeviceID, migratedP.first?.id, "迁移后活动打印机指向第一台")
    let migratedTwice = legacyS.migrateBambuPrintersToDevices()
    checkEqual(migratedTwice, 0, "迁移幂等-重复执行不新增")
    checkEqual(legacyS.devices.filter { $0.type == .bambuLab }.count, 2, "迁移幂等-设备数不变")
    // 实体自动匹配：从打印状态实体推导其余字段（前缀 + 关键词）
    let printerEntities = [
        HAEntity(entityId: "sensor.bambu_01h08c0a0001_status", friendlyName: "Bambu Lab A1 状态", state: "idle", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.bambu_01h08c0a0001_progress", friendlyName: "打印进度", state: "50", unitOfMeasurement: "%"),
        HAEntity(entityId: "sensor.bambu_01h08c0a0001_nozzle_temp", friendlyName: "喷嘴温度", state: "200", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.bambu_01h08c0a0001_bed_temp", friendlyName: "热床温度", state: "55", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.bambu_01h08c0a0001_current_task", friendlyName: "当前任务", state: "Benchy", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.bambu_01h08c0a0001_remaining_time", friendlyName: "剩余时间", state: "30", unitOfMeasurement: "分钟"),
        HAEntity(entityId: "sensor.bambu_01h08c0a0001_estimated_end_time", friendlyName: "预计结束时间", state: "2026-09-05T18:30:00+08:00", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.bambu_01h08c0a0001_hms_error", friendlyName: "错误码", state: "0", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.bambu_01h08c0a0001_current_stage", friendlyName: "当前阶段", state: "printing", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.living_temp", friendlyName: "客厅温度", state: "23", unitOfMeasurement: "°C"),
    ]
    let known = printerEntities[0]
    let matched = BambuEntityMatcher.detect(from: known, allEntities: printerEntities)
    checkEqual(matched.statusEntityID, "sensor.bambu_01h08c0a0001_status", "自动匹配状态实体")
    checkEqual(matched.progressEntityID, "sensor.bambu_01h08c0a0001_progress", "自动匹配进度实体")
    checkEqual(matched.nozzleTempEntityID, "sensor.bambu_01h08c0a0001_nozzle_temp", "自动匹配喷嘴实体")
    checkEqual(matched.bedTempEntityID, "sensor.bambu_01h08c0a0001_bed_temp", "自动匹配热床实体")
    checkEqual(matched.taskEntityID, "sensor.bambu_01h08c0a0001_current_task", "自动匹配任务实体")
    checkEqual(matched.remainingEntityID, "sensor.bambu_01h08c0a0001_remaining_time", "自动匹配剩余实体")
    checkEqual(matched.endTimeEntityID, "sensor.bambu_01h08c0a0001_estimated_end_time", "自动匹配结束时间实体")
    checkEqual(matched.errorEntityID, "sensor.bambu_01h08c0a0001_hms_error", "自动匹配错误码实体")
    // 前缀提取
    checkEqual(BambuEntityMatcher.prefix(of: "sensor.bambu_01h08c0a0001_status"), "sensor.bambu_01h08c0a0001", "实体前缀提取")
    checkEqual(BambuEntityMatcher.prefix(of: "sensor.bambu_x_nozzle_temp"), "sensor.bambu_x", "多词后缀前缀提取")
    checkEqual(BambuEntityMatcher.prefix(of: "sensor.x2d_20p6bj652500750_print_status"),
               "sensor.x2d_20p6bj652500750", "print_status 完整后缀提取")
    let serialPrinterEntities = [
        HAEntity(entityId: "sensor.x2d_20p6bj652500750_print_status", friendlyName: "X2D 打印状态",
                 state: "printing", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.x2d_20p6bj652500750_print_progress", friendlyName: "X2D 打印进度",
                 state: "42", unitOfMeasurement: "%"),
        HAEntity(entityId: "sensor.x2d_20p6bj652500750_task_name", friendlyName: "X2D 任务",
                 state: "benchy", unitOfMeasurement: nil),
        HAEntity(entityId: "binary_sensor.x2d_20p6bj652500750_hms_errors", friendlyName: "X2D HMS",
                 state: "off", unitOfMeasurement: nil),
    ]
    let serialMatch = BambuEntityMatcher.detect(from: serialPrinterEntities[0],
                                                allEntities: serialPrinterEntities)
    checkEqual(serialMatch.progressEntityID, "sensor.x2d_20p6bj652500750_print_progress",
               "print_status 种子匹配同序列号进度")
    checkEqual(serialMatch.taskEntityID, "sensor.x2d_20p6bj652500750_task_name",
               "print_status 种子匹配 task_name")
    checkEqual(serialMatch.errorEntityID, "binary_sensor.x2d_20p6bj652500750_hms_errors",
               "打印机身份可跨 sensor/binary_sensor 域匹配 HMS")
    // 型号识别：attributes.model 优先，其次名称/entity_id
    let modelA1 = HAEntity(entityId: "sensor.bambu_a1_status", friendlyName: "打印机状态", state: "idle", unitOfMeasurement: nil, model: "A1")
    checkEqual(BambuModelDetector.model(of: modelA1), "A1", "型号识别 attributes.model")
    let modelP1S = HAEntity(entityId: "sensor.bambu_p1s_status", friendlyName: "Bambu Lab P1S 打印机", state: "idle", unitOfMeasurement: nil)
    checkEqual(BambuModelDetector.model(of: modelP1S), "P1S", "型号识别名称匹配")
    let modelNone = HAEntity(entityId: "sensor.bambu_status", friendlyName: "打印机", state: "idle", unitOfMeasurement: nil)
    check(BambuModelDetector.model(of: modelNone) == nil, "未识别型号返回 nil")
    let modelX2D = HAEntity(entityId: "sensor.x2d_20p6bj652500750_print_status", friendlyName: "打印机状态", state: "idle", unitOfMeasurement: nil)
    checkEqual(BambuModelDetector.model(of: modelX2D), "X2D", "型号识别 X2D（entity_id 序列号前缀）")
    let modelX1Carbon = HAEntity(entityId: "sensor.bambu_x1_carbon_status", friendlyName: "Bambu Lab X1 Carbon", state: "idle", unitOfMeasurement: nil)
    checkEqual(BambuModelDetector.model(of: modelX1Carbon), "X1C", "型号识别 X1 Carbon（长模式优先于 X1）")
    // parseStates 解析 model 属性
    let modelJSON = """
    [{"entity_id": "sensor.bambu_x_status", "state": "idle",
      "attributes": {"friendly_name": "打印机", "model": "X1C"}}]
    """
    let modelEntities = try HomeAssistantClient.parseStates(data: Data(modelJSON.utf8))
    checkEqual(modelEntities[0].model, "X1C", "parseStates 解析型号属性")
    // 实体自定义显示名称：别名渲染优先于默认名；不同别名渲染不同
    let aliasEntities = [HAEntity(entityId: "sensor.living_temp", friendlyName: "客厅温度", state: "23", unitOfMeasurement: "°C")]
    let defaultName = try ScreenRenderer.renderHA(aliasEntities, aliases: [:], errorText: nil, settings: haSettings)
    let aliased = try ScreenRenderer.renderHA(aliasEntities, aliases: ["sensor.living_temp": "玄关温度"], errorText: nil, settings: haSettings)
    check(defaultName.data != aliased.data, "别名渲染与默认名不同")
    let alias2 = try ScreenRenderer.renderHA(aliasEntities, aliases: ["sensor.living_temp": "卧室温度"], errorText: nil, settings: haSettings)
    check(aliased.data != alias2.data, "不同别名渲染不同")
    // 基线：别名随 HA 设备快照往返
    var a10 = AppSettings()
    a10.haEntityAliases = ["sensor.living_temp": "玄关温度"]
    let snap10 = DeviceSettings.capture(from: a10, type: .homeAssistant)
    checkEqual(snap10.haEntityAliases?["sensor.living_temp"], "玄关温度", "别名随 HA 设备快照捕获")
    var a11 = AppSettings()
    snap10.apply(to: a11, type: .homeAssistant)
    checkEqual(a11.haEntityAliases["sensor.living_temp"], "玄关温度", "别名随 HA 设备快照套用")
    // 多实体 + 别名 + 状态图标色（off 与 on 渲染不同已覆盖状态色变化）
    let unconfigured = try ScreenRenderer.renderHA([], errorText: nil, settings: haSettings)
    check(withEntity.data != unconfigured.data, "HA 含实体与未配置渲染应不同")
    let errorCard = try ScreenRenderer.renderHA([], errorText: "令牌无效", settings: haSettings)
    check(errorCard.data != unconfigured.data, "HA 错误提示渲染应不同")

    // 画板模块：含 HA 实体 vs 无实体渲染不同（模块可用；多实体/单实体/空态）
    let system = SystemSnapshot(cpuPercent: 0, memoryPercent: 0, usedMemoryBytes: 0, totalMemoryBytes: 0,
                                downloadBytesPerSecond: 0, uploadBytesPerSecond: 0, uptime: 0, sampledAt: Date())
    let pomo = PomodoroSnapshot(phase: .focus, effectivePhase: .focus, taskName: "任务",
                                remaining: 100, duration: 1500, completedFocusSessions: 1,
                                endsAt: Date().addingTimeInterval(100))
    var canvas = AppSettings()
    canvas.canvasModules = [CanvasModule.homeAssistant.rawValue]
    let haSnap = HASnapshot(entities: entities, selectedEntities: Array(entities.prefix(2)))
    let haCanvas = try ScreenRenderer.renderCanvas(modules: canvas.canvasModuleList, system: system,
                                                   nowPlaying: .sample, pomodoro: pomo,
                                                   customText: "", settings: canvas,
                                                   ha: haSnap)
    checkEqual(haCanvas.image.width, 142, "HA 画板模块宽度")
    check(haCanvas.data.count <= ScreenRenderer.maximumFileSize, "HA 画板模块大小")
    let emptyCanvas = try ScreenRenderer.renderCanvas(modules: canvas.canvasModuleList, system: system,
                                                      nowPlaying: .sample, pomodoro: pomo,
                                                      customText: "", settings: canvas)
    check(haCanvas.data != emptyCanvas.data, "HA 画板模块含实体与空态渲染应不同")

    // 异常监控判定：状态不符 / 错误码非空触发；正常态不触发
    let printerStatus = HAEntity(entityId: "sensor.bambu_printer", friendlyName: "打印机",
                                 state: "running", unitOfMeasurement: nil)
    let printerError = HAEntity(entityId: "sensor.bambu_error", friendlyName: "打印机错误码",
                                state: "0x03080005", unitOfMeasurement: nil)
    let printerIdle = HAEntity(entityId: "sensor.bambu_printer", friendlyName: "打印机",
                               state: "idle", unitOfMeasurement: nil)
    let printerNoError = HAEntity(entityId: "sensor.bambu_error", friendlyName: "打印机错误码",
                                  state: "none", unitOfMeasurement: nil)
    // 状态不符 → 异常
    let r1 = HomeAssistantClient.monitor(entities: [printerStatus, printerError],
                                         monitorEntityID: "sensor.bambu_printer",
                                         expectedState: "idle",
                                         errorEntityID: "")
    check(r1.isAbnormal, "HA 监控：状态不符应判异常")
    check(r1.reason?.contains("running") == true, "HA 监控：异常原因含当前状态")
    // 状态符合 → 正常
    let r2 = HomeAssistantClient.monitor(entities: [printerIdle, printerError],
                                         monitorEntityID: "sensor.bambu_printer",
                                         expectedState: "IDLE",
                                         errorEntityID: "")
    check(!r2.isAbnormal, "HA 监控：状态符合应正常（忽略大小写）")
    // 错误码非空 → 异常（即使状态正常）
    let r3 = HomeAssistantClient.monitor(entities: [printerIdle, printerError],
                                         monitorEntityID: "sensor.bambu_printer",
                                         expectedState: "idle",
                                         errorEntityID: "sensor.bambu_error")
    check(r3.isAbnormal, "HA 监控：错误码非空应判异常")
    check(r3.reason?.contains("0x03080005") == true, "HA 监控：异常原因含错误码")
    // 错误码 none → 正常
    let r4 = HomeAssistantClient.monitor(entities: [printerIdle, printerNoError],
                                         monitorEntityID: "sensor.bambu_printer",
                                         expectedState: "idle",
                                         errorEntityID: "sensor.bambu_error")
    check(!r4.isAbnormal, "HA 监控：错误码 none 应正常")
    // 未设条件 → 正常
    let r5 = HomeAssistantClient.monitor(entities: [printerStatus], monitorEntityID: "",
                                         expectedState: "", errorEntityID: "")
    check(!r5.isAbnormal, "HA 监控：无条件应正常")

    // 监控设置往返
    let mrt = AppSettings()
    mrt.haMonitorEnabled = true
    mrt.haMonitorEntityID = "sensor.bambu_printer"
    mrt.haMonitorExpectedState = "idle"
    mrt.haMonitorErrorEntityID = "sensor.bambu_error"
    let mDecoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(mrt))
    checkEqual(mDecoded.haMonitorEnabled, true, "HA 监控开关往返")
    checkEqual(mDecoded.haMonitorEntityID, "sensor.bambu_printer", "HA 监控实体往返")
    checkEqual(mDecoded.haMonitorExpectedState, "idle", "HA 监控期望状态往返")
    checkEqual(mDecoded.haMonitorErrorEntityID, "sensor.bambu_error", "HA 监控错误码实体往返")

    // 告警卡渲染：尺寸正常、与普通 HA 卡不同
    let alertCard = try ScreenRenderer.renderHAAlert(title: "打印机", message: "0x03080005",
                                                     settings: haSettings)
    checkEqual(alertCard.image.width, 142, "HA 告警卡宽度")
    checkEqual(alertCard.image.height, 428, "HA 告警卡高度")
    check(alertCard.data.count <= ScreenRenderer.maximumFileSize, "HA 告警卡大小")
    check(alertCard.data != withEntity.data, "HA 告警卡与普通卡渲染应不同")
    check(alertCard.data != unconfigured.data, "HA 告警卡与未配置渲染应不同")

    // Bambu Lab 自动识别：从实体列表按关键词归类字段
    let bambuEntities = [
        HAEntity(entityId: "sensor.bambu_printer_status", friendlyName: "打印机状态", state: "idle", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.bambu_print_progress", friendlyName: "打印进度", state: "45", unitOfMeasurement: "%"),
        HAEntity(entityId: "sensor.bambu_current_task", friendlyName: "当前任务", state: "花瓶 v2", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.bambu_nozzle_temp", friendlyName: "喷嘴温度", state: "210", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.bambu_bed_temp", friendlyName: "热床温度", state: "60", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.bambu_remaining_time", friendlyName: "剩余时间", state: "01:25:00", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.bambu_finish_time", friendlyName: "预计完成时间", state: "2026-09-05T18:30:00+08:00", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.bambu_error_code", friendlyName: "错误码", state: "none", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.other_temp", friendlyName: "无关实体", state: "1", unitOfMeasurement: nil)
    ]
    let detected = BambuLabCardSettings.autoDetect(entities: bambuEntities)
    checkEqual(detected.statusEntityID, "sensor.bambu_printer_status", "Bambu 自动识别-状态")
    checkEqual(detected.progressEntityID, "sensor.bambu_print_progress", "Bambu 自动识别-进度")
    checkEqual(detected.taskEntityID, "sensor.bambu_current_task", "Bambu 自动识别-任务")
    checkEqual(detected.nozzleTempEntityID, "sensor.bambu_nozzle_temp", "Bambu 自动识别-喷嘴温度")
    checkEqual(detected.bedTempEntityID, "sensor.bambu_bed_temp", "Bambu 自动识别-热床温度")
    checkEqual(detected.remainingEntityID, "sensor.bambu_remaining_time", "Bambu 自动识别-剩余时间")
    checkEqual(detected.endTimeEntityID, "sensor.bambu_finish_time", "Bambu 自动识别-结束时间")
    checkEqual(detected.errorEntityID, "sensor.bambu_error_code", "Bambu 自动识别-错误码")
    checkEqual(BambuLabCardSettings.autoDetect(entities: [HAEntity(entityId: "sensor.other", friendlyName: "x", state: "1", unitOfMeasurement: nil)]).statusEntityID,
               "", "Bambu 无打印机实体时字段为空")

    // Bambu 卡片设置写入/读取设备快照（按 HA 设备独立）
    var bsnap = DeviceSettings()
    var bc = BambuLabCardSettings()
    bc.statusEntityID = "sensor.bambu_printer_status"
    bc.enableAlert = false
    bc.apply(to: &bsnap)
    checkEqual(bsnap.bambuStatusEntityID, "sensor.bambu_printer_status", "Bambu 快照写入状态")
    checkEqual(bsnap.bambuEnableAlert, false, "Bambu 快照写入告警开关")
    let bcBack = BambuLabCardSettings.from(bsnap)
    checkEqual(bcBack.statusEntityID, "sensor.bambu_printer_status", "Bambu 快照读回状态")
    checkEqual(bcBack.enableAlert, false, "Bambu 快照读回告警开关")

    // Bambu 卡片渲染：含实体聚合展示；错误态警示不同
    let bambuSetting = BambuLabCardSettings.from(bsnap)
    let bambuCard = try ScreenRenderer.renderBambuLab(bambuSetting, entities: bambuEntities, settings: haSettings)
    checkEqual(bambuCard.image.width, 142, "Bambu 卡片宽度")
    checkEqual(bambuCard.image.height, 428, "Bambu 卡片高度")
    check(bambuCard.data.count <= ScreenRenderer.maximumFileSize, "Bambu 卡片大小")
    var bambuErr = bambuEntities
    bambuErr[0] = HAEntity(entityId: "sensor.bambu_printer_status", friendlyName: "打印机状态", state: "error", unitOfMeasurement: nil)
    bambuErr[6] = HAEntity(entityId: "sensor.bambu_error_code", friendlyName: "错误码", state: "0x03080005", unitOfMeasurement: nil)
    let bambuErrorCard = try ScreenRenderer.renderBambuLab(bambuSetting, entities: bambuErr, settings: haSettings)
    check(bambuErrorCard.data != bambuCard.data, "Bambu 错误态渲染应不同")

    // binary_sensor HMS 错误实体：off = 无错误（即使 lastChanged 新鲜也不再误报），on = 有错误
    let freshNow = Date()
    var binSetting = bambuSetting
    binSetting.errorEntityID = "binary_sensor.bambu_hms_errors"
    var offErr = bambuEntities
    offErr[0] = HAEntity(entityId: "sensor.bambu_printer_status", friendlyName: "打印机状态", state: "running", unitOfMeasurement: nil)
    offErr[6] = HAEntity(entityId: "binary_sensor.bambu_hms_errors", friendlyName: "HMS 错误", state: "off",
                         unitOfMeasurement: nil, lastChanged: freshNow)
    let cardOff = try ScreenRenderer.renderBambuLab(binSetting, entities: offErr, settings: haSettings, now: freshNow)
    var noErr = offErr
    noErr[6] = HAEntity(entityId: "binary_sensor.bambu_hms_errors", friendlyName: "HMS 错误", state: "none",
                        unitOfMeasurement: nil, lastChanged: freshNow)
    let cardNoErr = try ScreenRenderer.renderBambuLab(binSetting, entities: noErr, settings: haSettings, now: freshNow)
    check(cardOff.data == cardNoErr.data, "HMS 错误实体 off（新鲜）应与 none 一样不触发错误态")
    var onErr = offErr
    onErr[6] = HAEntity(entityId: "binary_sensor.bambu_hms_errors", friendlyName: "HMS 错误", state: "on",
                        unitOfMeasurement: nil, lastChanged: freshNow)
    let cardOn = try ScreenRenderer.renderBambuLab(binSetting, entities: onErr, settings: haSettings, now: freshNow)
    check(cardOn.data != cardOff.data, "HMS 错误实体 on 应触发错误态")
    // monitor() 同样把 off 视为正常
    let monitorOff = HomeAssistantClient.monitor(
        entities: [HAEntity(entityId: "binary_sensor.bambu_hms_errors", friendlyName: "HMS", state: "off",
                            unitOfMeasurement: nil, lastChanged: freshNow)],
        monitorEntityID: "", expectedState: "", errorEntityID: "binary_sensor.bambu_hms_errors",
        staleErrorSeconds: 600, now: freshNow)
    check(!monitorOff.isAbnormal, "monitor：HMS 错误实体 off 视为正常")
    // 设备离线/不可用状态（unavailable/unknown）不是错误码：不触发错误态
    var unavailErr = offErr
    unavailErr[6] = HAEntity(entityId: "binary_sensor.bambu_hms_errors", friendlyName: "HMS 错误", state: "unavailable",
                             unitOfMeasurement: nil, lastChanged: freshNow)
    let cardUnavail = try ScreenRenderer.renderBambuLab(binSetting, entities: unavailErr, settings: haSettings, now: freshNow)
    check(cardUnavail.data == cardNoErr.data, "HMS 错误实体 unavailable（设备离线）不应触发错误态")
    let monitorUnavail = HomeAssistantClient.monitor(
        entities: [HAEntity(entityId: "binary_sensor.bambu_hms_errors", friendlyName: "HMS", state: "unavailable",
                            unitOfMeasurement: nil, lastChanged: freshNow)],
        monitorEntityID: "", expectedState: "", errorEntityID: "binary_sensor.bambu_hms_errors",
        staleErrorSeconds: 600, now: freshNow)
    check(!monitorUnavail.isAbnormal, "monitor：unavailable 视为正常")
    // 陈旧错误码：lastChanged 超过新鲜度阈值即视为已恢复（残留旧值不误报）
    let staleErr = HAEntity(entityId: "binary_sensor.bambu_hms_errors", friendlyName: "HMS 错误", state: "07FE-4500-0002-0003",
                            unitOfMeasurement: nil, lastChanged: freshNow.addingTimeInterval(-11 * 60))
    let monitorStale = HomeAssistantClient.monitor(
        entities: [staleErr], monitorEntityID: "", expectedState: "",
        errorEntityID: "binary_sensor.bambu_hms_errors", staleErrorSeconds: 600, now: freshNow)
    check(!monitorStale.isAbnormal, "超过新鲜度的旧错误码视为已恢复")

    // 剩余时间格式化：h 单位的小数 → 分钟/小时可读文本
    let remainHoursFrac = HAEntity(entityId: "sensor.x2d_remaining_time", friendlyName: "剩余时间", state: "0.383333333333333", unitOfMeasurement: "h")
    checkEqual(remainHoursFrac.remainingDisplayText, "23 分钟", "剩余时间-小时小数转分钟")
    let remainHours = HAEntity(entityId: "sensor.x2d_remaining_time", friendlyName: "剩余时间", state: "2.5", unitOfMeasurement: "h")
    checkEqual(remainHours.remainingDisplayText, "2 小时 30 分钟", "剩余时间-小时转时分")
    let remainMin = HAEntity(entityId: "sensor.x2d_remaining_time", friendlyName: "剩余时间", state: "90", unitOfMeasurement: "min")
    checkEqual(remainMin.remainingDisplayText, "90 分钟", "剩余时间-分钟")
    let remainRaw = HAEntity(entityId: "sensor.x2d_remaining_time", friendlyName: "剩余时间", state: "01:25:00", unitOfMeasurement: nil)
    checkEqual(remainRaw.remainingDisplayText, "01:25:00", "剩余时间-非数值原样")
    let finishTimestamp = HAEntity(entityId: "sensor.x2d_finish_time", friendlyName: "预计结束时间",
                                   state: "2026-09-05T18:30:00+08:00", unitOfMeasurement: nil)
    checkEqual(finishTimestamp.displayState, "09-05 18:30", "结束时间-ISO 时间戳转本地短时间")
    checkEqual(ScreenRenderer.bambuCompactCanvasTimeText(remainHours, mode: .remaining),
               "2时30分", "灵犀多打印机摘要压缩剩余时间单位")
    checkEqual(ScreenRenderer.bambuCompactCanvasTimeText(finishTimestamp, mode: .endTime),
               "18:30", "灵犀多打印机摘要的结束时间只保留时分")
    var timeModeConfig = BambuLabCardSettings(
        name: "X2D", remainingEntityID: remainHours.entityId,
        endTimeEntityID: finishTimestamp.entityId, timeDisplayMode: .remaining)
    let remainingTimeCard = try ScreenRenderer.renderBambuLab(
        timeModeConfig, entities: [remainHours, finishTimestamp], settings: haSettings)
    timeModeConfig.timeDisplayMode = .endTime
    let finishTimeCard = try ScreenRenderer.renderBambuLab(
        timeModeConfig, entities: [remainHours, finishTimestamp], settings: haSettings)
    check(remainingTimeCard.data != finishTimeCard.data,
          "打印机卡片切换剩余时间/结束时间后应立即呈现不同内容")
    checkEqual(timeModeConfig.selectedTimeEntityID, finishTimestamp.entityId,
               "结束时间模式只读取已绑定的结束时间实体")

    // 画板模块含 BambuLab
    var bCanvas = AppSettings()
    bCanvas.canvasModules = [CanvasModule.bambuLab.rawValue]
    var bDeviceSettings = DeviceSettings()
    detected.apply(to: &bDeviceSettings)
    let bDevice = ManagedDevice(type: .bambuLab, name: "Bambu 打印机",
                                settings: bDeviceSettings)
    bCanvas.devices = [bDevice]
    bCanvas.activeBambuLabDeviceID = bDevice.id
    var bSnap = HASnapshot(entities: bambuEntities)
    let bModule = try ScreenRenderer.renderCanvas(modules: bCanvas.canvasModuleList, system: system,
                                                  nowPlaying: .sample, pomodoro: pomo,
                                                  customText: "", settings: bCanvas, ha: bSnap)
    let bModuleLegacyLayout = try ScreenRenderer.renderCanvas(
        modules: bCanvas.canvasModuleList, system: system,
        nowPlaying: .sample, pomodoro: pomo,
        customText: "", settings: bCanvas, ha: bSnap,
        bambuHeroLayout: false)
    checkEqual(bModule.image.width, 142, "Bambu 画板模块宽度")
    check(bModule.data.count <= ScreenRenderer.maximumFileSize, "Bambu 画板模块大小")
    check(bModule.data != bModuleLegacyLayout.data,
          "灵犀画板默认使用小号状态、细进度条和数据更新时间的新仪表布局")
    // 多打印机画板：bambuLab→第 1 台、bambuLab2→第 2 台（与卡片管理槽位一致）
    var multiCanvas = AppSettings()
    var p1Dev = DeviceSettings()
    p1Dev.bambuPrinterName = "P1P"
    p1Dev.bambuStatusEntityID = "sensor.p1p_status"
    p1Dev.bambuProgressEntityID = "sensor.p1p_progress"
    var p2Dev = DeviceSettings()
    p2Dev.bambuPrinterName = "X2D"
    p2Dev.bambuStatusEntityID = "sensor.x2d_status"
    p2Dev.bambuProgressEntityID = "sensor.x2d_progress"
    p2Dev.bambuTaskEntityID = "sensor.x2d_task"
    p2Dev.bambuNozzleTempEntityID = "sensor.x2d_nozzle"
    p2Dev.bambuBedTempEntityID = "sensor.x2d_bed"
    p2Dev.bambuRemainingEntityID = "sensor.x2d_remain"
    multiCanvas.devices = [ManagedDevice(type: .bambuLab, name: "P1P", settings: p1Dev),
                           ManagedDevice(type: .bambuLab, name: "X2D", settings: p2Dev)]
    multiCanvas.activeBambuLabDeviceID = multiCanvas.devices[0].id
    let multiHA = HASnapshot(entities: [
        HAEntity(entityId: "sensor.p1p_status", friendlyName: "P1P 状态", state: "idle", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.p1p_progress", friendlyName: "P1P 进度", state: "0", unitOfMeasurement: "%"),
        HAEntity(entityId: "sensor.x2d_status", friendlyName: "X2D 状态", state: "running", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.x2d_progress", friendlyName: "X2D 进度", state: "80", unitOfMeasurement: "%"),
        HAEntity(entityId: "sensor.x2d_task", friendlyName: "X2D 任务", state: "带AMS 花瓶", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.x2d_nozzle", friendlyName: "X2D 喷嘴", state: "245", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.x2d_bed", friendlyName: "X2D 热床", state: "70", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.x2d_remain", friendlyName: "X2D 剩余", state: "0.5", unitOfMeasurement: "h"),
    ])
    let slot1Card = try ScreenRenderer.renderCanvas(modules: [.bambuLab], system: system,
                                                    nowPlaying: .sample, pomodoro: pomo,
                                                    customText: "", settings: multiCanvas, ha: multiHA)
    let slot2Card = try ScreenRenderer.renderCanvas(modules: [.bambuLab2], system: system,
                                                    nowPlaying: .sample, pomodoro: pomo,
                                                    customText: "", settings: multiCanvas, ha: multiHA)
    check(slot1Card.data != slot2Card.data, "画板 bambuLab/bambuLab2 应渲染不同打印机")
    let slot2Empty = try ScreenRenderer.renderCanvas(modules: [.bambuLab3], system: system,
                                                     nowPlaying: .sample, pomodoro: pomo,
                                                     customText: "", settings: multiCanvas, ha: multiHA)
    check(slot2Empty.data != slot2Card.data, "无打印机的卡片位模块渲染应不同（占位）")
    // 画板打印机模块显示选项：默认值、按模块设置往返、行数统计、渲染差异
    let defaultFields = multiCanvas.canvasPrinterFields(for: .bambuLab)
    check(defaultFields.showStatus && defaultFields.showProgress && defaultFields.showError,
          "画板打印机默认显示状态/进度/错误")
    check(!defaultFields.showTask && !defaultFields.showNozzleTemp && !defaultFields.showBedTemp
          && !defaultFields.showRemaining, "画板打印机默认不显示任务/温度/剩余")
    checkEqual(CanvasPrinterFields.default.enabledRowCount, 3, "默认开启行数=3")
    var fullFields = defaultFields
    fullFields.showTask = true
    fullFields.showNozzleTemp = true
    fullFields.showBedTemp = true
    fullFields.showRemaining = true
    checkEqual(fullFields.enabledRowCount, 7, "全开时行数=7")
    multiCanvas.setCanvasPrinterFields(fullFields, for: .bambuLab2)
    checkEqual(multiCanvas.canvasPrinterFields(for: .bambuLab2).enabledRowCount, 7,
               "设置后按模块读回显示选项")
    checkEqual(multiCanvas.canvasPrinterFields(for: .bambuLab).enabledRowCount, 3,
               "各打印机模块显示选项互不影响")
    multiCanvas.setCanvasPrinterFields(fullFields, for: .bambuLab)
    let densePrinterCanvas = try ScreenRenderer.renderCanvas(
        modules: [.bambuLab, .bambuLab2], system: system,
        nowPlaying: .sample, pomodoro: pomo, customText: "",
        settings: multiCanvas, ha: multiHA)
    checkEqual(densePrinterCanvas.image.width, 142,
               "灵犀画板多打印机全详情摘要保持画布宽度")
    checkEqual(densePrinterCanvas.image.height, 428,
               "灵犀画板多打印机全详情摘要保持画布高度")
    check(densePrinterCanvas.data.count <= ScreenRenderer.maximumFileSize,
          "灵犀画板多打印机全详情摘要不撑爆输出")
    // 多把键盘卡片内容隔离：画板打印机显示选项与系统监控图表样式写入/恢复各自设备快照
    var kbA = DeviceSettings()
    kbA.canvasModules = [CanvasModule.bambuLab.rawValue]
    kbA.canvasPrinterFields = [CanvasModule.bambuLab.rawValue: fullFields]
    kbA.networkChart = false
    let snapA = kbA.canvasPrinterFields?[CanvasModule.bambuLab.rawValue]
    checkEqual(snapA?.enabledRowCount, 7, "键盘A快照保留自己的打印机显示选项")
    checkEqual(kbA.networkChart, false, "键盘A快照保留自己的网络图表样式")
    var kbB = DeviceSettings()
    kbB.canvasModules = [CanvasModule.bambuLab.rawValue]
    kbB.canvasPrinterFields = [:]
    kbB.networkChart = true
    checkEqual(kbB.canvasPrinterFields?[CanvasModule.bambuLab.rawValue]?.enabledRowCount ?? 0, 0,
               "键盘B未配置时不继承键盘A的显示选项")
    // capture/apply 往返：全局镜像 ↔ 活动键盘快照，保证切换键盘后各自内容恢复
    var mirrorS = AppSettings()
    mirrorS.canvasPrinterFields = [CanvasModule.bambuLab.rawValue: fullFields]
    mirrorS.networkChart = false
    let kbSnap = DeviceSettings.capture(from: mirrorS, type: .keyboard)
    checkEqual(kbSnap.canvasPrinterFields?[CanvasModule.bambuLab.rawValue]?.enabledRowCount, 7,
               "键盘快照捕获打印机显示选项")
    checkEqual(kbSnap.networkChart, false, "键盘快照捕获网络图表样式")
    var restored = AppSettings()
    restored.networkChart = true
    kbSnap.apply(to: restored, type: .keyboard)
    checkEqual(restored.canvasPrinterFields[CanvasModule.bambuLab.rawValue]?.enabledRowCount, 7,
               "切回该键盘时恢复其打印机显示选项")
    checkEqual(restored.networkChart, false, "切回该键盘时恢复其网络图表样式")
    // —— 多把灵犀68 键盘：卡片管理与每张卡片的内容完全隔离 ——
    var kb1 = AppSettings()
    kb1.displayMode = .systemMonitor
    kb1.cardTheme = .neonPurple
    kb1.showCpu = true
    kb1.showMemory = true
    kb1.showNetwork = false
    kb1.showUptime = false
    kb1.showDisk = true
    kb1.networkChart = true
    kb1.pomodoroPraiseEnabled = true
    kb1.pomodoroPraiseSource = .hitokoto
    kb1.pomodoroTaskFontSize = 13
    kb1.qwenQuotaShowPercent = false
    kb1.excerptQuoteCategories = [0, 2]
    kb1.showExcerptSource = true
    kb1.keyboardCardPanels = ["system", "pomodoro", "excerptQuote"]
    let kb1Snap = DeviceSettings.capture(from: kb1, type: .keyboard)
    var kb2 = AppSettings()
    kb2.displayMode = .canvas
    kb2.cardTheme = .minimalLight
    kb2.showCpu = false
    kb2.showMemory = false
    kb2.showNetwork = true
    kb2.showUptime = true
    kb2.showDisk = false
    kb2.networkChart = false
    kb2.pomodoroPraiseEnabled = false
    kb2.pomodoroPraiseSource = .builtin
    kb2.pomodoroTaskFontSize = 8
    kb2.qwenQuotaShowPercent = true
    kb2.excerptQuoteCategories = [1]
    kb2.showExcerptSource = false
    kb2.keyboardCardPanels = ["canvas"]
    let kb2Snap = DeviceSettings.capture(from: kb2, type: .keyboard)
    // 快照逐字段保留各自的卡片内容（不共享、不覆盖）
    checkEqual(kb1Snap.displayMode, .systemMonitor, "键盘1快照记录自己的当前卡片")
    checkEqual(kb2Snap.displayMode, .canvas, "键盘2快照记录自己的当前卡片")
    checkEqual(kb1Snap.showDisk, true, "键盘1快照记录自己的系统监控区块")
    checkEqual(kb2Snap.showDisk, false, "键盘2快照记录自己的系统监控区块")
    checkEqual(kb1Snap.pomodoroPraiseSource, .hitokoto, "键盘1快照记录自己的番茄钟夸夸来源")
    checkEqual(kb2Snap.pomodoroTaskFontSize, 8, "键盘2快照记录自己的番茄钟任务字号")
    checkEqual(kb1Snap.qwenQuotaShowPercent, false, "键盘1快照记录自己的千问额度显示方式")
    checkEqual(kb1Snap.excerptQuoteCategories, [0, 2], "键盘1快照记录自己的语录分类")
    checkEqual(kb2Snap.showExcerptSource, false, "键盘2快照记录自己的语录出处开关")
    checkEqual(kb1Snap.keyboardCardPanels, ["system", "pomodoro", "excerptQuote"], "键盘1快照记录自己的卡片列表")
    checkEqual(kb2Snap.keyboardCardPanels, ["canvas"], "键盘2快照记录自己的卡片列表")
    // 切到键盘1：镜像全部换成键盘1的卡片内容
    var shared = AppSettings()
    shared.displayMode = .pomodoro
    shared.cardTheme = .amberTerminal
    shared.showCpu = false
    shared.showMemory = false
    shared.showNetwork = false
    shared.showUptime = false
    shared.showDisk = false
    shared.networkChart = false
    shared.pomodoroPraiseEnabled = false
    shared.pomodoroTaskFontSize = 9
    shared.qwenQuotaShowPercent = true
    shared.excerptQuoteCategories = [0]
    shared.showExcerptSource = false
    shared.keyboardCardPanels = ["canvas"]
    kb1Snap.apply(to: shared, type: .keyboard)
    checkEqual(shared.displayMode, .systemMonitor, "切到键盘1恢复其当前卡片")
    checkEqual(shared.cardTheme, .neonPurple, "切到键盘1恢复其卡片主题")
    checkEqual([shared.showCpu, shared.showMemory, shared.showNetwork, shared.showUptime, shared.showDisk],
               [true, true, false, false, true], "切到键盘1恢复其系统监控区块")
    checkEqual(shared.networkChart, true, "切到键盘1恢复其网络图表样式")
    checkEqual(shared.pomodoroPraiseEnabled, true, "切到键盘1恢复其番茄钟夸夸开关")
    checkEqual(shared.pomodoroPraiseSource, .hitokoto, "切到键盘1恢复其番茄钟夸夸来源")
    checkEqual(shared.pomodoroTaskFontSize, 13, "切到键盘1恢复其番茄钟任务字号")
    checkEqual(shared.qwenQuotaShowPercent, false, "切到键盘1恢复其千问额度显示方式")
    checkEqual(shared.excerptQuoteCategories, [0, 2], "切到键盘1恢复其语录分类")
    checkEqual(shared.showExcerptSource, true, "切到键盘1恢复其语录出处开关")
    checkEqual(shared.keyboardCardPanels, ["system", "pomodoro", "excerptQuote"], "切到键盘1恢复其卡片列表")
    // 再切到键盘2：键盘1的内容不会残留（无多设备干扰）
    kb2Snap.apply(to: shared, type: .keyboard)
    checkEqual(shared.displayMode, .canvas, "切到键盘2恢复其当前卡片（不被键盘1干扰）")
    checkEqual([shared.showCpu, shared.showMemory, shared.showNetwork, shared.showUptime, shared.showDisk],
               [false, false, true, true, false], "切到键盘2恢复其系统监控区块")
    checkEqual(shared.pomodoroPraiseEnabled, false, "切到键盘2关闭其番茄钟夸夸")
    checkEqual(shared.pomodoroTaskFontSize, 8, "切到键盘2恢复其番茄钟任务字号")
    checkEqual(shared.qwenQuotaShowPercent, true, "切到键盘2恢复其千问额度显示方式")
    checkEqual(shared.excerptQuoteCategories, [1], "切到键盘2恢复其语录分类")
    checkEqual(shared.showExcerptSource, false, "切到键盘2恢复其语录出处开关")
    checkEqual(shared.keyboardCardPanels, ["canvas"], "切到键盘2恢复其卡片列表")
    // 旧档案兼容：快照缺这些字段时保留当前镜像值（不清空用户现有设置）
    var legacySnap = DeviceSettings()
    legacySnap.endpoint = "http://192.168.1.9"
    var legacyMirror = AppSettings()
    legacyMirror.displayMode = .sspai
    legacyMirror.showCpu = true
    legacyMirror.pomodoroPraiseEnabled = true
    legacySnap.apply(to: legacyMirror, type: .keyboard)
    checkEqual(legacyMirror.displayMode, .sspai, "旧键盘快照缺当前卡片字段时保留现值")
    checkEqual(legacyMirror.showCpu, true, "旧键盘快照缺系统监控字段时保留现值")
    checkEqual(legacyMirror.pomodoroPraiseEnabled, true, "旧键盘快照缺番茄钟字段时保留现值")
    // 先知/摘录画板的打印机模块显示选项使用各自镜像字段，且不影响键盘画板配置
    var canvasOwner = AppSettings()
    canvasOwner.canvasPrinterFields = [CanvasModule.bambuLab.rawValue: defaultFields]
    canvasOwner.oracleCanvasPrinterFields = [CanvasModule.bambuLab.rawValue: fullFields]
    canvasOwner.excerptCanvasPrinterFields = [:]
    let oracleSnap = DeviceSettings.capture(from: canvasOwner, type: .oracle)
    let excerptSnap = DeviceSettings.capture(from: canvasOwner, type: .excerpt)
    checkEqual(oracleSnap.oracleCanvasPrinterFields?[CanvasModule.bambuLab.rawValue]?.enabledRowCount, 7,
               "先知设备快照记录自己的画板打印机显示选项")
    checkEqual(excerptSnap.oracleCanvasPrinterFields == nil, true, "摘录设备快照不携带先知字段")
    var ownerMirror = AppSettings()
    ownerMirror.canvasPrinterFields = [CanvasModule.bambuLab.rawValue: fullFields]
    oracleSnap.apply(to: ownerMirror, type: .oracle)
    checkEqual(ownerMirror.oracleCanvasPrinterFields[CanvasModule.bambuLab.rawValue]?.enabledRowCount, 7,
               "切到该先知设备恢复其画板打印机显示选项")
    checkEqual(ownerMirror.canvasPrinterFields[CanvasModule.bambuLab.rawValue]?.enabledRowCount, 7,
               "先知画板选项恢复不改动键盘画板选项（无跨设备串扰）")
    let oracleBefore = ownerMirror.oracleCanvasPrinterFields
    excerptSnap.apply(to: ownerMirror, type: .excerpt)
    checkEqual(ownerMirror.oracleCanvasPrinterFields.count, oracleBefore.count,
               "切换摘录设备不改动先知画板字段（各画板独立镜像）")
    // 全局镜像未持久化过先知字段时（旧档案）：套用到镜像应保持原值
    var oracleLegacy = AppSettings()
    oracleLegacy.oracleCanvasPrinterFields = [CanvasModule.bambuLab2.rawValue: fullFields]
    DeviceSettings().apply(to: oracleLegacy, type: .oracle)
    checkEqual(oracleLegacy.oracleCanvasPrinterFields[CanvasModule.bambuLab2.rawValue]?.enabledRowCount, 7,
               "旧先知快照缺字段时保留现值")
    // —— 端到端：两台键盘各自添加不同卡片，互不影响（走真实设备编排逻辑）——
    let kb1ID = UUID()
    let kb2ID = UUID()
    func legacyTwoKeyboardProfile() -> AppSettings {
        // 旧档案键盘：快照只有连接信息，卡片列表/卡片内容字段全为 nil
        var kb1Fields = DeviceSettings()
        kb1Fields.endpoint = "http://10.0.0.11/image/upload"
        var kb1 = ManagedDevice(type: .keyboard, name: "键盘一号", settings: kb1Fields)
        kb1.id = kb1ID
        var kb2Fields = DeviceSettings()
        kb2Fields.endpoint = "http://10.0.0.12/image/upload"
        var kb2 = ManagedDevice(type: .keyboard, name: "键盘二号", settings: kb2Fields)
        kb2.id = kb2ID
        var s = AppSettings()
        s.devices = [kb1, kb2]
        s.activeKeyboardDeviceID = kb1ID
        // 全局镜像 = 上一次退出时活动键盘（一号）的状态
        s.keyboardCardPanels = ["system", "pomodoro"]
        s.displayMode = .systemMonitor
        return s
    }
    // 1) 未补齐时复现用户反馈的串扰：切到键盘二号会继承键盘一号的卡片列表与当前卡片
    let unseeded = legacyTwoKeyboardProfile()
    check(unseeded.switchActiveDevice(of: .keyboard, to: kb2ID) != nil, "未补齐档案可切换键盘")
    checkEqual(unseeded.activeDevice(for: .keyboard)?.settings.keyboardCardPanels, ["system", "pomodoro"],
               "未补齐时键盘二号快照被上一台键盘的卡片列表污染（串扰复现）")
    // 2) 补齐后：每台键盘各记各的，切换与编辑互不影响
    let twoKb = legacyTwoKeyboardProfile()
    check(twoKb.migrateKeyboardCardContentSeeds() >= 1, "旧档案键盘卡片内容已补齐")
    checkEqual(twoKb.devices.first { $0.id == kb1ID }?.settings.displayMode, .systemMonitor,
               "补齐：键盘一号记下自己的当前卡片")
    check(twoKb.switchActiveDevice(of: .keyboard, to: kb2ID) != nil, "切换到键盘二号")
    checkEqual(twoKb.devices.first { $0.id == kb1ID }?.settings.displayMode, .systemMonitor,
               "补齐后切换不再污染键盘一号快照")
    // 键盘二号：只放「少数派推荐」卡片，当前卡片也设为少数派
    twoKb.keyboardCardPanels = ["sspai"]
    twoKb.displayMode = .sspai
    twoKb.showCpu = false
    twoKb.captureActiveDeviceSnapshots()
    checkEqual(twoKb.devices.first { $0.id == kb2ID }?.settings.keyboardCardPanels, ["sspai"],
               "键盘二号记录自己的卡片列表")
    checkEqual(twoKb.devices.first { $0.id == kb1ID }?.settings.keyboardCardPanels, ["system", "pomodoro"],
               "键盘二号的改动不影响键盘一号的卡片列表")
    // 切回键盘一号：恢复它自己的卡片列表与当前卡片
    check(twoKb.switchActiveDevice(of: .keyboard, to: kb1ID) != nil, "切换回键盘一号")
    checkEqual(twoKb.keyboardCardPanels, ["system", "pomodoro"], "切回键盘一号恢复其卡片列表")
    checkEqual(twoKb.displayMode, .systemMonitor, "切回键盘一号恢复其当前卡片")
    checkEqual(twoKb.showCpu, true, "切回键盘一号恢复其系统监控区块")
    // 键盘一号：再添加摘录语录卡片并关闭内存区块
    twoKb.keyboardCardPanels = ["system", "pomodoro", "excerptQuote"]
    twoKb.showMemory = false
    twoKb.captureActiveDeviceSnapshots()
    // 切到键盘二号：仍是它自己那一张少数派卡片
    check(twoKb.switchActiveDevice(of: .keyboard, to: kb2ID) != nil, "再次切换到键盘二号")
    checkEqual(twoKb.keyboardCardPanels, ["sspai"], "键盘二号卡片列表未被键盘一号污染")
    checkEqual(twoKb.displayMode, .sspai, "键盘二号恢复自己的当前卡片")
    checkEqual(twoKb.showMemory, true, "键盘一号关闭内存区块不影响键盘二号的系统监控区块")
    // 反复切换十次：两台键盘始终保持各自状态（无累积串扰）
    for i in 0..<10 {
        let target = i % 2 == 0 ? kb2ID : kb1ID
        let expectCards = i % 2 == 0 ? ["sspai"] : ["system", "pomodoro", "excerptQuote"]
        let expectMode: DisplayMode = i % 2 == 0 ? .sspai : .systemMonitor
        _ = twoKb.switchActiveDevice(of: .keyboard, to: target)
        checkEqual(twoKb.keyboardCardPanels, expectCards, "第\(i + 1)次切换后卡片列表仍独立")
        checkEqual(twoKb.displayMode, expectMode, "第\(i + 1)次切换后当前卡片仍独立")
    }
    // 持久化往返：两台键盘各自的卡片列表与内容写入文件后读回仍独立
    let twoKbSaved = try JSONEncoder().encode(twoKb)
    let twoKbReloaded = try JSONDecoder().decode(AppSettings.self, from: twoKbSaved)
    checkEqual(twoKbReloaded.devices.first { $0.id == kb1ID }?.settings.keyboardCardPanels,
               ["system", "pomodoro", "excerptQuote"], "持久化后键盘一号卡片列表不变")
    checkEqual(twoKbReloaded.devices.first { $0.id == kb2ID }?.settings.keyboardCardPanels,
               ["sspai"], "持久化后键盘二号卡片列表不变")
    checkEqual(twoKbReloaded.devices.first { $0.id == kb1ID }?.settings.displayMode, .systemMonitor,
               "持久化后键盘一号当前卡片不变")
    checkEqual(twoKbReloaded.devices.first { $0.id == kb2ID }?.settings.displayMode, .sspai,
               "持久化后键盘二号当前卡片不变")
    checkEqual(twoKbReloaded.devices.first { $0.id == kb2ID }?.settings.endpoint,
               "http://10.0.0.12/image/upload", "持久化后键盘二号连接信息不变")
    check(twoKbReloaded.switchActiveDevice(of: .keyboard, to: kb2ID) != nil, "重载后可切换键盘")
    checkEqual(twoKbReloaded.keyboardCardPanels, ["sspai"], "重载后键盘二号卡片列表仍独立")
    checkEqual(twoKbReloaded.switchActiveDevice(of: .keyboard, to: kb2ID), nil,
               "重复切换同一台键盘不产生副作用")
    // 卡片列表解析（Core）：每台键盘只读自己的快照，Bambu 卡片位随打印机台数增减
    var cardLists = AppSettings()
    var kb1List = DeviceSettings()
    kb1List.keyboardCardPanels = ["system", "bambuLab", "bambuLab2"]
    var kb2List = DeviceSettings()
    kb2List.keyboardCardPanels = ["sspai"]
    var kb3List = DeviceSettings()   // 旧档案：未记录 → 回退默认列表
    let kb1Ref = ManagedDevice(type: .keyboard, name: "K1", settings: kb1List)
    let kb2Ref = ManagedDevice(type: .keyboard, name: "K2", settings: kb2List)
    let kb3Ref = ManagedDevice(type: .keyboard, name: "K3", settings: kb3List)
    let clipPrinterA = ManagedDevice(type: .bambuLab, name: "P1", settings: DeviceSettings())
    let clipPrinterB = ManagedDevice(type: .bambuLab, name: "P2", settings: DeviceSettings())
    cardLists.devices = [kb1Ref, kb2Ref, kb3Ref, clipPrinterA, clipPrinterB]
    cardLists.activeKeyboardDeviceID = kb1Ref.id
    let defaultCards = ["clock", "system"]
    checkEqual(cardLists.keyboardCardPanelRawValues(for: kb1Ref.id, fallback: defaultCards),
               ["system", "bambuLab", "bambuLab2"], "键盘1解析出自己的卡片列表")
    checkEqual(cardLists.keyboardCardPanelRawValues(for: kb2Ref.id, fallback: defaultCards), ["sspai"],
               "键盘2解析出自己的卡片列表（与键盘1无关）")
    checkEqual(cardLists.keyboardCardPanelRawValues(for: kb3Ref.id, fallback: defaultCards), defaultCards,
               "旧键盘档案回退默认卡片列表")
    // 只保留 1 台打印机时：第 2 张打印机卡片位隐藏，且不影响其他键盘列表
    cardLists.devices.removeAll { $0.id == clipPrinterB.id }
    checkEqual(cardLists.keyboardCardPanelRawValues(for: kb1Ref.id, fallback: defaultCards),
               ["system", "bambuLab"], "打印机删除后对应卡片位隐藏")
    checkEqual(cardLists.keyboardCardPanelRawValues(for: kb2Ref.id, fallback: defaultCards), ["sspai"],
               "打印机卡片位清理不改动其他键盘的列表")
    // 禁用打印机同样按已启用台数计算
    if let idx = cardLists.devices.firstIndex(where: { $0.id == clipPrinterA.id }) {
        cardLists.devices[idx].isEnabled = false
    }
    checkEqual(cardLists.keyboardCardPanelRawValues(for: kb1Ref.id, fallback: defaultCards), ["system"],
               "打印机禁用后其卡片位对所有键盘都隐藏")
    // 启动路径（与 AppModel.init 一致）：从 JSON 读入旧档案 → 补齐 → 写回 → 再读入，两台键盘始终各自独立
    let startupLoaded = try JSONDecoder().decode(AppSettings.self,
                                                 from: try JSONEncoder().encode(legacyTwoKeyboardProfile()))
    checkEqual(startupLoaded.devices.first { $0.id == kb2ID }?.settings.keyboardCardPanels, nil,
               "旧档案里键盘二号没有自己的卡片列表")
    startupLoaded.migrateBambuPrintersToDevices()
    startupLoaded.migrateKeyboardCardContentSeeds()
    checkEqual(startupLoaded.devices.first { $0.id == kb2ID }?.settings.keyboardCardPanels,
               ["system", "pomodoro"], "启动补齐：键盘二号记下自己的卡片列表")
    checkEqual(startupLoaded.devices.first { $0.id == kb2ID }?.settings.displayMode, .systemMonitor,
               "启动补齐：键盘二号记下自己的当前卡片")
    // 幂等：再次启动不重复改动，也不会把别的设备的值串进来
    let afterFirstSave = try JSONDecoder().decode(AppSettings.self,
                                                  from: try JSONEncoder().encode(startupLoaded))
    checkEqual(afterFirstSave.migrateKeyboardCardContentSeeds(), 0, "启动补齐幂等：第二次无需补齐")
    // 用户在键盘二号上换成自己的卡片后，键盘一号完全不受影响
    check(afterFirstSave.switchActiveDevice(of: .keyboard, to: kb2ID) != nil, "启动后切换到键盘二号")
    afterFirstSave.keyboardCardPanels = ["canvas"]
    afterFirstSave.displayMode = .canvas
    afterFirstSave.captureActiveDeviceSnapshots()
    checkEqual(afterFirstSave.devices.first { $0.id == kb1ID }?.settings.keyboardCardPanels,
               ["system", "pomodoro"], "键盘二号换卡片不影响键盘一号")
    let afterSecondSave = try JSONDecoder().decode(AppSettings.self,
                                                   from: try JSONEncoder().encode(afterFirstSave))
    check(afterSecondSave.switchActiveDevice(of: .keyboard, to: kb1ID) != nil, "重启后切换到键盘一号")
    checkEqual(afterSecondSave.keyboardCardPanels, ["system", "pomodoro"],
               "重启后键盘一号仍恢复自己的卡片列表")
    checkEqual(afterSecondSave.devices.first { $0.id == kb2ID }?.settings.keyboardCardPanels, ["canvas"],
               "重启后键盘二号仍保留自己的卡片列表")
    // 跨设备类型：旧 HA 快照残留打印机映射时，切换 HA 设备不再覆盖当前打印机映射
    var mixed = AppSettings()
    var legacyHA = DeviceSettings()
    legacyHA.haServerURL = "http://ha.local"
    legacyHA.bambuStatusEntityID = "sensor.other_printer_status"
    let haDevice = ManagedDevice(type: .homeAssistant, name: "HA", settings: legacyHA)
    var printerFields = DeviceSettings()
    printerFields.bambuPrinterName = "X2D"
    printerFields.bambuStatusEntityID = "sensor.x2d_status"
    let printerDevice = ManagedDevice(type: .bambuLab, name: "X2D", settings: printerFields)
    mixed.devices = [haDevice, printerDevice]
    mixed.activeHomeAssistantDeviceID = haDevice.id
    mixed.activeBambuLabDeviceID = printerDevice.id
    mixed.bambuStatusEntityID = "sensor.x2d_status"
    mixed.captureActiveDeviceSnapshots()
    checkEqual(mixed.devices.first { $0.id == printerDevice.id }?.settings.bambuStatusEntityID,
               "sensor.x2d_status", "同步不再用全局镜像覆盖打印机快照之外的设备")
    let otherHA = ManagedDevice(type: .homeAssistant, name: "HA2", settings: legacyHA)
    mixed.devices.append(otherHA)
    mixed.activeHomeAssistantDeviceID = otherHA.id
    mixed.captureActiveDeviceSnapshots()
    checkEqual(mixed.bambuStatusEntityID, "sensor.x2d_status", "切换 HA 设备不改写打印机映射镜像")
    checkEqual(mixed.devices.first { $0.id == printerDevice.id }?.settings.bambuStatusEntityID,
               "sensor.x2d_status", "切换 HA 设备不改写打印机设备快照")
    let richCard = try ScreenRenderer.renderCanvas(modules: [.bambuLab2], system: system,
                                                   nowPlaying: .sample, pomodoro: pomo,
                                                   customText: "", settings: multiCanvas, ha: multiHA)
    check(richCard.data != slot2Card.data, "显示信息更多时画板模块渲染应不同")
    // 旧档案兼容：缺字段的 CanvasPrinterFields JSON 回退默认
    let legacyFields = try JSONDecoder().decode(CanvasPrinterFields.self,
                                                from: Data(#"{"showStatus":false}"#.utf8))
    checkEqual(legacyFields.showStatus, false, "画板显示选项-已给字段生效")
    checkEqual(legacyFields.showProgress, true, "画板显示选项-缺字段回退默认")
    // 状态汉化共用映射（卡片与画板模块一致）
    checkEqual(BambuStatusText.map("running"), "打印中", "状态汉化 running")
    checkEqual(BambuStatusText.map("finish"), "已完成", "状态汉化 finish")
    checkEqual(BambuStatusText.map("weird_state"), "weird_state", "状态汉化未知原样返回")
    let x2dPrintStatusTranslations = [
        "failed": "失败", "finish": "已完成", "idle": "空闲", "init": "初始化中",
        "offline": "离线", "pause": "已暂停", "prepare": "准备中", "running": "打印中",
        "slicing": "切片中", "unknown": "未知",
    ]
    for (raw, translated) in x2dPrintStatusTranslations {
        checkEqual(BambuStatusText.map(raw), translated, "X2D 打印状态翻译 \(raw)")
    }
    // X2D 在实机 Home Assistant 历史中已出现的详细阶段，译文要稳定且适合小屏。
    let observedX2DStageTranslations = [
        "auto_bed_leveling": "自动热床调平",
        "build_plate_alignment_detection": "打印板对齐检测",
        "calibrate_nozzle_offset": "喷嘴偏移校准",
        "calibrating_extrusion": "挤出校准",
        "changing_filament": "换料中",
        "cleaning_nozzle_tip": "清洁喷嘴",
        "cooling_chamber": "腔室冷却中",
        "heatbed_surface_foreign_object_detection": "热床表面异物检测",
        "homing_toolhead": "工具头归位",
        "identifying_build_plate_type": "识别打印板",
        "print_calibration_lines": "打印校准线",
        "sweeping_xy_mech_mode": "扫描 XY 轴机械模态",
        "waiting_for_heatbed_temperature": "等待热床升温",
    ]
    for (raw, translated) in observedX2DStageTranslations {
        checkEqual(BambuStatusText.map(raw), translated, "X2D 实际阶段翻译 \(raw)")
    }
    // ha-bambulab 当前为 X2D/P1P/A1 mini 等设备声明的 80 个 current_stage。
    // 全部必须命中词库；日后集成增加新值时仍会原样显示，便于发现。
    let allX2DStages = """
    filament_loading scanning_bed_surface measuring_surface waiting_for_heatbed_temperature
    moving_toolhead_to_center_of_heatbed homing_toolhead changing_filament auto_bed_leveling unknown
    paused_front_cover_falling bed_level_high_temperature calibrating_motor_noise heated_bedcooling
    calibrating_micro_lidar calibrating_blade_holder_position homing_blade_holder
    calibrating_detection_nozzle_clumping printing heating_hotend cooling_nozzle inspecting_first_layer
    calibrate_nozzle_offset paused_filament_runout build_plate_alignment_detection bed_level_phase_2
    cooling_chamber paused_nozzle_filament_covered_detected calibrating_cutter_model_offset active_arc_fitting
    check_plaform paused_low_fan_speed_heat_break check_birdeye_camera_position
    heatbed_underside_foreign_object_detection calibrating_extrusion
    paused_chamber_temperature_control_error thermal_preconditioning cleaning_nozzle_tip
    heatbed_surface_foreign_object_detection paused_heat_bed_temperature_malfunction paused_ams_lost
    check_material_position check_quick_release calibrate_birdeye_camera calibrating_extrusion_flow
    checking_extruder_temperature moving_toolhead_above_purge_chute filament_unloading bed_level_phase_1
    calibrating_camera_offset check_material check_absolute_accuracy_before_calibration laser_calibration
    heating_chamber calibrating_live_view_camera waiting_chamber_temperature_equalize measuring_rotary_attachment
    motor_noise_showoff paused_nozzle_clog paused_skipped_step print_calibration_lines paused_first_layer_error
    absolute_accuracy_calibration pre_extrusion_before_printing paused_nozzle_temperature_malfunction
    identifying_build_plate_type hotend_type_detection purifying_chamber_air paused_user paused_cutter_error
    preparing_ams check_absolute_accuracy_after_calibration preparing_hotend hotend_pick_place_test
    paused_user_gcode idle heatbed_preheating m400_pause sweeping_xy_mech_mode check_door_and_cover offline
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    checkEqual(allX2DStages.count, 80, "X2D current_stage 声明数量")
    for raw in allX2DStages {
        check(BambuStatusText.map(raw) != raw, "X2D current_stage 已翻译 \(raw)")
    }
    let shortStatusLayout = ScreenRenderer.bambuStatusTextLayout(
        "打印中", maxWidth: 92, maxHeight: 30, preferredSize: 20)
    checkEqual(shortStatusLayout.lines, ["打印中"], "短打印状态保持大字单行")
    let detailedStatusText = BambuStatusText.map("moving_toolhead_to_center_of_heatbed")
    let detailedStatusLayout = ScreenRenderer.bambuStatusTextLayout(
        detailedStatusText, maxWidth: 70, maxHeight: 42, preferredSize: 20)
    checkEqual(detailedStatusLayout.lines.count, 2, "详细打印阶段自动换成两行")
    checkEqual(detailedStatusLayout.lines.joined(), detailedStatusText,
               "详细打印阶段换行后保留完整语义")
    check(detailedStatusLayout.size >= 8.5 && detailedStatusLayout.size <= 20,
          "详细打印阶段按区域自适应字号")
    let movingStatusBadge = ScreenRenderer.bambuCompactStatusPresentation(
        rawState: "moving_toolhead_to_center_of_heatbed")
    checkEqual(movingStatusBadge.symbol, "arrow.up.and.down.and.arrow.left.and.right",
               "独立打印机长移动状态改用移动图标")
    checkEqual(movingStatusBadge.label, "移动中",
               "独立打印机长移动状态使用短标签")
    let detectionStatusBadge = ScreenRenderer.bambuCompactStatusPresentation(
        rawState: "heatbed_surface_foreign_object_detection")
    checkEqual(detectionStatusBadge.label, "检测中",
               "热床检测状态优先归类为检测而非温控")
    let pausedStatusBadge = ScreenRenderer.bambuCompactStatusPresentation(
        rawState: "paused_chamber_temperature_control_error")
    checkEqual(pausedStatusBadge.symbol, "exclamationmark.triangle.fill",
               "包含异常原因的暂停状态使用醒目的异常图标")
    // 完成庆祝卡：带任务名与不带渲染不同；超长任务名不撑爆
    let doneNoTask = try ScreenRenderer.renderPrintSuccess(printerName: "X2D", settings: bCanvas)
    let doneWithTask = try ScreenRenderer.renderPrintSuccess(printerName: "X2D",
                                                             taskName: "20个6.35mm批头", settings: bCanvas)
    check(doneNoTask.data != doneWithTask.data, "完成卡-有任务名时渲染不同")
    let doneLongTask = try ScreenRenderer.renderPrintSuccess(
        printerName: "X2D", taskName: String(repeating: "长", count: 40), settings: bCanvas)
    check(doneLongTask.data.count <= ScreenRenderer.maximumFileSize, "完成卡-超长任务名不撑爆")
    // 先知/摘录画板也支持打印机模块（带 HA 数据渲染，尺寸正确）
    let oraModule = ScreenRenderer.renderDeviceCanvas(modules: [.bambuLab], system: system,
                                                      nowPlaying: .placeholder, pomodoro: pomo,
                                                      customText: "", settings: bCanvas, ha: bSnap,
                                                      width: ScreenRenderer.oracleCanvasSize,
                                                      height: ScreenRenderer.oracleCanvasSize,
                                                      palette: ScreenThemes.einkMono,
                                                      optimizeBambuForOracleEInk: true,
                                                      bambuHeroLayout: true,
                                                      showBambuCamera: false)
    checkEqual(oraModule.width, ScreenRenderer.oracleCanvasSize, "先知画板 Bambu 模块宽度")
    let oraLegacyLayout = ScreenRenderer.renderDeviceCanvas(
        modules: [.bambuLab], system: system, nowPlaying: .placeholder, pomodoro: pomo,
        customText: "", settings: bCanvas, ha: bSnap,
        width: ScreenRenderer.oracleCanvasSize, height: ScreenRenderer.oracleCanvasSize,
        palette: ScreenThemes.einkMono, optimizeBambuForOracleEInk: true)
    check(!bitmapEqual(oraModule, oraLegacyLayout),
          "先知画板应采用状态背景字、前景百分比和底部更新时间的新仪表布局")
    let standardBambuType = ScreenRenderer.bambuCanvasTypography(
        sizeBase: 40, optimizeForOracleEInk: false)
    let oracleBambuType = ScreenRenderer.bambuCanvasTypography(
        sizeBase: 40, optimizeForOracleEInk: true)
    check(oracleBambuType.label > standardBambuType.label
          && oracleBambuType.value > standardBambuType.value
          && oracleBambuType.body > standardBambuType.body,
          "先知/摘录画板 Bambu 模块应放大全部文字层级")
    let compactKeyboardBambuType = ScreenRenderer.bambuCanvasTypography(
        sizeBase: 10, optimizeForOracleEInk: false)
    check(compactKeyboardBambuType.label >= 9
          && compactKeyboardBambuType.value >= 11
          && compactKeyboardBambuType.body >= 9,
          "灵犀画板多打印机均分空间后仍保持可读字号下限")
    let shortTaskLayout = ScreenRenderer.bambuCanvasTaskLayout(
        "校准立方体", maxWidth: 150, maxHeight: 42, preferredSize: 18)
    checkEqual(shortTaskLayout.lines, ["校准立方体"], "短任务名保持清晰单行")
    let longTaskLayout = ScreenRenderer.bambuCanvasTaskLayout(
        "工作室_A1_多色支架_最终打印版本.3mf",
        maxWidth: 105, maxHeight: 46, preferredSize: 19)
    checkEqual(longTaskLayout.lines.count, 2, "长任务名在设备画板中拆为两行")
    check(longTaskLayout.size <= 19 && longTaskLayout.size >= 8.5,
          "双行任务名按可用空间自适应字号")
    check(ScreenRenderer.bambuCanvasProgressBarHeight(
            rowHeight: 40, optimizeForOracleEInk: true)
          > ScreenRenderer.bambuCanvasProgressBarHeight(
            rowHeight: 40, optimizeForOracleEInk: false),
          "先知画板 Bambu 进度条应明显加粗")
    let lightOutline = ScreenRenderer.einkDeepColorRGB(against: (1, 1, 1))
    let darkOutline = ScreenRenderer.einkDeepColorRGB(against: (0, 0, 0))
    check(lightOutline.0 == 0 && lightOutline.1 == 0 && lightOutline.2 == 0,
          "先知画板浅色模式进度条应使用纯黑描边")
    check(darkOutline.0 == 1 && darkOutline.1 == 1 && darkOutline.2 == 1,
          "先知画板深色模式进度条应反色为纯白描边")
    let excerptModule = ScreenRenderer.renderDeviceCanvas(modules: [.bambuLab], system: system,
                                                          nowPlaying: .placeholder, pomodoro: pomo,
                                                          customText: "", settings: bCanvas, ha: bSnap,
                                                          width: ScreenRenderer.excerptCanvasWidth,
                                                          height: ScreenRenderer.excerptCanvasHeight,
                                                          palette: ScreenThemes.einkMono,
                                                          optimizeBambuForOracleEInk: true,
                                                          bambuHeroLayout: true,
                                                          showBambuCamera: false)
    checkEqual(excerptModule.width, ScreenRenderer.excerptCanvasWidth, "摘录画板 Bambu 模块宽度")
    let excerptLegacyLayout = ScreenRenderer.renderDeviceCanvas(
        modules: [.bambuLab], system: system, nowPlaying: .placeholder, pomodoro: pomo,
        customText: "", settings: bCanvas, ha: bSnap,
        width: ScreenRenderer.excerptCanvasWidth, height: ScreenRenderer.excerptCanvasHeight,
        palette: ScreenThemes.einkMono)
    check(!bitmapEqual(excerptModule, excerptLegacyLayout),
          "摘录画板应采用状态背景字、前景百分比和底部更新时间的新仪表布局")
    print("  Bambu Lab 通过")

    // 实体图标映射：mdi 名优先，其次 domain 默认，最后回退通用；
    // 开关/灯光类优先按域（switch/input_boolean → 开关样式，light → 灯泡样式，即使带 mdi 图标）
    checkEqual(SFIconMapper.symbol(icon: "thermometer", domain: "sensor"), "thermometer.medium",
               "图标映射 mdi thermometer")
    checkEqual(SFIconMapper.symbol(icon: "lightbulb", domain: "switch"), "switch.2",
               "switch 域优先开关图标（mdi 不覆盖）")
    checkEqual(SFIconMapper.symbol(icon: "power", domain: "switch"), "switch.2",
               "switch 域带 mdi power 仍为开关图标")
    checkEqual(SFIconMapper.symbol(icon: nil, domain: "switch"), "switch.2", "switch 域默认开关图标")
    checkEqual(SFIconMapper.symbol(icon: nil, domain: "input_boolean"), "switch.2",
               "input_boolean 域默认开关图标")
    checkEqual(SFIconMapper.symbol(icon: "power", domain: "input_boolean"), "switch.2",
               "input_boolean 域带 mdi 仍为开关图标")
    checkEqual(SFIconMapper.symbol(icon: "lamp", domain: "light"), "lightbulb",
               "light 域优先灯泡图标（mdi 不覆盖）")
    checkEqual(SFIconMapper.symbol(icon: nil, domain: "light"), "lightbulb", "domain 默认 light 图标")
    checkEqual(SFIconMapper.symbol(icon: nil, domain: "climate"), "thermostat", "domain 默认 climate 图标")
    checkEqual(SFIconMapper.symbol(icon: nil, domain: "binary_sensor"), "switch.2", "domain 默认 binary_sensor 图标")
    checkEqual(SFIconMapper.symbol(icon: nil, domain: "media_player"), "play.tv", "domain 默认 media_player 图标")
    checkEqual(SFIconMapper.symbol(icon: nil, domain: "nothing_here"), "questionmark.circle",
               "未知域回退通用图标")
    let iconEntity = HAEntity(entityId: "sensor.kitchen_temp", friendlyName: "厨房温度", state: "26",
                              unitOfMeasurement: "°C", icon: "thermometer")
    checkEqual(SFIconMapper.symbol(for: iconEntity), "thermometer.medium", "实体图标取 mdi 名")
    let noIconEntity = HAEntity(entityId: "light.bedroom", friendlyName: "卧室灯", state: "on",
                                unitOfMeasurement: nil)
    checkEqual(SFIconMapper.symbol(for: noIconEntity), "lightbulb", "无 mdi 图标按 domain 默认")
    let switchEntity = HAEntity(entityId: "switch.plug", friendlyName: "客厅插座", state: "on",
                                unitOfMeasurement: nil, icon: "power-socket")
    checkEqual(SFIconMapper.symbol(for: switchEntity), "switch.2", "switch 域实体渲染开关图标")
    let boolEntity = HAEntity(entityId: "input_boolean.night", friendlyName: "夜间模式", state: "off",
                              unitOfMeasurement: nil)
    checkEqual(SFIconMapper.symbol(for: boolEntity), "switch.2", "input_boolean 域实体渲染开关图标")

    // parseStates 解析 attributes.icon（mdi: 前缀提取 / 无前缀原样 / 空为 nil）
    let iconJSON = """
    [
      {"entity_id": "sensor.t1", "state": "1",
       "attributes": {"friendly_name": "温度", "icon": "mdi:thermometer"}},
      {"entity_id": "light.l1", "state": "on",
       "attributes": {"friendly_name": "灯", "icon": "custom-icon"}},
      {"entity_id": "switch.s1", "state": "off", "attributes": {}}
    ]
    """
    let iconEntities = try HomeAssistantClient.parseStates(data: Data(iconJSON.utf8))
    checkEqual(iconEntities[0].icon, "thermometer", "mdi: 前缀图标提取")
    checkEqual(iconEntities[1].icon, "custom-icon", "无 mdi: 前缀图标原样保留")
    check(iconEntities[2].icon == nil, "无图标实体 icon 为 nil")

    // 轮询触发判定：未配置不轮询 / 初始即轮询 / 间隔内不轮询 / 超间隔轮询
    let base = Date()
    checkEqual(HARefreshPolicy.isDue(now: base, serverURL: "", minutes: 5, lastRefresh: nil),
               false, "未配置服务器不轮询")
    checkEqual(HARefreshPolicy.isDue(now: base, serverURL: "http://h:8123", minutes: 5, lastRefresh: nil),
               true, "首次启动即轮询")
    checkEqual(HARefreshPolicy.isDue(now: base, serverURL: "http://h:8123", minutes: 5,
                                     lastRefresh: base.addingTimeInterval(-60)),
               false, "间隔内不轮询")
    checkEqual(HARefreshPolicy.isDue(now: base, serverURL: "http://h:8123", minutes: 5,
                                     lastRefresh: base.addingTimeInterval(-301)),
               true, "超过刷新间隔触发轮询")
    checkEqual(HARefreshPolicy.isDue(now: base, serverURL: "http://h:8123", minutes: 1,
                                     lastRefresh: base.addingTimeInterval(-90)),
               true, "1 分钟间隔下 90 秒后轮询")

    // 设备类型：HA 与键盘/先知/摘录并列；快照按设备独立记录实体配置
    check(DeviceType.allCases.contains(.homeAssistant), "HA 设备类型存在")
    checkEqual(DeviceType.homeAssistant.title, "Home Assistant", "HA 设备类型标题")
    var s1 = AppSettings()
    s1.haServerURL = "http://192.168.1.10:8123"
    s1.haToken = "token-A"
    s1.haRefreshMinutes = 3
    s1.haEntityID = "sensor.temp_a"
    let snap1 = DeviceSettings.capture(from: s1, type: .homeAssistant)
    checkEqual(snap1.haServerURL, "http://192.168.1.10:8123", "基线：HA 设备快照捕获服务器地址")
    checkEqual(snap1.haToken, "token-A", "基线：HA 设备快照捕获令牌")
    checkEqual(snap1.haRefreshMinutes, 3, "基线：HA 设备快照捕获刷新间隔")
    checkEqual(snap1.haEntityID, "sensor.temp_a", "基线：HA 设备快照捕获实体")
    var s2 = AppSettings()
    s2.haEntityID = "sensor.temp_b"
    s2.haMonitorEnabled = true
    let snap2 = DeviceSettings.capture(from: s2, type: .homeAssistant)
    checkEqual(snap2.haEntityID, "sensor.temp_b", "第二台 HA 设备独立实体")
    checkEqual(snap2.haMonitorEnabled, true, "第二台 HA 设备独立监控开关")
    var s3 = AppSettings()
    s3.haEntityID = "sensor.keep_me"
    s3.haServerURL = "http://shared.local:8123"
    s3.haToken = "shared-token"
    s3.haRefreshMinutes = 7
    snap1.apply(to: s3, type: .homeAssistant)
    checkEqual(s3.haEntityID, "sensor.temp_a", "基线：HA 设备快照套用恢复实体")
    checkEqual(s3.haServerURL, "http://192.168.1.10:8123", "基线：HA 设备快照套用恢复地址")
    checkEqual(s3.haToken, "token-A", "基线：HA 设备快照套用恢复令牌")
    checkEqual(s3.haRefreshMinutes, 3, "基线：HA 设备快照套用恢复刷新间隔")
    // 打印机实体映射只归 .bambuLab 设备记录：HA 设备不再捕获/套用同一批全局镜像字段
    // （否则切换 HA 设备会把它的旧映射写回镜像，再被同步覆盖到打印机快照 = 跨设备串扰）
    var s4 = AppSettings()
    s4.bambuEnableAlert = true
    s4.bambuStatusEntityID = "sensor.bambu_status"
    s4.bambuProgressEntityID = "sensor.bambu_progress"
    s4.bambuTaskEntityID = "sensor.bambu_task"
    s4.bambuNozzleTempEntityID = "sensor.bambu_nozzle"
    s4.bambuBedTempEntityID = "sensor.bambu_bed"
    s4.bambuRemainingEntityID = "sensor.bambu_remain"
    s4.bambuErrorEntityID = "sensor.bambu_error"
    let snap4 = DeviceSettings.capture(from: s4, type: .homeAssistant)
    checkEqual(snap4.bambuStatusEntityID, nil, "HA 快照不再捕获 Bambu 状态实体")
    checkEqual(snap4.bambuErrorEntityID, nil, "HA 快照不再捕获 Bambu 错误实体")
    checkEqual(snap4.bambuEnableAlert, nil, "HA 快照不再捕获 Bambu 告警开关")
    var s5 = AppSettings()
    s5.bambuStatusEntityID = "sensor.x2d_status"
    var staleHA = DeviceSettings()
    staleHA.bambuStatusEntityID = "sensor.other_printer_status"
    staleHA.bambuNozzleTempEntityID = "sensor.other_nozzle"
    staleHA.bambuEnableAlert = false
    staleHA.apply(to: s5, type: .homeAssistant)
    checkEqual(s5.bambuStatusEntityID, "sensor.x2d_status", "旧 HA 快照残留字段不改写打印机映射镜像")
    checkEqual(s5.bambuNozzleTempEntityID, "", "旧 HA 快照残留字段不改写喷嘴实体镜像")
    checkEqual(s5.bambuEnableAlert, true, "旧 HA 快照残留字段不改写告警开关镜像")
    // 打印机设备仍完整捕获/套用自身的实体映射
    var s4b = AppSettings()
    s4b.bambuStatusEntityID = "sensor.bambu_status"
    s4b.bambuErrorEntityID = "sensor.bambu_error"
    s4b.bambuEnableAlert = true
    s4b.bambuPrinterName = "X2D"
    let printerSnap4 = DeviceSettings.capture(from: s4b, type: .bambuLab)
    checkEqual(printerSnap4.bambuStatusEntityID, "sensor.bambu_status", "打印机设备快照捕获状态实体")
    checkEqual(printerSnap4.bambuErrorEntityID, "sensor.bambu_error", "打印机设备快照捕获错误实体")
    var s4c = AppSettings()
    printerSnap4.apply(to: s4c, type: .bambuLab)
    checkEqual(s4c.bambuStatusEntityID, "sensor.bambu_status", "打印机设备快照套用状态实体")
    checkEqual(s4c.bambuPrinterName, "X2D", "打印机设备快照套用名称")
    // 旧版多打印机列表仍随 HA 设备快照往返
    var s4d = AppSettings()
    s4d.bambuPrinters = [BambuLabCardSettings(name: "A1", statusEntityID: "sensor.a1_status")]
    let snap4d = DeviceSettings.capture(from: s4d, type: .homeAssistant)
    checkEqual(snap4d.bambuPrinters?.count, 1, "HA 快照保留旧版多打印机列表")
    var s4e = AppSettings()
    snap4d.apply(to: s4e, type: .homeAssistant)
    checkEqual(s4e.bambuPrinters.first?.name, "A1", "HA 快照套用旧版多打印机列表")
    // HA 设备不再搬运卡片实体列表与显示名称：卡片内容归键盘，显示名称全局共享
    var s6 = AppSettings()
    s6.haEntities = ["sensor.a", "light.b"]
    s6.haEntityAliases = ["sensor.a": "温度"]
    s6.haMonitorEnabled = true
    let snap6 = DeviceSettings.capture(from: s6, type: .homeAssistant)
    checkEqual(snap6.haEntities, ["sensor.a", "light.b"], "基线：HA 设备快照捕获卡片实体列表")
    checkEqual(snap6.haEntityAliases?["sensor.a"], "温度", "基线：HA 设备快照捕获实体显示名称")
    checkEqual(snap6.haMonitorEnabled, true, "HA 设备快照仍记录自己的异常监控开关")
    var s7 = AppSettings()
    s7.haEntities = ["sensor.other"]
    s7.haEntityAliases = [:]
    snap6.apply(to: s7, type: .homeAssistant)
    checkEqual(s7.haEntities, ["sensor.a", "light.b"], "基线：HA 设备快照套用恢复实体列表")
    checkEqual(s7.haEntityAliases["sensor.a"], "温度", "基线：HA 设备快照套用恢复别名")
    checkEqual(s7.haMonitorEnabled, true, "切换 HA 设备套用其异常监控配置")
    // —— Home Assistant 卡片内容按键盘隔离（实体池全局共享）——
    var cardKB1 = AppSettings()
    cardKB1.haCardEntityIDs = ["sensor.a", "light.b"]
    let kb1CardSnap = DeviceSettings.capture(from: cardKB1, type: .keyboard)
    checkEqual(kb1CardSnap.haCardEntityIDs, ["sensor.a", "light.b"], "键盘快照记录自己的 HA 卡片实体")
    var cardKB2 = AppSettings()
    cardKB2.haCardEntityIDs = ["switch.c"]
    let kb2CardSnap = DeviceSettings.capture(from: cardKB2, type: .keyboard)
    checkEqual(kb2CardSnap.haCardEntityIDs, ["switch.c"], "第二台键盘记录自己的 HA 卡片实体")
    // —— 三类画板的 HA 模块实体独立于键盘卡片，也彼此独立 ——
    let canvasEntitySettings = AppSettings()
    canvasEntitySettings.haCardEntityIDs = ["sensor.card_only"]
    canvasEntitySettings.canvasHAEntityIDs = ["sensor.keyboard_canvas"]
    canvasEntitySettings.oracleCanvasHAEntityIDs = ["light.oracle_canvas"]
    canvasEntitySettings.excerptCanvasHAEntityIDs = ["switch.excerpt_canvas"]
    let keyboardCanvasSnap = DeviceSettings.capture(from: canvasEntitySettings, type: .keyboard)
    let oracleCanvasSnap = DeviceSettings.capture(from: canvasEntitySettings, type: .oracle)
    let excerptCanvasSnap = DeviceSettings.capture(from: canvasEntitySettings, type: .excerpt)
    checkEqual(keyboardCanvasSnap.canvasHAEntityIDs, ["sensor.keyboard_canvas"],
               "灵犀画板记录自己的 HA 实体")
    checkEqual(oracleCanvasSnap.oracleCanvasHAEntityIDs, ["light.oracle_canvas"],
               "口袋先知画板记录自己的 HA 实体")
    checkEqual(excerptCanvasSnap.excerptCanvasHAEntityIDs, ["switch.excerpt_canvas"],
               "摘录画板记录自己的 HA 实体")
    let restoredCanvasEntities = AppSettings()
    keyboardCanvasSnap.apply(to: restoredCanvasEntities, type: .keyboard)
    oracleCanvasSnap.apply(to: restoredCanvasEntities, type: .oracle)
    excerptCanvasSnap.apply(to: restoredCanvasEntities, type: .excerpt)
    checkEqual(restoredCanvasEntities.haCardEntityIDs, ["sensor.card_only"],
               "HA 键盘卡片实体与灵犀画板实体分别恢复")
    checkEqual(restoredCanvasEntities.canvasHAEntityIDs, ["sensor.keyboard_canvas"],
               "灵犀画板 HA 实体套用恢复")
    checkEqual(restoredCanvasEntities.oracleCanvasHAEntityIDs, ["light.oracle_canvas"],
               "口袋先知 HA 实体套用恢复")
    checkEqual(restoredCanvasEntities.excerptCanvasHAEntityIDs, ["switch.excerpt_canvas"],
               "摘录画板 HA 实体套用恢复")
    let canvasEntitiesRoundTrip = try JSONDecoder().decode(AppSettings.self,
                                                           from: try JSONEncoder().encode(canvasEntitySettings))
    checkEqual(canvasEntitiesRoundTrip.canvasHAEntityIDs, ["sensor.keyboard_canvas"],
               "三画板 HA 实体持久化-灵犀")
    checkEqual(canvasEntitiesRoundTrip.oracleCanvasHAEntityIDs, ["light.oracle_canvas"],
               "三画板 HA 实体持久化-先知")
    checkEqual(canvasEntitiesRoundTrip.excerptCanvasHAEntityIDs, ["switch.excerpt_canvas"],
               "三画板 HA 实体持久化-摘录")
    let oldCanvasSettings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    checkEqual(oldCanvasSettings.canvasHAEntityIDs, [], "旧档案不会把卡片实体自动灌入灵犀画板")
    checkEqual(oldCanvasSettings.oracleCanvasHAEntityIDs, [], "旧档案先知画板实体默认空")
    checkEqual(oldCanvasSettings.excerptCanvasHAEntityIDs, [], "旧档案摘录画板实体默认空")

    let canvasPool = [
        HAEntity(entityId: "sensor.keyboard_canvas", friendlyName: "键盘温度", state: "23", unitOfMeasurement: "°C"),
        HAEntity(entityId: "light.oracle_canvas", friendlyName: "先知灯", state: "on", unitOfMeasurement: nil),
        HAEntity(entityId: "switch.excerpt_canvas", friendlyName: "摘录开关", state: "off", unitOfMeasurement: nil),
    ]
    let sharedPoolSnapshot = HASnapshot(entities: canvasPool)
    let keyboardCanvasSelection = sharedPoolSnapshot.selecting(entityIDs: ["sensor.keyboard_canvas"])
    let oracleCanvasSelection = sharedPoolSnapshot.selecting(entityIDs: ["light.oracle_canvas"])
    let excerptCanvasSelection = sharedPoolSnapshot.selecting(entityIDs: ["switch.excerpt_canvas"])
    checkEqual(keyboardCanvasSelection.selectedEntities.map(\.entityId), ["sensor.keyboard_canvas"],
               "同一 HA 实体池按灵犀画板列表过滤")
    checkEqual(oracleCanvasSelection.selectedEntities.map(\.entityId), ["light.oracle_canvas"],
               "同一 HA 实体池按先知画板列表过滤")
    checkEqual(excerptCanvasSelection.selectedEntities.map(\.entityId), ["switch.excerpt_canvas"],
               "同一 HA 实体池按摘录画板列表过滤")
    checkEqual(sharedPoolSnapshot.selecting(entityIDs: []).selectedEntities.count, 0,
               "画板未选择实体时不会自动显示全部实体")
    let cardKb1ID = UUID()
    let cardKb2ID = UUID()
    func cardOnlyKeyboard(_ id: UUID, _ name: String, _ endpoint: String) -> ManagedDevice {
        var fields = DeviceSettings()
        fields.endpoint = endpoint
        fields.haCardEntityIDs = []
        fields.keyboardCardPanels = ["homeAssistant"]
        var device = ManagedDevice(type: .keyboard, name: name, settings: fields)
        device.id = id
        return device
    }
    var cardScoped = AppSettings()
    cardScoped.haServerURL = "http://192.168.1.9:8123"
    cardScoped.haToken = "shared-token"
    cardScoped.haEntityAliases = ["sensor.a": "客厅温度"]
    cardScoped.devices = [cardOnlyKeyboard(cardKb1ID, "键盘一", "http://10.0.0.11/image/upload"),
                          cardOnlyKeyboard(cardKb2ID, "键盘二", "http://10.0.0.12/image/upload")]
    cardScoped.activeKeyboardDeviceID = cardKb1ID
    // 键盘一：选择两个实体
    cardScoped.haCardEntityIDs = ["sensor.a", "light.b"]
    cardScoped.captureActiveDeviceSnapshots()
    checkEqual(cardScoped.devices.first { $0.id == cardKb1ID }?.settings.haCardEntityIDs,
               ["sensor.a", "light.b"], "键盘一记下自己的 HA 卡片实体")
    // 切到键盘二：从空列表开始，编辑它不影响键盘一
    check(cardScoped.switchActiveDevice(of: .keyboard, to: cardKb2ID) != nil, "切换到键盘二")
    checkEqual(cardScoped.haCardEntityIDs, [], "键盘二的 HA 卡片实体列表独立（不继承键盘一）")
    cardScoped.haCardEntityIDs = ["switch.c"]
    cardScoped.captureActiveDeviceSnapshots()
    checkEqual(cardScoped.devices.first { $0.id == cardKb1ID }?.settings.haCardEntityIDs,
               ["sensor.a", "light.b"], "键盘二换实体不影响键盘一")
    // 切回键盘一：恢复自己的列表；共享服务器与别名不变
    check(cardScoped.switchActiveDevice(of: .keyboard, to: cardKb1ID) != nil, "切回键盘一")
    checkEqual(cardScoped.haCardEntityIDs, ["sensor.a", "light.b"], "切回键盘一恢复其卡片实体列表")
    checkEqual(cardScoped.haServerURL, "http://192.168.1.9:8123", "切换键盘不改动共享服务器")
    checkEqual(cardScoped.haEntityAliases["sensor.a"], "客厅温度", "实体显示名称全局共享")
    // 反复切换五次：两台键盘的卡片实体列表始终各自独立
    for i in 0..<5 {
        let target = i % 2 == 0 ? cardKb2ID : cardKb1ID
        let expected = i % 2 == 0 ? ["switch.c"] : ["sensor.a", "light.b"]
        _ = cardScoped.switchActiveDevice(of: .keyboard, to: target)
        checkEqual(cardScoped.haCardEntityIDs, expected, "第\(i + 1)次切换后卡片实体列表仍独立")
    }
    // 持久化往返：两台键盘的卡片实体列表各自保留
    let cardScopedReloaded = try JSONDecoder().decode(AppSettings.self,
                                                      from: try JSONEncoder().encode(cardScoped))
    checkEqual(cardScopedReloaded.devices.first { $0.id == cardKb1ID }?.settings.haCardEntityIDs,
               ["sensor.a", "light.b"], "持久化后键盘一卡片实体列表不变")
    checkEqual(cardScopedReloaded.devices.first { $0.id == cardKb2ID }?.settings.haCardEntityIDs,
               ["switch.c"], "持久化后键盘二卡片实体列表不变")
    // 旧档案：只有全局实体列表 → 解码时作为镜像，再由键盘补齐为每台一份，之后互不影响
    var legacyCard = AppSettings()
    legacyCard.haEntities = ["sensor.legacy", "light.legacy"]
    let legacyReloaded = try JSONDecoder().decode(AppSettings.self,
                                                  from: try JSONEncoder().encode(legacyCard))
    checkEqual(legacyReloaded.haCardEntityIDs, ["sensor.legacy", "light.legacy"],
               "旧档案的全局实体列表在解码时收为当前卡片列表镜像")
    let legacyKb1 = UUID()
    let legacyKb2 = UUID()
    var legacyCardScoped = AppSettings()
    var legacyKB1Fields = DeviceSettings()
    legacyKB1Fields.endpoint = "http://10.0.0.21/image/upload"
    var legacyKB1 = ManagedDevice(type: .keyboard, name: "旧键盘一", settings: legacyKB1Fields)
    legacyKB1.id = legacyKb1
    var legacyKB2Fields = DeviceSettings()
    legacyKB2Fields.endpoint = "http://10.0.0.22/image/upload"
    var legacyKB2 = ManagedDevice(type: .keyboard, name: "旧键盘二", settings: legacyKB2Fields)
    legacyKB2.id = legacyKb2
    legacyCardScoped.devices = [legacyKB1, legacyKB2]
    legacyCardScoped.activeKeyboardDeviceID = legacyKb1
    legacyCardScoped.haCardEntityIDs = ["sensor.legacy", "light.legacy"]
    legacyCardScoped.migrateKeyboardCardContentSeeds()
    checkEqual(legacyCardScoped.devices.first { $0.id == legacyKb2 }?.settings.haCardEntityIDs,
               ["sensor.legacy", "light.legacy"], "旧键盘二补齐到自己的卡片实体列表")
    check(legacyCardScoped.switchActiveDevice(of: .keyboard, to: legacyKb2) != nil, "切换到旧键盘二")
    legacyCardScoped.haCardEntityIDs = ["sensor.legacy"]
    legacyCardScoped.captureActiveDeviceSnapshots()
    checkEqual(legacyCardScoped.devices.first { $0.id == legacyKb1 }?.settings.haCardEntityIDs,
               ["sensor.legacy", "light.legacy"], "旧键盘一的卡片实体列表不被键盘二改动")
    // 同一份共享实体池 + 不同选择 → 两台键盘的 HA 卡片画面不同
    let poolSensor = HAEntity(entityId: "sensor.a", friendlyName: "客厅温度",
                              state: "22.5", unitOfMeasurement: "°C")
    let poolLight = HAEntity(entityId: "light.b", friendlyName: "台灯", state: "on",
                             unitOfMeasurement: nil)
    let poolSwitch = HAEntity(entityId: "switch.c", friendlyName: "风扇", state: "off",
                              unitOfMeasurement: nil)
    let pool = [poolSensor, poolLight, poolSwitch]
    var kb1Card = AppSettings()
    var kb2Card = AppSettings()
    let kb1Selection = [poolSensor, poolLight]
    let kb2Selection = [poolSwitch]
    let kb1Render = try ScreenRenderer.renderHA(kb1Selection, errorText: nil, settings: kb1Card)
    let kb2Render = try ScreenRenderer.renderHA(kb2Selection, errorText: nil, settings: kb2Card)
    check(kb1Render.data != kb2Render.data, "两台键盘按各自选择渲染出不同的 HA 卡片")
    let kb1Again = try ScreenRenderer.renderHA(kb1Selection, errorText: nil, settings: kb1Card)
    checkEqual(kb1Again.data.count, kb1Render.data.count, "同一份选择重复渲染结果一致（数据源共享）")
    check(HAEntityPicker.printerRelevant(pool).count < pool.count,
          "打印机候选只是共享实体池的视图层子集")
    checkEqual(pool.count, 3, "候选筛选不裁剪共享实体池（数据源仍是一份）")
    // —— Home Assistant 单服务器全局共享 ——
    var legacyHAFieldsA = DeviceSettings()
    legacyHAFieldsA.haServerURL = "http://192.168.1.10:8123"
    legacyHAFieldsA.haToken = "token-A"
    legacyHAFieldsA.haRefreshMinutes = 3
    var legacyHAFieldsB = DeviceSettings()
    legacyHAFieldsB.haServerURL = "http://192.168.1.99:8123"
    legacyHAFieldsB.haToken = "token-B"
    legacyHAFieldsB.haRefreshMinutes = 9
    let haDevA = ManagedDevice(type: .homeAssistant, name: "HA-A", settings: legacyHAFieldsA)
    let haDevB = ManagedDevice(type: .homeAssistant, name: "HA-B", settings: legacyHAFieldsB)
    var collapsed = AppSettings()
    collapsed.devices = [haDevA, haDevB]
    collapsed.activeHomeAssistantDeviceID = haDevB.id
    let migrationNote = collapsed.migrateHAServerToGlobal()
    check(migrationNote != nil, "旧档案 HA 连接迁移留下日志")
    checkEqual(collapsed.haServerURL, "http://192.168.1.99:8123", "迁移后全局地址采用活动设备那份")
    checkEqual(collapsed.haToken, "token-B", "迁移后全局令牌采用活动设备那份")
    checkEqual(collapsed.haRefreshMinutes, 9, "迁移后刷新间隔采用活动设备那份")
    checkEqual(collapsed.devices.first { $0.id == haDevA.id }?.settings.haServerURL, nil,
               "非活动设备的地址副本已清除（不再各存一份令牌）")
    checkEqual(collapsed.devices.first { $0.id == haDevB.id }?.settings.haToken, nil,
               "活动设备的令牌副本也已清除")
    checkEqual(collapsed.migrateHAServerToGlobal(), nil, "重复启动不再改动（迁移幂等）")
    // 全局为空时取活动设备值
    var collapsedEmpty = AppSettings()
    collapsedEmpty.devices = [haDevA, haDevB]
    collapsedEmpty.activeHomeAssistantDeviceID = haDevA.id
    collapsedEmpty.haServerURL = ""
    check(collapsedEmpty.migrateHAServerToGlobal() != nil, "全局为空时也能迁移")
    checkEqual(collapsedEmpty.haServerURL, "http://192.168.1.10:8123", "全局为空时取活动设备地址")
    // 切换激活 HA 设备：共享连接与实体池都不变
    let serverBefore = collapsed.haServerURL
    check(collapsed.switchActiveDevice(of: .homeAssistant, to: haDevA.id) != nil, "可切换激活 HA 设备")
    checkEqual(collapsed.haServerURL, serverBefore, "切换激活设备不改动共享服务器")
    checkEqual(collapsed.haToken, "token-B", "切换激活设备不改动共享令牌")
    // 地址规范化与校验
    checkEqual(HomeAssistantClient.statesURL(server: "192.168.1.20:8123")?.absoluteString,
               "http://192.168.1.20:8123/api/states", "缺协议时自动补 http://")
    checkEqual(HomeAssistantClient.statesURL(server: "http://a.local/")?.absoluteString,
               "http://a.local/api/states", "尾部斜杠不重复拼接")
    check(HomeAssistantClient.statesURL(server: "ftp://a.local") == nil, "非 http/https 地址判为无效")
    check(HomeAssistantClient.statesURL(server: "   ") == nil, "空白地址判为无效")
    check(HomeAssistantClient.validate(serverURL: "", token: "t") != nil, "校验：缺地址给出原因")
    check(HomeAssistantClient.validate(serverURL: "http://a.local", token: "  ") != nil,
          "校验：缺令牌给出原因")
    checkEqual(HomeAssistantClient.validate(serverURL: "http://a.local", token: "t"), nil,
               "校验：参数可用时不报错")
    check(HAError.unauthorized.errorDescription?.contains("401") == true, "401 报错含状态码")
    check(HAError.forbidden.errorDescription?.contains("403") == true, "403 报错含状态码")
    check(HAError.serverError(status: 500).errorDescription?.contains("500") == true,
          "其他状态码报错含状态码")
    check(HAError.invalidURL.errorDescription?.contains("http://") == true, "地址格式错误给出示例")
    check(HAError.cannotConnect.errorDescription?.contains("Home Assistant") == true,
          "连接失败提示使用产品全称")
    // 失效绑定：快照数据 + 卡片渲染
    let liveEntity = HAEntity(entityId: "sensor.ok", friendlyName: "在线传感器",
                              state: "21.5", unitOfMeasurement: "°C")
    var staleSnapshot = HASnapshot(entities: [liveEntity], selectedEntities: [liveEntity],
                                   missingEntityIDs: ["sensor.gone"],
                                   lastKnownValues: ["sensor.gone": "12 %"])
    checkEqual(staleSnapshot.missingRows().first?.name, "sensor.gone", "失效行默认显示 entity_id")
    staleSnapshot.aliases = ["sensor.gone": "旧传感器"]
    checkEqual(staleSnapshot.missingRows().first?.name, "旧传感器", "失效行优先使用自定义显示名")
    checkEqual(staleSnapshot.missingRows().first?.lastValue, "12 %", "失效行保留最后一次已知值")
    let remembered = staleSnapshot.rememberingValues(from: [liveEntity])
    checkEqual(remembered.lastKnownValues["sensor.ok"], "21.5 °C", "记录在线实体的最后已知值")
    var haCardSettings = AppSettings()
    haCardSettings.haServerURL = "http://192.168.1.9:8123"
    let cardNoStale = try ScreenRenderer.renderHA([liveEntity], missing: [],
                                                  errorText: nil, settings: haCardSettings)
    let cardWithStale = try ScreenRenderer.renderHA([liveEntity], missing: staleSnapshot.missingRows(),
                                                    errorText: nil, settings: haCardSettings)
    check(cardNoStale.data != cardWithStale.data, "存在失效绑定时 HA 卡片渲染不同")
    let cardAllStale = try ScreenRenderer.renderHA([], missing: staleSnapshot.missingRows(),
                                                   errorText: nil, settings: haCardSettings)
    check(cardAllStale.data != cardNoStale.data, "实体全部失效时不再显示为正常在线")
    let cardDisconnected = try ScreenRenderer.renderHA([], errorText: "无法连接 Home Assistant",
                                                       settings: haCardSettings)
    check(cardDisconnected.data != cardNoStale.data, "未连接时卡片显示明确提示")
    // 打印机卡片：未映射与已绑定但无数据可区分；后两种缺数据场景统一显示“未配置”。
    // 固定渲染时间，避免两次调用跨秒后“数据更新”页脚让 JPEG 基线随机变化。
    let mappingRenderNow = Date(timeIntervalSince1970: 1_788_448_400)
    let cardUnmapped = try ScreenRenderer.renderBambuLab(BambuLabCardSettings(name: "A1"),
                                                         entities: [liveEntity],
                                                         settings: haCardSettings,
                                                         now: mappingRenderNow)
    let cardStaleMapping = try ScreenRenderer.renderBambuLab(
        BambuLabCardSettings(name: "A1", statusEntityID: "sensor.gone"),
        entities: [liveEntity], settings: haCardSettings, now: mappingRenderNow)
    let cardNoPool = try ScreenRenderer.renderBambuLab(
        BambuLabCardSettings(name: "A1", statusEntityID: "sensor.gone"),
        entities: [], settings: haCardSettings, now: mappingRenderNow)
    check(cardUnmapped.data != cardStaleMapping.data, "映射失效与未映射渲染不同")
    checkEqual(cardNoPool.data, cardStaleMapping.data,
               "基线：不区分实体池未就绪与映射失效（统一显示未配置）")
    // 两台键盘卡片内容不同，但 HA 模块读同一份服务器数据 → 模块画面一致
    var kbShareA = AppSettings()
    var kbShareB = AppSettings()
    kbShareB.showCpu = false
    let sharedCanvasA = try ScreenRenderer.renderCanvas(modules: [.homeAssistant], system: system,
                                                        nowPlaying: .sample, pomodoro: pomo,
                                                        customText: "", settings: kbShareA,
                                                        ha: staleSnapshot)
    let sharedCanvasB = try ScreenRenderer.renderCanvas(modules: [.homeAssistant], system: system,
                                                        nowPlaying: .sample, pomodoro: pomo,
                                                        customText: "", settings: kbShareB,
                                                        ha: staleSnapshot)
    check(sharedCanvasA.data == sharedCanvasB.data,
          "两台键盘的 Home Assistant 模块读同一份实体数据（含失效行）")
    // —— 图片实体（image.*）支持：打印机状态 + 画面反馈 ——
    func makeTestPictureData(width: Int = 64, height: Int = 36) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
    let pictureData = makeTestPictureData()
    // 1) attributes.entity_picture 解析
    let pictureJSON = """
    [{"entity_id":"image.bambu_a1_camera","state":"captured",
      "attributes":{"friendly_name":"A1 摄像头","entity_picture":"/api/camera_proxy_image/image.bambu_a1_camera"}},
     {"entity_id":"sensor.a1_status","state":"printing","attributes":{"friendly_name":"A1 状态"}}]
    """
    let pictureEntities = try HomeAssistantClient.parseStates(data: Data(pictureJSON.utf8))
    checkEqual(pictureEntities[0].entityPicture, "/api/camera_proxy_image/image.bambu_a1_camera",
               "parseStates 解析 entity_picture")
    check(pictureEntities[0].hasPicture, "image 实体标记为可展示画面")
    check(!pictureEntities[1].hasPicture, "非 image 实体不算画面实体")
    let cameraJSON = """
    {"entity_id":"camera.bambu_lab_a1","state":"streaming",
     "attributes":{"friendly_name":"A1 摄像头"}}
    """
    let cameraEntity = try HomeAssistantClient.parseState(data: Data(cameraJSON.utf8))
    check(cameraEntity.hasPicture, "camera 实体无需 entity_picture 也可通过代理抓静态帧")
    // 2) 画面地址解析（相对路径补服务器 + access_token；绝对地址原样；裸主机补 http://）
    checkEqual(HomeAssistantClient.imageURL(server: "http://192.168.1.9:8123",
                                            picture: "/api/x.png", token: "tk")?.absoluteString,
               "http://192.168.1.9:8123/api/x.png?access_token=tk",
               "相对画面地址补全服务器与令牌")
    checkEqual(HomeAssistantClient.imageURL(server: "http://192.168.1.9:8123/",
                                            picture: "api/x.png", token: "")?.absoluteString,
               "http://192.168.1.9:8123/api/x.png", "无令牌时不加查询参数")
    checkEqual(HomeAssistantClient.imageURL(server: "", picture: "https://cdn/x.png")?.absoluteString,
               "https://cdn/x.png", "绝对画面地址直接使用")
    checkEqual(HomeAssistantClient.imageURL(server: "192.168.1.9:8123",
                                            picture: "/api/x.png")?.absoluteString,
               "http://192.168.1.9:8123/api/x.png", "裸主机地址自动补 http://")
    checkEqual(HomeAssistantClient.imageURL(server: "http://a", picture: "  "), nil, "空画面地址返回 nil")
    checkEqual(HomeAssistantClient.imageURL(server: "http://192.168.1.9:8123",
                                            entity: cameraEntity)?.absoluteString,
               "http://192.168.1.9:8123/api/camera_proxy/camera.bambu_lab_a1",
               "camera 实体无 entity_picture 时回退 camera_proxy 单帧接口")
    // 3) image 域进入打印机候选域与中文分类
    check(HAEntityPicker.printerDomains.contains("image"), "image 域纳入打印机候选域")
    check(HAEntityPicker.printerDomains.contains("camera"), "camera 域纳入打印机候选域")
    checkEqual(HAEntityPicker.chineseDomain("image"), "图片", "image 域中文名")
    check(HAEntityPicker.printerRelevant(pictureEntities).count == 2,
          "打印机候选集包含画面实体")
    // 4) 自动匹配的画面绑定
    let a1Status = HAEntity(entityId: "sensor.bambu_lab_a1_status", friendlyName: "A1 状态",
                            state: "printing", unitOfMeasurement: nil)
    let camA1 = HAEntity(entityId: "image.bambu_lab_a1_camera", friendlyName: "A1 摄像头",
                         state: "ok", unitOfMeasurement: nil, entityPicture: "/api/a1cam")
    let coverA1 = HAEntity(entityId: "image.bambu_lab_a1_cover_image", friendlyName: "A1 封面",
                           state: "ok", unitOfMeasurement: nil, entityPicture: "/api/a1cover")
    let camP1S = HAEntity(entityId: "image.bambu_lab_p1s_camera", friendlyName: "P1S 摄像头",
                          state: "ok", unitOfMeasurement: nil, entityPicture: "/api/p1scam")
    let bound = BambuEntityMatcher.detect(from: a1Status,
                                          allEntities: [a1Status, coverA1, camA1, camP1S])
    checkEqual(bound.imageEntityID, "image.bambu_lab_a1_camera",
               "摄像头绑定本机实体（不会错绑到别的打印机）")
    checkEqual(bound.taskImageEntityID, "image.bambu_lab_a1_cover_image",
               "自动匹配同时保存本机打印任务封面")
    let taskNamedCover = HAEntity(entityId: "image.bambu_lab_a1_current_task_cover",
                                  friendlyName: "A1 当前任务封面", state: "ready",
                                  unitOfMeasurement: nil, entityPicture: "/api/task-cover")
    let taskNamedCoverBound = BambuEntityMatcher.detect(
        from: a1Status, allEntities: [a1Status, taskNamedCover])
    checkEqual(taskNamedCoverBound.taskEntityID, "",
               "任务封面图片不能误绑定到当前任务文本实体")
    checkEqual(taskNamedCoverBound.taskImageEntityID, taskNamedCover.entityId,
               "带 current_task 命名的 image.* 正确归入任务封面")
    let coverOnly = BambuEntityMatcher.detect(from: a1Status, allEntities: [a1Status, coverA1])
    checkEqual(coverOnly.imageEntityID, "", "没有摄像头时不把任务封面误填入摄像头字段")
    checkEqual(coverOnly.taskImageEntityID, "image.bambu_lab_a1_cover_image", "单独匹配模型封面")
    let singleFallback = BambuEntityMatcher.detect(
        from: a1Status,
        allEntities: [a1Status, HAEntity(entityId: "image.other_thing", friendlyName: "其他",
                                         state: "ok", unitOfMeasurement: nil, entityPicture: "/api/o")])
    checkEqual(singleFallback.taskImageEntityID, "image.other_thing",
               "池内只有一张普通 image 时兜底绑定为任务图片")
    let cameraBound = BambuEntityMatcher.detect(from: a1Status,
                                                 allEntities: [a1Status, cameraEntity])
    checkEqual(cameraBound.imageEntityID, "camera.bambu_lab_a1",
               "自动匹配支持 camera 域静态帧源")
    checkEqual(BambuEntityMatcher.pictureCandidates(
        [camA1, coverA1, cameraEntity], source: .camera).map(\.entityId),
        ["camera.bambu_lab_a1", "image.bambu_lab_a1_camera"],
        "摄像头选择器只列 camera.* 与带摄像头特征的 image.*")
    checkEqual(BambuEntityMatcher.pictureCandidates(
        [camA1, coverA1, cameraEntity], source: .taskCover).map(\.entityId),
        ["image.bambu_lab_a1_cover_image"],
        "任务封面选择器不再混入摄像头实体")
    let delayedImage = HAEntity(entityId: "image.renamed_cover", friendlyName: "自定义封面",
                                state: "unknown", unitOfMeasurement: nil)
    check(BambuEntityMatcher.pictureCandidates(
        [delayedImage], source: .taskCover).isEmpty,
        "自动匹配继续排除当前不可抓取的 image 实体")
    checkEqual(BambuEntityMatcher.pictureCandidates(
        [delayedImage], source: .taskCover, requireAvailablePicture: false).map(\.entityId),
        [delayedImage.entityId],
        "手动选择仍显示暂时没有 entity_picture 的 image 实体")
    // 跨域实体以去掉字段后缀后的设备根名称精确关联；即使根名称只有数字也可以匹配。
    let numericStatus = HAEntity(entityId: "sensor.2_print_status", friendlyName: "自定义打印机",
                                 state: "printing", unitOfMeasurement: nil)
    let numericCamera = HAEntity(entityId: "camera.2_camera", friendlyName: "任意名称",
                                 state: "streaming", unitOfMeasurement: nil)
    let numericCover = HAEntity(entityId: "image.2_cover_image", friendlyName: "任意图片",
                                state: "ready", unitOfMeasurement: nil,
                                entityPicture: "/api/cover2")
    let numericBound = BambuEntityMatcher.detect(
        from: numericStatus, allEntities: [numericStatus, numericCamera, numericCover])
    checkEqual(numericBound.imageEntityID, numericCamera.entityId,
               "数字设备根名称可跨 sensor/camera 域精确关联摄像头")
    checkEqual(numericBound.taskImageEntityID, numericCover.entityId,
               "数字设备根名称可跨 sensor/image 域精确关联任务封面")
    // ID 不同但显示名称/型号一致时可辅助关联；若多个候选得分完全相同则保持未绑定，避免错配。
    let renamedPictureStatus = HAEntity(entityId: "sensor.custom_print_status",
                                        friendlyName: "工作室 X2D", state: "printing",
                                        unitOfMeasurement: nil)
    let renamedPictureCamera = HAEntity(entityId: "image.9_camera",
                                        friendlyName: "工作室 X2D 摄像头", state: "ready",
                                        unitOfMeasurement: nil, entityPicture: "/api/cam9")
    let renamedPictureBound = BambuEntityMatcher.detect(
        from: renamedPictureStatus,
        allEntities: [renamedPictureStatus, renamedPictureCamera])
    checkEqual(renamedPictureBound.imageEntityID, renamedPictureCamera.entityId,
               "摄像头 entity_id 改名后可用打印机显示名称/型号辅助关联")
    let ambiguousCameraA = HAEntity(entityId: "image.8_camera", friendlyName: "X2D 摄像头 A",
                                    state: "ready", unitOfMeasurement: nil,
                                    entityPicture: "/api/cam8")
    let ambiguousCameraB = HAEntity(entityId: "image.9_camera", friendlyName: "X2D 摄像头 B",
                                    state: "ready", unitOfMeasurement: nil,
                                    entityPicture: "/api/cam9")
    let ambiguousPictures = BambuEntityMatcher.detect(
        from: renamedPictureStatus,
        allEntities: [renamedPictureStatus, ambiguousCameraA, ambiguousCameraB])
    checkEqual(ambiguousPictures.imageEntityID, "",
               "多个摄像头关联证据相同时保持未绑定，避免自动错配")
    let noneMatch = BambuEntityMatcher.detect(from: a1Status, allEntities: [a1Status])
    checkEqual(noneMatch.imageEntityID, "", "无画面实体时不绑")
    checkEqual(noneMatch.taskImageEntityID, "", "无任务封面实体时不绑")
    // 画面实体按设备编号命名（image.2_camera）时，靠显示名称里的型号词匹配
    let p1pStatus = HAEntity(entityId: "sensor.bambu_lab_p1p_status", friendlyName: "P1P 状态",
                             state: "printing", unitOfMeasurement: nil)
    let p1pCam = HAEntity(entityId: "image.2_camera", friendlyName: "Bambu Lab P1P Camera",
                          state: "ok", unitOfMeasurement: nil, entityPicture: "/api/2cam")
    let otherCam = HAEntity(entityId: "image.7_camera", friendlyName: "客厅小爱摄像头",
                            state: "ok", unitOfMeasurement: nil, entityPicture: "/api/7cam")
    let namedMatch = BambuEntityMatcher.detect(from: p1pStatus,
                                               allEntities: [p1pStatus, otherCam, p1pCam])
    checkEqual(namedMatch.imageEntityID, "image.2_camera",
               "画面实体按显示名称的型号词匹配（不误绑无关摄像头）")
    let autoDetectPictures = BambuLabCardSettings.autoDetect(
        entities: [a1Status, camA1, coverA1, camP1S])
    checkEqual(autoDetectPictures.imageEntityID, "image.bambu_lab_a1_camera",
               "关键词自动识别绑定本机摄像头")
    checkEqual(autoDetectPictures.taskImageEntityID, "image.bambu_lab_a1_cover_image",
               "关键词自动识别绑定本机任务封面")
    // 5) 旧档案兼容：缺画面字段的 JSON 回退默认
    let legacyBambuJSON = #"{"name":"A1","statusEntityID":"sensor.a1_status"}"#
    let legacyBambu = try JSONDecoder().decode(BambuLabCardSettings.self,
                                               from: Data(legacyBambuJSON.utf8))
    checkEqual(legacyBambu.imageEntityID, "", "旧打印机配置缺画面字段回退空")
    checkEqual(legacyBambu.taskImageEntityID, "", "旧打印机配置缺任务封面字段回退空")
    checkEqual(legacyBambu.imageSource, .camera, "旧打印机配置默认继续显示摄像头")
    checkEqual(legacyBambu.showImage, true, "旧打印机配置默认开启画面区块")
    let pictureRoundTrip = try JSONDecoder().decode(BambuLabCardSettings.self,
                                                    from: try JSONEncoder().encode(bound))
    checkEqual(pictureRoundTrip.imageEntityID, "image.bambu_lab_a1_camera", "画面映射持久化往返")
    checkEqual(pictureRoundTrip.taskImageEntityID, "image.bambu_lab_a1_cover_image",
               "任务封面映射持久化往返")
    // 6) 打印机设备快照携带画面映射与开关
    var pictureMirror = AppSettings()
    pictureMirror.bambuImageEntityID = "image.bambu_lab_a1_camera"
    pictureMirror.bambuTaskImageEntityID = "image.bambu_lab_a1_cover_image"
    pictureMirror.bambuImageSource = .taskCover
    pictureMirror.bambuEndTimeEntityID = "sensor.bambu_lab_a1_finish_time"
    pictureMirror.bambuTimeDisplayMode = .endTime
    pictureMirror.bambuAutoCameraZoom = true
    pictureMirror.bambuShowImage = false
    let pictureMirrorRoundTrip = try JSONDecoder().decode(
        AppSettings.self, from: JSONEncoder().encode(pictureMirror))
    checkEqual(pictureMirrorRoundTrip.bambuTaskImageEntityID,
               "image.bambu_lab_a1_cover_image", "全局镜像持久化任务封面实体")
    checkEqual(pictureMirrorRoundTrip.bambuImageSource, .taskCover,
               "全局镜像持久化画面来源")
    checkEqual(pictureMirrorRoundTrip.bambuAutoCameraZoom, true,
               "全局镜像持久化自动放大小模型")
    checkEqual(pictureMirrorRoundTrip.bambuEndTimeEntityID,
               "sensor.bambu_lab_a1_finish_time", "全局镜像持久化结束时间实体")
    checkEqual(pictureMirrorRoundTrip.bambuTimeDisplayMode, .endTime,
               "全局镜像持久化时间显示模式")
    let pictureSnap = DeviceSettings.capture(from: pictureMirror, type: .bambuLab)
    checkEqual(pictureSnap.bambuImageEntityID, "image.bambu_lab_a1_camera", "打印机快照捕获画面映射")
    checkEqual(pictureSnap.bambuTaskImageEntityID, "image.bambu_lab_a1_cover_image",
               "打印机快照捕获任务封面映射")
    checkEqual(pictureSnap.bambuImageSource, .taskCover, "打印机快照捕获画面来源")
    checkEqual(pictureSnap.bambuAutoCameraZoom, true, "打印机快照捕获自动放大小模型")
    checkEqual(pictureSnap.bambuEndTimeEntityID, "sensor.bambu_lab_a1_finish_time",
               "打印机快照捕获结束时间实体")
    checkEqual(pictureSnap.bambuTimeDisplayMode, .endTime, "打印机快照捕获时间显示模式")
    checkEqual(pictureSnap.bambuShowImage, false, "打印机快照捕获画面开关")
    var pictureRestored = AppSettings()
    pictureSnap.apply(to: pictureRestored, type: .bambuLab)
    checkEqual(pictureRestored.bambuImageEntityID, "image.bambu_lab_a1_camera", "切回该打印机恢复画面映射")
    checkEqual(pictureRestored.bambuTaskImageEntityID, "image.bambu_lab_a1_cover_image",
               "切回该打印机恢复任务封面映射")
    checkEqual(pictureRestored.bambuImageSource, .taskCover, "切回该打印机恢复画面来源")
    checkEqual(pictureRestored.bambuAutoCameraZoom, true, "切回该打印机恢复自动放大小模型")
    checkEqual(pictureRestored.bambuEndTimeEntityID, "sensor.bambu_lab_a1_finish_time",
               "切回该打印机恢复结束时间实体")
    checkEqual(pictureRestored.bambuTimeDisplayMode, .endTime, "切回该打印机恢复时间显示模式")
    checkEqual(pictureRestored.bambuShowImage, false, "切回该打印机恢复画面开关")
    let legacyAutoZoomSettings = try JSONDecoder().decode(AppSettings.self,
                                                          from: Data("{}".utf8))
    checkEqual(legacyAutoZoomSettings.bambuAutoCameraZoom, false,
               "旧全局配置缺自动放大字段时默认关闭")
    let legacyAutoZoomDevice = try JSONDecoder().decode(DeviceSettings.self,
                                                        from: Data("{}".utf8))
    checkEqual(legacyAutoZoomDevice.bambuAutoCameraZoom, nil,
               "旧打印机快照缺自动放大字段时由界面回退关闭")
    checkEqual(legacyAutoZoomSettings.bambuTimeDisplayMode, .remaining,
               "旧全局配置缺时间显示模式时默认剩余时间")
    checkEqual(BambuLabCardSettings.from(legacyAutoZoomDevice).timeDisplayMode, .remaining,
               "旧打印机快照缺时间显示模式时默认剩余时间")
    var sourceSelection = bound
    checkEqual(sourceSelection.selectedImageEntityID, "image.bambu_lab_a1_camera",
               "摄像头来源选择摄像头实体")
    sourceSelection.imageSource = .taskCover
    checkEqual(sourceSelection.selectedImageEntityID, "image.bambu_lab_a1_cover_image",
               "任务图片来源选择任务封面实体")
    // 7) 画板模块：画面行只在有图时占位且更高
    var fields = CanvasPrinterFields.default
    checkEqual(fields.showImage, false, "画板画面默认关闭（不改旧布局）")
    checkEqual(fields.enabledRowCount(hasPicture: false), fields.enabledRowCount,
               "无画面时行数与旧口径一致")
    fields.showImage = true
    checkEqual(fields.enabledRowCount(hasPicture: false), 3, "开启但无画面 → 画面行不占位")
    checkEqual(fields.enabledRowCount(hasPicture: true), 4, "开启且有画面 → 多占一行")
    let legacyFieldJSON = #"{"showStatus":true,"showProgress":true,"showError":true}"#
    let legacyCanvasFields = try JSONDecoder().decode(CanvasPrinterFields.self,
                                                from: Data(legacyFieldJSON.utf8))
    checkEqual(legacyCanvasFields.showImage, false, "旧画板配置缺画面字段回退关闭")
    // 8) 渲染差异：打印机卡片 / HA 卡片 / 完成庆祝卡 带画面时不同
    var pictureCardSettings = AppSettings()
    let mappedPrinter = BambuLabCardSettings(name: "A1", statusEntityID: "sensor.a1_status",
                                             imageEntityID: "image.bambu_lab_a1_camera")
    let printerEntitiesForCard = [HAEntity(entityId: "sensor.a1_status", friendlyName: "A1 状态",
                                           state: "printing", unitOfMeasurement: nil)]
    let printerNoPicture = try ScreenRenderer.renderBambuLab(mappedPrinter,
                                                             entities: printerEntitiesForCard,
                                                             settings: pictureCardSettings)
    let printerWithPicture = try ScreenRenderer.renderBambuLab(mappedPrinter,
                                                               entities: printerEntitiesForCard,
                                                               image: pictureData,
                                                               settings: pictureCardSettings)
    check(printerNoPicture.data != printerWithPicture.data, "打印机卡片画面区块生效")
    var glowTaskCoverPrinter = mappedPrinter
    glowTaskCoverPrinter.imageSource = .taskCover
    let printerTaskCover = try ScreenRenderer.renderBambuLab(glowTaskCoverPrinter,
                                                             entities: printerEntitiesForCard,
                                                             image: pictureData,
                                                             settings: pictureCardSettings)
    check(printerWithPicture.data != printerTaskCover.data,
          "摄像头实况画面应用主色光晕，任务封面不应用")
    let printerPictureHidden = try ScreenRenderer.renderBambuLab(
        BambuLabCardSettings(name: "A1", statusEntityID: "sensor.a1_status",
                             imageEntityID: "image.bambu_lab_a1_camera", showImage: false),
        entities: printerEntitiesForCard, image: pictureData, settings: pictureCardSettings)
    checkEqual(printerPictureHidden.data.count, printerNoPicture.data.count,
               "关闭画面开关后不渲染图片")
    let imageEntity = HAEntity(entityId: "image.bambu_lab_a1_camera", friendlyName: "A1 摄像头",
                               state: "captured", unitOfMeasurement: nil,
                               entityPicture: "/api/x")
    let coverEntity = HAEntity(entityId: "image.bambu_lab_a1_cover_image", friendlyName: "A1 任务封面",
                               state: "captured", unitOfMeasurement: nil,
                               entityPicture: "/api/cover")
    var boardPrinter = mappedPrinter
    boardPrinter.progressEntityID = "sensor.a1_progress"
    boardPrinter.taskImageEntityID = coverEntity.entityId
    var boardPrinterFields = DeviceSettings()
    boardPrinter.apply(to: &boardPrinterFields)
    let boardPrinterDevice = ManagedDevice(type: .bambuLab, name: "A1", settings: boardPrinterFields)
    let boardSettings = AppSettings()
    boardSettings.devices = [boardPrinterDevice]
    boardSettings.activeBambuLabDeviceID = boardPrinterDevice.id
    let boardEntities = printerEntitiesForCard + [
        HAEntity(entityId: "sensor.a1_progress", friendlyName: "A1 进度",
                 state: "60", unitOfMeasurement: "%"), imageEntity, coverEntity
    ]
    let cameraBoardSnapshot = HASnapshot(
        entities: boardEntities,
        images: [imageEntity.entityId: pictureData, coverEntity.entityId: pictureData])
    let cameraAllowedBoard = ScreenRenderer.renderDeviceCanvas(
        modules: [.bambuLab], system: system, nowPlaying: .placeholder, pomodoro: pomo,
        customText: "", settings: boardSettings, ha: cameraBoardSnapshot,
        width: ScreenRenderer.oracleCanvasSize, height: ScreenRenderer.oracleCanvasSize,
        palette: ScreenThemes.einkMono,
        printerFields: [CanvasModule.bambuLab.rawValue: fields],
        optimizeBambuForOracleEInk: true, bambuHeroLayout: true,
        showBambuCamera: true)
    let cameraSuppressedBoard = ScreenRenderer.renderDeviceCanvas(
        modules: [.bambuLab], system: system, nowPlaying: .placeholder, pomodoro: pomo,
        customText: "", settings: boardSettings, ha: cameraBoardSnapshot,
        width: ScreenRenderer.oracleCanvasSize, height: ScreenRenderer.oracleCanvasSize,
        palette: ScreenThemes.einkMono,
        printerFields: [CanvasModule.bambuLab.rawValue: fields],
        optimizeBambuForOracleEInk: true, bambuHeroLayout: true,
        showBambuCamera: false)
    check(!bitmapEqual(cameraAllowedBoard, cameraSuppressedBoard),
          "口袋先知/摘录新仪表布局应明确排除摄像头画面")
    var taskCoverPrinter = boardPrinter
    taskCoverPrinter.imageSource = .taskCover
    var taskCoverFields = DeviceSettings()
    taskCoverPrinter.apply(to: &taskCoverFields)
    let taskCoverDevice = ManagedDevice(type: .bambuLab, name: "A1", settings: taskCoverFields)
    boardSettings.devices = [taskCoverDevice]
    boardSettings.activeBambuLabDeviceID = taskCoverDevice.id
    let taskCoverBoard = ScreenRenderer.renderDeviceCanvas(
        modules: [.bambuLab], system: system, nowPlaying: .placeholder, pomodoro: pomo,
        customText: "", settings: boardSettings, ha: cameraBoardSnapshot,
        width: ScreenRenderer.oracleCanvasSize, height: ScreenRenderer.oracleCanvasSize,
        palette: ScreenThemes.einkMono,
        printerFields: [CanvasModule.bambuLab.rawValue: fields],
        optimizeBambuForOracleEInk: true, bambuHeroLayout: true,
        showBambuCamera: false)
    check(!bitmapEqual(taskCoverBoard, cameraSuppressedBoard),
          "排除摄像头后仍允许用户选择显示打印任务封面")
    let haPlain = try ScreenRenderer.renderHA([imageEntity], errorText: nil,
                                              settings: pictureCardSettings)
    let haPicture = try ScreenRenderer.renderHA([imageEntity], images: ["image.bambu_lab_a1_camera": pictureData],
                                                errorText: nil, settings: pictureCardSettings)
    check(haPlain.data != haPicture.data, "HA 卡片单实体画面模式生效")
    let haListPlain = try ScreenRenderer.renderHA([imageEntity, printerEntitiesForCard[0]],
                                                  errorText: nil, settings: pictureCardSettings)
    let haListPicture = try ScreenRenderer.renderHA([imageEntity, printerEntitiesForCard[0]],
                                                    images: ["image.bambu_lab_a1_camera": pictureData],
                                                    errorText: nil, settings: pictureCardSettings)
    check(haListPlain.data != haListPicture.data, "HA 卡片混排横向图片预览生效")
    let cameraPlain = try ScreenRenderer.renderHA([cameraEntity], errorText: nil,
                                                  settings: pictureCardSettings)
    let cameraPicture = try ScreenRenderer.renderHA(
        [cameraEntity], images: [cameraEntity.entityId: pictureData],
        errorText: nil, settings: pictureCardSettings)
    check(cameraPlain.data != cameraPicture.data,
          "HA camera 实体通过代理取得静态帧后使用大图卡片")
    let fourPictureEntities = (0..<4).map { index in
        HAEntity(entityId: "camera.room_\(index)", friendlyName: "房间摄像头 \(index + 1)",
                 state: "streaming", unitOfMeasurement: nil)
    }
    let fourPictureData = Dictionary(uniqueKeysWithValues: fourPictureEntities.map {
        ($0.entityId, pictureData)
    })
    let fourPictureCard = try ScreenRenderer.renderHA(
        fourPictureEntities, images: fourPictureData,
        errorText: nil, settings: pictureCardSettings)
    check(!fourPictureCard.data.isEmpty,
          "HA 单页四路摄像头静态预览可在等高卡片中完成渲染")
    let successPlain = try ScreenRenderer.renderPrintSuccess(printerName: "A1",
                                                             taskName: "cube.gcode",
                                                             settings: pictureCardSettings)
    let successPicture = try ScreenRenderer.renderPrintSuccess(printerName: "A1",
                                                               taskName: "cube.gcode",
                                                               picture: pictureData,
                                                               settings: pictureCardSettings)
    check(successPlain.data != successPicture.data, "打印完成庆祝卡带画面生效")
    // 9) 快照携带画面数据：所有画板/卡片共用同一份
    var pictureSnapshot = HASnapshot(entities: [imageEntity], selectedEntities: [imageEntity],
                                     images: ["image.bambu_lab_a1_camera": pictureData])
    checkEqual(pictureSnapshot.picture(for: "image.bambu_lab_a1_camera")?.count, pictureData.count,
               "快照按实体返回画面数据")
    check(pictureSnapshot.picture(for: "sensor.missing") == nil, "未缓存实体返回 nil")
    pictureSnapshot.images = [:]
    checkEqual(pictureSnapshot.images.count, 0, "不再展示的画面可被清理")
    let canvasWithPicture = try ScreenRenderer.renderCanvas(modules: [.bambuLab], system: system,
                                                            nowPlaying: .sample, pomodoro: pomo,
                                                            customText: "", settings: pictureCardSettings,
                                                            ha: pictureSnapshot,
                                                            printerFields: [CanvasModule.bambuLab.rawValue: fields])
    check(canvasWithPicture.data != printerNoPicture.data, "画板打印机模块与打印机卡片各自渲染")
    // —— 打印机卡片文件名双行（两列）显示 ——
    let fileShort = "cube.gcode"
    let fileLong = "20p6bj652500750_0000000000000000_1_94713.3mf"
    let fileNoSep = String(repeating: "a", count: 48)
    checkEqual(ScreenRenderer.fileNameLines(fileShort, size: 11, maxW: 200), [fileShort],
               "放得下的文件名保持单行")
    let wrapped = ScreenRenderer.fileNameLines(fileLong, size: 11, maxW: 124, maxLines: 2)
    checkEqual(wrapped.count, 2, "长文件名折成两行")
    let firstLineEnd = fileLong.index(fileLong.startIndex, offsetBy: wrapped[0].count)
    let nextIsSeparator = firstLineEnd < fileLong.endIndex
        && ["_", ".", "-", "/", " "].contains(fileLong[firstLineEnd])
    check(wrapped[0].hasSuffix("_") || wrapped[0].hasSuffix(".") || nextIsSeparator,
          "折行落在分隔符边界（不把词硬切两半）")
    let narrowWrapped = ScreenRenderer.fileNameLines(fileLong, size: 11, maxW: 90, maxLines: 2)
    checkEqual(narrowWrapped.count, 2, "更窄时仍保持两行")
    check(narrowWrapped[0].count < fileLong.count && !narrowWrapped[1].isEmpty,
          "极窄时也拆成两行显示（不再缩成一行小字）")
    check(wrapped.joined().hasPrefix(fileLong.prefix(wrapped[0].count)),
          "第一行是文件名前缀")
    checkEqual(ScreenRenderer.fileNameLines(fileNoSep, size: 11, maxW: 90, maxLines: 2).count, 2,
               "无分隔符的长名也按宽度硬断成两行")
    check(ScreenRenderer.fileNameLines(fileNoSep, size: 11, maxW: 90, maxLines: 2)
            .joined().hasSuffix("…"), "两行放不下时用省略号标记")
    check(ScreenRenderer.fileNameLines("", size: 11, maxW: 90).isEmpty, "空文件名不产生行")
    check(ScreenRenderer.fileNameLines(fileLong, size: 11, maxW: 90, maxLines: 1).count == 1,
               "限制单行时不超出指定行数")
    let fileTaskEntities = [
        HAEntity(entityId: "sensor.a1_status", friendlyName: "A1 状态",
                 state: "printing", unitOfMeasurement: nil),
        HAEntity(entityId: "sensor.a1_task", friendlyName: "A1 任务",
                 state: fileLong, unitOfMeasurement: nil),
    ]
    let fileLongCard = try ScreenRenderer.renderBambuLab(
        BambuLabCardSettings(name: "A1", statusEntityID: "sensor.a1_status",
                             taskEntityID: "sensor.a1_task"),
        entities: fileTaskEntities, settings: pictureCardSettings)
    let fileShortCard = try ScreenRenderer.renderBambuLab(
        BambuLabCardSettings(name: "A1", statusEntityID: "sensor.a1_status",
                             taskEntityID: "sensor.a1_task"),
        entities: [fileTaskEntities[0],
                   HAEntity(entityId: "sensor.a1_task", friendlyName: "A1 任务",
                            state: fileShort, unitOfMeasurement: nil)],
        settings: pictureCardSettings)
    check(fileLongCard.data != fileShortCard.data, "长文件名卡片与短文件名卡片渲染不同")
    let fileNoTaskCard = try ScreenRenderer.renderBambuLab(
        BambuLabCardSettings(name: "A1", statusEntityID: "sensor.a1_status",
                             taskEntityID: "sensor.a1_task", showTask: false),
        entities: fileTaskEntities, settings: pictureCardSettings)
    check(fileLongCard.data != fileNoTaskCard.data, "关闭任务行时不渲染文件名")
    // 实体两级选择器：domain 分组 / 关键字过滤 / 选中回填（数据模型仍为 entity_id 字符串）
    checkEqual(HAEntityPicker.domain(of: "sensor.temp"), "sensor", "实体域解析 sensor")
    checkEqual(HAEntityPicker.domain(of: "binary_sensor.door"), "binary_sensor", "实体域解析 binary_sensor")
    checkEqual(HAEntityPicker.domain(of: "LIGHT.Office"), "light", "实体域解析大小写归一")
    checkEqual(HAEntityPicker.domain(of: "bare"), "unknown", "无点实体域回退 unknown")
    let pickerEntities = [
        HAEntity(entityId: "sensor.living_temp", friendlyName: "客厅温度", state: "23.5", unitOfMeasurement: "°C"),
        HAEntity(entityId: "sensor.bambu_progress", friendlyName: "打印进度", state: "68", unitOfMeasurement: "%"),
        HAEntity(entityId: "binary_sensor.door", friendlyName: "大门门磁", state: "off", unitOfMeasurement: nil),
        HAEntity(entityId: "light.office", friendlyName: "办公室灯", state: "on", unitOfMeasurement: nil),
        HAEntity(entityId: "switch.plug", friendlyName: "插座", state: "on", unitOfMeasurement: nil),
    ]
    let pickerGroups = HAEntityPicker.groupByDomain(pickerEntities)
    checkEqual(pickerGroups.map(\.domain), ["binary_sensor", "light", "sensor", "switch"], "实体域分组按字母序")
    checkEqual(pickerGroups.first { $0.domain == "sensor" }?.entities.count, 2, "sensor 分类实体数量")
    checkEqual(pickerGroups.first { $0.domain == "sensor" }?.entities.first?.entityId,
               "sensor.bambu_progress", "组内按 entity_id 排序")
    checkEqual(HAEntityPicker.filter(pickerEntities, keyword: "温度").count, 1, "按名称关键字过滤")
    checkEqual(HAEntityPicker.filter(pickerEntities, keyword: "bambu").map(\.entityId),
               ["sensor.bambu_progress"], "按 entity_id 关键字过滤")
    checkEqual(HAEntityPicker.filter(pickerEntities, keyword: "  ").count, 5, "空白关键字返回全部")
    checkEqual(HAEntityPicker.filter(pickerEntities, keyword: "OFFICE").map(\.entityId),
               ["light.office"], "关键字过滤大小写不敏感")
    // 实体域中文适配：常见域有中文名，未收录域原样返回；搜索支持按中文分类过滤
    checkEqual(HAEntityPicker.chineseDomain("sensor"), "传感器", "域中文名 sensor")
    checkEqual(HAEntityPicker.chineseDomain("binary_sensor"), "二进制传感器", "域中文名 binary_sensor")
    checkEqual(HAEntityPicker.chineseDomain("light"), "灯", "域中文名 light")
    checkEqual(HAEntityPicker.chineseDomain("switch"), "开关", "域中文名 switch")
    checkEqual(HAEntityPicker.chineseDomain("input_select"), "输入选项", "域中文名 input_select")
    checkEqual(HAEntityPicker.chineseDomain("CUSTOM_INTEGRATION"), "CUSTOM_INTEGRATION",
               "未收录域原样返回")
    checkEqual(HAEntityPicker.chineseDomain(of: pickerEntities[0]), "传感器", "实体域中文名（按实体）")
    checkEqual(HAEntityPicker.filter(pickerEntities, keyword: "灯").map(\.entityId).sorted(),
               ["light.office"], "按中文分类「灯」可搜到 light 实体")
    checkEqual(HAEntityPicker.filter(pickerEntities, keyword: "开关").count, 1, "按中文分类「开关」可搜到 switch 实体")
    checkEqual(HAEntityPicker.filter(pickerEntities, keyword: "传感器").count, 3, "按中文分类「传感器」含二进制传感器")
    // 打印机实体域强制过滤：保留可映射域，排除自动化/脚本/场景/灯等无关类型
    let mixedEntities = pickerEntities + [
        HAEntity(entityId: "automation.print_done", friendlyName: "打印完成自动化", state: "on", unitOfMeasurement: nil),
        HAEntity(entityId: "script.start_print", friendlyName: "开始打印脚本", state: "on", unitOfMeasurement: nil),
        HAEntity(entityId: "scene.movie_night", friendlyName: "观影场景", state: "on", unitOfMeasurement: nil),
        HAEntity(entityId: "number.speed_profile", friendlyName: "速度档位", state: "1", unitOfMeasurement: nil),
        HAEntity(entityId: "select.filament", friendlyName: "耗材选择", state: "PLA", unitOfMeasurement: nil),
    ]
    let printerOnly = HAEntityPicker.printerRelevant(mixedEntities)
    check(!printerOnly.contains { $0.entityId.hasPrefix("automation.") }, "打印机实体集排除 automation")
    check(!printerOnly.contains { $0.entityId.hasPrefix("script.") }, "打印机实体集排除 script")
    check(!printerOnly.contains { $0.entityId.hasPrefix("scene.") }, "打印机实体集排除 scene")
    check(!printerOnly.contains { $0.entityId.hasPrefix("light.") }, "打印机实体集排除 light")
    check(printerOnly.contains { $0.entityId == "number.speed_profile" }, "打印机实体集保留 number")
    check(printerOnly.contains { $0.entityId == "select.filament" }, "打印机实体集保留 select")
    check(printerOnly.contains { $0.entityId == "sensor.bambu_progress" }, "打印机实体集保留 sensor")
    check(printerOnly.contains { $0.entityId == "binary_sensor.door" }, "打印机实体集保留 binary_sensor")
    // 自动识别与实体匹配不落在无关域上
    let detectMixed = BambuLabCardSettings.autoDetect(entities: mixedEntities)
    check(!detectMixed.statusEntityID.hasPrefix("automation."), "autoDetect 不选 automation")
    let matcherMixed = BambuEntityMatcher.detect(
        from: HAEntity(entityId: "sensor.bambu_progress", friendlyName: "进度", state: "50", unitOfMeasurement: "%"),
        allEntities: mixedEntities)
    check(!matcherMixed.statusEntityID.hasPrefix("automation."), "实体匹配不选 automation")
    // 选中回填：选中的 entity_id 在分组结果中可定位（点击实体行后写回同一字符串）
    let pickerSelected = pickerEntities.first { $0.entityId == "light.office" }!
    check(pickerGroups.contains { $0.domain == "light"
        && $0.entities.contains { $0.entityId == pickerSelected.entityId } },
          "选中实体可在分类中回填定位")
    // Beta 标识判定：HA/Bambu 模块标记实验性，其余模块不标记
    check(CanvasModule.homeAssistant.isBeta, "HA 画板模块标记 Beta")
    check(CanvasModule.bambuLab.isBeta, "Bambu 画板模块标记 Beta")
    check(!CanvasModule.clock.isBeta, "时钟模块非 Beta")
    check(!CanvasModule.qwenQuota.isBeta, "千问额度模块非 Beta")
    // 多选批量添加合并：去空去重、保持现有顺序后按传入顺序追加
    checkEqual(HAEntityListEditor.merge([], adding: ["sensor.a", "light.b"]),
               ["sensor.a", "light.b"], "空列表批量添加")
    checkEqual(HAEntityListEditor.merge(["sensor.a"], adding: ["sensor.a", "light.b"]),
               ["sensor.a", "light.b"], "批量添加去重（跳过已存在）")
    checkEqual(HAEntityListEditor.merge(["sensor.a"], adding: ["", "switch.c", "  "]),
               ["sensor.a", "switch.c"], "批量添加去空")
    checkEqual(HAEntityListEditor.merge(["sensor.a", "light.b"], adding: ["switch.c", "sensor.a"]),
               ["sensor.a", "light.b", "switch.c"], "批量添加保持现有顺序后追加")
    print("  Home Assistant 通过")
}

// MARK: - 番茄钟模块居中

func testPomodoroCentering() throws {
    let fixed = Date(timeIntervalSince1970: 1_752_000_000)
    let system = SystemSnapshot(cpuPercent: 0, memoryPercent: 0,
                                usedMemoryBytes: 0, totalMemoryBytes: 0,
                                downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
                                uptime: 0, sampledAt: Date())
    let np = NowPlayingInfo.sample
    let pomo = PomodoroSnapshot(phase: .focus, effectivePhase: .focus, taskName: "任务",
                                remaining: 1500, duration: 1500, completedFocusSessions: 1,
                                endsAt: Date().addingTimeInterval(1500))
    let ps = AppSettings()
    ps.canvasModules = [CanvasModule.pomodoro.rawValue]
    let r = try ScreenRenderer.renderCanvas(modules: ps.canvasModuleList, system: system,
                                            nowPlaying: np, pomodoro: pomo,
                                            customText: "", settings: ps, now: fixed)
    // 单模块时番茄钟带为 103...409（安全区 56 + 标头 46 / 卡底 10），带中心 256；
    // 内容包围盒（亮色文字像素，避开卡片边框列 x=9/133）中心应贴近带中心
    let img = r.image
    let w = img.width, h = img.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var minY = 428, maxY = 0
    for y in 103..<409 {
        for x in 12..<130 {
            let i = (y * w + x) * 4
            if Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2]) > 200 {
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
    }
    check(minY < maxY, "番茄钟内容应存在")
    let center = (minY + maxY) / 2
    check(abs(center - 256) <= 6, "番茄钟内容应居中于模块带（min=\(minY) max=\(maxY) center=\(center) 期望 256）")

    // 阶段标识与时间紧凑成块：两段文字间空隙小（旧版两行均分空隙极大）
    func brightSegments(_ img: CGImage, _ yRange: Range<Int>) -> [(Int, Int)] {
        let w = img.width
        let ctx = CGContext(data: nil, width: w, height: img.height, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var segments: [(Int, Int)] = []
        var segStart = -1
        for y in yRange {
            var count = 0
            for x in 12..<130 {
                let i = (y * w + x) * 4
                if Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2]) > 200 { count += 1 }
            }
            if count > 0 && segStart < 0 { segStart = y }
            if count == 0 && segStart >= 0 { segments.append((segStart, y - 1)); segStart = -1 }
        }
        if segStart >= 0 { segments.append((segStart, yRange.upperBound - 1)) }
        return segments
    }
    let tallSegs = brightSegments(r.image, 103..<409)
    checkEqual(tallSegs.count, 2, "番茄钟高条带应为两段文字（阶段+时间）")
    if tallSegs.count == 2 {
        check(tallSegs[1].0 - tallSegs[0].1 - 1 <= 12,
              "阶段与时间空隙应紧凑（空隙=\(tallSegs[1].0 - tallSegs[0].1 - 1)px）")
    }

    // 拥挤场景：多模块短条带应自动缩窄空隙、收缩字号保持外边缘
    var crowded = AppSettings()
    crowded.canvasModules = [CanvasModule.pomodoro.rawValue, CanvasModule.clock.rawValue,
                             CanvasModule.cpu.rawValue, CanvasModule.memory.rawValue,
                             CanvasModule.network.rawValue, CanvasModule.disk.rawValue,
                             CanvasModule.codex.rawValue, CanvasModule.qwenQuota.rawValue]
    let crowdedRender = try ScreenRenderer.renderCanvas(modules: crowded.canvasModuleList, system: system,
                                                        nowPlaying: np, pomodoro: pomo,
                                                        customText: "", settings: crowded, now: fixed)
    let shortSegs = brightSegments(crowdedRender.image, 105..<139)
    checkEqual(shortSegs.count, 2, "番茄钟短条带仍为两段文字（阶段+时间）")
    if shortSegs.count == 2 {
        let gap = shortSegs[1].0 - shortSegs[0].1 - 1
        let span = shortSegs[1].1 - shortSegs[0].0 + 1
        check(gap <= 10, "短条带阶段与时间空隙应更窄（空隙=\(gap)px）")
        check(span <= 32, "短条带内容应收缩以适应模块（span=\(span)px）")
    }
    print("  番茄钟居中通过")
}




















































dispatchMain()
