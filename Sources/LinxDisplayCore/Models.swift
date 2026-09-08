import Foundation

// MARK: - 枚举

public enum DisplayMode: Int, CaseIterable, Identifiable, Codable, Hashable {
    case codex = 0
    case pomodoro = 1
    case systemMonitor = 2
    case customImage = 3
    case qwenWork = 4
    case nowPlaying = 5
    case canvas = 6
    case excerptQuote = 7
    case sspai = 8
    case emojiWallpaper = 9
    case homeAssistant = 10
    case bambuLab = 11
    case bambuLab2 = 12
    case bambuLab3 = 13
    case bambuLab4 = 14
    case bambuLab5 = 15
    case formlabs = 16
    case formlabs2 = 17
    case formlabs3 = 18
    case formlabs4 = 19
    case formlabs5 = 20

    /// Bambu 卡片位对应的打印机序号（0..4；非 Bambu 卡片返回 nil）
    public var bambuSlotIndex: Int? {
        let offset = rawValue - DisplayMode.bambuLab.rawValue
        return (0...4).contains(offset) ? offset : nil
    }

    public var formlabsSlotIndex: Int? {
        let offset = rawValue - DisplayMode.formlabs.rawValue
        return (0...4).contains(offset) ? offset : nil
    }

    /// 进入这些卡片时应立即拉取一次 Home Assistant 状态，不受后台刷新间隔限制。
    public var refreshesHomeAssistantOnEntry: Bool {
        self == .homeAssistant || bambuSlotIndex != nil
    }

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .codex: return "Codex 用量"
        case .pomodoro: return "番茄钟"
        case .systemMonitor: return "系统监控"
        case .customImage: return "自定义图片"
        case .qwenWork: return "千问办公额度"
        case .nowPlaying: return "正在播放"
        case .canvas: return "灵犀画板"
        case .excerptQuote: return "摘录语录"
        case .sspai: return "少数派推荐"
        case .emojiWallpaper: return "Emoji 壁纸"
        case .homeAssistant: return "Home Assistant"
        case .bambuLab: return "Bambu Lab 打印机"
        case .bambuLab2: return "Bambu Lab 打印机 2"
        case .bambuLab3: return "Bambu Lab 打印机 3"
        case .bambuLab4: return "Bambu Lab 打印机 4"
        case .bambuLab5: return "Bambu Lab 打印机 5"
        case .formlabs: return "Formlabs 打印机"
        case .formlabs2: return "Formlabs 打印机 2"
        case .formlabs3: return "Formlabs 打印机 3"
        case .formlabs4: return "Formlabs 打印机 4"
        case .formlabs5: return "Formlabs 打印机 5"
        }
    }

    /// 跨设备共用的卡片图标。导航层直接读取这里，避免每新增一种显示设备时
    /// 再复制一份卡片标题与图标映射。
    public var icon: String {
        switch self {
        case .qwenWork: return "creditcard"
        case .codex: return "terminal"
        case .pomodoro: return "timer"
        case .systemMonitor: return "gauge"
        case .nowPlaying: return "music.note"
        case .customImage: return "photo"
        case .canvas: return "rectangle.3.group"
        case .excerptQuote: return "text.quote"
        case .sspai: return "newspaper"
        case .emojiWallpaper: return "face.smiling"
        case .homeAssistant: return "house"
        case .bambuLab, .bambuLab2, .bambuLab3, .bambuLab4, .bambuLab5,
             .formlabs, .formlabs2, .formlabs3, .formlabs4, .formlabs5:
            return "printer"
        }
    }
}

/// Emoji 壁纸排列方式（居中排列，间隔可调）
public enum EmojiWallpaperLayout: Int, CaseIterable, Identifiable, Codable {
    case mixedSize = 0
    case grid = 1
    case spiral = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .mixedSize: return "大小混合"
        case .grid: return "网格排列"
        case .spiral: return "螺旋"
        }
    }

    public var subtitle: String {
        switch self {
        case .mixedSize: return "居中对齐的网格里，按规律交替放大、缩小表情，错落有致"
        case .grid: return "相同大小的表情居中排成整齐网格"
        case .spiral: return "漩涡状从中心向外排布：中间的表情小，越靠近边缘越大"
        }
    }
}

/// 画板可组合的功能模块
public enum CanvasModule: Int, CaseIterable, Identifiable, Codable {
    case clock = 0
    case date = 1
    case cpu = 2
    case memory = 3
    case network = 4
    case nowPlaying = 5
    case pomodoro = 6
    case uptime = 7
    case text = 8
    case image = 9
    case qwenQuota = 10
    case codex = 11
    /// 口袋先知轮换语录（仅供口袋先知画板）
    case oracleText = 12
    /// 摘录轮换语录（仅供摘录画板）
    case excerptText = 13
    /// 少数派推荐文章（三个画板通用）
    case sspai = 14
    /// 磁盘占用（系统监控磁盘用量；三个画板通用）
    case disk = 15
    /// Home Assistant 实体状态（三个画板通用）
    case homeAssistant = 16
    /// Bambu Lab 打印机状态（三个画板通用，映射到 Home Assistant 设备实体）；
    /// 与卡片管理一致，每台打印机一个独立模块（bambuLab→第 1 台、bambuLab2→第 2 台…）
    case bambuLab = 17
    case bambuLab2 = 18
    case bambuLab3 = 19
    case bambuLab4 = 20
    case bambuLab5 = 21
    /// Formlabs Dashboard 云端打印机状态（三个画板通用）；每台打印机一个独立模块。
    case formlabs = 22
    case formlabs2 = 23
    case formlabs3 = 24
    case formlabs4 = 25
    case formlabs5 = 26

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .clock: return "时钟"
        case .date: return "日期"
        case .cpu: return "CPU 占用"
        case .memory: return "内存占用"
        case .network: return "网络速率"
        case .nowPlaying: return "正在播放"
        case .pomodoro: return "番茄钟"
        case .uptime: return "运行时间"
        case .text: return "自定义文字"
        case .image: return "自定义图像"
        case .qwenQuota: return "千问额度"
        case .codex: return "Codex 用量"
        case .oracleText: return "先知语录"
        case .excerptText: return "摘录语录"
        case .sspai: return "少数派推荐"
        case .disk: return "磁盘占用"
        case .homeAssistant: return "Home Assistant"
        case .bambuLab: return "Bambu Lab 打印机"
        case .bambuLab2: return "Bambu Lab 打印机 2"
        case .bambuLab3: return "Bambu Lab 打印机 3"
        case .bambuLab4: return "Bambu Lab 打印机 4"
        case .bambuLab5: return "Bambu Lab 打印机 5"
        case .formlabs: return "Formlabs 打印机"
        case .formlabs2: return "Formlabs 打印机 2"
        case .formlabs3: return "Formlabs 打印机 3"
        case .formlabs4: return "Formlabs 打印机 4"
        case .formlabs5: return "Formlabs 打印机 5"
        }
    }

    public var icon: String {
        switch self {
        case .clock: return "clock"
        case .date: return "calendar"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "network"
        case .nowPlaying: return "music.note"
        case .pomodoro: return "timer"
        case .uptime: return "desktopcomputer"
        case .text: return "textformat"
        case .image: return "photo"
        case .qwenQuota: return "creditcard"
        case .codex: return "terminal"
        case .oracleText: return "sparkles"
        case .excerptText: return "quote.opening"
        case .sspai: return "newspaper"
        case .disk: return "internaldrive"
        case .homeAssistant: return "house"
        case .bambuLab, .bambuLab2, .bambuLab3, .bambuLab4, .bambuLab5,
             .formlabs, .formlabs2, .formlabs3, .formlabs4, .formlabs5: return "printer"
        }
    }

    /// 是否为实验性功能（Home Assistant / Bambu Lab，界面显示 Beta 徽标）
    public var isBeta: Bool {
        self == .homeAssistant || self == .bambuLab
            || self == .bambuLab2 || self == .bambuLab3
            || self == .bambuLab4 || self == .bambuLab5
            || self == .formlabs || self == .formlabs2 || self == .formlabs3
            || self == .formlabs4 || self == .formlabs5
    }

    /// Bambu 打印机模块对应的卡片位（0..4；非 Bambu 模块返回 nil）
    public var bambuSlotIndex: Int? {
        switch self {
        case .bambuLab: return 0
        case .bambuLab2: return 1
        case .bambuLab3: return 2
        case .bambuLab4: return 3
        case .bambuLab5: return 4
        default: return nil
        }
    }

    /// Formlabs 打印机模块对应的设备位（0...4；非 Formlabs 模块返回 nil）。
    public var formlabsSlotIndex: Int? {
        switch self {
        case .formlabs: return 0
        case .formlabs2: return 1
        case .formlabs3: return 2
        case .formlabs4: return 3
        case .formlabs5: return 4
        default: return nil
        }
    }

    /// 键盘画板可选模块（不含两个独立画板的语录模块）
    public static let keyboardModules: [CanvasModule] =
        allCases.filter { $0 != .oracleText && $0 != .excerptText }

    /// 口袋先知画板可选模块（含先知语录，不含摘录语录）
    public static let oraclePanelModules: [CanvasModule] =
        [.oracleText] + allCases.filter { $0 != .oracleText && $0 != .excerptText }

    /// 摘录画板可选模块（含摘录语录，不含先知语录）
    public static let excerptPanelModules: [CanvasModule] =
        [.excerptText] + allCases.filter { $0 != .oracleText && $0 != .excerptText }
}

/// 键盘独立番茄钟卡片的刷新对齐策略。
/// 以本轮番茄钟的起点为基准，使电脑预览与键盘都显示同一个间隔刻度；
/// 例如 5 秒时为 `25:00 → 24:55 → 24:50`，不会因定时器或网络耗时漂移。
public enum PomodoroRefreshPolicy {
    public static let defaultIntervalSeconds = 5

    public static func alignedRemainingSeconds(_ remaining: TimeInterval,
                                               duration: TimeInterval,
                                               intervalSeconds: Int) -> Int {
        let interval = min(max(intervalSeconds, 2), 60)
        let displayedSeconds = max(0, Int(ceil(remaining)))
        guard displayedSeconds > 0 else { return 0 }
        let durationSeconds = max(displayedSeconds, Int(ceil(duration)))
        let elapsedSeconds = max(0, durationSeconds - displayedSeconds)
        let completedIntervals = elapsedSeconds / interval
        return max(0, durationSeconds - completedIntervals * interval)
    }
}

/// 高频刷新策略集中在纯数据层，避免 UI 每秒无条件重绘整张卡片。
public enum RuntimePerformancePolicy {
    private static let systemModules: Set<CanvasModule> =
        [.cpu, .memory, .network, .disk, .uptime]

    public static func needsSystemSample(modules: [CanvasModule]) -> Bool {
        !systemModules.isDisjoint(with: modules)
    }

    /// 当前卡片预览所需的刷新间隔。真正按秒变化的内容仍保持 1 秒；
    /// 静态 HA / 打印机 /额度等内容随动态推送周期刷新，避免主线程空转。
    public static func previewInterval(mode: DisplayMode,
                                       canvasModules: [CanvasModule],
                                       timeFormat: String,
                                       nowPlaying: Bool,
                                       pomodoroRunning: Bool,
                                       dynamicUploadSeconds: Int,
                                       pomodoroUploadSeconds: Int = PomodoroRefreshPolicy.defaultIntervalSeconds) -> TimeInterval {
        switch mode {
        case .systemMonitor:
            return 1
        case .pomodoro:
            return pomodoroRunning ? TimeInterval(min(max(pomodoroUploadSeconds, 2), 60)) : 10
        case .nowPlaying:
            return nowPlaying ? 1 : 10
        case .canvas:
            if needsSystemSample(modules: canvasModules) { return 1 }
            if canvasModules.contains(.pomodoro), pomodoroRunning { return 1 }
            if canvasModules.contains(.nowPlaying), nowPlaying { return 1 }
            if canvasModules.contains(.clock), timeFormat.contains("s") { return 1 }
            if canvasModules.contains(.clock) || canvasModules.contains(.date)
                || canvasModules.contains(.uptime) {
                return 30
            }
            return TimeInterval(max(5, dynamicUploadSeconds))
        case .customImage:
            return timeFormat.contains("s") ? 1 : 30
        case .excerptQuote, .sspai:
            return 30
        case .codex, .qwenWork, .emojiWallpaper, .homeAssistant,
             .bambuLab, .bambuLab2, .bambuLab3, .bambuLab4, .bambuLab5,
             .formlabs, .formlabs2, .formlabs3, .formlabs4, .formlabs5:
            return TimeInterval(max(5, dynamicUploadSeconds))
        }
    }

    /// 独立墨水屏画板只在内容可能快速变化时每 5 秒比较一次；
    /// 静态/分钟级内容降到 30 秒，仍能在一分钟内及时更新。
    public static func deviceCanvasContentCheckInterval(modules: [CanvasModule],
                                                        timeFormat: String,
                                                        nowPlaying: Bool,
                                                        pomodoroRunning: Bool) -> TimeInterval {
        if needsSystemSample(modules: modules) { return 5 }
        if modules.contains(.pomodoro), pomodoroRunning { return 5 }
        if modules.contains(.nowPlaying), nowPlaying { return 5 }
        if modules.contains(.clock), timeFormat.contains("s") { return 5 }
        return 30
    }

