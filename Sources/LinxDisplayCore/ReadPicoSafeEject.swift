import Foundation
import Darwin

/// A normal macOS safe eject, retaining the original volume identity throughout preflight.
/// 使用系统 diskutil 正常安全弹出；不使用 force，也不结束占用磁盘的其他进程。
public struct ReadPicoSafeEject: Sendable {
    public struct CommandResult: Sendable {
        public let status: Int32, output: Data, error: Data
        public init(status: Int32, output: Data, error: Data = Data()) { self.status = status; self.output = output; self.error = error }
    }
    public struct Environment: Sendable {
        public var volumes: @Sendable () -> [ReadPicoMountedVolume]
        public var run: @Sendable ([String]) async throws -> CommandResult
        public var settle: @Sendable () async throws -> Void
        public init(volumes: @escaping @Sendable () -> [ReadPicoMountedVolume] = { ReadPicoMountedVolume.discover() },
                    run: @escaping @Sendable ([String]) async throws -> CommandResult = { try await ReadPicoSafeEject.runDiskutil($0) },
                    settle: @escaping @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }) {
            self.volumes = volumes; self.run = run; self.settle = settle
        }
    }
    private struct Disk: Equatable {
        let uuid: String, device: String, whole: String, mount: String, bytes: Int64
    }
    private let environment: Environment
    public init(environment: Environment = .init()) { self.environment = environment }
    public func eject(_ url: URL, expectedVolume: ReadPicoMountedVolume? = nil) async throws {
        try Task.checkCancellation()
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let matches = environment.volumes().filter { $0.rootURL == root }
        guard matches.count == 1, let volume = matches.first, let uuid = volume.identity, !uuid.isEmpty,
              volume.capacity > 0, !volume.readOnly,
              expectedVolume == nil || (expectedVolume?.identity == uuid && expectedVolume?.capacity == volume.capacity) else {
            throw ReadPicoManagerError.unavailable("无法核对原 TF 磁盘，请重新连接并选择磁盘后再安全弹出。")
        }
        let store = try ReadPicoTFStore(rootURL: root)
        func verifyMountedIdentity() async throws {
            try Task.checkCancellation(); try await store.verifyAvailable(writing: true)
            let current = environment.volumes().filter { $0.rootURL == root }
            guard current.count == 1, let current = current.first, current.identity == uuid,
                  current.capacity == volume.capacity, !current.readOnly else {
                throw ReadPicoManagerError.unavailable("TF 磁盘已断开或更换，已停止安全弹出。")
            }
        }
        try await verifyMountedIdentity()
        let first = try Self.disk(await command(["info", "-plist", root.path]), root: root, uuid: uuid, capacity: volume.capacity)
        try await verifyMountedIdentity()
        let devicePath = "/dev/" + first.device
        let second = try Self.disk(await command(["info", "-plist", devicePath]), root: root, uuid: uuid, capacity: volume.capacity)
        guard first == second else { throw ReadPicoManagerError.unavailable("TF 磁盘的设备身份已改变，已停止安全弹出。") }
        try await verifyMountedIdentity()
        _ = try await command(["eject", devicePath])
        for _ in 0..<20 {
            try Task.checkCancellation()
            if !environment.volumes().contains(where: { $0.identity == uuid && $0.capacity == volume.capacity }) { return }
            try await environment.settle()
        }
        throw ReadPicoManagerError.unavailable("系统尚未安全移除 TF 磁盘，请稍候重试；尚未确认弹出成功。")
    }
    private func command(_ args: [String]) async throws -> Data {
        try Task.checkCancellation()
        let result = try await environment.run(args)
        try Task.checkCancellation()
        guard result.output.count <= 131072 && result.error.count <= 131072 else { throw ReadPicoManagerError.unavailable("系统磁盘响应过长，安全弹出未确认。") }
        guard result.status == 0 else {
            let details = String(decoding: result.output + result.error, as: UTF8.self).lowercased()
            if details.contains("resource busy") || details.contains("ebusy") || details.contains("unmount was dissented by pid") {
                throw POSIXError(.EBUSY)
            }
            throw ReadPicoManagerError.unavailable("系统未能安全弹出 TF 磁盘（diskutil \(result.status)）。请关闭使用 TF 卡的窗口后重试。")
        }
        return result.output
    }
    private static func disk(_ data: Data, root: URL, uuid: String, capacity: Int64) throws -> Disk {
        guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = info["DeviceIdentifier"] as? String,
              id.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil,
              let whole = info["ParentWholeDisk"] as? String,
              whole.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              id.hasPrefix(whole + "s"), info["WholeDisk"] as? Bool == false,
              let mount = info["MountPoint"] as? String, mount == root.path,
              let actualUUID = info["VolumeUUID"] as? String, actualUUID.caseInsensitiveCompare(uuid) == .orderedSame,
              let size = info["TotalSize"] as? NSNumber, size.int64Value == capacity,
              info["Internal"] as? Bool != true else {
            throw ReadPicoManagerError.unavailable("系统磁盘信息与原 TF 卡不符，已停止安全弹出。")
        }
        return .init(uuid: actualUUID.lowercased(), device: id, whole: whole, mount: mount, bytes: size.int64Value)
    }
    /// Fixed executable and argument array: no shell, force flag, or unrelated process termination.
    public static func runDiskutil(_ arguments: [String]) async throws -> CommandResult {
        guard (arguments.count == 3 && arguments[0] == "info" && arguments[1] == "-plist") ||
              (arguments.count == 2 && arguments[0] == "eject" && arguments[1].range(of: #"^/dev/disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil) else {
            throw ReadPicoManagerError.invalid("不支持的安全磁盘操作。")
        }
        let execution = DiskutilExecution(arguments: arguments)
        return try await withTaskCancellationHandler {
            let worker = Task.detached { try await execution.execute() }
            let timeout = Task { try await Task.sleep(nanoseconds: 30_000_000_000); execution.stop(timedOut: true) }
            defer { timeout.cancel() }
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { execution.stop(timedOut: false) }
    }
}

private final class DiskutilExecution: @unchecked Sendable {
    private let process = Process(), output = Pipe(), errors = Pipe(), lock = NSLock()
    private var stopped = false, timedOut = false
    init(arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments; process.standardOutput = output; process.standardError = errors
        process.standardInput = FileHandle.nullDevice
    }
    func stop(timedOut: Bool) {
        lock.withLock {
            self.timedOut = self.timedOut || timedOut; stopped = true
            if process.isRunning { process.terminate() }
        }
    }
    func execute() async throws -> ReadPicoSafeEject.CommandResult {
        try lock.withLock { if stopped { throw CancellationError() }; try process.run() }
        let stdout = Task.detached { self.output.fileHandleForReading.readDataToEndOfFile() }
        let stderr = Task.detached { self.errors.fileHandleForReading.readDataToEndOfFile() }
        process.waitUntilExit()
        let (out, err) = await (stdout.value, stderr.value)
        let state = lock.withLock { (stopped, timedOut) }
        if state.1 { throw ReadPicoManagerError.unavailable("系统安全弹出操作超时，请保持连接后重试。") }
        if state.0 { throw CancellationError() }
        // Both pipes drain concurrently, avoiding a full-pipe wait in diskutil.
        return .init(status: process.terminationStatus, output: out, error: err)
    }
}
