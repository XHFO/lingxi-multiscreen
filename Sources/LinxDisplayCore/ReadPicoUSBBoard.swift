import Foundation
import Darwin

public struct ReadPicoUSBBoardProgress: Sendable {
    public let text: String
    public let fraction: Double?
    public init(_ text: String, fraction: Double? = nil) { self.text = text; self.fraction = fraction }
}
public struct ReadPicoUSBBoardReceipt: Sendable, Equatable {
    public let taskID: String
    public let state: String
    public let deviceIdentity: String?
    public let power: ReadPicoPowerStatus?
    public let revision: UInt32?
    public let orientation: String?
    public let contentChannel: ReadPicoContentChannel
    public init(taskID: String, state: String = "displayed", deviceIdentity: String? = nil, power: ReadPicoPowerStatus? = nil,
                revision: UInt32? = nil, orientation: String? = nil, contentChannel: ReadPicoContentChannel = .canvas) {
        self.taskID = taskID; self.state = state; self.deviceIdentity = deviceIdentity; self.power = power
        self.revision = revision; self.orientation = orientation; self.contentChannel = contentChannel
    }
}
public struct ReadPicoUSBBoardStatus: Sendable {
    public let taskID: String, state: String
    public let directProtocol: Int, chunkBytes: Int
    public let displayIntent: Bool
    public let dualOrientation: Bool, pairMaxBytes: Int
    public let modelProtocol: Int, modelMaxBytes: Int
    public var supportsModel: Bool { modelProtocol == 1 && modelMaxBytes >= ReadPicoBoardModel.maximumBytes }
    public let contentChannel: ReadPicoContentChannel
    public let appChannels: [String]
    public func supports(_ channel: ReadPicoContentChannel) -> Bool { channel == .canvas || appChannels.contains(channel.rawValue) }
    public var supportsDualOrientation: Bool { dualOrientation && pairMaxBytes >= ReadPicoCanvasPair.maximumBytes }
    public let revision: UInt32?
    public let orientation: String?
    public let power: ReadPicoPowerStatus?
    public init(taskID: String, state: String, power: ReadPicoPowerStatus? = nil, directProtocol: Int = 0, chunkBytes: Int = 0,
                displayIntent: Bool = false, dualOrientation: Bool = false, pairMaxBytes: Int = 0,
                revision: UInt32? = nil, orientation: String? = nil, contentChannel: ReadPicoContentChannel = .canvas, appChannels: [String] = [],
                modelProtocol: Int = 0, modelMaxBytes: Int = 0) {
        self.taskID = taskID; self.state = state; self.power = power
        self.directProtocol = directProtocol; self.chunkBytes = chunkBytes; self.displayIntent = displayIntent
        self.dualOrientation = dualOrientation; self.pairMaxBytes = pairMaxBytes
        self.revision = revision; self.orientation = orientation
        self.contentChannel = contentChannel; self.appChannels = appChannels
        self.modelProtocol = modelProtocol; self.modelMaxBytes = modelMaxBytes
    }
    public init(line: String) throws {
        let raw = Array(line.utf8)
        guard line.hasPrefix("RPICO "), raw.last == 10, raw.count < 1024,
              !raw.dropLast().contains(10), !raw.dropLast(raw.count > 1 && raw[raw.count - 2] == 13 ? 2 : 1).contains(13),
              let data = String(line.dropFirst(6)).data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let board = object["usb_board"] as? NSNumber, CFGetTypeID(board) == CFBooleanGetTypeID(), board.boolValue,
              let proto = object["protocol"] as? NSNumber, CFGetTypeID(proto) != CFBooleanGetTypeID(), proto.doubleValue == 1,
              let gray = object["gray_levels"] as? NSNumber, CFGetTypeID(gray) != CFBooleanGetTypeID(), gray.doubleValue == 16,
              let limit = object["max_bytes"] as? NSNumber, CFGetTypeID(limit) != CFBooleanGetTypeID(), limit.doubleValue >= 420000,
              let task = object["task"] as? String, task.isEmpty || (task.utf8.count == 32 && task.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })),
              let state = object["state"] as? String, ["idle", "pending", "displayed", "error", "saved"].contains(state) else {
            throw ReadPicoManagerError.unavailable("当前固件尚未支持 USB 灵犀画板，请先在“固件与备份”更新。")
        }
        guard let channel = ReadPicoContentChannel(rawValue: object["channel"] as? String ?? "canvas") else {
            throw ReadPicoManagerError.invalid("设备返回了未知的应用频道。")
        }
        contentChannel = channel; appChannels = object["app_channels"] as? [String] ?? []
        taskID = task; self.state = state
        func integer(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            return number.intValue
        }
        directProtocol = integer(object["direct_protocol"]) ?? 0
        chunkBytes = integer(object["chunk_bytes"]) ?? 0
        displayIntent = (object["display_intent"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        dualOrientation = (object["dual_orientation"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        pairMaxBytes = integer(object["pair_max_bytes"]) ?? 0
        modelProtocol = integer(object["model_protocol"]) ?? 0
        modelMaxBytes = integer(object["model_max_bytes"]) ?? 0
        revision = integer(object["revision"]).flatMap { UInt32(exactly: $0) }
        orientation = (object["orientation"] as? String).flatMap { ["portrait", "landscape"].contains($0) ? $0 : nil }
        power = ReadPicoPowerStatus.decodeOptional(object["power"])
    }
}

/// 中文：按实际协议能力选择直接USB画板传输；旧TF任务仅保留兼容工具，常规推图不交接磁盘。
/// English: Send boards over negotiated direct USB; legacy TF jobs remain a compatibility tool, never the normal board route.
public struct ReadPicoUSBBoardClient: Sendable {
    public typealias DirectRunner = @Sendable (String, Data, Bool, @escaping @Sendable (ReadPicoUSBBoardProgress) async -> Void) async throws -> ReadPicoUSBBoardReceipt
    public typealias DirectChannelRunner = @Sendable (String, Data, Bool, ReadPicoContentChannel, @escaping @Sendable (ReadPicoUSBBoardProgress) async -> Void) async throws -> ReadPicoUSBBoardReceipt
    public struct Environment: Sendable {
        public var direct: DirectRunner
        public var directChannel: DirectChannelRunner
        public var ports: @Sendable () -> [String]
        public var identity: @Sendable (String) -> String?
        public var volumes: @Sendable () -> [ReadPicoMountedVolume]
        public var status: @Sendable (String) async throws -> ReadPicoUSBBoardStatus
        public var start: @Sendable (String) async throws -> Void
        public var ejectRetryWait: @Sendable (Int) async throws -> Void
        public init(ports: @escaping @Sendable () -> [String] = { ReadPicoUSBTransferClient.discoverPorts() },
                    identity: @escaping @Sendable (String) -> String? = { ReadPicoUSBTransferClient.serialIdentity(port: $0) },
                    volumes: @escaping @Sendable () -> [ReadPicoMountedVolume] = { ReadPicoMountedVolume.discover() },
                    status: (@Sendable (String) async throws -> ReadPicoUSBBoardStatus)? = nil,
                    start: @escaping @Sendable (String) async throws -> Void = { port in _ = try await ReadPicoUSBTransferClient().start(port: port) },
                    ejectRetryWait: @escaping @Sendable (Int) async throws -> Void = { attempt in try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000) },
                    direct: DirectRunner? = nil, directChannel: DirectChannelRunner? = nil) {
            self.ports = ports; self.identity = identity; self.volumes = volumes; self.start = start
            self.ejectRetryWait = ejectRetryWait
            let productionChannel: DirectChannelRunner = { port, data, display, channel, progress in
                let cancellation = DirectCancellation()
                return try await withTaskCancellationHandler {
                    try await Task.detached { try await ReadPicoUSBBoardClient.directExchange(port: port, bmp: data,
                        display: display, contentChannel: channel, cancelled: { cancellation.isCancelled() }, progress: progress) }.value
                } onCancel: { cancellation.cancel() }
            }
            self.direct = direct ?? { port, data, display, progress in
                try await productionChannel(port, data, display, .canvas, progress)
            }
            self.directChannel = directChannel ?? { port, data, display, channel, progress in
                if let direct {
                    guard channel == .canvas else { throw ReadPicoManagerError.unavailable("当前 USB 连接尚不支持独立应用频道。") }
                    return try await direct(port, data, display, progress)
                }
                return try await productionChannel(port, data, display, channel, progress)
            }
            self.status = status ?? { port in
                let reader = Task.detached { try ReadPicoUSBBoardClient.readStatus(port) }
                return try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
            }
        }
    }
    private final class DirectCancellation: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private static func identitiesMatch(_ left: String?, _ right: String?) -> Bool {
        guard let left, let right else { return false }
        if left == right { return true }
        func mac(_ value: String) -> String? {
            let input = Array(value.utf8)
            guard input.count == 12 || input.count == 17 else { return nil }
            var digits: [UInt8] = []
            for (index, byte) in input.enumerated() {
                if input.count == 17 && index % 3 == 2 { guard byte == 58 else { return nil } }
                else if (48...57).contains(byte) || (65...70).contains(byte) { digits.append(byte) }
                else if (97...102).contains(byte) { digits.append(byte - 32) }
                else { return nil }
            }
            return digits.count == 12 ? String(decoding: digits, as: UTF8.self) : nil
        }
        guard let l = mac(left), let r = mac(right) else { return false }
        return l == r
    }
    /// 中文：仅验证当前选中的端口能力，不按历史型号、旧MAC或TF卷标拒绝替换设备。
    /// English: Verify the selected port's capabilities; historical model, MAC or TF labels never bind a replacement device.
    public func verifyDirect(port: String) async throws -> ReadPicoUSBBoardStatus {
        guard environment.ports().contains(port) else { throw ReadPicoManagerError.unavailable("所选 USB 设备已断开，请重新检测。") }
        let result = try await environment.status(port)
        guard result.directProtocol == 1, (1...1024).contains(result.chunkBytes) else {
            throw ReadPicoManagerError.unavailable("设备支持旧版 USB 画板，请先更新固件以启用直接推送；本次未开启 TF 文件传输。")
        }
        return result
    }
    /// 中文：USB数据直接发往设备服务，TF始终由阅读器管理；只有当前事务要求身份连续一致。
    /// English: Stream through the device service while TF stays reader-owned; identity continuity is scoped to this transfer.
    public func pushDirect(_ bmp: Data, port: String, expectedIdentity: String? = nil, display: Bool = false,
                           contentChannel: ReadPicoContentChannel = .canvas,
                           progress: @escaping @Sendable (ReadPicoUSBBoardProgress) async -> Void) async throws -> ReadPicoUSBBoardReceipt {
        try Self.validateDirectPayload(bmp)
        guard port.hasPrefix("/dev/cu.usbmodem"), URL(fileURLWithPath: port).deletingLastPathComponent().path == "/dev" else {
            throw ReadPicoManagerError.invalid("请选择设备的原生 USB 串口。")
        }
        let currentIdentity = environment.identity(port)
        if let expectedIdentity, !Self.identitiesMatch(currentIdentity, expectedIdentity) {
            throw ReadPicoManagerError.unavailable("传输前设备连接已变化，请重新选择 USB 设备。")
        }
        let capability = try await verifyDirect(port: port)
        let model = ReadPicoBoardModel.isModel(bmp)
        guard !model || capability.supportsModel else { throw ReadPicoManagerError.unavailable("请更新 Pico 固件以支持本机排版的数据画板；不会改发整屏截图。") }
        guard capability.supports(contentChannel) else { throw ReadPicoManagerError.unavailable("请更新设备固件，以支持 Cloudflare 独立应用；本次未传输图片。") }
        guard contentChannel == .canvas || model || ReadPicoCanvasPair.isPair(bmp) else { throw ReadPicoManagerError.invalid("应用内容必须提供数据模型或横竖两种布局。") }
        if ReadPicoCanvasPair.isPair(bmp), !capability.supportsDualOrientation || bmp.count > capability.pairMaxBytes {
            throw ReadPicoManagerError.unavailable("请更新设备固件，以一次接收横竖双方向画板；本次未传输任何图片。")
        }
        try Task.checkCancellation()
        if let currentIdentity, !Self.identitiesMatch(environment.identity(port), currentIdentity) {
            throw ReadPicoManagerError.unavailable("设备在传输前已断开或更换，请重新选择。")
        }
        let lease = try ReadPicoUSBSerialLease.acquire(path: port); defer { lease.release() }
        let receipt = try await environment.directChannel(port, bmp, display, contentChannel, progress)
        if let currentIdentity, !Self.identitiesMatch(environment.identity(port), currentIdentity) {
            throw ReadPicoManagerError.unavailable("USB 连接已变化，尚未确认本次画板；原稿已保留。")
        }
        guard receipt.contentChannel == contentChannel else { throw ReadPicoManagerError.unavailable("USB 应用频道不一致，尚未确认本次画面。") }
        return .init(taskID: receipt.taskID, state: receipt.state, deviceIdentity: currentIdentity, power: receipt.power,
                     revision: receipt.revision, orientation: receipt.orientation, contentChannel: contentChannel)
    }
    private struct DirectWire {
        let fd: Int32
        let cancelled: @Sendable () -> Bool
        var input = Data()
        func checkCancellation() throws { if cancelled() { throw CancellationError() } }
        func write(_ bytes: Data, timeout: TimeInterval = 6) throws {
            let end = Date().addingTimeInterval(timeout)
            var offset = 0
            while offset < bytes.count {
                try checkCancellation()
                guard Date() < end else { throw ReadPicoManagerError.unavailable("USB 发送超时；上一张画板保留。") }
                let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
                if count > 0 { offset += count }
                else if count < 0 && (errno == EINTR || errno == EAGAIN) { usleep(1_000) }
                else { throw ReadPicoManagerError.unavailable("USB 发送中断；上一张画板保留。") }
            }
        }
        mutating func line(timeout: TimeInterval = 6) throws -> String {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                try checkCancellation()
                while let newline = input.firstIndex(of: 10) {
                    let data = input.prefix(through: newline); input.removeSubrange(...newline)
                    if let line = String(data: data, encoding: .utf8), line.hasPrefix("RPICO ") { return line }
                }
                var bytes = [UInt8](repeating: 0, count: 2048)
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 {
                    input.append(contentsOf: bytes.prefix(count))
                    guard input.count <= 65536 else { throw ReadPicoManagerError.invalid("USB 响应过长；本次传输已停止。") }
                } else if count < 0 && errno != EAGAIN && errno != EINTR {
                    throw ReadPicoManagerError.unavailable("USB 已断开，尚未确认画板。")
                } else { usleep(1_000) }
            }
            throw ReadPicoManagerError.unavailable("设备未响应 USB 画板请求；原稿已保留。")
        }
        mutating func status() throws -> ReadPicoUSBBoardStatus {
            try write(Data("RPICO BOARD STATUS\n".utf8))
            let end = Date().addingTimeInterval(6)
            while Date() < end {
                let response = try line()
                if let value = try? ReadPicoUSBBoardStatus(line: response) { return value }
            }
            throw ReadPicoManagerError.unavailable("设备没有返回 USB 画板能力。")
        }
        mutating func acknowledgement(task: String, phase: String, offset: Int? = nil) throws {
            let end = Date().addingTimeInterval(6)
            while Date() < end {
                let line = try line()
                guard let data = String(line.dropFirst(6)).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let direct = json["board_direct"] as? NSNumber,
                      CFGetTypeID(direct) == CFBooleanGetTypeID(), direct.boolValue else { continue }
                guard json["task"] as? String == task else { continue }
                guard let accepted = json["accepted"] as? NSNumber,
                      CFGetTypeID(accepted) == CFBooleanGetTypeID(), accepted.boolValue else {
                    throw ReadPicoManagerError.unavailable("设备拒绝了 USB 画板传输，请检查 TF 卡及设备状态。")
                }
                guard json["phase"] as? String == phase,
                      let proto = json["protocol"] as? NSNumber, CFGetTypeID(proto) != CFBooleanGetTypeID(), proto.doubleValue == 1,
                      offset == nil || (json["next_offset"] as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == Double(offset!) }) == true else {
                    throw ReadPicoManagerError.invalid("USB 画板确认与发送内容不一致，传输已停止。")
                }
                return
            }
            throw ReadPicoManagerError.unavailable("设备未确认 USB 画板数据；原稿已保留。")
        }
        mutating func abort(task: String) {
            let deadline = Date().addingTimeInterval(1)
            do {
                try write(Data("RPICO BOARD ABORT \(task)\n".utf8), timeout: 1)
                // Keep the port open until the receiver consumes ABORT. A ready/chunk ACK
                // already in flight belongs to the cancelled exchange and may precede it.
                while Date() < deadline {
                    let response = try line(timeout: max(0.001, deadline.timeIntervalSinceNow))
                    guard let data = String(response.dropFirst(6)).data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let direct = json["board_direct"] as? NSNumber,
                          CFGetTypeID(direct) == CFBooleanGetTypeID(), direct.boolValue,
                          json["task"] as? String == task,
                          json["phase"] as? String == "aborted" else { continue }
                    return
                }
            } catch { /* Receiver timeout also clears an uncommitted transaction. */ }
        }
    }
    private static func directExchange(port: String, bmp: Data, display: Bool, contentChannel: ReadPicoContentChannel = .canvas,
                                       cancelled: @escaping @Sendable () -> Bool,
                                       progress: @escaping @Sendable (ReadPicoUSBBoardProgress) async -> Void) async throws -> ReadPicoUSBBoardReceipt {
        try validateDirectPayload(bmp)
        let paired = ReadPicoCanvasPair.isPair(bmp)
        let model = ReadPicoBoardModel.isModel(bmp)
        let fd = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw ReadPicoManagerError.unavailable("USB 端口暂不可用，请保持连接后重试。") }
        defer { Darwin.close(fd) }
        guard Darwin.ioctl(fd, TIOCEXCL) == 0 else { throw ReadPicoManagerError.unavailable("USB 正在处理其他操作，请稍后重试。") }
        var config = termios()
        guard tcgetattr(fd, &config) == 0 else { throw POSIXError(.EIO) }
        cfmakeraw(&config); config.c_cflag |= tcflag_t(CLOCAL | CREAD); config.c_cflag &= ~tcflag_t(HUPCL)
        guard cfsetspeed(&config, speed_t(B115200)) == 0, tcsetattr(fd, TCSANOW, &config) == 0 else { throw POSIXError(.EIO) }
        var wire = DirectWire(fd: fd, cancelled: cancelled)
        let capability = try wire.status()
        guard capability.directProtocol == 1, (1...1024).contains(capability.chunkBytes), !display || capability.displayIntent else {
            throw ReadPicoManagerError.unavailable("请更新设备固件，以使用直接 USB 画板和显示控制。")
        }
        guard capability.supports(contentChannel), contentChannel == .canvas || paired || model else {
            throw ReadPicoManagerError.unavailable("当前设备不支持本次应用内容；本次未传输图片。")
        }
        guard !paired || capability.supportsDualOrientation && bmp.count <= capability.pairMaxBytes else {
            throw ReadPicoManagerError.unavailable("请更新设备固件，以一次接收横竖双方向画板；本次未传输任何图片。")
        }
        guard !model || capability.supportsModel else {
            throw ReadPicoManagerError.unavailable("请更新 Pico 固件以支持本机排版的数据画板；不会改发整屏截图。")
        }
        let task = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let crc = String(format: "%08x", readPicoCRC32(bmp))
        let verb = model ? "BEGINMODEL \(contentChannel.rawValue)" : contentChannel == .canvas ? (paired ? "BEGINPAIR" : "BEGIN") : "BEGINAPP \(contentChannel.rawValue)"
        let begin = "RPICO BOARD \(verb) \(task) \(bmp.count) \(crc) \(display ? 1 : 0)\n"
        var abortNeeded = false, atChunkBoundary = true
        defer {
            // After a complete chunk, an ordered ABORT releases both staged frames. A partial
            // binary write cannot safely carry a command; firmware's receive timeout handles it.
            if abortNeeded && atChunkBoundary {
                var cleanup = DirectWire(fd: fd, cancelled: { false }, input: wire.input)
                cleanup.abort(task: task)
            }
        }
        try wire.write(Data(begin.utf8)); abortNeeded = true
        try wire.acknowledgement(task: task, phase: "ready", offset: 0)
        var offset = 0
        await progress(.init("正在通过 USB 直接发送画板…", fraction: 0))
        while offset < bmp.count {
            try wire.checkCancellation()
            let count = min(capability.chunkBytes, bmp.count - offset)
            atChunkBoundary = false
            try wire.write(Data("RPICO BOARD CHUNK \(task) \(offset) \(count)\n".utf8))
            let start = bmp.startIndex + offset
            try wire.write(bmp.subdata(in: start..<(start + count)))
            atChunkBoundary = true
            try wire.acknowledgement(task: task, phase: "chunk", offset: offset + count)
            offset += count
            if offset == bmp.count || offset % (32 * capability.chunkBytes) == 0 {
                await progress(.init("正在传输画板：\(ByteCountFormatter.string(fromByteCount: Int64(offset), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(bmp.count), countStyle: .file))", fraction: Double(offset) / Double(bmp.count)))
            }
        }
        atChunkBoundary = false
        try wire.write(Data("RPICO BOARD COMMIT \(task)\n".utf8)); abortNeeded = false
        try wire.acknowledgement(task: task, phase: "committed")
        await progress(.init(display ? "画板已发送，正在等待设备显示…" : "画板已发送，正在等待设备保存…", fraction: 1))
        let end = Date().addingTimeInterval(25)
        while Date() < end {
            let status = try wire.status()
            if status.taskID == task {
                guard status.contentChannel == contentChannel else { throw ReadPicoManagerError.unavailable("设备回执的应用频道不一致，请在设备上核对。") }
                if status.state == "saved" || status.state == "displayed" {
                    return .init(taskID: task, state: status.state, power: status.power,
                                 revision: status.revision, orientation: status.orientation, contentChannel: contentChannel)
                }
                if status.state == "error" { throw ReadPicoManagerError.unavailable("设备未完成画板保存或显示；Mac 原稿已保留。") }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ReadPicoManagerError.unavailable("画板已提交，尚未确认保存或显示；请在设备上核对。")
    }
    private func safelyEject(_ store: ReadPicoTFStore, volumeID: String, capacity: Int64,
                             eject: @escaping @Sendable (URL) async throws -> Void,
                             progress: @escaping @Sendable (ReadPicoUSBBoardProgress) async -> Void) async throws {
        for attempt in 1...6 {
            try Task.checkCancellation()
            try await store.verifyAvailable(writing: true)
            guard environment.volumes().contains(where: { $0.identity == volumeID && $0.capacity == capacity && !$0.readOnly && $0.rootURL.standardizedFileURL == store.rootURL.standardizedFileURL }) else {
                throw ReadPicoManagerError.unavailable("TF 磁盘已断开或已更换，请重新连接并选择原卡。")
            }
            do { try await eject(store.rootURL); return }
            catch {
                try Task.checkCancellation()
                let error = error as NSError
                guard (error.domain == NSOSStatusErrorDomain && error.code == -47) ||
                      (error.domain == NSPOSIXErrorDomain && error.code == Int(EBUSY)) else { throw error }
                guard attempt < 6 else {
                    throw ReadPicoManagerError.unavailable("TF 卡仍被系统占用，尚未安全弹出。请关闭正在使用 TF 卡的窗口后重试，Mac 原稿已保留。")
                }
                await progress(.init("TF 卡暂被系统占用，正在等待系统释放后安全弹出（\(attempt) / 5）…"))
                try await environment.ejectRetryWait(attempt)
            }
        }
    }
    private let environment: Environment
    public init(environment: Environment = .init()) { self.environment = environment }
    /// Read only: never exports storage or submits another frame while checking a saved task.
    /// 只读核对已保存的任务，不开启磁盘或重复传图；调用方保证 TF 当前属于设备。
    public func receiptStatus(taskID: String, expectedIdentity: String, contentChannel: ReadPicoContentChannel = .canvas) async throws -> ReadPicoUSBBoardStatus? {
        guard !expectedIdentity.isEmpty else { return nil }
        let ports = environment.ports().filter { Self.identitiesMatch(environment.identity($0), expectedIdentity) }
        guard ports.count == 1 else { return nil }
        let status = try await environment.status(ports[0])
        try Task.checkCancellation()
        guard Self.identitiesMatch(environment.identity(ports[0]), expectedIdentity) else { return nil }
        guard status.taskID == taskID, status.contentChannel == contentChannel else {
            throw ReadPicoManagerError.unavailable("设备已有其他画板任务，原画面尚未确认显示。")
        }
        return status
    }
    private func port(expected: String?, timeout: TimeInterval) async throws -> String {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            try Task.checkCancellation()
            let ports = environment.ports()
            let matching = ports.filter { expected == nil || environment.identity($0) == expected }
            if matching.count == 1, environment.identity(matching[0]) != nil { return matching[0] }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw ReadPicoManagerError.unavailable("未找到原阅读器的 USB 串口。请保持数据线连接并点按电源唤醒，原稿已保留。")
    }
    public func push(_ bmp: Data, store: ReadPicoTFStore, expectedIdentity: String?,
                     eject: @escaping @Sendable (URL) async throws -> Void,
                     progress: @escaping @Sendable (ReadPicoUSBBoardProgress) async -> Void) async throws -> ReadPicoUSBBoardReceipt {
        try Self.validateBitmap(bmp)
        try await store.verifyAvailable(writing: true)
        let root = store.rootURL
        guard let volume = environment.volumes().first(where: { $0.rootURL.standardizedFileURL == root.standardizedFileURL }),
              let volumeID = volume.identity, !volume.readOnly else {
            throw ReadPicoManagerError.unavailable("请先从小纸 Pico 的内容管理中连接并选择可写 TF 磁盘。")
        }
        await progress(.init("正在安全交还 TF 卡，核对 USB 画板能力…"))
        try await safelyEject(store, volumeID: volumeID, capacity: volume.capacity, eject: eject, progress: progress)
        let debugPort = try await port(expected: expectedIdentity, timeout: 18)
        guard let deviceID = environment.identity(debugPort) else { throw ReadPicoManagerError.unavailable("无法核对阅读器 USB 身份，请重新连接。") }
        _ = try await environment.status(debugPort)
        try Task.checkCancellation()
        await progress(.init("设备支持 USB 画板，正在准备 USB 文件传输…"))
        try await environment.start(debugPort)
        await progress(.init("已开启 USB，正在等待原 TF 磁盘挂载…"))
        let deadline = Date().addingTimeInterval(45)
        var target: ReadPicoMountedVolume?
        while Date() < deadline {
            try Task.checkCancellation()
            target = environment.volumes().first { $0.identity == volumeID && $0.capacity == volume.capacity && !$0.readOnly }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        guard let target else { throw ReadPicoManagerError.unavailable("原 TF 磁盘尚未重新挂载，请重新检测；尚未传输画板。") }
        let current = try ReadPicoTFStore(rootURL: target.rootURL)
        let taskID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await Self.commit(bmp, taskID: taskID, store: current, progress: progress)
        // 提交后取消只停止等待；不承诺撤销设备稍后读取的任务。/ Cancellation after commit stops waiting, never promises to revoke a task.
        await progress(.init("画板已传输，正在安全弹出并交还阅读器…"))
        try await safelyEject(current, volumeID: volumeID, capacity: volume.capacity, eject: eject, progress: progress)
        await progress(.init("正在等待阅读器确认保存或显示 16 灰阶画板…"))
        let returned = try await port(expected: deviceID, timeout: 18)
        let confirmationDeadline = Date().addingTimeInterval(25)
        while Date() < confirmationDeadline {
            try Task.checkCancellation()
            guard environment.identity(returned) == deviceID else { throw ReadPicoManagerError.unavailable("连接的阅读器已更换，画板显示尚未确认。") }
            let state = try await environment.status(returned)
            if state.taskID == taskID {
                if state.state == "displayed" || state.state == "saved" {
                    return .init(taskID: taskID, state: state.state, deviceIdentity: deviceID, power: state.power)
                }
                if state.state == "error" { throw ReadPicoManagerError.unavailable("阅读器未能确认显示这幅画板，Mac 原稿已保留。请查看设备后重试。") }
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        throw ReadPicoManagerError.unavailable("画板已提交，但尚未确认显示。请在阅读器查看结果后重试，Mac 原稿已保留。")
    }
    public static func commit(_ bmp: Data, taskID: String, store: ReadPicoTFStore,
                              progress: @escaping @Sendable (ReadPicoUSBBoardProgress) async -> Void) async throws {
        guard taskID.utf8.count == 32, taskID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), bmp.count <= 420000 else {
            throw ReadPicoManagerError.invalid("USB 画板任务无效。")
        }
        try validateBitmap(bmp)
        try await store.verifyAvailable(writing: true)
        var directoryFD = Darwin.open(store.rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw ReadPicoManagerError.unavailable("无法打开原 TF 磁盘，请重新连接。") }
        defer { Darwin.close(directoryFD) }
        try await store.verifyAvailable(writing: true)
        var openedRoot = stat(), currentRoot = stat()
        guard fstat(directoryFD, &openedRoot) == 0, Darwin.lstat(store.rootURL.path, &currentRoot) == 0,
              openedRoot.st_dev == currentRoot.st_dev, openedRoot.st_ino == currentRoot.st_ino else {
            throw ReadPicoManagerError.unavailable("TF 磁盘已断开或更换，未创建画板文件。")
        }
        for part in ["readpico", "desktop"] {
            try await store.verifyAvailable(writing: true)
            var existing = stat()
            if fstatat(directoryFD, part, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                guard existing.st_mode & S_IFMT == S_IFDIR else { throw ReadPicoManagerError.invalid("TF 卡的画板目录无效。") }
            } else {
                guard errno == ENOENT else { throw ReadPicoManagerError.unavailable("无法读取 TF 卡画板目录，请重新连接。") }
                // Another creator may win this mkdir; openat below still requires a real directory and rejects links.
                guard mkdirat(directoryFD, part, mode_t(0o700)) == 0 || errno == EEXIST else {
                    throw ReadPicoManagerError.unavailable("无法创建 TF 卡画板目录，请检查可用空间。")
                }
            }
            let nextFD = Darwin.openat(directoryFD, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard nextFD >= 0 else { throw ReadPicoManagerError.invalid("TF 卡的画板目录无效，不能使用文件或符号链接。") }
            Darwin.close(directoryFD); directoryFD = nextFD
        }
        try await store.verifyAvailable(writing: true)
        let targetName = "usb-board.pcb"
        var existing = stat()
        guard fstatat(directoryFD, targetName, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw ReadPicoManagerError.conflict("TF 卡内已有未处理的画板，请先安全弹出并等待设备处理后重试。")
        }
        let temporaryName = ".usb-board-\(taskID).tmp"
        var packet = Data(repeating: 0, count: 64)
        packet.replaceSubrange(0..<8, with: Data("PICOBRD1".utf8))
        func put(_ offset: Int, _ value: UInt32) { for i in 0..<4 { packet[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) } }
        put(8, 1); put(12, 64); put(16, UInt32(bmp.count)); put(20, readPicoCRC32(bmp)); packet.replaceSubrange(24..<56, with: Data(taskID.utf8)); packet.append(bmp)
        let fd = Darwin.openat(directoryFD, temporaryName, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw ReadPicoManagerError.unavailable("无法在 TF 卡创建画板临时文件，请检查可用空间。") }
        var closed = false
        defer { if !closed { Darwin.close(fd) }; Darwin.unlinkat(directoryFD, temporaryName, 0) }
        var offset = 0
        while offset < packet.count {
            try Task.checkCancellation(); try await store.verifyAvailable(writing: true)
            let end = min(offset + 8192, packet.count)
            let count = packet.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), end - offset) }
            guard count > 0 else { throw ReadPicoManagerError.unavailable("画板传输中断，请保持 TF 卡连接。") }
            offset += count
            await progress(.init("正在传输画板：\(ByteCountFormatter.string(fromByteCount: Int64(offset), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(packet.count), countStyle: .file))", fraction: Double(offset) / Double(packet.count)))
        }
        guard fsync(fd) == 0 else { throw ReadPicoManagerError.unavailable("TF 卡尚未完成写入，请检查存储空间后重试。") }
        var verified = Data(count: packet.count)
        let readCount = verified.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, packet.count, 0) }
        guard readCount == packet.count, verified == packet else { throw ReadPicoManagerError.unavailable("画板传输校验失败，请重新同步。") }
        guard Darwin.close(fd) == 0 else { closed = true; throw ReadPicoManagerError.unavailable("TF 卡未能完成写入。") }; closed = true
        try Task.checkCancellation(); try await store.verifyAvailable(writing: true)
        guard Darwin.renameatx_np(directoryFD, temporaryName, directoryFD, targetName, UInt32(RENAME_EXCL)) == 0 else {
            throw ReadPicoManagerError.unavailable("画板提交未完成；请检查是否已有未处理画板后重试。")
        }
    }
    private static func validateBitmap(_ bmp: Data) throws {
        let cap = try JSONDecoder().decode(ReadPicoCanvasCapability.self, from: Data("{\"supported\":true,\"width\":684,\"height\":1216,\"formats\":[\"image/bmp\"],\"max_bytes\":420000,\"bit_depths\":[1,4],\"gray_levels\":16}".utf8))
        try ReadPicoBitmap.validateCanvas(bmp, capability: cap)
        guard bmp[28] == 4 else { throw ReadPicoManagerError.invalid("USB 灵犀画板使用原生 16 灰阶图片。") }
    }
    private static func validateDirectPayload(_ data: Data) throws {
        if ReadPicoBoardModel.isModel(data) { _ = try ReadPicoBoardModel.decode(data) }
        else if ReadPicoCanvasPair.isPair(data) { try ReadPicoCanvasPair.validate(data) }
        else { try validateBitmap(data) }
    }
    private static func readStatus(_ port: String) throws -> ReadPicoUSBBoardStatus {
        guard port.hasPrefix("/dev/cu.usbmodem"), !port.dropFirst(5).contains("/") else {
            throw ReadPicoManagerError.invalid("请选择小纸 Pico 的 USB 调试串口。")
        }
        let lease = try ReadPicoUSBSerialLease.acquire(path: port); defer { lease.release() }
        let fd = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw ReadPicoManagerError.unavailable("USB 串口尚未恢复，请保持连接后重试。") }
        defer { Darwin.close(fd) }
        guard Darwin.ioctl(fd, TIOCEXCL) == 0 else { throw ReadPicoManagerError.unavailable("USB 串口正在使用，请等待固件或文件传输完成。") }
        var config = termios(); guard tcgetattr(fd, &config) == 0 else { throw POSIXError(.EIO) }
        cfmakeraw(&config); config.c_cflag |= tcflag_t(CLOCAL | CREAD); config.c_cflag &= ~tcflag_t(HUPCL)
        guard cfsetspeed(&config, speed_t(B115200)) == 0, tcsetattr(fd, TCSANOW, &config) == 0 else { throw POSIXError(.EIO) }
        let command = Data("\nRPICO BOARD STATUS\n".utf8)
        guard command.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, command.count) }) == command.count else { throw POSIXError(.EIO) }
        var buffer = Data(); let end = Date().addingTimeInterval(6)
        while Date() < end {
            if Task.isCancelled { throw CancellationError() }
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(through: newline); buffer.removeSubrange(...newline)
                if let text = String(data: line, encoding: .utf8), let status = try? ReadPicoUSBBoardStatus(line: text) { return status }
            }
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { buffer.append(contentsOf: bytes.prefix(count)); if buffer.count > 8192 { buffer.removeAll() } }
            else if count < 0 && errno != EAGAIN && errno != EINTR { throw ReadPicoManagerError.unavailable("USB 已断开，画板显示尚未确认。") }
            usleep(20_000)
        }
        throw ReadPicoManagerError.unavailable("设备没有 USB 画板回执，请先升级固件并保持设备唤醒。")
    }
}
