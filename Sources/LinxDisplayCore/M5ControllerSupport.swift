import Foundation

/// M5Stack StickS3 蓝牙控制器的共享类型：GATT 标识、设备设置、事件与信息载荷。
public enum M5ControllerBLE {
    public static let serviceUUIDString = "E0A3C001-5B4C-4D2E-9F8A-6C1D2E3F4A50"
    public static let eventCharacteristicUUIDString = "E0A3C002-5B4C-4D2E-9F8A-6C1D2E3F4A50"
    public static let infoCharacteristicUUIDString = "E0A3C003-5B4C-4D2E-9F8A-6C1D2E3F4A50"
    public static let advertisementNamePrefix = "Lingxi-Controller"
}

/// 大于单次 ATT 写入上限的信息通过这个轻量分片格式发送。每片都使用
/// `.withResponse`，设备完成整包重组和 JSON 解析后再从事件特征回传应用层确认。
/// 这样软件预览更新不再被误认为控制器已经真正收到卡片。
public enum M5ControllerInfoTransport {
    public static let magic: [UInt8] = [0x1E, 0x4C, 0x58, 0x01] // RS + "LX" + v1
    public static let headerSize = 14
    public static let maximumPayloadSize = 8 * 1024

    public static func chunks(payload: Data, maximumWriteLength: Int,
                              transferID: UInt16) -> [Data] {
        guard !payload.isEmpty, payload.count <= maximumPayloadSize else { return [] }
        let bodySize = max(1, maximumWriteLength - headerSize)
        let count = (payload.count + bodySize - 1) / bodySize
        guard count <= Int(UInt16.max) else { return [] }

        return (0..<count).map { index in
            let lower = index * bodySize
            let upper = min(payload.count, lower + bodySize)
            var result = Data(magic)
            result.appendLittleEndian(transferID)
            result.appendLittleEndian(UInt16(index))
            result.appendLittleEndian(UInt16(count))
            result.appendLittleEndian(UInt32(payload.count))
            result.append(payload[lower..<upper])
            return result
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

/// 控制器通过 notify 特征回传的交互事件。
public enum M5ControllerEvent: Equatable {
    /// direction=1 下一页；direction=-1 上一页。
    case shake(direction: Int)
    /// a=下一台设备／下一项；b=上一台设备／上一项。
    case button(key: String)
    /// 长按：a=进入 Home Assistant 控制/确认执行；b=返回。
    case buttonLong(key: String)
    /// 长按按键松开；用于“按住说话”等必须保持键位按下的动作。
    case buttonUp(key: String)
    /// 固件已通过 BLE HID 发送物理键盘按下；Mac 仅更新界面，不再重复注入。
    case buttonLongHandledByHID(key: String)
    /// 固件已通过 BLE HID 发送物理键盘松开。
    case buttonUpHandledByHID(key: String)
    /// 当前停留在“语音输入”动作时摇一摇，请求清空当前输入框。
    /// handledByHID=true 表示固件已用真实蓝牙键盘完成，Mac 只更新状态。
    case clearInput(handledByHID: Bool)
    /// 多媒体组合卡片的左右摇动作。固件优先通过 Consumer Control 直接执行。
    case mediaGesture(direction: Int, handledByHID: Bool)
    /// 飞鼠完成连续静止校准，请 Mac 把指针放到当前显示器中心。
    /// 后续移动仍全部由设备作为 BLE HID 相对鼠标发送。
    case pointerRecenter
    /// 固件主动上报 HID 加密与系统键盘订阅状态，区分“控制已连接”和“键盘可用”。
    case hidState(ready: Bool, secured: Bool)

    public static func parse(_ text: String) -> M5ControllerEvent? {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "shake":
            let direction = (object["dir"] as? Int) ?? 1
            return .shake(direction: direction >= 0 ? 1 : -1)
        case "button":
            guard let key = object["key"] as? String,
                  key == "a" || key == "b" else { return nil }
            switch object["press"] as? String {
            case "long": return .buttonLong(key: key)
            case "up": return .buttonUp(key: key)
            case "hid-long": return .buttonLongHandledByHID(key: key)
            case "hid-up": return .buttonUpHandledByHID(key: key)
            default: return .button(key: key)
            }
        case "input":
            guard object["action"] as? String == "clear" else { return nil }
            return .clearInput(handledByHID: object["source"] as? String == "hid")
        case "media":
            let direction = (object["dir"] as? Int) ?? 1
            return .mediaGesture(direction: direction >= 0 ? 1 : -1,
                                 handledByHID: object["source"] as? String == "hid")
        case "mouse":
            guard object["action"] as? String == "recenter" else { return nil }
            return .pointerRecenter
        case "hid":
            return .hidState(ready: object["ready"] as? Bool ?? false,
                             secured: object["secured"] as? Bool ?? false)
        default:
            return nil
        }
    }
}

/// Mac 写回 StickS3 屏幕的被控设备列表与当前页面信息。
public struct M5ControllerInfo: Codable, Equatable {
    public struct Device: Codable, Equatable {
        public var name: String
        public var detail: String
        public var available: Bool

        public init(name: String, detail: String, available: Bool) {
            self.name = name
            self.detail = detail
            self.available = available
        }
    }

    public var v: Int
    public var active: Int
    public var devices: [Device]
    /// 可选页面标头/操作提示；旧固件忽略，新固件缺失时使用原默认文案。
    public var title: String?
    public var footer: String?
    /// 控制器本机蜂鸣器总开关。旧固件会忽略；新固件缺失时按开启处理。
    public var buzzer: Bool?
    /// 当前语音输入动作使用的 BLE HID modifier byte；nil/0 表示禁用设备端 HID。
    public var hidModifiers: UInt8?
    /// 当前动作的标准 USB HID Usage；0 表示纯修饰键。
    public var hidKey: UInt8?
    /// true 时一直保持到 A 键松开（语音输入）；false 时由设备发送一次完整按下/松开。
    public var hidHold: Bool?
    /// 当前是否停留在语音输入动作；用于让固件把摇晃解释为清空输入框。
    public var clearInputOnShake: Bool?
    /// 当前多媒体动作的 Consumer Control Usage。非多媒体页面为 nil/0。
    public var consumerUsage: UInt16?
    /// 多媒体组合卡片左摇、右摇分别使用的 Consumer Control Usage。
    public var consumerUsageLeft: UInt16?
    public var consumerUsageRight: UInt16?
    /// 仅在“飞鼠指针”页面为 true；固件收到后切换为原生 BLE HID 鼠标。
    public var gyroMouseActive: Bool?
    /// 飞鼠指针参数。可选字段让旧固件与旧设置继续无损兼容。
    public var gyroMouseSensitivity: Double?
    public var gyroMouseDeadZone: Double?
    public var gyroMouseSmoothing: Double?
    public var gyroMouseInvertX: Bool?
    public var gyroMouseInvertY: Bool?
    /// 开启后，飞鼠指针页短按 B 在“跟随 / 临时脱开”之间切换。
    public var gyroMouseClutchEnabled: Bool?
    /// 软件侧每次请求飞鼠重新居中时递增；固件只对新 token 校准一次。
    public var gyroMouseRecenterToken: UInt32?
    /// 软件勾选状态的精简菜单清单。固件会持久化这些字段，并在重启后直接绘制
    /// 本地主菜单；具体页面仍由 Mac 回写动态数据。
    public var mainMenuMask: UInt8?
    public var shortcutMenuMask: UInt8?
    public var targetDeviceCount: Int?
    public var homeAssistantEntityCount: Int?
    public var vibeActionCount: Int?
    public var presentationActionCount: Int?
    public var customActionCount: Int?
    /// 仅在用户明确解除或删除控制器时下发；普通固件升级不应破坏有效系统配对。
    public var resetHIDBond: Bool?

    public init(active: Int, devices: [Device], title: String? = nil, footer: String? = nil,
                buzzer: Bool? = nil, hidModifiers: UInt8? = nil, hidKey: UInt8? = nil,
                hidHold: Bool? = nil,
                clearInputOnShake: Bool? = nil, consumerUsage: UInt16? = nil,
                consumerUsageLeft: UInt16? = nil, consumerUsageRight: UInt16? = nil,
                gyroMouseActive: Bool? = nil, gyroMouseSensitivity: Double? = nil,
                gyroMouseDeadZone: Double? = nil, gyroMouseSmoothing: Double? = nil,
                gyroMouseInvertX: Bool? = nil, gyroMouseInvertY: Bool? = nil,
                gyroMouseClutchEnabled: Bool? = nil,
                gyroMouseRecenterToken: UInt32? = nil,
                mainMenuMask: UInt8? = nil, shortcutMenuMask: UInt8? = nil,
                targetDeviceCount: Int? = nil, homeAssistantEntityCount: Int? = nil,
                vibeActionCount: Int? = nil, presentationActionCount: Int? = nil,
                customActionCount: Int? = nil,
                resetHIDBond: Bool? = nil) {
        self.v = 1
        self.active = active
        self.devices = devices.map {
            Device(name: Self.displaySafeText($0.name),
                   detail: Self.displaySafeText($0.detail), available: $0.available)
        }
        self.title = title.map(Self.displaySafeText)
        self.footer = footer.map(Self.displaySafeText)
        self.buzzer = buzzer
        self.hidModifiers = hidModifiers
        self.hidKey = hidKey
        self.hidHold = hidHold
        self.clearInputOnShake = clearInputOnShake
        self.consumerUsage = consumerUsage
        self.consumerUsageLeft = consumerUsageLeft
        self.consumerUsageRight = consumerUsageRight
        self.gyroMouseActive = gyroMouseActive
        self.gyroMouseSensitivity = gyroMouseSensitivity
        self.gyroMouseDeadZone = gyroMouseDeadZone
        self.gyroMouseSmoothing = gyroMouseSmoothing
        self.gyroMouseInvertX = gyroMouseInvertX
        self.gyroMouseInvertY = gyroMouseInvertY
        self.gyroMouseClutchEnabled = gyroMouseClutchEnabled
        self.gyroMouseRecenterToken = gyroMouseRecenterToken
        self.mainMenuMask = mainMenuMask
        self.shortcutMenuMask = shortcutMenuMask
        self.targetDeviceCount = targetDeviceCount
        self.homeAssistantEntityCount = homeAssistantEntityCount
        self.vibeActionCount = vibeActionCount
        self.presentationActionCount = presentationActionCount
        self.customActionCount = customActionCount
        self.resetHIDBond = resetHIDBond
    }

    /// M5GFX 内置中文字库不包含 macOS 快捷键符号和 Emoji。发送前换成可稳定显示的
    /// 文本，避免控制器上出现方框；设备端仍会对截断标记做第二层兜底。
    public static func displaySafeText(_ value: String) -> String {
        let replacements: [(String, String)] = [
            ("⌃", "Ctrl "), ("⌥", "Option "), ("⇧", "Shift "), ("⌘", "Cmd "),
            ("↑", "上"), ("↓", "下"), ("←", "左"), ("→", "右"),
            ("…", "..."), ("·", " "), ("—", "-"), ("–", "-"),
            ("“", "\""), ("”", "\""), ("‘", "'"), ("’", "'")
        ]
        var result = value
        for (source, target) in replacements {
            result = result.replacingOccurrences(of: source, with: target)
        }
        result = String(result.unicodeScalars.filter { scalar in
            let n = scalar.value
            if scalar.properties.isEmojiPresentation || n == 0xFE0F || n == 0x200D {
                return false
            }
            return !CharacterSet.controlCharacters.contains(scalar)
        })
        return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 删除控制器档案或解除配对前写回设备，清除 RAM 中残留的卡片与控制目标。
    public static var clearedPairing: M5ControllerInfo {
        M5ControllerInfo(active: 0, devices: [],
                         title: "灵犀控制器", footer: "等待软件重新连接",
                         mainMenuMask: 0, shortcutMenuMask: 0,
                         targetDeviceCount: 0, homeAssistantEntityCount: 0,
                         vibeActionCount: 0, presentationActionCount: 0,
                         customActionCount: 0,
                         resetHIDBond: true)
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

/// StickS3 固件直接发送的标准 BLE HID Consumer Control 动作。
/// 这些动作由系统媒体层接收，不依赖多屏灵犀的辅助功能权限。
public enum M5MediaControlAction: UInt16, CaseIterable, Identifiable {
    case playPause = 0x00CD
    case previousTrack = 0x00B6
    case nextTrack = 0x00B5
    case volumeDown = 0x00EA
    case volumeUp = 0x00E9
    case mute = 0x00E2

    public var id: UInt16 { rawValue }

    public var title: String {
        switch self {
        case .playPause: return "播放 / 暂停"
        case .previousTrack: return "上一曲"
        case .nextTrack: return "下一曲"
        case .volumeDown: return "音量减"
        case .volumeUp: return "音量加"
        case .mute: return "静音"
        }
    }

    public var detail: String {
        switch self {
        case .playPause: return "切换播放状态"
        case .previousTrack: return "返回上一首媒体"
        case .nextTrack: return "跳到下一首媒体"
        case .volumeDown: return "降低系统音量"
        case .volumeUp: return "提高系统音量"
        case .mute: return "切换系统静音"
        }
    }
}

/// 控制器多媒体页的两张组合卡片：摇动负责成对动作，长按 A 负责中央动作。
public enum M5MediaControlCard: String, CaseIterable, Identifiable {
    case playback
    case volume

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .playback: return "播放控制"
        case .volume: return "音量控制"
        }
    }

    public var detail: String {
        switch self {
        case .playback: return "左摇上一曲 右摇下一曲"
        case .volume: return "左摇音量减 右摇音量加"
        }
    }

    public var leftAction: M5MediaControlAction {
        switch self {
        case .playback: return .previousTrack
        case .volume: return .volumeDown
        }
    }

    public var rightAction: M5MediaControlAction {
        switch self {
        case .playback: return .nextTrack
        case .volume: return .volumeUp
        }
    }

    public var holdAction: M5MediaControlAction {
        switch self {
        case .playback: return .playPause
        case .volume: return .mute
        }
    }
}

/// StickS3「Mac 快捷键」卡片所属的二级菜单。
public enum M5MacShortcutGroup: String, Codable, CaseIterable, Identifiable {
    case vibeCoding
    case presentation
    case custom

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .presentation: return "演示翻页器"
        case .vibeCoding: return "Vibe Coding"
        case .custom: return "自定义快捷键"
        }
    }
}

/// 快捷键只持久化在 Mac；当前选中动作会临时同步给 StickS3 作为 BLE HID 执行。
public struct M5MacShortcut: Codable, Equatable, Identifiable {
    public var id: String
    public var group: M5MacShortcutGroup
    public var name: String
    public var shortcut: GlobalShortcut
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, group: M5MacShortcutGroup,
                name: String, shortcut: GlobalShortcut, isEnabled: Bool = true) {
        self.id = id
        self.group = group
        self.name = name
        self.shortcut = shortcut
        self.isEnabled = isEnabled
    }
}

