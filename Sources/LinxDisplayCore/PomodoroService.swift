import Foundation

/// 番茄钟状态机，逻辑与原版完全一致。
public final class PomodoroService {
    public let state: PomodoroState

    public init(state: PomodoroState) {
        self.state = state
        normalize()
    }

    @discardableResult
    public func tick(now: Date) -> Bool {
        var changed = false
        while isActive(state.phase), let endsAt = state.endsAt, now >= endsAt {
            advance(nextStart: endsAt)
            changed = true
        }
        return changed
    }

    public func startOrResume(now: Date) {
        if state.phase == .idle {
            state.phase = .focus
            state.endsAt = now.addingTimeInterval(TimeInterval(state.focusMinutes * 60))
        } else if state.phase == .paused {
            state.phase = isActive(state.resumePhase) ? state.resumePhase : .focus
            state.endsAt = now.addingTimeInterval(TimeInterval(max(1, state.pausedRemainingSeconds)))
            state.pausedRemainingSeconds = 0
        }
    }

    public func pause(now: Date) {
        guard isActive(state.phase) else { return }
        let remaining = Int(ceil((state.endsAt ?? now).timeIntervalSince(now)))
        state.pausedRemainingSeconds = max(0, remaining)
        state.resumePhase = state.phase
        state.phase = .paused
        state.endsAt = nil
    }

    public func skip(now: Date) {
        if state.phase == .idle {
            startOrResume(now: now)
            return
        }
        state.phase = state.phase == .paused ? state.resumePhase : state.phase
        advance(nextStart: now)
    }

    public func reset() {
        state.phase = .idle
        state.resumePhase = .focus
        state.endsAt = nil
        state.pausedRemainingSeconds = 0
        state.completedFocusSessions = 0
    }

    public func snapshot(now: Date) -> PomodoroSnapshot {
        var effective = state.phase == .paused ? state.resumePhase : state.phase
        if effective == .idle { effective = .focus }
        let duration = TimeInterval(minutes(for: effective) * 60)

        let remaining: TimeInterval
        switch state.phase {
        case .idle:
            remaining = duration
        case .paused:
            remaining = TimeInterval(max(0, state.pausedRemainingSeconds))
        default:
            if let endsAt = state.endsAt {
                remaining = endsAt.timeIntervalSince(now)
            } else {
                remaining = 0
            }
        }
        let clamped = min(max(remaining, 0), duration)

        return PomodoroSnapshot(
            phase: state.phase,
            effectivePhase: effective,
            taskName: state.taskName.trimmingCharacters(in: .whitespacesAndNewlines),
            remaining: clamped,
            duration: duration,
            completedFocusSessions: state.completedFocusSessions,
            endsAt: state.endsAt
        )
    }

    // MARK: - 内部

    private func advance(nextStart: Date) {
        if state.phase == .focus {
            state.completedFocusSessions += 1
            state.phase = state.completedFocusSessions % 4 == 0 ? .longBreak : .shortBreak
        } else {
            state.phase = .focus
        }
        state.resumePhase = state.phase
        state.pausedRemainingSeconds = 0
        state.endsAt = nextStart.addingTimeInterval(TimeInterval(minutes(for: state.phase) * 60))
    }

    private func minutes(for phase: PomodoroPhase) -> Int {
        switch phase {
        case .shortBreak: return state.shortBreakMinutes
        case .longBreak: return state.longBreakMinutes
        default: return state.focusMinutes
        }
    }

    private func normalize() {
        state.focusMinutes = min(max(state.focusMinutes, 1), 120)
        state.shortBreakMinutes = min(max(state.shortBreakMinutes, 1), 60)
        state.longBreakMinutes = min(max(state.longBreakMinutes, 1), 120)
        state.completedFocusSessions = max(0, state.completedFocusSessions)
        if state.taskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.taskName = "专注工作"
        }
        if state.phase == .paused && !isActive(state.resumePhase) {
            state.resumePhase = .focus
        }
        if isActive(state.phase) && state.endsAt == nil {
            state.phase = .idle
        }
    }

    private func isActive(_ phase: PomodoroPhase) -> Bool {
        phase == .focus || phase == .shortBreak || phase == .longBreak
    }

    // MARK: - 夸夸

    /// 内置夸夸语（随机轮换）
    public static let praisePhrases: [String] = [
        "太棒了！你又完成了一个专注时段",
        "自律的你闪闪发光，继续保持",
        "完成一段，离目标又近了一步",
        "做得漂亮！你的专注力值得大大的赞",
        "每一段坚持都在为你加分，干得好",
        "专注的你正在悄悄变强，太厉害了",
        "完美收官！给自己一点掌声吧",
        "又完成一段！你的效率今天也稳稳在线",
    ]

    /// 随机取一条内置夸夸语
    public static func randomPraisePhrase() -> String {
        praisePhrases.randomElement() ?? "太棒了！"
    }

    /// 拉取「一言」（每日随机语句）；网络失败或为空时返回 nil
    public static func fetchHitokoto() async -> String? {
        guard let url = URL(string: "https://v1.hitokoto.cn/?encode=text") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let result = text, !result.isEmpty else { return nil }
            return result
        } catch {
            return nil
        }
    }
}
