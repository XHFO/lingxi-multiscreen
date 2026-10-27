import AppKit
import Combine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Native design-preview assets live separately from the application's device libraries.
struct PicoNativeAsset: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let width: Int
    let height: Int
    let originalFilename: String
    let thumbnailFilename: String
    let sha256: String
    let importedAt: Date
    let isSample: Bool
}

struct PicoNativeImageUse: Codable {
    let assetID: UUID
    let target: PicoPreviewTarget
    let edit: PicoPhotoEdit
}

@MainActor
final class PicoNativeLibrary: ObservableObject {
    /// One app-wide library; preview fixtures never seed this production directory.
    static let shared = production()

    @Published var assets: [PicoNativeAsset] = []
    @Published var error: String?
    @Published private(set) var isImporting = false
    @Published private(set) var isWritable = true

    let rootURL: URL
    private var uses: [String: PicoNativeImageUse] = [:]
    private let imageCache = NSCache<NSString, NSImage>()
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var pendingImages: [PicoNativeAsset] = []
    private var requestedImages: Set<UUID> = []
    private var failedImages: Set<UUID> = []
    private var loadingImage = false
    private static let legacyKeys: Set<String> = ["board", "lock", "oracle", "excerpt"]
    private static let maximumAssets = 10000

    private struct Index: Codable {
        let version: Int
        var assets: [PicoNativeAsset]
        var uses: [String: PicoNativeImageUse]
    }

    private struct PreparedAsset {
        let asset: PicoNativeAsset
        let directory: URL
    }

    private struct LibraryError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// Retains the independent preview's three fixtures and its existing on-disk format.
    convenience init(rootURL: URL? = nil) {
        self.init(resolvedRoot: rootURL ?? Self.applicationSupport.appendingPathComponent("LingxiPicoNativePreview", isDirectory: true), seedFixtures: true, migrationSource: nil)
    }

    /// Alternate URLs allow migration and persistence checks without touching a user's libraries.
    static func production(rootURL: URL? = nil, previewRootURL: URL? = nil) -> PicoNativeLibrary {
        PicoNativeLibrary(resolvedRoot: rootURL ?? applicationSupport.appendingPathComponent("LingxiWallpaperLibrary", isDirectory: true),
                          seedFixtures: false,
                          migrationSource: previewRootURL ?? applicationSupport.appendingPathComponent("LingxiPicoNativePreview", isDirectory: true))
    }

