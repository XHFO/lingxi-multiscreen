import CoreFoundation
import Foundation

/// DeepSeek 官方用量快照。
///
/// 余额来自官方公开接口 `GET https://api.deepseek.com/user/balance`；
/// 今日 / 本月 Token 与花费来自 DeepSeek 平台网页使用的用量接口（需要平台会话令牌）。
/// 没有平台令牌时只显示官方余额，不会用估算值填充 Token 数字。
public struct DeepSeekUsageSnapshot: Equatable {
    public enum State: String, Equatable {
        /// 余额与平台用量都已读取。
        case live
        /// 只读取到官方余额；未配置平台令牌或平台用量暂时不可用。
        case balanceOnly
        case notConfigured
        case unauthorized
        case unreachable
        case unreadable
    }

    public var state: State
    public var currency: String
    public var totalBalance: Double
    public var grantedBalance: Double
    public var toppedUpBalance: Double
    /// 官方余额接口的 `is_available`：余额是否足以继续调用 API。
    public var apiAvailable: Bool
    public var todayTokens: Int?
    public var monthTokens: Int?
    public var todayCost: Double?
    public var monthCost: Double?
    public var todayRequests: Int?
    public var monthRequests: Int?
    public var topModel: String?
    public var sampledAt: Date?
    public var message: String

    public init(state: State,
                currency: String = "CNY",
                totalBalance: Double = 0,
                grantedBalance: Double = 0,
                toppedUpBalance: Double = 0,
                apiAvailable: Bool = false,
                todayTokens: Int? = nil,
                monthTokens: Int? = nil,
                todayCost: Double? = nil,
                monthCost: Double? = nil,
                todayRequests: Int? = nil,
                monthRequests: Int? = nil,
                topModel: String? = nil,
                sampledAt: Date? = nil,
                message: String = "") {
        self.state = state
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
        self.apiAvailable = apiAvailable
        self.todayTokens = todayTokens
        self.monthTokens = monthTokens
        self.todayCost = todayCost
        self.monthCost = monthCost
        self.todayRequests = todayRequests
        self.monthRequests = monthRequests
        self.topModel = topModel
        self.sampledAt = sampledAt
        self.message = message
    }

    /// 是否读取到官方余额。未配置、鉴权失败与网络错误都保持 false。
    public var hasBalance: Bool { state == .live || state == .balanceOnly }

    /// 是否读取到平台 Token / 花费明细。
    public var hasUsageDetails: Bool {
        state == .live && (todayTokens != nil || monthTokens != nil || monthCost != nil)
    }

    /// 卡片是否可显示真实数据（等价于读取到余额）。
    public var isAvailable: Bool { hasBalance }

    /// 需要出现在状态栏的失败；未配置与“仅余额”不反复打扰。
    public var statusFailure: String? {
        switch state {
        case .unauthorized: return "API Key 无效或无权读取余额"
        case .unreachable: return "暂时无法连接 DeepSeek 官方接口"
        case .unreadable: return message.isEmpty ? "DeepSeek 返回了无法识别的数据" : message
        case .live, .balanceOnly, .notConfigured: return nil
        }
    }

    public var currencySymbol: String {
        currency.uppercased() == "USD" ? "$" : "¥"
    }

    public func moneyText(_ value: Double, decimals: Int = 2) -> String {
        let clamped = max(0, value)
        return currencySymbol + String(format: "%.\(decimals)f", clamped)
    }

    public var balanceText: String { moneyText(totalBalance) }
    public var todayCostText: String { todayCost.map { moneyText($0, decimals: 4) } ?? "—" }
    public var monthCostText: String { monthCost.map { moneyText($0, decimals: 2) } ?? "—" }
    public var todayTokensText: String { todayTokens.map(Self.compactTokens) ?? "—" }
    public var monthTokensText: String { monthTokens.map(Self.compactTokens) ?? "—" }

