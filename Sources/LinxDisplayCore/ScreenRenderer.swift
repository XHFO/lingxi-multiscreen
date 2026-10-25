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

        if !snapshot.isAvailable {
            drawText(ctx, "尚未读取", size: 18, bold: true, color: colors.primaryTextCG,
                     in: rect(c.minX + 8, c.minY + 145, c.width - 16, 32), align: .center)
            drawText(ctx, "请在软件中刷新 Codex 用量", size: 9, bold: false,
                     color: colors.secondaryTextCG,
                     in: rect(c.minX + 8, c.minY + 180, c.width - 16, 24), align: .center)
            return try encode(ctx, quality: settings.jpegQuality)
        }

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
        let taskName = snapshot.taskName.isEmpty ? "专注工作" : snapshot.taskName
        let taskWidth = max(c.maxX - c.minX - 20, 1)
        drawText(ctx, taskName,
                 size: adaptiveFontSize(taskName, maxSize: 13, minSize: 7, bold: true, maxWidth: taskWidth),
                 bold: true, color: colors.primaryTextCG,
                 in: rect(c.minX + 10, c.minY + 50, taskWidth, 34), align: .center)

        // 键盘番茄钟与电脑预览使用同一个可调间隔刻度，
        // 避免上传耗时使两端显示的倒计时不一致。
        let seconds = PomodoroRefreshPolicy.alignedRemainingSeconds(
            snapshot.remaining, duration: snapshot.duration,
            intervalSeconds: settings.pomodoroUploadSeconds)
        drawText(ctx, String(format: "%02d:%02d", seconds / 60, seconds % 60),
                 size: 28, bold: true, color: colors.primaryTextCG,
                 in: rect(c.minX + 6, c.minY + 86, c.maxX - c.minX - 12, 45), align: .center)
        let alignedProgress = snapshot.duration > 0
            ? min(max(1 - Double(seconds) / snapshot.duration, 0), 1)
            : 0
        drawProgress(ctx, rect(c.minX + 12, c.minY + 139, c.maxX - c.minX - 24, 8),
                     progress: alignedProgress, accent: accent, background: colors.borderCG)
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

    // MARK: - 打印完成庆祝卡（打印成功后短暂展示，任何界面下都会显示）

    /// 打印成功庆祝卡：🎉（右下角，放大）+ 「打印完成！」+ 打印机名（与番茄钟夸夸卡同模式，短暂占屏）
    public static func renderPrintSuccess(printerName: String, taskName: String? = nil,
                                          picture: Data? = nil,
                                          settings: AppSettings,
                                          now: Date = Date()) throws -> RenderResult {
        let colors = settings.resolvedPalette
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let c = drawCanvas(ctx, safeArea: safe, colors: colors)
        let accent = colors.accentCG
        let maxW = c.maxX - c.minX - 16

        drawHeader(ctx, card: c, title: "PRINTER", badge: "完成", accent: accent, colors: colors)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)

        // 大字「打印完成！」（居中；按宽度收缩，保证完整不截断）
        var titleSize: CGFloat = 26
        var titleW = measureTextWidth("打印完成！", size: titleSize, bold: true)
        if titleW > maxW { titleSize = max(titleSize * maxW / titleW, 12) }
        drawText(ctx, "打印完成！", size: titleSize, bold: true, color: colors.primaryTextCG,
                 in: rect(c.minX + 8, c.minY + 66, maxW, 36), align: .center)
        // 打印机名（设备名，自适应缩字号）
        let displayName = printerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.isEmpty ? "打印机" : displayName
        var size: CGFloat = 13
        var tw = measureTextWidth(name, size: size, bold: true)
        if tw > maxW { size = max(size * maxW / tw, 8) }
        drawText(ctx, name, size: size, bold: true, color: accent,
                 in: rect(c.minX + 8, c.minY + 108, maxW, 22), align: .center)

        // 完成的任务名（最多两行，让用户知道具体打完的是哪个任务）
        var nextY = c.minY + 138
        let trimmedTask = (taskName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTask.isEmpty, trimmedTask.lowercased() != "unknown" {
            let lines = splitLines("任务：\(trimmedTask)", size: 11, bold: false,
                                   maxW: maxW, maxLines: 2)
            for line in lines {
                drawText(ctx, line, size: 11, bold: false, color: colors.primaryTextCG,
                         in: rect(c.minX + 8, nextY, maxW, 16), align: .center)
                nextY += 16
            }
        } else {
            drawText(ctx, "已成功完成打印", size: 10, bold: false, color: colors.secondaryTextCG,
                     in: rect(c.minX + 8, nextY, maxW, 18), align: .center)
            nextY += 18
        }

        // 完成画面（打印机摄像头最后一帧 / 模型封面）：有空间时按 16:9 圆角区块显示
        var pictureBox: CGRect?
        if let picture {
            let reserveH: CGFloat = 46
            let boxW = c.maxX - c.minX - 16
            let naturalH = boxW * 9 / 16
            let availableH = (c.maxY - 26) - nextY
            if availableH >= reserveH {
                let boxH = min(naturalH, availableH, 110)
                let box = CGRect(x: c.minX + 8, y: nextY + 4, width: boxW, height: boxH)
                if drawImageData(ctx, data: picture, into: box, cover: true, radius: 6) {
                    strokeRound(ctx, rect(box), radius: 6, color: colors.borderCG, width: 1)
                    pictureBox = box
                }
            }
        }

        // 🎉 庆祝 emoji：无画面时右下角放大（88pt）；有画面时叠在画面右下角作庆祝徽标（60pt），
        // 避免与上方标题/任务行重叠
        if let box = pictureBox {
            drawText(ctx, "🎉", size: 60, bold: false, color: colors.primaryTextCG,
                     in: rect(box.maxX - 64, box.maxY - 64, 60, 60), align: .center,
                     fontName: "AppleColorEmoji")
        } else {
            drawText(ctx, "🎉", size: 88, bold: false, color: colors.primaryTextCG,
                     in: rect(c.maxX - 12 - 88, c.maxY - 44 - 88, 88, 88), align: .center,
                     fontName: "AppleColorEmoji")
        }

        drawText(ctx, "PRINTER", size: 7, bold: false, color: accent,
                 in: rect(c.minX + 8, c.maxY - 24, maxW, 16), align: .center)
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
        if settings.showDisk { sections.append(.disk) }
        if settings.showNetwork { sections.append(.network) }
        if settings.showUptime { sections.append(.uptime) }
        if sections.isEmpty { sections = [.cpu] }

        let regionTop = c.minY + 49 + 6
        let regionBottom = c.maxY - 15 - 30  // 预留页脚时间戳

        // 运行时间不占满槽位：与其他板块同显时只在底部占一条紧凑行，
        // 其余板块均分剩余高度（避免运行时间挤占过多安全区）
        let mainSections = sections.filter { $0 != .uptime }
        let hasUptime = sections.contains(.uptime) && !mainSections.isEmpty
        let uptimeBandH: CGFloat = hasUptime ? 20 : 0
        let mainCount = max(mainSections.count, 1)
        let mainBandH = max(regionBottom - regionTop - uptimeBandH, CGFloat(mainCount) * 44)
        let slotHeight = mainBandH / CGFloat(mainCount)
        let uptimeBandTop = regionTop + mainBandH

        var mainIndex = 0
        for section in sections {
            if section == .uptime {
                if hasUptime {
                    // 底部紧凑单行（不参与均分）
                    drawText(ctx, uptimeText(snapshot.uptime), size: 7.5, bold: false,
                             color: colors.secondaryTextCG,
                             in: rect(c.minX + 8, uptimeBandTop, c.maxX - c.minX - 16, uptimeBandH), align: .center)
                } else {
                    // 仅显示运行时间时，维持整槽居中
                    drawText(ctx, uptimeText(snapshot.uptime), size: 7.5, bold: false,
                             color: colors.secondaryTextCG,
                             in: rect(c.minX + 8, regionTop, c.maxX - c.minX - 16, regionBottom - regionTop), align: .center)
                }
                continue
            }
            let slotTop = regionTop + CGFloat(mainIndex) * slotHeight
            mainIndex += 1
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
            case .disk:
                let contentHeight: CGFloat = 56
                let sTop = slotTop + max(0, (slotHeight - contentHeight) / 2)
                drawText(ctx, "磁盘", size: 7.5, bold: false, color: colors.secondaryTextCG,
                         in: rect(c.minX + 12, sTop, 38, 21), align: .left)
                drawText(ctx, String(format: "%.0f%%", snapshot.diskPercent), size: 11, bold: true,
                         color: colors.primaryTextCG,
                         in: rect(c.minX + 46, sTop, c.maxX - c.minX - 58, 23), align: .right)
                drawProgress(ctx, rect(c.minX + 12, sTop + 24, c.maxX - c.minX - 24, 7),
                             progress: snapshot.diskPercent / 100,
                             accent: colors.secondaryAccentCG, background: colors.borderCG)
                drawText(ctx, String(format: "%.0f / %.0f GB", toGiB(snapshot.usedDiskBytes), toGiB(snapshot.totalDiskBytes)),
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
                break // 运行时间已在循环内单独处理（底部紧凑行/仅此一项时整槽居中）
            }
        }

        // 页脚时间戳
        drawText(ctx, formatDate(snapshot.sampledAt, "HH:mm:ss"), size: 7.5, bold: false,
                 color: colors.secondaryTextCG,
                 in: rect(c.minX + 8, c.maxY - 15 - 24, c.maxX - c.minX - 16, 18), align: .center)

        return try encode(ctx, quality: settings.jpegQuality)
    }

    private enum SystemSection { case cpu, memory, disk, network, uptime }

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
                                    codex: UsageSnapshot = .empty,
                                    qwenQuota: QwenWorkQuota = .unavailable,
                                    grokBot: GrokBotUsageSnapshot = .notConfigured,
                                    cloudflare: CloudflareUsageSnapshot = .notConfigured,
                                    sspaiArticles: [SspaiArticle] = [],
                                    ha: HASnapshot = .empty,
                                    formlabsItems: [FormlabsCanvasItem] = [],
                                    now: Date = Date(),
                                    palette: ScreenPalette? = nil,
                                    printerFields: [Int: CanvasPrinterFields] = [:],
                                    artworkImage: CGImage? = nil,
                                    bambuHeroLayout: Bool = true) throws -> RenderResult {
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        if modules == [.weather], let weather = settings.weatherSnapshot {
            WeatherSkyRenderer.draw(ctx, weather: weather,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                coordinateHeight: CGFloat(height), safeArea: CGFloat(safe), now: now)
            return try encode(ctx, quality: settings.jpegQuality)
        }
        // 画板专用底色模式（手动深/浅色）覆盖默认调色板。
        // Liquid Glass 下封面取色与“智能封面背景”是两件事：即使用户
        // 保留手动主题背景，两道玻璃光晕也仍应来自当前专辑封面。
        let availableCoverArt = modules.contains(.nowPlaying)
            ? (artworkImage ?? nowPlaying.artwork.flatMap { decodeArtwork($0) })
            : nil
        let selectedPalette = palette ?? settings.resolvedPalette
        let basePalette = settings.cardRenderingMode == .liquidGlass
            ? availableCoverArt.map { applyingArtworkAccents(to: selectedPalette, artwork: $0) }
                ?? selectedPalette
            : selectedPalette

        // 背景模式：图像模块铺满整卡作底（其上叠加深色蒙版保证文字可读）。
        // 图像模式仅键盘画板可选；墨水屏画板图片模块固定按叠加模块显示
        let useImageBackground = modules.contains(.image)
            && settings.canvasImageMode == .background
            && isCanvasImageReady(settings.customImagePath)

        // 智能封面取色背景：整卡背景替换为专辑封面主色（同「正在播放」卡片设计），
        // 需画板含「正在播放」模块且有封面；整卡文字/边框随主色明暗自适应
        let coverArt = settings.canvasNowPlayingSmartBg ? availableCoverArt : nil
        let accentArtwork = coverArt
            ?? (settings.cardRenderingMode == .liquidGlass ? availableCoverArt : nil)
        let coverDominant = accentArtwork.map { dominantColor(of: $0) }

        let colors: ScreenPalette
        let c: CGRect
        if useImageBackground, let path = settings.customImagePath {
            let imagePalette = ScreenThemes.get(.deepSpace) // 深色系，保证图上文字可读
            colors = settings.cardRenderingMode == .liquidGlass
                ? availableCoverArt.map { applyingArtworkAccents(to: imagePalette, artwork: $0) }
                    ?? imagePalette
                : imagePalette
            // 壁纸仍是原始图像层；玻璃容器在其后、文字之前单独合成。
            _ = ColorCardSceneCapture.background(ctx, palette: colors)
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // 背景模式：图片等比完整显示（contain，不裁剪不变形），忽略顶部安全区、铺满整个屏幕；
            // 其他模块叠加其上
            drawImageContain(ctx, path: path,
                             into: CGRect(x: 0, y: 0, width: CGFloat(width),
                                          height: CGFloat(height)))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.5))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            c = CGRect(x: 9, y: CGFloat(safe) + 1, width: 124,
                       height: CGFloat(height) - 9 - (CGFloat(safe) + 1))
            _ = ColorCardSceneCapture.panel(ctx, bounds: rect(c), radius: 13,
                                            color: colors.cardCG)
            strokeRound(ctx, rect(c), radius: 13, color: colors.borderCG, width: 1)
        } else if let coverArt {
            colors = artworkPalette(of: coverArt,
                                    themeAccent: basePalette.accent)
            c = drawCanvas(ctx, safeArea: safe, colors: colors)
        } else {
            colors = basePalette
            c = drawCanvas(ctx, safeArea: safe, colors: colors)
        }

        drawHeader(ctx, card: c, title: "CANVAS", badge: "灵犀画板",
                   accent: colors.accentCG, colors: colors, badgeSize: 8)
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
            let multipleBambuModules = modules.filter { $0.bambuSlotIndex != nil }.count > 1
            let bands = moduleBands(modules: modules, region: region, settings: settings,
                                    haEntityCount: ha.selectedEntities.count + ha.missingEntityIDs.count,
                                    printerFields: printerFields,
                                    formlabsItems: formlabsItems,
                                    compactBambuSummary: multipleBambuModules,
                                    bambuHeroLayout: bambuHeroLayout,
                                    zeroHeightImageModule: useImageBackground)
            // 灵犀画板强调色跟随封面：画板含「正在播放」模块且开启智能封面取色（有封面）时，
            // 所有模块的进度条/百分比条强调色统一用封面生成的强调色（coverProgressAccent），
            // 关闭开关或无封面时回退全局强调色
            let accentOverride: CGColor? = coverDominant.map { dominant in
                let acc = coverProgressAccent(dominant)
                return CGColor(red: acc.0, green: acc.1, blue: acc.2, alpha: 1)
            }
            for (index, module) in modules.enumerated() {
                drawCanvasModule(ctx, module, band: bands[index], colors: colors,
                                 system: system, nowPlaying: nowPlaying, pomodoro: pomodoro,
                                 customText: customText, settings: settings,
                                 codex: codex, qwenQuota: qwenQuota,
                                 grokBot: grokBot, cloudflare: cloudflare,
                                 sspaiArticles: sspaiArticles,
                                 ha: ha, now: now,
                                 formlabsItems: formlabsItems,
                                 nowPlayingSmartBg: settings.canvasNowPlayingSmartBg,
                                 canvasCoverBgActive: coverArt != nil,
                                 accentOverride: accentOverride,
                                 printerFields: printerFields,
                                 // 灵犀画板与口袋先知/摘录统一采用新版打印机仪表排版：
                                 // 状态背景字、前景百分比、加粗进度条、双行任务名与数据更新时间。
                                 bambuHeroLayout: bambuHeroLayout,
                                 compactBambuSummary: multipleBambuModules,
                                 singleModuleCanvas: modules.count == 1,
                                 // 键盘上的灵犀画板空间最窄：不再把“打印中/空闲/暂停”等
                                 // 状态作为超大背景字；独立卡片和另外两种设备画板不受影响。
                                 hideBambuLargeStatusText: true)
            }
        }
        return try encode(ctx, quality: settings.jpegQuality)
    }

    /// Home Assistant 模块的内容高度倍率。数量越多占比越大；使用渐进曲线而不是硬上限，
    /// 因此即使实体很多，删掉任意一个也会重新释放空间。空选择仍保留最小提示高度。
    public static func homeAssistantCanvasHeightMultiplier(entityCount: Int) -> CGFloat {
        let count = max(entityCount, 1)
        let extra = CGFloat(count - 1)
        return 0.5 + 3.0 * extra / CGFloat(count + 3)
    }

    /// 打印机画板模块按实际开启内容动态分配高度。隐藏字段不仅停止绘制，也会降低外层
    /// 分带权重，把空间返还给同一画板中的其他模块。进度仪表会合并名称/状态，多打印机
    /// 摘要还会合并温度，并把时间放到进度旁，因此这些组合不会重复计算整行高度。
    public static func bambuCanvasHeightMultiplier(fields: CanvasPrinterFields,
                                                    compactSummary: Bool,
                                                    heroLayout: Bool = true) -> CGFloat {
        var demand: CGFloat = 1.0 // 即使全部隐藏，仍保留打印机名称/空配置提示
        if fields.showProgress {
            demand += heroLayout ? 0.8 : 1.0
        }
        if fields.showTask { demand += 1.2 }
        if fields.showNozzleTemp || fields.showBedTemp {
            demand += compactSummary
                ? 1.0
                : CGFloat((fields.showNozzleTemp ? 1 : 0) + (fields.showBedTemp ? 1 : 0))
        }
        // 多打印机摘要的时间已经并入进度行；其他布局仍需要独立一行。
        if fields.showRemaining && !(compactSummary && heroLayout && fields.showProgress) {
            demand += 1.0
        }
        // 错误详情只在异常时出现，预留半行即可，避免正常状态长期浪费整行。
        if fields.showError { demand += 0.5 }
        // 摄像头/任务封面需要明显高于文字行的正方形/横向画面区域。
        if fields.showImage { demand += 2.4 }
        return min(max(0.28 + demand * 0.22, 0.5), 2.15)
    }

    /// 模块加权分带：模块上下边距越大（紧凑度越高）权重越小、占用高度越少；
    /// Home Assistant 模块再根据本画板实际选择的实体数量动态增减权重。
    /// columns=2 时按双列流式排列：普通模块占一列，fullWidthModules 中的模块占满整行；
    /// 行高按该行最大权重计算（同行的两个模块等高）。
    /// zeroHeightImageModule=true 时图像模块占位为 0（键盘画板背景模式下让其他模块占满整卡）。
    private static func moduleBands(modules: [CanvasModule], region: CGRect,
                                    settings: AppSettings,
                                    columns: Int = 1,
                                    fullWidthModules: Set<Int> = [],
                                    haEntityCount: Int = 0,
                                    printerFields: [Int: CanvasPrinterFields] = [:],
                                    formlabsItems: [FormlabsCanvasItem] = [],
                                    compactBambuSummary: Bool = false,
                                    bambuHeroLayout: Bool = true,
                                    zeroHeightImageModule: Bool = false) -> [CGRect] {
        let weights = modules.map { m -> CGFloat in
            if zeroHeightImageModule && m == .image { return 0 }
            let margin = settings.canvasMargin(for: m)
            // 边距 0–40 线性映射到权重 1.0–0.15：整段滑杆都有效
            // （旧口径 1 - margin/40 配 0.25 下限，边距到 30 就触底，30–40 区间调节毫无变化）
            let base = max(0.15, 1.0 - CGFloat(margin) * 0.85 / 40.0)
            // 正在播放（含封面）需要更大高度：自适应/手动边距下都给予空间权重加成，
            // 避免封面被压得过小（仍不足时渲染层自动转横向排布）
            if m == .nowPlaying { return max(base * 1.4, 0.25) }
            if m == .grokBot || m == .cloudflare { return max(base * 1.35, 0.3) }
            if m == .homeAssistant {
                return base * homeAssistantCanvasHeightMultiplier(entityCount: haEntityCount)
            }
            if m.bambuSlotIndex != nil {
                let fields = printerFields[m.rawValue] ?? settings.canvasPrinterFields(for: m)
                return base * bambuCanvasHeightMultiplier(
                    fields: fields,
                    compactSummary: compactBambuSummary,
                    heroLayout: bambuHeroLayout)
            }
            if let slot = m.formlabsSlotIndex {
                let connection = formlabsItems.indices.contains(slot)
                    ? formlabsItems[slot].connection : FormlabsConnectionSettings()
                var demand: CGFloat = 2.4 // 设备名、状态、进度与任务名
                if connection.showThumbnail { demand += 2.2 }
                if connection.showLayers { demand += 0.7 }
                if connection.showMaterial { demand += 0.7 }
                return base * min(max(0.35 + demand * 0.22, 0.7), 2.1)
            }
            return base
        }
        var bands: [CGRect] = []
        if columns <= 1 || modules.count <= 1 {
            let totalWeight = max(weights.reduce(0, +), 0.01)
            let positiveCount = weights.filter { $0 > 0 }.count
            let verticalGap: CGFloat = 4
            let usableHeight = max(region.height
                                   - verticalGap * CGFloat(max(positiveCount - 1, 0)), 0)
            var cursor = region.minY
            var remainingPositive = positiveCount
            for (index, _) in modules.enumerated() {
                let bandHeight = usableHeight * weights[index] / totalWeight
                bands.append(CGRect(x: region.minX, y: cursor,
                                    width: region.width, height: bandHeight))
                cursor += bandHeight
                if weights[index] > 0 {
                    remainingPositive -= 1
                    if remainingPositive > 0 { cursor += verticalGap }
                }
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
        let horizontalGap: CGFloat = 6
        let verticalGap: CGFloat = 4
        let colWidth = (region.width - horizontalGap) / 2
        let usableHeight = max(region.height
                               - verticalGap * CGFloat(max(rows.count - 1, 0)), 0)
        bands = [CGRect](repeating: .zero, count: modules.count)
        var cursor = region.minY
        for (rowIndex, row) in rows.enumerated() {
            let rowHeight = usableHeight * rowWeights[rowIndex] / totalRowWeight
            if row.count == 2 {
                let left = row[0]
                let right = row[1]
                bands[left] = CGRect(x: region.minX, y: cursor, width: colWidth, height: rowHeight)
                bands[right] = CGRect(x: region.minX + colWidth + horizontalGap, y: cursor,
                                      width: colWidth, height: rowHeight)
            } else {
                let index = row[0]
                let spansBoth = fullWidthModules.contains(modules[index].rawValue)
                bands[index] = CGRect(x: region.minX, y: cursor,
                                      width: spansBoth ? region.width : colWidth,
                                      height: rowHeight)
            }
            cursor += rowHeight
            if rowIndex < rows.count - 1 { cursor += verticalGap }
        }
        return bands
    }

    /// 独立设备画布渲染：把模块组合渲染为指定尺寸的画布（无键盘卡片外壳/安全区）。
    /// 图像模块一律按「叠加」处理（铺满自己的横带）；
    /// optimizeForEInk=false 时保留完整彩色主题，并允许封面取色驱动整板背景；
    /// flipVertical/flipHorizontal 上下/左右翻转整幅画面（同开 = 旋转 180°）；
    /// columns=2 时模块按双列排列，fullWidthModules 中的模块占满整行（摘录画板用）。
    public static func renderDeviceCanvas(modules: [CanvasModule], system: SystemSnapshot,
                                          nowPlaying: NowPlayingInfo, pomodoro: PomodoroSnapshot,
                                          customText: String, settings: AppSettings,
                                          codex: UsageSnapshot = .empty,
                                          qwenQuota: QwenWorkQuota = .unavailable,
                                          grokBot: GrokBotUsageSnapshot = .notConfigured,
                                          cloudflare: CloudflareUsageSnapshot = .notConfigured,
                                          sspaiArticles: [SspaiArticle] = [],
                                          ha: HASnapshot = .empty,
                                          formlabsItems: [FormlabsCanvasItem] = [],
                                          now: Date = Date(),
                                          width: Int, height: Int,
                                          palette: ScreenPalette,
                                          optimizeForEInk: Bool = true,
                                          flipVertical: Bool = false,
                                          flipHorizontal: Bool = false,
                                          columns: Int = 1,
                                          fullWidthModules: Set<Int> = [],
                                          nowPlayingHorizontal: Bool = false,
                                          canvasImagePath: String? = nil,
                                          printerFields: [Int: CanvasPrinterFields] = [:],
                                          optimizeBambuForOracleEInk: Bool = false,
                                          bambuHeroLayout: Bool = false,
                                          showBambuCamera: Bool = true,
                                          nowPlayingSmartBackground: Bool = false,
                                          nowPlayingShowCover: Bool? = nil) -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("create device canvas context")
        }
        // 口袋先知/摘录继续锁定黑白高对比文字；AI Mac 彩屏直接保留主题色、
        // 打印机品牌色、封面光晕与进度强调色。
        let availableCoverArt = modules.contains(.nowPlaying)
            ? nowPlaying.artwork.flatMap { decodeArtwork($0) } : nil
        let coverArt = nowPlayingSmartBackground ? availableCoverArt : nil
        let accentArtwork = coverArt
            ?? (!optimizeForEInk && settings.cardRenderingMode == .liquidGlass
                ? availableCoverArt : nil)
        let coverDominant = accentArtwork.map { dominantColor(of: $0) }
        let selectedPalette = optimizeForEInk ? einkTextPalette(palette)
            : (modules == [.sspai] ? sspaiPalette(palette) : palette)
        let basePalette = (!optimizeForEInk && settings.cardRenderingMode == .liquidGlass)
            ? availableCoverArt.map { applyingArtworkAccents(to: selectedPalette, artwork: $0) }
                ?? selectedPalette
            : selectedPalette
        let canvasPalette: ScreenPalette
        if !optimizeForEInk, let coverArt {
            canvasPalette = artworkPalette(of: coverArt,
                                           themeAccent: palette.accent)
        } else {
            canvasPalette = basePalette
        }
        if optimizeForEInk || !ColorCardSceneCapture.background(ctx, palette: canvasPalette) {
            ctx.setFillColor(canvasPalette.backgroundCG)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        // 模块绘制助手统一按键盘画板高度（428）做 Skia→CG 翻转；
        // 平移 CTM 使同一套坐标正确落到当前尺寸的画布上
        ctx.translateBy(x: 0, y: CGFloat(height) - CGFloat(ScreenRenderer.height))

        let inset: CGFloat = 8
        let immersiveWeather = !optimizeForEInk && modules == [.weather]
            && settings.weatherSnapshot != nil && height >= 160 && width >= 110
        let region = immersiveWeather
            ? CGRect(x: 0, y: 0, width: width, height: height)
            : CGRect(x: inset, y: inset, width: CGFloat(width) - inset * 2,
                     height: CGFloat(height) - inset * 2)
        if !optimizeForEInk, ColorCardSceneCapture.isActive, modules != [.image], !immersiveWeather {
            // 正方形画板原本没有整板卡片外壳。仅增加背后的玻璃层，保持所有
            // 模块的现有排版区域和字号，不挤占可用空间；纯图片画板不加遮罩。
            let glassBounds = region.insetBy(dx: -4, dy: -4)
            _ = ColorCardSceneCapture.panel(ctx, bounds: rect(glassBounds), radius: 16,
                                            color: canvasPalette.cardCG)
        }
        if modules.isEmpty {
            drawText(ctx, "请在面板中添加模块", size: 9, bold: false,
                     color: canvasPalette.secondaryTextCG,
                     in: rect(region.minX, region.minY + region.height / 2 - 8, region.width, 16),
                     align: .center)
        } else {
            let bands = moduleBands(modules: modules, region: region, settings: settings,
                                    columns: columns, fullWidthModules: fullWidthModules,
                                    haEntityCount: ha.selectedEntities.count + ha.missingEntityIDs.count,
                                    printerFields: printerFields,
                                    formlabsItems: formlabsItems,
                                    bambuHeroLayout: bambuHeroLayout)
            let accentOverride: CGColor? = coverDominant.map { dominant in
                let accent = coverProgressAccent(dominant)
                return CGColor(red: accent.0, green: accent.1, blue: accent.2, alpha: 1)
            }
            for (index, module) in modules.enumerated() {
                drawCanvasModule(ctx, module, band: bands[index], colors: canvasPalette,
                                 system: system, nowPlaying: nowPlaying, pomodoro: pomodoro,
                                 customText: customText, settings: settings,
                                 codex: codex, qwenQuota: qwenQuota,
                                 grokBot: grokBot, cloudflare: cloudflare,
                                 sspaiArticles: sspaiArticles,
                                 ha: ha, now: now,
                                 formlabsItems: formlabsItems,
                                 imageOverlayOnly: true,
                                 nowPlayingSmartBg: nowPlayingSmartBackground,
                                 nowPlayingShowCover: nowPlayingShowCover,
                                 canvasCoverBgActive: coverArt != nil,
                                 fullWidth: fullWidthModules.contains(module.rawValue),
                                 deviceCanvas: true,
                                 nowPlayingHorizontal: nowPlayingHorizontal,
                                 canvasImagePath: canvasImagePath,
                                 accentOverride: accentOverride,
                                 printerFields: printerFields,
                                 optimizeBambuForOracleEInk: optimizeBambuForOracleEInk,
                                 bambuHeroLayout: bambuHeroLayout,
                                 showBambuCamera: showBambuCamera,
                                 singleModuleCanvas: modules.count == 1,
                                 monochromeDeviceCanvas: optimizeForEInk)
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

    /// AI Mac 240×240 的 Bambu 独立卡片。方形屏幕不再复用窄屏画板的“大进度”
    /// 分支，而是固定保留设备名、状态、任务、进度、温度和时间，并在下半区同时
    /// 容纳摄像头静态帧与任务封面。未绑定/被关闭的内容会释放给图片区。
    public static func renderAIMacBambuCard(
        _ bambu: BambuLabCardSettings,
        entities: [HAEntity],
        cameraImage: Data? = nil,
        taskCoverImage: Data? = nil,
        settings: AppSettings,
        sampledAt: Date = Date(),
        palette: ScreenPalette,
        width: Int = 240,
        height: Int = 240
    ) -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return placeholderCanvas()
        }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        if !ColorCardSceneCapture.background(ctx, palette: palette) {
            ctx.setFillColor(palette.backgroundCG)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        // rect()/drawText() 使用 142×428 渲染器的逻辑坐标，和设备画板保持同一 CTM。
        ctx.translateBy(x: 0, y: CGFloat(height) - CGFloat(ScreenRenderer.height))

        let card = CGRect(x: 8, y: 8, width: CGFloat(width) - 16,
                          height: CGFloat(height) - 16)
        fillRound(ctx, rect(card), radius: 16, color: palette.cardCG)
        strokeRound(ctx, rect(card), radius: 16, color: palette.borderCG, width: 1)

        func entity(_ id: String) -> HAEntity? {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return entities.first { $0.entityId == trimmed }
        }

        let accent = bambu.themeAccent == .bambuLab
            ? Self.bambuLabAccentColor : palette.accentCG
        let name = bambu.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = entity(bambu.statusEntityID)
        let rawStatus = status?.state ?? ""
        let error = entity(bambu.errorEntityID)
        let staleSeconds = TimeInterval(max(10, max(1, settings.haRefreshMinutes) * 2) * 60)
        let isError = rawStatus.lowercased() == "error"
            || (error.map { value in
                let state = value.state.trimmingCharacters(in: .whitespaces).lowercased()
                return !state.isEmpty
                    && !["none", "无", "normal", "ok", "0", "off", "unavailable", "unknown"]
                        .contains(state)
                    && HAErrorCodePolicy.isFresh(entity: value, staleSeconds: staleSeconds)
            } ?? false)
        let statusColor = isError ? CGColor(red: 0.94, green: 0.35, blue: 0.28, alpha: 1) : accent

        // 固定左上角标头；右侧状态胶囊不再占据正文中的一整行。
        ctx.setFillColor(accent)
        ctx.fillEllipse(in: rect(card.minX + 10, card.minY + 11, 8, 8))
        let statusBoxW: CGFloat = bambu.showStatus ? 78 : 0
        drawAdaptiveText(ctx, name.isEmpty ? "Bambu Lab 打印机" : name,
                         maxSize: 15, minSize: 10, bold: true,
                         color: palette.primaryTextCG,
                         in: rect(card.minX + 24, card.minY + 6,
                                  card.width - 38 - statusBoxW, 27), align: .left)
        if bambu.showStatus {
            let statusBox = CGRect(x: card.maxX - 88, y: card.minY + 7,
                                   width: 78, height: 24)
            if rawStatus.isEmpty {
                fillRound(ctx, rect(statusBox), radius: 10, color: palette.insetCG)
                strokeRound(ctx, rect(statusBox), radius: 10,
                            color: palette.borderCG, width: 1)
                drawText(ctx, bambu.statusEntityID.isEmpty ? "未配置" : "加载中",
                         size: 11, bold: true, color: palette.secondaryTextCG,
                         in: rect(statusBox), align: .center)
            } else {
                drawBambuCompactStatus(ctx, rawState: rawStatus, isError: isError,
                                       color: statusColor, background: palette.insetCG,
                                       border: palette.borderCG, in: statusBox)
            }
        }
        drawLine(ctx, x1: card.minX + 10, y1: card.minY + 37,
                 x2: card.maxX - 10, y2: card.minY + 37,
                 color: palette.borderCG)

        let innerX = card.minX + 10
        let innerW = card.width - 20
        var cursorY = card.minY + 43
        let taskText = (bambu.showTask ? entity(bambu.taskEntityID)?.displayState : nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !taskText.isEmpty, taskText.lowercased() != "unknown" {
            drawBambuCanvasTask(ctx, taskText,
                                in: CGRect(x: innerX, y: cursorY,
                                           width: innerW, height: 31),
                                preferredSize: 14, color: palette.primaryTextCG,
                                bold: true)
            cursorY += 34
        }

        let progress = bambu.showProgress
            ? entity(bambu.progressEntityID).flatMap { Double($0.state) } : nil
        if let progress {
            let clamped = min(max(progress, 0), 100)
            let percent = String(format: "%.0f%%", clamped)
            let percentW: CGFloat = 43
            let bar = CGRect(x: innerX, y: cursorY + 7,
                             width: innerW - percentW - 7, height: 5)
            drawProgress(ctx, rect(bar), progress: clamped / 100,
                         accent: accent, background: palette.borderCG)
            strokeRound(ctx, rect(bar), radius: 2.5,
                        color: palette.secondaryTextCG.copy(alpha: 0.45) ?? palette.borderCG,
                        width: 0.8)
            drawText(ctx, percent, size: 13, bold: true,
                     color: palette.primaryTextCG,
                     in: rect(card.maxX - 10 - percentW, cursorY,
                              percentW, 19), align: .right)
            cursorY += 23
        }

        let nozzle = entity(bambu.nozzleTempEntityID)
        let bed = entity(bambu.bedTempEntityID)
        let hasTemperature = bambu.showTemperature && (nozzle != nil || bed != nil)
        let timeEntity = bambu.showRemaining ? entity(bambu.selectedTimeEntityID) : nil
        let hasTime = timeEntity.map {
            !$0.state.isEmpty && !["unknown", "unavailable"].contains($0.state.lowercased())
        } ?? false
        let hasErrorLine = bambu.showError && isError
        let detailRows = (hasTemperature ? 1 : 0) + (hasTime ? 1 : 0) + (hasErrorLine ? 1 : 0)
        let detailH = CGFloat(detailRows) * 17
        let footerH: CGFloat = 16
        let detailBottom = card.maxY - footerH - 4
        let detailTop = detailBottom - detailH

        let cameraConfigured = bambu.showImage
            && !bambu.imageEntityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let taskCoverConfigured = bambu.showImage
            && !bambu.taskImageEntityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPictureArea = cameraConfigured || taskCoverConfigured
        if hasPictureArea {
            let pictureTop = cursorY + 5
            let pictureBottom = detailTop - (detailRows > 0 ? 5 : 0)
            let pictureH = max(pictureBottom - pictureTop, 40)
            let gap: CGFloat = cameraConfigured && taskCoverConfigured ? 7 : 0
            let cameraW = cameraConfigured && taskCoverConfigured
                ? floor((innerW - gap) * 0.64) : innerW
            let taskW = cameraConfigured && taskCoverConfigured
                ? innerW - gap - cameraW : innerW
            let lightBackground = 0.299 * palette.background.0
                + 0.587 * palette.background.1 + 0.114 * palette.background.2 >= 0.55

            func drawPictureSlot(_ data: Data?, title: String, symbol: String,
                                 box: CGRect, cover: Bool, glow: Bool) {
                if glow, let data, let decoded = decodeArtwork(data) {
                    drawCoverGlow(ctx,
                                  color: cameraGlowColor(dominantColor(of: decoded),
                                                         lightBackground: lightBackground),
                                  coverSkia: box, extent: 15, blurSigma: 7,
                                  innerInset: 0, cornerRadius: 9,
                                  opacity: lightBackground ? 0.82 : 0.68)
                }
                fillRound(ctx, rect(box), radius: 9, color: palette.insetCG)
                let didDraw = data.map {
                    drawImageData(ctx, data: $0, into: box, cover: cover, radius: 9)
                } ?? false
                if !didDraw {
                    let iconSide = min(max(box.height * 0.28, 16), 26)
                    drawEntityIcon(ctx, symbol: symbol,
                                   in: rect(box.midX - iconSide / 2,
                                            box.midY - iconSide / 2 - 3,
                                            iconSide, iconSide),
                                   color: palette.tertiaryTextCG)
                    drawText(ctx, "等待画面", size: 8.5, bold: false,
                             color: palette.tertiaryTextCG,
                             in: rect(box.minX + 4, box.maxY - 22,
                                      box.width - 8, 13), align: .center)
                }
                strokeRound(ctx, rect(box), radius: 9,
                            color: palette.borderCG, width: 1)
                let labelW = min(max(measureTextWidth(title, size: 8, bold: true) + 12, 36),
                                 box.width - 8)
                let labelBox = CGRect(x: box.minX + 5, y: box.minY + 5,
                                      width: labelW, height: 16)
                fillRound(ctx, rect(labelBox), radius: 7,
                          color: palette.backgroundCG.copy(alpha: 0.78) ?? palette.backgroundCG)
                drawText(ctx, title, size: 8, bold: true,
                         color: palette.primaryTextCG,
                         in: rect(labelBox), align: .center)
            }

            var pictureX = innerX
            if cameraConfigured {
                let box = CGRect(x: pictureX, y: pictureTop,
                                 width: cameraW, height: pictureH)
                drawPictureSlot(cameraImage, title: "实况", symbol: "video.fill",
                                box: box, cover: true, glow: true)
                pictureX = box.maxX + gap
            }
            if taskCoverConfigured {
                let box = CGRect(x: pictureX, y: pictureTop,
                                 width: taskW, height: pictureH)
                drawPictureSlot(taskCoverImage, title: "任务", symbol: "photo.fill",
                                box: box, cover: false, glow: false)
            }
        }

        var detailY = detailTop
        if hasTemperature {
            let text = "喷嘴  \(nozzle?.displayValue ?? "—")    热床  \(bed?.displayValue ?? "—")"
            drawAdaptiveText(ctx, text, maxSize: 11.5, minSize: 8.5,
                             bold: true, color: palette.secondaryTextCG,
                             in: rect(innerX, detailY, innerW, 16), align: .center)
            detailY += 17
        }
        if hasTime, let timeEntity {
            let value = bambuCompactCanvasTimeText(timeEntity, mode: bambu.timeDisplayMode)
            let prefix = bambu.timeDisplayMode == .endTime ? "预计结束" : "剩余"
            drawAdaptiveText(ctx, "\(prefix)  \(value)", maxSize: 11.5, minSize: 8.5,
                             bold: true, color: palette.secondaryTextCG,
                             in: rect(innerX, detailY, innerW, 16), align: .center)
            detailY += 17
        }
        if hasErrorLine {
            let raw = error?.state ?? status?.state ?? "未知错误"
            let reason = BambuHMSCode.reason(for: raw) ?? raw
            drawAdaptiveText(ctx, "⚠ \(reason)", maxSize: 11, minSize: 8,
                             bold: true, color: statusColor,
                             in: rect(innerX, detailY, innerW, 16), align: .center)
        }

        drawLine(ctx, x1: card.minX + 18, y1: card.maxY - footerH - 1,
                 x2: card.maxX - 18, y2: card.maxY - footerH - 1,
                 color: palette.borderCG)
        drawText(ctx, "数据更新  \(formatDate(sampledAt, "HH:mm:ss"))",
                 size: 8.5, bold: true, color: palette.tertiaryTextCG,
                 in: rect(innerX, card.maxY - footerH, innerW, footerH), align: .center)

        return ctx.makeImage() ?? placeholderCanvas()
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
    public static func einkDeepColorRGB(against bg: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
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

    /// 从文件读入 CGImage（失败返回 nil）
    private static func imageFromFile(_ path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return original
    }

    /// 绘制内存图片（Home Assistant 画面等）：cover = 按目标比例居中裁剪铺满，
    /// contain = 等比完整显示居中留边；圆角裁切；成功绘制返回 true
    @discardableResult
    static func drawImageData(_ ctx: CGContext, data: Data, into target: CGRect,
                              cover: Bool = true, radius: CGFloat = 6) -> Bool {
        guard target.width > 1, target.height > 1,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let targetRatio = target.width / target.height
        let sourceRatio = CGFloat(image.width) / CGFloat(image.height)
        guard sourceRatio.isFinite, sourceRatio > 0 else { return false }
        let drawn: CGImage
        let drawRect: CGRect
        if cover {
            let crop: CGRect
            if sourceRatio > targetRatio {
                let cropWidth = CGFloat(image.height) * targetRatio
                crop = CGRect(x: (CGFloat(image.width) - cropWidth) / 2, y: 0,
                              width: cropWidth, height: CGFloat(image.height))
            } else {
                let cropHeight = CGFloat(image.width) / targetRatio
                crop = CGRect(x: 0, y: (CGFloat(image.height) - cropHeight) / 2,
                              width: CGFloat(image.width), height: cropHeight)
            }
            guard let cropped = image.cropping(to: crop) else { return false }
            drawn = cropped
            drawRect = target
        } else {
            if sourceRatio > targetRatio {
                let h = target.width / sourceRatio
                drawRect = CGRect(x: target.minX, y: target.minY + (target.height - h) / 2,
                                  width: target.width, height: h)
            } else {
                let w = target.height * sourceRatio
                drawRect = CGRect(x: target.minX + (target.width - w) / 2, y: target.minY,
                                  width: w, height: target.height)
            }
            drawn = image
        }
        ctx.saveGState()
        if radius > 0 {
            ctx.addPath(CGPath(roundedRect: rect(drawRect), cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
        }
        ctx.interpolationQuality = .high
        ctx.draw(drawn, in: rect(drawRect))
        ctx.restoreGState()
        return true
    }

    /// 把图片按 cover 方式铺满目标区域（Skia 语义矩形，居中裁切不变形）
    private static func drawImageCover(_ ctx: CGContext, path: String, into target: CGRect) {
        guard let original = imageFromFile(path) else { return }
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

    /// 完整绘制图片（contain）：等比缩放完整显示，不裁剪不变形；比例不符时居中留边
    private static func drawImageContain(_ ctx: CGContext, path: String, into target: CGRect) {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let targetRatio = target.width / target.height
        let sourceRatio = CGFloat(original.width) / CGFloat(original.height)
        let drawRect: CGRect
        if sourceRatio > targetRatio {
            // 图更宽：按宽度撑满，上下留边
            let h = target.width / sourceRatio
            drawRect = CGRect(x: target.minX, y: target.minY + (target.height - h) / 2,
                              width: target.width, height: h)
        } else {
            // 图更高：按高度撑满，左右留边
            let w = target.height * sourceRatio
            drawRect = CGRect(x: target.minX + (target.width - w) / 2, y: target.minY,
                              width: w, height: target.height)
        }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(original, in: rect(drawRect))
        ctx.restoreGState()
    }

    /// 画板信息模块共用的文字层级。模块空间不足时可以向下收缩，但不再各自向上放大，
    /// 避免 Home Assistant、打印机、系统监控、额度与网络模块之间出现明显字号跳变。
    public static func canvasTypography() -> (label: CGFloat, value: CGFloat, body: CGFloat) {
        (label: 9, value: 12, body: 10)
    }

    /// Bambu 画板模块字号。键盘灵犀画板的旧下限只有 7–8pt，多台打印机均分画面后
    /// 实机几乎无法辨认；这里提高最小字号，并让空间充足时突破通用模块的字号上限。
    /// 口袋先知与摘录仍使用更大的墨水屏字号。
    public static func bambuCanvasTypography(sizeBase: CGFloat,
                                             optimizeForOracleEInk: Bool)
        -> (label: CGFloat, value: CGFloat, body: CGFloat) {
        if optimizeForOracleEInk {
            return (label: min(max(sizeBase * 0.68, 12), 16),
                    value: min(max(sizeBase * 0.78, 14), 21),
                    body: min(max(sizeBase * 0.72, 12.5), 17))
        }
        return (label: min(max(sizeBase * 0.64, 9), 11),
                value: min(max(sizeBase * 0.76, 11), 15),
                body: min(max(sizeBase * 0.68, 9), 12))
    }

    /// Bambu 画板进度条厚度。整体较旧版减少约三分之一；墨水屏仍保留足够的
    /// 二值化线宽，但不会在紧凑卡片中抢占过多纵向视觉重量。
    public static func bambuCanvasProgressBarHeight(rowHeight: CGFloat,
                                                    optimizeForOracleEInk: Bool) -> CGFloat {
        optimizeForOracleEInk
            ? min(max(rowHeight * 0.24, 5.5), 9.5)
            : min(max((rowHeight - 6) * 0.67, 2), 4.5)
    }

    /// 天气真实绘制使用的文本度量。保留一像素余量并复测缩放后的字形，
    /// 避免浮点舍入把完整的「24°」误判成超宽再变成「2…」。
    public static func weatherTextLayout(_ text: String, maxWidth: CGFloat, maxHeight: CGFloat,
                                          preferredSize: CGFloat, minSize: CGFloat = 7,
                                          bold: Bool = true, fontName: String? = nil)
        -> (text: String, size: CGFloat, width: CGFloat, height: CGFloat, fits: Bool) {
        let width = max(1, maxWidth - 1), height = max(1, maxHeight - 1)
        let minimum = min(max(1, minSize), max(1, preferredSize))
        var size = max(minimum, preferredSize)
        func dimensions(_ size: CGFloat) -> (CGFloat, CGFloat) {
            let font = CTFontCreateWithName((fontName ?? (bold ? "PingFangSC-Semibold" : "PingFangSC-Regular")) as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            let glyph = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            return (max(advance, glyph.maxX) - min(0, glyph.minX),
                    max(CTFontGetAscent(font) + CTFontGetDescent(font), glyph.height))
        }
        var measured = dimensions(size)
        size = max(minimum, min(size, size * min(width / max(1, measured.0), height / max(1, measured.1))))
        measured = dimensions(size)
        while size > minimum && (measured.0 > width || measured.1 > height) {
            size = max(minimum, size - 0.25)
            measured = dimensions(size)
        }
        return (text, size, measured.0, measured.1, measured.0 <= maxWidth && measured.1 <= maxHeight)
    }

    public static let weatherTemperatureFontName = "HelveticaNeue-Medium"

    /// 所有设备共用天气卡片：彩屏按天气分类取主题底色，墨水屏保持纯黑白。
    /// 由实际可用区域决定横向/纵向主视觉，详情不足时省略建议而不压缩温度和图标。
    private static func drawWeatherCard(_ ctx: CGContext, weather: WeatherSnapshot,
                                        band: CGRect, colors: ScreenPalette,
                                        monochrome: Bool, now: Date) {
        guard band.width > 20, band.height > 28 else { return }
        if !monochrome, band.width >= 110, band.height >= 160,
           (band.height <= band.width * 1.5 || band.height >= 300) {
            WeatherSkyRenderer.draw(ctx, weather: weather, bounds: band,
                                    coordinateHeight: CGFloat(height), safeArea: 0, now: now)
            return
        }
        let background = colors.background
        let dark = 0.299 * background.0 + 0.587 * background.1 + 0.114 * background.2 < 0.45
        let palette = weather.condition.palette(dark: dark, monochrome: monochrome)
        let weatherColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ hex: UInt32) -> CGColor {
            // 主题值与 C6 固件 RGB565 共用 sRGB，不能隐式使用 DeviceRGB 的显示器 gamma。
            CGColor(colorSpace: weatherColorSpace,
                    components: [CGFloat((hex >> 16) & 0xFF) / 255,
                                 CGFloat((hex >> 8) & 0xFF) / 255,
                                 CGFloat(hex & 0xFF) / 255, 1])!
        }
        let foreground = color(palette.foreground)
        let secondary = color(palette.secondary)
        ctx.saveGState()
        let radius = min(16, band.height * 0.1)
        ctx.addPath(CGPath(roundedRect: rect(band), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        if monochrome {
            fillRound(ctx, rect(band), radius: radius, color: color(palette.background))
        } else {
            // 逐行 sRGB 插值与 C6 的 RGB565 天空完全采用同一色表；静态绘制不增加刷新频率。
            let rows = max(1, Int(ceil(band.height)))
            for row in 0..<rows {
                ctx.setFillColor(color(palette.background(at: Double(row) / Double(max(1, rows - 1)))))
                ctx.fill(rect(band.minX, band.minY + CGFloat(row), band.width,
                              min(1, band.height - CGFloat(row))))
            }
        }
        func cloud(in frame: CGRect, tint: CGColor, opacity: CGFloat) {
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: frame.minX + x * frame.width, y: rect(frame).maxY - y * frame.height)
            }
            let outline = CGMutablePath()
            outline.move(to: point(0.19, 0.89))
            outline.addCurve(to: point(0.10, 0.57), control1: point(0.01, 0.89), control2: point(-0.01, 0.65))
            outline.addCurve(to: point(0.30, 0.52), control1: point(0.16, 0.46), control2: point(0.25, 0.46))
            outline.addCurve(to: point(0.65, 0.17), control1: point(0.29, 0.22), control2: point(0.49, 0.07))
            outline.addCurve(to: point(0.79, 0.48), control1: point(0.79, 0.22), control2: point(0.83, 0.36))
            outline.addCurve(to: point(0.94, 0.59), control1: point(0.86, 0.41), control2: point(0.96, 0.47))
            outline.addCurve(to: point(0.85, 0.89), control1: point(1.04, 0.75), control2: point(0.98, 0.89))
            outline.addCurve(to: point(0.19, 0.89), control1: point(0.64, 0.93), control2: point(0.38, 0.93))
            outline.closeSubpath()
            let base = tint.converted(to: weatherColorSpace, intent: .defaultIntent, options: nil)?.components ?? [1, 1, 1, 1]
            let darkCloud = palette.foreground == 0xF8FAFC
            let top = CGColor(colorSpace: weatherColorSpace, components: [
                base[0] + (1 - base[0]) * 0.14, base[1] + (1 - base[1]) * 0.14,
                base[2] + (1 - base[2]) * 0.14, 1])!
            let bottom = darkCloud ? color(0x35405B) : color(0xBDD1E2)
            ctx.saveGState()
            ctx.setAlpha(opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setAlpha(1)
            ctx.setShadow(offset: CGSize(width: 0, height: -frame.height * 0.05),
                          blur: frame.height * 0.18, color: color(0x244766).copy(alpha: 0.12))
            ctx.setFillColor(tint)
            ctx.addPath(outline); ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.saveGState()
            ctx.addPath(outline); ctx.clip()
            if let shading = CGGradient(colorsSpace: weatherColorSpace,
                colors: [top, tint, bottom] as CFArray, locations: [0, 0.48, 1]) {
                ctx.drawLinearGradient(shading, start: point(0.48, 0.12), end: point(0.48, 0.94),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        func sun(in frame: CGRect) {
            // 长屏纵向布局给图标的是宽矩形，但太阳仍保持球体，不随容器拉扁。
            let side = min(frame.width, frame.height)
            let square = CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2,
                                width: side, height: side)
            let target = rect(square), center = CGPoint(x: target.midX, y: target.midY)
            ctx.saveGState()
            if let halo = CGGradient(colorsSpace: weatherColorSpace,
                colors: [color(0xFFEBA5).copy(alpha: 0.36)!, color(0xFFEBA5).copy(alpha: 0)!] as CFArray,
                locations: [0, 1]) {
                ctx.drawRadialGradient(halo, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: side * 0.68, options: [])
            }
            let disk = target.insetBy(dx: target.width * 0.14, dy: target.height * 0.14)
            ctx.addEllipse(in: disk); ctx.clip()
            if let sunlight = CGGradient(colorsSpace: weatherColorSpace,
                colors: [color(0xFFF2AD), color(0xFFD761), color(0xFFBD43)] as CFArray,
                locations: [0, 0.55, 1]) {
                ctx.drawRadialGradient(sunlight,
                    startCenter: CGPoint(x: disk.midX - disk.width * 0.17, y: disk.midY + disk.height * 0.18), startRadius: 0,
                    endCenter: center, endRadius: disk.width * 0.56, options: [.drawsAfterEndLocation])
            }
            ctx.restoreGState()
        }
        if !monochrome {
            let skyCloud = CGRect(x: band.maxX - band.width * 0.51,
                                  y: band.minY + band.height * 0.12,
                                  width: band.width * 0.65, height: min(62, band.width * 0.28))
            switch weather.condition {
            case .sunny, .cloudy:
                let sunlight = color(0xFFEAA6)
                let center = CGPoint(x: band.maxX - band.width * 0.17,
                                     y: rect(band).maxY - band.height * 0.24)
                if let glow = CGGradient(colorsSpace: weatherColorSpace,
                    colors: [sunlight.copy(alpha: 0.32)!, sunlight.copy(alpha: 0)!] as CFArray,
                    locations: [0, 1]) {
                    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0,
                                           endCenter: center, endRadius: band.width * 0.42, options: [])
                }
                if weather.condition == .cloudy {
                    // 背景只保留远处云层；唯一的太阳在主视觉内半遮于云后，不与标头争抢。
                    cloud(in: skyCloud.offsetBy(dx: -band.width * 0.12, dy: -band.height * 0.025),
                          tint: color(palette.cloud), opacity: 0.20)
                    cloud(in: skyCloud.offsetBy(dx: band.width * 0.10, dy: band.height * 0.035),
                          tint: color(palette.cloud), opacity: 0.45)
                }
            case .fog:
                for index in 0..<3 {
                    let line = CGRect(x: band.minX + band.width * CGFloat(index) * 0.08,
                                      y: band.minY + band.height * (0.20 + CGFloat(index) * 0.12),
                                      width: band.width * 0.86, height: max(3, band.height * 0.022))
                    fillRound(ctx, rect(line), radius: line.height / 2,
                              color: color(palette.cloud).copy(alpha: 0.30)!)
                }
            case .overcast, .drizzle, .rain, .snow, .thunderstorm, .unknown:
                cloud(in: skyCloud, tint: color(palette.cloud), opacity: 0.64)
                cloud(in: skyCloud.offsetBy(dx: -band.width * 0.25, dy: -band.height * 0.045),
                      tint: color(palette.cloud), opacity: 0.26)
                if weather.condition == .rain || weather.condition == .drizzle {
                    for index in 0..<5 {
                        let x = band.maxX - band.width * (0.10 + CGFloat(index) * 0.062)
                        let y = skyCloud.maxY + 9 + CGFloat(index % 2) * 8
                        ctx.setStrokeColor(color(palette.cloud).copy(alpha: 0.55)!)
                        ctx.setLineWidth(2)
                        ctx.move(to: CGPoint(x: x, y: rect(band).maxY - (y - band.minY)))
                        ctx.addLine(to: CGPoint(x: x - 4, y: rect(band).maxY - (y - band.minY) - 11))
                        ctx.strokePath()
                    }
                } else if weather.condition == .snow {
                    ctx.setStrokeColor(color(palette.cloud).copy(alpha: 0.70)!)
                    ctx.setLineWidth(1.5)
                    for index in 0..<4 {
                        let x = band.maxX - band.width * (0.11 + CGFloat(index) * 0.08)
                        let y = rect(band).maxY - band.height * (0.31 + CGFloat(index % 2) * 0.075)
                        for angle in [0.0, Double.pi / 3, Double.pi * 2 / 3] {
                            let dx = CGFloat(cos(angle)) * 4, dy = CGFloat(sin(angle)) * 4
                            ctx.move(to: CGPoint(x: x - dx, y: y - dy))
                            ctx.addLine(to: CGPoint(x: x + dx, y: y + dy))
                            ctx.strokePath()
                        }
                    }
                }
            }
        }
        if monochrome {
            strokeRound(ctx, rect(band.insetBy(dx: 0.5, dy: 0.5)), radius: radius,
                        color: foreground, width: 1)
        }
        let padding = min(12, max(4, band.width * 0.05))
        let inner = band.insetBy(dx: padding, dy: padding)
        let gap = min(8, max(3, inner.height * 0.02))
        func label(_ text: String, in frame: CGRect, preferred: CGFloat,
                   minimum: CGFloat = 9, bold: Bool = true, color: CGColor, fontName: String? = nil) {
            let layout = weatherTextLayout(text, maxWidth: frame.width, maxHeight: frame.height,
                                           preferredSize: preferred, minSize: minimum, bold: bold, fontName: fontName)
            drawText(ctx, layout.text, size: layout.size, bold: bold, color: color,
                     in: rect(frame), align: .center, fontName: fontName)
        }
        func icon(in frame: CGRect) {
            if !monochrome && weather.condition == .sunny {
                sun(in: frame)
                return
            }
            if !monochrome && weather.condition == .cloudy {
                sun(in: CGRect(x: frame.minX - frame.width * 0.02, y: frame.minY - frame.height * 0.03,
                               width: frame.width * 0.72, height: frame.height * 0.72))
                cloud(in: CGRect(x: frame.minX + frame.width * 0.04, y: frame.minY + frame.height * 0.28,
                                  width: frame.width * 0.94, height: frame.height * 0.65),
                      tint: color(palette.cloud), opacity: 1)
                return
            }
            guard let icon = symbolImage(weather.condition.symbolName,
                                         pointSize: min(frame.width, frame.height),
                                         color: monochrome ? foreground : color(palette.symbol)) else { return }
            let target = rect(frame)
            let scale = min(target.width / CGFloat(icon.width), target.height / CGFloat(icon.height))
            let size = CGSize(width: CGFloat(icon.width) * scale, height: CGFloat(icon.height) * scale)
            ctx.draw(icon, in: CGRect(x: target.midX - size.width / 2,
                                     y: target.midY - size.height / 2, width: size.width, height: size.height))
        }
        // 多模块画板给天气的空间很小时，只保留状态与温度，不能硬塞完整详情。
        if band.height < 80 {
            let hasTitle = inner.height >= 36
            let titleH: CGFloat = hasTitle ? 13 : 0
            if hasTitle {
                label(weather.city + " · " + weather.description,
                      in: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: titleH),
                      preferred: 11, color: foreground)
            }
            let heroY = inner.minY + titleH + (hasTitle ? gap : 0)
            let heroH = max(12, inner.maxY - heroY)
            let iconSize = min(26, heroH, inner.width * 0.24)
            let content = hasTitle ? String(format: "%.0f°", weather.temperature)
                : String(format: "%.0f° · ", weather.temperature) + weather.description
            let size = min(25, max(12, heroH * 0.8))
            let textW = min(max(10, inner.width - iconSize - gap),
                            measureTextWidth(content, size: size, bold: true))
            let x = inner.midX - (textW + gap + iconSize) / 2
            label(content, in: CGRect(x: x, y: heroY, width: textW, height: heroH),
                  preferred: size, color: foreground, fontName: weatherTemperatureFontName)
            icon(in: CGRect(x: x + textW + gap, y: heroY + (heroH - iconSize) / 2,
                            width: iconSize, height: iconSize))
            ctx.restoreGState()
            return
        }
        let titleH = min(28, max(14, inner.height * 0.12))
        let detailLineH = min(22, max(13, inner.height * 0.095))
        let twoDetailRows = inner.width < 150 && inner.height > 110
        let detailH = detailLineH * (twoDetailRows ? 2 : 1)
        let adviceLineH = min(22, max(16, inner.height * 0.085))
        let adviceH = inner.height >= 160 ? adviceLineH * 2 : 0
        let footerH: CGFloat = inner.height >= 82 ? 12 : 0
        let totalGaps = gap * (2 + (adviceH > 0 ? 1 : 0) + (footerH > 0 ? 1 : 0))
        let heroH = max(18, inner.height - titleH - detailH - adviceH - footerH - totalGaps)
        label(weather.city + " · " + weather.description,
              in: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: titleH),
              preferred: min(20, max(12, titleH * 0.75)), color: foreground)
        let hero = CGRect(x: inner.minX, y: inner.minY + titleH + gap,
                          width: inner.width, height: heroH)
        let temperature = String(format: "%.0f°", weather.temperature)
        let iconFrame: CGRect
        let temperatureFrame: CGRect
        if inner.width < 150 && hero.height > 90 {
            let iconH = min(56, hero.height * 0.42)
            iconFrame = CGRect(x: hero.minX, y: hero.minY, width: hero.width, height: iconH)
            temperatureFrame = CGRect(x: hero.minX, y: iconFrame.maxY + gap,
                                      width: hero.width, height: max(18, hero.height - iconH - gap))
        } else {
            let iconSize = min(72, hero.height * 0.84, hero.width * 0.30)
            let fontSize = min(64, max(18, hero.height * 0.8))
            let availableTextW = max(20, hero.width - iconSize - gap)
            let textWidth = min(availableTextW, measureTextWidth(temperature, size: fontSize, bold: true))
            let groupWidth = textWidth + gap + iconSize
            let x = hero.midX - groupWidth / 2
            temperatureFrame = CGRect(x: x, y: hero.minY, width: textWidth, height: hero.height)
            iconFrame = CGRect(x: temperatureFrame.maxX + gap, y: hero.midY - iconSize / 2,
                               width: iconSize, height: iconSize)
        }
        label(temperature, in: temperatureFrame,
              preferred: min(64, max(18, temperatureFrame.height * 0.8)), color: foreground,
              fontName: weatherTemperatureFontName)
        icon(in: iconFrame)
        var y = hero.maxY + gap
        let range = String(format: "%.0f–%.0f°", weather.low, weather.high)
        let rain = "降雨 \(min(100, max(0, weather.rainProbability)))%"
        let detailSize = min(17, max(10, detailLineH * 0.78))
        if twoDetailRows {
            for line in [range, rain] {
                label(line, in: CGRect(x: inner.minX, y: y, width: inner.width, height: detailLineH),
                      preferred: min(detailSize, 15), bold: monochrome, color: foreground)
                y += detailLineH
            }
        } else {
            label(range + "  " + rain,
                  in: CGRect(x: inner.minX, y: y, width: inner.width, height: detailH),
                  preferred: min(detailSize, 15), bold: monochrome, color: foreground)
            y += detailH
        }
        if adviceH > 0 {
            y += gap
            for advice in [weather.clothing, weather.carWash] {
                label(advice, in: CGRect(x: inner.minX, y: y, width: inner.width, height: adviceLineH),
                      preferred: min(14, adviceLineH * 0.72), bold: monochrome, color: secondary)
                y += adviceLineH
            }
        }
        if footerH > 0 {
            let stale = now.timeIntervalSince(weather.updatedAt) > 3 * 3600
            let stamp = "\(stale ? "缓存 · " : "")\(formatDate(weather.updatedAt, "HH:mm")) · Open-Meteo"
            label(stamp, in: CGRect(x: inner.minX, y: inner.maxY - footerH,
                                   width: inner.width, height: footerH),
                  preferred: 10, minimum: 7, bold: false, color: secondary)
        }
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
                                         grokBot: GrokBotUsageSnapshot = .notConfigured,
                                         cloudflare: CloudflareUsageSnapshot = .notConfigured,
                                         sspaiArticles: [SspaiArticle], ha: HASnapshot, now: Date,
                                         formlabsItems: [FormlabsCanvasItem] = [],
                                         imageOverlayOnly: Bool = false,
                                         nowPlayingSmartBg: Bool = false,
                                         nowPlayingShowCover: Bool? = nil,
                                         canvasCoverBgActive: Bool = false,
                                         fullWidth: Bool = false,
                                         deviceCanvas: Bool = false,
                                         nowPlayingHorizontal: Bool = false,
                                         canvasImagePath: String? = nil,
                                         accentOverride: CGColor? = nil,
                                         printerFields: [Int: CanvasPrinterFields] = [:],
                                         optimizeBambuForOracleEInk: Bool = false,
                                         bambuHeroLayout: Bool = false,
                                         showBambuCamera: Bool = true,
                                         compactBambuSummary: Bool = false,
                                         singleModuleCanvas: Bool = false,
                                         hideBambuLargeStatusText: Bool = false,
                                         monochromeDeviceCanvas: Bool = true) {
        let w = band.width
        let typography = canvasTypography()
        switch module {
        case .weather:
            guard let weather = settings.weatherSnapshot else {
                drawText(ctx, "天气 · 请先选择城市", size: 14, bold: true, color: colors.primaryTextCG, in: rect(band), align: .center)
                break
            }
            drawWeatherCard(ctx, weather: weather, band: band, colors: colors,
                            monochrome: deviceCanvas && monochromeDeviceCanvas, now: now)
        case .homeAssistant:
            if deviceCanvas, !monochromeDeviceCanvas, band.width >= 140, band.height >= 56 {
                drawSquareHomeAssistant(ctx, snapshot: ha, band: band, colors: colors)
                break
            }
            if ha.selectedEntities.count == 1, let entity = ha.selectedEntities.first {
                // 单实体：图标 + 实体名（左）+ 状态值大字（右，含单位；on/off 映射开/关）
                drawEntityIcon(ctx, symbol: SFIconMapper.symbol(for: entity),
                               in: rect(band.minX + 2, band.minY + 1, 13, 13),
                               color: colors.secondaryTextCG)
                let label = entity.displayName
                let value = entity.displayValue
                var size = min(band.height * 0.55, typography.value)
                var tw = measureTextWidth(value, size: size, bold: true)
                if tw > w - 8 {
                    size = max(size * (w - 8) / tw, 9)
                    tw = measureTextWidth(value, size: size, bold: true)
                }
                let h1 = max(band.height * 0.45, 12)
                drawText(ctx, label, size: typography.label, bold: false, color: colors.secondaryTextCG,
                         in: rect(band.minX + 16, band.minY, w - 16, h1), align: .left)
                drawText(ctx, value, size: size, bold: true, color: colors.primaryTextCG,
                         in: rect(band.minX + 16, band.minY + h1, w - 16, band.height - h1), align: .right)
            } else if !ha.selectedEntities.isEmpty || !ha.missingEntityIDs.isEmpty {
                // 多实体：两端对齐（名称左 / 状态右），名称完整显示——
                // 字号先收缩，仍放不下就折第二行（与键盘「Home Assistant」卡片同一套排布），
                // 图标跟随名称首行对齐、不遮挡状态值；失效绑定排在后面灰显并保留最后已知值
                let cX0 = band.minX + 16
                let cX1 = band.maxX - 2
                let rowGap: CGFloat = 2
                var y = band.minY
                struct Row { let name: String; let value: String; let icon: String
                    let picture: Data?; let off: Bool; let stale: Bool }
                var rows: [Row] = ha.selectedEntities.map { entity in
                    Row(name: ha.aliases[entity.entityId] ?? entity.displayName,
                        value: entity.displayValue,
                        icon: SFIconMapper.symbol(for: entity),
                        picture: ha.picture(for: entity.entityId),
                        off: entity.state.lowercased() == "off", stale: false)
                }
                for stale in ha.missingRows() {
                    rows.append(Row(name: stale.name,
                                    value: stale.lastValue.isEmpty ? "失效" : "失效 · \(stale.lastValue)",
                                    icon: "exclamationmark.triangle",
                                    picture: nil, off: false, stale: true))
                }
                var rendered = 0
                for row in rows {
                    let availableW = cX1 - cX0
                    let stacked = haRowUsesStackedLayout(name: row.name, value: row.value,
                                                         availableWidth: availableW,
                                                         nameSize: typography.label,
                                                         valueSize: typography.body)
                    if stacked {
                        var nameSize = typography.label
                        while nameSize > 7 && measureTextWidth(row.name, size: nameSize, bold: false) > availableW {
                            nameSize -= 0.5
                        }
                        let nameLines = fileNameLines(row.name, size: nameSize,
                                                      maxW: availableW, maxLines: 2)
                        var valueSize = typography.body
                        while valueSize > 7 && measureTextWidth(row.value, size: valueSize, bold: true) > availableW {
                            valueSize -= 0.5
                        }
                        let valueLines = fileNameLines(row.value, size: valueSize,
                                                       maxW: availableW, maxLines: 2)
                        let nameLineH = max(nameSize * 1.2, 8)
                        let valueLineH = max(valueSize * 1.2, 8)
                        let nameH = nameLineH * CGFloat(max(nameLines.count, 1))
                        let valueH = valueLineH * CGFloat(max(valueLines.count, 1))
                        let rowH = nameH + valueH + 1
                        if y + rowH > band.maxY { break }

                        let iconSize: CGFloat = 12
                        let iconBox = CGRect(x: band.minX + 2,
                                             y: y + (nameLineH - iconSize) / 2,
                                             width: iconSize, height: iconSize)
                        if let picture = row.picture {
                            drawImageData(ctx, data: picture, into: iconBox, cover: true, radius: 3)
                        } else {
                            drawEntityIcon(ctx, symbol: row.icon, in: rect(iconBox),
                                           color: (row.off || row.stale) ? colors.secondaryTextCG : colors.primaryTextCG)
                        }
                        let nameColor = row.stale ? colors.tertiaryTextCG : colors.secondaryTextCG
                        for (li, line) in nameLines.enumerated() {
                            drawText(ctx, line, size: nameSize, bold: false, color: nameColor,
                                     in: rect(cX0, y + CGFloat(li) * nameLineH,
                                              availableW, nameLineH), align: .left)
                        }
                        for (li, line) in valueLines.enumerated() {
                            drawText(ctx, line, size: valueSize, bold: true,
                                     color: (row.off || row.stale) ? colors.secondaryTextCG : colors.primaryTextCG,
                                     in: rect(cX0, y + nameH + 1 + CGFloat(li) * valueLineH,
                                              availableW, valueLineH), align: .right)
                        }
                        rendered += 1
                        y += rowH + rowGap
                        continue
                    }
                    // 状态区：右对齐，宽度按文本自适应（最短 16、最长 45）
                    var vs = typography.body
                    while vs > 7 && measureTextWidth(row.value, size: vs, bold: true) > 45 { vs -= 0.5 }
                    let valueW = min(max(measureTextWidth(row.value, size: vs, bold: true) + 2, 16), 45)
                    let nameMaxW = (cX1 - cX0) - valueW - 6
                    // 名称：字号从 8 收缩到 6，仍放不下就折两行
                    var nameSize = typography.label
                    while nameSize > 7 && measureTextWidth(row.name, size: nameSize, bold: false) > nameMaxW {
                        nameSize -= 0.5
                    }
                    let nameLines = fileNameLines(row.name, size: nameSize,
                                                  maxW: nameMaxW, maxLines: 2)
                    let lineH = nameSize * 1.25
                    let rowH = max(nameSize * 1.3, nameSize * 1.25 * CGFloat(nameLines.count) + 1, 14)
                    if y + rowH > band.maxY { break }
                    // 图标：与名称首行居中对齐（有画面的实体画缩略图）
                    let iconSize: CGFloat = 12
                    let iconBox = CGRect(x: band.minX + 2, y: y + (lineH - iconSize) / 2,
                                         width: iconSize, height: iconSize)
                    if let picture = row.picture {
                        drawImageData(ctx, data: picture, into: iconBox, cover: true, radius: 3)
                    } else {
                        drawEntityIcon(ctx, symbol: row.icon, in: rect(iconBox),
                                       color: (row.off || row.stale) ? colors.secondaryTextCG : colors.primaryTextCG)
                    }
                    let nameColor = row.stale ? colors.tertiaryTextCG : colors.secondaryTextCG
                    for (li, line) in nameLines.enumerated() {
                        drawText(ctx, line, size: nameSize, bold: false, color: nameColor,
                                 in: rect(cX0, y + CGFloat(li) * lineH, nameMaxW, lineH), align: .left)
                    }
                    // 状态值：右对齐贴右缘，垂直居中于整行（与名称区互不重叠）
                    drawText(ctx, row.value, size: vs, bold: true,
                             color: (row.off || row.stale) ? colors.secondaryTextCG : colors.primaryTextCG,
                             in: rect(cX1 - valueW, y, valueW, rowH), align: .right)
                    rendered += 1
                    y += rowH + rowGap
                }
                let totalRows = rows.count
                if totalRows > rendered {
                    drawText(ctx, "+\(totalRows - rendered)", size: 7, bold: false,
                             color: colors.tertiaryTextCG,
                             in: rect(band.minX + 16, band.maxY - 10, w - 18, 10), align: .right)
                }
            } else {
                // 未选择实体/加载失败：明确错误而非空白
                let msg = ha.errorText ?? (settings.haServerURL.isEmpty
                        ? "未连接 Home Assistant" : "未选择实体")
                drawText(ctx, msg, size: 9, bold: false, color: colors.secondaryTextCG,
                         in: rect(band.minX, band.minY, w, band.height), align: .center)
            }
        case .bambuLab, .bambuLab2, .bambuLab3, .bambuLab4, .bambuLab5:
            // Bambu Lab 打印机状态（画板模块）：按模块对应的卡片位取打印机（bambuLab→第 1 台…），
            // 显示哪些信息由该模块的显示选项决定（状态/进度/任务/喷嘴/热床/剩余/错误），
            // 模块高度按已开启行数均分 → 上下边距调节能直接看到行高变化
            let slot = module.bambuSlotIndex ?? 0
            let bambu = settings.bambuSettings(atSlot: slot)
                ?? BambuLabCardSettings(name: slot == 0 ? "打印机" : "打印机 \(slot + 1)")
            let fields = printerFields[module.rawValue] ?? settings.canvasPrinterFields(for: module)
            let status = ha.entities.first { $0.entityId == bambu.statusEntityID }
            let progress = ha.entities.first { $0.entityId == bambu.progressEntityID }
            let task = ha.entities.first { $0.entityId == bambu.taskEntityID }
            let nozzle = ha.entities.first { $0.entityId == bambu.nozzleTempEntityID }
            let bed = ha.entities.first { $0.entityId == bambu.bedTempEntityID }
            let timeEntity = ha.entities.first { $0.entityId == bambu.selectedTimeEntityID }
            let error = ha.entities.first { $0.entityId == bambu.errorEntityID }
            let hasStatusBinding = !bambu.statusEntityID
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let rawStatus = status?.state ?? ""
            let statusText = status.map { BambuStatusText.map($0.state) } ?? "未配置"
            let errorStaleSeconds = TimeInterval(max(10, max(1, settings.haRefreshMinutes) * 2) * 60)
            let isError = status?.state.lowercased() == "error"
                || (error.map { e -> Bool in
                    let s = e.state.trimmingCharacters(in: .whitespaces).lowercased()
                    return !s.isEmpty && !["none", "无", "normal", "ok", "0", "off", "unavailable", "unknown"].contains(s)
                        && HAErrorCodePolicy.isFresh(entity: e, staleSeconds: errorStaleSeconds)
                } ?? false)
            let printerLabel = bambu.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // 口袋先知的 Bambu 模块固定白底纯黑字：不再随深色主题切换成白字，
            // 保证黑白量化及误差扩散前拿到的是最大黑度，细笔画不会被抖动吃掉。
            let pureBlack = CGColor(gray: 0, alpha: 1)
            let pureWhite = CGColor(gray: 1, alpha: 1)
            let primaryText = optimizeBambuForOracleEInk ? pureBlack : colors.primaryTextCG
            let secondaryText = optimizeBambuForOracleEInk ? pureBlack : colors.secondaryTextCG
            let alertText = optimizeBambuForOracleEInk ? pureBlack : colors.accentCG
            let progressInk = optimizeBambuForOracleEInk
                ? pureBlack : (accentOverride ?? colors.accentCG)
            // 轨道用稳定浅灰显示未完成部分。墨水屏保留深浅反色描边；
            // 灵犀画板则与 Formlabs 共用主题卡片描边，避免深色模式出现突兀白框。
            let progressTrack = optimizeBambuForOracleEInk
                ? CGColor(gray: 0.82, alpha: 1) : colors.borderCG
            let adaptiveOutline = colors.cg(einkDeepColorRGB(against: colors.background))
            let baseContentBand: CGRect
            if optimizeBambuForOracleEInk {
                fillRound(ctx, rect(band), radius: 7, color: pureWhite)
                strokeRound(ctx, rect(band), radius: 7, color: adaptiveOutline, width: 1.5)
                // 模块很多、条带很矮时保留至少 2 px 内容高度，避免 inset 产生负尺寸。
                let horizontalInset = min(6, max((band.width - 12) / 2, 0))
                let verticalInset = min(4, max((band.height - 2) / 2, 0))
                baseContentBand = band.insetBy(dx: horizontalInset, dy: verticalInset)
            } else {
                // 灵犀画板的 Bambu / Formlabs 使用同一组卡片指标：
                // 主题内嵌底色、低对比边框、相同圆角和自适应内边距。
                fillRound(ctx, rect(band), radius: 7, color: colors.insetCG)
                strokeRound(ctx, rect(band), radius: 7, color: colors.borderCG, width: 1)
                // 标头到左上角使用固定距离：卡片高度变化时不再上下漂移。
                let horizontalInset: CGFloat = 5
                let verticalInset: CGFloat = 4
                baseContentBand = band.insetBy(dx: horizontalInset, dy: verticalInset)
            }
            let heroEnabled = bambuHeroLayout && fields.showProgress && progress != nil
            // 新仪表布局在模块底部保留一行清晰的数据更新时间；条带过矮时自动省略。
            let footerH: CGFloat = heroEnabled && baseContentBand.height >= 72
                ? (compactBambuSummary
                    ? min(max(baseContentBand.height * 0.08, 11), 14)
                    : min(max(baseContentBand.height * 0.10, 15), 22))
                : 0
            let contentBand = CGRect(x: baseContentBand.minX, y: baseContentBand.minY,
                                     width: baseContentBand.width,
                                     height: max(baseContentBand.height - footerH - (footerH > 0 ? 2 : 0), 2))
            let contentWidth = contentBand.width
            // 口袋先知/摘录不显示摄像头帧；选择“任务图片”时仍可按用户的画面开关显示封面。
            let selectedPictureAllowed = showBambuCamera || bambu.imageSource != .camera
            let picture = (selectedPictureAllowed && fields.showImage
                           && !bambu.selectedImageEntityID.isEmpty)
                ? ha.picture(for: bambu.selectedImageEntityID) : nil
            let taskText = task?.displayState.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // 高卡允许任务标题两行；混排到单卡高度被压缩后强制单行，
            // 把纵向空间还给进度和详情。不依赖卡片数量，因此与其他模块混排也正确。
            let allowsTwoLineTask = optimizeBambuForOracleEInk || baseContentBand.height >= 150
            let taskNeedsTwoLines = allowsTwoLineTask && !taskText.isEmpty
                && measureTextWidth(taskText, size: 15, bold: optimizeBambuForOracleEInk)
                    > max(contentBand.width - 4, 10)

            // 已开启且有内容的行（错误行仅在真正报错时占位）
            var rows: [Int] = []
            if heroEnabled {
                // 名称、任务和进度由同一个主信息区按固定顺序排布，任务不会再落到
                // 进度条下方。状态缩进名称行右侧，避免额外占用一整行。
                rows.append(8)
            } else {
                if fields.showStatus && hasStatusBinding { rows.append(0) }
                if fields.showProgress, progress != nil { rows.append(1) }
            }
            if !heroEnabled, fields.showTask, let t = task, !t.state.isEmpty { rows.append(2) }
            // 灵犀画板里同时放多台打印机时，把喷嘴与热床合成一行，省下的高度返还给
            // 设备名、状态和进度；单打印机及两个独立画板继续保留原来的分行结构。
            if compactBambuSummary, fields.showNozzleTemp || fields.showBedTemp,
               nozzle != nil || bed != nil {
                rows.append(9)
            } else {
                if fields.showNozzleTemp, nozzle != nil { rows.append(3) }
                if fields.showBedTemp, bed != nil { rows.append(4) }
            }
            if fields.showRemaining, let r = timeEntity, !r.state.isEmpty,
               r.state.lowercased() != "unknown",
               // 新仪表布局统一把时间放到进度条右侧，不再额外占一行。
               !heroEnabled { rows.append(5) }
            if fields.showError, isError { rows.append(6) }
            if picture != nil { rows.append(7) }
            if rows.isEmpty { rows = [0] }
            // 行高按权重分配：画面行占更多空间，文字行保持原有字号基准
            let weights = rows.map { kind -> CGFloat in
                if kind == 7 { return 2.4 }
                // 多打印机摘要的头部只放一行名称/状态和一条细进度，不再为超大百分比
                // 预留三行权重；释放的高度用于任务、温度与时间，避免全部开启时堆叠。
                if kind == 8 {
                    // 主信息区内嵌任务名；双行任务相应增加高度，但仍作为一个连续卡片头。
                    if fields.showTask && !taskText.isEmpty {
                        return taskNeedsTwoLines ? 3.25 : 2.75
                    }
                    return 2.0
                }
                if kind == 2 && taskNeedsTwoLines { return 1.55 }
                if compactBambuSummary && (kind == 5 || kind == 9) { return 1.12 }
                return 1.0
            }
            let totalWeight = max(weights.reduce(0, +), 0.001)
            let textRowCount = max(rows.filter { $0 != 7 && $0 != 8 }.count, 1)
            let textRowH = contentBand.height / CGFloat(textRowCount)
            let rowH = contentBand.height / CGFloat(rows.count)
            var rowTops: [CGFloat] = []
            var rowHeights: [CGFloat] = []
            var cursor = contentBand.minY
            for weight in weights {
                let h = contentBand.height * weight / totalWeight
                rowTops.append(cursor)
                rowHeights.append(h)
                cursor += h
            }
            let sizeBase = rows.contains(7) ? min(rowH * 2, textRowH) : rowH
            let bambuTypography = bambuCanvasTypography(
                sizeBase: sizeBase, optimizeForOracleEInk: optimizeBambuForOracleEInk)
            let labelSize = bambuTypography.label
            let valueSize = bambuTypography.value
            let bodySize = bambuTypography.body
            for (i, kind) in rows.enumerated() {
                let rowRect = CGRect(x: contentBand.minX, y: rowTops[i],
                                     width: contentWidth, height: rowHeights[i])
                switch kind {
                case 8:
                    let value = min(max(Double(progress?.state ?? "") ?? 0, 0), 100)
                    // 两类打印机统一为「设备名/状态 → 任务名 → 进度」的信息顺序。
                    // 横向墨水屏使用更大的字号与轨道，灵犀画板维持紧凑但不再叠字。
                    let preferredHeaderH: CGFloat = optimizeBambuForOracleEInk
                        ? 21 : min(max(baseContentBand.height * 0.13, 15), 18)
                    let headerH = min(preferredHeaderH, max(rowRect.height * 0.34, 8))
                    let statusColor = isError ? alertText : primaryText
                    let nameWidth = rowRect.width * 0.56
                    drawAdaptiveText(ctx, printerLabel.isEmpty ? "打印机" : printerLabel,
                                     maxSize: optimizeBambuForOracleEInk ? 15 : 11,
                                     minSize: 8.5, bold: true, color: primaryText,
                                     in: rect(rowRect.minX, rowRect.minY,
                                              nameWidth, headerH), align: .left)
                    if fields.showStatus && hasStatusBinding {
                        let statusX = rowRect.minX + nameWidth + 3
                        let statusW = max(rowRect.maxX - statusX, 12)
                        let statusNeedsIcon = statusText.count > 4
                            || measureTextWidth(statusText,
                                                size: optimizeBambuForOracleEInk ? 13 : 9.5,
                                                bold: true) > statusW
                        if statusNeedsIcon {
                            let compact = bambuCompactStatusPresentation(rawState: rawStatus,
                                                                          isError: isError)
                            let iconSide: CGFloat = optimizeBambuForOracleEInk ? 12 : 10
                            let statusLabelSize = adaptiveFontSize(
                                compact.label,
                                maxSize: optimizeBambuForOracleEInk ? 12.5 : 9.5,
                                minSize: 7.5, bold: true,
                                maxWidth: max(statusW - iconSide - 3, 8))
                            let labelW = measureTextWidth(compact.label,
                                                          size: statusLabelSize, bold: true)
                            let groupW = min(iconSide + 3 + labelW, statusW)
                            let groupX = rowRect.maxX - groupW
                            drawEntityIcon(ctx, symbol: compact.symbol,
                                           in: rect(groupX,
                                                    rowRect.minY + (headerH - iconSide) / 2,
                                                    iconSide, iconSide), color: statusColor)
                            drawText(ctx, compact.label, size: statusLabelSize, bold: true,
                                     color: statusColor,
                                     in: rect(groupX + iconSide + 3, rowRect.minY,
                                              max(groupW - iconSide - 3, 8), headerH),
                                     align: .right)
                        } else {
                            drawAdaptiveText(ctx, statusText,
                                             maxSize: optimizeBambuForOracleEInk ? 13 : 9.5,
                                             minSize: 8, bold: true, color: statusColor,
                                             in: rect(statusX, rowRect.minY, statusW, headerH),
                                             align: .right)
                        }
                    }

                    // 标头和下方任务/进度属于两个明确信息区。墨水屏使用最深反差色，
                    // 键盘画板沿用主题边框色，避免二值化后分隔线消失。
                    let dividerY = rowRect.minY + headerH + 1
                    drawLine(ctx, x1: rowRect.minX, y1: dividerY,
                             x2: rowRect.maxX, y2: dividerY,
                             color: optimizeBambuForOracleEInk
                                ? adaptiveOutline : colors.borderCG)

                    let progressRowH: CGFloat = optimizeBambuForOracleEInk ? 23 : 16
                    let headerGap: CGFloat = optimizeBambuForOracleEInk ? 4 : 5
                    let availableTaskH = max(rowRect.height - headerH - headerGap - progressRowH - 4, 0)
                    let wantedTaskH: CGFloat = taskNeedsTwoLines
                        ? (optimizeBambuForOracleEInk ? 35 : 27)
                        : (optimizeBambuForOracleEInk ? 20 : 16)
                    let taskH = fields.showTask && !taskText.isEmpty
                        ? min(wantedTaskH, availableTaskH) : 0
                    if taskH > 7 {
                        let taskRect = CGRect(x: rowRect.minX,
                                              y: rowRect.minY + headerH + headerGap,
                                              width: rowRect.width, height: taskH)
                        if taskNeedsTwoLines {
                            drawBambuCanvasTask(ctx, taskText, in: taskRect,
                                                preferredSize: optimizeBambuForOracleEInk ? 14 : 10.5,
                                                color: primaryText, bold: true)
                        } else {
                            drawAdaptiveText(ctx, taskText,
                                             maxSize: optimizeBambuForOracleEInk ? 14 : 10.5,
                                             minSize: 7.5, bold: true, color: primaryText,
                                             in: rect(taskRect), align: .center)
                        }
                    }

                    let progressTop = rowRect.minY + headerH + headerGap
                        + taskH + (taskH > 0 ? 3 : 1)
                    let progressArea = CGRect(x: rowRect.minX, y: progressTop,
                                              width: rowRect.width,
                                              height: max(rowRect.maxY - progressTop, 2))
                    let pctText = String(format: "%.0f%%", value)
                    let compactTime = fields.showRemaining
                        ? timeEntity.flatMap { entity -> String? in
                            let state = entity.state.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !state.isEmpty, state.lowercased() != "unknown" else { return nil }
                            return bambuCompactCanvasTimeText(entity, mode: bambu.timeDisplayMode)
                        } : nil
                    let progressMeta = compactTime.map { "\(pctText) · \($0)" } ?? pctText
                    let desiredMetaSize: CGFloat = optimizeBambuForOracleEInk ? 12.5 : 10
                    let metaPreferredSize = min(desiredMetaSize,
                                                max(progressArea.height * 0.62, 6))
                    let metaWidth = min(max(measureTextWidth(progressMeta,
                                                             size: metaPreferredSize,
                                                             bold: true) + 3,
                                                optimizeBambuForOracleEInk ? 42 : 29),
                                        progressArea.width * 0.60)
                    let desiredBarH: CGFloat = optimizeBambuForOracleEInk ? 6 : 3.5
                    let barH = min(desiredBarH, max(progressArea.height - 2, 2))
                    let progressWidth = max(progressArea.width - metaWidth - 7, 14)
                    let progressBounds = rect(progressArea.minX,
                                              progressArea.minY + max((progressArea.height - barH) / 2, 0),
                                              progressWidth, barH)
                    drawProgress(ctx, progressBounds, progress: value / 100,
                                 accent: progressInk, background: progressTrack)
                    strokeRound(ctx, progressBounds, radius: barH / 2,
                                color: optimizeBambuForOracleEInk ? adaptiveOutline : colors.borderCG,
                                width: optimizeBambuForOracleEInk ? 1.5 : 0.8)
                    drawAdaptiveText(ctx, progressMeta, maxSize: metaPreferredSize,
                                     minSize: 7.5, bold: true, color: primaryText,
                                     in: rect(progressArea.maxX - metaWidth,
                                              progressArea.minY, metaWidth,
                                              progressArea.height), align: .right)
                case 0:
                    // 状态行：打印机名（左）+ 状态大字（右）。全部映射均为空时
                    // rows 的兜底仍会进入这里，但只显示设备名，不把“未配置”冒充状态。
                    drawAdaptiveText(ctx, printerLabel.isEmpty ? "打印机" : printerLabel,
                                     maxSize: labelSize, minSize: 8.5,
                                     bold: true, color: secondaryText,
                                     in: rect(rowRect.minX, rowRect.minY,
                                              hasStatusBinding ? contentWidth * 0.42 : contentWidth,
                                              rowRect.height),
                                     align: hasStatusBinding ? .left : .center)
                    if hasStatusBinding {
                        drawBambuStatusText(ctx, statusText,
                                            maxSize: valueSize, minSize: 8.5,
                                            color: isError ? alertText : primaryText,
                                            in: CGRect(x: rowRect.minX + contentWidth * 0.40,
                                                       y: rowRect.minY,
                                                       width: contentWidth * 0.60,
                                                       height: rowRect.height),
                                            align: .right)
                    }
                case 1:
                    // 进度行：进度条 + 百分比
                    let pct = progress.flatMap { Double($0.state) }.map { min($0 / 100, 1) } ?? 0
                    let pctText = progress.flatMap { Double($0.state) }
                        .map { String(format: "%.0f%%", $0) } ?? "—"
                    let barH = bambuCanvasProgressBarHeight(
                        rowHeight: rowRect.height,
                        optimizeForOracleEInk: optimizeBambuForOracleEInk)
                    let pctWidth = max(optimizeBambuForOracleEInk ? 42 : 32,
                                       measureTextWidth(pctText, size: valueSize, bold: true) + 3)
                    let progressBounds = rect(rowRect.minX, rowRect.midY - barH / 2,
                                              max(contentWidth - pctWidth - 6, 12), barH)
                    drawProgress(ctx, progressBounds, progress: pct,
                                 accent: progressInk, background: progressTrack)
                    if optimizeBambuForOracleEInk {
                        strokeRound(ctx, progressBounds, radius: barH / 2,
                                    color: adaptiveOutline, width: 2)
                    }
                    drawText(ctx, pctText, size: valueSize, bold: true, color: primaryText,
                             in: rect(rowRect.maxX - pctWidth, rowRect.minY,
                                      pctWidth, rowRect.height), align: .right)
                case 2:
                    drawBambuCanvasTask(ctx, taskText, in: rowRect,
                                        preferredSize: min(bodySize + 2, 20),
                                        color: primaryText,
                                        bold: optimizeBambuForOracleEInk || compactBambuSummary)
                case 3:
                    drawCanvasModuleValueLine(ctx, "喷嘴 \(nozzle?.displayValue ?? "—")", rowRect,
                                              w: contentWidth, size: bodySize, color: secondaryText,
                                              bold: optimizeBambuForOracleEInk)
                case 4:
                    drawCanvasModuleValueLine(ctx, "热床 \(bed?.displayValue ?? "—")", rowRect,
                                              w: contentWidth, size: bodySize, color: secondaryText,
                                              bold: optimizeBambuForOracleEInk)
                case 9:
                    let temperatureText = "喷嘴 \(nozzle?.displayValue ?? "—")  ·  热床 \(bed?.displayValue ?? "—")"
                    drawCanvasModuleValueLine(ctx, temperatureText, rowRect,
                                              w: contentWidth, size: bodySize,
                                              color: secondaryText, bold: true)
                case 5:
                    let timeText: String
                    if bambu.timeDisplayMode == .endTime {
                        timeText = "预计结束 \(timeEntity?.displayState ?? "—")"
                    } else {
                        timeText = "剩余 \(timeEntity?.remainingDisplayText ?? "—")"
                    }
                    drawCanvasModuleValueLine(ctx, timeText, rowRect,
                                              w: contentWidth, size: bodySize, color: secondaryText,
                                              bold: optimizeBambuForOracleEInk || compactBambuSummary)
                case 7:
                    // 画面行：打印机摄像头快照 / 模型封面（圆角 + 描边）
                    let box = CGRect(x: rowRect.minX, y: rowRect.minY + 1,
                                     width: w, height: rowRect.height - 3)
                    if let picture, drawImageData(ctx, data: picture, into: box,
                                                  cover: true, radius: 4) {
                        strokeRound(ctx, rect(box), radius: 4, color: colors.borderCG, width: 1)
                    }
                default:
                    // 错误行：错误码（醒目）
                    let errorText = error?.state ?? status?.state ?? "未知错误"
                    drawCanvasModuleValueLine(ctx, "⚠ \(errorText)", rowRect, w: contentWidth,
                                              size: min(bodySize + 1,
                                                        optimizeBambuForOracleEInk ? 17 : typography.value),
                                              color: alertText, bold: true)
                }
            }
            if footerH > 0 {
                let lineY = baseContentBand.maxY - footerH
                drawLine(ctx, x1: baseContentBand.minX + 6, y1: lineY,
                         x2: baseContentBand.maxX - 6, y2: lineY,
                         color: optimizeBambuForOracleEInk ? adaptiveOutline : colors.borderCG)
                let footerSize = min(max(footerH * 0.52, 8), 10.5)
                drawText(ctx, "数据更新  \(formatDate(ha.sampledAt, "HH:mm:ss"))",
                         size: footerSize, bold: true, color: secondaryText,
                         in: rect(baseContentBand.minX, lineY + 2,
                                  baseContentBand.width, footerH - 2), align: .center)
            }
        case .formlabs, .formlabs2, .formlabs3, .formlabs4, .formlabs5:
            let slot = module.formlabsSlotIndex ?? 0
            let item = formlabsItems.indices.contains(slot) ? formlabsItems[slot] : nil
            drawFormlabsCanvasModule(ctx, band: band, colors: colors,
                                     item: item, deviceCanvas: deviceCanvas,
                                     monochrome: monochromeDeviceCanvas,
                                     accent: accentOverride ?? colors.accentCG,
                                     emphasizeThumbnail: deviceCanvas && singleModuleCanvas)
        case .clock:
            let text = clockTimeText(now, format: settings.timeFormat)
            let preferredSize = min(band.height * 0.62, 32)
            let size = adaptiveFontSize(text, maxSize: preferredSize,
                                        minSize: min(preferredSize, 5.5), bold: true,
                                        maxWidth: max(w - 4, 1))
            drawText(ctx, text, size: size, bold: true, color: colors.primaryTextCG,
                     in: rect(band.minX, band.minY - 2, w, band.height), align: .center)
        case .date:
            let text = formatDate(now, settings.dateFormat)
            let preferredSize = min(band.height * 0.42, 14)
            let size = adaptiveFontSize(text, maxSize: preferredSize,
                                        minSize: min(preferredSize, 5), bold: false,
                                        maxWidth: max(w - 4, 1))
            drawText(ctx, text, size: size, bold: false, color: colors.primaryTextCG,
                     in: rect(band.minX, band.minY, w, band.height), align: .center)
        case .cpu:
            drawStatBand(ctx, band: band, label: "CPU", percent: system.cpuPercent,
                         accent: accentOverride ?? colors.accentCG, colors: colors)
        case .memory:
            drawStatBand(ctx, band: band, label: "内存", percent: system.memoryPercent,
                         accent: accentOverride ?? colors.secondaryAccentCG, colors: colors)
        case .disk:
            drawDiskBand(ctx, band: band, colors: colors,
                         accent: accentOverride ?? colors.secondaryAccentCG,
                         percent: system.diskPercent, used: system.usedDiskBytes, total: system.totalDiskBytes)
        case .codex:
            if deviceCanvas, !monochromeDeviceCanvas,
               band.width >= 180, band.height >= 180 {
                drawSquareCodexQuota(ctx, band: band, snapshot: codex,
                                     accent: accentOverride ?? colors.accentCG,
                                     colors: colors, now: now)
                break
            }
            let pct = codex.remainingPercent
            drawQuotaBand(ctx, band: band, label: "Codex", value: "\(pct)%",
                          progress: Double(pct) / 100, accent: accentOverride ?? colors.accentCG, colors: colors)
        case .qwenQuota:
            if deviceCanvas, !monochromeDeviceCanvas,
               band.width >= 180, band.height >= 180 {
                drawSquareQwenQuota(ctx, band: band, quota: qwenQuota,
                                    showPercent: settings.qwenQuotaShowPercent,
                                    accent: accentOverride ?? colors.secondaryAccentCG,
                                    colors: colors)
                break
            }
            // 额度精确到两位小数；整数大字 + 小数（含小数点）半字号
            let parts = quotaNumberParts(qwenQuota.remainingCredits)
            let unit = qwenQuota.unit.isEmpty ? "credits" : qwenQuota.unit
            // 百分比在基线采样后显示（基线每日自动采样，额度回升时自动拉高）
            let percentText = qwenQuota.trackedProgress.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
            drawQwenQuotaBand(ctx, band: band, whole: parts.whole, fraction: parts.fraction,
                              unit: unit, percent: percentText,
                              progress: qwenQuota.progress,
                              accent: accentOverride ?? colors.secondaryAccentCG, colors: colors,
                              showPercent: settings.qwenQuotaShowPercent)
        case .grokBot:
            drawGrokBotModule(ctx, band: band, snapshot: grokBot, colors: colors,
                              accent: accentOverride ?? colors.accentCG, now: now,
                              deviceCanvas: deviceCanvas,
                              monochromeDeviceCanvas: monochromeDeviceCanvas)
        case .cloudflare:
            drawCloudflareModule(ctx, band: band, snapshot: cloudflare, colors: colors,
                                 accent: accentOverride ?? colors.accentCG, now: now,
                                 deviceCanvas: deviceCanvas,
                                 monochromeDeviceCanvas: monochromeDeviceCanvas)
        case .network:
            let rowH = max(band.height / 2, 10)
            drawText(ctx, "↓ " + formatRate(system.downloadBytesPerSecond), size: typography.body, bold: true,
                     color: colors.primaryTextCG,
                     in: rect(band.minX + 6, band.minY, w - 12, rowH), align: .left)
            drawText(ctx, "↑ " + formatRate(system.uploadBytesPerSecond), size: typography.body, bold: true,
                     color: colors.secondaryTextCG,
                     in: rect(band.minX + 6, band.minY + rowH, w - 12, rowH), align: .left)
        case .nowPlaying:
            if deviceCanvas, !monochromeDeviceCanvas,
               band.width >= 180, band.height >= 180 {
                drawSquareNowPlaying(ctx, band: band, info: nowPlaying,
                                     accent: accentOverride ?? colors.accentCG,
                                     colors: colors,
                                     showCover: nowPlayingShowCover
                                        ?? settings.canvasNowPlayingCover)
                break
            }
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
                if monochromeDeviceCanvas {
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
            if nowPlayingShowCover ?? settings.canvasNowPlayingCover, let art {
                // 竖排封面尺寸估算（封面在模块上方、文字在下方）：
                // 空间不足时封面会被压得过小，此时自动转为横向排布（侧边栏式封面居左、歌名/歌手居右）
                let verticalTextH = max(band.height * 0.32, 20)
                let verticalCover = min(w - 4, max(band.height - verticalTextH - 4, 20))
                let horizontalNeeded = verticalCover < 44
                // 横向排布（占满整行 / 显式横向开关 / 竖排封面过小自动回退）：封面居左、歌名/歌手居右
                if (fullWidth || nowPlayingHorizontal || horizontalNeeded), band.width >= 100 {
                    let coverSize = max(min(band.height - 4, w * 0.45), 16)
                    let coverX = band.minX + 2
                    let coverY = band.minY + (band.height - coverSize) / 2
                    let coverSkia = CGRect(x: coverX, y: coverY,
                                           width: coverSize, height: coverSize)
                    let coverRect = rect(coverSkia)
                    if deviceCanvas, !monochromeDeviceCanvas {
                        drawCoverGlow(ctx,
                                      color: boostedGlowColor(dominantColor(of: art)),
                                      coverSkia: coverSkia,
                                      extent: min(max(coverSize * 0.24, 10), 22),
                                      blurSigma: min(max(coverSize * 0.11, 6), 11),
                                      innerInset: 2,
                                      cornerRadius: 7,
                                      opacity: 0.72)
                    }
                    ctx.saveGState()
                    ctx.addPath(CGPath(roundedRect: coverRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                    ctx.clip()
                    ctx.interpolationQuality = .high
                    ctx.draw(art, in: coverRect)
                    ctx.restoreGState()
                    // 墨水屏设备画板：封面加 2px 黑色描边，避免浅色封面与背景融为一体；
                    // 键盘画板开启「智能封面取色背景」时封面描边用封面主色强调色（跟随封面）
                    if monochromeDeviceCanvas {
                        strokeRound(ctx, coverRect, radius: 6,
                                    color: CGColor(red: 0, green: 0, blue: 0, alpha: 1), width: 2)
                    } else if nowPlayingSmartBg {
                        let coverAccent = coverProgressAccent(dominantColor(of: art))
                        strokeRound(ctx, coverRect, radius: 6,
                                    color: CGColor(red: coverAccent.0, green: coverAccent.1,
                                                   blue: coverAccent.2, alpha: 1), width: 1)
                    } else {
                        strokeRound(ctx, coverRect, radius: 6, color: colors.borderCG, width: 1)
                    }
                    let textX = band.minX + coverSize + 8
                    let textW = max(w - coverSize - 12, 20)
                    let textAreaH = band.height

                    // 歌名：自适应字号 + 断句换行（最多 2 行）；超长时不硬缩成小字，而是换行完整显示
                    let titleCapH = textAreaH * 0.6
                    var titleSize = min(band.height * 0.36, 12)
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
                                                 9), 6))
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
                    let coverSkia = CGRect(x: coverX, y: coverY,
                                           width: coverSize, height: coverSize)
                    let coverRect = rect(coverSkia)
                    if deviceCanvas, !monochromeDeviceCanvas {
                        drawCoverGlow(ctx,
                                      color: boostedGlowColor(dominantColor(of: art)),
                                      coverSkia: coverSkia,
                                      extent: min(max(coverSize * 0.24, 10), 24),
                                      blurSigma: min(max(coverSize * 0.11, 6), 12),
                                      innerInset: 2,
                                      cornerRadius: 9,
                                      opacity: 0.72)
                    }
                    ctx.saveGState()
                    ctx.addPath(CGPath(roundedRect: coverRect, cornerWidth: 8, cornerHeight: 8, transform: nil))
                    ctx.clip()
                    ctx.interpolationQuality = .high
                    ctx.draw(art, in: coverRect)
                    ctx.restoreGState()
                    // 墨水屏设备画板：封面加 2px 黑色描边，避免浅色封面与背景融为一体；
                    // 键盘画板开启「智能封面取色背景」时封面描边用封面主色强调色（跟随封面）
                    if monochromeDeviceCanvas {
                        strokeRound(ctx, coverRect, radius: 8,
                                    color: CGColor(red: 0, green: 0, blue: 0, alpha: 1), width: 2)
                    } else if nowPlayingSmartBg {
                        let coverAccent = coverProgressAccent(dominantColor(of: art))
                        strokeRound(ctx, coverRect, radius: 8,
                                    color: CGColor(red: coverAccent.0, green: coverAccent.1,
                                                   blue: coverAccent.2, alpha: 1), width: 1)
                    } else {
                        strokeRound(ctx, coverRect, radius: 8, color: colors.borderCG, width: 1)
                    }
                    let textTop = band.minY + 1 + coverSize + 2
                    let textBand = CGRect(x: band.minX, y: textTop, width: w, height: band.maxY - textTop)
                    var ts = min(textBand.height * 0.5, 12)
                    var tw = measureTextWidth(title, size: ts, bold: true)
                    if tw > w - 4 { ts = max(ts * (w - 4) / tw, 7); tw = measureTextWidth(title, size: ts, bold: true) }
                    drawText(ctx, title, size: ts, bold: true, color: primaryTextColor,
                             in: rect(band.minX, textTop, w, textBand.height * 0.55), align: .center)
                    drawText(ctx, artist, size: max(min(textBand.height * 0.4, 9), 6), bold: false,
                             color: secondaryTextColor,
                             in: rect(band.minX, textTop + textBand.height * 0.5, w, textBand.height * 0.5), align: .center)
                }
            } else {
                // 无封面（或未开启封面）：空间够就上下两行；被压缩到两行都会挤成小字时
                // 自动转横向单行（歌名居左、歌手居右），与口袋先知/摘录画板的横向排布一致
                let h1 = max(band.height * 0.55, 10)
                let h2 = max(band.height - h1, 6)
                if Self.nowPlayingPrefersHorizontal(bandHeight: band.height, bandWidth: band.width,
                                                    title: title,
                                                    titleSizeSetting: 12) {
                    var artistSize = max(min(band.height * 0.62,
                                             9), 6)
                    var artistW = measureTextWidth(artist, size: artistSize, bold: false)
                    let artistMaxW = w * 0.45
                    if artistW > artistMaxW {
                        artistSize = max(artistSize * artistMaxW / artistW, 6)
                        artistW = measureTextWidth(artist, size: artistSize, bold: false)
                    }
                    let titleMaxW = artist.isEmpty ? w : max(w - artistW - 8, 24)
                    var titleSize = max(min(band.height * 0.72,
                                            12), 7)
                    let titleW = measureTextWidth(title, size: titleSize, bold: true)
                    if titleW > titleMaxW {
                        titleSize = max(titleSize * titleMaxW / titleW, 7)
                    }
                    let glyphH = max(titleSize, artistSize)
                    // 字形按 em 盒居中会偏低，上移补偿使整行视觉居中
                    let textTop = band.minY + max((band.height - glyphH) / 2, 0) - glyphH * 0.18
                    if artist.isEmpty {
                        drawText(ctx, title, size: titleSize, bold: true, color: primaryTextColor,
                                 in: rect(band.minX, textTop, w, glyphH), align: .center)
                    } else {
                        drawText(ctx, title, size: titleSize, bold: true, color: primaryTextColor,
                                 in: rect(band.minX, textTop, titleMaxW, glyphH), align: .left)
                        drawText(ctx, artist, size: artistSize, bold: false, color: secondaryTextColor,
                                 in: rect(band.maxX - artistW, textTop, artistW, glyphH), align: .right)
                    }
                } else {
                    var size = min(h1 * 0.75, 12)
                    if measureTextWidth(title, size: size, bold: true) > w - 4 {
                        size = max(size * (w - 4) / measureTextWidth(title, size: size, bold: true), 8)
                    }
                    drawText(ctx, title, size: size, bold: true, color: primaryTextColor,
                             in: rect(band.minX, band.minY, w, h1), align: .center)
                    drawText(ctx, artist, size: max(min(h2 * 0.7, 9), 6), bold: false,
                             color: secondaryTextColor,
                             in: rect(band.minX, band.minY + h1, w, h2), align: .center)
                }
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
            // 阶段标识与时间紧凑成块：空隙随模块高度自动缩窄（越挤空隙越小），
            // 整块垂直居中保证上下外边缘充足；空间不足时整体收缩字号保持外边缘
            var phaseSize = max(min(band.height * 0.28, 11), 7)
            var timeSize = min(band.height * 0.42, 20)
            let outer = min(max(band.height * 0.12, 2), 6)
            let availH = max(band.height - outer * 2, 20)
            let gap = min(max(band.height * 0.05, 2), 5)
            var phaseRowH = phaseSize * 1.15
            var timeRowH = timeSize * 1.25
            var blockH = phaseRowH + gap + timeRowH
            if blockH > availH {
                let f = availH / blockH
                phaseSize = max(phaseSize * f, 7)
                timeSize = max(timeSize * f, 9)
                phaseRowH = phaseSize * 1.15
                timeRowH = timeSize * 1.25
                blockH = phaseRowH + gap + timeRowH
            }
            let blockTop = band.minY + max((band.height - blockH) / 2, 0)
            // 字形按 em 盒居中时视觉整体偏低约 0.35 倍字号（PingFang 大 ascent）：
            // 各行绘制区上移该量补偿，使字形真正居中于所在行
            drawText(ctx, phaseText, size: phaseSize, bold: false,
                     color: colors.secondaryTextCG,
                     in: rect(band.minX, blockTop - phaseSize * 0.35, w, phaseRowH), align: .center)
            drawText(ctx, time, size: timeSize, bold: true,
                     color: colors.primaryTextCG,
                     in: rect(band.minX, blockTop + phaseRowH + gap - timeSize * 0.35, w, timeRowH), align: .center)
        case .uptime:
            let text = uptimeText(system.uptime)
            var size = min(band.height * 0.45, typography.body)
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
            // 「叠加」模式：图像作为一个模块铺满当前横带；键盘画板「背景」模式在整卡已铺底，此处不再重复。
            // 墨水屏画板图片模块固定按叠加绘制
            if !deviceCanvas && settings.canvasImageMode == .background && !imageOverlayOnly {
                break
            }
            let imagePath = canvasImagePath ?? settings.customImagePath
            if isCanvasImageReady(imagePath), let path = imagePath {
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
            // 摘录语录不显示「摘录」标题，正文占满整带；轮换池按勾选的分类过滤；
            // 开启显示出处时底部加一行出处（替换时钟位置）
            let quoteBody = rotatingExcerptText(now, categories: settings.excerptQuoteCategories)
            let quoteSource = settings.showExcerptSource ? (excerptSource(for: quoteBody) ?? "") : ""
            drawQuoteBand(ctx, title: nil, body: quoteBody,
                          band: band, colors: colors, source: quoteSource)
        case .sspai:
            drawSspaiBand(ctx, articles: sspaiArticles, band: band, colors: colors,
                          deviceCanvas: deviceCanvas, monochrome: monochromeDeviceCanvas)
        }
    }

    /// 三种画板共用的 Formlabs 紧凑模块。窄而高的灵犀画板使用纵向缩略图，
    /// 口袋先知与摘录的宽画面改为“缩略图在左、任务详情在右”，空间不足时自动省略图片。
    private static func drawFormlabsCanvasModule(_ ctx: CGContext, band: CGRect,
                                                  colors: ScreenPalette,
                                                  item: FormlabsCanvasItem?,
                                                  deviceCanvas: Bool,
                                                  monochrome: Bool,
                                                  accent: CGColor,
                                                  emphasizeThumbnail: Bool = false) {
        guard band.width > 8, band.height > 8 else { return }
        // 与 Bambu 墨水屏模块统一：白色圆角卡片、最深黑字和黑色进度强调；
        // 键盘画板继续沿用用户主题配色。
        let primary = monochrome ? CGColor(gray: 0, alpha: 1) : colors.primaryTextCG
        let secondary = monochrome ? CGColor(gray: 0, alpha: 1) : colors.secondaryTextCG
        let cardFill = monochrome ? CGColor(gray: 1, alpha: 1) : colors.insetCG
        let cardBorder = monochrome ? CGColor(gray: 0, alpha: 1) : colors.borderCG
        let progressAccent = monochrome ? CGColor(gray: 0, alpha: 1) : accent
        let progressTrack = monochrome ? CGColor(gray: 0.82, alpha: 1) : colors.borderCG
        fillRound(ctx, rect(band), radius: 7, color: cardFill)
        strokeRound(ctx, rect(band), radius: 7, color: cardBorder,
                    width: monochrome ? 1.5 : 1)
        // 灵犀画板固定左上内边距，与 Bambu 标头完全对齐；
        // 墨水屏仍按画面尺寸适配。
        let insetX: CGFloat = deviceCanvas ? min(max(band.width * 0.045, 4), 7) : 5
        let insetY: CGFloat = deviceCanvas ? min(max(band.height * 0.035, 3), 6) : 4
        let content = band.insetBy(dx: insetX, dy: insetY)
        let fallbackName = "Formlabs 打印机"
        let name = item?.deviceName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = name.isEmpty ? fallbackName : name
        let snapshot = item?.snapshot ?? .empty
        let rawStatus = snapshot.print?.status.isEmpty == false
            ? snapshot.print!.status : (snapshot.device?.status ?? "unknown")
        let status = formlabsStatusText(rawStatus)
        let isError = rawStatus.lowercased().contains("error")
            || rawStatus.lowercased().contains("fail")

        let headerH = min(max(content.height * 0.13, 15), deviceCanvas ? 22 : 18)
        let statusPreferredSize: CGFloat = deviceCanvas ? 12.5 : 9.5
        let statusW = min(max(measureTextWidth(status, size: statusPreferredSize, bold: true) + 4, 28),
                          content.width * 0.43)
        let nameW = max(content.width - statusW - 4, 20)
        drawAdaptiveText(ctx, displayName,
                         maxSize: deviceCanvas ? 15 : 11, minSize: 7.5, bold: true,
                         color: primary,
                         in: rect(content.minX, content.minY, nameW, headerH), align: .left)
        drawAdaptiveText(ctx, status,
                         maxSize: statusPreferredSize, minSize: 7, bold: true,
                         color: isError ? progressAccent : secondary,
                         in: rect(content.maxX - statusW, content.minY,
                                  statusW, headerH), align: .right)

        let headerGap: CGFloat = deviceCanvas ? 4 : 5
        let dividerY = content.minY + headerH + 1
        drawLine(ctx, x1: content.minX, y1: dividerY,
                 x2: content.maxX, y2: dividerY, color: cardBorder)
        var cursor = content.minY + headerH + headerGap
        guard snapshot.hasData else {
            drawText(ctx, "等待云端数据", size: deviceCanvas ? 11 : 9, bold: false,
                     color: secondary,
                     in: rect(content.minX, cursor, content.width,
                              max(content.maxY - cursor, 10)), align: .center)
            return
        }

        // 摘录画板中卡片独占整幅时，封面改为左侧 hero 区：它可以
        // 占用标头以下的整段高度，不再受任务和进度条先占行的限制。
        // 口袋先知保留上下结构，稍后单独提高封面宽度权重。
        var flowContent = content
        var thumbnailWasDrawn = false
        if emphasizeThumbnail,
           content.width >= 240,
           item?.connection.showThumbnail == true,
           let thumbnail = snapshot.thumbnail {
            let availableHeight = max(content.maxY - cursor, 2)
            let side = min(availableHeight, min(content.width * 0.38, 104))
            let imageBox = CGRect(x: content.minX, y: cursor, width: side, height: side)
            if side >= 40,
               drawImageData(ctx, data: thumbnail, into: imageBox, cover: false, radius: 5) {
                strokeRound(ctx, rect(imageBox), radius: 5, color: cardBorder, width: 1)
                thumbnailWasDrawn = true
                flowContent = CGRect(x: imageBox.maxX + 8, y: content.minY,
                                     width: max(content.maxX - imageBox.maxX - 8, 8),
                                     height: content.height)
            }
        }

        // 与 Bambu 模块保持同一信息顺序：设备名/状态 → 任务名 → 进度。
        // 横向墨水屏优先使用单行大字，竖向灵犀画板在空间允许时显示两行。
        let task = snapshot.print?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !task.isEmpty {
            let preferred: CGFloat = deviceCanvas ? 13.5 : 10.5
            // 口袋先知中 Formlabs 独占 200×200 画板时，项目文件名明确限制为最多两行；
            // 摘录和多模块压缩条带保持单行，避免挤压下方缩略图和详情。
            let isPocketOracleStandalone = deviceCanvas
                && band.width >= 180 && band.width <= 220 && band.height >= 180
            let maximumLines = isPocketOracleStandalone ? 2 : 1
            let lines = fileNameLines(task, size: preferred,
                                      maxW: flowContent.width, maxLines: maximumLines)
            let lineH: CGFloat = deviceCanvas ? 18 : 14
            for line in lines {
                drawAdaptiveText(ctx, line, maxSize: preferred,
                                 minSize: deviceCanvas ? 9 : 7.5, bold: true,
                                 color: primary,
                                 in: rect(flowContent.minX, cursor, flowContent.width, lineH),
                                 align: flowContent.width >= 150 ? .left : .center)
                cursor += lineH
            }
            cursor += 2
        }

        if let progress = snapshot.print?.progress {
            let progressH = min(max(content.height * 0.12, deviceCanvas ? 20 : 16), 24)
            let percent = "\(Int((progress * 100).rounded()))%"
            let percentSize: CGFloat = deviceCanvas ? 12.5 : 10
            let percentW = min(max(measureTextWidth(percent, size: percentSize, bold: true) + 3, 28),
                               flowContent.width * 0.34)
            let barW = max(flowContent.width - percentW - 5, 12)
            let barH: CGFloat = deviceCanvas ? 6 : 3.5
            let barY = cursor + max((progressH - barH) / 2, 0)
            let progressBounds = rect(flowContent.minX, barY, barW, barH)
            drawProgress(ctx, progressBounds, progress: progress,
                         accent: progressAccent, background: progressTrack)
            strokeRound(ctx, progressBounds, radius: barH / 2,
                        color: cardBorder, width: monochrome ? 1.5 : 0.8)
            // 使用实际 glyph 边界居中，避免数字基线让百分比看起来比进度条低。
            let fittedPercentSize = adaptiveFontSize(
                percent, maxSize: percentSize, minSize: 7.5, bold: true,
                maxWidth: max(percentW - 1, 1))
            drawGlyphCenteredText(ctx, percent, size: fittedPercentSize,
                                  bold: true, color: primary,
                                  in: rect(flowContent.maxX - percentW, cursor,
                                           percentW, progressH), align: .right)
            cursor += progressH + 2
        }

        let remainingArea = CGRect(x: flowContent.minX, y: cursor, width: flowContent.width,
                                   height: max(content.maxY - cursor, 2))
        var detailArea = remainingArea
        if !thumbnailWasDrawn,
           item?.connection.showThumbnail == true,
           let thumbnail = snapshot.thumbnail {
            if remainingArea.width >= 150, remainingArea.height >= 40 {
                // 口袋先知和摘录画板：缩略图固定靠左，右侧详情从上向下排列。
                // 摘录较扁时允许缩略图随剩余高度收缩，不再把文字挤出边界。
                let widthWeight: CGFloat = emphasizeThumbnail ? 0.44 : 0.33
                let maximumSide: CGFloat = emphasizeThumbnail ? 92 : 78
                let side = min(remainingArea.height,
                               min(remainingArea.width * widthWeight, maximumSide))
                let imageBox = CGRect(x: remainingArea.minX,
                                      y: remainingArea.minY,
                                      width: side, height: side)
                if drawImageData(ctx, data: thumbnail, into: imageBox, cover: false, radius: 5) {
                    strokeRound(ctx, rect(imageBox), radius: 5, color: cardBorder, width: 1)
                    detailArea = CGRect(x: imageBox.maxX + 7, y: remainingArea.minY,
                                        width: max(remainingArea.maxX - imageBox.maxX - 7, 8),
                                        height: remainingArea.height)
                }
            } else if remainingArea.width < 150, remainingArea.height >= 112 {
                // 灵犀画板：窄屏使用上下结构，缩略图居中，详情紧随其后。
                let side = min(remainingArea.width - 8, min(remainingArea.height * 0.50, 82))
                let imageBox = CGRect(x: remainingArea.midX - side / 2,
                                      y: remainingArea.minY, width: side, height: side)
                if drawImageData(ctx, data: thumbnail, into: imageBox, cover: false, radius: 5) {
                    strokeRound(ctx, rect(imageBox), radius: 5, color: cardBorder, width: 1)
                    detailArea = CGRect(x: remainingArea.minX, y: imageBox.maxY + 5,
                                        width: remainingArea.width,
                                        height: max(remainingArea.maxY - imageBox.maxY - 5, 2))
                }
            }
        }

        var rows: [(String, Bool)] = []
        if item?.connection.showLayers == true,
           let current = snapshot.print?.currentLayer,
           let total = snapshot.print?.layerCount, total > 0 {
            rows.append(("层数  \(current) / \(total)", false))
        }
        if item?.connection.showMaterial == true,
           let material = snapshot.print?.materialName, !material.isEmpty {
            rows.append(("耗材  \(material)", false))
        }
        let remaining = snapshot.print?.estimatedTimeRemainingMS
            ?? snapshot.device?.estimatedPrintTimeRemainingMS
        if let remaining, remaining > 0 {
            rows.append(("剩余  \(formlabsDuration(remaining))", false))
        }
        guard !rows.isEmpty, detailArea.height > 4 else { return }
        let totalLines = rows.count
        let lineH = min(max(detailArea.height / CGFloat(max(totalLines, 1)), 8),
                        deviceCanvas ? 17 : 13)
        var textY = detailArea.minY
        for (text, emphasized) in rows {
            let preferred = emphasized ? (deviceCanvas ? 12.5 : 10.5)
                                       : (deviceCanvas ? 12 : 9)
            guard textY + lineH <= detailArea.maxY + 0.5 else { return }
            // 详情行的内容本身很短，窄布局下应优先缩小字号完整显示，
            // 不要先按大字号截断为省略号。
            drawAdaptiveText(ctx, text, maxSize: preferred,
                             minSize: emphasized ? 8 : 7, bold: emphasized,
                             color: emphasized ? primary : secondary,
                             in: rect(detailArea.minX, textY,
                                      detailArea.width, lineH),
                             align: emphasized && detailArea.width < 145 ? .center : .left)
            textY += lineH
        }
    }

    /// 少数派独立卡片及彩色方屏共用品牌色，避免方屏错误继承其他模块的绿色强调。
    public static func sspaiPalette(_ base: ScreenPalette) -> ScreenPalette {
        let luminance = 0.299 * base.background.0 + 0.587 * base.background.1 + 0.114 * base.background.2
        let brand: (CGFloat, CGFloat, CGFloat) = luminance < 0.5
            ? (0.98, 0.42, 0.28) : (0.82, 0.25, 0.15)
        var result = base
        result.accent = brand
        result.secondaryAccent = brand
        return result
    }

    /// 方屏推荐页：固定安全边距与标头，标题和作者作为完整文本组在正文区垂直居中。
    private static func drawSquareSspai(_ ctx: CGContext, articles: [SspaiArticle],
                                        band: CGRect, colors: ScreenPalette) {
        let inner = band.insetBy(dx: 8, dy: 6)
        let headerHeight: CGFloat = inner.height >= 90 ? 27 : 21
        drawText(ctx, "SSPAI", size: 15, bold: true, color: colors.accentCG,
                 in: rect(inner.minX, inner.minY, 72, headerHeight), align: .left)
        drawText(ctx, "少数派推荐", size: 10, bold: true, color: colors.secondaryTextCG,
                 in: rect(inner.minX + 78, inner.minY, inner.width - 78, headerHeight), align: .right)
        drawLine(ctx, x1: inner.minX, y1: inner.minY + headerHeight,
                 x2: inner.maxX, y2: inner.minY + headerHeight, color: colors.borderCG)
        let content = CGRect(x: inner.minX, y: inner.minY + headerHeight + 8,
                             width: inner.width, height: max(inner.height - headerHeight - 16, 12))
        guard !articles.isEmpty else {
            drawText(ctx, "正在获取推荐文章…", size: 12, bold: false, color: colors.secondaryTextCG,
                     in: rect(content), align: .center)
            return
        }
        let count = min(articles.count, 3, max(Int(content.height / 40), 1))
        let gap: CGFloat = count > 1 ? 10 : 0
        let rowLimit = max((content.height - gap * CGFloat(count - 1)) / CGFloat(count), 12)
        let textWidth = max(content.width - 26, 20)
        struct ArticleLayout {
            let article: SspaiArticle
            let lines: [String]
            let size: CGFloat
            let height: CGFloat
            let authorHeight: CGFloat
        }
        let rows: [ArticleLayout] = articles.prefix(count).map { article in
            let authorHeight: CGFloat = article.author.isEmpty || rowLimit < 38 ? 0 : 13
            let titleLimit = max(rowLimit - authorHeight, 12)
            var size: CGFloat = count == 1 ? 19 : 14
            var lines = wrapText(article.title, maxWidth: textWidth, size: size)
            while size > 9, CGFloat(lines.count) * size * 1.25 > titleLimit {
                size -= 0.5
                lines = wrapText(article.title, maxWidth: textWidth, size: size)
            }
            let maximumLines = max(Int(titleLimit / (size * 1.25)), 1)
            if lines.count > maximumLines {
                lines = splitLines(article.title, size: size, bold: false,
                                   maxW: textWidth, maxLines: maximumLines)
            }
            return ArticleLayout(article: article, lines: lines, size: size,
                                 height: CGFloat(max(lines.count, 1)) * size * 1.25 + authorHeight,
                                 authorHeight: authorHeight)
        }
        let groupHeight = rows.reduce(CGFloat.zero) { $0 + $1.height } + gap * CGFloat(count - 1)
        var y = content.minY + max((content.height - groupHeight) / 2, 0)
        for (index, row) in rows.enumerated() {
            drawText(ctx, "\(index + 1)", size: 12, bold: true, color: colors.accentCG,
                     in: rect(content.minX, y, 18, row.size * 1.25), align: .center)
            for (lineIndex, line) in row.lines.enumerated() {
                drawText(ctx, line, size: row.size, bold: false, color: colors.primaryTextCG,
                         in: rect(content.minX + 26, y + CGFloat(lineIndex) * row.size * 1.25,
                                  textWidth, row.size * 1.25), align: .left)
            }
            if row.authorHeight > 0 {
                drawAdaptiveText(ctx, row.article.author, maxSize: 9.5, minSize: 8,
                                 bold: false, color: colors.secondaryTextCG,
                                 in: rect(content.minX + 26, y + row.height - row.authorHeight,
                                          textWidth, row.authorHeight), align: .left)
            }
            y += row.height + gap
        }
    }

    /// 彩色方屏 HA：图片/摄像头使用可辨认的静态画面，普通实体保持名称与状态分区。
    /// 最多四个等高项目，单图占满正文；模块变矮时统一压缩本模块，不侵入相邻模块。
    private static func drawSquareHomeAssistant(_ ctx: CGContext, snapshot: HASnapshot,
                                                band: CGRect, colors: ScreenPalette) {
        let inner = band.insetBy(dx: 5, dy: 5)
        let headerHeight: CGFloat = inner.height >= 100 ? 28 : 21
        drawText(ctx, "HOME SYSTEM", size: 12, bold: true, color: colors.accentCG,
                 in: rect(inner.minX + 2, inner.minY, inner.width - 4, headerHeight), align: .left)
        drawLine(ctx, x1: inner.minX + 2, y1: inner.minY + headerHeight,
                 x2: inner.maxX - 2, y2: inner.minY + headerHeight, color: colors.borderCG)
        struct Item {
            let name: String
            let value: String
            let icon: String
            let image: Data?
            let isMedia: Bool
            let stale: Bool
        }
        var items = snapshot.selectedEntities.map { entity in
            Item(name: snapshot.aliases[entity.entityId] ?? entity.displayName,
                 value: entity.displayValue, icon: SFIconMapper.symbol(for: entity),
                 image: snapshot.picture(for: entity.entityId),
                 isMedia: !HAEntityPicker.pictureEntityIDs(in: [entity.entityId]).isEmpty,
                 stale: false)
        }
        items += snapshot.missingRows().map {
            Item(name: $0.name, value: $0.lastValue.isEmpty ? "失效" : $0.lastValue,
                 icon: "exclamationmark.triangle", image: nil, isMedia: false, stale: true)
        }
        let bodyHeight = max(inner.height - headerHeight - 12, 10)
        // 很矮的模块容不下“实体行 + 更多数量”。此时只保留计数摘要，避免
        // 把正文强行撑到 10px 后再和底部“另有 N 项”挤在同一行。
        if !items.isEmpty, bodyHeight < 30 {
            drawText(ctx, "\(items.count) 项实体 · 增大模块可查看详情", size: 9, bold: false,
                     color: colors.secondaryTextCG,
                     in: rect(inner.minX, inner.minY + headerHeight + 7,
                              inner.width, bodyHeight), align: .left)
            return
        }
        let mediaCandidate = items.prefix(haStandalonePageLimit).contains { $0.isMedia || $0.image != nil }
        let possibleColumns = mediaCandidate && items.count > 1 && bodyHeight >= 72 ? 2 : 1
        let possibleRows = max(Int((bodyHeight - (items.count > 1 ? 13 : 0) + 6) / 34), 1)
        let shown = Array(items.prefix(min(haStandalonePageLimit, possibleColumns * possibleRows)))
        let moreHeight: CGFloat = items.count > shown.count ? 13 : 0
        let content = CGRect(x: inner.minX, y: inner.minY + headerHeight + 7,
                             width: inner.width, height: max(inner.height - headerHeight - 12 - moreHeight, 10))
        guard !shown.isEmpty else {
            drawText(ctx, snapshot.errorText ?? "请选择显示的实体", size: 12, bold: false,
                     color: colors.secondaryTextCG, in: rect(content), align: .center)
            return
        }
        let hasMedia = shown.contains { $0.isMedia || $0.image != nil }
        let columns = hasMedia && shown.count > 1 && content.height >= 72 ? 2 : 1
        let rowCount = (shown.count + columns - 1) / columns
        let gap: CGFloat = 6
        let cellWidth = (content.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let availableHeight = max((content.height - gap * CGFloat(rowCount - 1)) / CGFloat(rowCount), 8)
        let cellHeight = hasMedia ? availableHeight
            : min(availableHeight, shown.count == 1 ? 84 : 38)
        let groupHeight = cellHeight * CGFloat(rowCount) + gap * CGFloat(rowCount - 1)
        let startY = content.minY + max((content.height - groupHeight) / 2, 0)
        for (index, item) in shown.enumerated() {
            let cell = CGRect(x: content.minX + CGFloat(index % columns) * (cellWidth + gap),
                              y: startY + CGFloat(index / columns) * (cellHeight + gap),
                              width: cellWidth, height: cellHeight)
            fillRound(ctx, rect(cell), radius: 8, color: colors.insetCG)
            strokeRound(ctx, rect(cell), radius: 8, color: colors.borderCG, width: 1)
            let foreground = item.stale ? colors.secondaryTextCG : colors.primaryTextCG
            if (item.isMedia || item.image != nil), cell.height >= 52 {
                let pictureBox = CGRect(x: cell.minX + 5, y: cell.minY + 5,
                                        width: cell.width - 10, height: cell.height - 32)
                if let image = item.image,
                   drawImageData(ctx, data: image, into: pictureBox, cover: true, radius: 5) {
                    // The fetched static frame is drawn directly, without streaming or a new timer.
                } else {
                    drawText(ctx, "等待画面", size: 11, bold: false, color: colors.secondaryTextCG,
                             in: rect(pictureBox), align: .center)
                }
                let label = splitLines(item.name, size: columns == 1 ? 11 : 9.5, bold: true,
                                       maxW: cell.width - 10, maxLines: 2)
                for (lineIndex, line) in label.enumerated() {
                    drawText(ctx, line, size: columns == 1 ? 11 : 9.5, bold: true, color: foreground,
                             in: rect(cell.minX + 5, cell.maxY - 25 + CGFloat(lineIndex) * 11,
                                      cell.width - 10, 11), align: .center)
                }
            } else if cell.height >= 48 {
                drawAdaptiveText(ctx, item.name, maxSize: 13, minSize: 9, bold: false,
                                 color: colors.secondaryTextCG,
                                 in: rect(cell.minX + 8, cell.minY + 5, cell.width - 16, 22), align: .center)
                drawAdaptiveText(ctx, item.value, maxSize: min(28, cell.height * 0.34), minSize: 9,
                                 bold: true, color: foreground,
                                 in: rect(cell.minX + 8, cell.minY + 27, cell.width - 16,
                                          cell.height - 32), align: .center)
            } else {
                let valueWidth = min(max(cell.width * 0.34, 42), 75)
                drawEntityIcon(ctx, symbol: item.icon,
                               in: rect(cell.minX + 6, cell.midY - 6, 12, 12), color: colors.accentCG)
                drawAdaptiveText(ctx, item.name, maxSize: 11, minSize: 8, bold: false,
                                 color: colors.secondaryTextCG,
                                 in: rect(cell.minX + 22, cell.minY + 2,
                                          max(cell.width - valueWidth - 29, 12), cell.height - 4), align: .left)
                drawAdaptiveText(ctx, item.value, maxSize: 12, minSize: 8, bold: true, color: foreground,
                                 in: rect(cell.maxX - valueWidth - 6, cell.minY + 2,
                                          valueWidth, cell.height - 4), align: .right)
            }
        }
        if moreHeight > 0 {
            drawText(ctx, "另有 \(items.count - shown.count) 项", size: 9, bold: false,
                     color: colors.tertiaryTextCG,
                     in: rect(inner.minX, inner.maxY - moreHeight, inner.width, moreHeight), align: .right)
        }
    }

    /// 少数派推荐画板模块：编号 + 标题多行（自适应字号，长标题换行显示而不是截断；
    /// 键盘画板强调色用少数派品牌红橙，墨水屏设备画板统一为最深对比色）
    private static func drawSspaiBand(_ ctx: CGContext, articles: [SspaiArticle],
                                      band: CGRect, colors: ScreenPalette,
                                      deviceCanvas: Bool, monochrome: Bool = true) {
        if deviceCanvas, !monochrome, band.width >= 140, band.height >= 56 {
            drawSquareSspai(ctx, articles: articles, band: band, colors: sspaiPalette(colors))
            return
        }
        let w = band.width
        if articles.isEmpty {
            drawText(ctx, "获取少数派推荐中…", size: 9, bold: false,
                     color: colors.secondaryTextCG,
                     in: rect(band.minX, band.minY, w, band.height), align: .center)
            return
        }
        // 编号强调色：墨水屏设备画板用最深对比色（无品牌色相），键盘画板用品牌红橙
        let brand: CGColor
        if deviceCanvas && monochrome {
            brand = colors.accentCG
        } else {
            brand = sspaiPalette(colors).accentCG
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
    /// 正文自适应字号 + 多行（长语录换行显示而不是缩成极小单行）；
    /// source 非空时正文区底部让出一行出处（摘录语录显示出处，替换时钟位置）
    private static func drawQuoteBand(_ ctx: CGContext, title: String?, body: String,
                                      band: CGRect, colors: ScreenPalette,
                                      source: String = "") {
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
        // 预留底部出处行（语录出处）；非空时正文区让出该行
        let sourceH: CGFloat = source.isEmpty ? 0 : min(max(band.height * 0.16, 11), 18)
        if sourceH > 0 { bodyHeight -= sourceH }
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
        // 出处行：小字号居中，超长自适应缩字号（摘录语录显示出处）
        if sourceH > 0 {
            let attribution = "—— " + source
            var srcSize = min(sourceH * 0.62, 10)
            var srcLine = wrapText(attribution, maxWidth: w - 6, size: srcSize).first ?? attribution
            while srcSize > 6, measureTextWidth(srcLine, size: srcSize, bold: false) > w - 6 {
                srcSize -= 0.5
                srcLine = wrapText(attribution, maxWidth: w - 6, size: srcSize).first ?? attribution
            }
            drawText(ctx, srcLine, size: srcSize, bold: false, color: colors.secondaryTextCG,
                     in: rect(band.minX, bodyTop + bodyHeight, w, sourceH), align: .center)
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

    /// 摘录语录出处（按语录原文精确匹配；没有确切出处的语录不显示）——
    /// 名人名言 → 作者（有出处的加书名/篇名），电影台词 → 电影名，诗词 → 作者《篇名》，谚语无确切出处留空
    public static let excerptQuoteSources: [String: String] = [
        // 名人名言
        "知行合一，止于至善。": "王阳明",
        "千里之行，始于足下。": "《老子》",
        "学而不思则罔，思而不学则殆。": "《论语》",
        "不积跬步，无以至千里。": "《荀子》",
        "业精于勤，荒于嬉。": "韩愈",
        "博观而约取，厚积而薄发。": "苏轼",
        "路虽远，行则将至。": "《荀子》",
        "知之者不如好之者，好之者不如乐之者。": "《论语》",
        "工欲善其事，必先利其器。": "《论语》",
        "天行健，君子以自强不息。": "《周易》",
        "走自己的路，让别人说去吧。": "但丁",
        "冬天来了，春天还会远吗？": "雪莱",
        "书籍是人类进步的阶梯。": "高尔基",
        "一个人可以被毁灭，但不能被打败。": "海明威",
        "世上只有一种真正的英雄主义，那就是认清生活的真相之后依然热爱生活。": "罗曼·罗兰",
        "天下难事，必作于易；天下大事，必作于细。": "《老子》",
        "勿以恶小而为之，勿以善小而不为。": "《三国志》",
        "人的一生应当这样度过：当他回首往事时，不因虚度年华而悔恨，也不因碌碌无为而羞耻。": "奥斯特洛夫斯基",
        // 经典电影台词
        "人生就像一盒巧克力，你永远不知道下一颗是什么味道。": "《阿甘正传》",
        "希望是美好的，也许是人间至善，而美好的事物永不消逝。": "《肖申克的救赎》",
        "做人如果没有梦想，那和咸鱼有什么分别？": "《少林足球》",
        "曾经有一份真挚的爱情摆在我面前，我没有珍惜，等到失去的时候才后悔莫及。": "《大话西游》",
        "能力越大，责任越大。": "《蜘蛛侠》",
        "昨天是历史，明天是谜团，而今天是天赐的礼物。": "《功夫熊猫》",
        "我命由我不由天。": "《哪吒之魔童降世》",
        "有些鸟是注定不会被关在笼子里的，因为它们的每一片羽毛都闪耀着自由的光辉。": "《肖申克的救赎》",
        "爱是唯一可以超越时间与空间的事物。": "《星际穿越》",
        "不要温和地走进那个良夜。": "《星际穿越》",
        "我们曾经仰望星空，思索我们在宇宙中的位置；而现在我们只顾低头，担心我们在尘世间的处境。": "《星际穿越》",
        "牛顿第三定律：要想离开，必须留下点什么。": "《星际穿越》",
        "一旦你为人父母，你就成了孩子未来的幽灵。": "《星际穿越》",
        "墨菲定律并不是说坏事一定会发生，而是说会发生的事总会发生。": "《星际穿越》",
        "既然是做梦，就干脆做大一点。": "《盗梦空间》",
        "要么作为英雄而死，要么苟活到目睹自己变成恶棍。": "《蝙蝠侠：黑暗骑士》",
        "人生总是这么苦么，还是只有童年苦？": "《这个杀手不太冷》",
        "不管前方的路有多苦，只要走的方向正确，不管多么崎岖不平，都比站在原地更接近幸福。": "《千与千寻》",
        "如果你有梦想的话，就要去捍卫它。": "《当幸福来敲门》",
        "说好的一辈子，差一年，一个月，一天，一个时辰，都不算一辈子。": "《霸王别姬》",
        // 诗词名句
        "长风破浪会有时，直挂云帆济沧海。": "李白《行路难》",
        "会当凌绝顶，一览众山小。": "杜甫《望岳》",
        "人生自古谁无死，留取丹心照汗青。": "文天祥《过零丁洋》",
        "海内存知己，天涯若比邻。": "王勃《送杜少府之任蜀州》",
        "山重水复疑无路，柳暗花明又一村。": "陆游《游山西村》",
        "沉舟侧畔千帆过，病树前头万木春。": "刘禹锡《酬乐天扬州初逢席上见赠》",
        "天生我材必有用，千金散尽还复来。": "李白《将进酒》",
        "问渠那得清如许，为有源头活水来。": "朱熹《观书有感》",
        "少壮不努力，老大徒伤悲。": "《长歌行》",
        "大鹏一日同风起，扶摇直上九万里。": "李白《上李邕》",
        "宝剑锋从磨砺出，梅花香自苦寒来。": "《警世贤文》",
    ]

    /// 语录出处查询（无确切出处的返回 nil）
    public static func excerptSource(for quote: String) -> String? {
        excerptQuoteSources[quote]
    }

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
        let typography = canvasTypography()
        let p = min(max(percent, 0), 100)
        let labelH = max(band.height * 0.5, 10)
        drawText(ctx, label, size: typography.label, bold: false, color: colors.secondaryTextCG,
                 in: rect(band.minX + 4, band.minY, band.width - 4, labelH), align: .left)
        drawText(ctx, String(format: "%.0f%%", p), size: typography.value, bold: true, color: colors.primaryTextCG,
                 in: rect(band.minX, band.minY, band.width - 4, labelH), align: .right)
        let barH = min(max(band.height - labelH - 4, 3), 6)
        drawProgress(ctx, rect(band.minX + 4, band.minY + labelH, band.width - 8, barH),
                     progress: p / 100, accent: accent, background: colors.borderCG)
    }

    /// 磁盘占用模块（标签 + 百分比 + 进度条 + 已用/总容量小字；高度不足时省略容量行）
    private static func drawDiskBand(_ ctx: CGContext, band: CGRect, colors: ScreenPalette,
                                     accent: CGColor,
                                     percent: Double, used: UInt64, total: UInt64) {
        let typography = canvasTypography()
        let p = min(max(percent, 0), 100)
        let w = band.width
        let capH: CGFloat = band.height >= 46 ? max(min(band.height * 0.22, 10), 7) : 0
        let labelH = max((band.height - capH) * 0.55, 10)
        drawText(ctx, "磁盘", size: typography.label, bold: false, color: colors.secondaryTextCG,
                 in: rect(band.minX + 4, band.minY, w - 4, labelH), align: .left)
        drawText(ctx, String(format: "%.0f%%", p), size: typography.value, bold: true, color: colors.primaryTextCG,
                 in: rect(band.minX, band.minY, w - 4, labelH), align: .right)
        let barY = band.minY + labelH
        let barH = min(max(band.height - labelH - capH - 4, 3), 6)
        drawProgress(ctx, rect(band.minX + 4, barY, w - 8, barH),
                     progress: p / 100, accent: accent, background: colors.borderCG)
        if capH > 0 {
            let capText = String(format: "%.0f / %.0f GB", toGiB(used), toGiB(total))
            var capSize = min(capH * 0.8, 8)
            var capW = measureTextWidth(capText, size: capSize, bold: false)
            if capW > w - 4 {
                capSize = max(capSize * (w - 4) / capW, 6)
                capW = measureTextWidth(capText, size: capSize, bold: false)
            }
            drawText(ctx, capText, size: capSize, bold: false, color: colors.tertiaryTextCG,
                     in: rect(band.minX, barY + barH, w, capH), align: .center)
        }
    }

    /// 额度类模块（标签 + 自定义数值文本 + 剩余进度条）
    private static func drawQuotaBand(_ ctx: CGContext, band: CGRect, label: String, value: String,
                                      progress: Double, accent: CGColor, colors: ScreenPalette) {
        let typography = canvasTypography()
        let p = min(max(progress, 0), 1)
        let labelH = max(band.height * 0.5, 10)
        drawText(ctx, label, size: typography.label, bold: false, color: colors.secondaryTextCG,
                 in: rect(band.minX + 4, band.minY, band.width - 4, labelH), align: .left)
        var size = typography.value
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

    /// 240×240 彩色屏的 Codex 专用信息架构。纵向键盘的“标签 + 一条进度”在方屏上
    /// 会浪费大面积空间，因此改为大指标、完整进度条和双信息格。
    private static func drawSquareCodexQuota(_ ctx: CGContext, band: CGRect,
                                             snapshot: UsageSnapshot, accent: CGColor,
                                             colors: ScreenPalette, now: Date) {
        let inner = band.insetBy(dx: 6, dy: 5)
        fillRound(ctx, rect(inner), radius: 12, color: colors.insetCG)
        strokeRound(ctx, rect(inner), radius: 12, color: colors.borderCG, width: 1)

        drawText(ctx, "CODEX", size: 16, bold: true, color: colors.primaryTextCG,
                 in: rect(inner.minX + 11, inner.minY + 8, 72, 23), align: .left)
        let source = snapshot.sourceName ?? "Codex 官方"
        let sourceSize = adaptiveFontSize(source, maxSize: 9.5, minSize: 7.5,
                                          bold: true, maxWidth: inner.width - 96)
        drawText(ctx, source, size: sourceSize, bold: true, color: accent,
                 in: rect(inner.minX + 86, inner.minY + 9, inner.width - 97, 21), align: .right)
        drawLine(ctx, x1: inner.minX + 10, y1: inner.minY + 35,
                 x2: inner.maxX - 10, y2: inner.minY + 35, color: colors.borderCG)

        if !snapshot.isAvailable {
            drawText(ctx, "—", size: 62, bold: true, color: colors.primaryTextCG,
                     in: rect(inner.minX + 10, inner.minY + 58, inner.width - 20, 72), align: .center)
            drawText(ctx, "尚未读取额度", size: 14, bold: true, color: colors.secondaryTextCG,
                     in: rect(inner.minX + 10, inner.minY + 134, inner.width - 20, 24), align: .center)
            return
        }

        drawText(ctx, snapshot.windowTitle, size: 13, bold: true, color: colors.secondaryTextCG,
                 in: rect(inner.minX + 10, inner.minY + 41, inner.width - 20, 20), align: .center)
        drawText(ctx, "\(snapshot.remainingPercent)%", size: 49, bold: true,
                 color: colors.primaryTextCG,
                 in: rect(inner.minX + 8, inner.minY + 57, inner.width - 16, 62), align: .center)
        drawProgress(ctx, rect(inner.minX + 13, inner.minY + 131, inner.width - 26, 8),
                     progress: Double(snapshot.remainingPercent) / 100,
                     accent: accent, background: colors.borderCG)

        let infoTop = inner.minY + 146
        let gap: CGFloat = 7
        let boxWidth = (inner.width - 20 - gap) / 2
        let left = CGRect(x: inner.minX + 10, y: infoTop, width: boxWidth, height: 53)
        let right = CGRect(x: left.maxX + gap, y: infoTop, width: boxWidth, height: 53)
        for box in [left, right] {
            fillRound(ctx, rect(box), radius: 8, color: colors.backgroundCG)
            strokeRound(ctx, rect(box), radius: 8, color: colors.borderCG, width: 1)
        }
        drawText(ctx, "周期", size: 9, bold: false, color: colors.tertiaryTextCG,
                 in: rect(left.minX + 7, left.minY + 6, left.width - 14, 14), align: .left)
        let cycle = snapshot.windowDescription
        drawText(ctx, cycle, size: adaptiveFontSize(cycle, maxSize: 13, minSize: 9,
                                                    bold: true, maxWidth: left.width - 14),
                 bold: true, color: colors.primaryTextCG,
                 in: rect(left.minX + 7, left.minY + 22, left.width - 14, 22), align: .left)

        let rightLabel: String
        let rightValue: String
        if let value = snapshot.remainingValue, let unit = snapshot.usageUnit, unit != "%" {
            rightLabel = "剩余额度"
            rightValue = value >= 100 ? String(format: "%.0f %@", value, unit)
                : String(format: "%.1f %@", value, unit)
        } else if let reset = snapshot.resetDate {
            rightLabel = "下次重置"
            rightValue = formatDate(reset, "M/d HH:mm")
        } else {
            rightLabel = "数据更新"
            rightValue = formatDate(snapshot.sampledAt ?? now, "HH:mm")
        }
        drawText(ctx, rightLabel, size: 9, bold: false, color: colors.tertiaryTextCG,
                 in: rect(right.minX + 7, right.minY + 6, right.width - 14, 14), align: .left)
        drawText(ctx, rightValue,
                 size: adaptiveFontSize(rightValue, maxSize: 13, minSize: 8.5,
                                        bold: true, maxWidth: right.width - 14),
                 bold: true, color: accent,
                 in: rect(right.minX + 7, right.minY + 22, right.width - 14, 22), align: .left)
    }

    /// 240×240 彩色屏的千问额度专用布局，与 Codex 方屏卡片保持同一视觉骨架。
    private static func drawSquareQwenQuota(_ ctx: CGContext, band: CGRect,
                                            quota: QwenWorkQuota, showPercent: Bool,
                                            accent: CGColor, colors: ScreenPalette) {
        let inner = band.insetBy(dx: 6, dy: 5)
        fillRound(ctx, rect(inner), radius: 12, color: colors.insetCG)
        strokeRound(ctx, rect(inner), radius: 12, color: colors.borderCG, width: 1)
        drawText(ctx, "千问额度", size: 16, bold: true, color: colors.primaryTextCG,
                 in: rect(inner.minX + 11, inner.minY + 8, 88, 23), align: .left)
        drawText(ctx, quota.plan ?? "千问办公", size: 9.5, bold: true, color: accent,
                 in: rect(inner.minX + 102, inner.minY + 9, inner.width - 113, 21), align: .right)
        drawLine(ctx, x1: inner.minX + 10, y1: inner.minY + 35,
                 x2: inner.maxX - 10, y2: inner.minY + 35, color: colors.borderCG)

        guard quota.available else {
            drawText(ctx, "—", size: 62, bold: true, color: colors.primaryTextCG,
                     in: rect(inner.minX + 10, inner.minY + 58, inner.width - 20, 72), align: .center)
            drawText(ctx, "尚未读取额度", size: 14, bold: true, color: colors.secondaryTextCG,
                     in: rect(inner.minX + 10, inner.minY + 134, inner.width - 20, 24), align: .center)
            return
        }

        drawText(ctx, showPercent ? "当前剩余" : "可用额度", size: 13, bold: true,
                 color: colors.secondaryTextCG,
                 in: rect(inner.minX + 10, inner.minY + 41, inner.width - 20, 20), align: .center)
        if showPercent {
            let percent = quota.trackedProgress.map { Int(($0 * 100).rounded()) }
            drawText(ctx, percent.map { "\($0)%" } ?? "—%", size: 49, bold: true,
                     color: colors.primaryTextCG,
                     in: rect(inner.minX + 8, inner.minY + 57, inner.width - 16, 62), align: .center)
        } else {
            let parts = quotaNumberParts(quota.remainingCredits)
            drawQuotaNumber(ctx, whole: parts.whole, fraction: parts.fraction,
                            suffix: "", size: 48, color: colors.primaryTextCG,
                            in: rect(inner.minX + 12, inner.minY + 59, inner.width - 24, 64),
                            align: .center)
        }
        drawProgress(ctx, rect(inner.minX + 13, inner.minY + 131, inner.width - 26, 8),
                     progress: quota.progress, accent: accent, background: colors.borderCG)

        let infoTop = inner.minY + 146
        let gap: CGFloat = 7
        let boxWidth = (inner.width - 20 - gap) / 2
        let left = CGRect(x: inner.minX + 10, y: infoTop, width: boxWidth, height: 53)
        let right = CGRect(x: left.maxX + gap, y: infoTop, width: boxWidth, height: 53)
        for box in [left, right] {
            fillRound(ctx, rect(box), radius: 8, color: colors.backgroundCG)
            strokeRound(ctx, rect(box), radius: 8, color: colors.borderCG, width: 1)
        }
        drawText(ctx, "额度数值", size: 9, bold: false, color: colors.tertiaryTextCG,
                 in: rect(left.minX + 7, left.minY + 6, left.width - 14, 14), align: .left)
        let amount = String(format: "%.2f", quota.remainingCredits)
        drawText(ctx, amount, size: adaptiveFontSize(amount, maxSize: 13, minSize: 9,
                                                     bold: true, maxWidth: left.width - 14),
                 bold: true, color: colors.primaryTextCG,
                 in: rect(left.minX + 7, left.minY + 22, left.width - 14, 22), align: .left)
        drawText(ctx, "数据更新", size: 9, bold: false, color: colors.tertiaryTextCG,
                 in: rect(right.minX + 7, right.minY + 6, right.width - 14, 14), align: .left)
        drawText(ctx, formatDate(quota.sampledAt, "HH:mm"), size: 13, bold: true, color: accent,
                 in: rect(right.minX + 7, right.minY + 22, right.width - 14, 22), align: .left)
    }

    /// 240×240 彩色小屏幕的正在播放专用布局：封面、歌曲信息、完整进度条，
    /// 以及已播放/剩余时间均拥有固定区域，不再被方屏通用模块裁掉。
    private static func drawSquareNowPlaying(_ ctx: CGContext, band: CGRect,
                                             info: NowPlayingInfo, accent: CGColor,
                                             colors: ScreenPalette,
                                             showCover: Bool) {
        let inner = band.insetBy(dx: 6, dy: 5)
        fillRound(ctx, rect(inner), radius: 12, color: colors.insetCG)
        strokeRound(ctx, rect(inner), radius: 12, color: colors.borderCG, width: 1)

        drawText(ctx, "正在播放", size: 16, bold: true, color: colors.primaryTextCG,
                 in: rect(inner.minX + 11, inner.minY + 7, 96, 24), align: .left)
        let stateText = info.isPlaying ? "播放中" : "已暂停"
        let stateBox = CGRect(x: inner.maxX - 69, y: inner.minY + 7,
                              width: 58, height: 23)
        fillRound(ctx, rect(stateBox), radius: 10,
                  color: accent.copy(alpha: 0.15) ?? accent)
        drawText(ctx, stateText, size: 10, bold: true, color: accent,
                 in: rect(stateBox), align: .center)
        drawLine(ctx, x1: inner.minX + 10, y1: inner.minY + 35,
                 x2: inner.maxX - 10, y2: inner.minY + 35, color: colors.borderCG)

        let coverBox = CGRect(x: inner.minX + 10, y: inner.minY + 45,
                              width: 88, height: 88)
        if showCover, let artwork = info.artwork.flatMap({ decodeArtwork($0) }) {
            drawCoverGlow(ctx, color: boostedGlowColor(dominantColor(of: artwork)),
                          coverSkia: coverBox, extent: 14, blurSigma: 7,
                          innerInset: 2, cornerRadius: 10, opacity: 0.62)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect(coverBox), cornerWidth: 10,
                               cornerHeight: 10, transform: nil))
            ctx.clip()
            ctx.interpolationQuality = .high
            ctx.draw(artwork, in: rect(coverBox))
            ctx.restoreGState()
            strokeRound(ctx, rect(coverBox), radius: 10, color: colors.borderCG, width: 1)
        } else {
            fillRound(ctx, rect(coverBox), radius: 10, color: colors.backgroundCG)
            strokeRound(ctx, rect(coverBox), radius: 10, color: colors.borderCG, width: 1)
            drawText(ctx, "♪", size: 42, bold: true, color: accent,
                     in: rect(coverBox), align: .center)
        }

        let textX = coverBox.maxX + 12
        let textW = max(inner.maxX - textX - 10, 30)
        let title = info.title.isEmpty ? "未在播放" : info.title
        var titleSize: CGFloat = 15
        var titleLines = wrapText(title, maxWidth: textW, size: titleSize)
        while (titleLines.count > 2 || CGFloat(titleLines.count) * titleSize * 1.2 > 42),
              titleSize > 9 {
            titleSize -= 0.5
            titleLines = wrapText(title, maxWidth: textW, size: titleSize)
        }
        titleLines = Array(titleLines.prefix(2))
        for (index, line) in titleLines.enumerated() {
            drawText(ctx, line, size: titleSize, bold: true, color: colors.primaryTextCG,
                     in: rect(textX, inner.minY + 49 + CGFloat(index) * titleSize * 1.18,
                              textW, titleSize * 1.22), align: .left)
        }
        let artist = info.artist.isEmpty ? "未知歌手" : info.artist
        drawAdaptiveText(ctx, artist, maxSize: 11.5, minSize: 8, bold: true,
                         color: colors.secondaryTextCG,
                         in: rect(textX, inner.minY + 94, textW, 17), align: .left)
        let source = info.album.isEmpty ? (info.appName ?? "本机媒体") : info.album
        drawAdaptiveText(ctx, source, maxSize: 9.5, minSize: 7, bold: false,
                         color: colors.tertiaryTextCG,
                         in: rect(textX, inner.minY + 114, textW, 15), align: .left)

        let progressY = inner.minY + 145
        drawProgress(ctx, rect(inner.minX + 11, progressY, inner.width - 22, 7),
                     progress: info.progress, accent: accent, background: colors.borderCG)
        let elapsed = info.duration > 0 ? formatClock(info.elapsedTime) : "--:--"
        let remainingSeconds = max(info.duration - info.elapsedTime, 0)
        let remaining = info.duration > 0 ? formatClock(remainingSeconds) : "--:--"
        drawText(ctx, "已播放  \(elapsed)", size: 10, bold: true,
                 color: colors.secondaryTextCG,
                 in: rect(inner.minX + 11, progressY + 13,
                          (inner.width - 22) / 2, 18), align: .left)
        drawText(ctx, "剩余  \(remaining)", size: 10, bold: true,
                 color: colors.secondaryTextCG,
                 in: rect(inner.midX, progressY + 13,
                          inner.width / 2 - 11, 18), align: .right)

        let total = info.duration > 0 ? formatClock(info.duration) : "--:--"
        let footerBox = CGRect(x: inner.minX + 10, y: progressY + 38,
                               width: inner.width - 20,
                               height: max(inner.maxY - progressY - 48, 20))
        fillRound(ctx, rect(footerBox), radius: 8, color: colors.backgroundCG)
        drawText(ctx, "总时长  \(total)", size: 10, bold: true, color: accent,
                 in: rect(footerBox.minX + 8, footerBox.minY,
                          footerBox.width - 16, footerBox.height), align: .center)
    }

    /// 千问办公额度数值拆分为整数与小数两部分（精确到两位小数；小数部分渲染时字号减半）
    public static func quotaNumberParts(_ credits: Double) -> (whole: String, fraction: String) {
        let scaled = (credits * 100).rounded()
        let whole = Int(scaled / 100)
        let fraction = Int(scaled) % 100
        return (String(whole), String(format: "%02d", fraction))
    }

    /// 绘制额度数值：整数部分大字 + 小数部分（含小数点）半字号，共享基线；
    /// 可选右侧小字后缀（单位/百分比）；宽度不足时整体收缩字号。对齐方式支持左/右/居中。
    private static func drawQuotaNumber(_ ctx: CGContext, whole: String, fraction: String,
                                        suffix: String = "", size: CGFloat,
                                        suffixSize: CGFloat = 9,
                                        color: CGColor, in bounds: CGRect,
                                        align: NSTextAlignment = .left) {
        let wholeFontName = "PingFangSC-Semibold"
        let fractionSize = max(size * 0.5, 6)
        let wholeW0 = measureTextWidth(whole, size: size, bold: true)
        let fractionW0 = measureTextWidth("." + fraction, size: fractionSize, bold: true)
        let suffixW0 = suffix.isEmpty ? 0 : measureTextWidth(suffix, size: suffixSize, bold: false)
        let gap: CGFloat = suffix.isEmpty ? 0 : 4
        var total = wholeW0 + fractionW0 + gap + suffixW0
        var wholeSize = size
        var fracSize = fractionSize
        if total > bounds.width, size > 7 {
            wholeSize = max(size * bounds.width / total, 7)
            fracSize = max(wholeSize * 0.5, 6)
            total = measureTextWidth(whole, size: wholeSize, bold: true)
                + measureTextWidth("." + fraction, size: fracSize, bold: true)
                + gap + suffixW0
        }
        let wholeFont = CTFontCreateWithName(wholeFontName as CFString, wholeSize, nil)
        let fractionFont = CTFontCreateWithName(wholeFontName as CFString, fracSize, nil)
        let suffixFont = CTFontCreateWithName("PingFangSC-Regular" as CFString, suffixSize, nil)
        let attrs = { (font: CTFont) -> [NSAttributedString.Key: Any] in [.font: font, .foregroundColor: color] }
        let wholeLine = CTLineCreateWithAttributedString(NSAttributedString(string: whole, attributes: attrs(wholeFont)))
        let fractionLine = CTLineCreateWithAttributedString(NSAttributedString(string: "." + fraction, attributes: attrs(fractionFont)))
        let suffixLine = suffix.isEmpty ? nil
            : CTLineCreateWithAttributedString(NSAttributedString(string: suffix, attributes: attrs(suffixFont)))
        let wholeW = CGFloat(CTLineGetTypographicBounds(wholeLine, nil, nil, nil))
        let fractionW = CGFloat(CTLineGetTypographicBounds(fractionLine, nil, nil, nil))
        let suffixW = suffixLine.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) } ?? 0
        let totalW = wholeW + fractionW + gap + suffixW
        let ascent = CTFontGetAscent(wholeFont)
        let descent = CTFontGetDescent(wholeFont)
        let baselineY = bounds.midY - (ascent + descent) / 2
        let startX: CGFloat
        switch align {
        case .right: startX = bounds.maxX - totalW
        case .center: startX = bounds.midX - totalW / 2
        default: startX = bounds.minX
        }
        ctx.textPosition = CGPoint(x: startX, y: baselineY)
        CTLineDraw(wholeLine, ctx)
        ctx.textPosition = CGPoint(x: startX + wholeW, y: baselineY)
        CTLineDraw(fractionLine, ctx)
        if let suffixLine {
            ctx.textPosition = CGPoint(x: startX + wholeW + fractionW + gap, y: baselineY)
            CTLineDraw(suffixLine, ctx)
        }
    }

    /// 千问额度模块横带：两端对齐（与 CPU/内存模块一致）——标签贴左缘、主指标贴右缘、
    /// 进度条横贯其中；紧凑块行高固定、整块垂直居中，band 高时不被撑开分散。
    /// showPercent=true 只显示百分比（隐藏额度数字）；false 只显示额度数字
    private static func drawQwenQuotaBand(_ ctx: CGContext, band: CGRect,
                                          whole: String, fraction: String,
                                          unit: String, percent: String,
                                          progress: Double, accent: CGColor, colors: ScreenPalette,
                                          showPercent: Bool) {
        let typography = canvasTypography()
        let p = min(max(progress, 0), 1)
        let w = band.width
        if band.height >= 46 {
            // 紧凑块：标签/指标行（两端对齐）+ 进度条贴合，整块垂直居中
            let labelH: CGFloat = 18
            let barH: CGFloat = 6
            let gap: CGFloat = 3
            let blockH = labelH + gap + barH
            let blockTop = band.minY + max((band.height - blockH) / 2, 0)
            drawText(ctx, "千问", size: typography.label, bold: false, color: colors.secondaryTextCG,
                     in: rect(band.minX + 4, blockTop, w - 4, labelH), align: .left)
            if showPercent {
                // 百分比模式：只显示百分比（隐藏具体额度数字）
                if !percent.isEmpty {
                    drawText(ctx, percent, size: typography.value, bold: true, color: colors.primaryTextCG,
                             in: rect(band.minX, blockTop, w - 4, labelH), align: .right)
                }
            } else {
                // 额度数值模式：只显示额度数字（无单位/百分比），贴右缘与标签两端对齐
                drawQuotaNumber(ctx, whole: whole, fraction: fraction, suffix: "", size: typography.value,
                                color: colors.primaryTextCG,
                                in: rect(band.minX, blockTop, w - 4, labelH), align: .right)
            }
            let barY = blockTop + labelH + gap
            drawProgress(ctx, rect(band.minX + 4, barY, w - 8, barH),
                         progress: p, accent: accent, background: colors.borderCG)
        } else {
            // 矮条带两行紧凑：标签左 + 指标右（两端对齐），进度条横贯
            let labelH = max(band.height * 0.5, 10)
            drawText(ctx, "千问", size: typography.label, bold: false, color: colors.secondaryTextCG,
                     in: rect(band.minX + 4, band.minY, 44, labelH), align: .left)
            let numberX = band.minX + 48
            let numberW = max(w - 52, 20)
            if showPercent {
                if !percent.isEmpty {
                    drawText(ctx, percent, size: typography.value, bold: true, color: colors.primaryTextCG,
                             in: rect(numberX, band.minY, numberW, labelH), align: .right)
                }
            } else {
                drawQuotaNumber(ctx, whole: whole, fraction: fraction, suffix: "", size: typography.value,
                                color: colors.primaryTextCG,
                                in: rect(numberX, band.minY, numberW, labelH), align: .right)
            }
            let barH = min(max(band.height - labelH - 4, 3), 6)
            drawProgress(ctx, rect(band.minX + 4, band.minY + labelH, w - 8, barH),
                         progress: p, accent: accent, background: colors.borderCG)
        }
    }

    public static func renderCustomImage(path: String, settings: AppSettings,
                                         now: Date = Date()) throws -> RenderResult {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RenderError.cannotDecodeImage
        }
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        // 背景铺黑
        ColorCardSceneCapture.attach(ctx)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 图片忽略全局顶部安全区，铺满整个屏幕显示范围（裁剪填充、不变形）
        let target = rect(0, 0, CGFloat(width), CGFloat(height))
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
        let clockColors = wallpaperClockColors(of: cropped, style: settings.wallpaperColorStyle)
        let primaryText = CGColor(red: clockColors.primary.0, green: clockColors.primary.1,
                                  blue: clockColors.primary.2, alpha: 1)
        let secondaryText = CGColor(red: clockColors.secondary.0, green: clockColors.secondary.1,
                                    blue: clockColors.secondary.2, alpha: 1)
        let primaryOutline = CGColor(red: clockColors.primaryOutline.0,
                                     green: clockColors.primaryOutline.1,
                                     blue: clockColors.primaryOutline.2, alpha: 1)
        let secondaryOutline = CGColor(red: clockColors.secondaryOutline.0,
                                       green: clockColors.secondaryOutline.1,
                                       blue: clockColors.secondaryOutline.2, alpha: 1)
        let shadowText = clockColors.usesLightTones
            ? CGColor(red: 0, green: 0, blue: 0, alpha: 0.62)
            : CGColor(red: 1, green: 1, blue: 1, alpha: 0.56)
        drawClockOverlay(ctx, overlay: settings.customImageClock, safeArea: safe, now: now,
                         fontSize: CGFloat(settings.clockFontSize),
                         timeFormat: settings.timeFormat,
                         dateFormat: settings.dateFormat,
                         showDate: settings.clockDateVisible,
                         stackedFontName: "Arial-Black",
                         offsetX: CGFloat(settings.clockOffsetX),
                         offsetY: CGFloat(settings.clockOffsetY),
                         primaryText: primaryText,
                         secondaryText: secondaryText,
                         primaryOutline: primaryOutline,
                         secondaryOutline: secondaryOutline,
                         shadowText: shadowText)
        return try encode(ctx, quality: settings.jpegQuality)
    }

    // MARK: - 自定义图片时钟叠加

    /// 在自定义图片上叠加 2×2 Pixel 大时钟。四位数字与日期作为一个图层组统一缩放，
    /// 因此调节整体大小不会改变字间距；前景使用壁纸种子色生成的 Material You 色调阶。
    private static func drawClockOverlay(_ ctx: CGContext, overlay: CustomImageClockOverlay,
                                         safeArea: CGFloat, now: Date,
                                         fontSize: CGFloat, timeFormat: String, dateFormat: String,
                                         showDate: Bool,
                                         stackedFontName: String,
                                         offsetX: CGFloat, offsetY: CGFloat,
                                         primaryText: CGColor, secondaryText: CGColor,
                                         primaryOutline: CGColor, secondaryOutline: CGColor,
                                         shadowText: CGColor) {
        let resolvedOverlay = overlay.stackedOnly
        guard resolvedOverlay != .none else { return }
        let dateText = formatDate(now, dateFormat)
        let timeText = clockTimeText(now, format: timeFormat)

        switch resolvedOverlay {
        case .none:
            return
        case .verticalLeft, .verticalCenter:
            // 所有几何先以最大尺寸建立，再通过同一个 CTM 整体缩放；数字、错位、行列间距、
            // 描边、阴影和日期始终保持固定比例，避免旧版缩小时字与字逐渐松散。
            let digits = stackedClockDigits(timeText, now: now)
            let groupScale = StackedClockSizing.scale(for: Int(fontSize.rounded()))
            let blockW = CGFloat(width) - 8
            let cellW = blockW * 0.56
            let digitSize = adaptiveFontSize("8", maxSize: 118, minSize: 72,
                                             fontName: stackedFontName,
                                             maxWidth: cellW - 8)
            let digitH = digitSize * 1.04
            // Arial Black 保留块状轮廓，再把字形本身纵向压缩，得到更扁、更紧密的锁屏数字。
            // 这里使用 CGContext 变换压缩实际轮廓，而不是只缩短文字框。
            let digitVerticalScale: CGFloat = 0.76
            // CoreText 的 strokeWidth 单位是字号百分比：在原 4% 基础上再增加 4px。
            let digitStrokeWidth = 4 + 400 / digitSize
            // CoreText 描边以字形边缘为中心，外轮廓需要增加两倍线宽，才能让可见边缘
            // 比数字本体向外扩展约 5px。它位于同一个 CTM 内，会随整组同步缩放。
            let digitOutlineStrokeWidth = digitStrokeWidth
                + StackedClockSizing.outlineExpansion * 200 / digitSize
            // 两行继续适度叠压；压扁后的可见轮廓仍保持清楚，不会散成四个独立方块。
            let rowAdvance = digitSize * 0.56
            let dateH: CGFloat = showDate ? 24 : 0
            let dateGap: CGFloat = showDate ? 24 : 0
            let visibleDigitBottom = digitH * (1 + digitVerticalScale) / 2
            let totalH = rowAdvance + visibleDigitBottom + dateGap + dateH + 4
            let scaledTotalH = totalH * groupScale
            let finalTop = (resolvedOverlay == .verticalCenter
                ? max((CGFloat(height) - scaledTotalH) / 2, safeArea + 6)
                : safeArea + 14) + offsetY
            let groupCenterY = finalTop + scaledTotalH / 2
            let groupCenterX = CGFloat(width) / 2 + offsetX
            let startY = groupCenterY - totalH / 2
            let blockX = groupCenterX - blockW / 2
            let columnAdvance = blockW * 0.41
            let positions: [(CGFloat, CGFloat)] = [
                (0, 0),
                (columnAdvance, digitSize * 0.02),
                (digitSize * 0.03, rowAdvance),
                (columnAdvance + digitSize * 0.02, rowAdvance + digitSize * 0.035)
            ]
            let digitColors = [primaryText, secondaryText, secondaryText, primaryText]
            let digitOutlineColors = [primaryOutline, secondaryOutline,
                                      secondaryOutline, primaryOutline]

            // Skia 语义的 y 向下；CGContext 的变换中心需换算到左下角坐标。
            let groupCenterCG = CGPoint(x: groupCenterX,
                                        y: CGFloat(height) - groupCenterY)
            ctx.saveGState()
            ctx.translateBy(x: groupCenterCG.x, y: groupCenterCG.y)
            ctx.scaleBy(x: groupScale, y: groupScale)
            ctx.translateBy(x: -groupCenterCG.x, y: -groupCenterCG.y)
            // 与四位数字、日期共享变换，移动和缩放时始终是同一个图层组。
            // 经典模式下此调用不绘制任何内容，保持壁纸和时钟原样。
            for index in 0..<4 {
                let position = positions[index]
                drawTextShadowed(ctx, String(digits[index]), size: digitSize, bold: false,
                                 color: digitColors[index],
                                 in: rect(blockX + position.0, startY + position.1,
                                          cellW, digitH), align: .center,
                                 fontName: stackedFontName, shadowColor: shadowText,
                                 shadowAlpha: 1, shadowOffset: 1.15,
                                 verticalScale: digitVerticalScale,
                                 strokeWidth: digitStrokeWidth,
                                 strokeColor: digitColors[index],
                                 outerStrokeWidth: digitOutlineStrokeWidth,
                                 outerStrokeColor: digitOutlineColors[index])
            }
            if showDate {
                let dateY = startY + rowAdvance + visibleDigitBottom + dateGap
                let dateSize = adaptiveFontSize(dateText, maxSize: 14, minSize: 8,
                                                bold: true, maxWidth: blockW)
                drawTextShadowed(ctx, dateText, size: dateSize, bold: true,
                                 color: secondaryText,
                                 in: rect(blockX, dateY, blockW, dateH),
                                 align: .center,
                                 shadowColor: shadowText, shadowAlpha: 1, shadowOffset: 0.7)
            }
            ctx.restoreGState()
        case .horizontalTop, .horizontalBottom:
            // 只为旧枚举值保留穷尽分支；stackedOnly 已在进入 switch 前完成迁移。
            return
        }
    }

    /// 从任意用户时间格式中提取小时/分钟，并稳定补齐为四位；叠排样式不显示秒。
    private static func stackedClockDigits(_ timeText: String, now: Date) -> [Character] {
        let groups = timeText.split(whereSeparator: { !$0.isNumber }).map(String.init)
        if groups.count >= 2, let hour = groups.first, let minute = groups.dropFirst().first {
            let hourDigits = String(hour.suffix(2))
            let minuteDigits = String(minute.prefix(2))
            let normalized = String(repeating: "0", count: max(0, 2 - hourDigits.count)) + hourDigits
                + String(repeating: "0", count: max(0, 2 - minuteDigits.count)) + minuteDigits
            return Array(normalized.prefix(4))
        }
        return Array(formatDate(now, "HHmm"))
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

    /// 带轻量投影的文字（CG 坐标矩形；投影向右下偏 1px，提升任意底图上的可读性）。
    /// shadowAlpha/shadowOffset 可调淡（浅色背景页脚用淡投影，避免抢眼）
    private static func drawTextShadowed(_ ctx: CGContext, _ text: String, size: CGFloat, bold: Bool,
                                         color: CGColor, in boundsCG: CGRect, align: NSTextAlignment,
                                         fontName: String? = nil,
                                         shadowColor: CGColor? = nil,
                                         shadowAlpha: CGFloat = 0.55,
                                         shadowOffset: CGFloat = 0.9,
                                         verticalScale: CGFloat = 1,
                                         strokeWidth: CGFloat? = nil,
                                         strokeColor: CGColor? = nil,
                                         outerStrokeWidth: CGFloat? = nil,
                                         outerStrokeColor: CGColor? = nil) {
        let resolvedShadowColor: CGColor
        if let shadowColor {
            resolvedShadowColor = shadowColor.copy(alpha: shadowColor.alpha * shadowAlpha)
                ?? shadowColor
        } else {
            resolvedShadowColor = CGColor(red: 0, green: 0, blue: 0, alpha: shadowAlpha)
        }
        let shadow = CGRect(x: boundsCG.origin.x + shadowOffset, y: boundsCG.origin.y - shadowOffset,
                            width: boundsCG.width, height: boundsCG.height)
        func drawLayer(color layerColor: CGColor, bounds: CGRect,
                       strokeWidth: CGFloat? = nil, strokeColor: CGColor? = nil) {
            if verticalScale != 1 {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: bounds.midY)
                ctx.scaleBy(x: 1, y: verticalScale)
                ctx.translateBy(x: 0, y: -bounds.midY)
            }
            drawText(ctx, text, size: size, bold: bold, color: layerColor,
                     in: bounds, align: align, fontName: fontName,
                     strokeWidth: strokeWidth, strokeColor: strokeColor)
            if verticalScale != 1 {
                ctx.restoreGState()
            }
        }
        // 先铺阴影，再铺更宽的浅色外轮廓，最后用数字本体覆盖轮廓内部。
        // 外轮廓与本体复用完全相同的字形和纵向压缩中心，不会产生错位。
        drawLayer(color: resolvedShadowColor, bounds: shadow)
        if let outerStrokeWidth, let outerStrokeColor {
            drawLayer(color: outerStrokeColor, bounds: boundsCG,
                      strokeWidth: outerStrokeWidth, strokeColor: outerStrokeColor)
        }
        drawLayer(color: color, bounds: boundsCG,
                  strokeWidth: strokeWidth, strokeColor: strokeColor)
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

        if !quota.available {
            drawText(ctx, "尚未读取", size: 18, bold: true, color: colors.primaryTextCG,
                     in: rect(c.minX + 8, c.minY + 145, c.width - 16, 32), align: .center)
            drawText(ctx, "请运行千问办公后刷新", size: 9, bold: false,
                     color: colors.secondaryTextCG,
                     in: rect(c.minX + 8, c.minY + 180, c.width - 16, 24), align: .center)
            return try encode(ctx, quality: settings.jpegQuality)
        }

        let top = c.minY + 49
        drawText(ctx, "剩余额度", size: 10, bold: true, color: colors.secondaryTextCG,
                 in: rect(c.minX + 9, top, c.maxX - c.minX - 18, 18), align: .center)
        // 额度精确到两位小数：整数大字 + 小数（含小数点）半字号，整体居中
        let parts = quotaNumberParts(quota.remainingCredits)
        drawQuotaNumber(ctx, whole: parts.whole, fraction: parts.fraction, size: 30,
                        color: colors.primaryTextCG,
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

    /// HA 多实体行是否需要改成上下排布。
    /// 名称和值任一过长，或两者总宽度放不进同一行时，切换为「名称在上、状态在下」，
    /// 避免在窄屏里把双方都压缩成难以辨认的省略文本。
    public static func haRowUsesStackedLayout(name: String, value: String,
                                              availableWidth: CGFloat,
                                              nameSize: CGFloat = 10,
                                              valueSize: CGFloat = 11) -> Bool {
        guard availableWidth > 0 else { return true }
        let minimumNameSize = max(nameSize - 2, 6)
        let minimumValueSize = max(valueSize - 2, 6)
        let nameW = measureTextWidth(name, size: minimumNameSize, bold: true)
        let valueW = measureTextWidth(value, size: minimumValueSize, bold: true)
        return nameW + valueW + 6 > availableWidth
            || nameW > availableWidth * 0.62
            || valueW > availableWidth * 0.46
    }

    /// 在 HA 卡片可用区域里排列实体行：同一页所有卡片取可见行所需的最大高度，
    /// 保证外框严格等高；剩余空间均匀分到顶部、行间和底部。
    /// 返回能完整容纳的前缀行；调用方可据此显示“另有 N 项”。
    public static func haAdaptiveRowFrames(minimumHeights: [CGFloat], region: CGRect,
                                           baseGap: CGFloat = 4) -> [CGRect] {
        guard !minimumHeights.isEmpty, region.width > 0, region.height > 0 else { return [] }
        let heights = minimumHeights.map { max($0, 1) }
        var visible: [CGFloat] = []
        for height in heights {
            let candidate = visible + [height]
            let equalHeight = candidate.max() ?? height
            let required = equalHeight * CGFloat(candidate.count)
                + baseGap * CGFloat(max(candidate.count - 1, 0))
            guard required <= region.height else { break }
            visible = candidate
        }
        if visible.isEmpty {
            visible = [min(heights[0], region.height)]
        }
        let equalHeight = min(visible.max() ?? 1,
                              (region.height - baseGap * CGFloat(max(visible.count - 1, 0)))
                                  / CGFloat(visible.count))
        let internalGaps = baseGap * CGFloat(max(visible.count - 1, 0))
        let spare = max(region.height - equalHeight * CGFloat(visible.count) - internalGaps, 0)
        let adaptiveInset = spare / CGFloat(visible.count + 1)
        var y = region.minY + adaptiveInset
        return visible.map { _ in
            let frame = CGRect(x: region.minX, y: y, width: region.width, height: equalHeight)
            y += equalHeight + baseGap + adaptiveInset
            return frame
        }
    }

    /// Home Assistant 独立卡片单页最多显示的实体数；超出部分在底部显示数量提示。
    public static let haStandalonePageLimit = 4

    /// Home Assistant 键盘卡片：支持多实体与 camera/image 静态帧；单个图片实体
    /// 使用大图，多实体中的图片实体使用等高横向预览卡，其余实体保持状态列表排布。
    /// 实体图标优先 attributes.icon 的 mdi 名映射 SF Symbol，否则按实体域默认图标；
    /// 加载失败/未配置时显示明确提示而非空白；
    /// 已绑定但在当前服务器查不到的实体按「失效」灰显行保留原值（换服务器后不静默消失、不错绑）
    public static func renderHA(_ entities: [HAEntity], aliases: [String: String] = [:],
                                missing: [(id: String, name: String, lastValue: String)] = [],
                                images: [String: Data] = [:],
                                errorText: String?, settings: AppSettings,
                                now: Date = Date()) throws -> RenderResult {
        let colors = settings.resolvedPalette
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let c = drawCanvas(ctx, safeArea: safe, colors: colors)
        let accent = colors.accentCG
        drawHeader(ctx, card: c, title: "HOME", badge: "HA",
                   accent: accent, colors: colors, titleSize: 7.5)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)
        let top = c.minY + 49
        // HA 页脚仅作为辅助信息，不沿用其他卡片的大号时间/日期层级。
        let footerSpace: CGFloat = settings.nowPlayingFooterVisible ? 28 : 8
        let contentBottom = c.maxY - footerSpace
        // 统一排布项：在线实体在前，失效绑定在后（灰显 + 保留最后一次已知值）
        var displayItems: [(id: String, name: String, value: String, icon: String,
                            off: Bool, stale: Bool, picture: Data?)] = entities.map { entity in
            (entity.entityId, aliases[entity.entityId] ?? entity.displayName, entity.displayValue,
             SFIconMapper.symbol(for: entity), entity.state.lowercased() == "off", false,
             images[entity.entityId])
        }
        for stale in missing {
            displayItems.append((stale.id, stale.name,
                                 stale.lastValue.isEmpty ? "失效" : "失效 · \(stale.lastValue)",
                                 SFIconMapper.symbol(icon: nil, domain: HAEntityPicker.domain(of: stale.id)),
                                 false, true, nil))
        }
        if entities.count == 1, missing.isEmpty {
            // 单实体：图标 + 名称（支持自定义别名）+ 大字状态值；
            // image.* 实体（带画面）改为大图画 + 底部一行名称与状态
            let entity = entities[0]
            let singleName = aliases[entity.entityId] ?? entity.displayName
            if let picture = images[entity.entityId] {
                let infoH: CGFloat = 20
                let box = CGRect(x: c.minX + 9, y: top,
                                 width: c.maxX - c.minX - 18,
                                 height: max(40, contentBottom - top - infoH - 2))
                if drawImageData(ctx, data: picture, into: box, cover: true, radius: 6) {
                    strokeRound(ctx, rect(box), radius: 6, color: colors.borderCG, width: 1)
                }
                let lineY = box.maxY + 3
                drawText(ctx, singleName, size: 9, bold: false, color: colors.secondaryTextCG,
                         in: rect(c.minX + 9, lineY, (c.maxX - c.minX - 18) * 0.6, infoH), align: .left)
                drawText(ctx, entity.displayValue, size: 11, bold: true, color: colors.primaryTextCG,
                         in: rect(c.minX + 9, lineY, c.maxX - c.minX - 18, infoH), align: .right)
            } else {
                drawEntityIcon(ctx, symbol: SFIconMapper.symbol(for: entity),
                               in: rect(c.minX + 9, top + 3, 16, 16), color: colors.secondaryTextCG)
                drawText(ctx, singleName, size: 10, bold: true, color: colors.secondaryTextCG,
                         in: rect(c.minX + 28, top, c.maxX - c.minX - 34, 20), align: .center)
                let value = entity.displayValue
                var size: CGFloat = 28
                var tw = measureTextWidth(value, size: size, bold: true)
                let maxW = c.maxX - c.minX - 16
                if tw > maxW {
                    size = max(size * maxW / tw, 14)
                    tw = measureTextWidth(value, size: size, bold: true)
                }
                drawText(ctx, value, size: size, bold: true, color: accent,
                         in: rect(c.minX + 8, top + 22, maxW, 44), align: .center)
                drawText(ctx, entity.entityId, size: 8, bold: false, color: colors.tertiaryTextCG,
                         in: rect(c.minX + 9, top + 70, c.maxX - c.minX - 18, 14), align: .center)
            }
        } else if !displayItems.isEmpty {
            // 多实体：短文本左右对齐；名称/状态任一过长时自动切换为上下两行；
            // 上行名称占满内容区，下行状态右对齐，避免双方在同一行互相挤压；
            // 名称完整显示（字号自适应收缩，必要时两行换行）；
            // 失效绑定同列表灰显排在后面，值位显示「失效 · 最后已知值」
            let shown = Array(displayItems.prefix(haStandalonePageLimit))
            let cardX = c.minX + 8
            let cardW = c.maxX - c.minX - 16
            let contentX0 = cardX + 25            // 名称/状态区左起点（图标之后）
            let contentX1 = cardX + cardW - 6     // 内容区右缘
            let availableW = contentX1 - contentX0

            // 先测量每一行的最小卡片高度，再由可用高度统一分配上下/行间留白。
            // 这样 2–3 个实体会自然铺开，4 个实体仍保持紧凑且不会互相覆盖。
            let minimumHeights: [CGFloat] = shown.map { item in
                if item.picture != nil { return 74 }
                let stacked = haRowUsesStackedLayout(name: item.name, value: item.value,
                                                      availableWidth: availableW)
                if stacked {
                    var nameSize: CGFloat = 10
                    while nameSize > 8 && measureTextWidth(item.name, size: nameSize, bold: true) > availableW {
                        nameSize -= 0.5
                    }
                    let nameLines = fileNameLines(item.name, size: nameSize,
                                                  maxW: availableW, maxLines: 2)
                    var valueSize: CGFloat = 10
                    while valueSize > 8 && measureTextWidth(item.value, size: valueSize, bold: true) > availableW {
                        valueSize -= 0.5
                    }
                    let valueLines = fileNameLines(item.value, size: valueSize,
                                                   maxW: availableW, maxLines: 2)
                    let textH = max(nameSize * 1.25, 11) * CGFloat(max(nameLines.count, 1))
                        + max(valueSize * 1.25, 11) * CGFloat(max(valueLines.count, 1)) + 2
                    return max(textH + 8, 42)
                }
                var valueSize: CGFloat = 11
                while valueSize > 8 && measureTextWidth(item.value, size: valueSize, bold: true) > 55 {
                    valueSize -= 0.5
                }
                let valueW = min(max(measureTextWidth(item.value, size: valueSize, bold: true) + 2, 20), 55)
                let nameMaxW = availableW - valueW - 6
                var nameSize: CGFloat = 10
                while nameSize > 8 && measureTextWidth(item.name, size: nameSize, bold: true) > nameMaxW {
                    nameSize -= 0.5
                }
                let lines = fileNameLines(item.name, size: nameSize, maxW: nameMaxW, maxLines: 2)
                return max((lines.count > 1 ? 32 : 22) + 8, 42)
            }
            var rowRegion = CGRect(x: cardX, y: top, width: cardW,
                                   height: max(contentBottom - top, 0))
            var frames = haAdaptiveRowFrames(minimumHeights: minimumHeights, region: rowRegion)
            if frames.count < displayItems.count {
                // 为“另有 N 项”保留独立底栏，避免它与最后一张实体卡叠在一起。
                rowRegion.size.height = max(rowRegion.height - 14, 0)
                frames = haAdaptiveRowFrames(minimumHeights: minimumHeights, region: rowRegion)
            }
            let renderedCount = frames.count
            for (item, card) in zip(shown.prefix(renderedCount), frames) {
                let name = item.name
                let value = item.value
                let muted = item.off || item.stale
                let stacked = haRowUsesStackedLayout(name: name, value: value,
                                                      availableWidth: availableW)
                // card 与实体文字都以左上角为原点；圆角绘制函数接收 CG 坐标，必须先转换，
                // 否则背景框会沿纵轴镜像到实体文字的另一侧。
                fillRound(ctx, rect(card), radius: 5, color: colors.insetCG)
                strokeRound(ctx, rect(card), radius: 5, color: colors.borderCG, width: 1)
                if let picture = item.picture {
                    // 多实体中也给 camera/image 足够大的完整预览区域，不再只是 16px 缩略图；
                    // 底部保留名称与状态，因此仍可辨认每路摄像头对应的实体。
                    let infoH = min(max(card.height * 0.24, 16), 20)
                    let pictureBox = CGRect(x: card.minX + 4, y: card.minY + 4,
                                            width: card.width - 8,
                                            height: max(card.height - infoH - 9, 20))
                    if drawImageData(ctx, data: picture, into: pictureBox,
                                     cover: true, radius: 4) {
                        strokeRound(ctx, rect(pictureBox), radius: 4,
                                    color: colors.borderCG, width: 1)
                    }
                    let infoY = card.maxY - infoH - 2
                    let nameW = max((card.width - 12) * 0.62, 20)
                    drawAdaptiveText(ctx, name, maxSize: 9, minSize: 7, bold: true,
                                     color: colors.primaryTextCG,
                                     in: rect(card.minX + 6, infoY, nameW, infoH), align: .left)
                    let valueX = card.minX + 10 + nameW
                    let valueW = max(card.maxX - 6 - valueX, 16)
                    drawAdaptiveText(ctx, value, maxSize: 9, minSize: 7, bold: true,
                                     color: accent,
                                     in: rect(valueX, infoY, valueW, infoH), align: .right)
                    continue
                }
                if stacked {
                    var nameSize: CGFloat = 10
                    while nameSize > 8 && measureTextWidth(name, size: nameSize, bold: true) > availableW {
                        nameSize -= 0.5
                    }
                    let nameLines = fileNameLines(name, size: nameSize,
                                                  maxW: availableW, maxLines: 2)
                    var valueSize: CGFloat = 10
                    while valueSize > 8 && measureTextWidth(value, size: valueSize, bold: true) > availableW {
                        valueSize -= 0.5
                    }
                    let valueLines = fileNameLines(value, size: valueSize,
                                                   maxW: availableW, maxLines: 2)
                    let nameLineH = max(nameSize * 1.25, 11)
                    let valueLineH = max(valueSize * 1.25, 11)
                    let nameH = nameLineH * CGFloat(max(nameLines.count, 1))
                    let valueH = valueLineH * CGFloat(max(valueLines.count, 1))
                    let rowH = nameH + valueH + 2
                    let y = card.midY - rowH / 2

                    let iconBox = CGRect(x: card.minX + 6, y: y + (nameLineH - 16) / 2,
                                         width: 16, height: 16)
                    if let picture = item.picture {
                        drawImageData(ctx, data: picture, into: iconBox, cover: true, radius: 3)
                    } else {
                        drawEntityIcon(ctx, symbol: item.icon, in: rect(iconBox),
                                       color: muted ? colors.secondaryTextCG : accent)
                    }
                    let nameColor = item.stale ? colors.secondaryTextCG : colors.primaryTextCG
                    for (li, line) in nameLines.enumerated() {
                        drawText(ctx, line, size: nameSize, bold: true, color: nameColor,
                                 in: rect(contentX0, y + CGFloat(li) * nameLineH,
                                          availableW, nameLineH), align: .left)
                    }
                    for (li, line) in valueLines.enumerated() {
                        drawText(ctx, line, size: valueSize, bold: true,
                                 color: muted ? colors.secondaryTextCG : accent,
                                 in: rect(contentX0, y + nameH + 2 + CGFloat(li) * valueLineH,
                                          availableW, valueLineH), align: .right)
                    }
                    continue
                }
                // 状态区宽按文字收缩，上限约为整行的 58%，避免中等长度的值被固定 55px 截断。
                let valueCap = max((contentX1 - contentX0) * 0.58, 20)
                var vs: CGFloat = 11
                while vs > 8 && measureTextWidth(value, size: vs, bold: true) > valueCap {
                    vs -= 0.5
                }
                let valueW = min(max(measureTextWidth(value, size: vs, bold: true) + 2, 20), valueCap)
                // 名称区：左贴左缘，右侧为状态区预留（含 6pt 间距），两端对齐互不重叠
                let nameMaxW = (contentX1 - contentX0) - valueW - 6
                var nameSize: CGFloat = 10
                while nameSize > 8 && measureTextWidth(name, size: nameSize, bold: true) > nameMaxW {
                    nameSize -= 0.5
                }
                // 名称按分隔符（_ . - / 空格）折行，长型号/序列号不在词中间硬切
                let nameLines = fileNameLines(name, size: nameSize, maxW: nameMaxW, maxLines: 2)
                let rowH: CGFloat = nameLines.count > 1 ? 32 : 22
                let y = card.midY - rowH / 2
                // 图标位：有画面的实体（image.*）画圆角缩略图，其余画 SF Symbol；
                // 关/失效用次要色，其余用强调色
                let iconBox = CGRect(x: card.minX + 6, y: y + (rowH - 16) / 2, width: 16, height: 16)
                if let picture = item.picture {
                    drawImageData(ctx, data: picture, into: iconBox, cover: true, radius: 3)
                } else {
                    drawEntityIcon(ctx, symbol: item.icon, in: rect(iconBox),
                                   color: muted ? colors.secondaryTextCG : accent)
                }
                // 名称：左对齐贴左缘（失效行整体灰显）
                let nameColor = item.stale ? colors.secondaryTextCG : colors.primaryTextCG
                if nameLines.count > 1 {
                    for (li, line) in nameLines.enumerated() {
                        drawText(ctx, line, size: nameSize, bold: true, color: nameColor,
                                 in: rect(contentX0, y + CGFloat(li) * (rowH / 2),
                                          nameMaxW, rowH / 2), align: .left)
                    }
                } else {
                    drawText(ctx, nameLines[0], size: nameSize, bold: true, color: nameColor,
                             in: rect(contentX0, y, nameMaxW, rowH), align: .left)
                }
                // 状态值：右对齐贴右缘（名称区之外，绝不重叠）
                drawText(ctx, value, size: vs, bold: true,
                         color: muted ? colors.secondaryTextCG : accent,
                         in: rect(contentX1 - valueW, y, valueW, rowH), align: .right)
            }
            if displayItems.count > renderedCount {
                drawText(ctx, "另有 \(displayItems.count - renderedCount) 项…", size: 7, bold: false,
                         color: colors.tertiaryTextCG,
                         in: rect(c.minX + 9, contentBottom - 12, c.maxX - c.minX - 18, 12),
                         align: .center)
            }
        } else if let errorText, !errorText.isEmpty {
            drawText(ctx, errorText, size: 10, bold: true, color: accent,
                     in: rect(c.minX + 9, top + 30, c.maxX - c.minX - 18, 20), align: .center)
            drawText(ctx, "未连接 · 请检查设置", size: 8, bold: false,
                     color: colors.tertiaryTextCG,
                     in: rect(c.minX + 9, top + 52, c.maxX - c.minX - 18, 14), align: .center)
        } else {
            drawText(ctx, "未连接", size: 13, bold: true, color: accent,
                     in: rect(c.minX + 9, top + 30, c.maxX - c.minX - 18, 22), align: .center)
            drawText(ctx, "在「Home Assistant」配置", size: 8, bold: false,
                     color: colors.tertiaryTextCG,
                     in: rect(c.minX + 9, top + 54, c.maxX - c.minX - 18, 14), align: .center)
        }
        if settings.nowPlayingFooterVisible {
            drawHAFooterClock(ctx, card: c, settings: settings, colors: colors, now: now)
        }
        return try encode(ctx, quality: settings.jpegQuality)
    }

    // MARK: - SF Symbol 实体图标（HA 卡片/画板模块）

    /// SF Symbol → CGImage 缓存（模板符号按指定颜色着色；避免每帧重复渲染）
    private static let symbolImageCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 192
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    /// 取 SF Symbol 图像（指定点大小与颜色；无此符号回退 nil）
    private static func symbolImage(_ name: String, pointSize: CGFloat, color: CGColor) -> CGImage? {
        // 颜色必须参与缓存：同一符号切换浅/深主题后不能复用上一次的文字色。
        let nsColor = (NSColor(cgColor: color) ?? .black).usingColorSpace(.sRGB) ?? .black
        let channels = [nsColor.redComponent, nsColor.greenComponent,
                        nsColor.blueComponent, nsColor.alphaComponent]
        let colorKey = channels.map { String(Int(($0 * 65535).rounded())) }.joined(separator: ",")
        let key = "\(name)#\(Int((pointSize * 100).rounded()))#\(colorKey)" as NSString
        if let cached = symbolImageCache.object(forKey: key) { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        // 模板符号着色：sourceAtop 只给非透明像素染上指定颜色
        let tinted = NSImage(size: base.size)
        tinted.lockFocus()
        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        nsColor.set()
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        var rect = CGRect(origin: .zero, size: tinted.size)
        guard let cg = tinted.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        symbolImageCache.setObject(cg, forKey: key, cost: cg.bytesPerRow * cg.height)
        return cg
    }

    /// 按宽度把文本拆成最多 maxLines 行（完整保留内容；末行若仍超宽才加省略号兜底）
    private static func splitLines(_ text: String, size: CGFloat, bold: Bool,
                                   maxW: CGFloat, maxLines: Int) -> [String] {
        var remaining = text
        var lines: [String] = []
        while !remaining.isEmpty && lines.count < maxLines {
            if measureTextWidth(remaining, size: size, bold: bold) <= maxW {
                lines.append(remaining)
                remaining = ""
            } else if remaining.count <= 1 {
                lines.append(remaining)
                remaining = ""
            } else {
                var cut = remaining.count
                while cut > 1 && measureTextWidth(String(remaining.prefix(cut)), size: size, bold: bold) > maxW {
                    cut -= 1
                }
                if cut <= 0 { cut = 1 }
                lines.append(String(remaining.prefix(cut)))
                remaining = String(remaining.dropFirst(cut))
            }
        }
        if !remaining.isEmpty, !lines.isEmpty {
            lines[lines.count - 1] += "…"
        }
        return lines
    }

    /// 正在播放卡片的歌名排布：优先单行；单行要把字号缩到 9pt 以下时改为双行
    /// （像播放器标题栏那样换行显示），双行仍放不下时缩到 7pt 并以省略号收尾。
    public static func nowPlayingTitleLines(title: String, maxWidth: CGFloat,
                                            maxSize: CGFloat, maxLines: Int = 2) -> (lines: [String], size: CGFloat) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, maxWidth > 10 else { return ([text.isEmpty ? "未在播放" : text], min(maxSize, 14)) }
        var single = min(maxSize, 14)
        while single > 8.5, measureTextWidth(text, size: single, bold: true) > maxWidth {
            single -= 0.5
        }
        if single > 8.5 || text.count < 6 {
            return ([text], min(single, maxSize))
        }
        var size = min(maxSize, 13)
        var lines = wrapText(text, maxWidth: maxWidth, size: size)
        while size > 7, lines.count > maxLines {
            size -= 0.5
            lines = wrapText(text, maxWidth: maxWidth, size: size)
        }
        if lines.count > maxLines {
            var kept = Array(lines.prefix(maxLines))
            if kept.count == maxLines {
                var second = kept[1]
                while second.count > 1,
                      measureTextWidth(second + "…", size: size, bold: true) > maxWidth {
                    second = String(second.dropLast())
                }
                kept[1] = second + "…"
            }
            lines = kept
        }
        return (lines, size)
    }

    /// 「正在播放」模块在无封面（或未开启封面）时是否改用横向单行排布：
    /// 竖排两行会把歌名压到 9pt 以下，或横带高度不足 26pt 时转横向
    /// （与口袋先知/摘录画板一致：卡片被压缩、收窄到一定尺寸就换排布方向）
    public static func nowPlayingPrefersHorizontal(bandHeight: CGFloat, bandWidth: CGFloat,
                                                   title: String, titleSizeSetting: Int) -> Bool {
        guard bandWidth >= 100 else { return false }
        let h1 = max(bandHeight * 0.55, 10)
        var stackedSize = min(h1 * 0.75, CGFloat(titleSizeSetting))
        let stackedWidth = measureTextWidth(title, size: stackedSize, bold: true)
        if stackedWidth > bandWidth - 4 {
            stackedSize = max(stackedSize * (bandWidth - 4) / stackedWidth, 8)
        }
        return stackedSize < 9 || bandHeight < 26
    }

    /// 文件名断行：优先在分隔符（_ . - / 空格 冒号）处断开，避免长 gcode 文件名被硬切在中间；
    /// 找不到合适分隔符时才按宽度硬断，超出 maxLines 的尾巴以「…」标记
    public static func fileNameLines(_ text: String, size: CGFloat, maxW: CGFloat,
                                     maxLines: Int = 2, bold: Bool = false) -> [String] {
        let separators: Set<Character> = ["_", ".", "-", "/", " ", ":"]
        var lines: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty, lines.count < maxLines {
            if measureTextWidth(String(rest), size: size, bold: bold) <= maxW {
                lines.append(String(rest))
                rest = ""
                break
            }
            var fit = rest.count
            while fit > 1, measureTextWidth(String(rest.prefix(fit)), size: size, bold: bold) > maxW {
                fit -= 1
            }
            // 在本行后半段里回退到最近的分隔符（分隔符留在本行行尾）
            var cut = fit
            let lowerBound = max(1, fit / 2)
            var offset = fit
            while offset > lowerBound {
                offset -= 1
                if separators.contains(rest[rest.index(rest.startIndex, offsetBy: offset)]) {
                    cut = offset + 1
                    break
                }
            }
            lines.append(String(rest.prefix(cut)))
            rest = rest.dropFirst(cut)
        }
        if !rest.isEmpty, !lines.isEmpty {
            lines[lines.count - 1] += "…"
        }
        return lines
    }

    /// 独立设备画板的打印任务名排版：优先较大的单行；过宽时改为最多两行，
    /// 并同时按横向宽度与两行可用高度收缩字号。返回值公开供布局回归测试使用。
    public static func bambuCanvasTaskLayout(_ text: String,
                                             maxWidth: CGFloat,
                                             maxHeight: CGFloat,
                                             preferredSize: CGFloat,
                                             bold: Bool = true) -> (lines: [String], size: CGFloat) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return ([], preferredSize) }
        let width = max(maxWidth, 10)
        let height = max(maxHeight, 8)
        let minimum = min(8.5, preferredSize)
        var size = min(preferredSize, max(height * 0.62, minimum))

        // 能以清晰大字单行容纳时不主动拆行。
        if measureTextWidth(value, size: size, bold: bold) <= width {
            return ([value], size)
        }

        // 长任务名最多两行；字号需要同时满足两行总高度和尽可能完整的横向排布。
        size = min(size, max((height - 1) / 2.35, minimum))
        var lines = fileNameLines(value, size: size, maxW: width, maxLines: 2, bold: bold)
        while size > minimum {
            let lineHeight = size * 1.16
            let truncated = lines.last?.hasSuffix("…") == true
            if !truncated, lineHeight * CGFloat(lines.count) <= height { break }
            size -= 0.5
            lines = fileNameLines(value, size: size, maxW: width, maxLines: 2, bold: bold)
        }
        return (lines, size)
    }

    /// 打印机状态排版：四字左右的常用状态优先保持大号单行；较长的详细阶段不再
    /// 强行缩成含义模糊的四字词，而是最多分成两行，并在两行仍放不下时自适应字号。
    public static func bambuStatusTextLayout(_ text: String,
                                             maxWidth: CGFloat,
                                             maxHeight: CGFloat,
                                             preferredSize: CGFloat,
                                             minSize: CGFloat = 8.5)
        -> (lines: [String], size: CGFloat) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return ([], preferredSize) }
        let width = max(maxWidth, 8)
        let height = max(maxHeight, 8)
        let minimum = min(minSize, preferredSize)
        var size = min(preferredSize, max(height * 0.76, minimum))
        if measureTextWidth(value, size: size, bold: true) <= width {
            return ([value], size)
        }

        let maxLines = height >= minimum * 2.0 ? 2 : 1
        if maxLines == 1 {
            size = adaptiveFontSize(value, maxSize: size, minSize: minimum,
                                    bold: true, maxWidth: width)
            return ([value], size)
        }

        size = min(size, max((height - 1) / 2.18, minimum))
        var lines = splitLines(value, size: size, bold: true,
                               maxW: width, maxLines: maxLines)
        while size > minimum, lines.last?.hasSuffix("…") == true {
            size -= 0.5
            lines = splitLines(value, size: size, bold: true,
                               maxW: width, maxLines: maxLines)
        }
        return (lines, size)
    }

    /// 独立打印机卡片在状态描述过长时使用的紧凑语义。详细阶段仍保留在翻译词库中，
    /// 这里只把它归纳成「图标 + 短标签」，避免开启任务、温度、时间和画面后状态占掉两行。
    public static func bambuCompactStatusPresentation(rawState: String,
                                                       isError: Bool = false)
        -> (symbol: String, label: String) {
        let raw = rawState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let translated = BambuStatusText.map(rawState)
        let searchable = "\(raw) \(translated)"

        if isError || searchable.contains("error") || searchable.contains("failed")
            || searchable.contains("报错") || searchable.contains("失败") {
            return ("exclamationmark.triangle.fill", "异常")
        }
        if searchable.contains("pause") || searchable.contains("暂停") {
            return ("pause.circle.fill", "已暂停")
        }
        if searchable.contains("finish") || searchable.contains("completed")
            || searchable.contains("完成") {
            return ("checkmark.circle.fill", "已完成")
        }
        if raw == "off" || searchable.contains("offline") || searchable.contains("离线")
            || searchable.contains("关机") {
            return ("power", "离线")
        }
        if searchable.contains("calibrat") || searchable.contains("level")
            || searchable.contains("measure") || searchable.contains("校准")
            || searchable.contains("调平") || searchable.contains("测量") {
            return ("scope", "校准中")
        }
        if searchable.contains("detect") || searchable.contains("inspect")
            || searchable.contains("scan") || searchable.contains("check")
            || searchable.contains("检测") || searchable.contains("检查")
            || searchable.contains("扫描") || searchable.contains("识别") {
            return ("viewfinder", "检测中")
        }
        if searchable.contains("filament") || searchable.contains("extrusion")
            || searchable.contains("purge") || searchable.contains("ams")
            || searchable.contains("进料") || searchable.contains("退料")
            || searchable.contains("换料") || searchable.contains("耗材") {
            return ("arrow.triangle.2.circlepath", "耗材处理中")
        }
        if searchable.contains("moving") || searchable.contains("homing")
            || searchable.contains("移至") || searchable.contains("归位") {
            return ("arrow.up.and.down.and.arrow.left.and.right", "移动中")
        }
        if searchable.contains("cool") || searchable.contains("冷却") {
            return ("snowflake", "冷却中")
        }
        if searchable.contains("heat") || searchable.contains("temperature")
            || searchable.contains("thermal") || searchable.contains("温度")
            || searchable.contains("加热") || searchable.contains("预热") {
            return ("thermometer.medium", "温控中")
        }
        if searchable.contains("printing") || searchable.contains("running")
            || searchable.contains("打印中") {
            return ("printer.fill", "打印中")
        }
        if searchable.contains("prepar") || searchable.contains("init")
            || searchable.contains("准备") || searchable.contains("初始化") {
            return ("gearshape.2.fill", "准备中")
        }
        if searchable.contains("idle") || searchable.contains("standby")
            || searchable.contains("空闲") || searchable.contains("待机") {
            return ("moon.zzz.fill", "待机")
        }
        return ("gearshape.fill", "处理中")
    }

    /// 在逻辑坐标中绘制紧凑状态胶囊。调用方传入未翻转的 bounds，由此处统一转换，
    /// 防止状态辅助函数再次出现双重坐标转换。
    private static func drawBambuCompactStatus(_ ctx: CGContext,
                                                rawState: String,
                                                isError: Bool,
                                                color: CGColor,
                                                background: CGColor,
                                                border: CGColor,
                                                in bounds: CGRect) {
        let presentation = bambuCompactStatusPresentation(rawState: rawState,
                                                           isError: isError)
        let converted = rect(bounds)
        fillRound(ctx, converted, radius: min(bounds.height / 2, 10), color: background)
        strokeRound(ctx, converted, radius: min(bounds.height / 2, 10), color: border, width: 1)

        var labelSize = min(max(bounds.height * 0.56, 10), 14)
        let iconSide = min(max(bounds.height - 8, 12), 15)
        let availableLabelWidth = max(10, bounds.width - iconSide - 12)
        let naturalLabelWidth = measureTextWidth(presentation.label, size: labelSize, bold: true)
        if naturalLabelWidth > availableLabelWidth {
            labelSize = max(10, labelSize * availableLabelWidth / naturalLabelWidth)
        }
        let labelWidth = min(availableLabelWidth, measureTextWidth(presentation.label, size: labelSize, bold: true))
        let groupWidth = iconSide + 4 + labelWidth
        let groupX = bounds.midX - groupWidth / 2
        drawEntityIcon(ctx, symbol: presentation.symbol,
                       in: rect(groupX, bounds.midY - iconSide / 2, iconSide, iconSide),
                       color: color)
        // Symbols are centered in their frame; center the visible text glyphs as
        // well, not the font's ascent/descent box (which drops Chinese labels).
        drawGlyphCenteredText(ctx, presentation.label, size: labelSize, bold: true, color: color,
                 in: rect(groupX + iconSide + 4, bounds.minY,
                          min(labelWidth + 2, bounds.maxX - groupX - iconSide - 4), bounds.height),
                 align: .left)
    }

    private static func drawBambuStatusText(_ ctx: CGContext, _ text: String,
                                             maxSize: CGFloat, minSize: CGFloat,
                                             color: CGColor, in bounds: CGRect,
                                             align: NSTextAlignment) {
        let layout = bambuStatusTextLayout(text,
                                           maxWidth: bounds.width,
                                           maxHeight: bounds.height,
                                           preferredSize: maxSize,
                                           minSize: minSize)
        guard !layout.lines.isEmpty else { return }
        let lineH = min(layout.size * 1.09,
                        bounds.height / CGFloat(layout.lines.count))
        let blockH = lineH * CGFloat(layout.lines.count)
        let startY = bounds.midY - blockH / 2
        for (index, line) in layout.lines.enumerated() {
            drawText(ctx, line, size: layout.size, bold: true, color: color,
                     in: rect(bounds.minX, startY + CGFloat(index) * lineH,
                              bounds.width, lineH), align: align)
        }
    }

    /// 绘制最多两行、字号自适应的打印任务名。
    private static func drawBambuCanvasTask(_ ctx: CGContext, _ text: String,
                                            in row: CGRect, preferredSize: CGFloat,
                                            color: CGColor, bold: Bool) {
        let layout = bambuCanvasTaskLayout(text,
                                           maxWidth: max(row.width - 4, 10),
                                           maxHeight: max(row.height - 2, 8),
                                           preferredSize: preferredSize,
                                           bold: bold)
        guard !layout.lines.isEmpty else { return }
        let lineH = min(layout.size * 1.16,
                        max((row.height - 2) / CGFloat(layout.lines.count), 8))
        let blockH = lineH * CGFloat(layout.lines.count)
        let y = row.midY - blockH / 2
        for (index, line) in layout.lines.enumerated() {
            drawText(ctx, line, size: layout.size, bold: bold, color: color,
                     in: rect(row.minX + 2, y + CGFloat(index) * lineH,
                              row.width - 4, lineH), align: .center)
        }
    }

    /// 画板模块内的一行居中文本：超宽自动缩字号（下限 6pt），用于打印机模块的信息行
    private static func drawCanvasModuleValueLine(_ ctx: CGContext, _ text: String, _ row: CGRect,
                                                  w: CGFloat, size: CGFloat, color: CGColor,
                                                  bold: Bool = false) {
        guard !text.isEmpty else { return }
        var fontSize = size
        let maxW = max(w - 4, 10)
        if measureTextWidth(text, size: fontSize, bold: bold) > maxW {
            fontSize = max(fontSize * maxW / measureTextWidth(text, size: fontSize, bold: bold), 6)
        }
        drawText(ctx, text, size: fontSize, bold: bold, color: color,
                 in: rect(row.minX, row.minY, w, row.height), align: .center)
    }

    /// 绘制 HA 实体图标（居中对齐到 frame；无匹配符号时静默跳过）
    private static func drawEntityIcon(_ ctx: CGContext, symbol: String, in frame: CGRect,
                                       color: CGColor) {
        guard let cg = symbolImage(symbol, pointSize: min(frame.height, 14), color: color) else { return }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return }
        let scale = min(frame.width / w, frame.height / h, 1)
        let dw = w * scale, dh = h * scale
        ctx.draw(cg, in: CGRect(x: frame.midX - dw / 2, y: frame.midY - dh / 2,
                                width: dw, height: dh))
    }

    /// HA 异常告警卡：深红警示背景 + ⚠ 标识 + 实体名（如打印机名）+ 错误信息大字，醒目突出。
    /// 监控到实体异常时由 AppModel 推送到键盘显示，恢复正常自动消失
    public static func renderHAAlert(title: String, message: String, settings: AppSettings,
                                     now: Date = Date()) throws -> RenderResult {
        let colors = settings.resolvedPalette
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let alertBG = CGColor(red: 0.30, green: 0.10, blue: 0.12, alpha: 1)
        let alertBorder = CGColor(red: 0.88, green: 0.38, blue: 0.32, alpha: 1)
        let warn = CGColor(red: 1, green: 0.92, blue: 0.55, alpha: 1)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let dim = CGColor(red: 1, green: 0.85, blue: 0.85, alpha: 0.75)
        // 告警必须保留深红底色，不能被普通主题背景替换。
        ColorCardSceneCapture.attach(ctx)
        ctx.setFillColor(alertBG)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let c = CGRect(x: 9, y: safe + 1, width: 124, height: CGFloat(height) - 9 - (safe + 1))
        fillRound(ctx, rect(c), radius: 13, color: alertBG)
        strokeRound(ctx, rect(c), radius: 13, color: alertBorder, width: 1)
        // 标头：⚠ 警示 + 「设备异常」（卡片宽度有限，不写产品全称）
        drawText(ctx, "⚠", size: 12, bold: true, color: warn,
                 in: rect(c.minX + 9, c.minY + 10, 20, 20), align: .left)
        drawText(ctx, "设备异常", size: 8, bold: true, color: warn,
                 in: rect(c.minX + 9, c.minY + 12, c.maxX - c.minX - 18, 16), align: .right)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 34, x2: c.maxX - 9, y2: c.minY + 34, color: alertBorder)
        let top = c.minY + 46
        // 实体名（如打印机名）
        drawText(ctx, title, size: 12, bold: true, color: white,
                 in: rect(c.minX + 9, top, c.maxX - c.minX - 18, 20), align: .center)
        // 错误信息大字（错误码等），过宽自动收缩
        var size: CGFloat = 16
        var tw = measureTextWidth(message, size: size, bold: true)
        let maxW = c.maxX - c.minX - 16
        if tw > maxW {
            size = max(size * maxW / tw, 10)
        }
        drawText(ctx, message, size: size, bold: true, color: warn,
                 in: rect(c.minX + 8, top + 26, maxW, 30), align: .center)
        // 分隔线：错误码与故障详情分区
        drawLine(ctx, x1: c.minX + 12, y1: top + 64, x2: c.maxX - 12, y2: top + 64, color: alertBorder)
        // 底部：HMS 故障原因（有映射显示具体原因，无则通用提示）
        // 详情为一眼可读重点：14pt 粗体白色，按宽度换行多行展示（不再缩成 8pt 小字）
        let reason = BambuHMSCode.reason(for: message)
            ?? "检测到异常状态，请检查设备（详见 Bambu Lab HMS 文档）"
        let rMax = c.maxX - c.minX - 18
        let reasonLines = splitLines(reason, size: 14, bold: true, maxW: rMax, maxLines: 10)
        var ry = top + 76
        for line in reasonLines {
            drawText(ctx, line, size: 14, bold: true, color: white,
                     in: rect(c.minX + 9, ry, rMax, 20), align: .center)
            ry += 20
        }
        if settings.nowPlayingFooterVisible {
            drawFooterClock(ctx, card: c, settings: settings, colors: colors, now: now, accent: warn)
        }
        return try encode(ctx, quality: settings.jpegQuality)
    }

    /// Bambu Lab 品牌绿（卡片主题色选项「Bambu Lab 强调色」使用；用户指定的品牌色 #629E4E）
    public static let bambuLabAccentColor = CGColor(red: 98.0 / 255.0, green: 158.0 / 255.0, blue: 78.0 / 255.0, alpha: 1)
    /// Formlabs Dashboard 品牌蓝。用户可按设备切换为全局主题强调色。
    public static let formlabsAccentColor = CGColor(red: 0.16, green: 0.52, blue: 0.88, alpha: 1)
    /// 大字布局的进度数字保持原来的 34pt；百分号缩小为数字的一半，降低视觉抢占。
    public static let bambuLargeProgressNumberSize: CGFloat = 34
    public static let bambuLargeProgressPercentSize: CGFloat = bambuLargeProgressNumberSize / 2
    /// 大字布局中状态作为进度数字背后的超大辅助信息，按宽度自适应缩小。
    public static let bambuLargeStatusBackdropSize: CGFloat = 35
    /// 标准状态文字以及没有进度数值时的大字卡片状态统一使用 20pt。
    /// Formlabs 独立卡片复用该值，确保两类打印机状态的视觉权重一致。
    public static let bambuRegularStatusSize: CGFloat = 20
    /// 数据更新时间需要在实体屏幕上保持可读，不能沿用普通辅助文字的 7.5pt。
    public static let bambuDataFooterSize: CGFloat = 9.5

    /// Bambu 图片区域的目标尺寸：摄像头固定为正方形；任务封面保持 16:9。
    /// 空间不足时两个方向等比缩小，避免把画面拉伸或把正方形压扁。
    public static func bambuPictureSize(source: BambuImageSource,
                                        maxWidth: CGFloat,
                                        maxHeight: CGFloat) -> CGSize {
        let availableWidth = max(maxWidth, 0)
        let availableHeight = max(maxHeight, 0)
        guard availableWidth > 0, availableHeight > 0 else { return .zero }
        switch source {
        case .camera:
            let side = min(availableWidth, availableHeight)
            return CGSize(width: side, height: side)
        case .taskCover:
            let targetRatio: CGFloat = 16 / 9
            let width = min(availableWidth, availableHeight * targetRatio)
            return CGSize(width: width, height: width / targetRatio)
        }
    }

    /// 灵犀画板多打印机摘要里的紧凑时间：与百分比共享进度行，因此去掉冗长单位；
    /// 结束时间只保留时分，避免日期再次占用一整行。
    public static func bambuCompactCanvasTimeText(_ entity: HAEntity,
                                                   mode: BambuTimeDisplayMode) -> String {
        switch mode {
        case .remaining:
            return entity.remainingDisplayText
                .replacingOccurrences(of: "小时", with: "时")
                .replacingOccurrences(of: "分钟", with: "分")
                .replacingOccurrences(of: " ", with: "")
        case .endTime:
            let display = entity.displayState
            if let last = display.split(separator: " ").last, last.contains(":") {
                return String(last)
            }
            return display
        }
    }

    /// Bambu Lab 打印机状态卡：聚合显示工作状态/进度/任务名/喷嘴与热床温度/剩余时间；
    /// 字段由实体映射配置（未映射字段自动隐藏）；状态=error 或错误码实体非空时显示错误警示
    public static func renderBambuLab(_ bambu: BambuLabCardSettings, entities: [HAEntity],
                                      image: Data? = nil,
                                      settings: AppSettings, now: Date = Date(),
                                      dataUpdatedAt: Date? = nil) throws -> RenderResult {
        let colors = settings.resolvedPalette
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let c = drawCanvas(ctx, safeArea: safe, colors: colors)
        // 主题色：跟随全局强调色，或固定使用 Bambu Lab 品牌青绿（按打印机各自设置）
        let accent = bambu.themeAccent == .bambuLab ? Self.bambuLabAccentColor : colors.accentCG
        // 打印机设备名作为头部主标题显示，不能只塞进 6pt 的右上角徽标：
        // 多台打印机切换卡片时，用户需要一眼确认当前卡片对应哪台设备。
        let trimmedName = bambu.name.trimmingCharacters(in: .whitespacesAndNewlines)
        drawBambuHeader(ctx, card: c,
                        deviceName: trimmedName.isEmpty ? "打印机" : trimmedName,
                        accent: accent, colors: colors)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)
        func entity(_ id: String) -> HAEntity? {
            guard !id.isEmpty else { return nil }
            return entities.first { $0.entityId == id }
        }
        let status = entity(bambu.statusEntityID)
        let error = entity(bambu.errorEntityID)
        let hasStatusBinding = !bambu.statusEntityID
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 错误码新鲜度阈值：2×刷新间隔（至少 10 分钟）；更早的错误码视为已恢复（残留旧值不误报）
        let staleSeconds = TimeInterval(max(10, max(1, settings.haRefreshMinutes) * 2) * 60)
        let isError = (status?.state.lowercased() == "error")
            || (error.map { e in
                let s = e.state.trimmingCharacters(in: .whitespaces).lowercased()
                // binary_sensor 类 HMS 错误实体 off = 无错误、on = 有错误
                return !s.isEmpty && !["none", "无", "normal", "ok", "0", "off", "unavailable", "unknown"].contains(s)
                    && HAErrorCodePolicy.isFresh(entity: e, staleSeconds: staleSeconds)
            } ?? false)
        let warn = CGColor(red: 1, green: 0.85, blue: 0.55, alpha: 1)
        // 状态大字（空闲/打印中/报错…，中文汉化），错误时用警示色。
        let rawStatus = status?.state ?? ""
        let statusText = status.map { BambuStatusText.map($0.state) } ?? "未配置"
        _ = entities
        let statusColor = isError ? warn : (statusText == "打印中" ? accent : colors.primaryTextCG)
        // 布局样式：标准 / 紧凑 / 大字（详情页可切换），调整字号与各区块行距
        let statusSize: CGFloat
        let topOffset: CGFloat
        let progressStep: CGFloat, taskStep: CGFloat, tempStep: CGFloat, remainStep: CGFloat
        let infoSize: CGFloat, progressH: CGFloat, taskBaseSize: CGFloat
        switch bambu.layout {
        case .compact:
            statusSize = 16; topOffset = 44
            progressStep = 12; taskStep = 16; tempStep = 14; remainStep = 14
            infoSize = 8; progressH = 4; taskBaseSize = 9
        case .large:
            // 大字布局只突出打印百分比；工作状态与标准布局保持同字号、横向排布。
            statusSize = Self.bambuRegularStatusSize; topOffset = 43
            progressStep = 19; taskStep = 24; tempStep = 21; remainStep = 21
            infoSize = 10; progressH = 6; taskBaseSize = 13
        case .standard:
            statusSize = Self.bambuRegularStatusSize; topOffset = 49
            progressStep = 16; taskStep = 20; tempStep = 18; remainStep = 18
            infoSize = 9; progressH = 4.5; taskBaseSize = 11
        }
        let top = c.minY + topOffset
        // 任务文件名行：单行放得下就一行；放不下折成两行（按 _ . - / 等分隔符断行），
        // 不再把长 gcode 文件名缩到不可读的字号
        let taskMaxW = c.maxX - c.minX - 20
        let taskText = ((bambu.showTask ? entity(bambu.taskEntityID)?.displayState : nil) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var taskLines: [String] = []
        if !taskText.isEmpty, taskText.lowercased() != "unknown" {
            taskLines = measureTextWidth(taskText, size: taskBaseSize, bold: false) <= taskMaxW
                ? [taskText]
                : fileNameLines(taskText, size: taskBaseSize, maxW: taskMaxW, maxLines: 2)
        }
        let taskLineH = taskLines.count > 1 ? max(taskStep * 0.62, 12) : taskStep
        let taskBlockH = taskLines.isEmpty ? 0 : taskLineH * CGFloat(taskLines.count)
        let progressEntity = entity(bambu.progressEntityID)
        let progressValue = progressEntity.flatMap { Double($0.state) }
        let prominentProgress = bambu.layout == .large && bambu.showProgress && progressValue != nil
        let contentBottom = c.maxY - (settings.nowPlayingFooterVisible ? 36 : 8)
        let nozzle = entity(bambu.nozzleTempEntityID)
        let bed = entity(bambu.bedTempEntityID)
        let temperatureText = "喷嘴 \(nozzle?.displayValue ?? "—")   热床 \(bed?.displayValue ?? "—")"
        let hasTemperature = bambu.showTemperature && (nozzle != nil || bed != nil)
        let temperatureBlockH: CGFloat = hasTemperature
            ? (measureTextWidth(temperatureText, size: infoSize, bold: false) > taskMaxW
                ? tempStep * 1.5 : tempStep)
            : 0
        let timeEntity = entity(bambu.selectedTimeEntityID)
        let hasTimeInfo = bambu.showRemaining
            && !(timeEntity?.state.isEmpty ?? true)
            && timeEntity?.state.lowercased() != "unknown"
        let errorText = error?.state ?? status?.state ?? "未知错误"
        let errorReason = BambuHMSCode.reason(for: errorText)
            ?? "未知错误码，详见 Bambu Lab HMS 文档"
        let errorLines = isError && bambu.showError
            ? splitLines(errorReason, size: 11, bold: true, maxW: taskMaxW, maxLines: 3)
            : []
        let errorBlockH: CGFloat = isError && bambu.showError
            ? 22 + CGFloat(errorLines.count) * 15 : 0
        let configurationHintH: CGFloat = status == nil && bambu.statusEntityID.isEmpty ? 16 : 0

        // 正文严格限制在页脚上方。极端的双行任务名 + 温度 + 错误说明场景即使空间不足，
        // 也只会在正文边界内截断，不会覆盖“数据更新”页脚。
        ctx.saveGState()
        ctx.clip(to: rect(c.minX, c.minY + 39,
                          c.maxX - c.minX, contentBottom - c.minY - 39))

        // 大字布局：状态是浅色超大背景字；进度数字与半号百分号叠在前景，
        // 粗进度条紧随其后。三者合成一个信息区，不再让状态单独占一整行。
        var y = top
        if prominentProgress, let value = progressValue {
            let clampedPercent = min(max(value, 0), 100)
            let numberText = String(format: "%.0f", clampedPercent)
            let numberSize = Self.bambuLargeProgressNumberSize
            let percentSize = Self.bambuLargeProgressPercentSize
            let innerX = c.minX + 10
            let innerW = c.maxX - c.minX - 20
            if bambu.showStatus && hasStatusBinding {
                let backdropColor = colors.secondaryTextCG.copy(alpha: 0.38) ?? colors.tertiaryTextCG
                // 大字字号本身会让三四个字的常用状态暂时超宽，不能因此误判为详细阶段。
                // 以常规 20pt 可读字号和文本长度判断，确保“打印中/已暂停”等继续用大字。
                let longStatus = statusText.count > 5
                    || measureTextWidth(statusText, size: 20, bold: true) > innerW
                if longStatus {
                    let badgeWidth = min(innerW, 96)
                    drawBambuCompactStatus(ctx, rawState: rawStatus, isError: isError,
                                           color: statusColor,
                                           background: colors.insetCG,
                                           border: colors.borderCG,
                                           in: CGRect(x: c.midX - badgeWidth / 2, y: top - 5,
                                                      width: badgeWidth, height: 23))
                } else {
                    drawBambuStatusText(ctx, statusText,
                                        maxSize: Self.bambuLargeStatusBackdropSize,
                                        minSize: 14, color: backdropColor,
                                        in: CGRect(x: innerX, y: top - 5,
                                                   width: innerW, height: 48), align: .center)
                }
            }
            drawBambuProgressLabel(ctx, number: numberText,
                                   numberSize: numberSize, percentSize: percentSize,
                                   numberColor: colors.primaryTextCG,
                                   percentColor: colors.secondaryTextCG,
                                   in: rect(innerX, top + 16, innerW, 46))
            // 给数字字形下沿留出明确呼吸空间，避免与轨道粘在一起。
            let barY = top + 72
            let barBounds = rect(innerX, barY, innerW, 8)
            drawProgress(ctx, barBounds, progress: clampedPercent / 100,
                         accent: accent, background: colors.borderCG)
            strokeRound(ctx, barBounds, radius: 4, color: colors.secondaryTextCG, width: 1)
            y = barY + 20
        }

        // 标准/紧凑布局中的状态仍是独立横排；大字布局已将它叠入进度信息区。
        if bambu.showStatus, hasStatusBinding, !prominentProgress {
            let statusWidth = c.maxX - c.minX - 16
            let singleLineFits = measureTextWidth(statusText, size: statusSize, bold: true)
                <= statusWidth
            let statusBlockH: CGFloat
            if singleLineFits {
                statusBlockH = statusSize + 6
                drawBambuStatusText(ctx, statusText,
                                    maxSize: statusSize,
                                    minSize: 10,
                                    color: statusColor,
                                    in: CGRect(x: c.minX + 8, y: y,
                                               width: statusWidth, height: statusBlockH),
                                    align: .center)
            } else {
                // 详细阶段常有 8～12 个字。独立卡片还要容纳画面、任务、温度和时间，
                // 因此改用语义图标与短标签，不再让状态独占两行并推挤下面的详情。
                statusBlockH = 24
                let badgeWidth = min(statusWidth, 96)
                drawBambuCompactStatus(ctx, rawState: rawStatus, isError: isError,
                                       color: statusColor,
                                       background: colors.insetCG,
                                       border: colors.borderCG,
                                       in: CGRect(x: c.midX - badgeWidth / 2, y: y,
                                                  width: badgeWidth, height: statusBlockH))
            }
            y += statusBlockH + 6
        }
        // 进度条（左）+ 百分比（右）：同一行两端排布，不与状态文本重叠
        if bambu.showProgress, !prominentProgress,
           let progress = progressEntity,
           let value = Double(progress.state) {
            let pctText = String(format: "%.0f%%", value)
            drawProgress(ctx, rect(c.minX + 10, y, c.maxX - c.minX - 52, progressH),
                         progress: min(value / 100, 1), accent: accent, background: colors.borderCG)
            drawText(ctx, pctText, size: infoSize + 1, bold: true, color: colors.primaryTextCG,
                     in: rect(c.maxX - 44, y - 7, 36, 14), align: .right)
            y += progressStep
        }

        // 图片和其余设备信息作为一个底部信息组：顶部进度区与底部监控区之间
        // 保留留白和分隔线，避免摄像头画面与进度条在视觉上粘连。
        // 摄像头固定为正方形；任务封面保留 16:9。空间不足时仍保持各自比例缩小。
        let textReserve = taskBlockH + temperatureBlockH
            + (hasTimeInfo ? remainStep : 0) + errorBlockH + configurationHintH
        let visibleDetailCount = (taskLines.isEmpty ? 0 : 1)
            + (hasTemperature ? 1 : 0)
            + (hasTimeInfo ? 1 : 0)
            + (isError && bambu.showError ? 1 : 0)
        let groupGap: CGFloat = visibleDetailCount >= 3 ? 12 : 18
        let hasUpperSummary = (bambu.showStatus && hasStatusBinding)
            || (bambu.showProgress && progressValue != nil)
        var didDrawPicture = false
        if bambu.showImage, let picture = image {
            let pictureMaxW = c.maxX - c.minX - 20
            let pictureMaxH = max(contentBottom - y - groupGap - textReserve - 6, 0)
            let pictureSize = bambuPictureSize(source: bambu.imageSource,
                                                maxWidth: pictureMaxW,
                                                maxHeight: pictureMaxH)
            if pictureSize.width >= 34, pictureSize.height >= 34 {
                let groupHeight = pictureSize.height + 6 + textReserve
                let earliestTop = y + groupGap
                let latestTop = max(contentBottom - groupHeight, earliestTop)
                // 过去始终取 latestTop，详情越多时上下区域反而越像被割裂。
                // 把多余空间均分到上下两侧，使下半信息组视觉居中但仍保持整体关系。
                let groupTop = earliestTop + (latestTop - earliestTop) * 0.5
                let box = CGRect(x: c.midX - pictureSize.width / 2, y: groupTop,
                                 width: pictureSize.width, height: pictureSize.height)
                // 实况画面使用更收敛的圆角矩形光晕；浅色主题下对采样色主动压暗并
                // 减小模糊半径，避免过去的大圆形柔光在白底上几乎看不出来。
                if bambu.imageSource == .camera,
                   let cameraFrame = decodeArtwork(picture) {
                    let backgroundLuminance = 0.299 * colors.background.0
                        + 0.587 * colors.background.1 + 0.114 * colors.background.2
                    let lightBackground = backgroundLuminance >= 0.55
                    drawCoverGlow(ctx,
                                  color: cameraGlowColor(dominantColor(of: cameraFrame),
                                                         lightBackground: lightBackground),
                                  coverSkia: box,
                                  extent: lightBackground ? 28 : 34,
                                  blurSigma: lightBackground ? 10 : 14,
                                  innerInset: -2,
                                  cornerRadius: 9,
                                  opacity: lightBackground ? 1 : 0.92)
                }
                if drawImageData(ctx, data: picture, into: box, cover: true, radius: 6) {
                    drawLine(ctx, x1: c.minX + 18, y1: groupTop - 9,
                             x2: c.maxX - 18, y2: groupTop - 9, color: colors.borderCG)
                    strokeRound(ctx, rect(box), radius: 6, color: colors.borderCG, width: 1)
                    y = groupTop + pictureSize.height + 6
                    didDrawPicture = true
                }
            }
        }
        if !didDrawPicture, textReserve > 0 {
            // 没有画面或画面尚未拉到时，详情文字也在下半区均衡排布；否则它们会全挤在
            // 进度条下面、底部留下大面积空白。仍画分隔线，明确上下两类信息。
            let earliestTop = y + groupGap
            let latestTop = max(contentBottom - textReserve, earliestTop)
            y = earliestTop + (latestTop - earliestTop) * 0.5
            if hasUpperSummary {
                drawLine(ctx, x1: c.minX + 18, y1: y - 9,
                         x2: c.maxX - 18, y2: y - 9, color: colors.borderCG)
            }
        }
        // 任务名（文件名）：单行或按分隔符折成的两行
        for line in taskLines {
            var size: CGFloat = taskBaseSize
            let tw = measureTextWidth(line, size: size, bold: false)
            if tw > taskMaxW {
                size = max(size * taskMaxW / tw, 7)
            }
            drawText(ctx, line, size: size, bold: false, color: colors.primaryTextCG,
                     in: rect(c.minX + 10, y, taskMaxW, taskLineH), align: .center)
            y += taskLineH
        }
        // 温度行：喷嘴 / 热床（大字模式单行放不下时拆成两行，避免「热床」被截断）
        if hasTemperature {
            let nozzleText = "喷嘴 \(nozzle?.displayValue ?? "—")"
            let bedText = "热床 \(bed?.displayValue ?? "—")"
            let combined = "\(nozzleText)   \(bedText)"
            let maxW = c.maxX - c.minX - 20
            if measureTextWidth(combined, size: infoSize, bold: false) > maxW {
                drawText(ctx, nozzleText, size: infoSize, bold: false, color: colors.secondaryTextCG,
                         in: rect(c.minX + 10, y, maxW, 16), align: .center)
                y += tempStep * 0.75
                drawText(ctx, bedText, size: infoSize, bold: false, color: colors.secondaryTextCG,
                         in: rect(c.minX + 10, y, maxW, 16), align: .center)
                y += tempStep * 0.75
            } else {
                drawText(ctx, combined, size: infoSize, bold: false, color: colors.secondaryTextCG,
                         in: rect(c.minX + 10, y, maxW, 16), align: .center)
                y += tempStep
            }
        }
        // 时间信息：默认显示可读的剩余时长，也可读取结束时间实体并显示本地短时间。
        if hasTimeInfo, let value = timeEntity {
            let timeText = bambu.timeDisplayMode == .endTime
                ? "预计结束 \(value.displayState)"
                : "剩余 \(value.remainingDisplayText)"
            drawText(ctx, timeText, size: infoSize, bold: false, color: colors.secondaryTextCG,
                     in: rect(c.minX + 10, y, c.maxX - c.minX - 20, 16), align: .center)
            y += remainStep
        }
        // 错误警示：错误码 + HMS 故障原因（内置映射，未收录显示通用提示）
        if isError, bambu.showError {
            drawText(ctx, "⚠ \(errorText)", size: 13, bold: true, color: warn,
                     in: rect(c.minX + 10, y, c.maxX - c.minX - 20, 22), align: .center)
            y += 22
            for line in errorLines {
                drawText(ctx, line, size: 11, bold: true, color: warn,
                         in: rect(c.minX + 10, y, taskMaxW, 15), align: .center)
                y += 15
            }
        } else if status == nil && bambu.statusEntityID.isEmpty {
            drawText(ctx, "在设备管理中配置实体映射", size: 8, bold: false, color: colors.tertiaryTextCG,
                     in: rect(c.minX + 10, y, c.maxX - c.minX - 20, 16), align: .center)
        }
        ctx.restoreGState()
        if settings.nowPlayingFooterVisible {
            drawBambuDataFooter(ctx, card: c, colors: colors,
                                updatedAt: dataUpdatedAt ?? now)
        }
        return try encode(ctx, quality: settings.jpegQuality)
    }

    /// Formlabs Dashboard API 云端卡片：设备状态、任务、进度、层数、材料与缩略图。
    public static func renderFormlabs(deviceName: String,
                                      connection: FormlabsConnectionSettings,
                                      snapshot: FormlabsSnapshot,
                                      settings: AppSettings,
                                      now: Date = Date()) throws -> RenderResult {
        let colors = settings.resolvedPalette
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let c = drawCanvas(ctx, safeArea: safe, colors: colors)
        let accent = connection.useBrandAccent ? Self.formlabsAccentColor : colors.accentCG
        // 与 Bambu Lab 独立卡片共用「左侧色点 + 设备名/产品名双行标头」的设计语言。
        // Dashboard 单独使用强调色，关闭品牌色后会同步跟随全局主题。
        let trimmedDeviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        drawFormlabsHeader(ctx, card: c,
                           deviceName: trimmedDeviceName.isEmpty ? "Formlabs 打印机" : trimmedDeviceName,
                           accent: accent, colors: colors)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)

        guard snapshot.hasData else {
            drawText(ctx, "等待连接", size: 22, bold: true, color: colors.primaryTextCG,
                     in: rect(c.minX + 8, c.minY + 138, c.width - 16, 34), align: .center)
            drawText(ctx, "请先填写 Dashboard API 凭证\n并选择云端打印机",
                     size: 8, bold: false, color: colors.secondaryTextCG,
                     in: rect(c.minX + 10, c.minY + 178, c.width - 20, 46), align: .center)
            return try encode(ctx, quality: settings.jpegQuality)
        }

        let rawStatus = snapshot.print?.status.isEmpty == false
            ? snapshot.print!.status : (snapshot.device?.status ?? "unknown")
        let footerTop = c.maxY - 34
        // 正文与 Bambu 独立卡片一样拥有明确的页脚安全区。安全区设到最大值、
        // 同时显示缩略图和全部详情时，也不能让最后一项压到数据更新时间上。
        ctx.saveGState()
        ctx.clip(to: rect(c.minX, c.minY + 39,
                          c.width, max(footerTop - c.minY - 39, 0)))
        let status = formlabsStatusText(rawStatus)
        let isError = rawStatus.lowercased().contains("error") || rawStatus.lowercased().contains("fail")
        let statusColor = isError ? CGColor(red: 0.95, green: 0.35, blue: 0.25, alpha: 1) : accent

        let taskName = snapshot.print?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let taskSize: CGFloat = 13
        let taskLines = taskName.isEmpty
            ? [] : fileNameLines(taskName, size: taskSize, maxW: c.width - 20, maxLines: 2)
        let infoRowCount = (connection.showLayers
                            && snapshot.print?.currentLayer != nil
                            && (snapshot.print?.layerCount ?? 0) > 0 ? 1 : 0)
            + (connection.showMaterial
               && !(snapshot.print?.materialName ?? "").isEmpty ? 1 : 0)
            + ((snapshot.print?.estimatedTimeRemainingMS
                ?? snapshot.device?.estimatedPrintTimeRemainingMS ?? 0) > 0 ? 1 : 0)
        let reservedTailHeight = (taskLines.isEmpty ? 0 : CGFloat(taskLines.count) * 18 + 5)
            + CGFloat(infoRowCount) * 16

        // 截图同款大字进度区：状态作为浅色背景，百分比数字置于前景，百分号
        // 使用数字一半字号；进度条独占下一行并铺满正文宽度。
        let heroTop = c.minY + 43
        var y: CGFloat
        if let progress = snapshot.print?.progress {
            let clamped = min(max(progress, 0), 1)
            let number = String(format: "%.0f", clamped * 100)
            let backdrop = colors.secondaryTextCG.copy(alpha: 0.34) ?? colors.tertiaryTextCG
            drawBambuStatusText(ctx, status,
                                maxSize: Self.bambuLargeStatusBackdropSize,
                                minSize: 14, color: backdrop,
                                in: CGRect(x: c.minX + 10, y: heroTop - 5,
                                           width: c.width - 20, height: 48),
                                align: .center)
            drawBambuProgressLabel(ctx, number: number,
                                   numberSize: Self.bambuLargeProgressNumberSize,
                                   percentSize: Self.bambuLargeProgressPercentSize,
                                   numberColor: colors.primaryTextCG,
                                   percentColor: colors.secondaryTextCG,
                                   in: rect(c.minX + 10, heroTop + 16, c.width - 20, 46))
            let barY = heroTop + 72
            let progressBounds = rect(c.minX + 10, barY, c.width - 20, 8)
            drawProgress(ctx, progressBounds, progress: clamped,
                         accent: isError ? statusColor : accent,
                         background: colors.borderCG)
            strokeRound(ctx, progressBounds, radius: 4,
                        color: colors.secondaryTextCG, width: 1)
            y = barY + 20
        } else {
            drawBambuStatusText(ctx, status,
                                maxSize: Self.bambuRegularStatusSize,
                                minSize: 10, color: statusColor,
                                in: CGRect(x: c.minX + 10, y: heroTop + 3,
                                           width: c.width - 20, height: 48),
                                align: .center)
            y = heroTop + 67
        }

        if connection.showThumbnail, let thumbnail = snapshot.thumbnail {
            let groupTop = y + 15
            // 缩略图优先保持大图；详情较多或顶部安全区较高时仅收紧图片高度，
            // 不压缩任务名和层数/材料/剩余时间的可读字号。
            let availableThumbnailHeight = footerTop - groupTop - 8 - reservedTailHeight
            let thumbnailHeight = min(max(availableThumbnailHeight, 44), 100)
            let box = CGRect(x: c.minX + 10, y: groupTop,
                             width: c.width - 20, height: thumbnailHeight)
            if let image = decodeArtwork(thumbnail) {
                let sourceRatio = CGFloat(image.width) / max(CGFloat(image.height), 1)
                let boxRatio = box.width / max(box.height, 1)
                let visibleBox: CGRect
                if sourceRatio > boxRatio {
                    let fittedHeight = box.width / sourceRatio
                    visibleBox = CGRect(x: box.minX,
                                        y: box.midY - fittedHeight / 2,
                                        width: box.width, height: fittedHeight)
                } else {
                    let fittedWidth = box.height * sourceRatio
                    visibleBox = CGRect(x: box.midX - fittedWidth / 2,
                                        y: box.minY,
                                        width: fittedWidth, height: box.height)
                }
                let backgroundLuminance = 0.299 * colors.background.0
                    + 0.587 * colors.background.1 + 0.114 * colors.background.2
                let lightBackground = backgroundLuminance >= 0.55
                let sampledGlow = cameraGlowColor(dominantColor(of: image),
                                                   lightBackground: lightBackground)
                // Formlabs 的任务封面只需要一层淡淡的环境色：先向白色混合成
                // 低饱和柔光，再降低整体透明度，避免深色主色形成第二层外框。
                let whiteMix: CGFloat = lightBackground ? 0.30 : 0.42
                let softGlow = (sampledGlow.0 * (1 - whiteMix) + whiteMix,
                                sampledGlow.1 * (1 - whiteMix) + whiteMix,
                                sampledGlow.2 * (1 - whiteMix) + whiteMix)
                drawCoverGlow(ctx,
                              color: softGlow,
                              coverSkia: visibleBox,
                              extent: lightBackground ? 18 : 22,
                              blurSigma: lightBackground ? 9 : 11,
                              innerInset: -1,
                              cornerRadius: 10,
                              opacity: lightBackground ? 0.20 : 0.24)
                if drawImageData(ctx, data: thumbnail, into: box, cover: false, radius: 8) {
                    // contain 模式下边框跟随真实图片边界，避免宽容器形成一圈
                    // 容易被误认为“深色光晕”的空心圆角框。
                    strokeRound(ctx, rect(visibleBox), radius: 8,
                                color: colors.borderCG, width: 1)
                    y = groupTop + thumbnailHeight + 8
                }
            }
        }

        if !taskName.isEmpty {
            for line in taskLines {
                var size = taskSize
                let measured = measureTextWidth(line, size: size, bold: true)
                if measured > c.width - 20 { size = max(size * (c.width - 20) / measured, 9.5) }
                drawText(ctx, line, size: size, bold: true, color: colors.primaryTextCG,
                         in: rect(c.minX + 10, y, c.width - 20, 18), align: .center)
                y += 18
            }
            y += 5
        }

        if connection.showLayers, let current = snapshot.print?.currentLayer,
           let total = snapshot.print?.layerCount, total > 0 {
            drawText(ctx, "层数  \(current) / \(total)", size: 9.5, bold: false,
                     color: colors.secondaryTextCG,
                     in: rect(c.minX + 10, y, c.width - 20, 15), align: .center)
            y += 16
        }
        if connection.showMaterial, let material = snapshot.print?.materialName,
           !material.isEmpty {
            drawText(ctx, "耗材  \(material)", size: 9.5, bold: false,
                     color: colors.secondaryTextCG,
                     in: rect(c.minX + 10, y, c.width - 20, 15), align: .center)
            y += 16
        }
        let remaining = snapshot.print?.estimatedTimeRemainingMS
            ?? snapshot.device?.estimatedPrintTimeRemainingMS
        if let remaining, remaining > 0 {
            drawText(ctx, "剩余  \(formlabsDuration(remaining))", size: 9.5, bold: false,
                     color: colors.secondaryTextCG,
                     in: rect(c.minX + 10, y, c.width - 20, 15), align: .center)
            y += 16
        }
        if let message = snapshot.print?.message, !message.isEmpty, y < c.maxY - 55 {
            drawText(ctx, message, size: 8, bold: false, color: colors.secondaryTextCG,
                     in: rect(c.minX + 10, y, c.width - 20, 28), align: .center)
        }

        ctx.restoreGState()

        drawLine(ctx, x1: c.minX + 18, y1: c.maxY - 29,
                 x2: c.maxX - 18, y2: c.maxY - 29, color: colors.borderCG)
        let footer = snapshot.cloudError == nil
            ? "数据更新  \(formatDate(snapshot.sampledAt ?? now, "HH:mm:ss"))"
            : "缓存数据  \(formatDate(snapshot.sampledAt ?? now, "HH:mm:ss"))"
        drawText(ctx, footer, size: 8.5, bold: true, color: colors.secondaryTextCG,
                 in: rect(c.minX + 8, c.maxY - 25, c.width - 16, 17), align: .center)
        return try encode(ctx, quality: settings.jpegQuality)
    }

    public static func formlabsStatusText(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "-", with: "_")
        let values: [String: String] = [
            "idle": "空闲", "ready": "就绪", "printing": "打印中",
            "paused": "已暂停", "finished": "已完成", "completed": "已完成",
            "preparing": "准备中", "finishing": "收尾中", "warming": "预热中",
            "error": "发生错误", "failed": "打印失败", "offline": "离线",
            "cancelled": "已取消", "canceled": "已取消", "aborted": "已取消",
            "disconnected": "未连接", "unknown": "状态未知"
        ]
        return values[normalized] ?? (raw.isEmpty ? "状态未知" : raw)
    }

    private static func formlabsDuration(_ milliseconds: Double) -> String {
        let minutes = max(Int(milliseconds / 60_000), 0)
        let hours = minutes / 60
        let rest = minutes % 60
        if hours > 0 { return rest > 0 ? "\(hours)小时\(rest)分" : "\(hours)小时" }
        return "\(rest)分钟"
    }

    private static func drawFormlabsInfoRow(_ ctx: CGContext, title: String, value: String,
                                             y: CGFloat, card: CGRect, colors: ScreenPalette) {
        let box = CGRect(x: card.minX + 10, y: y, width: card.width - 20, height: 22)
        drawBox(ctx, rect(box), colors: colors)
        // 使用实际字形边界（而非字体 ascent/descent）对齐胶囊框中心；中文标签与数字/英文
        // 的上下留白不同，固定偏移无法让两边同时居中。
        drawGlyphCenteredText(ctx, title, size: 10, bold: true,
                              color: colors.secondaryTextCG,
                              in: rect(box.minX + 7, box.minY, 30, box.height), align: .left)
        let valueWidth = box.width - 42
        var valueSize: CGFloat = 11
        let measured = measureTextWidth(value, size: valueSize, bold: true)
        if measured > valueWidth { valueSize = max(valueSize * valueWidth / measured, 8) }
        drawGlyphCenteredText(ctx, value, size: valueSize, bold: true,
                              color: colors.primaryTextCG,
                              in: rect(box.minX + 35, box.minY, valueWidth, box.height),
                              align: .right)
    }

    public static func renderNowPlaying(_ info: NowPlayingInfo, settings: AppSettings,
                                        artworkImage: CGImage? = nil,
                                        lyrics: LyricsDisplayWindow? = nil,
                                        lyricsOnly: Bool = false,
                                        now: Date = Date()) throws -> RenderResult {
        let artImage = artworkImage ?? (info.artwork.flatMap { decodeArtwork($0) })
        // 有封面时从封面取主色作为卡片背景；无封面回退主题配色
        let coverDominant = artImage.map { dominantColor(of: $0) }
        let colors: ScreenPalette
        if let artImage {
            colors = artworkPalette(of: artImage,
                                    themeAccent: settings.resolvedPalette.accent)
        } else {
            colors = settings.resolvedPalette
        }
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let c = drawCanvas(ctx, safeArea: safe, colors: colors)

        let accent = colors.accentCG
        if lyricsOnly {
            drawLyricsOnly(ctx, card: c, lyrics: lyrics, colors: colors, accent: accent)
            return try encode(ctx, quality: settings.jpegQuality)
        }
        // 封面几何：页脚可见时贴顶；隐藏页脚时在「头部下方 ～ 信息区上方」的可用空间内垂直居中
        // （考虑文字与进度条占用空间，而不是整卡中心）
        let top = c.minY + 49
        let footerVisible = settings.nowPlayingFooterVisible
        // 歌名先排版：双行时多留一行高度（信息区整体上移、封面缩小让位），
        // 而不是把字号缩到不可读
        let titleMaxW = c.maxX - c.minX - 20
        let titleLayout = nowPlayingTitleLines(title: info.title.isEmpty ? "未在播放" : info.title,
                                               maxWidth: titleMaxW,
                                               maxSize: 10)
        let extraTitleH: CGFloat = titleLayout.lines.count > 1 ? 14 : 0
        let infoTop = (footerVisible ? (top + 100) : (c.maxY - 15 - 70)) - extraTitleH
        let artSize: CGFloat = 92 - extraTitleH
        let artX = (c.minX + c.maxX) / 2 - artSize / 2
        let artY: CGFloat = footerVisible ? top : top + (infoTop - top - artSize) / 2
        let artSkia = CGRect(x: artX, y: artY, width: artSize, height: artSize)
        let artRect = rect(artSkia)

        // 封面主色光晕（画在最底层，头部文字与封面都叠在其上）：
        // 暗色封面提亮后，用单次高斯模糊生成平滑径向光晕——无分层色带，JPEG 压缩后依然干净
        if let artImage, let coverDominant {
            drawCoverGlow(ctx, color: boostedGlowColor(coverDominant),
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
        // 歌名：单行居中；过长时折成两行（与播放器标题栏一致），行高均分标题区
        let titleBlockH: CGFloat = 18 + extraTitleH
        let titleLineH = titleBlockH / CGFloat(max(titleLayout.lines.count, 1))
        for (li, line) in titleLayout.lines.enumerated() {
            drawText(ctx, line, size: titleLayout.size, bold: true, color: colors.primaryTextCG,
                     in: rect(c.minX + 10, infoTop + CGFloat(li) * titleLineH,
                              titleMaxW, titleLineH), align: .center)
        }
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
        // 信息区自上而下顺序排布：歌名块（可能两行）→ 歌手/专辑 → 进度条 → 时间，
        // 歌名折成两行时后续内容整体下移，不再被遮挡
        let subtitleY = infoTop + titleBlockH + 2
        drawAdaptiveText(ctx, subtitle, maxSize: 8, minSize: 5.5,
                         bold: false, color: colors.secondaryTextCG,
                         in: rect(c.minX + 10, subtitleY, c.maxX - c.minX - 20, 14), align: .center)
        // 进度条强调色：有封面时从封面主色生成（深色封面提亮、浅色封面加深），不跟随全局强调色
        let progressAccent: (CGFloat, CGFloat, CGFloat)
        if let coverDominant {
            progressAccent = coverProgressAccent(coverDominant)
        } else {
            progressAccent = colors.accent
        }
        drawProgress(ctx, rect(c.minX + 14, subtitleY + 22, c.maxX - c.minX - 28, 6),
                     progress: info.progress,
                     accent: CGColor(red: progressAccent.0, green: progressAccent.1,
                                     blue: progressAccent.2, alpha: 1),
                     background: colors.borderCG)
        let timeText = "\(formatClock(info.elapsedTime)) / \(formatClock(info.duration))"
        drawText(ctx, timeText, size: 8, bold: false, color: colors.secondaryTextCG,
                 in: rect(c.minX + 10, subtitleY + 32, c.maxX - c.minX - 20, 14), align: .center)

        // 关联口袋先知/AI Mac 后，灵犀 68 的纵向留白用于同步歌词：当前行加粗并
        // 使用轻量强调底，其余相邻行弱化。没有歌词时完全保持旧版布局。
        if let lyrics, !lyrics.lines.isEmpty {
            let lyricTop = subtitleY + 50
            let lyricBottom = footerVisible ? c.maxY - 92 : c.maxY - 14
            let availableHeight = lyricBottom - lyricTop
            if availableHeight >= 24 {
                drawLine(ctx, x1: c.minX + 18, y1: lyricTop,
                         x2: c.maxX - 18, y2: lyricTop, color: colors.borderCG)
                let visibleCount = min(lyrics.lines.count,
                                       max(1, min(3, Int((availableHeight - 5) / 17))))
                let start = max(0, min(lyrics.currentIndex - visibleCount / 2,
                                       lyrics.lines.count - visibleCount))
                let visibleLines = Array(lyrics.lines[start..<(start + visibleCount)])
                let currentVisibleIndex = lyrics.currentIndex - start
                let rowHeight = min(CGFloat(18), (availableHeight - 5) / CGFloat(visibleCount))
                for (index, line) in visibleLines.enumerated() {
                    let y = lyricTop + 5 + CGFloat(index) * rowHeight
                    let row = CGRect(x: c.minX + 8, y: y,
                                     width: c.width - 16, height: rowHeight - 1)
                    let isCurrent = index == currentVisibleIndex
                    if isCurrent {
                        fillRound(ctx, rect(row), radius: 5,
                                  color: accent.copy(alpha: 0.14) ?? accent)
                    }
                    drawAdaptiveText(ctx, line, maxSize: isCurrent ? 10 : 8.5,
                                     minSize: 5.5, bold: isCurrent,
                                     color: isCurrent ? colors.primaryTextCG : colors.tertiaryTextCG,
                                     in: rect(row.minX + 4, row.minY,
                                              row.width - 8, row.height), align: .center)
                }
            }
        }

        // 页脚：当前时间（上：时钟，下：日期）；格式与字号可自定义，也可整体隐藏。
        // 各带高度随字号自适应，字号调小后行距同步收紧释放空间。
        // 页脚不能直接复用较细的进度条色：极深封面上，同色相的简单
        // 倍率提亮仍可能不可读。按卡片实际底色选择对比度达标的同系色阶，
        // 深底使用浅色、浅底使用深色，同时保留封面色相。
        if footerVisible {
            let footerAccent = artworkReadableAccent(background: colors.card,
                                                       seed: colors.accent)
            drawFooterClock(ctx, card: c, settings: settings, colors: colors, now: now,
                            accent: CGColor(red: footerAccent.0, green: footerAccent.1,
                                            blue: footerAccent.2, alpha: 1),
                            tintAll: true)
        }

        return try encode(ctx, quality: settings.jpegQuality)
    }

    /// 灵犀 68 歌词联动专用画面。联动后不再保留封面、歌曲信息、进度与页脚，
    /// 把纵向空间完整交给当前歌词及相邻上下文。
    private static func drawLyricsOnly(_ ctx: CGContext, card: CGRect,
                                       lyrics: LyricsDisplayWindow?,
                                       colors: ScreenPalette, accent: CGColor) {
        let fallback = LyricsDisplayWindow(lines: ["暂未找到歌词"], currentIndex: 0)
        let window = (lyrics?.lines.isEmpty == false) ? lyrics! : fallback
        let lines = window.lines
        let region = card.insetBy(dx: 8, dy: 16)
        let current = min(max(window.currentIndex, 0), max(lines.count - 1, 0))
        let currentWeight: CGFloat = lines.count == 1 ? 1 : 0.54
        let secondaryCount = max(lines.count - 1, 1)
        let secondaryWeight = (1 - currentWeight) / CGFloat(secondaryCount)
        var cursor = region.minY

        func drawLine(_ text: String, in bounds: CGRect, isCurrent: Bool) {
            if isCurrent {
                fillRound(ctx, rect(bounds.insetBy(dx: 1, dy: 3)), radius: 10,
                          color: accent.copy(alpha: 0.14) ?? accent)
            }
            var size: CGFloat = isCurrent ? 18 : 10.5
            let minimum: CGFloat = isCurrent ? 9 : 7
            var wrapped = wrapText(text, maxWidth: bounds.width - 12,
                                   size: size, bold: isCurrent)
            while CGFloat(max(wrapped.count, 1)) * size * 1.3 > bounds.height - 8,
                  size > minimum {
                size -= 0.5
                wrapped = wrapText(text, maxWidth: bounds.width - 12,
                                   size: size, bold: isCurrent)
            }
            let maxLines = max(1, Int((bounds.height - 8) / max(size * 1.3, 1)))
            wrapped = Array(wrapped.prefix(maxLines))
            let lineHeight = size * 1.3
            let blockHeight = CGFloat(wrapped.count) * lineHeight
            let top = bounds.minY + max((bounds.height - blockHeight) / 2, 0)
            for (index, value) in wrapped.enumerated() {
                drawText(ctx, value, size: size, bold: isCurrent,
                         color: isCurrent ? colors.primaryTextCG : colors.tertiaryTextCG,
                         in: rect(bounds.minX + 6, top + CGFloat(index) * lineHeight,
                                  bounds.width - 12, lineHeight), align: .center)
            }
        }

        for (index, line) in lines.enumerated() {
            let weight = index == current ? currentWeight : secondaryWeight
            let height = index == lines.count - 1 ? region.maxY - cursor : region.height * weight
            let row = CGRect(x: region.minX, y: cursor, width: region.width, height: height)
            drawLine(line, in: row, isCurrent: index == current)
            cursor += height
        }
    }

    /// 封面光晕主色：暗色封面按 0.4/luminance 比例提亮（保色相、不超白），保证深色封面的光晕可见
    private static func boostedGlowColor(_ rgb: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
        let lum = 0.299 * rgb.0 + 0.587 * rgb.1 + 0.114 * rgb.2
        guard lum < 0.4, lum > 0.01 else { return rgb }
        let factor = min(0.4 / lum, 4)
        return (min(rgb.0 * factor, 1), min(rgb.1 * factor, 1), min(rgb.2 * factor, 1))
    }

    /// 摄像头光晕需要同时适配深浅底色：深色底沿用提亮策略；浅色底把过亮采样色
    /// 压到中等亮度，暗色则略微抬起，既保留原画面色相又与白色卡片拉开反差。
    private static func cameraGlowColor(_ rgb: (CGFloat, CGFloat, CGFloat),
                                        lightBackground: Bool)
        -> (CGFloat, CGFloat, CGFloat) {
        guard lightBackground else { return boostedGlowColor(rgb) }
        let luminance = 0.299 * rgb.0 + 0.587 * rgb.1 + 0.114 * rgb.2
        if luminance > 0.50 {
            let factor = 0.50 / max(luminance, 0.01)
            return (rgb.0 * factor, rgb.1 * factor, rgb.2 * factor)
        }
        if luminance < 0.20, luminance > 0.01 {
            let factor = min(0.26 / luminance, 3)
            return (min(rgb.0 * factor, 1), min(rgb.1 * factor, 1), min(rgb.2 * factor, 1))
        }
        return rgb
    }

    /// 从封面主色生成进度条强调色：深色封面提亮、浅色封面加深，
    /// 保证在封面底（=主色）上有足够对比；不跟随全局强调色。
    /// 对比度增强：深色提亮到更高亮度、浅色加深到更低亮度，进度条更清晰可见
    public static func coverProgressAccent(_ rgb: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
        let lum = 0.299 * rgb.0 + 0.587 * rgb.1 + 0.114 * rgb.2
        if lum < 0.5 {
            // 深色封面：提亮到明显亮于背景（目标亮度 0.9 封顶）
            let target = min(0.9, lum * 2.6)
            let factor = lum > 0.02 ? target / lum : 4.0
            return (min(rgb.0 * factor, 1), min(rgb.1 * factor, 1), min(rgb.2 * factor, 1))
        } else {
            // 浅色封面：加深到明显深于背景（亮度下限 0.25）
            let factor = max(0.25, 0.36 - (lum - 0.5) * 0.15)
            return (max(rgb.0 * factor, 0), max(rgb.1 * factor, 0), max(rgb.2 * factor, 0))
        }
    }

    /// 复用的 Core Image 上下文（创建开销大，进程内共享）
    private static let glowCIContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// 封面/实况光晕：在与内容宽高比一致的离屏画布绘制圆角矩形后做单次高斯模糊。
    /// 参数默认值保留专辑封面风格；摄像头可使用更小的扩散与模糊来强化矩形轮廓。
    private static func drawCoverGlow(_ ctx: CGContext, color: (CGFloat, CGFloat, CGFloat),
                                      coverSkia: CGRect,
                                      extent: CGFloat = 70,
                                      blurSigma: CGFloat = 24,
                                      innerInset: CGFloat = 5,
                                      cornerRadius: CGFloat = 16,
                                      opacity: CGFloat = 1) {
        let pixelWidth = Int(ceil(coverSkia.width + extent * 2))
        let pixelHeight = Int(ceil(coverSkia.height + extent * 2))
        guard pixelWidth > 0, pixelHeight > 0,
              let glowSrc = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let inner = CGRect(x: extent + innerInset, y: extent + innerInset,
                           width: max(coverSkia.width - innerInset * 2, 1),
                           height: max(coverSkia.height - innerInset * 2, 1))
        glowSrc.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        glowSrc.addPath(CGPath(roundedRect: inner,
                               cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                               transform: nil))
        glowSrc.fillPath()
        guard let srcImage = glowSrc.makeImage() else { return }
        let blurred = CIImage(cgImage: srcImage).applyingGaussianBlur(sigma: blurSigma)
        let crop = CGRect(x: 0, y: 0,
                          width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        guard let outImage = glowCIContext.createCGImage(blurred, from: crop) else { return }
        let dest = rect(coverSkia.insetBy(dx: -extent, dy: -extent))
        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.interpolationQuality = .high
        ctx.draw(outImage, in: dest)
        ctx.restoreGState()
    }

    /// Home Assistant 辅助页脚：时间与日期合并成一行小号弱对比文本，
    /// 把视觉主次留给实体状态卡片。
    private static func drawHAFooterClock(_ ctx: CGContext, card c: CGRect, settings: AppSettings,
                                          colors: ScreenPalette, now: Date) {
        let time = formatDate(now, settings.timeFormat)
        let date = formatDate(now, settings.dateFormat)
        let text = "\(time)  ·  \(date)"
        let maxW = c.maxX - c.minX - 20
        let size = adaptiveFontSize(text, maxSize: 7.5, minSize: 5,
                                    bold: false, maxWidth: maxW)
        drawLine(ctx, x1: c.minX + 18, y1: c.maxY - 25,
                 x2: c.maxX - 18, y2: c.maxY - 25, color: colors.borderCG)
        drawText(ctx, text, size: size, bold: false, color: colors.tertiaryTextCG,
                 in: rect(c.minX + 10, c.maxY - 23, maxW, 15), align: .center)
    }

    /// Bambu 卡片只显示数据更新时间：不再复用“当前时间 + 时间 + 日期”的大号三行页脚，
    /// 既能判断状态新鲜度，也把垂直空间还给打印进度、任务与摄像头画面。
    private static func drawBambuDataFooter(_ ctx: CGContext, card c: CGRect,
                                             colors: ScreenPalette, updatedAt: Date) {
        let text = "数据更新  \(formatDate(updatedAt, "HH:mm:ss"))"
        let maxW = c.maxX - c.minX - 20
        drawLine(ctx, x1: c.minX + 18, y1: c.maxY - 30,
                 x2: c.maxX - 18, y2: c.maxY - 30, color: colors.borderCG)
        drawText(ctx, text, size: Self.bambuDataFooterSize, bold: true,
                 color: colors.secondaryTextCG,
                 in: rect(c.minX + 10, c.maxY - 27, maxW, 19), align: .center)
    }

    /// 页脚时钟：当前时间（上：时钟，下：日期），格式/字号随设置、可整体隐藏。
    /// shadowed=true 时三行文字带轻量投影（浅色背景/无压暗遮罩时保证与底图分离可读），
    /// shadowAlpha/shadowOffset 用于调淡投影
    private static func drawFooterClock(_ ctx: CGContext, card c: CGRect, settings: AppSettings,
                                        colors: ScreenPalette, now: Date, accent: CGColor,
                                        tintAll: Bool = false, shadowed: Bool = false,
                                        shadowAlpha: CGFloat = 0.55,
                                        shadowOffset: CGFloat = 0.9) {
        let bottom = c.maxY - 15
        let preferredDateSize: CGFloat = 17
        let preferredTimeSize: CGFloat = 22
        let footerTextWidth = max(c.maxX - c.minX - 10, 1)
        let timeText = clockTimeText(now, format: settings.timeFormat)
        let dateText = formatDate(now, settings.dateFormat)
        let fittedTimeSize = adaptiveFontSize(
            timeText, maxSize: preferredTimeSize, minSize: min(preferredTimeSize, 6),
            bold: true, maxWidth: footerTextWidth)
        let fittedDateSize = adaptiveFontSize(
            dateText, maxSize: preferredDateSize, minSize: min(preferredDateSize, 5),
            bold: true, maxWidth: footerTextWidth)
        // 高度仍按用户设定的目标字号预留，避免仅因格式变长导致整个页脚上下跳动。
        let dateHeight = max(preferredDateSize + 8, 18)
        let timeHeight = max(preferredTimeSize + 10, 24)
        let labelTop = bottom - dateHeight - timeHeight - 16
        func draw(_ text: String, size: CGFloat, bold: Bool, color: CGColor, in r: CGRect) {
            if shadowed {
                drawTextShadowed(ctx, text, size: size, bold: bold, color: color, in: r, align: .center,
                                 shadowAlpha: shadowAlpha, shadowOffset: shadowOffset)
            } else {
                drawText(ctx, text, size: size, bold: bold, color: color, in: r, align: .center)
            }
        }
        // tintAll=true 时「当前时间」标签与日期也用强调色（正在播放卡片跟随封面强调色）
        draw("当前时间", size: 9, bold: true, color: tintAll ? accent : colors.tertiaryTextCG,
             in: rect(c.minX + 9, labelTop, c.maxX - c.minX - 18, 16))
        draw(timeText, size: fittedTimeSize,
             bold: true, color: accent,
             in: rect(c.minX + 5, bottom - dateHeight - timeHeight, c.maxX - c.minX - 10, timeHeight))
        draw(dateText, size: fittedDateSize,
             bold: true, color: tintAll ? accent : colors.primaryTextCG,
             in: rect(c.minX + 5, bottom - dateHeight, c.maxX - c.minX - 10, dateHeight))
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
        // 显示出处：开启后语录出处替换时钟位置并隐藏时钟（无确切出处的语录回退正常页脚）
        let quoteSource = excerptSource(for: quote) ?? ""
        let showsSource = settings.showExcerptSource && !quoteSource.isEmpty
        let footerReserve: CGFloat = (footerVisible || showsSource) ? 70 : 20
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

        if showsSource {
            drawQuoteSource(ctx, card: c, source: quoteSource, colors: colors)
        } else if footerVisible {
            drawFooterClock(ctx, card: c, settings: settings, colors: colors, now: now, accent: accent)
        }
        return try encode(ctx, quality: settings.jpegQuality)
    }

    /// 语录出处页脚：替换时钟位置显示「—— 出处」，小字号自适应最多两行居中
    private static func drawQuoteSource(_ ctx: CGContext, card c: CGRect, source: String,
                                        colors: ScreenPalette) {
        let bottom = c.maxY - 15
        let blockH: CGFloat = 46
        let blockTop = bottom - blockH
        let maxWidth = c.maxX - c.minX - 16
        let attribution = "—— " + source
        var size: CGFloat = 11
        var lines: [String] = []
        while size >= 7 {
            let wrapped = wrapText(attribution, maxWidth: maxWidth, size: size)
            if wrapped.count <= 2, CGFloat(wrapped.count) * size * 1.3 <= blockH {
                lines = wrapped
                break
            }
            size -= 0.5
        }
        if lines.isEmpty {
            lines = Array(wrapText(attribution, maxWidth: maxWidth, size: 7).prefix(2))
            size = 7
        }
        let lineH = blockH / CGFloat(lines.count)
        for (index, line) in lines.enumerated() {
            drawText(ctx, line, size: size, bold: true, color: colors.primaryTextCG,
                     in: rect(c.minX + 8, blockTop + CGFloat(index) * lineH,
                              c.maxX - c.minX - 16, lineH), align: .center)
        }
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
        let colors = sspaiPalette(settings.resolvedPalette)
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
                let lineStep = titleSize * 1.25
                let titleH = CGFloat(lines.count) * lineStep
                for (li, line) in lines.enumerated() {
                    drawText(ctx, line, size: titleSize, bold: false, color: colors.primaryTextCG,
                             in: rect(titleX, y + CGFloat(li) * lineStep, titleW, titleSize * 1.3),
                             align: .left)
                }
                if !article.author.isEmpty {
                    // 作者紧贴标题下方绘制（作者区域高度=作者字号，不再在剩余整行空间垂直居中，
                    // 避免标题与作者之间出现大段留白）
                    drawText(ctx, article.author, size: authorSize, bold: false,
                             color: colors.tertiaryTextCG,
                             in: rect(titleX, y + titleH + 2, titleW, authorSize + 2), align: .left)
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
        // 完整壁纸不使用玻璃默认调色板，避免全局风格改变 Emoji 的背景或页脚。
        let colors = ScreenThemes.resolved(theme: settings.cardTheme,
            backgroundTone: settings.backgroundTone, customBackgroundHex: settings.customBackgroundHex,
            accentTone: settings.accentTone, customAccentHex: settings.customAccentHex,
            softwareIsDark: settings.softwareIsDark)
        if !ColorCardSceneCapture.background(ctx, palette: colors) {
            ctx.setFillColor(colors.backgroundCG)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

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
                // 开启底部时间显示时螺旋中心上移 1/4 屏高：时间遮罩区背景更干净，主体螺旋视觉居中于剩余空间
                let spiralOffset: CGFloat = settings.nowPlayingFooterVisible ? CGFloat(height) / 4 : 0
                drawEmojiSpiral(ctx, emojis: emojis, baseSize: baseSize, spacing: spacing,
                                centerOffsetY: spiralOffset)
            }
        }

        // 页脚时钟（复用「正在播放」的底部时间/日期开关）；时间背后用高斯模糊遮罩
        // （毛玻璃效果，顶缘纵向 alpha 渐变平滑过渡），保证时间可读
        if settings.nowPlayingFooterVisible {
            drawEmojiFooterBlur(ctx, settings: settings, now: now, colors: colors)
        }
        return try encode(ctx, quality: settings.jpegQuality)
    }

    /// Emoji 壁纸页脚遮罩：把时间/日期背后的 emoji 区域做高斯模糊（毛玻璃）+ 轻量压暗，
    /// 顶缘用纵向 alpha 渐变平滑过渡（无硬边）；CoreImage 不可用时回退半透明深色带。
    /// 模糊前 clampedToExtent 复制边缘像素：避免模糊在裁剪区四周采样到透明黑，
    /// 产生屏幕左右/底部边缘的暗边（视觉上“边缘空缺”）
    private static func drawEmojiFooterBlur(_ ctx: CGContext, settings: AppSettings,
                                            now: Date, colors: ScreenPalette) {
        let bottom = CGFloat(height) - 15
        let dateH = max(17 + 8, 18)
        let timeH = max(22 + 10, 24)
        let labelTop = bottom - dateH - timeH - 16
        let bandTop = labelTop - 36                       // 遮罩加大：淡入区在文字上方完成，覆盖更宽底部区域
        let bandH = CGFloat(height) - bandTop
        let pad: CGFloat = 12                             // 顶部淡入透明段
        let fadeH: CGFloat = 16                           // 顶缘淡入高度
        let cropTop = bandTop - pad
        let cropH = bandH + pad
        let maskW = Int(CGFloat(width).rounded())
        let maskH = Int(cropH.rounded())
        // 浅色背景（浅色模式/浅色底色）下不加深遮罩，只保留毛玻璃模糊，
        // 避免浅底上出现灰暗色块；深色背景才压暗保证文字可读
        let bg = colors.background
        let isLightBackground = 0.299 * bg.0 + 0.587 * bg.1 + 0.114 * bg.2 >= 0.5
        if ColorCardSceneCapture.panel(
            ctx, bounds: rect(4, max(labelTop - 8, 4), CGFloat(width) - 8,
                              CGFloat(height) - 4 - max(labelTop - 8, 4)),
            radius: 15, color: colors.cardCG) {
            // 先保存完整 Emoji 底图，再由 SwiftUI 渲染玻璃；文字保持原来位置。
            // 新模式不重复执行旧的模糊条带，避免图像被两次模糊。
            drawFooterClock(ctx, card: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                            settings: settings, colors: colors, now: now,
                            accent: colors.accentCG, tintAll: true)
            return
        }
        let base = ctx.makeImage()
        // 页脚文字动态取色：从底部遮罩区域背景采样主色，按明暗做深提亮/浅加深保证对比
        // （深背景取亮色、浅背景取深色，复用封面智能取色逻辑）；取样失败回退主题强调色
        var footerAccent = colors.accentCG
        if let base {
            let sampleTop = max(Int(bandTop), 0)
            let sampleH = min(Int(bandH), height - sampleTop)
            if sampleH > 0,
               let sampled = base.cropping(to: CGRect(x: 0, y: sampleTop, width: width, height: sampleH)) {
                let acc = coverProgressAccent(dominantColor(of: sampled))
                footerAccent = CGColor(red: acc.0, green: acc.1, blue: acc.2, alpha: 1)
            }
        }
        var blurredCG: CGImage?
        if let base {
            let ciImage = CIImage(cgImage: base)
            // 边缘像素无限复制后再模糊：模糊不混入透明黑，四周无暗边
            let filtered = ciImage.clampedToExtent().applyingGaussianBlur(sigma: 6)
            // 只取底部条带（CIImage 坐标 y 向上：0 = 图像底部）
            blurredCG = CIContext().createCGImage(filtered,
                                                  from: CGRect(x: 0, y: 0,
                                                               width: CGFloat(width), height: cropH))
        }
        guard let blurredCG else {
            // 兜底：深色背景用半透明深色带保证时间可读；浅色背景轻微压暗（约 10%）
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: isLightBackground ? 0.10 : 0.32))
            ctx.fill(rect(0, bandTop, CGFloat(width), bandH))
            drawFooterClock(ctx, card: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                            settings: settings, colors: colors, now: now, accent: footerAccent,
                            tintAll: true, shadowed: isLightBackground,
                            shadowAlpha: isLightBackground ? 0.28 : 0.55,
                            shadowOffset: isLightBackground ? 0.6 : 0.9)
            return
        }
        // 纵向 alpha 渐变遮罩（灰度图）：pad 段完全透明 → fadeH 内线性淡入 → 其余不透明，
        // 保证模糊区与未模糊壁纸之间平滑过渡、无生硬边缘
        var bytes = [UInt8](repeating: 255, count: maskW * maskH)
        for y in 0..<maskH {
            let skiaY = cropTop + CGFloat(y)
            let a: CGFloat
            if skiaY <= bandTop { a = 0 }
            else if skiaY >= bandTop + fadeH { a = 1 }
            else { a = (skiaY - bandTop) / fadeH }
            let v = UInt8((a * 255).rounded())
            for x in 0..<maskW { bytes[y * maskW + x] = v }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let maskImage = CGImage(width: maskW, height: maskH, bitsPerComponent: 8, bitsPerPixel: 8,
                                bytesPerRow: maskW, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(), provider: provider, decode: nil,
                                shouldInterpolate: true, intent: .defaultIntent)!
        let bandCG = rect(0, cropTop, CGFloat(width), cropH)
        ctx.saveGState()
        ctx.clip(to: bandCG, mask: maskImage)
        ctx.interpolationQuality = .high
        ctx.draw(blurredCG, in: bandCG)
        // 轻量压暗（同一渐变遮罩生效）：深色背景 0.22 保证文字可读，
        // 浅色背景只加约 0.10 轻微压暗（不突兀、也不与背景完全融合）
        let tintAlpha: CGFloat = isLightBackground ? 0.10 : 0.22
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: tintAlpha))
        ctx.fill(bandCG)
        ctx.restoreGState()
        drawFooterClock(ctx, card: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                        settings: settings, colors: colors, now: now, accent: footerAccent,
                        tintAll: true, shadowed: isLightBackground,
                        shadowAlpha: isLightBackground ? 0.28 : 0.55,
                        shadowOffset: isLightBackground ? 0.6 : 0.9)
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

    /// 螺旋：从屏幕中心向外呈漩涡状排布，中间小、越靠边缘越大，间隔影响疏密。
    /// centerOffsetY > 0 时中心整体上移该量（开启底部时间显示时，给时间遮罩区留出更干净的背景）
    private static func drawEmojiSpiral(_ ctx: CGContext, emojis: [Character],
                                        baseSize: CGFloat, spacing: CGFloat,
                                        centerOffsetY: CGFloat = 0) {
        let w = CGFloat(width)
        let h = CGFloat(height)
        let cx = w / 2
        let cy = h / 2 - centerOffsetY
        // 最大半径按新中心到最远屏幕角的距离计算：中心上移后仍铺满全屏、不留空区
        let maxR: CGFloat = max(
            (cx * cx + cy * cy).squareRoot(),
            ((w - cx) * (w - cx) + cy * cy).squareRoot(),
            (cx * cx + (h - cy) * (h - cy)).squareRoot(),
            ((w - cx) * (w - cx) + (h - cy) * (h - cy)).squareRoot()
        )
        // 加大中心与边缘的大小对比（中心更小、边缘更大，变化更剧烈）
        let minSize = baseSize * 0.2
        let maxSize = baseSize * 2.2
        let twoPi: CGFloat = 2 * CGFloat.pi
        var theta: CGFloat = 0
        var r: CGFloat = 0
        var index = 0
        var placed = 0
        while r <= maxR, placed < 2000 {
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
            // 中心紧密、边缘舒展、渐变过渡：弧长步进与每圈半径增量都随该处表情尺寸自适应
            // （≈ 直径 + 间隔）——相邻表情、相邻圈刚好衔接，消除中心放射状大空隙。
            // 密度系数仅作用于中心区（t<0.35，中心 ≈1.9× 步长 ≈ 密度约一半、渐变回落），
            // 外圈保持贴合排列不变——整体既不过密、也不回退到稀疏
            let effSpacing = spacing * (0.35 + 0.65 * t)
            let boost = 1 + 0.9 * max(0, 1 - t / 0.35)
            let step = max(size + effSpacing, minSize + effSpacing) * boost
            let dTheta = step / max(r, step)
            theta += dTheta
            r += step * (dTheta / twoPi)
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

    /// Material You 风格的壁纸时钟色调阶。先提取种子色，再在感知均匀的 OKLCH
    /// 色彩空间中只改变明度、保留色相与主要色度。亮/暗色阶会按与壁纸的实际
    /// WCAG 对比度择优，而非只用一个固定明暗阈值。
    public static func wallpaperClockColors(
        of image: CGImage, style: WallpaperColorStyle = .natural
    ) -> (primary: (CGFloat, CGFloat, CGFloat),
          secondary: (CGFloat, CGFloat, CGFloat),
          primaryOutline: (CGFloat, CGFloat, CGFloat),
          secondaryOutline: (CGFloat, CGFloat, CGFloat),
          usesLightTones: Bool) {
        let background = dominantColor(of: image)
        let seed = wallpaperSeedColor(of: image)

        // 以 AOSP Monet 的三种常见动态配色方向生成 Accent 1/2：
        // Natural(Tonal Spot) 保持种子色相；Vibrant 提高色度并轻偏次色；
        // Expressive 对主色做明显色相偏移、次色做轻微偏移，形成更活泼的层次。
        // 最终仍由 OKLCH 色域映射与实际对比度选择保证屏幕可读性。
        let source = rgbToOKLCH(seed)
        let hasUsableChroma = source.chroma >= 0.025
        let primaryHueOffset: Double
        let secondaryHueOffset: Double
        let accent1Chroma: Double
        let accent2Chroma: Double
        switch style {
        case .natural:
            primaryHueOffset = 0
            secondaryHueOffset = 0
            accent1Chroma = hasUsableChroma ? 0.145 : source.chroma
            accent2Chroma = hasUsableChroma ? 0.052 : source.chroma
        case .vibrant:
            primaryHueOffset = 0
            secondaryHueOffset = .pi / 12       // +15°
            accent1Chroma = hasUsableChroma ? 0.19 : source.chroma
            accent2Chroma = hasUsableChroma ? 0.09 : source.chroma
        case .expressive:
            primaryHueOffset = .pi * 4 / 3      // +240°
            secondaryHueOffset = .pi / 12       // +15°
            accent1Chroma = hasUsableChroma ? 0.125 : source.chroma
            accent2Chroma = hasUsableChroma ? 0.075 : source.chroma
        }
        let lightPrimary = perceptualTone(of: seed, lightness: 0.92, chroma: accent1Chroma,
                                          hueOffset: primaryHueOffset)
        let lightSecondary = perceptualTone(of: seed, lightness: 0.84, chroma: accent2Chroma,
                                            hueOffset: secondaryHueOffset)
        let darkPrimary = perceptualTone(of: seed, lightness: 0.32, chroma: accent1Chroma,
                                         hueOffset: primaryHueOffset)
        let darkSecondary = perceptualTone(of: seed, lightness: 0.42, chroma: accent2Chroma,
                                           hueOffset: secondaryHueOffset)
        // 描边也跟随底图明暗反色：暗图使用同色相浅描边，亮图使用同色相深描边。
        // 描边与数字本体保持一档明度差，使约 5px 的外圈既能衬托字形，也不会脱离
        // 壁纸种子色与用户选择的 Material You 方案。
        let lightPrimaryOutline = perceptualTone(of: seed, lightness: 0.98,
                                                 chroma: accent1Chroma * 0.38,
                                                 hueOffset: primaryHueOffset)
        let lightSecondaryOutline = perceptualTone(of: seed, lightness: 0.94,
                                                   chroma: accent2Chroma * 0.48,
                                                   hueOffset: secondaryHueOffset)
        let darkPrimaryOutline = perceptualTone(of: seed, lightness: 0.14,
                                                chroma: accent1Chroma * 0.56,
                                                hueOffset: primaryHueOffset)
        let darkSecondaryOutline = perceptualTone(of: seed, lightness: 0.20,
                                                  chroma: accent2Chroma * 0.62,
                                                  hueOffset: secondaryHueOffset)
        let lightScore = contrastRatio(lightPrimary, background: background)
            + contrastRatio(lightSecondary, background: background) * 0.35
        let darkScore = contrastRatio(darkPrimary, background: background)
            + contrastRatio(darkSecondary, background: background) * 0.35
        if lightScore >= darkScore {
            return (lightPrimary, lightSecondary,
                    lightPrimaryOutline, lightSecondaryOutline, true)
        }
        return (darkPrimary, darkSecondary,
                darkPrimaryOutline, darkSecondaryOutline, false)
    }

    /// 兼容既有调用：强调色取同一 Material You 色调阶中的次级色。
    public static func wallpaperAccentColor(of image: CGImage) -> (CGFloat, CGFloat, CGFloat) {
        wallpaperClockColors(of: image).secondary
    }

    /// 与整图求平均不同，按色相聚类并优先选择占比高、色度清晰且不过曝的种子色，
    /// 避免多色照片被平均成灰褐色；低饱和图片则自然回退为中性色调阶。
    @inline(never)
    private static func artworkSeedColors(
        of image: CGImage
    ) -> (primary: (CGFloat, CGFloat, CGFloat), secondary: (CGFloat, CGFloat, CGFloat)) {
        let size = 32
        guard let ctx = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else {
            let fallback = dominantColor(of: image)
            return (fallback, fallback)
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        struct Bucket {
            var score: CGFloat = 0
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
        }
        var buckets = Array(repeating: Bucket(), count: 12)
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        for index in 0..<(size * size) {
            let offset = index * 4
            guard ptr[offset + 3] >= 200 else { continue }
            let r = CGFloat(ptr[offset]) / 255
            let g = CGFloat(ptr[offset + 1]) / 255
            let b = CGFloat(ptr[offset + 2]) / 255
            let maximum = max(r, g, b)
            let minimum = min(r, g, b)
            let chroma = maximum - minimum
            let saturation = maximum > 0.001 ? chroma / maximum : 0
            guard chroma > 0.035, saturation > 0.10 else { continue }

            let hue: CGFloat
            if maximum == r {
                hue = ((g - b) / chroma).truncatingRemainder(dividingBy: 6) / 6
            } else if maximum == g {
                hue = ((b - r) / chroma + 2) / 6
            } else {
                hue = ((r - g) / chroma + 4) / 6
            }
            let normalizedHue = hue < 0 ? hue + 1 : hue
            let bucketIndex = min(Int(normalizedHue * 12), 11)
            let luminance = 0.299 * r + 0.587 * g + 0.114 * b
            let exposureWeight = max(0.28, 1 - abs(luminance - 0.5) * 1.25)
            let weight = (0.32 + saturation * 1.68) * exposureWeight
            buckets[bucketIndex].score += weight
            buckets[bucketIndex].red += r * weight
            buckets[bucketIndex].green += g * weight
            buckets[bucketIndex].blue += b * weight
        }

        let ranked = buckets.enumerated()
            .filter { $0.element.score > 0 }
            .sorted { $0.element.score > $1.element.score }
        guard let winner = ranked.first else {
            let fallback = dominantColor(of: image)
            return (fallback, fallback)
        }
        func color(_ bucket: Bucket) -> (CGFloat, CGFloat, CGFloat) {
            (bucket.red / bucket.score,
             bucket.green / bucket.score,
             bucket.blue / bucket.score)
        }
        // 第二道光晕不只按占比排序：用“实际占比 × 与主色的色相距离”选择，
        // 让封面中面积较小但鲜明的颜色也能被保留，而不是总被大面积近似色吞掉。
        var secondary = winner
        var bestCollisionScore: CGFloat = -1
        for candidate in ranked.dropFirst() {
            let bucketDistance = abs(candidate.offset - winner.offset)
            let normalizedDistance = CGFloat(min(bucketDistance,
                buckets.count - bucketDistance)) / CGFloat(buckets.count / 2)
            let share = candidate.element.score / max(winner.element.score, 0.001)
            let score = min(share, 1) * (0.35 + normalizedDistance * 1.65)
            if score > bestCollisionScore {
                bestCollisionScore = score
                secondary = candidate
            }
        }
        return (color(winner.element), color(secondary.element))
    }

    private static func wallpaperSeedColor(of image: CGImage) -> (CGFloat, CGFloat, CGFloat) {
        artworkSeedColors(of: image).primary
    }

    private struct OKLCHColor {
        var lightness: Double
        var chroma: Double
        var hue: Double
    }

    private static func perceptualTone(
        of rgb: (CGFloat, CGFloat, CGFloat), lightness: Double, chroma: Double,
        hueOffset: Double = 0
    ) -> (CGFloat, CGFloat, CGFloat) {
        let source = rgbToOKLCH(rgb)
        // 极亮/极暗端会在转回 sRGB 时自动压缩色度以入色域。
        return oklchToRGB(OKLCHColor(lightness: lightness, chroma: chroma,
                                    hue: source.hue + hueOffset))
    }

    private static func rgbToOKLCH(_ rgb: (CGFloat, CGFloat, CGFloat)) -> OKLCHColor {
        let r = srgbToLinear(Double(rgb.0))
        let g = srgbToLinear(Double(rgb.1))
        let b = srgbToLinear(Double(rgb.2))
        let l = 0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b
        let m = 0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b
        let s = 0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b
        let lRoot = cbrt(l)
        let mRoot = cbrt(m)
        let sRoot = cbrt(s)
        let lightness = 0.210_454_255_3 * lRoot + 0.793_617_785 * mRoot
            - 0.004_072_046_8 * sRoot
        let a = 1.977_998_495_1 * lRoot - 2.428_592_205 * mRoot
            + 0.450_593_709_9 * sRoot
        let labB = 0.025_904_037_1 * lRoot + 0.782_771_766_2 * mRoot
            - 0.808_675_766 * sRoot
        return OKLCHColor(lightness: lightness,
                          chroma: hypot(a, labB),
                          hue: atan2(labB, a))
    }

    private static func oklchToRGB(_ color: OKLCHColor) -> (CGFloat, CGFloat, CGFloat) {
        var chroma = color.chroma
        for _ in 0..<18 {
            let a = chroma * cos(color.hue)
            let b = chroma * sin(color.hue)
            let lRoot = color.lightness + 0.396_337_777_4 * a + 0.215_803_757_3 * b
            let mRoot = color.lightness - 0.105_561_345_8 * a - 0.063_854_172_8 * b
            let sRoot = color.lightness - 0.089_484_177_5 * a - 1.291_485_548 * b
            let l = lRoot * lRoot * lRoot
            let m = mRoot * mRoot * mRoot
            let s = sRoot * sRoot * sRoot
            let redLinear = 4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s
            let greenLinear = -1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s
            let blueLinear = -0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701 * s
            if redLinear >= 0, redLinear <= 1,
               greenLinear >= 0, greenLinear <= 1,
               blueLinear >= 0, blueLinear <= 1 {
                return (CGFloat(linearToSRGB(redLinear)),
                        CGFloat(linearToSRGB(greenLinear)),
                        CGFloat(linearToSRGB(blueLinear)))
            }
            chroma *= 0.84
        }
        let neutral = CGFloat(linearToSRGB(pow(color.lightness, 3)))
        return (neutral, neutral, neutral)
    }

    private static func srgbToLinear(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ component: Double) -> Double {
        component <= 0.0031308
            ? component * 12.92
            : 1.055 * pow(component, 1 / 2.4) - 0.055
    }

    private static func relativeLuminance(_ rgb: (CGFloat, CGFloat, CGFloat)) -> Double {
        0.2126 * srgbToLinear(Double(rgb.0))
            + 0.7152 * srgbToLinear(Double(rgb.1))
            + 0.0722 * srgbToLinear(Double(rgb.2))
    }

    private static func contrastRatio(
        _ foreground: (CGFloat, CGFloat, CGFloat),
        background: (CGFloat, CGFloat, CGFloat)
    ) -> Double {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// 从封面种子色生成适合小字的可读色。优先保留色相与色度，
    /// 在 OKLCH 中逐档调整明度，直到与实际背景达到 WCAG AA 小文字对比度。
    @inline(never)
    public static func artworkReadableAccent(
        background: (CGFloat, CGFloat, CGFloat),
        seed: (CGFloat, CGFloat, CGFloat)
    ) -> (CGFloat, CGFloat, CGFloat) {
        let source = rgbToOKLCH(seed)
        let chroma = max(min(source.chroma, 0.17), source.chroma >= 0.02 ? 0.055 : 0)
        let lightSteps: [Double] = [0.84, 0.88, 0.92, 0.96, 0.99]
        let darkSteps: [Double] = [0.28, 0.24, 0.20, 0.16, 0.10]
        let preferred = relativeLuminance(background) < 0.36 ? lightSteps : darkSteps
        var best = perceptualTone(of: seed, lightness: preferred[0], chroma: chroma)
        var bestContrast = contrastRatio(best, background: background)
        for lightness in preferred.dropFirst() {
            let candidate = perceptualTone(of: seed, lightness: lightness, chroma: chroma)
            let contrast = contrastRatio(candidate, background: background)
            if contrast > bestContrast {
                best = candidate
                bestContrast = contrast
            }
            if contrast >= 4.5 { return candidate }
        }
        if bestContrast >= 4.5 { return best }
        let neutral: (CGFloat, CGFloat, CGFloat) = relativeLuminance(background) < 0.36
            ? (0.98, 0.98, 0.98) : (0.08, 0.08, 0.08)
        return contrastRatio(neutral, background: background) > bestContrast ? neutral : best
    }

    /// 从同一张封面分别提取主/次种子色，再生成适合玻璃背景的两道强调色。
    /// 封面中有真实异色时优先保留；近似单色时则从封面主种子派生一道
    /// 错开约 78° 的协调色，在不混入应用主题色的前提下增加色彩碰撞。
    @inline(never)
    public static func artworkGlassAccents(
        of image: CGImage
    ) -> (primary: (CGFloat, CGFloat, CGFloat), secondary: (CGFloat, CGFloat, CGFloat)) {
        let base = dominantColor(of: image)
        let seeds = artworkSeedColors(of: image)
        let darkBackground = relativeLuminance(base) < 0.5
        let primarySource = rgbToOKLCH(seeds.primary)
        let secondarySource = rgbToOKLCH(seeds.secondary)
        let rawHueDistance = abs(primarySource.hue - secondarySource.hue)
            .truncatingRemainder(dividingBy: Double.pi * 2)
        let hueDistance = min(rawHueDistance, Double.pi * 2 - rawHueDistance)
        let hasDistinctSampledHue = primarySource.chroma >= 0.018
            && secondarySource.chroma >= 0.025
            && hueDistance >= Double.pi / 4
        let primaryChroma = primarySource.chroma >= 0.018
            ? max(min(primarySource.chroma * 1.16, 0.22), 0.085)
            : min(primarySource.chroma, 0.025)
        let primary = perceptualTone(
            of: seeds.primary,
            lightness: darkBackground ? 0.82 : 0.28,
            chroma: primaryChroma)
        let secondarySeed = hasDistinctSampledHue ? seeds.secondary : seeds.primary
        let secondaryChroma: Double
        if primarySource.chroma < 0.018 {
            secondaryChroma = min(max(secondarySource.chroma, 0), 0.035)
        } else if hasDistinctSampledHue {
            secondaryChroma = max(min(secondarySource.chroma * 1.24, 0.21), 0.10)
        } else {
            secondaryChroma = max(min(primarySource.chroma * 1.08, 0.19), 0.10)
        }
        var secondary = perceptualTone(
            of: secondarySeed,
            lightness: darkBackground ? 0.68 : 0.40,
            chroma: secondaryChroma,
            hueOffset: hasDistinctSampledHue ? 0 : Double.pi * 13 / 30)
        let distance = abs(primary.0 - secondary.0)
            + abs(primary.1 - secondary.1) + abs(primary.2 - secondary.2)
        if distance < 0.28, primarySource.chroma >= 0.018 {
            secondary = perceptualTone(
                of: seeds.primary,
                lightness: darkBackground ? 0.66 : 0.42,
                chroma: max(min(primarySource.chroma * 1.12, 0.20), 0.11),
                hueOffset: Double.pi * 5 / 9)
        }
        return (primary, secondary)
    }

    /// 保留用户选定的背景、文字和容器颜色，仅用封面替换两道强调色。
    /// 用于彩色多模块画板：关闭“智能封面背景”时也能获得封面光晕，
    /// 但不会擅自改变用户的主题底色。
    public static func applyingArtworkAccents(to palette: ScreenPalette,
                                              artwork image: CGImage) -> ScreenPalette {
        let accents = artworkGlassAccents(of: image)
        var result = palette
        result.accent = accents.primary
        result.secondaryAccent = accents.secondary
        return result
    }

    /// 有原始封面时使用此入口，Liquid Glass 的两种强调色都来自封面采样。
    public static func artworkPalette(of image: CGImage,
                                      themeAccent: (CGFloat, CGFloat, CGFloat)) -> ScreenPalette {
        let accents = artworkGlassAccents(of: image)
        return artworkPalette(baseColor: dominantColor(of: image),
                              accent: accents.primary,
                              secondaryAccent: accents.secondary)
    }

    /// 只保留主色的兼容入口；两道强调色仍从主色衍生，不再混入主题强调色。
    public static func artworkPalette(baseColor: (CGFloat, CGFloat, CGFloat),
                                      themeAccent: (CGFloat, CGFloat, CGFloat)) -> ScreenPalette {
        let darkBackground = relativeLuminance(baseColor) < 0.5
        let source = rgbToOKLCH(baseColor)
        let chroma = max(min(source.chroma, 0.18), 0.025)
        return artworkPalette(
            baseColor: baseColor,
            accent: perceptualTone(of: baseColor,
                                   lightness: darkBackground ? 0.80 : 0.30,
                                   chroma: chroma),
            secondaryAccent: perceptualTone(of: baseColor,
                                            lightness: darkBackground ? 0.60 : 0.48,
                                            chroma: max(chroma * 0.72, 0.02)))
    }

    private static func artworkPalette(
        baseColor: (CGFloat, CGFloat, CGFloat),
        accent: (CGFloat, CGFloat, CGFloat),
        secondaryAccent: (CGFloat, CGFloat, CGFloat)
    ) -> ScreenPalette {
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
            accent: accent,
            secondaryAccent: secondaryAccent,
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

    /// 键盘卡片几何（供实时预览把渲染画面对齐到设备屏幕区）：
    /// 卡片左右与底部内缩 9pt、顶部内缩 9pt（另加安全区），圆角 13pt
    public static let cardInset: CGFloat = 9
    public static let cardRadius: CGFloat = 13

    /// 卡片中心相对画布中心的纵向偏移（Skia 语义，向下为正）：
    /// 顶部有安全区、底部只留 9pt，因此卡片中心略低于画布中心
    public static func cardCenterOffsetY(safeArea: Int) -> CGFloat {
        let safe = clampSafeArea(safeArea)
        let top = safe + 1
        let bottom = CGFloat(height) - cardInset
        return (top + bottom) / 2 - CGFloat(height) / 2
    }

    /// 绘制背景与卡片（Skia 语义坐标：origin 在屏幕左上，y 向下）
    private static func drawCanvas(_ ctx: CGContext, safeArea: CGFloat, colors: ScreenPalette) -> CGRect {
        if !ColorCardSceneCapture.background(ctx, palette: colors) {
            ctx.setFillColor(colors.backgroundCG)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
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
        // A scoped glass export still needs the foreground image, but encodes
        // only the final SwiftUI composition, not this temporary transparent layer.
        if ColorCardSceneCapture.isCapturing(ctx) {
            return RenderResult(data: Data(), image: image)
        }
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
        if ColorCardSceneCapture.panel(ctx, bounds: bounds, radius: radius, color: color) { return }
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func strokeRound(_ ctx: CGContext, _ bounds: CGRect, radius: CGFloat, color: CGColor, width: CGFloat) {
        if ColorCardSceneCapture.suppressStroke(ctx, bounds: bounds) { return }
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
                                   dotColor: CGColor? = nil, badgeSize: CGFloat = 6) {
        let center = CGPoint(x: card.minX + 13.5, y: CGFloat(height) - (card.minY + 18.5))
        ctx.setFillColor(dotColor ?? accent)
        ctx.fillEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
        drawText(ctx, title, size: titleSize, bold: true, color: colors.primaryTextCG,
                 in: rect(card.minX + 22, card.minY + 8, 62, 25), align: .left)
        // 徽标右对齐（右缘距卡片 10pt），绘制区宽度按实际文字自适应，放大字号时不截断
        let badgeW = max(33, measureTextWidth(badge, size: badgeSize, bold: true) + 2)
        drawText(ctx, badge, size: badgeSize, bold: true, color: accent,
                 in: rect(card.maxX - 10 - badgeW, card.minY + 10, badgeW, 20), align: .right)
    }

    /// Bambu 键盘独立卡片头部：设备名是主信息，品牌名退居辅助行。
    /// 设备名会在 11–7pt 之间自动收缩，仍过长时由 drawText 统一加省略号。
    private static func drawBambuHeader(_ ctx: CGContext, card: CGRect, deviceName: String,
                                        accent: CGColor, colors: ScreenPalette) {
        let center = CGPoint(x: card.minX + 13.5, y: CGFloat(height) - (card.minY + 18.5))
        ctx.setFillColor(accent)
        ctx.fillEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))

        let textX = card.minX + 22
        let textW = card.maxX - textX - 9
        var nameSize: CGFloat = 11
        while nameSize > 7 && measureTextWidth(deviceName, size: nameSize, bold: true) > textW {
            nameSize -= 0.5
        }
        drawText(ctx, deviceName, size: nameSize, bold: true, color: colors.primaryTextCG,
                 in: rect(textX, card.minY + 4, textW, 20), align: .left)
        drawText(ctx, "BAMBU LAB", size: 5.5, bold: true, color: accent,
                 in: rect(textX, card.minY + 22, textW, 10), align: .left)
    }

    /// Formlabs 独立卡片标头：与 Bambu 使用相同几何，设备名与
    /// Dashboard 拆成两行，第二行放大并单独着强调色。
    private static func drawFormlabsHeader(_ ctx: CGContext, card: CGRect, deviceName: String,
                                           accent: CGColor, colors: ScreenPalette) {
        let center = CGPoint(x: card.minX + 13.5,
                             y: CGFloat(height) - (card.minY + 18.5))
        ctx.setFillColor(accent)
        ctx.fillEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5,
                                   width: 7, height: 7))
        let textX = card.minX + 22
        let textW = card.maxX - textX - 9
        var nameSize: CGFloat = 11
        while nameSize > 7 && measureTextWidth(deviceName, size: nameSize, bold: true) > textW {
            nameSize -= 0.5
        }
        drawText(ctx, deviceName, size: nameSize, bold: true, color: colors.primaryTextCG,
                 in: rect(textX, card.minY + 4, textW, 20), align: .left)
        drawText(ctx, "Dashboard", size: 8, bold: true, color: accent,
                 in: rect(textX, card.minY + 21, textW, 12), align: .left)
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
                                 fontName: String? = nil,
                                 strokeWidth: CGFloat? = nil,
                                 strokeColor: CGColor? = nil) {
        let resolvedFont = fontName ?? (bold ? "PingFangSC-Semibold" : "PingFangSC-Regular")
        let font = CTFontCreateWithName(resolvedFont as CFString, size, nil)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let strokeWidth, strokeWidth > 0 {
            // CoreText 使用字体大小百分比表示描边宽度；负值代表同时绘制填充与描边。
            attributes[.strokeWidth] = -strokeWidth
            attributes[.strokeColor] = strokeColor ?? color
        }
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

    /// 按文字实际可见字形边界垂直居中。用于高度固定的胶囊/标签框；普通文本仍使用
    /// drawText 的字体度量居中，以保持已有页面的整体基线节奏。
    private static func drawGlyphCenteredText(_ ctx: CGContext, _ text: String,
                                              size: CGFloat, bold: Bool,
                                              color: CGColor, in bounds: CGRect,
                                              align: NSTextAlignment) {
        let fontName = bold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color
        ]
        var content = text
        while content.count > 1,
              measureTextWidth(content, size: size, bold: bold) > bounds.width {
            content.removeLast()
        }
        if content != text {
            while content.count > 1,
                  measureTextWidth(content + "…", size: size, bold: bold) > bounds.width {
                content.removeLast()
            }
            content += "…"
        }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: content, attributes: attributes))
        let glyphBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let visibleWidth = max(glyphBounds.width, 0)
        let x: CGFloat
        switch align {
        case .left: x = bounds.minX - glyphBounds.minX
        case .right: x = bounds.maxX - visibleWidth - glyphBounds.minX
        default: x = bounds.midX - visibleWidth / 2 - glyphBounds.minX
        }
        let baselineY = bounds.midY - glyphBounds.midY
        ctx.textPosition = CGPoint(x: x, y: baselineY)
        CTLineDraw(line, ctx)
    }

    /// Bambu 大字进度使用同一条 CoreText 基线绘制两端对齐的不同字号：
    /// 大号数字靠左、小号百分号靠右，缩小后仍不会上下漂移。
    private static func drawBambuProgressLabel(_ ctx: CGContext, number: String,
                                               numberSize: CGFloat, percentSize: CGFloat,
                                               numberColor: CGColor, percentColor: CGColor,
                                               in bounds: CGRect) {
        let numberFont = CTFontCreateWithName("PingFangSC-Semibold" as CFString, numberSize, nil)
        let percentFont = CTFontCreateWithName("PingFangSC-Semibold" as CFString, percentSize, nil)
        let numberLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: number,
            attributes: [.font: numberFont, .foregroundColor: numberColor]
        ))
        let percentLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: "%",
            attributes: [.font: percentFont, .foregroundColor: percentColor]
        ))
        var numberAscent: CGFloat = 0
        var numberDescent: CGFloat = 0
        _ = CTLineGetTypographicBounds(numberLine, &numberAscent, &numberDescent, nil)
        var percentAscent: CGFloat = 0
        var percentDescent: CGFloat = 0
        let percentWidth = CGFloat(CTLineGetTypographicBounds(
            percentLine, &percentAscent, &percentDescent, nil))
        let ascent = max(numberAscent, percentAscent)
        let descent = max(numberDescent, percentDescent)
        let baselineY = bounds.midY - (ascent + descent) / 2
        ctx.textPosition = CGPoint(x: bounds.minX, y: baselineY)
        CTLineDraw(numberLine, ctx)
        ctx.textPosition = CGPoint(x: bounds.maxX - percentWidth, y: baselineY)
        CTLineDraw(percentLine, ctx)
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

    /// 自定义字体版本的自适应字号，用于图片上的全局时钟叠加。
    private static func adaptiveFontSize(_ text: String, maxSize: CGFloat, minSize: CGFloat,
                                         fontName: String, maxWidth: CGFloat) -> CGFloat {
        var size = maxSize
        while size > minSize,
              measureTextWidth(text, fontName: fontName, size: size) > maxWidth {
            size -= 0.5
        }
        return max(size, minSize)
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

    // MARK: - Grok Bot / Cloudflare

    public static func renderGrokBot(_ snapshot: GrokBotUsageSnapshot, settings: AppSettings,
                                     now: Date = Date()) throws -> RenderResult {
        let colors = settings.resolvedPalette
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let c = drawCanvas(ctx, safeArea: safe, colors: colors)
        drawHeader(ctx, card: c, title: "GROK", badge: "每周",
                   accent: colors.accentCG, colors: colors)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)
        let body = CGRect(x: c.minX + 8, y: c.minY + 46,
                          width: c.width - 16, height: max(c.maxY - (c.minY + 54), 40))
        drawGrokBotBody(ctx, snapshot: snapshot, in: body, colors: colors,
                        accent: colors.accentCG, now: now)
        return try encode(ctx, quality: settings.jpegQuality)
    }

    public static func renderCloudflare(_ snapshot: CloudflareUsageSnapshot, settings: AppSettings,
                                        now: Date = Date()) throws -> RenderResult {
        let colors = settings.resolvedPalette
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        let c = drawCanvas(ctx, safeArea: safe, colors: colors)
        let badge = "今日"
        let badgeSize: CGFloat = 8
        let badgeW = max(33, measureTextWidth(badge, size: badgeSize, bold: true) + 2)
        let title = "CF 数据"
        let titleX = c.minX + 22
        let titleW = max(c.maxX - 10 - badgeW - titleX - 4, 36)
        let dot = CGPoint(x: c.minX + 13.5, y: CGFloat(height) - (c.minY + 18.5))
        ctx.setFillColor(colors.accentCG)
        ctx.fillEllipse(in: CGRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7))
        drawAdaptiveText(ctx, title, maxSize: 8.5, minSize: 6, bold: true,
                         color: colors.primaryTextCG,
                         in: rect(titleX, c.minY + 8, titleW, 22), align: .left)
        drawText(ctx, badge, size: badgeSize, bold: true, color: colors.accentCG,
                 in: rect(c.maxX - 10 - badgeW, c.minY + 10, badgeW, 20), align: .right)
        drawLine(ctx, x1: c.minX + 9, y1: c.minY + 38, x2: c.maxX - 9, y2: c.minY + 38,
                 color: colors.borderCG)
        let body = CGRect(x: c.minX + 8, y: c.minY + 46,
                          width: c.width - 16, height: max(c.maxY - (c.minY + 54), 40))
        drawCloudflareBody(ctx, snapshot: snapshot, in: body, colors: colors,
                           accent: colors.accentCG, now: now)
        return try encode(ctx, quality: settings.jpegQuality)
    }

    private static func drawGrokBotModule(_ ctx: CGContext, band: CGRect,
                                          snapshot: GrokBotUsageSnapshot, colors: ScreenPalette,
                                          accent: CGColor, now: Date,
                                          deviceCanvas: Bool, monochromeDeviceCanvas: Bool) {
        if deviceCanvas, !monochromeDeviceCanvas, band.width >= 180, band.height >= 180 {
            drawSquareGrokBot(ctx, band: band, snapshot: snapshot, accent: accent,
                              colors: colors, now: now)
            return
        }
        if band.height >= 130 {
            drawGrokBotBody(ctx, snapshot: snapshot, in: band.insetBy(dx: 4, dy: 2),
                            colors: colors, accent: accent, now: now)
            return
        }
        if snapshot.isAvailable, let remaining = snapshot.remainingPercent {
            drawQuotaBand(ctx, band: band, label: "Grok", value: "\(remaining)%",
                          progress: Double(remaining) / 100, accent: accent, colors: colors)
        } else {
            drawWrapped(ctx, snapshot.message.isEmpty ? "尚未读取" : snapshot.message,
                        maxSize: 11, minSize: 7, bold: true, color: colors.primaryTextCG,
                        in: band.insetBy(dx: 4, dy: 2), maxLines: 3, align: .center)
        }
    }

    private static func drawCloudflareModule(_ ctx: CGContext, band: CGRect,
                                             snapshot: CloudflareUsageSnapshot, colors: ScreenPalette,
                                             accent: CGColor, now: Date,
                                             deviceCanvas: Bool, monochromeDeviceCanvas: Bool) {
        if deviceCanvas, !monochromeDeviceCanvas, band.width >= 180, band.height >= 180 {
            drawSquareCloudflare(ctx, band: band, snapshot: snapshot, accent: accent,
                                 colors: colors, now: now)
            return
        }
        if band.height >= 130 {
            drawCloudflareBody(ctx, snapshot: snapshot, in: band.insetBy(dx: 4, dy: 2),
                               colors: colors, accent: accent, now: now)
            return
        }
        let value = snapshot.showsMetrics ? snapshot.heroText : "—"
        drawQuotaBand(ctx, band: band, label: "请求", value: value,
                      progress: 0, accent: accent, colors: colors)
    }

    private static func drawGrokBotBody(_ ctx: CGContext, snapshot: GrokBotUsageSnapshot,
                                        in area: CGRect, colors: ScreenPalette,
                                        accent: CGColor, now: Date) {
        guard area.width > 20, area.height > 24 else { return }
        let captionH: CGFloat = area.height >= 150 ? 18 : 0
        if captionH > 0 {
            drawText(ctx, "本周剩余", size: 10, bold: true, color: colors.secondaryTextCG,
                     in: rect(area.minX, area.minY, area.width, captionH), align: .center)
        }
        let heroH = min(max(area.height * 0.28, 36), 78)
        let hero = CGRect(x: area.minX, y: area.minY + captionH, width: area.width, height: heroH)
        if snapshot.isAvailable, let remaining = snapshot.remainingPercent {
            let heroText = "\(remaining)%"
            drawAdaptiveText(ctx, heroText, maxSize: min(heroH * 0.72, 40), minSize: 16,
                             bold: true, color: colors.primaryTextCG, in: rect(hero), align: .center)
            let barY = hero.maxY + 2
            if area.maxY - barY > 28 {
                drawProgress(ctx, rect(area.minX + 4, barY, area.width - 8, 7),
                             progress: Double(remaining) / 100, accent: accent, background: colors.borderCG)
            }
        } else {
            drawAdaptiveText(ctx, "—", maxSize: min(heroH * 0.7, 36), minSize: 18,
                             bold: true, color: colors.primaryTextCG,
                             in: rect(hero.minX, hero.minY, hero.width, hero.height * 0.62), align: .center)
            drawWrapped(ctx, snapshot.message.isEmpty ? "尚未读取" : snapshot.message,
                        maxSize: 10, minSize: 7, bold: false, color: colors.secondaryTextCG,
                        in: CGRect(x: hero.minX, y: hero.minY + hero.height * 0.58,
                                   width: hero.width, height: hero.height * 0.42),
                        maxLines: 2, align: .center)
        }
        var rows: [(String, String)] = []
        rows.append(("套餐", snapshot.planLabel ?? "—"))
        if let reset = snapshot.resetDate {
            rows.append(("重置", formatDate(reset, "M/d HH:mm")))
        } else if snapshot.isAvailable {
            rows.append(("重置", "未提供"))
        }
        if let banked = snapshot.availableBankedResetCount {
            rows.append(("可用重置", "\(banked) 次"))
        }
        let rowsTop = hero.maxY + (snapshot.isAvailable ? 16 : 6)
        let footH: CGFloat = area.height >= 170 ? 16 : 0
        let rowsRect = CGRect(x: area.minX, y: rowsTop, width: area.width,
                              height: max(area.maxY - rowsTop - footH, 0))
        if rowsRect.height >= 18 {
            drawMetricRows(ctx, rows: rows, in: rowsRect, colors: colors, accent: accent)
        }
        if footH > 0 {
            let stamp = snapshot.sampledAt ?? now
            drawAdaptiveText(ctx, "采样 \(formatDate(stamp, "HH:mm"))",
                             maxSize: 8, minSize: 6, bold: false, color: colors.tertiaryTextCG,
                             in: rect(area.minX, area.maxY - footH, area.width, footH), align: .center)
        }
    }

    private static func drawCloudflareBody(_ ctx: CGContext, snapshot: CloudflareUsageSnapshot,
                                           in area: CGRect, colors: ScreenPalette,
                                           accent: CGColor, now: Date) {
        guard area.width > 20, area.height > 24 else { return }
        let captionH: CGFloat = area.height >= 140 ? 16 : 0
        if captionH > 0 {
            let caption = snapshot.accountName.map { "\($0) · \(CloudflareUsageSnapshot.windowLabel)" }
                ?? CloudflareUsageSnapshot.windowLabel
            drawAdaptiveText(ctx, caption, maxSize: 9, minSize: 7, bold: true,
                             color: colors.secondaryTextCG,
                             in: rect(area.minX, area.minY, area.width, captionH), align: .center)
        }
        let heroH = min(max(area.height * 0.24, 32), 70)
        let hero = CGRect(x: area.minX, y: area.minY + captionH, width: area.width, height: heroH)
        drawText(ctx, "请求", size: 9, bold: false, color: colors.tertiaryTextCG,
                 in: rect(hero.minX, hero.minY, hero.width, 14), align: .center)
        let heroValue = snapshot.showsMetrics ? snapshot.heroText : "—"
        drawAdaptiveText(ctx, heroValue, maxSize: min(heroH * 0.62, 34), minSize: 14,
                         bold: true, color: colors.primaryTextCG,
                         in: rect(hero.minX, hero.minY + 14, hero.width, hero.height - 14), align: .center)
        if !snapshot.showsMetrics {
            drawWrapped(ctx, snapshot.message.isEmpty ? "尚未读取" : snapshot.message,
                        maxSize: 9, minSize: 7, bold: false, color: colors.secondaryTextCG,
                        in: CGRect(x: area.minX, y: hero.maxY, width: area.width, height: 28),
                        maxLines: 2, align: .center)
        }
        let noteH: CGFloat = area.height >= 160 ? 28 : 14
        let rowsTop = hero.maxY + (snapshot.showsMetrics ? 6 : 30)
        let rowsRect = CGRect(x: area.minX, y: rowsTop, width: area.width,
                              height: max(area.maxY - rowsTop - noteH - 2, 18))
        drawMetricRows(ctx, rows: snapshot.metricRows, in: rowsRect, colors: colors, accent: accent)
        let zone = snapshot.zoneCount.map { "\($0) 个站点" } ?? "站点 —"
        let stamp = snapshot.sampledAt.map { formatDate($0, "HH:mm") } ?? formatDate(now, "HH:mm")
        let note = snapshot.showsMetrics
            ? "\(zone) · \(stamp) · 观测用量"
            : "\(zone) · 观测用量，不是套餐剩余"
        drawWrapped(ctx, note, maxSize: 8, minSize: 6, bold: false, color: colors.tertiaryTextCG,
                    in: CGRect(x: area.minX, y: area.maxY - noteH, width: area.width, height: noteH),
                    maxLines: area.height >= 160 ? 2 : 1, align: .center)
    }

    private static func drawSquareGrokBot(_ ctx: CGContext, band: CGRect,
                                          snapshot: GrokBotUsageSnapshot, accent: CGColor,
                                          colors: ScreenPalette, now: Date) {
        let inner = band.insetBy(dx: 6, dy: 5)
        fillRound(ctx, rect(inner), radius: 12, color: colors.insetCG)
        strokeRound(ctx, rect(inner), radius: 12, color: colors.borderCG, width: 1)
        drawText(ctx, "GROK BOT", size: 16, bold: true, color: colors.primaryTextCG,
                 in: rect(inner.minX + 11, inner.minY + 8, 110, 23), align: .left)
        drawAdaptiveText(ctx, "每周", maxSize: 10, minSize: 8, bold: true, color: accent,
                         in: rect(inner.maxX - 58, inner.minY + 9, 46, 21), align: .right)
        drawLine(ctx, x1: inner.minX + 10, y1: inner.minY + 35,
                 x2: inner.maxX - 10, y2: inner.minY + 35, color: colors.borderCG)
        let body = CGRect(x: inner.minX + 8, y: inner.minY + 40,
                          width: inner.width - 16, height: inner.height - 48)
        drawGrokBotBody(ctx, snapshot: snapshot, in: body, colors: colors, accent: accent, now: now)
    }

    private static func drawSquareCloudflare(_ ctx: CGContext, band: CGRect,
                                             snapshot: CloudflareUsageSnapshot, accent: CGColor,
                                             colors: ScreenPalette, now: Date) {
        let inner = band.insetBy(dx: 6, dy: 5)
        fillRound(ctx, rect(inner), radius: 12, color: colors.insetCG)
        strokeRound(ctx, rect(inner), radius: 12, color: colors.borderCG, width: 1)
        drawText(ctx, "CLOUDFLARE", size: 15, bold: true, color: colors.primaryTextCG,
                 in: rect(inner.minX + 11, inner.minY + 8, inner.width - 78, 23), align: .left)
        drawAdaptiveText(ctx, "今日", maxSize: 10, minSize: 8, bold: true, color: accent,
                         in: rect(inner.maxX - 52, inner.minY + 9, 40, 21), align: .right)
        drawLine(ctx, x1: inner.minX + 10, y1: inner.minY + 35,
                 x2: inner.maxX - 10, y2: inner.minY + 35, color: colors.borderCG)
        let body = CGRect(x: inner.minX + 8, y: inner.minY + 40,
                          width: inner.width - 16, height: inner.height - 48)
        drawCloudflareBody(ctx, snapshot: snapshot, in: body, colors: colors, accent: accent, now: now)
    }

    private static func drawMetricRows(_ ctx: CGContext, rows: [(String, String)],
                                       in area: CGRect, colors: ScreenPalette, accent: CGColor) {
        guard !rows.isEmpty, area.height > 8, area.width > 16 else { return }
        let gap: CGFloat = area.height > 120 ? 4 : 2
        let rowH = max((area.height - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count), 14)
        var y = area.minY
        for (label, value) in rows {
            if y + 12 > area.maxY { break }
            let height = min(rowH, area.maxY - y)
            let labelW = min(max(area.width * 0.42, 36), area.width * 0.5)
            let valueX = area.minX + labelW + 4
            let valueW = max(area.maxX - valueX, 20)
            drawAdaptiveText(ctx, label, maxSize: min(height * 0.46, 12), minSize: 7,
                             bold: false, color: colors.secondaryTextCG,
                             in: rect(area.minX, y, labelW, height), align: .left)
            drawAdaptiveText(ctx, value, maxSize: min(height * 0.55, 15), minSize: 8,
                             bold: true, color: value == "无权限" ? colors.tertiaryTextCG : accent,
                             in: rect(valueX, y, valueW, height), align: .right)
            y += height + gap
        }
    }

    private static func drawWrapped(_ ctx: CGContext, _ text: String, maxSize: CGFloat, minSize: CGFloat,
                                    bold: Bool, color: CGColor, in area: CGRect, maxLines: Int,
                                    align: NSTextAlignment) {
        guard area.width > 8, area.height > 8, maxLines > 0 else { return }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        var size = maxSize
        var lines = wrapText(cleaned, maxWidth: area.width, size: size, bold: bold)
        while size > minSize, lines.count > maxLines {
            size -= 0.5
            lines = wrapText(cleaned, maxWidth: area.width, size: size, bold: bold)
        }
        let overflow = lines.count > maxLines
        lines = Array(lines.prefix(maxLines))
        if overflow, var last = lines.last {
            if !last.hasSuffix("…") { last += "…" }
            lines[lines.count - 1] = last
        }
        let lineH = min(area.height / CGFloat(lines.count), size * 1.3)
        for (index, line) in lines.enumerated() {
            drawText(ctx, line, size: size, bold: bold, color: color,
                     in: rect(area.minX, area.minY + CGFloat(index) * lineH, area.width, lineH),
                     align: align)
        }
    }
}
