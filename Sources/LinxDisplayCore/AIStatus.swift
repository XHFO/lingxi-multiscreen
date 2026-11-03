import Foundation

/// AI 工具的统一生命周期状态。
public enum AIStatusState: String, Codable, CaseIterable, Sendable {
    case idle, running, approval, error, completed

    public var title: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "运行中"
        case .approval: return "请求批准"
        case .error: return "报错"
        case .completed: return "已完成"
        }
    }

    public var symbol: String {
        switch self {
        case .idle: return "moon.zzz"
        case .running: return "play.circle.fill"
        case .approval: return "hand.raised.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }
}

public struct AIStatusEntry: Identifiable, Equatable, Sendable {
    public var source: String
    public var task: String
    public var state: AIStatusState
    public var message: String
    public var updatedAt: Date

    public var id: String { source }

    public init(source: String, task: String = "", state: AIStatusState,
                message: String = "", updatedAt: Date = Date()) {
        self.source = source
        self.task = task
        self.state = state
        self.message = message
        self.updatedAt = updatedAt
    }

    /// 本地 hook 上报 JSON。
    public init?(json: [String: Any], now: Date = Date()) {
        guard let source = json["source"] as? String, !source.isEmpty,
              let raw = json["state"] as? String,
              let state = AIStatusState(rawValue: raw.lowercased()) else { return nil }
        self.init(source: source,
                  task: (json["task"] as? String) ?? "",
                  state: state,
                  message: (json["message"] as? String) ?? "",
                  updatedAt: now)
    }
}

/// 读取 Codex 本地 thread/turn 数据库，得到运行中、报错和最近完成状态。
/// 等待批准无法从数据库稳定推导，需通过本机状态 hook 上报。
public enum AIStatusReader {
    public static func readCodex(now: Date = Date(),
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AIStatusEntry? {
        let history = home.appendingPathComponent(".codex/thread_history_1.sqlite")
        let state = home.appendingPathComponent(".codex/state_5.sqlite")
        guard FileManager.default.fileExists(atPath: history.path),
              FileManager.default.fileExists(atPath: state.path) else { return nil }
        let query = """
        attach '\(state.path.replacingOccurrences(of: "'", with: "''"))' as s;
        select t.title as title, tu.status as status, tu.error_json as error,
               tu.started_at as started, tu.completed_at as completed
        from thread_turns tu join s.threads t on t.id = tu.thread_id
        where tu.started_at is not null
        order by tu.started_at desc limit 8;
        """
        guard let data = runSQLite(history.path, query),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return parseCodexRows(rows, now: now)
    }

    public static func parseCodexRows(_ rows: [[String: Any]], now: Date = Date()) -> AIStatusEntry? {
        guard let first = rows.first else { return nil }
        let title = ((first["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let status = ((first["status"] as? String) ?? "").lowercased()
        let started = date(first["started"])
        let completed = date(first["completed"])
        let task = title.isEmpty ? "Codex 任务" : title
        switch status {
        case "inprogress":
            if let started, now.timeIntervalSince(started) < 6 * 3600 {
                return AIStatusEntry(source: "Codex", task: task, state: .running,
                                     message: "任务运行中", updatedAt: started)
            }
        case "failed":
            if let completed, now.timeIntervalSince(completed) < 24 * 3600 {
                let message = errorMessage(first["error"]) ?? "任务执行失败"
                return AIStatusEntry(source: "Codex", task: task, state: .error,
                                     message: message, updatedAt: completed)
            }
        case "completed":
            if let completed, now.timeIntervalSince(completed) < 30 * 60 {
                return AIStatusEntry(source: "Codex", task: task, state: .completed,
                                     message: "任务已完成", updatedAt: completed)
            }
        default:
            break
        }
        return AIStatusEntry(source: "Codex", task: task, state: .idle,
                             message: "最近没有运行中的任务",
                             updatedAt: completed ?? started ?? now)
    }

    private static func runSQLite(_ path: String, _ query: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", path, query]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        if let number = value as? Double { return Date(timeIntervalSince1970: number) }
        if let number = value as? Int { return Date(timeIntervalSince1970: Double(number)) }
        return nil
    }

    private static func errorMessage(_ value: Any?) -> String? {
        if let text = value as? String {
            if let data = text.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = root["message"] as? String, !message.isEmpty { return message }
            return text.isEmpty ? nil : text
        }
        if let root = value as? [String: Any], let message = root["message"] as? String { return message }
        return nil
    }
}
