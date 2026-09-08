import Foundation

/// 首次使用入口判定。正式发布的全新配置必须没有任何设备，界面据此直接显示设备添加引导。
public enum DeviceOnboardingPolicy {
    public static func shouldShow(for devices: [ManagedDevice]) -> Bool {
        devices.isEmpty
    }
}

/// 多设备编排（放在 Core 以便冒烟测试直接覆盖真实逻辑）：
/// 每台设备一份 `DeviceSettings` 快照，全局 `AppSettings` 字段只是「当前活动设备」的镜像。
///
/// 两条铁律：
/// 1. 写设备快照前必须先写全局镜像（或整体套用快照），否则任何一次设置变更都会触发
///    `captureActiveDeviceSnapshots()` 用旧镜像重建活动设备快照，把刚写的值清回去；
/// 2. 切换设备 = 先把镜像存回旧设备快照，再套用新设备快照，顺序不能颠倒；
///    期间屏蔽 onChange 的自动存回，避免新设备快照被旧设备的镜像值污染（多设备互相干扰的根因）。
extension AppSettings {
    /// 各设备类型的数量上限（未列出的类型不限）：
    /// Home Assistant 只允许一个实例；Bambu Lab 打印机最多 5 台（对应 5 张独立卡片位）
    public static let deviceLimits: [DeviceType: Int] = Dictionary(uniqueKeysWithValues:
        DeviceCapabilityRegistry.all.compactMap { profile in
            profile.maximumInstances.map { (profile.type, $0) }
        })

    /// 是否还能再添加该类型设备
    public func canAddDevice(of type: DeviceType) -> Bool {
        guard let limit = AppSettings.deviceLimits[type] else { return true }
        return devices(for: type).count < limit
    }

    /// 达到上限时的提示文案（nil = 未达上限）
    public func deviceLimitNotice(for type: DeviceType) -> String? {
        guard !canAddDevice(of: type) else { return nil }
        switch type {
        case .homeAssistant:
            return "只允许添加一个 Home Assistant 实例；如需更换服务器，请直接修改该设备的地址与长期访问令牌。"
        case .bambuLab:
            return "最多支持 5 台 Bambu Lab 打印机（对应 5 张独立卡片位）。"
        case .formlabs:
            return "最多支持 5 台 Formlabs 打印机（对应 5 张独立卡片位）。"
        case .aiMacScreen:
            return "最多支持 5 台 AI Mac 小屏幕。"
        default:
            return nil
        }
    }

    /// 某类型全部设备（含禁用；设备管理页需要显示以便重新启用）
    public func devices(for type: DeviceType) -> [ManagedDevice] {
        devices.filter { $0.type == type }
    }

    /// 某类型已启用设备（侧栏导航/目标选择只展示启用的设备）
    public func enabledDevices(for type: DeviceType) -> [ManagedDevice] {
        devices.filter { $0.type == type && $0.isEnabled }
    }

    /// 某类型当前活动设备 ID（原样返回，不做回退）
    public func activeDeviceID(for type: DeviceType) -> UUID? {
        switch type {
        case .keyboard: return activeKeyboardDeviceID
        case .oracle: return activeOracleDeviceID
        case .excerpt: return activeExcerptDeviceID
        case .homeAssistant: return activeHomeAssistantDeviceID
        case .bambuLab: return activeBambuLabDeviceID
        case .formlabs: return activeFormlabsDeviceID
        case .aiMacScreen: return activeAIMacScreenDeviceID
        }
    }

    /// 设置某类型活动设备 ID
    public func setActiveDeviceID(_ type: DeviceType, _ id: UUID?) {
        switch type {
        case .keyboard: activeKeyboardDeviceID = id
        case .oracle: activeOracleDeviceID = id
        case .excerpt: activeExcerptDeviceID = id
        case .homeAssistant: activeHomeAssistantDeviceID = id
        case .bambuLab: activeBambuLabDeviceID = id
        case .formlabs: activeFormlabsDeviceID = id
        case .aiMacScreen: activeAIMacScreenDeviceID = id
        }
    }

