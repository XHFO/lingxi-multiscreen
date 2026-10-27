import Foundation
import Network
import Security
import Darwin

public enum ReadPicoWeReadPhoneSetupError: LocalizedError, Sendable {
    case noLocalNetwork, listenerUnavailable, cancelled
    public var errorDescription: String? {
        switch self {
        case .noLocalNetwork: return "未找到可供手机访问的局域网。请将 Mac 和手机连接到同一 Wi-Fi 后重试。"
        case .listenerUnavailable: return "无法启动手机授权页面，请检查 macOS 的局域网与防火墙权限后重试。"
        case .cancelled: return "已关闭手机授权，原有授权不受影响。"
        }
    }
}

/// An explicitly started, ten-minute, one-shot LAN handoff. No secrets are written here or logged.
/// 仅在用户点击后启动；只收一次授权，不读取钥匙串、设备或微信账户。
public final class ReadPicoWeReadPhoneSetupServer: @unchecked Sendable {
    public struct Session: Sendable, Equatable {
        public let urls: [URL]
        public let expiresAt: Date
        public init(urls: [URL], expiresAt: Date) { self.urls = urls; self.expiresAt = expiresAt }
    }
    struct Configuration {
        var addresses: @Sendable () -> [String] = { privateIPv4Addresses() }
        var bindAddress = "0.0.0.0"
        var lifetime: TimeInterval = 600
        var requestTimeout: TimeInterval = 10
        var permitsLoopback = false
    }
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "net.xhfo.lingxi.weread-phone-setup")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var listener: NWListener?
    private var generation = UUID()
    private var token = ""
    private var authorities = Set<String>()
    private var expiresAt = Date.distantPast
    private var startContinuation: CheckedContinuation<Session, Error>?
    private var expiry: DispatchWorkItem?
    private var startupDeadline: DispatchWorkItem?
    private var connections: [UUID: Client] = [:]
    private var authorizationTask: Task<Void, Never>?
    private var committing = false
    private var consumed = false
    private var attempts = 0
    private var onAuthorize: (@Sendable (String) async throws -> Void)?
    private final class Client {
        let connection: NWConnection
        var bytes = Data()
        var deadline: DispatchWorkItem?
        var responding = false
        init(_ connection: NWConnection) { self.connection = connection }
    }
    public init() {
        configuration = Configuration()
        queue.setSpecific(key: queueKey, value: true)
    }
    init(configuration: Configuration) {
        self.configuration = configuration
        queue.setSpecific(key: queueKey, value: true)
    }
    deinit {
        expiry?.cancel(); startupDeadline?.cancel(); listener?.cancel(); authorizationTask?.cancel()
        for client in connections.values { client.deadline?.cancel(); client.connection.cancel() }
    }
    private final class StartupCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    public func start(onAuthorize: @escaping @Sendable (String) async throws -> Void) async throws -> Session {
        try Task.checkCancellation()
        let cancellation = StartupCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    begin(continuation: continuation, onAuthorize: onAuthorize)
                }
            }
        }, onCancel: { [weak self] in cancellation.cancel(); self?.stop() })
    }
    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true { shutdown() }
        else { queue.sync { shutdown() } }
    }
    private func begin(continuation: CheckedContinuation<Session, Error>,
                       onAuthorize: @escaping @Sendable (String) async throws -> Void) {
        shutdown()
        let addresses = Array(Set(configuration.addresses())).sorted().filter {
            Self.isPrivateIPv4($0) || (configuration.permitsLoopback && $0 == "127.0.0.1")
        }
        guard !addresses.isEmpty else { continuation.resume(throwing: ReadPicoWeReadPhoneSetupError.noLocalNetwork); return }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            continuation.resume(throwing: ReadPicoWeReadPhoneSetupError.listenerUnavailable); return
        }
        let id = UUID(); generation = id
        token = random.map { String(format: "%02x", $0) }.joined()
        expiresAt = Date().addingTimeInterval(configuration.lifetime)
        self.onAuthorize = onAuthorize; startContinuation = continuation
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(configuration.bindAddress), port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.accept(connection, generation: id)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.generation == id else { return }
                switch state {
                case .ready:
                    guard let port = listener?.port, let continuation = self.startContinuation else { return }
                    self.startContinuation = nil
                    self.startupDeadline?.cancel(); self.startupDeadline = nil
                    self.authorities = Set(addresses.map { "\($0):\(port.rawValue)" })
                    let urls = self.authorities.sorted().compactMap { URL(string: "http://\($0)/#\(self.token)") }
                    continuation.resume(returning: Session(urls: urls, expiresAt: self.expiresAt))
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.generation == id else { return }; self.shutdown()
                    }
                    self.expiry = work
                    self.queue.asyncAfter(deadline: .now() + self.configuration.lifetime, execute: work)
                case .failed, .waiting:
                    self.shutdown(error: ReadPicoWeReadPhoneSetupError.listenerUnavailable)
                default: break
                }
            }
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.generation == id, self.startContinuation != nil else { return }
                self.shutdown(error: ReadPicoWeReadPhoneSetupError.listenerUnavailable)
            }
            startupDeadline = deadline
            queue.asyncAfter(deadline: .now() + 8, execute: deadline)
            listener.start(queue: queue)
        } catch { shutdown(error: ReadPicoWeReadPhoneSetupError.listenerUnavailable) }
    }
    private func shutdown(error: Error = ReadPicoWeReadPhoneSetupError.cancelled) {
        generation = UUID(); token = ""; authorities = []; expiresAt = .distantPast
        expiry?.cancel(); expiry = nil
        startupDeadline?.cancel(); startupDeadline = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        authorizationTask?.cancel(); authorizationTask = nil; onAuthorize = nil
        for client in connections.values { client.deadline?.cancel(); client.connection.cancel() }
        connections.removeAll(); committing = false; consumed = false; attempts = 0
        if let continuation = startContinuation { startContinuation = nil; continuation.resume(throwing: error) }
    }
    private func accept(_ connection: NWConnection, generation id: UUID) {
        guard generation == id, !token.isEmpty, connections.count < 8, Date() < expiresAt,
              Self.allowedPeer(connection.endpoint, permitsLoopback: configuration.permitsLoopback) else { connection.cancel(); return }
        let key = UUID(), client = Client(connection)
        connections[key] = client
        let timeout = DispatchWorkItem { [weak self] in self?.close(key) }
        client.deadline = timeout
        queue.asyncAfter(deadline: .now() + configuration.requestTimeout, execute: timeout)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close(key) }
            if case .cancelled = state { self?.close(key) }
        }
        connection.start(queue: queue)
        receive(key, generation: id)
    }
    private func close(_ id: UUID) {
        guard let client = connections.removeValue(forKey: id) else { return }
        client.deadline?.cancel(); client.connection.stateUpdateHandler = nil; client.connection.cancel()
    }
    private func receive(_ key: UUID, generation id: UUID) {
        guard let client = connections[key], generation == id else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] data, _, complete, error in
            guard let self, self.generation == id, let client = self.connections[key], !client.responding else { return }
            if let data { client.bytes.append(data) }
            if client.bytes.count > 6144 { self.respond(key, status: 413, message: "请求内容过大，请重新填写。"); return }
            switch ReadPicoWeReadPhoneHTTPRequest.parse(client.bytes) {
            case .incomplete:
                if complete || error != nil { self.close(key) } else { self.receive(key, generation: id) }
            case .invalid(let status): self.respond(key, status: status, message: "请求格式无效，请重新扫码后填写。")
            case .request(let request): self.handle(request, client: key, generation: id)
            }
        }
    }
    private func handle(_ request: ReadPicoWeReadPhoneHTTPRequest, client key: UUID, generation id: UUID) {
        guard let client = connections[key] else { return }
        client.responding = true
        guard generation == id, !token.isEmpty, !consumed, Date() < expiresAt else {
            respond(key, status: 410, message: "此配置入口已失效，请回到 Mac 重新打开手机授权。"); return
        }
        guard let host = request.headers["host"], authorities.contains(host) else {
            respond(key, status: 403, message: "访问地址不匹配，请使用 Mac 上的二维码。"); return
        }
        if request.method == "GET" && request.path == "/" {
            guard request.body.isEmpty else { respond(key, status: 400, message: "请求格式无效。"); return }
            respond(key, status: 200, content: Data(ReadPicoWeReadPhoneSetupPage.html.utf8), type: "text/html; charset=utf-8"); return
        }
        guard request.path == "/api/weread/authorize" else { respond(key, status: 404, message: "未找到此页面。"); return }
        guard request.method == "POST" else { respond(key, status: 405, message: "请在授权页面点击保存。"); return }
        guard request.headers["origin"] == "http://" + host,
              request.headers["sec-fetch-site"].map({ $0 == "same-origin" }) ?? true else {
            respond(key, status: 403, message: "仅允许从本机配置页面提交，请重新扫码。"); return
        }
        guard Self.constantEqual(request.headers["authorization"] ?? "", "Bearer " + token) else {
            attempts += 1
            respond(key, status: 401, message: "授权会话无效，请回到 Mac 重新扫码。"); return
        }
        guard !committing else { respond(key, status: 409, message: "正在保存授权，请稍候。"); return }
        guard attempts < 30 else { respond(key, status: 429, message: "尝试次数过多，请回到 Mac 重新打开手机授权。"); return }
        attempts += 1
        guard request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json",
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              Set(object.keys) == ["api_key"], let raw = object["api_key"] as? String,
              let validated = try? ReadPicoWeReadSecretStore.validated(raw), let handler = onAuthorize else {
            respond(key, status: 400, message: "请粘贴完整的 wrk- API Key。"); return
        }
        committing = true
        client.deadline?.cancel(); client.deadline = nil
        authorizationTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await handler(validated)
                try Task.checkCancellation()
                guard let self else { return }
                self.queue.async {
                    guard self.generation == id, !self.token.isEmpty, Date() < self.expiresAt else { return }
                    self.consumed = true; self.authorizationTask = nil
                    self.respond(key, status: 200, message: "授权已保存。请回到 Mac 读取书架。", shutdownAfter: id)
                }
            } catch {
                guard let self else { return }
                self.queue.async {
                    guard self.generation == id else { return }
                    self.committing = false; self.authorizationTask = nil
                    self.respond(key, status: 503, message: "Mac 未能保存授权，请在 Mac 上检查磁盘权限后重试。")
                }
            }
        }
    }
    private func respond(_ key: UUID, status: Int, message: String) {
        respond(key, status: status, message: message, shutdownAfter: nil)
    }
    private func respond(_ key: UUID, status: Int, message: String, shutdownAfter: UUID?) {
        let body = (try? JSONSerialization.data(withJSONObject: ["ok": status == 200, "message": message], options: [.sortedKeys])) ?? Data()
        respond(key, status: status, content: body, type: "application/json; charset=utf-8", shutdownAfter: shutdownAfter)
    }
    private func respond(_ key: UUID, status: Int, content: Data, type: String, shutdownAfter: UUID? = nil) {
        guard let client = connections[key] else {
            if let id = shutdownAfter, generation == id { shutdown() }
            return
        }
        client.responding = true
        if let id = shutdownAfter {
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.generation == id else { return }; self.shutdown()
            }
            client.deadline = deadline
            queue.asyncAfter(deadline: .now() + 5, execute: deadline)
        }
        let reason: String
        switch status { case 200: reason = "OK"; case 400: reason = "Bad Request"; case 401: reason = "Unauthorized"; case 403: reason = "Forbidden"; case 404: reason = "Not Found"; case 405: reason = "Method Not Allowed"; case 409: reason = "Conflict"; case 410: reason = "Gone"; case 413: reason = "Content Too Large"; case 429: reason = "Too Many Requests"; default: reason = "Service Unavailable" }
        var data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(content.count)\r\nCache-Control: no-store\r\nPragma: no-cache\r\nConnection: close\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n\r\n".utf8)
        data.append(content)
        client.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.close(key)
            if let id = shutdownAfter, self.generation == id { self.shutdown() }
        })
    }
    static func constantEqual(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func isPrivateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let bytes = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  String(Int(part) ?? -1) == part else { return nil }
            return UInt8(part)
        }
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168)
    }
    private static func allowedPeer(_ endpoint: NWEndpoint, permitsLoopback: Bool) -> Bool {
        guard case .hostPort(let host, _) = endpoint, case .ipv4(let address) = host else { return false }
        let value = address.rawValue.map(String.init).joined(separator: ".")
        return isPrivateIPv4(value) || (permitsLoopback && value == "127.0.0.1")
    }
    static func privateIPv4Addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result = Set<String>(), cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let entry = current.pointee
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("ap") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil else { continue }
            let value = String(cString: buffer)
            if isPrivateIPv4(value) { result.insert(value) }
        }
        return result.sorted()
    }
}

