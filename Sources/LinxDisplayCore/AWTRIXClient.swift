import CoreFoundation
import CoreGraphics
import Foundation

/// AWTRIX NG 的连接、卡片与显示设置。显示内容由多屏灵犀直接发送到设备。
public struct AWTRIXSettings: Codable, Equatable, Sendable {
    public var baseURL = ""
    public var username = ""
    public var password = ""
    public var appName = "lingxi_text"
    public var text = "欢迎回家"
    public var foregroundHex = "#FFFFFF"
    public var backgroundHex = "#000000"
    /// `Solid` 表示使用前景色；其他值直接对应设备内置或 /PALETTES 下的调色板名。
    public var palette = "Solid"
    /// 本地调色板原始行（RRGGBB 或 RRGGBB@位置），用于离线预览和生成中文点阵。
    public var paletteEntries: [String] = []
    public var paletteBlend = true
    public var paletteSpan = 0
    public var paletteSpeed = 0.0
    /// 空字符串表示关闭灯光预设；其他值来自设备 capabilities.effects。
    public var effect = ""
    public var effectSpeed = 1.0
    public var durationSeconds = 10
    public var scrollSpeedMilliseconds = 90
    public var brightness = 60
    public var autoBrightness = false
    public var autoBrightnessMinimum = 5
    public var autoBrightnessMaximum = 120
    public var autoTransition = true
    public var appDurationSeconds = 7
    public var transitionEffect = "Reload"
    public var transitionDurationMilliseconds = 700
    public var lastUploadedIcon: String?
    /// nil 表示沿用旧版的已发现应用；空数组表示尚未添加任何卡片。
    public var sidebarAppNames: [String]? = []
    public var homeAssistant = AWTRIXHomeAssistantSettings()
    public var manualDisplaySession: AWTRIXManualDisplaySession?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case baseURL, username, password, appName, text, foregroundHex, backgroundHex
        case palette, paletteEntries, paletteBlend, paletteSpan, paletteSpeed
        case effect, effectSpeed, durationSeconds, scrollSpeedMilliseconds
        case brightness, autoBrightness, autoBrightnessMinimum, autoBrightnessMaximum
        case autoTransition, appDurationSeconds, transitionEffect
        case transitionDurationMilliseconds, lastUploadedIcon
        case sidebarAppNames, homeAssistant, manualDisplaySession
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? username
        password = try values.decodeIfPresent(String.self, forKey: .password) ?? password
        appName = try values.decodeIfPresent(String.self, forKey: .appName) ?? appName
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? text
        foregroundHex = try values.decodeIfPresent(String.self, forKey: .foregroundHex) ?? foregroundHex
        backgroundHex = try values.decodeIfPresent(String.self, forKey: .backgroundHex) ?? backgroundHex
        palette = try values.decodeIfPresent(String.self, forKey: .palette) ?? palette
        paletteEntries = try values.decodeIfPresent([String].self, forKey: .paletteEntries) ?? []
        paletteBlend = try values.decodeIfPresent(Bool.self, forKey: .paletteBlend) ?? paletteBlend
        paletteSpan = try values.decodeIfPresent(Int.self, forKey: .paletteSpan) ?? paletteSpan
        paletteSpeed = try values.decodeIfPresent(Double.self, forKey: .paletteSpeed) ?? paletteSpeed
        effect = try values.decodeIfPresent(String.self, forKey: .effect) ?? effect
        effectSpeed = try values.decodeIfPresent(Double.self, forKey: .effectSpeed) ?? effectSpeed
        durationSeconds = try values.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? durationSeconds
        scrollSpeedMilliseconds = try values.decodeIfPresent(Int.self, forKey: .scrollSpeedMilliseconds) ?? scrollSpeedMilliseconds
        brightness = try values.decodeIfPresent(Int.self, forKey: .brightness) ?? brightness
        autoBrightness = try values.decodeIfPresent(Bool.self, forKey: .autoBrightness) ?? autoBrightness
        autoBrightnessMinimum = try values.decodeIfPresent(Int.self, forKey: .autoBrightnessMinimum) ?? autoBrightnessMinimum
        autoBrightnessMaximum = try values.decodeIfPresent(Int.self, forKey: .autoBrightnessMaximum) ?? autoBrightnessMaximum
        autoTransition = try values.decodeIfPresent(Bool.self, forKey: .autoTransition) ?? autoTransition
        appDurationSeconds = try values.decodeIfPresent(Int.self, forKey: .appDurationSeconds) ?? appDurationSeconds
        transitionEffect = try values.decodeIfPresent(String.self, forKey: .transitionEffect) ?? transitionEffect
        transitionDurationMilliseconds = try values.decodeIfPresent(Int.self, forKey: .transitionDurationMilliseconds) ?? transitionDurationMilliseconds
        lastUploadedIcon = try values.decodeIfPresent(String.self, forKey: .lastUploadedIcon)
        // 老配置没有此字段时保留原有入口，新设备则使用显式的空卡片列表。
        sidebarAppNames = try values.decodeIfPresent([String].self, forKey: .sidebarAppNames)
        homeAssistant = try values.decodeIfPresent(AWTRIXHomeAssistantSettings.self,
                                                   forKey: .homeAssistant) ?? homeAssistant
        manualDisplaySession = try values.decodeIfPresent(AWTRIXManualDisplaySession.self,
                                                          forKey: .manualDisplaySession)
        sanitize()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encode(username, forKey: .username)
        try values.encode(password, forKey: .password)
        try values.encode(appName, forKey: .appName)
        try values.encode(text, forKey: .text)
        try values.encode(foregroundHex, forKey: .foregroundHex)
        try values.encode(backgroundHex, forKey: .backgroundHex)
        try values.encode(palette, forKey: .palette)
        try values.encode(paletteEntries, forKey: .paletteEntries)
        try values.encode(paletteBlend, forKey: .paletteBlend)
        try values.encode(paletteSpan, forKey: .paletteSpan)
        try values.encode(paletteSpeed, forKey: .paletteSpeed)
        try values.encode(effect, forKey: .effect)
        try values.encode(effectSpeed, forKey: .effectSpeed)
        try values.encode(durationSeconds, forKey: .durationSeconds)
        try values.encode(scrollSpeedMilliseconds, forKey: .scrollSpeedMilliseconds)
        try values.encode(brightness, forKey: .brightness)
        try values.encode(autoBrightness, forKey: .autoBrightness)
        try values.encode(autoBrightnessMinimum, forKey: .autoBrightnessMinimum)
        try values.encode(autoBrightnessMaximum, forKey: .autoBrightnessMaximum)
        try values.encode(autoTransition, forKey: .autoTransition)
        try values.encode(appDurationSeconds, forKey: .appDurationSeconds)
        try values.encode(transitionEffect, forKey: .transitionEffect)
        try values.encode(transitionDurationMilliseconds, forKey: .transitionDurationMilliseconds)
        try values.encodeIfPresent(lastUploadedIcon, forKey: .lastUploadedIcon)
        try values.encodeIfPresent(sidebarAppNames, forKey: .sidebarAppNames)
        try values.encode(homeAssistant, forKey: .homeAssistant)
        try values.encodeIfPresent(manualDisplaySession, forKey: .manualDisplaySession)
    }

    public mutating func sanitize() {
        baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        appName = AWTRIXClient.validatedAppName(appName) ?? "lingxi_text"
        foregroundHex = AWTRIXBitmapRenderer.normalizedHex(foregroundHex) ?? "#FFFFFF"
        backgroundHex = AWTRIXBitmapRenderer.normalizedHex(backgroundHex) ?? "#000000"
        palette = palette.trimmingCharacters(in: .whitespacesAndNewlines)
        if palette.isEmpty { palette = "Solid" }
        effect = effect.trimmingCharacters(in: .whitespacesAndNewlines)
        paletteSpan = min(max(paletteSpan, 0), 1_024)
        paletteSpeed = min(max(paletteSpeed, 0), 10)
        effectSpeed = min(max(effectSpeed, 0.1), 10)
        durationSeconds = min(max(durationSeconds, 1), 3_600)
        scrollSpeedMilliseconds = min(max(scrollSpeedMilliseconds, 40), 500)
        brightness = min(max(brightness, 1), AWTRIXClient.safeBrightnessLimit)
        autoBrightnessMinimum = min(max(autoBrightnessMinimum, 1), AWTRIXClient.safeBrightnessLimit)
        autoBrightnessMaximum = min(max(autoBrightnessMaximum, autoBrightnessMinimum),
                                    AWTRIXClient.safeBrightnessLimit)
        appDurationSeconds = min(max(appDurationSeconds, 1), 600)
        transitionDurationMilliseconds = min(max(transitionDurationMilliseconds, 0), 5_000)
        if let names = sidebarAppNames {
            var seen = Set<String>()
            sidebarAppNames = names.compactMap { raw in
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return !name.isEmpty && seen.insert(name).inserted ? name : nil
            }
        }
        homeAssistant.sanitize()
    }
}

