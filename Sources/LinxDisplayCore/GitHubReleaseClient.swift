import Foundation

/// GitHub 仓库 Release 信息（更新提醒用）
public struct GitHubReleaseInfo: Equatable {
    public let tag: String
    public let publishedAt: Date?
    public let htmlURL: URL?

    public init(tag: String, publishedAt: Date?, htmlURL: URL?) {
        self.tag = tag
        self.publishedAt = publishedAt
        self.htmlURL = htmlURL
    }
}

public enum GitHubReleaseError: Error, LocalizedError {
    case unreachable
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unreachable: return "无法连接 GitHub，请检查网络。"
        case .invalidResponse: return "检查过于频繁，请稍后再试。"
        }
    }
}

/// GitHub 仓库 Release 客户端：拉取最新版本用于更新提醒。
/// 用网页端点 https://github.com/<repo>/releases/latest（302 → /releases/tag/<版本>）
/// 提取版本号——不依赖匿名 API（限流 60 次/时/IP 常耗尽 403），国内访问更稳
public enum GitHubReleaseClient {
    /// 多屏灵犀的 GitHub 仓库
    public static let repo = "XHFO/lingxi-multiscreen"

    /// 拉取最新 Release（tag 形如 v1.5.0）。URLSession 默认跟随重定向，
    /// 直接取 response.url（最终地址）解析 tag
    public static func fetchLatestRelease(timeout: TimeInterval = 10) async throws -> GitHubReleaseInfo {
        guard let url = URL(string: "https://github.com/\(repo)/releases/latest") else {
            throw GitHubReleaseError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("LingxiMultiScreen", forHTTPHeaderField: "User-Agent")
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GitHubReleaseError.unreachable
        }
        // 重定向后 response.url 即最终地址（https://github.com/<repo>/releases/tag/<版本>）
        guard let finalURL = response.url,
              let tag = extractTag(from: finalURL) else {
            throw GitHubReleaseError.invalidResponse
        }
        return GitHubReleaseInfo(tag: tag, publishedAt: nil, htmlURL: finalURL)
    }

    /// 从 /releases/tag/<版本> 的 URL 提取版本号（取尾段，兼容查询/锚点/尾斜杠）
    public static func extractTag(from url: URL) -> String? {
        let path = url.path
        guard let range = path.range(of: "/releases/tag/") else { return nil }
        return String(path[range.upperBound...])
            .split(separator: "/").first
            .map(String.init)
    }

    /// 版本号比较：v1.3.0 → 1.3.0 逐段数值比较；返回 latest 是否比 current 新
    public static func isNewer(latest: String, than current: String) -> Bool {
        func parse(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".")
                .compactMap { Int($0) }
        }
        let l = parse(latest), c = parse(current)
        let n = max(l.count, c.count)
        for i in 0..<n {
            let a = i < l.count ? l[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
