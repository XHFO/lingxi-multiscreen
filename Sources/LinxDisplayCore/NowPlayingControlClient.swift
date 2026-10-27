import Darwin
import Foundation

/// Explicit MediaRemote commands. Play/pause deliberately avoid a toggle command:
/// a delayed response must not invert the user's requested state on a retry.
/// Values follow MediaRemote.h's MRMediaRemoteCommand enum (play=0, pause=1,
/// next=4, previous=5); these are not the USB HID consumer-control usages.
/// Header references: https://github.com/theos/headers/blob/master/MediaRemote/MediaRemote.h
/// and https://github.com/kirtan-shah/nowplaying-cli/blob/main/src/mediaremote-mini/private/MediaRemote.h
public enum NowPlayingControlCommand: Int32, CaseIterable, Sendable {
    case play = 0
    case pause = 1
    case nextTrack = 4
    case previousTrack = 5
}

/// MediaRemote accepted delivery. This does not assert that a player executed it;
/// callers must read a fresh system sample before changing the displayed state.
public enum NowPlayingControlReceipt: Equatable, Sendable {
    case accepted
}

public enum NowPlayingControlError: Error, LocalizedError, Equatable {
    case noMedia
    case unsupported
    case rejected
    case transportUnavailable
    case invalidTimeout
    case timeoutOutcomeUnknown
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .noMedia: return String(localized: "当前没有可控制的媒体。")
        case .unsupported: return String(localized: "当前系统不支持媒体控制。")
        case .rejected: return String(localized: "系统播放器未接受这项操作，当前播放器可能不支持。")
        case .transportUnavailable: return String(localized: "无法启动系统媒体控制。")
        case .invalidTimeout: return String(localized: "媒体控制的等待时间无效。")
        case .timeoutOutcomeUnknown: return String(localized: "媒体控制等待超时，操作是否生效尚未确认。")
        case .invalidResponse: return String(localized: "未能确认系统是否已接受媒体操作。")
        }
    }
}

/// Injectable command transport. Tests use this seam without controlling the
/// user's player. A transport sends once and must never retry after an ambiguous
/// failure, timeout, or cancellation, especially for next/previous commands.
public struct NowPlayingControlTransport {
    public var send: (NowPlayingControlCommand, TimeInterval) async throws -> NowPlayingControlReceipt

    public init(send: @escaping (NowPlayingControlCommand, TimeInterval) async throws -> NowPlayingControlReceipt) {
        self.send = send
    }

    public static var system: Self {
        Self { command, timeout in
            try await NowPlayingControlSubprocess.send(command, timeout: timeout)
        }
    }
}

/// Sends only an explicit user command. This class does not poll, launch players,
/// synthesize key presses, mutate NowPlayingInfo, or fall back to a second sender.
public final class NowPlayingControlClient {
    private let transport: NowPlayingControlTransport

    public init(transport: NowPlayingControlTransport = .system) {
        self.transport = transport
    }

    /// A paused track remains controllable. The placeholder and empty metadata do
    /// not: their zero playbackRate is not evidence of a real paused session.
    public static func canControl(_ current: NowPlayingInfo) -> Bool {
        let title = current.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        guard title == NowPlayingInfo.placeholder.title else { return true }
        return !current.artist.isEmpty || !current.album.isEmpty || current.duration > 0
            || current.isPlaying || current.artwork != nil || current.appName != nil
    }

    @discardableResult
    public func send(_ command: NowPlayingControlCommand, current: NowPlayingInfo,
                     timeout: TimeInterval = 8) async throws -> NowPlayingControlReceipt {
        try Task.checkCancellation()
        guard Self.canControl(current) else { throw NowPlayingControlError.noMedia }
        guard timeout.isFinite, timeout > 0 else { throw NowPlayingControlError.invalidTimeout }
        // Bound conversion to nanoseconds and the subprocess lifetime even if a
        // caller supplies an excessively large timeout.
        let receipt = try await transport.send(command, min(timeout, 60))
        try Task.checkCancellation()
        return receipt
    }

    /// Strictly validate the one-shot subprocess's result. Missing output and an
    /// unexpected command are ambiguous outcomes, never permission to send again.
    public static func parseTransportOutput(_ output: Data,
                                            expectedCommand: NowPlayingControlCommand) throws -> NowPlayingControlReceipt {
        guard let json = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any],
              let number = json["command"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(expectedCommand.rawValue),
              let status = json["status"] as? String else {
            throw NowPlayingControlError.invalidResponse
        }
        switch status {
        case "accepted": return .accepted
        case "rejected": throw NowPlayingControlError.rejected
        case "unsupported": throw NowPlayingControlError.unsupported
        default: throw NowPlayingControlError.invalidResponse
        }
    }
}

private enum NowPlayingControlSubprocess {
    static func send(_ command: NowPlayingControlCommand, timeout: TimeInterval) async throws -> NowPlayingControlReceipt {
        // Match NowPlayingClient's interpreter-based MediaRemote compatibility
        // path on macOS 26. There is intentionally no direct-call fallback:
        // once launched, an unconfirmed command might already have been sent.
        let swiftURL = URL(fileURLWithPath: "/usr/bin/swift")
        guard FileManager.default.isExecutableFile(atPath: swiftURL.path) else {
            throw NowPlayingControlError.transportUnavailable
        }
        let directory = FileManager.default.temporaryDirectory
        let scriptURL = directory.appendingPathComponent("linx-media-control-\(UUID().uuidString).swift")
        let outputURL = directory.appendingPathComponent("linx-media-control-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            throw NowPlayingControlError.transportUnavailable
        }
        let process = Process()
        process.executableURL = swiftURL
        process.arguments = [scriptURL.path, String(command.rawValue)]
        var environment = ProcessInfo.processInfo.environment
        environment["LINX_MEDIA_CONTROL_OUTPUT"] = outputURL.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completion = NowPlayingControlCompletion()
        process.terminationHandler = { _ in completion.finish(.success(())) }
        try Task.checkCancellation()
        do { try process.run() }
        catch { throw NowPlayingControlError.transportUnavailable }

        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { completion.install($0) }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if completion.finish(.failure(NowPlayingControlError.timeoutOutcomeUnknown)), process.isRunning {
                        process.terminate()
                    }
                    throw NowPlayingControlError.timeoutOutcomeUnknown
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } onCancel: {
            if completion.finish(.failure(CancellationError())), process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw NowPlayingControlError.invalidResponse }
        let output = (try? Data(contentsOf: outputURL)) ?? Data()
        return try NowPlayingControlClient.parseTransportOutput(output, expectedCommand: command)
    }

    private static let script = """
    import Darwin
    import Foundation

    guard CommandLine.arguments.count == 2,
          let command = Int32(CommandLine.arguments[1]),
          [Int32(0), 1, 4, 5].contains(command),
          let outputPath = ProcessInfo.processInfo.environment["LINX_MEDIA_CONTROL_OUTPUT"] else { exit(2) }
    func finish(_ status: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["command": command, "status": status]) else { exit(3) }
        do { try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic) }
        catch { exit(3) }
    }
    typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Bool
    guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
          let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
        finish("unsupported")
        exit(0)
    }
    let send = unsafeBitCast(symbol, to: SendCommand.self)
    // Exactly one delivery attempt. No retry, toggle, app launch, or fallback.
    finish(send(command, nil) ? "accepted" : "rejected")
    """
}

/// Exit, cancellation and deadline races may resolve the waiter only once.
private final class NowPlayingControlCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}