/// 为每台 AWTRIX 独立签发单调递增的显示请求代次。调用方用它判断异步结果
/// 是否仍是用户最后一次选择；一台设备的新请求不会取消或覆盖另一台设备。
public struct AWTRIXLatestDisplayRequestPolicy: Sendable {
    private var generations: [UUID: UInt64] = [:]

    public init() {}

    @discardableResult
    public mutating func issue(for deviceID: UUID) -> UInt64 {
        let generation = (generations[deviceID] ?? 0) &+ 1
        generations[deviceID] = generation
        return generation
    }

    public func isCurrent(_ generation: UInt64, for deviceID: UUID) -> Bool {
        generations[deviceID] == generation
    }

    public func currentGeneration(for deviceID: UUID) -> UInt64? {
        generations[deviceID]
    }

    public mutating func remove(_ deviceID: UUID) {
        generations[deviceID] = nil
    }
}

public struct AWTRIXAppMetadata: Decodable, Equatable, Sendable {
    public var name: String?
    public var desc: String?
    public var author: String?
    public var version: String?
}

public struct AWTRIXAppInfo: Decodable, Equatable, Identifiable, Sendable {
    public var name: String
    public var enabled: Bool?
    public var inLoop: Bool?
    public var slot: Int?
    public var present: Bool?
    public var origin: String?
    public var icon: String?
    public var skipped: Bool?
    public var headless: Bool?
    public var config: Bool?
    public var meta: AWTRIXAppMetadata?

