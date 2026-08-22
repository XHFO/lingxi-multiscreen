import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum RenderError: Error, LocalizedError {
    case encodeFailed
    case tooLarge(Int)
    case cannotDecodeImage
    case noCustomImage

    public var errorDescription: String? {
        switch self {
        case .encodeFailed: return "无法编码 JPEG 图片。"
        case .tooLarge(let bytes): return "屏幕图片为 \(bytes) 字节，超过 512KB 限制。"
        case .cannotDecodeImage: return "无法读取自定义图片。"
        case .noCustomImage: return "请先选择一张自定义图片。"
        }
    }
}

public struct RenderResult {
    public var data: Data
    public var image: CGImage
}

/// 把 Codex 用量 / 番茄钟 / 系统监控 / 自定义图片渲染为 142×428 JPEG。
/// 布局坐标与原版 SkiaSharp 渲染器完全一致（y 轴向下，从屏幕顶部起算），
/// 内部统一转换到 Core Graphics 的 y 轴向上坐标系。
public enum ScreenRenderer {
    public static let width = 142
    public static let height = 428
    public static let maximumFileSize = 512 * 1024

    // MARK: - 对外渲染入口

    public static func renderUsage(_ snapshot: UsageSnapshot, settings: AppSettings,
                                   now: Date = Date()) throws -> RenderResult {
        let colors = settings.resolvedPalette
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let card = drawCanvas(ctx, safeArea: safe, colors: colors)

        let c = card // Skia 语义：原点在左上
        drawHeader(ctx, card: c, title: "CODEX", badge: "实时",
                   accent: colors.accentCG, colors: colors)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)

        let top = c.minY + 49
        // 与千问办公额度卡同款布局：标题 → 大数字居中 → 单位 → 进度条 → 描述 → 信息框 → 页脚
        drawText(ctx, snapshot.windowTitle, size: 10, bold: true, color: colors.secondaryTextCG,
                 in: rect(c.minX + 9, top, c.maxX - c.minX - 18, 18), align: .center)
        drawText(ctx, "\(snapshot.remainingPercent)", size: 38, bold: true, color: colors.primaryTextCG,
                 in: rect(c.minX + 5, top + 16, c.maxX - c.minX - 10, 62), align: .center)
        drawText(ctx, "%", size: 11, bold: true, color: colors.accentCG,
                 in: rect(c.minX + 5, top + 80, c.maxX - c.minX - 10, 18), align: .center)
        drawProgress(ctx, rect(c.minX + 12, top + 102, c.maxX - c.minX - 24, 8),
                     progress: Double(snapshot.remainingPercent) / 100,
                     accent: colors.accentCG, background: colors.borderCG)
        drawText(ctx, snapshot.windowDescription, size: 9, bold: false, color: colors.tertiaryTextCG,
                 in: rect(c.minX + 9, top + 114, c.maxX - c.minX - 18, 18), align: .center)

        let resetSkia = CGRect(x: c.minX + 9, y: c.minY + 163, width: c.maxX - c.minX - 18, height: 70)
        drawBox(ctx, rect(resetSkia), colors: colors)
        drawText(ctx, "可用重置", size: 10, bold: true, color: colors.secondaryTextCG,
                 in: rect(resetSkia.minX + 10, resetSkia.minY + 7, resetSkia.width - 20, 20), align: .left)
        drawText(ctx, "\(snapshot.availableResetCount)", size: 28, bold: true, color: colors.primaryTextCG,
                 in: rect(resetSkia.minX + 10, resetSkia.minY + 24, 58, resetSkia.height - 30), align: .left)
        drawText(ctx, "次", size: 11, bold: true, color: colors.accentCG,
                 in: rect(resetSkia.maxX - 30, resetSkia.minY + 37, 20, 21), align: .right)

        let localNow = now
        let bottom = c.maxY - 15
        let resetText: String
        if let resetDate = snapshot.resetDate {
            resetText = "下次重置 \(formatDate(resetDate, "M/d HH:mm"))"
        } else {
            resetText = "重置时间未知"
        }
        drawText(ctx, resetText, size: 8, bold: false, color: colors.tertiaryTextCG,
                 in: rect(c.minX + 7, bottom - 94, c.maxX - c.minX - 14, 15), align: .center)
        drawText(ctx, "当前时间", size: 9, bold: true, color: colors.tertiaryTextCG,
                 in: rect(c.minX + 9, bottom - 76, c.maxX - c.minX - 18, 17), align: .center)
        drawText(ctx, formatDate(localNow, "M月d日"), size: 17, bold: true, color: colors.primaryTextCG,
                 in: rect(c.minX + 5, bottom - 57, c.maxX - c.minX - 10, 24), align: .center)
        drawText(ctx, formatDate(localNow, "HH:mm"), size: 22, bold: true, color: colors.accentCG,
                 in: rect(c.minX + 5, bottom - 32, c.maxX - c.minX - 10, 32), align: .center)

