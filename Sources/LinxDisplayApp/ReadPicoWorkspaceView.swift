import SwiftUI
import LinxDisplayCore

/// 中文：电脑连接不等于双机已连接，状态始终由配对设备回执确认。
/// English: A computer connection is not a paired-reader connection; receipts remain authoritative.
@MainActor final class ReadPicoWorkspaceSession: ObservableObject {
    private static var sessions: [String: ReadPicoWorkspaceSession] = [:]
    static func session(for id: String) -> ReadPicoWorkspaceSession {
        if let value = sessions[id] { return value }
        let value = ReadPicoWorkspaceSession(id: id); sessions[id] = value; return value
    }
    @Published var mode: ReadPicoWorkspace.Mode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: key) } }
    @Published private(set) var snapshot: ReadPicoWorkspace.Reply?
    @Published private(set) var busy = false
    @Published private(set) var message = "读取状态后可查看配对和连接情况。"
    @Published private(set) var isError = false
    private let key: String
    private var task: Task<Void, Never>?
    init(id: String) {
        key = "readpico.workspace.mode." + id
        mode = ReadPicoWorkspace.Mode(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .independent
    }
    static func endpoint(manager: ReadPicoManagerModel, port: String) throws -> ReadPicoDesktopConsole.Endpoint {
        if !port.isEmpty, manager.usbPorts.contains(port) { return .usb(port) }
        if let connection = manager.connection { return .lan(connection) }
        throw ReadPicoManagerError.unavailable("请选择这台 Pico 的 USB 端口，或完成它与电脑的局域网配对。")
    }
    func accept(_ value: ReadPicoWorkspace.Reply) {
        snapshot = value; isError = false
        if value.reading == true { message = "阅读或锁屏中 · 工作区传输暂停" }
        else if value.connected != true { message = value.paired == true ? "已配置双机 · 等待另一台连接" : "尚未配置双机" }
        else {
            switch value.state.flatMap(ReadPicoWorkspace.State.init(rawValue:)) {
            case .sending: message = "正在发送到第二台…"
            case .receiving: message = "正在接收配置…"
            case .saved: message = "第二台已接收 · 等待实际显示"
            case .displayed: message = "第二台已接收并确认显示"
            case .error: message = "第二台同步失败，请检查 TF 组件后重试"; isError = true
            case .busy: message = "第二台正忙，原内容保留"; isError = true
            default: message = "双机已连接 · 可以同步工作区"
            }
        }
    }
    func refresh(manager: ReadPicoManagerModel, port: String) {
        guard !busy, !manager.busy, manager.store == nil else { return }
        busy = true; message = "正在读取配对设备状态…"; isError = false
        task = Task { [weak self] in
            guard let self else { return }; defer { self.busy = false }
            do { self.accept(try await ReadPicoWorkspace.request("S", endpoint: Self.endpoint(manager: manager, port: port))) }
            catch { self.message = error.localizedDescription; self.isError = true }
        }
    }
    func sendBoard(_ model: Data, revision: UInt32, manager: ReadPicoManagerModel, port: String) {
        guard mode == .board, !busy, !manager.busy, manager.store == nil else { return }
        busy = true; isError = false; message = "正在连接第二台…"
        task = Task { [weak self] in
            guard let self else { return }; defer { self.busy = false }
            do {
                let endpoint = try Self.endpoint(manager: manager, port: port)
                let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                self.accept(try await ReadPicoWorkspace.request("M \(nonce) 1", endpoint: endpoint))
                let session = self
                let result = try await ReadPicoWorkspace.upload(model, revision: revision, nonce: nonce, endpoint: endpoint) { reply in
                    await session.accept(reply)
                }
                self.accept(result)
            } catch { self.message = error.localizedDescription; self.isError = true }
        }
    }
    func stopExtension(manager: ReadPicoManagerModel, port: String) {
        guard !busy else { return }
        busy = true
        task = Task { [weak self] in
            guard let self else { return }; defer { self.busy = false }
            do { let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(); self.accept(try await ReadPicoWorkspace.request("M \(nonce) 0", endpoint: Self.endpoint(manager: manager, port: port))); self.mode = .independent }
            catch { self.message = error.localizedDescription; self.isError = true }
        }
    }
}

struct ReadPicoWorkspacePanel: View {
    @ObservedObject var session: ReadPicoWorkspaceSession
    @ObservedObject var manager: ReadPicoManagerModel
    var port: String
    var consoleRunning = false
    private var pairTitle: String {
        guard let snapshot = session.snapshot else { return "双设备工作区" }
        if snapshot.connected == true { return "双设备已连接" }
        return snapshot.paired == true ? "双设备已配对 · 等待连接" : "尚未配置双设备"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 18, weight: .medium)).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pairTitle).font(.headline)
                    Text("电脑连接与两台 Pico 的蓝牙连接分别管理").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if session.busy { ProgressView().controlSize(.small) }
                Button("读取状态", systemImage: "arrow.clockwise") { session.refresh(manager: manager, port: port) }
                    .disabled(session.busy || manager.busy || manager.store != nil || consoleRunning)
            }
            Divider()
            Picker("第二台设备", selection: $session.mode) {
                Text("保持独立").tag(ReadPicoWorkspace.Mode.independent)
                Text("接收灵犀画板").tag(ReadPicoWorkspace.Mode.board)
                Text("扩展控制台按键").tag(ReadPicoWorkspace.Mode.console)
            }.pickerStyle(.menu).disabled(session.busy || consoleRunning)
            Text(session.mode == .console ? "每台最多 24 个按键；在下方选择按键所属屏幕。扩展屏点击经原配对蓝牙转发，应用只由这台 Mac 执行一次。" : session.mode == .board ? "发送当前语义画板到另一台，完整校验后打开灵犀画板。阅读、锁屏或 TF 占用时暂停，保留原内容。" : "不自动打开另一台；已有扩展请点击“停止扩展”。选择用途后再显式同步，不解除配对或修改阅读记录。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let value = session.snapshot, value.state == ReadPicoWorkspace.State.sending.rawValue, let fraction = value.fraction {
                ProgressView(value: fraction) { Text("第二台接收进度").font(.caption) } currentValueLabel: { Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
            }
            HStack(alignment: .top) {
                Label(session.message, systemImage: session.isError ? "exclamationmark.circle" : "info.circle")
                    .font(.caption).foregroundStyle(session.isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 8)
                if session.snapshot?.mode != 0, session.snapshot != nil {
                    Button("停止扩展") { session.stopExtension(manager: manager, port: port) }.disabled(session.busy || consoleRunning)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1) }
    }
}
