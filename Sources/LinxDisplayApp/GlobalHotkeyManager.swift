import Carbon.HIToolbox
import Foundation

/// 全局番茄钟快捷键（系统范围内生效，基于 Carbon RegisterEventHotKey）。
/// ⌃⌥Space 开始/暂停 · ⌃⌥→ 跳过 · ⌃⌥⌫ 重置
final class GlobalHotkeyManager {

    enum Action {
        case togglePomodoro
        case skipPomodoro
        case resetPomodoro
    }

    // 快捷键组合与键码
    static let toggleKeyCode: UInt32 = 49        // Space
    static let skipKeyCode: UInt32 = 124         // →
    static let resetKeyCode: UInt32 = 51         // ⌫ (Delete)
    static let modifiers: UInt32 = UInt32(controlKey) | UInt32(optionKey) // ⌃⌥

    private static let signature: OSType = 0x4C78_4448 // "LxDH"
    private static var actionByID: [UInt32: Action] = [:]
    private static var hotKeyRefs: [EventHotKeyRef?] = []
    private static var handler: ((Action) -> Void)?
    private static var installed = false

    /// 安装事件处理器并注册全部快捷键。返回注册成功的数量。
    @discardableResult
    static func install(handler: @escaping (Action) -> Void) -> Int {
        self.handler = handler
        installEventHandlerIfNeeded()
        var success = 0
        if register(id: 1, keyCode: toggleKeyCode, action: .togglePomodoro) { success += 1 }
        if register(id: 2, keyCode: skipKeyCode, action: .skipPomodoro) { success += 1 }
        if register(id: 3, keyCode: resetKeyCode, action: .resetPomodoro) { success += 1 }
        return success
    }

    static func uninstall() {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()
        actionByID.removeAll()
        handler = nil
    }

    static func shortcutHint(for action: Action) -> String {
        switch action {
        case .togglePomodoro: return "⌃⌥Space"
        case .skipPomodoro: return "⌃⌥→"
        case .resetPomodoro: return "⌃⌥⌫"
        }
    }

    // MARK: - 内部

    @discardableResult
    private static func register(id: UInt32, keyCode: UInt32, action: Action) -> Bool {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
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