/// 每台 M5 StickS3 控制器独立保存的配对和控制目标设置。
public struct M5ControllerDeviceSettings: Codable, Equatable {
    public var pairedPeripheralID: String?
    public var pairedName: String?
    public var targetDeviceIDs: [String]
    public var activeTargetIndex: Int
    /// 专供 StickS3 控制的 Home Assistant 实体。可选字段保证旧配置无损解码。
    public var homeAssistantEntityIDs: [String]?
    /// nil 兼容旧档案，按开启处理。每台 StickS3 独立保存。
    public var buzzerEnabled: Bool?
    /// 演示、Vibe Coding 与用户自定义动作；优先由 StickS3 的 BLE HID 直接执行。
    public var macShortcuts: [M5MacShortcut]?
    /// 本地 BLE Consumer Control 卡片是否显示。nil 兼容旧设置，默认显示。
    public var mediaControlsEnabled: Bool?
    /// 飞鼠指针独立于快捷键动作；只有进入对应页面时才启用高频 IMU 采样。
    public var gyroMouseEnabled: Bool?
    public var gyroMouseSensitivity: Double?
    public var gyroMouseDeadZone: Double?
    public var gyroMouseSmoothing: Double?
    public var gyroMouseInvertX: Bool?
    public var gyroMouseInvertY: Bool?
    /// nil 兼容旧档案。开启后短按 B 临时脱开；关闭时短按 B 保持右键。
    public var gyroMouseClutchEnabled: Bool?

