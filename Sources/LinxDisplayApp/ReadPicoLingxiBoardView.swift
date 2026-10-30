import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import LinxDisplayCore

/// App-owned board session. Saved receipts advance background delivery; displayed receipts alone confirm panel presentation.
@MainActor final class ReadPicoLingxiBoardSession: ObservableObject {
    struct AutomaticBoard {
        let id: UUID
        let name: String
        let durationSeconds: Int
        let draft: ReadPicoCanvasDraft
        let render: () throws -> ReadPicoLingxiBoardRenderer.Result
        let cadence: () -> ReadPicoBoardRefreshPolicy.Context
    }
    struct AutomaticSource {
        let draft: ReadPicoCanvasDraft
        let render: () throws -> ReadPicoLingxiBoardRenderer.Result
        let cadence: () -> ReadPicoBoardRefreshPolicy.Context
        var renderItem: ((UUID?) throws -> ReadPicoLingxiBoardRenderer.Result)? = nil
        var boards: [AutomaticBoard] = []
    }
    @Published private(set) var frame: ReadPicoLingxiBoardRenderer.Result?
    @Published private(set) var status = "添加内容，预览后发送到设备。"
    @Published private(set) var isError = false
    @Published private(set) var automatic = false
    @Published private(set) var nextUpdate: Date?
    @Published private(set) var lastConfirmed: Date?
    @Published private(set) var effectiveSeconds: Int?
    @Published private(set) var deliveredPlaylistItemID: UUID?
    @Published private(set) var deliveredBoardName: String?
    private var carousel = ReadPicoBoardCarouselCursor()
    private var provider: (() throws -> ReadPicoLingxiBoardRenderer.Result)?
    private var transferProvider: (() throws -> ReadPicoLingxiBoardRenderer.Result)?
    private var sourceFactory: (() throws -> AutomaticSource)?
    private var automaticSource: AutomaticSource?
    private var automaticOwnerGeneration: UUID?
    private weak var originalAutomaticDraft: ReadPicoCanvasDraft?
    private weak var draft: ReadPicoCanvasDraft?
    private var manager: ReadPicoManagerModel?
    private var timer: Task<Void, Never>?
    private var receiptReadTask: Task<Void, Never>?
    private var active = false
    private var visible = false
    private var visibleOwner: UUID?
    private var generation = UUID()
    private var ownsPush = false
    private var pushID: UUID?
    private var pendingRefresh = false
    private var requestedInterval = -1
    private var cadenceContext: () -> ReadPicoBoardRefreshPolicy.Context = { .init() }
    private var lastCheck: Date?
    private var lastDeliveredBitmap: Data?
    private var lastDeliveredIdentity: String?
    private var lastDeliveredChannel: ReadPicoContentChannel?
    private struct SavedDelivery {
        let receiptID: UUID
        let snapshot: ReadPicoCanvasDraft.PushSnapshot
        let bitmap: Data
        let contentChannel: ReadPicoContentChannel
        let item: ReadPicoBoardPlaylistItem?
        let boardIndex: Int?
    }
    private var savedDelivery: SavedDelivery?
    private var deliveredBoardIndex: Int?
    private var nextBoardDue: Date?
    private var retryNotBefore: Date?
    var automaticModules: [Int] {
        guard automatic, let draft = automaticSource?.draft else { return [] }
        if let boards = automaticSource?.boards, !boards.isEmpty {
            return Array(Set(boards.flatMap { board in
                board.draft.canvasMode == 2 && board.draft.playlist.mode == .carousel
                    ? board.draft.playlist.enabledItems.map(\.module)
                    : board.draft.board.modules
            })).sorted()
        }
        return draft.playlist.mode == .carousel ? draft.playlist.enabledItems.map(\.module) : draft.board.modules
    }

