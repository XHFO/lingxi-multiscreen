import AppKit
import SwiftUI
import Foundation
import LinxDisplayCore

private var checks = 0
@MainActor private func check(_ value: Bool, _ label: String) { checks += 1; if !value { fatalError(label) } }
@MainActor private func settled(_ model: ReadPicoManagerModel, local: ReadPicoLocalLibraryModel) async throws {
    for _ in 0..<500 {
        if !model.busy && !local.busy { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    fatalError("operation did not settle")
}
@main struct LocalLibraryUITests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pico-local-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("sources"), card = root.appendingPathComponent("card")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let source = sources.appendingPathComponent("阅读测试.txt")
        try Data(String(repeating:"这是一段文字，用于检查真实传输与预览。\n", count: 18000).utf8).write(to: source)
        let note = sources.appendingPathComponent("旅途记录.md")
        try Data("# 旅途记录\n\n今天读完了第一章，记录下来。".utf8).write(to: note)
        let library = try ReadPicoLocalLibrary(rootURL: root.appendingPathComponent("library"))
        let local = ReadPicoLocalLibraryModel(library: library)
        let manager = ReadPicoManagerModel(discoverVolumes: { [] }, discoverUSBPorts: { [] })
        defer { manager.deactivate() }
        local.importFiles([source], kind: .book)
        try await settled(manager, local: local)
        check(local.items.count == 1 && local.selected.count == 1, "import selects one owned local file")
        check(manager.store == nil && manager.files.isEmpty, "local import does not require or touch a device")
        check(local.thumbnails.count == 1 && local.items[0].previewText.contains("真实传输"), "local import loads real cached thumbnail and text")
        try FileManager.default.removeItem(at: source)
        let book = local.items[0]
        check(try await library.sourceURL(for: book).path != source.path, "owned source is independent")
        local.importFiles([note], kind: .note)
        try await settled(manager, local: local)
        check(local.items.count == 2 && local.items.contains { $0.kind == .note }, "note is a distinct local kind")
        var requested = false
        local.beginSync(local.items, manager: manager) { requested = true }
        check(requested && local.awaitingConnection, "only explicit sync requests a device connection")
        check(!manager.busy && manager.files.isEmpty, "pending connection has not written data")
        manager.selectCard(card); try await settled(manager, local: local)
        local.cardConnected(manager: manager, isActive: false)
        check(!manager.busy && local.awaitingConnection && manager.files.isEmpty,
              "a retained hidden library cannot resume a pending batch before its parent cancels")
        local.cardConnected(manager: manager)
        check(manager.busy && !local.awaitingConnection, "verified card selection starts queued sync once")
        try await settled(manager, local: local)
        check(manager.files.count == 2 && !manager.isError, "two selected local files arrive on TF")
        check(local.message.contains("成功 2") && local.message.contains("失败 0"), "batch result has success skipped and failure totals")
        check(local.syncProgress != nil && local.syncProgress!.fileCount == 2, "real copy progress reaches UI")
        local.beginSync(local.items, manager: manager) {}
        try await settled(manager, local: local)
        check(local.message.contains("跳过相同内容 2"), "same-content repeat sync is idempotent")
        let removed = local.items.first { $0.kind == .note }!
        local.remove(removed); try await settled(manager, local: local)
        check(local.items.count == 1 && manager.files.count == 2, "local deletion preserves synchronized device files")
        manager.forgetCard(); requested = false
        local.beginSync(local.items, manager: manager) { requested = true }
        local.cancelPending(); manager.selectCard(card); try await settled(manager, local: local)
        local.cardConnected(manager: manager)
        check(requested && !local.awaitingConnection && !manager.busy, "cancelled pending batch never resumes after a later card selection")
        let bookDestination = card.appendingPathComponent("books/阅读测试.txt"), picoVersion = Data("Pico 上后来修改的书本。".utf8)
        try picoVersion.write(to: bookDestination)
        local.beginSync([book], manager: manager) {}
        try await settled(manager, local: local)
        check(local.syncReview?.conflictCount == 1 && !manager.busy, "a real content conflict pauses for review after preflight")
        check(try Data(contentsOf: bookDestination) == picoVersion, "review has not overwritten Pico")
        local.cancelSyncReview()
        check(try Data(contentsOf: bookDestination) == picoVersion && local.syncReview == nil, "cancelled review leaves actual card untouched")
        local.beginSync([book], manager: manager) {}
        try await settled(manager, local: local)
        local.syncPolicy = .preferMac; local.applySyncReview(manager: manager)
        try await settled(manager, local: local)
        check(try Data(contentsOf: bookDestination) == Data(contentsOf: await library.sourceURL(for: book)), "Mac preference actually applies selected source")
        check(local.items.contains { $0.previewText.contains("后来修改") }, "replaced Pico source is visible and recoverable in local library")
        for index in 0..<5 { try Data("设备独有内容 \(index)".utf8).write(to: card.appendingPathComponent("books/设备特有\(index).txt")) }
        local.beginSync([book], manager: manager) {}
        try await settled(manager, local: local)
        check((local.syncReview?.picoOnly.count ?? 0) >= 5, "many one-sided differences also ask how to reconcile")
        local.syncPolicy = .merge; local.applySyncReview(manager: manager)
        try await settled(manager, local: local)
        check(local.items.filter { $0.filename.hasPrefix("设备特有") }.count == 5, "chosen merge imports device-only files into actual Mac library")
        print("PASS \(checks) local library UI/model workflow checks")
    }
}
