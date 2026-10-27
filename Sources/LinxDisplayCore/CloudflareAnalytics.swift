import Foundation
import CoreGraphics

public enum CloudflareAnalyticsPeriod: String, Codable, CaseIterable, Identifiable {
    case day, week, month
    public var id: String { rawValue }
    public var title: String { switch self { case .day: return String(localized: "最近 24 小时"); case .week: return String(localized: "最近 7 天"); case .month: return String(localized: "最近 30 天") } }
    public var seconds: TimeInterval { switch self { case .day: return 86400; case .week: return 7 * 86400; case .month: return 30 * 86400 } }
}

public enum CloudflareAnalyticsPresentation: String, Codable, CaseIterable, Identifiable {
    case worldMap, ranking
    public var id: String { rawValue }
    public var title: String { self == .worldMap ? String(localized: "全球热区") : String(localized: "地区排行") }
}

/// Display preference only; the source hostname and API filters retain their exact values.
public enum CloudflareDomainLetterCase: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, lowercase, uppercase
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .original: return String(localized: "原样")
        case .lowercase: return String(localized: "小写")
        case .uppercase: return String(localized: "大写")
        }
    }
    public func display(_ domain: String) -> String {
        switch self {
        case .original: return domain
        case .lowercase: return domain.lowercased(with: Locale(identifier: "en_US_POSIX"))
        case .uppercase: return domain.uppercased(with: Locale(identifier: "en_US_POSIX"))
        }
    }
}

public enum CloudflareDisplayLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case chinese, english
    public var id: String { rawValue }
    public var title: String { self == .chinese ? String(localized: "中文") : "English" }
    public var locale: Locale { Locale(identifier: self == .chinese ? "zh_CN" : "en_US") }
    public func text(_ chinese: String, _ english: String) -> String {
        self == .chinese ? chinese : english
    }
    public func regionName(_ code: String) -> String {
        locale.localizedString(forRegionCode: code) ?? code
    }
    public func countText(_ value: Double) -> String {
        CloudflareAnalyticsSnapshot.countText(value, language: self)
    }
    public func bytesText(_ value: Double) -> String {
        CloudflareAnalyticsSnapshot.bytesText(value, language: self)
    }
}

/// One website analytics configuration. Tokens never enter Codable settings or device frames.
/// 单个网站统计配置；Token 不进入设置导出、画板文件或设备传输。
public struct CloudflareAnalyticsSettings: Codable, Equatable {
    public var credentialID = UUID()
    public var zoneID = ""
    public var zoneName = ""
    public var hostname = ""
    public var period: CloudflareAnalyticsPeriod = .day
    public var refreshMinutes = 5
    public var rankByTraffic = true
    public var presentation: CloudflareAnalyticsPresentation = .worldMap
    public var domainLetterCase: CloudflareDomainLetterCase = .original
    public var displayLanguage: CloudflareDisplayLanguage = .chinese
    /// Card emphasize color; `.system` follows the keyboard theme accent, otherwise CF brand orange fallback.
    public var accentTone: AccentTone = .orange
    public var customAccentHex: String? = nil
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case credentialID, zoneID, zoneName, hostname, period, refreshMinutes, rankByTraffic, presentation, domainLetterCase, displayLanguage, accentTone, customAccentHex
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        credentialID = (try? values.decode(UUID.self, forKey: .credentialID)) ?? UUID()
        zoneID = try values.decodeIfPresent(String.self, forKey: .zoneID) ?? ""
        zoneName = try values.decodeIfPresent(String.self, forKey: .zoneName) ?? ""
        hostname = try values.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        period = (try? values.decode(CloudflareAnalyticsPeriod.self, forKey: .period)) ?? .day
        refreshMinutes = try values.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? 5
        rankByTraffic = try values.decodeIfPresent(Bool.self, forKey: .rankByTraffic) ?? true
        presentation = (try? values.decode(CloudflareAnalyticsPresentation.self, forKey: .presentation)) ?? .worldMap
        domainLetterCase = (try? values.decode(CloudflareDomainLetterCase.self, forKey: .domainLetterCase)) ?? .original
        displayLanguage = (try? values.decode(CloudflareDisplayLanguage.self, forKey: .displayLanguage)) ?? .chinese
        if let raw = try values.decodeIfPresent(Int.self, forKey: .accentTone), let tone = AccentTone(rawValue: raw) {
            accentTone = tone
        } else {
            accentTone = .orange
        }
        customAccentHex = try values.decodeIfPresent(String.self, forKey: .customAccentHex)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(credentialID, forKey: .credentialID)
        try values.encode(zoneID, forKey: .zoneID)
        try values.encode(zoneName, forKey: .zoneName)
        try values.encode(hostname, forKey: .hostname)
        try values.encode(period, forKey: .period)
        try values.encode(refreshMinutes, forKey: .refreshMinutes)
        try values.encode(rankByTraffic, forKey: .rankByTraffic)
        try values.encode(presentation, forKey: .presentation)
        try values.encode(domainLetterCase, forKey: .domainLetterCase)
        try values.encode(displayLanguage, forKey: .displayLanguage)
        try values.encode(accentTone.rawValue, forKey: .accentTone)
        try values.encodeIfPresent(customAccentHex, forKey: .customAccentHex)
    }
    public var isValid: Bool {
        zoneID.count == 32 && zoneID.allSatisfy { $0.isASCII && $0.isHexDigit }
        && (hostname.isEmpty || (hostname.count <= 253 && !hostname.contains("..")
            && hostname.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }))
    }
    /// Presentation edits retain in-flight readings and don't restart the refresh schedule.
    public func hasSameQuery(as other: Self) -> Bool {
        credentialID == other.credentialID && zoneID == other.zoneID
            && hostname == other.hostname && period == other.period
    }

    /// Resolved emphasize color for keyboard / device cards. Brand orange when tone is `.system` and theme has no override.
    public func resolvedAccentCG(themeAccent: CGColor? = nil) -> CGColor {
        if let rgb = AppearanceResolver.accentRGB(tone: accentTone, customHex: customAccentHex) {
            return CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
        if let themeAccent { return themeAccent }
        return CGColor(red: 1, green: 97.0 / 255, blue: 1.0 / 255, alpha: 1)
    }
}

