import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Keep departure decisions separate from connection edits, so typing a new address
/// cannot silently discard a configuration or submit it to a different reader.
@MainActor final class ReadPicoDraftGuard: ObservableObject {
    enum Scope { case device, canvas, all }
    enum Decision { case save, discard, cancel }
    let model: ReadPicoManagerModel
    let canvas: ReadPicoCanvasDraft
    let boardLibrary: ReadPicoBoardLibrary?
    let lockScreen: ReadPicoLockScreenDraft
    @Published var showPrompt = false
    @Published var externalBusy = false
    /// Waiting connection dialogs and child UI may move only after they finish;
    /// they must still be allowed to initiate their own connection operation.
    @Published var presentationBusy = false
    @Published var childDeparture: ((@escaping () -> Void) -> Void)? {
        didSet { childDepartureOwner = nil }
    }
    private var childDepartureOwner: UUID?
    @Published private(set) var isHandlingDeparture = false
    private struct Departure {
        let scope: Scope
        let title: String
        let action: () -> Void
    }
    private var pending: Departure?
    private var observations = Set<AnyCancellable>()
    private let saveCanvas: (ReadPicoCanvasDraft) throws -> Bool
    private let saveLockScreen: (ReadPicoLockScreenDraft) throws -> Bool
    private let id = UUID()
    private final class WeakGuard {
        weak var value: ReadPicoDraftGuard?
        init(_ value: ReadPicoDraftGuard) { self.value = value }
    }
    private static var active: [UUID: WeakGuard] = [:]

    init(model: ReadPicoManagerModel? = nil, canvas: ReadPicoCanvasDraft? = nil,
         boardLibrary: ReadPicoBoardLibrary? = nil,
         lockScreen: ReadPicoLockScreenDraft? = nil,
         saveLockScreen: ((ReadPicoLockScreenDraft) throws -> Bool)? = nil,
         saveCanvas: ((ReadPicoCanvasDraft) throws -> Bool)? = nil) {
        self.model = model ?? ReadPicoManagerModel()
        self.canvas = canvas ?? ReadPicoCanvasDraft()
        self.boardLibrary = boardLibrary
        self.lockScreen = lockScreen ?? ReadPicoLockScreenDraft()
        self.saveCanvas = saveCanvas ?? { draft in
            if let boardLibrary {
                if boardLibrary.selectedID == nil {
                    try boardLibrary.create(name: draft.board.name, from: draft, into: draft)
                } else { try boardLibrary.saveCurrent(draft) }
                return true
            }
            let panel = NSSavePanel()
            panel.title = "保存本地灵犀画板草稿"
            panel.nameFieldStringValue = "灵犀画板草稿.picocanvas"
            panel.allowedContentTypes = [UTType(filenameExtension: "picocanvas") ?? .json]
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            try draft.save(to: url)
            return true
        }
        self.saveLockScreen = saveLockScreen ?? { draft in
            let panel = NSSavePanel()
            panel.title = "保存图片锁屏原稿"
            panel.nameFieldStringValue = "图片锁屏.picolock"
            panel.allowedContentTypes = [UTType(filenameExtension: "picolock") ?? .json]
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            try draft.save(to: url)
            return true
        }
        let pairedModel = self.model
        self.lockScreen.onRendered = { [weak pairedModel] bitmap in pairedModel?.pendingLockImage = bitmap }
        self.lockScreen.onInvalidated = { [weak pairedModel] in pairedModel?.pendingLockImage = nil }
        self.model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        self.canvas.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        self.lockScreen.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }
    var departureTitle: String { pending?.title ?? "离开设备管理" }

    /// A sheet may release only its own handler; older sheets cannot clear a newer editor.
    @discardableResult
    func registerChildDeparture(owner: UUID, handler: @escaping (@escaping () -> Void) -> Void) -> Bool {
        guard childDeparture == nil || childDepartureOwner == owner else { return false }
        childDeparture = handler
        childDepartureOwner = owner
        return true
    }
    func clearChildDeparture(owner: UUID) {
        guard childDepartureOwner == owner else { return }
        childDeparture = nil
    }

