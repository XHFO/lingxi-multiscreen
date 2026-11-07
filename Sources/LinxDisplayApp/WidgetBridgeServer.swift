import Foundation
import Network

/// 给 WidgetKit 扩展提供只读卡片快照。只监听本机，不暴露局域网。
final class WidgetBridgeServer {
    static let port: UInt16 = 8788
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.lingxi.widget-bridge")
    private weak var model: AppModel?

    func start(model: AppModel) {
        guard listener == nil else { return }
        self.model = model
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        } catch {
            NSLog("[LinxDisplay] Widget bridge failed: \(error)")
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data,
                  let request = String(data: data, encoding: .utf8),
                  let line = request.components(separatedBy: "\r\n").first else {
                connection.cancel(); return
            }
            let parts = line.split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1]).split(separator: "?").first.map(String.init) ?? "/" : "/"
            Task { @MainActor [weak self] in
                guard let self, let model = self.model else { connection.cancel(); return }
                let body = model.widgetSnapshotJSON(path: path)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                var output = Data(header.utf8); output.append(body)
                connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
