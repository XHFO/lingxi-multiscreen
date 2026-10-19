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
        defaultStatusEntities = BambuEntityMatcher.automaticPrintStatusCandidates(
            printerEntities)
        allStatusEntities = BambuEntityMatcher.printStatusCandidates(
            printerEntities, useDefaultFilter: false)
    }
}

private struct BambuCameraZoomRuntime {
    var state = BambuCameraZoomState()
    var taskName = ""
}

private struct AIMacSmartRotationTarget: Equatable {
    var contentMode: AIMacScreenContentMode
    var cardMode: DisplayMode
    var c6NativeCardID: String?

    init(_ settings: AIMacScreenDeviceSettings) {
        contentMode = settings.mode
        cardMode = settings.cardMode
        c6NativeCardID = settings.mode == .card ? settings.c6NativeCardID : nil
    }
}

/// 应用总控：每秒时钟驱动渲染与推送，逻辑对齐原版 MainViewModel。
@MainActor
public final class AppModel: ObservableObject {
    private let store: SettingsStore
    private let codex = CodexRateLimitClient()
    private let ccSwitchQuota = CCSwitchQuotaClient()
    private let quotaClient = QwenWorkQuotaClient()
    private let nowPlayingClient = NowPlayingClient()
    private let lyricsClient = LyricsClient()
    private let imageApi = ImageApiClient()
    private let formlabsClient = FormlabsClient()
    private let esp8266Flasher = ESP8266FirmwareFlasher()
    private let m5FirmwareFlasher = ESP8266FirmwareFlasher()
    private var aiMacDiscoveryTask: Task<String, Error>?
    private let monitor = SystemMonitor()
    private let startup = StartupManager()
    private let pomodoro: PomodoroService
    /// 灵犀68 Fn + 旋钮翻页：运行期 HID 独占控制器（默认不启动）。
    private var lingxi68KnobController: Lingxi68KnobController?

    private var timer: Timer?
    /// 歌词行切换不再排在全局每秒任务之后，避免被 HA/打印机等网络刷新拖慢。
    private var lyricsTimer: Timer?
    /// 用量数据（Codex 用量 + 千问办公额度）统一刷新时间：各功能共用同一刷新周期
    private var lastQuotaRefresh: Date?
    private var lastPushAttempt: Date?
    /// 键盘独立番茄钟上次已推送的倒计刻度，与全局推送周期解耦。
    private var lastPomodoroPushAlignedSeconds: Int?
    private var lastUploadedHash: String?
    private var lastNowPlayingFetch: Date?
    /// 歌词只在换歌时查询；逐行进度在本机计算，并按目标键盘去重推送。
    private var lyricsRequestedSongKey: String?
    private var lyricsFetchTask: Task<Void, Never>?
    private var linkedLyricsLastLineKeys: [UUID: String] = [:]
    private var linkedLyricsBusyIDs: Set<UUID> = []
    /// 歌词属于强时效画面：每台键盘各自只保留最新帧，互不等待、互不共用延迟。
    private var linkedLyricsScheduledLineKeys: [UUID: String] = [:]
    private var linkedLyricsPushTasks: [UUID: Task<Void, Never>] = [:]
    private var linkedLyricsRetryLineKeys: [UUID: String] = [:]
    private var linkedLyricsRetryNotBefore: [UUID: Date] = [:]
    /// 每台灵犀 68 的渲染 + 上传耗时 EWMA，用来把换帧完成点贴近歌词时间戳。
    private var linkedLyricsUploadLatency: [UUID: TimeInterval] = [:]
    private var lastRemoteNowPlaying: NowPlayingInfo?
    private var nowPlayingChangeObservers: [NSObjectProtocol] = []
    private var playerChangeObservers: [NSObjectProtocol] = []
    private var nowPlayingEventRefreshTask: Task<Void, Never>?
    private var nowPlayingEventRefreshID: UUID?
    private var nowPlayingEventRefreshThrottle = NowPlayingEventRefreshThrottle()
    /// 换歌智能抢占只消费一次歌曲标识；并发的 MediaRemote 通知不会让同一首歌重复切卡。
    private var lastSmartRotationSongKey: String?
    /// 播放器可能先公布一首已暂停的新歌，随后才发“开始播放”；暂存该标识以免漏掉真正开播。
    private var pendingSmartRotationSongKey: String?
    private var lastPreviewRender: Date?
    private var lastImageRotation: Date?
    /// 当前自定义图片的文件修订指纹。即使路径不变，只要内容被替换也会重新取色。
    private var lastCustomImageRevision: String?
    /// AI Mac 小屏幕按设备保存能力、内容指纹与推送节流状态，不与键盘上传状态混用。
    private var aiMacScreenCapabilities: [UUID: AIMacScreenCapabilities] = [:]
    private var bambuMQTTClients: [UUID: BambuMQTTClient] = [:]
    private var bambuMQTTClientSettings: [UUID: BambuMQTTSettings] = [:]
    private var bambuMQTTEntities: [UUID: [HAEntity]] = [:]
    private var bambuMQTTAccessCodes: [UUID: String] = [:]
    @Published public var bambuMQTTStatuses: [UUID: String] = [:]
    @Published public var bambuMQTTCertificates: [UUID: String] = [:]
    private var aiMacButtonTask: Task<Void, Never>?
    private var aiMacButtonState: [UUID: (host: String, snapshot: C6ButtonSnapshot, time: Date)] = [:]
    private var c6MenuPausedIDs = Set<UUID>()
    private var c6MenuHosts: [UUID: String] = [:]
    private var aiMacScreenLastHashes: [UUID: String] = [:]
    private var aiMacScreenLastPushAt: [UUID: Date] = [:]
    /// 画板首次出现 HA 图片时使用每台设备一条 latest-only 准备队列；避免每秒 tick
    /// 对同一缺失静态帧重复发起下载，也保证快速切板只推送最后选择的画板。
    private var aiMacCanvasPicturePreparationTasks: [UUID: Task<Void, Never>] = [:]
    private var aiMacCanvasPicturePreparationGenerations: [UUID: UInt64] = [:]
    /// 每台小屏幕的渲染 + 上传耗时，用于让图片内进度指向预计换帧完成时刻。
    private var aiMacScreenUploadLatency: [UUID: TimeInterval] = [:]
    private var aiMacScreenLastBoardRotation: [UUID: Date] = [:]
    private var aiMacScreenLastCardRotation: [UUID: Date] = [:]
    /// 设备端时钟只需低频校时；逐秒走时与重绘由小屏幕自身完成。
    private var aiMacScreenLastClockSyncAt: [UUID: Date] = [:]
    /// 系统锁屏/睡眠期间暂停画面推送，并按设备记住熄屏前亮度。
    private var aiMacScreensSystemSleeping = false
    private var aiMacScreenSavedBrightness: [UUID: Int] = [:]
    /// 同一台设备的背光请求严格按事件顺序执行，避免快速锁屏/解锁时旧请求后到覆盖新状态。
    private var aiMacScreenPowerTasks: [UUID: Task<Bool, Never>] = [:]
    private var aiMacScreenPowerGenerations: [UUID: UInt] = [:]
    /// 色彩滑杆连续变化时只重绘目标小屏幕预览；设置写盘与网络推送按设备合并，
    /// 避免每个刻度都触发键盘、墨水屏和其他 AI Mac 的全量预览链路。
    private var aiMacColorCalibrationCommitTasks: [UUID: Task<Void, Never>] = [:]
    private var aiMacColorCalibrationPreviewTasks: [UUID: Task<Void, Never>] = [:]
    private var aiMacColorCalibrationPreviewGenerations: [UUID: UInt] = [:]
    private var aiMacColorCalibrationPendingIDs: Set<UUID> = []
    /// 已开始的上传不强行中断；下一代设置在它结束后补推，保证滑杆最终值不会
    /// 因设备短暂 busy 而丢失。
    private var aiMacColorCalibrationPushTasks: [UUID: Task<Void, Never>] = [:]
    private var aiMacColorCalibrationPushGenerations: [UUID: UInt] = [:]
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
    /// M5Stack StickS3 蓝牙控制器会话全局唯一；仅有设备或用户主动扫描时才创建。
    private var m5BLEClient: M5ControllerBLEClient?
    @Published public var m5ControllerConnected = false
    @Published public var m5ControllerHIDReady = false
    @Published public var m5ControllerHIDSecured = false
    @Published public var m5ControllerScanning = false
    @Published public var m5DiscoveredControllers: [M5DiscoveredController] = []
    @Published public var m5BluetoothState: M5ControllerBluetoothState = .unknown
    public enum M5RepairPhase: Equatable {
        /// 先让用户从 macOS 蓝牙设置中忽略旧的 HID 记录。
        case removeSystemRecord
        /// 旧记录已移除，正在重新发现控制器。
        case scanning
        /// 已选中控制器，等待自定义控制通道与系统 HID 配对都就绪。
        case waitingForSystemPairing
    }
    /// 重新配对是一个明确的三阶段流程：清除控制器端密钥、由用户在 macOS
    /// 蓝牙设置中忽略系统记录、重新连接并等待 HID 输入服务就绪。
    /// CoreBluetooth 无权代替用户删除系统蓝牙记录。
    @Published public private(set) var m5RepairingControllerID: UUID?
    @Published public private(set) var m5RepairingPeripheralName: String?
    @Published public private(set) var m5RepairPhase: M5RepairPhase?
    /// 软件详情页直接复用最近一次发给 StickS3 的完整载荷，避免预览与实机菜单漂移。
    @Published public private(set) var m5ControllerPreviewInfo: M5ControllerInfo?
    private var lastM5InfoSent: Data?
    private enum M5ControllerPage {
        case mainMenu, devices, homeAssistant, mediaControls, gyroMouse, macShortcuts
        case presentation, vibeCoding, customShortcuts
    }
    /// 主菜单顺序同时决定 StickS3 实机与软件预览的第一页内容。
    /// Vibe Coding 是高频入口，因此直接提升到主菜单第一项。
    private enum M5MainMenuItem: CaseIterable {
        case vibeCoding, devices, homeAssistant, macShortcuts
    }
    /// “Mac 快捷键”内的功能。多媒体与飞鼠指针均由 StickS3 原生 HID 执行。
    private enum M5ShortcutMenuItem: CaseIterable {
        case mediaControls, gyroMouse, presentation, custom
    }
    private var m5ControllerPage: M5ControllerPage = .mainMenu
    private var m5MainSelectionIndex = 0
    private var m5DeviceSelectionIndex = 0
    private var m5ShortcutMenuSelectionIndex = 0
    private var m5ShortcutActionSelectionIndex = 0
    private var m5MediaSelectionIndex = 0
    private var m5HASelectionIndex = 0
    /// 每台控制器独立的重新居中请求序号；避免多设备之间误触发校准。
    private var m5GyroRecenterTokens: [UUID: UInt32] = [:]
    private var m5HAActionInFlight = false
    private var m5HAActionMessage: String?
    private var m5ShortcutActionMessage: String?
    /// “语音输入”是按住执行：记录已发送 keyDown、尚未发送 keyUp 的动作。
    private var m5HeldShortcut: M5MacShortcut?
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
    /// 完成宽限按 ManagedDevice UUID 隔离。这里只保存成功网络观察产生的状态；
    /// 槽位、当前显示设备和磁盘里的旧任务缓存都不能互相借用时间窗口。
    private var printerRotationStates: [UUID: SmartCardRotationPolicy.PrinterRotationState] = [:]
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
    /// 同一图片实体的并发请求以“后启动的一轮”为准，避免慢旧帧覆盖新帧。
    private var haPictureRequestGenerations: [String: UInt64] = [:]
    private var c6PictureTaskKeys: [String: [String: String]] = [:]
    private var c6PictureOrigins: [String: String] = [:]

    private var c6CurrentPictureOrigin: String {
        let connection = c6HomeAssistantConnection
        return Self.sha256(Data((connection?.url ?? settings.haServerURL).utf8)
            + Data([0]) + Data((connection?.token ?? settings.haToken).utf8))
    }
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
    /// 首帧补发只允许一条任务运行；断线/重连回调可能在发送 await 期间交错。
    private var rand0SessionPrimeInFlight = false
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
    private var c6PendingForcedPushIDs: Set<UUID> = []
    /// AWTRIX NG 独立控制状态（按受管设备隔离，不依赖 Home Assistant）。
    @Published public var awtrixSnapshots: [UUID: AWTRIXSnapshot] = [:]
    @Published public var awtrixStatuses: [UUID: String] = [:]
    @Published public var awtrixBusyIDs: Set<UUID> = []
    /// 每台设备独立的 latest-wins 应用激活任务。展开设备触发的刷新或上一项
    /// 激活尚未结束时，新点击不会被丢弃；同一设备只保留最后一次选择。
    var awtrixDisplayRequestTasks: [UUID: Task<Void, Never>] = [:]
    var awtrixDisplayRequestPolicy = AWTRIXLatestDisplayRequestPolicy()
    var awtrixSettingsSaveTasks: [UUID: Task<Void, Never>] = [:]
    var awtrixContentSaveTasks: [UUID: Task<Void, Never>] = [:]
    var awtrixConfigSaveTasks: [String: Task<Void, Never>] = [:]
    var awtrixHASyncTasks: [UUID: Task<Void, Never>] = [:]
    var awtrixHALastAttempt: [UUID: Date] = [:]
    var awtrixHALastContent: [UUID: String] = [:]
    var awtrixWeatherTasks: [UUID: Task<Void, Never>] = [:]
    var awtrixWeatherLastAttempt: [UUID: Date] = [:]
    var awtrixWeatherLastContent: [UUID: WeatherSnapshot] = [:]
    var awtrixHAEntities: [UUID: [HAEntity]] = [:]
    var awtrixLoopSaveTasks: [UUID: Task<Void, Never>] = [:]
    var awtrixDesiredLoopOrders: [UUID: [String]] = [:]
    var awtrixRequestedCardNames: [UUID: String] = [:]
    var awtrixManualDisplayActiveIDs: Set<UUID> = []
    var awtrixManualDisplayReturnTasks: [UUID: Task<Void, Never>] = [:]
    var awtrixManualDisplayEpochs: [UUID: UUID] = [:]
    var awtrixPreparingForQuit = false
    /// AWTRIX 独立应用详情按「设备 ID + 应用名」隔离，避免多设备同名脚本串扰。
    @Published public var awtrixAppConfigurations: [UUID: [String: AWTRIXAppConfiguration]] = [:]
    @Published public var awtrixAppConfigDrafts: [UUID: [String: [String: AWTRIXJSONValue]]] = [:]
    @Published public var awtrixAppStatuses: [UUID: [String: String]] = [:]
    @Published public var awtrixAppBusyKeys: Set<String> = []
    /// 设备真实 32×8 屏幕帧，直接来自 AWTRIX 的屏幕 API。
    @Published public var awtrixLivePreviewImages: [UUID: NSImage] = [:]
    @Published public var awtrixLivePreviewStatuses: [UUID: String] = [:]
    /// 实时预览拥有独立的请求互斥，不与完整设备刷新共用 busy 状态；否则一次较慢的
    /// `/device + /apps + /settings` 刷新会让 250ms 画面轮询长期停顿。
    public var awtrixLivePreviewBusyIDs: Set<UUID> = []
    /// 仅当设备像素真正变化时才重建 NSImage / 发布视图更新，降低常驻预览的 CPU 占用。
    public var awtrixLivePreviewFrames: [UUID: AWTRIXDisplayFrame] = [:]
    public var awtrixSnapshot: AWTRIXSnapshot? {
        get { activeDeviceID(for: .awtrix).flatMap { awtrixSnapshots[$0] } }
        set {
            guard let id = activeDeviceID(for: .awtrix) else { return }
            awtrixSnapshots[id] = newValue
        }
    }
    public var awtrixStatus: String {
        get {
            guard let id = activeDeviceID(for: .awtrix) else { return "尚未添加 AWTRIX NG" }
            return awtrixStatuses[id] ?? "尚未连接 AWTRIX"
        }
        set {
            guard let id = activeDeviceID(for: .awtrix) else { return }
            awtrixStatuses[id] = newValue
        }
    }
    public var awtrixBusy: Bool {
        get { activeDeviceID(for: .awtrix).map { awtrixBusyIDs.contains($0) } ?? false }
        set {
            guard let id = activeDeviceID(for: .awtrix) else { return }
            if newValue { awtrixBusyIDs.insert(id) } else { awtrixBusyIDs.remove(id) }
        }
    }
    @Published public var aiMacDiscoveredDevices: [AIMacDiscoveredDevice] = []
    @Published public var aiMacNetworkScanBusy = false
    @Published public var aiMacNetworkScanStatus = ""
    @Published public var homeAssistantDiscoveredServices: [HomeAssistantDiscoveredService] = []
    @Published public var homeAssistantDiscoveryBusy = false
    @Published public var homeAssistantDiscoveryStatus = ""
    @Published public var lingxi68DiscoveredDevices: [Lingxi68DiscoveredDevice] = []
    @Published public var lingxi68DiscoveryBusy = false
    @Published public var lingxi68DiscoveryStatus = ""
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
    @Published public var m5FlashPorts: [ESPSerialPort] = []
    @Published public var selectedM5FlashPort = ""
    @Published public var m5FlashProgress = 0.0
    @Published public var m5FlashStatus = "连接 StickS3 USB 数据线后刷新串口列表"
    @Published public var m5FlashLog = ""
    @Published public var m5FlashBusy = false
    /// 设备管理页自动发现每类只主动运行一次；用户仍可点“重新扫描”。
    private var didAutoScanLingxi68 = false
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
    @Published public var nowPlayingLyrics: LyricsTrack?
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
    /// 正式应用允许定时刷新、自动发现与网络推送；发布截图使用隔离模型关闭这些行为。
    public let backgroundServicesEnabled: Bool
    public var enabledColorWiFiScreens: [ManagedDevice] {
        settings.devices.filter { $0.type.isColorWiFiScreen && $0.isEnabled }
    }
    // Shared editors use the device selected in the sidebar, not the ESP8266 active pointer.
    // Each hardware family still keeps its own persisted active ID and per-device settings.
    @Published private var selectedColorScreenType: DeviceType = .aiMacScreen
    public var activeColorScreenType: DeviceType {
        activeColorScreenDevice?.type ?? selectedColorScreenType
    }
    public var activeColorScreenDeviceID: UUID? { activeColorScreenDevice?.id }
    public var activeColorScreenDevice: ManagedDevice? {
        ColorWiFiScreenSelectionPolicy.device(in: settings, preferredType: selectedColorScreenType)
    }
    public func selectColorScreen(deviceID: UUID) {
        guard let type = ColorWiFiScreenSelectionPolicy.requestedType(for: deviceID, in: settings) else { return }
        switchDevice(type: type, to: deviceID)
    }
    private var c6HeartbeatAt: Date?
    private var c6HeartbeatBusy = false
    private var c6HeartbeatTask: Task<Void, Never>?
    @Published public var c6SyncStatuses: [UUID: String] = [:]
    /// A valid LAN session remains usable if installation-local persistence fails.
    @Published public var c6SessionOnlyAuthorizationIDs: Set<UUID> = []
    @Published public var c6OfflineSimulationIDs: Set<UUID> = []
    @Published public var c6OfflineSimulationBusyIDs: Set<UUID> = []
    private var c6OfflineSimulationHosts: [UUID: String] = [:]
    private var c6SyncTasks: [UUID: Task<Void, Never>] = [:]
    private var c6SyncLastCheck: [UUID: Date] = [:]
    private var c6SyncRequests: [UUID: String] = [:]
    private var c6SyncedInputs: [UUID: String] = [:]
    private var c6AttemptInputs: [UUID: String] = [:]
    private var c6Tokens: [UUID: String] = [:]
    private var c6NativeCardSelections: [UUID: [String: String]] = [:]
    private var c6CardOptionTasks: [UUID: Task<Void, Never>] = [:]
    // Lifecycle epochs reject old work even if a host is changed and changed
    // back. Tail IDs only clean finished queue slots; they never drop unrelated
    // ordered edits such as clock appearance followed by card participation.
    private var c6CardOptionEpochs: [UUID: UUID] = [:]
    private var c6CardOptionTaskIDs: [UUID: UUID] = [:]
    private var c6PreparingForQuit = false
    @Published public var c6SyncedConfigurations: [UUID: C6StandaloneConfiguration] = [:]
    private var c6SyncedHosts: [UUID: String] = [:]
    private var c6SyncedPictureOrigins: [UUID: String] = [:]
    private var c6ThumbnailTasks: [UUID: Task<Void, Never>] = [:]
    private var c6ThumbnailRequests: [UUID: UUID] = [:]
    private var c6ThumbnailAttempts: [UUID: Date] = [:]
    private var c6ThumbnailHashes: [UUID: [String: String]] = [:]
    @Published public var weatherStatus = "请选择天气城市"
    @Published public var weatherBusy = false
    private var weatherLastAttempt: Date?
    private var weatherLocationKey = ""

    /// 正式运行默认启用全部后台服务。视觉导出可以注入隔离存储并关闭后台服务，
    /// 这样不会读取、改写或推送用户正在使用的设备数据。
    public init(store: SettingsStore = SettingsStore(), startBackgroundServices: Bool = true) {
        backgroundServicesEnabled = startBackgroundServices
        self.store = store
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
            case .c6Screen: activeID = loaded.activeC6ScreenDeviceID
            case .awtrix: activeID = loaded.activeAWTRIXDeviceID
            case .m5Controller: activeID = loaded.activeM5ControllerDeviceID
            }
            if let device = list.first(where: { $0.id == activeID }) ?? list.first {
                device.settings.apply(to: loaded, type: type)
            }
        }
        wireSettingsHandlers()
        lastCustomImageRevision = currentCustomImageRevision()
        renderPreview()
        if startBackgroundServices {
            setupLingxi68KnobController()
            refreshInputMonitoringStatus()
            applyLingxi68KnobPaging()
            applyStartupState()
            refreshAIMacFlashPorts()
            startTimer()
            startAIMacButtonPolling()
            startLyricsTimer()
            startNowPlayingNotifications()
            Task { await activateMode() }
            for device in enabledDevices(for: .awtrix) {
                Task { await refreshAWTRIX(deviceID: device.id) }
            }
            // 启动即建立先知显示模式会话（自动重连由会话内部负责），按键随时可用
            ensureRand0Session()
            // 已配对的 StickS3 在应用启动后自动恢复蓝牙连接。
            ensureM5ControllerSession()
            // 启动后自动检查 GitHub 更新（6 小时节流，静默失败）
            Task { await checkForUpdate() }
        }
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
        printerRotationStates = [:]
        haAlertCooldownUntil = nil
        haAlertedCode = nil
        lastQuotaRefresh = nil
        lastPushAttempt = nil
        lastPomodoroPushAlignedSeconds = nil
        lastUploadedHash = nil
        aiMacScreenCapabilities = [:]
        aiMacScreenLastHashes = [:]
        aiMacScreenLastPushAt = [:]
        aiMacCanvasPicturePreparationTasks.values.forEach { $0.cancel() }
        aiMacCanvasPicturePreparationTasks = [:]
        aiMacCanvasPicturePreparationGenerations = [:]
        aiMacScreenUploadLatency = [:]
        aiMacScreenSavedBrightness = [:]
        awtrixSnapshots = [:]
        awtrixStatuses = [:]
        awtrixBusyIDs = []
        awtrixDisplayRequestTasks.values.forEach { $0.cancel() }
        awtrixDisplayRequestTasks = [:]
        awtrixDisplayRequestPolicy = AWTRIXLatestDisplayRequestPolicy()
        cancelAWTRIXBackgroundWork()
        awtrixAppConfigurations = [:]
        awtrixAppConfigDrafts = [:]
        awtrixAppStatuses = [:]
        awtrixAppBusyKeys = []
        awtrixLivePreviewImages = [:]
        awtrixLivePreviewStatuses = [:]
        awtrixLivePreviewBusyIDs = []
        awtrixLivePreviewFrames = [:]
        aiMacScreenPowerTasks.values.forEach { $0.cancel() }
        aiMacScreenPowerTasks = [:]
        aiMacScreenPowerGenerations = [:]
        aiMacColorCalibrationCommitTasks.values.forEach { $0.cancel() }
        aiMacColorCalibrationCommitTasks = [:]
        aiMacColorCalibrationPreviewTasks.values.forEach { $0.cancel() }
        aiMacColorCalibrationPreviewTasks = [:]
        aiMacColorCalibrationPreviewGenerations = [:]
        aiMacColorCalibrationPendingIDs = []
        aiMacColorCalibrationPushTasks.values.forEach { $0.cancel() }
        aiMacColorCalibrationPushTasks = [:]
        aiMacColorCalibrationPushGenerations = [:]
        aiMacScreensSystemSleeping = false
        lastOraclePushedHash = nil
        lastExcerptPushedHash = nil
        rand0SessionNeedsPrime = true
        rand0SessionPrimeInFlight = false
        releaseM5HeldShortcut()
        m5BLEClient?.disconnect()
        m5BLEClient = nil
        m5ControllerConnected = false
        m5ControllerScanning = false
        m5DiscoveredControllers = []
        m5BluetoothState = .unknown
        m5RepairingControllerID = nil
        m5RepairingPeripheralName = nil
        m5RepairPhase = nil
        lastM5InfoSent = nil
        m5ControllerPage = .mainMenu
        m5HASelectionIndex = 0
        m5HAActionInFlight = false
        m5HAActionMessage = nil
        lastNowPlayingFetch = nil
        nowPlayingEventRefreshTask?.cancel()
        nowPlayingEventRefreshTask = nil
        nowPlayingEventRefreshID = nil
        nowPlayingEventRefreshThrottle = NowPlayingEventRefreshThrottle()
        lastSmartRotationSongKey = nil
        pendingSmartRotationSongKey = nil
        lyricsFetchTask?.cancel()
        lyricsFetchTask = nil
        lyricsRequestedSongKey = nil
        linkedLyricsLastLineKeys = [:]
        linkedLyricsBusyIDs = []
        resetLinkedLyricsScheduling()
        linkedLyricsUploadLatency = [:]
        haPictureRequestGenerations = [:]
        lastRemoteNowPlaying = nil
        nowPlayingLyrics = nil
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
        ensureM5ControllerSession()
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
                self?.enabledColorWiFiScreens.forEach {
                    self?.refreshAIMacScreenPreview(deviceID: $0.id)
                }
                self?.onAppearanceChanged?()
                self?.scheduleCardSettingsPush()
                // 先知 IP/显示模式变化时重连按键会话（目标未变则幂等返回）
                self?.ensureRand0Session()
                self?.ensureM5ControllerSession()
                self?.sendM5ControllerInfo()
            }
        }
    }

    /// 设置修改后的轻量防抖推送。最终仍按渲染结果 hash 去重，因此与当前卡片
    /// 无关的设置不会产生网络上传，也不会用“画面未变化”覆盖界面状态。
    private func scheduleCardSettingsPush() {
        guard backgroundServicesEnabled else { return }
        cardSettingsPushTask?.cancel()
        cardSettingsPushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.pushWhenAvailable(force: false, silentIfUnchanged: true)
            for device in self.enabledColorWiFiScreens {
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
        let smartRotationReturn = settings.devices[index].settings.smartRotationReturnDisplayMode
        let smartRotationPrinterID = settings.devices[index].settings.smartRotationReturnPrinterDeviceID
        var captured = DeviceSettings.capture(from: settings, type: type)
        captured.bambuDataSource = settings.devices[index].settings.bambuDataSource
        captured.bambuMQTT = settings.devices[index].settings.bambuMQTT
        captured.smartRotationReturnDisplayMode = smartRotationReturn
        captured.smartRotationReturnPrinterDeviceID = smartRotationPrinterID
        settings.devices[index].settings = captured
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
        if settings.devices[index].type == .awtrix {
            if enabled {
                Task { await refreshAWTRIX(deviceID: id) }
            } else {
                cancelAWTRIXBackgroundWork(deviceID: id)
                awtrixDisplayRequestTasks[id]?.cancel()
                awtrixDisplayRequestPolicy.remove(id)
            }
        }
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
            self.activeColorScreenDeviceID ?? UUID()
        }, set: { id in
            self.selectColorScreen(deviceID: id)
        })
    }

    /// 当前 AWTRIX NG 控制页正在操作的设备。
    public var activeAWTRIXBinding: Binding<UUID> {
        Binding(get: {
            self.activeDevice(for: .awtrix)?.id ?? UUID()
        }, set: { id in
            self.switchDevice(type: .awtrix, to: id)
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
        if type.isColorWiFiScreen,
           let id = deviceID ?? settings.activeDeviceID(for: type),
           settings.devices.contains(where: { $0.id == id && $0.type == type && $0.isEnabled }) {
            selectedColorScreenType = type
        }
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
        if type.isColorWiFiScreen {
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
            settings.devices[index].settings.smartRotationReturnDisplayMode = nil
            settings.devices[index].settings.smartRotationReturnPrinterDeviceID = nil
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
        case .aiMacScreen, .c6Screen:
            settings.devices[index].settings.aiMacScreen = AIMacScreenDeviceSettings()
        case .awtrix:
            let fresh = AWTRIXSettings()
            settings.awtrix = fresh
            settings.devices[index].settings.awtrix = fresh
        case .m5Controller:
            settings.devices[index].settings.m5Controller = M5ControllerDeviceSettings()
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
        if type.isColorWiFiScreen {
            aiMacScreenStatuses[device.id] = "等待连接小屏幕"
            refreshAIMacScreenPreview(deviceID: device.id)
        }
        if type == .awtrix {
            awtrixStatuses[device.id] = "尚未连接 AWTRIX"
        }
        if type == .m5Controller {
            ensureM5ControllerSession()
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

    /// 删除一台设备（允许删除全部设备；删除的是活动设备时切换到同类回退设备）
    public func removeDevice(id: UUID) {
        guard let device = settings.devices.first(where: { $0.id == id }) else { return }
        let type = device.type
        if type == .c6Screen {
            invalidateC6CardOptionTasks(deviceID: id)
            c6OfflineSimulationIDs.remove(id); c6OfflineSimulationHosts[id] = nil
            c6OfflineSimulationBusyIDs.remove(id)
            c6ThumbnailTasks.removeValue(forKey: id)?.cancel(); c6SyncedConfigurations[id] = nil
            c6ThumbnailRequests[id] = nil
            c6SyncedHosts[id] = nil
            c6ThumbnailAttempts[id] = nil; c6ThumbnailHashes[id] = nil
            c6SyncTasks.removeValue(forKey: id)?.cancel()
            c6SyncStatuses[id] = nil; c6SyncedInputs[id] = nil; c6SyncRequests[id] = nil
            c6Tokens[id] = nil; c6AttemptInputs[id] = nil; c6SyncLastCheck[id] = nil
            c6SessionOnlyAuthorizationIDs.remove(id)
            _ = C6SecretStore.save("", deviceID: id)
        }
        if type == .awtrix {
            awtrixWeatherTasks.removeValue(forKey: id)?.cancel()
            awtrixWeatherLastContent[id] = nil; awtrixWeatherLastAttempt[id] = nil
        }
        if type == .bambuLab {
            disconnectBambuMQTT(id)
            BambuMQTTSecretStore.save("", deviceID: id)
        }
        let removingActiveDevice = activeDeviceID(for: type) == id
        // StickS3 的设备卡片保存在控制器 RAM 中。删除档案前先写入空列表，
        // 等 BLE 写入确认后再断开，否则控制器仍会显示并控制已经删除的旧目标。
        if type == .m5Controller {
            clearM5ControllerInfoAndDisconnect()
        }
        guard settings.removeManagedDevice(id: id) != nil else { return }
        if removingActiveDevice {
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
            printerRotationStates[id] = nil
            removeBambuPrinterCard()
        }
        if type == .formlabs {
            printerRotationStates[id] = nil
            formlabsSnapshots[id] = nil
            formlabsDiscoveredDevices[id] = nil
            formlabsConnectionStatus[id] = nil
            lastFormlabsRefresh[id] = nil
            store.saveFormlabsTaskCache(formlabsSnapshots)
            removeFormlabsPrinterCard()
        }
        if type.isColorWiFiScreen {
            aiMacScreenCapabilities[id] = nil
            aiMacScreenLastHashes[id] = nil
            aiMacScreenLastPushAt[id] = nil
            aiMacScreenUploadLatency[id] = nil
            aiMacScreenLastBoardRotation[id] = nil
            aiMacScreenLastCardRotation[id] = nil
            aiMacScreenLastClockSyncAt[id] = nil
            aiMacScreenPowerTasks[id]?.cancel()
            aiMacScreenPowerTasks[id] = nil
            aiMacScreenPowerGenerations[id] = nil
            aiMacColorCalibrationCommitTasks[id]?.cancel()
            aiMacColorCalibrationCommitTasks[id] = nil
            aiMacColorCalibrationPreviewTasks[id]?.cancel()
            aiMacColorCalibrationPreviewTasks[id] = nil
            aiMacColorCalibrationPreviewGenerations[id] = nil
            aiMacColorCalibrationPendingIDs.remove(id)
            aiMacColorCalibrationPushTasks[id]?.cancel()
            aiMacColorCalibrationPushTasks[id] = nil
            aiMacColorCalibrationPushGenerations[id] = nil
            aiMacScreenSavedBrightness[id] = nil
            aiMacSspaiRandomSelection = aiMacSspaiRandomSelection.filter {
                !$0.key.hasPrefix(id.uuidString + "|")
            }
            aiMacScreenPreviews[id] = nil
            aiMacScreenStatuses[id] = nil
            aiMacScreenLastPushText[id] = nil
            aiMacScreenLosslessIDs.remove(id)
            aiMacScreenLastClockSyncAt[id] = nil
            aiMacScreenBusyIDs.remove(id)
        }
        if type == .awtrix {
            cancelAWTRIXBackgroundWork(deviceID: id)
            awtrixDisplayRequestTasks[id]?.cancel()
            awtrixDisplayRequestTasks[id] = nil
            awtrixDisplayRequestPolicy.remove(id)
            awtrixSnapshots[id] = nil
            awtrixStatuses[id] = nil
            awtrixBusyIDs.remove(id)
            awtrixAppConfigurations[id] = nil
            awtrixAppConfigDrafts[id] = nil
            awtrixAppStatuses[id] = nil
            awtrixAppBusyKeys = awtrixAppBusyKeys.filter {
                !$0.hasPrefix(id.uuidString + "|")
            }
            awtrixLivePreviewImages[id] = nil
            awtrixLivePreviewStatuses[id] = nil
            awtrixLivePreviewBusyIDs.remove(id)
            awtrixLivePreviewFrames[id] = nil
        }
        if type == .m5Controller {
            if m5RepairingControllerID == id {
                m5RepairingControllerID = nil
                m5RepairingPeripheralName = nil
                m5RepairPhase = nil
            }
            m5ControllerConnected = false
            m5DiscoveredControllers = []
            lastM5InfoSent = nil
            m5ControllerPage = .mainMenu
            m5HASelectionIndex = 0
            m5HAActionInFlight = false
            m5HAActionMessage = nil
            status = "已删除 M5 StickS3；重新配对前请在系统蓝牙中手动忽略原设备"
        }
        // 删除任何显示设备时，同时清理控制器中保存的失效目标。
        for index in settings.devices.indices where settings.devices[index].type == .m5Controller {
            if var config = settings.devices[index].settings.m5Controller,
               config.targetDeviceIDs.contains(id.uuidString) {
                config.targetDeviceIDs.removeAll { $0 == id.uuidString }
                config.clamp()
                settings.devices[index].settings.m5Controller = config
            }
        }
        if type == .keyboard {
            linkedLyricsLastLineKeys[id] = nil
            linkedLyricsBusyIDs.remove(id)
            linkedLyricsScheduledLineKeys[id] = nil
            linkedLyricsPushTasks[id]?.cancel()
            linkedLyricsPushTasks[id] = nil
            linkedLyricsRetryLineKeys[id] = nil
            linkedLyricsRetryNotBefore[id] = nil
            linkedLyricsUploadLatency[id] = nil
            // 删除目标键盘时同时解除所有来源设备的关联，避免留下不可见的失效 ID。
            for index in settings.devices.indices {
                if settings.devices[index].type == .oracle,
                   settings.devices[index].settings.oracleLyricsKeyboardDeviceID == id {
                    settings.devices[index].settings.oracleLyricsKeyboardDeviceID = nil
                } else if settings.devices[index].type.isColorWiFiScreen,
                          var config = settings.devices[index].settings.aiMacScreen,
                          config.lyricsKeyboardDeviceID == id {
                    config.lyricsKeyboardDeviceID = nil
                    settings.devices[index].settings.aiMacScreen = config
                }
            }
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

    /// 某台 AWTRIX NG 的完整独立配置；旧快照缺字段时使用安全默认值。
    public func awtrixSettings(for id: UUID) -> AWTRIXSettings {
        settings.devices.first(where: { $0.id == id && $0.type == .awtrix })?
            .settings.awtrix ?? AWTRIXSettings()
    }

    public func mutateAWTRIXSettings(_ id: UUID,
                                     _ update: (inout AWTRIXSettings) -> Void) {
        guard let index = settings.devices.firstIndex(where: { $0.id == id && $0.type == .awtrix }) else {
            return
        }
        var value = settings.devices[index].settings.awtrix ?? AWTRIXSettings()
        update(&value)
        value.sanitize()
        guard value != settings.devices[index].settings.awtrix else { return }
        // AWTRIX 设置只更新目标设备，避免每次编辑都重绘键盘和所有画板。
        let wasSyncing = settings.deviceSyncInFlight
        settings.deviceSyncInFlight = true
        settings.devices[index].settings.awtrix = value
        if activeDeviceID(for: .awtrix) == id {
            settings.awtrix = value
        }
        settings.deviceSyncInFlight = wasSyncing
        objectWillChange.send()
        persistSettings()
    }

    public func awtrixBaseURLBinding(for id: UUID) -> Binding<String> {
        Binding(get: { self.awtrixSettings(for: id).baseURL }, set: { value in
            self.mutateAWTRIXSettings(id) { $0.baseURL = value }
        })
    }

    public func awtrixUsernameBinding(for id: UUID) -> Binding<String> {
        Binding(get: { self.awtrixSettings(for: id).username }, set: { value in
            self.mutateAWTRIXSettings(id) { $0.username = value }
        })
    }

    public func awtrixPasswordBinding(for id: UUID) -> Binding<String> {
        Binding(get: { self.awtrixSettings(for: id).password }, set: { value in
            self.mutateAWTRIXSettings(id) { $0.password = value }
        })
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
            let sampledAt = Date()
            applyHASnapshot(entities: entities, errorText: nil, sampledAt: sampledAt)
            lastHARefresh = sampledAt
            let result = reconcileBambuPrinters(entities: entities)
            observeBambuPrinterRotationStates(entities: entities, now: sampledAt)
            bambuAutoDiscoveryStatus = result
            return "连接成功：读到 \(entities.count) 个实体；\(result)"
        } catch let error as HAError {
            return error.errorDescription ?? "连接失败"
        } catch {
            return "连接失败"
        }
    }

    // MARK: - 灵犀68 / Home Assistant / Bambu Lab 自动发现

    /// 灵犀68 固件当前没有可靠的设备身份接口。保留这个入口便于将来恢复兼容，
    /// 但现阶段不执行局域网探测，避免把其他提供相似上传路由的设备误识别为键盘。
    public func scanLingxi68Devices(force: Bool = false) async {
        guard !lingxi68DiscoveryBusy else { return }
        if !force, didAutoScanLingxi68 { return }
        didAutoScanLingxi68 = true
        lingxi68DiscoveredDevices = []
        lingxi68DiscoveryStatus = "灵犀68键盘当前仅支持手动添加"
    }

    public func isLingxi68DeviceAdded(_ discovered: Lingxi68DiscoveredDevice) -> Bool {
        let host = EndpointBuilder.host(from: discovered.ip)
        return devices(for: .keyboard).contains {
            EndpointBuilder.host(from: $0.settings.endpoint ?? "") == host
        }
    }

    @discardableResult
    public func addDiscoveredLingxi68Device(_ discovered: Lingxi68DiscoveredDevice) -> UUID {
        let host = EndpointBuilder.host(from: discovered.ip)
        if let existing = devices(for: .keyboard).first(where: {
            EndpointBuilder.host(from: $0.settings.endpoint ?? "") == host
        }) {
            setDeviceEnabled(id: existing.id, enabled: true)
            switchDevice(type: .keyboard, to: existing.id)
            lingxi68DiscoveryStatus = "该键盘已在列表中 · \(host)"
            persistSettings()
            return existing.id
        }
        let id = addDevice(type: .keyboard)
        guard let index = settings.devices.firstIndex(where: { $0.id == id }) else { return id }
        settings.deviceSyncInFlight = true
        let endpoint = EndpointBuilder.endpoint(fromHost: host)
        settings.devices[index].settings.endpoint = endpoint
        settings.devices[index].name = discovered.displayName
        settings.endpoint = endpoint
        settings.deviceSyncInFlight = false
        lingxi68DiscoveredDevices.removeAll { $0.id == discovered.id }
        lingxi68DiscoveryStatus = "已添加 \(discovered.displayName) · \(host)"
        persistSettings()
        renderPreview()
        return id
    }

    /// 设备管理页首次进入时自动扫描一次；后续只有用户主动点“重新扫描”才再次运行。
    public func scanHomeAssistantServers(force: Bool = false) async {
        guard !homeAssistantDiscoveryBusy else { return }
        if !force, didAutoScanHomeAssistant { return }
        didAutoScanHomeAssistant = true
        homeAssistantDiscoveryBusy = true
        homeAssistantDiscoveryStatus = "正在查找局域网中的 Home Assistant…"
        defer { homeAssistantDiscoveryBusy = false }
        let scannedServices = await HomeAssistantDiscovery.scan(timeout: 3)
        let services = scannedServices.filter { !isHomeAssistantAdded($0) }
        homeAssistantDiscoveredServices = services
        homeAssistantDiscoveryStatus = services.isEmpty
            ? "没有发现尚未添加的服务器，可继续使用手动添加"
            : "发现 \(services.count) 个尚未添加的 Home Assistant 服务器"
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
            for device in devices(for: .bambuLab) { printerRotationStates[device.id] = nil }
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
            let sampledAt = Date()
            applyHASnapshot(entities: entities, errorText: nil, sampledAt: sampledAt)
            lastHARefresh = sampledAt
            bambuAutoDiscoveryStatus = reconcileBambuPrinters(entities: entities)
            observeBambuPrinterRotationStates(entities: entities, now: sampledAt)
        } catch let error as HAError {
            bambuAutoDiscoveryStatus = error.errorDescription ?? "无法读取 Home Assistant 设备"
        } catch {
            bambuAutoDiscoveryStatus = "无法读取 Home Assistant 设备"
        }
    }

    private func reconcileBambuPrinters(entities: [HAEntity]) -> String {
        let candidates = BambuEntityMatcher.automaticPrintStatusCandidates(entities)
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
            printerRotationStates[id] = nil
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
        let scannedDevices = await Rand0Discovery.scanLocalNetwork(excluding: excluded)
        let found = scannedDevices.filter { !isRand0DeviceAdded($0) }
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
        let excluded = Set(settings.devices.filter { $0.type.isColorWiFiScreen }.map {
            AIMacScreenSupport.normalizedHost($0.settings.aiMacScreen?.host ?? "")
        }.filter { !$0.isEmpty })
        let scannedDevices = await AIMacScreenDiscovery.scanLocalNetwork(excluding: excluded)
        let devices = scannedDevices.filter { !isAIMacScreenAdded($0) }
        aiMacDiscoveredDevices = devices
        aiMacNetworkScanStatus = devices.isEmpty
            ? "没有发现尚未添加的小屏幕，请确认 Mac 与设备位于同一网络"
            : "发现 \(devices.count) 台尚未添加的小屏幕"
    }

    public func isAIMacScreenAdded(_ discovered: AIMacDiscoveredDevice) -> Bool {
        let host = AIMacScreenSupport.normalizedHost(discovered.ip)
        return settings.devices.filter { $0.type.isColorWiFiScreen }.contains {
            AIMacScreenSupport.normalizedHost($0.settings.aiMacScreen?.host ?? "") == host
        }
    }

    /// 扫描结果按 IP 去重；已有设备会被重新启用并定位，不会产生重复档案。
    @discardableResult
    public func addDiscoveredAIMacScreen(_ discovered: AIMacDiscoveredDevice) -> UUID? {
        let host = AIMacScreenSupport.normalizedHost(discovered.ip)
        if let existing = settings.devices.filter({ $0.type.isColorWiFiScreen }).first(where: {
            AIMacScreenSupport.normalizedHost($0.settings.aiMacScreen?.host ?? "") == host
        }) {
            setDeviceEnabled(id: existing.id, enabled: true)
            switchDevice(type: existing.type, to: existing.id)
            aiMacScreenStatuses[existing.id] = "已在设备列表中 · \(host)"
            Task { await testAIMacScreenConnection(deviceID: existing.id) }
            return existing.id
        }
        guard settings.canAddDevice(of: discovered.type) else {
            aiMacNetworkScanStatus = "AI Mac 小屏幕已达到 5 台上限"
            return nil
        }
        let id = addDevice(type: discovered.type)
        mutateAIMacScreenSettings(id, schedulePush: false) { $0.host = host }
        if let index = settings.devices.firstIndex(where: { $0.id == id }) {
            settings.devices[index].name = discovered.displayName
        }
        aiMacDiscoveredDevices.removeAll { AIMacScreenSupport.normalizedHost($0.ip) == host }
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
        settings.devices.first(where: { $0.id == id && $0.type.isColorWiFiScreen })?
            .settings.aiMacScreen ?? AIMacScreenDeviceSettings()
    }

    private func mutateAIMacScreenSettings(
        _ id: UUID,
        pushImmediately: Bool = false,
        schedulePush: Bool = true,
        _ body: (inout AIMacScreenDeviceSettings) -> Void
    ) {
        guard let index = settings.devices.firstIndex(where: {
            $0.id == id && $0.type.isColorWiFiScreen
        }) else { return }
        var value = settings.devices[index].settings.aiMacScreen ?? AIMacScreenDeviceSettings()
        let previousHost = AIMacScreenSupport.normalizedHost(value.host)
        body(&value)
        if value.smartRotationReturnContentMode != nil,
           (value.mode != .card || value.cardMode != .nowPlaying || value.c6NativeCardID != nil) {
            // 只要页面已离开本次智能抢占目标（手动或普通轮播均可），返回令牌就失效；
            // 后续“未在播放”不能覆盖用户/轮播已经作出的新选择。
            value.smartRotationReturnContentMode = nil
            value.smartRotationReturnCardModeRawValue = nil
            value.smartRotationReturnPrinterDeviceID = nil
            value.smartRotationReturnC6NativeCardID = nil
        }
        value.clamp()
        settings.devices[index].settings.aiMacScreen = value
        if AIMacScreenSupport.normalizedHost(value.host) != previousHost {
            invalidateC6CardOptionTasks(deviceID: id)
            aiMacScreenCapabilities[id] = nil
            aiMacScreenLastHashes[id] = nil
            aiMacScreenLastPushAt[id] = nil
            aiMacScreenLosslessIDs.remove(id)
            aiMacScreenLastClockSyncAt[id] = nil
            c6SyncedConfigurations[id] = nil
            c6SyncedHosts[id] = nil
            c6NativeCardSelections[id] = nil
            value.c6LastSyncedInputKey = nil
            value.c6LastSyncedSelection = nil
            settings.devices[index].settings.aiMacScreen = value
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
            self.mutateAIMacScreenSettings(id, pushImmediately: true) {
                $0.smartRotationReturnContentMode = nil
                $0.smartRotationReturnCardModeRawValue = nil
                $0.smartRotationReturnPrinterDeviceID = nil
                $0.smartRotationReturnC6NativeCardID = nil
                $0.c6NativeCardID = nil
                $0.mode = value
            }
        })
    }

    public func activateAIMacScreenMode(_ mode: AIMacScreenContentMode,
                                        deviceID: UUID) {
        let current = aiMacScreenSettings(for: deviceID).mode
        mutateAIMacScreenSettings(deviceID, pushImmediately: current != mode) {
            $0.smartRotationReturnContentMode = nil
            $0.smartRotationReturnCardModeRawValue = nil
            $0.smartRotationReturnPrinterDeviceID = nil
            $0.smartRotationReturnC6NativeCardID = nil
            $0.c6NativeCardID = nil
            $0.mode = mode
        }
    }

    public func aiMacScreenAutoPushBinding(for id: UUID) -> Binding<Bool> {
        Binding(get: { self.aiMacScreenSettings(for: id).autoPush }, set: { value in
            self.mutateAIMacScreenSettings(id, pushImmediately: value) { $0.autoPush = value }
        })
    }

    public func aiMacScreenFollowSystemSleepBinding(for id: UUID) -> Binding<Bool> {
        Binding(get: { self.aiMacScreenSettings(for: id).followSystemSleep }, set: { value in
            self.mutateAIMacScreenSettings(id, schedulePush: false) {
                $0.followSystemSleep = value
            }
            // 极少数情况下用户通过远程桌面在锁屏态修改开关：开启立即熄屏，
            // 关闭则立即恢复背光，不把设备留在黑屏状态。
            if self.aiMacScreensSystemSleeping {
                Task { @MainActor [weak self] in
                    await self?.setAIMacScreenPower(deviceID: id, sleeping: value)
                }
            }
        })
    }

    public func aiMacScreenBrightnessLevel(for id: UUID) -> Int {
        aiMacScreenSavedBrightness[id]
            ?? aiMacScreenSettings(for: id).awakeBrightness
            ?? aiMacScreenCapabilities[id]?.brightnessLevel
            ?? 100
    }

    /// 滑动过程中只更新内存值；松开或点击“应用亮度”时才持久化并请求设备，
    /// 避免连续写设置和向低功耗小屏发送大量背光请求。
    public func aiMacScreenBrightnessBinding(for id: UUID) -> Binding<Double> {
        Binding(get: { Double(self.aiMacScreenBrightnessLevel(for: id)) }, set: { value in
            self.aiMacScreenSavedBrightness[id] = min(max(Int(value.rounded()), 1), 100)
            self.objectWillChange.send()
        })
    }

    public func applyAIMacScreenBrightness(deviceID: UUID) async {
        let level = aiMacScreenBrightnessLevel(for: deviceID)
        mutateAIMacScreenSettings(deviceID, schedulePush: false) {
            $0.awakeBrightness = level
        }
        guard !aiMacScreenShouldSleep(deviceID: deviceID) else {
            aiMacScreenStatuses[deviceID] = "已保存亮度 \(level)% · 唤醒后生效"
            return
        }

        // 与锁屏/唤醒共用同一条设备任务队列，保证临界时刻最后发生的状态胜出。
        let previousTask = aiMacScreenPowerTasks[deviceID]
        let generation = (aiMacScreenPowerGenerations[deviceID] ?? 0) &+ 1
        aiMacScreenPowerGenerations[deviceID] = generation
        let operation = Task { @MainActor [weak self] () -> Bool in
            _ = await previousTask?.value
            guard !Task.isCancelled, let self,
                  !self.aiMacScreenShouldSleep(deviceID: deviceID) else { return false }
            return await self.sendAIMacScreenBrightness(deviceID: deviceID, level: level)
        }
        aiMacScreenPowerTasks[deviceID] = operation
        let succeeded = await operation.value
        guard aiMacScreenPowerGenerations[deviceID] == generation else { return }
        aiMacScreenPowerTasks[deviceID] = nil
        if succeeded {
            aiMacScreenStatuses[deviceID] = "亮度已调整为 \(level)%"
        }
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

    public func c6ClockStyleBinding(for id: UUID) -> Binding<C6ClockStyle> {
        Binding(get: { self.c6SyncedConfigurations[id]?.clockStyle ?? .flip }, set: { style in
            guard !self.c6PreparingForQuit,
                  self.settings.devices.contains(where: { $0.id == id && $0.type == .c6Screen }) else { return }
            let host = AIMacScreenSupport.normalizedHost(self.aiMacScreenSettings(for: id).host)
            let epoch = self.c6CardOptionEpochs[id] ?? UUID()
            let operationID = UUID()
            self.c6CardOptionEpochs[id] = epoch
            self.c6CardOptionTaskIDs[id] = operationID
            let previous = self.c6CardOptionTasks[id]
            self.c6CardOptionTasks[id] = Task { @MainActor [weak self] in
                await previous?.value
                guard let self else { return }
                defer { self.finishC6CardOptionTask(deviceID: id, operationID: operationID) }
                guard self.isCurrentC6CardOptionTarget(id, host: host, epoch: epoch) else { return }
                do {
                    let client = try C6StandaloneClient(host: host)
                    let token = self.c6Tokens[id] ?? C6SecretStore.read(deviceID: id)
                    for attempt in 0..<2 {
                        var local = try await client.read(token: token)
                        guard self.isCurrentC6CardOptionTarget(id, host: host, epoch: epoch) else { return }
                        local.clockStyle = style
                        do {
                            let saved = try await client.save(local, token: token, credentials: C6Credentials())
                            guard self.isCurrentC6CardOptionTarget(id, host: host, epoch: epoch) else { return }
                            self.didUpdateC6DeviceConfiguration(saved, deviceID: id, host: host)
                            await self.pushAIMacScreen(deviceID: id, force: true)
                            guard self.isCurrentC6CardOptionTarget(id, host: host, epoch: epoch) else { return }
                            return
                        } catch C6StandaloneError.conflict where attempt == 0 { continue }
                    }
                } catch {
                    guard self.isCurrentC6CardOptionTarget(id, host: host, epoch: epoch) else { return }
                    self.c6SyncStatuses[id] = "时钟样式未保存：\(error.localizedDescription)"
                }
            }
        })
    }

    public func didUpdateC6DeviceConfiguration(_ configuration: C6StandaloneConfiguration, deviceID: UUID, host: String) {
        guard isCurrentColorScreenTarget(deviceID, host: AIMacScreenSupport.normalizedHost(host)),
              settings.devices.first(where: { $0.id == deviceID })?.type == .c6Screen else { return }
        c6SyncedConfigurations[deviceID] = configuration
        c6SyncedHosts[deviceID] = host
        aiMacScreenLastClockSyncAt[deviceID] = nil
        refreshAIMacScreenPreview(deviceID: deviceID)
    }

    public func aiMacScreenSaturationBinding(for id: UUID) -> Binding<Double> {
        aiMacScreenColorCalibrationBinding(for: id, \.saturationPercent)
    }

    public func aiMacScreenContrastBinding(for id: UUID) -> Binding<Double> {
        aiMacScreenColorCalibrationBinding(for: id, \.contrastPercent)
    }

    private func aiMacScreenColorCalibrationBinding(
        for id: UUID, _ keyPath: WritableKeyPath<AIMacScreenDeviceSettings, Int>
    ) -> Binding<Double> {
        Binding(get: {
            Double(self.aiMacScreenSettings(for: id)[keyPath: keyPath])
        }, set: { value in
            guard value.isFinite, (0...1_000).contains(value),
                  self.settings.devices.contains(where: { $0.id == id && $0.type.isColorWiFiScreen }) else { return }
            var config = self.aiMacScreenSettings(for: id)
            let previous = config
            config[keyPath: keyPath] = Int(value.rounded())
            config.clamp()
            guard config != previous else { return }
            self.updateAIMacScreenColorCalibration(config, deviceID: id)
        })
    }

    public func resetAIMacScreenColorCalibration(deviceID: UUID) {
        guard settings.devices.contains(where: { $0.id == deviceID && $0.type.isColorWiFiScreen }) else { return }
        var config = aiMacScreenSettings(for: deviceID)
        guard config.hasColorCalibration else { return }
        config.saturationPercent = 100
        config.contrastPercent = 100
        updateAIMacScreenColorCalibration(config, deviceID: deviceID)
        commitAIMacScreenColorCalibration(deviceID: deviceID)
    }

    /// 滑杆每个刻度只修改目标设备并即时重绘它自己的 240×240 预览。
    /// AppSettings 的通用 onChange 在这里被暂时旁路，避免无关设备随拖动重复渲染。
    private func updateAIMacScreenColorCalibration(
        _ config: AIMacScreenDeviceSettings, deviceID: UUID
    ) {
        guard let index = settings.devices.firstIndex(where: {
            $0.id == deviceID && $0.type.isColorWiFiScreen
        }) else { return }
        settings.deviceSyncInFlight = true
        var devices = settings.devices
        devices[index].settings.aiMacScreen = config
        settings.devices = devices
        settings.deviceSyncInFlight = false
        aiMacColorCalibrationPendingIDs.insert(deviceID)
        scheduleAIMacScreenColorCalibrationPreview(deviceID: deviceID)
        scheduleAIMacScreenColorCalibrationCommit(deviceID: deviceID)
    }

    /// 最多约 30 fps 更新当前设备预览。鼠标事件再密集也不会同步堵住主线程，
    /// 每次执行时读取最新参数，因此不会显示过期的中间刻度。
    private func scheduleAIMacScreenColorCalibrationPreview(deviceID: UUID) {
        guard aiMacColorCalibrationPreviewTasks[deviceID] == nil else { return }
        let generation = (aiMacColorCalibrationPreviewGenerations[deviceID] ?? 0) &+ 1
        aiMacColorCalibrationPreviewGenerations[deviceID] = generation
        aiMacColorCalibrationPreviewTasks[deviceID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 33_000_000) } catch { return }
            guard let self, !Task.isCancelled,
                  self.aiMacColorCalibrationPreviewGenerations[deviceID] == generation else { return }
            self.aiMacColorCalibrationPreviewTasks[deviceID] = nil
            self.refreshAIMacScreenPreview(deviceID: deviceID)
        }
    }

    private func scheduleAIMacScreenColorCalibrationCommit(deviceID: UUID) {
        aiMacColorCalibrationCommitTasks[deviceID]?.cancel()
        aiMacColorCalibrationCommitTasks[deviceID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.commitAIMacScreenColorCalibration(deviceID: deviceID)
        }
    }

    /// 拖动结束时立即提交；同时保留 180ms 尾随提交，兼容键盘微调等不触发
    /// Slider 编辑结束回调的交互方式。
    public func finishAIMacScreenColorCalibrationAdjustment(deviceID: UUID) {
        aiMacColorCalibrationPreviewTasks[deviceID]?.cancel()
        aiMacColorCalibrationPreviewTasks[deviceID] = nil
        aiMacColorCalibrationPreviewGenerations[deviceID] =
            (aiMacColorCalibrationPreviewGenerations[deviceID] ?? 0) &+ 1
        commitAIMacScreenColorCalibration(deviceID: deviceID)
    }

    private func commitAIMacScreenColorCalibration(deviceID: UUID) {
        aiMacColorCalibrationCommitTasks[deviceID]?.cancel()
        aiMacColorCalibrationCommitTasks[deviceID] = nil
        guard aiMacColorCalibrationPendingIDs.remove(deviceID) != nil else { return }
        guard settings.devices.contains(where: {
            $0.id == deviceID && $0.type.isColorWiFiScreen
        }) else { return }
        persistSettings()
        // 最终刻度只做一次真实传输格式模拟；拖动中的约 30 fps 预览保留轻量
        // 32-bit 渲染，避免旧 JPEG 固件在每个鼠标事件上反复编解码。
        refreshAIMacScreenPreview(deviceID: deviceID, simulateTransport: true)
        let config = aiMacScreenSettings(for: deviceID)
        let isNativeClock = config.mode == .clock
            || (config.mode == .card && config.cardMode == .aiMacClock)
        guard backgroundServicesEnabled, config.autoPush, !isNativeClock else { return }
        enqueueAIMacScreenColorCalibrationPush(deviceID: deviceID)
    }

    private func enqueueAIMacScreenColorCalibrationPush(deviceID: UUID) {
        let previous = aiMacColorCalibrationPushTasks[deviceID]
        let generation = (aiMacColorCalibrationPushGenerations[deviceID] ?? 0) &+ 1
        aiMacColorCalibrationPushGenerations[deviceID] = generation
        aiMacColorCalibrationPushTasks[deviceID] = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, !Task.isCancelled,
                  self.aiMacColorCalibrationPushGenerations[deviceID] == generation else { return }
            while self.aiMacScreenBusyIDs.contains(deviceID) {
                do { try await Task.sleep(nanoseconds: 25_000_000) } catch { return }
                guard self.aiMacColorCalibrationPushGenerations[deviceID] == generation,
                      self.settings.devices.contains(where: {
                          $0.id == deviceID && $0.type.isColorWiFiScreen
                      }) else { return }
            }
            let latest = self.aiMacScreenSettings(for: deviceID)
            let isNativeClock = latest.mode == .clock
                || (latest.mode == .card && latest.cardMode == .aiMacClock)
            guard latest.autoPush, !isNativeClock else { return }
            await self.pushAIMacScreen(deviceID: deviceID, force: false)
            if self.aiMacColorCalibrationPushGenerations[deviceID] == generation {
                self.aiMacColorCalibrationPushTasks[deviceID] = nil
            }
        }
    }

    /// App 退出前把不足 180ms 的最后一次滑杆修改写盘；终止期间不再发网络请求。
    public func prepareForTermination() {
        c6PreparingForQuit = true
        c6HeartbeatTask?.cancel()
        c6CardOptionTasks.values.forEach { $0.cancel() }
        c6CardOptionTasks = [:]
        c6CardOptionTaskIDs = [:]
        c6CardOptionEpochs = [:]
        c6SyncTasks.values.forEach { $0.cancel() }
        c6ThumbnailTasks.values.forEach { $0.cancel() }
        awtrixWeatherTasks.values.forEach { $0.cancel() }
        cancelAWTRIXBackgroundWork()
        aiMacColorCalibrationCommitTasks.values.forEach { $0.cancel() }
        aiMacColorCalibrationCommitTasks = [:]
        guard !aiMacColorCalibrationPendingIDs.isEmpty else { return }
        aiMacColorCalibrationPendingIDs = []
        persistSettings()
    }

    public var hasC6SoftwareControlToRelease: Bool {
        enabledDevices(for: .c6Screen).contains {
            !AIMacScreenSupport.normalizedHost(aiMacScreenSettings(for: $0.id).host).isEmpty
        }
    }

    public func releaseC6SoftwareControlBeforeQuit() async {
        // Stop new frames first; finish/cancel renewals before sending the final handoff.
        await c6HeartbeatTask?.value
        let deadline = Date().addingTimeInterval(1)
        while !aiMacScreenBusyIDs.isEmpty && Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !Task.isCancelled else { return }
        let targets = enabledDevices(for: .c6Screen).compactMap { device -> (C6StandaloneClient, String)? in
            let token = c6Tokens[device.id] ?? C6SecretStore.read(deviceID: device.id)
            guard !token.isEmpty, let client = try? C6StandaloneClient(host: aiMacScreenSettings(for: device.id).host) else { return nil }
            return (client, token)
        }
        await withTaskGroup(of: Void.self) { group in
            for (client, token) in targets {
                group.addTask { try? await client.releaseSoftwareControl(token: token) }
            }
        }
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

    public func aiMacSystemMonitorModules(for deviceID: UUID) -> [CanvasModule] {
        let deviceSettings = settings.devices.first {
            $0.id == deviceID && $0.type.isColorWiFiScreen
        }?.settings ?? DeviceSettings()
        return deviceSettings.aiMacSystemMonitorModules
    }

    public func aiMacSystemMonitorBinding(
        for deviceID: UUID, _ keyPath: WritableKeyPath<DeviceSettings, Bool?>
    ) -> Binding<Bool> {
        Binding(get: {
            self.settings.devices.first { $0.id == deviceID && $0.type.isColorWiFiScreen }?
                .settings[keyPath: keyPath] ?? true
        }, set: { visible in
            guard let device = self.settings.devices.first(where: {
                $0.id == deviceID && $0.type.isColorWiFiScreen
            }), device.settings[keyPath: keyPath] != visible else { return }
            // 正常设置监听器负责保存、刷新预览及防抖推送；不写键盘的全局 show 字段。
            self.mutateDeviceSettings(deviceID) { $0[keyPath: keyPath] = visible }
        })
    }

    public func aiMacHiddenCardList(for deviceID: UUID) -> [DisplayMode] {
        let visible = Set(aiMacCardList(for: deviceID))
        return availableAIMacCardModes.filter { !visible.contains($0) }
    }

    public func isCurrentAIMacCard(deviceID: UUID, mode: DisplayMode) -> Bool {
        let config = aiMacScreenSettings(for: deviceID)
        return config.mode == .card && config.cardMode == mode && config.c6NativeCardID == nil
    }

    public func activateAIMacCard(_ mode: DisplayMode, deviceID: UUID) {
        guard availableAIMacCardModes.contains(mode) else { return }
        if settings.devices.first(where: { $0.id == deviceID })?.type == .c6Screen,
           mode == .aiMacClock,
           let card = allC6Cards(for: deviceID).first(where: { $0.nativeCard?.kind == "clock" }) {
            activateC6Card(card, deviceID: deviceID)
            return
        }
        mutateAIMacScreenSettings(deviceID, schedulePush: false) { config in
            // 明确点选（包括再次点“正在播放”）取得页面所有权，不再让旧自动抢占
            // 在媒体结束时把用户带回更早的页面。
            config.smartRotationReturnContentMode = nil
            config.smartRotationReturnCardModeRawValue = nil
            config.smartRotationReturnPrinterDeviceID = nil
            config.smartRotationReturnC6NativeCardID = nil
            config.c6NativeCardID = nil
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

    // C6 has a single online playlist. Native targets have stable source identities,
    // not indices or editable names; ESP8266 retains its existing software playlist.
    private func allC6Cards(for deviceID: UUID) -> [C6CardDescriptor] {
        guard let device = settings.devices.first(where: { $0.id == deviceID && $0.type == .c6Screen }) else { return [] }
        let config = aiMacScreenSettings(for: deviceID)
        let local = c6SyncedConfigurations[deviceID] ?? C6StandaloneConfiguration()
        let selected = c6Selection(for: device)
        var mappings: [String: DisplayMode] = [:]
        for printer in local.printers {
            guard let match = selected.printers.first(where: { C6ConfigurationSync.mediaSourceMatches(printer, selected: $0) }) else { continue }
            if printer.sourceHA && c6SyncedPictureOrigins[deviceID] != c6CurrentPictureOrigin { continue }
            let devices = enabledDevices(for: printer.sourceFormlabs ? .formlabs : .bambuLab)
            if let index = devices.firstIndex(where: { item in
                if printer.sourceFormlabs {
                    let connection = item.settings.formlabsConnection
                    return connection?.printerSerial == match.serial && connection?.clientID == match.formClientID
                }
                if printer.sourceHA { return item.id.uuidString.replacingOccurrences(of: "-", with: "") == match.serial }
                return item.settings.bambuMQTT?.serial == match.serial
                    && item.settings.bambuMQTT?.host == match.host
                    && item.settings.bambuDataSource == .localMQTT
            }), let mode = DisplayMode(rawValue: (printer.sourceFormlabs ? DisplayMode.formlabs.rawValue : DisplayMode.bambuLab.rawValue) + index) {
                mappings[C6MergedCardPolicy.printerIdentity(printer, configuration: local)] = mode
            }
        }
        return C6MergedCardPolicy.descriptors(settings: config, configuration: local,
            softwareModes: availableAIMacCardModes, printerDisplayModes: mappings).map { descriptor in
                var card = descriptor
                if card.nativeCard == nil, let mode = card.displayMode { card.title = menuTitle(for: mode) }
                return card
            }
    }

    public func c6CardList(for deviceID: UUID) -> [C6CardDescriptor] {
        allC6Cards(for: deviceID).filter(\.visible)
    }
    public func c6HiddenCardList(for deviceID: UUID) -> [C6CardDescriptor] {
        allC6Cards(for: deviceID).filter { !$0.visible }
    }
    public func c6CardRotationList(for deviceID: UUID) -> [C6CardDescriptor] {
        c6CardList(for: deviceID).filter(\.participatesInRotation)
    }
    public func selectedC6Card(for deviceID: UUID) -> C6CardDescriptor? {
        let config = aiMacScreenSettings(for: deviceID)
        guard config.mode == .card || config.mode == .clock else { return nil }
        let cards = allC6Cards(for: deviceID)
        if config.mode == .clock || (config.c6NativeCardID == nil && config.cardMode == .aiMacClock) {
            return cards.first { $0.nativeCard?.kind == "clock" }
        }
        if let id = config.c6NativeCardID { return cards.first { $0.nativeCard?.id == id } }
        return cards.first { $0.nativeCard == nil && $0.displayMode == config.cardMode }
    }
    public func isCurrentC6Card(deviceID: UUID, card: C6CardDescriptor) -> Bool {
        selectedC6Card(for: deviceID)?.id == card.id
    }
    public func activateC6Card(_ card: C6CardDescriptor, deviceID: UUID) {
        guard allC6Cards(for: deviceID).contains(where: { $0.id == card.id }) else { return }
        if let native = card.nativeCard {
            mutateAIMacScreenSettings(deviceID, schedulePush: false) { config in
                config.mode = .card; config.c6NativeCardID = native.id
                config.cardMode = native.displayMode ?? .systemMonitor
                config.smartRotationReturnContentMode = nil
                config.smartRotationReturnCardModeRawValue = nil
                config.smartRotationReturnPrinterDeviceID = nil
                config.smartRotationReturnC6NativeCardID = nil
            }
            aiMacScreenLastCardRotation[deviceID] = Date()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.c6CardOptionTasks[deviceID]?.value
                await self.pushAIMacScreen(deviceID: deviceID, force: true)
            }
        } else if let mode = card.displayMode { activateAIMacCard(mode, deviceID: deviceID) }
    }
    public func setC6CardVisible(_ card: C6CardDescriptor, visible: Bool, deviceID: UUID) {
        if card.nativeCard == nil, let mode = card.displayMode {
            setAIMacCardVisible(mode, visible: visible, deviceID: deviceID); return
        }
        var ids = allC6Cards(for: deviceID).filter { $0.nativeCard != nil && $0.visible }.compactMap { $0.nativeCard?.id }
        guard let native = card.nativeCard else { return }
        if visible { if !ids.contains(native.id) { ids.append(native.id) } }
        else { ids.removeAll { $0 == native.id } }
        mutateAIMacScreenSettings(deviceID, schedulePush: false) { $0.c6NativeCardPanels = ids }
        saveC6NativeCardOptions(deviceID: deviceID)
    }
    public func setC6CardRotation(_ card: C6CardDescriptor, enabled: Bool, deviceID: UUID) {
        if card.nativeCard == nil, let mode = card.displayMode {
            setAIMacCardRotationMode(mode, enabled: enabled, deviceID: deviceID); return
        }
        var ids = allC6Cards(for: deviceID).filter { $0.nativeCard != nil && $0.participatesInRotation }.compactMap { $0.nativeCard?.id }
        guard let native = card.nativeCard else { return }
        if enabled { if !ids.contains(native.id) { ids.append(native.id) } }
        else { ids.removeAll { $0 == native.id } }
        mutateAIMacScreenSettings(deviceID, schedulePush: false) { $0.c6NativeCardRotationIDs = ids }
        saveC6NativeCardOptions(deviceID: deviceID)
    }
    public func commitC6CardOrder(_ cards: [C6CardDescriptor], deviceID: UUID) {
        let all = allC6Cards(for: deviceID)
        let order = C6MergedCardPolicy.normalizedOrder(cards.map(\.id) + all.filter { !$0.visible }.map(\.id), availableIDs: all.map(\.id))
        mutateAIMacScreenSettings(deviceID, schedulePush: false) { $0.c6MergedCardOrder = order }
    }

    private func invalidateC6CardOptionTasks(deviceID id: UUID) {
        c6CardOptionTasks.removeValue(forKey: id)?.cancel()
        c6CardOptionTaskIDs[id] = nil
        c6CardOptionEpochs[id] = nil
    }
    private func isCurrentC6CardOptionTarget(_ id: UUID, host: String, epoch: UUID) -> Bool {
        !Task.isCancelled && !c6PreparingForQuit && c6CardOptionEpochs[id] == epoch
            && isCurrentColorScreenTarget(id, host: host)
    }
    private func finishC6CardOptionTask(deviceID id: UUID, operationID: UUID) {
        guard c6CardOptionTaskIDs[id] == operationID else { return }
        c6CardOptionTaskIDs[id] = nil
        c6CardOptionTasks[id] = nil
    }

    /// Patch only local card participation. Conflict retries reread the device, so
    /// unrelated web edits and credentials are never overwritten by a stale snapshot.
    private func saveC6NativeCardOptions(deviceID id: UUID) {
        guard !c6PreparingForQuit else { return }
        let host = AIMacScreenSupport.normalizedHost(aiMacScreenSettings(for: id).host)
        let epoch = c6CardOptionEpochs[id] ?? UUID()
        let operationID = UUID()
        c6CardOptionEpochs[id] = epoch
        c6CardOptionTaskIDs[id] = operationID
        let previous = c6CardOptionTasks[id]
        c6CardOptionTasks[id] = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.finishC6CardOptionTask(deviceID: id, operationID: operationID) }
            guard self.isCurrentC6CardOptionTarget(id, host: host, epoch: epoch), !self.c6OfflineSimulationIDs.contains(id) else { return }
            do {
                let token = self.c6Tokens[id] ?? C6SecretStore.read(deviceID: id)
                let client = try C6StandaloneClient(host: host)
                for attempt in 0..<2 {
                    var latest = try await client.read(token: token)
                    guard self.isCurrentC6CardOptionTarget(id, host: host, epoch: epoch), !self.c6OfflineSimulationIDs.contains(id) else { return }
                    let desired = self.aiMacScreenSettings(for: id)
                    let cards = C6MergedCardPolicy.descriptors(settings: desired, configuration: latest,
                        softwareModes: self.availableAIMacCardModes)
                    for (kind, bit) in [("clock", 0), ("diagnostics", 1), ("weather", 2), ("ha", 3)] {
                        let local = cards.filter { $0.nativeCard?.kind == kind }
                        if local.contains(where: { $0.visible && $0.participatesInRotation }) { latest.cardMask |= 1 << bit }
                        else { latest.cardMask &= ~(1 << bit) }
                        if local.contains(where: \.visible) {
                            if kind == "clock" { latest.clock = true }
                            if kind == "diagnostics" { latest.diagnostics = true }
                            if kind == "weather" { latest.weather = true }
                            if kind == "ha" { latest.ha.enabled = true }
                            latest.enabled = true
                        }
                    }
                    for index in latest.printers.indices {
                        let identity = C6MergedCardPolicy.printerIdentity(latest.printers[index], configuration: latest)
                        if let card = cards.first(where: { $0.nativeCard?.id == "printer:" + Self.sha256(Data(identity.utf8)) }) {
                            latest.printers[index].rotate = card.visible && card.participatesInRotation
                            if card.visible { latest.printers[index].enabled = true; latest.enabled = true }
                        }
                    }
                    do {
                        let saved = try await client.save(latest, token: token, credentials: C6Credentials())
                        guard self.isCurrentC6CardOptionTarget(id, host: host, epoch: epoch), !self.c6OfflineSimulationIDs.contains(id) else { return }
                        self.didUpdateC6DeviceConfiguration(saved, deviceID: id, host: host)
                        self.c6SyncStatuses[id] = "在线卡片选择已保存 · 本地轮询资格已同步"
                        return
                    } catch C6StandaloneError.conflict where attempt == 0 { continue }
                }
            } catch {
                guard self.isCurrentC6CardOptionTarget(id, host: host, epoch: epoch) else { return }
                self.c6SyncStatuses[id] = "本地卡片设置未保存到设备：\(error.localizedDescription)"
            }
        }
    }

    public func refreshC6NativeCardPreview(deviceID id: UUID) async {
        guard let card = selectedC6Card(for: id), card.nativeCard != nil,
              c6NativeCardSelections[id] == card.nativeCard?.headers else { return }
        let host = AIMacScreenSupport.normalizedHost(aiMacScreenSettings(for: id).host)
        guard isCurrentColorScreenTarget(id, host: host), !c6OfflineSimulationIDs.contains(id) else { return }
        do {
            let token = c6Tokens[id] ?? C6SecretStore.read(deviceID: id)
            let bytes = try await C6StandaloneClient(host: host).previewFrame(token: token)
            guard !Task.isCancelled, isCurrentColorScreenTarget(id, host: host),
                  selectedC6Card(for: id)?.id == card.id, let image = AIMacScreenSupport.decodeRGB565(bytes) else { return }
            aiMacScreenPreviews[id] = NSImage(cgImage: image, size: NSSize(width: 240, height: 240))
        } catch { /* A preview read never changes selection or interrupts rotation. */ }
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

    /// AI Mac 的 Home Assistant 卡片实体按小屏幕设备隔离。旧档案没有该字段时，
    /// 首次显示兼容原键盘卡片选择；一旦用户编辑便写成该设备自己的明确列表。
    public func aiMacHAEntityIDs(for deviceID: UUID) -> [String] {
        aiMacScreenSettings(for: deviceID).haCardEntityIDs ?? settings.haCardEntityIDs
    }

    public func setAIMacHAEntityIDs(_ entityIDs: [String], deviceID: UUID) {
        let cleaned = HAEntityListEditor.merge([], adding: entityIDs)
        mutateAIMacScreenSettings(deviceID, schedulePush: false) {
            $0.haCardEntityIDs = cleaned
        }
        guard isCurrentAIMacCard(deviceID: deviceID, mode: .homeAssistant) else { return }
        Task { @MainActor [weak self] in
            await self?.refreshAIMacCardDataAndPush(mode: .homeAssistant,
                                                    deviceID: deviceID)
        }
    }

    public func addAIMacHAEntities(_ entityIDs: [String], deviceID: UUID) {
        setAIMacHAEntityIDs(
            HAEntityListEditor.merge(aiMacHAEntityIDs(for: deviceID), adding: entityIDs),
            deviceID: deviceID)
    }

    public func removeAIMacHAEntity(_ entityID: String, deviceID: UUID) {
        setAIMacHAEntityIDs(aiMacHAEntityIDs(for: deviceID).filter { $0 != entityID },
                           deviceID: deviceID)
    }

    public func replaceAIMacHAEntity(oldID: String, newID: String, deviceID: UUID) {
        let target = newID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != oldID else { return }
        var list = aiMacHAEntityIDs(for: deviceID)
        guard let index = list.firstIndex(of: oldID) else { return }
        if list.contains(target) { list.remove(at: index) } else { list[index] = target }
        if let alias = settings.haEntityAliases.removeValue(forKey: oldID) {
            settings.haEntityAliases[target] = alias
        }
        setAIMacHAEntityIDs(list, deviceID: deviceID)
    }

    public func aiMacHAEntitiesBinding(for deviceID: UUID) -> Binding<[String]> {
        Binding(get: { self.aiMacHAEntityIDs(for: deviceID) },
                set: { self.setAIMacHAEntityIDs($0, deviceID: deviceID) })
    }

    /// 按能力目录刷新一张卡片真正依赖的数据，再向目标小屏推送；不改变灵犀 68 当前卡片。
    private func refreshAIMacCardDataAndPush(mode: DisplayMode, deviceID: UUID) async {
        guard let capability = CardCapabilityRegistry.capability(for: mode),
              isCurrentAIMacCard(deviceID: deviceID, mode: mode) else { return }
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
        if mode == .homeAssistant {
            let ids = HAEntityPicker.pictureEntityIDs(
                in: aiMacHAEntityIDs(for: deviceID))
            // 先完成所选静态帧，再一次性推送最终画面；保留失败时的上一帧缓存，
            // 不先发无图卡片再补图，避免低帧率摄像头切入时闪烁。
            _ = await refreshHAPictures(entities: haSnapshot.entities, wantedIDs: ids)
        }
        guard isCurrentAIMacCard(deviceID: deviceID, mode: mode) else { return }
        let presentation = aiMacScreenSettings(for: deviceID)
        let presentationHost = AIMacScreenSupport.normalizedHost(presentation.host)
        let pictureOrigin = c6CurrentPictureOrigin
        await pushAIMacScreen(deviceID: deviceID, force: true)
        if mode.bambuSlotIndex != nil {
            let config = bambuConfig(for: mode)
            // AI Mac 的独立打印机卡同时显示实况与任务封面。两张图合并为一次
            // 图片刷新流程，仍沿用内容哈希去重，不增加新的轮询定时器。
            let pictureIDs = [config.imageEntityID, config.taskImageEntityID]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if config.showImage, !pictureIDs.isEmpty,
               await refreshHAPictures(entities: haSnapshot.entities,
                                       wantedIDs: pictureIDs) {
                guard isCurrentAIMacCard(deviceID: deviceID, mode: mode),
                      isCurrentColorScreenPresentation(deviceID, host: presentationHost, config: presentation),
                      c6CurrentPictureOrigin == pictureOrigin,
                      bambuConfig(for: mode) == config else { return }
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
        guard let id = activeColorScreenDeviceID else { return "未命名" }
        let config = aiMacScreenSettings(for: id)
        guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else {
            return CanvasBoardNamingPolicy.untitledName
        }
        return config.canvasBoards[config.canvasBoardIndex].name
    }

    public var aiMacCanvasModules: [CanvasModule] {
        guard let id = activeColorScreenDeviceID else { return [] }
        let config = aiMacScreenSettings(for: id)
        guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return [] }
        return config.canvasBoards[config.canvasBoardIndex].moduleList
    }

    private func mutateCurrentAIMacCanvasBoard(
        pushImmediately: Bool = true,
        schedulePush: Bool = true,
        _ body: (inout AIMacCanvasBoard) -> Void
    ) {
        guard let id = activeColorScreenDeviceID else { return }
        mutateAIMacScreenSettings(id, pushImmediately: pushImmediately,
                                  schedulePush: false) { config in
            guard config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return }
            body(&config.canvasBoards[config.canvasBoardIndex])
            config.canvasBoards[config.canvasBoardIndex].clamp()
            config.mode = .canvas
        }
        let config = aiMacScreenSettings(for: id)
        if schedulePush && (pushImmediately || config.autoPush) {
            scheduleCurrentAIMacCanvasPicturesAndPush(deviceID: id)
        }
    }

    public func addAIMacCanvasBoard() {
        guard let id = activeColorScreenDeviceID else { return }
        mutateAIMacScreenSettings(id, pushImmediately: true) { config in
            config.canvasBoards.append(AIMacCanvasBoard())
            config.canvasBoardIndex = config.canvasBoards.count - 1
            config.mode = .canvas
        }
        aiMacScreenLastBoardRotation[id] = Date()
        aiMacScreenStatuses[id] = "已创建空白画板，添加第一个模块后会自动命名"
    }

    public func applyAIMacCanvasBoard(deviceID: UUID, boardID: UUID) {
        selectColorScreen(deviceID: deviceID)
        mutateAIMacScreenSettings(deviceID, schedulePush: false) { config in
            guard let index = config.canvasBoards.firstIndex(where: { $0.id == boardID }) else { return }
            config.canvasBoardIndex = index
            config.mode = .canvas
        }
        aiMacScreenLastBoardRotation[deviceID] = Date()
        scheduleCurrentAIMacCanvasPicturesAndPush(deviceID: deviceID)
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
        mutateAIMacScreenSettings(deviceID, schedulePush: false) { value in
            value.canvasBoardIndex = nextIndex
            value.mode = .canvas
        }
        aiMacScreenLastBoardRotation[deviceID] = Date()
        if !automaticRotation {
            scheduleCurrentAIMacCanvasPicturesAndPush(deviceID: deviceID)
        }
        return true
    }

    /// 当前 AI Mac 画板如果包含 Home Assistant 图片/摄像头，先补齐缺失静态帧，
    /// 再确认画板与实体选择没有在等待期间变化。这样首次添加、手动切板和自动轮换
    /// 都不会先推一张“等待画面”的过渡帧；已有缓存时不会额外访问网络。
    @discardableResult
    private func prepareCurrentAIMacCanvasPictures(deviceID: UUID) async -> Bool {
        let config = aiMacScreenSettings(for: deviceID)
        guard config.mode == .canvas,
              config.canvasBoards.indices.contains(config.canvasBoardIndex) else { return false }
        let board = config.canvasBoards[config.canvasBoardIndex]
        let expectedBoardID = board.id
        let expectedEntityIDs = board.haEntityIDs
        if board.moduleList.contains(.homeAssistant) {
            let pictureIDs = HAEntityPicker.pictureEntityIDs(in: expectedEntityIDs)
            let missing = pictureIDs.filter { haSnapshot.picture(for: $0) == nil }
            if !missing.isEmpty {
                _ = await refreshHAPictures(entities: haSnapshot.entities, wantedIDs: missing)
            }
        }
        let current = aiMacScreenSettings(for: deviceID)
        guard current.mode == .canvas,
              current.canvasBoards.indices.contains(current.canvasBoardIndex) else { return false }
        let currentBoard = current.canvasBoards[current.canvasBoardIndex]
        return currentBoard.id == expectedBoardID
            && currentBoard.haEntityIDs == expectedEntityIDs
    }

    /// 每台设备只保留最后一次画板准备请求。设置连续变化或切板时取消旧任务；
    /// 若设备正上传，则等待完成后再校验当前画板并补推，避免修改永久丢失。
    private func scheduleCurrentAIMacCanvasPicturesAndPush(deviceID: UUID) {
        aiMacCanvasPicturePreparationTasks[deviceID]?.cancel()
        let generation = (aiMacCanvasPicturePreparationGenerations[deviceID] ?? 0) &+ 1
        aiMacCanvasPicturePreparationGenerations[deviceID] = generation
        aiMacCanvasPicturePreparationTasks[deviceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.aiMacCanvasPicturePreparationGenerations[deviceID] == generation {
                    self.aiMacCanvasPicturePreparationTasks[deviceID] = nil
                }
            }
            guard await self.prepareCurrentAIMacCanvasPictures(deviceID: deviceID),
                  !Task.isCancelled,
                  self.aiMacCanvasPicturePreparationGenerations[deviceID] == generation else { return }
            while self.aiMacScreenBusyIDs.contains(deviceID) {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                guard self.aiMacCanvasPicturePreparationGenerations[deviceID] == generation else { return }
            }
            // 上传等待期间仍可能切到原生时钟或另一张卡片；再核验一次，且缓存
            // 已齐时不会重复下载。
            guard await self.prepareCurrentAIMacCanvasPictures(deviceID: deviceID),
                  !Task.isCancelled,
                  self.aiMacCanvasPicturePreparationGenerations[deviceID] == generation else { return }
            await self.pushAIMacScreen(deviceID: deviceID, force: true)
        }
    }

    public func renameAIMacCanvasBoard(id boardID: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              let deviceID = activeColorScreenDeviceID else { return }
        mutateAIMacScreenSettings(deviceID) { config in
            guard let index = config.canvasBoards.firstIndex(where: { $0.id == boardID }) else { return }
            config.canvasBoards[index].name = clean
        }
    }

    public func setAIMacCanvasBoardSidebarVisible(id boardID: UUID, visible: Bool) {
        guard let deviceID = activeColorScreenDeviceID else { return }
        mutateAIMacScreenSettings(deviceID) { config in
            guard let index = config.canvasBoards.firstIndex(where: { $0.id == boardID }) else { return }
            config.canvasBoards[index].sidebarVisible = visible
        }
    }

    public func setAIMacCanvasBoardRotationEnabled(id boardID: UUID, enabled: Bool) {
        guard let deviceID = activeColorScreenDeviceID else { return }
        mutateAIMacScreenSettings(deviceID) { config in
            guard let index = config.canvasBoards.firstIndex(where: { $0.id == boardID }) else { return }
            config.canvasBoards[index].rotationEnabled = enabled
        }
    }

    public func removeAIMacCanvasBoard(id boardID: UUID) {
        guard let deviceID = activeColorScreenDeviceID else { return }
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
        guard let deviceID = activeColorScreenDeviceID else { return }
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
                                   nowPlayingOverride: NowPlayingInfo? = nil,
                                   now: Date = Date()) throws -> CGImage {
        let deviceType = settings.devices.first { $0.id == deviceID }?.type ?? .aiMacScreen
        // A C6 clock can only be shown by selecting the native device card.
        // Refuse even legacy/generic render calls rather than fabricate its style.
        if deviceType == .c6Screen,
           config.c6NativeCardID != nil || config.mode == .clock || (config.mode == .card && config.cardMode == .aiMacClock) {
            throw C6StandaloneError.unsupported
        }
        let isNativeClock = config.mode == .clock
            || (config.mode == .card && config.cardMode == .aiMacClock)
        let isEmojiWallpaper = config.mode == .card && config.cardMode == .emojiWallpaper
        let dark: Bool
        if config.mode == .canvas {
            let board = config.canvasBoards.indices.contains(config.canvasBoardIndex)
                ? config.canvasBoards[config.canvasBoardIndex] : AIMacCanvasBoard()
            dark = board.backgroundMode == .dark
        } else {
            dark = settings.softwareIsDark
        }
        let palette = ScreenThemes.resolved(
            theme: settings.cardTheme,
            backgroundTone: dark ? .dark : .light,
            customBackgroundHex: nil,
            accentTone: settings.accentTone,
            customAccentHex: settings.customAccentHex,
            softwareIsDark: dark,
            renderingMode: (isNativeClock || isEmojiWallpaper) ? .classic : settings.cardRenderingMode)
        // 设备端桌面时钟保留固件实际样式；其他彩色卡片的预览和推送共享同一张成图。
        let image = try LiquidGlassCardRenderer.renderImage(
            for: deviceType, mode: (isNativeClock || isEmojiWallpaper) ? .classic : settings.cardRenderingMode,
            palette: palette) {
                try self.renderAIMacScreenClassic(
                    deviceID: deviceID, config: config, system: snapshot,
                    nowPlayingOverride: nowPlayingOverride, now: now)
            }
        // 校准在玻璃合成之后统一执行，Emoji 也只校准颜色、不增加玻璃。
        // 桌面时钟由固件自行渲染，预览不能添加固件不会显示的色彩处理。
        let calibrated = isNativeClock ? image : AIMacColorCalibration.apply(to: image, settings: config)
        // C6 在固件显示层统一旋转，传输图片与软件预览保持正向；灵犀68也不走此路径。
        guard AIMacScreenSupport.needsSoftwareRotation(deviceType: deviceType,
            rotate180: config.rotate180, isNativeClock: isNativeClock) else { return calibrated }
        guard let context = CGContext(data: nil, width: calibrated.width, height: calibrated.height,
            bitsPerComponent: 8, bytesPerRow: calibrated.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return calibrated }
        context.translateBy(x: CGFloat(calibrated.width), y: CGFloat(calibrated.height))
        context.rotate(by: .pi)
        context.draw(calibrated, in: CGRect(x: 0, y: 0, width: calibrated.width, height: calibrated.height))
        return context.makeImage() ?? calibrated
    }

    private func renderAIMacScreenClassic(deviceID: UUID,
                                          config: AIMacScreenDeviceSettings,
                                          system snapshot: SystemSnapshot,
                                          nowPlayingOverride: NowPlayingInfo? = nil,
                                          now: Date = Date()) throws -> CGImage {
        let playbackInfo = nowPlayingOverride ?? nowPlaying
        if config.mode == .card {
            return try renderAIMacCard(deviceID: deviceID, mode: config.cardMode,
                                       config: config, system: snapshot,
                                       nowPlaying: playbackInfo, now: now)
        }
        guard config.mode == .canvas else {
            return try AIMacScreenSupport.render(settings: config, system: snapshot, now: now,
                c6FlipClock: settings.devices.first { $0.id == deviceID }?.type == .c6Screen)
        }
        let board = config.canvasBoards.indices.contains(config.canvasBoardIndex)
            ? config.canvasBoards[config.canvasBoardIndex] : AIMacCanvasBoard()
        let dark = board.backgroundMode == .dark
        let palette = ScreenThemes.resolved(theme: settings.cardTheme,
                                            backgroundTone: dark ? .dark : .light,
                                            customBackgroundHex: nil,
                                            accentTone: settings.accentTone,
                                            customAccentHex: settings.customAccentHex,
                                            softwareIsDark: dark,
                                            renderingMode: settings.cardRenderingMode)
        return ScreenRenderer.renderDeviceCanvas(
            modules: board.moduleList, system: snapshot,
            nowPlaying: playbackInfo, pomodoro: pomodoroSnapshot,
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
                                 nowPlaying playbackInfo: NowPlayingInfo,
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
        case .nativeClock:
            // 软件端仅保留外观预览；真正的时间计算、秒级刷新和绘制均由固件完成。
            var previewConfig = config
            previewConfig.mode = .clock
            return try AIMacScreenSupport.render(settings: previewConfig,
                                                 system: snapshot, now: now,
                c6FlipClock: settings.devices.first { $0.id == deviceID }?.type == .c6Screen)
        case .deviceCanvas:
            // AI Mac 的设备画板走上层 canvas 分支；通用卡片列表不会暴露这一配方。
            throw AIMacScreenSupportError.encodeFailed
        case .modules(let modules):
            let visibleModules = mode == .systemMonitor
                ? aiMacSystemMonitorModules(for: deviceID) : modules
            let dark = settings.softwareIsDark
            let palette = ScreenThemes.resolved(
                theme: settings.cardTheme,
                backgroundTone: dark ? .dark : .light,
                customBackgroundHex: nil,
                accentTone: settings.accentTone,
                customAccentHex: settings.customAccentHex,
                softwareIsDark: dark,
                renderingMode: settings.cardRenderingMode)
            let cardHA = mode == .homeAssistant
                ? haSnapshot.selecting(entityIDs: aiMacHAEntityIDs(for: deviceID))
                : haSnapshot
            if mode.bambuSlotIndex != nil {
                let bambu = bambuConfig(for: mode)
                let cameraID = bambu.imageEntityID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cameraRaw = cameraID.isEmpty ? nil : haSnapshot.picture(for: cameraID)
                let cameraFrame = bambu.autoCameraZoom
                    ? (bambuAutoZoomImages[cameraID] ?? cameraRaw) : cameraRaw
                let taskCoverID = bambu.taskImageEntityID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var taskCover = taskCoverID.isEmpty
                    ? nil : haSnapshot.picture(for: taskCoverID)
                if settings.devices.first(where: { $0.id == deviceID })?.type == .c6Screen {
                    // Restoring the established layout must not revive a cached
                    // cover belonging to another task or HA server connection.
                    let key = haSnapshot.entities.first { $0.entityId == bambu.taskEntityID }
                        .flatMap { C6TaskThumbnail.homeAssistantTaskKey($0.state) }
                    if key == nil || c6PictureTaskKeys[taskCoverID]?[bambu.taskEntityID] != key
                        || c6PictureOrigins[taskCoverID] != c6CurrentPictureOrigin {
                        taskCover = nil
                    }
                }
                return ScreenRenderer.renderAIMacBambuCard(
                    bambu, entities: haSnapshot.entities,
                    cameraImage: cameraFrame, taskCoverImage: taskCover,
                    settings: settings, sampledAt: haSnapshot.sampledAt,
                    palette: palette,
                    width: AIMacScreenSupport.frameSize,
                    height: AIMacScreenSupport.frameSize)
            }
            let articles = mode == .sspai ? Array(sspaiArticles.prefix(3)) : []
            var fields: [Int: CanvasPrinterFields] = [:]
            for module in modules where module.bambuSlotIndex != nil || module.formlabsSlotIndex != nil {
                fields[module.rawValue] = settings.canvasPrinterFields(for: module)
            }
            return ScreenRenderer.renderDeviceCanvas(
                modules: visibleModules, system: snapshot,
                nowPlaying: playbackInfo, pomodoro: pomodoroSnapshot,
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

    public func refreshAIMacScreenPreview(deviceID: UUID,
                                          simulateTransport: Bool = false) {
        guard !c6OfflineSimulationIDs.contains(deviceID) else { return }
        let config = aiMacScreenSettings(for: deviceID)
        if settings.devices.first(where: { $0.id == deviceID })?.type == .c6Screen,
           selectedC6Card(for: deviceID)?.nativeCard != nil {
            // Native cards use the actual device frame, never a desktop clock
            // approximation that could disagree with its style or timezone.
            if c6NativeCardSelections[deviceID] != selectedC6Card(for: deviceID)?.nativeCard?.headers {
                aiMacScreenPreviews[deviceID] = nil
            }
            return
        }
        if aiMacScreenCapabilities[deviceID]?.prefersNativeCards == true,
           c6NativeCardSelections[deviceID] == c6CardContextHeaders(config: config) { return }
        do {
            let image = try renderAIMacScreen(deviceID: deviceID, config: config,
                                              system: system)
            let previewImage = simulateTransport
                ? aiMacScreenTransportPreview(image, deviceID: deviceID, config: config)
                : image
            aiMacScreenPreviews[deviceID] = NSImage(
                cgImage: previewImage, size: NSSize(width: 240, height: 240))
        } catch {
            aiMacScreenPreviews[deviceID] = nil
            aiMacScreenStatuses[deviceID] = error.localizedDescription
        }
    }

    /// 已知设备能力时把最终 RGB565/JPEG 字节反解回来，预览因此包含与实机
    /// 相同的通道量化或 JPEG 压缩；未连接过的设备只能显示原始渲染近似值。
    private func aiMacScreenTransportPreview(
        _ image: CGImage, deviceID: UUID, config: AIMacScreenDeviceSettings
    ) -> CGImage {
        guard let capabilities = aiMacScreenCapabilities[deviceID] else { return image }
        if capabilities.supportsLosslessRGB565,
           let data = try? AIMacScreenSupport.encodeRGB565(image),
           let decoded = AIMacScreenSupport.decodeRGB565(data) {
            return decoded
        }
        guard let data = try? AIMacScreenSupport.encodeJPEG(
            image, preferredQuality: config.jpegQuality),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return image }
        return decoded
    }

    private func isCurrentColorScreenTarget(_ deviceID: UUID, host: String) -> Bool {
        !c6PreparingForQuit && settings.devices.contains {
            $0.id == deviceID && $0.isEnabled && $0.type.isColorWiFiScreen
                && AIMacScreenSupport.normalizedHost($0.settings.aiMacScreen?.host ?? "") == host
        }
    }

    private func isCurrentColorScreenPresentation(_ id: UUID, host: String,
                                                 config: AIMacScreenDeviceSettings) -> Bool {
        let current = aiMacScreenSettings(for: id)
        return isCurrentColorScreenTarget(id, host: host)
            && AIMacSmartRotationTarget(current) == AIMacSmartRotationTarget(config)
            && current.canvasBoardIndex == config.canvasBoardIndex
            && current.customImagePath == config.customImagePath
    }

    private func fetchAIMacScreenCapabilities(
        deviceID: UUID,
        force: Bool = false,
        timeout: TimeInterval = 4,
        allowJPEGFallback: Bool = true
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
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard isCurrentColorScreenTarget(deviceID, host: host) else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw AIMacScreenSupportError.invalidDevice
            }
            let capabilities = try AIMacScreenSupport.parseCapabilities(data: data, host: host)
            if capabilities.isC6, let index = settings.devices.firstIndex(where: { $0.id == deviceID && $0.type == .aiMacScreen }) {
                // Older test builds registered C6 as AI Mac. Preserve UUID, choices and credentials.
                var devices = settings.devices; devices[index].type = .c6Screen
                settings.devices = devices
                if settings.activeAIMacScreenDeviceID == deviceID {
                    settings.activeAIMacScreenDeviceID = enabledDevices(for: .aiMacScreen).first?.id
                }
                if settings.activeC6ScreenDeviceID == nil { settings.activeC6ScreenDeviceID = deviceID }
                persistSettings()
            }
            aiMacScreenCapabilities[deviceID] = capabilities
            if let brightness = capabilities.brightnessLevel, brightness > 0 {
                aiMacScreenSavedBrightness[deviceID] = brightness
            }
            return capabilities
        } catch {
            guard isCurrentColorScreenTarget(deviceID, host: host) else { throw CancellationError() }
            if !allowJPEGFallback { throw error }
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
        defer {
            aiMacScreenBusyIDs.remove(deviceID)
            if c6PendingForcedPushIDs.remove(deviceID) != nil,
               settings.devices.contains(where: { $0.id == deviceID && $0.isEnabled && $0.type == .c6Screen }) {
                Task { @MainActor [weak self] in
                    await self?.pushAIMacScreen(deviceID: deviceID, force: true)
                }
            }
        }
        do {
            let capabilities = try await fetchAIMacScreenCapabilities(deviceID: deviceID, force: true)
            if capabilities.supportsLosslessRGB565 {
                aiMacScreenLosslessIDs.insert(deviceID)
                aiMacScreenStatuses[deviceID] = "连接成功 · RGB565 无损模式"
            } else {
                aiMacScreenLosslessIDs.remove(deviceID)
                aiMacScreenStatuses[deviceID] = "地址可用 · JPEG 兼容模式"
            }
            if aiMacScreenSettings(for: deviceID).autoPush {
                // “连接测试”也代表一次明确的重新上线。把自动推送节拍提前到
                // 下一秒执行，用户无需再手动点一次推送才能看到首帧。
                aiMacScreenLastHashes[deviceID] = nil
                aiMacScreenLastPushAt[deviceID] = nil
            }
            refreshAIMacScreenPreview(deviceID: deviceID, simulateTransport: true)
        } catch {
            aiMacScreenStatuses[deviceID] = "连接失败：\(error.localizedDescription)"
        }
    }

    /// 系统锁屏/睡眠状态入口。相同状态的多条系统通知会被合并，避免重复请求。
    public func handleAIMacSystemSleepChange(sleeping: Bool) async {
        guard aiMacScreensSystemSleeping != sleeping else { return }
        aiMacScreensSystemSleeping = sleeping
        let targets = enabledColorWiFiScreens.filter {
            ($0.settings.aiMacScreen ?? AIMacScreenDeviceSettings()).followSystemSleep
                && !AIMacScreenSupport.normalizedHost(
                    ($0.settings.aiMacScreen ?? AIMacScreenDeviceSettings()).host).isEmpty
        }
        await withTaskGroup(of: Void.self) { group in
            for device in targets {
                guard !self.c6PreparingForQuit, !Task.isCancelled else { return }
                group.addTask { [weak self] in
                    await self?.setAIMacScreenPower(deviceID: device.id, sleeping: sleeping)
                }
            }
        }
    }

    /// 启动时修复“应用在锁屏期间被退出”留下的熄屏状态；若系统仍锁定则保持熄屏。
    public func reconcileAIMacPowerAfterLaunch(systemLocked: Bool) async {
        if systemLocked {
            await handleAIMacSystemSleepChange(sleeping: true)
            return
        }
        aiMacScreensSystemSleeping = false
        let targets = enabledColorWiFiScreens.filter {
            ($0.settings.aiMacScreen ?? AIMacScreenDeviceSettings()).followSystemSleep
        }
        for device in targets {
            guard let capabilities = try? await fetchAIMacScreenCapabilities(
                deviceID: device.id, force: true, timeout: 1.5),
                  capabilities.brightnessLevel == 0 else { continue }
            let config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
            aiMacScreenSavedBrightness[device.id] = config.awakeBrightness ?? 100
            await setAIMacScreenPower(deviceID: device.id, sleeping: false)
        }
    }

    /// 使用固件背光接口真正熄屏；同一设备的请求按事件顺序串行，最后一次状态一定胜出。
    private func setAIMacScreenPower(deviceID: UUID, sleeping: Bool) async {
        let previousTask = aiMacScreenPowerTasks[deviceID]
        let generation = (aiMacScreenPowerGenerations[deviceID] ?? 0) &+ 1
        aiMacScreenPowerGenerations[deviceID] = generation
        let operation = Task { @MainActor [weak self] () -> Bool in
            _ = await previousTask?.value
            guard !Task.isCancelled, let self else { return false }
            return await self.applyAIMacScreenPower(deviceID: deviceID, sleeping: sleeping)
        }
        aiMacScreenPowerTasks[deviceID] = operation
        let succeeded = await operation.value
        guard aiMacScreenPowerGenerations[deviceID] == generation else { return }
        aiMacScreenPowerTasks[deviceID] = nil
        guard succeeded, !sleeping, !aiMacScreenShouldSleep(deviceID: deviceID) else { return }

        // 如果唤醒正好撞上旧推送收尾，短暂等待后重试，确保一定补上一帧。
        for _ in 0..<5 {
            if !aiMacScreenBusyIDs.contains(deviceID) {
                aiMacScreenLastHashes[deviceID] = nil
                await pushAIMacScreen(deviceID: deviceID, force: true)
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func applyAIMacScreenPower(deviceID: UUID, sleeping: Bool) async -> Bool {
        // 唤醒时网络接口可能比系统唤醒通知晚一点恢复，做少量有限重试；
        // 睡眠前则只尝试一次，避免阻塞系统进入睡眠。
        let attempts = sleeping ? 1 : 3
        var resolvedCapabilities: AIMacScreenCapabilities?
        for attempt in 0..<attempts {
            do {
                resolvedCapabilities = try await fetchAIMacScreenCapabilities(
                    deviceID: deviceID, force: true, timeout: 1.5,
                    allowJPEGFallback: false)
                break
            } catch {
                guard attempt + 1 < attempts else { break }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        guard let capabilities = resolvedCapabilities else { return false }
        guard let brightnessURL = capabilities.brightnessURL else {
            // 旧版固件没有亮度接口；不推黑图，避免覆盖用户正在显示的画面。
            return false
        }
        if sleeping, let brightness = capabilities.brightnessLevel, brightness > 0 {
            aiMacScreenSavedBrightness[deviceID] = brightness
            if aiMacScreenSettings(for: deviceID).awakeBrightness != brightness {
                mutateAIMacScreenSettings(deviceID, schedulePush: false) {
                    $0.awakeBrightness = brightness
                }
            }
        }
        let savedLevel = aiMacScreenSavedBrightness[deviceID]
            ?? aiMacScreenSettings(for: deviceID).awakeBrightness ?? 100
        let targetLevel = sleeping ? 0 : max(1, savedLevel)
        guard let request = AIMacScreenSupport.brightnessRequest(
            url: brightnessURL, level: targetLevel) else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return false }
            if sleeping {
                aiMacScreenStatuses[deviceID] = "已随 Mac 锁屏熄屏"
            } else {
                aiMacScreenStatuses[deviceID] = "已随 Mac 唤醒"
            }
            return true
        } catch {
            // 锁屏/睡眠时网络可能先于通知断开；保持静默，唤醒通知会再次尝试恢复。
            return false
        }
    }

    private func sendAIMacScreenBrightness(deviceID: UUID, level: Int) async -> Bool {
        do {
            let capabilities = try await fetchAIMacScreenCapabilities(
                deviceID: deviceID, force: true, timeout: 2.5,
                allowJPEGFallback: false)
            guard let brightnessURL = capabilities.brightnessURL else {
                aiMacScreenStatuses[deviceID] = "当前固件不支持亮度调节，请升级至 0.8.1 或更新版本"
                return false
            }
            guard let request = AIMacScreenSupport.brightnessRequest(
                url: brightnessURL, level: level) else { return false }
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                aiMacScreenStatuses[deviceID] = "亮度调节失败：设备未接受请求"
                return false
            }
            aiMacScreenSavedBrightness[deviceID] = level
            return true
        } catch {
            aiMacScreenStatuses[deviceID] = "亮度调节失败：\(error.localizedDescription)"
            return false
        }
    }

    private func aiMacScreenShouldSleep(deviceID: UUID) -> Bool {
        aiMacScreensSystemSleeping && aiMacScreenSettings(for: deviceID).followSystemSleep
    }

    public func pushAIMacScreen(deviceID: UUID, force: Bool = true) async {
        await pushAIMacScreen(deviceID: deviceID, force: force, sampleDashboard: true)
    }
    private func maintainC6SoftwareLeases(now: Date) {
        guard !c6PreparingForQuit else { return }
        for id in c6OfflineSimulationIDs where !isCurrentColorScreenTarget(id,
            host: AIMacScreenSupport.normalizedHost(c6OfflineSimulationHosts[id] ?? "")) {
            // Changing or removing a device never carries its paused session to
            // another address. The old hardware's short control lease expires.
            c6OfflineSimulationIDs.remove(id); c6OfflineSimulationHosts[id] = nil
            c6ThumbnailHashes[id] = nil; aiMacButtonState[id] = nil
        }
        guard !c6HeartbeatBusy, c6HeartbeatAt.map({ now.timeIntervalSince($0) >= 10 }) ?? true else { return }
        let targets = enabledDevices(for: .c6Screen).filter {
            c6OfflineSimulationIDs.contains($0.id)
                || (aiMacScreenSettings(for: $0.id).autoPush && !aiMacScreenShouldSleep(deviceID: $0.id))
        }
        guard !targets.isEmpty else { return }
        c6HeartbeatBusy = true; c6HeartbeatAt = now
        c6HeartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.c6HeartbeatBusy = false; self.c6HeartbeatTask = nil }
            for device in targets {
                let host = self.aiMacScreenSettings(for: device.id).host
                guard !self.c6OfflineSimulationBusyIDs.contains(device.id),
                      self.isCurrentColorScreenTarget(device.id, host: AIMacScreenSupport.normalizedHost(host)),
                      let client = try? C6StandaloneClient(host: host) else { continue }
                if self.c6OfflineSimulationIDs.contains(device.id) {
                    guard self.c6OfflineSimulationHosts[device.id] == host else { continue }
                    let token = self.c6Tokens[device.id] ?? C6SecretStore.read(deviceID: device.id)
                    try? await client.simulateSoftwareOffline(true, token: token)
                    continue
                }
                var request = URLRequest(url: client.baseURL.appendingPathComponent("api/software"))
                request.httpMethod = "POST"; request.timeoutInterval = 2
                _ = try? await URLSession.shared.data(for: request)
            }
        }
    }

    private func c6CardContextHeaders(config: AIMacScreenDeviceSettings) -> [String: String] {
        guard config.mode == .card else { return ["X-Lingxi-Card": "generic"] }
        let mode = config.cardMode
        if mode == .weather { return ["X-Lingxi-Card": "weather"] }
        if mode == .homeAssistant { return ["X-Lingxi-Card": "ha"] }
        if mode == .aiMacClock { return ["X-Lingxi-Card": "clock"] }
        var serial: String?, brand = "bambu", source = "ha"
        if let slot = mode.bambuSlotIndex {
            let devices = enabledDevices(for: .bambuLab)
            if devices.indices.contains(slot) {
                let device = devices[slot]
                if device.settings.bambuDataSource == .localMQTT {
                    serial = device.settings.bambuMQTT?.serial; source = "mqtt"
                } else { serial = device.id.uuidString.replacingOccurrences(of: "-", with: "") }
            }
        } else if let slot = mode.formlabsSlotIndex {
            let devices = enabledDevices(for: .formlabs)
            if devices.indices.contains(slot) { serial = devices[slot].settings.formlabsConnection?.printerSerial }
            brand = "formlabs"; source = "formlabs"
        }
        guard let serial, !serial.isEmpty, serial.utf8.count < 40,
              serial.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return ["X-Lingxi-Card": "generic"] }
        return ["X-Lingxi-Card": "printer", "X-Lingxi-Serial": serial,
                "X-Lingxi-Brand": brand, "X-Lingxi-Source": source]
    }

    private func selectedC6NativeCard(deviceID: UUID, config: AIMacScreenDeviceSettings) -> C6NativeCard? {
        guard config.mode == .clock || config.mode == .card else { return nil }
        let cards = C6MergedCardPolicy.nativeCards(configuration: c6SyncedConfigurations[deviceID] ?? C6StandaloneConfiguration())
        if config.mode == .clock || (config.c6NativeCardID == nil && config.cardMode == .aiMacClock) {
            return cards.first { $0.kind == "clock" }
        }
        return cards.first { $0.id == config.c6NativeCardID }
    }

    private func pushAIMacScreen(deviceID: UUID, force: Bool,
                                 sampleDashboard: Bool) async {
        guard !c6PreparingForQuit else { return }
        guard !c6OfflineSimulationIDs.contains(deviceID) else { return }
        guard let device = settings.devices.first(where: {
                  $0.id == deviceID && $0.type.isColorWiFiScreen && $0.isEnabled
              }) else { return }
        guard !aiMacScreenBusyIDs.contains(deviceID) else {
            if device.type == .c6Screen && force { c6PendingForcedPushIDs.insert(deviceID) }
            return
        }
        var config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
        let targetHost = AIMacScreenSupport.normalizedHost(config.host)
        guard !(aiMacScreensSystemSleeping && config.followSystemSleep) else { return }
        guard !AIMacScreenSupport.normalizedHost(config.host).isEmpty else {
            aiMacScreenStatuses[deviceID] = AIMacScreenSupportError.invalidHost.localizedDescription
            return
        }
        aiMacScreenBusyIDs.insert(deviceID)
        aiMacScreenLastPushAt[deviceID] = Date()
        let isNativeClock = config.mode == .clock
            || (config.mode == .card && config.cardMode == .aiMacClock)
        aiMacScreenStatuses[deviceID] = config.c6NativeCardID != nil
            ? "正在切换设备本地卡片…" : isNativeClock
            ? "正在同步设备端时钟…" : "正在生成并推送画面…"
        defer {
            aiMacScreenBusyIDs.remove(deviceID)
            if device.type == .c6Screen {
                let pending = c6PendingForcedPushIDs.remove(deviceID) != nil
                if !c6PreparingForQuit, !c6OfflineSimulationIDs.contains(deviceID),
                   let current = settings.devices.first(where: { $0.id == deviceID && $0.isEnabled && $0.type == .c6Screen }),
                   pending || (current.settings.aiMacScreen ?? AIMacScreenDeviceSettings()) != config {
                    Task { @MainActor [weak self] in
                        await self?.pushAIMacScreen(deviceID: deviceID, force: true)
                    }
                }
            }
        }
        do {
            var c6Capabilities: AIMacScreenCapabilities?
            if device.type == .c6Screen {
                let c6 = try await fetchAIMacScreenCapabilities(deviceID: deviceID, force: true, allowJPEGFallback: false)
                guard isCurrentColorScreenPresentation(deviceID, host: targetHost, config: config), !c6OfflineSimulationIDs.contains(deviceID) else { return }
                c6Capabilities = c6
                if c6.interactionProtocol == 2 {
                    if c6.menuActive { c6MenuPausedIDs.insert(deviceID); c6MenuHosts[deviceID] = targetHost }
                    else { c6MenuPausedIDs.remove(deviceID); c6MenuHosts[deviceID] = nil }
                }
                if c6.rotationURL != nil {
                    // Device-side edits are authoritative. Ordinary frame pushes
                    // must not undo a rotation saved with the BOOT settings menu.
                    config.rotate180 = c6.displayRotation == 180
                    if let angle = c6.displayRotation, var local = c6SyncedConfigurations[deviceID], local.rotation != angle {
                        local.rotation = angle; c6SyncedConfigurations[deviceID] = local
                    }
                    if aiMacScreenSettings(for: deviceID).rotate180 != config.rotate180 {
                        mutateAIMacScreenSettings(deviceID, pushImmediately: false, schedulePush: false) { $0.rotate180 = config.rotate180 }
                    }
                } else if config.rotate180 {
                    throw NSError(domain: "C6Display", code: 2, userInfo: [NSLocalizedDescriptionKey: "请更新 C6 内置固件以使用设备端 180° 旋转。"])
                }
                guard c6.acceptsSoftwareFrames else {
                    aiMacScreenStatuses[deviceID] = c6.menuActive ? "设备菜单已打开 · 退出后推送最新画面" : "本地数据优先 · 软件推送已让位"
                    return
                }
                // The native clock is a playlist member, not a Mac clock command.
                // Only the target is sent; clock_style/digit_style/timezone stay
                // authoritative on the firmware. Older firmware must be upgraded.
                if config.c6NativeCardID != nil || isNativeClock {
                    guard c6.nativeCardVersion >= 2 else {
                        throw NSError(domain: "C6Cards", code: 2, userInfo: [NSLocalizedDescriptionKey:
                            "请在设备管理中更新 C6 固件，以使用电脑与本地卡片混合轮换。"])
                    }
                    var token = c6Tokens[deviceID] ?? C6SecretStore.read(deviceID: deviceID)
                    let client = try C6StandaloneClient(host: targetHost)
                    if token.isEmpty {
                        token = try await client.connectLAN()
                        guard isCurrentColorScreenPresentation(deviceID, host: targetHost, config: config) else { return }
                        authorizeC6Sync(deviceID: deviceID, token: token)
                    }
                    if c6SyncedConfigurations[deviceID] == nil {
                        let local = try await client.read(token: token)
                        guard isCurrentColorScreenPresentation(deviceID, host: targetHost, config: config) else { return }
                        didUpdateC6DeviceConfiguration(local, deviceID: deviceID, host: targetHost)
                    }
                    guard let native = selectedC6NativeCard(deviceID: deviceID, config: config) else {
                        throw NSError(domain: "C6Cards", code: 3, userInfo: [NSLocalizedDescriptionKey:
                            "该本地卡片已移除或数据源已改变，请在卡片管理中重新选择。"])
                    }
                    // Migrate a previously selected software clock without changing
                    // its device-owned appearance. Other disabled cards stay explicit.
                    if let local = c6SyncedConfigurations[deviceID], !local.enabled || (native.kind == "clock" && !local.clock) {
                        for attempt in 0..<2 {
                            var latest = try await client.read(token: token)
                            guard isCurrentColorScreenPresentation(deviceID, host: targetHost, config: config) else { return }
                            latest.enabled = true
                            if native.kind == "clock" { latest.clock = true }
                            do {
                                let saved = try await client.save(latest, token: token, credentials: C6Credentials())
                                guard isCurrentColorScreenPresentation(deviceID, host: targetHost, config: config) else { return }
                                didUpdateC6DeviceConfiguration(saved, deviceID: deviceID, host: targetHost)
                                break
                            } catch C6StandaloneError.conflict where attempt == 0 { continue }
                        }
                    }
                    guard isCurrentColorScreenPresentation(deviceID, host: targetHost, config: config) else { return }
                    let status = try await client.selectNativeCard(token: token, headers: native.headers, explicitNative: true)
                    guard isCurrentColorScreenPresentation(deviceID, host: targetHost, config: config),
                          !c6OfflineSimulationIDs.contains(deviceID) else { return }
                    if status == 204 { aiMacScreenStatuses[deviceID] = "设备菜单已打开 · 退出后显示选中卡片"; return }
                    guard status == 200 else {
                        throw NSError(domain: "C6Cards", code: status, userInfo: [NSLocalizedDescriptionKey:
                            "本地卡片尚未启用或来源已改变，请检查设备本地设置。"])
                    }
                    c6NativeCardSelections[deviceID] = native.headers
                    aiMacScreenLastHashes[deviceID] = nil
                    aiMacScreenLastClockSyncAt[deviceID] = nil
                    let bytes = try? await client.previewFrame(token: token)
                    guard isCurrentColorScreenPresentation(deviceID, host: targetHost, config: config),
                          !c6OfflineSimulationIDs.contains(deviceID) else { return }
                    if let bytes, let image = AIMacScreenSupport.decodeRGB565(bytes) {
                        aiMacScreenPreviews[deviceID] = NSImage(cgImage: image, size: NSSize(width: 240, height: 240))
                    }
                    aiMacScreenStatuses[deviceID] = "\(native.title) · 设备本地实时运行 · 统一轮换"
                    return
                }
                let context = c6CardContextHeaders(config: config)
                if !isNativeClock, c6.prefersNativeCards, c6.nativeCardURL != nil,
                   ["weather", "ha", "printer"].contains(context["X-Lingxi-Card"] ?? "") {
                    let token = c6Tokens[deviceID] ?? C6SecretStore.read(deviceID: deviceID)
                    let client = try C6StandaloneClient(host: targetHost)
                    let status = try await client.selectNativeCard(token: token, headers: context)
                    guard isCurrentColorScreenTarget(deviceID, host: targetHost),
                          !c6PreparingForQuit, !c6OfflineSimulationIDs.contains(deviceID),
                          aiMacScreenSettings(for: deviceID).mode == config.mode,
                          aiMacScreenSettings(for: deviceID).cardMode == config.cardMode,
                          aiMacScreenSettings(for: deviceID).c6NativeCardID == nil,
                          c6CardContextHeaders(config: aiMacScreenSettings(for: deviceID)) == context else { return }
                    if status == 204 {
                        aiMacScreenStatuses[deviceID] = "设备菜单已打开 · 退出后显示最新卡片"
                        return
                    }
                    if status == 200 {
                        // Show the device's actual native frame, not a Mac-rendered approximation.
                        let bytes = try? await client.previewFrame(token: token)
                        guard isCurrentColorScreenTarget(deviceID, host: targetHost),
                              !c6PreparingForQuit, !c6OfflineSimulationIDs.contains(deviceID),
                              aiMacScreenSettings(for: deviceID).mode == config.mode,
                              aiMacScreenSettings(for: deviceID).cardMode == config.cardMode,
                              aiMacScreenSettings(for: deviceID).c6NativeCardID == nil,
                              c6CardContextHeaders(config: aiMacScreenSettings(for: deviceID)) == context else { return }
                        c6NativeCardSelections[deviceID] = context
                        if let bytes, let image = AIMacScreenSupport.decodeRGB565(bytes) {
                            aiMacScreenPreviews[deviceID] = NSImage(cgImage: image, size: NSSize(width: 240, height: 240))
                        }
                        aiMacScreenLastHashes[deviceID] = nil
                        aiMacScreenLastClockSyncAt[deviceID] = nil
                        aiMacScreenStatuses[deviceID] = "设备本地卡片 · 与电脑卡片混合轮转"
                        return
                    }
                    // 404: no identical enabled local counterpart; push the software card normally.
                }
                c6NativeCardSelections[deviceID] = nil
            }
            if isNativeClock {
                // 普通自动推送节拍不会再产生时钟图片。仅每 30 分钟低频校时，
                // 手动切入、自动轮播切入以及系统唤醒都会强制立即同步一次。
                var probedCapabilities: AIMacScreenCapabilities? = c6Capabilities
                if !force, let last = aiMacScreenLastClockSyncAt[deviceID],
                   Date().timeIntervalSince(last) < 30 * 60 {
                    // 本地记住“已校时”不代表重启后的设备仍在时钟模式。
                    // 读取固件 mode，只有设备真的还在 clock 才跳过本次命令。
                    let current: AIMacScreenCapabilities
                    if let c6Capabilities { current = c6Capabilities }
                    else {
                        current = try await fetchAIMacScreenCapabilities(
                            deviceID: deviceID, force: true, allowJPEGFallback: false)
                    }
                    if !AIMacScreenSupport.requiresPrimeFrame(
                        activeMode: current.activeMode,
                        frameRevision: current.frameRevision,
                        expectedMode: "clock"),
                       !current.isC6 || (current.nativeClockStyle ?? 0) == (config.c6ClockStyle ?? .flip).rawValue {
                        aiMacScreenStatuses[deviceID] = "设备端时钟正在实时运行"
                        return
                    }
                    probedCapabilities = current
                }
                // 用户可能刚用本应用从旧固件刷到 0.8.5；强制重读能力，不能沿用
                // 刷写前缓存的“无设备端时钟”结果。
                let capabilities: AIMacScreenCapabilities
                if let probedCapabilities {
                    capabilities = probedCapabilities
                } else {
                    capabilities = try await fetchAIMacScreenCapabilities(
                        deviceID: deviceID, force: true, allowJPEGFallback: false)
                }
                if capabilities.isC6, !capabilities.nativeClockStyles.contains((config.c6ClockStyle ?? .flip).rawValue) {
                    throw NSError(domain: "C6Clock", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "此固件尚不支持圆角粗数字时钟，请在设备管理中更新内置 C6 固件。"])
                }
                guard let url = capabilities.nativeClockURL,
                      let request = AIMacScreenSupport.nativeClockRequest(
                        url: url, now: Date(), timeZone: .current,
                        c6Style: capabilities.isC6 ? config.c6ClockStyle ?? .flip : nil) else {
                    throw AIMacScreenSupportError.nativeClockUnavailable
                }
                guard !c6PreparingForQuit else { return }
                let (_, response) = try await URLSession.shared.data(for: request)
                guard isCurrentColorScreenTarget(deviceID, host: targetHost), !c6OfflineSimulationIDs.contains(deviceID) else { return }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw AIMacScreenSupportError.nativeClockUnavailable
                }
                let syncedAt = Date()
                aiMacScreenLastClockSyncAt[deviceID] = syncedAt
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                aiMacScreenLastPushText[deviceID] = formatter.string(from: syncedAt)
                aiMacScreenStatuses[deviceID] = "设备端时钟已同步 · 本机实时走时"
                return
            }
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
            // 自动推送前轻量读取一次设备真实状态。设备重启会清空画面，但电脑端
            // 的上一帧 hash 仍存在；仅依靠 hash 会把应补发的首帧错误跳过。
            // 已确认是新固件后，探测失败必须作为离线处理，不能再静默伪装成旧版
            // JPEG 固件，否则仍会在下面命中旧 hash 并跳过首帧。
            let cachedCapabilities = aiMacScreenCapabilities[deviceID]
            let knownModernFirmware = cachedCapabilities?.activeMode != nil
                || cachedCapabilities?.supportsLosslessRGB565 == true
            // 自动节拍始终重试 /api/info：刚开机时 Web 服务常晚于图片端点就绪，
            // 首次失败产生的 JPEG 兼容结果不能永久阻止后续识别新固件重启状态。
            let shouldProbeDeviceState = !force
            let capabilities: AIMacScreenCapabilities
            if let c6Capabilities {
                capabilities = c6Capabilities
            } else if shouldProbeDeviceState {
                capabilities = try await fetchAIMacScreenCapabilities(
                    deviceID: deviceID, force: true,
                    allowJPEGFallback: !knownModernFirmware)
            } else {
                capabilities = try await fetchAIMacScreenCapabilities(deviceID: deviceID)
            }
            let usesNativeNowPlaying = config.mode == .card
                && config.cardMode == .nowPlaying
                && capabilities.supportsNativeNowPlaying
                && settings.cardRenderingMode == .classic
                && !config.hasColorCalibration
            let expectedDeviceMode = usesNativeNowPlaying ? "now_playing" : "external"
            let deviceNeedsPrime = AIMacScreenSupport.requiresPrimeFrame(
                activeMode: capabilities.activeMode,
                frameRevision: capabilities.frameRevision,
                expectedMode: expectedDeviceMode)
            let estimatedLatency = min(max(aiMacScreenUploadLatency[deviceID] ?? 0.18,
                                           0.05), 1.5)
            let presentationTime = Date().addingTimeInterval(estimatedLatency)
            let projectedPlayback = nowPlaying.anchored(at: presentationTime)
            let uploadStartedAt = Date()
            let image = try renderAIMacScreen(
                deviceID: deviceID, config: config, system: system,
                nowPlayingOverride: projectedPlayback, now: presentationTime)
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
            let encodedPreview: CGImage?
            if capabilities.supportsLosslessRGB565 {
                encodedPreview = AIMacScreenSupport.decodeRGB565(bytes)
            } else if let source = CGImageSourceCreateWithData(bytes as CFData, nil) {
                encodedPreview = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            } else {
                encodedPreview = nil
            }
            aiMacScreenPreviews[deviceID] = NSImage(
                cgImage: encodedPreview ?? image, size: NSSize(width: 240, height: 240))
            let frameHash = SHA256.hash(data: bytes).map {
                String(format: "%02x", $0)
            }.joined()
            if !force, !deviceNeedsPrime, aiMacScreenLastHashes[deviceID] == frameHash {
                if usesNativeNowPlaying {
                    try await syncAIMacNativeNowPlaying(
                        deviceID: deviceID, capabilities: capabilities, info: nowPlaying)
                    aiMacScreenStatuses[deviceID] = "设备端播放进度已校准"
                } else {
                    aiMacScreenStatuses[deviceID] = "画面未变化，已跳过推送"
                }
                return
            }
            guard !c6PreparingForQuit, isCurrentColorScreenPresentation(deviceID, host: targetHost, config: config), !c6OfflineSimulationIDs.contains(deviceID) else { return }
            if capabilities.supportsLosslessRGB565 {
                let status = try await imageApi.upload(
                    rgb565: bytes, endpoint: endpoint.absoluteString, timeout: 12,
                    headers: device.type == .c6Screen ? c6CardContextHeaders(config: config) : [:])
                // 204 means the physical menu/local priority won the race. It did
                // not accept a frame; never remember its hash as a success.
                if device.type == .c6Screen, status == 204 {
                    aiMacScreenStatuses[deviceID] = "设备正在本地显示 · 等待可接收画面"
                    return
                }
            } else {
                _ = try await imageApi.upload(
                    jpeg: bytes, endpoint: endpoint.absoluteString, timeout: 12)
            }
            guard isCurrentColorScreenPresentation(deviceID, host: targetHost, config: config), !c6OfflineSimulationIDs.contains(deviceID) else { return }
            aiMacScreenLastHashes[deviceID] = frameHash
            let measuredLatency = min(max(Date().timeIntervalSince(uploadStartedAt), 0), 3)
            if let previous = aiMacScreenUploadLatency[deviceID] {
                aiMacScreenUploadLatency[deviceID] = previous * 0.7 + measuredLatency * 0.3
            } else {
                aiMacScreenUploadLatency[deviceID] = measuredLatency
            }
            // 任意成功画面上传都会让固件退出原生时钟；下次轮换回时钟必须重新发指令。
            aiMacScreenLastClockSyncAt[deviceID] = nil
            if usesNativeNowPlaying {
                try await syncAIMacNativeNowPlaying(
                    deviceID: deviceID, capabilities: capabilities, info: nowPlaying)
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            aiMacScreenLastPushText[deviceID] = formatter.string(from: Date())
            aiMacScreenStatuses[deviceID] = usesNativeNowPlaying
                ? "推送成功 · \(modeText) · 设备端实时进度"
                : "推送成功 · \(modeText)"
        } catch {
            guard isCurrentColorScreenTarget(deviceID, host: targetHost), !c6OfflineSimulationIDs.contains(deviceID) else { return }
            // 失败可能正是设备重启的离线窗口。清掉电脑端基线，设备重新上线后
            // 下一次自动节拍必须实际上传，不能继续被旧 hash 短路。
            aiMacScreenLastHashes[deviceID] = nil
            aiMacScreenCapabilities[deviceID] = nil
            aiMacScreenStatuses[deviceID] = "推送失败：\(error.localizedDescription)"
        }
    }

    private func syncAIMacNativeNowPlaying(
        deviceID: UUID, capabilities: AIMacScreenCapabilities,
        info: NowPlayingInfo
    ) async throws {
        // 请求等待期间也可能切换外观或色彩校准；这两种情况下不能让固件用
        // 未校准的纯色进度区域覆盖最终成图。
        guard settings.cardRenderingMode == .classic,
              !aiMacScreenSettings(for: deviceID).hasColorCalibration else { return }
        guard let url = capabilities.nativeNowPlayingURL else { return }
        let basePalette = ScreenThemes.resolved(
            theme: settings.cardTheme,
            backgroundTone: settings.softwareIsDark ? .dark : .light,
            customBackgroundHex: nil,
            accentTone: settings.accentTone,
            customAccentHex: settings.customAccentHex,
            softwareIsDark: settings.softwareIsDark)
        let palette: ScreenPalette
        let accent: (CGFloat, CGFloat, CGFloat)
        if let artwork = cachedArtworkImage(for: info.artwork) {
            palette = ScreenRenderer.artworkPalette(
                of: artwork, themeAccent: basePalette.accent)
            accent = palette.accent
        } else {
            palette = basePalette
            accent = basePalette.accent
        }
        guard let request = AIMacScreenSupport.nativeNowPlayingRequest(
            url: url, info: info, background: palette.inset,
            track: palette.border, accent: accent, text: palette.secondaryText,
            now: Date()) else { throw AIMacScreenSupportError.invalidDevice }
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw AIMacScreenSupportError.invalidDevice
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        aiMacScreenLastPushText[deviceID] = formatter.string(from: Date())
    }

    private func maybeAutoPushAIMacScreens(now: Date) async {
        reconcileBambuMQTTClients()
        let dueDevices = enabledColorWiFiScreens.filter { device in
            let config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
            guard config.autoPush,
                  !c6MenuPausedIDs.contains(device.id),
                  !(aiMacScreensSystemSleeping && config.followSystemSleep),
                  !AIMacScreenSupport.normalizedHost(config.host).isEmpty,
                  !aiMacScreenBusyIDs.contains(device.id),
                  !aiMacColorCalibrationPendingIDs.contains(device.id),
                  aiMacCanvasPicturePreparationTasks[device.id] == nil else { return false }
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
            if device.type == .c6Screen,
               config.c6NativeCardID != nil || config.mode == .clock
                || (config.mode == .card && config.cardMode == .aiMacClock) { return false }
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
        var rotatedCanvasDeviceIDs = Set<UUID>()
        var rotatedCardModes: [UUID: DisplayMode] = [:]
        var rotatedNativeDeviceIDs = Set<UUID>()
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
                if cycleAIMacCanvasBoard(deviceID: device.id, direction: 1,
                                         automaticRotation: true) {
                    rotatedCanvasDeviceIDs.insert(device.id)
                }
                aiMacScreenLastBoardRotation[device.id] = now
            }
        }
        for device in dueDevices {
            let config = aiMacScreenSettings(for: device.id)
            // 画板与卡片各自只运行自己的轮播器；两者同时开启时不能在同一拍先切画板、
            // 又立刻被卡片轮播覆盖。
            guard config.mode == .card, config.cardRotationEnabled else { continue }
            if device.type == .c6Screen {
                let cards = c6CardRotationList(for: device.id)
                guard cards.count > 1 else { continue }
                let last = aiMacScreenLastCardRotation[device.id] ?? now
                if aiMacScreenLastCardRotation[device.id] == nil {
                    aiMacScreenLastCardRotation[device.id] = now; continue
                }
                guard now.timeIntervalSince(last) >= TimeInterval(config.cardRotationMinutes * 60) else { continue }
                aiMacScreenLastCardRotation[device.id] = now
                let currentID = selectedC6Card(for: device.id)?.id
                let current = cards.firstIndex { $0.id == currentID } ?? -1
                let next = (1...cards.count).compactMap { offset -> C6CardDescriptor? in
                    let candidate = cards[(current + offset + cards.count) % cards.count]
                    guard candidate.id != currentID else { return nil }
                    if let mode = candidate.displayMode,
                       candidate.nativeCard == nil || candidate.nativeCard?.kind == "printer" {
                        guard self.isAutomaticRotationModeEligible(mode, now: now) else { return nil }
                    }
                    return candidate
                }.first
                guard let next else { continue }
                mutateAIMacScreenSettings(device.id, schedulePush: false) { value in
                    value.mode = .card
                    value.c6NativeCardID = next.nativeCard?.id
                    value.cardMode = next.displayMode ?? .systemMonitor
                }
                if next.nativeCard != nil { rotatedNativeDeviceIDs.insert(device.id) }
                else if let mode = next.displayMode { rotatedCardModes[device.id] = mode }
                continue
            }
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
            aiMacScreenLastCardRotation[device.id] = now
            guard let next = SmartCardRotationPolicy.nextMode(
                after: config.cardMode, in: modes,
                isEligible: { self.isAutomaticRotationModeEligible($0, now: now) }
            ) else { continue }
            mutateAIMacScreenSettings(device.id, schedulePush: false) { value in
                value.mode = .card
                value.c6NativeCardID = nil
                value.cardMode = next
            }
            rotatedCardModes[device.id] = next
        }
        // 自动切到带图片的画板只安排一条 latest-only 任务；后续 tick 会看到
        // preparationTasks 并跳过，避免慢摄像头产生并发下载和空图闪帧。
        for deviceID in rotatedCanvasDeviceIDs {
            let current = aiMacScreenSettings(for: deviceID)
            if current.mode == .canvas {
                scheduleCurrentAIMacCanvasPicturesAndPush(deviceID: deviceID)
            }
        }
        // 自动切卡和手动切卡走同一份依赖刷新：打印机状态、HA 图片、额度与媒体
        // 都先更新再推送，避免轮播刚切入时显示上一轮缓存。
        for (deviceID, mode) in rotatedCardModes {
            await refreshAIMacCardDataAndPush(mode: mode, deviceID: deviceID)
        }
        for deviceID in rotatedNativeDeviceIDs {
            await pushAIMacScreen(deviceID: deviceID, force: true)
        }
        for device in dueDevices {
            if aiMacCanvasPicturePreparationTasks[device.id] != nil
                || rotatedCardModes[device.id] != nil { continue }
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

    /// Reuse the actual device-management connection, including saved credentials.
    /// Do not send credentials from a stale global preview mirror to C6.
    public var c6HomeAssistantConnection: (name: String, url: String, token: String)? {
        if let id = activeHADeviceID,
           let device = settings.devices.first(where: { $0.id == id && $0.type == .homeAssistant }) {
            return (device.name, device.settings.haServerURL ?? "", device.settings.haToken ?? "")
        }
        guard !settings.haServerURL.isEmpty else { return nil }
        return ("Home Assistant", settings.haServerURL, settings.haToken)
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
            if keyPath == \.bambuStatusEntityID {
                // 换绑实体等同换了一台状态来源；旧打印机的完成窗口不能串给新实体。
                self.printerRotationStates[id] = nil
            }
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
        return BambuLabCardSettings.from(dev)
    }

    public func bambuDataSourceBinding(_ id: UUID) -> Binding<BambuDataSource> {
        Binding(get: { self.settings.devices.first { $0.id == id }?.settings.bambuDataSource ?? .homeAssistant },
                set: { value in
            self.mutateDeviceSettings(id) { $0.bambuDataSource = value }
            self.reconcileBambuMQTTClients(); self.renderPreview()
        })
    }
    public func bambuMQTTFieldBinding(_ id: UUID, key: WritableKeyPath<BambuMQTTSettings, String>) -> Binding<String> {
        Binding(get: { (self.settings.devices.first { $0.id == id }?.settings.bambuMQTT ?? BambuMQTTSettings())[keyPath: key] },
                set: { value in
            self.mutateDeviceSettings(id) {
                var c = $0.bambuMQTT ?? BambuMQTTSettings()
                c[keyPath: key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                c.certificateSHA256 = ""; c.certificatePEM = nil; $0.bambuMQTT = c
            }
            self.disconnectBambuMQTT(id)
        })
    }
    public func bambuMQTTAccessCodeBinding(_ id: UUID) -> Binding<String> {
        if bambuMQTTAccessCodes[id] == nil { bambuMQTTAccessCodes[id] = BambuMQTTSecretStore.read(deviceID: id) }
        return Binding(get: { self.bambuMQTTAccessCodes[id] ?? "" }, set: { value in
            if !BambuMQTTSecretStore.save(value, deviceID: id) { self.bambuMQTTStatuses[id] = "无法保存访问码到钥匙串" }
            else { self.bambuMQTTAccessCodes[id] = value }
            self.disconnectBambuMQTT(id)
        })
    }
    public func connectBambuMQTT(_ id: UUID) {
        disconnectBambuMQTT(id); reconcileBambuMQTTClients()
    }
    public func trustBambuMQTTCertificate(_ id: UUID) {
        guard let fingerprint = bambuMQTTCertificates[id] else { return }
        mutateDeviceSettings(id) {
            var c = $0.bambuMQTT ?? BambuMQTTSettings(); c.certificateSHA256 = fingerprint
            c.certificatePEM = nil; $0.bambuMQTT = c
        }
        bambuMQTTCertificates[id] = nil; connectBambuMQTT(id)
    }
    private func disconnectBambuMQTT(_ id: UUID) {
        bambuMQTTClients.removeValue(forKey: id)?.stop(); bambuMQTTClientSettings[id] = nil
        bambuMQTTEntities[id] = nil; bambuMQTTCertificates[id] = nil
        applyHASnapshot(entities: haSnapshot.entities, errorText: haSnapshot.errorText, rebuildBambuCatalog: false)
    }
    private func reconcileBambuMQTTClients() {
        let devices = enabledDevices(for: .bambuLab).filter { $0.settings.bambuDataSource == .localMQTT }
        let active = Set(devices.map(\.id))
        for id in Array(bambuMQTTClients.keys) where !active.contains(id) { disconnectBambuMQTT(id) }
        for device in devices {
            let id = device.id
            var config = device.settings.bambuMQTT ?? BambuMQTTSettings()
            config.namespace = id.uuidString
            if bambuMQTTClientSettings[id] == config { continue }
            disconnectBambuMQTT(id)
            let client = BambuMQTTClient(settings: config, accessCode: BambuMQTTSecretStore.read(deviceID: id))
            bambuMQTTClients[id] = client; bambuMQTTClientSettings[id] = config
            client.onStatus = { [weak self, weak client] status in
                guard let self, let client, self.bambuMQTTClients[id] === client else { return }
                self.bambuMQTTStatuses[id] = status
                if status.contains("断开") {
                    self.bambuMQTTEntities[id] = [HAEntity(entityId: config.entityPrefix + "status",
                        friendlyName: "status", state: "unavailable", unitOfMeasurement: nil)]
                    self.applyHASnapshot(entities: self.haSnapshot.entities, errorText: self.haSnapshot.errorText, rebuildBambuCatalog: false)
                }
            }
            client.onCertificate = { [weak self, weak client] fingerprint in
                guard let self, let client, self.bambuMQTTClients[id] === client else { return }
                self.bambuMQTTCertificates[id] = fingerprint
            }
            client.onVerifiedCertificate = { [weak self, weak client] pem in
                guard let self, let client, self.bambuMQTTClients[id] === client,
                      self.settings.devices.first(where: { $0.id == id })?.settings.bambuMQTT?.certificatePEM != pem else { return }
                self.mutateDeviceSettings(id) { $0.bambuMQTT?.certificatePEM = pem }
            }
            client.onReport = { [weak self, weak client] report in
                guard let self, let client, self.bambuMQTTClients[id] === client else { return }
                let now = Date(); self.bambuMQTTEntities[id] = report.entities(config: config, now: now)
                self.applyHASnapshot(entities: self.haSnapshot.entities, errorText: self.haSnapshot.errorText, rebuildBambuCatalog: false, sampledAt: now)
                self.observeBambuPrinterRotationStates(entities: self.haSnapshot.entities, now: now, deviceIDs: [id])
                self.renderPreview()
            }
            client.start()
        }
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
        MenuBarNamingPolicy.printerCardTitle(for: mode, devices: settings.devices)
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
            let sampledAt = Date()
            applyHASnapshot(entities: entities, errorText: nil, sampledAt: sampledAt)
            observeBambuPrinterRotationStates(entities: entities, now: sampledAt)
            lastHARefresh = sampledAt
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
        for device in devices(for: .bambuLab) { printerRotationStates[device.id] = nil }
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
        aiMacButtonTask?.cancel()
        timer?.invalidate()
        lyricsTimer?.invalidate()
        linkedLyricsPushTasks.values.forEach { $0.cancel() }
        nowPlayingEventRefreshTask?.cancel()
        lyricsFetchTask?.cancel()
        aiMacCanvasPicturePreparationTasks.values.forEach { $0.cancel() }
        aiMacColorCalibrationCommitTasks.values.forEach { $0.cancel() }
        aiMacColorCalibrationPreviewTasks.values.forEach { $0.cancel() }
        aiMacColorCalibrationPushTasks.values.forEach { $0.cancel() }
        nowPlayingChangeObservers.forEach(NotificationCenter.default.removeObserver)
        playerChangeObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        rand0Session?.disconnect()
    }

    // MARK: - 时钟

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// 独立的歌词时间轴只做行号比较；歌词没有变化时不会渲染或访问网络。
    private func startLyricsTimer() {
        lyricsTimer = Timer.scheduledTimer(
            withTimeInterval: LyricsTimelinePolicy.checkInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.linkedLyricsKeyboardIDs.isEmpty else { return }
                self.scheduleLinkedLyricsPush(force: false, now: Date())
            }
        }
        RunLoop.main.add(lyricsTimer!, forMode: .common)
    }

    /// MediaRemote 变化时立即重新取样。通知不可用的系统会自动继续使用 6 秒兜底校准。
    private func startNowPlayingNotifications() {
        nowPlayingClient.registerForChangeNotifications()
        nowPlayingChangeObservers = NowPlayingClient.changeNotifications.map { name in
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleNowPlayingEventRefresh() }
            }
        }
        playerChangeObservers = NowPlayingClient.playerChangeNotifications.map { name in
            DistributedNotificationCenter.default().addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleNowPlayingEventRefresh() }
            }
        }
    }

    private var smartRotationNeedsLiveNowPlaying: Bool {
        let keyboardRotationNeedsMedia = activeDevice(for: .keyboard) != nil
            && settings.cardRotationEnabled && keyboardRotationList.contains(.nowPlaying)
        let aiMacRotationNeedsMedia = enabledColorWiFiScreens.contains { device in
            let config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
            return config.autoPush && config.cardRotationEnabled
                && (device.type == .c6Screen
                    ? c6CardRotationList(for: device.id).contains { $0.nativeCard == nil && $0.displayMode == .nowPlaying }
                    : aiMacCardRotationList(for: device.id).contains(.nowPlaying))
        }
        return keyboardRotationNeedsMedia || aiMacRotationNeedsMedia
    }

    private var needsNowPlayingEventRefresh: Bool {
        guard backgroundServicesEnabled else { return false }
        let keyboardNeedsMedia = activeDevice(for: .keyboard) != nil
            && (settings.displayMode == .nowPlaying
                || (settings.displayMode == .canvas && settings.canvasModuleList.contains(.nowPlaying)))
        return keyboardNeedsMedia || deviceCanvasNeedsLiveNowPlaying
            || smartRotationNeedsLiveNowPlaying
            || !linkedLyricsKeyboardIDs.isEmpty || NSApp.isActive
    }

    /// 初次事件轻量防抖；连续通知至多每秒取样一次。取样中的新事件保留一次
    /// 尾随刷新，无设备媒体需求且窗口不活跃时继续使用侧栏的低频刷新。
    private func scheduleNowPlayingEventRefresh() {
        nowPlayingEventRefreshThrottle.notify(hasDemand: needsNowPlayingEventRefresh)
        guard nowPlayingEventRefreshThrottle.hasPendingRefresh else { return }
        guard nowPlayingEventRefreshTask == nil else { return }
        let requestID = UUID()
        nowPlayingEventRefreshID = requestID
        nowPlayingEventRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.nowPlayingEventRefreshID == requestID {
                    self.nowPlayingEventRefreshTask = nil
                    self.nowPlayingEventRefreshID = nil
                }
            }
            while self.nowPlayingEventRefreshThrottle.hasPendingRefresh, !Task.isCancelled {
                let delay = self.nowPlayingEventRefreshThrottle.delay(at: Date())
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard self.nowPlayingEventRefreshThrottle.beginRefresh(
                    at: Date(), hasDemand: self.needsNowPlayingEventRefresh) else { continue }
                await self.refreshNowPlaying(now: Date(), forceRemote: true)
            }
        }
    }

    private func tick() async {
        let now = Date()
        maintainC6SoftwareLeases(now: now)
        scheduleC6ConfigurationSync(periodic: true)
        refreshWeatherIfDue(now: now)
        scheduleAWTRIXHomeAssistantSync(now: now)
        scheduleAWTRIXWeatherSync(now: now)
        // 设备端时钟每秒重绘，软件效果图也只在应用处于前台时跟随同一秒刷新；
        // 这里仅更新 240×240 本地预览，不触发图片上传或设备网络请求。
        refreshActiveAIMacClockPreview(now: now)
        // 跟随系统外观变化（外观模式为「跟随系统」时）
        updateSoftwareDarkState()
        // 设备画板含「正在播放」模块且开启自动推送时：按 6 秒节流刷新播放状态，
        // 实时捕获专辑封面变化（否则要等 30 秒的侧栏低频刷新）
        if deviceCanvasNeedsLiveNowPlaying || smartRotationNeedsLiveNowPlaying
            || !linkedLyricsKeyboardIDs.isEmpty {
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
        case .weather:
            await refreshPreviewOrPush(now: now)
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
        case .aiMacClock:
            // AI Mac 专属卡片不会成为灵犀 68 的活动模式；异常旧值仅保持预览。
            renderPreviewIfDue(now: now)
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
        // 240×240 小屏幕按设备检查轮播与普通内容；桌面时钟只做低频校时，
        // 秒级走时与画面重绘完全留在设备端。
        await maybeAutoPushAIMacScreens(now: now)
        // 歌词时间轴有独立调度器；这里仅补一次检查，不阻塞全局设备刷新。
        scheduleLinkedLyricsPush(force: false, now: now)
        // 侧栏常驻封面：非「正在播放」模式下也低频刷新一次播放状态
        if settings.displayMode != .nowPlaying {
            await refreshSidebarNowPlaying(now: now)
        }
        // 独立画板预览：按分钟刷新（内容每分钟轮换）
        refreshCanvasPreviews(now: now)
    }

    private var lastCanvasPreviewMinute: Int?

    private func refreshActiveAIMacClockPreview(now: Date) {
        guard NSApp.isActive,
              let id = activeColorScreenDeviceID,
              let device = settings.devices.first(where: {
                  $0.id == id && $0.type.isColorWiFiScreen && $0.isEnabled
              }) else { return }
        let config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
        // C6 clock previews are actual firmware frames, refreshed by the native
        // view. Never enter the legacy once-per-second desktop clock renderer.
        guard device.type != .c6Screen else { return }
        let isNativeClock = (config.mode == .card && config.cardMode == .aiMacClock)
            || config.mode == .clock
        guard isNativeClock else { return }
        do {
            let image = try renderAIMacScreen(deviceID: id, config: config,
                                              system: system, now: now)
            aiMacScreenPreviews[id] = NSImage(
                cgImage: image, size: NSSize(width: 240, height: 240))
        } catch {
            // 常规定时刷新会继续维护状态提示；效果图刷新失败不覆盖设备状态。
        }
    }

    private func refreshCanvasPreviews(now: Date) {
        let minute = Int(now.timeIntervalSince1970 / 60)
        guard lastCanvasPreviewMinute != minute else { return }
        lastCanvasPreviewMinute = minute
        refreshOracleCanvasPreview()
        refreshExcerptCanvasPreview()
        if let id = activeColorScreenDeviceID {
            let mode = aiMacScreenSettings(for: id).mode
            if mode == .canvas || mode == .card || mode == .clock || mode == .dashboard {
                refreshAIMacScreenPreview(deviceID: id)
            }
        }
    }

    /// 低频刷新正在播放状态（仅供侧栏常驻封面/歌曲信息，不推送、不影响当前卡片）
    private func refreshSidebarNowPlaying(now: Date) async {
        if let last = lastNowPlayingFetch, now.timeIntervalSince(last) < 30 { return }
        // 统一走完整媒体刷新链，确保低频兜底同样能识别换歌并触发智能轮播；
        // 不再维护一条会绕过换歌判定的侧栏专用赋值路径。
        await refreshNowPlaying(now: now, forceRemote: true)
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
            guard let id = activeColorScreenDeviceID else { return nil }
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
            guard let id = activeColorScreenDeviceID else { return nil }
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
            if let id = activeColorScreenDeviceID {
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
        guard let nextMode = SmartCardRotationPolicy.nextMode(
            after: settings.displayMode, in: modes,
            isEligible: { self.isAutomaticRotationModeEligible($0, now: now) }
        ) else { return false }
        cardRotationIndex = modes.firstIndex(of: nextMode) ?? 0
        setMode(nextMode)
        return true
    }

    /// 自动轮播只跳过能够明确判定为未工作的打印机；手动点选卡片不经过此判定。
    /// 未收录的新固件状态继续显示，错误/失败也保留，确保重要故障不会被静默隐藏。
    private func isAutomaticRotationModeEligible(_ mode: DisplayMode, now: Date) -> Bool {
        if mode == .nowPlaying {
            return SmartCardRotationPolicy.hasValidNowPlayingTitle(nowPlaying.title)
        }
        if mode.bambuSlotIndex != nil {
            guard let device = bambuDevice(for: mode) else { return false }
            let config = BambuLabCardSettings.from(device)
            let statusID = config.statusEntityID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statusID.isEmpty else { return false }
            guard let state = haSnapshot.entities.first(where: {
                $0.entityId == statusID
            })?.state else {
                // 已绑定但尚未取得首份 HA 快照时不武断隐藏；刷新后会按真实状态过滤。
                return true
            }
            let activity = SmartCardRotationPolicy.printerActivity(state: state)
            return SmartCardRotationPolicy.printerParticipatesInRotation(
                activity: activity,
                state: printerRotationStates[device.id] ?? .init(),
                at: now)
        }
        if mode.formlabsSlotIndex != nil {
            guard let device = formlabsDevice(for: mode) else { return false }
            let connection = device.settings.formlabsConnection ?? FormlabsConnectionSettings()
            guard !connection.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !connection.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !connection.printerSerial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            guard let snapshot = formlabsSnapshots[device.id] else {
                // 配置完整但第一次云端刷新尚未返回，暂时保留卡片以兼容新状态。
                return true
            }
            let states = [snapshot.print?.status, snapshot.device?.status]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let activity: SmartCardRotationPolicy.PrinterActivity =
                snapshot.device?.isConnected == false
                ? .inactive : SmartCardRotationPolicy.printerActivity(states: states)
            let persistedState = snapshot.completionObservedAt.map {
                SmartCardRotationPolicy.PrinterRotationState(
                    lastActivity: activity == .idle ? .idle : .completed,
                    completedAt: $0)
            }
            return SmartCardRotationPolicy.printerParticipatesInRotation(
                activity: activity,
                state: printerRotationStates[device.id] ?? persistedState ?? .init(),
                at: now)
        }
        return true
    }

    /// 只在 Home Assistant 请求成功后调用。失败路径会沿用旧实体快照，绝不能把那份
    /// 缓存当成新的状态跳变；last_changed 则允许重启后恢复尚未耗尽的完成窗口。
    private func observeBambuPrinterRotationStates(
        entities: [HAEntity],
        now: Date,
        deviceIDs: Set<UUID>? = nil
    ) {
        let byID = Dictionary(entities.map { ($0.entityId, $0) }, uniquingKeysWith: { _, newest in newest })
        for device in enabledDevices(for: .bambuLab)
            where deviceIDs?.contains(device.id) ?? true {
            let config = BambuLabCardSettings.from(device)
            let statusID = config.statusEntityID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statusID.isEmpty, let entity = byID[statusID] else { continue }
            let decision = SmartCardRotationPolicy.observePrinterActivity(
                SmartCardRotationPolicy.printerActivity(state: entity.state),
                previous: printerRotationStates[device.id] ?? .init(),
                at: now,
                completionEvidenceAt: entity.lastChanged)
            printerRotationStates[device.id] = decision.state
        }
    }

    /// Formlabs 的磁盘任务缓存只提供画面连续性，不能作为一次可信“之前仍在打印”。
    /// 只有本进程成功观察到的转换才能首次写 completionObservedAt；一旦写入，该绝对
    /// 时间随任务缓存持久化，重复 completed/idle 刷新只沿用而不会续期。
    private func applyingFormlabsPrinterRotationState(
        to snapshot: FormlabsSnapshot,
        deviceID: UUID,
        now: Date
    ) -> FormlabsSnapshot {
        var updated = snapshot
        let states = [snapshot.print?.status, snapshot.device?.status]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let activity: SmartCardRotationPolicy.PrinterActivity =
            snapshot.device?.isConnected == false
            ? .inactive : SmartCardRotationPolicy.printerActivity(states: states)
        let persisted = snapshot.completionObservedAt.map {
            SmartCardRotationPolicy.PrinterRotationState(
                lastActivity: activity == .idle ? .idle : .completed,
                completedAt: $0)
        }
        let decision = SmartCardRotationPolicy.observePrinterActivity(
            activity,
            previous: printerRotationStates[deviceID] ?? persisted ?? .init(),
            at: now)
        printerRotationStates[deviceID] = decision.state
        updated.completionObservedAt = decision.state.completedAt
        return updated
    }

    private func printerDeviceID(for mode: DisplayMode) -> UUID? {
        if let slot = mode.bambuSlotIndex {
            let printers = enabledDevices(for: .bambuLab)
            return printers.indices.contains(slot) ? printers[slot].id : nil
        }
        if let slot = mode.formlabsSlotIndex {
            let printers = enabledDevices(for: .formlabs)
            return printers.indices.contains(slot) ? printers[slot].id : nil
        }
        return nil
    }

    /// 返回点中的槽位只作类型提示；真正按稳定设备 UUID 查找当前槽位，避免播放期间
    /// 删除/禁用/重排打印机后把页面恢复到另一台机器。
    private func resolvedSmartRotationReturnMode(
        _ storedMode: DisplayMode,
        printerDeviceID: UUID?
    ) -> DisplayMode? {
        if storedMode.bambuSlotIndex != nil {
            guard let printerDeviceID,
                  let slot = enabledDevices(for: .bambuLab).firstIndex(where: {
                      $0.id == printerDeviceID
                  }) else { return nil }
            return DisplayMode(rawValue: DisplayMode.bambuLab.rawValue + slot)
        }
        if storedMode.formlabsSlotIndex != nil {
            guard let printerDeviceID,
                  let slot = enabledDevices(for: .formlabs).firstIndex(where: {
                      $0.id == printerDeviceID
                  }) else { return nil }
            return DisplayMode(rawValue: DisplayMode.formlabs.rawValue + slot)
        }
        return storedMode
    }

    /// “未在播放”是智能换歌抢占的释放事件。返回点逐设备持久化；仅当页面仍然
    /// 停在本次抢占呈现的 nowPlaying 时恢复，中途手动/普通轮播切走只清令牌。
    private func releaseNowPlayingSmartRotationTakeovers(now: Date) async {
        let activeKeyboardID = activeDeviceID(for: .keyboard)
        var activeKeyboardRestore: DisplayMode?
        var changedKeyboardState = false
        let previousSyncState = settings.deviceSyncInFlight
        settings.deviceSyncInFlight = true
        for index in settings.devices.indices where settings.devices[index].type == .keyboard {
            let deviceID = settings.devices[index].id
            guard let stored = settings.devices[index].settings.smartRotationReturnDisplayMode else {
                continue
            }
            let current = deviceID == activeKeyboardID
                ? settings.displayMode
                : (settings.devices[index].settings.displayMode ?? .codex)
            let takeover = SmartCardRotationPolicy.AutomaticTakeover(
                previousTarget: stored, presentedTarget: DisplayMode.nowPlaying)
            let requested = SmartCardRotationPolicy.releaseAutomaticTakeover(
                takeover, current: current)
            let resolved = requested.flatMap {
                resolvedSmartRotationReturnMode(
                    $0,
                    printerDeviceID: settings.devices[index].settings
                        .smartRotationReturnPrinterDeviceID)
            }
            settings.devices[index].settings.smartRotationReturnDisplayMode = nil
            settings.devices[index].settings.smartRotationReturnPrinterDeviceID = nil
            if let resolved {
                settings.devices[index].settings.displayMode = resolved
                if deviceID == activeKeyboardID {
                    settings.displayMode = resolved
                    activeKeyboardRestore = resolved
                }
            }
            changedKeyboardState = true
        }
        settings.deviceSyncInFlight = previousSyncState
        if changedKeyboardState { persistSettings() }

        var aiMacRestores: [(deviceID: UUID, target: AIMacSmartRotationTarget)] = []
        let aiMacIDs = settings.devices.compactMap { device in
            device.type.isColorWiFiScreen ? device.id : nil
        }
        for deviceID in aiMacIDs {
            guard !c6MenuPausedIDs.contains(deviceID) else { continue }
            let config = aiMacScreenSettings(for: deviceID)
            guard let returnContentMode = config.smartRotationReturnContentMode else { continue }
            let storedCardMode = config.smartRotationReturnCardModeRawValue
                .flatMap(DisplayMode.init(rawValue:)) ?? config.cardMode
            let previousCardMode: DisplayMode?
            if let nativeID = config.smartRotationReturnC6NativeCardID {
                previousCardMode = allC6Cards(for: deviceID).contains { $0.nativeCard?.id == nativeID } ? storedCardMode : nil
            } else if returnContentMode == .card {
                previousCardMode = resolvedSmartRotationReturnMode(
                    storedCardMode,
                    printerDeviceID: config.smartRotationReturnPrinterDeviceID)
            } else {
                previousCardMode = storedCardMode
            }
            let currentTarget = AIMacSmartRotationTarget(config)
            let presented = AIMacSmartRotationTarget(
                AIMacScreenDeviceSettings(mode: .card,
                                          cardModeRawValue: DisplayMode.nowPlaying.rawValue))
            let requested = previousCardMode.flatMap { cardMode in
                SmartCardRotationPolicy.releaseAutomaticTakeover(
                    .init(previousTarget: AIMacSmartRotationTarget(
                        AIMacScreenDeviceSettings(mode: returnContentMode,
                                                  cardModeRawValue: cardMode.rawValue,
                                                  c6NativeCardID: config.smartRotationReturnC6NativeCardID)),
                          presentedTarget: presented),
                    current: currentTarget)
            }
            mutateAIMacScreenSettings(deviceID, schedulePush: false) { value in
                value.smartRotationReturnContentMode = nil
                value.smartRotationReturnCardModeRawValue = nil
                value.smartRotationReturnPrinterDeviceID = nil
                value.smartRotationReturnC6NativeCardID = nil
                if let requested {
                    value.mode = requested.contentMode
                    value.cardMode = requested.cardMode
                    value.c6NativeCardID = requested.c6NativeCardID
                }
            }
            guard let requested,
                  let device = settings.devices.first(where: {
                      $0.id == deviceID && $0.type.isColorWiFiScreen && $0.isEnabled
                  }) else { continue }
            let restored = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
            guard restored.autoPush,
                  !(aiMacScreensSystemSleeping && restored.followSystemSleep) else { continue }
            aiMacScreenLastCardRotation[deviceID] = now
            aiMacRestores.append((deviceID, requested))
        }

        // 至此所有设备的旧令牌都已同步消费；下面才允许挂起，避免 await 期间的新歌
        // 建立新令牌后又被这次旧“未在播放”事件清掉。
        if let activeKeyboardRestore {
            lastCardRotation = now
            cardRotationIndex = keyboardRotationList.firstIndex(of: activeKeyboardRestore) ?? 0
            await activateMode()
        }
        for restore in aiMacRestores {
            let current = aiMacScreenSettings(for: restore.deviceID)
            guard AIMacSmartRotationTarget(current) == restore.target else { continue }
            if restore.target.contentMode == .card && restore.target.c6NativeCardID == nil {
                await refreshAIMacCardDataAndPush(
                    mode: restore.target.cardMode, deviceID: restore.deviceID)
            } else {
                await pushAIMacScreen(deviceID: restore.deviceID, force: true)
            }
        }
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
    private func refreshNowPlaying(now: Date, forceRemote: Bool = false) async {
        // 播放中保持 6 秒校准；无媒体/暂停时退避到 30 秒，避免空闲状态频繁启动
        // Swift MediaRemote 探测子进程而拖慢整个系统。检测到播放后自动恢复高频校准。
        let highFrequencyDemand = settings.displayMode == .nowPlaying
            || deviceCanvasNeedsLiveNowPlaying
            || smartRotationNeedsLiveNowPlaying
            || !linkedLyricsKeyboardIDs.isEmpty
        let fetchInterval: TimeInterval = nowPlaying.isPlaying || highFrequencyDemand ? 6 : 30
        if !forceRemote, let last = lastNowPlayingFetch,
           now.timeIntervalSince(last) < fetchInterval {
            // 使用同一锚点函数推进，歌词判断不再叠加第二套本地计时。
            if nowPlaying.isPlaying { nowPlaying = nowPlaying.anchored(at: now) }
            await refreshLyricsIfNeeded()
            return
        }
        lastNowPlayingFetch = now
        let previousInfo = nowPlaying
        var timelineChanged = false
        var receivedAuthoritativeState = false
        do {
            let fetched = try await nowPlayingClient.fetch()
            receivedAuthoritativeState = true
            let merged = fetched.reconciledWithProgressed(
                current: nowPlaying, previousRemote: lastRemoteNowPlaying)
            lastRemoteNowPlaying = fetched
            nowPlaying = merged.info
            timelineChanged = merged.didSeek
                || previousInfo.isPlaying != nowPlaying.isPlaying
                || nowPlayingSongKey(previousInfo) != nowPlayingSongKey(nowPlaying)
        } catch NowPlayingError.notPlaying {
            receivedAuthoritativeState = true
            nowPlaying = .placeholder
            lastRemoteNowPlaying = nil
            timelineChanged = previousInfo.title != nowPlaying.title
        } catch is CancellationError {
            return
        } catch {
            if nowPlaying.title.isEmpty || nowPlaying.title == "未在播放" {
                nowPlaying = .placeholder
            }
        }
        let previousSongKey = nowPlayingSongKey(previousInfo)
        let observedSongKey = nowPlayingSongKey(nowPlaying)
        var shouldPrioritizeSong = false
        if let observedSongKey {
            if observedSongKey != previousSongKey {
                if nowPlaying.isPlaying, observedSongKey != lastSmartRotationSongKey {
                    shouldPrioritizeSong = true
                    lastSmartRotationSongKey = observedSongKey
                    pendingSmartRotationSongKey = nil
                } else if !nowPlaying.isPlaying {
                    // 某些播放器换歌时先发一帧 paused，再发 playing；这不是旧歌的暂停/继续。
                    pendingSmartRotationSongKey = observedSongKey
                }
            } else if nowPlaying.isPlaying,
                      pendingSmartRotationSongKey == observedSongKey,
                      lastSmartRotationSongKey != observedSongKey {
                shouldPrioritizeSong = true
                lastSmartRotationSongKey = observedSongKey
                pendingSmartRotationSongKey = nil
            }
        } else if receivedAuthoritativeState {
            // “未在播放”是明确的会话边界；之后重新开始同一首歌也应视为新的播放内容。
            lastSmartRotationSongKey = nil
            pendingSmartRotationSongKey = nil
            await releaseNowPlayingSmartRotationTakeovers(now: now)
        }
        updateSidebarArtwork()
        // 这里仅安排后台查询，并同步清掉上一首歌的歌词；不会等待歌词网络。
        await refreshLyricsIfNeeded()
        // 媒体本身已经读取完成：标题/封面不应等外部歌词服务响应才出现在预览中。
        if previousInfo.title != nowPlaying.title || previousInfo.artist != nowPlaying.artist
            || previousInfo.artwork != nowPlaying.artwork || timelineChanged {
            renderPreview()
        }
        if timelineChanged {
            resetLinkedLyricsScheduling()
            scheduleLinkedLyricsPush(force: true, now: Date())
            // 小屏幕的播放状态锚点也要在暂停、继续和 seek 时立即刷新，不能等
            // 用户设定的下一次完整图片推送。
            for device in enabledColorWiFiScreens {
                let config = aiMacScreenSettings(for: device.id)
                if config.autoPush, config.mode == .card,
                   config.cardMode == .nowPlaying,
                   config.lyricsKeyboardDeviceID != nil {
                    await pushAIMacScreen(deviceID: device.id, force: false)
                }
            }
        }
        if shouldPrioritizeSong {
            await prioritizeNowPlayingForSmartRotation(now: now)
        }
    }

    private func nowPlayingSongKey(_ info: NowPlayingInfo) -> String? {
        let title = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SmartCardRotationPolicy.hasValidNowPlayingTitle(title) else { return nil }
        return "\(title.lowercased())|\(info.artist.lowercased())|\(Int(info.duration.rounded()))"
    }

    /// 换歌时把“正在播放”提升为本轮首卡。只有用户已将该卡加入自动轮播池才生效；
    /// 已经在正在播放页时也重置驻留周期，让新歌获得完整展示时间。
    private func prioritizeNowPlayingForSmartRotation(now: Date) async {
        var activateKeyboard = false
        var pushCurrentKeyboard = false
        let keyboardModes = keyboardRotationList
        let keyboardShouldSwitch = SmartCardRotationPolicy.shouldPrioritizeNowPlaying(
            songChanged: true, isPlaying: nowPlaying.isPlaying,
            rotationEnabled: settings.cardRotationEnabled,
            rotationModes: keyboardModes, currentMode: settings.displayMode)
        let keyboardParticipates = keyboardShouldSwitch
            || (settings.cardRotationEnabled && keyboardModes.contains(.nowPlaying)
                && settings.displayMode == .nowPlaying)
        if keyboardParticipates, let keyboardID = activeDeviceID(for: .keyboard) {
            lastCardRotation = now
            cardRotationIndex = keyboardModes.firstIndex(of: .nowPlaying) ?? 0
            if settings.displayMode != .nowPlaying {
                if let index = settings.devices.firstIndex(where: { $0.id == keyboardID }),
                   let takeover = SmartCardRotationPolicy.beginAutomaticTakeover(
                       from: settings.displayMode, presenting: DisplayMode.nowPlaying) {
                    settings.devices[index].settings.smartRotationReturnDisplayMode =
                        takeover.previousTarget
                    settings.devices[index].settings.smartRotationReturnPrinterDeviceID =
                        printerDeviceID(for: takeover.previousTarget)
                }
                settings.displayMode = .nowPlaying
                persistSettings()
                activateKeyboard = true
            } else {
                // 已停留在正在播放页也要立刻送出新歌，而不是继续受普通动态推送间隔限制。
                pushCurrentKeyboard = true
            }
        }

        var aiMacActions: [(deviceID: UUID, needsRefresh: Bool)] = []
        for device in enabledColorWiFiScreens {
            guard !c6MenuPausedIDs.contains(device.id) else { continue }
            let config = aiMacScreenSettings(for: device.id)
            let currentCard = config.mode == .card ? config.cardMode : .canvas
            let modes = device.type == .c6Screen
                ? c6CardRotationList(for: device.id).filter { $0.nativeCard == nil }.compactMap(\.displayMode)
                : aiMacCardRotationList(for: device.id)
            let shouldSwitch = SmartCardRotationPolicy.shouldPrioritizeNowPlaying(
                songChanged: true, isPlaying: nowPlaying.isPlaying,
                rotationEnabled: config.cardRotationEnabled,
                rotationModes: modes, currentMode: currentCard)
            let alreadyShowing = config.cardRotationEnabled && modes.contains(.nowPlaying)
                && config.mode == .card && config.cardMode == .nowPlaying
            guard config.autoPush,
                  !(aiMacScreensSystemSleeping && config.followSystemSleep),
                  shouldSwitch || alreadyShowing
            else { continue }
            aiMacScreenLastCardRotation[device.id] = now
            guard config.mode != .card || config.cardMode != .nowPlaying else {
                aiMacActions.append((device.id, false))
                continue
            }
            let previousTarget = AIMacSmartRotationTarget(config)
            mutateAIMacScreenSettings(device.id, schedulePush: false) { value in
                value.smartRotationReturnContentMode = previousTarget.contentMode
                value.smartRotationReturnCardModeRawValue = previousTarget.cardMode.rawValue
                value.smartRotationReturnC6NativeCardID = previousTarget.c6NativeCardID
                value.smartRotationReturnPrinterDeviceID = previousTarget.contentMode == .card
                    ? self.printerDeviceID(for: previousTarget.cardMode) : nil
                value.mode = .card
                value.c6NativeCardID = nil
                value.cardMode = .nowPlaying
            }
            aiMacActions.append((device.id, true))
        }

        // 所有目标的返回令牌与 nowPlaying 页面先在主 actor 上原子建立；之后才允许
        // 网络/上传 await，避免期间到达的“未在播放”遗漏尚未抢占的某台小屏。
        if activateKeyboard {
            await activateMode()
        } else if pushCurrentKeyboard {
            await pushWhenAvailable(force: false, silentIfUnchanged: true)
        }
        for action in aiMacActions {
            guard isCurrentAIMacCard(deviceID: action.deviceID, mode: .nowPlaying) else {
                continue
            }
            if action.needsRefresh {
                await refreshAIMacCardDataAndPush(mode: .nowPlaying, deviceID: action.deviceID)
            } else {
                await pushAIMacScreen(deviceID: action.deviceID, force: false)
            }
        }
    }

    /// 关联存在时每首歌只查询一次 LRCLIB；失败也缓存到换歌为止，避免网络重试形成负担。
    private func refreshLyricsIfNeeded(force: Bool = false) async {
        guard !linkedLyricsKeyboardIDs.isEmpty,
              let songKey = nowPlayingSongKey(nowPlaying) else {
            lyricsFetchTask?.cancel()
            lyricsFetchTask = nil
            lyricsRequestedSongKey = nil
            nowPlayingLyrics = nil
            return
        }
        guard force || lyricsRequestedSongKey != songKey else { return }
        lyricsFetchTask?.cancel()
        lyricsRequestedSongKey = songKey
        // 换歌查询期间不能继续按新歌曲进度渲染上一首歌的歌词。
        nowPlayingLyrics = nil
        resetLinkedLyricsScheduling()
        let requestedInfo = nowPlaying
        // 查询期间先发送当前曲目的封面页；歌词请求独立运行，不阻塞 tick、
        // 歌曲识别或用户 seek 的即时校准。换歌/解除关联会取消旧请求。
        scheduleLinkedLyricsPush(force: true, now: Date())
        lyricsFetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let fetched: LyricsTrack?
            do {
                fetched = try await self.lyricsClient.fetch(for: requestedInfo)
            } catch {
                fetched = nil
            }
            guard !Task.isCancelled,
                  self.lyricsRequestedSongKey == songKey,
                  self.nowPlayingSongKey(self.nowPlaying) == songKey else { return }
            self.nowPlayingLyrics = fetched
            self.lyricsFetchTask = nil
            self.linkedLyricsLastLineKeys = [:]
            self.renderPreview()
            self.scheduleLinkedLyricsPush(force: true, now: Date())
        }
    }

    private func resetLinkedLyricsScheduling(clearDisplayedLines: Bool = true,
                                              preserveInFlightTasks: Bool = false) {
        linkedLyricsPushTasks.values.forEach { $0.cancel() }
        // 切换渲染方式时，新任务仍需等待旧上传真正退出，不能仅丢掉取消句柄后
        // 把仍然 busy 的设备当成已经推送成功。停止/解除关联继续使用完整清理。
        if !preserveInFlightTasks { linkedLyricsPushTasks = [:] }
        linkedLyricsScheduledLineKeys = [:]
        linkedLyricsRetryLineKeys = [:]
        linkedLyricsRetryNotBefore = [:]
        if clearDisplayedLines { linkedLyricsLastLineKeys = [:] }
    }

    private func linkedLyricsPayload(for keyboardID: UUID, force: Bool, now: Date) ->
        (window: LyricsDisplayWindow?, lyricsOnly: Bool, lineKey: String)? {
        let lineKey: String
        let renderingKey = settings.cardRenderingMode.rawValue
        if let lyrics = nowPlayingLyrics {
            let lead = LyricsTimelinePolicy.presentationLead(
                observedLatency: linkedLyricsUploadLatency[keyboardID])
            let userDelay = TimeInterval(settings.lyricsTimingOffsetMilliseconds) / 1_000
            let displayElapsed = LyricsTimelinePolicy.displayElapsed(
                for: nowPlaying, at: now, presentationLead: lead,
                userDelay: userDelay)
            let window = lyrics.displayWindow(at: displayElapsed)
            guard !window.lines.isEmpty else { return nil }
            let lineIndex = lyrics.currentLineIndex(at: displayElapsed) ?? -1
            lineKey = "\(renderingKey)|\(nowPlayingSongKey(nowPlaying) ?? "")|\(lineIndex)|\(window.lines.joined(separator: "|"))"
            return (window, true, lineKey)
        } else if let songKey = nowPlayingSongKey(nowPlaying) {
            // 查询中或服务没有返回歌词时，保持灵犀 68 的标准正在播放页：
            // 显示专辑封面、歌曲信息与进度，而不是“暂未找到歌词”的空白文字页。
            // 五秒更新一次进度，同时把首次回退帧的耗时用于后续歌词换帧校准。
            let elapsedBucket = Int(nowPlaying.effectiveElapsed(at: now) / 5)
            lineKey = "\(renderingKey)|cover|\(songKey)|\(nowPlaying.artwork?.count ?? 0)|\(elapsedBucket)"
            return (nil, false, lineKey)
        } else {
            // 尚无播放内容时保留原有占位页，平时 tick 不重复发送。
            guard force else { return nil }
            let message = nowPlayingSongKey(nowPlaying) == nil ? "暂无播放内容" : "暂未找到歌词"
            let window = LyricsDisplayWindow(lines: [message], currentIndex: 0)
            lineKey = "\(renderingKey)|placeholder|\(message)"
            return (window, true, lineKey)
        }
    }

    /// 高频歌词推送使用 latest-only 队列：新歌词出现时取消尚在等待或上传的旧帧，
    /// 并等待旧任务真正退出后再发送最新帧，避免键盘唤醒后补发过期画面。
    private func scheduleLinkedLyricsPush(force: Bool, now: Date = Date()) {
        let keyboardIDs = linkedLyricsKeyboardIDs
        guard !keyboardIDs.isEmpty else {
            resetLinkedLyricsScheduling(clearDisplayedLines: false)
            return
        }
        // 删除刚解除关联设备留下的任务；其他设备继续使用自己的队列与延迟模型。
        for keyboardID in Array(linkedLyricsPushTasks.keys)
            where !keyboardIDs.contains(keyboardID) {
            linkedLyricsPushTasks[keyboardID]?.cancel()
            linkedLyricsPushTasks[keyboardID] = nil
            linkedLyricsScheduledLineKeys[keyboardID] = nil
        }
        for keyboardID in keyboardIDs {
            guard let payload = linkedLyricsPayload(for: keyboardID, force: force, now: now) else {
                continue
            }
            if !force, linkedLyricsRetryLineKeys[keyboardID] == payload.lineKey,
               let retryAt = linkedLyricsRetryNotBefore[keyboardID], now < retryAt { continue }
            if !force, linkedLyricsScheduledLineKeys[keyboardID] == payload.lineKey { continue }
            if linkedLyricsRetryLineKeys[keyboardID] != payload.lineKey {
                linkedLyricsRetryLineKeys[keyboardID] = nil
                linkedLyricsRetryNotBefore[keyboardID] = nil
            }
            linkedLyricsScheduledLineKeys[keyboardID] = payload.lineKey
            let previousTask = linkedLyricsPushTasks[keyboardID]
            previousTask?.cancel()
            linkedLyricsPushTasks[keyboardID] = Task { @MainActor [weak self] in
                _ = await previousTask?.result
                guard let self, !Task.isCancelled,
                      self.linkedLyricsScheduledLineKeys[keyboardID] == payload.lineKey else {
                    return
                }
                let succeeded = await self.performLinkedLyricsPush(
                    keyboardID: keyboardID, window: payload.window,
                    lyricsOnly: payload.lyricsOnly, lineKey: payload.lineKey)
                guard !Task.isCancelled,
                      self.linkedLyricsScheduledLineKeys[keyboardID] == payload.lineKey else {
                    return
                }
                if succeeded {
                    self.linkedLyricsRetryLineKeys[keyboardID] = nil
                    self.linkedLyricsRetryNotBefore[keyboardID] = nil
                } else {
                    // 休眠/离线时不积压历史帧，只让仍然有效的当前歌词稍后重试。
                    self.linkedLyricsScheduledLineKeys[keyboardID] = nil
                    self.linkedLyricsRetryLineKeys[keyboardID] = payload.lineKey
                    self.linkedLyricsRetryNotBefore[keyboardID] = Date().addingTimeInterval(1)
                }
            }
        }
    }

    /// 单台键盘只处理自己的最新帧。多台设备的 HTTP 上传可以并行，慢设备不会再
    /// 推迟快设备；非活动键盘仍使用自己的端点和显示快照。
    private func performLinkedLyricsPush(keyboardID: UUID,
                                         window: LyricsDisplayWindow?,
                                         lyricsOnly: Bool,
                                         lineKey: String) async -> Bool {
        guard linkedLyricsLastLineKeys[keyboardID] != lineKey,
              linkedLyricsScheduledLineKeys[keyboardID] == lineKey,
              !Task.isCancelled,
              let device = enabledDevices(for: .keyboard).first(where: { $0.id == keyboardID }) else {
            return true
        }
        // 暂时忙碌属于待重试，不能锁定当前行的“已成功”状态。
        guard !linkedLyricsBusyIDs.contains(keyboardID) else { return false }
        let mode = keyboardID == activeDeviceID(for: .keyboard)
            ? settings.displayMode : (device.settings.displayMode ?? .codex)
        guard mode == .nowPlaying else { return true }
        linkedLyricsBusyIDs.insert(keyboardID)
        defer { linkedLyricsBusyIDs.remove(keyboardID) }

        var ownsGlobalPushSlot = false
        do {
            // 每次让出执行权后重新判断活动设备；切到另一把键盘时不能继续借用
            // 新键盘的全局设置，也不能抢占它的普通推送槽位。
            while activeDeviceID(for: .keyboard) == keyboardID && busy {
                try await Task.sleep(nanoseconds: 25_000_000)
                guard linkedLyricsScheduledLineKeys[keyboardID] == lineKey,
                      linkedLyricsKeyboardIDs.contains(keyboardID) else {
                    throw CancellationError()
                }
            }
            guard !Task.isCancelled,
                  linkedLyricsScheduledLineKeys[keyboardID] == lineKey,
                  linkedLyricsKeyboardIDs.contains(keyboardID),
                  let target = NowPlayingKeyboardRenderTarget(deviceID: keyboardID, source: settings) else {
                return false
            }
            if target.ownsActivePreview(in: settings) {
                busy = true
                ownsGlobalPushSlot = true
            }
            defer { if ownsGlobalPushSlot { busy = false } }
            let renderSettings = target.renderSettings
            let uploadStartedAt = Date()
            let artwork = cachedArtworkImage(for: nowPlaying.artwork)
            let result = try LiquidGlassCardRenderer.renderKeyboard(settings: renderSettings) {
                try ScreenRenderer.renderNowPlaying(
                    self.nowPlaying, settings: renderSettings, artworkImage: artwork,
                    lyrics: window, lyricsOnly: lyricsOnly)
            }
            guard !Task.isCancelled,
                  linkedLyricsScheduledLineKeys[keyboardID] == lineKey else { return true }
            _ = try await imageApi.upload(result.data, contentType: "image/jpeg",
                                          endpoint: target.endpoint)
            guard !Task.isCancelled,
                  linkedLyricsScheduledLineKeys[keyboardID] == lineKey else { return true }
            guard target.isValid(in: settings), linkedLyricsKeyboardIDs.contains(keyboardID) else { return false }
            let measuredLatency = min(max(Date().timeIntervalSince(uploadStartedAt), 0), 3)
            if let previous = linkedLyricsUploadLatency[keyboardID] {
                linkedLyricsUploadLatency[keyboardID] = previous * 0.65 + measuredLatency * 0.35
            } else {
                linkedLyricsUploadLatency[keyboardID] = measuredLatency
            }
            linkedLyricsLastLineKeys[keyboardID] = lineKey
            if target.ownsActivePreview(in: settings) {
                // 歌词使用独立的高频推送队列；成功后把实际上传的 JPEG 同步到预览，
                // 避免软件仍显示另外一次普通渲染生成的旧时间窗或封面页。
                updateKeyboardPreview(from: result)
                lastUploadedHash = Self.sha256(result.data)
                lastPushAttempt = Date()
                lastPush = "最后推送：\(Self.formatNow())"
            }
            return true
        } catch {
            return Task.isCancelled
        }
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
            for device in enabledColorWiFiScreens {
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
        case .weather:
            if settings.weatherSnapshot == nil { await refreshWeather() }
            await push(force: true)
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
        case .aiMacClock:
            // 仅供 AI Mac 卡片目录使用，不进入灵犀 68 的模式激活路径。
            break
        }
    }

    // MARK: - 数据刷新（Codex 用量 / 千问办公额度：统一调取，一次拉两个源供各功能共享）

    private var allAIMacCanvasModules: [CanvasModule] {
        enabledColorWiFiScreens.flatMap { device in
            (device.settings.aiMacScreen ?? AIMacScreenDeviceSettings())
                .canvasBoards.flatMap(\.moduleList)
        }
    }

    private var activeAIMacCardModes: [DisplayMode] {
        enabledColorWiFiScreens.compactMap { device in
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
            || enabledColorWiFiScreens.contains { device in
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
            for device in self.enabledColorWiFiScreens {
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
        // 自动轮播池里的打印机即使当前没显示，也要保持状态新鲜；否则一张曾经空闲而
        // 被跳过的卡片永远没有机会发现新任务开始。
        let currentCardSlots = activeAIMacCardModes.compactMap(\.formlabsSlotIndex)
        let keyboardRotationSlots = settings.cardRotationEnabled
            ? keyboardRotationList.compactMap(\.formlabsSlotIndex) : []
        let aiMacRotationSlots = enabledColorWiFiScreens.flatMap { device -> [Int] in
            let config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
            guard config.autoPush, config.cardRotationEnabled else { return [] }
            return aiMacCardRotationList(for: device.id).compactMap(\.formlabsSlotIndex)
        }
        let slots = Set(modules.compactMap(\.formlabsSlotIndex)
                        + currentCardSlots + keyboardRotationSlots + aiMacRotationSlots).sorted()
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
        for device in enabledColorWiFiScreens {
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
        var updated = await formlabsClient.refresh(settings: config, previous: previous)
        if updated.cloudError == nil {
            if FormlabsTaskCachePolicy.isDefinitelyDifferentTask(
                previous.print, updated.print) {
                printerRotationStates[deviceID] = nil
            }
            updated = applyingFormlabsPrinterRotationState(
                to: updated, deviceID: deviceID, now: updated.sampledAt ?? Date())
        }
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

    private func bambuDevice(for mode: DisplayMode) -> ManagedDevice? {
        guard let slot = mode.bambuSlotIndex else { return nil }
        let printers = enabledDevices(for: .bambuLab)
        return printers.indices.contains(slot) ? printers[slot] : nil
    }

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
        for device in devices(for: .bambuLab) { printerRotationStates[device.id] = nil }
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
            let sampledAt = Date()
            // 一份全局快照：HA 卡片、画板模块、异常监控、打印机映射共用同一数据源
            applyHASnapshot(entities: entities, errorText: nil, sampledAt: sampledAt)
            observeBambuPrinterRotationStates(entities: entities, now: sampledAt)
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
            for printerDevice in enabledDevices(for: .bambuLab) {
                guard let statusID = printerDevice.settings.bambuStatusEntityID, !statusID.isEmpty,
                      let e = entities.first(where: { $0.entityId == statusID }) else { continue }
                let state = e.state.trimmingCharacters(in: .whitespaces).lowercased()
                let prev = lastPrinterStatuses[printerDevice.id]
                lastPrinterStatuses[printerDevice.id] = state
                guard SmartCardRotationPolicy.printerActivity(state: state) == .completed,
                      let prev,
                      SmartCardRotationPolicy.printerActivity(state: prev) != .completed
                else { continue }
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
        let entities = entities.filter { !$0.entityId.hasPrefix("sensor.lingxi_mqtt_") }
            + bambuMQTTEntities.values.flatMap { $0 }
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
        func add(_ candidate: String) {
            let id = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !ids.contains(id) { ids.append(id) }
        }
        for printer in enabledDevices(for: .bambuLab) {
            let config = BambuLabCardSettings.from(printer)
            guard config.showImage else { continue }
            add(config.selectedImageEntityID)
        }
        // 只有当前正在显示 Bambu 独立卡片的 AI Mac 才额外保留双图，避免让
        // 键盘/墨水屏的单图选择无条件扩大后台图片下载量。
        for mode in activeAIMacCardModes where mode.bambuSlotIndex != nil {
            let config = bambuConfig(for: mode)
            guard config.showImage else { continue }
            add(config.imageEntityID)
            add(config.taskImageEntityID)
        }
        for device in enabledColorWiFiScreens {
            let config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
            if config.mode == .card, config.cardMode == .homeAssistant {
                HAEntityPicker.pictureEntityIDs(
                    in: config.haCardEntityIDs ?? settings.haCardEntityIDs).forEach(add)
            } else if config.mode == .canvas,
                      config.canvasBoards.indices.contains(config.canvasBoardIndex) {
                let board = config.canvasBoards[config.canvasBoardIndex]
                if board.moduleList.contains(.homeAssistant) {
                    HAEntityPicker.pictureEntityIDs(in: board.haEntityIDs).forEach(add)
                }
            }
        }
        // Fetch static covers once when preparing an offline test, even if the
        // currently visible online card uses its camera or another card type.
        // Do not expand steady-state camera/image polling for all saved cards.
        for device in enabledDevices(for: .c6Screen) where c6OfflineSimulationBusyIDs.contains(device.id) {
            let selection = c6Selection(for: device)
            for printer in selection.printers where printer.sourceHA && printer.showImage {
                add(printer.imageEntity); add(printer.taskCoverEntity)
            }
            HAEntityPicker.pictureEntityIDs(in: selection.ha.entities.map(\.id)).forEach(add)
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
                config.errorEntityID, config.imageEntityID, config.taskImageEntityID]
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
        if let device = bambuDevice(for: mode), device.settings.bambuDataSource == .localMQTT {
            reconcileBambuMQTTClients(); return
        }
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
            let sampledAt = Date()
            applyHASnapshot(entities: merged, errorText: nil, rebuildBambuCatalog: false,
                            sampledAt: sampledAt)
            if let device = bambuDevice(for: mode) {
                observeBambuPrinterRotationStates(
                    entities: merged, now: sampledAt, deviceIDs: [device.id])
            }
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
        let retainedAtStart = pictureEntityIDs()
        let retainedAtStartSet = Set(retainedAtStart)
        let wanted = (wantedIDs ?? retainedAtStart).filter { retainedAtStartSet.contains($0) }
        guard !retainedAtStart.isEmpty else {
            let changed = !haSnapshot.images.isEmpty
            if !haSnapshot.images.isEmpty { haSnapshot.images = [:] }
            bambuAutoZoomImages = [:]
            bambuCameraZoomRuntime = [:]
            haPictureRequestGenerations = [:]
            c6PictureTaskKeys = [:]
            c6PictureOrigins = [:]
            return changed
        }
        // URL 和鉴权必须属于同一轮服务器配置；等待期间切换 HA 时，旧请求结果
        // 不能写回新服务器的同名实体缓存。
        let serverURL = settings.haServerURL
        let token = settings.haToken
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.entityId, $0) })
        var pictureTaskKeys: [String: [String: String]] = [:]
        for printer in enabledDevices(for: .bambuLab) where printer.settings.bambuDataSource != .localMQTT {
            let fields = BambuLabCardSettings.from(printer)
            if let task = byID[fields.taskEntityID], let key = C6TaskThumbnail.homeAssistantTaskKey(task.state) {
                for imageID in [fields.taskImageEntityID, fields.imageEntityID] where !imageID.isEmpty {
                    pictureTaskKeys[imageID, default: [:]][fields.taskEntityID] = key
                }
            }
        }
        var requests: [(id: String, url: URL, generation: UInt64)] = []
        for id in wanted {
            guard let entity = byID[id],
                  let url = HomeAssistantClient.imageURL(server: serverURL,
                                                         entity: entity,
                                                         token: token) else { continue }
            let generation = (haPictureRequestGenerations[id] ?? 0) &+ 1
            haPictureRequestGenerations[id] = generation
            requests.append((id, url, generation))
        }
        let fetched = await withTaskGroup(of: (String, UInt64, Data?).self) { group in
            for request in requests {
                group.addTask {
                    (request.id, request.generation,
                     try? await HomeAssistantClient.fetchImage(url: request.url, token: token))
                }
            }
            var result: [(String, UInt64, Data)] = []
            for await (id, generation, data) in group {
                if let data { result.append((id, generation, data)) }
            }
            return result
        }
        guard !Task.isCancelled,
              settings.haServerURL == serverURL, settings.haToken == token else { return false }
        // 两台小屏或快速换板可能并发抓图。完成时重新计算保留集合，并从此刻的
        // 全局缓存合并，避免较早启动、较晚结束的请求删掉另一台刚写入的帧。
        let retainedNow = Set(pictureEntityIDs())
        haPictureRequestGenerations = haPictureRequestGenerations.filter {
            retainedNow.contains($0.key)
        }
        bambuAutoZoomImages = bambuAutoZoomImages.filter { retainedNow.contains($0.key) }
        bambuCameraZoomRuntime = bambuCameraZoomRuntime.filter { retainedNow.contains($0.key) }
        var images = haSnapshot.images.filter { retainedNow.contains($0.key) }
        for (id, generation, data) in fetched
            where retainedNow.contains(id) && haPictureRequestGenerations[id] == generation {
            images[id] = data
            c6PictureTaskKeys[id] = pictureTaskKeys[id]
            c6PictureOrigins[id] = Self.sha256(Data(serverURL.utf8) + Data([0]) + Data(token.utf8))
        }
        c6PictureTaskKeys = c6PictureTaskKeys.filter { retainedNow.contains($0.key) }
        c6PictureOrigins = c6PictureOrigins.filter { retainedNow.contains($0.key) }
        let changed = images != haSnapshot.images
        haSnapshot.images = images
        scheduleC6ThumbnailSync()
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
        for device in enabledColorWiFiScreens {
            let config = device.settings.aiMacScreen ?? AIMacScreenDeviceSettings()
            (config.haCardEntityIDs ?? settings.haCardEntityIDs).forEach { add($0) }
            config.canvasBoards.flatMap(\.haEntityIDs).forEach { add($0) }
        }
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

    /// 口袋先知与 AI Mac 小屏幕分别保存自己的歌词联动目标；默认不关联。
    func lyricsKeyboardDeviceID(for owner: CanvasOwner) -> UUID? {
        switch owner {
        case .oracle:
            guard let id = activeDeviceID(for: .oracle) else { return nil }
            return settings.devices.first(where: { $0.id == id })?
                .settings.oracleLyricsKeyboardDeviceID
        case .aiMac:
            guard let id = activeColorScreenDeviceID else { return nil }
            return aiMacScreenSettings(for: id).lyricsKeyboardDeviceID
        case .keyboard, .excerpt:
            return nil
        }
    }

    func setLyricsKeyboardDeviceID(_ keyboardID: UUID?, for owner: CanvasOwner) {
        switch owner {
        case .oracle:
            guard let id = activeDeviceID(for: .oracle),
                  let index = settings.devices.firstIndex(where: {
                      $0.id == id && $0.type == .oracle
                  }) else { return }
            settings.devices[index].settings.oracleLyricsKeyboardDeviceID = keyboardID
            persistSettings()
        case .aiMac:
            guard let id = activeColorScreenDeviceID else { return }
            mutateAIMacScreenSettings(id, schedulePush: false) {
                $0.lyricsKeyboardDeviceID = keyboardID
            }
        case .keyboard, .excerpt:
            return
        }
        if let keyboardID {
            prepareKeyboardForLyricsLink(keyboardID)
        }
        resetLinkedLyricsScheduling()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshLyricsIfNeeded(force: true)
            self.scheduleLinkedLyricsPush(force: true)
        }
    }

    /// 歌词联动是目标键盘的独占显示模式：停止轮播并固定到正在播放页。
    /// 取消关联时不自动恢复旧状态，避免覆盖用户关联后的手动调整。
    private func prepareKeyboardForLyricsLink(_ keyboardID: UUID) {
        guard let index = settings.devices.firstIndex(where: {
            $0.id == keyboardID && $0.type == .keyboard && $0.isEnabled
        }) else { return }
        settings.devices[index].settings.cardRotationEnabled = false
        settings.devices[index].settings.smartRotationReturnDisplayMode = nil
        settings.devices[index].settings.smartRotationReturnPrinterDeviceID = nil
        settings.devices[index].settings.displayMode = .nowPlaying
        if activeDeviceID(for: .keyboard) == keyboardID {
            settings.cardRotationEnabled = false
            settings.displayMode = .nowPlaying
            lastCardRotation = nil
            cardRotationIndex = 0
            renderPreview()
        }
        persistSettings()
    }

    func lyricsKeyboardBinding(for owner: CanvasOwner) -> Binding<UUID?> {
        Binding(get: { self.lyricsKeyboardDeviceID(for: owner) },
                set: { self.setLyricsKeyboardDeviceID($0, for: owner) })
    }

    private var linkedLyricsKeyboardIDs: Set<UUID> {
        var ids = Set<UUID>()
        for device in enabledDevices(for: .oracle) {
            if let id = device.settings.oracleLyricsKeyboardDeviceID { ids.insert(id) }
        }
        for device in enabledColorWiFiScreens {
            if let id = (device.settings.aiMacScreen ?? AIMacScreenDeviceSettings())
                .lyricsKeyboardDeviceID { ids.insert(id) }
        }
        let enabledKeyboardIDs = Set(enabledDevices(for: .keyboard).map(\.id))
        return ids.intersection(enabledKeyboardIDs)
    }

    private func lyricsForKeyboard(_ keyboardID: UUID?) -> LyricsTrack? {
        guard let keyboardID, linkedLyricsKeyboardIDs.contains(keyboardID) else { return nil }
        return nowPlayingLyrics
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
            guard let id = activeColorScreenDeviceID else { return [] }
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
        case .aiMac:
            guard let deviceID = activeColorScreenDeviceID else { return }
            // 图片实体要先取得静态帧再首次推送，不能让通用设置监听抢先发送空图。
            mutateCurrentAIMacCanvasBoard(pushImmediately: false, schedulePush: false) {
                $0.haEntityIDs = cleaned
            }
            scheduleCurrentAIMacCanvasPicturesAndPush(deviceID: deviceID)
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
            guard let id = activeColorScreenDeviceID else { return 3 }
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
            guard let id = activeColorScreenDeviceID else { return false }
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
            guard let id = activeColorScreenDeviceID else { return true }
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
            guard let id = activeColorScreenDeviceID else { return true }
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
            guard let id = activeColorScreenDeviceID else { stored = [:]; break }
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
            guard let id = activeColorScreenDeviceID else { return false }
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
                if connected, self.rand0SessionNeedsPrime,
                   !self.rand0SessionPrimeInFlight {
                    // 首次连接与每次自动重连后立即发送当前画板，完成显示模式初始化；
                    // 之后自动推送与设备按键无需再靠一次人工测试推送来“唤醒”。
                    self.rand0SessionPrimeInFlight = true
                    defer { self.rand0SessionPrimeInFlight = false }
                    for attempt in 0..<5 {
                        guard self.rand0Session === session,
                              self.rand0SessionIP == ip,
                              self.rand0SessionEndpoint == endpoint,
                              self.rand0SessionNeedsPrime else { return }
                        if session.isConnected {
                            let didPush = await self.pushOracleCanvas(
                                preRenderedFrame: nil, skipIfUnchanged: false)
                            // 发送完成时连接仍有效，才算设备真正接收了本次首帧。
                            if didPush, session.isConnected {
                                self.rand0SessionNeedsPrime = false
                                return
                            }
                        }
                        guard attempt < 4 else { break }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
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

    // MARK: - M5 StickS3 蓝牙控制器

    /// 可由控制器切换和翻页的显示设备。AWTRIX 是 1.5.5 主线新增目标。
    public static let m5ControllableTypes: [DeviceType] = [
        .keyboard, .oracle, .excerpt, .aiMacScreen, .awtrix
    ]

    private var embeddedM5FirmwareURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("Firmware", isDirectory: true)
            .appendingPathComponent(EmbeddedM5StickS3Firmware.fileName)
    }

    private var embeddedM5FlashHelperURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("Firmware", isDirectory: true)
            .appendingPathComponent(EmbeddedM5StickS3Firmware.helperName)
    }

    public private(set) lazy var embeddedM5FirmwareReady: Bool = {
        guard let firmwareURL = embeddedM5FirmwareURL,
              let helperURL = embeddedM5FlashHelperURL,
              let firmware = try? Data(contentsOf: firmwareURL) else { return false }
        return EmbeddedM5StickS3Firmware.validate(firmware)
            && FileManager.default.isExecutableFile(atPath: helperURL.path)
    }()

    /// StickS3 使用 ESP32-S3 原生 USB CDC，只显示 usbmodem 端口，避免用户误刷
    /// 同时连接的 CH340/CP210x 打印机、键盘或其他串口设备。
    public func refreshM5FlashPorts() {
        m5FlashPorts = ESP8266FirmwareFlasher.discoverM5StickS3SerialPorts()
        if !m5FlashPorts.contains(where: { $0.path == selectedM5FlashPort }) {
            selectedM5FlashPort = m5FlashPorts.first?.path ?? ""
        }
        if m5FlashPorts.isEmpty {
            m5FlashStatus = "没有发现 StickS3 原生 USB 串口，请检查数据线并让设备进入下载模式"
        } else if !m5FlashBusy {
            m5FlashStatus = "已发现 \(m5FlashPorts.count) 个 StickS3 候选串口"
        }
    }

    @discardableResult
    public func flashM5StickS3Firmware() async -> Bool {
        guard !m5FlashBusy, !aiMacFlashBusy else { return false }
        guard let port = m5FlashPorts.first(where: { $0.path == selectedM5FlashPort }) else {
            m5FlashStatus = ESP8266FlashError.noPort.localizedDescription
            return false
        }
        guard let firmwareURL = embeddedM5FirmwareURL,
              let helperURL = embeddedM5FlashHelperURL else {
            m5FlashStatus = ESP8266FlashError.missingResource("StickS3 固件").localizedDescription
            return false
        }

        m5FlashBusy = true
        m5FlashProgress = 0
        m5FlashLog = ""
        m5FlashStatus = "正在连接 ESP32-S3…"
        defer { m5FlashBusy = false }
        do {
            try await m5FirmwareFlasher.flashM5StickS3(
                port: port, helperURL: helperURL, firmwareURL: firmwareURL,
                progress: { [weak self] value in
                    Task { @MainActor in
                        self?.m5FlashProgress = value
                        self?.m5FlashStatus = value > 0
                            ? "正在刷入 StickS3 固件… \(Int((value * 100).rounded()))%"
                            : "正在连接 ESP32-S3…"
                    }
                },
                log: { [weak self] text in
                    Task { @MainActor in
                        guard let self else { return }
                        self.m5FlashLog += text
                        if self.m5FlashLog.count > 20_000 {
                            self.m5FlashLog = String(self.m5FlashLog.suffix(20_000))
                        }
                    }
                })
            m5FlashProgress = 1
            m5FlashStatus = "刷入成功，StickS3 已自动重启；正在扫描蓝牙控制器…"
            status = "M5 StickS3 固件刷入成功"
            refreshM5FlashPorts()
            m5StartScan()
            return true
        } catch {
            m5FlashStatus = error.localizedDescription
            status = "M5 StickS3 固件刷入失败"
            refreshM5FlashPorts()
            return false
        }
    }

    public func cancelM5FirmwareFlash() {
        m5FirmwareFlasher.cancel()
        m5FlashStatus = "正在停止刷写…"
    }

    public func ensureM5ControllerSession() {
        guard backgroundServicesEnabled else { return }
        let device = settings.activeDevice(for: .m5Controller)
        let pairedID: UUID? = {
            guard let device, device.isEnabled,
                  let raw = device.settings.m5Controller?.pairedPeripheralID else { return nil }
            return UUID(uuidString: raw)
        }()
        guard let pairedID else {
            releaseM5HeldShortcut()
            m5BLEClient?.disconnect()
            m5ControllerConnected = false
            return
        }
        obtainM5BLEClient().connect(peripheralID: pairedID)
    }

    private func obtainM5BLEClient() -> M5ControllerBLEClient {
        if let m5BLEClient { return m5BLEClient }
        let client = M5ControllerBLEClient()
        client.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handleM5ControllerEvent(event) }
        }
        client.onConnectionChange = { [weak self] connected in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.m5ControllerConnected = connected
                if connected {
                    self.status = self.m5RepairPhase == .waitingForSystemPairing
                        ? "控制器已连接，正在等待 macOS 完成蓝牙输入设备配对"
                        : "M5 StickS3 控制器已连接"
                    self.lastM5InfoSent = nil
                    self.sendM5ControllerInfo()
                } else if self.settings.activeDevice(for: .m5Controller)?
                    .settings.m5Controller?.pairedPeripheralID != nil {
                    self.releaseM5HeldShortcut()
                    self.m5ControllerHIDReady = false
                    self.m5ControllerHIDSecured = false
                    self.status = "M5 StickS3 控制器已断开，等待重连…"
                } else if !connected {
                    self.releaseM5HeldShortcut()
                    self.m5ControllerHIDReady = false
                    self.m5ControllerHIDSecured = false
                }
            }
        }
        client.onDiscovered = { [weak self] list in
            Task { @MainActor [weak self] in self?.m5DiscoveredControllers = list }
        }
        client.onScanStateChange = { [weak self] scanning in
            Task { @MainActor [weak self] in self?.m5ControllerScanning = scanning }
        }
        client.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in self?.m5BluetoothState = state }
        }
        client.onInfoTransmissionResult = { [weak self] data, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.lastM5InfoSent = nil
                    self.status = "控制器卡片同步失败：\(error.localizedDescription)"
                } else if self.m5ControllerPreviewInfo?.encoded() == data {
                    // 只有实机完成重组和解析后才记为已同步；预览更新不再提前
                    // 吞掉后续重试。
                    self.lastM5InfoSent = data
                }
            }
        }
        m5BLEClient = client
        return client
    }

    public func m5StartScan() {
        let client = obtainM5BLEClient()
        client.clearDiscovered()
        client.startScan()
    }

    public func m5StopScan() {
        m5BLEClient?.stopScan()
    }

    public func m5PairController(_ discovered: M5DiscoveredController) {
        let deviceID = m5RepairingControllerID
            ?? settings.activeDevice(for: .m5Controller)?.id
            ?? addDevice(type: .m5Controller)
        // 多控制器场景必须把扫描结果写回发起重新配对的那张设备卡，不能因为
        // 当前活动设备改变而覆盖另一台控制器的配对信息。
        if settings.activeDeviceID(for: .m5Controller) != deviceID {
            switchDevice(type: .m5Controller, to: deviceID)
        }
        mutateM5ControllerSettings(deviceID) {
            $0.pairedPeripheralID = discovered.id.uuidString
            $0.pairedName = discovered.name
        }
        m5ControllerPage = .mainMenu
        m5HASelectionIndex = 0
        m5HAActionMessage = nil
        m5ControllerHIDReady = false
        m5ControllerHIDSecured = false
        if m5RepairingControllerID != nil {
            m5RepairPhase = .waitingForSystemPairing
            m5RepairingPeripheralName = discovered.name
        }
        m5StopScan()
        m5DiscoveredControllers = []
        ensureM5ControllerSession()
        status = "已选择 M5 StickS3「\(discovered.name)」，正在连接并等待系统配对"
    }

    public func m5UnpairController(deviceID: UUID) {
        mutateM5ControllerSettings(deviceID) {
            $0.pairedPeripheralID = nil
            $0.pairedName = nil
        }
        clearM5ControllerInfoAndDisconnect()
        m5ControllerConnected = false
        lastM5InfoSent = nil
        m5ControllerPage = .mainMenu
        m5HASelectionIndex = 0
        m5HAActionMessage = nil
        m5GyroRecenterTokens.removeValue(forKey: deviceID)
        m5RepairingControllerID = nil
        m5RepairingPeripheralName = nil
        m5RepairPhase = nil
        status = "已解除软件配对；重新配对前请在系统蓝牙中手动忽略原设备"
    }

    public func m5BeginRepairController(deviceID: UUID) {
        let config = m5ControllerSettings(for: deviceID)
        let previousName = config.pairedName ?? "Lingxi-Controller"
        m5UnpairController(deviceID: deviceID)
        m5RepairingControllerID = deviceID
        m5RepairingPeripheralName = previousName
        m5RepairPhase = .removeSystemRecord
        m5OpenBluetoothSettings()
        status = "重新配对第 1 步：请在系统蓝牙中忽略旧的 \(previousName)"
    }

    public func m5OpenBluetoothSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    public func m5ContinueRepairScan() {
        guard m5RepairingControllerID != nil else { return }
        m5RepairPhase = .scanning
        m5StartScan()
        status = "重新配对第 2 步：正在扫描已清除旧记录的 StickS3"
    }

    public func m5ReturnToRepairSystemStep() {
        guard m5RepairingControllerID != nil else { return }
        m5StopScan()
        m5RepairPhase = .removeSystemRecord
        m5OpenBluetoothSettings()
        status = "重新配对第 1 步：请先在系统蓝牙中忽略旧的 \(m5RepairingPeripheralName ?? "Lingxi-Controller")"
    }

    public func m5CancelRepair() {
        m5RepairingControllerID = nil
        m5RepairingPeripheralName = nil
        m5RepairPhase = nil
        m5StopScan()
    }

    /// 删除或解除配对时写给 StickS3 的空页面。BLE 客户端会等待带响应写入完成，
    /// 再真正断开连接；这同时阻止旧按键事件继续控制已删除的目标。
    private func clearM5ControllerInfoAndDisconnect() {
        releaseM5HeldShortcut()
        guard let client = m5BLEClient else { return }
        if let data = M5ControllerInfo.clearedPairing.encoded() {
            client.clearInfoAndDisconnect(info: data)
        } else {
            client.disconnect()
        }
    }

    public func m5ControllerSettings(for id: UUID) -> M5ControllerDeviceSettings {
        settings.devices.first(where: { $0.id == id && $0.type == .m5Controller })?
            .settings.m5Controller ?? M5ControllerDeviceSettings()
    }

    public func m5BuzzerBinding(controllerID: UUID) -> Binding<Bool> {
        Binding(get: {
            self.m5ControllerSettings(for: controllerID).resolvedBuzzerEnabled
        }, set: { enabled in
            self.mutateM5ControllerSettings(controllerID) { $0.buzzerEnabled = enabled }
            self.lastM5InfoSent = nil
            self.sendM5ControllerInfo()
        })
    }

    public func m5MediaControlsEnabledBinding(controllerID: UUID) -> Binding<Bool> {
        Binding(get: {
            self.m5ControllerSettings(for: controllerID).resolvedMediaControlsEnabled
        }, set: { enabled in
            self.mutateM5ControllerSettings(controllerID) { $0.mediaControlsEnabled = enabled }
            if !enabled, self.m5ControllerPage == .mediaControls {
                self.m5ControllerPage = .macShortcuts
            }
            self.m5MainSelectionIndex = 0
            self.m5ShortcutMenuSelectionIndex = 0
            self.lastM5InfoSent = nil
            self.sendM5ControllerInfo()
        })
    }

    public func m5GyroMouseEnabledBinding(controllerID: UUID) -> Binding<Bool> {
        Binding(get: {
            self.m5ControllerSettings(for: controllerID).resolvedGyroMouseEnabled
        }, set: { enabled in
            self.mutateM5ControllerSettings(controllerID) { $0.gyroMouseEnabled = enabled }
            if !enabled, self.m5ControllerPage == .gyroMouse {
                self.m5ControllerPage = .macShortcuts
            }
            self.m5MainSelectionIndex = 0
            self.m5ShortcutMenuSelectionIndex = 0
            self.lastM5InfoSent = nil
            self.sendM5ControllerInfo()
        })
    }

    public func m5GyroMouseSensitivityBinding(controllerID: UUID) -> Binding<Double> {
        Binding(get: {
            self.m5ControllerSettings(for: controllerID).resolvedGyroMouseSensitivity
        }, set: { value in
            self.mutateM5ControllerSettings(controllerID) { $0.gyroMouseSensitivity = value }
            self.lastM5InfoSent = nil
            self.sendM5ControllerInfo()
        })
    }

    public func m5GyroMouseDeadZoneBinding(controllerID: UUID) -> Binding<Double> {
        Binding(get: {
            self.m5ControllerSettings(for: controllerID).resolvedGyroMouseDeadZone
        }, set: { value in
            self.mutateM5ControllerSettings(controllerID) { $0.gyroMouseDeadZone = value }
            self.lastM5InfoSent = nil
            self.sendM5ControllerInfo()
        })
    }

    public func m5GyroMouseSmoothingBinding(controllerID: UUID) -> Binding<Double> {
        Binding(get: {
            self.m5ControllerSettings(for: controllerID).resolvedGyroMouseSmoothing
        }, set: { value in
            self.mutateM5ControllerSettings(controllerID) { $0.gyroMouseSmoothing = value }
            self.lastM5InfoSent = nil
            self.sendM5ControllerInfo()
        })
    }

    public func m5GyroMouseInvertXBinding(controllerID: UUID) -> Binding<Bool> {
        Binding(get: {
            self.m5ControllerSettings(for: controllerID).resolvedGyroMouseInvertX
        }, set: { value in
            self.mutateM5ControllerSettings(controllerID) { $0.gyroMouseInvertX = value }
            self.lastM5InfoSent = nil
            self.sendM5ControllerInfo()
        })
    }

    public func m5GyroMouseInvertYBinding(controllerID: UUID) -> Binding<Bool> {
        Binding(get: {
            self.m5ControllerSettings(for: controllerID).resolvedGyroMouseInvertY
        }, set: { value in
            self.mutateM5ControllerSettings(controllerID) { $0.gyroMouseInvertY = value }
            self.lastM5InfoSent = nil
            self.sendM5ControllerInfo()
        })
    }

    public func m5GyroMouseClutchEnabledBinding(controllerID: UUID) -> Binding<Bool> {
        Binding(get: {
            self.m5ControllerSettings(for: controllerID).resolvedGyroMouseClutchEnabled
        }, set: { value in
            self.mutateM5ControllerSettings(controllerID) {
                $0.gyroMouseClutchEnabled = value
            }
            self.lastM5InfoSent = nil
            self.sendM5ControllerInfo()
        })
    }

    /// 固件进入飞鼠页时会自动采样静止零偏与自然握姿；此操作用于用户中途
    /// 换握姿后重新采样。完成后固件会请求 Mac 把指针移到当前显示器中心。
    /// token 避免 BLE 重发同一载荷时重复进入校准。
    public func m5RecenterGyroMouse(controllerID: UUID) {
        var token = (m5GyroRecenterTokens[controllerID] ?? 0) &+ 1
        if token == 0 { token = 1 }
        m5GyroRecenterTokens[controllerID] = token
        lastM5InfoSent = nil
        sendM5ControllerInfo()
        status = m5ControllerConnected
            ? "StickS3：请保持自然握姿并静止约半秒，正在重新居中飞鼠"
            : "StickS3 尚未连接；重新进入飞鼠指针时会自动校准"
    }

    /// CGEvent 的位置与 CGDisplayBounds 使用同一套全局坐标，可直接在多显示器
    /// 环境中找到当前指针所在屏幕。这里只进行一次置中，不接管后续 HID 移动。
    private func centerM5AirMousePointer() {
        let currentLocation = CGEvent(source: nil)?.location
            ?? CGPoint(x: CGDisplayBounds(CGMainDisplayID()).midX,
                       y: CGDisplayBounds(CGMainDisplayID()).midY)
        var displayID = CGMainDisplayID()
        var displayCount: UInt32 = 0
        if CGGetDisplaysWithPoint(currentLocation, 1, &displayID, &displayCount) != .success
            || displayCount == 0 {
            displayID = CGMainDisplayID()
        }
        let bounds = CGDisplayBounds(displayID)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let result = CGWarpMouseCursorPosition(center)
        if result == .success {
            _ = CGAssociateMouseAndMouseCursorPosition(1)
            status = "M5 飞鼠指针已居中：慢移精准，快速扫腕可跨屏"
        } else {
            status = "M5 飞鼠校准完成，但 macOS 未能把指针移到屏幕中央"
        }
    }

    public func m5MacShortcuts(controllerID: UUID,
                               group: M5MacShortcutGroup? = nil) -> [M5MacShortcut] {
        let all = m5ControllerSettings(for: controllerID).resolvedMacShortcuts
        return group.map { selected in all.filter { $0.group == selected } } ?? all
    }

    public func m5MacShortcutEnabledBinding(controllerID: UUID,
                                            shortcutID: String) -> Binding<Bool> {
        Binding(get: {
            self.m5MacShortcuts(controllerID: controllerID)
                .first(where: { $0.id == shortcutID })?.isEnabled ?? false
        }, set: { enabled in
            self.mutateM5ControllerSettings(controllerID) { config in
                if config.macShortcuts == nil { config.macShortcuts = config.resolvedMacShortcuts }
                guard let index = config.macShortcuts?.firstIndex(where: { $0.id == shortcutID })
                else { return }
                config.macShortcuts?[index].isEnabled = enabled
            }
            self.m5MainSelectionIndex = 0
            self.m5ShortcutMenuSelectionIndex = 0
            self.lastM5InfoSent = nil
            self.sendM5ControllerInfo()
        })
    }

    public func m5MacShortcutNameBinding(controllerID: UUID,
                                         shortcutID: String) -> Binding<String> {
        Binding(get: {
            self.m5MacShortcuts(controllerID: controllerID)
                .first(where: { $0.id == shortcutID })?.name ?? ""
        }, set: { name in
            self.mutateM5ControllerSettings(controllerID) { config in
                if config.macShortcuts == nil { config.macShortcuts = config.resolvedMacShortcuts }
                guard let index = config.macShortcuts?.firstIndex(where: { $0.id == shortcutID })
                else { return }
                config.macShortcuts?[index].name = name
            }
            self.lastM5InfoSent = nil
            self.sendM5ControllerInfo()
        })
    }

    public func setM5MacShortcut(_ shortcut: GlobalShortcut,
                                 shortcutID: String, controllerID: UUID) {
        mutateM5ControllerSettings(controllerID) { config in
            if config.macShortcuts == nil { config.macShortcuts = config.resolvedMacShortcuts }
            guard let index = config.macShortcuts?.firstIndex(where: { $0.id == shortcutID })
            else { return }
            config.macShortcuts?[index].shortcut = shortcut
        }
        lastM5InfoSent = nil
        sendM5ControllerInfo()
    }

    public func addM5CustomShortcut(controllerID: UUID) {
        mutateM5ControllerSettings(controllerID) { config in
            var shortcuts = config.resolvedMacShortcuts
            let existing = shortcuts.filter { $0.group == .custom }.count
            shortcuts.append(.init(group: .custom, name: "自定义快捷键 \(existing + 1)",
                                   shortcut: .init(keyCode: 122, modifiers: 0)))
            config.macShortcuts = shortcuts
        }
        lastM5InfoSent = nil
        sendM5ControllerInfo()
    }

    public func removeM5CustomShortcut(_ shortcutID: String, controllerID: UUID) {
        mutateM5ControllerSettings(controllerID) { config in
            config.macShortcuts?.removeAll { $0.id == shortcutID && $0.group == .custom }
        }
        lastM5InfoSent = nil
        sendM5ControllerInfo()
    }

    private func mutateM5ControllerSettings(
        _ id: UUID,
        _ body: (inout M5ControllerDeviceSettings) -> Void
    ) {
        guard let index = settings.devices.firstIndex(where: {
            $0.id == id && $0.type == .m5Controller
        }) else { return }
        var value = settings.devices[index].settings.m5Controller
            ?? M5ControllerDeviceSettings()
        body(&value)
        value.clamp()
        settings.devices[index].settings.m5Controller = value
        persistSettings()
    }

    public static let m5HAControllableDomains = M5HAControlPolicy.supportedDomains

    public func m5HAEntityCandidates() -> [HAEntity] {
        haSnapshot.entities.filter(M5HAControlPolicy.isControllable).sorted {
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    public func m5HAEntityIDs(for controllerID: UUID) -> [String] {
        m5ControllerSettings(for: controllerID).homeAssistantEntityIDs ?? []
    }

    public func addM5HAEntities(_ entityIDs: [String], controllerID: UUID) {
        let allowed = Set(m5HAEntityCandidates().map(\.entityId))
        mutateM5ControllerSettings(controllerID) { config in
            var ids = config.homeAssistantEntityIDs ?? []
            for id in entityIDs where allowed.contains(id) && !ids.contains(id) { ids.append(id) }
            config.homeAssistantEntityIDs = ids
        }
        m5MainSelectionIndex = 0
        lastM5InfoSent = nil
        sendM5ControllerInfo()
    }

    public func removeM5HAEntity(_ entityID: String, controllerID: UUID) {
        mutateM5ControllerSettings(controllerID) { config in
            config.homeAssistantEntityIDs?.removeAll { $0 == entityID }
        }
        m5HASelectionIndex = min(m5HASelectionIndex,
                                 max(0, m5HAEntityIDs(for: controllerID).count - 1))
        m5MainSelectionIndex = 0
        lastM5InfoSent = nil
        sendM5ControllerInfo()
    }

    public func moveM5HAEntity(_ entityID: String, direction: Int, controllerID: UUID) {
        mutateM5ControllerSettings(controllerID) { config in
            var ids = config.homeAssistantEntityIDs ?? []
            guard let index = ids.firstIndex(of: entityID), ids.count > 1 else { return }
            let destination = min(max(index + direction, 0), ids.count - 1)
            guard destination != index else { return }
            ids.remove(at: index)
            ids.insert(entityID, at: destination)
            config.homeAssistantEntityIDs = ids
        }
        lastM5InfoSent = nil
        sendM5ControllerInfo()
    }

    public func m5ControllableDevices() -> [ManagedDevice] {
        Self.m5ControllableTypes.flatMap { settings.enabledDevices(for: $0) }
    }

    public func m5TargetToggleBinding(controllerID: UUID,
                                      targetID: UUID) -> Binding<Bool> {
        Binding(get: {
            self.m5ControllerSettings(for: controllerID)
                .targetDeviceIDs.contains(targetID.uuidString)
        }, set: { enabled in
            self.mutateM5ControllerSettings(controllerID) { config in
                if enabled {
                    if !config.targetDeviceIDs.contains(targetID.uuidString) {
                        config.targetDeviceIDs.append(targetID.uuidString)
                    }
                } else {
                    config.targetDeviceIDs.removeAll { $0 == targetID.uuidString }
                }
            }
            self.m5MainSelectionIndex = 0
            self.lastM5InfoSent = nil
            self.sendM5ControllerInfo()
        })
    }

    private func m5ConfiguredTargets(_ config: M5ControllerDeviceSettings) -> [ManagedDevice] {
        config.targetDeviceIDs.compactMap { raw in
            guard let id = UUID(uuidString: raw),
                  let device = settings.devices.first(where: { $0.id == id }),
                  Self.m5ControllableTypes.contains(device.type) else { return nil }
            return device
        }
    }

    public func m5ResolvedTargets(_ config: M5ControllerDeviceSettings)
        -> [(type: DeviceType, id: UUID, name: String)] {
        m5ConfiguredTargets(config).filter(\.isEnabled).map { ($0.type, $0.id, $0.name) }
    }

    private func m5ShortcutMenuItems(_ config: M5ControllerDeviceSettings)
        -> [M5ShortcutMenuItem] {
        var items: [M5ShortcutMenuItem] = []
        if config.resolvedMediaControlsEnabled { items.append(.mediaControls) }
        if config.resolvedGyroMouseEnabled { items.append(.gyroMouse) }
        if config.resolvedMacShortcuts.contains(where: {
            $0.group == .presentation && $0.isEnabled
        }) { items.append(.presentation) }
        if config.resolvedMacShortcuts.contains(where: {
            $0.group == .custom && $0.isEnabled
        }) { items.append(.custom) }
        return items
    }

    private func m5MainMenuItems(_ config: M5ControllerDeviceSettings) -> [M5MainMenuItem] {
        var items: [M5MainMenuItem] = []
        if config.resolvedMacShortcuts.contains(where: {
            $0.group == .vibeCoding && $0.isEnabled
        }) { items.append(.vibeCoding) }
        if !m5ConfiguredTargets(config).isEmpty { items.append(.devices) }
        if !(config.homeAssistantEntityIDs ?? []).isEmpty { items.append(.homeAssistant) }
        if !m5ShortcutMenuItems(config).isEmpty { items.append(.macShortcuts) }
        return items
    }

    private func normalizeM5Navigation(_ config: M5ControllerDeviceSettings) {
        let mainItems = m5MainMenuItems(config)
        let shortcutItems = m5ShortcutMenuItems(config)
        switch m5ControllerPage {
        case .mainMenu:
            m5MainSelectionIndex = min(max(m5MainSelectionIndex, 0), max(0, mainItems.count - 1))
        case .devices where !mainItems.contains(.devices),
             .homeAssistant where !mainItems.contains(.homeAssistant),
             .vibeCoding where !mainItems.contains(.vibeCoding):
            m5ControllerPage = .mainMenu
            m5MainSelectionIndex = 0
        case .macShortcuts where shortcutItems.isEmpty:
            m5ControllerPage = .mainMenu
            m5MainSelectionIndex = 0
        case .mediaControls where !shortcutItems.contains(.mediaControls),
             .gyroMouse where !shortcutItems.contains(.gyroMouse),
             .presentation where !shortcutItems.contains(.presentation),
             .customShortcuts where !shortcutItems.contains(.custom):
            m5ControllerPage = shortcutItems.isEmpty ? .mainMenu : .macShortcuts
            m5ShortcutMenuSelectionIndex = 0
        default:
            break
        }
    }

    private func handleM5ControllerEvent(_ event: M5ControllerEvent) {
        if case .hidState(let ready, let secured) = event {
            m5ControllerHIDReady = ready
            m5ControllerHIDSecured = secured
            if ready {
                status = "M5 StickS3 已完成配对，控制与输入功能均可用"
                if m5RepairPhase == .waitingForSystemPairing {
                    m5RepairingControllerID = nil
                    m5RepairingPeripheralName = nil
                    m5RepairPhase = nil
                }
            } else if secured {
                status = "系统配对已通过，正在启用 StickS3 输入服务…"
            } else {
                status = "StickS3 控制已连接，请完成 macOS 蓝牙输入设备配对"
            }
            return
        }
        if case .pointerRecenter = event {
            centerM5AirMousePointer()
            return
        }
        guard let controller = settings.activeDevice(for: .m5Controller),
              let config = controller.settings.m5Controller else { return }
        switch m5ControllerPage {
        case .mainMenu:
            handleM5MainMenuEvent(event, controller: controller, config: config)
        case .devices:
            handleM5DeviceMenuEvent(event, controller: controller, config: config)
        case .homeAssistant:
            handleM5HomeAssistantEvent(event, controller: controller, config: config)
        case .mediaControls:
            handleM5MediaControlEvent(event)
        case .gyroMouse:
            handleM5GyroMouseEvent(event)
        case .macShortcuts:
            handleM5ShortcutMenuEvent(event, config: config)
        case .presentation, .vibeCoding, .customShortcuts:
            handleM5ShortcutActionEvent(event, controller: controller, config: config)
        }
    }

    private func m5CycledIndex(_ current: Int, count: Int, key: String) -> Int {
        guard count > 0 else { return 0 }
        let delta = key == "a" ? 1 : -1
        return ((current + delta) % count + count) % count
    }

    private func handleM5MainMenuEvent(_ event: M5ControllerEvent,
                                       controller: ManagedDevice,
                                       config: M5ControllerDeviceSettings) {
        let items = m5MainMenuItems(config)
        switch event {
        case .button(let key):
            m5MainSelectionIndex = m5CycledIndex(
                m5MainSelectionIndex, count: items.count, key: key)
        case .buttonLong(let key), .buttonLongHandledByHID(let key):
            guard key == "a" else { return }
            guard items.indices.contains(m5MainSelectionIndex) else { return }
            switch items[m5MainSelectionIndex] {
            case .vibeCoding:
                m5ControllerPage = .vibeCoding
                m5ShortcutActionSelectionIndex = 0
                m5ShortcutActionMessage = nil
            case .devices:
                m5ControllerPage = .devices
                m5DeviceSelectionIndex = min(max(config.activeTargetIndex, 0),
                                             max(0, m5ConfiguredTargets(config).count - 1))
            case .homeAssistant:
                m5ControllerPage = .homeAssistant
                m5HASelectionIndex = 0
                m5HAActionMessage = nil
                Task { @MainActor [weak self] in await self?.refreshM5HAControlEntities() }
            case .macShortcuts:
                m5ControllerPage = .macShortcuts
                m5ShortcutMenuSelectionIndex = 0
            }
        case .shake, .clearInput, .mediaGesture, .pointerRecenter, .hidState:
            return
        case .buttonUp, .buttonUpHandledByHID:
            return
        }
        lastM5InfoSent = nil
        sendM5ControllerInfo()
    }

    private func handleM5DeviceMenuEvent(_ event: M5ControllerEvent,
                                         controller: ManagedDevice,
                                         config: M5ControllerDeviceSettings) {
        let targets = m5ConfiguredTargets(config)
        switch event {
        case .button(let key):
            m5DeviceSelectionIndex = m5CycledIndex(m5DeviceSelectionIndex,
                                                   count: targets.count, key: key)
            if !targets.isEmpty {
                mutateM5ControllerSettings(controller.id) {
                    $0.activeTargetIndex = self.m5DeviceSelectionIndex
                }
            }
        case .buttonLong(let key), .buttonLongHandledByHID(let key):
            if key == "b" {
                m5ControllerPage = .mainMenu
            } else if targets.indices.contains(m5DeviceSelectionIndex),
                      targets[m5DeviceSelectionIndex].isEnabled {
                let target = targets[m5DeviceSelectionIndex]
                switchDevice(type: target.type, to: target.id)
                status = "M5 控制器：已切换到「\(target.name)」"
            } else {
                status = "M5 控制器：所选设备当前不可用"
            }
        case .shake(let direction):
            guard targets.indices.contains(m5DeviceSelectionIndex),
                  targets[m5DeviceSelectionIndex].isEnabled else { return }
            m5PageTarget(targets[m5DeviceSelectionIndex], direction: direction)
            return
        case .clearInput:
            return
        case .mediaGesture:
            return
        case .pointerRecenter, .hidState:
            return
        case .buttonUp, .buttonUpHandledByHID:
            return
        }
        lastM5InfoSent = nil
        sendM5ControllerInfo()
    }

    private func handleM5ShortcutMenuEvent(_ event: M5ControllerEvent,
                                           config: M5ControllerDeviceSettings) {
        let items = m5ShortcutMenuItems(config)
        switch event {
        case .button(let key):
            m5ShortcutMenuSelectionIndex = m5CycledIndex(
                m5ShortcutMenuSelectionIndex, count: items.count, key: key)
        case .buttonLong(let key), .buttonLongHandledByHID(let key):
            if key == "b" {
                m5ControllerPage = .mainMenu
            } else {
                guard items.indices.contains(m5ShortcutMenuSelectionIndex) else { return }
                switch items[m5ShortcutMenuSelectionIndex] {
                case .mediaControls:
                    m5ControllerPage = .mediaControls
                    m5MediaSelectionIndex = 0
                case .gyroMouse:
                    guard config.resolvedGyroMouseEnabled else {
                        status = "请先在 StickS3 设置中启用飞鼠指针"
                        break
                    }
                    m5ControllerPage = .gyroMouse
                    status = "M5 飞鼠指针：保持自然握姿并静止，随后指针会自动居中"
                case .presentation:
                    m5ControllerPage = .presentation
                case .custom:
                    m5ControllerPage = .customShortcuts
                }
                m5ShortcutActionSelectionIndex = 0
                m5ShortcutActionMessage = nil
            }
        case .shake, .clearInput, .mediaGesture, .pointerRecenter, .hidState:
            return
        case .buttonUp, .buttonUpHandledByHID:
            return
        }
        lastM5InfoSent = nil
        sendM5ControllerInfo()
    }

    private func handleM5GyroMouseEvent(_ event: M5ControllerEvent) {
        switch event {
        case .buttonLong(let key), .buttonLongHandledByHID(let key):
            if key == "b" {
                m5ControllerPage = .macShortcuts
                status = "已退出 M5 飞鼠指针"
            } else {
                status = "飞鼠指针需要更新并重新刷入内置 StickS3 固件"
                return
            }
        case .button, .buttonUp, .buttonUpHandledByHID, .shake, .clearInput,
             .mediaGesture, .pointerRecenter, .hidState:
            // 新固件直接通过 BLE HID 发送移动与按键；旧固件的回退事件不会在 Mac 注入鼠标。
            return
        }
        lastM5InfoSent = nil
        sendM5ControllerInfo()
    }

    private func handleM5MediaControlEvent(_ event: M5ControllerEvent) {
        let cards = M5MediaControlCard.allCases
        switch event {
        case .button(let key):
            m5MediaSelectionIndex = m5CycledIndex(
                m5MediaSelectionIndex, count: cards.count, key: key)
        case .buttonLong(let key):
            if key == "b" {
                m5ControllerPage = .macShortcuts
            } else if key == "a" {
                status = "M5 多媒体控制需要更新并重新刷入内置 StickS3 固件"
            }
        case .buttonLongHandledByHID(let key):
            guard key == "a", cards.indices.contains(m5MediaSelectionIndex) else { return }
            status = "M5 多媒体控制：已执行「\(cards[m5MediaSelectionIndex].holdAction.title)」"
        case .mediaGesture(let direction, let handledByHID):
            guard cards.indices.contains(m5MediaSelectionIndex) else { return }
            let card = cards[m5MediaSelectionIndex]
            let action = direction < 0 ? card.leftAction : card.rightAction
            status = handledByHID
                ? "M5 多媒体控制：已执行「\(action.title)」"
                : "M5 多媒体控制需要更新并重新刷入内置 StickS3 固件"
        case .shake:
            status = "M5 多媒体控制需要更新并重新刷入内置 StickS3 固件"
        case .buttonUp, .buttonUpHandledByHID, .clearInput, .pointerRecenter, .hidState:
            return
        }
        lastM5InfoSent = nil
        sendM5ControllerInfo()
    }

    private func m5ShortcutGroup(for page: M5ControllerPage) -> M5MacShortcutGroup? {
        switch page {
        case .presentation: return .presentation
        case .vibeCoding: return .vibeCoding
        case .customShortcuts: return .custom
        default: return nil
        }
    }

    private func handleM5ShortcutActionEvent(_ event: M5ControllerEvent,
                                             controller: ManagedDevice,
                                             config: M5ControllerDeviceSettings) {
        guard let group = m5ShortcutGroup(for: m5ControllerPage) else { return }
        let actions = config.resolvedMacShortcuts.filter { $0.group == group && $0.isEnabled }
        switch event {
        case .button(let key):
            m5ShortcutActionSelectionIndex = m5CycledIndex(
                m5ShortcutActionSelectionIndex, count: actions.count, key: key)
            m5ShortcutActionMessage = nil
        case .buttonLong(let key):
            if key == "b" {
                releaseM5HeldShortcut()
                m5ControllerPage = .macShortcuts
                m5ShortcutActionMessage = nil
            } else if actions.indices.contains(m5ShortcutActionSelectionIndex) {
                let action = actions[m5ShortcutActionSelectionIndex]
                if action.id == "vibe.voice" {
                    beginM5HeldShortcut(action)
                } else {
                    executeM5MacShortcut(action)
                }
            }
        case .buttonLongHandledByHID(let key):
            guard key == "a",
                  actions.indices.contains(m5ShortcutActionSelectionIndex) else { return }
            let action = actions[m5ShortcutActionSelectionIndex]
            releaseM5HeldShortcut()
            if action.id == "vibe.voice" {
                m5ShortcutActionMessage = "按住说话… · 设备键盘"
                status = "M5 快捷键：StickS3 HID 正在按住「语音输入」"
            } else {
                m5ShortcutActionMessage = "已执行 · 设备键盘"
                status = "M5 快捷键：已通过 StickS3 执行「\(action.name)」"
            }
        case .shake:
            return
        case .mediaGesture:
            return
        case .clearInput(let handledByHID):
            guard actions.indices.contains(m5ShortcutActionSelectionIndex),
                  actions[m5ShortcutActionSelectionIndex].id == "vibe.voice" else { return }
            releaseM5HeldShortcut()
            if handledByHID {
                m5ShortcutActionMessage = "已摇一摇清空 · 设备键盘"
                status = "M5 快捷键：已通过 StickS3 清空当前输入框"
            } else if clearM5FocusedInput() {
                m5ShortcutActionMessage = "已摇一摇清空"
                status = "M5 快捷键：已清空当前输入框"
            } else {
                m5ShortcutActionMessage = "清空失败 · 检查辅助功能权限"
                status = "M5 快捷键：无法清空输入框，请检查辅助功能权限"
            }
        case .pointerRecenter, .hidState:
            return
        case .buttonUp(let key):
            guard key == "a" else { return }
            releaseM5HeldShortcut()
        case .buttonUpHandledByHID(let key):
            guard key == "a",
                  actions.indices.contains(m5ShortcutActionSelectionIndex),
                  actions[m5ShortcutActionSelectionIndex].id == "vibe.voice" else { return }
            m5ShortcutActionMessage = "已松开 · 输入结束"
            status = "M5 快捷键：StickS3 HID 已结束「语音输入」"
        }
        lastM5InfoSent = nil
        sendM5ControllerInfo()
    }

    private func executeM5MacShortcut(_ action: M5MacShortcut) {
        guard AXIsProcessTrusted() else {
            m5ShortcutActionMessage = "需要辅助功能权限"
            status = "M5 快捷键：请在系统设置中允许多屏灵犀使用辅助功能"
            return
        }
        releaseM5HeldShortcut()
        guard postM5ShortcutEvent(action.shortcut, keyDown: true),
              postM5ShortcutEvent(action.shortcut, keyDown: false) else {
            m5ShortcutActionMessage = "执行失败"
            return
        }
        m5ShortcutActionMessage = "已执行 · \(action.shortcut.displayString)"
        status = "M5 快捷键：已执行「\(action.name)」"
    }

    /// 固件尚未成为 macOS HID 键盘时的兼容回退。正常情况下由 StickS3
    /// 直接发送 Command+A 与 Delete，以免输入法过滤软件合成事件。
    private func clearM5FocusedInput() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let selectAll = GlobalShortcut(keyCode: 0, modifiers: GlobalShortcut.cmdKey)
        let delete = GlobalShortcut(keyCode: 51, modifiers: 0)
        guard postM5ShortcutEvent(selectAll, keyDown: true),
              postM5ShortcutEvent(selectAll, keyDown: false) else { return false }
        usleep(12_000)
        return postM5ShortcutEvent(delete, keyDown: true)
            && postM5ShortcutEvent(delete, keyDown: false)
    }

    private func beginM5HeldShortcut(_ action: M5MacShortcut) {
        guard AXIsProcessTrusted() else {
            m5ShortcutActionMessage = "需要辅助功能权限"
            status = "M5 快捷键：请在系统设置中允许多屏灵犀使用辅助功能"
            return
        }
        releaseM5HeldShortcut()
        guard postM5ShortcutEvent(action.shortcut, keyDown: true) else {
            m5ShortcutActionMessage = "启动失败"
            return
        }
        m5HeldShortcut = action
        m5ShortcutActionMessage = "按住说话…"
        status = "M5 快捷键：正在按住「\(action.name)」"
    }

    private func releaseM5HeldShortcut() {
        guard let action = m5HeldShortcut else { return }
        _ = postM5ShortcutEvent(action.shortcut, keyDown: false)
        m5HeldShortcut = nil
        m5ShortcutActionMessage = "已松开 · 输入结束"
        status = "M5 快捷键：已结束「\(action.name)」"
    }

    @discardableResult
    private func postM5ShortcutEvent(_ shortcut: GlobalShortcut, keyDown: Bool) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(shortcut.keyCode), keyDown: keyDown) else {
            return false
        }
        var flags: CGEventFlags = []
        if shortcut.modifiers & GlobalShortcut.cmdKey != 0 { flags.insert(.maskCommand) }
        if shortcut.modifiers & GlobalShortcut.shiftKey != 0 { flags.insert(.maskShift) }
        if shortcut.modifiers & GlobalShortcut.optionKey != 0 { flags.insert(.maskAlternate) }
        if shortcut.modifiers & GlobalShortcut.controlKey != 0 { flags.insert(.maskControl) }
        if let physicalModifier = GlobalShortcut.modifierMask(for: shortcut.keyCode) {
            // 单独修饰键必须在按下事件中带上自己的 flag，松开时则清除；否则
            // 系统只会看到虚拟键码，却不会改变 Control/Option/Command 的按压状态。
            if keyDown {
                if physicalModifier == GlobalShortcut.cmdKey { flags.insert(.maskCommand) }
                if physicalModifier == GlobalShortcut.shiftKey { flags.insert(.maskShift) }
                if physicalModifier == GlobalShortcut.optionKey { flags.insert(.maskAlternate) }
                if physicalModifier == GlobalShortcut.controlKey { flags.insert(.maskControl) }
            } else {
                flags = []
            }
            // 真实修饰键产生 flagsChanged，而不是普通 keyDown/keyUp。此修正让
            // 接受合成事件的软件也能按正确时序识别；微信输入法仍优先走设备 HID。
            event.type = .flagsChanged
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        return true
    }

    private func handleM5HomeAssistantEvent(_ event: M5ControllerEvent,
                                            controller: ManagedDevice,
                                            config: M5ControllerDeviceSettings) {
        let ids = config.homeAssistantEntityIDs ?? []
        switch event {
        case .button(let key):
            guard !ids.isEmpty else { return }
            let delta = key == "a" ? 1 : -1
            m5HASelectionIndex = ((m5HASelectionIndex + delta) % ids.count + ids.count) % ids.count
            m5HAActionMessage = nil
            lastM5InfoSent = nil
            sendM5ControllerInfo()
        case .buttonLong(let key), .buttonLongHandledByHID(let key):
            if key == "b" {
                m5ControllerPage = .mainMenu
                m5HAActionMessage = nil
                lastM5InfoSent = nil
                sendM5ControllerInfo()
                status = "M5 控制器：已返回设备列表"
            } else {
                executeM5HACommand(direction: nil, controller: controller, config: config)
            }
        case .shake(let direction):
            executeM5HACommand(direction: direction, controller: controller, config: config)
        case .clearInput:
            return
        case .mediaGesture:
            return
        case .pointerRecenter, .hidState:
            return
        case .buttonUp, .buttonUpHandledByHID:
            return
        }
    }

    private func executeM5HACommand(direction: Int?, controller: ManagedDevice,
                                    config: M5ControllerDeviceSettings) {
        guard !m5HAActionInFlight else { return }
        let ids = config.homeAssistantEntityIDs ?? []
        guard ids.indices.contains(m5HASelectionIndex) else {
            m5HAActionMessage = "未配置控制实体"
            lastM5InfoSent = nil
            sendM5ControllerInfo()
            return
        }
        let entityID = ids[m5HASelectionIndex]
        guard let entity = haSnapshot.entities.first(where: { $0.entityId == entityID }) else {
            m5HAActionMessage = "实体离线或尚未刷新"
            lastM5InfoSent = nil
            sendM5ControllerInfo()
            Task { @MainActor [weak self] in await self?.refreshM5HAControlEntities() }
            return
        }
        let command = direction.map { M5HAControlPolicy.directionalCommand(for: entity,
                                                                            direction: $0) }
            ?? M5HAControlPolicy.primaryCommand(for: entity)
        guard let command else {
            m5HAActionMessage = direction == nil ? "此实体暂不支持控制" : "此实体不支持摇晃操作"
            lastM5InfoSent = nil
            sendM5ControllerInfo()
            return
        }
        m5HAActionInFlight = true
        m5HAActionMessage = "正在执行…"
        lastM5InfoSent = nil
        sendM5ControllerInfo()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.m5HAActionInFlight = false }
            do {
                try await HomeAssistantClient.callService(
                    serverURL: self.settings.haServerURL, token: self.settings.haToken,
                    command: command)
                try? await Task.sleep(nanoseconds: 250_000_000)
                let updated = try await HomeAssistantClient.fetchState(
                    serverURL: self.settings.haServerURL, token: self.settings.haToken,
                    entityID: entityID)
                var entities = self.haSnapshot.entities
                if let index = entities.firstIndex(where: { $0.entityId == entityID }) {
                    entities[index] = updated
                } else {
                    entities.append(updated)
                }
                self.applyHASnapshot(entities: entities, errorText: nil, sampledAt: Date())
                self.m5HAActionMessage = "已执行 · \(updated.displayValue)"
                self.status = "Home Assistant：已控制「\(updated.displayName)」"
            } catch {
                self.m5HAActionMessage = "执行失败"
                self.status = "Home Assistant 控制失败：\(error.localizedDescription)"
            }
            self.lastM5InfoSent = nil
            self.sendM5ControllerInfo()
        }
    }

    private func refreshM5HAControlEntities() async {
        guard let controller = settings.activeDevice(for: .m5Controller),
              let config = controller.settings.m5Controller else { return }
        let ids = config.homeAssistantEntityIDs ?? []
        guard !ids.isEmpty, !settings.haServerURL.isEmpty else {
            lastM5InfoSent = nil
            sendM5ControllerInfo()
            return
        }
        do {
            let updated = try await HomeAssistantClient.fetchStates(
                serverURL: settings.haServerURL, token: settings.haToken, entityIDs: ids)
            var entities = haSnapshot.entities
            for entity in updated {
                if let index = entities.firstIndex(where: { $0.entityId == entity.entityId }) {
                    entities[index] = entity
                } else {
                    entities.append(entity)
                }
            }
            applyHASnapshot(entities: entities, errorText: nil, sampledAt: Date())
            m5HASelectionIndex = min(m5HASelectionIndex, max(0, ids.count - 1))
            m5HAActionMessage = nil
        } catch {
            m5HAActionMessage = "状态刷新失败"
        }
        lastM5InfoSent = nil
        sendM5ControllerInfo()
    }

    private func m5PageTarget(_ target: ManagedDevice, direction: Int) {
        let forward = direction > 0
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch target.type {
            case .keyboard:
                self.switchDevice(type: .keyboard, to: target.id)
                self.status = "M5 控制器：键盘\(forward ? "下一张" : "上一张")卡片"
                self.keyboardPage(direction: direction)
            case .oracle:
                self.switchDevice(type: .oracle, to: target.id)
                self.status = "M5 控制器：口袋先知切换\(forward ? "下一" : "上一")块画板"
                _ = self.cycleOracleCanvasBoard(direction: direction)
                await self.pushOracleCanvas()
            case .excerpt:
                self.switchDevice(type: .excerpt, to: target.id)
                if forward {
                    self.status = "M5 控制器：摘录内容下一条"
                    await self.dotNextContent()
                } else {
                    self.status = "M5 控制器：推送摘录画板"
                    await self.pushExcerptCanvas()
                }
            case .aiMacScreen, .c6Screen:
                self.status = "M5 控制器：AI Mac \(forward ? "下一张" : "上一张")卡片"
                self.aiMacPageCard(deviceID: target.id, direction: direction)
            case .awtrix:
                self.switchDevice(type: .awtrix, to: target.id)
                self.status = "M5 控制器：AWTRIX \(forward ? "下一" : "上一")个应用"
                await self.moveAWTRIXApp(next: forward, deviceID: target.id)
            default:
                return
            }
            self.sendM5ControllerInfo()
        }
    }

    public func aiMacPageCard(deviceID: UUID, direction: Int) {
        let config = aiMacScreenSettings(for: deviceID)
        if settings.devices.first(where: { $0.id == deviceID })?.type == .c6Screen {
            let cards = c6CardList(for: deviceID)
            guard !cards.isEmpty else { return }
            let current = cards.firstIndex { $0.id == selectedC6Card(for: deviceID)?.id } ?? -1
            let offset = config.mode == .card ? direction : 1
            let index = ((current + offset) % cards.count + cards.count) % cards.count
            activateC6Card(cards[index], deviceID: deviceID)
            return
        }
        let modes = aiMacCardList(for: deviceID)
        guard !modes.isEmpty else { return }
        guard config.mode == .card else {
            mutateAIMacScreenSettings(deviceID, pushImmediately: true) { $0.mode = .card }
            aiMacScreenLastCardRotation[deviceID] = Date()
            return
        }
        let count = modes.count
        let current = modes.firstIndex(of: config.cardMode) ?? -1
        let next = modes[((current + direction) % count + count) % count]
        mutateAIMacScreenSettings(deviceID, pushImmediately: true) {
            $0.mode = .card
            $0.c6NativeCardID = nil
            $0.cardMode = next
        }
        aiMacScreenLastCardRotation[deviceID] = Date()
    }

    public func aiMacRotationBinding(deviceID: UUID) -> Binding<Bool> {
        Binding(get: { self.aiMacScreenSettings(for: deviceID).rotate180 }, set: { value in
            if self.settings.devices.first(where: { $0.id == deviceID })?.type == .c6Screen {
                let host = self.aiMacScreenSettings(for: deviceID).host
                Task { @MainActor in
                    do {
                        let client = try C6StandaloneClient(host: host)
                        var token = self.c6Tokens[deviceID] ?? C6SecretStore.read(deviceID: deviceID)
                        if token.isEmpty { token = try await client.connectLAN(); self.authorizeC6Sync(deviceID: deviceID, token: token) }
                        for attempt in 0..<2 {
                            var remote = try await client.read(token: token); remote.rotation = value ? 180 : 0
                            guard self.isCurrentColorScreenTarget(deviceID, host: AIMacScreenSupport.normalizedHost(host)) else { return }
                            do { _ = try await client.save(remote, token: token); break }
                            catch C6StandaloneError.conflict where attempt == 0 { continue }
                        }
                        guard self.isCurrentColorScreenTarget(deviceID, host: AIMacScreenSupport.normalizedHost(host)) else { return }
                        self.mutateAIMacScreenSettings(deviceID, pushImmediately: true) { $0.rotate180 = value }
                    } catch { self.aiMacScreenStatuses[deviceID] = "屏幕方向未保存：\(error.localizedDescription)" }
                }
                return
            }
            self.mutateAIMacScreenSettings(deviceID, pushImmediately: true) { $0.rotate180 = value }
        })
    }

    /// This C6-only choice changes the LCD boundary, never the pushed pixels.
    public func c6DisplayRotationBinding(deviceID: UUID) -> Binding<Int> {
        Binding(get: {
            self.c6SyncedConfigurations[deviceID]?.rotation ?? (self.aiMacScreenSettings(for: deviceID).rotate180 ? 180 : 0)
        }, set: { angle in
            guard [0, 90, 180, 270].contains(angle), self.settings.devices.first(where: { $0.id == deviceID })?.type == .c6Screen else { return }
            let host = self.aiMacScreenSettings(for: deviceID).host
            Task { @MainActor in
                do {
                    let client = try C6StandaloneClient(host: host)
                    var token = self.c6Tokens[deviceID] ?? C6SecretStore.read(deviceID: deviceID)
                    if token.isEmpty { token = try await client.connectLAN(); self.authorizeC6Sync(deviceID: deviceID, token: token) }
                    for attempt in 0..<2 {
                        var remote = try await client.read(token: token); remote.rotation = angle
                        try await client.ensureSupports(remote, token: token)
                        guard self.isCurrentColorScreenTarget(deviceID, host: AIMacScreenSupport.normalizedHost(host)) else { return }
                        do {
                            let saved = try await client.save(remote, token: token)
                            guard self.isCurrentColorScreenTarget(deviceID, host: AIMacScreenSupport.normalizedHost(host)) else { return }
                            self.didUpdateC6DeviceConfiguration(saved, deviceID: deviceID, host: host)
                            self.mutateAIMacScreenSettings(deviceID, pushImmediately: true) { $0.rotate180 = angle == 180 }
                            break
                        } catch C6StandaloneError.conflict where attempt == 0 { continue }
                    }
                } catch { self.aiMacScreenStatuses[deviceID] = "屏幕方向未保存：\(error.localizedDescription)" }
            }
        })
    }

    private func startAIMacButtonPolling() {
        aiMacButtonTask?.cancel()
        aiMacButtonTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAIMacButtons()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private func pollAIMacButtons() async {
        for id in c6MenuPausedIDs {
            guard let host = c6MenuHosts[id], isCurrentColorScreenTarget(id, host: host) else {
                c6MenuPausedIDs.remove(id); c6MenuHosts[id] = nil; aiMacButtonState[id] = nil
                continue
            }
        }
        for device in enabledColorWiFiScreens {
            guard !c6OfflineSimulationIDs.contains(device.id) else { continue }
            let config = aiMacScreenSettings(for: device.id)
            guard !(aiMacScreensSystemSleeping && config.followSystemSleep),
                  let caps = aiMacScreenCapabilities[device.id],
                  caps.host == AIMacScreenSupport.normalizedHost(config.host),
                  let url = caps.buttonURL else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      !c6OfflineSimulationIDs.contains(device.id),
                      let snapshot = try? JSONDecoder().decode(C6ButtonSnapshot.self, from: data),
                      snapshot.isCompatible(protocol: caps.interactionProtocol, identity: caps.deviceIdentity),
                      settings.devices.contains(where: { $0.id == device.id && $0.isEnabled }),
                      AIMacScreenSupport.normalizedHost(aiMacScreenSettings(for: device.id).host) == caps.host
                else { continue }
                let previous = aiMacButtonState[device.id]
                let now = Date()
                aiMacButtonState[device.id] = (caps.host, snapshot, now)
                let wasPaused = c6MenuPausedIDs.contains(device.id)
                if snapshot.menuActive == true { c6MenuPausedIDs.insert(device.id); c6MenuHosts[device.id] = caps.host }
                else { c6MenuPausedIDs.remove(device.id); c6MenuHosts[device.id] = nil }
                if wasPaused && snapshot.menuActive == false {
                    aiMacScreenLastCardRotation[device.id] = now
                    aiMacScreenLastBoardRotation[device.id] = now
                }
                if device.type == .c6Screen,
                   previous == nil || previous?.host != caps.host || previous?.snapshot.bootID != snapshot.bootID {
                    // Static covers live in device RAM, unlike its saved revision.
                    // A reboot/reconnect must not be deduplicated by the Mac's
                    // successful-upload hash from the preceding session.
                    c6ThumbnailHashes[device.id] = nil; c6ThumbnailAttempts[device.id] = nil
                    scheduleC6ThumbnailSync()
                }
                let refresh = device.type == .c6Screen && snapshot.menuActive != true && (
                    wasPaused || previous == nil || previous?.snapshot.bootID != snapshot.bootID ||
                    previous?.snapshot.viewRevision != snapshot.viewRevision)
                if refresh {
                    aiMacScreenLastHashes[device.id] = nil
                    await pushAIMacScreen(deviceID: device.id, force: true)
                }
                // Baseline on first contact/reboot/reconnect. Never replay stale presses.
                if let previous, previous.host == caps.host, previous.snapshot.bootID == snapshot.bootID,
                   now.timeIntervalSince(previous.time) < 2,
                   snapshot.menuActive != true,
                   snapshot.sequence > previous.snapshot.sequence {
                    aiMacPageCard(deviceID: device.id, direction: 1)
                }
            } catch {
                aiMacButtonState[device.id] = nil
            }
        }
    }

    public func sendM5ControllerInfo() {
        guard let client = m5BLEClient, client.isConnected,
              let controller = settings.activeDevice(for: .m5Controller),
              var config = controller.settings.m5Controller else { return }
        normalizeM5Navigation(config)
        switch m5ControllerPage {
        case .mainMenu:
            let targets = m5ConfiguredTargets(config)
            let enabledShortcutCount = config.resolvedMacShortcuts.filter(\.isEnabled).count
            let vibeCount = config.resolvedMacShortcuts.filter {
                $0.group == .vibeCoding && $0.isEnabled
            }.count
            let menuItems = m5MainMenuItems(config)
            var cards: [M5ControllerInfo.Device] = menuItems.map { item in
                switch item {
                case .vibeCoding:
                    return .init(name: "Vibe Coding", detail: "\(vibeCount) 个可用动作",
                                 available: vibeCount > 0)
                case .devices:
                    return .init(name: "多屏设备", detail: "\(targets.count) 台已配置",
                                 available: true)
                case .homeAssistant:
                    return .init(name: "Home Assistant",
                                 detail: "\(config.homeAssistantEntityIDs?.count ?? 0) 个控制实体",
                                 available: true)
                case .macShortcuts:
                    return .init(name: "Mac 快捷键",
                                 detail: "媒体 + \(enabledShortcutCount - vibeCount) 个动作",
                                 available: true)
                }
            }
            if cards.isEmpty {
                cards = [.init(name: "尚未启用功能", detail: "请在 Mac 软件中勾选",
                               available: false)]
            }
            m5MainSelectionIndex = min(max(m5MainSelectionIndex, 0), cards.count - 1)
            sendM5Payload(client: client, config: config,
                          active: min(max(m5MainSelectionIndex, 0), cards.count - 1),
                          cards: cards, title: "灵犀控制器",
                          footer: "A/B选择 长A进入")
        case .devices:
            let targets = m5ConfiguredTargets(config)
            let liveIDs = targets.map { $0.id.uuidString }
            if liveIDs != config.targetDeviceIDs {
                mutateM5ControllerSettings(controller.id) { $0.targetDeviceIDs = liveIDs }
                config.targetDeviceIDs = liveIDs
                config.clamp()
            }
            var cards = targets.map {
                M5ControllerInfo.Device(name: String($0.name.prefix(32)),
                                        detail: String(m5DeviceDetail($0).prefix(32)),
                                        available: $0.isEnabled)
            }
            if cards.isEmpty {
                cards = [.init(name: "未配置显示设备", detail: "请在 Mac 软件中勾选",
                               available: false)]
            }
            m5DeviceSelectionIndex = min(max(m5DeviceSelectionIndex, 0), cards.count - 1)
            sendM5Payload(client: client, config: config, active: m5DeviceSelectionIndex,
                          cards: cards, title: "多屏设备",
                          footer: "A/B选择 长A确认 长B返回")
        case .homeAssistant:
            sendM5HomeAssistantInfo(client: client, config: config)
        case .mediaControls:
            let mediaCards = M5MediaControlCard.allCases
            let cards = mediaCards.map {
                M5ControllerInfo.Device(name: $0.title, detail: $0.detail, available: true)
            }
            m5MediaSelectionIndex = min(max(m5MediaSelectionIndex, 0), cards.count - 1)
            let selectedCard = mediaCards[m5MediaSelectionIndex]
            sendM5Payload(client: client, config: config,
                          active: m5MediaSelectionIndex, cards: cards,
                          title: "多媒体控制", footer: "左右摇控制 长A执行 长B返回",
                          consumerUsage: selectedCard.holdAction.rawValue,
                          consumerUsageLeft: selectedCard.leftAction.rawValue,
                          consumerUsageRight: selectedCard.rightAction.rawValue)
        case .macShortcuts:
            let shortcutItems = m5ShortcutMenuItems(config)
            let cards = shortcutItems.map { item -> M5ControllerInfo.Device in
                switch item {
                case .mediaControls:
                    return .init(name: "多媒体控制", detail: "2 张组合卡片", available: true)
                case .gyroMouse:
                    return .init(name: "飞鼠指针",
                                 detail: config.resolvedGyroMouseEnabled ? "慢移精准 快甩加速" : "已关闭",
                                 available: config.resolvedGyroMouseEnabled)
                case .presentation:
                    let count = config.resolvedMacShortcuts.filter {
                        $0.group == .presentation && $0.isEnabled
                    }.count
                    return .init(name: M5MacShortcutGroup.presentation.title,
                                 detail: "\(count) 个动作", available: true)
                case .custom:
                    let count = config.resolvedMacShortcuts.filter {
                        $0.group == .custom && $0.isEnabled
                    }.count
                    return .init(name: M5MacShortcutGroup.custom.title,
                                 detail: "\(count) 个动作", available: true)
                }
            }
            m5ShortcutMenuSelectionIndex = min(max(m5ShortcutMenuSelectionIndex, 0),
                                               max(0, cards.count - 1))
            sendM5Payload(client: client, config: config,
                          active: m5ShortcutMenuSelectionIndex, cards: cards,
                          title: "Mac 快捷键", footer: "A/B选择 长A进入 长B返回")
        case .presentation, .vibeCoding, .customShortcuts:
            sendM5ShortcutActionInfo(client: client, config: config)
        case .gyroMouse:
            sendM5Payload(client: client, config: config, active: 0,
                          cards: [.init(name: "飞鼠指针", detail: "电视飞鼠手感 自动居中",
                                        available: true)],
                          title: "飞鼠指针",
                          footer: config.resolvedGyroMouseClutchEnabled
                            ? "A点击 B脱开/恢复 长B返回"
                            : "A左键 B右键 长B返回",
                          gyroMouseActive: true)
        }
    }

    private func sendM5Payload(client: M5ControllerBLEClient,
                               config: M5ControllerDeviceSettings,
                               active: Int, cards: [M5ControllerInfo.Device],
                               title: String, footer: String,
                               hidModifiers: UInt8? = nil,
                               hidKey: UInt8? = nil,
                               hidHold: Bool? = nil,
                               clearInputOnShake: Bool? = nil,
                               consumerUsage: UInt16? = nil,
                               consumerUsageLeft: UInt16? = nil,
                               consumerUsageRight: UInt16? = nil,
                               gyroMouseActive: Bool = false) {
        let mainMenuMask = m5MainMenuItems(config).reduce(UInt8(0)) { mask, item in
            switch item {
            case .vibeCoding: return mask | 0x01
            case .devices: return mask | 0x02
            case .homeAssistant: return mask | 0x04
            case .macShortcuts: return mask | 0x08
            }
        }
        let shortcutMenuMask = m5ShortcutMenuItems(config).reduce(UInt8(0)) { mask, item in
            switch item {
            case .mediaControls: return mask | 0x01
            case .gyroMouse: return mask | 0x02
            case .presentation: return mask | 0x04
            case .custom: return mask | 0x08
            }
        }
        let shortcuts = config.resolvedMacShortcuts.filter(\.isEnabled)
        let info = M5ControllerInfo(
            active: active, devices: cards, title: title, footer: footer,
            buzzer: config.resolvedBuzzerEnabled, hidModifiers: hidModifiers,
            hidKey: hidKey, hidHold: hidHold,
            clearInputOnShake: clearInputOnShake, consumerUsage: consumerUsage,
            consumerUsageLeft: consumerUsageLeft, consumerUsageRight: consumerUsageRight,
            gyroMouseActive: gyroMouseActive,
            gyroMouseSensitivity: config.resolvedGyroMouseSensitivity,
            gyroMouseDeadZone: config.resolvedGyroMouseDeadZone,
            gyroMouseSmoothing: config.resolvedGyroMouseSmoothing,
            gyroMouseInvertX: config.resolvedGyroMouseInvertX,
            gyroMouseInvertY: config.resolvedGyroMouseInvertY,
            gyroMouseClutchEnabled: config.resolvedGyroMouseClutchEnabled,
            gyroMouseRecenterToken: settings.activeDevice(for: .m5Controller)
                .flatMap { m5GyroRecenterTokens[$0.id] },
            mainMenuMask: mainMenuMask,
            shortcutMenuMask: shortcutMenuMask,
            targetDeviceCount: m5ConfiguredTargets(config).count,
            homeAssistantEntityCount: config.homeAssistantEntityIDs?.count ?? 0,
            vibeActionCount: shortcuts.filter { $0.group == .vibeCoding }.count,
            presentationActionCount: shortcuts.filter { $0.group == .presentation }.count,
            customActionCount: shortcuts.filter { $0.group == .custom }.count
        )
        m5ControllerPreviewInfo = info
        guard let data = info.encoded(), data != lastM5InfoSent else { return }
        client.send(info: data)
    }

    private func sendM5ShortcutActionInfo(client: M5ControllerBLEClient,
                                          config: M5ControllerDeviceSettings) {
        guard let group = m5ShortcutGroup(for: m5ControllerPage) else { return }
        let actions = config.resolvedMacShortcuts.filter { $0.group == group && $0.isEnabled }
        var cards = actions.map {
            M5ControllerInfo.Device(name: String($0.name.prefix(32)),
                                    detail: $0.id == "vibe.voice"
                                        ? "按住 A · \($0.shortcut.displayString)"
                                        : $0.shortcut.displayString,
                                    available: true)
        }
        if cards.isEmpty {
            cards = [.init(name: "没有可用快捷键", detail: "请在 Mac 软件中配置",
                           available: false)]
        }
        m5ShortcutActionSelectionIndex = min(max(m5ShortcutActionSelectionIndex, 0),
                                             cards.count - 1)
        if let message = m5ShortcutActionMessage,
           cards.indices.contains(m5ShortcutActionSelectionIndex) {
            cards[m5ShortcutActionSelectionIndex].detail = message
        }
        let voiceInputSelected = actions.indices.contains(m5ShortcutActionSelectionIndex)
            && actions[m5ShortcutActionSelectionIndex].id == "vibe.voice"
        let hidReport = actions.indices.contains(m5ShortcutActionSelectionIndex)
            ? actions[m5ShortcutActionSelectionIndex].shortcut.hidKeyboardReport : nil
        sendM5Payload(client: client, config: config,
                      active: m5ShortcutActionSelectionIndex, cards: cards,
                      title: group.title,
                      footer: voiceInputSelected
                        ? "长按A说话 摇一摇清空 长B返回"
                        : "A/B选择 长A执行 长B返回",
                      hidModifiers: hidReport?.modifiers,
                      hidKey: hidReport?.key,
                      hidHold: voiceInputSelected,
                      clearInputOnShake: voiceInputSelected)
    }

    private func sendM5HomeAssistantInfo(client: M5ControllerBLEClient,
                                         config: M5ControllerDeviceSettings) {
        let ids = config.homeAssistantEntityIDs ?? []
        let byID = Dictionary(uniqueKeysWithValues: haSnapshot.entities.map { ($0.entityId, $0) })
        var payload = ids.map { id -> M5ControllerInfo.Device in
            guard let entity = byID[id] else {
                return .init(name: settings.haEntityAliases[id] ?? id,
                             detail: "离线或尚未刷新", available: false)
            }
            let name = settings.haEntityAliases[id] ?? entity.displayName
            return .init(name: String(name.prefix(32)),
                         detail: String(entity.displayValue.prefix(32)),
                         available: entity.state.lowercased() != "unavailable")
        }
        if payload.isEmpty {
            payload = [.init(name: "未配置控制实体", detail: "请在 Mac 软件中添加",
                             available: false)]
        }
        m5HASelectionIndex = min(max(m5HASelectionIndex, 0), payload.count - 1)
        if let message = m5HAActionMessage, payload.indices.contains(m5HASelectionIndex) {
            payload[m5HASelectionIndex].detail = message
        }
        sendM5Payload(client: client, config: config,
                      active: m5HASelectionIndex, cards: payload,
                      title: "Home Assistant", footer: "A/B选择 长A执行 长B返回")
    }

    private func m5DeviceDetail(_ device: ManagedDevice) -> String {
        switch device.type {
        case .keyboard:
            let mode = settings.activeDeviceID(for: .keyboard) == device.id
                ? settings.displayMode
                : device.settings.displayMode ?? settings.displayMode
            // 打印机卡片不能显示“Bambu Lab 打印机 2”这类内部卡片位名称。
            // 与菜单栏使用同一套稳定映射，始终解析到设备管理中的用户自定义名称。
            return MenuBarNamingPolicy.printerCardTitle(for: mode, devices: settings.devices)
        case .aiMacScreen, .c6Screen:
            let config = aiMacScreenSettings(for: device.id)
            if config.mode == .card {
                return MenuBarNamingPolicy.printerCardTitle(
                    for: config.cardMode, devices: settings.devices)
            }
            if config.mode == .canvas,
               config.canvasBoards.indices.contains(config.canvasBoardIndex) {
                return config.canvasBoards[config.canvasBoardIndex].name
            }
            return config.mode.title
        case .oracle:
            let active = settings.activeDeviceID(for: .oracle) == device.id
            let boards = active ? settings.oracleCanvasBoards
                : device.settings.oracleCanvasBoards ?? []
            let index = active ? settings.oracleCanvasBoardIndex
                : device.settings.oracleCanvasBoardIndex ?? 0
            return boards.indices.contains(index) ? boards[index].name : "画板"
        case .excerpt:
            let active = settings.activeDeviceID(for: .excerpt) == device.id
            let boards = active ? settings.excerptCanvasBoards
                : device.settings.excerptCanvasBoards ?? []
            let index = active ? settings.excerptCanvasBoardIndex
                : device.settings.excerptCanvasBoardIndex ?? 0
            return boards.indices.contains(index) ? boards[index].name : "摘录内容"
        case .awtrix:
            return awtrixSnapshots[device.id]?.device.currentApp ?? "应用"
        default:
            return ""
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
            clearActiveKeyboardSmartRotationReturn()
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
        clearActiveKeyboardSmartRotationReturn()
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
    }

    // MARK: - 模式 / 主题 / 登录自启

    @discardableResult
    private func clearActiveKeyboardSmartRotationReturn() -> Bool {
        guard let id = activeDeviceID(for: .keyboard),
              let index = settings.devices.firstIndex(where: { $0.id == id }) else { return false }
        let changed = settings.devices[index].settings.smartRotationReturnDisplayMode != nil
            || settings.devices[index].settings.smartRotationReturnPrinterDeviceID != nil
        guard changed else { return false }
        settings.devices[index].settings.smartRotationReturnDisplayMode = nil
        settings.devices[index].settings.smartRotationReturnPrinterDeviceID = nil
        return true
    }

    public func setMode(_ mode: DisplayMode, reactivateIfUnchanged: Bool = false) {
        let changed = settings.displayMode != mode
        let clearedSmartReturn = clearActiveKeyboardSmartRotationReturn()
        guard changed || reactivateIfUnchanged || clearedSmartReturn else { return }
        if changed {
            settings.displayMode = mode
            persistSettings()
        } else if clearedSmartReturn {
            persistSettings()
        }
        if changed || reactivateIfUnchanged {
            Task { await activateMode() }
        }
    }

    public func setTheme(_ theme: CardTheme) {
        guard settings.cardTheme != theme else { return }
        settings.cardTheme = theme
        persistSettings()
        renderPreview()
    }

    public func setCardRenderingMode(_ mode: CardRenderingMode) {
        guard settings.cardRenderingMode != mode else { return }
        LiquidGlassCardRenderer.clearCache()
        lastUploadedHash = nil
        aiMacScreenLastHashes = [:]
        aiMacScreenLastPushAt = [:]
        lastPreviewRender = nil
        resetLinkedLyricsScheduling(preserveInFlightTasks: true)
        // onChange 统一完成保存、各设备预览和防抖推送，避免重复生成整张画面。
        settings.cardRenderingMode = mode
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

    /// Menu-only rendering reads cached data and detached configurations. It never
    /// selects a device, samples the system, connects, persists or pushes content.
    func menuBarPreview(for target: MenuBarPreviewTarget) throws -> NSImage? {
        guard let device = MenuBarPresentationPolicy.displayDevices(settings.devices)
            .first(where: { $0.id == target.deviceID }) else { return nil }
        return try autoreleasepool {
            switch target {
            case let .c6Local(id, token):
                // A native preview is the current hardware frame, never a fake
                // software rendition or a command that switches the device.
                guard device.type == .c6Screen,
                      selectedC6Card(for: id)?.id == token,
                      selectedC6Card(for: id)?.nativeCard?.headers == c6NativeCardSelections[id]
                else { return nil }
                return aiMacScreenPreviews[id]
            case let .awtrix(id, name):
                // AWTRIX owns app rendering. Only its actual current frame is available;
                // do not silently switch apps or fetch over the network just to preview.
                guard awtrixSnapshots[id]?.device.currentApp?.caseInsensitiveCompare(name) == .orderedSame else { return nil }
                return awtrixLivePreviewImages[id]
            case let .card(id, mode) where device.type == .keyboard:
                guard keyboardCardList(for: id).contains(where: { $0.displayMode == mode }) else { return nil }
                if activeDeviceID(for: .keyboard) == id, settings.displayMode == mode,
                   let previewImage { return previewImage }
                let copy = try MenuBarPresentationPolicy.previewSettings(from: settings, device: device)
                copy.displayMode = mode
                let result = try LiquidGlassCardRenderer.renderKeyboard(settings: copy) {
                    try self.renderCurrentClassic(previewSettings: copy, previewKeyboardID: id)
                }
                return NSImage(data: result.data) ?? NSImage(cgImage: result.image, size: NSSize(width: 142, height: 428))
            case .card where device.type.isColorWiFiScreen, .board where device.type.isColorWiFiScreen:
                var config = aiMacScreenSettings(for: device.id)
                switch target {
                case let .card(_, mode):
                    if device.type == .c6Screen && mode == .aiMacClock {
                        guard let clock = selectedC6Card(for: device.id), clock.nativeCard?.kind == "clock",
                              clock.nativeCard?.headers == c6NativeCardSelections[device.id] else { return nil }
                        return aiMacScreenPreviews[device.id]
                    }
                    guard aiMacCardList(for: device.id).contains(mode) else { return nil }
                    if isCurrentAIMacCard(deviceID: device.id, mode: mode),
                       let cached = aiMacScreenPreviews[device.id] { return cached }
                    config.mode = .card
                    config.c6NativeCardID = nil
                    config.cardMode = mode
                case let .board(_, boardID):
                    guard let index = config.canvasBoards.firstIndex(where: { $0.id == boardID && $0.isSidebarVisible }) else { return nil }
                    if isCurrentAIMacCanvasBoard(deviceID: device.id, boardID: boardID),
                       let cached = aiMacScreenPreviews[device.id] { return cached }
                    config.mode = .canvas
                    config.c6NativeCardID = nil
                    config.canvasBoardIndex = index
                default: return nil
                }
                let image = try renderAIMacScreen(deviceID: device.id, config: config, system: system)
                return NSImage(cgImage: aiMacScreenTransportPreview(image, deviceID: device.id, config: config),
                    size: NSSize(width: 240, height: 240))
            case let .board(_, boardID):
                guard device.type == .oracle || device.type == .excerpt else { return nil }
                let copy = try MenuBarPresentationPolicy.previewSettings(from: settings, device: device)
                let oracle = device.type == .oracle
                if oracle {
                    guard let board = visibleOracleCanvasBoards(for: device.id).first(where: { $0.id == boardID }) else { return nil }
                    if activeDeviceID(for: .oracle) == device.id,
                       isCurrentOracleCanvasBoard(deviceID: device.id, boardID: boardID),
                       let oracleCanvasImage { return oracleCanvasImage }
                    board.apply(to: copy)
                } else {
                    guard let board = visibleExcerptCanvasBoards(for: device.id).first(where: { $0.id == boardID }) else { return nil }
                    if activeDeviceID(for: .excerpt) == device.id,
                       isCurrentExcerptCanvasBoard(deviceID: device.id, boardID: boardID),
                       let excerptCanvasImage { return excerptCanvasImage }
                    board.apply(to: copy)
                }
                let dark = (oracle ? copy.oracleBackgroundMode : copy.excerptBackgroundMode) == .dark
                let palette = ScreenThemes.resolved(theme: copy.cardTheme, backgroundTone: dark ? .dark : .light,
                    customBackgroundHex: nil, accentTone: copy.accentTone,
                    customAccentHex: copy.customAccentHex, softwareIsDark: dark)
                var fields = oracle ? copy.oracleCanvasPrinterFields : copy.excerptCanvasPrinterFields
                for module in CanvasModule.allCases where module.bambuSlotIndex != nil && fields[module.rawValue] == nil {
                    fields[module.rawValue] = .default
                }
                let width = oracle ? ScreenRenderer.oracleCanvasSize : ScreenRenderer.excerptCanvasWidth
                let height = oracle ? ScreenRenderer.oracleCanvasSize : ScreenRenderer.excerptCanvasHeight
                let raw = ScreenRenderer.renderDeviceCanvas(
                    modules: oracle ? copy.oracleCanvasModuleList : copy.excerptCanvasModuleList,
                    system: system, nowPlaying: nowPlaying, pomodoro: pomodoroSnapshot,
                    customText: copy.canvasText, settings: copy, codex: usage, qwenQuota: qwenQuota,
                    sspaiArticles: Array(sspaiArticles.prefix(max(0, min(6, oracle ? copy.oracleSspaiCount : copy.excerptSspaiCount)))),
                    ha: haSnapshot.selecting(entityIDs: oracle ? copy.oracleCanvasHAEntityIDs : copy.excerptCanvasHAEntityIDs),
                    formlabsItems: formlabsCanvasItems(), now: Date(), width: width, height: height, palette: palette,
                    flipVertical: !oracle && copy.excerptImageRotate180,
                    flipHorizontal: !oracle && copy.excerptImageRotate180,
                    columns: oracle ? 1 : copy.excerptLayoutColumns,
                    fullWidthModules: oracle ? [] : Set(copy.excerptFullWidthModules),
                    nowPlayingHorizontal: oracle ? copy.oracleNowPlayingHorizontal : copy.excerptNowPlayingHorizontal,
                    canvasImagePath: oracle ? copy.oracleCanvasImagePath : copy.excerptCanvasImagePath,
                    printerFields: fields, optimizeBambuForOracleEInk: true, bambuHeroLayout: true, showBambuCamera: false)
                let image: CGImage
                if oracle {
                    image = ScreenRenderer.oraclePreviewImage(from: raw, algorithm: copy.oracleGrayAlgorithm,
                        mode: copy.oracleDisplayMode, dither: copy.oracleDitherKernel)
                } else {
                    image = ScreenRenderer.grayscaleCanvasImage(from: raw,
                        algorithm: copy.excerptPushRawImage ? .luminosity : copy.excerptGrayAlgorithm,
                        mode: copy.excerptPushRawImage ? .gray4 : copy.excerptDisplayMode,
                        dither: copy.excerptPushRawImage
                            ? ScreenRenderer.localDitherKernel(for: copy.excerptServerDitherType, kernel: copy.excerptServerDitherKernel)
                            : copy.excerptDitherKernel, width: width, height: height)
                }
                return NSImage(cgImage: image, size: NSSize(width: width, height: height))
            default: return nil
            }
        }
    }

    // MARK: - 渲染

    public func renderBytes() throws -> Data {
        try renderCurrent().data
    }

    private func renderCurrent() throws -> RenderResult {
        try LiquidGlassCardRenderer.renderKeyboard(settings: settings) {
            try self.renderCurrentClassic()
        }
    }

    private func renderCurrentClassic(previewSettings: AppSettings? = nil,
                                      previewKeyboardID: UUID? = nil) throws -> RenderResult {
        let settings = previewSettings ?? self.settings
        // 夸夸卡：完成时间段后的展示窗口内，任何界面都优先显示夸夸内容
        if previewSettings == nil, let text = praiseText, let until = praiseUntil, Date() < until {
            return try ScreenRenderer.renderPraise(text: text,
                                                   sessions: pomodoroSnapshot.completedFocusSessions,
                                                   settings: settings)
        }
        // 打印完成庆祝卡：打印成功后短暂展示 🎉（与夸夸同模式），并显示完成的任务名
        if previewSettings == nil, let name = printSuccessName, let until = printSuccessUntil, Date() < until {
            return try ScreenRenderer.renderPrintSuccess(printerName: name,
                                                         taskName: printSuccessTask,
                                                         picture: printSuccessImage,
                                                         settings: settings)
        }
        // HA 异常告警：监控到异常时优先显示告警卡（打印机名 + 错误码，醒目样式），恢复后自动消失
        if previewSettings == nil, !haAlertTitle.isEmpty {
            return try ScreenRenderer.renderHAAlert(title: haAlertTitle, message: haAlertMessage,
                                                    settings: settings)
        }
        switch settings.displayMode {
        case .pomodoro:
            return try ScreenRenderer.renderPomodoro(pomodoroSnapshot, settings: settings)
        case .weather:
            return try ScreenRenderer.renderCanvas(modules: [.weather], system: system,
                nowPlaying: nowPlaying, pomodoro: pomodoroSnapshot, customText: "", settings: settings)
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
            let snapshot = previewSettings == nil ? haSnapshot : haSnapshot.selecting(
                entityIDs: Self.haCardPerKeyboardEnabled ? settings.haCardEntityIDs : settings.haEntities)
            return try ScreenRenderer.renderHA(snapshot.selectedEntities,
                                               aliases: haSnapshot.aliases,
                                               missing: snapshot.missingRows(),
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
            let keyboardID = previewKeyboardID ?? activeDeviceID(for: .keyboard)
            let linked = keyboardID.map { linkedLyricsKeyboardIDs.contains($0) } ?? false
            let playbackNow = nowPlaying.anchored(at: Date())
            let lyrics = lyricsForKeyboard(keyboardID)?
                .displayWindow(at: playbackNow.elapsedTime)
            return try ScreenRenderer.renderNowPlaying(playbackNow, settings: settings,
                                                       artworkImage: artwork, lyrics: lyrics,
                                                       lyricsOnly: linked)
        case .codex:
            return try ScreenRenderer.renderUsage(usage, settings: settings)
        case .canvas:
            return try ScreenRenderer.renderCanvas(
                modules: settings.canvasModuleList, system: system,
                nowPlaying: nowPlaying, pomodoro: pomodoroSnapshot,
                customText: settings.canvasText, settings: settings,
                codex: usage, qwenQuota: qwenQuota,
                sspaiArticles: sspaiDisplayArticles(for: .keyboard),
                ha: previewSettings == nil ? haSnapshot(forCanvas: .keyboard)
                    : haSnapshot.selecting(entityIDs: settings.canvasHAEntityIDs),
                formlabsItems: formlabsCanvasItems(),
                artworkImage: cachedArtworkImage(for: nowPlaying.artwork))
        case .aiMacClock:
            // 若损坏的旧设置把专属模式写到键盘，安全回退为系统监控画面。
            return try ScreenRenderer.renderSystem(system, history: monitor.networkHistory,
                                                   settings: settings)
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
        updateKeyboardPreview(from: result)
        return result
    }

    /// 软件预览以最终 JPEG 字节为唯一来源，和键盘收到的上传体完全一致。
    /// 编码前 CGImage 只作为极端解码失败时的安全回退，不参与正常预览。
    private func updateKeyboardPreview(from result: RenderResult) {
        let uploadedImage: CGImage?
        if let source = CGImageSourceCreateWithData(result.data as CFData, nil) {
            uploadedImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            uploadedImage = nil
        }
        let image = uploadedImage ?? result.image
        previewImage = NSImage(cgImage: image, size: NSSize(width: 142, height: 428))
        lastPreviewRender = Date()
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
        scheduleC6ConfigurationSync()
    }

    public func c6AutomaticSyncBinding(for id: UUID) -> Binding<Bool> {
        Binding(get: { self.settings.devices.first { $0.id == id }?.settings.c6AutomaticSync ?? true },
                set: { value in
            self.mutateDeviceSettings(id) { $0.c6AutomaticSync = value }
            if !value { self.c6SyncTasks.removeValue(forKey: id)?.cancel(); self.c6SyncRequests[id] = nil }
            else {
                self.c6SyncLastCheck[id] = nil; self.c6SyncedInputs[id] = nil; self.c6AttemptInputs[id] = nil
                self.scheduleC6ConfigurationSync()
            }
        })
    }

    public func setC6OfflineSimulation(deviceID id: UUID, enabled: Bool) async {
        guard !c6OfflineSimulationBusyIDs.contains(id),
              settings.devices.contains(where: { $0.id == id && $0.type == .c6Screen && $0.isEnabled }) else { return }
        let host = aiMacScreenSettings(for: id).host
        c6OfflineSimulationBusyIDs.insert(id)
        defer { c6OfflineSimulationBusyIDs.remove(id) }
        do {
            // Serialize mode changes after any in-flight renewal. A cancelled
            // URL request may already have reached the device; awaiting it makes
            // the stop command the final request before permitting software frames.
            await c6HeartbeatTask?.value
            guard isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)) else { return }
            // Finish the latest selected entities/printers before disconnecting.
            if enabled {
                scheduleC6ConfigurationSync()
                await c6SyncTasks[id]?.value
                if let remote = c6SyncedConfigurations[id] {
                    let covers = remote.printers.filter { $0.enabled && $0.sourceHA && $0.showImage }
                        .flatMap { [$0.imageEntity, $0.taskCoverEntity] }
                        + HAEntityPicker.pictureEntityIDs(in: remote.ha.entities.map(\.id))
                    if !covers.isEmpty {
                        await refreshHAPictures(entities: haSnapshot.entities, wantedIDs: covers)
                    }
                }
                scheduleC6ThumbnailSync()
                // Complete one best-effort, timeout-bounded cached-cover upload
                // before pausing software traffic. Cover failures don't prevent
                // standalone status/weather operation.
                await c6ThumbnailTasks[id]?.value
            }
            guard isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)) else { return }
            if enabled, let current = settings.devices.first(where: { $0.id == id }),
               current.settings.c6AutomaticSync ?? true {
                guard c6SyncedHosts[id] == host,
                      c6SyncedInputs[id] == c6SyncInput(for: current).key else {
                    throw NSError(domain: "C6Simulation", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        "最新显示配置尚未同步成功，请先检查同步状态后重试，以免测试设备旧配置。"])
                }
            }
            let token = c6Tokens[id] ?? C6SecretStore.read(deviceID: id)
            let client = try C6StandaloneClient(host: host)
            if enabled {
                let remote = try await client.read(token: token)
                guard remote.enabled else {
                    throw NSError(domain: "C6Simulation", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先同步设置，并启用电脑离线时独立运行。"])
                }
                guard isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)) else { return }
                c6SyncTasks.removeValue(forKey: id)?.cancel(); c6SyncRequests[id] = nil
                c6ThumbnailTasks.removeValue(forKey: id)?.cancel()
                c6ThumbnailRequests[id] = nil
                c6PendingForcedPushIDs.remove(id)
                c6OfflineSimulationHosts[id] = host; c6OfflineSimulationIDs.insert(id)
                aiMacScreenPreviews[id] = nil
                aiMacButtonState[id] = nil
                aiMacScreenStatuses[id] = "正在交回设备本地运行…"
                do { try await client.simulateSoftwareOffline(true, token: token) }
                catch {
                    // A timed-out response may already have been applied by the device.
                    try? await client.simulateSoftwareOffline(false, token: token)
                    throw error
                }
                guard isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)),
                      c6OfflineSimulationHosts[id] == host else { return }
                c6HeartbeatAt = nil
                aiMacScreenStatuses[id] = "模拟软件离线 · 设备独立订阅与轮转"
                c6SyncStatuses[id] = "模拟离线中 · 电脑配置同步已暂停"
                await refreshC6OfflinePreview(deviceID: id)
            } else {
                // Stop the remote control lease before allowing a fresh Mac frame.
                try await client.simulateSoftwareOffline(false, token: token)
                guard isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)) else { return }
                c6OfflineSimulationIDs.remove(id); c6OfflineSimulationHosts[id] = nil
                aiMacButtonState[id] = nil; aiMacScreenLastHashes[id] = nil
                aiMacScreenLastClockSyncAt[id] = nil; c6HeartbeatAt = nil
                c6SyncLastCheck[id] = nil
                scheduleC6ConfigurationSync()
                await pushAIMacScreen(deviceID: id, force: true)
            }
        } catch {
            guard isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)) else { return }
            if enabled {
                c6OfflineSimulationIDs.remove(id); c6OfflineSimulationHosts[id] = nil
                scheduleC6ConfigurationSync()
                Task { @MainActor [weak self] in await self?.pushAIMacScreen(deviceID: id, force: true) }
            }
            aiMacScreenStatuses[id] = "\(enabled ? "无法开始" : "无法结束")离线模拟：\(error.localizedDescription)"
        }
    }

    public func refreshC6OfflinePreview(deviceID id: UUID) async {
        guard c6OfflineSimulationIDs.contains(id), let host = c6OfflineSimulationHosts[id],
              isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)) else { return }
        do {
            let token = c6Tokens[id] ?? C6SecretStore.read(deviceID: id)
            let bytes = try await C6StandaloneClient(host: host).previewFrame(token: token)
            guard !Task.isCancelled, c6OfflineSimulationIDs.contains(id), c6OfflineSimulationHosts[id] == host,
                  isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)),
                  let image = AIMacScreenSupport.decodeRGB565(bytes) else { return }
            aiMacScreenPreviews[id] = NSImage(cgImage: image, size: NSSize(width: 240, height: 240))
            aiMacScreenStatuses[id] = "模拟软件离线 · 设备独立订阅与轮转"
        } catch {
            guard c6OfflineSimulationIDs.contains(id), c6OfflineSimulationHosts[id] == host else { return }
            aiMacScreenStatuses[id] = "设备离线预览不可用：\(error.localizedDescription)"
        }
    }

    /// View changes reuse a successful LAN connection without system prompts.
    public func c6SessionAuthorization(deviceID: UUID) -> String {
        c6Tokens[deviceID] ?? ""
    }

    public func authorizeC6Sync(deviceID: UUID, token: String) {
        guard !token.isEmpty else { return }
        // Keep the live LAN session even if private local persistence fails.
        if C6SecretStore.save(token, deviceID: deviceID) {
            c6SessionOnlyAuthorizationIDs.remove(deviceID)
        } else {
            c6SessionOnlyAuthorizationIDs.insert(deviceID)
        }
        c6Tokens[deviceID] = token
        c6SyncLastCheck[deviceID] = nil; c6SyncedInputs[deviceID] = nil
        c6ThumbnailHashes[deviceID] = nil; c6ThumbnailAttempts[deviceID] = nil
        scheduleC6ConfigurationSync()
    }

    @discardableResult
    public func invalidateC6Authorization(deviceID: UUID, host: String, token: String) -> Bool {
        guard isCurrentColorScreenTarget(deviceID, host: AIMacScreenSupport.normalizedHost(host)),
              (c6Tokens[deviceID] ?? C6SecretStore.read(deviceID: deviceID)) == token else { return false }
        c6Tokens[deviceID] = ""
        _ = C6SecretStore.save("", deviceID: deviceID)
        c6SessionOnlyAuthorizationIDs.remove(deviceID)
        c6SyncedInputs[deviceID] = nil
        c6SyncStatuses[deviceID] = "设备连接已更新，将自动重新连接局域网设备。"
        return true
    }

    private func c6Selection(for device: ManagedDevice) -> C6StandaloneConfiguration {
        let screen = aiMacScreenSettings(for: device.id)
        let modes = aiMacCardList(for: device.id)
        let boards = screen.canvasBoards.filter(\.isSidebarVisible)
        let modules = boards.flatMap(\.moduleList)
        var selection = C6StandaloneConfiguration()
        selection.enabled = true; selection.diagnostics = false
        selection.clock = screen.mode == .clock || modes.contains(.aiMacClock)
        selection.clockStyle = screen.c6ClockStyle ?? .flip
        selection.rotation = screen.rotate180 ? 180 : 0
        selection.brightness = screen.awakeBrightness ?? 80
        selection.saturationPercent = screen.saturationPercent
        selection.contrastPercent = screen.contrastPercent
        let dark: Bool
        if screen.mode == .canvas, screen.canvasBoards.indices.contains(screen.canvasBoardIndex) {
            dark = screen.canvasBoards[screen.canvasBoardIndex].backgroundMode == .dark
        } else {
            dark = settings.softwareIsDark
        }
        let palette = ScreenThemes.resolved(theme: settings.cardTheme,
            backgroundTone: dark ? .dark : .light, customBackgroundHex: nil,
            accentTone: settings.accentTone, customAccentHex: settings.customAccentHex,
            softwareIsDark: dark)
        func rgb24(_ color: (CGFloat, CGFloat, CGFloat)) -> Int {
            let values = [color.0, color.1, color.2].map { Int((min(1, max(0, $0)) * 255).rounded()) }
            return (values[0] << 16) | (values[1] << 8) | values[2]
        }
        selection.theme = C6RenderTheme(enabled: true, dark: dark,
            background: rgb24(palette.background), card: rgb24(palette.card),
            inset: rgb24(palette.inset), border: rgb24(palette.border),
            accent: rgb24(palette.accent), secondaryAccent: rgb24(palette.secondaryAccent),
            primaryText: rgb24(palette.primaryText), secondaryText: rgb24(palette.secondaryText),
            tertiaryText: rgb24(palette.tertiaryText))
        selection.interval = min(300, max(5, screen.cardRotationMinutes * 60))
        var ids = modes.contains(.homeAssistant) ? aiMacHAEntityIDs(for: device.id) : []
        for board in boards where board.moduleList.contains(.homeAssistant) {
            ids = HAEntityListEditor.merge(ids, adding: board.haEntityIDs)
        }
        selection.ha.entities = ids.map { id in
            C6HAEntity(id: id, name: settings.haEntityAliases[id] ?? haSnapshot.entities.first { $0.entityId == id }?.displayName ?? id)
        }
        let wanted = Set(modes.compactMap(\.bambuSlotIndex) + modules.compactMap(\.bambuSlotIndex))
        for (index, printer) in enabledDevices(for: .bambuLab).enumerated() where wanted.contains(index) {
            let fields = BambuLabCardSettings.from(printer)
            var p = C6PrinterConfiguration()
            p.name = printer.name; p.serial = printer.id.uuidString.replacingOccurrences(of: "-", with: "")
            p.showStatus = fields.showStatus; p.showProgress = fields.showProgress
            p.showTask = fields.showTask; p.showRemaining = fields.showRemaining
            p.showImage = fields.showImage
            p.showNozzle = fields.showTemperature && !fields.nozzleTempEntityID.isEmpty
            p.showBed = fields.showTemperature && !fields.bedTempEntityID.isEmpty
            p.showError = fields.showError && !fields.errorEntityID.isEmpty
            p.timeMode = fields.timeDisplayMode == .endTime ? 1 : 0
            p.brandAccent = fields.themeAccent == .bambuLab
            if !modes.contains(where: { $0.bambuSlotIndex == index }),
               let board = boards.first(where: { $0.moduleList.contains(where: { $0.bambuSlotIndex == index }) }),
               let module = board.moduleList.first(where: { $0.bambuSlotIndex == index }),
               let f = board.printerFields[module.rawValue] {
                p.showStatus = f.showStatus; p.showProgress = f.showProgress; p.showTask = f.showTask; p.showRemaining = f.showRemaining
                p.showImage = f.showImage
                p.showNozzle = f.showNozzleTemp && !fields.nozzleTempEntityID.isEmpty
                p.showBed = f.showBedTemp && !fields.bedTempEntityID.isEmpty
                p.showError = f.showError && !fields.errorEntityID.isEmpty
            }
            if printer.settings.bambuDataSource == .localMQTT {
                let mqtt = printer.settings.bambuMQTT ?? BambuMQTTSettings()
                p.host = mqtt.host; p.serial = mqtt.serial
                p.certificate = mqtt.certificateSHA256.isEmpty ? "" : (mqtt.certificatePEM ?? "")
            } else {
                p.sourceHA = true; p.statusEntity = fields.statusEntityID
                p.progressEntity = fields.progressEntityID; p.taskEntity = fields.taskEntityID
                p.remainingEntity = fields.remainingEntityID
                p.nozzleEntity = fields.nozzleTempEntityID
                p.bedEntity = fields.bedTempEntityID
                p.errorEntity = fields.errorEntityID
                p.endTimeEntity = fields.endTimeEntityID
                let imageID = fields.imageEntityID
                p.imageEntity = imageID.hasPrefix("image.") || imageID.hasPrefix("camera.") ? imageID : ""
                p.liveImage = !p.imageEntity.isEmpty
                p.taskCoverEntity = fields.taskImageEntityID.hasPrefix("image.") ? fields.taskImageEntityID : ""
            }
            selection.printers.append(p)
        }
        let wantedForms = Set(modes.compactMap(\.formlabsSlotIndex) + modules.compactMap(\.formlabsSlotIndex))
        for (index, printer) in enabledDevices(for: .formlabs).enumerated() where wantedForms.contains(index) {
            let fields = printer.settings.formlabsConnection ?? FormlabsConnectionSettings()
            var p = C6PrinterConfiguration()
            p.sourceFormlabs = true; p.serial = fields.printerSerial
            p.formClientID = fields.clientID; p.name = printer.name
            p.showImage = fields.showThumbnail; p.showLayers = fields.showLayers
            p.showMaterial = fields.showMaterial; p.brandAccent = fields.useBrandAccent
            if !modes.contains(where: { $0.formlabsSlotIndex == index }),
               let board = boards.first(where: { $0.moduleList.contains(where: { $0.formlabsSlotIndex == index }) }),
               let module = board.moduleList.first(where: { $0.formlabsSlotIndex == index }),
               let f = board.printerFields[module.rawValue] {
                p.showStatus = f.showStatus; p.showProgress = f.showProgress
                p.showTask = f.showTask; p.showRemaining = f.showRemaining; p.showImage = f.showImage
            }
            selection.printers.append(p)
        }
        selection.ha.enabled = !selection.ha.entities.isEmpty || selection.printers.contains(where: \.sourceHA)
        if let endpoint = C6ConfigurationSync.homeAssistantEndpoint(c6HomeAssistantConnection?.url ?? "") {
            selection.ha.host = endpoint.host; selection.ha.tls = endpoint.tls
            selection.ha.port = endpoint.port
        }
        selection.weather = modes.contains(.weather) || modules.contains(.weather)
        selection.latitude = settings.weather.latitude; selection.longitude = settings.weather.longitude
        selection.weatherCity = settings.weather.city; selection.weatherMinutes = settings.weather.refreshMinutes
        // With no offline-capable content selected, keep one useful fallback rather than blanking the screen.
        if !selection.clock && !selection.ha.enabled && selection.printers.isEmpty && !selection.weather { selection.clock = true }
        return selection
    }

    private func c6SyncInput(for device: ManagedDevice) -> (selection: C6StandaloneConfiguration, credentials: C6Credentials, key: String) {
        let selection = c6Selection(for: device)
        var credentials = C6Credentials()
        credentials.haToken = selection.ha.enabled ? (c6HomeAssistantConnection?.token ?? "") : ""
        for printer in enabledDevices(for: .formlabs) {
            let fields = printer.settings.formlabsConnection ?? FormlabsConnectionSettings()
            if selection.printers.contains(where: { $0.sourceFormlabs && $0.serial == fields.printerSerial && $0.formClientID == fields.clientID }) {
                if let p = selection.printers.first(where: { $0.sourceFormlabs && $0.serial == fields.printerSerial && $0.formClientID == fields.clientID }) {
                    credentials.formClientSecrets[p.credentialKey] = fields.clientSecret
                }
            }
        }
        for printer in enabledDevices(for: .bambuLab) where printer.settings.bambuDataSource == .localMQTT
            && selection.printers.contains(where: { !$0.sourceHA && !$0.sourceFormlabs && $0.serial == printer.settings.bambuMQTT?.serial && $0.host == printer.settings.bambuMQTT?.host }) {
            if let p = selection.printers.first(where: { !$0.sourceHA && !$0.sourceFormlabs && $0.serial == printer.settings.bambuMQTT?.serial && $0.host == printer.settings.bambuMQTT?.host }) {
                credentials.printerAccessCodes[p.credentialKey] = BambuMQTTSecretStore.read(deviceID: printer.id)
            }
        }
        var encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(selection)) ?? Data()
        let secretBytes = (try? JSONSerialization.data(withJSONObject: credentials.printerAccessCodes, options: [.sortedKeys])) ?? Data()
        let host = aiMacScreenSettings(for: device.id).host
        let token = c6Tokens[device.id] ?? C6SecretStore.read(deviceID: device.id)
        let formSecretBytes = (try? JSONSerialization.data(withJSONObject: credentials.formClientSecrets, options: [.sortedKeys])) ?? Data()
        let key = Self.sha256(bytes + secretBytes + formSecretBytes + Data((host + token + credentials.haToken + c6CurrentPictureOrigin).utf8))
        return (selection, credentials, key)
    }

    private func scheduleC6ConfigurationSync(periodic: Bool = false) {
        guard backgroundServicesEnabled, !c6PreparingForQuit else { return }
        for device in enabledDevices(for: .c6Screen) {
            let automaticSync = device.settings.c6AutomaticSync ?? true
            let id = device.id, host = aiMacScreenSettings(for: device.id).host
            guard !c6OfflineSimulationIDs.contains(id) else { continue }
            let due = c6SyncLastCheck[id].map { Date().timeIntervalSince($0) >= 60 } ?? true
            if periodic && (!due || c6SyncTasks[id] != nil) { continue }
            if c6Tokens[id] == nil { c6Tokens[id] = C6SecretStore.read(deviceID: id) }
            let token = c6Tokens[id] ?? ""
            guard !token.isEmpty else {
                guard c6SyncTasks[id] == nil, due else { continue }
                let requestID = "lan|" + host
                c6SyncRequests[id] = requestID
                c6SyncStatuses[id] = "正在连接局域网设备…"
                c6SyncTasks[id] = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { if self.c6SyncRequests[id] == requestID { self.c6SyncRequests[id] = nil; self.c6SyncTasks[id] = nil } }
                    do {
                        let session = try await C6StandaloneClient(host: host).connectLAN()
                        guard !Task.isCancelled, !self.c6PreparingForQuit,
                              self.isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)),
                              !self.c6OfflineSimulationIDs.contains(id), self.c6SyncRequests[id] == requestID else { return }
                        self.c6SyncTasks[id] = nil; self.c6SyncRequests[id] = nil
                        self.authorizeC6Sync(deviceID: id, token: session)
                    } catch {
                        guard !Task.isCancelled, self.isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)) else { return }
                        self.c6SyncLastCheck[id] = Date()
                        self.c6SyncStatuses[id] = "局域网连接未完成：请检查设备网络；旧固件需先 USB 更新。"
                    }
                }
                continue
            }
            let (selection, credentials, inputKey) = c6SyncInput(for: device)
            let key = automaticSync ? inputKey : "read|" + host
            let pictureOrigin = c6CurrentPictureOrigin
            if c6AttemptInputs[id] == key && !due { continue }
            guard c6SyncRequests[id] != key, key != c6SyncedInputs[id] || (periodic && due) else { continue }
            let previous = c6SyncTasks[id]; previous?.cancel()
            c6SyncRequests[id] = key
            c6SyncTasks[id] = Task { @MainActor [weak self] in
                await previous?.value
                do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.c6SyncLastCheck[id] = Date(); self.c6AttemptInputs[id] = key; self.c6SyncStatuses[id] = "正在同步显示设置…"
                defer { if self.c6SyncRequests[id] == key { self.c6SyncRequests[id] = nil; self.c6SyncTasks[id] = nil } }
                do {
                    let client = try C6StandaloneClient(host: host)
                    guard !Task.isCancelled, self.isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)) else { return }
                    var remote = try await client.read(token: token)
                    guard !Task.isCancelled, self.c6SyncRequests[id] == key,
                          self.isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)) else { return }
                    let previousRemote = self.c6SyncedConfigurations[id]
                    self.didUpdateC6DeviceConfiguration(remote, deviceID: id, host: host)
                    let checkpoint = self.aiMacScreenSettings(for: id)
                    let appliesSelection = automaticSync && C6ConfigurationSync.shouldApplySelection(inputKey: key,
                        lastSyncedInputKey: self.c6SyncedInputs[id] ?? checkpoint.c6LastSyncedInputKey)
                    var resolvedCheckpoint: C6StandaloneConfiguration?
                    var authorizesMediaOrigin = false
                    if appliesSelection {
                        guard selection.ha.entities.count <= 6, selection.printers.count <= 3 else {
                            throw NSError(domain: "C6Sync", code: 1, userInfo: [NSLocalizedDescriptionKey: "C6 独立运行目前最多 6 个实体、3 台打印机；未覆盖设备原配置，请减少选择后重试"])
                        }
                        if selection.weather && !self.settings.weather.isValid { throw C6StandaloneError.invalidConfiguration }
                        var resolved = selection
                        var resolvedCredentials = credentials
                        if resolved.ha.enabled {
                            guard !resolved.ha.host.isEmpty else {
                                throw NSError(domain: "C6Sync", code: 3, userInfo: [NSLocalizedDescriptionKey: "请先在设备管理中填写 Home Assistant 服务器与长期令牌；C6 会自动复用，无需重复输入"])
                            }
                            resolved.ha.host = try await C6ConfigurationSync.localIPv4(resolved.ha.host)
                        }
                        for i in resolved.printers.indices where !resolved.printers[i].sourceHA && !resolved.printers[i].sourceFormlabs {
                            let enteredKey = resolved.printers[i].credentialKey
                            resolved.printers[i].host = try await C6ConfigurationSync.localIPv4(resolved.printers[i].host)
                            if let secret = resolvedCredentials.printerAccessCodes.removeValue(forKey: enteredKey) {
                                resolvedCredentials.printerAccessCodes[resolved.printers[i].credentialKey] = secret
                            }
                            guard !resolved.printers[i].certificate.isEmpty else {
                                throw NSError(domain: "C6Sync", code: 2, userInfo: [NSLocalizedDescriptionKey: "请先在打印机设备管理中连接并确认 TLS 证书，再同步本地 MQTT"])
                            }
                        }
                        resolvedCheckpoint = resolved
                        let delta = C6ConfigurationSync.changedSelection(resolved, since: checkpoint.c6LastSyncedSelection)
                        if delta.ha.enabled && resolvedCredentials.haToken.isEmpty {
                            throw NSError(domain: "C6Sync", code: 3, userInfo: [NSLocalizedDescriptionKey:
                                "请先在设备管理中填写 Home Assistant 长期令牌；设备已有的本地配置不会被覆盖。"])
                        }
                        if !delta.ha.enabled { resolvedCredentials.haToken = "" }
                        for attempt in 0..<2 {
                            guard !C6ConfigurationSync.hasHomeAssistantOriginConflict(selection: delta, remote: remote) else {
                                throw NSError(domain: "C6Sync", code: 4, userInfo: [NSLocalizedDescriptionKey:
                                    "设备已配置另一 Home Assistant 来源；原配置已保留，请在本地设置中确认来源后再同步。"])
                            }
                            guard !C6ConfigurationSync.hasPrinterOriginConflict(selection: delta, remote: remote) else {
                                throw NSError(domain: "C6Sync", code: 6, userInfo: [NSLocalizedDescriptionKey:
                                    "同一打印机在设备与电脑中使用了不同来源或云端账号；设备原配置已保留，请确认来源后再同步。"])
                            }
                            let desired = C6ConfigurationSync.applyingChanges(resolved, since: checkpoint.c6LastSyncedSelection, into: remote)
                            // Re-evaluate after every conflict read. An unchanged
                            // source removed/replaced in the web UI must not receive
                            // credentials from a previous attempt's allowlist.
                            let permittedPrinters = delta.printers + resolved.printers.filter { selected in
                                remote.printers.contains { C6ConfigurationSync.mediaSourceMatches($0, selected: selected) }
                            }
                            let permittedKeys = Set(permittedPrinters.map(\.credentialKey))
                            var attemptCredentials = resolvedCredentials
                            attemptCredentials.printerAccessCodes = attemptCredentials.printerAccessCodes.filter { permittedKeys.contains($0.key) }
                            attemptCredentials.formClientSecrets = attemptCredentials.formClientSecrets.filter { permittedKeys.contains($0.key) }
                            guard desired.ha.entities.count <= 6, desired.printers.count <= 3 else {
                                throw NSError(domain: "C6Sync", code: 5, userInfo: [NSLocalizedDescriptionKey:
                                    "合并后超出 C6 的 6 个实体或 3 台打印机限制；原配置已保留，请调整本地或电脑卡片选择。"])
                            }
                            guard !Task.isCancelled, self.c6SyncRequests[id] == key,
                                  !self.c6OfflineSimulationIDs.contains(id),
                                  self.isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)),
                                  self.settings.devices.contains(where: { $0.id == id && $0.isEnabled && ($0.settings.c6AutomaticSync ?? true) }) else { return }
                            do {
                                remote = try await client.save(desired, token: token, credentials: attemptCredentials)
                                authorizesMediaOrigin = !attemptCredentials.haToken.isEmpty
                                    && C6ConfigurationSync.canAuthorizeMediaOrigin(selection: resolved, current: remote)
                                break
                            }
                            catch C6StandaloneError.conflict where attempt == 0 { remote = try await client.read(token: token) }
                        }
                    }
                    guard !Task.isCancelled, self.c6SyncRequests[id] == key,
                          !self.c6OfflineSimulationIDs.contains(id),
                          self.isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)),
                          self.settings.devices.contains(where: { $0.id == id && $0.isEnabled }) else { return }
                    let retainsMediaOrigin = C6ConfigurationSync.canRetainMediaOrigin(
                        previous: previousRemote, current: remote,
                        originMatches: self.c6SyncedPictureOrigins[id] == pictureOrigin)
                    self.c6SyncedInputs[id] = key
                    self.c6SyncedConfigurations[id] = remote
                    self.c6SyncedHosts[id] = host
                    if let resolvedCheckpoint {
                        self.mutateAIMacScreenSettings(id, schedulePush: false) {
                            $0.c6LastSyncedInputKey = key
                            $0.c6LastSyncedSelection = resolvedCheckpoint
                        }
                    }
                    if authorizesMediaOrigin || retainsMediaOrigin {
                        self.c6SyncedPictureOrigins[id] = pictureOrigin
                    } else {
                        // A changed web-side server invalidates desktop media
                        // authorization until a deliberate content sync restores it.
                        self.c6SyncedPictureOrigins[id] = nil
                        self.c6ThumbnailTasks.removeValue(forKey: id)?.cancel()
                        self.c6ThumbnailRequests[id] = nil; self.c6ThumbnailHashes[id] = nil
                        self.c6ThumbnailAttempts[id] = nil
                    }
                    self.scheduleC6ThumbnailSync()
                    let resultLabel = appliesSelection ? "已同步到设备" : "已读取设备配置"
                    self.c6SyncStatuses[id] = "\(resultLabel) · \(remote.ha.entities.count) 个实体 / \(remote.printers.count) 台打印机\(remote.weather ? " / 天气" : "")"
                } catch {
                    guard !Task.isCancelled else { return }
                    if error as? C6StandaloneError == .unauthorized,
                       self.invalidateC6Authorization(deviceID: id, host: host, token: token) { return }
                    let needsInput: Bool
                    if let issue = error as? C6StandaloneError {
                        switch issue {
                        case .address, .invalidConfiguration, .unsupported, .upgradeRequired, .unauthorized, .configurationSave: needsInput = true
                        default: needsInput = false
                        }
                    } else { needsInput = (error as NSError).domain == "C6Sync" }
                    self.c6SyncStatuses[id] = "尚未同步：\(error.localizedDescription)" + (needsInput ? "" : "；设备联网后自动重试")
                }
            }
        }
    }

    private struct C6MediaUpload {
        var serial = "", entityID = "", taskEntity = "", cacheKey = ""
        var brand = "", source = ""
        var cover = false
        var formDeviceID: UUID?
        var formClientID = ""
        var taskKey = "", hash = ""
        var data = Data()
    }

    private func c6MediaPrinterKey(_ p: C6PrinterConfiguration) -> String? {
        if let task = haSnapshot.entities.first(where: { $0.entityId == p.taskEntity }),
           let key = C6TaskThumbnail.homeAssistantTaskKey(task.state) { return key }
        return C6TaskThumbnail.taskKey(source: "snapshot", value: p.imageEntity.isEmpty ? p.taskCoverEntity : p.imageEntity)
    }

    private func c6MediaUploadIsCurrent(_ upload: C6MediaUpload, deviceID: UUID,
                                      configuration: C6StandaloneConfiguration) -> Bool {
        if !upload.serial.isEmpty {
            guard let screen = settings.devices.first(where: { $0.id == deviceID && $0.isEnabled && $0.type == .c6Screen }),
                  let printer = configuration.printers.first(where: {
                      $0.serial == upload.serial && $0.brand == upload.brand && $0.source == upload.source
                  }), c6Selection(for: screen).printers.contains(where: {
                      C6ConfigurationSync.mediaSourceMatches(printer, selected: $0)
                  }) else { return false }
        }
        if let id = upload.formDeviceID {
            guard let printer = settings.devices.first(where: { $0.id == id && $0.isEnabled && $0.type == .formlabs }),
                  printer.settings.formlabsConnection?.printerSerial == upload.serial,
                  printer.settings.formlabsConnection?.clientID == upload.formClientID,
                  let print = formlabsSnapshots[id]?.print else { return false }
            return C6TaskThumbnail.formlabsTaskKey(runID: print.runID, name: print.name) == upload.taskKey
        }
        if upload.serial.isEmpty { return C6TaskThumbnail.taskKey(source: "entity", value: upload.entityID) == upload.taskKey }
        if let task = haSnapshot.entities.first(where: { $0.entityId == upload.taskEntity }),
           let key = C6TaskThumbnail.homeAssistantTaskKey(task.state) { return key == upload.taskKey }
        return upload.taskKey == C6TaskThumbnail.taskKey(source: "snapshot", value: upload.cacheKey.components(separatedBy: "|").last ?? "")
    }

    private func scheduleC6ThumbnailSync() {
        guard backgroundServicesEnabled, !c6PreparingForQuit else { return }
        for device in enabledDevices(for: .c6Screen) {
            let id = device.id, host = aiMacScreenSettings(for: id).host
            let pictureOrigin = c6CurrentPictureOrigin
            guard !c6OfflineSimulationIDs.contains(id), c6ThumbnailTasks[id] == nil,
                  let remote = c6SyncedConfigurations[id], c6SyncedHosts[id] == host,
                  c6SyncedPictureOrigins[id] == pictureOrigin,
                  c6ThumbnailAttempts[id].map({ Date().timeIntervalSince($0) >= 15 }) ?? true else { continue }
            var uploads: [C6MediaUpload] = []
            func append(_ value: C6MediaUpload) {
                var u = value
                // Firmware has a four-frame LRU pool. Refresh acknowledged cache
                // entries occasionally so eviction doesn't permanently suppress
                // a still-current picture supplied by the Mac.
                let cacheLease = Int(Date().timeIntervalSince1970 / 120)
                u.hash = "\(remote.revision)|\(u.taskKey)|\(u.cacheKey)|\(cacheLease)|" + Self.sha256(u.data)
                if c6ThumbnailHashes[id]?[u.cacheKey] != u.hash { uploads.append(u) }
            }
            let selectedPrinters = c6Selection(for: device).printers
            for p in remote.printers where p.enabled && p.showImage
                && selectedPrinters.contains(where: { C6ConfigurationSync.mediaSourceMatches(p, selected: $0) }) {
                if p.sourceFormlabs {
                    guard let device = enabledDevices(for: .formlabs).first(where: {
                        $0.settings.formlabsConnection?.printerSerial == p.serial
                            && $0.settings.formlabsConnection?.clientID == p.formClientID
                    }), let snapshot = formlabsSnapshots[device.id], let print = snapshot.print,
                       let taskKey = C6TaskThumbnail.formlabsTaskKey(runID: print.runID, name: print.name),
                       let data = snapshot.thumbnail else { continue }
                    append(C6MediaUpload(serial: p.serial, cacheKey: p.credentialKey + "|formlabs", brand: p.brand, source: p.source,
                        formDeviceID: device.id, formClientID: p.formClientID, taskKey: taskKey, data: data))
                } else if p.sourceHA, let key = c6MediaPrinterKey(p) {
                    for (entity, cover) in [(p.imageEntity, false), (p.taskCoverEntity, true)] {
                        guard entity.hasPrefix("image.") || entity.hasPrefix("camera."),
                              c6PictureOrigins[entity] == pictureOrigin,
                              let data = haSnapshot.picture(for: entity) else { continue }
                        if let raw = haSnapshot.entities.first(where: { $0.entityId == p.taskEntity }),
                           C6TaskThumbnail.homeAssistantTaskKey(raw.state) != nil,
                           c6PictureTaskKeys[entity]?[p.taskEntity] != key { continue }
                        let fallbackEntity = p.imageEntity.isEmpty ? p.taskCoverEntity : p.imageEntity
                        append(C6MediaUpload(serial: p.serial, taskEntity: p.taskEntity,
                            cacheKey: p.credentialKey + (cover ? "|cover|" : "|image|") + fallbackEntity, brand: p.brand, source: p.source,
                            cover: cover, taskKey: key, data: data))
                    }
                }
            }
            if remote.ha.enabled {
                for e in remote.ha.entities where e.id.hasPrefix("camera.") || e.id.hasPrefix("image.") {
                    guard c6PictureOrigins[e.id] == pictureOrigin, let data = haSnapshot.picture(for: e.id),
                          let key = C6TaskThumbnail.taskKey(source: "entity", value: e.id) else { continue }
                    append(C6MediaUpload(entityID: e.id, cacheKey: "entity|" + e.id, taskKey: key, data: data))
                }
            }
            guard !uploads.isEmpty else { continue }
            c6ThumbnailAttempts[id] = Date()
            let token = c6Tokens[id] ?? C6SecretStore.read(deviceID: id)
            let requestID = UUID(); c6ThumbnailRequests[id] = requestID
            c6ThumbnailTasks[id] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { if self.c6ThumbnailRequests[id] == requestID { self.c6ThumbnailTasks[id] = nil; self.c6ThumbnailRequests[id] = nil } }
                for upload in uploads {
                    guard !Task.isCancelled, !self.c6OfflineSimulationIDs.contains(id),
                          self.c6ThumbnailRequests[id] == requestID,
                          self.c6SyncedPictureOrigins[id] == pictureOrigin, self.c6CurrentPictureOrigin == pictureOrigin,
                          self.isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)),
                          self.c6SyncedConfigurations[id]?.revision == remote.revision,
                          self.c6MediaUploadIsCurrent(upload, deviceID: id, configuration: remote),
                          let small = C6TaskThumbnail.encodeMedia(from: upload.data) else { continue }
                    do {
                        try await C6StandaloneClient(host: host).uploadMedia(small, serial: upload.serial,
                            entityID: upload.entityID, brand: upload.brand, source: upload.source, cover: upload.cover,
                            taskKey: upload.taskKey, revision: remote.revision, token: token)
                        guard !Task.isCancelled, !self.c6OfflineSimulationIDs.contains(id),
                              self.c6ThumbnailRequests[id] == requestID,
                              self.c6SyncedConfigurations[id]?.revision == remote.revision,
                              self.c6MediaUploadIsCurrent(upload, deviceID: id, configuration: remote),
                              self.isCurrentColorScreenTarget(id, host: AIMacScreenSupport.normalizedHost(host)) else { return }
                        self.c6ThumbnailHashes[id, default: [:]][upload.cacheKey] = upload.hash
                    } catch {
                        // Cache failure cannot block state subscriptions or replace another task.
                        // The device retries independently; a full visible-page pool is bounded.
                    }
                }
            }
        }
    }

    private func refreshWeatherIfDue(now: Date) {
        guard settings.weather.isValid, !weatherBusy else { return }
        let key = "\(settings.weather.latitude),\(settings.weather.longitude),\(settings.weather.city)"
        if key != weatherLocationKey {
            weatherLocationKey = key; weatherLastAttempt = nil
            if settings.weatherSnapshot?.matches(settings.weather) != true { settings.weatherSnapshot = nil }
        }
        let elapsed = weatherLastAttempt.map { now.timeIntervalSince($0) } ?? .infinity
        let cachedElapsed = settings.weatherSnapshot.map { now.timeIntervalSince($0.updatedAt) } ?? .infinity
        guard elapsed >= 300, cachedElapsed >= Double(settings.weather.refreshMinutes * 60) else { return }
        Task { @MainActor [weak self] in await self?.refreshWeather() }
    }

    public func refreshWeather() async {
        guard !weatherBusy, settings.weather.isValid else { return }
        let request = settings.weather; weatherBusy = true; weatherLastAttempt = Date()
        defer { weatherBusy = false }
        do {
            let snapshot = try await WeatherClient.fetch(request)
            guard request == settings.weather else { return }
            settings.weatherSnapshot = snapshot; weatherStatus = "已更新 · Open-Meteo"
            renderPreview(); enabledColorWiFiScreens.forEach { refreshAIMacScreenPreview(deviceID: $0.id) }
        } catch { weatherStatus = "天气更新失败，保留最近缓存；稍后重试" }
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
