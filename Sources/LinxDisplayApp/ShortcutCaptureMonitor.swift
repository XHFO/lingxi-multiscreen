import AppKit
import CoreGraphics
import Foundation
import LinxDisplayCore

/// 临时的低层快捷键录制器。
///
/// 与 NSEvent 本地监听不同，事件在系统听写或其它全局快捷键处理之前到达；录到的
/// keyDown 会被吞掉，因此用户录制语音输入组合时不会顺便启动一次语音输入。
final class ShortcutCaptureMonitor {
    var onCapture: ((GlobalShortcut) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var acceptingEvent = false
    private var heldModifierKeyCodes = Set<UInt32>()
    private var modifierPressOrder: [UInt32] = []
    private var pressedModifierMask: UInt32 = 0

    @discardableResult
    func start() -> Bool {
        stop()
        prepareCapture()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<ShortcutCaptureMonitor>
                    .fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = recorder.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard recorder.acceptingEvent else {
                    return Unmanaged.passUnretained(event)
                }
                let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                let consumed = recorder.handle(type: type, keyCode: keyCode, flags: event.flags)
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            acceptingEvent = false
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Event Tap 无权限时仍可回退应用内监听。该路径同样处理 flagsChanged，
    /// 因而单独按下左/右 Control、Option、Command 也可以被录入。
    func startLocalCapture() {
        stop()
        prepareCapture()
    }

    /// 返回 true 表示本次事件属于录制，应由调用方吞掉。
    func handleLocalEvent(_ event: NSEvent) -> Bool {
        let type: CGEventType
        switch event.type {
        case .keyDown: type = .keyDown
        case .flagsChanged: type = .flagsChanged
        default: return false
        }
        return handle(
            type: type,
            keyCode: UInt32(event.keyCode),
            flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        )
    }

    func stop() {
        acceptingEvent = false
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        heldModifierKeyCodes.removeAll()
        modifierPressOrder.removeAll()
        pressedModifierMask = 0
    }

    deinit { stop() }

    private func prepareCapture() {
        acceptingEvent = true
        heldModifierKeyCodes.removeAll()
        modifierPressOrder.removeAll()
        pressedModifierMask = 0
    }

    private func handle(type: CGEventType, keyCode: UInt32, flags: CGEventFlags) -> Bool {
        switch type {
        case .keyDown:
            finish(GlobalShortcut(keyCode: keyCode, modifiers: Self.modifiers(from: flags)))
            return true
        case .flagsChanged:
            guard let keyMask = GlobalShortcut.modifierMask(for: keyCode),
                  let eventFlag = Self.eventFlag(for: keyMask) else { return false }

            if heldModifierKeyCodes.contains(keyCode) {
                heldModifierKeyCodes.remove(keyCode)
                // 纯修饰键或纯修饰键组合在全部松开时确认，避免刚按 Control
                // 就结束录制，从而仍可继续组成 Control + 普通键组合。
                if heldModifierKeyCodes.isEmpty, let primaryKeyCode = modifierPressOrder.last {
                    let primaryMask = GlobalShortcut.modifierMask(for: primaryKeyCode) ?? 0
                    finish(GlobalShortcut(
                        keyCode: primaryKeyCode,
                        modifiers: pressedModifierMask & ~primaryMask
                    ))
                }
            } else if flags.contains(eventFlag) {
                heldModifierKeyCodes.insert(keyCode)
                modifierPressOrder.append(keyCode)
                pressedModifierMask |= keyMask
            } else {
                // 录制开始前已经处于按下状态的修饰键，其第一次事件可能是松开；
                // 不把这类残余事件误识别为一次新快捷键。
                return false
            }
            return true
        default:
            return false
        }
    }

    private func finish(_ shortcut: GlobalShortcut) {
        guard acceptingEvent else { return }
        acceptingEvent = false
        DispatchQueue.main.async { [weak self] in
            self?.onCapture?(shortcut)
        }
    }

    private static func modifiers(from flags: CGEventFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.maskControl) { modifiers |= GlobalShortcut.controlKey }
        if flags.contains(.maskAlternate) { modifiers |= GlobalShortcut.optionKey }
        if flags.contains(.maskShift) { modifiers |= GlobalShortcut.shiftKey }
        if flags.contains(.maskCommand) { modifiers |= GlobalShortcut.cmdKey }
        return modifiers
    }

    private static func eventFlag(for modifier: UInt32) -> CGEventFlags? {
        switch modifier {
        case GlobalShortcut.controlKey: return .maskControl
        case GlobalShortcut.optionKey: return .maskAlternate
        case GlobalShortcut.shiftKey: return .maskShift
        case GlobalShortcut.cmdKey: return .maskCommand
        default: return nil
        }
    }
}