    public init(pairedPeripheralID: String? = nil,
                pairedName: String? = nil,
                targetDeviceIDs: [String] = [],
                activeTargetIndex: Int = 0,
                homeAssistantEntityIDs: [String]? = nil,
                buzzerEnabled: Bool? = true,
                macShortcuts: [M5MacShortcut]? = nil,
                mediaControlsEnabled: Bool? = true,
                gyroMouseEnabled: Bool? = true,
                gyroMouseSensitivity: Double? = 1.0,
                gyroMouseDeadZone: Double? = 1.4,
                gyroMouseSmoothing: Double? = 0.58,
                gyroMouseInvertX: Bool? = false,
                gyroMouseInvertY: Bool? = false,
                gyroMouseClutchEnabled: Bool? = false) {
        self.pairedPeripheralID = pairedPeripheralID
        self.pairedName = pairedName
        self.targetDeviceIDs = targetDeviceIDs
        self.activeTargetIndex = activeTargetIndex
        self.homeAssistantEntityIDs = homeAssistantEntityIDs
        self.buzzerEnabled = buzzerEnabled
        self.macShortcuts = macShortcuts ?? Self.defaultMacShortcuts
        self.mediaControlsEnabled = mediaControlsEnabled
        self.gyroMouseEnabled = gyroMouseEnabled
        self.gyroMouseSensitivity = gyroMouseSensitivity
        self.gyroMouseDeadZone = gyroMouseDeadZone
        self.gyroMouseSmoothing = gyroMouseSmoothing
        self.gyroMouseInvertX = gyroMouseInvertX
        self.gyroMouseInvertY = gyroMouseInvertY
        self.gyroMouseClutchEnabled = gyroMouseClutchEnabled
        clamp()
    }

