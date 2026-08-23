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
        case .invalidResponse: return "GitHub 返回了无法识别的内容。"
        }
    }
}

/// GitHub 仓库 Release 客户端：拉取最新版本用于更新提醒
public enum GitHubReleaseClient {
    /// 多屏灵犀的 GitHub 仓库
    public static let repo = "XHFO/lingxi-multiscreen"

    /// 拉取最新 Release（tag 形如 v1.3.0）
    public static func fetchLatestRelease(timeout: TimeInterval = 10) async throws -> GitHubReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw GitHubReleaseError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // GitHub API 强制要求 User-Agent
        request.setValue("LingxiMultiScreen", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw GitHubReleaseError.unreachable
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            throw GitHubReleaseError.invalidResponse
        }
        var published: Date?
        if let iso = obj["published_at"] as? String {
            published = ISO8601DateFormatter().date(from: iso)
        }
        var html: URL?
        if let s = obj["html_url"] as? String { html = URL(string: s) }
        return GitHubReleaseInfo(tag: tag, publishedAt: published, htmlURL: html)
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
