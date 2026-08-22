import Darwin
import Foundation

public enum NowPlayingError: Error, LocalizedError {
    case frameworkUnavailable
    case timeout
    case notPlaying

    public var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            return "无法读取系统播放器状态（MediaRemote 不可用）。"
        case .timeout:
            return "读取播放器状态超时。"
        case .notPlaying:
            return "当前没有正在播放的媒体。"
        }
    }
}

/// 系统「正在播放」信息：标题、艺术家、时长、进度、播放/暂停状态与封面。
public struct NowPlayingInfo: Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var elapsedTime: TimeInterval
    public var playbackRate: Double
    public var artwork: Data?
    public var appName: String?
    public var sampledAt: Date

    public init(title: String, artist: String = "", album: String = "",
                duration: TimeInterval = 0, elapsedTime: TimeInterval = 0,
                playbackRate: Double = 1, artwork: Data? = nil,
                appName: String? = nil, sampledAt: Date = Date()) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsedTime = elapsedTime
        self.playbackRate = playbackRate
        self.artwork = artwork
        self.appName = appName
        self.sampledAt = sampledAt
    }

    /// 是否处于播放状态（播放速率 > 0 视为播放中）
    public var isPlaying: Bool { playbackRate > 0.01 }

    public var progress: Double {
        duration > 0 ? min(max(elapsedTime / duration, 0), 1) : 0
    }

    /// 无媒体播放时的占位状态
    public static let placeholder = NowPlayingInfo(title: "未在播放", artist: "", album: "",
                                                   duration: 0, elapsedTime: 0, playbackRate: 0,
                                                   artwork: nil, appName: nil)

    /// 示例数据（无封面时为占位样式）
    public static let sample = NowPlayingInfo(
        title: "示例歌曲", artist: "示例歌手", album: "示例专辑",
        duration: 210, elapsedTime: 63, playbackRate: 1, artwork: nil, sampledAt: Date())

    /// 合并新拉的播放状态与本地推进值：同一首歌且正在播放时，
    /// 若拉取到的 elapsedTime 落后于本地值（MediaRemote 可能停滞），
    /// 保留本地较大值，避免进度条周期性回跳；换曲/暂停/时长变化则采用新值。
    public func mergedWithProgressed(current: NowPlayingInfo) -> NowPlayingInfo {
        guard title == current.title,
              abs(duration - current.duration) < 0.5,
              current.isPlaying,
              elapsedTime < current.elapsedTime else {
            return self
        }
        var merged = self
        merged.elapsedTime = current.elapsedTime
        return merged
    }
}

/// 通过系统私有框架 MediaRemote 读取「正在播放」信息。
/// 键名为框架标准字面量（kMRMediaRemoteNowPlayingInfo*），
/// 采用 dlsym 动态加载，避免直接链接私有框架。
public final class NowPlayingClient {

    private typealias GetNowPlayingInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void