    public var resolvedBuzzerEnabled: Bool { buzzerEnabled ?? true }
    public var resolvedMediaControlsEnabled: Bool { mediaControlsEnabled ?? true }
    public var resolvedGyroMouseEnabled: Bool { gyroMouseEnabled ?? true }
    public var resolvedGyroMouseSensitivity: Double { gyroMouseSensitivity ?? 1.0 }
    public var resolvedGyroMouseDeadZone: Double { gyroMouseDeadZone ?? 1.4 }
    public var resolvedGyroMouseSmoothing: Double { gyroMouseSmoothing ?? 0.58 }
    public var resolvedGyroMouseInvertX: Bool { gyroMouseInvertX ?? false }
    public var resolvedGyroMouseInvertY: Bool { gyroMouseInvertY ?? false }
    public var resolvedGyroMouseClutchEnabled: Bool { gyroMouseClutchEnabled ?? false }
    public var resolvedMacShortcuts: [M5MacShortcut] {
        macShortcuts ?? Self.defaultMacShortcuts
    }

    public static let defaultMacShortcuts: [M5MacShortcut] = [
        .init(id: "presentation.previous", group: .presentation, name: "上一页",
              shortcut: .init(keyCode: 123, modifiers: 0)),
        .init(id: "presentation.next", group: .presentation, name: "下一页",
              shortcut: .init(keyCode: 124, modifiers: 0)),
        .init(id: "presentation.start", group: .presentation, name: "开始演示",
              shortcut: .init(keyCode: 36, modifiers: GlobalShortcut.cmdKey | GlobalShortcut.shiftKey)),
        .init(id: "vibe.voice", group: .vibeCoding, name: "语音输入",
              shortcut: .init(keyCode: 49, modifiers: GlobalShortcut.controlKey | GlobalShortcut.optionKey)),
        .init(id: "vibe.submit", group: .vibeCoding, name: "提交内容",
              shortcut: .init(keyCode: 36, modifiers: GlobalShortcut.cmdKey)),
        .init(id: "vibe.stop", group: .vibeCoding, name: "停止生成",
              shortcut: .init(keyCode: 53, modifiers: 0))
    ]

