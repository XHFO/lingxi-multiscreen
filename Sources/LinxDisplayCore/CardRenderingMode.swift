import Foundation

/// 彩色屏幕卡片的全局渲染风格；墨水屏与设备端桌面时钟保持各自的渲染方式。
public enum CardRenderingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case classic
    case liquidGlass

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .classic: return String(localized: "经典")
        case .liquidGlass: return "Liquid Glass"
        }
    }

    /// 仅完整彩色屏幕可使用这组外观选项；数据源设备没有可渲染屏幕。
    public static func supports(_ deviceType: DeviceType) -> Bool {
        guard let profile = DeviceCapabilityRegistry.profile(for: deviceType) else { return false }
        return profile.colorCapability == .fullColor && profile.cardSurface != nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try? container.decode(String.self)
        self = rawValue.flatMap(Self.init(rawValue:)) ?? .classic
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
