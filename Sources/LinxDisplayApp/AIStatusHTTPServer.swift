import Foundation
import LinxDisplayCore
import Network

/// 本机 AI 状态上报端点：
/// `POST http://127.0.0.1:8765/ai-status`
/// `{"source":"Codex","state":"approval","task":"…","message":"…"}`
/// 只服务于同一台 Mac 上的 AI 工具/hook，不接收局域网请求以外的配置。
final class AIStatusHTTPServer {
    static let port: UInt16 = 8765
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.lingxi.ai-status")
    private var onEvent: (@MainActor (AIStatusEntry) -> Void)?
    private(set) var isRunning = false

    func start(onEvent: @escaping @MainActor (AIStatusEntry) -> Void) {
        guard listener == nil else { return }
        self.onEvent = onEvent
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                self?.isRunning = (state == .ready)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        } catch {
            isRunning = false
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data else { connection.cancel(); return }
            let request = String(data: data, encoding: .utf8) ?? ""
            let bodyText = request.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            var entry: AIStatusEntry?
            if let body = bodyText.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                entry = AIStatusEntry(json: json)
            }
            let ok = entry != nil
            let response = ok ? "{\"ok\":true}" : "{\"ok\":false}"
            let payload = Data(response.utf8)
            let header = "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            var output = Data(header.utf8); output.append(payload)
            connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
            if let entry {
                Task { @MainActor [weak self] in self?.onEvent?(entry) }
            }
        }
    }
}
