import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LinxDisplayCore

/// Configuration stays on this Mac; only display records and action IDs go to the TF app.
/// 电脑保存启动映射，TF应用只收到显示记录与动作ID。
@MainActor final class ReadPicoDesktopConsoleSession: ObservableObject {
    struct Shortcut: Codable, Identifiable, Equatable {
        var id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24).description
        var label: String
        var application: String
        var screen: Int? = nil
    }
    private static var sessions: [String: ReadPicoDesktopConsoleSession] = [:]
    static func session(for id: String) -> ReadPicoDesktopConsoleSession {
        if let value = sessions[id] { return value }
        let value = ReadPicoDesktopConsoleSession(id: id); sessions[id] = value; return value
    }
    @Published var shortcuts: [Shortcut] = []
    @Published var selectedPort = ""
    @Published var rotated = false
    let workspace: ReadPicoWorkspaceSession
    @Published private(set) var running = false
    @Published private(set) var status = "在设备上安装并打开“桌面控制台”，然后添加电脑应用。"
    @Published private(set) var error = false
    private let key: String
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private weak var manager: ReadPicoManagerModel?
    private var identity: String?
    init(id: String) {
        key = "readpico.desktop-console." + id
        workspace = .session(for: id)
        rotated = UserDefaults.standard.bool(forKey: key + ".rotated")
        if let data = UserDefaults.standard.data(forKey: key), let values = try? JSONDecoder().decode([Shortcut].self, from: data), values.count <= 48 { shortcuts = values }
    }
    func persist() { UserDefaults.standard.set(rotated, forKey: key + ".rotated"); if let data = try? JSONEncoder().encode(shortcuts) { UserDefaults.standard.set(data, forKey: key) } }
    func add() {
        guard shortcuts.count < 48 else { status = "两屏合计最多添加 48 个快捷方式，每屏最多 24 个。"; error = true; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true; panel.prompt = "添加应用"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where shortcuts.count < 48 {
            guard !shortcuts.contains(where: { $0.application == url.path }) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            var label = ""; for char in name { if (label + String(char)).utf8.count >= 48 { break }; label.append(char) }
            shortcuts.append(.init(label: label, application: url.path, screen: shortcuts.filter { $0.screen != 1 }.count < 24 ? 0 : 1))
        }
        persist()
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil; running = false; status = "连接已停止；设备保留图标，离线点击不会执行。"; error = false }
    func start(manager: ReadPicoManagerModel) {
        stop(); self.manager = manager
        let port = selectedPort
        identity = port.isEmpty ? nil : ReadPicoUSBTransferClient.serialIdentity(port: port)
        do {
            let snapshot = shortcuts
            let items = try snapshot.filter { $0.screen != 1 }.map { value -> ReadPicoDesktopConsole.Item in
                guard URL(fileURLWithPath: value.application).pathExtension.lowercased() == "app", FileManager.default.fileExists(atPath: value.application) else { throw ReadPicoManagerError.invalid("“\(value.label)”已移动，请移除后重新添加。") }
                return .init(id: value.id, label: value.label, icon: try Self.icon(value.application))
            }
            let revision = UInt32.random(in: 1...UInt32.max)
            let payload = try ReadPicoDesktopConsole.configuration(items: items, revision: revision, rotated: rotated)
            let peerItems = try snapshot.filter { $0.screen == 1 }.map { value -> ReadPicoDesktopConsole.Item in
                guard URL(fileURLWithPath: value.application).pathExtension.lowercased() == "app", FileManager.default.fileExists(atPath: value.application) else { throw ReadPicoManagerError.invalid("“\(value.label)”已移动，请移除后重新添加。") }
                return .init(id: value.id, label: value.label, icon: try Self.icon(value.application))
            }
            let peerPayload = try ReadPicoDesktopConsole.configuration(items: peerItems, revision: revision, rotated: rotated)
            let mode = workspace.mode
            let token = UUID(); generation = token; running = true; error = false; status = "正在连接设备…"
            task = Task { [weak self, weak manager] in
                guard let self, let manager else { return }
                var nonce = Self.nonce(), gate = ReadPicoDesktopConsole.EventGate(), ack: UInt32 = 0
                var lastEndpoint = "", lastSuccess = Date.distantPast, mustSync = true
                var launchError: String?
                var pairEndpoint = ""
                gate.reset(session: nonce)
                while !Task.isCancelled && self.generation == token {
                    do {
                        guard !manager.busy, manager.store == nil else { throw ReadPicoManagerError.unavailable("固件或 TF 传输期间，控制台暂停。") }
                        let ports = ReadPicoUSBTransferClient.discoverPorts()
                        let matched = self.identity.flatMap { expected in ports.first { ReadPicoUSBTransferClient.serialIdentity(port: $0) == expected } }
                        let usb = matched ?? (self.identity == nil && ports.contains(port) ? port : nil)
                        let endpoint: ReadPicoDesktopConsole.Endpoint
                        let endpointID: String
                        if let usb { endpoint = .usb(usb); endpointID = "usb:" + usb }
                        else if let connection = manager.connection { endpoint = .lan(connection); endpointID = "lan:" + connection.baseURL.absoluteString + connection.setupKey }
                        else { throw ReadPicoManagerError.unavailable("电脑离线；请选择 USB 设备，或先在设备设置完成局域网配对。") }
                        if endpointID != lastEndpoint || Date().timeIntervalSince(lastSuccess) > 2.5 {
                            nonce = Self.nonce(); gate.reset(session: nonce); ack = 0; mustSync = true; pairEndpoint = ""; lastEndpoint = endpointID
                        }
                        if mode == .console, pairEndpoint != endpointID {
                            self.status = "正在同步第二台扩展按键…"
                            self.workspace.accept(try await ReadPicoWorkspace.request("M \(nonce) 2", endpoint: endpoint))
                            let workspace = self.workspace
                            let receipt = try await ReadPicoWorkspace.upload(peerPayload, revision: revision, nonce: nonce, endpoint: endpoint) { reply in
                                await workspace.accept(reply)
                            }
                            self.workspace.accept(receipt); pairEndpoint = endpointID
                        }
                        let reply = try await ReadPicoDesktopConsole.request("H \(nonce) \(revision) \(ack)", endpoint: endpoint)
                        guard !Task.isCancelled, self.generation == token, reply.session == nonce else { break }
                        if mustSync || reply.revision != revision {
                            self.status = "正在同步快捷方式…"
                            _ = try await ReadPicoDesktopConsole.request("B \(nonce) \(payload.count) \(ReadPicoDesktopConsole.crc32(payload))", endpoint: endpoint)
                            for offset in stride(from: 0, to: payload.count, by: 128) {
                                try Task.checkCancellation()
                                let block = payload[offset..<min(offset + 128, payload.count)]
                                let hex = block.map { String(format: "%02x", $0) }.joined()
                                let received = try await ReadPicoDesktopConsole.request("C \(nonce) \(offset) \(hex)", endpoint: endpoint)
                                guard received.offset == UInt32(offset + block.count) else { throw ReadPicoManagerError.invalid("设备接收位置不一致，原配置保留。") }
                            }
                            let saved = try await ReadPicoDesktopConsole.request("E \(nonce)", endpoint: endpoint)
                            guard saved.revision == revision else { throw ReadPicoManagerError.invalid("设备尚未确认保存快捷方式。") }
                            mustSync = false
                        } else if let action = gate.accept(reply, allowed: Set(snapshot.map(\.id))), let shortcut = snapshot.first(where: { $0.id == action }) {
                            // The gate records the sequence before opening; a lost ACK can never launch twice.
                            // 启动前记录序号，丢失确认也不会再次启动。
                            ack = reply.event ?? 0
                            do {
                                _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: shortcut.application), configuration: .init())
                                launchError = nil
                                self.status = "已打开“\(shortcut.label)”"; self.error = false
                            } catch { launchError = "“\(shortcut.label)”未能打开：\(error.localizedDescription)" }
                        } else if let event = reply.event, event > 0 { ack = event }
                        if mode == .console {
                            let pair = try await ReadPicoWorkspace.request("H \(nonce)", endpoint: endpoint)
                            self.workspace.accept(pair)
                            guard pair.canDeliver, pair.state == ReadPicoWorkspace.State.displayed.rawValue else { throw ReadPicoManagerError.unavailable("双机工作区已暂停；退出阅读或恢复连接后，请点击“同步并连接”。") }
                        }
                        lastSuccess = Date()
                        if let launchError { self.status = launchError; self.error = true }
                        else { self.status = endpointID.hasPrefix("usb:") ? "USB 已连接 · 点击设备图标启动应用" : "局域网已连接 · 点击设备图标启动应用"; self.error = false }
                        try await Task.sleep(nanoseconds: 400_000_000)
                    } catch {
                        if Task.isCancelled || self.generation != token { break }
                        self.status = error.localizedDescription; self.error = true
                        if mode == .console { self.running = false; break }
                        nonce = Self.nonce(); gate.reset(session: nonce); ack = 0; mustSync = true; lastEndpoint = ""; pairEndpoint = ""
                        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                    }
                }
            }
        } catch { status = error.localizedDescription; self.error = true; running = false }
    }
