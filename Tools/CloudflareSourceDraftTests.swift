import Foundation
import LinxDisplayCore

@main struct CloudflareSourceDraftTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError(message) }
    }

    static func main() async throws {
        check(!CloudflareSourceDraftPolicy.canReadSites(token: "", retainingCredential: false), "empty credential blocks next")
        check(!CloudflareSourceDraftPolicy.canReadSites(token: " \n ", retainingCredential: false), "blank credential blocks next")
        check(!CloudflareSourceDraftPolicy.canReadSites(token: "invalid\r\nheader", retainingCredential: false), "malformed credential blocks next")
        check(CloudflareSourceDraftPolicy.canReadSites(token: "cfut_fixture-token", retainingCredential: false), "new token prefix accepted without fixed-length check")
        check(CloudflareSourceDraftPolicy.canReadSites(token: "", retainingCredential: true), "saved credential may be retained without exposing value")

        var configuration = CloudflareAnalyticsSettings()
        configuration.zoneID = "  " + String(repeating: "A", count: 32) + "\n"
        configuration.zoneName = " example.com "
        configuration.hostname = " WWW.EXAMPLE.COM "
        let normalized = CloudflareSourceDraftPolicy.normalized(configuration)
        check(normalized.zoneID == String(repeating: "a", count: 32), "zone ID normalized")
        check(normalized.zoneName == "example.com" && normalized.hostname == "www.example.com", "display name trimmed and hostname normalized")
        check(normalized.credentialID == configuration.credentialID, "normalization preserves credential reference")
        let payload = Data("{\"data\":{\"viewer\":{\"zones\":[{\"totals\":[{\"count\":10,\"sum\":{\"edgeResponseBytes\":1024}}],\"trend\":[],\"regions\":[]}]}},\"errors\":null}".utf8)
        let snapshot = try await CloudflareAnalyticsClient.fetch(normalized, token: "fixture-token") { _ in (payload, 200) }
        let credentialRevision = UUID()
        let proof = CloudflareSourceValidationProof(configuration: normalized, credentialRevision: credentialRevision)
        check(!CloudflareSourceDraftPolicy.canFinish(name: "Website", configuration: normalized, snapshot: nil, validation: proof, credentialRevision: credentialRevision), "site list alone cannot finish without analytics validation")
        check(!CloudflareSourceDraftPolicy.canFinish(name: " ", configuration: normalized, snapshot: snapshot, validation: proof, credentialRevision: credentialRevision), "empty source name blocks finish")
        check(CloudflareSourceDraftPolicy.canFinish(name: "Website", configuration: configuration, snapshot: snapshot, validation: proof, credentialRevision: credentialRevision), "validated normalized draft can finish")
        var changed = normalized; changed.hostname = "another.example.com"
        check(!CloudflareSourceDraftPolicy.canFinish(name: "Website", configuration: changed, snapshot: snapshot, validation: proof, credentialRevision: credentialRevision), "stale validation cannot save changed host")
        changed = normalized; changed.period = .week
        check(!CloudflareSourceDraftPolicy.canFinish(name: "Website", configuration: changed, snapshot: snapshot, validation: proof, credentialRevision: credentialRevision), "stale validation cannot save changed period")
        check(!CloudflareSourceDraftPolicy.canFinish(name: "Website", configuration: normalized, snapshot: snapshot, validation: nil, credentialRevision: credentialRevision), "a cached snapshot alone is not current validation")
        check(!CloudflareSourceDraftPolicy.canFinish(name: "Website", configuration: normalized, snapshot: snapshot, validation: proof, credentialRevision: UUID()), "changing or replacing draft Token invalidates old validation")
        changed = normalized; changed.zoneID = String(repeating: "b", count: 32)
        check(!proof.matches(changed, credentialRevision: credentialRevision), "website change cannot retain validation proof")
        changed = normalized; changed.credentialID = UUID()
        check(!proof.matches(changed, credentialRevision: credentialRevision), "changing saved credential reference invalidates validation proof")

        let previous = UUID(), fresh = UUID()
        var events: [String] = []
        let save: (String, UUID) -> Bool = { value, id in
            events.append(value.isEmpty ? "delete:\(id)" : "save:\(id)")
            return true
        }
        // Preparing, validating, navigating back, and discarding a draft never enters commit.
        _ = CloudflareSourceDraftPolicy.canReadSites(token: "fixture-token", retainingCredential: false)
        _ = CloudflareSourceDraftPolicy.canFinish(name: "Cancelled", configuration: normalized, snapshot: snapshot, validation: proof, credentialRevision: credentialRevision)
        check(events.isEmpty, "cancelling a validated draft has no credential or settings writes")

        try CloudflareSourceCredentialTransaction.commit(replacementToken: "fixture-token", credentialID: fresh, previousCredentialID: previous,
            saveSecret: save, persistSource: { events.append("persist"); return true }, credentialIsReferenced: { _ in false })
        check(events == ["save:\(fresh)", "persist", "delete:\(previous)"], "replace is save then persist then retire old credential")
        events = []
        try CloudflareSourceCredentialTransaction.commit(replacementToken: nil, credentialID: previous, previousCredentialID: previous,
            saveSecret: save, persistSource: { events.append("persist"); return true }, credentialIsReferenced: { _ in true })
        check(events == ["persist"], "retaining a credential does not rewrite or delete it")
        events = []
        try CloudflareSourceCredentialTransaction.commit(replacementToken: "fixture-token", credentialID: fresh, previousCredentialID: previous,
            saveSecret: save, persistSource: { events.append("persist"); return true }, credentialIsReferenced: { _ in true })
        check(events == ["save:\(fresh)", "persist"], "shared previous credential is preserved")
        events = []
        do {
            try CloudflareSourceCredentialTransaction.commit(replacementToken: "fixture-token", credentialID: fresh, previousCredentialID: previous,
                saveSecret: { _, _ in events.append("save-failed"); return false },
                persistSource: { events.append("persist"); return true }, credentialIsReferenced: { _ in false })
            fatalError("credential save failure accepted")
        } catch CloudflareSourceCommitError.credentialSave {
            check(events == ["save-failed"], "Keychain failure leaves source settings unchanged")
        }
        events = []
        do {
            try CloudflareSourceCredentialTransaction.commit(replacementToken: "fixture-token", credentialID: fresh, previousCredentialID: previous,
                saveSecret: save, persistSource: { events.append("persist-failed"); return false }, credentialIsReferenced: { _ in false })
            fatalError("missing source accepted")
        } catch CloudflareSourceCommitError.sourceMissing {
            check(events == ["save:\(fresh)", "persist-failed", "delete:\(fresh)"], "failed source update removes only new credential and preserves old one")
        }
        print("PASS: \(checks) Cloudflare source draft and commit checks; no network, user settings, or Keychain access")
    }
}
