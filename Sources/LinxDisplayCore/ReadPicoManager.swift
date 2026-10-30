import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import Darwin

/// Read Pico's card data and authenticated management protocol are independent of C6 devices.
/// TF mutations require a card exported by the reader or mounted in a card reader.
public enum ReadPicoManagerError: LocalizedError {
    case invalid(String), unavailable(String), conflict(String), http(Int), expired, homeModuleMissing, homePortalActive
    public var errorDescription: String? {
        switch self {
        case .invalid(let text), .unavailable(let text), .conflict(let text): return text
        case .http(let code): return "设备请求未完成（HTTP \(code)）。请保持管理页面开启并重试。"
        case .expired: return "配对已失效，请在阅读器重新打开“手机管理”并复制新的连接地址。"
        case .homeModuleMissing: return "需安装 TF apps/tools/home-link.pga，或使用完整 Home Link 固件。"
        case .homePortalActive: return "手机正在填写家庭设置，本机暂不保存。请关闭设备端二维码或等待门户结束后再试。"
        }
    }
}

/// Host Home Link stack mode from `GET /api/manage/pico/status` (`home_link_mode`).
/// Missing field on older builds is treated as `thin` by clients.
public enum ReadPicoHomeLinkMode: String, Codable, Equatable, Sendable {
    case thin, full, pga
}

private func picoU16(_ data: Data, _ offset: Int) -> Int {
    Int(data[offset]) | Int(data[offset + 1]) << 8
}
private func picoU32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
}
private enum ReadPicoCRC {
    static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }; return crc
    }
}
public func readPicoCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffffffff
    for byte in data { crc = (crc >> 8) ^ ReadPicoCRC.table[Int((crc ^ UInt32(byte)) & 255)] }
    return crc ^ 0xffffffff
}
private func picoString(_ data: Data, _ offset: Int, _ count: Int) throws -> String {
    let bytes = data.subdata(in: offset..<(offset + count))
    guard let end = bytes.firstIndex(of: 0), bytes[end...].allSatisfy({ $0 == 0 }),
          let value = String(data: bytes[..<end], encoding: .utf8) else {
        throw ReadPicoManagerError.invalid("应用包的文字字段无效。")
    }
    return value
}

public struct ReadPicoPackage: Equatable, Sendable {
    public let id: String, title: String, summary: String, version: Int, kind: Int, targets: [String]
    public var isTool: Bool { kind >= 128 }
    public var versionLabel: String { "\(version / 10000).\(version / 100 % 100).\(version % 100)" }
    public init(data: Data, requireDevice: Bool = true) throws {
        func require(_ condition: Bool) throws {
            if !condition { throw ReadPicoManagerError.invalid("PGA 应用包损坏、版本不兼容，或未包含设备代码。") }
        }
        try require((512...4 * 1024 * 1024).contains(data.count))
        try require(data.prefix(8) == Data("PICOAPP1".utf8))
        try require(picoU32(data, 8) == 1 && picoU32(data, 12) == 512 && Int(picoU32(data, 16)) == data.count && picoU32(data, 20) == 1)
        var header = data.subdata(in: 0..<512); let expected = picoU32(header, 232)
        header.replaceSubrange(232..<236, with: [0, 0, 0, 0]); try require(readPicoCRC32(header) == expected)
        let kind = Int(picoU32(data, 28)), count = Int(picoU32(data, 228))
        try require(picoU32(data, 24) > 0 && ((0...5).contains(kind) || (128...255).contains(kind)))
        try require((1...4).contains(count) && picoU32(data, 224) == 0)
        try require(data[236..<256].allSatisfy({ $0 == 0 }) && data[384..<448].allSatisfy({ $0 == 0 }) && data[480..<512].allSatisfy({ $0 == 0 }))
        let id = try picoString(data, 32, 32)
        try require(!id.isEmpty && id.first != "-" && id.last != "-" && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
        let title = try picoString(data, 64, 64), summary = try picoString(data, 128, 96)
        try require(!title.isEmpty)
        var next = 512, targets: [String] = []
        for i in 0..<4 {
            let offset = 256 + i * 32
            if i >= count { try require(data[offset..<(offset + 32)].allSatisfy { $0 == 0 }); continue }
            let target = try picoString(data, offset, 16), start = Int(picoU32(data, offset + 16)), bytes = Int(picoU32(data, offset + 20))
            try require(!target.isEmpty && !targets.contains(target) && start == next && bytes > 0 && bytes <= 2 * 1024 * 1024 && bytes <= data.count - start && picoU32(data, offset + 28) == 0)
            try require(readPicoCRC32(data.subdata(in: start..<(start + bytes))) == picoU32(data, offset + 24))
            next += bytes; targets.append(target)
        }
        try require(next == data.count && (!requireDevice || targets.contains("esp32s3-xtensa")))
        self.id = id; self.title = title; self.summary = summary; self.version = Int(picoU32(data, 24)); self.kind = kind; self.targets = targets
    }
}

public enum ReadPicoFileKind: String, CaseIterable, Identifiable, Sendable {
    case book, application, drawing, font, note
    public var id: String { rawValue }
    public var title: String { switch self { case .book: return "图书"; case .application: return "应用"; case .drawing: return "画板原稿"; case .font: return "字体"; case .note: return "笔记" } }
}
/// Matches the device's bounded TrueType upload preflight (transfer_font.h).
/// CoreText alone also accepts CFF/collections that Pico cannot load.
public enum ReadPicoTrueTypeFont {
    public static func validate(_ data: Data, filename: String) throws {
        func require(_ value: Bool) throws {
            guard value else { throw ReadPicoManagerError.invalid("Pico 仅支持有效的 TrueType TTF 字体；不支持 OTF/CFF 或 TTC 字体集合，改扩展名也无法转换。") }
        }
        try require(URL(fileURLWithPath: filename).pathExtension.lowercased() == "ttf" && data.count >= 12 && data.count <= 32 * 1024 * 1024)
        func u16(_ p: Int) -> Int { Int(data[p]) << 8 | Int(data[p + 1]) }
        func u32(_ p: Int) -> Int { u16(p) << 16 | u16(p + 2) }
        try require(u32(0) == 0x00010000 || data.prefix(4) == Data("true".utf8))
        let count = u16(4), directoryEnd = 12 + count * 16
        try require(count > 0 && count <= 128 && directoryEnd <= data.count)
        let required: Set<String> = ["cmap", "head", "hhea", "hmtx", "maxp", "loca", "glyf"]
        var tables: [String: (offset: Int, size: Int)] = [:]
        for i in 0..<count {
            let record = 12 + i * 16, offset = u32(record + 8), size = u32(record + 12)
            try require(offset >= directoryEnd && offset <= data.count && size <= data.count - offset)
            let tag = String(decoding: data[record..<(record + 4)], as: UTF8.self)
            try require(tag != "CFF " && tag != "CFF2")
            if required.contains(tag) { try require(tables[tag] == nil); tables[tag] = (offset, size) }
        }
        try require(required.allSatisfy { (tables[$0]?.size ?? 0) > 0 })
        let head = tables["head"]!, hhea = tables["hhea"]!, maxp = tables["maxp"]!, cmap = tables["cmap"]!, loca = tables["loca"]!, glyf = tables["glyf"]!, hmtx = tables["hmtx"]!
        try require(head.size >= 54 && hhea.size >= 36 && maxp.size >= 6 && cmap.size >= 4)
        let glyphs = u16(maxp.offset + 4), metrics = u16(hhea.offset + 34), units = u16(head.offset + 18), format = u16(head.offset + 50), maps = u16(cmap.offset + 2)
        try require(u32(head.offset + 12) == 0x5f0f3cf5 && units >= 16 && units <= 16384 && glyphs > 0 && metrics > 0 && metrics <= glyphs && format <= 1)
        let width = format == 0 ? 2 : 4
        try require(loca.size >= (glyphs + 1) * width && hmtx.size >= metrics * 4 + (glyphs - metrics) * 2 && u16(cmap.offset) == 0 && maps > 0 && 4 + maps * 8 <= cmap.size)
        var previous = 0
        for i in 0...glyphs {
            let location = loca.offset + i * width, offset = format == 0 ? u16(location) * 2 : u32(location)
            try require(offset >= previous && offset <= glyf.size); previous = offset
        }
    }
}
public struct ReadPicoCardFile: Identifiable, Equatable, Sendable {
    public let relativePath: String, title: String, kind: ReadPicoFileKind, bytes: Int64, modified: Date?, detail: String, valid: Bool
    public init(relativePath: String, title: String, kind: ReadPicoFileKind, bytes: Int64, modified: Date? = nil, detail: String = "", valid: Bool = true) {
        self.relativePath = relativePath; self.title = title; self.kind = kind; self.bytes = bytes
        self.modified = modified; self.detail = detail; self.valid = valid
    }
    public var id: String { relativePath }
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
public struct ReadPicoDrawing: Sendable {
    public struct Point: Sendable { public let x: Int, y: Int, width: Int, startsStroke: Bool, eraser: Bool }
    public let width: Int, height: Int, points: [Point]
    public init(data: Data) throws {
        guard data.count == 12 + 49168, picoU32(data, 0) == 0x31535058, picoU32(data, 4) == 49168,
              readPicoCRC32(data.subdata(in: 12..<data.count)) == picoU32(data, 8),
              picoU32(data, 12) == 0x314e4450, picoU16(data, 16) == 1 else {
            throw ReadPicoManagerError.invalid("画板原稿校验未通过；原文件已保留。")
        }
        let width = picoU16(data, 18), height = picoU16(data, 20), count = picoU16(data, 22)
        guard (100...2000).contains(width), (100...2000).contains(height), count <= 8192 else { throw ReadPicoManagerError.invalid("画板原稿尺寸或点数无效。") }
        var points: [Point] = []; points.reserveCapacity(count)
        for i in 0..<count {
            let offset = 28 + i * 6, x = picoU16(data, offset), y = picoU16(data, offset + 2), thickness = Int(data[offset + 4]), flags = data[offset + 5]
            guard x < width, y < height, (1...48).contains(thickness), flags & ~3 == 0, i != 0 || flags & 1 != 0 else { throw ReadPicoManagerError.invalid("画板笔迹数据无效；原文件已保留。") }
            points.append(Point(x: x, y: y, width: thickness, startsStroke: flags & 1 != 0, eraser: flags & 2 != 0))
        }
        self.width = width; self.height = height; self.points = points
    }
    public func svg() -> Data {
        var text = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\"><rect width=\"100%\" height=\"100%\" fill=\"white\"/>"
        for (i, point) in points.enumerated() {
            let previous = i == 0 || point.startsStroke ? point : points[i - 1], color = point.eraser ? "white" : "black"
            if previous.x == point.x && previous.y == point.y { text += "<circle cx=\"\(point.x)\" cy=\"\(point.y)\" r=\"\(Double(point.width) / 2)\" fill=\"\(color)\"/>" }
            else { text += "<path d=\"M\(previous.x) \(previous.y)L\(point.x) \(point.y)\" stroke=\"\(color)\" stroke-width=\"\(point.width)\" stroke-linecap=\"round\"/>" }
        }
        return Data((text + "</svg>").utf8)
    }
    public func image() throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ReadPicoManagerError.unavailable("无法创建画板预览。") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1); context.setLineCap(.round)
        for (i, point) in points.enumerated() {
            let previous = i == 0 || point.startsStroke ? point : points[i - 1], color = CGColor(gray: point.eraser ? 1 : 0, alpha: 1)
            context.setStrokeColor(color); context.setFillColor(color); context.setLineWidth(CGFloat(point.width))
            if previous.x == point.x && previous.y == point.y { let r = CGFloat(point.width) / 2; context.fillEllipse(in: CGRect(x: CGFloat(point.x) - r, y: CGFloat(point.y) - r, width: r * 2, height: r * 2)) }
            else { context.move(to: CGPoint(x: previous.x, y: previous.y)); context.addLine(to: CGPoint(x: point.x, y: point.y)); context.strokePath() }
        }
        guard let image = context.makeImage() else { throw ReadPicoManagerError.unavailable("无法生成画板图片。") }; return image
    }
    public func png() throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw ReadPicoManagerError.unavailable("无法导出 PNG。") }
        CGImageDestinationAddImage(destination, try image(), nil)
        guard CGImageDestinationFinalize(destination) else { throw ReadPicoManagerError.unavailable("PNG 导出未完成。") }; return output as Data
    }
}

