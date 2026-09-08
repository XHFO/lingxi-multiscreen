import Foundation

public enum LyricsError: Error, LocalizedError {
    case invalidRequest
    case unavailable
    case noLyrics

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "当前歌曲信息不足，无法查询歌词。"
        case .unavailable: return "歌词服务暂时不可用。"
        case .noLyrics: return "暂未找到这首歌的歌词。"
        }
    }
}

public struct TimedLyricLine: Codable, Equatable {
    public var time: TimeInterval
    public var text: String

    public init(time: TimeInterval, text: String) {
        self.time = max(0, time)
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 一首歌的缓存歌词。优先使用同步歌词；只有纯文本时提供静态两行回退。
public struct LyricsTrack: Codable, Equatable {
    public var title: String
    public var artist: String
    public var timedLines: [TimedLyricLine]
    public var plainLines: [String]

    public init(title: String, artist: String,
                timedLines: [TimedLyricLine] = [], plainLines: [String] = []) {
        self.title = title
        self.artist = artist
        self.timedLines = timedLines.sorted { $0.time < $1.time }
        self.plainLines = plainLines.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    /// 当前行居中，同时给出前后各一行；用于灵犀 68 纵向屏幕的歌词区域。
    public func displayLines(at elapsed: TimeInterval) -> [String] {
        displayWindow(at: elapsed).lines
    }

    public func displayWindow(at elapsed: TimeInterval) -> LyricsDisplayWindow {
        guard !timedLines.isEmpty else {
            return LyricsDisplayWindow(lines: Array(plainLines.prefix(2)), currentIndex: 0)
        }
        let current = timedLines.lastIndex { $0.time <= elapsed + 0.08 } ?? 0
        let lower = max(0, current - 1)
        let upper = min(timedLines.count - 1, current + 1)
        return LyricsDisplayWindow(lines: Array(timedLines[lower...upper].map(\.text)),
                                   currentIndex: current - lower)
    }

    public func currentLineIndex(at elapsed: TimeInterval) -> Int? {
        guard !timedLines.isEmpty else { return nil }
        return timedLines.lastIndex { $0.time <= elapsed + 0.08 } ?? 0
    }
}

public struct LyricsDisplayWindow: Equatable {
    public var lines: [String]
    public var currentIndex: Int

    public init(lines: [String], currentIndex: Int) {
        self.lines = lines
        self.currentIndex = min(max(currentIndex, 0), max(lines.count - 1, 0))
    }
}

/// 歌词联动的本地时间轴策略。独立于设备和网络刷新周期，仅在即将跨入
/// 新歌词行时触发实际渲染与上传。
public enum LyricsTimelinePolicy {
    /// 轻量行号检查频率；未换行时不会重绘或上传。
    public static let checkInterval: TimeInterval = 0.25
    /// 抵消 JPEG 渲染、网络上传和键盘换帧造成的可见延迟。
    public static let presentationLead: TimeInterval = 0.30

    public static func displayElapsed(for info: NowPlayingInfo,
                                      at now: Date = Date()) -> TimeInterval {
        var elapsed = max(info.elapsedTime, 0)
        if info.isPlaying {
            elapsed += max(now.timeIntervalSince(info.sampledAt), 0)
            elapsed += presentationLead
        }
        if info.duration > 0 {
            elapsed = min(elapsed, info.duration)
        }
        return elapsed
    }
}

/// 无需 API Key 的 LRCLIB 歌词查询。只在用户建立歌词联动后按换歌请求，
/// 不轮询歌词服务；播放进度与逐行切换均在本机完成。
public final class LyricsClient {
    private struct Record: Decodable {
        var trackName: String?
        var artistName: String?
        var syncedLyrics: String?
        var plainLyrics: String?
        var duration: Double?
    }

    public init() {}

    public func fetch(for info: NowPlayingInfo, timeout: TimeInterval = 8) async throws -> LyricsTrack {
        let title = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = info.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != "未在播放" else { throw LyricsError.invalidRequest }

        if let exact = try? await fetchExact(title: title, artist: artist,
                                             album: info.album, duration: info.duration,
                                             timeout: timeout),
           let track = Self.track(from: exact, fallbackTitle: title, fallbackArtist: artist) {
            return track
        }
        let results = try await search(title: title, artist: artist, timeout: timeout)
        let best = results.min { lhs, rhs in
            Self.score(lhs, info: info) < Self.score(rhs, info: info)
        }
        guard let best,
              let track = Self.track(from: best, fallbackTitle: title, fallbackArtist: artist) else {
            throw LyricsError.noLyrics
        }
        return track
    }

    private func fetchExact(title: String, artist: String, album: String,
                            duration: TimeInterval, timeout: TimeInterval) async throws -> Record {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        components?.queryItems = items
        return try await request(components?.url, timeout: timeout)
    }

    private func search(title: String, artist: String, timeout: TimeInterval) async throws -> [Record] {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        var items = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        components?.queryItems = items
        return try await request(components?.url, timeout: timeout)
    }

    private func request<T: Decodable>(_ url: URL?, timeout: TimeInterval) async throws -> T {
        guard let url else { throw LyricsError.invalidRequest }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("LinxMultiScreen/1.5.4 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { throw LyricsError.unavailable }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func score(_ record: Record, info: NowPlayingInfo) -> Double {
        var score = 0.0
        if let duration = record.duration, info.duration > 0 {
            score += abs(duration - info.duration)
        }
        if record.trackName?.localizedCaseInsensitiveCompare(info.title) != .orderedSame { score += 20 }
        if !info.artist.isEmpty,
           record.artistName?.localizedCaseInsensitiveCompare(info.artist) != .orderedSame { score += 10 }
        if record.syncedLyrics?.isEmpty != false { score += 5 }
        return score
    }

    private static func track(from record: Record, fallbackTitle: String,
                              fallbackArtist: String) -> LyricsTrack? {
        let synced = parseLRC(record.syncedLyrics ?? "")
        let plain = (record.plainLyrics ?? "").components(separatedBy: .newlines)
        guard !synced.isEmpty || plain.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        return LyricsTrack(title: record.trackName ?? fallbackTitle,
                           artist: record.artistName ?? fallbackArtist,
                           timedLines: synced, plainLines: plain)
    }

    public static func parseLRC(_ text: String) -> [TimedLyricLine] {
        let pattern = #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [TimedLyricLine] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = regex.matches(in: rawLine, range: range)
            guard !matches.isEmpty else { continue }
            let lyric = regex.stringByReplacingMatches(in: rawLine, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lyric.isEmpty else { continue }
            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: rawLine),
                      let secondRange = Range(match.range(at: 2), in: rawLine),
                      let minutes = Double(rawLine[minuteRange]),
                      let seconds = Double(rawLine[secondRange]) else { continue }
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound,
                   let fractionRange = Range(match.range(at: 3), in: rawLine) {
                    let digits = String(rawLine[fractionRange])
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                result.append(TimedLyricLine(time: minutes * 60 + seconds + fraction, text: lyric))
            }
        }
        return result.sorted { $0.time < $1.time }
    }
}
