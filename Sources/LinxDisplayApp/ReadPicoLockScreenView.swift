import AppKit
import ImageIO
import LinxDisplayCore
import SwiftUI
import UniformTypeIdentifiers

struct ReadPicoLockScreenView: View {
    @Environment(\.controlCenterHasExternalPreview) private var hasExternalPreview
    @ObservedObject private var drafts: ReadPicoDraftGuard
    @ObservedObject private var model: ReadPicoManagerModel
    @ObservedObject private var editor: ReadPicoLockScreenDraft
    @ObservedObject private var library = PicoNativeLibrary.shared
    private let deviceID: UUID?
    @State private var dragOrigin: CGSize?
    @State private var showWallpaperPicker = false
    @State private var showDeviceFeedback = false
    @State private var compositionRequest: CompositionRequest?
    @State private var saveRequest: SaveRequest?
    private struct CompositionRequest: Identifiable {
        let id = UUID()
        let image: NSImage
        let initial: PicoPhotoEdit
    }
    private struct SaveRequest {
        enum Phase { case image, style }
        let connection: ReadPicoConnection
        let image: Data?
        let imageRevision: UInt32?
        let options: ReadPicoLockScreenOptions
        let sourceName: String
        let configuration: ReadPicoDeviceConfiguration
        let baseline: ReadPicoDeviceConfiguration
        let saveStyle: Bool
        var phase: Phase
    }
    init(drafts: ReadPicoDraftGuard, deviceID: UUID? = nil) {
        self.drafts = drafts; self.model = drafts.model; self.editor = drafts.lockScreen; self.deviceID = deviceID
    }
    private var target: PicoPreviewTarget { editor.options.landscape ? .picoLandscape : .pico }
    private var libraryKey: String { deviceID.map { "device.\($0.uuidString).lock" } ?? "lock" }
    private var photoEdit: PicoPhotoEdit? { editor.options.photoEditData.flatMap { try? JSONDecoder().decode(PicoPhotoEdit.self, from: $0) } }
    /// Indices match device lockStyle; labels 0–4 use Pico I18N keys, index 5 stays Mac-only (charging clarification).
    private var styles: [String] {
        [
            L10n.t(PicoKeys.Power.styleClock),
            L10n.t(PicoKeys.Power.styleQuotes),
            L10n.t(PicoKeys.Power.styleCovers),
            L10n.t(PicoKeys.Power.stylePage),
            L10n.t(PicoKeys.Power.styleImage),
            L10n.t("充电时显示灵犀画板"),
        ]
    }
    private let coverLayouts = ["全屏单封面", "双封面", "书库拼贴", "留白海报", "全屏书墙"]
    private var bitmap: Data? { editor.hasImage ? editor.bitmap : model.pendingLockImage ?? model.lockImagePreview }
    private var supportsStyle: Bool { model.deviceSettingsSupported && model.deviceConfiguration.lockStyle != nil && model.imageLock?.supported == true }
    private var hasStyleChanges: Bool {
        guard let baseline = model.confirmedDeviceConfig else { return false }
        return model.deviceConfiguration.lockStyle != baseline.lockStyle || model.deviceConfiguration.coverLayout != baseline.coverLayout
    }
    private var editingDisabled: Bool { model.busy || saveRequest != nil || !editor.hasImage }
    private var canSaveToDevice: Bool {
        supportsStyle && model.connection != nil && model.confirmedDeviceConfig != nil &&
        !model.busy && saveRequest == nil && !editor.rendering && editor.error == nil &&
        (model.pendingLockImage != nil || hasStyleChanges) &&
        (model.pendingLockImage == nil || editor.outputBitDepth != 4 || model.imageLock?.supportsNativeGray16 == true)
    }
    private var previewDepth: Int {
        if let bitmap, bitmap.count > 29 { return Int(bitmap[28]) | Int(bitmap[29]) << 8 }
        return editor.outputBitDepth
    }
    private var previewSize: CGSize {
        if !editor.hasImage, let bitmap, let image = NSImage(data: bitmap), image.size.width > 0, image.size.height > 0 { return image.size }
        return CGSize(width: editor.options.width, height: editor.options.height)
    }
    /// Keep the position-adjustment canvas available while an original is being edited.
    private var needsLocalCanvas: Bool { editor.hasImage && photoEdit == nil }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header.padding(.horizontal, 20).padding(.vertical, 14)
                Divider()
                if hasExternalPreview && !needsLocalCanvas {
                    Form { settingsSections }.formStyle(.grouped)
                    .controlCenterHostedFormSurface()
                } else if geometry.size.width >= 820 {
                    HStack(alignment: .top, spacing: 0) {
                        Form { settingsSections }
                            .formStyle(.grouped)
                            .controlCenterHostedFormSurface()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        Divider().padding(.vertical, 4)
                        Form { previewSection }
                            .formStyle(.grouped)
                            .controlCenterHostedFormSurface()
                            .frame(width: min(440, max(340, geometry.size.width * 0.43)))
                    }
                } else {
                    Form {
                        settingsSections
                        previewSection
                    }.formStyle(.grouped)
                    .controlCenterHostedFormSurface()
                }
            }
        }
        .onAppear {
            editor.configureOutputCapability(model.imageLock?.supportsNativeGray16)
            editor.configureRenderer { try ReadPicoLockScreenRenderer.render($0, options: $1) }
            restorePreparedImage()
        }
        .task(id: deviceID) {
            // Image decoding is asynchronous; restore only into an empty device draft.
            for _ in 0..<30 {
                guard !editor.hasImage, !Task.isCancelled, let use = library.use(for: libraryKey),
                      let asset = library.assets.first(where: { $0.id == use.assetID }) else { return }
                if let image = library.image(for: asset) { selectWallpaper(asset, image: image, restoring: use); return }
                if library.imageLoadFailed(for: asset) { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .sheet(isPresented: $showWallpaperPicker) {
            SharedWallpaperPicker(title: "选择锁屏图片") { asset, image in
                selectWallpaper(asset, image: image)
                showWallpaperPicker = false
            }
        }
        .sheet(item: $compositionRequest) { request in
            PicoPhotoEditor(image: request.image, target: target, initial: request.initial, drafts: drafts,
                            applicationNote: "应用到当前锁屏草稿；点击“保存到设备”后同步。") { edit in
                applyComposition(edit)
            }
        }
        .onChange(of: model.imageLock?.supportsNativeGray16) { _, value in editor.configureOutputCapability(value) }
        .onChange(of: model.busy) { wasBusy, isBusy in
            if wasBusy && !isBusy { finishSaveStep() }
        }
        .onChange(of: model.cancelling) { _, cancelling in
            if cancelling { saveRequest = nil }
        }
        .onChange(of: model.connection) { _, connection in
            saveRequest = nil
            if connection != nil { restorePreparedImage() }
        }
        .onDisappear { saveRequest = nil }
    }
    private func restorePreparedImage() {
        guard !editor.rendering, editor.error == nil,
              let bitmap = editor.bitmap,
              bitmap != model.lockImagePreview,
              model.pendingLockImage == nil else { return }
        model.pendingLockImage = bitmap
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text("图片锁屏").font(.title2.weight(.semibold))
                    Spacer(minLength: 16)
                    moreMenu
                    saveButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("图片锁屏").font(.title2.weight(.semibold))
                        Spacer(minLength: 8)
                        moreMenu
                    }
                    saveButton
                }
            }
            feedback
        }
    }
    private var saveButton: some View {
        Button("保存到设备", systemImage: "arrow.up.doc") { saveToDevice() }
            .buttonStyle(.borderedProminent)
            .disabled(!canSaveToDevice)
    }
    private var moreMenu: some View {
        Menu("更多", systemImage: "ellipsis.circle") {
            Button("打开原稿…", systemImage: "folder") {
                drafts.request(.device, title: "打开另一份原稿前保存修改？") { openDraft() }
            }
            Button("另存原稿…", systemImage: "square.and.arrow.down") { saveDraft() }
                .disabled(!editor.hasImage)
            Button("导出锁屏图片…", systemImage: "photo.badge.arrow.down") { exportBitmap() }
                .disabled(bitmap == nil || editor.rendering)
            Divider()
            if let root = model.store?.rootURL {
                Button("从 TF 卡选择图片…", systemImage: "sdcard") {
                    drafts.request(.device, title: "选择 TF 图片前保存修改？") { chooseImage(initialDirectory: root) }
                }
            }
            Button("读取设备图片", systemImage: "arrow.down.doc") {
                drafts.request(.device, title: "读取设备图片前保存修改？") {
                    editor.clear(); showDeviceFeedback = true; model.readLockImage()
                }
            }.disabled(model.imageLock?.available != true)
        }
        .fixedSize()
        .disabled(model.busy || saveRequest != nil || editor.rendering)
    }
    @ViewBuilder private var feedback: some View {
        if editor.rendering {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在生成预览…")
            }.font(.callout).foregroundStyle(.secondary)
        } else if let error = editor.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
        if model.busy || model.isError || showDeviceFeedback {
            HStack(alignment: .top, spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.message).foregroundStyle(model.isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if model.canCancel {
                    Button(model.cancelTitle) { saveRequest = nil; model.cancelOperation() }
                }
            }.font(.callout)
        }
        if !model.busy && model.connection == nil {
            Text("可先编辑图片，连接阅读器后保存。")
                .font(.callout).foregroundStyle(.secondary)
        } else if !model.busy && !supportsStyle {
            Label("当前固件尚未支持图片锁屏，请在“固件与备份”更新。", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if !model.busy && model.pendingLockImage != nil && editor.outputBitDepth == 4 && model.imageLock?.supportsNativeGray16 != true {
            Label("当前固件支持黑白图片，请选择“自动匹配设备”或“黑白”。", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private var settingsSections: some View {
        Section("锁屏样式") {
            Picker("样式", selection: Binding(get: { model.deviceConfiguration.lockStyle ?? 0 }, set: { model.deviceConfiguration.lockStyle = $0 })) {
                ForEach(0..<styles.count, id: \.self) { style in
                    Text(styles[style]).tag(style)
                        .disabled(style == 4 && model.imageLock?.available != true && model.pendingLockImage == nil)
                }
            }.disabled(!supportsStyle || model.busy || saveRequest != nil)
            if model.deviceConfiguration.lockStyle == 2 {
                if model.deviceConfiguration.coverLayout != nil {
                    Picker("封面排布", selection: Binding(get: { model.deviceConfiguration.coverLayout ?? 0 }, set: { model.deviceConfiguration.coverLayout = $0 })) {
                        ForEach(0..<coverLayouts.count, id: \.self) { layout in Text(coverLayouts[layout]).tag(layout) }
                    }.disabled(model.busy || saveRequest != nil)
                    Text("优先显示最近阅读的真实图书封面；海报留白，书墙填满屏幕。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("更新固件后可在这里选择封面排布。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        Section("图片来源") {
            LabeledContent("当前图片") {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(editor.hasImage ? editor.name : model.lockImagePreview != nil ? "设备中的锁屏图片" : "未选择图片")
                        .lineLimit(2).help(editor.name)
                    if editor.hasUnsavedChanges {
                        Text("原稿未保存").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { sourceButtons }
                VStack(alignment: .leading, spacing: 10) { sourceButtons }
            }.disabled(model.busy || saveRequest != nil || editor.rendering)
        }
        Section("图片效果") {
            Picker("像素模式", selection: option(\.output)) {
                ForEach(ReadPicoLockScreenOptions.Output.allCases) { output in
                    Text(output.title).tag(output).disabled(output == .gray16 && editor.supportsNativeGray16 == false)
                }
            }
            Picker("显示方向", selection: option(\.landscape)) {
                Text("竖屏").tag(false); Text("横屏").tag(true)
            }
            Picker("内容效果", selection: option(\.mode)) {
                ForEach(ReadPicoLockScreenOptions.Mode.allCases) { Text($0.title).tag($0) }
            }
            Picker("灰度转换", selection: option(\.gray)) {
                ForEach(ReadPicoLockScreenOptions.Gray.allCases) { Text($0.title).tag($0) }
            }
            if editor.options.mode == .image && editor.outputBitDepth == 1 {
                Picker("黑白算法", selection: option(\.dither)) {
                    ForEach(ReadPicoLockScreenOptions.Dither.allCases) { Text($0.title).tag($0) }
                }
            } else if editor.options.mode == .ascii {
                LabeledContent("字符大小") {
                    HStack {
                        Slider(value: Binding(get: { Double(editor.options.asciiCellSize) }, set: { value in
                            var next = editor.options; next.asciiCellSize = Int(value); editor.updateOptions(next)
                        }), in: 8...32, step: 2).accessibilityLabel("ASCII 字符大小")
                        Text("\(editor.options.asciiCellSize) px").monospacedDigit().frame(width: 46, alignment: .trailing)
                    }
                }
            }
        }.disabled(editingDisabled)
        Section("图片构图") {
            Button("调整裁剪、旋转与翻转…", systemImage: "crop.rotate") { openComposition() }
            if photoEdit == nil {
                Picker("图片排布", selection: Binding(get: { editor.options.layout }, set: { editor.setLayout($0) })) {
                    ForEach(ReadPicoLockScreenOptions.Layout.allCases) { Text($0.title).tag($0) }
                }
                adjustment("缩放", value: option(\.zoom), range: 0.25...4, label: "\(Int((editor.options.zoom * 100).rounded()))%")
                adjustment("水平", value: option(\.offsetX), range: -1...1, label: "\(Int((editor.options.offsetX * 100).rounded()))%")
                adjustment("垂直", value: option(\.offsetY), range: -1...1, label: "\(Int((editor.options.offsetY * 100).rounded()))%")
                Button("居中复位", systemImage: "arrow.counterclockwise") { editor.center() }
            }
        }.disabled(editingDisabled)
    }
    @ViewBuilder private var sourceButtons: some View {
        Button("从壁纸库选择…", systemImage: "photo.on.rectangle.angled") {
            drafts.request(.device, title: "选择另一张壁纸前保存修改？") { showWallpaperPicker = true }
        }
        Button("选择图片…", systemImage: "photo") {
            drafts.request(.device, title: "选择另一张图片前保存修改？") { chooseImage() }
        }
    }
    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range).accessibilityLabel(title)
                Text(label).font(.callout.monospacedDigit()).frame(width: 50, alignment: .trailing)
            }
        }
    }
    private func option<Value>(_ keyPath: WritableKeyPath<ReadPicoLockScreenOptions, Value>) -> Binding<Value> {
        Binding(get: { editor.options[keyPath: keyPath] }, set: { value in
            var next = editor.options; next[keyPath: keyPath] = value; editor.updateOptions(next)
        })
    }
    private var previewSection: some View {
        Section("锁屏预览") {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geometry in
                    ZStack {
                        Color.white
                        if let bitmap, let image = NSImage(data: bitmap) {
                            Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                                .accessibilityLabel("实际保存到阅读器的锁屏图片")
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "photo.on.rectangle").font(.system(size: 36))
                                Text(model.imageLock?.available == true ? "从“更多”读取设备图片" : "选择图片以预览锁屏")
                                    .multilineTextAlignment(.center)
                            }.foregroundStyle(Color.gray).padding()
                        }
                    }.contentShape(Rectangle()).clipped()
                        .gesture(DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                guard editor.hasImage, !model.busy, saveRequest == nil, editor.options.photoEditData == nil else { return }
                                if dragOrigin == nil { dragOrigin = CGSize(width: editor.options.offsetX, height: editor.options.offsetY) }
                                guard let origin = dragOrigin else { return }
                                var next = editor.options
                                next.offsetX = min(1, max(-1, origin.width + value.translation.width / max(1, geometry.size.width)))
                                next.offsetY = min(1, max(-1, origin.height + value.translation.height / max(1, geometry.size.height)))
                                editor.updateOptions(next)
                            }.onEnded { _ in dragOrigin = nil })
                }
                .aspectRatio(previewSize.width / previewSize.height, contentMode: .fit)
                .frame(maxWidth: previewSize.width > previewSize.height ? 660 : 350)
                .overlay(Rectangle().stroke(Color.secondary.opacity(0.3)))
                .frame(maxWidth: .infinity, alignment: .center)
                HStack {
                    Text("\(Int(previewSize.width)) × \(Int(previewSize.height))")
                    Spacer()
                    Text(previewDepth == 4 ? "原生 16 灰阶" : "黑白")
                }.font(.callout).foregroundStyle(.secondary)
                if editor.hasImage && photoEdit == nil {
                    Text("拖动预览可调整图片位置。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func saveToDevice() {
        guard canSaveToDevice, let connection = model.connection, let baseline = model.confirmedDeviceConfig else { return }
        let image = model.pendingLockImage
        let request = SaveRequest(connection: connection, image: image, imageRevision: model.imageLock?.revision,
                                  options: editor.options, sourceName: editor.name,
                                  configuration: model.deviceConfiguration, baseline: baseline,
                                  saveStyle: hasStyleChanges, phase: image == nil ? .style : .image)
        showDeviceFeedback = true
        if let image {
            saveRequest = request
            model.uploadLockImage(image)
            if !model.busy { saveRequest = nil }
        } else { saveStyle(request) }
    }
    private func saveStyle(_ request: SaveRequest) {
        guard request.saveStyle, model.connection == request.connection,
              model.deviceConfiguration == request.configuration,
              model.confirmedDeviceConfig == request.baseline, !model.busy else {
            saveRequest = nil
            return
        }
        var next = request; next.phase = .style; saveRequest = next
        // This page owns lock style/cover layout. The model captures its argument synchronously;
        // retain unrelated power drafts instead of committing them as part of an image edit.
        var submitted = request.baseline
        submitted.lockStyle = request.configuration.lockStyle
        submitted.coverLayout = request.configuration.coverLayout
        model.deviceConfiguration = submitted
        model.saveDeviceSettings()
        model.deviceConfiguration = request.configuration
        if !model.busy { saveRequest = nil }
    }
    private func finishSaveStep() {
        guard let request = saveRequest else { return }
        saveRequest = nil
        guard !model.isError, model.connection == request.connection else { return }
        switch request.phase {
        case .image:
            guard let image = request.image, model.pendingLockImage == nil,
                  model.lockImagePreview == image, model.imageLock?.revision != request.imageRevision,
                  !editor.rendering, editor.options == request.options, editor.name == request.sourceName,
                  !editor.hasImage || editor.bitmap == image else { return }
            if request.saveStyle {
                saveStyle(request)
            } else { model.report("锁屏图片已保存到设备。") }
        case .style:
            if model.confirmedDeviceConfig?.lockStyle == request.configuration.lockStyle,
               model.confirmedDeviceConfig?.coverLayout == request.configuration.coverLayout {
                model.report(request.image == nil ? "锁屏样式已保存，下次锁屏时生效。" : "锁屏图片与样式已保存，下次锁屏时生效。")
            }
        }
    }
    private func exportBitmap() {
        guard let bitmap, !editor.rendering else { return }
        let panel = NSSavePanel(); panel.title = "导出锁屏图片"; panel.nameFieldStringValue = "图片锁屏.bmp"
        panel.allowedContentTypes = [.bmp]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try bitmap.write(to: url, options: .atomic) }
        catch { model.report(error.localizedDescription, error: true) }
    }
    private func openComposition() {
        guard let source = editor.source else { return }
        let image = NSImage(cgImage: source, size: CGSize(width: source.width, height: source.height))
        compositionRequest = CompositionRequest(image: image, initial: photoEdit ?? ReadPicoLockScreenRenderer.legacyComposition(source: CGSize(width: source.width, height: source.height), options: editor.options))
    }
    private func applyComposition(_ edit: PicoPhotoEdit) -> Bool {
        do {
            let data = try JSONEncoder().encode(edit.normalized())
            guard data.count <= 16 * 1024 else { return false }
            // The embedded source and parameters belong to this draft, including portable originals.
            // Applying an edit never writes a global use; save the .picolock or send explicitly afterwards.
            // 内嵌原稿为草稿自身所有；应用构图不提前写共享用途，跨 Mac 打开也能继续编辑。
            var next = editor.options
            next.photoEditData = data
            editor.updateOptions(next)
            return true
        } catch { model.report(error.localizedDescription, error: true); return false }
    }
    private func selectWallpaper(_ asset: PicoNativeAsset, image: NSImage, restoring use: PicoNativeImageUse? = nil) {
        do {
            guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ReadPicoManagerError.invalid("壁纸原图暂时无法读取。")
            }
            // The library owns the unchanged original. Keep the existing draft's bounded
            // working-image budget; composition remains normalized to this image plane.
            let factor = min(1, 2048 / Double(max(source.width, source.height)))
            let width = max(1, Int((Double(source.width) * factor).rounded()))
            let height = max(1, Int((Double(source.height) * factor).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ReadPicoManagerError.unavailable("无法准备锁屏工作图片。")
            }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let working = context.makeImage() else { throw ReadPicoManagerError.unavailable("无法准备锁屏工作图片。") }
            try editor.setImage(working, name: asset.name)
            var next = editor.options
            next.wallpaperAssetID = asset.id
            let storedUse = use ?? library.use(for: libraryKey).flatMap { $0.assetID == asset.id ? $0 : nil }
            if let use = storedUse {
                next.landscape = use.target == .picoLandscape
                next.photoEditData = try JSONEncoder().encode(use.edit.normalized())
            }
            editor.updateOptions(next)
        } catch { model.report(error.localizedDescription, error: true) }
    }
    private func chooseImage(initialDirectory: URL? = nil) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.directoryURL = initialDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 32 * 1024 * 1024,
                  let input = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else {
                throw ReadPicoManagerError.invalid("请选择可读取的图片，文件不超过 32 MB。")
            }
            try editor.setImage(image, name: url.lastPathComponent)
        } catch { model.report(error.localizedDescription, error: true) }
    }
    private func saveDraft() {
        let panel = NSSavePanel(); panel.title = "保存图片锁屏原稿"; panel.nameFieldStringValue = "图片锁屏.picolock"
        panel.allowedContentTypes = [UTType(filenameExtension: "picolock") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try editor.save(to: url) } catch { model.report(error.localizedDescription, error: true) }
    }
    private func openDraft() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "picolock") ?? .json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 48 * 1024 * 1024 else { throw ReadPicoManagerError.invalid("图片锁屏原稿不能超过 48 MB。") }
            try editor.load(data: Data(contentsOf: url, options: .mappedIfSafe))
        } catch { model.report(error.localizedDescription, error: true) }
    }
}
