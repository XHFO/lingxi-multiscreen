import CryptoKit
import Foundation

/// Identifies the connection that produced a cached reading without retaining its token.
/// Token bytes remain exact, as they are sent by HomeAssistantClient; only URL whitespace
/// is ignored, matching the client's URL construction.
public enum HASourcePreviewOriginPolicy {
    public static func fingerprint(serverURL: String, token: String) -> String? {
        let server = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var input = Data("lingxi-ha-preview-v1:".utf8)
        for value in [server, token] {
            let bytes = Data(value.utf8)
            input.append(Data("\(bytes.count):".utf8))
            input.append(bytes)
        }
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    public static func matchingSources(requestFingerprint: String?,
                                       configurations: [UUID: String]) -> [UUID: String] {
        guard let requestFingerprint else { return [:] }
        return configurations.filter { $0.value == requestFingerprint }
    }
}

/// A read-only consumer's cache. Array values retain Swift's copy-on-write storage.
/// Only an actual successful request may populate it; selection/global mirror changes
/// cannot establish provenance. Late responses cannot replace a different configuration.
public struct HASourcePreviewCache<Value> {
    private struct Entry {
        let fingerprint: String
        let value: Value
    }
    private var entries: [UUID: Entry] = [:]

    public init() {}

    public func value(for sourceID: UUID, configurationFingerprint: String?) -> Value? {
        guard let fingerprint = configurationFingerprint,
              let entry = entries[sourceID], entry.fingerprint == fingerprint else { return nil }
        return entry.value
    }

    public mutating func recordSuccess(_ value: Value, requestedSources: [UUID: String],
                                      currentConfigurations: [UUID: String]) {
        for (id, fingerprint) in requestedSources where currentConfigurations[id] == fingerprint {
            entries[id] = Entry(fingerprint: fingerprint, value: value)
        }
    }

    /// A failure only invalidates the connection that failed, preserving a newer
    /// successful reading if the user changed this source while the request was running.
    public mutating func invalidate(requestedSources: [UUID: String]) {
        for (id, fingerprint) in requestedSources where entries[id]?.fingerprint == fingerprint {
            entries[id] = nil
        }
    }

    public mutating func remove(sourceID: UUID) { entries[sourceID] = nil }
    public mutating func removeAll() { entries.removeAll() }
}
