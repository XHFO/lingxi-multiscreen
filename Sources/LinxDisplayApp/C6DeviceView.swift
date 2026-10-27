import SwiftUI
import CoreLocation
import LinxDisplayCore

/// Offline setup is a peer of Card Management, Board Management and Screen Control.
struct C6DeviceView: View {
    @ObservedObject var model: AppModel
    let deviceID: UUID
    @Environment(\.controlCenterHasExternalPreview) private var hasExternalPreview

    private var isOfflinePreview: Bool { model.c6OfflineSimulationIDs.contains(deviceID) }
    @State private var confirmOverride = false
    private var deviceName: String {
        model.settings.devices.first { $0.id == deviceID }?.name ?? C6ProjectResources.productName
    }
    private var backendURL: URL? {
        (try? C6StandaloneClient(host: model.aiMacScreenSettings(for: deviceID).host))?
            .baseURL.appendingPathComponent("standalone")
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
            Text(C6ProjectResources.productName).font(.title2.weight(.semibold))
            Text("\(deviceName) · \(C6ProjectResources.branchName)")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section {
                    Toggle("自动同步显示设置到设备", isOn: model.c6AutomaticSyncBinding(for: deviceID))
                        .disabled(isOfflinePreview)
                    Label(model.c6SyncStatuses[deviceID] ?? "等待局域网连接", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let conflict = model.c6SyncConflicts[deviceID] {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(conflict.message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(conflict.kind == .homeAssistant
                                 ? "Home Assistant 服务器地址与设备上保存的不一致。可保留设备配置，或用电脑端设备管理中的服务器覆盖设备。"
                                 : "同一台打印机在两边绑定了不同数据源或云端账号。可保留设备配置，或用电脑端当前选择覆盖设备。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("保留设备配置") {
                                    model.resolveC6SyncConflictKeepDevice(deviceID: deviceID)
                                }
                                Button("用电脑端覆盖", role: .destructive) { confirmOverride = true }
                                .disabled(isOfflinePreview)
                            }
                        }
                        .padding(8)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let remote = model.c6SyncedConfigurations[deviceID] {
                        Label(remote.localFirst
                              ? "在线时：本地卡片优先（可与电脑推送混合轮转）；离线约 30 秒后仅本地轮询。"
                              : "在线时：以电脑推送卡片为主；本地时钟/天气等仅在卡片管理启用时参与。离线约 30 秒后独立运行。",
                              systemImage: remote.localFirst ? "square.stack.3d.up" : "desktopcomputer")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("电脑与设备同步")
                        HelpIcon(text: "在侧边栏卡片页选择实体和打印机显示内容，在天气页设置城市。局域网连接后自动保存到这台 C6，电脑断开约 30 秒后独立显示。最多 6 个状态实体、3 台打印机；离线优先使用静态任务缩略图。若出现来源冲突，请在本页选择保留设备或覆盖，不会静默改写。")
                    }
                }
                C6StandaloneView(initialHost: model.aiMacScreenSettings(for: deviceID).host,
                    deviceID: deviceID, model: model,
                    onAuthorized: { model.authorizeC6Sync(deviceID: deviceID, token: $0) })
                    .id(deviceID.uuidString + model.aiMacScreenSettings(for: deviceID).host)
                Section("已有数据源") {
                    if let connection = model.c6HomeAssistantConnection {
                        LabeledContent("Home Assistant", value: connection.name)
                        LabeledContent("服务器", value: connection.url)
                        LabeledContent("长期令牌", value: connection.token.isEmpty ? "尚未填写" : "从设备管理自动同步")
                    } else {
                        Text("请先在设备管理中添加 Home Assistant 服务器。")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Bambu Lab", value: "复用所选打印机的数据源与实体绑定")
                    HelpIcon(text: "Home Assistant 数据源使用打印状态、打印进度、任务名称和剩余时间实体；本地 MQTT 数据源使用设备管理保存的连接及已确认的 TLS 证书。无需在 C6 页面重复填写服务器令牌或访问码。")
                }
                Section("使用与支持") {
                    DisclosureGroup("BOOT 按键操作") {
                        LabeledContent("单击", value: "下一张卡片 / 下一项")
                        LabeledContent("双击", value: "卡片详情 / 确认")
                        HStack(spacing: 4) {
                            LabeledContent("长按约 1.5 秒", value: "设备设置 / 返回")
                            HelpIcon(text: "长按 BOOT 进入设备设置，单击选择、双击确认、长按返回并自动保存。菜单每页最多 3 项，只暂停当前设备轮转。重置 Wi-Fi 默认取消，保留显示配置。RST 仍是硬件重启。")
                        }
                    }
                    C6ProjectGuideEntry()
                }
                if hasExternalPreview {
                    Section("屏幕预览") { previewControls }
                }
            }
            .formStyle(.grouped)
            .controlCenterHostedFormSurface()
            .frame(minWidth: 320, maxWidth: .infinity, alignment: .top)

            if !hasExternalPreview {
              Divider().padding(.vertical, 4)
              ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("屏幕预览").font(.headline)
                        Spacer()
                        Text("240 × 240").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Label(isOfflinePreview ? "设备实际画面" : "软件推送画面",
                          systemImage: isOfflinePreview ? "display" : "desktopcomputer")
                        .font(.subheadline.weight(.medium))
                    if let preview = model.aiMacScreenPreviews[deviceID] {
                        Image(nsImage: preview).resizable().interpolation(.none).scaledToFit()
                            .frame(width: 240, height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("\(deviceName)屏幕预览")
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "display").font(.largeTitle).foregroundStyle(.secondary)
                            Text("暂无画面").font(.headline)
                            Text("连接设备后刷新预览").foregroundStyle(.secondary)
                        }.frame(width: 240, height: 240)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    }
                    previewControls
                }.padding(20)
            }
            .frame(width: 300)
            }
        }
        .padding(.bottom, 12)
      }
        .confirmationDialog("用电脑端覆盖设备来源？", isPresented: $confirmOverride, titleVisibility: .visible) {
            Button("覆盖并写入设备", role: .destructive) {
                model.resolveC6SyncConflictUseDesktop(deviceID: deviceID)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把电脑端当前的 Home Assistant / 打印机数据源写入这台 C6，并替换设备上冲突的来源。设备独有的时钟样式、休眠与离线轮询设置会尽量保留。")
        }
        .task { model.refreshAIMacScreenPreview(deviceID: deviceID) }
        .task(id: model.c6OfflineSimulationIDs.contains(deviceID)) {
            while model.c6OfflineSimulationIDs.contains(deviceID) && !Task.isCancelled {
                await model.refreshC6OfflinePreview(deviceID: deviceID)
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }

    /// These controls remain available when the enclosing workspace owns the preview.
    private var previewControls: some View {
        Group {
            Button { refreshPreview() } label: { Label("刷新预览", systemImage: "arrow.clockwise") }
                .disabled(model.c6OfflineSimulationBusyIDs.contains(deviceID))
            Text(isOfflinePreview ? "读取设备实际画面，每 2 秒更新。" : "使用与设备推送相同的卡片渲染，不代表设备已接收。")
                .font(.callout)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 4) {
                Toggle("模拟软件离线", isOn: Binding(
                    get: { isOfflinePreview },
                    set: { enabled in Task { await model.setC6OfflineSimulation(deviceID: deviceID, enabled: enabled) } }))
                HelpIcon(text: "仅暂停这台 C6 的软件画面、心跳与配置同步，保留 Wi-Fi 以及设备独立订阅。预览读取设备真实画面。关闭后恢复原数据源优先级并补发软件首帧，不影响其他设备，也不清除配置。此状态不保存；应用退出后，临时控制最多 45 秒自动失效。")
            }.disabled(model.c6OfflineSimulationBusyIDs.contains(deviceID))
            if model.c6OfflineSimulationBusyIDs.contains(deviceID) {
                ProgressView("正在切换运行方式…").controlSize(.small)
            }
            Label(model.aiMacScreenStatuses[deviceID] ?? "需要先连接并同步显示设置。", systemImage: "info.circle")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let backendURL {
                Link(destination: backendURL) { Label("打开设备网页设置", systemImage: "arrow.up.right.square") }
            }
        }
    }

    private func refreshPreview() {
        if isOfflinePreview { Task { await model.refreshC6OfflinePreview(deviceID: deviceID) } }
        else { model.refreshAIMacScreenPreview(deviceID: deviceID) }
    }
}