    public mutating func clamp() {
        targetDeviceIDs = Self.uniqueNonEmpty(targetDeviceIDs)
        homeAssistantEntityIDs = Self.uniqueNonEmpty(homeAssistantEntityIDs ?? [])
        buzzerEnabled = buzzerEnabled ?? true
        mediaControlsEnabled = mediaControlsEnabled ?? true
        gyroMouseEnabled = gyroMouseEnabled ?? true
        gyroMouseSensitivity = min(max(resolvedGyroMouseSensitivity, 0.35), 2.5)
        gyroMouseDeadZone = min(max(resolvedGyroMouseDeadZone, 0.4), 4.0)
        gyroMouseSmoothing = min(max(resolvedGyroMouseSmoothing, 0.0), 0.85)
        gyroMouseInvertX = gyroMouseInvertX ?? false
        gyroMouseInvertY = gyroMouseInvertY ?? false
        gyroMouseClutchEnabled = gyroMouseClutchEnabled ?? false
        var seenShortcutIDs = Set<String>()
        macShortcuts = resolvedMacShortcuts.compactMap { item in
            var cleaned = item
            cleaned.id = cleaned.id.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.name = String(cleaned.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            cleaned.shortcut = cleaned.shortcut.clamped()
            guard !cleaned.id.isEmpty, !cleaned.name.isEmpty,
                  seenShortcutIDs.insert(cleaned.id).inserted else { return nil }
            return cleaned
        }
        activeTargetIndex = targetDeviceIDs.isEmpty
            ? 0 : min(max(activeTargetIndex, 0), targetDeviceIDs.count - 1)
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }
}

public struct HAServiceCommand: Equatable, Sendable {
    public var domain: String
    public var service: String
    public var entityID: String
    /// cover.set_cover_position 使用；0=完全关闭，100=完全打开。
    public var position: Int?

