import Foundation

/// 千问办公剩余额度。通过本机千问办公桌面应用的本地 MCP 服务（127.0.0.1）查询。
public struct QwenWorkQuota: Equatable {
    public struct Segment: Equatable {
        public var id: String
        public var remaining: Double
        public var unit: String

        public init(id: String, remaining: Double, unit: String) {
            self.id = id
            self.remaining = remaining
            self.unit = unit
        }
    }

    public var available: Bool
    public var remainingCredits: Double
    public var usedCredits: Double
    public var totalCredits: Double
    public var percentageUsed: Double? // 0-100
    public var unit: String
    public var plan: String?
    public var segments: [Segment]
    public var sampledAt: Date
    /// 客户端跟踪的剩余额度进度（0-1）：基于本次会话观察到的最高剩余额度计算；
    /// 为 nil 时回退到 percentageUsed 口径
    public var trackedProgress: Double?

    public init(available: Bool, remainingCredits: Double, usedCredits: Double,
                totalCredits: Double, percentageUsed: Double?, unit: String,
                plan: String?, segments: [Segment], sampledAt: Date,
                trackedProgress: Double? = nil) {
        self.available = available
        self.remainingCredits = remainingCredits
        self.usedCredits = usedCredits
        self.totalCredits = totalCredits
        self.percentageUsed = percentageUsed
        self.unit = unit
        self.plan = plan
        self.segments = segments
        self.sampledAt = sampledAt
        self.trackedProgress = trackedProgress
    }

    /// 剩余额度进度（0-1）：优先用客户端跟踪进度；否则用百分比口径 100 - 已用百分比。
    public var progress: Double {
        if let trackedProgress { return min(max(trackedProgress, 0), 1) }
        guard let percentageUsed else { return 1 }
        return min(max(1 - percentageUsed / 100, 0), 1)
    }

    /// 剩余额度进度：以手动捕获的基线为 100%，返回 当前/基线（0-1）；
    /// 未设置基线返回 nil（此时按 100% 处理或提示设置基线）。
    public static func trackedQuotaProgress(current: Double, baseline: Double?) -> Double? {
        guard let baseline, baseline > 0 else { return nil }
        return min(current / baseline, 1)
    }

    public static let sample = QwenWorkQuota(
        available: true, remainingCredits: 2061.9, usedCredits: 0, totalCredits: 0,
        percentageUsed: 0, unit: "credits", plan: "Free",
        segments: [Segment(id: "plan", remaining: 2061.9, unit: "credits")],
        sampledAt: Date()
    )
}

/// 额度百分比基线采样器：每日定期采样、更新、刷新基线。
///
/// 规则：
/// - 首次采样或跨天（基线日 != 今天）时，以当前剩余额度重新采样为基线（每日刷新）；
/// - 同一日内剩余额度回升超过基线（如每日赠送积分入账、套餐升级）时，把基线自动拉高到当前额度，
///   避免百分比基数低于实际额度导致显示失真；
/// - 剩余额度为 0 时不动基线（避免把基线清零使百分比失去参照）。
public enum QuotaBaselineSampler {
    /// 按规则更新基线，返回 (基线, 基线采样日)。
    public static func sample(baseline: Double?, baselineDay: String?,
                              remaining: Double, today: String) -> (baseline: Double?, day: String?) {
        guard remaining > 0 else { return (baseline, baselineDay) }
        if baseline == nil || baselineDay != today {
            // 首次采样或新的一天：以当前额度重新采样
            return (remaining, today)
        }
        if remaining > baseline! {
            // 同日额度回升超过基线（每日赠送积分入账）：把基线拉高到当前额度
            return (remaining, today)
        }
        return (baseline, baselineDay)
    }

