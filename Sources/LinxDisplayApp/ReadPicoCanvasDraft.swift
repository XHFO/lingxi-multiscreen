import AppKit
import Combine
import ImageIO
import LinxDisplayCore

/// Independent editable configuration for a Pico Lingxi board. Values never mutate another device's settings.
/// 小纸灵犀画板独立配置；模块与内容属于这份草稿，不写入口袋先知或其他设备的设置。
struct ReadPicoLingxiBoardConfiguration: Codable, Equatable {
    var name = "未命名画板"
    var modules: [Int] = []
    var text = ""
    var columns = 1
    var rasterScale = 3
    var darkBackground = false
    var nowPlayingHorizontal = true
    var entityIDs: [String] = []
    var fullWidthModules: [Int] = []
    var intervalSeconds = -1

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 256, text.utf8.count <= 16_384,
              modules.count <= 12, Set(modules).count == modules.count,
              modules.allSatisfy({ CanvasModule.allCases.map(\.rawValue).contains($0) && $0 != CanvasModule.excerptText.rawValue }),
              (1...2).contains(columns), (2...4).contains(rasterScale),
              entityIDs.count <= 24, Set(entityIDs).count == entityIDs.count,
              entityIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 }),
              fullWidthModules.count <= 12, Set(fullWidthModules).count == fullWidthModules.count,
              fullWidthModules.allSatisfy({ modules.contains($0) }),
              [-1, 0, 1, 2, 5, 10, 15, 30, 60, 300, 900, 1800, 3600].contains(intervalSeconds) else {
            throw ReadPicoManagerError.invalid("画板配置无效或超过限制，请检查模块和文字内容。")
        }
    }
}

/// Editable local canvas state. A device acknowledgement only confirms the source that was sent.
/// 本地画布草稿：图片与手绘分别追踪，推送回执不会误清另一个来源或之后的编辑。
@MainActor
final class ReadPicoCanvasDraft: ObservableObject {
    @Published var landscape = false
    @Published var dither = true
    @Published var image: NSImage? {
        didSet { imageSource = nil; wallpaperAssetID = nil; wallpaperEditData = nil }
    }
    /// Uncropped RGB source retained with this document; image remains the derived render input.
    /// 原 RGB 图随草稿保存；image 保留现有渲染输入约定，反复编辑不会丢失边缘。
    @Published var imageSource: NSImage?
    @Published var wallpaperAssetID: UUID?
    @Published var wallpaperEditData: Data?
    @Published var strokes: [[CGPoint]] = []
    @Published var liveStroke: [CGPoint] = []
    @Published var canvasMode = 0
    @Published var board = ReadPicoLingxiBoardConfiguration()
    @Published var playlist = ReadPicoBoardPlaylist()

    func applyWallpaper(source: NSImage, rendered: NSImage, assetID: UUID?, editData: Data) {
        image = rendered
        imageSource = source
        wallpaperAssetID = assetID
        wallpaperEditData = editData
    }

    /// A value captured before a request starts; acknowledge only after the device confirms display.
    /// 请求前冻结数据；设备确认显示后才能调用 acknowledge()。
    struct PushSnapshot {
        let data: Data
        private let confirmation: @MainActor () -> Void

        fileprivate init(data: Data, confirmation: @escaping @MainActor () -> Void) {
            self.data = data
            self.confirmation = confirmation
        }

        @MainActor func acknowledge() { confirmation() }
    }

    private struct State {
        var landscape = false
        var dither = true
        var image: NSImage?
        var imageSource: NSImage?
        var wallpaperAssetID: UUID?
        var wallpaperEditData: Data?
        var strokes: [[CGPoint]] = []
        var liveStroke: [CGPoint] = []
        var canvasMode = 0
        var board = ReadPicoLingxiBoardConfiguration()
        var playlist = ReadPicoBoardPlaylist()
    }

    private struct Point: Codable {
        let x: Double
        let y: Double
        init(_ value: CGPoint) { x = Double(value.x); y = Double(value.y) }
        var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    }

    private struct StoredImage: Codable {
        // Legacy key retained for version 1/2 compatibility; original sources contain lossless PNG.
        let tiff: Data
        let width: Int
        let height: Int
    }

    private struct Document: Codable {
        let version: Int
        let landscape: Bool
        let dither: Bool
        let canvasMode: Int
        let image: StoredImage?
        let imageSource: StoredImage?
        let strokes: [[Point]]
        let liveStroke: [Point]
        let board: ReadPicoLingxiBoardConfiguration?
        let playlist: ReadPicoBoardPlaylist?
        let wallpaperAssetID: UUID?
        let wallpaperEditData: Data?

