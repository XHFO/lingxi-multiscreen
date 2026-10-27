import LinxDisplayCore
import SwiftUI

struct ReadPicoBundledAppsView: View {
    @ObservedObject var model: ReadPicoManagerModel
    var onBusyChange: ((Bool) -> Void)? = nil
    @State private var items: [ReadPicoBundledApplication] = []
    @State private var loadError = ""
    @State private var expanded = true
    @State private var removing: ReadPicoCardFile?
    @State private var updating: ReadPicoBundledApplication?
    var body: some View {
        DisclosureGroup("内置功能包", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("选择要添加到阅读器的游戏和工具。功能包随多屏灵犀提供，添加后可离线使用。")
                    .foregroundStyle(.secondary)
                if !model.canManageContent {
                    Label("通过 Wi-Fi 配对或连接 USB，即可添加或移除。", systemImage: "sdcard")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !loadError.isEmpty { Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(item.package.title, systemImage: item.id == "weread" ? "text.book.closed" : item.package.isTool ? "pencil.and.outline" : "gamecontroller")
                                    .font(.headline)
                                Spacer()
                                Text(item.package.versionLabel).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(item.package.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            HStack {
                                if let existing = installed(item) {
                                    Label(existing.valid ? "已添加" : "需要修复", systemImage: existing.valid ? "checkmark.circle" : "exclamationmark.triangle")
                                        .font(.callout).foregroundStyle(existing.valid ? Color.secondary : Color.orange)
                                    Spacer()
                                    Button(existing.valid ? "更新" : "重新安装") { updating = item }
                                    Button("移除", role: .destructive) { removing = existing }
                                } else {
                                    Spacer()
                                    Button("添加", systemImage: "plus") { model.install([item.url], kind: .application, replace: false) }
                                        .buttonStyle(.bordered)
                                }
                            }.disabled(!model.canManageContent || model.busy)
                        }.padding(12).frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                if items.contains(where: { $0.id == "weread" }) {
                    ReadPicoWeReadView(model: model, onBusyChange: onBusyChange)
                }
            }.padding(.top, 12)
        }
        .task {
            guard items.isEmpty, loadError.isEmpty else { return }
            do {
                guard let root = Bundle.main.resourceURL?.appendingPathComponent("Firmware/ReadPico") else {
                    throw ReadPicoManagerError.unavailable("软件内置功能包目录缺失。")
                }
                items = try ReadPicoBundledApps.load(directory: root)
            } catch { loadError = error.localizedDescription }
        }
        .confirmationDialog("移除这个功能包？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移除功能包", role: .destructive) { if let file = removing { model.remove(file) }; removing = nil }
            Button("取消", role: .cancel) { removing = nil }
        } message: { Text("仅移除应用程序，TF 卡里的独立存档和画板原稿会保留。") }
        .confirmationDialog("更新这个功能包？", isPresented: Binding(get: { updating != nil }, set: { if !$0 { updating = nil } })) {
            Button("更新功能包") { if let item = updating { model.install([item.url], kind: .application, replace: true) }; updating = nil }
            Button("取消", role: .cancel) { updating = nil }
        } message: { Text("使用软件内置的版本替换同名应用，保留其存档。") }
    }
    private func installed(_ item: ReadPicoBundledApplication) -> ReadPicoCardFile? {
        model.files.first { $0.kind == .application && $0.relativePath == item.relativePath }
    }
}
