import AppKit
import LinxDisplayCore
import SwiftUI

/// 主面板的操作全部位于内容区标题栏，不使用 AppKit 窗口工具栏。
///
/// macOS 27 会在 `NavigationSplitView` 收起侧栏时重新安装一个空工具栏；
/// 即使 SwiftUI 已移除 `.sidebarToggle` 并隐藏 `windowToolbar`，仍可能留下
/// “更多工具栏项目”的双箭头入口。窗口级拒绝安装工具栏可让展开/收起始终
/// 只经过内容区的单个按钮，同时保留标准标题栏、红绿灯与窗口拖动行为。
private final class ToolbarlessMainWindow: NSWindow {
    override var toolbar: NSToolbar? {
        get { nil }
        set { super.toolbar = nil }
    }
}

/// 手动 AppKit 引导（SPM 可执行环境下 SwiftUI @main 场景不可靠）：
/// NSStatusItem 提供菜单栏常驻图标（右键快速切换显示模式、番茄钟子菜单），
/// NSHostingView 承载 SwiftUI 主面板。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private var windowController: NSWindowController?
    private var pomodoroSubmenu: NSMenu?
    private var deviceMenuEntries: [NSMenuItem] = []
    private var previewViews: [NSMenu: MenuBarScreenPreview] = [:]
    private var previewTargets: [NSMenuItem: MenuBarPreviewTarget] = [:]
    private var previewCache: [MenuBarPreviewTarget: NSImage] = [:]
    private var previewTimer: Timer?
    private var workspaceDisplayObservers: [NSObjectProtocol] = []
    private var distributedDisplayObservers: [NSObjectProtocol] = []
    private var awtrixQuitRestorePending = false

    private enum AWTRIXMenuAction {
        case showCard(UUID, String)
        case toggleRotation(UUID)
        case move(UUID, next: Bool)
        case refresh(UUID)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        model.onAppearanceChanged = { [weak self] in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
        setupMenuBar()
        setupEditMenu() // 菜单栏应用没有默认编辑菜单，Cmd+C/V/X 等快捷键依赖它
        installHotkeys()
        installAIMacSystemDisplayObservers()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let model = self?.model else { return }
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
            await model.reconcileAIMacPowerAfterLaunch(systemLocked: locked)
        }
        openMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 挂载标准「编辑」菜单（LSUIElement 应用无系统菜单栏，若不挂载，
    /// 文本框的 Cmd+C/V/X/全选等快捷键将失效；菜单不显示但 keyEquivalent 仍路由）
    private func setupEditMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // 关闭窗口后继续在菜单栏运行
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard model.hasAWTRIXManualDisplayToRestore || model.hasC6SoftwareControlToRelease else { return .terminateNow }
        guard !awtrixQuitRestorePending else { return .terminateLater }
        awtrixQuitRestorePending = true
        model.prepareForTermination()
        let restore = Task { @MainActor in
            async let c6: Void = model.releaseC6SoftwareControlBeforeQuit()
            async let awtrix: Void = model.restoreAWTRIXManualDisplaysBeforeQuit()
            _ = await (c6, awtrix)
        }
        // 不让离线设备阻塞退出；未完成的恢复点留在磁盘，下次启动重试。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard self?.awtrixQuitRestorePending == true else { return }
            self?.awtrixQuitRestorePending = false
            restore.cancel()
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor [weak self] in
            await restore.value
            guard self?.awtrixQuitRestorePending == true else { return }
            self?.awtrixQuitRestorePending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.prepareForTermination()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceDisplayObservers.forEach(workspaceCenter.removeObserver)
        let distributedCenter = DistributedNotificationCenter.default()
        distributedDisplayObservers.forEach(distributedCenter.removeObserver)
    }

    /// AI Mac 彩屏跟随系统：锁屏/睡眠熄灭背光，解锁/唤醒恢复并补推当前画面。
    /// Workspace 与分布式锁屏通知会有重叠，AppModel 会对相同状态自动去重。
    private func installAIMacSystemDisplayObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sleepNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        let wakeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for name in sleepNames {
            workspaceDisplayObservers.append(workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.setAIMacSystemSleeping(true)
            })
        }
        for name in wakeNames {
            workspaceDisplayObservers.append(workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.setAIMacSystemSleeping(false)
            })
        }

        let distributedCenter = DistributedNotificationCenter.default()
        let locked = Notification.Name("com.apple.screenIsLocked")
        let unlocked = Notification.Name("com.apple.screenIsUnlocked")
        distributedDisplayObservers.append(distributedCenter.addObserver(
            forName: locked, object: nil, queue: .main
        ) { [weak self] _ in
            self?.setAIMacSystemSleeping(true)
        })
        distributedDisplayObservers.append(distributedCenter.addObserver(
            forName: unlocked, object: nil, queue: .main
        ) { [weak self] _ in
            self?.setAIMacSystemSleeping(false)
        })
    }

    private func setAIMacSystemSleeping(_ sleeping: Bool) {
        guard let model else { return }
        Task { @MainActor in
            await model.handleAIMacSystemSleepChange(sleeping: sleeping)
        }
    }

    /// 用户从「系统设置 → 输入监控」返回时，刷新授权状态并在需要时自动重连旋钮。
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            model?.refreshInputMonitoringStatus()
        }
    }

    /// 安装全局快捷键（番茄钟 + 灵犀68 手动翻页）。
    private func installHotkeys() {
        let shortcuts: [GlobalHotkeyManager.Action: GlobalShortcut] = MainActor.assumeIsolated {
            [
                .togglePomodoro: model?.settings.pomodoroToggleShortcut ?? .defaultToggle,
                .skipPomodoro: model?.settings.pomodoroSkipShortcut ?? .defaultSkip,
                .resetPomodoro: model?.settings.pomodoroResetShortcut ?? .defaultReset,
                .keyboardPageUp: model?.settings.keyboardPageUpShortcut ?? .defaultPageUp,
                .keyboardPageDown: model?.settings.keyboardPageDownShortcut ?? .defaultPageDown
            ]
        }
        GlobalHotkeyManager.install(handler: { [weak self] action in
            MainActor.assumeIsolated {
                guard let self, let model = self.model else { return }
                switch action {
                case .togglePomodoro: Task { await model.togglePomodoro() }
                case .skipPomodoro: Task { await model.skipPomodoro() }
                case .resetPomodoro: Task { await model.resetPomodoro() }
                case .keyboardPageUp: model.manualKeyboardPage(direction: -1)
                case .keyboardPageDown: model.manualKeyboardPage(direction: 1)
                }
            }
        }, shortcuts: shortcuts)
    }

    // MARK: - 菜单栏常驻图标（左键/右键均弹出菜单，含快速切换与番茄钟子菜单）

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "多屏灵犀")
        item.button?.toolTip = "多屏灵犀 · 点击切换显示内容"

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let openItem = menu.addItem(withTitle: "打开面板…", action: #selector(openMainWindow), keyEquivalent: ",")
        openItem.target = self

        menu.addItem(.separator())

        let pushItem = menu.addItem(withTitle: "立即推送", action: #selector(pushNow), keyEquivalent: "")
        pushItem.target = self
        let refreshItem = menu.addItem(withTitle: "刷新数据", action: #selector(refreshNow), keyEquivalent: "")
        refreshItem.target = self

        menu.addItem(.separator())

        // Device entries are rebuilt immediately before opening the native menu.

        menu.addItem(.separator())

        // 番茄钟控制子菜单：操作与实时状态
        let pomodoroSubmenu = NSMenu()
        pomodoroSubmenu.delegate = self
        let toggleItem = NSMenuItem(title: "", action: #selector(pomodoroToggle), keyEquivalent: "")
        toggleItem.target = self
        let skipItem = NSMenuItem(title: "跳过  \(GlobalHotkeyManager.shortcutHint(for: .skipPomodoro))", action: #selector(pomodoroSkip), keyEquivalent: "")
        skipItem.target = self
        let resetItem = NSMenuItem(title: "重置  \(GlobalHotkeyManager.shortcutHint(for: .resetPomodoro))", action: #selector(pomodoroReset), keyEquivalent: "")
        resetItem.target = self
        let statusItemLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusItemLabel.isEnabled = false
        pomodoroSubmenu.addItem(toggleItem)
        pomodoroSubmenu.addItem(skipItem)
        pomodoroSubmenu.addItem(resetItem)
        pomodoroSubmenu.addItem(.separator())
        pomodoroSubmenu.addItem(statusItemLabel)
        let pomodoroEntry = NSMenuItem(title: "番茄钟控制", action: nil, keyEquivalent: "")
        pomodoroEntry.submenu = pomodoroSubmenu
        menu.addItem(pomodoroEntry)
        self.pomodoroSubmenu = pomodoroSubmenu

        menu.addItem(.separator())

        let quitItem = menu.addItem(withTitle: "退出 多屏灵犀", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self

        item.menu = menu
        statusItem = item
    }

    /// 菜单即将显示时刷新动态内容（勾选当前模式、番茄钟按钮与状态）
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let model else { return }
        MainActor.assumeIsolated {
            if menu === self.statusItem?.menu {
                self.rebuildCanvasSubmenus(model: model)
            }
            if menu === self.pomodoroSubmenu || menu === self.statusItem?.menu {
                let items = self.pomodoroSubmenu?.items ?? []
                if items.count >= 5 {
                    items[0].title = "\(model.pomodoroAction)  \(GlobalHotkeyManager.shortcutHint(for: .togglePomodoro))"
                    items[1].title = "跳过  \(GlobalHotkeyManager.shortcutHint(for: .skipPomodoro))"
                    items[2].title = "重置  \(GlobalHotkeyManager.shortcutHint(for: .resetPomodoro))"
                    items[4].title = model.pomodoroStatus
                }
            }
        }
        if let view = previewViews[menu],
           let item = menu.items.first(where: { $0.state == .on && previewTargets[$0] != nil })
            ?? menu.items.first(where: { previewTargets[$0] != nil }) {
            schedulePreview(item, in: menu, view: view)
        }
    }

    /// One submenu per physical screen; no type → device → card cascade.
    @MainActor
    private func rebuildCanvasSubmenus(model: AppModel) {
        guard let root = statusItem?.menu else { return }
        previewTimer?.invalidate()
        previewTargets.removeAll()
        previewViews.removeAll()
        previewCache.removeAll()
        for entry in deviceMenuEntries { root.removeItem(entry) }
        deviceMenuEntries.removeAll()

        for device in MenuBarPresentationPolicy.displayDevices(model.settings.devices) {
            let name = MenuBarNamingPolicy.resolvedDeviceName(device)
            let submenu = NSMenu(title: name)
            submenu.autoenablesItems = false
            submenu.delegate = self
            let entry = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            entry.submenu = submenu
            entry.toolTip = device.type.title
            let symbol: String
            switch device.type {
            case .keyboard: symbol = "keyboard"
            case .oracle, .excerpt: symbol = "rectangle"
            case .awtrix: symbol = "rectangle.split.3x1"
            default: symbol = "display"
            }
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: device.type.title)
            root.insertItem(entry, at: 5 + deviceMenuEntries.count)
            deviceMenuEntries.append(entry)

            // Add actions first so an empty screen doesn't occupy a large preview.
            switch device.type {
            case .keyboard:
                let current = model.activeDeviceID(for: .keyboard) == device.id
                    ? model.settings.displayMode : device.settings.displayMode
                for panel in model.keyboardCardList(for: device.id) {
                    guard let mode = panel.displayMode else { continue }
                    let item = NSMenuItem(title: model.menuTitle(for: mode),
                        action: #selector(switchMode(_:)), keyEquivalent: "")
                    item.target = self
                    let target = MenuBarPreviewTarget.card(device.id, mode)
                    item.representedObject = target
                    item.state = current == mode ? .on : .off
                    previewTargets[item] = target
                    submenu.addItem(item)
                }
            case .oracle, .excerpt:
                let oracle = device.type == .oracle
                let boards: [(UUID, String, Bool)] = oracle
                    ? model.visibleOracleCanvasBoards(for: device.id).map {
                        ($0.id, $0.name, model.isCurrentOracleCanvasBoard(deviceID: device.id, boardID: $0.id))
                    } : model.visibleExcerptCanvasBoards(for: device.id).map {
                        ($0.id, $0.name, model.isCurrentExcerptCanvasBoard(deviceID: device.id, boardID: $0.id))
                    }
                for (id, title, selected) in boards {
                    let item = NSMenuItem(title: title,
                        action: oracle ? #selector(switchOracleBoard(_:)) : #selector(switchExcerptBoard(_:)),
                        keyEquivalent: "")
                    item.target = self
                    item.representedObject = "\(device.id.uuidString)|\(id.uuidString)"
                    item.state = selected ? .on : .off
                    previewTargets[item] = .board(device.id, id)
                    submenu.addItem(item)
                }
            case .aiMacScreen, .c6Screen:
                let hasCards: Bool
                if device.type == .c6Screen {
                    let cards = model.c6CardList(for: device.id)
                    hasCards = !cards.isEmpty
                    for card in cards {
                        let item = NSMenuItem(title: "\(card.title) · \(card.sourceTitle)",
                            action: #selector(switchC6Card(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = "\(device.id.uuidString)|c6card|\(card.id)"
                        item.state = model.isCurrentC6Card(deviceID: device.id, card: card) ? .on : .off
                        if card.nativeCard != nil {
                            previewTargets[item] = .c6Local(device.id, card.id)
                        } else if let mode = card.displayMode {
                            previewTargets[item] = .card(device.id, mode)
                        }
                        submenu.addItem(item)
                    }
                } else {
                    let modes = model.aiMacCardList(for: device.id)
                    hasCards = !modes.isEmpty
                    for mode in modes {
                        let item = NSMenuItem(title: model.menuTitle(for: mode),
                            action: #selector(switchAIMacCard(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = "\(device.id.uuidString)|card|\(mode.rawValue)"
                        item.state = model.isCurrentAIMacCard(deviceID: device.id, mode: mode) ? .on : .off
                        previewTargets[item] = .card(device.id, mode)
                        submenu.addItem(item)
                    }
                }
                let boards = model.visibleAIMacCanvasBoards(for: device.id)
                if hasCards && !boards.isEmpty { submenu.addItem(.separator()) }
                for board in boards {
                    let item = NSMenuItem(title: board.name, action: #selector(switchAIMacBoard(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = "\(device.id.uuidString)|\(board.id.uuidString)"
                    item.state = model.isCurrentAIMacCanvasBoard(deviceID: device.id, boardID: board.id) ? .on : .off
                    previewTargets[item] = .board(device.id, board.id)
                    submenu.addItem(item)
                }
            case .awtrix:
                rebuildAWTRIXSubmenu(model: model, device: device, menu: submenu)
            default: break
            }
            if submenu.items.contains(where: { previewTargets[$0] != nil }) {
                let view = MenuBarScreenPreview(imageAreaHeight: device.type == .keyboard ? 300 : device.type == .awtrix ? 76 : 184)
                previewViews[submenu] = view
                let header = NSMenuItem(title: "画面预览", action: nil, keyEquivalent: "")
                header.isEnabled = false
                header.view = view
                submenu.insertItem(header, at: 0)
                submenu.insertItem(.separator(), at: 1)
            }
            addEmptyHintIfNeeded(to: submenu, title: "尚未添加可见卡片或画板")
        }
        if deviceMenuEntries.isEmpty {
            let hint = NSMenuItem(title: "尚未添加显示设备", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            root.insertItem(hint, at: 5)
            deviceMenuEntries.append(hint)
        }
    }

    @MainActor
    private func rebuildAWTRIXSubmenu(model: AppModel, device: ManagedDevice, menu: NSMenu) {
        let snapshot = model.awtrixSnapshots[device.id]
        for card in model.awtrixVisibleCards(for: device.id) {
            let item = awtrixMenuItem(title: card.title, action: .showCard(device.id, card.name))
            item.image = NSImage(systemSymbolName: card.symbol, accessibilityDescription: card.title)
            item.state = snapshot?.device.currentApp?.caseInsensitiveCompare(card.name) == .orderedSame ? .on : .off
            previewTargets[item] = .awtrix(device.id, card.name)
            menu.addItem(item)
        }
        addEmptyHintIfNeeded(to: menu, title: "尚未添加可见卡片")
        menu.addItem(.separator())
        let rotation = awtrixMenuItem(title: "自动轮播", action: .toggleRotation(device.id))
        rotation.state = model.awtrixSettings(for: device.id).autoTransition ? .on : .off
        menu.addItem(rotation)
        menu.addItem(awtrixMenuItem(title: "上一张卡片", action: .move(device.id, next: false)))
        menu.addItem(awtrixMenuItem(title: "下一张卡片", action: .move(device.id, next: true)))
        menu.addItem(.separator())
        let refresh = awtrixMenuItem(title: "刷新数据", action: .refresh(device.id))
        refresh.isEnabled = !model.awtrixBusyIDs.contains(device.id)
        menu.addItem(refresh)
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let item, let view = previewViews[menu], previewTargets[item] != nil else { return }
        schedulePreview(item, in: menu, view: view)
    }

    private func schedulePreview(_ item: NSMenuItem, in menu: NSMenu, view: MenuBarScreenPreview) {
        guard let target = previewTargets[item] else { return }
        previewTimer?.invalidate()
        let title = item.title
        if let image = previewCache[target] {
            view.show(image: image, title: title)
            return
        }
        view.show(image: nil, title: title, explanation: "正在准备预览…")
        // Only one hovered frame is rendered, after a short debounce. No polling,
        // network request or render of every card on root-menu opening.
        let timer = Timer(timeInterval: 0.12, repeats: false) { [weak self, weak view] _ in
            MainActor.assumeIsolated {
                guard let self, let view, let model = self.model,
                      self.previewViews[menu] === view else { return }
                do {
                    let image = try model.menuBarPreview(for: target)
                    if let image {
                        // Bound retained bitmaps even in a long, user-defined menu.
                        if self.previewCache.count >= 12 { self.previewCache.removeAll() }
                        self.previewCache[target] = image
                    }
                    let explanation: String?
                    if case .awtrix = target {
                        explanation = image == nil ? "仅当前应用有设备快照 · 点击切换" : "设备最近画面 · 点击切换"
                    } else if case .c6Local = target {
                        explanation = image == nil ? "仅当前本地卡片有设备快照 · 点击切换" : "设备最近画面 · 点击切换"
                    } else { explanation = nil }
                    view.show(image: image, title: title, explanation: explanation)
                } catch {
                    view.show(image: nil, title: title, explanation: "预览暂不可用 · 点击卡片仍可切换")
                }
            }
        }
        previewTimer = timer
        // Explicitly support menu tracking; a default-mode timer won't fire while
        // the user holds a submenu open. The timer is one-shot, not polling.
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
    }

    func menuDidClose(_ menu: NSMenu) {
        previewTimer?.invalidate()
        previewTimer = nil
        if menu === statusItem?.menu {
            for view in previewViews.values { view.show(image: nil, title: "画面预览") }
            previewCache.removeAll()
            previewTargets.removeAll()
            previewViews.removeAll()
        }
    }

    @MainActor
    private func awtrixMenuItem(title: String, action: AWTRIXMenuAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performAWTRIXMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        return item
    }

    @MainActor
    private func addEmptyHintIfNeeded(to menu: NSMenu?, title: String) {
        guard let menu, menu.items.isEmpty else { return }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    // MARK: - 主窗口（iOS 26 风格：透明标题栏 + 毛玻璃背景）

    @objc private func openMainWindow() {
        guard let model else { return }
        if let windowController {
            windowController.showWindow(nil)
            centerOnMainScreen(windowController.window)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingView(rootView: SettingsView(model: model))

        let window = ToolbarlessMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        // macOS 26 沉浸式标题栏：隐藏窗口标题、标题栏透明、内容延伸到标题栏区域，
        // 红绿灯按钮悬浮在左侧导航栏上
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.contentMinSize = NSSize(width: 700, height: 560)
        window.setFrameAutosaveName("LingxiMultiMainWindow")
        window.contentView = hosting

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        centerOnMainScreen(window)
        applyAppearance()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 把窗口放到鼠标当前所在屏幕的中央（多显示器时用户在看哪块屏就开在哪块屏上）
    private func centerOnMainScreen(_ window: NSWindow?) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let frame = window?.frame ?? NSRect(x: 0, y: 0, width: 820, height: 660)
        let origin = NSPoint(x: visible.midX - frame.width / 2,
                             y: visible.midY - frame.height / 2)
        window?.setFrameOrigin(origin)
    }

    /// 应用外观设置（跟随系统 / 浅色 / 深色 + 背景底色）
    private func applyAppearance() {
        MainActor.assumeIsolated {
            guard let window = self.windowController?.window, let model = self.model else { return }
            switch model.settings.appearanceMode {
            case .system:
                window.appearance = nil
            case .light:
                window.appearance = NSAppearance(named: .aqua)
            case .dark:
                window.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }

    // MARK: - 菜单动作

    @objc private func performAWTRIXMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? AWTRIXMenuAction, let model else { return }
        Task { @MainActor in
            switch action {
            case let .showCard(deviceID, name):
                await model.showAWTRIXCard(name, deviceID: deviceID)
            case let .toggleRotation(deviceID):
                let isRotating = model.awtrixSettings(for: deviceID).autoTransition
                await model.setAWTRIXAutoRotation(!isRotating, deviceID: deviceID)
            case let .move(deviceID, next):
                await model.moveAWTRIXApp(next: next, deviceID: deviceID)
            case let .refresh(deviceID):
                await model.refreshAWTRIX(deviceID: deviceID)
            }
        }
    }

    @objc private func switchMode(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MenuBarPreviewTarget,
              case let .card(deviceID, mode) = target,
              let model else { return }
        MainActor.assumeIsolated {
            guard model.enabledDevices(for: .keyboard).contains(where: { $0.id == deviceID }),
                  model.keyboardCardList(for: deviceID).contains(where: { $0.displayMode == mode }) else { return }
            model.switchDevice(type: .keyboard, to: deviceID)
            model.setMode(mode)
        }
    }

    @objc private func switchOracleBoard(_ sender: NSMenuItem) {
        guard let (deviceID, boardID) = boardIDs(from: sender), let model else { return }
        MainActor.assumeIsolated {
            model.menuBarSelectOracleBoard(deviceID: deviceID, boardID: boardID)
        }
    }

    @objc private func switchExcerptBoard(_ sender: NSMenuItem) {
        guard let (deviceID, boardID) = boardIDs(from: sender), let model else { return }
        MainActor.assumeIsolated {
            model.menuBarSelectExcerptBoard(deviceID: deviceID, boardID: boardID)
        }
    }

    @objc private func switchAIMacBoard(_ sender: NSMenuItem) {
        guard let (deviceID, boardID) = boardIDs(from: sender), let model else { return }
        MainActor.assumeIsolated {
            guard model.enabledColorWiFiScreens.contains(where: { $0.id == deviceID }),
                  model.visibleAIMacCanvasBoards(for: deviceID).contains(where: { $0.id == boardID }) else { return }
            model.selectColorScreen(deviceID: deviceID)
            model.menuBarSelectAIMacBoard(deviceID: deviceID, boardID: boardID)
        }
    }

    @objc private func switchC6Card(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let model else { return }
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "c6card",
              let deviceID = UUID(uuidString: String(parts[0])) else { return }
        let token = String(parts[2])
        MainActor.assumeIsolated {
            guard model.enabledDevices(for: .c6Screen).contains(where: { $0.id == deviceID }),
                  let card = model.c6CardList(for: deviceID).first(where: { $0.id == token }) else { return }
            model.selectColorScreen(deviceID: deviceID)
            model.activateC6Card(card, deviceID: deviceID)
        }
    }

    @objc private func switchAIMacCard(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let model else { return }
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "card",
              let deviceID = UUID(uuidString: String(parts[0])),
              let rawValue = Int(parts[2]),
              let mode = DisplayMode(rawValue: rawValue) else { return }
        MainActor.assumeIsolated {
            guard model.enabledColorWiFiScreens.contains(where: { $0.id == deviceID }),
                  model.aiMacCardList(for: deviceID).contains(mode) else { return }
            model.selectColorScreen(deviceID: deviceID)
            model.activateAIMacCard(mode, deviceID: deviceID)
        }
    }

    private func boardIDs(from sender: NSMenuItem) -> (UUID, UUID)? {
        guard let key = sender.representedObject as? String else { return nil }
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let deviceID = UUID(uuidString: String(parts[0])),
              let boardID = UUID(uuidString: String(parts[1])) else { return nil }
        return (deviceID, boardID)
    }

    @objc private func pomodoroToggle() {
        guard let model else { return }
        Task { await model.togglePomodoro() }
    }

    @objc private func pomodoroSkip() {
        guard let model else { return }
        Task { await model.skipPomodoro() }
    }

    @objc private func pomodoroReset() {
        guard let model else { return }
        Task { await model.resetPomodoro() }
    }

    @objc private func pushNow() {
        guard let model else { return }
        Task { @MainActor in model.menuBarPushNow() }
    }

    @objc private func refreshNow() {
        guard let model else { return }
        Task { await model.refresh() }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
