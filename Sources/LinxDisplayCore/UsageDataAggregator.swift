import Foundation

/// 统一数据调取器：一次调用并行拉取 Codex、千问、Grok Bot 与 DeepSeek。
/// 结果由软件统一缓存并分发给各卡片、画板模块和预览。
/// Cloudflare 网站统计走本机 CloudflareAnalytics 独立刷新。
/// 单源失败不影响其他源（抛错的源返回 nil 并保留旧缓存）。
/// Grok Bot 的「未配置」是成功快照，不会占掉失败列表。
public struct UsageDataAggregator {
    public typealias CodexFetcher = (String?) async throws -> UsageSnapshot
    public typealias QuotaFetcher = () async throws -> QwenWorkQuota
    public typealias GrokFetcher = () async -> GrokBotUsageSnapshot
    public typealias DeepSeekFetcher = () async -> DeepSeekUsageSnapshot

    public var fetchCodex: CodexFetcher
    public var fetchQuota: QuotaFetcher
    public var fetchGrokBot: GrokFetcher?
    public var fetchDeepSeek: DeepSeekFetcher?

    public init(fetchCodex: @escaping CodexFetcher,
                fetchQuota: @escaping QuotaFetcher,
                fetchGrokBot: GrokFetcher? = nil,
                fetchDeepSeek: DeepSeekFetcher? = nil) {
        self.fetchCodex = fetchCodex
        self.fetchQuota = fetchQuota
        self.fetchGrokBot = fetchGrokBot
        self.fetchDeepSeek = fetchDeepSeek
    }

    /// 单次统一调取的结果。抛错的源为 nil；可选源未接入时也为 nil。
    public struct Outcome: Equatable {
        public var usage: UsageSnapshot?
        public var quota: QwenWorkQuota?
        public var grokBot: GrokBotUsageSnapshot?
        public var deepSeek: DeepSeekUsageSnapshot?
        public var failures: [String]

        public init(usage: UsageSnapshot? = nil,
                    quota: QwenWorkQuota? = nil,
                    grokBot: GrokBotUsageSnapshot? = nil,
                    deepSeek: DeepSeekUsageSnapshot? = nil,
                    failures: [String] = []) {
            self.usage = usage
            self.quota = quota
            self.grokBot = grokBot
            self.deepSeek = deepSeek
            self.failures = failures
        }
    }

    /// 并行调取已接入的数据源。
    public func fetch(codexCliPath: String?) async -> Outcome {
        async let usageOutcome = capture { try await fetchCodex(codexCliPath) }
        async let quotaOutcome = capture { try await fetchQuota() }
        async let grokSnapshot = loadGrokBot()
        async let deepSeekSnapshot = loadDeepSeek()
        let (usageResult, quotaResult, grokResult, deepSeekResult) = await (
            usageOutcome, quotaOutcome, grokSnapshot, deepSeekSnapshot)

        var outcome = Outcome()
        switch usageResult {
        case .success(let snapshot): outcome.usage = snapshot
        case .failure(let error): outcome.failures.append("Codex：\(error.localizedDescription)")
        }
        switch quotaResult {
        case .success(let quota): outcome.quota = quota
        case .failure(let error): outcome.failures.append("千问办公：\(error.localizedDescription)")
        }
        if let grokResult {
            outcome.grokBot = grokResult
            if let note = grokResult.statusFailure {
                outcome.failures.append("Grok Bot：\(note)")
            }
        }
        if let deepSeekResult {
            outcome.deepSeek = deepSeekResult
            if let note = deepSeekResult.statusFailure {
                outcome.failures.append("DeepSeek：\(note)")
            }
        }
        return outcome
    }

    private func loadGrokBot() async -> GrokBotUsageSnapshot? {
        guard let fetchGrokBot else { return nil }
        return await fetchGrokBot()
    }

    private func loadDeepSeek() async -> DeepSeekUsageSnapshot? {
        guard let fetchDeepSeek else { return nil }
        return await fetchDeepSeek()
    }


    private func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) }
        catch { return .failure(error) }
    }
}
