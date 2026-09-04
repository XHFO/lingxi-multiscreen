import Foundation
import IOKit.hid

/// 灵犀 68 的 Fn + 旋钮控制器。
///
/// 只匹配 VID 0x38EE / PID 0x0005 的 Consumer Control 接口，并以 seize 模式打开。
/// 因此启用时只有这把键盘的媒体控制会被系统拦截；其他键盘和 Mac 自身音量键不受影响。
final class Lingxi68KnobController {
    static let vendorID = 0x38EE
    static let productID = 0x0005

    var onPage: ((Int) -> Void)?
    var onStatus: ((String) -> Void)?

    private var manager: IOHIDManager?
    private(set) var isEnabled = false

    enum InputAccess {
        case granted
        case denied
        case unknown
    }

    /// IOHIDManager 使用的原生输入监控权限状态（与旋钮监听走同一套 API）。
    static var inputAccess: InputAccess {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    /// 首次启用时触发系统权限请求；已拒绝时系统不会重复弹窗，需由用户在设置中手动开启。
    @discardableResult
    static func requestInputAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func restart() {
        stop()
        start()
    }

    private func start() {
        guard manager == nil else { return }
        isEnabled = true

        guard Self.inputAccess == .granted else {
            onStatus?("未获得输入监控权限；授权后将自动重新连接")
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
            kIOHIDPrimaryUsagePageKey as String: 0x0C,
            kIOHIDPrimaryUsageKey as String: 0x01
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let controller = Unmanaged<Lingxi68KnobController>.fromOpaque(context).takeUnretainedValue()
            controller.onStatus?("已接管灵犀68：Fn + 旋钮可翻页，系统音量已拦截")
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let controller = Unmanaged<Lingxi68KnobController>.fromOpaque(context).takeUnretainedValue()
            controller.onStatus?("未检测到灵犀68 Consumer Control 接口")
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == 0x0C,
                  IOHIDValueGetIntegerValue(value) == 1 else { return }

            let controller = Unmanaged<Lingxi68KnobController>.fromOpaque(context).takeUnretainedValue()
            switch IOHIDElementGetUsage(element) {
            case 0xE9: controller.onPage?(1)   // Fn + 顺时针：下一页
            case 0xEA: controller.onPage?(-1)  // Fn + 逆时针：上一页
            default: break                     // 旋钮按压（静音）只拦截，不绑定动作
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        // 独占精确匹配的 Consumer Control 接口：从源头阻止系统音量响应。
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if result == kIOReturnSuccess {
            onStatus?("正在等待灵犀68旋钮…")
        } else {
            onStatus?(Self.openErrorDescription(result))
        }
    }

    private func stop() {
        isEnabled = false
        guard let manager else {
            onStatus?("未启用")
            return
        }
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        onStatus?("未启用")
    }

    private static func openErrorDescription(_ result: IOReturn) -> String {
        if result == kIOReturnNotPermitted {
            return "未获得输入监控权限，请授权后重新连接"
        }
        if result == kIOReturnExclusiveAccess {
            return "旋钮接口正被其他软件独占，请退出键盘改键软件后重试"
        }
        return String(format: "旋钮接管失败（IOKit 0x%08X）", result)
    }

    deinit {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
}