#if PICO_WORKSPACE_PREVIEW
    func previewState() {
        running = true; status = "USB 已连接 · 点击设备图标启动应用"; error = false
    }
#endif
    private static func nonce() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    static func applicationImage(_ path: String) -> NSImage {
        if let bundle = Bundle(path: path), let file = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let resource = bundle.resourceURL?.appendingPathComponent(file.hasSuffix(".icns") ? file : file + ".icns"),
           let image = NSImage(contentsOf: resource) { return image }
        return NSWorkspace.shared.icon(forFile: path)
    }
    static func deviceImage(_ path: String) -> NSImage {
        guard let packed = try? icon(path), let context = CGContext(data: nil, width: 32, height: 32,
            bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
            let raw = context.data?.assumingMemoryBound(to: UInt8.self) else { return applicationImage(path) }
        for (index, byte) in packed.enumerated() { raw[index * 2] = (byte >> 4) * 17; raw[index * 2 + 1] = (byte & 15) * 17 }
        guard let image = context.makeImage() else { return applicationImage(path) }
        return NSImage(cgImage: image, size: NSSize(width: 32, height: 32))
    }
    private static func icon(_ path: String) throws -> Data {
        let image = applicationImage(path)
        var rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ReadPicoManagerError.invalid("应用图标读取失败。") }
        context.setFillColor(gray: 1, alpha: 1); context.fill(rect); context.interpolationQuality = .high
        context.draw(cg, in: rect)
        guard let raw = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ReadPicoManagerError.invalid("图标灰阶转换失败。") }
        var result = Data(); for i in stride(from: 0, to: 1024, by: 2) { result.append(UInt8((min(15, (Int(raw[i]) + 8) / 17) << 4) | min(15, (Int(raw[i + 1]) + 8) / 17))) }; return result
    }
}

