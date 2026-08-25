import Foundation

// MARK: - 枚举

public enum DisplayMode: Int, CaseIterable, Identifiable, Codable {
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

    public init(remainingPercent: Int, resetDate: Date?, windowMinutes: Int?,
                availableResetCount: Int, planType: String?) {
        self.remainingPercent = remainingPercent
        self.resetDate = resetDate
        self.windowMinutes = windowMinutes
        self.availableResetCount = availableResetCount
        self.planType = planType
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

    /// 首次展示前的示例数据（与原版一致）
    public static let sample = UsageSnapshot(
        remainingPercent: 98,
        resetDate: Date().addingTimeInterval(5 * 24 * 3600),
        windowMinutes: 10_080,
        availableResetCount: 3,
        planType: "plus"
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

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .none: return "不叠加"
        case .horizontalTop: return "横向 · 顶部"
        case .horizontalBottom: return "横向 · 底部"
        case .verticalLeft: return "竖向 · 左侧"
        case .verticalCenter: return "竖向 · 居中"
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

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .ultraLight: return "极细"
        case .thin: return "纤细"
        case .light: return "细体"
        case .regular: return "常规"
        case .medium: return "中粗"
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
            }
        case .pingfang:
            switch weight {
            case .ultraLight: return "PingFangSC-Ultralight"
            case .thin: return "PingFangSC-Thin"
            case .light: return "PingFangSC-Light"
            case .regular: return "PingFangSC-Regular"
            case .medium: return "PingFangSC-Medium"
            }
        case .songti:
            switch weight {
            case .ultraLight, .thin, .light: return "STSongti-SC-Light"
            case .regular: return "STSongti-SC-Regular"
            case .medium: return "STSongti-SC-Bold"
            }
        case .kaiti:
            switch weight {
            case .medium: return "STKaitiSC-Bold"
            default: return "STKaitiSC-Regular"
            }
        case .timesNewRoman:
            switch weight {
            case .medium: return "TimesNewRomanPS-BoldMT"
            default: return "TimesNewRomanPSMT"
            }
        case .courier:
            switch weight {
            case .medium: return "CourierNewPS-BoldMT"
            default: return "CourierNewPSMT"
            }
        case .menlo:
            switch weight {
            case .medium: return "Menlo-Bold"
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
public enum DeviceType: Int, CaseIterable, Identifiable, Codable {
    case keyboard = 0
    case oracle = 1
    case excerpt = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .keyboard: return "灵犀68 键盘"
        case .oracle: return "口袋先知"
        case .excerpt: return "摘录"
        }
    }
}

/// 口袋先知画板：一块完整画布配置快照（模块组合/显示模式/灰阶/抖动/底色/旋转/sspai/横向排布）。
/// 一台先知设备可保存多块画板，按键控制目标为自身时上下键在画板间循环切换并推送。
public struct OracleCanvasBoard: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var modules: [Int]
    public var backgroundMode: CanvasBackgroundMode
    public var imageRotate180: Bool
    public var displayMode: OracleDisplayMode
    public var grayAlgorithm: OracleGrayAlgorithm
    public var ditherKernel: OracleDitherKernel
    public var sspaiCount: Int
    public var sspaiRandom: Bool
    public var nowPlayingHorizontal: Bool