    private init(resolvedRoot: URL, seedFixtures: Bool, migrationSource: URL?) {
        self.rootURL = resolvedRoot.standardizedFileURL
        imageCache.totalCostLimit = 128 * 1024 * 1024
        thumbnailCache.totalCostLimit = 24 * 1024 * 1024
        do {
            let rootExisted = FileManager.default.fileExists(atPath: self.rootURL.path)
            if !rootExisted, let migrationSource {
                try migratePreviewIfPresent(from: migrationSource.standardizedFileURL)
            } else if !seedFixtures, rootExisted,
                      !FileManager.default.fileExists(atPath: self.rootURL.appendingPathComponent("library.json").path),
                      !(try FileManager.default.contentsOfDirectory(atPath: self.rootURL.path)).isEmpty {
                throw LibraryError(message: "壁纸目录已有资料但缺少索引，已暂停写入以保留原文件。")
            }
            try prepareDirectories()
            let indexURL = self.rootURL.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let index = try Self.readIndex(at: indexURL)
                assets = index.assets
                uses = index.uses
            } else if seedFixtures {
                try seedSamples()
            } else {
                try persist(assets: [], uses: [:])
            }
        } catch {
            isWritable = false
            self.error = "无法打开图片资料库：\(error.localizedDescription)"
        }
    }

    /// Decodes an editing preview from the owned original in the background, never from its thumbnail.
    /// The 4096-pixel preview budget does not alter or replace the original file.
    func image(for asset: PicoNativeAsset) -> NSImage? {
        let key = asset.id.uuidString as NSString
        if let image = imageCache.object(forKey: key) { return image }
        guard Self.valid(asset), !failedImages.contains(asset.id) else { return nil }
        if requestedImages.insert(asset.id).inserted {
            pendingImages.append(asset)
            loadNextImage()
        }
        return nil
    }

    func imageLoadFailed(for asset: PicoNativeAsset) -> Bool { failedImages.contains(asset.id) }

    func thumbnail(for asset: PicoNativeAsset) -> NSImage {
        let key = asset.id.uuidString as NSString
        if let image = thumbnailCache.object(forKey: key) { return image }
        if Self.valid(asset), let pixels = Self.previewPixels(objectURL(asset).appendingPathComponent(asset.thumbnailFilename), maximum: 640) {
            let image = NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
            thumbnailCache.setObject(image, forKey: key, cost: pixels.bytesPerRow * pixels.height)
            return image
        }
        return Self.placeholder()
    }

    func use(for key: String) -> PicoNativeImageUse? { Self.canonicalKey(key).flatMap { uses[$0] } }

    /// A board and a lock screen can share a target size while retaining separate edit parameters.
    @discardableResult
    func saveUse(assetID: UUID, key: String, target: PicoPreviewTarget, edit: PicoPhotoEdit) -> Bool {
        guard requireWritable() else { return false }
        guard let key = Self.canonicalKey(key), assets.contains(where: { $0.id == assetID }) else {
            error = "请先选择资料库中的图片及有效的使用位置。"
            return false
        }
        var proposed = uses
        proposed[key] = PicoNativeImageUse(assetID: assetID, target: target, edit: edit)
        do {
            try persist(assets: assets, uses: proposed)
            uses = proposed
            objectWillChange.send()
            error = nil
            return true
        } catch {
            self.error = "图片编辑参数未保存：\(error.localizedDescription)"
            return false
        }
    }

    /// A synchronous two-file commit: do not expose the candidate use until settings confirm saving.
    /// No await is allowed in commit; a settings failure restores the exact original index bytes.
    /// 同步提交资料库用途与外部设置；设置失败恢复原索引，回滚失败明确报错并暂停写入。
    func commitUse(assetID: UUID, key: String, target: PicoPreviewTarget, edit: PicoPhotoEdit,
                   commit: () throws -> Void) throws {
        guard requireWritable() else { throw LibraryError(message: error ?? "资料库当前不可写。") }
        guard let key = Self.canonicalKey(key), assets.contains(where: { $0.id == assetID }) else {
            let message = "请先选择资料库中的图片及有效的使用位置。"
            error = message; throw LibraryError(message: message)
        }
        let indexURL = rootURL.appendingPathComponent("library.json")
        let previousIndex: Data
        var proposed = uses
        proposed[key] = PicoNativeImageUse(assetID: assetID, target: target, edit: edit)
        do {
            previousIndex = try Self.readIndexData(at: indexURL)
            try persist(assets: assets, uses: proposed)
        } catch {
            self.error = "图片编辑参数未保存：\(error.localizedDescription)"
            throw error
        }
        do { try commit() }
        catch let commitError {
            do { try previousIndex.write(to: indexURL, options: .atomic) }
            catch let rollbackError {
                isWritable = false
                let message = "设置未保存：\(commitError.localizedDescription)；资料库回滚失败：\(rollbackError.localizedDescription)。已暂停资料库写入，请保留现有资料并修复存储后重试。"
                error = message
                throw LibraryError(message: message)
            }
            error = "图片应用未完成，已恢复原资料库设置：\(commitError.localizedDescription)"
            throw commitError
        }
        uses = proposed
        objectWillChange.send()
        error = nil
    }

    func importImages() {
        guard requireWritable(), !isImporting else { return }
        guard assets.count < Self.maximumAssets else {
            error = "壁纸库最多可保存 \(Self.maximumAssets) 张图片。"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "导入图片到壁纸库"
        panel.prompt = "导入副本"
        panel.message = "原图副本保存在这台 Mac，可供各设备的画板和图片锁屏使用。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { [weak self] in await self?.importImages(from: urls) }
    }

    /// Shared file-import path for open-panel selection and future drop/paste handling.
    func importImages(from urls: [URL]) async {
        guard requireWritable(), !isImporting, !urls.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let stagingRoot = rootURL.appendingPathComponent("staging", isDirectory: true)
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try Self.prepareImport(url, stagingRoot: stagingRoot)
                }.value
                if assets.contains(where: { $0.sha256 == prepared.asset.sha256 }) {
                    try? FileManager.default.removeItem(at: prepared.directory)
                } else {
                    try commit(prepared)
                }
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func objectURL(_ asset: PicoNativeAsset) -> URL {
        rootURL.appendingPathComponent("objects", isDirectory: true).appendingPathComponent(asset.id.uuidString, isDirectory: true)
    }

    /// Legacy template keys coexist with device- and module-specific compositions.
    /// UUID case is normalized so reopening a device cannot create a second spelling of its use.
    private static func canonicalKey(_ key: String) -> String? {
        if legacyKeys.contains(key) { return key }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (parts.count == 3 || parts.count == 4), parts[0] == "device", parts[1].count == 36,
              let device = UUID(uuidString: parts[1]) else { return nil }
        if parts.count == 3, legacyKeys.contains(parts[2]) {
            return "device.\(device.uuidString).\(parts[2])"
        }
        if parts.count == 4, parts[2] == "module", parts[3].count == 36,
           let module = UUID(uuidString: parts[3]) {
            return "device.\(device.uuidString).module.\(module.uuidString)"
        }
        return nil
    }

    private static func readIndexData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes > 0, bytes <= 16 * 1024 * 1024 else {
            throw LibraryError(message: "资料库索引无法读取；原文件已保留。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 16 * 1024 * 1024 else { throw LibraryError(message: "资料库索引超过大小限制。") }
        return data
    }

    private static func readIndex(at url: URL) throws -> Index {
        let data = try readIndexData(at: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var index = try decoder.decode(Index.self, from: data)
        let identifiers = Set(index.assets.map(\.id))
        guard index.version == 1, index.assets.count <= maximumAssets,
              identifiers.count == index.assets.count, index.assets.allSatisfy(valid),
              index.uses.keys.allSatisfy({ canonicalKey($0) != nil }),
              index.uses.values.allSatisfy({ identifiers.contains($0.assetID) }) else {
            throw LibraryError(message: "资料库索引无效；没有重建或覆盖原资料。")
        }
        var canonicalUses: [String: PicoNativeImageUse] = [:]
        for (key, use) in index.uses {
            guard let canonical = canonicalKey(key), canonicalUses[canonical] == nil else {
                throw LibraryError(message: "资料库包含重复的设备用途，已保留原索引并暂停写入。")
            }
            canonicalUses[canonical] = use
        }
        index.uses = canonicalUses
        return index
    }

    private static func encoded(_ index: Index) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        guard data.count <= 16 * 1024 * 1024 else { throw LibraryError(message: "资料库索引超过大小限制。") }
        return data
    }

    /// Stage the entire first production library next to its final path, then rename once.
    /// No source file is moved, edited, or removed; an existing production index always wins.
    private func migratePreviewIfPresent(from sourceRoot: URL) throws {
        let manager = FileManager.default
        let sourceIndex = sourceRoot.appendingPathComponent("library.json")
        guard manager.fileExists(atPath: sourceIndex.path) else { return }
        for directory in [sourceRoot, sourceRoot.appendingPathComponent("objects")] {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw LibraryError(message: "旧预览资料库目录无效；原资料已保留。")
            }
        }
        let previous = try Self.readIndex(at: sourceIndex)
        let migratedAssets = previous.assets.filter { !$0.isSample }
        let migratedIDs = Set(migratedAssets.map(\.id))
        let migratedUses = previous.uses.filter { migratedIDs.contains($0.value.assetID) }
        let parent = rootURL.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stagedRoot = parent.appendingPathComponent(".\(rootURL.lastPathComponent)-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: stagedRoot) }
        let staging = stagedRoot.appendingPathComponent("staging", isDirectory: true)
        let objects = stagedRoot.appendingPathComponent("objects", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        try manager.createDirectory(at: objects, withIntermediateDirectories: false)
        for asset in migratedAssets {
            let oldObject = sourceRoot.appendingPathComponent("objects", isDirectory: true).appendingPathComponent(asset.id.uuidString, isDirectory: true)
            let values = try oldObject.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw LibraryError(message: "旧图片「\(asset.name)」的目录无法读取；迁移尚未写入。")
            }
            // The regular-file checks, hash and thumbnail are generated from our own byte copy.
            let prepared = try Self.prepareImport(oldObject.appendingPathComponent(asset.originalFilename), stagingRoot: staging)
            guard prepared.asset.sha256 == asset.sha256, prepared.asset.width == asset.width, prepared.asset.height == asset.height else {
                throw LibraryError(message: "旧图片「\(asset.name)」与索引不一致；迁移尚未写入。")
            }
            if prepared.asset.originalFilename != asset.originalFilename {
                try manager.moveItem(at: prepared.directory.appendingPathComponent(prepared.asset.originalFilename),
                                     to: prepared.directory.appendingPathComponent(asset.originalFilename))
            }
            try manager.moveItem(at: prepared.directory, to: objects.appendingPathComponent(asset.id.uuidString, isDirectory: true))
        }
        try Self.encoded(Index(version: 1, assets: migratedAssets, uses: migratedUses))
            .write(to: stagedRoot.appendingPathComponent("library.json"), options: .atomic)
        do {
            try manager.moveItem(at: stagedRoot, to: rootURL)
        } catch {
            // Another app may have completed first. Never replace it with our staged copy.
            guard manager.fileExists(atPath: rootURL.path) else { throw error }
            _ = try Self.readIndex(at: rootURL.appendingPathComponent("library.json"))
        }
    }

    private func requireWritable() -> Bool {
        guard isWritable else {
            error = "资料库索引无法读取，已暂停写入以保留原资料。请先修复或另建预览资料库。"
            return false
        }
        return true
    }

    private func loadNextImage() {
        guard !loadingImage, !pendingImages.isEmpty else { return }
        let asset = pendingImages.removeFirst()
        let url = objectURL(asset).appendingPathComponent(asset.originalFilename)
        loadingImage = true
        Task { [weak self] in
            let pixels = await Task.detached(priority: .userInitiated) {
                Self.previewPixels(url, maximum: 4096)
            }.value
            guard let self else { return }
            if let pixels {
                let image = NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
                imageCache.setObject(image, forKey: asset.id.uuidString as NSString, cost: pixels.bytesPerRow * pixels.height)
            } else {
                if failedImages.insert(asset.id).inserted {
                    error = "无法读取图片「\(asset.name)」；请检查资料库中的原文件是否仍然可用。"
                }
            }
            requestedImages.remove(asset.id)
            loadingImage = false
            objectWillChange.send()
            loadNextImage()
        }
    }

    nonisolated private static func previewPixels(_ url: URL, maximum: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    private func prepareDirectories() throws {
        for directory in [rootURL, rootURL.appendingPathComponent("objects"), rootURL.appendingPathComponent("staging")] {
            if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw LibraryError(message: "预览资料库目录不能指向其他文件夹。")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func valid(_ asset: PicoNativeAsset) -> Bool {
        asset.width > 0 && asset.height > 0 && asset.width <= 32768 && asset.height <= 32768
            && Int64(asset.width) * Int64(asset.height) <= 100_000_000
            && asset.sha256.count == 64 && asset.sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && asset.originalFilename.hasPrefix("original.") && !asset.originalFilename.contains("/") && !asset.originalFilename.contains("\\")
            && asset.thumbnailFilename == "thumbnail.png"
    }

    private func persist(assets: [PicoNativeAsset], uses: [String: PicoNativeImageUse]) throws {
        guard isWritable, assets.count <= Self.maximumAssets, uses.keys.allSatisfy({ Self.canonicalKey($0) != nil }) else {
            throw LibraryError(message: "资料库当前不可写或已达到容量上限。")
        }
        let data = try Self.encoded(Index(version: 1, assets: assets, uses: uses))
        try data.write(to: rootURL.appendingPathComponent("library.json"), options: .atomic)
    }

    private func commit(_ prepared: PreparedAsset) throws {
        let destination = objectURL(prepared.asset)
        do {
            guard isWritable, assets.count < Self.maximumAssets else {
                throw LibraryError(message: "资料库当前不可写或已达到容量上限。")
            }
            try FileManager.default.moveItem(at: prepared.directory, to: destination)
            let proposed = assets + [prepared.asset]
            do {
                try persist(assets: proposed, uses: uses)
                assets = proposed
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: prepared.directory)
            throw error
        }
    }

    nonisolated private static func prepareImport(_ source: URL, stagingRoot: URL) throws -> PreparedAsset {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes > 0, bytes <= 256 * 1024 * 1024 else {
            throw LibraryError(message: "请选择不超过 256 MB 的普通图片文件。")
        }
        let id = UUID(), directory = stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        // Work on our copy so an original moved after import cannot invalidate the preview library.
        let suffix = source.pathExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let originalName = "original." + (suffix.isEmpty ? "image" : String(suffix.prefix(12)))
        let original = directory.appendingPathComponent(originalName)
        try FileManager.default.copyItem(at: source, to: original)
        guard let imageSource = CGImageSourceCreateWithURL(original as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(imageSource) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0, pixelWidth <= 32768, pixelHeight <= 32768,
              Int64(pixelWidth) * Int64(pixelHeight) <= 100_000_000 else {
            throw LibraryError(message: "图片无法解码、包含多帧，或超过 1 亿像素的预览限制。")
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let swapped = (5...8).contains(orientation)
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary), let png = NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:]) else {
            throw LibraryError(message: "无法生成图片缩略图，原文件没有更改。")
        }
        try png.write(to: directory.appendingPathComponent("thumbnail.png"), options: .atomic)
        let handle = try FileHandle(forReadingFrom: original)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let asset = PicoNativeAsset(id: id, name: source.lastPathComponent,
                                   width: swapped ? pixelHeight : pixelWidth, height: swapped ? pixelWidth : pixelHeight,
                                   originalFilename: originalName, thumbnailFilename: "thumbnail.png",
                                   sha256: digest, importedAt: Date(), isSample: false)
        complete = true
        return PreparedAsset(asset: asset, directory: directory)
    }

    private func seedSamples() throws {
        let names = ["山间晨雾 · 预置示例", "光与轨迹 · 预置示例", "安静的纸面 · 预置示例"]
        var staged: [PreparedAsset] = []
        var destinations: [URL] = []
        do {
            for index in 0..<3 {
                let image = Self.sample(index)
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw LibraryError(message: "无法生成预置图片。")
                }
                let id = UUID(), directory = rootURL.appendingPathComponent("staging").appendingPathComponent(id.uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let asset = PicoNativeAsset(id: id, name: names[index], width: 1600, height: 1200,
                                           originalFilename: "original.png", thumbnailFilename: "thumbnail.png",
                                           sha256: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(), importedAt: Date(), isSample: true)
                staged.append(PreparedAsset(asset: asset, directory: directory))
                try png.write(to: directory.appendingPathComponent("original.png"), options: .atomic)
                guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                      let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary),
                      let thumbnail = NSBitmapImageRep(cgImage: thumb).representation(using: .png, properties: [:]) else {
                    throw LibraryError(message: "无法生成预置缩略图。")
                }
                try thumbnail.write(to: directory.appendingPathComponent("thumbnail.png"), options: .atomic)
            }
            for item in staged {
                let destination = objectURL(item.asset)
                try FileManager.default.moveItem(at: item.directory, to: destination)
                destinations.append(destination)
            }
            let seeded = staged.map(\.asset)
            try persist(assets: seeded, uses: [:])
            assets = seeded
        } catch {
            for item in staged { try? FileManager.default.removeItem(at: item.directory) }
            for destination in destinations { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }

    private static func placeholder() -> NSImage {
        NSImage(systemSymbolName: "photo", accessibilityDescription: "图片暂不可用") ?? NSImage(size: NSSize(width: 1600, height: 1200))
    }

    private static func sample(_ index: Int) -> NSImage {
        let size = NSSize(width: 1600, height: 1200)
        return NSImage(size: size, flipped: false) { bounds in
            func fill(_ gray: CGFloat, _ rect: NSRect) { NSColor(white: gray, alpha: 1).setFill(); rect.fill() }
            fill(index == 1 ? 0.12 : 0.92, bounds)
            if index == 0 {
                NSColor(white: 1, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: 1160, y: 850, width: 220, height: 220)).fill()
                for (points, gray) in [
                    ([NSPoint(x: 0, y: 0), NSPoint(x: 0, y: 340), NSPoint(x: 370, y: 900), NSPoint(x: 760, y: 360), NSPoint(x: 1160, y: 810), NSPoint(x: 1600, y: 270), NSPoint(x: 1600, y: 0)], CGFloat(0.65)),
                    ([NSPoint(x: 0, y: 0), NSPoint(x: 0, y: 170), NSPoint(x: 480, y: 540), NSPoint(x: 930, y: 120), NSPoint(x: 1330, y: 550), NSPoint(x: 1600, y: 160), NSPoint(x: 1600, y: 0)], CGFloat(0.32))
                ] {
                    let path = NSBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }; path.close()
                    NSColor(white: gray, alpha: 1).setFill(); path.fill()
                }
            } else if index == 1 {
                for (radius, gray) in [(420, 0.3), (310, 0.5), (200, 0.7), (90, 0.92)] {
                    NSColor(white: gray, alpha: 1).setFill()
                    NSBezierPath(ovalIn: NSRect(x: 800 - radius, y: 600 - radius, width: radius * 2, height: radius * 2)).fill()
                }
                NSColor.white.setStroke()
                let line = NSBezierPath(); line.move(to: NSPoint(x: 0, y: 90)); line.line(to: NSPoint(x: 1600, y: 1050)); line.lineWidth = 15; line.stroke()
            } else {
                NSColor(white: 0.72, alpha: 1).setFill()
                let shape = NSBezierPath(); shape.move(to: NSPoint(x: 0, y: 0)); shape.line(to: NSPoint(x: 1170, y: 1200)); shape.line(to: NSPoint(x: 1600, y: 1200)); shape.line(to: NSPoint(x: 1600, y: 0)); shape.close(); shape.fill()
                fill(0.3, NSRect(x: 135, y: 1010, width: 560, height: 18)); fill(0.5, NSRect(x: 135, y: 970, width: 310, height: 10))
                NSColor(white: 0.3, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: 1060, y: 120, width: 340, height: 340)).fill()
            }
            return true
        }
    }
}
