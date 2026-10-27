import Foundation
import CryptoKit
import Darwin

public enum ReadPicoReadingNoteKind: Int, Codable, CaseIterable, Sendable {
    case note = 0, highlight = 1, bookmark = 2
    public var title: String { switch self { case .note: "批注"; case .highlight: "划线"; case .bookmark: "书签" } }
}
public struct ReadPicoReadingInkPoint: Codable, Equatable, Sendable {
    public let x: UInt16, y: UInt16
}
public struct ReadPicoReadingNote: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let anchorID: String
    public let kind: ReadPicoReadingNoteKind
    public let bookPath: String
    public let sourceTitle: String
    public let fileBytes: UInt64
    public let chapter: UInt32
    public let start: UInt32
    public let end: UInt32
    public let quote: String
    public let note: String
    public let ink: [ReadPicoReadingInkPoint]
    public var sourceDeviceIDs: [UUID]
    public var firstImportedAt: Date
    public var lastImportedAt: Date
}
/// A deliberate, authorized display projection. Private annotations are absent unless explicitly allowed.
public struct ReadPicoReadingCard: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let quote: String
    public let body: String
    public let sourceTitle: String
    public let note: String?
}
public struct ReadPicoReadingNotesImportReport: Sendable {
    public let imported: Int
    public let duplicates: Int
    public let total: Int
    public let sourceURL: URL
    public let usedBackup: Bool
}
public enum ReadPicoReadingNotesSyncPolicy: String, CaseIterable, Identifiable, Sendable {
    case merge, preferMac, preferPico
    public var id: String { rawValue }
    public var title: String { switch self { case .merge: "合并两边的记录"; case .preferMac: "冲突位置保留 Mac 记录"; case .preferPico: "冲突位置保留 Pico 记录" } }
}
public struct ReadPicoReadingNotesSyncReview: Identifiable, Sendable {
    public let id = UUID()
    public let snapshot: ReadPicoReadingNotesParser.Snapshot
    public let localIDs: Set<String>
    public let macOnlyCount: Int, picoOnlyCount: Int, sharedCount: Int
    public let conflictingAnchors: Set<String>
    public var needsReview: Bool { !conflictingAnchors.isEmpty || !localIDs.isEmpty && macOnlyCount + picoOnlyCount >= 10 }
}
public struct ReadPicoReadingNotesError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Reads the committed v3 format in pico_reader_records.inc, with ps_store's XPS1/CRC32 envelope.
/// Never reads uncommitted orphan objects, writes the source card, or treats arbitrary TXT as annotations.
public enum ReadPicoReadingNotesParser {
    public struct Snapshot: Sendable {
        public let notes: [ReadPicoReadingNote]
        public let sourceURL: URL
        public let usedBackup: Bool
    }
    private struct ExportManifest: Decodable {
        struct Source: Decodable {
            let directory: String
            let index_crc32: UInt32
            let sequence: UInt32
        }
        let version: Int
        let complete: Bool
        let sources: [Source]
    }
    private static let exportDirectories = ["internal-a", "internal-b", "tf-a", "tf-b"]
    public static func read(from selected: URL, deviceID: UUID? = nil, now: Date = Date()) throws -> Snapshot {
        if let manifest = try locateExportManifest(selected) {
            return try readExport(manifest, deviceID: deviceID, now: now)
        }
        let index = try locateIndex(selected)
        return try readCommittedIndex(index, deviceID: deviceID, now: now)
    }
    private static func readCommittedIndex(_ index: URL, deviceID: UUID?, now: Date,
                                           expected: ExportManifest.Source? = nil) throws -> Snapshot {
        let directory = index.deletingLastPathComponent()
        let primary = expected != nil || index.lastPathComponent.hasSuffix(".bak") ? [index] : [index, directory.appendingPathComponent("reader-r3-index.bak")]
        var lastError: Error = ReadPicoReadingNotesError("没有找到已提交的阅读记录。")
        for url in primary where FileManager.default.fileExists(atPath: url.path) {
            do { return try readIndex(url, deviceID: deviceID, now: now, expected: expected) }
            catch { lastError = error }
        }
        throw lastError
    }
    /// New firmware snapshots both internal/TF committed stores before USB handoff.
    /// A completed manifest is authoritative: never hide a failed export by reading stale TF records.
    private static func locateExportManifest(_ selected: URL) throws -> URL? {
        guard selected.isFileURL else { throw ReadPicoReadingNotesError("请选择本地 TF 卡或阅读记录索引。") }
        let values = try selected.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw ReadPicoReadingNotesError("阅读记录来源不能是符号链接。") }
        var candidates: [(root: URL, boundary: URL)] = []
        if values.isDirectory == true {
            candidates.append((selected.appendingPathComponent("readpico/reading-notes", isDirectory: true), selected))
            if selected.lastPathComponent == "readpico" { candidates.append((selected.appendingPathComponent("reading-notes", isDirectory: true), selected)) }
            if selected.lastPathComponent == "reading-notes" { candidates.append((selected, selected)) }
            if exportDirectories.contains(selected.lastPathComponent), selected.deletingLastPathComponent().lastPathComponent == "reading-notes" {
                let parent = selected.deletingLastPathComponent(); candidates.append((parent, parent))
            }
        } else if values.isRegularFile == true {
            if selected.lastPathComponent == "manifest.json", selected.deletingLastPathComponent().lastPathComponent == "reading-notes" {
                candidates.append((selected.deletingLastPathComponent(), selected.deletingLastPathComponent()))
            } else if ["reader-r3-index.dat", "reader-r3-index.bak"].contains(selected.lastPathComponent) {
                let source = selected.deletingLastPathComponent(), parent = source.deletingLastPathComponent()
                if exportDirectories.contains(source.lastPathComponent), parent.lastPathComponent == "reading-notes" { candidates.append((parent, parent)) }
            }
        }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.root.path) {
            let manifest = candidate.root.appendingPathComponent("manifest.json")
            try validateAncestors(manifest, boundary: candidate.boundary)
            guard FileManager.default.fileExists(atPath: manifest.path) else {
                throw ReadPicoReadingNotesError("阅读记录导出尚未完成。请安全弹出 TF 卡，再重新连接 Pico 同步；设备中的原记录保留。")
            }
            return manifest
        }
        return nil
    }
    private static func readManifest(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1...4096).contains(size) else {
            throw ReadPicoReadingNotesError("阅读记录导出清单无效，请重新连接 Pico 同步。")
        }
        let data = try Data(contentsOf: url)
        guard data.count == size else { throw ReadPicoReadingNotesError("阅读记录导出清单读取不完整，请重新同步。") }
        return data
    }
    private static func readExport(_ manifestURL: URL, deviceID: UUID?, now: Date) throws -> Snapshot {
        let raw = try readManifest(manifestURL)
        let manifest: ExportManifest
        do { manifest = try JSONDecoder().decode(ExportManifest.self, from: raw) }
        catch { throw ReadPicoReadingNotesError("阅读记录导出清单格式无效，请重新连接 Pico 同步。") }
        guard manifest.version == 1, manifest.complete, manifest.sources.count <= 2,
              Set(manifest.sources.map(\.directory)).count == manifest.sources.count,
              manifest.sources.allSatisfy({ exportDirectories.contains($0.directory) && $0.sequence > 0 }),
              Set(manifest.sources.map { String($0.directory.dropLast(2)) }).count == manifest.sources.count,
              Set(manifest.sources.map { $0.directory.suffix(1) }).count <= 1 else {
            throw ReadPicoReadingNotesError("阅读记录导出尚未完整提交，请重新连接 Pico 同步。")
        }
        let root = manifestURL.deletingLastPathComponent()
        var notes: [ReadPicoReadingNote] = [], usedBackup = false
        for source in manifest.sources {
            let index = root.appendingPathComponent(source.directory, isDirectory: true).appendingPathComponent("reader-r3-index.dat")
            try validateAncestors(index, boundary: root)
            let snapshot = try readCommittedIndex(index, deviceID: deviceID, now: now, expected: source)
            notes.append(contentsOf: snapshot.notes); usedBackup = usedBackup || snapshot.usedBackup
        }
        guard try readManifest(manifestURL) == raw else {
            throw ReadPicoReadingNotesError("读取期间设备导出记录发生变化，请保持 TF 卡连接并重试。")
        }
        return Snapshot(notes: notes, sourceURL: manifestURL, usedBackup: usedBackup)
    }
    private static func locateIndex(_ selected: URL) throws -> URL {
        guard selected.isFileURL else { throw ReadPicoReadingNotesError("请选择本地 TF 卡或阅读记录索引。") }
        let value = try selected.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard value.isSymbolicLink != true else { throw ReadPicoReadingNotesError("阅读记录来源不能是符号链接。") }
        if value.isDirectory == true {
            for relative in ["books/.pico-system", ".pico-system", ""] {
                let root = relative.isEmpty ? selected : selected.appendingPathComponent(relative, isDirectory: true)
                for name in ["reader-r3-index.dat", "reader-r3-index.bak"] {
                    let index = root.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: index.path) { try validateAncestors(index, boundary: selected); return index }
                }
            }
            throw ReadPicoReadingNotesError("未找到可同步的书内记录。请使用支持阅读记录导出的新版 Pico 重新连接 USB；旧版可选择已复制的 books/.pico-system 目录或 reader-r3-index.dat。设备上的内置存储与 TF 卡记录都会保留。")
        }
        guard value.isRegularFile == true, ["reader-r3-index.dat", "reader-r3-index.bak"].contains(selected.lastPathComponent) else {
            throw ReadPicoReadingNotesError("请选择 reader-r3-index.dat 及同目录对象文件。普通 TXT 是独立文本，不能作为书内批注导入。")
        }
        return selected
    }
    private static func validateAncestors(_ url: URL, boundary: URL) throws {
        var cursor = url.deletingLastPathComponent()
        let stop = boundary.standardizedFileURL.path
        while cursor.standardizedFileURL.path.hasPrefix(stop) {
            let value = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard value.isDirectory == true, value.isSymbolicLink != true else { throw ReadPicoReadingNotesError("阅读记录目录无效，不能读取符号链接。") }
            if cursor.standardizedFileURL.path == stop { break }
            let parent = cursor.deletingLastPathComponent(); if parent == cursor { break }; cursor = parent
        }
    }
    private static func wrapped(_ url: URL, expected: Int? = nil) throws -> (raw: Data, payload: Data) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, (12...65548).contains(size) else { throw ReadPicoReadingNotesError("记录文件不是有效普通文件或超过固件上限。") }
        let raw = try Data(contentsOf: url)
        guard raw.count == size, u32(raw, 0) == 0x31535058, Int(u32(raw, 4)) == raw.count - 12,
              expected.map({ $0 == raw.count - 12 }) ?? true else { throw ReadPicoReadingNotesError("记录长度或 XPS1 文件头校验失败。") }
        let payload = Data(raw.dropFirst(12))
        guard crc32(payload) == u32(raw, 8) else { throw ReadPicoReadingNotesError("阅读记录 CRC32 校验失败，未导入不完整数据。") }
        return (raw, payload)
    }
    private static func readIndex(_ url: URL, deviceID: UUID?, now: Date, expected: ExportManifest.Source? = nil) throws -> Snapshot {
        let index = try wrapped(url, expected: 16 + 1024 * 8)
        let data = index.payload
        let count = Int(u32(data, 4)), nextID = u32(data, 12)
        guard u32(data, 0) == 3, count <= 1024, u32(data, 8) > 0, nextID > 0 else { throw ReadPicoReadingNotesError("阅读记录索引版本或数量无效。") }
        if let expected {
            guard u32(index.raw, 8) == expected.index_crc32, u32(data, 8) == expected.sequence else {
                throw ReadPicoReadingNotesError("阅读记录快照与导出清单不一致，未导入旧快照。请重新连接 Pico 同步。")
            }
        }
        var notes: [ReadPicoReadingNote] = [], seen = Set<UInt32>(), backup = url.pathExtension == "bak"
        for i in 0..<count {
            let objectID = u32(data, 16 + i * 8), size = Int(u32(data, 20 + i * 8))
            guard objectID > 0, objectID < nextID, seen.insert(objectID).inserted, (1185...3232).contains(size) else { throw ReadPicoReadingNotesError("阅读记录索引包含无效对象。") }
            let base = url.deletingLastPathComponent().appendingPathComponent("reader-r3-o-\(objectID)")
            var object: Data?, lastError: Error?
            // A manifest commits one complete export generation. Its older .bak objects
            // may share IDs/sizes, so recovery is reserved for legacy native stores.
            for ext in expected == nil ? ["dat", "bak"] : ["dat"] {
                do { object = try wrapped(base.appendingPathExtension(ext), expected: size).payload; if ext == "bak" { backup = true }; break }
                catch { lastError = error }
            }
            guard let object else { throw lastError ?? ReadPicoReadingNotesError("阅读记录对象缺失。") }
            if let note = try decodeObject(object, deviceID: deviceID, now: now) { notes.append(note) }
        }
        // An index commit during reading cannot yield a mixed local import.
        guard try wrapped(url, expected: data.count).raw == index.raw else { throw ReadPicoReadingNotesError("读取期间记录索引发生变化，请保持 TF 卡连接并重试。") }
        return Snapshot(notes: notes, sourceURL: url, usedBackup: backup)
    }
    private static func decodeObject(_ data: Data, deviceID: UUID?, now: Date) throws -> ReadPicoReadingNote? {
        guard data.count >= 1185, u32(data, 0) == 3, data[31] == 0,
              Int(u32(data, 24)) == data.count - 1184, (1...2048).contains(data.count - 1184),
              data.last == 0, !data[1184..<(data.count - 1)].contains(0),
              let kind = ReadPicoReadingNoteKind(rawValue: Int(data[29])), data[30] <= 64 else { throw ReadPicoReadingNotesError("阅读记录对象格式无效。") }
        // Retired built-in demo records are not actual book annotations.
        guard data[28] == 255 else { return nil }
        let start = u32(data, 4), end = u32(data, 8), chapter = u32(data, 12)
        let bytes = UInt64(u32(data, 16)) | UInt64(u32(data, 20)) << 32
        let quote = try string(data, at: 32, length: 512), path = try string(data, at: 544, length: 288), title = try string(data, at: 832, length: 96)
        guard let note = String(data: data[1184..<(data.count - 1)], encoding: .utf8), bytes > 0,
              start <= end, end <= 2 * 1024 * 1024, chapter < 32768, !title.isEmpty,
              let normalized = normalizedBookPath(path) else { throw ReadPicoReadingNotesError("阅读记录来源、UTF-8 正文或位置锚点无效。") }
        var ink: [ReadPicoReadingInkPoint] = []
        for i in 0..<Int(data[30]) {
            let at = 928 + i * 4, x = u16(data, at), y = u16(data, at + 2)
            guard (x & 0x7fff) <= 1023, y <= 1023 else { throw ReadPicoReadingNotesError("旧笔迹坐标无效。") }
            ink.append(.init(x: x, y: y))
        }
        let anchor = digest([normalized, String(bytes), String(chapter), String(start), String(end), String(kind.rawValue)])
        // The firmware can keep several distinct notes at one anchor. Preserve them;
        // re-importing the same source still deduplicates across object IDs/devices.
        let id = digest([anchor, quote, note, ink.map { "\($0.x),\($0.y)" }.joined(separator: ";")])
        return .init(id: id, anchorID: anchor, kind: kind, bookPath: path, sourceTitle: title, fileBytes: bytes,
                     chapter: chapter, start: start, end: end, quote: quote, note: note, ink: ink,
                     sourceDeviceIDs: deviceID.map { [$0] } ?? [], firstImportedAt: now, lastImportedAt: now)
    }
    private static func normalizedBookPath(_ path: String) -> String? {
        let name: Substring
        if path.hasPrefix("/sdcard/books/") { name = path.dropFirst(14) }
        else if path.hasPrefix("/sdcard/") { name = path.dropFirst(8) }
        else if path.hasPrefix("/flash/books/") { name = path.dropFirst(13) }
        else { return nil }
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
              ["txt", "epub"].contains(URL(fileURLWithPath: String(name)).pathExtension.lowercased()) else { return nil }
        return String(name)
    }
    private static func string(_ data: Data, at: Int, length: Int) throws -> String {
        let field = data[at..<(at + length)]
        guard let zero = field.firstIndex(of: 0), let value = String(data: data[at..<zero], encoding: .utf8) else { throw ReadPicoReadingNotesError("阅读记录字符串缺少终止符或包含无效 UTF-8。") }
        return value
    }
    fileprivate static func digest(_ pieces: [String]) -> String {
        // Length prefixes avoid ambiguous separators in user text/path values.
        var data = Data()
        for piece in pieces { data.append(Data("\(piece.utf8.count):".utf8)); data.append(Data(piece.utf8)) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func u16(_ data: Data, _ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
    private static func u32(_ data: Data, _ at: Int) -> UInt32 { UInt32(u16(data, at)) | UInt32(u16(data, at + 2)) << 16 }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb88320 & (0 &- (crc & 1))) } }
        return ~crc
    }
}

