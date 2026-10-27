import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import LinxDisplayCore

private enum ReadPicoInformationSource: String, CaseIterable, Identifiable {
    case clock, weather, music, system, home, image
    var id: String { rawValue }
    var title: String {
        switch self { case .clock: return "日期与时间"; case .weather: return "天气"; case .music: return "正在播放"; case .system: return "Mac 系统监控"; case .home: return "Home Assistant"; case .image: return "图片" }
    }
    var symbol: String {
        switch self { case .clock: return "clock"; case .weather: return "cloud.sun"; case .music: return "music.note"; case .system: return "desktopcomputer"; case .home: return "house"; case .image: return "photo" }
    }
}

/// Scheduling is deliberately scoped to this open page and its paired manager.
/// A persisted interval never starts network requests by itself.
@MainActor final class ReadPicoInformationPushSession: ObservableObject {
    @Published private(set) var preview: NSImage?
    @Published private(set) var bitmap: Data?
    @Published private(set) var unavailableReason: String?
    @Published private(set) var status = "可先在本地预览，连接阅读器后再推送。"
    @Published private(set) var error = false
    @Published private(set) var automatic = false
    @Published private(set) var nextUpdate: Date?
    @Published private(set) var lastConfirmed: Date?
    private var timer: Task<Void, Never>?
    private var active = false
    private var generation = UUID()
    private var ownsPush = false
    private var provider: (() throws -> (ReadPicoInformationRenderer.Result, String?))?
    private weak var manager: ReadPicoManagerModel?

    func activate(manager: ReadPicoManagerModel,
                  provider: @escaping () throws -> (ReadPicoInformationRenderer.Result, String?)) {
        self.manager = manager; self.provider = provider; active = true
        refresh()
    }
    func refresh() {
        do {
            guard let provider else { return }
            let (frame, unavailable) = try provider()
            preview = frame.preview; bitmap = frame.transferData; unavailableReason = unavailable
        } catch {
            bitmap = nil; unavailableReason = error.localizedDescription
            status = error.localizedDescription; self.error = true
        }
    }
    func sourceChanged() {
        stopAutomatic(message: "来源已更新；如需定时推送，请重新开始。")
        refresh()
    }
    func startAutomatic(interval: Int) {
        guard active, interval >= 60, let manager, manager.connection != nil,
              !manager.busy, manager.capability?.supported == true else { return }
        refresh()
        guard unavailableReason == nil, bitmap != nil else { return }
        timer?.cancel(); automatic = true; error = false
        status = "本页打开期间定时推送；离开页面会停止。"
        schedule(after: interval)
    }
    private func schedule(after interval: Int) {
        guard automatic, active else { return }
        let token = generation
        nextUpdate = Date().addingTimeInterval(TimeInterval(interval))
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000) }
            catch { return }
            guard let self, self.active, self.automatic, self.generation == token else { return }
            guard self.manager?.busy == false else {
                self.status = "设备正在处理其他操作，已顺延本次更新。"
                self.schedule(after: interval); return
            }
            self.send(repeatingEvery: interval)
        }
    }
    func send(repeatingEvery interval: Int? = nil) {
        guard active, let manager, !manager.busy else { return }
        guard manager.connection != nil, manager.capability?.supported == true else {
            stopAutomatic(message: "尚未连接支持信息推送的阅读器，请先到设备设置配对。", isError: true)
            return
        }
        refresh()
        guard unavailableReason == nil, let bitmap else {
            stopAutomatic(message: unavailableReason ?? "没有可推送的画面。", isError: true)
            return
        }
        // Freeze the bitmap now. Later model samples cannot replace an in-flight request.
        let token = generation
        ownsPush = true; error = false; status = "正在推送，等待阅读器确认显示…"; nextUpdate = nil
        manager.sendBoard(bitmap, display: interval == nil) { [weak self, weak manager] succeeded in
            guard let self, self.active, self.generation == token else { return }
            self.ownsPush = false
            if succeeded {
                if manager?.boardDelivery?.displayed == true { self.lastConfirmed = Date() }
                self.error = false
                self.status = manager?.boardDelivery?.displayed == true
                    ? "阅读器已确认显示，横竖屏画面均已保存。"
                    : "横竖屏画面已后台保存，阅读器保留当前页面。"
                if let interval, self.automatic { self.schedule(after: interval) }
            } else {
                self.stopAutomatic(message: manager?.message ?? "尚未确认显示，请检查设备连接后重试。", isError: manager?.isError ?? true)
            }
        }
    }
    func stopAutomatic(message: String = "已停止本次定时推送。", isError: Bool = false) {
        timer?.cancel(); timer = nil; automatic = false; nextUpdate = nil
        status = message; error = isError
    }
    func disappear() {
        active = false; generation = UUID(); timer?.cancel(); timer = nil
        automatic = false; nextUpdate = nil; provider = nil
        if ownsPush, manager?.canCancel == true { manager?.cancelOperation() }
        ownsPush = false
    }
}

