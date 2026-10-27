import AppKit
import SwiftUI

/// The application-wide source library. It only edits local images and never sends to a device.
@MainActor
struct SharedWallpaperLibraryView: View {
    @ObservedObject private var library = PicoNativeLibrary.shared
    @State private var selectedID: UUID?
    @State private var search = ""
    @State private var destination: SharedWallpaperTemplate = .lock
    @State private var editRequest: SharedWallpaperEditRequest?
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("壁纸库").font(.title2.weight(.semibold))
                    Text("统一收藏原图，为不同设备分别调整显示方式。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                SharedWallpaperImportButton(library: library)
            }
            if library.assets.isEmpty {
                ContentUnavailableView {
                    Label("添加你的第一张壁纸", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("导入图片后可预览和裁剪；也可以在设备的画板与图片锁屏页面选择使用。")
                } actions: {
                    Button("导入图片…") { library.importImages() }
                        .buttonStyle(.borderedProminent).disabled(library.isImporting || !library.isWritable)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    VStack(spacing: 14) {
                        TextField("搜索图片", text: $search).textFieldStyle(.roundedBorder)
                        ScrollView {
                            if visibleAssets.isEmpty {
                                ContentUnavailableView.search(text: search).padding(.top, 40)
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 210), spacing: 14)], spacing: 14) {
                                    ForEach(visibleAssets) { asset in
                                        Button { selectedID = asset.id } label: {
                                            SharedWallpaperThumbnail(asset: asset, image: library.thumbnail(for: asset), selected: asset.id == selectedID)
                                        }.buttonStyle(.plain).accessibilityLabel("选择壁纸：\(asset.name)")
                                    }
                                }.padding(.trailing, 5).padding(.bottom, 6)
                            }
                        }
                    }.frame(minWidth: 270).padding(.trailing, 18)
                    ScrollView { inspector.frame(maxWidth: .infinity, alignment: .topLeading) }
                        .frame(minWidth: 265, idealWidth: 300, maxWidth: 340).padding(.leading, 20)
                }
            }
            Text(status.isEmpty ? "原图和编辑参数保存在这台 Mac。保存模板不会发送到设备。" : status)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: library.assets.map(\.id)) { oldIDs, newIDs in
            if let added = newIDs.last(where: { !Set(oldIDs).contains($0) }) { selectedID = added }
            else { selectFirstIfNeeded() }
        }
        .sheet(item: $editRequest) { request in
            PicoPhotoEditor(image: request.image, target: request.destination.target, initial: request.initial) { edit in
                guard library.saveUse(assetID: request.asset.id, key: request.destination.rawValue,
                                      target: request.destination.target, edit: edit) else { return false }
                status = "\(request.destination.title)已保存到这台 Mac；原图及其他用途的裁剪保持不变。"
                return true
            }
        }
        .modifier(SharedWallpaperLibraryError(library: library))
    }

    private var visibleAssets: [PicoNativeAsset] {
        search.isEmpty ? library.assets : library.assets.filter { $0.name.localizedStandardContains(search) }
    }
    private var selected: PicoNativeAsset? { library.assets.first { $0.id == selectedID } }
    private func selectFirstIfNeeded() {
        if selected == nil { selectedID = library.assets.first?.id }
    }
    @ViewBuilder private var inspector: some View {
        if let asset = selected {
            VStack(alignment: .leading, spacing: 16) {
                Text(asset.name).font(.headline).lineLimit(3)
                Text("\(asset.width) × \(asset.height) 像素").font(.caption).foregroundStyle(.secondary)
                Picker("预设用途", selection: $destination) {
                    ForEach(SharedWallpaperTemplate.allCases) { Text($0.title).tag($0) }
                }
                if let image = library.image(for: asset) {
                    let use = library.use(for: destination.rawValue)
                    let edit = use?.assetID == asset.id ? use?.edit : nil
                    SharedWallpaperTargetPreview(image: image, edit: edit, target: destination.target)
                    Button("调整图片…", systemImage: "crop.rotate") {
                        editRequest = SharedWallpaperEditRequest(asset: asset, image: image, destination: destination, initial: edit)
                    }.buttonStyle(.borderedProminent)
                    Text("\(Int(destination.target.size.width)) × \(Int(destination.target.size.height)) · \(destination.target.grayLevels == 16 ? "16 灰阶预览" : "布局预览")")
                        .font(.caption).foregroundStyle(.secondary)
                } else if library.imageLoadFailed(for: asset) {
                    ContentUnavailableView("无法读取原图", systemImage: "photo.badge.exclamationmark",
                                           description: Text("原文件可能已损坏或缺失，请选择其他图片或重新导入。"))
                } else {
                    ProgressView("正在准备原图…").frame(maxWidth: .infinity, minHeight: 240)
                }
                Text("模板用于预览不同屏幕的裁剪。设备中的画板与图片锁屏会分别保留各自设置。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        } else {
            ContentUnavailableView("选择一张壁纸", systemImage: "photo", description: Text("点击左侧图片查看原图与用途预览。"))
        }
    }
}

/// Source-only chooser shared by the real device pages. Cancellation never changes a draft.
@MainActor
struct SharedWallpaperPicker: View {
    let title: String
    let onSelect: (PicoNativeAsset, NSImage) -> Void
    @ObservedObject private var library = PicoNativeLibrary.shared
    @State private var selectedID: UUID?
    @Environment(\.dismiss) private var dismiss

    init(title: String = "从壁纸库选择", onSelect: @escaping (PicoNativeAsset, NSImage) -> Void) {
        self.title = title; self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                SharedWallpaperImportButton(library: library)
            }
            Text("选择保存在 Mac 的原图，确认后再为当前设备调整。")
                .foregroundStyle(.secondary)
            if library.assets.isEmpty {
                ContentUnavailableView("壁纸库还是空的", systemImage: "photo.stack",
                                       description: Text("导入图片后即可在各设备页面使用。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $selectedID) {
                        ForEach(library.assets) { asset in
                            HStack(spacing: 12) {
                                Image(nsImage: library.thumbnail(for: asset)).resizable().scaledToFit().frame(width: 58, height: 50)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(asset.name).lineLimit(2)
                                    Text("\(asset.width) × \(asset.height)").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 5).tag(asset.id)
                        }
                    }.listStyle(.inset).controlCenterHostedFormSurface().frame(minWidth: 300)
                    sourcePreview.frame(minWidth: 220, idealWidth: 250, maxWidth: 280).padding(.leading, 16)
                }
            }
            Divider()
            HStack {
                Text("仅选择原图，不发送到设备").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("使用此图片") {
                    guard let asset = selected, let image = library.image(for: asset) else { return }
                    onSelect(asset, image)
                    dismiss()
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(selected.flatMap { library.image(for: $0) } == nil)
            }
        }
        .padding(22).frame(width: 720, height: 500)
        .onAppear { if selected == nil { selectedID = library.assets.first?.id } }
        .onChange(of: library.assets.map(\.id)) { oldIDs, newIDs in
            if let added = newIDs.last(where: { !Set(oldIDs).contains($0) }) { selectedID = added }
            else if selected == nil { selectedID = newIDs.first }
        }
        .modifier(SharedWallpaperLibraryError(library: library))
    }
    private var selected: PicoNativeAsset? { library.assets.first { $0.id == selectedID } }
    @ViewBuilder private var sourcePreview: some View {
        if let asset = selected {
            if let image = library.image(for: asset) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .controlCenterHostedPanelSurface()
                    .accessibilityLabel("\(asset.name)原图预览")
            } else if library.imageLoadFailed(for: asset) {
                ContentUnavailableView("原图不可用", systemImage: "photo.badge.exclamationmark", description: Text("请选择其他图片。"))
            } else { ProgressView("正在准备原图…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        } else { ContentUnavailableView("选择一张图片", systemImage: "photo") }
    }
}

private enum SharedWallpaperTemplate: String, CaseIterable, Identifiable {
    case lock, board, oracle, excerpt
    var id: String { rawValue }
    var title: String {
        switch self { case .lock: "Pico 图片锁屏模板"; case .board: "Pico 画板模板"; case .oracle: "口袋先知模板"; case .excerpt: "摘录模板" }
    }
    var target: PicoPreviewTarget {
        switch self { case .lock, .board: .pico; case .oracle: .oracle; case .excerpt: .excerpt }
    }
}
private struct SharedWallpaperEditRequest: Identifiable {
    let id = UUID()
    let asset: PicoNativeAsset
    let image: NSImage
    let destination: SharedWallpaperTemplate
    let initial: PicoPhotoEdit?
}
private struct SharedWallpaperThumbnail: View {
    let asset: PicoNativeAsset
    let image: NSImage
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 105)
                .controlCenterHostedPanelSurface(in: RoundedRectangle(cornerRadius: 5))
            Text(asset.name).font(.callout).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(asset.width) × \(asset.height)").font(.caption).foregroundStyle(.secondary)
        }.padding(9)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
private struct SharedWallpaperTargetPreview: View {
    let image: NSImage
    let edit: PicoPhotoEdit?
    let target: PicoPreviewTarget
    var body: some View {
        let output = PicoPhotoRenderer.render(image: image, edit: edit ?? .centered(source: PicoPhotoRenderer.sourceSize(image: image), target: target), target: target)
        Image(nsImage: output).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 255)
            .padding(10).controlCenterHostedPanelSurface()
            .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .accessibilityLabel("\(target.title)用途预览")
    }
}
@MainActor private struct SharedWallpaperImportButton: View {
    @ObservedObject var library: PicoNativeLibrary
    var body: some View {
        HStack(spacing: 8) {
            if library.isImporting { ProgressView().controlSize(.small) }
            Button(library.isImporting ? "正在导入…" : "导入图片…", systemImage: "plus") { library.importImages() }
                .disabled(library.isImporting || !library.isWritable)
        }
    }
}
@MainActor private struct SharedWallpaperLibraryError: ViewModifier {
    @ObservedObject var library: PicoNativeLibrary
    func body(content: Content) -> some View {
        content.alert("图片资料库", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("好") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }
}