struct ReadPicoWeReadPhoneHTTPRequest {
    let method: String, path: String, headers: [String: String], body: Data
    enum Parse { case incomplete, invalid(Int), request(ReadPicoWeReadPhoneHTTPRequest) }
    static func parse(_ data: Data) -> Parse {
        guard let separator = data.range(of: Data([13, 10, 13, 10])) else { return data.count > 4096 ? .invalid(413) : .incomplete }
        guard separator.lowerBound <= 4096,
              let head = String(data: data[..<separator.lowerBound], encoding: .ascii) else { return .invalid(400) }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .invalid(400) }
        let fields = first.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[2] == "HTTP/1.1", !fields[0].isEmpty,
              fields[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              fields[1] == "/" || fields[1] == "/api/weread/authorize" else { return .invalid(400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { return .invalid(400) }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  headers[name] == nil, value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { return .invalid(400) }
            headers[name] = value
        }
        guard headers["host"] != nil, headers["transfer-encoding"] == nil, headers["expect"] == nil else { return .invalid(400) }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.count <= 6, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let parsed = Int(raw) else { return .invalid(400) }
            length = parsed
        } else {
            guard fields[0] == "GET" else { return .invalid(400) }
            length = 0
        }
        guard length <= 1024 else { return .invalid(413) }
        let expected = separator.upperBound + length
        guard data.count >= expected else { return .incomplete }
        guard data.count == expected else { return .invalid(400) }
        return .request(Self(method: String(fields[0]), path: String(fields[1]), headers: headers, body: data[separator.upperBound..<expected]))
    }
}
