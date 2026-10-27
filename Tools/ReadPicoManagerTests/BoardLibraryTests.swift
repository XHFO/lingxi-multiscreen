import AppKit
import Foundation

private var checks = 0
@MainActor private func check(_ value: @autoclosure () throws -> Bool, _ message: String) rethrows {
    checks += 1
    if try !value() { fatalError(message) }
}
private func fails(_ message: String, _ action: () throws -> Void) {
    do { try action(); fatalError(message) } catch { checks += 1 }
}
private enum Simulated: Error { case disk }

@main struct BoardLibraryTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let device = UUID(), active = ReadPicoCanvasDraft()
        active.canvasMode = 1; active.strokes = [[CGPoint(x: 0.2, y: 0.3)]]
        var failCommit = false
        let library = ReadPicoBoardLibrary(deviceID: device, rootURL: root, beforeIndexCommit: {
            if failCommit { throw Simulated.disk }
        })
        try library.load(into: active)
        check(library.boards.isEmpty && library.selectedID == nil && active.hasUnsavedChanges,
              "empty library never invents examples or discards unsaved input")
        let first = try library.create(name: "第一张", from: active, into: active)
        check(library.selectedID == first && !active.hasUnsavedChanges && active.strokes.count == 1,
              "create saves real editable content and selection")
        active.landscape = true; active.board.modules = [0, 1]
        _ = active.playlist.add(module: 0, name: "时钟")
        active.strokes.append([CGPoint(x: 0.7, y: 0.8)])
        try library.saveCurrent(active)
        let firstURL = library.directoryURL.appendingPathComponent(first.uuidString + ".picocanvas")
        let firstBytes = try Data(contentsOf: firstURL)
        let snapshot = try library.loadBoard(first)
        check(snapshot.landscape && snapshot.playlist.items.count == 1 && snapshot.strokes == active.strokes,
              "saved snapshot retains orientation, playlist, and editable strokes")
        snapshot.strokes.removeAll()
        check(active.strokes.count == 2 && !active.hasUnsavedChanges, "independent snapshots never mutate editor")

        let second = try library.duplicate(first, into: active)
        check(second != first && library.selectedID == second && active.strokes.count == 2,
              "duplicate uses fresh UUID with independent content")
        try library.rename(second, to: "第二张")
        check(active.board.name == "第二张" && !active.hasUnsavedChanges, "rename updates clean selected document")
        active.strokes.append([CGPoint(x: 0.4, y: 0.4)])
        try library.rename(second, to: "保留编辑")
        check(active.hasUnsavedChanges && active.strokes.count == 3, "rename preserves pending edits")
        try library.select(first, into: active)
        try library.reorder([second, first])
        let order = library.boards.map(\.id)
        fails("reorder rejects duplicates") { try library.reorder([first, first]) }
        check(library.boards.map(\.id) == order, "bad ordering preserves old list")

        let indexURL = library.directoryURL.appendingPathComponent("index.json")
        var indexBytes = try Data(contentsOf: indexURL)
        let secondURL = library.directoryURL.appendingPathComponent(second.uuidString + ".picocanvas")
        let secondBytes = try Data(contentsOf: secondURL)
        try Data("broken".utf8).write(to: secondURL)
        active.strokes.append([CGPoint(x: 0.9, y: 0.9)])
        let pending = active.strokes
        fails("corrupt select fails before changing active selection") { try library.select(second, into: active) }
        check(library.selectedID == first && active.strokes == pending && active.hasUnsavedChanges,
              "corrupt select preserves editor and baseline")
        try check(try Data(contentsOf: indexURL) == indexBytes, "corrupt select preserves index bytes")
        try secondBytes.write(to: secondURL)

        failCommit = true
        fails("new insertion disk failure") { _ = try library.create(name: "失败", into: active) }
        check(library.boards.count == 2 && active.strokes == pending && active.hasUnsavedChanges,
              "failed insert keeps old editor and list")
        fails("selection disk failure") { try library.select(second, into: active) }
        fails("rename disk failure") { try library.rename(first, to: "失败改名") }
        try check(try Data(contentsOf: firstURL) == firstBytes, "failed rename restores exact old document")
        active.board.name = "失败保存"
        fails("save name-change disk failure") { try library.saveCurrent(active) }
        try check(try Data(contentsOf: firstURL) == firstBytes, "failed save restores document bytes")
        try check(try Data(contentsOf: indexURL) == indexBytes, "failed transactions keep exact index")
        check(active.hasUnsavedChanges && active.board.name == "失败保存", "failed save keeps pending name and baseline")
        let ownedFiles = try fm.contentsOfDirectory(at: library.directoryURL, includingPropertiesForKeys: nil)
        check(ownedFiles.filter { $0.pathExtension == "picocanvas" }.count == 2,
              "failed insertion removes only its owned staging document")
        failCommit = false
        active.discardChanges()

        let external = root.appendingPathComponent("original.picocanvas")
        try firstBytes.write(to: external)
        let imported = try library.importDraft(from: external, into: active)
        try check(try Data(contentsOf: external) == firstBytes, "import never rewrites user original")
        let invalid = root.appendingPathComponent("bad.picocanvas")
        try Data("invalid".utf8).write(to: invalid)
        fails("invalid import") { _ = try library.importDraft(from: invalid, into: active) }
        check(library.selectedID == imported, "invalid import keeps selection")
        try library.setIncludedInCarousel(second, included: false)
        try library.setCarouselDuration(first, seconds: 15)
        try library.setCarouselEnabled(true)
        check(library.nextCarouselID(after: first) == imported && library.nextCarouselID(after: imported) == first,
              "carousel respects inclusion and stored order")
        fails("carousel duration limit") { try library.setCarouselDuration(first, seconds: 0) }
        let reopened = ReadPicoBoardLibrary(deviceID: device, rootURL: root)
        let otherActive = ReadPicoCanvasDraft(); try reopened.load(into: otherActive)
        check(reopened.selectedID == imported && reopened.carouselEnabled && reopened.carouselBoards.count == 2,
              "selection and carousel metadata survive reopening")
        try reopened.rename(first, to: "外部更新")
        fails("stale writer refuses overwrite") { try library.setCarouselEnabled(false) }
        try library.load(into: active)

        let otherDevice = ReadPicoBoardLibrary(deviceID: UUID(), rootURL: root)
        let otherDraft = ReadPicoCanvasDraft(); try otherDevice.load(into: otherDraft)
        let otherID = try otherDevice.create(name: "另一台", into: otherDraft)
        let otherFile = otherDevice.directoryURL.appendingPathComponent(otherID.uuidString + ".picocanvas")
        try library.remove(second, into: active)
        check(library.selectedID == imported, "removing non-selected board does not switch editor")
        try library.remove(imported, into: active)
        check(library.selectedID == first && active.board.name == "外部更新", "remove selected chooses nearest remaining board")
        try library.remove(first, into: active)
        check(library.boards.isEmpty && library.selectedID == nil && !active.hasUnsavedChanges && active.strokes.isEmpty,
              "removing last board gives clean blank draft")
        check(fm.fileExists(atPath: external.path) && fm.fileExists(atPath: otherFile.path),
              "removing library copies never deletes originals or another device")

        indexBytes = try Data(contentsOf: indexURL)
        var badIndex = try JSONSerialization.jsonObject(with: indexBytes) as! [String: Any]
        badIndex["deviceID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: badIndex).write(to: indexURL)
        active.strokes = [[CGPoint(x: 0.1, y: 0.1)]]
        fails("wrong-device index rejected") { try library.load(into: active) }
        check(library.boards.isEmpty && active.hasUnsavedChanges, "invalid index load preserves editor and published state")
        try indexBytes.write(to: indexURL); try library.load(into: active)
        for number in 0..<ReadPicoBoardLibrary.maximumBoards {
            _ = try library.create(name: "画板 \(number)", into: active)
        }
        fails("enforces maximum 32 independent boards") { _ = try library.create(into: active) }
        check(library.boards.count == 32, "limit failure preserves existing boards")
        print("ReadPicoBoardLibrary: \(checks) checks passed")
    }
}
