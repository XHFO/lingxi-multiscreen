import CoreFoundation
import Foundation

/// Cursor 账号上的 Grok Bot 每周用量。
/// 只在同时读到已用百分比和「套餐包含额度」标记时显示剩余；缺失字段不会当成 0% 或 100%。
public struct GrokBotUsageSnapshot: Equatable {
    public enum State: String, Equatable {
        case live
        case notConfigured
        case sealedLogin
        case unauthorized
        case notIncluded
        case pooled
        case unreadable
        case unreachable
    }

    public var state: State
    /// 已用百分比，0–100。只有 `.live` 时有值。
    public var usagePercent: Double?
    public var remainingPercent: Int?
    public var planLabel: String?
    public var resetDate: Date?
    /// 仅在接口明确返回且大于 0 时保留。0 次不展示。
    public var availableBankedResetCount: Int?
    public var sampledAt: Date?
    public var message: String

    public init(state: State, usagePercent: Double? = nil, remainingPercent: Int? = nil,
                planLabel: String? = nil, resetDate: Date? = nil,
                availableBankedResetCount: Int? = nil, sampledAt: Date? = nil,
                message: String) {
        self.state = state
        self.usagePercent = usagePercent
        self.remainingPercent = remainingPercent
        self.planLabel = planLabel
        self.resetDate = resetDate
        self.availableBankedResetCount = availableBankedResetCount
        self.sampledAt = sampledAt
        self.message = message
    }

    public var isAvailable: Bool { state == .live && remainingPercent != nil }

    /// 需要出现在状态栏的失败。未配置、加密登录、套餐不含额度都不反复打扰。
    public var statusFailure: String? {
        switch state {
        case .unauthorized: return "登录已失效或无权读取用量"
        case .unreachable: return "暂时无法连接 Cursor 用量服务"
        case .unreadable: return message
        case .live, .notConfigured, .sealedLogin, .notIncluded, .pooled: return nil
        }
    }

    public static let notConfigured = GrokBotUsageSnapshot(
        state: .notConfigured,
        message: "尚未配置。可在设置中粘贴 Cursor 会话令牌，或使用尚未加密的本机登录。")

    public static func sealedLogin(now: Date) -> GrokBotUsageSnapshot {
        GrokBotUsageSnapshot(
            state: .sealedLogin, sampledAt: now,
            message: "本机 Cursor 登录已加密。请在设置中粘贴会话令牌。")
    }
}

/// 读取 Cursor 仪表盘的 Grok Bot（内部名称 Sand）每周用量。
/// 不解密钥匙串，不读取 Grok CLI / SuperGrok 的另一套账单。
public final class GrokBotUsageClient {
    public static let sealedPrefix = "cursor-safe-storage:v1:"
    public static let endpoint = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!

    private let session: URLSession

    public init(session: URLSession = EphemeralJSONSession.make()) {
        self.session = session
    }

    public func fetch(sessionToken: String, now: Date = Date()) async -> GrokBotUsageSnapshot {
        let pasted = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: String
        if !pasted.isEmpty {
            if pasted.hasPrefix(Self.sealedPrefix) { return .sealedLogin(now: now) }
            raw = pasted
        } else {
            switch Self.readLocalCursorAccessToken() {
            case .missing: return .notConfigured
            case .sealed: return .sealedLogin(now: now)
            case .plaintext(let token): raw = token
            }
        }
        guard let cookie = Self.sessionCookieValue(from: raw) else {
            return GrokBotUsageSnapshot(
                state: .unreadable, sampledAt: now,
                message: "会话令牌无法识别。请粘贴 WorkosCursorSessionToken 或 Cursor access token。")
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return Self.interpret(statusCode: status, body: data, now: now)
        } catch {
            return GrokBotUsageSnapshot(
                state: .unreachable, sampledAt: now,
                message: "暂时无法连接 Cursor 用量服务。")
        }
    }