    private static let getNowPlayingInfo: GetNowPlayingInfo? = {
        guard let handle = dlopen(NowPlayingClient.frameworkPath, RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { return nil }
        return unsafeBitCast(symbol, to: GetNowPlayingInfo.self)
    }()

    private static let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

    // MARK: - 键名（MediaRemote 标准字面量）

    public enum Keys {
        public static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        public static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        public static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        public static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
        public static let elapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        public static let playbackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        public static let artworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
    }

    public init() {}

    /// 拉取「正在播放」。
    /// 注意：本系统（macOS 26）上编译后的二进制直接调用 MediaRemote 会返回 nil
    /// （仅有解释器 JIT 模式能拿到数据），因此优先通过 `swift` 解释器子进程读取，
    /// 子进程不可用时回退为直接调用。
    public func fetch(timeout: TimeInterval = 10) async throws -> NowPlayingInfo {
        do {
            return try await fetchViaSubprocess(timeout: timeout)
        } catch NowPlayingError.notPlaying {
            throw NowPlayingError.notPlaying
        } catch {
            guard let get = Self.getNowPlayingInfo else {
                throw NowPlayingError.frameworkUnavailable
            }
            return try await fetchDirect(get: get, timeout: timeout)
        }
    }

    // MARK: - 子进程方式（解释器 JIT 可读取；结果经临时文件回传，避开 stdout 管道缓冲死锁）

    private func fetchViaSubprocess(timeout: TimeInterval) async throws -> NowPlayingInfo {
        let swiftPath = "/usr/bin/swift"
        guard FileManager.default.isExecutableFile(atPath: swiftPath) else {
            throw NowPlayingError.frameworkUnavailable
        }
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("linx-np-probe-\(UUID().uuidString).swift")
        try Self.probeScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        // 结果输出文件：子进程把 JSON 写入此文件，app 在子进程退出后读取
        let outFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("linx-np-out-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: swiftPath)
        process.arguments = [scriptURL.path]
        var env = ProcessInfo.processInfo.environment
        env["LINX_NP_OUT"] = outFile.path
        process.environment = env
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        // 等待子进程退出（带超时），随后读结果文件
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { process.waitUntilExit() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                process.terminate()
                throw NowPlayingError.timeout
            }
            _ = try await group.next()
            group.cancelAll()
        }
        let output = (try? Data(contentsOf: outFile)) ?? Data()

        guard let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let playing = json["playing"] as? Bool, playing,
              let title = json["title"] as? String, !title.isEmpty else {
            throw NowPlayingError.notPlaying
        }
        return NowPlayingInfo(
            title: title,
            artist: json["artist"] as? String ?? "",
            album: json["album"] as? String ?? "",
            duration: (json["duration"] as? Double) ?? 0,
            elapsedTime: (json["elapsedTime"] as? Double) ?? 0,
            playbackRate: (json["playbackRate"] as? Double) ?? 0,
            artwork: (json["artwork"] as? String).flatMap { Data(base64Encoded: $0) },
            appName: nil,
            sampledAt: Date()
        )
    }

    /// 解释器子进程脚本：dlopen MediaRemote 读取正在播放并输出 JSON
    private static let probeScript = """
    import Foundation
    import Darwin

    typealias GetInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
          let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { exit(2) }
    let get = unsafeBitCast(sym, to: GetInfo.self)

    let sema = DispatchSemaphore(value: 0)
    var output = "{\\"playing\\":false}"
    get(DispatchQueue.global(qos: .userInitiated)) { info in
        defer { sema.signal() }
        guard let dict = info as? [String: Any] else { return }
        guard let title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else { return }
        let artworkData = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        let obj: [String: Any] = [
            "playing": true,
            "title": title,
            "artist": dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",
            "album": dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "",
            "duration": dict["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0,
            "elapsedTime": dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0,
            "playbackRate": dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0,
            "artwork": artworkData?.base64EncodedString() ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let text = String(data: data, encoding: .utf8) {
            output = text
        }
    }
    _ = sema.wait(timeout: .now() + 4)
    if let outPath = ProcessInfo.processInfo.environment["LINX_NP_OUT"] {
        try? output.write(toFile: outPath, atomically: true, encoding: .utf8)
    }
    """

    // MARK: - 直接调用方式（回退）

    private func fetchDirect(get: GetNowPlayingInfo, timeout: TimeInterval) async throws -> NowPlayingInfo {
        try await withThrowingTaskGroup(of: NowPlayingInfo.self) { group in
            group.addTask {
                try await self.fetchInternal(get: get)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NowPlayingError.timeout
            }
            let first = try await group.next()
            group.cancelAll()
            guard let value = first else { throw NowPlayingError.timeout }
            return value
        }
    }

    private func fetchInternal(get: GetNowPlayingInfo) async throws -> NowPlayingInfo {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue.global(qos: .userInitiated)
            get(queue) { info in
                guard let dict = info as? [String: Any],
                      let title = dict[Self.Keys.title] as? String,
                      !title.isEmpty else {
                    continuation.resume(throwing: NowPlayingError.notPlaying)
                    return
                }
                continuation.resume(returning: NowPlayingInfo(
                    title: title,
                    artist: dict[Self.Keys.artist] as? String ?? "",
                    album: dict[Self.Keys.album] as? String ?? "",
                    duration: (dict[Self.Keys.duration] as? Double) ?? 0,
                    elapsedTime: (dict[Self.Keys.elapsedTime] as? Double) ?? 0,
                    playbackRate: (dict[Self.Keys.playbackRate] as? Double) ?? 0,
                    artwork: dict[Self.Keys.artworkData] as? Data,
                    appName: nil,
                    sampledAt: Date()
                ))
            }
        }
    }

    /// 解析用（供测试构造数据）
    public static func parseInfo(_ dict: [String: Any], sampledAt: Date = Date()) -> NowPlayingInfo? {
        guard let title = dict[Keys.title] as? String, !title.isEmpty else { return nil }
        return NowPlayingInfo(
            title: title,
            artist: dict[Keys.artist] as? String ?? "",
            album: dict[Keys.album] as? String ?? "",
            duration: (dict[Keys.duration] as? Double) ?? 0,
            elapsedTime: (dict[Keys.elapsedTime] as? Double) ?? 0,
            playbackRate: (dict[Keys.playbackRate] as? Double) ?? 0,
            artwork: dict[Keys.artworkData] as? Data,
            sampledAt: sampledAt
        )
    }

}
