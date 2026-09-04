import Combine
import Foundation

/// 应用设置。属性变更时通过 onChange 回调通知持久化。
public final class AppSettings: ObservableObject {
    /// 键盘推送地址（设备管理添加键盘时按 IP 自动补全 http://<IP>/image/upload；默认为空）
    @Published public var endpoint = "" {
        didSet { onChange() }
    }
    /// 用量数据统一刷新周期（秒）：Codex 用量与千问办公额度一次并行调取，供所有功能共享
    @Published public var codexRefreshSeconds = 300 {
        didSet { onChange() }
    }
    /// 少数派推荐卡片刷新周期（分钟）
    @Published public var sspaiRefreshMinutes = 30 {
        didSet { onChange() }
    }
    /// 少数派推荐：文章多于三条时，进入该页随机推送三条到键盘
    @Published public var sspaiRandomPush = false {
        didSet { onChange() }
    }
    @Published public var dynamicUploadSeconds = 5 {
        didSet { onChange() }
    }
    @Published public var safeAreaHeight = 56 {
        didSet { onChange() }
    }
    /// 键盘卡片 JPEG 质量（50–100；100 = 4:4:4 无彩色抽样，画质接近无损）
    @Published public var jpegQuality = 100 {
        didSet { onChange() }
    }
    /// 千问办公额度百分比基线：用户手动抓取的「100%」额度值（持久化；之后按 当前/基线 算剩余百分比）
    @Published public var qwenQuotaBaseline: Double? {
        didSet { onChange() }
    }
    /// 千问办公额度基线的采样日（yyyy-MM-dd，本地时区）：跨天后自动以当天额度重新采样基线
    @Published public var qwenQuotaBaselineDay: String? {
        didSet { onChange() }
    }
    @Published public var displayMode: DisplayMode = .codex {
        didSet { onChange() }
    }
    @Published public var cardTheme: CardTheme = .deepSpace {
        didSet { onChange() }
    }
    @Published public var customImagePath: String? {
        didSet { onChange() }
    }
    @Published public var customImageName: String? {
        didSet { onChange() }
    }
    /// 口袋先知画板图像模块自己的图片（与键盘自定义图片解耦，按设备独立）
    @Published public var oracleCanvasImagePath: String? {
        didSet { onChange() }
    }
    @Published public var oracleCanvasImageName: String? {
        didSet { onChange() }
    }
    /// 摘录画板图像模块自己的图片（与键盘自定义图片解耦，按设备独立）
    @Published public var excerptCanvasImagePath: String? {
        didSet { onChange() }
    }
    @Published public var excerptCanvasImageName: String? {
        didSet { onChange() }
    }
    /// 最近使用的自定义图片（最多 9 条，最新在前）
    @Published public var customImageHistory: [RecentImage] = [] {
        didSet { onChange() }
    }
    @Published public var startWithSystem = false {
        didSet { onChange() }
    }
    @Published public var codexCliPath: String? {
        didSet { onChange() }
    }
    @Published public var appearanceMode: AppearanceMode = .system {
        didSet { onChange() }
    }
    /// 软件当前有效的明暗状态（由 AppModel 依据外观模式 + 系统外观实时更新，不持久化）。
    /// 背景底色「跟随软件明暗」时以此决定深/浅底色。
    @Published public var softwareIsDark = true {
        didSet { onChange() }
    }
    /// 侧边栏宽度（像素，48–320）
    @Published public var sidebarWidth = 168 {
        didSet { onChange() }
    }
    @Published public var backgroundTone: BackgroundTone = .system {
        didSet { onChange() }
    }
    @Published public var customBackgroundHex: String? {
        didSet { onChange() }
    }
    @Published public var accentTone: AccentTone = .system {
        didSet { onChange() }
    }
    @Published public var customAccentHex: String? {
        didSet { onChange() }
    }
    // 系统监控分类显示开关
    @Published public var showCpu = true {
        didSet { onChange() }
    }
    @Published public var showMemory = true {
        didSet { onChange() }
    }
    @Published public var showNetwork = true {
        didSet { onChange() }
    }
    @Published public var showUptime = true {
        didSet { onChange() }
    }
    @Published public var showDisk = false {
        didSet { onChange() }
    }
    /// 网络板块显示方式：false = 数字速率，true = 折线图
    @Published public var networkChart = false {
        didSet { onChange() }
    }
    // 最近图片定时轮换
    @Published public var imageRotationEnabled = false {
        didSet { onChange() }
    }
    @Published public var imageRotationSeconds = 30 {
        didSet { onChange() }
    }
    @Published public var imageRotationMode: ImageRotationMode = .sequential {
        didSet { onChange() }
    }
    /// 自定义图片上的时钟叠加布局（不叠加时不额外刷新）
    @Published public var customImageClock: CustomImageClockOverlay = .none {
        didSet { onChange() }
    }
    /// 壁纸种子色生成时钟前景色的 Material 动态配色风格。
    @Published public var wallpaperColorStyle: WallpaperColorStyle = .natural {
        didSet { onChange() }
    }
    /// 是否在 Pixel 叠排时钟下方显示日期（按键盘设备独立保存）。
    @Published public var clockDateVisible = true {
        didSet { onChange() }
    }
    /// Pixel 叠排时钟整体图层组尺寸（32–42；四位数字、间距、日期同步缩放）。
    @Published public var clockFontSize = StackedClockSizing.defaultValue {
        didSet { onChange() }
    }
    /// 叠加时钟字体粗细（Pixel 锁屏风格，默认中粗）
    @Published public var clockFontWeight: ClockFontWeight = .medium {
        didSet { onChange() }
    }
    /// 叠加时钟字体家族（默认 Helvetica Neue，Pixel 锁屏风格）
    @Published public var clockFont: ClockFont = .helveticaNeue {
        didSet { onChange() }
    }
    /// Pixel 叠排时钟图层组水平偏移（px，正值向右）
    @Published public var clockOffsetX = 0 {
        didSet { onChange() }
    }
    /// 时钟叠加垂直偏移（px，正值向下）
    @Published public var clockOffsetY = 0 {
        didSet { onChange() }
    }
    /// 时钟时间格式（DateFormatter 模式，如 HH:mm / hh:mm / HH:mm:ss）
    /// 全局时间格式（DateFormatter 模式）：软件内所有时间显示统一使用（时钟卡片、画板时钟模块、
    /// 正在播放页脚等），不再按界面单独设置
    @Published public var timeFormat = "HH:mm" {
        didSet { onChange() }
    }
    /// 全局日期格式（DateFormatter 模式）：软件内所有日期显示统一使用
    @Published public var dateFormat = "yyyy年M月d日 EEE" {
        didSet { onChange() }
    }
    /// 旧档案字段：时钟卡片时间格式（已由全局 timeFormat 取代，仅用于读取旧设置）
    @Published public var clockTimeFormat = "HH:mm" {
        didSet { onChange() }
    }
    /// 画板已选模块（CanvasModule.rawValue 有序数组，从上到下排列）
    @Published public var canvasModules: [Int] = [CanvasModule.clock.rawValue] {
        didSet { onChange() }
    }
    /// 画板「自定义文字」模块的内容
    @Published public var canvasText = "LinxDisplay" {
        didSet { onChange() }
    }
    // 画板模块细节设置
    @Published public var canvasClockFormat = "HH:mm" {
        didSet { onChange() }
    }
    @Published public var canvasDateFormat = "yyyy年M月d日 EEE" {
        didSet { onChange() }
    }
    @Published public var canvasNowPlayingCover = false {
        didSet { onChange() }
    }
    /// 键盘画板「智能封面取色背景」开关（整卡背景替换为封面主色；墨水屏画板不使用）
    @Published public var canvasNowPlayingSmartBg = false {
        didSet { onChange() }
    }
    /// 口袋先知画板「正在播放」模块横向排布（封面居左、文字居右；默认竖向大封面）
    @Published public var oracleNowPlayingHorizontal = false {
        didSet { onChange() }
    }
    /// 口袋先知多画板：保存的画板列表（每块画板 = 完整画布配置快照；按键控制目标为自身时上下键循环切换）
    @Published public var oracleCanvasBoards: [OracleCanvasBoard] = [] {
        didSet { onChange() }
    }
    /// 口袋先知多画板：当前画板下标
    @Published public var oracleCanvasBoardIndex = 0 {
        didSet { onChange() }
    }
    /// 摘录画板「正在播放」模块横向排布（封面居左、文字居右；默认竖向大封面）
    @Published public var excerptNowPlayingHorizontal = false {
        didSet { onChange() }
    }
    /// 灵犀画板「少数派推荐」模块显示条数（1–6）
    @Published public var canvasSspaiCount = 2 {
        didSet { onChange() }
    }
    /// 口袋先知画板「少数派推荐」模块显示条数（1–6）
    @Published public var oracleSspaiCount = 3 {
        didSet { onChange() }
    }
    /// 摘录画板「少数派推荐」模块显示条数（1–6）
    @Published public var excerptSspaiCount = 4 {
        didSet { onChange() }
    }
    /// 灵犀画板「少数派推荐」随机显示（文章多于显示条数时随机抽取，刷新后重抽）
    @Published public var canvasSspaiRandom = false {
        didSet { onChange() }
    }
    /// 口袋先知画板「少数派推荐」随机显示
    @Published public var oracleSspaiRandom = false {
        didSet { onChange() }
    }
    /// 摘录画板「少数派推荐」随机显示
    @Published public var excerptSspaiRandom = false {
        didSet { onChange() }
    }
    /// 摘录语录启用的分类（ExcerptQuoteCategory.rawValue 数组，默认全选；
    /// 勾选为空时轮换池回退全部，避免无语录可显示）
    @Published public var excerptQuoteCategories: [Int] = ExcerptQuoteCategory.allCases.map(\.rawValue) {
        didSet { onChange() }
    }
    /// 摘录语录显示出处：开启后在时钟位置显示语录出处并隐藏时钟（无确切出处的语录不显示）
    @Published public var showExcerptSource = false {
        didSet { onChange() }
    }
    /// Emoji 壁纸：用户提供的 emoji 表情串
    @Published public var emojiWallpaperText = "🌈🌟🦄🔥🎵⭐️" {
        didSet { onChange() }
    }
    /// Emoji 壁纸：emoji 基础字号（像素）
    @Published public var emojiWallpaperSize = 48 {
        didSet { onChange() }
    }
    /// Emoji 壁纸：排列方式
    @Published public var emojiWallpaperLayout: EmojiWallpaperLayout = .grid {
        didSet { onChange() }
    }
    /// Emoji 壁纸：表情之间的间隔（像素，0 = 紧贴）
    @Published public var emojiWallpaperSpacing = 8 {
        didSet { onChange() }
    }
    /// 正在播放卡片：歌名字号（键盘「正在播放」卡片，自适应收缩下限 5.5）
    @Published public var nowPlayingTitleSize = 10 {
        didSet { onChange() }
    }
    /// 正在播放卡片：歌手/专辑信息字号
    @Published public var nowPlayingArtistSize = 8 {
        didSet { onChange() }
    }
    /// 正在播放卡片：底部时间/日期是否显示（隐藏时封面居中、歌词/进度条信息贴底）
    @Published public var nowPlayingFooterVisible = true {
        didSet { onChange() }
    }
    /// 正在播放卡片：底部时间格式（DateFormatter 模式）
    @Published public var nowPlayingTimeFormat = "HH:mm" {
        didSet { onChange() }
    }
    /// 正在播放卡片：底部日期格式（DateFormatter 模式）
    @Published public var nowPlayingDateFormat = "M月d日" {
        didSet { onChange() }
    }
    /// 正在播放卡片：底部时间字号
    @Published public var nowPlayingTimeSize = 22 {
        didSet { onChange() }
    }
    /// 正在播放卡片：底部日期字号
    @Published public var nowPlayingDateSize = 17 {
        didSet { onChange() }
    }
    /// 画板「正在播放」模块：歌名字号（键盘/先知/摘录画板共用）
    @Published public var canvasNowPlayingTitleSize = 12 {
        didSet { onChange() }
    }
    /// 画板「正在播放」模块：歌手/专辑信息字号
    @Published public var canvasNowPlayingArtistSize = 9 {
        didSet { onChange() }
    }
    /// 口袋先知画板：底色模式（手动深色/亮色，避免墨水屏长时间黑底；不随软件主题同步）
    @Published public var oracleBackgroundMode: CanvasBackgroundMode = .dark {
        didSet { onChange() }
    }
    /// 摘录画板：推送前是否将画面直接旋转 180°（适配设备安装方向，非镜像翻转）
    @Published public var excerptImageRotate180 = false {
        didSet { onChange() }
    }
    /// 摘录画板：底色模式（手动深色/亮色，避免墨水屏长时间黑底；不随软件主题同步）
    @Published public var excerptBackgroundMode: CanvasBackgroundMode = .dark {
        didSet { onChange() }
    }
    /// 摘录画板：是否直接推送原始画面（灰阶/抖动处理前的彩色原图，设备端自行处理；默认开启）
    @Published public var excerptPushRawImage = true {
        didSet { onChange() }
    }
    /// 摘录画板：推送原始图片时使用的服务端抖动方式（官方 ditherType）
    @Published public var excerptServerDitherType: DotServerDitherType = .diffusion {
        didSet { onChange() }
    }
    /// 摘录画板：推送原始图片时使用的服务端抖动核（官方 ditherKernel）
    @Published public var excerptServerDitherKernel: DotServerDitherKernel = .floydSteinberg {
        didSet { onChange() }
    }
    /// 口袋先知画板：自动推送开关与间隔（分钟）
    @Published public var oracleAutoPushEnabled = false {
        didSet { onChange() }
    }
    @Published public var oracleAutoPushMinutes = 30 {
        didSet { onChange() }
    }
    /// 口袋先知多画板：按保存顺序定时切换到下一块画板并立即推送。
    @Published public var oracleBoardRotationEnabled = false {
        didSet { onChange() }
    }
    @Published public var oracleBoardRotationMinutes = 5 {
        didSet { onChange() }
    }
    /// 摘录画板：自动推送开关与间隔（分钟）
    @Published public var excerptAutoPushEnabled = false {
        didSet { onChange() }
    }
    @Published public var excerptAutoPushMinutes = 30 {
        didSet { onChange() }
    }
    @Published public var canvasImageMode: CanvasImageMode = .background {
        didSet { onChange() }
    }
    /// 画板各模块的上下边距（key=CanvasModule.rawValue，值=紧凑度 0–40，越大模块越矮、排布越紧密）
    @Published public var canvasModuleMargins: [Int: Int] = [:] {
        didSet { onChange() }
    }
    /// 画板打印机模块的显示信息选项（key=CanvasModule.rawValue，每台打印机模块独立配置）
    @Published public var canvasPrinterFields: [Int: CanvasPrinterFields] = [:] {
        didSet { onChange() }
    }
    /// 口袋先知画板打印机模块显示选项（独立镜像：不与键盘画板共用，设备间互不串扰）
    @Published public var oracleCanvasPrinterFields: [Int: CanvasPrinterFields] = [:] {
        didSet { onChange() }
    }
    /// 摘录画板打印机模块显示选项（独立镜像：不与键盘画板共用，设备间互不串扰）
    @Published public var excerptCanvasPrinterFields: [Int: CanvasPrinterFields] = [:] {
        didSet { onChange() }
    }
    /// 画板「千问额度」模块显示方式：true = 百分比为大字（与其他模块一致），false = 额度数值为大字
    @Published public var qwenQuotaShowPercent = true {
        didSet { onChange() }
    }
    /// 番茄钟：每完成一个时间段是否显示夸夸
    @Published public var pomodoroPraiseEnabled = false {
        didSet { onChange() }
    }
    /// 番茄钟：夸夸内容来源
    @Published public var pomodoroPraiseSource: PraiseSource = .builtin {
        didSet { onChange() }
    }
    /// 番茄钟：任务名称字号
    @Published public var pomodoroTaskFontSize = 9 {
        didSet { onChange() }
    }
    /// 番茄钟：全局快捷键（开始/暂停 · 跳过 · 重置），可自定义、可恢复默认
    @Published public var pomodoroToggleShortcut = GlobalShortcut.defaultToggle {
        didSet { onChange() }
    }
    @Published public var pomodoroSkipShortcut = GlobalShortcut.defaultSkip {
        didSet { onChange() }
    }
    @Published public var pomodoroResetShortcut = GlobalShortcut.defaultReset {
        didSet { onChange() }
    }
    /// 灵犀68 手动翻页全局快捷键（作用于「菜单栏切换目标键盘」）。
    @Published public var keyboardPageUpShortcut = GlobalShortcut.defaultPageUp {
        didSet { onChange() }
    }
    @Published public var keyboardPageDownShortcut = GlobalShortcut.defaultPageDown {
        didSet { onChange() }
    }
    /// 使用灵犀68 的 Fn + 旋钮手动翻页；启用时独占该键盘的媒体控制接口并拦截系统音量。
    /// 涉及系统输入行为，必须由用户主动开启，默认关闭。
    @Published public var lingxi68KnobPagingEnabled = false {
        didSet { onChange() }
    }
    /// Home Assistant：服务器地址（全局唯一，所有设备共享；如 http://192.168.x.x:8123）
    @Published public var haServerURL = "" {
        didSet { onChange() }
    }
    /// Home Assistant：长期访问令牌（敏感字段，仅保存在本机 settings.json；日志与测试不打印明文）
    @Published public var haToken = "" {
        didSet { onChange() }
    }
    /// Home Assistant：刷新间隔（分钟，全局唯一）
    @Published public var haRefreshMinutes = 5 {
        didSet { onChange() }
    }
    /// 旧档案字段：单实体选择（现由每台键盘的 haCardEntityIDs 记录，仅用于读取旧设置）
    @Published public var haEntityID = "" {
        didSet { onChange() }
    }
    /// 旧档案字段：全局实体列表（现由每台键盘的 haCardEntityIDs 记录，仅用于读取旧设置）
    @Published public var haEntities: [String] = [] {
        didSet { onChange() }
    }
    /// 当前操作键盘的 Home Assistant 卡片实体列表（镜像；有序=卡片显示顺序）。
    /// 实体池由全局共享服务器拉取一次，但每台键盘卡片展示哪些实体互相独立。
    @Published public var haCardEntityIDs: [String] = [] {
        didSet { onChange() }
    }
    /// 灵犀画板的 Home Assistant 模块实体列表（与 HA 键盘卡片、其他画板互相独立）。
    @Published public var canvasHAEntityIDs: [String] = [] {
        didSet { onChange() }
    }
    /// 口袋先知画板的 Home Assistant 模块实体列表。
    @Published public var oracleCanvasHAEntityIDs: [String] = [] {
        didSet { onChange() }
    }
    /// 摘录画板的 Home Assistant 模块实体列表。
    @Published public var excerptCanvasHAEntityIDs: [String] = [] {
        didSet { onChange() }
    }
    /// Home Assistant：实体自定义显示名称（entity_id → 别名；卡片渲染优先使用）
    @Published public var haEntityAliases: [String: String] = [:] {
        didSet { onChange() }
    }
    /// HA 异常监控：是否开启（检测到异常时推送到键盘告警）
    @Published public var haMonitorEnabled = false {
        didSet { onChange() }
    }
    /// HA 异常监控：被监控的状态实体 entity_id（如打印机状态 sensor；状态 != 期望值即异常）
    @Published public var haMonitorEntityID = "" {
        didSet { onChange() }
    }
    /// HA 异常监控：期望的正常状态值（如 idle/standby；状态 != 该值视为异常；空 = 不做状态判定）
    @Published public var haMonitorExpectedState = "" {
        didSet { onChange() }
    }
    /// HA 异常监控：可选错误码实体 entity_id（其状态非空且非 none 即异常，如打印机错误码）
    @Published public var haMonitorErrorEntityID = "" {
        didSet { onChange() }
    }
    /// Bambu Lab 打印机卡片：报错时推送键盘告警（默认开启）
    @Published public var bambuEnableAlert = true {
        didSet { onChange() }
    }
    /// Bambu Lab 打印机列表（多台打印机独立配置；旧版单台字段迁移为首台）
    @Published public var bambuPrinters: [BambuLabCardSettings] = [] {
        didSet { onChange() }
    }
    /// Bambu Lab 打印机卡片：各字段实体映射（活动 Home Assistant 设备镜像）
    @Published public var bambuStatusEntityID = "" {
        didSet { onChange() }
    }
    @Published public var bambuProgressEntityID = "" {
        didSet { onChange() }
    }
    @Published public var bambuTaskEntityID = "" {
        didSet { onChange() }
    }
    @Published public var bambuNozzleTempEntityID = "" {
        didSet { onChange() }
    }
    @Published public var bambuBedTempEntityID = "" {
        didSet { onChange() }
    }
    @Published public var bambuRemainingEntityID = "" {
        didSet { onChange() }
    }
    @Published public var bambuErrorEntityID = "" {
        didSet { onChange() }
    }
    /// 摄像头实体（活动 Bambu 设备的镜像；保留旧字段名兼容已有配置）
    @Published public var bambuImageEntityID = "" {
        didSet { onChange() }
    }
    /// 打印任务封面实体（活动 Bambu 设备的镜像）
    @Published public var bambuTaskImageEntityID = "" {
        didSet { onChange() }
    }
    /// 卡片当前显示的画面来源（摄像头 / 任务图片）
    @Published public var bambuImageSource: BambuImageSource = .camera {
        didSet { onChange() }
    }
    /// Bambu Lab 打印机名称（活动 Bambu 设备的镜像；设备名独立存储于各设备快照）
    @Published public var bambuPrinterName = "打印机" {
        didSet { onChange() }
    }
    /// Bambu Lab 卡片布局样式（活动 Bambu 设备的镜像）
    @Published public var bambuLayout: BambuCardLayout = .standard {
        didSet { onChange() }
    }
    /// Bambu Lab 卡片主题色（活动 Bambu 设备的镜像）
    @Published public var bambuThemeAccent: BambuThemeAccent = .global {
        didSet { onChange() }
    }
    /// Bambu Lab 卡片各区块显示开关（活动 Bambu 设备的镜像）
    @Published public var bambuShowStatus = true {
        didSet { onChange() }
    }
    @Published public var bambuShowProgress = true {
        didSet { onChange() }
    }
    @Published public var bambuShowTask = true {
        didSet { onChange() }
    }
    @Published public var bambuShowTemperature = true {
        didSet { onChange() }
    }
    @Published public var bambuShowRemaining = true {
        didSet { onChange() }
    }
    @Published public var bambuShowError = true {
        didSet { onChange() }
    }
    /// 画面区块开关（活动 Bambu 设备的镜像；仅在已映射画面实体且拉到图片时渲染）
    @Published public var bambuShowImage = true {
        didSet { onChange() }
    }
    /// 当前活动 Bambu Lab 打印机设备 ID（对应键盘 Bambu Lab 卡片渲染的打印机）
    @Published public var activeBambuLabDeviceID: UUID? {
        didSet { onChange() }
    }