    public static func interpret(statusCode: Int, body: Data, now: Date = Date()) -> GrokBotUsageSnapshot {
        if statusCode == 401 || statusCode == 403 || (300...399).contains(statusCode) {
            return GrokBotUsageSnapshot(
                state: .unauthorized, sampledAt: now,
                message: "登录已失效或无权读取用量。")
        }
        guard (200...299).contains(statusCode) else {
            return GrokBotUsageSnapshot(
                state: .unreachable, sampledAt: now,
                message: "暂时无法连接 Cursor 用量服务。")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return GrokBotUsageSnapshot(
                state: .unauthorized, sampledAt: now,
                message: "登录已失效或无权读取用量。")
        }
        if quotaJSONBool(object, ["usesPooledEnterpriseAllowance", "uses_pooled_enterprise_allowance"]) == true {
            return GrokBotUsageSnapshot(
                state: .pooled, sampledAt: now,
                message: "用量来自企业共享池，这里不显示个人每周剩余。")
        }
        let limitZero = quotaJSONBool(object, ["includedLimitZero", "included_limit_zero"]) == true
        let included = quotaJSONBool(object, ["hasNonZeroIncludedLimit", "has_non_zero_included_limit"])
        if limitZero || included == false {
            return GrokBotUsageSnapshot(
                state: .notIncluded,
                planLabel: planLabel(object),
                sampledAt: now,
                message: "当前套餐未包含可显示的每周额度。")
        }
        guard included == true, let used = quotaJSONDouble(object, ["usagePercent", "usage_percent"]),
              used >= -0.5, used <= 100.5 else {
            return GrokBotUsageSnapshot(
                state: .unreadable,
                planLabel: planLabel(object),
                sampledAt: now,
                message: "已连接，但用量字段不完整，未显示百分比。")
        }
        let clamped = min(max(used, 0), 100)
        let remaining = Int((100 - clamped).rounded())
        let banked = quotaJSONInt(object, ["availableBankedResetCount", "available_banked_reset_count"])
        return GrokBotUsageSnapshot(
            state: .live,
            usagePercent: clamped,
            remainingPercent: min(max(remaining, 0), 100),
            planLabel: planLabel(object),
            resetDate: quotaJSONDate(object, ["nextResetTimestampUtc", "next_reset_timestamp_utc"]),
            availableBankedResetCount: (banked ?? 0) > 0 ? banked : nil,
            sampledAt: now,
            message: "")
    }

    /// Cookie 值本身，不含 `WorkosCursorSessionToken=` 前缀。
    public static func sessionCookieValue(from raw: String) -> String? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty || token.hasPrefix(sealedPrefix) { return nil }
        if let range = token.range(of: "WorkosCursorSessionToken=", options: [.caseInsensitive]) {
            token = String(token[range.upperBound...])
            if let end = token.firstIndex(of: ";") { token = String(token[..<end]) }
            token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if token.contains("%3A%3A") || token.contains("::") {
            let value = token.replacingOccurrences(of: "::", with: "%3A%3A")
            return value.isEmpty ? nil : value
        }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let payload = jwtPayload(String(parts[1])),
              let subject = payload["sub"] as? String else { return nil }
        let account = subject.split(separator: "|").last.map(String.init) ?? subject
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(trimmed)%3A%3A\(token)"
    }

    public enum LocalCursorToken: Equatable {
        case missing
        case sealed
        case plaintext(String)
    }

    /// 只读 `state.vscdb` 里的明文 access token。遇到加密前缀则返回 `.sealed`，不访问钥匙串。
    public static func readLocalCursorAccessToken() -> LocalCursorToken {
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path),
              let encoded = database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return .missing
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "file://\(encoded)?mode=ro",
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return .missing }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return .missing }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return .missing }
        if text.hasPrefix(sealedPrefix) { return .sealed }
        return .plaintext(text)
    }

    private static func planLabel(_ object: [String: Any]) -> String? {
        guard let raw = quotaJSONString(object, ["grokPlanLabel", "grok_plan_label"]) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jwtPayload(_ segment: String) -> [String: Any]? {
        var text = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - text.count % 4) % 4
        text += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: text),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}

func quotaJSONBool(_ object: [String: Any], _ keys: [String]) -> Bool? {
    for key in keys {
        guard let value = object[key], !(value is NSNull) else { continue }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        if let text = value as? String {
            if text.lowercased() == "true" { return true }
            if text.lowercased() == "false" { return false }
        }
    }
    return nil
}

func quotaJSONDouble(_ object: [String: Any], _ keys: [String]) -> Double? {
    for key in keys {
        guard let value = object[key], !(value is NSNull) else { continue }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        if let text = value as? String, let number = Double(text) { return number }
    }
    return nil
}

func quotaJSONInt(_ object: [String: Any], _ keys: [String]) -> Int? {
    guard let number = quotaJSONDouble(object, keys) else { return nil }
    return Int(number.rounded())
}

func quotaJSONString(_ object: [String: Any], _ keys: [String]) -> String? {
    for key in keys {
        if let text = object[key] as? String { return text }
    }
    return nil
}

func quotaJSONDate(_ object: [String: Any], _ keys: [String]) -> Date? {
    for key in keys {
        guard let value = object[key], !(value is NSNull) else { continue }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            var seconds = number.doubleValue
            if seconds > 1_000_000_000_000 { seconds /= 1000 }
            return Date(timeIntervalSince1970: seconds)
        }
        if let text = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) { return date }
        }
    }
    return nil
}
