import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LinxDisplayCore
import SwiftUI
import UniformTypeIdentifiers

/// 应用总控：每秒时钟驱动渲染与推送，逻辑对齐原版 MainViewModel。
@MainActor
public final class AppModel: ObservableObject {
    private let store = SettingsStore()
    private let codex = CodexRateLimitClient()
    private let quotaClient = QwenWorkQuotaClient()
    private let nowPlayingClient = NowPlayingClient()
    private let imageApi = ImageApiClient()
    private let monitor = SystemMonitor()
    private let startup = StartupManager()
    private let pomodoro: PomodoroService

    private var timer: Timer?
    /// 用量数据（Codex 用量 + 千问办公额度）统一刷新时间：各功能共用同一刷新周期
    private var lastQuotaRefresh: Date?
    private var lastPushAttempt: Date?
    private var lastUploadedHash: String?
    private var lastNowPlayingFetch: Date?
    private var lastTickDate: Date?
    private var lastImageRotation: Date?
    private var lastClockMinute: Int?
    private var lastCardRotation: Date?
    private var cardRotationIndex = 0
    /// 摘录语录卡片最近一次推送的语录（变化时才推送：手动切换或分钟轮换）
    private var lastQuotePushText: String?
    /// 少数派推荐：上次抓取时间与内容指纹（内容变化时推送到键盘）
    private var lastSspaiFetch: Date?
    private var lastSspaiHash: String?
    /// 各画板「少数派推荐」随机抽取的缓存（文章刷新后失效重抽，避免每次渲染都换导致频繁推送）
    private var sspaiRandomSelection: [CanvasOwner: [SspaiArticle]] = [:]
    /// Rand/0 显示模式持久会话：保持连接接收按键事件（下键触发手动更新），推送走同一连接即显示
    private var rand0Session: Rand0DisplaySession?
    private var rand0SessionIP = ""
    private var rand0SessionEndpoint: Rand0Client.Endpoint = .bw
    /// 口袋先知显示模式连接状态（供界面显示）
    @Published public var rand0SessionConnected = false
    /// 摘录语录：手动切换的语录下标（nil = 按分钟自动轮换）
    @Published public var quoteOverrideIndex: Int?

    /// 摘录语录当前展示的语录：优先手动指定，否则按分钟自动轮换（轮换池按勾选的分类过滤）
    public var quoteDisplayText: String {
        let quotes = ScreenRenderer.excerptQuotes(in: settings.excerptQuoteCategories)
        guard !quotes.isEmpty else { return "摘录语录" }
        if let index = quoteOverrideIndex {
            return quotes[abs(index) % quotes.count]
        }
        return ScreenRenderer.rotatingExcerptText(Date(), categories: settings.excerptQuoteCategories)
    }

    /// 手动切换到下一条语录（覆盖自动轮换）
    public func nextQuote() {
        let quotes = ScreenRenderer.excerptQuotes(in: settings.excerptQuoteCategories)
        guard !quotes.isEmpty else { return }
        let base = quoteOverrideIndex ?? Int(Date().timeIntervalSince1970 / 60) % quotes.count
        quoteOverrideIndex = (base + 1) % quotes.count
        lastQuotePushText = nil
        renderPreview()
    }

    /// 手动切换到上一条语录（覆盖自动轮换）
    public func previousQuote() {
        let quotes = ScreenRenderer.excerptQuotes(in: settings.excerptQuoteCategories)
        guard !quotes.isEmpty else { return }
        let base = quoteOverrideIndex ?? Int(Date().timeIntervalSince1970 / 60) % quotes.count
        quoteOverrideIndex = (base - 1 + quotes.count) % quotes.count
        lastQuotePushText = nil
        renderPreview()
    }

    /// 恢复自动轮换（清除手动指定）
    public func resetQuoteRotation() {
        quoteOverrideIndex = nil
        lastQuotePushText = nil
        renderPreview()
    }

    /// 勾选/取消一个语录分类：切换后回到自动轮换并立即刷新预览（分类变化即刻生效）
    public func setExcerptQuoteCategory(_ category: ExcerptQuoteCategory, enabled: Bool) {
        var cats = settings.excerptQuoteCategories
        if enabled {
            if !cats.contains(category.rawValue) { cats.append(category.rawValue) }
        } else {
            cats.removeAll { $0 == category.rawValue }
        }
        settings.excerptQuoteCategories = cats
        quoteOverrideIndex = nil
        lastQuotePushText = nil
        renderPreview()
    }
    /// 夸夸展示：当前文案与展示截止时间（到期后恢复正常卡片）
    private var praiseText: String?
    private var praiseUntil: Date?
    private static let praiseDisplaySeconds: TimeInterval = 12
    private var cachedArtwork: (data: Data, image: CGImage)?
    private var busy = false
    /// 用量统一调取进行中（防止长耗时拉取重叠）
    private var quotaRefreshing = false
    /// 两个独立画板定时推送的上次推送时间（初始化为启动时刻，避免启动即推送）
    private var lastOracleAutoPush: Date?
    private var lastExcerptAutoPush: Date?
    /// 两个独立画板已推送内容指纹（用于内容变化立即推送的对比基线）
    private var lastOraclePushedHash: Data?
    private var lastExcerptPushedHash: Data?
    /// 两个独立画板内容变化检查节流时间
    private var lastOracleContentCheck: Date?
    private var lastExcerptContentCheck: Date?
    private var cropWindow: NSWindow?

    /// 统一数据调取器：一次并行拉取 Codex 用量与千问办公额度，缓存后分发给各功能
    private lazy var usageAggregator: UsageDataAggregator = UsageDataAggregator(
        fetchCodex: { [weak self] path in
            guard let self else { throw CodexError.notFound }
            return try await self.codex.fetch(executable: path ?? self.settings.codexCliPath)
        },
        fetchQuota: { [weak self] in
            guard let self else { throw QuotaError.unreachable }
            return try await self.quotaClient.fetch()
        })

    /// 活动设置（普通存储属性而非 @Published：视图直接观察 AppSettings 自身
    /// 的 objectWillChange，避免 @Published 包装器嵌套访问触发元数据递归崩溃）
    public var settings: AppSettings
    @Published public var usage: UsageSnapshot = .sample
    @Published public var qwenQuota: QwenWorkQuota = .sample
    /// 少数派推荐文章缓存（供「少数派推荐」卡片显示）
    @Published public var sspaiArticles: [SspaiArticle] = []
    @Published public var nowPlaying: NowPlayingInfo = .placeholder
    @Published public var system: SystemSnapshot = .empty
    @Published public var previewImage: NSImage?
    /// 侧栏常驻显示的正在播放封面（无封面时为占位）
    @Published public var sidebarArtwork: NSImage?
    /// 侧栏封面背后的高斯模糊光斑颜色（取封面主色；无封面时为 nil）
    @Published public var sidebarArtworkGlow: NSColor?
    @Published public var status = "正在初始化…"
    @Published public var lastRefresh = "最后刷新：尚未刷新"
    @Published public var lastPush = "最后推送：尚未推送"

    /// 外观变化时由窗口应用（跟随系统 / 浅色 / 深色）
    public var onAppearanceChanged: (() -> Void)?

