import AppKit
import LinxDisplayCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 面板类型

enum Panel: String, CaseIterable, Identifiable, Hashable {
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
    case devices
    case buttonControl
    case cardRotation
    case oracleCanvas
    case excerptCanvas
    case general

    var id: String { rawValue }

    /// 主导航项（外观与设置置于底部）
    static var mainItems: [Panel] {
        [.qwenWork, .codex, .pomodoro, .system, .nowPlaying, .customImage, .canvas,
         .excerptQuote, .sspai, .emojiWallpaper, .devices, .oracleCanvas, .excerptCanvas]
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
        }
    }

    var title: String {
        switch self {
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
        case .devices: return "设备管理"
        case .buttonControl: return "按键控制"
        case .cardRotation: return "卡片管理"
        case .oracleCanvas: return "口袋先知画板"
        case .excerptCanvas: return "摘录画板"
        }
    }

    var icon: String {
        switch self {
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
        case .devices: return "externaldrive"
        case .buttonControl: return "appletvremote.gen4"
        case .cardRotation: return "tray.full"
        case .oracleCanvas: return "sparkles"
        case .excerptCanvas: return "quote.opening"
        }
    }

    /// 选择该面板时对应的显示模式（设置/外观/设备管理/按键控制/独立画板无对应键盘显示模式）
    var displayMode: DisplayMode? {
        switch self {
        case .general, .appearance: return nil
        case .oracleCanvas, .excerptCanvas, .devices, .buttonControl, .cardRotation: return nil
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

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var sidebarVisible = true
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
    /// 设备连接字段的输入草稿（填写后需点「应用」才生效，避免输入中途被误用/误改）
    /// 键为「设备ID#字段名」复合键：同一设备可能有多个连接字段（摘录的 API Key 与序列号），
    /// 共用一个草稿槽会导致两个输入框互相串内容
    @State private var connectionDrafts: [String: String] = [:]
    /// 口袋先知多画板拖拽排序状态（拖动中仅更新本地列表，松手统一提交）
    @State private var draggedBoard: OracleCanvasBoard?
    @State private var dragBoards: [OracleCanvasBoard]?
    /// 待删除的设备（非 nil 时弹出二次确认）
    @State private var deviceToDelete: ManagedDevice?
    /// 待重命名的先知画板（非 nil 时弹出重命名输入框）
    @State private var boardRenameTarget: OracleCanvasBoard?
    @State private var boardRenameDraft = ""

    init(model: AppModel) {
        self.model = model
        // 首次使用（无任何设备）直接进入设备管理引导添加设备；已有设备时跟随当前显示模式
        if model.settings.devices.isEmpty {
            _selected = State(initialValue: .devices)
        } else {
            _selected = State(initialValue: Panel.from(displayMode: model.settings.displayMode) ?? .general)
        }
    }

    var body: some View {
        mainContent
    }

    /// 独立设备画板页面（口袋先知/摘录）自带宽幅设备预览，隐藏键盘小屏实时预览
    private var isDeviceCanvasPanel: Bool {
        selected == .oracleCanvas || selected == .excerptCanvas
    }

    /// 不显示右侧键盘小屏实时预览的面板：两个独立画板（自带设备预览）、设备管理、设置；
    /// 按键控制页只有被控目标是灵犀68 键盘时才显示键盘预览
    private var hidesPreviewPanel: Bool {
        switch selected {
        case .oracleCanvas, .excerptCanvas, .devices, .general:
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
            content(width: geo.size.width)
        }
    }

    /// 自适应宽度布局：窗口变窄时优先压缩左侧导航栏宽度（压缩到仅剩图标条为止），
    /// 导航栏压到最小后详情内容仍放不下时，才由详情滚动区提供横向滚动条。
    private func content(width windowWidth: CGFloat) -> some View {
        // 详情区理想宽度：两个独立画板为双栏（主内容 + 右侧边栏），其余面板取最小列宽 380
        let centerIdeal: CGFloat = isDeviceCanvasPanel ? 620 : 380
        let previewWidth: CGFloat = hidesPreviewPanel ? 0 : 210
        let sidebarBudget = windowWidth - centerIdeal - previewWidth - 8
        let effectiveSidebar = min(CGFloat(model.settings.sidebarWidth), max(48, sidebarBudget))
        let useMiniSidebar = effectiveSidebar <= 96
        return HStack(spacing: 0) {
            if sidebarVisible {
                if useMiniSidebar {
                    // 已压缩到仅剩图标条：窄图标栏（选项卡图标 + 正在播放封面）
                    MiniSidebar(selection: $selected, model: model)
                        .transition(.move(edge: .leading))
                        .zIndex(1)
                } else {
                    Sidebar(selection: $selected, sidebarVisible: $sidebarVisible, model: model)
                        .frame(width: effectiveSidebar)
                        .transition(.move(edge: .leading))
                        .zIndex(1) // 导航栏层级最高：详情内容再宽也不会盖住导航栏
                    SidebarResizeHandle(model: model)
                        .zIndex(1)
                }
            } else {
                // 收起态：保留最窄一条图标栏（选项卡快速切换 + 正在播放封面点击跳转）
                MiniSidebar(selection: $selected, model: model)
                    .zIndex(1)
            }

            VStack(spacing: 0) {
                headerBar
                Divider()
                // 两个独立画板均为双栏（主内容 + 右侧边栏）：窗口自动放大容纳，保持纯纵向滚动
                // （横向滚动会干扰右侧边栏 TextField 的键盘焦点：Cmd+V/Tab 失效）
                ScrollView([.vertical]) {
                    if model.settings.devices.isEmpty && !worksWithoutDevices(selected) {
                        emptyDevicesOnboarding
                    } else if selected == .excerptCanvas {
                        excerptCanvasForm // 摘录画板：主内容 + 右侧设备边栏两栏布局
                    } else if selected == .oracleCanvas {
                        oracleCanvasForm // 口袋先知画板：主内容 + 右侧预览边栏两栏布局
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
            .frame(minWidth: 380)

            if !hidesPreviewPanel {
                Divider()

                PreviewPanel(model: model)
                    .frame(width: 210)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
        .onChange(of: selected) { newValue in
            if let mode = newValue.displayMode {
                model.setMode(mode)
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

    // MARK: 顶部栏（折叠侧栏按钮 + 标题 + 状态）

    private var headerBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    sidebarVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(sidebarVisible ? "折叠侧边栏" : "展开侧边栏")

            Text(model.settings.devices.isEmpty && !worksWithoutDevices(selected)
                 ? "开始使用" : selected.title)
                .font(.headline)

            Spacer()

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14) // 沉浸式标题栏留白
        .padding(.bottom, 8)
    }

    // MARK: 各面板内容

    @ViewBuilder
    private func panelContent(for panel: Panel) -> some View {
        switch panel {
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
        case .devices: devicesForm
        case .buttonControl: buttonControlForm
        case .cardRotation: cardRotationForm
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
        let draftKey = "\(deviceID.uuidString)#\(label)"
        HStack(spacing: 6) {
            TextField(label, text: Binding(
                get: { self.connectionDrafts[draftKey] ?? binding.wrappedValue },
                set: { self.connectionDrafts[draftKey] = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(width: fieldWidth)
            Button("应用") {
                binding.wrappedValue = self.connectionDrafts[draftKey] ?? ""
                self.connectionDrafts[draftKey] = nil
            }
            .controlSize(.small)
            .disabled((self.connectionDrafts[draftKey] ?? binding.wrappedValue)
                      == binding.wrappedValue)
            .help("确认并应用此连接信息")
            if let helpText, let helpURL {
                Button {
                    NSWorkspace.shared.open(helpURL)
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(helpText)
            }
        }
    }

    /// 口袋先知按键控制页：配置当前口袋先知设备的按键控制目标
    /// （跟随侧栏选中的先知设备，每台先知设备各自记住）
    private var buttonControlForm: some View {
        Group {
            Section("口袋先知设备") {
                LabeledContent("设备",
                               value: model.activeDevice(for: .oracle)?.name ?? "未设置")
            }
            Section("按键控制") {
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
            }
            Section {
                Text("口袋先知设备按键（短按）控制所选目标：控制自身时下键手动更新画布（保存了多块画板时上下键在画板间循环切换并推送）；控制灵犀68 键盘时上下键翻页；控制摘录时下键切换到 Dot 云端内容下一项、上键推送本地摘录画板。每台先知设备各自记住自己的控制目标。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { model.ensureRand0Session() }
    }

    /// 设备管理页面：多台 灵犀68/口袋先知/摘录 设备的添加、重命名、删除与活动设备切换；
    /// 每台设备独立记住连接信息与画板设置
    private var devicesForm: some View {
        Group {
            ForEach(DeviceType.allCases) { type in
                Section {
                    ForEach(model.devices(for: type)) { device in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("设备名称", text: model.deviceNameBinding(for: device.id))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 320)
                            }
                            .opacity(device.isEnabled ? 1 : 0.5)
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
                            .opacity(device.isEnabled ? 1 : 0.5)
                            // 启用/停用开关：独立位置（禁用后左侧导航隐藏该设备，设置保留）
                            Toggle("启用设备", isOn: model.deviceEnabledBinding(for: device.id))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .help("禁用后左侧导航隐藏该设备，设置保留")
                            // 删除设备：独立按钮，删除前二次确认
                            Button(role: .destructive) {
                                deviceToDelete = device
                            } label: {
                                Label("删除设备", systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help("删除该设备")
                        }
                        .padding(.vertical, 2)
                    }
                    Button("添加 \(type.title) 设备") {
                        model.addDevice(type: type)
                    }
                } header: {
                    Text(type.title)
                }
            }
            Section {
                Text("键盘与口袋先知只需填写 IP 地址（键盘会自动补全推送地址 http://IP/image/upload），摘录需 API Key 与设备序列号。连接信息填写后需点「应用」才生效；每台设备独立记录连接与画板设置，切换设备后恢复该设备之前的设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    model.removeDevice(id: device.id)
                }
                deviceToDelete = nil
            }
            Button("取消", role: .cancel) {
                deviceToDelete = nil
            }
        }
    }

    /// 卡片轮换（键盘功能设置）：开关、间隔与轮换卡片内容排序（按键盘设备独立记录）
    private var cardRotationForm: some View {
        Group {
            Section("自动轮播") {
                Toggle("卡片页面自动轮播", isOn: model.cardRotationEnabledBinding)
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
                        Text("范围 1 分钟–1 小时；到点后在键盘上循环切换已加入自动循环的卡片。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("卡片（拖拽排序）") {
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
                Text("拖动排序决定侧栏顺序与自动轮播顺序；「侧栏」关闭后该卡片不在侧栏显示，「轮换」开启后该卡片参与自动轮播。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
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
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section {
                Text("卡片管理是灵犀68 键盘的功能：管理各卡片在侧栏的显示、自动轮播的参与与顺序，每台键盘设备独立记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 卡片管理列表中的一行：拖拽排序 + 侧栏显示开关 + 加入自动循环开关（开关固定列宽右对齐）
    private func cardManagementRow(_ panel: Panel) -> some View {
        let inRotation = panel.displayMode.map { model.settings.cardRotationModes.contains($0.rawValue) } ?? false
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Image(systemName: panel.icon)
                .font(.system(size: 12))
                .frame(width: 16)
            Text(panel.title)
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
                               available: CanvasModule.keyboardModules)
            Section {
                Text("模块自上而下排列成一张卡片，模块越多每块越紧凑。带设置项的模块展开其右侧箭头即可调整；右侧可实时预览，组合满意后按「立即推送」发到键盘。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                    if model.quoteOverrideIndex != nil {
                        Button("恢复自动轮换") {
                            model.resetQuoteRotation()
                        }
                    }
                }
                Text("语录每分钟自动轮换；切到本页即推送到键盘，之后语录变化时更新。手动「切换到下一条」会暂时固定展示所选语录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text("Emoji 表情")
                    TextField("输入要用作壁纸的 emoji，如 🌈🌟🦄", text: model.emojiWallpaperTextBinding,
                              prompt: Text("输入 emoji"))
                        .textFieldStyle(.roundedBorder)
                    Text("多个 emoji 会循环重复排列，铺满整个键盘屏幕。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("排列方式", selection: model.emojiWallpaperLayoutBinding) {
                    ForEach(EmojiWallpaperLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                Text(model.settings.emojiWallpaperLayout.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("大小与间隔") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Emoji 大小")
                        Spacer()
                        Text("\(model.settings.emojiWallpaperSize) px")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.emojiWallpaperSizeBinding, in: 16...96, step: 2)
                    Text("越大单个表情越大、铺满所需数量越少；越小越密集。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("表情间隔")
                        Spacer()
                        Text("\(model.settings.emojiWallpaperSpacing) px")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.emojiWallpaperSpacingBinding, in: 0...40, step: 2)
                    Text("控制表情之间的空隙；0 为紧挨着排列。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("显示底部时间", isOn: model.nowPlayingFooterVisibleBinding)
            }
        }
    }

    /// 少数派推荐键盘卡片页面：显示编辑推荐的最新文章（点击标题跳转网页），可手动刷新/调节刷新周期
    private var sspaiForm: some View {
        Group {
            Section {
                Text("推送到键盘的少数派推荐卡片最多显示三条内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Button("刷新推荐") {
                    Task { await model.refresh() }
                }
            }
            Section("推送") {
                Toggle("文章多于三条时，进入本页随机推送三条到键盘", isOn: model.sspaiRandomPushBinding)
                Text("开启后每次进入本页都会重新随机抽取三条推荐内容推送到键盘（文章不超过三条时按全部推送）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("刷新周期") {
                Stepper("\(model.settings.sspaiRefreshMinutes) 分钟",
                        value: model.sspaiRefreshMinutesBinding, in: 5...240, step: 5)
                Text("到点自动重新抓取编辑推荐文章并推送到键盘（内容变化时才会推送）；点击标题可在浏览器打开原文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if model.settings.sspaiRandomPush {
                Task { await model.enterSspaiPage() }
            }
        }
    }

    /// 画板模块组合编辑器（键盘画板与两个独立设备画板共用）
    @ViewBuilder
    private func canvasModuleEditor(owner: AppModel.CanvasOwner,
                                    modulesRaw: [Int],
                                    moduleList: [CanvasModule],
                                    available: [CanvasModule],
                                    showFullWidthToggle: Bool = false) -> some View {
        Section("当前组合（自上而下）") {
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
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Image(systemName: module.icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(module.title)
                Spacer()
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
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expandedModule = expandedModule == module ? nil : module
                        }
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
            if expandedModule == module {
                canvasModuleSettings(module, owner: owner)
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
                Text(module.title)
                Spacer()
                Image(systemName: "plus.circle")
                    .foregroundStyle(modulesRaw.contains(module.rawValue)
                                     ? Color.secondary : Color.accentColor)
            }
        }
        .buttonStyle(.plain)
        .disabled(modulesRaw.contains(module.rawValue))
    }

    /// 口袋先知画板：主内容（显示设置 / 模块组合 / Rand/0 设备 / 自动推送）
    /// + 右侧预览边栏（处理前 / 处理后 纵向排列）
    private var oracleCanvasForm: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧主内容
            Form {
                Section("画板") {
                    if model.settings.oracleCanvasBoards.isEmpty {
                        Text("当前为默认画布。可把常用配置保存为多块画板，按键控制目标为自身时，设备上下键在多块画板间循环切换并推送。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        reorderList(items: model.settings.oracleCanvasBoards,
                                    dragged: $draggedBoard,
                                    dragItems: $dragBoards,
                                    commit: { model.commitOracleCanvasBoards($0) }) { board in
                            oracleCanvasBoardRow(board)
                        }
                    }
                    Button("将当前配置保存为新画板") {
                        model.addOracleCanvasBoard()
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
                            HelpIcon(text: "将画面直接旋转 180°，适配设备安装方向；不会产生镜像。")
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
                canvasModuleEditor(owner: .oracle,
                                   modulesRaw: model.settings.oracleCanvasModules,
                                   moduleList: dragModules ?? model.settings.oracleCanvasModuleList,
                                   available: CanvasModule.oraclePanelModules)
                Section {
                    Text("设备 IP 地址与按键控制设备请在「设备管理」中按设备设置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("推送到 Rand/0 设备") {
                        Task { await model.pushOracleCanvas() }
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
                        HelpIcon(text: "通过局域网 WebSocket（ws://<IP>/display/bw 或 /display/gray4）把图像推送到 Rand/0 墨水屏，发送即显示、无需在设备上按键刷新。保持连接时设备按键信号会回传给软件，可在「设备管理」中配置每台先知设备按键控制的目标（自身更新画布 / 灵犀68 键盘翻页 / 摘录切换语录）。请确认设备在线且与电脑在同一局域网。")
                    }
                }
                Section("自动推送") {
                    Toggle(isOn: model.oracleAutoPushEnabledBinding) {
                        HStack(spacing: 4) {
                            Text("自动推送画布")
                            HelpIcon(text: "开启后立即推送一次；之后内容变化（专辑封面、时间等）时立即推送，无变化则按间隔推送。")
                        }
                    }
                    if model.settings.oracleAutoPushEnabled {
                        Stepper("推送间隔 \(model.settings.oracleAutoPushMinutes) 分钟",
                                value: model.oracleAutoPushMinutesBinding, in: 1...1440)
                    }
                }
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

    /// 摘录画板：主内容（画板预览 / 显示设置 / 模块组合）+ 右侧设备边栏（Dot 设备 / 自动推送）
    private var excerptCanvasForm: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧主内容
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
                        HelpIcon(text: "上下两图均为设备效果图：画布按 296×152 与设备屏幕显示范围 1:1 对齐叠加；上方为灰阶/抖动处理前的彩色原始渲染，下方为处理后的实际效果。")
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
                }
                canvasModuleEditor(owner: .excerpt,
                                   modulesRaw: model.settings.excerptCanvasModules,
                                   moduleList: dragModules ?? model.settings.excerptCanvasModuleList,
                                   available: CanvasModule.excerptPanelModules,
                                   showFullWidthToggle: model.settings.excerptLayoutColumns == 2)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 720, alignment: .topLeading)

            Divider()
                .padding(.vertical, 4)

            // 右侧设备边栏：Dot 设备推送 + 自动推送
            Form {
                Section {
                    HStack(spacing: 4) {
                        Text("API Key 与序列号请在「设备管理」的摘录设备中设置。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle(isOn: model.excerptPushRawImageBinding) {
                        HStack(spacing: 4) {
                            Text("推送原始彩色图片")
                            HelpIcon(text: "开启后直接推送灰阶/抖动处理前的彩色原图，由 Dot 服务端按所选抖动方式/抖动核自行转换（官方 ditherType/ditherKernel）；关闭时使用本地 4 级灰阶 + 抖动处理后的画面（ditherType=NONE）。")
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
                        Text("按官方指南传 ditherType 与 ditherKernel，由服务端完成灰度量化与抖动，软件端无需本地处理。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("推送到 Dot 设备") {
                        Task { await model.pushExcerptCanvas() }
                    }
                    Button("查询设备状态") {
                        Task { await model.checkDotDeviceStatus() }
                    }
                    .controlSize(.small)
                    if !model.dotDeviceStatusText.isEmpty {
                        Text(model.dotDeviceStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("Dot 设备")
                        HelpIcon(text: "通过 dot.mindreset.tech 图像接口把卡片推送到 Dot 墨水屏。需先在 Dot App 的 Content Studio 中加入 Image API 内容；设备离线或休眠时，内容会在下次刷新时显示。")
                    }
                }
                Section("自动推送") {
                    Toggle(isOn: model.excerptAutoPushEnabledBinding) {
                        HStack(spacing: 4) {
                            Text("自动推送画布")
                            HelpIcon(text: "开启后立即推送一次；之后内容变化（专辑封面、时间等）时立即推送，无变化则按间隔推送。")
                        }
                    }
                    if model.settings.excerptAutoPushEnabled {
                        Stepper("推送间隔 \(model.settings.excerptAutoPushMinutes) 分钟",
                                value: model.excerptAutoPushMinutesBinding, in: 1...1440)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 310, maxWidth: .infinity, alignment: .top)
        }
        .padding(.bottom, 12)
        .onAppear { model.refreshExcerptCanvasPreview() }
        .task { await model.checkDotDeviceStatus() }
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

    /// 模块上下边距（紧凑度）滑杆绑定
    private func canvasMarginBinding(for module: CanvasModule) -> Binding<Double> {
        Binding(
            get: { Double(self.model.settings.canvasMargin(for: module)) },
            set: { self.model.settings.setCanvasMargin(Int($0), for: module) }
        )
    }

    /// 墨水屏画板「正在播放」横向排布开关绑定（先知/摘录各持独立设置）
    private func nowPlayingHorizontalBinding(for owner: AppModel.CanvasOwner) -> Binding<Bool> {
        switch owner {
        case .keyboard: return Binding(get: { false }, set: { _ in })
        case .oracle: return model.oracleNowPlayingHorizontalBinding
        case .excerpt: return model.excerptNowPlayingHorizontalBinding
        }
    }

    /// 模块行内展开的设置内容
    @ViewBuilder
    private func canvasModuleSettings(_ module: CanvasModule, owner: AppModel.CanvasOwner) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("上下边距")
                    Spacer()
                    Text("\(model.settings.canvasMargin(for: module))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: canvasMarginBinding(for: module), in: 0...40, step: 1)
                Text("数值越大该模块越紧凑，模块之间排布越密集。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch module {
            case .clock:
                TextField("时钟格式", text: model.canvasClockFormatBinding)
                    .textFieldStyle(.roundedBorder)
                Text("DateFormatter 模式，如 HH:mm / hh:mm / HH:mm:ss")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .date:
                TextField("日期格式", text: model.canvasDateFormatBinding)
                    .textFieldStyle(.roundedBorder)
                Text("如 yyyy年M月d日 EEE / M/d / yyyy-MM-dd")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .text:
                TextField("画板文字", text: model.canvasTextBinding)
                    .textFieldStyle(.roundedBorder)
            case .nowPlaying:
                Toggle("大尺寸专辑封面", isOn: model.canvasNowPlayingCoverBinding)
                // 智能封面取色背景：仅键盘画板使用（整卡背景替换为封面主色）；
                // 墨水屏画板（先知/摘录）不使用智能取色，保持手动底色
                if owner == .keyboard {
                    Toggle("智能封面取色背景", isOn: model.canvasNowPlayingSmartBgBinding)
                    Text("智能背景使用专辑封面主色替换整张画板背景色调，并自动配置可读的文字颜色。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("横向排布（封面在左）", isOn: nowPlayingHorizontalBinding(for: owner))
                    Text("开启后封面居左、歌名歌手居右；关闭为竖向大封面（封面在上、文字在下）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("歌名字号")
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
                    Text("画板内「正在播放」模块字号；超宽时自动收缩以保证显示完整。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .image:
                if owner == .keyboard {
                    Picker("图像模式", selection: model.canvasImageModeBinding) {
                        ForEach(CanvasImageMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text("背景：完整显示作为底层，其他模块叠加其上（自动加深）。叠加：作为一个模块显示。「自定义图片」中选择的图片即为此模块使用的图片。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("选择图片…") { Task { await model.pickCanvasImage(for: owner) } }
                        Spacer()
                        Text(model.canvasImageName(for: owner) ?? "未选择")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("为该画板独立选择图片（与键盘自定义图片互不影响），可随时替换；图片模块固定作为模块叠加显示。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .sspai:
                Stepper("显示 \(model.sspaiCount(for: owner)) 条",
                        value: model.sspaiCountBinding(for: owner), in: 1...6)
                Toggle("随机显示", isOn: model.sspaiRandomBinding(for: owner))
                Text("抓取到的文章多于显示条数时，勾选后每次刷新随机挑一批显示；不勾选固定显示最新几篇。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
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
                Text("推送到键盘的「正在播放」卡片字号；超宽时自动收缩以保证显示完整。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: model.nowPlayingFooterVisibleBinding) {
                HStack(spacing: 4) {
                    Text("显示底部时间日期")
                    HelpIcon(text: "关闭后底部时间/日期隐藏：专辑封面垂直居中，歌名/进度条信息贴到底部并保留安全区。")
                }
            }
            if model.settings.nowPlayingFooterVisible {
                TextField("时间格式", text: model.nowPlayingTimeFormatBinding)
                    .textFieldStyle(.roundedBorder)
                TextField("日期格式", text: model.nowPlayingDateFormatBinding)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 4) {
                    Text("DateFormatter 模式，如 HH:mm / M月d日 / yyyy年M月d日 EEE")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("时间字号")
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
            Button("刷新") {
                Task { await model.refresh() }
            }
            Text("数据来自系统「正在播放」，支持音乐、浏览器、Spotify 等播放器。封面主色会自动用作卡片背景。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var appearanceForm: some View {
        Section {
            Picker("软件明暗模式", selection: model.appearanceBinding) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text("控制软件窗口界面（菜单、面板、预览区域）的明暗显示：跟随系统 / 浅色 / 深色。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("卡片外观") {
            Picker("卡片主题", selection: model.themeBinding) {
                ForEach(CardTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            Picker("背景底色", selection: model.backgroundToneBinding) {
                ForEach(BackgroundTone.allCases) { tone in
                    Text(tone.title).tag(tone)
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
            HStack(spacing: 4) {
                Text("卡片主题决定强调色基调（「跟随主题」时生效）；背景底色「跟随软件明暗」随上方软件明暗切换深浅。以上均作用于推送到键盘的卡片画面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var generalForm: some View {
        Group {
        Section {
            Text("键盘 IP 地址等设备连接信息请在「设备管理」中按设备设置。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("灵犀68 屏幕控制") {
            Text("以下选项仅适用于灵犀68 键盘，不影响口袋先知与摘录。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("菜单栏切换目标键盘", selection: model.menuBarTargetBinding()) {
                Text("跟随当前活动键盘").tag("follow")
                ForEach(model.enabledDevices(for: .keyboard)) { device in
                    Text(device.name).tag("kb:\(device.id.uuidString)")
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
                    Spacer()
                    Text("\(model.settings.jpegQuality)%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: model.qualityBinding, in: 50...100, step: 1)
                Text("100% 为 4:4:4 无彩色抽样，画质接近无损；越低文件越小、压缩痕迹越明显。键盘仅支持 JPEG 格式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Section("系统权限") {
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
            Text("全局快捷键：⌃⌥Space 开始/暂停 · ⌃⌥→ 跳过 · ⌃⌥⌫ 重置。快捷键在系统范围内生效，无需额外权限。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("应用", value: "多屏灵犀（Lingxi MultiScreen）")
            LabeledContent("版本", value: ReleaseNotes.currentVersion)
            LabeledContent("系统要求", value: "macOS 14+ · Apple 芯片")
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
        Section("版本更新日志") {
            ForEach(ReleaseNotes.all) { note in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("v\(note.id)")
                            .font(.headline)
                        Text(note.date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    ForEach(note.notes, id: \.self) { item in
                        Text("· \(item)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            Text("更新日志随新版本发布在本页追加；最新版本号以「关于」中的版本为准。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        }
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
            LabeledContent("剩余额度", value: model.qwenQuotaText)
            LabeledContent("剩余百分比", value: model.qwenQuotaPercentText)
            LabeledContent("百分比基线", value: model.quotaBaselineText)
            Button("将当前额度设为 100% 基线") {
                model.captureQuotaBaseline()
            }
            Text("额度百分比按「当前剩余 ÷ 基线」计算：先点上方按钮把当前额度记为 100%，之后额度减少时自动计算剩余百分比；额度充值后可重新设置基线。")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("最后采样", value: Self.formatSample(model.qwenQuota.sampledAt))
            Text("额度数据来自本机千问办公客户端（本地服务），请保持千问办公运行。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var codexForm: some View {
        Section {
            TextField("Codex CLI 路径（可选）", text: model.codexCliPathBinding)
                .textFieldStyle(.roundedBorder)
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
                Text("剩余 \(model.usage.remainingPercent)% · 可用重置 \(model.usage.availableResetCount) 次")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var pomodoroForm: some View {
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
            Toggle("每完成一个时间段进行夸夸", isOn: model.pomodoroPraiseEnabledBinding)
            if model.settings.pomodoroPraiseEnabled {
                Picker("内容来源", selection: model.pomodoroPraiseSourceBinding) {
                    ForEach(PraiseSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                Text("任何界面下，每完成一个时间阶段都会显示夸夸内容约 12 秒，然后恢复正常卡片。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var systemForm: some View {
        Section {
            Stepper("推送周期 \(model.settings.dynamicUploadSeconds) 秒",
                    value: model.dynamicUploadBinding, in: 2...60)
            Toggle("显示 CPU", isOn: model.showCpuBinding)
            Toggle("显示内存", isOn: model.showMemoryBinding)
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
                Spacer()
                Text(model.customImageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("图片会自动居中裁切为 142×428，顶部保留安全区（44–80px）。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("时钟叠加", selection: model.customImageClockBinding) {
                ForEach(CustomImageClockOverlay.allCases) { overlay in
                    Text(overlay.title).tag(overlay)
                }
            }
            Text("叠加时钟跟随系统时间，每分钟自动刷新推送；不叠加则保持静态图片。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.settings.customImageClock != .none {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("时钟字号")
                        Spacer()
                        Text("\(model.settings.clockFontSize) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.clockFontSizeBinding, in: 18...56, step: 1)
                }
                Picker("字体粗细", selection: model.clockFontWeightBinding) {
                    ForEach(ClockFontWeight.allCases) { weight in
                        Text(weight.title).tag(weight)
                    }
                }
                Text("Pixel 锁屏风格数字；竖向布局为第一行小时、第二行分钟，每行两位数字横向排布。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("时间格式", selection: model.clockFormatPresetBinding) {
                    Text("24 小时 · HH:mm").tag(0)
                    Text("24 小时 · H:mm").tag(1)
                    Text("24 小时 · HH:mm:ss").tag(2)
                    Text("12 小时 · hh:mm").tag(3)
                    Text("自定义…").tag(4)
                }
                if model.clockFormatPresetBinding.wrappedValue == 4 {
                    TextField("自定义格式", text: model.clockTimeFormatBinding)
                        .textFieldStyle(.roundedBorder)
                    Text("可用符号：HH 两位小时 · H 小时 · hh 12 小时 · mm 分 · ss 秒 · a 上午/下午")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.settings.clockTimeFormat.contains("s") {
                    Text("格式含秒时将按秒刷新推送。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        Spacer()
                        Text(RotationInterval.label(forSeconds: model.settings.imageRotationSeconds))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: model.imageRotationSliderBinding, in: 0...1)
                    Text("范围 5 秒–5 分钟；滑杆非线性，时间越长档位越粗。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

/// 感叹号提示图标：点击弹出注释（替代长段 caption 文字，节省页面空间）
struct HelpIcon: View {
    let text: String
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
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
    @Binding var sidebarVisible: Bool
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
                        ForEach(model.enabledDevices(for: .keyboard)) { device in
                            deviceInstanceGroup(icon: "keyboard", title: device.name,
                                                isExpanded: deviceExpandedBinding(device.id),
                                                panels: keyboardPanels(for: device.id),
                                                switchType: .keyboard, deviceID: device.id,
                                                emptyHint: keyboardHasNoCards(device.id) ? "尚未添加卡片，去卡片管理添加" : nil)
                        }
                        ForEach(model.enabledDevices(for: .oracle)) { device in
                            deviceInstanceGroup(icon: "sparkles", title: device.name,
                                                isExpanded: deviceExpandedBinding(device.id),
                                                panels: [.oracleCanvas, .buttonControl],
                                                switchType: .oracle, deviceID: device.id)
                        }
                        ForEach(model.enabledDevices(for: .excerpt)) { device in
                            deviceInstanceGroup(icon: "quote.opening", title: device.name,
                                                isExpanded: deviceExpandedBinding(device.id),
                                                panels: [.excerptCanvas],
                                                switchType: .excerpt, deviceID: device.id)
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
        .padding(.top, 14) // 与中栏 headerBar 顶部内边距一致，保证「自动轮播」下分隔线与头部分隔线对齐
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
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
    /// 点击任意功能项先切到这台设备再打开对应页面
    private func deviceInstanceGroup(icon: String, title: String, isExpanded: Binding<Bool>,
                                     panels: [Panel], switchType: DeviceType?, deviceID: UUID?,
                                     emptyHint: String? = nil) -> some View {
        return DisclosureGroup(isExpanded: isExpanded) {
            ForEach(panels) { panel in
                if panel == .cardRotation, switchType == .keyboard, let deviceID {
                    cardRotationRow(deviceID)
                } else {
                    sidebarRow(panel, switchingTo: switchType, deviceID: deviceID)
                }
            }
            if let emptyHint {
                Button {
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
            }
        } label: {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .frame(width: 18, height: 18)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
    }

    /// 「卡片轮换」行：左侧打开轮换设置页，右侧是该键盘设备的自动轮播开关
    private func cardRotationRow(_ deviceID: UUID) -> some View {
        let rotationOn = model.settings.devices.first(where: { $0.id == deviceID })?
            .settings.cardRotationEnabled ?? false
        return HStack(spacing: 8) {
            Button {
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
                            Circle()
                                .fill(Color(nsColor: glow))
                                .frame(width: 144, height: 144)
                                .blur(radius: 48)
                                .opacity(isSelected ? 1.0 : 0.5)
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
            }
            selection = panel
        } label: {
            HStack(spacing: 8) {
                Image(systemName: panel.icon)
                    .frame(width: 18, height: 18)
                Text(panel.title)
                    .lineLimit(1)
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

    private let railWidth: CGFloat = 48

    var body: some View {
        VStack(spacing: 2) {
            // 设备图标：每类设备一个入口（点击进入对应画板），不展示具体设备功能；
            // 该类型全部设备被禁用时隐藏对应图标
            if !model.enabledDevices(for: .keyboard).isEmpty {
                deviceIconButton(icon: "keyboard", title: "灵犀68 键盘", panel: .canvas)
            }
            if !model.enabledDevices(for: .oracle).isEmpty {
                deviceIconButton(icon: "sparkles", title: "口袋先知", panel: .oracleCanvas)
            }
            if !model.enabledDevices(for: .excerpt).isEmpty {
                deviceIconButton(icon: "quote.opening", title: "摘录", panel: .excerptCanvas)
            }
            Spacer(minLength: 0)
            // 正在播放：专辑封面（点击跳转到正在播放页）
            Button {
                selection = .nowPlaying
            } label: {
                ZStack {
                    // 选中态用光斑增亮表达，不再需要高亮描边；浅色模式下不显示光晕
                    if let glow = model.sidebarArtworkGlow, model.settings.softwareIsDark {
                        Circle()
                            .fill(Color(nsColor: glow))
                            .frame(width: 88, height: 88)
                            .blur(radius: 32)
                            .opacity(selection == .nowPlaying ? 1.0 : 0.5)
                    }
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
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
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
        .frame(width: railWidth)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
        }
    }

    /// 设备图标按钮：点击进入该设备对应的画板页面
    private func deviceIconButton(icon: String, title: String, panel: Panel) -> some View {
        let isSelected = selection == panel
        return Button {
            selection = panel
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
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
            Image(systemName: panel.icon)
                .font(.system(size: 14, weight: .medium))
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

/// 侧边栏右边缘的拖拽手柄：像调整窗口大小一样，悬停变左右箭头光标，按住拖动调整宽度
struct SidebarResizeHandle: View {
    @ObservedObject var model: AppModel
    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.clear)
            Rectangle()
                .fill(isHovering ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.12))
                .frame(width: 1)
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else if dragStartWidth == nil {
                // 拖拽中不重置光标（防止指针略出手柄区时光标闪回箭头）
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = CGFloat(model.settings.sidebarWidth)
                        model.beginSidebarResize()
                    }
                    let newWidth = (dragStartWidth ?? 168) + value.translation.width
                    model.setSidebarWidth(Int(newWidth))
                }
                .onEnded { _ in
                    dragStartWidth = nil
                    model.finishSidebarResize()
                }
        )
    }
}

// MARK: - 实时预览

struct PreviewPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            Text("实时预览")
                .font(.headline)
            if let image = model.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.quaternary, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    .padding(.horizontal, 8)
            } else {
                ProgressView()
            }
            Text("142 × 428 · JPEG")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("当前模式：\(model.settings.displayMode.title)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 18) // 沉浸式标题栏留白
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
            Text("拖动选择要显示的区域 · 滑动缩放")
                .font(.caption)
                .foregroundStyle(.secondary)
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
    var clockFontSizeBinding: Binding<Double> {
        Binding(get: { Double(self.settings.clockFontSize) },
                set: { self.settings.clockFontSize = Int($0.rounded()) })
    }
    var clockFontWeightBinding: Binding<ClockFontWeight> {
        Binding(get: { self.settings.clockFontWeight },
                set: { self.settings.clockFontWeight = $0 })
    }
    /// 时间格式预设：0=HH:mm 1=H:mm 2=HH:mm:ss 3=hh:mm 4=自定义
    var clockFormatPresetBinding: Binding<Int> {
        Binding(get: {
            switch self.settings.clockTimeFormat {
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
        Binding(get: { self.settings.clockTimeFormat },
                set: { self.setClockTimeFormat($0) })
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
    var canvasClockFormatBinding: Binding<String> {
        Binding(get: { self.settings.canvasClockFormat },
                set: { self.settings.canvasClockFormat = $0 })
    }
    var canvasDateFormatBinding: Binding<String> {
        Binding(get: { self.settings.canvasDateFormat },
                set: { self.settings.canvasDateFormat = $0 })
    }
    var canvasNowPlayingCoverBinding: Binding<Bool> {
        Binding(get: { self.settings.canvasNowPlayingCover },
                set: { self.settings.canvasNowPlayingCover = $0 })
    }
    var canvasNowPlayingSmartBgBinding: Binding<Bool> {
        Binding(get: { self.settings.canvasNowPlayingSmartBg },
                set: { self.settings.canvasNowPlayingSmartBg = $0 })
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
                set: { newValue in
                    switch owner {
                    case .keyboard: self.settings.canvasSspaiCount = newValue
                    case .oracle: self.settings.oracleSspaiCount = newValue
                    case .excerpt: self.settings.excerptSspaiCount = newValue
                    }
                })
    }
    /// 各画板「少数派推荐」随机显示开关绑定（各自独立）
    func sspaiRandomBinding(for owner: CanvasOwner) -> Binding<Bool> {
        Binding(get: { self.sspaiRandomEnabled(for: owner) },
                set: { newValue in
                    switch owner {
                    case .keyboard: self.settings.canvasSspaiRandom = newValue
                    case .oracle: self.settings.oracleSspaiRandom = newValue
                    case .excerpt: self.settings.excerptSspaiRandom = newValue
                    }
                })
    }
    /// 摘录语录分类勾选绑定（多选；取消最后一个分类时由 UI 禁用，防止轮换池为空）
    func excerptQuoteCategoryBinding(for category: ExcerptQuoteCategory) -> Binding<Bool> {
        Binding(get: { self.settings.excerptQuoteCategories.contains(category.rawValue) },
                set: { isOn in self.setExcerptQuoteCategory(category, enabled: isOn) })
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
    var nowPlayingTimeFormatBinding: Binding<String> {
        Binding(get: { self.settings.nowPlayingTimeFormat },
                set: { self.settings.nowPlayingTimeFormat = $0 })
    }
    var nowPlayingDateFormatBinding: Binding<String> {
        Binding(get: { self.settings.nowPlayingDateFormat },
                set: { self.settings.nowPlayingDateFormat = $0 })
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
    var excerptAutoPushEnabledBinding: Binding<Bool> {
        Binding(get: { self.settings.excerptAutoPushEnabled },
                set: { self.setExcerptAutoPushEnabled($0) })
    }
    var excerptAutoPushMinutesBinding: Binding<Double> {
        Binding(get: { Double(self.settings.excerptAutoPushMinutes) },
                set: { self.settings.excerptAutoPushMinutes = Int($0.rounded()) })
    }
    var startWithSystemBinding: Binding<Bool> {
        Binding(get: { self.settings.startWithSystem },
                set: { self.setStartWithSystem($0) })
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