    /// 画板模块列表（过滤无效 rawValue）
    public var canvasModuleList: [CanvasModule] {
        canvasModules.compactMap(CanvasModule.init(rawValue:))
    }

    /// 口袋先知画板模块列表（过滤无效 rawValue）
    public var oracleCanvasModuleList: [CanvasModule] {
        oracleCanvasModules.compactMap(CanvasModule.init(rawValue:))
    }

    /// 摘录画板模块列表（过滤无效 rawValue）
    public var excerptCanvasModuleList: [CanvasModule] {
        excerptCanvasModules.compactMap(CanvasModule.init(rawValue:))
    }

    /// 模块列表清洗：过滤无效 rawValue 并去重（保持顺序）
    private static func cleanModuleList(_ raws: [Int]) -> [Int] {
        let valid = Set(CanvasModule.allCases.map(\.rawValue))
        var cleaned: [Int] = []
        var seen = Set<Int>()
        for raw in raws where valid.contains(raw) && !seen.contains(raw) {
            cleaned.append(raw)
            seen.insert(raw)
        }
        return cleaned
    }

    /// 模块的上下边距（0–40，越大越紧凑）。0 = 自适应调节模式：使用按模块类型的默认边距
    public func canvasMargin(for module: CanvasModule) -> Int {
        // 手动设置过（>0）用手动值；未设置或值为 0 时回落自适应默认边距，
        // 让画板布局默认就合理、用户通常无需手动调节
        if let v = canvasModuleMargins[module.rawValue], v > 0 { return v }
        return defaultCanvasMargin(for: module)
    }

    /// 模块手动设置的边距值（未设置/归零=自适应时为 0，供滑杆显示与判断）
    public func manualCanvasMargin(for module: CanvasModule) -> Int {
        canvasModuleMargins[module.rawValue] ?? 0
    }

    /// 当前活动 Home Assistant 设备的设置快照（无 HA 设备时返回 nil；
    /// 无活动 ID 时回退第一台 HA 设备）
    public func activeHADeviceSettings() -> DeviceSettings? {
        if let id = activeHomeAssistantDeviceID,
           let device = devices.first(where: { $0.id == id }) {
            return device.settings
        }
        return devices.first { $0.type == .homeAssistant }?.settings
    }