        return try encode(ctx, quality: settings.jpegQuality)
    }

    public static func renderPomodoro(_ snapshot: PomodoroSnapshot, settings: AppSettings,
                                      now: Date = Date()) throws -> RenderResult {
        let colors = settings.resolvedPalette
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let c = drawCanvas(ctx, safeArea: safe, colors: colors)

        let isBreak = snapshot.effectivePhase == .shortBreak || snapshot.effectivePhase == .longBreak
        let accent = isBreak ? colors.secondaryAccentCG : colors.accentCG
        drawHeader(ctx, card: c, title: isBreak ? "BREAK" : "FOCUS",
                   badge: snapshot.isRunning ? "LIVE" : snapshot.isPaused ? "PAUSE" : "READY",
                   accent: accent, colors: colors)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)
        drawText(ctx, snapshot.taskName.isEmpty ? "专注工作" : snapshot.taskName,
                 size: CGFloat(settings.pomodoroTaskFontSize), bold: true, color: colors.primaryTextCG,
                 in: rect(c.minX + 10, c.minY + 50, c.maxX - c.minX - 20, 34), align: .center)

        let seconds = max(0, Int(ceil(snapshot.remaining)))
        drawText(ctx, String(format: "%02d:%02d", seconds / 60, seconds % 60),
                 size: 28, bold: true, color: colors.primaryTextCG,
                 in: rect(c.minX + 6, c.minY + 86, c.maxX - c.minX - 12, 45), align: .center)
        drawProgress(ctx, rect(c.minX + 12, c.minY + 139, c.maxX - c.minX - 24, 8),
                     progress: snapshot.progress, accent: accent, background: colors.borderCG)
        drawText(ctx, snapshot.isPaused ? "已暂停" : snapshot.isRunning ? "保持节奏" : "点击开始",
                 size: 8, bold: false, color: colors.secondaryTextCG,
                 in: rect(c.minX + 8, c.minY + 153, c.maxX - c.minX - 16, 20), align: .center)

        let completedSkia = CGRect(x: c.minX + 10, y: c.minY + 184, width: c.maxX - c.minX - 20, height: 73)
        drawBox(ctx, rect(completedSkia), colors: colors)
        drawText(ctx, "今日完成", size: 7, bold: false, color: colors.secondaryTextCG,
                 in: rect(completedSkia.minX, completedSkia.minY + 10, completedSkia.width, 18), align: .center)
        drawText(ctx, "\(snapshot.completedFocusSessions)", size: 28, bold: true, color: accent,
                 in: rect(completedSkia.minX, completedSkia.minY + 28, completedSkia.width, completedSkia.height - 36), align: .center)
        let footer: String
        if snapshot.isRunning, let end = snapshot.endsAt {
            footer = "结束 \(formatDate(end, "HH:mm"))"
        } else {
            footer = "现在 \(formatDate(now, "HH:mm"))"
        }
        drawText(ctx, footer, size: 8, bold: false, color: colors.secondaryTextCG,
                 in: rect(c.minX + 8, c.maxY - 46, c.maxX - c.minX - 16, 20), align: .center)
        drawText(ctx, "POMODORO", size: 7, bold: false, color: accent,
                 in: rect(c.minX + 8, c.maxY - 24, c.maxX - c.minX - 16, 16), align: .center)

        return try encode(ctx, quality: settings.jpegQuality)
    }

    // MARK: - 夸夸卡（完成时间段后的庆祝画面，任何界面下都会显示）

    public static func renderPraise(text: String, sessions: Int, settings: AppSettings,
                                    now: Date = Date()) throws -> RenderResult {
        let colors = settings.resolvedPalette
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let c = drawCanvas(ctx, safeArea: safe, colors: colors)

        drawHeader(ctx, card: c, title: "POMODORO", badge: "完成",
                   accent: colors.accentCG, colors: colors)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)

        // 大号「完成！」
        drawText(ctx, "完成！", size: 30, bold: true, color: colors.primaryTextCG,
                 in: rect(c.minX + 8, c.minY + 74, c.maxX - c.minX - 16, 44), align: .center)

        // 夸夸文字：自适应缩字号到放得下为止（下限 6pt，完整显示句子）
        let maxWidth = c.maxX - c.minX - 16
        var size: CGFloat = 11
        var tw = measureTextWidth(text, size: size, bold: false)
        if tw > maxWidth {
            size = max(size * maxWidth / tw, 6)
            tw = measureTextWidth(text, size: size, bold: false)
        }
        drawText(ctx, text, size: size, bold: false, color: colors.secondaryTextCG,
                 in: rect(c.minX + 8, c.minY + 130, maxWidth, 30), align: .center)

        // 已完成轮数
        drawText(ctx, "已完成", size: 8, bold: false, color: colors.secondaryTextCG,
                 in: rect(c.minX + 8, c.minY + 190, c.maxX - c.minX - 16, 18), align: .center)
        drawText(ctx, "\(sessions)", size: 34, bold: true, color: colors.accentCG,
                 in: rect(c.minX + 8, c.minY + 210, c.maxX - c.minX - 16, 44), align: .center)
        drawText(ctx, "个专注时段", size: 8, bold: false, color: colors.secondaryTextCG,
                 in: rect(c.minX + 8, c.minY + 256, c.maxX - c.minX - 16, 18), align: .center)

        drawText(ctx, "POMODORO", size: 7, bold: false, color: colors.accentCG,
                 in: rect(c.minX + 8, c.maxY - 24, c.maxX - c.minX - 16, 16), align: .center)

        return try encode(ctx, quality: settings.jpegQuality)
    }

    public static func renderSystem(_ snapshot: SystemSnapshot, history: [NetworkSample] = [],
                                    settings: AppSettings) throws -> RenderResult {
        let colors = settings.resolvedPalette
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let c = drawCanvas(ctx, safeArea: safe, colors: colors)

        drawHeader(ctx, card: c, title: "SYSTEM", badge: "LIVE",
                   accent: colors.accentCG, colors: colors,
                   dotColor: loadIndicatorColor(percent: snapshot.cpuPercent))
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)

        // 按开关收集可见板块（动态排版）
        var sections: [SystemSection] = []
        if settings.showCpu { sections.append(.cpu) }
        if settings.showMemory { sections.append(.memory) }
        if settings.showNetwork { sections.append(.network) }
        if settings.showUptime { sections.append(.uptime) }
        if sections.isEmpty { sections = [.cpu] }

        let regionTop = c.minY + 49 + 6
        let regionBottom = c.maxY - 15 - 30  // 预留页脚时间戳
        let slotHeight = max(44, (regionBottom - regionTop) / CGFloat(sections.count))

        for (index, section) in sections.enumerated() {
            let slotTop = regionTop + CGFloat(index) * slotHeight
            switch section {
            case .cpu:
                let contentHeight: CGFloat = 48
                let sTop = slotTop + max(0, (slotHeight - contentHeight) / 2)
                drawText(ctx, "CPU", size: 7.5, bold: false, color: colors.secondaryTextCG,
                         in: rect(c.minX + 12, sTop, c.maxX - c.minX - 24, 19), align: .left)
                drawText(ctx, String(format: "%.0f%%", snapshot.cpuPercent), size: 24, bold: true,
                         color: colors.primaryTextCG,
                         in: rect(c.minX + 8, sTop + 6, c.maxX - c.minX - 18, 32), align: .right)
                drawProgress(ctx, rect(c.minX + 12, sTop + 40, c.maxX - c.minX - 24, 7),
                             progress: snapshot.cpuPercent / 100,
                             accent: colors.accentCG, background: colors.borderCG)
            case .memory:
                let contentHeight: CGFloat = 56
                let sTop = slotTop + max(0, (slotHeight - contentHeight) / 2)
                drawText(ctx, "内存", size: 7.5, bold: false, color: colors.secondaryTextCG,
                         in: rect(c.minX + 12, sTop, 38, 21), align: .left)
                drawText(ctx, String(format: "%.0f%%", snapshot.memoryPercent), size: 11, bold: true,
                         color: colors.primaryTextCG,
                         in: rect(c.minX + 46, sTop, c.maxX - c.minX - 58, 23), align: .right)
                drawProgress(ctx, rect(c.minX + 12, sTop + 24, c.maxX - c.minX - 24, 7),
                             progress: snapshot.memoryPercent / 100,
                             accent: colors.secondaryAccentCG, background: colors.borderCG)
                drawText(ctx, String(format: "%.1f / %.1f GB", toGiB(snapshot.usedMemoryBytes), toGiB(snapshot.totalMemoryBytes)),
                         size: 7.5, bold: false, color: colors.secondaryTextCG,
                         in: rect(c.minX + 8, sTop + 38, c.maxX - c.minX - 16, 17), align: .center)
            case .network:
                // 盒子高度被槽位钳制，内部所有行按盒子实际高度比例排布；
                // 注意：文字定位必须用 Skia 语义坐标（rect() 只转换一次），
                // 此前误用 CG 矩形的 minY 当 Skia y，导致网络文字画到 CPU/内存区（堆叠根因）
                let contentHeight = min(slotHeight - 8, 88)
                let sTop = slotTop + max(0, (slotHeight - contentHeight) / 2)
                let boxSkia = CGRect(x: c.minX + 10, y: sTop,
                                     width: c.maxX - c.minX - 20, height: contentHeight)
                drawBox(ctx, rect(boxSkia), colors: colors)
                drawText(ctx, "网络速率", size: 7.5, bold: false, color: colors.secondaryTextCG,
                         in: rect(boxSkia.minX + 9, boxSkia.minY + 6, boxSkia.width - 18, 15), align: .left)
                let bodyTop = boxSkia.minY + 6 + 15 + 3
                let bodyHeight = max(contentHeight - (6 + 15 + 3 + 5), 20)
                if settings.networkChart, history.count >= 2 {
                    drawNetworkChart(ctx, in: rect(boxSkia.minX + 9, bodyTop, boxSkia.width - 18, bodyHeight),
                                     history: history, colors: colors)
                } else {
                    let rowH = bodyHeight / 2
                    drawText(ctx, "↓", size: 11, bold: true, color: colors.accentCG,
                             in: rect(boxSkia.minX + 9, bodyTop, 19, rowH), align: .left)
                    drawText(ctx, formatRate(snapshot.downloadBytesPerSecond), size: 11, bold: true,
                             color: colors.primaryTextCG,
                             in: rect(boxSkia.minX + 29, bodyTop, boxSkia.width - 37, rowH), align: .right)
                    drawText(ctx, "↑", size: 11, bold: true, color: colors.secondaryAccentCG,
                             in: rect(boxSkia.minX + 9, bodyTop + rowH, 19, rowH), align: .left)
                    drawText(ctx, formatRate(snapshot.uploadBytesPerSecond), size: 11, bold: true,
                             color: colors.primaryTextCG,
                             in: rect(boxSkia.minX + 29, bodyTop + rowH, boxSkia.width - 37, rowH), align: .right)
                }
            case .uptime:
                drawText(ctx, uptimeText(snapshot.uptime), size: 7.5, bold: false,
                         color: colors.secondaryTextCG,
                         in: rect(c.minX + 8, slotTop, c.maxX - c.minX - 16, slotHeight), align: .center)
            }
        }

        // 页脚时间戳
        drawText(ctx, formatDate(snapshot.sampledAt, "HH:mm:ss"), size: 7.5, bold: false,
                 color: colors.secondaryTextCG,
                 in: rect(c.minX + 8, c.maxY - 15 - 24, c.maxX - c.minX - 16, 18), align: .center)

        return try encode(ctx, quality: settings.jpegQuality)
    }

    private enum SystemSection { case cpu, memory, network, uptime }

    private static func uptimeText(_ uptime: TimeInterval) -> String {
        if uptime >= 86400 {
            return "运行 \(Int(uptime / 86400))天 \(Int(uptime.truncatingRemainder(dividingBy: 86400) / 3600))时"
        } else {
            return "运行 \(Int(uptime / 3600))时 \(Int(uptime.truncatingRemainder(dividingBy: 3600) / 60))分"
        }
    }

    /// 网络速率折线图：下行（强调色）/ 上行（次强调色）两条线共用同一峰值刻度，
    /// history 时间升序、最新在右；附带底部基线与 50% 参考线
    private static func drawNetworkChart(_ ctx: CGContext, in bounds: CGRect,
                                         history: [NetworkSample], colors: ScreenPalette) {
        let peakValue = history
            .map { max($0.downloadBytesPerSecond, $0.uploadBytesPerSecond) }
            .max() ?? 0
        let peak = max(CGFloat(peakValue), 4096) // 至少覆盖 4KB/s，避免低速时贴底
        let count = history.count
        let step = count > 1 ? bounds.width / CGFloat(count - 1) : 0

        ctx.saveGState()
        ctx.setStrokeColor(colors.borderCG)
        ctx.setLineWidth(0.5)
        for fraction in [0.0, 0.5, 1.0] as [CGFloat] {
            let y = bounds.minY + bounds.height * (1 - fraction)
            ctx.move(to: CGPoint(x: bounds.minX, y: y))
            ctx.addLine(to: CGPoint(x: bounds.maxX, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()

        func points(_ rate: @escaping (NetworkSample) -> Double) -> [CGPoint] {
            history.enumerated().map { index, sample in
                let x = bounds.minX + CGFloat(index) * step
                let y = bounds.minY + bounds.height * (1 - CGFloat(rate(sample)) / peak)
                return CGPoint(x: x, y: min(max(y, bounds.minY), bounds.maxY))
            }
        }
        drawPolyline(ctx, points: points { $0.downloadBytesPerSecond }, color: colors.accentCG)
        drawPolyline(ctx, points: points { $0.uploadBytesPerSecond }, color: colors.secondaryAccentCG)
    }

    private static func drawPolyline(_ ctx: CGContext, points: [CGPoint], color: CGColor) {
        guard points.count >= 2 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.move(to: points[0])
        for point in points.dropFirst() { ctx.addLine(to: point) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - 画板（功能模块自由组合）

    /// 画板：把选中的功能模块垂直堆叠成一张 142×428 卡片
    public static func renderCanvas(modules: [CanvasModule], system: SystemSnapshot,
                                    nowPlaying: NowPlayingInfo, pomodoro: PomodoroSnapshot,
                                    customText: String, settings: AppSettings,
                                    codex: UsageSnapshot = .sample,
                                    qwenQuota: QwenWorkQuota = .sample,
                                    sspaiArticles: [SspaiArticle] = [],
                                    now: Date = Date(),
                                    palette: ScreenPalette? = nil) throws -> RenderResult {
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        // 画板专用底色模式（手动深/浅色）覆盖默认调色板
        let basePalette = palette ?? settings.resolvedPalette

        // 背景模式：图像模块铺满整卡作底（其上叠加深色蒙版保证文字可读）
        let useImageBackground = modules.contains(.image)
            && settings.canvasImageMode == .background
            && isCanvasImageReady(settings.customImagePath)

        // 智能封面取色背景：整卡背景替换为专辑封面主色（同「正在播放」卡片设计），
        // 需画板含「正在播放」模块且有封面；整卡文字/边框随主色明暗自适应
        let coverArt = settings.canvasNowPlayingSmartBg && modules.contains(.nowPlaying)
            ? (nowPlaying.artwork.flatMap { decodeArtwork($0) })
            : nil

        let colors: ScreenPalette
        let c: CGRect
        if useImageBackground, let path = settings.customImagePath {
            colors = ScreenThemes.get(.deepSpace) // 深色系，保证图上文字可读
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            drawImageCover(ctx, path: path,
                           into: CGRect(x: 0, y: CGFloat(safe), width: CGFloat(width),
                                        height: CGFloat(height) - CGFloat(safe)))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            c = CGRect(x: 9, y: CGFloat(safe) + 1, width: 124,
                       height: CGFloat(height) - 9 - (CGFloat(safe) + 1))
            strokeRound(ctx, rect(c), radius: 13, color: colors.borderCG, width: 1)
        } else if let coverArt {
            let dominant = dominantColor(of: coverArt)
            colors = artworkPalette(baseColor: dominant,
                                    themeAccent: basePalette.accent)
            c = drawCanvas(ctx, safeArea: safe, colors: colors)
        } else {
            colors = basePalette
            c = drawCanvas(ctx, safeArea: safe, colors: colors)
        }

        drawHeader(ctx, card: c, title: "CANVAS", badge: "灵犀画板",
                   accent: colors.accentCG, colors: colors)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)

        let regionTop = c.minY + 46
        let regionBottom = c.maxY - 10
        let regionHeight = max(regionBottom - regionTop, 30)
        if modules.isEmpty {
            drawText(ctx, "在「灵犀画板」面板添加模块", size: 8, bold: false, color: colors.secondaryTextCG,
                     in: rect(c.minX + 8, regionTop, c.maxX - c.minX - 16, 20), align: .center)
        } else {
            let region = CGRect(x: c.minX + 8, y: regionTop,
                                width: c.maxX - c.minX - 16, height: regionHeight)
            let bands = moduleBands(modules: modules, region: region, settings: settings)
            for (index, module) in modules.enumerated() {
                drawCanvasModule(ctx, module, band: bands[index], colors: colors,
                                 system: system, nowPlaying: nowPlaying, pomodoro: pomodoro,
                                 customText: customText, settings: settings,
                                 codex: codex, qwenQuota: qwenQuota, sspaiArticles: sspaiArticles,
                                 now: now,
                                 nowPlayingSmartBg: settings.canvasNowPlayingSmartBg,
                                 canvasCoverBgActive: coverArt != nil)
            }
        }
        return try encode(ctx, quality: settings.jpegQuality)
    }

    /// 模块加权分带：模块上下边距越大（紧凑度越高）权重越小、占用高度越少。
    /// columns=2 时按双列流式排列：普通模块占一列，fullWidthModules 中的模块占满整行；
    /// 行高按该行最大权重计算（同行的两个模块等高）。
    private static func moduleBands(modules: [CanvasModule], region: CGRect,
                                    settings: AppSettings,
                                    columns: Int = 1,
                                    fullWidthModules: Set<Int> = []) -> [CGRect] {
        let weights = modules.map { m -> CGFloat in
            let margin = settings.canvasMargin(for: m)
            return max(0.25, 1.0 - CGFloat(margin) / 40.0)
        }
        var bands: [CGRect] = []
        if columns <= 1 || modules.count <= 1 {
            let totalWeight = weights.reduce(0, +)
            var cursor = region.minY
            for (index, _) in modules.enumerated() {
                let bandHeight = region.height * weights[index] / totalWeight
                bands.append(CGRect(x: region.minX, y: cursor,
                                    width: region.width, height: bandHeight))
                cursor += bandHeight
            }
            return bands
        }

        // 双列流式：构建行（每行 1–2 个普通模块，或 1 个整行模块）
        var rows: [[Int]] = []
        var currentRow: [Int] = []
        for (index, module) in modules.enumerated() {
            if fullWidthModules.contains(module.rawValue) {
                if !currentRow.isEmpty {
                    rows.append(currentRow)
                    currentRow = []
                }
                rows.append([index])
            } else {
                currentRow.append(index)
                if currentRow.count == 2 {
                    rows.append(currentRow)
                    currentRow = []
                }
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        let rowWeights = rows.map { row -> CGFloat in
            var maxWeight: CGFloat = 0
            for index in row {
                if weights[index] > maxWeight { maxWeight = weights[index] }
            }
            return maxWeight
        }
        let totalRowWeight = rowWeights.reduce(0, +)
        let gap: CGFloat = 6
        let colWidth = (region.width - gap) / 2
        bands = [CGRect](repeating: .zero, count: modules.count)
        var cursor = region.minY
        for (rowIndex, row) in rows.enumerated() {
            let rowHeight = region.height * rowWeights[rowIndex] / totalRowWeight
            if row.count == 2 {
                let left = row[0]
                let right = row[1]
                bands[left] = CGRect(x: region.minX, y: cursor, width: colWidth, height: rowHeight)
                bands[right] = CGRect(x: region.minX + colWidth + gap, y: cursor,
                                      width: colWidth, height: rowHeight)
            } else {
                let index = row[0]
                let spansBoth = fullWidthModules.contains(modules[index].rawValue)
                bands[index] = CGRect(x: region.minX, y: cursor,
                                      width: spansBoth ? region.width : colWidth,
                                      height: rowHeight)
            }
            cursor += rowHeight
        }
        return bands
    }

    /// 独立设备画布渲染：把模块组合渲染为指定尺寸的画布（无键盘卡片外壳/安全区）。
    /// 图像模块一律按「叠加」处理（铺满自己的横带）；
    /// flipVertical/flipHorizontal 上下/左右翻转整幅画面（同开 = 旋转 180°）；
    /// columns=2 时模块按双列排列，fullWidthModules 中的模块占满整行（摘录画板用）。
    public static func renderDeviceCanvas(modules: [CanvasModule], system: SystemSnapshot,
                                          nowPlaying: NowPlayingInfo, pomodoro: PomodoroSnapshot,
                                          customText: String, settings: AppSettings,
                                          codex: UsageSnapshot = .sample,
                                          qwenQuota: QwenWorkQuota = .sample,
                                          sspaiArticles: [SspaiArticle] = [],
                                          now: Date = Date(),
                                          width: Int, height: Int,
                                          palette: ScreenPalette,
                                          flipVertical: Bool = false,
                                          flipHorizontal: Bool = false,
                                          columns: Int = 1,
                                          fullWidthModules: Set<Int> = [],
                                          nowPlayingHorizontal: Bool = false) -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("create device canvas context")
        }
        // 墨水屏设备画板：所有文字与强调色统一为最深对比色（无色相）。
        // 浅色底取纯黑、深色底取纯白，保证任何底色模式都清晰可读。
        let einkPalette = einkTextPalette(palette)
        ctx.setFillColor(einkPalette.backgroundCG)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 模块绘制助手统一按键盘画板高度（428）做 Skia→CG 翻转；
        // 平移 CTM 使同一套坐标正确落到当前尺寸的画布上
        ctx.translateBy(x: 0, y: CGFloat(height) - CGFloat(ScreenRenderer.height))

        let inset: CGFloat = 8
        let region = CGRect(x: inset, y: inset,
                            width: CGFloat(width) - inset * 2,
                            height: CGFloat(height) - inset * 2)
        if modules.isEmpty {
            drawText(ctx, "请在面板中添加模块", size: 9, bold: false,
                     color: einkPalette.secondaryTextCG,
                     in: rect(region.minX, region.minY + region.height / 2 - 8, region.width, 16),
                     align: .center)
        } else {
            let bands = moduleBands(modules: modules, region: region, settings: settings,
                                    columns: columns, fullWidthModules: fullWidthModules)
            for (index, module) in modules.enumerated() {
                drawCanvasModule(ctx, module, band: bands[index], colors: einkPalette,
                                 system: system, nowPlaying: nowPlaying, pomodoro: pomodoro,
                                 customText: customText, settings: settings,
                                 codex: codex, qwenQuota: qwenQuota, sspaiArticles: sspaiArticles,
                                 now: now,
                                 imageOverlayOnly: true,
                                 nowPlayingSmartBg: false,
                                 fullWidth: fullWidthModules.contains(module.rawValue),
                                 deviceCanvas: true,
                                 nowPlayingHorizontal: nowPlayingHorizontal)
            }
        }
        var result = ctx.makeImage() ?? placeholderCanvas()
        if flipVertical, let flipped = flipImageVertical(result) {
            result = flipped
        }
        if flipHorizontal, let flipped = flipImageHorizontal(result) {
            result = flipped
        }
        return result
    }

    /// 墨水屏文字调色板：把文字与强调色统一为最深对比色（无色相），
    /// 浅色底 → 纯黑、深色底 → 纯白；背景/边框保持不变。
    private static func einkTextPalette(_ base: ScreenPalette) -> ScreenPalette {
        var palette = base
        let deep = einkDeepColorRGB(against: base.background)
        palette.primaryText = deep
        palette.secondaryText = deep
        palette.tertiaryText = deep
        palette.accent = deep
        palette.secondaryAccent = deep
        return palette
    }

    /// 按底色明暗返回最深对比色（浅底黑、深底白），用于墨水屏文字/描边
    private static func einkDeepColorRGB(against bg: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
        let lum = 0.299 * bg.0 + 0.587 * bg.1 + 0.114 * bg.2
        return lum >= 0.5 ? (0, 0, 0) : (1, 1, 1)
    }

    /// 上下翻转整幅图像（绕水平中线）
    private static func flipImageVertical(_ image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 左右翻转整幅图像（绕垂直中线）
    private static func flipImageHorizontal(_ image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 画板自定义图像是否可用（有路径且文件存在）
    private static func isCanvasImageReady(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// 把图片按 cover 方式铺满目标区域（Skia 语义矩形，居中裁切不变形）
    private static func drawImageCover(_ ctx: CGContext, path: String, into target: CGRect) {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let targetRatio = target.width / target.height
        let sourceRatio = CGFloat(original.width) / CGFloat(original.height)
        let crop: CGRect
        if sourceRatio > targetRatio {
            let cropWidth = CGFloat(original.height) * targetRatio
            crop = CGRect(x: (CGFloat(original.width) - cropWidth) / 2, y: 0,
                          width: cropWidth, height: CGFloat(original.height))
        } else {
            let cropHeight = CGFloat(original.width) / targetRatio
            crop = CGRect(x: 0, y: (CGFloat(original.height) - cropHeight) / 2,
                          width: CGFloat(original.width), height: cropHeight)
        }
        guard let cropped = original.cropping(to: crop) else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: rect(target))
        ctx.restoreGState()
    }

    /// 绘制单个画板模块（band 为 Skia 语义的横带）；imageOverlayOnly=true 时图像模块强制按叠加绘制；
    /// nowPlayingSmartBg=true 时正在播放模块用封面主色填充模块底（键盘画板整卡背景已是封面主色时由
    /// canvasCoverBgActive=true 跳过，避免出现色差圆角块）
    private static func drawCanvasModule(_ ctx: CGContext, _ module: CanvasModule, band: CGRect,
                                         colors: ScreenPalette, system: SystemSnapshot,
                                         nowPlaying: NowPlayingInfo, pomodoro: PomodoroSnapshot,
                                         customText: String, settings: AppSettings,
                                         codex: UsageSnapshot, qwenQuota: QwenWorkQuota,
                                         sspaiArticles: [SspaiArticle], now: Date,
                                         imageOverlayOnly: Bool = false,
                                         nowPlayingSmartBg: Bool = false,
                                         canvasCoverBgActive: Bool = false,
                                         fullWidth: Bool = false,
                                         deviceCanvas: Bool = false,
                                         nowPlayingHorizontal: Bool = false) {
        let w = band.width
        switch module {
        case .clock:
            let text = clockTimeText(now, format: settings.canvasClockFormat)
            var size = min(band.height * 0.62, 32)
            var tw = measureTextWidth(text, size: size, bold: true)
            if tw > w - 4 {
                size = max(size * (w - 4) / tw, 10)
                tw = measureTextWidth(text, size: size, bold: true)
            }
            drawText(ctx, text, size: size, bold: true, color: colors.primaryTextCG,
                     in: rect(band.minX, band.minY - 2, w, band.height), align: .center)
        case .date:
            let text = formatDate(now, settings.canvasDateFormat)
            var size = min(band.height * 0.42, 14)
            var tw = measureTextWidth(text, size: size, bold: false)
            if tw > w - 4 {
                size = max(size * (w - 4) / tw, 7)
                tw = measureTextWidth(text, size: size, bold: false)
            }
            drawText(ctx, text, size: size, bold: false, color: colors.primaryTextCG,
                     in: rect(band.minX, band.minY, w, band.height), align: .center)
        case .cpu:
            drawStatBand(ctx, band: band, label: "CPU", percent: system.cpuPercent,
                         accent: colors.accentCG, colors: colors)
        case .memory:
            drawStatBand(ctx, band: band, label: "内存", percent: system.memoryPercent,
                         accent: colors.secondaryAccentCG, colors: colors)
        case .codex:
            let pct = codex.remainingPercent
            drawQuotaBand(ctx, band: band, label: "Codex", value: "\(pct)%",
                          progress: Double(pct) / 100, accent: colors.accentCG, colors: colors)
        case .qwenQuota:
            let numberText = qwenQuota.remainingCredits >= 100
                ? String(format: "%.0f", qwenQuota.remainingCredits)
                : String(format: "%.1f", qwenQuota.remainingCredits)
            let unit = qwenQuota.unit.isEmpty ? "credits" : qwenQuota.unit
            // 百分比仅在设置了手动基线后显示
            let percentText = qwenQuota.trackedProgress.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
            drawQuotaBand(ctx, band: band, label: "千问额度",
                          value: "\(numberText) \(unit)\(percentText)",
                          progress: qwenQuota.progress, accent: colors.secondaryAccentCG, colors: colors)
        case .network:
            let rowH = max(band.height / 2, 10)
            drawText(ctx, "↓ " + formatRate(system.downloadBytesPerSecond), size: 10, bold: true,
                     color: colors.primaryTextCG,
                     in: rect(band.minX + 6, band.minY, w - 12, rowH), align: .left)
            drawText(ctx, "↑ " + formatRate(system.uploadBytesPerSecond), size: 10, bold: true,
                     color: colors.secondaryTextCG,
                     in: rect(band.minX + 6, band.minY + rowH, w - 12, rowH), align: .left)
        case .nowPlaying:
            let title = nowPlaying.title.isEmpty || nowPlaying.title == "未在播放" ? "未在播放" : nowPlaying.title
            let artist = nowPlaying.artist.isEmpty ? "" : nowPlaying.artist
            let art = nowPlaying.artwork.flatMap({ decodeArtwork($0) })
            // 智能封面取色背景：用专辑封面主色填充模块底，按明暗自动配深/浅文字。
            // 整卡背景已是封面主色（canvasCoverBgActive）时跳过，避免出现色差圆角块
            var primaryTextColor = colors.primaryTextCG
            var secondaryTextColor = colors.secondaryTextCG
            if nowPlayingSmartBg, let art, !canvasCoverBgActive {
                let dominant = dominantColor(of: art)
                let luminance = 0.299 * dominant.0 + 0.587 * dominant.1 + 0.114 * dominant.2
                fillRound(ctx, rect(band), radius: 6,
                          color: CGColor(red: dominant.0, green: dominant.1, blue: dominant.2, alpha: 1))
                if deviceCanvas {
                    // 墨水屏：模块底为封面主色，文字取最深对比色（无色相）
                    let deep = einkDeepColorRGB(against: dominant)
                    let deepCG = CGColor(red: deep.0, green: deep.1, blue: deep.2, alpha: 1)
                    primaryTextColor = deepCG
                    secondaryTextColor = deepCG
                } else if luminance >= 0.5 {
                    primaryTextColor = CGColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1)
                    secondaryTextColor = CGColor(red: 0.32, green: 0.35, blue: 0.42, alpha: 1)
                } else {
                    primaryTextColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                    secondaryTextColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.78)
                }
            }
            if settings.canvasNowPlayingCover, let art {
                // 横向排布（跨单元占满整行，或墨水屏画板开启「横向排布」）：封面居左、歌名/歌手居右
                if (fullWidth || nowPlayingHorizontal), band.width >= 120 {
                    let coverSize = max(min(band.height - 4, w * 0.45), 16)
                    let coverX = band.minX + 2
                    let coverY = band.minY + (band.height - coverSize) / 2
                    let coverRect = rect(coverX, coverY, coverSize, coverSize)
                    ctx.saveGState()
                    ctx.addPath(CGPath(roundedRect: coverRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                    ctx.clip()
                    ctx.interpolationQuality = .high
                    ctx.draw(art, in: coverRect)
                    ctx.restoreGState()
                    // 墨水屏设备画板：封面加 2px 黑色描边，避免浅色封面与背景融为一体
                    if deviceCanvas {
                        strokeRound(ctx, coverRect, radius: 6,
                                    color: CGColor(red: 0, green: 0, blue: 0, alpha: 1), width: 2)
                    } else {
                        strokeRound(ctx, coverRect, radius: 6, color: colors.borderCG, width: 1)
                    }
                    let textX = band.minX + coverSize + 8
                    let textW = max(w - coverSize - 12, 20)
                    let textAreaH = band.height

                    // 歌名：自适应字号 + 断句换行（最多 2 行）；超长时不硬缩成小字，而是换行完整显示
                    let titleCapH = textAreaH * 0.6
                    var titleSize = min(band.height * 0.36, CGFloat(settings.canvasNowPlayingTitleSize))
                    var titleLines: [String] = []
                    while titleSize >= 7 {
                        let wrapped = wrapText(title, maxWidth: textW, size: titleSize)
                        if wrapped.count <= 2,
                           CGFloat(wrapped.count) * titleSize * 1.3 <= titleCapH {
                            titleLines = wrapped
                            break
                        }
                        titleSize -= 0.5
                    }
                    if titleLines.isEmpty {
                        titleLines = Array(wrapText(title, maxWidth: textW, size: 7).prefix(2))
                        titleSize = 7
                    }
                    let titleH = CGFloat(titleLines.count) * titleSize * 1.3

                    // 作者信息：字号始终小于歌名（约 0.72 倍），便于在墨水屏上区分歌名/歌手；
                    // 自适应字号 + 断句换行（最多 2 行），紧随标题下方、不超出模块
                    let artistCapSize = max(titleSize * 0.72, 6)
                    var artistSize = min(artistCapSize,
                                         max(min(band.height * 0.24,
                                                 CGFloat(settings.canvasNowPlayingArtistSize)), 6))
                    var artistLines: [String] = []
                    while artistSize >= 6 {
                        let wrapped = wrapText(artist, maxWidth: textW, size: artistSize)
                        if wrapped.count <= 2,
                           CGFloat(wrapped.count) * artistSize * 1.3 <= textAreaH - titleH - 4 {
                            artistLines = wrapped
                            break
                        }
                        artistSize -= 0.5
                    }
                    if artistLines.isEmpty {
                        artistLines = Array(wrapText(artist, maxWidth: textW, size: 6).prefix(2))
                        artistSize = 6
                    }
                    let artistH = CGFloat(artistLines.count) * artistSize * 1.3

                    // 文本块整体垂直居中于封面（封面在模块内垂直居中），不覆盖封面
                    let blockH = titleH + 4 + artistH
                    let textTop = band.minY + max((textAreaH - blockH) / 2, 0)
                    for (li, line) in titleLines.enumerated() {
                        drawText(ctx, line, size: titleSize, bold: true, color: primaryTextColor,
                                 in: rect(textX, textTop + CGFloat(li) * titleSize * 1.25,
                                          textW, titleSize * 1.3), align: .left)
                    }
                    let artistTop = textTop + titleH + 4
                    for (li, line) in artistLines.enumerated() {
                        drawText(ctx, line, size: artistSize, bold: false, color: secondaryTextColor,
                                 in: rect(textX, artistTop + CGFloat(li) * artistSize * 1.25,
                                          textW, artistSize * 1.3), align: .left)
                    }
                } else {
                    // 大封面模式：专辑封面尽量大 + 下方歌名/作者（垂直排列）
                    let textH = max(band.height * 0.32, 20)
                    let coverSize = min(w - 4, max(band.height - textH - 4, 20))
                    let coverX = band.minX + (w - coverSize) / 2
                    let coverY = band.minY + 1
                    let coverRect = rect(coverX, coverY, coverSize, coverSize)
                    ctx.saveGState()
                    ctx.addPath(CGPath(roundedRect: coverRect, cornerWidth: 8, cornerHeight: 8, transform: nil))
                    ctx.clip()
                    ctx.interpolationQuality = .high
                    ctx.draw(art, in: coverRect)
                    ctx.restoreGState()
                    // 墨水屏设备画板：封面加 2px 黑色描边，避免浅色封面与背景融为一体
                    if deviceCanvas {
                        strokeRound(ctx, coverRect, radius: 8,
                                    color: CGColor(red: 0, green: 0, blue: 0, alpha: 1), width: 2)
                    } else {
                        strokeRound(ctx, coverRect, radius: 8, color: colors.borderCG, width: 1)
                    }
                    let textTop = band.minY + 1 + coverSize + 2
                    let textBand = CGRect(x: band.minX, y: textTop, width: w, height: band.maxY - textTop)
                    var ts = min(textBand.height * 0.5, CGFloat(settings.canvasNowPlayingTitleSize))
                    var tw = measureTextWidth(title, size: ts, bold: true)
                    if tw > w - 4 { ts = max(ts * (w - 4) / tw, 7); tw = measureTextWidth(title, size: ts, bold: true) }
                    drawText(ctx, title, size: ts, bold: true, color: primaryTextColor,
                             in: rect(band.minX, textTop, w, textBand.height * 0.55), align: .center)
                    drawText(ctx, artist, size: max(min(textBand.height * 0.4, CGFloat(settings.canvasNowPlayingArtistSize)), 6), bold: false,
                             color: secondaryTextColor,
                             in: rect(band.minX, textTop + textBand.height * 0.5, w, textBand.height * 0.5), align: .center)
                }
            } else {
                let h1 = max(band.height * 0.55, 10)
                let h2 = max(band.height - h1, 6)
                var size = min(h1 * 0.75, CGFloat(settings.canvasNowPlayingTitleSize))
                var tw = measureTextWidth(title, size: size, bold: true)
                if tw > w - 4 {
                    size = max(size * (w - 4) / tw, 8)
                    tw = measureTextWidth(title, size: size, bold: true)
                }
                drawText(ctx, title, size: size, bold: true, color: primaryTextColor,
                         in: rect(band.minX, band.minY, w, h1), align: .center)
                drawText(ctx, artist, size: max(min(h2 * 0.7, CGFloat(settings.canvasNowPlayingArtistSize)), 6), bold: false,
                         color: secondaryTextColor,
                         in: rect(band.minX, band.minY + h1, w, h2), align: .center)
            }
        case .pomodoro:
            let phaseText: String
            switch pomodoro.effectivePhase {
            case .shortBreak, .longBreak: phaseText = "休息中"
            case .focus: phaseText = "专注中"
            case .paused: phaseText = "已暂停"
            case .idle: phaseText = "未开始"
            }
            let seconds = max(0, Int(ceil(pomodoro.remaining)))
            let time = String(format: "%02d:%02d", seconds / 60, seconds % 60)
            let h1 = max(band.height * 0.5, 10)
            let h2 = max(band.height - h1, 6)
            drawText(ctx, phaseText, size: max(min(h1 * 0.5, 11), 7), bold: false,
                     color: colors.secondaryTextCG,
                     in: rect(band.minX, band.minY, w, h1), align: .center)
            drawText(ctx, time, size: min(band.height * 0.45, 20), bold: true,
                     color: colors.primaryTextCG,
                     in: rect(band.minX, band.minY + h1, w, h2), align: .center)
        case .uptime:
            let text = uptimeText(system.uptime)
            var size = min(band.height * 0.45, 12)
            var tw = measureTextWidth(text, size: size, bold: false)
            if tw > w - 4 {
                size = max(size * (w - 4) / tw, 7)
                tw = measureTextWidth(text, size: size, bold: false)
            }
            drawText(ctx, text, size: size, bold: false, color: colors.primaryTextCG,
                     in: rect(band.minX, band.minY, w, band.height), align: .center)
        case .text:
            let text = customText.isEmpty ? "自定义文字" : customText
            var size = min(band.height * 0.55, 16)
            var tw = measureTextWidth(text, size: size, bold: true)
            if tw > w - 4 {
                size = max(size * (w - 4) / tw, 8)
                tw = measureTextWidth(text, size: size, bold: true)
            }
            drawText(ctx, text, size: size, bold: true, color: colors.accentCG,
                     in: rect(band.minX, band.minY, w, band.height), align: .center)
        case .image:
            // 「叠加」模式：图像作为一个模块铺满当前横带；「背景」模式在 renderCanvas 中已整卡铺底，此处不再重复
            if settings.canvasImageMode == .background && !imageOverlayOnly {
                break
            }
            if isCanvasImageReady(settings.customImagePath), let path = settings.customImagePath {
                drawImageCover(ctx, path: path, into: band)
                strokeRound(ctx, rect(band), radius: 6, color: colors.borderCG, width: 1)
            } else {
                drawText(ctx, "请先在「自定义图片」中选择图片", size: 8, bold: false,
                         color: colors.secondaryTextCG,
                         in: rect(band.minX, band.minY, w, band.height), align: .center)
            }
        case .oracleText:
            drawQuoteBand(ctx, title: "先知", body: rotatingOracleText(now), band: band, colors: colors)
        case .excerptText:
            // 摘录语录不显示「摘录」标题，正文占满整带；轮换池按勾选的分类过滤
            drawQuoteBand(ctx, title: nil,
                          body: rotatingExcerptText(now, categories: settings.excerptQuoteCategories),
                          band: band, colors: colors)
        case .sspai:
            drawSspaiBand(ctx, articles: sspaiArticles, band: band, colors: colors,
                          deviceCanvas: deviceCanvas)
        }
    }

    /// 少数派推荐画板模块：编号 + 标题多行（自适应字号，长标题换行显示而不是截断；
    /// 键盘画板强调色用少数派品牌红橙，墨水屏设备画板统一为最深对比色）
    private static func drawSspaiBand(_ ctx: CGContext, articles: [SspaiArticle],
                                      band: CGRect, colors: ScreenPalette,
                                      deviceCanvas: Bool) {
        let w = band.width
        if articles.isEmpty {
            drawText(ctx, "获取少数派推荐中…", size: 9, bold: false,
                     color: colors.secondaryTextCG,
                     in: rect(band.minX, band.minY, w, band.height), align: .center)
            return
        }
        // 编号强调色：墨水屏设备画板用最深对比色（无品牌色相），键盘画板用品牌红橙
        let brand: CGColor
        if deviceCanvas {
            brand = colors.accentCG
        } else {
            let bgLum = 0.299 * colors.background.0 + 0.587 * colors.background.1 + 0.114 * colors.background.2
            brand = bgLum < 0.5
                ? CGColor(red: 0.98, green: 0.42, blue: 0.28, alpha: 1)
                : CGColor(red: 0.82, green: 0.25, blue: 0.15, alpha: 1)
        }
        // 每行至少 18pt，保证标题有换行空间、小屏幕下可读
        let maxFit = max(Int(band.height / 18), 1)
        let rows = Array(articles.prefix(maxFit))
        let rowH = band.height / CGFloat(rows.count)
        let titleX = band.minX + 20
        let titleW = w - 20 - 8
        for (index, article) in rows.enumerated() {
            let y = band.minY + CGFloat(index) * rowH
            // 自适应字号 + 多行：从大到小尝试，换行后的行数×行高不超过本行高度
            let maxLines = rowH >= 30 ? 3 : 2
            var titleSize = min(rowH * 0.34, 14)
            var lines: [String] = []
            while titleSize >= 6 {
                let wrapped = wrapText(article.title, maxWidth: titleW, size: titleSize)
                if wrapped.count <= maxLines,
                   CGFloat(wrapped.count) * titleSize * 1.3 <= rowH {
                    lines = wrapped
                    break
                }
                titleSize -= 0.5
            }
            if lines.isEmpty {
                lines = Array(wrapText(article.title, maxWidth: titleW, size: 6).prefix(maxLines))
                titleSize = 6
            }
            // 序号与标题首行垂直居中对齐（不随整行高度居中，多行标题时不错位）
            let firstLineH = titleSize * 1.3
            drawText(ctx, "\(index + 1)", size: min(rowH * 0.24, 10), bold: true, color: brand,
                     in: rect(band.minX + 6, y, 12, firstLineH), align: .center)
            let lineH = titleSize * 1.3
            for (li, line) in lines.enumerated() {
                drawText(ctx, line, size: titleSize, bold: false, color: colors.primaryTextCG,
                         in: rect(titleX, y + CGFloat(li) * lineH, titleW, lineH), align: .left)
            }
        }
    }

    /// 语录模块排版：title 非空且横带足够高时先画小标题再画正文；
    /// 正文自适应字号 + 多行（长语录换行显示而不是缩成极小单行）
    private static func drawQuoteBand(_ ctx: CGContext, title: String?, body: String,
                                      band: CGRect, colors: ScreenPalette) {
        let w = band.width
        var bodyTop = band.minY
        var bodyHeight = band.height
        if let title, band.height >= 64 {
            let titleH = max(band.height * 0.18, 12)
            drawText(ctx, title, size: min(titleH * 0.8, 13), bold: true,
                     color: colors.secondaryTextCG,
                     in: rect(band.minX, band.minY, w, titleH), align: .center)
            bodyTop = band.minY + titleH
            bodyHeight = band.height - titleH
        }
        // 自适应字号 + 多行：从大到小尝试，换行后的行数×行高不超过正文区高度
        let maxWidth = w - 8
        let maxLines = bodyHeight >= 60 ? 3 : (bodyHeight >= 36 ? 2 : 1)
        var bodySize = min(bodyHeight * 0.42, 24)
        var lines: [String] = []
        while bodySize >= 8 {
            let wrapped = wrapText(body, maxWidth: maxWidth, size: bodySize)
            if wrapped.count <= maxLines,
               CGFloat(wrapped.count) * bodySize * 1.3 <= bodyHeight {
                lines = wrapped
                break
            }
            bodySize -= 0.5
        }
        if lines.isEmpty {
            lines = Array(wrapText(body, maxWidth: maxWidth, size: 8).prefix(maxLines))
            bodySize = 8
        }
        let lineH = bodyHeight / CGFloat(lines.count)
        for (index, line) in lines.enumerated() {
            drawText(ctx, line, size: bodySize, bold: true, color: colors.primaryTextCG,
                     in: rect(band.minX, bodyTop + lineH * CGFloat(index), w, lineH),
                     align: .center)
        }
    }

    /// 口袋先知语录（每分钟按分钟数轮换一条）
    public static let oracleMessages: [String] = [
        "今日宜专注，忌分心",
        "好运正在路上，保持耐心",
        "专注的此刻，正在塑造未来",
        "答案会在行动中出现",
        "别急着赶路，先看清方向",
        "今天的小坚持，明天的大收获",
        "心之所向，行之所至",
        "深呼吸，把当下做到最好",
        "机会偏爱有准备的人",
        "安静下来，灵感自会浮现",
    ]

    /// 摘录语录按分类整理（可多选勾选；轮换池 = 所选分类的语录合集）
    public static let excerptQuoteCategoryPool: [ExcerptQuoteCategory: [String]] = [
        .famousSayings: [
            "知行合一，止于至善。",
            "千里之行，始于足下。",
            "学而不思则罔，思而不学则殆。",
            "不积跬步，无以至千里。",
            "业精于勤，荒于嬉。",
            "博观而约取，厚积而薄发。",
            "路虽远，行则将至。",
            "知之者不如好之者，好之者不如乐之者。",
            "工欲善其事，必先利其器。",
            "天行健，君子以自强不息。",
            "走自己的路，让别人说去吧。",
            "冬天来了，春天还会远吗？",
            "书籍是人类进步的阶梯。",
            "一个人可以被毁灭，但不能被打败。",
            "世上只有一种真正的英雄主义，那就是认清生活的真相之后依然热爱生活。",
            "天下难事，必作于易；天下大事，必作于细。",
            "勿以恶小而为之，勿以善小而不为。",
            "人的一生应当这样度过：当他回首往事时，不因虚度年华而悔恨，也不因碌碌无为而羞耻。",
            "我只会为我所爱而奋战，我只会热爱我所尊重的，我只会尊重我所了解的。",
        ],
        .movieQuotes: [
            "人生就像一盒巧克力，你永远不知道下一颗是什么味道。",
            "希望是美好的，也许是人间至善，而美好的事物永不消逝。",
            "做人如果没有梦想，那和咸鱼有什么分别？",
            "曾经有一份真挚的爱情摆在我面前，我没有珍惜，等到失去的时候才后悔莫及。",
            "能力越大，责任越大。",
            "昨天是历史，明天是谜团，而今天是天赐的礼物。",
            "我命由我不由天。",
            "有些鸟是注定不会被关在笼子里的，因为它们的每一片羽毛都闪耀着自由的光辉。",
            "爱是唯一可以超越时间与空间的事物。",
            "不要温和地走进那个良夜。",
            "我们曾经仰望星空，思索我们在宇宙中的位置；而现在我们只顾低头，担心我们在尘世间的处境。",
            "牛顿第三定律：要想离开，必须留下点什么。",
            "一旦你为人父母，你就成了孩子未来的幽灵。",
            "墨菲定律并不是说坏事一定会发生，而是说会发生的事总会发生。",
            "既然是做梦，就干脆做大一点。",
            "要么作为英雄而死，要么苟活到目睹自己变成恶棍。",
            "人生总是这么苦么，还是只有童年苦？",
            "不管前方的路有多苦，只要走的方向正确，不管多么崎岖不平，都比站在原地更接近幸福。",
            "如果你有梦想的话，就要去捍卫它。",
            "说好的一辈子，差一年，一个月，一天，一个时辰，都不算一辈子。",
        ],
        .poetry: [
            "长风破浪会有时，直挂云帆济沧海。",
            "会当凌绝顶，一览众山小。",
            "人生自古谁无死，留取丹心照汗青。",
            "海内存知己，天涯若比邻。",
            "山重水复疑无路，柳暗花明又一村。",
            "沉舟侧畔千帆过，病树前头万木春。",
            "天生我材必有用，千金散尽还复来。",
            "问渠那得清如许，为有源头活水来。",
            "少壮不努力，老大徒伤悲。",
            "大鹏一日同风起，扶摇直上九万里。",
            "宝剑锋从磨砺出，梅花香自苦寒来。",
        ],
        .proverbs: [
            "一寸光阴一寸金，寸金难买寸光阴。",
            "冰冻三尺，非一日之寒。",
            "只要功夫深，铁杵磨成针。",
            "良药苦口利于病，忠言逆耳利于行。",
            "世上无难事，只怕有心人。",
            "活到老，学到老。",
            "千里送鹅毛，礼轻情意重。",
            "书山有路勤为径，学海无涯苦作舟。",
            "早起的鸟儿有虫吃。",
            "塞翁失马，焉知非福。",
        ],
    ]

    /// 全部摘录语录（各分类按枚举顺序拼接；兼容旧调用与默认全选池）
    public static var excerptQuotes: [String] {
        ExcerptQuoteCategory.allCases.flatMap { excerptQuoteCategoryPool[$0] ?? [] }
    }

    /// 按所选分类取语录池（勾选为空时回退全部，避免轮换池为空）
    public static func excerptQuotes(in categories: [Int]) -> [String] {
        let selected = Set(categories.compactMap(ExcerptQuoteCategory.init(rawValue:)))
        if selected.isEmpty { return excerptQuotes }
        return ExcerptQuoteCategory.allCases
            .filter { selected.contains($0) }
            .flatMap { excerptQuoteCategoryPool[$0] ?? [] }
    }

    /// 按当前分钟从数组中取一条（确定性：同一分钟内一致，跨分钟轮换）
    public static func rotatingText(_ now: Date, from list: [String]) -> String {
        guard !list.isEmpty else { return "" }
        let minutes = Int(now.timeIntervalSince1970 / 60)
        return list[abs(minutes) % list.count]
    }

    /// 键盘翻页：在卡片列表中按方向取上一张/下一张（循环）；列表为空回退全部卡片模式
    public static func pagedMode(from current: DisplayMode, direction: Int,
                                 modes: [DisplayMode]) -> DisplayMode? {
        let list = modes.isEmpty ? DisplayMode.allCases : modes
        guard !list.isEmpty else { return nil }
        guard let index = list.firstIndex(of: current) else { return list[0] }
        let next = (index + direction + list.count) % list.count
        return list[next]
    }

    public static func rotatingOracleText(_ now: Date) -> String {
        rotatingText(now, from: oracleMessages)
    }

    public static func rotatingExcerptText(_ now: Date) -> String {
        rotatingText(now, from: excerptQuotes)
    }

    /// 按所选分类轮换摘录语录（键盘卡片与摘录画板模块共用）
    public static func rotatingExcerptText(_ now: Date, categories: [Int]) -> String {
        rotatingText(now, from: excerptQuotes(in: categories))
    }

    // MARK: - 口袋先知 / 摘录 独立画板

    /// 口袋先知画板（Rand/0）固定渲染尺寸：200×200 黑白屏
    public static let oracleCanvasSize = 200

    /// 摘录画板（Dot 墨水屏）固定分辨率：296×152 横屏（125 PPI），推送内容与屏幕 1:1 对应
    public static let excerptCanvasWidth = 296
    public static let excerptCanvasHeight = 152

    /// 逐像素灰阶值（0–255，按选定算法）
    public static func oracleGrayValue(_ r: UInt8, _ g: UInt8, _ b: UInt8,
                                       algorithm: OracleGrayAlgorithm) -> UInt8 {
        switch algorithm {
        case .luminosity:
            let weighted = 299 * Int(r) + 587 * Int(g) + 114 * Int(b)
            return UInt8(weighted / 1000)
        case .average:
            let sum = Int(r) + Int(g) + Int(b)
            return UInt8(sum / 3)
        case .lightness:
            let lo = min(r, min(g, b))
            let hi = max(r, max(g, b))
            let mid = Int(lo) + Int(hi)
            return UInt8(mid / 2)
        case .redChannel:
            return r
        case .greenChannel:
            return g
        case .blueChannel:
            return b
        }
    }

    /// 计算图像经「灰阶转换 + 抖动」后的离散灰阶档（0…levelCount-1，0=最黑）。
    /// 抖动算法参考官方墨水屏 ditherKernel：THRESHOLD / NONE / ORDERED(Bayer 4×4) /
    /// FLOYD_STEINBERG / ATKINSON / BURKES / SIERRA2 / STUCKI / JARVIS_JUDICE_NINKE。
    private static func quantizedLevels(from image: CGImage,
                                        algorithm: OracleGrayAlgorithm,
                                        dither: OracleDitherKernel,
                                        levelCount: Int,
                                        width: Int, height: Int) -> [Int] {
        let maxLevel = levelCount - 1
        let pixelCount = width * height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else {
            return [Int](repeating: 0, count: pixelCount)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: pixelCount * 4)
        var grays = [Int](repeating: 0, count: pixelCount)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                grays[y * width + x] = Int(oracleGrayValue(pixels[i], pixels[i + 1], pixels[i + 2],
                                                           algorithm: algorithm))
            }
        }
        var levels = [Int](repeating: 0, count: pixelCount)

        switch dither {
        case .threshold, .none:
            // THRESHOLD（固定 128 阈值）与 NONE（最近档量化）在两级/四级下结果一致
            for i in 0..<grays.count {
                let g = grays[i]
                let q = (g * maxLevel + 127) / 255
                levels[i] = min(maxLevel, q)
            }
        case .ordered:
            // ORDERED：Bayer 4×4 有序抖动
            let bayer: [[Int]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
            for y in 0..<height {
                for x in 0..<width {
                    let g = grays[y * width + x]
                    let scaled = Double(g) * Double(levelCount) / 255.0
                    let base = Int(scaled)
                    let frac = scaled - Double(base)
                    let thresholdValue = (Double(bayer[y % 4][x % 4]) + 0.5) / 16.0
                    levels[y * width + x] = min(maxLevel, base + (frac > thresholdValue ? 1 : 0))
                }
            }
        default:
            // DIFFUSION 系列：误差扩散抖动
            let entries = ditherDiffusionEntries(dither)
            let step = 255.0 / Double(maxLevel)
            var work = [Double](repeating: 0, count: pixelCount)
            for i in 0..<grays.count {
                work[i] = Double(grays[i])
            }
            for y in 0..<height {
                for x in 0..<width {
                    let idx = y * width + x
                    let old = work[idx]
                    var nearest = Int((old / step).rounded())
                    nearest = min(maxLevel, max(0, nearest))
                    levels[idx] = nearest
                    let error = old - Double(nearest) * step
                    for (dx, dy, coeff) in entries {
                        let nx = x + dx
                        let ny = y + dy
                        if nx >= 0 && nx < width && ny >= 0 && ny < height {
                            work[ny * width + nx] += error * coeff
                        }
                    }
                }
            }
        }
        return levels
    }

    /// 官方误差扩散算法的 (dx, dy, 系数) 表
    private static func ditherDiffusionEntries(_ dither: OracleDitherKernel) -> [(Int, Int, Double)] {
        switch dither {
        case .floydSteinberg:
            return [(1, 0, 7.0 / 16), (-1, 1, 3.0 / 16), (0, 1, 5.0 / 16), (1, 1, 1.0 / 16)]
        case .atkinson:
            return [(1, 0, 1.0 / 8), (2, 0, 1.0 / 8), (-1, 1, 1.0 / 8), (0, 1, 1.0 / 8),
                    (1, 1, 1.0 / 8), (2, 1, 1.0 / 8)]
        case .burkes:
            return [(1, 0, 8.0 / 32), (2, 0, 4.0 / 32), (-2, 1, 2.0 / 32), (-1, 1, 4.0 / 32),
                    (0, 1, 8.0 / 32), (1, 1, 4.0 / 32), (2, 1, 2.0 / 32)]
        case .sierra2:
            return [(1, 0, 4.0 / 16), (2, 0, 3.0 / 16), (-2, 1, 1.0 / 16), (-1, 1, 2.0 / 16),
                    (0, 1, 3.0 / 16), (1, 1, 2.0 / 16), (2, 1, 1.0 / 16)]
        case .stucki:
            return [(1, 0, 8.0 / 42), (2, 0, 4.0 / 42), (-2, 1, 2.0 / 42), (-1, 1, 4.0 / 42),
                    (0, 1, 8.0 / 42), (1, 1, 4.0 / 42), (2, 1, 2.0 / 42)]
        case .jarvisJudiceNinke:
            return [(1, 0, 7.0 / 48), (2, 0, 5.0 / 48), (-2, 1, 3.0 / 48), (-1, 1, 5.0 / 48),
                    (0, 1, 7.0 / 48), (1, 1, 5.0 / 48), (2, 1, 3.0 / 48),
                    (-2, 2, 1.0 / 48), (-1, 2, 3.0 / 48), (0, 2, 5.0 / 48),
                    (1, 2, 3.0 / 48), (2, 2, 1.0 / 48)]
        default:
            return []
        }
    }

    /// 把 200×200 图像按灰阶算法、抖动算法与显示模式转换为 Rand/0 帧。
    /// - bw：5000 字节，每字节 8 像素，bit7 为最左，1=白 0=黑
    /// - gray4：10000 字节，每字节 4 像素，最左像素占 bit7-6；00=白 01=浅灰 10=深灰 11=黑
    public static func oracleFrame(from image: CGImage,
                                   algorithm: OracleGrayAlgorithm,
                                   mode: OracleDisplayMode,
                                   dither: OracleDitherKernel = .none) -> Data {
        let size = 200
        let frameBytes = mode == .gray4 ? 10000 : 5000
        let levelCount = mode == .gray4 ? 4 : 2
        let levels = quantizedLevels(from: image, algorithm: algorithm,
                                     dither: dither, levelCount: levelCount,
                                     width: size, height: size)
        var frame = Data(count: frameBytes)
        frame.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let out = raw.bindMemory(to: UInt8.self)
            switch mode {
            case .bw:
                for y in 0..<size {
                    for x in 0..<size {
                        if levels[y * size + x] == 1 {
                            let byteIndex = y * size / 8 + x / 8
                            let bitIndex = 7 - (x % 8)
                            out[byteIndex] |= UInt8(1 << bitIndex)
                        }
                    }
                }
            case .gray4:
                for y in 0..<size {
                    for x in 0..<size {
                        let level = levels[y * size + x]
                        let bits = 3 - level
                        let byteIndex = (y * size + x) / 4
                        let shift = 6 - 2 * (x % 4)
                        out[byteIndex] |= UInt8(bits << shift)
                    }
                }
            }
        }
        return frame
    }

    /// 兼容入口：亮度加权 + 1 位黑白
    public static func oracleBWFrame(from image: CGImage) -> Data {
        oracleFrame(from: image, algorithm: .luminosity, mode: .bw)
    }

    /// 生成与推送效果一致的灰阶预览图（黑白模式为二值，灰阶模式为 4 档量化，含抖动效果）
    public static func oraclePreviewImage(from image: CGImage,
                                          algorithm: OracleGrayAlgorithm,
                                          mode: OracleDisplayMode,
                                          dither: OracleDitherKernel = .none) -> CGImage {
        grayscaleCanvasImage(from: image, algorithm: algorithm, mode: mode, dither: dither,
                             width: 200, height: 200)
    }

    /// 把任意尺寸图像按「灰阶转换 + 抖动 + 量化」渲染为设备灰阶画面
    /// （黑白模式为二值 0/255，灰阶模式为 4 档 0/85/170/255）。摘录画板用 296×152。
    public static func grayscaleCanvasImage(from image: CGImage,
                                            algorithm: OracleGrayAlgorithm,
                                            mode: OracleDisplayMode,
                                            dither: OracleDitherKernel = .none,
                                            width: Int, height: Int) -> CGImage {
        let levelCount = mode == .gray4 ? 4 : 2
        let maxLevel = levelCount - 1
        let levels = quantizedLevels(from: image, algorithm: algorithm,
                                     dither: dither, levelCount: levelCount,
                                     width: width, height: height)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else {
            return image
        }
        let dst = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let level = levels[y * width + x]
                let value = UInt8(level * 255 / maxLevel)
                let i = (y * width + x) * 4
                dst[i] = value
                dst[i + 1] = value
                dst[i + 2] = value
                dst[i + 3] = 255
            }
        }
        return ctx.makeImage() ?? image
    }

    /// 把 Dot 服务端抖动算法映射为本地近似抖动核，用于「处理后」预览与服务端效果对齐。
    /// 服务端 DIFFUSION_ROW/COLUMN/2D 无本地对应，用 Floyd-Steinberg 近似。
    public static func localDitherKernel(for type: DotServerDitherType,
                                         kernel: DotServerDitherKernel) -> OracleDitherKernel {
        switch type {
        case .none: return .none
        case .ordered: return .ordered
        case .diffusion:
            switch kernel {
            case .threshold: return .threshold
            case .atkinson: return .atkinson
            case .burkes: return .burkes
            case .floydSteinberg: return .floydSteinberg
            case .sierra2: return .sierra2
            case .stucki: return .stucki
            case .jarvisJudiceNinke: return .jarvisJudiceNinke
            case .diffusionRow, .diffusionColumn, .diffusion2D: return .floydSteinberg
            }
        }
    }

    private static func placeholderCanvas() -> CGImage {
        guard let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                                  bytesPerRow: 200 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError()
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        return ctx.makeImage()!
    }

    /// 统计类模块（标签 + 百分比 + 进度条）
    private static func drawStatBand(_ ctx: CGContext, band: CGRect, label: String, percent: Double,
                                     accent: CGColor, colors: ScreenPalette) {
        let p = min(max(percent, 0), 100)
        let labelH = max(band.height * 0.5, 10)
        drawText(ctx, label, size: 9, bold: false, color: colors.secondaryTextCG,
                 in: rect(band.minX + 4, band.minY, band.width - 4, labelH), align: .left)
        drawText(ctx, String(format: "%.0f%%", p), size: 12, bold: true, color: colors.primaryTextCG,
                 in: rect(band.minX, band.minY, band.width - 4, labelH), align: .right)
        let barH = min(max(band.height - labelH - 4, 3), 6)
        drawProgress(ctx, rect(band.minX + 4, band.minY + labelH, band.width - 8, barH),
                     progress: p / 100, accent: accent, background: colors.borderCG)
    }

    /// 额度类模块（标签 + 自定义数值文本 + 剩余进度条）
    private static func drawQuotaBand(_ ctx: CGContext, band: CGRect, label: String, value: String,
                                      progress: Double, accent: CGColor, colors: ScreenPalette) {
        let p = min(max(progress, 0), 1)
        let labelH = max(band.height * 0.5, 10)
        drawText(ctx, label, size: 9, bold: false, color: colors.secondaryTextCG,
                 in: rect(band.minX + 4, band.minY, band.width - 4, labelH), align: .left)
        var size: CGFloat = 12
        var tw = measureTextWidth(value, size: size, bold: true)
        let maxValueWidth = band.width * 0.55
        if tw > maxValueWidth {
            size = max(size * maxValueWidth / tw, 7)
            tw = measureTextWidth(value, size: size, bold: true)
        }
        drawText(ctx, value, size: size, bold: true, color: colors.primaryTextCG,
                 in: rect(band.minX, band.minY, band.width - 4, labelH), align: .right)
        let barH = min(max(band.height - labelH - 4, 3), 6)
        drawProgress(ctx, rect(band.minX + 4, band.minY + labelH, band.width - 8, barH),
                     progress: p, accent: accent, background: colors.borderCG)
    }

    public static func renderCustomImage(path: String, settings: AppSettings,
                                         now: Date = Date()) throws -> RenderResult {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RenderError.cannotDecodeImage
        }
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        // 背景铺黑，内容区从顶部安全区下方开始
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let target = rect(0, CGFloat(safe), CGFloat(width), CGFloat(height) - CGFloat(safe))
        let sourceRatio = CGFloat(original.width) / CGFloat(original.height)
        let targetRatio = target.width / target.height
        let crop: CGRect
        if sourceRatio > targetRatio {
            let cropWidth = CGFloat(original.height) * targetRatio
            crop = CGRect(x: (CGFloat(original.width) - cropWidth) / 2, y: 0,
                          width: cropWidth, height: CGFloat(original.height))
        } else {
            let cropHeight = CGFloat(original.width) / targetRatio
            crop = CGRect(x: 0, y: (CGFloat(original.height) - cropHeight) / 2,
                          width: CGFloat(original.width), height: cropHeight)
        }
        guard let cropped = original.cropping(to: crop) else { throw RenderError.cannotDecodeImage }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: target)
        drawClockOverlay(ctx, overlay: settings.customImageClock, safeArea: safe, now: now,
                         fontSize: CGFloat(settings.clockFontSize),
                         timeFormat: settings.clockTimeFormat,
                         fontName: settings.clockFontWeight.fontName,
                         colors: settings.resolvedPalette)
        return try encode(ctx, quality: settings.jpegQuality)
    }

    // MARK: - 自定义图片时钟叠加

    /// 叠加文字色（无背景遮罩，靠轻量投影保证可读性）
    private static var overlayText: CGColor { CGColor(red: 1, green: 1, blue: 1, alpha: 1) }
    private static var overlayTextDim: CGColor { CGColor(red: 1, green: 1, blue: 1, alpha: 0.75) }

    /// 在自定义图片上叠加时钟（跟随系统时间；无背景遮罩，字号/格式/字重可自定义）
    private static func drawClockOverlay(_ ctx: CGContext, overlay: CustomImageClockOverlay,
                                         safeArea: CGFloat, now: Date,
                                         fontSize: CGFloat, timeFormat: String,
                                         fontName: String,
                                         colors: ScreenPalette) {
        guard overlay != .none else { return }
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.weekday, .day, .month], from: now)
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekdayIndex = min(max((comps.weekday ?? 1) - 1, 0), 6)
        let dateText = "\(comps.month ?? 0)月\(comps.day ?? 0)日 \(weekdays[weekdayIndex])"
        let timeText = clockTimeText(now, format: timeFormat)
        let timeSize = max(min(fontSize, 56), 12)

        switch overlay {
        case .none:
            return
        case .horizontalTop, .horizontalBottom:
            // 横向：细体大字号时间 + 小字日期（Google Pixel 锁屏时钟风格）；过宽时按比例收缩
            var size = timeSize
            var tw = measureTextWidth(timeText, fontName: fontName, size: size)
            let maxWidth = CGFloat(width) - 12
            if tw > maxWidth {
                size = max(size * maxWidth / tw, 12)
                tw = measureTextWidth(timeText, fontName: fontName, size: size)
            }
            let timeH = size * 1.22
            let timeY = overlay == .horizontalTop
                ? safeArea + 14
                : CGFloat(height) - 14 - timeH
            let tx = (CGFloat(width) - tw) / 2
            let dateSize = max(6, size * 0.24)
            let dateY = overlay == .horizontalTop ? timeY + timeH + 4 : timeY - dateSize - 6
            drawTextShadowed(ctx, dateText, size: dateSize, bold: false, color: overlayTextDim,
                             in: rect(0, dateY, CGFloat(width), dateSize + 5), align: .center)
            drawTextShadowed(ctx, timeText, size: size, bold: false, color: overlayText,
                             in: rect(tx, timeY, tw, timeH), align: .left,
                             fontName: fontName)
        case .verticalLeft, .verticalCenter:
            // 竖向：第一行小时、第二行分钟，每行的两位数字横向排布（Pixel 细体）；
            // 小时为白色、分钟为强调色
            let parts = timeText.split(separator: ":").map(String.init)
            var hoursText = ""
            var minutesText = ""
            if parts.count >= 2 {
                hoursText = parts[0]
                minutesText = parts[1]
            } else {
                let digits = timeText.filter { $0.isNumber }
                hoursText = String(digits.prefix(2))
                minutesText = String(digits.dropFirst(2).prefix(2))
            }
            let glyphSize = max(timeSize * 0.78, 12)
            let rowH = glyphSize * 1.25
            let startY = safeArea + 16
            func drawRow(_ text: String, y: CGFloat, color: CGColor) {
                let rowW = max(measureTextWidth(text, fontName: fontName, size: glyphSize),
                               glyphSize)
                let rowX: CGFloat = overlay == .verticalLeft
                    ? 10
                    : (CGFloat(width) - rowW) / 2
                drawTextShadowed(ctx, text, size: glyphSize, bold: false, color: color,
                                 in: rect(rowX, y, rowW, rowH), align: .left,
                                 fontName: fontName)
            }
            drawRow(hoursText, y: startY, color: overlayText)
            drawRow(minutesText, y: startY + rowH, color: colors.accentCG)
        }
    }

    /// 按用户格式输出时间；格式无效/输出为空时回退 HH:mm
    private static func clockTimeText(_ now: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        let text = formatter.string(from: now)
        guard !text.isEmpty else {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: now)
        }
        return text
    }

    /// 带轻量投影的文字（CG 坐标矩形；投影向右下偏 1px，提升任意底图上的可读性）
    private static func drawTextShadowed(_ ctx: CGContext, _ text: String, size: CGFloat, bold: Bool,
                                         color: CGColor, in boundsCG: CGRect, align: NSTextAlignment,
                                         fontName: String? = nil) {
        let shadowColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        let shadow = CGRect(x: boundsCG.origin.x + 0.9, y: boundsCG.origin.y - 0.9,
                            width: boundsCG.width, height: boundsCG.height)
        drawText(ctx, text, size: size, bold: bold, color: shadowColor, in: shadow, align: align,
                 fontName: fontName)
        drawText(ctx, text, size: size, bold: bold, color: color, in: boundsCG, align: align,
                 fontName: fontName)
    }

    public static func renderQwenWork(_ quota: QwenWorkQuota, settings: AppSettings,
                                      now: Date = Date()) throws -> RenderResult {
        let colors = settings.resolvedPalette
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let c = drawCanvas(ctx, safeArea: safe, colors: colors)

        drawHeader(ctx, card: c, title: "QWENWORK", badge: "实时",
                   accent: colors.accentCG, colors: colors, titleSize: 7.5)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)

        let top = c.minY + 49
        drawText(ctx, "剩余额度", size: 10, bold: true, color: colors.secondaryTextCG,
                 in: rect(c.minX + 9, top, c.maxX - c.minX - 18, 18), align: .center)
        let numberText = quota.remainingCredits >= 100
            ? String(format: "%.0f", quota.remainingCredits)
            : String(format: "%.1f", quota.remainingCredits)
        drawText(ctx, numberText, size: 30, bold: true, color: colors.primaryTextCG,
                 in: rect(c.minX + 5, top + 16, c.maxX - c.minX - 10, 62), align: .center)
        drawText(ctx, quota.unit.isEmpty ? "credits" : quota.unit, size: 8, bold: true,
                 color: colors.accentCG,
                 in: rect(c.minX + 5, top + 80, c.maxX - c.minX - 10, 16), align: .center)
        drawProgress(ctx, rect(c.minX + 12, top + 100, c.maxX - c.minX - 24, 8),
                     progress: quota.progress, accent: colors.accentCG, background: colors.borderCG)
        // 剩余百分比：以手动捕获的基线为 100%（未设置基线时提示）
        if let tracked = quota.trackedProgress {
            let percent = Int((tracked * 100).rounded())
            drawText(ctx, "剩余 \(percent)%", size: 13, bold: true, color: colors.accentCG,
                     in: rect(c.minX + 9, top + 110, c.maxX - c.minX - 18, 20), align: .center)
        } else {
            drawText(ctx, "剩余 —%（未设基线）", size: 10, bold: true, color: colors.accentCG,
                     in: rect(c.minX + 9, top + 111, c.maxX - c.minX - 18, 18), align: .center)
        }
        let planText: String
        if let plan = quota.plan, !plan.isEmpty {
            planText = "\(plan) 额度"
        } else {
            planText = "套餐额度"
        }
        drawText(ctx, planText, size: 8, bold: false, color: colors.tertiaryTextCG,
                 in: rect(c.minX + 9, top + 130, c.maxX - c.minX - 18, 14), align: .center)

        // “最后刷新”移至计划文本下方填充中部空间
        drawText(ctx, "最后刷新 \(formatDate(quota.sampledAt, "HH:mm:ss"))", size: 8, bold: false,
                 color: colors.tertiaryTextCG,
                 in: rect(c.minX + 7, top + 144, c.maxX - c.minX - 14, 14), align: .center)

        let bottom = c.maxY - 15
        drawText(ctx, "当前时间", size: 9, bold: true, color: colors.tertiaryTextCG,
                 in: rect(c.minX + 9, bottom - 76, c.maxX - c.minX - 18, 17), align: .center)
        drawText(ctx, formatDate(now, "M月d日"), size: 17, bold: true, color: colors.primaryTextCG,
                 in: rect(c.minX + 5, bottom - 57, c.maxX - c.minX - 10, 24), align: .center)
        drawText(ctx, formatDate(now, "HH:mm"), size: 22, bold: true, color: colors.accentCG,
                 in: rect(c.minX + 5, bottom - 32, c.maxX - c.minX - 10, 32), align: .center)

        return try encode(ctx, quality: settings.jpegQuality)
    }

    public static func renderNowPlaying(_ info: NowPlayingInfo, settings: AppSettings,
                                        artworkImage: CGImage? = nil,
                                        now: Date = Date()) throws -> RenderResult {
        let artImage = artworkImage ?? (info.artwork.flatMap { decodeArtwork($0) })
        // 有封面时从封面取主色作为卡片背景；无封面回退主题配色
        let colors: ScreenPalette
        if let artImage {
            let dominant = dominantColor(of: artImage)
            colors = artworkPalette(baseColor: dominant,
                                    themeAccent: settings.resolvedPalette.accent)
        } else {
            colors = settings.resolvedPalette
        }
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let c = drawCanvas(ctx, safeArea: safe, colors: colors)

        let accent = colors.accentCG
        // 封面几何：页脚可见时贴顶；隐藏页脚时在「头部下方 ～ 信息区上方」的可用空间内垂直居中
        // （考虑文字与进度条占用空间，而不是整卡中心）
        let top = c.minY + 49
        let footerVisible = settings.nowPlayingFooterVisible
        let infoTop = footerVisible ? (top + 100) : (c.maxY - 15 - 70)
        let artSize: CGFloat = 92
        let artX = (c.minX + c.maxX) / 2 - artSize / 2
        let artY: CGFloat = footerVisible ? top : top + (infoTop - top - artSize) / 2
        let artSkia = CGRect(x: artX, y: artY, width: artSize, height: artSize)
        let artRect = rect(artSkia)

        // 封面主色光晕（画在最底层，头部文字与封面都叠在其上）：
        // 暗色封面提亮后，用单次高斯模糊生成平滑径向光晕——无分层色带，JPEG 压缩后依然干净
        if let artImage {
            drawCoverGlow(ctx, color: boostedGlowColor(dominantColor(of: artImage)),
                          coverSkia: artSkia)
        }

        drawHeader(ctx, card: c, title: "NOW PLAYING", badge: info.isPlaying ? "PLAYING" : "PAUSED",
                   accent: accent, colors: colors, titleSize: 7.5)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)

        if let artImage {
            // 封面本体
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: artRect, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.clip()
            ctx.interpolationQuality = .high
            ctx.draw(artImage, in: artRect)
            ctx.restoreGState()
            strokeRound(ctx, artRect, radius: 10, color: colors.borderCG, width: 1)
        } else {
            fillRound(ctx, artRect, radius: 10, color: colors.insetCG)
            strokeRound(ctx, artRect, radius: 10, color: colors.borderCG, width: 1)
            drawText(ctx, "♪", size: 42, bold: false, color: accent,
                     in: artRect, align: .center)
        }

        // 歌名/歌手/进度条/播放时间信息区：默认在封面下方；
        // 隐藏底部时间/日期时整块贴底（保留底部安全区）
        let title = info.title.isEmpty ? "未在播放" : info.title
        // 歌名自适应：字号从设置值向下收缩直到放进可用宽度，仍放不下才截断
        drawAdaptiveText(ctx, title, maxSize: CGFloat(settings.nowPlayingTitleSize), minSize: 5.5,
                         bold: true, color: colors.primaryTextCG,
                         in: rect(c.minX + 10, infoTop, c.maxX - c.minX - 20, 18), align: .center)
        let subtitle: String
        if !info.artist.isEmpty && !info.album.isEmpty {
            subtitle = "\(info.artist) · \(info.album)"
        } else if !info.artist.isEmpty {
            subtitle = info.artist
        } else if !info.album.isEmpty {
            subtitle = info.album
        } else {
            subtitle = "未知来源"
        }
        // 歌手/专辑信息自适应：字号从设置值收缩，超宽时缩小而不截断
        drawAdaptiveText(ctx, subtitle, maxSize: CGFloat(settings.nowPlayingArtistSize), minSize: 5.5,
                         bold: false, color: colors.secondaryTextCG,
                         in: rect(c.minX + 10, infoTop + 20, c.maxX - c.minX - 20, 14), align: .center)
        drawProgress(ctx, rect(c.minX + 14, infoTop + 42, c.maxX - c.minX - 28, 6),
                     progress: info.progress, accent: accent, background: colors.borderCG)
        let timeText = "\(formatClock(info.elapsedTime)) / \(formatClock(info.duration))"
        drawText(ctx, timeText, size: 8, bold: false, color: colors.secondaryTextCG,
                 in: rect(c.minX + 10, infoTop + 52, c.maxX - c.minX - 20, 14), align: .center)

        // 页脚：当前时间（上：时钟，下：日期）；格式与字号可自定义，也可整体隐藏。
        // 各带高度随字号自适应，字号调小后行距同步收紧释放空间
        if footerVisible {
            drawFooterClock(ctx, card: c, settings: settings, colors: colors, now: now, accent: accent)
        }

        return try encode(ctx, quality: settings.jpegQuality)
    }

    /// 封面光晕主色：暗色封面按 0.4/luminance 比例提亮（保色相、不超白），保证深色封面的光晕可见
    private static func boostedGlowColor(_ rgb: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
        let lum = 0.299 * rgb.0 + 0.587 * rgb.1 + 0.114 * rgb.2
        guard lum < 0.4, lum > 0.01 else { return rgb }
        let factor = min(0.4 / lum, 4)
        return (min(rgb.0 * factor, 1), min(rgb.1 * factor, 1), min(rgb.2 * factor, 1))
    }

    /// 复用的 Core Image 上下文（创建开销大，进程内共享）
    private static let glowCIContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// 封面光晕：单次高斯模糊生成平滑径向光晕（无分层色带，JPEG 压缩后依然干净）。
    /// 在离屏小画布画实心圆角矩形（略小于封面、全不透明），模糊后以封面为中心画回主画布。
    private static func drawCoverGlow(_ ctx: CGContext, color: (CGFloat, CGFloat, CGFloat),
                                      coverSkia: CGRect) {
        let extent: CGFloat = 70
        let size = Int(coverSkia.width + extent * 2)
        guard size > 0,
              let glowSrc = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let inner = CGRect(x: extent + 5, y: extent + 5,
                           width: coverSkia.width - 10, height: coverSkia.height - 10)
        glowSrc.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        glowSrc.addPath(CGPath(roundedRect: inner, cornerWidth: 16, cornerHeight: 16, transform: nil))
        glowSrc.fillPath()
        guard let srcImage = glowSrc.makeImage() else { return }
        // 高斯模糊：σ=24，覆盖 extent 范围外仍有柔和衰减
        let blurred = CIImage(cgImage: srcImage).applyingGaussianBlur(sigma: 24)
        let crop = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
        guard let outImage = glowCIContext.createCGImage(blurred, from: crop) else { return }
        let dest = rect(coverSkia.insetBy(dx: -extent, dy: -extent))
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(outImage, in: dest)
        ctx.restoreGState()
    }

    /// 页脚时钟：当前时间（上：时钟，下：日期），格式/字号随设置、可整体隐藏
    private static func drawFooterClock(_ ctx: CGContext, card c: CGRect, settings: AppSettings,
                                        colors: ScreenPalette, now: Date, accent: CGColor) {
        let bottom = c.maxY - 15
        let dateHeight = max(CGFloat(settings.nowPlayingDateSize) + 8, 18)
        let timeHeight = max(CGFloat(settings.nowPlayingTimeSize) + 10, 24)
        let labelTop = bottom - dateHeight - timeHeight - 16
        drawText(ctx, "当前时间", size: 9, bold: true, color: colors.tertiaryTextCG,
                 in: rect(c.minX + 9, labelTop, c.maxX - c.minX - 18, 16), align: .center)
        drawText(ctx, formatDate(now, settings.nowPlayingTimeFormat), size: CGFloat(settings.nowPlayingTimeSize),
                 bold: true, color: accent,
                 in: rect(c.minX + 5, bottom - dateHeight - timeHeight, c.maxX - c.minX - 10, timeHeight), align: .center)
        drawText(ctx, formatDate(now, settings.nowPlayingDateFormat), size: CGFloat(settings.nowPlayingDateSize),
                 bold: true, color: colors.primaryTextCG,
                 in: rect(c.minX + 5, bottom - dateHeight, c.maxX - c.minX - 10, dateHeight), align: .center)
    }

    /// 摘录语录键盘卡片：每分钟轮换一条语录（可手动指定语录），
    /// 竖向排布（字符自上而下成列、列自右向左），充分利用屏幕纵向空间，
    /// 字号自适应保证整段完整显示、不做省略截断；下方页脚时间日期
    public static func renderExcerptQuote(quote: String? = nil, settings: AppSettings,
                                          now: Date = Date()) throws -> RenderResult {
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let colors = settings.resolvedPalette
        let c = drawCanvas(ctx, safeArea: safe, colors: colors)
        let accent = colors.accentCG
        drawHeader(ctx, card: c, title: "QUOTE", badge: "语录",
                   accent: accent, colors: colors, titleSize: 7.5)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)

        let quote = quote ?? rotatingExcerptText(now)
        let top = c.minY + 49
        let bottom = c.maxY - 15
        let footerVisible = settings.nowPlayingFooterVisible
        let footerReserve: CGFloat = footerVisible ? 70 : 20
        let region = CGRect(x: c.minX + 10, y: top,
                            width: c.maxX - c.minX - 20,
                            height: bottom - top - footerReserve)

        // 竖排标点：角标点画在单元格右上、成对括号旋转 90°（顺时钟）
        let cornerPunct: Set<Character> = ["，", "。", "、", "；", "：", "！", "？", "…", "—", ",", ".", "!", "?", ":", ";"]
        let rotatePunct: Set<Character> = ["“", "”", "「", "」", "『", "』", "（", "）", "【", "】", "《", "》", "(", ")"]

        // 选字号：从大到小尝试，使竖排列数能放入区域；缩到 7pt 兜底（真实语录远小于容量）
        var chosenSize: CGFloat = 22
        var chosenCols: [String] = []
        for size in stride(from: 24.0, through: 7.0, by: -1) {
            let perCol = max(Int(region.height / (size * 1.38)), 1)
            let maxCols = max(Int(region.width / (size * 1.18)), 1)
            let cols = wrapVertical(quote, maxChars: perCol)
            if cols.count <= maxCols || size <= 7 {
                chosenSize = size
                chosenCols = cols
                break
            }
        }
        let cellH = chosenSize * 1.38
        let colW = region.width / CGFloat(max(chosenCols.count, 1))
        for (colIndex, col) in chosenCols.enumerated() {
            // 列自右向左：第 0 列在最右
            let x = region.maxX - (CGFloat(colIndex) + 1) * colW
            for (rowIndex, ch) in Array(col).enumerated() {
                let y = region.minY + CGFloat(rowIndex) * cellH
                if cornerPunct.contains(ch) {
                    drawText(ctx, String(ch), size: chosenSize * 0.88, bold: true, color: colors.primaryTextCG,
                             in: rect(x + colW * 0.06, y, colW * 0.94, cellH * 0.82), align: .right)
                } else if rotatePunct.contains(ch) {
                    let cell = rect(x, y, colW, cellH)
                    ctx.saveGState()
                    ctx.translateBy(x: cell.midX, y: cell.midY)
                    ctx.rotate(by: -CGFloat.pi / 2)
                    ctx.translateBy(x: -cell.midX, y: -cell.midY)
                    drawText(ctx, String(ch), size: chosenSize * 0.92, bold: true, color: colors.primaryTextCG,
                             in: cell, align: .center)
                    ctx.restoreGState()
                } else {
                    drawText(ctx, String(ch), size: chosenSize, bold: true, color: colors.primaryTextCG,
                             in: rect(x, y, colW, cellH), align: .center)
                }
            }
        }

        if footerVisible {
            drawFooterClock(ctx, card: c, settings: settings, colors: colors, now: now, accent: accent)
        }
        return try encode(ctx, quality: settings.jpegQuality)
    }

    /// 按字符贪心换行：每行不超过 maxWidth；避免标点单独成行或落到行首
    /// （断行时若当前字符或下一字符是后置标点，则并入本行，允许轻微超宽）
    public static func wrapText(_ text: String, maxWidth: CGFloat, size: CGFloat, bold: Bool = true) -> [String] {
        let chars = Array(text)
        let punct: Set<Character> = ["，", "。", "、", "；", "：", "！", "？", "”", "』", "）", "…", "—", ",", ".", "!", "?", ")", "]"]
        var lines: [String] = []
        var current = ""
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            let candidate = current + String(ch)
            if measureTextWidth(candidate, size: size, bold: bold) > maxWidth, !current.isEmpty {
                if punct.contains(ch) {
                    // 当前字符是后置标点：留在行尾，避免新行以标点开头
                    current = candidate
                } else if index + 1 < chars.count, punct.contains(chars[index + 1]) {
                    // 下一字符是标点：一并并入本行，避免标点单独成行
                    current = current + String(ch) + String(chars[index + 1])
                    index += 2
                    continue
                } else {
                    lines.append(current)
                    current = String(ch)
                }
            } else {
                current = candidate
            }
            index += 1
        }
        if !current.isEmpty { lines.append(current) }
        // 兜底：把仅含一个标点的行并入上一行
        var merged: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isLonePunct = trimmed.count == 1 && punct.contains(trimmed.first ?? " ")
            if isLonePunct, !merged.isEmpty {
                merged[merged.count - 1] += line
            } else {
                merged.append(line)
            }
        }
        return merged.isEmpty ? [text] : merged
    }

    /// 竖向排布拆列：把文本拆成自上而下的列，每列最多 maxChars 字。
    /// 遵循竖排标点规则：后置标点不置于列首（并入上一列末尾，允许超出一字）、
    /// 开括号不置于列尾；兜底合并单标点列，避免孤立标点列。
    public static func wrapVertical(_ text: String, maxChars: Int) -> [String] {
        let chars = Array(text)
        let closing: Set<Character> = ["，", "。", "、", "；", "：", "！", "？", "”", "』", "）", "…", "—", ",", ".", "!", "?", ")", "]"]
        let opening: Set<Character> = ["“", "「", "『", "（", "【", "《", "(", "["]
        guard maxChars > 0, !chars.isEmpty else { return [text] }
        var columns: [String] = []
        var current = ""
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if current.count >= maxChars {
                if let last = current.last, opening.contains(last) {
                    // 开括号不置于列尾：闭列后由开括号开启新列
                    current.removeLast()
                    columns.append(current)
                    current = String(last)
                } else {
                    columns.append(current)
                    current = ""
                }
            }
            if current.isEmpty, closing.contains(ch), !columns.isEmpty {
                // 后置标点不置于列首：并入上一列末尾
                columns[columns.count - 1] += String(ch)
                index += 1
                continue
            }
            current += String(ch)
            index += 1
        }
        if !current.isEmpty { columns.append(current) }
        // 兜底：把仅含一个标点的列并入上一列
        var merged: [String] = []
        for col in columns {
            let trimmed = col.trimmingCharacters(in: .whitespaces)
            let isLonePunct = trimmed.count == 1 && closing.contains(trimmed.first ?? " ")
            if isLonePunct, !merged.isEmpty {
                merged[merged.count - 1] += col
            } else {
                merged.append(col)
            }
        }
        return merged.isEmpty ? [text] : merged
    }

    /// 少数派推荐键盘卡片：文章垂直排布（标题+作者竖排），强调色用少数派主色调（红橙），
    /// 底色跟随全局浅色/深色模式；显示前 4 篇 + 页脚时间
    public static func renderSspai(articles: [SspaiArticle], settings: AppSettings,
                                   now: Date = Date()) throws -> RenderResult {
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let base = settings.resolvedPalette
        // 少数派主色调（红橙）作为强调色；按底色明暗选亮/深一档保证可见
        let bgLum = 0.299 * base.background.0 + 0.587 * base.background.1 + 0.114 * base.background.2
        let brand: (CGFloat, CGFloat, CGFloat) = bgLum < 0.5 ? (0.98, 0.42, 0.28) : (0.82, 0.25, 0.15)
        var colors = base
        colors.accent = brand
        colors.secondaryAccent = brand
        let c = drawCanvas(ctx, safeArea: safe, colors: colors)
        let accent = colors.accentCG
        drawHeader(ctx, card: c, title: "SSPAI", badge: "推荐",
                   accent: accent, colors: colors, titleSize: 7.5)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)

        let top = c.minY + 46
        let bottom = c.maxY - 15
        let footerVisible = settings.nowPlayingFooterVisible
        let footerReserve: CGFloat = footerVisible ? 70 : 16
        let region = CGRect(x: c.minX + 8, y: top + 2,
                            width: c.maxX - c.minX - 16,
                            height: bottom - (top + 2) - footerReserve)

        if articles.isEmpty {
            drawText(ctx, "正在获取少数派推荐文章…", size: 9, bold: false,
                     color: colors.secondaryTextCG,
                     in: rect(c.minX + 8, region.minY, c.maxX - c.minX - 16, 20), align: .center)
        } else {
            let shown = Array(articles.prefix(3))
            let rowH = region.height / CGFloat(shown.count)
            for (index, article) in shown.enumerated() {
                let y = region.minY + rowH * CGFloat(index)
                let titleX = c.minX + 20
                let titleW = region.width - 16
                // 标题自适应字号 + 多行：预留作者行，标题换行后整体不超出行高
                let authorSize: CGFloat = article.author.isEmpty ? 0 : max(min(rowH * 0.22, 9), 7)
                let authorH: CGFloat = article.author.isEmpty ? 0 : authorSize + 4
                let titleSpace = max(rowH - authorH, 10)
                let maxLines = titleSpace >= 34 ? 3 : 2
                var titleSize = min(rowH * 0.42, 20)
                var lines: [String] = []
                while titleSize >= 8 {
                    let wrapped = wrapText(article.title, maxWidth: titleW, size: titleSize)
                    if wrapped.count <= maxLines,
                       CGFloat(wrapped.count) * titleSize * 1.3 <= titleSpace {
                        lines = wrapped
                        break
                    }
                    titleSize -= 0.5
                }
                if lines.isEmpty {
                    lines = Array(wrapText(article.title, maxWidth: titleW, size: 8).prefix(maxLines))
                    titleSize = 8
                }
                // 序号与标题首行垂直居中对齐（不随整行高度居中，多行标题时不错位）
                let firstLineH = titleSize * 1.3
                drawText(ctx, "\(index + 1)", size: min(rowH * 0.24, 11), bold: true, color: accent,
                         in: rect(c.minX + 6, y, 12, firstLineH), align: .center)
                let titleH = CGFloat(lines.count) * titleSize * 1.3
                for (li, line) in lines.enumerated() {
                    drawText(ctx, line, size: titleSize, bold: false, color: colors.primaryTextCG,
                             in: rect(titleX, y + CGFloat(li) * titleSize * 1.25, titleW, titleSize * 1.3),
                             align: .left)
                }
                if !article.author.isEmpty {
                    drawText(ctx, article.author, size: authorSize, bold: false,
                             color: colors.tertiaryTextCG,
                             in: rect(titleX, y + titleH + 2, titleW, max(rowH - titleH - 2, 8)), align: .left)
                }
            }
        }

        if footerVisible {
            drawFooterClock(ctx, card: c, settings: settings, colors: colors, now: now, accent: accent)
        }
        return try encode(ctx, quality: settings.jpegQuality)
    }

    /// Emoji 壁纸键盘卡片：用户提供的 emoji 全屏铺满（iOS 锁屏壁纸风格），
    /// 支持多种排列方式与字号调节；排列确定性由表情串+字号+布局种子决定，保证多次渲染一致
    public static func renderEmojiWallpaper(settings: AppSettings,
                                            now: Date = Date()) throws -> RenderResult {
        let ctx = createContext()
        let colors = settings.resolvedPalette
        ctx.setFillColor(colors.backgroundCG)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let emojis = Array(settings.emojiWallpaperText)
        if emojis.isEmpty {
            drawText(ctx, "在设置中输入 emoji", size: 10, bold: false,
                     color: colors.secondaryTextCG,
                     in: rect(0, CGFloat(height) / 2 - 10, CGFloat(width), 20), align: .center)
        } else {
            let baseSize = CGFloat(min(max(settings.emojiWallpaperSize, 16), 96))
            let spacing = CGFloat(min(max(settings.emojiWallpaperSpacing, 0), 40))
            switch settings.emojiWallpaperLayout {
            case .mixedSize:
                drawEmojiMixedSize(ctx, emojis: emojis, baseSize: baseSize, spacing: spacing)
            case .grid:
                drawEmojiGrid(ctx, emojis: emojis, baseSize: baseSize, spacing: spacing)
            case .spiral:
                drawEmojiSpiral(ctx, emojis: emojis, baseSize: baseSize, spacing: spacing)
            }
        }

        // 页脚时钟（复用「正在播放」的底部时间/日期开关）；底部叠半透明带保证时间可读
        if settings.nowPlayingFooterVisible {
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.32))
            ctx.fill(rect(0, CGFloat(height) - 96, CGFloat(width), 96))
            drawFooterClock(ctx, card: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                            settings: settings, colors: colors, now: now, accent: colors.accentCG)
        }
        return try encode(ctx, quality: settings.jpegQuality)
    }

    // MARK: - Emoji 壁纸布局（居中排列、间隔可调；均为确定性纯数学排布，多次渲染一致）

    /// 在 (cx, cy)（Skia 坐标，中心点）绘制一个 emoji，尺寸 size
    private static func drawEmojiGlyph(_ ctx: CGContext, _ ch: Character, size: CGFloat,
                                       center: CGPoint) {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: String(ch), attributes: [.font: font]))
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let glyphW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        // Skia 语义：把字形盒（宽 glyphW、高 ascent+descent）中心对齐到 (cx, cy)
        let box = rect(center.x - glyphW / 2, center.y - (ascent + descent) / 2, glyphW, ascent + descent)
        let baselineY = box.midY - (ascent - descent) / 2
        ctx.textPosition = CGPoint(x: box.midX - glyphW / 2, y: baselineY)
        CTLineDraw(line, ctx)
    }

    /// 网格排列：以屏幕中心为原点向外铺满的整齐网格，允许表情溢出边缘（超出部分裁切），间隔可调
    private static func drawEmojiGrid(_ ctx: CGContext, emojis: [Character],
                                      baseSize: CGFloat, spacing: CGFloat) {
        let step = baseSize + spacing
        let w = CGFloat(width)
        let h = CGFloat(height)
        let cx = w / 2
        let cy = h / 2
        // 从中心向外铺开，多留一圈让边缘表情溢出屏幕、铺满无空隙（由画布裁切）
        let colsHalf = Int(w / step / 2) + 1
        let rowsHalf = Int(h / step / 2) + 1
        var index = 0
        for r in -rowsHalf...rowsHalf {
            for c in -colsHalf...colsHalf {
                drawEmojiGlyph(ctx, emojis[index % emojis.count], size: baseSize * 0.9,
                               center: CGPoint(x: cx + CGFloat(c) * step,
                                               y: cy + CGFloat(r) * step))
                index += 1
            }
        }
    }

    /// 大小混合：以屏幕中心为原点向外铺开，按棋盘格规律交替放大/缩小（规律性放大）；溢出边缘裁切
    private static func drawEmojiMixedSize(_ ctx: CGContext, emojis: [Character],
                                           baseSize: CGFloat, spacing: CGFloat) {
        let step = baseSize + spacing
        let w = CGFloat(width)
        let h = CGFloat(height)
        let cx = w / 2
        let cy = h / 2
        let colsHalf = Int(w / step / 2) + 1
        let rowsHalf = Int(h / step / 2) + 1
        let largeSize = baseSize * 1.35
        let smallSize = baseSize * 0.8
        var index = 0
        for r in -rowsHalf...rowsHalf {
            for c in -colsHalf...colsHalf {
                let isLarge = (r + c) % 2 == 0
                drawEmojiGlyph(ctx, emojis[index % emojis.count],
                               size: isLarge ? largeSize : smallSize,
                               center: CGPoint(x: cx + CGFloat(c) * step,
                                               y: cy + CGFloat(r) * step))
                index += 1
            }
        }
    }

    /// 螺旋：从屏幕中心向外呈漩涡状排布，中间小、越靠边缘越大，间隔影响疏密
    private static func drawEmojiSpiral(_ ctx: CGContext, emojis: [Character],
                                        baseSize: CGFloat, spacing: CGFloat) {
        let w = CGFloat(width)
        let h = CGFloat(height)
        let cx = w / 2
        let cy = h / 2
        let halfW = w / 2
        let halfH = h / 2
        let maxR: CGFloat = (halfW * halfW + halfH * halfH).squareRoot()
        // 加大中心与边缘的大小对比：中心更小、边缘更大
        let minSize = baseSize * 0.26
        let maxSize = baseSize * 1.85
        // 阿基米德螺线：半径随角度线性增长，增长速率由间隔控制（间隔越大圈越疏）
        let twoPi: CGFloat = 2 * CGFloat.pi
        let radialGrowth = max((baseSize + spacing) / twoPi, baseSize * 0.16)
        var theta: CGFloat = 0
        var r: CGFloat = 0
        var index = 0
        var placed = 0
        while r <= maxR, placed < 400 {
            let x = cx + r * cos(theta)
            let y = cy + r * sin(theta)
            let t: CGFloat = min(r / maxR, 1)
            let size = minSize + (maxSize - minSize) * t
            if x > -size, x < w + size, y > -size, y < h + size {
                drawEmojiGlyph(ctx, emojis[index % emojis.count], size: size,
                               center: CGPoint(x: x, y: y))
                index += 1
            }
            placed += 1
            // 沿螺线前进：弧长 ≈ 当前字号 + 间隔
            let arcStep = max(size + spacing, minSize + spacing)
            theta += arcStep / max(r, arcStep)
            r = radialGrowth * theta
        }
    }

    /// 解码封面图（JPEG/PNG 数据 → CGImage）
    public static func decodeArtwork(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 从封面图采样主色（缩小到 32×32 求平均，跳过透明像素）
    public static func dominantColor(of image: CGImage) -> (CGFloat, CGFloat, CGFloat) {
        let size = 32
        guard let ctx = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else {
            return (0.07, 0.10, 0.16)
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        var r = 0.0, g = 0.0, b = 0.0
        var count = 0.0
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(size * size) {
            let idx = i * 4
            if ptr[idx + 3] < 200 { continue }
            r += Double(ptr[idx])
            g += Double(ptr[idx + 1])
            b += Double(ptr[idx + 2])
            count += 1
        }
        guard count > 0 else { return (0.07, 0.10, 0.16) }
        return (CGFloat(r / count / 255), CGFloat(g / count / 255), CGFloat(b / count / 255))
    }

    /// 由封面主色生成整卡调色板（按明暗自动适配文字，保留主题强调色）
    public static func artworkPalette(baseColor: (CGFloat, CGFloat, CGFloat),
                                      themeAccent: (CGFloat, CGFloat, CGFloat)) -> ScreenPalette {
        let (r, g, b) = baseColor
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        let isDark = luminance < 0.5
        func adjust(_ component: CGFloat, _ factor: CGFloat) -> CGFloat {
            min(max(component * factor, 0), 1)
        }
        let card = isDark
            ? (adjust(r, 1.18), adjust(g, 1.18), adjust(b, 1.18))
            : (adjust(r, 0.88), adjust(g, 0.88), adjust(b, 0.88))
        let inset = isDark
            ? (adjust(r, 1.35), adjust(g, 1.35), adjust(b, 1.35))
            : (adjust(r, 0.80), adjust(g, 0.80), adjust(b, 0.80))
        let border = isDark
            ? (adjust(r, 1.65), adjust(g, 1.65), adjust(b, 1.65))
            : (adjust(r, 0.62), adjust(g, 0.62), adjust(b, 0.62))
        let (text, sub, ter): ((CGFloat, CGFloat, CGFloat), (CGFloat, CGFloat, CGFloat), (CGFloat, CGFloat, CGFloat))
        if isDark {
            text = (0.98, 0.98, 0.98)
            sub = (0.88, 0.88, 0.90)
            ter = (0.76, 0.76, 0.80)
        } else {
            text = (0.10, 0.10, 0.12)
            sub = (0.30, 0.30, 0.34)
            ter = (0.42, 0.42, 0.46)
        }
        return ScreenPalette(
            background: baseColor,
            card: card,
            inset: inset,
            border: border,
            accent: themeAccent,
            secondaryAccent: themeAccent,
            primaryText: text,
            secondaryText: sub,
            tertiaryText: ter
        )
    }

    // MARK: - 工具

    public static func formatRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1024 * 1024 { return String(format: "%.1f MB/s", bytesPerSecond / 1024 / 1024) }
        if bytesPerSecond >= 1024 { return String(format: "%.1f KB/s", bytesPerSecond / 1024) }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    // MARK: - 绘制基础

    private static func clampSafeArea(_ value: Int) -> CGFloat {
        CGFloat(min(max(value, 44), 80))
    }

    private static func createContext() -> CGContext {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        return ctx
    }

    /// 绘制背景与卡片（Skia 语义坐标：origin 在屏幕左上，y 向下）
    private static func drawCanvas(_ ctx: CGContext, safeArea: CGFloat, colors: ScreenPalette) -> CGRect {
        ctx.setFillColor(colors.backgroundCG)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 卡片顶部从安全区下方开始（Skia 语义）
        let cardSkia = CGRect(x: 9, y: safeArea + 1, width: 124,
                              height: CGFloat(height) - 9 - (safeArea + 1))
        // 绘制时转换一次到 CG 坐标；勿直接传 Skia 数值（CG 会把 y 当作距底部距离，
        // 导致卡片顶边钉死在屏幕顶部、安全区空隙落在卡片底部——此前"第二个底色框顶边不同步"问题）
        let card = rect(cardSkia)
        fillRound(ctx, card, radius: 13, color: colors.cardCG)
        strokeRound(ctx, card, radius: 13, color: colors.borderCG, width: 1)
        return cardSkia
    }

    private static func encode(_ ctx: CGContext, quality: Int) throws -> RenderResult {
        guard let image = ctx.makeImage() else { throw RenderError.encodeFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RenderError.encodeFailed
        }
        let q = Double(min(max(quality, 50), 100)) / 100
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encodeFailed }
        let result = data as Data
        if result.count > maximumFileSize { throw RenderError.tooLarge(result.count) }
        return RenderResult(data: result, image: image)
    }

    /// 无损 PNG 编码（推送时无压缩痕迹；PNG 对大面积纯色卡片体积远小于 512KB 上限）
    public static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let result = data as Data
        return result.count <= maximumFileSize ? result : nil
    }

    /// 把 Skia 语义矩形（origin 左上、y 向下）转换为 CG 坐标（origin 左下、y 向上）
    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: CGFloat(height) - y - h, width: w, height: h)
    }

    /// 同上的矩形重载
    private static func rect(_ skia: CGRect) -> CGRect {
        rect(skia.minX, skia.minY, skia.width, skia.height)
    }

    private static func fillRound(_ ctx: CGContext, _ bounds: CGRect, radius: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func strokeRound(_ ctx: CGContext, _ bounds: CGRect, radius: CGFloat, color: CGColor, width: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawLine(_ ctx: CGContext, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: x1, y: CGFloat(height) - y1))
        ctx.addLine(to: CGPoint(x: x2, y: CGFloat(height) - y2))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawBox(_ ctx: CGContext, _ bounds: CGRect, colors: ScreenPalette) {
        fillRound(ctx, bounds, radius: 10, color: colors.insetCG)
        strokeRound(ctx, bounds, radius: 10, color: colors.borderCG, width: 1)
    }

    private static func drawProgress(_ ctx: CGContext, _ bounds: CGRect, progress: Double,
                                     accent: CGColor, background: CGColor) {
        let p = min(max(progress, 0), 1)
        let radius = bounds.height / 2
        fillRound(ctx, bounds, radius: radius, color: background)
        guard p > 0 else { return }
        let filledWidth = max(bounds.height, bounds.width * p)
        var filled = bounds
        filled.size.width = filledWidth
        ctx.saveGState()
        ctx.addRect(bounds)
        ctx.clip()
        fillRound(ctx, filled, radius: radius, color: accent)
        ctx.restoreGState()
    }

    private static func drawHeader(_ ctx: CGContext, card: CGRect, title: String, badge: String,
                                   accent: CGColor, colors: ScreenPalette, titleSize: CGFloat = 10,
                                   dotColor: CGColor? = nil) {
        let center = CGPoint(x: card.minX + 13.5, y: CGFloat(height) - (card.minY + 18.5))
        ctx.setFillColor(dotColor ?? accent)
        ctx.fillEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
        drawText(ctx, title, size: titleSize, bold: true, color: colors.primaryTextCG,
                 in: rect(card.minX + 22, card.minY + 8, 62, 25), align: .left)
        drawText(ctx, badge, size: 6, bold: true, color: accent,
                 in: rect(card.maxX - 43, card.minY + 10, 33, 20), align: .right)
    }

    /// 负载状态指示灯颜色：低负载绿 / 适中黄 / 高负载红（以 CPU 使用率为依据）
    private static func loadIndicatorColor(percent: Double) -> CGColor {
        if percent < 40 {
            return CGColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1)   // 绿：低负载
        } else if percent < 70 {
            return CGColor(red: 0.96, green: 0.77, blue: 0.20, alpha: 1)   // 黄：适中
        } else {
            return CGColor(red: 0.95, green: 0.30, blue: 0.30, alpha: 1)   // 红：高负载
        }
    }

    private static func drawText(_ ctx: CGContext, _ text: String, size: CGFloat, bold: Bool,
                                 color: CGColor, in bounds: CGRect, align: NSTextAlignment,
                                 fontName: String? = nil) {
        let resolvedFont = fontName ?? (bold ? "PingFangSC-Semibold" : "PingFangSC-Regular")
        let font = CTFontCreateWithName(resolvedFont as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let measure: (String) -> CGFloat = fontName != nil
            ? { measureTextWidth($0, fontName: resolvedFont, size: size) }
            : { measureTextWidth($0, size: size, bold: bold) }

        var content = text
        if measure(content) > bounds.width {
            while content.count > 1 && measure(content + "…") > bounds.width {
                content.removeLast()
            }
            content += "…"
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: content, attributes: attributes))
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let baselineY = bounds.midY - (ascent + descent) / 2
        let lineWidth = measure(content)
        let x: CGFloat
        switch align {
        case .left: x = bounds.minX
        case .right: x = bounds.maxX - lineWidth
        default: x = bounds.midX - lineWidth / 2
        }
        ctx.textPosition = CGPoint(x: x, y: baselineY)
        CTLineDraw(line, ctx)
    }

    /// 用 PingFang SC 度量文本宽度（粗体/常规）
    private static func measureTextWidth(_ text: String, size: CGFloat, bold: Bool) -> CGFloat {
        let fontName = bold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// 用指定字体度量文本宽度（自定义字体叠加）
    private static func measureTextWidth(_ text: String, fontName: String, size: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// 自适应字号：从 maxSize 逐步缩小直到放得下 maxWidth，缩到 minSize 为止
    public static func adaptiveFontSize(_ text: String, maxSize: CGFloat, minSize: CGFloat,
                                        bold: Bool, maxWidth: CGFloat) -> CGFloat {
        var size = maxSize
        while size > minSize, measureTextWidth(text, size: size, bold: bold) > maxWidth {
            size -= 0.5
        }
        return size
    }

    /// 自适应字号文本：字号收缩到放得下为止；仍放不下时交由 drawText 的截断逻辑收尾。
    private static func drawAdaptiveText(_ ctx: CGContext, _ text: String,
                                         maxSize: CGFloat, minSize: CGFloat, bold: Bool,
                                         color: CGColor, in bounds: CGRect, align: NSTextAlignment) {
        let size = adaptiveFontSize(text, maxSize: maxSize, minSize: minSize, bold: bold, maxWidth: bounds.width)
        drawText(ctx, text, size: size, bold: bold, color: color, in: bounds, align: align)
    }

    private static func formatDate(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// 播放时长格式：mm:ss 或 h:mm:ss
    private static func formatClock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func toGiB(_ bytes: UInt64) -> Double {
        Double(bytes) / 1024 / 1024 / 1024
    }
}