    /// 墨水屏自动推送只发送实际发生变化的最终画面。没有成功推送基线时必须发送，
    /// 以保证首次启用、应用重启或切换设备后的第一帧可以正常到达设备。
    public static func shouldPushInkDisplay(previousFingerprint: Data?,
                                            currentFingerprint: Data?) -> Bool {
        guard let currentFingerprint else { return false }
        guard let previousFingerprint else { return true }
        return previousFingerprint != currentFingerprint
    }
}

/// 画板打印机模块的显示信息选项（每个画板模块独立配置；决定模块内渲染哪些行）
public struct CanvasPrinterFields: Codable, Equatable {
    /// 工作状态（打印机名 + 状态大字）
    public var showStatus: Bool
    /// 打印进度条（含百分比）
    public var showProgress: Bool
    /// 当前任务名
    public var showTask: Bool
    /// 喷嘴温度
    public var showNozzleTemp: Bool
    /// 热床温度
    public var showBedTemp: Bool
    /// 剩余时间
    public var showRemaining: Bool
    /// 错误码 / 故障原因
    public var showError: Bool
    /// 画面（打印机摄像头快照 / 模型封面；默认关闭，开启且本轮拉到图片时占一行）
    public var showImage: Bool

    public init(showStatus: Bool = true, showProgress: Bool = true, showTask: Bool = false,
                showNozzleTemp: Bool = false, showBedTemp: Bool = false,
                showRemaining: Bool = false, showError: Bool = true, showImage: Bool = false) {
        self.showStatus = showStatus
        self.showProgress = showProgress
        self.showTask = showTask
        self.showNozzleTemp = showNozzleTemp
        self.showBedTemp = showBedTemp
        self.showRemaining = showRemaining
        self.showError = showError
        self.showImage = showImage
    }

    public static let `default` = CanvasPrinterFields()

    /// 已开启的行数（用于把模块高度均分给各行；至少 1 行避免空白）
    /// - Parameter hasPicture: 本轮是否真的拿到画面；没有画面时图片行不占位
    public func enabledRowCount(hasPicture: Bool = false) -> Int {
        var rows = [showStatus, showProgress, showTask, showNozzleTemp, showBedTemp,
                    showRemaining, showError].filter { $0 }.count
        if showImage && hasPicture { rows += 1 }
        return max(1, rows)
    }

    /// 兼容旧调用：不区分是否含画面
    public var enabledRowCount: Int { enabledRowCount() }

    // 旧档案缺字段时回退默认选项
    private enum CodingKeys: String, CodingKey {
        case showStatus, showProgress, showTask, showNozzleTemp, showBedTemp, showRemaining, showError, showImage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showStatus = try c.decodeIfPresent(Bool.self, forKey: .showStatus) ?? true
        showProgress = try c.decodeIfPresent(Bool.self, forKey: .showProgress) ?? true
        showTask = try c.decodeIfPresent(Bool.self, forKey: .showTask) ?? false
        showNozzleTemp = try c.decodeIfPresent(Bool.self, forKey: .showNozzleTemp) ?? false
        showBedTemp = try c.decodeIfPresent(Bool.self, forKey: .showBedTemp) ?? false
        showRemaining = try c.decodeIfPresent(Bool.self, forKey: .showRemaining) ?? false
        showError = try c.decodeIfPresent(Bool.self, forKey: .showError) ?? true
        showImage = try c.decodeIfPresent(Bool.self, forKey: .showImage) ?? false
    }
}

/// 摘录语录分类（可多选勾选，轮换池 = 所选分类的语录合集）
public enum ExcerptQuoteCategory: Int, CaseIterable, Identifiable, Codable {
    case famousSayings = 0
    case movieQuotes = 1
    case poetry = 2
    case proverbs = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .famousSayings: return "名人名言"
        case .movieQuotes: return "经典电影台词"
        case .poetry: return "诗词名句"
        case .proverbs: return "谚语俗语"
        }
    }
}

/// 画板自定义图像的显示模式
public enum CanvasImageMode: Int, CaseIterable, Identifiable, Codable {
    case background = 0
    case overlay = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .background: return "背景（完整显示，模块叠加）"
        case .overlay: return "叠加（作为模块）"
        }
    }
}

/// 显示模式：1 位黑白 / 4 级灰阶
public enum OracleDisplayMode: Int, CaseIterable, Identifiable, Codable {
    case bw = 0
    case gray4 = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .bw: return "黑白（1 位）"
        case .gray4: return "4 级灰阶"
        }
    }
}

/// 口袋先知（Rand/0）灰阶转换算法
public enum OracleGrayAlgorithm: Int, CaseIterable, Identifiable, Codable {
    case luminosity = 0
    case average = 1
    case lightness = 2
    case redChannel = 3
    case greenChannel = 4
    case blueChannel = 5

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .luminosity: return "亮度加权"
        case .average: return "平均值"
        case .lightness: return "明度法"
        case .redChannel: return "红通道"
        case .greenChannel: return "绿通道"
        case .blueChannel: return "蓝通道"
        }
    }

    public var subtitle: String {
        switch self {
        case .luminosity: return "0.299R + 0.587G + 0.114B，符合人眼敏感度的标准加权"
        case .average: return "(R + G + B) ÷ 3，三通道等权平均"
        case .lightness: return "(max + min) ÷ 2，结果偏亮、对比柔和"
        case .redChannel: return "仅取红色通道的亮度"
        case .greenChannel: return "仅取绿色通道的亮度，人眼最敏感"
        case .blueChannel: return "仅取蓝色通道的亮度"
        }
    }
}

/// 口袋先知（Rand/0）抖动算法（参考官方墨水屏 ditherKernel 清单）
public enum OracleDitherKernel: Int, CaseIterable, Identifiable, Codable {
    case threshold = 0
    case none = 1
    case ordered = 2
    case floydSteinberg = 3
    case atkinson = 4
    case burkes = 5
    case sierra2 = 6
    case stucki = 7
    case jarvisJudiceNinke = 8

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .threshold: return "阈值（THRESHOLD）"
        case .none: return "不抖动（NONE）"
        case .ordered: return "有序抖动（ORDERED）"
        case .floydSteinberg: return "Floyd-Steinberg"
        case .atkinson: return "Atkinson"
        case .burkes: return "Burkes"
        case .sierra2: return "Sierra2"
        case .stucki: return "Stucki"
        case .jarvisJudiceNinke: return "Jarvis-Judice-Ninke"
        }
    }

    public var subtitle: String {
        switch self {
        case .threshold: return "按固定阈值（128）判黑/白，无灰度过渡"
        case .none: return "直接取最近的灰阶档，不做误差扩散"
        case .ordered: return "Bayer 4×4 矩阵，规则点阵纹理"
        case .floydSteinberg: return "误差扩散（7/16·3/16·5/16·1/16），官方默认算法，细节保留最好"
        case .atkinson: return "误差扩散（1/8×6 邻域），高光更干净"
        case .burkes: return "误差扩散（8/32 系），介于 FS 与 Sierra 之间"
        case .sierra2: return "误差扩散（4/16 系），与 Sierra-2 Lite 同族"
        case .stucki: return "误差扩散（8/42 系），纹理更细腻"
        case .jarvisJudiceNinke: return "误差扩散（7/48 系，12 邻域），最平滑但计算量大"
        }
    }
}

public enum CardTheme: Int, CaseIterable, Identifiable, Codable {
    case deepSpace = 0
    case minimalLight = 1
    case neonPurple = 2
    case amberTerminal = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .deepSpace: return "深空薄荷"
        case .minimalLight: return "明亮极简"
        case .neonPurple: return "霓虹紫"
        case .amberTerminal: return "琥珀终端"
        }
    }
}

public enum PomodoroPhase: Int, Codable {
    case idle = 0
    case focus = 1
    case shortBreak = 2
    case longBreak = 3
    case paused = 4
}

/// 应用界面外观（跟随系统 / 浅色 / 深色）。仅影响软件窗口，不影响键盘卡片主题。
public enum AppearanceMode: Int, CaseIterable, Identifiable, Codable {
    case system = 0
    case light = 1
    case dark = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

/// 番茄钟夸夸内容来源
public enum PraiseSource: Int, CaseIterable, Identifiable, Codable {
    case builtin = 0
    case hitokoto = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .builtin: return "内置夸夸语（随机轮换）"
        case .hitokoto: return "一言（每日随机）"
        }
    }
}

/// 背景底色：跟随软件明暗 / 深色 / 浅色 / 自定义。作用于推送到键盘的卡片画面。
public enum BackgroundTone: Int, CaseIterable, Identifiable, Codable {
    case system = 0
    case dark = 1
    case light = 2
    case custom = 3

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .system: return "跟随软件明暗"
        case .dark: return "深色"
        case .light: return "浅色"
        case .custom: return "自定义…"
        }
    }
}

/// 强调色：跟随主题 / 常用预设 / 自定义。作用于推送到键盘的卡片画面。
public enum AccentTone: Int, CaseIterable, Identifiable, Codable {
    case system = 0
    case blue = 1
    case purple = 2
    case pink = 3
    case orange = 4
    case green = 5
    case red = 6
    case graphite = 7
    case custom = 8

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .system: return "跟随主题"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .pink: return "粉色"
        case .orange: return "橙色"
        case .green: return "绿色"
        case .red: return "红色"
        case .graphite: return "石墨"
        case .custom: return "自定义…"
        }
    }
}

/// 画板底色模式：手动固定深色/浅色，不随电脑或软件主题同步
public enum CanvasBackgroundMode: Int, CaseIterable, Identifiable, Codable {
    case dark = 0
    case light = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .dark: return "深色底色"
        case .light: return "浅色底色"
        }
    }
}

/// Dot 服务端抖动方式（官方 image API 的 ditherType 参数）
public enum DotServerDitherType: Int, CaseIterable, Identifiable, Codable {
    case diffusion = 0
    case ordered = 1
    case none = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .diffusion: return "误差扩散（DIFFUSION）"
        case .ordered: return "有序抖动（ORDERED）"
        case .none: return "无（NONE）"
        }
    }

    /// 发送给服务端的参数值
    public var apiValue: String {
        switch self {
        case .diffusion: return "DIFFUSION"
        case .ordered: return "ORDERED"
        case .none: return "NONE"
        }
    }
}

/// Dot 服务端抖动核（官方 image API 的 ditherKernel 参数）
public enum DotServerDitherKernel: Int, CaseIterable, Identifiable, Codable {
    case threshold = 0
    case atkinson = 1
    case burkes = 2
    case floydSteinberg = 3
    case sierra2 = 4
    case stucki = 5
    case jarvisJudiceNinke = 6
    case diffusionRow = 7
    case diffusionColumn = 8
    case diffusion2D = 9

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .threshold: return "THRESHOLD（阈值）"
        case .atkinson: return "ATKINSON"
        case .burkes: return "BURKES"
        case .floydSteinberg: return "FLOYD_STEINBERG"
        case .sierra2: return "SIERRA2"
        case .stucki: return "STUCKI"
        case .jarvisJudiceNinke: return "JARVIS_JUDICE_NINKE"
        case .diffusionRow: return "DIFFUSION_ROW（行扩散）"
        case .diffusionColumn: return "DIFFUSION_COLUMN（列扩散）"
        case .diffusion2D: return "DIFFUSION_2D（二维扩散）"
        }
    }

    /// 发送给服务端的参数值
    public var apiValue: String {
        switch self {
        case .threshold: return "THRESHOLD"
        case .atkinson: return "ATKINSON"
        case .burkes: return "BURKES"
        case .floydSteinberg: return "FLOYD_STEINBERG"
        case .sierra2: return "SIERRA2"
        case .stucki: return "STUCKI"
        case .jarvisJudiceNinke: return "JARVIS_JUDICE_NINKE"
        case .diffusionRow: return "DIFFUSION_ROW"
        case .diffusionColumn: return "DIFFUSION_COLUMN"
        case .diffusion2D: return "DIFFUSION_2D"
        }
    }
}

