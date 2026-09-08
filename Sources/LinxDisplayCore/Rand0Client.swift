import Foundation
import Darwin

/// Rand/0 设备显示模式客户端：通过局域网 WebSocket 向设备推送 200×200 帧。
/// 端点 ws://<IP>/display/bw（黑白，5000 字节）或 ws://<IP>/display/gray4（4 级灰阶，10000 字节）。
/// 同一时间设备只保留一个活动客户端；无额外登录鉴权（仅适合可信局域网）。
public enum Rand0Client {
    /// 显示端点：bw=1 位黑白，gray4=4 级灰阶
    public enum Endpoint: String {
        case bw = "bw"
        case gray4 = "gray4"
    }

    public enum Rand0Error: Error, LocalizedError {
        case missingIP
        case invalidURL
        case connectionFailed
        case invalidFrameSize(Int)

        public var errorDescription: String? {
            switch self {
            case .missingIP: return "请先在「口袋先知」画板中填写 Rand/0 设备 IP 地址。"
            case .invalidURL: return "Rand/0 设备 IP 地址无效。"
            case .connectionFailed: return "连接 Rand/0 设备失败，请确认设备在线且在同一局域网。"
            case .invalidFrameSize(let expected): return "帧数据尺寸无效（应为 \(expected) 字节）。"
            }
        }
    }

    /// 把一帧数据通过 WebSocket 推送到 Rand/0 设备（按端点校验帧尺寸：bw=5000，gray4=10000）。
    /// - Returns: 发送是否完成（设备确认收到二进制帧）。
    public static func pushFrame(_ frame: Data, ip: String, endpoint: Endpoint = .bw) async throws {
        let expected = endpoint == .gray4 ? 10000 : 5000
        guard frame.count == expected else { throw Rand0Error.invalidFrameSize(expected) }

        let trimmedIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIP.isEmpty else { throw Rand0Error.missingIP }
        let host = EndpointBuilder.host(from: trimmedIP)
        guard let url = URL(string: "ws://\(host)/display/\(endpoint.rawValue)") else {
            throw Rand0Error.invalidURL
        }

        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        // 等待连接建立
        let connected = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            task.receive { result in
                switch result {
                case .success: cont.resume(returning: true)
                case .failure: cont.resume(returning: false)
                }
            }
        }
        guard connected else {
            task.cancel(with: .goingAway, reason: nil)
            throw Rand0Error.connectionFailed
        }

        // 发送二进制帧
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.send(.data(frame)) { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: ()) }
            }
        }

        // 等待设备确认或超时（3 秒）；超时与收到消息都可能触发，须保证只 resume 一次，
        // 否则 CheckedContinuation 断言失败崩溃
        let acknowledged = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var resumed = false
            func resumeOnce(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: value)
            }
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                resumeOnce(false)
            }
            task.receive { result in
                timeoutTask.cancel()
                switch result {
                case .success: resumeOnce(true)
                case .failure: resumeOnce(false)
                }
            }
        }

        task.cancel(with: .normalClosure, reason: nil)

        if !acknowledged {
            // 设备未确认也认为已发送（e-ink 刷新可能较慢）
        }
    }

    /// 兼容入口：黑白帧（5000 字节）
    public static func pushBWFrame(_ frame: Data, ip: String) async throws {
        try await pushFrame(frame, ip: ip, endpoint: .bw)
    }
}

// MARK: - WebSocket 帧编解码（RFC 6455 子集）

/// 一帧已解析的 WebSocket 消息
public struct WSFrame {
    public let fin: Bool
    public let opcode: UInt8
    public let payload: Data

    public init(fin: Bool, opcode: UInt8, payload: Data) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
    }
}

