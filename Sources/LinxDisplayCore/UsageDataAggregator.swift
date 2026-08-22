import Foundation

/// 统一数据调取器：一次调用并行拉取 Codex 用量与千问办公额度，
/// 结果由软件统一缓存并分发给各功能（Codex 卡片 / 千问卡片 / 画板额度模块 / 预览），
/// 避免各功能各自重复拉取。单源失败不影响另一源（对应字段返回 nil，保留旧缓存）。
public struct UsageDataAggregator {
    public typealias CodexFetcher = (String?) async throws -> UsageSnapshot
    public typealias QuotaFetcher = () async throws -> QwenWorkQuota

    public var fetchCodex: CodexFetcher
    public var fetchQuota: QuotaFetcher

    public init(fetchCodex: @escaping CodexFetcher,
                fetchQuota: @escaping QuotaFetcher) {
        self.fetchCodex = fetchCodex
        self.fetchQuota = fetchQuota
    }

    /// 单次统一调取的结果：两源各自的快照（失败为 nil）+ 失败原因列表。
    public struct Outcome: Equatable {
        public var usage: UsageSnapshot?
        public var quota: QwenWorkQuota?
        public var failures: [String]

        public init(usage: UsageSnapshot? = nil,
                    quota: QwenWorkQuota? = nil,
                    failures: [String] = []) {
            self.usage = usage
            self.quota = quota
            self.failures = failures
        }
    }

    /// 并行调取两个数据源，一次调用同时更新两个缓存字段。
    public func fetch(codexCliPath: String?) async -> Outcome {
        async let usageOutcome = capture { try await fetchCodex(codexCliPath) }
        async let quotaOutcome = capture { try await fetchQuota() }
        let (usageResult, quotaResult) = await (usageOutcome, quotaOutcome)

        var outcome = Outcome()
        switch usageResult {
        case .success(let snapshot): outcome.usage = snapshot
        case .failure(let error): outcome.failures.append("Codex：\(error.localizedDescription)")
        }
        switch quotaResult {
        case .success(let quota): outcome.quota = quota
        case .failure(let error): outcome.failures.append("千问办公：\(error.localizedDescription)")
        }
        return outcome
    }

    private func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) }
        catch { return .failure(error) }
    }
}
