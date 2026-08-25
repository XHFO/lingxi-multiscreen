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

    /// 安装全局番茄钟快捷键（默认 ⌃⌥Space / ⌃⌥→ / ⌃⌥⌫，可在番茄钟设置中自定义）
    private func installHotkeys() {
        let shortcuts: [GlobalHotkeyManager.Action: GlobalShortcut] = MainActor.assumeIsolated {
            [
                .togglePomodoro: model?.settings.pomodoroToggleShortcut ?? .defaultToggle,
                .skipPomodoro: model?.settings.pomodoroSkipShortcut ?? .defaultSkip,
                .resetPomodoro: model?.settings.pomodoroResetShortcut ?? .defaultReset
            ]
        }
        GlobalHotkeyManager.install(handler: { [weak self] action in
            MainActor.assumeIsolated {
                guard let self, let model = self.model else { return }
                switch action {
                case .togglePomodoro: Task { await model.togglePomodoro() }
                case .skipPomodoro: Task { await model.skipPomodoro() }
                case .resetPomodoro: Task { await model.resetPomodoro() }
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

        // 显示内容：直接作为顶层菜单项（每个模式一项，当前项带勾选，无需二次点击）
        let modeOrder: [DisplayMode] = [.qwenWork, .codex, .pomodoro, .systemMonitor, .nowPlaying, .customImage, .canvas, .excerptQuote, .sspai]
        for mode in modeOrder {
            let modeItem = NSMenuItem(title: mode.title, action: #selector(switchMode(_:)), keyEquivalent: "")
            modeItem.target = self
            modeItem.representedObject = mode.rawValue
            modeItems.append(modeItem)
            menu.addItem(modeItem)
        }

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
                for item in self.modeItems {
                    guard let raw = item.representedObject as? Int,
                          let mode = DisplayMode(rawValue: raw) else { continue }
                    item.state = (mode == model.settings.displayMode) ? .on : .off
                }
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
