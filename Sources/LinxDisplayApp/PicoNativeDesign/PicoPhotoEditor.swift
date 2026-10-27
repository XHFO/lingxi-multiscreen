import AppKit
import SwiftUI

/// Native, local design-preview sheet. Applying returns composition parameters only.
struct PicoPhotoEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let image: NSImage
    private let target: PicoPreviewTarget
    private let drafts: ReadPicoDraftGuard?
    private let initialEdit: PicoPhotoEdit
    private let applicationNote: String?
    private let onApply: ((PicoPhotoEdit) -> Bool)?
    private let asyncApply: ((PicoPhotoEdit) async throws -> Void)?
    private let sourceSize: CGSize
    @State private var edit: PicoPhotoEdit
    @State private var mode: EditingMode = .image
    @State private var preview: NSImage?
    @State private var undoHistory: [PicoPhotoEdit] = []
    @State private var redoHistory: [PicoPhotoEdit] = []
    @State private var panBaseline: PicoPhotoEdit?
    @State private var cropBaseline: PicoPhotoEdit?
    @State private var magnifyBaseline: PicoPhotoEdit?
    @State private var sliderBaseline: PicoPhotoEdit?
    @State private var applyError: String?
    @State private var applying = false
    @StateObject private var departure = PicoPhotoDepartureGate()

    private enum EditingMode: String, CaseIterable, Identifiable {
        case image = "调整图片", crop = "调整裁剪框"
        var id: String { rawValue }
    }
    private enum Handle: String, CaseIterable, Identifiable {
        case nw, n, ne, e, se, s, sw, w
        var id: String { rawValue }
        var title: String {
            switch self { case .nw: return "左上"; case .n: return "上"; case .ne: return "右上"; case .e: return "右"; case .se: return "右下"; case .s: return "下"; case .sw: return "左下"; case .w: return "左" }
        }
        var anchor: UnitPoint {
            switch self { case .nw: return .topLeading; case .n: return .top; case .ne: return .topTrailing; case .e: return .trailing; case .se: return .bottomTrailing; case .s: return .bottom; case .sw: return .bottomLeading; case .w: return .leading }
        }
    }

    init(image: NSImage, target: PicoPreviewTarget, initial: PicoPhotoEdit?, drafts: ReadPicoDraftGuard? = nil, applicationNote: String? = nil, onApply: @escaping (PicoPhotoEdit) -> Bool) {
        self.image = image; self.target = target; self.onApply = onApply; self.asyncApply = nil; self.applicationNote = applicationNote
        self.drafts = drafts
        let source = PicoPhotoRenderer.sourceSize(image: image)
        sourceSize = source
        let value = initial?.normalized() ?? PicoPhotoEdit.centered(source: source, target: target)
        initialEdit = value; _edit = State(initialValue: value)
    }

    init(image: NSImage, target: PicoPreviewTarget, initial: PicoPhotoEdit?, drafts: ReadPicoDraftGuard? = nil, applicationNote: String? = nil,
         apply: @escaping (PicoPhotoEdit) async throws -> Void) {
        self.image = image; self.target = target; self.onApply = nil; self.asyncApply = apply; self.applicationNote = applicationNote
        self.drafts = drafts
        let source = PicoPhotoRenderer.sourceSize(image: image)
        sourceSize = source
        let value = initial?.normalized() ?? PicoPhotoEdit.centered(source: source, target: target)
        initialEdit = value; _edit = State(initialValue: value)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                if geometry.size.width > 830 {
                    HStack(spacing: 0) {
                        workspace
                        Divider()
                        inspector.frame(width: 284)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) { workspace.frame(height: 420); Divider(); inspector }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(applying || (drafts != nil && edit.normalized() != initialEdit))
        .onAppear {
            departure.register(with: drafts, isDirty: { edit.normalized() != initialEdit },
                               isApplying: { applying }, dismiss: { dismiss() })
        }
        .onDisappear { departure.unregister() }
        .alert("离开前应用图片调整？", isPresented: $departure.showPrompt) {
            Button("应用并继续") { departure.resolve(.apply, apply: applyAdjustments) }
            Button("放弃调整并继续", role: .destructive) { departure.resolve(.discard, apply: applyAdjustments) }
            Button("取消", role: .cancel) { departure.resolve(.cancel, apply: applyAdjustments) }
        } message: {
            Text("尚未应用的裁剪、位置与效果会丢失。应用后仍需按原页面的保存操作保留原稿，不会自动发送到设备。")
        }
        .task(id: edit) {
            // Immediate manipulation stays vector/native; coalesce only the raster thumbnail.
            try? await Task.sleep(for: .milliseconds(24))
            guard !Task.isCancelled else { return }
            preview = PicoPhotoRenderer.render(image: image, edit: edit, target: target)
        }
    }

    // SwiftUI sheets can choose the compact minimum despite a wide ideal size.
    // Set the native sheet's initial size explicitly, constrained to the active display.
    private var sheetSize: CGSize {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let available = screen?.visibleFrame.size ?? CGSize(width: 1280, height: 900)
        return CGSize(width: min(1100, max(560, available.width - 64)),
                      height: min(790, max(480, available.height - 80)))
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("调整图片").font(.title2.weight(.semibold))
                Text("\(target.title) · 原图保留，只调整显示方式").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("撤销").accessibilityLabel("撤销上一步调整")
                .keyboardShortcut("z", modifiers: .command).disabled(undoHistory.isEmpty)
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .help("重做").accessibilityLabel("重做调整")
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(redoHistory.isEmpty)
            Button("还原") { change { $0 = PicoPhotoEdit.centered(source: sourceSize, target: target) } }
        }.controlSize(.regular).padding(20)
    }

    private var workspace: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Picker("拖动方式", selection: $mode) {
                    ForEach(EditingMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 270)
                Spacer(minLength: 4)
                Button { change { $0.rotation -= 90; $0 = $0.normalized() } } label: { Label("左转", systemImage: "rotate.left") }
                Button { change { $0.rotation += 90; $0 = $0.normalized() } } label: { Label("右转", systemImage: "rotate.right") }
            }.padding(.horizontal, 16).padding(.top, 14)
            GeometryReader { geometry in
                let available = CGSize(width: max(40, geometry.size.width - 56), height: max(40, geometry.size.height - 56))
                let factor = min(available.width / sourceSize.width, available.height / sourceSize.height)
                let canvas = CGSize(width: sourceSize.width * factor, height: sourceSize.height * factor)
                editingCanvas(size: canvas)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            Text(mode == .image ? "拖动图片 · 双指缩放 · 拖动白色手柄调整裁剪 · 方向键微调" : "拖动裁剪框移动范围 · 拖动边角改变大小 · 双指缩放图片")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 14)
        }
    }

    private func editingCanvas(size: CGSize) -> some View {
        let crop = CGRect(x: edit.cropX * size.width, y: edit.cropY * size.height,
                          width: edit.cropWidth * size.width, height: edit.cropHeight * size.height)
        return ZStack(alignment: .topLeading) {
            ZStack {
                Color.white
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(x: edit.scale * (edit.flipX ? -1 : 1), y: edit.scale * (edit.flipY ? -1 : 1))
                    .rotationEffect(.degrees(edit.totalAngle))
                    .offset(x: edit.panX * size.width, y: edit.panY * size.height)
            }
            .frame(width: size.width, height: size.height).clipped()
            .contentShape(Rectangle())
            .gesture(imageDrag(size: size))

            Path { path in path.addRect(CGRect(origin: .zero, size: size)); path.addRect(crop) }
                .fill(.black.opacity(0.48), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

            cropGrid(size: crop.size)
                .frame(width: crop.width, height: crop.height)
                .contentShape(Rectangle())
                .position(x: crop.midX, y: crop.midY)
                .gesture(cropDrag(size: size))
                .allowsHitTesting(mode == .crop)

            ForEach(Handle.allCases) { handle in
                RoundedRectangle(cornerRadius: 2).fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.6), lineWidth: 1))
                    .frame(width: 10, height: 10).frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .position(x: crop.minX + crop.width * handle.anchor.x, y: crop.minY + crop.height * handle.anchor.y)
                    .gesture(handleDrag(handle, size: size))
                    .accessibilityLabel("\(handle.title)裁剪边界")
                    .accessibilityAdjustableAction { direction in
                        let amount = direction == .increment ? 0.005 : -0.005
                        change { value in value = resized(value, handle: handle, dx: handle.rawValue.contains("w") ? -amount : amount, dy: handle.rawValue.contains("n") ? -amount : amount) }
                    }
            }
        }
        .frame(width: size.width, height: size.height)
        .simultaneousGesture(magnifyGesture())
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in nudge(direction) }
        .accessibilityLabel("图片编辑区域")
        .accessibilityHint("拖动图片或裁剪框，双指缩放，也可以使用方向键微调。")
    }

    private func cropGrid(size: CGSize) -> some View {
        ZStack {
            Path { path in
                for fraction in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: size.width * fraction, y: 0)); path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                    path.move(to: CGPoint(x: 0, y: size.height * fraction)); path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                }
            }.stroke(.white.opacity(0.65), lineWidth: 0.7)
            Rectangle().stroke(.white, lineWidth: 2)
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("裁剪比例").font(.headline)
                    Picker("裁剪比例", selection: Binding(get: { edit.ratio }, set: { ratio in change { $0.fitCrop(ratio, source: sourceSize, target: target) } })) {
                        ForEach(PicoPhotoCropRatio.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                }
                valueSlider("缩放", value: $edit.scale, in: min(0.25, edit.scale)...6, formatted: "\(Int((edit.scale * 100).rounded()))%")
                valueSlider("校正", value: $edit.straighten, in: -45...45, formatted: String(format: "%+.1f°", edit.straighten))
                HStack {
                    Toggle(isOn: Binding(get: { edit.flipX }, set: { new in change { $0.flipX = new } })) { Label("水平翻转", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    Toggle(isOn: Binding(get: { edit.flipY }, set: { new in change { $0.flipY = new } })) { Label("垂直翻转", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                }.toggleStyle(.button).controlSize(.small)
                HStack {
                    Button("居中图片") { change { center(&$0) } }
                    Button("填满裁剪") { change { coverCrop(&$0) } }
                }.frame(maxWidth: .infinity)
                Toggle("铺满目标屏幕", isOn: Binding(get: { edit.fillTarget }, set: { new in change { $0.fillTarget = new } }))
                    .help("关闭时完整显示裁剪范围，按需要保留留白。")
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("目标预览").font(.headline)
                    HStack {
                        Spacer()
                        Group {
                            if let preview { Image(nsImage: preview).resizable().interpolation(.high).aspectRatio(target.size, contentMode: .fit) }
                            else { Color.white.aspectRatio(target.size, contentMode: .fit) }
                        }
                        .frame(maxWidth: 230, maxHeight: 260)
                        .padding(5).background(Color(nsColor: .darkGray)).clipShape(RoundedRectangle(cornerRadius: 10))
                        Spacer()
                    }
                    Text("\(Int(target.size.width)) × \(Int(target.size.height)) · \(target.grayLevels == 16 ? "16 灰阶预览" : "尺寸与布局示意")")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    Text("裁剪 \(Int((edit.cropWidth * sourceSize.width).rounded())) × \(Int((edit.cropHeight * sourceSize.height).rounded()))\n原图 \(Int(sourceSize.width)) × \(Int(sourceSize.height))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                }
            }.padding(20)
        }.background(.background)
    }

    private func valueSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, formatted: String) -> some View {
        VStack(spacing: 8) {
            HStack { Text(title).font(.headline); Spacer(); Text(formatted).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
            Slider(value: value, in: range) { editing in
                if editing { sliderBaseline = edit }
                else if let before = sliderBaseline { record(before); sliderBaseline = nil }
            }.accessibilityLabel(title).accessibilityValue(formatted)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if applying {
                ProgressView("正在保存图片…").controlSize(.small)
            } else if let applyError {
                Label(applyError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
            } else {
                Label(applicationNote ?? "仅在 Mac 本地预览，不会发送或改写原图。", systemImage: "photo.badge.checkmark")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消", role: .cancel) { departure.unregister(); dismiss() }.keyboardShortcut(.cancelAction).disabled(applying)
            Button("应用调整") {
                applyAdjustments { success in
                    if success { departure.unregister(); dismiss() }
                }
            }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(applying)
        }.padding(18)
    }

    private func applyAdjustments(completion: @escaping (Bool) -> Void) {
        guard !applying else { completion(false); return }
        applyError = nil; applying = true
        Task { @MainActor in
            defer { applying = false }
            if let asyncApply {
                do { try await asyncApply(edit.normalized()); completion(true) }
                catch { applyError = error.localizedDescription; completion(false) }
            } else if onApply?(edit.normalized()) == true { completion(true) }
            else {
                applyError = "未能保存，当前调整已保留。请检查资料库后重试。"
                completion(false)
            }
        }
    }

    private func imageDrag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard magnifyBaseline == nil else { return }
                if panBaseline == nil { panBaseline = edit }
                guard let baseline = panBaseline else { return }
                if mode == .crop {
                    edit.cropX = bound(baseline.cropX + value.translation.width / size.width, 0, 1 - edit.cropWidth)
                    edit.cropY = bound(baseline.cropY + value.translation.height / size.height, 0, 1 - edit.cropHeight)
                } else {
                    edit.panX = bound(baseline.panX + value.translation.width / size.width, -2, 2)
                    edit.panY = bound(baseline.panY + value.translation.height / size.height, -2, 2)
                }
            }
            .onEnded { _ in if let before = panBaseline { record(before) }; panBaseline = nil }
    }
    private func cropDrag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1).onChanged { value in
            if cropBaseline == nil { cropBaseline = edit }
            guard let baseline = cropBaseline else { return }
            edit.cropX = bound(baseline.cropX + value.translation.width / size.width, 0, 1 - edit.cropWidth)
            edit.cropY = bound(baseline.cropY + value.translation.height / size.height, 0, 1 - edit.cropHeight)
        }.onEnded { _ in if let before = cropBaseline { record(before) }; cropBaseline = nil }
    }
    private func handleDrag(_ handle: Handle, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            if cropBaseline == nil { cropBaseline = edit }
            guard let baseline = cropBaseline else { return }
            edit = resized(baseline, handle: handle, dx: value.translation.width / size.width, dy: value.translation.height / size.height)
        }.onEnded { _ in if let before = cropBaseline { record(before) }; cropBaseline = nil }
    }
    private func magnifyGesture() -> some Gesture {
        MagnifyGesture().onChanged { value in
            if magnifyBaseline == nil { magnifyBaseline = edit }
            guard let baseline = magnifyBaseline else { return }
            let next = bound(baseline.scale * value.magnification, min(0.25, baseline.scale), 6), ratio = next / baseline.scale
            let x = value.startAnchor.x, y = value.startAnchor.y
            edit.scale = next
            edit.panX = bound(x + (0.5 + baseline.panX - x) * ratio - 0.5, -2, 2)
            edit.panY = bound(y + (0.5 + baseline.panY - y) * ratio - 0.5, -2, 2)
        }.onEnded { _ in
            if let before = magnifyBaseline { record(before) }
            magnifyBaseline = nil; panBaseline = nil
        }
    }

    private func resized(_ value: PicoPhotoEdit, handle: Handle, dx: Double, dy: Double) -> PicoPhotoEdit {
        var output = value
        var left = value.cropX, top = value.cropY, right = left + value.cropWidth, bottom = top + value.cropHeight
        if handle.rawValue.contains("w") { left = bound(left + dx, 0, right - 0.04) }
        if handle.rawValue.contains("e") { right = bound(right + dx, left + 0.04, 1) }
        if handle.rawValue.contains("n") { top = bound(top + dy, 0, bottom - 0.04) }
        if handle.rawValue.contains("s") { bottom = bound(bottom + dy, top + 0.04, 1) }
        var width = right - left, height = bottom - top
        if let ratio = value.ratio.value(source: sourceSize, target: target) {
            let nr = ratio * sourceSize.height / sourceSize.width
            if handle == .n || handle == .s || (handle.rawValue.count == 2 && abs(dy) / value.cropHeight > abs(dx) / value.cropWidth) { width = height * nr }
            else { height = width / nr }
            let factor = min(1, min(1 / width, 1 / height)); width *= factor; height *= factor
            let minimumFactor = max(1, max(0.04 / width, 0.04 / height)); width *= minimumFactor; height *= minimumFactor
            left = handle.rawValue.contains("w") ? value.cropX + value.cropWidth - width : handle.rawValue.contains("e") ? value.cropX : value.cropX + (value.cropWidth - width) / 2
            top = handle.rawValue.contains("n") ? value.cropY + value.cropHeight - height : handle.rawValue.contains("s") ? value.cropY : value.cropY + (value.cropHeight - height) / 2
        }
        output.cropWidth = width; output.cropHeight = height
        output.cropX = bound(left, 0, 1 - width); output.cropY = bound(top, 0, 1 - height)
        return output.normalized()
    }

    private func center(_ value: inout PicoPhotoEdit) { value.panX = value.cropX + value.cropWidth / 2 - 0.5; value.panY = value.cropY + value.cropHeight / 2 - 0.5 }
    private func coverCrop(_ value: inout PicoPhotoEdit) {
        let angle = value.totalAngle * .pi / 180, cw = value.cropWidth * sourceSize.width, ch = value.cropHeight * sourceSize.height
        value.scale = bound(max((abs(cos(angle)) * cw + abs(sin(angle)) * ch) / sourceSize.width, (abs(sin(angle)) * cw + abs(cos(angle)) * ch) / sourceSize.height), 0.25, 6)
        center(&value)
    }
    private func nudge(_ direction: MoveCommandDirection) {
        let dx: Double = direction == .left ? -1 / sourceSize.width : direction == .right ? 1 / sourceSize.width : 0
        let dy: Double = direction == .up ? -1 / sourceSize.height : direction == .down ? 1 / sourceSize.height : 0
        change { value in
            if mode == .crop { value.cropX = bound(value.cropX + dx, 0, 1 - value.cropWidth); value.cropY = bound(value.cropY + dy, 0, 1 - value.cropHeight) }
            else { value.panX = bound(value.panX + dx, -2, 2); value.panY = bound(value.panY + dy, -2, 2) }
        }
    }
    private func bound(_ value: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, value)) }
    private func change(_ mutation: (inout PicoPhotoEdit) -> Void) { let before = edit; mutation(&edit); record(before) }
    private func record(_ before: PicoPhotoEdit) { guard before != edit else { return }; undoHistory.append(before); if undoHistory.count > 60 { undoHistory.removeFirst() }; redoHistory.removeAll() }
    private func undo() { guard let previous = undoHistory.popLast() else { return }; redoHistory.append(edit); edit = previous }
    private func redo() { guard let next = redoHistory.popLast() else { return }; undoHistory.append(edit); edit = next }
}

