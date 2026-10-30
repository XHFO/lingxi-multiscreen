import Foundation
import CryptoKit

/// Semantic board content. Geometry, typography and orientation belong to the reader.
public struct ReadPicoBoardModel: Codable, Equatable, Sendable {
    public static let maximumBytes = 65_536
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case clock, date, cpu, memory, disk, network, pomodoro, uptime, text, image, codex, sspai, weather, cloudflare, formlabs
        case nowPlaying = "now_playing", qwenQuota = "qwen_quota", oracleText = "oracle_text"
        case homeAssistant = "home_assistant", bambuLab = "bambu_lab", readingExcerpt = "reading_excerpt", grokBot = "grok_bot"
    }
    public struct Metric: Codable, Equatable, Sendable {
        public var label: String, value: String, unit: String
        public init(_ label: String, _ value: String, _ unit: String = "") { self.label = label; self.value = value; self.unit = unit }
    }
    public struct Row: Codable, Equatable, Sendable {
        public var label: String, value: String
        public init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }
    public enum MediaLayout: String, Codable, Sendable { case horizontal, vertical }
    public enum Presentation: String, Codable, Sendable { case worldMap, ranking }
    public enum RankMetric: String, Codable, Sendable { case requests, traffic }
    public struct Region: Codable, Equatable, Sendable {
        public var code: String, value: Double
        public init(code: String, value: Double) { self.code = code; self.value = value }
    }
    public struct Module: Codable, Equatable, Sendable {
        public var kind: Kind, id: String, title: String, subtitle: String, body: String, footer: String
        public var metrics: [Metric], rows: [Row], series: [Double]
        public var timestamp: Double?, duration: Double?, progress: Double?, asset: String?
        public var running: Bool = false
        public var span: Int?
        public var mediaLayout: MediaLayout?
        public var presentation: Presentation?
        public var rankMetric: RankMetric?
        public var regions: [Region]?
        enum CodingKeys: String, CodingKey {
            case kind, id, title, subtitle, body, footer, metrics, rows, series, timestamp, duration, progress, asset, running, span
            case mediaLayout = "media_layout", presentation, rankMetric = "rank_metric", regions
        }
        public init(kind: Kind, id: String, title: String = "", subtitle: String = "", body: String = "", footer: String = "",
                    metrics: [Metric] = [], rows: [Row] = [], series: [Double] = [], timestamp: Double? = nil,
                    duration: Double? = nil, progress: Double? = nil, asset: String? = nil) {
            self.kind = kind; self.id = id; self.title = title; self.subtitle = subtitle; self.body = body; self.footer = footer
            self.metrics = metrics; self.rows = rows; self.series = series; self.timestamp = timestamp
            self.duration = duration; self.progress = progress; self.asset = asset
        }
    }
    public struct Asset: Codable, Equatable, Sendable {
        public var id: String, width: Int, height: Int, format: String, data: String
        public init(width: Int, height: Int, pixels: Data) {
            self.width = width; self.height = height; format = "gray4"
            id = Self.digest(pixels); data = pixels.base64EncodedString()
        }
        public static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    }
    public var schema: Int = 1
    public var boardID: String
    public var generatedAt: Double
    public var columns: Int
    public var dark: Bool
    public var textScale: Int?
    public var worldMap: String?
    public var modules: [Module]
    public var assets: [Asset]
    enum CodingKeys: String, CodingKey { case schema, boardID = "board_id", generatedAt = "generated_at", columns, dark, textScale = "text_scale", worldMap = "world_map", modules, assets }
    public init(boardID: String, generatedAt: Double, columns: Int = 1, dark: Bool = false, textScale: Int? = nil, worldMap: String? = nil,
                modules: [Module], assets: [Asset] = []) {
        self.boardID = boardID; self.generatedAt = generatedAt; self.columns = columns
        self.dark = dark; self.textScale = textScale; self.worldMap = worldMap; self.modules = modules; self.assets = assets
    }
    public var needsWorldMap: Bool { modules.contains { $0.kind == .cloudflare && ($0.presentation ?? .worldMap) == .worldMap } }
    public static func isModel(_ data: Data) -> Bool { data.first == UInt8(ascii: "{") }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw invalid("画板数据超过 64 KB，请减少模块或图片。") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(); return value
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maximumBytes else { throw Self.invalid("画板数据超过 64 KB，请减少模块或图片。") }
        return bytes
    }
    /// Time of transmission must not make an otherwise unchanged board upload again.
    public func semanticData() throws -> Data {
        var copy = self; copy.generatedAt = 0
        for index in copy.modules.indices where copy.modules[index].kind == .clock || copy.modules[index].kind == .date {
            copy.modules[index].timestamp = 0; copy.modules[index].body = ""
        }
        return try copy.encoded()
    }
    public func validate() throws {
        func bounded(_ text: String, _ limit: Int) -> Bool {
            text.utf8.count <= limit && !text.unicodeScalars.contains { $0.value == 0 }
        }
        guard schema == 1, bounded(boardID, 64), !boardID.isEmpty, generatedAt.isFinite, generatedAt >= 0,
              (1...2).contains(columns), textScale.map({ (2...4).contains($0) }) ?? true, (1...12).contains(modules.count), assets.count <= 8,
              Set(modules.map(\.id)).count == modules.count, Set(assets.map(\.id)).count == assets.count else {
            throw Self.invalid("画板结构或模块数量不受支持。")
        }
        guard (worldMap != nil) == needsWorldMap else { throw Self.invalid("全球热区必须附带同源地图，其他卡片不接受多余地图数据。") }
        if let worldMap {
            guard let bytes = Data(base64Encoded: worldMap), bytes.base64EncodedString() == worldMap,
                  !bytes.isEmpty, bytes.count <= 8192 else { throw Self.invalid("世界地图数据损坏或超过 8 KB。") }
        }
        var total = 0
        for asset in assets {
            guard (1...192).contains(asset.width), (1...192).contains(asset.height), asset.format == "gray4",
                  let raw = Data(base64Encoded: asset.data), raw.base64EncodedString() == asset.data,
                  raw.count == ((asset.width + 1) / 2) * asset.height, raw.count <= 18_432,
                  Asset.digest(raw) == asset.id else { throw Self.invalid("图片素材损坏或超过设备尺寸限制。") }
            total += raw.count
        }
        guard total <= 32_768 else { throw Self.invalid("画板图片素材超过 32 KB，请减少图片。") }
        let ids = Set(assets.map(\.id))
        for module in modules {
            guard !module.id.isEmpty, bounded(module.id, 64), bounded(module.title, 192), bounded(module.subtitle, 384),
                  bounded(module.body, 8192), bounded(module.footer, 384), module.metrics.count <= 8, module.rows.count <= 24,
                  module.series.count <= 60, module.series.allSatisfy(\.isFinite),
                  module.span.map({ (1...2).contains($0) }) ?? true,
                  (module.regions?.count ?? 0) <= 250,
                  (module.mediaLayout == nil || module.kind == .nowPlaying),
                  (module.kind == .cloudflare || (module.presentation == nil && module.rankMetric == nil && module.regions == nil)),
                  Set((module.regions ?? []).map(\.code)).count == (module.regions?.count ?? 0),
                  module.regions?.allSatisfy({ !$0.code.isEmpty && bounded($0.code, 32) && $0.code.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) && $0.value.isFinite && (0...1e30).contains($0.value) }) ?? true,
                  module.metrics.allSatisfy({ bounded($0.label, 96) && bounded($0.value, 96) && bounded($0.unit, 32) }),
                  module.rows.allSatisfy({ bounded($0.label, 96) && bounded($0.value, 256) }),
                  module.timestamp.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  module.duration.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  module.progress.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
                  module.asset.map(ids.contains) ?? (module.kind != .image) else {
                throw Self.invalid("画板模块内容超过设备限制，或引用了缺失的图片素材。")
            }
        }
    }
    private static func invalid(_ message: String) -> ReadPicoManagerError { .invalid(message) }
}