    public var id: String { slot.map { "\(name)#\($0)" } ?? name }
    public var title: String {
        // 多屏灵犀推送的中文点阵应用在设备 API 中使用稳定的内部名，
        // 界面统一显示产品名称，避免和“中文点阵文字”形成两个入口。
        if name.caseInsensitiveCompare("lingxi_text") == .orderedSame {
            return "灵犀文字"
        }
        if name.caseInsensitiveCompare(AWTRIXCardPolicy.homeAssistantAppName) == .orderedSame {
            return "Home Assistant"
        }
        let display = meta?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return display.isEmpty ? name : display
    }
    public var isManageable: Bool { enabled != nil && origin != "module" }
    public var hasConfiguration: Bool { config == true }

    /// 侧边栏按独立应用展示，而不是照抄可能包含重复轮换槽位的运行列表。
    /// 已停用但仍安装的应用也应保留，方便用户从侧边栏重新启用或修改设置。
    public static func sidebarApps(from apps: [AWTRIXAppInfo]) -> [AWTRIXAppInfo] {
        var names = Set<String>()
        return apps.filter { app in
            let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, app.origin != "module", app.headless != true,
                  app.present != false, names.insert(app.name).inserted else { return false }
            return true
        }
    }
}

/// AWTRIX 脚本应用的配置值。固件目前主要返回标量，但保留数组与对象，
/// 这样将来新增字段类型时不会让整个配置页面解码失败。
public indirect enum AWTRIXJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case array([AWTRIXJSONValue])
    case object([String: AWTRIXJSONValue])
    case null

    public static func == (lhs: AWTRIXJSONValue, rhs: AWTRIXJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let lhs), .string(let rhs)): return lhs == rhs
        case (.integer(let lhs), .integer(let rhs)): return lhs == rhs
        case (.number(let lhs), .number(let rhs)): return lhs == rhs
        // 表单控件通常以 Double 回写，即使固件最初以整数返回；数值相同不应
        // 让“保存设置”一直保持为有未保存修改。
        case (.integer(let lhs), .number(let rhs)): return Double(lhs) == rhs
        case (.number(let lhs), .integer(let rhs)): return lhs == Double(rhs)
        case (.bool(let lhs), .bool(let rhs)): return lhs == rhs
        case (.array(let lhs), .array(let rhs)): return lhs == rhs
        case (.object(let lhs), .object(let rhs)): return lhs == rhs
        case (.null, .null): return true
        default: return false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AWTRIXJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AWTRIXJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported AWTRIX configuration value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var numberValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        default: return nil
        }
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    fileprivate var foundationValue: Any {
        switch self {
        case .string(let value): return value
        case .integer(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .array(let value): return value.map(\.foundationValue)
        case .object(let value): return value.mapValues(\.foundationValue)
        case .null: return NSNull()
        }
    }
}

public struct AWTRIXConfigField: Decodable, Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case text
        case number
        case slider
        case bool
        case color
        case select
        case unsupported(String)
    }

    public let key: String
    /// 保留固件给出的原始类型，未知类型仍可显示为只读值。
    public let type: String
    public let label: String?
    public let help: String?
    public let unit: String?
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let defaultValue: AWTRIXJSONValue?
    public let value: AWTRIXJSONValue?
    public let options: [AWTRIXJSONValue]

    public var id: String { key }
    public var displayLabel: String {
        let candidate = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? key : candidate
    }
    public var effectiveValue: AWTRIXJSONValue? { value ?? defaultValue }
    public var kind: Kind {
        switch type.lowercased() {
        case "text": return .text
        case "number": return .number
        case "slider": return .slider
        case "bool", "boolean": return .bool
        case "color": return .color
        case "select": return .select
        default: return .unsupported(type)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case key, type, label, help, unit, min, max, step, value, options
        case defaultValue = "default"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? "text"
        label = try values.decodeIfPresent(String.self, forKey: .label)
        help = try values.decodeIfPresent(String.self, forKey: .help)
        unit = try values.decodeIfPresent(String.self, forKey: .unit)
        min = try values.decodeIfPresent(Double.self, forKey: .min)
        max = try values.decodeIfPresent(Double.self, forKey: .max)
        step = try values.decodeIfPresent(Double.self, forKey: .step)
        defaultValue = try values.decodeIfPresent(AWTRIXJSONValue.self, forKey: .defaultValue)
        value = try values.decodeIfPresent(AWTRIXJSONValue.self, forKey: .value)
        options = try values.decodeIfPresent([AWTRIXJSONValue].self, forKey: .options) ?? []
    }
}

public struct AWTRIXAppConfiguration: Decodable, Equatable, Sendable {
    public let name: String
    public let fields: [AWTRIXConfigField]
    public let warnings: [String]

