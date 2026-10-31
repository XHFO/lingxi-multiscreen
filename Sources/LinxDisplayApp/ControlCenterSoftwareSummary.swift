import Foundation
import LinxDisplayCore

/// 中控软件卡片可单独选择显示的内容。字段只影响中控面板，不改变设备卡片本身。
enum ControlCenterSoftwareField: String, CaseIterable, Identifiable {
    case codexPercent, codexWindow, codexReset, codexPlan, codexProgress
    case qwenRemaining, qwenUnit, qwenPlan, qwenSegments, qwenProgress
    case grokPercent, grokPlan, grokReset, grokProgress
    case deepSeekBalance, deepSeekTodayCost, deepSeekTodayTokens
    case deepSeekMonthCost, deepSeekMonthTokens, deepSeekGranted
    case deepSeekTopUp, deepSeekAPI, deepSeekTopModel
    case sspaiCount, sspaiLatestTitle, sspaiLatestAuthor, sspaiList
    case pomodoroTime, pomodoroPhase, pomodoroTask, pomodoroCompleted, pomodoroProgress
    case excerptText, excerptSource
    case systemCPU, systemMemory, systemDisk, systemNetwork, systemUptime
    case customImageName, emojiText, canvasModules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codexPercent: return "剩余百分比"
        case .codexWindow: return "额度窗口"
        case .codexReset: return "重置时间"
        case .codexPlan: return "套餐"
        case .codexProgress: return "进度条"
        case .qwenRemaining: return "剩余额度"
        case .qwenUnit: return "额度单位"
        case .qwenPlan: return "套餐"
        case .qwenSegments: return "分段数量"
        case .qwenProgress: return "进度条"
        case .grokPercent: return "剩余百分比"
        case .grokPlan: return "套餐"
        case .grokReset: return "重置时间"
        case .grokProgress: return "进度条"
        case .deepSeekBalance: return "账户余额"
        case .deepSeekTodayCost: return "今日花费"
        case .deepSeekTodayTokens: return "今日 Token"
        case .deepSeekMonthCost: return "本月花费"
        case .deepSeekMonthTokens: return "本月 Token"
        case .deepSeekGranted: return "赠送余额"
        case .deepSeekTopUp: return "充值余额"
        case .deepSeekAPI: return "API 状态"
        case .deepSeekTopModel: return "主要模型"
        case .sspaiCount: return "文章数量"
        case .sspaiLatestTitle: return "最新标题"
        case .sspaiLatestAuthor: return "最新作者"
        case .sspaiList: return "文章列表"
        case .pomodoroTime: return "剩余时间"
        case .pomodoroPhase: return "阶段"
        case .pomodoroTask: return "任务名"
        case .pomodoroCompleted: return "完成数"
        case .pomodoroProgress: return "进度条"
        case .excerptText: return "语录正文"
        case .excerptSource: return "出处"
        case .systemCPU: return "CPU 占用"
        case .systemMemory: return "内存占用"
        case .systemDisk: return "磁盘占用"
        case .systemNetwork: return "网络速率"
        case .systemUptime: return "运行时间"
        case .customImageName: return "图片名称"
        case .emojiText: return "Emoji 内容"
        case .canvasModules: return "模块数量"
        }
    }

    static func fields(for mode: DisplayMode) -> [ControlCenterSoftwareField] {
        switch mode {
        case .codex: return [.codexPercent, .codexWindow, .codexReset, .codexPlan, .codexProgress]
        case .qwenWork: return [.qwenRemaining, .qwenUnit, .qwenPlan, .qwenSegments, .qwenProgress]
        case .grokBot: return [.grokPercent, .grokPlan, .grokReset, .grokProgress]
        case .deepSeek: return [.deepSeekBalance, .deepSeekTodayCost, .deepSeekTodayTokens,
                                .deepSeekMonthCost, .deepSeekMonthTokens, .deepSeekGranted,
                                .deepSeekTopUp, .deepSeekAPI, .deepSeekTopModel]
        case .sspai: return [.sspaiCount, .sspaiLatestTitle, .sspaiLatestAuthor, .sspaiList]
        case .pomodoro: return [.pomodoroTime, .pomodoroPhase, .pomodoroTask,
                                .pomodoroCompleted, .pomodoroProgress]
        case .excerptQuote: return [.excerptText, .excerptSource]
        case .systemMonitor: return [.systemCPU, .systemMemory, .systemDisk,
                                     .systemNetwork, .systemUptime]
        case .customImage: return [.customImageName]
        case .emojiWallpaper: return [.emojiText]
        case .canvas: return [.canvasModules]
        default: return []
        }
    }

    static func defaultFields(for mode: DisplayMode) -> Set<ControlCenterSoftwareField> {
        switch mode {
        case .codex: return [.codexPercent, .codexWindow, .codexReset, .codexPlan, .codexProgress]
        case .qwenWork: return [.qwenRemaining, .qwenUnit, .qwenPlan, .qwenProgress]
        case .grokBot: return [.grokPercent, .grokPlan, .grokReset, .grokProgress]
        case .deepSeek: return [.deepSeekBalance, .deepSeekTodayCost, .deepSeekTodayTokens,
                                .deepSeekMonthCost, .deepSeekMonthTokens, .deepSeekAPI]
        case .sspai: return [.sspaiCount, .sspaiLatestAuthor, .sspaiList]
        case .pomodoro: return [.pomodoroTime, .pomodoroPhase, .pomodoroTask, .pomodoroProgress]
        case .excerptQuote: return [.excerptText, .excerptSource]
        case .systemMonitor: return [.systemCPU, .systemMemory, .systemDisk,
                                     .systemNetwork, .systemUptime]
        case .customImage: return [.customImageName]
        case .emojiWallpaper: return [.emojiText]
        case .canvas: return [.canvasModules]
        default: return []
        }
    }
}

