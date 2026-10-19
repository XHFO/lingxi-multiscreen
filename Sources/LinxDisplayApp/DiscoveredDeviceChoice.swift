import LinxDisplayCore

/// 已识别的物理设备。只有用户选择卡片后才写入设备设置。
enum DiscoveredDeviceChoice: Identifiable {
    case homeAssistant(HomeAssistantDiscoveredService)
    case oracle(Rand0DiscoveredDevice)
    case aiMacScreen(AIMacDiscoveredDevice)
    case controller(M5DiscoveredController)

    var id: String {
        switch self {
        case .homeAssistant(let device): return "ha:\(device.id)"
        case .oracle(let device): return "oracle:\(device.id)"
        case .aiMacScreen(let device): return "screen:\(device.id)"
        case .controller(let device): return "controller:\(device.id)"
        }
    }

    var name: String {
        switch self {
        case .homeAssistant(let device): return device.name
        case .oracle(let device): return device.displayName
        case .aiMacScreen(let device): return device.displayName
        case .controller(let device): return device.name
        }
    }

    var detail: String {
        switch self {
        case .homeAssistant(let device): return device.serverURL
        case .oracle(let device): return device.ip
        case .aiMacScreen(let device): return "\(device.ip) · 固件 \(device.firmwareVersion)"
        case .controller(let device): return device.id.uuidString
        }
    }
}