/// 十六进制颜色工具（#RRGGBB）
public enum HexColor {
    public static func parse(_ hex: String) -> (CGFloat, CGFloat, CGFloat)? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        return (
            CGFloat((number >> 16) & 0xFF) / 255,
            CGFloat((number >> 8) & 0xFF) / 255,
            CGFloat(number & 0xFF) / 255
        )
    }

    public static func string(from red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> String {
        String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}

/// 外观颜色解析：把背景底色 / 强调色设置解析为具体颜色（nil 表示跟随系统默认）
public enum AppearanceResolver {
    public static func backgroundRGB(tone: BackgroundTone, customHex: String?) -> (CGFloat, CGFloat, CGFloat)? {
        switch tone {
        case .system: return nil
        case .dark: return (0.11, 0.11, 0.13)
        case .light: return (0.95, 0.95, 0.97)
        case .custom: return customHex.flatMap { HexColor.parse($0) }
        }
    }

    public static func accentRGB(tone: AccentTone, customHex: String?) -> (CGFloat, CGFloat, CGFloat)? {
        switch tone {
        case .system: return nil
        case .blue: return (0.00, 0.478, 1.00)
        case .purple: return (0.686, 0.322, 0.871)
        case .pink: return (1.00, 0.176, 0.333)
        case .orange: return (1.00, 0.584, 0.00)
        case .green: return (0.204, 0.780, 0.349)
        case .red: return (1.00, 0.231, 0.188)
        case .graphite: return (0.557, 0.557, 0.576)
        case .custom: return customHex.flatMap { HexColor.parse($0) }
        }
    }
}

// MARK: - Codex 用量快照

public struct UsageSnapshot: Equatable {
    public var remainingPercent: Int
    public var resetDate: Date?
    public var windowMinutes: Int?
    public var availableResetCount: Int
    public var planType: String?
    /// 实际额度来源名称。官方来源显示“Codex 官方”；CC Switch 会包含当前供应商名称。
    public var sourceName: String?
    /// 第三方来源可提供的额度原值与单位，供正方形屏幕提高信息密度。
    public var remainingValue: Double?
    public var usageUnit: String?
    public var sampledAt: Date?

    public init(remainingPercent: Int, resetDate: Date?, windowMinutes: Int?,
                availableResetCount: Int, planType: String?,
                sourceName: String? = nil, remainingValue: Double? = nil,
                usageUnit: String? = nil, sampledAt: Date? = nil) {
        self.remainingPercent = remainingPercent
        self.resetDate = resetDate
        self.windowMinutes = windowMinutes
        self.availableResetCount = availableResetCount
        self.planType = planType
        self.sourceName = sourceName
        self.remainingValue = remainingValue
        self.usageUnit = usageUnit
        self.sampledAt = sampledAt
    }

    public var windowTitle: String {
        switch windowMinutes {
        case let m? where m >= 10_080: return "本周剩余"
        case let m? where m >= 1_440: return "本日剩余"
        case 300: return "5 小时剩余"
        default: return "周期剩余"
        }
    }

    public var windowDescription: String {
        switch windowMinutes {
        case nil: return "当前周期"
        case let m? where m % 1_440 == 0: return "\(m / 1_440) 天周期"
        case let m? where m % 60 == 0: return "\(m / 60) 小时周期"
        case let m?: return "\(m) 分钟周期"
        }
    }

    /// 是否已读取到真实的 Codex 用量。全新安装和读取失败时保持 false，
    /// 避免把开发预览用的示例百分比误当成用户数据展示。
    public var isAvailable: Bool {
        resetDate != nil || windowMinutes != nil || planType != nil
    }

    /// 正式运行的空状态；示例数据只允许用于测试和预览。
    public static let empty = UsageSnapshot(
        remainingPercent: 0,
        resetDate: nil,
        windowMinutes: nil,
        availableResetCount: 0,
        planType: nil,
        sourceName: nil,
        remainingValue: nil,
        usageUnit: nil,
        sampledAt: nil
    )

}

// MARK: - 键盘图像 API 地址

/// 键盘地址构造：界面只让用户填 IP，完整端点由软件自动拼装。
public enum EndpointBuilder {
    public static let path = "/image/upload"

    /// 从完整端点提取主机部分（含端口），例如 http://192.168.1.5/image/upload → 192.168.1.5
    public static func host(from endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host {
            if let port = url.port { return "\(host):\(port)" }
            return host
        }
        return trimmed
    }

    /// 由用户输入的 IP/主机拼出完整端点。兼容粘贴完整地址的情况。
    public static func endpoint(fromHost host: String) -> String {
        let input = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return "" }
        // 用户粘贴了完整地址（含协议）时，提取主机部分
        if let url = URL(string: input), url.scheme != nil, let hostPart = url.host {
            let port = url.port.map { ":\($0)" } ?? ""
            return "http://\(hostPart)\(port)\(path)"
        }
        let clean = input.replacingOccurrences(of: "/", with: "")
        if clean.isEmpty { return "" }
        return "http://\(clean)\(path)"
    }
}

// MARK: - 自定义图片历史记录

/// 最近使用的自定义图片记录（路径指向历史目录中的副本，随 settings.json 持久化）
public struct RecentImage: Codable, Identifiable, Equatable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var addedAt: Date

    public init(path: String, name: String, addedAt: Date = Date()) {
        self.path = path
        self.name = name
        self.addedAt = addedAt
    }

    /// 插入/置顶新记录（同路径去重），最多保留 `limit` 条，最近的在前。
    public static func upsert(_ entries: [RecentImage], new: RecentImage, limit: Int) -> [RecentImage] {
        var result = entries.filter { $0.path != new.path }
        result.insert(new, at: 0)
        return Array(result.prefix(limit))
    }
}

/// 最近图片轮换的切换方式
public enum ImageRotationMode: Int, CaseIterable, Identifiable, Codable {
    case sequential = 0
    case random = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .sequential: return "顺序切换"
        case .random: return "随机切换"
        }
    }
}

/// 轮换间隔的非线性滑杆映射：滑杆位置 0…1 ↔ 秒数 5…300。
/// 采用指数曲线，低段（短时间）档位细密，高段（长时间）档位粗疏。
public enum RotationInterval {
    public static let minSeconds = 5.0
    public static let maxSeconds = 300.0

    /// 滑杆位置（0…1）→ 秒数
    public static func seconds(fromSlider position: Double) -> Int {
        let t = min(max(position, 0), 1)
        let ratio = maxSeconds / minSeconds
        let value = minSeconds * pow(ratio, t)
        return Int(value.rounded())
    }

    /// 秒数 → 滑杆位置（0…1）
    public static func slider(fromSeconds seconds: Int) -> Double {
        let ratio = maxSeconds / minSeconds
        let s = min(max(Double(seconds), minSeconds), maxSeconds)
        return log(s / minSeconds) / log(ratio)
    }

    /// 人类可读的间隔文案
    public static func label(forSeconds seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        let rem = seconds % 60
        if rem == 0 { return "\(minutes) 分钟" }
        return "\(minutes) 分 \(rem) 秒"
    }
}

/// 自定义图片上的时钟叠加布局（跟随系统时间，分钟级刷新）
public enum CustomImageClockOverlay: Int, CaseIterable, Identifiable, Codable {
    case none = 0
    case horizontalTop = 1
    case horizontalBottom = 2
    case verticalLeft = 3
    case verticalCenter = 4

    /// 只保留不叠加与两种 Pixel 叠排大时钟；横向值仅用于兼容旧设置解码。
    public static let allCases: [CustomImageClockOverlay] = [.none, .verticalLeft, .verticalCenter]

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .none: return "不叠加"
        case .horizontalTop: return "Pixel 大时钟 · 顶部"
        case .horizontalBottom: return "Pixel 大时钟 · 底部"
        case .verticalLeft: return "Pixel 叠排大时钟 · 上方"
        case .verticalCenter: return "Pixel 叠排大时钟 · 居中"
        }
    }

    /// 旧横向布局迁移到位置语义最接近的叠排布局。
    public var stackedOnly: CustomImageClockOverlay {
        switch self {
        case .horizontalTop: return .verticalLeft
        case .horizontalBottom: return .verticalCenter
        case .none, .verticalLeft, .verticalCenter: return self
        }
    }
}

/// Pixel 叠排时钟整体图层组的有效尺寸范围。每一档都直接对应统一缩放比例，
/// 不再存在旧 18…96 范围中因内部最小/最大字号钳制而无效的区段。
public enum StackedClockSizing {
    public static let minimum = 32
    public static let maximum = 42
    public static let defaultValue = 42
    /// 数字本体之外的浅色轮廓半径；随整个时钟图层组一起缩放。
    public static let outlineExpansion: CGFloat = 5
    /// 覆盖 428px 画布的大部分垂直行程，同时保留精确到 1px 的微调。
    public static let minimumYOffset = -160
    public static let maximumYOffset = 160

    public static func scale(for value: Int) -> CGFloat {
        CGFloat(min(max(value, minimum), maximum)) / CGFloat(maximum)
    }

    public static func percent(for value: Int) -> Int {
        Int((scale(for: value) * 100).rounded())
    }
}

/// 自定义图片时钟的 Material 动态取色变体。
/// 三档对应 Pixel 常见的 Tonal Spot / Vibrant / Expressive 视觉方向。
public enum WallpaperColorStyle: Int, CaseIterable, Identifiable, Codable {
    case natural = 0
    case vibrant = 1
    case expressive = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .natural: return "自然"
        case .vibrant: return "鲜艳"
        case .expressive: return "表现力"
        }
    }

    public var description: String {
        switch self {
        case .natural: return "保持壁纸种子色相，层次柔和"
        case .vibrant: return "提高色度，让强调色更鲜明"
        case .expressive: return "偏移色相，形成更强的配色层次"
        }
    }
}

/// 叠加时钟字体粗细（Helvetica Neue 字重，Pixel 锁屏时钟风格）
public enum ClockFontWeight: Int, CaseIterable, Identifiable, Codable {
    case ultraLight = 0
    case thin = 1
    case light = 2
    case regular = 3
    case medium = 4
    case bold = 5

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .ultraLight: return "极细"
        case .thin: return "纤细"
        case .light: return "细体"
        case .regular: return "常规"
        case .medium: return "中粗"
        case .bold: return "粗体"
        }
    }

    /// 新版锁屏时钟只提供清晰字重；旧档案中的纤细字重仍可解码，但渲染时提升为中粗。
    public static let modernCases: [ClockFontWeight] = [.regular, .medium, .bold]

    public var modernized: ClockFontWeight {
        switch self {
        case .ultraLight, .thin, .light: return .medium
        case .regular, .medium, .bold: return self
        }
    }

    /// 对应的 Helvetica Neue PostScript 字体名
    public var fontName: String {
        switch self {
        case .ultraLight: return "HelveticaNeue-UltraLight"
        case .thin: return "HelveticaNeue-Thin"
        case .light: return "HelveticaNeue-Light"
        case .regular: return "HelveticaNeue-Regular"
        case .medium: return "HelveticaNeue-Medium"
        case .bold: return "HelveticaNeue-Bold"
        }
    }
}

/// 叠加时钟字体家族（按字重解析为具体 PostScript 字体名）
public enum ClockFont: Int, CaseIterable, Identifiable, Codable {
    case helveticaNeue = 0   // 默认，Pixel 锁屏风格
    case pingfang = 1        // 苹方
    case songti = 2          // 宋体
    case kaiti = 3           // 楷体
    case timesNewRoman = 4   // Times New Roman
    case courier = 5         // Courier New
    case menlo = 6           // Menlo 等宽

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .helveticaNeue: return "Helvetica Neue"
        case .pingfang: return "苹方 PingFang"
        case .songti: return "宋体 Songti"
        case .kaiti: return "楷体 Kaiti"
        case .timesNewRoman: return "Times New Roman"
        case .courier: return "Courier New"
        case .menlo: return "Menlo 等宽"
        }
    }

    /// 按字重解析为具体 PostScript 字体名；无对应字重的家族回退到最接近的字重
    public func fontName(weight: ClockFontWeight) -> String {
        switch self {
        case .helveticaNeue:
            switch weight {
            case .ultraLight: return "HelveticaNeue-UltraLight"
            case .thin: return "HelveticaNeue-Thin"
            case .light: return "HelveticaNeue-Light"
            case .regular: return "HelveticaNeue-Regular"
            case .medium: return "HelveticaNeue-Medium"
            case .bold: return "HelveticaNeue-Bold"
            }
        case .pingfang:
            switch weight {
            case .ultraLight: return "PingFangSC-Ultralight"
            case .thin: return "PingFangSC-Thin"
            case .light: return "PingFangSC-Light"
            case .regular: return "PingFangSC-Regular"
            case .medium: return "PingFangSC-Medium"
            case .bold: return "PingFangSC-Semibold"
            }
        case .songti:
            switch weight {
            case .ultraLight, .thin, .light: return "STSongti-SC-Light"
            case .regular: return "STSongti-SC-Regular"
            case .medium, .bold: return "STSongti-SC-Bold"
            }
        case .kaiti:
            switch weight {
            case .medium, .bold: return "STKaitiSC-Bold"
            default: return "STKaitiSC-Regular"
            }
        case .timesNewRoman:
            switch weight {
            case .medium, .bold: return "TimesNewRomanPS-BoldMT"
            default: return "TimesNewRomanPSMT"
            }
        case .courier:
            switch weight {
            case .medium, .bold: return "CourierNewPS-BoldMT"
            default: return "CourierNewPSMT"
            }
        case .menlo:
            switch weight {
            case .medium, .bold: return "Menlo-Bold"
            default: return "Menlo-Regular"
            }
        }
    }
}