struct ControlCenterSoftwareMetric: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.id = label
        self.label = label
        self.value = value
    }
}

/// 中控面板软件卡片的实时摘要。只读取 AppModel 已缓存的数据，不触发网络请求。
@MainActor
struct ControlCenterSoftwareSummary {
    let title: String
    let icon: String
    let headline: String?
    let headlineLabel: String?
    let metrics: [ControlCenterSoftwareMetric]
    let body: String?
    let footer: String?
    let progress: Double?
    let fields: Set<ControlCenterSoftwareField>

    var status: String { footer ?? headline ?? "打开设置" }

    static func make(model: AppModel, settings: AppSettings,
                     mode: DisplayMode) -> ControlCenterSoftwareSummary {
        let stored = settings.controlCenterSoftwareFieldIDs(for: mode)
        let fields = stored.map { Set($0.compactMap(ControlCenterSoftwareField.init(rawValue:))) }
            ?? ControlCenterSoftwareField.defaultFields(for: mode)
        switch mode {
        case .codex: return codex(model: model, fields: fields)
        case .qwenWork: return qwen(model: model, fields: fields)
        case .grokBot: return grok(model: model, fields: fields)
        case .deepSeek: return deepSeek(model: model, fields: fields)
        case .sspai: return sspai(model: model, fields: fields)
        case .pomodoro: return pomodoro(model: model, fields: fields)
        case .excerptQuote: return excerpt(model: model, fields: fields)
        case .systemMonitor: return system(model: model, fields: fields)
        case .customImage:
            return .init(title: mode.title, icon: mode.icon, headline: nil, headlineLabel: nil,
                         metrics: [], body: model.settings.customImageName ?? "尚未选择图片",
                         footer: "键盘卡片", progress: nil, fields: fields)
        case .emojiWallpaper:
            let text = model.settings.emojiWallpaperText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(title: mode.title, icon: mode.icon, headline: nil, headlineLabel: nil,
                         metrics: [], body: text.isEmpty ? "尚未输入 Emoji" : text,
                         footer: "键盘卡片", progress: nil, fields: fields)
        case .canvas:
            let count = model.settings.canvasModuleList.count
            return .init(title: mode.title, icon: mode.icon, headline: nil, headlineLabel: nil,
                         metrics: [], body: count > 0 ? "\(count) 个模块" : "尚未添加模块",
                         footer: "键盘画板", progress: nil, fields: fields)
        default:
            return .init(title: mode.title, icon: mode.icon, headline: nil, headlineLabel: nil,
                         metrics: [], body: nil, footer: "打开设置", progress: nil, fields: fields)
        }
    }