    static func prefersUSB(_ manager: ReadPicoManagerModel) -> Bool { manager.prefersUSBBoard }
    static func frozenCopy(of source: ReadPicoCanvasDraft) -> ReadPicoCanvasDraft {
        let copy = ReadPicoCanvasDraft()
        copy.landscape = source.landscape; copy.dither = source.dither
        copy.image = source.image?.copy() as? NSImage
        copy.imageSource = source.imageSource?.copy() as? NSImage
        copy.wallpaperAssetID = source.wallpaperAssetID; copy.wallpaperEditData = source.wallpaperEditData
        copy.strokes = source.strokes; copy.liveStroke = source.liveStroke
        copy.canvasMode = source.canvasMode; copy.board = source.board; copy.playlist = source.playlist
        return copy
    }
    func activate(owner: UUID, manager: ReadPicoManagerModel, draft: ReadPicoCanvasDraft,
                  cadence: @escaping () -> ReadPicoBoardRefreshPolicy.Context = { .init() },
                  automaticSource: (() throws -> AutomaticSource)? = nil,
                  transferProvider: (() throws -> ReadPicoLingxiBoardRenderer.Result)? = nil,
                  provider: @escaping () throws -> ReadPicoLingxiBoardRenderer.Result) {
        if self.manager !== manager || (self.draft != nil && self.draft !== draft) {
            shutdown(); lastConfirmed = nil; lastDeliveredBitmap = nil; lastDeliveredIdentity = nil; lastDeliveredChannel = nil; lastCheck = nil
        }
        self.manager = manager; self.draft = draft; self.provider = provider
        self.transferProvider = transferProvider ?? provider
        self.sourceFactory = automaticSource; cadenceContext = cadence; active = true; visible = true; visibleOwner = owner
        refresh()
    }
    func refresh() {
        guard !ownsPush else { pendingRefresh = true; return }
        pendingRefresh = false
        do {
            guard let provider else { return }
            frame = try provider(); isError = false
        } catch { frame = nil; stop(message: error.localizedDescription, error: true) }
    }
    func edited() {
        status = automatic ? "正在自动推送已启用的版本；应用当前内容后更新。" : "画板已更新，可以发送到设备。"
        refresh()
    }
    func start(interval: Int) {
        guard active, ReadPicoBoardRefreshPolicy.supportedIntervals.contains(interval), interval != 0,
              let manager, !manager.busy, let draft else { return }
        generation = UUID(); cancelReceiptRead()
        do {
            if let sourceFactory { automaticSource = try sourceFactory() }
            else if let transferProvider { automaticSource = .init(draft: draft, render: transferProvider, cadence: cadenceContext) }
            else { return }
            guard automaticSource?.draft.hasRenderableBoardContent == true || !(automaticSource?.boards.isEmpty ?? true) else {
                throw ReadPicoManagerError.invalid("请先添加画板内容。")
            }
            originalAutomaticDraft = draft
            automaticOwnerGeneration = manager.ownerGeneration
            deliveredPlaylistItemID = nil; carousel.reset(); savedDelivery = nil
            deliveredBoardIndex = nil; deliveredBoardName = nil; nextBoardDue = nil; retryNotBefore = nil
            requestedInterval = interval; automatic = true; isError = false
            send(interval: interval, usb: Self.prefersUSB(manager))
        } catch { stop(message: error.localizedDescription, error: true) }
    }
    private func currentCadence() -> ReadPicoBoardRefreshPolicy.Context {
        if let index = candidateBoardIndex(), let board = automaticSource?.boards[index] { return board.cadence() }
        return automaticSource?.cadence() ?? cadenceContext()
    }
    private func candidateBoardIndex(now: Date = Date()) -> Int? {
        guard let boards = automaticSource?.boards, !boards.isEmpty else { return nil }
        guard let deliveredBoardIndex else { return 0 }
        if let nextBoardDue, nextBoardDue <= now { return (deliveredBoardIndex + 1) % boards.count }
        return deliveredBoardIndex
    }
    private func schedule() {
        guard active, automatic, let manager else { return }
        guard validateAutomaticOwner(manager) else { return }
        timer?.cancel()
        let token = generation
        timer = Task { @MainActor [weak self, weak manager] in
            guard let manager, self?.validateAutomaticOwner(manager) == true else { return }
            let usb = Self.prefersUSB(manager)
            // This API rejects sampling while TF is host-owned. Keep USB-only background power
            // telemetry fresh as well; otherwise charging would silently fall back after 45s.
            let age = manager.powerStatusReceivedAt.map { Date().timeIntervalSince($0) }
            if age.map({ $0 < 0 || $0 >= 5 }) ?? true { await manager.refreshDevicePowerStatus() }
            guard !Task.isCancelled, self?.active == true, self?.automatic == true, token == self?.generation,
                  self?.validateAutomaticOwner(manager) == true else { return }
            guard let requested = self?.requestedInterval,
                  let interval = ReadPicoBoardRefreshPolicy.effectiveInterval(
                    requested: requested, power: manager.powerStatus,
                    receivedAt: manager.powerStatusReceivedAt, usb: usb, context: self?.currentCadence() ?? .init()) else { self?.stop(); return }
            self?.effectiveSeconds = interval
            let elapsed = self?.lastCheck.map { Date().timeIntervalSince($0) } ?? 0
            var delay = max(0, TimeInterval(interval) - elapsed)
            if let due = self?.carousel.due { delay = min(delay, max(0, due.timeIntervalSinceNow)) }
            if let due = self?.nextBoardDue { delay = min(delay, max(0, due.timeIntervalSinceNow)) }
            if let retry = self?.retryNotBefore { delay = max(delay, max(0, retry.timeIntervalSinceNow)) }
            self?.nextUpdate = Date().addingTimeInterval(delay)
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.active, self.automatic, token == self.generation, self.validateAutomaticOwner(manager) else { return }
            if manager.busy {
                self.lastCheck = Date(); self.retryNotBefore = Date().addingTimeInterval(1)
                self.schedule(); return
            }
            self.retryNotBefore = nil
            self.send(interval: self.requestedInterval, usb: Self.prefersUSB(manager))
        }
    }
    func setInterval(_ interval: Int) {
        requestedInterval = interval
        if interval == 0 { stop() } else { powerChanged() }
    }
    func powerChanged() {
        guard active, automatic, !ownsPush, let manager else { return }
        let interval = ReadPicoBoardRefreshPolicy.effectiveInterval(requested: requestedInterval,
            power: manager.powerStatus, receivedAt: manager.powerStatusReceivedAt, usb: Self.prefersUSB(manager), context: currentCadence())
        if interval != effectiveSeconds { schedule() }
    }
    func send(interval: Int? = nil, usb: Bool = false) {
        guard active, let manager, !manager.busy, !ownsPush else { return }
        if interval != nil && automatic, !validateAutomaticOwner(manager) { return }
        do {
            let sendingAutomatically = interval != nil && automatic
            let source: ReadPicoCanvasDraft
            let rendered: ReadPicoLingxiBoardRenderer.Result
            var renderedItem: ReadPicoBoardPlaylistItem?
            var renderedBoardIndex: Int?
            if sendingAutomatically, let automaticSource {
                if let index = candidateBoardIndex() {
                    let board = automaticSource.boards[index]
                    source = board.draft; rendered = try board.render(); renderedBoardIndex = index
                } else if automaticSource.draft.playlist.mode == .carousel {
                    source = originalAutomaticDraft ?? automaticSource.draft
                    let playlist = automaticSource.draft.playlist
                    renderedItem = carousel.candidate(in: playlist)
                    guard let renderedItem, let renderItem = automaticSource.renderItem else {
                        throw ReadPicoManagerError.invalid("请添加并启用至少一个轮播模块。")
                    }
                    rendered = try renderItem(renderedItem.id)
                } else {
                    source = originalAutomaticDraft ?? automaticSource.draft
                    rendered = try automaticSource.render()
                }
            } else {
                guard let draft, let transferProvider else { return }
                source = draft; rendered = try transferProvider()
            }
            lastCheck = Date()
            let payload = rendered.transferData
            let contentIdentity = rendered.comparisonData
            let contentChannel = rendered.contentChannel
            let snapshot = try source.canvasMode == 2 ? source.makeBoardPushSnapshot(bitmap: payload) : source.makePushSnapshot(nativeGray16: true)
            if sendingAutomatically { originalAutomaticDraft = nil }
            if sendingAutomatically, let savedDelivery, manager.boardDelivery?.id == savedDelivery.receiptID,
               let identity = manager.boardConnectionIdentity, identity == lastDeliveredIdentity,
               savedDelivery.bitmap == contentIdentity, savedDelivery.contentChannel == contentChannel {
                snapshot.acknowledge()
                confirmCarousel(renderedItem); confirmBoard(renderedBoardIndex)
                checkSavedDelivery(savedDelivery, identity: identity, manager: manager)
                return
            }
            if sendingAutomatically, let identity = manager.boardConnectionIdentity,
               identity == lastDeliveredIdentity, lastDeliveredBitmap == contentIdentity, lastDeliveredChannel == contentChannel {
                // A matching saved or displayed receipt proves delivery of this exact semantic content or image.
                snapshot.acknowledge()
                confirmCarousel(renderedItem)
                confirmBoard(renderedBoardIndex)
                status = "内容没有变化，设备保留当前画面。"; schedule(); return
            }
            let requestID = UUID()
            timer?.cancel(); timer = nil
            if !rendered.bitmap.isEmpty { frame = rendered }
            pushID = requestID; ownsPush = true; isError = false
            status = "正在发送到设备…"; nextUpdate = nil
            let completion: (Bool) -> Void = { [weak self, weak manager] success in
                let delivery = success && manager?.boardDelivery?.contentChannel == contentChannel ? manager?.boardDelivery : nil
                if delivery != nil { snapshot.acknowledge() }
                guard let self, self.pushID == requestID else { return }
                self.pushID = nil; self.ownsPush = false
                if let delivery {
                    if self.visible, rendered.modelData != nil,
                       let preview = try? ReadPicoLingxiBoardRenderer.nativePreview(rendered, landscape: rendered.width > rendered.height, now: Date()) {
                        self.frame = preview
                    }
                    self.confirmCarousel(renderedItem); self.confirmBoard(renderedBoardIndex)
                    self.lastDeliveredBitmap = contentIdentity
                    self.lastDeliveredIdentity = manager?.boardConnectionIdentity
                    self.lastDeliveredChannel = contentChannel
                    if delivery.displayed {
                        self.savedDelivery = nil
                        self.lastConfirmed = Date()
                        self.status = "设备已确认显示。"
                    } else {
                        self.savedDelivery = .init(receiptID: delivery.id, snapshot: snapshot, bitmap: contentIdentity, contentChannel: contentChannel,
                                                   item: renderedItem, boardIndex: renderedBoardIndex)
                        self.status = "已保存到设备，尚未显示；阅读器保留当前页面。"
                    }
                    self.isError = false
                    if self.visible, self.pendingRefresh { self.refresh() }
                    if self.active, self.automatic { self.schedule() }
                } else { self.stop(message: manager?.message ?? "尚未确认显示，请检查连接后重试。", error: manager?.isError ?? true) }
            }
            manager.sendBoard(payload, display: !sendingAutomatically, contentChannel: contentChannel, completion: completion)
        } catch { stop(message: error.localizedDescription, error: true) }
    }
    private func checkSavedDelivery(_ saved: SavedDelivery, identity: String, manager: ReadPicoManagerModel) {
        let requestID = UUID()
        let token = generation
        timer?.cancel(); timer = nil; nextUpdate = nil; pushID = requestID; ownsPush = true
        receiptReadTask = Task { @MainActor [weak self, weak manager] in
            guard let manager else { return }
            do {
                let receipt = try await manager.refreshBoardDelivery(saved.receiptID)
                if receipt?.displayed == true { saved.snapshot.acknowledge() }
                guard let self, self.generation == token, self.pushID == requestID else { return }
                self.receiptReadTask = nil; self.pushID = nil; self.ownsPush = false
                if manager.boardConnectionIdentity != identity, self.active, self.automatic {
                    self.send(interval: self.requestedInterval, usb: Self.prefersUSB(manager)); return
                }
                guard receipt != nil else {
                    self.stop(message: "设备连接已变更，请重新连接后开启自动更新。")
                    return
                }
                if receipt?.displayed == true {
                    self.savedDelivery = nil
                    self.lastConfirmed = Date(); self.lastDeliveredBitmap = saved.bitmap
                    self.lastDeliveredIdentity = manager.boardConnectionIdentity
                    self.lastDeliveredChannel = saved.contentChannel
                    self.status = "设备已确认显示。"
                } else { self.status = "已保存到设备，尚未显示；内容未变，不重复传输。" }
                self.isError = false
                if self.visible, self.pendingRefresh { self.refresh() }
                if self.active, self.automatic { self.schedule() }
            } catch {
                guard let self, self.generation == token, self.pushID == requestID else { return }
                self.receiptReadTask = nil; self.pushID = nil; self.ownsPush = false
                if manager.boardConnectionIdentity != identity, self.active, self.automatic {
                    self.send(interval: self.requestedInterval, usb: Self.prefersUSB(manager)); return
                }
                if error is CancellationError, self.active, self.automatic {
                    self.retryNotBefore = Date().addingTimeInterval(1); self.schedule()
                } else { self.stop(message: error.localizedDescription, error: true) }
            }
        }
    }
    private func confirmCarousel(_ item: ReadPicoBoardPlaylistItem?) {
        guard let item else { return }
        carousel.confirm(item, minimumInterval: effectiveSeconds ?? 1)
        deliveredPlaylistItemID = carousel.displayedID
    }
    private func confirmBoard(_ index: Int?) {
        guard let index, let board = automaticSource?.boards[index] else { return }
        if deliveredBoardIndex != index {
            deliveredBoardIndex = index
            nextBoardDue = Date().addingTimeInterval(TimeInterval(max(5, board.durationSeconds)))
        }
        deliveredBoardName = board.name
    }
    private func cancelReceiptRead() {
        guard let receiptReadTask else { return }
        receiptReadTask.cancel(); self.receiptReadTask = nil; pushID = nil; ownsPush = false
    }
    func stop(message: String = "自动更新已关闭。", error: Bool = false) {
        generation = UUID()
        // 中文：只读回执属于本次自动会话；旧读任务不能清理或停止重新开启的会话。
        // English: Revoke this session's read ownership before a replacement automatic run starts.
        cancelReceiptRead()
        timer?.cancel(); timer = nil; automatic = false; nextUpdate = nil; effectiveSeconds = nil
        automaticSource = nil; originalAutomaticDraft = nil; automaticOwnerGeneration = nil
        deliveredPlaylistItemID = nil; carousel.reset()
        deliveredBoardIndex = nil; deliveredBoardName = nil; nextBoardDue = nil; retryNotBefore = nil; savedDelivery = nil
        status = message; isError = error
    }
    private func validateAutomaticOwner(_ manager: ReadPicoManagerModel) -> Bool {
        guard automaticOwnerGeneration == manager.ownerGeneration else {
            stop(message: "设备管理会话已结束，自动更新已停止。请重新连接并手动开启。")
            return false
        }
        return true
    }
    func disappear(owner: UUID) {
        // During a floating-to-inline transfer the replacement can appear first.
        // The retiring view must not clear the replacement's preview provider.
        guard visibleOwner == owner else { return }
        visibleOwner = nil
        visible = false; provider = nil; sourceFactory = nil; cadenceContext = { .init() }; pendingRefresh = false
        if !automatic { active = false; generation = UUID() }
    }
    func shutdown() {
        active = false; visible = false; visibleOwner = nil; generation = UUID(); provider = nil; transferProvider = nil; sourceFactory = nil; pendingRefresh = false
        stop(); pushID = nil; ownsPush = false; manager = nil; draft = nil
    }
}

