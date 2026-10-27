import Foundation

/// Home Assistant has one shared server. Old device copies are only a legacy
/// fallback when both shared fields are absent; never combine two credential pairs.
public struct HASharedConnection: Equatable {
    public let serverURL: String
    public let token: String
    public var fingerprint: String {
        HASourcePreviewOriginPolicy.fingerprint(serverURL: serverURL, token: token)!
    }
}

public enum HASharedConnectionResolver {
    public static func resolve(serverURL: String, token: String,
                               legacyServerURL: String? = nil, legacyToken: String? = nil) -> HASharedConnection? {
        let server = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasToken = !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !server.isEmpty || hasToken {
            guard !server.isEmpty, hasToken else { return nil }
            return HASharedConnection(serverURL: server, token: token)
        }
        let legacyServer = (legacyServerURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyToken = legacyToken ?? ""
        guard !legacyServer.isEmpty,
              !legacyToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return HASharedConnection(serverURL: legacyServer, token: legacyToken)
    }
}

/// A visible overview may request one missing first reading per connection.
/// Repeated renders/ticks do not create a new polling cadence; leaving and reopening
/// the overview allows one explicit retry. Owners support multiple native windows.
public struct ControlCenterSourcePreviewDemand {
    private var owners: [UUID: Set<UUID>] = [:]
    private var attemptedOrigins: Set<String> = []

    public init() {}
    public var deviceIDs: Set<UUID> { owners.values.reduce(into: Set<UUID>()) { $0.formUnion($1) } }

    public mutating func setDevices(_ ids: Set<UUID>, owner: UUID) {
        owners[owner] = ids
    }

    public mutating func remove(owner: UUID) {
        owners[owner] = nil
        if owners.isEmpty { attemptedOrigins.removeAll() }
    }

    public func shouldRequest(origin: String?, needsFirstReading: Bool, requestInFlight: Bool) -> Bool {
        guard let origin else { return false }
        return !deviceIDs.isEmpty && needsFirstReading && !requestInFlight && !attemptedOrigins.contains(origin)
    }

    public mutating func beganRequest(origin: String) { attemptedOrigins.insert(origin) }
}