/// A child owns only its departure registration. Another sheet may replace it without
/// being cleared by this editor's delayed onDisappear. Cancellation always releases the parent gate.
@MainActor final class PicoPhotoDepartureGate: ObservableObject {
    enum Decision { case apply, discard, cancel }
    @Published var showPrompt = false
    private let owner = UUID()
    private weak var drafts: ReadPicoDraftGuard?
    private var continuation: (() -> Void)?
    private var dismiss: (() -> Void)?
    private var isDirty: (() -> Bool)?
    private var isApplying: (() -> Bool)?

    func register(with drafts: ReadPicoDraftGuard?, isDirty: @escaping () -> Bool,
                  isApplying: @escaping () -> Bool, dismiss: @escaping () -> Void) {
        guard let drafts else { return }
        guard drafts.registerChildDeparture(owner: owner, handler: { [weak self, weak drafts] action in
            guard let self else { drafts?.cancelChildDeparture(); return }
            self.request(action)
        }) else { return }
        self.drafts = drafts; self.isDirty = isDirty; self.isApplying = isApplying; self.dismiss = dismiss
    }
    private func request(_ action: @escaping () -> Void) {
        guard isApplying?() != true else { drafts?.cancelChildDeparture(); return }
        continuation = action
        if isDirty?() == true { showPrompt = true }
        else { finish() }
    }
    func resolve(_ decision: Decision, apply: (@escaping (Bool) -> Void) -> Void) {
        guard continuation != nil else { return }
        showPrompt = false
        switch decision {
        case .cancel: cancel()
        case .discard: finish()
        case .apply:
            apply { [weak self] success in
                guard let self else { return }
                if success { self.finish() } else { self.cancel() }
            }
        }
    }
    private func cancel() {
        continuation = nil; showPrompt = false; drafts?.cancelChildDeparture()
    }
    private func finish() {
        let action = continuation, close = dismiss
        continuation = nil
        unregister()
        close?(); action?()
    }
    func unregister() {
        if continuation != nil { cancel() }
        drafts?.clearChildDeparture(owner: owner)
        drafts = nil; dismiss = nil; isDirty = nil; isApplying = nil; showPrompt = false
    }
}