    private static func codex(model: AppModel, fields: Set<ControlCenterSoftwareField>) -> Self {
        let usage = model.usage
        guard usage.isAvailable else {
            return .init(title: DisplayMode.codex.title, icon: DisplayMode.codex.icon,
                         headline: nil, headlineLabel: nil, metrics: [], body: "尚未读取 Codex 用量",
                         footer: "打开后刷新", progress: nil, fields: fields)
        }
        var metrics: [ControlCenterSoftwareMetric] = []
        if fields.contains(.codexWindow) { metrics.append(.init("额度窗口", usage.windowTitle)) }
        if fields.contains(.codexReset) {
            metrics.append(.init("重置时间", usage.resetDate.map { shortDate($0) } ?? "未提供"))
        }
        if fields.contains(.codexPlan) { metrics.append(.init("套餐", usage.planType ?? "官方")) }
        return .init(title: DisplayMode.codex.title, icon: DisplayMode.codex.icon,
                     headline: fields.contains(.codexPercent) ? "\(usage.remainingPercent)%" : nil,
                     headlineLabel: fields.contains(.codexPercent) ? usage.windowTitle : nil,
                     metrics: metrics, body: nil,
                     footer: usage.sourceName ?? "Codex 官方用量",
                     progress: fields.contains(.codexProgress) ? Double(usage.remainingPercent) / 100 : nil,
                     fields: fields)
    }

    private static func qwen(model: AppModel, fields: Set<ControlCenterSoftwareField>) -> Self {
        let quota = model.qwenQuota
        guard quota.available else {
            return .init(title: DisplayMode.qwenWork.title, icon: DisplayMode.qwenWork.icon,
                         headline: nil, headlineLabel: nil, metrics: [], body: "尚未读取千问办公额度",
                         footer: "打开后刷新", progress: nil, fields: fields)
        }
        let unit = quota.unit.isEmpty ? "credits" : quota.unit
        var metrics: [ControlCenterSoftwareMetric] = []
        if fields.contains(.qwenUnit) { metrics.append(.init("单位", unit)) }
        if fields.contains(.qwenPlan) { metrics.append(.init("套餐", quota.plan ?? "未提供")) }
        if fields.contains(.qwenSegments) { metrics.append(.init("分段", "\(quota.segments.count)")) }
        return .init(title: DisplayMode.qwenWork.title, icon: DisplayMode.qwenWork.icon,
                     headline: fields.contains(.qwenRemaining) ? compactNumber(quota.remainingCredits) : nil,
                     headlineLabel: fields.contains(.qwenRemaining) ? "剩余 \(unit)" : nil,
                     metrics: metrics, body: nil,
                     footer: "剩余 \(Int((quota.progress * 100).rounded()))%",
                     progress: fields.contains(.qwenProgress) ? quota.progress : nil,
                     fields: fields)
    }

    private static func grok(model: AppModel, fields: Set<ControlCenterSoftwareField>) -> Self {
        let grok = model.grokBotUsage
        guard grok.isAvailable, let remaining = grok.remainingPercent else {
            return .init(title: DisplayMode.grokBot.title, icon: DisplayMode.grokBot.icon,
                         headline: nil, headlineLabel: nil, metrics: [],
                         body: grok.message.isEmpty ? "尚未读取 Grok Bot 用量" : grok.message,
                         footer: "打开后刷新", progress: nil, fields: fields)
        }
        var metrics: [ControlCenterSoftwareMetric] = []
        if fields.contains(.grokPlan) { metrics.append(.init("套餐", grok.planLabel ?? "未提供")) }
        if fields.contains(.grokReset) {
            metrics.append(.init("重置时间", grok.resetDate.map { shortDate($0) } ?? "未提供"))
        }
        return .init(title: DisplayMode.grokBot.title, icon: DisplayMode.grokBot.icon,
                     headline: fields.contains(.grokPercent) ? "\(remaining)%" : nil,
                     headlineLabel: fields.contains(.grokPercent) ? "本周剩余" : nil,
                     metrics: metrics, body: nil, footer: "Grok Bot 用量",
                     progress: fields.contains(.grokProgress) ? Double(remaining) / 100 : nil,
                     fields: fields)
    }

