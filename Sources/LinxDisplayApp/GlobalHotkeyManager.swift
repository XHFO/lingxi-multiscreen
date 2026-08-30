import Carbon.HIToolbox
import Foundation
import LinxDisplayCore

/// 全局快捷键（系统范围内生效，基于 Carbon RegisterEventHotKey）。
final class GlobalHotkeyManager {

    enum Action {
        case togglePomodoro
        case skipPomodoro
        case resetPomodoro
        case keyboardPageUp
        case keyboardPageDown
    }

    private static let signature: OSType = 0x4C78_4448 // "LxDH"
    private static var handler: ((Action) -> Void)?
    private static var currentShortcuts: [Action: GlobalShortcut] = [:]
    private static var actionByID: [UInt32: Action] = [:]
    private static var hotKeyRefs: [EventHotKeyRef?] = []
    private static var installed = false

    /// 安装事件处理器并用当前组合注册全部快捷键。
    static func install(handler: @escaping (Action) -> Void,
                        shortcuts: [Action: GlobalShortcut]) {
        self.handler = handler
        apply(shortcuts: shortcuts)
    }

    /// 按新组合重新注册；组合未变化时跳过（onChange 高频触发时无开销）。
    static func apply(shortcuts: [Action: GlobalShortcut]) {
        guard shortcuts != currentShortcuts else { return }
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()
        actionByID.removeAll()
        currentShortcuts = shortcuts
        installEventHandlerIfNeeded()
        var id: UInt32 = 1
        for (action, shortcut) in shortcuts {
            if register(id: id, shortcut: shortcut, action: action) { id += 1 }
        }
    }

    static func uninstall() {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()
        actionByID.removeAll()
        currentShortcuts.removeAll()
        handler = nil
    }

    static func shortcutHint(for action: Action) -> String {
        currentShortcuts[action]?.displayString ?? ""
    }

    // MARK: - 内部

    @discardableResult
    private static func register(id: UInt32, shortcut: GlobalShortcut, action: Action) -> Bool {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        actionByID[id] = action
        hotKeyRefs.append(ref)
        return true
    }

    private static func installEventHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID)
                guard status == noErr else { return noErr }
                if let action = GlobalHotkeyManager.actionByID[hotKeyID.id] {
                    GlobalHotkeyManager.handler?(action)
                }
                return noErr
            },
            1, &spec, nil, nil)
    }
}