    public static func compactTokens(_ count: Int) -> String {
        let value = Double(max(0, count))
        if value >= 1_000_000 {
            return String(format: value >= 10_000_000 ? "%.0fM" : "%.1fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: value >= 100_000 ? "%.0fK" : "%.1fK", value / 1_000)
        }
        return "\(max(0, count))"
    }

    public static let notConfigured = DeepSeekUsageSnapshot(
        state: .notConfigured,
        message: "尚未配置。请在「DeepSeek 用量」面板填写官方 API Key。")

    public static func failure(_ state: State, _ message: String, now: Date) -> DeepSeekUsageSnapshot {
        DeepSeekUsageSnapshot(state: state, sampledAt: now, message: message)
    }
}

/// 平台接口返回的今日 / 本月用量。
public struct DeepSeekUsageDetails: Equatable {
    public var todayTokens: Int?
    public var monthTokens: Int?
    public var todayCost: Double?
    public var monthCost: Double?
    public var todayRequests: Int?
    public var monthRequests: Int?
    public var topModel: String?

    public init(todayTokens: Int?, monthTokens: Int?, todayCost: Double?, monthCost: Double?,
                todayRequests: Int?, monthRequests: Int?, topModel: String?) {
        self.todayTokens = todayTokens
        self.monthTokens = monthTokens
        self.todayCost = todayCost
        self.monthCost = monthCost
        self.todayRequests = todayRequests
        self.monthRequests = monthRequests
        self.topModel = topModel
    }
}

public enum DeepSeekUsageError: Error, Equatable, LocalizedError {
    case unauthorized
    case api(String)
    case parse(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "DeepSeek 凭据无效或已过期。"
        case .api(let message): return message
        case .parse(let message): return "DeepSeek 返回了无法识别的数据：\(message)"
        case .network(let message): return message
        }
    }
}