    private static func deepSeek(model: AppModel, fields: Set<ControlCenterSoftwareField>) -> Self {
        let deepSeek = model.deepSeekUsage
        guard deepSeek.isAvailable else {
            let configured = !model.settings.deepSeekAPIKey
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return .init(title: DisplayMode.deepSeek.title, icon: DisplayMode.deepSeek.icon,
                         headline: nil, headlineLabel: nil, metrics: [],
                         body: deepSeek.message.isEmpty
                            ? (configured ? "已配置，等待刷新余额" : "尚未配置 DeepSeek 官方用量")
                            : deepSeek.message,
                         footer: configured ? "DeepSeek 官方" : "打开后配置",
                         progress: nil, fields: fields)
        }
        var metrics: [ControlCenterSoftwareMetric] = []
        if fields.contains(.deepSeekTodayCost) { metrics.append(.init("今日花费", deepSeek.todayCostText)) }
        if fields.contains(.deepSeekTodayTokens) { metrics.append(.init("今日 Token", deepSeek.todayTokensText)) }
        if fields.contains(.deepSeekMonthCost) { metrics.append(.init("本月花费", deepSeek.monthCostText)) }
        if fields.contains(.deepSeekMonthTokens) { metrics.append(.init("本月 Token", deepSeek.monthTokensText)) }
        if fields.contains(.deepSeekGranted) { metrics.append(.init("赠送余额", deepSeek.moneyText(deepSeek.grantedBalance))) }
        if fields.contains(.deepSeekTopUp) { metrics.append(.init("充值余额", deepSeek.moneyText(deepSeek.toppedUpBalance))) }
        if fields.contains(.deepSeekAPI) { metrics.append(.init("API 状态", deepSeek.apiAvailable ? "可用" : "不可用")) }
        if fields.contains(.deepSeekTopModel), let top = deepSeek.topModel, !top.isEmpty {
            metrics.append(.init("主要模型", top))
        }
        return .init(title: DisplayMode.deepSeek.title, icon: DisplayMode.deepSeek.icon,
                     headline: fields.contains(.deepSeekBalance) ? deepSeek.balanceText : nil,
                     headlineLabel: fields.contains(.deepSeekBalance) ? "官方账户余额" : nil,
                     metrics: metrics, body: nil,
                     footer: deepSeek.apiAvailable ? "DeepSeek 官方" : "API 不可用",
                     progress: nil, fields: fields)
    }

    private static func sspai(model: AppModel, fields: Set<ControlCenterSoftwareField>) -> Self {
        let articles = model.sspaiArticles
        var metrics: [ControlCenterSoftwareMetric] = []
        if fields.contains(.sspaiLatestAuthor), let first = articles.first {
            metrics.append(.init("作者", first.author))
        }
        var body: String?
        if fields.contains(.sspaiList), !articles.isEmpty {
            body = articles.prefix(4).map(\.title).joined(separator: "\n")
        } else if fields.contains(.sspaiLatestTitle), let first = articles.first {
            body = first.title
        }
        return .init(title: DisplayMode.sspai.title, icon: DisplayMode.sspai.icon,
                     headline: fields.contains(.sspaiCount) ? "\(articles.count) 篇" : nil,
                     headlineLabel: fields.contains(.sspaiCount) ? "文章数量" : nil,
                     metrics: metrics, body: body, footer: "少数派推荐", progress: nil, fields: fields)
    }

