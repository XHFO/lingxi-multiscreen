import Foundation

/// Only a failed authenticated read may establish that LAN is offline. A failed
/// canvas POST can have reached the reader even when its acknowledgement was lost.
public enum ReadPicoBoardLANFailure: Equatable, Sendable {
    case offline, authenticationRequired, cancelled, unavailable

    public static func preflight(_ error: Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let pico = error as? ReadPicoManagerError {
            switch pico {
            case .expired, .http(401), .http(403): return .authenticationRequired
            default: return .unavailable
            }
        }
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return .unavailable }
        switch URLError.Code(rawValue: value.code) {
        case .cancelled: return .cancelled
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return .authenticationRequired
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .networkConnectionLost, .timedOut, .dataNotAllowed:
            return .offline
        default:
            // Certificate failures, redirects, malformed responses and other
            // protocol errors must never authorize a second delivery over USB.
            return .unavailable
        }
    }
}

public enum ReadPicoBoardRoute: Equatable, Sendable {
    case probeLAN, wireless, usb, needsConnection, authenticationRequired, blocked, submissionUncertain
}

/// Non-secret routing state for Lingxi Board, separate from file-management mode.
/// Callers perform probes/submissions; this value never opens a port or a network.
public struct ReadPicoBoardRouting: Sendable {
    public enum LANState: Equatable, Sendable {
        case unknown, ready, offline, authenticationRequired, unavailable
    }
    public static let readyFreshness: TimeInterval = 10
    public static let offlineProbeInterval: TimeInterval = 15
    public private(set) var lanState: LANState = .unknown
    public private(set) var probeAt: Date?
    public private(set) var submissionUncertain = false

    public init() {}

    /// Reconnecting or changing the temporary setup key refreshes LAN evidence,
    /// but cannot prove whether an earlier submitted frame reached the reader.
    public mutating func reset() {
        lanState = .unknown; probeAt = nil
    }

    public mutating func probeSucceeded(at now: Date = Date()) {
        lanState = .ready; probeAt = now
    }

    public mutating func probeFailed(_ failure: ReadPicoBoardLANFailure, at now: Date = Date()) {
        guard failure != .cancelled else { return }
        probeAt = now
        switch failure {
        case .offline: lanState = .offline
        case .authenticationRequired: lanState = .authenticationRequired
        case .unavailable: lanState = .unavailable
        case .cancelled: break
        }
    }

    /// Mark before beginning POST, not after receiving acceptance. Only a
    /// matching display receipt or explicit user/device reconciliation clears it.
    public mutating func submissionStarted() { submissionUncertain = true }
    public mutating func displayConfirmed() { submissionUncertain = false }
    public mutating func submissionReconciled() { submissionUncertain = false }

    /// `verifiedLANUSBIdentity` belongs to the authenticated LAN session. With no
    /// LAN session, `trustedUSBIdentity` may instead come from explicit USB setup
    /// or a user-selected, verified target. Discovery alone establishes neither.
    public func route(preference: ReadPicoTransportPreference, hasLANSession: Bool,
                      verifiedLANUSBIdentity: String?, availableUSBIdentity: String?,
                      trustedUSBIdentity: String? = nil,
                      now: Date = Date()) -> ReadPicoBoardRoute {
        guard !submissionUncertain else { return .submissionUncertain }
        let sameUSB = Self.identityMatches(hasLANSession ? verifiedLANUSBIdentity : trustedUSBIdentity,
                                          availableUSBIdentity)
        if preference == .usb { return sameUSB ? .usb : .needsConnection }
        guard hasLANSession else {
            return preference == .automatic && sameUSB ? .usb : .needsConnection
        }
        switch lanState {
        case .unknown: return .probeLAN
        case .authenticationRequired: return .authenticationRequired
        case .unavailable: return .blocked
        case .ready:
            guard let probeAt, now >= probeAt, now.timeIntervalSince(probeAt) <= Self.readyFreshness else { return .probeLAN }
            return .wireless
        case .offline:
            guard let probeAt, now >= probeAt, now.timeIntervalSince(probeAt) < Self.offlineProbeInterval else { return .probeLAN }
            return preference == .automatic && sameUSB ? .usb : .needsConnection
        }
    }

    /// CDC/MSC forms of the hardware MAC may differ in colons and ASCII case.
    /// Complete non-MAC serials compare exactly; partial or padded values do not.
    public static func identityMatches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        func mac(_ value: String) -> [UInt8]? {
            let input = Array(value.utf8)
            guard input.count == 12 || input.count == 17 else { return nil }
            var result: [UInt8] = []
            for (offset, byte) in input.enumerated() {
                if input.count == 17 && offset % 3 == 2 {
                    guard byte == 58 else { return nil }
                } else {
                    switch byte {
                    case 48...57, 65...70: result.append(byte)
                    case 97...102: result.append(byte - 32)
                    default: return nil
                    }
                }
            }
            return result.count == 12 ? result : nil
        }
        guard let left = mac(lhs), let right = mac(rhs) else { return false }
        return left == right
    }
}
