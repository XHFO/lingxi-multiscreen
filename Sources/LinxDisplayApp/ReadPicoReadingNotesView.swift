import AppKit
import Combine
import LinxDisplayCore
import SwiftUI

struct ReadPicoReadingDestination: Identifiable, Hashable {
    let id: String
    let title: String
}

@MainActor private final class ReadPicoReadingNotesModel: ObservableObject {
    @Published var notes: [ReadPicoReadingNote] = []
    @Published var selected = Set<String>()
    @Published var focusedID: String?
    @Published var permissions: [String: Bool] = [:]
    @Published var busy = false
    @Published var message = "同步 Pico 中的划线与批注，保留原文位置。"
    @Published var isError = false
    @Published var previewCard: ReadPicoReadingCard?
    @Published var syncReview: ReadPicoReadingNotesSyncReview?
    @Published var syncPolicy: ReadPicoReadingNotesSyncPolicy = .merge
    let store: ReadPicoReadingNotesStore
    private var reloadID = UUID()
    private var activeTarget = ""
    init(store: ReadPicoReadingNotesStore) { self.store = store }
    func reload(target: String) async {
        let request = UUID(); reloadID = request
        if activeTarget != target { previewCard = nil; permissions = [:] }
        activeTarget = target
        do {
            let latestNotes = try await store.notes()
            let latestPermissions = target.isEmpty ? [:] : try await store.authorization(target: target)
            guard reloadID == request, !Task.isCancelled else { return }
            notes = latestNotes
            selected.formIntersection(Set(notes.map(\.id)))
            if !notes.contains(where: { $0.id == focusedID }) { focusedID = notes.first?.id }
            permissions = latestPermissions
        } catch { if reloadID == request, !Task.isCancelled { report(error.localizedDescription, error: true) } }
    }
    func report(_ text: String, error: Bool = false) { message = text; isError = error }
    func importSource(_ url: URL, deviceID: UUID?, target: String, changed: @escaping () -> Void) {
        guard !busy else { return }
        busy = true; isError = false; message = "正在只读校验阅读记录与来源位置…"
        Task {
            defer { busy = false }
            do {
                let review = try await store.prepareImport(url, deviceID: deviceID)
                if review.needsReview {
                    syncPolicy = .merge; syncReview = review
                    report("发现两边记录存在差异，请选择合并或冲突保留方式。")
                    return
                }
                let result = try await store.applyImport(review, policy: .merge)
                await reload(target: target)
                report("已加入 \(result.imported) 条，跳过 \(result.duplicates) 条重复记录；Mac 共 \(result.total) 条。" + (result.usedBackup ? "已使用通过校验的备份记录。" : "") + "TF 卡原记录未改动。")
                changed()
            } catch { report(error.localizedDescription, error: true) }
        }
    }
    func cancelReview() { syncReview = nil; report("已取消同步，Mac 与 Pico 的原记录均保留。") }
    func applyReview(target: String, changed: @escaping () -> Void) {
        guard !busy, let review = syncReview else { return }
        let policy = syncPolicy; syncReview = nil; busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await store.applyImport(review, policy: policy)
                await reload(target: target)
                report("已加入 \(result.imported) 条，保留或跳过 \(result.duplicates) 条；Mac 共 \(result.total) 条。Pico 原记录未修改。")
                changed()
            } catch { report(error.localizedDescription, error: true) }
        }
    }
    func restorePrevious(target: String, changed: @escaping () -> Void) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                let count = try await store.restoreBeforeReconciliation()
                await reload(target: target); report("已恢复 \(count) 条同步前记录，当前记录与 Pico 原件保留。")
                changed()
            } catch { report(error.localizedDescription, error: true) }
        }
    }
    func authorize(target: String, includeNotes: Bool, remove: Bool, changed: @escaping () -> Void) {
        guard !busy, !selected.isEmpty, !target.isEmpty else { return }
        busy = true
        let ids = selected
        Task {
            defer { busy = false }
            do {
                if remove { try await store.removeAuthorization(noteIDs: ids, target: target) }
                else { try await store.setAuthorization(noteIDs: ids, target: target, includeNotes: includeNotes) }
                let latestPermissions = try await store.authorization(target: target)
                if activeTarget == target { permissions = latestPermissions }
                previewCard = nil
                report(remove ? "已从此设备的阅读卡片移除，Mac 原记录保留。" : "已允许 \(ids.count) 条记录用于此设备。" + (includeNotes ? "包括所选批注。" : "私人批注仍保留在 Mac。"))
                changed()
            } catch { report(error.localizedDescription, error: true) }
        }
    }
    func previewNext(target: String) {
        guard !busy, !target.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let card = try await store.nextCard(target: target, instance: "library-preview")
                guard activeTarget == target else { return }
                previewCard = card
                if card == nil { report("先选择划线或批注，再加入此设备卡片。没有引用正文的书签不参与轮播。") }
            } catch { report(error.localizedDescription, error: true) }
        }
    }
    func removeLocal(changed: @escaping () -> Void, target: String) {
        guard !busy, !selected.isEmpty else { return }
        busy = true; let ids = selected
        Task {
            defer { busy = false }
            do {
                try await store.removeFromMac(noteIDs: ids); selected = []; previewCard = nil
                await reload(target: target)
                report("已移除 Mac 副本及卡片授权；TF 卡上的原始记录保留。")
                changed()
            } catch { report(error.localizedDescription, error: true) }
        }
    }
}