/// 口袋先知按键信号控制的设备（display mode 会把按键回传给当前连接的客户端）
public enum Rand0ButtonTarget: Int, CaseIterable, Identifiable, Codable {
    case oracle = 0
    case keyboard = 1
    case excerpt = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .oracle: return "口袋先知自身"
        case .keyboard: return "灵犀68 键盘"
        case .excerpt: return "摘录"
        }
    }

    public var subtitle: String {
        switch self {
        case .oracle: return "下键短按：手动更新口袋先知画布（重新渲染并推送）"
        case .keyboard: return "上键/下键短按：在灵犀68 键盘的卡片列表中上下翻页（上一张/下一张，循环）"
        case .excerpt: return "下键短按：切换到 Dot 云端内容列表的下一项（云端仅提供下一条接口）"
        }
    }
}

// MARK: - 设备管理

/// 设备类型
public enum DeviceType: Int, CaseIterable, Identifiable, Codable, Hashable {
    case keyboard = 0
    case oracle = 1
    case excerpt = 2
    case homeAssistant = 3
    case bambuLab = 4
    case formlabs = 5
    case aiMacScreen = 6

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .keyboard: return "灵犀68 键盘"
        case .oracle: return "口袋先知"
        case .excerpt: return "摘录"
        case .homeAssistant: return "Home Assistant"
        case .bambuLab: return "Bambu Lab 打印机"
        case .formlabs: return "Formlabs 打印机"
        case .aiMacScreen: return "AI Mac 小屏幕"
        }
    }
}

/// 新建画板的命名规则：空画板先显示“未命名”，第一次添加模块时才使用
/// 第一个模块的显示名称；用户已主动命名或画板已有模块时绝不覆盖。
public enum CanvasBoardNamingPolicy {
    public static let untitledName = "未命名"

    public static func nameAfterAddingFirstModule(currentName: String,
                                                  currentModules: [Int],
                                                  moduleTitle: String) -> String {
        guard currentModules.isEmpty,
              currentName.trimmingCharacters(in: .whitespacesAndNewlines) == untitledName else {
            return currentName
        }
        let title = moduleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? currentName : title
    }
}

/// 口袋先知画板：一块完整画布配置快照（模块组合/显示模式/灰阶/抖动/底色/旋转/sspai/横向排布）。
/// 一台先知设备可保存多块画板，按键控制目标为自身时上下键在画板间循环切换并推送。
public struct OracleCanvasBoard: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// 是否显示在所属口袋先知设备的侧边栏中。nil 为旧档案，按显示处理。
    public var sidebarVisible: Bool?
    /// 是否参与自动轮播。nil 为旧档案，按参与处理。
    public var rotationEnabled: Bool?
    public var modules: [Int]
    public var backgroundMode: CanvasBackgroundMode
    public var imageRotate180: Bool
    public var displayMode: OracleDisplayMode
    public var grayAlgorithm: OracleGrayAlgorithm
    public var ditherKernel: OracleDitherKernel
    public var sspaiCount: Int
    public var sspaiRandom: Bool
    public var nowPlayingHorizontal: Bool
    /// 后续补充的完整画布字段均为可选，确保旧版本已保存的画板仍可解码。
    public var printerFields: [Int: CanvasPrinterFields]?
    public var haEntityIDs: [String]?
    public var imagePath: String?
    public var imageName: String?
    public var capturesExtendedFields: Bool?

    public init(id: UUID = UUID(), name: String,
                sidebarVisible: Bool? = true, rotationEnabled: Bool? = true,
                modules: [Int],
                backgroundMode: CanvasBackgroundMode, imageRotate180: Bool,
                displayMode: OracleDisplayMode, grayAlgorithm: OracleGrayAlgorithm,
                ditherKernel: OracleDitherKernel, sspaiCount: Int, sspaiRandom: Bool,
                nowPlayingHorizontal: Bool,
                printerFields: [Int: CanvasPrinterFields]? = nil,
                haEntityIDs: [String]? = nil,
                imagePath: String? = nil, imageName: String? = nil,
                capturesExtendedFields: Bool? = nil) {
        self.id = id
        self.name = name
        self.sidebarVisible = sidebarVisible
        self.rotationEnabled = rotationEnabled
        self.modules = modules
        self.backgroundMode = backgroundMode
        self.imageRotate180 = imageRotate180
        self.displayMode = displayMode
        self.grayAlgorithm = grayAlgorithm
        self.ditherKernel = ditherKernel
        self.sspaiCount = sspaiCount
        self.sspaiRandom = sspaiRandom
        self.nowPlayingHorizontal = nowPlayingHorizontal
        self.printerFields = printerFields
        self.haEntityIDs = haEntityIDs
        self.imagePath = imagePath
        self.imageName = imageName
        self.capturesExtendedFields = capturesExtendedFields
    }

    /// 从全局设置捕获当前先知画布配置
    public static func capture(from s: AppSettings) -> OracleCanvasBoard {
        OracleCanvasBoard(name: "画板 \(s.oracleCanvasBoards.count + 1)",
                          modules: s.oracleCanvasModules,
                          backgroundMode: s.oracleBackgroundMode,
                          imageRotate180: s.oracleImageRotate180,
                          displayMode: s.oracleDisplayMode,
                          grayAlgorithm: s.oracleGrayAlgorithm,
                          ditherKernel: s.oracleDitherKernel,
                          sspaiCount: s.oracleSspaiCount,
                          sspaiRandom: s.oracleSspaiRandom,
                          nowPlayingHorizontal: s.oracleNowPlayingHorizontal,
                          printerFields: s.oracleCanvasPrinterFields,
                          haEntityIDs: s.oracleCanvasHAEntityIDs,
                          imagePath: s.oracleCanvasImagePath,
                          imageName: s.oracleCanvasImageName,
                          capturesExtendedFields: true)
    }

    /// 创建一块不继承当前功能模块的新画板。设备级显示参数仍沿用当前设置，
    /// 但画板内容从空白开始，等待用户添加第一个模块后再自动命名。
    public static func blank(from s: AppSettings) -> OracleCanvasBoard {
        var board = capture(from: s)
        board.name = CanvasBoardNamingPolicy.untitledName
        board.modules = []
        return board
    }

    /// 自动保存时刷新配置内容，但画板身份与用户名称保持不变。
    public func updatingConfiguration(from s: AppSettings) -> OracleCanvasBoard {
        var updated = OracleCanvasBoard.capture(from: s)
        updated.id = id
        updated.name = name
        updated.sidebarVisible = sidebarVisible
        updated.rotationEnabled = rotationEnabled
        return updated
    }

    public var isSidebarVisible: Bool { sidebarVisible ?? true }
    public var participatesInRotation: Bool { rotationEnabled ?? true }

    /// 把本画板配置套用到全局设置（当前画布即为本画板）
    public func apply(to s: AppSettings) {
        s.oracleCanvasModules = modules
        s.oracleBackgroundMode = backgroundMode
        s.oracleImageRotate180 = imageRotate180
        s.oracleDisplayMode = displayMode
        s.oracleGrayAlgorithm = grayAlgorithm
        s.oracleDitherKernel = ditherKernel
        s.oracleSspaiCount = sspaiCount
        s.oracleSspaiRandom = sspaiRandom
        s.oracleNowPlayingHorizontal = nowPlayingHorizontal
        if capturesExtendedFields == true {
            s.oracleCanvasPrinterFields = printerFields ?? [:]
            s.oracleCanvasHAEntityIDs = haEntityIDs ?? []
            s.oracleCanvasImagePath = imagePath
            s.oracleCanvasImageName = imageName
        } else {
            // 旧画板没有扩展字段时保持旧行为，不清空用户现有的图片与实体选择。
            if let printerFields { s.oracleCanvasPrinterFields = printerFields }
            if let haEntityIDs { s.oracleCanvasHAEntityIDs = haEntityIDs }
            if let imagePath { s.oracleCanvasImagePath = imagePath }
            if let imageName { s.oracleCanvasImageName = imageName }
        }
    }
}

/// 摘录多画板：一块完整的摘录画布配置快照。
/// 每台摘录设备分别保存自己的列表；切换设备时列表与当前下标随设备快照一同切换。
public struct ExcerptCanvasBoard: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// 是否显示在所属摘录设备的侧边栏与系统菜单中。nil 为旧档案，按显示处理。
    public var sidebarVisible: Bool?
    /// 是否参与自动轮播。nil 为旧档案，按参与处理。
    public var rotationEnabled: Bool?
    public var modules: [Int]
    public var backgroundMode: CanvasBackgroundMode
    public var imageRotate180: Bool
    public var layoutColumns: Int
    public var fullWidthModules: [Int]
    public var pushRawImage: Bool
    public var serverDitherType: DotServerDitherType
    public var serverDitherKernel: DotServerDitherKernel
    public var displayMode: OracleDisplayMode
    public var grayAlgorithm: OracleGrayAlgorithm
    public var ditherKernel: OracleDitherKernel
    public var sspaiCount: Int
    public var sspaiRandom: Bool
    public var nowPlayingHorizontal: Bool
    public var printerFields: [Int: CanvasPrinterFields]
    public var haEntityIDs: [String]
    public var imagePath: String?
    public var imageName: String?
    public var quoteCategories: [Int]
    public var showQuoteSource: Bool

    public init(id: UUID = UUID(), name: String,
                sidebarVisible: Bool? = true, rotationEnabled: Bool? = true,
                modules: [Int],
                backgroundMode: CanvasBackgroundMode, imageRotate180: Bool,
                layoutColumns: Int, fullWidthModules: [Int], pushRawImage: Bool,
                serverDitherType: DotServerDitherType,
                serverDitherKernel: DotServerDitherKernel,
                displayMode: OracleDisplayMode, grayAlgorithm: OracleGrayAlgorithm,
                ditherKernel: OracleDitherKernel, sspaiCount: Int, sspaiRandom: Bool,
                nowPlayingHorizontal: Bool, printerFields: [Int: CanvasPrinterFields],
                haEntityIDs: [String], imagePath: String?, imageName: String?,
                quoteCategories: [Int], showQuoteSource: Bool) {
        self.id = id
        self.name = name
        self.sidebarVisible = sidebarVisible
        self.rotationEnabled = rotationEnabled
        self.modules = modules
        self.backgroundMode = backgroundMode
        self.imageRotate180 = imageRotate180
        self.layoutColumns = layoutColumns
        self.fullWidthModules = fullWidthModules
        self.pushRawImage = pushRawImage
        self.serverDitherType = serverDitherType
        self.serverDitherKernel = serverDitherKernel
        self.displayMode = displayMode
        self.grayAlgorithm = grayAlgorithm
        self.ditherKernel = ditherKernel
        self.sspaiCount = sspaiCount
        self.sspaiRandom = sspaiRandom
        self.nowPlayingHorizontal = nowPlayingHorizontal
        self.printerFields = printerFields
        self.haEntityIDs = haEntityIDs
        self.imagePath = imagePath
        self.imageName = imageName
        self.quoteCategories = quoteCategories
        self.showQuoteSource = showQuoteSource
    }

    public static func capture(from s: AppSettings) -> ExcerptCanvasBoard {
        ExcerptCanvasBoard(name: "画板 \(s.excerptCanvasBoards.count + 1)",
                           modules: s.excerptCanvasModules,
                           backgroundMode: s.excerptBackgroundMode,
                           imageRotate180: s.excerptImageRotate180,
                           layoutColumns: s.excerptLayoutColumns,
                           fullWidthModules: s.excerptFullWidthModules,
                           pushRawImage: s.excerptPushRawImage,
                           serverDitherType: s.excerptServerDitherType,
                           serverDitherKernel: s.excerptServerDitherKernel,
                           displayMode: s.excerptDisplayMode,
                           grayAlgorithm: s.excerptGrayAlgorithm,
                           ditherKernel: s.excerptDitherKernel,
                           sspaiCount: s.excerptSspaiCount,
                           sspaiRandom: s.excerptSspaiRandom,
                           nowPlayingHorizontal: s.excerptNowPlayingHorizontal,
                           printerFields: s.excerptCanvasPrinterFields,
                           haEntityIDs: s.excerptCanvasHAEntityIDs,
                           imagePath: s.excerptCanvasImagePath,
                           imageName: s.excerptCanvasImageName,
                           quoteCategories: s.excerptQuoteCategories,
                           showQuoteSource: s.showExcerptSource)
    }

    /// 与口袋先知保持一致：新建时为空模块、未命名，首个模块决定默认名称。
    public static func blank(from s: AppSettings) -> ExcerptCanvasBoard {
        var board = capture(from: s)
        board.name = CanvasBoardNamingPolicy.untitledName
        board.modules = []
        board.fullWidthModules = []
        return board
    }

    /// 自动保存时刷新配置内容，但画板身份与用户名称保持不变。
    public func updatingConfiguration(from s: AppSettings) -> ExcerptCanvasBoard {
        var updated = ExcerptCanvasBoard.capture(from: s)
        updated.id = id
        updated.name = name
        updated.sidebarVisible = sidebarVisible
        updated.rotationEnabled = rotationEnabled
        return updated
    }

    public var isSidebarVisible: Bool { sidebarVisible ?? true }
    public var participatesInRotation: Bool { rotationEnabled ?? true }

    public func apply(to s: AppSettings) {
        s.excerptCanvasModules = modules
        s.excerptBackgroundMode = backgroundMode
        s.excerptImageRotate180 = imageRotate180
        s.excerptLayoutColumns = layoutColumns
        s.excerptFullWidthModules = fullWidthModules
        s.excerptPushRawImage = pushRawImage
        s.excerptServerDitherType = serverDitherType
        s.excerptServerDitherKernel = serverDitherKernel
        s.excerptDisplayMode = displayMode
        s.excerptGrayAlgorithm = grayAlgorithm
        s.excerptDitherKernel = ditherKernel
        s.excerptSspaiCount = sspaiCount
        s.excerptSspaiRandom = sspaiRandom
        s.excerptNowPlayingHorizontal = nowPlayingHorizontal
        s.excerptCanvasPrinterFields = printerFields
        s.excerptCanvasHAEntityIDs = haEntityIDs
        s.excerptCanvasImagePath = imagePath
        s.excerptCanvasImageName = imageName
        s.excerptQuoteCategories = quoteCategories
        s.showExcerptSource = showQuoteSource
    }
}

