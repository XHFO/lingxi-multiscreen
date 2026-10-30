import AppKit
import LinxDisplayCore

/// Information cards share the firmware parser and layout; images and drawings retain full-resolution pixels.
/// 信息卡片共用固件原生排版；纯图片与手绘保留原始分辨率及 16 灰阶。
enum ReadPicoLingxiBoardRenderer {
    struct Result {
        let bitmap: Data
        let preview: NSImage
        let width: Int
        let height: Int
        let pairedBitmap: Data?
        let contentChannel: ReadPicoContentChannel
        let modelData: Data?
        let comparisonData: Data
        var transferData: Data { modelData ?? pairedBitmap ?? bitmap }
        init(bitmap: Data, preview: NSImage, width: Int, height: Int, pairedBitmap: Data? = nil,
             contentChannel: ReadPicoContentChannel = .canvas, modelData: Data? = nil, comparisonData: Data? = nil) {
            self.bitmap = bitmap; self.preview = preview; self.width = width; self.height = height
            self.pairedBitmap = pairedBitmap; self.contentChannel = contentChannel
            self.modelData = modelData; self.comparisonData = comparisonData ?? modelData ?? pairedBitmap ?? bitmap
        }
    }
    /// The sending path never renders a full-screen image for information modules.
    @MainActor static func transfer(draft: ReadPicoCanvasDraft, model: AppModel, now: Date = Date(),
                                    deviceID: UUID? = nil, playlistItemID: UUID? = nil,
                                    readingInstance: String = "canvas") throws -> Result {
        guard draft.canvasMode == 2 else { return try render(draft: draft, model: model, now: now, deviceID: deviceID) }
        var board = draft.board
        let artwork = draft.image
        var selectedItem: ReadPicoBoardPlaylistItem?
        var identity = deviceID?.uuidString ?? "pico-board", instance = readingInstance
        if draft.playlist.mode == .carousel {
            try draft.playlist.validate()
            let item = playlistItemID.map { draft.playlist.item(id: $0) } ?? draft.playlist.enabledItems.first
            guard let item, item.enabled else { throw ReadPicoManagerError.invalid("请至少启用一个轮播模块。") }
            selectedItem = item
            board = item.configurationForRendering; identity = item.id.uuidString; instance = identity
        }
        if board.modules == [CanvasModule.image.rawValue] {
            let portraitDraft = orientedCopy(draft, landscape: false), landscapeDraft = orientedCopy(draft, landscape: true)
            portraitDraft.canvasMode = 0; landscapeDraft.canvasMode = 0
            if let selectedItem {
                portraitDraft.image = try ReadPicoBoardPlaylistImage.composed(for: selectedItem, landscape: false)
                landscapeDraft.image = try ReadPicoBoardPlaylistImage.composed(for: selectedItem, landscape: true)
            }
            let portrait = try renderImage(draft: portraitDraft)
            let landscape = try renderImage(draft: landscapeDraft)
            let selected = draft.landscape ? landscape : portrait
            return .init(bitmap: selected.bitmap, preview: selected.preview, width: selected.width, height: selected.height,
                         pairedBitmap: try ReadPicoCanvasPair.encode(portrait: portrait.bitmap, landscape: landscape.bitmap))
        }
        let excerpt = board.modules.contains(CanvasModule.readingExcerpt.rawValue)
            ? model.readingExcerptCard(for: deviceID, instance: instance) : nil
        let content = try ReadPicoBoardModelBuilder.build(board: board, image: artwork, model: model,
            now: now, boardID: identity, excerpt: excerpt)
        return Result(bitmap: Data(), preview: NSImage(), width: draft.landscape ? 1216 : 684,
            height: draft.landscape ? 684 : 1216,
            contentChannel: board.modules == [CanvasModule.cloudflare.rawValue] ? .cloudflare : .canvas,
            modelData: try content.encoded(), comparisonData: try content.semanticData())
    }
    @MainActor static func render(draft: ReadPicoCanvasDraft, model: AppModel,
                                   now: Date = Date(), deviceID: UUID? = nil,
                                   playlistItemID: UUID? = nil, readingInstance: String = "canvas") throws -> Result {
        if draft.canvasMode == 2 {
            return try nativePreview(transfer(draft: draft, model: model, now: now, deviceID: deviceID,
                playlistItemID: playlistItemID, readingInstance: readingInstance), landscape: draft.landscape, now: now)
        }
        let portrait = try renderImage(draft: orientedCopy(draft, landscape: false))
        let landscape = try renderImage(draft: orientedCopy(draft, landscape: true))
        let selected = draft.landscape ? landscape : portrait
        return Result(bitmap: selected.bitmap, preview: selected.preview, width: selected.width, height: selected.height,
                      pairedBitmap: try ReadPicoCanvasPair.encode(portrait: portrait.bitmap, landscape: landscape.bitmap))
    }
    static func nativePreview(_ result: Result, landscape: Bool, now: Date) throws -> Result {
        guard let data = result.modelData else { return result }
        let image = try ReadPicoNativeBoardRenderer.render(data, landscape: landscape, now: now)
        let bitmap = try ReadPicoBitmap.makeGray16(image: image, width: image.width, height: image.height)
        return Result(bitmap: bitmap, preview: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
                      width: image.width, height: image.height, contentChannel: result.contentChannel,
                      modelData: data, comparisonData: result.comparisonData)
    }
    @MainActor private static func orientedCopy(_ source: ReadPicoCanvasDraft, landscape: Bool) -> ReadPicoCanvasDraft {
        let copy = ReadPicoCanvasDraft()
        copy.landscape = landscape; copy.dither = source.dither; copy.canvasMode = source.canvasMode
        copy.image = source.image; copy.imageSource = source.imageSource
        copy.wallpaperAssetID = source.wallpaperAssetID; copy.wallpaperEditData = source.wallpaperEditData
        copy.strokes = source.strokes; copy.liveStroke = source.liveStroke
        copy.board = source.board; copy.playlist = source.playlist
        if let original = source.imageSource, let editData = source.wallpaperEditData,
           let edit = try? JSONDecoder().decode(PicoPhotoEdit.self, from: editData), edit.version == 1 {
            let composed = PicoPhotoRenderer.composeColor(image: original, edit: edit.normalized(),
                target: landscape ? .picoLandscape : .pico)
            copy.applyWallpaper(source: original, rendered: composed, assetID: source.wallpaperAssetID, editData: editData)
        }
        return copy
    }
    @MainActor private static func renderImage(draft: ReadPicoCanvasDraft) throws -> Result {
        let width = draft.landscape ? 1216 : 684, height = draft.landscape ? 684 : 1216
        let bitmap = try draft.bitmapGray16()
        guard let preview = NSImage(data: bitmap) else { throw ReadPicoManagerError.unavailable("无法生成 16 级灰阶预览。") }
        return Result(bitmap: bitmap, preview: preview, width: width, height: height)
    }

    /// The preview uses the exact model and firmware layout for the selected carousel item.
    @MainActor static func renderPlaylistItem(draft: ReadPicoCanvasDraft, model: AppModel,
                                              itemID: UUID? = nil, deviceID: UUID? = nil,
                                              now: Date = Date()) throws -> Result {
        try nativePreview(transfer(draft: draft, model: model, now: now, deviceID: deviceID, playlistItemID: itemID),
                          landscape: draft.landscape, now: now)
    }
}
