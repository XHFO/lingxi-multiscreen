import Foundation

/// 彩色屏卡片自动轮播的纯判定逻辑。
///
/// 手动选择卡片不经过这里；这里只负责定时轮播候选过滤，以及换歌时的即时优先显示。
public enum SmartCardRotationPolicy {
    public static let printerCompletionRetention: TimeInterval = 30 * 60

    public enum PrinterActivity: Equatable {
        case active
        /// 报错/失败仍需让用户看到，不能因为设备停止运动就从轮播中静默消失。
        case attention
        /// 成功完成是一个单独终态：只有本次进程确实观察到从工作态进入完成态，
        /// 才能获得有限的轮播保留时间。
        case completed
        /// 普通空闲本身应立即跳过；若它紧跟在一次已确认的成功完成之后，则沿用该次
        /// 完成窗口的原截止时间（不会从进入 idle 的时刻重新计时）。
        case idle
        /// 离线、断开、取消等不能继续继承成功完成窗口的状态。
        case inactive
        /// 为新固件或尚未收录的状态保留展示机会，只跳过能够明确判定为空闲的状态。
        case unknown

        /// 不带历史的保守结果。完成态必须交给带时间状态的重载判定，不能在重启后
        /// 因一份持久化完成缓存重新获得 30 分钟。
        public var participatesInRotation: Bool {
            switch self {
            case .active, .attention, .unknown: return true
            case .completed, .idle, .inactive: return false
            }
        }

        fileprivate var canStartCompletionRetention: Bool {
            switch self {
            case .active, .attention: return true
            case .completed, .idle, .inactive, .unknown: return false
            }
        }
    }

    /// 调用方按真实打印机 ID 分别保存此值；策略本身不持有全局缓存或读取系统时间。
    public struct PrinterRotationState: Equatable {
        public var lastActivity: PrinterActivity?
        public var completedAt: Date?

        public init(lastActivity: PrinterActivity? = nil, completedAt: Date? = nil) {
            self.lastActivity = lastActivity
            self.completedAt = completedAt
        }
    }

    public struct PrinterRotationDecision: Equatable {
        public var state: PrinterRotationState
        public var participatesInRotation: Bool

        public init(state: PrinterRotationState, participatesInRotation: Bool) {
            self.state = state
            self.participatesInRotation = participatesInRotation
        }
    }

    /// 智能换歌抢占的可撤销令牌。只有页面仍是本令牌呈现的目标时才允许恢复；
    /// 用户或其他轮播逻辑中途切走后，旧令牌不会覆盖新的选择。
    public struct AutomaticTakeover<Target: Equatable>: Equatable {
        public var previousTarget: Target
        public var presentedTarget: Target

        public init(previousTarget: Target, presentedTarget: Target) {
            self.previousTarget = previousTarget
            self.presentedTarget = presentedTarget
        }
    }

    public static func beginAutomaticTakeover<Target: Equatable>(
        from current: Target,
        presenting target: Target
    ) -> AutomaticTakeover<Target>? {
        guard current != target else { return nil }
        return AutomaticTakeover(previousTarget: current, presentedTarget: target)
    }

    public static func releaseAutomaticTakeover<Target: Equatable>(
        _ takeover: AutomaticTakeover<Target>,
        current: Target
    ) -> Target? {
        current == takeover.presentedTarget ? takeover.previousTarget : nil
    }