/// WebSocket 帧构造与解析。解析对部分实现不遵循 RFC 的情况（如对客户端帧加掩码、
/// 使用保留 opcode）保持宽容：任何帧都消费并保持流同步，调用方按 opcode 决定处理。
public enum WSFraming {
    public static let opcodeContinuation: UInt8 = 0x0
    public static let opcodeText: UInt8 = 0x1
    public static let opcodeBinary: UInt8 = 0x2
    public static let opcodeClose: UInt8 = 0x8
    public static let opcodePing: UInt8 = 0x9
    public static let opcodePong: UInt8 = 0xA

    /// 单帧最大负载（超出视为异常数据，调用方按字节重同步）
    public static let maximumPayload = 16_000_000

    /// 构造一帧（client→server 必须 masked，RFC 6455 强制）
    public static func build(opcode: UInt8, payload: Data, masked: Bool) -> Data {
        var out = Data()
        out.append(0x80 | opcode) // FIN=1
        let maskBit: UInt8 = masked ? 0x80 : 0x00
        let len = payload.count
        if len < 126 {
            out.append(maskBit | UInt8(len))
        } else if len <= 0xFFFF {
            out.append(maskBit | 126)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
        } else {
            out.append(maskBit | 127)
            var big = UInt64(len).bigEndian
            withUnsafeBytes(of: &big) { out.append(contentsOf: $0) }
        }
        if masked {
            let key = (0..<4).map { _ in UInt8.random(in: 0...255) }
            out.append(contentsOf: key)
            for (i, b) in payload.enumerated() { out.append(b ^ key[i % 4]) }
        } else {
            out.append(contentsOf: payload)
        }
        return out
    }

    /// 从缓冲区开头解析一帧。数据不足时返回 nil 且**不消费任何字节**；
    /// 解析成功则消费整帧并返回。掩码自动解除。
    public static func parse(from buffer: inout Data) -> WSFrame? {
        let count = buffer.count
        guard count >= 2 else { return nil }
        let base = buffer.startIndex // removeFirst 可能让 startIndex 前移而非物理删除
        let b0 = buffer[base]
        let b1 = buffer[base + 1]
        let fin = (b0 >> 7) & 1 == 1
        let opcode = b0 & 0x0F
        let masked = (b1 >> 7) & 1 == 1
        var len = Int(b1 & 0x7F)
        var headerLen = 2
        if len == 126 {
            guard count >= 4 else { return nil }
            len = Int(UInt16(buffer[base + 2]) << 8 | UInt16(buffer[base + 3]))
            headerLen = 4
        } else if len == 127 {
            guard count >= 10 else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(buffer[base + 2 + i]) }
            len = Int(v)
            headerLen = 10
        }
        guard len <= maximumPayload else { return nil }
        var maskKey: [UInt8] = []
        if masked {
            guard count >= headerLen + 4 else { return nil }
            maskKey = Array(buffer[(base + headerLen)..<(base + headerLen + 4)])
            headerLen += 4
        }
        guard count >= headerLen + len else { return nil }
        let payloadStart = base + headerLen
        var payload = Data(buffer[payloadStart..<(payloadStart + len)])
        if masked {
            for i in 0..<payload.count {
                payload[payload.startIndex + i] ^= maskKey[i % 4]
            }
        }
        buffer.removeFirst(headerLen + len)
        return WSFrame(fin: fin, opcode: opcode, payload: payload)
    }
}

// MARK: - 底层 POSIX socket 辅助

private enum RawSocket {
    /// 建立 TCP 连接（非阻塞 connect + poll 超时），返回阻塞 fd。
    static func connect(host: String, port: UInt16, timeout: TimeInterval,
                        receiveTimeout: TimeInterval = 1) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = 0
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let addr = res else {
            throw Rand0Client.Rand0Error.connectionFailed
        }
        defer { freeaddrinfo(res) }