    /// 活动 Bambu Lab 打印机设备（无活动 ID 时回退第一台已启用打印机；无打印机返回 nil）
    public func activeBambuLabDevice() -> ManagedDevice? {
        let printers = devices.filter { $0.type == .bambuLab }
        guard !printers.isEmpty else { return nil }
        if let id = activeBambuLabDeviceID,
           let device = printers.first(where: { $0.id == id }) {
            return device
        }
        return printers.first { $0.isEnabled } ?? printers.first
    }

    /// 活动 Bambu Lab 打印机的卡片配置（nil = 未配置任何打印机）
    public func activeBambuLabSettings() -> BambuLabCardSettings? {
        activeBambuLabDevice().map { BambuLabCardSettings.from($0) }
    }

    /// 按卡片位（已启用打印机顺序）取打印机配置：bambuLab→第 1 台、bambuLab2→第 2 台…
    /// 与卡片管理槽位一致；该位无打印机返回 nil
    public func bambuSettings(atSlot slot: Int) -> BambuLabCardSettings? {
        let printers = devices.filter { $0.type == .bambuLab && $0.isEnabled }
        guard printers.indices.contains(slot) else { return nil }
        return BambuLabCardSettings.from(printers[slot])
    }

    /// 旧架构迁移：HA 设备内嵌的打印机配置（bambuPrinters 列表/旧单台字段）→ 独立 DeviceType.bambuLab 设备。
    /// 每台打印机成为一个独立设备（名称与实体映射保留）；已存在 bambuLab 设备时跳过（幂等）。
    /// 返回创建的打印机设备数量。
    @discardableResult
    public func migrateBambuPrintersToDevices() -> Int {
        guard devices.allSatisfy({ $0.type != .bambuLab }) else { return 0 }
        var migrated: [ManagedDevice] = []
        for haDevice in devices where haDevice.type == .homeAssistant {
            var printers = haDevice.settings.bambuPrinters ?? []
            if printers.isEmpty,
               let old = haDevice.settings.bambuStatusEntityID, !old.isEmpty {
                printers = [BambuLabCardSettings.from(haDevice.settings)]
            }
            for printer in printers {
                var settings = DeviceSettings()
                printer.apply(to: &settings)
                let device = ManagedDevice(type: .bambuLab,
                                           name: printer.name.isEmpty ? "打印机 \(migrated.count + 1)" : printer.name,
                                           settings: settings)
                migrated.append(device)
            }
        }
        if !migrated.isEmpty {
            devices.append(contentsOf: migrated)
            activeBambuLabDeviceID = migrated.first?.id
        }
        return migrated.count
    }

    /// 时间/日期格式统一（幂等）：软件内所有时间显示改用全局 timeFormat / dateFormat 后，
    /// 旧档案里被用户改过的分界面格式收拢一次——按「与默认值不同者优先」取时间格式与日期格式，
    /// 其余旧字段保持原样但不再被读取。返回迁移说明（nil = 无需迁移）。
    @discardableResult
    public func migrateTimeDateFormat() -> String? {
        let timeDefaults = ["HH:mm", "HH:mm", "HH:mm"]
        let legacyTimes = [(clockTimeFormat, timeDefaults[0], "时钟卡片"),
                           (canvasClockFormat, timeDefaults[1], "画板时钟"),
                           (nowPlayingTimeFormat, timeDefaults[2], "正在播放页脚")]
        let legacyDates = [(canvasDateFormat, "yyyy年M月d日 EEE", "画板日期"),
                           (nowPlayingDateFormat, "M月d日", "页脚日期")]
        var notes: [String] = []
        if timeFormat == "HH:mm",
           let picked = legacyTimes.first(where: { $0.0 != $0.1 && !$0.0.isEmpty }) {
            timeFormat = picked.0
            notes.append("时间格式采用\(picked.2)设置（\(picked.0)）")
        }
        if dateFormat == "yyyy年M月d日 EEE",
           let picked = legacyDates.first(where: { $0.0 != $0.1 && !$0.0.isEmpty }) {
            dateFormat = picked.0
            notes.append("日期格式采用\(picked.2)设置（\(picked.0)）")
        }
        return notes.isEmpty ? nil : "时间/日期格式已统一：" + notes.joined(separator: "；")
    }

