import Foundation
import CoreGraphics
import CoreText
import ImageIO
import CryptoKit
import Darwin
import zlib

public enum ReadPicoLibraryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case book, font, note
    public var id: String { rawValue }
    public var title: String { switch self { case .book: return "图书"; case .font: return "字体"; case .note: return "独立笔记" } }
    public var fileKind: ReadPicoFileKind { switch self { case .book: return .book; case .font: return .font; case .note: return .note } }
}
public struct ReadPicoLibraryItem: Codable, Identifiable, Equatable, Sendable {
    public let id: String, title: String, filename: String, kind: ReadPicoLibraryKind, bytes: Int64
    public let summary: String, previewText: String, thumbnailFilename: String?, importedAt: Date, sha256: String
}
public struct ReadPicoLibrarySyncResult: Sendable {
    public let itemID: String, relativePath: String, alreadyPresent: Bool
}
public struct ReadPicoLibraryProgress: Sendable {
    public let fileIndex: Int, fileCount: Int, filename: String, completedBytes: Int64, totalBytes: Int64
    public let overallCompletedBytes: Int64, overallTotalBytes: Int64, stage: String
}

/// Conflict preferences apply to matching filenames; one-sided content is never deleted.
public enum ReadPicoLibrarySyncPolicy: String, CaseIterable, Identifiable, Sendable {
    case merge, preferMac, preferPico
    public var id: String { rawValue }
    public var title: String { switch self { case .merge: "合并两边的资料"; case .preferMac: "同名冲突保留 Mac 版本"; case .preferPico: "同名冲突保留 Pico 版本" } }
    public var explanation: String {
        switch self {
        case .merge: "两边独有内容都保留；同名不同内容分别保存，Pico 原文件保持原名。"
        case .preferMac: "同名文件使用 Mac 版本；替换前将 Pico 原件保存到 Mac 资料库，便于恢复。"
        case .preferPico: "同名文件保留 Pico 版本并收入 Mac 资料库；Mac 原件保留，不覆盖。"
        }
    }
}
public struct ReadPicoLibrarySyncPlan: Identifiable, Sendable {
    public enum Difference: String, Sendable { case identical, macOnly, conflict }
    public struct Entry: Sendable {
        public let item: ReadPicoLibraryItem
        public let relativePath: String
        public let difference: Difference
        public let renamed: Bool
        public let localSHA256: String
        public let remoteSHA256: String?
    }
    public let id = UUID()
    public let entries: [Entry]
    public let picoOnly: [ReadPicoCardFile]
    public let inventorySignature: String
    public var identicalCount: Int { entries.filter { $0.difference == .identical }.count }
    public var macOnlyCount: Int { entries.filter { $0.difference == .macOnly }.count }
    public var conflictCount: Int { entries.filter { $0.difference == .conflict }.count }
    public var needsReview: Bool { conflictCount > 0 || entries.contains(where: \.renamed) || macOnlyCount + picoOnly.count >= 5 }
    public var differenceCount: Int { macOnlyCount + picoOnly.count + conflictCount }
}

