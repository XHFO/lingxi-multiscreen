import Foundation

/// Exercises actual production AppSettings methods and Codable entirely in memory.
@main struct CloudflareSourceSettingsTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
            print("PASS " + message)
        }
        func configuration(_ index: Int) -> CloudflareAnalyticsSettings {
            var value = CloudflareAnalyticsSettings()
            value.zoneID = String(repeating: String(index), count: 32)
            value.zoneName = "site-\(index).example"
            value.hostname = "www.site-\(index).example"
            return value
        }
        func snapshot(_ value: CloudflareAnalyticsSettings, requests: Double) -> CloudflareAnalyticsSnapshot {
            let end = Date(timeIntervalSince1970: 1_790_000_000)
            return .init(zoneID: value.zoneID, hostname: value.hostname, period: value.period,
                start: end.addingTimeInterval(-value.period.seconds), end: end, sampledAt: end,
                requests: requests, bytes: requests * 1024, regions: [], trend: [])
        }
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        func decode(_ value: [String: Any]) throws -> AppSettings {
            try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: value))
        }
        func roundTrip(_ value: AppSettings) throws -> AppSettings {
            try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(value))
        }

        let empty = try decode([:])
        check(empty.cloudflareSources.isEmpty && empty.cloudflareSourceID == nil, "empty legacy settings do not create a fake source")
        let emptyRoundTrip = try roundTrip(empty)
        check(emptyRoundTrip.cloudflareSources.isEmpty && emptyRoundTrip.cloudflareSourceID == nil, "empty source list survives Codable round-trip")
        empty.cloudflare.period = .week
        check(empty.cloudflareSources.isEmpty, "unconfigured defaults stay outside the source library")
        let preferenceRoundTrip = try roundTrip(empty)
        check(preferenceRoundTrip.cloudflare.period == .week && preferenceRoundTrip.cloudflare.credentialID == empty.cloudflare.credentialID,
              "unconfigured preferences and credential reference remain stable without inventing a source")

        let first = configuration(1), second = configuration(2)
        let firstSnapshot = snapshot(first, requests: 100), secondSnapshot = snapshot(second, requests: 200)
        let migrated = try decode(["cloudflare": try object(first), "cloudflareSnapshot": try object(firstSnapshot)])
        check(migrated.cloudflareSources.count == 1, "build53 single-site configuration migrates to one source")
        check(migrated.activeCloudflareSource?.name == first.zoneName, "migrated source receives its website name")
        check(migrated.cloudflare == first && migrated.activeCloudflareSource?.configuration == first, "migration preserves exact configuration and Keychain reference")
        check(migrated.cloudflareSnapshot == firstSnapshot && migrated.activeCloudflareSource?.snapshot == firstSnapshot, "migration preserves the matching cached reading")
        let migratedID = migrated.cloudflareSourceID!
        let remigrated = try roundTrip(migrated)
        check(remigrated.cloudflareSourceID == migratedID && remigrated.cloudflareSources == migrated.cloudflareSources, "migration round-trip keeps stable source identifiers")
        let mismatchedLegacy = try decode(["cloudflare": try object(first), "cloudflareSnapshot": try object(secondSnapshot)])
        check(mismatchedLegacy.cloudflareSnapshot == nil && mismatchedLegacy.activeCloudflareSource?.snapshot == nil, "migration drops another website's stale cache")

        let settings = AppSettings()
        var notifications = 0
        var coherentNotifications = true
        settings.onChange = {
            notifications += 1
            if let source = settings.activeCloudflareSource {
                coherentNotifications = coherentNotifications && source.configuration == settings.cloudflare && source.snapshot == settings.cloudflareSnapshot
            } else {
                coherentNotifications = coherentNotifications && settings.cloudflareSources.isEmpty && settings.cloudflareSourceID == nil
            }
        }
        let firstID = settings.addCloudflareSource(name: "  主站  ", configuration: first, snapshot: firstSnapshot)
        check(settings.cloudflareSourceID == firstID && settings.activeCloudflareSource?.name == "主站", "adding a source selects it and trims its name")
        check(notifications == 1 && coherentNotifications, "add emits one coherent persistence notification")
        let secondID = settings.addCloudflareSource(name: "第二站", configuration: second, snapshot: secondSnapshot, select: false)
        check(settings.cloudflareSourceID == firstID && settings.cloudflare == first && settings.cloudflareSnapshot == firstSnapshot, "adding without selection keeps the active configuration and cache")
        check(settings.cloudflareSources[1].configuration.credentialID != settings.cloudflareSources[0].configuration.credentialID, "independent source configurations keep independent credential references")
        check(settings.selectCloudflareSource(secondID), "another source can be selected")
        check(settings.cloudflare == second && settings.cloudflareSnapshot == secondSnapshot, "selection loads the selected website and its own cached data")
        check(settings.cloudflareSources[0].configuration == first && settings.cloudflareSources[0].snapshot == firstSnapshot, "selection does not overwrite the previous website")
        let selectedNotificationCount = notifications
        check(settings.selectCloudflareSource(secondID) && notifications == selectedNotificationCount, "selecting the current source is a no-op")
        check(!settings.selectCloudflareSource(UUID()) && notifications == selectedNotificationCount, "unknown source selection leaves state unchanged")

        settings.cloudflare.rankByTraffic = false
        settings.cloudflare.refreshMinutes = 10
        settings.cloudflare.domainLetterCase = .uppercase
        settings.cloudflare.displayLanguage = .english
        check(settings.activeCloudflareSource?.configuration.domainLetterCase == .uppercase,
              "domain case persists in the active source")
        check(settings.cloudflareSnapshot == secondSnapshot && settings.cloudflare.hostname == second.hostname,
              "domain case retains the exact hostname and valid cached statistics")
        let displayRoundTrip = try roundTrip(settings)
        check(displayRoundTrip.cloudflare.domainLetterCase == .uppercase && displayRoundTrip.cloudflareSnapshot == secondSnapshot,
              "domain case and cached data survive full settings reload")
        check(displayRoundTrip.cloudflare.displayLanguage == .english && settings.activeCloudflareSource?.configuration.displayLanguage == .english,
              "display language persists in the selected data source and full settings reload")
        check(settings.activeCloudflareSource?.configuration.rankByTraffic == false && settings.activeCloudflareSource?.configuration.refreshMinutes == 10, "legacy direct configuration edits persist in the selected source")
        check(settings.cloudflareSnapshot == secondSnapshot, "presentation and refresh interval edits preserve matching statistics")
        check(settings.cloudflareSources[0].configuration == first, "direct active edits leave other sources untouched")
        settings.cloudflare.period = .week
        check(settings.cloudflareSnapshot == nil && settings.activeCloudflareSource?.snapshot == nil, "changing query range invalidates only that source's cache")
        let updatedSecond = settings.cloudflare
        let updatedSecondSnapshot = snapshot(updatedSecond, requests: 250)
        settings.cloudflareSnapshot = updatedSecondSnapshot
        check(settings.activeCloudflareSource?.snapshot == updatedSecondSnapshot, "legacy refresh writes reach the active source")
        settings.cloudflareSnapshot = firstSnapshot
        check(settings.cloudflareSnapshot == updatedSecondSnapshot, "a stale response for another website cannot replace valid active data")
        settings.cloudflareSnapshot = nil
        check(settings.activeCloudflareSource?.snapshot == nil, "explicit cache clearing reaches only the active source")
        settings.cloudflareSnapshot = updatedSecondSnapshot
        check(settings.selectCloudflareSource(firstID) && settings.cloudflareSnapshot == firstSnapshot, "switching back restores the previous source's original cache")

        var inactivePreferences = settings.cloudflareSources[1]
        inactivePreferences.configuration.refreshMinutes = 45
        inactivePreferences.configuration.presentation = .ranking
        check(settings.updateCloudflareSource(inactivePreferences), "inactive source refresh frequency and style can be saved without selecting it")
        check(settings.cloudflareSourceID == firstID && settings.cloudflare == first && settings.cloudflareSnapshot == firstSnapshot,
              "editing another source's frequency and style leaves the active website and reading intact")
        check(settings.cloudflareSources[1].snapshot == updatedSecondSnapshot,
              "frequency and style edits retain the inactive website's cached reading")
        let inactivePreferenceReload = try roundTrip(settings)
        check(inactivePreferenceReload.cloudflareSources[1].configuration.refreshMinutes == 45
              && inactivePreferenceReload.cloudflareSources[1].configuration.presentation == .ranking
              && inactivePreferenceReload.cloudflareSources[1].snapshot == updatedSecondSnapshot,
              "inactive source frequency, style and reading survive a complete settings reload")

        var editedSecond = settings.cloudflareSources[1]
        editedSecond.name = "  已编辑的第二站  "
        editedSecond.configuration.hostname = "api.site-2.example"
        check(settings.updateCloudflareSource(editedSecond), "an existing source can be edited without selection")
        check(settings.cloudflareSources[1].name == "已编辑的第二站" && settings.cloudflareSources[1].snapshot == nil, "source edits normalize names and drop mismatching caches")
        check(settings.cloudflareSourceID == firstID && settings.cloudflare == first && settings.cloudflareSnapshot == firstSnapshot, "editing an inactive source leaves the current card intact")
        var editedFirst = settings.cloudflareSources[0]
        editedFirst.name = "主站新版"
        editedFirst.configuration.rankByTraffic = false
        check(settings.updateCloudflareSource(editedFirst), "the active source can be edited")
        check(settings.cloudflare.rankByTraffic == false && settings.activeCloudflareSource?.name == "主站新版" && settings.cloudflareSnapshot == firstSnapshot, "active source edit updates the compatibility projection coherently")
        check(!settings.updateCloudflareSource(.init(name: "不存在", configuration: first)), "updating an unknown source does not create a record")
        let saved = try roundTrip(settings)
        check(saved.cloudflareSources == settings.cloudflareSources && saved.cloudflareSourceID == settings.cloudflareSourceID, "multiple sources and active selection survive actual AppSettings Codable")
        check(saved.cloudflare == settings.cloudflare && saved.cloudflareSnapshot == settings.cloudflareSnapshot, "Codable projection matches the selected source after reload")
        check(coherentNotifications, "all persistence callbacks observe matching source and compatibility projection")

        var shared = second
        shared.credentialID = first.credentialID
        let sharedID = settings.addCloudflareSource(name: "共享授权", configuration: shared, snapshot: secondSnapshot, select: false)
        check(settings.cloudflareSources.last?.configuration.credentialID == first.credentialID, "explicitly shared Keychain references are preserved")
        check(settings.removeCloudflareSource(sharedID), "removing an inactive source succeeds")
        check(settings.cloudflareSourceID == firstID && settings.cloudflare.credentialID == first.credentialID, "source removal leaves another source's shared credential reference intact")
        check(settings.removeCloudflareSource(firstID), "the selected source can be removed")
        check(settings.cloudflareSourceID == secondID && settings.cloudflare == editedSecond.configuration && settings.cloudflareSnapshot == nil, "removing active source selects the first remaining source with its own data")
        check(!settings.removeCloudflareSource(firstID), "repeated removal does not change state")
        check(settings.removeCloudflareSource(secondID), "the last source can be removed")
        check(settings.cloudflareSources.isEmpty && settings.cloudflareSourceID == nil && settings.cloudflare.zoneID.isEmpty && settings.cloudflareSnapshot == nil, "removing last source clears compatibility configuration and cache")
        let deletedRoundTrip = try roundTrip(settings)
        check(deletedRoundTrip.cloudflareSources.isEmpty, "deleted sources do not return after Codable reload")
        let noResurrection = try decode(["cloudflareSources": [], "cloudflare": try object(first), "cloudflareSnapshot": try object(firstSnapshot)])
        check(noResurrection.cloudflareSources.isEmpty && noResurrection.cloudflare.zoneID.isEmpty && noResurrection.cloudflareSnapshot == nil, "explicit empty source list overrides stale legacy fields")

        let duplicateID = UUID()
        let duplicateRecords = [CloudflareAnalyticsSource(id: duplicateID, name: "一", configuration: first, snapshot: firstSnapshot),
                                CloudflareAnalyticsSource(id: duplicateID, name: "二", configuration: second, snapshot: secondSnapshot)]
        let deduplicated = try decode(["cloudflareSources": try object(duplicateRecords), "cloudflareSourceID": duplicateID.uuidString])
        check(deduplicated.cloudflareSources.count == 2 && Set(deduplicated.cloudflareSources.map(\.id)).count == 2, "duplicate source identifiers are repaired without losing either source")
        check(deduplicated.cloudflareSourceID == duplicateID && deduplicated.cloudflare == first, "duplicate selected identifier resolves to the first source predictably")
        check(deduplicated.cloudflareSources[1].configuration.credentialID == second.credentialID, "repairing source identifiers does not alter credential references")
        let repairedRoundTrip = try roundTrip(deduplicated)
        check(repairedRoundTrip.cloudflareSources == deduplicated.cloudflareSources, "repaired identifiers stay stable on subsequent reload")
        var invalidRecord = try object(CloudflareAnalyticsSource(name: "", configuration: second)) as! [String: Any]
        invalidRecord["id"] = "not-a-uuid"
        invalidRecord["name"] = "  "
        let repaired = try decode(["cloudflareSources": [invalidRecord], "cloudflareSourceID": "invalid-id"])
        check(repaired.cloudflareSources.count == 1 && repaired.cloudflareSourceID == repaired.cloudflareSources[0].id, "invalid record and selection identifiers recover to a usable source")
        check(repaired.activeCloudflareSource?.name == second.zoneName && repaired.cloudflare == second, "invalid identifiers do not lose website configuration or resolved name")
        let partialConfiguration = try JSONDecoder().decode(CloudflareAnalyticsSettings.self,
            from: JSONSerialization.data(withJSONObject: ["zoneID": first.zoneID, "credentialID": "invalid-reference"]))
        check(partialConfiguration.zoneID == first.zoneID && partialConfiguration.refreshMinutes == 5 && partialConfiguration.period == .day,
              "invalid credential identifiers and missing preference fields recover without losing website data")
        let unknownSelection = try decode(["cloudflareSources": try object(duplicateRecords), "cloudflareSourceID": UUID().uuidString])
        check(unknownSelection.cloudflareSourceID == duplicateID && unknownSelection.cloudflare == first, "unknown persisted selection falls back deterministically")

        let directLegacy = AppSettings()
        directLegacy.cloudflare = first
        directLegacy.cloudflareSnapshot = firstSnapshot
        check(directLegacy.cloudflareSources.count == 1 && directLegacy.activeCloudflareSource?.configuration == first && directLegacy.activeCloudflareSource?.snapshot == firstSnapshot, "legacy clients configuring the first site create a synchronized source")
        let alternate = directLegacy.addCloudflareSource(name: "", configuration: second, snapshot: firstSnapshot)
        check(directLegacy.cloudflareSourceID == alternate && directLegacy.cloudflareSnapshot == nil, "adding with an unrelated cached snapshot never exposes it")

        let rangeSettings = AppSettings()
        let rangeID = rangeSettings.addCloudflareSource(name: "Range site", configuration: first, snapshot: firstSnapshot)
        let unrelatedID = rangeSettings.addCloudflareSource(name: "Unrelated site", configuration: second,
            snapshot: secondSnapshot, select: false)
        let unrelatedBefore = rangeSettings.cloudflareSources.first { $0.id == unrelatedID }!
        for period in [CloudflareAnalyticsPeriod.week, .month, .day] {
            let before = rangeSettings.activeCloudflareSource!
            let oldReading = before.snapshot!
            var ranged = before
            ranged.configuration.period = period
            check(rangeSettings.updateCloudflareSource(ranged), "saved source accepts a \(period.rawValue) range change")
            check(rangeSettings.cloudflareSourceID == rangeID && rangeSettings.cloudflare.period == period
                  && rangeSettings.activeCloudflareSource?.configuration.period == period,
                  "range change updates active source and compatibility projection for \(period.rawValue)")
            check(rangeSettings.cloudflareSnapshot == nil && rangeSettings.activeCloudflareSource?.snapshot == nil,
                  "changing to \(period.rawValue) removes the previous period's cached statistics")
            check(rangeSettings.cloudflare.credentialID == before.configuration.credentialID
                  && rangeSettings.cloudflare.zoneID == before.configuration.zoneID
                  && rangeSettings.cloudflare.hostname == before.configuration.hostname,
                  "range change preserves credentials and website identity for \(period.rawValue)")
            check(rangeSettings.cloudflareSources.first { $0.id == unrelatedID } == unrelatedBefore,
                  "range change leaves another site's configuration and reading intact")
            let reload = try roundTrip(rangeSettings)
            check(reload.cloudflare.period == period && reload.cloudflareSourceID == rangeID
                  && reload.activeCloudflareSource?.configuration.period == period && reload.cloudflareSnapshot == nil,
                  "\(period.rawValue) selection survives complete Codable reload without old cache")
            rangeSettings.cloudflareSnapshot = oldReading
            check(rangeSettings.cloudflareSnapshot == nil && rangeSettings.activeCloudflareSource?.snapshot == nil,
                  "late response for old period cannot reappear while waiting for \(period.rawValue)")
            let reading = snapshot(rangeSettings.cloudflare, requests: 300 + period.seconds)
            rangeSettings.cloudflareSnapshot = reading
            check(rangeSettings.cloudflareSnapshot == reading && rangeSettings.activeCloudflareSource?.snapshot == reading,
                  "matching \(period.rawValue) response is accepted by the active source")
            rangeSettings.cloudflareSnapshot = oldReading
            check(rangeSettings.cloudflareSnapshot == reading,
                  "late old-period response cannot replace newer \(period.rawValue) data")
        }
        var sameRangeDisplay = rangeSettings.activeCloudflareSource!
        let sameRangeReading = sameRangeDisplay.snapshot
        sameRangeDisplay.configuration.presentation = .ranking
        check(rangeSettings.updateCloudflareSource(sameRangeDisplay)
              && rangeSettings.cloudflareSnapshot == sameRangeReading,
              "display-only changes retain the selected period's valid cached statistics")
        var inactiveRange = unrelatedBefore
        inactiveRange.configuration.period = .month
        let activeBeforeInactiveEdit = rangeSettings.activeCloudflareSource
        check(rangeSettings.updateCloudflareSource(inactiveRange), "inactive source's range can be edited without selection")
        check(rangeSettings.activeCloudflareSource == activeBeforeInactiveEdit && rangeSettings.cloudflareSourceID == rangeID,
              "editing another site's range never changes active site or its cached statistics")
        check(rangeSettings.cloudflareSources.first { $0.id == unrelatedID }?.configuration.period == .month
              && rangeSettings.cloudflareSources.first { $0.id == unrelatedID }?.snapshot == nil,
              "inactive site's new range is saved and only its old cache is discarded")
        let inactiveRangeReload = try roundTrip(rangeSettings)
        check(inactiveRangeReload.cloudflareSources == rangeSettings.cloudflareSources,
              "independent active and inactive period selections survive complete settings reload")

        print("PASS: \(checks) actual AppSettings Cloudflare source checks; in-memory Codable only, no user files, Keychain or network access")
    }
}
