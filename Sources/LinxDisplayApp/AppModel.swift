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

/// 设备管理页复用的 Bambu 实体目录。只在 HA 全量实体列表变化时构建一次，
/// 避免 SwiftUI 每次刷新、每台打印机都重新筛选和排序完整实体池。
struct BambuEntityCatalog {
    var printerEntities: [HAEntity] = []
    var pictureEntities: [HAEntity] = []
    var cameraEntities: [HAEntity] = []
    var taskCoverEntities: [HAEntity] = []
    var defaultStatusEntities: [HAEntity] = []
    var allStatusEntities: [HAEntity] = []

    init(entities: [HAEntity] = []) {
        printerEntities = HAEntityPicker.printerRelevant(entities)
        pictureEntities = printerEntities.filter {
            let domain = HAEntityPicker.domain(of: $0.entityId)
            return domain == "image" || domain == "camera"
        }
        // 摄像头与任务封面分别建立候选目录，避免两个选择器混入彼此的实体。
        // 手动选择不能要求 image.* 当前已经带 entity_picture：部分 HA 集成只在
        // 实际请求时生成地址。严格的可抓取检查只用于自动匹配，不用于隐藏候选。
        cameraEntities = BambuEntityMatcher.pictureCandidates(
            pictureEntities, source: .camera, requireAvailablePicture: false)
        taskCoverEntities = BambuEntityMatcher.pictureCandidates(
            pictureEntities, source: .taskCover, requireAvailablePicture: false)
        defaultStatusEntities = BambuEntityMatcher.printStatusCandidates(
            printerEntities, useDefaultFilter: true)
        allStatusEntities = BambuEntityMatcher.printStatusCandidates(
            printerEntities, useDefaultFilter: false)
    }
}

private struct BambuCameraZoomRuntime {
    var state = BambuCameraZoomState()
    var taskName = ""
}

/// 应用总控：每秒时钟驱动渲染与推送，逻辑对齐原版 MainViewModel。
@MainActor
public final class AppModel: ObservableObject {
    private let store = SettingsStore()
    private let codex = CodexRateLimitClient()
    private let ccSwitchQuota = CCSwitchQuotaClient()
    private let quotaClient = QwenWorkQuotaClient()
    private let nowPlayingClient = NowPlayingClient()
    private let imageApi = ImageApiClient()
    private let formlabsClient = FormlabsClient()
    private let esp8266Flasher = ESP8266FirmwareFlasher()
    private var aiMacDiscoveryTask: Task<String, Error>?
    private let monitor = SystemMonitor()
    private let startup = StartupManager()
    private let pomodoro: PomodoroService
    /// 灵犀68 Fn + 旋钮翻页：运行期 HID 独占控制器（默认不启动）。
    private var lingxi68KnobController: Lingxi68KnobController?

    private var timer: Timer?
    /// 用量数据（Codex 用量 + 千问办公额度）统一刷新时间：各功能共用同一刷新周期
    private var lastQuotaRefresh: Date?
    private var lastPushAttempt: Date?
    /// 键盘独立番茄钟上次已推送的倒计刻度，与全局推送周期解耦。
    private var lastPomodoroPushAlignedSeconds: Int?
    private var lastUploadedHash: String?
    private var lastNowPlayingFetch: Date?
    private var lastTickDate: Date?
    private var lastPreviewRender: Date?
    private var lastImageRotation: Date?
    /// 当前自定义图片的文件修订指纹。即使路径不变，只要内容被替换也会重新取色。
    private var lastCustomImageRevision: String?
    /// AI Mac 小屏幕按设备保存能力、内容指纹与推送节流状态，不与键盘上传状态混用。
    private var aiMacScreenCapabilities: [UUID: AIMacScreenCapabilities] = [:]
    private var aiMacScreenLastHashes: [UUID: String] = [:]
    private var aiMacScreenLastPushAt: [UUID: Date] = [:]
    private var aiMacScreenLastBoardRotation: [UUID: Date] = [:]
    private var aiMacScreenLastCardRotation: [UUID: Date] = [:]
    private var aiMacSspaiRandomSelection: [String: [SspaiArticle]] = [:]
    private var lastClockMinute: Int?
    private var lastCardRotation: Date?
    /// 设置连续变化时合并为一次键盘推送，避免滑块/文本编辑逐帧上传。
    private var cardSettingsPushTask: Task<Void, Never>?
    /// Bambu 图片来源或图片实体快速切换时取消旧请求，防止旧帧回写新选择。
    private var bambuPictureRefreshTask: Task<Void, Never>?
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
    /// 打印成功庆祝：打印机名与展示截止时间（到期后恢复正常卡片）
    private var printSuccessName: String?
    /// 完成庆祝卡上展示的具体任务名（取完成瞬间该打印机的任务实体）
    private var printSuccessTask: String?
    /// 完成瞬间抓到的画面（打印机摄像头最后一帧 / 模型封面）
    private var printSuccessImage: Data?
    private var printSuccessUntil: Date?
    /// 各打印机最近一次状态（用于检测「非完成 → 完成」的跳变，只在跳变时推送庆祝）
    private var lastPrinterStatuses: [UUID: String] = [:]
    private var cachedArtwork: (data: Data, image: CGImage)?
    private var busy = false
    /// 用量统一调取进行中（防止长耗时拉取重叠）
    private var quotaRefreshing = false
    /// Home Assistant 拉取进行中 / 上次拉取时间（按设置间隔节流）
    private var haRefreshing = false
    private var lastHARefresh: Date?
    private var lastFormlabsRefresh: [UUID: Date] = [:]
    private var formlabsRefreshing: Set<UUID> = []
    /// 自动聚焦后的摄像头帧与每台摄像头的动态取景状态；原始 HA 图片缓存保持不变，
    /// 关闭功能或切换到任务封面时可以立即恢复原图。
    private var bambuAutoZoomImages: [String: Data] = [:]
    private var bambuCameraZoomRuntime: [String: BambuCameraZoomRuntime] = [:]
    /// 两个独立画板定时推送的上次推送时间（初始化为启动时刻，避免启动即推送）
    private var lastOracleAutoPush: Date?
    private var lastOracleBoardRotation: Date?
    private var lastExcerptAutoPush: Date?
    private var lastExcerptBoardRotation: Date?
    /// 两个独立画板已推送内容指纹（用于内容变化立即推送的对比基线）
    private var lastOraclePushedHash: Data?
    private var lastExcerptPushedHash: Data?
    /// Rand/0 每次首次连接或断线重连后都要主动发送一帧，设备才会完整进入
    /// 显示模式并开始稳定回传按键；不能再依赖用户手动点一次“推送”。
    private var rand0SessionNeedsPrime = true
    /// 两个独立画板内容变化检查节流时间
    private var lastOracleContentCheck: Date?
    private var lastExcerptContentCheck: Date?
    /// 自动保存画板时会改写画板数组；防止该改写再次触发自动保存形成递归。
    private var canvasBoardAutosaveInFlight = false
    private var cropWindow: NSWindow?

    /// 统一数据调取器：一次并行拉取 Codex 用量与千问办公额度，缓存后分发给各功能
    private lazy var usageAggregator: UsageDataAggregator = UsageDataAggregator(
        fetchCodex: { [weak self] path in
            guard let self else { throw CodexError.notFound }
            switch self.settings.codexUsageSource {
            case .codexCLI:
                return try await self.codex.fetch(executable: path ?? self.settings.codexCliPath)
            case .ccSwitch:
                return try await self.ccSwitchQuota.fetch()
            }
        },
        fetchQuota: { [weak self] in
            guard let self else { throw QuotaError.unreachable }
            return try await self.quotaClient.fetch()
        })

    /// 活动设置（普通存储属性而非 @Published：视图直接观察 AppSettings 自身
    /// 的 objectWillChange，避免 @Published 包装器嵌套访问触发元数据递归崩溃）
    public var settings: AppSettings
    @Published public var usage: UsageSnapshot = .empty
    @Published public var qwenQuota: QwenWorkQuota = .unavailable
    /// Home Assistant 快照（实体列表 + 选中实体状态 + 错误信息）
    @Published public var haSnapshot: HASnapshot = .empty
    @Published public var formlabsSnapshots: [UUID: FormlabsSnapshot] = [:]
    @Published public var formlabsDiscoveredDevices: [UUID: [FormlabsDeviceInfo]] = [:]
    @Published public var formlabsConnectionStatus: [UUID: String] = [:]
    @Published public var aiMacScreenPreviews: [UUID: NSImage] = [:]
    @Published public var aiMacScreenStatuses: [UUID: String] = [:]
    @Published public var aiMacScreenLastPushText: [UUID: String] = [:]
    @Published public var aiMacScreenLosslessIDs: Set<UUID> = []
    @Published public var aiMacScreenBusyIDs: Set<UUID> = []
    @Published public var aiMacDiscoveredDevices: [AIMacDiscoveredDevice] = []
    @Published public var aiMacNetworkScanBusy = false
    @Published public var aiMacNetworkScanStatus = ""
    @Published public var homeAssistantDiscoveredServices: [HomeAssistantDiscoveredService] = []
    @Published public var homeAssistantDiscoveryBusy = false
    @Published public var homeAssistantDiscoveryStatus = ""
    @Published public var rand0DiscoveredDevices: [Rand0DiscoveredDevice] = []
    @Published public var rand0DiscoveryBusy = false
    @Published public var rand0DiscoveryStatus = ""
    @Published public var bambuAutoDiscoveryBusy = false
    @Published public var bambuAutoDiscoveryStatus = ""
    @Published public var aiMacFlashPorts: [ESPSerialPort] = []
    @Published public var selectedAIMacFlashPort = ""
    @Published public var aiMacFlashProgress = 0.0
    @Published public var aiMacFlashStatus = "连接小屏幕 USB 数据线后刷新串口列表"
    @Published public var aiMacFlashLog = ""
    @Published public var aiMacFlashBusy = false
    /// 设备管理页自动发现每类只主动运行一次；用户仍可点“重新扫描”。
    private var didAutoScanHomeAssistant = false
    private var didAutoScanRand0 = false
    /// Bambu 实体选择候选缓存；依靠 haSnapshot 的发布通知驱动界面读取，无需单独发布。
    var bambuEntityCatalog = BambuEntityCatalog()
    /// HA 异常监控告警：异常标题（如打印机名）与详情（错误码等）；非空即处于告警状态
    @Published public var haAlertTitle = ""
    @Published public var haAlertMessage = ""
    /// 告警触发时间：用于硬性超时（超过 haAlertMaxSeconds 自动清除，防止陈旧故障码永久占屏）
    private var haAlertSetAt: Date?
    /// 告警冷却截止时间：同一错误码超时清除后，在该时间点前不再重复弹告警（避免每分钟反复占屏）
    private var haAlertCooldownUntil: Date?
    /// 最近一次已提醒过的错误码（用于区分「同一错误冷却中」与「新故障」）
    private var haAlertedCode: String?
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
    @Published public var lingxi68KnobPagingStatus = "未启用"
    @Published private var inputMonitoringAuthorized = false

    /// 外观变化时由窗口应用（跟随系统 / 浅色 / 深色）
    public var onAppearanceChanged: (() -> Void)?

    public init() {
        let loaded = store.load()
        settings = loaded
        pomodoro = PomodoroService(state: store.loadPomodoro())
        // HA 旧配置迁移：设置页时代的全局 ha 配置（实体/监控）→ 第一台 Home Assistant 设备，
        // 避免用户重配。连接配置（地址/令牌/刷新间隔）不写进设备快照：它只有一份全局来源
        if !loaded.haServerURL.isEmpty, loaded.devices.allSatisfy({ $0.type != .homeAssistant }) {
            let count = loaded.devices.filter { $0.type == .homeAssistant }.count
            var haDevice = ManagedDevice(type: .homeAssistant,
                                         name: ManagedDevice.defaultName(for: .homeAssistant, index: count),
                                         settings: DeviceSettings.capture(from: loaded, type: .homeAssistant))
            haDevice.settings.haServerURL = loaded.haServerURL
            haDevice.settings.haToken = loaded.haToken
            loaded.devices.append(haDevice)
            loaded.activeHomeAssistantDeviceID = haDevice.id
        }
        // 设备管理初始化：首次使用不自动创建设备（空列表），由界面引导用户在设备管理中添加；
        // 直接用本地加载的对象（避免经 AppModel 的 @Published 包装器访问，
        // 防止 init 阶段触发元数据重入崩溃）
        // HA 多实体迁移：旧版单实体 haEntityID → 多实体列表首项（全局 + 各 HA 设备快照）
        if loaded.haEntities.isEmpty, !loaded.haEntityID.isEmpty {
            loaded.haEntities = [loaded.haEntityID]
        }
        for index in loaded.devices.indices where loaded.devices[index].type == .homeAssistant {
            let s = loaded.devices[index].settings
            if (s.haEntities ?? []).isEmpty, let single = s.haEntityID, !single.isEmpty {
                loaded.devices[index].settings.haEntities = [single]
            }
            // Bambu 多打印机迁移：旧版单台字段 → 打印机列表首台
            if (s.bambuPrinters ?? []).isEmpty,
               let old = s.bambuStatusEntityID, !old.isEmpty {
                loaded.devices[index].settings.bambuPrinters = [BambuLabCardSettings.from(s)]
            }
        }
        // 时间/日期格式统一（幂等）：各界面独立格式收拢为全局一对
        if let note = loaded.migrateTimeDateFormat() {
            NSLog("[LinxDisplay] \(note)")
        }
        // Bambu Lab 打印机设备迁移：旧架构中打印机配置内嵌在 HA 设备（bambuPrinters 列表），
        // 新架构每台打印机是独立 DeviceType.bambuLab 设备（迁移逻辑在 Core，幂等可测）
        loaded.migrateBambuPrintersToDevices()
        // 旧档案键盘补齐：卡片列表/卡片内容字段缺失的键盘按当前镜像各记一份，
        // 否则切到这台键盘时会把上一台键盘的卡片列表与内容写进它的快照（多设备互相干扰）
        loaded.migrateKeyboardCardContentSeeds()
        // 旧档案没有画板独立 HA 实体字段：显式补为空列表，避免切换同类设备时沿用
        // 上一台设备的镜像；空列表也符合“加入 HA 模块后由用户单独选择”的新行为。
        for index in loaded.devices.indices {
            switch loaded.devices[index].type {
            case .keyboard:
                if loaded.devices[index].settings.canvasHAEntityIDs == nil {
                    loaded.devices[index].settings.canvasHAEntityIDs = []
                }
            case .oracle:
                if loaded.devices[index].settings.oracleCanvasHAEntityIDs == nil {
                    loaded.devices[index].settings.oracleCanvasHAEntityIDs = []
                }
            case .excerpt:
                if loaded.devices[index].settings.excerptCanvasHAEntityIDs == nil {
                    loaded.devices[index].settings.excerptCanvasHAEntityIDs = []
                }
            default:
                break
            }
        }
        // 设备↔卡片绑定：为已存在的打印机设备补齐键盘卡片管理的对应卡片位
        reconcileBambuCards()
        reconcileFormlabsCards()
        // Formlabs 最近任务独立持久化：启动后先恢复已完成任务及封面，随后云端
        // 刷新只在出现下一项任务时替换。已经删除的设备不会重新带回缓存。
        let formLabsDeviceIDs = Set(loaded.devices.filter { $0.type == .formlabs }.map(\.id))
        formlabsSnapshots = store.loadFormlabsTaskCache().filter {
            formLabsDeviceIDs.contains($0.key)
        }
        for type in DeviceType.allCases {
            let list = loaded.devices.filter { $0.type == type }
            let activeID: UUID?
            switch type {
            case .keyboard: activeID = loaded.activeKeyboardDeviceID
            case .oracle: activeID = loaded.activeOracleDeviceID
            case .excerpt: activeID = loaded.activeExcerptDeviceID
            case .homeAssistant: activeID = loaded.activeHomeAssistantDeviceID
            case .bambuLab: activeID = loaded.activeBambuLabDeviceID
            case .formlabs: activeID = loaded.activeFormlabsDeviceID
            case .aiMacScreen: activeID = loaded.activeAIMacScreenDeviceID
            }
            if let device = list.first(where: { $0.id == activeID }) ?? list.first {
                device.settings.apply(to: loaded, type: type)
            }
        }
        setupLingxi68KnobController()
        refreshInputMonitoringStatus()
        wireSettingsHandlers()
        applyLingxi68KnobPaging()
        applyStartupState()
        lastCustomImageRevision = currentCustomImageRevision()
        refreshAIMacFlashPorts()
        startTimer()
        renderPreview()
        Task { await activateMode() }
        // 启动即建立先知显示模式会话（自动重连由会话内部负责），按键随时可用
        ensureRand0Session()
        // 启动后自动检查 GitHub 更新（6 小时节流，静默失败）
        Task { await checkForUpdate() }
    }

    /// 启动/恢复初始设定后把系统相关状态与设置对齐（登录项、外观、自动推送计时起点）。
    /// 不包含 startTimer：定时器在 init 只启动一次，恢复初始设定复用本函数时不会重复建定时器。
    private func applyStartupState() {
        updateSoftwareDarkState()
        settings.startWithSystem = startup.isEnabled()
        // 自动推送开启时启动即推一次（推送内部会等待会话连接就绪）；未开启则从启动时刻起算间隔
        lastOracleAutoPush = settings.oracleAutoPushEnabled ? nil : Date()
        // 画板轮换不像自动推送那样开启即执行：从启动/开启时刻完整等待一个轮换周期。
        lastOracleBoardRotation = Date()
        lastExcerptAutoPush = settings.excerptAutoPushEnabled ? nil : Date()
        lastExcerptBoardRotation = Date()
    }

    /// 恢复初始设定：清除全部设置、已添加的设备、自定义内容与自定义图片缓存，
    /// 回到首次启动状态。调用前界面已完成多次确认。
    public func resetToFactoryDefaults() {
        // 1. 磁盘数据（设置/番茄钟/自定义图片/图片缓存）移入废纸篓（可恢复，不永久删除）
        store.resetAllData()
        // 2. 换入全新默认设置并重新接线 onChange
        let fresh = AppSettings()
        fresh.clamped()
        settings = fresh
        wireSettingsHandlers()
        // 3. 重置内存运行态
        pomodoro.reset()
        usage = .empty
        qwenQuota = .unavailable
        formlabsSnapshots = [:]
        formlabsDiscoveredDevices = [:]
        formlabsConnectionStatus = [:]
        lastFormlabsRefresh = [:]
        sspaiArticles = []
        sspaiRandomSelection = [:]
        quoteOverrideIndex = nil
        praiseText = nil
        praiseUntil = nil
        printSuccessName = nil
        printSuccessTask = nil
        printSuccessImage = nil
        printSuccessUntil = nil
        lastPrinterStatuses = [:]
        haAlertCooldownUntil = nil
        haAlertedCode = nil
        lastQuotaRefresh = nil
        lastPushAttempt = nil
        lastPomodoroPushAlignedSeconds = nil
        lastUploadedHash = nil
        lastOraclePushedHash = nil
        lastExcerptPushedHash = nil
        rand0SessionNeedsPrime = true
        lastNowPlayingFetch = nil
        lastTickDate = nil
        lastImageRotation = nil
        lastOracleBoardRotation = nil
        lastExcerptBoardRotation = nil
        lastClockMinute = nil
        lastCardRotation = nil
        cardRotationIndex = 0
        lastQuotePushText = nil
        lastSspaiFetch = nil
        lastSspaiHash = nil
        rand0SessionIP = ""
        rand0SessionEndpoint = .bw
        // 4. 对齐系统状态、断开旧设备会话、持久化全新默认设置并刷新界面
        applyStartupState()
        ensureRand0Session()
        persistSettings()
        objectWillChange.send()
        renderPreview()
        refreshOracleCanvasPreview()
        refreshExcerptCanvasPreview()
        status = "已恢复初始设定：设备、自定义内容与图片缓存均已清除"
    }

