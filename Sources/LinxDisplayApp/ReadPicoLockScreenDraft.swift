import AppKit
import Combine
import ImageIO
import LinxDisplayCore

struct ReadPicoLockScreenOptions: Codable, Equatable, Sendable {
    enum Output: String, Codable, CaseIterable, Identifiable {
        case automatic, gray16, monochrome
        var id: String { rawValue }
        var title: String { switch self { case .automatic: return "自动匹配设备"; case .gray16: return "原生 16 灰阶"; case .monochrome: return "黑白 · 1 位" } }
    }
    enum Mode: String, Codable, CaseIterable, Identifiable { case image, ascii
        var id: String { rawValue }
        var title: String { self == .image ? "图片" : "ASCII 字符画" }
    }
    enum Layout: String, Codable, CaseIterable, Identifiable { case fit, fill
        var id: String { rawValue }
        var title: String { self == .fit ? "完整显示" : "填满屏幕" }
    }
    enum Gray: String, Codable, CaseIterable, Identifiable {
        case luminosity, average, lightness, red, green, blue
        var id: String { rawValue }
        var title: String {
            switch self { case .luminosity: return "亮度加权"; case .average: return "平均值"; case .lightness: return "明度法"; case .red: return "红通道"; case .green: return "绿通道"; case .blue: return "蓝通道" }
        }
    }
    enum Dither: String, Codable, CaseIterable, Identifiable {
        case threshold, ordered, floydSteinberg, atkinson, burkes, sierra2, stucki, jarvisJudiceNinke
        var id: String { rawValue }
        var title: String {
            switch self { case .threshold: return "黑白阈值"; case .ordered: return "有序抖动 · Bayer"; case .floydSteinberg: return "误差扩散 · Floyd–Steinberg"; case .atkinson: return "误差扩散 · Atkinson"; case .burkes: return "误差扩散 · Burkes"; case .sierra2: return "误差扩散 · Sierra2"; case .stucki: return "误差扩散 · Stucki"; case .jarvisJudiceNinke: return "误差扩散 · Jarvis–Judice–Ninke" }
        }
    }
    var landscape = false
    var output: Output = .automatic
    var mode: Mode = .image
    var gray: Gray = .luminosity
    var dither: Dither = .floydSteinberg
    var layout: Layout = .fit
    var zoom = 1.0
    /// Fractions of the final canvas; positive X moves right, positive Y moves down.
    var offsetX = 0.0
    var offsetY = 0.0
    var asciiCellSize = 12
    /// Optional native composition; nil retains the original v1 geometry exactly.
    /// Kept opaque so standalone draft tests and consumers do not depend on UI types.
    var photoEditData: Data?
    var wallpaperAssetID: UUID?
    var width: Int { landscape ? 1216 : 684 }
    var height: Int { landscape ? 684 : 1216 }
    var isValid: Bool { (photoEditData.map { !$0.isEmpty && $0.count <= 16 * 1024 && (try? JSONSerialization.jsonObject(with: $0)) is [String: Any] } ?? true) && zoom.isFinite && (0.25...4).contains(zoom) && offsetX.isFinite && (-1...1).contains(offsetX) && offsetY.isFinite && (-1...1).contains(offsetY) && (8...32).contains(asciiCellSize) }
    init() {}
    private enum CodingKeys: String, CodingKey { case landscape, output, mode, gray, dither, layout, zoom, offsetX, offsetY, asciiCellSize, photoEditData, wallpaperAssetID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        landscape = try values.decode(Bool.self, forKey: .landscape)
        output = try values.decodeIfPresent(Output.self, forKey: .output) ?? .monochrome
        mode = try values.decode(Mode.self, forKey: .mode); gray = try values.decode(Gray.self, forKey: .gray)
        dither = try values.decode(Dither.self, forKey: .dither); layout = try values.decode(Layout.self, forKey: .layout)
        zoom = try values.decode(Double.self, forKey: .zoom); offsetX = try values.decode(Double.self, forKey: .offsetX)
        offsetY = try values.decode(Double.self, forKey: .offsetY); asciiCellSize = try values.decode(Int.self, forKey: .asciiCellSize)
        photoEditData = try values.decodeIfPresent(Data.self, forKey: .photoEditData)
        wallpaperAssetID = try values.decodeIfPresent(UUID.self, forKey: .wallpaperAssetID)
    }
}