/// Shared validation runs before either a mounted-card write or an authenticated upload.
private enum ReadPicoContentRules {
    static func boundedData(_ url: URL, limit: Int) throws -> Data {
        var current = url; current.removeAllCachedResourceValues()
        let values = try current.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= limit else {
            throw ReadPicoManagerError.invalid("文件为空、大小超过限制或不是普通文件。")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == size else { throw ReadPicoManagerError.unavailable("源文件读取不完整，请重新选择。") }
        return data
    }
    static func proposedPath(for source: URL, kind: ReadPicoFileKind) throws -> String {
        let name = source.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 32 || "\\:*?\"<>|".contains($0) }), !name.hasSuffix("."), !name.hasSuffix(" ") else { throw ReadPicoManagerError.invalid("文件名包含 TF 卡不支持的字符。") }
        switch kind {
        case .book:
            guard ["epub", "txt"].contains(source.pathExtension.lowercased()), source.lastPathComponent.utf8.count <= 180 else { throw ReadPicoManagerError.invalid("目前支持 EPUB 和 TXT；请使用不超过 180 字节的文件名。") }
            return "books/" + source.lastPathComponent
        case .font:
            let data = try boundedData(source, limit: 32 * 1024 * 1024)
            try ReadPicoTrueTypeFont.validate(data, filename: source.lastPathComponent)
            guard source.lastPathComponent.utf8.count <= 180,
                  let provider = CGDataProvider(data: data as CFData), CGFont(provider) != nil else { throw ReadPicoManagerError.invalid("请选择有效的 TrueType TTF 字体文件。") }
            return "fonts/" + source.lastPathComponent
        case .note:
            guard source.pathExtension.lowercased() == "txt", source.lastPathComponent.hasPrefix("灵犀笔记-"), source.lastPathComponent.utf8.count <= 180,
                  String(data: try boundedData(source, limit: 16 * 1024 * 1024), encoding: .utf8) != nil else { throw ReadPicoManagerError.invalid("独立笔记须为资料库生成的 UTF-8 TXT。") }
            return "books/" + source.lastPathComponent
        case .application:
            let package = try ReadPicoPackage(data: boundedData(source, limit: 4 * 1024 * 1024))
            return "apps/\(package.isTool ? "tools" : "games")/\(package.id).pga"
        case .drawing: throw ReadPicoManagerError.invalid("画板原稿仅提供导出，不直接覆盖设备笔迹。")
        }
    }

    static func path(_ value: String, kind: ReadPicoFileKind, removing: Bool = false) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, value.utf8.count <= 240,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 32 || "\\:*?\"<>|".contains($0) }) }),
              !parts.contains(where: { $0.hasSuffix(".") || $0.hasSuffix(" ") }) else {
            throw ReadPicoManagerError.invalid("文件路径无效。")
        }
        let name = String(parts.last!), ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let allowed: Bool
        switch kind {
        case .book: allowed = ["epub", "txt"].contains(ext) && (parts.count == 1 || parts.count == 2 && parts[0] == "books")
        case .note: allowed = ext == "txt" && name.hasPrefix("灵犀笔记-") && parts.count == 2 && parts[0] == "books"
        case .font: allowed = ["ttf", "otf"].contains(ext) && parts.count == 2 && parts[0] == "fonts"
        case .application: allowed = ext == "pga" && parts.count == 3 && parts[0] == "apps" && ["games", "tools"].contains(String(parts[1]))
        case .drawing: allowed = !removing && parts.count == 4 && parts[0] == "apps" && parts[1] == "data" && parts[2] == "drawing-notes" && name.range(of: #"^board(0[1-9]|1[0-2])\.dat$"#, options: .regularExpression) != nil
        }
        guard allowed else { throw ReadPicoManagerError.invalid("只能管理图书、字体、独立笔记和应用；画板原稿仅可导出。") }
    }
}

/// Both transports enforce the same managed paths and preserve unrelated TF content and app saves.
public protocol ReadPicoContentStore: Sendable {
    func scan() async throws -> [ReadPicoCardFile]
    func proposedPath(for source: URL, kind: ReadPicoFileKind) async throws -> String
    func isIdentical(_ source: URL, kind: ReadPicoFileKind) async throws -> Bool
    @discardableResult func importFile(_ source: URL, kind: ReadPicoFileKind, replace: Bool,
                                      progress: (@Sendable (Int64, Int64, String) -> Void)?) async throws -> String
    func remove(_ item: ReadPicoCardFile) async throws
    func export(_ item: ReadPicoCardFile, to destination: URL, format: String) async throws
}

public enum ReadPicoTransportPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, wifi, usb
    public var id: String { rawValue }
    public var title: String { switch self { case .automatic: return "自动"; case .wifi: return "Wi-Fi"; case .usb: return "USB" } }
}

