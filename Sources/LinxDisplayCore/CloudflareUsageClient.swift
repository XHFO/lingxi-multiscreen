import Foundation

/// Cloudflare Analytics 今日（UTC）观测值。不是套餐剩余，缺失字段保持空而不是 0。
public struct CloudflareUsageSnapshot: Equatable {
    public enum State: String, Equatable {
        case live
        case notConfigured
        case unauthorized
        case noPermission
        case unreachable
        case unreadable
    }

    public enum Field: String, Equatable, CaseIterable {
        case requests
        case bytes
        case cached
        case threats
        case workers
    }

    public var state: State
    public var requests: Double?
    public var bytes: Double?
    public var cachedRequests: Double?
    public var threats: Double?
    public var workersRequests: Double?
    public var zoneCount: Int?
    public var accountName: String?
    public var deniedFields: Set<Field>
    public var sampledAt: Date?
    public var message: String

    public init(state: State, requests: Double? = nil, bytes: Double? = nil,
                cachedRequests: Double? = nil, threats: Double? = nil,
                workersRequests: Double? = nil, zoneCount: Int? = nil,
                accountName: String? = nil, deniedFields: Set<Field> = [],
                sampledAt: Date? = nil, message: String) {
        self.state = state
        self.requests = requests
        self.bytes = bytes
        self.cachedRequests = cachedRequests
        self.threats = threats
        self.workersRequests = workersRequests
        self.zoneCount = zoneCount
        self.accountName = accountName
        self.deniedFields = deniedFields
        self.sampledAt = sampledAt
        self.message = message
    }

    public var showsMetrics: Bool { state == .live || state == .noPermission }

    public var statusFailure: String? {
        switch state {
        case .unauthorized: return "API 令牌无效或已失效"
        case .unreachable: return "暂时无法连接 Cloudflare"
        case .unreadable: return "Cloudflare 返回的数据无法读取"
        case .live, .notConfigured, .noPermission: return nil
        }
    }

    public static let notConfigured = CloudflareUsageSnapshot(
        state: .notConfigured,
        message: "尚未配置。请在设置中填写 Cloudflare API 令牌。")

    public static let windowLabel = "今日（UTC）"

    public func text(for field: Field) -> String {
        if deniedFields.contains(field) { return "无权限" }
        switch field {
        case .requests:
            guard let requests else { return "—" }
            return CloudflareUsageClient.compactCount(requests)
        case .bytes:
            guard let bytes else { return "—" }
            return CloudflareUsageClient.formatBytes(bytes)
        case .cached:
            guard let cachedRequests else { return "—" }
            if let requests, requests > 0 {
                let percent = Int((min(max(cachedRequests / requests, 0), 9.99) * 100).rounded())
                return "\(percent)%"
            }
            return CloudflareUsageClient.compactCount(cachedRequests)
        case .threats:
            guard let threats else { return "—" }
            return CloudflareUsageClient.compactCount(threats)
        case .workers:
            guard let workersRequests else { return "—" }
            return CloudflareUsageClient.compactCount(workersRequests)
        }
    }

    public var heroText: String { text(for: .requests) }

    public var metricRows: [(String, String)] {
        [
            ("带宽", text(for: .bytes)),
            ("缓存命中", text(for: .cached)),
            ("威胁", text(for: .threats)),
            ("Workers", text(for: .workers))
        ]
    }
}

public final class CloudflareUsageClient {
    private let session: URLSession

    public init(session: URLSession = EphemeralJSONSession.make()) {
        self.session = session
    }

    public func fetch(apiToken: String, accountID: String?, now: Date = Date()) async -> CloudflareUsageSnapshot {
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .notConfigured }
        let override = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountFilter = (override?.isEmpty == false) ? override : nil

        guard let accountsURL = URL(string: "https://api.cloudflare.com/client/v4/accounts?per_page=50") else {
            return unreachable(now)
        }
        let accounts = await get(accountsURL, token: token)
        if let failed = Self.transportFailure(status: accounts.status, now: now) { return failed }
        guard let accountsObject = accounts.object, accountsObject["success"] as? Bool != false,
              let accountRows = accountsObject["result"] as? [[String: Any]] else {
            return unreadable(now)
        }
        let account = Self.pickAccount(accountRows, override: accountFilter)
        guard let accountTag = account.id else {
            return CloudflareUsageSnapshot(
                state: .unreadable, sampledAt: now,
                message: accountFilter == nil ? "这个令牌看不到任何账号。" : "找不到填写的账号 ID。")
        }

