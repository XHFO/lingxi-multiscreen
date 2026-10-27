import AppKit
import LinxDisplayCore
import SwiftUI
import UniformTypeIdentifiers

/// 中文：独立的小纸 Pico USB 管理入口，不复用其他设备的固件选择与写入地址。
/// English: Dedicated Read Pico USB management without other boards' images or write addresses.
struct ReadPicoFirmwareView: View {
    private let onBusyChange: ((Bool) -> Void)?
    private let discoverSerialPorts: () -> [ESPSerialPort]
    @State private var ports: [ESPSerialPort] = []
    @State private var selectedPort = ""
    @State private var imageURL: URL?
    @State private var manifestURL: URL?
    @State private var imageInfo: ReadPicoImageInfo?
    @State private var manifest: ReadPicoFirmwareManifest?
    @State private var device: ReadPicoDeviceInfo?
    @State private var busy = false
    @State private var progress = 0.0
    @State private var status = "连接小纸 Pico 后选择 USB 串口。"
    @State private var failed = false
    @State private var warning = false
    @State private var phase: ReadPicoFirmwarePhase = .idle
    @State private var stopping = false
    @State private var backupDirectory: URL?
    @State private var operationID: UUID?
    @State private var detail = ""
    @State private var showDetails = false
    @State private var confirmation: Action?
    @State private var partitionMismatch: ReadPicoPartitionMismatch?
    @State private var flasher = ReadPicoFirmwareFlasher()
    @State private var operationTask: Task<Void, Never>?
    @State private var usbRecovery = ReadPicoFirmwareUSBRecovery()
    @State private var transferDevices: [ReadPicoFirmwareUSBRecovery.Candidate] = []
    @State private var selectedTransferID = ""
    @State private var recoveringUSB = false