    private enum CodingKeys: String, CodingKey { case name, fields, warnings }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        fields = try values.decodeIfPresent([AWTRIXConfigField].self, forKey: .fields) ?? []
        warnings = try values.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

/// `/api/v1/display/screen` 返回的实时 32×8 像素帧，颜色格式为 0xRRGGBB。
public struct AWTRIXDisplayFrame: Decodable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt32]

    public var isValid: Bool {
        guard (1...256).contains(width), (1...256).contains(height),
              width <= 65_536 / height else { return false }
        return pixels.count == width * height && pixels.allSatisfy { $0 <= 0xFF_FF_FF }
    }

    public func pixel(x: Int, y: Int) -> UInt32? {
        guard isValid, (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        return pixels[y * width + x]
    }

    /// 生成无插值的原始像素图；界面缩放时应继续关闭插值以保留点阵效果。
    public func makeImage() -> CGImage? {
        guard isValid else { return nil }
        var rgba = [UInt8](repeating: 255, count: pixels.count * 4)
        for (index, color) in pixels.enumerated() {
            rgba[index * 4] = UInt8((color >> 16) & 0xFF)
            rgba[index * 4 + 1] = UInt8((color >> 8) & 0xFF)
            rgba[index * 4 + 2] = UInt8(color & 0xFF)
        }
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: [.byteOrder32Big,
                                    CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)],
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

public struct AWTRIXCapabilities: Decodable, Equatable, Sendable {
    public var effects: [String]
    public var palettes: [String]
    public var paletteEffects: [String]
    public var overlays: [String]
    public var transitions: [String]

    public init(effects: [String] = [], palettes: [String] = [],
                paletteEffects: [String] = [], overlays: [String] = [],
                transitions: [String] = []) {
        self.effects = effects
        self.palettes = palettes
        self.paletteEffects = paletteEffects
        self.overlays = overlays
        self.transitions = transitions
    }
}

public struct AWTRIXDeviceState: Decodable, Equatable, Sendable {
    public var version: String?
    public var uid: String?
    public var ipAddress: String?
    public var hostname: String?
    public var wifiRssi: Int?
    public var uptimeSeconds: Int?
    public var brightness: Int?
    public var matrixPower: Bool?
    public var currentApp: String?
    public var lightLevel: Double?
    public var ldrRaw: Int?
}

public struct AWTRIXRuntimeSettings: Decodable, Equatable, Sendable {
    public var autoBrightness: Bool?
    public var brightness: Int?
    public var autoTransition: Bool?
    public var appDurationMs: Int?
    public var transitionEffect: String?
    public var transitionDurationMs: Int?
}

public struct AWTRIXSystemSettings: Decodable, Equatable, Sendable {
    public var minBrightness: Int?
    public var maxBrightness: Int?
}

public struct AWTRIXSnapshot: Equatable, Sendable {
    public let device: AWTRIXDeviceState
    public let settings: AWTRIXRuntimeSettings
    public let system: AWTRIXSystemSettings
    public let apps: [AWTRIXAppInfo]
    public let capabilities: AWTRIXCapabilities
    public let paletteDefinitions: [String: [String]]

    public init(device: AWTRIXDeviceState,
                settings: AWTRIXRuntimeSettings,
                system: AWTRIXSystemSettings,
                apps: [AWTRIXAppInfo] = [],
                capabilities: AWTRIXCapabilities = AWTRIXCapabilities(),
                paletteDefinitions: [String: [String]] = [:]) {
        self.device = device
        self.settings = settings
        self.system = system
        self.apps = apps
        self.capabilities = capabilities
        self.paletteDefinitions = paletteDefinitions
    }
}

public enum AWTRIXError: LocalizedError {
    case invalidURL
    case invalidAppName
    case emptyText
    case missingFont(String)
    case invalidColor(String)
    case invalidResponse
    case requestFailed(Int, String)
    case appConfigurationFailed(String)
    case gifEncodingFailed
    case bitmapTextTooLong(Int)
    case textPayloadTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "AWTRIX 地址无效，请填写设备 IP 或 http:// 地址"
        case .invalidAppName: return "应用名称只能使用字母、数字、下划线或连字符，最长 32 个字符"
        case .emptyText: return "请输入要显示的文字"
        case .missingFont(let name): return "缺少 AWTRIX 中文点阵字库：\(name)"
        case .invalidColor(let value): return "颜色格式无效：\(value)"
        case .invalidResponse: return "AWTRIX 返回了无法识别的数据"
        case .requestFailed(let code, let message):
            return "AWTRIX 请求失败（HTTP \(code)）：\(message)"
        case .appConfigurationFailed(let message):
            return "AWTRIX 应用设置未能保存：\(message)"
        case .gifEncodingFailed: return "无法生成 32×8 点阵动画"
        case .bitmapTextTooLong(let limit): return "中文点阵最多支持 \(limit) 个字符，请缩短文字后重试"
        case .textPayloadTooLarge: return "文字内容超过设备容量，请缩短文字后重试"
        }
    }
}

/// AWTRIX NG HTTP API 客户端。只访问用户填写的局域网设备地址。
public final class AWTRIXClient: @unchecked Sendable {
    private struct FileListing: Decodable {
        struct Item: Decodable { let name: String }
        let files: [Item]
    }

    /// 这块灯板在更高亮度下会重启，因此软件在所有手动/自动路径上统一限幅。
    public static let safeBrightnessLimit = 120
    public static let transitionEffects = [
        "Random", "Slide", "Dim", "Zoom", "Rotate", "Pixelate", "Curtain",
        "Ripple", "Blink", "Reload", "Fade", "Cover", "Uncover", "Split",
        "Blinds", "Blocks", "Flash", "Diamond", "Wave", "Rain", "Melt", "Interlace"
    ]

