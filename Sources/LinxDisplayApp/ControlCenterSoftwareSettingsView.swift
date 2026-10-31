import SwiftUI
import LinxDisplayCore

/// 中控软件卡片的显示内容设置。字段按卡片类型列出，选择结果只保存在中控面板。
struct ControlCenterSoftwareSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    let source: DeviceControlCenterDataSource
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, source: DeviceControlCenterDataSource) {
        self.model = model
        self._settings = ObservedObject(wrappedValue: model.settings)
        self.source = source
    }

    private var mode: DisplayMode? {
        guard case let .software(mode) = source.destination else { return nil }
        return mode
    }

    private var allFields: [ControlCenterSoftwareField] {
        guard let mode else { return [] }
        return ControlCenterSoftwareField.fields(for: mode)
    }

    private var selected: Set<ControlCenterSoftwareField> {
        guard let mode else { return [] }
        if let stored = settings.controlCenterSoftwareFieldIDs(for: mode) {
            return Set(stored.compactMap(ControlCenterSoftwareField.init(rawValue:)))
        }
        return ControlCenterSoftwareField.defaultFields(for: mode)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(source.title, systemImage: source.symbolName)
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            Form {
                Section {
                    ForEach(allFields) { field in
                        Toggle(field.title, isOn: binding(for: field))
                    }
                } header: {
                    Text("显示内容")
                } footer: {
                    Text("卡片会按 1×1、2×1、1×2、2×2、2×3 自动切换排版；这里选择要出现在卡片里的信息。取消全部字段时只保留标题和状态。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    HStack {
                        Button("全部显示") { update(Set(allFields)) }
                        Button("恢复默认") { reset() }
                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
            .controlCenterHostedFormSurface()
        }
        .frame(width: 460, height: 520)
    }

    private func binding(for field: ControlCenterSoftwareField) -> Binding<Bool> {
        Binding(get: {
            selected.contains(field)
        }, set: { enabled in
            var next = selected
            if enabled { next.insert(field) } else { next.remove(field) }
            update(next)
        })
    }

    private func update(_ fields: Set<ControlCenterSoftwareField>) {
        guard let mode else { return }
        let ordered = allFields.filter(fields.contains).map(\.rawValue)
        settings.setControlCenterSoftwareFieldIDs(ordered, for: mode)
    }

    private func reset() {
        guard let mode else { return }
        settings.clearControlCenterSoftwareFieldIDs(for: mode)
    }
}
