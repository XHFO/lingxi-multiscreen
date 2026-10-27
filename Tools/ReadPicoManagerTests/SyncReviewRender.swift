import AppKit
import SwiftUI
import Foundation

@main struct SyncReviewRender {
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1]), sourceCard = URL(fileURLWithPath: CommandLine.arguments[2])
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("pico-review-render-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let input = root.appendingPathComponent("在时间的河流中阅读.txt"), card = root.appendingPathComponent("card")
        try fm.createDirectory(at: card.appendingPathComponent("books"), withIntermediateDirectories: true)
        try Data("Mac 中保存的图书内容。".utf8).write(to: input)
        try Data("Pico 中的另一个版本，必须保留。".utf8).write(to: card.appendingPathComponent("books/在时间的河流中阅读.txt"))
        for index in 0..<5 { try Data("设备独有资料 \(index)".utf8).write(to: card.appendingPathComponent("books/设备独有\(index).txt")) }
        let library = try ReadPicoLocalLibrary(rootURL: root.appendingPathComponent("library")), item = try await library.importFile(input, kind: .book)
        let plan = try await library.prepareSync([item], to: ReadPicoTFStore(rootURL: card))
        let notes = ReadPicoReadingNotesStore(rootURL: root.appendingPathComponent("notes"))
        let notePlan = try await notes.prepareImport(sourceCard)
        var manifest: [[String: Any]] = []
        for dark in [false, true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for type in ["files", "notes"] {
                let width: CGFloat = type == "files" ? 580 : 540
                let content: AnyView = type == "files"
                    ? AnyView(ReadPicoLibrarySyncReview(plan: plan, policy: .constant(.merge), cancel: {}, apply: {}))
                    : AnyView(ReadPicoReadingNotesSyncSheet(review: notePlan, policy: .constant(.preferPico), cancel: {}, apply: {}))
                let view = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
                view.appearance = app.appearance
                view.frame = NSRect(x: 0, y: 0, width: width, height: type == "files" ? 495 : 430)
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("cannot render native review") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let name = type + (dark ? "-dark" : "-light") + ".png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
                manifest.append(["file": name, "width": view.bounds.width, "height": view.bounds.height])
            }
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("manifest.json"))
        print("PASS native file/database review sheets rendered in light and dark appearances")
    }
}