        var sock: Int32 = -1
        var cursor: UnsafeMutablePointer<addrinfo>? = addr
        while let p = cursor {
            let fd = socket(p.pointee.ai_family, p.pointee.ai_socktype, p.pointee.ai_protocol)
            if fd >= 0 {
                // 防止向已关闭连接写数据触发 SIGPIPE 崩溃
                var noSig: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let rc = Darwin.connect(fd, p.pointee.ai_addr, p.pointee.ai_addrlen)
                if rc == 0 {
                    sock = fd
                    break
                }
                if rc == -1 && errno == EINPROGRESS {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let prc = poll(&pfd, 1, Int32(timeout * 1000))
                    if prc > 0 {
                        var soerr: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len)
                        if soerr == 0 {
                            sock = fd
                            break
                        }
                    }
                }
                Darwin.close(fd)
            }
            cursor = p.pointee.ai_next
        }
        guard sock >= 0 else { throw Rand0Client.Rand0Error.connectionFailed }

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags & ~O_NONBLOCK)
        let boundedReceiveTimeout = max(receiveTimeout, 0.1)
        var rcv = timeval(tv_sec: Int(boundedReceiveTimeout),
                          tv_usec: Int32((boundedReceiveTimeout
                              - floor(boundedReceiveTimeout)) * 1_000_000))
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &rcv, socklen_t(MemoryLayout<timeval>.size))
        return sock
    }

    /// 完整发送（处理部分发送）
    static func sendAll(_ fd: Int32, _ data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            while sent < data.count {
                let n = Darwin.send(fd, base + sent, data.count - sent, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Rand0Client.Rand0Error.connectionFailed
                }
                sent += n
            }
        }
    }
}

/// Rand/0 显示模式持久会话：保持 WebSocket 连接以接收按键事件（设备把按键信号回传给
/// 当前已连接的客户端），推送帧走同一连接（发送即显示，无需在设备上按键刷新）。
///
/// 实现说明（相对早期 URLSession 版本的关键差异）：
/// - 自研 raw-socket WebSocket 客户端，绕过 URLSessionWebSocketTask 的严格帧校验——
///   设备固件的帧可能不遵循 RFC（如对服务端帧加掩码、保留 opcode），URLSession 会因此
///   直接断连导致按键事件永远收不到；
/// - 断线自动重连（设备空闲约 30~60 秒会主动关闭连接），保证随时处于可接收按键的状态；
/// - 连接状态回调 onStatusChange，界面「已连接」指示始终与真实状态一致。
/// 文档：dot.mindreset.tech/docs/rand_0/start/features/display_mode
public final class Rand0DisplaySession: @unchecked Sendable {
    /// 按键事件回调：(key, action)，如 ("down", "short")；在主线程触发
    public var onKeyEvent: ((String, String) -> Void)?
    /// 连接状态变化回调（true=已连接/重连成功，false=断线）；在主线程触发
    public var onStatusChange: ((Bool) -> Void)?

    private let lock = NSLock()
    private let socketQueue = DispatchQueue(label: "rand0.session.socket")
    private var fd: Int32 = -1
    private var connectedFlag = false
    private var loopRunning = false
    private var stopRequested = false
    private var generation = 0
    private var host = ""
    private var port: UInt16 = 80
    private var path = "/display/bw"

    public init() {}

    /// 只完成专属显示端点的 WebSocket 握手并立即关闭，不发送任何图像。
    /// 用于设备管理的局域网发现，不会改变墨水屏当前内容。
    public static func probe(ip: String, timeout: TimeInterval = 0.65) async -> Bool {
        let clean = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        return await Task.detached(priority: .utility) {
            let (host, port) = splitHostPort(EndpointBuilder.host(from: clean))
            do {
                let (fd, _) = try openConnection(host: host, port: port, path: "/display/bw",
                                                 connectTimeout: timeout,
                                                 handshakeTimeout: timeout)
                Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
                return true
            } catch {
                return false
            }
        }.value
    }