    var departureMessage: String {
        var parts: [String] = []
        if let scope = pending?.scope {
            if scope != .canvas && model.hasUnsavedDeviceConfigurationChanges {
                parts.append("修改的设备设置会保存到当前连接的阅读器。")
            }
            if scope != .device && canvas.hasUnsavedLocalChanges {
                parts.append("模块、图片和手绘会保存到这台设备的 Mac 画板库，不会自动推送。")
            }
            if scope != .canvas && lockScreen.hasUnsavedChanges {
                parts.append("锁屏原图、图片位置和效果会保存为 Mac 本地图片锁屏原稿。")
            }
        }
        parts.append("保存失败或取消保存时会留在当前页面。")
        return parts.joined(separator: "\n")
    }
    func hasChanges(_ scope: Scope) -> Bool {
        (scope != .canvas && (model.hasUnsavedDeviceConfigurationChanges || lockScreen.hasUnsavedChanges)) ||
            (scope != .device && canvas.hasUnsavedLocalChanges)
    }
    var blocksDismissal: Bool { model.busy || externalBusy || lockScreen.rendering || hasChanges(.all) || childDeparture != nil }
    func activate() { Self.active[id] = WeakGuard(self) }
    func deactivate() {
        Self.active[id] = nil
        pending = nil; showPrompt = false; isHandlingDeparture = false; presentationBusy = false
        model.deactivate()
    }
    func request(_ scope: Scope = .all, title: String, action: @escaping () -> Void) {
        guard !model.busy, !externalBusy, !lockScreen.rendering, !isHandlingDeparture else {
            model.report("请先完成或取消当前设备操作，再离开页面。", error: true)
            return
        }
        isHandlingDeparture = true
        let departure = Departure(scope: scope, title: title, action: action)
        if scope == .all, let childDeparture {
            // The child owns any form-specific save action. Only continue once it
            // has explicitly completed or discarded its own work.
            childDeparture { [weak self] in self?.prepare(departure) }
        } else { prepare(departure) }
    }
    /// A child cancel must also release the pending global departure.
    func cancelChildDeparture() { if pending == nil { isHandlingDeparture = false } }
    private func prepare(_ departure: Departure) {
        if hasChanges(departure.scope) { pending = departure; showPrompt = true }
        else { isHandlingDeparture = false; departure.action() }
    }
    func resolve(_ decision: Decision) {
        guard let departure = pending, !model.busy else { return }
        showPrompt = false
        switch decision {
        case .cancel:
            pending = nil; isHandlingDeparture = false
        case .discard:
            if departure.scope != .canvas, !model.discardPendingDeviceChanges() { return }
            if departure.scope != .canvas { lockScreen.discardChanges() }
            if departure.scope != .device { canvas.discardChanges() }
            pending = nil; isHandlingDeparture = false
            departure.action()
        case .save:
            do {
                if departure.scope != .device && canvas.hasUnsavedLocalChanges {
                    guard try saveCanvas(canvas) else {
                        pending = nil; isHandlingDeparture = false
                        return
                    }
                }
                if departure.scope != .canvas && lockScreen.hasUnsavedChanges {
                    guard try saveLockScreen(lockScreen) else {
                        pending = nil; isHandlingDeparture = false
                        return
                    }
                }
            } catch {
                pending = nil; isHandlingDeparture = false
                model.report("本地原稿尚未保存，已保留当前内容。" + error.localizedDescription, error: true)
                return
            }
            if departure.scope != .canvas && model.hasUnsavedDeviceConfigurationChanges {
                model.savePendingDeviceChanges(includeLockImage: false) { [weak self] success in
                    guard let self else { return }
                    self.finishSave(departure, success: success)
                }
            } else { finishSave(departure, success: true) }
        }
    }
    private func finishSave(_ departure: Departure, success: Bool) {
        pending = nil; isHandlingDeparture = false
        guard success, !hasChanges(departure.scope) else { return }
        departure.action()
    }
    /// Return false while a registered workbench resolves its own drafts. The
    /// existing application termination pipeline runs again after resolution.
    static func prepareForApplicationTermination() -> Bool {
        active = active.filter { $0.value.value != nil }
        guard let draft = active.values.compactMap(\.value).first(where: { $0.blocksDismissal || $0.isHandlingDeparture }) else { return true }
        if draft.model.busy || draft.externalBusy || draft.lockScreen.rendering {
            let alert = NSAlert()
            alert.messageText = "正在完成小纸 Pico 设备操作"
            alert.informativeText = "请等待操作完成，或在设备管理中取消等待后再退出。未保存内容会保留。"
            alert.addButton(withTitle: "继续等待")
            alert.runModal()
        } else if !draft.isHandlingDeparture {
            draft.request(title: "退出多屏灵犀前保存修改？") { NSApp.terminate(nil) }
        }
        return false
    }
}

