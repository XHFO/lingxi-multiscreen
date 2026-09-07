import AppKit
import LinxDisplayCore
import SwiftUI

struct AIMacScreenView: View {
    @ObservedObject var model: AIMacScreenModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            settingsPanel
                .frame(width: 330)
            previewPanel
                .frame(width: 360)
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 500)
    }

    private var settingsPanel: some View {
        Form {
            Section("AI Mac 小屏幕") {
                TextField("设备 IP，例如 192.168.1.88", text: model.hostBinding)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("连接测试") { model.testConnection() }
                    if model.busy { ProgressView().controlSize(.small) }
                }
            }

            Section("显示内容") {
                Picker("画面", selection: model.modeBinding) {
                    ForEach(AIMacScreenMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                if model.settings.mode == .customImage {
                    Button("选择图片…") { model.chooseImage() }
                    Text(model.settings.customImagePath.map {
                        URL(fileURLWithPath: $0).lastPathComponent
                    } ?? "尚未选择")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("帧推送") {
                Toggle("自动推送变化画面", isOn: model.autoPushBinding)
                Stepper("最短间隔：\(model.settings.pushIntervalSeconds) 秒",
                        value: model.intervalBinding, in: 1...60)
                HStack {
                    Text("JPEG 质量")
                    Slider(value: Binding(
                        get: { Double(model.settings.jpegQuality) },
                        set: { model.settings.jpegQuality = Int($0.rounded()) }),
                           in: 50...90, step: 1)
                    Text("\(model.settings.jpegQuality)")
                        .monospacedDigit()
                        .frame(width: 28)
                }
                Text("固件只接收严格的 240×240 JPEG；实验版会自动降低质量，确保每帧不超过 24KB。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("立即推送", action: model.pushNow)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
            }

            Section("状态") {
                Text(model.status)
                Text(model.lastPush)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("240×240 实时预览")
                .font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.black)
                    .shadow(radius: 12, y: 5)
                if let image = model.preview {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(26)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            Text("此实验版只使用自己的设置目录，不读取多屏灵犀主版的设备、令牌或图片记录。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