/// The reader board follows Oracle's module composition, using a full-size native grayscale preview.
/// 设备侧栏内的完整画板编辑器；文字、图片及实时模块共用口袋先知画板引擎。
@MainActor
struct ReadPicoLingxiBoardView: View {
    @ObservedObject private var model: AppModel
    @Environment(\.controlCenterHasExternalPreview) private var hasExternalPreview
    let deviceID: UUID
    @ObservedObject private var drafts: ReadPicoDraftGuard
    @ObservedObject private var draft: ReadPicoCanvasDraft
    @ObservedObject private var manager: ReadPicoManagerModel
    @ObservedObject private var session: ReadPicoLingxiBoardSession
    private let onConfigureModule: ((CanvasModule) -> Void)?
    private let supportsBoardCarousel: Bool
    private enum Page: String, CaseIterable, Identifiable {
        case content, delivery
        var id: Self { self }
        var title: String { self == .content ? "内容编辑" : "推送设置" }
    }
    @State private var page: Page = .content
    @State private var presentationID = UUID()
    @State private var previewTask: Task<Void, Never>?
    @State private var entitySearch = ""
    @State private var expandedModule: Int?
    @State private var draggedModule: Int?
    @State private var showClear = false
    @State private var showAdvanced = false
    @State private var showConnectionOptions = false
    @ObservedObject private var wallpaperLibrary = PicoNativeLibrary.shared
    @State private var showWallpaperPicker = false
    @State private var playlistPreviewID: UUID?
    @State private var photoRequest: BoardPhotoRequest?
    @State private var pendingPhotoRequest: BoardPhotoRequest?
    private struct BoardPhotoRequest: Identifiable {
        let id = UUID()
        let asset: PicoNativeAsset?
        let source: NSImage
        let target: PicoPreviewTarget
        let initial: PicoPhotoEdit?
    }
    private var wallpaperKey: String { "device.\(deviceID.uuidString).board" }
    private var photoTarget: PicoPreviewTarget { draft.landscape ? .picoLandscape : .pico }
    init(model: AppModel, deviceID: UUID, drafts: ReadPicoDraftGuard,
         onConfigureModule: ((CanvasModule) -> Void)? = nil,
         supportsBoardCarousel: Bool = true) {
        self.model = model; self.deviceID = deviceID; self.drafts = drafts
        self.onConfigureModule = onConfigureModule
        self.supportsBoardCarousel = supportsBoardCarousel
        _draft = ObservedObject(wrappedValue: drafts.canvas)
        _manager = ObservedObject(wrappedValue: drafts.model)
        _session = ObservedObject(wrappedValue: model.readPicoBoardSession(for: deviceID))
    }
    private var modules: [CanvasModule] { draft.board.modules.compactMap(CanvasModule.init(rawValue:)) }
    private var canSend: Bool {
        !manager.busy && draft.hasRenderableBoardContent && session.frame != nil
    }
    private var rotatesSavedBoards: Bool { supportsBoardCarousel && drafts.boardLibrary?.carouselEnabled == true }
    private var canStartAutomatic: Bool {
        if rotatesSavedBoards {
            return !manager.busy && (drafts.boardLibrary?.boards.filter(\.includedInCarousel).count ?? 0) >= 2
        }
        return canSend
    }
    private var usbTransport: Bool { ReadPicoLingxiBoardSession.prefersUSB(manager) }
    private var connectionTitle: String { manager.boardConnectionDescription }
    private var cadenceContext: ReadPicoBoardRefreshPolicy.Context { Self.refreshContext(model: model, draft: draft) }
    private static func refreshContext(model: AppModel, draft: ReadPicoCanvasDraft) -> ReadPicoBoardRefreshPolicy.Context {
        .init(dynamicSeconds: model.settings.dynamicUploadSeconds,
              contentCheckSeconds: Int(RuntimePerformancePolicy.deviceCanvasContentCheckInterval(
                modules: (draft.playlist.mode == .carousel ? draft.playlist.enabledItems.map(\.module) : draft.board.modules).compactMap(CanvasModule.init(rawValue:)), timeFormat: model.settings.timeFormat,
                nowPlaying: model.nowPlaying.isPlaying, pomodoroRunning: model.pomodoroSnapshot.isRunning)))
    }
    private var availableModules: [CanvasModule] { CanvasModule.oraclePanelModules.filter { !draft.board.modules.contains($0.rawValue) } }
    private var sharedPlaylistModules: [CanvasModule] {
        CanvasModule.oraclePanelModules.filter { module in
            ![CanvasModule.text, .image, .homeAssistant].contains(module)
                && draft.playlist.items.contains(where: { $0.module == module.rawValue })
        }
    }
    private var entityCandidates: [HAEntity] {
        model.haSnapshot.entities.filter { entitySearch.isEmpty || $0.displayName.localizedCaseInsensitiveContains(entitySearch) || $0.entityId.localizedCaseInsensitiveContains(entitySearch) }
    }
    /// A drawing surface remains part of editing; a passive duplicate preview does not.
    private var needsLocalCanvas: Bool { draft.canvasMode == 1 && page == .content }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header.padding(.horizontal, 20).padding(.vertical, 12)
                Divider()
                if hasExternalPreview && !needsLocalCanvas {
                    settingsForm
                        .dropDestination(for: URL.self) { urls, _ in
                            guard !manager.busy, let url = urls.first, url.isFileURL else { return false }
                            if loadImage(from: url) { draft.canvasMode = 0; return true }
                            return false
                        }
                } else if geometry.size.width >= 820 {
                    HStack(alignment: .top, spacing: 0) {
                        settingsForm
                            .frame(maxWidth: .infinity, alignment: .top)
                        Divider().padding(.vertical, 4)
                        Form {
                            Section("画板预览") {
                                preview(maxHeight: max(150, geometry.size.height - 210), availableWidth: 280)
                            }
                        }
                        .formStyle(.grouped)
                        .controlCenterHostedFormSurface()
                        .frame(width: 320)
                    }
                } else {
                    Form {
                        pageSections
                        Section("画板预览") {
                            preview(maxHeight: max(180, min(420, geometry.size.height * 0.48)),
                                    availableWidth: max(1, geometry.size.width - 80))
                        }
                    }.formStyle(.grouped)
                    .controlCenterHostedFormSurface()
                }
            }
        }
        .confirmationDialog("清空当前手绘？", isPresented: $showClear, titleVisibility: .visible) {
            Button("清空手绘", role: .destructive) { draft.strokes = []; draft.liveStroke = [] }
            Button("取消", role: .cancel) {}
        }
        .controlSize(.regular)
        .sheet(isPresented: $showWallpaperPicker, onDismiss: {
            if let request = pendingPhotoRequest { pendingPhotoRequest = nil; photoRequest = request }
        }) {
            SharedWallpaperPicker(title: "选择画板原图") { asset, image in
                // A document owns its crop. Another draft using the same asset cannot override it.
                // 同图不同草稿拥有独立构图；未保存编辑不写回共享设备用途。
                let isCurrentAsset = draft.wallpaperAssetID == asset.id
                let currentEdit = isCurrentAsset ? draft.wallpaperEditData.flatMap { try? JSONDecoder().decode(PicoPhotoEdit.self, from: $0) } : nil
                let use = wallpaperLibrary.use(for: wallpaperKey)
                let initial = isCurrentAsset ? currentEdit : (use?.assetID == asset.id && use?.target == photoTarget ? use?.edit : nil)
                pendingPhotoRequest = BoardPhotoRequest(asset: asset, source: isCurrentAsset ? draft.imageSource ?? image : image,
                                                       target: photoTarget, initial: initial)
            }
        }
        .sheet(item: $photoRequest) { request in
            PicoPhotoEditor(image: request.source, target: request.target, initial: request.initial, drafts: drafts,
                applicationNote: "应用后更新 Mac 画板草稿；使用发送按钮同步到设备。") { edit in
                guard let encoded = try? JSONEncoder().encode(edit) else { return false }
                let composed = PicoPhotoRenderer.composeColor(image: request.source, edit: edit, target: request.target)
                draft.applyWallpaper(source: request.source, rendered: composed, assetID: request.asset?.id, editData: encoded)
                manager.report("图片构图已更新到 Mac 草稿，尚未发送到设备。")
                return true
            }
        }
        .onAppear(perform: activate)
        .onChange(of: manager.usbBoardNeedsSelection) { _, needed in
            if needed { page = .delivery; showConnectionOptions = true }
        }
        .onDisappear { previewTask?.cancel(); previewTask = nil; session.disappear(owner: presentationID) }
        .onChange(of: draft.board) { previous, current in
            var comparable = previous
            comparable.intervalSeconds = current.intervalSeconds
            if comparable == current { session.setInterval(current.intervalSeconds) }
            else { queuePreview(edit: true) }
        }
        .onReceive(model.settings.$dynamicUploadSeconds) { _ in session.powerChanged() }
        .onReceive(model.settings.$timeFormat) { _ in session.powerChanged() }
        .onReceive(model.settings.objectWillChange) { _ in queuePreview() }
        .onReceive(model.$readingExcerptCards.dropFirst()) { _ in queuePreview() }
        .onReceive(model.$readingExcerptInstanceCards.dropFirst()) { _ in queuePreview() }
        .onChange(of: draft.landscape) { _, _ in queuePreview(edit: true) }
        .onChange(of: draft.image) { _, _ in queuePreview(edit: true) }
        .onChange(of: draft.canvasMode) { _, _ in queuePreview(edit: true) }
        .onChange(of: draft.playlist) { _, value in
            if value.item(id: playlistPreviewID) == nil { playlistPreviewID = value.enabledItems.first?.id }
            queuePreview(edit: true)
        }
        .onChange(of: draft.strokes) { _, _ in queuePreview(edit: true) }
        .onReceive(model.$nowPlaying) { _ in if modules.contains(.nowPlaying) { queuePreview() } }
        .onReceive(model.$system) { _ in if modules.contains(where: { [.cpu, .memory, .disk, .network, .uptime].contains($0) }) { queuePreview() } }
        .onReceive(model.$haSnapshot) { _ in if modules.contains(.homeAssistant) || modules.contains(where: { $0.bambuSlotIndex != nil }) { queuePreview() } }
        .task {
            var elapsed = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                await manager.refreshCardAvailability()
                guard !Task.isCancelled else { return }
                elapsed += 1
                if elapsed % 5 == 0, session.automatic {
                    await manager.refreshDevicePowerStatus()
                    guard !Task.isCancelled else { return }
                    session.powerChanged()
                }
                if elapsed >= max(1, session.effectiveSeconds ?? cadenceContext.contentCheckSeconds) {
                    elapsed = 0
                    if modules.contains(.clock) || modules.contains(.date) || modules.contains(.pomodoro) { session.refresh() }
                    if modules.contains(where: { [.cpu, .memory, .disk, .network, .uptime].contains($0) }) { model.refreshReadPicoSystemSnapshot() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let library = drafts.boardLibrary {
                ReadPicoBoardLibraryControls(library: library, drafts: drafts, session: session, compact: true,
                                            supportsCarousel: supportsBoardCarousel)
            }
            HStack(spacing: 16) { pagePicker; Spacer(minLength: 12); fileMenu }
        }
    }
    private var pagePicker: some View {
        Picker("画板工作区", selection: $page) {
            ForEach(Page.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
    }
    private var settingsForm: some View {
        Form {
            pageSections
            if hasExternalPreview && !needsLocalCanvas {
                Section("画板预览") {
                    Button("刷新预览", systemImage: "arrow.clockwise", action: refreshPreview)
                        .disabled(manager.busy)
                    if draft.hasUnsavedLocalChanges {
                        Label("有未保存的画板修改", systemImage: "circle.dotted")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.formStyle(.grouped)
        .controlCenterHostedFormSurface()
    }
    @ViewBuilder private var pageSections: some View {
        if page == .content { editor }
        else { pushSettings }
    }
    private var fileMenu: some View {
        Menu {
            if let library = drafts.boardLibrary {
                Button("保存画板", systemImage: "square.and.arrow.down") {
                    do { try saveCurrentBoard(in: library); manager.report("画板已保存到此设备的 Mac 画板库。") }
                    catch { manager.report(error.localizedDescription, error: true) }
                }
                Button("导入画板草稿…", systemImage: "folder") { openDraft() }
                Button("导出可编辑草稿…", systemImage: "square.and.arrow.up") { saveDraft() }
            } else {
                Button("打开画板草稿…", systemImage: "folder") { openDraft() }
                Button("保存画板草稿…", systemImage: "square.and.arrow.down") { saveDraft() }
            }
            Divider()
            Button("导出 16 灰阶图片…", systemImage: "photo") { exportBitmap() }.disabled(session.frame == nil)
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).fixedSize().frame(minWidth: 28, minHeight: 28)
        .accessibilityLabel("画板文件与导出").help("画板文件与导出").disabled(manager.busy)
    }
    @ViewBuilder private var editor: some View {
        Section("当前画板") {
            TextField("名称", text: $draft.board.name)
            Text("编辑内容会更新软件预览；设备上的画面以发送确认结果为准。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Section("内容") {
            Picker("内容", selection: $draft.canvasMode) {
                Text("图片").tag(0); Text("组件").tag(2); Text("手绘").tag(1)
            }.pickerStyle(.segmented).accessibilityLabel("画板内容类型")
            if draft.canvasMode == 2 {
                Picker("显示方式", selection: Binding(get: { draft.playlist.mode }, set: switchPresentation)) {
                    ForEach(ReadPicoBoardPlaylist.Mode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                if draft.playlist.mode == .carousel {
                    ReadPicoBoardPlaylistEditor(model: model, playlist: $draft.playlist, deviceID: deviceID, drafts: drafts,
                        landscape: draft.landscape, onPreview: { id in playlistPreviewID = id; queuePreview() })
                    if let onConfigureModule, !sharedPlaylistModules.isEmpty {
                        Menu("模块通用设置", systemImage: "slider.horizontal.3") {
                            ForEach(sharedPlaylistModules) { module in
                                Button { onConfigureModule(module) } label: { Label(module.title, systemImage: module.icon) }
                            }
                        }
                    }
                } else { componentEditor }
            } else if draft.canvasMode == 0 {
                VStack(alignment: .leading, spacing: 12) {
                    Text("图片").font(.headline)
                    Button(draft.image == nil ? "选择图片…" : "更换图片…", systemImage: "photo") { chooseImage() }
                    Button("调整构图…", systemImage: "crop.rotate") { editBoardImage() }.disabled(draft.image == nil)
                    Text("从共享壁纸库选择原图，自由裁剪、缩放与旋转；发送时转换为 16 级灰阶。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("手绘").font(.headline)
                    Text("直接在画板上绘画，笔迹会保留在草稿中。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("撤销", systemImage: "arrow.uturn.backward") { if !draft.strokes.isEmpty { draft.strokes.removeLast() } }.disabled(draft.strokes.isEmpty)
                        Button("清空", systemImage: "trash", role: .destructive) { showClear = true }.disabled(draft.strokes.isEmpty && draft.liveStroke.isEmpty)
                    }
                }
            }
        }
        Section("显示与排版") {
            Picker("预览方向", selection: $draft.landscape) { Text("竖屏").tag(false); Text("横屏").tag(true) }.pickerStyle(.segmented)
            if draft.canvasMode == 2 && draft.playlist.mode == .composition {
                Picker("排布", selection: $draft.board.columns) { Text("单列").tag(1); Text("双列").tag(2) }.pickerStyle(.segmented)
            }
            if draft.canvasMode == 2 {
                Text("预览与设备共用原生排版，文字和卡片会随横竖屏自适应。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("更多显示选项", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("内容大小", selection: $draft.board.rasterScale) { Text("紧凑").tag(2); Text("标准").tag(3); Text("大号").tag(4) }
                        Toggle("深色背景", isOn: $draft.board.darkBackground)
                    }.padding(.top, 12)
                }
            }
        }
        Section {
            Button("前往推送设置", systemImage: "paperplane") { page = .delivery }
        }
    }
    @ViewBuilder private var pushSettings: some View {
        Section("推送到设备") {
            LabeledContent("当前画板", value: draft.board.name)
            Label(connectionTitle, systemImage: usbTransport ? "cable.connector" : "wifi")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            sendButton
            delivery
            if !draft.hasRenderableBoardContent {
                Text("先在内容编辑中添加图片、组件或手绘。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        Section("自动推送与轮播") {
            updateControls
            if draft.canvasMode == 2 && draft.playlist.mode == .carousel {
                Text("轮播 \(draft.playlist.enabledItems.count) 项，按内容编辑中的顺序与停留时间播放。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Section("设备连接") {
            DisclosureGroup("连接选项", isExpanded: $showConnectionOptions) {
                ReadPicoUSBConnectionPanel(drafts: drafts, forBoard: true)
                    .padding(.top, 10)
            }
            Text("优先通过局域网发送，离线时可用 USB 直传。自动更新在后台接收，阅读器保留当前操作。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let library = drafts.boardLibrary {
            Section("画板管理") {
                ReadPicoBoardLibraryControls(library: library, drafts: drafts, session: session, compact: false,
                                            supportsCarousel: supportsBoardCarousel)
            }
        }
    }
    private var componentEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("组件").font(.headline)
                Text("\(modules.count)/12").foregroundStyle(.secondary).font(.callout)
                Spacer()
                Menu {
                    ForEach(availableModules) { item in
                        Button { add(item) } label: { Label(item.title, systemImage: item.icon) }
                    }
                } label: { Label("添加", systemImage: "plus") }
                    .disabled(draft.board.modules.count >= 12 || availableModules.isEmpty)
            }
            if modules.isEmpty {
                Text("添加时钟、文字或信息组件，开始制作画板。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(modules) { module in
                moduleRow(module)
                    .onDrag { draggedModule = module.rawValue; return NSItemProvider(object: "pico-board-module:\(module.rawValue)" as NSString) }
                    .onDrop(of: [.plainText], isTargeted: nil) { _ in
                        guard let source = draggedModule, source != module.rawValue else { return false }
                        move(source, before: module.rawValue); draggedModule = nil; return true
                    }
            }
            if let selected = modules.first(where: { $0.rawValue == expandedModule }) {
                Divider()
                Label(selected.title, systemImage: selected.icon).font(.headline)
                moduleOptions(selected)
                if draft.board.columns == 2 {
                    Toggle("占满整行", isOn: Binding(get: { draft.board.fullWidthModules.contains(selected.rawValue) }, set: { enabled in
                        draft.board.fullWidthModules.removeAll { $0 == selected.rawValue }
                        if enabled { draft.board.fullWidthModules.append(selected.rawValue) }
                    }))
                }
            }
        }
    }
    private var updateControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("自动更新", isOn: Binding(get: { session.automatic }, set: { enabled in
                if enabled {
                    if draft.board.intervalSeconds == 0 { draft.board.intervalSeconds = -1 }
                    session.start(interval: draft.board.intervalSeconds)
                } else { session.stop() }
            })).disabled(!session.automatic && !canStartAutomatic)
            Text((session.automatic ? "" : "启用后：") + ReadPicoBoardRefreshPolicy.summary(requested: draft.board.intervalSeconds,
                    power: manager.powerStatus, receivedAt: manager.powerStatusReceivedAt, usb: usbTransport, context: cadenceContext))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if session.automatic {
                Text(rotatesSavedBoards
                     ? "正在轮播启动时保存的画板版本。编辑后保存并更新轮播，才会应用到自动推送。"
                     : "正在推送已启用的版本。编辑后点击“应用当前内容并发送”更新自动推送内容。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("更新设置") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("频率", selection: $draft.board.intervalSeconds) {
                        Text("跟随多屏灵犀").tag(-1)
                        Text("每 1 秒").tag(1); Text("每 2 秒").tag(2); Text("每 5 秒").tag(5); Text("每 10 秒").tag(10); Text("每 15 秒").tag(15); Text("每 30 秒").tag(30)
                        Text("每分钟").tag(60); Text("每 5 分钟").tag(300); Text("每 15 分钟").tag(900)
                        Text("每 30 分钟").tag(1800); Text("每小时").tag(3600); Text("仅手动").tag(0)
                    }
                    Text("充电时跟随软件的动态推送间隔，电池供电时沿用其他墨水屏画板的内容检查策略。只有画面变化才发送；USB 等待连接、传输和显示确认后再继续。离开此页后，软件运行期间继续更新。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 10)
            }
        }
    }
    private func moduleRow(_ module: CanvasModule) -> some View {
        HStack(spacing: 8) {
            Button { expandedModule = module.rawValue } label: {
                HStack(spacing: 8) {
                    Label(module.title, systemImage: module.icon).lineLimit(2)
                    Spacer(minLength: 4)
                    if expandedModule == module.rawValue { Image(systemName: "checkmark").font(.callout.weight(.semibold)) }
                }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(expandedModule == module.rawValue ? [.isSelected] : [])
            Menu {
                Button("向前移动", systemImage: "chevron.up") { nudge(module.rawValue, by: -1) }.disabled(draft.board.modules.first == module.rawValue)
                Button("向后移动", systemImage: "chevron.down") { nudge(module.rawValue, by: 1) }.disabled(draft.board.modules.last == module.rawValue)
                Divider()
                Button("移除组件", systemImage: "trash", role: .destructive) { remove(module) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().frame(minWidth: 28, minHeight: 28)
                .accessibilityLabel("\(module.title)的更多操作")
        }.padding(8)
        .background(expandedModule == module.rawValue ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private func moduleOptions(_ module: CanvasModule) -> some View {
        switch module {
        case .text:
            TextEditor(text: $draft.board.text).font(.body).frame(minHeight: 100).border(Color.secondary.opacity(0.25))
            Text("画板的独立文字，不会覆盖其他设备的文字。") .font(.caption).foregroundStyle(.secondary)
        case .image:
            Button("选择画板图片…", systemImage: "photo") { chooseImage() }
            Button("调整构图…", systemImage: "crop.rotate") { editBoardImage() }.disabled(draft.image == nil)
            if let image = draft.image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 120) }
            Text("原图保留在草稿内；图片与其他模块按所选顺序排布。") .font(.caption).foregroundStyle(.secondary)
        case .homeAssistant:
            TextField("查找实体", text: $entitySearch).textFieldStyle(.roundedBorder)
            if entityCandidates.isEmpty { Text("在多屏灵犀连接 Home Assistant 后即可选择实体。") .font(.callout).foregroundStyle(.secondary) }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(entityCandidates.prefix(80)), id: \.entityId) { entity in
                            Toggle(entity.displayName, isOn: Binding(get: { draft.board.entityIDs.contains(entity.entityId) }, set: { selected in
                                draft.board.entityIDs.removeAll { $0 == entity.entityId }
                                if selected && draft.board.entityIDs.count < 24 { draft.board.entityIDs.append(entity.entityId) }
                            })).disabled(!draft.board.entityIDs.contains(entity.entityId) && draft.board.entityIDs.count >= 24)
                        }
                    }
                }.frame(maxHeight: 200)
            }
            Text("已选 \(draft.board.entityIDs.count) / 24 个实体。仅显示，不触发设备控制。") .font(.caption).foregroundStyle(.secondary)
        case .nowPlaying:
            Toggle("封面与文字横向排布", isOn: $draft.board.nowPlayingHorizontal)
            Text("使用多屏灵犀正在播放的真实标题、歌手、专辑和封面。") .font(.caption).foregroundStyle(.secondary)
        case .grokBot:
            Text("此版显示 Grok 状态与额度，暂不支持动画。")
                .font(.callout).foregroundStyle(.secondary)
        case .weather:
            Text(model.settings.weatherSnapshot.map { "\($0.city) · \($0.description)" } ?? "请先在多屏灵犀天气页选择城市。") .font(.callout).foregroundStyle(.secondary)
            Button(model.weatherBusy ? "正在更新天气…" : "获取最新天气") { Task { await model.refreshWeather(); session.refresh() } }
                .disabled(model.weatherBusy || !model.settings.weather.isValid)
        default:
            Text(module.bambuSlotIndex != nil || module.formlabsSlotIndex != nil ? "使用多屏灵犀已经配置的对应打印机与显示字段。" : "使用多屏灵犀相同模块的数据，由小纸 Pico 按屏幕方向排版。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if ![CanvasModule.text, .image, .homeAssistant].contains(module), let onConfigureModule {
            Button("配置\(module.title)…", systemImage: "slider.horizontal.3") {
                onConfigureModule(module)
            }
            Text("在多屏灵犀的对应模块中统一配置，画板会沿用这些设置。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func preview(maxHeight: CGFloat, availableWidth: CGFloat) -> some View {
        let ratio = draft.landscape ? 1216.0 / 684 : 684.0 / 1216
        let width = max(1, min(availableWidth, maxHeight * ratio, draft.landscape ? 900 : 480))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("软件渲染预览").font(.headline).lineLimit(1)
                Spacer()
                Button { refreshPreview() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("刷新预览").accessibilityLabel("刷新预览").disabled(manager.busy)
            }
            ZStack {
                if draft.canvasMode == 1 {
                    Color.white
                    drawingSurface
                } else {
                    ReadPicoDevicePreview(image: session.frame?.preview, landscape: draft.landscape)
                }
            }
            .frame(width: width, height: width / ratio)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(draft.canvasMode == 1 ? Color.secondary.opacity(0.3) : .clear))
            .frame(maxWidth: .infinity)
            .dropDestination(for: URL.self) { urls, _ in
                guard !manager.busy, let url = urls.first, url.isFileURL else { return false }
                if loadImage(from: url) { draft.canvasMode = 0; return true }
                return false
            }
            Text("\(draft.landscape ? "1216 × 684" : "684 × 1216") · 16 级灰阶")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("每次发送横竖两版，设备旋转时自动切换。这里仅切换当前草稿的预览方向。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if draft.hasUnsavedLocalChanges { Label("有未保存的画板修改", systemImage: "circle.dotted").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var drawingSurface: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for stroke in draft.strokes + (draft.liveStroke.isEmpty ? [] : [draft.liveStroke]) {
                    guard let first = stroke.first else { continue }
                    var path = Path()
                    let start = CGPoint(x: first.x * size.width, y: first.y * size.height)
                    path.move(to: start)
                    let lineWidth = max(1, 5 * size.width / (draft.landscape ? 1216 : 684))
                    if stroke.count == 1 {
                        path.addEllipse(in: CGRect(x: start.x - lineWidth / 2, y: start.y - lineWidth / 2, width: lineWidth, height: lineWidth))
                        context.fill(path, with: .color(.black))
                    } else {
                        for point in stroke.dropFirst() { path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height)) }
                        context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    }
                }
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !manager.busy, draft.liveStroke.count < 20_000, geometry.size.width > 0, geometry.size.height > 0 else { return }
                draft.liveStroke.append(CGPoint(x: min(1, max(0, value.location.x / geometry.size.width)), y: min(1, max(0, value.location.y / geometry.size.height))))
            }.onEnded { _ in
                if !manager.busy, !draft.liveStroke.isEmpty, draft.strokes.count < 10_000 { draft.strokes.append(draft.liveStroke) }
                draft.liveStroke = []
            })
        }.accessibilityLabel("灵犀画板手绘区域")
    }
    @ViewBuilder private var delivery: some View {
        if manager.busy {
            HStack(spacing: 12) {
                if let fraction = manager.usbBoardProgress?.fraction {
                    ProgressView(value: fraction).frame(maxWidth: 140).accessibilityLabel("画板发送进度")
                } else { ProgressView().controlSize(.small) }
                Text(manager.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if manager.canCancel { Button(manager.cancelTitle) { manager.cancelOperation() } }
            }
        } else if manager.boardSubmissionUncertain {
            VStack(alignment: .leading, spacing: 8) {
                Label("设备可能已收到画面，自动更新已暂停。", systemImage: "exclamationmark.circle").font(.callout)
                Text("请先查看 Pico 当前显示，再决定是否继续，避免重复发送。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("已核对设备显示，允许继续发送") { manager.reconcileBoardSubmission() }
            }
        } else if session.isError || manager.isError {
            Label(manager.isError ? manager.message : session.status, systemImage: "exclamationmark.circle")
                .font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } else if let date = session.lastConfirmed {
            VStack(alignment: .leading, spacing: 6) {
                Label("已发送到设备 · \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                if let name = session.deliveredBoardName { Text("当前推送：\(name)").foregroundStyle(.secondary) }
                if let next = session.nextUpdate { Text("下次检查 \(next.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary) }
            }.font(.callout)
        }
    }
    private var sendButton: some View {
        Button(session.automatic ? (rotatesSavedBoards ? "保存当前画板并更新轮播" : "应用当前内容并发送") : "发送到设备", systemImage: "paperplane") {
            if session.automatic {
                if rotatesSavedBoards, let library = drafts.boardLibrary {
                    do { try saveCurrentBoard(in: library) }
                    catch { manager.report(error.localizedDescription, error: true); return }
                }
                session.start(interval: draft.board.intervalSeconds)
            }
            else { session.send(usb: usbTransport) }
        }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!canSend)
            .keyboardShortcut(.return, modifiers: [.command])
    }
    private func activate() {
        let old = model.settings.devices.first { $0.id == deviceID }?.settings.readPico?.informationPush ?? .init()
        var initial = ReadPicoLingxiBoardConfiguration()
        initial.modules = ["clock": [0, 1], "weather": [27], "music": [5], "system": [2, 3, 15, 4], "home": [16], "image": [9]][old.source] ?? [0, 1]
        initial.entityIDs = old.entityIDs; initial.intervalSeconds = old.intervalSeconds
        draft.initializeBoardIfNeeded(initial, landscape: old.landscape)
        model.refreshReadPicoSystemSnapshot()
        let source = draft, app = model, library = drafts.boardLibrary
        let supportsCarousel = supportsBoardCarousel
        session.activate(owner: presentationID, manager: manager, draft: source,
            cadence: { [weak app] in app.map { Self.refreshContext(model: $0, draft: source) } ?? .init() },
            automaticSource: { [weak app] in
                guard let app else { throw ReadPicoManagerError.unavailable("软件正在退出，自动更新已停止。") }
                let frozen = ReadPicoLingxiBoardSession.frozenCopy(of: source)
                var automaticSource = ReadPicoLingxiBoardSession.AutomaticSource(draft: frozen, render: { [weak app] in
                    guard let app else { throw ReadPicoManagerError.unavailable("软件正在退出，自动更新已停止。") }
                    if RuntimePerformancePolicy.needsSystemSample(modules: frozen.board.modules.compactMap(CanvasModule.init(rawValue:))) { app.refreshReadPicoSystemSnapshot() }
                    return try ReadPicoLingxiBoardRenderer.transfer(draft: frozen, model: app, deviceID: deviceID)
                }, cadence: { [weak app] in app.map { Self.refreshContext(model: $0, draft: frozen) } ?? .init() },
                    renderItem: { [weak app] itemID in
                        guard let app else { throw ReadPicoManagerError.unavailable("软件正在退出。") }
                        app.refreshReadPicoSystemSnapshot()
                        return try ReadPicoLingxiBoardRenderer.transfer(draft: frozen, model: app, deviceID: deviceID, playlistItemID: itemID)
                    })
                if supportsCarousel, let library, library.carouselEnabled {
                    let entries = library.boards.filter(\.includedInCarousel)
                    guard entries.count >= 2 else { throw ReadPicoManagerError.invalid("请至少选择两块参与轮播的画板。") }
                    automaticSource.boards = try entries.flatMap { entry -> [ReadPicoLingxiBoardSession.AutomaticBoard] in
                        let board = try library.loadBoard(entry.id)
                        guard board.hasRenderableBoardContent else {
                            throw ReadPicoManagerError.invalid("“\(entry.name)”尚无可显示内容，请先编辑并保存，或取消参与轮播。")
                        }
                        let items: [ReadPicoBoardPlaylistItem?] = board.canvasMode == 2 && board.playlist.mode == .carousel
                            ? board.playlist.enabledItems.map { Optional($0) } : [nil]
                        return items.map { item in
                            .init(id: item?.id ?? entry.id,
                                  name: item.map { entry.name + " · " + $0.name } ?? entry.name,
                                  durationSeconds: item?.durationSeconds ?? entry.durationSeconds,
                                  draft: board, render: { [weak app] in
                                guard let app else { throw ReadPicoManagerError.unavailable("软件正在退出。") }
                                app.refreshReadPicoSystemSnapshot()
                                return try ReadPicoLingxiBoardRenderer.transfer(draft: board, model: app, deviceID: deviceID,
                                    playlistItemID: item?.id, readingInstance: "board.\(entry.id.uuidString)")
                            }, cadence: { [weak app] in app.map { Self.refreshContext(model: $0, draft: board) } ?? .init() })
                        }
                    }
                }
                return automaticSource
            }, transferProvider: { [weak app] in
                guard let app else { throw ReadPicoManagerError.unavailable("软件已关闭。") }
                return try ReadPicoLingxiBoardRenderer.transfer(draft: source, model: app, deviceID: deviceID, playlistItemID: playlistPreviewID)
            }, provider: { [weak app] in
                guard let app else { throw ReadPicoManagerError.unavailable("软件已关闭。") }
                return try ReadPicoLingxiBoardRenderer.render(draft: source, model: app, deviceID: deviceID, playlistItemID: playlistPreviewID)
            })
        if expandedModule == nil { expandedModule = modules.first?.rawValue }
    }
    private func queuePreview(edit: Bool = false) {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            if edit { session.edited() } else { session.refresh() }
        }
    }
    private func refreshPreview() { previewTask?.cancel(); model.refreshReadPicoSystemSnapshot(); session.refresh() }
    private func switchPresentation(_ mode: ReadPicoBoardPlaylist.Mode) {
        if mode == .carousel, draft.playlist.items.isEmpty, !draft.board.modules.isEmpty {
            var playlist = ReadPicoBoardPlaylist.fromComposition(draft.board)
            var sourcePNG: Data?
            if let image = draft.imageSource ?? draft.image,
               let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                sourcePNG = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            }
            for index in playlist.items.indices {
                playlist.items[index].name = CanvasModule(rawValue: playlist.items[index].module)?.title ?? "模块"
                if playlist.items[index].module == CanvasModule.image.rawValue {
                    playlist.items[index].imageSourcePNG = sourcePNG
                    playlist.items[index].imageAssetID = draft.wallpaperAssetID
                    playlist.items[index].imageEditData = draft.wallpaperEditData
                }
            }
            do { try playlist.validate(); draft.playlist = playlist }
            catch { manager.report(error.localizedDescription); return }
        } else { draft.playlist.mode = mode }
        playlistPreviewID = draft.playlist.enabledItems.first?.id
    }
    private func add(_ module: CanvasModule) {
        guard draft.board.modules.count < 12, !draft.board.modules.contains(module.rawValue) else { return }
        let wasEmpty = draft.board.modules.isEmpty
        draft.board.modules.append(module.rawValue)
        if wasEmpty, draft.board.name == "未命名画板" { draft.board.name = module.title }
        expandedModule = module.rawValue
    }
    private func remove(_ module: CanvasModule) {
        draft.board.modules.removeAll { $0 == module.rawValue }; draft.board.fullWidthModules.removeAll { $0 == module.rawValue }
        if expandedModule == module.rawValue { expandedModule = modules.first?.rawValue }
    }
    private func nudge(_ module: Int, by delta: Int) {
        guard let index = draft.board.modules.firstIndex(of: module), draft.board.modules.indices.contains(index + delta) else { return }
        draft.board.modules.swapAt(index, index + delta)
    }
    private func move(_ source: Int, before target: Int) {
        draft.board.modules = ReadPicoBoardModuleOrder.moving(source, before: target, in: draft.board.modules)
    }
    private func chooseImage() {
        guard !manager.busy else { return }
        showWallpaperPicker = true
    }
    private func editBoardImage() {
        guard !manager.busy else { return }
        let asset = draft.wallpaperAssetID.flatMap { id in wallpaperLibrary.assets.first { $0.id == id } }
        let edit = draft.wallpaperEditData.flatMap { try? JSONDecoder().decode(PicoPhotoEdit.self, from: $0) }
        if let source = draft.imageSource {
            // Portable drafts remain editable even after the shared asset is removed or on another Mac.
            // 独立原稿优先，删除共享库来源或换一台 Mac 也能重新调整构图。
            photoRequest = BoardPhotoRequest(asset: asset, source: source, target: photoTarget, initial: edit)
        } else if let asset {
            guard let source = wallpaperLibrary.image(for: asset) else {
                manager.report(wallpaperLibrary.imageLoadFailed(for: asset) ? "原图无法读取，请重新从壁纸库选择。" : "原图正在准备，请稍后再打开构图。"); return
            }
            photoRequest = BoardPhotoRequest(asset: asset, source: source, target: photoTarget, initial: edit)
        } else if let image = draft.image {
            photoRequest = BoardPhotoRequest(asset: nil, source: image, target: photoTarget, initial: nil)
        }
    }
    @discardableResult private func loadImage(from url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 16 * 1024 * 1024 else {
                throw ReadPicoManagerError.invalid("请选择 16 MB 以内的本地图片文件。")
            }
            let data = try Data(contentsOf: url)
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192, width <= 16 * 1024 * 1024 / height,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ReadPicoManagerError.invalid("无法读取图片，或图片像素超过限制。") }
            let loaded = NSImage(size: NSSize(width: width, height: height))
            loaded.addRepresentation(NSBitmapImageRep(cgImage: image))
            draft.image = loaded
            if !manager.busy { manager.report("图片已更新，可以发送到设备。") }
            return true
        } catch { manager.report(error.localizedDescription, error: true); return false }
    }
    private func saveDraft() {
        let panel = NSSavePanel(); panel.title = "保存灵犀画板草稿"; panel.nameFieldStringValue = draft.board.name + ".picocanvas"
        panel.allowedContentTypes = [UTType(filenameExtension: "picocanvas") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try draft.save(to: url); manager.report("已保存可编辑画板草稿，图片与模块内容均已保留。") }
        catch { manager.report("画板草稿尚未保存。" + error.localizedDescription, error: true) }
    }
    private func saveCurrentBoard(in library: ReadPicoBoardLibrary) throws {
        if library.selectedID == nil {
            _ = try library.create(name: draft.board.name, from: draft, into: draft)
        } else { try library.saveCurrent(draft) }
    }
    private func openDraft() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "picocanvas") ?? .json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let candidate = ReadPicoCanvasDraft(); try candidate.load(from: url)
            drafts.request(.canvas, title: "打开另一块画板前保存修改？") {
                session.stop()
                do {
                    if let library = drafts.boardLibrary {
                        _ = try library.create(name: candidate.board.name, from: candidate, into: draft)
                    } else { draft.adoptValidatedDraft(candidate) }
                    if draft.canvasMode != 2 { activate() } else { session.edited() }
                } catch { manager.report(error.localizedDescription, error: true) }
            }
        } catch { manager.report("草稿无法打开，当前内容已保留。" + error.localizedDescription, error: true) }
    }
    private func exportBitmap() {
        guard let frame = session.frame else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.bmp]; panel.nameFieldStringValue = draft.board.name + ".bmp"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try frame.bitmap.write(to: url, options: .atomic); manager.report("已导出与设备预览一致的 16 灰阶画面。") }
        catch { manager.report(error.localizedDescription, error: true) }
    }
}

/// Uses the same per-device canvas documents for selection, management and automatic playback.
/// The library owns persistence; changing the active document always goes through its draft guard.
@MainActor private struct ReadPicoBoardLibraryControls: View {
    @ObservedObject var library: ReadPicoBoardLibrary
    @ObservedObject var drafts: ReadPicoDraftGuard
    @ObservedObject var session: ReadPicoLingxiBoardSession
    let compact: Bool
    let supportsCarousel: Bool
    @State private var draggedID: UUID?
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var removeID: UUID?
    @State private var showRemove = false

    private var blocked: Bool { drafts.model.busy || drafts.externalBusy || drafts.isHandlingDeparture }
    private var selection: Binding<UUID?> {
        Binding(get: { library.selectedID }, set: { id in
            guard let id, id != library.selectedID else { return }
            guarded("切换画板前保存修改？") { try library.select(id, into: drafts.canvas) }
        })
    }
    var body: some View {
        Group {
            if compact {
                HStack(spacing: 12) {
                    Picker("当前画板", selection: selection) {
                        if library.boards.isEmpty { Text("尚未保存的画板").tag(nil as UUID?) }
                        ForEach(library.boards) { board in Text(board.name).tag(Optional(board.id)) }
                    }.frame(maxWidth: 420)
                    Spacer(minLength: 4)
                    newButton
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("\(library.boards.count) 块画板").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        newButton
                    }
                    if supportsCarousel {
                        Toggle("自动轮换已保存画板", isOn: Binding(get: { library.carouselEnabled }, set: { enabled in
                            perform { try library.setCarouselEnabled(enabled); session.stop() }
                        }))
                        Text("开启后，再启用上方自动更新。至少选择两块画板；设备确认保存后开始计时。各画板内的独立模块会按顺序逐项轮播。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if library.boards.isEmpty {
                        Text("保存当前画板或新建第一块画板，之后可在这里切换。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(library.boards) { board in
                        boardRow(board)
                            .onDrag {
                                draggedID = board.id
                                return NSItemProvider(object: board.id.uuidString as NSString)
                            }
                            .onDrop(of: [.plainText], isTargeted: nil) { _ in
                                guard let source = draggedID, source != board.id else { return false }
                                draggedID = nil
                                move(source, before: board.id)
                                return true
                            }
                    }
                    Text("画板保存在这台 Pico 的 Mac 资料中。拖动可调整顺序；切换画板会保留当前未保存内容的处理选择。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .disabled(blocked)
        .alert("重命名画板", isPresented: $showRename) {
            TextField("画板名称", text: $renameText)
            Button("保存") { rename() }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) { renameID = nil }
        }
        .confirmationDialog("删除这块画板？", isPresented: $showRemove, titleVisibility: .visible) {
            Button("删除画板", role: .destructive) {
                guard let id = removeID else { return }
                guarded("删除画板前保存修改？") { try library.remove(id, into: drafts.canvas) }
                removeID = nil
            }
            Button("取消", role: .cancel) { removeID = nil }
        } message: {
            Text("会从这台 Pico 的 Mac 画板库中移除；设备当前显示的画面不会改变。")
        }
    }
    private var newButton: some View {
        Button("新建画板", systemImage: "plus") {
            guarded("新建画板前保存修改？") {
                let blank = ReadPicoCanvasDraft()
                blank.canvasMode = 2
                _ = try library.create(name: "新画板", from: blank, into: drafts.canvas)
            }
        }
    }
    private func boardRow(_ board: ReadPicoBoardLibrary.Board) -> some View {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.tertiary)
            Button {
                guard board.id != library.selectedID else { return }
                guarded("切换画板前保存修改？") { try library.select(board.id, into: drafts.canvas) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "rectangle.stack")
                    Text(board.name).lineLimit(1)
                    if board.id == library.selectedID { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if supportsCarousel {
                Toggle("参与轮播", isOn: Binding(get: { board.includedInCarousel }, set: { enabled in
                    perform { try library.setIncludedInCarousel(board.id, included: enabled) }
                })).toggleStyle(.checkbox).font(.caption)
            }
            Menu {
                Button("重命名…", systemImage: "pencil") {
                    renameID = board.id; renameText = board.name; showRename = true
                }
                Button("复制画板", systemImage: "plus.square.on.square") {
                    guarded("复制画板前保存修改？") { _ = try library.duplicate(board.id, into: drafts.canvas) }
                }
                Divider()
                Button("向上移动", systemImage: "chevron.up") { nudge(board.id, by: -1) }
                    .disabled(library.boards.first?.id == board.id)
                Button("向下移动", systemImage: "chevron.down") { nudge(board.id, by: 1) }
                    .disabled(library.boards.last?.id == board.id)
                Divider()
                Button("删除画板…", systemImage: "trash", role: .destructive) { removeID = board.id; showRemove = true }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().frame(minWidth: 28, minHeight: 28)
                .accessibilityLabel("\(board.name)的更多操作")
          }
          if supportsCarousel && board.includedInCarousel {
              Stepper("停留 \(board.durationSeconds) 秒", value: Binding(get: { board.durationSeconds }, set: { value in
                  perform { try library.setCarouselDuration(board.id, seconds: value) }
              }), in: 5...3600, step: 5)
                  .font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
          }
        }.padding(.vertical, 4)
    }
    private func guarded(_ title: String, operation: @escaping () throws -> Void) {
        drafts.request(.canvas, title: title) {
            session.stop()
            perform(operation)
        }
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch { drafts.model.report(error.localizedDescription, error: true) }
    }
    private func rename() {
        guard let id = renameID else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if id == library.selectedID {
            guarded("重命名画板前保存修改？") {
                try library.rename(id, to: name)
                drafts.canvas.adoptValidatedDraft(try library.loadBoard(id))
            }
        } else { perform { try library.rename(id, to: name) } }
        renameID = nil
    }
    private func nudge(_ id: UUID, by delta: Int) {
        var ids = library.boards.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + delta) else { return }
        ids.swapAt(index, index + delta)
        perform { try library.reorder(ids) }
    }
    private func move(_ source: UUID, before target: UUID) {
        var ids = library.boards.map(\.id)
        guard source != target, let sourceIndex = ids.firstIndex(of: source) else { return }
        ids.remove(at: sourceIndex)
        guard let targetIndex = ids.firstIndex(of: target) else { return }
        ids.insert(source, at: targetIndex)
        perform { try library.reorder(ids) }
    }
}