    /// 空标题和明确的“未在播放”都不是自动轮播候选。暂停不影响此判定：只要仍有
    /// 有效曲目信息，暂停页就可以按用户配置继续参与轮播。
    public static func hasValidNowPlayingTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized != "未在播放"
    }

    /// 新的有效歌曲开始播放时，只有用户已明确把「正在播放」加入轮播池才允许抢占。
    /// seek、暂停/继续不会改变歌曲标识，因此不会触发。
    public static func shouldPrioritizeNowPlaying(
        songChanged: Bool,
        isPlaying: Bool,
        rotationEnabled: Bool,
        rotationModes: [DisplayMode],
        currentMode: DisplayMode
    ) -> Bool {
        songChanged
            && isPlaying
            && rotationEnabled
            && currentMode != .nowPlaying
            && rotationModes.contains(.nowPlaying)
    }

    /// 从当前卡片之后寻找下一张可参与自动轮播的卡片。
    ///
    /// 打印机空闲时由调用方通过 `isEligible` 排除；即使当前卡本身已经不再符合条件，
    /// 仍会从其原有顺序的后一项继续，避免轮播顺序突然跳回列表开头。
    public static func nextMode(
        after currentMode: DisplayMode,
        in orderedModes: [DisplayMode],
        isEligible: (DisplayMode) -> Bool
    ) -> DisplayMode? {
        guard !orderedModes.isEmpty else { return nil }
        let currentIndex = orderedModes.firstIndex(of: currentMode) ?? -1
        for offset in 1...orderedModes.count {
            let index = (currentIndex + offset + orderedModes.count) % orderedModes.count
            let candidate = orderedModes[index]
            if candidate != currentMode, isEligible(candidate) { return candidate }
        }
        return nil
    }

    /// 消费一次来自设备的成功、非缓存状态观察，并返回新的纯值状态。
    ///
    /// 首次观察就是 completed 时不会建立窗口；inactive → completed 也不会建立窗口。
    /// 这避免应用重启、旧快照恢复或离线设备的陈旧完成状态被误当成“刚刚完成”。
    public static func observePrinterActivity(
        _ activity: PrinterActivity,
        previous: PrinterRotationState = PrinterRotationState(),
        at now: Date,
        completionEvidenceAt: Date? = nil,
        completionRetention: TimeInterval = printerCompletionRetention
    ) -> PrinterRotationDecision {
        var state = previous
        switch activity {
        case .completed:
            let continuingKnownCompletion = previous.completedAt != nil
                && (previous.lastActivity == .completed || previous.lastActivity == .idle)
            if !continuingKnownCompletion {
                if let completionEvidenceAt {
                    let elapsed = now.timeIntervalSince(completionEvidenceAt)
                    // last_changed 一旦存在就是权威绝对时间：未来时间或已经过期时直接
                    // 不建窗口，不能再退回 now 而重新赠送完整 30 分钟。
                    state.completedAt = elapsed >= 0 && elapsed < max(0, completionRetention)
                        ? completionEvidenceAt : nil
                } else {
                    state.completedAt = previous.lastActivity?.canStartCompletionRetention == true
                        ? now : nil
                }
            }
            state.lastActivity = .completed
        case .active, .attention, .unknown:
            state.lastActivity = activity
            state.completedAt = nil
        case .idle:
            let followsKnownCompletion = previous.completedAt != nil
                && (previous.lastActivity == .completed || previous.lastActivity == .idle)
            state.lastActivity = .idle
            if !followsKnownCompletion { state.completedAt = nil }
        case .inactive:
            state.lastActivity = .inactive
            state.completedAt = nil
        }
        return PrinterRotationDecision(
            state: state,
            participatesInRotation: printerParticipatesInRotation(
                activity: activity, state: state, at: now,
                completionRetention: completionRetention)
        )
    }

    /// 在任意注入时间读取资格；读取本身不延长完成窗口。
    public static func printerParticipatesInRotation(
        activity: PrinterActivity,
        state: PrinterRotationState,
        at now: Date,
        completionRetention: TimeInterval = printerCompletionRetention
    ) -> Bool {
        switch activity {
        case .active, .attention, .unknown:
            return true
        case .inactive:
            return false
        case .completed, .idle:
            guard let completedAt = state.completedAt else {
                return false
            }
            let elapsed = now.timeIntervalSince(completedAt)
            return elapsed >= 0 && elapsed < max(0, completionRetention)
        }
    }

    /// Bambu Lab 与 Formlabs 的工作状态归一判定。
    ///
    /// 区分成功完成与普通空闲。暂停属于尚未结束的任务；错误/失败属于需要用户留意的状态；
    /// 新固件返回的未知状态继续展示，避免升级后整张打印机卡被静默隐藏。
    public static func printerActivity(states: [String]) -> PrinterActivity {
        guard !states.isEmpty else { return .unknown }
        let activities = states.map(printerActivity(state:))
        // 任一来源明确报告离线/断开/取消时立即退出；不能被另一份缓存里的
        // finished/printing 文本掩盖并继续占用轮播权重。
        if activities.contains(.inactive) { return .inactive }
        if activities.contains(.attention) { return .attention }
        if activities.contains(.active) { return .active }
        if activities.contains(.completed) { return .completed }
        if activities.contains(.unknown) { return .unknown }
        if activities.contains(.idle) { return .idle }
        return .inactive
    }

    public static func printerActivity(state: String) -> PrinterActivity {
        let normalized = state
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        guard !normalized.isEmpty else { return .unknown }

        let attentionFragments = [
            "error", "failed", "failure", "fault", "jammed", "blocked",
            "报错", "错误", "异常", "失败", "故障", "堵塞"
        ]
        if attentionFragments.contains(where: { normalized.contains($0) }) {
            return .attention
        }

        // 先识别终态/空闲态，避免诸如 not_printing、ready_to_print 一类文本被工作关键字误中。
        let completedTokens = [
            "completed", "complete", "finished", "finish", "success", "succeeded", "done",
            "已完成", "完成"
        ]
        if completedTokens.contains(normalized) { return .completed }

        let idleTokens = [
            "idle", "standby", "ready", "ready_to_print", "not_printing",
            "空闲", "待机", "就绪"
        ]
        if idleTokens.contains(normalized) { return .idle }

        let inactiveTokens = [
            "off", "offline", "disconnected", "unavailable",
            "cancelled", "canceled", "cancel", "aborted",
            "关机", "离线", "已取消", "取消"
        ]
        if inactiveTokens.contains(normalized) { return .inactive }

        let activeFragments = [
            "printing", "paused", "pause", "running", "busy",
            "preparing", "prepare", "initializing", "init", "starting",
            "slicing", "queued", "pending", "loading", "unloading",
            "heating", "cooling", "calibrating", "calibration", "leveling",
            "scanning", "measuring", "inspecting", "checking", "moving", "homing",
            "extrusion", "purge", "filament", "curing", "finishing", "post_process",
            "打印中", "已暂停", "暂停", "运行中", "忙碌", "准备", "初始化",
            "切片", "排队", "进料", "退料", "换料", "加热", "冷却", "校准",
            "调平", "扫描", "测量", "检测", "检查", "移动", "归位", "处理中"
        ]
        if activeFragments.contains(where: { normalized.contains($0) }) { return .active }
        return .unknown
    }
}