public actor ReadPicoTFStore: ReadPicoContentStore {
    public nonisolated let rootURL: URL
    private let files = FileManager.default
    private let rootDevice: UInt64, rootInode: UInt64
    public init(rootURL: URL) throws {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey, .isVolumeKey])
        guard values.isDirectory == true else { throw ReadPicoManagerError.invalid("请选择阅读器的 TF 磁盘或卡片根目录。") }
        let parent = root.deletingLastPathComponent().lastPathComponent
        guard values.isVolume == true || (!["books", "fonts", "apps", "readpico"].contains(root.lastPathComponent.lowercased()) &&
              !(parent == "apps" && ["games", "tools", "data"].contains(root.lastPathComponent.lowercased()))) else {
            throw ReadPicoManagerError.invalid("请选择 TF 磁盘的最外层根目录，不要选择 books、apps 或字体文件夹。")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            throw ReadPicoManagerError.unavailable("无法核对 TF 磁盘身份，请重新选择磁盘。")
        }
        rootDevice = device; rootInode = inode
        self.rootURL = root
    }
    /// A detached card or another volume mounted at the old path must never receive stale writes.
    public func verifyAvailable(writing: Bool = false) throws {
        guard let attributes = try? files.attributesOfItem(atPath: rootURL.path),
              (attributes[.systemNumber] as? NSNumber)?.uint64Value == rootDevice,
              (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == rootInode,
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ReadPicoManagerError.unavailable("TF 磁盘已断开或已更换。请重新连接并选择磁盘，尚未开始的文件不会写入。")
        }
        if writing, !files.isWritableFile(atPath: rootURL.path) {
            throw ReadPicoManagerError.unavailable("TF 磁盘为只读，无法导入或移除。请检查读卡器写保护或磁盘状态。")
        }
    }
    private func safe(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else { throw ReadPicoManagerError.invalid("文件路径无效。") }
        var url = rootURL
        for part in parts {
            url.appendPathComponent(String(part))
            if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true { throw ReadPicoManagerError.invalid("不能管理指向卡片外部的符号链接。") }
        }
        return url
    }
    private func boundedData(_ url: URL, limit: Int) throws -> Data {
        var currentURL = url; currentURL.removeAllCachedResourceValues()
        let values = try currentURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= limit else { throw ReadPicoManagerError.invalid("文件大小或类型无效。") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == size else { throw ReadPicoManagerError.unavailable("卡片在读取时断开，请重新连接。") }; return data
    }
    public func scan() throws -> [ReadPicoCardFile] {
        try verifyAvailable()
        var result: [ReadPicoCardFile] = []
        for directory in ["", "books", "fonts", "apps/games", "apps/tools", "apps/data/drawing-notes"] {
            let url = directory.isEmpty ? rootURL : try safe(directory)
            if !files.fileExists(atPath: url.path) { continue }
            let children = try files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            for child in children {
                let values = try child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let ext = child.pathExtension.lowercased(), relative = directory.isEmpty ? child.lastPathComponent : directory + "/" + child.lastPathComponent
                var title = child.deletingPathExtension().lastPathComponent, kind: ReadPicoFileKind, detail = "", valid = true
                if directory == "" || directory == "books" { guard ["txt", "epub"].contains(ext) else { continue }; kind = directory == "books" && child.lastPathComponent.hasPrefix("灵犀笔记-") ? .note : .book; detail = ext.uppercased() }
                else if directory == "fonts" {
                    guard ["ttf", "otf"].contains(ext) else { continue }; kind = .font; detail = ext.uppercased()
                    if ext == "otf" { valid = false; detail = "OTF · Pico 不支持此字体格式" }
                } else if directory == "apps/games" || directory == "apps/tools" {
                    guard ext == "pga" else { continue }; kind = .application
                    do { let package = try ReadPicoPackage(data: boundedData(child, limit: 4 * 1024 * 1024)); guard child.deletingPathExtension().lastPathComponent == package.id, package.isTool == (directory == "apps/tools") else { throw ReadPicoManagerError.invalid("文件名与应用 ID 不符") }; title = package.title; detail = "\(package.isTool ? "工具" : "游戏") · \(package.versionLabel)" }
                    catch { valid = false; detail = error.localizedDescription }
                } else {
                    guard ext == "dat", child.lastPathComponent.range(of: #"^board(0[1-9]|1[0-2])\.dat$"#, options: .regularExpression) != nil else { continue }; kind = .drawing
                    do { let drawing = try ReadPicoDrawing(data: boundedData(child, limit: 12 + 49168)); title = "原稿 \(child.lastPathComponent.dropFirst(5).prefix(2))"; detail = "\(drawing.points.count) 个笔迹点 · \(drawing.width) × \(drawing.height)" }
                    catch { valid = false; detail = error.localizedDescription }
                }
                result.append(ReadPicoCardFile(relativePath: relative, title: title, kind: kind, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate, detail: detail, valid: valid))
            }
        }
        return result.sorted { $0.kind.rawValue == $1.kind.rawValue ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.kind.rawValue < $1.kind.rawValue }
    }
    public func proposedPath(for source: URL, kind: ReadPicoFileKind) throws -> String {
        try ReadPicoContentRules.proposedPath(for: source, kind: kind)
    }
    private func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { try Task.checkCancellation(); hash.update(data: chunk) }; return hash.finalize()
    }
    public func isIdentical(_ source: URL, kind: ReadPicoFileKind) throws -> Bool {
        try verifyAvailable()
        var currentSource = source; currentSource.removeAllCachedResourceValues()
        let values = try currentSource.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ReadPicoManagerError.invalid("同步源必须为普通文件。") }
        let destination = try safe(proposedPath(for: source, kind: kind))
        guard files.fileExists(atPath: destination.path) else { return false }
        let same = try digest(source) == digest(destination)
        try verifyAvailable()
        return same
    }
    @discardableResult public func importFile(_ source: URL, kind: ReadPicoFileKind, replace: Bool = false, progress: (@Sendable (Int64, Int64, String) -> Void)? = nil) throws -> String {
        try verifyAvailable(writing: true)
        let relative = try proposedPath(for: source, kind: kind), destination = try safe(relative), parent = destination.deletingLastPathComponent()
        if kind == .application {
            // Never install one stable ID into both categories.
            let otherDirectory = relative.hasPrefix("apps/tools/") ? "apps/games/" : "apps/tools/"
            let other = try safe(otherDirectory + destination.lastPathComponent)
            if files.fileExists(atPath: other.path) { throw ReadPicoManagerError.conflict("另一个应用分类中已存在相同 ID，请先移除旧包；存档会保留。") }
        }
        if files.fileExists(atPath: destination.path) && !replace { throw ReadPicoManagerError.conflict("卡片已存在同名内容，请确认是否替换。") }
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".pico-\(UUID().uuidString).tmp")
        defer { try? files.removeItem(at: staging) }
        var currentSource = source; currentSource.removeAllCachedResourceValues()
        let sourceValues = try currentSource.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true, let size = sourceValues.fileSize, size <= 256 * 1024 * 1024 else { throw ReadPicoManagerError.invalid("请选择不超过 256 MB 的普通文件。") }
        guard files.createFile(atPath: staging.path, contents: nil) else { throw ReadPicoManagerError.unavailable("无法创建传输暂存文件。") }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: staging)
        defer { try? input.close(); try? output.close() }
        var copied: Int64 = 0
        progress?(0, Int64(size), "copying")
        while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            try verifyAvailable(writing: true)
            try output.write(contentsOf: chunk); copied += Int64(chunk.count)
            guard copied <= size else { throw ReadPicoManagerError.invalid("源文件在复制期间发生变化。") }
            progress?(copied, Int64(size), "copying")
        }
        guard copied == size else { throw ReadPicoManagerError.unavailable("源文件“\(source.lastPathComponent)”没有完整读取（\(copied) / \(size) 字节），未提交。") }
        try output.synchronize(); try output.close(); try input.close()
        try Task.checkCancellation()
        progress?(copied, Int64(size), "verifying")
        guard try digest(source) == digest(staging) else { throw ReadPicoManagerError.unavailable("复制校验未通过，旧文件已保留。") }
        if kind == .application {
            let package = try ReadPicoPackage(data: boundedData(staging, limit: 4 * 1024 * 1024))
            guard package.id + ".pga" == destination.lastPathComponent,
                  package.isTool == relative.hasPrefix("apps/tools/") else { throw ReadPicoManagerError.invalid("应用包在复制期间发生变化，未安装。") }
        }
        let handle = try FileHandle(forWritingTo: staging); try handle.synchronize(); try handle.close()
        try verifyAvailable(writing: true)
        try Task.checkCancellation()
        progress?(Int64(try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), Int64(try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), "committing")
        // A same-directory rename never exposes a partly copied package or truncates the old file first.
        guard Darwin.rename(staging.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if kind == .application {
            let oldBackup = try safe(relative + ".bak")
            if files.fileExists(atPath: oldBackup.path) { try files.removeItem(at: oldBackup) }
        }
        return relative
    }
    public func remove(_ item: ReadPicoCardFile) throws {
        try verifyAvailable(writing: true)
        guard item.kind != .drawing else { throw ReadPicoManagerError.invalid("请在阅读器画板内管理原稿；Mac 不删除笔迹。") }
        let parts = item.relativePath.split(separator: "/")
        let ext = URL(fileURLWithPath: item.relativePath).pathExtension.lowercased()
        let managedBook = item.kind == .book && ["epub", "txt"].contains(ext) && (parts.count == 1 || parts.count == 2 && parts.first == "books")
        let managedApplication = item.kind == .application && ext == "pga" && parts.count == 3 && parts[0] == "apps" && ["games", "tools"].contains(String(parts[1]))
        let managedFont = item.kind == .font && ["ttf", "otf"].contains(ext) && parts.count == 2 && parts.first == "fonts"
        let managedNote = item.kind == .note && ext == "txt" && parts.count == 2 && parts.first == "books" && parts.last?.hasPrefix("灵犀笔记-") == true
        guard managedBook || managedApplication || managedFont || managedNote else { throw ReadPicoManagerError.invalid("只能移除书架图书或应用包，不能移除设置、存档和其他 TF 文件。") }
        let target = try safe(item.relativePath)
        if item.kind == .application { let backup = try safe(item.relativePath + ".bak"); if files.fileExists(atPath: backup.path) { try files.removeItem(at: backup) } }
        try files.removeItem(at: target)
    }
    public func export(_ item: ReadPicoCardFile, to destination: URL, format: String = "dat") throws {
        try verifyAvailable()
        let source = try safe(item.relativePath)
        if item.kind == .drawing, format != "dat" {
            let drawing = try ReadPicoDrawing(data: boundedData(source, limit: 12 + 49168))
            guard ["svg", "png"].contains(format) else { throw ReadPicoManagerError.invalid("请选择原稿、SVG 或 PNG。") }
            try (format == "svg" ? drawing.svg() : drawing.png()).write(to: destination, options: .atomic)
        } else if item.kind == .drawing { try boundedData(source, limit: 12 + 49168).write(to: destination, options: .atomic) }
        else { try files.copyItem(at: source, to: destination) }
    }
}

