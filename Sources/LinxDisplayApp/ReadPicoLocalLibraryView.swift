import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LinxDisplayCore

final class ReadPicoLibrarySyncCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = Set<Int>(), skipped = Set<Int>()
    func receive(_ value: ReadPicoLibraryProgress) {
        lock.lock(); defer { lock.unlock() }
        if value.stage == "completed" { finished.insert(value.fileIndex) }
        if value.stage == "skipped" { skipped.insert(value.fileIndex) }
    }
    var counts: (completed: Int, skipped: Int) {
        lock.lock(); defer { lock.unlock() }; return (finished.count, skipped.count)
    }
}

@MainActor final class ReadPicoLocalLibraryModel: ObservableObject {
    private static let sharedLibrary = Result { try ReadPicoLocalLibrary() }
    let library: ReadPicoLocalLibrary?
    @Published var items: [ReadPicoLibraryItem] = []
    @Published var selected = Set<String>()
    @Published var focusedID: String?
    @Published var busy = false
    @Published var message = "先导入到 Mac 资料库，预览后勾选同步到阅读器。"
    @Published var isError = false
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var syncProgress: ReadPicoLibraryProgress?
    @Published var awaitingConnection = false
    @Published var syncReview: ReadPicoLibrarySyncPlan?
    @Published var syncPolicy: ReadPicoLibrarySyncPolicy = .merge
    private var reviewOwner: String?
    private var pending: [ReadPicoLibraryItem] = []
    init(library: ReadPicoLocalLibrary? = nil) {
        if let library { self.library = library }
        else { self.library = try? Self.sharedLibrary.get() }
        if self.library == nil { message = "无法打开 Mac 本地资料库，请检查用户资料文件夹权限。"; isError = true }
    }
    func reload() async {
        guard let library else { return }
        do {
            items = try await library.items()
            selected.formIntersection(Set(items.map(\.id)))
            var images: [String: NSImage] = [:]
            for item in items {
                if let url = try await library.thumbnailURL(for: item), let image = NSImage(contentsOf: url) { images[item.id] = image }
            }
            thumbnails = images
        } catch { report(error.localizedDescription, error: true) }
    }
    func report(_ text: String, error: Bool = false) { message = text; isError = error }
    func importFiles(_ urls: [URL], kind: ReadPicoLibraryKind) {
        guard !busy, let library else { return }
        busy = true; isError = false
        Task {
            var imported: [ReadPicoLibraryItem] = [], failures: [String] = []
            for (index, url) in urls.enumerated() {
                message = "正在导入 Mac 资料库 \(index + 1)/\(urls.count)：\(url.lastPathComponent)…"
                do { imported.append(try await library.importFile(url, kind: kind)) }
                catch { failures.append(url.lastPathComponent + "：" + error.localizedDescription) }
            }
            await reload(); selected.formUnion(imported.map(\.id)); focusedID = imported.first?.id ?? focusedID
            busy = false
            report("已加入 Mac 资料库 \(imported.count) 项" + (failures.isEmpty ? "，尚未传输到设备。" : "；失败 \(failures.count) 项。\n" + failures.joined(separator: "\n")), error: !failures.isEmpty)
        }
    }
    func remove(_ item: ReadPicoLibraryItem) {
        guard !busy, let library else { return }
        busy = true
        Task {
            do { try await library.remove(item); await reload(); if focusedID == item.id { focusedID = nil }; report("已从 Mac 资料库移除，Pico 中的内容保留。") }
            catch { report(error.localizedDescription, error: true) }
            busy = false
        }
    }
    func beginSync(_ items: [ReadPicoLibraryItem], manager: ReadPicoManagerModel, requestConnection: () -> Void) {
        guard !busy, !manager.busy, !items.isEmpty else { return }
        guard manager.canManageContent else {
            pending = items; awaitingConnection = true
            report("已选 \(items.count) 项。请在上方连接 Wi-Fi 或 USB，连接后会继续同步。")
            requestConnection(); return
        }
        sync(items, manager: manager)
    }
    func cardConnected(manager: ReadPicoManagerModel, isActive: Bool = true) {
        guard isActive, awaitingConnection, manager.canManageContent, !manager.busy else { return }
        let batch = pending; pending = []; awaitingConnection = false
        sync(batch, manager: manager)
    }
    func cancelPending() { pending = []; awaitingConnection = false; report("已取消等待连接，资料仍保存在 Mac。") }
    private func sync(_ batch: [ReadPicoLibraryItem], manager: ReadPicoManagerModel) {
        guard let library else { return }
        syncProgress = nil; busy = true; report("正在核对两边的资料，尚未传输…")
        manager.prepareLibrarySync(batch, library: library) { [weak self] plan in
            guard let self else { return }
            self.busy = false
            guard let plan else { self.report(manager.message, error: manager.isError); return }
            if plan.needsReview {
                self.syncPolicy = .merge; self.reviewOwner = manager.librarySyncConnectionID; self.syncReview = plan
                self.report("发现 \(plan.differenceCount) 项差异，请选择如何同步。")
            } else { self.applySync(batch, manager: manager) }
        }
    }
    func cancelSyncReview() { syncReview = nil; reviewOwner = nil; report("已取消同步，两边的资料保持原样。") }
    func syncReviewDismissed() { if reviewOwner != nil { cancelSyncReview() } }
    func applySyncReview(manager: ReadPicoManagerModel) {
        guard let plan = syncReview, !manager.busy else { return }
        guard reviewOwner == manager.librarySyncConnectionID else { cancelSyncReview(); report("设备连接已变更，请重新核对同步差异。", error: true); return }
        let policy = syncPolicy
        syncReview = nil; reviewOwner = nil
        applySync(plan.entries.map(\.item), manager: manager, plan: plan, policy: policy)
    }
    private func applySync(_ batch: [ReadPicoLibraryItem], manager: ReadPicoManagerModel,
                           plan: ReadPicoLibrarySyncPlan? = nil, policy: ReadPicoLibrarySyncPolicy = .merge) {
        guard let library else { return }
        busy = true
        manager.synchronizeLibrary(batch, library: library, plan: plan, policy: policy, progress: { [weak self] value in self?.syncProgress = value }) { [weak self] success in
            guard let self else { return }
            let result = manager.message
            Task {
                await self.reload()
                self.report(result, error: !success)
                self.busy = false
            }
        }
    }
}