struct ReadPicoDraftProtection: ViewModifier {
    @ObservedObject var drafts: ReadPicoDraftGuard
    var enabled = true
    /// Managed readers are owned by the stable device navigation host. Their
    /// editor may move between a floating shell and the inline detail column.
    var managesLifecycle = true
    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(enabled && drafts.blocksDismissal)
            .alert(drafts.departureTitle, isPresented: Binding(get: { enabled && drafts.showPrompt }, set: { if enabled { drafts.showPrompt = $0 } })) {
                Button("保存并离开") { drafts.resolve(.save) }
                Button("放弃修改并离开", role: .destructive) { drafts.resolve(.discard) }
                Button("取消", role: .cancel) { drafts.resolve(.cancel) }
            } message: { Text(drafts.departureMessage) }
            .background { if enabled { ReadPicoWindowCloseGuard(drafts: drafts) } }
            .onAppear { if enabled && managesLifecycle { drafts.activate() } }
            .onDisappear { if enabled && managesLifecycle { drafts.deactivate() } }
    }
}

/// Route a window's close button through the same policy as Close and Escape,
/// forwarding all unrelated delegate methods to the window's original owner.
struct ReadPicoWindowCloseGuard: NSViewRepresentable {
    let drafts: ReadPicoDraftGuard
    final class Attachment: NSView {
        var moved: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); moved?(window) }
    }
    func makeNSView(context: Context) -> Attachment {
        let view = Attachment()
        view.moved = { [weak coordinator = context.coordinator] in coordinator?.attach($0) }
        return view
    }
    func updateNSView(_ view: Attachment, context: Context) {
        context.coordinator.drafts = drafts
        context.coordinator.attach(view.window)
    }
    func makeCoordinator() -> Coordinator { Coordinator(drafts: drafts) }
    static func dismantleNSView(_ view: Attachment, coordinator: Coordinator) { view.moved = nil; coordinator.attach(nil) }
    final class Coordinator: NSObject, NSWindowDelegate {
        var drafts: ReadPicoDraftGuard
        weak var window: NSWindow?
        weak var original: (any NSWindowDelegate)?
        private var allowClose = false
        init(drafts: ReadPicoDraftGuard) { self.drafts = drafts }
        func attach(_ next: NSWindow?) {
            guard window !== next else { return }
            if let window, window.delegate === self { window.delegate = original }
            window = next; original = next?.delegate; next?.delegate = self
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if allowClose || !drafts.blocksDismissal { return original?.windowShouldClose?(sender) ?? true }
            drafts.request(title: "关闭前保存修改？") { [weak self, weak sender] in
                guard let self, let sender else { return }
                self.allowClose = true; sender.performClose(nil); self.allowClose = false
            }
            return false
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? { original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector) }
    }
}
