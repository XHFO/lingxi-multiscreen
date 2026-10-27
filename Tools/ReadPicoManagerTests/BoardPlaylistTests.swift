import AppKit
import Foundation
import ImageIO
import LinxDisplayCore

@main struct BoardPlaylistTests {
    @MainActor static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1; precondition(value(), message)
        }
        func reject(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(message) } catch { count += 1 }
        }
        var playlist = ReadPicoBoardPlaylist(); playlist.mode = .carousel
        let first = playlist.add(module: 8, name: "第一段文字")!
        let second = playlist.add(module: 8, name: "第二段文字")!
        playlist.items[0].configuration.text = "独立内容 A"
        playlist.items[1].configuration.text = "独立内容 B"
        playlist.items[0].durationSeconds = 10; playlist.items[1].durationSeconds = 30
        try playlist.validate()
        check(first != second && playlist.items.map(\.module) == [8, 8], "same module types have independent instance identities")
        let decoded = try JSONDecoder().decode(ReadPicoBoardPlaylist.self, from: JSONEncoder().encode(playlist))
        check(decoded == playlist && decoded.items[1].configuration.text == "独立内容 B", "all independent data survives Codable")
        let copy = playlist.duplicate(first)!
        playlist.items[1].configuration.text = "副本的新内容"
        check(playlist.items[0].configuration.text == "独立内容 A" && playlist.items[1].id == copy, "duplicating has no shared mutable text state")
        playlist.move(second, by: -1)
        check(playlist.items.map(\.id) == [first, second, copy], "instances reorder independently")
        playlist.items[1].enabled = false
        check(playlist.item(after: nil)?.id == first && playlist.item(after: first)?.id == copy && playlist.item(after: copy)?.id == first,
              "start, skip disabled and wrap preserve order")
        playlist.remove(copy)
        check(playlist.items.map(\.id) == [first, second], "remove targets only the selected instance")
        playlist.items[0].enabled = false
        check(playlist.item(after: nil) == nil, "all-disabled playlist yields no item")
        playlist.items[0].enabled = true; playlist.items[1].enabled = true

        let cloudflareModule = CanvasModule.cloudflare.rawValue
        check(cloudflareModule == 29 && ReadPicoBoardPlaylistItem.supports(cloudflareModule),
              "Cloudflare uses the real module catalog rather than an outdated numeric bound")
        check(ReadPicoBoardPlaylistItem.supports(CanvasModule.oracleText.rawValue),
              "existing oracle text support is preserved")
        check(!ReadPicoBoardPlaylistItem.supports(CanvasModule.excerptText.rawValue) &&
              !ReadPicoBoardPlaylistItem.supports(999), "only supported catalog modules may be selected")
        var cloudflarePlaylist = ReadPicoBoardPlaylist()
        let cloudflareID = cloudflarePlaylist.add(module: cloudflareModule, name: "Cloudflare 网站统计")
        check(cloudflareID != nil && cloudflarePlaylist.items.first?.module == cloudflareModule,
              "Cloudflare may be added as a full-screen carousel instance")
        try cloudflarePlaylist.items[0].validate()
        try cloudflarePlaylist.validate()
        check(cloudflarePlaylist.add(module: 999, name: "Unknown") == nil &&
              cloudflarePlaylist.add(module: CanvasModule.excerptText.rawValue, name: "Excerpt") == nil,
              "add still rejects unknown modules and the excluded excerpt module")
        let cloudflareDecoded = try JSONDecoder().decode(ReadPicoBoardPlaylist.self,
            from: JSONEncoder().encode(cloudflarePlaylist))
        try cloudflareDecoded.validate()
        check(cloudflareDecoded == cloudflarePlaylist && cloudflareDecoded.items[0].id == cloudflareID,
              "Cloudflare identity and rendering configuration survive Codable and actual validation")
        var cloudflareComposition = ReadPicoLingxiBoardConfiguration()
        cloudflareComposition.modules = [CanvasModule.oracleText.rawValue, cloudflareModule,
                                         CanvasModule.excerptText.rawValue, 999]
        let separated = ReadPicoBoardPlaylist.fromComposition(cloudflareComposition)
        try separated.validate()
        check(separated.mode == .carousel && separated.items.map(\.module) == [12, cloudflareModule] &&
              separated.items[1].configuration.modules == [cloudflareModule],
              "splitting a composition retains Cloudflare and oracle text while filtering unsupported modules")

        var invalid = playlist
        invalid.items[1].id = first
        reject("duplicate UUID must fail") { try invalid.validate() }
        invalid = playlist; invalid.items[0].durationSeconds = 0
        reject("zero dwell must fail") { try invalid.validate() }
        invalid.items[0].durationSeconds = 3601
        reject("excessive dwell must fail") { try invalid.validate() }
        invalid = playlist; invalid.items[0].name = " "
        reject("blank name must fail") { try invalid.validate() }
        invalid = playlist; invalid.items[0].module = 13
        reject("unsupported device-specific quote module must fail") { try invalid.validate() }
        invalid = playlist; invalid.items[0].module = 999
        reject("unknown module must fail") { try invalid.validate() }
        invalid = playlist; invalid.items[0].configuration.modules = [0]
        reject("module configuration mismatch must fail") { try invalid.validate() }
        invalid = playlist; invalid.items[0].imageEditData = Data(repeating: 0, count: 16_385)
        reject("excessive edit parameters must fail") { try invalid.validate() }
        invalid = playlist
        invalid.items[0].imageSourcePNG = Data(repeating: 0, count: ReadPicoBoardPlaylist.maximumEmbeddedBytes)
        invalid.items[1].imageSourcePNG = Data([0])
        reject("total portable source bound must fail") { try invalid.validate() }
        check(invalid.duplicate(first) == nil, "duplicate cannot exceed total image source bound")
        invalid = playlist
        invalid.items = (0..<33).map { ReadPicoBoardPlaylistItem(module: 0, name: "\($0)") }
        reject("too many instances must fail") { try invalid.validate() }

        let start = Date(timeIntervalSince1970: 1_000)
        var cursor = ReadPicoBoardCarouselCursor()
        check(cursor.candidate(in: playlist, now: start)?.id == first && cursor.displayedID == nil && cursor.due == nil,
              "candidate does not advance or start a timer before display receipt")
        check(cursor.candidate(in: playlist, now: start.addingTimeInterval(100))?.id == first,
              "failed or unconfirmed send retries the same candidate")
        cursor.confirm(playlist.items[0], minimumInterval: 1, now: start)
        check(cursor.displayedID == first && cursor.due == start.addingTimeInterval(10), "receipt starts the exact item dwell")
        check(cursor.candidate(in: playlist, now: start.addingTimeInterval(9))?.id == first, "remain on current until due")
        cursor.confirm(playlist.items[0], minimumInterval: 1, now: start.addingTimeInterval(4))
        check(cursor.due == start.addingTimeInterval(10), "dynamic refresh of current item does not reset dwell")
        check(cursor.candidate(in: playlist, now: start.addingTimeInterval(10))?.id == second, "next candidate appears when due")
        check(cursor.displayedID == first, "unconfirmed next candidate leaves confirmed cursor unchanged")
        cursor.confirm(playlist.items[1], minimumInterval: 60, now: start.addingTimeInterval(12))
        check(cursor.due == start.addingTimeInterval(72), "battery minimum interval applies from actual receipt")
        playlist.items[1].enabled = false
        check(cursor.candidate(in: playlist, now: start.addingTimeInterval(13))?.id == first, "disabling displayed item advances to an enabled instance")
        cursor.confirm(playlist.items[0], minimumInterval: 1, now: start.addingTimeInterval(14))
        check(cursor.candidate(in: playlist, now: start.addingTimeInterval(24))?.id == first, "single enabled item loops")
        cursor.confirm(playlist.items[0], minimumInterval: 1, now: start.addingTimeInterval(24))
        check(cursor.due == start.addingTimeInterval(34), "single item next receipt starts a fresh dwell")
        cursor.reset()
        check(cursor.displayedID == nil && cursor.due == nil, "reset removes playback state")

        func colorImage(width: Int, height: Int) -> NSImage {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.85, green: 0.25, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
        }
        let image = colorImage(width: 3000, height: 1500)
        var imageItem = ReadPicoBoardPlaylistItem(module: 9, name: "图片 A")
        imageItem.imageSourcePNG = try ReadPicoBoardPlaylistImage.portableSource(image)
        imageItem.imageEditData = try JSONEncoder().encode(PicoPhotoEdit())
        let portable = try ReadPicoBoardPlaylistImage.source(for: imageItem)
        check(PicoPhotoRenderer.sourceSize(image: portable) == CGSize(width: 2048, height: 1024), "portable source is bounded without changing aspect")
        let color = portable.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let pixel = NSBitmapImageRep(cgImage: color).colorAt(x: 100, y: 100)!.usingColorSpace(.deviceRGB)!
        check(abs(pixel.redComponent - pixel.greenComponent) > 0.2, "portable source retains RGB before hardware conversion")
        let portrait = try ReadPicoBoardPlaylistImage.composed(for: imageItem, landscape: false)
        let landscape = try ReadPicoBoardPlaylistImage.composed(for: imageItem, landscape: true)
        check(PicoPhotoRenderer.sourceSize(image: portrait) == CGSize(width: 684, height: 1216) &&
              PicoPhotoRenderer.sourceSize(image: landscape) == CGSize(width: 1216, height: 684), "each orientation uses real native screen dimensions")
        var imageCopy = imageItem
        imageCopy.id = UUID(); imageCopy.imageEditData = try JSONEncoder().encode(PicoPhotoEdit.centered(source: CGSize(width: 2048, height: 1024), target: .pico))
        check(imageCopy.imageEditData != imageItem.imageEditData && imageCopy.imageSourcePNG == imageItem.imageSourcePNG,
              "image composition changes independently while immutable source may be copied")
        imageCopy.imageSourcePNG = Data([0, 1, 2])
        reject("corrupt image must fail") { _ = try ReadPicoBoardPlaylistImage.source(for: imageCopy) }
        imageCopy = imageItem; imageCopy.imageEditData = Data("{}".utf8)
        reject("corrupt composition must fail") { _ = try ReadPicoBoardPlaylistImage.composed(for: imageCopy, landscape: false) }
        imageCopy = ReadPicoBoardPlaylistItem(module: 9, name: "未选图")
        reject("missing image must fail truthfully") { _ = try ReadPicoBoardPlaylistImage.source(for: imageCopy) }
        let oversized = colorImage(width: 4097, height: 1).cgImage(forProposedRect: nil, context: nil, hints: nil)!
        imageCopy.imageSourcePNG = NSBitmapImageRep(cgImage: oversized).representation(using: .png, properties: [:])
        reject("oversized decoded dimension rejected before rendering") { _ = try ReadPicoBoardPlaylistImage.source(for: imageCopy) }
        print("PASS: \(count) playlist, receipt cursor and image source checks")
    }
}