/// The setup key lives in this object only; never persist it in settings, logs or backups.
public struct ReadPicoConnection: Equatable, Sendable {
    public let baseURL: URL, setupKey: String, previewSession: String?
    public init(address: String, setupKey: String = "") throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed.contains("://") ? trimmed : "http://" + trimmed),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { throw ReadPicoManagerError.invalid("请粘贴阅读器“手机管理”页面显示的完整连接地址。") }
        let fragment = URLComponents(string: "http://key/?" + (components.fragment ?? ""))?.queryItems?.first { $0.name == "key" }?.value ?? ""
        let key = setupKey.isEmpty ? fragment : setupKey
        guard key.count == 32, key.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw ReadPicoManagerError.invalid("需要设备显示的 32 位临时配对码，或含 #key= 的完整链接。") }
        self.previewSession = components.queryItems?.first { $0.name == "session" }?.value
        components.path = ""; components.query = nil; components.fragment = nil
        guard let url = components.url else { throw ReadPicoManagerError.invalid("设备地址无效。") }
        self.baseURL = url; self.setupKey = key
    }
    public var managementURL: URL {
        var url = URLComponents(url: baseURL.appendingPathComponent("manage"), resolvingAgainstBaseURL: false)!
        if let previewSession { url.queryItems = [URLQueryItem(name: "session", value: previewSession)] }
        url.fragment = "key=" + setupKey; return url.url!
    }
}
/// Short-lived on-device LAN QR portal (`portal` / `home_portal`). Secrets never appear here.
public struct ReadPicoHomePortal: Codable, Equatable, Sendable {
    public var active: Bool
    public var phase: String
    public var revision: Int
    public var secondsLeft: Int
    public var writer: String
    public init(active: Bool = false, phase: String = "idle", revision: Int = 0, secondsLeft: Int = 0, writer: String = "") {
        self.active = active; self.phase = phase; self.revision = revision; self.secondsLeft = secondsLeft; self.writer = writer
    }
    enum CodingKeys: String, CodingKey {
        case active, phase, revision, writer
        case secondsLeft = "seconds_left"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? "idle"
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        secondsLeft = try c.decodeIfPresent(Int.self, forKey: .secondsLeft) ?? 0
        writer = try c.decodeIfPresent(String.self, forKey: .writer) ?? ""
    }
}

public struct ReadPicoHomeConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool, local: String, external: String, homeWifi: String, externalEnabled: Bool, externalControl: Bool, hasToken: Bool
    public var hasCfAccessClientId: Bool, hasCfAccessClientSecret: Bool
    public init(enabled: Bool = false, local: String = "", external: String = "", homeWifi: String = "", externalEnabled: Bool = false, externalControl: Bool = false, hasToken: Bool = false, hasCfAccessClientId: Bool = false, hasCfAccessClientSecret: Bool = false) {
        self.enabled = enabled; self.local = local; self.external = external; self.homeWifi = homeWifi; self.externalEnabled = externalEnabled; self.externalControl = externalControl; self.hasToken = hasToken
        self.hasCfAccessClientId = hasCfAccessClientId; self.hasCfAccessClientSecret = hasCfAccessClientSecret
    }
    enum CodingKeys: String, CodingKey {
        case enabled, local, external
        case homeWifi = "home_wifi", externalEnabled = "external_enabled", externalControl = "external_control", hasToken = "has_token"
        case hasCfAccessClientId = "has_cf_access_client_id", hasCfAccessClientSecret = "has_cf_access_client_secret"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        local = try c.decodeIfPresent(String.self, forKey: .local) ?? ""
        external = try c.decodeIfPresent(String.self, forKey: .external) ?? ""
        homeWifi = try c.decodeIfPresent(String.self, forKey: .homeWifi) ?? ""
        externalEnabled = try c.decodeIfPresent(Bool.self, forKey: .externalEnabled) ?? false
        externalControl = try c.decodeIfPresent(Bool.self, forKey: .externalControl) ?? false
        hasToken = try c.decodeIfPresent(Bool.self, forKey: .hasToken) ?? false
        hasCfAccessClientId = try c.decodeIfPresent(Bool.self, forKey: .hasCfAccessClientId) ?? false
        hasCfAccessClientSecret = try c.decodeIfPresent(Bool.self, forKey: .hasCfAccessClientSecret) ?? false
    }
}
public struct ReadPicoHomeSnapshot: Decodable, Sendable {
    public let config: ReadPicoHomeConfiguration, savedWifi: [String], networkOnline: Bool
    public let portal: ReadPicoHomePortal?
    enum CodingKeys: String, CodingKey {
        case config, portal
        case savedWifi = "saved_wifi", networkOnline = "network_online"
    }
    public init(config: ReadPicoHomeConfiguration, savedWifi: [String], networkOnline: Bool, portal: ReadPicoHomePortal? = nil) {
        self.config = config; self.savedWifi = savedWifi; self.networkOnline = networkOnline; self.portal = portal
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try c.decodeIfPresent(ReadPicoHomeConfiguration.self, forKey: .config) ?? ReadPicoHomeConfiguration()
        savedWifi = try c.decodeIfPresent([String].self, forKey: .savedWifi) ?? []
        networkOnline = try c.decodeIfPresent(Bool.self, forKey: .networkOnline) ?? false
        portal = try c.decodeIfPresent(ReadPicoHomePortal.self, forKey: .portal)
    }
}