        private enum CodingKeys: String, CodingKey { case version, landscape, dither, canvasMode, image, imageSource, strokes, liveStroke, board, playlist, wallpaperAssetID, wallpaperEditData }

        init(version: Int, landscape: Bool, dither: Bool, canvasMode: Int, image: StoredImage?, imageSource: StoredImage? = nil, strokes: [[Point]], liveStroke: [Point], board: ReadPicoLingxiBoardConfiguration? = nil, playlist: ReadPicoBoardPlaylist? = nil, wallpaperAssetID: UUID? = nil, wallpaperEditData: Data? = nil) {
            self.version = version; self.landscape = landscape; self.dither = dither; self.canvasMode = canvasMode
            self.image = image; self.imageSource = imageSource; self.strokes = strokes; self.liveStroke = liveStroke; self.board = board; self.playlist = playlist
            self.wallpaperAssetID = wallpaperAssetID; self.wallpaperEditData = wallpaperEditData
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            version = try fields.decode(Int.self, forKey: .version)
            guard (1...3).contains(version) else { throw ReadPicoManagerError.invalid("此画布草稿版本暂不支持。") }
            landscape = try fields.decode(Bool.self, forKey: .landscape)
            dither = try fields.decode(Bool.self, forKey: .dither)
            canvasMode = try fields.decode(Int.self, forKey: .canvasMode)
            guard canvasMode == 0 || canvasMode == 1 || (version >= 2 && canvasMode == 2) else { throw ReadPicoManagerError.invalid("画布来源无效。") }
            board = try fields.decodeIfPresent(ReadPicoLingxiBoardConfiguration.self, forKey: .board)
            playlist = try fields.decodeIfPresent(ReadPicoBoardPlaylist.self, forKey: .playlist)
            try playlist?.validate()
            wallpaperAssetID = try fields.decodeIfPresent(UUID.self, forKey: .wallpaperAssetID)
            wallpaperEditData = try fields.decodeIfPresent(Data.self, forKey: .wallpaperEditData)
            guard (wallpaperEditData?.count ?? 0) <= 16_384 else { throw ReadPicoManagerError.invalid("图片裁剪参数超过限制。") }
            if version == 2 || canvasMode == 2 { guard board != nil else { throw ReadPicoManagerError.invalid("画板草稿缺少可编辑模块。") } }
            try board?.validate()
            image = try fields.decodeIfPresent(StoredImage.self, forKey: .image)
            imageSource = try fields.decodeIfPresent(StoredImage.self, forKey: .imageSource)
            var paths = try fields.nestedUnkeyedContainer(forKey: .strokes)
            guard (paths.count ?? 0) <= 10_000 else { throw ReadPicoManagerError.invalid("草稿笔迹数量超过限制。") }
            var decoded: [[Point]] = []
            var total = 0
            // Reject array sizes before allocating points; a small JSON file can contain millions of empty arrays.
            // 数组必须先检查数量再分配，避免短小的恶意 JSON 生成数百万个空笔迹对象。
            while !paths.isAtEnd {
                guard decoded.count < 10_000 else { throw ReadPicoManagerError.invalid("草稿笔迹数量超过限制。") }
                var points = try paths.nestedUnkeyedContainer()
                guard (points.count ?? 0) <= 20_000, (points.count ?? 0) <= 200_000 - total else {
                    throw ReadPicoManagerError.invalid("草稿笔迹数量超过限制。")
                }
                var stroke: [Point] = []
                while !points.isAtEnd {
                    guard stroke.count < 20_000, total < 200_000 else { throw ReadPicoManagerError.invalid("草稿笔迹数量超过限制。") }
                    stroke.append(try points.decode(Point.self)); total += 1
                }
                decoded.append(stroke)
            }
            strokes = decoded
            var active = try fields.nestedUnkeyedContainer(forKey: .liveStroke)
            guard (active.count ?? 0) <= 20_000, (active.count ?? 0) <= 200_000 - total else {
                throw ReadPicoManagerError.invalid("草稿笔迹数量超过限制。")
            }
            var activePoints: [Point] = []
            while !active.isAtEnd {
                guard activePoints.count < 20_000, total < 200_000 else { throw ReadPicoManagerError.invalid("草稿笔迹数量超过限制。") }
                activePoints.append(try active.decode(Point.self)); total += 1
            }
            liveStroke = activePoints
        }
    }

