import AppKit
import SwiftUI
import LinxDisplayCore

/// Native per-instance editing. Repeating a module never shares mutable text, image or timing state.
@MainActor
struct ReadPicoBoardPlaylistEditor: View {
    @ObservedObject var model: AppModel
    @Binding var playlist: ReadPicoBoardPlaylist
    let deviceID: UUID
    var drafts: ReadPicoDraftGuard? = nil
    let landscape: Bool
    let onPreview: (UUID) -> Void
    @ObservedObject private var library = PicoNativeLibrary.shared
    @State private var selectedID: UUID?
    @State private var entitySearch = ""
    @State private var error = ""
    @State private var showImagePicker = false
    @State private var pendingPhoto: PhotoRequest?
    @State private var photoRequest: PhotoRequest?
    @State private var imageSource: NSImage?
    @State private var imageError = ""

    private struct PhotoRequest: Identifiable {
        let id = UUID()
        let itemID: UUID
        let assetID: UUID?
        let source: NSImage
        let target: PicoPreviewTarget
        let initial: PicoPhotoEdit?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("轮播内容").font(.headline)
                Text("\(playlist.items.count)/\(ReadPicoBoardPlaylist.maximumItems)")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(CanvasModule.oraclePanelModules) { module in
                        Button { add(module) } label: { Label(module.title, systemImage: module.icon) }
                    }
                } label: { Label("添加模块", systemImage: "plus") }
                    .disabled(playlist.items.count >= ReadPicoBoardPlaylist.maximumItems)
            }
            Text("每项独占一屏，按顺序轮播；同一种模块可以重复添加，分别编辑。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if playlist.items.isEmpty {
                ContentUnavailableView("添加第一项轮播内容", systemImage: "rectangle.stack.badge.plus",
                                       description: Text("可添加时钟、图片、文字、阅读摘录或实时信息模块。"))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(playlist.items) { item in itemRow(item) }
                    }.padding(.trailing, 3)
                }.frame(minHeight: 76, maxHeight: 260)
            }
            if let item = selected {
                Divider()
                itemEditor(item)
            }
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { ensureSelection() }
        .onChange(of: playlist.items.map(\.id)) { _, _ in ensureSelection() }
        .onChange(of: selectedID) { _, _ in entitySearch = ""; refreshImage() }
        .onChange(of: landscape) { _, _ in refreshImage() }
        .onReceive(library.objectWillChange) { _ in
            if imageSource == nil, selected?.module == CanvasModule.image.rawValue {
                Task { @MainActor in refreshImage() }
            }
        }
        .sheet(isPresented: $showImagePicker, onDismiss: {
            photoRequest = pendingPhoto; pendingPhoto = nil
        }) {
            SharedWallpaperPicker(title: "为轮播项选择图片") { asset, source in
                guard let item = selected else { return }
                pendingPhoto = PhotoRequest(itemID: item.id, assetID: asset.id, source: source,
                                            target: target, initial: nil)
            }
        }
        .sheet(item: $photoRequest) { request in
            PicoPhotoEditor(image: request.source, target: request.target, initial: request.initial, drafts: drafts,
                            applicationNote: "仅更新这一项轮播的图片与构图，应用后可预览并发送。") { edit in
                applyPhoto(request, edit: edit)
            }
        }
    }

    private var selected: ReadPicoBoardPlaylistItem? { playlist.item(id: selectedID) }
    private var target: PicoPreviewTarget { landscape ? .picoLandscape : .pico }
    private func binding<Value>(_ keyPath: WritableKeyPath<ReadPicoBoardPlaylistItem, Value>,
                                fallback: Value) -> Binding<Value> {
        let id = selectedID
        return Binding(get: { playlist.item(id: id)?[keyPath: keyPath] ?? fallback }, set: { value in
            guard let index = playlist.items.firstIndex(where: { $0.id == id }) else { return }
            playlist.items[index][keyPath: keyPath] = value
        })
    }
    private func ensureSelection() {
        if selected == nil { selectedID = playlist.items.first?.id }
        refreshImage()
    }
    private func add(_ module: CanvasModule) {
        guard let id = playlist.add(module: module.rawValue, name: module.title) else {
            error = "轮播项已达到上限。"; return
        }
        selectedID = id; error = ""
        if module != .image { onPreview(id) }
    }
    private func itemRow(_ item: ReadPicoBoardPlaylistItem) -> some View {
        let module = CanvasModule(rawValue: item.module)
        return HStack(spacing: 9) {
            Toggle("启用\(item.name)", isOn: Binding(get: {
                playlist.item(id: item.id)?.enabled ?? false
            }, set: { enabled in
                guard let index = playlist.items.firstIndex(where: { $0.id == item.id }) else { return }
                playlist.items[index].enabled = enabled
            })).labelsHidden().toggleStyle(.checkbox)
            Button {
                selectedID = item.id; error = ""
                if item.enabled { onPreview(item.id) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: module?.icon ?? "square.dashed").frame(width: 19)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).lineLimit(1)
                        Text("\(module?.title ?? "未知模块") · \(item.durationSeconds) 秒")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 3)
                    if selectedID == item.id { Image(systemName: "checkmark").font(.callout.weight(.semibold)) }
                }.frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityAddTraits(selectedID == item.id ? [.isSelected] : [])
            Menu {
                Button("预览这一项", systemImage: "eye") { selectedID = item.id; onPreview(item.id) }.disabled(!item.enabled)
                Button("复制这一项", systemImage: "plus.square.on.square") {
                    if let id = playlist.duplicate(item.id) { selectedID = id; error = "" }
                    else { error = "无法复制：轮播项或图片原稿已达到容量上限。" }
                }.disabled(playlist.items.count >= ReadPicoBoardPlaylist.maximumItems)
                Divider()
                Button("向前移动", systemImage: "chevron.up") { playlist.move(item.id, by: -1) }.disabled(playlist.items.first?.id == item.id)
                Button("向后移动", systemImage: "chevron.down") { playlist.move(item.id, by: 1) }.disabled(playlist.items.last?.id == item.id)
                Divider()
                Button("移除这一项", systemImage: "trash", role: .destructive) { playlist.remove(item.id) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().frame(minWidth: 26, minHeight: 30)
                .accessibilityLabel("\(item.name)的更多操作")
        }.padding(8)
            .background(selectedID == item.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8))
    }
    private func itemEditor(_ item: ReadPicoBoardPlaylistItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("名称", text: binding(\.name, fallback: "")).textFieldStyle(.roundedBorder)
            HStack {
                Text("停留时间")
                Spacer()
                TextField("秒", value: binding(\.durationSeconds, fallback: 30), format: .number)
                    .frame(width: 64).multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                Stepper("秒", value: binding(\.durationSeconds, fallback: 30), in: 1...3600).fixedSize()
            }
            Text("从设备确认显示后开始计时，传输与等待不会占用停留时间。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("深色背景", isOn: binding(\.configuration.darkBackground, fallback: false))
            if let module = CanvasModule(rawValue: item.module) { moduleOptions(module) }
        }
    }
    @ViewBuilder private func moduleOptions(_ module: CanvasModule) -> some View {
        switch module {
        case .text:
            TextEditor(text: binding(\.configuration.text, fallback: ""))
                .font(.body).frame(minHeight: 110).border(Color.secondary.opacity(0.25))
            Text("文字只属于当前这一项。") .font(.caption).foregroundStyle(.secondary)
        case .image:
            HStack {
                Button(selected?.imageSourcePNG == nil && selected?.imageAssetID == nil ? "选择图片…" : "更换图片…",
                       systemImage: "photo") { showImagePicker = true }
                Button("调整构图…", systemImage: "crop.rotate") { editImage() }.disabled(imageSource == nil)
            }
            if let imageSource {
                Image(nsImage: imageSource).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 140)
            } else {
                Text(imageError.isEmpty ? "从壁纸库选择原图，为这一项单独调整构图。" : imageError)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .homeAssistant:
            TextField("查找实体", text: $entitySearch).textFieldStyle(.roundedBorder)
            let entities = model.haSnapshot.entities.filter { entitySearch.isEmpty || $0.displayName.localizedCaseInsensitiveContains(entitySearch) || $0.entityId.localizedCaseInsensitiveContains(entitySearch) }
            if entities.isEmpty {
                Text("连接 Home Assistant 后即可选择真实实体。") .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(entities.prefix(80)), id: \.entityId) { entity in
                            Toggle(entity.displayName, isOn: entityBinding(entity.entityId))
                                .disabled(!(selected?.configuration.entityIDs.contains(entity.entityId) ?? false) && (selected?.configuration.entityIDs.count ?? 0) >= 24)
                        }
                    }
                }.frame(maxHeight: 180)
            }
            Text("当前项已选 \(selected?.configuration.entityIDs.count ?? 0)/24 个实体。") .font(.caption).foregroundStyle(.secondary)
        case .nowPlaying:
            Toggle("封面与文字横向排布", isOn: binding(\.configuration.nowPlayingHorizontal, fallback: true))
        case .grokBot:
            Text("此版显示 Grok 状态与额度，暂不支持动画。")
                .font(.callout).foregroundStyle(.secondary)
        case .weather:
            Text(model.settings.weatherSnapshot.map { "\($0.city) · \($0.description)" } ?? "请在多屏灵犀天气页选择城市。")
                .font(.callout).foregroundStyle(.secondary)
            Button(model.weatherBusy ? "正在更新天气…" : "获取最新天气") {
                Task { await model.refreshWeather(); if let id = selectedID { onPreview(id) } }
            }.disabled(model.weatherBusy || !model.settings.weather.isValid)
        case .readingExcerpt:
            Text("从已授权给这台 Pico 的阅读笔记与摘录中获取内容。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        default:
            Text(module.bambuSlotIndex != nil || module.formlabsSlotIndex != nil
                 ? "使用多屏灵犀已配置的对应打印机与显示字段。"
                 : "使用多屏灵犀这一模块的实时数据与显示设置。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func entityBinding(_ entityID: String) -> Binding<Bool> {
        let itemID = selectedID
        return Binding(get: { playlist.item(id: itemID)?.configuration.entityIDs.contains(entityID) ?? false }, set: { enabled in
            guard let index = playlist.items.firstIndex(where: { $0.id == itemID }) else { return }
            playlist.items[index].configuration.entityIDs.removeAll { $0 == entityID }
            if enabled, playlist.items[index].configuration.entityIDs.count < 24 {
                playlist.items[index].configuration.entityIDs.append(entityID)
            }
        })
    }
    private func refreshImage() {
        imageSource = nil; imageError = ""
        guard let item = selected, item.module == CanvasModule.image.rawValue,
              item.imageSourcePNG != nil || item.imageAssetID != nil else { return }
        do { imageSource = try ReadPicoBoardPlaylistImage.source(for: item) }
        catch { imageError = error.localizedDescription }
    }
    private func editImage() {
        guard let item = selected, let imageSource else { return }
        do {
            let initial = try ReadPicoBoardPlaylistImage.edit(for: item, source: imageSource, landscape: landscape)
            photoRequest = PhotoRequest(itemID: item.id, assetID: item.imageAssetID,
                                        source: imageSource, target: target, initial: initial)
        } catch { self.error = error.localizedDescription }
    }
    private func applyPhoto(_ request: PhotoRequest, edit: PicoPhotoEdit) -> Bool {
        guard let index = playlist.items.firstIndex(where: { $0.id == request.itemID }),
              playlist.items[index].module == CanvasModule.image.rawValue else {
            error = "轮播项已移除，尚未应用图片。"; return false
        }
        do {
            var candidate = playlist
            candidate.items[index].imageAssetID = request.assetID
            candidate.items[index].imageEditData = try JSONEncoder().encode(edit.normalized())
            candidate.items[index].imageSourcePNG = try ReadPicoBoardPlaylistImage.portableSource(request.source)
            try candidate.validate()
            if let assetID = request.assetID, library.assets.contains(where: { $0.id == assetID }) {
                guard library.saveUse(assetID: assetID, key: "device.\(deviceID.uuidString).module.\(request.itemID.uuidString)",
                                      target: request.target, edit: edit) else {
                    error = library.error ?? "图片构图尚未保存，请重试。"; return false
                }
            }
            playlist = candidate; error = ""; refreshImage()
            if candidate.items[index].enabled { onPreview(request.itemID) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