/// Aggregate `GET /api/manage/pico/home-link` (pga; full returns 404). No `saved_wifi` — use home GET for SSIDs.
public struct ReadPicoHomeLinkDocument: Decodable, Sendable {
    public let ok: Bool?
    public let homeLinkMode: String?
    public let writer: String?
    public let portal: ReadPicoHomePortal?
    public let config: ReadPicoHomeConfiguration
    public let networkOnline: Bool
    public let atHome: Bool?
    enum CodingKeys: String, CodingKey {
        case ok, portal, config, writer
        case homeLinkMode = "home_link_mode"
        case networkOnline = "network_online"
        case atHome = "at_home"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
        homeLinkMode = try c.decodeIfPresent(String.self, forKey: .homeLinkMode)
        writer = try c.decodeIfPresent(String.self, forKey: .writer)
        portal = try c.decodeIfPresent(ReadPicoHomePortal.self, forKey: .portal)
        config = try c.decodeIfPresent(ReadPicoHomeConfiguration.self, forKey: .config) ?? ReadPicoHomeConfiguration()
        networkOnline = try c.decodeIfPresent(Bool.self, forKey: .networkOnline) ?? false
        atHome = try c.decodeIfPresent(Bool.self, forKey: .atHome)
    }
    public var asHomeSnapshot: ReadPicoHomeSnapshot {
        ReadPicoHomeSnapshot(config: config, savedWifi: [], networkOnline: networkOnline, portal: portal)
    }
}
/// Destination storage is separate from the pixel container. A named app never overwrites the shared board.
public enum ReadPicoContentChannel: String, Codable, Sendable {
    case canvas, cloudflare
}
public struct ReadPicoCanvasReceipt: Decodable, Sendable {
    public let state: String?
    public let revision: UInt32?
    public let orientation: String?
}
public struct ReadPicoCanvasCapability: Decodable, Sendable {
    public let supported: Bool, width: Int, height: Int, formats: [String], maxBytes: Int
    public let state: String?, revision: UInt32?
    public let grayLevels: Int?, bitDepths: [Int]?
    public let displayIntent: Bool?
    public let dualOrientation: Bool?, pairMaxBytes: Int?
    public let modelProtocol: Int?, modelMaxBytes: Int?
    public var supportsModel: Bool { supported && modelProtocol == 1 && (modelMaxBytes ?? 0) >= ReadPicoBoardModel.maximumBytes }
    public let orientation: String?
    public let appChannels: [String]?
    public let appReceipts: [String: ReadPicoCanvasReceipt]?
    public func supports(_ channel: ReadPicoContentChannel) -> Bool {
        channel == .canvas || appChannels?.contains(channel.rawValue) == true
    }
    public func receipt(for channel: ReadPicoContentChannel) -> ReadPicoCanvasReceipt? {
        channel == .canvas ? .init(state: state, revision: revision, orientation: orientation) : appReceipts?[channel.rawValue]
    }
    public var supportsDualOrientation: Bool { supportsNativeGray16 && dualOrientation == true && (pairMaxBytes ?? 0) >= 834444 }
    public var supportsNativeGray16: Bool {
        supported && grayLevels == 16 && bitDepths?.contains(4) == true &&
        formats.contains("image/bmp") && maxBytes >= 418422 &&
        ((width == 684 && height == 1216) || (width == 1216 && height == 684))
    }
    enum CodingKeys: String, CodingKey {
        case supported, width, height, formats, state, revision
        case maxBytes = "max_bytes", grayLevels = "gray_levels", bitDepths = "bit_depths", displayIntent = "display_intent"
        case dualOrientation = "dual_orientation", pairMaxBytes = "pair_max_bytes", orientation
        case modelProtocol = "model_protocol", modelMaxBytes = "model_max_bytes"
        case appChannels = "app_channels", appReceipts = "app_receipts"
    }
}
public struct ReadPicoDeviceConfiguration: Codable, Equatable, Sendable {
    public var autoSleepMinutes: Int, doubleTapWake: Bool, state: Int, revision: UInt32
    public var lockStyle: Int?, coverLayout: Int?
    public static let allowedSleepMinutes = [0, 1, 3, 5, 10, 30]
    public init(autoSleepMinutes: Int = 5, doubleTapWake: Bool = true, state: Int = 0, revision: UInt32 = 0, lockStyle: Int? = nil, coverLayout: Int? = nil) {
        self.autoSleepMinutes = autoSleepMinutes; self.doubleTapWake = doubleTapWake; self.state = state; self.revision = revision
        self.lockStyle = lockStyle; self.coverLayout = coverLayout
    }
    enum CodingKeys: String, CodingKey { case autoSleepMinutes = "auto_sleep_minutes", doubleTapWake = "double_tap_wake", state, revision, lockStyle = "lock_style", coverLayout = "cover_layout" }
}
public struct ReadPicoImageLockCapability: Decodable, Sendable {
    public let supported: Bool, available: Bool, state: String, revision: UInt32
    public let width: Int, height: Int, formats: [String], maxBytes: Int
    public let grayLevels: Int?, bitDepths: [Int]?
    public var supportsNativeGray16: Bool {
        supported && grayLevels == 16 && bitDepths?.contains(4) == true &&
        formats.contains("image/bmp") && maxBytes >= 418422
    }
    enum CodingKeys: String, CodingKey {
        case supported, available, state, revision, width, height, formats
        case maxBytes = "max_bytes", grayLevels = "gray_levels", bitDepths = "bit_depths"
    }
}
public struct ReadPicoCapabilities: Decodable, Sendable {
    public let `protocol`: Int, canvas: ReadPicoCanvasCapability, config: ReadPicoDeviceConfiguration?
    public let imageLock: ReadPicoImageLockCapability?
    public let power: ReadPicoPowerStatus?
    public let content: ReadPicoContentCapability?
    /// Additive `home_link_mode` from pico/status; absent on older firmware.
    public let homeLinkMode: String?
    /// Additive `home_portal` from pico/status on pga/full.
    public let homePortal: ReadPicoHomePortal?
    enum CodingKeys: String, CodingKey {
        case `protocol`, canvas, config, imageLock = "image_lock", power, content
        case homeLinkMode = "home_link_mode", homePortal = "home_portal"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.protocol = try c.decode(Int.self, forKey: .protocol)
        canvas = try c.decode(ReadPicoCanvasCapability.self, forKey: .canvas)
        config = try c.decodeIfPresent(ReadPicoDeviceConfiguration.self, forKey: .config)
        imageLock = try c.decodeIfPresent(ReadPicoImageLockCapability.self, forKey: .imageLock)
        power = try? c.decodeIfPresent(ReadPicoPowerStatus.self, forKey: .power)
        content = try c.decodeIfPresent(ReadPicoContentCapability.self, forKey: .content)
        homeLinkMode = try c.decodeIfPresent(String.self, forKey: .homeLinkMode)
        homePortal = try c.decodeIfPresent(ReadPicoHomePortal.self, forKey: .homePortal)
    }
}
public struct ReadPicoContentCapability: Codable, Equatable, Sendable {
    public let supported: Bool, maxBytes: Int, maxPageItems: Int
    enum CodingKeys: String, CodingKey { case supported; case maxBytes = "max_bytes", maxPageItems = "max_page_items" }
    public var isUsable: Bool { supported && maxBytes > 0 && maxBytes <= 256 * 1024 * 1024 && (1...64).contains(maxPageItems) }
}
private final class ReadPicoNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
private final class ReadPicoUploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let callback: (@Sendable (Int64, Int64, String) -> Void)?
    private let bytes: Int64, lock = NSLock()
    private var lastUpdate = Date.distantPast
    private var completed = false
    init(bytes: Int64, callback: (@Sendable (Int64, Int64, String) -> Void)?) { self.bytes = bytes; self.callback = callback }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return }
        let now = Date(), shouldNotify = now.timeIntervalSince(lastUpdate) >= 0.1 || totalBytesSent >= bytes
        if shouldNotify { lastUpdate = now }
        if shouldNotify { callback?(min(bytes, totalBytesSent), bytes, "sending") }
    }
    func finishSending() {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return }; completed = true
        callback?(bytes, bytes, "sending")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public actor ReadPicoHTTPClient: ReadPicoContentStore {
    public let connection: ReadPicoConnection
    private let session: URLSession
    public init(connection: ReadPicoConnection, session: URLSession? = nil) {
        self.connection = connection
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 1800; config.urlCache = nil
        self.session = session ?? URLSession(configuration: config, delegate: ReadPicoNoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    private func makeRequest(_ path: String, method: String = "GET", data: Data? = nil, contentType: String = "application/json", query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: connection.baseURL.appendingPathComponent("api/manage/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            // Preserve a literal plus in FAT filenames even on form-style query decoders.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var request = URLRequest(url: components.url!); request.httpMethod = method; request.httpBody = data
        request.setValue(connection.setupKey, forHTTPHeaderField: "X-Pico-Setup-Key"); request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let preview = connection.previewSession { request.setValue(preview, forHTTPHeaderField: "X-Pico-Preview-Session") }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
    private func manageErrorCode(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return object["error"] as? String
    }
    private func checkedResponse(_ response: URLResponse, bytes: Int, limit: Int, errorBody: Data = Data()) throws {
        guard let response = response as? HTTPURLResponse, bytes >= 0, bytes <= limit else { throw ReadPicoManagerError.invalid("设备响应格式或大小无效。") }
        if response.statusCode == 401 { throw ReadPicoManagerError.expired }
        if response.statusCode == 409 {
            if manageErrorCode(from: errorBody) == "home_portal_active" {
                throw ReadPicoManagerError.homePortalActive
            }
            throw ReadPicoManagerError.conflict("设备已有同名的不同内容，或存储正在使用。请核对文件后再明确替换，勿重复同步。")
        }
        if (200...299).contains(response.statusCode) { return }
        // Thin-host Home Link stubs return 503 + home_module_missing; never map that to TF storage copy.
        if manageErrorCode(from: errorBody) == "home_module_missing" {
            throw ReadPicoManagerError.homeModuleMissing
        }
        if response.statusCode == 503 { throw ReadPicoManagerError.unavailable("设备存储暂不可用。请结束 USB 文件传输、确认 TF 卡已挂载后重试。") }
        throw ReadPicoManagerError.http(response.statusCode)
    }
    private func checkedResponse(_ response: URLResponse, body: Data, limit: Int) throws {
        try checkedResponse(response, bytes: body.count, limit: limit, errorBody: body)
    }
    private func request(_ path: String, method: String = "GET", data: Data? = nil, contentType: String = "application/json", responseLimit: Int = 131072, query: [URLQueryItem] = []) async throws -> Data {
        let request = makeRequest(path, method: method, data: data, contentType: contentType, query: query)
        let (body, response) = try await session.data(for: request)
        try checkedResponse(response, body: body, limit: responseLimit)
        return body
    }
    private struct ContentPage: Decodable {
        struct Item: Decodable {
            let path: String, title: String, kind: String, bytes: Int64
            let modified: Double?, detail: String?, valid: Bool?
        }
        let ok: Bool, items: [Item], offset: Int, total: Int
    }
    private struct ContentReceipt: Decodable {
        let ok: Bool, path: String, bytes: Int64, sha256: String
        func matches(path expectedPath: String, bytes expectedBytes: Int64? = nil, sha256 expectedSHA: String? = nil) -> Bool {
            ok && path == expectedPath && bytes >= 0 && bytes <= 256 * 1024 * 1024 &&
            sha256.count == 64 && sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
            (expectedBytes == nil || bytes == expectedBytes) && (expectedSHA == nil || sha256 == expectedSHA)
        }
    }
    private func contentSupport() async throws -> ReadPicoContentCapability {
        let status = try await capabilities()
        guard status.protocol == 1, let content = status.content, content.isUsable else {
            throw ReadPicoManagerError.unavailable("当前固件尚未开放 Wi-Fi 内容管理，请更新固件或使用 USB。")
        }
        return content
    }
    public func scan() async throws -> [ReadPicoCardFile] {
        let support = try await contentSupport()
        var files: [ReadPicoCardFile] = [], seen = Set<String>(), expectedTotal: Int?
        repeat {
            try Task.checkCancellation()
            let page = try JSONDecoder().decode(ContentPage.self, from: await request("pico/files", query: [
                .init(name: "offset", value: String(files.count)), .init(name: "limit", value: String(support.maxPageItems))]))
            guard page.ok, page.offset == files.count, (0...10000).contains(page.total),
                  page.items.count <= support.maxPageItems, page.offset + page.items.count <= page.total,
                  expectedTotal == nil || expectedTotal == page.total,
                  !page.items.isEmpty || files.count == page.total else {
                throw ReadPicoManagerError.invalid("设备文件列表已变化或格式无效，请重新刷新。")
            }
            expectedTotal = page.total
            for item in page.items {
                guard let kind = ReadPicoFileKind(rawValue: item.kind), item.bytes >= 0, item.bytes <= 256 * 1024 * 1024,
                      item.title.utf8.count <= 2048, (item.detail?.utf8.count ?? 0) <= 2048, seen.insert(item.path).inserted else {
                    throw ReadPicoManagerError.invalid("设备文件列表包含无效或重复项目。")
                }
                try ReadPicoContentRules.path(item.path, kind: kind)
                files.append(.init(relativePath: item.path, title: item.title, kind: kind, bytes: item.bytes,
                                   modified: item.modified.map { Date(timeIntervalSince1970: $0) }, detail: item.detail ?? "", valid: item.valid ?? true))
            }
        } while files.count < (expectedTotal ?? 0)
        return files.sorted { $0.kind.rawValue == $1.kind.rawValue ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.kind.rawValue < $1.kind.rawValue }
    }
    public func proposedPath(for source: URL, kind: ReadPicoFileKind) throws -> String {
        try ReadPicoContentRules.proposedPath(for: source, kind: kind)
    }
    private func fileDigest(_ source: URL) throws -> (Int64, String) {
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ReadPicoManagerError.invalid("无法读取普通同步源文件。") }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 256 * 1024 * 1024 else {
            throw ReadPicoManagerError.invalid("请选择不超过 256 MB 的非空普通文件。")
        }
        var digest = SHA256(), count: Int64 = 0
        while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); count += Int64(chunk.count)
            guard count <= info.st_size else { throw ReadPicoManagerError.invalid("同步源文件在读取时发生变化。") }
            digest.update(data: chunk)
        }
        guard count == info.st_size else { throw ReadPicoManagerError.invalid("同步源文件读取不完整。") }
        return (count, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    public func isIdentical(_ source: URL, kind: ReadPicoFileKind) async throws -> Bool {
        let path = try proposedPath(for: source, kind: kind)
        let receipt: ContentReceipt
        do {
            receipt = try JSONDecoder().decode(ContentReceipt.self, from: await request("pico/file", query: [
                .init(name: "path", value: path), .init(name: "metadata", value: "1")]))
        } catch ReadPicoManagerError.http(404) { return false }
        guard receipt.matches(path: path) else { throw ReadPicoManagerError.invalid("设备文件校验信息无效。") }
        let local = try fileDigest(source)
        return receipt.matches(path: path, bytes: local.0, sha256: local.1)
    }
    @discardableResult public func importFile(_ source: URL, kind: ReadPicoFileKind, replace: Bool = false,
                                              progress: (@Sendable (Int64, Int64, String) -> Void)? = nil) async throws -> String {
        let support = try await contentSupport()
        _ = try proposedPath(for: source, kind: kind)
        // Upload an immutable owned snapshot, so retry/verification never observes a changed original.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("readpico-upload-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = directory.appendingPathComponent(source.lastPathComponent)
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ReadPicoManagerError.invalid("无法打开同步源文件。") }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= support.maxBytes else {
            throw ReadPicoManagerError.invalid("文件为空、不是普通文件或超过当前固件传输限制。")
        }
        guard FileManager.default.createFile(atPath: snapshot.path, contents: nil) else { throw ReadPicoManagerError.unavailable("无法创建同步暂存文件。") }
        let output = try FileHandle(forWritingTo: snapshot)
        defer { try? output.close() }
        var count: Int64 = 0, digest = SHA256()
        progress?(0, Int64(info.st_size), "preparing")
        while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); count += Int64(chunk.count)
            guard count <= info.st_size else { throw ReadPicoManagerError.invalid("同步源文件在读取时发生变化。") }
            try output.write(contentsOf: chunk); digest.update(data: chunk)
        }
        guard count == info.st_size else { throw ReadPicoManagerError.invalid("同步源文件读取不完整。") }
        try output.synchronize(); try output.close(); try input.close()
        let path = try proposedPath(for: snapshot, kind: kind)
        try ReadPicoContentRules.path(path, kind: kind)
        let sha = digest.finalize().map { String(format: "%02x", $0) }.joined()
        var request = makeRequest("pico/files", method: "PUT", contentType: "application/octet-stream", query: [
            .init(name: "path", value: path), .init(name: "replace", value: replace ? "1" : "0")])
        request.timeoutInterval = 1800
        request.setValue(sha, forHTTPHeaderField: "X-Pico-Content-SHA256")
        try Task.checkCancellation(); progress?(0, count, "sending")
        let uploadProgress = ReadPicoUploadProgress(bytes: count, callback: progress)
        let (body, response) = try await session.upload(for: request, fromFile: snapshot, delegate: uploadProgress)
        try checkedResponse(response, body: body, limit: 131072)
        // URLSession may coalesce all byte callbacks for a small upload. A successful upload
        // response confirms the whole body was sent; close that stage before verification.
        uploadProgress.finishSending()
        progress?(count, count, "verifying")
        let receipt = try JSONDecoder().decode(ContentReceipt.self, from: body)
        guard receipt.matches(path: path, bytes: count, sha256: sha) else {
            throw ReadPicoManagerError.unavailable("设备已接收文件，但保存校验尚未确认。请刷新设备内容后再核对，勿重复替换。")
        }
        try Task.checkCancellation()
        return path
    }
    public func remove(_ item: ReadPicoCardFile) async throws {
        try ReadPicoContentRules.path(item.relativePath, kind: item.kind, removing: true)
        let data = try await request("pico/files", method: "DELETE", query: [.init(name: "path", value: item.relativePath)])
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any], reply["ok"] as? Bool == true,
              reply["path"] as? String == item.relativePath else { throw ReadPicoManagerError.invalid("设备尚未确认文件移除，请刷新后核对。") }
    }
    public func export(_ item: ReadPicoCardFile, to destination: URL, format: String = "dat") async throws {
        try ReadPicoContentRules.path(item.relativePath, kind: item.kind)
        let expected = try JSONDecoder().decode(ContentReceipt.self, from: await request("pico/file", query: [
            .init(name: "path", value: item.relativePath), .init(name: "metadata", value: "1")]))
        guard expected.matches(path: item.relativePath, bytes: item.bytes) else { throw ReadPicoManagerError.invalid("设备文件已变化，请刷新内容列表后重新导出。") }
        let request = makeRequest("pico/file", query: [.init(name: "path", value: item.relativePath)])
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        var errorProbe = Data()
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode), size > 0 {
            if let handle = try? FileHandle(forReadingFrom: temporary) {
                defer { try? handle.close() }
                errorProbe = (try? handle.read(upToCount: 4096)) ?? Data()
            }
        }
        try checkedResponse(response, bytes: size, limit: item.kind == .drawing ? 12 + 49168 : 256 * 1024 * 1024, errorBody: errorProbe)
        guard size >= 0, Int64(size) == item.bytes else { throw ReadPicoManagerError.invalid("设备文件在导出时发生变化或下载不完整。") }
        let actual = try fileDigest(temporary)
        guard expected.matches(path: item.relativePath, bytes: actual.0, sha256: actual.1) else { throw ReadPicoManagerError.invalid("下载校验未通过，原导出文件已保留。") }
        let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
        if item.kind == .drawing {
            let drawing = try ReadPicoDrawing(data: data)
            guard ["dat", "svg", "png"].contains(format) else { throw ReadPicoManagerError.invalid("请选择原稿、SVG 或 PNG。") }
            try (format == "svg" ? drawing.svg() : format == "png" ? drawing.png() : data).write(to: destination, options: .atomic)
        } else { try data.write(to: destination, options: .atomic) }
    }
    public func home() async throws -> ReadPicoHomeSnapshot { try JSONDecoder().decode(ReadPicoHomeSnapshot.self, from: await request("home")) }
    /// Aggregate home/config/portal/printers readback. Present on `pga`; `full` returns 404.
    public func homeLink() async throws -> ReadPicoHomeLinkDocument {
        try JSONDecoder().decode(ReadPicoHomeLinkDocument.self, from: await request("pico/home-link"))
    }
    public func saveHome(_ config: ReadPicoHomeConfiguration, token: String = "", cfAccessClientId: String = "", cfAccessClientSecret: String = "") async throws {
        func validateEndpoint(_ text: String, external: Bool) throws {
            if text.isEmpty { return }
            guard text.utf8.count <= 191, let url = URLComponents(string: text),
                  external ? url.scheme == "https" : ["http", "https"].contains(url.scheme ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw ReadPicoManagerError.invalid(external ? "外部地址请使用完整 HTTPS 地址，不包含账号或查询参数。" : "本地地址请使用完整 HTTP 或 HTTPS 地址，不包含账号或查询参数。")
            }
        }
        try validateEndpoint(config.local, external: false); try validateEndpoint(config.external, external: true)
        guard config.homeWifi.utf8.count <= 47, token.utf8.count <= 1023 else { throw ReadPicoManagerError.invalid("网络名称或访问令牌超过设备长度限制。") }
        guard cfAccessClientId.utf8.count <= 95, cfAccessClientSecret.utf8.count <= 63 else {
            throw ReadPicoManagerError.invalid("Cloudflare Access 客户端 ID（≤95）或密钥（≤63）超过设备长度限制。")
        }
        if !config.local.isEmpty && config.homeWifi.isEmpty { throw ReadPicoManagerError.invalid("请为本地连接选择已记忆的家庭 Wi-Fi。") }
        if config.externalEnabled && config.external.isEmpty { throw ReadPicoManagerError.invalid("请填写外部服务器地址。") }
        var body: [String: Any] = ["enabled": config.enabled, "local": config.local, "external": config.external, "home_wifi": config.homeWifi, "external_enabled": config.externalEnabled, "external_control": config.externalControl]
        if !token.isEmpty { body["ha_token"] = token }
        // Write-only CF Access Service Token for external HTTPS HA only (not Cloudflare Analytics).
        if !cfAccessClientId.isEmpty { body["cf_access_client_id"] = cfAccessClientId }
        if !cfAccessClientSecret.isEmpty { body["cf_access_client_secret"] = cfAccessClientSecret }
        let data = try await request("home", method: "PUT", data: JSONSerialization.data(withJSONObject: body))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["ok"] as? Bool == true else {
            throw ReadPicoManagerError.invalid("设备没有确认保存设置。")
        }
        // Success body may include queued + portal; callers re-GET for authoritative public fields.
        _ = object["queued"]
        _ = object["portal"]
    }
    public func capabilities() async throws -> ReadPicoCapabilities { try JSONDecoder().decode(ReadPicoCapabilities.self, from: await request("pico/status")) }
    /// HTTP acceptance is distinct from the UI task's atomic NVS commit.
    public func saveDeviceConfiguration(_ configuration: ReadPicoDeviceConfiguration) async throws -> ReadPicoCapabilities {
        guard ReadPicoDeviceConfiguration.allowedSleepMinutes.contains(configuration.autoSleepMinutes),
              let previous = try await capabilities().config else { throw ReadPicoManagerError.invalid("设备尚未开放电源配置，或休眠时间不受支持。") }
        var body: [String: Any] = ["auto_sleep_minutes": configuration.autoSleepMinutes, "double_tap_wake": configuration.doubleTapWake]
        if let style = configuration.lockStyle {
            guard (0...5).contains(style), previous.lockStyle != nil else {
                throw ReadPicoManagerError.unavailable("当前固件尚未开放锁屏样式设置，请更新固件后重试。")
            }
            body["lock_style"] = style
        }
        if let layout = configuration.coverLayout {
            guard (0...4).contains(layout), previous.coverLayout != nil else {
                throw ReadPicoManagerError.unavailable("当前固件尚未开放封面排布设置，请更新固件后重试。")
            }
            body["cover_layout"] = layout
        }
        let reply = try await request("pico/config", method: "PUT", data: JSONSerialization.data(withJSONObject: body))
        guard let response = try JSONSerialization.jsonObject(with: reply) as? [String: Any], response["ok"] as? Bool == true,
              response["accepted"] as? Bool == true else { throw ReadPicoManagerError.invalid("设备未接受配置请求。") }
        for _ in 0..<32 {
            try await Task.sleep(nanoseconds: 250_000_000)
            let status: ReadPicoCapabilities
            do { status = try await capabilities() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                throw ReadPicoManagerError.unavailable("设置请求已提交，但连接中断，尚未确认保存。请重新连接后核对。" + error.localizedDescription)
            }
            guard let current = status.config else { throw ReadPicoManagerError.invalid("设备配置状态未返回，无法确认保存。") }
            if current.state == 3 { throw ReadPicoManagerError.unavailable("设备保存设置失败；原设置保留，请重试。") }
            if current.state == 2, current.revision != previous.revision,
               current.autoSleepMinutes == configuration.autoSleepMinutes, current.doubleTapWake == configuration.doubleTapWake,
               configuration.lockStyle == nil || current.lockStyle == configuration.lockStyle,
               configuration.coverLayout == nil || current.coverLayout == configuration.coverLayout { return status }
        }
        throw ReadPicoManagerError.unavailable("请求已接收，但尚未确认保存。请保持连接，在设备上核对后重新读取。")
    }
    public func pushCanvas(_ bmp: Data, capability: ReadPicoCanvasCapability, display: Bool = false) async throws {
        try await pushCanvas(bmp, capability: capability, display: display, contentChannel: .canvas)
    }
    public func pushCanvas(_ bmp: Data, capability: ReadPicoCanvasCapability, display: Bool,
                           contentChannel: ReadPicoContentChannel) async throws {
        guard capability.supports(contentChannel) else { throw ReadPicoManagerError.unavailable("请更新设备固件，以支持 Cloudflare 独立应用。") }
        let model = ReadPicoBoardModel.isModel(bmp)
        guard contentChannel == .canvas || model || ReadPicoCanvasPair.isPair(bmp) else { throw ReadPicoManagerError.invalid("应用内容必须提供数据模型或横竖两种布局。") }
        let pair = ReadPicoCanvasPair.isPair(bmp)
        if model {
            guard capability.supportsModel else { throw ReadPicoManagerError.unavailable("请更新 Pico 固件以支持本机排版的数据画板；不会改发整屏截图。") }
            _ = try ReadPicoBoardModel.decode(bmp)
        } else if pair {
            guard capability.supportsDualOrientation, bmp.count <= (capability.pairMaxBytes ?? 0) else {
                throw ReadPicoManagerError.unavailable("请更新设备固件，以支持一次接收竖屏和横屏画面。")
            }
            try ReadPicoCanvasPair.validate(bmp)
        } else { try ReadPicoBitmap.validateCanvas(bmp, capability: capability) }
        guard !display || capability.displayIntent == true else { throw ReadPicoManagerError.unavailable("请更新设备固件，以支持发送后立即展示。") }
        let path = model ? (contentChannel == .canvas ? "pico/canvas/model" : "pico/apps/\(contentChannel.rawValue)/model")
            : contentChannel == .canvas ? (pair ? "pico/canvas/pair" : "pico/canvas") : "pico/apps/\(contentChannel.rawValue)/pair"
        let data = try await request(display ? path + "/show" : path, method: "POST", data: bmp,
                                     contentType: model ? "application/vnd.readpico.board-model+json" : pair ? "application/vnd.readpico.canvas-pair" : "image/bmp")
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any], body["ok"] as? Bool == true, body["accepted"] as? Bool == true else { throw ReadPicoManagerError.invalid("设备没有接收画布。") }
    }
    /// A saved receipt confirms delivery only; only displayed confirms panel presentation.
    public func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability,
                                    onAccepted: (@Sendable () async -> Void)? = nil) async throws -> ReadPicoCapabilities {
        try await pushCanvasConfirmed(bmp, capability: capability, display: false, onAccepted: onAccepted)
    }
    public func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, display: Bool,
                                    onAccepted: (@Sendable () async -> Void)? = nil) async throws -> ReadPicoCapabilities {
        try await pushCanvasConfirmed(bmp, capability: capability, display: display, contentChannel: .canvas, onAccepted: onAccepted)
    }
    public func pushCanvasConfirmed(_ bmp: Data, capability: ReadPicoCanvasCapability, display: Bool,
                                    contentChannel: ReadPicoContentChannel,
                                    onAccepted: (@Sendable () async -> Void)? = nil) async throws -> ReadPicoCapabilities {
        guard capability.supported else { throw ReadPicoManagerError.unavailable("设备尚未开放画布推送。") }
        let previous = try await capabilities()
        guard previous.protocol == 1, previous.canvas.supported, previous.canvas.supports(contentChannel),
              let previousReceipt = previous.canvas.receipt(for: contentChannel), let revision = previousReceipt.revision,
              previousReceipt.state != nil else { throw ReadPicoManagerError.unavailable("当前固件尚未提供画布显示确认，请更新固件后重试。") }
        try await pushCanvas(bmp, capability: previous.canvas, display: display, contentChannel: contentChannel)
        await onAccepted?()
        for _ in 0..<48 {
            try await Task.sleep(nanoseconds: 250_000_000)
            let current: ReadPicoCapabilities
            do { current = try await capabilities() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                throw ReadPicoManagerError.unavailable("画布已提交，但连接中断，尚未确认显示。请重新连接后核对。" + error.localizedDescription)
            }
            guard current.protocol == 1, current.canvas.supports(contentChannel),
                  let receipt = current.canvas.receipt(for: contentChannel), let state = receipt.state, let next = receipt.revision else {
                throw ReadPicoManagerError.unavailable("画布已提交，但设备没有返回显示状态，请在阅读器上核对。")
            }
            if state == "error" { throw ReadPicoManagerError.unavailable("设备未完成画布显示。请检查 TF 卡和屏幕状态后重试。") }
            if (state == "displayed" || state == "saved"), next != revision { return current }
        }
        throw ReadPicoManagerError.unavailable("画布已提交，但尚未确认显示。请保持连接，在阅读器上核对后重试。")
    }

    public func lockImage() async throws -> Data {
        let status = try await capabilities()
        guard status.protocol == 1, status.imageLock?.supported == true, status.imageLock?.available == true else {
            throw ReadPicoManagerError.unavailable("阅读器尚未保存自定义锁屏图片。")
        }
        let data = try await request("pico/lock-image", responseLimit: min(420000, status.imageLock!.maxBytes))
        try ReadPicoBitmap.validateLock(data, capability: status.imageLock!)
        return data
    }

    public func saveLockImageConfirmed(_ bmp: Data, onAccepted: (@Sendable () async -> Void)? = nil) async throws -> ReadPicoCapabilities {
        let previous = try await capabilities()
        guard previous.protocol == 1, let capability = previous.imageLock, capability.supported else {
            throw ReadPicoManagerError.unavailable("当前固件尚不支持自定义图片锁屏，请先更新固件。")
        }
        try ReadPicoBitmap.validateLock(bmp, capability: capability)
        let data = try await request("pico/lock-image", method: "POST", data: bmp, contentType: "image/bmp")
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["ok"] as? Bool == true, reply["accepted"] as? Bool == true else {
            throw ReadPicoManagerError.invalid("设备未接收锁屏图片。")
        }
        await onAccepted?()
        for _ in 0..<48 {
            try await Task.sleep(nanoseconds: 250_000_000)
            let current: ReadPicoCapabilities
            do { current = try await capabilities() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                throw ReadPicoManagerError.unavailable("锁屏图片已提交，但连接中断，尚未确认保存。请重新连接后核对。")
            }
            guard current.protocol == 1, let image = current.imageLock, image.supported else {
                throw ReadPicoManagerError.unavailable("设备没有返回兼容的锁屏图片保存状态。")
            }
            if image.state == "error" { throw ReadPicoManagerError.unavailable("锁屏图片保存失败，请检查 TF 卡后重试。") }
            if image.available, image.state == "saved", image.revision != capability.revision {
                try ReadPicoBitmap.validateLock(bmp, capability: image)
                return current
            }
        }
        throw ReadPicoManagerError.unavailable("锁屏图片已提交，尚未确认保存；请保持连接并重新读取。")
    }
}