    private let session: URLSession
    private let metadataCache = AWTRIXMetadataCache()

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            // MCU 的 HTTP 服务不能按桌面服务器的并发连接数压测。
            config.httpMaximumConnectionsPerHost = 1
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForResource = 16
            self.session = URLSession(configuration: config)
        }
    }

    public static func validatedAppName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32,
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122: return true
                  default: return scalar == "_" || scalar == "-"
                  }
              }) else { return nil }
        return trimmed
    }

    public func refresh(_ configuration: AWTRIXSettings) async throws -> AWTRIXSnapshot {
        let decoder = JSONDecoder()
        let device = try await fetchDevice(configuration)
        let apps = try await fetchApps(configuration)
        let settingsBytes = try? await request(configuration, path: "/api/v1/settings", timeout: 4)
        let runtime = (try? settingsBytes.map { try decoder.decode(AWTRIXRuntimeSettings.self, from: $0) })
            ?? AWTRIXRuntimeSettings()
        let systemBytes = try? await request(configuration, path: "/api/v1/system", timeout: 4)
        let system = (try? systemBytes.map { try decoder.decode(AWTRIXSystemSettings.self, from: $0) })
            ?? AWTRIXSystemSettings()
        try Task.checkCancellation()
        let key = configuration.baseURL + "|" + configuration.username
        var metadata = await metadataCache.get(key)
        if metadata == nil {
            let capabilityBytes = try? await request(configuration, path: "/api/v1/capabilities", timeout: 4)
            let decodedCapabilities = try? capabilityBytes.map { try decoder.decode(AWTRIXCapabilities.self, from: $0) }
            let capabilities = decodedCapabilities ?? AWTRIXCapabilities()
            let paletteBytes = try? await request(configuration, path: "/api/v1/files?dir=/PALETTES", timeout: 4)
            let decodedNames = try? paletteBytes.map { try decoder.decode(FileListing.self, from: $0).files.map(\.name) }
            let names = (decodedNames ?? []).filter { $0.lowercased().hasSuffix(".txt") }
            let definitions = await fetchPaletteDefinitions(names, configuration: configuration)
            try Task.checkCancellation()
            let value = AWTRIXMetadataCache.Entry(capabilities: capabilities, palettes: definitions)
            // 暂时缺少辅助端点时仍保留应用清单，下次刷新再补齐，不缓存失败。
            if decodedCapabilities != nil && decodedNames != nil && definitions.count == Set(names).count {
                await metadataCache.set(value, key: key)
            }
            metadata = value
        }
        return AWTRIXSnapshot(device: device, settings: runtime, system: system, apps: apps,
            capabilities: metadata?.capabilities ?? AWTRIXCapabilities(),
            paletteDefinitions: metadata?.palettes ?? [:])
    }

    public func fetchApps(_ configuration: AWTRIXSettings) async throws -> [AWTRIXAppInfo] {
        let data = try await request(configuration, path: "/api/v1/apps")
        return try JSONDecoder().decode([AWTRIXAppInfo].self, from: data)
    }

    public func fetchDevice(_ configuration: AWTRIXSettings) async throws -> AWTRIXDeviceState {
        let data = try await request(configuration, path: "/api/v1/device")
        return try JSONDecoder().decode(AWTRIXDeviceState.self, from: data)
    }

    public func setAutoTransition(_ enabled: Bool, configuration: AWTRIXSettings) async throws {
        _ = try await request(configuration, path: "/api/v1/settings", method: "PATCH",
                              json: ["autoTransition": enabled])
    }

    public func activateApp(_ name: String, fast: Bool = false,
                            configuration: AWTRIXSettings) async throws {
        _ = try await request(configuration, path: "/api/v1/apps/active", method: "PUT",
                              json: ["name": name, "fast": fast])
    }

    public func setAppOrder(_ order: [String], disabled: [String],
                            configuration: AWTRIXSettings) async throws {
        _ = try await request(configuration, path: "/api/v1/apps/order", method: "PUT",
                              json: ["order": order, "disabled": disabled])
    }

    public func fetchAppConfiguration(_ name: String,
                                      configuration: AWTRIXSettings) async throws
        -> AWTRIXAppConfiguration {
        let name = try validatedPathAppName(name)
        let data = try await request(configuration, path: "/api/v1/apps/\(name)/config")
        return try JSONDecoder().decode(AWTRIXAppConfiguration.self, from: data)
    }

    /// 仅发送用户实际修改的字段。固件会依据脚本声明的 schema 再做类型和范围校验。
    public func updateAppConfiguration(_ name: String,
                                       values: [String: AWTRIXJSONValue],
                                       configuration: AWTRIXSettings) async throws {
        guard !values.isEmpty else { return }
        let name = try validatedPathAppName(name)
        let payload = values.mapValues(\.foundationValue)
        let data = try await request(configuration, path: "/api/v1/apps/\(name)/config",
                                     method: "PATCH", json: payload)
        // AWTRIX NG 的脚本设置校验错误可能以 HTTP 200 + {"error": {...}}
        // 返回，不能仅凭状态码宣告保存成功。
        if let message = Self.appConfigurationError(from: data) {
            throw AWTRIXError.appConfigurationFailed(message)
        }
    }

    public func fetchDisplayFrame(_ configuration: AWTRIXSettings) async throws
        -> AWTRIXDisplayFrame {
        let data = try await request(configuration, path: "/api/v1/display/screen", timeout: 2)
        let frame = try JSONDecoder().decode(AWTRIXDisplayFrame.self, from: data)
        guard frame.isValid else { throw AWTRIXError.invalidResponse }
        return frame
    }

    public func setDisplayPower(_ power: Bool, configuration: AWTRIXSettings) async throws {
        _ = try await request(configuration, path: "/api/v1/display", method: "PATCH",
                              json: ["power": power])
    }

    public func applyDisplaySettings(_ value: AWTRIXSettings) async throws {
        var settings = value
        settings.sanitize()
        // 自动亮度也必须受相同的 120 安全上限约束，否则设备原始 220 上限仍可能触发重启。
        _ = try await request(settings, path: "/api/v1/system", method: "PUT", json: [
            "minBrightness": settings.autoBrightnessMinimum,
            "maxBrightness": settings.autoBrightnessMaximum
        ])
        _ = try await request(settings, path: "/api/v1/settings", method: "PATCH", json: [
            "autoBrightness": settings.autoBrightness,
            "brightness": min(settings.brightness, Self.safeBrightnessLimit),
            "autoTransition": settings.autoTransition,
            "appDurationMs": settings.appDurationSeconds * 1_000,
            "transitionEffect": settings.transitionEffect,
            "transitionDurationMs": settings.transitionDurationMilliseconds
        ])
    }

    @discardableResult
    public func showText(_ value: AWTRIXSettings, showNow: Bool = true) async throws -> String {
        var settings = value
        settings.sanitize()
        guard !settings.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AWTRIXError.emptyText
        }
        guard let appName = Self.validatedAppName(settings.appName) else {
            throw AWTRIXError.invalidAppName
        }
        let content = try await AWTRIXTextContent.prepare(settings)
        try Task.checkCancellation()
        if let gif = content.iconData {
            try await uploadIcon(gif, named: content.iconName, configuration: settings)
        }
        try Task.checkCancellation()
        _ = try await request(settings, path: "/api/v1/apps/pushed/\(appName)",
                              method: "PUT", body: content.payloadData, contentType: "application/json")
        if showNow {
            try await activateApp(appName, fast: true, configuration: settings)
        }
        return content.iconName
    }

    public func clearText(_ value: AWTRIXSettings) async throws {
        guard let appName = Self.validatedAppName(value.appName) else {
            throw AWTRIXError.invalidAppName
        }
        _ = try await request(value, path: "/api/v1/apps/\(appName)", method: "DELETE")
        if let icon = value.lastUploadedIcon, !icon.isEmpty {
            try? await deleteIcon(icon, configuration: value)
        }
    }

    public func deleteIcon(_ name: String, configuration: AWTRIXSettings) async throws {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        _ = try await request(configuration,
                              path: "/api/v1/files?path=/ICONS/\(encoded).gif",
                              method: "DELETE")
    }

    public func nextApp(_ value: AWTRIXSettings) async throws {
        _ = try await request(value, path: "/api/v1/apps/next", method: "POST")
    }

    public func previousApp(_ value: AWTRIXSettings) async throws {
        _ = try await request(value, path: "/api/v1/apps/previous", method: "POST")
    }

    private func validatedPathAppName(_ value: String) throws -> String {
        guard let name = Self.validatedAppName(value),
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw AWTRIXError.invalidAppName
        }
        return encoded
    }

    private func fetchPaletteDefinitions(_ filenames: [String],
                                         configuration: AWTRIXSettings) async -> [String: [String]] {
        var result: [String: [String]] = [:]
        for filename in filenames {
            guard !Task.isCancelled else { break }
            let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
            guard let data = try? await request(configuration, path: "/PALETTES/\(encoded)", timeout: 3),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let entries = text.split(whereSeparator: \.isNewline).map(String.init)
            if !entries.isEmpty { result[String(filename.dropLast(4))] = entries }
        }
        return result
    }

    private func uploadIcon(_ data: Data, named name: String,
                            configuration: AWTRIXSettings) async throws {
        let boundary = "LingxiBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"\(name).gif\"\r\n")
        body.appendUTF8("Content-Type: image/gif\r\n\r\n")
        body.append(data)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        _ = try await request(configuration,
                              path: "/api/v1/files?dir=/ICONS",
                              method: "POST",
                              body: body,
                              contentType: "multipart/form-data; boundary=\(boundary)")
    }

    private func request(_ configuration: AWTRIXSettings,
                         path: String,
                         method: String = "GET",
                         json: [String: Any]? = nil,
                         body: Data? = nil,
                         contentType: String? = nil,
                         timeout: TimeInterval = 12) async throws -> Data {
        let base = try baseURL(configuration.baseURL)
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw AWTRIXError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.username.isEmpty {
            let token = Data("\(configuration.username):\(configuration.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AWTRIXError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let text = Self.errorMessage(from: data)
            throw AWTRIXError.requestFailed(http.statusCode, "\(text)（\(method) \(path)）")
        }
        return data
    }

    private func baseURL(_ value: String) throws -> URL {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "http://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let url = URL(string: raw + "/"), url.host != nil else { throw AWTRIXError.invalidURL }
        return url
    }

    private static func errorMessage(from data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text! : "未知错误"
    }

    private static func appConfigurationError(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawError = root["error"], !(rawError is NSNull) else { return nil }
        if let message = rawError as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let error = rawError as? [String: Any] else { return "设备返回了未知设置错误" }
        let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = (error["line"] as? NSNumber)?.intValue
        let hook = (error["hook"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var details = message?.isEmpty == false ? message! : "脚本拒绝了这项设置"
        if let line { details += "（第 \(line) 行）" }
        if let hook, !hook.isEmpty { details += " · \(hook)" }
        return details
    }
}

public struct AWTRIXBitmapRenderer: Sendable {
    public static let maximumTextCharacters = 160
    public static let maximumGIFFrames = 128
    /// 固件需把压缩文件完整加载进 RAM；这是客户端预算，不是假定的固件上传上限。
    public static let maximumGIFBytes = 32 * 1_024
    private struct RGB: Equatable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    private struct Glyph {
        let rows: [UInt8]
        let width: Int
        let gap: Int
    }

    private let ascii: Data
    private let gb2312: Data
    private static let gbEncoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    public init(fontDirectory: URL? = nil) throws {
        let directory = fontDirectory ?? Self.defaultFontDirectory()
        let asciiURL = directory.appendingPathComponent("font_ascii.bin")
        let gbURL = directory.appendingPathComponent("font_gb2312.bin")
        guard let ascii = try? Data(contentsOf: asciiURL), ascii.count >= 95 * 9 else {
            throw AWTRIXError.missingFont("font_ascii.bin")
        }
        guard let gb = try? Data(contentsOf: gbURL), gb.count >= 94 * 94 * 8 else {
            throw AWTRIXError.missingFont("font_gb2312.bin")
        }
        self.ascii = ascii
        self.gb2312 = gb
    }

    public static func normalizedHex(_ value: String) -> String? {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, raw.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + raw
    }

    public func fitsOnPanel(_ text: String) -> Bool {
        guard text.count <= Self.maximumTextCharacters else { return false }
        let glyphs = text.map(glyph)
        guard !glyphs.isEmpty else { return true }
        return Self.contentWidth(glyphs) <= 32
    }

    /// 生成 AWTRIX `draw.pixels` 指令。只绘制字形亮点，未点亮区域留给设备原生灯光效果。
    public func renderDrawCommands(text: String,
                                   foregroundHex: String,
                                   paletteName: String,
                                   paletteEntries: [String] = []) throws -> [[Any]] {
        try Task.checkCancellation()
        let foreground = try Self.rgb(foregroundHex)
        let glyphs = text.map(glyph)
        guard !glyphs.isEmpty else { throw AWTRIXError.emptyText }
        let width = Self.contentWidth(glyphs)
        guard width <= 32 else { throw AWTRIXError.gifEncodingFailed }
        let stops = Self.paletteStops(named: paletteName, entries: paletteEntries)
        let left = (32 - width) / 2
        var groups: [String: [Int]] = [:]
        var originX = 0
        for item in glyphs {
            for y in 0..<min(8, item.rows.count) {
                for x in 0..<item.width where item.rows[y] & (0x80 >> UInt8(x)) != 0 {
                    let color = stops.map {
                        Self.blend($0, position: Double(originX + x) / Double(max(1, width - 1)))
                    } ?? foreground
                    groups[Self.hex(color), default: []].append(contentsOf: [left + originX + x, y])
                }
            }
            originX += item.width + item.gap
        }
        return groups.keys.sorted().map { color in
            var command: [Any] = ["pixels", color]
            command.append(contentsOf: groups[color]!.map { $0 as Any })
            return command
        }
    }

    public func renderGIF(text: String,
                          foregroundHex: String,
                          backgroundHex: String,
                          paletteName: String,
                          paletteEntries: [String] = [],
                          scrollSpeedMilliseconds: Int) throws -> Data {
        try Task.checkCancellation()
        guard text.count <= Self.maximumTextCharacters else {
            throw AWTRIXError.bitmapTextTooLong(Self.maximumTextCharacters)
        }
        let foreground = try Self.rgb(foregroundHex)
        let background = try Self.rgb(backgroundHex)
        let glyphs = text.map(glyph)
        guard !glyphs.isEmpty else { throw AWTRIXError.emptyText }
        let contentWidth = Self.contentWidth(glyphs)
        let stops = Self.paletteStops(named: paletteName, entries: paletteEntries)
        let colors: [RGB]
        if let stops {
            colors = [background] + (0..<15).map { Self.blend(stops, position: Double($0) / 14) }
        } else {
            colors = [background, foreground]
        }
        var canvas = Array(repeating: UInt8(0), count: contentWidth * 8)
        var originX = 0
        for item in glyphs {
            try Task.checkCancellation()
            for y in 0..<min(8, item.rows.count) {
                for x in 0..<item.width where item.rows[y] & (0x80 >> UInt8(x)) != 0 {
                    let color: UInt8
                    if stops != nil {
                        color = UInt8((Double(originX + x) / Double(max(1, contentWidth - 1)) * 14).rounded()) + 1
                    } else {
                        color = 1
                    }
                    canvas[y * contentWidth + originX + x] = color
                }
            }
            originX += item.width + item.gap
        }

        var encoder = AWTRIXIndexedGIFEncoder(colors: colors.map {
            (UInt32($0.r) << 16) | (UInt32($0.g) << 8) | UInt32($0.b)
        })
        let scrolling = contentWidth > 32
        let step = scrolling ? max(1, (contentWidth + 9 + Self.maximumGIFFrames - 1) / Self.maximumGIFFrames) : 1
        let offsets = scrolling
            ? Array(stride(from: 0, to: contentWidth + 9, by: step))
            : [-((32 - contentWidth) / 2)]
        for offset in offsets {
            try Task.checkCancellation()
            var pixels = Array(repeating: UInt8(0), count: 32 * 8)
            for y in 0..<8 {
                for x in 0..<32 {
                    let sourceX = x + offset
                    if sourceX >= 0 && sourceX < contentWidth {
                        pixels[y * 32 + x] = canvas[y * contentWidth + sourceX]
                    }
                }
            }
            let duration = !scrolling ? 1_000
                : (offset == 0 ? 700 : min(max(scrollSpeedMilliseconds, 40), 500) * step)
            try encoder.appendFrame(pixels, durationMilliseconds: duration)
        }
        return encoder.finish()
    }

    private static func contentWidth(_ glyphs: [Glyph]) -> Int {
        max(1, glyphs.reduce(0) { $0 + $1.width + $1.gap } - (glyphs.last?.gap ?? 0))
    }

    private func glyph(_ character: Character) -> Glyph {
        let string = String(character)
        if let scalar = string.unicodeScalars.first, string.unicodeScalars.count == 1,
           scalar.value >= 32, scalar.value <= 126 {
            let start = Int(scalar.value - 32) * 9
            return Glyph(rows: Array(ascii[start..<(start + 8)]),
                         width: max(1, min(Int(ascii[start + 8]), 8)), gap: 1)
        }
        if let encoded = string.data(using: Self.gbEncoding), encoded.count == 2 {
            let bytes = [UInt8](encoded)
            if bytes[0] >= 0xA1, bytes[0] <= 0xFE, bytes[1] >= 0xA1, bytes[1] <= 0xFE {
                let index = (Int(bytes[0]) - 0xA1) * 94 + Int(bytes[1]) - 0xA1
                let start = index * 8
                if start + 8 <= gb2312.count {
                    return Glyph(rows: Array(gb2312[start..<(start + 8)]), width: 8, gap: 0)
                }
            }
        }
        return glyph("?")
    }

    private static func defaultFontDirectory() -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("AWTRIX"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // SwiftPM 冒烟测试从源码运行时使用仓库 Resources；正式应用始终命中上面的 Bundle。
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/AWTRIX")
    }

    private static func rgb(_ value: String) throws -> RGB {
        guard let normalized = normalizedHex(value) else { throw AWTRIXError.invalidColor(value) }
        let raw = String(normalized.dropFirst())
        return RGB(r: UInt8(raw.prefix(2), radix: 16)!,
                   g: UInt8(raw.dropFirst(2).prefix(2), radix: 16)!,
                   b: UInt8(raw.dropFirst(4).prefix(2), radix: 16)!)
    }

    private static func paletteStops(named name: String, entries: [String]) -> [RGB]? {
        if !entries.isEmpty {
            let parsed = entries.compactMap { entry -> RGB? in
                let color = entry.split(separator: "@", maxSplits: 1).first.map(String.init) ?? entry
                return try? rgb(color)
            }
            if !parsed.isEmpty { return parsed }
        }
        switch name.lowercased() {
        case "solid", "": return nil
        case "cloud": return [RGB(r: 0, g: 0, b: 255), RGB(r: 0, g: 0, b: 139), RGB(r: 135, g: 206, b: 235), RGB(r: 255, g: 255, b: 255), RGB(r: 173, g: 216, b: 230)]
        case "rainbow": return [RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 160, b: 0), RGB(r: 255, g: 255, b: 0), RGB(r: 0, g: 255, b: 0), RGB(r: 0, g: 180, b: 255), RGB(r: 80, g: 0, b: 255), RGB(r: 220, g: 0, b: 255)]
        case "ocean": return [RGB(r: 0, g: 18, b: 80), RGB(r: 0, g: 110, b: 220), RGB(r: 0, g: 255, b: 255), RGB(r: 120, g: 255, b: 255)]
        case "lava": return [RGB(r: 70, g: 0, b: 0), RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 100, b: 0), RGB(r: 255, g: 255, b: 80)]
        case "forest": return [RGB(r: 0, g: 40, b: 0), RGB(r: 0, g: 150, b: 40), RGB(r: 80, g: 255, b: 60), RGB(r: 210, g: 255, b: 120)]
        case "party": return [RGB(r: 255, g: 0, b: 160), RGB(r: 0, g: 210, b: 255), RGB(r: 255, g: 230, b: 0), RGB(r: 120, g: 0, b: 255)]
        case "heat": return [RGB(r: 30, g: 0, b: 0), RGB(r: 180, g: 0, b: 0), RGB(r: 255, g: 90, b: 0), RGB(r: 255, g: 255, b: 120)]
        case "stripe": return [RGB(r: 255, g: 255, b: 255), RGB(r: 255, g: 40, b: 40), RGB(r: 255, g: 255, b: 255), RGB(r: 40, g: 120, b: 255)]
        default: return nil
        }
    }

    private static func hex(_ color: RGB) -> String {
        String(format: "#%02X%02X%02X", color.r, color.g, color.b)
    }

    private static func blend(_ stops: [RGB], position: Double) -> RGB {
        guard stops.count > 1 else { return stops.first ?? RGB(r: 255, g: 255, b: 255) }
        let scaled = max(0, min(1, position)) * Double(stops.count - 1)
        let index = min(Int(scaled), stops.count - 2)
        let fraction = scaled - Double(index)
        func channel(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) * (1 - fraction) + Double(b) * fraction).rounded())
        }
        return RGB(r: channel(stops[index].r, stops[index + 1].r),
                   g: channel(stops[index].g, stops[index + 1].g),
                   b: channel(stops[index].b, stops[index + 1].b))
    }

}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(contentsOf: value.utf8)
    }
}
