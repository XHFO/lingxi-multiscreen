import Foundation
import LinxDisplayCore
import Network

/// 在本机 127.0.0.1 上接收小米 OAuth 回调。只监听 loopback，不暴露到局域网。
final class XiaomiOAuthCallbackServer {
    private var listener: NWListener?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var didResumeCode = false
    private var didResumeReady = false
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.lingxi.xiaomi.oauth")
    private(set) var port: UInt16 = 0

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            do {
                let listener = try NWListener(using: .tcp, on: .any)
                self.listener = listener
                self.lock.lock()
                self.readyContinuation = continuation
                self.lock.unlock()
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let value = listener.port?.rawValue else {
                            self.finishReady(.failure(XiaomiCloudError.invalidResponse)); return
                        }
                        self.port = value
                        self.finishReady(.success(value))
                    case .failed(let error):
                        self.finishReady(.failure(error))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.start(queue: queue)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func waitForCode(timeout: TimeInterval = 300) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            codeContinuation = continuation
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finishCode(.failure(XiaomiCloudError.server("小米登录超时，请重试。")))
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        finishCode(.failure(XiaomiCloudError.server("登录已取消。")))
    }

    private func finishReady(_ result: Result<UInt16, Error>) {
        lock.lock()
        guard !didResumeReady, let continuation = readyContinuation else { lock.unlock(); return }
        didResumeReady = true
        readyContinuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    private func finishCode(_ result: Result<String, Error>) {
        lock.lock()
        guard !didResumeCode, let continuation = codeContinuation else { lock.unlock(); return }
        didResumeCode = true
        codeContinuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            if error != nil { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2,
                  let components = URLComponents(string: String(parts[1])) else {
                self.respond(connection, success: false, message: "无效的回调地址。")
                return
            }
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value
            if let code, !code.isEmpty {
                self.respond(connection, success: true, message: "登录成功，请返回多屏灵犀。")
                self.finishCode(.success(code))
            } else {
                self.respond(connection, success: false, message: "没有收到小米授权码，请返回软件重试。")
                self.finishCode(.failure(XiaomiCloudError.server("小米未返回授权码。")))
            }
        }
    }

    private func respond(_ connection: NWConnection, success: Bool, message: String) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>多屏灵犀 · 小米登录</title></head>
        <body style="font-family:-apple-system;padding:48px;text-align:center">
        <h2>\(success ? "登录成功" : "登录失败")</h2><p>\(message)</p>
        <p style="color:#888">可以关闭此页面。</p></body></html>
        """
        let body = Data(html.utf8)
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(response.utf8); data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

enum XiaomiOAuthLogin {
    static func login(region: XiaomiCloudRegion, deviceID: String,
                      openURL: @escaping (URL) -> Void) async throws -> XiaomiAccount {
        let server = XiaomiOAuthCallbackServer()
        let port = try await server.start()
        defer { server.stop() }
        let redirect = "http://127.0.0.1:\(port)/callback"
        let state = UUID().uuidString
        guard let url = XiaomiCloudClient.authorizationURL(region: region, redirectURL: redirect,
                                                           deviceID: deviceID, state: state) else {
            throw XiaomiCloudError.invalidURL
        }
        openURL(url)
        let code = try await server.waitForCode()
        let client = XiaomiCloudClient()
        let account = try await client.exchangeCode(code, redirectURL: redirect,
                                                    deviceID: deviceID, region: region)
        return account
    }
}