    public init() {
        let loaded = store.load()
        settings = loaded
        pomodoro = PomodoroService(state: store.loadPomodoro())
        // 设备管理初始化：首次使用不自动创建设备（空列表），由界面引导用户在设备管理中添加；
        // 直接用本地加载的对象（避免经 AppModel 的 @Published 包装器访问，
        // 防止 init 阶段触发元数据重入崩溃）
        for type in DeviceType.allCases {
            let list = loaded.devices.filter { $0.type == type }
            let activeID: UUID?
            switch type {
            case .keyboard: activeID = loaded.activeKeyboardDeviceID
            case .oracle: activeID = loaded.activeOracleDeviceID
            case .excerpt: activeID = loaded.activeExcerptDeviceID
            }
            if let device = list.first(where: { $0.id == activeID }) ?? list.first {
                device.settings.apply(to: loaded, type: type)
            }
        }
        settings.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.updateSoftwareDarkState()
                // 拖拽侧边栏宽度中：跳过持久化/重渲染/外观应用，避免逐帧闪烁，松手时一次性提交
                guard self?.sidebarResizing != true else { return }
                // 设备设置同步进行中（同步操作会再次触发 onChange）：直接跳过防递归
                guard self?.isSyncingDeviceSettings != true else { return }
                // 同步活动设备设置（内部防重入），随后持久化
                self?.syncActiveDeviceSettings()
                self?.persistSettings()
                self?.renderPreview()
                self?.refreshOracleCanvasPreview()
                self?.refreshExcerptCanvasPreview()
                self?.onAppearanceChanged?()
                // 先知 IP/显示模式变化时重连按键会话（目标未变则幂等返回）
                self?.ensureRand0Session()
            }
        }
        updateSoftwareDarkState()
        settings.startWithSystem = startup.isEnabled()
        // 自动推送开启时启动即推一次（推送内部会等待会话连接就绪）；未开启则从启动时刻起算间隔
        lastOracleAutoPush = settings.oracleAutoPushEnabled ? nil : Date()
        lastExcerptAutoPush = settings.excerptAutoPushEnabled ? nil : Date()
        startTimer()
        renderPreview()
        Task { await activateMode() }
        // 启动即建立先知显示模式会话（自动重连由会话内部负责），按键随时可用
        ensureRand0Session()
    }

    /// 设备设置同步防重入（同步操作会再次触发 onChange）
    private var isSyncingDeviceSettings = false

    /// 把活动设置同步回各类型当前激活设备的快照（切换设备时据此记住之前设备的设置）
    public func syncActiveDeviceSettings() {
        guard !settings.devices.isEmpty else { return }
        isSyncingDeviceSettings = true
        defer { isSyncingDeviceSettings = false }
        for type in DeviceType.allCases {
            guard let device = activeDevice(for: type),
                  let index = settings.devices.firstIndex(where: { $0.id == device.id }) else { continue }
            settings.devices[index].settings = DeviceSettings.capture(from: settings, type: type)
        }
    }

    /// 某类型设备列表（含被禁用的；设备管理页需要显示以便重新启用）
    public func devices(for type: DeviceType) -> [ManagedDevice] {
        settings.devices.filter { $0.type == type }
    }

    /// 某类型已启用设备列表（侧栏导航/目标选择等只展示启用的设备）
    public func enabledDevices(for type: DeviceType) -> [ManagedDevice] {
        settings.devices.filter { $0.type == type && $0.isEnabled }
    }

    /// 某类型当前活动设备（按活动 ID，回退该类第一台已启用设备；全部禁用时为 nil）
    public func activeDevice(for type: DeviceType) -> ManagedDevice? {
        let list = enabledDevices(for: type)
        guard !list.isEmpty else { return nil }
        let activeID = activeDeviceID(for: type)
        return list.first { $0.id == activeID } ?? list[0]
    }

    /// 设备启用/禁用开关：禁用后侧栏隐藏该设备；禁用活动设备时自动切到该类第一台仍启用的设备
    public func setDeviceEnabled(id: UUID, enabled: Bool) {
        guard let index = settings.devices.firstIndex(where: { $0.id == id }) else { return }
        guard settings.devices[index].isEnabled != enabled else { return }
        settings.devices[index].isEnabled = enabled
        if !enabled {
            let type = settings.devices[index].type
            if activeDeviceID(for: type) == id {
                if let fallback = enabledDevices(for: type).first {
                    switchDevice(type: type, to: fallback.id)
                } else {
                    setActiveDeviceID(type, nil)
                }
            }
        }
    }

    /// 某台设备的启用开关绑定
    public func deviceEnabledBinding(for id: UUID) -> Binding<Bool> {
        Binding(get: {
            self.settings.devices.first(where: { $0.id == id })?.isEnabled ?? true
        }, set: { enabled in
            self.setDeviceEnabled(id: id, enabled: enabled)
        })
    }

    /// 某类型活动设备 ID
    public func activeDeviceID(for type: DeviceType) -> UUID? {
        switch type {
        case .keyboard: return settings.activeKeyboardDeviceID
        case .oracle: return settings.activeOracleDeviceID
        case .excerpt: return settings.activeExcerptDeviceID
        }
    }

    private func setActiveDeviceID(_ type: DeviceType, _ id: UUID?) {
        switch type {
        case .keyboard: settings.activeKeyboardDeviceID = id
        case .oracle: settings.activeOracleDeviceID = id
        case .excerpt: settings.activeExcerptDeviceID = id
        }
    }

    /// 切换某类型的活动设备：先把当前设置存回原设备，再套用新设备的设置
    public func switchDevice(type: DeviceType, to deviceID: UUID?) {
        guard let newDevice = devices(for: type).first(where: { $0.id == deviceID })
                ?? devices(for: type).first else { return }
        if activeDeviceID(for: type) == newDevice.id { return }
        syncActiveDeviceSettings()
        setActiveDeviceID(type, newDevice.id)
        newDevice.settings.apply(to: settings, type: type)
        // 切换口袋先知设备后，显示模式会话要重连到新设备 IP（按键信号才回传到这台设备）
        if type == .oracle {
            ensureRand0Session()
        }
        persistSettings()
        renderPreview()
        refreshOracleCanvasPreview()
        refreshExcerptCanvasPreview()
    }

    /// 新增一台该类型设备（复制当前活动设备的设置作为起点，并设为活动）
    @discardableResult
    public func addDevice(type: DeviceType) -> UUID {
        // 无活动设备时（如删光后重加）继承全局设置快照：连接信息等仍保留的内容照常显示，
        // 避免「显示已清除但实际未清除」的不一致
        let current = activeDevice(for: type)?.settings
            ?? DeviceSettings.capture(from: settings, type: type)
        let count = devices(for: type).count
        let device = ManagedDevice(type: type,
                                   name: ManagedDevice.defaultName(for: type, index: count),
                                   settings: current)
        settings.devices.append(device)
        // 新键盘设备默认无卡片（空可见列表，侧栏显示去卡片管理的提示）；镜像先行防 sync 覆盖
        if type == .keyboard {
            settings.keyboardCardPanels = []
            settings.devices[settings.devices.count - 1].settings.keyboardCardPanels = []
        }
        setActiveDeviceID(type, device.id)
        persistSettings()
        return device.id
    }

    /// 删除一台设备（允许删除全部设备；删除的是活动设备时活动设备置空）
    public func removeDevice(id: UUID) {
        guard let device = settings.devices.first(where: { $0.id == id }) else { return }
        let type = device.type
        settings.devices.removeAll { $0.id == id }
        if activeDeviceID(for: type) == id {
            setActiveDeviceID(type, nil)
            activeDevice(for: type)?.settings.apply(to: settings, type: type)
        }
        persistSettings()
        renderPreview()
        refreshOracleCanvasPreview()
        refreshExcerptCanvasPreview()
    }

    /// 重命名设备
    public func renameDevice(id: UUID, to name: String) {
        guard let index = settings.devices.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.devices[index].name = trimmed.isEmpty
            ? ManagedDevice.defaultName(for: settings.devices[index].type,
                                       index: devices(for: settings.devices[index].type).count)
            : trimmed
        persistSettings()
    }

    /// 某台键盘设备的自动轮播开关（按设备独立；是活动设备时同步到活动设置并重置轮换时钟）
    public func deviceRotationEnabledBinding(for deviceID: UUID) -> Binding<Bool> {
        Binding(get: {
            self.settings.devices.first(where: { $0.id == deviceID })?.settings.cardRotationEnabled ?? false
        }, set: { enabled in
            guard let index = self.settings.devices.firstIndex(where: { $0.id == deviceID }) else { return }
            self.settings.devices[index].settings.cardRotationEnabled = enabled
            if self.activeDeviceID(for: .keyboard) == deviceID {
                self.settings.cardRotationEnabled = enabled
                if enabled { self.lastCardRotation = nil }
            }
        })
    }

    /// 设备名编辑绑定
    public func deviceNameBinding(for id: UUID) -> Binding<String> {
        Binding(get: { self.settings.devices.first(where: { $0.id == id })?.name ?? "" },
                set: { self.renameDevice(id: id, to: $0) })
    }

    /// 设备连接信息编辑绑定：写入设备快照；是活动设备时通过 liveSync 同步到活动设置
    private func deviceConnectionBinding(for id: UUID,
                                         get: @escaping (DeviceSettings) -> String?,
                                         set: @escaping (inout DeviceSettings, String) -> Void,
                                         activeType: DeviceType,
                                         liveSync: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: {
            guard let device = self.settings.devices.first(where: { $0.id == id }) else { return "" }
            return get(device.settings) ?? ""
        }, set: { newValue in
            guard let index = self.settings.devices.firstIndex(where: { $0.id == id }) else { return }
            set(&self.settings.devices[index].settings, newValue)
            if self.activeDeviceID(for: activeType) == id {
                liveSync(newValue)
            }
        })
    }

    /// 键盘设备连接绑定（只需填 IP/主机；应用时自动拼成完整图像 API 地址）
    public func deviceEndpointBinding(for id: UUID) -> Binding<String> {
        deviceConnectionBinding(for: id,
                                get: { EndpointBuilder.host(from: $0.endpoint ?? "") },
                                set: { device, value in
                                    device.endpoint = EndpointBuilder.endpoint(fromHost: value)
                                },
                                activeType: .keyboard,
                                liveSync: { self.settings.endpoint = EndpointBuilder.endpoint(fromHost: $0) })
    }

    /// 口袋先知设备连接绑定（IP）
    public func deviceRand0IPBinding(for id: UUID) -> Binding<String> {
        deviceConnectionBinding(for: id,
                                get: { $0.rand0IP },
                                set: { $0.rand0IP = $1 },
                                activeType: .oracle,
                                liveSync: { self.settings.rand0IP = $0 })
    }

    /// 摘录设备 API Key 绑定
    public func deviceDotApiKeyBinding(for id: UUID) -> Binding<String> {
        deviceConnectionBinding(for: id,
                                get: { $0.dotApiKey },
                                set: { $0.dotApiKey = $1 },
                                activeType: .excerpt,
                                liveSync: { self.settings.dotApiKey = $0 })
    }

    /// 摘录设备序列号绑定
    public func deviceDotDeviceIdBinding(for id: UUID) -> Binding<String> {
        deviceConnectionBinding(for: id,
                                get: { $0.dotDeviceId },
                                set: { $0.dotDeviceId = $1 },
                                activeType: .excerpt,
                                liveSync: { self.settings.dotDeviceId = $0 })
    }

    /// 按键控制目标选项：口袋先知自身 + 所有灵犀68 键盘设备 + 所有摘录设备
    /// （key 为稳定字符串，供 Picker 可靠选择；旧配置「目标为空」回退为自身）
    public func rand0ControlOptions() -> [(key: String, label: String)] {
        var options: [(String, String)] = [("self", "口袋先知自身")]
        for device in enabledDevices(for: .keyboard) {
            options.append(("kb:\(device.id.uuidString)", "灵犀68 键盘 · \(device.name)"))
        }
        for device in enabledDevices(for: .excerpt) {
            options.append(("ex:\(device.id.uuidString)", "摘录 · \(device.name)"))
        }
        return options
    }

    /// 某台先知设备的按键控制目标绑定（字符串 key：self=自身，kb:/ex:=具体设备）
    public func deviceRand0ControlTargetBinding(for id: UUID) -> Binding<String> {
        Binding(get: {
            guard let device = self.settings.devices.first(where: { $0.id == id }) else { return "self" }
            let target = device.settings.rand0ButtonTarget ?? .oracle
            switch target {
            case .oracle:
                return "self"
            case .keyboard, .excerpt:
                guard let deviceID = device.settings.rand0ButtonTargetDeviceID else { return "self" }
                let prefix = target == .keyboard ? "kb:" : "ex:"
                return "\(prefix)\(deviceID.uuidString)"
            }
        }, set: { key in
            guard let index = self.settings.devices.firstIndex(where: { $0.id == id }) else { return }
            var target: Rand0ButtonTarget = .oracle
            var targetDeviceID: UUID?
            if key == "self" {
                target = .oracle
                targetDeviceID = nil
            } else if key.hasPrefix("kb:"), let deviceID = UUID(uuidString: String(key.dropFirst(3))) {
                target = .keyboard
                targetDeviceID = deviceID
            } else if key.hasPrefix("ex:"), let deviceID = UUID(uuidString: String(key.dropFirst(3))) {
                target = .excerpt
                targetDeviceID = deviceID
            }
            // 先写全局镜像、再写设备快照：设备快照写入会触发 onChange → syncActiveDeviceSettings
            // 用全局快照回写设备；若镜像还是旧值，刚选的目标会被旧快照覆盖（选择器表现为"卡住"）。
            // 镜像先行保证 sync 捕获到新值，最终两端一致。
            if self.activeDeviceID(for: .oracle) == id {
                self.settings.rand0ButtonTarget = target
                self.settings.rand0ButtonTargetDeviceID = targetDeviceID
            }
            self.settings.devices[index].settings.rand0ButtonTarget = target
            self.settings.devices[index].settings.rand0ButtonTargetDeviceID = targetDeviceID
        })
    }

    /// 某台先知设备当前按键控制目标的说明文字
    public func rand0ControlTargetLabel(for oracleDeviceID: UUID) -> String {
        guard let device = self.settings.devices.first(where: { $0.id == oracleDeviceID }) else { return "" }
        let target = device.settings.rand0ButtonTarget ?? .oracle
        switch target {
        case .oracle:
            return settings.oracleCanvasBoards.count > 1
                ? "口袋先知自身：上下键在多块画板间循环切换并推送"
                : "口袋先知自身：下键手动更新画布"
        case .keyboard, .excerpt:
            if let targetID = device.settings.rand0ButtonTargetDeviceID,
               let targetDevice = self.settings.devices.first(where: { $0.id == targetID }) {
                if target == .keyboard {
                    return "\(targetDevice.type.title) \(targetDevice.name)：上下键翻页"
                }
                return "\(targetDevice.type.title) \(targetDevice.name)：下键切云端下一项，上键推送本地摘录画板"
            }
            // 旧配置目标为空：按自身处理
            return "口袋先知自身：下键手动更新画布"
        }
    }

    /// 正在拖拽调整侧边栏宽度（拖拽中跳过重量级刷新）
    private var sidebarResizing = false

    /// 拖拽开始：进入批处理模式
    public func beginSidebarResize() {
        sidebarResizing = true
    }

    /// 拖拽中更新宽度（仅更新布局，不持久化/不重渲染预览）
    public func setSidebarWidth(_ width: Int) {
        settings.sidebarWidth = min(max(width, 140), 280)
    }

    /// 拖拽结束：一次性持久化并刷新预览
    public func finishSidebarResize() {
        sidebarResizing = false
        persistSettings()
        renderPreview()
    }

    /// 依据外观模式 + 系统外观计算软件当前明暗；背景底色「跟随软件明暗」依赖此状态
    private func updateSoftwareDarkState() {
        let isDark: Bool
        switch settings.appearanceMode {
        case .light: isDark = false
        case .dark: isDark = true
        case .system:
            let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            isDark = (match == .darkAqua)
        }
        guard settings.softwareIsDark != isDark else { return }
        settings.softwareIsDark = isDark
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - 时钟

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() async {
        let now = Date()
        // 跟随系统外观变化（外观模式为「跟随系统」时）
        updateSoftwareDarkState()
        // 设备画板含「正在播放」模块且开启自动推送时：按 6 秒节流刷新播放状态，
        // 实时捕获专辑封面变化（否则要等 30 秒的侧栏低频刷新）
        if deviceCanvasNeedsLiveNowPlaying {
            await refreshNowPlaying(now: now)
        }
        // 夸夸展示到期：恢复正常卡片并推送
        if let until = praiseUntil, now >= until {
            praiseText = nil
            praiseUntil = nil
            renderPreview()
            await push(force: true)
        }
        let periodCompleted = pomodoro.tick(now: now)
        if periodCompleted {
            store.savePomodoro(pomodoro.state)
            if settings.pomodoroPraiseEnabled {
                await showPraise(now: now)
            }
        }
        if await maybeRotateCard(now: now) {
            return
        }
        switch settings.displayMode {
        case .codex, .qwenWork:
            let action = SyncPlanner.forCodex(
                now: now, lastRefresh: lastQuotaRefresh, lastPush: lastPushAttempt,
                refreshSeconds: settings.codexRefreshSeconds)
            switch action {
            case .refreshAndPush:
                await refreshData(upload: true, forceUpload: false)
            case .push:
                await push(force: false)
            case .none:
                renderPreview()
            }
        case .systemMonitor:
            system = monitor.sample(now: now)
            renderPreview()
            if shouldPushDynamically(now: now) {
                await push(force: false)
            }
        case .pomodoro:
            renderPreview()
            if shouldPushDynamically(now: now) {
                await push(force: false)
            }
        case .nowPlaying:
            await refreshNowPlaying(now: now)
            renderPreview()
            if shouldPushDynamically(now: now) {
                await push(force: false)
            }
        case .canvas:
            system = monitor.sample(now: now)
            // 画板含 Codex/千问额度模块时，按统一用量刷新周期先调取再渲染
            if canvasNeedsQuotaData, isQuotaDataStale(now: now) {
                let failures = await refreshUsageAndQuota()
                if !failures.isEmpty { status = failures.joined(separator: "；") }
            }
            renderPreview()
            if shouldPushDynamically(now: now) {
                await push(force: false)
            }
        case .excerptQuote:
            renderPreview()
            // 语录变化（手动切换或分钟轮换）时才推送到键盘
            let quote = quoteDisplayText
            if lastQuotePushText != quote {
                lastQuotePushText = quote
                await push(force: false)
            }
        case .sspai:
            // 到刷新周期则重新抓取少数派推荐
            if lastSspaiFetch == nil
                || now.timeIntervalSince(lastSspaiFetch!) >= TimeInterval(max(5, settings.sspaiRefreshMinutes) * 60) {
                let changed = await fetchSspai()
                renderPreview()
                if changed {
                    await push(force: false)
                }
            } else {
                renderPreview()
            }
        case .customImage:
            if settings.imageRotationEnabled {
                await maybeRotateImage(now: now)
            }
            if settings.customImageClock != .none {
                await maybePushClockOverlay(now: now)
            }
        case .emojiWallpaper:
            // 壁纸内容确定性强（由设置决定），仅在内容变化（设置改动触发渲染）时推送
            renderPreview()
            if shouldPushDynamically(now: now) {
                await push(force: false)
            }
        }
        // 用量数据统一调取：任一画板（键盘/先知/摘录）含 Codex 或千问额度模块时，
        // 按统一刷新周期（codexRefreshSeconds）并行拉取一次，供所有功能共享（避免各自重复调用）
        if settings.displayMode != .codex && settings.displayMode != .qwenWork,
           canvasNeedsQuotaData, isQuotaDataStale(now: now) {
            let failures = await refreshUsageAndQuota()
            if !failures.isEmpty { status = failures.joined(separator: "；") }
        }
        // 少数派推荐：三个画板都可能使用该模块，按刷新周期统一抓取一次供共享
        // （displayMode == .sspai 时上面 case 已抓取，此处跳过避免重复）
        if lastSspaiFetch == nil
            || now.timeIntervalSince(lastSspaiFetch!) >= TimeInterval(max(5, settings.sspaiRefreshMinutes) * 60) {
            let changed = await fetchSspai()
            if changed, settings.displayMode == .sspai {
                renderPreview()
                await push(force: false)
            }
        }
        // 独立画板定时推送：按各自间隔自动推送口袋先知 / 摘录画布到设备
        await maybeAutoPushDeviceCanvases(now: now)
        // 侧栏常驻封面：非「正在播放」模式下也低频刷新一次播放状态
        if settings.displayMode != .nowPlaying {
            await refreshSidebarNowPlaying(now: now)
        }
        // 独立画板预览：按分钟刷新（内容每分钟轮换）
        refreshCanvasPreviews(now: now)
    }

    private var lastCanvasPreviewMinute: Int?

    private func refreshCanvasPreviews(now: Date) {
        let minute = Int(now.timeIntervalSince1970 / 60)
        guard lastCanvasPreviewMinute != minute else { return }
        lastCanvasPreviewMinute = minute
        refreshOracleCanvasPreview()
        refreshExcerptCanvasPreview()
    }

    /// 低频刷新正在播放状态（仅供侧栏常驻封面/歌曲信息，不推送、不影响当前卡片）
    private func refreshSidebarNowPlaying(now: Date) async {
        if let last = lastNowPlayingFetch, now.timeIntervalSince(last) < 30 { return }
        lastNowPlayingFetch = now
        lastTickDate = now
        do {
            nowPlaying = try await nowPlayingClient.fetch()
        } catch {
            if nowPlaying.title.isEmpty || nowPlaying.title == "未在播放" {
                nowPlaying = .placeholder
            }
        }
        updateSidebarArtwork()
    }

    /// 最近图片定时轮换：到点后按顺序/随机切换到下一张历史图片并推送
    private func maybeRotateImage(now: Date) async {
        guard settings.customImageHistory.count >= 2 else { return }
        guard let last = lastImageRotation else {
            lastImageRotation = now
            return
        }
        guard now.timeIntervalSince(last) >= TimeInterval(settings.imageRotationSeconds) else { return }
        lastImageRotation = now
        guard !busy else { return }

        let history = settings.customImageHistory
        let next: RecentImage
        switch settings.imageRotationMode {
        case .sequential:
            if let index = history.firstIndex(where: { $0.path == settings.customImagePath }) {
                next = history[(index + 1) % history.count]
            } else {
                next = history[0]
            }
        case .random:
            let candidates = history.filter { $0.path != settings.customImagePath }
            next = candidates.randomElement() ?? history[0]
        }
        guard FileManager.default.fileExists(atPath: next.path) else { return }
        settings.customImagePath = next.path
        settings.customImageName = next.name
        persistSettings()
        renderPreview()
        await push(force: true)
    }

    /// 时钟叠加的刷新：格式含秒时按秒级推送，否则分钟级（force=false，hash 去重兜底）
    private func maybePushClockOverlay(now: Date) async {
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0
        let minuteOfDay = hour * 60 + minute
        let includesSeconds = settings.clockTimeFormat.contains("s")
        let current = includesSeconds ? minuteOfDay * 60 + second : minuteOfDay
        guard current != lastClockMinute else { return }
        lastClockMinute = current
        renderPreview()
        await push(force: false)
    }

    /// 切换自定义图片的时钟叠加布局（重置时钟，下一个 tick 立即重推）
    public func setCustomImageClock(_ overlay: CustomImageClockOverlay) {
        settings.customImageClock = overlay
        lastClockMinute = nil
        persistSettings()
    }

    /// 自定义时钟时间格式（重置时钟，下一个 tick 立即重推）
    public func setClockTimeFormat(_ format: String) {
        let trimmed = format.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.clockTimeFormat = trimmed.isEmpty ? "HH:mm" : trimmed
        lastClockMinute = nil
        persistSettings()
    }

    // MARK: - 画板编辑

    /// 添加一个画板模块（已存在则忽略）
    public func addCanvasModule(_ module: CanvasModule, to owner: CanvasOwner = .keyboard) {
        let key = modulesKeyPath(for: owner)
        guard !settings[keyPath: key].contains(module.rawValue) else { return }
        settings[keyPath: key].append(module.rawValue)
        persistSettings()
        refreshDevicePreview(for: owner)
    }

    /// 移除一个画板模块
    public func removeCanvasModule(_ module: CanvasModule, from owner: CanvasOwner = .keyboard) {
        let key = modulesKeyPath(for: owner)
        settings[keyPath: key].removeAll { $0 == module.rawValue }
        persistSettings()
        refreshDevicePreview(for: owner)
    }

    /// 上移 / 下移一个画板模块
    public func moveCanvasModule(_ module: CanvasModule, up: Bool, owner: CanvasOwner = .keyboard) {
        let key = modulesKeyPath(for: owner)
        guard let index = settings[keyPath: key].firstIndex(of: module.rawValue) else { return }
        let target = up ? index - 1 : index + 1
        guard target >= 0, target < settings[keyPath: key].count else { return }
        settings[keyPath: key].swapAt(index, target)
        persistSettings()
        refreshDevicePreview(for: owner)
    }

    /// 拖拽排序：把 module 移到 target 之前（after=false）或之后（after=true）
    public func moveCanvasModule(_ module: CanvasModule, before target: CanvasModule,
                                 after: Bool = false, owner: CanvasOwner = .keyboard) {
        guard module != target else { return }
        let key = modulesKeyPath(for: owner)
        var list = settings[keyPath: key]
        list.removeAll { $0 == module.rawValue }
        if let index = list.firstIndex(of: target.rawValue) {
            list.insert(module.rawValue, at: after ? index + 1 : index)
        } else {
            list.append(module.rawValue)
        }
        settings[keyPath: key] = list
        persistSettings()
        refreshDevicePreview(for: owner)
    }

    /// 拖拽排序完成：一次性提交最终模块顺序并刷新预览（拖动中只改本地列表，避免卡顿）
    public func commitCanvasModules(_ modules: [CanvasModule], owner: CanvasOwner) {
        settings[keyPath: modulesKeyPath(for: owner)] = modules.map(\.rawValue)
        persistSettings()
        refreshDevicePreview(for: owner)
    }

    /// 独立画板模块编辑后立即刷新其预览（键盘画板预览走 renderPreview 流程）
    private func refreshDevicePreview(for owner: CanvasOwner) {
        switch owner {
        case .keyboard: break
        case .oracle: refreshOracleCanvasPreview()
        case .excerpt: refreshExcerptCanvasPreview()
        }
    }

    /// 切换摘录画板模块是否占满整行（双列布局下横跨两列）
    public func toggleExcerptFullWidth(_ module: CanvasModule) {
        if settings.excerptFullWidthModules.contains(module.rawValue) {
            settings.excerptFullWidthModules.removeAll { $0 == module.rawValue }
        } else {
            settings.excerptFullWidthModules.append(module.rawValue)
        }
        persistSettings()
        refreshExcerptCanvasPreview()
    }

    /// 画板自定义文字内容
    public func setCanvasText(_ text: String) {
        settings.canvasText = text
        persistSettings()
    }

    // MARK: - 卡片页面自动轮换

    /// 卡片轮换：到点后切换到轮换池中的下一个显示模式并推送；返回是否发生了切换
    private func maybeRotateCard(now: Date) async -> Bool {
        guard settings.cardRotationEnabled else { return false }
        let modes = keyboardRotationList
        guard modes.count >= 2 else { return false }
        guard let last = lastCardRotation else {
            lastCardRotation = now
            cardRotationIndex = modes.firstIndex(of: settings.displayMode) ?? 0
            return false
        }
        guard now.timeIntervalSince(last) >= TimeInterval(settings.cardRotationMinutes) * 60 else { return false }
        lastCardRotation = now
        cardRotationIndex = (cardRotationIndex + 1) % modes.count
        let nextMode = modes[cardRotationIndex]
        guard nextMode != settings.displayMode else { return false }
        setMode(nextMode)
        return true
    }

    /// 开启/关闭卡片自动轮换（开启时重置轮换时钟与游标）
    public func setCardRotationEnabled(_ enabled: Bool) {
        settings.cardRotationEnabled = enabled
        if enabled {
            lastCardRotation = nil
            cardRotationIndex = 0
        }
        persistSettings()
    }

    /// 设置轮换间隔（分钟，1–60）
    public func setCardRotationMinutes(_ minutes: Int) {
        settings.cardRotationMinutes = min(max(minutes, 1), 60)
        persistSettings()
    }

    /// 把一张卡片加入轮换池（已存在则忽略）
    public func addCardRotationMode(_ mode: DisplayMode) {
        guard !settings.cardRotationModes.contains(mode.rawValue) else { return }
        settings.cardRotationModes.append(mode.rawValue)
        persistSettings()
    }

    /// 从轮换池移除一张卡片（移除后不再进入自动轮换）
    public func removeCardRotationMode(_ mode: DisplayMode) {
        settings.cardRotationModes.removeAll { $0 == mode.rawValue }
        persistSettings()
    }

    /// 调整轮换池中卡片的上/下位置
    public func moveCardRotationMode(_ mode: DisplayMode, up: Bool) {
        guard let index = settings.cardRotationModes.firstIndex(of: mode.rawValue) else { return }
        let target = up ? index - 1 : index + 1
        guard target >= 0, target < settings.cardRotationModes.count else { return }
        settings.cardRotationModes.swapAt(index, target)
        persistSettings()
    }

    /// 拖拽排序：把 mode 移到 target 之前（after=false）或之后（after=true）
    public func moveCardRotationMode(_ mode: DisplayMode, before target: DisplayMode,
                                     after: Bool = false) {
        guard mode != target else { return }
        var list = settings.cardRotationModes
        list.removeAll { $0 == mode.rawValue }
        if let index = list.firstIndex(of: target.rawValue) {
            list.insert(mode.rawValue, at: after ? index + 1 : index)
        } else {
            list.append(mode.rawValue)
        }
        settings.cardRotationModes = list
        persistSettings()
    }

    /// 拖拽排序完成：一次性提交轮换卡片顺序
    public func commitCardRotationModes(_ modes: [DisplayMode]) {
        settings.cardRotationModes = modes.map(\.rawValue)
        persistSettings()
    }

    /// 正在播放：每 ~6 秒经子进程拉取一次系统状态，间隔内本地推进播放进度
    private func refreshNowPlaying(now: Date) async {
        if let last = lastNowPlayingFetch, now.timeIntervalSince(last) < 6 {
            // 本地推进：只加“距上一次 tick”的间隔，避免重复累计；并钳制不超过总时长
            if nowPlaying.isPlaying, let lastTick = lastTickDate {
                nowPlaying.elapsedTime += now.timeIntervalSince(lastTick)
                if nowPlaying.duration > 0 {
                    nowPlaying.elapsedTime = min(nowPlaying.elapsedTime, nowPlaying.duration)
                }
                nowPlaying.sampledAt = now
            }
            lastTickDate = now
            return
        }
        lastNowPlayingFetch = now
        lastTickDate = now
        do {
            let fetched = try await nowPlayingClient.fetch()
            // MediaRemote 的 elapsedTime 可能长时间不更新（实测多次拉取返回同一值）：
            // 同一首歌时，用本地推进值托底，避免进度条每 6 秒往回跳；换曲则直接采用新值。
            nowPlaying = fetched.mergedWithProgressed(current: nowPlaying)
        } catch NowPlayingError.notPlaying {
            nowPlaying = .placeholder
        } catch {
            if nowPlaying.title.isEmpty || nowPlaying.title == "未在播放" {
                nowPlaying = .placeholder
            }
        }
        updateSidebarArtwork()
    }

    /// 上次侧栏封面数据（用于检测封面变化，实时刷新设备画板预览）
    private var lastSidebarArtworkData: Data?

    /// 刷新侧栏常驻封面：解码当前播放封面（无封面时置 nil，侧栏显示占位）
    private func updateSidebarArtwork() {
        guard let cg = cachedArtworkImage(for: nowPlaying.artwork) else {
            sidebarArtwork = nil
            sidebarArtworkGlow = nil
            lastSidebarArtworkData = nil
            return
        }
        sidebarArtwork = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        // 封面主色：供侧栏封面背后的高斯模糊光斑取色。
        // 主色过暗时光晕会在深色侧栏上几乎不可见，按亮度下限提亮，保证光晕始终可辨识
        let dominant = ScreenRenderer.dominantColor(of: cg)
        var glow = (dominant.0, dominant.1, dominant.2)
        let luminance = 0.299 * glow.0 + 0.587 * glow.1 + 0.114 * glow.2
        if luminance < 0.4 {
            let boost = 0.4 / max(luminance, 0.001)
            glow = (min(glow.0 * boost, 1), min(glow.1 * boost, 1), min(glow.2 * boost, 1))
        }
        sidebarArtworkGlow = NSColor(srgbRed: glow.0, green: glow.1, blue: glow.2, alpha: 1)
        // 封面变化时立即刷新两个设备画板的预览，实时反映专辑封面变化
        if lastSidebarArtworkData != nowPlaying.artwork {
            lastSidebarArtworkData = nowPlaying.artwork
            refreshOracleCanvasPreview()
            refreshExcerptCanvasPreview()
        }
    }


    private func shouldPushDynamically(now: Date) -> Bool {
        guard let lastPushAttempt else { return true }
        return now.timeIntervalSince(lastPushAttempt) >= TimeInterval(settings.dynamicUploadSeconds)
    }

    // MARK: - 模式激活

    private func activateMode() async {
        renderPreview()
        switch settings.displayMode {
        case .codex, .qwenWork:
            await refreshData(upload: true, forceUpload: false)
        case .systemMonitor:
            _ = monitor.sample(now: Date())
            try? await Task.sleep(nanoseconds: 150_000_000)
            system = monitor.sample(now: Date())
            renderPreview()
            await push(force: true)
        case .pomodoro:
            await push(force: true)
        case .excerptQuote:
            renderPreview()
            await push(force: true)
        case .sspai:
            _ = await fetchSspai()
            renderPreview()
            await push(force: true)
        case .nowPlaying:
            await refreshNowPlaying(now: Date())
            renderPreview()
            await push(force: true)
        case .canvas:
            _ = monitor.sample(now: Date())
            try? await Task.sleep(nanoseconds: 150_000_000)
            system = monitor.sample(now: Date())
            await refreshNowPlaying(now: Date())
            // 画板含 Codex/千问额度模块时，进入即统一调取一次用量数据
            if canvasNeedsQuotaData {
                let failures = await refreshUsageAndQuota()
                if !failures.isEmpty { status = failures.joined(separator: "；") }
            }
            renderPreview()
            await push(force: true)
        case .customImage:
            if let path = settings.customImagePath,
               FileManager.default.fileExists(atPath: path) {
                lastImageRotation = Date()
                await push(force: true)
            }
        case .emojiWallpaper:
            renderPreview()
            await push(force: true)
        }
    }

    // MARK: - 数据刷新（Codex 用量 / 千问办公额度：统一调取，一次拉两个源供各功能共享）

    /// 任一画板（键盘/先知/摘录）模块组合里含 Codex 或千问额度模块
    private var canvasNeedsQuotaData: Bool {
        let lists = [settings.canvasModuleList,
                     settings.oracleCanvasModuleList,
                     settings.excerptCanvasModuleList]
        return lists.contains { list in
            list.contains { $0 == .codex || $0 == .qwenQuota }
        }
    }

    /// 设备画板（口袋先知/摘录）含「正在播放」模块且开启自动推送：
    /// 需要高频刷新播放状态，实时捕获专辑封面变化
    private var deviceCanvasNeedsLiveNowPlaying: Bool {
        (settings.oracleAutoPushEnabled && settings.oracleCanvasModuleList.contains(.nowPlaying))
            || (settings.excerptAutoPushEnabled && settings.excerptCanvasModuleList.contains(.nowPlaying))
    }

    /// 用量数据是否已过统一刷新周期
    private func isQuotaDataStale(now: Date) -> Bool {
        guard let lastQuotaRefresh else { return true }
        return now.timeIntervalSince(lastQuotaRefresh) >= TimeInterval(max(1, settings.codexRefreshSeconds))
    }

    /// 统一调取：一次并行拉取 Codex 用量与千问办公额度并更新缓存（单源失败保留旧值）。
    /// 返回失败提示列表（空 = 全部成功）。
    @discardableResult
    private func refreshUsageAndQuota() async -> [String] {
        guard !quotaRefreshing else { return [] }
        quotaRefreshing = true
        defer { quotaRefreshing = false }
        lastQuotaRefresh = Date()
        let outcome = await usageAggregator.fetch(codexCliPath: settings.codexCliPath)
        if let usage = outcome.usage { self.usage = usage }
        if let quota = outcome.quota {
            // 千问额度百分比：以用户手动捕获的基线为 100%，按 当前/基线 算剩余百分比
            // （未设置基线时 trackedProgress 为 nil，卡片显示「剩余 —%」并提示设置）
            var updated = quota
            updated.trackedProgress = QwenWorkQuota.trackedQuotaProgress(
                current: quota.remainingCredits, baseline: settings.qwenQuotaBaseline)
            qwenQuota = updated
        }
        return outcome.failures
    }

    /// 手动把当前剩余额度抓取为百分比基线（100%）；之后每次减少按 当前/基线 计算
    public func captureQuotaBaseline() {
        guard qwenQuota.remainingCredits > 0 else {
            status = "当前额度为 0，无法作为基线"
            return
        }
        settings.qwenQuotaBaseline = qwenQuota.remainingCredits
        var updated = qwenQuota
        updated.trackedProgress = 1
        qwenQuota = updated
        status = "已把当前额度 \(String(format: "%.1f", qwenQuota.remainingCredits)) 设为 100% 基线"
        persistSettings()
        renderPreview()
    }

    /// 额度百分比基线说明文字（设置页显示）
    public var quotaBaselineText: String {
        guard let baseline = settings.qwenQuotaBaseline else { return "未设置" }
        return String(format: "%.1f", baseline)
    }

    /// 剩余百分比说明文字（设置页显示；未设基线时提示）
    public var qwenQuotaPercentText: String {
        guard let tracked = qwenQuota.trackedProgress else { return "未设置基线" }
        return "剩余 \(Int((tracked * 100).rounded()))%"
    }

    /// 抓取少数派推荐文章；内容有变化返回 true（用于触发推送）
    private func fetchSspai() async -> Bool {
        do {
            let articles = try await SspaiClient.fetchLatestRecommended()
            let newHash = articles.map { "\($0.id):\($0.title)" }.joined(separator: "|")
            sspaiArticles = articles
            // 文章已刷新：随机抽取缓存失效，下次渲染重新抽取
            sspaiRandomSelection = [:]
            lastSspaiFetch = Date()
            let changed = newHash != lastSspaiHash
            lastSspaiHash = newHash
            return changed
        } catch {
            lastSspaiFetch = Date()
            status = Self.friendly(error)
            return false
        }
    }

    public func refreshData(upload: Bool, forceUpload: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        status = upload ? "正在刷新并推送…" : "正在刷新…"
        do {
            switch settings.displayMode {
            case .codex, .qwenWork, .canvas:
                // 统一调取：一次并行拉取 Codex 用量 + 千问办公额度，缓存后供各功能共享
                let failures = await refreshUsageAndQuota()
                if settings.displayMode == .canvas {
                    system = monitor.sample(now: Date())
                    nowPlaying = (try? await nowPlayingClient.fetch()) ?? nowPlaying
                }
                renderPreview()
                lastRefresh = "最后刷新：\(Self.formatNow())"
                if upload {
                    try await uploadRendered(force: forceUpload)
                } else {
                    status = failures.isEmpty ? "数据已刷新" : failures.joined(separator: "；")
                }
            case .nowPlaying:
                nowPlaying = try await nowPlayingClient.fetch()
                renderPreview()
                lastRefresh = "最后刷新：\(Self.formatNow())"
                if upload {
                    try await uploadRendered(force: forceUpload)
                } else {
                    status = "数据已刷新"
                }
            case .systemMonitor:
                system = monitor.sample(now: Date())
                renderPreview()
                lastRefresh = "最后刷新：\(Self.formatNow())"
                if upload {
                    try await uploadRendered(force: forceUpload)
                } else {
                    status = "数据已刷新"
                }
            default:
                renderPreview()
                if upload {
                    try await uploadRendered(force: forceUpload)
                }
            }
        } catch {
            renderPreview()
            status = Self.friendly(error)
        }
    }

    public func refresh() async {
        if settings.displayMode == .codex || settings.displayMode == .qwenWork {
            await refreshData(upload: false, forceUpload: false)
        } else if settings.displayMode == .nowPlaying {
            do {
                nowPlaying = try await nowPlayingClient.fetch()
                renderPreview()
                lastRefresh = "最后刷新：\(Self.formatNow())"
                status = "数据已刷新"
            } catch NowPlayingError.notPlaying {
                nowPlaying = .placeholder
                renderPreview()
                lastRefresh = "最后刷新：\(Self.formatNow())"
                status = "当前没有正在播放的媒体"
            } catch {
                status = Self.friendly(error)
            }
        } else if settings.displayMode == .systemMonitor {
            system = monitor.sample(now: Date())
            renderPreview()
            lastRefresh = "最后刷新：\(Self.formatNow())"
            status = "数据已刷新"
        } else if settings.displayMode == .excerptQuote {
            renderPreview()
            lastRefresh = "最后刷新：\(Self.formatNow())"
            status = "数据已刷新"
        } else if settings.displayMode == .sspai {
            _ = await fetchSspai()
            renderPreview()
            lastRefresh = "最后刷新：\(Self.formatNow())"
            status = "数据已刷新"
        } else if settings.displayMode == .canvas {
            system = monitor.sample(now: Date())
            do {
                nowPlaying = try await nowPlayingClient.fetch()
            } catch {
                if nowPlaying.title.isEmpty || nowPlaying.title == "未在播放" {
                    nowPlaying = .placeholder
                }
            }
            // 画板含 Codex/千问额度模块时，一次统一调取两个数据源
            if canvasNeedsQuotaData {
                let failures = await refreshUsageAndQuota()
                if !failures.isEmpty { status = failures.joined(separator: "；") }
            }
            renderPreview()
            lastRefresh = "最后刷新：\(Self.formatNow())"
            status = "数据已刷新"
        }
    }

    // MARK: - 推送

    public func pushNow() async {
        if settings.displayMode == .codex || settings.displayMode == .qwenWork {
            await refreshData(upload: true, forceUpload: true)
        } else {
            await push(force: true)
        }
    }

    /// 把当前卡片推送到 Dot 设备（dot.mindreset.tech image API）
    public func pushToDotDevice() async {
        guard !settings.dotApiKey.isEmpty, !settings.dotDeviceId.isEmpty else {
            status = "请先在「设置」中填写 Dot API Key 与设备序列号"
            return
        }
        do {
            let result = try renderCurrent()
            let png = try Self.pngData(from: result.image)
            let pushResult = try await DotImageAPIClient.push(pngData: png,
                                                              deviceId: settings.dotDeviceId,
                                                              apiKey: settings.dotApiKey)
            status = Self.dotStatusMessage(pushResult)
        } catch {
            status = Self.friendly(error)
        }
    }

    /// CGImage → PNG Data
    private static func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encodeFailed }
        return data as Data
    }

    // MARK: - 口袋先知 / 摘录 独立画板（模块组合，移植自键盘画板）

    /// 画板模块编辑目标：键盘画板与两个独立设备画板各自持有模块列表
    public enum CanvasOwner {
        case keyboard, oracle, excerpt
    }

    private func modulesKeyPath(for owner: CanvasOwner) -> ReferenceWritableKeyPath<AppSettings, [Int]> {
        switch owner {
        case .keyboard: return \AppSettings.canvasModules
        case .oracle: return \AppSettings.oracleCanvasModules
        case .excerpt: return \AppSettings.excerptCanvasModules
        }
    }

    /// 各画板「少数派推荐」显示条数（1–6，各自独立）
    func sspaiCount(for owner: CanvasOwner) -> Int {
        switch owner {
        case .keyboard: return settings.canvasSspaiCount
        case .oracle: return settings.oracleSspaiCount
        case .excerpt: return settings.excerptSspaiCount
        }
    }

    /// 各画板「少数派推荐」随机显示开关（各自独立）
    func sspaiRandomEnabled(for owner: CanvasOwner) -> Bool {
        switch owner {
        case .keyboard: return settings.canvasSspaiRandom
        case .oracle: return settings.oracleSspaiRandom
        case .excerpt: return settings.excerptSspaiRandom
        }
    }

    /// 画板要显示的少数派文章：固定显示最新 N 篇；
    /// 开启随机且文章多于显示条数时，随机抽取 N 篇（文章刷新后重新抽取并缓存）
    func sspaiDisplayArticles(for owner: CanvasOwner) -> [SspaiArticle] {
        let count = min(max(sspaiCount(for: owner), 1), 6)
        let pool = sspaiArticles
        if !sspaiRandomEnabled(for: owner) || pool.count <= count {
            return Array(pool.prefix(count))
        }
        let cached = sspaiRandomSelection[owner]
        let stale = cached == nil || cached!.count != count
            || cached!.contains { cachedArticle in
                !pool.contains { $0.id == cachedArticle.id }
            }
        if stale {
            sspaiRandomSelection[owner] = Array(pool.shuffled().prefix(count))
        }
        return sspaiRandomSelection[owner] ?? Array(pool.prefix(count))
    }

    /// 口袋先知画板预览（处理后，设备实际效果）
    @Published public var oracleCanvasImage: NSImage?
    /// 口袋先知画板处理前原始渲染
    @Published public var oracleCanvasRawImage: NSImage?
    /// 摘录画板预览（处理后，设备实际效果）
    @Published public var excerptCanvasImage: NSImage?
    /// 摘录画板处理前原始渲染
    @Published public var excerptCanvasRawImage: NSImage?

    /// 口袋先知画布：模块组合渲染为 200×200 彩色原始画面（底色按手动深色/亮色模式，
    /// 支持整体旋转 180° = 上下+左右反转，非镜像）
    private func renderOracleCanvasImage(now: Date = Date()) -> CGImage {
        let rotate = settings.oracleImageRotate180
        return ScreenRenderer.renderDeviceCanvas(modules: settings.oracleCanvasModuleList,
                                                system: monitor.sample(now: now),
                                                nowPlaying: nowPlaying, pomodoro: pomodoroSnapshot,
                                                customText: settings.canvasText, settings: settings,
                                                codex: usage, qwenQuota: qwenQuota,
                                                sspaiArticles: sspaiDisplayArticles(for: .oracle),
                                                now: now,
                                                width: ScreenRenderer.oracleCanvasSize,
                                                height: ScreenRenderer.oracleCanvasSize,
                                                palette: oraclePalette,
                                                flipVertical: rotate,
                                                flipHorizontal: rotate,
                                                nowPlayingHorizontal: settings.oracleNowPlayingHorizontal)
    }

    /// 口袋先知画板专用调色板：底色按手动深色/亮色模式固定，不随电脑或软件主题同步；
    /// 主题与强调色沿用外观设置
    var oraclePalette: ScreenPalette {
        let dark = settings.oracleBackgroundMode == .dark
        return ScreenThemes.resolved(theme: settings.cardTheme,
                                     backgroundTone: dark ? .dark : .light,
                                     customBackgroundHex: nil,
                                     accentTone: settings.accentTone,
                                     customAccentHex: settings.customAccentHex,
                                     softwareIsDark: dark)
    }

    /// 摘录画布：模块组合彩色原始渲染（296×152，支持单列/双列布局与整体旋转 180°，
    /// 未做灰阶/抖动处理）。底色按手动深色/亮色模式渲染，处理前/处理后预览与推送图一致。
    private func renderExcerptCanvasRawImage(now: Date = Date()) -> CGImage {
        // 旋转 180° = 上下反转 + 左右反转（非镜像）
        let rotate = settings.excerptImageRotate180
        return ScreenRenderer.renderDeviceCanvas(modules: settings.excerptCanvasModuleList,
                                                 system: monitor.sample(now: now),
                                                 nowPlaying: nowPlaying, pomodoro: pomodoroSnapshot,
                                                 customText: settings.canvasText, settings: settings,
                                                 codex: usage, qwenQuota: qwenQuota,
                                                 sspaiArticles: sspaiDisplayArticles(for: .excerpt),
                                                 now: now,
                                                 width: ScreenRenderer.excerptCanvasWidth,
                                                 height: ScreenRenderer.excerptCanvasHeight,
                                                 palette: excerptPalette,
                                                 flipVertical: rotate,
                                                 flipHorizontal: rotate,
                                                 columns: settings.excerptLayoutColumns,
                                                 fullWidthModules: Set(settings.excerptFullWidthModules),
                                                 nowPlayingHorizontal: settings.excerptNowPlayingHorizontal)
    }

    /// 摘录画板专用调色板：底色按手动深色/亮色模式固定，不随电脑或软件主题同步；
    /// 主题与强调色沿用外观设置
    var excerptPalette: ScreenPalette {
        let dark = settings.excerptBackgroundMode == .dark
        return ScreenThemes.resolved(theme: settings.cardTheme,
                                     backgroundTone: dark ? .dark : .light,
                                     customBackgroundHex: nil,
                                     accentTone: settings.accentTone,
                                     customAccentHex: settings.customAccentHex,
                                     softwareIsDark: dark)
    }

    /// 摘录画布：原始渲染 → 灰阶量化（本地模式用所选灰阶/抖动设置；
    /// 服务端处理模式下预览用与服务端所选抖动算法一致的本地近似）。
    /// 反色已在原始渲染源头生效，灰阶转换自然继承反色。
    private func renderExcerptCanvasImage(now: Date = Date()) -> CGImage {
        let raw = renderExcerptCanvasRawImage(now: now)
        if settings.excerptPushRawImage {
            return ScreenRenderer.grayscaleCanvasImage(from: raw,
                                                      algorithm: .luminosity,
                                                      mode: .gray4,
                                                      dither: ScreenRenderer.localDitherKernel(for: settings.excerptServerDitherType,
                                                                                               kernel: settings.excerptServerDitherKernel),
                                                      width: ScreenRenderer.excerptCanvasWidth,
                                                      height: ScreenRenderer.excerptCanvasHeight)
        }
        return ScreenRenderer.grayscaleCanvasImage(from: raw,
                                                  algorithm: settings.excerptGrayAlgorithm,
                                                  mode: settings.excerptDisplayMode,
                                                  dither: settings.excerptDitherKernel,
                                                  width: ScreenRenderer.excerptCanvasWidth,
                                                  height: ScreenRenderer.excerptCanvasHeight)
    }

    /// 实际推送给 Dot 的图片：原始彩色或本地处理后图片（反色已在源头生效）
    private func excerptPushImage() -> CGImage {
        if settings.excerptPushRawImage {
            return renderExcerptCanvasRawImage()
        }
        return renderExcerptCanvasImage()
    }

    public func refreshOracleCanvasPreview() {
        let size = CGFloat(ScreenRenderer.oracleCanvasSize)
        let raw = renderOracleCanvasImage()
        let preview = ScreenRenderer.oraclePreviewImage(from: raw,
                                                        algorithm: settings.oracleGrayAlgorithm,
                                                        mode: settings.oracleDisplayMode,
                                                        dither: settings.oracleDitherKernel)
        oracleCanvasRawImage = NSImage(cgImage: raw, size: NSSize(width: size, height: size))
        oracleCanvasImage = NSImage(cgImage: preview, size: NSSize(width: size, height: size))
    }

    public func refreshExcerptCanvasPreview() {
        let raw = renderExcerptCanvasRawImage()
        let processed = renderExcerptCanvasImage()
        let size = NSSize(width: CGFloat(ScreenRenderer.excerptCanvasWidth),
                          height: CGFloat(ScreenRenderer.excerptCanvasHeight))
        excerptCanvasRawImage = NSImage(cgImage: raw, size: size)
        excerptCanvasImage = NSImage(cgImage: processed, size: size)
    }

    /// 确保口袋先知显示模式会话已连接：保持 WebSocket 连接以接收设备按键事件
    /// （display mode 会把按键信号回传给当前连接的客户端），推送帧走同一连接、发送即显示。
    /// 下键短按 → 发起手动更新切换（重新渲染并推送当前画布）。
    public func ensureRand0Session() {
        let ip = settings.rand0IP
        let endpoint: Rand0Client.Endpoint = settings.oracleDisplayMode == .gray4 ? .gray4 : .bw
        guard !ip.isEmpty else {
            rand0Session?.disconnect()
            rand0Session = nil
            rand0SessionConnected = false
            return
        }
        // 旧配置（目标非自身但未指定具体设备）在读取时按「自身」处理（界面显示与按键分发一致），
        // 不做写侧归一——写侧归一会与 syncActiveDeviceSettings 形成递归死循环（栈溢出崩溃）
        // 目标未变且会话循环存活（已连接或正在重连）：直接复用，不打断自动重连
        if let session = rand0Session, rand0SessionIP == ip, rand0SessionEndpoint == endpoint,
           session.isActive {
            rand0SessionConnected = session.isConnected
            return
        }
        // IP 或显示模式变化：断开旧会话再建新连接
        rand0Session?.disconnect()
        rand0SessionIP = ip
        rand0SessionEndpoint = endpoint
        let session = Rand0DisplaySession()
        session.onKeyEvent = { [weak self] key, action in
            guard action == "short" else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 读取时归一：非自身但未指定具体设备（旧版配置）按「自身」处理，与界面显示一致
                let target: Rand0ButtonTarget
                if self.settings.rand0ButtonTarget != .oracle,
                   self.settings.rand0ButtonTargetDeviceID == nil {
                    target = .oracle
                } else {
                    target = self.settings.rand0ButtonTarget
                }
                switch target {
                case .oracle:
                    // 多画板：上下键循环切换画板并推送；单画板时下键手动更新画布
                    if self.settings.oracleCanvasBoards.count > 1 {
                        let direction = key == "up" ? -1 : 1
                        self.status = "设备按键：切换到\(direction == 1 ? "下一" : "上一")块画板"
                        _ = self.cycleOracleCanvasBoard(direction: direction)
                        await self.pushOracleCanvas()
                    } else if key == "down" {
                        self.status = "检测到设备下键，正在更新画布…"
                        await self.pushOracleCanvas()
                    }
                case .keyboard:
                    // 灵犀68 键盘上下翻页（上一张/下一张，循环）；指定了具体键盘则先切换过去
                    if let deviceID = self.settings.rand0ButtonTargetDeviceID {
                        self.switchDevice(type: .keyboard, to: deviceID)
                    }
                    if key == "up" {
                        self.status = "设备按键：键盘上一张"
                        self.keyboardPage(direction: -1)
                    } else if key == "down" {
                        self.status = "设备按键：键盘下一张"
                        self.keyboardPage(direction: 1)
                    }
                case .excerpt:
                    // 摘录：控制 Dot 云端内容列表（下一条）；先切换到目标摘录设备
                    if let deviceID = self.settings.rand0ButtonTargetDeviceID {
                        self.switchDevice(type: .excerpt, to: deviceID)
                    }
                    if key == "down" {
                        self.status = "设备按键：摘录内容下一条"
                        await self.dotNextContent()
                    } else if key == "up" {
                        // Dot 云端无上一页接口：上键改为推送本地摘录画板
                        self.status = "设备按键：推送摘录画板"
                        await self.pushExcerptCanvas()
                    }
                }
            }
        }
        rand0Session = session
        session.onStatusChange = { [weak self] connected in
            Task { @MainActor in
                self?.rand0SessionConnected = connected
            }
        }
        Task {
            await session.connect(ip: ip, endpoint: endpoint)
            rand0SessionConnected = session.isConnected
        }
    }

    /// 键盘翻页：按上下键方向在卡片列表中切换显示（上一张/下一张，循环）
    public func keyboardPage(direction: Int) {
        guard let mode = ScreenRenderer.pagedMode(from: settings.displayMode,
                                                  direction: direction,
                                                  modes: keyboardRotationList) else { return }
        setMode(mode)
    }

    /// 口袋先知多画板：把当前画布配置保存为一块新画板并设为当前
    public func addOracleCanvasBoard() {
        let board = OracleCanvasBoard.capture(from: settings)
        var boards = settings.oracleCanvasBoards
        boards.append(board)
        settings.oracleCanvasBoards = boards
        settings.oracleCanvasBoardIndex = boards.count - 1
        status = "已添加画板「\(board.name)」，共 \(boards.count) 块"
    }

    /// 口袋先知多画板：应用指定画板配置到当前画布（字段变化触发预览刷新）
    public func applyOracleCanvasBoard(at index: Int) {
        guard settings.oracleCanvasBoards.indices.contains(index) else { return }
        let board = settings.oracleCanvasBoards[index]
        board.apply(to: settings)
        settings.oracleCanvasBoardIndex = index
        refreshOracleCanvasPreview()
    }

    /// 口袋先知多画板：按方向循环切换画板（direction = ±1），返回是否切换成功
    @discardableResult
    public func cycleOracleCanvasBoard(direction: Int) -> Bool {
        let boards = settings.oracleCanvasBoards
        guard !boards.isEmpty else { return false }
        let count = boards.count
        let current = min(max(settings.oracleCanvasBoardIndex, 0), count - 1)
        let next = ((current + direction) % count + count) % count
        guard next != current else { return false }
        applyOracleCanvasBoard(at: next)
        return true
    }

    /// 口袋先知多画板：删除指定画板（删除当前画板时套用新的当前画板）
    public func removeOracleCanvasBoard(at index: Int) {
        guard settings.oracleCanvasBoards.indices.contains(index) else { return }
        let wasCurrent = settings.oracleCanvasBoardIndex == index
        var boards = settings.oracleCanvasBoards
        boards.remove(at: index)
        settings.oracleCanvasBoards = boards
        guard !boards.isEmpty else {
            settings.oracleCanvasBoardIndex = 0
            status = "已删除全部画板，回到默认画布"
            return
        }
        var newIndex = settings.oracleCanvasBoardIndex
        if index < newIndex { newIndex -= 1 }
        else if index == newIndex { newIndex = min(newIndex, boards.count - 1) }
        newIndex = max(0, min(newIndex, boards.count - 1))
        settings.oracleCanvasBoardIndex = newIndex
        if wasCurrent {
            boards[newIndex].apply(to: settings)
            refreshOracleCanvasPreview()
            status = "已删除画板，当前为「\(boards[newIndex].name)」"
        } else {
            status = "已删除画板"
        }
    }

    /// 口袋先知多画板：拖拽排序提交（当前画板按 id 跟随到新位置）
    public func commitOracleCanvasBoards(_ boards: [OracleCanvasBoard]) {
        guard !boards.isEmpty else { return }
        let oldIndex = min(max(settings.oracleCanvasBoardIndex, 0), settings.oracleCanvasBoards.count - 1)
        let currentID = settings.oracleCanvasBoards.indices.contains(oldIndex)
            ? settings.oracleCanvasBoards[oldIndex].id : nil
        settings.oracleCanvasBoards = boards
        if let currentID, let newIndex = boards.firstIndex(where: { $0.id == currentID }) {
            settings.oracleCanvasBoardIndex = newIndex
        } else {
            settings.oracleCanvasBoardIndex = 0
        }
    }

    /// 口袋先知多画板：当前画板名（无画板时为「默认画布」）
    public var oracleCanvasBoardName: String {
        let index = settings.oracleCanvasBoardIndex
        guard settings.oracleCanvasBoards.indices.contains(index) else { return "默认画布" }
        return settings.oracleCanvasBoards[index].name
    }

    /// 推送口袋先知画板到 Rand/0 设备（按所选显示模式与灰阶算法生成帧）。
    /// 优先走持久会话（保持按键监听、发送即显示）；会话不可用时回退一次性推送。
    public func pushOracleCanvas() async {
        guard !settings.rand0IP.isEmpty else {
            status = "请先在「口袋先知画板」中填写 Rand/0 设备 IP"
            return
        }
        // 确保会话已建立：推送同时保持按键监听（自动重连由会话负责）
        ensureRand0Session()
        do {
            let image = renderOracleCanvasImage()
            let frame = ScreenRenderer.oracleFrame(from: image,
                                                   algorithm: settings.oracleGrayAlgorithm,
                                                   mode: settings.oracleDisplayMode,
                                                   dither: settings.oracleDitherKernel)
            let endpoint: Rand0Client.Endpoint = settings.oracleDisplayMode == .gray4 ? .gray4 : .bw
            // 会话循环存活（含断线重连中）一律走会话推送：内部等待连接就绪，绝不另开竞争连接
            if let session = rand0Session, rand0SessionIP == settings.rand0IP,
               rand0SessionEndpoint == endpoint, session.isActive {
                try await session.push(frame: frame, ip: settings.rand0IP, endpoint: endpoint)
            } else {
                try await Rand0Client.pushFrame(frame, ip: settings.rand0IP, endpoint: endpoint)
            }
            status = "已推送到 Rand/0 设备（\(settings.oracleDisplayMode.title)）"
            lastOraclePushedHash = frame
        } catch {
            status = Self.friendly(error)
        }
    }

    /// 把摘录设备的内容切换到 Dot 云端内容列表的下一项（设备内容循环）
    public func dotNextContent() async {
        guard !settings.dotApiKey.isEmpty, !settings.dotDeviceId.isEmpty else {
            status = "请先在「设备管理」中设置摘录设备的 API Key 与序列号"
            return
        }
        do {
            let message = try await DotImageAPIClient.switchNext(deviceId: settings.dotDeviceId,
                                                                 apiKey: settings.dotApiKey)
            status = message.isEmpty ? "已切换摘录内容到下一条" : "已切换摘录内容：\(message)"
        } catch {
            status = Self.friendly(error)
        }
    }

    /// 推送摘录画板到 Dot 设备（image API，296×152 固定分辨率）
    public func pushExcerptCanvas() async {
        guard !settings.dotApiKey.isEmpty, !settings.dotDeviceId.isEmpty else {
            status = "请先在「摘录画板」中填写 Dot API Key 与设备序列号"
            return
        }
        do {
            // 原始彩色推送时跳过本地灰阶/抖动处理，由 Dot 服务端按官方指南
            // 使用所选 ditherType/ditherKernel 自行转换；本地处理后推送用 NONE 保留本地抖动。
            // 浅色模式（反色）在推送图上取反。
            let rawPush = settings.excerptPushRawImage
            let png = try Self.pngData(from: excerptPushImage())
            let pushResult = try await DotImageAPIClient.push(pngData: png,
                                                              deviceId: settings.dotDeviceId,
                                                              apiKey: settings.dotApiKey,
                                                              ditherType: rawPush ? settings.excerptServerDitherType.apiValue : "NONE",
                                                              ditherKernel: rawPush ? settings.excerptServerDitherKernel.apiValue : nil)
            status = Self.dotStatusMessage(pushResult)
            lastExcerptPushedHash = png
        } catch {
            status = Self.friendly(error)
        }
    }

    /// 口袋先知画板定时推送开关（开启后下一拍立即推送一次，之后按间隔）
    public func setOracleAutoPushEnabled(_ enabled: Bool) {
        settings.oracleAutoPushEnabled = enabled
        if enabled {
            lastOracleAutoPush = nil
            // 开启自动推送时保持显示模式会话，接收按键事件并让推送即时上屏
            ensureRand0Session()
        }
    }

    /// 摘录画板定时推送开关（开启后下一拍立即推送一次，之后按间隔）
    public func setExcerptAutoPushEnabled(_ enabled: Bool) {
        settings.excerptAutoPushEnabled = enabled
        if enabled { lastExcerptAutoPush = nil }
    }

    /// 独立画板自动推送：到点推送（兜底）；两次间隔之间若画布内容变化
    /// （专辑封面/时间/语录等）也立即推送。设备地址未配置时静默跳过。
    /// lastPush 为 nil 表示刚开启开关，应立即推送一次。
    private func maybeAutoPushDeviceCanvases(now: Date) async {
        if settings.oracleAutoPushEnabled, !settings.rand0IP.isEmpty {
            if isAutoPushDue(lastPush: lastOracleAutoPush, now: now,
                             intervalMinutes: settings.oracleAutoPushMinutes) {
                lastOracleAutoPush = now
                await pushOracleCanvas()
            } else if isContentCheckDue(lastCheck: lastOracleContentCheck, now: now) {
                lastOracleContentCheck = now
                // 已有推送基线且内容变化 → 立即推送
                if let baseline = lastOraclePushedHash, oracleCanvasContentHash() != baseline {
                    lastOracleAutoPush = now
                    await pushOracleCanvas()
                }
            }
        }
        if settings.excerptAutoPushEnabled, !settings.dotApiKey.isEmpty, !settings.dotDeviceId.isEmpty {
            if isAutoPushDue(lastPush: lastExcerptAutoPush, now: now,
                             intervalMinutes: settings.excerptAutoPushMinutes) {
                lastExcerptAutoPush = now
                await pushExcerptCanvas()
            } else if isContentCheckDue(lastCheck: lastExcerptContentCheck, now: now) {
                lastExcerptContentCheck = now
                if let baseline = lastExcerptPushedHash, excerptCanvasContentHash() != baseline {
                    lastExcerptAutoPush = now
                    await pushExcerptCanvas()
                }
            }
        }
    }

    private func isAutoPushDue(lastPush: Date?, now: Date, intervalMinutes: Int) -> Bool {
        guard let lastPush else { return true }
        return now.timeIntervalSince(lastPush) >= TimeInterval(max(1, intervalMinutes) * 60)
    }

    /// 内容变化检查节流（每 5 秒渲染对比一次，避免每秒重渲染）
    private func isContentCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= 5
    }

    /// 口袋先知画布当前内容指纹（灰阶帧字节；封面/时间/语录变化都会改变）
    private func oracleCanvasContentHash() -> Data {
        let image = renderOracleCanvasImage()
        return ScreenRenderer.oracleFrame(from: image,
                                          algorithm: settings.oracleGrayAlgorithm,
                                          mode: settings.oracleDisplayMode,
                                          dither: settings.oracleDitherKernel)
    }

    /// 摘录画布当前内容指纹（推送 PNG 字节）
    private func excerptCanvasContentHash() -> Data? {
        try? Self.pngData(from: excerptPushImage())
    }

    /// Dot 推送状态文案：优先显示服务器返回的 message（如设备离线/休眠提示）
    private static func dotStatusMessage(_ result: DotImageAPIClient.DotPushResult) -> String {
        if result.message.isEmpty {
            return "已推送到 Dot 设备（HTTP \(result.statusCode)）"
        }
        return result.message
    }

    /// Dot 设备状态行（在线/离线、上次刷新、下次刷新）
    @Published public var dotDeviceStatusText = ""

    /// 查询 Dot 设备状态，用于诊断推送后不上屏的问题
    public func checkDotDeviceStatus() async {
        guard !settings.dotApiKey.isEmpty, !settings.dotDeviceId.isEmpty else {
            dotDeviceStatusText = "请先填写 API Key 与设备序列号"
            return
        }
        do {
            let s = try await DotImageAPIClient.fetchStatus(deviceId: settings.dotDeviceId,
                                                            apiKey: settings.dotApiKey)
            var text = "状态：\(s.state.isEmpty ? "未知" : s.state)"
            if !s.lastRender.isEmpty {
                text += " · 上次刷新 \(s.lastRender)"
            }
            if !s.nextPower.isEmpty {
                text += " · 下次 \(s.nextPower)"
            }
            if !s.detail.isEmpty {
                text += " · \(s.detail)"
            }
            dotDeviceStatusText = text
        } catch {
            dotDeviceStatusText = Self.friendly(error)
        }
    }

    /// Dot 设备循环内容列表（摘录等内容项）
    @Published public var dotTaskList: [DotImageAPIClient.DotTaskItem] = []
    /// 内容列表获取状态文案
    @Published public var dotTaskListText = ""
    /// 「下一个内容」切换状态文案
    @Published public var dotSwitchStatus = ""

    /// 获取 Dot 设备的内容列表（loop 循环内容），便于确认摘录内容项是否存在
    public func fetchDotTasks() async {
        guard !settings.dotApiKey.isEmpty, !settings.dotDeviceId.isEmpty else {
            dotTaskListText = "请先填写 API Key 与设备序列号"
            return
        }
        do {
            let items = try await DotImageAPIClient.listTasks(deviceId: settings.dotDeviceId,
                                                              apiKey: settings.dotApiKey)
            dotTaskList = items
            dotTaskListText = items.isEmpty ? "设备内容列表为空" : "共 \(items.count) 项内容"
        } catch {
            dotTaskListText = Self.friendly(error)
        }
    }

    /// 立即切换到设备内容循环中的下一个内容（无需等待计划刷新时间）
    public func switchDotNext() async {
        guard !settings.dotApiKey.isEmpty, !settings.dotDeviceId.isEmpty else {
            dotSwitchStatus = "请先填写 API Key 与设备序列号"
            return
        }
        do {
            let message = try await DotImageAPIClient.switchNext(deviceId: settings.dotDeviceId,
                                                                 apiKey: settings.dotApiKey)
            dotSwitchStatus = message.isEmpty ? "已切换到下一个内容" : message
            status = message.isEmpty ? "已切换到下一个内容" : message
        } catch {
            dotSwitchStatus = Self.friendly(error)
        }
    }

    private func push(force: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await uploadRendered(force: force)
        } catch {
            status = Self.friendly(error)
        }
    }

    private func uploadRendered(force: Bool) async throws {
        // 键盘仅支持 JPEG（质量可调，100 = 4:4:4 无彩色抽样、画质接近无损）
        let jpeg = try renderBytes()
        let hash = Self.sha256(jpeg)
        lastPushAttempt = Date()
        if !force && hash == lastUploadedHash {
            status = "画面未变化，无需重复推送"
            return
        }
        status = "正在推送到键盘…"
        let statusCode = try await imageApi.upload(jpeg, contentType: "image/jpeg", endpoint: settings.endpoint)
        lastUploadedHash = hash
        lastPush = "最后推送：\(Self.formatNow())"
        status = "推送成功（HTTP \(statusCode)）"
    }

    // MARK: - 番茄钟

    public var pomodoroSnapshot: PomodoroSnapshot {
        pomodoro.snapshot(now: Date())
    }

    /// 番茄钟状态实例（任务名与各阶段时长，供设置界面绑定）。
    public var pomodoroState: PomodoroState {
        pomodoro.state
    }

    public var pomodoroAction: String {
        let snapshot = pomodoroSnapshot
        return snapshot.isRunning ? "暂停" : snapshot.isPaused ? "继续" : "开始"
    }

    public var pomodoroStatus: String {
        let snapshot = pomodoroSnapshot
        let phase: String
        switch snapshot.phase {
        case .focus: phase = "专注中"
        case .shortBreak: phase = "短休息"
        case .longBreak: phase = "长休息"
        case .paused: phase = "已暂停"
        case .idle: phase = "尚未开始"
        }
        let remaining = Self.formatClock(snapshot.remaining)
        return "\(phase) · \(remaining) · 已完成 \(snapshot.completedFocusSessions) 轮"
    }

    public var systemStatus: String {
        "CPU \(Int(system.cpuPercent.rounded()))% · 内存 \(Int(system.memoryPercent.rounded()))% · ↓ \(ScreenRenderer.formatRate(system.downloadBytesPerSecond)) · ↑ \(ScreenRenderer.formatRate(system.uploadBytesPerSecond))"
    }

    public var customImageName: String {
        guard let name = settings.customImageName, !name.isEmpty else { return "尚未选择图片" }
        return name
    }

    /// 千问办公额度摘要文本
    public var qwenQuotaText: String {
        let plan = qwenQuota.plan.map { "\($0) · " } ?? ""
        return "\(plan)剩余 \(String(format: "%.1f", qwenQuota.remainingCredits)) \(qwenQuota.unit)"
    }

    /// 正在播放摘要文本
    public var nowPlayingSummary: String {
        guard !nowPlaying.title.isEmpty, nowPlaying.title != "未在播放" else { return "未在播放" }
        let state = nowPlaying.isPlaying ? "播放中" : "已暂停"
        var parts = [nowPlaying.title]
        if !nowPlaying.artist.isEmpty { parts.append(nowPlaying.artist) }
        if nowPlaying.duration > 0 {
            let remaining = max(0, nowPlaying.duration - nowPlaying.elapsedTime)
            parts.append("剩余 \(Self.formatClock(remaining))")
        }
        parts.append(state)
        return parts.joined(separator: " · ")
    }

    // MARK: 番茄钟配置编辑

    public func setTaskName(_ name: String) {
        guard pomodoro.state.taskName != name else { return }
        pomodoro.state.taskName = name
        store.savePomodoro(pomodoro.state)
        renderPreview()
    }

    public func setFocusMinutes(_ value: Int) {
        let clamped = min(max(value, 1), 120)
        guard pomodoro.state.focusMinutes != clamped else { return }
        pomodoro.state.focusMinutes = clamped
        store.savePomodoro(pomodoro.state)
        renderPreview()
    }

    public func setShortBreakMinutes(_ value: Int) {
        let clamped = min(max(value, 1), 60)
        guard pomodoro.state.shortBreakMinutes != clamped else { return }
        pomodoro.state.shortBreakMinutes = clamped
        store.savePomodoro(pomodoro.state)
        renderPreview()
    }

    public func setLongBreakMinutes(_ value: Int) {
        let clamped = min(max(value, 1), 120)
        guard pomodoro.state.longBreakMinutes != clamped else { return }
        pomodoro.state.longBreakMinutes = clamped
        store.savePomodoro(pomodoro.state)
        renderPreview()
    }

    public func togglePomodoro() async {
        let now = Date()
        let snapshot = pomodoro.snapshot(now: now)
        if snapshot.isRunning {
            pomodoro.pause(now: now)
        } else {
            pomodoro.startOrResume(now: now)
        }
        store.savePomodoro(pomodoro.state)
        renderPreview()
        await push(force: true)
    }

    public func skipPomodoro() async {
        pomodoro.skip(now: Date())
        store.savePomodoro(pomodoro.state)
        renderPreview()
        await push(force: true)
    }

    public func resetPomodoro() async {
        pomodoro.reset()
        store.savePomodoro(pomodoro.state)
        renderPreview()
        await push(force: true)
    }

    /// 每完成一个时间段：设置夸夸文案并在任何界面下立即推送夸夸卡
    private func showPraise(now: Date) async {
        let text: String
        if settings.pomodoroPraiseSource == .hitokoto {
            text = await PomodoroService.fetchHitokoto() ?? PomodoroService.randomPraisePhrase()
        } else {
            text = PomodoroService.randomPraisePhrase()
        }
        praiseText = text
        praiseUntil = now.addingTimeInterval(Self.praiseDisplaySeconds)
        renderPreview()
        await push(force: true)
    }

    // MARK: - 自定义图片

    public func pickCustomImage() async {
        let panel = NSOpenPanel()
        panel.title = "选择要显示的图片"
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url) else {
            status = "无法读取所选图片"
            return
        }
        showCropEditor(image: image, sourceURL: url)
    }

    /// 弹出裁切编辑器，按屏幕显示区域比例选择图片显示部分
    private func showCropEditor(image: NSImage, sourceURL: URL) {
        let editor = CropEditorView(
            sourceImage: image,
            safeAreaHeight: settings.safeAreaHeight,
            onConfirm: { [weak self] cropped in
                Task { @MainActor in
                    await self?.applyCroppedImage(cropped, sourceURL: sourceURL)
                }
            },
            onCancel: { [weak self] in
                Task { @MainActor in
                    self?.closeCropEditor()
                }
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "裁切图片"
        // 手动管理窗口生命周期：releasedWhenClosed=true（默认）会让 close() 再向
        // 自动释放池排一个 release，而窗口已随 block 引用提前析构，排空池时
        // objc_release 踩到已释放内存 → SIGSEGV。改为 false 由引用计数自行管理。
        window.isReleasedWhenClosed = false
        // macOS 26：close() 的缩放退出动画(_NSWindowTransformAnimation)在 SwiftUI
        // 按钮事件链里析构托管视图时会野指针闪退，禁用该动画规避
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: editor)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        cropWindow = window
    }

    /// 把裁切后的图片保存为自定义图片并推送
    private func applyCroppedImage(_ cropped: CGImage, sourceURL: URL) async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("linx-crop-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let dest = CGImageDestinationCreateWithURL(
            tempURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            status = "无法生成裁切图片"
            return
        }
        CGImageDestinationAddImage(dest, cropped, nil)
        guard CGImageDestinationFinalize(dest) else {
            status = "无法生成裁切图片"
            return
        }
        closeCropEditor()
        await setCustomImage(url: tempURL, displayName: sourceURL.lastPathComponent)
    }

    private func closeCropEditor() {
        guard let window = cropWindow else { return }
        cropWindow = nil
        // 不能同步 close()：窗口仍在 SwiftUI 按钮事件栈里，托管视图随事件链析构，
        // macOS 26 的退出动画对象会持引用已释放的窗口内容，在下一帧 CA 提交时野指针闪退。
        // 延后到下一 runloop 执行，并禁用动画（创建时已设置 .none，这里双保险）。
        window.animationBehavior = .none
        DispatchQueue.main.async { window.close() }
    }

    public func setCustomImage(url: URL, displayName: String? = nil) async {
        do {
            let destination = try store.saveHistoryImage(from: url)
            let name = displayName ?? url.lastPathComponent
            settings.customImagePath = destination.path
            settings.customImageName = name
            settings.customImageHistory = RecentImage.upsert(
                settings.customImageHistory,
                new: RecentImage(path: destination.path, name: name),
                limit: 9)
            settings.displayMode = .customImage
            lastImageRotation = Date()
            persistSettings()
            renderPreview()
            await push(force: true)
        } catch {
            status = Self.friendly(error)
        }
    }

    /// 应用历史记录中的一张图片（置顶并重新推送）
    public func applyImageHistory(_ entry: RecentImage) async {
        guard FileManager.default.fileExists(atPath: entry.path) else {
            status = "该图片文件已不存在，可在「清除历史记录」中移除"
            settings.customImageHistory = settings.customImageHistory.filter { $0.path != entry.path }
            persistSettings()
            return
        }
        settings.customImageHistory = RecentImage.upsert(
            settings.customImageHistory,
            new: RecentImage(path: entry.path, name: entry.name),
            limit: 9)
        settings.customImagePath = entry.path
        settings.customImageName = entry.name
        settings.displayMode = .customImage
        lastImageRotation = Date()
        persistSettings()
        renderPreview()
        await push(force: true)
    }

    /// 清除图片历史记录（保留当前正在显示的图片文件）
    public func clearImageHistory() {
        store.clearHistoryFiles(keepingCurrentPath: settings.customImagePath)
        settings.customImageHistory = []
        persistSettings()
        status = "已清除图片历史记录"
    }

    /// 开启/关闭最近图片定时轮换（开启时重置轮换时钟）
    public func setImageRotationEnabled(_ enabled: Bool) {
        settings.imageRotationEnabled = enabled
        if enabled { lastImageRotation = Date() }
        persistSettings()
    }

    // MARK: - 侧栏排序

    /// 当前生效的主菜单项顺序（外观/设置固定置底，不参与排序）
    var orderedMainPanels: [Panel] {
        Panel.orderedMainItems(settings.sidebarOrder)
    }

    /// 键盘功能项分组（可排序；设备画板单独分组）
    var orderedKeyboardPanels: [Panel] {
        Panel.orderedKeyboardItems(settings.sidebarOrder)
    }

    /// 设备画板分组（口袋先知/摘录，独立分组，排在键盘功能项之后）
    var orderedCanvasPanels: [Panel] {
        Panel.orderedCanvasItems(settings.sidebarOrder)
    }

    /// 上移 / 下移一个主菜单项，并持久化顺序
    func moveSidebarItem(_ panel: Panel, up: Bool) {
        let panels = orderedMainPanels
        guard let index = panels.firstIndex(of: panel) else { return }
        let target = up ? index - 1 : index + 1
        guard target >= 0, target < panels.count else { return }
        var reordered = panels
        reordered.swapAt(index, target)
        settings.sidebarOrder = reordered.map(\.rawValue)
        persistSettings()
    }

    /// 拖拽排序：把 panel 移到 target 之前（after=false）或之后（after=true），并持久化顺序
    func moveSidebarItem(_ panel: Panel, before target: Panel, after: Bool = false) {
        guard panel != target else { return }
        var panels = orderedMainPanels
        guard panels.contains(panel), panels.contains(target) else { return }
        panels.removeAll { $0 == panel }
        if let index = panels.firstIndex(of: target) {
            panels.insert(panel, at: after ? index + 1 : index)
        } else {
            panels.append(panel)
        }
        settings.sidebarOrder = panels.map(\.rawValue)
        persistSettings()
    }

    /// 拖拽排序完成：一次性提交菜单栏顺序（键盘功能项与设备画板两组，合并持久化）
    func commitSidebarOrder(_ panels: [Panel]) {
        settings.sidebarOrder = panels.map(\.rawValue)
        persistSettings()
    }

    /// 两组分别排序后合并提交：设备画板组始终跟在键盘功能项组之后
    func commitSidebarOrder(keyboard: [Panel], canvases: [Panel]) {
        settings.sidebarOrder = (keyboard + canvases).map(\.rawValue)
        persistSettings()
    }

    // MARK: - 卡片管理（排序 / 侧栏显示 / 自动循环，按键盘设备独立）

    /// 某台键盘设备侧栏显示的卡片（有序可见列表；nil = 旧设备未配置，回退侧栏排序的全部卡片）
    func keyboardCardList(for deviceID: UUID) -> [Panel] {
        guard let device = settings.devices.first(where: { $0.id == deviceID }) else { return [] }
        if let panels = device.settings.keyboardCardPanels {
            return panels.compactMap(Panel.init(rawValue:))
        }
        // 未配置（旧设备）：按侧栏排序派生全部卡片
        return Panel.orderedKeyboardItems(settings.sidebarOrder)
            .filter { $0 != .nowPlaying && $0 != .devices && $0 != .cardRotation }
    }

    /// 活动键盘设备的可见卡片列表
    var activeKeyboardCardList: [Panel] {
        guard let device = activeDevice(for: .keyboard) else { return [] }
        return keyboardCardList(for: device.id)
    }

    /// 活动键盘设备未显示在侧栏的卡片（供「添加到侧栏」）
    var keyboardHiddenCardList: [Panel] {
        let visible = Set(activeKeyboardCardList.map(\.rawValue))
        return Panel.orderedKeyboardItems(settings.sidebarOrder)
            .filter { $0 != .nowPlaying && $0 != .devices && $0 != .cardRotation && !visible.contains($0.rawValue) }
    }

    /// 设置活动键盘设备某张卡片是否显示在侧栏（先写全局镜像再写设备快照，防 sync 覆盖）
    func setKeyboardCardVisible(_ panel: Panel, visible: Bool) {
        guard let device = activeDevice(for: .keyboard),
              let index = settings.devices.firstIndex(where: { $0.id == device.id }) else { return }
        var list = keyboardCardList(for: device.id)
        if visible {
            if !list.contains(panel) { list.append(panel) }
        } else {
            list.removeAll { $0 == panel }
        }
        let raw = list.map(\.rawValue)
        settings.keyboardCardPanels = raw       // 镜像先行
        settings.devices[index].settings.keyboardCardPanels = raw
        persistSettings()
    }

    /// 卡片管理拖拽排序提交：先写全局镜像再写设备快照，防 sync 覆盖
    func commitKeyboardCardOrder(_ cards: [Panel]) {
        guard let device = activeDevice(for: .keyboard),
              let index = settings.devices.firstIndex(where: { $0.id == device.id }) else { return }
        let raw = cards.map(\.rawValue)
        settings.keyboardCardPanels = raw
        settings.devices[index].settings.keyboardCardPanels = raw
        persistSettings()
    }

    /// 键盘自动轮换序列：活动键盘设备侧栏可见且加入自动循环的卡片，按侧栏顺序
    var keyboardRotationList: [DisplayMode] {
        activeKeyboardCardList
            .filter { panel in
                guard let mode = panel.displayMode else { return false }
                return settings.cardRotationModes.contains(mode.rawValue)
            }
            .compactMap(\.displayMode)
    }

    /// 恢复默认侧栏顺序
    public func resetSidebarOrder() {
        settings.sidebarOrder = []
        persistSettings()
        status = "已恢复默认菜单顺序"
    }

    // MARK: - 菜单栏目标键盘（多台键盘时指定快捷切换控制哪一台）

    /// 菜单栏切换目标绑定（"follow" = 跟随当前活动键盘；"kb:uuid" = 指定键盘）
    public func menuBarTargetBinding() -> Binding<String> {
        Binding(get: {
            guard let id = self.settings.menuBarKeyboardDeviceID else { return "follow" }
            return "kb:\(id.uuidString)"
        }, set: { key in
            if key == "follow" {
                self.settings.menuBarKeyboardDeviceID = nil
            } else if key.hasPrefix("kb:"), let id = UUID(uuidString: String(key.dropFirst(3))) {
                self.settings.menuBarKeyboardDeviceID = id
            }
            self.persistSettings()
        })
    }

    /// 菜单栏动作前先切到目标键盘（指定了目标且该设备已启用时）
    private func ensureMenuBarKeyboard() {
        guard let targetID = settings.menuBarKeyboardDeviceID,
              let target = enabledDevices(for: .keyboard).first(where: { $0.id == targetID }) else { return }
        switchDevice(type: .keyboard, to: target.id)
    }

    /// 菜单栏切换显示内容：先切到目标键盘再设置模式
    public func menuBarSetMode(_ mode: DisplayMode) {
        ensureMenuBarKeyboard()
        setMode(mode)
    }

    /// 菜单栏立即推送：先切到目标键盘再推送
    public func menuBarPushNow() {
        ensureMenuBarKeyboard()
        Task { await pushNow() }
    }

    // MARK: - 模式 / 主题 / 登录自启

    public func setMode(_ mode: DisplayMode) {
        guard settings.displayMode != mode else { return }
        settings.displayMode = mode
        persistSettings()
        Task { await activateMode() }
    }

    public func setTheme(_ theme: CardTheme) {
        guard settings.cardTheme != theme else { return }
        settings.cardTheme = theme
        persistSettings()
        renderPreview()
    }

    public func setStartWithSystem(_ enabled: Bool) {
        do {
            try startup.setEnabled(enabled)
            settings.startWithSystem = enabled
            persistSettings()
            status = enabled ? "已启用登录时自动启动" : "已关闭登录时自动启动"
        } catch {
            status = Self.friendly(error)
        }
    }

    // MARK: - 渲染

    public func renderBytes() throws -> Data {
        try renderCurrent().data
    }

    private func renderCurrent() throws -> RenderResult {
        // 夸夸卡：完成时间段后的展示窗口内，任何界面都优先显示夸夸内容
        if let text = praiseText, let until = praiseUntil, Date() < until {
            return try ScreenRenderer.renderPraise(text: text,
                                                   sessions: pomodoroSnapshot.completedFocusSessions,
                                                   settings: settings)
        }
        switch settings.displayMode {
        case .pomodoro:
            return try ScreenRenderer.renderPomodoro(pomodoroSnapshot, settings: settings)
        case .systemMonitor:
            return try ScreenRenderer.renderSystem(system, history: monitor.networkHistory, settings: settings)
        case .customImage:
            guard let path = settings.customImagePath,
                  FileManager.default.fileExists(atPath: path) else {
                throw RenderError.noCustomImage
            }
            return try ScreenRenderer.renderCustomImage(path: path, settings: settings)
        case .qwenWork:
            return try ScreenRenderer.renderQwenWork(qwenQuota, settings: settings)
        case .excerptQuote:
            return try ScreenRenderer.renderExcerptQuote(quote: quoteDisplayText, settings: settings, now: Date())
        case .sspai:
            return try ScreenRenderer.renderSspai(articles: sspaiArticles, settings: settings, now: Date())
        case .emojiWallpaper:
            return try ScreenRenderer.renderEmojiWallpaper(settings: settings, now: Date())
        case .nowPlaying:
            let artwork = cachedArtworkImage(for: nowPlaying.artwork)
            return try ScreenRenderer.renderNowPlaying(nowPlaying, settings: settings, artworkImage: artwork)
        case .codex:
            return try ScreenRenderer.renderUsage(usage, settings: settings)
        case .canvas:
            return try ScreenRenderer.renderCanvas(
                modules: settings.canvasModuleList, system: system,
                nowPlaying: nowPlaying, pomodoro: pomodoroSnapshot,
                customText: settings.canvasText, settings: settings,
                codex: usage, qwenQuota: qwenQuota,
                sspaiArticles: sspaiDisplayArticles(for: .keyboard))
        }
    }

    /// 封面解码缓存：数据未变时复用 CGImage，避免每秒重复解码
    private func cachedArtworkImage(for data: Data?) -> CGImage? {
        guard let data else {
            cachedArtwork = nil
            return nil
        }
        if let cached = cachedArtwork, cached.data == data {
            return cached.image
        }
        guard let image = ScreenRenderer.decodeArtwork(data) else { return nil }
        cachedArtwork = (data, image)
        return image
    }

    private func renderPreview() {
        do {
            let result = try renderCurrent()
            previewImage = NSImage(cgImage: result.image, size: NSSize(width: 142, height: 428))
        } catch {
            status = Self.friendly(error)
        }
    }

    // MARK: - 持久化

    private func persistSettings() {
        store.save(settings)
    }

    // MARK: - 工具

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func formatNow() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm:ss"
        return formatter.string(from: Date())
    }

    private static func formatClock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(ceil(interval)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func friendly(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - 系统权限

    /// 辅助功能（辅助功能/输入事件）是否已授权
    public var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// 输入监控是否已授权
    public var listenEventGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」
    public func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    /// 打开「系统设置 → 隐私与安全性 → 输入监控」
    public func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    private func openPrivacyPane(_ identifier: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(identifier)") else { return }
        NSWorkspace.shared.open(url)
        status = "请在系统设置中允许 LinxDisplay，并勾选快捷操作"
    }
}
