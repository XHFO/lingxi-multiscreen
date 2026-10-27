import AppKit
import Foundation
import LinxDisplayCore

/// Tests the actual production Core object and committed firmware-note fixture.
/// No live AppModel, USB volume, network, or physical device is used.
@main struct ReadingCardRenderingTests {
    @MainActor static func main() async throws {
        guard (2...3).contains(CommandLine.arguments.count) else { fatalError("fixture root and optional output directory required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = CommandLine.arguments.count == 3 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil
        let store = ReadPicoReadingNotesStore(rootURL: root.appendingPathComponent("render-db"))
        let deviceA = UUID(), deviceB = UUID(), deviceC = UUID(), deviceD = UUID()
        _ = try await store.importCard(rootURL: root)
        let records = try await store.notes()
        let record = records.first { !$0.note.isEmpty }!
        let alternate = records.first { !$0.note.isEmpty && $0.id != record.id }!
        try await store.setAuthorization(noteIDs: [record.id], target: deviceA.uuidString, includeNotes: false)
        try await store.setAuthorization(noteIDs: [record.id], target: deviceB.uuidString, includeNotes: true)
        try await store.setAuthorization(noteIDs: [alternate.id], target: deviceD.uuidString, includeNotes: true)
        let plain = try await store.nextCard(target: deviceA.uuidString, instance: "actual-render")!
        let annotated = try await store.nextCard(target: deviceB.uuidString, instance: "actual-render")!
        let otherNote = try await store.nextCard(target: deviceD.uuidString, instance: "actual-render")!
        let unauthorized = try await store.nextCard(target: deviceC.uuidString, instance: "actual-render")
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1; print("PASS " + message)
        }
        check(plain.id == annotated.id && plain.note == nil && annotated.note == record.note && unauthorized == nil,
              "actual per-device projection includes private annotation only for explicit authorization")
        let settings = AppSettings()
        let pomo = PomodoroSnapshot(phase: .idle, effectivePhase: .idle, taskName: "", remaining: 0,
                                    duration: 0, completedFocusSessions: 0)
        let nowPlaying = NowPlayingInfo(title: "")
        let now = Date(timeIntervalSince1970: 1_792_742_400)
        func image(_ card: ReadPicoReadingCard?, width: Int, height: Int) -> CGImage {
            ScreenRenderer.renderDeviceCanvas(modules: [.readingExcerpt], system: .empty,
                nowPlaying: nowPlaying, pomodoro: pomo, customText: "", settings: settings,
                now: now, width: width, height: height, palette: settings.resolvedPalette,
                rasterScale: width > 600 ? 4 : 1, readingExcerpt: card)
        }
        func pixels(_ image: CGImage) -> Data {
            let context = CGContext(data: nil, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: context.data!, count: image.width * image.height * 4)
        }
        func save(_ image: CGImage, name: String) throws {
            guard let output else { return }
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            try data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }
        func withLongQuote(_ card: ReadPicoReadingCard) throws -> ReadPicoReadingCard {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as! [String: Any]
            object["body"] = String(repeating: "这段很长的书中引用不应该挤掉已经明确授权的私人批注。", count: 30)
            return try JSONDecoder().decode(ReadPicoReadingCard.self, from: JSONSerialization.data(withJSONObject: object))
        }
        for (width, height) in [(684, 1216), (1216, 684), (200, 200), (296, 152), (240, 240)] {
            let onlyQuote = image(plain, width: width, height: height)
            let withNote = image(annotated, width: width, height: height)
            let placeholder = image(unauthorized, width: width, height: height)
            let quotePixels = pixels(onlyQuote), notePixels = pixels(withNote), emptyPixels = pixels(placeholder)
            if width >= 600 {
                try save(onlyQuote, name: "fixture-quote-\(width)x\(height)")
                try save(withNote, name: "fixture-authorized-note-\(width)x\(height)")
                try save(placeholder, name: "fixture-unauthorized-\(width)x\(height)")
            }
            check(onlyQuote.width == width && onlyQuote.height == height && withNote.width == width && withNote.height == height,
                  "actual module renderer preserves \(width)x\(height) target pixels")
            check(notePixels != quotePixels, "explicit authorized annotation changes actual \(width)x\(height) output")
            check(notePixels != pixels(image(otherNote, width: width, height: height)),
                  "private note text after explicit newline remains distinguishable at \(width)x\(height)")
            check(emptyPixels != quotePixels && emptyPixels != notePixels,
                  "unauthorized \(width)x\(height) target renders placeholder rather than another device's content")
            check(notePixels == pixels(image(annotated, width: width, height: height)),
                  "rendering cached \(width)x\(height) card does not advance queue or randomize pixels")
        }
        let longQuoteA = try withLongQuote(annotated), longQuoteB = try withLongQuote(otherNote)
        for (width, height) in [(684, 1216), (1216, 684), (200, 60), (200, 36)] {
            check(pixels(image(longQuoteA, width: width, height: height)) != pixels(image(longQuoteB, width: width, height: height)),
                  "long quotation cannot hide distinct authorized annotations at \(width)x\(height)")
        }
        let plainKeyboard = try ScreenRenderer.renderCanvas(modules: [.readingExcerpt], system: .empty,
            nowPlaying: nowPlaying, pomodoro: pomo, customText: "", settings: settings,
            now: now, readingExcerpt: plain)
        let noteKeyboard = try ScreenRenderer.renderCanvas(modules: [.readingExcerpt], system: .empty,
            nowPlaying: nowPlaying, pomodoro: pomo, customText: "", settings: settings,
            now: now, readingExcerpt: annotated)
        let keyboardImage = NSImage(data: noteKeyboard.data)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        check(plainKeyboard.data != noteKeyboard.data, "keyboard renderCanvas production JPEG includes explicitly authorized annotation")
        check(keyboardImage.width == 142 && keyboardImage.height == 428, "keyboard output retains exact 142x428 dimensions")
        try await store.removeAuthorization(noteIDs: [record.id], target: deviceB.uuidString)
        let reopened = ReadPicoReadingNotesStore(rootURL: root.appendingPathComponent("render-db"))
        let revoked = try await reopened.nextCard(target: deviceB.uuidString, instance: "actual-render")
        check(revoked == nil, "reopening database after authorization removal produces no private card")
        check(pixels(image(revoked, width: 684, height: 1216)) == pixels(image(nil, width: 684, height: 1216)),
              "revoked target renders the actual empty placeholder after database reopen")
        let retained = try await reopened.nextCard(target: deviceA.uuidString, instance: "actual-render")
        check(retained?.id == plain.id && retained?.note == nil, "revoking one device preserves another device's quote-only grant")
        if let output {
            let description = """
            阅读摘录实际渲染回归：\(checks) 项通过。
            PNG 来自合成 C ABI 固件记录 fixture，经当前实际 LinxDisplayCore 生产引擎渲染。
            这些图片不是软件 UI 截图，也不是实体设备截图；没有访问 USB、网络或实体设备。
            quote：仅允许引用；authorized-note：额外授权私人批注；unauthorized：未授权占位。
            覆盖 Pico 原生竖横屏、先知、摘录、AI Mac 与键盘尺寸，多行批注、长引用和低高度排版。
            """
            try Data(description.utf8).write(to: output.appendingPathComponent("README.txt"), options: .atomic)
        }
        print("PASS \(checks) production reading-card rendering and device projection checks; no hardware accessed")
    }
}