    /// Home Assistant 单服务器收敛（幂等）：把设备快照里的地址/令牌/刷新间隔收归为一份全局配置。
    /// 规则：全局地址为空 → 取活动设备的值；任一设备与全局不一致 → 以活动设备的值写入全局一次，
    /// 其余设备值弃用；两种情况都会清掉设备侧副本（设置文件不再重复存令牌）。
    /// 返回迁移说明（nil = 无需迁移）供启动日志留痕；重复启动是幂等空操作。
    @discardableResult
    public func migrateHAServerToGlobal() -> String? {
        let haOffsets = devices.indices.filter { devices[$0].type == .homeAssistant }
        guard !haOffsets.isEmpty else { return nil }
        // 仍带连接信息的设备（旧档案）
        let carriedOffsets = haOffsets.filter { off in
            !(devices[off].settings.haServerURL ?? "").isEmpty || !(devices[off].settings.haToken ?? "").isEmpty
        }
        guard !carriedOffsets.isEmpty else { return nil }
        let activeID = activeDevice(for: .homeAssistant)?.id
        // 取值来源：优先活动设备（且它确实带了连接信息），否则第一台带信息的设备
        let source = carriedOffsets.first { devices[$0].id == activeID } ?? carriedOffsets.first!
        let sourceURL = (devices[source].settings.haServerURL ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceToken = devices[source].settings.haToken ?? ""
        let sourceRefresh = devices[source].settings.haRefreshMinutes
        var notes: [String] = []
        if haServerURL.isEmpty, !sourceURL.isEmpty {
            haServerURL = sourceURL
            notes.append("全局服务器地址取自设备「\(devices[source].name)」")
        }
        if haToken.isEmpty, !sourceToken.isEmpty {
            haToken = sourceToken
            notes.append("全局令牌取自设备「\(devices[source].name)」")
        }
        let differing = carriedOffsets.filter { off in
            let url = devices[off].settings.haServerURL ?? ""
            let token = devices[off].settings.haToken ?? ""
            return (!url.isEmpty && url != haServerURL) || (!token.isEmpty && token != haToken)
        }
        if !differing.isEmpty, !sourceURL.isEmpty || !sourceToken.isEmpty {
            if !sourceURL.isEmpty { haServerURL = sourceURL }
            if !sourceToken.isEmpty { haToken = sourceToken }
            notes.append("\(differing.count) 台设备与全局服务器不一致，统一采用设备「\(devices[source].name)」的连接配置")
        }
        if let refresh = sourceRefresh, refresh != haRefreshMinutes {
            haRefreshMinutes = min(max(refresh, 1), 60)
            notes.append("刷新间隔采用设备设置（\(haRefreshMinutes) 分钟）")
        }
        for off in haOffsets {
            devices[off].settings.haServerURL = nil
            devices[off].settings.haToken = nil
            devices[off].settings.haRefreshMinutes = nil
        }
        guard !notes.isEmpty else { return nil }
        return "Home Assistant 连接配置已收归全局（所有设备共享）：" + notes.joined(separator: "；")
    }

    /// 旧档案键盘「卡片内容」补齐（幂等：只填设备缺失的字段，绝不覆盖设备已有的值）。
    ///
    /// 根因：早期版本的设备快照里没有卡片列表/卡片内容字段（全为 nil）。切换到这台键盘时，
    /// apply 不会写这些字段 → 全局镜像仍保留上一台键盘的值 → 随后的 syncActiveDeviceSettings
    /// 把上一台键盘的卡片列表与内容写进这台键盘的快照，表现为「改一台键盘的卡片影响另一台」。
    /// 启动时按当前镜像为每台键盘补齐一次缺失字段，此后每台键盘各自记录、互不干扰。
    /// 返回被补齐过字段的键盘台数。
    @discardableResult
    public func migrateKeyboardCardContentSeeds() -> Int {
        let seed = DeviceSettings.capture(from: self, type: .keyboard)
        let boolPaths: [WritableKeyPath<DeviceSettings, Bool?>] = [
            \.cardRotationEnabled, \.networkChart, \.showCpu, \.showMemory, \.showNetwork,
            \.showUptime, \.showDisk, \.pomodoroPraiseEnabled, \.qwenQuotaShowPercent,
            \.showExcerptSource, \.canvasNowPlayingCover, \.canvasNowPlayingSmartBg,
            \.canvasSspaiRandom, \.imageRotationEnabled, \.clockDateVisible,
        ]
        let intPaths: [WritableKeyPath<DeviceSettings, Int?>] = [
            \.safeAreaHeight, \.jpegQuality, \.dynamicUploadSeconds, \.cardRotationMinutes,
            \.canvasNowPlayingTitleSize, \.canvasNowPlayingArtistSize, \.canvasSspaiCount,
            \.nowPlayingTitleSize, \.nowPlayingArtistSize, \.nowPlayingTimeSize, \.nowPlayingDateSize,
            \.clockFontSize, \.clockOffsetX, \.clockOffsetY, \.imageRotationSeconds,
            \.emojiWallpaperSize, \.emojiWallpaperSpacing, \.pomodoroTaskFontSize,
        ]
        let stringPaths: [WritableKeyPath<DeviceSettings, String?>] = [
            \.customImageName, \.canvasText, \.canvasClockFormat, \.canvasDateFormat,
            \.nowPlayingTimeFormat, \.nowPlayingDateFormat,
        ]
        let intArrayPaths: [WritableKeyPath<DeviceSettings, [Int]?>] = [
            \.canvasModules, \.cardRotationModes, \.excerptQuoteCategories,
        ]
        var seeded = 0
        for index in devices.indices where devices[index].type == .keyboard {
            var s = devices[index].settings
            let before = s
            if s.keyboardCardPanels == nil { s.keyboardCardPanels = seed.keyboardCardPanels }
            if s.haCardEntityIDs == nil { s.haCardEntityIDs = seed.haCardEntityIDs }
            if s.canvasHAEntityIDs == nil { s.canvasHAEntityIDs = seed.canvasHAEntityIDs }
            if s.displayMode == nil { s.displayMode = seed.displayMode }
            if s.cardTheme == nil { s.cardTheme = seed.cardTheme }
            if s.pomodoroPraiseSource == nil { s.pomodoroPraiseSource = seed.pomodoroPraiseSource }
            if s.canvasImageMode == nil { s.canvasImageMode = seed.canvasImageMode }
            if s.imageRotationMode == nil { s.imageRotationMode = seed.imageRotationMode }
            if s.customImageClock == nil { s.customImageClock = seed.customImageClock }
            if s.wallpaperColorStyle == nil { s.wallpaperColorStyle = seed.wallpaperColorStyle }
            if s.clockFontWeight == nil { s.clockFontWeight = seed.clockFontWeight }
            if s.clockFont == nil { s.clockFont = seed.clockFont }
            if s.emojiWallpaperLayout == nil { s.emojiWallpaperLayout = seed.emojiWallpaperLayout }
            if s.emojiWallpaperText == nil { s.emojiWallpaperText = seed.emojiWallpaperText }
            if s.customImagePath == nil { s.customImagePath = seed.customImagePath }
            if s.canvasPrinterFields == nil { s.canvasPrinterFields = seed.canvasPrinterFields }
            if s.canvasModuleMargins == nil { s.canvasModuleMargins = seed.canvasModuleMargins }
            for kp in boolPaths where s[keyPath: kp] == nil { s[keyPath: kp] = seed[keyPath: kp] }
            for kp in intPaths where s[keyPath: kp] == nil { s[keyPath: kp] = seed[keyPath: kp] }
            for kp in stringPaths where s[keyPath: kp] == nil { s[keyPath: kp] = seed[keyPath: kp] }
            for kp in intArrayPaths where s[keyPath: kp] == nil { s[keyPath: kp] = seed[keyPath: kp] }
            if s != before {
                devices[index].settings = s
                seeded += 1
            }
        }
        return seeded
    }

    /// 各模块的自适应默认边距：内容厚重/需要呼吸的模块给更大间距，
    /// 纯文字紧凑模块给最小间距；用户手动设置过则覆盖默认值
    public func defaultCanvasMargin(for module: CanvasModule) -> Int {
        switch module {
        case .nowPlaying, .image, .sspai, .oracleText, .excerptText: return 6
        case .pomodoro: return 4
        case .cpu, .memory, .disk, .network, .uptime, .qwenQuota, .codex, .homeAssistant, .bambuLab,
             .bambuLab2, .bambuLab3, .bambuLab4, .bambuLab5: return 4
        case .clock, .date, .text: return 2
        }
    }

    public func setCanvasMargin(_ margin: Int, for module: CanvasModule) {
        let clamped = min(max(margin, 0), 40)
        if clamped == 0 {
            // 0 = 自适应调节模式：移除手动值，回落到该模块的自适应默认边距
            if canvasModuleMargins[module.rawValue] != nil {
                canvasModuleMargins.removeValue(forKey: module.rawValue)
            }
        } else if canvasModuleMargins[module.rawValue] != clamped {
            canvasModuleMargins[module.rawValue] = clamped
        }
    }

    /// 画板打印机模块的显示信息选项（未配置时用默认：状态 + 进度 + 错误）
    public func canvasPrinterFields(for module: CanvasModule) -> CanvasPrinterFields {
        canvasPrinterFields[module.rawValue] ?? .default
    }

    /// 更新画板打印机模块的显示信息选项
    public func setCanvasPrinterFields(_ fields: CanvasPrinterFields, for module: CanvasModule) {
        if canvasPrinterFields[module.rawValue] != fields {
            canvasPrinterFields[module.rawValue] = fields
        }
    }

    /// 卡片页面自动轮换：开关 / 间隔（分钟）/ 参与轮换的显示模式
    @Published public var cardRotationEnabled = false {
        didSet { onChange() }
    }
    @Published public var cardRotationMinutes = 5 {
        didSet { onChange() }
    }
    @Published public var cardRotationModes: [Int] = DisplayMode.allCases.map(\.rawValue) {
        didSet { onChange() }
    }

    /// 参与轮换的显示模式列表（有序；被移除的卡片不在此列，即不参与轮换）
    public var cardRotationModeList: [DisplayMode] {
        cardRotationModes.compactMap(DisplayMode.init(rawValue:))
    }
    /// 侧栏主菜单项排序（Panel.rawValue 数组；空数组 = 默认顺序）
    @Published public var sidebarOrder: [String] = [] {
        didSet { onChange() }
    }
    /// 活动键盘设备的侧栏可见卡片列表镜像（Panel.rawValue 有序；nil = 未配置，设备侧各自存储）
    @Published public var keyboardCardPanels: [String]? {
        didSet { onChange() }
    }
    /// Dot. Open Platform（dot.mindreset.tech）凭据：API Key 与设备序列号，用于推送卡片到 Dot 设备
    @Published public var dotApiKey = "" {
        didSet { onChange() }
    }
    @Published public var dotDeviceId = "" {
        didSet { onChange() }
    }
    /// 口袋先知（Rand/0）设备局域网 IP
    @Published public var rand0IP = "" {
        didSet { onChange() }
    }
    /// 口袋先知按键信号控制的设备（默认控制自身：下键手动更新画布）
    @Published public var rand0ButtonTarget: Rand0ButtonTarget = .oracle {
        didSet { onChange() }
    }
    /// 按键控制目标的具体设备 ID（键盘/摘录类目标时指向某台具体设备；nil = 当前活动设备）
    @Published public var rand0ButtonTargetDeviceID: UUID? {
        didSet { onChange() }
    }
    /// 受管设备列表（每台设备独立记录连接与画布设置；首次运行保持为空并进入添加引导）
    @Published public var devices: [ManagedDevice] = [] {
        didSet { onChange() }
    }
    /// 菜单栏快捷切换的目标键盘设备 ID（nil = 跟随当前活动键盘）
    @Published public var menuBarKeyboardDeviceID: UUID? {
        didSet { onChange() }
    }
    /// 最近一次自动检查 GitHub 更新的时间（节流，避免频繁请求）
    @Published public var lastUpdateCheckAt: Date? {
        didSet { onChange() }
    }
    /// 各类设备当前活动的设备 ID（nil = 使用该类第一台）
    @Published public var activeKeyboardDeviceID: UUID? {
        didSet { onChange() }
    }
    @Published public var activeOracleDeviceID: UUID? {
        didSet { onChange() }
    }
    @Published public var activeHomeAssistantDeviceID: UUID? {
        didSet { onChange() }
    }
    @Published public var activeExcerptDeviceID: UUID? {
        didSet { onChange() }
    }
    /// 口袋先知画板已选模块（CanvasModule.rawValue 有序数组，独立于键盘画板）
    @Published public var oracleCanvasModules: [Int] = [CanvasModule.oracleText.rawValue] {
        didSet { onChange() }
    }
    /// 摘录画板已选模块（CanvasModule.rawValue 有序数组，独立于键盘画板）
    @Published public var excerptCanvasModules: [Int] = [CanvasModule.excerptText.rawValue] {
        didSet { onChange() }
    }
    /// 口袋先知画板：推送前是否将画面直接旋转 180°（适配设备安装方向，非镜像翻转）
    @Published public var oracleImageRotate180 = false {
        didSet { onChange() }
    }
    /// 口袋先知画板：显示模式（1 位黑白 / 4 级灰阶）
    @Published public var oracleDisplayMode: OracleDisplayMode = .bw {
        didSet { onChange() }
    }
    /// 口袋先知画板：灰阶转换算法
    @Published public var oracleGrayAlgorithm: OracleGrayAlgorithm = .luminosity {
        didSet { onChange() }
    }
    /// 口袋先知画板：抖动算法（官方墨水屏 ditherKernel，默认 Floyd-Steinberg）
    @Published public var oracleDitherKernel: OracleDitherKernel = .floydSteinberg {
        didSet { onChange() }
    }
    /// 摘录画板：显示模式（Dot 墨水屏原生 4 级灰阶；可选 1 位黑白）
    @Published public var excerptDisplayMode: OracleDisplayMode = .gray4 {
        didSet { onChange() }
    }
    /// 摘录画板：灰阶转换算法
    @Published public var excerptGrayAlgorithm: OracleGrayAlgorithm = .luminosity {
        didSet { onChange() }
    }
    /// 摘录画板：抖动算法（官方墨水屏 ditherKernel，默认 Floyd-Steinberg）
    @Published public var excerptDitherKernel: OracleDitherKernel = .floydSteinberg {
        didSet { onChange() }
    }
    /// 摘录画板：画布内模块布局列数（1 = 单列纵向堆叠，2 = 双列排列）
    @Published public var excerptLayoutColumns: Int = 1 {
        didSet { onChange() }
    }
    /// 摘录画板双列布局中占满整行（横跨两列）的模块 rawValue 列表
    @Published public var excerptFullWidthModules: [Int] = [] {
        didSet { onChange() }
    }

    /// 设备切换/新增设备进行中：此期间 onChange 不做「镜像→活动设备快照」回写，
    /// 否则新设备快照会在套用前被上一台设备的镜像值整体覆盖（表现为设备间设置串扰）。
    /// 运行期标记，不持久化。
    public var deviceSyncInFlight = false

    /// 任一属性变更后调用（用于触发持久化）。
    public var onChange: () -> Void = {}

    /// 应用到键盘卡片画面的最终调色板（所选主题 + 背景底色/强调色覆盖）
    public var resolvedPalette: ScreenPalette {
        ScreenThemes.resolved(
            theme: cardTheme,
            backgroundTone: backgroundTone,
            customBackgroundHex: customBackgroundHex,
            accentTone: accentTone,
            customAccentHex: customAccentHex,
            softwareIsDark: softwareIsDark)
    }

    public init() {}

    public func clamped() {
        safeAreaHeight = min(max(safeAreaHeight, 44), 80)
        jpegQuality = min(max(jpegQuality, 50), 100)
        dynamicUploadSeconds = min(max(dynamicUploadSeconds, 2), 60)
        imageRotationSeconds = min(max(imageRotationSeconds, Int(RotationInterval.minSeconds)), Int(RotationInterval.maxSeconds))
        clockFontSize = min(max(clockFontSize, StackedClockSizing.minimum),
                            StackedClockSizing.maximum)
        customImageClock = customImageClock.stackedOnly
        clockFontWeight = clockFontWeight.modernized
        clockOffsetX = min(max(clockOffsetX, -60), 60)
        clockOffsetY = min(max(clockOffsetY, StackedClockSizing.minimumYOffset),
                           StackedClockSizing.maximumYOffset)
        pomodoroTaskFontSize = min(max(pomodoroTaskFontSize, 7), 16)
        // 快捷键钳制：键码 0–127、修饰键只保留 ⌘⇧⌥⌃
        pomodoroToggleShortcut = pomodoroToggleShortcut.clamped()
        pomodoroSkipShortcut = pomodoroSkipShortcut.clamped()
        pomodoroResetShortcut = pomodoroResetShortcut.clamped()
        keyboardPageUpShortcut = keyboardPageUpShortcut.clamped()
        keyboardPageDownShortcut = keyboardPageDownShortcut.clamped()
        haRefreshMinutes = min(max(haRefreshMinutes, 1), 60)
        if timeFormat.trimmingCharacters(in: .whitespaces).isEmpty { timeFormat = "HH:mm" }
        if dateFormat.trimmingCharacters(in: .whitespaces).isEmpty { dateFormat = "yyyy年M月d日 EEE" }
        // HA 多实体列表：去空去重，保持顺序（旧全局列表 + 每台键盘自己的卡片列表）
        func cleanEntityList(_ list: [String]) -> [String] {
            var cleaned: [String] = []
            var seen = Set<String>()
            for eid in list where !eid.trimmingCharacters(in: .whitespaces).isEmpty && !seen.contains(eid) {
                cleaned.append(eid)
                seen.insert(eid)
            }
            return cleaned
        }
        haEntities = cleanEntityList(haEntities)
        haCardEntityIDs = cleanEntityList(haCardEntityIDs)
        canvasHAEntityIDs = cleanEntityList(canvasHAEntityIDs)
        oracleCanvasHAEntityIDs = cleanEntityList(oracleCanvasHAEntityIDs)
        excerptCanvasHAEntityIDs = cleanEntityList(excerptCanvasHAEntityIDs)
        nowPlayingTitleSize = min(max(nowPlayingTitleSize, 7), 24)
        nowPlayingArtistSize = min(max(nowPlayingArtistSize, 6), 20)
        nowPlayingTimeSize = min(max(nowPlayingTimeSize, 10), 40)
        nowPlayingDateSize = min(max(nowPlayingDateSize, 8), 30)
        canvasNowPlayingTitleSize = min(max(canvasNowPlayingTitleSize, 7), 24)
        canvasNowPlayingArtistSize = min(max(canvasNowPlayingArtistSize, 6), 20)
        oracleAutoPushMinutes = min(max(oracleAutoPushMinutes, 1), 1440)
        oracleBoardRotationMinutes = min(max(oracleBoardRotationMinutes, 1), 1440)
        excerptAutoPushMinutes = min(max(excerptAutoPushMinutes, 1), 1440)
        cardRotationMinutes = min(max(cardRotationMinutes, 1), 60)
        sidebarWidth = min(max(sidebarWidth, 48), 320)
        // 轮换卡片列表：去重 + 过滤无效模式
        let validModes = Set(DisplayMode.allCases.map(\.rawValue))
        var cleanedModes: [Int] = []
        var seenModes = Set<Int>()
        for mode in cardRotationModes where validModes.contains(mode) && !seenModes.contains(mode) {
            cleanedModes.append(mode)
            seenModes.insert(mode)
        }
        cardRotationModes = cleanedModes
        // 独立画板模块列表：去重 + 过滤无效模块
        oracleCanvasModules = Self.cleanModuleList(oracleCanvasModules)
        excerptCanvasModules = Self.cleanModuleList(excerptCanvasModules)
        // 摘录布局：列数钳制 1–2，占满整行的模块去重 + 过滤无效
        excerptLayoutColumns = min(max(excerptLayoutColumns, 1), 2)
        excerptFullWidthModules = Self.cleanModuleList(excerptFullWidthModules)
        if clockTimeFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clockTimeFormat = "HH:mm"
        }
        if canvasClockFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            canvasClockFormat = "HH:mm"
        }
        if canvasDateFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            canvasDateFormat = "yyyy年M月d日"
        }
        if !([60, 300, 600, 1800].contains(codexRefreshSeconds)) {
            codexRefreshSeconds = 300
        }
        sspaiRefreshMinutes = min(max(sspaiRefreshMinutes, 5), 240)
        canvasSspaiCount = min(max(canvasSspaiCount, 1), 6)
        oracleSspaiCount = min(max(oracleSspaiCount, 1), 6)
        excerptSspaiCount = min(max(excerptSspaiCount, 1), 6)
        // 口袋先知多画板：清理每块画板的模块列表，当前下标钳制到有效范围
        oracleCanvasBoards = oracleCanvasBoards.map { board in
            var cleaned = board
            cleaned.modules = Self.cleanModuleList(board.modules)
            return cleaned
        }
        if oracleCanvasBoards.isEmpty {
            oracleCanvasBoardIndex = 0
        } else {
            oracleCanvasBoardIndex = min(max(oracleCanvasBoardIndex, 0), oracleCanvasBoards.count - 1)
        }
        emojiWallpaperSize = min(max(emojiWallpaperSize, 16), 96)
        emojiWallpaperSpacing = min(max(emojiWallpaperSpacing, 0), 40)
        // 摘录语录分类：去重 + 过滤无效
        let validQuoteCats = Set(ExcerptQuoteCategory.allCases.map(\.rawValue))
        var cleanedQuoteCats: [Int] = []
        var seenQuoteCats = Set<Int>()
        for cat in excerptQuoteCategories where validQuoteCats.contains(cat) && !seenQuoteCats.contains(cat) {
            cleanedQuoteCats.append(cat)
            seenQuoteCats.insert(cat)
        }
        excerptQuoteCategories = cleanedQuoteCats
    }

    // MARK: - Codable（手动实现，与 @Published 兼容）

    private enum CodingKeys: String, CodingKey {
        case endpoint, codexRefreshSeconds, sspaiRefreshMinutes, sspaiRandomPush, dynamicUploadSeconds, safeAreaHeight,
             jpegQuality, qwenQuotaBaseline, qwenQuotaBaselineDay, displayMode, cardTheme, customImagePath, customImageName,
             oracleCanvasImagePath, oracleCanvasImageName, excerptCanvasImagePath, excerptCanvasImageName,
             customImageHistory,
             startWithSystem, codexCliPath, appearanceMode, backgroundTone,
             customBackgroundHex, accentTone, customAccentHex,
             showCpu, showMemory, showNetwork, showUptime, showDisk,
             networkChart,
             imageRotationEnabled, imageRotationSeconds, imageRotationMode,
             customImageClock, wallpaperColorStyle, clockDateVisible,
             clockFontSize, clockTimeFormat, clockFontWeight, clockFont,
             clockOffsetX, clockOffsetY, timeFormat, dateFormat,
             canvasModules, canvasText,
             canvasClockFormat, canvasDateFormat, canvasNowPlayingCover, canvasNowPlayingSmartBg,
             oracleNowPlayingHorizontal, excerptNowPlayingHorizontal, canvasImageMode,
             canvasSspaiCount, oracleSspaiCount, excerptSspaiCount,
             canvasSspaiRandom, oracleSspaiRandom, excerptSspaiRandom,
             excerptQuoteCategories, showExcerptSource,
             emojiWallpaperText, emojiWallpaperSize, emojiWallpaperLayout, emojiWallpaperSpacing,
             canvasModuleMargins, canvasPrinterFields, oracleCanvasPrinterFields, excerptCanvasPrinterFields, qwenQuotaShowPercent,
             pomodoroPraiseEnabled, pomodoroPraiseSource, pomodoroTaskFontSize,
             pomodoroToggleShortcut, pomodoroSkipShortcut, pomodoroResetShortcut,
             keyboardPageUpShortcut, keyboardPageDownShortcut, lingxi68KnobPagingEnabled,
             haServerURL, haToken, haRefreshMinutes, haEntityID, haEntities, haCardEntityIDs,
             canvasHAEntityIDs, oracleCanvasHAEntityIDs, excerptCanvasHAEntityIDs, haEntityAliases,
             haMonitorEnabled, haMonitorEntityID, haMonitorExpectedState, haMonitorErrorEntityID,
             bambuEnableAlert, bambuStatusEntityID, bambuProgressEntityID, bambuTaskEntityID,
             bambuNozzleTempEntityID, bambuBedTempEntityID, bambuRemainingEntityID, bambuErrorEntityID,
             bambuImageEntityID, bambuTaskImageEntityID, bambuImageSource,
             bambuPrinterName, bambuPrinters,
             nowPlayingTitleSize, nowPlayingArtistSize,
             nowPlayingFooterVisible, nowPlayingTimeFormat, nowPlayingDateFormat,
             nowPlayingTimeSize, nowPlayingDateSize,
             canvasNowPlayingTitleSize, canvasNowPlayingArtistSize,
             oracleBackgroundMode,
             oracleAutoPushEnabled, oracleAutoPushMinutes,
             oracleBoardRotationEnabled, oracleBoardRotationMinutes,
             excerptAutoPushEnabled, excerptAutoPushMinutes,
             cardRotationEnabled, cardRotationMinutes, cardRotationModes,
             sidebarOrder, keyboardCardPanels, sidebarWidth,
             dotApiKey, dotDeviceId, rand0IP, rand0ButtonTarget, rand0ButtonTargetDeviceID,
             devices, menuBarKeyboardDeviceID, lastUpdateCheckAt, activeKeyboardDeviceID, activeOracleDeviceID, activeExcerptDeviceID, activeHomeAssistantDeviceID, activeBambuLabDeviceID,
             oracleCanvasModules, excerptCanvasModules,
             oracleImageRotate180,
             oracleDisplayMode, oracleGrayAlgorithm, oracleDitherKernel,
             excerptDisplayMode, excerptGrayAlgorithm, excerptDitherKernel,
             excerptLayoutColumns, excerptFullWidthModules,
             excerptImageRotate180, excerptBackgroundMode, excerptPushRawImage,
             excerptServerDitherType, excerptServerDitherKernel,
             oracleCanvasBoards, oracleCanvasBoardIndex
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(codexRefreshSeconds, forKey: .codexRefreshSeconds)
        try container.encode(sspaiRefreshMinutes, forKey: .sspaiRefreshMinutes)
        try container.encode(sspaiRandomPush, forKey: .sspaiRandomPush)
        try container.encode(dynamicUploadSeconds, forKey: .dynamicUploadSeconds)
        try container.encode(safeAreaHeight, forKey: .safeAreaHeight)
        try container.encode(jpegQuality, forKey: .jpegQuality)
        try container.encodeIfPresent(qwenQuotaBaseline, forKey: .qwenQuotaBaseline)
        try container.encodeIfPresent(qwenQuotaBaselineDay, forKey: .qwenQuotaBaselineDay)
        try container.encode(displayMode.rawValue, forKey: .displayMode)
        try container.encode(cardTheme.rawValue, forKey: .cardTheme)
        try container.encodeIfPresent(customImagePath, forKey: .customImagePath)
        try container.encodeIfPresent(customImageName, forKey: .customImageName)
        try container.encodeIfPresent(oracleCanvasImagePath, forKey: .oracleCanvasImagePath)
        try container.encodeIfPresent(oracleCanvasImageName, forKey: .oracleCanvasImageName)
        try container.encodeIfPresent(excerptCanvasImagePath, forKey: .excerptCanvasImagePath)
        try container.encodeIfPresent(excerptCanvasImageName, forKey: .excerptCanvasImageName)
        try container.encode(customImageHistory, forKey: .customImageHistory)
        try container.encode(startWithSystem, forKey: .startWithSystem)
        try container.encodeIfPresent(codexCliPath, forKey: .codexCliPath)
        try container.encode(appearanceMode.rawValue, forKey: .appearanceMode)
        try container.encode(backgroundTone.rawValue, forKey: .backgroundTone)
        try container.encodeIfPresent(customBackgroundHex, forKey: .customBackgroundHex)
        try container.encode(accentTone.rawValue, forKey: .accentTone)
        try container.encodeIfPresent(customAccentHex, forKey: .customAccentHex)
        try container.encode(showCpu, forKey: .showCpu)
        try container.encode(showMemory, forKey: .showMemory)
        try container.encode(showNetwork, forKey: .showNetwork)
        try container.encode(showUptime, forKey: .showUptime)
        try container.encode(showDisk, forKey: .showDisk)
        try container.encode(networkChart, forKey: .networkChart)
        try container.encode(imageRotationEnabled, forKey: .imageRotationEnabled)
        try container.encode(imageRotationSeconds, forKey: .imageRotationSeconds)
        try container.encode(imageRotationMode.rawValue, forKey: .imageRotationMode)
        try container.encode(customImageClock.rawValue, forKey: .customImageClock)
        try container.encode(wallpaperColorStyle.rawValue, forKey: .wallpaperColorStyle)
        try container.encode(clockDateVisible, forKey: .clockDateVisible)
        try container.encode(clockFontSize, forKey: .clockFontSize)
        try container.encode(clockFontWeight.rawValue, forKey: .clockFontWeight)
        try container.encode(clockFont.rawValue, forKey: .clockFont)
        try container.encode(clockOffsetX, forKey: .clockOffsetX)
        try container.encode(clockOffsetY, forKey: .clockOffsetY)
        try container.encode(timeFormat, forKey: .timeFormat)
        try container.encode(dateFormat, forKey: .dateFormat)
        try container.encode(clockTimeFormat, forKey: .clockTimeFormat)
        try container.encode(canvasModules, forKey: .canvasModules)
        try container.encode(canvasText, forKey: .canvasText)
        try container.encode(canvasClockFormat, forKey: .canvasClockFormat)
        try container.encode(canvasDateFormat, forKey: .canvasDateFormat)
        try container.encode(canvasNowPlayingCover, forKey: .canvasNowPlayingCover)
        try container.encode(canvasNowPlayingSmartBg, forKey: .canvasNowPlayingSmartBg)
        try container.encode(oracleNowPlayingHorizontal, forKey: .oracleNowPlayingHorizontal)
        try container.encode(excerptNowPlayingHorizontal, forKey: .excerptNowPlayingHorizontal)
        try container.encode(canvasSspaiCount, forKey: .canvasSspaiCount)
        try container.encode(oracleSspaiCount, forKey: .oracleSspaiCount)
        try container.encode(excerptSspaiCount, forKey: .excerptSspaiCount)
        try container.encode(canvasSspaiRandom, forKey: .canvasSspaiRandom)
        try container.encode(oracleSspaiRandom, forKey: .oracleSspaiRandom)
        try container.encode(excerptSspaiRandom, forKey: .excerptSspaiRandom)
        try container.encode(excerptQuoteCategories, forKey: .excerptQuoteCategories)
        try container.encode(showExcerptSource, forKey: .showExcerptSource)
        try container.encode(emojiWallpaperText, forKey: .emojiWallpaperText)
        try container.encode(emojiWallpaperSize, forKey: .emojiWallpaperSize)
        try container.encode(emojiWallpaperLayout.rawValue, forKey: .emojiWallpaperLayout)
        try container.encode(emojiWallpaperSpacing, forKey: .emojiWallpaperSpacing)
        try container.encode(canvasImageMode.rawValue, forKey: .canvasImageMode)
        try container.encode(canvasModuleMargins, forKey: .canvasModuleMargins)
        try container.encode(canvasPrinterFields, forKey: .canvasPrinterFields)
        try container.encode(oracleCanvasPrinterFields, forKey: .oracleCanvasPrinterFields)
        try container.encode(excerptCanvasPrinterFields, forKey: .excerptCanvasPrinterFields)
        try container.encode(qwenQuotaShowPercent, forKey: .qwenQuotaShowPercent)
        try container.encode(pomodoroPraiseEnabled, forKey: .pomodoroPraiseEnabled)
        try container.encode(pomodoroPraiseSource.rawValue, forKey: .pomodoroPraiseSource)
        try container.encode(pomodoroTaskFontSize, forKey: .pomodoroTaskFontSize)
        try container.encode(pomodoroToggleShortcut, forKey: .pomodoroToggleShortcut)
        try container.encode(pomodoroSkipShortcut, forKey: .pomodoroSkipShortcut)
        try container.encode(pomodoroResetShortcut, forKey: .pomodoroResetShortcut)
        try container.encode(keyboardPageUpShortcut, forKey: .keyboardPageUpShortcut)
        try container.encode(keyboardPageDownShortcut, forKey: .keyboardPageDownShortcut)
        try container.encode(lingxi68KnobPagingEnabled, forKey: .lingxi68KnobPagingEnabled)
        try container.encode(haServerURL, forKey: .haServerURL)
        try container.encode(haToken, forKey: .haToken)
        try container.encode(haRefreshMinutes, forKey: .haRefreshMinutes)
        try container.encode(haEntityID, forKey: .haEntityID)
        try container.encode(haEntities, forKey: .haEntities)
        try container.encode(haCardEntityIDs, forKey: .haCardEntityIDs)
        try container.encode(canvasHAEntityIDs, forKey: .canvasHAEntityIDs)
        try container.encode(oracleCanvasHAEntityIDs, forKey: .oracleCanvasHAEntityIDs)
        try container.encode(excerptCanvasHAEntityIDs, forKey: .excerptCanvasHAEntityIDs)
        try container.encode(haEntityAliases, forKey: .haEntityAliases)
        try container.encode(haMonitorEnabled, forKey: .haMonitorEnabled)
        try container.encode(haMonitorEntityID, forKey: .haMonitorEntityID)
        try container.encode(haMonitorExpectedState, forKey: .haMonitorExpectedState)
        try container.encode(haMonitorErrorEntityID, forKey: .haMonitorErrorEntityID)
        try container.encode(bambuEnableAlert, forKey: .bambuEnableAlert)
        try container.encode(bambuStatusEntityID, forKey: .bambuStatusEntityID)
        try container.encode(bambuProgressEntityID, forKey: .bambuProgressEntityID)
        try container.encode(bambuTaskEntityID, forKey: .bambuTaskEntityID)
        try container.encode(bambuNozzleTempEntityID, forKey: .bambuNozzleTempEntityID)
        try container.encode(bambuBedTempEntityID, forKey: .bambuBedTempEntityID)
        try container.encode(bambuRemainingEntityID, forKey: .bambuRemainingEntityID)
        try container.encode(bambuErrorEntityID, forKey: .bambuErrorEntityID)
        try container.encode(bambuImageEntityID, forKey: .bambuImageEntityID)
        try container.encode(bambuTaskImageEntityID, forKey: .bambuTaskImageEntityID)
        try container.encode(bambuImageSource.rawValue, forKey: .bambuImageSource)
        try container.encode(bambuPrinterName, forKey: .bambuPrinterName)
        try container.encode(bambuPrinters, forKey: .bambuPrinters)
        try container.encode(nowPlayingTitleSize, forKey: .nowPlayingTitleSize)
        try container.encode(nowPlayingArtistSize, forKey: .nowPlayingArtistSize)
        try container.encode(nowPlayingFooterVisible, forKey: .nowPlayingFooterVisible)
        try container.encode(nowPlayingTimeFormat, forKey: .nowPlayingTimeFormat)
        try container.encode(nowPlayingDateFormat, forKey: .nowPlayingDateFormat)
        try container.encode(nowPlayingTimeSize, forKey: .nowPlayingTimeSize)
        try container.encode(nowPlayingDateSize, forKey: .nowPlayingDateSize)
        try container.encode(canvasNowPlayingTitleSize, forKey: .canvasNowPlayingTitleSize)
        try container.encode(canvasNowPlayingArtistSize, forKey: .canvasNowPlayingArtistSize)
        try container.encode(oracleBackgroundMode.rawValue, forKey: .oracleBackgroundMode)
        try container.encode(oracleAutoPushEnabled, forKey: .oracleAutoPushEnabled)
        try container.encode(oracleAutoPushMinutes, forKey: .oracleAutoPushMinutes)
        try container.encode(oracleBoardRotationEnabled, forKey: .oracleBoardRotationEnabled)
        try container.encode(oracleBoardRotationMinutes, forKey: .oracleBoardRotationMinutes)
        try container.encode(excerptAutoPushEnabled, forKey: .excerptAutoPushEnabled)
        try container.encode(excerptAutoPushMinutes, forKey: .excerptAutoPushMinutes)
        try container.encode(cardRotationEnabled, forKey: .cardRotationEnabled)
        try container.encode(cardRotationMinutes, forKey: .cardRotationMinutes)
        try container.encode(cardRotationModes, forKey: .cardRotationModes)
        try container.encode(sidebarOrder, forKey: .sidebarOrder)
        try container.encodeIfPresent(keyboardCardPanels, forKey: .keyboardCardPanels)
        try container.encode(sidebarWidth, forKey: .sidebarWidth)
        try container.encode(dotApiKey, forKey: .dotApiKey)
        try container.encode(dotDeviceId, forKey: .dotDeviceId)
        try container.encode(rand0IP, forKey: .rand0IP)
        try container.encode(rand0ButtonTarget.rawValue, forKey: .rand0ButtonTarget)
        try container.encodeIfPresent(rand0ButtonTargetDeviceID, forKey: .rand0ButtonTargetDeviceID)
        try container.encode(devices, forKey: .devices)
        try container.encodeIfPresent(menuBarKeyboardDeviceID, forKey: .menuBarKeyboardDeviceID)
        try container.encodeIfPresent(lastUpdateCheckAt, forKey: .lastUpdateCheckAt)
        try container.encodeIfPresent(activeKeyboardDeviceID, forKey: .activeKeyboardDeviceID)
        try container.encodeIfPresent(activeOracleDeviceID, forKey: .activeOracleDeviceID)
        try container.encodeIfPresent(activeExcerptDeviceID, forKey: .activeExcerptDeviceID)
        try container.encodeIfPresent(activeHomeAssistantDeviceID, forKey: .activeHomeAssistantDeviceID)
        try container.encodeIfPresent(activeBambuLabDeviceID, forKey: .activeBambuLabDeviceID)
        try container.encode(oracleCanvasModules, forKey: .oracleCanvasModules)
        try container.encode(excerptCanvasModules, forKey: .excerptCanvasModules)
        try container.encode(oracleImageRotate180, forKey: .oracleImageRotate180)
        try container.encode(excerptImageRotate180, forKey: .excerptImageRotate180)
        try container.encode(excerptBackgroundMode.rawValue, forKey: .excerptBackgroundMode)
        try container.encode(excerptPushRawImage, forKey: .excerptPushRawImage)
        try container.encode(excerptServerDitherType.rawValue, forKey: .excerptServerDitherType)
        try container.encode(excerptServerDitherKernel.rawValue, forKey: .excerptServerDitherKernel)
        try container.encode(oracleCanvasBoards, forKey: .oracleCanvasBoards)
        try container.encode(oracleCanvasBoardIndex, forKey: .oracleCanvasBoardIndex)
        try container.encode(oracleDisplayMode.rawValue, forKey: .oracleDisplayMode)
        try container.encode(oracleGrayAlgorithm.rawValue, forKey: .oracleGrayAlgorithm)
        try container.encode(oracleDitherKernel.rawValue, forKey: .oracleDitherKernel)
        try container.encode(excerptDisplayMode.rawValue, forKey: .excerptDisplayMode)
        try container.encode(excerptGrayAlgorithm.rawValue, forKey: .excerptGrayAlgorithm)
        try container.encode(excerptDitherKernel.rawValue, forKey: .excerptDitherKernel)
        try container.encode(excerptLayoutColumns, forKey: .excerptLayoutColumns)
        try container.encode(excerptFullWidthModules, forKey: .excerptFullWidthModules)
    }
}

