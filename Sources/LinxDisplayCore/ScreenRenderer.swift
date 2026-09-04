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
                                    sspaiArticles: [SspaiArticle] = [],
                                    ha: HASnapshot = .empty,
                                    now: Date = Date(),
                                    palette: ScreenPalette? = nil,
                                    printerFields: [Int: CanvasPrinterFields] = [:],
                                    artworkImage: CGImage? = nil,
                                    bambuHeroLayout: Bool = true) throws -> RenderResult {
        let ctx = createContext()
        let safe = clampSafeArea(settings.safeAreaHeight)
        // 画板专用底色模式（手动深/浅色）覆盖默认调色板
        let basePalette = palette ?? settings.resolvedPalette

        // 背景模式：图像模块铺满整卡作底（其上叠加深色蒙版保证文字可读）。
        // 图像模式仅键盘画板可选；墨水屏画板图片模块固定按叠加模块显示
        let useImageBackground = modules.contains(.image)
            && settings.canvasImageMode == .background
            && isCanvasImageReady(settings.customImagePath)

        // 智能封面取色背景：整卡背景替换为专辑封面主色（同「正在播放」卡片设计），
        // 需画板含「正在播放」模块且有封面；整卡文字/边框随主色明暗自适应
        let coverArt = settings.canvasNowPlayingSmartBg && modules.contains(.nowPlaying)
            ? (artworkImage ?? nowPlaying.artwork.flatMap { decodeArtwork($0) })
            : nil
        let coverDominant = coverArt.map { dominantColor(of: $0) }

        let colors: ScreenPalette
        let c: CGRect
        if useImageBackground, let path = settings.customImagePath {
            colors = ScreenThemes.get(.deepSpace) // 深色系，保证图上文字可读
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
            strokeRound(ctx, rect(c), radius: 13, color: colors.borderCG, width: 1)
        } else if let dominant = coverDominant {
            colors = artworkPalette(baseColor: dominant,
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
            let bands = moduleBands(modules: modules, region: region, settings: settings,
                                    haEntityCount: ha.selectedEntities.count + ha.missingEntityIDs.count,
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
                                 codex: codex, qwenQuota: qwenQuota, sspaiArticles: sspaiArticles,
                                 ha: ha, now: now,
                                 nowPlayingSmartBg: settings.canvasNowPlayingSmartBg,
                                 canvasCoverBgActive: coverArt != nil,
                                 accentOverride: accentOverride,
                                 printerFields: printerFields,
                                 // 灵犀画板与口袋先知/摘录统一采用新版打印机仪表排版：
                                 // 状态背景字、前景百分比、加粗进度条、双行任务名与数据更新时间。
                                 bambuHeroLayout: bambuHeroLayout)
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
            if m == .homeAssistant {
                return base * homeAssistantCanvasHeightMultiplier(entityCount: haEntityCount)
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
    /// flipVertical/flipHorizontal 上下/左右翻转整幅画面（同开 = 旋转 180°）；
    /// columns=2 时模块按双列排列，fullWidthModules 中的模块占满整行（摘录画板用）。
    public static func renderDeviceCanvas(modules: [CanvasModule], system: SystemSnapshot,
                                          nowPlaying: NowPlayingInfo, pomodoro: PomodoroSnapshot,
                                          customText: String, settings: AppSettings,
                                          codex: UsageSnapshot = .empty,
                                          qwenQuota: QwenWorkQuota = .unavailable,
                                          sspaiArticles: [SspaiArticle] = [],
                                          ha: HASnapshot = .empty,
                                          now: Date = Date(),
                                          width: Int, height: Int,
                                          palette: ScreenPalette,
                                          flipVertical: Bool = false,
                                          flipHorizontal: Bool = false,
                                          columns: Int = 1,
                                          fullWidthModules: Set<Int> = [],
                                          nowPlayingHorizontal: Bool = false,
                                          canvasImagePath: String? = nil,
                                          printerFields: [Int: CanvasPrinterFields] = [:],
                                          optimizeBambuForOracleEInk: Bool = false,
                                          bambuHeroLayout: Bool = false,
                                          showBambuCamera: Bool = true) -> CGImage {
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
                                    columns: columns, fullWidthModules: fullWidthModules,
                                    haEntityCount: ha.selectedEntities.count + ha.missingEntityIDs.count)
            for (index, module) in modules.enumerated() {
                drawCanvasModule(ctx, module, band: bands[index], colors: einkPalette,
                                 system: system, nowPlaying: nowPlaying, pomodoro: pomodoro,
                                 customText: customText, settings: settings,
                                 codex: codex, qwenQuota: qwenQuota, sspaiArticles: sspaiArticles,
                                 ha: ha, now: now,
                                 imageOverlayOnly: true,
                                 nowPlayingSmartBg: false,
                                 fullWidth: fullWidthModules.contains(module.rawValue),
                                 deviceCanvas: true,
                                 nowPlayingHorizontal: nowPlayingHorizontal,
                                 canvasImagePath: canvasImagePath,
                                 printerFields: printerFields,
                                 optimizeBambuForOracleEInk: optimizeBambuForOracleEInk,
                                 bambuHeroLayout: bambuHeroLayout,
                                 showBambuCamera: showBambuCamera)
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

    /// Bambu 画板模块字号。口袋先知与摘录都属于独立设备画板，使用更大的字号与
    /// 更高的最小值，确保灰阶量化后设备名、温度和剩余时间仍能直接辨认。
    public static func bambuCanvasTypography(sizeBase: CGFloat,
                                             optimizeForOracleEInk: Bool)
        -> (label: CGFloat, value: CGFloat, body: CGFloat) {
        if optimizeForOracleEInk {
            return (label: min(max(sizeBase * 0.68, 12), 16),
                    value: min(max(sizeBase * 0.78, 14), 21),
                    body: min(max(sizeBase * 0.72, 12.5), 17))
        }
        let standard = canvasTypography()
        return (label: min(max(sizeBase * 0.52, 7), standard.label),
                value: min(max(sizeBase * 0.62, 8), standard.value),
                body: min(max(sizeBase * 0.56, 7), standard.body))
    }

    /// Bambu 画板进度条厚度。口袋先知使用 8–14 px，确保误差扩散后二值线条仍清晰。
    public static func bambuCanvasProgressBarHeight(rowHeight: CGFloat,
                                                    optimizeForOracleEInk: Bool) -> CGFloat {
        optimizeForOracleEInk
            ? min(max(rowHeight * 0.36, 8), 14)
            : min(max(rowHeight - 6, 3), 7)
    }

    /// 绘制单个画板模块（band 为 Skia 语义的横带）；imageOverlayOnly=true 时图像模块强制按叠加绘制；
    /// nowPlayingSmartBg=true 时正在播放模块用封面主色填充模块底（键盘画板整卡背景已是封面主色时由
    /// canvasCoverBgActive=true 跳过，避免出现色差圆角块）
    private static func drawCanvasModule(_ ctx: CGContext, _ module: CanvasModule, band: CGRect,
                                         colors: ScreenPalette, system: SystemSnapshot,
                                         nowPlaying: NowPlayingInfo, pomodoro: PomodoroSnapshot,
                                         customText: String, settings: AppSettings,
                                         codex: UsageSnapshot, qwenQuota: QwenWorkQuota,
                                         sspaiArticles: [SspaiArticle], ha: HASnapshot, now: Date,
                                         imageOverlayOnly: Bool = false,
                                         nowPlayingSmartBg: Bool = false,
                                         canvasCoverBgActive: Bool = false,
                                         fullWidth: Bool = false,
                                         deviceCanvas: Bool = false,
                                         nowPlayingHorizontal: Bool = false,
                                         canvasImagePath: String? = nil,
                                         accentOverride: CGColor? = nil,
                                         printerFields: [Int: CanvasPrinterFields] = [:],
                                         optimizeBambuForOracleEInk: Bool = false,
                                         bambuHeroLayout: Bool = false,
                                         showBambuCamera: Bool = true) {
        let w = band.width
        let typography = canvasTypography()
        switch module {
        case .homeAssistant:
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
            let remain = ha.entities.first { $0.entityId == bambu.remainingEntityID }
            let error = ha.entities.first { $0.entityId == bambu.errorEntityID }
            let hasStatusBinding = !bambu.statusEntityID
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            // 轨道用稳定浅灰显示未完成部分；描边按画板底色反色（浅底黑、深底白）。
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
                baseContentBand = band
            }
            let heroEnabled = bambuHeroLayout && fields.showProgress && progress != nil
            // 新仪表布局在模块底部保留一行清晰的数据更新时间；条带过矮时自动省略。
            let footerH: CGFloat = heroEnabled && baseContentBand.height >= 72
                ? min(max(baseContentBand.height * 0.10, 15), 22) : 0
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
            let taskNeedsTwoLines = !taskText.isEmpty
                && measureTextWidth(taskText, size: 15, bold: optimizeBambuForOracleEInk)
                    > max(contentBand.width - 4, 10)

            // 已开启且有内容的行（错误行仅在真正报错时占位）
            var rows: [Int] = []
            if heroEnabled {
                rows.append(8) // 状态背景字 + 前景百分比 + 下方粗进度条
            } else {
                if fields.showStatus && hasStatusBinding { rows.append(0) }
                if fields.showProgress, progress != nil { rows.append(1) }
            }
            if fields.showTask, let t = task, !t.state.isEmpty { rows.append(2) }
            if fields.showNozzleTemp, nozzle != nil { rows.append(3) }
            if fields.showBedTemp, bed != nil { rows.append(4) }
            if fields.showRemaining, let r = remain, !r.state.isEmpty,
               r.state.lowercased() != "unknown" { rows.append(5) }
            if fields.showError, isError { rows.append(6) }
            if picture != nil { rows.append(7) }
            if rows.isEmpty { rows = [0] }
            // 行高按权重分配：画面行占更多空间，文字行保持原有字号基准
            let weights = rows.map { kind -> CGFloat in
                if kind == 7 { return 2.4 }
                if kind == 8 { return 2.0 }
                if kind == 2 && taskNeedsTwoLines { return 1.55 }
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
                    // 口袋先知/摘录的大字仪表布局：状态退到灰色背景，进度数字与小号 %
                    // 叠在前景；进度条与数字之间保留明显空隙，避免墨水屏量化后粘连。
                    let value = min(max(Double(progress?.state ?? "") ?? 0, 0), 100)
                    let numberSize = min(max(rowRect.height * 0.36, 20), 54)
                    let percentSize = max(numberSize / 2, 10)
                    let nameSize = min(max(rowRect.height * 0.13, 11), 16)
                    drawAdaptiveText(ctx, printerLabel.isEmpty ? "打印机" : printerLabel,
                                     maxSize: nameSize, minSize: 9, bold: true,
                                     color: secondaryText,
                                     in: rect(rowRect.minX, rowRect.minY,
                                              rowRect.width, max(nameSize + 5, 17)), align: .left)
                    if fields.showStatus && hasStatusBinding {
                        // 旧值 0.28 在灰阶/误差扩散后笔画容易消失；提高到 0.50，
                        // 同时保留前景纯黑进度数字的层级差。
                        let backdrop = primaryText.copy(alpha: 0.50) ?? secondaryText
                        drawAdaptiveText(ctx, statusText,
                                         maxSize: min(max(rowRect.height * 0.34, 22), 58),
                                         minSize: 15, bold: true, color: backdrop,
                                         in: rect(rowRect.minX, rowRect.minY + rowRect.height * 0.08,
                                                  rowRect.width, rowRect.height * 0.48),
                                         align: .center)
                    }
                    let labelY = rowRect.minY + rowRect.height * 0.24
                    let labelH = rowRect.height * 0.42
                    drawBambuProgressLabel(ctx, number: String(format: "%.0f", value),
                                           numberSize: numberSize, percentSize: percentSize,
                                           numberColor: primaryText, percentColor: secondaryText,
                                           in: rect(rowRect.minX, labelY, rowRect.width, labelH))
                    let barH = min(max(rowRect.height * 0.095, 8), 14)
                    let barY = rowRect.maxY - barH - 3
                    let progressBounds = rect(rowRect.minX, barY, rowRect.width, barH)
                    drawProgress(ctx, progressBounds, progress: value / 100,
                                 accent: progressInk, background: progressTrack)
                    strokeRound(ctx, progressBounds, radius: barH / 2,
                                color: adaptiveOutline,
                                width: optimizeBambuForOracleEInk ? 2 : 1.5)
                case 0:
                    // 状态行：打印机名（左）+ 状态大字（右）。全部映射均为空时
                    // rows 的兜底仍会进入这里，但只显示设备名，不把“未配置”冒充状态。
                    drawText(ctx, printerLabel.isEmpty ? "打印机" : printerLabel, size: labelSize,
                             bold: optimizeBambuForOracleEInk, color: secondaryText,
                             in: rect(rowRect.minX, rowRect.minY,
                                      hasStatusBinding ? contentWidth * 0.5 : contentWidth,
                                      rowRect.height),
                             align: hasStatusBinding ? .left : .center)
                    if hasStatusBinding {
                        drawText(ctx, statusText, size: valueSize, bold: true,
                                 color: isError ? alertText : primaryText,
                                 in: rect(rowRect.minX, rowRect.minY,
                                          contentWidth, rowRect.height), align: .right)
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
                                        bold: optimizeBambuForOracleEInk)
                case 3:
                    drawCanvasModuleValueLine(ctx, "喷嘴 \(nozzle?.displayValue ?? "—")", rowRect,
                                              w: contentWidth, size: bodySize, color: secondaryText,
                                              bold: optimizeBambuForOracleEInk)
                case 4:
                    drawCanvasModuleValueLine(ctx, "热床 \(bed?.displayValue ?? "—")", rowRect,
                                              w: contentWidth, size: bodySize, color: secondaryText,
                                              bold: optimizeBambuForOracleEInk)
                case 5:
                    drawCanvasModuleValueLine(ctx, "剩余 \(remain?.remainingDisplayText ?? "—")", rowRect,
                                              w: contentWidth, size: bodySize, color: secondaryText,
                                              bold: optimizeBambuForOracleEInk)
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
            let pct = codex.remainingPercent
            drawQuotaBand(ctx, band: band, label: "Codex", value: "\(pct)%",
                          progress: Double(pct) / 100, accent: accentOverride ?? colors.accentCG, colors: colors)
        case .qwenQuota:
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
        case .network:
            let rowH = max(band.height / 2, 10)
            drawText(ctx, "↓ " + formatRate(system.downloadBytesPerSecond), size: typography.body, bold: true,
                     color: colors.primaryTextCG,
                     in: rect(band.minX + 6, band.minY, w - 12, rowH), align: .left)
            drawText(ctx, "↑ " + formatRate(system.uploadBytesPerSecond), size: typography.body, bold: true,
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
                    let coverRect = rect(coverX, coverY, coverSize, coverSize)
                    ctx.saveGState()
                    ctx.addPath(CGPath(roundedRect: coverRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                    ctx.clip()
                    ctx.interpolationQuality = .high
                    ctx.draw(art, in: coverRect)
                    ctx.restoreGState()
                    // 墨水屏设备画板：封面加 2px 黑色描边，避免浅色封面与背景融为一体；
                    // 键盘画板开启「智能封面取色背景」时封面描边用封面主色强调色（跟随封面）
                    if deviceCanvas {
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
                    // 墨水屏设备画板：封面加 2px 黑色描边，避免浅色封面与背景融为一体；
                    // 键盘画板开启「智能封面取色背景」时封面描边用封面主色强调色（跟随封面）
                    if deviceCanvas {
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
                // 无封面（或未开启封面）：空间够就上下两行；被压缩到两行都会挤成小字时
                // 自动转横向单行（歌名居左、歌手居右），与口袋先知/摘录画板的横向排布一致
                let h1 = max(band.height * 0.55, 10)
                let h2 = max(band.height - h1, 6)
                if Self.nowPlayingPrefersHorizontal(bandHeight: band.height, bandWidth: band.width,
                                                    title: title,
                                                    titleSizeSetting: settings.canvasNowPlayingTitleSize) {
                    var artistSize = max(min(band.height * 0.62,
                                             CGFloat(settings.canvasNowPlayingArtistSize)), 6)
                    var artistW = measureTextWidth(artist, size: artistSize, bold: false)
                    let artistMaxW = w * 0.45
                    if artistW > artistMaxW {
                        artistSize = max(artistSize * artistMaxW / artistW, 6)
                        artistW = measureTextWidth(artist, size: artistSize, bold: false)
                    }
                    let titleMaxW = artist.isEmpty ? w : max(w - artistW - 8, 24)
                    var titleSize = max(min(band.height * 0.72,
                                            CGFloat(settings.canvasNowPlayingTitleSize)), 7)
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
                    var size = min(h1 * 0.75, CGFloat(settings.canvasNowPlayingTitleSize))
                    if measureTextWidth(title, size: size, bold: true) > w - 4 {
                        size = max(size * (w - 4) / measureTextWidth(title, size: size, bold: true), 8)
                    }
                    drawText(ctx, title, size: size, bold: true, color: primaryTextColor,
                             in: rect(band.minX, band.minY, w, h1), align: .center)
                    drawText(ctx, artist, size: max(min(h2 * 0.7, CGFloat(settings.canvasNowPlayingArtistSize)), 6), bold: false,
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
                // 状态区宽：按状态文本自适应（右对齐贴右缘；最短 20、最长 55，保证名称区宽度）
                var vs: CGFloat = 11
                while vs > 8 && measureTextWidth(value, size: vs, bold: true) > 55 {
                    vs -= 0.5
                }
                let valueW = min(max(measureTextWidth(value, size: vs, bold: true) + 2, 20), 55)
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
    private static let symbolImageCache = NSCache<NSString, CGImage>()

    /// 取 SF Symbol 图像（指定点大小与颜色；无此符号回退 nil）
    private static func symbolImage(_ name: String, pointSize: CGFloat, color: CGColor) -> CGImage? {
        let key = "\(name)#\(Int(pointSize))#\(color.alpha > 0.5 ? "1" : "0")" as NSString
        if let cached = symbolImageCache.object(forKey: key) { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let nsColor = NSColor(cgColor: color) ?? .black
        // 模板符号着色：sourceAtop 只给非透明像素染上指定颜色
        let tinted = NSImage(size: base.size)
        tinted.lockFocus()
        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        nsColor.set()
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        var rect = CGRect(origin: .zero, size: tinted.size)
        guard let cg = tinted.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        symbolImageCache.setObject(cg, forKey: key)
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
    /// 大字布局的进度数字保持原来的 34pt；百分号缩小为数字的一半，降低视觉抢占。
    public static let bambuLargeProgressNumberSize: CGFloat = 34
    public static let bambuLargeProgressPercentSize: CGFloat = bambuLargeProgressNumberSize / 2
    /// 大字布局中状态作为进度数字背后的超大辅助信息，按宽度自适应缩小。
    public static let bambuLargeStatusBackdropSize: CGFloat = 35
    /// 数据更新时间需要在实体屏幕上保持可读，不能沿用普通辅助文字的 7.5pt。
    public static let bambuDataFooterSize: CGFloat = 9.5

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
            infoSize = 8; progressH = 6; taskBaseSize = 9
        case .large:
            // 大字布局只突出打印百分比；工作状态与标准布局保持同字号、横向排布。
            statusSize = 20; topOffset = 43
            progressStep = 19; taskStep = 24; tempStep = 21; remainStep = 21
            infoSize = 10; progressH = 9; taskBaseSize = 13
        case .standard:
            statusSize = 20; topOffset = 49
            progressStep = 16; taskStep = 20; tempStep = 18; remainStep = 18
            infoSize = 9; progressH = 7; taskBaseSize = 11
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
                drawAdaptiveText(ctx, statusText,
                                 maxSize: Self.bambuLargeStatusBackdropSize,
                                 minSize: 23, bold: true, color: backdropColor,
                                 in: rect(innerX, top - 5, innerW, 48), align: .center)
            }
            drawBambuProgressLabel(ctx, number: numberText,
                                   numberSize: numberSize, percentSize: percentSize,
                                   numberColor: colors.primaryTextCG,
                                   percentColor: colors.secondaryTextCG,
                                   in: rect(innerX, top + 16, innerW, 46))
            // 给数字字形下沿留出明确呼吸空间，避免与轨道粘在一起。
            let barY = top + 72
            let barBounds = rect(innerX, barY, innerW, 12)
            drawProgress(ctx, barBounds, progress: clampedPercent / 100,
                         accent: accent, background: colors.borderCG)
            strokeRound(ctx, barBounds, radius: 6, color: colors.secondaryTextCG, width: 1)
            y = barY + 20
        }

        // 标准/紧凑布局中的状态仍是独立横排；大字布局已将它叠入进度信息区。
        if bambu.showStatus, hasStatusBinding, !prominentProgress {
            drawText(ctx, statusText, size: statusSize, bold: true, color: statusColor,
                     in: rect(c.minX + 8, y, c.maxX - c.minX - 16, statusSize + 6), align: .center)
            y += statusSize + 12
        }
        // 画面区块（状态下方）：image.* 实体画面（摄像头快照 / 模型封面）
        // 先给后续文字行留出空间，再按 16:9 铺一张圆角图；空间不足 34pt 时整块跳过
        if bambu.showImage, let picture = image {
            let textReserve: CGFloat = (bambu.showProgress && !prominentProgress ? progressStep : 0)
                + taskBlockH
                + (bambu.showTemperature ? tempStep : 0)
                + (bambu.showRemaining ? remainStep : 0)
                + (isError && bambu.showError ? 46 : 0) + 10
            let pictureW = c.maxX - c.minX - 20
            let available = contentBottom - y - textReserve
            let pictureH = min(pictureW * 9 / 16, available, 120)
            if pictureH >= 34 {
                let box = CGRect(x: c.minX + 10, y: y, width: pictureW, height: pictureH)
                if drawImageData(ctx, data: picture, into: box, cover: true, radius: 6) {
                    strokeRound(ctx, rect(box), radius: 6, color: colors.borderCG, width: 1)
                    y += pictureH + 6
                }
            }
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
        let nozzle = entity(bambu.nozzleTempEntityID)
        let bed = entity(bambu.bedTempEntityID)
        if bambu.showTemperature, nozzle != nil || bed != nil {
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
        // 剩余时间（remaining_time 常为小时小数，转为可读的「X 小时 Y 分钟 / X 分钟」）
        if bambu.showRemaining,
           let remain = entity(bambu.remainingEntityID), !remain.state.isEmpty,
           remain.state.lowercased() != "unknown" {
            drawText(ctx, "剩余 \(remain.remainingDisplayText)", size: infoSize, bold: false, color: colors.secondaryTextCG,
                     in: rect(c.minX + 10, y, c.maxX - c.minX - 20, 16), align: .center)
            y += remainStep
        }
        // 错误警示：错误码 + HMS 故障原因（内置映射，未收录显示通用提示）
        if isError, bambu.showError {
            let errorText = error?.state ?? status?.state ?? "未知错误"
            drawText(ctx, "⚠ \(errorText)", size: 13, bold: true, color: warn,
                     in: rect(c.minX + 10, y, c.maxX - c.minX - 20, 22), align: .center)
            y += 22
            let reason = BambuHMSCode.reason(for: errorText)
                ?? "未知错误码，详见 Bambu Lab HMS 文档"
            let maxW = c.maxX - c.minX - 20
            let lines = splitLines(reason, size: 11, bold: true, maxW: maxW, maxLines: 3)
            for line in lines {
                drawText(ctx, line, size: 11, bold: true, color: warn,
                         in: rect(c.minX + 10, y, maxW, 15), align: .center)
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

    public static func renderNowPlaying(_ info: NowPlayingInfo, settings: AppSettings,
                                        artworkImage: CGImage? = nil,
                                        now: Date = Date()) throws -> RenderResult {
        let artImage = artworkImage ?? (info.artwork.flatMap { decodeArtwork($0) })
        // 有封面时从封面取主色作为卡片背景；无封面回退主题配色
        let coverDominant = artImage.map { dominantColor(of: $0) }
        let colors: ScreenPalette
        if let coverDominant {
            colors = artworkPalette(baseColor: coverDominant,
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
        // 歌名先排版：双行时多留一行高度（信息区整体上移、封面缩小让位），
        // 而不是把字号缩到不可读
        let titleMaxW = c.maxX - c.minX - 20
        let titleLayout = nowPlayingTitleLines(title: info.title.isEmpty ? "未在播放" : info.title,
                                               maxWidth: titleMaxW,
                                               maxSize: CGFloat(settings.nowPlayingTitleSize))
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
        drawAdaptiveText(ctx, subtitle, maxSize: CGFloat(settings.nowPlayingArtistSize), minSize: 5.5,
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

        // 页脚：当前时间（上：时钟，下：日期）；格式与字号可自定义，也可整体隐藏。
        // 各带高度随字号自适应，字号调小后行距同步收紧释放空间。
        // 时间、日期与「当前时间」标签同样使用封面生成的强调色
        if footerVisible {
            drawFooterClock(ctx, card: c, settings: settings, colors: colors, now: now,
                            accent: CGColor(red: progressAccent.0, green: progressAccent.1,
                                            blue: progressAccent.2, alpha: 1),
                            tintAll: true)
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

    /// 从封面主色生成进度条强调色：深色封面提亮、浅色封面加深，
    /// 保证在封面底（=主色）上有足够对比；不跟随全局强调色。
    /// 对比度增强：深色提亮到更高亮度、浅色加深到更低亮度，进度条更清晰可见
    private static func coverProgressAccent(_ rgb: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
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
        let preferredDateSize = CGFloat(settings.nowPlayingDateSize)
        let preferredTimeSize = CGFloat(settings.nowPlayingTimeSize)
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
        let dateH = max(CGFloat(settings.nowPlayingDateSize) + 8, 18)
        let timeH = max(CGFloat(settings.nowPlayingTimeSize) + 10, 24)
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
    private static func wallpaperSeedColor(of image: CGImage) -> (CGFloat, CGFloat, CGFloat) {
        let size = 32
        guard let ctx = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else {
            return dominantColor(of: image)
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

        guard let winner = buckets.max(by: { $0.score < $1.score }), winner.score > 0 else {
            return dominantColor(of: image)
        }
        return (winner.red / winner.score,
                winner.green / winner.score,
                winner.blue / winner.score)
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
}
