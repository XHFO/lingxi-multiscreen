import Foundation

public enum AutomaticSyncAction {
    case none
    case push
    case refreshAndPush
}

/// 自动同步规划：Codex 模式在“数据过期”时刷新并推送，否则每分钟推送一次。
public enum SyncPlanner {
    public static func forCodex(now: Date,
                                lastRefresh: Date?,
                                lastPush: Date?,
                                refreshSeconds: Int) -> AutomaticSyncAction {
        guard let lastRefresh else { return .refreshAndPush }
        if now.timeIntervalSince(lastRefresh) >= TimeInterval(max(1, refreshSeconds)) {
            return .refreshAndPush
        }
        guard let lastPush else { return .push }
        if !isSameLocalMinute(now, lastPush) {
            return .push
        }
        return .none
    }

    private static func isSameLocalMinute(_ left: Date, _ right: Date) -> Bool {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let a = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: left)
        let b = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: right)
        return a.year == b.year && a.month == b.month && a.day == b.day
            && a.hour == b.hour && a.minute == b.minute
    }
}