extension AppSettings: Codable {
    public convenience init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? endpoint
        codexRefreshSeconds = try container.decodeIfPresent(Int.self, forKey: .codexRefreshSeconds) ?? codexRefreshSeconds
        sspaiRefreshMinutes = try container.decodeIfPresent(Int.self, forKey: .sspaiRefreshMinutes) ?? sspaiRefreshMinutes
        sspaiRandomPush = try container.decodeIfPresent(Bool.self, forKey: .sspaiRandomPush) ?? sspaiRandomPush
        dynamicUploadSeconds = try container.decodeIfPresent(Int.self, forKey: .dynamicUploadSeconds) ?? dynamicUploadSeconds
        safeAreaHeight = try container.decodeIfPresent(Int.self, forKey: .safeAreaHeight) ?? safeAreaHeight
        jpegQuality = try container.decodeIfPresent(Int.self, forKey: .jpegQuality) ?? jpegQuality
        qwenQuotaBaseline = try container.decodeIfPresent(Double.self, forKey: .qwenQuotaBaseline) ?? qwenQuotaBaseline
        qwenQuotaBaselineDay = try container.decodeIfPresent(String.self, forKey: .qwenQuotaBaselineDay) ?? qwenQuotaBaselineDay
        if let raw = try container.decodeIfPresent(Int.self, forKey: .displayMode),
           let mode = DisplayMode(rawValue: raw) {
            displayMode = mode
        }
        if let raw = try container.decodeIfPresent(Int.self, forKey: .cardTheme),
           let theme = CardTheme(rawValue: raw) {
            cardTheme = theme
        }
        customImagePath = try container.decodeIfPresent(String.self, forKey: .customImagePath)
        customImageName = try container.decodeIfPresent(String.self, forKey: .customImageName)
        oracleCanvasImagePath = try container.decodeIfPresent(String.self, forKey: .oracleCanvasImagePath)
        oracleCanvasImageName = try container.decodeIfPresent(String.self, forKey: .oracleCanvasImageName)
        excerptCanvasImagePath = try container.decodeIfPresent(String.self, forKey: .excerptCanvasImagePath)
        excerptCanvasImageName = try container.decodeIfPresent(String.self, forKey: .excerptCanvasImageName)
        customImageHistory = try container.decodeIfPresent([RecentImage].self, forKey: .customImageHistory) ?? []
        startWithSystem = try container.decodeIfPresent(Bool.self, forKey: .startWithSystem) ?? startWithSystem
        codexCliPath = try container.decodeIfPresent(String.self, forKey: .codexCliPath)
        if let raw = try container.decodeIfPresent(Int.self, forKey: .appearanceMode),
           let mode = AppearanceMode(rawValue: raw) {
            appearanceMode = mode
        }
        if let raw = try container.decodeIfPresent(Int.self, forKey: .backgroundTone),
           let tone = BackgroundTone(rawValue: raw) {
            backgroundTone = tone
        }
        customBackgroundHex = try container.decodeIfPresent(String.self, forKey: .customBackgroundHex)
        if let raw = try container.decodeIfPresent(Int.self, forKey: .accentTone),
           let tone = AccentTone(rawValue: raw) {
            accentTone = tone
        }
        customAccentHex = try container.decodeIfPresent(String.self, forKey: .customAccentHex)
        showCpu = try container.decodeIfPresent(Bool.self, forKey: .showCpu) ?? showCpu
        showMemory = try container.decodeIfPresent(Bool.self, forKey: .showMemory) ?? showMemory
        showNetwork = try container.decodeIfPresent(Bool.self, forKey: .showNetwork) ?? showNetwork
        showUptime = try container.decodeIfPresent(Bool.self, forKey: .showUptime) ?? showUptime
        showDisk = try container.decodeIfPresent(Bool.self, forKey: .showDisk) ?? showDisk
        networkChart = try container.decodeIfPresent(Bool.self, forKey: .networkChart) ?? networkChart
        imageRotationEnabled = try container.decodeIfPresent(Bool.self, forKey: .imageRotationEnabled) ?? imageRotationEnabled
        imageRotationSeconds = try container.decodeIfPresent(Int.self, forKey: .imageRotationSeconds) ?? imageRotationSeconds
        if let raw = try container.decodeIfPresent(Int.self, forKey: .imageRotationMode),
           let mode = ImageRotationMode(rawValue: raw) {
            imageRotationMode = mode
        }
        if let raw = try container.decodeIfPresent(Int.self, forKey: .customImageClock),
           let overlay = CustomImageClockOverlay(rawValue: raw) {
            customImageClock = overlay.stackedOnly
        }
        if let raw = try container.decodeIfPresent(Int.self, forKey: .wallpaperColorStyle),
           let style = WallpaperColorStyle(rawValue: raw) {
            wallpaperColorStyle = style
        }
        clockDateVisible = try container.decodeIfPresent(Bool.self, forKey: .clockDateVisible)
            ?? clockDateVisible
        clockFontSize = try container.decodeIfPresent(Int.self, forKey: .clockFontSize) ?? clockFontSize
        if let raw = try container.decodeIfPresent(Int.self, forKey: .clockFontWeight),
           let weight = ClockFontWeight(rawValue: raw) {
            clockFontWeight = weight
        }
        if let raw = try container.decodeIfPresent(Int.self, forKey: .clockFont),
           let font = ClockFont(rawValue: raw) {
            clockFont = font
        }
        clockOffsetX = try container.decodeIfPresent(Int.self, forKey: .clockOffsetX) ?? clockOffsetX
        clockOffsetY = try container.decodeIfPresent(Int.self, forKey: .clockOffsetY) ?? clockOffsetY
        timeFormat = try container.decodeIfPresent(String.self, forKey: .timeFormat) ?? timeFormat
        dateFormat = try container.decodeIfPresent(String.self, forKey: .dateFormat) ?? dateFormat
        clockTimeFormat = try container.decodeIfPresent(String.self, forKey: .clockTimeFormat) ?? clockTimeFormat
        canvasModules = try container.decodeIfPresent([Int].self, forKey: .canvasModules) ?? canvasModules
        canvasText = try container.decodeIfPresent(String.self, forKey: .canvasText) ?? canvasText
        canvasClockFormat = try container.decodeIfPresent(String.self, forKey: .canvasClockFormat) ?? canvasClockFormat
        canvasDateFormat = try container.decodeIfPresent(String.self, forKey: .canvasDateFormat) ?? canvasDateFormat
        canvasNowPlayingCover = try container.decodeIfPresent(Bool.self, forKey: .canvasNowPlayingCover) ?? canvasNowPlayingCover
        canvasNowPlayingSmartBg = try container.decodeIfPresent(Bool.self, forKey: .canvasNowPlayingSmartBg) ?? canvasNowPlayingSmartBg
        oracleNowPlayingHorizontal = try container.decodeIfPresent(Bool.self, forKey: .oracleNowPlayingHorizontal) ?? oracleNowPlayingHorizontal
        excerptNowPlayingHorizontal = try container.decodeIfPresent(Bool.self, forKey: .excerptNowPlayingHorizontal) ?? excerptNowPlayingHorizontal
        canvasSspaiCount = try container.decodeIfPresent(Int.self, forKey: .canvasSspaiCount) ?? canvasSspaiCount
        oracleSspaiCount = try container.decodeIfPresent(Int.self, forKey: .oracleSspaiCount) ?? oracleSspaiCount
        excerptSspaiCount = try container.decodeIfPresent(Int.self, forKey: .excerptSspaiCount) ?? excerptSspaiCount
        canvasSspaiRandom = try container.decodeIfPresent(Bool.self, forKey: .canvasSspaiRandom) ?? canvasSspaiRandom
        oracleSspaiRandom = try container.decodeIfPresent(Bool.self, forKey: .oracleSspaiRandom) ?? oracleSspaiRandom
        excerptSspaiRandom = try container.decodeIfPresent(Bool.self, forKey: .excerptSspaiRandom) ?? excerptSspaiRandom
        excerptQuoteCategories = try container.decodeIfPresent([Int].self, forKey: .excerptQuoteCategories) ?? excerptQuoteCategories
        showExcerptSource = try container.decodeIfPresent(Bool.self, forKey: .showExcerptSource) ?? showExcerptSource
        emojiWallpaperText = try container.decodeIfPresent(String.self, forKey: .emojiWallpaperText) ?? emojiWallpaperText
        emojiWallpaperSize = try container.decodeIfPresent(Int.self, forKey: .emojiWallpaperSize) ?? emojiWallpaperSize
        if let raw = try container.decodeIfPresent(Int.self, forKey: .emojiWallpaperLayout),
           let layout = EmojiWallpaperLayout(rawValue: raw) {
            emojiWallpaperLayout = layout
        }
        emojiWallpaperSpacing = try container.decodeIfPresent(Int.self, forKey: .emojiWallpaperSpacing) ?? emojiWallpaperSpacing
        if let raw = try container.decodeIfPresent(Int.self, forKey: .canvasImageMode),
           let mode = CanvasImageMode(rawValue: raw) {
            canvasImageMode = mode
        }
        canvasModuleMargins = (try container.decodeIfPresent([Int: Int].self, forKey: .canvasModuleMargins) ?? [:])
            .filter { $0.value > 0 }   // 0 = 自适应模式：丢弃历史遗留的显式 0 条目
        canvasPrinterFields = try container.decodeIfPresent([Int: CanvasPrinterFields].self, forKey: .canvasPrinterFields) ?? [:]
        oracleCanvasPrinterFields = try container.decodeIfPresent([Int: CanvasPrinterFields].self, forKey: .oracleCanvasPrinterFields) ?? [:]
        excerptCanvasPrinterFields = try container.decodeIfPresent([Int: CanvasPrinterFields].self, forKey: .excerptCanvasPrinterFields) ?? [:]
        qwenQuotaShowPercent = try container.decodeIfPresent(Bool.self, forKey: .qwenQuotaShowPercent) ?? qwenQuotaShowPercent
        pomodoroPraiseEnabled = try container.decodeIfPresent(Bool.self, forKey: .pomodoroPraiseEnabled) ?? pomodoroPraiseEnabled
        if let raw = try container.decodeIfPresent(Int.self, forKey: .pomodoroPraiseSource),
           let source = PraiseSource(rawValue: raw) {
            pomodoroPraiseSource = source
        }
        pomodoroTaskFontSize = try container.decodeIfPresent(Int.self, forKey: .pomodoroTaskFontSize) ?? pomodoroTaskFontSize
        pomodoroToggleShortcut = try container.decodeIfPresent(GlobalShortcut.self, forKey: .pomodoroToggleShortcut) ?? .defaultToggle
        pomodoroSkipShortcut = try container.decodeIfPresent(GlobalShortcut.self, forKey: .pomodoroSkipShortcut) ?? .defaultSkip
        pomodoroResetShortcut = try container.decodeIfPresent(GlobalShortcut.self, forKey: .pomodoroResetShortcut) ?? .defaultReset
        keyboardPageUpShortcut = try container.decodeIfPresent(GlobalShortcut.self, forKey: .keyboardPageUpShortcut) ?? .defaultPageUp
        keyboardPageDownShortcut = try container.decodeIfPresent(GlobalShortcut.self, forKey: .keyboardPageDownShortcut) ?? .defaultPageDown
        lingxi68KnobPagingEnabled = try container.decodeIfPresent(Bool.self, forKey: .lingxi68KnobPagingEnabled) ?? false
        haServerURL = try container.decodeIfPresent(String.self, forKey: .haServerURL) ?? haServerURL
        haToken = try container.decodeIfPresent(String.self, forKey: .haToken) ?? haToken
        haRefreshMinutes = try container.decodeIfPresent(Int.self, forKey: .haRefreshMinutes) ?? haRefreshMinutes
        haEntityID = try container.decodeIfPresent(String.self, forKey: .haEntityID) ?? haEntityID
        haEntities = try container.decodeIfPresent([String].self, forKey: .haEntities) ?? haEntities
        haCardEntityIDs = try container.decodeIfPresent([String].self, forKey: .haCardEntityIDs) ?? haCardEntityIDs
        canvasHAEntityIDs = try container.decodeIfPresent([String].self, forKey: .canvasHAEntityIDs) ?? []
        oracleCanvasHAEntityIDs = try container.decodeIfPresent([String].self, forKey: .oracleCanvasHAEntityIDs) ?? []
        excerptCanvasHAEntityIDs = try container.decodeIfPresent([String].self, forKey: .excerptCanvasHAEntityIDs) ?? []
        // 旧档案：只有全局实体列表（或单实体字段）时，先把它作为当前镜像值，
        // 随后 migrateKeyboardCardContentSeeds 会为每台键盘各记一份，之后互不影响
        if haCardEntityIDs.isEmpty {
            if !haEntities.isEmpty { haCardEntityIDs = haEntities }
            else if !haEntityID.isEmpty { haCardEntityIDs = [haEntityID] }
        }
        haEntityAliases = try container.decodeIfPresent([String: String].self, forKey: .haEntityAliases) ?? haEntityAliases
        haMonitorEnabled = try container.decodeIfPresent(Bool.self, forKey: .haMonitorEnabled) ?? haMonitorEnabled
        haMonitorEntityID = try container.decodeIfPresent(String.self, forKey: .haMonitorEntityID) ?? haMonitorEntityID
        haMonitorExpectedState = try container.decodeIfPresent(String.self, forKey: .haMonitorExpectedState) ?? haMonitorExpectedState
        haMonitorErrorEntityID = try container.decodeIfPresent(String.self, forKey: .haMonitorErrorEntityID) ?? haMonitorErrorEntityID
        bambuEnableAlert = try container.decodeIfPresent(Bool.self, forKey: .bambuEnableAlert) ?? bambuEnableAlert
        bambuStatusEntityID = try container.decodeIfPresent(String.self, forKey: .bambuStatusEntityID) ?? bambuStatusEntityID
        bambuProgressEntityID = try container.decodeIfPresent(String.self, forKey: .bambuProgressEntityID) ?? bambuProgressEntityID
        bambuTaskEntityID = try container.decodeIfPresent(String.self, forKey: .bambuTaskEntityID) ?? bambuTaskEntityID
        bambuNozzleTempEntityID = try container.decodeIfPresent(String.self, forKey: .bambuNozzleTempEntityID) ?? bambuNozzleTempEntityID
        bambuBedTempEntityID = try container.decodeIfPresent(String.self, forKey: .bambuBedTempEntityID) ?? bambuBedTempEntityID
        bambuRemainingEntityID = try container.decodeIfPresent(String.self, forKey: .bambuRemainingEntityID) ?? bambuRemainingEntityID
        bambuErrorEntityID = try container.decodeIfPresent(String.self, forKey: .bambuErrorEntityID) ?? bambuErrorEntityID
        bambuImageEntityID = try container.decodeIfPresent(String.self, forKey: .bambuImageEntityID) ?? bambuImageEntityID
        bambuTaskImageEntityID = try container.decodeIfPresent(String.self, forKey: .bambuTaskImageEntityID) ?? bambuTaskImageEntityID
        if let raw = try container.decodeIfPresent(Int.self, forKey: .bambuImageSource),
           let source = BambuImageSource(rawValue: raw) {
            bambuImageSource = source
        }
        bambuPrinterName = try container.decodeIfPresent(String.self, forKey: .bambuPrinterName) ?? bambuPrinterName
        bambuPrinters = try container.decodeIfPresent([BambuLabCardSettings].self, forKey: .bambuPrinters) ?? bambuPrinters
        nowPlayingTitleSize = try container.decodeIfPresent(Int.self, forKey: .nowPlayingTitleSize) ?? nowPlayingTitleSize
        nowPlayingArtistSize = try container.decodeIfPresent(Int.self, forKey: .nowPlayingArtistSize) ?? nowPlayingArtistSize
        nowPlayingFooterVisible = try container.decodeIfPresent(Bool.self, forKey: .nowPlayingFooterVisible) ?? nowPlayingFooterVisible
        nowPlayingTimeFormat = try container.decodeIfPresent(String.self, forKey: .nowPlayingTimeFormat) ?? nowPlayingTimeFormat
        nowPlayingDateFormat = try container.decodeIfPresent(String.self, forKey: .nowPlayingDateFormat) ?? nowPlayingDateFormat
        nowPlayingTimeSize = try container.decodeIfPresent(Int.self, forKey: .nowPlayingTimeSize) ?? nowPlayingTimeSize
        nowPlayingDateSize = try container.decodeIfPresent(Int.self, forKey: .nowPlayingDateSize) ?? nowPlayingDateSize
        canvasNowPlayingTitleSize = try container.decodeIfPresent(Int.self, forKey: .canvasNowPlayingTitleSize) ?? canvasNowPlayingTitleSize
        canvasNowPlayingArtistSize = try container.decodeIfPresent(Int.self, forKey: .canvasNowPlayingArtistSize) ?? canvasNowPlayingArtistSize
        if let raw = try container.decodeIfPresent(Int.self, forKey: .oracleBackgroundMode),
           let mode = CanvasBackgroundMode(rawValue: raw) {
            oracleBackgroundMode = mode
        }
        oracleAutoPushEnabled = try container.decodeIfPresent(Bool.self, forKey: .oracleAutoPushEnabled) ?? oracleAutoPushEnabled
        oracleAutoPushMinutes = try container.decodeIfPresent(Int.self, forKey: .oracleAutoPushMinutes) ?? oracleAutoPushMinutes
        oracleBoardRotationEnabled = try container.decodeIfPresent(Bool.self, forKey: .oracleBoardRotationEnabled) ?? oracleBoardRotationEnabled
        oracleBoardRotationMinutes = try container.decodeIfPresent(Int.self, forKey: .oracleBoardRotationMinutes) ?? oracleBoardRotationMinutes
        excerptAutoPushEnabled = try container.decodeIfPresent(Bool.self, forKey: .excerptAutoPushEnabled) ?? excerptAutoPushEnabled
        excerptAutoPushMinutes = try container.decodeIfPresent(Int.self, forKey: .excerptAutoPushMinutes) ?? excerptAutoPushMinutes
        cardRotationEnabled = try container.decodeIfPresent(Bool.self, forKey: .cardRotationEnabled) ?? cardRotationEnabled
        cardRotationMinutes = try container.decodeIfPresent(Int.self, forKey: .cardRotationMinutes) ?? cardRotationMinutes
        cardRotationModes = try container.decodeIfPresent([Int].self, forKey: .cardRotationModes) ?? cardRotationModes
        sidebarWidth = try container.decodeIfPresent(Int.self, forKey: .sidebarWidth) ?? sidebarWidth
        dotApiKey = try container.decodeIfPresent(String.self, forKey: .dotApiKey) ?? dotApiKey
        dotDeviceId = try container.decodeIfPresent(String.self, forKey: .dotDeviceId) ?? dotDeviceId
        rand0IP = try container.decodeIfPresent(String.self, forKey: .rand0IP) ?? rand0IP
        if let raw = try container.decodeIfPresent(Int.self, forKey: .rand0ButtonTarget),
           let target = Rand0ButtonTarget(rawValue: raw) {
            rand0ButtonTarget = target
        }
        rand0ButtonTargetDeviceID = try container.decodeIfPresent(UUID.self, forKey: .rand0ButtonTargetDeviceID) ?? rand0ButtonTargetDeviceID
        devices = try container.decodeIfPresent([ManagedDevice].self, forKey: .devices) ?? devices
        menuBarKeyboardDeviceID = try container.decodeIfPresent(UUID.self, forKey: .menuBarKeyboardDeviceID)
        lastUpdateCheckAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdateCheckAt)
        activeKeyboardDeviceID = try container.decodeIfPresent(UUID.self, forKey: .activeKeyboardDeviceID) ?? activeKeyboardDeviceID
        activeOracleDeviceID = try container.decodeIfPresent(UUID.self, forKey: .activeOracleDeviceID) ?? activeOracleDeviceID
        activeExcerptDeviceID = try container.decodeIfPresent(UUID.self, forKey: .activeExcerptDeviceID) ?? activeExcerptDeviceID
        activeHomeAssistantDeviceID = try container.decodeIfPresent(UUID.self, forKey: .activeHomeAssistantDeviceID) ?? activeHomeAssistantDeviceID
        activeBambuLabDeviceID = try container.decodeIfPresent(UUID.self, forKey: .activeBambuLabDeviceID) ?? activeBambuLabDeviceID
        oracleCanvasModules = try container.decodeIfPresent([Int].self, forKey: .oracleCanvasModules) ?? oracleCanvasModules
        excerptCanvasModules = try container.decodeIfPresent([Int].self, forKey: .excerptCanvasModules) ?? excerptCanvasModules
        oracleImageRotate180 = try container.decodeIfPresent(Bool.self, forKey: .oracleImageRotate180) ?? oracleImageRotate180
        excerptImageRotate180 = try container.decodeIfPresent(Bool.self, forKey: .excerptImageRotate180) ?? excerptImageRotate180
        if let raw = try container.decodeIfPresent(Int.self, forKey: .excerptBackgroundMode),
           let mode = CanvasBackgroundMode(rawValue: raw) {
            excerptBackgroundMode = mode
        }
        excerptPushRawImage = try container.decodeIfPresent(Bool.self, forKey: .excerptPushRawImage) ?? excerptPushRawImage
        if let raw = try container.decodeIfPresent(Int.self, forKey: .excerptServerDitherType),
           let type = DotServerDitherType(rawValue: raw) {
            excerptServerDitherType = type
        }
        if let raw = try container.decodeIfPresent(Int.self, forKey: .excerptServerDitherKernel),
           let kernel = DotServerDitherKernel(rawValue: raw) {
            excerptServerDitherKernel = kernel
        }
        oracleCanvasBoards = try container.decodeIfPresent([OracleCanvasBoard].self, forKey: .oracleCanvasBoards) ?? oracleCanvasBoards
        oracleCanvasBoardIndex = try container.decodeIfPresent(Int.self, forKey: .oracleCanvasBoardIndex) ?? oracleCanvasBoardIndex
        if let raw = try container.decodeIfPresent(Int.self, forKey: .oracleDisplayMode),
           let mode = OracleDisplayMode(rawValue: raw) {
            oracleDisplayMode = mode
        }
        if let raw = try container.decodeIfPresent(Int.self, forKey: .oracleGrayAlgorithm),
           let algorithm = OracleGrayAlgorithm(rawValue: raw) {
            oracleGrayAlgorithm = algorithm
        }
        if let raw = try container.decodeIfPresent(Int.self, forKey: .oracleDitherKernel),
           let kernel = OracleDitherKernel(rawValue: raw) {
            oracleDitherKernel = kernel
        }
        if let raw = try container.decodeIfPresent(Int.self, forKey: .excerptDisplayMode),
           let mode = OracleDisplayMode(rawValue: raw) {
            excerptDisplayMode = mode
        }
        if let raw = try container.decodeIfPresent(Int.self, forKey: .excerptGrayAlgorithm),
           let algorithm = OracleGrayAlgorithm(rawValue: raw) {
            excerptGrayAlgorithm = algorithm
        }
        if let raw = try container.decodeIfPresent(Int.self, forKey: .excerptDitherKernel),
           let kernel = OracleDitherKernel(rawValue: raw) {
            excerptDitherKernel = kernel
        }
        excerptLayoutColumns = try container.decodeIfPresent(Int.self, forKey: .excerptLayoutColumns) ?? excerptLayoutColumns
        excerptFullWidthModules = try container.decodeIfPresent([Int].self, forKey: .excerptFullWidthModules) ?? excerptFullWidthModules
        sidebarOrder = try container.decodeIfPresent([String].self, forKey: .sidebarOrder) ?? []
        keyboardCardPanels = try container.decodeIfPresent([String].self, forKey: .keyboardCardPanels)
        clamped()
    }
}