    /// 给当前 settings 对象接线 onChange（init 与恢复初始设定共用）
    private func wireSettingsHandlers() {
        settings.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.updateSoftwareDarkState()
                // 拖拽侧边栏宽度中：跳过持久化/重渲染/外观应用，避免逐帧闪烁，松手时一次性提交
                guard self?.sidebarResizing != true else { return }
                // 设备切换/快照同步进行中：跳过中途「镜像→快照」回写，
                // 否则新设备快照会在套用前被旧设备的镜像值整体覆盖（设备间串扰）
                guard self?.settings.deviceSyncInFlight != true else { return }
                guard self?.canvasBoardAutosaveInFlight != true else { return }
                // 已创建画板后，当前界面的每次有效修改都自动写回当前画板。
                self?.autosaveCurrentCanvasBoards()
                // 同步活动设备设置（内部防重入），随后持久化
                self?.syncActiveDeviceSettings()
                self?.persistSettings()
                self?.applyGlobalShortcuts()
                self?.applyLingxi68KnobPaging()
                self?.renderPreview()
                self?.refreshOracleCanvasPreview()
                self?.refreshExcerptCanvasPreview()
                self?.enabledDevices(for: .aiMacScreen).forEach {
                    self?.refreshAIMacScreenPreview(deviceID: $0.id)
                }
                self?.onAppearanceChanged?()
                self?.scheduleCardSettingsPush()
                // 先知 IP/显示模式变化时重连按键会话（目标未变则幂等返回）
                self?.ensureRand0Session()
            }
        }
    }

    /// 设置修改后的轻量防抖推送。最终仍按渲染结果 hash 去重，因此与当前卡片
    /// 无关的设置不会产生网络上传，也不会用“画面未变化”覆盖界面状态。
    private func scheduleCardSettingsPush() {
        cardSettingsPushTask?.cancel()
        cardSettingsPushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.pushWhenAvailable(force: false, silentIfUnchanged: true)
            for device in self.enabledDevices(for: .aiMacScreen) {
                let config = self.aiMacScreenSettings(for: device.id)
                if config.autoPush {
                    await self.pushAIMacScreen(deviceID: device.id, force: false)
                }
            }
        }
    }

    /// 把活动设置同步回各类型当前激活设备的快照（切换设备时据此记住之前设备的设置）
    public func syncActiveDeviceSettings() {
        settings.deviceSyncInFlight = true
        defer { settings.deviceSyncInFlight = false }
        settings.captureActiveDeviceSnapshots()
    }

    /// 把当前画布镜像写回两类设备各自选中的画板。保留画板 ID/名称，只更新配置内容。
    private func autosaveCurrentCanvasBoards() {
        canvasBoardAutosaveInFlight = true
        defer { canvasBoardAutosaveInFlight = false }

        let oracleIndex = settings.oracleCanvasBoardIndex
        if settings.oracleCanvasBoards.indices.contains(oracleIndex) {
            let current = settings.oracleCanvasBoards[oracleIndex]
            let updated = current.updatingConfiguration(from: settings)
            if updated != current { settings.oracleCanvasBoards[oracleIndex] = updated }
        }

        let excerptIndex = settings.excerptCanvasBoardIndex
        if settings.excerptCanvasBoards.indices.contains(excerptIndex) {
            let current = settings.excerptCanvasBoards[excerptIndex]
            let updated = current.updatingConfiguration(from: settings)
            if updated != current { settings.excerptCanvasBoards[excerptIndex] = updated }
        }
    }

    /// 批量切换/删除/排序画板后，只更新指定活动设备的快照，避免影响其他设备类型。
    private func captureActiveDeviceSnapshot(of type: DeviceType) {
        guard let activeID = activeDeviceID(for: type),
              let index = settings.devices.firstIndex(where: { $0.id == activeID && $0.type == type }) else { return }
        settings.devices[index].settings = DeviceSettings.capture(from: settings, type: type)
    }

    /// 某类型设备列表（含被禁用的；设备管理页需要显示以便重新启用）
    public func devices(for type: DeviceType) -> [ManagedDevice] {
        settings.devices(for: type)
    }

    /// 某类型已启用设备列表（侧栏导航/目标选择等只展示启用的设备）
    public func enabledDevices(for type: DeviceType) -> [ManagedDevice] {
        settings.enabledDevices(for: type)
    }

    /// 某类型当前活动设备（按活动 ID，回退该类第一台已启用设备；全部禁用时为 nil）
    public func activeDevice(for type: DeviceType) -> ManagedDevice? {
        settings.activeDevice(for: type)
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

    /// 当前操作的键盘设备（卡片管理等页面据此切换编辑对象；每台键盘配置互相独立）
    public var activeKeyboardBinding: Binding<UUID> {
        Binding(get: {
            self.activeDevice(for: .keyboard)?.id ?? UUID()
        }, set: { id in
            self.switchDevice(type: .keyboard, to: id)
        })
    }

    /// 当前画板管理页正在编辑的口袋先知设备。
    public var activeOracleBinding: Binding<UUID> {
        Binding(get: {
            self.activeDevice(for: .oracle)?.id ?? UUID()
        }, set: { id in
            self.switchDevice(type: .oracle, to: id)
        })
    }

    /// 当前摘录画板页正在编辑的摘录设备。
    public var activeExcerptBinding: Binding<UUID> {
        Binding(get: {
            self.activeDevice(for: .excerpt)?.id ?? UUID()
        }, set: { id in
            self.switchDevice(type: .excerpt, to: id)
        })
    }

    /// 当前 AI Mac 画板页正在编辑的彩色小屏设备。
    public var activeAIMacScreenBinding: Binding<UUID> {
        Binding(get: {
            self.activeDevice(for: .aiMacScreen)?.id ?? UUID()
        }, set: { id in
            self.switchDevice(type: .aiMacScreen, to: id)
        })
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
        settings.activeDeviceID(for: type)
    }

    private func setActiveDeviceID(_ type: DeviceType, _ id: UUID?) {
        settings.setActiveDeviceID(type, id)
    }

    /// 切换某类型的活动设备：存回原设备快照 → 套用新设备快照（Core 内原子完成），
    /// 这里只做切换后的界面/会话副作用
    public func switchDevice(type: DeviceType, to deviceID: UUID?) {
        guard let newDevice = settings.switchActiveDevice(of: type, to: deviceID) else { return }
        // 切换键盘设备：轮换池与当前卡片都换了，重置轮换时钟，从这台键盘自己的卡片重新开始
        if type == .keyboard {
            lastCardRotation = nil
            cardRotationIndex = 0
        }
        // 切换口袋先知设备后，显示模式会话要重连到新设备 IP（按键信号才回传到这台设备）
        if type == .oracle {
            lastOracleAutoPush = settings.oracleAutoPushEnabled ? nil : Date()
            lastOracleBoardRotation = Date()
            lastOraclePushedHash = nil
            ensureRand0Session()
        }
        if type == .excerpt {
            lastExcerptAutoPush = settings.excerptAutoPushEnabled ? nil : Date()
            lastExcerptBoardRotation = Date()
            lastExcerptPushedHash = nil
        }
        // 点开某台 Bambu 打印机的设置页时，预览/键盘立即切到这台打印机的卡片位
        // （按已启用打印机顺序对应 Bambu Lab 打印机 1/2/3 卡，避免在编辑打印机 2 时预览仍显示打印机 1）
        if type == .bambuLab {
            syncBambuPreviewSlot(for: newDevice.id)
        }
        if type == .formlabs {
            syncFormlabsPreviewSlot(for: newDevice.id)
        }
        if type == .aiMacScreen {
            aiMacScreenLastBoardRotation[newDevice.id] = Date()
            aiMacScreenLastCardRotation[newDevice.id] = Date()
            refreshAIMacScreenPreview(deviceID: newDevice.id)
        }
        persistSettings()
        renderPreview()
        refreshOracleCanvasPreview()
        refreshExcerptCanvasPreview()
    }

    /// 把预览/键盘切到指定打印机的卡片位（按已启用打印机顺序对应 bambuLab/bambuLab2/bambuLab3/4/5）
    public func syncBambuPreviewSlot(for deviceID: UUID) {
        guard let index = enabledDevices(for: .bambuLab).firstIndex(where: { $0.id == deviceID }) else { return }
        syncBambuPreviewSlot(index: index)
    }

    /// 按已启用打印机序号切卡片位（0→bambuLab，1→bambuLab2，…，4→bambuLab5；该位无打印机则不动）
    public func syncBambuPreviewSlot(index: Int) {
        guard enabledDevices(for: .bambuLab).indices.contains(index),
              let slot = DisplayMode(rawValue: DisplayMode.bambuLab.rawValue + index) else { return }
        // 统一走模式激活入口：即使当前恰好已是这个卡片位，切换打印机设备时也要
        // 即时查询一次 HA 状态，不能被「模式未变化」的短路条件跳过。
        setMode(slot, reactivateIfUnchanged: true)
    }

    public func syncFormlabsPreviewSlot(for deviceID: UUID) {
        guard let index = enabledDevices(for: .formlabs).firstIndex(where: { $0.id == deviceID }) else { return }
        syncFormlabsPreviewSlot(index: index)
    }

    public func syncFormlabsPreviewSlot(index: Int) {
        guard enabledDevices(for: .formlabs).indices.contains(index),
              let slot = DisplayMode(rawValue: DisplayMode.formlabs.rawValue + index) else { return }
        setMode(slot, reactivateIfUnchanged: true)
    }

    /// 新增一台该类型设备（以当前活动设备设置为模板，但连接/凭证字段一律置空：
    /// 新设备的 IP / API Key / 设备序列号等需要单独填写，与已有设备完全隔离、互不串扰）
    @discardableResult
    public func addDevice(type: DeviceType) -> UUID {
        // 屏蔽中间 onChange 的同步回写：添加过程涉及设备列表、全局镜像、活动设备多处变更，
        // 若每次变更都触发 syncActiveDeviceSettings，会把全局旧值写回新设备快照、
        // 或把置空后的全局值污染旧设备快照（卡片列表/连接信息串扰）
        settings.deviceSyncInFlight = true
        defer { settings.deviceSyncInFlight = false }
        // 数量上限（Home Assistant 1 个实例 / Bambu Lab 5 台）：不再新增，直接定位到已有设备
        if !settings.canAddDevice(of: type), let existing = devices(for: type).first {
            if type == .homeAssistant {
                setActiveDeviceID(type, existing.id)
                persistSettings()
            }
            return existing.id
        }
        // 无活动设备时（如删光后重加）继承全局设置快照：非连接字段照常继承，连接字段随后统一置空
        let current = activeDevice(for: type)?.settings
            ?? DeviceSettings.capture(from: settings, type: type)
        let count = devices(for: type).count
        let device = ManagedDevice(type: type,
                                   name: ManagedDevice.defaultName(for: type, index: count),
                                   settings: current)
        settings.devices.append(device)
        let index = settings.devices.count - 1
        // 新键盘设备默认无卡片（空可见列表，侧栏显示去卡片管理的提示）；镜像先行防 sync 覆盖
        if type == .keyboard {
            settings.keyboardCardPanels = []
            settings.devices[index].settings.keyboardCardPanels = []
            // 新键盘从「灵犀画板」开始，不沿用别的键盘当前显示的卡片与轮换池
            settings.displayMode = .canvas
            settings.devices[index].settings.displayMode = .canvas
            settings.cardRotationModes = []
            settings.devices[index].settings.cardRotationModes = []
            // 新键盘的 Home Assistant 卡片也从空开始（不继承别的键盘的实体选择）
            settings.haCardEntityIDs = []
            settings.devices[index].settings.haCardEntityIDs = []
            settings.canvasHAEntityIDs = []
            settings.devices[index].settings.canvasHAEntityIDs = []
        }
        // 连接/凭证字段置空：设备快照与全局镜像同步清空（镜像先行，与新设备实际状态一致）
        switch type {
        case .keyboard:
            settings.endpoint = ""
            settings.devices[index].settings.endpoint = ""
        case .oracle:
            settings.rand0IP = ""
            settings.devices[index].settings.rand0IP = ""
            settings.oracleCanvasHAEntityIDs = []
            settings.devices[index].settings.oracleCanvasHAEntityIDs = []
            settings.oracleCanvasBoards = []
            settings.oracleCanvasBoardIndex = 0
            settings.devices[index].settings.oracleCanvasBoards = []
            settings.devices[index].settings.oracleCanvasBoardIndex = 0
        case .excerpt:
            settings.dotApiKey = ""
            settings.dotDeviceId = ""
            settings.devices[index].settings.dotApiKey = ""
            settings.devices[index].settings.dotDeviceId = ""
            settings.excerptCanvasHAEntityIDs = []
            settings.devices[index].settings.excerptCanvasHAEntityIDs = []
            settings.excerptQuoteCategories = ExcerptQuoteCategory.allCases.map(\.rawValue)
            settings.showExcerptSource = false
            settings.devices[index].settings.excerptCanvasQuoteCategories = settings.excerptQuoteCategories
            settings.devices[index].settings.excerptCanvasShowQuoteSource = false
            // 新设备从空画板列表开始，不能继承上一台摘录设备保存的画板。
            settings.excerptCanvasBoards = []
            settings.excerptCanvasBoardIndex = 0
            settings.devices[index].settings.excerptCanvasBoards = []
            settings.devices[index].settings.excerptCanvasBoardIndex = 0
        case .homeAssistant:
            // 基线：每台 Home Assistant 设备各自填写服务器地址与令牌，新设备从空连接配置开始
            settings.haServerURL = ""
            settings.haToken = ""
            settings.haEntities = []
            settings.haEntityID = ""
            settings.haMonitorEnabled = false
            settings.haMonitorEntityID = ""
            settings.haMonitorExpectedState = ""
            settings.haMonitorErrorEntityID = ""
            settings.devices[index].settings.haMonitorEnabled = false
            settings.devices[index].settings.haMonitorEntityID = ""
            settings.devices[index].settings.haMonitorExpectedState = ""
            settings.devices[index].settings.haMonitorErrorEntityID = ""
            settings.devices[index].settings.haServerURL = nil
            settings.devices[index].settings.haToken = nil
            settings.devices[index].settings.haRefreshMinutes = nil
            settings.devices[index].settings.haEntities = nil
            settings.devices[index].settings.haEntityID = nil
            settings.devices[index].settings.haEntityAliases = nil
            settings.devices[index].settings.haCardEntityIDs = nil
        case .bambuLab:
            // 新打印机从空配置开始：实体映射/名称全部置空，绝不继承其他打印机的映射
            settings.bambuPrinterName = "打印机"
            settings.bambuEnableAlert = true
            settings.bambuStatusEntityID = ""
            settings.bambuProgressEntityID = ""
            settings.bambuTaskEntityID = ""
            settings.bambuNozzleTempEntityID = ""
            settings.bambuBedTempEntityID = ""
            settings.bambuRemainingEntityID = ""
            settings.bambuEndTimeEntityID = ""
            settings.bambuTimeDisplayMode = .remaining
            settings.bambuErrorEntityID = ""
            settings.bambuImageEntityID = ""
            settings.bambuTaskImageEntityID = ""
            settings.bambuImageSource = .camera
            settings.bambuAutoCameraZoom = false
            settings.bambuShowImage = true
            settings.devices[index].settings.bambuPrinterName = "打印机"
            settings.devices[index].settings.bambuEnableAlert = true
            settings.devices[index].settings.bambuStatusEntityID = ""
            settings.devices[index].settings.bambuProgressEntityID = ""
            settings.devices[index].settings.bambuTaskEntityID = ""
            settings.devices[index].settings.bambuNozzleTempEntityID = ""
            settings.devices[index].settings.bambuBedTempEntityID = ""
            settings.devices[index].settings.bambuRemainingEntityID = ""
            settings.devices[index].settings.bambuEndTimeEntityID = ""
            settings.devices[index].settings.bambuTimeDisplayMode = .remaining
            settings.devices[index].settings.bambuErrorEntityID = ""
            settings.devices[index].settings.bambuImageEntityID = ""
            settings.devices[index].settings.bambuTaskImageEntityID = ""
            settings.devices[index].settings.bambuImageSource = .camera
            settings.devices[index].settings.bambuAutoCameraZoom = false
            settings.devices[index].settings.bambuShowImage = true
        case .formlabs:
            let fresh = FormlabsConnectionSettings()
            settings.devices[index].settings.formlabsConnection = fresh
        case .aiMacScreen:
            settings.devices[index].settings.aiMacScreen = AIMacScreenDeviceSettings()
        }
        setActiveDeviceID(type, device.id)
        if type == .oracle {
            lastOracleAutoPush = settings.oracleAutoPushEnabled ? nil : Date()
            lastOracleBoardRotation = Date()
            lastOraclePushedHash = nil
        }
        if type == .excerpt {
            lastExcerptAutoPush = settings.excerptAutoPushEnabled ? nil : Date()
            lastExcerptBoardRotation = Date()
            lastExcerptPushedHash = nil
        }
        if type == .bambuLab {
            addBambuPrinterCard()
        }
        if type == .formlabs {
            addFormlabsPrinterCard()
        }
        if type == .aiMacScreen {
            aiMacScreenStatuses[device.id] = "等待连接小屏幕"
            refreshAIMacScreenPreview(deviceID: device.id)
        }
        if type == .keyboard {
            reconcileBambuCards()
            reconcileFormlabsCards()
        }
        persistSettings()
        renderPreview()
        refreshOracleCanvasPreview()
        refreshExcerptCanvasPreview()
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
            if type == .oracle {
                lastOracleAutoPush = settings.oracleAutoPushEnabled ? nil : Date()
                lastOracleBoardRotation = Date()
                lastOraclePushedHash = nil
            }
            if type == .excerpt {
                lastExcerptAutoPush = settings.excerptAutoPushEnabled ? nil : Date()
                lastExcerptBoardRotation = Date()
                lastExcerptPushedHash = nil
            }
        }
        if type == .bambuLab {
            removeBambuPrinterCard()
        }
        if type == .formlabs {
            formlabsSnapshots[id] = nil
            formlabsDiscoveredDevices[id] = nil
            formlabsConnectionStatus[id] = nil
            lastFormlabsRefresh[id] = nil
            store.saveFormlabsTaskCache(formlabsSnapshots)
            removeFormlabsPrinterCard()
        }
        if type == .aiMacScreen {
            aiMacScreenCapabilities[id] = nil
            aiMacScreenLastHashes[id] = nil
            aiMacScreenLastPushAt[id] = nil
            aiMacScreenLastBoardRotation[id] = nil
            aiMacScreenLastCardRotation[id] = nil
            aiMacSspaiRandomSelection = aiMacSspaiRandomSelection.filter {
                !$0.key.hasPrefix(id.uuidString + "|")
            }
            aiMacScreenPreviews[id] = nil
            aiMacScreenStatuses[id] = nil
            aiMacScreenLastPushText[id] = nil
            aiMacScreenLosslessIDs.remove(id)
            aiMacScreenBusyIDs.remove(id)
        }
        persistSettings()
        renderPreview()
        refreshOracleCanvasPreview()
        refreshExcerptCanvasPreview()
    }

    /// 新增打印机设备后：只在当前操作的键盘设备卡片管理中加入对应卡片位
    /// （不写其他键盘：各键盘卡片列表相互独立，需要时在它那台的「卡片管理」里自行添加）
    private func addBambuPrinterCard() {
        let count = devices(for: .bambuLab).count
        guard count >= 1, let slot = Panel.bambuPanel(forSlotIndex: count - 1) else { return }
        appendPrinterCardToActiveKeyboard(slot)
        if let mode = slot.displayMode, !settings.cardRotationModes.contains(mode.rawValue) {
            settings.cardRotationModes.append(mode.rawValue)
        }
    }

    /// 删除打印机设备后：从每台键盘移除卡片位索引 ≥ 现有打印机台数的卡片
    /// （这些卡片位已无对应设备，属于清理失效项，不是给别的键盘新增内容）
    private func removeBambuPrinterCard() {
        let count = devices(for: .bambuLab).count
        var removed: [Panel] = []
        for kb in devices(for: .keyboard) {
            guard let idx = settings.devices.firstIndex(where: { $0.id == kb.id }) else { continue }
            var list = keyboardCardList(for: kb.id)
            let gone = list.filter { ($0.bambuSlotIndex ?? -1) >= count }
            guard !gone.isEmpty else { continue }
            removed.append(contentsOf: gone)
            list.removeAll { ($0.bambuSlotIndex ?? -1) >= count }
            writeKeyboardCardPanels(list, deviceIndex: idx)
        }
        for p in removed {
            if let mode = p.displayMode {
                settings.cardRotationModes.removeAll { $0 == mode.rawValue }
            }
        }
    }

    /// 启动补齐：仅在当前操作的键盘上补齐已存在打印机对应的卡片位（设备↔卡片绑定；
    /// 其他键盘保持自己的卡片列表不变）
    private func reconcileBambuCards() {
        for slot in 0..<enabledDevices(for: .bambuLab).count {
            if let panel = Panel.bambuPanel(forSlotIndex: slot) {
                appendPrinterCardToActiveKeyboard(panel)
            }
        }
    }

    private func addFormlabsPrinterCard() {
        let count = devices(for: .formlabs).count
        guard count >= 1, let panel = Panel.formlabsPanel(forSlotIndex: count - 1) else { return }
        appendPrinterCardToActiveKeyboard(panel)
        if let mode = panel.displayMode, !settings.cardRotationModes.contains(mode.rawValue) {
            settings.cardRotationModes.append(mode.rawValue)
        }
    }

    private func removeFormlabsPrinterCard() {
        let count = devices(for: .formlabs).count
        var removed: [Panel] = []
        for kb in devices(for: .keyboard) {
            guard let idx = settings.devices.firstIndex(where: { $0.id == kb.id }) else { continue }
            var list = keyboardCardList(for: kb.id)
            let gone = list.filter { ($0.formlabsSlotIndex ?? -1) >= count }
            guard !gone.isEmpty else { continue }
            removed.append(contentsOf: gone)
            list.removeAll { ($0.formlabsSlotIndex ?? -1) >= count }
            writeKeyboardCardPanels(list, deviceIndex: idx)
        }
        for panel in removed {
            if let mode = panel.displayMode {
                settings.cardRotationModes.removeAll { $0 == mode.rawValue }
            }
        }
    }

    private func reconcileFormlabsCards() {
        for slot in 0..<enabledDevices(for: .formlabs).count {
            if let panel = Panel.formlabsPanel(forSlotIndex: slot) {
                appendPrinterCardToActiveKeyboard(panel)
            }
        }
    }

    /// 把一张打印机卡片追加到当前操作键盘的可见列表（镜像先行，防 sync 覆盖）
    private func appendPrinterCardToActiveKeyboard(_ panel: Panel) {
        guard let kb = activeDevice(for: .keyboard),
              let idx = settings.devices.firstIndex(where: { $0.id == kb.id }) else { return }
        var list = keyboardCardList(for: kb.id)
        guard !list.contains(panel) else { return }
        list.append(panel)
        writeKeyboardCardPanels(list, deviceIndex: idx)
    }

    /// 写某台键盘的卡片列表（镜像先行：仅当它是活动键盘时同步全局，防止 syncActiveDeviceSettings 覆盖）
    private func writeKeyboardCardPanels(_ panels: [Panel], deviceIndex: Int) {
        let raw = panels.map(\.rawValue)
        if settings.devices[deviceIndex].id == activeDeviceID(for: .keyboard) {
            settings.keyboardCardPanels = raw
        }
        settings.devices[deviceIndex].settings.keyboardCardPanels = raw
    }

    /// 重命名设备
    public func renameDevice(id: UUID, to name: String) {
        guard let index = settings.devices.firstIndex(where: { $0.id == id }) else { return }
        // TextField 会在每次按键时写入：必须保留编辑中的空字符串及空格，避免用户删掉
        // 默认名准备输入新名称时，旧默认名又被立即塞回输入框。默认名仅由 addDevice 生成。
        settings.devices[index].rename(to: name)
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

    /// Home Assistant 设备服务器地址绑定
    public func deviceHAServerURLBinding(for id: UUID) -> Binding<String> {
        deviceConnectionBinding(for: id,
                                get: { $0.haServerURL },
                                set: { $0.haServerURL = $1 },
                                activeType: .homeAssistant,
                                liveSync: { self.settings.haServerURL = $0 })
    }

    /// Home Assistant 设备长期访问令牌绑定（敏感字段，仅存本机；日志/测试不打印明文）
    public func deviceHATokenBinding(for id: UUID) -> Binding<String> {
        deviceConnectionBinding(for: id,
                                get: { $0.haToken },
                                set: { $0.haToken = $1 },
                                activeType: .homeAssistant,
                                liveSync: { self.settings.haToken = $0 })
    }

    /// Home Assistant 设备刷新间隔绑定（分钟）
    public func deviceHARefreshBinding(for id: UUID) -> Binding<Int> {
        Binding(get: {
            guard let device = self.settings.devices.first(where: { $0.id == id }) else { return 5 }
            return device.settings.haRefreshMinutes ?? 5
        }, set: { newValue in
            guard let index = self.settings.devices.firstIndex(where: { $0.id == id }) else { return }
            self.settings.devices[index].settings.haRefreshMinutes = newValue
            if self.activeDeviceID(for: .homeAssistant) == id {
                self.settings.haRefreshMinutes = newValue
            }
        })
    }

    /// Home Assistant 设备连接测试（读该设备快照的地址与令牌验证；不打印令牌）
    public func testHADevice(_ id: UUID) async -> String {
        guard let device = settings.devices.first(where: { $0.id == id }) else { return "设备不存在" }
        let server = device.settings.haServerURL ?? ""
        let token = device.settings.haToken ?? ""
        if let problem = HomeAssistantClient.validate(serverURL: server, token: token) {
            return problem
        }
        do {
            let entities = try await HomeAssistantClient.fetchStates(serverURL: server, token: token)
            applyHASnapshot(entities: entities, errorText: nil)
            lastHARefresh = Date()
            let result = reconcileBambuPrinters(entities: entities)
            bambuAutoDiscoveryStatus = result
            return "连接成功：读到 \(entities.count) 个实体；\(result)"
        } catch let error as HAError {
            return error.errorDescription ?? "连接失败"
        } catch {
            return "连接失败"
        }
    }

    // MARK: - Home Assistant / Bambu Lab 自动发现

    /// 设备管理页首次进入时自动扫描一次；后续只有用户主动点“重新扫描”才再次运行。
    public func scanHomeAssistantServers(force: Bool = false) async {
        guard !homeAssistantDiscoveryBusy else { return }
        if !force, didAutoScanHomeAssistant { return }
        didAutoScanHomeAssistant = true
        homeAssistantDiscoveryBusy = true
        homeAssistantDiscoveryStatus = "正在查找局域网中的 Home Assistant…"
        defer { homeAssistantDiscoveryBusy = false }
        let services = await HomeAssistantDiscovery.scan(timeout: 3)
        homeAssistantDiscoveredServices = services
        homeAssistantDiscoveryStatus = services.isEmpty
            ? "没有自动发现服务器，可继续使用手动添加"
            : "发现 \(services.count) 个 Home Assistant 服务器"
    }

    public func isHomeAssistantAdded(_ discovered: HomeAssistantDiscoveredService) -> Bool {
        let target = normalizedServerURL(discovered.serverURL)
        return devices(for: .homeAssistant).contains {
            normalizedServerURL($0.settings.haServerURL ?? "") == target
        }
    }

    /// Home Assistant 仅允许一个档案。选择另一台服务器时复用该档案并清空旧令牌，
    /// 防止凭证被意外发给不同主机。
    @discardableResult
    public func addDiscoveredHomeAssistant(_ discovered: HomeAssistantDiscoveredService) -> UUID {
        let id = devices(for: .homeAssistant).first?.id ?? addDevice(type: .homeAssistant)
        let target = normalizedServerURL(discovered.serverURL)
        guard let index = settings.devices.firstIndex(where: { $0.id == id }) else { return id }
        let previous = normalizedServerURL(settings.devices[index].settings.haServerURL ?? "")
        let changedServer = !previous.isEmpty && previous != target
        settings.deviceSyncInFlight = true
        settings.devices[index].settings.haServerURL = discovered.serverURL
        if changedServer { settings.devices[index].settings.haToken = "" }
        settings.devices[index].name = discovered.name
        settings.devices[index].isEnabled = true
        setActiveDeviceID(.homeAssistant, id)
        settings.haServerURL = discovered.serverURL
        if changedServer { settings.haToken = "" }
        settings.deviceSyncInFlight = false
        lastHARefresh = nil
        if changedServer {
            applyHASnapshot(entities: [], errorText: nil)
            bambuAutoDiscoveryStatus = "服务器已更换，请填写长期访问令牌后连接"
        }
        homeAssistantDiscoveryStatus = "已选择 \(discovered.name)，请填写长期访问令牌"
        persistSettings()
        return id
    }

    /// 使用当前 Home Assistant 凭证扫描打印状态实体并创建/补全打印机档案。
    public func discoverAndAddBambuPrinters(homeAssistantDeviceID id: UUID) async {
        guard !bambuAutoDiscoveryBusy else { return }
        guard let device = settings.devices.first(where: { $0.id == id }) else {
            bambuAutoDiscoveryStatus = "请先添加 Home Assistant 服务器"
            return
        }
        let server = device.settings.haServerURL ?? ""
        let token = device.settings.haToken ?? ""
        if let problem = HomeAssistantClient.validate(serverURL: server, token: token) {
            bambuAutoDiscoveryStatus = problem
            return
        }
        bambuAutoDiscoveryBusy = true
        bambuAutoDiscoveryStatus = "正在查找 Bambu Lab 打印机…"
        defer { bambuAutoDiscoveryBusy = false }
        do {
            let entities = try await HomeAssistantClient.fetchStates(serverURL: server, token: token)
            applyHASnapshot(entities: entities, errorText: nil)
            lastHARefresh = Date()
            bambuAutoDiscoveryStatus = reconcileBambuPrinters(entities: entities)
        } catch let error as HAError {
            bambuAutoDiscoveryStatus = error.errorDescription ?? "无法读取 Home Assistant 设备"
        } catch {
            bambuAutoDiscoveryStatus = "无法读取 Home Assistant 设备"
        }
    }

    private func reconcileBambuPrinters(entities: [HAEntity]) -> String {
        let candidates = BambuEntityMatcher.printStatusCandidates(entities, useDefaultFilter: true)
        var seenPrefixes = Set<String>()
        let unique = candidates.filter {
            seenPrefixes.insert(BambuEntityMatcher.prefix(of: $0.entityId)).inserted
        }
        guard !unique.isEmpty else { return "没有发现 Bambu Lab 打印机" }

        var added = 0
        var updated = 0
        var skipped = 0
        var claimedExistingIDs = Set<UUID>()
        for seed in unique {
            let prefix = BambuEntityMatcher.prefix(of: seed.entityId)
            let printers = devices(for: .bambuLab)
            let directlyMatched = printers.first(where: { device in
                guard !claimedExistingIDs.contains(device.id),
                      let statusID = device.settings.bambuStatusEntityID, !statusID.isEmpty else {
                    return false
                }
                return statusID == seed.entityId || BambuEntityMatcher.prefix(of: statusID) == prefix
            })
            // entity_id 被用户重命名后前缀可能完全变化：型号能唯一对应时仍复用旧档案，
            // 不新建重复打印机。型号同时从旧 entity_id 与用户设备名中识别。
            let modelMatched: ManagedDevice? = {
                guard directlyMatched == nil,
                      let candidateModel = BambuModelDetector.model(of: seed) else { return nil }
                let matches = printers.filter { device in
                    guard !claimedExistingIDs.contains(device.id) else { return false }
                    let oldStatus = device.settings.bambuStatusEntityID ?? ""
                    let probe = HAEntity(entityId: oldStatus, friendlyName: device.name,
                                         state: "", unitOfMeasurement: nil)
                    return BambuModelDetector.model(of: probe) == candidateModel
                }
                return matches.count == 1 ? matches[0] : nil
            }()
            let blankMatched = printers.first(where: { device in
                !claimedExistingIDs.contains(device.id)
                    && (device.settings.bambuStatusEntityID ?? "").isEmpty
            })
            if let existing = directlyMatched ?? modelMatched ?? blankMatched {
                claimedExistingIDs.insert(existing.id)
                setDeviceEnabled(id: existing.id, enabled: true)
                if (existing.settings.bambuStatusEntityID ?? "").isEmpty,
                   existing.name.hasPrefix("Bambu Lab 打印机"),
                   let index = settings.devices.firstIndex(where: { $0.id == existing.id }) {
                    let name = discoveredBambuName(from: seed)
                    settings.devices[index].name = name
                    settings.devices[index].settings.bambuPrinterName = name
                    if activeDeviceID(for: .bambuLab) == existing.id {
                        settings.bambuPrinterName = name
                    }
                }
                applyBambuAutoDetect(from: seed, deviceID: existing.id, entities: entities)
                updated += 1
                continue
            }
            guard settings.canAddDevice(of: .bambuLab) else {
                skipped += 1
                continue
            }
            let id = addDevice(type: .bambuLab)
            let name = discoveredBambuName(from: seed)
            if let index = settings.devices.firstIndex(where: { $0.id == id }) {
                settings.devices[index].name = name
                settings.devices[index].settings.bambuPrinterName = name
            }
            settings.bambuPrinterName = name
            applyBambuAutoDetect(from: seed, deviceID: id, entities: entities)
            added += 1
        }
        persistSettings()
        renderPreview()
        var parts = ["发现 \(unique.count) 台打印机", "新增 \(added) 台", "更新 \(updated) 台"]
        if skipped > 0 { parts.append("另有 \(skipped) 台超过上限") }
        return parts.joined(separator: "，")
    }

    private func discoveredBambuName(from entity: HAEntity) -> String {
        if let model = BambuModelDetector.modelName(of: entity) { return model }
        var name = entity.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = ["Print Status", "Printer Status", "打印状态", "打印机状态", "Status"]
        for suffix in suffixes where name.lowercased().hasSuffix(suffix.lowercased()) {
            name.removeLast(suffix.count)
            name = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "-_·")))
            break
        }
        return name.isEmpty ? "Bambu Lab 打印机" : name
    }

    private func normalizedServerURL(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            .lowercased()
    }

    public func formlabsSettings(for id: UUID) -> FormlabsConnectionSettings {
        settings.devices.first(where: { $0.id == id })?.settings.formlabsConnection
            ?? FormlabsConnectionSettings()
    }

    private func mutateFormlabsSettings(_ id: UUID,
                                        _ body: (inout FormlabsConnectionSettings) -> Void) {
        guard let index = settings.devices.firstIndex(where: { $0.id == id && $0.type == .formlabs }) else { return }
        var value = settings.devices[index].settings.formlabsConnection ?? FormlabsConnectionSettings()
        let previousSerial = value.printerSerial
        body(&value)
        settings.devices[index].settings.formlabsConnection = value
        if value.printerSerial != previousSerial {
            // 改绑另一台实体打印机时，旧打印机的最近任务不能串到新设备上。
            formlabsSnapshots[id] = nil
            store.saveFormlabsTaskCache(formlabsSnapshots)
        }
        lastFormlabsRefresh[id] = nil
    }

    public func formlabsStringBinding(for id: UUID,
                                      _ keyPath: WritableKeyPath<FormlabsConnectionSettings, String>) -> Binding<String> {
        Binding(get: { self.formlabsSettings(for: id)[keyPath: keyPath] },
                set: { value in self.mutateFormlabsSettings(id) { $0[keyPath: keyPath] = value } })
    }

    public func formlabsBoolBinding(for id: UUID,
                                    _ keyPath: WritableKeyPath<FormlabsConnectionSettings, Bool>) -> Binding<Bool> {
        Binding(get: { self.formlabsSettings(for: id)[keyPath: keyPath] },
                set: { value in self.mutateFormlabsSettings(id) { $0[keyPath: keyPath] = value } })
    }

    public func chooseFormlabsCloudPrinter(_ printer: FormlabsDeviceInfo, for id: UUID) {
        mutateFormlabsSettings(id) {
            $0.printerSerial = printer.id
        }
        if let index = settings.devices.firstIndex(where: { $0.id == id }),
           settings.devices[index].name.hasPrefix("Formlabs ") {
            settings.devices[index].name = printer.productName
        }
        renderPreview()
    }

    public func discoverFormlabsDevices(_ id: UUID) async {
        let config = formlabsSettings(for: id)
        formlabsConnectionStatus[id] = "正在从 Formlabs 云端读取打印机…"
        do {
            let devices = try await formlabsClient.cloudPrinters(
                clientID: config.clientID, clientSecret: config.clientSecret)
            formlabsDiscoveredDevices[id] = devices
            formlabsConnectionStatus[id] = devices.isEmpty
                ? "云端账号下没有可用打印机" : "云端发现 \(devices.count) 台打印机"
        } catch {
            formlabsConnectionStatus[id] = "云端读取失败：\(error.localizedDescription)"
        }
    }

    public func testFormlabsConnection(_ id: UUID) async {
        let config = formlabsSettings(for: id)
        formlabsConnectionStatus[id] = "正在测试 Formlabs 云端连接…"
        formlabsConnectionStatus[id] = await formlabsCloudTestText(config)
        await refreshFormlabs(deviceID: id, force: true, pushIfVisible: true)
    }

    // MARK: - 口袋先知局域网发现

    /// 低并发扫描当前 /24 网段。已添加设备不再握手，避免打断它正在使用的显示连接。
    public func scanRand0Devices(force: Bool = false) async {
        guard !rand0DiscoveryBusy else { return }
        if !force, didAutoScanRand0 { return }
        didAutoScanRand0 = true
        rand0DiscoveryBusy = true
        rand0DiscoveryStatus = "正在查找局域网中的口袋先知…"
        defer { rand0DiscoveryBusy = false }
        let excluded = Set(devices(for: .oracle).compactMap { device -> String? in
            let host = EndpointBuilder.host(from: device.settings.rand0IP ?? "")
            return host.isEmpty ? nil : host
        })
        let found = await Rand0Discovery.scanLocalNetwork(excluding: excluded)
        rand0DiscoveredDevices = found
        rand0DiscoveryStatus = found.isEmpty
            ? "没有发现新的口袋先知，可继续使用手动添加"
            : "发现 \(found.count) 台尚未添加的口袋先知"
    }

    public func isRand0DeviceAdded(_ discovered: Rand0DiscoveredDevice) -> Bool {
        let host = EndpointBuilder.host(from: discovered.ip)
        return devices(for: .oracle).contains {
            EndpointBuilder.host(from: $0.settings.rand0IP ?? "") == host
        }
    }

    /// 扫描结果按 IP 去重；每台口袋先知保留独立档案与画板设置。
    @discardableResult
    public func addDiscoveredRand0Device(_ discovered: Rand0DiscoveredDevice) -> UUID {
        let host = EndpointBuilder.host(from: discovered.ip)
        if let existing = devices(for: .oracle).first(where: {
            EndpointBuilder.host(from: $0.settings.rand0IP ?? "") == host
        }) {
            setDeviceEnabled(id: existing.id, enabled: true)
            switchDevice(type: .oracle, to: existing.id)
            rand0DiscoveryStatus = "该设备已在列表中 · \(host)"
            persistSettings()
            return existing.id
        }
        let id = addDevice(type: .oracle)
        guard let index = settings.devices.firstIndex(where: { $0.id == id }) else { return id }
        settings.deviceSyncInFlight = true
        settings.devices[index].settings.rand0IP = host
        settings.devices[index].name = discovered.displayName
        settings.rand0IP = host
        settings.deviceSyncInFlight = false
        rand0DiscoveredDevices.removeAll { $0.id == discovered.id }
        rand0DiscoveryStatus = "已添加 \(discovered.displayName) · \(host)"
        persistSettings()
        ensureRand0Session()
        return id
    }

    // MARK: - AI Mac 240×240 小屏幕

    public func scanAIMacScreens() async {
        guard !aiMacNetworkScanBusy else { return }
        aiMacNetworkScanBusy = true
        aiMacNetworkScanStatus = "正在扫描当前局域网…"
        defer { aiMacNetworkScanBusy = false }
        let devices = await AIMacScreenDiscovery.scanLocalNetwork()
        aiMacDiscoveredDevices = devices
        aiMacNetworkScanStatus = devices.isEmpty
            ? "没有发现已联网的小屏幕，请确认 Mac 与设备位于同一网络"
            : "发现 \(devices.count) 台已联网的小屏幕"
    }

    public func isAIMacScreenAdded(_ discovered: AIMacDiscoveredDevice) -> Bool {
        let host = AIMacScreenSupport.normalizedHost(discovered.ip)
        return devices(for: .aiMacScreen).contains {
            AIMacScreenSupport.normalizedHost($0.settings.aiMacScreen?.host ?? "") == host
        }
    }

    /// 扫描结果按 IP 去重；已有设备会被重新启用并定位，不会产生重复档案。
    @discardableResult
    public func addDiscoveredAIMacScreen(_ discovered: AIMacDiscoveredDevice) -> UUID? {
        let host = AIMacScreenSupport.normalizedHost(discovered.ip)
        if let existing = devices(for: .aiMacScreen).first(where: {
            AIMacScreenSupport.normalizedHost($0.settings.aiMacScreen?.host ?? "") == host
        }) {
            setDeviceEnabled(id: existing.id, enabled: true)
            switchDevice(type: .aiMacScreen, to: existing.id)
            aiMacScreenStatuses[existing.id] = "已在设备列表中 · \(host)"
            Task { await testAIMacScreenConnection(deviceID: existing.id) }
            return existing.id
        }
        guard settings.canAddDevice(of: .aiMacScreen) else {
            aiMacNetworkScanStatus = "AI Mac 小屏幕已达到 5 台上限"
            return nil
        }
        let id = addDevice(type: .aiMacScreen)
        mutateAIMacScreenSettings(id, schedulePush: false) { $0.host = host }
        if let index = settings.devices.firstIndex(where: { $0.id == id }) {
            settings.devices[index].name = discovered.displayName
        }
        aiMacScreenStatuses[id] = "已通过局域网扫描添加 · \(host)"
        persistSettings()
        Task { await testAIMacScreenConnection(deviceID: id) }
        return id
    }

    private var embeddedAIMacFirmwareURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("Firmware", isDirectory: true)
            .appendingPathComponent(EmbeddedAIMacFirmware.fileName)
    }

    private var embeddedAIMacFlashHelperURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("Firmware", isDirectory: true)
            .appendingPathComponent(EmbeddedAIMacFirmware.helperName)
    }

    /// 固件资源随应用包固定不变，首次读取后缓存校验结果，避免刷写进度刷新 UI 时反复计算 SHA-256。
    public private(set) lazy var embeddedAIMacFirmwareReady: Bool = {
        guard let firmwareURL = embeddedAIMacFirmwareURL,
              let helperURL = embeddedAIMacFlashHelperURL,
              let firmware = try? Data(contentsOf: firmwareURL) else { return false }
        return EmbeddedAIMacFirmware.validate(firmware)
            && FileManager.default.isExecutableFile(atPath: helperURL.path)
    }()

    public func refreshAIMacFlashPorts() {
        aiMacFlashPorts = ESP8266FirmwareFlasher.discoverSerialPorts()
        if !aiMacFlashPorts.contains(where: { $0.path == selectedAIMacFlashPort }) {
            selectedAIMacFlashPort = aiMacFlashPorts.first?.path ?? ""
        }
        if aiMacFlashPorts.isEmpty {
            aiMacFlashStatus = "没有发现 USB 串口，请检查数据线或 USB 转串口驱动"
        } else if !aiMacFlashBusy {
            aiMacFlashStatus = "已发现 \(aiMacFlashPorts.count) 个可用串口"
        }
    }

    @discardableResult
    public func flashAIMacFirmware(addDeviceAfterSuccess: Bool,
                                   ssid: String,
                                   password: String) async -> Bool {
        guard !aiMacFlashBusy else { return false }
        guard let port = aiMacFlashPorts.first(where: { $0.path == selectedAIMacFlashPort }) else {
            aiMacFlashStatus = ESP8266FlashError.noPort.localizedDescription
            return false
        }
        guard let firmwareURL = embeddedAIMacFirmwareURL,
              let helperURL = embeddedAIMacFlashHelperURL else {
            aiMacFlashStatus = ESP8266FlashError.missingResource("AI Mac 固件").localizedDescription
            return false
        }
        let provisioningImage: Data
        do {
            provisioningImage = try AIMacWiFiProvisioning.makeImage(ssid: ssid,
                                                                    password: password)
        } catch {
            aiMacFlashStatus = error.localizedDescription
            return false
        }
        aiMacFlashBusy = true
        aiMacFlashProgress = 0
        aiMacFlashLog = ""
        aiMacFlashStatus = "正在写入固件与 Wi-Fi 配置…"
        defer {
            aiMacDiscoveryTask = nil
            aiMacFlashBusy = false
        }
        do {
            let result = try await esp8266Flasher.flash(
                port: port, helperURL: helperURL, firmwareURL: firmwareURL,
                wifiProvisioningImage: provisioningImage,
                progress: { [weak self] value in
                    Task { @MainActor in
                        self?.aiMacFlashProgress = value
                        self?.aiMacFlashStatus = value > 0
                            ? "正在刷入固件与配网数据… \(Int((value * 100).rounded()))%"
                            : "正在连接 ESP8266…"
                    }
                },
                log: { [weak self] text in
                    Task { @MainActor in
                        guard let self else { return }
                        self.aiMacFlashLog += text
                        if self.aiMacFlashLog.count > 20_000 {
                            self.aiMacFlashLog = String(self.aiMacFlashLog.suffix(20_000))
                        }
                    }
                })
            aiMacFlashProgress = 1
            status = "AI Mac 小屏幕固件与 Wi-Fi 配置刷入成功"
            guard let hostname = result.expectedHostname else {
                aiMacFlashStatus = "固件与 Wi-Fi 已刷入，但未能读取设备识别码；请等待屏幕显示 IP 后手动添加"
                return true
            }

            aiMacFlashStatus = "刷入成功，正在等待 \(hostname).local 联网…"
            let discovery = Task {
                try await AIMacScreenDiscovery.waitForDevice(hostname: hostname) {
                    [weak self] attempt in
                    Task { @MainActor in
                        self?.aiMacFlashStatus = "刷入成功，正在等待设备联网… 第 \(attempt) 次检测"
                    }
                }
            }
            aiMacDiscoveryTask = discovery
            do {
                let ip = try await discovery.value
                if addDeviceAfterSuccess {
                    guard settings.canAddDevice(of: .aiMacScreen) else {
                        aiMacFlashStatus = "设备已联网（\(ip)），但 AI Mac 设备列表已达到 5 台上限"
                        return true
                    }
                    let id = addDevice(type: .aiMacScreen)
                    mutateAIMacScreenSettings(id, schedulePush: false) { $0.host = ip }
                    aiMacScreenStatuses[id] = "已通过刷机流程自动连接 · \(ip)"
                    aiMacFlashStatus = "全部完成：固件刷入成功，设备已联网并自动添加（\(ip)）"
                    status = "AI Mac 小屏幕已自动添加"
                    await testAIMacScreenConnection(deviceID: id)
                } else {
                    aiMacFlashStatus = "固件刷入成功，设备已联网 · IP：\(ip)"
                }
            } catch is CancellationError {
                aiMacFlashStatus = "固件与 Wi-Fi 已刷入；已停止等待设备联网"
            } catch {
                aiMacFlashStatus = error.localizedDescription
                status = "固件刷入成功，但自动发现设备尚未完成"
            }
            refreshAIMacFlashPorts()
            return true
        } catch {
            aiMacFlashStatus = error.localizedDescription
            status = "AI Mac 小屏幕固件刷入失败"
            refreshAIMacFlashPorts()
            return false
        }
    }

    public func cancelAIMacFirmwareFlash() {
        esp8266Flasher.cancel()
        aiMacDiscoveryTask?.cancel()
        aiMacFlashStatus = aiMacFlashProgress >= 1
            ? "正在停止等待设备联网…" : "正在停止刷写…"
    }

    public func aiMacScreenSettings(for id: UUID) -> AIMacScreenDeviceSettings {
        settings.devices.first(where: { $0.id == id && $0.type == .aiMacScreen })?
            .settings.aiMacScreen ?? AIMacScreenDeviceSettings()
    }

    private func mutateAIMacScreenSettings(
        _ id: UUID,
        pushImmediately: Bool = false,
        schedulePush: Bool = true,
        _ body: (inout AIMacScreenDeviceSettings) -> Void
    ) {
        guard let index = settings.devices.firstIndex(where: {
            $0.id == id && $0.type == .aiMacScreen
        }) else { return }
        var value = settings.devices[index].settings.aiMacScreen ?? AIMacScreenDeviceSettings()
        let previousHost = AIMacScreenSupport.normalizedHost(value.host)
        body(&value)
        value.clamp()
        settings.devices[index].settings.aiMacScreen = value
        if AIMacScreenSupport.normalizedHost(value.host) != previousHost {
            aiMacScreenCapabilities[id] = nil
            aiMacScreenLastHashes[id] = nil
            aiMacScreenLastPushAt[id] = nil
            aiMacScreenLosslessIDs.remove(id)
        }
        persistSettings()
        refreshAIMacScreenPreview(deviceID: id)
        if schedulePush && (pushImmediately || value.autoPush) {
            Task { @MainActor [weak self] in
                await self?.pushAIMacScreen(deviceID: id, force: pushImmediately)
            }
        }
    }

    public func aiMacScreenHostBinding(for id: UUID) -> Binding<String> {
        Binding(get: { self.aiMacScreenSettings(for: id).host }, set: { value in
            self.mutateAIMacScreenSettings(id) { $0.host = value }
        })
    }

    public func aiMacScreenModeBinding(for id: UUID) -> Binding<AIMacScreenContentMode> {
        Binding(get: { self.aiMacScreenSettings(for: id).mode }, set: { value in
            self.mutateAIMacScreenSettings(id, pushImmediately: true) { $0.mode = value }
        })
    }

    public func activateAIMacScreenMode(_ mode: AIMacScreenContentMode,
                                        deviceID: UUID) {
        let current = aiMacScreenSettings(for: deviceID).mode
        mutateAIMacScreenSettings(deviceID, pushImmediately: current != mode) {
            $0.mode = mode
        }
    }

    public func aiMacScreenAutoPushBinding(for id: UUID) -> Binding<Bool> {
        Binding(get: { self.aiMacScreenSettings(for: id).autoPush }, set: { value in
            self.mutateAIMacScreenSettings(id, pushImmediately: value) { $0.autoPush = value }
        })
    }

    public func aiMacScreenIntervalBinding(for id: UUID) -> Binding<Int> {
        Binding(get: { self.aiMacScreenSettings(for: id).pushIntervalSeconds }, set: { value in
            self.mutateAIMacScreenSettings(id) { $0.pushIntervalSeconds = value }
        })
    }

    public func aiMacScreenJPEGQualityBinding(for id: UUID) -> Binding<Int> {
        Binding(get: { self.aiMacScreenSettings(for: id).jpegQuality }, set: { value in
            self.mutateAIMacScreenSettings(id, pushImmediately: true) { $0.jpegQuality = value }
        })
    }

    // MARK: AI Mac 通用卡片能力

    /// 统一目录根据现有打印机设备动态裁剪可用卡片；AI Mac 自己的多画板有独立入口，
    /// 因此不在通用卡片列表中重复显示“灵犀画板”。
    public var availableAIMacCardModes: [DisplayMode] {
        guard let surface = DeviceType.aiMacScreen.capabilityProfile?.cardSurface else { return [] }
        return CardCapabilityRegistry.modes(
            for: surface,
            bambuPrinterCount: enabledDevices(for: .bambuLab).count,
            formlabsPrinterCount: enabledDevices(for: .formlabs).count,
            includesDeviceCanvas: false)
    }

    public func aiMacCardList(for deviceID: UUID) -> [DisplayMode] {
        let config = aiMacScreenSettings(for: deviceID)
        guard let stored = config.cardPanels else { return availableAIMacCardModes }
        return CardCapabilityRegistry.sanitized(stored, available: availableAIMacCardModes)
    }

    public func aiMacHiddenCardList(for deviceID: UUID) -> [DisplayMode] {
        let visible = Set(aiMacCardList(for: deviceID))
        return availableAIMacCardModes.filter { !visible.contains($0) }
    }

    public func isCurrentAIMacCard(deviceID: UUID, mode: DisplayMode) -> Bool {
        let config = aiMacScreenSettings(for: deviceID)
        return config.mode == .card && config.cardMode == mode
    }

    public func activateAIMacCard(_ mode: DisplayMode, deviceID: UUID) {
        guard availableAIMacCardModes.contains(mode) else { return }
        mutateAIMacScreenSettings(deviceID, schedulePush: false) { config in
            config.mode = .card
            config.cardMode = mode
        }
        aiMacScreenLastCardRotation[deviceID] = Date()
        Task { @MainActor [weak self] in
            await self?.refreshAIMacCardDataAndPush(mode: mode, deviceID: deviceID)
        }
    }

    public func setAIMacCardVisible(_ mode: DisplayMode, visible: Bool, deviceID: UUID) {
        var list = aiMacCardList(for: deviceID)
        if visible {
            if !list.contains(mode) { list.append(mode) }
        } else {
            list.removeAll { $0 == mode }
        }
        mutateAIMacScreenSettings(deviceID) { config in
            config.cardPanels = list.map(\.rawValue)
            config.cardRotationModes = (config.cardRotationModes ?? [])
                .filter { list.map(\.rawValue).contains($0) }
        }
    }

    public func commitAIMacCardOrder(_ modes: [DisplayMode], deviceID: UUID) {
        mutateAIMacScreenSettings(deviceID) { config in
            config.cardPanels = CardCapabilityRegistry
                .sanitized(modes.map(\.rawValue), available: availableAIMacCardModes)
                .map(\.rawValue)
        }
    }

    public func aiMacCardRotationList(for deviceID: UUID) -> [DisplayMode] {
        let config = aiMacScreenSettings(for: deviceID)
        let selected = Set(config.cardRotationModes ?? [])
        return aiMacCardList(for: deviceID).filter { selected.contains($0.rawValue) }
    }

    public func setAIMacCardRotationMode(_ mode: DisplayMode, enabled: Bool,
                                         deviceID: UUID) {
        mutateAIMacScreenSettings(deviceID) { config in
            var values = config.cardRotationModes ?? []
            if enabled {
                if !values.contains(mode.rawValue) { values.append(mode.rawValue) }
            } else {
                values.removeAll { $0 == mode.rawValue }
            }
            config.cardRotationModes = values
        }
    }

    public func aiMacCardRotationBinding(for deviceID: UUID) -> Binding<Bool> {
        Binding(get: { self.aiMacScreenSettings(for: deviceID).cardRotationEnabled }, set: { value in
            self.mutateAIMacScreenSettings(deviceID) { $0.cardRotationEnabled = value }
            self.aiMacScreenLastCardRotation[deviceID] = Date()
        })
    }

    public func aiMacCardRotationMinutesBinding(for deviceID: UUID) -> Binding<Double> {
        Binding(get: { Double(self.aiMacScreenSettings(for: deviceID).cardRotationMinutes) },
                set: { value in
            self.mutateAIMacScreenSettings(deviceID) {
                $0.cardRotationMinutes = Int(value.rounded())
            }
            self.aiMacScreenLastCardRotation[deviceID] = Date()
        })
    }

    /// 按能力目录刷新一张卡片真正依赖的数据，再向目标小屏推送；不改变灵犀 68 当前卡片。
    private func refreshAIMacCardDataAndPush(mode: DisplayMode, deviceID: UUID) async {
        guard let capability = CardCapabilityRegistry.capability(for: mode),
              aiMacScreenSettings(for: deviceID).mode == .card,
              aiMacScreenSettings(for: deviceID).cardMode == mode else { return }
        let requirements = capability.requirements
        if requirements.contains(.system) {
            _ = monitor.sample(now: Date())
            try? await Task.sleep(nanoseconds: 120_000_000)
            system = monitor.sample(now: Date())
        }
        if requirements.contains(.nowPlaying) {
            await refreshNowPlaying(now: Date())
        }
        if requirements.contains(.quotas) {
            _ = await refreshUsageAndQuota()
        }
        if requirements.contains(.sspai) {
            _ = await fetchSspai()
        }
        if requirements.contains(.homeAssistant) {
            // 普通 HA 卡片需要完整实体池；打印机卡片只刷新该槽位已绑定的实体。
            if mode.bambuSlotIndex != nil {
                await refreshBambuEntities(for: mode)
            } else {
                await refreshHA(includePictures: false)
            }
        }
        if requirements.contains(.formlabs),
           let printer = formlabsDevice(for: mode) {
            await refreshFormlabs(deviceID: printer.id, force: true, pushIfVisible: false)
        }
        await pushAIMacScreen(deviceID: deviceID, force: true)
        if mode == .homeAssistant {
            let ids = haCardPictureEntityIDs()
            if await refreshHAPictures(entities: haSnapshot.entities, wantedIDs: ids) {
                await pushAIMacScreen(deviceID: deviceID, force: false)
            }
        } else if mode.bambuSlotIndex != nil {
            let config = bambuConfig(for: mode)
            if config.showImage, !config.selectedImageEntityID.isEmpty,
               await refreshHAPictures(entities: haSnapshot.entities,
                                       wantedIDs: [config.selectedImageEntityID]) {
                await pushAIMacScreen(deviceID: deviceID, force: false)
            }
        }
    }

    public func aiMacCanvasBoards(for deviceID: UUID) -> [AIMacCanvasBoard] {
        aiMacScreenSettings(for: deviceID).canvasBoards
    }

    public func visibleAIMacCanvasBoards(for deviceID: UUID) -> [AIMacCanvasBoard] {
        aiMacCanvasBoards(for: deviceID).filter(\.isSidebarVisible)
    }

    public func isCurrentAIMacCanvasBoard(deviceID: UUID, boardID: UUID) -> Bool {
        let config = aiMacScreenSettings(for: deviceID)
        return config.mode == .canvas
            && config.canvasBoards.indices.contains(config.canvasBoardIndex)
            && config.canvasBoards[config.canvasBoardIndex].id == boardID
    }

    public var aiMacCanvasBoardName: String {
        guard let id = activeDeviceID(for: .aiMacScreen) else { return "未命名" }
        let config = aiMacScreenSettings(for: id)
        guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else {
            return CanvasBoardNamingPolicy.untitledName
        }
        return config.canvasBoards[config.canvasBoardIndex].name
    }

    public var aiMacCanvasModules: [CanvasModule] {
        guard let id = activeDeviceID(for: .aiMacScreen) else { return [] }
        let config = aiMacScreenSettings(for: id)
        guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return [] }
        return config.canvasBoards[config.canvasBoardIndex].moduleList
    }

    private func mutateCurrentAIMacCanvasBoard(
        pushImmediately: Bool = true,
        _ body: (inout AIMacCanvasBoard) -> Void
    ) {
        guard let id = activeDeviceID(for: .aiMacScreen) else { return }
        mutateAIMacScreenSettings(id, pushImmediately: pushImmediately) { config in
            guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return }
            body(&config.canvasBoards[config.canvasBoardIndex])
            config.canvasBoards[config.canvasBoardIndex].clamp()
            config.mode = .canvas
        }
    }

    public func addAIMacCanvasBoard() {
        guard let id = activeDeviceID(for: .aiMacScreen) else { return }
        mutateAIMacScreenSettings(id, pushImmediately: true) { config in
            config.canvasBoards.append(AIMacCanvasBoard())
            config.canvasBoardIndex = config.canvasBoards.count - 1
            config.mode = .canvas
        }
        aiMacScreenLastBoardRotation[id] = Date()
        aiMacScreenStatuses[id] = "已创建空白画板，添加第一个模块后会自动命名"
    }

    public func applyAIMacCanvasBoard(deviceID: UUID, boardID: UUID) {
        if activeDeviceID(for: .aiMacScreen) != deviceID {
            switchDevice(type: .aiMacScreen, to: deviceID)
        }
        mutateAIMacScreenSettings(deviceID, pushImmediately: true) { config in
            guard let index = config.canvasBoards.firstIndex(where: { $0.id == boardID }) else { return }
            config.canvasBoardIndex = index
            config.mode = .canvas
        }
        aiMacScreenLastBoardRotation[deviceID] = Date()
    }

    @discardableResult
    public func cycleAIMacCanvasBoard(deviceID: UUID, direction: Int,
                                      automaticRotation: Bool = false) -> Bool {
        let config = aiMacScreenSettings(for: deviceID)
        let eligible = config.canvasBoards.indices.filter { index in
            let board = config.canvasBoards[index]
            return board.isSidebarVisible
                && (!automaticRotation || board.participatesInRotation)
        }
        guard eligible.count > 1 else { return false }
        let current = min(max(config.canvasBoardIndex, 0), config.canvasBoards.count - 1)
        let anchor = eligible.firstIndex(of: current)
            ?? (direction >= 0 ? eligible.count - 1 : 0)
        let position = ((anchor + direction) % eligible.count + eligible.count) % eligible.count
        let nextIndex = eligible[position]
        mutateAIMacScreenSettings(deviceID, pushImmediately: !automaticRotation,
                                  schedulePush: !automaticRotation) { value in
            value.canvasBoardIndex = nextIndex
            value.mode = .canvas
        }
        aiMacScreenLastBoardRotation[deviceID] = Date()
        return true
    }

    public func renameAIMacCanvasBoard(id boardID: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              let deviceID = activeDeviceID(for: .aiMacScreen) else { return }
        mutateAIMacScreenSettings(deviceID) { config in
            guard let index = config.canvasBoards.firstIndex(where: { $0.id == boardID }) else { return }
            config.canvasBoards[index].name = clean
        }
    }

    public func setAIMacCanvasBoardSidebarVisible(id boardID: UUID, visible: Bool) {
        guard let deviceID = activeDeviceID(for: .aiMacScreen) else { return }
        mutateAIMacScreenSettings(deviceID) { config in
            guard let index = config.canvasBoards.firstIndex(where: { $0.id == boardID }) else { return }
            config.canvasBoards[index].sidebarVisible = visible
        }
    }

    public func setAIMacCanvasBoardRotationEnabled(id boardID: UUID, enabled: Bool) {
        guard let deviceID = activeDeviceID(for: .aiMacScreen) else { return }
        mutateAIMacScreenSettings(deviceID) { config in
            guard let index = config.canvasBoards.firstIndex(where: { $0.id == boardID }) else { return }
            config.canvasBoards[index].rotationEnabled = enabled
        }
    }

    public func removeAIMacCanvasBoard(id boardID: UUID) {
        guard let deviceID = activeDeviceID(for: .aiMacScreen) else { return }
        mutateAIMacScreenSettings(deviceID, pushImmediately: true) { config in
            guard let index = config.canvasBoards.firstIndex(where: { $0.id == boardID }) else { return }
            config.canvasBoards.remove(at: index)
            if config.canvasBoards.isEmpty {
                config.canvasBoardIndex = 0
            } else if index < config.canvasBoardIndex {
                config.canvasBoardIndex -= 1
            } else if config.canvasBoardIndex >= config.canvasBoards.count {
                config.canvasBoardIndex = config.canvasBoards.count - 1
            }
            config.mode = .canvas
        }
    }

    public func commitAIMacCanvasBoards(_ boards: [AIMacCanvasBoard]) {
        guard let deviceID = activeDeviceID(for: .aiMacScreen) else { return }
        let old = aiMacScreenSettings(for: deviceID)
        let currentID = old.canvasBoards.indices.contains(old.canvasBoardIndex)
            ? old.canvasBoards[old.canvasBoardIndex].id : nil
        mutateAIMacScreenSettings(deviceID) { config in
            config.canvasBoards = boards
            config.canvasBoardIndex = currentID.flatMap { id in
                boards.firstIndex(where: { $0.id == id })
            } ?? 0
        }
    }

    public func aiMacBackgroundModeBinding(for deviceID: UUID) -> Binding<CanvasBackgroundMode> {
        Binding(get: {
            let config = self.aiMacScreenSettings(for: deviceID)
            guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return .dark }
            return config.canvasBoards[config.canvasBoardIndex].backgroundMode
        }, set: { value in
            self.mutateCurrentAIMacCanvasBoard { $0.backgroundMode = value }
        })
    }

    public func aiMacBoardRotationBinding(for deviceID: UUID) -> Binding<Bool> {
        Binding(get: { self.aiMacScreenSettings(for: deviceID).boardRotationEnabled }, set: { value in
            self.mutateAIMacScreenSettings(deviceID) { $0.boardRotationEnabled = value }
            self.aiMacScreenLastBoardRotation[deviceID] = Date()
        })
    }

    public func aiMacBoardRotationMinutesBinding(for deviceID: UUID) -> Binding<Int> {
        Binding(get: { self.aiMacScreenSettings(for: deviceID).boardRotationMinutes }, set: { value in
            self.mutateAIMacScreenSettings(deviceID) { $0.boardRotationMinutes = value }
            self.aiMacScreenLastBoardRotation[deviceID] = Date()
        })
    }

    public func chooseAIMacScreenImage(deviceID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "选择 AI Mac 小屏幕图片"
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let stored = try store.saveHistoryImage(from: url)
            let wasCard = aiMacScreenSettings(for: deviceID).mode == .card
            mutateAIMacScreenSettings(deviceID, pushImmediately: true) {
                $0.customImagePath = stored.path
                $0.mode = wasCard ? .card : .customImage
                if wasCard { $0.cardMode = .customImage }
            }
        } catch {
            aiMacScreenStatuses[deviceID] = "图片保存失败：\(error.localizedDescription)"
        }
    }

    private func aiMacCanvasArticles(deviceID: UUID, board: AIMacCanvasBoard) -> [SspaiArticle] {
        let count = min(max(board.sspaiCount, 1), 6)
        guard board.sspaiRandom, sspaiArticles.count > count else {
            return Array(sspaiArticles.prefix(count))
        }
        let key = "\(deviceID.uuidString)|\(board.id.uuidString)"
        let cached = aiMacSspaiRandomSelection[key]
        let stale = cached == nil || cached!.count != count || cached!.contains { article in
            !sspaiArticles.contains { $0.id == article.id }
        }
        if stale {
            aiMacSspaiRandomSelection[key] = Array(sspaiArticles.shuffled().prefix(count))
        }
        return aiMacSspaiRandomSelection[key] ?? Array(sspaiArticles.prefix(count))
    }

    private func renderAIMacScreen(deviceID: UUID,
                                   config: AIMacScreenDeviceSettings,
                                   system snapshot: SystemSnapshot,
                                   now: Date = Date()) throws -> CGImage {
        if config.mode == .card {
            return try renderAIMacCard(deviceID: deviceID, mode: config.cardMode,
                                       config: config, system: snapshot, now: now)
        }
        guard config.mode == .canvas else {
            return try AIMacScreenSupport.render(settings: config, system: snapshot, now: now)
        }
        let board = config.canvasBoards.indices.contains(config.canvasBoardIndex)
            ? config.canvasBoards[config.canvasBoardIndex] : AIMacCanvasBoard()
        let dark = board.backgroundMode == .dark
        let palette = ScreenThemes.resolved(theme: settings.cardTheme,
                                            backgroundTone: dark ? .dark : .light,
                                            customBackgroundHex: nil,
                                            accentTone: settings.accentTone,
                                            customAccentHex: settings.customAccentHex,
                                            softwareIsDark: dark)
        return ScreenRenderer.renderDeviceCanvas(
            modules: board.moduleList, system: snapshot,
            nowPlaying: nowPlaying, pomodoro: pomodoroSnapshot,
            customText: settings.canvasText, settings: settings,
            codex: usage, qwenQuota: qwenQuota,
            sspaiArticles: aiMacCanvasArticles(deviceID: deviceID, board: board),
            ha: haSnapshot.selecting(entityIDs: board.haEntityIDs),
            formlabsItems: formlabsCanvasItems(), now: now,
            width: AIMacScreenSupport.frameSize, height: AIMacScreenSupport.frameSize,
            palette: palette, optimizeForEInk: false,
            nowPlayingHorizontal: board.nowPlayingHorizontal,
            canvasImagePath: board.imagePath, printerFields: board.printerFields,
            optimizeBambuForOracleEInk: false,
            bambuHeroLayout: true,
            showBambuCamera: true,
            nowPlayingSmartBackground: board.usesNowPlayingSmartBackground,
            nowPlayingShowCover: board.usesNowPlayingCover)
    }

    /// 通用卡片渲染入口：具体设备只负责尺寸、色彩能力与传输方式；卡片到模块的
    /// 映射完全来自 CardCapabilityRegistry，后续新增模块不再修改 AI Mac 的页面分支。
    private func renderAIMacCard(deviceID: UUID, mode: DisplayMode,
                                 config: AIMacScreenDeviceSettings,
                                 system snapshot: SystemSnapshot,
                                 now: Date) throws -> CGImage {
        guard let capability = CardCapabilityRegistry.capability(for: mode) else {
            throw AIMacScreenSupportError.encodeFailed
        }
        switch capability.recipe {
        case .customImage:
            var imageConfig = config
            imageConfig.mode = .customImage
            if imageConfig.customImagePath == nil { imageConfig.customImagePath = settings.customImagePath }
            return try AIMacScreenSupport.render(settings: imageConfig, system: snapshot, now: now)
        case .emojiWallpaper:
            return try AIMacScreenSupport.renderEmojiWallpaper(settings: settings)
        case .deviceCanvas:
            // AI Mac 的设备画板走上层 canvas 分支；通用卡片列表不会暴露这一配方。
            throw AIMacScreenSupportError.encodeFailed
        case .modules(let modules):
            let dark = settings.softwareIsDark
            let palette = ScreenThemes.resolved(
                theme: settings.cardTheme,
                backgroundTone: dark ? .dark : .light,
                customBackgroundHex: nil,
                accentTone: settings.accentTone,
                customAccentHex: settings.customAccentHex,
                softwareIsDark: dark)
            let cardHA = mode == .homeAssistant
                ? haSnapshot.selecting(entityIDs: settings.haCardEntityIDs)
                : haSnapshot
            let articles = mode == .sspai ? Array(sspaiArticles.prefix(3)) : []
            var fields: [Int: CanvasPrinterFields] = [:]
            for module in modules where module.bambuSlotIndex != nil || module.formlabsSlotIndex != nil {
                fields[module.rawValue] = settings.canvasPrinterFields(for: module)
            }
            return ScreenRenderer.renderDeviceCanvas(
                modules: modules, system: snapshot,
                nowPlaying: nowPlaying, pomodoro: pomodoroSnapshot,
                customText: mode == .excerptQuote ? quoteDisplayText : settings.canvasText,
                settings: settings, codex: usage, qwenQuota: qwenQuota,
                sspaiArticles: articles, ha: cardHA,
                formlabsItems: formlabsCanvasItems(), now: now,
                width: AIMacScreenSupport.frameSize, height: AIMacScreenSupport.frameSize,
                palette: palette, optimizeForEInk: false,
                nowPlayingHorizontal: mode == .nowPlaying,
                canvasImagePath: config.customImagePath ?? settings.customImagePath,
                printerFields: fields,
                optimizeBambuForOracleEInk: false,
                bambuHeroLayout: true,
                showBambuCamera: true,
                nowPlayingSmartBackground: mode == .nowPlaying,
                nowPlayingShowCover: mode == .nowPlaying)
        }
    }

    public func refreshAIMacScreenPreview(deviceID: UUID) {
        let config = aiMacScreenSettings(for: deviceID)
        do {
            let image = try renderAIMacScreen(deviceID: deviceID, config: config, system: system)
            aiMacScreenPreviews[deviceID] = NSImage(
                cgImage: image, size: NSSize(width: 240, height: 240))
        } catch {
            aiMacScreenPreviews[deviceID] = nil
            aiMacScreenStatuses[deviceID] = error.localizedDescription
        }
    }

    private func fetchAIMacScreenCapabilities(
        deviceID: UUID,
        force: Bool = false
    ) async throws -> AIMacScreenCapabilities {
        let config = aiMacScreenSettings(for: deviceID)
        let host = AIMacScreenSupport.normalizedHost(config.host)
        guard !host.isEmpty else { throw AIMacScreenSupportError.invalidHost }
        if !force, let cached = aiMacScreenCapabilities[deviceID], cached.host == host {
            return cached
        }
        guard let infoURL = AIMacScreenSupport.infoURL(host: host) else {
            throw AIMacScreenSupportError.invalidHost
        }
        var request = URLRequest(url: infoURL)
        request.timeoutInterval = 4
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw AIMacScreenSupportError.invalidDevice
            }
            let capabilities = try AIMacScreenSupport.parseCapabilities(data: data, host: host)
            aiMacScreenCapabilities[deviceID] = capabilities
            return capabilities
        } catch {
            // 0.6.x 等旧版固件没有能力接口，但仍支持 /image/upload。
            let fallback = try AIMacScreenSupport.jpegOnlyCapabilities(host: host)
            aiMacScreenCapabilities[deviceID] = fallback
            return fallback
        }
    }

    public func testAIMacScreenConnection(deviceID: UUID) async {
        guard !aiMacScreenBusyIDs.contains(deviceID) else { return }
        aiMacScreenBusyIDs.insert(deviceID)
        aiMacScreenStatuses[deviceID] = "正在检测小屏幕…"
        defer { aiMacScreenBusyIDs.remove(deviceID) }
        do {
            let capabilities = try await fetchAIMacScreenCapabilities(deviceID: deviceID, force: true)
            if capabilities.supportsLosslessRGB565 {
                aiMacScreenLosslessIDs.insert(deviceID)
                aiMacScreenStatuses[deviceID] = "连接成功 · RGB565 无损模式"
            } else {
                aiMacScreenLosslessIDs.remove(deviceID)
                aiMacScreenStatuses[deviceID] = "地址可用 · JPEG 兼容模式"
            }
        } catch {
            aiMacScreenStatuses[deviceID] = "连接失败：\(error.localizedDescription)"
        }
    }

    public func pushAIMacScreen(deviceID: UUID, force: Bool = true) async {
        await pushAIMacScreen(deviceID: deviceID, force: force, sampleDashboard: true)
    }

    private func pushAIMacScreen(deviceID: UUID, force: Bool,
                                 sampleDashboard: Bool) async {
        guard !aiMacScreenBusyIDs.contains(deviceID),
              let device = settings.devices.first(where: {
                  $0.id == deviceID && $0.type == .aiMacScreen && $0.isEnabled
              }) else { return }
        let config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
        guard !AIMacScreenSupport.normalizedHost(config.host).isEmpty else {
            aiMacScreenStatuses[deviceID] = AIMacScreenSupportError.invalidHost.localizedDescription
            return
        }
        aiMacScreenBusyIDs.insert(deviceID)
        aiMacScreenLastPushAt[deviceID] = Date()
        aiMacScreenStatuses[deviceID] = "正在生成并推送画面…"
        defer { aiMacScreenBusyIDs.remove(deviceID) }
        do {
            let canvasNeedsSystem = config.mode == .canvas
                && config.canvasBoards.indices.contains(config.canvasBoardIndex)
                && RuntimePerformancePolicy.needsSystemSample(
                    modules: config.canvasBoards[config.canvasBoardIndex].moduleList)
            let cardNeedsSystem = config.mode == .card
                && (CardCapabilityRegistry.capability(for: config.cardMode)?
                    .requirements.contains(.system) ?? false)
            if sampleDashboard && (config.mode == .dashboard || canvasNeedsSystem || cardNeedsSystem) {
                system = monitor.sample(now: Date())
            }
            let image = try renderAIMacScreen(deviceID: deviceID, config: config, system: system)
            aiMacScreenPreviews[deviceID] = NSImage(
                cgImage: image, size: NSSize(width: 240, height: 240))
            let capabilities = try await fetchAIMacScreenCapabilities(deviceID: deviceID)
            let bytes: Data
            let endpoint: URL
            let modeText: String
            if let rgb565URL = capabilities.rgb565UploadURL {
                bytes = try AIMacScreenSupport.encodeRGB565(image)
                endpoint = rgb565URL
                modeText = "RGB565 无损"
                aiMacScreenLosslessIDs.insert(deviceID)
            } else {
                bytes = try AIMacScreenSupport.encodeJPEG(
                    image, preferredQuality: config.jpegQuality)
                endpoint = capabilities.jpegUploadURL
                modeText = "JPEG 兼容"
                aiMacScreenLosslessIDs.remove(deviceID)
            }
            let frameHash = SHA256.hash(data: bytes).map {
                String(format: "%02x", $0)
            }.joined()
            if !force, aiMacScreenLastHashes[deviceID] == frameHash {
                aiMacScreenStatuses[deviceID] = "画面未变化，已跳过推送"
                return
            }
            if capabilities.supportsLosslessRGB565 {
                _ = try await imageApi.upload(
                    rgb565: bytes, endpoint: endpoint.absoluteString, timeout: 12)
            } else {
                _ = try await imageApi.upload(
                    jpeg: bytes, endpoint: endpoint.absoluteString, timeout: 12)
            }
            aiMacScreenLastHashes[deviceID] = frameHash
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            aiMacScreenLastPushText[deviceID] = formatter.string(from: Date())
            aiMacScreenStatuses[deviceID] = "推送成功 · \(modeText)"
        } catch {
            aiMacScreenStatuses[deviceID] = "推送失败：\(error.localizedDescription)"
        }
    }

    private func maybeAutoPushAIMacScreens(now: Date) async {
        let dueDevices = enabledDevices(for: .aiMacScreen).filter { device in
            let config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
            guard config.autoPush,
                  !AIMacScreenSupport.normalizedHost(config.host).isEmpty,
                  !aiMacScreenBusyIDs.contains(device.id) else { return false }
            let interval = TimeInterval(max(1, config.pushIntervalSeconds))
            if let last = aiMacScreenLastPushAt[device.id], now.timeIntervalSince(last) < interval {
                return false
            }
            return true
        }
        // 同一秒有多台仪表盘需要推送时只采样一次系统状态，避免设备数增加后
        // CPU/内存/网络统计调用按台数重复放大。
        if dueDevices.contains(where: { device in
            let config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
            if config.mode == .dashboard { return true }
            if config.mode == .card {
                return CardCapabilityRegistry.capability(for: config.cardMode)?
                    .requirements.contains(.system) ?? false
            }
            guard config.mode == .canvas,
                  config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return false }
            return RuntimePerformancePolicy.needsSystemSample(
                modules: config.canvasBoards[config.canvasBoardIndex].moduleList)
        }) {
            system = monitor.sample(now: now)
        }
        for device in dueDevices {
            let config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
            guard config.mode == .canvas, config.boardRotationEnabled,
                  config.canvasBoards.filter({
                      $0.isSidebarVisible && $0.participatesInRotation
                  }).count > 1 else { continue }
            let interval = TimeInterval(config.boardRotationMinutes * 60)
            let last = aiMacScreenLastBoardRotation[device.id] ?? now
            if aiMacScreenLastBoardRotation[device.id] == nil {
                aiMacScreenLastBoardRotation[device.id] = now
            } else if now.timeIntervalSince(last) >= interval {
                _ = cycleAIMacCanvasBoard(deviceID: device.id, direction: 1,
                                          automaticRotation: true)
                aiMacScreenLastBoardRotation[device.id] = now
            }
        }
        for device in dueDevices {
            let config = aiMacScreenSettings(for: device.id)
            guard config.cardRotationEnabled else { continue }
            let modes = aiMacCardRotationList(for: device.id)
            guard modes.count > 1 else { continue }
            let last = aiMacScreenLastCardRotation[device.id] ?? now
            if aiMacScreenLastCardRotation[device.id] == nil {
                aiMacScreenLastCardRotation[device.id] = now
                continue
            }
            guard now.timeIntervalSince(last) >= TimeInterval(config.cardRotationMinutes * 60) else {
                continue
            }
            let current = modes.firstIndex(of: config.cardMode) ?? -1
            let next = modes[(current + 1 + modes.count) % modes.count]
            mutateAIMacScreenSettings(device.id, schedulePush: false) { value in
                value.mode = .card
                value.cardMode = next
            }
            aiMacScreenLastCardRotation[device.id] = now
        }
        for device in dueDevices {
            await pushAIMacScreen(deviceID: device.id, force: false, sampleDashboard: false)
        }
    }

    private func formlabsCloudTestText(_ config: FormlabsConnectionSettings) async -> String {
        do {
            _ = try await formlabsClient.testCloud(settings: config)
            return "Formlabs 云端已连接"
        } catch { return "云端失败：\(error.localizedDescription)" }
    }

    /// 当前活动 Home Assistant 设备 ID（无则回退第一台 HA 设备）
    public var activeHADeviceID: UUID? {
        if let id = settings.activeHomeAssistantDeviceID,
           settings.devices.contains(where: { $0.id == id }) { return id }
        return settings.devices.first { $0.type == .homeAssistant }?.id
    }

    /// Bambu Lab 字段实体映射绑定（按打印机设备快照；活动设备时同步全局镜像防 sync 覆盖）
    public func bambuFieldBinding(for id: UUID,
                                  _ keyPath: WritableKeyPath<DeviceSettings, String?>) -> Binding<String> {
        Binding(get: {
            guard let dev = self.settings.devices.first(where: { $0.id == id }) else { return "" }
            return dev.settings[keyPath: keyPath] ?? ""
        }, set: { v in
            // 先写全局镜像再写设备快照，防止 onChange→syncActiveDeviceSettings 用旧全局值覆盖回写
            self.syncBambuGlobalMirror(id, keyPath: keyPath, value: v)
            self.mutateDeviceSettings(id) { $0[keyPath: keyPath] = v }
            if keyPath == \.bambuImageEntityID || keyPath == \.bambuTaskImageEntityID {
                self.refreshDisplayedBambuPictureAfterSettingChange(deviceID: id)
            }
        })
    }

    /// 当前活动 Bambu Lab 打印机设备 ID（无则回退第一台已配置打印机）
    public var activeBambuLabDeviceID: UUID? {
        if let id = settings.activeBambuLabDeviceID,
           settings.devices.contains(where: { $0.id == id }) { return id }
        return settings.devices.first { $0.type == .bambuLab }?.id
    }

    /// 某台 Bambu Lab 打印机设备的卡片配置（nil = 设备不存在）
    public func bambuSettings(for deviceID: UUID) -> BambuLabCardSettings? {
        guard let dev = settings.devices.first(where: { $0.id == deviceID }) else { return nil }
        return BambuLabCardSettings.from(dev.settings)
    }

    /// 打印机名称绑定：读写设备名（重命名设备，侧栏分组/设备管理/卡片徽标同步更新；
    /// 同时镜像旧版 bambuPrinterName 字段保持兼容）
    public func bambuDeviceNameBinding(for deviceID: UUID) -> Binding<String> {
        Binding(get: {
            self.settings.devices.first(where: { $0.id == deviceID })?.name ?? ""
        }, set: { v in
            self.renameDevice(id: deviceID, to: v)
            if self.activeDeviceID(for: .bambuLab) == deviceID {
                self.settings.bambuPrinterName = v
            }
            self.mutateDeviceSettings(deviceID) { $0.bambuPrinterName = v }
        })
    }

    /// 打印机告警开关绑定（按打印机设备快照；活动设备时同步全局镜像）
    public func bambuAlertBinding(for id: UUID) -> Binding<Bool> {
        Binding(get: {
            guard let dev = self.settings.devices.first(where: { $0.id == id }) else { return true }
            return dev.settings.bambuEnableAlert ?? true
        }, set: { v in
            if self.activeDeviceID(for: .bambuLab) == id {
                self.settings.bambuEnableAlert = v
            }
            self.mutateDeviceSettings(id) { $0.bambuEnableAlert = v }
        })
    }

    /// 打印状态实体默认筛选开关（按打印机设备持久化；旧档案默认开启）。
    public func bambuDefaultEntityFilterBinding(for id: UUID) -> Binding<Bool> {
        Binding(get: {
            self.settings.devices.first(where: { $0.id == id })?
                .settings.bambuUseDefaultEntityFilter ?? true
        }, set: { value in
            self.mutateDeviceSettings(id) { $0.bambuUseDefaultEntityFilter = value }
        })
    }

    /// 卡片布局样式绑定（详情页布局选择器；按打印机设备快照）
    public func bambuLayoutBinding(for id: UUID) -> Binding<BambuCardLayout> {
        Binding(get: {
            guard let dev = self.settings.devices.first(where: { $0.id == id }) else { return .standard }
            return (dev.settings.bambuLayout ?? .standard).selectableValue
        }, set: { v in
            let v = v.selectableValue
            if self.activeDeviceID(for: .bambuLab) == id {
                self.settings.bambuLayout = v
            }
            self.mutateDeviceSettings(id) { $0.bambuLayout = v }
        })
    }

    /// 卡片主题色绑定（跟随全局 / Bambu Lab 强调色；按打印机设备快照）
    public func bambuThemeAccentBinding(for id: UUID) -> Binding<BambuThemeAccent> {
        Binding(get: {
            guard let dev = self.settings.devices.first(where: { $0.id == id }) else { return .global }
            return dev.settings.bambuThemeAccent ?? .global
        }, set: { v in
            if self.activeDeviceID(for: .bambuLab) == id {
                self.settings.bambuThemeAccent = v
            }
            self.mutateDeviceSettings(id) { $0.bambuThemeAccent = v }
        })
    }

    /// 卡片画面来源绑定。两个实体映射始终保留，只切换当前展示与抓取哪一个。
    public func bambuImageSourceBinding(for id: UUID) -> Binding<BambuImageSource> {
        Binding(get: {
            guard let dev = self.settings.devices.first(where: { $0.id == id }) else { return .camera }
            return dev.settings.bambuImageSource ?? .camera
        }, set: { source in
            if self.activeDeviceID(for: .bambuLab) == id {
                self.settings.bambuImageSource = source
            }
            self.mutateDeviceSettings(id) { $0.bambuImageSource = source }
            self.refreshDisplayedBambuPictureAfterSettingChange(deviceID: id)
        })
    }

    /// 时间区块来源绑定。剩余时间与结束时间实体都保留，只切换当前展示内容。
    public func bambuTimeDisplayModeBinding(for id: UUID) -> Binding<BambuTimeDisplayMode> {
        Binding(get: {
            self.settings.devices.first(where: { $0.id == id })?
                .settings.bambuTimeDisplayMode ?? .remaining
        }, set: { mode in
            if self.activeDeviceID(for: .bambuLab) == id {
                self.settings.bambuTimeDisplayMode = mode
            }
            self.mutateDeviceSettings(id) { $0.bambuTimeDisplayMode = mode }
            self.renderPreview()
            self.refreshDisplayedBambuPictureAfterSettingChange(deviceID: id,
                                                                 refreshPicture: false,
                                                                 refreshEntities: true)
        })
    }

    /// 摄像头自动聚焦开关（每台打印机独立，旧配置默认关闭）。切换后清空旧裁切状态；
    /// 开启时先处理已经缓存的原始帧并立即预览/推送，不等待摄像头产生下一帧。
    public func bambuAutoCameraZoomBinding(for id: UUID) -> Binding<Bool> {
        Binding(get: {
            self.settings.devices.first(where: { $0.id == id })?
                .settings.bambuAutoCameraZoom ?? false
        }, set: { enabled in
            let cameraID = self.settings.devices.first(where: { $0.id == id })?
                .settings.bambuImageEntityID ?? ""
            if self.activeDeviceID(for: .bambuLab) == id {
                self.settings.bambuAutoCameraZoom = enabled
            }
            self.mutateDeviceSettings(id) { $0.bambuAutoCameraZoom = enabled }
            self.bambuAutoZoomImages.removeValue(forKey: cameraID)
            self.bambuCameraZoomRuntime.removeValue(forKey: cameraID)
            self.renderPreview()
            self.refreshDisplayedBambuPictureAfterSettingChange(
                deviceID: id, reprocessCachedCamera: enabled)
        })
    }

    /// 当前显示的确为这台打印机时：先把来源/布局变化立即推送，再抓新静态帧补推。
    /// expectedEntityID 同时作为竞态保护，快速来回切换不会让旧请求覆盖新来源。
    private func refreshDisplayedBambuPictureAfterSettingChange(deviceID: UUID,
                                                                refreshPicture: Bool = true,
                                                                refreshEntities: Bool = false,
                                                                reprocessCachedCamera: Bool = false) {
        let expectedMode = settings.displayMode
        guard let slot = expectedMode.bambuSlotIndex else { return }
        let printers = enabledDevices(for: .bambuLab)
        guard printers.indices.contains(slot), printers[slot].id == deviceID else { return }
        let expectedConfig = BambuLabCardSettings.from(printers[slot])
        let expectedEntityID = expectedConfig.selectedImageEntityID
        let samplesInsidePush = expectedConfig.autoCameraZoom
            && expectedConfig.imageSource == .camera
        bambuPictureRefreshTask?.cancel()
        bambuPictureRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 时间来源切换时只刷新当前打印机已选实体，确保结束时间立即更新；
            // 不扫描完整 HA 实体库，也不额外抓取摄像头图片。
            if refreshEntities {
                await self.refreshCurrentBambuEntities()
            }
            guard !Task.isCancelled else { return }
            // 自动裁切开关开启时，优先对 HA 图片缓存中的上一帧做本地识别和裁切。
            // 这样预览与键盘马上产生变化，不再被低帧率摄像头或网络请求阻塞。
            let usedCachedFrame = reprocessCachedCamera
                ? await self.prepareCachedBambuCameraFrame(deviceID: deviceID,
                                                           expectedMode: expectedMode)
                : false
            if usedCachedFrame { self.renderPreview() }
            guard !Task.isCancelled else { return }
            // 即使新来源尚未取得图片，也先把选项造成的布局变化显示到键盘。
            await self.pushWhenAvailable(force: false, silentIfUnchanged: true,
                                         sampleBambuCameraBeforePush: !usedCachedFrame)
            guard !Task.isCancelled else { return }
            if refreshPicture, !samplesInsidePush,
               await self.refreshCurrentBambuPicture(expectedMode: expectedMode,
                                                     expectedEntityID: expectedEntityID) {
                await self.pushWhenAvailable(force: false, silentIfUnchanged: true)
            }
        }
    }

    /// 各区块显示开关绑定（按打印机设备快照；未设置默认开启）
    public func bambuShowBinding(for id: UUID,
                                 _ keyPath: WritableKeyPath<DeviceSettings, Bool?>) -> Binding<Bool> {
        Binding(get: {
            guard let dev = self.settings.devices.first(where: { $0.id == id }) else { return true }
            return dev.settings[keyPath: keyPath] ?? true
        }, set: { v in
            if self.activeDeviceID(for: .bambuLab) == id {
                self.syncBambuShowMirror(id, keyPath: keyPath, value: v)
            }
            self.mutateDeviceSettings(id) { $0[keyPath: keyPath] = v }
        })
    }

    /// 显示开关写回全局镜像（仅活动打印机设备）
    private func syncBambuShowMirror(_ id: UUID, keyPath: WritableKeyPath<DeviceSettings, Bool?>, value: Bool) {
        switch keyPath {
        case \.bambuShowStatus: settings.bambuShowStatus = value
        case \.bambuShowProgress: settings.bambuShowProgress = value
        case \.bambuShowTask: settings.bambuShowTask = value
        case \.bambuShowTemperature: settings.bambuShowTemperature = value
        case \.bambuShowRemaining: settings.bambuShowRemaining = value
        case \.bambuShowError: settings.bambuShowError = value
        case \.bambuShowImage: settings.bambuShowImage = value
        default: break
        }
    }

    /// 自动匹配：只从打印状态实体推导该打印机的全部实体映射（保留用户设备名）。
    public func applyBambuAutoDetect(from knownEntity: HAEntity, deviceID: UUID,
                                     entities: [HAEntity], useDefaultFilter: Bool = true) {
        var detected = BambuEntityMatcher.detect(from: knownEntity, allEntities: entities,
                                                 allowUnfilteredSeed: !useDefaultFilter)
        guard detected.statusEntityID == knownEntity.entityId else { return }
        if let dev = settings.devices.first(where: { $0.id == deviceID }) {
            let deviceName = dev.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !deviceName.isEmpty {
                detected.name = deviceName
            }
        }
        writeBambuDetected(detected, deviceID: deviceID)
    }

    /// 重新匹配：必须先配置有效的打印状态实体，不再从全量任意实体猜测打印机归属。
    public func applyBambuAutoDetect(deviceID: UUID, entities: [HAEntity],
                                     useDefaultFilter: Bool = true) {
        guard let dev = settings.devices.first(where: { $0.id == deviceID }),
              let seedID = dev.settings.bambuStatusEntityID, !seedID.isEmpty,
              let seed = entities.first(where: { $0.entityId == seedID }) else { return }
        var detected = BambuEntityMatcher.detect(from: seed, allEntities: entities,
                                                 allowUnfilteredSeed: !useDefaultFilter)
        guard detected.statusEntityID == seed.entityId else { return }
        if let dev = settings.devices.first(where: { $0.id == deviceID }) {
            let deviceName = dev.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !deviceName.isEmpty {
                detected.name = deviceName
            }
        }
        writeBambuDetected(detected, deviceID: deviceID)
    }

    /// 经统一通道写入打印机设备的字段（先全局镜像、再设备快照，防 sync 覆盖回退）
    private func writeBambuDetected(_ detected: BambuLabCardSettings, deviceID: UUID) {
        var detected = detected
        // 自动匹配只负责实体映射，不重置用户在卡片页选好的布局、颜色、图片区块及画面来源。
        if let current = bambuSettings(for: deviceID) {
            detected.enableAlert = current.enableAlert
            detected.layout = current.layout
            detected.themeAccent = current.themeAccent
            detected.showStatus = current.showStatus
            detected.showProgress = current.showProgress
            detected.showTask = current.showTask
            detected.showTemperature = current.showTemperature
            detected.showRemaining = current.showRemaining
            detected.showError = current.showError
            detected.showImage = current.showImage
            detected.imageSource = current.imageSource
            detected.autoCameraZoom = current.autoCameraZoom
            detected.timeDisplayMode = current.timeDisplayMode
        }
        if activeDeviceID(for: .bambuLab) == deviceID {
            syncBambuLegacyMirror(detected)
        }
        mutateDeviceSettings(deviceID) { detected.apply(to: &$0) }
    }

    /// 同步到全局旧版单台字段（兼容 capture/apply 与活动设备快照重建）
    private func syncBambuLegacyMirror(_ p: BambuLabCardSettings) {
        settings.bambuPrinterName = p.name
        settings.bambuEnableAlert = p.enableAlert
        settings.bambuStatusEntityID = p.statusEntityID
        settings.bambuProgressEntityID = p.progressEntityID
        settings.bambuTaskEntityID = p.taskEntityID
        settings.bambuNozzleTempEntityID = p.nozzleTempEntityID
        settings.bambuBedTempEntityID = p.bedTempEntityID
        settings.bambuRemainingEntityID = p.remainingEntityID
        settings.bambuEndTimeEntityID = p.endTimeEntityID
        settings.bambuTimeDisplayMode = p.timeDisplayMode
        settings.bambuErrorEntityID = p.errorEntityID
        settings.bambuImageEntityID = p.imageEntityID
        settings.bambuTaskImageEntityID = p.taskImageEntityID
        settings.bambuImageSource = p.imageSource
        settings.bambuAutoCameraZoom = p.autoCameraZoom
        settings.bambuLayout = p.layout
        settings.bambuThemeAccent = p.themeAccent
        settings.bambuShowStatus = p.showStatus
        settings.bambuShowProgress = p.showProgress
        settings.bambuShowTask = p.showTask
        settings.bambuShowTemperature = p.showTemperature
        settings.bambuShowRemaining = p.showRemaining
        settings.bambuShowError = p.showError
        settings.bambuShowImage = p.showImage
    }

    /// 某台打印机的型号（从其状态实体识别；未识别返回 nil）
    public func bambuModel(for deviceID: UUID) -> String? {
        guard let dev = settings.devices.first(where: { $0.id == deviceID }),
              let statusID = dev.settings.bambuStatusEntityID, !statusID.isEmpty,
              let e = haSnapshot.entities.first(where: { $0.entityId == statusID }) else { return nil }
        return BambuModelDetector.model(of: e)
    }

    /// Bambu 卡片位绑定的打印机名（卡片↔设备绑定：卡片名显示所绑定设备的名称；
    /// 非 Bambu 面板或无对应设备返回 nil）
    func bambuCardTitle(for panel: Panel) -> String? {
        let type: DeviceType
        let slot: Int
        if let value = panel.bambuSlotIndex { type = .bambuLab; slot = value }
        else if let value = panel.formlabsSlotIndex { type = .formlabs; slot = value }
        else { return nil }
        let printers = enabledDevices(for: type)
        guard printers.indices.contains(slot) else { return nil }
        let name = printers[slot].name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? panel.title : name
    }

    /// 画板模块显示名：打印机模块显示所绑定设备名（与独立卡片一致）。
    func canvasModuleTitle(_ module: CanvasModule) -> String {
        let type: DeviceType
        let slot: Int
        if let value = module.bambuSlotIndex { type = .bambuLab; slot = value }
        else if let value = module.formlabsSlotIndex { type = .formlabs; slot = value }
        else { return module.title }
        let printers = enabledDevices(for: type)
        guard printers.indices.contains(slot) else { return module.title }
        let name = printers[slot].name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? module.title : name
    }

    func formlabsDevice(for module: CanvasModule) -> ManagedDevice? {
        guard let slot = module.formlabsSlotIndex else { return nil }
        let printers = enabledDevices(for: .formlabs)
        return printers.indices.contains(slot) ? printers[slot] : nil
    }

    func formlabsCanvasItems() -> [FormlabsCanvasItem] {
        enabledDevices(for: .formlabs).map { device in
            FormlabsCanvasItem(
                deviceName: device.name,
                connection: device.settings.formlabsConnection ?? FormlabsConnectionSettings(),
                snapshot: formlabsSnapshots[device.id] ?? .empty)
        }
    }

    /// 菜单栏用的显示模式标题：Bambu 卡片位显示所绑定打印机的设备名
    public func menuTitle(for mode: DisplayMode) -> String {
        let type: DeviceType
        let slot: Int
        if let value = mode.bambuSlotIndex { type = .bambuLab; slot = value }
        else if let value = mode.formlabsSlotIndex { type = .formlabs; slot = value }
        else { return mode.title }
        let printers = enabledDevices(for: type)
        guard printers.indices.contains(slot) else { return mode.title }
        let name = printers[slot].name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? mode.title : name
    }

    /// Bambu 卡片位绑定的打印机设备（用于详情页；非 Bambu 面板返回 nil）
    func bambuDevice(for panel: Panel) -> ManagedDevice? {
        guard let slot = panel.bambuSlotIndex else { return nil }
        let printers = enabledDevices(for: .bambuLab)
        return printers.indices.contains(slot) ? printers[slot] : nil
    }

    /// Bambu 字段全局镜像同步（该设备为活动 Bambu 打印机或活动 HA 设备时写全局；sync 重建快照以全局为准）
    private func syncBambuGlobalMirror(_ id: UUID, keyPath: WritableKeyPath<DeviceSettings, String?>, value: String) {
        guard activeDeviceID(for: .bambuLab) == id || activeDeviceID(for: .homeAssistant) == id else { return }
        switch keyPath {
        case \.bambuStatusEntityID: settings.bambuStatusEntityID = value
        case \.bambuProgressEntityID: settings.bambuProgressEntityID = value
        case \.bambuTaskEntityID: settings.bambuTaskEntityID = value
        case \.bambuNozzleTempEntityID: settings.bambuNozzleTempEntityID = value
        case \.bambuBedTempEntityID: settings.bambuBedTempEntityID = value
        case \.bambuRemainingEntityID: settings.bambuRemainingEntityID = value
        case \.bambuEndTimeEntityID: settings.bambuEndTimeEntityID = value
        case \.bambuErrorEntityID: settings.bambuErrorEntityID = value
        case \.bambuImageEntityID: settings.bambuImageEntityID = value
        case \.bambuTaskImageEntityID: settings.bambuTaskImageEntityID = value
        default: break
        }
    }

    /// 修改设备快照（复制-修改-赋回，触发 @Published 让 UI 刷新；
    /// @Published 对数组元素的嵌套修改不自动触发，必须整体赋回）
    private func mutateDeviceSettings(_ id: UUID, _ mutate: (inout DeviceSettings) -> Void) {
        guard let idx = settings.devices.firstIndex(where: { $0.id == id }) else { return }
        var devices = settings.devices
        mutate(&devices[idx].settings)
        settings.devices = devices
    }

    /// Home Assistant 连接测试（全局共享服务器配置；返回用户可读结果，不打印令牌）
    public func testHAConnection() async -> String {
        if let problem = HomeAssistantClient.validate(serverURL: settings.haServerURL,
                                                      token: settings.haToken) {
            return problem
        }
        do {
            let entities = try await HomeAssistantClient.fetchStates(serverURL: settings.haServerURL,
                                                                     token: settings.haToken)
            applyHASnapshot(entities: entities, errorText: nil)
            lastHARefresh = Date()
            return "连接成功：读到 \(entities.count) 个实体"
        } catch let error as HAError {
            return error.errorDescription ?? "连接失败"
        } catch {
            return "连接失败：\(error.localizedDescription)"
        }
    }

    /// Home Assistant 静态画面支持：只按 HA 卡片所选实体及已启用打印机的
    /// image.*/camera.* 映射抓取当前帧，不建立视频流。
    static let haPictureSupportEnabled = true
    /// 失效绑定提示开关：当前部署基线关闭
    static let haStaleHintsEnabled = false
    /// 卡片实体列表是否按键盘独立记录：当前部署基线关闭（全局一份）
    static let haCardPerKeyboardEnabled = false

    /// 全局服务器当前是否有可用实体池（设备管理页的连接指示灯用）
    public var haConnectedNow: Bool {
        !settings.haServerURL.isEmpty && !haSnapshot.entities.isEmpty && haSnapshot.errorText == nil
    }

    /// 是否已添加 Home Assistant 服务器（填过地址或令牌即算已添加）
    public var haServerConfigured: Bool {
        !settings.haServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !settings.haToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 移除 Home Assistant 服务器：清空全局地址与令牌、丢弃实体池与画面；
    /// 各键盘的卡片实体选择保留（重新添加服务器后即恢复显示）
    public func clearHAServer() {
        settings.haServerURL = ""
        settings.haToken = ""
        haSnapshot = .empty
        lastHARefresh = nil
        clearHAAlert(cooldown: false)
        persistSettings()
        renderPreview()
        refreshOracleCanvasPreview()
        refreshExcerptCanvasPreview()
        status = "已移除 Home Assistant 服务器"
    }

    /// 各键盘 Home Assistant 卡片当前显示的实体数量摘要（卡片内容按键盘独立）
    public func haCardEntityCountSummary() -> String {
        let keyboards = enabledDevices(for: .keyboard)
        guard !keyboards.isEmpty else { return "尚未添加键盘设备" }
        let parts = keyboards.map { device in
            "\(device.name) \(device.settings.haCardEntityIDs?.count ?? 0) 个"
        }
        return "各键盘卡片：" + parts.joined(separator: " · ")
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
    /// 系统分隔条拖拽的防抖提交任务（最后一次宽度变化后 0.35s 统一持久化）
    private var sidebarResizeDebounce: DispatchWorkItem?

    /// 拖拽开始：进入批处理模式
    public func beginSidebarResize() {
        sidebarResizing = true
    }

    /// NavigationSplitView 原生分隔条拖拽：进入批处理模式并安排防抖提交
    /// （原生分隔条没有拖拽开始/结束回调，用防抖代替松手时机）
    public func noteSidebarResize() {
        sidebarResizing = true
        sidebarResizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishSidebarResize() }
        }
        sidebarResizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// 拖拽中更新宽度（仅更新布局，不持久化/不重渲染预览）
    public func setSidebarWidth(_ width: Int) {
        settings.sidebarWidth = min(max(width, 48), 320)
    }

    /// 拖拽结束：一次性持久化并刷新预览
    public func finishSidebarResize() {
        sidebarResizing = false
        sidebarResizeDebounce = nil
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
        rand0Session?.disconnect()
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
        // Home Assistant 定时刷新（按设置间隔节流；未配置服务器地址时自动跳过）
        if haRefreshDue(now: now) {
            await refreshHA()
        }
        // 任一画板引用 Formlabs 模块时也保持对应云端设备缓存新鲜；只刷新实际使用的
        // 卡片位，仍沿用每台设备至少 30 秒的限流策略。
        await refreshCanvasFormlabsIfDue(now: now)
        // 夸夸展示到期：恢复正常卡片并推送
        if let until = praiseUntil, now >= until {
            praiseText = nil
            praiseUntil = nil
            renderPreview()
            await push(force: true)
        }
        // 打印完成庆祝到期：恢复正常卡片并推送
        if let until = printSuccessUntil, now >= until {
            printSuccessName = nil
            printSuccessTask = nil
            printSuccessImage = nil
            printSuccessUntil = nil
            renderPreview()
            await push(force: true)
        }
        // 设备报错占屏到期（最多 1 分钟）：立即清除并进入冷却，恢复常规卡片推送
        if !haAlertTitle.isEmpty, let setAt = haAlertSetAt,
           now.timeIntervalSince(setAt) > haAlertMaxSeconds {
            clearHAAlert(cooldown: true)
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
                renderPreviewIfDue(now: now)
            }
        case .systemMonitor:
            system = monitor.sample(now: now)
            await refreshPreviewOrPush(now: now)
        case .pomodoro:
            let snapshot = pomodoroSnapshot
            if snapshot.isRunning {
                let alignedSeconds = PomodoroRefreshPolicy.alignedRemainingSeconds(
                    snapshot.remaining, duration: snapshot.duration,
                    intervalSeconds: settings.pomodoroUploadSeconds)
                if alignedSeconds != lastPomodoroPushAlignedSeconds {
                    await push(force: false)
                } else {
                    renderPreviewIfDue(now: now)
                }
            } else {
                renderPreviewIfDue(now: now)
            }
        case .nowPlaying:
            await refreshNowPlaying(now: now)
            await refreshPreviewOrPush(now: now)
        case .canvas:
            if RuntimePerformancePolicy.needsSystemSample(modules: settings.canvasModuleList) {
                system = monitor.sample(now: now)
            }
            // 画板含 Codex/千问额度模块时，按统一用量刷新周期先调取再渲染
            if canvasNeedsQuotaData, isQuotaDataStale(now: now) {
                let failures = await refreshUsageAndQuota()
                if !failures.isEmpty { status = failures.joined(separator: "；") }
            }
            await refreshPreviewOrPush(now: now)
        case .excerptQuote:
            // 语录变化（手动切换或分钟轮换）时才推送到键盘
            let quote = quoteDisplayText
            if lastQuotePushText != quote {
                lastQuotePushText = quote
                await push(force: false)
            } else {
                renderPreviewIfDue(now: now)
            }
        case .sspai:
            // 到刷新周期则重新抓取少数派推荐
            if lastSspaiFetch == nil
                || now.timeIntervalSince(lastSspaiFetch!) >= TimeInterval(max(5, settings.sspaiRefreshMinutes) * 60) {
                let changed = await fetchSspai()
                if changed {
                    await push(force: false)
                } else {
                    renderPreviewIfDue(now: now)
                }
            } else {
                renderPreviewIfDue(now: now)
            }
        case .customImage:
            let imageContentChanged = refreshCustomImageRevisionIfNeeded()
            if imageContentChanged {
                // 与 WallpaperColorsChanged 相同的语义：当前壁纸内容变化后立刻重新
                // 裁剪、提取种子色、生成 Accent 色调板并推送，不等下一分钟。
                lastClockMinute = nil
                renderPreview()
                await push(force: true)
            }
            if settings.imageRotationEnabled {
                await maybeRotateImage(now: now)
            }
            if settings.customImageClock != .none, !imageContentChanged {
                await maybePushClockOverlay(now: now)
            }
        case .emojiWallpaper:
            // 壁纸内容确定性强（由设置决定），仅在内容变化（设置改动触发渲染）时推送
            await refreshPreviewOrPush(now: now)
        case .homeAssistant, .bambuLab, .bambuLab2, .bambuLab3, .bambuLab4, .bambuLab5:
            await refreshPreviewOrPush(now: now)
        case .formlabs, .formlabs2, .formlabs3, .formlabs4, .formlabs5:
            if let device = formlabsDevice(for: settings.displayMode),
               formLabsRefreshDue(deviceID: device.id, now: now) {
                await refreshFormlabs(deviceID: device.id, pushIfVisible: true)
            } else {
                await refreshPreviewOrPush(now: now)
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
        // 240×240 小屏幕共用本应用每秒时钟；每台设备仍按自己的最短间隔与内容指纹推送。
        await maybeAutoPushAIMacScreens(now: now)
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
        if let id = activeDeviceID(for: .aiMacScreen) {
            let mode = aiMacScreenSettings(for: id).mode
            if mode == .canvas || mode == .card || mode == .clock || mode == .dashboard {
                refreshAIMacScreenPreview(deviceID: id)
            }
        }
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
        lastCustomImageRevision = currentCustomImageRevision()
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
        let includesSeconds = settings.timeFormat.contains("s")
        let current = includesSeconds ? minuteOfDay * 60 + second : minuteOfDay
        guard current != lastClockMinute else { return }
        lastClockMinute = current
        renderPreview()
        await push(force: false)
    }

    /// 路径 + 大小 + 纳秒级修改时间组成轻量修订指纹。只在“自定义图片”卡片处于
    /// 当前显示模式时每秒检查一次，不解码图片；真正发生变化后才重新渲染和取色。
    private func currentCustomImageRevision() -> String? {
        guard let path = settings.customImagePath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey
        ]) else { return nil }
        let size = values.fileSize ?? 0
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(path)|\(size)|\(modified)"
    }

    private func refreshCustomImageRevisionIfNeeded() -> Bool {
        let revision = currentCustomImageRevision()
        defer { lastCustomImageRevision = revision }
        guard let previous = lastCustomImageRevision else { return false }
        return revision != previous
    }

    /// 切换自定义图片的时钟叠加布局（重置时钟，下一个 tick 立即重推）
    public func setCustomImageClock(_ overlay: CustomImageClockOverlay) {
        settings.customImageClock = overlay.stackedOnly
        lastClockMinute = nil
        persistSettings()
    }

    /// 自定义时钟时间格式（重置时钟，下一个 tick 立即重推）
    /// 设置页实时预览用的当前时间 / 日期文本
    public var previewTimeString: String { TimeFormatProbe.format(settings.timeFormat, now: Date()) }
    public var previewDateString: String { TimeFormatProbe.format(settings.dateFormat, now: Date()) }