/// Holds the original and edit parameters separately from the exact wire bitmap.
/// Rendering is injectable so draft/exit tests never need a device or the full app.
@MainActor final class ReadPicoLockScreenDraft: ObservableObject {
    typealias Renderer = @Sendable (CGImage, ReadPicoLockScreenOptions) throws -> Data
    @Published private(set) var source: CGImage?
    @Published private(set) var name = ""
    @Published private(set) var options = ReadPicoLockScreenOptions()
    @Published private(set) var bitmap: Data?
    @Published private(set) var rendering = false
    @Published private(set) var error: String?
    @Published private(set) var supportsNativeGray16: Bool?
    var onRendered: ((Data) -> Void)?
    var onInvalidated: (() -> Void)?
    private var sourcePNG: Data?
    private var confirmed: Snapshot?
    private var renderer: Renderer?
    private var renderTask: Task<Void, Never>?
    private var generation = UUID()
    private struct Snapshot: Codable, Equatable {
        var options: ReadPicoLockScreenOptions
        var name: String
        var image: Data
    }
    private struct Document: Codable { var version: Int; var draft: Snapshot }
    var hasImage: Bool { source != nil }
    var outputBitDepth: Int { options.output == .monochrome || (options.output == .automatic && supportsNativeGray16 == false) ? 1 : 4 }
    var hasUnsavedChanges: Bool { snapshot != nil && snapshot != confirmed }
    private var snapshot: Snapshot? { sourcePNG.map { Snapshot(options: options, name: name, image: $0) } }

    init(renderer: Renderer? = nil) { self.renderer = renderer }
    func configureOutputCapability(_ supportsGray16: Bool?) {
        guard supportsNativeGray16 != supportsGray16 else { return }
        supportsNativeGray16 = supportsGray16
        if source != nil && options.output == .automatic { rebuild() }
    }
    func configureRenderer(_ renderer: @escaping Renderer) {
        self.renderer = renderer
        if source != nil && bitmap == nil { rebuild() }
    }
    func setImage(_ image: CGImage, name: String) throws {
        guard image.width > 0, image.height > 0, image.width <= 2048, image.height <= 2048,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), png.count <= 32 * 1024 * 1024 else {
            throw ReadPicoManagerError.invalid("图片无法读取，或解码后超过 2048 像素／32 MB。")
        }
        source = image; sourcePNG = png; self.name = name
        options.zoom = 1; options.offsetX = 0; options.offsetY = 0; options.photoEditData = nil; options.wallpaperAssetID = nil
        rebuild()
    }
    func updateOptions(_ value: ReadPicoLockScreenOptions) {
        guard value.isValid, options != value else { return }
        options = value
        if source != nil { rebuild() }
    }
    func setLayout(_ value: ReadPicoLockScreenOptions.Layout) {
        var next = options; next.layout = value; next.zoom = 1; next.offsetX = 0; next.offsetY = 0
        updateOptions(next)
    }
    func center() { var next = options; next.zoom = 1; next.offsetX = 0; next.offsetY = 0; updateOptions(next) }
    private func rebuild(notify: Bool = true) {
        renderTask?.cancel(); generation = UUID()
        if notify { onInvalidated?() }
        guard let source, let renderer else { bitmap = nil; rendering = false; return }
        var renderOptions = options
        renderOptions.output = outputBitDepth == 4 ? .gray16 : .monochrome
        let options = renderOptions, token = generation
        rendering = true; error = nil
        renderTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
                let value = try await Task.detached(priority: .userInitiated) { try renderer(source, options) }.value
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.bitmap = value; self.rendering = false; self.renderTask = nil
                if notify { self.onRendered?(value) }
            } catch {
                guard let self, self.generation == token else { return }
                self.rendering = false; self.renderTask = nil
                if !(error is CancellationError) { self.error = error.localizedDescription; self.bitmap = nil }
            }
        }
    }
    func documentData() throws -> Data {
        guard let snapshot else { throw ReadPicoManagerError.invalid("请先选择一张图片。") }
        return try JSONEncoder().encode(Document(version: options.photoEditData == nil && options.wallpaperAssetID == nil ? 1 : 2, draft: snapshot))
    }
    func save(to url: URL) throws {
        let data = try documentData(); try data.write(to: url, options: .atomic)
        confirmed = snapshot; objectWillChange.send()
    }
    func load(data: Data) throws {
        guard data.count <= 48 * 1024 * 1024 else { throw ReadPicoManagerError.invalid("图片锁屏草稿不能超过 48 MB。") }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard (1...2).contains(document.version), document.draft.options.isValid,
              document.draft.image.count <= 32 * 1024 * 1024,
              let input = CGImageSourceCreateWithData(document.draft.image as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else {
            throw ReadPicoManagerError.invalid("图片锁屏草稿的版本、图片或编辑参数无效。")
        }
        source = image; sourcePNG = document.draft.image; name = document.draft.name
        options = document.draft.options; confirmed = document.draft; rebuild()
    }
    func discardChanges() {
        renderTask?.cancel(); generation = UUID(); rendering = false; error = nil
        guard let confirmed,
              let input = CGImageSourceCreateWithData(confirmed.image as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { clear(); return }
        source = image; sourcePNG = confirmed.image; name = confirmed.name; options = confirmed.options
        rebuild(notify: false)
    }
    func clear() {
        renderTask?.cancel(); renderTask = nil; generation = UUID()
        source = nil; sourcePNG = nil; confirmed = nil; name = ""; bitmap = nil
        options = .init(); rendering = false; error = nil
    }
}