        var zoneCount: Int?
        var zoneTags: [String] = []
        if let zonesURL = URL(string: "https://api.cloudflare.com/client/v4/zones?per_page=50&account.id=\(accountTag)") {
            let zones = await get(zonesURL, token: token)
            if zones.status == 401 || zones.status == 403 {
                return CloudflareUsageSnapshot(
                    state: .noPermission, zoneCount: nil, accountName: account.name,
                    deniedFields: Set(CloudflareUsageSnapshot.Field.allCases),
                    sampledAt: now, message: "令牌没有读取站点或分析数据的权限。")
            }
            if let rows = zones.object?["result"] as? [[String: Any]] {
                zoneTags = rows.compactMap { $0["id"] as? String }
                if let info = zones.object?["result_info"] as? [String: Any],
                   let total = quotaJSONInt(info, ["total_count"]) {
                    zoneCount = total
                } else {
                    zoneCount = rows.count
                }
            }
        }

        let analytics = await graphql(accountTag: accountTag, zoneTags: zoneTags, token: token, now: now)
        if let failed = Self.transportFailure(status: analytics.status, now: now, accountName: account.name) {
            return failed
        }
        guard let body = analytics.object else { return unreadable(now, accountName: account.name) }
        return Self.parseAnalytics(body: body, zoneCount: zoneCount, accountName: account.name, now: now)
    }

    public static func parseAnalytics(body: [String: Any], zoneCount: Int?, accountName: String?,
                                      now: Date = Date()) -> CloudflareUsageSnapshot {
        let errors = body["errors"] as? [[String: Any]] ?? []
        let viewer = ((body["data"] as? [String: Any])?["viewer"] as? [String: Any]) ?? [:]
        let accounts = viewer["accounts"] as? [[String: Any]] ?? []
        let zones = viewer["zones"] as? [[String: Any]] ?? []
        let workerGroups = accounts.flatMap { $0["workersInvocationsAdaptive"] as? [[String: Any]] ?? [] }
        let httpGroups = zones.flatMap { $0["httpRequests1dGroups"] as? [[String: Any]] ?? [] }
        var denied = Set<CloudflareUsageSnapshot.Field>()
        let errorText = errors.compactMap { $0["message"] as? String }.joined(separator: " ").lowercased()
        let permissionDenied = errorText.contains("permission") || errorText.contains("auth")
            || errorText.contains("not authorized") || errorText.contains("unauthorized")
        if permissionDenied && workerGroups.isEmpty {
            denied.insert(.workers)
        }
        if permissionDenied && httpGroups.isEmpty {
            denied.formUnion([.requests, .bytes, .cached, .threats])
        }
        let requests = sum(httpGroups, "requests")
        let bytes = sum(httpGroups, "bytes")
        let cached = sum(httpGroups, "cachedRequests")
        let threats = sum(httpGroups, "threats")
        let workers = sum(workerGroups, "requests")
        let hasAnyNumber = [requests, bytes, cached, threats, workers].contains { $0 != nil }
        if !hasAnyNumber && !errors.isEmpty && denied.isEmpty {
            return CloudflareUsageSnapshot(
                state: .unreadable, zoneCount: zoneCount, accountName: accountName,
                sampledAt: now, message: "Cloudflare 返回的数据无法读取。")
        }
        let state: CloudflareUsageSnapshot.State = denied.isEmpty ? .live : .noPermission
        let message = denied.isEmpty ? "" : "部分字段没有读取权限。"
        return CloudflareUsageSnapshot(
            state: state, requests: requests, bytes: bytes, cachedRequests: cached,
            threats: threats, workersRequests: workers, zoneCount: zoneCount,
            accountName: accountName, deniedFields: denied, sampledAt: now, message: message)
    }

    public static func compactCount(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)
        if magnitude >= 100_000_000 { return sign + trimmed(magnitude / 100_000_000) + "亿" }
        if magnitude >= 10_000 { return sign + trimmed(magnitude / 10_000) + "万" }
        if magnitude >= 100 || magnitude == magnitude.rounded() {
            return sign + String(format: "%.0f", magnitude.rounded())
        }
        return sign + String(format: "%.1f", magnitude)
    }

    public static func formatBytes(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = abs(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let number = index == 0 || value >= 10
            ? String(format: "%.0f", value.rounded())
            : trimmed(value)
        return (bytes < 0 ? "-" : "") + number + " " + units[index]
    }

    private static func trimmed(_ value: Double) -> String {
        if abs(value - value.rounded()) < 0.05 { return String(format: "%.0f", value.rounded()) }
        return String(format: "%.1f", value)
    }

    private static func sum(_ groups: [[String: Any]], _ key: String) -> Double? {
        var total = 0.0
        var seen = false
        for group in groups {
            guard let sum = group["sum"] as? [String: Any], let value = quotaJSONDouble(sum, [key]) else { continue }
            total += value
            seen = true
        }
        return seen ? total : nil
    }

    private struct AccountPick {
        var id: String?
        var name: String?
    }

    private static func pickAccount(_ rows: [[String: Any]], override: String?) -> AccountPick {
        if let override {
            let match = rows.first { ($0["id"] as? String) == override }
            return AccountPick(id: override, name: match?["name"] as? String)
        }
        guard let first = rows.first, let id = first["id"] as? String else {
            return AccountPick(id: nil, name: nil)
        }
        return AccountPick(id: id, name: first["name"] as? String)
    }

    private struct HTTPResult {
        var status: Int
        var object: [String: Any]?
    }

    private func get(_ url: URL, token: String) async -> HTTPResult {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return HTTPResult(status: status, object: object)
        } catch {
            return HTTPResult(status: -1, object: nil)
        }
    }

    private func graphql(accountTag: String, zoneTags: [String], token: String, now: Date) async -> HTTPResult {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        stamp.timeZone = calendar.timeZone
        let query = """
        query LingxiCloudflare($accountTag: String!, $zoneTags: [String!], $start: Time!, $end: Time!, $dateGeq: Date!, $dateLt: Date!, $includeZones: Boolean!) {
          viewer {
            accounts(filter: {accountTag: $accountTag}) {
              workersInvocationsAdaptive(limit: 9999, filter: {datetime_geq: $start, datetime_leq: $end}) {
                sum { requests }
              }
            }
            zones(filter: {zoneTag_in: $zoneTags}) @include(if: $includeZones) {
              httpRequests1dGroups(limit: 9999, filter: {date_geq: $dateGeq, date_lt: $dateLt}) {
                sum { requests bytes cachedRequests threats }
              }
            }
          }
        }
        """
        let variables: [String: Any] = [
            "accountTag": accountTag,
            "zoneTags": zoneTags,
            "start": stamp.string(from: start),
            "end": stamp.string(from: end.addingTimeInterval(-1)),
            "dateGeq": dayFormatter.string(from: start),
            "dateLt": dayFormatter.string(from: end),
            "includeZones": !zoneTags.isEmpty
        ]
        guard let url = URL(string: "https://api.cloudflare.com/client/v4/graphql"),
              let body = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables]) else {
            return HTTPResult(status: -1, object: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return HTTPResult(status: status, object: object)
        } catch {
            return HTTPResult(status: -1, object: nil)
        }
    }

    private static func transportFailure(status: Int, now: Date, accountName: String? = nil) -> CloudflareUsageSnapshot? {
        if status == 401 || status == 403 {
            return CloudflareUsageSnapshot(
                state: .unauthorized, accountName: accountName, sampledAt: now,
                message: "API 令牌无效或已失效。")
        }
        if status == -1 || !(200...299).contains(status) {
            return CloudflareUsageSnapshot(
                state: .unreachable, accountName: accountName, sampledAt: now,
                message: "暂时无法连接 Cloudflare。")
        }
        return nil
    }

    private func unreachable(_ now: Date) -> CloudflareUsageSnapshot {
        CloudflareUsageSnapshot(state: .unreachable, sampledAt: now, message: "暂时无法连接 Cloudflare。")
    }

    private func unreadable(_ now: Date, accountName: String? = nil) -> CloudflareUsageSnapshot {
        CloudflareUsageSnapshot(
            state: .unreadable, accountName: accountName, sampledAt: now,
            message: "Cloudflare 返回的数据无法读取。")
    }
}