/// Local owned copies survive removal of the original source and disconnected readers.
/// Every index transaction uses an OS file lock and reloads the index, including across device sessions.
public actor ReadPicoLocalLibrary {
    public nonisolated let rootURL: URL
    private let files = FileManager.default
    public init(rootURL: URL? = nil) throws {
        let base = try rootURL ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LinxDisplayBeta2/ReadPicoLibrary", isDirectory: true)
        guard (try? base.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw ReadPicoManagerError.invalid("资料库目录不能是符号链接。") }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.rootURL = base.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        let lockURL = rootURL.appendingPathComponent(".library.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw ReadPicoManagerError.unavailable("无法锁定本地资料库，请检查存储权限。") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func load() throws -> [ReadPicoLibraryItem] {
        let url = rootURL.appendingPathComponent("index.json")
        guard files.fileExists(atPath: url.path) else { return [] }
        let data = try read(url, limit: 16 * 1024 * 1024)
        let items = try JSONDecoder().decode([ReadPicoLibraryItem].self, from: data)
        guard items.count <= 10000, Set(items.map(\.id)).count == items.count, items.allSatisfy({ valid($0) }) else { throw ReadPicoManagerError.invalid("资料库索引无效；原文件已保留。") }
        return items
    }
    private func valid(_ item: ReadPicoLibraryItem) -> Bool {
        item.sha256.count == 64 && item.sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        && item.id == item.kind.rawValue + "-" + item.sha256 && leaf(item.filename) && (item.thumbnailFilename == nil || item.thumbnailFilename == "thumbnail.png")
    }
    private func leaf(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && name.utf8.count <= 180 }
    private func object(_ item: ReadPicoLibraryItem) throws -> URL {
        guard valid(item) else { throw ReadPicoManagerError.invalid("资料库项目路径无效。") }
        let parent = rootURL.appendingPathComponent("objects").appendingPathComponent(item.id)
        for p in [rootURL.appendingPathComponent("objects"), parent] {
            guard (try? p.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw ReadPicoManagerError.invalid("资料库文件不能指向其他目录。") }
        }
        return parent
    }
    private func save(_ items: [ReadPicoLibraryItem]) throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: rootURL.appendingPathComponent("index.json"), options: .atomic)
    }
    public func items(kind: ReadPicoLibraryKind? = nil) throws -> [ReadPicoLibraryItem] {
        try transaction { try load().filter { kind == nil || $0.kind == kind }.sorted { $0.importedAt > $1.importedAt } }
    }
    public func sourceURL(for item: ReadPicoLibraryItem) throws -> URL {
        let url = try object(item).appendingPathComponent(item.filename)
        guard files.fileExists(atPath: url.path), (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw ReadPicoManagerError.unavailable("本地资料文件已丢失，请重新导入。") }
        return url
    }
    public func thumbnailURL(for item: ReadPicoLibraryItem) throws -> URL? {
        guard let name = item.thumbnailFilename else { return nil }
        let url = try object(item).appendingPathComponent(name)
        guard files.fileExists(atPath: url.path), (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        return url
    }
    private func read(_ url: URL, limit: Int) throws -> Data {
        var currentURL = url; currentURL.removeAllCachedResourceValues()
        let v = try currentURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize, size > 0, size <= limit else { throw ReadPicoManagerError.invalid("文件为空、过大或不是普通文件。") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == size else { throw ReadPicoManagerError.unavailable("源文件读取不完整。") }; return data
    }
    @discardableResult public func importFile(_ source: URL, kind: ReadPicoLibraryKind) throws -> ReadPicoLibraryItem {
        try transaction {
            guard leaf(source.lastPathComponent) else { throw ReadPicoManagerError.invalid("请使用不超过 180 字节的文件名。") }
            let ext = source.pathExtension.lowercased()
            if kind == .font && ext != "ttf" { throw ReadPicoManagerError.invalid("Pico 仅支持 TrueType TTF；请选择 .ttf 字体。OTF、CFF 与 TTC 不能同步到设备。") }
            guard (kind == .book && ["epub", "txt"].contains(ext)) || (kind == .font && ext == "ttf") || (kind == .note && ["md", "markdown", "txt"].contains(ext)) else { throw ReadPicoManagerError.invalid("请选择当前资料类型支持的文件。") }
            let data = try read(source, limit: kind == .font ? 32 * 1024 * 1024 : kind == .note ? 16 * 1024 * 1024 : 256 * 1024 * 1024)
            if kind == .font { try ReadPicoTrueTypeFont.validate(data, filename: source.lastPathComponent) }
            try Task.checkCancellation()
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), id = kind.rawValue + "-" + sha
            var list = try load()
            if let existing = list.first(where: { $0.id == id }) { _ = try sourceURL(for: existing); return existing }
            var title = source.deletingPathExtension().lastPathComponent, preview = "", summary = "", cover: Data?, font: CTFont?
            if kind == .font {
                guard let provider = CGDataProvider(data: data as CFData), let cg = CGFont(provider) else { throw ReadPicoManagerError.invalid("字体无法读取，请选择有效的 TrueType TTF。") }
                font = CTFontCreateWithGraphicsFont(cg, 28, nil, nil)
                title = CTFontCopyFullName(font!) as String
                preview = "天地玄黄，宇宙洪荒。\n小纸 Pico · 灵犀画板\nThe quick brown fox jumps over the lazy dog.\nABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789 ！？，。"
                var chinese = Array("中文阅读".utf16), glyphs = [CGGlyph](repeating: 0, count: chinese.count)
                let includesChinese = CTFontGetGlyphsForCharacters(font!, &chinese, &glyphs, chinese.count)
                summary = "\(ext.uppercased()) · \(cg.numberOfGlyphs) 个字形" + (includesChinese ? "" : " · 中文字形不完整")
            } else if ext == "epub" {
                let epub = try PicoEPUBPreview(data: data)
                if !epub.title.isEmpty { title = epub.title }
                preview = epub.text; cover = epub.cover
                summary = "EPUB" + (epub.author.isEmpty ? "" : " · " + epub.author) + (cover == nil ? " · 未包含可用封面" : " · 书内封面")
            } else {
                guard let text = PicoLibraryPreview.decodeText(data), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReadPicoManagerError.invalid("文本编码无法识别或没有正文。") }
                preview = String(text.prefix(12000)); summary = kind == .note ? "独立笔记 · 同步为可阅读 TXT，不合并书内批注" : "TXT · \(text.count) 字符"
            }
            title = String(title.prefix(512))
            let item = ReadPicoLibraryItem(id: id, title: title, filename: source.lastPathComponent, kind: kind, bytes: Int64(data.count), summary: summary, previewText: preview, thumbnailFilename: "thumbnail.png", importedAt: Date(), sha256: sha)
            let parent = try object(item)
            try files.createDirectory(at: parent, withIntermediateDirectories: true)
            var committed = false
            defer { if !committed { try? files.removeItem(at: parent) } }
            try data.write(to: parent.appendingPathComponent(item.filename), options: .atomic)
            if kind == .note {
                guard let text = PicoLibraryPreview.decodeText(data) else { throw ReadPicoManagerError.invalid("笔记编码无法识别。") }
                try Data(text.utf8).write(to: parent.appendingPathComponent(syncFilename(item)), options: .atomic)
            }
            let png = try PicoLibraryPreview.thumbnail(title: title, text: preview, cover: cover, font: font, kind: kind)
            try png.write(to: parent.appendingPathComponent("thumbnail.png"), options: .atomic)
            try Task.checkCancellation()
            list.append(item); try save(list); committed = true; return item
        }
    }
    private func syncFilename(_ item: ReadPicoLibraryItem) -> String {
        guard item.kind == .note else { return item.filename }
        if item.filename.hasPrefix("灵犀笔记-"), URL(fileURLWithPath: item.filename).pathExtension.lowercased() == "txt" { return item.filename }
        let name = URL(fileURLWithPath: item.filename).deletingPathExtension().lastPathComponent
        var stem = String(name.prefix(48))
        while ("灵犀笔记-" + stem + ".txt").utf8.count > 180 { stem.removeLast() }
        return "灵犀笔记-" + stem + ".txt"
    }
    public func remove(_ item: ReadPicoLibraryItem) throws {
        try transaction {
            var list = try load(); guard list.contains(where: { $0.id == item.id }) else { return }
            list.removeAll { $0.id == item.id }; try save(list)
            try? files.removeItem(at: object(item))
        }
    }
    private func syncSource(_ item: ReadPicoLibraryItem) throws -> URL {
        item.kind == .note ? try object(item).appendingPathComponent(syncFilename(item)) : try sourceURL(for: item)
    }
    private static func pathKey(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
    private static func alternateFilename(_ source: URL, sha: String) -> String {
        var stem = source.deletingPathExtension().lastPathComponent
        let suffix = "-Mac-" + String(sha.prefix(10)) + "." + source.pathExtension
        while (stem + suffix).utf8.count > 180 { stem.removeLast() }
        return stem + suffix
    }
    private static func inventorySignature(_ items: [ReadPicoCardFile]) -> String {
        let rows = items.map { "\($0.kind.rawValue)|\($0.relativePath)|\($0.bytes)|\($0.modified?.timeIntervalSince1970 ?? -1)|\($0.valid)" }.sorted()
        return SHA256.hash(data: Data(rows.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func exported(_ file: ReadPicoCardFile, store: any ReadPicoContentStore, directory: URL) async throws -> URL {
        let parent = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = parent.appendingPathComponent(URL(fileURLWithPath: file.relativePath).lastPathComponent)
        try await store.export(file, to: url, format: "dat")
        return url
    }
    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while true { try Task.checkCancellation(); let bytes = try handle.read(upToCount: 128 * 1024) ?? Data(); if bytes.isEmpty { break }; hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Read-only preview; no device file or local database is modified before a policy is chosen.
    public func prepareSync(_ items: [ReadPicoLibraryItem], to store: any ReadPicoContentStore) async throws -> ReadPicoLibrarySyncPlan {
        let inventory = try await store.scan(), selectedKinds = Set(items.map { $0.kind.fileKind.rawValue })
        let temporary = files.temporaryDirectory.appendingPathComponent("pico-sync-review-" + UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        var entries: [ReadPicoLibrarySyncPlan.Entry] = [], selectedPaths = Set<String>()
        for item in items {
            try Task.checkCancellation()
            let source = try syncSource(item), localSHA = try digest(source)
            var proposed = try await store.proposedPath(for: source, kind: item.kind.fileKind), renamed = false
            if !selectedPaths.insert(Self.pathKey(proposed)).inserted {
                proposed = (item.kind == .font ? "fonts/" : "books/") + Self.alternateFilename(source, sha: localSHA)
                guard selectedPaths.insert(Self.pathKey(proposed)).inserted else { throw ReadPicoManagerError.conflict("所选资料包含重复条目，请重新选择后同步。") }
                renamed = true
            }
            let match = inventory.first { Self.pathKey($0.relativePath) == Self.pathKey(proposed) }
            if let match {
                if !renamed, match.relativePath == proposed, try await store.isIdentical(source, kind: item.kind.fileKind) {
                    // The network store checks SHA-256 metadata without downloading an unchanged book.
                    entries.append(.init(item: item, relativePath: match.relativePath, difference: .identical, renamed: false, localSHA256: localSHA, remoteSHA256: localSHA))
                    continue
                }
                // Compare complete bytes, including case-only filenames on FAT filesystems.
                let saved = try await exported(match, store: store, directory: temporary)
                let remoteSHA = try digest(saved), same = remoteSHA == localSHA
                entries.append(.init(item: item, relativePath: match.relativePath, difference: same ? .identical : .conflict, renamed: renamed, localSHA256: localSHA, remoteSHA256: remoteSHA))
            } else { entries.append(.init(item: item, relativePath: proposed, difference: .macOnly, renamed: renamed, localSHA256: localSHA, remoteSHA256: nil)) }
        }
        let outgoing = Set(entries.map { Self.pathKey($0.relativePath) })
        let picoOnly = inventory.filter { selectedKinds.contains($0.kind.rawValue) && $0.valid && !outgoing.contains(Self.pathKey($0.relativePath)) }
        return .init(entries: entries, picoOnly: picoOnly, inventorySignature: Self.inventorySignature(inventory))
    }
    /// Apply a reviewed reconciliation; replacement always follows a verified import of the previous Pico copy.
    public func sync(_ plan: ReadPicoLibrarySyncPlan, to store: any ReadPicoContentStore,
                     policy: ReadPicoLibrarySyncPolicy, progress: (@Sendable (ReadPicoLibraryProgress) -> Void)? = nil) async throws -> [ReadPicoLibrarySyncResult] {
        let inventory = try await store.scan()
        guard Self.inventorySignature(inventory) == plan.inventorySignature else { throw ReadPicoManagerError.conflict("Pico 内容在预览后发生了变化，请重新核对同步差异。") }
        let temporary = files.temporaryDirectory.appendingPathComponent("pico-sync-apply-" + UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        var sourceSizes: [String: Int64] = [:]
        for entry in plan.entries {
            let source = try syncSource(entry.item)
            guard try digest(source) == entry.localSHA256 else { throw ReadPicoManagerError.conflict("Mac 原件在预览后发生了变化，请重新核对同步差异。") }
            guard let bytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 0 else { throw ReadPicoManagerError.unavailable("待同步的资料不可读取，请重新导入。") }
            sourceSizes[entry.item.id] = Int64(bytes)
        }
        var preserved: [String: URL] = [:]
        // Check all conflicts and preserve all replaced versions before the first device write.
        for entry in plan.entries where entry.difference == .conflict {
            try Task.checkCancellation()
            guard let file = inventory.first(where: { $0.relativePath == entry.relativePath }) else { throw ReadPicoManagerError.conflict("Pico 的同名文件已变化，请重新核对。") }
            let url = try await exported(file, store: store, directory: temporary)
            guard try digest(url) == entry.remoteSHA256 else { throw ReadPicoManagerError.conflict("Pico 文件在预览后已修改，请重新核对同步差异。") }
            _ = try importFile(url, kind: entry.item.kind)
            preserved[entry.relativePath] = url
        }
        // A merge brings reader-only files into the Mac library; neither side's unique files is removed.
        if policy == .merge || policy == .preferPico {
            for file in plan.picoOnly {
                try Task.checkCancellation()
                guard let kind = ReadPicoLibraryKind.allCases.first(where: { $0.fileKind == file.kind }) else { continue }
                let url = try await exported(file, store: store, directory: temporary)
                _ = try importFile(url, kind: kind)
            }
        }
        var results: [ReadPicoLibrarySyncResult] = [], completed: Int64 = 0
        let total = plan.entries.reduce(Int64(0)) { $0 + (sourceSizes[$1.item.id] ?? 0) }
        for (index, entry) in plan.entries.enumerated() {
            try Task.checkCancellation()
            let item = entry.item, source = try syncSource(item), bytes = sourceSizes[item.id] ?? 0
            let base = completed, filename = item.filename, count = plan.entries.count
            let notify: @Sendable (Int64, Int64, String) -> Void = { copied, bytes, stage in
                progress?(.init(fileIndex: index + 1, fileCount: count, filename: filename, completedBytes: copied, totalBytes: bytes, overallCompletedBytes: base + copied, overallTotalBytes: total, stage: stage))
            }
            defer { completed += bytes }
            if entry.difference == .identical || entry.difference == .conflict && policy == .preferPico {
                notify(bytes, bytes, "skipped")
                results.append(.init(itemID: item.id, relativePath: entry.relativePath, alreadyPresent: true)); continue
            }
            var sending = source
            if entry.difference == .conflict || entry.renamed {
                if entry.difference == .conflict { guard preserved[entry.relativePath] != nil else { throw ReadPicoManagerError.unavailable("尚未保存 Pico 原件，已停止替换。") } }
                let parent = temporary.appendingPathComponent(UUID().uuidString)
                try files.createDirectory(at: parent, withIntermediateDirectories: true)
                if entry.difference == .conflict && policy == .merge {
                    sending = parent.appendingPathComponent(Self.alternateFilename(source, sha: entry.localSHA256))
                } else { sending = parent.appendingPathComponent(URL(fileURLWithPath: entry.relativePath).lastPathComponent) }
                try files.copyItem(at: source, to: sending)
            }
            let same = try await store.isIdentical(sending, kind: item.kind.fileKind)
            let relative = same ? try await store.proposedPath(for: sending, kind: item.kind.fileKind) : try await store.importFile(sending, kind: item.kind.fileKind, replace: entry.difference == .conflict && policy == .preferMac, progress: notify)
            notify(bytes, bytes, same ? "skipped" : "completed")
            results.append(.init(itemID: item.id, relativePath: relative, alreadyPresent: same))
        }
        return results
    }
    public func sync(_ items: [ReadPicoLibraryItem], to store: any ReadPicoContentStore, replace: Bool = false, progress: (@Sendable (ReadPicoLibraryProgress) -> Void)? = nil) async throws -> [ReadPicoLibrarySyncResult] {
        var sources: [(ReadPicoLibraryItem, URL, Int64)] = []
        for item in items {
            let url = item.kind == .note ? try object(item).appendingPathComponent(syncFilename(item)) : try sourceURL(for: item)
            // Check all selected content before copying any item, including legacy local OTF entries.
            _ = try await store.proposedPath(for: url, kind: item.kind.fileKind)
            let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            sources.append((item, url, Int64(bytes)))
        }
        let fileCount = sources.count
        let total = sources.reduce(Int64(0)) { $0 + $1.2 }; var done: Int64 = 0, results: [ReadPicoLibrarySyncResult] = []
        for (index, entry) in sources.enumerated() {
            try Task.checkCancellation()
            let (item, url, bytes) = entry, base = done
            let notify: @Sendable (Int64, Int64, String) -> Void = { copied, count, stage in
                progress?(.init(fileIndex: index + 1, fileCount: fileCount, filename: item.filename, completedBytes: copied, totalBytes: count, overallCompletedBytes: base + copied, overallTotalBytes: total, stage: stage))
            }
            let same = try await store.isIdentical(url, kind: item.kind.fileKind)
            let relative: String
            if same { relative = try await store.proposedPath(for: url, kind: item.kind.fileKind); notify(bytes, bytes, "skipped") }
            else { relative = try await store.importFile(url, kind: item.kind.fileKind, replace: replace, progress: notify); notify(bytes, bytes, "completed") }
            done += bytes; results.append(.init(itemID: item.id, relativePath: relative, alreadyPresent: same))
        }
        return results
    }
}

private enum PicoLibraryPreview {
    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { return String(data: data, encoding: .utf16) }
        if let s = String(data: data, encoding: .utf8) { return s.replacingOccurrences(of: "\u{feff}", with: "") }
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: encoding))
    }
    static func thumbnail(title: String, text: String, cover: Data?, font: CTFont?, kind: ReadPicoLibraryKind) throws -> Data {
        let width = 300, height = 420
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ReadPicoManagerError.unavailable("无法生成缩略图。") }
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let cover, let source = CGImageSourceCreateWithData(cover as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height)), w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
            c.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
        } else {
            c.setStrokeColor(CGColor(gray: 0.84, alpha: 1)); c.setLineWidth(1); c.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(width - 1), height: CGFloat(height - 1)))
            let heading = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 20, nil)
            let label = NSAttributedString(string: title + "\n\n", attributes: [.init(kCTFontAttributeName as String): heading, .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1)])
            let bodyFont = font.map { CTFontCreateCopyWithAttributes($0, 20, nil, nil) } ?? CTFontCreateWithName("PingFangSC-Regular" as CFString, 15, nil)
            let content = NSMutableAttributedString(attributedString: label)
            content.append(NSAttributedString(string: String(text.prefix(kind == .font ? 200 : 600)), attributes: [.init(kCTFontAttributeName as String): bodyFont, .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.2, alpha: 1)]))
            let setter = CTFramesetterCreateWithAttributedString(content), path = CGPath(rect: CGRect(x: 20, y: 20, width: width - 40, height: height - 40), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), c)
        }
        guard let image = c.makeImage() else { throw ReadPicoManagerError.unavailable("无法生成缩略图。") }
        let data = NSMutableData(); guard let target = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw ReadPicoManagerError.unavailable("无法编码缩略图。") }
        CGImageDestinationAddImage(target, image, nil); guard CGImageDestinationFinalize(target) else { throw ReadPicoManagerError.unavailable("缩略图写入失败。") }; return data as Data
    }
}

