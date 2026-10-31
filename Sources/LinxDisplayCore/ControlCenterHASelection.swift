import Foundation

/// Content chosen for the software overview, independent of any physical display's
/// card contents. A server/token change intentionally requires choosing again.
public struct ControlCenterHASelection: Codable, Equatable, Sendable {
    public let connectionFingerprint: String
    public let entityIDs: [String]
    /// 用户指定为整行宽度的实体；其余实体使用半宽（单独一行时自动铺满）。
    public let wideEntityIDs: [String]

    public init(connectionFingerprint: String, entityIDs: [String],
                wideEntityIDs: [String] = []) {
        self.connectionFingerprint = connectionFingerprint
        var seen = Set<String>()
        self.entityIDs = entityIDs.compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && seen.insert(id).inserted ? id : nil
        }
        let allowed = Set(self.entityIDs)
        var wideSeen = Set<String>()
        self.wideEntityIDs = wideEntityIDs.compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return allowed.contains(id) && wideSeen.insert(id).inserted ? id : nil
        }
    }

    private enum CodingKeys: String, CodingKey { case connectionFingerprint, entityIDs, wideEntityIDs }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(connectionFingerprint: try values.decode(String.self, forKey: .connectionFingerprint),
                  entityIDs: try values.decode([String].self, forKey: .entityIDs),
                  wideEntityIDs: try values.decodeIfPresent([String].self, forKey: .wideEntityIDs) ?? [])
    }
}

/// Deliberately narrower than the existing controller's domain list. An overview
/// offers only explicit on/off operations; locks, scripts, scenes, automations,
/// button presses and other domains remain read-only.
public enum ControlCenterHAControlPolicy {
    public static let supportedDomains: Set<String> = ["light", "switch", "fan", "input_boolean", "climate"]

    public static func isAvailable(_ entity: HAEntity) -> Bool {
        !["", "unknown", "unavailable", "none", "null"].contains(
            entity.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func isControllable(_ entity: HAEntity) -> Bool {
        supportedDomains.contains(entity.domain)
    }

    /// 电源按钮的“当前开启”判断：空调的 state 是 heat/cool/auto 等模式，不等于 on。
    public static func isPowerOn(_ entity: HAEntity) -> Bool {
        guard isAvailable(entity) else { return false }
        let state = entity.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if entity.domain == "climate" {
            return state != "off"
        }
        return state == "on"
    }

    /// Revalidate selection and origin at the user-click boundary, then reuse the
    /// existing service mapping. No permissive fall-through for arbitrary services.
    public static func command(for entity: HAEntity, selectedEntityIDs: [String],
                               expectedFingerprint: String, currentFingerprint: String?, turnOn: Bool) -> HAServiceCommand? {
        guard !expectedFingerprint.isEmpty, currentFingerprint == expectedFingerprint,
              selectedEntityIDs.contains(entity.entityId), isControllable(entity), isAvailable(entity) else { return nil }
        return M5HAControlPolicy.directionalCommand(for: entity, direction: turnOn ? 1 : -1)
    }

    /// 灯光亮度：0% 直接关灯，>0% 使用 light.turn_on 的 brightness_pct。
    public static func brightnessCommand(for entity: HAEntity, selectedEntityIDs: [String],
                                         expectedFingerprint: String, currentFingerprint: String?,
                                         percent: Int) -> HAServiceCommand? {
        guard !expectedFingerprint.isEmpty, currentFingerprint == expectedFingerprint,
              selectedEntityIDs.contains(entity.entityId),
              entity.domain == "light", isAvailable(entity) else { return nil }
        let value = min(max(percent, 0), 100)
        if value == 0 {
            return HAServiceCommand(domain: "light", service: "turn_off", entityID: entity.entityId)
        }
        return HAServiceCommand(domain: "light", service: "turn_on", entityID: entity.entityId,
                                brightnessPercent: value)
    }

    /// 风扇百分比：0% 直接关风扇，>0% 使用 fan.set_percentage。
    public static func fanCommand(for entity: HAEntity, selectedEntityIDs: [String],
                                  expectedFingerprint: String, currentFingerprint: String?,
                                  percent: Int) -> HAServiceCommand? {
        guard !expectedFingerprint.isEmpty, currentFingerprint == expectedFingerprint,
              selectedEntityIDs.contains(entity.entityId),
              entity.domain == "fan", isAvailable(entity) else { return nil }
        let value = min(max(percent, 0), 100)
        if value == 0 {
            return HAServiceCommand(domain: "fan", service: "turn_off", entityID: entity.entityId)
        }
        return HAServiceCommand(domain: "fan", service: "set_percentage", entityID: entity.entityId,
                                percentage: value)
    }

    /// 空调目标温度。HA 会按集成配置的温标接受数值。
    public static func climateTemperatureCommand(for entity: HAEntity,
                                                 selectedEntityIDs: [String],
                                                 expectedFingerprint: String,
                                                 currentFingerprint: String?,
                                                 temperature: Double) -> HAServiceCommand? {
        guard !expectedFingerprint.isEmpty, currentFingerprint == expectedFingerprint,
              selectedEntityIDs.contains(entity.entityId),
              entity.domain == "climate", isAvailable(entity),
              temperature.isFinite else { return nil }
        let lower = entity.minTemperature ?? 5
        let upper = entity.maxTemperature ?? 35
        let clamped = min(max(temperature, lower), upper)
        return HAServiceCommand(domain: "climate", service: "set_temperature",
                                entityID: entity.entityId, temperature: clamped)
    }

    /// 空调模式：off / heat / cool / heat_cool / auto / dry / fan_only。
    public static func climateModeCommand(for entity: HAEntity,
                                          selectedEntityIDs: [String],
                                          expectedFingerprint: String,
                                          currentFingerprint: String?,
                                          mode: String) -> HAServiceCommand? {
        let value = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !expectedFingerprint.isEmpty, currentFingerprint == expectedFingerprint,
              selectedEntityIDs.contains(entity.entityId),
              entity.domain == "climate", isAvailable(entity), !value.isEmpty else { return nil }
        if let modes = entity.hvacModes, !modes.isEmpty,
           !modes.map({ $0.lowercased() }).contains(value) { return nil }
        return HAServiceCommand(domain: "climate", service: "set_hvac_mode",
                                entityID: entity.entityId, hvacMode: value)
    }

    /// 温湿度传感器是可选中但只读的实体。
    public static func isClimateSensor(_ entity: HAEntity) -> Bool {
        entity.isClimateSensor
    }
}