// MARK: - 存储

public final class SettingsStore {
    public let dataDirectory: URL
    public var settingsURL: URL { dataDirectory.appendingPathComponent("settings.json") }
    public var pomodoroURL: URL { dataDirectory.appendingPathComponent("pomodoro.json") }
    public var customImageURL: URL { dataDirectory.appendingPathComponent("custom-image.png") }
    /// 原版 (.NET/Avalonia) 使用的设置文件，用于首次启动迁移。
    public var originalSettingsURL: URL { dataDirectory.appendingPathComponent("settings-v2.json") }
    public var originalPomodoroURL: URL { dataDirectory.appendingPathComponent("pomodoro.json") }

    public init(dataDirectory: URL? = nil) {
        let applicationSupport: URL
        if let dataDirectory {
            applicationSupport = dataDirectory
        } else {
            applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        }
        self.dataDirectory = applicationSupport.appendingPathComponent("LinxDisplay", isDirectory: true)
    }

    public func load() -> AppSettings {
        if let settings = try? read(AppSettings.self, from: settingsURL) {
            settings.clamped()
            return settings
        }
        // 首次运行：尝试迁移原版设置
        if let migrated = migrateFromOriginal() {
            try? write(migrated, to: settingsURL)
            return migrated
        }
        let fresh = AppSettings()
        fresh.clamped()
        return fresh
    }

