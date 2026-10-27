import AppKit
import LinxDisplayCore

/// Reuses the Oracle canvas module engine while drawing vectors at the reader's native resolution.
/// 复用口袋先知模块引擎；在小纸原生像素上下文绘图，最终只量化一次为 16 级灰阶。
enum ReadPicoLingxiBoardRenderer {
    struct Result {
        let bitmap: Data
        let preview: NSImage
        let width: Int
        let height: Int
        let pairedBitmap: Data?
        let contentChannel: ReadPicoContentChannel
        var transferData: Data { pairedBitmap ?? bitmap }
        init(bitmap: Data, preview: NSImage, width: Int, height: Int, pairedBitmap: Data? = nil,
             contentChannel: ReadPicoContentChannel = .canvas) {
            self.bitmap = bitmap; self.preview = preview; self.width = width; self.height = height
            self.pairedBitmap = pairedBitmap; self.contentChannel = contentChannel
        }
    }
    @MainActor static func render(draft: ReadPicoCanvasDraft, model: AppModel,
                                   now: Date = Date(), deviceID: UUID? = nil,
                                   playlistItemID: UUID? = nil, readingInstance: String = "canvas") throws -> Result {
        if draft.canvasMode == 2, draft.playlist.mode == .carousel {
            return try renderPlaylistItem(draft: draft, model: model, itemID: playlistItemID,
                                          deviceID: deviceID, now: now)
        }
        // MainActor rendering is synchronous: both layouts share one sampled model and timestamp.
        // Resolve excerpt selection once so rotating cannot switch to a different note.
        let excerpt = draft.board.modules.contains(CanvasModule.readingExcerpt.rawValue)
            ? model.readingExcerptCard(for: deviceID, instance: readingInstance) : nil
        let portrait = try renderSingle(draft: orientedCopy(draft, landscape: false), model: model, now: now, excerpt: excerpt)
        let landscape = try renderSingle(draft: orientedCopy(draft, landscape: true), model: model, now: now, excerpt: excerpt)
        let selected = draft.landscape ? landscape : portrait
        return Result(bitmap: selected.bitmap, preview: selected.preview, width: selected.width, height: selected.height,
                      pairedBitmap: try ReadPicoCanvasPair.encode(portrait: portrait.bitmap, landscape: landscape.bitmap),
                      contentChannel: draft.canvasMode == 2 && draft.board.modules == [CanvasModule.cloudflare.rawValue] ? .cloudflare : .canvas)
    }
    @MainActor private static func orientedCopy(_ source: ReadPicoCanvasDraft, landscape: Bool) -> ReadPicoCanvasDraft {
        let copy = ReadPicoCanvasDraft()
        copy.landscape = landscape; copy.dither = source.dither; copy.canvasMode = source.canvasMode
        copy.image = source.image; copy.imageSource = source.imageSource
        copy.wallpaperAssetID = source.wallpaperAssetID; copy.wallpaperEditData = source.wallpaperEditData
        copy.strokes = source.strokes; copy.liveStroke = source.liveStroke
        copy.board = source.board; copy.playlist = source.playlist
        return copy
    }
    @MainActor private static func renderSingle(draft: ReadPicoCanvasDraft, model: AppModel,
                                                now: Date, excerpt: ReadPicoReadingCard?) throws -> Result {
        let board = draft.board
        try board.validate()
        let width = draft.landscape ? 1216 : 684, height = draft.landscape ? 684 : 1216
        if draft.canvasMode != 2 {
            let bitmap = try draft.bitmapGray16()
            guard let preview = NSImage(data: bitmap) else { throw ReadPicoManagerError.unavailable("无法生成 16 级灰阶预览。") }
            return Result(bitmap: bitmap, preview: preview, width: width, height: height)
        }
        var imageURL: URL?
        defer { if let imageURL { try? FileManager.default.removeItem(at: imageURL) } }
        if board.modules.contains(CanvasModule.image.rawValue), let data = try draft.boardImageData() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pico-board-\(UUID().uuidString).tiff")
            try data.write(to: url, options: .atomic); imageURL = url
        }
        let modules = board.modules.compactMap(CanvasModule.init(rawValue:))
        let palette = ScreenThemes.resolved(theme: model.settings.cardTheme,
                                           backgroundTone: board.darkBackground ? .dark : .light,
                                           customBackgroundHex: nil, accentTone: model.settings.accentTone,
                                           customAccentHex: model.settings.customAccentHex,
                                           softwareIsDark: board.darkBackground)
        let raw = ScreenRenderer.renderDeviceCanvas(
            modules: modules, system: model.system, nowPlaying: model.nowPlaying,
            pomodoro: model.pomodoroSnapshot, customText: board.text, settings: model.settings,
            codex: model.usage, qwenQuota: model.qwenQuota,
            sspaiArticles: Array(model.sspaiArticles.prefix(6)),
            ha: model.haSnapshot.selecting(entityIDs: board.entityIDs),
            formlabsItems: model.formlabsCanvasItems(), now: now,
            width: width, height: height, palette: palette, columns: board.columns,
            fullWidthModules: Set(board.fullWidthModules), nowPlayingHorizontal: board.nowPlayingHorizontal,
            canvasImagePath: imageURL?.path, printerFields: model.settings.canvasPrinterFields,
            optimizeBambuForOracleEInk: true, bambuHeroLayout: true, showBambuCamera: false,
            rasterScale: CGFloat(board.rasterScale),
            readingExcerpt: excerpt, nativeEInkLegibility: true)
        let bitmap = try ReadPicoBitmap.makeGray16(image: raw, width: width, height: height)
        guard let preview = NSImage(data: bitmap) else { throw ReadPicoManagerError.unavailable("无法生成 16 级灰阶预览。") }
        return Result(bitmap: bitmap, preview: preview, width: width, height: height)
    }

    /// Each playlist instance becomes one full-screen composition using the production renderer.
    /// This only renders pixels; advancing the playlist remains gated by the device's display receipt.
    @MainActor static func renderPlaylistItem(draft: ReadPicoCanvasDraft, model: AppModel,
                                              itemID: UUID? = nil, deviceID: UUID? = nil,
                                              now: Date = Date()) throws -> Result {
        try draft.playlist.validate()
        let item: ReadPicoBoardPlaylistItem
        if let itemID {
            guard let selected = draft.playlist.item(id: itemID), selected.enabled else {
                throw ReadPicoBoardPlaylistError.invalid("此轮播项已移除或停用，请重新选择。")
            }
            item = selected
        } else {
            guard let first = draft.playlist.enabledItems.first else {
                throw ReadPicoBoardPlaylistError.invalid("请至少添加并启用一个轮播项。")
            }
            item = first
        }
        let frame = ReadPicoCanvasDraft()
        frame.canvasMode = 2; frame.dither = draft.dither; frame.board = item.configurationForRendering
        let excerpt = item.module == CanvasModule.readingExcerpt.rawValue
            ? model.readingExcerptCard(for: deviceID, instance: item.id.uuidString) : nil
        let portraitDraft = orientedCopy(frame, landscape: false)
        let landscapeDraft = orientedCopy(frame, landscape: true)
        if item.module == CanvasModule.image.rawValue {
            // Apply the same editable source/crop to each target aspect ratio, never rotate an already cropped bitmap.
            portraitDraft.image = try ReadPicoBoardPlaylistImage.composed(for: item, landscape: false)
            landscapeDraft.image = try ReadPicoBoardPlaylistImage.composed(for: item, landscape: true)
        }
        let portrait = try renderSingle(draft: portraitDraft, model: model, now: now, excerpt: excerpt)
        let landscape = try renderSingle(draft: landscapeDraft, model: model, now: now, excerpt: excerpt)
        let selected = draft.landscape ? landscape : portrait
        return Result(bitmap: selected.bitmap, preview: selected.preview, width: selected.width, height: selected.height,
                      pairedBitmap: try ReadPicoCanvasPair.encode(portrait: portrait.bitmap, landscape: landscape.bitmap),
                      contentChannel: item.module == CanvasModule.cloudflare.rawValue ? .cloudflare : .canvas)
    }
}
