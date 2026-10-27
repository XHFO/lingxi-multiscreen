import AppKit
import LinxDisplayCore
import SwiftUI

/// Connection controls remain inline; merely editing a board never takes ownership of its TF card.
struct ReadPicoUSBConnectionPanel: View {
    @ObservedObject private var drafts: ReadPicoDraftGuard
    @ObservedObject private var model: ReadPicoManagerModel
    @State private var selectedPort = ""
    @State private var showDetails = false
    @State private var address: String
    @State private var setupKey = ""
    @State private var selectedSSID = ""
    @State private var networkPassword = ""
    @State private var showManual = false
    @State private var pendingSync = false
    private let forBoard: Bool
    private let compact: Bool
    private let onSync: (() -> Void)?
    private let syncDisabled: Bool
    private let syncRequiresUSB: Bool

    init(drafts: ReadPicoDraftGuard, initialAddress: String = "", forBoard: Bool = false,
         compact: Bool = false, onSync: (() -> Void)? = nil,
         syncDisabled: Bool = false, syncRequiresUSB: Bool = false) {
        self.drafts = drafts; self.model = drafts.model; self.forBoard = forBoard
        self.compact = compact; self.onSync = onSync
        self.syncDisabled = syncDisabled; self.syncRequiresUSB = syncRequiresUSB
        _address = State(initialValue: initialAddress)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if compact {
                compactRow
                if let failure = compactFailure {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { routePicker; Spacer(minLength: 8); automaticButton; detailsButton }
                    VStack(alignment: .leading, spacing: 10) {
                        routePicker
                        HStack { automaticButton; Spacer(minLength: 8); detailsButton }
                    }
                }
                status
            }
            if routePreference != .usb && (compact ? needsWirelessInput : (model.provisioningPhase != .idle || (routePreference == .wifi && model.connection == nil))) {
                wirelessSetupControls
            }
            if showDetails || model.usbBoardNeedsSelection {
                VStack(alignment: .leading, spacing: 12) {
                    if compact {
                        HStack(spacing: 12) { routePicker; Spacer(minLength: 4); automaticButton }
                        if syncRequiresUSB {
                            Text("书内划线与批注目前通过 USB 同步；连接方式仍用于其他设备内容。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if routePreference != .usb {
                        wifiControls
                        if routePreference == .automatic { Divider() }
                    }
                    if routePreference != .wifi || syncRequiresUSB { usbControls }
                }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .task {
            chooseNetwork()
            while !Task.isCancelled {
                await model.refreshCardAvailability(); choosePort()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
        .onChange(of: model.wirelessNetworks) { _, _ in
            chooseNetwork()
        }
        .onChange(of: selectedSSID) { _, _ in networkPassword = "" }
        .onChange(of: model.connection) { _, connection in
            if let connection { address = connection.baseURL.absoluteString; setupKey = "" }
        }
        .onChange(of: model.canManageContent) { _, _ in finishPendingSync() }
        .onChange(of: model.busy) { _, busy in if !busy { finishPendingSync() } }
        .onChange(of: model.isError) { _, failed in if failed { pendingSync = false } }
        .onChange(of: model.cardError) { _, failed in if failed { pendingSync = false } }
        .onChange(of: model.wirelessError) { _, failed in if failed { pendingSync = false } }
        .onDisappear { pendingSync = false }
    }
    private var compactRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                if model.busy || model.waitingForUSBVolume || syncDisabled {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: syncRequiresUSB ? (model.store == nil ? "cable.connector" : "checkmark.circle")
                          : model.usesWirelessContent ? "wifi" : model.store == nil ? "cable.connector" : "checkmark.circle")
                }
                Text(compactStatus).lineLimit(model.busy || model.waitingForUSBVolume ? 3 : 1)
                    .truncationMode(.middle).help(compactStatus)
            }.font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if model.busy, model.canCancel {
                Button(model.cancelTitle) { pendingSync = false; model.cancelOperation() }.font(.callout)
            }
            Button(model.waitingForUSBVolume || setupBusy ? "连接中…" : model.busy || syncDisabled ? "同步中…" : "同步",
                   systemImage: "arrow.triangle.2.circlepath") { synchronize() }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || model.waitingForUSBVolume || syncDisabled || drafts.isHandlingDeparture)
            detailsButton
        }
    }
    private var compactStatus: String {
        if model.waitingForUSBVolume { return "正在连接 Pico…" }
        if model.busy { return model.message }
        if syncDisabled { return "正在同步，请保持设备连接…" }
        if syncRequiresUSB {
            if let store = model.store { return "USB · " + store.rootURL.lastPathComponent }
            return model.connection == nil ? "连接 Pico 后同步" : "Pico 已在线 · 书内记录通过 USB 同步"
        }
        return model.contentConnectionDescription
    }
    private var compactFailure: String? {
        if model.isError { return model.message }
        if model.cardError && (model.waitingForUSBVolume || model.store == nil) { return model.cardMessage }
        if routePreference != .usb && model.wirelessError && !model.canManageContent { return model.wirelessStatus }
        return nil
    }
    private var needsWirelessInput: Bool {
        model.provisioningPhase == .selectNetwork || (model.wirelessError && !model.canManageContent)
    }
    /// Reuse the existing routes and real reload/import action. Opening options never takes TF ownership.
    private func synchronize() {
        guard !model.busy, !syncDisabled, !model.waitingForUSBVolume else { return }
        if syncRequiresUSB, model.store != nil { onSync?(); return }
        if !syncRequiresUSB, model.canManageContent { performSync(); return }
        choosePort()
        guard !selectedPort.isEmpty else {
            showDetails = true
            model.report(model.usbPorts.isEmpty
                         ? "尚未检测到 Pico。请连接 USB，或在连接选项中配对后同步。"
                         : "检测到多台设备，请在连接选项中选择要同步的 Pico。", error: true)
            return
        }
        let port = selectedPort
        drafts.request(.device, title: "同步前保存设备设置？") {
            if syncRequiresUSB {
                // Notify the import view only after a save/discard decision actually accepts this action.
                onSync?()
                model.startUSB(port: port)
            } else if routePreference != .wifi {
                pendingSync = true; model.startUSB(port: port)
            } else {
                pendingSync = true
                if !model.autoConnectWireless(port: port, discardChanges: true) { pendingSync = false }
            }
        }
    }
    private func performSync() {
        if let onSync { onSync() } else { model.reload() }
    }
    private func finishPendingSync() {
        guard pendingSync, !model.busy, model.canManageContent else { return }
        pendingSync = false; performSync()
    }
    private var routePreference: ReadPicoTransportPreference {
        get { forBoard ? model.boardTransportPreference : model.transportPreference }
        nonmutating set {
            if forBoard { model.boardTransportPreference = newValue }
            else { model.transportPreference = newValue }
        }
    }
    private var setupBusy: Bool {
        switch model.provisioningPhase {
        case .checking, .scanning, .connecting, .pairing: true
        default: false
        }
    }
    private var automaticButton: some View {
        Group {
            if routePreference != .usb {
                Button(model.connection == nil ? "自动连接" : "重新连接", systemImage: "link") {
                    _ = model.autoConnectWireless(port: selectedPort.isEmpty ? nil : selectedPort)
                }.disabled(model.busy || setupBusy)
                    .help("通过 USB 自动取得无线地址与配对信息")
            }
        }
    }
    private var routePicker: some View {
        Picker(forBoard ? "画板发送方式" : "文件管理方式", selection: Binding(get: { routePreference }, set: { routePreference = $0 })) {
            ForEach(ReadPicoTransportPreference.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 250).disabled(model.busy)
            .help(forBoard ? "自动：先验证局域网连接，不可达时使用已确认的 USB 设备。" : "选择文件管理使用的连接方式。")
    }
    private var status: some View {
        HStack(spacing: 6) {
            if model.waitingForUSBVolume || (model.busy && !setupBusy) { ProgressView().controlSize(.small) }
            else { Image(systemName: (routePreference == .wifi || (forBoard ? !model.prefersUSBBoard && model.connection != nil : model.usesWirelessContent)) ? "wifi" : model.store != nil ? "checkmark.circle" : "cable.connector") }
            Text(model.waitingForUSBVolume ? "正在连接 Pico…" : model.busy && !setupBusy ? model.message : forBoard ? model.boardConnectionDescription : model.contentConnectionDescription)
                .fixedSize(horizontal: false, vertical: true)
        }.font(.callout).foregroundStyle(.secondary)
    }
    private var detailsButton: some View {
        Button { showDetails.toggle() } label: {
            if compact { Label("连接选项", systemImage: showDetails ? "chevron.up" : "chevron.down") }
            else { Text(showDetails ? "收起" : "连接选项") }
        }.font(.callout).buttonStyle(.plain)
            .accessibilityValue(showDetails ? "已展开" : "已收起")
    }
    private var wirelessSetupControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.wirelessStatus.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    if setupBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.wirelessError ? "exclamationmark.circle" : model.provisioningPhase == .connected ? "checkmark.circle" : "wifi") }
                    Text(model.wirelessStatus).fixedSize(horizontal: false, vertical: true)
                }.font(.callout).foregroundStyle(model.wirelessError ? Color.red : Color.secondary)
            }
            if model.provisioningPhase == .selectNetwork || (!model.wirelessNetworks.isEmpty && model.wirelessError) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("Wi-Fi 网络", selection: $selectedSSID) {
                            Text("选择网络").tag("")
                            ForEach(model.wirelessNetworks) { network in
                                Text(network.ssid + (network.supported ? "" : "（不支持）")).tag(network.ssid).disabled(!network.supported)
                            }
                        }
                        Button("重新扫描", systemImage: "arrow.clockwise") { _ = model.scanWirelessNetworks() }
                            .labelStyle(.iconOnly).accessibilityLabel("重新扫描 Wi-Fi 网络").help("重新扫描 Wi-Fi 网络")
                    }
                    if model.wirelessNetworks.first(where: { $0.ssid == selectedSSID })?.requiresPassword == true {
                        SecureField("Wi-Fi 密码", text: $networkPassword)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Wi-Fi 密码")
                            .onSubmit { joinNetwork() }
                    }
                    HStack {
                        Text("为 Pico 选择与 Mac 可互访的 2.4 GHz 网络。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("连接网络") { joinNetwork() }.disabled(!canJoinNetwork)
                    }
                }.disabled(model.busy || setupBusy)
            }
        }
        .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
    private var canJoinNetwork: Bool {
        guard let network = model.wirelessNetworks.first(where: { $0.ssid == selectedSSID }), network.supported else { return false }
        return !network.requiresPassword || !networkPassword.isEmpty
    }
    private func joinNetwork() {
        guard canJoinNetwork, !model.busy, !setupBusy else { return }
        if model.joinWirelessNetwork(ssid: selectedSSID, password: networkPassword) { networkPassword = "" }
    }
    private var wifiControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Wi-Fi 无线连接", systemImage: "wifi").font(.callout.weight(.medium))
            if let connection = model.connection {
                HStack {
                    Text(connection.baseURL.absoluteString).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("断开") {
                        drafts.request(.device, title: "断开前保存设备设置？") { _ = model.disconnect() }
                    }.disabled(model.busy)
                }
            } else {
                Text("接上 USB 后点“自动连接”，无需在设备上抄写地址或配对码。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("手动填写地址与配对码", isExpanded: $showManual) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("http://设备地址/manage#key=…", text: $address)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Pico 管理地址").privacySensitive()
                        SecureField("临时配对码（完整链接已含时留空）", text: $setupKey)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("临时配对码")
                        HStack {
                            Text("也可从 Pico 的“手机与电脑管理”页面取得链接。")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button("配对") { model.connect(address: address, key: setupKey) }.disabled(address.isEmpty || model.busy)
                        }
                    }.padding(.top, 8)
                }
            }
        }.disabled(model.busy || setupBusy)
    }
    @ViewBuilder private var usbControls: some View {
        if forBoard { boardUSBControls } else { fileUSBControls }
    }
    private var boardUSBControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("USB 直接推送", systemImage: "cable.connector").font(.callout.weight(.medium))
            Text("画板直接发送给设备，TF 卡保留在阅读器内。连接按实际协议能力识别，替换设备后可以重新选择。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let store = model.store {
                HStack {
                    Text("正在管理 TF 文件：" + store.rootURL.lastPathComponent).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if model.canEjectCard { Button("结束文件管理") { model.ejectCard() } }
                }
            }
            HStack {
                Picker("USB 设备", selection: $selectedPort) {
                    Text("选择设备").tag("")
                    ForEach(model.usbPorts, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent).tag($0) }
                }
                Button("使用此设备") { model.selectUSBBoard(port: selectedPort) }
                    .disabled(selectedPort.isEmpty || model.waitingForUSBVolume)
            }
            HStack {
                Button("重新检测", systemImage: "arrow.clockwise") { Task { await model.refreshCardAvailability(); choosePort() } }
                if model.waitingForUSBVolume { Button("停止等待") { model.stopWaitingForUSB() } }
            }.font(.callout)
        }.disabled(model.busy)
    }
    private var fileUSBControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("USB 有线连接", systemImage: "cable.connector").font(.callout.weight(.medium))
            if let store = model.store {
                HStack {
                    Text(store.rootURL.lastPathComponent).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("在访达中显示") { NSWorkspace.shared.open(store.rootURL) }
                    if model.canEjectCard { Button("安全断开") { model.ejectCard() } }
                }
            } else {
                Text("发送时会自动连接，完成后交还阅读器。只编辑内容时不会开启文件传输。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.usbPorts.isEmpty {
                    HStack {
                        Picker("Pico", selection: $selectedPort) {
                            Text("选择设备").tag("")
                            ForEach(model.usbPorts, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent).tag($0) }
                        }
                        Button("连接 USB") {
                            drafts.request(.device, title: "连接前保存设备设置？") { model.startUSB(port: selectedPort) }
                        }.disabled(selectedPort.isEmpty || model.waitingForUSBVolume)
                    }
                }
                ForEach(model.mountedVolumes) { volume in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(volume.name).font(.callout)
                            Text(volume.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("使用此卡") { model.selectCard(volume.rootURL) }.disabled(volume.readOnly)
                    }
                }
            }
            HStack {
                Button("重新检测", systemImage: "arrow.clockwise") { Task { await model.refreshCardAvailability(); choosePort() } }
                if model.waitingForUSBVolume { Button("停止等待") { pendingSync = false; model.stopWaitingForUSB() } }
            }.font(.callout)
            if model.cardError { Text(model.cardMessage).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }.disabled(model.busy)
    }
    private func chooseNetwork() {
        if !model.wirelessNetworks.contains(where: { $0.ssid == selectedSSID && $0.supported }) {
            selectedSSID = model.wirelessNetworks.first(where: { $0.supported })?.ssid ?? ""
            networkPassword = ""
        }
    }
    private func choosePort() {
        if !model.usbPorts.contains(selectedPort) { selectedPort = model.usbPorts.count == 1 ? model.usbPorts[0] : "" }
    }
}