struct ReadPicoLocalLibraryView: View {
    @Environment(\.controlCenterUsesFloatingSurface) private var usesFloatingSurface
    @ObservedObject var library: ReadPicoLocalLibraryModel
    @ObservedObject var manager: ReadPicoManagerModel
    let kind: ReadPicoLibraryKind
    var isActive = true
    let requestConnection: () -> Void
    @State private var search = ""
    @State private var pendingDelete: ReadPicoLibraryItem?
    private var visible: [ReadPicoLibraryItem] { library.items.filter { $0.kind == kind && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.filename.localizedCaseInsensitiveContains(search)) } }
    private var selected: [ReadPicoLibraryItem] { visible.filter { library.selected.contains($0.id) } }
    private var focused: ReadPicoLibraryItem? { visible.first { $0.id == library.focusedID } ?? selected.first ?? visible.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("搜索本地\(kind.title)", text: $search).textFieldStyle(.roundedBorder)
                Button("导入到 Mac…", systemImage: "plus") { importFiles() }.disabled(library.busy || manager.busy)
                syncButton
            }
            HStack(spacing: 12) {
                Toggle("全选", isOn: Binding(get: { !visible.isEmpty && visible.allSatisfy { library.selected.contains($0.id) } }, set: { value in
                    if value { library.selected.formUnion(visible.map(\.id)) } else { library.selected.subtract(visible.map(\.id)) }
                })).toggleStyle(.checkbox).disabled(visible.isEmpty || manager.busy)
                Text("\(visible.count) 项 · 已选 \(selected.count) 项").foregroundStyle(.secondary)
                Spacer()
                if library.busy { ProgressView().controlSize(.small) }
                if library.awaitingConnection { Button("取消等待") { library.cancelPending() } }
                Text("保存在此 Mac").foregroundStyle(.secondary)
            }.font(.callout)
            if let progress = library.syncProgress, manager.busy {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("\(progress.fileIndex)/\(progress.fileCount) · \(progress.filename)").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(stageLabel(progress.stage)).foregroundStyle(.secondary)
                    }.font(.callout)
                    ProgressView(value: Double(progress.overallCompletedBytes), total: Double(max(1, progress.overallTotalBytes)))
                    Text("当前文件 \(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)) · 总计 \(ByteCountFormatter.string(fromByteCount: progress.overallCompletedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.overallTotalBytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }.accessibilityElement(children: .combine)
            }
            if visible.isEmpty {
                ContentUnavailableView(search.isEmpty ? "把\(kind.title)加入本地资料库" : "没有匹配的资料", systemImage: symbol,
                    description: Text(search.isEmpty ? importDescription : "换一个书名、文件名或字体名称试试。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(visible, selection: $library.focusedID) { item in libraryRow(item).tag(item.id) }
                        .listStyle(.inset).controlCenterHostedFormSurface().frame(minWidth: 240, idealWidth: 360)
                    if let item = focused { preview(item).frame(minWidth: 205, idealWidth: 245, maxWidth: 360) }
                }.frame(maxHeight: .infinity)
            }
            Label(library.message, systemImage: library.isError ? "exclamationmark.circle" : "info.circle")
                .font(.callout).foregroundStyle(library.isError ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true).lineLimit(4).textSelection(.enabled)

        }.task { await library.reload() }
            .onChange(of: visible.map(\.id), initial: true) { _, ids in
                if !ids.contains(library.focusedID ?? "") { library.focusedID = ids.first }
            }
            .onChange(of: manager.canManageContent) { _, _ in library.cardConnected(manager: manager, isActive: isActive) }
            .onChange(of: manager.busy) { _, busy in if !busy { library.cardConnected(manager: manager, isActive: isActive) } }
            .confirmationDialog("从 Mac 资料库移除“\(pendingDelete?.title ?? "")”？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                if let item = pendingDelete { Button("从本地移除", role: .destructive) { library.remove(item); pendingDelete = nil } }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { Text("只移除多屏灵犀保存的副本，不会删除原始文件或 Pico 中的内容。") }
            .sheet(item: $library.syncReview, onDismiss: library.syncReviewDismissed) { plan in
                ReadPicoLibrarySyncReview(plan: plan, policy: $library.syncPolicy,
                    cancel: library.cancelSyncReview,
                    apply: { library.applySyncReview(manager: manager) })
            }
    }
    private var syncButton: some View {
        Button(!manager.canManageContent ? "连接并同步所选…" : "同步所选到 Pico", systemImage: "arrow.triangle.2.circlepath") {
            library.beginSync(selected, manager: manager, requestConnection: requestConnection)
        }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || library.busy || manager.busy || library.awaitingConnection)
            .help("只同步已勾选的资料；本地和设备中的其他内容会保留。")
    }
    private var symbol: String { kind == .book ? "books.vertical" : kind == .font ? "textformat" : "note.text" }
    private var importDescription: String {
        switch kind {
        case .book: return "导入 EPUB 或 TXT 后可预览封面与文字，勾选后再同步。设备不必现在连接。"
        case .font: return "导入 TrueType TTF，先查看实际字体样张，再勾选同步。Pico 不支持 OTF、CFF 或 TTC 字体集合。"
        case .note: return "导入 TXT 或 Markdown 笔记，预览后作为独立可阅读文本同步。不会覆盖书籍批注或划线。"
        }
    }
    private func libraryRow(_ item: ReadPicoLibraryItem) -> some View {
        HStack(spacing: 9) {
            Toggle("选择\(item.title)", isOn: Binding(get: { library.selected.contains(item.id) }, set: { value in
                if value { library.selected.insert(item.id) } else { library.selected.remove(item.id) }
            })).labelsHidden().toggleStyle(.checkbox).disabled(manager.busy)
            Group {
                if let image = library.thumbnails[item.id] { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(systemName: symbol).font(.title2).foregroundStyle(.secondary) }
            }.frame(width: 42, height: 56).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(syncLabel(item)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 5).contentShape(Rectangle()).onTapGesture { library.focusedID = item.id }
            .background(library.focusedID == item.id ? Color.accentColor.opacity(0.1) : .clear)
            .contextMenu { Button("预览") { library.focusedID = item.id }; Button("从本地移除…", role: .destructive) { pendingDelete = item }.disabled(manager.busy || library.busy) }
            .accessibilityElement(children: .contain)
    }
    private func preview(_ item: ReadPicoLibraryItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let image = library.thumbnails[item.id] {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: kind == .book ? 235 : 180)
                        .accessibilityLabel(kind == .book ? "图书预览缩略图" : kind == .font ? "实际字体样张" : "笔记缩略图")
                }
                Text(item.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(item.filename).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.callout).foregroundStyle(.secondary)
                if item.kind == .font && URL(fileURLWithPath: item.filename).pathExtension.lowercased() != "ttf" {
                    Text("此旧字体仅保留在 Mac，不能同步到 Pico。请重新导入 TrueType TTF 字体。").font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                Text(item.previewText.isEmpty ? "此文件没有可显示的文字预览。" : item.previewText).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if kind == .note { Text("同步为独立文本，不与书籍的划线或批注记录合并。").font(.caption).foregroundStyle(.secondary) }
                Button("从本地移除…", role: .destructive) { pendingDelete = item }.disabled(manager.busy || library.busy)
            }.padding(12)
        }.background(usesFloatingSurface ? Color.primary.opacity(0.035) : Color(nsColor: .controlBackgroundColor))
    }
    private func syncLabel(_ item: ReadPicoLibraryItem) -> String {
        if item.kind == .font && URL(fileURLWithPath: item.filename).pathExtension.lowercased() != "ttf" { return "仅保留在 Mac · Pico 仅支持 TTF" }
        guard manager.canManageContent else { return "尚未核对设备" }
        let exists = manager.files.contains { file in file.kind == item.kind.fileKind && (file.title == item.title || file.relativePath.hasSuffix("/" + item.filename)) }
        return exists ? "Pico 中有同名内容" : "可同步到 Pico"
    }
    private func stageLabel(_ stage: String) -> String {
        switch stage { case "copying": return "正在传输"; case "verifying": return "正在校验"; case "committing": return "正在保存"; case "skipped": return "已跳过相同内容"; case "completed": return "已完成"; default: return "正在准备" }
    }
    private func importFiles() {
        let panel = NSOpenPanel(); panel.title = "导入\(kind.title)到 Mac 资料库"; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        let extensions = kind == .book ? ["epub", "txt"] : kind == .font ? ["ttf"] : ["txt", "md", "markdown"]
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { library.importFiles(panel.urls, kind: kind) }
    }
}