/// Production annotation library. Its USB action only reads an already mounted card,
/// including firmware's committed internal/TF export snapshot;
/// it never starts MSC, ejects storage, sends a card, or changes device/firmware state.
@MainActor struct ReadPicoReadingNotesView: View {
    let deviceID: UUID?
    let mountedCardRoot: URL?
    let transferBusy: Bool
    let destinations: [ReadPicoReadingDestination]
    let onLibraryChanged: () -> Void
    let syncRequestID: UUID?
    let showsSyncButton: Bool
    let syncFailure: String?
    let onBusyChange: (Bool) -> Void
    @StateObject private var model: ReadPicoReadingNotesModel
    @State private var search = ""
    @State private var kind: ReadPicoReadingNoteKind?
    @State private var target = ""
    @State private var includeNotes = false
    @State private var showRemove = false
    @State private var showSharing = false
    @State private var pendingSyncRequest: UUID?
    init(deviceID: UUID? = nil, mountedCardRoot: URL? = nil, transferBusy: Bool = false,
         destinations: [ReadPicoReadingDestination] = [],
         syncRequestID: UUID? = nil, showsSyncButton: Bool = true,
         syncFailure: String? = nil,
         onBusyChange: @escaping (Bool) -> Void = { _ in },
         onLibraryChanged: @escaping () -> Void = {},
         store: ReadPicoReadingNotesStore = .shared) {
        self.deviceID = deviceID; self.mountedCardRoot = mountedCardRoot; self.transferBusy = transferBusy
        self.destinations = destinations; self.onLibraryChanged = onLibraryChanged
        self.syncRequestID = syncRequestID; self.showsSyncButton = showsSyncButton
        self.syncFailure = syncFailure
        self.onBusyChange = onBusyChange
        _model = StateObject(wrappedValue: ReadPicoReadingNotesModel(store: store))
    }
    private var actualDestinations: [ReadPicoReadingDestination] {
        if !destinations.isEmpty { return destinations }
        return deviceID.map { [.init(id: $0.uuidString, title: "当前小纸 Pico")] } ?? []
    }
    private var visible: [ReadPicoReadingNote] {
        model.notes.filter { note in
            (kind == nil || note.kind == kind) && (search.isEmpty || [note.sourceTitle, note.quote, note.note].contains { $0.localizedStandardContains(search) })
        }
    }
    private var focused: ReadPicoReadingNote? { model.notes.first { $0.id == model.focusedID } }
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                header
                if geometry.size.width >= 780 {
                    HSplitView {
                        records.frame(minWidth: 300)
                        ScrollView { detail.padding(.leading, 18).padding(.trailing, 4) }
                            .frame(minWidth: 280, idealWidth: 340)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            records.frame(minHeight: 220, idealHeight: 300)
                            Divider(); detail
                        }
                    }
                }
                status
            }.padding(20)
        }
        .task {
            if target.isEmpty { target = actualDestinations.first?.id ?? "" }
            await model.reload(target: target)
        }
        .task(id: target) { await model.reload(target: target) }
        .task(id: syncRequestID) {
            guard let request = syncRequestID else {
                if pendingSyncRequest != nil { model.report("已取消本次同步。") }
                pendingSyncRequest = nil; return
            }
            pendingSyncRequest = request
            synchronizeWhenReady()
            guard pendingSyncRequest == request else { return }
            if let syncFailure {
                pendingSyncRequest = nil; model.report(syncFailure, error: true); return
            }
            model.report("正在连接 Pico，连接后会自动同步。")
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard pendingSyncRequest == request else { return }
            pendingSyncRequest = nil
            model.report("Pico 尚未连接。请检查 USB，或打开连接选项后重试。", error: true)
        }
        .onChange(of: mountedCardRoot) { _, _ in synchronizeWhenReady() }
        .onChange(of: syncFailure) { _, failure in
            if pendingSyncRequest != nil, let failure {
                pendingSyncRequest = nil; model.report(failure, error: true)
            }
        }
        .onChange(of: model.busy) { _, busy in
            onBusyChange(busy)
            if !busy { synchronizeWhenReady() }
        }
        .onDisappear { pendingSyncRequest = nil; onBusyChange(false) }
        .onChange(of: target) { _, _ in includeNotes = false }
        .onChange(of: actualDestinations) { _, values in
            if !values.contains(where: { $0.id == target }) { target = values.first?.id ?? "" }
        }
        .confirmationDialog("仅移除 Mac 中的所选阅读记录？", isPresented: $showRemove, titleVisibility: .visible) {
            Button("移除 Mac 副本", role: .destructive) { model.removeLocal(changed: onLibraryChanged, target: target) }
            Button("取消", role: .cancel) {}
        } message: { Text("设备与 TF 卡的记录保留；这些记录在其他设备的阅读卡片授权也会移除。") }
        .sheet(item: $model.syncReview) { review in
            ReadPicoReadingNotesSyncSheet(review: review, policy: $model.syncPolicy,
                cancel: model.cancelReview, apply: { model.applyReview(target: target, changed: onLibraryChanged) })
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("划线与笔记").font(.title2.weight(.semibold))
                    Text("按书整理，随时回看。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                sourceButtons
            }
        }
    }
    @ViewBuilder private var sourceButtons: some View {
        if showsSyncButton {
            Button("同步", systemImage: "arrow.triangle.2.circlepath") {
                if let mountedCardRoot { model.importSource(mountedCardRoot, deviceID: deviceID, target: target, changed: onLibraryChanged) }
            }.buttonStyle(.borderedProminent).disabled(mountedCardRoot == nil || model.busy || transferBusy)
        }
        Menu {
            Button("导入记录文件或 TF 卡…", systemImage: "folder") { chooseSource() }
            Button("刷新 Mac 记录", systemImage: "arrow.clockwise") { Task { await model.reload(target: target) } }
            Button("恢复同步前的冲突记录", systemImage: "arrow.uturn.backward") { model.restorePrevious(target: target, changed: onLibraryChanged) }
            Divider()
            Text("书内记录通过 USB 同步；普通 TXT 在独立文本笔记中管理。")
        } label: { Label("更多", systemImage: "ellipsis.circle") }
            .disabled(model.busy || transferBusy)
    }
    private func synchronizeWhenReady() {
        guard pendingSyncRequest != nil, let mountedCardRoot, !model.busy else { return }
        pendingSyncRequest = nil
        model.importSource(mountedCardRoot, deviceID: deviceID, target: target, changed: onLibraryChanged)
    }
    private var records: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("搜索书名、划线或批注", text: $search).textFieldStyle(.roundedBorder)
            Picker("记录类型", selection: $kind) {
                Text("全部").tag(Optional<ReadPicoReadingNoteKind>.none)
                ForEach(ReadPicoReadingNoteKind.allCases, id: \.rawValue) { Text($0.title).tag(Optional($0)) }
            }.pickerStyle(.segmented).labelsHidden()
            if visible.isEmpty {
                ContentUnavailableView(model.notes.isEmpty ? "还没有导入书内记录" : "没有匹配记录", systemImage: "text.quote",
                                       description: Text(model.notes.isEmpty ? "将 TF 卡连接到 Mac 后同步；也可以选择已经复制到 Mac 的原始记录目录。" : "尝试其他关键词或记录类型。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selected) {
                    ForEach(visible) { note in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(note.kind.title).font(.caption.weight(.medium)).foregroundStyle(.secondary); Spacer(); if model.permissions[note.id] != nil { Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary).accessibilityLabel("已允许用于此设备卡片") } }
                            Text(note.quote.isEmpty ? note.note.isEmpty ? "阅读书签" : note.note : note.quote).lineLimit(3)
                            Text(note.sourceTitle + " · 第 \(note.chapter + 1) 节").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(.vertical, 6).tag(note.id)
                            .contextMenu { Button("查看详情") { model.focusedID = note.id }; Button("仅从 Mac 移除…", role: .destructive) { model.selected = [note.id]; showRemove = true } }
                    }
                }.listStyle(.inset).controlCenterHostedFormSurface()
                    .onChange(of: model.selected) { _, values in if let id = values.first { model.focusedID = id } }
                    .disabled(model.busy)
            }
            Text("Mac 共 \(model.notes.count) 条 · 已选 \(model.selected.count) 条").font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let note = focused {
                Text(note.sourceTitle).font(.headline)
                Text("\(note.kind.title) · 第 \(note.chapter + 1) 节").font(.callout).foregroundStyle(.secondary)
                if !note.quote.isEmpty { Text(note.quote).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                if !note.note.isEmpty {
                    GroupBox("我的批注 · 默认私有") { Text(note.note).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6) }
                }
                if !note.ink.isEmpty { Label("保留了 \(note.ink.count) 个旧笔迹点，未进行文字识别。", systemImage: "scribble.variable").font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("原文位置") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(note.bookPath).textSelection(.enabled)
                        Text("UTF-8 正文范围 \(note.start)–\(note.end) · 源文件 \(note.fileBytes) 字节")
                        Text("同步于 \(note.lastImportedAt.formatted(date: .abbreviated, time: .shortened))")
                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
            }
            if focused == nil {
                ContentUnavailableView("选择一条记录", systemImage: "text.quote", description: Text("查看划线、批注和书籍来源。"))
            }
            DisclosureGroup("用于设备阅读卡片", isExpanded: $showSharing) {
            VStack(alignment: .leading, spacing: 12) {
            if actualDestinations.isEmpty {
                Text("添加兼容画板设备后，可单独选择允许展示的引用内容。").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("目标设备", selection: $target) { ForEach(actualDestinations) { Text($0.title).tag($0.id) } }
                Toggle("也允许所选批注用于此设备", isOn: $includeNotes)
                    .font(.callout)
                Text("默认只展示引用与来源。授权按设备保存；各设备与模块分别轮换，每轮不重复。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("加入设备卡片") { model.authorize(target: target, includeNotes: includeNotes, remove: false, changed: onLibraryChanged) }.buttonStyle(.borderedProminent)
                    Button("移出") { model.authorize(target: target, includeNotes: false, remove: true, changed: onLibraryChanged) }
                }.disabled(model.selected.isEmpty || model.busy || target.isEmpty)
                if let card = model.previewCard {
                    GroupBox("卡片内容预览") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(card.quote)
                            if let note = card.note { Text(note).font(.callout).foregroundStyle(.secondary) }
                            Text(card.sourceTitle).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                Button("随机预览下一篇", systemImage: "shuffle") { model.previewNext(target: target) }
                    .disabled(model.busy || model.permissions.isEmpty)
            }
            }.padding(.top, 10)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var status: some View {
        HStack(alignment: .top, spacing: 10) {
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.message).font(.callout).foregroundStyle(model.isError ? Color.red : Color.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
    private func chooseSource() {
        pendingSyncRequest = nil
        let panel = NSOpenPanel(); panel.title = "导入 Pico 书内划线与批注"
        panel.message = "选择 TF 卡或 readpico/reading-notes 导出目录，可同时导入设备内置与 TF 卡记录。旧记录也可选择 books/.pico-system 文件夹或 reader-r3-index.dat。"
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importSource(url, deviceID: deviceID, target: target, changed: onLibraryChanged)
    }
}

private struct ReadPicoReadingNotesSyncSheet: View {
    let review: ReadPicoReadingNotesSyncReview
    @Binding var policy: ReadPicoReadingNotesSyncPolicy
    let cancel: () -> Void
    let apply: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("核对阅读记录差异").font(.title2.weight(.semibold))
            Text("仅 Mac \(review.macOnlyCount) 条 · 仅 Pico \(review.picoOnlyCount) 条 · 相同 \(review.sharedCount) 条")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("\(review.conflictingAnchors.count) 处相同原文位置的记录不同。独有记录与其他书籍记录都会保留。")
                .fixedSize(horizontal: false, vertical: true)
            Picker("同步方式", selection: $policy) {
                ForEach(ReadPicoReadingNotesSyncPolicy.allCases) { option in Text(option.title + (option == .merge ? "（推荐）" : "")).tag(option) }
            }.pickerStyle(.radioGroup)
            Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44, alignment: .topLeading)
            Text("Pico 中的划线和批注不会被改写。选择 Pico 版本后，可在“更多”中恢复同步前的 Mac 冲突记录。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack { Button("取消", action: cancel).keyboardShortcut(.cancelAction); Spacer(); Button("同步记录", action: apply).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 540).fixedSize(horizontal: false, vertical: true)
    }
    private var explanation: String {
        switch policy {
        case .merge: "保留同一位置的所有不同划线与批注；完全相同的记录自动去重。"
        case .preferMac: "同一位置存在不同记录时使用 Mac 记录；Pico 独有位置的记录仍会加入。"
        case .preferPico: "同一位置存在不同记录时使用 Pico 记录；Mac 原记录先保存，其他位置与其他书籍的记录保留。"
        }
    }
}
