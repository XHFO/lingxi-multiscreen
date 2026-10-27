import Foundation

@main struct CloudflareAnalyticsTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !value() { fatalError(description) }
    }
    static func response(_ totals: String = "[{\"count\":100,\"sum\":{\"edgeResponseBytes\":4096}}]",
                         regions: String = "[{\"count\":40,\"sum\":{\"edgeResponseBytes\":1024},\"dimensions\":{\"clientCountryName\":\"US\"}},{\"count\":60,\"sum\":{\"edgeResponseBytes\":3072},\"dimensions\":{\"clientCountryName\":\"CN\"}}]",
                         trend: String = "[{\"count\":100,\"sum\":{\"edgeResponseBytes\":4096},\"dimensions\":{\"datetimeHour\":\"2026-10-24T01:00:00Z\"}}]") -> Data {
        Data("{\"data\":{\"viewer\":{\"zones\":[{\"totals\":\(totals),\"regions\":\(regions),\"trend\":\(trend)}]}},\"errors\":null}".utf8)
    }
    static func main() async throws {
        var config = CloudflareAnalyticsSettings()
        check(!config.isValid, "empty config rejected")
        config.zoneID = String(repeating: "a", count: 32)
        check(config.isValid, "zone valid")
        config.hostname = "https://example.com/path"
        check(!config.isValid, "URLs are not hostname filters")
        config.hostname = "www.example.com"
        let mixedDomain = "WWW.Example.COM"
        check(CloudflareDomainLetterCase.original.display(mixedDomain) == mixedDomain, "original display preserves input")
        check(CloudflareDomainLetterCase.lowercase.display(mixedDomain) == "www.example.com", "lowercase domain presentation")
        check(CloudflareDomainLetterCase.uppercase.display(mixedDomain) == "WWW.EXAMPLE.COM", "uppercase domain presentation")
        let legacySettings = try JSONDecoder().decode(CloudflareAnalyticsSettings.self, from: Data("{}".utf8))
        check(legacySettings.domainLetterCase == .original, "legacy settings preserve their domain appearance")
        check(legacySettings.displayLanguage == .chinese, "legacy settings retain Chinese display")
        let futureSettings = try JSONDecoder().decode(CloudflareAnalyticsSettings.self,
            from: Data("{\"domainLetterCase\":\"future-mode\"}".utf8))
        check(futureSettings.domainLetterCase == .original, "unknown presentation recovers without losing configuration")
        let unknownLanguage = try JSONDecoder().decode(CloudflareAnalyticsSettings.self,
            from: Data("{\"displayLanguage\":\"future-language\"}".utf8))
        check(unknownLanguage.displayLanguage == .chinese, "unknown display language recovers to Chinese")
        check(CloudflareDisplayLanguage.english.regionName("US") == "United States", "English region names use English locale")
        check(CloudflareDisplayLanguage.chinese.regionName("US") == "美国", "Chinese region names use Chinese locale")
        check(CloudflareDisplayLanguage.english.text("请求数", "Requests") == "Requests", "English copy selection")
        check(CloudflareDisplayLanguage.chinese.text("请求数", "Requests") == "请求数", "Chinese copy selection")
        for language in CloudflareDisplayLanguage.allCases {
            check(language.bytesText(0) == "0 B", "zero uses standard bytes unit in either language")
            check(language.bytesText(633_100_000).hasSuffix(" MB"), "traffic uses international units independent of system locale")
            check(language.bytesText(.infinity) == "—" && language.countText(-1) == "—", "localized numbers reject invalid values")
            check(language.countText(15_619) == "15,619", "request counts retain readable grouping")
        }
        let now = Date(timeIntervalSince1970: 1792800000)
        let data = response()
        let sample = try await CloudflareAnalyticsClient.fetch(config, token: "test-token", now: now) { request in
            check(request.url?.absoluteString == "https://api.cloudflare.com/client/v4/graphql", "fixed official endpoint")
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "bearer header")
            check(request.httpMethod == "POST", "uses POST")
            let root = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let query = root["query"] as! String
            check(query.contains("count sum { edgeResponseBytes }"), "requests are count, bytes are edge bytes")
            check(!query.contains("visits") && !query.contains("test-token"), "no fabricated visitors or token in query")
            let variables = root["variables"] as! [String: Any]
            let filter = variables["filter"] as! [String: Any]
            check(filter["clientRequestHTTPHost"] as? String == "www.example.com", "optional hostname exact filter")
            check(filter["requestSource"] as? String == "eyeball", "edge client traffic only")
            check(filter["datetime_lt"] as? String == ISO8601DateFormatter().string(from: now), "bounded window")
            return (data, 200)
        }
        check(sample.requests == 100 && sample.bytes == 4096, "total metrics")
        check(sample.end.timeIntervalSince(sample.start) == 86400, "24-hour range")
        check(sample.rankedRegions(byTraffic: true).first?.code == "CN", "traffic sorting")
        check(sample.rankedRegions(byTraffic: false).first?.requests == 60, "request sorting")
        check(sample.trend.count == 1 && sample.matches(config), "matching source cache")
        for letterCase in CloudflareDomainLetterCase.allCases {
            var displaySettings = config
            displaySettings.domainLetterCase = letterCase
            let decoded = try JSONDecoder().decode(CloudflareAnalyticsSettings.self, from: JSONEncoder().encode(displaySettings))
            check(decoded.domainLetterCase == letterCase && decoded.hostname == config.hostname,
                  "domain display preference persists without altering hostname")
            check(sample.matches(decoded), "domain appearance preserves statistics cache")
            check(config.hasSameQuery(as: decoded), "domain appearance keeps the in-flight query identity")
            _ = try await CloudflareAnalyticsClient.fetch(decoded, token: "test-token", now: now) { request in
                let root = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let filter = (root["variables"] as! [String: Any])["filter"] as! [String: Any]
                check(filter["clientRequestHTTPHost"] as? String == config.hostname,
                      "display preference never changes the API filter")
                return (data, 200)
            }
        }
        var another = config; another.hostname = "other.example.com"
        check(!sample.matches(another), "cache cannot cross hostname")
        check(!config.hasSameQuery(as: another), "different hostname changes the query identity")
        another = config; another.period = .week
        check(!sample.matches(another), "cache cannot cross range")
        check(!config.hasSameQuery(as: another), "different period changes the query identity")
        another = config; another.zoneID = String(repeating: "b", count: 32)
        check(!config.hasSameQuery(as: another), "different site changes the query identity")
        another = config; another.credentialID = UUID()
        check(!config.hasSameQuery(as: another), "different credential changes the query identity")
        another = config; another.rankByTraffic = false; another.presentation = .ranking; another.refreshMinutes = 10
        check(config.hasSameQuery(as: another), "visual preferences and schedule keep the same statistics query")
        for language in CloudflareDisplayLanguage.allCases {
            var translated = config; translated.displayLanguage = language
            let decoded = try JSONDecoder().decode(CloudflareAnalyticsSettings.self, from: JSONEncoder().encode(translated))
            check(decoded.displayLanguage == language, "display language survives Codable")
            check(config.hasSameQuery(as: decoded) && sample.matches(decoded), "display language retains query identity and valid cache")
        }
        let encoded = try JSONEncoder().encode(config)
        check(!String(data: encoded, encoding: .utf8)!.contains("test-token"), "settings contain no token")
        check(CloudflareAnalyticsSnapshot.countText(0) == "0", "zero is meaningful")
        check(CloudflareAnalyticsSnapshot.bytesText(.infinity) == "—", "invalid count safe")
        for status in [401, 403, 429, 500, 302] {
            do { _ = try await CloudflareAnalyticsClient.fetch(config, token: "test-token") { _ in (data, status) }; fatalError("HTTP failure accepted") }
            catch let error as CloudflareAnalyticsError {
                check(!(error.localizedDescription.contains("test-token")), "error redacts token")
            }
        }
        let badResponses: [Data] = [
            Data("{\"errors\":[{\"message\":\"test-token secret detail\"}],\"data\":null}".utf8),
            Data("{\"data\":{\"viewer\":{\"zones\":[]}}}".utf8),
            response("[{\"count\":-1,\"sum\":{\"edgeResponseBytes\":2}}]"),
            response("[{\"count\":true,\"sum\":{\"edgeResponseBytes\":2}}]"),
            response("[]"), response(regions: "[{\"count\":1}]")
        ]
        for bad in badResponses {
            do { _ = try await CloudflareAnalyticsClient.fetch(config, token: "test-token") { _ in (bad, 200) }; fatalError("Incomplete data accepted") }
            catch let error as CloudflareAnalyticsError { check(!error.localizedDescription.contains("secret detail"), "API errors sanitized") }
        }
        let zero = try await CloudflareAnalyticsClient.fetch(config, token: "test-token") { _ in (response("[]", regions: "[]", trend: "[]"), 200) }
        check(zero.requests == 0 && zero.bytes == 0, "empty dataset is zero")
        var calls = 0
        let zones = try await CloudflareAnalyticsClient.zones(token: "test-token") { request in
            calls += 1
            check(request.url?.query?.contains("page=\(calls)") == true, "zone pagination")
            let page = calls == 1 ? "b.example" : "a.example"
            return (Data("{\"success\":true,\"result\":[{\"id\":\"\(calls)\",\"name\":\"\(page)\"}],\"result_info\":{\"total_pages\":2}}".utf8), 200)
        }
        check(calls == 2 && zones.map(\.name) == ["a.example", "b.example"], "zone pagination sorted")
        do { _ = try await CloudflareAnalyticsClient.fetch(config, token: "bad\r\nheader") { _ in fatalError("must not send malformed token") }; fatalError("token accepted") }
        catch { check(true, "header injection rejected") }
        do { _ = try await CloudflareAnalyticsClient.fetch(config, token: "test-token") { _ in throw CancellationError() }; fatalError("cancel accepted") }
        catch is CancellationError { check(true, "cancellation preserved") }
        print("PASS: \(checks) Cloudflare client checks; no real credentials, Keychain writes or network requests")
    }
}