public struct CloudflareAnalyticsSnapshot: Codable, Equatable {
    public struct Region: Codable, Equatable, Identifiable {
        public let code: String
        public let requests: Double
        public let bytes: Double
        public var id: String { code }
        public var name: String { Locale(identifier: "zh_CN").localizedString(forRegionCode: code) ?? code }
    }
    public struct Point: Codable, Equatable { public let time: String; public let requests: Double; public let bytes: Double }
    public let zoneID: String
    public let hostname: String
    public let period: CloudflareAnalyticsPeriod
    public let start: Date
    public let end: Date
    public let sampledAt: Date
    public let requests: Double
    public let bytes: Double
    public let regions: [Region]
    public let trend: [Point]
    public func matches(_ settings: CloudflareAnalyticsSettings) -> Bool {
        zoneID == settings.zoneID && hostname == settings.hostname && period == settings.period
    }
    public func rankedRegions(byTraffic: Bool) -> [Region] {
        regions.sorted { a, b in
            let av = byTraffic ? a.bytes : a.requests, bv = byTraffic ? b.bytes : b.requests
            return av == bv ? a.code < b.code : av > bv
        }
    }
    public static func countText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
    public static func bytesText(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .decimal)
    }
    public static func countText(_ value: Double, language: CloudflareDisplayLanguage) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)).locale(language.locale))
    }
    public static func bytesText(_ value: Double, language: CloudflareDisplayLanguage) -> String {
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var amount = value, index = 0
        while amount >= 1000 && index < units.count - 1 { amount /= 1000; index += 1 }
        let digits = index == 0 ? 0 : 2
        let count = amount.formatted(.number.precision(.fractionLength(0...digits)).locale(language.locale))
        return count + " " + units[index]
    }
}