    // Bound both encoded input and decoded work before constructing AppKit images.
    // 编码文件、解码像素及笔迹分别限量，避免损坏文件导致无界内存分配。
    private static let maxDocumentBytes = 160 * 1024 * 1024
    private static let maxSourceBytes = 80 * 1024 * 1024
    private static let maxImageBytes = 16 * 1024 * 1024
    private static let maxImageDimension = 8192
    private static let maxImagePixels = 16 * 1024 * 1024
    private static let maxStrokes = 10_000
    private static let maxPointsPerStroke = 20_000
    private static let maxPoints = 200_000

    private var saved = State()
    private var confirmedImage = State()
    private var confirmedDrawing = State()
    private var confirmedBoard = State()
    private var confirmedPlaylist = ReadPicoBoardPlaylist()
    private var epoch: UInt64 = 0
    private var nextTicket: UInt64 = 0
    private var imageTicket: UInt64 = 0
    private var drawingTicket: UInt64 = 0

    /// Changing the selected source is navigation, not an edit. Empty sources have no display options to lose.
    /// 切换来源本身不算修改；没有内容的来源也不会仅因横屏、点阵选项变化而要求保存。
    var hasUnsavedChanges: Bool {
        let imageChanged = image !== confirmedImage.image || imageSource !== confirmedImage.imageSource || wallpaperAssetID != confirmedImage.wallpaperAssetID || wallpaperEditData != confirmedImage.wallpaperEditData ||
            (image != nil && (landscape != confirmedImage.landscape || dither != confirmedImage.dither))
        let drawingChanged = strokes != confirmedDrawing.strokes || liveStroke != confirmedDrawing.liveStroke ||
            ((!strokes.isEmpty || !liveStroke.isEmpty) &&
             (landscape != confirmedDrawing.landscape || dither != confirmedDrawing.dither))
        let boardChanged = board != confirmedBoard.board ||
            (!board.modules.isEmpty && landscape != confirmedBoard.landscape) ||
            (board.modules.contains(9) && image !== confirmedBoard.image)
        return imageChanged || drawingChanged || boardChanged || playlist != confirmedPlaylist
    }

    /// A display acknowledgement never saves the editable Mac document.
    /// Keep local departure decisions separate from the delivered-frame baselines above.
    var hasUnsavedLocalChanges: Bool {
        let imageChanged = image !== saved.image || imageSource !== saved.imageSource ||
            wallpaperAssetID != saved.wallpaperAssetID || wallpaperEditData != saved.wallpaperEditData ||
            (image != nil && (landscape != saved.landscape || dither != saved.dither))
        let drawingChanged = strokes != saved.strokes || liveStroke != saved.liveStroke ||
            ((!strokes.isEmpty || !liveStroke.isEmpty) &&
             (landscape != saved.landscape || dither != saved.dither))
        let boardChanged = board != saved.board ||
            ((!board.modules.isEmpty || !playlist.enabledItems.isEmpty) && landscape != saved.landscape)
        return imageChanged || drawingChanged || boardChanged || playlist != saved.playlist
    }

    private var state: State {
        State(landscape: landscape, dither: dither, image: image, imageSource: imageSource, wallpaperAssetID: wallpaperAssetID, wallpaperEditData: wallpaperEditData, strokes: strokes,
              liveStroke: liveStroke, canvasMode: canvasMode, board: board, playlist: playlist)
    }

    /// Restore the last successfully saved local draft, or the initial blank canvas.
    /// 放弃修改始终回到最近一次本地保存；设备推送不能替代本地可编辑草稿。
    func discardChanges() {
        restore(saved)
        confirmAll()
    }

    /// Render input, lossless RGB original, independent playlist and paths commit atomically.
    /// 渲染图、无损 RGB 原稿、独立轮播及笔迹一次性原子保存；失败不改变保存基线。
    func save(to url: URL) throws {
        let value = state
        try Self.validate(value)
        try Self.validatePlaylistImages(value.playlist)
        let includesBoard = canvasMode == 2 || board != ReadPicoLingxiBoardConfiguration()
        let includesSource = value.imageSource != nil || value.playlist != ReadPicoBoardPlaylist()
        let document = Document(version: includesSource ? 3 : includesBoard ? 2 : 1, landscape: value.landscape, dither: value.dither,
                                canvasMode: value.canvasMode, image: try Self.storeImage(value.image),
                                imageSource: try Self.storeImage(value.imageSource, original: true),
                                strokes: value.strokes.map { $0.map(Point.init) }, liveStroke: value.liveStroke.map(Point.init), board: includesBoard ? value.board : nil,
                                playlist: value.playlist == ReadPicoBoardPlaylist() ? nil : value.playlist,
                                wallpaperAssetID: value.wallpaperAssetID, wallpaperEditData: value.wallpaperEditData)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maxDocumentBytes else { throw Self.invalid("草稿太大，请减少图片尺寸或笔迹后重试。") }
        try data.write(to: url, options: .atomic)
        saved = value
        confirmAll()
    }