    public init(id: UUID = UUID(), name: String, modules: [Int],
                backgroundMode: CanvasBackgroundMode, imageRotate180: Bool,
                displayMode: OracleDisplayMode, grayAlgorithm: OracleGrayAlgorithm,
                ditherKernel: OracleDitherKernel, sspaiCount: Int, sspaiRandom: Bool,
                nowPlayingHorizontal: Bool) {
        self.id = id
        self.name = name
        self.modules = modules
        self.backgroundMode = backgroundMode
        self.imageRotate180 = imageRotate180
        self.displayMode = displayMode
        self.grayAlgorithm = grayAlgorithm
        self.ditherKernel = ditherKernel
        self.sspaiCount = sspaiCount
        self.sspaiRandom = sspaiRandom
        self.nowPlayingHorizontal = nowPlayingHorizontal
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
                          nowPlayingHorizontal: s.oracleNowPlayingHorizontal)
    }

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
    public var cardRotationEnabled: Bool?
    public var cardRotationMinutes: Int?
    public var cardRotationModes: [Int]?
    /// 键盘设备侧栏可见卡片（有序；nil = 旧设备未配置，回退侧栏排序；[] = 无卡片，新设备默认）
    public var keyboardCardPanels: [String]?
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
    public var oracleSspaiCount: Int?
    public var oracleSspaiRandom: Bool?
    public var oracleNowPlayingHorizontal: Bool?
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
    public var excerptSspaiCount: Int?
    public var excerptSspaiRandom: Bool?
    public var excerptNowPlayingHorizontal: Bool?
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
            d.canvasText = s.canvasText
            d.canvasClockFormat = s.canvasClockFormat
            d.canvasDateFormat = s.canvasDateFormat
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
            d.cardRotationEnabled = s.cardRotationEnabled
            d.cardRotationMinutes = s.cardRotationMinutes
            d.cardRotationModes = s.cardRotationModes
            d.keyboardCardPanels = s.keyboardCardPanels
            d.nowPlayingTitleSize = s.nowPlayingTitleSize
            d.nowPlayingArtistSize = s.nowPlayingArtistSize
            d.nowPlayingFooterVisible = s.nowPlayingFooterVisible
            d.nowPlayingTimeFormat = s.nowPlayingTimeFormat
            d.nowPlayingDateFormat = s.nowPlayingDateFormat
            d.nowPlayingTimeSize = s.nowPlayingTimeSize
            d.nowPlayingDateSize = s.nowPlayingDateSize
            d.clockFontSize = s.clockFontSize
            d.clockTimeFormat = s.clockTimeFormat
            d.clockFontWeight = s.clockFontWeight
            d.clockFont = s.clockFont
            d.clockOffsetX = s.clockOffsetX
            d.clockOffsetY = s.clockOffsetY
            d.customImageClock = s.customImageClock
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
            d.oracleSspaiCount = s.oracleSspaiCount
            d.oracleSspaiRandom = s.oracleSspaiRandom
            d.oracleNowPlayingHorizontal = s.oracleNowPlayingHorizontal
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
            d.excerptSspaiCount = s.excerptSspaiCount
            d.excerptSspaiRandom = s.excerptSspaiRandom
            d.excerptNowPlayingHorizontal = s.excerptNowPlayingHorizontal
            d.canvasImagePath = s.excerptCanvasImagePath
            d.canvasImageName = s.excerptCanvasImageName
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
            if let v = canvasText { s.canvasText = v }
            if let v = canvasClockFormat { s.canvasClockFormat = v }
            if let v = canvasDateFormat { s.canvasDateFormat = v }
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
            if let v = cardRotationEnabled { s.cardRotationEnabled = v }
            if let v = cardRotationMinutes { s.cardRotationMinutes = v }
            if let v = cardRotationModes { s.cardRotationModes = v }
            if let v = keyboardCardPanels { s.keyboardCardPanels = v }
            if let v = nowPlayingTitleSize { s.nowPlayingTitleSize = v }
            if let v = nowPlayingArtistSize { s.nowPlayingArtistSize = v }
            if let v = nowPlayingFooterVisible { s.nowPlayingFooterVisible = v }
            if let v = nowPlayingTimeFormat { s.nowPlayingTimeFormat = v }
            if let v = nowPlayingDateFormat { s.nowPlayingDateFormat = v }
            if let v = nowPlayingTimeSize { s.nowPlayingTimeSize = v }
            if let v = nowPlayingDateSize { s.nowPlayingDateSize = v }
            if let v = clockFontSize { s.clockFontSize = v }
            if let v = clockTimeFormat { s.clockTimeFormat = v }
            if let v = clockFontWeight { s.clockFontWeight = v }
            if let v = clockFont { s.clockFont = v }
            if let v = clockOffsetX { s.clockOffsetX = v }
            if let v = clockOffsetY { s.clockOffsetY = v }
            if let v = customImageClock { s.customImageClock = v }
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
            if let v = oracleSspaiCount { s.oracleSspaiCount = v }
            if let v = oracleSspaiRandom { s.oracleSspaiRandom = v }
            if let v = oracleNowPlayingHorizontal { s.oracleNowPlayingHorizontal = v }
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
            if let v = excerptSspaiCount { s.excerptSspaiCount = v }
            if let v = excerptSspaiRandom { s.excerptSspaiRandom = v }
            if let v = excerptNowPlayingHorizontal { s.excerptNowPlayingHorizontal = v }
            if let v = canvasImagePath { s.excerptCanvasImagePath = v }
            if let v = canvasImageName { s.excerptCanvasImageName = v }
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

    /// 默认设备名（第 N 台）
    public static func defaultName(for type: DeviceType, index: Int) -> String {
        "\(type.title) \(index + 1)"
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