    /// 某类型当前活动设备（按活动 ID，回退该类第一台已启用设备；全部禁用时为 nil）
    public func activeDevice(for type: DeviceType) -> ManagedDevice? {
        let list = enabledDevices(for: type)
        guard !list.isEmpty else { return nil }
        let id = activeDeviceID(for: type)
        return list.first { $0.id == id } ?? list[0]
    }

    /// 把当前镜像存回各类型活动设备的快照（任意设置变更后据此记住该设备的设置）
    public func captureActiveDeviceSnapshots() {
        guard !devices.isEmpty else { return }
        for type in DeviceType.allCases {
            guard let device = activeDevice(for: type),
                  let index = devices.firstIndex(where: { $0.id == device.id }) else { continue }
            // Formlabs 没有全局镜像：连接配置在设备快照里直接编辑，不能用空 capture 覆盖。
            if type == .formlabs || type == .aiMacScreen { continue }
            devices[index].settings = DeviceSettings.capture(from: self, type: type)
        }
    }

    /// 切换某类型的活动设备：存回旧设备 → 记新活动 ID → 套用新设备快照 → 结果定型回新设备。
    /// 目标不存在或已是当前活动设备时返回 nil（不做任何改动）。
    /// 全程置 deviceSyncInFlight，屏蔽 onChange 的中途「镜像→快照」回写，
    /// 否则新设备快照会在套用前被旧设备的镜像值整体覆盖（另一台设备的设置就此串进来）。
    @discardableResult
    public func switchActiveDevice(of type: DeviceType, to id: UUID?) -> ManagedDevice? {
        guard let target = devices.first(where: { $0.type == type && $0.id == id })
                ?? devices.first(where: { $0.type == type }) else { return nil }
        guard activeDeviceID(for: type) != target.id else { return nil }
        deviceSyncInFlight = true
        defer { deviceSyncInFlight = false }
        captureActiveDeviceSnapshots()               // 1. 旧设备的镜像存回它自己的快照
        setActiveDeviceID(type, target.id)           // 2. 活动设备切到目标
        target.settings.apply(to: self, type: type)  // 3. 目标快照套用到镜像
        captureActiveDeviceSnapshots()               // 4. 套用结果定型回目标快照
        return target
    }

    /// 某台键盘的侧栏可见卡片 rawValue 列表（只读这台设备自己的快照，另一台键盘不可能提供数据）。
    /// - 快照为 nil（旧档案未补齐）时回退调用方给的 fallback 列表；
    /// - Bambu 卡片位只在对应序号的打印机设备存在时保留（设备↔卡片绑定：删除设备即消失）。
    public func keyboardCardPanelRawValues(for deviceID: UUID, fallback: [String]) -> [String] {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return [] }
        let printerCount = enabledDevices(for: .bambuLab).count
        let formlabsCount = enabledDevices(for: .formlabs).count
        let stored = device.settings.keyboardCardPanels ?? fallback
        return stored.filter { raw in
            if let slot = Self.bambuSlotIndex(in: raw) { return slot < printerCount }
            if let slot = Self.formlabsSlotIndex(in: raw) { return slot < formlabsCount }
            return true
        }
    }

    /// 键盘卡片名对应的 Bambu 卡片位序号（0 起；非打印机卡片返回 nil）
    static func bambuSlotIndex(in raw: String) -> Int? {
        switch raw {
        case "bambuLab": return 0
        case "bambuLab2": return 1
        case "bambuLab3": return 2
        case "bambuLab4": return 3
        case "bambuLab5": return 4
        default: return nil
        }
    }

    static func formlabsSlotIndex(in raw: String) -> Int? {
        switch raw {
        case "formlabs": return 0
        case "formlabs2": return 1
        case "formlabs3": return 2
        case "formlabs4": return 3
        case "formlabs5": return 4
        default: return nil
        }
    }
}