/// 单台设备的设置快照（仅设备相关字段；切换设备时整体捕获/套用，每台设备各自记住设置）
public struct DeviceSettings: Codable, Equatable {
    // 连接信息
    public var endpoint: String?
    public var rand0IP: String?
    public var dotApiKey: String?
    public var dotDeviceId: String?
    // 灵犀68 键盘画板
    public var customImagePath: String?
    public var customImageName: String?
    public var canvasModules: [Int]?
    public var canvasModuleMargins: [Int: Int]?
    /// 画板打印机模块显示信息选项（key=CanvasModule.rawValue；每台画板设备独立，互不串扰）
    public var canvasPrinterFields: [Int: CanvasPrinterFields]?
    public var canvasText: String?
    public var canvasClockFormat: String?
    public var canvasDateFormat: String?
    public var canvasNowPlayingCover: Bool?
    public var canvasNowPlayingSmartBg: Bool?
    public var canvasNowPlayingTitleSize: Int?
    public var canvasNowPlayingArtistSize: Int?
    public var canvasImageMode: CanvasImageMode?
    public var canvasSspaiCount: Int?
    public var canvasSspaiRandom: Bool?
    // 灵犀68 屏幕控制（按设备记录）
    public var safeAreaHeight: Int?
    public var jpegQuality: Int?
    public var dynamicUploadSeconds: Int?
    public var pomodoroUploadSeconds: Int?
    public var cardRotationEnabled: Bool?
    public var cardRotationMinutes: Int?
    public var cardRotationModes: [Int]?
    /// 键盘设备侧栏可见卡片（有序；nil = 旧设备未配置，回退侧栏排序；[] = 无卡片，新设备默认）
    public var keyboardCardPanels: [String]?
    /// 系统监控卡片：网络速率是否用折线图（键盘卡片内容，每台键盘独立）
    public var networkChart: Bool?
    /// 当前显示的卡片（每台键盘记住自己的卡片，切换设备互不干扰）
    public var displayMode: DisplayMode?
    /// 键盘卡片主题（每台键盘独立）
    public var cardTheme: CardTheme?
    /// 系统监控卡片显示区块（每台键盘独立）
    public var showCpu: Bool?
    public var showMemory: Bool?
    public var showNetwork: Bool?
    public var showUptime: Bool?
    public var showDisk: Bool?
    /// 番茄钟卡片内容（每台键盘独立；番茄钟全局快捷键仍为全局）
    public var pomodoroPraiseEnabled: Bool?
    public var pomodoroPraiseSource: PraiseSource?
    public var pomodoroTaskFontSize: Int?
    /// 千问额度卡片显示方式（每台键盘独立）
    public var qwenQuotaShowPercent: Bool?
    /// 摘录语录卡片内容（分类轮换池 / 是否显示出处；每台键盘独立）
    public var excerptQuoteCategories: [Int]?
    public var showExcerptSource: Bool?
    /// Home Assistant 卡片：本键盘要显示的实体（有序；实体池全局共享，
    /// 但每台键盘卡片展示哪些实体、按什么顺序展示互相独立）
    public var haCardEntityIDs: [String]?
    /// 三类画板各自的 HA 模块实体列表；nil 表示旧档案尚无此字段，[] 表示用户明确不显示实体。
    public var canvasHAEntityIDs: [String]?
    public var oracleCanvasHAEntityIDs: [String]?
    public var excerptCanvasHAEntityIDs: [String]?
    /// 口袋先知画板打印机模块显示选项（独立字段：不与键盘画板共用，避免同步时互相覆盖）
    public var oracleCanvasPrinterFields: [Int: CanvasPrinterFields]?
    /// 摘录画板打印机模块显示选项（同上）
    public var excerptCanvasPrinterFields: [Int: CanvasPrinterFields]?
    public var nowPlayingTitleSize: Int?
    public var nowPlayingArtistSize: Int?
    public var nowPlayingFooterVisible: Bool?
    public var nowPlayingTimeFormat: String?
    public var nowPlayingDateFormat: String?
    public var nowPlayingTimeSize: Int?
    public var nowPlayingDateSize: Int?
    public var clockFontSize: Int?
    public var clockTimeFormat: String?
    public var clockFontWeight: ClockFontWeight?
    public var clockFont: ClockFont?
    /// 时钟叠加水平偏移（px，正值向右）
    public var clockOffsetX: Int?
    /// 时钟叠加垂直偏移（px，正值向下）
    public var clockOffsetY: Int?
    public var customImageClock: CustomImageClockOverlay?
    public var wallpaperColorStyle: WallpaperColorStyle?
    public var clockDateVisible: Bool?
    public var imageRotationEnabled: Bool?
    public var imageRotationSeconds: Int?
    public var imageRotationMode: ImageRotationMode?
    public var emojiWallpaperText: String?
    public var emojiWallpaperSize: Int?
    public var emojiWallpaperSpacing: Int?
    public var emojiWallpaperLayout: EmojiWallpaperLayout?
    // 口袋先知画板
    public var oracleCanvasModules: [Int]?
    public var oracleBackgroundMode: CanvasBackgroundMode?
    public var oracleImageRotate180: Bool?
    public var oracleDisplayMode: OracleDisplayMode?
    public var oracleGrayAlgorithm: OracleGrayAlgorithm?
    public var oracleDitherKernel: OracleDitherKernel?
    public var oracleAutoPushEnabled: Bool?
    public var oracleAutoPushMinutes: Int?
    public var oracleBoardRotationEnabled: Bool?
    public var oracleBoardRotationMinutes: Int?
    public var oracleSspaiCount: Int?
    public var oracleSspaiRandom: Bool?
    public var oracleNowPlayingHorizontal: Bool?
    /// 口袋先知“正在播放”可把同步歌词联动到指定灵犀 68 键盘。
    public var oracleLyricsKeyboardDeviceID: UUID?
    /// 多画板：保存的画板列表 + 当前画板下标（切换画板时把该画板配置套用到当前画布字段）
    public var oracleCanvasBoards: [OracleCanvasBoard]?
    public var oracleCanvasBoardIndex: Int?
    public var rand0ButtonTarget: Rand0ButtonTarget?
    /// 按键控制目标的具体设备 ID（键盘/摘录类目标时指向某台具体设备；nil = 当前活动设备）
    public var rand0ButtonTargetDeviceID: UUID?
    // 摘录画板
    public var excerptCanvasModules: [Int]?
    public var excerptBackgroundMode: CanvasBackgroundMode?
    public var excerptImageRotate180: Bool?
    public var excerptLayoutColumns: Int?
    public var excerptFullWidthModules: [Int]?
    public var excerptPushRawImage: Bool?
    public var excerptServerDitherType: DotServerDitherType?
    public var excerptServerDitherKernel: DotServerDitherKernel?
    public var excerptDisplayMode: OracleDisplayMode?
    public var excerptGrayAlgorithm: OracleGrayAlgorithm?
    public var excerptDitherKernel: OracleDitherKernel?
    public var excerptAutoPushEnabled: Bool?
    public var excerptAutoPushMinutes: Int?
    public var excerptBoardRotationEnabled: Bool?
    public var excerptBoardRotationMinutes: Int?
    public var excerptSspaiCount: Int?
    public var excerptSspaiRandom: Bool?
    public var excerptNowPlayingHorizontal: Bool?
    public var excerptCanvasQuoteCategories: [Int]?
    public var excerptCanvasShowQuoteSource: Bool?
    /// 摘录多画板：按设备独立保存的画板列表及当前选中下标。
    public var excerptCanvasBoards: [ExcerptCanvasBoard]?
    public var excerptCanvasBoardIndex: Int?
    // Home Assistant（实体与异常监控按设备独立记录）
    /// 旧档案字段：服务器地址/令牌/刷新间隔已收归全局共享配置（所有设备只有一个 Home Assistant 服务器），
    /// 仅保留用于读取旧设置文件，不再随设备 capture/apply 搬运。
    public var haServerURL: String?
    public var haToken: String?
    public var haRefreshMinutes: Int?
    public var haEntityID: String?
    /// 多实体列表（顺序即卡片显示顺序；旧版单实体 haEntityID 迁移为首项）
    public var haEntities: [String]?
    /// 实体自定义显示名称（entity_id → 别名；卡片渲染优先使用，未设置用默认名）
    public var haEntityAliases: [String: String]?
    public var haMonitorEnabled: Bool?
    public var haMonitorEntityID: String?
    public var haMonitorExpectedState: String?
    public var haMonitorErrorEntityID: String?
    // Bambu Lab 打印机卡片（字段实体映射 + 告警开关，按 HA 设备独立）
    public var bambuPrinterName: String?
    public var bambuEnableAlert: Bool?
    public var bambuStatusEntityID: String?
    public var bambuProgressEntityID: String?
    public var bambuTaskEntityID: String?
    public var bambuNozzleTempEntityID: String?
    public var bambuBedTempEntityID: String?
    public var bambuRemainingEntityID: String?
    /// 预计结束/完成时间实体；nil 兼容旧档案。
    public var bambuEndTimeEntityID: String?
    /// 时间区块显示模式；nil 兼容旧档案并视为剩余时间。
    public var bambuTimeDisplayMode: BambuTimeDisplayMode?
    public var bambuErrorEntityID: String?
    /// 自动匹配是否使用默认打印状态候选筛选；nil 兼容旧档案并视为开启。
    /// 关闭后允许用户从全部 sensor 实体中指定改名后的打印状态实体。
    public var bambuUseDefaultEntityFilter: Bool?
    /// 摄像头实体（旧字段名保留，兼容已发布配置）
    public var bambuImageEntityID: String?
    /// 当前打印任务封面实体
    public var bambuTaskImageEntityID: String?
    /// 卡片画面来源（摄像头 / 任务图片）
    public var bambuImageSource: BambuImageSource?
    /// 每次推送前分析摄像头静态帧并自动放大小模型；nil 兼容旧档案并视为关闭。
    public var bambuAutoCameraZoom: Bool?
    /// 卡片布局样式（标准/紧凑/大字；详情页可切换，每台打印机独立）
    public var bambuLayout: BambuCardLayout?
    /// 卡片主题色（跟随全局 / Bambu Lab 强调色）
    public var bambuThemeAccent: BambuThemeAccent?
    /// 各区块显示开关（详情页可切换；关闭后对应区块不渲染）
    public var bambuShowStatus: Bool?
    public var bambuShowProgress: Bool?
    public var bambuShowTask: Bool?
    public var bambuShowTemperature: Bool?
    public var bambuShowRemaining: Bool?
    public var bambuShowError: Bool?
    /// 画面区块开关（已映射画面实体且拉到图片时才渲染）
    public var bambuShowImage: Bool?
    /// 多打印机配置列表（每台打印机独立映射与告警；旧版单台字段迁移为首台）
    public var bambuPrinters: [BambuLabCardSettings]?
    // Formlabs Dashboard API 连接配置直接保存在打印机设备快照中，不经过全局镜像。
    public var formlabsConnection: FormlabsConnectionSettings?
    /// ESP8266 AI Mac 240×240 小屏幕：每台设备独立保存，不经过全局镜像。
    public var aiMacScreen: AIMacScreenDeviceSettings?
    /// 画板图像模块自己的图片（先知/摘录设备各自独立，与键盘自定义图片解耦）
    public var canvasImagePath: String?
    public var canvasImageName: String?

    public init() {}