    public init(domain: String, service: String, entityID: String,
                position: Int? = nil) {
        self.domain = domain
        self.service = service
        self.entityID = entityID
        self.position = position.map { min(max($0, 0), 100) }
    }
}

/// StickS3 的 Home Assistant 控制白名单与按键映射。没有列出的域只读、不执行服务。
public enum M5HAControlPolicy {
    public static let supportedDomains: Set<String> = [
        "switch", "light", "fan", "input_boolean", "automation",
        "cover", "lock", "scene", "script", "button", "input_button",
        "media_player", "climate", "vacuum"
    ]

    public static func isControllable(_ entity: HAEntity) -> Bool {
        supportedDomains.contains(entity.domain)
    }

    /// A 长按：按当前状态执行最自然的主操作。
    public static func primaryCommand(for entity: HAEntity) -> HAServiceCommand? {
        let state = entity.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let service: String
        switch entity.domain {
        case "switch", "light", "fan", "input_boolean", "automation", "climate":
            service = state == "on" || !["off", "unavailable", "unknown"].contains(state)
                ? "turn_off" : "turn_on"
        case "cover":
            // 一部分窗帘集成的 open_cover / close_cover 只触发短脉冲或语义相反；
            // 明确写入端点位置更稳定，也让短按确认表现为真正的 0% / 100% 切换。
            return HAServiceCommand(
                domain: entity.domain,
                service: "set_cover_position",
                entityID: entity.entityId,
                position: ["closed", "closing"].contains(state) ? 100 : 0)
        case "lock":
            service = state == "locked" ? "unlock" : "lock"
        case "scene", "script": service = "turn_on"
        case "button", "input_button": service = "press"
        case "media_player": service = "media_play_pause"
        case "vacuum":
            service = ["docked", "idle", "paused"].contains(state) ? "start" : "return_to_base"
        default: return nil
        }
        return HAServiceCommand(domain: entity.domain, service: service,
                                entityID: entity.entityId)
    }

    /// HA 页面摇晃：右/正方向开启、打开或播放；左/负方向关闭、暂停或回充。
    public static func directionalCommand(for entity: HAEntity,
                                          direction: Int) -> HAServiceCommand? {
        let positive = direction >= 0
        let service: String
        switch entity.domain {
        case "switch", "light", "fan", "input_boolean", "automation", "climate":
            service = positive ? "turn_on" : "turn_off"
        case "cover":
            return HAServiceCommand(
                domain: entity.domain,
                service: "set_cover_position",
                entityID: entity.entityId,
                position: positive ? 100 : 0)
        case "media_player": service = positive ? "media_play" : "media_pause"
        case "vacuum": service = positive ? "start" : "return_to_base"
        default: return nil
        }
        return HAServiceCommand(domain: entity.domain, service: service,
                                entityID: entity.entityId)
    }
}