/// A named data source keeps its own configuration and last successful reading.
/// The credential identifier references a sealed local file; the Token itself is never persisted here.
public struct CloudflareAnalyticsSource: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var configuration: CloudflareAnalyticsSettings
    public var snapshot: CloudflareAnalyticsSnapshot?

    public init(id: UUID = UUID(), name: String, configuration: CloudflareAnalyticsSettings,
                snapshot: CloudflareAnalyticsSnapshot? = nil) {
        self.id = id
        self.name = Self.resolvedName(name, configuration: configuration)
        self.configuration = configuration
        self.snapshot = snapshot.flatMap { $0.matches(configuration) ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey { case id, name, configuration, snapshot }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let configuration = try values.decode(CloudflareAnalyticsSettings.self, forKey: .configuration)
        self.init(id: (try? values.decode(UUID.self, forKey: .id)) ?? UUID(),
                  name: (try? values.decode(String.self, forKey: .name)) ?? "",
                  configuration: configuration,
                  snapshot: try values.decodeIfPresent(CloudflareAnalyticsSnapshot.self, forKey: .snapshot))
    }

    private static func resolvedName(_ name: String, configuration: CloudflareAnalyticsSettings) -> String {
        for candidate in [name, configuration.zoneName, configuration.hostname] {
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return "Cloudflare 网站统计"
    }
}

public struct CloudflareAnalyticsZone: Decodable, Equatable, Identifiable {
    public let id: String
    public let name: String
}

public enum CloudflareAnalyticsError: LocalizedError {
    case invalidConfiguration, missingToken, authentication, rateLimited, deniedDataset, malformed, transport
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "请填写 32 位 Zone ID；域名筛选只填写主机名。"
        case .missingToken: return "请保存具有 Analytics 只读权限的 Cloudflare API Token。"
        case .authentication: return "Cloudflare 拒绝访问，请检查 Token、有效期和授权站点。"
        case .rateLimited: return "Cloudflare 请求过于频繁；已保留上次数据，稍后重试。"
        case .deniedDataset: return "Cloudflare 未返回此统计范围，请检查 Analytics 权限或缩短时间范围；数据集受套餐限制。"
        case .malformed: return "Cloudflare 统计响应不完整，已保留上次数据。"
        case .transport: return "无法连接 Cloudflare，已保留上次数据。"
        }
    }
}

/// Sealed local files shared by website configuration, never copied into document exports.
/// 网站凭据仅在本机 Application Support 加密保存，不写进原稿与设置文件；不使用系统钥匙串。
public enum CloudflareAnalyticsSecretStore {
    private static let subdirectory = "cloudflare-analytics-credentials"
    public static func read(id: UUID) -> String {
        SealedCredentialStore.read(account: id.uuidString, subdirectory: subdirectory)
    }
    @discardableResult public static func save(_ token: String, id: UUID) -> Bool {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || value.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else { return false }
        return SealedCredentialStore.save(value, account: id.uuidString, subdirectory: subdirectory)
    }
}