public func setClockTimeFormat(_ format: String) {
        let trimmed = format.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.timeFormat = trimmed.isEmpty ? "HH:mm" : trimmed
        lastClockMinute = nil
        persistSettings()
    }

    /// 设置全局日期格式（软件内所有日期显示统一生效）
    public func setDateFormat(_ format: String) {
        let trimmed = format.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.dateFormat = trimmed.isEmpty ? "yyyy年M月d日 EEE" : trimmed
        persistSettings()
    }

    /// 恢复时钟叠加默认样式：自然取色、显示日期、100% 整体大小、HH:mm、无偏移；
    /// 叠加开关与布局（顶部/底部/左/中）保持不变
    public func resetClockOverlay() {
        settings.clockFont = .helveticaNeue
        settings.wallpaperColorStyle = .natural
        settings.clockDateVisible = true
        settings.clockFontSize = StackedClockSizing.defaultValue
        settings.clockFontWeight = .medium
        settings.timeFormat = "HH:mm"
        settings.clockOffsetX = 0
        settings.clockOffsetY = 0
        lastClockMinute = nil
        persistSettings()
        renderPreview()
    }

    // MARK: - 画板编辑

    /// 各画板图像模块自己的图片路径（键盘用自定义图片；先知/摘录各自独立）
    public func canvasImagePath(for owner: CanvasOwner) -> String? {
        switch owner {
        case .keyboard: return settings.customImagePath
        case .oracle: return settings.oracleCanvasImagePath
        case .excerpt: return settings.excerptCanvasImagePath
        case .aiMac:
            guard let id = activeDeviceID(for: .aiMacScreen) else { return nil }
            let config = aiMacScreenSettings(for: id)
            guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return nil }
            return config.canvasBoards[config.canvasBoardIndex].imagePath
        }
    }

    /// 各画板图像模块当前图片名
    public func canvasImageName(for owner: CanvasOwner) -> String? {
        switch owner {
        case .keyboard: return settings.customImageName
        case .oracle: return settings.oracleCanvasImageName
        case .excerpt: return settings.excerptCanvasImageName
        case .aiMac:
            guard let id = activeDeviceID(for: .aiMacScreen) else { return nil }
            let config = aiMacScreenSettings(for: id)
            guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return nil }
            return config.canvasBoards[config.canvasBoardIndex].imageName
        }
    }

    /// 为指定画板选择/替换图像模块的图片：按该画板屏幕比例裁切后保存（键盘/先知/摘录各自独立）
    public func pickCanvasImage(for owner: CanvasOwner) async {
        let panel = NSOpenPanel()
        panel.title = "选择画板图片（按屏幕比例裁切）"
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url) else {
            status = "无法读取所选图片"
            return
        }
        if owner == .keyboard {
            showCropEditor(image: image, sourceURL: url)
        } else if owner == .oracle || owner == .aiMac {
            showCropEditor(image: image, sourceURL: url,
                           cropRatio: 1.0, owner: owner) // 先知与 AI Mac 均为方形
        } else {
            showCropEditor(image: image, sourceURL: url,
                           cropRatio: 296.0 / 152.0, owner: .excerpt) // 摘录 296×152
        }
    }

    /// 设置指定画板图像模块的图片（先知/摘录各自独立存储）
    public func setCanvasImage(url: URL, displayName: String?, owner: CanvasOwner) async {
        guard owner != .keyboard else {
            await setCustomImage(url: url, displayName: displayName)
            return
        }
        do {
            let destination = try store.saveHistoryImage(from: url)
            let name = displayName ?? url.lastPathComponent
            switch owner {
            case .keyboard: break
            case .oracle:
                settings.oracleCanvasImagePath = destination.path
                settings.oracleCanvasImageName = name
            case .excerpt:
                settings.excerptCanvasImagePath = destination.path
                settings.excerptCanvasImageName = name
            case .aiMac:
                mutateCurrentAIMacCanvasBoard { board in
                    board.imagePath = destination.path
                    board.imageName = name
                }
            }
            persistSettings()
            refreshDevicePreview(for: owner)
            let label = owner == .oracle ? "先知" : owner == .excerpt ? "摘录" : "AI Mac"
            status = "已更新\(label)画板图片"
        } catch {
            status = Self.friendly(error)
        }
    }

    /// 添加一个画板模块（已存在则忽略）
    public func addCanvasModule(_ module: CanvasModule, to owner: CanvasOwner = .keyboard) {
        let currentModules = canvasModulesRaw(for: owner)
        guard !currentModules.contains(module.rawValue) else { return }
        assignFirstModuleNameIfNeeded(module, owner: owner, currentModules: currentModules)
        setCanvasModulesRaw(currentModules + [module.rawValue], for: owner)
        persistSettings()
        refreshDevicePreview(for: owner)
    }

    /// 空白“未命名”画板第一次添加模块时，以该模块在界面上的实际名称自动命名。
    /// 键盘灵犀画板目前是固定单画板、没有独立名称，因此只处理两类可新建的设备画板。
    private func assignFirstModuleNameIfNeeded(_ module: CanvasModule,
                                               owner: CanvasOwner,
                                               currentModules: [Int]) {
        guard currentModules.isEmpty else { return }
        let moduleName = canvasModuleTitle(module)
        switch owner {
        case .keyboard:
            return
        case .oracle:
            let index = settings.oracleCanvasBoardIndex
            guard settings.oracleCanvasBoards.indices.contains(index) else { return }
            let oldName = settings.oracleCanvasBoards[index].name
            let newName = CanvasBoardNamingPolicy.nameAfterAddingFirstModule(
                currentName: oldName, currentModules: currentModules, moduleTitle: moduleName)
            guard newName != oldName else { return }
            settings.deviceSyncInFlight = true
            settings.oracleCanvasBoards[index].name = newName
            captureActiveDeviceSnapshot(of: .oracle)
            settings.deviceSyncInFlight = false
        case .excerpt:
            let index = settings.excerptCanvasBoardIndex
            guard settings.excerptCanvasBoards.indices.contains(index) else { return }
            let oldName = settings.excerptCanvasBoards[index].name
            let newName = CanvasBoardNamingPolicy.nameAfterAddingFirstModule(
                currentName: oldName, currentModules: currentModules, moduleTitle: moduleName)
            guard newName != oldName else { return }
            settings.deviceSyncInFlight = true
            settings.excerptCanvasBoards[index].name = newName
            captureActiveDeviceSnapshot(of: .excerpt)
            settings.deviceSyncInFlight = false
        case .aiMac:
            mutateCurrentAIMacCanvasBoard(pushImmediately: false) { board in
                board.name = CanvasBoardNamingPolicy.nameAfterAddingFirstModule(
                    currentName: board.name, currentModules: currentModules,
                    moduleTitle: moduleName)
            }
        }
    }

    /// 移除一个画板模块
    public func removeCanvasModule(_ module: CanvasModule, from owner: CanvasOwner = .keyboard) {
        setCanvasModulesRaw(canvasModulesRaw(for: owner).filter { $0 != module.rawValue }, for: owner)
        persistSettings()
        refreshDevicePreview(for: owner)
    }

    /// 上移 / 下移一个画板模块
    public func moveCanvasModule(_ module: CanvasModule, up: Bool, owner: CanvasOwner = .keyboard) {
        var list = canvasModulesRaw(for: owner)
        guard let index = list.firstIndex(of: module.rawValue) else { return }
        let target = up ? index - 1 : index + 1
        guard target >= 0, target < list.count else { return }
        list.swapAt(index, target)
        setCanvasModulesRaw(list, for: owner)
        persistSettings()
        refreshDevicePreview(for: owner)
    }

    /// 拖拽排序：把 module 移到 target 之前（after=false）或之后（after=true）
    public func moveCanvasModule(_ module: CanvasModule, before target: CanvasModule,
                                 after: Bool = false, owner: CanvasOwner = .keyboard) {
        guard module != target else { return }
        var list = canvasModulesRaw(for: owner)
        list.removeAll { $0 == module.rawValue }
        if let index = list.firstIndex(of: target.rawValue) {
            list.insert(module.rawValue, at: after ? index + 1 : index)
        } else {
            list.append(module.rawValue)
        }
        setCanvasModulesRaw(list, for: owner)
        persistSettings()
        refreshDevicePreview(for: owner)
    }

    /// 拖拽排序完成：一次性提交最终模块顺序并刷新预览（拖动中只改本地列表，避免卡顿）
    public func commitCanvasModules(_ modules: [CanvasModule], owner: CanvasOwner) {
        setCanvasModulesRaw(modules.map(\.rawValue), for: owner)
        persistSettings()
        refreshDevicePreview(for: owner)
    }

    /// 独立画板模块编辑后立即刷新其预览（键盘画板预览走 renderPreview 流程）
    private func refreshDevicePreview(for owner: CanvasOwner) {
        switch owner {
        case .keyboard: break
        case .oracle: refreshOracleCanvasPreview()
        case .excerpt: refreshExcerptCanvasPreview()
        case .aiMac:
            if let id = activeDeviceID(for: .aiMacScreen) {
                refreshAIMacScreenPreview(deviceID: id)
            }
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
        // 播放中保持 6 秒校准；无媒体/暂停时退避到 30 秒，避免空闲状态频繁启动
        // Swift MediaRemote 探测子进程而拖慢整个系统。检测到播放后自动恢复高频校准。
        let fetchInterval: TimeInterval = nowPlaying.isPlaying ? 6 : 30
        if let last = lastNowPlayingFetch, now.timeIntervalSince(last) < fetchInterval {
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
        // 封面变化时立即刷新所有设备画板预览。AI Mac 保留完整彩色主色，
        // 下一次自动推送会按设备自己的间隔与内容指纹发送新画面。
        if lastSidebarArtworkData != nowPlaying.artwork {
            lastSidebarArtworkData = nowPlaying.artwork
            refreshOracleCanvasPreview()
            refreshExcerptCanvasPreview()
            for device in enabledDevices(for: .aiMacScreen) {
                let config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
                if config.mode == .card && config.cardMode == .nowPlaying {
                    refreshAIMacScreenPreview(deviceID: device.id)
                    continue
                }
                guard config.mode == .canvas,
                      config.canvasBoards.indices.contains(config.canvasBoardIndex),
                      config.canvasBoards[config.canvasBoardIndex].moduleList.contains(.nowPlaying)
                else { continue }
                refreshAIMacScreenPreview(deviceID: device.id)
            }
        }
    }


    private func shouldPushDynamically(now: Date) -> Bool {
        guard let lastPushAttempt else { return true }
        return now.timeIntervalSince(lastPushAttempt) >= TimeInterval(settings.dynamicUploadSeconds)
    }

    /// 到推送周期时只渲染一次：同一份结果同时更新软件预览并用于上传；
    /// 非推送秒则按内容实际变化速度刷新预览，避免主线程每秒无条件重绘。
    private func refreshPreviewOrPush(now: Date) async {
        if shouldPushDynamically(now: now) {
            await push(force: false)
        } else {
            renderPreviewIfDue(now: now)
        }
    }

    // MARK: - 模式激活

    private func activateMode() async {
        renderPreview()
        // 普通 HA 卡需要完整实体列表；Bambu 卡只并发刷新当前打印机已映射的实体，
        // 避免大型 HA 实例每次切卡都下载并解析整个 /api/states。
        if settings.displayMode == .homeAssistant {
            await refreshHA(includePictures: false)
        } else if settings.displayMode.bambuSlotIndex != nil {
            await refreshCurrentBambuEntities()
        }
        switch settings.displayMode {
        case .codex, .qwenWork:
            await refreshData(upload: true, forceUpload: false)
        case .systemMonitor:
            _ = monitor.sample(now: Date())
            try? await Task.sleep(nanoseconds: 150_000_000)
            system = monitor.sample(now: Date())
            await push(force: true)
        case .pomodoro:
            await push(force: true)
        case .excerptQuote:
            await push(force: true)
        case .sspai:
            _ = await fetchSspai()
            await push(force: true)
        case .nowPlaying:
            await refreshNowPlaying(now: Date())
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
        case .homeAssistant:
            await push(force: true)
            // 与 Bambu 卡一致：先显示状态，再抓 camera/image 静态帧并补推。
            let expectedPictureIDs = haCardPictureEntityIDs()
            if await refreshCurrentHAPictures(expectedEntityIDs: expectedPictureIDs) {
                await pushWhenAvailable(force: false, silentIfUnchanged: true)
            }
        case .bambuLab, .bambuLab2, .bambuLab3, .bambuLab4, .bambuLab5:
            await push(force: true)
            let mode = settings.displayMode
            let config = bambuConfig(for: mode)
            // 自动聚焦已在上面的 push 内完成“抓帧 → 分析 → 裁切 → 推送”，不再重复请求。
            // 未开启时保持原来的两阶段体验：状态先出现，静态帧随后补推。
            if !(config.autoCameraZoom && config.imageSource == .camera),
               await refreshCurrentBambuPicture(expectedMode: mode) {
                await pushWhenAvailable(force: false, silentIfUnchanged: true)
            }
        case .formlabs, .formlabs2, .formlabs3, .formlabs4, .formlabs5:
            if let device = formlabsDevice(for: settings.displayMode) {
                // 切入卡片立即刷新一次；先保留旧缓存预览，网络返回后再按 hash 推送。
                await refreshFormlabs(deviceID: device.id, force: true, pushIfVisible: true)
            } else {
                await push(force: true)
            }
        }
    }

    // MARK: - 数据刷新（Codex 用量 / 千问办公额度：统一调取，一次拉两个源供各功能共享）

    private var allAIMacCanvasModules: [CanvasModule] {
        enabledDevices(for: .aiMacScreen).flatMap { device in
            (device.settings.aiMacScreen ?? AIMacScreenDeviceSettings())
                .canvasBoards.flatMap(\.moduleList)
        }
    }

    private var activeAIMacCardModes: [DisplayMode] {
        enabledDevices(for: .aiMacScreen).compactMap { device in
            let config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
            return config.mode == .card ? config.cardMode : nil
        }
    }

    /// 任一画板（键盘/先知/摘录/AI Mac）模块组合里含 Codex 或千问额度模块
    private var canvasNeedsQuotaData: Bool {
        let lists = [settings.canvasModuleList,
                     settings.oracleCanvasModuleList,
                     settings.excerptCanvasModuleList,
                     allAIMacCanvasModules]
        return lists.contains { list in
            list.contains { $0 == .codex || $0 == .qwenQuota }
        } || activeAIMacCardModes.contains { mode in
            CardCapabilityRegistry.capability(for: mode)?.requirements.contains(.quotas) ?? false
        }
    }

    /// 设备画板（口袋先知/摘录）含「正在播放」模块且开启自动推送：
    /// 需要高频刷新播放状态，实时捕获专辑封面变化
    private var deviceCanvasNeedsLiveNowPlaying: Bool {
        (settings.oracleAutoPushEnabled && settings.oracleCanvasModuleList.contains(.nowPlaying))
            || (settings.excerptAutoPushEnabled && settings.excerptCanvasModuleList.contains(.nowPlaying))
            || enabledDevices(for: .aiMacScreen).contains { device in
                let config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
                if config.autoPush, config.mode == .card {
                    return CardCapabilityRegistry.capability(for: config.cardMode)?
                        .requirements.contains(.nowPlaying) ?? false
                }
                guard config.autoPush, config.mode == .canvas,
                      config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return false }
                return config.canvasBoards[config.canvasBoardIndex].moduleList.contains(.nowPlaying)
            }
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
        let requestedCodexSource = settings.codexUsageSource
        let outcome = await usageAggregator.fetch(codexCliPath: settings.codexCliPath)
        // 来源切换发生在网络请求途中时，丢弃旧来源刚返回的结果。
        if let usage = outcome.usage, settings.codexUsageSource == requestedCodexSource {
            self.usage = usage
        }
        if let quota = outcome.quota {
            // 千问额度百分比：以基线为 100%，按 当前/基线 算剩余百分比。
            // 基线每日自动采样（跨天后重新采样），同一日内额度回升超过基线（如每日赠送积分入账）
            // 时自动把基线拉高到当前额度；未取得额度数据时基线保持 nil，卡片显示「剩余 —%」
            var updated = quota
            applyQuotaBaselineSampling(remaining: quota.remainingCredits, now: Date())
            updated.trackedProgress = QwenWorkQuota.trackedQuotaProgress(
                current: quota.remainingCredits, baseline: settings.qwenQuotaBaseline)
            qwenQuota = updated
        }
        return outcome.failures
    }

    /// 切换 Codex 额度来源后立即丢弃旧来源快照并重新读取，避免界面在一个刷新周期内
    /// 继续显示上一来源的数据。刷新完成后按内容指纹推送当前可见卡片。
    public func setCodexUsageSource(_ source: CodexUsageSource) {
        guard settings.codexUsageSource != source else { return }
        settings.codexUsageSource = source
        usage = .empty
        lastQuotaRefresh = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 若上一轮定时刷新恰好仍在进行，等其收尾后立即拉取新来源；旧结果会被
            // refreshUsageAndQuota 内的来源校验丢弃，不会闪回到卡片上。
            while self.quotaRefreshing, self.settings.codexUsageSource == source {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard self.settings.codexUsageSource == source else { return }
            let failures = await self.refreshUsageAndQuota()
            self.renderPreview()
            self.status = failures.isEmpty ? "Codex 额度来源已切换" : failures.joined(separator: "；")
            await self.pushWhenAvailable(force: false, silentIfUnchanged: true)
            for device in self.enabledDevices(for: .aiMacScreen) {
                let config = self.aiMacScreenSettings(for: device.id)
                if config.autoPush {
                    await self.pushAIMacScreen(deviceID: device.id, force: false)
                }
            }
        }
    }

    // MARK: - Formlabs

    func formlabsDevice(for mode: DisplayMode) -> ManagedDevice? {
        guard let slot = mode.formlabsSlotIndex else { return nil }
        let printers = enabledDevices(for: .formlabs)
        return printers.indices.contains(slot) ? printers[slot] : nil
    }

    func formlabsDevice(for panel: Panel) -> ManagedDevice? {
        guard let slot = panel.formlabsSlotIndex else { return nil }
        let printers = enabledDevices(for: .formlabs)
        return printers.indices.contains(slot) ? printers[slot] : nil
    }

    private func formLabsRefreshDue(deviceID: UUID, now: Date) -> Bool {
        guard !formlabsRefreshing.contains(deviceID) else { return false }
        guard let last = lastFormlabsRefresh[deviceID] else { return true }
        return now.timeIntervalSince(last) >= 30
    }

    private func refreshCanvasFormlabsIfDue(now: Date) async {
        let modules = settings.canvasModuleList
            + settings.oracleCanvasModuleList
            + settings.excerptCanvasModuleList
            + allAIMacCanvasModules
        let cardSlots = activeAIMacCardModes.compactMap(\.formlabsSlotIndex)
        let slots = Set(modules.compactMap(\.formlabsSlotIndex) + cardSlots).sorted()
        guard !slots.isEmpty else { return }
        let printers = enabledDevices(for: .formlabs)
        var refreshed = false
        for slot in slots where printers.indices.contains(slot) {
            let id = printers[slot].id
            guard formLabsRefreshDue(deviceID: id, now: now) else { continue }
            await refreshFormlabs(deviceID: id)
            refreshed = true
        }
        guard refreshed else { return }
        if settings.displayMode == .canvas { renderPreview() }
        if settings.oracleCanvasModuleList.contains(where: { $0.formlabsSlotIndex != nil }) {
            refreshOracleCanvasPreview()
        }
        if settings.excerptCanvasModuleList.contains(where: { $0.formlabsSlotIndex != nil }) {
            refreshExcerptCanvasPreview()
        }
        for device in enabledDevices(for: .aiMacScreen) {
            let config = aiMacScreenSettings(for: device.id)
            let usesFormlabs = config.mode == .card && config.cardMode.formlabsSlotIndex != nil
                || config.mode == .canvas && config.canvasBoards.indices.contains(config.canvasBoardIndex)
                && config.canvasBoards[config.canvasBoardIndex].moduleList
                    .contains(where: { $0.formlabsSlotIndex != nil })
            if usesFormlabs { refreshAIMacScreenPreview(deviceID: device.id) }
        }
    }

    public func refreshFormlabs(deviceID: UUID, force: Bool = false,
                                pushIfVisible: Bool = false) async {
        guard let device = settings.devices.first(where: { $0.id == deviceID && $0.type == .formlabs }) else { return }
        guard force || formLabsRefreshDue(deviceID: deviceID, now: Date()) else { return }
        let config = device.settings.formlabsConnection ?? FormlabsConnectionSettings()
        let hasCloud = !config.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !config.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !config.printerSerial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasCloud else { return }
        formlabsRefreshing.insert(deviceID)
        defer { formlabsRefreshing.remove(deviceID) }
        lastFormlabsRefresh[deviceID] = Date()
        let previous = formlabsSnapshots[deviceID] ?? .empty
        let updated = await formlabsClient.refresh(settings: config, previous: previous)
        formlabsSnapshots[deviceID] = updated
        store.saveFormlabsTaskCache(formlabsSnapshots)
        if let cloudError = updated.cloudError {
            formlabsConnectionStatus[deviceID] = "云端刷新失败：\(cloudError)"
        } else {
            formlabsConnectionStatus[deviceID] = "Formlabs 云端数据已更新"
        }
        guard formlabsDevice(for: settings.displayMode)?.id == deviceID else { return }
        renderPreview()
        if pushIfVisible { await pushWhenAvailable(force: false, silentIfUnchanged: true) }
    }

    // MARK: - Home Assistant

    /// 取 Bambu 打印机配置（按显示模式对应第 1/2/3/4/5 台 Bambu Lab 设备：
    /// bambuLab→第 1 台、bambuLab2→第 2 台…bambuLab5→第 5 台；未配置该位时返回空占位卡）
    func bambuConfig(for mode: DisplayMode) -> BambuLabCardSettings {
        let printers = enabledDevices(for: .bambuLab)
        let index: Int
        switch mode {
        case .bambuLab2: index = 1
        case .bambuLab3: index = 2
        case .bambuLab4: index = 3
        case .bambuLab5: index = 4
        default: index = 0
        }
        if printers.indices.contains(index) {
            return BambuLabCardSettings.from(printers[index])
        }
        let placeholder: String
        switch index {
        case 1: placeholder = "打印机 2"
        case 2: placeholder = "打印机 3"
        case 3: placeholder = "打印机 4"
        case 4: placeholder = "打印机 5"
        default: placeholder = "打印机"
        }
        return BambuLabCardSettings(name: placeholder)
    }

    /// HA 卡片实体列表（基线：全局共享一份；顺序即卡片显示顺序）
    public var haEntityList: [String] {
        if Self.haCardPerKeyboardEnabled { return settings.haCardEntityIDs }
        let list = settings.haEntities
        if list.isEmpty, !settings.haEntityID.isEmpty { return [settings.haEntityID] }
        return list
    }

    /// 批量添加实体（多选勾选确认后调用；去空去重，保持现有顺序后追加）
    public func addHAEntitiesBatch(_ entityIDs: [String]) {
        setHAEntities(HAEntityListEditor.merge(haEntityList, adding: entityIDs))
    }

    /// 从多实体列表移除一个实体（保留首项兼容单实体字段）
    public func removeHAEntity(_ entityID: String) {
        var list = haEntityList
        list.removeAll { $0 == entityID }
        setHAEntities(list)
    }

    /// 多实体列表拖拽排序提交
    public func moveHAEntity(from source: IndexSet, to destination: Int) {
        var list = haEntityList
        list.move(fromOffsets: source, toOffset: destination)
        setHAEntities(list)
    }

    /// 用新实体替换失效绑定（保持列表位置与自定义显示名称；换服务器后可一键重选）
    public func replaceHAEntity(oldID: String, newID: String) {
        let target = newID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != oldID else { return }
        var list = haEntityList
        guard let index = list.firstIndex(of: oldID) else { return }
        if list.contains(target) {
            list.remove(at: index)          // 新实体已在列表中：失效项直接去掉
        } else {
            list[index] = target
        }
        if let alias = settings.haEntityAliases.removeValue(forKey: oldID) {
            settings.haEntityAliases[target] = alias   // 显示名称跟随换绑
        }
        setHAEntities(list)
    }

    /// 写入 HA 卡片实体列表（基线：全局镜像 + 活动 HA 设备快照）
    private func setHAEntities(_ list: [String]) {
        if Self.haCardPerKeyboardEnabled {
            settings.haCardEntityIDs = list
            if let kb = activeDevice(for: .keyboard),
               let index = settings.devices.firstIndex(where: { $0.id == kb.id }) {
                settings.devices[index].settings.haCardEntityIDs = list
            }
        } else {
            settings.haEntities = list
            settings.haEntityID = list.first ?? ""
            if let devID = activeHADeviceID,
               let index = settings.devices.firstIndex(where: { $0.id == devID }) {
                settings.devices[index].settings.haEntities = list
                settings.devices[index].settings.haEntityID = list.first ?? ""
            }
        }
        persistSettings()
        // 实体列表变更后立即重建快照选中集并刷新预览/推送（不依赖轮询间隔）
        refreshHASnapshotSelection()
    }

    /// 设置实体自定义显示名称（空 = 清除别名回默认名）
    public func setHAEntityAlias(_ entityID: String, alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        var aliases = settings.haEntityAliases
        if trimmed.isEmpty {
            aliases.removeValue(forKey: entityID)
        } else {
            aliases[entityID] = trimmed
        }
        settings.haEntityAliases = aliases
        // 显示名称是实体本身的属性：全局共享一份，不写到任何设备快照上
        persistSettings()
        refreshHASnapshotSelection()
    }

    /// 按当前实体列表立即重建快照选中集并刷新预览、按需推送一次
    private func refreshHASnapshotSelection() {
        applyHASnapshot(entities: haSnapshot.entities, errorText: haSnapshot.errorText,
                        rebuildBambuCatalog: false, sampledAt: haSnapshot.sampledAt)
        renderPreview()
        let expectedPictureIDs = haCardPictureEntityIDs()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pushWhenAvailable(force: false, silentIfUnchanged: true)
            guard self.settings.displayMode == .homeAssistant else { return }
            if await self.refreshCurrentHAPictures(expectedEntityIDs: expectedPictureIDs) {
                await self.pushWhenAvailable(force: false, silentIfUnchanged: true)
            }
        }
    }

    /// 本键盘 Home Assistant 卡片实体列表绑定（设置页多实体编辑用）
    public var haEntitiesBinding: Binding<[String]> {
        Binding(get: { self.haEntityList },
                set: { self.setHAEntities($0) })
    }

    /// HA 是否到刷新时间（按设置间隔节流；未配置服务器地址返回 false）
    private func haRefreshDue(now: Date) -> Bool {
        HARefreshPolicy.isDue(now: now, serverURL: settings.haServerURL,
                              minutes: settings.haRefreshMinutes, lastRefresh: lastHARefresh)
    }

    /// 共享服务器配置变更（地址/令牌）：立即按新配置重拉一次，让所有设备即时生效
    public func reloadHAServer() {
        lastHARefresh = nil
        if !haSnapshot.entities.isEmpty {
            applyHASnapshot(entities: haSnapshot.entities, errorText: nil,
                            rebuildBambuCatalog: false, sampledAt: haSnapshot.sampledAt)
        }
        Task { await refreshHA() }
    }

    /// 拉取 Home Assistant 实体状态并更新快照（失败时保留旧实体列表、记录错误文案；不打印令牌）。
    /// 后台按刷新间隔自动轮询（tick 驱动）；开启异常监控时进行异常判定：
    /// 检测到异常推送到键盘告警，恢复正常清除告警
    public func refreshHA(includePictures: Bool = true) async {
        guard !haRefreshing else { return }
        haRefreshing = true
        defer { haRefreshing = false }
        guard !settings.haServerURL.isEmpty else {
            // 未配置/已清空服务器：不保留上一台服务器的实体池，卡片明确显示未连接
            applyHASnapshot(entities: [], errorText: nil)
            haSnapshot.images = [:]
            return
        }
        lastHARefresh = Date()
        do {
            let entities = try await HomeAssistantClient.fetchStates(serverURL: settings.haServerURL,
                                                                     token: settings.haToken)
            // 一份全局快照：HA 卡片、画板模块、异常监控、打印机映射共用同一数据源
            applyHASnapshot(entities: entities, errorText: nil)
            // 仅抓取用户已映射且开启显示的 Bambu image.*/camera.* 实体当前静态帧。
            // 单帧失败时保留上一帧，避免摄像头偶发超时造成卡片闪空。
            if includePictures {
                _ = await refreshHAPictures(entities: entities)
            }
            // Bambu Lab 打印机告警：状态=error 或错误码实体非空 → 推送告警（开启告警开关时）
            // Bambu 打印机告警：遍历全部已启用打印机设备（每台独立），任一报错推告警（含打印机名），恢复自动清除
            let printers = enabledDevices(for: .bambuLab)
                .map { BambuLabCardSettings.from($0) }
            let staleSeconds = TimeInterval(max(10, max(1, settings.haRefreshMinutes) * 2) * 60)
            var anyError: (name: String, code: String)? = nil
            for printer in printers where printer.enableAlert {
                guard !printer.statusEntityID.isEmpty || !printer.errorEntityID.isEmpty else { continue }
                let statusE = entities.first { $0.entityId == printer.statusEntityID }
                let errorE = entities.first { $0.entityId == printer.errorEntityID }
                let isError = (statusE?.state.lowercased() == "error")
                    || (errorE.map { e in
                        let s = e.state.trimmingCharacters(in: .whitespaces).lowercased()
                        // binary_sensor 类 HMS 错误实体 off = 无错误、on = 有错误；
                        // unavailable/unknown 为设备离线/不可用，也不是错误码
                        return !s.isEmpty && !["none", "无", "normal", "ok", "0", "off", "unavailable", "unknown"].contains(s)
                            && HAErrorCodePolicy.isFresh(entity: e, staleSeconds: staleSeconds)
                    } ?? false)
                if isError {
                    anyError = (printer.name, errorE?.state ?? statusE?.state ?? "打印机报错")
                    break
                }
            }
            if let error = anyError {
                // 同一错误码超时后进入冷却，不再反复占屏；错误码变化（新故障）则立即提醒
                if haAlertTitle.isEmpty, shouldAlert(code: error.code, now: Date()) {
                    enterHAAlert(title: error.name, message: error.code)
                }
            } else {
                if !haAlertTitle.isEmpty {
                    clearHAAlert()
                }
            }
            // 打印完成庆祝：状态从「非完成」跳变到「完成」（completed/finish/success/done）时，
            // 推送一次 🎉 打印完成提醒（与番茄钟夸夸卡同模式，短暂占屏；不重复推送）
            let completedStates: Set<String> = ["completed", "finish", "success", "done"]
            for printerDevice in enabledDevices(for: .bambuLab) {
                guard let statusID = printerDevice.settings.bambuStatusEntityID, !statusID.isEmpty,
                      let e = entities.first(where: { $0.entityId == statusID }) else { continue }
                let state = e.state.trimmingCharacters(in: .whitespaces).lowercased()
                let prev = lastPrinterStatuses[printerDevice.id]
                lastPrinterStatuses[printerDevice.id] = state
                guard completedStates.contains(state), let prev, !completedStates.contains(prev) else { continue }
                // 完成瞬间抓取任务名，让用户知道具体打完的是哪个任务
                let taskName = printerDevice.settings.bambuTaskEntityID.flatMap { id in
                    entities.first(where: { $0.entityId == id })?.state
                }
                // 完成瞬间的画面（摄像头最后一帧 / 模型封面）
                enterPrintSuccess(printerName: printerDevice.name, taskName: taskName,
                                  picture: nil)
            }
            // 异常监控判定（配置开启且有可判定的条件时）
            if settings.haMonitorEnabled,
               !settings.haMonitorEntityID.isEmpty || !settings.haMonitorErrorEntityID.isEmpty {
                let result = HomeAssistantClient.monitor(
                    entities: entities,
                    monitorEntityID: settings.haMonitorEntityID,
                    expectedState: settings.haMonitorExpectedState,
                    errorEntityID: settings.haMonitorErrorEntityID,
                    staleErrorSeconds: TimeInterval(max(10, max(1, settings.haRefreshMinutes) * 2) * 60))
                let title = monitoredEntityDisplayName(entities: entities)
                if result.isAbnormal {
                    // 异常：进入告警状态并推送到键盘（只推一次，避免每次刷新重复推送）
                    if haAlertTitle.isEmpty {
                        enterHAAlert(title: title, message: result.reason ?? "实体状态异常")
                    }
                } else {
                    // 恢复正常：清除告警并恢复显示（仅当之前处于告警状态）
                    if !haAlertTitle.isEmpty {
                        clearHAAlert()
                    }
                }
            }
        } catch let error as HAError {
            // 网络波动时保留上一次完整实体目录，避免设备管理中的候选瞬间全部消失。
            applyHASnapshot(entities: haSnapshot.entities,
                            errorText: error.errorDescription ?? "无法获取实体状态",
                            rebuildBambuCatalog: false,
                            sampledAt: haSnapshot.sampledAt)
        } catch {
            applyHASnapshot(entities: haSnapshot.entities,
                            errorText: "无法获取实体状态",
                            rebuildBambuCatalog: false,
                            sampledAt: haSnapshot.sampledAt)
        }
    }

    /// Bambu 卡片可用局部状态刷新，但设备管理的实体选择器必须至少建立过一次
    /// 完整目录。只在目录为空时补拉，不会每次打开页面都下载大型 /api/states。
    public func ensureBambuEntityCatalog() async {
        guard bambuEntityCatalog.printerEntities.isEmpty,
              !settings.haServerURL.isEmpty else { return }
        await refreshHA(includePictures: false)
    }

    /// 统一构建全局 HA 快照：一份服务器数据同时供 HA 卡片、画板模块、异常监控与打印机映射使用。
    /// 同时记录每个实体的最后一次已知值，并标出「已绑定但当前服务器查无此实体」的失效项
    /// （换服务器后不静默错绑、也不凭空消失，而是明确显示失效）。
    private func applyHASnapshot(entities: [HAEntity], errorText: String?,
                                 rebuildBambuCatalog: Bool = true,
                                 sampledAt: Date? = nil) {
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.entityId, $0) })
        // 最后已知值只服务于已经绑定的实体。旧逻辑保存服务器全部实体且永不清理，
        // 在大型 HA 实例或实体改名后会持续抬高常驻内存。
        let retainedIDs = Set(boundEntityIDs())
        var values = haSnapshot.lastKnownValues.filter { retainedIDs.contains($0.key) }
        for entity in entities where retainedIDs.contains(entity.entityId) {
            values[entity.entityId] = entity.displayValue
        }
        // 拉取失败（实体池为空）时不做失效判定，避免把全部绑定误标失效
        let missing: [String] = entities.isEmpty ? [] : missingBoundEntityIDs(pool: byID)
        if rebuildBambuCatalog {
            bambuEntityCatalog = BambuEntityCatalog(entities: entities)
        }
        haSnapshot = HASnapshot(entities: entities,
                                selectedEntities: haEntityList.compactMap { byID[$0] },
                                aliases: settings.haEntityAliases,
                                errorText: errorText,
                                sampledAt: sampledAt ?? Date(),
                                missingEntityIDs: missing,
                                lastKnownValues: values,
                                images: haSnapshot.images)
    }

    /// Home Assistant 独立卡片中用户已选择的 camera/image 实体（去重、保序）。
    func haCardPictureEntityIDs() -> [String] {
        HAEntityPicker.pictureEntityIDs(in: haEntityList)
    }

    /// 本轮需要保留/抓取的全部静态画面实体 ID：Bambu 卡与 HA 独立卡共用缓存。
    func pictureEntityIDs() -> [String] {
        if !Self.haPictureSupportEnabled { return [] }
        var ids = haCardPictureEntityIDs()
        for printer in enabledDevices(for: .bambuLab) {
            let config = BambuLabCardSettings.from(printer)
            guard config.showImage else { continue }
            let id = config.selectedImageEntityID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// 当前 HA 卡片静态帧刷新；快速切换卡片或修改实体列表时校验预期 ID，
    /// 避免旧请求完成后把不再选择的摄像头画面补推到键盘。
    private func refreshCurrentHAPictures(expectedEntityIDs: [String]) async -> Bool {
        guard settings.displayMode == .homeAssistant,
              haCardPictureEntityIDs() == expectedEntityIDs else { return false }
        let changed = await refreshHAPictures(entities: haSnapshot.entities,
                                              wantedIDs: expectedEntityIDs)
        return changed
            && settings.displayMode == .homeAssistant
            && haCardPictureEntityIDs() == expectedEntityIDs
    }

    /// 当前 Bambu 卡片已经映射的实体 ID（不包含空值，去重）。
    private func bambuEntityIDs(for mode: DisplayMode) -> [String] {
        guard mode.bambuSlotIndex != nil else { return [] }
        let config = bambuConfig(for: mode)
        return [config.statusEntityID, config.progressEntityID, config.taskEntityID,
                config.nozzleTempEntityID, config.bedTempEntityID, config.selectedTimeEntityID,
                config.errorEntityID, config.selectedImageEntityID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Bambu 卡片切入专用刷新：仅请求当前打印机已选择的实体，并合并回原有完整目录。
    private func refreshCurrentBambuEntities() async {
        await refreshBambuEntities(for: settings.displayMode)
    }

    /// 指定卡片位的 Bambu 局部刷新。键盘与其他显示设备共用这一入口，
    /// 因而切换 AI Mac 卡片无需临时改变键盘当前显示模式。
    private func refreshBambuEntities(for mode: DisplayMode) async {
        guard mode.bambuSlotIndex != nil else { return }
        // 冷启动直接落在 Bambu 卡片时，先建立一次完整目录；以后切卡仍只刷新已选实体。
        if bambuEntityCatalog.printerEntities.isEmpty {
            await ensureBambuEntityCatalog()
            if !bambuEntityCatalog.printerEntities.isEmpty { return }
        }
        guard !haRefreshing else { return }
        let ids = bambuEntityIDs(for: mode)
        guard !ids.isEmpty, !settings.haServerURL.isEmpty else { return }
        haRefreshing = true
        defer { haRefreshing = false }
        do {
            let updated = try await HomeAssistantClient.fetchStates(
                serverURL: settings.haServerURL, token: settings.haToken, entityIDs: ids)
            var merged = haSnapshot.entities
            var indices = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($0.element.entityId, $0.offset) })
            for entity in updated {
                if let index = indices[entity.entityId] {
                    merged[index] = entity
                } else {
                    indices[entity.entityId] = merged.count
                    merged.append(entity)
                }
            }
            // 状态值更新不会改变设备管理候选目录，不重新做完整筛选与排序。
            applyHASnapshot(entities: merged, errorText: nil, rebuildBambuCatalog: false)
        } catch let error as HAError {
            applyHASnapshot(entities: haSnapshot.entities,
                            errorText: error.errorDescription ?? "无法获取实体状态",
                            rebuildBambuCatalog: false,
                            sampledAt: haSnapshot.sampledAt)
        } catch {
            applyHASnapshot(entities: haSnapshot.entities, errorText: "无法获取实体状态",
                            rebuildBambuCatalog: false,
                            sampledAt: haSnapshot.sampledAt)
        }
    }

    /// 当前卡首次状态画面已经推送后，再抓取摄像头静态帧；切到别的卡片则不补推。
    private func refreshCurrentBambuPicture(expectedMode: DisplayMode,
                                            expectedEntityID: String? = nil) async -> Bool {
        guard settings.displayMode == expectedMode else { return false }
        let config = bambuConfig(for: expectedMode)
        if let expectedEntityID, config.selectedImageEntityID != expectedEntityID { return false }
        guard config.showImage, !config.selectedImageEntityID.isEmpty else { return false }
        let changed = await refreshHAPictures(entities: haSnapshot.entities,
                                              wantedIDs: [config.selectedImageEntityID])
        guard changed, settings.displayMode == expectedMode else { return false }
        if let expectedEntityID {
            return bambuConfig(for: expectedMode).selectedImageEntityID == expectedEntityID
        }
        return true
    }

    /// 自动聚焦开启时，每次真正向键盘上传前只采样一张最新静态帧。
    /// Bambu 摄像头本身帧率较低，不连续追帧；Vision 分析在后台线程完成，上一帧裁切状态
    /// 负责平滑与容错。图片拉取或识别失败时保留原图/逐步退回全画面，绝不阻断本次推送。
    private func prepareCurrentBambuCameraFrameForPush() async {
        guard praiseText == nil, printSuccessName == nil, haAlertTitle.isEmpty else { return }
        let expectedMode = settings.displayMode
        guard expectedMode.bambuSlotIndex != nil else { return }
        let config = bambuConfig(for: expectedMode)
        let cameraID = config.imageEntityID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.autoCameraZoom, config.showImage, config.imageSource == .camera,
              !cameraID.isEmpty else { return }

        // 同步当前进度与任务名：裁切范围会随进度强制扩大，任务变化则重置上一任务的取景状态。
        // 这里只请求最多两个已绑定实体，避免每次推送都下载完整 HA 实体库。
        let trackingIDs = [config.progressEntityID, config.taskEntityID]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !trackingIDs.isEmpty, !settings.haServerURL.isEmpty,
           let updated = try? await HomeAssistantClient.fetchStates(
                serverURL: settings.haServerURL, token: settings.haToken,
                entityIDs: trackingIDs, timeout: 5),
           settings.displayMode == expectedMode {
            var merged = haSnapshot.entities
            var indices = Dictionary(uniqueKeysWithValues: merged.enumerated().map {
                ($0.element.entityId, $0.offset)
            })
            for entity in updated {
                if let index = indices[entity.entityId] {
                    merged[index] = entity
                } else {
                    indices[entity.entityId] = merged.count
                    merged.append(entity)
                }
            }
            applyHASnapshot(entities: merged, errorText: nil,
                            rebuildBambuCatalog: false, sampledAt: Date())
        }

        // camera_proxy / entity_picture 每次重新请求；HA 或摄像头超时时 refreshHAPictures
        // 会保留上一张有效帧，随后仍可生成一张正常卡片。
        _ = await refreshHAPictures(entities: haSnapshot.entities, wantedIDs: [cameraID])
        guard settings.displayMode == expectedMode else { return }
        let currentConfig = bambuConfig(for: expectedMode)
        guard currentConfig.autoCameraZoom, currentConfig.imageSource == .camera,
              currentConfig.imageEntityID == cameraID,
              let rawFrame = haSnapshot.picture(for: cameraID) else { return }

        _ = await processBambuCameraFrame(rawFrame,
                                          cameraID: cameraID,
                                          expectedMode: expectedMode)
    }

    /// 设置页开启自动裁切时使用上一张原始摄像头缓存，避免为了第一次视觉反馈等待网络。
    /// 返回 true 表示缓存帧已完成处理（即使 Vision 判断应保留完整画面，也属于有效结果）。
    private func prepareCachedBambuCameraFrame(deviceID: UUID,
                                               expectedMode: DisplayMode) async -> Bool {
        guard settings.displayMode == expectedMode,
              let slot = expectedMode.bambuSlotIndex else { return false }
        let printers = enabledDevices(for: .bambuLab)
        guard printers.indices.contains(slot), printers[slot].id == deviceID else { return false }
        let config = BambuLabCardSettings.from(printers[slot])
        let cameraID = config.imageEntityID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.autoCameraZoom, config.showImage, config.imageSource == .camera,
              !cameraID.isEmpty,
              let cachedFrame = haSnapshot.picture(for: cameraID) else { return false }
        return await processBambuCameraFrame(cachedFrame,
                                             cameraID: cameraID,
                                             expectedMode: expectedMode)
    }

    /// 对给定原始帧执行一次自动取景并写入独立的裁切缓存。网络采样路径与设置页缓存路径
    /// 共用这段逻辑，确保任务切换、打印进度放宽和竞态保护完全一致。
    private func processBambuCameraFrame(_ rawFrame: Data,
                                         cameraID: String,
                                         expectedMode: DisplayMode) async -> Bool {
        guard settings.displayMode == expectedMode else { return false }
        let currentConfig = bambuConfig(for: expectedMode)
        guard currentConfig.autoCameraZoom, currentConfig.showImage,
              currentConfig.imageSource == .camera,
              currentConfig.imageEntityID == cameraID else { return false }

        let progress = haSnapshot.entities
            .first(where: { $0.entityId == currentConfig.progressEntityID })
            .flatMap { Double($0.state) }
        let taskName = haSnapshot.entities
            .first(where: { $0.entityId == currentConfig.taskEntityID })?
            .displayState.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var runtime = bambuCameraZoomRuntime[cameraID] ?? BambuCameraZoomRuntime()
        if !taskName.isEmpty, runtime.taskName != taskName {
            runtime = BambuCameraZoomRuntime(state: BambuCameraZoomState(), taskName: taskName)
        } else if !taskName.isEmpty {
            runtime.taskName = taskName
        }
        let previousState = runtime.state
        let output = await Task.detached(priority: .utility) {
            BambuCameraAutoZoom.process(imageData: rawFrame,
                                        progress: progress,
                                        previous: previousState)
        }.value

        // 分析期间若用户切卡、换实体或关闭开关，丢弃过时结果。
        guard settings.displayMode == expectedMode else { return false }
        let verified = bambuConfig(for: expectedMode)
        guard verified.autoCameraZoom, verified.showImage,
              verified.imageSource == .camera,
              verified.imageEntityID == cameraID else { return false }
        runtime.state = output.state
        bambuCameraZoomRuntime[cameraID] = runtime
        bambuAutoZoomImages[cameraID] = output.imageData
        return true
    }

    /// 拉取需要展示的画面（跟随 HA 轮询同一节奏；支持 image.* 与 camera.* 静态帧）。
    /// 失败的实体保留上一轮画面，避免摄像头偶发超时导致卡片闪空。
    @discardableResult
    private func refreshHAPictures(entities: [HAEntity], wantedIDs: [String]? = nil) async -> Bool {
        let retained = pictureEntityIDs()
        let retainedSet = Set(retained)
        bambuAutoZoomImages = bambuAutoZoomImages.filter { retainedSet.contains($0.key) }
        bambuCameraZoomRuntime = bambuCameraZoomRuntime.filter { retainedSet.contains($0.key) }
        let wanted = wantedIDs ?? retained
        guard !retained.isEmpty else {
            let changed = !haSnapshot.images.isEmpty
            if !haSnapshot.images.isEmpty { haSnapshot.images = [:] }
            return changed
        }
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.entityId, $0) })
        let requests: [(String, URL)] = wanted.compactMap { id in
            guard let entity = byID[id],
                  let url = HomeAssistantClient.imageURL(server: settings.haServerURL,
                                                         entity: entity,
                                                         token: settings.haToken) else { return nil }
            return (id, url)
        }
        let token = settings.haToken
        let fetched = await withTaskGroup(of: (String, Data?).self) { group in
            for (id, url) in requests {
                group.addTask {
                    (id, try? await HomeAssistantClient.fetchImage(url: url, token: token))
                }
            }
            var result: [String: Data] = [:]
            for await (id, data) in group {
                if let data { result[id] = data }
            }
            return result
        }
        var images = haSnapshot.images.filter { retained.contains($0.key) }
        for (id, data) in fetched { images[id] = data }
        let changed = images != haSnapshot.images
        haSnapshot.images = images
        return changed
    }

    /// 所有已绑定的 entity_id：HA 卡片实体 + 每台打印机七字段映射 + 异常监控实体（去重、保序、去空）
    func boundEntityIDs() -> [String] {
        var ids: [String] = []
        func add(_ candidate: String?) {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, !ids.contains(value) else { return }
            ids.append(value)
        }
        haEntityList.forEach { add($0) }
        canvasHAEntityIDs(for: .keyboard).forEach { add($0) }
        canvasHAEntityIDs(for: .oracle).forEach { add($0) }
        canvasHAEntityIDs(for: .excerpt).forEach { add($0) }
        for printer in devices(for: .bambuLab) {
            let config = BambuLabCardSettings.from(printer)
            add(config.statusEntityID); add(config.progressEntityID); add(config.taskEntityID)
            add(config.nozzleTempEntityID); add(config.bedTempEntityID)
            add(config.remainingEntityID); add(config.endTimeEntityID); add(config.errorEntityID)
            add(config.imageEntityID); add(config.taskImageEntityID)
        }
        if settings.haMonitorEnabled {
            add(settings.haMonitorEntityID); add(settings.haMonitorErrorEntityID)
        }
        return ids
    }

    /// 已绑定但服务器实体池中查不到的 entity_id（基线关闭失效提示 → 恒为空）
    func missingBoundEntityIDs(pool: [String: HAEntity]) -> [String] {
        guard Self.haStaleHintsEnabled else { return [] }
        return boundEntityIDs().filter { pool[$0] == nil }
    }

    /// HA 告警最长强制显示时长（秒）：设备报错最多占屏 1 分钟，到期自动清除恢复常规卡片
    private var haAlertMaxSeconds: TimeInterval { 60 }
    /// 同一错误码超时后的冷却时长：期间不再重复弹告警，避免报错长期占屏、其他卡片无法推送
    private var haAlertCooldownSeconds: TimeInterval { 10 * 60 }

    /// 是否应弹出告警：无冷却、或错误码与上次已提醒过的不同（新故障立即提醒）
    private func shouldAlert(code: String, now: Date) -> Bool {
        if let alerted = haAlertedCode, alerted != code { return true }   // 换了错误码：不受冷却限制
        if let until = haAlertCooldownUntil, now < until { return false } // 冷却期内不重复
        return true
    }

    /// 进入告警状态（记录触发时间与错误码）并立即推送
    private func enterHAAlert(title: String, message: String) {
        haAlertTitle = title
        haAlertMessage = message
        haAlertSetAt = Date()
        haAlertedCode = message
        renderPreview()
        Task { await push(force: true) }
    }

    /// 清除告警并推送恢复正常；超时清除时进入冷却，避免同一错误立刻再次占屏
    private func clearHAAlert(cooldown: Bool = false) {
        let timedOut = cooldown
        haAlertTitle = ""
        haAlertMessage = ""
        haAlertSetAt = nil
        if timedOut {
            haAlertCooldownUntil = Date().addingTimeInterval(haAlertCooldownSeconds)
        } else {
            // 设备已恢复正常：解除冷却，下次报错可以立即提醒
            haAlertCooldownUntil = nil
            haAlertedCode = nil
        }
        renderPreview()
        Task { await push(force: true) }
    }

    /// 打印完成庆祝：短暂展示 🎉 卡片并推送（与番茄钟夸夸同模式），带上完成的任务名
    private func enterPrintSuccess(printerName: String, taskName: String?, picture: Data?) {
        printSuccessName = printerName
        printSuccessTask = taskName
        printSuccessImage = picture
        printSuccessUntil = Date().addingTimeInterval(Self.praiseDisplaySeconds)
        renderPreview()
        Task { await push(force: true) }
    }

    /// 被监控实体的显示名（状态实体优先，其次错误码实体，都缺时用「Home Assistant」）
    private func monitoredEntityDisplayName(entities: [HAEntity]) -> String {
        if !settings.haMonitorEntityID.isEmpty,
           let e = entities.first(where: { $0.entityId == settings.haMonitorEntityID }) {
            return e.displayName
        }
        if !settings.haMonitorErrorEntityID.isEmpty,
           let e = entities.first(where: { $0.entityId == settings.haMonitorErrorEntityID }) {
            return e.displayName
        }
        return "Home Assistant"
    }

    /// 额度百分比基线自动采样：跨天重新采样 + 额度高于基线时拉高基线（基线变更经 onChange 自动持久化；
    /// 值未变化时跳过赋值，避免每次刷新触发多余持久化/重渲染）
    private func applyQuotaBaselineSampling(remaining: Double, now: Date) {
        let result = QuotaBaselineSampler.sample(
            baseline: settings.qwenQuotaBaseline,
            baselineDay: settings.qwenQuotaBaselineDay,
            remaining: remaining,
            today: QuotaBaselineSampler.dayKey(now))
        guard settings.qwenQuotaBaseline != result.baseline || settings.qwenQuotaBaselineDay != result.day else { return }
        settings.qwenQuotaBaseline = result.baseline
        settings.qwenQuotaBaselineDay = result.day
    }

    /// 手动把当前剩余额度抓取为百分比基线（100%）；之后每次减少按 当前/基线 计算
    public func captureQuotaBaseline() {
        guard qwenQuota.remainingCredits > 0 else {
            status = "当前额度为 0，无法作为基线"
            return
        }
        settings.qwenQuotaBaseline = qwenQuota.remainingCredits
        settings.qwenQuotaBaselineDay = QuotaBaselineSampler.dayKey(Date())
        var updated = qwenQuota
        updated.trackedProgress = 1
        qwenQuota = updated
        status = "已把当前额度 \(String(format: "%.2f", qwenQuota.remainingCredits)) 设为 100% 基线"
        persistSettings()
        renderPreview()
    }

    /// 额度百分比基线说明文字（设置页显示）
    public var quotaBaselineText: String {
        guard let baseline = settings.qwenQuotaBaseline else { return "未设置" }
        return String(format: "%.2f", baseline)
    }

    /// 剩余百分比说明文字（设置页显示；尚未取得额度数据时提示）
    public var qwenQuotaPercentText: String {
        guard let tracked = qwenQuota.trackedProgress else { return "尚无额度数据" }
        return "剩余 \(Int((tracked * 100).rounded()))%"
    }

    /// 少数派推荐：键盘卡片当前展示的随机三条（nil = 按推荐顺序取前三条）
    @Published private var keyboardSspaiSelection: [SspaiArticle]?

    /// 键盘少数派卡片使用的文章：随机模式下用已抽取的三条，否则用推荐顺序的前三条
    var keyboardSspaiArticles: [SspaiArticle] {
        keyboardSspaiSelection ?? sspaiArticles
    }

    /// 重新随机抽取三条少数派文章（文章多于三条时）
    private func rollSspaiRandom() {
        guard sspaiArticles.count > 3 else {
            keyboardSspaiSelection = nil
            return
        }
        keyboardSspaiSelection = Array(sspaiArticles.shuffled().prefix(3))
    }

    /// 进入「少数派推荐」页：开启随机推送且文章多于三条时，重新随机抽取三条并推送到键盘
    public func enterSspaiPage() async {
        guard settings.sspaiRandomPush else { return }
        _ = await fetchSspai()   // 先刷新文章池
        rollSspaiRandom()        // 再随机抽取三条
        if settings.displayMode != .sspai {
            setMode(.sspai)      // 切到少数派卡片并推送
        } else {
            renderPreview()
            await push(force: true)
        }
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
                lastRefresh = "最后刷新：\(Self.formatNow())"
                if upload {
                    try await uploadRendered(force: forceUpload)
                } else {
                    renderPreview()
                    status = failures.isEmpty ? "数据已刷新" : failures.joined(separator: "；")
                }
            case .nowPlaying:
                nowPlaying = try await nowPlayingClient.fetch()
                lastRefresh = "最后刷新：\(Self.formatNow())"
                if upload {
                    try await uploadRendered(force: forceUpload)
                } else {
                    renderPreview()
                    status = "数据已刷新"
                }
            case .systemMonitor:
                system = monitor.sample(now: Date())
                lastRefresh = "最后刷新：\(Self.formatNow())"
                if upload {
                    try await uploadRendered(force: forceUpload)
                } else {
                    renderPreview()
                    status = "数据已刷新"
                }
            default:
                if upload {
                    try await uploadRendered(force: forceUpload)
                } else {
                    renderPreview()
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

    /// 画板模块编辑目标：键盘画板与三类独立设备画板各自持有模块列表
    public enum CanvasOwner {
        case keyboard, oracle, excerpt, aiMac
    }

    private func canvasModulesRaw(for owner: CanvasOwner) -> [Int] {
        switch owner {
        case .keyboard: return settings.canvasModules
        case .oracle: return settings.oracleCanvasModules
        case .excerpt: return settings.excerptCanvasModules
        case .aiMac: return aiMacCanvasModules.map(\.rawValue)
        }
    }

    private func setCanvasModulesRaw(_ modules: [Int], for owner: CanvasOwner) {
        switch owner {
        case .keyboard: settings.canvasModules = modules
        case .oracle: settings.oracleCanvasModules = modules
        case .excerpt: settings.excerptCanvasModules = modules
        case .aiMac:
            mutateCurrentAIMacCanvasBoard { $0.modules = modules }
        }
    }

    /// 某一块画板的 HA 模块实体列表。三块画板与 HA 键盘卡片均不共用选择结果。
    func canvasHAEntityIDs(for owner: CanvasOwner) -> [String] {
        switch owner {
        case .keyboard: return settings.canvasHAEntityIDs
        case .oracle: return settings.oracleCanvasHAEntityIDs
        case .excerpt: return settings.excerptCanvasHAEntityIDs
        case .aiMac:
            guard let id = activeDeviceID(for: .aiMacScreen) else { return [] }
            let config = aiMacScreenSettings(for: id)
            guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return [] }
            return config.canvasBoards[config.canvasBoardIndex].haEntityIDs
        }
    }

    /// 写入某画板的 HA 实体列表；AppSettings 的 onChange 会同步到该画板所属的活动设备快照。
    func setCanvasHAEntityIDs(_ ids: [String], for owner: CanvasOwner) {
        let cleaned = HAEntityListEditor.merge([], adding: ids)
        switch owner {
        case .keyboard: settings.canvasHAEntityIDs = cleaned
        case .oracle: settings.oracleCanvasHAEntityIDs = cleaned
        case .excerpt: settings.excerptCanvasHAEntityIDs = cleaned
        case .aiMac: mutateCurrentAIMacCanvasBoard { $0.haEntityIDs = cleaned }
        }
    }

    func addCanvasHAEntities(_ ids: [String], for owner: CanvasOwner) {
        setCanvasHAEntityIDs(HAEntityListEditor.merge(canvasHAEntityIDs(for: owner), adding: ids),
                             for: owner)
    }

    func removeCanvasHAEntity(_ id: String, from owner: CanvasOwner) {
        setCanvasHAEntityIDs(canvasHAEntityIDs(for: owner).filter { $0 != id }, for: owner)
    }

    /// 将同一份 HA 实体池按画板自己的选择列表投影为渲染快照。
    func haSnapshot(forCanvas owner: CanvasOwner) -> HASnapshot {
        haSnapshot.selecting(entityIDs: canvasHAEntityIDs(for: owner))
    }

    /// 各画板「少数派推荐」显示条数（1–6，各自独立）
    func sspaiCount(for owner: CanvasOwner) -> Int {
        switch owner {
        case .keyboard: return settings.canvasSspaiCount
        case .oracle: return settings.oracleSspaiCount
        case .excerpt: return settings.excerptSspaiCount
        case .aiMac:
            guard let id = activeDeviceID(for: .aiMacScreen) else { return 3 }
            let config = aiMacScreenSettings(for: id)
            guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return 3 }
            return config.canvasBoards[config.canvasBoardIndex].sspaiCount
        }
    }

    func setSspaiCount(_ count: Int, for owner: CanvasOwner) {
        let value = min(max(count, 1), 6)
        switch owner {
        case .keyboard: settings.canvasSspaiCount = value
        case .oracle: settings.oracleSspaiCount = value
        case .excerpt: settings.excerptSspaiCount = value
        case .aiMac: mutateCurrentAIMacCanvasBoard { $0.sspaiCount = value }
        }
    }

    func setSspaiRandom(_ enabled: Bool, for owner: CanvasOwner) {
        switch owner {
        case .keyboard: settings.canvasSspaiRandom = enabled
        case .oracle: settings.oracleSspaiRandom = enabled
        case .excerpt: settings.excerptSspaiRandom = enabled
        case .aiMac:
            mutateCurrentAIMacCanvasBoard { $0.sspaiRandom = enabled }
            aiMacSspaiRandomSelection = [:]
        }
    }

    func nowPlayingHorizontal(for owner: CanvasOwner) -> Bool {
        switch owner {
        case .keyboard: return false
        case .oracle: return settings.oracleNowPlayingHorizontal
        case .excerpt: return settings.excerptNowPlayingHorizontal
        case .aiMac:
            guard let id = activeDeviceID(for: .aiMacScreen) else { return false }
            let config = aiMacScreenSettings(for: id)
            guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return false }
            return config.canvasBoards[config.canvasBoardIndex].nowPlayingHorizontal
        }
    }

    func setNowPlayingHorizontal(_ enabled: Bool, for owner: CanvasOwner) {
        switch owner {
        case .keyboard: break
        case .oracle: settings.oracleNowPlayingHorizontal = enabled
        case .excerpt: settings.excerptNowPlayingHorizontal = enabled
        case .aiMac: mutateCurrentAIMacCanvasBoard { $0.nowPlayingHorizontal = enabled }
        }
    }

    func nowPlayingCover(for owner: CanvasOwner) -> Bool {
        switch owner {
        case .aiMac:
            guard let id = activeDeviceID(for: .aiMacScreen) else { return true }
            let config = aiMacScreenSettings(for: id)
            guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return true }
            return config.canvasBoards[config.canvasBoardIndex].usesNowPlayingCover
        case .keyboard, .oracle, .excerpt:
            return settings.canvasNowPlayingCover
        }
    }

    func setNowPlayingCover(_ enabled: Bool, for owner: CanvasOwner) {
        switch owner {
        case .aiMac:
            mutateCurrentAIMacCanvasBoard { $0.nowPlayingCover = enabled }
        case .keyboard, .oracle, .excerpt:
            settings.canvasNowPlayingCover = enabled
        }
    }

    func nowPlayingSmartBackground(for owner: CanvasOwner) -> Bool {
        switch owner {
        case .keyboard: return settings.canvasNowPlayingSmartBg
        case .oracle, .excerpt: return false
        case .aiMac:
            guard let id = activeDeviceID(for: .aiMacScreen) else { return true }
            let config = aiMacScreenSettings(for: id)
            guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return true }
            return config.canvasBoards[config.canvasBoardIndex].usesNowPlayingSmartBackground
        }
    }

    func setNowPlayingSmartBackground(_ enabled: Bool, for owner: CanvasOwner) {
        switch owner {
        case .keyboard: settings.canvasNowPlayingSmartBg = enabled
        case .oracle, .excerpt: break
        case .aiMac:
            mutateCurrentAIMacCanvasBoard { $0.nowPlayingSmartBackground = enabled }
        }
    }

    /// 画板归属对应的设备类型（键盘画板 → 键盘设备）
    func deviceType(for owner: CanvasOwner) -> DeviceType {
        switch owner {
        case .keyboard: return .keyboard
        case .oracle: return .oracle
        case .excerpt: return .excerpt
        case .aiMac: return .aiMacScreen
        }
    }

    /// 某画板的打印机模块显示选项：每种画板使用各自的镜像字段
    /// （先知/摘录补齐全部打印机模块默认值，渲染时不会回退到键盘画板的配置）
    func canvasPrinterFields(for owner: CanvasOwner) -> [Int: CanvasPrinterFields] {
        let stored: [Int: CanvasPrinterFields]
        switch owner {
        case .keyboard: stored = settings.canvasPrinterFields
        case .oracle: stored = settings.oracleCanvasPrinterFields
        case .excerpt: stored = settings.excerptCanvasPrinterFields
        case .aiMac:
            guard let id = activeDeviceID(for: .aiMacScreen) else { stored = [:]; break }
            let config = aiMacScreenSettings(for: id)
            stored = config.canvasBoards.indices.contains(config.canvasBoardIndex)
                ? config.canvasBoards[config.canvasBoardIndex].printerFields : [:]
        }
        guard owner != .keyboard else { return stored }
        var filled = stored
        for module in CanvasModule.allCases where module.bambuSlotIndex != nil {
            if filled[module.rawValue] == nil { filled[module.rawValue] = .default }
        }
        return filled
    }

    /// 更新某画板的打印机模块显示选项（写镜像先行，由设备同步落到对应画板设备快照，各画板互相独立）
    func setCanvasPrinterFields(_ fields: [Int: CanvasPrinterFields], for owner: CanvasOwner) {
        switch owner {
        case .keyboard:
            if settings.canvasPrinterFields != fields { settings.canvasPrinterFields = fields }
        case .oracle:
            if settings.oracleCanvasPrinterFields != fields { settings.oracleCanvasPrinterFields = fields }
        case .excerpt:
            if settings.excerptCanvasPrinterFields != fields { settings.excerptCanvasPrinterFields = fields }
        case .aiMac:
            mutateCurrentAIMacCanvasBoard { $0.printerFields = fields }
        }
    }

    /// 各画板「少数派推荐」随机显示开关（各自独立）
    func sspaiRandomEnabled(for owner: CanvasOwner) -> Bool {
        switch owner {
        case .keyboard: return settings.canvasSspaiRandom
        case .oracle: return settings.oracleSspaiRandom
        case .excerpt: return settings.excerptSspaiRandom
        case .aiMac:
            guard let id = activeDeviceID(for: .aiMacScreen) else { return false }
            let config = aiMacScreenSettings(for: id)
            guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return false }
            return config.canvasBoards[config.canvasBoardIndex].sspaiRandom
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

    /// 口袋先知画板预览（处理后；始终保持正向，不应用设备安装方向旋转）
    @Published public var oracleCanvasImage: NSImage?
    /// 口袋先知画板处理前原始渲染（始终保持正向）
    @Published public var oracleCanvasRawImage: NSImage?
    /// 摘录画板预览（处理后，设备实际效果）
    @Published public var excerptCanvasImage: NSImage?
    /// 摘录画板处理前原始渲染
    @Published public var excerptCanvasRawImage: NSImage?

    /// 口袋先知画布：模块组合渲染为 200×200 彩色原始画面（底色按手动深色/亮色模式，
    /// 支持整体旋转 180° = 上下+左右反转，非镜像）
    private func renderOracleCanvasImage(now: Date = Date(), applyDeviceRotation: Bool = true) -> CGImage {
        // 软件预览始终保持正向；只有内容指纹/实际推送路径应用设备安装方向旋转。
        let rotate = applyDeviceRotation && settings.oracleImageRotate180
        let modules = settings.oracleCanvasModuleList
        let canvasSystem = RuntimePerformancePolicy.needsSystemSample(modules: modules)
            ? monitor.sample(now: now) : system
        return ScreenRenderer.renderDeviceCanvas(modules: modules,
                                                system: canvasSystem,
                                                nowPlaying: nowPlaying, pomodoro: pomodoroSnapshot,
                                                customText: settings.canvasText, settings: settings,
                                                codex: usage, qwenQuota: qwenQuota,
                                                sspaiArticles: sspaiDisplayArticles(for: .oracle),
                                                ha: haSnapshot(forCanvas: .oracle),
                                                formlabsItems: formlabsCanvasItems(),
                                                now: now,
                                                width: ScreenRenderer.oracleCanvasSize,
                                                height: ScreenRenderer.oracleCanvasSize,
                                                palette: oraclePalette,
                                                flipVertical: rotate,
                                                flipHorizontal: rotate,
                                                nowPlayingHorizontal: settings.oracleNowPlayingHorizontal,
                                                canvasImagePath: settings.oracleCanvasImagePath,
                                                printerFields: canvasPrinterFields(for: .oracle),
                                                optimizeBambuForOracleEInk: true,
                                                bambuHeroLayout: true,
                                                showBambuCamera: false)
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
        let modules = settings.excerptCanvasModuleList
        let canvasSystem = RuntimePerformancePolicy.needsSystemSample(modules: modules)
            ? monitor.sample(now: now) : system
        return ScreenRenderer.renderDeviceCanvas(modules: modules,
                                                 system: canvasSystem,
                                                 nowPlaying: nowPlaying, pomodoro: pomodoroSnapshot,
                                                 customText: settings.canvasText, settings: settings,
                                                 codex: usage, qwenQuota: qwenQuota,
                                                 sspaiArticles: sspaiDisplayArticles(for: .excerpt),
                                                 ha: haSnapshot(forCanvas: .excerpt),
                                                 formlabsItems: formlabsCanvasItems(),
                                                 now: now,
                                                 width: ScreenRenderer.excerptCanvasWidth,
                                                 height: ScreenRenderer.excerptCanvasHeight,
                                                 palette: excerptPalette,
                                                 flipVertical: rotate,
                                                 flipHorizontal: rotate,
                                                 columns: settings.excerptLayoutColumns,
                                                 fullWidthModules: Set(settings.excerptFullWidthModules),
                                                 nowPlayingHorizontal: settings.excerptNowPlayingHorizontal,
                                                 canvasImagePath: settings.excerptCanvasImagePath,
                                                 printerFields: canvasPrinterFields(for: .excerpt),
                                                 optimizeBambuForOracleEInk: true,
                                                 bambuHeroLayout: true,
                                                 showBambuCamera: false)
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
        return processedExcerptCanvasImage(from: raw)
    }

    private func processedExcerptCanvasImage(from raw: CGImage) -> CGImage {
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
        autoreleasepool {
            let size = CGFloat(ScreenRenderer.oracleCanvasSize)
            let raw = renderOracleCanvasImage(applyDeviceRotation: false)
            let preview = ScreenRenderer.oraclePreviewImage(from: raw,
                                                            algorithm: settings.oracleGrayAlgorithm,
                                                            mode: settings.oracleDisplayMode,
                                                            dither: settings.oracleDitherKernel)
            oracleCanvasRawImage = NSImage(cgImage: raw, size: NSSize(width: size, height: size))
            oracleCanvasImage = NSImage(cgImage: preview, size: NSSize(width: size, height: size))
        }
    }

    public func refreshExcerptCanvasPreview() {
        autoreleasepool {
            let raw = renderExcerptCanvasRawImage()
            // 直接处理同一张 raw；旧逻辑在 renderExcerptCanvasImage 内又完整渲染了一次。
            let processed = processedExcerptCanvasImage(from: raw)
            let size = NSSize(width: CGFloat(ScreenRenderer.excerptCanvasWidth),
                              height: CGFloat(ScreenRenderer.excerptCanvasHeight))
            excerptCanvasRawImage = NSImage(cgImage: raw, size: size)
            excerptCanvasImage = NSImage(cgImage: processed, size: size)
        }
    }

    /// 确保口袋先知显示模式会话已连接：保持 WebSocket 连接以接收设备按键事件
    /// （display mode 会把按键信号回传给当前连接的客户端），推送帧走同一连接、发送即显示。
    /// 下键短按 → 发起手动更新切换（重新渲染并推送当前画布）。
    public func ensureRand0Session() {
        let ip = settings.rand0IP
        let endpoint: Rand0Client.Endpoint = settings.oracleDisplayMode == .gray4 ? .gray4 : .bw
        guard !ip.isEmpty else {
            rand0Session?.disconnect()
            rand0SessionConnected = false
            rand0SessionIP = ""
            rand0SessionNeedsPrime = true
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
        // 整个 AppModel 始终复用同一个 session。目标变化由 session 内的 generation
        // 淘汰旧循环；若每次新建对象，旧对象会被其 socketQueue 持有到阻塞连接返回，
        // 画板轮换时便可能积累大量重连线程。
        rand0SessionIP = ip
        rand0SessionEndpoint = endpoint
        rand0SessionNeedsPrime = true
        let session: Rand0DisplaySession
        if let existing = rand0Session {
            session = existing
        } else {
            let created = Rand0DisplaySession()
            rand0Session = created
            session = created
        }
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
        session.onStatusChange = { [weak self, weak session] connected in
            Task { @MainActor in
                guard let self, let session, self.rand0Session === session,
                      self.rand0SessionIP == ip, self.rand0SessionEndpoint == endpoint else { return }
                self.rand0SessionConnected = connected
                if connected, self.rand0SessionNeedsPrime {
                    // 首次连接与每次自动重连后立即发送当前画板，完成显示模式初始化；
                    // 之后自动推送与设备按键无需再靠一次人工测试推送来“唤醒”。
                    self.rand0SessionNeedsPrime = false
                    _ = await self.pushOracleCanvas(preRenderedFrame: nil,
                                                    skipIfUnchanged: false)
                } else if !connected {
                    self.rand0SessionNeedsPrime = true
                }
            }
        }
        Task { @MainActor [weak self, session] in
            // ensure 连续被多组设置变化触发时，丢弃尚未开始的过时目标。
            guard let self, self.rand0Session === session,
                  self.rand0SessionIP == ip, self.rand0SessionEndpoint == endpoint else { return }
            await session.connect(ip: ip, endpoint: endpoint)
            guard self.rand0Session === session,
                  self.rand0SessionIP == ip, self.rand0SessionEndpoint == endpoint else { return }
            self.rand0SessionConnected = session.isConnected
        }
    }

    /// 键盘翻页：按上下键方向在卡片列表中切换显示（上一张/下一张，循环）
    public func keyboardPage(direction: Int) {
        guard let mode = ScreenRenderer.pagedMode(from: settings.displayMode,
                                                  direction: direction,
                                                  modes: keyboardRotationList) else { return }
        setMode(mode)
    }

    /// 口袋先知多画板：新建“未命名”的空画板；第一个模块会成为默认名称。
    public func addOracleCanvasBoard() {
        let board = OracleCanvasBoard.blank(from: settings)
        var boards = settings.oracleCanvasBoards
        boards.append(board)
        settings.deviceSyncInFlight = true
        settings.oracleCanvasBoards = boards
        settings.oracleCanvasBoardIndex = boards.count - 1
        board.apply(to: settings)
        captureActiveDeviceSnapshot(of: .oracle)
        settings.deviceSyncInFlight = false
        if settings.oracleBoardRotationEnabled { lastOracleBoardRotation = Date() }
        lastOraclePushedHash = nil
        persistSettings()
        renderPreview()
        refreshOracleCanvasPreview()
        status = "已创建画板「\(board.name)」，后续修改将自动保存"
    }

    /// 口袋先知多画板：应用指定画板配置到当前画布（字段变化触发预览刷新）
    public func applyOracleCanvasBoard(at index: Int) {
        guard settings.oracleCanvasBoards.indices.contains(index) else { return }
        let board = settings.oracleCanvasBoards[index]
        settings.deviceSyncInFlight = true
        board.apply(to: settings)
        settings.oracleCanvasBoardIndex = index
        captureActiveDeviceSnapshot(of: .oracle)
        settings.deviceSyncInFlight = false
        // 用户手动选择画板后重新计算轮换周期，避免刚选中就被定时器切走。
        if settings.oracleBoardRotationEnabled { lastOracleBoardRotation = Date() }
        lastOraclePushedHash = nil
        persistSettings()
        renderPreview()
        refreshOracleCanvasPreview()
        ensureRand0Session()
    }

    /// 从侧栏按设备和画板 ID 精确切换，防止不同设备的同名/同下标画板串扰。
    public func applyOracleCanvasBoard(deviceID: UUID, boardID: UUID) {
        if activeDeviceID(for: .oracle) != deviceID {
            switchDevice(type: .oracle, to: deviceID)
        }
        guard activeDeviceID(for: .oracle) == deviceID,
              let index = settings.oracleCanvasBoards.firstIndex(where: { $0.id == boardID }) else { return }
        applyOracleCanvasBoard(at: index)
    }

    /// 口袋先知多画板：按方向循环切换画板（direction = ±1），返回是否切换成功
    @discardableResult
    public func cycleOracleCanvasBoard(direction: Int, automaticRotation: Bool = false) -> Bool {
        let boards = settings.oracleCanvasBoards
        let eligible = boards.indices.filter { index in
            let board = boards[index]
            return board.isSidebarVisible
                && (!automaticRotation || board.participatesInRotation)
        }
        guard eligible.count > 1 else { return false }
        let current = min(max(settings.oracleCanvasBoardIndex, 0), boards.count - 1)
        let anchor: Int
        if let currentPosition = eligible.firstIndex(of: current) {
            anchor = currentPosition
        } else {
            // 当前项刚被隐藏/移出轮播时，下一次从排序后最接近的可用项继续。
            anchor = direction >= 0 ? eligible.count - 1 : 0
        }
        let nextPosition = ((anchor + direction) % eligible.count + eligible.count) % eligible.count
        let next = eligible[nextPosition]
        guard next != current else { return false }
        applyOracleCanvasBoard(at: next)
        return true
    }

    /// 口袋先知多画板：重命名画板
    public func renameOracleCanvasBoard(id: UUID, to name: String) {
        guard let index = settings.oracleCanvasBoards.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.oracleCanvasBoards[index].name = trimmed
        status = "已重命名画板"
    }

    /// 画板管理：控制当前口袋先知设备的一块画板是否显示在侧边栏。
    public func setOracleCanvasBoardSidebarVisible(id: UUID, visible: Bool) {
        guard let index = settings.oracleCanvasBoards.firstIndex(where: { $0.id == id }) else { return }
        settings.deviceSyncInFlight = true
        settings.oracleCanvasBoards[index].sidebarVisible = visible
        captureActiveDeviceSnapshot(of: .oracle)
        settings.deviceSyncInFlight = false
        if settings.oracleBoardRotationEnabled { lastOracleBoardRotation = Date() }
        persistSettings()
    }

    /// 画板管理：控制当前口袋先知设备的一块画板是否参加自动轮播。
    public func setOracleCanvasBoardRotationEnabled(id: UUID, enabled: Bool) {
        guard let index = settings.oracleCanvasBoards.firstIndex(where: { $0.id == id }) else { return }
        settings.deviceSyncInFlight = true
        settings.oracleCanvasBoards[index].rotationEnabled = enabled
        captureActiveDeviceSnapshot(of: .oracle)
        settings.deviceSyncInFlight = false
        if settings.oracleBoardRotationEnabled { lastOracleBoardRotation = Date() }
        persistSettings()
    }

    /// 口袋先知多画板：删除指定画板（删除当前画板时套用新的当前画板）
    public func removeOracleCanvasBoard(at index: Int) {
        guard settings.oracleCanvasBoards.indices.contains(index) else { return }
        let wasCurrent = settings.oracleCanvasBoardIndex == index
        var boards = settings.oracleCanvasBoards
        boards.remove(at: index)
        var newIndex = 0
        if !boards.isEmpty {
            newIndex = settings.oracleCanvasBoardIndex
            if index < newIndex { newIndex -= 1 }
            else if index == newIndex { newIndex = min(newIndex, boards.count - 1) }
            newIndex = max(0, min(newIndex, boards.count - 1))
        }
        settings.deviceSyncInFlight = true
        settings.oracleCanvasBoards = boards
        settings.oracleCanvasBoardIndex = newIndex
        if wasCurrent, !boards.isEmpty {
            boards[newIndex].apply(to: settings)
        }
        captureActiveDeviceSnapshot(of: .oracle)
        settings.deviceSyncInFlight = false
        if settings.oracleBoardRotationEnabled { lastOracleBoardRotation = Date() }
        lastOraclePushedHash = nil
        persistSettings()
        renderPreview()
        refreshOracleCanvasPreview()
        ensureRand0Session()
        if boards.isEmpty {
            status = "已删除全部画板，回到默认画布"
        } else if wasCurrent {
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
        let newIndex: Int
        if let currentID, let foundIndex = boards.firstIndex(where: { $0.id == currentID }) {
            newIndex = foundIndex
        } else {
            newIndex = 0
        }
        settings.deviceSyncInFlight = true
        settings.oracleCanvasBoards = boards
        settings.oracleCanvasBoardIndex = newIndex
        captureActiveDeviceSnapshot(of: .oracle)
        settings.deviceSyncInFlight = false
        if settings.oracleBoardRotationEnabled { lastOracleBoardRotation = Date() }
        persistSettings()
    }

    /// 口袋先知多画板：当前画板名（无画板时为「默认画布」）
    public var oracleCanvasBoardName: String {
        let index = settings.oracleCanvasBoardIndex
        guard settings.oracleCanvasBoards.indices.contains(index) else { return "默认画布" }
        return settings.oracleCanvasBoards[index].name
    }

    /// 自动轮换将要显示的下一块画板名（按当前拖拽顺序循环）。
    public var nextOracleCanvasBoardName: String {
        let boards = settings.oracleCanvasBoards
        let eligible = boards.indices.filter {
            boards[$0].isSidebarVisible && boards[$0].participatesInRotation
        }
        guard eligible.count > 1 else { return "—" }
        let current = min(max(settings.oracleCanvasBoardIndex, 0), boards.count - 1)
        if let position = eligible.firstIndex(of: current) {
            return boards[eligible[(position + 1) % eligible.count]].name
        }
        return boards[eligible[0]].name
    }

    public func oracleCanvasBoards(for deviceID: UUID) -> [OracleCanvasBoard] {
        if activeDeviceID(for: .oracle) == deviceID { return settings.oracleCanvasBoards }
        return settings.devices.first(where: { $0.id == deviceID && $0.type == .oracle })?
            .settings.oracleCanvasBoards ?? []
    }

    public func visibleOracleCanvasBoards(for deviceID: UUID) -> [OracleCanvasBoard] {
        oracleCanvasBoards(for: deviceID).filter(\.isSidebarVisible)
    }

    public var oracleRotationBoardCount: Int {
        settings.oracleCanvasBoards.filter {
            $0.isSidebarVisible && $0.participatesInRotation
        }.count
    }

    /// 侧栏快捷开关：按口袋先知设备独立保存自动轮播状态。
    public func oracleDeviceBoardRotationBinding(for deviceID: UUID) -> Binding<Bool> {
        Binding(get: {
            self.settings.devices.first(where: { $0.id == deviceID && $0.type == .oracle })?
                .settings.oracleBoardRotationEnabled ?? false
        }, set: { enabled in
            guard let index = self.settings.devices.firstIndex(where: {
                $0.id == deviceID && $0.type == .oracle
            }) else { return }
            self.settings.deviceSyncInFlight = true
            self.settings.devices[index].settings.oracleBoardRotationEnabled = enabled
            if self.activeDeviceID(for: .oracle) == deviceID {
                self.settings.oracleBoardRotationEnabled = enabled
                self.captureActiveDeviceSnapshot(of: .oracle)
                self.lastOracleBoardRotation = Date()
                if enabled { self.ensureRand0Session() }
            }
            self.settings.deviceSyncInFlight = false
            self.persistSettings()
        })
    }

    public func isCurrentOracleCanvasBoard(deviceID: UUID, boardID: UUID) -> Bool {
        let boards = oracleCanvasBoards(for: deviceID)
        let index: Int
        if activeDeviceID(for: .oracle) == deviceID {
            index = settings.oracleCanvasBoardIndex
        } else {
            index = settings.devices.first(where: { $0.id == deviceID && $0.type == .oracle })?
                .settings.oracleCanvasBoardIndex ?? 0
        }
        return boards.indices.contains(index) && boards[index].id == boardID
    }

    /// 摘录多画板：新建“未命名”的空画板；第一个模块会成为默认名称。
    public func addExcerptCanvasBoard() {
        let board = ExcerptCanvasBoard.blank(from: settings)
        var boards = settings.excerptCanvasBoards
        boards.append(board)
        settings.deviceSyncInFlight = true
        settings.excerptCanvasBoards = boards
        settings.excerptCanvasBoardIndex = boards.count - 1
        board.apply(to: settings)
        captureActiveDeviceSnapshot(of: .excerpt)
        settings.deviceSyncInFlight = false
        if settings.excerptBoardRotationEnabled { lastExcerptBoardRotation = Date() }
        lastExcerptPushedHash = nil
        persistSettings()
        renderPreview()
        refreshExcerptCanvasPreview()
        status = "已创建摘录画板「\(board.name)」，后续修改将自动保存"
    }

    /// 应用当前活动摘录设备的指定画板。
    public func applyExcerptCanvasBoard(at index: Int) {
        guard settings.excerptCanvasBoards.indices.contains(index) else { return }
        let board = settings.excerptCanvasBoards[index]
        // 一块画板包含多项设置，批量套用后只持久化/渲染一次，避免连续触发二十余次重绘。
        settings.deviceSyncInFlight = true
        board.apply(to: settings)
        settings.excerptCanvasBoardIndex = index
        captureActiveDeviceSnapshot(of: .excerpt)
        settings.deviceSyncInFlight = false
        if settings.excerptBoardRotationEnabled { lastExcerptBoardRotation = Date() }
        lastExcerptPushedHash = nil
        persistSettings()
        renderPreview()
        refreshExcerptCanvasPreview()
    }

    /// 从侧栏按“设备 + 画板 ID”切换。先切设备再解析画板 ID，避免不同设备下标相同造成串扰。
    public func applyExcerptCanvasBoard(deviceID: UUID, boardID: UUID) {
        if activeDeviceID(for: .excerpt) != deviceID {
            switchDevice(type: .excerpt, to: deviceID)
        }
        guard activeDeviceID(for: .excerpt) == deviceID,
              let index = settings.excerptCanvasBoards.firstIndex(where: { $0.id == boardID }) else { return }
        applyExcerptCanvasBoard(at: index)
    }

    public func renameExcerptCanvasBoard(id: UUID, to name: String) {
        guard let index = settings.excerptCanvasBoards.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.excerptCanvasBoards[index].name = trimmed
        status = "已重命名摘录画板"
    }

    /// 画板管理：控制当前摘录设备的一块画板是否显示在侧边栏与系统菜单。
    public func setExcerptCanvasBoardSidebarVisible(id: UUID, visible: Bool) {
        guard let index = settings.excerptCanvasBoards.firstIndex(where: { $0.id == id }) else { return }
        settings.deviceSyncInFlight = true
        settings.excerptCanvasBoards[index].sidebarVisible = visible
        captureActiveDeviceSnapshot(of: .excerpt)
        settings.deviceSyncInFlight = false
        if settings.excerptBoardRotationEnabled { lastExcerptBoardRotation = Date() }
        persistSettings()
    }

    /// 画板管理：控制当前摘录设备的一块画板是否参加自动轮播。
    public func setExcerptCanvasBoardRotationEnabled(id: UUID, enabled: Bool) {
        guard let index = settings.excerptCanvasBoards.firstIndex(where: { $0.id == id }) else { return }
        settings.deviceSyncInFlight = true
        settings.excerptCanvasBoards[index].rotationEnabled = enabled
        captureActiveDeviceSnapshot(of: .excerpt)
        settings.deviceSyncInFlight = false
        if settings.excerptBoardRotationEnabled { lastExcerptBoardRotation = Date() }
        persistSettings()
    }

    public func removeExcerptCanvasBoard(at index: Int) {
        guard settings.excerptCanvasBoards.indices.contains(index) else { return }
        let wasCurrent = settings.excerptCanvasBoardIndex == index
        var boards = settings.excerptCanvasBoards
        boards.remove(at: index)
        var newIndex = 0
        if !boards.isEmpty {
            newIndex = settings.excerptCanvasBoardIndex
            if index < newIndex { newIndex -= 1 }
            else if index == newIndex { newIndex = min(newIndex, boards.count - 1) }
            newIndex = max(0, min(newIndex, boards.count - 1))
        }
        settings.deviceSyncInFlight = true
        settings.excerptCanvasBoards = boards
        settings.excerptCanvasBoardIndex = newIndex
        if wasCurrent, !boards.isEmpty {
            boards[newIndex].apply(to: settings)
        }
        captureActiveDeviceSnapshot(of: .excerpt)
        settings.deviceSyncInFlight = false
        if settings.excerptBoardRotationEnabled { lastExcerptBoardRotation = Date() }
        lastExcerptPushedHash = nil
        persistSettings()
        renderPreview()
        refreshExcerptCanvasPreview()
        if boards.isEmpty {
            status = "已删除全部摘录画板，回到默认画布"
        } else if wasCurrent {
            status = "已删除画板，当前为「\(boards[newIndex].name)」"
        } else {
            status = "已删除摘录画板"
        }
    }

    /// 拖拽排序时用画板 ID 跟随当前项，不依赖旧下标。
    public func commitExcerptCanvasBoards(_ boards: [ExcerptCanvasBoard]) {
        guard !boards.isEmpty else { return }
        let oldIndex = min(max(settings.excerptCanvasBoardIndex, 0), settings.excerptCanvasBoards.count - 1)
        let currentID = settings.excerptCanvasBoards.indices.contains(oldIndex)
            ? settings.excerptCanvasBoards[oldIndex].id : nil
        let newIndex: Int
        if let currentID, let foundIndex = boards.firstIndex(where: { $0.id == currentID }) {
            newIndex = foundIndex
        } else {
            newIndex = 0
        }
        settings.deviceSyncInFlight = true
        settings.excerptCanvasBoards = boards
        settings.excerptCanvasBoardIndex = newIndex
        captureActiveDeviceSnapshot(of: .excerpt)
        settings.deviceSyncInFlight = false
        if settings.excerptBoardRotationEnabled { lastExcerptBoardRotation = Date() }
        persistSettings()
    }

    /// 摘录多画板：按方向在可见画板中循环切换；自动轮播时还要求画板开启“轮播”。
    @discardableResult
    public func cycleExcerptCanvasBoard(direction: Int, automaticRotation: Bool = false) -> Bool {
        let boards = settings.excerptCanvasBoards
        let eligible = boards.indices.filter { index in
            let board = boards[index]
            return board.isSidebarVisible
                && (!automaticRotation || board.participatesInRotation)
        }
        guard eligible.count > 1 else { return false }
        let current = min(max(settings.excerptCanvasBoardIndex, 0), boards.count - 1)
        let anchor: Int
        if let currentPosition = eligible.firstIndex(of: current) {
            anchor = currentPosition
        } else {
            anchor = direction >= 0 ? eligible.count - 1 : 0
        }
        let nextPosition = ((anchor + direction) % eligible.count + eligible.count) % eligible.count
        let next = eligible[nextPosition]
        guard next != current else { return false }
        applyExcerptCanvasBoard(at: next)
        return true
    }

    /// 侧栏只读目标摘录设备自己的快照；活动设备读取镜像，确保刚编辑的名称立即可见。
    public func excerptCanvasBoards(for deviceID: UUID) -> [ExcerptCanvasBoard] {
        if activeDeviceID(for: .excerpt) == deviceID { return settings.excerptCanvasBoards }
        return settings.devices.first(where: { $0.id == deviceID && $0.type == .excerpt })?
            .settings.excerptCanvasBoards ?? []
    }

    public func visibleExcerptCanvasBoards(for deviceID: UUID) -> [ExcerptCanvasBoard] {
        excerptCanvasBoards(for: deviceID).filter(\.isSidebarVisible)
    }

    public var excerptCanvasBoardName: String {
        let index = settings.excerptCanvasBoardIndex
        guard settings.excerptCanvasBoards.indices.contains(index) else { return "默认画布" }
        return settings.excerptCanvasBoards[index].name
    }

    public var excerptRotationBoardCount: Int {
        settings.excerptCanvasBoards.filter {
            $0.isSidebarVisible && $0.participatesInRotation
        }.count
    }

    public var nextExcerptCanvasBoardName: String {
        let boards = settings.excerptCanvasBoards
        let eligible = boards.indices.filter {
            boards[$0].isSidebarVisible && boards[$0].participatesInRotation
        }
        guard eligible.count > 1 else { return "—" }
        let current = min(max(settings.excerptCanvasBoardIndex, 0), boards.count - 1)
        if let position = eligible.firstIndex(of: current) {
            return boards[eligible[(position + 1) % eligible.count]].name
        }
        return boards[eligible[0]].name
    }

    /// 侧边栏快捷开关：按摘录设备独立保存自动轮播状态。
    public func excerptDeviceBoardRotationBinding(for deviceID: UUID) -> Binding<Bool> {
        Binding(get: {
            self.settings.devices.first(where: { $0.id == deviceID && $0.type == .excerpt })?
                .settings.excerptBoardRotationEnabled ?? false
        }, set: { enabled in
            guard let index = self.settings.devices.firstIndex(where: {
                $0.id == deviceID && $0.type == .excerpt
            }) else { return }
            self.settings.deviceSyncInFlight = true
            self.settings.devices[index].settings.excerptBoardRotationEnabled = enabled
            if self.activeDeviceID(for: .excerpt) == deviceID {
                self.settings.excerptBoardRotationEnabled = enabled
                self.captureActiveDeviceSnapshot(of: .excerpt)
                self.lastExcerptBoardRotation = Date()
            }
            self.settings.deviceSyncInFlight = false
            self.persistSettings()
        })
    }

    public func isCurrentExcerptCanvasBoard(deviceID: UUID, boardID: UUID) -> Bool {
        let boards = excerptCanvasBoards(for: deviceID)
        let index: Int
        if activeDeviceID(for: .excerpt) == deviceID {
            index = settings.excerptCanvasBoardIndex
        } else {
            index = settings.devices.first(where: { $0.id == deviceID && $0.type == .excerpt })?
                .settings.excerptCanvasBoardIndex ?? 0
        }
        return boards.indices.contains(index) && boards[index].id == boardID
    }

    /// 推送口袋先知画板到 Rand/0 设备（按所选显示模式与灰阶算法生成帧）。
    /// 优先走持久会话（保持按键监听、发送即显示）；会话不可用时回退一次性推送。
    public func pushOracleCanvas() async {
        // 手动按钮保留强制重发能力，可用于设备刚重启但画面内容未变化的场景。
        _ = await pushOracleCanvas(preRenderedFrame: nil, skipIfUnchanged: false)
    }

    /// 内容检查已经完成渲染时直接复用帧，避免“先渲染比较、变化后再渲染推送”两次开销。
    private func pushOracleCanvas(preRenderedFrame: Data?, skipIfUnchanged: Bool) async -> Bool {
        guard !settings.rand0IP.isEmpty else {
            status = "请先在「口袋先知画板」中填写 Rand/0 设备 IP"
            return false
        }
        // 确保会话已建立：推送同时保持按键监听（自动重连由会话负责）
        ensureRand0Session()
        do {
            let frame = preRenderedFrame ?? oracleCanvasContentHash()
            let endpoint: Rand0Client.Endpoint = settings.oracleDisplayMode == .gray4 ? .gray4 : .bw
            let fingerprint = oraclePushFingerprint(frame, endpoint: endpoint)
            if skipIfUnchanged,
               !RuntimePerformancePolicy.shouldPushInkDisplay(
                previousFingerprint: lastOraclePushedHash,
                currentFingerprint: fingerprint) {
                return false
            }
            // 会话循环存活（含断线重连中）一律走会话推送：内部等待连接就绪，绝不另开竞争连接
            if let session = rand0Session, rand0SessionIP == settings.rand0IP,
               rand0SessionEndpoint == endpoint, session.isActive {
                try await session.push(frame: frame, ip: settings.rand0IP, endpoint: endpoint)
            } else {
                try await Rand0Client.pushFrame(frame, ip: settings.rand0IP, endpoint: endpoint)
            }
            status = "已推送到 Rand/0 设备（\(settings.oracleDisplayMode.title)）"
            lastOraclePushedHash = fingerprint
            return true
        } catch {
            status = Self.friendly(error)
            return false
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
        // 手动按钮允许在设备重启后强制恢复当前画面。
        await pushExcerptCanvas(preRenderedPNG: nil, skipIfUnchanged: false)
    }

    /// 复用内容检查生成的 PNG，避免变化时重复渲染和灰阶处理。
    private func pushExcerptCanvas(preRenderedPNG: Data?, skipIfUnchanged: Bool) async {
        guard !settings.dotApiKey.isEmpty, !settings.dotDeviceId.isEmpty else {
            status = "请先在「摘录画板」中填写 Dot API Key 与设备序列号"
            return
        }
        do {
            // 原始彩色推送时跳过本地灰阶/抖动处理，由 Dot 服务端按官方指南
            // 使用所选 ditherType/ditherKernel 自行转换；本地处理后推送用 NONE 保留本地抖动。
            // 浅色模式（反色）在推送图上取反。
            let rawPush = settings.excerptPushRawImage
            let png = try preRenderedPNG ?? Self.pngData(from: excerptPushImage())
            let fingerprint = excerptPushFingerprint(png, rawPush: rawPush)
            if skipIfUnchanged,
               !RuntimePerformancePolicy.shouldPushInkDisplay(
                previousFingerprint: lastExcerptPushedHash,
                currentFingerprint: fingerprint) {
                return
            }
            let pushResult = try await DotImageAPIClient.push(pngData: png,
                                                              deviceId: settings.dotDeviceId,
                                                              apiKey: settings.dotApiKey,
                                                              ditherType: rawPush ? settings.excerptServerDitherType.apiValue : "NONE",
                                                              ditherKernel: rawPush ? settings.excerptServerDitherKernel.apiValue : nil)
            status = Self.dotStatusMessage(pushResult)
            lastExcerptPushedHash = fingerprint
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

    /// 口袋先知画板自动轮换开关。默认关闭；开启后完整等待一个间隔再切换。
    public func setOracleBoardRotationEnabled(_ enabled: Bool) {
        settings.oracleBoardRotationEnabled = enabled
        lastOracleBoardRotation = Date()
        if enabled { ensureRand0Session() }
    }

    /// 摘录画板定时推送开关（开启后下一拍立即推送一次，之后按间隔）
    public func setExcerptAutoPushEnabled(_ enabled: Bool) {
        settings.excerptAutoPushEnabled = enabled
        if enabled { lastExcerptAutoPush = nil }
    }

    /// 摘录画板自动轮换开关。开启后完整等待一个设定间隔再切换。
    public func setExcerptBoardRotationEnabled(_ enabled: Bool) {
        settings.excerptBoardRotationEnabled = enabled
        lastExcerptBoardRotation = Date()
    }

    /// 独立画板自动推送：到点推送（兜底）；两次间隔之间若画布内容变化
    /// （专辑封面/时间/语录等）也立即推送。设备地址未配置时静默跳过。
    /// lastPush 为 nil 表示刚开启开关，应立即推送一次。
    private func maybeAutoPushDeviceCanvases(now: Date) async {
        var rotatedOracleBoard = false
        if settings.oracleBoardRotationEnabled,
           oracleRotationBoardCount > 1,
           !settings.rand0IP.isEmpty,
           isAutoPushDue(lastPush: lastOracleBoardRotation, now: now,
                         intervalMinutes: settings.oracleBoardRotationMinutes) {
            lastOracleBoardRotation = now
            if cycleOracleCanvasBoard(direction: 1, automaticRotation: true) {
                rotatedOracleBoard = true
                let didPush = await pushOracleCanvas(preRenderedFrame: nil,
                                                     skipIfUnchanged: true)
                // 本次轮换已经完成内容比较，无需让普通自动推送在同一秒再次处理。
                lastOracleAutoPush = now
                if didPush {
                    status = "已自动轮换并推送画板「\(oracleCanvasBoardName)」"
                }
            }
        }
        if settings.oracleAutoPushEnabled, !rotatedOracleBoard, !settings.rand0IP.isEmpty {
            if isAutoPushDue(lastPush: lastOracleAutoPush, now: now,
                             intervalMinutes: settings.oracleAutoPushMinutes) {
                lastOracleAutoPush = now
                _ = await pushOracleCanvas(preRenderedFrame: nil, skipIfUnchanged: true)
            } else if isContentCheckDue(lastCheck: lastOracleContentCheck, now: now,
                                        modules: settings.oracleCanvasModuleList) {
                lastOracleContentCheck = now
                // 已有推送基线且内容变化 → 立即推送
                let frame = oracleCanvasContentHash()
                let endpoint: Rand0Client.Endpoint = settings.oracleDisplayMode == .gray4 ? .gray4 : .bw
                let fingerprint = oraclePushFingerprint(frame, endpoint: endpoint)
                if RuntimePerformancePolicy.shouldPushInkDisplay(
                    previousFingerprint: lastOraclePushedHash,
                    currentFingerprint: fingerprint) {
                    lastOracleAutoPush = now
                    _ = await pushOracleCanvas(preRenderedFrame: frame, skipIfUnchanged: true)
                }
            }
        }
        var rotatedExcerptBoard = false
        if settings.excerptBoardRotationEnabled,
           excerptRotationBoardCount > 1,
           !settings.dotApiKey.isEmpty, !settings.dotDeviceId.isEmpty,
           isAutoPushDue(lastPush: lastExcerptBoardRotation, now: now,
                         intervalMinutes: settings.excerptBoardRotationMinutes) {
            lastExcerptBoardRotation = now
            if cycleExcerptCanvasBoard(direction: 1, automaticRotation: true) {
                rotatedExcerptBoard = true
                await pushExcerptCanvas(preRenderedPNG: nil, skipIfUnchanged: true)
                lastExcerptAutoPush = now
                status = "已自动轮换并推送摘录画板「\(excerptCanvasBoardName)」"
            }
        }
        if settings.excerptAutoPushEnabled, !rotatedExcerptBoard,
           !settings.dotApiKey.isEmpty, !settings.dotDeviceId.isEmpty {
            if isAutoPushDue(lastPush: lastExcerptAutoPush, now: now,
                             intervalMinutes: settings.excerptAutoPushMinutes) {
                lastExcerptAutoPush = now
                await pushExcerptCanvas(preRenderedPNG: nil, skipIfUnchanged: true)
            } else if isContentCheckDue(lastCheck: lastExcerptContentCheck, now: now,
                                        modules: settings.excerptCanvasModuleList) {
                lastExcerptContentCheck = now
                let png = excerptCanvasContentHash()
                let fingerprint = png.map {
                    excerptPushFingerprint($0, rawPush: settings.excerptPushRawImage)
                }
                if RuntimePerformancePolicy.shouldPushInkDisplay(
                    previousFingerprint: lastExcerptPushedHash,
                    currentFingerprint: fingerprint), let png {
                    lastExcerptAutoPush = now
                    await pushExcerptCanvas(preRenderedPNG: png, skipIfUnchanged: true)
                }
            }
        }
    }

    private func isAutoPushDue(lastPush: Date?, now: Date, intervalMinutes: Int) -> Bool {
        guard let lastPush else { return true }
        return now.timeIntervalSince(lastPush) >= TimeInterval(max(1, intervalMinutes) * 60)
    }

    /// 内容变化检查按模块动态节流：播放/秒钟/系统指标保持 5 秒，静态内容降到 30 秒。
    private func isContentCheckDue(lastCheck: Date?, now: Date,
                                   modules: [CanvasModule]) -> Bool {
        guard let lastCheck else { return true }
        let interval = RuntimePerformancePolicy.deviceCanvasContentCheckInterval(
            modules: modules,
            timeFormat: settings.timeFormat,
            nowPlaying: nowPlaying.isPlaying,
            pomodoroRunning: pomodoroSnapshot.isRunning)
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// 口袋先知画布当前内容指纹（灰阶帧字节；封面/时间/语录变化都会改变）
    private func oracleCanvasContentHash() -> Data {
        autoreleasepool {
            let image = renderOracleCanvasImage()
            return ScreenRenderer.oracleFrame(from: image,
                                              algorithm: settings.oracleGrayAlgorithm,
                                              mode: settings.oracleDisplayMode,
                                              dither: settings.oracleDitherKernel)
        }
    }

    /// 摘录画布当前内容指纹（推送 PNG 字节）
    private func excerptCanvasContentHash() -> Data? {
        autoreleasepool { try? Self.pngData(from: excerptPushImage()) }
    }

    /// 指纹除最终帧外还包含目标地址和显示端点；同一画面切换到另一台设备或
    /// 切换黑白/四级灰模式时仍会推送一次。
    private func oraclePushFingerprint(_ frame: Data,
                                       endpoint: Rand0Client.Endpoint) -> Data {
        var input = frame
        input.append(Data("|\(settings.rand0IP)|\(endpoint.rawValue)".utf8))
        return Data(SHA256.hash(data: input))
    }

    /// Dot 服务端抖动参数不会改变上传 PNG 本身，因此也必须进入内容指纹。
    private func excerptPushFingerprint(_ png: Data, rawPush: Bool) -> Data {
        var input = png
        let processing = rawPush
            ? "\(settings.excerptServerDitherType.apiValue)|\(settings.excerptServerDitherKernel.apiValue)"
            : "NONE"
        input.append(Data("|\(settings.dotDeviceId)|\(processing)".utf8))
        return Data(SHA256.hash(data: input))
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

    private func push(force: Bool, silentIfUnchanged: Bool = false,
                      sampleBambuCameraBeforePush: Bool = true) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await uploadRendered(force: force,
                                     silentIfUnchanged: silentIfUnchanged,
                                     sampleBambuCameraBeforePush: sampleBambuCameraBeforePush)
        } catch {
            status = Self.friendly(error)
        }
    }

    /// 等待当前上传完成后再推送，设置变化不会因为恰逢 busy 而被直接丢弃。
    private func pushWhenAvailable(force: Bool, silentIfUnchanged: Bool = false,
                                   sampleBambuCameraBeforePush: Bool = true) async {
        while busy {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch { return }
            if Task.isCancelled { return }
        }
        await push(force: force, silentIfUnchanged: silentIfUnchanged,
                   sampleBambuCameraBeforePush: sampleBambuCameraBeforePush)
    }

    private func uploadRendered(force: Bool, silentIfUnchanged: Bool = false,
                                sampleBambuCameraBeforePush: Bool = true) async throws {
        // 自动聚焦模式必须先抓当前静态帧并完成安全裁切，再渲染、哈希和上传。
        // 因此键盘收到的每一张 Bambu 摄像头卡片都对应本次推送前的采样结果。
        if sampleBambuCameraBeforePush {
            await prepareCurrentBambuCameraFrameForPush()
        }
        // 键盘仅支持 JPEG（质量可调，100 = 4:4:4 无彩色抽样、画质接近无损）
        // 渲染结果同时供软件预览和上传使用，消除原先推送秒的重复整卡渲染。
        let jpeg = try renderAndUpdatePreview().data
        let hash = Self.sha256(jpeg)
        lastPushAttempt = Date()
        if settings.displayMode == .pomodoro {
            let snapshot = pomodoroSnapshot
            lastPomodoroPushAlignedSeconds = snapshot.isRunning
                ? PomodoroRefreshPolicy.alignedRemainingSeconds(
                    snapshot.remaining, duration: snapshot.duration,
                    intervalSeconds: settings.pomodoroUploadSeconds)
                : nil
        }
        if !force && hash == lastUploadedHash {
            if !silentIfUnchanged {
                status = "画面未变化，无需重复推送"
            }
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
        guard qwenQuota.available else { return "尚未读取" }
        let plan = qwenQuota.plan.map { "\($0) · " } ?? ""
        return "\(plan)剩余 \(String(format: "%.2f", qwenQuota.remainingCredits)) \(qwenQuota.unit)"
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

    // MARK: - 全局快捷键（番茄钟 / 灵犀68 手动翻页）

    func shortcut(for action: GlobalHotkeyManager.Action) -> GlobalShortcut {
        switch action {
        case .togglePomodoro: return settings.pomodoroToggleShortcut
        case .skipPomodoro: return settings.pomodoroSkipShortcut
        case .resetPomodoro: return settings.pomodoroResetShortcut
        case .keyboardPageUp: return settings.keyboardPageUpShortcut
        case .keyboardPageDown: return settings.keyboardPageDownShortcut
        }
    }

    func setShortcut(_ shortcut: GlobalShortcut, for action: GlobalHotkeyManager.Action) {
        switch action {
        case .togglePomodoro: settings.pomodoroToggleShortcut = shortcut
        case .skipPomodoro: settings.pomodoroSkipShortcut = shortcut
        case .resetPomodoro: settings.pomodoroResetShortcut = shortcut
        case .keyboardPageUp: settings.keyboardPageUpShortcut = shortcut
        case .keyboardPageDown: settings.keyboardPageDownShortcut = shortcut
        }
        // 触发 onChange → 持久化 + applyGlobalShortcuts 重新注册
    }

    public func resetPomodoroShortcuts() {
        settings.pomodoroToggleShortcut = .defaultToggle
        settings.pomodoroSkipShortcut = .defaultSkip
        settings.pomodoroResetShortcut = .defaultReset
    }

    public func resetKeyboardPageShortcuts() {
        settings.keyboardPageUpShortcut = .defaultPageUp
        settings.keyboardPageDownShortcut = .defaultPageDown
    }

    /// 用户主动启用/关闭灵犀68 Fn + 旋钮翻页。首次启用时请求输入监控权限。
    public func setLingxi68KnobPagingEnabled(_ enabled: Bool) {
        if enabled, Lingxi68KnobController.inputAccess != .granted {
            _ = Lingxi68KnobController.requestInputAccess()
            refreshInputMonitoringStatus()
        }
        settings.lingxi68KnobPagingEnabled = enabled
    }

    /// 授权或关闭冲突软件后手动重连，不改变开关状态。
    public func reconnectLingxi68KnobPaging() {
        guard settings.lingxi68KnobPagingEnabled else { return }
        refreshInputMonitoringStatus()
        lingxi68KnobController?.restart()
    }

    /// 从系统设置返回应用时刷新 TCC 状态；刚获得权限则自动重新打开 HID 接口。
    public func refreshInputMonitoringStatus() {
        let granted = Lingxi68KnobController.inputAccess == .granted
        let changed = granted != inputMonitoringAuthorized
        inputMonitoringAuthorized = granted
        if changed, settings.lingxi68KnobPagingEnabled {
            lingxi68KnobController?.restart()
        }
    }

    private func setupLingxi68KnobController() {
        let controller = Lingxi68KnobController()
        controller.onPage = { [weak self] direction in
            Task { @MainActor [weak self] in
                guard let self, self.settings.lingxi68KnobPagingEnabled else { return }
                self.status = direction > 0 ? "Fn + 旋钮：下一页" : "Fn + 旋钮：上一页"
                self.manualKeyboardPage(direction: direction)
            }
        }
        controller.onStatus = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.lingxi68KnobPagingStatus = message
            }
        }
        lingxi68KnobController = controller
    }

    /// 设置变化时幂等同步 HID 控制器；关闭立即释放独占，恢复系统音量控制。
    private func applyLingxi68KnobPaging() {
        // 用户已在旧构建中开启该功能、但新构建尚无 TCC 记录时，启动阶段也应触发正确的 IOHID 授权请求。
        if settings.lingxi68KnobPagingEnabled,
           Lingxi68KnobController.inputAccess == .unknown {
            _ = Lingxi68KnobController.requestInputAccess()
            inputMonitoringAuthorized = Lingxi68KnobController.inputAccess == .granted
        }
        lingxi68KnobController?.setEnabled(settings.lingxi68KnobPagingEnabled)
    }

    /// 把设置中的快捷键组合应用到全局注册（组合未变化时跳过）
    public func applyGlobalShortcuts() {
        GlobalHotkeyManager.apply(shortcuts: [
            .togglePomodoro: settings.pomodoroToggleShortcut,
            .skipPomodoro: settings.pomodoroSkipShortcut,
            .resetPomodoro: settings.pomodoroResetShortcut,
            .keyboardPageUp: settings.keyboardPageUpShortcut,
            .keyboardPageDown: settings.keyboardPageDownShortcut
        ])
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
    /// - Parameters:
    ///   - cropRatio: 目标画板宽高比（nil = 键盘 142×(428-安全区)）
    ///   - owner: 图片归属画板（键盘走自定义图片，先知/摘录存各自画板图片）
    private func showCropEditor(image: NSImage, sourceURL: URL,
                                cropRatio: CGFloat? = nil,
                                owner: CanvasOwner = .keyboard) {
        let editor = CropEditorView(
            sourceImage: image,
            cropRatio: cropRatio ?? (142.0 / CGFloat(428 - settings.safeAreaHeight)),
            onConfirm: { [weak self] cropped in
                Task { @MainActor in
                    await self?.applyCroppedImage(cropped, sourceURL: sourceURL, owner: owner)
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

    /// 把裁切后的图片保存为对应画板的图片并推送
    private func applyCroppedImage(_ cropped: CGImage, sourceURL: URL,
                                   owner: CanvasOwner = .keyboard) async {
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
        await setCanvasImage(url: tempURL, displayName: sourceURL.lastPathComponent, owner: owner)
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
            lastCustomImageRevision = currentCustomImageRevision()
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
        lastCustomImageRevision = currentCustomImageRevision()
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

    /// 某台键盘设备侧栏显示的卡片（有序可见列表；nil = 旧设备未配置，回退侧栏排序的全部卡片，含正在播放）
    func keyboardCardList(for deviceID: UUID) -> [Panel] {
        // 旧设备（未记录卡片列表）回退：按侧栏排序派生全部卡片（含正在播放）
        let fallback = Panel.orderedKeyboardItems(settings.sidebarOrder)
            .filter { $0 != .devices && $0 != .cardRotation }
            .map(\.rawValue)
        return settings.keyboardCardPanelRawValues(for: deviceID, fallback: fallback)
            .compactMap(Panel.init(rawValue:))
    }

    /// 活动键盘设备的可见卡片列表
    var activeKeyboardCardList: [Panel] {
        guard let device = activeDevice(for: .keyboard) else { return [] }
        return keyboardCardList(for: device.id)
    }

    /// 活动键盘设备未显示在侧栏的卡片（供「添加到侧栏」）
    var keyboardHiddenCardList: [Panel] {
        let visible = Set(activeKeyboardCardList.map(\.rawValue))
        let printerCount = enabledDevices(for: .bambuLab).count
        let formlabsCount = enabledDevices(for: .formlabs).count
        return Panel.orderedKeyboardItems(settings.sidebarOrder)
            .filter { $0 != .devices && $0 != .cardRotation && !visible.contains($0.rawValue)
                && (($0.bambuSlotIndex.map { $0 < printerCount }) ?? true)
                && (($0.formlabsSlotIndex.map { $0 < formlabsCount }) ?? true) }
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

    /// 检测到的新版本（nil = 未发现更新）
    @Published public var updateAvailable: GitHubReleaseInfo?
    /// 更新检查状态说明（nil = 未检查；"已是最新版本" 等）
    @Published public var updateStatusText: String?
    /// 更新检查进行中
    @Published public var updateChecking = false

    /// 检查 GitHub 仓库是否有新版本（force = 忽略节流立即检查）
    public func checkForUpdate(force: Bool = false) async {
        guard !updateChecking else { return }
        if !force, let last = settings.lastUpdateCheckAt,
           Date().timeIntervalSince(last) < 6 * 3600 { return }
        updateChecking = true
        defer { updateChecking = false }
        settings.lastUpdateCheckAt = Date()
        do {
            let release = try await GitHubReleaseClient.fetchLatestRelease()
            if GitHubReleaseClient.isNewer(latest: release.tag,
                                           than: ReleaseNotes.currentShortVersion) {
                updateAvailable = release
                updateStatusText = "发现新版本 \(release.tag)"
                status = "发现新版本 \(release.tag)，可在「设置 → 关于」中查看下载"
            } else {
                updateAvailable = nil
                updateStatusText = "已是最新版本"
            }
        } catch {
            // 手动检查（force）失败：显示明确提示不静默；自动启动检查保持静默
            if force {
                if let e = error as? GitHubReleaseError {
                    updateStatusText = e.errorDescription ?? "无法连接 GitHub，请检查网络"
                } else {
                    updateStatusText = "无法连接 GitHub，请检查网络"
                }
            } else {
                updateStatusText = nil
            }
        }
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

    /// 全局翻页快捷键：与菜单栏操作共用目标键盘，然后循环切换上一张/下一张卡片。
    public func manualKeyboardPage(direction: Int) {
        ensureMenuBarKeyboard()
        keyboardPage(direction: direction)
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

    /// 菜单栏直接选择某台口袋先知的指定画板，并立即推送到对应设备。
    public func menuBarSelectOracleBoard(deviceID: UUID, boardID: UUID) {
        applyOracleCanvasBoard(deviceID: deviceID, boardID: boardID)
        guard activeDeviceID(for: .oracle) == deviceID,
              settings.oracleCanvasBoards.contains(where: { $0.id == boardID }) else { return }
        Task { await pushOracleCanvas() }
    }

    /// 菜单栏直接选择某台摘录设备的指定画板，并立即推送到对应设备。
    public func menuBarSelectExcerptBoard(deviceID: UUID, boardID: UUID) {
        applyExcerptCanvasBoard(deviceID: deviceID, boardID: boardID)
        guard activeDeviceID(for: .excerpt) == deviceID,
              settings.excerptCanvasBoards.contains(where: { $0.id == boardID }) else { return }
        Task { await pushExcerptCanvas() }
    }

    /// 菜单栏直接选择某台 AI Mac 小屏幕的指定彩色画板并立即推送。
    public func menuBarSelectAIMacBoard(deviceID: UUID, boardID: UUID) {
        applyAIMacCanvasBoard(deviceID: deviceID, boardID: boardID)
        guard activeDeviceID(for: .aiMacScreen) == deviceID,
              aiMacCanvasBoards(for: deviceID).contains(where: { $0.id == boardID }) else { return }
        Task { await pushAIMacScreen(deviceID: deviceID, force: true) }
    }

    // MARK: - 模式 / 主题 / 登录自启

    public func setMode(_ mode: DisplayMode, reactivateIfUnchanged: Bool = false) {
        let changed = settings.displayMode != mode
        guard changed || reactivateIfUnchanged else { return }
        if changed {
            settings.displayMode = mode
            persistSettings()
        }
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
        // 打印完成庆祝卡：打印成功后短暂展示 🎉（与夸夸同模式），并显示完成的任务名
        if let name = printSuccessName, let until = printSuccessUntil, Date() < until {
            return try ScreenRenderer.renderPrintSuccess(printerName: name,
                                                         taskName: printSuccessTask,
                                                         picture: printSuccessImage,
                                                         settings: settings)
        }
        // HA 异常告警：监控到异常时优先显示告警卡（打印机名 + 错误码，醒目样式），恢复后自动消失
        if !haAlertTitle.isEmpty {
            return try ScreenRenderer.renderHAAlert(title: haAlertTitle, message: haAlertMessage,
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
        case .homeAssistant:
            return try ScreenRenderer.renderHA(haSnapshot.selectedEntities,
                                               aliases: haSnapshot.aliases,
                                               missing: haSnapshot.missingRows(),
                                               images: haSnapshot.images,
                                               errorText: haSnapshot.errorText,
                                               settings: settings)
        case .bambuLab, .bambuLab2, .bambuLab3, .bambuLab4, .bambuLab5:
            let config = bambuConfig(for: settings.displayMode)
            let rawFrame = config.showImage
                ? haSnapshot.picture(for: config.selectedImageEntityID) : nil
            let staticFrame = config.autoCameraZoom && config.imageSource == .camera
                ? (bambuAutoZoomImages[config.selectedImageEntityID] ?? rawFrame)
                : rawFrame
            return try ScreenRenderer.renderBambuLab(config,
                                                     entities: haSnapshot.entities,
                                                     image: staticFrame,
                                                     settings: settings,
                                                     dataUpdatedAt: haSnapshot.sampledAt)
        case .formlabs, .formlabs2, .formlabs3, .formlabs4, .formlabs5:
            if let device = formlabsDevice(for: settings.displayMode) {
                return try ScreenRenderer.renderFormlabs(
                    deviceName: device.name,
                    connection: device.settings.formlabsConnection ?? FormlabsConnectionSettings(),
                    snapshot: formlabsSnapshots[device.id] ?? .empty,
                    settings: settings)
            }
            return try ScreenRenderer.renderFormlabs(
                deviceName: "Formlabs 打印机",
                connection: FormlabsConnectionSettings(), snapshot: .empty, settings: settings)
        case .excerptQuote:
            return try ScreenRenderer.renderExcerptQuote(quote: quoteDisplayText, settings: settings, now: Date())
        case .sspai:
            return try ScreenRenderer.renderSspai(articles: keyboardSspaiArticles, settings: settings, now: Date())
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
                sspaiArticles: sspaiDisplayArticles(for: .keyboard),
                ha: haSnapshot(forCanvas: .keyboard),
                formlabsItems: formlabsCanvasItems(),
                artworkImage: cachedArtworkImage(for: nowPlaying.artwork))
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

    private func renderAndUpdatePreview() throws -> RenderResult {
        let result = try autoreleasepool { try renderCurrent() }
        previewImage = NSImage(cgImage: result.image, size: NSSize(width: 142, height: 428))
        lastPreviewRender = Date()
        return result
    }

    private func renderPreviewIfDue(now: Date) {
        let interval = RuntimePerformancePolicy.previewInterval(
            mode: settings.displayMode,
            canvasModules: settings.canvasModuleList,
            timeFormat: settings.timeFormat,
            nowPlaying: nowPlaying.isPlaying,
            pomodoroRunning: pomodoroSnapshot.isRunning,
            dynamicUploadSeconds: settings.dynamicUploadSeconds,
            pomodoroUploadSeconds: settings.pomodoroUploadSeconds)
        if let lastPreviewRender, now.timeIntervalSince(lastPreviewRender) < interval { return }
        renderPreview()
    }

    private func renderPreview() {
        do {
            _ = try renderAndUpdatePreview()
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
        inputMonitoringAuthorized
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」
    public func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    /// 打开「系统设置 → 隐私与安全性 → 输入监控」
    public func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
        lingxi68KnobPagingStatus = "请在输入监控中开启“多屏灵犀”，返回软件后将自动重连"
    }

    private func openPrivacyPane(_ identifier: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(identifier)") else { return }
        NSWorkspace.shared.open(url)
        status = "请在系统设置中允许 LinxDisplay，并勾选快捷操作"
    }
}

/// 全局时间/日期格式的实时预览文本（设置页用）
public enum TimeFormatProbe {
    public static func format(_ pattern: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = pattern.isEmpty ? "HH:mm" : pattern
        return formatter.string(from: now)
    }
}
