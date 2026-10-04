import Darwin
import Foundation

public enum NowPlayingError: Error, LocalizedError {
    case frameworkUnavailable
    case timeout
    case notPlaying
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            return "无法读取系统播放器状态（MediaRemote 不可用）。"
        case .timeout:
            return "读取播放器状态超时。"
        case .notPlaying:
            return "当前没有正在播放的媒体。"
        case .invalidResponse:
            return "系统播放器返回了无法识别的数据。"
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

    /// 以 MediaRemote 的位置和采样时刻为唯一时钟锚点。倍速播放时必须按实际
    /// playbackRate 推进，否则歌词在 0.5x / 1.5x 等速度下会持续漂移。
    public func effectiveElapsed(at date: Date = Date()) -> TimeInterval {
        var value = max(elapsedTime, 0)
        if isPlaying {
            value += max(date.timeIntervalSince(sampledAt), 0) * max(playbackRate, 0)
        }
        if duration > 0 { value = min(value, duration) }
        return value
    }

    /// 把当前推算位置重新锚定到指定时间，供低频 MediaRemote 查询之间本地推进。
    public func anchored(at date: Date = Date()) -> NowPlayingInfo {
        var result = self
        result.elapsedTime = effectiveElapsed(at: date)
        result.sampledAt = date
        return result
    }

    public var progress: Double {
        duration > 0 ? min(max(elapsedTime / duration, 0), 1) : 0
    }

    /// 无媒体播放时的占位状态
    public static let placeholder = NowPlayingInfo(title: "未在播放", artist: "", album: "",
                                                   duration: 0, elapsedTime: 0, playbackRate: 0,
                                                   artwork: nil, appName: nil)

    /// 合并新拉的播放状态与本地推进值：同一首歌且正在播放时，
    /// 若拉取到的 elapsedTime 落后于本地值（MediaRemote 可能停滞），
    /// 保留本地较大值，避免进度条周期性回跳；换曲/暂停/时长变化则采用新值。
    public func mergedWithProgressed(current: NowPlayingInfo) -> NowPlayingInfo {
        var incoming = preservingArtwork(from: current)
        guard incoming.title == current.title,
              abs(incoming.duration - current.duration) < 0.5,
              current.isPlaying,
              incoming.elapsedTime < current.elapsedTime else {
            return incoming
        }
        incoming.elapsedTime = current.elapsedTime
        return incoming
    }

    /// 合并远端采样和本地时钟，同时区分“MediaRemote 返回同一旧值”与用户 seek。
    /// 旧值继续沿用本地时钟；明显的前跳或后跳则立即采用新位置。
    public func reconciledWithProgressed(current: NowPlayingInfo,
                                         previousRemote: NowPlayingInfo?,
                                         seekThreshold: TimeInterval = 1.5) ->
        (info: NowPlayingInfo, didSeek: Bool) {
        let incoming = preservingArtwork(from: current)
        guard incoming.title == current.title,
              incoming.artist == current.artist,
              abs(incoming.duration - current.duration) < 0.5,
              current.isPlaying,
              incoming.isPlaying else {
            return (incoming, false)
        }

        let predicted = current.effectiveElapsed(at: incoming.sampledAt)
        let offset = incoming.elapsedTime - predicted
        guard abs(offset) > seekThreshold else { return (incoming, false) }
        if offset > 0 { return (incoming, true) }

        if let previousRemote,
           previousRemote.title == incoming.title,
           previousRemote.artist == incoming.artist,
           abs(previousRemote.duration - incoming.duration) < 0.5 {
            let remoteDelta = incoming.elapsedTime - previousRemote.elapsedTime
            if remoteDelta < -seekThreshold { return (incoming, true) }
            if abs(remoteDelta) < 0.35 {
                var anchored = current.anchored(at: incoming.sampledAt)
                if anchored.artwork == nil { anchored.artwork = incoming.artwork }
                return (anchored, false)
            }
        }
        return (incoming, true)
    }

    /// MediaRemote 偶尔会在同一首歌的后续取样里暂时漏掉封面。此时保留已经
    /// 成功取得的封面；只有完整媒体身份一致才继承，避免换歌时沿用上一首图片。
    private func preservingArtwork(from current: NowPlayingInfo) -> NowPlayingInfo {
        guard artwork == nil,
              current.artwork != nil,
              title == current.title,
              artist == current.artist,
              album == current.album,
              abs(duration - current.duration) < 0.5 else { return self }
        var result = self
        result.artwork = current.artwork
        return result
    }
}