/// Central-directory bounded ZIP reader: no filesystem extraction and no shell commands.
private struct PicoEPUBArchive {
    struct Entry { let name: String, start: Int, compressed: Int, uncompressed: Int, method: Int, crc: UInt32 }
    let data: Data, entries: [String: Entry]
    private static func u16(_ d: Data, _ p: Int) -> Int { Int(d[p]) | Int(d[p + 1]) << 8 }
    private static func u32(_ d: Data, _ p: Int) -> UInt32 { UInt32(d[p]) | UInt32(d[p + 1]) << 8 | UInt32(d[p + 2]) << 16 | UInt32(d[p + 3]) << 24 }
    init(data: Data) throws {
        func fail() -> ReadPicoManagerError { .invalid("EPUB 目录损坏、加密或超出安全预览限制。") }
        guard data.count >= 22 else { throw fail() }
        var end: Int?
        for p in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if Self.u32(data, p) == 0x06054b50, p + 22 + Self.u16(data, p + 20) == data.count { end = p; break }
        }
        guard let end, Self.u16(data, end + 4) == 0, Self.u16(data, end + 6) == 0, Self.u16(data, end + 8) == Self.u16(data, end + 10) else { throw fail() }
        let count = Self.u16(data, end + 10), size = Int(Self.u32(data, end + 12)), start = Int(Self.u32(data, end + 16))
        guard count > 0, count <= 10000, start <= end, size <= end - start else { throw fail() }
        var parsed: [String: Entry] = [:], p = start
        for _ in 0..<count {
            guard p <= start + size - 46, Self.u32(data, p) == 0x02014b50 else { throw fail() }
            let flags = Self.u16(data, p + 8), method = Self.u16(data, p + 10), compressed = Int(Self.u32(data, p + 20)), uncompressed = Int(Self.u32(data, p + 24)), nameLength = Self.u16(data, p + 28), extra = Self.u16(data, p + 30), comment = Self.u16(data, p + 32), local = Int(Self.u32(data, p + 42))
            guard flags & 1 == 0, [0, 8].contains(method), nameLength > 0, nameLength <= 1024, p + 46 + nameLength + extra + comment <= start + size,
                  let name = String(data: data.subdata(in: p + 46..<p + 46 + nameLength), encoding: .utf8), !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"), !name.split(separator: "/").contains(".."), parsed[name] == nil,
                  local <= start - 30, Self.u32(data, local) == 0x04034b50, Self.u16(data, local + 8) == method, Self.u16(data, local + 6) & 1 == 0 else { throw fail() }
            let localName = Self.u16(data, local + 26), localExtra = Self.u16(data, local + 28), payload = local + 30 + localName + localExtra
            guard localName == nameLength, payload <= start, compressed <= start - payload,
                  data.subdata(in: local + 30..<local + 30 + localName) == data.subdata(in: p + 46..<p + 46 + nameLength) else { throw fail() }
            parsed[name] = Entry(name: name, start: payload, compressed: compressed, uncompressed: uncompressed, method: method, crc: Self.u32(data, p + 16)); p += 46 + nameLength + extra + comment
        }
        guard p == start + size else { throw fail() }; self.data = data; entries = parsed
    }
    func read(_ name: String, limit: Int) throws -> Data {
        guard let e = entries[name], e.uncompressed <= limit, e.compressed <= 16 * 1024 * 1024 else { throw ReadPicoManagerError.invalid("EPUB 预览资源缺失或过大。") }
        let compressed = data.subdata(in: e.start..<e.start + e.compressed)
        let result: Data
        if e.method == 0 { guard e.compressed == e.uncompressed else { throw ReadPicoManagerError.invalid("EPUB 资源长度无效。") }; result = compressed }
        else {
            let outputCount = max(1, e.uncompressed)
            var output = Data(count: outputCount), stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ReadPicoManagerError.unavailable("无法初始化 EPUB 解压。") }
            defer { inflateEnd(&stream) }
            let status = output.withUnsafeMutableBytes { out in compressed.withUnsafeBytes { input in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(compressed.count)
                stream.next_out = out.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(outputCount)
                return inflate(&stream, Z_FINISH)
            } }
            guard status == Z_STREAM_END, stream.total_out == e.uncompressed, stream.total_in == e.compressed else { throw ReadPicoManagerError.invalid("EPUB 资源解压未完成。") }
            result = output.prefix(e.uncompressed)
        }
        guard readPicoCRC32(result) == e.crc else { throw ReadPicoManagerError.invalid("EPUB 资源校验未通过。") }; return result
    }
    static func path(_ href: String, relativeTo file: String) -> String? {
        guard let decoded = href.removingPercentEncoding, !decoded.contains(":"), !decoded.hasPrefix("/"), !decoded.contains("\\") else { return nil }
        var parts = file.split(separator: "/").dropLast().map(String.init)
        for part in decoded.split(separator: "#", maxSplits: 1).first?.split(separator: "/") ?? [] {
            if part == "." { continue }; if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() } else { parts.append(String(part)) }
        }
        return parts.joined(separator: "/")
    }
}
private final class PicoEPUBXML: NSObject, XMLParserDelegate {
    var title = "", author = "", text = "", rootfile: String?, coverID: String?, manifest: [String: (String, String)] = [:], spine: [String] = [], coverHref: String?
    private var current = "", ignored = 0
    static func parse(_ data: Data) throws -> PicoEPUBXML {
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
        guard !raw.lowercased().contains("<!entity") else { throw ReadPicoManagerError.invalid("EPUB 文档包含不支持的实体定义。") }
        let delegate = PicoEPUBXML(), parser = XMLParser(data: data); parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw ReadPicoManagerError.invalid("EPUB 文档无法解析。") }; return delegate
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String]) {
        current = name.split(separator: ":").last.map(String.init)?.lowercased() ?? name
        if ["script", "style"].contains(current) { ignored += 1 }
        if current == "rootfile", rootfile == nil { rootfile = a["full-path"] }
        if current == "meta", a["name"] == "cover" { coverID = a["content"] }
        if current == "item", let id = a["id"], let href = a["href"] { manifest[id] = (href, a["media-type"] ?? ""); if a["properties"]?.split(separator: " ").contains("cover-image") == true { coverHref = href } }
        if current == "itemref", let id = a["idref"] { spine.append(id) }
        if ["p", "div", "br", "h1", "h2", "li"].contains(current) { text += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current == "title" { title += string }; if current == "creator" { author += string }
        if ignored == 0, text.count < 16000 { text += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = name.split(separator: ":").last.map(String.init)?.lowercased() ?? name
        if ["script", "style"].contains(element) { ignored = max(0, ignored - 1) }; current = ""
    }
}
private struct PicoEPUBPreview {
    let title: String, author: String, text: String, cover: Data?
    init(data: Data) throws {
        let archive = try PicoEPUBArchive(data: data)
        let container = try PicoEPUBXML.parse(archive.read("META-INF/container.xml", limit: 128 * 1024))
        guard let root = container.rootfile, let rootPath = PicoEPUBArchive.path(root, relativeTo: "container.xml") else { throw ReadPicoManagerError.invalid("EPUB 未提供有效的内容目录。") }
        let opf = try PicoEPUBXML.parse(archive.read(rootPath, limit: 1024 * 1024))
        title = opf.title.trimmingCharacters(in: .whitespacesAndNewlines); author = String(opf.author.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        let coverHref = opf.coverHref ?? opf.coverID.flatMap { opf.manifest[$0]?.0 }
        if let coverHref, let path = PicoEPUBArchive.path(coverHref, relativeTo: rootPath), let candidate = try? archive.read(path, limit: 8 * 1024 * 1024),
           let source = CGImageSourceCreateWithData(candidate as CFData, nil), CGImageSourceGetCount(source) > 0,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0, width <= 20000, height <= 20000, Int64(width) * Int64(height) <= 40_000_000 { cover = candidate } else { cover = nil }
        var body = ""
        for id in opf.spine.prefix(32) {
            guard body.count < 12000, let entry = opf.manifest[id], ["application/xhtml+xml", "text/html"].contains(entry.1), let path = PicoEPUBArchive.path(entry.0, relativeTo: rootPath), let resource = try? archive.read(path, limit: 512 * 1024), let xml = try? PicoEPUBXML.parse(resource) else { continue }
            body += xml.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        text = String(body.prefix(12000))
    }
}
