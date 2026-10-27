import AppKit
import Combine
import Darwin
import Foundation
import LinxDisplayCore

/// Saved, editable boards belong to one physical-device UUID. Selecting never transmits a frame.
/// 每台设备有独立可编辑画板库；切换本地画板不会自动推送，也不改其他设备内容。
@MainActor
final class ReadPicoBoardLibrary: ObservableObject {
    struct Board: Codable, Equatable, Identifiable {
        let id: UUID
        var name: String
        var includedInCarousel = true
        var durationSeconds = 30

        init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
        private enum CodingKeys: String, CodingKey { case id, name, includedInCarousel, durationSeconds }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            includedInCarousel = try values.decodeIfPresent(Bool.self, forKey: .includedInCarousel) ?? true
            durationSeconds = try values.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 30
        }
    }

    private struct Index: Codable, Equatable {
        var version = 1
        let deviceID: UUID
        var boards: [Board] = []
        var selectedID: UUID?
        var carouselEnabled = false
    }

    static let maximumBoards = 32
    @Published private(set) var boards: [Board] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var carouselEnabled = false
    let deviceID: UUID
    let directoryURL: URL

    var selectedBoard: Board? { boards.first { $0.id == selectedID } }
    var carouselBoards: [Board] { boards.filter(\.includedInCarousel) }

    private let fileManager: FileManager
    private let beforeIndexCommit: (() throws -> Void)?
    private var index: Index
    private var loadedData: Data?
    private var loaded = false
    private weak var activeDraft: ReadPicoCanvasDraft?
    private var indexURL: URL { directoryURL.appendingPathComponent("index.json") }
    private static let maximumIndexBytes = 64 * 1024

    /// rootURL is the library root, not a device folder. The commit hook supports deterministic disk-failure tests.
    /// rootURL为画板库根目录，内部始终再拼设备UUID；提交前钩子仅供确定性磁盘失败测试。
    init(deviceID: UUID, rootURL: URL? = nil, fileManager: FileManager = .default,
         beforeIndexCommit: (() throws -> Void)? = nil) {
        self.deviceID = deviceID
        self.fileManager = fileManager
        self.beforeIndexCommit = beforeIndexCommit
        let root = rootURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LingxiPicoBoards", isDirectory: true)
        directoryURL = root.appendingPathComponent(deviceID.uuidString, isDirectory: true)
        index = Index(deviceID: deviceID)
    }

    /// Fully decode the selected file before changing either observable state or the active draft.
    /// 先完整解码选中文件，成功后才改变列表与草稿；首次空库不创建示例或清除现有输入。
    func load(into active: ReadPicoCanvasDraft) throws {
        try withLock {
            let data = try readIndexData()
            let candidateIndex = try decodeIndex(data)
            let candidate = try candidateIndex.selectedID.map { try readBoard($0) }
            index = candidateIndex; loadedData = data; loaded = true
            publish()
            if let candidate { active.adoptValidatedDraft(candidate) }
            activeDraft = active
        }
    }

    /// All document work is staged on an independent instance, so a failed save never clears live dirty state.
    /// 所有文档处理先在独立实例暂存；保存失败不会提前清除当前草稿的未保存状态。
    func saveCurrent(_ active: ReadPicoCanvasDraft) throws {
        try withLock {
            try requireFresh()
            guard let id = index.selectedID, let position = index.boards.firstIndex(where: { $0.id == id }) else {
                throw invalid("请先新建或选择一张画板。")
            }
            let name = try validName(active.board.name)
            let staged = try stage(active, name: name)
            defer { try? fileManager.removeItem(at: staged.url) }
            var next = index; next.boards[position].name = name
            try replaceDocument(staged.url, id: id, next: next)
            active.adoptValidatedDraft(staged.draft); activeDraft = active
        }
    }

    @discardableResult
    func create(name: String = "新画板", from source: ReadPicoCanvasDraft? = nil,
                into active: ReadPicoCanvasDraft) throws -> UUID {
        try withLock {
            try requireFresh(); try requireRoom()
            let blank = ReadPicoCanvasDraft(); blank.canvasMode = 2
            return try insert(source ?? blank, name: validName(name), into: active)
        }
    }

    @discardableResult
    func importDraft(from sourceURL: URL, name: String? = nil,
                     into active: ReadPicoCanvasDraft) throws -> UUID {
        // The external source is read only. Validation finishes before touching the owned library.
        // 用户原文件只读；先验证，再向自有目录复制，失败不改变当前草稿。
        let candidate = ReadPicoCanvasDraft()
        try candidate.load(from: sourceURL)
        let title = try validName(name ?? candidate.board.name)
        return try withLock {
            try requireFresh(); try requireRoom()
            return try insert(candidate, name: title, into: active)
        }
    }

    func select(_ id: UUID, into active: ReadPicoCanvasDraft) throws {
        try withLock {
            try requireFresh(); try requireBoard(id)
            let candidate = try readBoard(id)
            var next = index; next.selectedID = id
            try commit(next)
            active.adoptValidatedDraft(candidate); activeDraft = active
        }
    }

    /// Read an independent saved snapshot for preview/carousel; it never changes the user's current editor.
    /// 预览/轮播读取独立已保存快照，不切换或覆盖用户正在编辑的草稿。
    func loadBoard(_ id: UUID) throws -> ReadPicoCanvasDraft {
        try withLock { try requireFresh(); try requireBoard(id); return try readBoard(id) }
    }

    func rename(_ id: UUID, to requestedName: String) throws {
        try withLock {
            try requireFresh(); try requireBoard(id)
            let name = try validName(requestedName)
            guard let position = index.boards.firstIndex(where: { $0.id == id }), index.boards[position].name != name else { return }
            let candidate = try readBoard(id)
            let staged = try stage(candidate, name: name)
            defer { try? fileManager.removeItem(at: staged.url) }
            var next = index; next.boards[position].name = name
            try replaceDocument(staged.url, id: id, next: next)
            if selectedID == id, let active = activeDraft {
                if active.hasUnsavedLocalChanges { active.board.name = name }
                else { active.adoptValidatedDraft(staged.draft) }
            }
        }
    }

    @discardableResult
    func duplicate(_ id: UUID, into active: ReadPicoCanvasDraft? = nil) throws -> UUID {
        try withLock {
            try requireFresh(); try requireBoard(id); try requireRoom()
            let source = try readBoard(id)
            let oldName = index.boards.first { $0.id == id }!.name
            let name = String(oldName.prefix(60)) + " 副本"
            return try insert(source, name: validName(name), into: active, after: id)
        }
    }

    func remove(_ id: UUID, into active: ReadPicoCanvasDraft) throws {
        try withLock {
            try requireFresh(); try requireBoard(id)
            let position = index.boards.firstIndex { $0.id == id }!
            var next = index; next.boards.remove(at: position)
            var candidate: ReadPicoCanvasDraft?
            if next.selectedID == id {
                next.selectedID = next.boards.isEmpty ? nil : next.boards[min(position, next.boards.count - 1)].id
                if let nextID = next.selectedID { candidate = try readBoard(nextID) }
                else {
                    let blank = ReadPicoCanvasDraft()
                    let staged = try stage(blank)
                    candidate = staged.draft; try? fileManager.removeItem(at: staged.url)
                }
            }
            try commit(next)
            if let candidate { active.adoptValidatedDraft(candidate); activeDraft = active }
            // Only our UUID-named copy is eligible for cleanup. A cleanup failure leaves an unindexed file, never a lost active board.
            // 只清理自有UUID副本；清理失败只留下无索引文件，不删除原稿或其他设备内容。
            try? fileManager.removeItem(at: documentURL(id))
        }
    }

    func reorder(_ ids: [UUID]) throws {
        try withLock {
            try requireFresh()
            guard ids.count == index.boards.count, Set(ids).count == ids.count,
                  Set(ids) == Set(index.boards.map(\.id)) else { throw invalid("画板顺序必须包含当前全部画板，且不能重复。") }
            let values = Dictionary(uniqueKeysWithValues: index.boards.map { ($0.id, $0) })
            var next = index; next.boards = ids.map { values[$0]! }; try commit(next)
        }
    }

    func setIncludedInCarousel(_ id: UUID, included: Bool) throws {
        try updateMetadata(id) { $0.includedInCarousel = included }
    }
    func setCarouselDuration(_ id: UUID, seconds: Int) throws {
        guard (5...3600).contains(seconds) else { throw invalid("每张画板的停留时间应为5至3600秒。") }
        try updateMetadata(id) { $0.durationSeconds = seconds }
    }
    func setCarouselEnabled(_ enabled: Bool) throws {
        try withLock { try requireFresh(); var next = index; next.carouselEnabled = enabled; try commit(next) }
    }
    func nextCarouselID(after id: UUID?) -> UUID? {
        guard carouselEnabled, !carouselBoards.isEmpty else { return nil }
        let values = carouselBoards
        guard let id, let position = values.firstIndex(where: { $0.id == id }) else { return values.first?.id }
        return values[(position + 1) % values.count].id
    }

    private func updateMetadata(_ id: UUID, _ change: (inout Board) -> Void) throws {
        try withLock {
            try requireFresh(); try requireBoard(id)
            var next = index; change(&next.boards[next.boards.firstIndex { $0.id == id }!]); try commit(next)
        }
    }
    private func documentURL(_ id: UUID) -> URL { directoryURL.appendingPathComponent(id.uuidString + ".picocanvas") }
    private func requireBoard(_ id: UUID) throws {
        guard index.boards.contains(where: { $0.id == id }) else { throw invalid("画板已被移除，请重新载入列表。") }
    }
    private func requireRoom() throws {
        guard index.boards.count < Self.maximumBoards else { throw invalid("每台小纸 Pico 最多保存32张画板。") }
    }
    private func validName(_ requested: String) throws -> String {
        let name = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256 else { throw invalid("画板名称不能为空，且不能超过256字节。") }
        return name
    }
    private func publish() {
        boards = index.boards; selectedID = index.selectedID; carouselEnabled = index.carouselEnabled
    }
    private func invalid(_ message: String) -> ReadPicoManagerError { .invalid(message) }

    private func readIndexData() throws -> Data? {
        guard fileManager.fileExists(atPath: indexURL.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: indexURL); defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumIndexBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= Self.maximumIndexBytes else { throw invalid("画板目录文件为空或超过限制。") }
        return data
    }
    private func decodeIndex(_ data: Data?) throws -> Index {
        guard let data else { return Index(deviceID: deviceID) }
        let value = try JSONDecoder().decode(Index.self, from: data)
        guard value.version == 1, value.deviceID == deviceID, value.boards.count <= Self.maximumBoards,
              Set(value.boards.map(\.id)).count == value.boards.count,
              (value.boards.isEmpty ? value.selectedID == nil : value.boards.contains { $0.id == value.selectedID }) else {
            throw invalid("画板目录版本、设备编号或选择状态无效，现有画板未改动。")
        }
        for board in value.boards {
            _ = try validName(board.name)
            guard (5...3600).contains(board.durationSeconds) else { throw invalid("画板轮播时间无效。") }
        }
        return value
    }
    private func requireFresh() throws {
        guard loaded else { throw invalid("请先载入当前设备的画板库。") }
        guard try readIndexData() == loadedData else { throw invalid("画板库已在其他窗口更新，请重新载入后再操作。") }
    }
    private func readBoard(_ id: UUID) throws -> ReadPicoCanvasDraft {
        let draft = ReadPicoCanvasDraft(); try draft.load(from: documentURL(id)); return draft
    }
    private func commit(_ next: Index) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= Self.maximumIndexBytes else { throw invalid("画板目录超过大小限制。") }
        if data != loadedData {
            try requireFresh(); try beforeIndexCommit?(); try data.write(to: indexURL, options: .atomic)
        }
        index = next; loadedData = data; publish()
    }

    /// Save a value copy through the actual document codec; adoptValidatedDraft then establishes a validated saved baseline.
    /// 值副本经过真实文档保存器校验，再用adoptValidatedDraft建立已保存基线。
    private func stage(_ source: ReadPicoCanvasDraft, name: String? = nil) throws -> (draft: ReadPicoCanvasDraft, url: URL) {
        let copy = ReadPicoCanvasDraft()
        copy.landscape = source.landscape; copy.dither = source.dither
        copy.image = source.image; copy.imageSource = source.imageSource
        copy.wallpaperAssetID = source.wallpaperAssetID; copy.wallpaperEditData = source.wallpaperEditData
        copy.strokes = source.strokes; copy.liveStroke = source.liveStroke; copy.canvasMode = source.canvasMode
        copy.board = source.board; copy.playlist = source.playlist
        if let name { copy.board.name = name }
        let url = directoryURL.appendingPathComponent(".stage-" + UUID().uuidString + ".picocanvas")
        do { try copy.save(to: url) }
        catch { try? fileManager.removeItem(at: url); throw error }
        return (copy, url)
    }
    @discardableResult
    private func insert(_ source: ReadPicoCanvasDraft, name: String, into active: ReadPicoCanvasDraft?, after id: UUID? = nil) throws -> UUID {
        let board = Board(name: name), staged = try stage(source, name: name)
        defer { try? fileManager.removeItem(at: staged.url) }
        let target = documentURL(board.id)
        try moveAtomically(staged.url, to: target)
        do {
            var next = index
            if let id, let position = next.boards.firstIndex(where: { $0.id == id }) { next.boards.insert(board, at: position + 1) }
            else { next.boards.append(board) }
            if active != nil || next.selectedID == nil { next.selectedID = board.id }
            try commit(next)
        } catch { try? fileManager.removeItem(at: target); throw error }
        if let active { active.adoptValidatedDraft(staged.draft); activeDraft = active }
        return board.id
    }
    /// Keep the old inode until its matching index commits. Restoring a hard link needs no large in-memory image copy.
    /// 索引成功提交前保留旧inode；失败用硬链接恢复，不复制大幅图片到内存。
    private func replaceDocument(_ staged: URL, id: UUID, next: Index) throws {
        if next == index { try moveAtomically(staged, to: documentURL(id)); return }
        let target = documentURL(id), backup = directoryURL.appendingPathComponent(".rollback-" + UUID().uuidString)
        guard Darwin.link(target.path, backup.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var preserveBackup = false
        do {
            try moveAtomically(staged, to: target)
            do { try commit(next) }
            catch {
                let originalError = error
                do { try moveAtomically(backup, to: target) }
                catch {
                    preserveBackup = true
                    throw invalid("画板索引保存失败，旧原稿保留在：" + backup.path)
                }
                throw originalError
            }
        } catch {
            if !preserveBackup { try? fileManager.removeItem(at: backup) }
            throw error
        }
        try? fileManager.removeItem(at: backup)
    }
    private func moveAtomically(_ source: URL, to target: URL) throws {
        guard Darwin.rename(source.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private func withLock<T>(_ action: () throws -> T) throws -> T {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let lockURL = directoryURL.appendingPathComponent(".lock")
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
}
