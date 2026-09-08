import Foundation

/// 卡片可以运行的显示设备族。卡片本身不再了解具体硬件，新增设备只需要声明支持的设备族。
public enum CardSurface: String, Codable, CaseIterable, Hashable {
    case keyboard
    case colorSquare
}

/// 卡片渲染所需的数据能力。设备调度器据此决定进入卡片时要刷新哪些数据，
/// 避免每种新设备重复一份按卡片类型分支的网络与采样逻辑。
public struct CardDataRequirements: OptionSet, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let system = CardDataRequirements(rawValue: 1 << 0)
    public static let pomodoro = CardDataRequirements(rawValue: 1 << 1)
    public static let nowPlaying = CardDataRequirements(rawValue: 1 << 2)
    public static let quotas = CardDataRequirements(rawValue: 1 << 3)
    public static let homeAssistant = CardDataRequirements(rawValue: 1 << 4)
    public static let sspai = CardDataRequirements(rawValue: 1 << 5)
    public static let formlabs = CardDataRequirements(rawValue: 1 << 6)
    public static let image = CardDataRequirements(rawValue: 1 << 7)
}

/// 与具体设备尺寸无关的渲染配方。普通信息卡片可以直接映射到画板模块；
/// 需要专用绘制的壁纸、图片与用户画板保留明确的专用配方。
public enum CardRenderRecipe: Equatable {
    case modules([CanvasModule])
    case customImage
    case emojiWallpaper
    case deviceCanvas
}

/// 一张功能卡片的完整能力描述。侧栏、卡片管理、轮播和渲染都读取这里，
/// 不再分别维护容易遗漏的卡片清单。
public struct CardCapability: Identifiable, Equatable {
    public let mode: DisplayMode
    public let surfaces: Set<CardSurface>
    public let recipe: CardRenderRecipe
    public let requirements: CardDataRequirements

    public var id: Int { mode.rawValue }

    public init(mode: DisplayMode,
                surfaces: Set<CardSurface> = [.keyboard, .colorSquare],
                recipe: CardRenderRecipe,
                requirements: CardDataRequirements = []) {
        self.mode = mode
        self.surfaces = surfaces
        self.recipe = recipe
        self.requirements = requirements
    }
}

/// 应用级卡片能力目录。
///
/// 新增普通功能卡片时只需要：
/// 1. 在 `DisplayMode` 增加稳定标识；
/// 2. 在这里增加一条能力描述；
/// 3. 若不是模块配方，再实现对应的专用渲染器。
/// 所有已声明支持该设备族的设备会自动获得侧栏、显示/隐藏与轮播能力。
public enum CardCapabilityRegistry {
    public static let all: [CardCapability] = [
        .init(mode: .qwenWork, recipe: .modules([.qwenQuota]), requirements: [.quotas]),
        .init(mode: .codex, recipe: .modules([.codex]), requirements: [.quotas]),
        .init(mode: .pomodoro, recipe: .modules([.pomodoro]), requirements: [.pomodoro]),
        .init(mode: .systemMonitor,
              recipe: .modules([.cpu, .memory, .disk, .network, .uptime]),
              requirements: [.system]),
        .init(mode: .nowPlaying, recipe: .modules([.nowPlaying]), requirements: [.nowPlaying]),
        .init(mode: .customImage, recipe: .customImage, requirements: [.image]),
        .init(mode: .canvas, recipe: .deviceCanvas,
              requirements: [.system, .pomodoro, .nowPlaying, .quotas,
                             .homeAssistant, .sspai, .formlabs, .image]),
        .init(mode: .excerptQuote, recipe: .modules([.excerptText])),
        .init(mode: .sspai, recipe: .modules([.sspai]), requirements: [.sspai]),
        .init(mode: .emojiWallpaper, recipe: .emojiWallpaper),
        .init(mode: .homeAssistant, recipe: .modules([.homeAssistant]),
              requirements: [.homeAssistant]),
        .init(mode: .bambuLab, recipe: .modules([.bambuLab]), requirements: [.homeAssistant]),
        .init(mode: .bambuLab2, recipe: .modules([.bambuLab2]), requirements: [.homeAssistant]),
        .init(mode: .bambuLab3, recipe: .modules([.bambuLab3]), requirements: [.homeAssistant]),
        .init(mode: .bambuLab4, recipe: .modules([.bambuLab4]), requirements: [.homeAssistant]),
        .init(mode: .bambuLab5, recipe: .modules([.bambuLab5]), requirements: [.homeAssistant]),
        .init(mode: .formlabs, recipe: .modules([.formlabs]), requirements: [.formlabs]),
        .init(mode: .formlabs2, recipe: .modules([.formlabs2]), requirements: [.formlabs]),
        .init(mode: .formlabs3, recipe: .modules([.formlabs3]), requirements: [.formlabs]),
        .init(mode: .formlabs4, recipe: .modules([.formlabs4]), requirements: [.formlabs]),
        .init(mode: .formlabs5, recipe: .modules([.formlabs5]), requirements: [.formlabs])
    ]

    private static let byMode = Dictionary(uniqueKeysWithValues: all.map { ($0.mode, $0) })

    public static func capability(for mode: DisplayMode) -> CardCapability? { byMode[mode] }

    /// 设备当前真正可用的卡片。打印机卡片位与已添加设备数量联动，避免出现空设备入口。
    public static func modes(for surface: CardSurface,
                             bambuPrinterCount: Int = 0,
                             formlabsPrinterCount: Int = 0,
                             includesDeviceCanvas: Bool = true) -> [DisplayMode] {
        all.compactMap { card in
            guard card.surfaces.contains(surface) else { return nil }
            if !includesDeviceCanvas, card.mode == .canvas { return nil }
            if let slot = card.mode.bambuSlotIndex, slot >= bambuPrinterCount { return nil }
            if let slot = card.mode.formlabsSlotIndex, slot >= formlabsPrinterCount { return nil }
            return card.mode
        }
    }

    public static func sanitized(_ rawValues: [Int], available: [DisplayMode]) -> [DisplayMode] {
        let allowed = Set(available)
        var seen = Set<DisplayMode>()
        return rawValues.compactMap(DisplayMode.init(rawValue:))
            .filter { allowed.contains($0) && seen.insert($0).inserted }
    }
}
