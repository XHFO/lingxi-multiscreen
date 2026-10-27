import AppKit
import ImageIO

/// Portable per-instance source images remain RGB until the final device renderer quantizes them.
@MainActor
enum ReadPicoBoardPlaylistImage {
    private static let maximumDimension = 4096
    private static let maximumPixels = 16 * 1024 * 1024

    static func source(for item: ReadPicoBoardPlaylistItem,
                       library: PicoNativeLibrary? = nil) throws -> NSImage {
        if let data = item.imageSourcePNG {
            guard !data.isEmpty, data.count <= ReadPicoBoardPlaylist.maximumEmbeddedBytes,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
                  width <= maximumPixels / height,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw ReadPicoBoardPlaylistError.invalid("轮播图片原稿已损坏或超过像素限制，请重新选择图片。")
            }
            return NSImage(cgImage: image, size: NSSize(width: width, height: height))
        }
        guard let assetID = item.imageAssetID else {
            throw ReadPicoBoardPlaylistError.invalid("此轮播项尚未选择图片，请从壁纸库选择。")
        }
        let library = library ?? .shared
        guard let asset = library.assets.first(where: { $0.id == assetID }) else {
            throw ReadPicoBoardPlaylistError.invalid("此轮播项的图片原稿已缺失，请从壁纸库重新选择。")
        }
        if let image = library.image(for: asset) { return image }
        if library.imageLoadFailed(for: asset) {
            throw ReadPicoBoardPlaylistError.invalid("轮播图片原文件已缺失或损坏，请重新选择图片。")
        }
        throw ReadPicoBoardPlaylistError.imageLoading
    }

    static func edit(for item: ReadPicoBoardPlaylistItem, source: NSImage,
                     landscape: Bool) throws -> PicoPhotoEdit {
        let target: PicoPreviewTarget = landscape ? .picoLandscape : .pico
        guard let data = item.imageEditData else {
            return .centered(source: PicoPhotoRenderer.sourceSize(image: source), target: target)
        }
        guard data.count <= 16_384, let edit = try? JSONDecoder().decode(PicoPhotoEdit.self, from: data), edit.version == 1 else {
            throw ReadPicoBoardPlaylistError.invalid("此轮播项的构图参数无效，请重新调整图片。")
        }
        return edit.normalized()
    }

    static func composed(for item: ReadPicoBoardPlaylistItem, landscape: Bool) throws -> NSImage {
        let image = try source(for: item)
        let edit = try edit(for: item, source: image, landscape: landscape)
        return PicoPhotoRenderer.composeColor(image: image, edit: edit,
                                              target: landscape ? .picoLandscape : .pico)
    }

    /// The shared library keeps the full original. Drafts embed a bounded color source for portability.
    static func portableSource(_ image: NSImage) throws -> Data {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 0, source.height > 0 else {
            throw ReadPicoBoardPlaylistError.invalid("无法读取所选图片。")
        }
        let scale = min(1, 2048 / Double(max(source.width, source.height)))
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ReadPicoBoardPlaylistError.invalid("无法准备轮播图片，请重试。")
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]),
              data.count <= ReadPicoBoardPlaylist.maximumEmbeddedBytes else {
            throw ReadPicoBoardPlaylistError.invalid("轮播图片原稿过大，请选择较小的图片。")
        }
        return data
    }
}
