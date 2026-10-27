import Foundation

/// Official read-only WeRead metadata. No API key is Codable or copied into a Pico snapshot.
/// 官方只读资料；授权密钥不参与序列化，也不进入设备快照。
public enum ReadPicoWeReadError: LocalizedError, Equatable, Sendable {
    case missingKey, invalidKey, authentication, rateLimited, upgradeRequired, malformed, tooLarge, transport, service
    case storage(String)
    public var errorDescription: String? {
        switch self {
        case .missingKey: return "请先保存微信读书官方 API Key。"
        case .invalidKey: return "API Key 格式无效，请从微信读书官方授权页面复制完整的 wrk- 密钥。"
        case .authentication: return "微信读书授权已失效，请重新获取并保存 API Key。"
        case .rateLimited: return "微信读书请求过于频繁，请稍后重试；已有离线资料仍保留。"
        case .upgradeRequired: return "微信读书接口要求更新兼容版本，已暂停同步；已有离线资料仍保留。"
        case .malformed: return "微信读书返回的数据不完整，未覆盖已有离线资料。"
        case .tooLarge: return "所选微信读书资料超过本版离线容量，请减少所选书籍或笔记后重试。"
        case .transport: return "暂时无法连接微信读书，请检查网络后重试。"
        case .service: return "微信读书暂时无法提供资料，请稍后重试。"
        case .storage(let text): return text
        }
    }
}

public enum ReadPicoWeReadBookKind: String, Codable, Sendable { case book, album, articles }
public struct ReadPicoWeReadBook: Codable, Equatable, Identifiable, Sendable {
    public let id: String, title: String, author: String
    public let kind: ReadPicoWeReadBookKind
    public let coverURL: URL?, readerURL: URL?
    public let isPrivate: Bool
    public init(id: String, title: String, author: String = "", kind: ReadPicoWeReadBookKind = .book,
                coverURL: URL? = nil, readerURL: URL? = nil, isPrivate: Bool = false) {
        self.id = id; self.title = title; self.author = author; self.kind = kind
        self.coverURL = coverURL; self.readerURL = readerURL; self.isPrivate = isPrivate
    }
}
public struct ReadPicoWeReadShelf: Equatable, Sendable {
    public let entries: [ReadPicoWeReadBook]
    public var books: [ReadPicoWeReadBook] { entries.filter { $0.kind == .book } }
    public var totalCount: Int { entries.count }
    public var albumCount: Int { entries.filter { $0.kind == .album }.count }
    public var hasArticles: Bool { entries.contains { $0.kind == .articles } }
}
public enum ReadPicoWeReadNoteKind: String, Codable, Sendable { case highlight, thought }
public struct ReadPicoWeReadNote: Codable, Equatable, Identifiable, Sendable {
    public let id: String, kind: ReadPicoWeReadNoteKind, chapter: String, quote: String, text: String
    public let createdAt: UInt64
    public init(id: String, kind: ReadPicoWeReadNoteKind, chapter: String = "", quote: String = "", text: String = "", createdAt: UInt64 = 0) {
        self.id = id; self.kind = kind; self.chapter = chapter; self.quote = quote; self.text = text; self.createdAt = createdAt
    }
}
public struct ReadPicoWeReadBookNotes: Codable, Equatable, Sendable {
    public let book: ReadPicoWeReadBook, notes: [ReadPicoWeReadNote]
    public init(book: ReadPicoWeReadBook, notes: [ReadPicoWeReadNote]) { self.book = book; self.notes = notes }
}
public struct ReadPicoWeReadSnapshot: Codable, Equatable, Sendable {
    public let createdAt: Date, books: [ReadPicoWeReadBookNotes]
    public init(createdAt: Date = Date(), books: [ReadPicoWeReadBookNotes]) { self.createdAt = createdAt; self.books = books }
    public var noteCount: Int { books.reduce(0) { $0 + $1.notes.count } }
}