    /// 从活动设置捕获该类型设备的全部相关字段
    public static func capture(from s: AppSettings, type: DeviceType) -> DeviceSettings {
        var d = DeviceSettings()
        switch type {
        case .keyboard:
            d.endpoint = s.endpoint
            d.customImagePath = s.customImagePath
            d.customImageName = s.customImageName
            d.canvasModules = s.canvasModules
            d.canvasModuleMargins = s.canvasModuleMargins
            d.canvasPrinterFields = s.canvasPrinterFields
            d.canvasText = s.canvasText
            d.canvasNowPlayingCover = s.canvasNowPlayingCover
            d.canvasNowPlayingSmartBg = s.canvasNowPlayingSmartBg
            d.canvasNowPlayingTitleSize = s.canvasNowPlayingTitleSize
            d.canvasNowPlayingArtistSize = s.canvasNowPlayingArtistSize
            d.canvasImageMode = s.canvasImageMode
            d.canvasSspaiCount = s.canvasSspaiCount
            d.canvasSspaiRandom = s.canvasSspaiRandom
            d.safeAreaHeight = s.safeAreaHeight
            d.jpegQuality = s.jpegQuality
            d.dynamicUploadSeconds = s.dynamicUploadSeconds
            d.pomodoroUploadSeconds = s.pomodoroUploadSeconds
            d.cardRotationEnabled = s.cardRotationEnabled
            d.cardRotationMinutes = s.cardRotationMinutes
            d.cardRotationModes = s.cardRotationModes
            d.keyboardCardPanels = s.keyboardCardPanels
            d.networkChart = s.networkChart
            d.displayMode = s.displayMode
            d.cardTheme = s.cardTheme
            d.showCpu = s.showCpu
            d.showMemory = s.showMemory
            d.showNetwork = s.showNetwork
            d.showUptime = s.showUptime
            d.showDisk = s.showDisk
            d.pomodoroPraiseEnabled = s.pomodoroPraiseEnabled
            d.pomodoroPraiseSource = s.pomodoroPraiseSource
            d.pomodoroTaskFontSize = s.pomodoroTaskFontSize
            d.qwenQuotaShowPercent = s.qwenQuotaShowPercent
            d.excerptQuoteCategories = s.excerptQuoteCategories
            d.showExcerptSource = s.showExcerptSource
            d.haCardEntityIDs = s.haCardEntityIDs
            d.canvasHAEntityIDs = s.canvasHAEntityIDs
            d.nowPlayingTitleSize = s.nowPlayingTitleSize
            d.nowPlayingArtistSize = s.nowPlayingArtistSize
            d.nowPlayingFooterVisible = s.nowPlayingFooterVisible
            d.nowPlayingTimeSize = s.nowPlayingTimeSize
            d.nowPlayingDateSize = s.nowPlayingDateSize
            d.clockFontSize = s.clockFontSize
            d.clockFontWeight = s.clockFontWeight
            d.clockFont = s.clockFont
            d.clockOffsetX = s.clockOffsetX
            d.clockOffsetY = s.clockOffsetY
            d.customImageClock = s.customImageClock
            d.wallpaperColorStyle = s.wallpaperColorStyle
            d.clockDateVisible = s.clockDateVisible
            d.imageRotationEnabled = s.imageRotationEnabled
            d.imageRotationSeconds = s.imageRotationSeconds
            d.imageRotationMode = s.imageRotationMode
            d.emojiWallpaperText = s.emojiWallpaperText
            d.emojiWallpaperSize = s.emojiWallpaperSize
            d.emojiWallpaperSpacing = s.emojiWallpaperSpacing
            d.emojiWallpaperLayout = s.emojiWallpaperLayout
        case .oracle:
            d.rand0IP = s.rand0IP
            d.oracleCanvasModules = s.oracleCanvasModules
            d.oracleBackgroundMode = s.oracleBackgroundMode
            d.oracleImageRotate180 = s.oracleImageRotate180
            d.oracleDisplayMode = s.oracleDisplayMode
            d.oracleGrayAlgorithm = s.oracleGrayAlgorithm
            d.oracleDitherKernel = s.oracleDitherKernel
            d.oracleAutoPushEnabled = s.oracleAutoPushEnabled
            d.oracleAutoPushMinutes = s.oracleAutoPushMinutes
            d.oracleBoardRotationEnabled = s.oracleBoardRotationEnabled
            d.oracleBoardRotationMinutes = s.oracleBoardRotationMinutes
            d.oracleSspaiCount = s.oracleSspaiCount
            d.oracleSspaiRandom = s.oracleSspaiRandom
            d.oracleNowPlayingHorizontal = s.oracleNowPlayingHorizontal
            d.oracleCanvasPrinterFields = s.oracleCanvasPrinterFields
            d.oracleCanvasHAEntityIDs = s.oracleCanvasHAEntityIDs
            d.oracleCanvasBoards = s.oracleCanvasBoards
            d.oracleCanvasBoardIndex = s.oracleCanvasBoardIndex
            d.canvasImagePath = s.oracleCanvasImagePath
            d.canvasImageName = s.oracleCanvasImageName
            d.rand0ButtonTarget = s.rand0ButtonTarget
            d.rand0ButtonTargetDeviceID = s.rand0ButtonTargetDeviceID
        case .excerpt:
            d.dotApiKey = s.dotApiKey
            d.dotDeviceId = s.dotDeviceId
            d.excerptCanvasModules = s.excerptCanvasModules
            d.excerptBackgroundMode = s.excerptBackgroundMode
            d.excerptImageRotate180 = s.excerptImageRotate180
            d.excerptLayoutColumns = s.excerptLayoutColumns
            d.excerptFullWidthModules = s.excerptFullWidthModules
            d.excerptPushRawImage = s.excerptPushRawImage
            d.excerptServerDitherType = s.excerptServerDitherType
            d.excerptServerDitherKernel = s.excerptServerDitherKernel
            d.excerptDisplayMode = s.excerptDisplayMode
            d.excerptGrayAlgorithm = s.excerptGrayAlgorithm
            d.excerptDitherKernel = s.excerptDitherKernel
            d.excerptAutoPushEnabled = s.excerptAutoPushEnabled
            d.excerptAutoPushMinutes = s.excerptAutoPushMinutes
            d.excerptBoardRotationEnabled = s.excerptBoardRotationEnabled
            d.excerptBoardRotationMinutes = s.excerptBoardRotationMinutes
            d.excerptSspaiCount = s.excerptSspaiCount
            d.excerptSspaiRandom = s.excerptSspaiRandom
            d.excerptNowPlayingHorizontal = s.excerptNowPlayingHorizontal
            d.excerptCanvasQuoteCategories = s.excerptQuoteCategories
            d.excerptCanvasShowQuoteSource = s.showExcerptSource
            d.excerptCanvasBoards = s.excerptCanvasBoards
            d.excerptCanvasBoardIndex = s.excerptCanvasBoardIndex
            d.excerptCanvasPrinterFields = s.excerptCanvasPrinterFields
            d.excerptCanvasHAEntityIDs = s.excerptCanvasHAEntityIDs
            d.canvasImagePath = s.excerptCanvasImagePath
            d.canvasImageName = s.excerptCanvasImageName
        case .homeAssistant:
            d.haServerURL = s.haServerURL
            d.haToken = s.haToken
            d.haRefreshMinutes = s.haRefreshMinutes
            d.haEntityID = s.haEntityID
            d.haEntities = s.haEntities
            d.haEntityAliases = s.haEntityAliases
            d.haMonitorEnabled = s.haMonitorEnabled
            d.haMonitorEntityID = s.haMonitorEntityID
            d.haMonitorExpectedState = s.haMonitorExpectedState
            d.haMonitorErrorEntityID = s.haMonitorErrorEntityID
            // 打印机实体映射的逐字段（bambuStatusEntityID 等）只由 .bambuLab 设备记录：
            // 这里若再捕获同一批全局镜像，切换 HA 设备会把 HA 快照里的旧映射写回镜像，
            // 下一次同步又把它盖到打印机设备快照上（跨设备串扰）；仅保留旧版多打印机列表。
            d.bambuPrinters = s.bambuPrinters
        case .bambuLab:
            d.bambuPrinterName = s.bambuPrinterName
            d.bambuEnableAlert = s.bambuEnableAlert
            d.bambuStatusEntityID = s.bambuStatusEntityID
            d.bambuProgressEntityID = s.bambuProgressEntityID
            d.bambuTaskEntityID = s.bambuTaskEntityID
            d.bambuNozzleTempEntityID = s.bambuNozzleTempEntityID
            d.bambuBedTempEntityID = s.bambuBedTempEntityID
            d.bambuRemainingEntityID = s.bambuRemainingEntityID
            d.bambuEndTimeEntityID = s.bambuEndTimeEntityID
            d.bambuTimeDisplayMode = s.bambuTimeDisplayMode
            d.bambuErrorEntityID = s.bambuErrorEntityID
            d.bambuImageEntityID = s.bambuImageEntityID
            d.bambuTaskImageEntityID = s.bambuTaskImageEntityID
            d.bambuImageSource = s.bambuImageSource
            d.bambuAutoCameraZoom = s.bambuAutoCameraZoom
            d.bambuShowImage = s.bambuShowImage
            d.bambuLayout = s.bambuLayout
            d.bambuThemeAccent = s.bambuThemeAccent
            d.bambuShowStatus = s.bambuShowStatus
            d.bambuShowProgress = s.bambuShowProgress
            d.bambuShowTask = s.bambuShowTask
            d.bambuShowTemperature = s.bambuShowTemperature
            d.bambuShowRemaining = s.bambuShowRemaining
            d.bambuShowError = s.bambuShowError
        case .formlabs:
            // Formlabs 连接信息由 ManagedDevice.settings 直接持有；此处不从全局镜像覆盖。
            break
        case .aiMacScreen:
            // 小屏幕设置直接保存在 ManagedDevice.settings 中。
            break
        }
        return d
    }