    /// Fully decode and validate before touching the active draft, including its save/discard baseline.
    /// 全部解码并验证通过后才替换当前草稿，失败时保留现有输入与保存基线。
    func load(from url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let byteCount = try handle.seekToEnd()
        guard byteCount > 0, byteCount <= UInt64(Self.maxDocumentBytes) else { throw Self.invalid("草稿文件为空或超过大小限制。") }
        try handle.seek(toOffset: 0)
        // Read a bounded amount even if another process grows the file after the size check.
        let data = try handle.read(upToCount: Self.maxDocumentBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= Self.maxDocumentBytes else { throw Self.invalid("草稿文件超过大小限制。") }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard (1...3).contains(document.version) else { throw Self.invalid("此画布草稿版本暂不支持。") }
        var value = State(landscape: document.landscape, dither: document.dither,
                          strokes: document.strokes.map { $0.map(\.cgPoint) },
                          liveStroke: document.liveStroke.map(\.cgPoint), canvasMode: document.canvasMode,
                          board: document.board ?? .init(), playlist: document.playlist ?? .init())
        if let storedImage = document.image { value.image = try Self.loadImage(storedImage) }
        if let source = document.imageSource { value.imageSource = try Self.loadImage(source, original: true) }
        value.wallpaperAssetID = document.wallpaperAssetID; value.wallpaperEditData = document.wallpaperEditData
        try Self.validate(value)
        try Self.validatePlaylistImages(value.playlist)
        restore(value)
        saved = value
        confirmAll()
    }

    /// Adopt the other instance's last successfully decoded/saved local snapshot, without file I/O.
    /// Stage `candidate.load(from:)` before asking to discard the current draft, then adopt that candidate.
    /// Images are immutable sources: replace `image` to edit it; never mutate an NSImage representation in place.
    /// 先在临时实例完整加载，再确认离开，最后采用内存中的已验证基线；确认后不再读盘或解码。
    /// 图片源按不可变对象共享，修改图片必须重新赋值，不能原地修改 NSImage 的图像表示。
    func adoptValidatedDraft(_ other: ReadPicoCanvasDraft) {
        let value = other.saved
        restore(value)
        saved = value
        confirmAll()
    }

    /// Preserve the existing aspect-fit bitmap contract: no crop or nonuniform image stretch.
    /// 维持原有等比留白显示约定，不裁切或拉伸原图。
    func bitmap() throws -> Data { try bitmap(for: state) }
    func bitmapGray16() throws -> Data { try bitmap(for: state, nativeGray16: true) }

    func makePushSnapshot(nativeGray16: Bool = false) throws -> PushSnapshot {
        let captured = state
        let data = try bitmap(for: captured, nativeGray16: nativeGray16)
        nextTicket &+= 1
        let ticket = nextTicket
        let capturedEpoch = epoch
        return PushSnapshot(data: data) { [weak self] in
            guard let self, self.epoch == capturedEpoch else { return }
            if captured.canvasMode == 0 {
                guard ticket > self.imageTicket else { return }
                self.imageTicket = ticket
                self.objectWillChange.send()
                self.confirmedImage = captured
            } else {
                guard ticket > self.drawingTicket else { return }
                self.drawingTicket = ticket
                self.objectWillChange.send()
                self.confirmedDrawing = captured
            }
        }
    }

    var hasRenderableBoardContent: Bool {
        canvasMode == 2 ? (playlist.mode == .carousel ? !playlist.enabledItems.isEmpty : !board.modules.isEmpty) : canvasMode == 0 ? image != nil : (!strokes.isEmpty || !liveStroke.isEmpty)
    }

    /// Migrate the previous single-source push options once without marking a new empty document dirty.
    /// 首次进入沿用旧信息来源，迁移自身不制造未保存提示；已有画板配置始终保留。
    private var boardInitialized = false
    func initializeBoardIfNeeded(_ configuration: ReadPicoLingxiBoardConfiguration, landscape: Bool) {
        guard !boardInitialized else { return }
        boardInitialized = true
        guard board == ReadPicoLingxiBoardConfiguration(), canvasMode != 2 else { return }
        board = configuration
        if image == nil && strokes.isEmpty && liveStroke.isEmpty { self.landscape = landscape; canvasMode = 2 }
        saved.board = configuration; saved.canvasMode = canvasMode; saved.landscape = self.landscape
        confirmedBoard = state
    }

    /// Reuse the same bounded original-image validation for module rendering and local saves.
    /// 模块绘图复用草稿保存的原图限量校验，临时文件只用于现有画板渲染引擎。
    func boardImageData() throws -> Data? { try Self.storeImage(image)?.tiff }

    /// Freeze the rendered module bitmap, retaining editable sources and acknowledgement ordering.
    /// 冻结真实模块画面；显示回执只确认这次渲染所用的配置，不会清除后续编辑。
    func makeBoardPushSnapshot(bitmap: Data) throws -> PushSnapshot {
        let captured = state
        try Self.validate(captured)
        guard (captured.playlist.mode == .carousel ? !captured.playlist.enabledItems.isEmpty : !captured.board.modules.isEmpty), !bitmap.isEmpty else { throw Self.invalid("请先添加模块并生成预览。") }
        nextTicket &+= 1
        let ticket = nextTicket, capturedEpoch = epoch
        return PushSnapshot(data: bitmap) { [weak self] in
            guard let self, self.epoch == capturedEpoch, ticket > self.boardTicket else { return }
            self.boardTicket = ticket
            // One carousel frame never confirms unsent composition edits or the entire playlist.
            // 单张轮播回执不能确认尚未显示的组合画板或整份轮播计划。
            if captured.playlist.mode == .composition {
                self.objectWillChange.send()
                self.confirmedBoard = captured
                if captured.board.modules.contains(CanvasModule.image.rawValue) { self.confirmedImage = captured }
            }
        }
    }
    private var boardTicket: UInt64 = 0

    private func restore(_ value: State) {
        landscape = value.landscape
        dither = value.dither
        image = value.image
        imageSource = value.imageSource
        wallpaperAssetID = value.wallpaperAssetID; wallpaperEditData = value.wallpaperEditData
        strokes = value.strokes
        liveStroke = value.liveStroke
        canvasMode = value.canvasMode
        board = value.board
        playlist = value.playlist
        boardInitialized = value.board != ReadPicoLingxiBoardConfiguration() || value.canvasMode == 2
    }

    private func confirmAll() {
        objectWillChange.send()
        epoch &+= 1
        confirmedImage = state
        confirmedDrawing = state
        confirmedBoard = state
        confirmedPlaylist = playlist
    }

    private func bitmap(for value: State, nativeGray16: Bool = false) throws -> Data {
        try Self.validate(value)
        let width = value.landscape ? 1216 : 684
        let height = value.landscape ? 684 : 1216
        let source: CGImage
        guard value.canvasMode != 2 else { throw Self.invalid("请从灵犀画板预览生成模块画面。") }
        if value.canvasMode == 0 {
            guard let stored = try Self.storeImage(value.image) else { throw Self.invalid("请先选择可读取的图片。") }
            source = try Self.decodeImage(stored)
        } else {
            let paths = value.strokes + (value.liveStroke.isEmpty ? [] : [value.liveStroke])
            guard paths.contains(where: { !$0.isEmpty }) else { throw Self.invalid("请先画几笔，再推送到阅读器。") }
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Self.invalid("无法创建手绘画布。")
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(5)
            for stroke in paths {
                guard let first = stroke.first else { continue }
                context.move(to: CGPoint(x: first.x * CGFloat(width), y: first.y * CGFloat(height)))
                if stroke.count == 1 {
                    context.setFillColor(CGColor(gray: 0, alpha: 1))
                    context.fillEllipse(in: CGRect(x: first.x * CGFloat(width) - 2.5,
                                                  y: first.y * CGFloat(height) - 2.5, width: 5, height: 5))
                } else {
                    for point in stroke.dropFirst() { context.addLine(to: CGPoint(x: point.x * CGFloat(width), y: point.y * CGFloat(height))) }
                    context.strokePath()
                }
            }
            guard let output = context.makeImage() else { throw Self.invalid("手绘画布转换未完成。") }
            source = output
        }
        if nativeGray16 { return try ReadPicoBitmap.makeGray16(image: source, width: width, height: height) }
        return try ReadPicoBitmap.make(image: source, width: width, height: height, dither: value.dither)
    }

    private static func validate(_ value: State) throws {
        try value.board.validate()
        try value.playlist.validate()
        guard value.imageSource == nil || value.image != nil else { throw invalid("图片原稿缺少对应的渲染图。") }
        guard (value.wallpaperEditData?.count ?? 0) <= 16_384 else { throw invalid("图片裁剪参数超过限制。") }
        guard value.canvasMode == 0 || value.canvasMode == 1 || value.canvasMode == 2 else { throw invalid("画布来源无效。") }
        guard value.strokes.count <= maxStrokes, value.liveStroke.count <= maxPointsPerStroke else { throw invalid("草稿笔迹数量超过限制。") }
        var count = value.liveStroke.count
        for stroke in value.strokes {
            guard stroke.count <= maxPointsPerStroke, count <= maxPoints - stroke.count else { throw invalid("草稿笔迹数量超过限制。") }
            count += stroke.count
        }
        for stroke in value.strokes + [value.liveStroke] {
            guard stroke.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
                throw invalid("草稿包含无效的笔迹坐标。")
            }
        }
    }

