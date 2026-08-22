import Foundation

/// 少数派（sspai.com）推荐文章客户端：拉取编辑推荐到首页的最新文章。
/// 公开接口：GET https://sspai.com/api/v1/articles?limit=N&offset=0
public struct SspaiArticle: Equatable {
    public let id: Int
    public let title: String
    public let author: String
    /// 编辑推荐上首页的时间（nil 表示未推荐）
    public let recommendTime: Date?

    public init(id: Int, title: String, author: String, recommendTime: Date?) {
        self.id = id
        self.title = title
        self.author = author
        self.recommendTime = recommendTime
    }
}

public enum SspaiError: Error, LocalizedError {
    case unreachable
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unreachable: return "无法连接少数派，请检查网络。"
        case .invalidResponse: return "少数派返回了无法识别的内容。"
        }
    }
}

public enum SspaiClient {
    /// 拉取编辑推荐到首页的最新文章（按推荐时间倒序，取前 limit 篇）。
    /// 无推荐时回退到最新文章（保持卡片有内容）。
    public static func fetchLatestRecommended(limit: Int = 6,
                                              timeout: TimeInterval = 10) async throws -> [SspaiArticle] {
        // 多取一些再按推荐时间筛选，保证取够 limit 篇推荐
        let fetchCount = max(limit * 3, 20)
        guard let url = URL(string: "https://sspai.com/api/v1/articles?limit=\(fetchCount)&offset=0") else {
            throw SspaiError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw SspaiError.unreachable
        }
        return Array(try parseArticles(data).prefix(limit))
    }

    /// 解析文章接口返回体：优先编辑推荐（按推荐时间倒序），无推荐时按 id 倒序回退最新
    public static func parseArticles(_ data: Data) throws -> [SspaiArticle] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["list"] as? [[String: Any]] else {
            throw SspaiError.invalidResponse
        }

        var articles: [SspaiArticle] = []
        for item in list {
            guard let id = item["id"] as? Int,
                  let title = item["title"] as? String, !title.isEmpty else { continue }
            let author: String
            if let authorDict = item["author"] as? [String: Any],
               let nickname = authorDict["nickname"] as? String {
                author = nickname
            } else {
                author = (item["author"] as? String) ?? ""
            }
            let recommendTime: Date?
            if let ts = item["recommend_to_home_at"] as? Double, ts > 0 {
                recommendTime = Date(timeIntervalSince1970: ts)
            } else {
                recommendTime = nil
            }
            articles.append(SspaiArticle(id: id, title: title, author: author,
                                         recommendTime: recommendTime))
        }

        let recommended = articles
            .compactMap { article -> (SspaiArticle, Date)? in
                article.recommendTime.map { (article, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        if !recommended.isEmpty {
            return recommended
        }
        return articles.sorted { $0.id > $1.id }
    }
}
