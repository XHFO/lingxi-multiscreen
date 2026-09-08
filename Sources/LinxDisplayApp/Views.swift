import AppKit
import LinxDisplayCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 面板类型

/// 「Beta」小徽标：低对比浅灰标签，标识 Home Assistant / Bambu Lab 实验性功能。
struct BetaBadge: View {
    var body: some View {
        Text("Beta")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Color.secondary.opacity(0.82))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
                    }
            }
            .accessibilityLabel("Beta 测试")
    }
}

/// 该面板是否为实验性功能（Home Assistant / Bambu Lab）
extension Panel {
    var isBeta: Bool {
        self == .homeAssistant || self == .bambuLab || self == .bambuLab2
            || self == .bambuLab3 || self == .bambuLab4 || self == .bambuLab5
            || isFormlabsCard || self == .aiMacScreen || self == .aiMacDashboard
            || self == .aiMacClock || self == .aiMacCustomImage || self == .aiMacControl
            || self == .aiMacCard || self == .aiMacCardManagement
    }

    /// 是否为 Bambu Lab 打印机卡片位（第 1/2/3/4/5 台；显示在键盘设备分组内，
    /// 实体映射与告警在「设备管理」中配置）
    var isBambuCard: Bool {
        self == .bambuLab || self == .bambuLab2 || self == .bambuLab3
            || self == .bambuLab4 || self == .bambuLab5
    }

    /// Bambu 卡片位索引（0..4）；非 Bambu 面板返回 nil
    var bambuSlotIndex: Int? {
        switch self {
        case .bambuLab: return 0
        case .bambuLab2: return 1
        case .bambuLab3: return 2
        case .bambuLab4: return 3
        case .bambuLab5: return 4
        default: return nil
        }
    }

    /// 按卡片位索引取 Bambu 面板（越界返回 nil）
    static func bambuPanel(forSlotIndex i: Int) -> Panel? {
        switch i {
        case 0: return .bambuLab
        case 1: return .bambuLab2
        case 2: return .bambuLab3
        case 3: return .bambuLab4
        case 4: return .bambuLab5
        default: return nil
        }
    }

    var isFormlabsCard: Bool { formlabsSlotIndex != nil }

    var formlabsSlotIndex: Int? {
        switch self {
        case .formlabs: return 0
        case .formlabs2: return 1
        case .formlabs3: return 2
        case .formlabs4: return 3
        case .formlabs5: return 4
        default: return nil
        }
    }

    static func formlabsPanel(forSlotIndex i: Int) -> Panel? {
        switch i {
        case 0: return .formlabs
        case 1: return .formlabs2
        case 2: return .formlabs3
        case 3: return .formlabs4
        case 4: return .formlabs5
        default: return nil
        }
    }
}

enum Panel: String, CaseIterable, Identifiable, Hashable {
    case welcome
    case appearance
    case qwenWork
    case codex
    case pomodoro
    case system
    case nowPlaying
    case customImage
    case canvas
    case excerptQuote
    case sspai
    case emojiWallpaper
    case homeAssistant
    case bambuLab
    case bambuLab2
    case bambuLab3
    case bambuLab4
    case bambuLab5
    case formlabs
    case formlabs2
    case formlabs3
    case formlabs4
    case formlabs5
    case aiMacScreen
    case aiMacDashboard
    case aiMacClock
    case aiMacCustomImage
    case aiMacCard
    case aiMacCardManagement
    case aiMacControl
    case devices
    case buttonControl
    case cardRotation
    case oracleBoardManagement
    case excerptBoardManagement
    case aiMacBoardManagement
    case oracleCanvas
    case excerptCanvas
    case general

    var id: String { rawValue }

    /// 主导航项（外观与设置置于底部）
    static var mainItems: [Panel] {
        [.qwenWork, .codex, .pomodoro, .system, .nowPlaying, .customImage, .canvas,
         .excerptQuote, .sspai, .emojiWallpaper, .homeAssistant,
         .bambuLab, .bambuLab2, .bambuLab3, .bambuLab4, .bambuLab5,
         .formlabs, .formlabs2, .formlabs3, .formlabs4, .formlabs5,
         .devices, .oracleCanvas, .excerptCanvas]
    }

    /// 底部项：外观与设置
    static var bottomItems: [Panel] {
        [.appearance, .general]
    }

    /// 按用户配置的顺序返回主菜单项（仅主菜单项参与排序，外观/设置固定置底；
    /// 空配置 = 默认顺序；未知标识忽略，缺失项按默认顺序补在末尾）
    static func orderedMainItems(_ order: [String]) -> [Panel] {
        let mainIDs = Set(mainItems.map(\.rawValue))
        let keptOrder = order.filter { mainIDs.contains($0) }
        return MenuOrdering
            .ordered(keptOrder, available: mainItems.map(\.rawValue))
            .compactMap(Panel.init(rawValue:))
    }

    /// 独立设备画板（口袋先知/摘录）：单独排序分组，与键盘功能项以分隔线隔开
    static var deviceCanvasItems: [Panel] {
        [.oracleCanvas, .excerptCanvas]
    }

    /// 键盘功能项分组（按用户顺序；设备画板不在此组）
    static func orderedKeyboardItems(_ order: [String]) -> [Panel] {
        let keyboardIDs = Set(mainItems.map(\.rawValue)).subtracting(Set(deviceCanvasItems.map(\.rawValue)))
        return MenuOrdering
            .grouped(orderedMainItems(order).map(\.rawValue), in: keyboardIDs)
            .compactMap(Panel.init(rawValue:))
    }

    /// 设备画板分组（按用户顺序；固定在键盘功能项之后）
    static func orderedCanvasItems(_ order: [String]) -> [Panel] {
        let canvasIDs = Set(deviceCanvasItems.map(\.rawValue))
        return MenuOrdering
            .grouped(orderedMainItems(order).map(\.rawValue), in: canvasIDs)
            .compactMap(Panel.init(rawValue:))
    }

    /// 从显示模式反查面板（设置/外观无对应模式时返回 nil）
    static func from(displayMode: DisplayMode) -> Panel? {
        switch displayMode {
        case .qwenWork: return .qwenWork
        case .codex: return .codex
        case .pomodoro: return .pomodoro
        case .systemMonitor: return .system
        case .nowPlaying: return .nowPlaying
        case .customImage: return .customImage
        case .canvas: return .canvas
        case .excerptQuote: return .excerptQuote
        case .sspai: return .sspai
        case .emojiWallpaper: return .emojiWallpaper
        case .homeAssistant: return .homeAssistant
        case .bambuLab: return .bambuLab
        case .bambuLab2: return .bambuLab2
        case .bambuLab3: return .bambuLab3
        case .bambuLab4: return .bambuLab4
        case .bambuLab5: return .bambuLab5
        case .formlabs: return .formlabs
        case .formlabs2: return .formlabs2
        case .formlabs3: return .formlabs3
        case .formlabs4: return .formlabs4
        case .formlabs5: return .formlabs5
        }
    }

    var title: String {
        switch self {
        case .welcome: return "开始使用"
        case .general: return "设置"
        case .appearance: return "外观"
        case .qwenWork: return "千问办公额度"
        case .codex: return "Codex 用量"
        case .pomodoro: return "番茄钟"
        case .system: return "系统监控"
        case .nowPlaying: return "正在播放"
        case .customImage: return "自定义图片"
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
        case .aiMacScreen: return "AI Mac 画板"
        case .aiMacDashboard: return "系统仪表盘"
        case .aiMacClock: return "桌面时钟"
        case .aiMacCustomImage: return "自定义图片"
        case .aiMacCard: return "功能卡片"
        case .aiMacCardManagement: return "卡片管理"
        case .aiMacControl: return "屏幕控制"
        case .devices: return "设备管理"
        case .buttonControl: return "按键控制"
        case .cardRotation: return "卡片管理"
        case .oracleBoardManagement: return "口袋先知画板管理"
        case .excerptBoardManagement: return "摘录画板管理"
        case .aiMacBoardManagement: return "AI Mac 画板管理"
        case .oracleCanvas: return "口袋先知画板"
        case .excerptCanvas: return "摘录画板"
        }
    }

    var icon: String {
        switch self {
        case .welcome: return "shippingbox"
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .qwenWork: return "creditcard"
        case .codex: return "terminal"
        case .pomodoro: return "timer"
        case .system: return "gauge"
        case .nowPlaying: return "music.note"
        case .customImage: return "photo"
        case .canvas: return "rectangle.3.group"
        case .excerptQuote: return "text.quote"
        case .sspai: return "newspaper"
        case .emojiWallpaper: return "face.smiling"
        case .homeAssistant: return "house"
        case .bambuLab, .bambuLab2, .bambuLab3, .bambuLab4, .bambuLab5,
             .formlabs, .formlabs2, .formlabs3, .formlabs4, .formlabs5: return "printer"
        case .aiMacScreen: return "rectangle.stack"
        case .aiMacDashboard: return "gauge.with.dots.needle.50percent"
        case .aiMacClock: return "clock"
        case .aiMacCustomImage: return "photo"
        case .aiMacCard: return "square.grid.2x2"
        case .aiMacCardManagement: return "tray.full"
        case .aiMacControl: return "slider.horizontal.3"
        case .devices: return "externaldrive"
        case .buttonControl: return "appletvremote.gen4"
        case .cardRotation: return "tray.full"
        case .oracleBoardManagement: return "rectangle.stack"
        case .excerptBoardManagement: return "rectangle.stack"
        case .aiMacBoardManagement: return "rectangle.stack"
        case .oracleCanvas: return "sparkles"
        case .excerptCanvas: return "quote.opening"
        }
    }

    /// 选择该面板时对应的显示模式（设置/外观/设备管理/按键控制/独立画板/开始使用无对应键盘显示模式）
    var displayMode: DisplayMode? {
        switch self {
        case .welcome, .general, .appearance: return nil
        case .oracleCanvas, .excerptCanvas, .devices, .buttonControl, .aiMacScreen,
             .aiMacDashboard, .aiMacClock, .aiMacCustomImage,
             .aiMacCard, .aiMacCardManagement, .aiMacControl,
             .cardRotation, .oracleBoardManagement, .excerptBoardManagement,
             .aiMacBoardManagement: return nil
        case .qwenWork: return .qwenWork
        case .codex: return .codex
        case .pomodoro: return .pomodoro
        case .system: return .systemMonitor
        case .nowPlaying: return .nowPlaying
        case .customImage: return .customImage
        case .canvas: return .canvas
        case .excerptQuote: return .excerptQuote
        case .sspai: return .sspai
        case .emojiWallpaper: return .emojiWallpaper
        case .homeAssistant: return .homeAssistant
        case .bambuLab: return .bambuLab
        case .bambuLab2: return .bambuLab2
        case .bambuLab3: return .bambuLab3
        case .bambuLab4: return .bambuLab4
        case .bambuLab5: return .bambuLab5
        case .formlabs: return .formlabs
        case .formlabs2: return .formlabs2
        case .formlabs3: return .formlabs3
        case .formlabs4: return .formlabs4
        case .formlabs5: return .formlabs5
        }
    }
}

// MARK: - 拖拽排序放置委托

/// 放置位置：插到某行之前，或移动到末尾
private enum ReorderPlacement<Item> {
    case before(Item)
    case end
}

/// 实时排序拖放委托：拖入目标行/末尾槽时立即把被拖项移到对应位置（带动画），
/// 只更新本地列表，松手后统一通过 commit 提交设置。
private struct ReorderDropDelegate<Item: Equatable>: DropDelegate {
    let placement: ReorderPlacement<Item>
    @Binding var dragged: Item?
    @Binding var items: [Item]?
    let commit: ([Item]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged, var list = items, list.contains(dragged) else { return }
        switch placement {
        case .before(let target):
            guard dragged != target else { return }
            list.removeAll { $0 == dragged }
            if let index = list.firstIndex(of: target) {
                list.insert(dragged, at: index)
            } else {
                list.append(dragged)
            }
        case .end:
            list.removeAll { $0 == dragged }
            list.append(dragged)
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            items = list
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let final = items
        dragged = nil
        items = nil
        if let final { commit(final) }
        return true
    }
}

/// 列表空白处的兜底放置委托：不做位置移动，仅在空白处松手时提交当前拖拽结果，
/// 避免落在行间空隙时静默还原。
private struct CommitDropDelegate<Item: Equatable>: DropDelegate {
    @Binding var dragged: Item?
    @Binding var items: [Item]?
    let commit: ([Item]) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let final = items
        dragged = nil
        items = nil
        if let final { commit(final) }
        return true
    }
}

/// 排序列表的公共结构：行列表（加大间距/行高并恢复分隔线）+ 末尾放置槽 + 空白兜底放置
@ViewBuilder
private func reorderList<Item: Identifiable & Equatable, Row: View>(
    items: [Item],
    dragged: Binding<Item?>,
    dragItems: Binding<[Item]?>,
    commit: @escaping ([Item]) -> Void,
    @ViewBuilder row: @escaping (Item) -> Row
) -> some View {
    VStack(spacing: 8) {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            VStack(spacing: 0) {
                row(item)
                    .padding(.vertical, 6)
                if index < items.count - 1 {
                    Divider()
                        .padding(.leading, 30)
                }
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle().inset(by: -8))
            .onDrop(of: [.text], delegate: ReorderDropDelegate(
                placement: .before(item),
                dragged: dragged,
                items: dragItems,
                commit: commit))
        }
        Text("拖到此处移动到末尾")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.3),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .padding(.horizontal, 2)
            )
            .contentShape(Rectangle().inset(by: -12))
            .onDrop(of: [.text], delegate: ReorderDropDelegate(
                placement: .end,
                dragged: dragged,
                items: dragItems,
                commit: commit))
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle().inset(by: -10))
    .onDrop(of: [.text], delegate: CommitDropDelegate(
        dragged: dragged,
        items: dragItems,
        commit: commit))
}

// MARK: - 主面板：左侧可收缩侧栏 + 中间设置 + 右侧实时预览

/// Dot Image API 获取说明文档（摘录设备 API Key / 序列号帮助图标跳转）
private let dotImageAPIDocsURL = URL(string: "https://dot.mindreset.tech/docs/service/open/image_api")!
/// Rand/0 显示模式官方文档（先知设备 IP 帮助图标跳转）
private let rand0DisplayModeDocsURL = URL(string: "https://dot.mindreset.tech/docs/rand_0/start/features/display_mode")!
private let formlabsDeveloperDocsURL = URL(string: "https://formlabs.com/support/Formlabs-Developer-Platform-overview/")!

struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// NavigationSplitView 侧栏列可见性
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selected: Panel
    @State private var showClearHistoryConfirm = false
    @State private var expandedModule: CanvasModule?
    // 拖拽排序状态：拖动中仅更新本地列表，松手后统一提交设置
    @State private var draggedModule: CanvasModule?
    @State private var dragModules: [CanvasModule]?
    @State private var draggedPanel: Panel?
    @State private var dragPanels: [Panel]?
    @State private var dragCanvasPanels: [Panel]?
    /// 卡片管理拖拽排序状态（拖动中仅更新本地列表，松手统一提交）
    @State private var draggedCardPanel: Panel?
    @State private var dragCardPanels: [Panel]?
    @State private var draggedHAEntity: HAEntityRef?
    @State private var dragHAEntities: [HAEntityRef]?
    /// Bambu 打印机自动匹配输入草稿（key = 设备ID-打印机索引）
    @State private var bambuMatchDrafts: [String: String] = [:]
    /// 彩蛋：连续点击告警标题次数（5 次触发所有打印机报错预览）
    @State private var alertTitleTapCount = 0
    @State private var showPrinterAlertPreview = false
    /// HA 实体自定义显示名称编辑（正在编辑的实体 id 与草稿）
    @State private var editingAliasEntityID: String?
    @State private var aliasDraft = ""
    /// 设备连接字段的输入草稿（填写后需点「应用」才生效，避免输入中途被误用/误改）
    /// 键为「设备ID#字段名」复合键：同一设备可能有多个连接字段（摘录的 API Key 与序列号），
    /// 共用一个草稿槽会导致两个输入框互相串内容
    @State private var connectionDrafts: [String: String] = [:]
    /// 口袋先知多画板拖拽排序状态（拖动中仅更新本地列表，松手统一提交）
    @State private var draggedBoard: OracleCanvasBoard?
    @State private var dragBoards: [OracleCanvasBoard]?
    @State private var draggedExcerptBoard: ExcerptCanvasBoard?
    @State private var dragExcerptBoards: [ExcerptCanvasBoard]?
    @State private var draggedAIMacBoard: AIMacCanvasBoard?
    @State private var dragAIMacBoards: [AIMacCanvasBoard]?
    @State private var draggedAIMacCard: DisplayMode?
    @State private var dragAIMacCards: [DisplayMode]?
    /// 待删除的设备（非 nil 时弹出二次确认）
    @State private var deviceToDelete: ManagedDevice?
    /// 设备管理默认只读；只有用户明确点“编辑”的设备才开放输入、开关与操作按钮。
    @State private var editingDeviceIDs: Set<UUID> = []
    /// 恢复初始设定两步确认：第一步说明清除范围，第二步最终确认
    @State private var showResetConfirm1 = false
    @State private var showResetConfirm2 = false
    /// 待重命名的先知画板（非 nil 时弹出重命名输入框）
    @State private var boardRenameTarget: OracleCanvasBoard?
    @State private var boardRenameDraft = ""
    @State private var excerptBoardRenameTarget: ExcerptCanvasBoard?
    @State private var excerptBoardRenameDraft = ""
    @State private var aiMacBoardRenameTarget: AIMacCanvasBoard?
    @State private var aiMacBoardRenameDraft = ""
    /// 全局快捷键录制：正在录制的动作（nil = 未录制）与本地按键监听器
    @State private var recordingShortcutAction: GlobalHotkeyManager.Action?
    @State private var recordingMonitor: Any?
    /// 恢复初始快捷键确认 / 快捷键冲突提示
    @State private var showRestoreShortcutsConfirm = false
    @State private var showRestorePageShortcutsConfirm = false
    @State private var showShortcutConflict = false
    @State private var shortcutConflictText = ""
    /// 版本更新日志：已展开的版本号集合（默认仅展开当前版本，旧版本收起为精简列表）
    @State private var expandedReleaseNotes: Set<String>
    /// 版本更新日志整体入口是否展开（默认收起，设置页主体保持一行入口不被撑长）
    @State private var showVersionLog = false
    /// Home Assistant 连接测试结果与进行中状态
    @State private var haTestResult = ""
    @State private var haTesting = false
    /// 用户主动展开「添加 Home Assistant 服务器」表单（未配置服务器时默认只显示入口按钮）
    @State private var haSetupVisible = false
    /// 添加服务器时填写的长期访问令牌草稿
    @State private var haTokenDraft = ""
    /// AI Mac 小屏幕固件刷写必须由用户二次确认；记录完成后是否顺便创建设备档案。
    @State private var showAIMacFlashConfirmation = false
    @State private var aiMacFlashShouldAddDevice = true
    @State private var showAIMacFlashLog = false
    @State private var aiMacProvisionSSID = ""
    @State private var aiMacProvisionPassword = ""
    @State private var showAIMacFlashResult = false
    @State private var aiMacFlashResultSucceeded = false
    @State private var aiMacFlashResultMessage = ""

    init(model: AppModel) {
        self.model = model
        // 版本日志默认展开当前版本（最新一条），历史版本折叠
        _expandedReleaseNotes = State(initialValue: Set(ReleaseNotes.all.prefix(1).map(\.id)))
        // 首次使用（无任何设备）直接进入「开始使用」引导页；已有设备时跟随当前显示模式
        if DeviceOnboardingPolicy.shouldShow(for: model.settings.devices) {
            _selected = State(initialValue: .welcome)
        } else {
            _selected = State(initialValue: Panel.from(displayMode: model.settings.displayMode) ?? .general)
        }
    }

    var body: some View {
        mainContent
            .alert("恢复初始设定？", isPresented: $showResetConfirm1) {
                Button("取消", role: .cancel) {}
                Button("继续", role: .destructive) { showResetConfirm2 = true }
            } message: {
                Text("将清除软件的全部信息：已添加的设备档案、自定义内容（画板/卡片/图片/文字/主题等所有设置），以及自定义图片缓存。恢复后软件回到首次启动状态。")
            }
            .alert("再次确认：此操作不可撤销", isPresented: $showResetConfirm2) {
                Button("取消", role: .cancel) {}
                Button("恢复初始设定", role: .destructive) {
                    model.resetToFactoryDefaults()
                }
            } message: {
                Text("即将清除全部 \(model.settings.devices.count) 台设备、所有自定义内容与图片缓存（数据会移入废纸篓），并恢复为首次启动状态。确认执行吗？")
            }
            .alert("快捷键冲突", isPresented: $showShortcutConflict) {
                Button("好", role: .cancel) {}
            } message: {
                Text(shortcutConflictText)
            }
            .confirmationDialog(
                "确认刷入 AI Mac 小屏幕固件？",
                isPresented: $showAIMacFlashConfirmation,
                titleVisibility: .visible
            ) {
                Button(aiMacFlashShouldAddDevice ? "刷入并添加设备" : "仅刷入固件") {
                    let shouldAdd = aiMacFlashShouldAddDevice
                    let ssid = aiMacProvisionSSID
                    let password = aiMacProvisionPassword
                    Task {
                        let flashed = await model.flashAIMacFirmware(
                            addDeviceAfterSuccess: shouldAdd, ssid: ssid, password: password)
                        if flashed { aiMacProvisionPassword = "" }
                        aiMacFlashResultSucceeded = flashed
                        aiMacFlashResultMessage = model.aiMacFlashStatus
                        showAIMacFlashResult = true
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("刷写会覆盖所选 ESP8266 小屏幕中的现有固件，并写入 Wi-Fi“\(aiMacProvisionSSID)”。ESP8266 仅支持 2.4 GHz，请确认该网络已开启 2.4 GHz；完成前不要拔掉 USB 数据线。")
            }
            .alert(aiMacFlashResultSucceeded ? "刷写流程完成" : "刷写失败",
                   isPresented: $showAIMacFlashResult) {
                Button("好", role: .cancel) {}
            } message: {
                Text(aiMacFlashResultMessage)
            }
    }

    /// 独立设备画板页面自带设备预览，隐藏键盘小屏实时预览
    private var isDeviceCanvasPanel: Bool {
        selected == .oracleCanvas || selected == .excerptCanvas || selected == .aiMacScreen
            || selected == .aiMacDashboard || selected == .aiMacClock
            || selected == .aiMacCustomImage || selected == .aiMacCard
    }

    /// 不显示右侧键盘小屏实时预览的面板：两个独立画板（自带设备预览）、设备管理、设置、开始使用；
    /// 无设备时一律不显示预览（引导页/设备管理阶段无需预览）；按键控制页只有被控目标是灵犀68 键盘时才显示键盘预览
    private var hidesPreviewPanel: Bool {
        if model.settings.devices.isEmpty { return true }
        switch selected {
        case .oracleCanvas, .excerptCanvas, .oracleBoardManagement, .aiMacScreen,
             .aiMacDashboard, .aiMacClock, .aiMacCustomImage,
             .aiMacCard, .aiMacCardManagement, .aiMacControl,
             .excerptBoardManagement, .aiMacBoardManagement,
             .devices, .general:
            return true
        case .buttonControl:
            return model.settings.rand0ButtonTarget != .keyboard
                || model.settings.rand0ButtonTargetDeviceID == nil
        default:
            return false
        }
    }

    /// 无设备时可正常使用的面板（设备管理 / 外观 / 设置）
    private func worksWithoutDevices(_ panel: Panel) -> Bool {
        panel == .devices || panel == .appearance || panel == .general
    }

    /// 首次使用/已删光全部设备时的引导页：引导用户到设备管理添加设备
    private var emptyDevicesOnboarding: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("尚未添加任何设备")
                .font(.title3.weight(.semibold))
            Text("先在「设备管理」中添加你的设备（灵犀68 键盘 / 口袋先知 / 摘录），添加后即可在左侧导航中配置各设备的卡片与画板。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("前往设备管理添加设备") {
                selected = .devices
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var mainContent: some View {
        GeometryReader { geo in
            // 详情区所需宽度：主内容最小 380 + 分隔线 + 预览面板 210（隐藏预览的面板只需 380）。
            // 侧栏列最大宽度随窗口宽度动态收缩，保证详情区永远放得下——
            // 预览面板任何窗口尺寸下都完整展示、绝不被裁切（与旧版自适应行为一致）
            let previewNeed: CGFloat = hidesPreviewPanel ? 0 : PreviewPanel.preferredWidth(forHeight: geo.size.height)
            let detailNeed: CGFloat = 380 + previewNeed + 2
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarColumn(windowWidth: geo.size.width)
                    // 图标模式最窄 82
                    .navigationSplitViewColumnWidth(min: 82,
                                                    ideal: CGFloat(model.settings.sidebarWidth),
                                                    max: max(82, min(320, geo.size.width - detailNeed)))
            } detail: {
                detailColumn
            }
            .onChange(of: selected) { newValue in
                if let mode = newValue.displayMode {
                    model.setMode(mode)
                }
                if newValue == .devices {
                    Task { await model.ensureBambuEntityCatalog() }
                }
                // 两个独立画板均为双栏布局（左主内容 + 右侧边栏）：
                // 窗口不够宽时自动放大到能完整显示，避免用户看不到右侧边栏
                if newValue == .excerptCanvas || newValue == .oracleCanvas {
                    ensureDeviceCanvasWindowWidth()
                }
            }
            // 卡片自动轮换等外部改变 displayMode 时，侧栏选中项跟随同步；
            // 但自动轮换开启时键盘按轮换池循环推送，侧栏不跟随（避免用户操作中途界面被切走）。
            // 关闭自动轮换后，点击侧栏项才会切换显示。
            .onChange(of: model.settings.displayMode) { newMode in
                if model.settings.cardRotationEnabled { return }
                if let panel = Panel.from(displayMode: newMode), panel != selected {
                    selected = panel
                }
            }
            // 切换操作设备时丢弃进行中的拖拽临时列表：否则上一台键盘的排序可能被提交到新设备
            .onChange(of: model.activeDeviceID(for: .keyboard)) { _ in
                dragPanels = nil
                dragCanvasPanels = nil
                dragCardPanels = nil
                draggedCardPanel = nil
            }
            .onChange(of: model.activeDeviceID(for: .oracle)) { _ in
                dragBoards = nil
                draggedBoard = nil
            }
            .onChange(of: model.activeDeviceID(for: .excerpt)) { _ in
                dragExcerptBoards = nil
                draggedExcerptBoard = nil
            }
            .onChange(of: model.activeDeviceID(for: .aiMacScreen)) { _ in
                dragAIMacBoards = nil
                draggedAIMacBoard = nil
                dragModules = nil
                draggedModule = nil
                dragAIMacCards = nil
                draggedAIMacCard = nil
            }
        }
    }

    /// 侧栏列内容：列宽被压到图标条宽度（≤96）时自动切换为窄图标栏
    private func sidebarColumn(windowWidth: CGFloat) -> some View {
        GeometryReader { geo in
            Group {
                if geo.size.width <= 96 {
                    MiniSidebar(selection: $selected, model: model)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    Sidebar(selection: $selected, model: model)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // 跨越 96pt 模式切换阈值时用带弹跳的 spring 衔接（跳入/跳出感），拖拽过程本身不逐帧动画
            .animation(.spring(response: 0.32, dampingFraction: 0.6), value: geo.size.width <= 96)
            .onChange(of: geo.size.width) { newWidth in
                persistSidebarWidth(newWidth, windowWidth: windowWidth)
            }
        }
    }

    /// 用户拖拽系统分隔条调整侧栏宽度后，回写持久化设置：
    /// 窗口不够宽时系统会把侧栏列压窄给内容让位——不要把被压缩的结果持久化，
    /// 否则窗口拉回原宽后侧栏回不到用户设定的宽度
    private func persistSidebarWidth(_ width: CGFloat, windowWidth: CGFloat) {
        guard width > 96 else { return } // 图标条模式下宽度由窗口决定，不持久化
        let detailBudget: CGFloat = 380 + (hidesPreviewPanel ? 0 : 210)
        guard windowWidth - width >= detailBudget else { return } // 列正被系统压缩中
        let w = Int(width.rounded())
        guard abs(w - model.settings.sidebarWidth) >= 2 else { return }
        model.noteSidebarResize() // 进入批处理模式 + 防抖提交（拖拽过程中跳过逐帧持久化/预览渲染）
        model.setSidebarWidth(w)
    }

    /// 详情列：顶部栏 + 主内容滚动区 + 实时预览面板
    private var detailColumn: some View {
        HStack(spacing: 0) {
            // 两个独立画板均为双栏（主内容 + 右侧边栏）：窗口自动放大容纳，保持纯纵向滚动
            // （横向滚动会干扰右侧边栏 TextField 的键盘焦点：Cmd+V/Tab 失效）
            VStack(spacing: 0) {
                headerBar
                Divider()
                ScrollView([.vertical]) {
                    if model.settings.devices.isEmpty && !worksWithoutDevices(selected) {
                        emptyDevicesOnboarding
                    } else if selected == .excerptCanvas {
                        excerptCanvasForm // 摘录画板：主内容 + 右侧设备边栏两栏布局
                    } else if selected == .oracleCanvas {
                        oracleCanvasForm // 口袋先知画板：主内容 + 右侧预览边栏两栏布局
                    } else if selected == .aiMacScreen {
                        aiMacScreenForm
                    } else if selected == .aiMacDashboard {
                        aiMacStandaloneModeForm(.dashboard)
                    } else if selected == .aiMacClock {
                        aiMacStandaloneModeForm(.clock)
                    } else if selected == .aiMacCustomImage {
                        aiMacStandaloneModeForm(.customImage)
                    } else if selected == .aiMacCard {
                        aiMacCardForm
                    } else if selected == .aiMacCardManagement {
                        aiMacCardManagementForm
                    } else if selected == .oracleBoardManagement {
                        oracleBoardManagementForm
                    } else if selected == .excerptBoardManagement {
                        excerptBoardManagementForm
                    } else if selected == .aiMacBoardManagement {
                        aiMacBoardManagementForm
                    } else if selected == .aiMacControl {
                        aiMacControlForm
                    } else {
                        Form { panelContent(for: selected) }
                            .formStyle(.grouped)
                            .padding(.bottom, 12)
                    }
                }
                .scrollContentBackground(.hidden)
                // 面板切换时重建滚动视图，确保每次打开都从页面顶部开始（不继承上一面板的滚动位置）
                .id(selected)
            }
            .frame(minWidth: 300, maxWidth: .infinity) // 空间不足时中间区先让位，预览保持完整

            if !hidesPreviewPanel {
                Divider()
                PreviewPanel(model: model) // 宽度按面板自身高度×设备外观比例反推，四边留白固定
            }
        }
        .sheet(isPresented: $showPrinterAlertPreview) {
            PrinterAlertPreviewSheet(model: model)
        }
    }

    /// 独立画板（先知/摘录）双栏布局所需的最小窗口宽度；窗口更窄时自动放大（只放大不缩小，不超出屏幕）
    private func ensureDeviceCanvasWindowWidth() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.titleVisibility == .hidden }) else {
            return
        }
        let target: CGFloat = 1280
        let maxWidth = (window.screen?.visibleFrame.width ?? target) - 40
        let width = min(target, max(maxWidth, window.frame.width))
        guard window.frame.width < width else { return }
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: 顶部栏（收起态才出现的展开按钮 + 标题 + 状态）

    private var headerBar: some View {
        HStack(spacing: 10) {
            // 展开按钮只在侧栏收起后才出现（滑动+淡入动画，不突兀）；
            // 展开态详情页不放按钮——折叠操作在侧栏右上角
            if columnVisibility == .detailOnly {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { columnVisibility = .all }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("展开侧边栏")
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            HStack(spacing: 6) {
                Text(model.settings.devices.isEmpty && !worksWithoutDevices(selected)
                     ? "开始使用"
                     : selected == .oracleCanvas ? model.oracleCanvasBoardName
                     : selected == .excerptCanvas ? model.excerptCanvasBoardName
                     : selected == .aiMacScreen ? model.aiMacCanvasBoardName
                     : selected == .aiMacCard ? model.activeDeviceID(for: .aiMacScreen)
                        .map { model.aiMacScreenSettings(for: $0).cardMode.title } ?? selected.title
                     : selected.title)
                    .font(.headline)
                if selected.isBeta {
                    BetaBadge()
                }
            }

            Spacer()

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12) // 收起后系统自动把本行下移到红绿灯下方，无需再避让
        .padding(.top, 14) // 沉浸式标题栏留白
        .padding(.bottom, 8)
    }

    // MARK: 各面板内容

    @ViewBuilder
    private func panelContent(for panel: Panel) -> some View {
        switch panel {
        case .welcome: EmptyView() // 开始使用引导页由 detailColumn 的空设备状态渲染，此处无需内容
        case .general: generalForm
        case .appearance: appearanceForm
        case .qwenWork: qwenWorkForm
        case .codex: codexForm
        case .pomodoro: pomodoroForm
        case .system: systemForm
        case .nowPlaying: nowPlayingForm
        case .customImage: customImageForm
        case .canvas: canvasForm
        case .excerptQuote: excerptQuoteForm
        case .sspai: sspaiForm
        case .emojiWallpaper: emojiWallpaperForm
        case .homeAssistant: homeAssistantForm
        case .bambuLab, .bambuLab2, .bambuLab3, .bambuLab4, .bambuLab5: bambuLabForm(for: panel)
        case .formlabs, .formlabs2, .formlabs3, .formlabs4, .formlabs5: formlabsForm(for: panel)
        case .aiMacScreen: aiMacScreenForm
        case .aiMacDashboard: aiMacStandaloneModeForm(.dashboard)
        case .aiMacClock: aiMacStandaloneModeForm(.clock)
        case .aiMacCustomImage: aiMacStandaloneModeForm(.customImage)
        case .aiMacCard: aiMacCardForm
        case .aiMacCardManagement: aiMacCardManagementForm
        case .aiMacControl: aiMacControlForm
        case .devices: devicesForm
        case .buttonControl: buttonControlForm
        case .cardRotation: cardRotationForm
        case .oracleBoardManagement: oracleBoardManagementForm
        case .excerptBoardManagement: excerptBoardManagementForm
        case .aiMacBoardManagement: aiMacBoardManagementForm
        case .oracleCanvas: oracleCanvasForm
        case .excerptCanvas: excerptCanvasForm
        }
    }

    /// 设备连接字段：草稿输入 + 「应用」确认（点应用才写入设备并生效，避免误改/输入中途生效）
    @ViewBuilder
    private func deviceConnectionField(_ deviceID: UUID, label: String,
                                       binding: Binding<String>,
                                       fieldWidth: CGFloat? = nil,
                                       helpText: String? = nil,
                                       helpURL: URL? = nil) -> some View {
        HStack(spacing: 6) {
            draftField(key: "\(deviceID.uuidString)#\(label)", label: label,
                       binding: binding, fieldWidth: fieldWidth)
            if let helpText, let helpURL {
                HelpIcon(text: helpText, linkURL: helpURL)
            } else if let helpText {
                HelpIcon(text: helpText)
            }
        }
    }

    private var aiMacScreenForm: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                if let device = model.activeDevice(for: .aiMacScreen) {
                    let config = model.aiMacScreenSettings(for: device.id)
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.stack")
                                .foregroundStyle(Color.accentColor)
                            Text(config.mode == .canvas
                                 ? model.aiMacCanvasBoardName : config.mode.title)
                                .font(.headline)
                            Spacer()
                            Text(device.name).foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack(spacing: 4) {
                            Text("当前画板")
                            HelpIcon(text: "本页编辑当前 AI Mac 彩色画板的模块。画板创建、排序、显示和自动轮换在“AI Mac 画板管理”中设置。")
                        }
                    }

                    if config.mode == .canvas {
                        if config.canvasBoards.isEmpty {
                            Section {
                                Text("尚未创建画板。新画板从空白“未命名”状态开始，添加第一个模块后自动命名。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("创建新的画板") { model.addAIMacCanvasBoard() }
                            }
                        } else {
                            canvasModuleEditor(owner: .aiMac,
                                               modulesRaw: model.aiMacCanvasModules.map(\.rawValue),
                                               moduleList: dragModules ?? model.aiMacCanvasModules,
                                               available: availableCanvasModules(CanvasModule.oraclePanelModules))
                        }
                    } else if config.mode == .customImage {
                        Section("自定义图片") {
                            HStack {
                                Button("选择图片…") {
                                    model.chooseAIMacScreenImage(deviceID: device.id)
                                }
                                Spacer()
                                Text(config.customImagePath.map {
                                    URL(fileURLWithPath: $0).lastPathComponent
                                } ?? "尚未选择")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Section {
                            Text("这是旧版独立显示模式。可在“AI Mac 画板管理”中切回画板模式，将时钟、系统监控等内容作为模块自由组合。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        Text("请先在“设备管理”中添加并启用 AI Mac 小屏幕。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, alignment: .top)

            Divider().padding(.vertical, 4)

            Form {
                Section {
                    HStack {
                        Spacer()
                        aiMacPreview
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    Text("彩色原始画面即为实际推送效果，不进行黑白转换、灰阶抖动或墨水屏插值处理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    HStack(spacing: 4) {
                        Text("240 × 240 彩色预览")
                        HelpIcon(text: "预览与设备收到的 240×240 彩色像素内容一致；RGB565 固件使用无损帧传输。")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 300)
        }
        .padding(.bottom, 12)
        .onAppear {
            if let id = model.activeDeviceID(for: .aiMacScreen) {
                model.refreshAIMacScreenPreview(deviceID: id)
            }
        }
    }

    /// AI Mac 固定内容使用各自的独立页面；设备切换后所有设置、预览和推送目标
    /// 都来自当前侧栏分组对应的设备，不复用其他小屏幕状态。
    private func aiMacStandaloneModeForm(_ mode: AIMacScreenContentMode) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                if let device = model.activeDevice(for: .aiMacScreen) {
                    let config = model.aiMacScreenSettings(for: device.id)
                    Section {
                        LabeledContent("设备", value: device.name)
                        LabeledContent("显示内容", value: mode.title)
                    } header: {
                        HStack(spacing: 4) {
                            Text(mode.title)
                            HelpIcon(text: "此页面只控制侧边栏当前小屏幕，其他 AI Mac 设备拥有独立的显示内容、图片、画板和推送设置。")
                        }
                    }

                    if mode == .customImage {
                        Section("图片") {
                            Button("选择图片…") {
                                model.chooseAIMacScreenImage(deviceID: device.id)
                            }
                            Text(config.customImagePath.map {
                                URL(fileURLWithPath: $0).lastPathComponent
                            } ?? "尚未选择图片")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } else if mode == .dashboard {
                        Section {
                            Text("显示 CPU、内存、磁盘、网络和当前时间；数据在该设备的推送时刻重新采样。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else if mode == .clock {
                        Section {
                            Text("显示适配 240 × 240 彩屏的桌面时钟与日期。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        Button("立即推送到这台设备") {
                            Task { await model.pushAIMacScreen(deviceID: device.id, force: true) }
                        }
                        .keyboardShortcut(.return, modifiers: [.command])
                        if model.aiMacScreenBusyIDs.contains(device.id) {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.aiMacScreenStatuses[device.id] ?? "等待连接小屏幕")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text("请先在设备管理中添加并启用 AI Mac 小屏幕。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, alignment: .top)

            Divider().padding(.vertical, 4)

            Form {
                Section {
                    HStack {
                        Spacer()
                        aiMacPreview
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("240 × 240 彩色预览")
                }
            }
            .formStyle(.grouped)
            .frame(width: 300)
        }
        .padding(.bottom, 12)
        .onAppear {
            if let id = model.activeDeviceID(for: .aiMacScreen) {
                model.activateAIMacScreenMode(mode, deviceID: id)
            }
        }
    }

    /// 统一卡片页面：左侧直接复用同一张功能卡片的设置组件，右侧使用目标设备原生
    /// 240×240 预览。修改设置不会切换灵犀 68 当前页面。
    private var aiMacCardForm: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                if let device = model.activeDevice(for: .aiMacScreen) {
                    let config = model.aiMacScreenSettings(for: device.id)
                    Section {
                        LabeledContent("设备", value: device.name)
                        LabeledContent("功能卡片", value: config.cardMode.title)
                    } header: {
                        HStack(spacing: 4) {
                            Text(config.cardMode.title)
                            HelpIcon(text: "卡片设置由所有兼容设备共用；这台小屏幕的当前卡片、侧栏顺序和轮播列表则单独保存。")
                        }
                    }

                    aiMacCardSettings(for: config.cardMode, deviceID: device.id)

                    Section {
                        Button("立即推送到这台设备") {
                            Task { await model.pushAIMacScreen(deviceID: device.id, force: true) }
                        }
                        .keyboardShortcut(.return, modifiers: [.command])
                        if model.aiMacScreenBusyIDs.contains(device.id) {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.aiMacScreenStatuses[device.id] ?? "等待连接小屏幕")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section { Text("请先在设备管理中添加并启用 AI Mac 小屏幕。") }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, alignment: .top)

            Divider().padding(.vertical, 4)

            Form {
                Section {
                    HStack { Spacer(); aiMacPreview; Spacer() }
                        .padding(.vertical, 8)
                } header: { Text("240 × 240 彩色预览") }
            }
            .formStyle(.grouped)
            .frame(width: 300)
        }
        .padding(.bottom, 12)
        .onAppear {
            if let id = model.activeDeviceID(for: .aiMacScreen) {
                let mode = model.aiMacScreenSettings(for: id).cardMode
                model.activateAIMacCard(mode, deviceID: id)
            }
        }
    }

    @ViewBuilder
    private func aiMacCardSettings(for mode: DisplayMode, deviceID: UUID) -> some View {
        switch mode {
        case .customImage:
            Section("图片") {
                Button("选择图片…") { model.chooseAIMacScreenImage(deviceID: deviceID) }
                Text(model.aiMacScreenSettings(for: deviceID).customImagePath.map {
                    URL(fileURLWithPath: $0).lastPathComponent
                } ?? "尚未选择图片")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        case .qwenWork: qwenWorkForm
        case .codex: codexForm
        case .pomodoro: pomodoroForm
        case .systemMonitor: systemForm
        case .nowPlaying:
            VStack(alignment: .leading, spacing: 10) {
                nowPlayingForm
                linkedLyricsKeyboardPicker(owner: .aiMac)
            }
        case .excerptQuote: excerptQuoteForm
        case .sspai: sspaiForm
        case .emojiWallpaper: emojiWallpaperForm
        case .homeAssistant: homeAssistantForm
        case .bambuLab: bambuLabForm(for: .bambuLab)
        case .bambuLab2: bambuLabForm(for: .bambuLab2)
        case .bambuLab3: bambuLabForm(for: .bambuLab3)
        case .bambuLab4: bambuLabForm(for: .bambuLab4)
        case .bambuLab5: bambuLabForm(for: .bambuLab5)
        case .formlabs: formlabsForm(for: .formlabs)
        case .formlabs2: formlabsForm(for: .formlabs2)
        case .formlabs3: formlabsForm(for: .formlabs3)
        case .formlabs4: formlabsForm(for: .formlabs4)
        case .formlabs5: formlabsForm(for: .formlabs5)
        case .canvas: EmptyView()
        }
    }

    /// AI Mac 卡片管理与灵犀 68 使用同一种交互，但所有状态写入当前小屏幕设备快照。
    private var aiMacCardManagementForm: some View {
        Form {
            if let device = model.activeDevice(for: .aiMacScreen) {
                let config = model.aiMacScreenSettings(for: device.id)
                Section {
                    LabeledContent("正在管理", value: device.name)
                }
                Section("自动轮播") {
                    Toggle("卡片页面自动轮播",
                           isOn: model.aiMacCardRotationBinding(for: device.id))
                    if config.cardRotationEnabled {
                        HStack {
                            Text("轮换间隔")
                            Spacer()
                            Text(Self.rotationIntervalText(config.cardRotationMinutes))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: model.aiMacCardRotationMinutesBinding(for: device.id),
                               in: 1...60, step: 1)
                    }
                }
                Section {
                    let cards = dragAIMacCards ?? model.aiMacCardList(for: device.id)
                    if cards.isEmpty {
                        Text("尚未添加卡片，从下方添加。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        reorderList(items: cards,
                                    dragged: $draggedAIMacCard,
                                    dragItems: $dragAIMacCards,
                                    commit: { model.commitAIMacCardOrder($0, deviceID: device.id) }) { mode in
                            aiMacCardManagementRow(mode, deviceID: device.id)
                        }
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("卡片（拖拽排序）")
                        HelpIcon(text: "排序同时决定侧栏顺序；轮换开关决定该卡片是否加入当前小屏幕的自动轮播。")
                    }
                }
                let hidden = model.aiMacHiddenCardList(for: device.id)
                if !hidden.isEmpty {
                    Section("添加到侧栏") {
                        ForEach(hidden) { mode in
                            Button { model.setAIMacCardVisible(mode, visible: true, deviceID: device.id) } label: {
                                HStack {
                                    Image(systemName: mode.icon).frame(width: 18)
                                    Text(mode.title)
                                    Spacer()
                                    Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 12)
    }

    private func aiMacCardManagementRow(_ mode: DisplayMode, deviceID: UUID) -> some View {
        let inRotation = model.aiMacCardRotationList(for: deviceID).contains(mode)
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Image(systemName: mode.icon).frame(width: 18)
            Text(mode.title)
            Spacer()
            Toggle("", isOn: Binding(get: { true }, set: {
                model.setAIMacCardVisible(mode, visible: $0, deviceID: deviceID)
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            .help("在侧边栏显示该卡片")
            Toggle("", isOn: Binding(get: { inRotation }, set: {
                model.setAIMacCardRotationMode(mode, enabled: $0, deviceID: deviceID)
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            .help("加入自动轮播")
        }
        .onDrag {
            draggedAIMacCard = mode
            dragAIMacCards = model.aiMacCardList(for: deviceID)
            return NSItemProvider(object: String(mode.rawValue) as NSString)
        }
    }

    private var aiMacPreview: some View {
        Group {
            if let id = model.activeDeviceID(for: .aiMacScreen),
               let preview = model.aiMacScreenPreviews[id] {
                Image(nsImage: preview).resizable().interpolation(.none)
            } else {
                ZStack {
                    Color.black.opacity(0.9)
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(width: 240, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    /// 草稿式连接输入：输入框 + 「应用」（避免逐字符触发拉取/持久化）；key 为草稿存储键
    private func draftField(key: String, label: String, binding: Binding<String>,
                            fieldWidth: CGFloat? = nil, secure: Bool = false,
                            helpText: String? = nil,
                            onApply: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Group {
                if secure {
                    SecureField(label, text: Binding(
                        get: { self.connectionDrafts[key] ?? binding.wrappedValue },
                        set: { self.connectionDrafts[key] = $0 }))
                } else {
                    TextField(label, text: Binding(
                        get: { self.connectionDrafts[key] ?? binding.wrappedValue },
                        set: { self.connectionDrafts[key] = $0 }))
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: fieldWidth)
            Button("应用") {
                binding.wrappedValue = self.connectionDrafts[key] ?? ""
                self.connectionDrafts[key] = nil
                onApply?()
            }
            .controlSize(.small)
            .disabled((self.connectionDrafts[key] ?? binding.wrappedValue) == binding.wrappedValue)
            .help("确认并应用此连接信息")
            if let helpText {
                HelpIcon(text: helpText)
            }
        }
    }

    /// Home Assistant 长期访问令牌输入（密码框 + 草稿 + 应用，与连接字段一致）
    private func haTokenField(_ deviceID: UUID) -> some View {
        draftField(key: "\(deviceID.uuidString)#HA令牌", label: "长期访问令牌",
                   binding: model.deviceHATokenBinding(for: deviceID), fieldWidth: 320, secure: true,
                   helpText: "长期访问令牌在 Home Assistant 网页“个人资料 → 安全 → 长期访问令牌”生成；仅保存在本机，不会随发布包外泄。")
    }

    /// 口袋先知按键控制页：配置当前口袋先知设备的按键控制目标
    /// （跟随侧栏选中的先知设备，每台先知设备各自记住）
    private var buttonControlForm: some View {
        Group {
            Section("口袋先知设备") {
                LabeledContent("设备",
                               value: model.activeDevice(for: .oracle)?.name ?? "未设置")
            }
            Section {
                if let oracleID = model.activeDevice(for: .oracle)?.id {
                    Picker("按键控制设备", selection: model.deviceRand0ControlTargetBinding(for: oracleID)) {
                        ForEach(model.rand0ControlOptions(), id: \.key) { option in
                            Text(option.label).tag(option.key)
                        }
                    }
                    Text(model.rand0ControlTargetLabel(for: oracleID))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("请先在「设备管理」中添加口袋先知设备。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.rand0SessionConnected {
                    Label("显示模式已连接：设备按键信号实时回传", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !model.settings.rand0IP.isEmpty {
                    Text("显示模式未连接：进入本页后会自动连接，连接后按键信号才会回传。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack(spacing: 4) {
                    Text("按键控制")
                    HelpIcon(text: "口袋先知设备按键（短按）控制所选目标：控制自身时下键手动更新画布（保存了多块画板时上下键可循环切换并推送）；控制灵犀68 键盘时上下键翻页；控制摘录时下键切换 Dot 云端下一项、上键推送本地摘录画板。每台设备独立保存控制目标。")
                }
            }
        }
        .onAppear { model.ensureRand0Session() }
    }

    /// 设备管理页面：多台 灵犀68/口袋先知/摘录 设备的添加、重命名、删除与活动设备切换；
    /// 每台设备独立记住自己的画板与卡片设置；Home Assistant 服务器为全局唯一连接配置
    private var devicesForm: some View {
        Group {
            ForEach(DeviceType.allCases) { type in
                Section {
                    if type == .homeAssistant {
                        homeAssistantDiscoveryInline
                        Divider()
                    }
                    if type == .oracle {
                        rand0DiscoveryInline
                        Divider()
                    }
                    if type == .aiMacScreen {
                        aiMacAddExistingDeviceInline
                        Divider()
                        DisclosureGroup("需要刷写一台新设备？") {
                            aiMacFirmwareFlasherInline
                                .padding(.top, 6)
                        }
                        Divider()
                    }
                    ForEach(model.devices(for: type)) { device in
                        let isEditing = editingDeviceIDs.contains(device.id)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Group {
                                    TextField("设备名称", text: model.deviceNameBinding(for: device.id))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 320)
                                    if type == .bambuLab, let printerModel = model.bambuModel(for: device.id) {
                                        Text(printerModel)
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                .fill(Color.accentColor.opacity(0.85)))
                                            .help("识别到的打印机型号")
                                    }
                                }
                                .disabled(!isEditing)
                                .opacity(isEditing ? (device.isEnabled ? 1 : 0.5) : 0.5)
                                Spacer()
                                Button {
                                    toggleDeviceEditing(device.id)
                                } label: {
                                    Label(isEditing ? "完成" : "编辑",
                                          systemImage: isEditing ? "checkmark.circle.fill" : "pencil")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help(isEditing ? "完成并锁定这台设备的设置" : "解锁这台设备的设置")
                            }
                            // 连接信息按设备类型显示与编辑（键盘/先知只需 IP，摘录需 API Key 与序列号）
                            // 所有输入框统一固定宽度，与设备名称输入框对齐
                            Group {
                                if type == .keyboard {
                                    deviceConnectionField(device.id, label: "键盘 IP 地址",
                                                          binding: model.deviceEndpointBinding(for: device.id),
                                                          fieldWidth: 320)
                                } else if type == .oracle {
                                    deviceConnectionField(device.id, label: "设备 IP 地址",
                                                          binding: model.deviceRand0IPBinding(for: device.id),
                                                          fieldWidth: 320,
                                                          helpText: "Rand/0 设备 IP 地址可在设备网络设置中查看；点击图标查看显示模式官方文档。",
                                                          helpURL: rand0DisplayModeDocsURL)
                                } else if type == .homeAssistant {
                                    deviceConnectionField(device.id, label: "服务器地址",
                                                          binding: model.deviceHAServerURLBinding(for: device.id),
                                                          fieldWidth: 320,
                                                          helpText: "如 http://192.168.x.x:8123；实体状态经 REST 接口（/api/states）拉取。")
                                    haTokenField(device.id)
                                    HStack {
                                        Stepper("刷新间隔 \(model.deviceHARefreshBinding(for: device.id).wrappedValue) 分钟",
                                                value: model.deviceHARefreshBinding(for: device.id), in: 1...60)
                                        Spacer()
                                    }
                                    HStack {
                                        Button("连接测试") {
                                            Task {
                                                haTesting = true
                                                haTestResult = await model.testHADevice(device.id)
                                                haTesting = false
                                            }
                                        }
                                        if haTesting {
                                            ProgressView().controlSize(.small)
                                        }
                                        Spacer()
                                        if !haTestResult.isEmpty {
                                            Text(haTestResult)
                                                .font(.caption)
                                                .foregroundStyle(haTestResult.hasPrefix("连接成功") ? Color.secondary : Color.red)
                                        }
                                    }
                                } else if type == .bambuLab {
                                    bambuDeviceConfigInline(device.id)
                                } else if type == .formlabs {
                                    formlabsDeviceConfigInline(device.id)
                                } else if type == .aiMacScreen {
                                    deviceConnectionField(device.id, label: "小屏幕 IP 地址",
                                                          binding: model.aiMacScreenHostBinding(for: device.id),
                                                          fieldWidth: 320,
                                                          helpText: "支持 240×240 AI Mac 小屏幕；0.8.1 固件支持 Wi-Fi 预配置、热点配网修复与 RGB565 无损帧，旧固件自动回退 JPEG。")
                                    HStack {
                                        Button("连接测试") {
                                            Task { await model.testAIMacScreenConnection(deviceID: device.id) }
                                        }
                                        if model.aiMacScreenBusyIDs.contains(device.id) {
                                            ProgressView().controlSize(.small)
                                        }
                                        Spacer()
                                        Text(model.aiMacScreenStatuses[device.id] ?? "尚未测试")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    deviceConnectionField(device.id, label: "API Key",
                                                          binding: model.deviceDotApiKeyBinding(for: device.id),
                                                          fieldWidth: 320,
                                                          helpText: "API Key 在 Dot 开发者平台创建 Image API 应用后获取；点击图标打开获取说明。",
                                                          helpURL: dotImageAPIDocsURL)
                                    deviceConnectionField(device.id, label: "设备序列号",
                                                          binding: model.deviceDotDeviceIdBinding(for: device.id),
                                                          fieldWidth: 320,
                                                          helpText: "设备序列号（SN）可在 Dot App 中查看；点击图标打开获取说明。",
                                                          helpURL: dotImageAPIDocsURL)
                                }
                            }
                            .disabled(!isEditing)
                            .opacity(isEditing ? (device.isEnabled ? 1 : 0.5) : 0.5)
                            // 启用/停用开关：独立位置（禁用后左侧导航隐藏该设备，设置保留）
                            Toggle("启用设备", isOn: model.deviceEnabledBinding(for: device.id))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help("禁用后左侧导航隐藏该设备，设置保留")
                                .disabled(!isEditing)
                                .opacity(isEditing ? 1 : 0.5)
                            // 删除设备：独立按钮，删除前二次确认
                            Button(role: .destructive) {
                                deviceToDelete = device
                            } label: {
                                Label("删除设备", systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help("删除该设备")
                            .disabled(!isEditing)
                            .opacity(isEditing ? 1 : 0.5)
                        }
                        .padding(.vertical, 10)
                        Divider()
                    }
                    if type == .bambuLab {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Button("添加 \(type.title) 设备") {
                                    model.addDevice(type: type)
                                }
                                .disabled(!model.settings.canAddDevice(of: type))
                                Button {
                                    guard let homeAssistantID = bambuDiscoveryHomeAssistantID else { return }
                                    Task {
                                        await model.discoverAndAddBambuPrinters(
                                            homeAssistantDeviceID: homeAssistantID)
                                    }
                                } label: {
                                    Label(model.bambuAutoDiscoveryBusy
                                          ? "正在匹配…" : "扫描并匹配",
                                          systemImage: "printer.filled.and.paper")
                                }
                                .disabled(model.bambuAutoDiscoveryBusy
                                          || bambuDiscoveryHomeAssistantID == nil)
                                .help(bambuDiscoveryHomeAssistantID == nil
                                      ? "请先添加并配置 Home Assistant 服务器"
                                      : "通过已添加的 Home Assistant 服务器扫描并自动创建 Bambu Lab 打印机设备")
                                if model.bambuAutoDiscoveryBusy {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            if let notice = model.settings.deviceLimitNotice(for: type) {
                                Text(notice)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !model.bambuAutoDiscoveryStatus.isEmpty {
                                Text(model.bambuAutoDiscoveryStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else if let notice = model.settings.deviceLimitNotice(for: type) {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if type != .aiMacScreen && type != .homeAssistant && type != .oracle {
                        Button("添加 \(type.title) 设备") {
                            model.addDevice(type: type)
                        }
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text(type.title)
                        HelpIcon(text: "连接信息填写后需点“应用”才生效；每台设备独立记录连接与画板设置，切换设备后会恢复该设备之前的设置。灵犀68 键盘与口袋先知填写 IP，摘录填写 API Key 与设备序列号。")
                    }
                }
            }
        }
        .confirmationDialog(
            deviceToDelete.map { "确定删除设备「\($0.name)」吗？该设备的连接信息与画板设置将被移除。" } ?? "",
            isPresented: Binding(get: { deviceToDelete != nil },
                                 set: { if !$0 { deviceToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let device = deviceToDelete {
                    editingDeviceIDs.remove(device.id)
                    discardDeviceDrafts(device.id)
                    model.removeDevice(id: device.id)
                }
                deviceToDelete = nil
            }
            Button("取消", role: .cancel) {
                deviceToDelete = nil
            }
        }
        .task {
            await model.ensureBambuEntityCatalog()
        }
        .task {
            await model.scanHomeAssistantServers()
        }
        .task {
            await model.scanRand0Devices()
        }
        .onDisappear {
            editingDeviceIDs.removeAll()
            connectionDrafts.removeAll()
            bambuMatchDrafts.removeAll()
        }
    }

    private var bambuDiscoveryHomeAssistantID: UUID? {
        let devices = model.devices(for: .homeAssistant)
        if let activeID = model.activeDeviceID(for: .homeAssistant),
           devices.contains(where: { $0.id == activeID }) {
            return activeID
        }
        return devices.first?.id
    }

    private func toggleDeviceEditing(_ deviceID: UUID) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if editingDeviceIDs.contains(deviceID) {
                editingDeviceIDs.remove(deviceID)
                discardDeviceDrafts(deviceID)
            } else {
                editingDeviceIDs.insert(deviceID)
            }
        }
    }

    private func discardDeviceDrafts(_ deviceID: UUID) {
        let prefix = "\(deviceID.uuidString)#"
        connectionDrafts = connectionDrafts.filter { !$0.key.hasPrefix(prefix) }
        bambuMatchDrafts[deviceID.uuidString] = nil
    }

    /// Home Assistant 通过官方 Zeroconf 广播自动发现；只填入地址，令牌仍由用户本人提供。
    private var homeAssistantDiscoveryInline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("自动发现服务器", systemImage: "homekit")
                    .font(.headline)
                HelpIcon(text: "自动查找与这台 Mac 位于同一局域网的 Home Assistant。选择服务器后填写长期访问令牌；Bambu Lab 打印机扫描入口位于“Bambu Lab 打印机”设备添加按钮旁。")
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    model.addDevice(type: .homeAssistant)
                } label: {
                    Label("手动添加", systemImage: "plus")
                }
                .disabled(!model.settings.canAddDevice(of: .homeAssistant))
                Button {
                    Task { await model.scanHomeAssistantServers(force: true) }
                } label: {
                    Label(model.homeAssistantDiscoveryBusy ? "正在查找…" : "重新扫描",
                          systemImage: "arrow.clockwise")
                }
                .disabled(model.homeAssistantDiscoveryBusy)
                if model.homeAssistantDiscoveryBusy {
                    ProgressView().controlSize(.small)
                }
            }
            if !model.homeAssistantDiscoveryStatus.isEmpty {
                Text(model.homeAssistantDiscoveryStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.homeAssistantDiscoveredServices.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.homeAssistantDiscoveredServices) { service in
                        HStack(spacing: 10) {
                            Image(systemName: "house.and.flag.fill")
                                .frame(width: 22)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(service.serverURL)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            let added = model.isHomeAssistantAdded(service)
                            Button(added ? "已选择" : "使用") {
                                _ = model.addDiscoveredHomeAssistant(service)
                            }
                            .disabled(added)
                        }
                        .padding(.vertical, 8)
                        if service.id != model.homeAssistantDiscoveredServices.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.vertical, 8)
    }

    /// 已经联网的口袋先知可以直接扫描添加；手动输入 IP 始终作为备用入口。
    private var rand0DiscoveryInline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("添加已联网设备", systemImage: "wifi")
                    .font(.headline)
                HelpIcon(text: "自动查找与这台 Mac 位于同一局域网的口袋先知。扫描只确认设备身份，不会覆盖或改变屏幕内容。")
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    model.addDevice(type: .oracle)
                } label: {
                    Label("手动添加", systemImage: "plus")
                }
                Button {
                    Task { await model.scanRand0Devices(force: true) }
                } label: {
                    Label(model.rand0DiscoveryBusy ? "正在扫描…" : "重新扫描",
                          systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(model.rand0DiscoveryBusy)
                if model.rand0DiscoveryBusy {
                    ProgressView().controlSize(.small)
                }
            }
            if !model.rand0DiscoveryStatus.isEmpty {
                Text(model.rand0DiscoveryStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.rand0DiscoveredDevices.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.rand0DiscoveredDevices) { discovered in
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.on.rectangle.angled")
                                .frame(width: 22)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(discovered.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(discovered.ip)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            let added = model.isRand0DeviceAdded(discovered)
                            Button(added ? "已添加" : "添加") {
                                _ = model.addDiscoveredRand0Device(discovered)
                            }
                            .disabled(added)
                        }
                        .padding(.vertical, 8)
                        if discovered.id != model.rand0DiscoveredDevices.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.vertical, 8)
    }

    /// 已经刷写并联网的小屏幕可直接手动添加或从当前局域网扫描，不依赖刷机流程。
    private var aiMacAddExistingDeviceInline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("添加已联网设备", systemImage: "wifi")
                    .font(.headline)
                HelpIcon(text: "适用于已经刷入兼容固件并连接 2.4 GHz Wi-Fi 的小屏幕。可手动填写 IP，也可扫描与这台 Mac 位于同一局域网的设备。")
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    model.addDevice(type: .aiMacScreen)
                } label: {
                    Label("手动添加", systemImage: "plus")
                }
                .disabled(!model.settings.canAddDevice(of: .aiMacScreen))

                Button {
                    Task { await model.scanAIMacScreens() }
                } label: {
                    Label(model.aiMacNetworkScanBusy ? "正在扫描…" : "扫描局域网",
                          systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(model.aiMacNetworkScanBusy)
                if model.aiMacNetworkScanBusy {
                    ProgressView().controlSize(.small)
                }
            }

            if !model.aiMacNetworkScanStatus.isEmpty {
                Text(model.aiMacNetworkScanStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.aiMacDiscoveredDevices.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.aiMacDiscoveredDevices) { discovered in
                        HStack(spacing: 10) {
                            Image(systemName: "display")
                                .frame(width: 22)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(discovered.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                Text("\(discovered.ip) · 固件 \(discovered.firmwareVersion)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            let added = model.isAIMacScreenAdded(discovered)
                            Button(added ? "已添加" : "添加") {
                                _ = model.addDiscoveredAIMacScreen(discovered)
                            }
                            .disabled(added || !model.settings.canAddDevice(of: .aiMacScreen))
                        }
                        .padding(.vertical, 8)
                        if discovered.id != model.aiMacDiscoveredDevices.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.vertical, 8)
    }

    /// AI Mac 小屏幕属于主应用的一种设备；首次使用时可在设备管理中完成固件准备，
    /// 无需安装 Python、esptool 或另一个独立应用。
    private var aiMacFirmwareFlasherInline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("固件准备", systemImage: "memorychip")
                    .font(.headline)
                Text("v\(EmbeddedAIMacFirmware.version)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Label(model.embeddedAIMacFirmwareReady ? "内置固件已校验" : "内置固件不可用",
                      systemImage: model.embeddedAIMacFirmwareReady
                        ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(model.embeddedAIMacFirmwareReady ? Color.green : Color.red)
            }

            Text("首次使用时，将 AI Mac 小屏幕通过 USB 数据线连接到 Mac。软件会一并写入 Wi-Fi，刷完后等待设备联网、读取 IP 并自动添加。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("仅支持 2.4 GHz Wi-Fi")
                            .fontWeight(.semibold)
                        Text("请勿选择仅有 5 GHz 或 6 GHz 的网络；双频同名 Wi-Fi 也必须开启 2.4 GHz。")
                            .font(.caption)
                    }
                } icon: {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.title3)
                }
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: 360, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.45), lineWidth: 1)
                }

                HStack(spacing: 6) {
                    TextField("Wi-Fi 名称（SSID）", text: $aiMacProvisionSSID)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    HelpIcon(text: "SSID 区分大小写。若路由器把 2.4 GHz 与 5 GHz 合并为同一个名称，请确认 2.4 GHz 频段没有被关闭。")
                }
                SecureField("Wi-Fi 密码（开放网络可留空）", text: $aiMacProvisionPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                if (!aiMacProvisionSSID.isEmpty || !aiMacProvisionPassword.isEmpty),
                   let error = aiMacWiFiInputError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !aiMacProvisionSSID.isEmpty {
                    Label("密码仅用于本次刷写；设备联网后会擦除临时配网区，软件不会保存密码。",
                          systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(model.aiMacFlashBusy)

            HStack(spacing: 8) {
                Picker("USB 串口", selection: $model.selectedAIMacFlashPort) {
                    if model.aiMacFlashPorts.isEmpty {
                        Text("未发现设备").tag("")
                    } else {
                        ForEach(model.aiMacFlashPorts) { port in
                            Text(port.displayName).tag(port.path)
                        }
                    }
                }
                .frame(maxWidth: 360)
                .disabled(model.aiMacFlashBusy)

                Button {
                    model.refreshAIMacFlashPorts()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.aiMacFlashBusy)
            }

            HStack(spacing: 8) {
                Button("刷入固件并添加设备") {
                    aiMacFlashShouldAddDevice = true
                    showAIMacFlashConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.embeddedAIMacFirmwareReady
                          || model.selectedAIMacFlashPort.isEmpty
                          || aiMacWiFiInputError != nil
                          || model.aiMacFlashBusy)

                Button("仅刷入固件") {
                    aiMacFlashShouldAddDevice = false
                    showAIMacFlashConfirmation = true
                }
                .disabled(!model.embeddedAIMacFirmwareReady
                          || model.selectedAIMacFlashPort.isEmpty
                          || aiMacWiFiInputError != nil
                          || model.aiMacFlashBusy)

                if model.aiMacFlashBusy {
                    Button("取消", role: .destructive) {
                        model.cancelAIMacFirmwareFlash()
                    }
                }
            }

            if model.aiMacFlashBusy || model.aiMacFlashProgress > 0 {
                ProgressView(value: model.aiMacFlashProgress)
                    .progressViewStyle(.linear)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if model.aiMacFlashBusy {
                    ProgressView().controlSize(.small)
                }
                Text(model.aiMacFlashStatus)
                    .font(.caption)
                    .foregroundStyle(model.aiMacFlashStatus.contains("失败")
                                     || model.aiMacFlashStatus.contains("缺失")
                                     || model.aiMacFlashStatus.contains("校验失败")
                                     ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                Spacer()
                if !model.aiMacFlashLog.isEmpty {
                    Button(showAIMacFlashLog ? "收起日志" : "查看日志") {
                        withAnimation { showAIMacFlashLog.toggle() }
                    }
                    .buttonStyle(.link)
                }
            }

            if showAIMacFlashLog, !model.aiMacFlashLog.isEmpty {
                ScrollView {
                    Text(model.aiMacFlashLog)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 120)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            }

            Label("请使用支持数据传输的 USB 线；刷写过程中不要拔线或关闭应用。",
                  systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .onAppear { model.refreshAIMacFlashPorts() }
    }

    private var aiMacWiFiInputError: String? {
        do {
            try AIMacWiFiProvisioning.validateCredentials(
                ssid: aiMacProvisionSSID, password: aiMacProvisionPassword)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @ViewBuilder
    private func formlabsDeviceConfigInline(_ deviceID: UUID) -> some View {
        let discovered = model.formlabsDiscoveredDevices[deviceID] ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Formlabs Dashboard API")
                    .font(.system(size: 12, weight: .semibold))
                HelpIcon(text: "纯云端模式：设备状态、任务名、准确进度、层数、耗材种类与缩略图均来自 Formlabs Dashboard API。")
            }
            Toggle(isOn: model.formlabsBoolBinding(for: deviceID, \.useBrandAccent)) {
                HStack(spacing: 4) {
                    Text("使用 Formlabs 品牌强调色")
                    HelpIcon(text: "开启时使用 Formlabs 品牌蓝；关闭后跟随软件的全局主题强调色。")
                }
            }
            deviceConnectionField(deviceID, label: "Client ID",
                                  binding: model.formlabsStringBinding(for: deviceID, \.clientID),
                                  fieldWidth: 320,
                                  helpText: "在 Formlabs Developer Platform 创建应用后获得。",
                                  helpURL: formlabsDeveloperDocsURL)
            draftField(key: "\(deviceID.uuidString)#FormlabsSecret", label: "Client Secret",
                       binding: model.formlabsStringBinding(for: deviceID, \.clientSecret),
                       fieldWidth: 320, secure: true)
            HStack {
                Button("读取云端打印机") { Task { await model.discoverFormlabsDevices(deviceID) } }
                HelpIcon(text: "先应用 Client ID 和 Client Secret，再从账号中读取打印机。")
            }
            if !discovered.isEmpty {
                Picker("云端打印机", selection: model.formlabsStringBinding(for: deviceID, \.printerSerial)) {
                    Text("请选择").tag("")
                    ForEach(discovered) { printer in
                        Text("\(printer.productName) · \(printer.id)").tag(printer.id)
                    }
                }
                .frame(width: 420)
                .onChange(of: model.formlabsStringBinding(for: deviceID, \.printerSerial).wrappedValue) { _, serial in
                    if let printer = discovered.first(where: { $0.id == serial }) {
                        model.chooseFormlabsCloudPrinter(printer, for: deviceID)
                    }
                }
            } else {
                deviceConnectionField(deviceID, label: "打印机序列号",
                                      binding: model.formlabsStringBinding(for: deviceID, \.printerSerial),
                                      fieldWidth: 320)
            }
            HStack {
                Button("测试云端连接") { Task { await model.testFormlabsConnection(deviceID) } }
                Button("立即刷新") {
                    Task { await model.refreshFormlabs(deviceID: deviceID, force: true, pushIfVisible: true) }
                }
                Spacer()
            }
            if let status = model.formlabsConnectionStatus[deviceID], !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status.contains("失败") || status.contains("异常") ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// 口袋先知画板管理：每台设备独立排序，并分别控制侧栏显示与自动轮播参与状态。
    private var oracleBoardManagementForm: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                    Text("正在管理")
                    HelpIcon(text: "每台口袋先知的画板、显示顺序和轮播设置相互独立；此页只影响当前选中的设备。")
                    Spacer()
                    if model.enabledDevices(for: .oracle).count > 1 {
                        Picker("", selection: model.activeOracleBinding) {
                            ForEach(model.enabledDevices(for: .oracle)) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    } else {
                        Text(model.activeDevice(for: .oracle)?.name ?? "未选择设备")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11))
                        .foregroundStyle(.clear)
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 11))
                        .foregroundStyle(.clear)
                        .frame(width: 16)
                    Text("画板")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("侧栏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44)
                    Text("轮播")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44)
                    Color.clear.frame(width: 50, height: 1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                let boards = dragBoards ?? model.settings.oracleCanvasBoards
                if boards.isEmpty {
                    Text("尚未创建画板")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    reorderList(items: boards, dragged: $draggedBoard, dragItems: $dragBoards,
                                commit: { model.commitOracleCanvasBoards($0) }) { board in
                        oracleBoardManagementRow(board)
                    }
                }
                Button("创建新的画板") {
                    model.addOracleCanvasBoard()
                    selected = .oracleCanvas
                }
            } header: {
                HStack(spacing: 4) {
                    Text("画板（拖拽排序）")
                    HelpIcon(text: "拖动排序决定侧栏与自动轮播顺序；关闭“侧栏”后不再显示在设备折叠菜单中，关闭“轮播”后不会被自动切换。")
                }
            }

            Section("显示设置") {
                HStack(spacing: 4) {
                    Text("底色模式")
                    HelpIcon(text: "手动切换深色/亮色底色：亮色模式为白底深字，避免墨水屏长时间显示黑色底色；不随电脑或软件主题同步。")
                }
                Picker("", selection: model.oracleBackgroundModeBinding) {
                    ForEach(CanvasBackgroundMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle(isOn: model.oracleImageRotate180Binding) {
                    HStack(spacing: 4) {
                        Text("旋转 180°")
                        HelpIcon(text: "仅将实际推送到设备的画面旋转 180°，适配设备安装方向；软件预览始终保持正向，也不会产生镜像。")
                    }
                }
                Picker(selection: model.oracleDisplayModeBinding) {
                    ForEach(OracleDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("显示模式")
                        HelpIcon(text: "黑白模式：灰值 > 128 显示为白，其余为黑（通过 /display/bw 推送）。4 级灰阶：白/浅灰/深灰/黑（通过 /display/gray4 推送）。")
                    }
                }
                .pickerStyle(.segmented)
                Picker(selection: model.oracleGrayAlgorithmBinding) {
                    ForEach(OracleGrayAlgorithm.allCases) { algorithm in
                        Text(algorithm.title).tag(algorithm)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("灰阶算法")
                        HelpIcon(text: "灰阶转换：\(model.settings.oracleGrayAlgorithm.subtitle)")
                    }
                }
                Picker(selection: model.oracleDitherKernelBinding) {
                    ForEach(OracleDitherKernel.allCases) { kernel in
                        Text(kernel.title).tag(kernel)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("抖动算法")
                        HelpIcon(text: "抖动：\(model.settings.oracleDitherKernel.subtitle)（参考官方墨水屏 ditherKernel）")
                    }
                }
            }

            Section {
                HStack(spacing: 4) {
                    Button("推送到 Rand/0 设备") {
                        Task { await model.pushOracleCanvas() }
                    }
                    HelpIcon(text: "设备 IP 地址与按键控制目标请在“设备管理”中按设备设置。")
                }
                if model.rand0SessionConnected {
                    Label("显示模式已连接：设备按键信号实时回传", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !model.settings.rand0IP.isEmpty {
                    Text("显示模式未连接：设备可能离线或不在同一局域网，将自动重连；连接后推送即时上屏、按键信号回传。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack(spacing: 4) {
                    Text("Rand/0 设备")
                    HelpIcon(text: "通过局域网 WebSocket（ws://<IP>/display/bw 或 /display/gray4）把图像推送到 Rand/0 墨水屏，发送即显示、无需在设备上按键刷新。保持连接时设备按键信号会回传给软件，可在「设备管理」中配置每台先知设备按键控制的目标。")
                }
            }

            Section("自动推送与轮换") {
                Toggle(isOn: model.oracleAutoPushEnabledBinding) {
                    HStack(spacing: 4) {
                        Text("自动推送画布")
                        HelpIcon(text: "开启后立即推送一次；之后内容变化时立即推送，无变化则按间隔推送。")
                    }
                }
                if model.settings.oracleAutoPushEnabled {
                    Stepper("推送间隔 \(model.settings.oracleAutoPushMinutes) 分钟",
                            value: model.oracleAutoPushMinutesBinding, in: 1...1440)
                }
                Divider()
                Toggle(isOn: model.oracleBoardRotationEnabledBinding) {
                    HStack(spacing: 4) {
                        Text("自动轮换画板")
                        HelpIcon(text: "按画板管理中的顺序循环切换同时开启“侧栏”和“轮播”的画板；每次切换后立即推送。")
                    }
                }
                if model.settings.oracleBoardRotationEnabled {
                    Stepper("轮换间隔 \(model.settings.oracleBoardRotationMinutes) 分钟",
                            value: model.oracleBoardRotationMinutesBinding, in: 1...1440)
                }
                if model.oracleRotationBoardCount < 2 {
                    Text("至少需要两块同时开启“侧栏”和“轮播”的画板，自动轮播才会开始。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.settings.oracleBoardRotationEnabled {
                    Text("当前：\(model.oracleCanvasBoardName) · 下一块：\(model.nextOracleCanvasBoardName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
        .alert("重命名画板", isPresented: Binding(
            get: { boardRenameTarget != nil },
            set: { if !$0 { boardRenameTarget = nil } })) {
            TextField("画板名称", text: $boardRenameDraft)
            Button("确定") {
                if let board = boardRenameTarget {
                    model.renameOracleCanvasBoard(id: board.id, to: boardRenameDraft)
                }
                boardRenameTarget = nil
            }
            Button("取消", role: .cancel) { boardRenameTarget = nil }
        }
        .onAppear {
            model.ensureRand0Session()
        }
    }

    private func oracleBoardManagementRow(_ board: OracleCanvasBoard) -> some View {
        let index = model.settings.oracleCanvasBoards.firstIndex(where: { $0.id == board.id }) ?? 0
        let isCurrent = model.settings.oracleCanvasBoards.indices.contains(index)
            && index == model.settings.oracleCanvasBoardIndex
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Image(systemName: "rectangle.stack")
                .font(.system(size: 12))
                .frame(width: 16)
            Button {
                model.applyOracleCanvasBoard(at: index)
                selected = .oracleCanvas
            } label: {
                HStack(spacing: 5) {
                    Text(board.name).lineLimit(1)
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Toggle("", isOn: Binding(
                get: { board.isSidebarVisible },
                set: { model.setOracleCanvasBoardSidebarVisible(id: board.id, visible: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(width: 44)
                .help("在该设备的侧边栏中显示")
            Toggle("", isOn: Binding(
                get: { board.participatesInRotation },
                set: { model.setOracleCanvasBoardRotationEnabled(id: board.id, enabled: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(width: 44)
                .help("加入自动轮播")
            HStack(spacing: 6) {
                Button {
                    boardRenameTarget = board
                    boardRenameDraft = board.name
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("重命名画板")
                Button(role: .destructive) {
                    model.removeOracleCanvasBoard(at: index)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("删除画板")
            }
            .frame(width: 50)
        }
        .padding(.vertical, 2)
        .onDrag {
            draggedBoard = board
            dragBoards = model.settings.oracleCanvasBoards
            return NSItemProvider(object: board.id.uuidString as NSString)
        }
        .help("点击名称编辑；拖拽排序")
    }

    /// AI Mac 小屏幕画板管理：沿用口袋先知的多画板、侧栏、排序和轮播逻辑，
    /// 仅保留彩屏需要的设置，不展示墨水屏灰阶、抖动与插值选项。
    private var aiMacBoardManagementForm: some View {
        Form {
            if let device = model.activeDevice(for: .aiMacScreen) {
                let config = model.aiMacScreenSettings(for: device.id)
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "display").foregroundStyle(.secondary)
                        Text("正在管理")
                        HelpIcon(text: "每台 AI Mac 小屏幕分别保存画板、顺序、可见状态和自动轮播设置，不会与其他小屏幕串用。")
                        Spacer()
                        if model.enabledDevices(for: .aiMacScreen).count > 1 {
                            Picker("", selection: model.activeAIMacScreenBinding) {
                                ForEach(model.enabledDevices(for: .aiMacScreen)) { item in
                                    Text(item.name).tag(item.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        } else {
                            Text(device.name).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    let boards = dragAIMacBoards ?? config.canvasBoards
                    if boards.isEmpty {
                        Text("尚未创建画板")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        reorderList(items: boards, dragged: $draggedAIMacBoard,
                                    dragItems: $dragAIMacBoards,
                                    commit: { model.commitAIMacCanvasBoards($0) }) { board in
                            aiMacBoardManagementRow(board, config: config)
                        }
                    }
                    Button("创建新的画板") {
                        model.addAIMacCanvasBoard()
                        dragModules = nil
                        selected = .aiMacScreen
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("画板（拖拽排序）")
                        HelpIcon(text: "新画板为空白“未命名”；添加第一个模块后自动命名。侧栏开关控制是否显示在设备折叠菜单中，轮播开关控制是否参与自动切换。")
                    }
                }

                if config.canvasBoards.indices.contains(config.canvasBoardIndex) {
                    Section("当前画板显示") {
                        Picker("底色模式",
                               selection: model.aiMacBackgroundModeBinding(for: device.id)) {
                            ForEach(CanvasBackgroundMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("直接渲染 240×240 彩色画面，不进行黑白转换、灰阶量化、抖动或插值。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("自动轮换") {
                    Toggle("自动轮换画板",
                           isOn: model.aiMacBoardRotationBinding(for: device.id))
                    if config.boardRotationEnabled {
                        Stepper("轮换间隔 \(config.boardRotationMinutes) 分钟",
                                value: model.aiMacBoardRotationMinutesBinding(for: device.id),
                                in: 1...1_440)
                    }
                    let rotationCount = config.canvasBoards.filter {
                        $0.isSidebarVisible && $0.participatesInRotation
                    }.count
                    if rotationCount < 2 {
                        Text("至少需要两块同时开启“侧栏”和“轮播”的画板。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Text("请先在设备管理中添加 AI Mac 小屏幕。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
        .alert("重命名画板", isPresented: Binding(
            get: { aiMacBoardRenameTarget != nil },
            set: { if !$0 { aiMacBoardRenameTarget = nil } })) {
            TextField("画板名称", text: $aiMacBoardRenameDraft)
            Button("确定") {
                if let board = aiMacBoardRenameTarget {
                    model.renameAIMacCanvasBoard(id: board.id, to: aiMacBoardRenameDraft)
                }
                aiMacBoardRenameTarget = nil
            }
            Button("取消", role: .cancel) { aiMacBoardRenameTarget = nil }
        }
    }

    /// 与画板管理分离的设备连接与推送页，行为对齐灵犀68的独立控制页面。
    private var aiMacControlForm: some View {
        Form {
            if let device = model.activeDevice(for: .aiMacScreen) {
                let config = model.aiMacScreenSettings(for: device.id)
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "display").foregroundStyle(.secondary)
                        Text(device.name).font(.headline)
                        Spacer()
                        Text(config.mode.title).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("当前设备")
                        HelpIcon(text: "本页的地址、推送间隔、连接状态和手动推送只作用于这台小屏幕。其他 AI Mac 设备保留自己的独立设置。")
                    }
                }

                Section("连接") {
                    deviceConnectionField(device.id, label: "小屏幕 IP 地址",
                                          binding: model.aiMacScreenHostBinding(for: device.id),
                                          fieldWidth: 320,
                                          helpText: "可在设备管理中手动添加或扫描已联网设备；兼容固件优先使用 RGB565 无损帧，旧固件自动使用 JPEG。")
                    HStack {
                        Button("连接测试") {
                            Task { await model.testAIMacScreenConnection(deviceID: device.id) }
                        }
                        Spacer()
                        if model.aiMacScreenBusyIDs.contains(device.id) {
                            ProgressView().controlSize(.small)
                        }
                    }
                    LabeledContent("传输模式",
                                   value: model.aiMacScreenLosslessIDs.contains(device.id)
                                   ? "RGB565 无损" : "JPEG 兼容")
                    Text(model.aiMacScreenStatuses[device.id] ?? "等待连接小屏幕")
                        .font(.caption)
                        .foregroundStyle((model.aiMacScreenStatuses[device.id] ?? "").contains("失败")
                                         ? Color.red : Color.secondary)
                }

                Section {
                    Picker("自动休眠",
                           selection: model.aiMacScreenFollowSystemSleepBinding(for: device.id)) {
                        Text("始终保持亮屏").tag(false)
                        Text("跟随 Mac 锁屏与休眠").tag(true)
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 12) {
                        Slider(value: model.aiMacScreenBrightnessBinding(for: device.id),
                               in: 1...100, step: 1, onEditingChanged: { editing in
                            guard !editing else { return }
                            Task { await model.applyAIMacScreenBrightness(deviceID: device.id) }
                        })
                        Text("\(model.aiMacScreenBrightnessLevel(for: device.id))%")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                    Button("应用亮度") {
                        Task { await model.applyAIMacScreenBrightness(deviceID: device.id) }
                    }
                    .disabled(AIMacScreenSupport.normalizedHost(config.host).isEmpty)
                } header: {
                    HStack(spacing: 4) {
                        Text("屏幕与亮度")
                        HelpIcon(text: "可选择始终亮屏，或在 Mac 锁屏、休眠时自动熄灭背光并在唤醒后恢复。亮度范围为 1%–100%，需要小屏幕使用 0.8.1 或更新固件。")
                    }
                }

                Section("画面推送") {
                    Toggle("自动推送", isOn: model.aiMacScreenAutoPushBinding(for: device.id))
                    if config.autoPush {
                        Stepper("推送间隔 \(config.pushIntervalSeconds) 秒",
                                value: model.aiMacScreenIntervalBinding(for: device.id), in: 1...60)
                    }
                    if !model.aiMacScreenLosslessIDs.contains(device.id) {
                        Stepper("JPEG 质量 \(config.jpegQuality)%",
                                value: model.aiMacScreenJPEGQualityBinding(for: device.id), in: 50...90)
                    }
                    Button("立即推送") {
                        Task { await model.pushAIMacScreen(deviceID: device.id, force: true) }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    if let time = model.aiMacScreenLastPushText[device.id] {
                        LabeledContent("最后推送", value: time)
                    }
                }
            } else {
                Section {
                    Text("请先在设备管理中添加 AI Mac 小屏幕。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func aiMacBoardManagementRow(_ board: AIMacCanvasBoard,
                                         config: AIMacScreenDeviceSettings) -> some View {
        let isCurrent = config.canvasBoards.indices.contains(config.canvasBoardIndex)
            && config.canvasBoards[config.canvasBoardIndex].id == board.id
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Image(systemName: "rectangle.stack").font(.system(size: 12)).frame(width: 16)
            Button {
                if let deviceID = model.activeDeviceID(for: .aiMacScreen) {
                    model.applyAIMacCanvasBoard(deviceID: deviceID, boardID: board.id)
                    dragModules = nil
                    selected = .aiMacScreen
                }
            } label: {
                HStack(spacing: 5) {
                    Text(board.name).lineLimit(1)
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Toggle("", isOn: Binding(get: { board.isSidebarVisible }, set: {
                model.setAIMacCanvasBoardSidebarVisible(id: board.id, visible: $0)
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini).frame(width: 44)
            Toggle("", isOn: Binding(get: { board.participatesInRotation }, set: {
                model.setAIMacCanvasBoardRotationEnabled(id: board.id, enabled: $0)
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini).frame(width: 44)
            HStack(spacing: 6) {
                Button {
                    aiMacBoardRenameTarget = board
                    aiMacBoardRenameDraft = board.name
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                Button(role: .destructive) {
                    model.removeAIMacCanvasBoard(id: board.id)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            .frame(width: 50)
        }
        .padding(.vertical, 2)
        .onDrag {
            draggedAIMacBoard = board
            dragAIMacBoards = config.canvasBoards
            return NSItemProvider(object: board.id.uuidString as NSString)
        }
    }

    /// 摘录画板管理：每台设备独立排序，并分别控制侧边栏显示、自动轮播与设备推送。
    private var excerptBoardManagementForm: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "quote.opening")
                        .foregroundStyle(.secondary)
                    Text("正在管理")
                    HelpIcon(text: "每台摘录设备的画板、显示顺序、推送与轮播设置相互独立；此页只影响当前选中的设备。")
                    Spacer()
                    if model.enabledDevices(for: .excerpt).count > 1 {
                        Picker("", selection: model.activeExcerptBinding) {
                            ForEach(model.enabledDevices(for: .excerpt)) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    } else {
                        Text(model.activeDevice(for: .excerpt)?.name ?? "未选择设备")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11))
                        .foregroundStyle(.clear)
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 11))
                        .foregroundStyle(.clear)
                        .frame(width: 16)
                    Text("画板")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("侧栏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44)
                    Text("轮播")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44)
                    Color.clear.frame(width: 50, height: 1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                let boards = dragExcerptBoards ?? model.settings.excerptCanvasBoards
                if boards.isEmpty {
                    Text("尚未创建画板")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    reorderList(items: boards,
                                dragged: $draggedExcerptBoard,
                                dragItems: $dragExcerptBoards,
                                commit: { model.commitExcerptCanvasBoards($0) }) { board in
                        excerptBoardManagementRow(board)
                    }
                }
                Button("创建新的画板") {
                    model.addExcerptCanvasBoard()
                    selected = .excerptCanvas
                }
            } header: {
                HStack(spacing: 4) {
                    Text("画板（拖拽排序）")
                    HelpIcon(text: "拖动排序决定侧边栏、系统菜单与自动轮播顺序；关闭“侧栏”后不再显示，关闭“轮播”后不会被自动切换。")
                }
            }

            Section("显示设置") {
                HStack(spacing: 4) {
                    Text("底色模式")
                    HelpIcon(text: "手动切换深色/亮色底色：亮色模式为白底深字，避免墨水屏长时间显示黑色底色。")
                }
                Picker("", selection: model.excerptBackgroundModeBinding) {
                    ForEach(CanvasBackgroundMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle(isOn: model.excerptImageRotate180Binding) {
                    HStack(spacing: 4) {
                        Text("旋转 180°")
                        HelpIcon(text: "仅将实际推送的画面旋转 180°；软件预览始终保持正向。")
                    }
                }
                Picker(selection: model.excerptLayoutColumnsBinding) {
                    Text("单列").tag(1)
                    Text("双列").tag(2)
                } label: {
                    HStack(spacing: 4) {
                        Text("模块布局")
                        HelpIcon(text: "双列布局中，可在具体画板的“当前组合”内让模块占满整行。")
                    }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: model.showExcerptSourceBinding) {
                    HStack(spacing: 4) {
                        Text("显示语录出处")
                        HelpIcon(text: "摘录语录模块在底部显示语录出处；没有确切出处的语录不显示。")
                    }
                }
                Toggle(isOn: model.excerptPushRawImageBinding) {
                    HStack(spacing: 4) {
                        Text("推送原始彩色图片")
                        HelpIcon(text: "开启后由 Dot 服务端按所选算法转换；关闭时推送本地灰阶与抖动处理后的画面。")
                    }
                }
                if model.settings.excerptPushRawImage {
                    Picker("服务端抖动方式", selection: model.excerptServerDitherTypeBinding) {
                        ForEach(DotServerDitherType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    Picker("服务端抖动核", selection: model.excerptServerDitherKernelBinding) {
                        ForEach(DotServerDitherKernel.allCases) { kernel in
                            Text(kernel.title).tag(kernel)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Button("测试推送") { Task { await model.pushExcerptCanvas() } }
                    Button("查询设备状态") { Task { await model.checkDotDeviceStatus() } }
                        .controlSize(.small)
                }
                if !model.dotDeviceStatusText.isEmpty {
                    Text(model.dotDeviceStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                HStack(spacing: 4) {
                    Text("摘录设备")
                    HelpIcon(text: "API Key 与序列号请在“设备管理”中设置。测试推送会立即发送当前画板。")
                }
            }

            Section("自动推送与轮换") {
                Toggle(isOn: model.excerptAutoPushEnabledBinding) {
                    HStack(spacing: 4) {
                        Text("自动推送画布")
                        HelpIcon(text: "开启后立即推送一次；之后内容变化时立即推送，无变化则按间隔检查。")
                    }
                }
                if model.settings.excerptAutoPushEnabled {
                    Stepper("推送间隔 \(model.settings.excerptAutoPushMinutes) 分钟",
                            value: model.excerptAutoPushMinutesBinding, in: 1...1440)
                }
                Divider()
                Toggle(isOn: model.excerptBoardRotationEnabledBinding) {
                    HStack(spacing: 4) {
                        Text("自动轮换画板")
                        HelpIcon(text: "按管理页排序循环切换同时开启“侧栏”和“轮播”的画板，每次切换后立即推送。")
                    }
                }
                if model.settings.excerptBoardRotationEnabled {
                    Stepper("轮换间隔 \(model.settings.excerptBoardRotationMinutes) 分钟",
                            value: model.excerptBoardRotationMinutesBinding, in: 1...1440)
                }
                if model.excerptRotationBoardCount < 2 {
                    Text("至少需要两块同时开启“侧栏”和“轮播”的画板，自动轮播才会开始。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.settings.excerptBoardRotationEnabled {
                    Text("当前：\(model.excerptCanvasBoardName) · 下一块：\(model.nextExcerptCanvasBoardName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
        .alert("重命名摘录画板", isPresented: Binding(
            get: { excerptBoardRenameTarget != nil },
            set: { if !$0 { excerptBoardRenameTarget = nil } })) {
            TextField("画板名称", text: $excerptBoardRenameDraft)
            Button("确定") {
                if let board = excerptBoardRenameTarget {
                    model.renameExcerptCanvasBoard(id: board.id, to: excerptBoardRenameDraft)
                }
                excerptBoardRenameTarget = nil
            }
            Button("取消", role: .cancel) { excerptBoardRenameTarget = nil }
        }
        .task { await model.checkDotDeviceStatus() }
    }

    private func excerptBoardManagementRow(_ board: ExcerptCanvasBoard) -> some View {
        let index = model.settings.excerptCanvasBoards.firstIndex(where: { $0.id == board.id }) ?? 0
        let isCurrent = model.settings.excerptCanvasBoards.indices.contains(index)
            && index == model.settings.excerptCanvasBoardIndex
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Image(systemName: "rectangle.stack")
                .font(.system(size: 12))
                .frame(width: 16)
            Button {
                model.applyExcerptCanvasBoard(at: index)
                selected = .excerptCanvas
            } label: {
                HStack(spacing: 5) {
                    Text(board.name).lineLimit(1)
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Toggle("", isOn: Binding(
                get: { board.isSidebarVisible },
                set: { model.setExcerptCanvasBoardSidebarVisible(id: board.id, visible: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(width: 44)
                .help("在该设备的侧边栏与系统菜单中显示")
            Toggle("", isOn: Binding(
                get: { board.participatesInRotation },
                set: { model.setExcerptCanvasBoardRotationEnabled(id: board.id, enabled: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(width: 44)
                .help("加入自动轮播")
            HStack(spacing: 6) {
                Button {
                    excerptBoardRenameTarget = board
                    excerptBoardRenameDraft = board.name
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("重命名画板")
                Button(role: .destructive) {
                    model.removeExcerptCanvasBoard(at: index)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("删除画板")
            }
            .frame(width: 50)
        }
        .padding(.vertical, 2)
        .onDrag {
            draggedExcerptBoard = board
            dragExcerptBoards = model.settings.excerptCanvasBoards
            return NSItemProvider(object: board.id.uuidString as NSString)
        }
        .help("点击名称编辑；拖拽排序")
    }

    /// 卡片轮换（键盘功能设置）：开关、间隔与轮换卡片内容排序（按键盘设备独立记录）
    private var cardRotationForm: some View {
        Group {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                    Text("正在管理")
                    HelpIcon(text: "每台灵犀68 键盘的卡片列表与卡片内容相互独立；此页只影响当前选中的键盘。")
                    Spacer()
                    if model.enabledDevices(for: .keyboard).count > 1 {
                        Picker("", selection: model.activeKeyboardBinding) {
                            ForEach(model.enabledDevices(for: .keyboard)) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    } else {
                        Text(model.activeDevice(for: .keyboard)?.name ?? "未选择设备")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("自动轮播") {
                Toggle(isOn: model.cardRotationEnabledBinding) {
                    HStack(spacing: 4) {
                        Text("卡片页面自动轮播")
                        HelpIcon(text: "开启后按卡片管理中的顺序，在键盘上循环切换已加入自动循环的卡片。轮换范围 1 分钟至 1 小时。")
                    }
                }
                if model.settings.cardRotationEnabled {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("轮换间隔")
                            Spacer()
                            Text(Self.rotationIntervalText(model.settings.cardRotationMinutes))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: model.cardRotationMinutesBinding, in: 1...60, step: 1)
                    }
                }
            }
            Section {
                // 表头：说明每列开关对应的功能
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11))
                        .foregroundStyle(.clear)
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11))
                        .foregroundStyle(.clear)
                        .frame(width: 16)
                    Text("卡片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("侧栏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44)
                    Text("轮换")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                let cards = dragCardPanels ?? model.activeKeyboardCardList
                if cards.isEmpty {
                    Text("尚未添加卡片，从下方「添加到侧栏」选择。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    reorderList(items: cards, dragged: $draggedCardPanel, dragItems: $dragCardPanels,
                                commit: { model.commitKeyboardCardOrder($0) }) { panel in
                        cardManagementRow(panel)
                    }
                }
            } header: {
                HStack(spacing: 4) {
                    Text("卡片（拖拽排序）")
                    HelpIcon(text: "拖动排序决定侧栏和自动轮播顺序；“侧栏”关闭后不显示该卡片，“轮换”开启后该卡片参与自动轮播。")
                }
            }
            if !model.keyboardHiddenCardList.isEmpty {
                Section("添加到侧栏") {
                    ForEach(model.keyboardHiddenCardList) { panel in
                        Button { model.setKeyboardCardVisible(panel, visible: true) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: panel.icon)
                                    .font(.system(size: 12))
                                    .frame(width: 16)
                                Text(panel.title)
                                if panel.isBeta {
                                    BetaBadge()
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 卡片管理列表中的一行：拖拽排序 + 侧栏显示开关 + 加入自动循环开关（开关固定列宽右对齐）
    private func cardManagementRow(_ panel: Panel) -> some View {
        let inRotation = panel.displayMode.map { model.settings.cardRotationModes.contains($0.rawValue) } ?? false
        let displayTitle = model.bambuCardTitle(for: panel) ?? panel.title
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Image(systemName: panel.icon)
                .font(.system(size: 12))
                .frame(width: 16)
            Text(displayTitle)
            if panel.isBeta {
                BetaBadge()
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { true },
                set: { model.setKeyboardCardVisible(panel, visible: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(width: 44)
                .help("在侧边栏显示该卡片")
            Toggle("", isOn: Binding(
                get: { inRotation },
                set: { on in
                    if on, let mode = panel.displayMode {
                        model.addCardRotationMode(mode)
                    } else if let mode = panel.displayMode {
                        model.removeCardRotationMode(mode)
                    }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(width: 44)
                .help("加入自动循环")
        }
        .padding(.vertical, 2)
        .onDrag {
            draggedCardPanel = panel
            dragCardPanels = model.activeKeyboardCardList
            return NSItemProvider(object: panel.rawValue as NSString)
        }
        .help("拖拽排序")
    }

    /// 画板面板：组合功能模块，实时预览
    private var canvasForm: some View {
        Group {
            canvasModuleEditor(owner: .keyboard,
                               modulesRaw: model.settings.canvasModules,
                               moduleList: dragModules ?? model.settings.canvasModuleList,
                               available: availableCanvasModules(CanvasModule.keyboardModules))
        }
    }

    /// 摘录语录键盘卡片页面：每分钟轮换一条语录推送到键盘，可手动切换下一条、按分类勾选轮换池
    private var excerptQuoteForm: some View {
        Group {
            Section {
                LabeledContent("当前语录", value: model.quoteDisplayText)
                HStack {
                    Button("切换到下一条") {
                        model.nextQuote()
                    }
                    HelpIcon(text: "语录每分钟自动轮换；切到本页即推送到键盘，之后语录变化时更新。手动切换会暂时固定当前语录。")
                    if model.quoteOverrideIndex != nil {
                        Button("恢复自动轮换") {
                            model.resetQuoteRotation()
                        }
                    }
                }
            }
            Section {
                ForEach(ExcerptQuoteCategory.allCases) { category in
                    Toggle(category.title,
                           isOn: model.excerptQuoteCategoryBinding(for: category))
                        .disabled(excerptCategoryIsLastSelected(category))
                }
            } header: {
                HStack(spacing: 4) {
                    Text("语录分类")
                    HelpIcon(text: "勾选要轮换的语录分类，轮换池 = 所选分类的语录合集；至少保留一个分类。切换分类后立即回到自动轮换。")
                }
            }
            Section {
                Toggle(isOn: model.showExcerptSourceBinding) {
                    HStack(spacing: 4) {
                        Text("显示语录出处")
                        HelpIcon(text: "开启后在页脚时钟位置显示语录出处并隐藏时钟；没有确切出处的语录会回退为正常页脚。")
                    }
                }
            }
        }
    }

    /// 是否为当前唯一勾选的分类（最后一个勾选不可取消，保证轮换池非空）
    private func excerptCategoryIsLastSelected(_ category: ExcerptQuoteCategory) -> Bool {
        model.settings.excerptQuoteCategories.count == 1
            && model.settings.excerptQuoteCategories.contains(category.rawValue)
    }

    /// Emoji 壁纸页面：输入 emoji、选排列方式、调大小，全屏铺满键盘屏幕
    private var emojiWallpaperForm: some View {
        Group {
            Section("表情与布局") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Emoji 表情")
                        HelpIcon(text: "多个 emoji 会循环重复排列并铺满整个键盘屏幕。")
                    }
                    TextField("输入要用作壁纸的 emoji，如 🌈🌟🦄", text: model.emojiWallpaperTextBinding,
                              prompt: Text("输入 emoji"))
                        .textFieldStyle(.roundedBorder)
                }
                Picker(selection: model.emojiWallpaperLayoutBinding) {
                    ForEach(EmojiWallpaperLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("排列方式")
                        HelpIcon(text: model.settings.emojiWallpaperLayout.subtitle)
                    }
                }
            }
            Section("大小与间隔") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Emoji 大小")
                        HelpIcon(text: "越大单个表情越大、铺满所需数量越少；越小越密集。")
                        Spacer()
                        Text("\(model.settings.emojiWallpaperSize) px")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.emojiWallpaperSizeBinding, in: 16...96, step: 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("表情间隔")
                        HelpIcon(text: "控制表情之间的空隙；0 为紧挨着排列。")
                        Spacer()
                        Text("\(model.settings.emojiWallpaperSpacing) px")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.emojiWallpaperSpacingBinding, in: 0...40, step: 2)
                }
                Toggle("显示底部时间", isOn: model.nowPlayingFooterVisibleBinding)
            }
        }
    }

    /// 少数派推荐键盘卡片页面：显示编辑推荐的最新文章（点击标题跳转网页），可手动刷新/调节刷新周期
    private var sspaiForm: some View {
        Group {
            Section {
                if model.sspaiArticles.isEmpty {
                    Text("正在获取少数派推荐文章…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.sspaiArticles.prefix(6).enumerated()), id: \.element.id) { index, article in
                        Button {
                            if let url = URL(string: "https://sspai.com/post/\(article.id)") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(index + 1). \(article.title)")
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                                Text(article.author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("在浏览器中打开：https://sspai.com/post/\(article.id)")
                    }
                }
                HStack(spacing: 4) {
                    Button("刷新推荐") {
                        Task { await model.refresh() }
                    }
                    HelpIcon(text: "推送到键盘的少数派推荐卡片最多显示三条内容。")
                }
            }
            Section("推送") {
                Toggle(isOn: model.sspaiRandomPushBinding) {
                    HStack(spacing: 4) {
                        Text("文章多于三条时，进入本页随机推送三条到键盘")
                        HelpIcon(text: "每次进入本页都会重新随机抽取三条推荐内容；文章不超过三条时按全部推送。")
                    }
                }
            }
            Section {
                Stepper("\(model.settings.sspaiRefreshMinutes) 分钟",
                        value: model.sspaiRefreshMinutesBinding, in: 5...240, step: 5)
            } header: {
                HStack(spacing: 4) {
                    Text("刷新周期")
                    HelpIcon(text: "到点自动重新抓取编辑推荐文章并推送到键盘；内容无变化时不会推送。点击标题可在浏览器打开原文。")
                }
            }
        }
        .onAppear {
            if model.settings.sspaiRandomPush {
                Task { await model.enterSspaiPage() }
            }
        }
    }

    /// 打印机模块只展示已经添加并启用的设备位，避免出现无法配置的空模块。
    private func availableCanvasModules(_ modules: [CanvasModule]) -> [CanvasModule] {
        let formlabsCount = model.enabledDevices(for: .formlabs).count
        return modules.filter { module in
            module.formlabsSlotIndex.map { $0 < formlabsCount } ?? true
        }
    }

    /// 画板模块组合编辑器（键盘画板与两个独立设备画板共用）
    @ViewBuilder
    private func canvasModuleEditor(owner: AppModel.CanvasOwner,
                                    modulesRaw: [Int],
                                    moduleList: [CanvasModule],
                                    available: [CanvasModule],
                                    showFullWidthToggle: Bool = false) -> some View {
        Section {
            if moduleList.isEmpty {
                Text("尚未添加模块，从下方选择添加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                reorderList(items: moduleList, dragged: $draggedModule, dragItems: $dragModules,
                            commit: { model.commitCanvasModules($0, owner: owner) }) { module in
                    canvasModuleCurrentRow(module, owner: owner, moduleList: moduleList,
                                          showFullWidthToggle: showFullWidthToggle)
                }
            }
        } header: {
            HStack(spacing: 4) {
                Text("当前组合（自上而下）")
                HelpIcon(text: "模块自上而下排列成一张卡片；模块越多，每块会越紧凑。拖动模块可以调整顺序，展开右侧箭头可以调整模块设置。")
            }
        }
        Section("添加模块") {
            ForEach(available) { module in
                canvasModuleAddRow(module, owner: owner, modulesRaw: modulesRaw)
            }
        }
    }

    /// 当前组合中的模块行（含拖拽排序/展开设置/删除；双列布局时可切换占满整行）
    private func canvasModuleCurrentRow(_ module: CanvasModule,
                                        owner: AppModel.CanvasOwner,
                                        moduleList: [CanvasModule],
                                        showFullWidthToggle: Bool = false) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                // 标签栏主体（拖拽把手/图标/标题/弹性空白）整段可点击展开/收起设置，
                // 按钮（占满整行/展开箭头/删除）保持各自独立交互
                Group {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Image(systemName: module.icon)
                        .font(.system(size: 12))
                        .frame(width: 16)
                    Text(model.canvasModuleTitle(module))
                    if module.isBeta {
                        BetaBadge()
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleModuleExpanded(module) }
                if showFullWidthToggle {
                    let isFullWidth = model.settings.excerptFullWidthModules.contains(module.rawValue)
                    Button { model.toggleExcerptFullWidth(module) } label: {
                        Image(systemName: "arrow.left.and.right")
                            .foregroundStyle(isFullWidth ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(isFullWidth ? "取消占满整行" : "占满整行（双列布局下横跨两列）")
                }
                if canvasHasSettings(module) {
                    Button {
                        toggleModuleExpanded(module)
                    } label: {
                        Image(systemName: expandedModule == module ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .help(expandedModule == module ? "收起设置" : "展开设置")
                }
                Button(role: .destructive) { model.removeCanvasModule(module, from: owner) } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 3)
            if expandedModule == module {
                canvasModuleSettings(module, owner: owner)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onDrag {
            draggedModule = module
            dragModules = moduleList
            return NSItemProvider(object: String(module.rawValue) as NSString)
        }
        .help("拖拽排序")
    }

    /// 「添加模块」列表中的一行
    private func canvasModuleAddRow(_ module: CanvasModule,
                                    owner: AppModel.CanvasOwner,
                                    modulesRaw: [Int]) -> some View {
        Button { model.addCanvasModule(module, to: owner) } label: {
            HStack(spacing: 10) {
                Image(systemName: module.icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(model.canvasModuleTitle(module))
                if module.isBeta {
                    BetaBadge()
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .foregroundStyle(modulesRaw.contains(module.rawValue)
                                     ? Color.secondary : Color.accentColor)
            }
        }
        .buttonStyle(.plain)
        .disabled(modulesRaw.contains(module.rawValue))
    }

    /// 单块口袋先知画板：只保留当前画板的模块内容编辑与预览。
    /// 排序、显示模式、设备推送、自动推送和轮换均集中在独立的画板管理页。
    private var oracleCanvasForm: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧主内容
            Form {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(Color.accentColor)
                        Text(model.oracleCanvasBoardName)
                            .font(.headline)
                        Spacer()
                        Text(model.activeDevice(for: .oracle)?.name ?? "未选择设备")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("当前画板")
                        HelpIcon(text: "本页只编辑这块画板的内容与模块。排序、显示模式、设备推送和自动轮换请前往“口袋先知画板管理”。")
                    }
                }
                canvasModuleEditor(owner: .oracle,
                                   modulesRaw: model.settings.oracleCanvasModules,
                                   moduleList: dragModules ?? model.settings.oracleCanvasModuleList,
                                   available: availableCanvasModules(CanvasModule.oraclePanelModules))
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, alignment: .top)

            Divider()
                .padding(.vertical, 4)

            // 右侧预览边栏：处理前 / 处理后 固定垂直排列；宽度固定适中（比键盘 210 预览稍大）
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("处理前（彩色原始渲染）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            oracleHeroPreview(model.oracleCanvasRawImage, displayWidth: 240)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("处理后（实际效果）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            oracleHeroPreview(model.oracleCanvasImage, displayWidth: 240)
                        }
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("画板预览")
                        HelpIcon(text: "上下两图均为设备效果图：画布按 200×200 与设备屏幕显示范围 1:1 对齐叠加；上方为灰阶/抖动处理前的彩色原始渲染，下方为处理后的实际效果（固定 200×200 / 184 PPI，不超屏）。")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 280)
        }
        .padding(.bottom, 12)
        .alert("重命名画板", isPresented: Binding(
            get: { boardRenameTarget != nil },
            set: { if !$0 { boardRenameTarget = nil } })) {
            TextField("画板名称", text: $boardRenameDraft)
            Button("确定") {
                if let board = boardRenameTarget {
                    model.renameOracleCanvasBoard(id: board.id, to: boardRenameDraft)
                }
                boardRenameTarget = nil
            }
            Button("取消", role: .cancel) {
                boardRenameTarget = nil
            }
        }
        .onAppear {
            model.refreshOracleCanvasPreview()
            model.ensureRand0Session()
        }
    }

    /// 画板列表中的一行：点击选中/套用、拖拽排序、删除
    private func oracleCanvasBoardRow(_ board: OracleCanvasBoard) -> some View {
        let index = model.settings.oracleCanvasBoards.firstIndex(of: board) ?? 0
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Button {
                model.applyOracleCanvasBoard(at: index)
            } label: {
                HStack(spacing: 6) {
                    Text(board.name)
                    if index == model.settings.oracleCanvasBoardIndex {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                boardRenameTarget = board
                boardRenameDraft = board.name
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("重命名画板")
            Button(role: .destructive) {
                model.removeOracleCanvasBoard(at: index)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除该画板")
        }
        .contentShape(Rectangle())
        .onDrag {
            draggedBoard = board
            dragBoards = model.settings.oracleCanvasBoards
            return NSItemProvider(object: board.id.uuidString as NSString)
        }
        .help("点击选中；拖拽排序")
    }

    /// 单块摘录画板：只保留当前画板的模块内容编辑与预览。
    /// 排序、显示设置、设备推送、自动推送和轮换均集中在独立管理页。
    private var excerptCanvasForm: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(Color.accentColor)
                        Text(model.excerptCanvasBoardName)
                            .font(.headline)
                        Spacer()
                        Text(model.activeDevice(for: .excerpt)?.name ?? "未选择设备")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("当前画板")
                        HelpIcon(text: "本页只编辑这块画板的内容与模块。排序、显示设置、设备推送和自动轮换请前往“摘录画板管理”。")
                    }
                }
                canvasModuleEditor(owner: .excerpt,
                                   modulesRaw: model.settings.excerptCanvasModules,
                                   moduleList: dragModules ?? model.settings.excerptCanvasModuleList,
                                   available: availableCanvasModules(CanvasModule.excerptPanelModules),
                                   showFullWidthToggle: model.settings.excerptLayoutColumns == 2)
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, alignment: .top)

            Divider()
                .padding(.vertical, 4)

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("处理前（彩色原始渲染）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            excerptHeroPreview(model.excerptCanvasRawImage)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("处理后（按服务端算法近似）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            excerptHeroPreview(model.excerptCanvasImage)
                        }
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("画板预览")
                        HelpIcon(text: "上下两图按摘录设备 296×152 显示范围对齐；上方为彩色原始渲染，下方为设备处理后的效果。")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 310, maxWidth: .infinity, alignment: .top)
        }
        .padding(.bottom, 12)
        .onAppear { model.refreshExcerptCanvasPreview() }
    }

    /// 旧版合并页面保留为过渡实现；导航已切换到独立画板编辑与管理页。
    private var legacyExcerptCanvasForm: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧主内容
            Form {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "quote.opening")
                            .foregroundStyle(.secondary)
                        Text("正在管理")
                        HelpIcon(text: "画板编辑、排序、设备推送与自动推送均集中在本页；每台摘录设备相互独立。")
                        Spacer()
                        if model.enabledDevices(for: .excerpt).count > 1 {
                            Picker("", selection: model.activeExcerptBinding) {
                                ForEach(model.enabledDevices(for: .excerpt)) { device in
                                    Text(device.name).tag(device.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        } else {
                            Text(model.activeDevice(for: .excerpt)?.name ?? "未选择设备")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.settings.excerptCanvasBoards.isEmpty {
                        Text("当前为默认画布")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        reorderList(items: model.settings.excerptCanvasBoards,
                                    dragged: $draggedExcerptBoard,
                                    dragItems: $dragExcerptBoards,
                                    commit: { model.commitExcerptCanvasBoards($0) }) { board in
                            excerptCanvasBoardRow(board)
                        }
                    }
                    Button("创建新的画板") {
                        model.addExcerptCanvasBoard()
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("画板")
                        HelpIcon(text: "创建画板后自动保存当前修改；拖动决定侧栏和系统菜单栏中的显示顺序。")
                    }
                }
                Section {
                    Toggle(isOn: model.excerptPushRawImageBinding) {
                        HStack(spacing: 4) {
                            Text("推送原始彩色图片")
                            HelpIcon(text: "开启后直接推送彩色原图，由 Dot 服务端按所选抖动方式与抖动核转换；关闭时使用本地灰阶与抖动处理后的画面。")
                        }
                    }
                    if model.settings.excerptPushRawImage {
                        Picker(selection: model.excerptServerDitherTypeBinding) {
                            ForEach(DotServerDitherType.allCases) { type in
                                Text(type.title).tag(type)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("服务端抖动方式")
                                HelpIcon(text: "按官方指南传 ditherType 与 ditherKernel，由服务端完成灰度量化与抖动。")
                            }
                        }
                        Picker("服务端抖动核", selection: model.excerptServerDitherKernelBinding) {
                            ForEach(DotServerDitherKernel.allCases) { kernel in
                                Text(kernel.title).tag(kernel)
                            }
                        }
                    }
                    HStack {
                        Button("测试推送") {
                            Task { await model.pushExcerptCanvas() }
                        }
                        Button("查询设备状态") {
                            Task { await model.checkDotDeviceStatus() }
                        }
                        .controlSize(.small)
                    }
                    if !model.dotDeviceStatusText.isEmpty {
                        Text(model.dotDeviceStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("设备推送")
                        HelpIcon(text: "API Key 与序列号请在「设备管理」中设置。测试推送会立即把当前画板发送到对应 Dot 墨水屏。")
                    }
                }
                Section("自动推送") {
                    Toggle(isOn: model.excerptAutoPushEnabledBinding) {
                        HStack(spacing: 4) {
                            Text("自动推送画布")
                            HelpIcon(text: "开启后立即推送一次；之后内容变化时立即推送，无变化则按间隔推送。")
                        }
                    }
                    if model.settings.excerptAutoPushEnabled {
                        Stepper("推送间隔 \(model.settings.excerptAutoPushMinutes) 分钟",
                                value: model.excerptAutoPushMinutesBinding, in: 1...1440)
                    }
                }
                Section("显示设置") {
                    HStack(spacing: 4) {
                        Text("底色模式")
                        HelpIcon(text: "手动切换深色/亮色底色：亮色模式为白底深字，避免墨水屏长时间显示黑色底色；不随电脑或软件主题同步。")
                    }
                    Picker("", selection: model.excerptBackgroundModeBinding) {
                        ForEach(CanvasBackgroundMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Toggle(isOn: model.excerptImageRotate180Binding) {
                        HStack(spacing: 4) {
                            Text("旋转 180°")
                            HelpIcon(text: "将画面直接旋转 180°，适配设备安装方向；不会产生镜像。")
                        }
                    }
                    Picker(selection: model.excerptLayoutColumnsBinding) {
                        Text("单列").tag(1)
                        Text("双列").tag(2)
                    } label: {
                        HStack(spacing: 4) {
                            Text("模块布局")
                            HelpIcon(text: "双列布局：模块按两列排列，在「当前组合」中点击 ⇄ 图标可让该模块占满整行。")
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle(isOn: model.showExcerptSourceBinding) {
                        HStack(spacing: 4) {
                            Text("显示语录出处")
                            HelpIcon(text: "摘录语录模块在底部显示语录出处（替换时钟位置并隐藏时钟）；没有确切出处的语录不显示。")
                        }
                    }
                }
                canvasModuleEditor(owner: .excerpt,
                                   modulesRaw: model.settings.excerptCanvasModules,
                                   moduleList: dragModules ?? model.settings.excerptCanvasModuleList,
                                   available: availableCanvasModules(CanvasModule.excerptPanelModules),
                                   showFullWidthToggle: model.settings.excerptLayoutColumns == 2)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 720, alignment: .topLeading)

            Divider()
                .padding(.vertical, 4)

            // 右侧只保留预览；设备推送与间隔统一归入左侧画板管理。
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("处理前（彩色原始渲染）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            excerptHeroPreview(model.excerptCanvasRawImage)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("处理后（按服务端算法近似）")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            excerptHeroPreview(model.excerptCanvasImage)
                        }
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("画板预览")
                        HelpIcon(text: "上下两图按摘录设备 296×152 显示范围对齐；上方为彩色原始渲染，下方为设备处理后的效果。")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 310, maxWidth: .infinity, alignment: .top)
        }
        .padding(.bottom, 12)
        .alert("重命名摘录画板", isPresented: Binding(
            get: { excerptBoardRenameTarget != nil },
            set: { if !$0 { excerptBoardRenameTarget = nil } })) {
            TextField("画板名称", text: $excerptBoardRenameDraft)
            Button("确定") {
                if let board = excerptBoardRenameTarget {
                    model.renameExcerptCanvasBoard(id: board.id, to: excerptBoardRenameDraft)
                }
                excerptBoardRenameTarget = nil
            }
            Button("取消", role: .cancel) {
                excerptBoardRenameTarget = nil
            }
        }
        .onAppear { model.refreshExcerptCanvasPreview() }
        .task { await model.checkDotDeviceStatus() }
    }

    /// 摘录画板列表行：选中、重命名、删除、拖拽排序。
    private func excerptCanvasBoardRow(_ board: ExcerptCanvasBoard) -> some View {
        let index = model.settings.excerptCanvasBoards.firstIndex(of: board) ?? 0
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Button {
                model.applyExcerptCanvasBoard(at: index)
            } label: {
                HStack(spacing: 6) {
                    Text(board.name)
                    if index == model.settings.excerptCanvasBoardIndex {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                excerptBoardRenameTarget = board
                excerptBoardRenameDraft = board.name
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("重命名画板")
            Button(role: .destructive) {
                model.removeExcerptCanvasBoard(at: index)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除该画板")
        }
        .contentShape(Rectangle())
        .onDrag {
            draggedExcerptBoard = board
            dragExcerptBoards = model.settings.excerptCanvasBoards
            return NSItemProvider(object: board.id.uuidString as NSString)
        }
        .help("点击选中；拖拽排序")
    }

    /// 摘录画布在 quote_0 hero 设备框内的预览（画布对齐屏幕显示区）；无 hero 资源时回退纯图
    @ViewBuilder
    private func excerptHeroPreview(_ image: NSImage?) -> some View {
        if let hero = PreviewResources.heroImage, let image {
            let displayWidth: CGFloat = 600
            let scale = displayWidth / hero.size.width
            ZStack(alignment: .topLeading) {
                Image(nsImage: hero)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displayWidth)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: PreviewResources.heroScreenRect.width * scale,
                           height: PreviewResources.heroScreenRect.height * scale)
                    .position(x: PreviewResources.heroScreenRect.midX * scale,
                              y: (hero.size.height
                                  - PreviewResources.heroScreenRect.minY
                                  - PreviewResources.heroScreenRect.height / 2) * scale)
            }
            .frame(width: displayWidth, height: hero.size.height * scale)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help("画布已按设备屏幕区域对齐叠加")
        } else if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(296.0 / 152.0, contentMode: .fit)
                .frame(maxWidth: 340, maxHeight: 175)
        } else {
            ProgressView().frame(height: 120)
        }
    }

    /// 口袋先知画布在 Rand/0 hero 设备框内的预览（画布对齐屏幕显示区）；无 hero 资源时回退纯图。
    /// displayWidth 随右栏宽度自适应：窗口放大时预览同步放大，左右边距一致。
    @ViewBuilder
    private func oracleHeroPreview(_ image: NSImage?, displayWidth: CGFloat = 210) -> some View {
        if let hero = PreviewResources.oracleHeroImage, let image {
            let scale = displayWidth / hero.size.width
            ZStack(alignment: .topLeading) {
                Image(nsImage: hero)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displayWidth)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: PreviewResources.oracleHeroScreenRect.width * scale,
                           height: PreviewResources.oracleHeroScreenRect.height * scale)
                    .clipShape(RoundedRectangle(cornerRadius: PreviewResources.oracleHeroScreenCornerRadius * scale,
                                                style: .continuous))
                    .position(x: PreviewResources.oracleHeroScreenRect.midX * scale,
                              y: (hero.size.height
                                  - PreviewResources.oracleHeroScreenRect.minY
                                  - PreviewResources.oracleHeroScreenRect.height / 2) * scale)
            }
            .frame(width: displayWidth, height: hero.size.height * scale)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help("画布已按设备屏幕区域对齐叠加")
        } else if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 116, height: 116)
        } else {
            ProgressView().frame(width: 116, height: 116)
        }
    }

    /// 该模块是否有可展开的设置（所有模块都可调上下边距，故均可展开）
    private func canvasHasSettings(_ module: CanvasModule) -> Bool {
        true
    }

    /// 展开/收起模块设置（带过渡动画；标签栏整段与展开箭头共用）
    private func toggleModuleExpanded(_ module: CanvasModule) {
        withAnimation(.easeInOut(duration: 0.15)) {
            expandedModule = expandedModule == module ? nil : module
        }
    }

    /// 模块上下边距（紧凑度）滑杆绑定：显示手动设置值（0 = 自适应模式，滑杆归零即恢复自适应）
    private func canvasMarginBinding(for module: CanvasModule) -> Binding<Double> {
        Binding(
            get: { Double(self.model.settings.manualCanvasMargin(for: module)) },
            set: { self.model.settings.setCanvasMargin(Int($0), for: module) }
        )
    }

    /// 画板打印机模块的单个显示信息开关绑定（按画板归属读写：每台键盘/先知/摘录各自独立）
    private func canvasPrinterFieldBinding(_ module: CanvasModule, owner: AppModel.CanvasOwner,
                                           _ keyPath: WritableKeyPath<CanvasPrinterFields, Bool>) -> Binding<Bool> {
        Binding(get: {
            let stored = self.model.canvasPrinterFields(for: owner)[module.rawValue] ?? .default
            return stored[keyPath: keyPath]
        }, set: { v in
            var dict = self.model.canvasPrinterFields(for: owner)
            var fields = dict[module.rawValue] ?? .default
            fields[keyPath: keyPath] = v
            dict[module.rawValue] = fields
            self.model.setCanvasPrinterFields(dict, for: owner)
        })
    }

    /// 墨水屏画板「正在播放」横向排布开关绑定（先知/摘录各持独立设置）
    private func nowPlayingHorizontalBinding(for owner: AppModel.CanvasOwner) -> Binding<Bool> {
        Binding(get: { model.nowPlayingHorizontal(for: owner) },
                set: { model.setNowPlayingHorizontal($0, for: owner) })
    }

    private func nowPlayingSmartBackgroundBinding(for owner: AppModel.CanvasOwner) -> Binding<Bool> {
        Binding(get: { model.nowPlayingSmartBackground(for: owner) },
                set: { model.setNowPlayingSmartBackground($0, for: owner) })
    }

    private func nowPlayingCoverBinding(for owner: AppModel.CanvasOwner) -> Binding<Bool> {
        Binding(get: { model.nowPlayingCover(for: owner) },
                set: { model.setNowPlayingCover($0, for: owner) })
    }

    @ViewBuilder
    private func linkedLyricsKeyboardPicker(owner: AppModel.CanvasOwner) -> some View {
        let keyboards = model.enabledDevices(for: .keyboard)
        if keyboards.isEmpty {
            HStack(spacing: 4) {
                Text("歌词联动：请先添加灵犀 68 键盘")
                    .foregroundStyle(.secondary)
                HelpIcon(text: "添加键盘后，可把这台设备的正在播放页面与指定键盘关联。")
            }
        } else {
            Picker(selection: model.lyricsKeyboardBinding(for: owner)) {
                Text("不关联").tag(nil as UUID?)
                ForEach(keyboards) { keyboard in
                    Text(keyboard.name).tag(Optional(keyboard.id))
                }
            } label: {
                HStack(spacing: 4) {
                    Text("歌词联动到灵犀 68")
                    HelpIcon(text: "关联后会自动关闭目标键盘的卡片轮播、切换到“正在播放”，并让该页面仅显示当前及相邻歌词。歌曲名、歌手、专辑和时长仅在换歌时发送给 LRCLIB 查询歌词；歌词会在本机缓存并按播放进度切换。取消关联后不会自动恢复先前的轮播设置。")
                }
            }
            .pickerStyle(.menu)
        }
    }

    /// 模块行内展开的设置内容
    @ViewBuilder
    private func canvasModuleSettings(_ module: CanvasModule, owner: AppModel.CanvasOwner) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("上下边距", systemImage: "arrow.up.and.down")
                        .font(.system(size: 12, weight: .medium))
                    HelpIcon(text: "0 为自适应；数值越大，模块越紧凑。自适应会按模块类型选择合适间距。")
                    Spacer()
                    if model.settings.manualCanvasMargin(for: module) == 0 {
                        Text("自适应")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(model.settings.manualCanvasMargin(for: module))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Slider(value: canvasMarginBinding(for: module), in: 0...40, step: 1)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04)))
            switch module {
            case .clock, .date:
                HStack(spacing: 4) {
                    Text("使用全局时间与日期格式")
                    HelpIcon(text: "时间和日期格式在“设置 → 时间与日期”统一调整，所有界面共用同一份。")
                }
            case .text:
                TextField("画板文字", text: model.canvasTextBinding)
                    .textFieldStyle(.roundedBorder)
            case .nowPlaying:
                Toggle("大尺寸专辑封面", isOn: nowPlayingCoverBinding(for: owner))
                if owner == .oracle || owner == .aiMac {
                    linkedLyricsKeyboardPicker(owner: owner)
                }
                // 键盘和 AI Mac 彩色画板可使用整板封面取色；墨水屏保持手动底色。
                if owner == .keyboard || owner == .aiMac {
                    Toggle(isOn: nowPlayingSmartBackgroundBinding(for: owner)) {
                        HStack(spacing: 4) {
                            Text("智能封面取色背景")
                            HelpIcon(text: "使用专辑封面主色替换整张画板背景，并自动生成高对比文字、进度强调色与封面描边。")
                        }
                    }
                }
                if owner != .keyboard {
                    Toggle(isOn: nowPlayingHorizontalBinding(for: owner)) {
                        HStack(spacing: 4) {
                            Text("横向排布（封面在左）")
                            HelpIcon(text: "开启后封面居左、歌名歌手居右；关闭后使用封面在上、文字在下的竖向布局。")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("歌名字号")
                        HelpIcon(text: "画板内正在播放模块的字号；文字过宽时仍会自动收缩以保证完整显示。")
                        Spacer()
                        Text("\(model.settings.canvasNowPlayingTitleSize) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.canvasNowPlayingTitleSizeBinding, in: 7...24, step: 1)
                    HStack {
                        Text("歌手信息字号")
                        Spacer()
                        Text("\(model.settings.canvasNowPlayingArtistSize) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.canvasNowPlayingArtistSizeBinding, in: 6...20, step: 1)
                }
            case .image:
                if owner == .keyboard {
                    Picker(selection: model.canvasImageModeBinding) {
                        ForEach(CanvasImageMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("图像模式")
                            HelpIcon(text: "“背景”会完整显示为底层并自动加深，其他模块叠加在上方；“叠加”会把图片作为普通模块显示。")
                        }
                    }
                } else {
                    HStack {
                        Button("选择图片…") { Task { await model.pickCanvasImage(for: owner) } }
                        HelpIcon(text: "为当前画板独立选择图片，与键盘自定义图片互不影响；图片模块固定作为模块叠加显示。")
                        Spacer()
                        Text(model.canvasImageName(for: owner) ?? "未选择")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .sspai:
                Stepper("显示 \(model.sspaiCount(for: owner)) 条",
                        value: model.sspaiCountBinding(for: owner), in: 1...6)
                Toggle(isOn: model.sspaiRandomBinding(for: owner)) {
                    HStack(spacing: 4) {
                        Text("随机显示")
                        HelpIcon(text: "文章多于显示条数时，每次刷新随机挑选一批；关闭后固定显示最新几篇。")
                    }
                }
            case .qwenQuota:
                Picker(selection: model.qwenQuotaShowPercentBinding) {
                    Text("百分比").tag(true)
                    Text("额度数值").tag(false)
                } label: {
                    HStack(spacing: 4) {
                        Text("显示方式")
                        HelpIcon(text: "百分比会大字显示剩余百分比；额度数值会大字显示剩余额度数字。")
                    }
                }
                .pickerStyle(.segmented)
            case .homeAssistant:
                let selectedIDs = model.canvasHAEntityIDs(for: owner)
                HStack(spacing: 4) {
                    EntityDomainPicker(title: "显示实体（可多选）",
                                   selection: .constant(""),
                                   entities: model.haSnapshot.entities,
                                   emptyLabel: "\(selectedIDs.count) 个已选",
                                   allowClear: false,
                                   multiSelect: true,
                                   lockedIDs: Set(selectedIDs),
                                   onMultiConfirm: { model.addCanvasHAEntities($0, for: owner) })
                    HelpIcon(text: "模块会根据当前画板选择的实体数量自动调整占比；各画板分别保存自己的实体列表，不会自动沿用其他卡片或画板。")
                }
                if selectedIDs.isEmpty {
                    Text("尚未选择实体")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(selectedIDs, id: \.self) { id in
                        HStack(spacing: 6) {
                            let entity = model.haSnapshot.entities.first { $0.entityId == id }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entity?.displayName ?? id)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                if entity != nil {
                                    Text(id)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            Button(role: .destructive) {
                                model.removeCanvasHAEntity(id, from: owner)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("从此画板移除")
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.035)))
                    }
                }
            case .bambuLab, .bambuLab2, .bambuLab3, .bambuLab4, .bambuLab5:
                HStack(spacing: 4) {
                    Text("显示信息")
                    HelpIcon(text: "每个打印机模块独立配置；关闭项目会释放对应空间。多台打印机或空间较小时会自动缩小状态文字、使用细进度条，并把时间合并到进度附近。")
                }
                Toggle("工作状态", isOn: canvasPrinterFieldBinding(module, owner: owner, \.showStatus))
                Toggle("打印进度", isOn: canvasPrinterFieldBinding(module, owner: owner, \.showProgress))
                Toggle("当前任务", isOn: canvasPrinterFieldBinding(module, owner: owner, \.showTask))
                Toggle("喷嘴温度", isOn: canvasPrinterFieldBinding(module, owner: owner, \.showNozzleTemp))
                Toggle("热床温度", isOn: canvasPrinterFieldBinding(module, owner: owner, \.showBedTemp))
                Toggle("时间信息", isOn: canvasPrinterFieldBinding(module, owner: owner, \.showRemaining))
                Toggle("错误码 / 故障原因", isOn: canvasPrinterFieldBinding(module, owner: owner, \.showError))
            case .formlabs, .formlabs2, .formlabs3, .formlabs4, .formlabs5:
                if let device = model.formlabsDevice(for: module) {
                    HStack(spacing: 4) {
                        Text("显示内容")
                        HelpIcon(text: "这些选项与该打印机的独立卡片同步。画板会根据空间自动切换纵向或左右布局，空间不足时优先保留设备名、状态、进度、任务名称和剩余时间。")
                    }
                    Toggle("任务缩略图",
                           isOn: model.formlabsBoolBinding(for: device.id, \.showThumbnail))
                    Toggle("当前层数",
                           isOn: model.formlabsBoolBinding(for: device.id, \.showLayers))
                    Toggle("耗材种类",
                           isOn: model.formlabsBoolBinding(for: device.id, \.showMaterial))
                } else {
                    Text("对应的 Formlabs 打印机已经停用或移除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }

    @ViewBuilder
    private var nowPlayingForm: some View {
        Section {
            LabeledContent("当前媒体", value: model.nowPlaying.title.isEmpty || model.nowPlaying.title == "未在播放"
                           ? "未在播放" : model.nowPlaying.title)
            LabeledContent("艺术家", value: model.nowPlaying.artist.isEmpty ? "—" : model.nowPlaying.artist)
            LabeledContent("状态", value: model.nowPlaying.isPlaying ? "播放中" : "已暂停 / 未播放")
            if model.nowPlaying.duration > 0 {
                LabeledContent("进度", value: model.nowPlayingSummary)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("推送间隔")
                    Spacer()
                    Text("\(model.settings.dynamicUploadSeconds) 秒")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: model.dynamicUploadBinding, in: 2...60, step: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("歌名字号")
                    HelpIcon(text: "推送到键盘的「正在播放」卡片字号；超宽时自动收缩以保证显示完整。")
                    Spacer()
                    Text("\(model.settings.nowPlayingTitleSize) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: model.nowPlayingTitleSizeBinding, in: 7...24, step: 1)
                HStack {
                    Text("歌手信息字号")
                    Spacer()
                    Text("\(model.settings.nowPlayingArtistSize) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: model.nowPlayingArtistSizeBinding, in: 6...20, step: 1)
            }
            Toggle(isOn: model.nowPlayingFooterVisibleBinding) {
                HStack(spacing: 4) {
                    Text("显示底部时间日期")
                    HelpIcon(text: "关闭后底部时间/日期隐藏：专辑封面垂直居中，歌名/进度条信息贴到底部并保留安全区。")
                }
            }
            if model.settings.nowPlayingFooterVisible {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("时间字号")
                        HelpIcon(text: "页脚时间与日期使用全局格式，可在「设置 → 时间与日期」调整。")
                        Spacer()
                        Text("\(model.settings.nowPlayingTimeSize) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.nowPlayingTimeSizeBinding, in: 10...40, step: 1)
                    HStack {
                        Text("日期字号")
                        Spacer()
                        Text("\(model.settings.nowPlayingDateSize) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.nowPlayingDateSizeBinding, in: 8...30, step: 1)
                }
            }
            HStack(spacing: 4) {
                Button("刷新") {
                    Task { await model.refresh() }
                }
                HelpIcon(text: "数据来自系统「正在播放」，支持音乐、浏览器、Spotify 等播放器；封面主色会自动用作卡片背景。")
            }
        }
    }

    @ViewBuilder
    private var appearanceForm: some View {
        Section {
            Picker(selection: model.appearanceBinding) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("软件明暗模式")
                    HelpIcon(text: "控制软件窗口界面（菜单、面板、预览区域）的明暗显示：跟随系统、浅色或深色。")
                }
            }
        }
        Section("卡片外观") {
            Picker(selection: model.themeBinding) {
                ForEach(CardTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("卡片主题")
                    HelpIcon(text: "卡片主题决定强调色基调（选择「跟随主题」时生效）；这些设置作用于推送到设备的卡片画面。")
                }
            }
            Picker(selection: model.backgroundToneBinding) {
                ForEach(BackgroundTone.allCases) { tone in
                    Text(tone.title).tag(tone)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("背景底色")
                    HelpIcon(text: "选择「跟随软件明暗」时，卡片背景会随软件明暗模式切换深浅。")
                }
            }
            if model.settings.backgroundTone == .custom {
                ColorPicker("自定义背景色", selection: model.customBackgroundBinding, supportsOpacity: false)
            }
            Picker("强调色", selection: model.accentToneBinding) {
                ForEach(AccentTone.allCases) { tone in
                    Text(tone.title).tag(tone)
                }
            }
            if model.settings.accentTone == .custom {
                ColorPicker("自定义强调色", selection: model.customAccentBinding, supportsOpacity: false)
            }
        }
    }

    /// Home Assistant 卡片页面：实体选择 + 异常监控（服务器连接设置只在「设备管理」中提供）
    @ViewBuilder
    private var homeAssistantForm: some View {
        Section {
            let entityRefs = dragHAEntities ?? model.haEntityList.map(HAEntityRef.init)
            if entityRefs.isEmpty {
                Text("尚未添加实体")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                reorderList(items: entityRefs,
                            dragged: $draggedHAEntity,
                            dragItems: $dragHAEntities,
                            commit: { refs in
                                model.haEntitiesBinding.wrappedValue = refs.map(\.id)
                            }) { ref in
                    haEntityRow(ref)
                }
            }
            HAEntityAdder(entities: model.haSnapshot.entities,
                          alreadyAdded: Set(model.haEntityList)) { entityIDs in
                model.addHAEntitiesBatch(entityIDs)
            }
            // 拉取失败或未连接时给出明确原因（服务器设置只在「设备管理 → Home Assistant 连接」提供）
            if let error = model.haSnapshot.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if model.settings.haServerURL.isEmpty {
                Text("尚未配置服务器：请在「设备管理」中添加 Home Assistant 设备并填写地址与长期访问令牌。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 4) {
                Text("实体选择")
                HelpIcon(text: "这里选中的实体用于键盘「Home Assistant」卡片和画板模块，按列表顺序显示；camera.* 与 image.* 会抓取静态帧，不建立视频流。单个图片实体显示大图，和其他实体混排时显示横向预览卡。拖拽排序、点 × 移除；服务器地址与令牌请在「设备管理 → Home Assistant」中填写。")
            }
        }
        Section("异常监控") {
            Toggle("开启实体异常监控", isOn: model.haMonitorEnabledBinding)
            if model.settings.haMonitorEnabled {
                HStack(spacing: 4) {
                    EntityDomainPicker(title: "状态实体",
                                       selection: model.haMonitorEntityIDBinding,
                                       entities: model.haSnapshot.entities,
                                       emptyLabel: "未选择",
                                       clearLabel: "不使用")
                    HelpIcon(text: "该实体的状态不等于下面的期望值即视为异常（例如 Bambu Lab 打印机正常时为 idle/standby）。")
                }
                HStack(spacing: 4) {
                    TextField("期望的正常状态值", text: model.haMonitorExpectedStateBinding)
                        .textFieldStyle(.roundedBorder)
                    HelpIcon(text: "留空则不做状态判定，只按错误码实体判定。")
                        .fixedSize()
                }
                HStack(spacing: 4) {
                    EntityDomainPicker(title: "错误码实体（可选）",
                                       selection: model.haMonitorErrorEntityIDBinding,
                                       entities: model.haSnapshot.entities,
                                       emptyLabel: "不使用",
                                       clearLabel: "不使用")
                    HelpIcon(text: "错误码实体的值非空（且不是 none/正常/off）即视为异常；两个条件任一命中都会推送告警到键盘。")
                }
                if !model.haAlertTitle.isEmpty {
                    Label("当前告警：\(model.haAlertTitle)（\(model.haAlertMessage)）",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// Bambu Lab 打印机卡片详情页：界面显示调整（布局样式 + 各区块开关）。
    /// 卡片渲染由键盘右侧实时预览展示，本页不再重复预览；实体映射在「设备管理」中配置。
    private func bambuLabForm(for panel: Panel) -> some View {
        Group {
            if let device = model.bambuDevice(for: panel) {
                Section("卡片 · \(device.name)") {
                    Picker(selection: model.bambuLayoutBinding(for: device.id)) {
                        ForEach(BambuCardLayout.selectableCases) { layout in
                            Text(layout.title).tag(layout)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("布局样式")
                            HelpIcon(text: "「大字」把工作状态作为浅色背景大字，并在前景显示进度数字、百分号与加粗进度条。")
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker(selection: model.bambuImageSourceBinding(for: device.id)) {
                        ForEach(BambuImageSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("画面内容")
                            HelpIcon(text: "摄像头和任务封面两个图片实体会同时保留，切换显示内容不会清除实体映射。")
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle(isOn: model.bambuShowBinding(for: device.id, \.bambuShowImage)) {
                        HStack(spacing: 4) {
                            Text("显示图片")
                            HelpIcon(text: "按上方选择显示摄像头静态帧或当前打印任务封面。摄像头只抓单帧，不会建立实时视频流；状态先推送，图片获取完成后再更新画面。")
                        }
                    }
                    if model.bambuImageSourceBinding(for: device.id).wrappedValue == .camera {
                        Toggle(isOn: model.bambuAutoCameraZoomBinding(for: device.id)) {
                            HStack(spacing: 4) {
                                Text("自动放大小模型")
                                HelpIcon(text: "开启时会先处理当前缓存画面并立即推送；后续每次准备推送到键盘前再抓取一张最新静态帧，在本机识别打印床中心的模型并自动裁切。取景范围会随打印进度逐步扩大；识别不可靠时自动恢复完整画面。")
                            }
                        }
                    }
                    Picker(selection: model.bambuThemeAccentBinding(for: device.id)) {
                        ForEach(BambuThemeAccent.allCases) { accent in
                            Text(accent.title).tag(accent)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("主题色")
                            HelpIcon(text: "「跟随全局」使用外观设置里的强调色；「Bambu Lab 强调色」固定使用品牌绿，用于徽标、进度条与状态高亮。")
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker(selection: model.bambuTimeDisplayModeBinding(for: device.id)) {
                        ForEach(BambuTimeDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("时间显示")
                            HelpIcon(text: "默认显示剩余时间；选择结束时间后读取设备管理中绑定的预计结束时间实体。两个实体映射会同时保留。")
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Toggle("显示工作状态", isOn: model.bambuShowBinding(for: device.id, \.bambuShowStatus))
                    Toggle("显示打印进度", isOn: model.bambuShowBinding(for: device.id, \.bambuShowProgress))
                    Toggle("显示当前任务", isOn: model.bambuShowBinding(for: device.id, \.bambuShowTask))
                    Toggle("显示喷嘴 / 热床温度", isOn: model.bambuShowBinding(for: device.id, \.bambuShowTemperature))
                    Toggle("显示时间信息", isOn: model.bambuShowBinding(for: device.id, \.bambuShowRemaining))
                    Toggle("显示错误码", isOn: model.bambuShowBinding(for: device.id, \.bambuShowError))
                } header: {
                    HStack(spacing: 4) {
                        Text("显示区块")
                        HelpIcon(text: "关闭的区块即使已映射实体也不显示；未映射实体的区块会自动隐藏。")
                    }
                }
                Section {
                    HStack(spacing: 4) {
                        Button("实体映射与自动匹配 → 设备管理") {
                            selected = .devices
                        }
                        HelpIcon(text: "打印机实体映射、自动匹配与报错告警在「设备管理 → Bambu Lab 打印机」中按设备配置；卡片渲染效果见右侧实时预览。")
                    }
                }
            } else {
                Section {
                    Text("该卡片位尚未绑定打印机设备")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("前往设备管理") {
                        selected = .devices
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func formlabsForm(for panel: Panel) -> some View {
        if let device = model.formlabsDevice(for: panel) {
            let snapshot = model.formlabsSnapshots[device.id] ?? .empty
            Section("当前打印机") {
                LabeledContent("设备", value: device.name)
                LabeledContent("云端设备", value: snapshot.device?.productName ?? "等待刷新")
                LabeledContent("状态", value: ScreenRenderer.formlabsStatusText(
                    snapshot.print?.status.isEmpty == false
                        ? snapshot.print!.status : (snapshot.device?.status ?? "unknown")))
                if let progress = snapshot.print?.progress {
                    LabeledContent("任务进度", value: "\(Int((progress * 100).rounded()))%")
                }
                if let sampledAt = snapshot.sampledAt {
                    LabeledContent("数据更新", value: sampledAt.formatted(date: .omitted, time: .standard))
                }
            }
            Section {
                Toggle("显示任务缩略图", isOn: model.formlabsBoolBinding(for: device.id, \.showThumbnail))
                Toggle("显示当前层数", isOn: model.formlabsBoolBinding(for: device.id, \.showLayers))
                Toggle("显示耗材种类", isOn: model.formlabsBoolBinding(for: device.id, \.showMaterial))
            } header: {
                HStack(spacing: 4) {
                    Text("显示内容")
                    HelpIcon(text: "卡片优先使用层数计算准确进度；层数不可用时，自动改用已用时长与预计总时长。")
                }
            }
            Section {
                HStack {
                    Button("立即刷新并推送") {
                        Task { await model.refreshFormlabs(deviceID: device.id, force: true, pushIfVisible: true) }
                    }
                    Button("连接设置 → 设备管理") { selected = .devices }
                    HelpIcon(text: "云端短暂断开时会保留上一次有效数据，并在卡片底部标出连接异常。")
                }
            }
        } else {
            Section {
                Text("该卡片位尚未绑定 Formlabs 打印机")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("前往设备管理") { selected = .devices }
            }
        }
    }

    /// Bambu Lab 打印机在「设备管理」页内的内联配置：自动匹配 + 实体映射 + 报错告警
    @ViewBuilder
    private func bambuDeviceConfigInline(_ deviceID: UUID) -> some View {
        // 复用全量 HA 快照更新时生成的目录；不在每台打印机的 View 重算中反复筛选/排序。
        let catalog = model.bambuEntityCatalog
        let printerEntities = catalog.printerEntities
        let currentBambu = model.bambuSettings(for: deviceID)
        let currentCameraID = currentBambu?.imageEntityID ?? ""
        let currentTaskCoverID = currentBambu?.taskImageEntityID ?? ""
        // 老版本可能曾把封面回填到“摄像头”字段。分类优化后仍把当前绑定项保留在
        // 对应选择器里，确保用户能看见、换绑或解除，不会出现有值却显示“未绑定”。
        let cameraEntities = catalog.cameraEntities + catalog.pictureEntities.filter { entity in
            entity.entityId == currentCameraID
                && !catalog.cameraEntities.contains(where: { $0.entityId == entity.entityId })
        }
        let taskCoverEntities = catalog.taskCoverEntities + catalog.pictureEntities.filter { entity in
            entity.entityId == currentTaskCoverID
                && !catalog.taskCoverEntities.contains(where: { $0.entityId == entity.entityId })
        }
        let useDefaultFilter = model.bambuDefaultEntityFilterBinding(for: deviceID).wrappedValue
        let defaultStatusEntities = catalog.defaultStatusEntities
        let allStatusEntities = catalog.allStatusEntities
        // 默认规则没有识别结果时自动展示全部 sensor，不能让“推荐筛选”变成空白墙。
        let statusEntities = useDefaultFilter && !defaultStatusEntities.isEmpty
            ? defaultStatusEntities : allStatusEntities
        let configuredStatusID = model.bambuSettings(for: deviceID)?.statusEntityID ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            // 自动匹配必须由打印状态实体确定打印机身份，再推导同一前缀下的其余字段。
            EntityDomainPicker(title: "打印状态实体（自动匹配）",
                               selection: bambuMatchDraftBinding(deviceID),
                               entities: statusEntities,
                               emptyLabel: "选择打印状态实体",
                               clearLabel: "清除",
                               allowClear: true,
                               largePopover: true,
                               defaultFilter: model.bambuDefaultEntityFilterBinding(for: deviceID),
                               unfilteredEntities: allStatusEntities,
                               filterEnabledDescription: "只显示软件判断为打印状态的实体。",
                               filterDisabledDescription: "显示全部 sensor 实体，适合设备名称或 entity_id 已被修改的情况。")
                .onChange(of: bambuMatchDraftBinding(deviceID).wrappedValue) { _, newValue in
                    if !newValue.isEmpty,
                       let entity = allStatusEntities.first(where: { $0.entityId == newValue }) {
                        let currentUseDefaultFilter = model
                            .bambuDefaultEntityFilterBinding(for: deviceID).wrappedValue
                        model.applyBambuAutoDetect(from: entity, deviceID: deviceID,
                                                   entities: printerEntities,
                                                   useDefaultFilter: currentUseDefaultFilter)
                        self.bambuMatchDrafts["\(deviceID.uuidString)"] = ""
                    }
                }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HelpIcon(text: "自动匹配，需要用户将实体选中到备选打印机的“打印状态实体”才可完成匹配。软件会根据该状态实体确定打印机前缀，再推导进度、任务、温度、剩余时间、结束时间、错误、摄像头与任务封面实体；结果可手动修改，点击每行右侧 × 可解除单项关联并停止显示。")
                Text("实体映射")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Button("按打印状态实体重新匹配") {
                    model.applyBambuAutoDetect(deviceID: deviceID,
                                               entities: printerEntities,
                                               useDefaultFilter: useDefaultFilter)
                }
                .controlSize(.small)
                .disabled(configuredStatusID.isEmpty
                          || !statusEntities.contains { $0.entityId == configuredStatusID })
                .help("需要先选择或手动设置有效的打印状态实体")
            }
            bambuFieldRow("工作状态", keyPath: \.bambuStatusEntityID, deviceID: deviceID, entities: printerEntities)
            bambuFieldRow("打印进度", keyPath: \.bambuProgressEntityID, deviceID: deviceID, entities: printerEntities)
            bambuFieldRow("当前任务", keyPath: \.bambuTaskEntityID, deviceID: deviceID, entities: printerEntities)
            bambuFieldRow("喷嘴温度", keyPath: \.bambuNozzleTempEntityID, deviceID: deviceID, entities: printerEntities)
            bambuFieldRow("热床温度", keyPath: \.bambuBedTempEntityID, deviceID: deviceID, entities: printerEntities)
            bambuFieldRow("剩余时间", keyPath: \.bambuRemainingEntityID, deviceID: deviceID, entities: printerEntities)
            bambuFieldRow("预计结束时间", keyPath: \.bambuEndTimeEntityID, deviceID: deviceID, entities: printerEntities)
            bambuFieldRow("错误码", keyPath: \.bambuErrorEntityID, deviceID: deviceID, entities: printerEntities)
            bambuFieldRow("打印任务封面", keyPath: \.bambuTaskImageEntityID,
                          deviceID: deviceID, entities: taskCoverEntities)
            bambuFieldRow("摄像头画面", keyPath: \.bambuImageEntityID,
                          deviceID: deviceID, entities: cameraEntities)
            HStack(spacing: 8) {
                Text("报错时推送键盘告警")
                    .onTapGesture {
                        alertTitleTapCount += 1
                        if alertTitleTapCount >= 5 {
                            alertTitleTapCount = 0
                            showPrinterAlertPreview = true
                        }
                    }
                    .help("连续点击 5 次可查看所有打印机报错界面预览（彩蛋）")
                Spacer()
                Toggle("", isOn: model.bambuAlertBinding(for: deviceID))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    /// Bambu Lab 字段映射行（Popover 实体选择器；按打印机设备；未指定 = 隐藏该字段）
    private func bambuFieldRow(_ title: String, keyPath: WritableKeyPath<DeviceSettings, String?>,
                               deviceID: UUID, entities: [HAEntity]) -> some View {
        let binding = model.bambuFieldBinding(for: deviceID, keyPath)
        return HStack(spacing: 8) {
            EntityDomainPicker(title: title,
                               selection: binding,
                               entities: entities,
                               emptyLabel: "未绑定（不显示）",
                               clearLabel: "解除关联（隐藏此项）",
                               allowClear: true)
            // 已绑定时在行尾直接提供解除入口，不必先展开实体弹窗再寻找“清除”。
            // 清空 entity_id 即为禁用该项显示；之后仍可随时重新选择实体。
            if !binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    binding.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("解除“\(title)”实体关联并停止显示该项")
            }
        }
    }

    /// Bambu 自动匹配输入草稿绑定（按打印机设备隔离）
    private func bambuMatchDraftBinding(_ deviceID: UUID) -> Binding<String> {
        let key = "\(deviceID.uuidString)"
        return Binding(get: { self.bambuMatchDrafts[key] ?? "" },
                       set: { self.bambuMatchDrafts[key] = $0 })
    }

    /// 已选 HA 实体行：图标 + 名称（支持自定义别名）+ entity_id + 状态值 + 重命名/移除（拖拽排序）。
    /// 从全量实体快照查找（新添加实体在下次轮询前也能显示名称与状态）
    private func haEntityRow(_ ref: HAEntityRef) -> some View {
        let entity = model.haSnapshot.entities.first { $0.entityId == ref.id }
        // 已绑定但当前服务器查无此实体 = 失效（基线关闭该提示）
        let isStale = AppModel.haStaleHintsEnabled && entity == nil && !model.haSnapshot.entities.isEmpty
        let icon = entity.map { SFIconMapper.symbol(for: $0) } ?? "questionmark.circle"
        let alias = model.settings.haEntityAliases[ref.id]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Image(systemName: isStale ? "exclamationmark.triangle" : icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isStale ? Color.orange : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(alias ?? (entity?.displayName ?? ref.id))
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(isStale ? Color.secondary
                                         : (alias != nil ? Color.accentColor : Color.primary))
                    Text(isStale ? "失效 · 当前服务器无此实体（\(ref.id)）" : ref.id)
                        .font(.system(size: 9))
                        .foregroundStyle(isStale ? Color.orange : Color.secondary.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer()
                if let entity {
                    Text(entity.displayValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if isStale, let last = model.haSnapshot.lastKnownValues[ref.id] {
                    Text("原值 \(last)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                if isStale {
                    EntityDomainPicker(title: "重选",
                                       selection: Binding(get: { "" },
                                                          set: { model.replaceHAEntity(oldID: ref.id, newID: $0) }),
                                       entities: model.haSnapshot.entities,
                                       emptyLabel: "换绑实体",
                                       clearLabel: "不使用")
                        .frame(width: 150)
                        .fixedSize()
                        .help("该实体在当前服务器上不存在，换一个绑定")
                }
                Button {
                    editingAliasEntityID = ref.id
                    aliasDraft = alias ?? ""
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("自定义显示名称")
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { model.removeHAEntity(ref.id) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("移除该实体")
            }
            .padding(.vertical, 8)
            .onDrag {
                draggedHAEntity = ref
                dragHAEntities = model.haEntityList.map(HAEntityRef.init)
                return NSItemProvider(object: ref.id as NSString)
            }
            .help("拖拽排序")

            if editingAliasEntityID == ref.id {
                HStack(spacing: 6) {
                    TextField("自定义显示名称（留空恢复默认）", text: $aliasDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            model.setHAEntityAlias(ref.id, alias: aliasDraft)
                            editingAliasEntityID = nil
                        }
                    Button("保存") {
                        model.setHAEntityAlias(ref.id, alias: aliasDraft)
                        editingAliasEntityID = nil
                    }
                    .controlSize(.small)
                    Button("取消") { editingAliasEntityID = nil }
                        .controlSize(.small)
                }
                .padding(.leading, 44)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
        }
    }

    private var generalForm: some View {
        Group {
        Section {
            Picker(selection: model.menuBarTargetBinding()) {
                Text("跟随当前活动键盘").tag("follow")
                ForEach(model.enabledDevices(for: .keyboard)) { device in
                    Text(device.name).tag("kb:\(device.id.uuidString)")
                }
            } label: {
                HStack(spacing: 4) {
                    Text("菜单栏切换目标键盘")
                    HelpIcon(text: "菜单栏的「切换显示内容 / 立即推送」操作哪台键盘的判定依据：选「跟随当前活动键盘」时，作用于软件当前活动的键盘设备（侧栏中正在操作的那台）；选某台具体键盘时，执行前会先把活动键盘切到这台设备再操作，无论当前活动的是哪台。目标设备被禁用时回退到当前活动键盘。")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("顶部安全区")
                    Spacer()
                    Text("\(model.settings.safeAreaHeight) px")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: model.safeAreaBinding, in: 44...80, step: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("JPEG 质量")
                    HelpIcon(text: "100% 为 4:4:4 无彩色抽样，画质接近无损；越低文件越小、压缩痕迹越明显。键盘仅支持 JPEG 格式。")
                    Spacer()
                    Text("\(model.settings.jpegQuality)%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: model.qualityBinding, in: 50...100, step: 1)
            }
        } header: {
            HStack(spacing: 4) {
                Text("灵犀68 屏幕控制")
                HelpIcon(text: "以下选项仅适用于灵犀68 键盘，不影响口袋先知与摘录。键盘 IP 地址等连接信息请在「设备管理」中按设备设置。")
            }
        }
        Section {
            shortcutBindingRow("上一页", action: .keyboardPageUp)
            shortcutBindingRow("下一页", action: .keyboardPageDown)
            HStack {
                if recordingShortcutAction == .keyboardPageUp || recordingShortcutAction == .keyboardPageDown {
                    Text("正在录制…按下新的快捷键（Esc 取消）")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button("恢复默认") { showRestorePageShortcutsConfirm = true }
                    .controlSize(.small)
            }
            Divider()
            Toggle(isOn: model.lingxi68KnobPagingBinding) {
                HStack(spacing: 4) {
                    Text("使用 Fn + 旋钮翻页")
                    HelpIcon(text: "默认关闭。开启后，灵犀68 的 Fn + 顺时针切换下一页、Fn + 逆时针切换上一页；软件会独占该键盘的媒体控制接口，因此系统将不再响应这把键盘的音量增加、音量减少和静音操作。其他键盘与 Mac 自身音量键不受影响。")
                }
            }
            if model.settings.lingxi68KnobPagingEnabled {
                HStack {
                    Label(model.lingxi68KnobPagingStatus,
                          systemImage: model.lingxi68KnobPagingStatus.hasPrefix("已接管") ? "checkmark.circle.fill" : "dial.high")
                        .font(.caption)
                        .foregroundStyle(model.lingxi68KnobPagingStatus.hasPrefix("已接管") ? .green : .secondary)
                    Spacer()
                    if !model.listenEventGranted {
                        Button("打开输入监控设置") { model.openInputMonitoringSettings() }
                            .controlSize(.small)
                    }
                    Button("重新连接") { model.reconnectLingxi68KnobPaging() }
                        .controlSize(.small)
                }
            }
        } header: {
            HStack(spacing: 4) {
                Text("手动上下翻页快捷键")
                HelpIcon(text: "可在系统任意界面手动切换灵犀68 的上一张或下一张卡片；作用目标与上方菜单栏目标键盘一致。")
            }
        }
        Section {
            Picker(selection: model.clockFormatPresetBinding) {
                Text("24 小时 · HH:mm").tag(0)
                Text("24 小时 · H:mm").tag(1)
                Text("24 小时 · HH:mm:ss").tag(2)
                Text("12 小时 · hh:mm").tag(3)
                Text("自定义…").tag(4)
            } label: {
                HStack(spacing: 4) {
                    Text("时间格式")
                    HelpIcon(text: "时间格式含秒时，键盘画面会按秒刷新推送。")
                }
            }
            if model.clockFormatPresetBinding.wrappedValue == 4 {
                HStack(spacing: 4) {
                    TextField("自定义时间格式", text: model.clockTimeFormatBinding)
                        .textFieldStyle(.roundedBorder)
                    HelpIcon(text: "可用符号：HH 两位小时 · H 小时 · hh 12 小时 · mm 分 · ss 秒 · a 上午/下午")
                        .fixedSize()
                }
            }
            Picker("日期格式", selection: model.dateFormatPresetBinding) {
                Text("yyyy年M月d日 EEE").tag(0)
                Text("M月d日").tag(1)
                Text("yyyy-MM-dd").tag(2)
                Text("M/d").tag(3)
                Text("自定义…").tag(4)
            }
            if model.dateFormatPresetBinding.wrappedValue == 4 {
                HStack(spacing: 4) {
                    TextField("自定义日期格式", text: model.dateFormatBinding)
                        .textFieldStyle(.roundedBorder)
                    HelpIcon(text: "可用符号：yyyy 年 · MM 月 · M 月 · dd 日 · d 日 · EEE 星期")
                        .fixedSize()
                }
            }
            Text("当前显示：\(model.previewTimeString) · \(model.previewDateString)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        } header: {
            HStack(spacing: 4) {
                Text("时间与日期")
                HelpIcon(text: "软件内所有时间与日期显示统一使用这里的一份格式：时钟卡片、自定义图片上的时钟、画板时钟/日期模块、正在播放页脚、番茄钟与各类卡片页脚。较长格式会按所在区域自动缩小字号，避免超出画面。")
            }
        }
        Section {
            Toggle("登录时自动启动", isOn: model.startWithSystemBinding)
            HStack {
                LabeledContent("辅助功能", value: model.accessibilityGranted ? "已授权" : "未授权")
                Button("打开设置") { model.openAccessibilitySettings() }
                    .controlSize(.small)
            }
            HStack {
                LabeledContent("输入监控", value: model.listenEventGranted ? "已授权" : "未授权")
                Button("打开设置") { model.openInputMonitoringSettings() }
                    .controlSize(.small)
            }
        } header: {
            HStack(spacing: 4) {
                Text("系统权限")
                HelpIcon(text: "全局快捷键：⌃⌥Space 开始/暂停 · ⌃⌥→ 跳过 · ⌃⌥⌫ 重置。快捷键在系统范围内生效，无需额外权限。")
            }
        }
        Section {
            LabeledContent("应用", value: "多屏灵犀（Lingxi MultiScreen）")
            LabeledContent("版本", value: ReleaseNotes.currentVersion)
            LabeledContent("系统要求", value: "macOS 26+ · Apple 芯片")
            LabeledContent("驱动设备", value: "灵犀68 键盘 / 口袋先知 / 摘录")
            if let release = model.updateAvailable {
                Label("发现新版本 \(release.tag)", systemImage: "arrow.down.circle")
                    .foregroundStyle(Color.accentColor)
                if let url = release.htmlURL {
                    Button("前往下载") { NSWorkspace.shared.open(url) }
                }
            } else if let text = model.updateStatusText {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("检查更新") {
                    Task { await model.checkForUpdate(force: true) }
                }
                if model.updateChecking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } header: {
            HStack(spacing: 4) {
                Text("关于")
                HelpIcon(text: "一套软件驱动三块屏幕；版本号随每次更新递增，可在本页查看当前版本、历史更新记录，并检查 GitHub 仓库是否有新版本。")
            }
        }
        // 版本更新日志：整体折叠为单行入口（chevron 展开），设置页主体不被版本列表撑长；
        // 展开后每个版本仍是单行折叠，点版本行再展开详细日志
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showVersionLog.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showVersionLog ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("版本更新日志")
                        .font(.headline)
                    HelpIcon(text: "点击版本行可展开或收起对应版本的更新日志；最新版本号以「关于」中的版本为准。")
                    Spacer()
                    if showVersionLog {
                        Text("收起")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            if showVersionLog {
                ForEach(ReleaseNotes.all) { note in
                    let isExpanded = expandedReleaseNotes.contains(note.id)
                    VStack(alignment: .leading, spacing: 4) {
                        // 版本行：点击展开/收起该版本详细日志（0.2s 平滑过渡）
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if isExpanded {
                                    expandedReleaseNotes.remove(note.id)
                                } else {
                                    expandedReleaseNotes.insert(note.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text("v\(note.id)")
                                    .font(.headline)
                                Text(note.date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if note.id == ReleaseNotes.all.first?.id {
                                    Text("当前版本")
                                        .font(.caption2)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        if isExpanded {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(note.notes, id: \.self) { item in
                                    Text("· \(item)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        Section {
            HStack(spacing: 4) {
                Button("恢复初始设定…", role: .destructive) {
                    showResetConfirm1 = true
                }
                HelpIcon(text: "清除全部设置、已添加的设备、自定义内容与自定义图片缓存，软件回到首次启动状态。需要两次确认，请谨慎操作。")
            }
        } header: {
            Text("高级")
        }
        }
        .confirmationDialog("恢复手动翻页快捷键？", isPresented: $showRestorePageShortcutsConfirm,
                            titleVisibility: .visible) {
            Button("恢复默认组合", role: .destructive) { model.resetKeyboardPageShortcuts() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("上一页、下一页将恢复为默认组合：⌃⌥↑ · ⌃⌥↓。")
        }
        .onDisappear { cancelShortcutRecording() }
    }

    @ViewBuilder
    private var qwenWorkForm: some View {
        Section {
            Picker("刷新间隔", selection: model.refreshIntervalBinding) {
                ForEach([60, 300, 600, 1800], id: \.self) { seconds in
                    Text(Self.intervalTitle(seconds)).tag(seconds)
                }
            }
            Button("立即刷新") {
                Task { await model.refresh() }
            }
            LabeledContent("套餐版本", value: model.qwenQuota.plan ?? "未知")
            LabeledContent("剩余额度", value: model.qwenQuotaText)
            LabeledContent("剩余百分比", value: model.qwenQuotaPercentText)
            LabeledContent("百分比基线", value: model.quotaBaselineText)
            HStack(spacing: 4) {
                Button("将当前额度设为 100% 基线") {
                    model.captureQuotaBaseline()
                }
                HelpIcon(text: "额度百分比按「当前剩余 ÷ 基线」计算。基线每日自动采样：跨天后以当天额度重新采样；同一日内额度回升超过基线时自动把基线拉高到当前额度。也可随时手动重设基线。")
            }
            LabeledContent("最后采样", value: model.qwenQuota.available
                           ? Self.formatSample(model.qwenQuota.sampledAt) : "尚未读取")
            HStack(spacing: 4) {
                Text("数据来源")
                HelpIcon(text: "额度数据来自本机千问办公客户端的本地服务，请保持千问办公运行。")
                Spacer()
                Text("千问办公")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var codexForm: some View {
        Section {
            Picker("额度来源", selection: model.codexUsageSourceBinding) {
                ForEach(CodexUsageSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            if model.settings.codexUsageSource == .codexCLI {
                TextField("Codex CLI 路径（可选）", text: model.codexCliPathBinding)
                    .textFieldStyle(.roundedBorder)
            } else {
                HStack(spacing: 4) {
                    Text("当前来源")
                    HelpIcon(text: "只读跟随 CC Switch 当前选中的 Codex 供应商。请先在 CC Switch 的供应商卡片中启用用量查询；多屏灵犀不会复制或保存其中的 API 密钥。")
                    Spacer()
                    Text(model.usage.sourceName ?? "等待读取 CC Switch")
                        .foregroundStyle(.secondary)
                }
            }
            Picker("刷新间隔", selection: model.refreshIntervalBinding) {
                ForEach([60, 300, 600, 1800], id: \.self) { seconds in
                    Text(Self.intervalTitle(seconds)).tag(seconds)
                }
            }
            HStack {
                Button("立即刷新") {
                    Task { await model.refresh() }
                }
                Spacer()
                Text(model.usage.isAvailable
                     ? "剩余 \(model.usage.remainingPercent)%"
                        + (model.usage.availableResetCount > 0
                           ? " · 可用重置 \(model.usage.availableResetCount) 次" : "")
                     : "尚未读取 Codex 用量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var pomodoroForm: some View {
        Group {
            Section {
                TextField("任务名称", text: model.taskNameBinding)
                    .textFieldStyle(.roundedBorder)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("任务名字号")
                        Spacer()
                        Text("\(model.settings.pomodoroTaskFontSize) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.pomodoroTaskFontSizeBinding, in: 7...16, step: 1)
                }
                editableMinutesRow("专注时长", binding: model.focusMinutesBinding)
                editableMinutesRow("短休息", binding: model.shortBreakMinutesBinding)
                editableMinutesRow("长休息", binding: model.longBreakMinutesBinding)
                Stepper("键盘推送间隔 \(model.settings.pomodoroUploadSeconds) 秒",
                        value: model.pomodoroUploadBinding, in: 2...60)
                HStack {
                    Button(model.pomodoroAction) {
                        Task { await model.togglePomodoro() }
                    }
                    Button("跳过") {
                        Task { await model.skipPomodoro() }
                    }
                    Button("重置") {
                        Task { await model.resetPomodoro() }
                    }
                    Spacer()
                    Text(model.pomodoroStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("完成夸夸") {
                Toggle(isOn: model.pomodoroPraiseEnabledBinding) {
                    HStack(spacing: 4) {
                        Text("每完成一个时间段进行夸夸")
                        HelpIcon(text: "任何界面下，每完成一个时间阶段都会显示夸夸内容约 12 秒，然后恢复正常卡片。")
                    }
                }
                if model.settings.pomodoroPraiseEnabled {
                    Picker("内容来源", selection: model.pomodoroPraiseSourceBinding) {
                        ForEach(PraiseSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                }
            }
            Section {
                shortcutBindingRow("开始 / 暂停", action: .togglePomodoro)
                shortcutBindingRow("跳过", action: .skipPomodoro)
                shortcutBindingRow("重置", action: .resetPomodoro)
                HStack {
                    if recordingShortcutAction != nil {
                        Text("正在录制…按下新的快捷键（Esc 取消）")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    Button("恢复初始快捷键") { showRestoreShortcutsConfirm = true }
                        .controlSize(.small)
                }
            } header: {
                HStack(spacing: 4) {
                    Text("全局快捷键")
                    HelpIcon(text: "快捷键在系统范围内生效，无需额外权限。")
                }
            }
        }
        .confirmationDialog("恢复初始快捷键？", isPresented: $showRestoreShortcutsConfirm,
                            titleVisibility: .visible) {
            Button("恢复默认组合", role: .destructive) { model.resetPomodoroShortcuts() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("开始/暂停、跳过、重置三个快捷键将恢复为默认组合：⌃⌥Space · ⌃⌥→ · ⌃⌥⌫。")
        }
        .onDisappear { cancelShortcutRecording() }
    }

    /// 全局快捷键设置行：当前组合 + 录制按钮
    private func shortcutBindingRow(_ title: String, action: GlobalHotkeyManager.Action) -> some View {
        HStack {
            Text(title)
            Spacer()
            if recordingShortcutAction == action {
                Text("按下新快捷键…（Esc 取消）")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            } else {
                Text(GlobalHotkeyManager.shortcutHint(for: action))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button(recordingShortcutAction == action ? "取消" : "录制") {
                if recordingShortcutAction == action {
                    cancelShortcutRecording()
                } else {
                    startShortcutRecording(action)
                }
            }
            .controlSize(.small)
        }
    }

    /// 开始录制：挂本地按键监听，捕获下一个有效组合（Esc 取消；无修饰键的非功能键忽略；冲突拒绝）
    private func startShortcutRecording(_ action: GlobalHotkeyManager.Action) {
        cancelShortcutRecording()
        recordingShortcutAction = action
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                self.cancelShortcutRecording()
                return nil
            }
            if (event.charactersIgnoringModifiers ?? "").isEmpty { return nil }
            var mods: UInt32 = 0
            let flags = event.modifierFlags
            if flags.contains(.control) { mods |= GlobalShortcut.controlKey }
            if flags.contains(.option) { mods |= GlobalShortcut.optionKey }
            if flags.contains(.shift) { mods |= GlobalShortcut.shiftKey }
            if flags.contains(.command) { mods |= GlobalShortcut.cmdKey }
            let keyCode = UInt32(event.keyCode)
            // 无修饰键且非功能键：拒绝（避免占用普通输入，Carbon 也无法注册）
            if mods == 0 && !GlobalShortcut.isFunctionKey(keyCode) { return nil }
            let newShortcut = GlobalShortcut(keyCode: keyCode, modifiers: mods)
            let others: [GlobalHotkeyManager.Action] = [
                .togglePomodoro, .skipPomodoro, .resetPomodoro,
                .keyboardPageUp, .keyboardPageDown
            ]
            if let conflict = others.first(where: { $0 != action && self.model.shortcut(for: $0) == newShortcut }) {
                self.shortcutConflictText = "「\(self.shortcutActionTitle(conflict))」已绑定到 \(newShortcut.displayString)。请更换组合。"
                self.showShortcutConflict = true
                self.cancelShortcutRecording()
                return nil
            }
            self.model.setShortcut(newShortcut, for: action)
            self.cancelShortcutRecording()
            return nil
        }
    }

    private func cancelShortcutRecording() {
        if let monitor = recordingMonitor {
            NSEvent.removeMonitor(monitor)
        }
        recordingMonitor = nil
        recordingShortcutAction = nil
    }

    private func shortcutActionTitle(_ action: GlobalHotkeyManager.Action) -> String {
        switch action {
        case .togglePomodoro: return "开始/暂停"
        case .skipPomodoro: return "跳过"
        case .resetPomodoro: return "重置"
        case .keyboardPageUp: return "上一页"
        case .keyboardPageDown: return "下一页"
        }
    }

    @ViewBuilder
    private var systemForm: some View {
        Section {
            Stepper("推送周期 \(model.settings.dynamicUploadSeconds) 秒",
                    value: model.dynamicUploadBinding, in: 2...60)
            Toggle("显示 CPU", isOn: model.showCpuBinding)
            Toggle("显示内存", isOn: model.showMemoryBinding)
            Toggle("显示磁盘", isOn: model.showDiskBinding)
            Toggle("显示网络", isOn: model.showNetworkBinding)
            if model.settings.showNetwork {
                Picker("网络显示方式", selection: model.networkChartBinding) {
                    Text("数字速率").tag(false)
                    Text("折线图").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
            Toggle("显示运行时间", isOn: model.showUptimeBinding)
            Text(model.systemStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var customImageForm: some View {
        Section {
            HStack {
                Button("选择图片…") {
                    Task { await model.pickCustomImage() }
                }
                HelpIcon(text: "图片会自动居中裁切为 142×428，顶部保留 44–80 px 安全区。")
                Spacer()
                Text(model.customImageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker(selection: model.customImageClockBinding) {
                ForEach(CustomImageClockOverlay.allCases) { overlay in
                    Text(overlay.title).tag(overlay)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("时钟叠加")
                    HelpIcon(text: "叠加时钟跟随系统时间，每分钟自动刷新推送；不叠加则保持静态图片。")
                }
            }
            if model.settings.customImageClock != .none {
                Picker(selection: model.wallpaperColorStyleBinding) {
                    ForEach(WallpaperColorStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("动态取色")
                        HelpIcon(text: model.settings.wallpaperColorStyle.description)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("显示日期", isOn: model.clockDateVisibleBinding)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("整体大小")
                        HelpIcon(text: "Pixel 叠排大时钟把四位时间与日期视为一个图层组统一缩放，数字间距不会随大小变化。叠排样式固定使用纵向压缩、加粗描边的 Arial Black 数字；配色从当前图片实时取色，并按 Material You 规则生成同色系高反差色调。时间格式在「设置 → 时间与日期」统一调整。")
                        Spacer()
                        Text("\(StackedClockSizing.percent(for: model.settings.clockFontSize))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.clockFontSizeBinding,
                           in: Double(StackedClockSizing.minimum)...Double(StackedClockSizing.maximum),
                           step: 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("X 偏移")
                        Spacer()
                        Text("\(model.settings.clockOffsetX) px")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.clockOffsetXBinding, in: -60...60, step: 1)
                        // 双击滑块恢复默认偏移 0（与拖动互不干扰）
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                model.settings.clockOffsetX = 0
                            }
                        )
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Y 偏移")
                        Spacer()
                        Text("\(model.settings.clockOffsetY) px")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.clockOffsetYBinding,
                           in: Double(StackedClockSizing.minimumYOffset)...Double(StackedClockSizing.maximumYOffset),
                           step: 1)
                        // 双击滑块恢复默认偏移 0（与拖动互不干扰）
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                model.settings.clockOffsetY = 0
                            }
                        )
                }
                HStack(spacing: 4) {
                    Button("恢复默认样式") {
                        model.resetClockOverlay()
                    }
                    HelpIcon(text: "恢复为自然取色、显示日期、Arial Black、100% 整体大小、HH:mm、无偏移；叠加开关与布局保持不变。")
                }
            }
        }
        recentImagesSection
        rotationSection
    }

    /// 最近图片定时轮换：开关 + 切换模式 + 非线性间隔滑杆
    @ViewBuilder
    private var rotationSection: some View {
        Section("定时轮换") {
            Toggle("在最近图片间轮换", isOn: model.imageRotationEnabledBinding)
            if model.settings.imageRotationEnabled {
                Picker("切换模式", selection: model.imageRotationModeBinding) {
                    ForEach(ImageRotationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("轮换间隔")
                        HelpIcon(text: "范围 5 秒–5 分钟；滑杆非线性，时间越长档位越粗。")
                        Spacer()
                        Text(RotationInterval.label(forSeconds: model.settings.imageRotationSeconds))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.imageRotationSliderBinding, in: 0...1)
                }
                if model.settings.customImageHistory.count < 2 {
                    Text("至少需要 2 张最近图片才能轮换。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 最近使用的图片（最多 9 张，点击即重新应用）
    @ViewBuilder
    private var recentImagesSection: some View {
        if !model.settings.customImageHistory.isEmpty {
            Section("最近图片") {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                    spacing: 10
                ) {
                    ForEach(model.settings.customImageHistory) { entry in
                        RecentImageCell(entry: entry) {
                            Task { await model.applyImageHistory(entry) }
                        }
                    }
                }
                Button("清除历史记录…", role: .destructive) {
                    showClearHistoryConfirm = true
                }
                .buttonStyle(.bordered)
                .confirmationDialog(
                    "清除最近图片？",
                    isPresented: $showClearHistoryConfirm,
                    titleVisibility: .visible
                ) {
                    Button("清除历史记录", role: .destructive) {
                        model.clearImageHistory()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将删除最近 \(model.settings.customImageHistory.count) 条图片记录及其缓存文件，当前正在显示的图片不受影响。")
                }
            }
        }
    }

    private static func intervalTitle(_ seconds: Int) -> String {
        switch seconds {
        case 60: return "1 分钟"
        case 300: return "5 分钟"
        case 600: return "10 分钟"
        default: return "30 分钟"
        }
    }

    private static func rotationIntervalText(_ minutes: Int) -> String {
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    /// 时长编辑行：中间输入框可直接输入数值，两侧保留 +/- 步进
    private func editableMinutesRow(_ label: String, binding: Binding<Int>) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer()
            Button { binding.wrappedValue -= 1 } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.borderless)
            TextField("", value: binding, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 54)
            Button { binding.wrappedValue += 1 } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.borderless)
            Text("分钟")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func formatSample(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - 最近图片缩略格

/// 历史图片缩略格：异步加载缩略图，点击应用该图片
struct RecentImageCell: View {
    let entry: RecentImage
    let onApply: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: onApply) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(entry.name)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(entry.name)
        .task {
            thumbnail = NSImage(contentsOfFile: entry.path)
        }
    }
}

// MARK: - 侧边栏（纯按钮，避免 List 自动选中覆盖持久化模式；底部项经 Spacer 固定置底）

/// 感叹号提示图标：悬停自动弹出注释，点击可固定切换或打开对应文档。
struct HelpIcon: View {
    let text: String
    var linkURL: URL? = nil
    @State private var showPopover = false

    var body: some View {
        Button {
            if let linkURL {
                NSWorkspace.shared.open(linkURL)
            } else {
                showPopover.toggle()
            }
        } label: {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .onHover { hovering in
            showPopover = hovering
        }
        .popover(isPresented: $showPopover) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .padding(12)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

struct Sidebar: View {
    @Binding var selection: Panel
    @ObservedObject var model: AppModel

    /// 用户手动展开的设备分组（默认全部收起；只记录被展开的 ID）
    @State private var expandedDeviceIDs: Set<UUID> = []

    /// 某台键盘设备侧栏的功能项：卡片管理入口 + 该设备自己的可见卡片（隐藏的卡片不在侧栏显示）
    private func keyboardPanels(for deviceID: UUID) -> [Panel] {
        [.cardRotation] + model.keyboardCardList(for: deviceID)
    }

    /// 某台键盘设备是否没有任何卡片（空列表时显示去卡片管理的提示）
    private func keyboardHasNoCards(_ deviceID: UUID) -> Bool {
        model.keyboardCardList(for: deviceID).isEmpty
    }

    var body: some View {
        VStack(spacing: 2) {
            // 按设备实例分类：每台设备（设备管理中添加的）下面挂它的卡片功能，
            // 点开某台设备下的功能项即操作那台设备
            ScrollView {
                VStack(spacing: 2) {
                    if model.settings.devices.isEmpty {
                        // 首次使用/已删光全部设备：引导到设备管理添加
                        VStack(spacing: 10) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 26))
                                .foregroundStyle(.secondary)
                            Text("尚未添加设备")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Button("去设备管理添加") {
                                selection = .devices
                            }
                            .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .padding(.horizontal, 8)
                    } else {
                        // 所有已启用设备按类型顺序平铺；设备之间插入分隔线
                        ForEach(Array(sidebarDevices.enumerated()), id: \.element.device.id) { index, entry in
                            if index > 0 {
                                Divider()
                                    .padding(.vertical, 3)
                            }
                            deviceGroup(for: entry.type, device: entry.device)
                        }
                    }
                }
            }
            nowPlayingCard
            Divider()
                .padding(.vertical, 4)
            // 底部固定项：设备管理 / 外观 / 设置
            ForEach([Panel.devices] + Panel.bottomItems) { panel in
                sidebarRow(panel)
            }
        }
        .padding(.horizontal, 8)
        // 系统给侧栏与详情列各自留了不同的顶部间距，导致侧栏首行下方的分隔线
        // 比详情标题栏下方分隔线低约 20pt——用负上边距把设备列表整体上移对齐两条分隔线
        // （负 padding 只作用于滚动区内容，底部固定项仍贴底）
        .padding(.top, -6)
        .padding(.bottom, 8)
    }

    /// 所有已启用设备按类型顺序（键盘 → 先知 → 摘录）平铺，供设备间分隔线遍历
    private var sidebarDevices: [(type: DeviceType, device: ManagedDevice)] {
        // 侧栏不展示 HA 设备与 Bambu Lab 打印机独立分组：
        // HA 配置在设备管理维护（卡片/画板模块嵌入）；Bambu 打印机卡片归入键盘分组，
        // 实体映射与告警在「设备管理」中配置
        DeviceType.allCases.filter { $0 != .homeAssistant && $0 != .bambuLab && $0 != .formlabs }.flatMap { type in
            model.enabledDevices(for: type).map { (type, $0) }
        }
    }

    /// 单台设备的可展开分组（按设备类型挂对应功能项）
    private func deviceGroup(for type: DeviceType, device: ManagedDevice) -> some View {
        switch type {
        case .keyboard:
            return AnyView(deviceInstanceGroup(icon: "keyboard", title: device.name,
                                               isExpanded: deviceExpandedBinding(device.id),
                                               panels: keyboardPanels(for: device.id),
                                               switchType: .keyboard, deviceID: device.id,
                                               emptyHint: keyboardHasNoCards(device.id) ? "尚未添加卡片，去卡片管理添加" : nil))
        case .oracle:
            return AnyView(deviceInstanceGroup(icon: "sparkles", title: device.name,
                                               isExpanded: deviceExpandedBinding(device.id),
                                               panels: [.oracleBoardManagement, .buttonControl],
                                               switchType: .oracle, deviceID: device.id,
                                               oracleBoards: model.visibleOracleCanvasBoards(for: device.id)))
        case .excerpt:
            return AnyView(deviceInstanceGroup(icon: "quote.opening", title: device.name,
                                               isExpanded: deviceExpandedBinding(device.id),
                                               panels: [.excerptBoardManagement],
                                               switchType: .excerpt, deviceID: device.id,
                                               excerptBoards: model.visibleExcerptCanvasBoards(for: device.id)))
        case .homeAssistant:
            // HA 设备不在侧栏显示独立分组（配置在设备管理维护，以卡片/画板模块嵌入）
            return AnyView(EmptyView())
        case .bambuLab:
            // Bambu Lab 打印机不在侧栏独立分组：卡片归入键盘分组，配置在设备管理维护
            return AnyView(EmptyView())
        case .formlabs:
            return AnyView(EmptyView())
        case .aiMacScreen:
            return AnyView(deviceInstanceGroup(icon: "display", title: device.name,
                                               isExpanded: deviceExpandedBinding(device.id),
                                               panels: [.aiMacCardManagement, .aiMacClock,
                                                        .aiMacBoardManagement,
                                                        .aiMacControl],
                                               switchType: .aiMacScreen, deviceID: device.id,
                                               aiMacBoards: model.visibleAIMacCanvasBoards(for: device.id),
                                               aiMacCardModes: model.aiMacCardList(for: device.id)))
        }
    }

    /// 设备分组展开状态（默认全部收起；展开某台设备时自动收起其他所有设备 = 手风琴效果）
    private func deviceExpandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expandedDeviceIDs.contains(id) },
                set: { isExpanded in
                    if isExpanded {
                        // 手风琴：同一时刻只展开一台设备
                        expandedDeviceIDs = [id]
                    } else {
                        expandedDeviceIDs.remove(id)
                    }
                })
    }

    /// 单台设备的可展开分组：标题 = 设备名，下面挂该设备的卡片功能；
    /// 点击任意功能项先切到这台设备再打开对应页面。
    /// 展开的二级菜单整体向右缩进（图标与文字一起），与设备名层级拉开。
    private func deviceInstanceGroup(icon: String, title: String, isExpanded: Binding<Bool>,
                                     panels: [Panel], switchType: DeviceType?, deviceID: UUID?,
                                     emptyHint: String? = nil,
                                     oracleBoards: [OracleCanvasBoard] = [],
                                     excerptBoards: [ExcerptCanvasBoard] = [],
                                     aiMacBoards: [AIMacCanvasBoard] = [],
                                     aiMacCardModes: [DisplayMode] = []) -> some View {
        return DisclosureGroup(isExpanded: isExpanded) {
            ForEach(panels) { panel in
                if panel == .cardRotation, switchType == .keyboard, let deviceID {
                    cardRotationRow(deviceID)
                        .padding(.leading, Self.submenuIndent)
                } else if panel == .oracleBoardManagement,
                          switchType == .oracle, let deviceID {
                    oracleBoardManagementSidebarRow(deviceID)
                        .padding(.leading, Self.submenuIndent)
                } else if panel == .excerptBoardManagement,
                          switchType == .excerpt, let deviceID {
                    excerptBoardManagementSidebarRow(deviceID)
                        .padding(.leading, Self.submenuIndent)
                } else if panel == .aiMacBoardManagement,
                          switchType == .aiMacScreen, let deviceID {
                    aiMacBoardManagementSidebarRow(deviceID)
                        .padding(.leading, Self.submenuIndent)
                } else if panel == .aiMacCardManagement,
                          switchType == .aiMacScreen, let deviceID {
                    aiMacCardManagementSidebarRow(deviceID)
                        .padding(.leading, Self.submenuIndent)
                } else {
                    sidebarRow(panel, switchingTo: switchType, deviceID: deviceID)
                        .padding(.leading, Self.submenuIndent)
                }
                if panel == .oracleBoardManagement, switchType == .oracle, let deviceID {
                    ForEach(oracleBoards) { board in
                        oracleBoardSidebarRow(board, deviceID: deviceID)
                            .padding(.leading, Self.submenuIndent + 14)
                    }
                }
                if panel == .excerptBoardManagement, switchType == .excerpt, let deviceID {
                    ForEach(excerptBoards) { board in
                        excerptBoardSidebarRow(board, deviceID: deviceID)
                            .padding(.leading, Self.submenuIndent + 14)
                    }
                }
                if panel == .aiMacBoardManagement, switchType == .aiMacScreen, let deviceID {
                    ForEach(aiMacBoards) { board in
                        aiMacBoardSidebarRow(board, deviceID: deviceID)
                            .padding(.leading, Self.submenuIndent + 14)
                    }
                }
                if panel == .aiMacCardManagement, switchType == .aiMacScreen, let deviceID {
                    ForEach(aiMacCardModes) { mode in
                        aiMacCardSidebarRow(mode, deviceID: deviceID)
                            // 功能卡片与「卡片管理」同属设备下的第二级，排列层级和
                            // 灵犀键盘一致；不再额外缩进成难以辨认的第三级。
                            .padding(.leading, Self.submenuIndent)
                    }
                }
            }
            if (switchType == .oracle && oracleBoards.isEmpty)
                || (switchType == .excerpt && excerptBoards.isEmpty)
                || (switchType == .aiMacScreen && aiMacBoards.isEmpty) {
                Text(switchType == .oracle && deviceID.map({ !model.oracleCanvasBoards(for: $0).isEmpty }) == true
                     || switchType == .excerpt && deviceID.map({ !model.excerptCanvasBoards(for: $0).isEmpty }) == true
                     || switchType == .aiMacScreen && deviceID.map({ !model.aiMacCanvasBoards(for: $0).isEmpty }) == true
                     ? "所有画板已隐藏" : "尚未创建画板")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
                    .padding(.leading, Self.submenuIndent + 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let emptyHint {
                Button {
                    if let switchType, let deviceID {
                        model.switchDevice(type: switchType, to: deviceID)
                    }
                    selection = .cardRotation
                } label: {
                    Label(emptyHint, systemImage: "plus.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, Self.submenuIndent)
            }
        } label: {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 22, height: 22)
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
    }

    private func oracleBoardSidebarRow(_ board: OracleCanvasBoard, deviceID: UUID) -> some View {
        let isCurrent = model.activeDeviceID(for: .oracle) == deviceID
            && model.isCurrentOracleCanvasBoard(deviceID: deviceID, boardID: board.id)
        return Button {
            model.applyOracleCanvasBoard(deviceID: deviceID, boardID: board.id)
            selection = .oracleCanvas
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isCurrent ? "circle.inset.filled" : "circle")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 14)
                Text(board.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent && selection == .oracleCanvas
                          ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        .help("切换到这台口袋先知并应用「\(board.name)」")
    }

    /// 摘录设备下的画板行。选中依据“设备 ID + 画板 ID”，相同下标不会跨设备误高亮。
    private func excerptBoardSidebarRow(_ board: ExcerptCanvasBoard, deviceID: UUID) -> some View {
        let isCurrent = model.activeDeviceID(for: .excerpt) == deviceID
            && model.isCurrentExcerptCanvasBoard(deviceID: deviceID, boardID: board.id)
        return Button {
            model.applyExcerptCanvasBoard(deviceID: deviceID, boardID: board.id)
            selection = .excerptCanvas
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isCurrent ? "circle.inset.filled" : "circle")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 14)
                Text(board.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent && selection == .excerptCanvas
                          ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        .help("切换到这台摘录设备并应用「\(board.name)」")
    }

    private func aiMacBoardSidebarRow(_ board: AIMacCanvasBoard, deviceID: UUID) -> some View {
        let isCurrent = model.activeDeviceID(for: .aiMacScreen) == deviceID
            && model.isCurrentAIMacCanvasBoard(deviceID: deviceID, boardID: board.id)
        return Button {
            model.applyAIMacCanvasBoard(deviceID: deviceID, boardID: board.id)
            selection = .aiMacScreen
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isCurrent ? "circle.inset.filled" : "circle")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 14)
                Text(board.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrent && selection == .aiMacScreen
                      ? Color.accentColor.opacity(0.18) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        .help("切换到这台 AI Mac 小屏幕并应用「\(board.name)」")
    }

    /// 设备二级菜单相对设备名的缩进宽度（图标与文字整体右移）
    private static let submenuIndent: CGFloat = 16

    /// 口袋先知「画板管理」行：与灵犀键盘卡片管理一致，右侧直接控制该设备自动轮播。
    private func oracleBoardManagementSidebarRow(_ deviceID: UUID) -> some View {
        let rotationOn = model.settings.devices.first(where: { $0.id == deviceID })?
            .settings.oracleBoardRotationEnabled ?? false
        return HStack(spacing: 8) {
            Button {
                model.switchDevice(type: .oracle, to: deviceID)
                selection = .oracleBoardManagement
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Panel.oracleBoardManagement.icon)
                        .frame(width: 18, height: 18)
                    Text(Panel.oracleBoardManagement.title)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(selection == .oracleBoardManagement ? Color.accentColor : Color.primary)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(rotationOn ? Color.accentColor : Color.secondary)
                .help("自动轮播快捷开关")
            Toggle("", isOn: model.oracleDeviceBoardRotationBinding(for: deviceID))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help("该口袋先知设备的自动轮播开关（间隔、排序与参与内容在“画板管理”中调整）")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selection == .oracleBoardManagement
                      ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// 摘录「画板管理」行：右侧直接控制该设备的自动轮播。
    private func excerptBoardManagementSidebarRow(_ deviceID: UUID) -> some View {
        let rotationOn = model.settings.devices.first(where: { $0.id == deviceID })?
            .settings.excerptBoardRotationEnabled ?? false
        return HStack(spacing: 8) {
            Button {
                model.switchDevice(type: .excerpt, to: deviceID)
                selection = .excerptBoardManagement
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Panel.excerptBoardManagement.icon)
                        .frame(width: 18, height: 18)
                    Text(Panel.excerptBoardManagement.title)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(selection == .excerptBoardManagement ? Color.accentColor : Color.primary)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(rotationOn ? Color.accentColor : Color.secondary)
                .help("自动轮播快捷开关")
            Toggle("", isOn: model.excerptDeviceBoardRotationBinding(for: deviceID))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help("该摘录设备的自动轮播开关（间隔、排序与参与内容在“画板管理”中调整）")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selection == .excerptBoardManagement
                      ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// AI Mac「画板管理」行：右侧直接控制该小屏幕的自动轮播。
    private func aiMacBoardManagementSidebarRow(_ deviceID: UUID) -> some View {
        let rotationOn = model.aiMacScreenSettings(for: deviceID).boardRotationEnabled
        return HStack(spacing: 8) {
            Button {
                model.switchDevice(type: .aiMacScreen, to: deviceID)
                selection = .aiMacBoardManagement
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Panel.aiMacBoardManagement.icon)
                        .frame(width: 18, height: 18)
                    Text(Panel.aiMacBoardManagement.title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(selection == .aiMacBoardManagement ? Color.accentColor : Color.primary)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(rotationOn ? Color.accentColor : Color.secondary)
            Toggle("", isOn: model.aiMacBoardRotationBinding(for: deviceID))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help("该 AI Mac 小屏幕的自动轮播开关")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selection == .aiMacBoardManagement
                  ? Color.accentColor.opacity(0.25) : Color.clear))
        .contentShape(Rectangle())
    }

    private func aiMacCardManagementSidebarRow(_ deviceID: UUID) -> some View {
        let rotationOn = model.aiMacScreenSettings(for: deviceID).cardRotationEnabled
        return HStack(spacing: 8) {
            Button {
                model.switchDevice(type: .aiMacScreen, to: deviceID)
                selection = .aiMacCardManagement
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Panel.aiMacCardManagement.icon)
                        .frame(width: 18, height: 18)
                    Text(Panel.aiMacCardManagement.title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(selection == .aiMacCardManagement ? Color.accentColor : Color.primary)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(rotationOn ? Color.accentColor : Color.secondary)
            Toggle("", isOn: model.aiMacCardRotationBinding(for: deviceID))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help("该 AI Mac 小屏幕的卡片自动轮播开关")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selection == .aiMacCardManagement
                  ? Color.accentColor.opacity(0.25) : Color.clear))
        .contentShape(Rectangle())
    }

    private func aiMacCardSidebarRow(_ mode: DisplayMode, deviceID: UUID) -> some View {
        let current = model.activeDeviceID(for: .aiMacScreen) == deviceID
            && model.isCurrentAIMacCard(deviceID: deviceID, mode: mode)
        let selected = current && selection == .aiMacCard
        return Button {
            if model.activeDeviceID(for: .aiMacScreen) != deviceID {
                model.switchDevice(type: .aiMacScreen, to: deviceID)
            }
            model.activateAIMacCard(mode, deviceID: deviceID)
            selection = .aiMacCard
        } label: {
            HStack(spacing: 8) {
                Image(systemName: mode.icon)
                    .frame(width: 18, height: 18)
                Text(mode.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            // 与灵犀键盘 sidebarRow 使用同一字号、图标框和行高标准。
            .font(.system(size: 12))
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .help("在这台 AI Mac 小屏幕显示“\(mode.title)”")
    }

    /// 「卡片轮换」行：左侧打开轮换设置页，右侧是该键盘设备的自动轮播开关
    private func cardRotationRow(_ deviceID: UUID) -> some View {
        let rotationOn = model.settings.devices.first(where: { $0.id == deviceID })?
            .settings.cardRotationEnabled ?? false
        return HStack(spacing: 8) {
            Button {
                // 卡片管理页编辑的是「当前操作设备」：先切到这台键盘，避免改到别的键盘
                model.switchDevice(type: .keyboard, to: deviceID)
                selection = .cardRotation
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Panel.cardRotation.icon)
                        .frame(width: 18, height: 18)
                    Text(Panel.cardRotation.title)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(selection == .cardRotation ? Color.accentColor : Color.primary)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(rotationOn ? Color.accentColor : Color.secondary)
                .help("自动轮播快捷开关")
            Toggle("", isOn: model.deviceRotationEnabledBinding(for: deviceID))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help("该键盘设备的自动轮播开关（间隔与内容在「卡片管理」中调整）")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selection == .cardRotation ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// 「正在播放」选项卡 + 播放器信息合并卡片：点击一起跳转到正在播放页面
    private var nowPlayingCard: some View {
        let isSelected = selection == .nowPlaying
        return Button {
            selection = .nowPlaying
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "music.note")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("正在播放")
                        .font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    // 专辑封面 + 封面主色高斯模糊光斑（光斑层不被封面圆角裁切）；
                    // 选中态用光斑增亮表达，不再需要高亮框；浅色模式下不显示光晕
                    ZStack {
                        if let glow = model.sidebarArtworkGlow, model.settings.softwareIsDark {
                            let glowColor = Color(nsColor: glow)
                            Circle()
                                .fill(glowColor)
                                .frame(width: 144, height: 144)
                                .blur(radius: 48)
                                .opacity(isSelected ? 1.0 : 0.5)
                                // 点亮/变暗与换曲变色均做动画衔接，不生硬跳变
                                .animation(.easeInOut(duration: 0.6), value: isSelected)
                                .animation(.easeInOut(duration: 0.6), value: glowColor)
                        }
                        ZStack {
                            if let artwork = model.sidebarArtwork {
                                Image(nsImage: artwork)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Color.secondary.opacity(0.14)
                                Image(systemName: "music.note")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                        )
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.nowPlaying.title.isEmpty || model.nowPlaying.title == "未在播放"
                             ? "未在播放" : model.nowPlaying.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(model.nowPlaying.artist.isEmpty ? "—" : model.nowPlaying.artist)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 12))
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .help(model.nowPlayingSummary)
    }

    /// 侧栏行：设备分组内的功能项点击时先把操作设备切到所属设备再打开页面
    private func sidebarRow(_ panel: Panel, switchingTo type: DeviceType? = nil,
                            deviceID: UUID? = nil) -> some View {
        Button {
            if let type, let deviceID {
                model.switchDevice(type: type, to: deviceID)
                if type == .aiMacScreen {
                    switch panel {
                    case .aiMacDashboard:
                        model.activateAIMacScreenMode(.dashboard, deviceID: deviceID)
                    case .aiMacClock:
                        model.activateAIMacScreenMode(.clock, deviceID: deviceID)
                    case .aiMacCustomImage:
                        model.activateAIMacScreenMode(.customImage, deviceID: deviceID)
                    default:
                        break
                    }
                }
            }
            // 用户进入 HA/Bambu 卡片时显式激活一次。切换键盘设备可能已从设备快照恢复出
            // 相同 displayMode，因此这里允许同模式重新激活；随后 selection 的 onChange
            // 再调用普通 setMode 会因模式未变化而短路，不会产生第二次查询。
            if let mode = panel.displayMode,
               mode.refreshesHomeAssistantOnEntry || mode.formlabsSlotIndex != nil {
                model.setMode(mode, reactivateIfUnchanged: true)
            }
            selection = panel
        } label: {
            HStack(spacing: 8) {
                Image(systemName: panel.icon)
                    .frame(width: 18, height: 18)
                Text(model.bambuCardTitle(for: panel) ?? panel.title)
                    .lineLimit(1)
                if panel.isBeta {
                    BetaBadge()
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selection == panel ? Color.accentColor.opacity(0.25) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selection == panel ? Color.accentColor : Color.primary)
    }
}

/// 收起态迷你导航栏：保留最窄一条图标栏——选项卡图标快速切换 + 正在播放专辑封面（点击跳转）
struct MiniSidebar: View {
    @Binding var selection: Panel
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 2) {
            // 设备图标：每类设备一个入口（点击进入对应画板），不展示具体设备功能；
            // 该类型全部设备被禁用时隐藏对应图标
            if !model.enabledDevices(for: .keyboard).isEmpty {
                deviceIconButton(icon: "keyboard", title: "灵犀68 键盘", panel: .canvas)
            }
            if !model.enabledDevices(for: .oracle).isEmpty {
                deviceIconButton(icon: "sparkles", title: "口袋先知", panel: .oracleBoardManagement)
            }
            if !model.enabledDevices(for: .excerpt).isEmpty {
                deviceIconButton(icon: "quote.opening", title: "摘录", panel: .excerptBoardManagement)
            }
            if !model.enabledDevices(for: .aiMacScreen).isEmpty {
                deviceIconButton(icon: "display", title: "AI Mac 小屏幕", panel: .aiMacBoardManagement)
            }
            Spacer(minLength: 0)
            // 正在播放：专辑封面（点击跳转到正在播放页）
            Button {
                selection = .nowPlaying
            } label: {
                ZStack {
                    // 光晕层不被封面圆角裁切（与完整侧栏同一效果），选中态增亮/换曲变色带动画
                    if let glow = model.sidebarArtworkGlow, model.settings.softwareIsDark {
                        let glowColor = Color(nsColor: glow)
                        Circle()
                            .fill(glowColor)
                            .frame(width: 88, height: 88)
                            .blur(radius: 32)
                            .opacity(selection == .nowPlaying ? 1.0 : 0.5)
                            // 点亮/变暗与换曲变色均做动画衔接，不生硬跳变
                            .animation(.easeInOut(duration: 0.6), value: selection == .nowPlaying)
                            .animation(.easeInOut(duration: 0.6), value: glowColor)
                    }
                    ZStack {
                        if let artwork = model.sidebarArtwork {
                            Image(nsImage: artwork)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Color.secondary.opacity(0.14)
                            Image(systemName: "music.note")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 44, height: 44) // 与展开模式正在播放封面一致
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .help(model.nowPlayingSummary)
            Divider()
                .padding(.vertical, 4)
            // 底部固定项：设备管理 / 外观 / 设置
            ForEach([Panel.devices] + Panel.bottomItems) { panel in
                iconButton(panel)
            }
        }
        .padding(.top, 14) // 贴近红绿灯的留白，与完整侧栏一致
        .padding(.bottom, 8)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity)
    }

    /// 设备图标按钮：点击进入该设备对应的画板页面
    private func deviceIconButton(icon: String, title: String, panel: Panel) -> some View {
        let isSelected = selection == panel
        return Button {
            selection = panel
        } label: {
            // 图标大小与展开模式设备分组图标一致（15pt semibold / 22×22 视觉）
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func iconButton(_ panel: Panel) -> some View {
        let isSelected = selection == panel
        return Button {
            selection = panel
        } label: {
            // 图标大小与展开模式底部固定项一致（12pt / 18×18 视觉）
            Image(systemName: panel.icon)
                .font(.system(size: 12))
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help(panel.title)
    }
}

// MARK: - 实时预览

struct PreviewPanel: View {
    @ObservedObject var model: AppModel

    /// 设备外观图（俯视图，绿色区域即键盘显示区）；资源缺失时回退到普通圆角预览
    private static let deviceFrame: NSImage? = {
        guard let url = Bundle.main.url(forResource: "akko2", withExtension: "png"),
              let image = NSImage(contentsOf: url), image.size.width > 0 else { return nil }
        return image
    }()

    /// 外观图中绿色显示区的实测位置（相对整张图归一化，左上原点）
    private static let screenRect = CGRect(x: 0.19362, y: 0.33124, width: 0.61386, height: 0.60259)
    /// 显示区圆角（相对图宽实测 49/909；素材圆角为正圆弧，故用 .circular 匹配）
    private static let screenRadiusRatio: CGFloat = 0.05391
    /// 渲染画布与卡片几何（与 ScreenRenderer 保持一致）
    private static let canvasWidth: CGFloat = 142
    private static let canvasHeight: CGFloat = 428
    private static let cardInsetX: CGFloat = ScreenRenderer.cardInset
    private static let cardRadiusCanvas: CGFloat = ScreenRenderer.cardRadius
    /// 叠加层向外微扩（相对图宽），盖住抗锯齿留下的绿边
    private static let screenBleedRatio: CGFloat = 0.005
    /// 设备外观留白：上下左各 10pt，右侧贴住窗口右缘不留缝隙
    static let panelPadding: CGFloat = 10
    static let panelRightPadding: CGFloat = 0

    /// 设备外观图宽高比（缺失时用打包资源的设计比例兜底）
    private static var deviceRatio: CGFloat {
        guard let frame = deviceFrame, frame.size.height > 0 else { return 456.0 / 1357.0 }
        return frame.size.width / frame.size.height
    }

    /// 按比例把可用空间折算成等比适配尺寸
    private static func fitSize(ratio: CGFloat, in size: CGSize) -> CGSize {
        guard ratio > 0, size.width > 0, size.height > 0 else { return .zero }
        return size.width / size.height > ratio
            ? CGSize(width: size.height * ratio, height: size.height)
            : CGSize(width: size.width, height: size.width / ratio)
    }

    /// 面板内可用于绘制设备图的区域（左/上/下留 panelPadding，右侧贴边）
    private static func innerSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width - panelPadding - panelRightPadding, 1),
               height: max(size.height - panelPadding * 2, 1))
    }

    /// 面板宽度按面板自身可用高度等比反推：设备图按高度铺满，左侧 10pt、右侧贴边
    static func preferredWidth(forHeight height: CGFloat) -> CGFloat {
        guard height > 0 else { return 210 }
        let usableHeight = max(height - panelPadding * 2, 1)
        return (usableHeight * deviceRatio + panelPadding + panelRightPadding).rounded(.up)
    }

    /// 面板自身实测高度（用于反推宽度，避免用窗口高度估算带来的误差）
    @State private var measuredHeight: CGFloat = 0
    /// 鼠标是否悬停在预览面板上：底部信息胶囊默认隐藏，悬停时才淡入
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image = model.previewImage, let frame = Self.deviceFrame {
                    devicePreview(image: image, frame: frame, in: geo.size)
                } else if let image = model.previewImage {
                    plainPreview(image: image, in: Self.innerSize(geo.size))
                } else {
                    ProgressView()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .onAppear { measuredHeight = geo.size.height }
            .onChange(of: geo.size.height) { _, newHeight in
                if abs(newHeight - measuredHeight) > 0.5 { measuredHeight = newHeight }
            }
        }
        .frame(width: Self.preferredWidth(forHeight: measuredHeight))
        // 悬停整个预览面板（设备图区域）才显示底部信息胶囊
        .onHover { hovering in isHovering = hovering }
        // 沉浸式标题栏的安全区会把整列内容往下推约 50pt：预览顶部忽略安全区，
        // 设备外观只需按设计留 10pt 上边距
        .ignoresSafeArea(.all, edges: .top)
    }

    /// 设备外观打底 + 渲染画面叠加在绿色显示区上（正圆弧角匹配，右侧贴边）
    private func devicePreview(image: NSImage, frame: NSImage, in size: CGSize) -> some View {
        let inner = Self.innerSize(size)
        let fitted = Self.fitSize(ratio: frame.size.width / frame.size.height, in: inner)
        // 顶部固定 10pt、右侧贴住面板右缘；若面板比理想宽度更宽，余量全部留在左侧
        let originX = size.width - Self.panelRightPadding - fitted.width
        let originY = Self.panelPadding
        let screen = Self.screenRect
        let bleed = max(fitted.width * Self.screenBleedRatio, 0.5)
        // 叠加时以「渲染卡片」而非整张画布对齐显示区：卡片左右边缘铺满绿色区，
        // 画布四周的深色留白被裁到显示区之外，圆角也改用卡片自身半径，
        // 避免出现「设备黑框 + 画面圆角」双层圆角与四角黑楔
        let viewportW = fitted.width * screen.width + bleed * 2
        let viewportH = fitted.height * screen.height + bleed * 2
        let unit = viewportW / (Self.canvasWidth - Self.cardInsetX * 2)
        let imageW = Self.canvasWidth * unit
        let imageH = Self.canvasHeight * unit
        let radius = Self.cardRadiusCanvas * unit + bleed
        let cardShiftY = -ScreenRenderer.cardCenterOffsetY(safeArea: model.settings.safeAreaHeight) * unit
        return ZStack {
            Image(nsImage: frame)
                .resizable()
                .interpolation(.high)
                .frame(width: fitted.width, height: fitted.height)
                .position(x: originX + fitted.width / 2, y: originY + fitted.height / 2)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: imageW, height: imageH)
                .offset(y: cardShiftY)
                .frame(width: viewportW, height: viewportH)
                .clipped()
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .circular))
                .overlay {
                    // 与设备黑色边框衔接，压住抗锯齿边缘
                    RoundedRectangle(cornerRadius: radius, style: .circular)
                        .stroke(Color.black.opacity(0.65), lineWidth: max(fitted.width * 0.004, 0.6))
                }
                .position(x: originX + fitted.width * screen.midX,
                          y: originY + fitted.height * screen.midY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            VStack(spacing: 1) {
                Text("实时预览 · \(model.menuTitle(for: model.settings.displayMode))")
                Text("142 × 428 · JPEG")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
            .padding(.bottom, 6)
            // 默认隐藏：不占用设备外观的视觉空间；鼠标移到预览面板上才淡入
            .opacity(isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isHovering)
            .allowsHitTesting(false)
        }
    }

    /// 回退预览：没有设备外观图时，按画布比例圆角展示
    private func plainPreview(image: NSImage, in size: CGSize) -> some View {
        let fitted = Self.fitSize(ratio: image.size.width / image.size.height, in: size)
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: max(fitted.width, 1), height: max(fitted.height, 1))
            .clipShape(RoundedRectangle(cornerRadius: max(fitted.width * 0.09, 6), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: max(fitted.width * 0.09, 6), style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .position(x: size.width / 2, y: size.height / 2)
    }
}

// MARK: - 裁切编辑器（按屏幕显示区域比例选择图片显示部分）

struct CropEditorView: View {
    let sourceImage: NSImage
    /// 裁切比例（宽/高）：键盘 142×428 带安全区、先知 200×200、摘录 296×152
    let cropRatio: CGFloat
    let onConfirm: (CGImage) -> Void
    let onCancel: () -> Void

    @State private var imageOffset: CGSize = .zero
    @State private var zoom: CGFloat = 1.0
    @State private var gestureStartOffset: CGSize = .zero
    @State private var displaySize: CGSize = .zero

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("裁切区域")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HelpIcon(text: "拖动图片选择要显示的区域，滑动可缩放。")
            }
            .padding(.top, 8)

            GeometryReader { geo in
                ZStack {
                    Color.black
                    imageLayer(in: geo.size)
                    cropMask(in: geo.size)
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let proposed = CGSize(
                                width: gestureStartOffset.width + value.translation.width,
                                height: gestureStartOffset.height + value.translation.height)
                            imageOffset = clampedOffset(proposed, in: geo.size)
                        }
                        .onEnded { _ in
                            gestureStartOffset = imageOffset
                        }
                )
                .onAppear { displaySize = geo.size }
                .onChange(of: geo.size) { displaySize = $0 }
            }
            .frame(minHeight: 320)

            HStack(spacing: 14) {
                Button("取消") { onCancel() }
                Spacer()
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $zoom, in: 1...4, step: 0.1)
                    .frame(width: 180)
                Image(systemName: "plus.magnifyingglass")
                Button("确认裁剪", action: confirm)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(width: 400, height: 560)
    }

    // MARK: 图层

    private var imagePixels: (CGFloat, CGFloat) {
        guard let cg = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (1, 1) }
        return (CGFloat(cg.width), CGFloat(cg.height))
    }

    /// 裁切框显示尺寸（保持显示区域比例，适配编辑区）
    private func cropDisplaySize(in display: CGSize) -> CGSize {
        let maxH = display.height - 8
        let maxW = display.width - 8
        let w = min(maxW, maxH * cropRatio)
        return CGSize(width: w, height: w / cropRatio + 0.001)
    }

    /// 缩放 1x 时图片刚好覆盖裁切框
    private func baseScale(crop: CGSize, pw: CGFloat, ph: CGFloat) -> CGFloat {
        max(crop.width / pw, crop.height / ph)
    }

    private func imageLayer(in display: CGSize) -> some View {
        let (pw, ph) = imagePixels
        let cropSize = cropDisplaySize(in: display)
        let scale = baseScale(crop: cropSize, pw: pw, ph: ph) * zoom
        return Image(nsImage: sourceImage)
            .resizable()
            .interpolation(.high)
            .frame(width: pw * scale, height: ph * scale)
            .position(x: display.width / 2 + imageOffset.width,
                      y: display.height / 2 + imageOffset.height)
    }

    /// 裁切框外的暗化遮罩 + 白色边框
    private func cropMask(in display: CGSize) -> some View {
        let cropSize = cropDisplaySize(in: display)
        let cx = display.width / 2
        let cy = display.height / 2
        return ZStack {
            Color.black.opacity(0.55)
                .mask(
                    ZStack {
                        Rectangle().fill(Color.white)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black)
                            .frame(width: cropSize.width, height: cropSize.height)
                            .position(x: cx, y: cy)
                    }
                    .compositingGroup()
                )
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white, lineWidth: 2)
                .frame(width: cropSize.width, height: cropSize.height)
                .position(x: cx, y: cy)
        }
        .allowsHitTesting(false)
    }

    /// 限制图片偏移，保证图片始终覆盖裁切框
    private func clampedOffset(_ proposed: CGSize, in display: CGSize) -> CGSize {
        let (pw, ph) = imagePixels
        return ImageCropper.clampedOffset(
            proposed,
            imageSize: CGSize(width: pw, height: ph),
            displaySize: display,
            zoom: zoom,
            cropDisplaySize: cropDisplaySize(in: display))
    }

    private func confirm() {
        guard let cg = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              displaySize.width > 0 else { return }
        guard let rect = ImageCropper.cropRect(
            imageSize: CGSize(width: CGFloat(cg.width), height: CGFloat(cg.height)),
            displaySize: displaySize,
            imageOffset: imageOffset,
            zoom: zoom,
            cropDisplaySize: cropDisplaySize(in: displaySize)),
              let cropped = cg.cropping(to: rect) else { return }
        onConfirm(cropped)
    }
}

// MARK: - HA 实体两级选择器

/// Home Assistant 实体选择器：第一级 = 实体域分类（sensor/binary_sensor/…，显示实体数量），
/// 第二级 = 分类下的实体列表（friendly_name + entity_id，点击选中回填）。
/// 顶部搜索框按名称或 entity_id 关键字过滤；分类默认收起、点击展开，0.2s 过渡动画；
/// 数据模型不变（仍存 entity_id 字符串）；外观跟随系统深浅色。
struct EntityDomainPicker: View {
    let title: String
    @Binding var selection: String
    let entities: [HAEntity]
    var emptyLabel = "未选择"
    var clearLabel = "清除选择"
    var allowClear = true
    /// 设备管理中的自动匹配使用更宽、更高的实体浏览面板。
    var largePopover = false
    /// 可选的默认筛选开关。传入时，开关直接显示在 Popover 内。
    var defaultFilter: Binding<Bool>? = nil
    /// 关闭默认筛选后使用的完整候选集。
    var unfilteredEntities: [HAEntity]? = nil
    var filterEnabledDescription = ""
    var filterDisabledDescription = ""
    /// 多选模式：Popover 内实体行勾选多个，底部「确认添加」批量回调（已锁定实体显示实心勾选不可取消）
    var multiSelect = false
    /// 多选模式下已加入列表的实体（锁定勾选，再次打开可见）
    var lockedIDs: Set<String> = []
    /// 多选确认回调：参数为本次勾选的实体（按实体列表顺序）
    var onMultiConfirm: (([String]) -> Void)?

    @State private var showPicker = false

    private var selectedEntity: HAEntity? {
        guard !selection.isEmpty else { return nil }
        let lookupEntities = defaultFilter?.wrappedValue == false
            ? (unfilteredEntities ?? entities) : entities
        return lookupEntities.first { $0.entityId == selection }
    }

    /// 已绑定但当前服务器实体池中查不到（换服务器后的失效绑定；基线关闭该提示）
    private var isStaleBinding: Bool {
        AppModel.haStaleHintsEnabled
            && !selection.isEmpty && selectedEntity == nil && !entities.isEmpty
    }

    /// 按钮右侧显示的选择状态文字
    private var selectionLabel: String {
        if multiSelect { return "\(lockedIDs.count) 个已选" }
        if let selectedEntity { return selectedEntity.displayName }
        if isStaleBinding { return "失效 · \(selection)" }
        return emptyLabel
    }

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                Text(selectionLabel)
                    .lineLimit(1)
                    .foregroundStyle(isStaleBinding ? Color.orange
                                       : (multiSelect || selectedEntity == nil ? Color.secondary : Color.primary))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // macOS 原生 Popover：系统保证「点击内部任何元素不关闭、点击外部才关闭」，
        // 从机制上根治「点击实体行/搜索框导致选择器收起」的问题
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            EntityPickerContent(selection: $selection,
                                entities: entities,
                                emptyLabel: emptyLabel,
                                clearLabel: clearLabel,
                                allowClear: allowClear,
                                largePopover: largePopover,
                                defaultFilter: defaultFilter,
                                unfilteredEntities: unfilteredEntities,
                                filterEnabledDescription: filterEnabledDescription,
                                filterDisabledDescription: filterDisabledDescription,
                                multiSelect: multiSelect,
                                lockedIDs: lockedIDs,
                                onSingleSelect: { showPicker = false },
                                onMultiConfirm: { ids in
                                    onMultiConfirm?(ids)
                                    showPicker = false
                                })
        }
    }
}

/// 实体选择器内容（Popover 内）：搜索框 + 清除 + 分类列表（可滚动）+ 实体行 + 多选确认栏。
/// 点击内部任何元素（勾选框/名称/搜索框/分类行）都不会关闭 Popover（系统保证）；
/// 点击 Popover 外部自动关闭。
private struct EntityPickerContent: View {
    @Binding var selection: String
    let entities: [HAEntity]
    var emptyLabel = "未选择"
    var clearLabel = "清除选择"
    var allowClear = true
    var largePopover = false
    var defaultFilter: Binding<Bool>? = nil
    var unfilteredEntities: [HAEntity]? = nil
    var filterEnabledDescription = ""
    var filterDisabledDescription = ""
    var multiSelect = false
    var lockedIDs: Set<String> = []
    /// 单选选中后回调（关闭 Popover）
    var onSingleSelect: () -> Void = {}
    /// 多选确认回调（批量勾选结果）
    var onMultiConfirm: (([String]) -> Void)?

    @State private var expandedDomains: Set<String> = []
    @State private var keyword = ""
    @State private var checked: Set<String> = []

    private var effectiveEntities: [HAEntity] {
        defaultFilter?.wrappedValue == false ? (unfilteredEntities ?? entities) : entities
    }

    private var filtered: [HAEntity] {
        HAEntityPicker.filter(effectiveEntities, keyword: keyword)
    }

    private var grouped: [(domain: String, entities: [HAEntity])] {
        HAEntityPicker.groupByDomain(filtered)
    }

    private var checkedOrdered: [String] {
        effectiveEntities.filter { checked.contains($0.entityId) }.map(\.entityId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let defaultFilter {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { defaultFilter.wrappedValue },
                            set: { newValue in
                                defaultFilter.wrappedValue = newValue
                                keyword = ""
                                expandedDomains.removeAll()
                            }
                        )) {
                            HStack(spacing: 4) {
                                Text("使用默认筛选")
                                HelpIcon(text: defaultFilter.wrappedValue
                                         ? filterEnabledDescription : filterDisabledDescription)
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        Spacer()
                        Text("\(effectiveEntities.count) 个候选")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                    .padding(.bottom, 2)
            }

            // 搜索框：按名称或 entity_id 过滤
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索名称、entity_id 或分类（如 灯 / 开关）", text: $keyword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            // 清除选择（单选模式）
            if allowClear && !selection.isEmpty {
                Button {
                    selection = ""
                    keyword = ""
                    onSingleSelect()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slash.circle")
                            .font(.system(size: 11))
                        Text(clearLabel)
                            .font(.system(size: 12))
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                    .padding(.leading, 2)
                }
                .buttonStyle(.plain)
            }

            // 分类列表（可滚动，实体多时也能完整浏览）
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if grouped.isEmpty {
                        Text("无匹配实体")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                            .padding(.leading, 4)
                    } else {
                        ForEach(grouped, id: \.domain) { group in
                            domainRow(group)
                        }
                    }
                }
            }
            .frame(minHeight: largePopover ? 300 : nil,
                   maxHeight: largePopover ? 460 : 340)

            // 多选确认栏
            if multiSelect {
                HStack(spacing: 8) {
                    Text(checked.isEmpty ? "勾选实体后批量添加" : "已勾选 \(checked.count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        onMultiConfirm?(checkedOrdered)
                    } label: {
                        Text("确认添加")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(checked.isEmpty)
                }
            }
        }
        .padding(largePopover ? 16 : 14)
        // 普通映射弹窗也需要容纳较长的设备名和 entity_id；自动匹配面板再宽一档。
        .frame(width: largePopover ? 640 : 520)
        .onAppear {
            // 自动匹配候选通常只有一组；大面板直接展开，减少一次无意义点击。
            if largePopover, grouped.count == 1, let domain = grouped.first?.domain {
                expandedDomains.insert(domain)
            }
        }
    }

    /// 第一级：实体域分类行（域 + 数量 + 展开箭头），点击展开该分类实体
    private func domainRow(_ group: (domain: String, entities: [HAEntity])) -> some View {
        let isExpanded = expandedDomains.contains(group.domain)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedDomains.remove(group.domain)
                    } else {
                        expandedDomains.insert(group.domain)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(HAEntityPicker.chineseDomain(group.domain))
                        .font(.system(size: 12, weight: .medium))
                    if HAEntityPicker.chineseDomain(group.domain) != group.domain {
                        Text(group.domain)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Text("\(group.entities.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, 5)
                .padding(.leading, 4)
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(group.entities, id: \.entityId) { entity in
                    entityRow(entity)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// 第二级：实体行。勾选框为纯手势区（highPriorityGesture 隔离 + 命中区 28×24），
    /// 点击只切换勾选、绝不触发收起；名称区同样切换。锁定态（已添加）禁用
    private func entityRow(_ entity: HAEntity) -> some View {
        let isLocked = multiSelect && lockedIDs.contains(entity.entityId)
        let isChecked = multiSelect
            ? (isLocked || checked.contains(entity.entityId))
            : (entity.entityId == selection)
        let iconName = isChecked ? "checkmark.circle.fill" : "circle"
        let iconColor: Color = isLocked ? Color.orange.opacity(0.85)
            : (isChecked ? Color.accentColor : Color.secondary)
        return HStack(spacing: 6) {
            // 勾选框：纯手势区（Image + highPriorityGesture），不依赖 Button 命中；
            // 实测独立 Button 在相邻按钮 contentShape 抢占下不可靠，手势区最稳
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    TapGesture().onEnded {
                        if !isLocked {
                            toggleEntity(entity)
                        }
                    }
                )
                .opacity(isLocked ? 0.9 : 1)
                .help(isLocked ? "已在显示列表中" : "点击勾选/取消")
            // 名称区：多选点击同勾选；单选点击选中回填
            Button {
                toggleEntity(entity)
            } label: {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entity.displayName)
                            .font(.system(size: largePopover ? 13 : 12))
                            .foregroundStyle(isChecked ? (isLocked ? Color.primary : Color.accentColor) : Color.primary)
                        Text(entity.entityId)
                            .font(.system(size: largePopover ? 11 : 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isLocked {
                        Text("已添加")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
            .help(isLocked ? "已在显示列表中" : (multiSelect ? "点击勾选/取消" : "点击选中"))
        }
        .padding(.vertical, largePopover ? 6 : 3)
        .padding(.leading, 14)
    }

    /// 切换勾选/选中：多选只改勾选（Popover 不关闭）；单选选中回填并关闭 Popover
    private func toggleEntity(_ entity: HAEntity) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if multiSelect {
                if checked.contains(entity.entityId) {
                    checked.remove(entity.entityId)
                } else {
                    checked.insert(entity.entityId)
                }
            } else {
                selection = entity.entityId
                keyword = ""
                onSingleSelect()
            }
        }
    }
}

/// 彩蛋：所有打印机报错界面预览（连续点击告警标题 5 次触发）。
/// 为每台打印机渲染一张深红告警卡（含型号/错误码与 HMS 原因），便于检查报错效果。
private struct PrinterAlertPreviewSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 4) {
                Text("所有打印机报错界面预览")
                    .font(.headline)
                HelpIcon(text: "彩蛋：为每台打印机展示报错告警卡效果，使用错误码 07FE-4500-0002-0003 并包含故障原因。")
            }
            let printers = model.settings.devices
                .filter { $0.type == .bambuLab }
                .map { BambuLabCardSettings.from($0) }
            if printers.isEmpty {
                Text("尚未添加 Bambu Lab 打印机设备")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(printers.indices, id: \.self) { index in
                            alertCard(printers[index], index: index)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Button("关闭") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 380, height: 520)
    }

    private func alertCard(_ printer: BambuLabCardSettings, index: Int) -> some View {
        VStack(spacing: 6) {
            if let render = try? ScreenRenderer.renderHAAlert(
                title: printer.name.isEmpty ? "打印机 \(index + 1)" : printer.name,
                message: "07FE-4500-0002-0003",
                settings: model.settings) {
                Image(nsImage: NSImage(cgImage: render.image,
                                       size: NSSize(width: 142, height: 428)))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 100, height: 302)
                    .cornerRadius(8)
            }
            Text("打印机 \(index + 1)：\(printer.name.isEmpty ? "未命名" : printer.name)")
                .font(.system(size: 12, weight: .medium))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.05)))
    }
}

/// HA 实体 id 的 Identifiable 包装（多实体列表拖拽排序用）
struct HAEntityRef: Identifiable, Equatable {
    let id: String
}

/// 「添加 Home Assistant 实体」入口：直接弹出 Popover 多选选择器（域分类 + 搜索 + 勾选批量添加）。
/// 点击选择器内部任意元素不关闭（系统 Popover 保证），确认添加后批量回调。
private struct HAEntityAdder: View {
    let entities: [HAEntity]
    /// 已加入显示列表的实体（锁定勾选，再次打开可见）
    let alreadyAdded: Set<String>
    /// 批量添加回调（勾选确认后传入本次勾选的实体）
    let onAddBatch: ([String]) -> Void

    var body: some View {
        EntityDomainPicker(title: "添加实体（可多选）",
                           selection: .constant(""),
                           entities: entities,
                           emptyLabel: "未选择",
                           allowClear: false,
                           multiSelect: true,
                           lockedIDs: alreadyAdded,
                           onMultiConfirm: onAddBatch)
    }
}

// MARK: - AppModel 编辑绑定

extension AppModel {
    /// 键盘 IP（只显示主机部分，端点后缀由软件自动拼装）
    var keyboardHost: String {
        EndpointBuilder.host(from: settings.endpoint)
    }

    var keyboardIPBinding: Binding<String> {
        Binding(get: { EndpointBuilder.host(from: self.settings.endpoint) },
                set: { self.settings.endpoint = EndpointBuilder.endpoint(fromHost: $0) })
    }

    var appearanceBinding: Binding<AppearanceMode> {
        Binding(get: { self.settings.appearanceMode }, set: { self.settings.appearanceMode = $0 })
    }

    var backgroundToneBinding: Binding<BackgroundTone> {
        Binding(get: { self.settings.backgroundTone }, set: { self.settings.backgroundTone = $0 })
    }

    var accentToneBinding: Binding<AccentTone> {
        Binding(get: { self.settings.accentTone }, set: { self.settings.accentTone = $0 })
    }

    var customBackgroundBinding: Binding<Color> {
        Binding(get: { self.colorFromHex(self.settings.customBackgroundHex, fallback: .gray) },
                set: { self.settings.customBackgroundHex = Self.hexFromColor($0) })
    }

    var customAccentBinding: Binding<Color> {
        Binding(get: { self.colorFromHex(self.settings.customAccentHex, fallback: .blue) },
                set: { self.settings.customAccentHex = Self.hexFromColor($0) })
    }

    private func colorFromHex(_ hex: String?, fallback: Color) -> Color {
        guard let hex, let rgb = HexColor.parse(hex) else { return fallback }
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    private static func hexFromColor(_ color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .black
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        nsColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return HexColor.string(from: red, green, blue)
    }

    var codexCliPathBinding: Binding<String> {
        Binding(get: { self.settings.codexCliPath ?? "" },
                set: {
                    let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.settings.codexCliPath = normalized.isEmpty ? nil : normalized
                })
    }
    var codexUsageSourceBinding: Binding<CodexUsageSource> {
        Binding(get: { self.settings.codexUsageSource },
                set: { self.setCodexUsageSource($0) })
    }
    var taskNameBinding: Binding<String> {
        Binding(get: { self.pomodoroState.taskName }, set: { self.setTaskName($0) })
    }
    var safeAreaBinding: Binding<Double> {
        Binding(get: { Double(self.settings.safeAreaHeight) },
                set: { self.settings.safeAreaHeight = Int($0) })
    }
    var qualityBinding: Binding<Double> {
        Binding(get: { Double(self.settings.jpegQuality) },
                set: { self.settings.jpegQuality = Int($0) })
    }
    var dynamicUploadBinding: Binding<Double> {
        Binding(get: { Double(self.settings.dynamicUploadSeconds) },
                set: { self.settings.dynamicUploadSeconds = Int($0) })
    }
    var pomodoroUploadBinding: Binding<Int> {
        Binding(get: { self.settings.pomodoroUploadSeconds },
                set: { self.settings.pomodoroUploadSeconds = $0 })
    }
    var sspaiRefreshMinutesBinding: Binding<Double> {
        Binding(get: { Double(self.settings.sspaiRefreshMinutes) },
                set: { self.settings.sspaiRefreshMinutes = Int($0.rounded()) })
    }
    var sspaiRandomPushBinding: Binding<Bool> {
        Binding(get: { self.settings.sspaiRandomPush },
                set: { self.settings.sspaiRandomPush = $0 })
    }
    var showCpuBinding: Binding<Bool> {
        Binding(get: { self.settings.showCpu }, set: { self.settings.showCpu = $0 })
    }
    var showMemoryBinding: Binding<Bool> {
        Binding(get: { self.settings.showMemory }, set: { self.settings.showMemory = $0 })
    }
    var showNetworkBinding: Binding<Bool> {
        Binding(get: { self.settings.showNetwork }, set: { self.settings.showNetwork = $0 })
    }
    var showUptimeBinding: Binding<Bool> {
        Binding(get: { self.settings.showUptime }, set: { self.settings.showUptime = $0 })
    }
    var showDiskBinding: Binding<Bool> {
        Binding(get: { self.settings.showDisk }, set: { self.settings.showDisk = $0 })
    }
    var networkChartBinding: Binding<Bool> {
        Binding(get: { self.settings.networkChart }, set: { self.settings.networkChart = $0 })
    }
    var imageRotationEnabledBinding: Binding<Bool> {
        Binding(get: { self.settings.imageRotationEnabled }, set: { self.setImageRotationEnabled($0) })
    }
    /// 轮换间隔滑杆（0…1 非线性映射到 5 秒…5 分钟）
    var imageRotationSliderBinding: Binding<Double> {
        Binding(get: { RotationInterval.slider(fromSeconds: self.settings.imageRotationSeconds) },
                set: { self.settings.imageRotationSeconds = RotationInterval.seconds(fromSlider: $0) })
    }
    var imageRotationModeBinding: Binding<ImageRotationMode> {
        Binding(get: { self.settings.imageRotationMode }, set: { self.settings.imageRotationMode = $0 })
    }
    var customImageClockBinding: Binding<CustomImageClockOverlay> {
        Binding(get: { self.settings.customImageClock }, set: { self.setCustomImageClock($0) })
    }
    var wallpaperColorStyleBinding: Binding<WallpaperColorStyle> {
        Binding(get: { self.settings.wallpaperColorStyle },
                set: { self.settings.wallpaperColorStyle = $0 })
    }
    var clockDateVisibleBinding: Binding<Bool> {
        Binding(get: { self.settings.clockDateVisible },
                set: { self.settings.clockDateVisible = $0 })
    }
    var clockFontSizeBinding: Binding<Double> {
        Binding(get: { Double(self.settings.clockFontSize) },
                set: { self.settings.clockFontSize = Int($0.rounded()) })
    }
    var clockFontWeightBinding: Binding<ClockFontWeight> {
        Binding(get: { self.settings.clockFontWeight },
                set: { self.settings.clockFontWeight = $0 })
    }
    var clockFontBinding: Binding<ClockFont> {
        Binding(get: { self.settings.clockFont }, set: { self.settings.clockFont = $0 })
    }
    var clockOffsetXBinding: Binding<Double> {
        Binding(get: { Double(self.settings.clockOffsetX) },
                set: { self.settings.clockOffsetX = Int($0.rounded()) })
    }
    var clockOffsetYBinding: Binding<Double> {
        Binding(get: { Double(self.settings.clockOffsetY) },
                set: { self.settings.clockOffsetY = Int($0.rounded()) })
    }
    /// 全局时间格式预设：0=HH:mm 1=H:mm 2=HH:mm:ss 3=hh:mm 4=自定义
    var clockFormatPresetBinding: Binding<Int> {
        Binding(get: {
            switch self.settings.timeFormat {
            case "HH:mm": return 0
            case "H:mm": return 1
            case "HH:mm:ss": return 2
            case "hh:mm": return 3
            default: return 4
            }
        }, set: { preset in
            let patterns = ["HH:mm", "H:mm", "HH:mm:ss", "hh:mm"]
            if preset >= 0, preset < patterns.count {
                self.setClockTimeFormat(patterns[preset])
            }
        })
    }
    var clockTimeFormatBinding: Binding<String> {
        Binding(get: { self.settings.timeFormat },
                set: { self.setClockTimeFormat($0) })
    }

    /// 全局日期格式预设：0=yyyy年M月d日 EEE 1=M月d日 2=yyyy-MM-dd 3=M/d 4=自定义
    var dateFormatPresetBinding: Binding<Int> {
        Binding(get: {
            switch self.settings.dateFormat {
            case "yyyy年M月d日 EEE": return 0
            case "M月d日": return 1
            case "yyyy-MM-dd": return 2
            case "M/d": return 3
            default: return 4
            }
        }, set: { preset in
            let patterns = ["yyyy年M月d日 EEE", "M月d日", "yyyy-MM-dd", "M/d"]
            if preset >= 0, preset < patterns.count {
                self.setDateFormat(patterns[preset])
            }
        })
    }
    var dateFormatBinding: Binding<String> {
        Binding(get: { self.settings.dateFormat },
                set: { self.setDateFormat($0) })
    }
    var canvasTextBinding: Binding<String> {
        Binding(get: { self.settings.canvasText }, set: { self.setCanvasText($0) })
    }
    var dotApiKeyBinding: Binding<String> {
        Binding(get: { self.settings.dotApiKey }, set: { self.settings.dotApiKey = $0 })
    }
    var dotDeviceIdBinding: Binding<String> {
        Binding(get: { self.settings.dotDeviceId }, set: { self.settings.dotDeviceId = $0 })
    }
    var rand0IPBinding: Binding<String> {
        Binding(get: { self.settings.rand0IP }, set: { self.settings.rand0IP = $0 })
    }
    var rand0ButtonTargetBinding: Binding<Rand0ButtonTarget> {
        Binding(get: { self.settings.rand0ButtonTarget },
                set: { self.settings.rand0ButtonTarget = $0 })
    }
    var oracleImageRotate180Binding: Binding<Bool> {
        Binding(get: { self.settings.oracleImageRotate180 },
                set: { self.settings.oracleImageRotate180 = $0 })
    }
    var excerptImageRotate180Binding: Binding<Bool> {
        Binding(get: { self.settings.excerptImageRotate180 },
                set: { self.settings.excerptImageRotate180 = $0 })
    }
    var excerptBackgroundModeBinding: Binding<CanvasBackgroundMode> {
        Binding(get: { self.settings.excerptBackgroundMode },
                set: { self.settings.excerptBackgroundMode = $0 })
    }
    var excerptPushRawImageBinding: Binding<Bool> {
        Binding(get: { self.settings.excerptPushRawImage },
                set: { self.settings.excerptPushRawImage = $0 })
    }
    var excerptServerDitherTypeBinding: Binding<DotServerDitherType> {
        Binding(get: { self.settings.excerptServerDitherType },
                set: { self.settings.excerptServerDitherType = $0 })
    }
    var excerptServerDitherKernelBinding: Binding<DotServerDitherKernel> {
        Binding(get: { self.settings.excerptServerDitherKernel },
                set: { self.settings.excerptServerDitherKernel = $0 })
    }
    var oracleDisplayModeBinding: Binding<OracleDisplayMode> {
        Binding(get: { self.settings.oracleDisplayMode },
                set: { self.settings.oracleDisplayMode = $0 })
    }
    var oracleGrayAlgorithmBinding: Binding<OracleGrayAlgorithm> {
        Binding(get: { self.settings.oracleGrayAlgorithm },
                set: { self.settings.oracleGrayAlgorithm = $0 })
    }
    var oracleDitherKernelBinding: Binding<OracleDitherKernel> {
        Binding(get: { self.settings.oracleDitherKernel },
                set: { self.settings.oracleDitherKernel = $0 })
    }
    var excerptDisplayModeBinding: Binding<OracleDisplayMode> {
        Binding(get: { self.settings.excerptDisplayMode },
                set: { self.settings.excerptDisplayMode = $0 })
    }
    var excerptGrayAlgorithmBinding: Binding<OracleGrayAlgorithm> {
        Binding(get: { self.settings.excerptGrayAlgorithm },
                set: { self.settings.excerptGrayAlgorithm = $0 })
    }
    var excerptDitherKernelBinding: Binding<OracleDitherKernel> {
        Binding(get: { self.settings.excerptDitherKernel },
                set: { self.settings.excerptDitherKernel = $0 })
    }
    var excerptLayoutColumnsBinding: Binding<Int> {
        Binding(get: { self.settings.excerptLayoutColumns },
                set: { self.settings.excerptLayoutColumns = $0 })
    }
    var canvasNowPlayingCoverBinding: Binding<Bool> {
        Binding(get: { self.settings.canvasNowPlayingCover },
                set: { self.settings.canvasNowPlayingCover = $0 })
    }
    var canvasNowPlayingSmartBgBinding: Binding<Bool> {
        Binding(get: { self.settings.canvasNowPlayingSmartBg },
                set: { self.settings.canvasNowPlayingSmartBg = $0 })
    }
    /// Home Assistant 配置绑定（地址/令牌/刷新间隔/实体）
    var haServerURLBinding: Binding<String> {
        Binding(get: { self.settings.haServerURL },
                set: { self.settings.haServerURL = $0 })
    }
    var haTokenBinding: Binding<String> {
        Binding(get: { self.settings.haToken },
                set: { self.settings.haToken = $0 })
    }
    var haRefreshMinutesBinding: Binding<Int> {
        Binding(get: { self.settings.haRefreshMinutes },
                set: { self.settings.haRefreshMinutes = $0 })
    }
    /// HA 异常监控绑定
    var haMonitorEnabledBinding: Binding<Bool> {
        Binding(get: { self.settings.haMonitorEnabled },
                set: { self.settings.haMonitorEnabled = $0 })
    }
    var haMonitorEntityIDBinding: Binding<String> {
        Binding(get: { self.settings.haMonitorEntityID },
                set: { self.settings.haMonitorEntityID = $0 })
    }
    var haMonitorExpectedStateBinding: Binding<String> {
        Binding(get: { self.settings.haMonitorExpectedState },
                set: { self.settings.haMonitorExpectedState = $0 })
    }
    var haMonitorErrorEntityIDBinding: Binding<String> {
        Binding(get: { self.settings.haMonitorErrorEntityID },
                set: { self.settings.haMonitorErrorEntityID = $0 })
    }
    /// 画板「千问额度」模块显示方式（百分比 / 额度数值）
    var qwenQuotaShowPercentBinding: Binding<Bool> {
        Binding(get: { self.settings.qwenQuotaShowPercent },
                set: { self.settings.qwenQuotaShowPercent = $0 })
    }
    /// 口袋先知画板「正在播放」横向排布开关
    var oracleNowPlayingHorizontalBinding: Binding<Bool> {
        Binding(get: { self.settings.oracleNowPlayingHorizontal },
                set: { self.settings.oracleNowPlayingHorizontal = $0 })
    }
    /// 摘录画板「正在播放」横向排布开关
    var excerptNowPlayingHorizontalBinding: Binding<Bool> {
        Binding(get: { self.settings.excerptNowPlayingHorizontal },
                set: { self.settings.excerptNowPlayingHorizontal = $0 })
    }
    /// 各画板「少数派推荐」显示条数绑定（灵犀/口袋先知/摘录各自独立）
    func sspaiCountBinding(for owner: CanvasOwner) -> Binding<Int> {
        Binding(get: { self.sspaiCount(for: owner) },
                set: { self.setSspaiCount($0, for: owner) })
    }
    /// 各画板「少数派推荐」随机显示开关绑定（各自独立）
    func sspaiRandomBinding(for owner: CanvasOwner) -> Binding<Bool> {
        Binding(get: { self.sspaiRandomEnabled(for: owner) },
                set: { self.setSspaiRandom($0, for: owner) })
    }
    /// 摘录语录分类勾选绑定（多选；取消最后一个分类时由 UI 禁用，防止轮换池为空）
    func excerptQuoteCategoryBinding(for category: ExcerptQuoteCategory) -> Binding<Bool> {
        Binding(get: { self.settings.excerptQuoteCategories.contains(category.rawValue) },
                set: { isOn in self.setExcerptQuoteCategory(category, enabled: isOn) })
    }
    /// 摘录语录显示出处绑定
    var showExcerptSourceBinding: Binding<Bool> {
        Binding(get: { self.settings.showExcerptSource },
                set: { self.settings.showExcerptSource = $0 })
    }
    /// Emoji 壁纸：表情串绑定
    var emojiWallpaperTextBinding: Binding<String> {
        Binding(get: { self.settings.emojiWallpaperText },
                set: { self.settings.emojiWallpaperText = $0 })
    }
    /// Emoji 壁纸：排列方式绑定
    var emojiWallpaperLayoutBinding: Binding<EmojiWallpaperLayout> {
        Binding(get: { self.settings.emojiWallpaperLayout },
                set: { self.settings.emojiWallpaperLayout = $0 })
    }
    /// Emoji 壁纸：字号滑杆绑定
    var emojiWallpaperSizeBinding: Binding<Double> {
        Binding(get: { Double(self.settings.emojiWallpaperSize) },
                set: { self.settings.emojiWallpaperSize = Int($0.rounded()) })
    }
    /// Emoji 壁纸：表情间隔滑杆绑定
    var emojiWallpaperSpacingBinding: Binding<Double> {
        Binding(get: { Double(self.settings.emojiWallpaperSpacing) },
                set: { self.settings.emojiWallpaperSpacing = Int($0.rounded()) })
    }
    var canvasImageModeBinding: Binding<CanvasImageMode> {
        Binding(get: { self.settings.canvasImageMode },
                set: { self.settings.canvasImageMode = $0 })
    }
    var cardRotationEnabledBinding: Binding<Bool> {
        Binding(get: { self.settings.cardRotationEnabled }, set: { self.setCardRotationEnabled($0) })
    }
    var cardRotationMinutesBinding: Binding<Double> {
        Binding(get: { Double(self.settings.cardRotationMinutes) },
                set: { self.setCardRotationMinutes(Int($0.rounded())) })
    }
    var sidebarWidthBinding: Binding<Double> {
        Binding(get: { Double(self.settings.sidebarWidth) },
                set: { self.settings.sidebarWidth = Int($0.rounded()) })
    }
    var pomodoroPraiseEnabledBinding: Binding<Bool> {
        Binding(get: { self.settings.pomodoroPraiseEnabled },
                set: { self.settings.pomodoroPraiseEnabled = $0 })
    }
    var pomodoroPraiseSourceBinding: Binding<PraiseSource> {
        Binding(get: { self.settings.pomodoroPraiseSource },
                set: { self.settings.pomodoroPraiseSource = $0 })
    }
    var pomodoroTaskFontSizeBinding: Binding<Double> {
        Binding(get: { Double(self.settings.pomodoroTaskFontSize) },
                set: { self.settings.pomodoroTaskFontSize = Int($0.rounded()) })
    }
    var nowPlayingTitleSizeBinding: Binding<Double> {
        Binding(get: { Double(self.settings.nowPlayingTitleSize) },
                set: { self.settings.nowPlayingTitleSize = Int($0.rounded()) })
    }
    var nowPlayingArtistSizeBinding: Binding<Double> {
        Binding(get: { Double(self.settings.nowPlayingArtistSize) },
                set: { self.settings.nowPlayingArtistSize = Int($0.rounded()) })
    }
    var nowPlayingFooterVisibleBinding: Binding<Bool> {
        Binding(get: { self.settings.nowPlayingFooterVisible },
                set: { self.settings.nowPlayingFooterVisible = $0 })
    }
    var nowPlayingTimeSizeBinding: Binding<Double> {
        Binding(get: { Double(self.settings.nowPlayingTimeSize) },
                set: { self.settings.nowPlayingTimeSize = Int($0.rounded()) })
    }
    var nowPlayingDateSizeBinding: Binding<Double> {
        Binding(get: { Double(self.settings.nowPlayingDateSize) },
                set: { self.settings.nowPlayingDateSize = Int($0.rounded()) })
    }
    var canvasNowPlayingTitleSizeBinding: Binding<Double> {
        Binding(get: { Double(self.settings.canvasNowPlayingTitleSize) },
                set: { self.settings.canvasNowPlayingTitleSize = Int($0.rounded()) })
    }
    var oracleBackgroundModeBinding: Binding<CanvasBackgroundMode> {
        Binding(get: { self.settings.oracleBackgroundMode },
                set: { self.settings.oracleBackgroundMode = $0 })
    }
    var canvasNowPlayingArtistSizeBinding: Binding<Double> {
        Binding(get: { Double(self.settings.canvasNowPlayingArtistSize) },
                set: { self.settings.canvasNowPlayingArtistSize = Int($0.rounded()) })
    }
    var oracleAutoPushEnabledBinding: Binding<Bool> {
        Binding(get: { self.settings.oracleAutoPushEnabled },
                set: { self.setOracleAutoPushEnabled($0) })
    }
    var oracleAutoPushMinutesBinding: Binding<Double> {
        Binding(get: { Double(self.settings.oracleAutoPushMinutes) },
                set: { self.settings.oracleAutoPushMinutes = Int($0.rounded()) })
    }
    var oracleBoardRotationEnabledBinding: Binding<Bool> {
        Binding(get: { self.settings.oracleBoardRotationEnabled },
                set: { self.setOracleBoardRotationEnabled($0) })
    }
    var oracleBoardRotationMinutesBinding: Binding<Double> {
        Binding(get: { Double(self.settings.oracleBoardRotationMinutes) },
                set: { self.settings.oracleBoardRotationMinutes = Int($0.rounded()) })
    }
    var excerptAutoPushEnabledBinding: Binding<Bool> {
        Binding(get: { self.settings.excerptAutoPushEnabled },
                set: { self.setExcerptAutoPushEnabled($0) })
    }
    var excerptAutoPushMinutesBinding: Binding<Double> {
        Binding(get: { Double(self.settings.excerptAutoPushMinutes) },
                set: { self.settings.excerptAutoPushMinutes = Int($0.rounded()) })
    }
    var excerptBoardRotationEnabledBinding: Binding<Bool> {
        Binding(get: { self.settings.excerptBoardRotationEnabled },
                set: { self.setExcerptBoardRotationEnabled($0) })
    }
    var excerptBoardRotationMinutesBinding: Binding<Double> {
        Binding(get: { Double(self.settings.excerptBoardRotationMinutes) },
                set: { self.settings.excerptBoardRotationMinutes = Int($0.rounded()) })
    }
    var startWithSystemBinding: Binding<Bool> {
        Binding(get: { self.settings.startWithSystem },
                set: { self.setStartWithSystem($0) })
    }
    var lingxi68KnobPagingBinding: Binding<Bool> {
        Binding(get: { self.settings.lingxi68KnobPagingEnabled },
                set: { self.setLingxi68KnobPagingEnabled($0) })
    }
    var themeBinding: Binding<CardTheme> {
        Binding(get: { self.settings.cardTheme }, set: { self.setTheme($0) })
    }
    var refreshIntervalBinding: Binding<Int> {
        Binding(get: { self.settings.codexRefreshSeconds },
                set: { self.settings.codexRefreshSeconds = $0 })
    }
    var focusMinutesBinding: Binding<Int> {
        Binding(get: { self.pomodoroState.focusMinutes }, set: { self.setFocusMinutes($0) })
    }
    var shortBreakMinutesBinding: Binding<Int> {
        Binding(get: { self.pomodoroState.shortBreakMinutes }, set: { self.setShortBreakMinutes($0) })
    }
    var longBreakMinutesBinding: Binding<Int> {
        Binding(get: { self.pomodoroState.longBreakMinutes }, set: { self.setLongBreakMinutes($0) })
    }
}
