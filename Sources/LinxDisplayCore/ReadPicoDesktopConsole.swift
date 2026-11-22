import Foundation
import Darwin

/// Bounded data-only console. Executable mappings never enter the device payload.
/// 有界数据控制台；设备只接收动作ID、名称与图标，不接收程序路径。
private final class ConsoleNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum ReadPicoDesktopConsole {
    public static let maximumItems = 24
    public struct Item: Sendable {
        public var id: String, label: String, icon: Data
        public init(id: String, label: String, icon: Data) { self.id = id; self.label = label; self.icon = icon }
    }
    public struct Reply: Decodable, Sendable {
        public let console: Bool, ok: Bool
        public let error: String?
        public let session: String?
        public let revision: UInt32?, offset: UInt32?, event: UInt32?, action: String?, online: Bool?
    }
    public enum Endpoint: Sendable { case usb(String), lan(ReadPicoConnection) }
    public static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320) } }
        return ~crc
    }
    public static func configuration(items: [Item], revision: UInt32, rotated: Bool = false) throws -> Data {
        guard items.count <= maximumItems, Set(items.map(\.id)).count == items.count else { throw ReadPicoManagerError.invalid("桌面控制台最多保留 24 个不同快捷方式。") }
        var data = Data()
        func u32(_ v: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: v >> shift)) } }
        func fixed(_ value: String, _ size: Int) { let raw = Data(value.utf8); data.append(raw); data.append(Data(repeating: 0, count: size - raw.count)) }
        u32(0x31434350); u32(revision); data.append(contentsOf: [1, 0, UInt8(items.count), 0]); u32(rotated ? 1 : 0)
        for item in items {
            guard !item.id.isEmpty, item.id.utf8.count < 32,
                  item.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
                  !item.label.isEmpty, item.label.utf8.count < 48,
                  item.label.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }), item.icon.count == 512 else {
                throw ReadPicoManagerError.invalid("快捷方式名称过长或图标损坏，请缩短名称后重试。")
            }
            fixed(item.id, 32); fixed(item.label, 48); data.append(item.icon)
        }
        data.append(Data(repeating: 0, count: (maximumItems - items.count) * 592)); return data
    }
    /// Record before launching; duplicates and old sequences cannot execute twice.
    public struct EventGate: Sendable {
        public private(set) var session = ""
        private var seen: UInt32 = 0
        public init() {}
        public mutating func reset(session: String) { self.session = session; seen = 0 }
        public mutating func accept(_ reply: Reply, allowed: Set<String>) -> String? {
            guard reply.ok, reply.session == session, reply.online == true,
                  let event = reply.event, event > seen, let action = reply.action, allowed.contains(action) else { return nil }
            seen = event; return action
        }
    }
    public static func request(_ command: String, endpoint: Endpoint) async throws -> Reply {
        let bytes = try await requestData(command, endpoint: endpoint)
        let reply = try JSONDecoder().decode(Reply.self, from: bytes)
        guard reply.console, reply.ok else { throw ReadPicoManagerError.unavailable(replyError(reply.error)) }
        return reply
    }
    public static func requestData(_ command: String, endpoint: Endpoint, workspace: Bool = false) async throws -> Data {
        guard command.utf8.count < 400, command.utf8.allSatisfy({ (32...126).contains($0) }) else { throw ReadPicoManagerError.invalid("控制台请求超出限制。") }
        let bytes: Data
        switch endpoint {
        case .usb(let port):
            let task = Task.detached { try serial(command, port: port, workspace: workspace) }
            bytes = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        case .lan(let connection):
            var components = URLComponents(url: connection.baseURL.appendingPathComponent(workspace ? "api/manage/pico/workspace" : "api/manage/pico/console"), resolvingAgainstBaseURL: false)!
            if let preview = connection.previewSession { components.queryItems = [.init(name: "session", value: preview)] }
            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"; request.httpBody = Data(command.utf8); request.timeoutInterval = 4
            request.setValue(connection.setupKey, forHTTPHeaderField: "X-Pico-Setup-Key")
            request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            let session = URLSession(configuration: .ephemeral, delegate: ConsoleNoRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ReadPicoManagerError.unavailable("设备未返回控制台状态。") }
            guard data.count <= 4096 else { throw ReadPicoManagerError.invalid("控制台响应过大。") }
            if http.statusCode == 401 || http.statusCode == 403 { throw ReadPicoManagerError.expired }
            bytes = data
        }
        return bytes
    }
    private static func replyError(_ error: String?) -> String {
        switch error { case "open_console": return "请在设备上打开 TF“桌面控制台”，并确认已更新配套固件。"
        case "storage": return "设备保存失败，原配置已保留；请检查 TF 卡后重试。"
        case "expired": return "控制台连接已断开，正在重新连接。"
        default: return "控制台同步未完成（\(error ?? "连接异常")），原配置保留。" }
    }
    private static func serial(_ text: String, port: String, workspace: Bool) throws -> Data {
        guard port.hasPrefix("/dev/cu.usbmodem"), !port.dropFirst(5).contains("/") else { throw ReadPicoManagerError.invalid("请选择小纸 Pico 的 USB 串口。") }
        let lease = try ReadPicoUSBSerialLease.acquire(path: port); defer { lease.release() }
        let fd = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw ReadPicoManagerError.unavailable("USB 尚未连接。") }; defer { Darwin.close(fd) }
        guard Darwin.ioctl(fd, TIOCEXCL) == 0 else { throw ReadPicoManagerError.unavailable("USB 正在使用，控制台已暂停。") }
        var config = termios(); guard tcgetattr(fd, &config) == 0 else { throw POSIXError(.EIO) }
        cfmakeraw(&config); config.c_cflag |= tcflag_t(CLOCAL | CREAD); config.c_cflag &= ~tcflag_t(HUPCL)
        guard cfsetspeed(&config, speed_t(B115200)) == 0, tcsetattr(fd, TCSANOW, &config) == 0 else { throw POSIXError(.EIO) }
        let command = Data("\nRPICO \(workspace ? "WORKSPACE" : "CONSOLE") \(text)\n".utf8), deadline = Date().addingTimeInterval(3)
        var sent = 0, line = Data(), buffer = [UInt8](repeating: 0, count: 512)
        while Date() < deadline {
            try Task.checkCancellation()
            if sent < command.count {
                let n = command.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), command.count - sent) }
                if n > 0 { sent += n } else if n < 0 && errno != EAGAIN && errno != EINTR { throw POSIXError(.EIO) }
            }
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 { for byte in buffer.prefix(n) {
                if byte == 10 {
                    if let text = String(data: line, encoding: .utf8), text.hasPrefix("RPICO "),
                       let data = String(text.dropFirst(6)).data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object[workspace ? "workspace" : "console"] as? Bool == true { return data }
                    line.removeAll(keepingCapacity: true)
                } else if byte != 13 { line.append(byte); if line.count > 4096 { line.removeAll(keepingCapacity: true) } }
            } } else if n < 0 && errno != EAGAIN && errno != EINTR { throw POSIXError(.EIO) }
            usleep(10_000)
        }
        throw ReadPicoManagerError.unavailable("控制台未响应，请确认设备已打开应用且没有进行固件或 TF 传输。")
    }
}