/// Mac-owned, atomic JSON database. Source cards are strictly read-only; removed reader records
/// remain in the local library until the user explicitly removes the Mac copy.
public actor ReadPicoReadingNotesStore {
    public static let shared = ReadPicoReadingNotesStore()
    public nonisolated let rootURL: URL
    private struct Permission: Codable { var includeNotes: Bool }
    private struct Cycle: Codable { var remaining: [String]; var previous: String? }
    private struct Database: Codable {
        var version = 1
        var notes: [ReadPicoReadingNote] = []
        var permissions: [String: [String: Permission]] = [:]
        var cycles: [String: Cycle] = [:]
    }
    public init(rootURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.rootURL = (rootURL ?? support.appendingPathComponent("Lingxi/ReadPicoReadingNotes", isDirectory: true)).standardizedFileURL
    }
    public func notes() throws -> [ReadPicoReadingNote] {
        try transaction { database in database.notes.sorted { $0.lastImportedAt > $1.lastImportedAt } }
    }
    public func importCard(rootURL: URL, deviceID: UUID? = nil) throws -> ReadPicoReadingNotesImportReport {
        try importFile(rootURL, deviceID: deviceID)
    }
    public func importFile(_ url: URL, deviceID: UUID? = nil) throws -> ReadPicoReadingNotesImportReport {
        let snapshot = try ReadPicoReadingNotesParser.read(from: url, deviceID: deviceID)
        return try apply(snapshot, policy: .merge)
    }
    public func prepareImport(_ url: URL, deviceID: UUID? = nil) throws -> ReadPicoReadingNotesSyncReview {
        let snapshot = try ReadPicoReadingNotesParser.read(from: url, deviceID: deviceID)
        return try transaction { database in
            let ids = Set(snapshot.notes.map(\.id)), localIDs = Set(database.notes.map(\.id))
            let sourceBooks = Set(snapshot.notes.map(\.bookPath))
            let related = database.notes.filter { sourceBooks.contains($0.bookPath) }
            let existingGroups = Dictionary(grouping: related, by: \.anchorID), incomingGroups = Dictionary(grouping: snapshot.notes, by: \.anchorID)
            let conflicting = Set(incomingGroups.keys.filter { anchor in
                guard let old = existingGroups[anchor], let new = incomingGroups[anchor] else { return false }
                return Set(old.map(\.id)) != Set(new.map(\.id))
            })
            return .init(snapshot: snapshot, localIDs: localIDs,
                         macOnlyCount: related.filter { !ids.contains($0.id) }.count,
                         picoOnlyCount: ids.subtracting(localIDs).count, sharedCount: ids.intersection(localIDs).count,
                         conflictingAnchors: conflicting)
        }
    }
    public func applyImport(_ review: ReadPicoReadingNotesSyncReview, policy: ReadPicoReadingNotesSyncPolicy) throws -> ReadPicoReadingNotesImportReport {
        try apply(review.snapshot, policy: policy, expectedIDs: review.localIDs, conflicts: review.conflictingAnchors)
    }
    private func apply(_ snapshot: ReadPicoReadingNotesParser.Snapshot, policy: ReadPicoReadingNotesSyncPolicy,
                       expectedIDs: Set<String>? = nil, conflicts: Set<String> = []) throws -> ReadPicoReadingNotesImportReport {
        return try transaction(write: true) { database in
            if let expectedIDs, Set(database.notes.map(\.id)) != expectedIDs { throw ReadPicoReadingNotesError("Mac 记录在预览后发生了变化，请重新核对同步差异。") }
            if policy == .preferPico, !conflicts.isEmpty {
                // Preserve the complete database before changing conflict visibility; source records stay read-only.
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let backupURL = rootURL.appendingPathComponent("before-reconciliation.json")
                var recoverable = database
                if FileManager.default.fileExists(atPath: backupURL.path) {
                    let values = try backupURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 256 * 1024 * 1024 else { throw ReadPicoReadingNotesError("冲突恢复文件不可用，已停止替换原记录。") }
                    let previous = try JSONDecoder().decode(Database.self, from: Data(contentsOf: backupURL))
                    guard previous.version == 1, previous.notes.count <= 50_000 else { throw ReadPicoReadingNotesError("冲突恢复文件无效，已停止替换原记录。") }
                    let ids = Set(recoverable.notes.map(\.id))
                    recoverable.notes.append(contentsOf: previous.notes.filter { !ids.contains($0.id) })
                }
                guard recoverable.notes.count <= 50_000 else { throw ReadPicoReadingNotesError("冲突恢复记录超过 5 万条，已停止替换原记录。") }
                try encoder.encode(recoverable).write(to: backupURL, options: .atomic)
                database.notes.removeAll { conflicts.contains($0.anchorID) }
                let remaining = Set(database.notes.map(\.id))
                database.permissions = database.permissions.mapValues { $0.filter { remaining.contains($0.key) } }
                database.cycles = [:]
            }
            var incoming = Set<String>(), imported = 0, duplicates = 0
            var positions = Dictionary(uniqueKeysWithValues: database.notes.enumerated().map { ($0.element.id, $0.offset) })
            for var note in snapshot.notes {
                if policy == .preferMac, conflicts.contains(note.anchorID) { duplicates += 1; continue }
                guard incoming.insert(note.id).inserted else { duplicates += 1; continue }
                if let position = positions[note.id] {
                    let existing = database.notes[position]
                    note.firstImportedAt = existing.firstImportedAt
                    note.sourceDeviceIDs = Array(Set(existing.sourceDeviceIDs + note.sourceDeviceIDs)).sorted { $0.uuidString < $1.uuidString }
                    database.notes[position] = note; duplicates += 1
                } else {
                    positions[note.id] = database.notes.count; database.notes.append(note); imported += 1
                }
            }
            guard database.notes.count <= 50_000 else { throw ReadPicoReadingNotesError("Mac 阅读资料库已达到 5 万条上限。") }
            return .init(imported: imported, duplicates: duplicates, total: database.notes.count,
                         sourceURL: snapshot.sourceURL, usedBackup: snapshot.usedBackup)
        }
    }
    /// Recovery merges the previous local database back; it never removes newly imported notes or modifies the reader.
    public func restoreBeforeReconciliation() throws -> Int {
        try transaction(write: true) { database in
            let url = rootURL.appendingPathComponent("before-reconciliation.json")
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 256 * 1024 * 1024 else { throw ReadPicoReadingNotesError("没有可恢复的同步前记录。") }
            let previous = try JSONDecoder().decode(Database.self, from: Data(contentsOf: url))
            guard previous.version == 1, previous.notes.count <= 50_000 else { throw ReadPicoReadingNotesError("同步前记录无效，当前资料保留。") }
            let ids = Set(database.notes.map(\.id)), restoring = previous.notes.filter { !ids.contains($0.id) }
            guard database.notes.count + restoring.count <= 50_000 else { throw ReadPicoReadingNotesError("恢复后记录超过 5 万条上限，请先导出整理。") }
            database.notes.append(contentsOf: restoring)
            // Restored private notes are not automatically re-authorized for display cards.
            database.cycles = [:]
            return restoring.count
        }
    }
    public func authorization(target: String) throws -> [String: Bool] {
        try validateTarget(target)
        return try transaction { database in database.permissions[target]?.mapValues(\.includeNotes) ?? [:] }
    }
    public func setAuthorization(noteIDs: Set<String>, target: String, includeNotes: Bool) throws {
        try validateTarget(target)
        try transaction(write: true) { database in
            let valid = Set(database.notes.map(\.id))
            guard noteIDs.isSubset(of: valid) else { throw ReadPicoReadingNotesError("所选阅读记录已经变化，请刷新后重试。") }
            for id in noteIDs { database.permissions[target, default: [:]][id] = Permission(includeNotes: includeNotes) }
            database.cycles = database.cycles.filter { !$0.key.hasPrefix(target + ":") }
        }
    }
    public func removeAuthorization(noteIDs: Set<String>, target: String) throws {
        try validateTarget(target)
        try transaction(write: true) { database in
            for id in noteIDs { database.permissions[target]?.removeValue(forKey: id) }
            database.cycles = database.cycles.filter { !$0.key.hasPrefix(target + ":") }
        }
    }
    public func removeFromMac(noteIDs: Set<String>) throws {
        try transaction(write: true) { database in
            database.notes.removeAll { noteIDs.contains($0.id) }
            for target in Array(database.permissions.keys) { for id in noteIDs { database.permissions[target]?.removeValue(forKey: id) } }
            database.cycles.removeAll()
        }
    }
    /// Called by the actual device scheduler, not the preview drawing path.
    /// The persisted queue prevents repetition within a cycle, including app restarts.
    public func nextCard(target: String, instance: String = "default") throws -> ReadPicoReadingCard? {
        try validateTarget(target)
        guard !instance.isEmpty, instance.utf8.count <= 256 else { throw ReadPicoReadingNotesError("卡片实例标识无效。") }
        return try transaction(write: true) { database in
            let allowed = database.permissions[target] ?? [:]
            let pool = database.notes.filter { allowed[$0.id] != nil && !$0.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !pool.isEmpty else { return nil }
            let key = target + ":" + ReadPicoReadingNotesParser.digest([instance])
            let validIDs = Set(pool.map(\.id))
            var cycle = database.cycles[key] ?? Cycle(remaining: [], previous: nil)
            cycle.remaining = cycle.remaining.filter { validIDs.contains($0) }
            if cycle.remaining.isEmpty {
                cycle.remaining = pool.map(\.id).shuffled()
                if cycle.remaining.count > 1, cycle.remaining.first == cycle.previous { cycle.remaining.swapAt(0, 1) }
            }
            let id = cycle.remaining.removeFirst(); cycle.previous = id; database.cycles[key] = cycle
            guard let item = pool.first(where: { $0.id == id }) else { return nil }
            let privateNote = allowed[id]?.includeNotes == true && !item.note.isEmpty ? item.note : nil
            return .init(id: item.id, quote: item.quote, body: item.quote, sourceTitle: item.sourceTitle + " · 第 \(item.chapter + 1) 节", note: privateNote)
        }
    }
    private func validateTarget(_ target: String) throws {
        guard UUID(uuidString: target) != nil else { throw ReadPicoReadingNotesError("请选择真实设备后配置阅读卡片。") }
    }
    private func transaction<T>(write: Bool = false, _ operation: (inout Database) throws -> T) throws -> T {
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        guard try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink != true else { throw ReadPicoReadingNotesError("阅读资料库目录不能是符号链接。") }
        let lockURL = rootURL.appendingPathComponent(".notes.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ReadPicoReadingNotesError("无法锁定 Mac 阅读资料库。") }
        defer { _ = close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ReadPicoReadingNotesError("Mac 阅读资料库正被占用。") }
        defer { _ = flock(fd, LOCK_UN) }
        let url = rootURL.appendingPathComponent("notes.json")
        var database = Database()
        if fm.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 256 * 1024 * 1024 else { throw ReadPicoReadingNotesError("Mac 阅读资料库文件无效；原资料保留。") }
            database = try JSONDecoder().decode(Database.self, from: Data(contentsOf: url))
            guard database.version == 1, database.notes.count <= 50_000, Set(database.notes.map(\.id)).count == database.notes.count else { throw ReadPicoReadingNotesError("Mac 阅读资料库版本或索引无效；未重建原资料。") }
        }
        let result = try operation(&database)
        if write {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(database)
            guard data.count <= 256 * 1024 * 1024 else { throw ReadPicoReadingNotesError("Mac 阅读资料库超过大小上限。") }
            try data.write(to: url, options: .atomic)
        }
        return result
    }
}
