import Foundation

@main struct BoardRoutingTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1; precondition(condition(), label)
        }
        let now = Date(timeIntervalSince1970: 1_000)
        let serial = "AABBCCDDEEFF", cdc = "aa:bb:cc:dd:ee:ff"
        var state = ReadPicoBoardRouting()
        func route(_ preference: ReadPicoTransportPreference = .automatic, session: Bool = true,
                   expected: String? = serial, usb: String? = cdc, trusted: String? = serial,
                   at: Date = now) -> ReadPicoBoardRoute {
            state.route(preference: preference, hasLANSession: session,
                        verifiedLANUSBIdentity: expected, availableUSBIdentity: usb,
                        trustedUSBIdentity: trusted, now: at)
        }
        check(route() == .probeLAN, "A remembered session is not proof the endpoint remains online")
        state.probeSucceeded(at: now)
        check(route() == .wireless && route(.wifi) == .wireless, "Authenticated LAN wins automatic routing")
        check(route(.usb) == .usb, "An independent explicit Board USB preference is honored")
        check(route(expected: nil) == .wireless, "LAN does not require a USB cable or registry identity")
        check(route(at: now.addingTimeInterval(10)) == .wireless, "Ready cache includes freshness boundary")
        check(route(at: now.addingTimeInterval(10.001)) == .probeLAN, "Ready cache requires bounded fresh probe")
        check(route(at: now.addingTimeInterval(-1)) == .probeLAN, "Future clock sample does not count as online")
        state.probeFailed(.offline, at: now)
        check(route() == .usb, "Offline preflight permits matching-device USB backup")
        check(route(.wifi) == .needsConnection, "Explicit wireless mode never falls back to USB")
        check(route(expected: nil) == .needsConnection && route(usb: "001122334455") == .needsConnection,
              "Missing or mismatched LAN provenance prevents accidental USB fallback")
        check(route(at: now.addingTimeInterval(14.999)) == .usb, "Offline cooldown avoids per-frame USB/probe preparation")
        check(route(at: now.addingTimeInterval(15)) == .probeLAN, "Next boundary rechecks LAN before another USB fallback")
        state.probeSucceeded(at: now.addingTimeInterval(15))
        check(route(at: now.addingTimeInterval(15)) == .wireless, "Recovered authenticated LAN automatically resumes preference")
        state.probeFailed(.authenticationRequired, at: now)
        check(route() == .authenticationRequired, "Expired key requires pairing, not USB replay")
        state.probeFailed(.unavailable, at: now)
        check(route() == .blocked, "Protocol/storage/TLS failure does not mean LAN offline")
        state.probeFailed(.cancelled, at: now.addingTimeInterval(1))
        check(state.lanState == .unavailable && state.probeAt == now, "Cancellation cannot mutate established health")
        state.probeFailed(.offline, at: now)
        state.submissionStarted()
        check(route() == .submissionUncertain && route(.usb) == .submissionUncertain,
              "Lost POST acknowledgement blocks automatic and forced second delivery")
        state.probeSucceeded(at: now)
        check(route() == .submissionUncertain, "A successful status read alone cannot reconcile a canvas receipt")
        state.displayConfirmed()
        check(route() == .wireless, "Matching display receipt permits future sends")
        state.submissionStarted(); state.submissionReconciled()
        check(!state.submissionUncertain, "Explicit reconciliation releases uncertainty")
        state.submissionStarted(); state.reset()
        check(state.submissionUncertain && route() == .submissionUncertain,
              "Pairing again cannot discard an uncertain prior delivery")
        state.submissionReconciled()
        state.reset()
        check(state.lanState == .unknown && state.probeAt == nil && !state.submissionUncertain, "New paired session starts with fresh route evidence after reconciliation")
        check(route(session: false) == .usb && route(.wifi, session: false) == .needsConnection,
              "Verified wired destination remains usable when no LAN session exists")
        check(route(session: false, expected: nil) == .usb && route(.usb, session: false, expected: nil) == .usb,
              "A fresh reader explicitly trusted through USB needs no historic LAN pairing")
        check(route(session: false, expected: nil, trusted: nil) == .needsConnection,
              "An arbitrary nearby cable never proves device identity")
        check(route(session: false, trusted: "001122334455") == .needsConnection,
              "An old explicit USB target cannot authorize a newly attached reader")
        state.probeFailed(.offline, at: now)
        check(route(expected: "001122334455", trusted: serial) == .needsConnection &&
              route(.usb, expected: "001122334455", trusted: serial) == .needsConnection,
              "Explicit USB trust cannot override a different existing LAN session")
        for code in [URLError.Code.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                     .dnsLookupFailed, .networkConnectionLost, .timedOut, .dataNotAllowed] {
            check(ReadPicoBoardLANFailure.preflight(URLError(code)) == .offline, "Read-only transport failure is offline: \(code)")
        }
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted,
                     .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                     .httpTooManyRedirects, .badServerResponse, .cannotDecodeContentData] {
            check(ReadPicoBoardLANFailure.preflight(URLError(code)) == .unavailable, "Unsafe fallback classification rejected: \(code)")
        }
        check(ReadPicoBoardLANFailure.preflight(ReadPicoManagerError.expired) == .authenticationRequired,
              "Expired pairing is actionable authentication failure")
        check(ReadPicoBoardLANFailure.preflight(ReadPicoManagerError.http(403)) == .authenticationRequired,
              "HTTP forbidden cannot become offline fallback")
        check(ReadPicoBoardLANFailure.preflight(ReadPicoManagerError.unavailable("storage")) == .unavailable,
              "Human-readable messages do not drive transport fallback")
        check(ReadPicoBoardLANFailure.preflight(CancellationError()) == .cancelled &&
              ReadPicoBoardLANFailure.preflight(URLError(.cancelled)) == .cancelled, "Both task and URL cancellation remain cancellation")
        check(ReadPicoBoardRouting.identityMatches(serial, cdc), "Full MAC identity normalizes only documented CDC/MSC format")
        check(!ReadPicoBoardRouting.identityMatches(serial, "aa-bb-cc-dd-ee-ff") &&
              !ReadPicoBoardRouting.identityMatches(serial, " AABBCCDDEEFF"), "Alternate delimiters/padding never weaken identity")
        check(ReadPicoBoardRouting.identityMatches("serial-7", "serial-7") &&
              !ReadPicoBoardRouting.identityMatches("serial-7", "SERIAL-7"), "Non-MAC serials remain exact")
        check(!ReadPicoBoardRouting.identityMatches(nil, nil) && !ReadPicoBoardRouting.identityMatches("", ""), "Absent identity never matches")
        print("Board routing: \(checks) checks passed; pure state, no network, hardware or user settings")
    }
}