/// A single atomic delivery of native portrait and landscape canvases sampled at the same instant.
/// 双方向画面属于同一份内容快照；校验整套后一次提交，设备旋转时直接选用本地方向。
public enum ReadPicoCanvasPair {
    public static let maximumBytes = 840032
    public static func isPair(_ data: Data) -> Bool { data.prefix(8) == Data("PICOPAIR".utf8) }
    public static func encode(portrait: Data, landscape: Data) throws -> Data {
        var result = Data(repeating: 0, count: 32)
        result.replaceSubrange(0..<8, with: Data("PICOPAIR".utf8))
        func put(_ offset: Int, _ value: UInt32) {
            for index in 0..<4 { result[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        guard portrait.count <= 420000, landscape.count <= 420000 else { throw invalid() }
        put(8, 1); put(12, 32); put(16, UInt32(portrait.count)); put(20, readPicoCRC32(portrait))
        put(24, UInt32(landscape.count)); put(28, readPicoCRC32(landscape))
        result.append(portrait); result.append(landscape)
        try validate(result)
        return result
    }
    public static func validate(_ data: Data) throws {
        guard data.count >= 32, data.count <= maximumBytes, isPair(data) else { throw invalid() }
        // Data slices can retain a nonzero startIndex; parse bounded zero-based bytes.
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
        }
        let portraitCount = Int(u32(16)), landscapeCount = Int(u32(24))
        guard u32(8) == 1, u32(12) == 32, (118...420000).contains(portraitCount),
              (118...420000).contains(landscapeCount), data.count == 32 + portraitCount + landscapeCount else { throw invalid() }
        let portrait = Data(bytes[32..<(32 + portraitCount)])
        let landscape = Data(bytes[(32 + portraitCount)..<bytes.count])
        guard readPicoCRC32(portrait) == u32(20), readPicoCRC32(landscape) == u32(28) else { throw invalid() }
        let cap = try JSONDecoder().decode(ReadPicoCanvasCapability.self, from: Data("{\"supported\":true,\"width\":684,\"height\":1216,\"formats\":[\"image/bmp\"],\"max_bytes\":420000,\"bit_depths\":[1,4],\"gray_levels\":16}".utf8))
        try ReadPicoBitmap.validateCanvas(portrait, capability: cap)
        try ReadPicoBitmap.validateCanvas(landscape, capability: cap)
        func dimension(_ image: Data, _ offset: Int) -> Int32 {
            Int32(bitPattern: (0..<4).reduce(UInt32(0)) { $0 | UInt32(image[offset + $1]) << ($1 * 8) })
        }
        guard portrait[28] == 4, landscape[28] == 4,
              dimension(portrait, 18) == 684, abs(Int(dimension(portrait, 22))) == 1216,
              dimension(landscape, 18) == 1216, abs(Int(dimension(landscape, 22))) == 684 else { throw invalid() }
    }
    private static func invalid() -> ReadPicoManagerError { .invalid("双方向画板必须包含完整、校验一致的竖屏和横屏 16 灰阶画面。") }
}

public enum ReadPicoBitmap {
    /// 中文：新锁屏明确声明16灰时才接受4位；缺省能力继续使用原有黑白契约。
    /// English: Accept 4-bit locks only with explicit gray16 capability; absent fields retain the legacy binary contract.
    public static func validateLock(_ data: Data, capability: ReadPicoImageLockCapability) throws {
        guard data.count >= 62 else { throw ReadPicoManagerError.invalid("锁屏图片的文件头不完整。") }
        if picoU16(data, 28) == 4 {
            guard capability.supportsNativeGray16 else {
                throw ReadPicoManagerError.unavailable("当前固件尚不支持 16 灰阶图片锁屏，请选择黑白或更新固件。")
            }
            let canvas = ReadPicoCanvasCapability(supported: capability.supported, width: 684, height: 1216,
                formats: capability.formats, maxBytes: capability.maxBytes, state: capability.state,
                revision: capability.revision, grayLevels: capability.grayLevels, bitDepths: capability.bitDepths, displayIntent: nil, dualOrientation: nil, pairMaxBytes: nil, modelProtocol: nil, modelMaxBytes: nil, orientation: nil, appChannels: nil, appReceipts: nil)
            do { try validateCanvas(data, capability: canvas) }
            catch { throw ReadPicoManagerError.invalid("锁屏图片的 16 灰阶 BMP 数据或色板无效。") }
            return
        }
        guard capability.supported, capability.formats.contains("image/bmp"),
              data.count <= min(110000, capability.maxBytes), data.prefix(2) == Data("BM".utf8),
              Int(picoU32(data, 2)) == data.count, picoU32(data, 10) == 62, picoU32(data, 14) == 40,
              picoU16(data, 26) == 1, picoU16(data, 28) == 1, picoU32(data, 30) == 0,
              (picoU32(data, 18) == 684 && picoU32(data, 22) == 1216) ||
              (picoU32(data, 18) == 1216 && picoU32(data, 22) == 684) else {
            throw ReadPicoManagerError.invalid("锁屏图片须为匹配设备尺寸的黑白或 16 灰阶 BMP。")
        }
        let stride = (Int(picoU32(data, 18)) + 31) / 32 * 4
        guard data.count == 62 + stride * Int(picoU32(data, 22)),
              Int(picoU32(data, 34)) == stride * Int(picoU32(data, 22)), picoU32(data, 46) == 2,
              data[54..<58] == Data([0, 0, 0, 0]), data[58..<62] == Data([255, 255, 255, 0]) else {
            throw ReadPicoManagerError.invalid("锁屏图片的像素数据或黑白色板不完整。")
        }
    }

    /// 中文：保留面板的16个灰阶，每个像素4位；每行含BMP要求的4字节对齐。
    /// English: Preserve all sixteen panel levels, using 4-bit pixels and DWORD-aligned BMP rows.
    public static func makeGray16(image: CGImage, width: Int, height: Int) throws -> Data {
        guard (width == 684 && height == 1216) || (width == 1216 && height == 684),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ReadPicoManagerError.invalid("灵犀画板必须匹配 684 × 1216 或 1216 × 684 的设备屏幕。")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw ReadPicoManagerError.unavailable("16 灰阶画板转换未完成。")
        }
        let stride = (width * 4 + 31) / 32 * 4, offset = 118, size = offset + stride * height
        var bmp = Data(repeating: 0, count: size)
        func set(_ at: Int, _ value: UInt32) {
            for i in 0..<4 { bmp[at + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        bmp[0] = 66; bmp[1] = 77; set(2, UInt32(size)); set(10, UInt32(offset)); set(14, 40)
        set(18, UInt32(width)); set(22, UInt32(height)); bmp[26] = 1; bmp[28] = 4
        set(34, UInt32(stride * height)); set(46, 16)
        for level in 0..<16 {
            for component in 0..<3 { bmp[54 + level * 4 + component] = UInt8(level * 17) }
        }
        for y in 0..<height {
            let row = offset + (height - 1 - y) * stride
            for x in 0..<width {
                let level = UInt8(min(15, (Int(pixels[y * width + x]) + 8) / 17))
                if x.isMultiple(of: 2) { bmp[row + x / 2] = level << 4 }
                else { bmp[row + x / 2] |= level }
            }
        }
        return bmp
    }

    /// 中文：发送前完整校验；旧固件必须显式声明16灰支持，禁止悄悄转为黑白。
    /// English: Validate complete pixel data before upload; never silently degrade gray16 on older firmware.
    public static func validateCanvas(_ data: Data, capability: ReadPicoCanvasCapability) throws {
        guard capability.supported, capability.formats.contains("image/bmp"),
              data.count >= 62, data.count <= min(420000, capability.maxBytes) else {
            throw ReadPicoManagerError.invalid("设备未开放画板推送，或图片超过设备可接收的大小。")
        }
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> UInt32 { UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { u16(at) | u16(at + 2) << 16 }
        let depth = u16(28)
        if depth == 4 && !capability.supportsNativeGray16 {
            throw ReadPicoManagerError.unavailable("当前固件尚不支持原生 16 灰阶灵犀画板，请先更新固件。")
        }
        let signedHeight = Int32(bitPattern: u32(22))
        guard bytes[0] == 66, bytes[1] == 77, Int(u32(2)) == bytes.count, u32(14) == 40,
              u16(26) == 1, depth == 1 || depth == 4, u32(30) == 0, signedHeight != Int32.min else {
            throw ReadPicoManagerError.invalid("画板图片必须为完整的无压缩黑白或 16 灰阶 BMP。")
        }
        let width = Int(u32(18)), height = abs(Int(signedHeight)), offset = Int(u32(10))
        guard (width == 684 && height == 1216) || (width == 1216 && height == 684) else {
            throw ReadPicoManagerError.invalid("画板图片尺寸与阅读器屏幕不符。")
        }
        let colors = depth == 4 ? 16 : 2, header = 54 + colors * 4
        let stride = (width * Int(depth) + 31) / 32 * 4
        guard offset >= header, offset <= bytes.count, bytes.count - offset == stride * height,
              u32(34) == 0 || u32(34) == UInt32(stride * height),
              u32(46) == 0 || u32(46) == UInt32(colors) else {
            throw ReadPicoManagerError.invalid("画板图片的像素数据或色板不完整。")
        }
        if depth == 4 {
            guard offset == 118, u16(6) == 0, u16(8) == 0, u32(50) == 0 || u32(50) == 16 else {
                throw ReadPicoManagerError.invalid("16 灰阶画板的文件头不兼容。")
            }
            var levels = Set<UInt8>()
            for index in 0..<16 {
                let at = 54 + index * 4, value = bytes[at]
                guard value == bytes[at + 1], value == bytes[at + 2], value % 17 == 0, bytes[at + 3] == 0 else {
                    throw ReadPicoManagerError.invalid("画板图片必须包含完整的 16 级灰度色板。")
                }
                levels.insert(value)
            }
            guard levels.count == 16 else { throw ReadPicoManagerError.invalid("画板图片的灰度色板存在重复。") }
        } else {
            guard data.count <= 110000 else { throw ReadPicoManagerError.invalid("黑白画板图片大小无效。") }
            func luminance(_ at: Int) -> Int { Int(bytes[at]) * 11 + Int(bytes[at + 1]) * 59 + Int(bytes[at + 2]) * 30 }
            guard (luminance(54) < 12800) != (luminance(58) < 12800) else {
                throw ReadPicoManagerError.invalid("黑白画板色板必须包含明暗两种颜色。")
            }
        }
    }

    /// Uncompressed, bottom-up 1-bit Windows BMP; palette index zero is black, one is white.
    public static func make(image: CGImage, width: Int, height: Int, dither: Bool = true) throws -> Data {
        guard (width == 684 && height == 1216) || (width == 1216 && height == 684),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ReadPicoManagerError.invalid("画布必须匹配 684 × 1216 或 1216 × 684 的设备屏幕。") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height)), w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        context.interpolationQuality = .high; context.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ReadPicoManagerError.unavailable("图片转换未完成。") }
        let stride = (width + 31) / 32 * 4, size = 62 + stride * height
        var bmp = Data(repeating: 0, count: size)
        func set(_ offset: Int, _ value: UInt32) { for i in 0..<4 { bmp[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) } }
        bmp[0] = 66; bmp[1] = 77; set(2, UInt32(size)); set(10, 62); set(14, 40); set(18, UInt32(width)); set(22, UInt32(height)); bmp[26] = 1; bmp[28] = 1; set(34, UInt32(stride * height)); set(46, 2)
        bmp[58] = 255; bmp[59] = 255; bmp[60] = 255
        let matrix = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        for y in 0..<height { for x in 0..<width {
            let threshold = dither ? matrix[(y % 4) * 4 + x % 4] * 16 + 8 : 128
            if Int(pixels[y * width + x]) >= threshold { bmp[62 + (height - 1 - y) * stride + x / 8] |= UInt8(0x80 >> (x % 8)) }
        } }
        return bmp
    }
}