/// Native reconciliation sheet: one task, explicit source preference and a reversible default.
struct ReadPicoLibrarySyncReview: View {
    let plan: ReadPicoLibrarySyncPlan
    @Binding var policy: ReadPicoLibrarySyncPolicy
    let cancel: () -> Void
    let apply: () -> Void
    @State private var showsFiles = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("核对同步差异").font(.title2.weight(.semibold))
                Text("选择两边资料的处理方式。独有内容不会被删除。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 24) {
                count(plan.macOnlyCount, "仅 Mac")
                count(plan.picoOnly.count, "仅 Pico")
                count(plan.conflictCount, "同名不同内容")
                count(plan.identicalCount, "相同")
            }.frame(maxWidth: .infinity, alignment: .leading)
            Picker("同步方式", selection: $policy) {
                ForEach(ReadPicoLibrarySyncPolicy.allCases) { option in Text(option.title + (option == .merge ? "（推荐）" : "")).tag(option) }
            }.pickerStyle(.radioGroup)
            Text(policy.explanation).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 36, alignment: .topLeading)
            DisclosureGroup("查看差异文件", isExpanded: $showsFiles) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(plan.entries.filter { $0.difference != .identical }.enumerated()), id: \.offset) { _, entry in
                            HStack { Text(entry.item.filename).lineLimit(1).truncationMode(.middle); Spacer(); Text(entry.difference == .conflict ? "同名冲突" : "仅 Mac").foregroundStyle(.secondary) }
                        }
                        ForEach(plan.picoOnly, id: \.relativePath) { file in
                            HStack { Text(file.relativePath).lineLimit(1).truncationMode(.middle); Spacer(); Text("仅 Pico").foregroundStyle(.secondary) }
                        }
                    }.font(.callout).padding(.top, 8)
                }.frame(maxHeight: 160)
            }
            Text("仅处理本次所选资料的类型。书内划线、阅读进度和画稿不随文件替换删除。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack { Button("取消", action: cancel).keyboardShortcut(.cancelAction); Spacer(); Button("开始同步", action: apply).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 580).fixedSize(horizontal: false, vertical: true)
    }
    private func count(_ value: Int, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value.formatted()).font(.title2.monospacedDigit()); Text(title).font(.callout).foregroundStyle(.secondary) }.accessibilityElement(children: .combine)
    }
}