/// One Mac account; keys stay in sealed local files except for an in-memory authenticated request.
/// Mac 账户密钥仅保存在本机加密凭据目录，请求时短暂读入内存；不读取浏览器 Cookie，不使用系统钥匙串。
public enum ReadPicoWeReadSecretStore {
    public static let authorizationURL = URL(string: "https://weread.qq.com/r/weread-skills")!
    private static let subdirectory = "weread-credentials"
    private static let account = "primary"
    public static func validated(_ key: String) throws -> String {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ReadPicoWeReadError.missingKey }
        guard value.hasPrefix("wrk-"), (8...512).contains(value.utf8.count),
              value.utf8.allSatisfy({ (33...126).contains($0) }) else { throw ReadPicoWeReadError.invalidKey }
        return value
    }
    public static func read() -> String {
        SealedCredentialStore.read(account: account, subdirectory: subdirectory)
    }
    public static func save(_ key: String) throws {
        let value = try validated(key)
        guard SealedCredentialStore.save(value, account: account, subdirectory: subdirectory) else {
            throw ReadPicoWeReadError.storage("无法保存微信读书授权，请检查本机磁盘权限后重试。")
        }
    }
    public static func remove() throws {
        guard SealedCredentialStore.save("", account: account, subdirectory: subdirectory) else {
            throw ReadPicoWeReadError.storage("无法移除微信读书授权，请稍后重试。")
        }
    }
}

