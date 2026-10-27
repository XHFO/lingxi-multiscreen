import Foundation
import CoreGraphics
import ImageIO
private var count = 0
private func check(_ condition: Bool, _ text: String) { count += 1; if !condition { fatalError(text) } }
private func rejects(_ text: String, _ action: () async throws -> Void) async { do { try await action(); fatalError(text) } catch { count += 1 } }
private final class ProgressBox: @unchecked Sendable {
    let lock = NSLock(); var events: [ReadPicoLibraryProgress] = []
    func add(_ e: ReadPicoLibraryProgress) { lock.lock(); events.append(e); lock.unlock() }
}
@main struct LocalLibraryTests {
 static func main() async throws {
    let files = FileManager.default, fixtures = URL(fileURLWithPath: CommandLine.arguments[1]), root = files.temporaryDirectory.appendingPathComponent("pico-library-" + UUID().uuidString)
    try files.createDirectory(at: root, withIntermediateDirectories: true); defer { try? files.removeItem(at: root) }
    let libraryURL = root.appendingPathComponent("library"), source = root.appendingPathComponent("source"), card = root.appendingPathComponent("card")
    try files.createDirectory(at: source, withIntermediateDirectories: true); try files.createDirectory(at: card, withIntermediateDirectories: true)
    let library = try ReadPicoLocalLibrary(rootURL: libraryURL), second = try ReadPicoLocalLibrary(rootURL: libraryURL)
    let input = source.appendingPathComponent("读书摘记.md")
    try Data("# 我的读书摘记\n长期有效的独立笔记。".utf8).write(to: input)
    let note = try await library.importFile(input, kind: .note)
    check(note.kind == .note && note.previewText.contains("长期有效"), "note preview")
    check(note.summary.contains("不合并"), "note semantics")
    check(try Data(contentsOf: await library.sourceURL(for: note)) == Data(contentsOf: input), "owned source")
    let note2 = try await second.importFile(input, kind: .note)
    let afterDuplicate = try await library.items()
    check(note.id == note2.id && afterDuplicate.count == 1, "dedup across actors")
    try files.removeItem(at: input)
    check(files.fileExists(atPath: try await library.sourceURL(for: note).path), "original removed, local retained")
    let recreated = try ReadPicoLocalLibrary(rootURL: libraryURL)
    check((try await recreated.items()).first?.id == note.id, "persistent index")
    let large = source.appendingPathComponent("长文本.txt"), bytes = Data(String(repeating: "天地玄黄 宇宙洪荒\n", count: 80000).utf8)
    try bytes.write(to: large)
    async let a = library.importFile(large, kind: .book)
    async let b = second.importFile(fixtures.appendingPathComponent("sample.epub"), kind: .book)
    let (book, epub) = try await (a, b)
    check((try await library.items()).count == 3, "concurrent actors do not lose updates")
    check(epub.title == "真实封面书" && epub.summary.contains("作者甲") && epub.previewText.contains("真正的章节内容"), "EPUB OPF/spine metadata")
    let thumbURL = try await library.thumbnailURL(for: epub)!
    let thumb = CGImageSourceCreateWithURL(thumbURL as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(thumb, 0, nil)!
    check(image.width == 300 && image.height == 420, "cached thumbnail dimensions")
    let rendered = CFDataGetBytePtr(image.dataProvider!.data!)!
    let center = 4 * (image.width * 210 + 150)
    check(rendered[center] > 180 && rendered[center + 1] < 100 && rendered[center + 2] < 100, "real red cover used")
    let systemFont = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
    let font = try await library.importFile(systemFont, kind: .font)
    check(font.title.contains("Arial") && font.summary.contains("字形"), "font actual metadata")
    check(try await library.thumbnailURL(for: font) != nil, "private CoreText preview cache")
    let store = try ReadPicoTFStore(rootURL: card), progress = ProgressBox()
    let trueType = try Data(contentsOf: systemFont)
    func u16(_ p: Int) -> Int { Int(trueType[p]) << 8 | Int(trueType[p + 1]) }
    func u32(_ p: Int) -> Int { u16(p) << 16 | u16(p + 2) }
    func record(_ tag: String) -> Int { (0..<u16(4)).map { 12 + $0 * 16 }.first { String(decoding: trueType[$0..<($0 + 4)], as: UTF8.self) == tag }! }
    var appleTrue = trueType; appleTrue.replaceSubrange(0..<4, with: Data("true".utf8))
    try ReadPicoTrueTypeFont.validate(appleTrue, filename: "apple-true.ttf"); check(true, "supported Apple TrueType signature")
    var badCFF = trueType; badCFF.replaceSubrange(0..<4, with: Data("OTTO".utf8))
    var badCollection = trueType; badCollection.replaceSubrange(0..<4, with: Data("ttcf".utf8))
    var missingGlyf = trueType; missingGlyf.replaceSubrange(record("glyf")..<(record("glyf") + 4), with: Data("gone".utf8))
    var badLocations = trueType
    let locaOffset = u32(record("loca") + 8), headOffset = u32(record("head") + 8), locationWidth = u16(headOffset + 50) == 0 ? 2 : 4
    badLocations.replaceSubrange(locaOffset..<(locaOffset + locationWidth * 2), with: Data((0..<(locationWidth * 2)).map { $0 == locationWidth - 1 ? 4 : 0 }))
    var outsideTable = trueType; outsideTable.replaceSubrange(20..<24, with: [255, 255, 255, 255])
    var badUnits = trueType; badUnits.replaceSubrange((headOffset + 18)..<(headOffset + 20), with: [0, 15])
    for (name, data) in [("renamed.otf", trueType), ("renamed-cff.ttf", badCFF), ("collection.ttf", badCollection), ("no-glyf.ttf", missingGlyf), ("bad-loca.ttf", badLocations), ("outside-table.ttf", outsideTable), ("bad-units.ttf", badUnits)] {
        let url = source.appendingPathComponent(name); try data.write(to: url)
        await rejects("local import rejects " + name) { _ = try await library.importFile(url, kind: .font) }
        await rejects("TF destination rejects " + name) { _ = try await store.proposedPath(for: url, kind: .font) }
    }
    let legacyURL = root.appendingPathComponent("legacy-library")
    try files.copyItem(at: libraryURL, to: legacyURL)
    let legacyIndexURL = legacyURL.appendingPathComponent("index.json")
    var legacyIndex = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyIndexURL)) as! [[String: Any]]
    let fontIndex = legacyIndex.firstIndex { $0["id"] as? String == font.id }!
    legacyIndex[fontIndex]["filename"] = "保留的旧字体.otf"
    let legacySource = legacyURL.appendingPathComponent("objects/\(font.id)/保留的旧字体.otf")
    try trueType.write(to: legacySource)
    let legacyIndexBytes = try JSONSerialization.data(withJSONObject: legacyIndex); try legacyIndexBytes.write(to: legacyIndexURL)
    let legacyLibrary = try ReadPicoLocalLibrary(rootURL: legacyURL), legacyFont = try await legacyLibrary.items(kind: .font).first!
    let untouchedCard = root.appendingPathComponent("preflight-card"); try files.createDirectory(at: untouchedCard, withIntermediateDirectories: true)
    let untouchedStore = try ReadPicoTFStore(rootURL: untouchedCard)
    await rejects("legacy OTF rejects before any selected file writes") { _ = try await legacyLibrary.sync([book, legacyFont], to: untouchedStore) }
    check(try Data(contentsOf: legacySource) == trueType && Data(contentsOf: legacyIndexURL) == legacyIndexBytes, "legacy OTF source and index preserved")
    check(try files.contentsOfDirectory(atPath: untouchedCard.path).isEmpty, "batch font preflight leaves TF unchanged")
    let results = try await library.sync([note, book, epub, font], to: store, progress: { progress.add($0) })
    check(results.count == 4 && results.allSatisfy { !$0.alreadyPresent }, "selective sync results")
    check(results[0].relativePath == "books/灵犀笔记-读书摘记.txt", "flat notes path for actual reader")
    check(try String(contentsOf: card.appendingPathComponent(results[0].relativePath), encoding: .utf8).contains("独立笔记"), "Markdown note readable UTF8 copy")
    check(progress.events.filter { $0.stage == "copying" && $0.fileIndex == 2 }.count > 5, "actual large file chunk progress")
    check(progress.events.last?.overallCompletedBytes == progress.events.last?.overallTotalBytes, "overall exact total")
    let scans = try await store.scan()
    check(scans.filter { $0.kind == .font }.count == 1 && scans.filter { $0.kind == .note }.count == 1, "scan synchronized fonts/notes")
    let repeats = try await library.sync([note, book], to: store)
    check(repeats.allSatisfy(\.alreadyPresent), "sync idempotence")
    try Data("existing different bytes".utf8).write(to: card.appendingPathComponent("books/长文本.txt"))
    await rejects("different same name must not overwrite") { _ = try await library.sync([book], to: store) }
    check(try Data(contentsOf: card.appendingPathComponent("books/长文本.txt")) == Data("existing different bytes".utf8), "conflict preserves existing")
    _ = try await library.sync([book], to: store, replace: true)
    check(try Data(contentsOf: card.appendingPathComponent("books/长文本.txt")) == bytes, "explicit replace")
    let toCancel = source.appendingPathComponent("取消.txt"); try bytes.write(to: toCancel)
    let cancelItem = try await library.importFile(toCancel, kind: .book)
    let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await library.sync([cancelItem], to: store) }
    do { _ = try await task.value; fatalError("cancel ignored") } catch { count += 1 }
    check(!files.fileExists(atPath: card.appendingPathComponent("books/取消.txt").path), "cancel no target")
    let cancelledDestination = card.appendingPathComponent("books/取消.txt")
    try Data("old preserved".utf8).write(to: cancelledDestination)
    let midCopy = Task {
      try await store.importFile(toCancel, kind: .book, replace: true, progress: { completed, _, stage in
        if stage == "copying", completed > 0 { withUnsafeCurrentTask { $0?.cancel() } }
      })
    }
    do { _ = try await midCopy.value; fatalError("mid-copy cancel ignored") } catch { count += 1 }
    check(try Data(contentsOf: cancelledDestination) == Data("old preserved".utf8), "mid-copy cancel preserves old target")
    check(try files.contentsOfDirectory(atPath: card.appendingPathComponent("books").path).allSatisfy { !$0.hasPrefix(".pico-") }, "cancel removes temp file")
    let broken = source.appendingPathComponent("broken.ttf"); try Data("garbage".utf8).write(to: broken)
    await rejects("invalid font") { _ = try await library.importFile(broken, kind: .font) }
    let markdownSource = source.appendingPathComponent("长扩展名.markdown"), markdownText = "# Markdown 笔记\n保留原件，独立同步。"
    try Data(markdownText.utf8).write(to: markdownSource)
    let markdown = try await library.importFile(markdownSource, kind: .note)
    let markdownOwnedSource = try await library.sourceURL(for: markdown)
    let markdownOwnedData = try Data(contentsOf: markdownOwnedSource)
    check(markdown.filename.hasSuffix(".markdown") && markdown.previewText == markdownText && markdownOwnedData == Data(markdownText.utf8), "markdown extension previews and preserves original")
    let markdownResults = try await library.sync([markdown], to: store)
    let markdownDeviceText = try String(contentsOf: card.appendingPathComponent("books/灵犀笔记-长扩展名.txt"), encoding: .utf8)
    check(markdownResults.first?.relativePath == "books/灵犀笔记-长扩展名.txt" && markdownDeviceText == markdownText, "markdown extension normalizes to readable UTF8 TXT")
    for name in ["traversal.epub", "crc.epub", "duplicate.epub", "bomb.epub", "entity.epub"] {
      await rejects(name) { _ = try await library.importFile(fixtures.appendingPathComponent(name), kind: .book) }
    }
    let link = source.appendingPathComponent("link.txt"); try files.createSymbolicLink(at: link, withDestinationURL: large)
    await rejects("source symlink") { _ = try await library.importFile(link, kind: .book) }
    let diskIndex = libraryURL.appendingPathComponent("index.json"), savedIndex = try Data(contentsOf: diskIndex)
    var forged = try JSONSerialization.jsonObject(with: savedIndex) as! [[String: Any]]; forged[0]["filename"] = "../escape.txt"
    try JSONSerialization.data(withJSONObject: forged).write(to: diskIndex)
    await rejects("forged index path") { _ = try await library.items() }
    try savedIndex.write(to: diskIndex)
    try await library.remove(note)
    check(!(try await second.items()).contains { $0.id == note.id }, "remove shared index")
    check(files.fileExists(atPath: card.appendingPathComponent(results[0].relativePath).path), "local remove keeps device")
    // Real temporary cards exercise all reconciliation choices without touching user storage.
    for policy in ReadPicoLibrarySyncPolicy.allCases {
        let policyRoot = root.appendingPathComponent(policy.rawValue), policyCard = policyRoot.appendingPathComponent("card")
        try files.createDirectory(at: policyCard.appendingPathComponent("books"), withIntermediateDirectories: true)
        let input = policyRoot.appendingPathComponent("同名.txt"), oldBytes = Data("Pico 上的旧版本，必须保留。".utf8), newBytes = Data("Mac 上的新版本。".utf8)
        try newBytes.write(to: input); try oldBytes.write(to: policyCard.appendingPathComponent("books/同名.txt"))
        try Data("只在Pico存在的书。".utf8).write(to: policyCard.appendingPathComponent("books/设备独有.txt"))
        let peer = try ReadPicoTFStore(rootURL: policyCard), local = try ReadPicoLocalLibrary(rootURL: policyRoot.appendingPathComponent("library"))
        let item = try await local.importFile(input, kind: .book)
        let plan = try await local.prepareSync([item], to: peer)
        check(plan.conflictCount == 1 && plan.picoOnly.count == 1 && plan.needsReview, "\(policy): full diff preview")
        let itemsBefore = try await local.items()
        check(try Data(contentsOf: policyCard.appendingPathComponent("books/同名.txt")) == oldBytes && itemsBefore.count == 1, "preview does not mutate either side")
        _ = try await local.sync(plan, to: peer, policy: policy)
        let current = try Data(contentsOf: policyCard.appendingPathComponent("books/同名.txt"))
        check(current == (policy == .preferMac ? newBytes : oldBytes), "\(policy): chosen original path")
        let localItems = try await local.items()
        check(localItems.contains { $0.sha256 != item.sha256 && $0.previewText.contains("必须保留") }, "\(policy): Pico conflict source recoverable in Mac library")
        check(files.fileExists(atPath: policyCard.appendingPathComponent("books/设备独有.txt").path), "\(policy): peer-only content preserved")
        if policy == .merge {
            check((try await peer.scan()).count == 3, "merge keeps both file versions on Pico")
            let next = try await local.prepareSync([item], to: peer)
            _ = try await local.sync(next, to: peer, policy: .merge)
            check((try await peer.scan()).count == 3, "merge repeat is idempotent")
        }
        let stale = try await local.prepareSync([item], to: peer)
        try Data("changed after preview".utf8).write(to: policyCard.appendingPathComponent("books/同名.txt"))
        await rejects("stale diff rejected") { _ = try await local.sync(stale, to: peer, policy: policy) }
        check(try Data(contentsOf: policyCard.appendingPathComponent("books/同名.txt")) == Data("changed after preview".utf8), "stale preview cannot overwrite new Pico data")
    }
    let duplicateRoot = root.appendingPathComponent("duplicate-selection"), duplicateCard = duplicateRoot.appendingPathComponent("card")
    try files.createDirectory(at: duplicateCard, withIntermediateDirectories: true)
    let duplicateInput = duplicateRoot.appendingPathComponent("同名选择.txt"), duplicateLibrary = try ReadPicoLocalLibrary(rootURL: duplicateRoot.appendingPathComponent("library"))
    let firstBytes = Data("第一份同名的内容。".utf8), secondBytes = Data("第二份同名的内容。".utf8)
    try firstBytes.write(to: duplicateInput); let firstVersion = try await duplicateLibrary.importFile(duplicateInput, kind: .book)
    try secondBytes.write(to: duplicateInput); let secondVersion = try await duplicateLibrary.importFile(duplicateInput, kind: .book)
    let duplicatePeer = try ReadPicoTFStore(rootURL: duplicateCard)
    let duplicatePlan = try await duplicateLibrary.prepareSync([firstVersion, secondVersion], to: duplicatePeer)
    check(duplicatePlan.needsReview && duplicatePlan.entries.filter(\.renamed).count == 1, "selected Mac versions with the same filename require review")
    check(Set(duplicatePlan.entries.map(\.relativePath)).count == 2, "selected same-name versions receive distinct reviewed paths")
    let duplicateResults = try await duplicateLibrary.sync(duplicatePlan, to: duplicatePeer, policy: .merge)
    check(duplicateResults.count == 2 && duplicateResults.allSatisfy { !$0.alreadyPresent }, "both selected same-name versions synchronize")
    let copiedVersions = try duplicateResults.map { try Data(contentsOf: duplicateCard.appendingPathComponent($0.relativePath)) }
    check(Set(copiedVersions) == Set([firstBytes, secondBytes]), "same-name selected versions preserve exact content")
    let repeatedDuplicatePlan = try await duplicateLibrary.prepareSync([firstVersion, secondVersion], to: duplicatePeer)
    _ = try await duplicateLibrary.sync(repeatedDuplicatePlan, to: duplicatePeer, policy: .merge)
    check((try await duplicatePeer.scan()).count == 2, "same-name selected repeat creates no extra files")
    let utf16NoteURL = duplicateRoot.appendingPathComponent("UTF16笔记.txt"), utf16Text = "测试 UTF16 独立笔记的真实传输大小。"
    try (Data([0xff, 0xfe]) + utf16Text.data(using: .utf16LittleEndian)!).write(to: utf16NoteURL)
    let utf16Note = try await duplicateLibrary.importFile(utf16NoteURL, kind: .note), utf16Progress = ProgressBox()
    let utf16Plan = try await duplicateLibrary.prepareSync([utf16Note], to: duplicatePeer)
    let utf16Results = try await duplicateLibrary.sync(utf16Plan, to: duplicatePeer, policy: .merge, progress: { utf16Progress.add($0) })
    let utf8NoteBytes = try Data(contentsOf: duplicateCard.appendingPathComponent(utf16Results[0].relativePath))
    check(utf16Note.bytes != utf8NoteBytes.count && String(data: utf8NoteBytes, encoding: .utf8) == utf16Text, "reviewed note sync sends normalized UTF8 content")
    check(utf16Progress.events.last?.overallCompletedBytes == Int64(utf8NoteBytes.count) && utf16Progress.events.last?.overallTotalBytes == Int64(utf8NoteBytes.count), "reviewed progress uses actual transmitted UTF8 bytes")
    print("LocalLibrary: \(count) checks passed")
 }
}