    /// Validate portable per-instance sources before replacing a document or writing its saved baseline.
    /// 轮播原稿逐项解码验证，通过后才能替换文档或写入保存基线。
    private static func validatePlaylistImages(_ playlist: ReadPicoBoardPlaylist) throws {
        for item in playlist.items {
            guard let data = item.imageSourcePNG else { continue }
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  dimensionsAreSafe(width: width, height: height) else {
                throw invalid("轮播项「\(item.name)」的图片原稿已损坏或尺寸超过限制。")
            }
            _ = try decodeImage(StoredImage(tiff: data, width: width, height: height))
        }
    }

    private static func dimensionsAreSafe(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxImageDimension && height <= maxImageDimension &&
            width <= maxImagePixels / height
    }

    private static func storeImage(_ image: NSImage?, original: Bool = false) throws -> StoredImage? {
        guard let image else { return nil }
        guard image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0,
              image.size.width <= CGFloat(maxImageDimension), image.size.height <= CGFloat(maxImageDimension) else {
            throw invalid("图片尺寸过大或无效，请使用较小的图片。")
        }
        guard image.representations.count <= 32 else { throw invalid("图片包含过多图像版本，请使用单张图片。") }
        var totalPixels = 0
        for representation in image.representations {
            // AppKit's CGImage wrapper may advertise a Retina size twice the actual CGImage dimensions.
            // Validate concrete bitmaps here and the exact source CGImage below, avoiding a false 4× pixel budget.
            // CGImage 包装表示可能报告 Retina 两倍尺寸；原稿以真实 CGImage 像素复核，避免错误放大四倍拒绝。
            if original && !(representation is NSBitmapImageRep) { continue }
            guard dimensionsAreSafe(width: representation.pixelsWide, height: representation.pixelsHigh),
                  representation.pixelsWide * representation.pixelsHigh <= maxImagePixels - totalPixels else {
                throw invalid("图片尺寸过大或无效，请使用较小的图片。")
            }
            totalPixels += representation.pixelsWide * representation.pixelsHigh
        }
        let data: Data?
        if original {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  dimensionsAreSafe(width: cgImage.width, height: cgImage.height) else { throw invalid("图片原稿无法保存。") }
            data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        } else { data = image.tiffRepresentation }
        guard let data, data.count <= (original ? maxSourceBytes : maxImageBytes),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              dimensionsAreSafe(width: width, height: height) else {
            throw invalid("图片无法保存，或超过草稿允许的大小。")
        }
        return StoredImage(tiff: data, width: width, height: height)
    }

    private static func decodeImage(_ image: StoredImage, original: Bool = false) throws -> CGImage {
        guard image.tiff.count <= (original ? maxSourceBytes : maxImageBytes), dimensionsAreSafe(width: image.width, height: image.height),
              let source = CGImageSourceCreateWithData(image.tiff as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == image.width, height == image.height, dimensionsAreSafe(width: width, height: height),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw invalid("草稿图片已损坏或尺寸超过限制。")
        }
        return decoded
    }

    private static func loadImage(_ image: StoredImage, original: Bool = false) throws -> NSImage {
        let decoded = try decodeImage(image, original: original)
        let loaded = NSImage(size: NSSize(width: image.width, height: image.height))
        loaded.addRepresentation(NSBitmapImageRep(cgImage: decoded))
        return loaded
    }

    private static func invalid(_ text: String) -> ReadPicoManagerError { .invalid(text) }
}