    private enum Action: String, Identifiable {
        case update, restore, freshInstall
        var id: String { rawValue }
        var title: String {
            switch self {
            case .update: return "更新小纸 Pico 固件？"
            case .restore: return "恢复这台设备的备份？"
            case .freshInstall: return "分区不匹配，进行首次全新安装？"
            }
        }
    }
    init(onBusyChange: ((Bool) -> Void)? = nil,
         discoverSerialPorts: @escaping () -> [ESPSerialPort] = { ReadPicoFirmwareFlasher.discoverSerialPorts() },
         usbRecovery: ReadPicoFirmwareUSBRecovery = .init()) {
        self.onBusyChange = onBusyChange; self.discoverSerialPorts = discoverSerialPorts
        _usbRecovery = State(initialValue: usbRecovery)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("固件与备份").font(.title2.weight(.semibold))
                Text("日常更新只替换系统应用，保留设备设置和 TF 卡内容。备份需要单独点击。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                connection
                Divider()
                files
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { firmwareActions }
                    VStack(alignment: .leading, spacing: 10) { firmwareActions }
                }.controlSize(.large)
                if partitionMismatch != nil && freshInstallDirectory != nil && !busy {
                    Button("首次全新安装…", role: .destructive) { confirmation = .freshInstall }
                        .help("仅在检测到有效的旧版 Pico 分区时提供；确认前不会擦除设备。")
                }
                if busy {
                    HStack {
                        Text(phaseLabel).font(.callout)
                        Spacer()
                        if !recoveringUSB { Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().font(.callout) }
                    }
                    if recoveringUSB { ProgressView().controlSize(.small).accessibilityLabel("等待 USB 串口恢复") }
                    else { ProgressView(value: progress).accessibilityLabel("操作进度") }
                    HStack {
                        Button(stopping ? "正在停止…" : "停止操作") { requestStop() }
                            .disabled(stopping || !phase.allowsCancellation)
                        if !phase.allowsCancellation {
                            Text("完成当前阶段后才能关闭或切换页面。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                Label(status, systemImage: failed || warning ? "exclamationmark.triangle" : busy ? "arrow.triangle.2.circlepath" : "info.circle")
                    .foregroundStyle(failed ? Color.red : warning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
                if let backupDirectory {
                    LabeledContent("最近有效备份") {
                        Text(backupDirectory.path).font(.caption).textSelection(.enabled)
                    }
                    Button("在访达中显示备份") { NSWorkspace.shared.activateFileViewerSelecting([backupDirectory]) }
                        .disabled(busy)
                }
                DisclosureGroup("详细记录", isExpanded: $showDetails) {
                    ScrollView {
                        Text(detail.isEmpty ? "尚无操作记录。" : detail)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 100, maxHeight: 200)
                }
            }.padding(10)
        } label: { Label("小纸 Pico · USB 固件", systemImage: "book.closed") }
        .task { scanPorts() }
        .interactiveDismissDisabled(busy)
        .onDisappear { if busy { requestStop() } }
        .onChange(of: selectedPort) { _, _ in device = nil; partitionMismatch = nil }
        .alert(item: $confirmation) { action in
            Alert(title: Text(action.title), message: Text(confirmationMessage(action)),
                  primaryButton: confirmationButton(action),
                  secondaryButton: .cancel(Text("取消")))
        }
    }
    @ViewBuilder private var firmwareActions: some View {
        Button("更新固件") { confirmation = .update }
            .buttonStyle(.borderedProminent)
            .disabled(!ready || manifest?.kind != "application")
        Button("备份当前固件…") { chooseBackupDirectory() }
            .disabled(busy || selectedPort.isEmpty)
        Button("恢复所选备份…") { confirmation = .restore }
            .disabled(!ready || manifest?.kind != "backup")
    }
    private var phaseLabel: String {
        if recoveringUSB { return "正在结束文件传输并等待原设备串口" }
        switch phase {
        case .idle: return "准备就绪"
        case .preparing: return "正在核对设备与文件"
        case .readingBackup: return "正在读取设备固件"
        case .savingBackup: return "正在保存备份"
        case .writing: return "正在写入固件，请保持连接"
        case .verifying: return "正在校验写入结果"
        case .restarting: return "正在重新启动设备"
        }
    }
    private func confirmationButton(_ action: Action) -> Alert.Button {
        let operation = {
            if action == .freshInstall { freshInstall() }
            else { install(restoring: action == .restore) }
        }
        if action == .update { return .default(Text("更新固件"), action: operation) }
        return .destructive(Text(action == .freshInstall ? "清除内部数据并全新安装" : "恢复备份"), action: operation)
    }
    private func confirmationMessage(_ action: Action) -> String {
        switch action {
        case .update: return "将先核对设备身份、分区与安全状态，再写入所选版本。期间请保持 USB 连接；本次不会自动备份。"
        case .restore: return "仅允许恢复到备份所属的同一台小纸 Pico。将替换系统应用，设备设置和 TF 卡内容保留。请保持 USB 连接。"
        case .freshInstall:
            return "已确认设备 \(partitionMismatch?.macAddress ?? "") 的有效分区与内置固件不匹配，尚未写入数据。\n\n全新安装将清除全部内部 Flash，重新建立分区并安装内置系统。内部 Wi-Fi、配对与系统设置，以及仅保存在内部的笔记、划线和文件将被清除；TF 卡中的图书、笔记、应用及画稿保留。\n\n确认后将重新核对原设备和安装文件；开始擦除后不能停止。请保持 USB 连接。"
        }
    }

    private var ready: Bool { !busy && !selectedPort.isEmpty && imageInfo != nil && imageURL != nil && manifestURL != nil }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
              HStack {
                Picker("USB 串口", selection: $selectedPort) {
                    Text("请选择小纸 Pico").tag("")
                    ForEach(ports) { port in Text(port.displayName).tag(port.path) }
                }
                Button("刷新") { scanPorts() }
                Button("核对设备") { inspect() }.disabled(selectedPort.isEmpty)
              }
              VStack(alignment: .leading, spacing: 8) {
                Picker("USB 串口", selection: $selectedPort) {
                    Text("请选择小纸 Pico").tag("")
                    ForEach(ports) { port in Text(port.displayName).tag(port.path) }
                }
                HStack {
                    Button("刷新") { scanPorts() }
                    Button("核对设备") { inspect() }.disabled(selectedPort.isEmpty)
                }
              }
            }.disabled(busy)
            if let device {
                LabeledContent("设备系统", value: "\(device.version) · \(device.macAddress)")
                Label("身份、分区和安全状态已核对", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            } else if ports.isEmpty && transferDevices.isEmpty {
                Text("未找到阅读器。请连接可传输数据的 USB 线，并开启设备。")
                    .foregroundStyle(.secondary)
            }
            if !transferDevices.isEmpty {
                Divider()
                Label("Pico 正在进行 TF 文件传输，暂时没有刷写串口。", systemImage: "externaldrive.connected.to.line.below")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if transferDevices.count > 1 {
                    Picker("正在传输的 Pico", selection: $selectedTransferID) {
                        Text("选择要连接的设备").tag("")
                        ForEach(transferDevices) { candidate in Text(candidate.displayName).tag(candidate.id) }
                    }.disabled(busy)
                } else if let candidate = transferDevices.first {
                    Text(candidate.displayName).font(.callout).foregroundStyle(.secondary)
                }
                Button("结束传输并连接", systemImage: "cable.connector") { recoverTransferConnection() }
                    .disabled(busy || !transferDevices.contains(where: { $0.id == selectedTransferID }))
                Text("先安全弹出所选 TF 卡，再等待同一台 Pico 的串口恢复。连接完成后仍需点击更新固件；此操作不会刷写。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var files: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("本地固件").fontWeight(.medium)
                    Spacer()
                    fileActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("本地固件").fontWeight(.medium)
                    fileActions
                }
            }.disabled(busy)
            LabeledContent("镜像", value: imageURL?.lastPathComponent ?? "未选择")
            LabeledContent("清单", value: manifestURL?.lastPathComponent ?? "未选择")
            if let imageInfo, let manifest {
                LabeledContent("版本", value: imageInfo.version)
                LabeledContent("类型", value: manifest.kind == "backup" ? "设备备份 · 仅可恢复至原设备" : "系统 APP 更新")
                LabeledContent("文件大小", value: ByteCountFormatter.string(fromByteCount: Int64(manifest.imageBytes), countStyle: .file))
                Label("文件与清单校验通过", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var fileActions: some View {
        if bundledFirmwareAvailable { Button("使用内置固件") { chooseBundledFirmware() } }
        Button("选择 APP 文件…") { chooseImage() }
        Button("选择对应清单…") { chooseManifest() }
    }
    private func scanPorts() {
        ports = discoverSerialPorts()
        if !ports.contains(where: { $0.path == selectedPort }) { selectedPort = ports.count == 1 ? ports[0].path : "" }
        transferDevices = usbRecovery.candidates()
        if !transferDevices.contains(where: { $0.id == selectedTransferID }) {
            selectedTransferID = transferDevices.count == 1 ? transferDevices[0].id : ""
        }
    }
    private func recoverTransferConnection() {
        guard let candidate = transferDevices.first(where: { $0.id == selectedTransferID }),
              let id = start("正在安全结束 TF 文件传输，等待原 Pico 的 USB 串口…") else { return }
        recoveringUSB = true
        operationTask = Task { @MainActor in
            defer { recoveringUSB = false; finish(id) }
            do {
                let port = try await usbRecovery.recover(candidate)
                try Task.checkCancellation()
                guard operationID == id else { return }
                scanPorts(); selectedPort = port
                progress = 1
                status = "TF 卡已安全交还原 Pico，USB 串口已恢复。现在可以核对设备或更新固件。"
            } catch {
                guard operationID == id else { return }
                scanPorts()
                failed = !(error is CancellationError)
                status = error is CancellationError
                    ? "已停止等待连接。若 TF 卡已经弹出，请等待设备恢复后刷新；尚未开始刷写。"
                    : error.localizedDescription
            }
        }
    }
    private func chooseImage() {
        let panel = NSOpenPanel(); panel.title = "选择小纸 Pico APP 或备份镜像"
        panel.allowedContentTypes = [.data]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        imageURL = url
        let sibling = url.deletingLastPathComponent().appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: sibling.path) { manifestURL = sibling }
        validateSelection()
    }
    private func chooseManifest() {
        let panel = NSOpenPanel(); panel.title = "选择与镜像对应的 manifest.json"
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        manifestURL = url; validateSelection()
    }
    private var bundledFirmwareDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Firmware/ReadPico", isDirectory: true)
    }
    private var bundledFirmwareAvailable: Bool {
        guard let directory = bundledFirmwareDirectory else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("read-pico-app.bin").path) &&
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path)
    }
    private var freshInstallDirectory: URL? {
        guard let directory = bundledFirmwareDirectory,
              imageURL?.standardizedFileURL == directory.appendingPathComponent("read-pico-app.bin").standardizedFileURL,
              manifestURL?.standardizedFileURL == directory.appendingPathComponent("manifest.json").standardizedFileURL,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("fresh-install.json").path) else { return nil }
        return directory
    }
    private func chooseBundledFirmware() {
        guard let directory = bundledFirmwareDirectory else { return }
        imageURL = directory.appendingPathComponent("read-pico-app.bin")
        manifestURL = directory.appendingPathComponent("manifest.json")
        validateSelection()
    }
    private func validateSelection() {
        imageInfo = nil; manifest = nil; partitionMismatch = nil; failed = false
        guard let imageURL, let manifestURL else { status = "请选择镜像文件及与它配套的清单。"; return }
        // 中文：这里只做本地文件验证，尚未访问串口。/ English: Local validation does not access USB.
        do {
            let data = try ReadPicoFirmwareValidator.readFile(imageURL, maximumBytes: ReadPicoFirmwareValidator.slotBytes)
            let parsed = try JSONDecoder().decode(ReadPicoFirmwareManifest.self, from: ReadPicoFirmwareValidator.readFile(manifestURL, maximumBytes: 65536))
            imageInfo = try ReadPicoFirmwareValidator.validate(data, manifest: parsed, backup: parsed.kind == "backup")
            manifest = parsed; status = "文件校验通过，开始操作时还会重新核对设备。"
        } catch { failed = true; status = error.localizedDescription }
    }
    private func start(_ message: String) -> UUID? {
        guard !busy else { return nil }
        let id = UUID(); operationID = id
        busy = true; stopping = false; failed = false; warning = false
        phase = .preparing; progress = 0; detail = ""; status = message
        onBusyChange?(true)
        return id
    }
    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil; operationTask = nil; phase = .idle; stopping = false; busy = false
        onBusyChange?(false)
    }
    private func requestStop() {
        guard busy && !stopping else { return }
        if recoveringUSB {
            stopping = true; status = "正在停止等待 USB 连接…"; operationTask?.cancel(); return
        }
        if flasher.cancel() {
            stopping = true
            status = "正在停止操作，等待助手释放 USB 串口…"
        } else {
            phase = flasher.phase
            status = phase.message.isEmpty ? "操作正在收尾，请稍候…" : phase.message
        }
    }
    private func phaseHandler(_ id: UUID) -> ReadPicoFirmwareFlasher.PhaseHandler {
        { value in Task { @MainActor in
            guard operationID == id && busy else { return }
            phase = value
            if !stopping && value != .idle { status = value.message }
        } }
    }
    private func logHandler(_ id: UUID) -> ReadPicoFirmwareFlasher.Log {
        { text in Task { @MainActor in
            guard operationID == id && busy else { return }
            appendLog(text)
        } }
    }
    private func progressHandler(_ id: UUID) -> ReadPicoFirmwareFlasher.Progress {
        { value in Task { @MainActor in
            guard operationID == id && busy else { return }
            progress = value
        } }
    }
    private func reportFailure(_ error: Error) {
        if case .partitionMismatch(let mismatch) = error as? ReadPicoFirmwareError {
            device = nil
            if mismatch.targetBundleSHA256 != nil && freshInstallDirectory != nil {
                partitionMismatch = mismatch; warning = true; failed = false
                status = "设备分区不匹配，尚未写入数据。请确认是否首次全新安装。"
                confirmation = .freshInstall
                return
            }
            failed = true
            status = "设备分区与新固件不匹配，尚未写入数据。请使用包含完整首次安装资源的内置固件重新核对。"
            return
        }
        failed = (error as? ReadPicoFirmwareError) != .cancelled
        status = error.localizedDescription
    }
    private func appendLog(_ text: String) {
        detail += text
        if detail.count > 32_000 { detail = String(detail.suffix(24_000)) }
    }
    private func inspect() {
        guard !busy && !selectedPort.isEmpty else { return }
        let port = ESPSerialPort(path: selectedPort)
        guard let id = start("正在读取设备身份和系统信息…") else { return }
        operationTask = Task { @MainActor in
            defer { finish(id) }
            do {
                device = try await flasher.inspect(port: port, helperURL: ReadPicoFirmwareFlasher.helperURL(),
                    phase: phaseHandler(id), log: logHandler(id))
                progress = 1; status = "已确认是兼容的小纸 Pico，设备已恢复运行。"
            } catch { reportFailure(error) }
        }
    }
    private func install(restoring: Bool) {
        guard !busy, !selectedPort.isEmpty, let imageURL, let manifestURL else { return }
        let port = ESPSerialPort(path: selectedPort)
        guard let id = start(restoring ? "正在核对备份与设备身份…" : "正在核对固件与设备身份…") else { return }
        operationTask = Task { @MainActor in
            defer { finish(id) }
            do {
                let helper = try ReadPicoFirmwareFlasher.helperURL()
                let result: ReadPicoFirmwareResult
                if restoring { result = try await flasher.restore(port: port, helperURL: helper, imageURL: imageURL, manifestURL: manifestURL, progress: progressHandler(id), phase: phaseHandler(id), log: logHandler(id)) }
                else { result = try await flasher.flash(port: port, helperURL: helper, imageURL: imageURL, manifestURL: manifestURL, freshInstallDirectory: freshInstallDirectory, progress: progressHandler(id), phase: phaseHandler(id), log: logHandler(id)) }
                device = nil
                progress = 1
                status = (restoring ? "备份已恢复" : "固件已更新") + "，\(result.bytes) 字节回读校验通过。"
                if let restartError = result.restartError {
                    warning = true
                    status += "但设备启动请求未完成，请按电源键开机；无需重复刷写。"
                    appendLog("\n启动请求未完成：\(restartError)\n")
                } else { status += "已请求设备启动。" }
            } catch { reportFailure(error) }
        }
    }
    private func freshInstall() {
        guard !busy, let mismatch = partitionMismatch, let directory = freshInstallDirectory,
              selectedPort == mismatch.portPath else { return }
        let port = ESPSerialPort(path: selectedPort)
        guard let id = start("正在重新核对首次安装的设备和资源…") else { return }
        operationTask = Task { @MainActor in
            defer { finish(id) }
            do {
                let result = try await flasher.freshInstall(port: port, helperURL: ReadPicoFirmwareFlasher.helperURL(),
                    bundleDirectory: directory, confirmation: mismatch, progress: progressHandler(id),
                    phase: phaseHandler(id), log: logHandler(id))
                device = nil; partitionMismatch = nil; progress = 1
                status = "首次全新安装完成，启动程序、分区、系统和初始存储均已回读校验。TF 卡内容保留；请重新配置设备。"
                if let restartError = result.restartError {
                    warning = true; status += "启动请求未完成，请按电源键开机；无需重复安装。"
                    appendLog("\n启动请求未完成：\(restartError)\n")
                }
            } catch { partitionMismatch = nil; reportFailure(error) }
        }
    }
    private func chooseBackupDirectory() {
        guard !busy && !selectedPort.isEmpty else { return }
        let panel = NSOpenPanel(); panel.title = "选择固件备份保存位置"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let port = ESPSerialPort(path: selectedPort)
        guard let id = start("正在读取当前固件，设备数据不会被写入…") else { return }
        operationTask = Task { @MainActor in
            defer { finish(id) }
            do {
                let result = try await flasher.backup(port: port, helperURL: ReadPicoFirmwareFlasher.helperURL(), directory: directory,
                    progress: progressHandler(id), phase: phaseHandler(id), log: logHandler(id))
                backupDirectory = result.directory; progress = 1
                status = "备份已保存并通过校验。仅包含系统应用，不包含设置或 TF 卡。"
                if let restartError = result.restartError {
                    warning = true
                    status += "设备启动请求未完成，备份仍然有效；请按电源键开机。"
                    appendLog("\n启动请求未完成：\(restartError)\n")
                }
                NSWorkspace.shared.activateFileViewerSelecting([result.directory])
            } catch { reportFailure(error) }
        }
    }
}
