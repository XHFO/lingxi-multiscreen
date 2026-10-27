import Foundation

/// Content chosen for the software overview, independent of any physical display's
/// card contents. A server/token change intentionally requires choosing again.
public struct ControlCenterHASelection: Codable, Equatable, Sendable {
    public let connectionFingerprint: String
    public let entityIDs: [String]

    public init(connectionFingerprint: String, entityIDs: [String]) {
        self.connectionFingerprint = connectionFingerprint
        var seen = Set<String>()
        self.entityIDs = entityIDs.compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return !id.isEmpty && seen.insert(id).inserted ? id : nil
        }
    }

    private enum CodingKeys: String, CodingKey { case connectionFingerprint, entityIDs }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(connectionFingerprint: try values.decode(String.self, forKey: .connectionFingerprint),
                  entityIDs: try values.decode([String].self, forKey: .entityIDs))
    }
}

/// Deliberately narrower than the existing controller's domain list. An overview
/// offers only explicit on/off operations; locks, scripts, scenes, automations,
/// button presses and other domains remain read-only.
public enum ControlCenterHAControlPolicy {
    public static let supportedDomains: Set<String> = ["light", "switch", "fan", "input_boolean"]

    public static func isAvailable(_ entity: HAEntity) -> Bool {
        !["", "unknown", "unavailable", "none", "null"].contains(
            entity.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func isControllable(_ entity: HAEntity) -> Bool {
        supportedDomains.contains(entity.domain)
    }

    /// Revalidate selection and origin at the user-click boundary, then reuse the
    /// existing service mapping. No permissive fall-through for arbitrary services.
    public static func command(for entity: HAEntity, selectedEntityIDs: [String],
                               expectedFingerprint: String, currentFingerprint: String?, turnOn: Bool) -> HAServiceCommand? {
        guard !expectedFingerprint.isEmpty, currentFingerprint == expectedFingerprint,
              selectedEntityIDs.contains(entity.entityId), isControllable(entity), isAvailable(entity) else { return nil }
        return M5HAControlPolicy.directionalCommand(for: entity, direction: turnOn ? 1 : -1)
    }
}