/// 中文：配对状态来自设备认证链路；电脑连接和双机连接分开呈现。
/// English: Pair state comes from the authenticated device link, separately from the computer connection.
public enum ReadPicoWorkspace {
    public enum Mode: Int, Codable, CaseIterable, Sendable { case independent = 0, board = 1, console = 2 }
    public enum State: Int, Sendable { case idle, waiting, sending, receiving, saved, displayed, error, busy }
    public struct Reply: Decodable, Sendable {
        public let workspace: Bool, ok: Bool
        public let error: String?
        public let `protocol`: Int?
        public let paired: Bool?, connected: Bool?, reading: Bool?
        public let role: Int?, mode: Int?, state: Int?, peer_state: Int?
        public let done: Int?, total: Int?, revision: UInt32?
        public var fraction: Double? {
            guard let done, let total, total > 0, done >= 0, done <= total else { return nil }
            return Double(done) / Double(total)
        }
        public var canDeliver: Bool { paired == true && connected == true && reading == false }
    }
    public static func request(_ command: String, endpoint: ReadPicoDesktopConsole.Endpoint) async throws -> Reply {
        let data = try await ReadPicoDesktopConsole.requestData(command, endpoint: endpoint, workspace: true)
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.workspace, reply.ok, reply.protocol == 1 else {
            let message: String
            switch reply.error {
            case "reading": message = "设备正在阅读、锁屏或使用 TF 卡，工作区同步已暂停。退出后重新同步即可。"
            case "not_connected": message = "两台设备尚未建立连接；请先在设备“连接 → 双设备阅读”中连接原配对。"
            case "owned": message = "另一端正在管理这个工作区，请先停止另一台电脑的连接。"
            case "checksum": message = "内容校验未通过，第二台保留原内容，请重新同步。"
            default: message = "双机工作区需要两台升级到配套固件，并安装新版桌面控制台 TF 组件。"
            }
            throw ReadPicoManagerError.unavailable(message)
        }
        return reply
    }
    /// 中文：只在用户显式同步后传输；完整CRC与设备完成回执才确认接收。
    /// English: Transfer only after explicit synchronization; CRC and the peer's completion receipt confirm reception.
    public static func upload(_ payload: Data, revision: UInt32, nonce: String,
                              endpoint: ReadPicoDesktopConsole.Endpoint,
                              progress: @Sendable (Reply) async -> Void) async throws -> Reply {
        guard !payload.isEmpty, payload.count <= 65536 else { throw ReadPicoManagerError.invalid("双机工作区只接受不超过 64 KiB 的语义画板或按键配置。") }
        _ = try await request("B \(nonce) \(payload.count) \(ReadPicoDesktopConsole.crc32(payload)) \(revision)", endpoint: endpoint)
        for offset in stride(from: 0, to: payload.count, by: 128) {
            try Task.checkCancellation()
            let block = payload[offset..<min(offset + 128, payload.count)]
            _ = try await request("C \(nonce) \(offset) \(block.map { String(format: "%02x", $0) }.joined())", endpoint: endpoint)
        }
        var reply = try await request("E \(nonce)", endpoint: endpoint)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try Task.checkCancellation(); await progress(reply)
            guard reply.connected == true, reply.reading == false else { throw ReadPicoManagerError.unavailable("双机连接已中断或进入阅读；本次同步停止，原内容保留。") }
            if reply.state == State.displayed.rawValue { return reply }
            if reply.state == State.error.rawValue || reply.state == State.busy.rawValue {
                throw ReadPicoManagerError.unavailable("第二台暂未完成展示；请确认配套 TF 组件、剩余空间和设备页面，再重新同步。")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
            reply = try await request("H \(nonce)", endpoint: endpoint)
        }
        throw ReadPicoManagerError.unavailable("等待第二台展示超时；内容可能已保存，请核对设备后再操作。")
    }
}
