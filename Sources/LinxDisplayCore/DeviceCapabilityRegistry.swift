import Foundation

public enum DisplayColorCapability: String, Codable {
    case fullColor
    case grayscale
    case monochrome
    case dataSource
}

public enum DeviceTransportKind: String, Codable {
    case localHTTPImage
    case localWebSocket
    case cloudImageAPI
    case cloudDataAPI
    case sharedDataSource
}

public struct DisplayPixelSize: Codable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// 一类设备的稳定能力描述。导航与业务层可以询问能力，而不是用设备名称猜测行为。
public struct DeviceCapabilityProfile: Identifiable, Equatable {
    public let type: DeviceType
    public let icon: String
    public let maximumInstances: Int?
    public let screenSize: DisplayPixelSize?
    public let colorCapability: DisplayColorCapability
    public let transport: DeviceTransportKind
    public let cardSurface: CardSurface?
    public let supportsMultipleBoards: Bool

    public var id: Int { type.rawValue }

    public init(type: DeviceType, icon: String, maximumInstances: Int? = nil,
                screenSize: DisplayPixelSize? = nil,
                colorCapability: DisplayColorCapability,
                transport: DeviceTransportKind,
                cardSurface: CardSurface? = nil,
                supportsMultipleBoards: Bool = false) {
        self.type = type
        self.icon = icon
        self.maximumInstances = maximumInstances
        self.screenSize = screenSize
        self.colorCapability = colorCapability
        self.transport = transport
        self.cardSurface = cardSurface
        self.supportsMultipleBoards = supportsMultipleBoards
    }
}

/// 设备能力目录。新增硬件时在此登记一次，数量限制、屏幕规格、卡片兼容性与
/// 传输语义即可被设备管理和渲染编排共同读取。
public enum DeviceCapabilityRegistry {
    public static let all: [DeviceCapabilityProfile] = [
        .init(type: .keyboard, icon: "keyboard", screenSize: .init(width: 142, height: 428),
              colorCapability: .fullColor, transport: .localHTTPImage,
              cardSurface: .keyboard, supportsMultipleBoards: false),
        .init(type: .oracle, icon: "sparkles", screenSize: .init(width: 200, height: 200),
              colorCapability: .grayscale, transport: .localWebSocket,
              supportsMultipleBoards: true),
        .init(type: .excerpt, icon: "quote.opening", screenSize: .init(width: 296, height: 152),
              colorCapability: .grayscale, transport: .cloudImageAPI,
              supportsMultipleBoards: true),
        .init(type: .homeAssistant, icon: "house", maximumInstances: 1,
              colorCapability: .dataSource, transport: .sharedDataSource),
        .init(type: .bambuLab, icon: "printer", maximumInstances: 5,
              colorCapability: .dataSource, transport: .sharedDataSource),
        .init(type: .formlabs, icon: "printer", maximumInstances: 5,
              colorCapability: .dataSource, transport: .cloudDataAPI),
        .init(type: .aiMacScreen, icon: "display", maximumInstances: 5,
              screenSize: .init(width: 240, height: 240),
              colorCapability: .fullColor, transport: .localHTTPImage,
              cardSurface: .colorSquare, supportsMultipleBoards: true)
    ]

    private static let byType = Dictionary(uniqueKeysWithValues: all.map { ($0.type, $0) })

    public static func profile(for type: DeviceType) -> DeviceCapabilityProfile? { byType[type] }
}

public extension DeviceType {
    var capabilityProfile: DeviceCapabilityProfile? {
        DeviceCapabilityRegistry.profile(for: self)
    }
}