struct ReadPicoDesktopConsoleView: View {
    @ObservedObject var manager: ReadPicoManagerModel
    @ObservedObject private var session: ReadPicoDesktopConsoleSession
    @ObservedObject private var workspace: ReadPicoWorkspaceSession
    init(manager: ReadPicoManagerModel, deviceID: UUID?) {
        self.manager = manager
        let value = ReadPicoDesktopConsoleSession.session(for: deviceID?.uuidString ?? "standalone")
        session = value; workspace = value.workspace
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label("桌面控制台", systemImage: "rectangle.grid.2x3").font(.title2.weight(.semibold))
                        Spacer()
                        Text("Stream Deck 式快捷按键").font(.callout).foregroundStyle(.secondary)
                    }
                    connection
                    ReadPicoWorkspacePanel(session: workspace, manager: manager, port: session.selectedPort, consoleRunning: session.running)
                    if geometry.size.width >= 1020 {
                        HStack(alignment: .top, spacing: 20) {
                            shortcuts.frame(maxWidth: .infinity)
                            display.frame(width: 320)
                        }
                    } else { display; shortcuts }
                    HStack {
                        Text(session.running ? "修改后同步生效 · 离开本页仍保持连接" : "应用路径只保存在 Mac · 离线点击不执行")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if session.running { Button("停止连接") { session.stop() } }
                        Button(session.running ? "同步修改" : "同步并连接", systemImage: "arrow.triangle.2.circlepath") {
                            session.persist(); session.start(manager: manager)
                        }.buttonStyle(.borderedProminent).disabled(manager.busy || manager.store != nil || workspace.busy)
                    }
                }.padding(24)
            }
        }.onChange(of: session.shortcuts) { _, _ in session.persist() }
            .onChange(of: session.rotated) { _, _ in session.persist() }
    }
    private var connection: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: session.running && !session.error ? "cable.connector" : "desktopcomputer").font(.system(size: 20)).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.status).font(.callout.weight(.medium)).foregroundStyle(session.error ? Color.red : Color.primary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text("电脑连接 · USB 优先，支持已配对局域网").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Picker("连接设备", selection: $session.selectedPort) {
                Text("已配对局域网").tag("")
                ForEach(manager.usbPorts, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent).tag($0) }
            }.frame(width: 240).disabled(session.running)
        }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("快捷按键与顺序", systemImage: "list.number").font(.headline)
                Spacer(); Text("\(session.shortcuts.count) / 48").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("添加应用…", systemImage: "plus") { session.add() }.disabled(session.shortcuts.count >= 48)
            }
            Text("从上到下对应设备的从左到右、从上到下排列；每屏每页 6 个，左右滑动翻页。")
                .font(.caption).foregroundStyle(.secondary)
            if session.shortcuts.isEmpty {
                ContentUnavailableView("添加常用应用", systemImage: "square.grid.2x2", description: Text("选择软件后，Pico 会显示它的图标和名称。"))
                    .frame(minHeight: 180)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach($session.shortcuts) { $shortcut in
                        HStack(spacing: 10) {
                            Text(String((session.shortcuts.filter { ($0.screen ?? 0) == (shortcut.screen ?? 0) }.firstIndex { $0.id == shortcut.id } ?? 0) + 1))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                            Image(nsImage: ReadPicoDesktopConsoleSession.applicationImage(shortcut.application)).resizable().frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("显示名称", text: $shortcut.label).textFieldStyle(.roundedBorder)
                                Text(URL(fileURLWithPath: shortcut.application).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(minWidth: 120, maxWidth: .infinity)
                            Picker("显示屏幕", selection: Binding(get: { shortcut.screen ?? 0 }, set: { shortcut.screen = $0 })) {
                                Text("本机").tag(0); Text("扩展屏").tag(1)
                            }.labelsHidden().frame(width: 90).help("选择这个按键所在的设备")
                            HStack(spacing: 2) {
                                orderButton(shortcut.id, delta: -1, icon: "chevron.up", label: "上移")
                                orderButton(shortcut.id, delta: 1, icon: "chevron.down", label: "下移")
                                Button { session.shortcuts.removeAll { $0.id == shortcut.id }; session.persist() } label: { Image(systemName: "minus.circle").frame(width: 28, height: 28) }
                                    .buttonStyle(.borderless).help("移除快捷按键").accessibilityLabel("移除“\(shortcut.label)”")
                            }
                        }.padding(.vertical, 10)
                        Divider()
                    }
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1) }
    }
    private var display: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("显示与布局", systemImage: "rectangle.rotate").font(.headline)
            Picker("界面方向", selection: $session.rotated) {
                Text("竖向 · 0°").tag(false); Text("横向 · 90°").tag(true)
            }.pickerStyle(.segmented)
            Text("仅旋转桌面控制台；退出后恢复原方向。两台扩展屏保持相同布局。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            preview(screen: 0, title: "本机按键")
            if workspace.mode == .console { preview(screen: 1, title: "扩展屏按键") }
            if session.shortcuts.contains(where: { $0.screen == 1 }), workspace.mode != .console {
                Label("扩展屏有按键；选择“扩展控制台按键”后才会发送。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1) }
    }
    private func preview(screen: Int, title: String) -> some View {
        let values = session.shortcuts.filter { ($0.screen ?? 0) == screen }
        return VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.callout.weight(.medium)); Spacer(); Text("\(values.count) / 24").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: session.rotated ? 3 : 2), spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    VStack(spacing: 4) {
                        if index < values.count {
                            Image(nsImage: ReadPicoDesktopConsoleSession.deviceImage(values[index].application)).resizable().frame(width: 28, height: 28)
                            Text(values[index].label).font(.system(size: 11)).lineLimit(1)
                        } else { Image(systemName: "plus").foregroundStyle(.tertiary).font(.caption); Text("空位").font(.system(size: 11)).foregroundStyle(.tertiary) }
                    }.frame(maxWidth: .infinity, minHeight: 56).padding(5)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(Color.black)
                        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(index < values.count ? 0.65 : 0.12), lineWidth: 1) }
                }
            }.padding(10).background(Color(white: 0.95), in: RoundedRectangle(cornerRadius: 10))
            if values.count > 6 { Text("第 1 / \((values.count + 5) / 6) 页").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
        }
    }
    private func orderButton(_ id: String, delta: Int, icon: String, label: String) -> some View {
        let index = session.shortcuts.firstIndex { $0.id == id } ?? 0
        return Button { move(id, by: delta) } label: { Image(systemName: icon).frame(width: 28, height: 28) }
            .buttonStyle(.borderless).disabled(!session.shortcuts.indices.contains(index + delta))
            .help(label).accessibilityLabel(label + "快捷按键")
    }
    private func move(_ id: String, by delta: Int) {
        guard let index = session.shortcuts.firstIndex(where: { $0.id == id }), session.shortcuts.indices.contains(index + delta) else { return }
        session.shortcuts.swapAt(index, index + delta); session.persist()
    }
}
