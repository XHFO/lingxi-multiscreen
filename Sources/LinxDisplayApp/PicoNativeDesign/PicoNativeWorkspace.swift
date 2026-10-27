import AppKit
import SwiftUI

/// Isolated native design workspace. It never creates a device connection or sends content.
@MainActor
struct PicoNativeWorkspace: View {
    @StateObject private var library = PicoNativeLibrary()
    @StateObject private var design = PicoNativeWorkspaceModel()
    @State private var page: PicoNativePage? = .wallpapers
    @State private var selectedAssetID: UUID?
    @State private var destination: PicoNativeDestination = .lock
    @State private var editor: PicoNativeEditorRequest?
    @State private var picker: PicoNativePickerRequest?
    @State private var showTFDesign = false

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    Label("壁纸库", systemImage: "photo.on.rectangle.angled").tag(PicoNativePage.wallpapers)
                }
                Section("小纸 Pico") {
                    ForEach(PicoNativePage.devicePages) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("多屏灵犀")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "pencil.and.outline")
                    Text("原生设计预览 · 未连接设备")
                    Spacer()
                    Text("设备功能仅预览，图片资料保存在这台 Mac")
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
                Divider()
                detail
            }
            .navigationTitle((page ?? .wallpapers).title)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 920, minHeight: 660)
        .onAppear { if selectedAssetID == nil { selectedAssetID = library.assets.first?.id } }
        .onChange(of: library.assets.map(\.id)) { _, ids in
            if selectedAssetID == nil || !ids.contains(selectedAssetID!) { selectedAssetID = ids.last }
        }
        .sheet(item: $editor) { request in
            PicoPhotoEditor(image: request.image, target: request.target, initial: request.initial) { edit in
                if let moduleID = request.moduleID {
                    design.updateModuleImage(moduleID, assetID: request.asset.id, edit: edit)
                    design.notice = "模块图片调整仅保留在本次窗口草稿，未发送到设备。"
                } else {
                    guard library.saveUse(assetID: request.asset.id, key: request.key, target: request.target, edit: edit) else { return false }
                    design.notice = "已保存这台 Mac 上的图片参数，未发送到设备。"
                }
                return true
            }
        }
        .sheet(item: $picker) { request in
            PicoNativeAssetPicker(library: library, title: "选择共享壁纸") { asset in
                let edit = PicoPhotoEdit.centered(source: CGSize(width: asset.width, height: asset.height), target: request.target)
                if let id = request.moduleID {
                    design.updateModuleImage(id, assetID: asset.id, edit: edit)
                    design.notice = "模块图片引用仅保留在本次窗口草稿，其他目标的裁剪保持不变。"
                } else {
                    guard library.saveUse(assetID: asset.id, key: request.key, target: request.target, edit: edit) else { return }
                    design.notice = "已为当前目标引用原图，其他目标的裁剪保持不变。"
                }
                picker = nil
            }
        }
        .sheet(isPresented: $showTFDesign) { PicoNativeTFDesign() }
        .alert("图片资料库", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("好") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }

    @ViewBuilder private var detail: some View {
        switch page ?? .wallpapers {
        case .wallpapers: wallpapers
        case .excerpts: PicoNativeExcerptsPanel(design: design)
        case .board:
            PicoNativeBoardPanel(design: design, asset: assetForKey, preview: previewForKey,
                                 chooseImage: { openPicker($0) }, editImage: { openEditor($0) })
        case .lock: lockScreen
        case .tf:
            VStack(alignment: .leading, spacing: 18) {
                Text("TF 图片锁屏流程").font(.title2.bold())
                Text("预览在设备上选择图片、设置排布和每次锁屏换图的流程。这里不读取 TF 卡，也不保存设备设置。")
                    .foregroundStyle(.secondary).frame(maxWidth: 620, alignment: .leading)
                Button("打开设备流程预览") { showTFDesign = true }.buttonStyle(.borderedProminent)
                Spacer()
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var wallpapers: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("壁纸库").font(.title2.bold())
                    Text("共享原图，各设备独立裁剪。导入与图片参数会保存在 Mac。").foregroundStyle(.secondary)
                }
                Spacer()
                if library.isImporting { ProgressView().controlSize(.small); Text("正在导入…").font(.caption).foregroundStyle(.secondary) }
                Button("导入图片…", systemImage: "plus") { library.importImages() }.disabled(library.isImporting)
            }
            HSplitView {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 15)], spacing: 15) {
                        ForEach(library.assets) { asset in
                            Button { selectedAssetID = asset.id } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Image(nsImage: library.thumbnail(for: asset)).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 110)
                                        .background(Color(nsColor: .controlBackgroundColor))
                                    Text(asset.name).font(.callout).lineLimit(2)
                                    Text("\(asset.width) × \(asset.height)").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(9)
                                .background(selectedAssetID == asset.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedAssetID == asset.id ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.trailing, 16).padding(.vertical, 2)
                }.frame(minWidth: 280)
                wallpaperInspector.frame(minWidth: 255, idealWidth: 285, maxWidth: 320).padding(.leading, 20)
            }
            notice
        }.padding(24)
    }

    @ViewBuilder private var wallpaperInspector: some View {
        if let asset = selectedAsset, let image = library.image(for: asset) {
            VStack(alignment: .leading, spacing: 15) {
                Picker("调用目标", selection: $destination) {
                    ForEach(PicoNativeDestination.allCases) { Text($0.title).tag($0) }
                }
                let use = library.use(for: destination.rawValue)
                let edit = use?.assetID == asset.id ? use?.edit : nil
                PicoNativeImagePreview(image: image, edit: edit, target: destination.target)
                Text(asset.name).font(.headline)
                Text("原图不会被裁剪覆盖。当前目标的方向、裁剪和灰阶参数独立保存。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("编辑图片…", systemImage: "crop.rotate") { openEditor(destination.rawValue, asset: asset) }
                    .buttonStyle(.borderedProminent)
                Text(destination.target == .pico ? "Pico · 684 × 1216 · 16 灰阶预览" : "\(destination.target.title) · 裁剪布局预览，输出能力待适配")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        } else {
            if let asset = selectedAsset {
                if library.imageLoadFailed(for: asset) {
                    ContentUnavailableView("无法读取原图", systemImage: "photo.badge.exclamationmark", description: Text("此图片的原文件可能已损坏或缺失。请选择其他图片，或重新导入可用的原文件。"))
                } else {
                    VStack(spacing: 12) { ProgressView(); Text("正在准备图片预览…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else { ContentUnavailableView("选择一张图片", systemImage: "photo", description: Text("可导入图片，或先使用三张内置样例。")) }
        }
    }

    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("图片锁屏").font(.title2.bold())
            HSplitView {
                if let image = rawImageForKey("lock") {
                    PicoNativeImagePreview(image: image, edit: editForKey("lock"), target: .pico)
                        .frame(minWidth: 260, maxWidth: .infinity)
                } else if let asset = assetForKey("lock"), library.imageLoadFailed(for: asset) {
                    ContentUnavailableView("无法读取锁屏原图", systemImage: "photo.badge.exclamationmark", description: Text("原文件可能已损坏或缺失，请选择其他图片。"))
                        .frame(minWidth: 260, maxWidth: .infinity)
                } else if assetForKey("lock") == nil {
                    ContentUnavailableView("选择锁屏图片", systemImage: "photo", description: Text("从共享壁纸库选择一张图片。"))
                        .frame(minWidth: 260, maxWidth: .infinity)
                } else {
                    ProgressView("正在准备图片预览…").frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(alignment: .leading, spacing: 15) {
                    Text(assetForKey("lock")?.name ?? "共享壁纸库样例").font(.headline)
                    Text("图片引用自共享壁纸库。此处保存 Mac 草稿，下次实际连接后才可同步到设备。")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("选择图片…") { openPicker("lock") }
                        Button("编辑图片…") { openEditor("lock") }.buttonStyle(.borderedProminent)
                    }
                    Divider()
                    Text("设备端 TF 图片").font(.headline)
                    Text("直接选择 TF 卡中的图片或文件夹，选择单张或每次锁屏换图。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("设备流程预览…") { showTFDesign = true }
                    Spacer()
                    Label("不会自动锁屏，也不发送到设备", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(minWidth: 275, idealWidth: 310, maxWidth: 350).padding(.leading, 22)
            }
            notice
        }.padding(24)
    }

    private var notice: some View {
        Text(design.notice.isEmpty ? "所有设备操作均未连接；样例模块和摘录仅用于设计预览。" : design.notice)
            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var selectedAsset: PicoNativeAsset? { library.assets.first { $0.id == selectedAssetID } ?? library.assets.first }
    private func moduleID(for key: String) -> UUID? { key.hasPrefix("module.") ? UUID(uuidString: String(key.dropFirst(7))) : nil }
    private func assetForKey(_ key: String) -> PicoNativeAsset? {
        let id: UUID?
        if let moduleID = moduleID(for: key) { id = design.modules.first { $0.id == moduleID }?.assetID }
        else { id = library.use(for: key)?.assetID }
        return library.assets.first { $0.id == id } ?? library.assets.first
    }
    private func editForKey(_ key: String) -> PicoPhotoEdit? {
        if let moduleID = moduleID(for: key) { return design.modules.first { $0.id == moduleID }?.imageEdit }
        return library.use(for: key)?.edit
    }
    private func rawImageForKey(_ key: String) -> NSImage? { assetForKey(key).flatMap { library.image(for: $0) } }
    private func previewForKey(_ key: String) -> NSImage? {
        rawImageForKey(key).map { PicoPhotoRenderer.render(image: $0, edit: editForKey(key) ?? PicoPhotoEdit.centered(source: PicoPhotoRenderer.sourceSize(image: $0), target: .pico), target: .pico) }
    }
    private func openPicker(_ key: String) {
        picker = PicoNativePickerRequest(key: key, target: PicoNativeDestination(rawValue: key)?.target ?? .pico, moduleID: moduleID(for: key))
    }
    private func openEditor(_ key: String, asset explicitAsset: PicoNativeAsset? = nil) {
        guard let asset = explicitAsset ?? assetForKey(key) else { return }
        guard let image = library.image(for: asset) else {
            design.notice = library.imageLoadFailed(for: asset) ? "无法读取此图片原文件，请选择其他图片后再编辑。" : "正在准备图片，请等预览出现后再打开编辑器。"
            return
        }
        let existingID = moduleID(for: key).flatMap { id in design.modules.first { $0.id == id }?.assetID } ?? library.use(for: key)?.assetID
        editor = PicoNativeEditorRequest(key: key, target: PicoNativeDestination(rawValue: key)?.target ?? .pico,
                                        asset: asset, image: image, initial: existingID == asset.id ? editForKey(key) : nil,
                                        moduleID: moduleID(for: key))
    }
}

private enum PicoNativePage: String, CaseIterable, Identifiable {
    case wallpapers, excerpts, board, lock, tf
    var id: String { rawValue }
    static let devicePages: [Self] = [.excerpts, .board, .lock, .tf]
    var title: String { switch self { case .wallpapers: "壁纸库"; case .excerpts: "笔记与摘录"; case .board: "灵犀画板"; case .lock: "图片锁屏"; case .tf: "TF 选图设计" } }
    var symbol: String { switch self { case .wallpapers: "photo.on.rectangle"; case .excerpts: "text.quote"; case .board: "rectangle.on.rectangle"; case .lock: "lock.rectangle"; case .tf: "sdcard" } }
}
private enum PicoNativeDestination: String, CaseIterable, Identifiable {
    case board, lock, oracle, excerpt
    var id: String { rawValue }
    var title: String { switch self { case .board: "Pico 组合画板"; case .lock: "Pico 图片锁屏"; case .oracle: "口袋先知"; case .excerpt: "摘录设备" } }
    var target: PicoPreviewTarget { switch self { case .board, .lock: .pico; case .oracle: .oracle; case .excerpt: .excerpt } }
}
private struct PicoNativeEditorRequest: Identifiable {
    let id = UUID()
    let key: String
    let target: PicoPreviewTarget
    let asset: PicoNativeAsset
    let image: NSImage
    let initial: PicoPhotoEdit?
    let moduleID: UUID?
}
private struct PicoNativePickerRequest: Identifiable {
    let id = UUID()
    let key: String
    let target: PicoPreviewTarget
    let moduleID: UUID?
}
private struct PicoNativeAssetPicker: View {
    @ObservedObject var library: PicoNativeLibrary
    let title: String
    let choose: (PicoNativeAsset) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(title).font(.title2.bold()); Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("选择共享原图，仅改变当前目标的引用。").foregroundStyle(.secondary)
            List(library.assets) { asset in
                HStack(spacing: 14) {
                    Image(nsImage: library.thumbnail(for: asset)).resizable().scaledToFit().frame(width: 64, height: 48)
                    VStack(alignment: .leading) { Text(asset.name); Text("\(asset.width) × \(asset.height)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("选择") { choose(asset) }
                }.padding(.vertical, 5)
            }.listStyle(.inset)
            Button("导入图片…") { library.importImages() }
        }.padding(22).frame(width: 600, height: 460)
    }
}
private struct PicoNativeImagePreview: View {
    let image: NSImage
    let edit: PicoPhotoEdit?
    let target: PicoPreviewTarget
    var body: some View {
        let output = PicoPhotoRenderer.render(image: image, edit: edit ?? PicoPhotoEdit.centered(source: PicoPhotoRenderer.sourceSize(image: image), target: target), target: target)
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            Image(nsImage: output).resizable().scaledToFit().padding(14)
        }
        .frame(maxWidth: .infinity).frame(height: 310)
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .accessibilityLabel("\(target.title)图片输出预览")
    }
}

// Sample-only state. No AppModel, USB, network or physical-device services are used.
@MainActor private final class PicoNativeWorkspaceModel: ObservableObject {
    @Published var notice = ""
    @Published var modules = [PicoNativeModule(kind: "clock", name: "阅读时钟"), PicoNativeModule(kind: "reading", name: "我的阅读摘录"), PicoNativeModule(kind: "weather", name: "出门前看天气")]
    @Published var permissions: [String: [UUID: Bool]] = [:]
    @Published var moduleDraft: [PicoNativeModule] = []
    @Published var readingCurrent: [String: UUID] = [:]
    private var readingRemaining: [String: [UUID]] = [:]
    let excerpts = PicoNativeExcerpt.samples
    func allowedExcerpts(for target: PicoPreviewTarget) -> [PicoNativeExcerpt] {
        excerpts.filter { permissions[target.rawValue]?[$0.id] != nil }
    }
    func cardExcerpt(for target: PicoPreviewTarget, instance: String) -> PicoNativeExcerpt? {
        let pool = allowedExcerpts(for: target)
        let key = target.rawValue + "." + instance
        return pool.first { $0.id == readingCurrent[key] } ?? pool.first
    }
    func nextExcerpt(for target: PicoPreviewTarget, instance: String) {
        let pool = allowedExcerpts(for: target)
        guard !pool.isEmpty else { return }
        let key = target.rawValue + "." + instance
        let current = cardExcerpt(for: target, instance: instance)?.id
        let allowedIDs = Set(pool.map(\.id))
        var remaining = readingRemaining[key]?.filter { allowedIDs.contains($0) } ?? pool.map(\.id).shuffled().filter { $0 != current }
        if remaining.isEmpty {
            remaining = pool.map(\.id).shuffled()
            if remaining.count > 1, remaining.first == current { remaining.swapAt(0, 1) }
        }
        readingCurrent[key] = remaining.removeFirst()
        readingRemaining[key] = remaining
    }
    func updateModuleImage(_ id: UUID, assetID: UUID, edit: PicoPhotoEdit?) {
        guard let i = modules.firstIndex(where: { $0.id == id }) else { return }
        modules[i].assetID = assetID; modules[i].imageEdit = edit
    }
}
private struct PicoNativeModule: Identifiable {
    let id = UUID()
    var kind: String
    var name: String
    var enabled = true
    var seconds = 60
    var text = "给阅读留一点时间。"
    var city = "上海"
    var assetID: UUID?
    var imageEdit: PicoPhotoEdit?
}
private struct PicoNativeExcerpt: Identifiable {
    let id: UUID
    let book: String
    let chapter: String
    let quote: String
    let note: String
    static let samples: [Self] = [
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, book: "阅读随记（演示）", chapter: "第一章 · 阅读时间", quote: "把注意力放回眼前的一页，答案不必总是立即出现。", note: "留给周末重新读一遍。"),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, book: "日常观察（演示）", chapter: "第二章 · 行走与记录", quote: "那些被认真记录的小事，会在以后连接成新的想法。", note: "可以用在下一次创作的开头。"),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, book: "阅读随记（演示）", chapter: "第三章 · 重新开始", quote: "不必等到一切准备完美，先把最重要的一小步做完。", note: "私人待办，默认只在资料库保留。")
    ]
}
private struct PicoNativeReadingCard: View {
    let excerpt: PicoNativeExcerpt?
    let target: PicoPreviewTarget
    let includeNote: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: target == .excerpt ? 8 : 16) {
            if let excerpt {
                Text("阅读摘录").font(.caption).foregroundStyle(.secondary)
                Text(excerpt.quote).font(target == .excerpt ? .callout : .title3).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                if includeNote { Text(excerpt.note).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Text(excerpt.book + " · " + excerpt.chapter).font(.caption2).foregroundStyle(.secondary)
            } else {
                Spacer()
                Label("尚无已授权摘录", systemImage: "text.quote").font(.callout).foregroundStyle(.secondary)
                Text("选择内容并加入此设备卡片").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(target == .excerpt ? 16 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .aspectRatio(target.size.width / target.size.height, contentMode: .fit)
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .accessibilityLabel("\(target.title)阅读卡片预览")
    }
}
private struct PicoNativeExcerptsPanel: View {
    @ObservedObject var design: PicoNativeWorkspaceModel
    @State private var target: PicoPreviewTarget = .pico
    @State private var selected = Set<UUID>()
    @State private var focused: UUID? = PicoNativeExcerpt.samples.first?.id
    @State private var includeNotes = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("笔记与摘录").font(.title2.bold())
            Text("三个虚构来源示例。未读取 Pico；只有你选择的内容可用于指定设备卡片。").foregroundStyle(.secondary)
            Picker("卡片目标", selection: $target) { ForEach(PicoPreviewTarget.allCases) { Text($0.title).tag($0) } }.frame(width: 260)
            HSplitView {
                List(selection: $focused) {
                    ForEach(design.excerpts) { excerpt in
                        HStack(alignment: .top) {
                            Toggle("选择摘录", isOn: Binding(get: { selected.contains(excerpt.id) }, set: { if $0 { selected.insert(excerpt.id) } else { selected.remove(excerpt.id) } })).labelsHidden()
                            VStack(alignment: .leading, spacing: 5) {
                                Text(excerpt.quote).lineLimit(3)
                                Text(excerpt.book).font(.caption).foregroundStyle(.secondary)
                                Text(design.permissions[target.rawValue]?[excerpt.id] == nil ? "仅私人资料库" : "已允许用于此设备卡片").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 7).tag(excerpt.id)
                    }
                }.frame(minWidth: 270)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let excerpt = design.excerpts.first(where: { $0.id == focused }) {
                            Text(excerpt.book).font(.headline)
                            Text(excerpt.chapter).font(.caption).foregroundStyle(.secondary)
                            Text(excerpt.quote).textSelection(.enabled)
                            DisclosureGroup("我的批注 · 默认私有") { Text(excerpt.note).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6) }
                        }
                        Divider()
                        HStack { Text("设备卡片预览").font(.headline); Spacer(); Text("仅已授权内容").font(.caption).foregroundStyle(.secondary) }
                        let card = design.cardExcerpt(for: target, instance: "library")
                        PicoNativeReadingCard(excerpt: card, target: target, includeNote: card.map { design.permissions[target.rawValue]?[$0.id] == true } ?? false)
                            .frame(maxWidth: target == .pico ? 185 : .infinity).frame(maxWidth: .infinity)
                        Button("随机预览下一篇", systemImage: "shuffle") { design.nextExcerpt(for: target, instance: "library") }.disabled(design.allowedExcerpts(for: target).isEmpty)
                        Text("每轮不重复；各设备与每个阅读模块分别记录播放进度。").font(.caption).foregroundStyle(.secondary)
                    }.padding(.leading, 20).padding(.trailing, 4)
                }.frame(minWidth: 265, idealWidth: 330)
            }
            HStack {
                Toggle("本次也允许所选批注用于卡片", isOn: $includeNotes)
                Spacer()
                Button("移出此设备卡片") { selected.forEach { design.permissions[target.rawValue, default: [:]].removeValue(forKey: $0) } }.disabled(selected.isEmpty)
                Button("加入此设备卡片") { selected.forEach { design.permissions[target.rawValue, default: [:]][$0] = includeNotes } }.disabled(selected.isEmpty).buttonStyle(.borderedProminent)
            }
            Text("授权只影响当前目标；其他设备及新添加设备默认没有授权。本次窗口内存草稿，尚未接入实际同步。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }
}
private enum PicoNativeBoardMode: String, CaseIterable, Identifiable {
    case carousel = "模块轮播", composition = "组合画板"
    var id: String { rawValue }
}
private struct PicoNativeBoardPanel: View {
    @ObservedObject var design: PicoNativeWorkspaceModel
    let asset: (String) -> PicoNativeAsset?
    let preview: (String) -> NSImage?
    let chooseImage: (String) -> Void
    let editImage: (String) -> Void
    @State private var selection: UUID?
    @State private var mode: PicoNativeBoardMode = .carousel
    @State private var overlay = "无"
    @State private var placement = "底部"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("灵犀画板").font(.title2.bold()); Spacer()
                if mode == .carousel {
                    Menu("添加模块") {
                        Button("时钟") { add("clock", "时钟") }
                        Button("阅读摘录") { add("reading", "阅读摘录") }
                        Button("天气") { add("weather", "天气") }
                        Button("自定义图片") { add("image", "自定义图片") }
                        Button("自定义文字") { add("text", "自定义文字") }
                    }
                }
            }
            Picker("画板模式", selection: $mode) { ForEach(PicoNativeBoardMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 290)
            Text(mode == .carousel ? "每个模块独立占一屏；同类模块可重复添加和分别配置。" : "将背景图片与内容组合在同一张画板，与整屏模块轮播分别配置。")
                .foregroundStyle(.secondary)
            if mode == .carousel { carousel } else { composition }
            Text(design.notice.isEmpty ? "原生预览不连接设备。模块与叠加设置只保留在本次窗口；图片原图和裁剪参数保存在 Mac。" : design.notice).font(.caption).foregroundStyle(.secondary)
        }.padding(24).onAppear { if selection == nil { selection = design.modules.first?.id } }
    }
    private var carousel: some View {
        VStack(spacing: 16) {
            HSplitView {
                List(selection: $selection) {
                    ForEach(design.modules) { module in
                        HStack {
                            Toggle("启用模块", isOn: binding(module.id, \.enabled)).labelsHidden()
                            VStack(alignment: .leading) { Text(module.name); Text("停留 \(module.seconds) 秒").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 6).tag(module.id)
                    }
                }.frame(minWidth: 235)
                ScrollView {
                    if let i = design.modules.firstIndex(where: { $0.id == selection }) {
                        moduleEditor(i).padding(.leading, 20).padding(.trailing, 4)
                    }
                }.frame(minWidth: 280, idealWidth: 350)
            }
            HStack {
                Button("预览下一项") { next() }.disabled(!design.modules.contains(where: \.enabled))
                Spacer()
                Button("保存本次预览草稿") { design.moduleDraft = design.modules; design.notice = "模块草稿仅保留在本次窗口内存，未发送到设备。" }
            }
        }
    }
    @ViewBuilder private func moduleEditor(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            TextField("实例名称", text: $design.modules[i].name).textFieldStyle(.roundedBorder)
            Stepper("停留 \(design.modules[i].seconds) 秒", value: $design.modules[i].seconds, in: 5...3600, step: 5)
            let key = "module.\(design.modules[i].id)"
            switch design.modules[i].kind {
            case "image":
                if let image = preview(key) { Image(nsImage: image).resizable().scaledToFit().frame(height: 250).frame(maxWidth: .infinity) }
                else { ProgressView("正在准备图片…").frame(height: 220).frame(maxWidth: .infinity) }
                Text(asset(key)?.name ?? "选择共享原图").font(.caption).foregroundStyle(.secondary)
                HStack { Button("选择图片…") { chooseImage(key) }; Button("编辑图片…") { editImage(key) } }
            case "text":
                TextEditor(text: $design.modules[i].text).frame(height: 180).border(Color(nsColor: .separatorColor))
            case "reading":
                let card = design.cardExcerpt(for: .pico, instance: key)
                PicoNativeReadingCard(excerpt: card, target: .pico, includeNote: card.map { design.permissions["pico"]?[$0.id] == true } ?? false).frame(maxWidth: 175).frame(maxWidth: .infinity)
                Button("随机预览下一篇", systemImage: "shuffle") { design.nextExcerpt(for: .pico, instance: key) }.disabled(design.allowedExcerpts(for: .pico).isEmpty)
                Text("只使用“笔记与摘录”中已授权给 Pico 的内容。").font(.caption).foregroundStyle(.secondary)
            case "weather":
                TextField("示例城市", text: $design.modules[i].city).textFieldStyle(.roundedBorder)
                Text("\(design.modules[i].city) · 22° · 晴").font(.title2).frame(maxWidth: .infinity, minHeight: 170)
                Text("天气为静态演示数据").font(.caption).foregroundStyle(.secondary)
            default:
                Text("10:24").font(.system(size: 56, weight: .light, design: .rounded)).monospacedDigit().frame(maxWidth: .infinity, minHeight: 190)
                Text("时钟为静态排版示例").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("上移") { move(i, -1) }.disabled(i == 0)
                Button("下移") { move(i, 1) }.disabled(i == design.modules.count - 1)
                Spacer()
                Button("移除", role: .destructive) { let id = design.modules[i].id; design.modules.removeAll { $0.id == id }; selection = design.modules.first?.id }
            }
        }
    }
    private var composition: some View {
        HSplitView {
            GeometryReader { geometry in
                let height = min(geometry.size.height, 440.0)
                let width = height * 684 / 1216
                ZStack(alignment: placement == "顶部" ? .top : placement == "中间" ? .center : .bottom) {
                    if let image = preview("board") { Image(nsImage: image).resizable().scaledToFit() }
                    else { Color.white; ProgressView("正在准备图片…") }
                    if overlay == "时钟" { Text("10:24").font(.system(size: 42, weight: .light)).monospacedDigit().padding(18).background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 8)).padding(14) }
                    if overlay == "阅读摘录", let card = design.cardExcerpt(for: .pico, instance: "composition") { Text(card.quote).font(.callout).lineSpacing(4).padding(16).background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 8)).padding(14) }
                }.frame(width: width, height: height).overlay(Rectangle().stroke(Color(nsColor: .separatorColor))).frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(minWidth: 260, minHeight: 300)
            VStack(alignment: .leading, spacing: 18) {
                Text(asset("board")?.name ?? "共享壁纸库样例").font(.headline)
                HStack { Button("选择背景…") { chooseImage("board") }; Button("编辑图片…") { editImage("board") }.buttonStyle(.borderedProminent) }
                Picker("叠加内容", selection: $overlay) { ForEach(["无", "时钟", "阅读摘录"], id: \.self) { Text($0).tag($0) } }
                Picker("显示位置", selection: $placement) { ForEach(["顶部", "中间", "底部"], id: \.self) { Text($0).tag($0) } }.disabled(overlay == "无")
                if overlay == "阅读摘录" { Button("随机预览下一篇") { design.nextExcerpt(for: .pico, instance: "composition") }.disabled(design.allowedExcerpts(for: .pico).isEmpty) }
                Text("Pico · 684 × 1216 · 16 灰阶图片预览").font(.caption).foregroundStyle(.secondary)
                Text("叠加排版为原生交互示意，尚未输出到设备；背景图片参数独立保存。").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }.padding(.leading, 20).frame(minWidth: 260, idealWidth: 310, maxWidth: 350)
        }
    }
    private func binding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<PicoNativeModule, Value>) -> Binding<Value> {
        let fallback = design.modules.first(where: { $0.id == id })![keyPath: keyPath]
        return Binding(get: { design.modules.first(where: { $0.id == id }).map { $0[keyPath: keyPath] } ?? fallback }, set: { value in if let i = design.modules.firstIndex(where: { $0.id == id }) { design.modules[i][keyPath: keyPath] = value } })
    }
    private func add(_ kind: String, _ name: String) { let module = PicoNativeModule(kind: kind, name: name); design.modules.append(module); selection = module.id }
    private func move(_ index: Int, _ amount: Int) { design.modules.swapAt(index, index + amount) }
    private func next() { let enabled = design.modules.filter(\.enabled); guard !enabled.isEmpty else { return }; let i = enabled.firstIndex(where: { $0.id == selection }) ?? -1; selection = enabled[(i + 1) % enabled.count].id }
}
private struct PicoNativeTFDesign: View {
    @Environment(\.dismiss) private var dismiss
    @State private var folder = true
    @State private var selected = "山间晨雾.jpg"
    @State private var random = true
    @State private var fill = false
    @State private var alignment = "居中"
    @State private var draft = false
    private let files = ["山间晨雾.jpg", "光与轨迹.png", "安静的纸面.bmp"]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("TF 图片锁屏 · 设备流程设计").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("仅使用虚构路径与图片示意，不读取 TF 卡，不写入设备设置，不会触发锁屏。").font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 10) {
                    fixture.frame(width: 185, height: 329).overlay(Rectangle().stroke(Color(nsColor: .separatorColor)))
                    Text("虚构图片排布示意").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 15)
                Form {
                    LabeledContent("示例目录", value: "/Pictures/Lockscreen/")
                    Toggle("使用整个文件夹", isOn: $folder)
                    if !folder { Picker("图片", selection: $selected) { ForEach(files, id: \.self) { Text($0).tag($0) } } }
                    Toggle("每次进入锁屏换一张", isOn: $random).disabled(!folder)
                    Toggle("填满屏幕并裁剪", isOn: $fill)
                    Picker("对齐", selection: $alignment) { ForEach(["左上", "居中", "右下"], id: \.self) { Text($0).tag($0) } }
                }.formStyle(.grouped)
            }
            Text("换图只发生在进入锁屏时，锁屏后不定时唤醒刷新。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("保留本次流程草稿") { draft = true }.buttonStyle(.borderedProminent) }
            Text(draft ? "流程草稿仅保留在此弹窗内，未保存到 Pico。" : "实际读取、格式校验与16灰缓存生成尚未接入。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 760, height: 560)
    }
    private var fixture: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let width = fill ? size.height * 1.5 : size.width
            let height = fill ? size.height : size.width / 1.5
            let position: Alignment = alignment == "左上" ? .topLeading : alignment == "右下" ? .bottomTrailing : .center
            ZStack(alignment: position) {
                Color.white
                ZStack {
                    LinearGradient(colors: [Color(white: 0.85), Color(white: 0.45)], startPoint: .top, endPoint: .bottom)
                    Circle().fill(Color(white: 0.95)).frame(width: width * 0.18).offset(x: width * 0.27, y: -height * 0.24)
                    Image(systemName: selected == "光与轨迹.png" ? "building.2.fill" : selected == "安静的纸面.bmp" ? "leaf.fill" : "mountain.2.fill")
                        .resizable().scaledToFit().foregroundStyle(Color(white: 0.2)).frame(width: width * 0.9, height: height * 0.72).offset(y: height * 0.23)
                }.frame(width: width, height: height).clipped()
            }.frame(width: size.width, height: size.height).clipped()
        }
    }
}