private final class ReadPicoWeReadRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct ReadPicoWeReadClient: Sendable {
    public typealias Transport = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)
    public static let skillVersion = "1.0.5"
    public static let endpoint = URL(string: "https://i.weread.qq.com/api/agent/gateway")!
    private let key: String, transport: Transport
    public init(apiKey: String, transport: Transport? = nil) throws {
        self.key = try ReadPicoWeReadSecretStore.validated(apiKey)
        self.transport = transport ?? { request, limit in try await Self.perform(request, limit: limit) }
    }
    private static func perform(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 90
        let session = URLSession(configuration: config, delegate: ReadPicoWeReadRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ReadPicoWeReadError.transport }
        guard response.expectedContentLength <= Int64(limit) else { throw ReadPicoWeReadError.tooLarge }
        var data = Data(); data.reserveCapacity(min(limit, 65536))
        for try await byte in bytes {
            if data.count & 4095 == 0 { try Task.checkCancellation() }
            guard data.count < limit else { throw ReadPicoWeReadError.tooLarge }
            data.append(byte)
        }
        return (data, response)
    }
    private func request(_ name: String, parameters: [String: Any] = [:]) async throws -> [String: Any] {
        try Task.checkCancellation()
        var body = parameters; body["api_name"] = name; body["skill_version"] = Self.skillVersion
        var request = URLRequest(url: Self.endpoint); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        do {
            let (data, response) = try await transport(request, 4 * 1024 * 1024)
            try Task.checkCancellation()
            guard data.count <= 4 * 1024 * 1024 else { throw ReadPicoWeReadError.tooLarge }
            if response.statusCode == 401 || response.statusCode == 403 { throw ReadPicoWeReadError.authentication }
            if response.statusCode == 429 { throw ReadPicoWeReadError.rateLimited }
            guard response.statusCode == 200 else { throw ReadPicoWeReadError.service }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReadPicoWeReadError.malformed }
            let payload = json["data"] as? [String: Any] ?? json
            if json["upgrade_info"] != nil && !(json["upgrade_info"] is NSNull) || payload["upgrade_info"] != nil && !(payload["upgrade_info"] is NSNull) {
                throw ReadPicoWeReadError.upgradeRequired
            }
            if let code = json["errcode"], Self.integer(code) != 0 { throw ReadPicoWeReadError.service }
            return payload
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as ReadPicoWeReadError { throw error }
        catch { throw ReadPicoWeReadError.transport }
    }
    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            let double = value.doubleValue
            guard double.isFinite, double.rounded(.towardZero) == double, double >= Double(Int.min), double < Double(Int.max) else { return nil }
            return value.intValue
        }
        if let value = value as? String { return Int(value) }
        return nil
    }
    private static func text(_ value: Any?, max: Int = 256 * 1024) throws -> String {
        guard let value = value as? String, value.utf8.count <= max else { throw ReadPicoWeReadError.malformed }
        return value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    private static func optionalText(_ value: Any?, max: Int = 256 * 1024) throws -> String {
        if value == nil || value is NSNull { return "" }; return try text(value, max: max)
    }
    private static func link(_ value: Any?) -> URL? {
        guard let value = value as? String, value.utf8.count <= 2048, let url = URL(string: value),
              ["https", "weread"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
        return url
    }
    private static func array(_ value: Any?, optional: Bool = false) throws -> [[String: Any]] {
        if optional && (value == nil || value is NSNull) { return [] }
        guard let value = value as? [[String: Any]], value.count <= 10000 else { throw ReadPicoWeReadError.malformed }; return value
    }
    public func fetchShelf() async throws -> ReadPicoWeReadShelf {
        let data = try await request("/shelf/sync")
        guard data["books"] != nil || data["albums"] != nil else { throw ReadPicoWeReadError.malformed }
        var entries: [ReadPicoWeReadBook] = []
        var ids = Set<String>()
        for book in try Self.array(data["books"], optional: true) {
            let id = try Self.text(book["bookId"], max: 128), title = try Self.text(book["title"], max: 2048)
            guard !id.isEmpty, !title.isEmpty, ids.insert("book:" + id).inserted else { throw ReadPicoWeReadError.malformed }
            entries.append(.init(id: id, title: title, author: try Self.optionalText(book["author"], max: 2048),
                coverURL: Self.link(book["cover"]), readerURL: Self.link(book["readerLink"]) ?? Self.link(book["deepLink"]), isPrivate: Self.integer(book["secret"]) == 1))
        }
        for album in try Self.array(data["albums"], optional: true) {
            guard let info = album["albumInfo"] as? [String: Any] else { throw ReadPicoWeReadError.malformed }
            let id = try Self.text(info["albumId"], max: 128), title = try Self.text(info["name"], max: 2048)
            guard !id.isEmpty, !title.isEmpty, ids.insert("album:" + id).inserted else { throw ReadPicoWeReadError.malformed }
            entries.append(.init(id: id, title: title, author: try Self.optionalText(info["authorName"], max: 2048), kind: .album,
                coverURL: Self.link(info["cover"]), isPrivate: Self.integer((album["albumInfoExtra"] as? [String: Any])?["secret"]) == 1))
        }
        if let mp = data["mp"] as? [String: Any], !mp.isEmpty { entries.append(.init(id: "articles", title: "文章收藏", kind: .articles, isPrivate: true)) }
        return ReadPicoWeReadShelf(entries: entries)
    }
    public func fetchProgress(bookID: String) async throws -> Int {
        guard !bookID.isEmpty, bookID.utf8.count <= 128 else { throw ReadPicoWeReadError.malformed }
        let data = try await request("/book/getprogress", parameters: ["bookId": bookID])
        guard let book = data["book"] as? [String: Any], let value = Self.integer(book["progress"]), (0...100).contains(value) else { throw ReadPicoWeReadError.malformed }
        return value
    }
    public func fetchSnapshot(books: [ReadPicoWeReadBook], now: Date = Date(),
                              progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> ReadPicoWeReadSnapshot {
        guard books.count <= 64, Set(books.map(\.id)).count == books.count,
              books.allSatisfy({ $0.kind == .book && !$0.id.isEmpty && $0.id.utf8.count <= 128 }) else { throw ReadPicoWeReadError.tooLarge }
        var result: [ReadPicoWeReadBookNotes] = [], totalBytes = 0
        progress?(0, books.count)
        for book in books {
            try Task.checkCancellation()
            let notes = try await fetchNotes(bookID: book.id)
            totalBytes += notes.reduce(0) { $0 + $1.chapter.utf8.count + $1.quote.utf8.count + $1.text.utf8.count }
            guard totalBytes <= 32 * 1024 * 1024 else { throw ReadPicoWeReadError.tooLarge }
            result.append(.init(book: book, notes: notes)); progress?(result.count, books.count)
        }
        return ReadPicoWeReadSnapshot(createdAt: now, books: result)
    }
    public func fetchNotes(bookID: String) async throws -> [ReadPicoWeReadNote] {
        guard !bookID.isEmpty, bookID.utf8.count <= 128 else { throw ReadPicoWeReadError.malformed }
        let highlights = try await request("/book/bookmarklist", parameters: ["bookId": bookID])
        var chapters: [Int: String] = [:], result: [ReadPicoWeReadNote] = [], ids = Set<String>(), textBytes = 0
        for chapter in try Self.array(highlights["chapters"], optional: true) {
            if let uid = Self.integer(chapter["chapterUid"]) { chapters[uid] = try Self.optionalText(chapter["title"], max: 2048) }
        }
        for item in try Self.array(highlights["updated"]) {
            // Bookmarks are counts only; never turn type 0 positions into highlighted text.
            // 书签只作为统计，不能将 type 0 位置伪造为划线内容。
            guard Self.integer(item["type"]) == 1 else { continue }
            let id = try Self.text(item["bookmarkId"], max: 256), quote = try Self.text(item["markText"])
            guard !id.isEmpty, ids.insert("h:" + id).inserted else { throw ReadPicoWeReadError.malformed }
            let chapter = Self.integer(item["chapterUid"]).flatMap { chapters[$0] } ?? ""
            result.append(.init(id: "h:" + id, kind: .highlight, chapter: chapter, quote: quote, createdAt: UInt64(max(0, Self.integer(item["createTime"]) ?? 0))))
            textBytes += chapter.utf8.count + quote.utf8.count
            guard textBytes <= 8 * 1024 * 1024 else { throw ReadPicoWeReadError.tooLarge }
        }
        var cursor = 0, cursors = Set<Int>(), pages = 0
        while true {
            try Task.checkCancellation(); pages += 1
            guard pages <= 256 else { throw ReadPicoWeReadError.tooLarge }
            let data = try await request("/review/list/mine", parameters: ["bookid": bookID, "synckey": cursor, "count": 100])
            let reviews = try Self.array(data["reviews"])
            for item in reviews {
                guard let review = item["review"] as? [String: Any] else { throw ReadPicoWeReadError.malformed }
                let id = try Self.text(review["reviewId"], max: 256)
                guard !id.isEmpty, ids.insert("t:" + id).inserted else { throw ReadPicoWeReadError.malformed }
                let quote = try Self.optionalText(review["abstract"]), text = try Self.text(review["content"])
                let chapter = try Self.optionalText(review["chapterName"], max: 2048)
                textBytes += quote.utf8.count + text.utf8.count + chapter.utf8.count
                guard result.count < 10000, textBytes <= 8 * 1024 * 1024 else { throw ReadPicoWeReadError.tooLarge }
                result.append(.init(id: "t:" + id, kind: .thought, chapter: chapter, quote: quote, text: text, createdAt: UInt64(max(0, Self.integer(review["createTime"]) ?? 0))))
            }
            guard let more = Self.integer(data["hasMore"]), more == 0 || more == 1 else { throw ReadPicoWeReadError.malformed }
            if more == 0 { break }
            guard !reviews.isEmpty, let next = Self.integer(data["synckey"]), next != cursor, next >= 0, cursors.insert(next).inserted else { throw ReadPicoWeReadError.malformed }
            cursor = next
        }
        return result.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }
}