/// 同一个读取客户端的并发请求共享一次取样，避免定时器、播放器通知与手动刷新
/// 同时启动多个 Swift 解释器。仅合并正在执行的请求，不缓存已完成的媒体状态。
public actor NowPlayingRequestCoordinator {
    private struct Request {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<NowPlayingInfo, Error>]
    }
    private var pending: Request?

    public init() {}

    public func fetch(_ operation: @escaping () async throws -> NowPlayingInfo) async throws -> NowPlayingInfo {
        try Task.checkCancellation()
        let waiterID = UUID()
        let value: NowPlayingInfo = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if pending != nil {
                    pending?.waiters[waiterID] = continuation
                    return
                }
                let requestID = UUID()
                let task = Task {
                    let result: Result<NowPlayingInfo, Error>
                    do { result = .success(try await operation()) }
                    catch { result = .failure(error) }
                    self.complete(requestID, with: result)
                }
                pending = Request(id: requestID, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
        try Task.checkCancellation()
        return value
    }

    private func complete(_ id: UUID, with result: Result<NowPlayingInfo, Error>) {
        guard let request = pending, request.id == id else { return }
        pending = nil
        for waiter in request.waiters.values { waiter.resume(with: result) }
    }

    private func cancel(_ waiterID: UUID) {
        guard let waiter = pending?.waiters.removeValue(forKey: waiterID) else { return }
        if pending?.waiters.isEmpty == true {
            let task = pending?.task
            pending = nil
            task?.cancel()
        }
        waiter.resume(throwing: CancellationError())
    }
}

/// 首次事件短暂合并，连续事件限频；取样中的新事件只保留一次尾随刷新。
public struct NowPlayingEventRefreshThrottle {
    public static let minimumInterval: TimeInterval = 1
    public static let debounceInterval: TimeInterval = 0.09
    public private(set) var hasPendingRefresh = false
    private var lastStartedAt: Date?

    public init() {}

    public mutating func notify(hasDemand: Bool) { hasPendingRefresh = hasDemand }

    public func delay(at now: Date) -> TimeInterval {
        let remaining = lastStartedAt.map { Self.minimumInterval - now.timeIntervalSince($0) } ?? 0
        return max(Self.debounceInterval, remaining)
    }

    @discardableResult
    public mutating func beginRefresh(at now: Date, hasDemand: Bool) -> Bool {
        guard hasDemand else { hasPendingRefresh = false; return false }
        guard hasPendingRefresh,
              lastStartedAt.map({ now.timeIntervalSince($0) >= Self.minimumInterval }) ?? true else { return false }
        hasPendingRefresh = false
        lastStartedAt = now
        return true
    }
}

/// 歌词上传使用目标键盘自己的独立连接/布局快照；活动键盘切换不会改变它。
public struct NowPlayingKeyboardRenderTarget {
    public let deviceID: UUID
    public let endpoint: String
    public let renderSettings: AppSettings

    public init?(deviceID: UUID, source: AppSettings) {
        guard let device = source.devices.first(where: {
            $0.id == deviceID && $0.type == .keyboard && $0.isEnabled
        }) else { return nil }
        let snapshot = source.activeDeviceID(for: .keyboard) == deviceID
            ? DeviceSettings.capture(from: source, type: .keyboard) : device.settings
        guard snapshot.displayMode == .nowPlaying,
              let endpoint = snapshot.endpoint,
              !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let settings = AppSettings()
        settings.softwareIsDark = source.softwareIsDark
        settings.cardRenderingMode = source.cardRenderingMode
        settings.backgroundTone = source.backgroundTone
        settings.customBackgroundHex = source.customBackgroundHex
        settings.accentTone = source.accentTone
        settings.customAccentHex = source.customAccentHex
        settings.timeFormat = source.timeFormat
        settings.dateFormat = source.dateFormat
        snapshot.apply(to: settings, type: .keyboard)
        self.deviceID = deviceID
        self.endpoint = endpoint
        renderSettings = settings
    }

    public func isValid(in source: AppSettings) -> Bool {
        guard let device = source.devices.first(where: {
            $0.id == deviceID && $0.type == .keyboard && $0.isEnabled
        }) else { return false }
        if source.activeDeviceID(for: .keyboard) == deviceID {
            return source.displayMode == .nowPlaying && source.endpoint == endpoint
        }
        return device.settings.displayMode == .nowPlaying && device.settings.endpoint == endpoint
    }

    public func ownsActivePreview(in source: AppSettings) -> Bool {
        source.activeDeviceID(for: .keyboard) == deviceID && isValid(in: source)
    }
}