    /// 当前是否已连接
    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return connectedFlag
    }

    /// 连接循环是否存活（已连接或正在连接/重连中）。目标相同时重复调用 connect 不会打断它。
    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return loopRunning
    }

    // MARK: - 同步锁辅助（避免在 async 上下文直接使用 NSLock）

    /// 锁内准备连接状态；返回新循环的不可变代次，nil 表示目标未变且循环已存活。
    /// 目标切换时 stopRequested 会为新循环恢复为 false，因此旧循环还必须用代次永久淘汰。
    private func prepareLoop(host: String, port: UInt16, path: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        if self.host == host && self.port == port && self.path == path && loopRunning {
            return nil
        }
        if loopRunning {
            // 目标变化：停掉旧循环（fd shutdown 后旧 readLoop 立刻返回）
            stopRequested = true
            if fd >= 0 {
                // 只 shutdown 来唤醒所有者的 recv；最终 close 由该循环完成。
                // 这避免两个线程重复 close 同一数字后误关系统复用的新 fd。
                Darwin.shutdown(fd, SHUT_RDWR)
                fd = -1
            }
        }
        self.host = host
        self.port = port
        self.path = path
        stopRequested = false
        loopRunning = true
        generation += 1
        return generation
    }

    /// 当前连接的 fd（未连接返回 nil）
    private func connectedFd() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        return connectedFlag && fd >= 0 ? fd : nil
    }

    /// 建立连接并开始监听按键事件；目标（IP/端口/端点）相同时幂等。
    /// 等待首次握手结果后返回；断线后由内部循环自动重连。
    public func connect(ip: String, endpoint: Rand0Client.Endpoint = .bw) async {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let (h, p) = Self.splitHostPort(EndpointBuilder.host(from: trimmed))
        let path = "/display/\(endpoint.rawValue)"
        guard let loopGeneration = prepareLoop(host: h, port: p, path: path) else { return }

        _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            socketQueue.async { [weak self] in
                guard let self else {
                    cont.resume(returning: false)
                    return
                }
                self.runLoop(host: h, port: p, path: path,
                             generation: loopGeneration, firstResult: cont)
            }
        }
    }

    /// 通过当前连接推送一帧；未连接时等待连接循环就绪（最多 3 秒）再发送，
    /// 绝不另开一条竞争连接（设备同一时间只给最后连接的客户端发按键事件）。
    public func push(frame: Data, ip: String, endpoint: Rand0Client.Endpoint = .bw) async throws {
        let expected = endpoint == .gray4 ? 10000 : 5000
        guard frame.count == expected else { throw Rand0Client.Rand0Error.invalidFrameSize(expected) }
        if let f = connectedFd() {
            try sendFrame(f, opcode: WSFraming.opcodeBinary, payload: frame)
            return
        }
        await connect(ip: ip, endpoint: endpoint)
        for _ in 0..<30 {
            if let f = connectedFd() {
                try sendFrame(f, opcode: WSFraming.opcodeBinary, payload: frame)
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Rand0Client.Rand0Error.connectionFailed
    }

    /// 断开连接（停止自动重连）
    public func disconnect() {
        lock.lock()
        stopRequested = true
        // 淘汰已排队、正在 connect 或 read 的所有旧循环。
        generation += 1
        loopRunning = false
        connectedFlag = false
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            fd = -1
        }
        lock.unlock()
    }

    /// 解析 display mode 的按键事件文本帧；非按键帧返回 nil
    public static func parseKeyEvent(_ text: String) -> (key: String, action: String)? {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["type"] as? String) == "key",
              let key = obj["key"] as? String,
              let action = obj["action"] as? String else { return nil }
        return (key, action)
    }

    // MARK: - 连接循环

    private func runLoop(host: String, port: UInt16, path: String, generation myGen: Int,
                         firstResult: CheckedContinuation<Bool, Never>) {
        var backoff: TimeInterval = 1.0
        var firstDone = false

        while true {
            lock.lock()
            let stop = stopRequested || generation != myGen
            lock.unlock()
            if stop {
                finishLoop(gen: myGen, firstResult: firstResult, firstDone: &firstDone)
                return
            }
            do {
                let (newFd, leftover) = try Self.openConnection(host: host, port: port, path: path)
                lock.lock()
                if stopRequested || generation != myGen {
                    Darwin.close(newFd)
                    lock.unlock()
                    finishLoop(gen: myGen, firstResult: firstResult, firstDone: &firstDone)
                    return
                }
                fd = newFd
                connectedFlag = true
                lock.unlock()
                backoff = 1.0
                if !firstDone {
                    firstResult.resume(returning: true)
                    firstDone = true
                }
                DispatchQueue.main.async { [weak self] in self?.onStatusChange?(true) }
                readLoop(fd: newFd, initial: leftover, gen: myGen)
                // 连接断开：先解除引用再关闭 fd，避免泄漏成 CLOSE_WAIT
                lock.lock()
                if generation == myGen { connectedFlag = false }
                if fd == newFd { fd = -1 }
                let isCurrent = generation == myGen
                lock.unlock()
                Darwin.close(newFd)
                if isCurrent {
                    DispatchQueue.main.async { [weak self] in self?.onStatusChange?(false) }
                }
            } catch {
                lock.lock()
                if generation == myGen { connectedFlag = false }
                let isCurrent = generation == myGen
                lock.unlock()
                if !firstDone {
                    firstResult.resume(returning: false)
                    firstDone = true
                }
                if isCurrent {
                    DispatchQueue.main.async { [weak self] in self?.onStatusChange?(false) }
                }
            }
            lock.lock()
            let stop2 = stopRequested || generation != myGen
            lock.unlock()
            if stop2 {
                finishLoop(gen: myGen, firstResult: firstResult, firstDone: &firstDone)
                return
            }
            // 分段等待，让目标切换/disconnect 最多 100 ms 就能淘汰本循环，
            // 不会被 8 秒退避卡住 socketQueue 后面的新连接。
            let deadline = Date().addingTimeInterval(backoff)
            while Date() < deadline {
                lock.lock()
                let obsolete = stopRequested || generation != myGen
                lock.unlock()
                if obsolete {
                    finishLoop(gen: myGen, firstResult: firstResult, firstDone: &firstDone)
                    return
                }
                Thread.sleep(forTimeInterval: min(0.1, max(0, deadline.timeIntervalSinceNow)))
            }
            backoff = min(backoff * 2, 8)
        }
    }

    private func finishLoop(gen: Int, firstResult: CheckedContinuation<Bool, Never>,
                            firstDone: inout Bool) {
        if !firstDone {
            firstResult.resume(returning: false)
            firstDone = true
        }
        lock.lock()
        if generation == gen {
            loopRunning = false
            connectedFlag = false
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }
        lock.unlock()
    }

    /// 阻塞读帧循环：解析完整帧；缓冲异常时逐字节重同步。
    private func readLoop(fd: Int32, initial: Data, gen: Int) {
        var buffer = initial
        var pendingText = Data()
        var havePending = false
        while true {
            lock.lock()
            let stop = stopRequested || generation != gen
            lock.unlock()
            if stop { return }
            if buffer.count > 1_000_000 {
                buffer.removeFirst(1) // 失控数据：逐字节重同步
                continue
            }
            if let frame = WSFraming.parse(from: &buffer) {
                switch frame.opcode {
                case WSFraming.opcodeContinuation:
                    pendingText.append(frame.payload)
                    if frame.fin, havePending {
                        let text = String(data: pendingText, encoding: .utf8) ?? ""
                        pendingText.removeAll()
                        havePending = false
                        handleText(text)
                    }
                case WSFraming.opcodeText, WSFraming.opcodeBinary:
                    // 文本帧；二进制帧也尝试按 UTF-8/JSON 解析（个别固件把按键事件当二进制发）
                    if frame.fin {
                        if havePending { pendingText.removeAll(); havePending = false }
                        let text = String(data: frame.payload, encoding: .utf8) ?? ""
                        handleText(text)
                    } else {
                        pendingText = frame.payload
                        havePending = true
                    }
                case WSFraming.opcodeClose:
                    return
                case WSFraming.opcodePing:
                    // 收到 ping 回 pong（同一连接，必须及时响应否则对端可能断开）
                    let pong = WSFraming.build(opcode: WSFraming.opcodePong,
                                               payload: frame.payload, masked: true)
                    try? RawSocket.sendAll(fd, pong)
                default:
                    break // 保留 opcode（部分固件的非标准帧）忽略，流保持同步
                }
            } else {
                var tmp = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.recv(fd, &tmp, 4096, 0)
                if n == 0 { return }
                if n < 0 {
                    // EAGAIN = 接收超时（1s），继续等待；EINTR 重试；其余视为连接断开
                    let e = errno
                    if e == EINTR || e == EAGAIN || e == EWOULDBLOCK { continue }
                    return
                }
                buffer.append(contentsOf: tmp[0..<n])
            }
        }
    }

    private func handleText(_ text: String) {
        guard let ev = Self.parseKeyEvent(text) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onKeyEvent?(ev.key, ev.action)
        }
    }

    private func sendFrame(_ fd: Int32, opcode: UInt8, payload: Data) throws {
        let data = WSFraming.build(opcode: opcode, payload: payload, masked: true)
        try RawSocket.sendAll(fd, data)
    }

    // MARK: - 握手

    /// 建连并完成 WebSocket 握手；返回 (fd, 握手后多余字节)。
    private static func openConnection(host: String, port: UInt16, path: String,
                                       connectTimeout: TimeInterval = 4,
                                       handshakeTimeout: TimeInterval = 5) throws -> (Int32, Data) {
        let fd = try RawSocket.connect(host: host, port: port, timeout: connectTimeout,
                                       receiveTimeout: handshakeTimeout)
        do {
            let leftover = try handshake(fd: fd, host: host, port: port, path: path,
                                         timeout: handshakeTimeout)
            return (fd, leftover)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func handshake(fd: Int32, host: String, port: UInt16, path: String,
                                  timeout: TimeInterval = 5) throws -> Data {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let hostHeader = port == 80 ? host : "\(host):\(port)"
        var req = "GET \(path) HTTP/1.1\r\n"
        req += "Host: \(hostHeader)\r\n"
        req += "Upgrade: websocket\r\n"
        req += "Connection: Upgrade\r\n"
        req += "Sec-WebSocket-Key: \(key)\r\n"
        req += "Sec-WebSocket-Version: 13\r\n\r\n"
        try RawSocket.sendAll(fd, Data(req.utf8))

        // 读到 \r\n\r\n（5 秒上限）
        var head = Data()
        let deadline = Date().addingTimeInterval(max(timeout, 0.1))
        var tmp = [UInt8](repeating: 0, count: 2048)
        while head.range(of: Data([13, 10, 13, 10])) == nil {
            if Date() > deadline { throw Rand0Client.Rand0Error.connectionFailed }
            let n = Darwin.recv(fd, &tmp, 2048, 0)
            if n == 0 { throw Rand0Client.Rand0Error.connectionFailed }
            if n < 0 {
                let e = errno
                if e == EINTR || e == EAGAIN || e == EWOULDBLOCK { continue }
                throw Rand0Client.Rand0Error.connectionFailed
            }
            head.append(contentsOf: tmp[0..<n])
        }
        guard let s = String(data: head, encoding: .utf8), s.contains(" 101 ") else {
            throw Rand0Client.Rand0Error.connectionFailed
        }
        // 头部之后的字节是设备立即发来的帧数据
        if let range = head.range(of: Data([13, 10, 13, 10])) {
            return head.subdata(in: range.upperBound..<head.endIndex)
        }
        return Data()
    }

    /// 拆 "host:port" → (host, port)；无端口默认 80
    private static func splitHostPort(_ host: String) -> (String, UInt16) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = trimmed.lastIndex(of: ":"),
           trimmed[trimmed.index(after: idx)...].allSatisfy({ $0.isNumber }),
           let port = UInt16(trimmed[trimmed.index(after: idx)...]) {
            return (String(trimmed[..<idx]), port)
        }
        return (trimmed, 80)
    }
}