/// 解析 DeepSeek 官方接口响应；单独暴露便于离线测试。
public enum DeepSeekUsageParser {
    public static func balanceSnapshot(from data: Data, now: Date = Date()) throws -> DeepSeekUsageSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DeepSeekUsageError.parse("余额响应不是 JSON 对象")
        }
        let apiAvailable = (root["is_available"] as? Bool) ?? true
        guard let infos = root["balance_infos"] as? [[String: Any]] else {
            throw DeepSeekUsageError.parse("缺少 balance_infos")
        }
        let parsed = infos.compactMap { info -> (currency: String, total: Double, granted: Double, toppedUp: Double)? in
            guard let currency = info["currency"] as? String, !currency.isEmpty else { return nil }
            let total = number(info["total_balance"])
            let granted = number(info["granted_balance"]) ?? 0
            let toppedUp = number(info["topped_up_balance"]) ?? 0
            guard let total else { return nil }
            return (currency.uppercased(), total, granted, toppedUp)
        }
        guard !parsed.isEmpty else {
            throw DeepSeekUsageError.parse("余额列表为空或数字格式不受支持")
        }
        // 优先显示有余额的 USD，其次任一有余额币种；都为零时优先 USD，最后取第一项。
        let selected = parsed.first { $0.currency == "USD" && $0.total > 0 }
            ?? parsed.first { $0.total > 0 }
            ?? parsed.first { $0.currency == "USD" }
            ?? parsed[0]
        var snapshot = DeepSeekUsageSnapshot(
            state: .balanceOnly,
            currency: selected.currency,
            totalBalance: selected.total,
            grantedBalance: selected.granted,
            toppedUpBalance: selected.toppedUp,
            apiAvailable: apiAvailable,
            sampledAt: now)
        if !apiAvailable {
            snapshot.message = selected.total > 0
                ? "账户余额不可用于 API 调用，请检查账户状态。"
                : "账户余额不足，暂时无法调用 API。"
        }
        return snapshot
    }

    /// 合并平台月度 amount / cost 响应。日期按本地日（yyyy-MM-dd）匹配“今天”。
    public static func usageDetails(amountData: Data, costData: Data,
                                    now: Date = Date(),
                                    calendar: Calendar = .current) throws -> DeepSeekUsageDetails {
        let amountRoot = try jsonObject(amountData, label: "amount")
        let costRoot = try jsonObject(costData, label: "cost")
        try validateEnvelope(amountRoot, label: "amount")
        try validateEnvelope(costRoot, label: "cost")

        let amountBiz = try bizDictionaries(amountRoot, label: "amount")
        let costBiz = try bizDictionaries(costRoot, label: "cost")
        let amountTotal = amountBiz.first?["total"] as? [[String: Any]] ?? []
        let amountDays = amountBiz.first?["days"] as? [[String: Any]] ?? []
        let costTotal = costBiz.first?["total"] as? [[String: Any]] ?? []
        let costDays = costBiz.first?["days"] as? [[String: Any]] ?? []

        var days: [String: (tokens: Int, cost: Double, requests: Int)] = [:]
        for day in amountDays {
            guard let key = normalizedDayKey(day["date"]), let models = day["data"] as? [[String: Any]] else { continue }
            var totals = days[key] ?? (0, 0, 0)
            for model in models {
                for item in model["usage"] as? [[String: Any]] ?? [] {
                    let type = (item["type"] as? String ?? "").uppercased()
                    let value = Int(number(item["amount"]) ?? 0)
                    if type == "REQUEST" {
                        totals.requests += max(0, value)
                    } else if isTokenType(type) {
                        totals.tokens += max(0, value)
                    }
                }
            }
            days[key] = totals
        }
        for day in costDays {
            guard let key = normalizedDayKey(day["date"]), let models = day["data"] as? [[String: Any]] else { continue }
            var totals = days[key] ?? (0, 0, 0)
            for model in models {
                for item in model["usage"] as? [[String: Any]] ?? [] {
                    let type = (item["type"] as? String ?? "").uppercased()
                    guard isTokenType(type) else { continue }
                    totals.cost += max(0, number(item["amount"]) ?? 0)
                }
            }
            days[key] = totals
        }

        if days.isEmpty {
            // 个别账号的响应只有 total、没有 days；此时只能给出本月口径。
            let (tokens, requests) = totalAmounts(amountTotal)
            let cost = totalCosts(costTotal)
            return DeepSeekUsageDetails(
                todayTokens: nil,
                monthTokens: tokens,
                todayCost: nil,
                monthCost: cost,
                todayRequests: nil,
                monthRequests: requests,
                topModel: topModel(amountTotal))
        }

        let todayKey = dayKey(now, calendar: calendar)
        let monthPrefix = String(todayKey.prefix(7))
        var monthTokens = 0
        var monthCost = 0.0
        var monthRequests = 0
        for (key, totals) in days where key.hasPrefix(monthPrefix) {
            monthTokens += totals.tokens
            monthCost += totals.cost
            monthRequests += totals.requests
        }
        let today = days[todayKey]
        return DeepSeekUsageDetails(
            todayTokens: today?.tokens,
            monthTokens: monthTokens,
            todayCost: today?.cost,
            monthCost: monthCost,
            todayRequests: today?.requests,
            monthRequests: monthRequests,
            topModel: topModel(amountTotal))
    }

    // MARK: - JSON 容错

    private static func jsonObject(_ data: Data, label: String) throws -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DeepSeekUsageError.parse("\(label) 响应不是 JSON 对象")
        }
        return root
    }

    private static func validateEnvelope(_ root: [String: Any], label: String) throws {
        if let code = number(root["code"]), code != 0 {
            if code == 40_002 || code == 40_003 { throw DeepSeekUsageError.unauthorized }
            throw DeepSeekUsageError.api("\(label) 接口返回错误码 \(Int(code))")
        }
        if let data = root["data"] as? [String: Any],
           let bizCode = number(data["biz_code"]), bizCode != 0 {
            if bizCode == 40_002 || bizCode == 40_003 { throw DeepSeekUsageError.unauthorized }
            throw DeepSeekUsageError.api("\(label) 接口返回错误码 \(Int(bizCode))")
        }
    }

    /// amount 的 biz_data 是对象，cost 是数组；统一成可读的字典数组。
    private static func bizDictionaries(_ root: [String: Any], label: String) throws -> [[String: Any]] {
        guard let data = root["data"] as? [String: Any] else {
            throw DeepSeekUsageError.parse("\(label) 缺少 data")
        }
        if let list = data["biz_data"] as? [[String: Any]] { return list }
        if let single = data["biz_data"] as? [String: Any] { return [single] }
        throw DeepSeekUsageError.parse("\(label) 缺少 biz_data")
    }

    private static func isTokenType(_ type: String) -> Bool {
        type == "PROMPT_CACHE_HIT_TOKEN" || type == "PROMPT_CACHE_MISS_TOKEN" || type == "RESPONSE_TOKEN"
    }

    private static func totalAmounts(_ models: [[String: Any]]) -> (tokens: Int, requests: Int) {
        var tokens = 0
        var requests = 0
        for model in models {
            for item in model["usage"] as? [[String: Any]] ?? [] {
                let type = (item["type"] as? String ?? "").uppercased()
                let value = Int(number(item["amount"]) ?? 0)
                if type == "REQUEST" {
                    requests += max(0, value)
                } else if isTokenType(type) {
                    tokens += max(0, value)
                }
            }
        }
        return (tokens, requests)
    }

    private static func totalCosts(_ models: [[String: Any]]) -> Double {
        var cost = 0.0
        for model in models {
            for item in model["usage"] as? [[String: Any]] ?? [] {
                let type = (item["type"] as? String ?? "").uppercased()
                guard isTokenType(type) else { continue }
                cost += max(0, number(item["amount"]) ?? 0)
            }
        }
        return cost
    }

    private static func topModel(_ models: [[String: Any]]) -> String? {
        var totals: [String: Int] = [:]
        for model in models {
            guard let name = model["model"] as? String, !name.isEmpty else { continue }
            var tokens = 0
            for item in model["usage"] as? [[String: Any]] ?? [] {
                let type = (item["type"] as? String ?? "").uppercased()
                guard isTokenType(type) else { continue }
                tokens += max(0, Int(number(item["amount"]) ?? 0))
            }
            totals[name, default: 0] += tokens
        }
        return totals.max { left, right in
            left.value == right.value ? left.key > right.key : left.value < right.value
        }?.key
    }

    private static func topModel(days: [[String: Any]]) -> String? {
        var totals: [String: Int] = [:]
        for day in days {
            guard let models = day["data"] as? [[String: Any]] else { continue }
            for model in models {
                guard let name = model["model"] as? String, !name.isEmpty else { continue }
                var tokens = 0
                for item in model["usage"] as? [[String: Any]] ?? [] {
                    let type = (item["type"] as? String ?? "").uppercased()
                    guard isTokenType(type) else { continue }
                    tokens += max(0, Int(number(item["amount"]) ?? 0))
                }
                totals[name, default: 0] += tokens
            }
        }
        return totals.max { left, right in
            left.value == right.value ? left.key > right.key : left.value < right.value
        }?.key
    }

    public static func normalizedDayKey(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard normalized.count >= 10 else { return nil }
        let prefix = String(normalized.prefix(10))
        let parts = prefix.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              Int(parts[0]) != nil, Int(parts[1]) != nil, Int(parts[2]) != nil else { return nil }
        return prefix
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// 读取 DeepSeek 官方余额，并在提供平台会话令牌时补充今日 / 本月用量。
public final class DeepSeekUsageClient {
    public static let balanceEndpoint = URL(string: "https://api.deepseek.com/user/balance")!
    public static let usageAmountEndpoint = URL(string: "https://platform.deepseek.com/api/v0/usage/amount")!
    public static let usageCostEndpoint = URL(string: "https://platform.deepseek.com/api/v0/usage/cost")!

    private let session: URLSession

    public init(session: URLSession = EphemeralJSONSession.make()) {
        self.session = session
    }

    public func fetch(apiKey: String, platformToken: String = "",
                      now: Date = Date(), timeout: TimeInterval = 12) async -> DeepSeekUsageSnapshot {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .notConfigured }

        let balance: DeepSeekUsageSnapshot
        do {
            let data = try await request(Self.balanceEndpoint, token: key, timeout: timeout)
            balance = try DeepSeekUsageParser.balanceSnapshot(from: data, now: now)
        } catch let error as DeepSeekUsageError {
            switch error {
            case .unauthorized:
                return .failure(.unauthorized, "API Key 无效或已失效，请在官方平台重新创建。", now: now)
            case .parse(let message):
                return .failure(.unreadable, message, now: now)
            case .api(let message):
                return .failure(.unreadable, message, now: now)
            case .network(let message):
                return .failure(.unreachable, message, now: now)
            }
        } catch {
            return .failure(.unreachable, "暂时无法连接 DeepSeek 官方接口。", now: now)
        }

        let token = platformToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            var snapshot = balance
            snapshot.state = .balanceOnly
            snapshot.message = "填写平台会话令牌后可显示今日与本月 Token 用量。"
            return snapshot
        }

        var snapshot = balance
        do {
            let details = try await fetchDetails(platformToken: token, now: now, timeout: timeout)
            snapshot.state = .live
            snapshot.todayTokens = details.todayTokens
            snapshot.monthTokens = details.monthTokens
            snapshot.todayCost = details.todayCost
            snapshot.monthCost = details.monthCost
            snapshot.todayRequests = details.todayRequests
            snapshot.monthRequests = details.monthRequests
            snapshot.topModel = details.topModel
            snapshot.message = ""
        } catch let error as DeepSeekUsageError {
            snapshot.state = .balanceOnly
            if case .unauthorized = error {
                snapshot.message = "平台会话令牌无效或已过期，暂只显示账户余额。"
            } else {
                snapshot.message = "平台用量暂时不可用，仅显示账户余额。"
            }
        } catch {
            snapshot.state = .balanceOnly
            snapshot.message = "平台用量暂时不可用，仅显示账户余额。"
        }
        return snapshot
    }

    private func fetchDetails(platformToken: String, now: Date,
                              timeout: TimeInterval) async throws -> DeepSeekUsageDetails {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month], from: now)
        guard let year = components.year, let month = components.month else {
            throw DeepSeekUsageError.parse("无法确定当前月份")
        }
        var amountComponents = URLComponents(url: Self.usageAmountEndpoint, resolvingAgainstBaseURL: false)
        amountComponents?.queryItems = [
            URLQueryItem(name: "month", value: String(month)),
            URLQueryItem(name: "year", value: String(year))
        ]
        var costComponents = URLComponents(url: Self.usageCostEndpoint, resolvingAgainstBaseURL: false)
        costComponents?.queryItems = [
            URLQueryItem(name: "month", value: String(month)),
            URLQueryItem(name: "year", value: String(year))
        ]
        guard let amountURL = amountComponents?.url, let costURL = costComponents?.url else {
            throw DeepSeekUsageError.parse("无法构造用量请求地址")
        }
        async let amountData = request(amountURL, token: platformToken, timeout: timeout)
        async let costData = request(costURL, token: platformToken, timeout: timeout)
        return try DeepSeekUsageParser.usageDetails(amountData: try await amountData,
                                                    costData: try await costData,
                                                    now: now, calendar: calendar)
    }

    private func request(_ url: URL, token: String, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 平台用量页与公开 API 使用不同的鉴权域；网页接口用该标记返回网页口径。
        request.setValue("web", forHTTPHeaderField: "x-client-platform")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw DeepSeekUsageError.network("读取 DeepSeek 用量超时。")
        } catch {
            throw DeepSeekUsageError.network("无法连接 DeepSeek 官方接口。")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 || status == 403 || (300...399).contains(status) {
            throw DeepSeekUsageError.unauthorized
        }
        guard (200...299).contains(status) else {
            throw DeepSeekUsageError.api("DeepSeek 接口返回 HTTP \(status)")
        }
        return data
    }
}
