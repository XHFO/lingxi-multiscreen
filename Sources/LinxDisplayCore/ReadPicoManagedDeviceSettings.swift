import Foundation

public struct ReadPicoInformationPushSettings: Codable, Equatable, Sendable {
    public var source: String
    public var landscape: Bool
    public var dither: Bool
    public var intervalSeconds: Int
    public var entityIDs: [String]
    public static let sources = ["clock", "weather", "music", "system", "home", "image"]
    public static let intervals = [0, 60, 300, 900, 1800, 3600]
    public init(source: String = "clock", landscape: Bool = false, dither: Bool = true,
                intervalSeconds: Int = 0, entityIDs: [String] = []) {
        self.source = Self.sources.contains(source) ? source : "clock"
        self.landscape = landscape; self.dither = dither
        self.intervalSeconds = Self.intervals.contains(intervalSeconds) ? intervalSeconds : 0
        var seen = Set<String>()
        self.entityIDs = Array(entityIDs.filter { !$0.isEmpty && $0.utf8.count <= 255 && seen.insert($0).inserted }.prefix(6))
    }
    private enum CodingKeys: String, CodingKey { case source, landscape, dither, intervalSeconds, entityIDs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try c.decodeIfPresent(String.self, forKey: .source) ?? "clock",
                  landscape: try c.decodeIfPresent(Bool.self, forKey: .landscape) ?? false,
                  dither: try c.decodeIfPresent(Bool.self, forKey: .dither) ?? true,
                  intervalSeconds: try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 0,
                  entityIDs: try c.decodeIfPresent([String].self, forKey: .entityIDs) ?? [])
    }
}

/// 设备管理列表里的 Pico 连接位置。与带临时配对码的 ReadPicoConnection 分开，
/// 保存、导出和备份设备设置时都不会携带 Web 管理权限。
public struct ReadPicoManagedDeviceSettings: Codable, Equatable, Sendable {
    public private(set) var managementAddress: String
    public var informationPush = ReadPicoInformationPushSettings()
    public var automaticUSBPreparation = true
    public var transportPreference: ReadPicoTransportPreference = .automatic

    public init() { managementAddress = "" }

    /// 接受设备 IP 或完整管理链接，仅保留协议、主机和端口。
    public init(managementAddress: String) throws {
        self.managementAddress = try Self.normalizedManagementAddress(managementAddress)
    }

    public mutating func updateManagementAddress(_ address: String) throws {
        managementAddress = try Self.normalizedManagementAddress(address)
    }

    public static func normalizedManagementAddress(_ address: String) throws -> String {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return "" }
        guard !input.contains(where: { $0.isWhitespace || $0.isNewline }),
              var components = URLComponents(string: input.contains("://") ? input : "http://" + input),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw ReadPicoManagedDeviceSettingsError.invalidManagementAddress
        }
        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let result = components.url?.absoluteString else {
            throw ReadPicoManagedDeviceSettingsError.invalidManagementAddress
        }
        return result
    }

    private enum CodingKeys: String, CodingKey { case managementAddress, informationPush, automaticUSBPreparation, transportPreference }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try container.decodeIfPresent(String.self, forKey: .managementAddress) ?? ""
        // 损坏的连接地址不会令整个设备列表丢失；旧导入中的授权参数也在这里清除。
        managementAddress = (try? Self.normalizedManagementAddress(saved)) ?? ""
        informationPush = try container.decodeIfPresent(ReadPicoInformationPushSettings.self, forKey: .informationPush) ?? .init()
        automaticUSBPreparation = try container.decodeIfPresent(Bool.self, forKey: .automaticUSBPreparation) ?? true
        transportPreference = (try? container.decodeIfPresent(ReadPicoTransportPreference.self, forKey: .transportPreference)) ?? .automatic
    }
}

public enum ReadPicoManagedDeviceSettingsError: Error, LocalizedError, Equatable {
    case invalidManagementAddress

    public var errorDescription: String? {
        "请填写设备 IP 或 HTTP/HTTPS 管理地址，不包含账号或密码。"
    }
}
