import SwiftUI
import LinxDisplayCore

/// These are the exact shared settings consumed by renderDeviceCanvas, not another device's content.
/// 只绑定生产画板渲染器使用的共享设置，不借用其他设备的文字、图片或实体绑定。
struct ReadPicoSharedModuleSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    let module: CanvasModule
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, module: CanvasModule) {
        self.model = model; self.module = module; self.settings = model.settings
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(module.title, systemImage: module.icon).font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(20)
            Divider()
            Form {
                Section {
                    LabeledContent("上下边距", value: settings.manualCanvasMargin(for: module) == 0 ? "自适应" : "\(settings.manualCanvasMargin(for: module))")
                    Slider(value: Binding(get: { Double(settings.manualCanvasMargin(for: module)) },
                        set: { settings.setCanvasMargin(Int($0), for: module) }), in: 0...40, step: 1)
                } header: { Text("画板排版") } footer: { Text("与多屏灵犀的其他画板共用；修改后会更新使用此模块的画板。") }
                options
            }.formStyle(.grouped).controlCenterHostedFormSurface()
        }.frame(width: 480, height: 520)
    }
    @ViewBuilder private var options: some View {
        switch module {
        case .clock, .date:
            Section("时间与日期") {
                TextField("时间格式", text: $settings.timeFormat)
                TextField("日期格式", text: $settings.dateFormat)
                Text("使用软件的全局格式，例如 HH:mm、yyyy年M月d日 EEE。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .nowPlaying:
            Section("正在播放") {
                LabeledContent("歌名字号", value: "\(settings.canvasNowPlayingTitleSize) pt")
                Slider(value: Binding(get: { Double(settings.canvasNowPlayingTitleSize) }, set: { settings.canvasNowPlayingTitleSize = Int($0) }), in: 7...24, step: 1)
                LabeledContent("歌手字号", value: "\(settings.canvasNowPlayingArtistSize) pt")
                Slider(value: Binding(get: { Double(settings.canvasNowPlayingArtistSize) }, set: { settings.canvasNowPlayingArtistSize = Int($0) }), in: 6...20, step: 1)
            }
        case .sspai:
            Section("少数派推荐") {
                Stepper("显示 \(settings.canvasSspaiCount) 条", value: $settings.canvasSspaiCount, in: 1...6)
                Toggle("随机显示", isOn: $settings.canvasSspaiRandom)
            }
        case .cloudflare:
            Section("网站统计") { CloudflareAnalyticsSettingsView(model: model) }
        case .qwenQuota:
            Section("千问额度") { Toggle("显示百分比", isOn: $settings.qwenQuotaShowPercent) }
        case .bambuLab, .bambuLab2, .bambuLab3, .bambuLab4, .bambuLab5:
            Section("显示信息") {
                Toggle("工作状态", isOn: printerField(\.showStatus))
                Toggle("打印进度", isOn: printerField(\.showProgress))
                Toggle("当前任务", isOn: printerField(\.showTask))
                Toggle("喷嘴温度", isOn: printerField(\.showNozzleTemp))
                Toggle("热床温度", isOn: printerField(\.showBedTemp))
                Toggle("时间信息", isOn: printerField(\.showRemaining))
                Toggle("错误信息", isOn: printerField(\.showError))
            }
        case .formlabs, .formlabs2, .formlabs3, .formlabs4, .formlabs5:
            if let device = model.formlabsDevice(for: module) {
                Section("显示信息") {
                    Toggle("任务缩略图", isOn: model.formlabsBoolBinding(for: device.id, \.showThumbnail))
                    Toggle("当前层数", isOn: model.formlabsBoolBinding(for: device.id, \.showLayers))
                    Toggle("耗材种类", isOn: model.formlabsBoolBinding(for: device.id, \.showMaterial))
                }
            } else { Section { Text("对应的打印机已停用或移除，请在设备管理中添加。") } }
        default:
            Section("数据来源") {
                Text("使用多屏灵犀已经配置的数据源与实时状态。")
                    .foregroundStyle(.secondary)
            }
        }
    }
    private func printerField(_ keyPath: WritableKeyPath<CanvasPrinterFields, Bool>) -> Binding<Bool> {
        Binding(get: { settings.canvasPrinterFields(for: module)[keyPath: keyPath] }, set: { value in
            var fields = settings.canvasPrinterFields(for: module)
            fields[keyPath: keyPath] = value
            settings.setCanvasPrinterFields(fields, for: module)
        })
    }
}