struct ReadPicoInformationPushView: View {
    @ObservedObject private var model: AppModel
    private let deviceID: UUID
    @ObservedObject private var drafts: ReadPicoDraftGuard
    @ObservedObject private var manager: ReadPicoManagerModel
    @StateObject private var session = ReadPicoInformationPushSession()
    @State private var options: ReadPicoInformationPushSettings
    @State private var selectedImage: NSImage?
    @State private var imageName = ""
    @State private var entitySearch = ""
    @State private var previewTask: Task<Void, Never>?

    init(model: AppModel, deviceID: UUID, drafts: ReadPicoDraftGuard) {
        self.model = model; self.deviceID = deviceID; self.drafts = drafts
        _manager = ObservedObject(wrappedValue: drafts.model)
        let saved = model.settings.devices.first { $0.id == deviceID }?.settings.readPico?.informationPush ?? .init()
        _options = State(initialValue: saved)
    }
    private var source: ReadPicoInformationSource { .init(rawValue: options.source) ?? .clock }
    private var canPush: Bool {
        manager.connection != nil && manager.capability?.supported == true && manager.capability?.revision != nil
            && !manager.busy && session.bitmap != nil && session.unavailableReason == nil
    }
    private var entityCandidates: [HAEntity] {
        model.haSnapshot.entities.filter {
            entitySearch.isEmpty || $0.displayName.localizedCaseInsensitiveContains(entitySearch) || $0.entityId.localizedCaseInsensitiveContains(entitySearch)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("将多屏灵犀的信息生成墨水屏画面，推送后可离线保留。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if geometry.size.width >= 780 {
                        HStack(alignment: .top, spacing: 24) {
                            controls.frame(width: 300)
                            previewPane.frame(maxWidth: .infinity)
                        }
                    } else {
                        controls
                        previewPane
                    }
                    deliveryPane
                }.padding(20)
            }
        }
        .onAppear { activate() }
        .onDisappear { previewTask?.cancel(); previewTask = nil; session.disappear() }
        .onChange(of: options) { _, new in
            model.updateReadPicoInformationPush(deviceID: deviceID, settings: new)
            if new.source == "system" { model.refreshReadPicoSystemSnapshot() }
            session.sourceChanged()
        }
        .onChange(of: selectedImage) { _, _ in session.sourceChanged() }
        .onReceive(model.$nowPlaying) { _ in if source == .music { queuePreview() } }
        .onReceive(model.$system) { _ in if source == .system { queuePreview() } }
        .onReceive(model.$haSnapshot) { _ in if source == .home { queuePreview() } }
        .onReceive(model.objectWillChange) { _ in if source == .weather { queuePreview() } }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                if source == .clock { session.refresh() }
                if source == .system { model.refreshReadPicoSystemSnapshot() }
            }
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("信息来源") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("显示内容", selection: $options.source) {
                        ForEach(ReadPicoInformationSource.allCases) { item in Label(item.title, systemImage: item.symbol).tag(item.rawValue) }
                    }
                    sourceOptions
                }.padding(8)
            }
            GroupBox("屏幕画面") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("预览方向", selection: $options.landscape) { Text("竖屏").tag(false); Text("横屏").tag(true) }
                    Text("每次发送 684 × 1216 竖版与 1216 × 684 横版，均为原生 16 级灰阶。设备旋转时自动切换；这里仅选择预览方向。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }
            GroupBox("更新方式") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("推送间隔", selection: $options.intervalSeconds) {
                        Text("仅手动").tag(0); Text("每分钟").tag(60); Text("每 5 分钟").tag(300)
                        Text("每 15 分钟").tag(900); Text("每 30 分钟").tag(1800); Text("每小时").tag(3600)
                    }
                    if options.intervalSeconds > 0 {
                        if session.automatic {
                            Button("停止本次定时推送", systemImage: "pause.circle") { session.stopAutomatic() }
                        } else {
                            Button("开始本次定时推送", systemImage: "arrow.clockwise.circle") { session.startAutomatic(interval: options.intervalSeconds) }
                                .disabled(!canPush)
                        }
                    }
                    Text("定时更新仅在本页打开、Mac 正在运行且设备保持配对时生效。离开页面、连接失效或推送失败后停止。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }
        }.disabled(manager.busy)
    }
    @ViewBuilder private var sourceOptions: some View {
        switch source {
        case .clock:
            Text("使用 Mac 当前日期与时间。设备显示最后一次推送的时刻。")
                .font(.callout).foregroundStyle(.secondary)
        case .weather:
            Text(model.settings.weatherSnapshot.map { "\($0.city) · \($0.description) · \(Int($0.temperature.rounded()))°" } ?? "尚无天气数据，请先在多屏灵犀的天气页选择城市。")
                .font(.callout).foregroundStyle(.secondary)
            Button(model.weatherBusy ? "正在更新天气…" : "获取最新天气") { Task { await model.refreshWeather(); session.refresh() } }
                .disabled(model.weatherBusy || !model.settings.weather.isValid)
        case .music:
            Text("共享系统“正在播放”的标题、歌手、专辑与封面。媒体暂停时保留真实播放状态。")
                .font(.callout).foregroundStyle(.secondary)
        case .system:
            Text("共享多屏灵犀采集的 CPU、内存、磁盘和网络速率；画面标明采样时间。")
                .font(.callout).foregroundStyle(.secondary)
        case .home:
            homeOptions
        case .image:
            Button("选择图片…", systemImage: "photo") { chooseImage() }
            Text(selectedImage == nil ? "选择本机图片，按屏幕比例完整显示。图片仅保留在本次页面会话内。" : imageName)
                .font(.callout).foregroundStyle(.secondary).lineLimit(3)
        }
    }
    private var homeOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("从多屏灵犀已连接的 Home Assistant 选择最多 6 个实体。仅推送状态，不触发实体控制。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("查找实体", text: $entitySearch).textFieldStyle(.roundedBorder)
            if model.haSnapshot.entities.isEmpty {
                Text("尚无实体，请先在 Home Assistant 设备页连接服务器。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(entityCandidates.prefix(80)), id: \.entityId) { entity in
                            Toggle(isOn: Binding(get: { options.entityIDs.contains(entity.entityId) }, set: { selected in
                                if selected, options.entityIDs.count < 6 { options.entityIDs.append(entity.entityId) }
                                else if !selected { options.entityIDs.removeAll { $0 == entity.entityId } }
                            })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entity.displayName).lineLimit(1)
                                    Text(entity.entityId).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.toggleStyle(.checkbox)
                                .disabled(!options.entityIDs.contains(entity.entityId) && options.entityIDs.count >= 6)
                        }
                    }.padding(.vertical, 4)
                }.frame(maxHeight: 210)
                if entityCandidates.count > 80 { Text("找到 \(entityCandidates.count) 个实体，请输入名称缩小范围。") .font(.caption).foregroundStyle(.secondary) }
            }
            if !options.entityIDs.isEmpty {
                Text("已选 \(options.entityIDs.count)/6 项").font(.caption).foregroundStyle(.secondary)
                Button("清空选择") { options.entityIDs = [] }
            }
            Button("刷新实体状态", systemImage: "arrow.clockwise") { Task { await model.refreshHA(includePictures: false); session.refresh() } }
                .disabled(!model.haServerConfigured)
        }
    }
    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("设备画面预览").font(.headline)
                Spacer()
                Button("刷新预览", systemImage: "arrow.clockwise") { refreshPreview() }.disabled(manager.busy)
            }
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let preview = session.preview {
                    Image(nsImage: preview).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                        .padding(14).accessibilityLabel("小纸 Pico 黑白画面，\(source.title)")
                } else { ProgressView("正在生成预览…") }
            }.frame(height: options.landscape ? 310 : 470)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if let reason = session.unavailableReason {
                Label(reason, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var deliveryPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                if manager.connection != nil {
                    Label("已配对当前阅读器", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    Label("请先在此设备的“设备设置”中完成配对", systemImage: "link").foregroundStyle(.secondary)
                }
                Spacer()
                if manager.busy {
                    ProgressView().controlSize(.small)
                    if manager.canCancel { Button(manager.cancelTitle) { manager.cancelOperation() } }
                }
                Button("立即推送", systemImage: "paperplane") { session.send() }
                    .buttonStyle(.borderedProminent).disabled(!canPush)
            }
            Label(manager.busy ? manager.message : session.status,
                  systemImage: session.error ? "exclamationmark.circle" : "info.circle")
                .font(.callout).foregroundStyle(session.error ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let date = session.lastConfirmed {
                Text("已确认显示：\(date.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let next = session.nextUpdate {
                Text("下次更新：\(next.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("阅读器需保持“手机与电脑管理”服务开启。信息推送使用 TF 卡离线画布，与自定义图片锁屏分别管理；最后一张画面不会随网络状态自动更新。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func activate() {
        if source == .system { model.refreshReadPicoSystemSnapshot() }
        session.activate(manager: manager) {
            let frame = makeFrame()
            return (try ReadPicoInformationRenderer.render(frame, landscape: options.landscape, dither: options.dither), frame.unavailableReason)
        }
    }
    private func refreshPreview() {
        if source == .system { model.refreshReadPicoSystemSnapshot() }
        previewTask?.cancel(); previewTask = nil
        session.refresh()
    }
    private func queuePreview() {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            session.refresh()
        }
    }
    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        selectedImage = image; imageName = url.lastPathComponent
    }
    private func makeFrame() -> ReadPicoInformationFrame {
        let now = Date()
        switch source {
        case .clock:
            let clock = DateFormatter(); clock.dateFormat = "HH:mm"
            let date = DateFormatter(); date.locale = Locale(identifier: "zh_CN"); date.dateFormat = "yyyy 年 M 月 d 日  EEEE"
            return ReadPicoInformationFrame(layout: .clock, title: "日期与时间", subtitle: "来自 Mac 的当前时间", primary: clock.string(from: now), rows: [.init(label: "日期", value: date.string(from: now))], sampledAt: now)
        case .weather:
            guard let value = model.settings.weatherSnapshot else {
                return .init(title: "天气", unavailableReason: "尚无天气数据，请在多屏灵犀选择天气城市并更新。")
            }
            return .init(title: value.city, subtitle: value.description + (value.isStale ? " · 缓存时间较早" : ""), primary: "\(Int(value.temperature.rounded()))°", rows: [
                .init(label: "体感温度", value: "\(Int(value.apparent.rounded()))°"),
                .init(label: "今日温度", value: "\(Int(value.low.rounded()))° / \(Int(value.high.rounded()))°"),
                .init(label: "降水概率", value: "\(value.rainProbability)%")], sampledAt: value.updatedAt, footer: "天气 · Open-Meteo")
        case .music:
            let value = model.nowPlaying
            guard value != .placeholder else { return .init(title: "正在播放", unavailableReason: "Mac 当前没有可用的媒体信息，请先在播放器开始播放。") }
            let cgImage = value.artwork.flatMap { NSImage(data: $0) }?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return .init(layout: .media, title: value.isPlaying ? "正在播放" : "已暂停", subtitle: value.appName ?? "Mac 系统播放器", primary: value.title, rows: [
                .init(label: "歌手", value: value.artist), .init(label: "专辑", value: value.album),
                .init(label: "播放进度", value: "\(duration(value.effectiveElapsed(at: now))) / \(duration(value.duration))")], image: cgImage, sampledAt: value.sampledAt)
        case .system:
            let value = model.system
            guard value.totalMemoryBytes > 0 else { return .init(title: "Mac 系统监控", unavailableReason: "尚未取得系统采样，请稍后刷新。") }
            return .init(title: "Mac 系统监控", subtitle: ProcessInfo.processInfo.hostName, rows: [
                .init(label: "CPU", value: String(format: "%.0f%%", value.cpuPercent)),
                .init(label: "内存", value: String(format: "%.0f%%", value.memoryPercent)),
                .init(label: "磁盘", value: String(format: "%.0f%%", value.diskPercent)),
                .init(label: "下载", value: "\(bytes(value.downloadBytesPerSecond)) / s"),
                .init(label: "上传", value: "\(bytes(value.uploadBytesPerSecond)) / s")], sampledAt: value.sampledAt)
        case .home:
            guard !options.entityIDs.isEmpty else { return .init(title: "Home Assistant", unavailableReason: "请先选择要显示的实体，最多 6 项。") }
            let snapshot = model.haSnapshot
            guard !snapshot.entities.isEmpty else { return .init(title: "Home Assistant", unavailableReason: "尚无服务器实体数据，请先连接 Home Assistant。") }
            let pool = Dictionary(snapshot.entities.map { ($0.entityId, $0) }, uniquingKeysWith: { first, _ in first })
            let rows = options.entityIDs.prefix(6).map { id -> ReadPicoInformationFrame.Row in
                guard let entity = pool[id] else { return .init(label: id, value: "实体不可用") }
                return .init(label: snapshot.aliases[id] ?? entity.displayName, value: entity.displayValue)
            }
            return .init(title: "Home Assistant", subtitle: snapshot.errorText == nil ? "家庭状态" : "连接异常 · 最近采样", rows: rows, sampledAt: snapshot.sampledAt)
        case .image:
            guard let image = selectedImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .init(title: "图片", unavailableReason: "请先选择需要推送的本机图片。") }
            return .init(layout: .image, title: imageName, image: image, sampledAt: now)
        }
    }
    private func duration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0)); return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, min(value.isFinite ? value : 0, Double(Int64.max / 2)))), countStyle: .binary)
    }
}