    /// 本地时区下的「yyyy-MM-dd」天键，用于判断是否跨天。
    public static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public enum QuotaError: Error, LocalizedError {
    case configNotFound
    case unreachable
    case invalidResponse
    case timeout

    public var errorDescription: String? {
        switch self {
        case .configNotFound:
            return "未找到千问办公本机服务配置（~/.qwenworkcn/mcp-adaptor.config）。请确认已登录并运行千问办公。"
        case .unreachable:
            return "无法连接千问办公本机服务，请确认千问办公正在运行。"
        case .invalidResponse:
            return "千问办公返回了无法识别的额度数据。"
        case .timeout:
            return "读取千问办公额度超时。"
        }
    }
}

/// 通过千问办公桌面应用的本地 MCP 端点查询账号剩余额度。
/// 配置与令牌每次请求时重新读取（令牌会随会话轮换）。
public final class QwenWorkQuotaClient {
    public init() {}

    public func fetch(timeout: TimeInterval = 6) async throws -> QwenWorkQuota {
        let config = try Self.loadConfig()
        var request = URLRequest(url: config.url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.token, forHTTPHeaderField: "x-api-key")

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "qw_query",
                "arguments": ["key": "qwenwork.usage"]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw QuotaError.timeout
        } catch {
            throw QuotaError.unreachable
        }

        var quota = try Self.parseResponse(data)
        quota.plan = Self.readPlanName()
        return quota
    }

    // MARK: - 解析

    /// 解析完整 JSON-RPC 响应体。
    public static func parseResponse(_ body: Data) throws -> QwenWorkQuota {
        guard let outer = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let result = outer["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let inner = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let data = inner["data"] as? [String: Any] else {
            throw QuotaError.invalidResponse
        }
        return try parseUsageData(data)
    }

    /// 解析 usage 数据对象（data 字段）。
    public static func parseUsageData(_ data: [String: Any]) throws -> QwenWorkQuota {
        let available = (data["available"] as? Bool) ?? true

        // 优先 planCredits，其次各 segment 求和
        var remaining = 0.0
        var used = 0.0
        var total = 0.0
        var percentageUsed: Double?
        var unit = "credits"

        if let planCredits = data["planCredits"] as? [String: Any] {
            remaining = (planCredits["remaining"] as? Double) ?? remaining
            used = (planCredits["used"] as? Double) ?? used
            total = (planCredits["total"] as? Double) ?? total
            percentageUsed = (planCredits["percentage"] as? Double) ?? percentageUsed
            unit = (planCredits["unit"] as? String) ?? unit
        }

        var segments: [QwenWorkQuota.Segment] = []
        if let rawSegments = data["segments"] as? [[String: Any]] {
            for segment in rawSegments {
                let id = segment["id"] as? String ?? "plan"
                let segRemaining = (segment["remaining"] as? Double) ?? 0
                let segUnit = segment["unit"] as? String ?? "credits"
                segments.append(QwenWorkQuota.Segment(id: id, remaining: segRemaining, unit: segUnit))
            }
        }
        if segments.isEmpty && remaining > 0 {
            segments.append(QwenWorkQuota.Segment(id: "plan", remaining: remaining, unit: unit))
        }
        // 无 planCredits 时退化为各 segment 求和
        if data["planCredits"] == nil {
            remaining = segments.reduce(0) { $0 + $1.remaining }
            if let first = segments.first { unit = first.unit }
        }

        return QwenWorkQuota(
            available: available,
            remainingCredits: remaining,
            usedCredits: used,
            totalCredits: total,
            percentageUsed: percentageUsed,
            unit: unit,
            plan: nil, // 由调用方补充（来自 .status.json）
            segments: segments,
            sampledAt: Date()
        )
    }

    // MARK: - 配置与账户

    private struct Config {
        var url: URL
        var token: String
    }

    private static func loadConfig() throws -> Config {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".qwenworkcn/mcp-adaptor.config")
        guard let data = try? Data(contentsOf: configURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let urlString = root["url"] as? String,
              let url = URL(string: urlString),
              let token = (root["token"] as? String) ?? (root["headers"] as? [String: Any])?["x-api-key"] as? String,
              !token.isEmpty else {
            throw QuotaError.configNotFound
        }
        return Config(url: url, token: token)
    }

    private static func readPlanName() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let statusURL = home.appendingPathComponent(".qwenworkcn/.status.json")
        guard let data = try? Data(contentsOf: statusURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plan = root["plan"] as? String, !plan.isEmpty else {
            return nil
        }
        return plan
    }
}