public enum CloudflareAnalyticsClient {
    public typealias Transport = (URLRequest) async throws -> (Data, Int)
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private static let redirectGuard = NoRedirect()
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25; c.timeoutIntervalForResource = 35
        c.httpShouldSetCookies = false; c.urlCache = nil
        return URLSession(configuration: c, delegate: redirectGuard, delegateQueue: nil)
    }()
    private static func network(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw CloudflareAnalyticsError.transport }
            return (data, response.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch { throw CloudflareAnalyticsError.transport }
    }
    private static func request(path: String, token: String) throws -> URLRequest {
        guard !token.isEmpty, token.count < 4096,
              token.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else { throw CloudflareAnalyticsError.missingToken }
        var r = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/" + path)!)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }
    private static func check(_ status: Int, data: Data) throws {
        if status == 401 || status == 403 { throw CloudflareAnalyticsError.authentication }
        if status == 429 { throw CloudflareAnalyticsError.rateLimited }
        guard (200..<300).contains(status), data.count <= 8 * 1024 * 1024 else { throw CloudflareAnalyticsError.transport }
    }
    public static func zones(token: String, transport: Transport? = nil) async throws -> [CloudflareAnalyticsZone] {
        struct Envelope: Decodable {
            struct Info: Decodable { let total_pages: Int }
            let success: Bool; let result: [CloudflareAnalyticsZone]; let result_info: Info
        }
        var result: [CloudflareAnalyticsZone] = []
        for page in 1...100 {
            let r = try request(path: "zones?per_page=50&page=\(page)", token: token)
            let (data, status) = try await (transport ?? network)(r)
            try check(status, data: data)
            guard let e = try? JSONDecoder().decode(Envelope.self, from: data), e.success,
                  e.result_info.total_pages <= 100 else { throw CloudflareAnalyticsError.malformed }
            result += e.result
            if page >= e.result_info.total_pages { return result.sorted { $0.name < $1.name } }
        }
        throw CloudflareAnalyticsError.malformed
    }
    public static func fetch(_ settings: CloudflareAnalyticsSettings, token: String, now: Date = Date(),
                             transport: Transport? = nil) async throws -> CloudflareAnalyticsSnapshot {
        guard settings.isValid else { throw CloudflareAnalyticsError.invalidConfiguration }
        let start = now.addingTimeInterval(-settings.period.seconds)
        let bucket = settings.period == .month ? "date" : "datetimeHour"
        // Adaptive Analytics exposes request count and edge response bytes, not unique people.
        // 自适应统计提供请求数与边缘响应字节，不把请求数冒充访问人数。
        let query = "query Traffic($zone: string, $filter: ZoneHttpRequestsAdaptiveGroupsFilter_InputObject) { viewer { zones(filter: {zoneTag: $zone}) { totals: httpRequestsAdaptiveGroups(limit: 1, filter: $filter) { count sum { edgeResponseBytes } } trend: httpRequestsAdaptiveGroups(limit: 750, filter: $filter, orderBy: [\(bucket)_ASC]) { count sum { edgeResponseBytes } dimensions { \(bucket) } } regions: httpRequestsAdaptiveGroups(limit: 250, filter: $filter, orderBy: [sum_edgeResponseBytes_DESC]) { count sum { edgeResponseBytes } dimensions { clientCountryName } } } } }"
        let formatter = ISO8601DateFormatter()
        var filter: [String: Any] = ["datetime_geq": formatter.string(from: start), "datetime_lt": formatter.string(from: now), "requestSource": "eyeball"]
        if !settings.hostname.isEmpty { filter["clientRequestHTTPHost"] = settings.hostname }
        var r = try request(path: "graphql", token: token)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": ["zone": settings.zoneID, "filter": filter]])
        let (data, status) = try await (transport ?? network)(r)
        try check(status, data: data)
        return try decode(data, settings: settings, start: start, end: now, bucket: bucket)
    }
    private static func decode(_ data: Data, settings: CloudflareAnalyticsSettings, start: Date, end: Date,
                                bucket: String) throws -> CloudflareAnalyticsSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudflareAnalyticsError.malformed }
        if let errors = root["errors"] as? [Any], !errors.isEmpty { throw CloudflareAnalyticsError.deniedDataset }
        guard let content = root["data"] as? [String: Any], let viewer = content["viewer"] as? [String: Any],
              let zones = viewer["zones"] as? [[String: Any]], zones.count == 1,
              let totals = zones[0]["totals"] as? [[String: Any]], totals.count <= 1,
              let regions = zones[0]["regions"] as? [[String: Any]], regions.count <= 250,
              let trend = zones[0]["trend"] as? [[String: Any]], trend.count < 750 else { throw CloudflareAnalyticsError.malformed }
        func value(_ row: [String: Any]) throws -> (Double, Double) {
            guard let count = row["count"] as? NSNumber,
                  let sum = row["sum"] as? [String: Any], let bytes = sum["edgeResponseBytes"] as? NSNumber,
                  CFGetTypeID(count) != CFBooleanGetTypeID(), CFGetTypeID(bytes) != CFBooleanGetTypeID(),
                  count.doubleValue.isFinite, bytes.doubleValue.isFinite,
                  count.doubleValue >= 0, bytes.doubleValue >= 0 else { throw CloudflareAnalyticsError.malformed }
            return (count.doubleValue, bytes.doubleValue)
        }
        let total = try totals.first.map(value) ?? (0, 0)
        if totals.isEmpty && (!regions.isEmpty || !trend.isEmpty) { throw CloudflareAnalyticsError.malformed }
        var countries: [String: (Double, Double)] = [:]
        for row in regions {
            let v = try value(row)
            guard let d = row["dimensions"] as? [String: Any], let code = d["clientCountryName"] as? String,
                  !code.isEmpty, code.count <= 32 else { throw CloudflareAnalyticsError.malformed }
            let previous = countries[code] ?? (0, 0)
            countries[code] = (previous.0 + v.0, previous.1 + v.1)
        }
        var points: [CloudflareAnalyticsSnapshot.Point] = []
        for row in trend {
            let v = try value(row)
            guard let d = row["dimensions"] as? [String: Any], let time = d[bucket] as? String,
                  !time.isEmpty, time.count <= 32 else { throw CloudflareAnalyticsError.malformed }
            points.append(.init(time: time, requests: v.0, bytes: v.1))
        }
        return CloudflareAnalyticsSnapshot(zoneID: settings.zoneID, hostname: settings.hostname, period: settings.period,
            start: start, end: end, sampledAt: end, requests: total.0, bytes: total.1,
            regions: countries.map { .init(code: $0.key, requests: $0.value.0, bytes: $0.value.1) },
            trend: points.sorted { $0.time < $1.time })
    }
}