/// Callback、超时和取消只允许其中一个完成 continuation；回调晚到时不会重复恢复。
private final class NowPlayingContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// 通过系统私有框架 MediaRemote 读取「正在播放」信息。
/// 键名为框架标准字面量（kMRMediaRemoteNowPlayingInfo*），
/// 采用 dlsym 动态加载，避免直接链接私有框架。
public final class NowPlayingClient {
    private let requests = NowPlayingRequestCoordinator()

    private typealias GetNowPlayingInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias RegisterForNotifications = @convention(c) (DispatchQueue) -> Void

    private static let getNowPlayingInfo: GetNowPlayingInfo? = {
        guard let handle = dlopen(NowPlayingClient.frameworkPath, RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { return nil }
        return unsafeBitCast(symbol, to: GetNowPlayingInfo.self)
    }()

    private static let registerForNotifications: RegisterForNotifications? = {
        guard let handle = dlopen(NowPlayingClient.frameworkPath, RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") else {
            return nil
        }
        return unsafeBitCast(symbol, to: RegisterForNotifications.self)
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
        public static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
    }

    /// 兼容不同 macOS / 播放器返回的封面字段。标准字段优先；若系统换用了
    /// 其他包含 Artwork 的 Data 字段，则选择最大的有效候选，避开摘要字节。
    public static func artworkData(in dict: [String: Any]) -> Data? {
        if let exact = dict[Keys.artworkData] as? Data, exact.count > 128 {
            return exact
        }
        return dict.compactMap { key, value -> Data? in
            guard key.localizedCaseInsensitiveContains("artwork"),
                  let data = value as? Data,
                  data.count > 128 else { return nil }
            return data
        }.max { $0.count < $1.count }
    }

    /// MediaRemote 的变化通知用于立即捕获换歌、暂停/继续和拖动进度。若当前系统
    /// 不提供注册符号，调用会安全退化为现有的定时校准。
    public static let changeNotifications: [Notification.Name] = [
        Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
        Notification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
        Notification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification")
    ]

    /// 播放器自身的分布式通知补充 MediaRemote；只作为重新读取系统状态的信号，
    /// 不相信通知负载中的歌曲/进度，以免不同来源争抢歌词时间锚点。
    public static let playerChangeNotifications: [Notification.Name] = [
        Notification.Name("com.apple.Music.playerInfo"),
        Notification.Name("com.spotify.client.PlaybackStateChanged")
    ]

    public func registerForChangeNotifications() {
        Self.registerForNotifications?(DispatchQueue.main)
    }

    public init() {}

    /// 拉取「正在播放」。
    /// 注意：本系统（macOS 26）上编译后的二进制直接调用 MediaRemote 会返回 nil
    /// （仅有解释器 JIT 模式能拿到数据），因此优先通过 `swift` 解释器子进程读取，
    /// 子进程不可用时回退为直接调用。
    public func fetch(timeout: TimeInterval = 10) async throws -> NowPlayingInfo {
        try Task.checkCancellation()
        let result = try await requests.fetch {
            try await self.fetchUnshared(timeout: timeout)
        }
        try Task.checkCancellation()
        return result
    }

    private func fetchUnshared(timeout: TimeInterval) async throws -> NowPlayingInfo {
        do {
            return try await fetchViaSubprocess(timeout: timeout)
        } catch NowPlayingError.notPlaying {
            throw NowPlayingError.notPlaying
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
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
        // JSON 已写入结果文件；不用无人读取的管道，避免解释器诊断输出堵塞子进程。
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completion = NowPlayingContinuation<Void>()
        process.terminationHandler = { _ in completion.finish(.success(())) }
        try Task.checkCancellation()
        try process.run()

        // 进程回调完成等待，不占用协作线程池；最后一个调用者取消时立即结束探测。
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { completion.install($0) }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                    completion.finish(.failure(NowPlayingError.timeout))
                    if process.isRunning { process.terminate() }
                    throw NowPlayingError.timeout
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw NowPlayingError.invalidResponse }
        let output = (try? Data(contentsOf: outFile)) ?? Data()
        return try Self.parseProbeOutput(output)
    }

    /// 解析解释器 probe 的回传数据。只有结构合法且明确声明
    /// `playing == false` 时才表示未在播放；空输出、损坏 JSON 或缺少字段
    /// 都是 probe 故障，上层应回退到直接 MediaRemote 读取。
    public static func parseProbeOutput(_ output: Data) throws -> NowPlayingInfo {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: output)
        } catch {
            throw NowPlayingError.invalidResponse
        }
        guard let json = value as? [String: Any],
              let playingNumber = json["playing"] as? NSNumber,
              CFGetTypeID(playingNumber) == CFBooleanGetTypeID() else {
            throw NowPlayingError.invalidResponse
        }
        let playing = playingNumber.boolValue
        guard playing else { throw NowPlayingError.notPlaying }
        guard let title = json["title"] as? String, !title.isEmpty else {
            throw NowPlayingError.invalidResponse
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
            sampledAt: (json["sampledAt"] as? Double)
                .map(Date.init(timeIntervalSince1970:)) ?? Date()
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

    var output = "{\\"playing\\":false}"

    func artworkData(in dict: [String: Any]) -> Data? {
        if let exact = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
           exact.count > 128 { return exact }
        return dict.compactMap { key, value -> Data? in
            guard key.localizedCaseInsensitiveContains("artwork"),
                  let data = value as? Data,
                  data.count > 128 else { return nil }
            return data
        }.max { $0.count < $1.count }
    }

    // MediaRemote 冷启动时常先返回标题，封面会晚约一两百毫秒就绪。
    // 在同一个解释器进程内短暂复查，避免每次都在封面准备好前退出。
    var bestDict: [String: Any]?
    for attempt in 0..<3 {
        let sema = DispatchSemaphore(value: 0)
        var callbackDict: [String: Any]?
        get(DispatchQueue.global(qos: .userInitiated)) { info in
            callbackDict = info as? [String: Any]
            sema.signal()
        }
        guard sema.wait(timeout: .now() + 1.0) == .success else { continue }
        if let dict = callbackDict,
           let title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String,
           !title.isEmpty {
            bestDict = dict
            if artworkData(in: dict) != nil { break }
        }
        if attempt < 2 { Thread.sleep(forTimeInterval: 0.18) }
    }

    if let dict = bestDict,
       let title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String,
       !title.isEmpty {
        let artwork = artworkData(in: dict)
        let callbackAt = Date()
        let callbackEpoch = callbackAt.timeIntervalSince1970
        var sampledEpoch = callbackEpoch
        if let timestamp = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
            let candidate = timestamp.timeIntervalSince1970
            if abs(candidate - callbackEpoch) < 86400 { sampledEpoch = candidate }
        } else if let timestamp = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? NSNumber {
            let raw = timestamp.doubleValue
            let candidate = raw > 1000000000
                ? raw : Date(timeIntervalSinceReferenceDate: raw).timeIntervalSince1970
            if abs(candidate - callbackEpoch) < 86400 { sampledEpoch = candidate }
        }
        let obj: [String: Any] = [
            "playing": true,
            "title": title,
            "artist": dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",
            "album": dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "",
            "duration": dict["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0,
            "elapsedTime": dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0,
            "playbackRate": dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0,
            "artwork": artwork?.base64EncodedString() ?? "",
            // 优先使用播放器提供的进度锚点。仅在播放器没有提供 timestamp 时才用
            // 回调时刻，避免把媒体端已经滞后的 elapsedTime 当成“此刻”的进度。
            "sampledAt": sampledEpoch
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let text = String(data: data, encoding: .utf8) {
            output = text
        }
    }
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
        let completion = NowPlayingContinuation<NowPlayingInfo>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let queue = DispatchQueue.global(qos: .userInitiated)
                get(queue) { info in
                    guard let dict = info as? [String: Any],
                          let title = dict[Self.Keys.title] as? String,
                          !title.isEmpty else {
                        completion.finish(.failure(NowPlayingError.notPlaying))
                        return
                    }
                    completion.finish(.success(NowPlayingInfo(
                        title: title,
                        artist: dict[Self.Keys.artist] as? String ?? "",
                        album: dict[Self.Keys.album] as? String ?? "",
                        duration: (dict[Self.Keys.duration] as? Double) ?? 0,
                        elapsedTime: (dict[Self.Keys.elapsedTime] as? Double) ?? 0,
                        playbackRate: (dict[Self.Keys.playbackRate] as? Double) ?? 0,
                        artwork: Self.artworkData(in: dict),
                        appName: nil,
                        sampledAt: Self.playbackSampleDate(
                            dict[Self.Keys.timestamp], fallback: Date())
                    )))
                }
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
        }
    }

    private static func playbackSampleDate(_ value: Any?, fallback: Date) -> Date {
        let candidate: Date?
        if let date = value as? Date {
            candidate = date
        } else if let number = value as? NSNumber {
            let raw = number.doubleValue
            candidate = raw > 1_000_000_000
                ? Date(timeIntervalSince1970: raw)
                : Date(timeIntervalSinceReferenceDate: raw)
        } else {
            candidate = nil
        }
        guard let candidate,
              abs(candidate.timeIntervalSince(fallback)) < 86_400 else { return fallback }
        return candidate
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
            artwork: artworkData(in: dict),
            sampledAt: sampledAt
        )
    }

}
