import Foundation
import LinxDisplayCore

/// Uses the app's dynamic interval and shared ink-display content checks.
/// The cadence is a content check, never a promise that a USB mount can finish within it.
enum ReadPicoBoardRefreshPolicy {
    static let supportedIntervals = [-1, 0, 1, 2, 5, 10, 15, 30, 60, 300, 900, 1800, 3600]
    static let maximumPowerAge: TimeInterval = 45
    struct Context {
        var dynamicSeconds = 5
        var contentCheckSeconds = 30
    }

    static func effectiveInterval(requested: Int, power: ReadPicoPowerStatus?, receivedAt: Date?,
                                  usb: Bool, now: Date = Date(), context: Context = .init()) -> Int? {
        guard requested != 0, supportedIntervals.contains(requested) else { return nil }
        let age = receivedAt.map { now.timeIntervalSince($0) }
        let fresh = age.map { $0 >= 0 && $0 <= maximumPowerAge } ?? false
        let powered = fresh && power?.known == true && power?.externalPower == true
        let shared = min(60, max(2, context.dynamicSeconds))
        let content = max(1, context.contentCheckSeconds)
        if requested == -1 { return powered ? shared : max(shared, content) }
        return powered ? requested : max(requested, content)
    }

    static func summary(requested: Int, power: ReadPicoPowerStatus?, receivedAt: Date?,
                        usb: Bool, now: Date = Date(), context: Context = .init()) -> String {
        guard let interval = effectiveInterval(requested: requested, power: power, receivedAt: receivedAt,
                                               usb: usb, now: now, context: context) else { return "手动发送" }
        let cadence = interval < 60 ? "每 \(interval) 秒检查变化" : "每 \(interval / 60) 分钟检查变化"
        let age = receivedAt.map { now.timeIntervalSince($0) }
        guard let age, age >= 0, age <= maximumPowerAge, let power, power.known else {
            return "\(cadence) · 等待设备供电信息"
        }
        let source = power.charging ? "充电中" : power.externalPower ? "外接供电" : "电池供电"
        return "\(cadence) · \(source)"
    }
}
