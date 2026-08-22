import CoreGraphics
import Foundation

/// 图片裁切坐标计算：把编辑区的拖动/缩放映射回源图像的像素裁切矩形。
public enum ImageCropper {

    /// 计算源图像中的裁切矩形（像素坐标，原点左上）。
    /// - imageSize: 源图像素尺寸
    /// - displaySize: 编辑区显示尺寸
    /// - imageOffset: 图片平移（显示坐标）
    /// - zoom: 缩放倍数（>= 1）
    /// - cropDisplaySize: 裁切框显示尺寸
    public static func cropRect(imageSize: CGSize,
                                displaySize: CGSize,
                                imageOffset: CGSize,
                                zoom: CGFloat,
                                cropDisplaySize: CGSize) -> CGRect? {
        let pw = imageSize.width
        let ph = imageSize.height
        guard pw > 0, ph > 0, zoom > 0 else { return nil }
        let baseScale = max(cropDisplaySize.width / pw, cropDisplaySize.height / ph)
        let scale = baseScale * zoom
        let centerX = pw / 2 - imageOffset.width / scale
        let centerY = ph / 2 - imageOffset.height / scale
        let wpx = cropDisplaySize.width / scale
        let hpx = cropDisplaySize.height / scale
        let rect = CGRect(x: centerX - wpx / 2, y: centerY - hpx / 2,
                          width: wpx, height: hpx)
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: pw, height: ph))
        guard clamped.width > 1, clamped.height > 1 else { return nil }
        return clamped
    }

    /// 限制平移，保证图片始终覆盖裁切框。
    public static func clampedOffset(_ proposed: CGSize,
                                     imageSize: CGSize,
                                     displaySize: CGSize,
                                     zoom: CGFloat,
                                     cropDisplaySize: CGSize) -> CGSize {
        let pw = imageSize.width
        let ph = imageSize.height
        let baseScale = max(cropDisplaySize.width / pw, cropDisplaySize.height / ph)
        let scale = baseScale * zoom
        let minX = cropDisplaySize.width / 2 - pw * scale / 2
        let maxX = pw * scale / 2 - cropDisplaySize.width / 2
        let minY = cropDisplaySize.height / 2 - ph * scale / 2
        let maxY = ph * scale / 2 - cropDisplaySize.height / 2
        return CGSize(width: min(max(proposed.width, minX), maxX),
                      height: min(max(proposed.height, minY), maxY))
    }
}
