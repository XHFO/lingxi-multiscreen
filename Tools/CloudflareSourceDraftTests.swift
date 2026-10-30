import Foundation
import LinxDisplayCore

@main struct CloudflareSourceDraftTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError(message) }
    }

    static func main() async throws {
        check(CloudflareSourceDraftPolicy.initialConnectionStep(editingExistingSource: false) == 0,
              "new source retains the complete Token guide")
        check(CloudflareSourceDraftPolicy.initialConnectionStep(editingExistingSource: true) == 2,
              "explicit saved-source connection edit skips Token creation and starts with its website")
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
        var displayDraft = normalized
        displayDraft.refreshMinutes = 30
        displayDraft.presentation = .ranking
        displayDraft.rankByTraffic = false
        displayDraft.domainLetterCase = .uppercase
        displayDraft.displayLanguage = .english
        displayDraft.accentTone = .custom
        displayDraft.customAccentHex = "#21AACC"
        let currentSource = CloudflareAnalyticsSource(name: "Current website", configuration: normalized, snapshot: snapshot)
        let displayEdited = CloudflareSourceDraftPolicy.applyingDisplayPreferences(displayDraft, to: currentSource)
        check(displayEdited.id == currentSource.id && displayEdited.name == currentSource.name,
              "display editing keeps the saved source identity and latest name")
        check(displayEdited.configuration.refreshMinutes == 30 && displayEdited.configuration.presentation == .ranking
              && !displayEdited.configuration.rankByTraffic && displayEdited.configuration.domainLetterCase == .uppercase
              && displayEdited.configuration.displayLanguage == .english && displayEdited.configuration.accentTone == .custom
              && displayEdited.configuration.customAccentHex == "#21AACC",
              "saved-source preferences apply refresh frequency and all card display controls")
        check(displayEdited.configuration.hasSameQuery(as: currentSource.configuration) && displayEdited.snapshot == snapshot,
              "display editing retains credentials, query and cached reading without credential reads")
        var concurrent = currentSource
        concurrent.name = "Renamed while settings were open"
        concurrent.configuration.hostname = "new.example.com"
        concurrent.configuration.credentialID = UUID()
        concurrent.configuration.period = .week
        concurrent.snapshot = nil
        let merged = CloudflareSourceDraftPolicy.applyingDisplayPreferences(displayDraft, to: concurrent)
        check(merged.name == concurrent.name && merged.configuration.hasSameQuery(as: concurrent.configuration)
              && merged.snapshot == nil, "stale display binding cannot overwrite a newer connection, query, name or reading")
        for period in CloudflareAnalyticsPeriod.allCases {
            let ranged = CloudflareSourceDraftPolicy.applyingPeriod(period, to: currentSource)
            check(ranged.configuration.period == period,
                  "period control applies \(period.rawValue) to the saved source")
            check(ranged.id == currentSource.id && ranged.name == currentSource.name
                  && ranged.configuration.credentialID == currentSource.configuration.credentialID
                  && ranged.configuration.zoneID == currentSource.configuration.zoneID
                  && ranged.configuration.zoneName == currentSource.configuration.zoneName
                  && ranged.configuration.hostname == currentSource.configuration.hostname,
                  "period editing preserves source identity, name, credential reference and website for \(period.rawValue)")
            check(ranged.configuration.refreshMinutes == currentSource.configuration.refreshMinutes
                  && ranged.configuration.presentation == currentSource.configuration.presentation
                  && ranged.configuration.rankByTraffic == currentSource.configuration.rankByTraffic
                  && ranged.configuration.domainLetterCase == currentSource.configuration.domainLetterCase
                  && ranged.configuration.displayLanguage == currentSource.configuration.displayLanguage
                  && ranged.configuration.accentTone == currentSource.configuration.accentTone
                  && ranged.configuration.customAccentHex == currentSource.configuration.customAccentHex,
                  "period editing preserves display preferences and cadence for \(period.rawValue)")
            check(ranged.snapshot == (period == normalized.period ? snapshot : nil),
                  "period editing keeps only a reading matching \(period.rawValue)")
            check(ranged.configuration.hasSameQuery(as: currentSource.configuration) == (period == normalized.period),
                  "query identity changes exactly when the selected period changes")
            let queryNow = Date(timeIntervalSince1970: 1_800_000_000)
            let queryReading = try await CloudflareAnalyticsClient.fetch(ranged.configuration, token: "fixture-token", now: queryNow) { request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let variables = body["variables"] as! [String: Any]
                let filter = variables["filter"] as! [String: Any]
                let formatter = ISO8601DateFormatter()
                check(filter["datetime_geq"] as? String == formatter.string(from: queryNow.addingTimeInterval(-period.seconds))
                      && filter["datetime_lt"] as? String == formatter.string(from: queryNow),
                      "\(period.rawValue) changes the actual outgoing statistics time filter")
                let query = body["query"] as! String
                check(query.contains(period == .month ? "date_ASC" : "datetimeHour_ASC"),
                      "\(period.rawValue) requests the appropriate trend aggregation bucket")
                return (payload, 200)
            }
            check(queryReading.period == period && queryReading.start == queryNow.addingTimeInterval(-period.seconds)
                  && queryReading.end == queryNow && queryReading.matches(ranged.configuration),
                  "\(period.rawValue) fetch produces a snapshot bound to the requested range")
        }
        let concurrentPeriod = CloudflareSourceDraftPolicy.applyingPeriod(.month, to: concurrent)
        check(concurrentPeriod.configuration.period == .month
              && concurrentPeriod.configuration.hostname == concurrent.configuration.hostname
              && concurrentPeriod.configuration.credentialID == concurrent.configuration.credentialID
              && concurrentPeriod.name == concurrent.name,
              "period editing merges into the latest connection without reviving stale website fields")
        displayDraft.refreshMinutes = 0
        check(CloudflareSourceDraftPolicy.applyingDisplayPreferences(displayDraft, to: currentSource).configuration.refreshMinutes == 5,
              "saved-source refresh frequency respects the five-minute minimum")
        displayDraft.refreshMinutes = 500
        check(CloudflareSourceDraftPolicy.applyingDisplayPreferences(displayDraft, to: currentSource).configuration.refreshMinutes == 60,
              "saved-source refresh frequency respects the sixty-minute maximum")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var cadence = normalized
        cadence.refreshMinutes = 30
        check(!cadence.isRefreshDue(lastAttempt: now.addingTimeInterval(-600), now: now),
              "longer frequency waits relative to the previous attempt")
        cadence.refreshMinutes = 5
        check(cadence.isRefreshDue(lastAttempt: now.addingTimeInterval(-600), now: now),
              "shortening frequency becomes due immediately on the next scheduler tick")
        check(!cadence.isRefreshDue(lastAttempt: now.addingTimeInterval(-299), now: now)
              && cadence.isRefreshDue(lastAttempt: now.addingTimeInterval(-300), now: now),
              "refresh follows the selected interval boundary")
        check(cadence.isRefreshDue(lastAttempt: nil, now: now), "a source with no previous attempt is due")
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