    private static func pomodoro(model: AppModel, fields: Set<ControlCenterSoftwareField>) -> Self {
        let snapshot = model.pomodoroSnapshot
        var metrics: [ControlCenterSoftwareMetric] = []
        if fields.contains(.pomodoroPhase) { metrics.append(.init("阶段", phaseText(snapshot))) }
        if fields.contains(.pomodoroTask) { metrics.append(.init("任务", snapshot.taskName)) }
        if fields.contains(.pomodoroCompleted) {
            metrics.append(.init("完成", "\(snapshot.completedFocusSessions) 个专注"))
        }
        return .init(title: DisplayMode.pomodoro.title, icon: DisplayMode.pomodoro.icon,
                     headline: fields.contains(.pomodoroTime) ? clockText(snapshot.remaining) : nil,
                     headlineLabel: fields.contains(.pomodoroTime) ? phaseText(snapshot) : nil,
                     metrics: metrics, body: nil, footer: "番茄钟",
                     progress: fields.contains(.pomodoroProgress) ? snapshot.progress : nil,
                     fields: fields)
    }

    private static func excerpt(model: AppModel, fields: Set<ControlCenterSoftwareField>) -> Self {
        let text = model.quoteDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(title: DisplayMode.excerptQuote.title, icon: DisplayMode.excerptQuote.icon,
                     headline: nil, headlineLabel: nil, metrics: [],
                     body: fields.contains(.excerptText) ? (text.isEmpty ? "尚未读取摘录语录" : text) : nil,
                     footer: fields.contains(.excerptSource) ? "轮换语录" : nil,
                     progress: nil, fields: fields)
    }

    private static func system(model: AppModel, fields: Set<ControlCenterSoftwareField>) -> Self {
        let system = model.system
        guard system.totalMemoryBytes > 0 else {
            return .init(title: DisplayMode.systemMonitor.title, icon: DisplayMode.systemMonitor.icon,
                         headline: nil, headlineLabel: nil, metrics: [], body: "打开系统监控后开始采样",
                         footer: "系统监控", progress: nil, fields: fields)
        }
        var metrics: [ControlCenterSoftwareMetric] = []
        if fields.contains(.systemMemory) { metrics.append(.init("内存", "\(Int(system.memoryPercent.rounded()))%")) }
        if fields.contains(.systemDisk) { metrics.append(.init("磁盘", "\(Int(system.diskPercent.rounded()))%")) }
        if fields.contains(.systemNetwork) {
            metrics.append(.init("下载", rateText(system.downloadBytesPerSecond)))
            metrics.append(.init("上传", rateText(system.uploadBytesPerSecond)))
        }
        if fields.contains(.systemUptime) { metrics.append(.init("运行时间", uptimeText(system.uptime))) }
        return .init(title: DisplayMode.systemMonitor.title, icon: DisplayMode.systemMonitor.icon,
                     headline: fields.contains(.systemCPU) ? "\(Int(system.cpuPercent.rounded()))%" : nil,
                     headlineLabel: fields.contains(.systemCPU) ? "CPU 占用" : nil,
                     metrics: metrics, body: nil, footer: "系统监控",
                     progress: fields.contains(.systemCPU) ? system.cpuPercent / 100 : nil,
                     fields: fields)
    }

    private static func compactNumber(_ value: Double) -> String {
        if value >= 1000 { return String(format: "%.0f", value) }
        if value >= 100 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    private static func clockText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func phaseText(_ snapshot: PomodoroSnapshot) -> String {
        if snapshot.isRunning {
            switch snapshot.effectivePhase {
            case .focus: return "专注中"
            case .shortBreak: return "短休息"
            case .longBreak: return "长休息"
            default: return "进行中"
            }
        }
        return snapshot.phase == .paused ? "已暂停" : "就绪"
    }

    private static func rateText(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value >= 1_048_576 { return String(format: "%.1f MB/s", value / 1_048_576) }
        if value >= 1_024 { return String(format: "%.0f KB/s", value / 1_024) }
        return String(format: "%.0f B/s", value)
    }

    private static func uptimeText(_ interval: TimeInterval) -> String {
        let hours = max(0, Int(interval)) / 3600
        if hours >= 24 { return "\(hours / 24) 天 \(hours % 24) 小时" }
        return "\(hours) 小时"
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }
}
