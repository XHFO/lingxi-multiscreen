import Foundation
import LinxDisplayCore

/// A value-based playlist is separate from the module IDs composing one screen.
/// Duplicate module types are intentional; only instance UUIDs must be unique.
struct ReadPicoBoardPlaylist: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case composition, carousel
        var id: String { rawValue }
        var title: String { self == .composition ? "组合画板" : "模块轮播" }
    }
    static let maximumItems = 32
    static let maximumEmbeddedBytes = 16 * 1024 * 1024
    var mode: Mode = .composition
    var items: [ReadPicoBoardPlaylistItem] = []
    var enabledItems: [ReadPicoBoardPlaylistItem] { items.filter(\.enabled) }

    func validate() throws {
        guard items.count <= Self.maximumItems, Set(items.map(\.id)).count == items.count else {
            throw ReadPicoBoardPlaylistError.invalid("轮播最多添加 32 项，每个实例需要独立编号。")
        }
        var bytes = 0
        for item in items {
            try item.validate()
            bytes += item.imageSourcePNG?.count ?? 0
            guard bytes <= Self.maximumEmbeddedBytes else {
                throw ReadPicoBoardPlaylistError.invalid("轮播中的图片原稿合计超过 16 MB，请减少图片或缩小原稿。")
            }
        }
    }
    /// Call after the preceding display receipt. Nil starts at the first enabled item.
    func item(after id: UUID?) -> ReadPicoBoardPlaylistItem? {
        let enabled = enabledItems
        guard !enabled.isEmpty else { return nil }
        guard let id, let index = enabled.firstIndex(where: { $0.id == id }) else { return enabled.first }
        return enabled[(index + 1) % enabled.count]
    }
    func item(id: UUID?) -> ReadPicoBoardPlaylistItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }
    @discardableResult mutating func add(module: Int, name: String,
                                        configuration: ReadPicoLingxiBoardConfiguration? = nil) -> UUID? {
        guard items.count < Self.maximumItems, ReadPicoBoardPlaylistItem.supports(module) else { return nil }
        let item = ReadPicoBoardPlaylistItem(module: module, name: name, configuration: configuration)
        items.append(item)
        return item.id
    }
    @discardableResult mutating func duplicate(_ id: UUID) -> UUID? {
        guard items.count < Self.maximumItems, let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let imageBytes = items.reduce(0) { $0 + ($1.imageSourcePNG?.count ?? 0) }
        guard imageBytes + (items[index].imageSourcePNG?.count ?? 0) <= Self.maximumEmbeddedBytes else { return nil }
        var copy = items[index]
        copy.id = UUID()
        copy.name = String((copy.name + " 副本").prefix(60))
        items.insert(copy, at: index + 1)
        return copy.id
    }
    mutating func move(_ id: UUID, by amount: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + amount) else { return }
        let item = items.remove(at: index)
        items.insert(item, at: index + amount)
    }
    mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    /// Splits the existing composition into independently editable full-screen instances.
    static func fromComposition(_ board: ReadPicoLingxiBoardConfiguration) -> Self {
        var result = Self(); result.mode = .carousel
        result.items = board.modules.filter(ReadPicoBoardPlaylistItem.supports).map { module in
            ReadPicoBoardPlaylistItem(module: module, name: "模块 \(module)", configuration: board)
        }
        return result
    }
}

struct ReadPicoBoardPlaylistItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var enabled = true
    var durationSeconds = 30
    var module: Int
    var configuration: ReadPicoLingxiBoardConfiguration
    var imageAssetID: UUID?
    var imageEditData: Data?
    /// Portable bounded source for reopening .picocanvas without the Mac library.
    var imageSourcePNG: Data?

    init(module: Int, name: String, configuration: ReadPicoLingxiBoardConfiguration? = nil) {
        self.module = module; self.name = name
        var value = configuration ?? ReadPicoLingxiBoardConfiguration()
        value.modules = [module]; value.columns = 1
        value.fullWidthModules = []; value.intervalSeconds = -1
        self.configuration = value
    }
    static func supports(_ module: Int) -> Bool {
        guard let value = CanvasModule(rawValue: module) else { return false }
        return value != .excerptText
    }
    var configurationForRendering: ReadPicoLingxiBoardConfiguration {
        var value = configuration
        value.modules = [module]; value.columns = 1; value.fullWidthModules = []
        return value
    }
    func validate() throws {
        guard Self.supports(module), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 256, (1...3600).contains(durationSeconds),
              configuration.modules == [module], (imageEditData?.count ?? 0) <= 16_384,
              (imageSourcePNG?.count ?? 0) <= ReadPicoBoardPlaylist.maximumEmbeddedBytes,
              imageEditData == nil || imageAssetID != nil || imageSourcePNG != nil else {
            throw ReadPicoBoardPlaylistError.invalid("轮播项配置无效：请检查名称、停留时间和图片原稿。")
        }
        try configuration.validate()
    }
}

enum ReadPicoBoardPlaylistError: LocalizedError {
    case invalid(String), imageLoading
    var errorDescription: String? {
        switch self { case .invalid(let message): message; case .imageLoading: "正在准备轮播图片，请等原图加载完成后再预览。" }
    }
}
