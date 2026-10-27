import AppKit
import Combine
import Foundation

private var checks = 0
@MainActor private func check(_ condition: @autoclosure () -> Bool, _ description: String) {
    checks += 1
    if !condition() { fatalError(description) }
}
private func expectFailure(_ description: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError(description) } catch { checks += 1 }
}
private func image() -> NSImage {
    let context = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
    return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 80, height: 40))
}
private func colorSource() -> NSImage {
    let context = CGContext(data: nil, width: 140, height: 60, bitsPerComponent: 8, bytesPerRow: 560,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 70, height: 60))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 70, y: 0, width: 70, height: 60))
    return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 140, height: 60))
}
private func png(_ image: NSImage) -> Data {
    NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!).representation(using: .png, properties: [:])!
}
private func color(_ image: NSImage, x: Int, y: Int) -> NSColor {
    NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!).colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
}
private func dimension(_ data: Data, offset: Int) -> Int {
    (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
}
private func bit(_ data: Data, x: Int, y: Int) -> Bool {
    let width = dimension(data, offset: 18), height = dimension(data, offset: 22)
    let stride = (width + 31) / 32 * 4
    return data[62 + (height - 1 - y) * stride + x / 8] & UInt8(0x80 >> (x % 8)) != 0
}

@main struct CanvasDraftTests {
    @MainActor static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("editable.picocanvas")
        let draft = ReadPicoCanvasDraft()
        check(!draft.hasUnsavedChanges, "blank starts clean")
        check(!draft.hasUnsavedLocalChanges, "blank local draft starts clean")
        draft.canvasMode = 1; draft.landscape = true; draft.dither = false
        check(!draft.hasUnsavedChanges, "empty display preferences and source navigation have no lost content")
        check(!draft.hasUnsavedLocalChanges, "empty source preferences are also locally clean")
        draft.image = image()
        draft.strokes = [[CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.9)], [CGPoint(x: 0.4, y: 0.6)]]
        draft.liveStroke = [CGPoint(x: 0.2, y: 0.3)]
        check(draft.hasUnsavedChanges, "both editable sources are tracked")
        try draft.save(to: file)
        check(!draft.hasUnsavedChanges, "local save confirms both sources")
        let savedData = try Data(contentsOf: file)
        let restored = ReadPicoCanvasDraft()
        try restored.load(from: file)
        check(restored.landscape && !restored.dither && restored.canvasMode == 1, "display choices survive reopen")
        check(restored.strokes == draft.strokes && restored.liveStroke == draft.liveStroke, "all normalized paths survive reopen")
        check(restored.image != nil && !restored.hasUnsavedChanges, "original image source survives reopen cleanly")
        restored.canvasMode = 0
        let bitmap = try restored.bitmap()
        check(dimension(bitmap, offset: 18) == 1216 && dimension(bitmap, offset: 22) == 684, "landscape bitmap uses device dimensions")
        check(bit(bitmap, x: 608, y: 5) && !bit(bitmap, x: 608, y: 342), "wide source stays aspect fit with white letterbox")
        restored.canvasMode = 1
        let drawingBitmap = try restored.bitmap()
        check(!drawingBitmap.isEmpty, "restored paths render without any source flattening")

        restored.strokes.append([CGPoint(x: 0.9, y: 0.1)])
        restored.image = image()
        let imagePush: ReadPicoCanvasDraft.PushSnapshot
        restored.canvasMode = 0; imagePush = try restored.makePushSnapshot()
        imagePush.acknowledge()
        check(restored.hasUnsavedChanges, "image acknowledgement leaves new drawing dirty")
        restored.canvasMode = 1
        let drawingPush = try restored.makePushSnapshot()
        drawingPush.acknowledge()
        check(!restored.hasUnsavedChanges, "confirming the remaining source clears dirty state")
        check(restored.hasUnsavedLocalChanges, "device acknowledgements never save image or drawing originals locally")
        restored.strokes.append([CGPoint(x: 0.5, y: 0.6)])
        let late = try restored.makePushSnapshot()
        restored.strokes.append([CGPoint(x: 0.6, y: 0.7)])
        late.acknowledge()
        check(restored.hasUnsavedChanges, "late acknowledgement never confirms more recent paths")
        let newer = try restored.makePushSnapshot()
        newer.acknowledge(); late.acknowledge()
        check(!restored.hasUnsavedChanges, "an older response cannot undo a newer acknowledgement")
        check(restored.hasUnsavedLocalChanges, "new and old display responses cannot confirm the editable local document")
        restored.canvasMode = 0
        let oldOptions = try restored.makePushSnapshot()
        restored.landscape.toggle()
        oldOptions.acknowledge()
        check(restored.hasUnsavedChanges, "late image response cannot confirm newer orientation options")
        restored.discardChanges()
        check(restored.strokes == draft.strokes && !restored.hasUnsavedChanges, "discard returns to local editable save, not pushed-only paths")
        check(!restored.hasUnsavedLocalChanges, "discard restores the local baseline independently of delivery")

        let lateBeforeLoad = try restored.makePushSnapshot()
        try restored.load(from: file)
        restored.strokes.append([CGPoint(x: 0.3, y: 0.4)])
        lateBeforeLoad.acknowledge()
        check(restored.hasUnsavedChanges, "old document acknowledgement cannot clear a reopened document")
        restored.discardChanges()
        restored.strokes = [[CGPoint(x: .nan, y: 0.5)]]
        expectFailure("invalid coordinate save must fail") { try restored.save(to: file) }
        let afterFailure = try Data(contentsOf: file)
        check(afterFailure == savedData, "failed save preserves previous file byte for byte")
        check(restored.hasUnsavedChanges && restored.strokes.first?.first?.x.isNaN == true, "failed save keeps pending input")
        check(restored.hasUnsavedLocalChanges, "failed local save preserves local dirty state")
        expectFailure("invalid conversion must fail") { _ = try restored.makePushSnapshot() }
        check(restored.hasUnsavedChanges, "conversion failure does not confirm a draft")
        restored.discardChanges()
        restored.strokes.append([CGPoint(x: 0.3, y: 0.8)])
        let before = restored.strokes, beforeImage = restored.image

        var document = try JSONSerialization.jsonObject(with: savedData) as! [String: Any]
        func reject(_ value: [String: Any], _ description: String) throws {
            let invalid = folder.appendingPathComponent("invalid.picocanvas")
            try JSONSerialization.data(withJSONObject: value).write(to: invalid)
            expectFailure(description) { try restored.load(from: invalid) }
            check(restored.strokes == before && restored.image === beforeImage && restored.hasUnsavedChanges,
                  description + " preserves current draft and baseline")
        }
        document["version"] = 99
        try reject(document, "unknown format version")
        document["version"] = 1; document["canvasMode"] = 9
        try reject(document, "invalid source selector")
        document["canvasMode"] = 1; document["strokes"] = [[["x": -0.1, "y": 0.5]]]
        try reject(document, "negative coordinate")
        document["strokes"] = [[["x": 1.1, "y": 0.5]]]
        try reject(document, "out of bounds coordinate")
        document["strokes"] = Array(repeating: [["x": 0.1, "y": 0.5]], count: 10_001)
        try reject(document, "excessive stroke count")
        document["strokes"] = Array(repeating: [[String: Double]](), count: 10_001)
        try reject(document, "excessive empty arrays rejected before creating stroke objects")
        document["strokes"] = [Array(repeating: ["x": 0.1, "y": 0.5], count: 20_001)]
        try reject(document, "excessive individual stroke")
        document["strokes"] = Array(repeating: Array(repeating: ["x": 0.1, "y": 0.5], count: 20_000), count: 11)
        try reject(document, "excessive total points")
        document = try JSONSerialization.jsonObject(with: savedData) as! [String: Any]
        var storedImage = document["image"] as! [String: Any]
        storedImage["width"] = 100_000
        document["image"] = storedImage
        try reject(document, "invalid stored dimensions")
        storedImage["width"] = 79
        document["image"] = storedImage
        try reject(document, "stored dimensions disagree with image metadata")
        storedImage["width"] = 80; storedImage["tiff"] = Data([0, 1, 2]).base64EncodedString()
        document["image"] = storedImage
        try reject(document, "invalid encoded image")
        let oversized = folder.appendingPathComponent("oversized.picocanvas")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 160 * 1024 * 1024 + 1); try handle.close()
        expectFailure("oversized input rejected before decode") { try restored.load(from: oversized) }
        check(restored.strokes == before && restored.hasUnsavedChanges, "oversized file does not replace pending input")
        expectFailure("unwritable destination should fail") { try restored.save(to: folder.appendingPathComponent("missing/subfolder/file.picocanvas")) }
        check(restored.strokes == before && restored.hasUnsavedChanges, "write failure keeps active draft")
        restored.discardChanges()
        check(restored.strokes == draft.strokes && !restored.hasUnsavedChanges, "every failed load/save leaves the original discard baseline intact")
        let blank = ReadPicoCanvasDraft()
        expectFailure("empty image push rejected") { _ = try blank.makePushSnapshot() }
        blank.canvasMode = 1
        expectFailure("empty drawing push rejected") { _ = try blank.makePushSnapshot() }
        check(!blank.hasUnsavedChanges, "failed empty conversion leaves baseline unchanged")

        // SwiftUI observes this publisher, including changes made only to private confirmation baselines.
        // 验证仅更新内部确认基线时也通知 SwiftUI，避免“有未保存内容”的提示停留在旧状态。
        let observed = ReadPicoCanvasDraft()
        observed.image = image()
        let observedPush = try observed.makePushSnapshot()
        var dirtyAtNotification: [Bool] = []
        let subscription = observed.objectWillChange.sink { dirtyAtNotification.append(observed.hasUnsavedChanges) }
        defer { subscription.cancel() }
        observedPush.acknowledge()
        check(dirtyAtNotification.contains(true) && !observed.hasUnsavedChanges,
              "push acknowledgement notifies before the private baseline makes the draft clean")
        observed.strokes = [[CGPoint(x: 0.25, y: 0.75)]]
        dirtyAtNotification.removeAll()
        try observed.save(to: folder.appendingPathComponent("observed.picocanvas"))
        check(dirtyAtNotification.contains(true) && !observed.hasUnsavedChanges,
              "local save emits a notification even though no published content changes")
        observed.strokes.append([CGPoint(x: 0.75, y: 0.25)])
        dirtyAtNotification.removeAll()
        observed.discardChanges()
        check(!dirtyAtNotification.isEmpty && !observed.hasUnsavedChanges,
              "discard refreshes observed dirty status after restoring local content")
        observed.strokes = [[CGPoint(x: 2, y: 0)]]
        dirtyAtNotification.removeAll()
        expectFailure("invalid save remains unconfirmed") { try observed.save(to: file) }
        check(dirtyAtNotification.isEmpty && observed.hasUnsavedChanges,
              "failed save sends no misleading confirmation notification")

        // Opening is a two-phase UI operation: decode a candidate before a save/discard decision.
        // 打开草稿先验证候选文件，确认放弃后只采用内存快照，避免坏文件导致旧输入先被清除。
        let incomingFile = folder.appendingPathComponent("incoming.picocanvas")
        try savedData.write(to: incomingFile)
        let incoming = ReadPicoCanvasDraft()
        try incoming.load(from: incomingFile)
        let active = ReadPicoCanvasDraft()
        try active.load(from: file)
        active.canvasMode = 1
        active.strokes.append([CGPoint(x: 0.55, y: 0.66)])
        let activeBeforeOpen = active.strokes
        let oldActivePush = try active.makePushSnapshot()
        try Data("broken document".utf8).write(to: incomingFile)
        let rejectedCandidate = ReadPicoCanvasDraft()
        expectFailure("bad candidate must fail before active draft is discarded") { try rejectedCandidate.load(from: incomingFile) }
        check(active.strokes == activeBeforeOpen && active.hasUnsavedChanges,
              "failed staging leaves the original unsaved draft intact")
        incoming.strokes.append([CGPoint(x: 0.01, y: 0.01)])
        active.adoptValidatedDraft(incoming)
        check(active.strokes == draft.strokes && active.liveStroke == draft.liveStroke && active.image != nil,
              "adoption uses the complete validated baseline even after the file or candidate edits change")
        check(active.landscape == draft.landscape && active.dither == draft.dither && !active.hasUnsavedChanges,
              "adoption restores saved display options and both clean source baselines")
        active.strokes = activeBeforeOpen
        oldActivePush.acknowledge()
        check(active.hasUnsavedChanges, "adopting a document invalidates tickets from the replaced document")
        active.discardChanges()
        check(active.strokes == draft.strokes && !active.hasUnsavedChanges,
              "discard after adoption returns to the newly adopted local baseline")
        // The Lingxi board remains an editable source alongside old image/drawing documents.
        // 灵犀模块草稿不扁平化；版本迁移和异步推送回执保留独立编辑状态。
        let boardDraft = ReadPicoCanvasDraft()
        var initialBoard = ReadPicoLingxiBoardConfiguration()
        initialBoard.modules = [0, 1]; initialBoard.intervalSeconds = 300
        boardDraft.initializeBoardIfNeeded(initialBoard, landscape: false)
        check(boardDraft.canvasMode == 2 && !boardDraft.hasUnsavedChanges, "initial source migration is clean")
        boardDraft.board.name = "阅读桌面"
        boardDraft.board.modules = [0, 1, 8, 9, 16]
        boardDraft.board.text = "你好，灵犀画板"
        boardDraft.board.columns = 2; boardDraft.board.fullWidthModules = [9]
        boardDraft.board.entityIDs = ["sensor.room_temperature"]
        boardDraft.image = image()
        check(boardDraft.hasUnsavedChanges, "module edits and original image are tracked")
        let boardFile = folder.appendingPathComponent("board.picocanvas")
        try boardDraft.save(to: boardFile)
        let boardJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: boardFile)) as! [String: Any]
        check(boardJSON["version"] as? Int == 2, "new boards use editable version 2")
        let reopenedBoard = ReadPicoCanvasDraft(); try reopenedBoard.load(from: boardFile)
        check(reopenedBoard.board == boardDraft.board && reopenedBoard.image != nil && !reopenedBoard.hasUnsavedChanges,
              "module layout, text, source image, interval and entities survive reopening")
        reopenedBoard.board.text = "推送中的旧内容"
        let boardPush = try reopenedBoard.makeBoardPushSnapshot(bitmap: Data([1, 2, 3]))
        reopenedBoard.board.text = "推送之后的新内容"
        boardPush.acknowledge()
        check(reopenedBoard.hasUnsavedChanges, "display acknowledgement cannot confirm newer module text")
        let newBoardPush = try reopenedBoard.makeBoardPushSnapshot(bitmap: Data([4, 5, 6]))
        newBoardPush.acknowledge(); boardPush.acknowledge()
        check(!reopenedBoard.hasUnsavedChanges, "older module acknowledgement cannot undo a newer one")
        check(reopenedBoard.hasUnsavedLocalChanges, "displayed board text still requires a local save")
        try reopenedBoard.save(to: boardFile)
        check(!reopenedBoard.hasUnsavedLocalChanges, "only a successful local save confirms editable board changes")
        let locallyReopened = ReadPicoCanvasDraft(); try locallyReopened.load(from: boardFile)
        check(locallyReopened.board.text == "推送之后的新内容" && !locallyReopened.hasUnsavedLocalChanges,
              "saved displayed changes survive reopening the editable local board")
        reopenedBoard.board.text = "本地保存后的临时修改"
        reopenedBoard.discardChanges()
        check(reopenedBoard.board == locallyReopened.board, "discard restores the most recently saved editable local module configuration")
        reopenedBoard.canvasMode = 0
        let grayscale = try reopenedBoard.bitmapGray16()
        check(grayscale[28] == 4 && dimension(grayscale, offset: 10) == 118 && grayscale.count == 418422,
              "image source uses native 4-bit 16-gray BMP and padded portrait rows")
        reopenedBoard.canvasMode = 1; reopenedBoard.strokes = [[CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)]]
        let grayscaleDrawing = try reopenedBoard.makePushSnapshot(nativeGray16: true)
        check(grayscaleDrawing.data[28] == 4, "existing editable drawing can push native grayscale")
        reopenedBoard.canvasMode = 2
        reopenedBoard.board.text = "保留当前未保存文字"
        var badBoardJSON = boardJSON
        var invalidBoard = badBoardJSON["board"] as! [String: Any]
        invalidBoard["modules"] = [0, 0]
        badBoardJSON["board"] = invalidBoard
        let badBoardFile = folder.appendingPathComponent("invalid-board.picocanvas")
        try JSONSerialization.data(withJSONObject: badBoardJSON).write(to: badBoardFile)
        expectFailure("duplicate modules are rejected") { try reopenedBoard.load(from: badBoardFile) }
        check(reopenedBoard.board.text == "保留当前未保存文字" && reopenedBoard.hasUnsavedChanges,
              "bad module file never discards active edits")
        invalidBoard["modules"] = [0]; invalidBoard["rasterScale"] = 1000; badBoardJSON["board"] = invalidBoard
        try JSONSerialization.data(withJSONObject: badBoardJSON).write(to: badBoardFile)
        expectFailure("unbounded rendering scale is rejected") { try reopenedBoard.load(from: badBoardFile) }
        reopenedBoard.board = initialBoard
        let inFlightBoard = try reopenedBoard.makeBoardPushSnapshot(bitmap: Data([9]))
        try reopenedBoard.load(from: boardFile)
        reopenedBoard.board.text = "载入后编辑"
        inFlightBoard.acknowledge()
        check(reopenedBoard.hasUnsavedChanges, "load invalidates module tickets from the replaced document")
        let oldSource = ReadPicoCanvasDraft(); try oldSource.load(from: file)
        check(oldSource.canvasMode == 1 && oldSource.strokes == draft.strokes && oldSource.board.modules.isEmpty,
              "legacy version 1 images and drawing remain editable without new module defaults")
        let wallpaperDraft = ReadPicoCanvasDraft()
        wallpaperDraft.image = image()
        let wallpaperID = UUID(), parameters = Data("{\"scale\":1.5}".utf8)
        wallpaperDraft.wallpaperAssetID = wallpaperID; wallpaperDraft.wallpaperEditData = parameters
        let wallpaperFile = folder.appendingPathComponent("wallpaper.picocanvas")
        try wallpaperDraft.save(to: wallpaperFile)
        let wallpaperReload = ReadPicoCanvasDraft(); try wallpaperReload.load(from: wallpaperFile)
        check(wallpaperReload.wallpaperAssetID == wallpaperID && wallpaperReload.wallpaperEditData == parameters,
              "shared original reference and image composition survive local draft reopen")
        check(!wallpaperReload.hasUnsavedChanges, "restored wallpaper composition starts clean")
        wallpaperReload.wallpaperEditData = Data("changed".utf8)
        check(wallpaperReload.hasUnsavedChanges, "composition changes participate in draft departure protection")
        wallpaperReload.discardChanges()
        check(wallpaperReload.wallpaperEditData == parameters && !wallpaperReload.hasUnsavedChanges,
              "discard restores original reference and composition together")
        wallpaperReload.image = image()
        check(wallpaperReload.wallpaperAssetID == nil && wallpaperReload.wallpaperEditData == nil,
              "replacing an image never reuses another original's composition")
        wallpaperReload.wallpaperEditData = Data(repeating: 0, count: 16_385)
        expectFailure("oversized composition is rejected before overwriting a saved draft") { try wallpaperReload.save(to: wallpaperFile) }
        let preservedWallpaper = ReadPicoCanvasDraft(); try preservedWallpaper.load(from: wallpaperFile)
        check(preservedWallpaper.wallpaperAssetID == wallpaperID, "failed composition save preserves previous original reference")

        // The screen image is derived; an RGB original and its edges survive independently of the library.
        let portable = ReadPicoCanvasDraft(), original = colorSource()
        let firstEdit = Data("{\"scale\":2,\"panX\":0.4}".utf8)
        portable.applyWallpaper(source: original, rendered: image(), assetID: wallpaperID, editData: firstEdit)
        let portableFile = folder.appendingPathComponent("portable.picocanvas")
        try portable.save(to: portableFile)
        let portableData = try Data(contentsOf: portableFile)
        var portableJSON = try JSONSerialization.jsonObject(with: portableData) as! [String: Any]
        check(portableJSON["version"] as? Int == 3, "portable sources use version 3")
        let portableReload = ReadPicoCanvasDraft(); try portableReload.load(from: portableFile)
        check(portableReload.image?.size == NSSize(width: 80, height: 40) && portableReload.imageSource?.size == NSSize(width: 140, height: 60),
              "reopen preserves separate original and derived dimensions without any library")
        let left = color(portableReload.imageSource!, x: 2, y: 20), right = color(portableReload.imageSource!, x: 137, y: 20)
        check(left.redComponent > 0.99 && left.blueComponent < 0.01 && right.blueComponent > 0.99,
              "lossless original retains RGB and both edges outside the rendered crop")
        check(portableReload.wallpaperEditData == firstEdit && !portableReload.hasUnsavedChanges,
              "portable crop and original reopen as one clean document")
        let retainedSource = portableReload.imageSource!
        portableReload.applyWallpaper(source: retainedSource, rendered: image(), assetID: wallpaperID, editData: Data("{\"scale\":1}".utf8))
        let originalPush = try portableReload.makePushSnapshot()
        portableReload.imageSource = colorSource(); portableReload.wallpaperEditData = Data("{\"scale\":3}".utf8)
        originalPush.acknowledge()
        check(portableReload.hasUnsavedChanges, "late receipt never confirms a newer original or crop")
        portableReload.discardChanges()
        check(portableReload.imageSource?.size == original.size && portableReload.wallpaperEditData == firstEdit && !portableReload.hasUnsavedChanges,
              "discard restores original RGB source and crop together")
        let preservedSource = portableReload.imageSource
        portableReload.wallpaperEditData = Data("pending crop".utf8)
        var invalidOriginal = portableJSON["imageSource"] as! [String: Any]
        invalidOriginal["tiff"] = Data([0, 1, 2]).base64EncodedString()
        portableJSON["imageSource"] = invalidOriginal
        let invalidSourceFile = folder.appendingPathComponent("invalid-source.picocanvas")
        try JSONSerialization.data(withJSONObject: portableJSON).write(to: invalidSourceFile)
        expectFailure("corrupt RGB source is rejected before replacing the active document") { try portableReload.load(from: invalidSourceFile) }
        check(portableReload.imageSource === preservedSource && portableReload.wallpaperEditData == Data("pending crop".utf8) && portableReload.hasUnsavedChanges,
              "corrupt source load preserves current editable source and pending crop")
        portableReload.imageSource = NSImage(size: NSSize(width: 100_000, height: 1))
        expectFailure("invalid original cannot overwrite a valid portable draft") { try portableReload.save(to: portableFile) }
        let afterSourceSaveFailure = try Data(contentsOf: portableFile)
        check(afterSourceSaveFailure == portableData, "source save failure preserves prior draft byte for byte")
        portableReload.discardChanges()
        let adoptPortable = ReadPicoCanvasDraft(); adoptPortable.adoptValidatedDraft(portableReload)
        check(adoptPortable.imageSource?.size == original.size && adoptPortable.wallpaperEditData == firstEdit && !adoptPortable.hasUnsavedChanges,
              "adopting a validated portable draft carries its independent original and crop")
        portableReload.image = image()
        check(portableReload.imageSource == nil && portableReload.wallpaperEditData == nil && portableReload.wallpaperAssetID == nil,
              "normal replacement clears the previous RGB original and composition")

        // A normal high-resolution source exceeds the old TIFF budget, but its lossless PNG is portable.
        let largeContext = CGContext(data: nil, width: 2200, height: 2000, bitsPerComponent: 8, bytesPerRow: 8800,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        largeContext.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        largeContext.fill(CGRect(x: 0, y: 0, width: 2200, height: 2000))
        let largeSource = NSImage(cgImage: largeContext.makeImage()!, size: NSSize(width: 2200, height: 2000))
        check(largeSource.tiffRepresentation!.count > 16 * 1024 * 1024, "high-resolution fixture exceeds the legacy TIFF image limit")
        let largeDraft = ReadPicoCanvasDraft()
        largeDraft.applyWallpaper(source: largeSource, rendered: image(), assetID: nil, editData: firstEdit)
        let largeFile = folder.appendingPathComponent("large-original.picocanvas")
        try largeDraft.save(to: largeFile)
        let largeReload = ReadPicoCanvasDraft(); try largeReload.load(from: largeFile)
        check(largeReload.imageSource?.size == largeSource.size && !largeReload.hasUnsavedChanges,
              "lossless source storage preserves normal high-resolution originals beyond the old TIFF budget")

        // Repeated module types are independent instances, not one shared module-ID setting.
        let sequence = ReadPicoCanvasDraft(); sequence.canvasMode = 2; sequence.board.modules = [9]
        sequence.playlist.mode = .carousel
        let instanceA = sequence.playlist.add(module: 9, name: "图片 A")!, instanceB = sequence.playlist.add(module: 9, name: "图片 B")!
        sequence.playlist.items[0].imageAssetID = wallpaperID
        sequence.playlist.items[0].imageSourcePNG = png(original)
        sequence.playlist.items[0].imageEditData = firstEdit
        sequence.playlist.items[1].imageSourcePNG = png(image())
        sequence.playlist.items[1].imageEditData = Data("{\"scale\":1}".utf8)
        sequence.playlist.items[1].enabled = false; sequence.playlist.items[1].durationSeconds = 90
        let sequenceFile = folder.appendingPathComponent("sequence.picocanvas")
        try sequence.save(to: sequenceFile)
        let sequenceReload = ReadPicoCanvasDraft(); try sequenceReload.load(from: sequenceFile)
        check(sequenceReload.playlist == sequence.playlist && sequenceReload.playlist.items[0].id == instanceA && sequenceReload.playlist.items[1].id == instanceB,
              "duplicate-type instances retain identities, enabled state, time and independent original/crop")
        check(!sequenceReload.hasUnsavedChanges, "saved playlist reopens clean")
        sequenceReload.playlist.items[0].imageEditData = Data("new crop".utf8)
        check(sequenceReload.playlist.items[1].imageEditData == sequence.playlist.items[1].imageEditData && sequenceReload.hasUnsavedChanges,
              "editing one instance cannot change another same-type instance")
        var copiedPlaylist = sequenceReload.playlist
        copiedPlaylist.items[0].durationSeconds = 123
        check(sequenceReload.playlist.items[0].durationSeconds != copiedPlaylist.items[0].durationSeconds,
              "playlist snapshots use independent value state")
        sequenceReload.discardChanges()
        sequenceReload.board.text = "未发送的组合内容"
        sequenceReload.playlist.items[1].durationSeconds = 120
        let oneFrame = try sequenceReload.makeBoardPushSnapshot(bitmap: Data([1, 2, 3]))
        oneFrame.acknowledge()
        check(sequenceReload.hasUnsavedChanges, "one carousel receipt cannot confirm an unsent item or composition")
        sequenceReload.discardChanges()
        check(sequenceReload.playlist == sequence.playlist && !sequenceReload.hasUnsavedChanges, "discard restores full playlist and source baselines")
        sequenceReload.playlist.items[0].imageSourcePNG = Data([0, 1, 2])
        expectFailure("corrupt embedded playlist original cannot be saved") { try sequenceReload.save(to: sequenceFile) }
        let badSequenceData = try JSONEncoder().encode(sequenceReload.playlist)
        var sequenceJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: sequenceFile)) as! [String: Any]
        sequenceJSON["playlist"] = try JSONSerialization.jsonObject(with: badSequenceData)
        let invalidSequenceFile = folder.appendingPathComponent("invalid-sequence.picocanvas")
        try JSONSerialization.data(withJSONObject: sequenceJSON).write(to: invalidSequenceFile)
        let beforeBadPlaylist = sequenceReload.playlist
        expectFailure("corrupt embedded playlist original cannot replace an active draft") { try sequenceReload.load(from: invalidSequenceFile) }
        check(sequenceReload.playlist == beforeBadPlaylist && sequenceReload.hasUnsavedChanges, "failed playlist decode preserves unsaved active values")
        sequenceReload.discardChanges()
        check(sequenceReload.playlist == sequence.playlist, "failed playlist load preserves the last saved discard baseline")
        var excerpt = ReadPicoLingxiBoardConfiguration(); excerpt.modules = [28]
        try excerpt.validate()
        check(true, "reading excerpt uses the actual CanvasModule capability list")
        print("ReadPico canvas draft: \(checks) checks passed")
    }
}
