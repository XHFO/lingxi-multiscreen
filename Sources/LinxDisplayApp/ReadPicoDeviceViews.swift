import SwiftUI
import LinxDisplayCore

/// All reader functions are peers in the device sidebar. The section is owned
/// by the main window, while its connection and drafts belong to the reader.
enum ReadPicoDeviceSection: String, CaseIterable {
    case books, fonts, notes, apps, drawings, settings, information, lockScreen, firmware

    var managerSection: String? {
        switch self {
        case .books: return "books"
        case .fonts: return "fonts"
        case .notes: return "notes"
        case .apps: return "apps"
        case .drawings: return "drawings"
        case .settings: return "connection"
        case .information, .lockScreen, .firmware: return nil
        }
    }
}

/// Each managed reader owns its session and drafts. All navigation commits after its departure guard.
@MainActor final class ReadPicoDeviceNavigation: ObservableObject {
    private var guards: [UUID: ReadPicoDraftGuard] = [:]
    @Published private(set) var activeDrafts: ReadPicoDraftGuard?
    private var activeDeviceID: UUID?
    private var approved = false
    func drafts(for id: UUID) -> ReadPicoDraftGuard {
        if let existing = guards[id] { return existing }
        let canvas = ReadPicoCanvasDraft()
        let library = ReadPicoBoardLibrary(deviceID: id)
        let value = ReadPicoDraftGuard(canvas: canvas, boardLibrary: library)
        do { try library.load(into: canvas) }
        catch { value.model.report("画板库未能读取，已保留原文件。" + error.localizedDescription, error: true) }
        guards[id] = value
        return value
    }
    /// Presentation changes do not change session ownership. The stable main
    /// window host calls this only when the physical reader or selected workspace
    /// changes, so an old editor's onDisappear cannot cancel the new editor.
    func setActiveDevice(_ id: UUID?) {
        guard id != activeDeviceID else { return }
        activeDrafts?.deactivate()
        activeDeviceID = id
        let next = id.map { drafts(for: $0) }
        next?.activate()
        activeDrafts = next
    }
    func request(from id: UUID?, action: @escaping () -> Void) {
        guard !approved, let id, let drafts = guards[id] else { action(); return }
        drafts.request(title: "离开小纸 Pico 前保存修改？") { [weak self] in
            self?.approved = true
            action()
            self?.approved = false
        }
    }
    /// A section change keeps the same session and drafts. Only a departure
    /// from this reader requires a save decision; ongoing operations still block navigation.
    func requestPage(from currentID: UUID?, to nextID: UUID?, action: @escaping () -> Void) {
        if let currentID, currentID == nextID {
            if let drafts = guards[currentID],
               drafts.model.busy || drafts.externalBusy || drafts.isHandlingDeparture {
                drafts.request(title: "切换小纸 Pico 页面前请完成当前操作", action: action)
            } else { action() }
        } else { request(from: currentID, action: action) }
    }
    func remove(_ id: UUID) {
        if activeDeviceID == id {
            setActiveDevice(nil)
            guards.removeValue(forKey: id)
        } else { guards.removeValue(forKey: id)?.deactivate() }
    }
}

struct ReadPicoAddDeviceForm: View {
    let onAdd: (String, String) throws -> Void
    @State private var name = "小纸 Pico"
    @State private var address = ""
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("添加你的阅读器", systemImage: "book.closed").font(.headline)
            TextField("设备名称", text: $name).textFieldStyle(.roundedBorder)
            TextField("设备 IP 或管理地址（可稍后填写）", text: $address)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("小纸 Pico 管理地址")
            VStack(alignment: .leading, spacing: 8) {
                Label("Wi-Fi 和 USB 管理图书与应用", systemImage: "externaldrive")
                Text("可以通过 Wi-Fi 无线同步，也可以连接 USB 自动准备文件管理。图书、字体和笔记可先加入 Mac 资料库，勾选后同步。")
                Label("USB 连接一次，自动准备无线", systemImage: "wifi")
                Text("用 USB 连接 Pico 后点“自动连接”，软件会取得无线地址并完成配对。首次尚未联网时，选择 Wi-Fi 并输入密码即可。也可从设备“手机与电脑管理”页面取得链接进行手动配对。")
            }.font(.callout).foregroundStyle(.secondary)
            if !error.isEmpty { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("添加并打开设备") {
                    do { try onAdd(name, address) }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }
}

struct ReadPicoManagedDeviceView: View {
    @ObservedObject var model: AppModel
    let device: ManagedDevice
    let drafts: ReadPicoDraftGuard
    var section: ReadPicoDeviceSection = .books
    let onBack: () -> Void
    let onRemove: () -> Void
    @State private var showDelete = false
    @State private var configuredModule: CanvasModule?
    private var managementAddressLabel: String {
        let address = device.settings.readPico?.managementAddress ?? ""
        return address.isEmpty ? "在设备配置中配对后记录" : address
    }
    private var deviceProfile: some View {
        Group {
            LabeledContent("设备名称") {
                TextField("设备名称", text: model.deviceNameBinding(for: device.id))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 300)
            }
            LabeledContent("管理地址", value: managementAddressLabel)
            Toggle("启用设备", isOn: Binding(get: { device.isEnabled }, set: { enabled in
                drafts.request(title: "停用设备前保存修改？") {
                    model.deviceEnabledBinding(for: device.id).wrappedValue = enabled
                }
            }))
            HStack {
                Button("设备管理", action: onBack)
                Spacer()
                Button("移除设备", role: .destructive) { showDelete = true }
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            ReadPicoWorkbenchView(embedded: true,
                                  initialEndpoint: device.settings.readPico?.managementAddress ?? "",
                                  section: section, appModel: model, deviceID: device.id,
                                  draftGuard: drafts, settingsHeader: AnyView(deviceProfile),
                                  onConfigureModule: { configuredModule = $0 }, onEndpointVerified: { address in
                try? model.updateReadPicoManagementAddress(deviceID: device.id, address: address)
            })
        }
        .sheet(item: $configuredModule) { module in
            ReadPicoSharedModuleSettingsView(model: model, module: module)
        }
        .confirmationDialog("移除“\(device.name)”？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("移除设备", role: .destructive, action: onRemove)
            Button("取消", role: .cancel) {}
        } message: { Text("仅移除 Mac 中的设备档案，阅读器与 TF 卡内的内容会保留。") }
    }
}
