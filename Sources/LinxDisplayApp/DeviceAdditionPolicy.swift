/// 发现只提供添加建议，不自动创建档案或连接设备。
enum DeviceAdditionPolicy {
    enum Route: Equatable {
        case unavailable
        case manual
        case discovered
        case chooseDevice
    }

    static func route(canAdd: Bool, discoveredCount: Int) -> Route {
        guard canAdd else { return .unavailable }
        switch discoveredCount {
        case ...0: return .manual
        case 1: return .discovered
        default: return .chooseDevice
        }
    }
}
