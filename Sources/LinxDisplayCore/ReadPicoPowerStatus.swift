import Foundation

/// 中文：只接受设备报告的供电快照；未知、缺失或损坏数据不能证明外接电源。
/// English: Accept device-reported power snapshots only; unknown, absent or malformed data never proves external power.
public struct ReadPicoPowerStatus: Decodable, Equatable, Sendable {
    public let known: Bool, charging: Bool, externalPower: Bool
    public let batteryPercent: Int, revision: UInt32
    public init(known: Bool, charging: Bool, batteryPercent: Int, revision: UInt32, externalPower: Bool) {
        let valid = (-1...100).contains(batteryPercent) && (!charging || externalPower)
        self.known = known && valid; self.charging = known && valid && charging
        self.externalPower = known && valid && externalPower
        self.batteryPercent = (-1...100).contains(batteryPercent) ? batteryPercent : -1
        self.revision = revision
    }
    enum CodingKeys: String, CodingKey {
        case known, charging, revision
        case batteryPercent = "battery_percent", externalPower = "external_power"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let known = try c.decode(Bool.self, forKey: .known)
        let charging = try c.decode(Bool.self, forKey: .charging)
        let external = try c.decode(Bool.self, forKey: .externalPower)
        let percent = try c.decode(Int.self, forKey: .batteryPercent)
        let revision = try c.decode(UInt32.self, forKey: .revision)
        guard (-1...100).contains(percent), !charging || external,
              known || (!charging && !external) else {
            throw DecodingError.dataCorruptedError(forKey: .known, in: c, debugDescription: "Invalid device power projection")
        }
        self.init(known: known, charging: charging, batteryPercent: percent, revision: revision, externalPower: external)
    }
    /// 中文：遥测是可选扩展；损坏扩展按未知处理，不阻止已有画布或存储协议。
    /// English: Telemetry is optional; malformed extensions remain unknown without breaking canvas/storage protocols.
    public static func decodeOptional(_ object: Any?) -> Self? {
        guard let object = object as? [String: Any], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