    /// 把本快照套用到活动设置（nil 字段保留当前值，兼容旧档案）
    public func apply(to s: AppSettings, type: DeviceType) {
        switch type {
        case .keyboard:
            if let v = endpoint { s.endpoint = v }
            if let v = customImagePath { s.customImagePath = v }
            if let v = customImageName { s.customImageName = v }
            if let v = canvasModules { s.canvasModules = v }
            if let v = canvasModuleMargins { s.canvasModuleMargins = v }
            if let v = canvasPrinterFields { s.canvasPrinterFields = v }
            if let v = canvasText { s.canvasText = v }
            if let v = canvasNowPlayingCover { s.canvasNowPlayingCover = v }
            if let v = canvasNowPlayingSmartBg { s.canvasNowPlayingSmartBg = v }
            if let v = canvasNowPlayingTitleSize { s.canvasNowPlayingTitleSize = v }
            if let v = canvasNowPlayingArtistSize { s.canvasNowPlayingArtistSize = v }
            if let v = canvasImageMode { s.canvasImageMode = v }
            if let v = canvasSspaiCount { s.canvasSspaiCount = v }
            if let v = canvasSspaiRandom { s.canvasSspaiRandom = v }
            if let v = safeAreaHeight { s.safeAreaHeight = v }
            if let v = jpegQuality { s.jpegQuality = v }
            if let v = dynamicUploadSeconds { s.dynamicUploadSeconds = v }
            if let v = pomodoroUploadSeconds { s.pomodoroUploadSeconds = v }
            if let v = cardRotationEnabled { s.cardRotationEnabled = v }
            if let v = cardRotationMinutes { s.cardRotationMinutes = v }
            if let v = cardRotationModes { s.cardRotationModes = v }
            if let v = keyboardCardPanels { s.keyboardCardPanels = v }
            if let v = networkChart { s.networkChart = v }
            if let v = displayMode { s.displayMode = v }
            if let v = cardTheme { s.cardTheme = v }
            if let v = showCpu { s.showCpu = v }
            if let v = showMemory { s.showMemory = v }
            if let v = showNetwork { s.showNetwork = v }
            if let v = showUptime { s.showUptime = v }
            if let v = showDisk { s.showDisk = v }
            if let v = pomodoroPraiseEnabled { s.pomodoroPraiseEnabled = v }
            if let v = pomodoroPraiseSource { s.pomodoroPraiseSource = v }
            if let v = pomodoroTaskFontSize { s.pomodoroTaskFontSize = v }
            if let v = qwenQuotaShowPercent { s.qwenQuotaShowPercent = v }
            if let v = excerptQuoteCategories { s.excerptQuoteCategories = v }
            if let v = showExcerptSource { s.showExcerptSource = v }
            if let v = haCardEntityIDs { s.haCardEntityIDs = v }
            if let v = canvasHAEntityIDs { s.canvasHAEntityIDs = v }
            if let v = nowPlayingTitleSize { s.nowPlayingTitleSize = v }
            if let v = nowPlayingArtistSize { s.nowPlayingArtistSize = v }
            if let v = nowPlayingFooterVisible { s.nowPlayingFooterVisible = v }
            if let v = nowPlayingTimeSize { s.nowPlayingTimeSize = v }
            if let v = nowPlayingDateSize { s.nowPlayingDateSize = v }
            if let v = clockFontSize { s.clockFontSize = v }
            if let v = clockFontWeight { s.clockFontWeight = v }
            if let v = clockFont { s.clockFont = v }
            if let v = clockOffsetX { s.clockOffsetX = v }
            if let v = clockOffsetY { s.clockOffsetY = v }
            if let v = customImageClock { s.customImageClock = v.stackedOnly }
            if let v = wallpaperColorStyle { s.wallpaperColorStyle = v }
            if let v = clockDateVisible { s.clockDateVisible = v }
            if let v = imageRotationEnabled { s.imageRotationEnabled = v }
            if let v = imageRotationSeconds { s.imageRotationSeconds = v }
            if let v = imageRotationMode { s.imageRotationMode = v }
            if let v = emojiWallpaperText { s.emojiWallpaperText = v }
            if let v = emojiWallpaperSize { s.emojiWallpaperSize = v }
            if let v = emojiWallpaperSpacing { s.emojiWallpaperSpacing = v }
            if let v = emojiWallpaperLayout { s.emojiWallpaperLayout = v }
        case .oracle:
            if let v = rand0IP { s.rand0IP = v }
            if let v = oracleCanvasModules { s.oracleCanvasModules = v }
            if let v = oracleBackgroundMode { s.oracleBackgroundMode = v }
            if let v = oracleImageRotate180 { s.oracleImageRotate180 = v }
            if let v = oracleDisplayMode { s.oracleDisplayMode = v }
            if let v = oracleGrayAlgorithm { s.oracleGrayAlgorithm = v }
            if let v = oracleDitherKernel { s.oracleDitherKernel = v }
            if let v = oracleAutoPushEnabled { s.oracleAutoPushEnabled = v }
            if let v = oracleAutoPushMinutes { s.oracleAutoPushMinutes = v }
            // 旧设备快照没有轮换字段时必须明确回退默认值，避免切换设备后沿用上一台设置。
            s.oracleBoardRotationEnabled = oracleBoardRotationEnabled ?? false
            s.oracleBoardRotationMinutes = oracleBoardRotationMinutes ?? 5
            if let v = oracleSspaiCount { s.oracleSspaiCount = v }
            if let v = oracleSspaiRandom { s.oracleSspaiRandom = v }
            if let v = oracleNowPlayingHorizontal { s.oracleNowPlayingHorizontal = v }
            if let v = oracleCanvasPrinterFields { s.oracleCanvasPrinterFields = v }
            if let v = oracleCanvasHAEntityIDs { s.oracleCanvasHAEntityIDs = v }
            if let v = oracleCanvasBoards { s.oracleCanvasBoards = v }
            if let v = oracleCanvasBoardIndex { s.oracleCanvasBoardIndex = v }
            if let v = canvasImagePath { s.oracleCanvasImagePath = v }
            if let v = canvasImageName { s.oracleCanvasImageName = v }
            if let v = rand0ButtonTarget { s.rand0ButtonTarget = v }
            if let v = rand0ButtonTargetDeviceID { s.rand0ButtonTargetDeviceID = v }
        case .excerpt:
            if let v = dotApiKey { s.dotApiKey = v }
            if let v = dotDeviceId { s.dotDeviceId = v }
            if let v = excerptCanvasModules { s.excerptCanvasModules = v }
            if let v = excerptBackgroundMode { s.excerptBackgroundMode = v }
            if let v = excerptImageRotate180 { s.excerptImageRotate180 = v }
            if let v = excerptLayoutColumns { s.excerptLayoutColumns = v }
            if let v = excerptFullWidthModules { s.excerptFullWidthModules = v }
            if let v = excerptPushRawImage { s.excerptPushRawImage = v }
            if let v = excerptServerDitherType { s.excerptServerDitherType = v }
            if let v = excerptServerDitherKernel { s.excerptServerDitherKernel = v }
            if let v = excerptDisplayMode { s.excerptDisplayMode = v }
            if let v = excerptGrayAlgorithm { s.excerptGrayAlgorithm = v }
            if let v = excerptDitherKernel { s.excerptDitherKernel = v }
            if let v = excerptAutoPushEnabled { s.excerptAutoPushEnabled = v }
            if let v = excerptAutoPushMinutes { s.excerptAutoPushMinutes = v }
            s.excerptBoardRotationEnabled = excerptBoardRotationEnabled ?? false
            s.excerptBoardRotationMinutes = excerptBoardRotationMinutes ?? 5
            if let v = excerptSspaiCount { s.excerptSspaiCount = v }
            if let v = excerptSspaiRandom { s.excerptSspaiRandom = v }
            if let v = excerptNowPlayingHorizontal { s.excerptNowPlayingHorizontal = v }
            s.excerptQuoteCategories = excerptCanvasQuoteCategories
                ?? ExcerptQuoteCategory.allCases.map(\.rawValue)
            s.showExcerptSource = excerptCanvasShowQuoteSource ?? false
            // nil 表示旧版本快照；显式回退为空列表，不能沿用上一台摘录设备的画板。
            s.excerptCanvasBoards = excerptCanvasBoards ?? []
            s.excerptCanvasBoardIndex = excerptCanvasBoardIndex ?? 0
            if let v = excerptCanvasPrinterFields { s.excerptCanvasPrinterFields = v }
            if let v = excerptCanvasHAEntityIDs { s.excerptCanvasHAEntityIDs = v }
            if let v = canvasImagePath { s.excerptCanvasImagePath = v }
            if let v = canvasImageName { s.excerptCanvasImageName = v }
        case .homeAssistant:
            if let v = haServerURL { s.haServerURL = v }
            if let v = haToken { s.haToken = v }
            if let v = haRefreshMinutes { s.haRefreshMinutes = v }
            if let v = haEntityID { s.haEntityID = v }
            if let v = haEntities { s.haEntities = v }
            if let v = haEntityAliases { s.haEntityAliases = v }
            if let v = haMonitorEnabled { s.haMonitorEnabled = v }
            if let v = haMonitorEntityID { s.haMonitorEntityID = v }
            if let v = haMonitorExpectedState { s.haMonitorExpectedState = v }
            if let v = haMonitorErrorEntityID { s.haMonitorErrorEntityID = v }
            // 打印机实体映射字段不在此套用：它们属于 .bambuLab 设备，
            // 从旧的 HA 快照套用会覆盖当前打印机的映射（跨设备串扰）
            if let v = bambuPrinters { s.bambuPrinters = v }
        case .bambuLab:
            if let v = bambuPrinterName { s.bambuPrinterName = v }
            if let v = bambuEnableAlert { s.bambuEnableAlert = v }
            if let v = bambuStatusEntityID { s.bambuStatusEntityID = v }
            if let v = bambuProgressEntityID { s.bambuProgressEntityID = v }
            if let v = bambuTaskEntityID { s.bambuTaskEntityID = v }
            if let v = bambuNozzleTempEntityID { s.bambuNozzleTempEntityID = v }
            if let v = bambuBedTempEntityID { s.bambuBedTempEntityID = v }
            if let v = bambuRemainingEntityID { s.bambuRemainingEntityID = v }
            if let v = bambuEndTimeEntityID { s.bambuEndTimeEntityID = v }
            if let v = bambuTimeDisplayMode { s.bambuTimeDisplayMode = v }
            if let v = bambuErrorEntityID { s.bambuErrorEntityID = v }
            if let v = bambuImageEntityID { s.bambuImageEntityID = v }
            if let v = bambuTaskImageEntityID { s.bambuTaskImageEntityID = v }
            if let v = bambuImageSource { s.bambuImageSource = v }
            if let v = bambuAutoCameraZoom { s.bambuAutoCameraZoom = v }
            if let v = bambuShowImage { s.bambuShowImage = v }
            if let v = bambuLayout { s.bambuLayout = v }
            if let v = bambuThemeAccent { s.bambuThemeAccent = v }
            if let v = bambuShowStatus { s.bambuShowStatus = v }
            if let v = bambuShowProgress { s.bambuShowProgress = v }
            if let v = bambuShowTask { s.bambuShowTask = v }
            if let v = bambuShowTemperature { s.bambuShowTemperature = v }
            if let v = bambuShowRemaining { s.bambuShowRemaining = v }
            if let v = bambuShowError { s.bambuShowError = v }
        case .formlabs:
            break
        case .aiMacScreen:
            break
        }
    }
}

/// 一台受管设备（类型 + 名称 + 连接与画布设置快照）
public struct ManagedDevice: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var type: DeviceType
    public var name: String
    public var settings: DeviceSettings
    /// 临时禁用开关：禁用后左侧导航隐藏该设备（设置保留，可随时重新启用）
    public var isEnabled = true

    public init(type: DeviceType, name: String, settings: DeviceSettings) {
        self.type = type
        self.name = name
        self.settings = settings
        self.isEnabled = true
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try c.decode(DeviceType.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        settings = try c.decodeIfPresent(DeviceSettings.self, forKey: .settings) ?? DeviceSettings()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// 用户编辑设备名时原样保存输入；默认名只在创建设备时生成，不能在编辑过程中回填。
    public mutating func rename(to editedName: String) {
        name = editedName
    }

    /// 默认设备名（第 N 台）
    public static func defaultName(for type: DeviceType, index: Int) -> String {
        switch type {
        case .bambuLab: return "打印机 \(index + 1)"
        case .formlabs: return "Formlabs \(index + 1)"
        case .aiMacScreen: return "AI Mac 小屏幕 \(index + 1)"
        default: return "\(type.title) \(index + 1)"
        }
    }
}

// MARK: - 侧栏菜单排序

/// 侧栏菜单排序辅助（纯字符串，便于测试与跨模块复用）。
public enum MenuOrdering {
    /// 按用户配置的顺序排列可用标识；未知标识忽略；缺失项按可用顺序补在末尾；重复项去重。
    public static func ordered(_ order: [String], available: [String]) -> [String] {
        guard !order.isEmpty else { return available }
        let allowed = Set(available)
        var result: [String] = []
        for id in order where allowed.contains(id) && !result.contains(id) {
            result.append(id)
        }
        for id in available where !result.contains(id) {
            result.append(id)
        }
        return result
    }

    /// 分组过滤：从已排序列表中仅保留指定组（组内保持相对顺序）。
    /// 用于把键盘功能项与独立设备画板拆成两个独立排序分组。
    public static func grouped(_ ordered: [String], in group: Set<String>) -> [String] {
        ordered.filter { group.contains($0) }
    }
}

// MARK: - 番茄钟状态

public final class PomodoroState: Codable {
    public var phase: PomodoroPhase = .idle
    public var resumePhase: PomodoroPhase = .focus
    public var endsAt: Date?
    public var pausedRemainingSeconds: Int = 0
    public var completedFocusSessions: Int = 0
    public var taskName: String = "专注工作"
    public var focusMinutes: Int = 25
    public var shortBreakMinutes: Int = 5
    public var longBreakMinutes: Int = 15

    public init() {}

    enum CodingKeys: String, CodingKey {
        case phase, resumePhase, endsAt, pausedRemainingSeconds,
             completedFocusSessions, taskName, focusMinutes,
             shortBreakMinutes, longBreakMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = PomodoroPhase(rawValue: try c.decodeIfPresent(Int.self, forKey: .phase) ?? 0) ?? .idle
        resumePhase = PomodoroPhase(rawValue: try c.decodeIfPresent(Int.self, forKey: .resumePhase) ?? 1) ?? .focus
        endsAt = try c.decodeIfPresent(Date.self, forKey: .endsAt)
        pausedRemainingSeconds = try c.decodeIfPresent(Int.self, forKey: .pausedRemainingSeconds) ?? 0
        completedFocusSessions = try c.decodeIfPresent(Int.self, forKey: .completedFocusSessions) ?? 0
        taskName = try c.decodeIfPresent(String.self, forKey: .taskName) ?? "专注工作"
        focusMinutes = try c.decodeIfPresent(Int.self, forKey: .focusMinutes) ?? 25
        shortBreakMinutes = try c.decodeIfPresent(Int.self, forKey: .shortBreakMinutes) ?? 5
        longBreakMinutes = try c.decodeIfPresent(Int.self, forKey: .longBreakMinutes) ?? 15
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(phase.rawValue, forKey: .phase)
        try c.encode(resumePhase.rawValue, forKey: .resumePhase)
        try c.encodeIfPresent(endsAt, forKey: .endsAt)
        try c.encode(pausedRemainingSeconds, forKey: .pausedRemainingSeconds)
        try c.encode(completedFocusSessions, forKey: .completedFocusSessions)
        try c.encode(taskName, forKey: .taskName)
        try c.encode(focusMinutes, forKey: .focusMinutes)
        try c.encode(shortBreakMinutes, forKey: .shortBreakMinutes)
        try c.encode(longBreakMinutes, forKey: .longBreakMinutes)
    }
}

public struct PomodoroSnapshot {
    public var phase: PomodoroPhase
    public var effectivePhase: PomodoroPhase
    public var taskName: String
    public var remaining: TimeInterval
    public var duration: TimeInterval
    public var completedFocusSessions: Int
    public var endsAt: Date?

    public init(phase: PomodoroPhase, effectivePhase: PomodoroPhase, taskName: String,
                remaining: TimeInterval, duration: TimeInterval,
                completedFocusSessions: Int, endsAt: Date? = nil) {
        self.phase = phase
        self.effectivePhase = effectivePhase
        self.taskName = taskName
        self.remaining = remaining
        self.duration = duration
        self.completedFocusSessions = completedFocusSessions
        self.endsAt = endsAt
    }

    public var isRunning: Bool {
        phase == .focus || phase == .shortBreak || phase == .longBreak
    }

    public var isPaused: Bool { phase == .paused }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(1 - remaining / duration, 0), 1)
    }
}