    public func save(_ settings: AppSettings) {
        try? write(settings, to: settingsURL)
    }

    public func loadPomodoro() -> PomodoroState {
        if let state = try? read(PomodoroState.self, from: pomodoroURL), isMyFormat(pomodoroURL) {
            return state
        }
        // 原版番茄钟数据使用同一个 pomodoro.json（PascalCase 键），格式不符时按原版迁移
        if let migrated = migratePomodoroFromOriginal() {
            try? write(migrated, to: pomodoroURL)
            return migrated
        }
        return PomodoroState()
    }

    public func savePomodoro(_ state: PomodoroState) {
        try? write(state, to: pomodoroURL)
    }

    /// 把自定义图片复制到应用数据目录，返回目标地址。
    @discardableResult
    public func saveCustomImage(from source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: customImageURL.path) {
            try? FileManager.default.removeItem(at: customImageURL)
        }
        try FileManager.default.copyItem(at: source, to: customImageURL)
        return customImageURL
    }

    // MARK: - 自定义图片历史

    /// 历史图片副本目录（每条记录一个独立文件，避免互相覆盖）
    public var historyDirectory: URL {
        dataDirectory.appendingPathComponent("custom-images", isDirectory: true)
    }

    /// 把图片复制进历史目录（保留扩展名），返回目标地址。
    @discardableResult
    public func saveHistoryImage(from source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let target = historyDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    /// 清理历史目录中的图片文件，保留当前正在使用的图片（其副本可能在历史目录内）。
    public func clearHistoryFiles(keepingCurrentPath currentPath: String?) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: historyDirectory, includingPropertiesForKeys: nil) else { return }
        // contentsOfDirectory 返回的路径可能已解析符号链接（如 /var→/private/var），
        // 与存储路径直接比较会失配，统一解析后再比较
        let keep = currentPath.map { ($0 as NSString).resolvingSymlinksInPath }
        for item in items {
            let path = (item.path as NSString).resolvingSymlinksInPath
            guard path != keep, !item.hasDirectoryPath else { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// 恢复初始设定：把设置文件、番茄钟数据、自定义图片与图片缓存目录移入废纸篓
    /// （带时间戳的子目录，可恢复；不永久删除）。下次保存时重新创建全新默认配置。
    /// trashRoot 仅用于测试注入；默认使用系统废纸篓。
    public func resetAllData(trashRoot: URL? = nil) {
        let root = trashRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let trashDir = root.appendingPathComponent(
            "多屏灵犀-恢复初始设定-\(stamp.string(from: Date()))", isDirectory: true)
        try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        // pomodoro 新旧路径指向同一文件，去重防第二次移动失败
        let targets = [settingsURL, pomodoroURL, customImageURL, originalSettingsURL, historyDirectory]
        var seen = Set<String>()
        for target in targets {
            let key = (target.path as NSString).resolvingSymlinksInPath
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            guard FileManager.default.fileExists(atPath: target.path) else { continue }
            let dest = trashDir.appendingPathComponent(target.lastPathComponent)
            try? FileManager.default.moveItem(at: target, to: dest)
        }
    }

    // MARK: - 原版数据迁移（仅在自身数据不存在时执行一次）

    /// 判断文件是否为本应用写入的格式（camelCase 键）。
    private func isMyFormat(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        return root["phase"] != nil || root["endpoint"] != nil
    }

    private func migrateFromOriginal() -> AppSettings? {
        guard let data = try? Data(contentsOf: originalSettingsURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let settings = AppSettings()

        func string(_ key: String) -> String? {
            root[key] as? String
        }
        func int(_ key: String, fallback: Int) -> Int {
            root[key] as? Int ?? fallback
        }
        func bool(_ key: String) -> Bool {
            root[key] as? Bool ?? false
        }

        settings.endpoint = string("Endpoint") ?? settings.endpoint
        settings.codexRefreshSeconds = int("CodexRefreshSeconds", fallback: 300)
        settings.dynamicUploadSeconds = int("DynamicUploadSeconds", fallback: 5)
        settings.safeAreaHeight = int("SafeAreaHeight", fallback: 56)
        settings.jpegQuality = int("JpegQuality", fallback: 90)
        if let raw = root["DisplayMode"] as? Int, let mode = DisplayMode(rawValue: raw) {
            settings.displayMode = mode
        }
        if let raw = root["CardTheme"] as? Int, let theme = CardTheme(rawValue: raw) {
            settings.cardTheme = theme
        }
        settings.customImagePath = string("CustomImagePath")
        settings.customImageName = string("CustomImageName")
        settings.startWithSystem = bool("StartWithSystem")
        settings.codexCliPath = string("CodexCliPath")
        settings.clamped()
        return settings
    }

    private func migratePomodoroFromOriginal() -> PomodoroState? {
        guard let data = try? Data(contentsOf: originalPomodoroURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let state = PomodoroState()

        func int(_ key: String, fallback: Int) -> Int {
            root[key] as? Int ?? fallback
        }
        func string(_ key: String) -> String? {
            root[key] as? String
        }

        if let raw = root["Phase"] as? Int, let phase = PomodoroPhase(rawValue: raw) {
            state.phase = phase
        }
        if let raw = root["ResumePhase"] as? Int, let phase = PomodoroPhase(rawValue: raw) {
            state.resumePhase = phase
        }
        if let value = string("EndsAt"), let date = ISO8601DateFormatter().date(from: value) {
            state.endsAt = date
        }
        state.pausedRemainingSeconds = int("PausedRemainingSeconds", fallback: 0)
        state.completedFocusSessions = int("CompletedFocusSessions", fallback: 0)
        state.taskName = string("TaskName") ?? state.taskName
        state.focusMinutes = int("FocusMinutes", fallback: 25)
        state.shortBreakMinutes = int("ShortBreakMinutes", fallback: 5)
        state.longBreakMinutes = int("LongBreakMinutes", fallback: 15)
        return state
    }

    // MARK: - 内部

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