struct C6FirmwareView: View {
    @State private var ports: [ESPSerialPort] = []
    @State private var selectedPort = ""
    @State private var busy = false
    @State private var progress = 0.0
    @State private var status = "仅适用于 Waveshare ESP32-C6-LCD-1.3。"
    @State private var confirm = false
    @State private var networkMode: C6FlashNetworkMode = .preserve
    @State private var wifiSSID = ""
    @State private var wifiPassword = ""
    @StateObject private var networkScanner = C6ProvisioningNetworkScanner()
    @State private var flasher = ESP8266FirmwareFlasher()
    var body: some View {
        GroupBox("C6 USB 一键刷机") {
            VStack(alignment: .leading, spacing: 12) {
                C6ProjectGuideEntry()
                HStack(spacing: 4) {
                    Picker("网络配置", selection: $networkMode) {
                        ForEach(C6FlashNetworkMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }.pickerStyle(.radioGroup)
                    HelpIcon(text: "默认只更新固件，不读取或覆盖设备已保存的 Wi-Fi、配对与离线配置，无需重新输入密码。首次配网或更换网络时选择写入新配置，或刷写后通过设备热点配网。C6 仅支持 2.4 GHz；新密码只用于本次 USB 配网，不保存到 Mac。")
                }.disabled(busy)
                if networkMode == .replace {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button { networkScanner.requestScan() } label: {
                                Label(networkScanner.isScanning ? "正在扫描" : "扫描 2.4 GHz Wi-Fi", systemImage: "arrow.clockwise")
                            }
                            .disabled(busy || networkScanner.isScanning)
                            if !networkScanner.networks.isEmpty {
                                Menu("选择网络") {
                                    ForEach(networkScanner.networks) { network in
                                        Button(network.ssid + (network.isOpen ? " · 开放网络" : "")) {
                                            wifiSSID = network.ssid
                                            if network.isOpen { wifiPassword = "" }
                                        }
                                    }
                                }.disabled(busy)
                            }
                            if networkScanner.isScanning { ProgressView().controlSize(.small) }
                        }
                        TextField("Wi-Fi 名称（SSID），也可手动填写", text: $wifiSSID)
                            .textFieldStyle(.roundedBorder).disabled(busy)
                            .onChange(of: wifiSSID) { previous, current in
                                if previous != current { wifiPassword = "" }
                            }
                        SecureField("Wi-Fi 密码（开放网络可留空）", text: $wifiPassword)
                            .textFieldStyle(.roundedBorder).disabled(busy)
                        Label("仅支持 2.4 GHz，不支持 5 GHz / 6 GHz", systemImage: "wifi.exclamationmark")
                            .font(.caption).foregroundStyle(.orange)
                        if !networkScanner.status.isEmpty {
                            Text(networkScanner.status).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if (!wifiSSID.isEmpty || !wifiPassword.isEmpty), let error = wifiInputError {
                            Text(error).font(.caption).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Picker("USB 串口", selection: $selectedPort) {
                    Text("选择已连接的 C6").tag("")
                    ForEach(ports) { Text($0.displayName).tag($0.path) }
                }.disabled(busy)
                HStack {
                    Button("重新扫描串口") { scanPorts() }.disabled(busy)
                    Button("刷入内置 C6 固件") { confirm = true }
                        .disabled(selectedPort.isEmpty || busy || wifiInputError != nil)
                    if busy { Button("取消刷写", role: .destructive) { flasher.cancel() } }
                }
                if busy { ProgressView(value: progress) }
                Text(status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(8)
        }.task { scanPorts() }
        .onChange(of: networkMode) { _, mode in
            if mode == .preserve {
                wifiPassword = ""
                networkScanner.stopWaitingForPermission()
            }
        }
        .onDisappear { wifiPassword = ""; networkScanner.stopWaitingForPermission() }
        .alert("刷写所选 C6？", isPresented: $confirm) {
            Button("取消", role: .cancel) {}
            Button("确认刷写", role: .destructive) { flash() }
        } message: {
            Text(networkMode == .replace
                 ? "将覆盖所选 C6 的固件，并通过 USB 一并写入本次 2.4 GHz Wi-Fi 配置。保留原配对和离线设置；密码不保存到 Mac。刷写期间不要拔线，完成后等待设备联网，再扫描添加。"
                 : "将覆盖所选 C6 的固件，保留原 Wi-Fi、配对和离线设置。仅适用于 Waveshare C6，不适用于 ESP8266。刷写期间不要拔线；首次使用需通过设备热点配置 2.4 GHz Wi-Fi。")
        }
    }
    private var wifiInputError: String? {
        guard networkMode == .replace else { return nil }
        do { try C6WiFiProvisioning.validateCredentials(ssid: wifiSSID, password: wifiPassword); return nil }
        catch { return error.localizedDescription }
    }
    private func scanPorts() {
        ports = ESP8266FirmwareFlasher.discoverSerialPorts().filter { $0.displayName.lowercased().hasPrefix("cu.usbmodem") }
        if !ports.contains(where: { $0.path == selectedPort }) { selectedPort = ports.count == 1 ? ports[0].path : "" }
    }
    private func flash() {
        guard let port = ports.first(where: { $0.path == selectedPort }) else { return }
        let provisioningImage: Data?
        do {
            provisioningImage = try C6WiFiProvisioning.makeImage(networkMode: networkMode,
                ssid: wifiSSID, password: wifiPassword)
        } catch { status = error.localizedDescription; return }
        wifiPassword = ""
        busy = true; progress = 0; status = "正在刷入 C6 固件…"
        Task { @MainActor in
            defer { busy = false }
            do {
                let firmware = try EmbeddedC6Firmware.resource(ota: false)
                guard let helper = Bundle.main.resourceURL?.appendingPathComponent("Firmware/lingxi-esptool") else { throw ESP8266FlashError.missingResource("刷机助手") }
                try await flasher.flashC6(port: port, helperURL: helper, firmwareURL: firmware.url,
                    wifiProvisioningImage: provisioningImage,
                    progress: { value in Task { @MainActor in progress = value } }, log: { _ in })
                status = provisioningImage == nil
                    ? "刷写完成。已有 Wi-Fi 配置将继续使用；首次使用可连接设备的 Lingxi-C6 热点配网，然后扫描添加设备。"
                    : "刷写完成，Wi-Fi 配置已通过 USB 写入。请等待设备联网，再扫描添加；若连接失败，长按 BOOT 进入设置，在“网络”中重置 Wi-Fi 后连接 Lingxi-C6 热点重新配网。"
            } catch { status = error.localizedDescription }
        }
    }
}

/// macOS requires Location permission to reveal scanned SSIDs. Permission is
/// requested only when the user clicks Scan; no location updates are started.
@MainActor
private final class C6ProvisioningNetworkScanner: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var networks: [ProvisioningWiFiNetwork] = []
    @Published var isScanning = false
    @Published var status = ""
    private let location = CLLocationManager()
    private var waitingForAuthorization = false

    override init() {
        super.init()
        location.delegate = self
    }
    func requestScan() {
        guard !isScanning else { return }
        guard CLLocationManager.locationServicesEnabled() else {
            status = "定位服务未开启。扫描网络名称需在系统设置 → 隐私与安全性 → 定位服务中授权；也可直接手动填写 SSID。"
            return
        }
        switch location.authorizationStatus {
        case .notDetermined:
            waitingForAuthorization = true; isScanning = true
            status = "请允许读取附近 Wi-Fi 网络名称；不会获取、保存或上传地理位置。"
            location.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: scanAuthorized()
        case .denied, .restricted: showDenied()
        @unknown default: showDenied()
        }
    }
    func stopWaitingForPermission() {
        if waitingForAuthorization { isScanning = false }
        waitingForAuthorization = false
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard waitingForAuthorization else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            waitingForAuthorization = false; scanAuthorized()
        case .denied, .restricted:
            waitingForAuthorization = false; showDenied()
        default: break
        }
    }
    private func showDenied() {
        isScanning = false
        status = "未获得扫描权限。可在系统设置 → 隐私与安全性 → 定位服务中允许多屏灵犀读取网络名称，或手动填写 SSID。"
    }
    private func scanAuthorized() {
        isScanning = true; status = "正在查找附近的 2.4 GHz 网络…"
        Task {
            defer { isScanning = false }
            do {
                networks = try await WiFiNetworkDiscovery.scan2GHz()
                status = "已找到 \(networks.count) 个 2.4 GHz 网络。选择网络后填写密码；隐藏网络可手动填写。"
            } catch { networks = []; status = error.localizedDescription }
        }
    }
}
