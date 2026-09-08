import AppKit
import LinxDisplayCore
import SwiftUI

/// 手动 AppKit 引导（SPM 可执行环境下 SwiftUI @main 场景不可靠）：
/// NSStatusItem 提供菜单栏常驻图标（右键快速切换显示模式、番茄钟子菜单），
/// NSHostingView 承载 SwiftUI 主面板。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private var windowController: NSWindowController?
    private var modeItems: [NSMenuItem] = []
    private var pomodoroSubmenu: NSMenu?
    private var keyboardCanvasSubmenu: NSMenu?
    private var oracleCanvasSubmenu: NSMenu?
    private var excerptCanvasSubmenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        model.onAppearanceChanged = { [weak self] in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
        setupMenuBar()
        setupEditMenu() // 菜单栏应用没有默认编辑菜单，Cmd+C/V/X 等快捷键依赖它
        installHotkeys()
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

        // 三类画板统一折叠为二级菜单：只列出用户实际添加并保持可见的卡片/画板，
        // 避免所有内容平铺在系统菜单栏造成层级混乱。
        let keyboardCanvasSubmenu = NSMenu(title: "灵犀画板")
        let keyboardEntry = NSMenuItem(title: "灵犀画板", action: nil, keyEquivalent: "")
        keyboardEntry.submenu = keyboardCanvasSubmenu
        menu.addItem(keyboardEntry)
        self.keyboardCanvasSubmenu = keyboardCanvasSubmenu

        let oracleCanvasSubmenu = NSMenu(title: "口袋先知画板")
        let oracleEntry = NSMenuItem(title: "口袋先知画板", action: nil, keyEquivalent: "")
        oracleEntry.submenu = oracleCanvasSubmenu
        menu.addItem(oracleEntry)
        self.oracleCanvasSubmenu = oracleCanvasSubmenu

        let excerptCanvasSubmenu = NSMenu(title: "摘录画板")
        let excerptEntry = NSMenuItem(title: "摘录画板", action: nil, keyEquivalent: "")
        excerptEntry.submenu = excerptCanvasSubmenu
        menu.addItem(excerptEntry)
        self.excerptCanvasSubmenu = excerptCanvasSubmenu

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
                if items.count >= 4 {
                    items[0].title = "\(model.pomodoroAction)  \(GlobalHotkeyManager.shortcutHint(for: .togglePomodoro))"
                    items[1].title = "跳过  \(GlobalHotkeyManager.shortcutHint(for: .skipPomodoro))"
                    items[2].title = "重置  \(GlobalHotkeyManager.shortcutHint(for: .resetPomodoro))"
                    items[3].title = model.pomodoroStatus
                }
            }
        }
    }

    /// 每次展开菜单时按当前设备快照重建三个画板子菜单，确保新增、删除、重命名、
    /// 显示/隐藏与设备切换都无需重启即可同步，且不同设备的画板不会串到一起。
    @MainActor
    private func rebuildCanvasSubmenus(model: AppModel) {
        modeItems.removeAll(keepingCapacity: true)
        keyboardCanvasSubmenu?.removeAllItems()
        oracleCanvasSubmenu?.removeAllItems()
        excerptCanvasSubmenu?.removeAllItems()

        let targetKeyboard = model.settings.menuBarKeyboardDeviceID.flatMap { targetID in
            model.enabledDevices(for: .keyboard).first { $0.id == targetID }
        } ?? model.activeDevice(for: .keyboard)
        if let keyboard = targetKeyboard {
            let panels = model.keyboardCardList(for: keyboard.id)
            for panel in panels {
                guard let mode = panel.displayMode else { continue }
                let item = NSMenuItem(title: model.menuTitle(for: mode),
                                      action: #selector(switchMode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = mode.rawValue
                item.state = mode == model.settings.displayMode ? .on : .off
                modeItems.append(item)
                keyboardCanvasSubmenu?.addItem(item)
            }
        }
        addEmptyHintIfNeeded(to: keyboardCanvasSubmenu, title: "尚未添加卡片")

        let oracleDevices = model.enabledDevices(for: .oracle)
        for device in oracleDevices {
            for board in model.visibleOracleCanvasBoards(for: device.id) {
                let title = oracleDevices.count > 1 ? "\(device.name) · \(board.name)" : board.name
                let item = NSMenuItem(title: title,
                                      action: #selector(switchOracleBoard(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = "\(device.id.uuidString)|\(board.id.uuidString)"
                item.state = model.activeDeviceID(for: .oracle) == device.id
                    && model.isCurrentOracleCanvasBoard(deviceID: device.id, boardID: board.id)
                    ? .on : .off
                oracleCanvasSubmenu?.addItem(item)
            }
        }
        addEmptyHintIfNeeded(to: oracleCanvasSubmenu, title: "尚未创建可见画板")

        let excerptDevices = model.enabledDevices(for: .excerpt)
        for device in excerptDevices {
            for board in model.visibleExcerptCanvasBoards(for: device.id) {
                let title = excerptDevices.count > 1 ? "\(device.name) · \(board.name)" : board.name
                let item = NSMenuItem(title: title,
                                      action: #selector(switchExcerptBoard(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = "\(device.id.uuidString)|\(board.id.uuidString)"
                item.state = model.activeDeviceID(for: .excerpt) == device.id
                    && model.isCurrentExcerptCanvasBoard(deviceID: device.id, boardID: board.id)
                    ? .on : .off
                excerptCanvasSubmenu?.addItem(item)
            }
        }
        addEmptyHintIfNeeded(to: excerptCanvasSubmenu, title: "尚未创建可见画板")
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

        let window = NSWindow(
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

    @objc private func switchMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let mode = DisplayMode(rawValue: raw),
              let model else { return }
        MainActor.assumeIsolated { model.menuBarSetMode(mode) }
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
