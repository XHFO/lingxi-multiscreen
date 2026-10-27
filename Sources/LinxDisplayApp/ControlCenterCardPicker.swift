import LinxDisplayCore
import SwiftUI

struct ControlCenterCardCatalogItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbolName: String
}

/// A card is a view of an existing record. Adding/removing it changes only the
/// desktop layout, and never creates, deletes or disconnects a device/source.
struct ControlCenterCardPicker: View {
    let items: [ControlCenterCardCatalogItem]
    @Binding var layout: DeviceControlCenterLayout
    let onAddDevice: () -> Void
    let onClose: () -> Void
    @State private var query = ""
    private var matching: [ControlCenterCardCatalogItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { term.isEmpty || $0.title.localizedCaseInsensitiveContains(term) || $0.subtitle.localizedCaseInsensitiveContains(term) }
    }
    private var available: [ControlCenterCardCatalogItem] { matching.filter { !layout.isCardVisible($0.id) } }
    private var added: [ControlCenterCardCatalogItem] { matching.filter { layout.isCardVisible($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("添加卡片").font(.title2.weight(.semibold))
                Spacer()
                Button("完成", action: onClose).keyboardShortcut(.cancelAction)
            }.padding(20)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("搜索卡片", text: $query).textFieldStyle(.plain)
                    .accessibilityIdentifier("control-center-card-picker-search")
            }.padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            List {
                Section {
                    if available.isEmpty {
                        Text(LocalizedStringKey(query.isEmpty ? "所有可用卡片均已添加" : "没有匹配的可添加卡片"))
                            .foregroundStyle(.secondary).padding(.vertical, 10)
                    } else {
                        ForEach(available) { item in row(item, visible: false) }
                    }
                } header: { Text("可添加") }
                Section {
                    if added.isEmpty {
                        Text("还没有中控卡片").foregroundStyle(.secondary).padding(.vertical, 10)
                    } else {
                        ForEach(added) { item in row(item, visible: true) }
                    }
                } header: { Text("已添加") }
            }
            .listStyle(.inset)
            .controlCenterHostedFormSurface()
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("移除卡片只影响中控面板，设备与数据源配置会保留。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(action: onAddDevice) {
                    Label("添加设备或数据源", systemImage: "plus.circle")
                }.buttonStyle(.bordered)
                    .accessibilityIdentifier("control-center-card-picker-add-device")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .frame(minWidth: 440, idealWidth: 600, maxWidth: 720, minHeight: 440, idealHeight: 620, maxHeight: 760)
        .accessibilityIdentifier("control-center-card-picker")
    }

    private func row(_ item: ControlCenterCardCatalogItem, visible: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbolName).font(.title3)
                .foregroundStyle(.secondary).frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if visible {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    .accessibilityLabel("已添加")
                Button("移除") { layout.setCardVisible(false, for: item.id) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("control-center-hide-" + item.id)
            } else {
                Button("添加") { layout.setCardVisible(true, for: item.id) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("control-center-show-" + item.id)
            }
        }.padding(.vertical, 7)
    }
}