// MARK: - 系统监控快照

public struct SystemSnapshot {
    public var cpuPercent: Double
    public var memoryPercent: Double
    public var usedMemoryBytes: UInt64
    public var totalMemoryBytes: UInt64
    public var diskPercent: Double
    public var usedDiskBytes: UInt64
    public var totalDiskBytes: UInt64
    public var downloadBytesPerSecond: Double
    public var uploadBytesPerSecond: Double
    public var uptime: TimeInterval
    public var sampledAt: Date

    public init(cpuPercent: Double, memoryPercent: Double,
                usedMemoryBytes: UInt64, totalMemoryBytes: UInt64,
                diskPercent: Double = 0, usedDiskBytes: UInt64 = 0, totalDiskBytes: UInt64 = 0,
                downloadBytesPerSecond: Double, uploadBytesPerSecond: Double,
                uptime: TimeInterval, sampledAt: Date) {
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.usedMemoryBytes = usedMemoryBytes
        self.totalMemoryBytes = totalMemoryBytes
        self.diskPercent = diskPercent
        self.usedDiskBytes = usedDiskBytes
        self.totalDiskBytes = totalDiskBytes
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.uptime = uptime
        self.sampledAt = sampledAt
    }

    public static let empty = SystemSnapshot(
        cpuPercent: 0, memoryPercent: 0, usedMemoryBytes: 0, totalMemoryBytes: 0,
        diskPercent: 0, usedDiskBytes: 0, totalDiskBytes: 0,
        downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
        uptime: ProcessInfo.processInfo.systemUptime, sampledAt: Date()
    )
}

/// 网络速率历史采样点（供网络折线图使用，时间升序，最新在末尾）
public struct NetworkSample: Equatable {
    public var downloadBytesPerSecond: Double
    public var uploadBytesPerSecond: Double

    public init(downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
    }
}

// MARK: - 全局快捷键

/// 全局快捷键组合（Carbon 虚拟键码 + 修饰键掩码），可持久化。
/// 修饰键位与 Carbon 一致：⌘=0x0100 ⇧=0x0200 ⌥=0x0800 ⌃=0x1000
public struct GlobalShortcut: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public static let cmdKey: UInt32 = 0x0100
    public static let shiftKey: UInt32 = 0x0200
    public static let optionKey: UInt32 = 0x0800
    public static let controlKey: UInt32 = 0x1000

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 番茄钟默认组合：⌃⌥Space 开始/暂停 · ⌃⌥→ 跳过 · ⌃⌥⌫ 重置
    public static let defaultToggle = GlobalShortcut(keyCode: 49, modifiers: controlKey | optionKey)
    public static let defaultSkip = GlobalShortcut(keyCode: 124, modifiers: controlKey | optionKey)
    public static let defaultReset = GlobalShortcut(keyCode: 51, modifiers: controlKey | optionKey)
    /// 灵犀68 手动翻页默认组合：⌃⌥↑ 上一页 · ⌃⌥↓ 下一页
    public static let defaultPageUp = GlobalShortcut(keyCode: 126, modifiers: controlKey | optionKey)
    public static let defaultPageDown = GlobalShortcut(keyCode: 125, modifiers: controlKey | optionKey)

    /// 功能键键码（可无修饰键注册全局快捷键）
    public static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        [64, 79, 80, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120, 122].contains(keyCode)
    }

    /// 显示字符串（如 ⌃⌥Space / ⌘1 / ⌃⌥→）
    public var displayString: String {
        var s = ""
        if modifiers & GlobalShortcut.controlKey != 0 { s += "⌃" }
        if modifiers & GlobalShortcut.optionKey != 0 { s += "⌥" }
        if modifiers & GlobalShortcut.shiftKey != 0 { s += "⇧" }
        if modifiers & GlobalShortcut.cmdKey != 0 { s += "⌘" }
        return s + Self.symbol(for: keyCode)
    }

    private static let keySymbols: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-",
        28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "⌫", 53: "Esc", 117: "⌦",
        64: "F17", 79: "F18", 80: "F19", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12",
        113: "F15", 118: "F4", 120: "F2", 122: "F1",
        115: "Home", 116: "PgUp", 119: "End", 121: "PgDn", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    private static func symbol(for keyCode: UInt32) -> String {
        keySymbols[keyCode] ?? "键\(keyCode)"
    }
}

extension GlobalShortcut {
    /// 钳制：键码 0–127，修饰键只保留 ⌘⇧⌥⌃
    func clamped() -> GlobalShortcut {
        GlobalShortcut(keyCode: min(keyCode, 127),
                       modifiers: modifiers & (GlobalShortcut.cmdKey | GlobalShortcut.shiftKey
                                               | GlobalShortcut.optionKey | GlobalShortcut.controlKey))
    }
}

// MARK: - Home Assistant

/// Home Assistant 实体（来自 GET /api/states 的解析结果）
public struct HAEntity: Codable, Equatable {
    public var entityId: String
    public var friendlyName: String
    public var state: String
    public var unitOfMeasurement: String?
    /// Material Design 图标名（由 attributes.icon 的 "mdi:xxx" 提取；无则 nil）
    public var icon: String?
    /// 状态最近变化时间（HA last_changed；用于判断错误码等状态是否过期）
    public var lastChanged: Date?
    /// 设备型号（attributes.model / series，如 "A1"；用于打印机型号识别）
    public var model: String?
    /// 图片地址（attributes.entity_picture；多为相对 Home Assistant 的路径，需补全并带令牌请求）
    public var entityPicture: String?

    public init(entityId: String, friendlyName: String, state: String,
                unitOfMeasurement: String?, icon: String? = nil, lastChanged: Date? = nil,
                model: String? = nil, entityPicture: String? = nil) {
        self.entityId = entityId
        self.friendlyName = friendlyName
        self.state = state
        self.unitOfMeasurement = unitOfMeasurement
        self.icon = icon
        self.lastChanged = lastChanged
        self.model = model
        self.entityPicture = entityPicture
    }

    /// 是否为可抓取静态帧的画面源：image.* 使用 entity_picture；camera.* 可走
    /// Home Assistant 的 camera_proxy 单帧接口，即使状态属性没有 entity_picture 也可用。
    public var hasPicture: Bool {
        domain == "camera" || (domain == "image" && !(entityPicture ?? "").isEmpty)
    }

    /// 实体域（entity_id 前缀，如 sensor / light；无点回退 unknown）
    public var domain: String {
        HAEntityPicker.domain(of: entityId)
    }

    /// 显示名：优先 friendly_name，缺失时用 entity_id
    public var displayName: String {
        friendlyName.isEmpty ? entityId : friendlyName
    }

    /// 状态显示值：常见状态中文化；HA 的 ISO8601 时间戳压缩为适合小屏的本地短时间。
    public var displayState: String {
        Self.compactDisplayState(state)
    }

    /// 把 HA 原始状态转换为适合 142pt 宽键盘屏的短文本。
    /// 图片实体经常把最后更新时间直接放在 state 中；完整 ISO8601 字符串会挤占整行，
    /// 因此统一显示为「MM-dd HH:mm」。非时间状态保持原样。
    public static func compactDisplayState(_ raw: String,
                                           timeZone: TimeZone = .current) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "on": return "开"
        case "off": return "关"
        case "unknown": return "未知"
        case "unavailable": return "不可用"
        case "none": return "无"
        default: break
        }

        // 普通数值、printing/idle 等状态占绝大多数；先做廉价形态判断，
        // 避免每次画板渲染都为每个实体创建 ISO8601DateFormatter。
        guard trimmed.count >= 19,
              trimmed.index(trimmed.startIndex, offsetBy: 4) < trimmed.endIndex,
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)] == "-",
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)] == "-",
              trimmed.contains("T") else {
            return trimmed
        }

        for parser in isoTimestampParsers {
            if let date = parser.date(from: trimmed) {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.timeZone = timeZone
                formatter.dateFormat = "MM-dd HH:mm"
                return formatter.string(from: date)
            }
        }

        return trimmed
    }

    private static let isoTimestampParsers: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return [fractional, standard]
    }()

    /// 完整显示串（含单位，如「23.5 °C」）
    public var displayValue: String {
        if let unit = unitOfMeasurement, !unit.isEmpty {
            return "\(displayState) \(unit)"
        }
        return displayState
    }

    /// 剩余时间的可读文本：Bambu Lab 的 remaining_time 常以小时为单位的浮点小数
    /// （如 0.383333333333333 h ≈ 23 分钟），直接显示原始值不可读，这里转为
    /// 「X 小时 Y 分钟 / X 分钟」；分钟单位同理；其余值原样返回。
    public var remainingDisplayText: String {
        let unit = (unitOfMeasurement ?? "").lowercased()
        guard let value = Double(state) else { return displayState }
        if ["h", "hr", "hrs", "hour", "hours", "小时"].contains(unit) {
            let totalMinutes = Int((value * 60).rounded())
            if totalMinutes >= 60 {
                return "\(totalMinutes / 60) 小时 \(totalMinutes % 60) 分钟"
            }
            return "\(totalMinutes) 分钟"
        }
        if ["min", "mins", "minute", "minutes", "分钟"].contains(unit) {
            return "\(Int(value.rounded())) 分钟"
        }
        return displayState
    }
}

/// Home Assistant 快照：实体列表 + 选中的多实体状态 + 错误信息
public struct HASnapshot: Equatable {
    public var entities: [HAEntity]
    /// 当前选中的实体状态（按设置中的实体列表顺序；旧版单实体兼容）
    public var selectedEntities: [HAEntity]
    public var selected: HAEntity? {
        selectedEntities.first
    }
    /// 实体自定义显示名称（entity_id → 别名；渲染优先使用）
    public var aliases: [String: String]
    public var errorText: String?
    public var sampledAt: Date
    /// 已绑定但当前服务器实体池中查不到的 entity_id（按绑定顺序）。
    /// 换服务器后同名实体不再存在时用于明确显示「失效」，而不是静默错绑或凭空消失。
    public var missingEntityIDs: [String]
    /// entity_id → 最后一次已知显示值（失效行保留原值、灰显）
    public var lastKnownValues: [String: String]
    /// entity_id → 图片字节（image.* 实体的 entity_picture 拉取结果；与实体同一轮更新，
    /// 所有卡片/画板共用同一份画面数据）
    public var images: [String: Data]

    public init(entities: [HAEntity] = [], selectedEntities: [HAEntity] = [],
                aliases: [String: String] = [:],
                errorText: String? = nil, sampledAt: Date = Date(),
                missingEntityIDs: [String] = [], lastKnownValues: [String: String] = [:],
                images: [String: Data] = [:]) {
        self.entities = entities
        self.selectedEntities = selectedEntities
        self.aliases = aliases
        self.errorText = errorText
        self.sampledAt = sampledAt
        self.missingEntityIDs = missingEntityIDs
        self.lastKnownValues = lastKnownValues
        self.images = images
    }

    /// 某实体对应的画面数据（无则 nil）
    public func picture(for entityID: String) -> Data? {
        images[entityID]
    }

    /// 由同一份服务器实体池生成某个消费者自己的选择视图（HA 卡片/三类画板可各持不同列表）。
    public func selecting(entityIDs: [String]) -> HASnapshot {
        guard !entityIDs.isEmpty else {
            var copy = self
            copy.selectedEntities = []
            copy.missingEntityIDs = []
            return copy
        }
        let wanted = Set(entityIDs)
        var byID: [String: HAEntity] = [:]
        byID.reserveCapacity(entityIDs.count)
        for entity in entities where wanted.contains(entity.entityId) {
            byID[entity.entityId] = entity
            if byID.count == wanted.count { break }
        }
        var copy = self
        copy.selectedEntities = entityIDs.compactMap { byID[$0] }
        copy.missingEntityIDs = entities.isEmpty ? [] : entityIDs.filter { byID[$0] == nil }
        return copy
    }

    /// 失效行渲染数据：(entity_id, 显示名, 最后一次已知值)
    public func missingRows() -> [(id: String, name: String, lastValue: String)] {
        missingEntityIDs.map { id in
            (id, aliases[id] ?? id, lastKnownValues[id] ?? "")
        }
    }

    /// 记录本批实体的显示值，供之后失效时回显原值
    public func rememberingValues(from entities: [HAEntity]) -> HASnapshot {
        var updated = self
        var values = updated.lastKnownValues
        for entity in entities { values[entity.entityId] = entity.displayValue }
        updated.lastKnownValues = values
        return updated
    }

    public static let empty = HASnapshot()
}
