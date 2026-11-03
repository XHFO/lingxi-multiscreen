import SwiftUI
import LinxDisplayCore

/// 小米 IoT 账号与设备导入。当前阶段完成原生小米云登录、设备列表和导入选择；
/// 设备属性/控制会按每台设备的 MIoT 规格继续接入。
struct XiaomiSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings

    init(model: AppModel) {
        self.model = model
        self._settings = ObservedObject(wrappedValue: model.settings)
    }

    private var region: Binding<XiaomiCloudRegion> {
        Binding(get: { XiaomiCloudRegion(rawValue: settings.xiaomiRegionRaw) ?? .cn },
                set: { settings.xiaomiRegionRaw = $0.rawValue })
    }

    private var selected: Set<String> { Set(settings.xiaomiSelectedDeviceIDs) }

    var body: some View {
        Form {
            Section {
                Picker("账号地区", selection: region) {
                    ForEach(XiaomiCloudRegion.allCases) { region in
                        Text(region.title).tag(region)
                    }
                }
                .disabled(model.xiaomiAccount != nil)
                if let account = model.xiaomiAccount {
                    LabeledContent("登录状态", value: "已登录 · \(account.region.title)")
                    if let nickname = account.nickname, !nickname.isEmpty {
                        LabeledContent("账号", value: nickname)
                    }
                    HStack {
                        Button("重新读取设备") { Task { await model.refreshXiaomiDevices() } }
                            .disabled(model.xiaomiBusy)
                        Button("退出登录", role: .destructive) { model.logoutXiaomi() }
                            .disabled(model.xiaomiBusy)
                    }
                } else {
                    Button(model.xiaomiBusy ? "正在登录…" : "登录小米账号") {
                        Task { await model.loginXiaomi() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.xiaomiBusy)
                    Text("使用小米账号在浏览器中授权。登录信息仅保存在本机加密凭据文件中。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.xiaomiStatus.isEmpty {
                    Text(model.xiaomiStatus).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("小米云账号")
            }

            if !model.xiaomiDevices.isEmpty {
                Section {
                    HStack {
                        Text("已导入 \(selected.count) / \(model.xiaomiDevices.count) 台")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("全选") {
                            settings.xiaomiSelectedDeviceIDs = model.xiaomiDevices.map(\.did)
                        }
                        Button("全不选") { settings.xiaomiSelectedDeviceIDs = [] }
                    }
                    ForEach(model.xiaomiDevices) { device in
                        Toggle(isOn: Binding(
                            get: { selected.contains(device.did) },
                            set: { model.setXiaomiDeviceSelected(device.did, selected: $0) })) {
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: device))
                                    .frame(width: 24)
                                    .foregroundStyle(device.online ? Color.orange : Color.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name).lineLimit(1)
                                    Text(device.subtitle.isEmpty ? device.model : device.subtitle)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Text(device.online ? "在线" : "离线")
                                    .font(.caption).foregroundStyle(device.online ? .green : .secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                } header: {
                    Text("设备")
                } footer: {
                    Text("导入的设备会出现在中控面板的小米 IoT 卡片中。")
                }
            } else if model.xiaomiAccount != nil {
                Section {
                    ContentUnavailableView("暂无小米设备", systemImage: "m.square",
                                           description: Text("点击「重新读取设备」从小米云同步。"))
                }
            }
        }
        .formStyle(.grouped)
        .controlCenterHostedFormSurface()
        .task {
            if model.xiaomiAccount != nil, model.xiaomiDevices.isEmpty {
                await model.refreshXiaomiDevices()
            }
        }
    }

    private func icon(for device: XiaomiDevice) -> String {
        switch device.category {
        case "light": return "lightbulb"
        case "fan": return "fan"
        case "air-conditioner", "airconditioner": return "thermostat"
        case "switch", "plug", "outlet": return "powerplug"
        case "temperature-sensor", "humidity-sensor", "environment-sensor": return "thermometer.medium"
        default: return "square.grid.2x2"
        }
    }
}
