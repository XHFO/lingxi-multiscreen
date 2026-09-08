import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// 单台摄像头在一次打印任务中的自动取景状态。裁切坐标使用 Vision 的标准化坐标系
/// （原点在左下，范围 0...1）；状态只保存在内存中，不写入用户配置。
public struct BambuCameraZoomState: Equatable, Sendable {
    public var crop: CGRect
    public var progress: Double?
    public var consecutiveMisses: Int

    public init(crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                progress: Double? = nil,
                consecutiveMisses: Int = 0) {
        self.crop = crop
        self.progress = progress
        self.consecutiveMisses = consecutiveMisses
    }
}

public struct BambuCameraZoomOutput: @unchecked Sendable {
    public var imageData: Data
    public var state: BambuCameraZoomState
    public var usedZoom: Bool
    public var confidence: Float
}

/// Bambu 摄像头静态帧自动取景：使用系统 Vision 在本机寻找中心附近的显著前景，
/// 再按打印进度和上一帧状态生成保守、平滑且只会逐步放宽的正方形取景框。
public enum BambuCameraAutoZoom {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let unitCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// 纯几何规划入口公开供回归测试使用。candidate 为 Vision 标准化矩形。
    public static func plannedState(candidate: CGRect?,
                                    confidence: Float,
                                    progress: Double?,
                                    previous: BambuCameraZoomState) -> BambuCameraZoomState {
        let currentProgress = progress.map { min(max($0, 0), 100) }
        let restarted: Bool
        if let old = previous.progress, let current = currentProgress {
            restarted = current + 12 < old
        } else {
            restarted = false
        }
        let base = restarted ? BambuCameraZoomState() : previous

        guard let rawCandidate = candidate, confidence >= 0.18 else {
            return missedState(progress: currentProgress, previous: base)
        }
        let candidate = rawCandidate.standardized.intersection(unitCrop)
        let area = candidate.width * candidate.height
        let center = CGPoint(x: candidate.midX, y: candidate.midY)
        // 只接受打印床中央大区域内、尺寸合理的前景；机箱边缘、时间戳和整张背景不参与聚焦。
        guard !candidate.isNull, area >= 0.0015, area <= 0.48,
              (0.12...0.88).contains(center.x), (0.08...0.92).contains(center.y) else {
            return missedState(progress: currentProgress, previous: base)
        }

        let progressFraction = (currentProgress ?? 0) / 100
        // 早期最多约 2.5× 放大；随着打印进度增加，强制逐步放宽到至少 92% 全画面。
        // 即使某一帧只识别到喷头或模型的一小部分，也不会一直保持早期的小裁切框。
        let progressFloor = cropFloor(for: progressFraction)
        // 给目标留约 45% 外围空间，同时避免早期小模型被大块空打印床稀释。
        let observedSide = max(candidate.width, candidate.height) * 1.45 + 0.06
        var side = min(max(max(observedSide, progressFloor), 0.40), 1)

        let previousWasFocused = base.crop.width < 0.985 && base.consecutiveMisses == 0
        if previousWasFocused, !restarted,
           currentProgress == nil || base.progress == nil || currentProgress! + 2 >= base.progress! {
            // 同一任务进度未回退时，取景框只可保持或扩大，不再重新缩小。
            side = max(side, base.crop.width)
        }

        let targetCenter: CGPoint
        if previousWasFocused, !restarted {
            // 中心缓动，避免低帧率画面中裁切框随喷头突然跳向另一侧。
            targetCenter = CGPoint(x: base.crop.midX * 0.72 + center.x * 0.28,
                                   y: base.crop.midY * 0.72 + center.y * 0.28)
        } else {
            targetCenter = center
        }
        let crop = squareCrop(center: targetCenter, side: side)
        return BambuCameraZoomState(crop: crop,
                                    progress: currentProgress ?? base.progress,
                                    consecutiveMisses: 0)
    }

    /// 分析并裁切一张当前静态帧。任何解码、识别或编码异常都返回原图，确保推送始终可用。
    public static func process(imageData: Data,
                               progress: Double?,
                               previous: BambuCameraZoomState) -> BambuCameraZoomOutput {
        guard let source = CIImage(data: imageData,
                                   options: [.applyOrientationProperty: true]),
              source.extent.width >= 32, source.extent.height >= 32 else {
            return fallback(imageData: imageData, progress: progress, previous: previous)
        }

        let detection = salientCandidate(in: source)
        let state = plannedState(candidate: detection?.rect,
                                 confidence: detection?.confidence ?? 0,
                                 progress: progress,
                                 previous: previous)
        guard state.crop.width < 0.985, state.crop.height < 0.985,
              let cropped = encodedCrop(source, normalized: state.crop) else {
            return BambuCameraZoomOutput(imageData: imageData, state: state,
                                         usedZoom: false,
                                         confidence: detection?.confidence ?? 0)
        }
        return BambuCameraZoomOutput(imageData: cropped, state: state,
                                     usedZoom: true,
                                     confidence: detection?.confidence ?? 0)
    }

    private static func salientCandidate(in image: CIImage) -> (rect: CGRect, confidence: Float)? {
        let maxDimension = max(image.extent.width, image.extent.height)
        let scale = min(1, 320 / max(maxDimension, 1))
        let analysisImage = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(ciImage: analysisImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let objects = request.results?.first?.salientObjects, !objects.isEmpty else {
            return nil
        }
        // 显著度相近时优先选择更接近打印床中心的目标，降低机箱标识和边缘反光误判。
        return objects.compactMap { object -> (CGRect, Float, Double)? in
            let rect = object.boundingBox.standardized.intersection(unitCrop)
            guard !rect.isNull else { return nil }
            let dx = Double(rect.midX - 0.5)
            let dy = Double(rect.midY - 0.48)
            let distance = min(sqrt(dx * dx + dy * dy), 0.75)
            let area = Double(rect.width * rect.height)
            guard area >= 0.0015, area <= 0.48 else { return nil }
            let score = Double(object.confidence) * (1.15 - distance) * (1 - min(area, 0.45) * 0.25)
            return (rect, object.confidence, score)
        }
        .max(by: { $0.2 < $1.2 })
        .map { (rect: $0.0, confidence: $0.1) }
    }

    private static func missedState(progress: Double?,
                                    previous: BambuCameraZoomState) -> BambuCameraZoomState {
        let misses = previous.consecutiveMisses + 1
        guard previous.crop.width < 0.985, misses < 2 else {
            return BambuCameraZoomState(crop: unitCrop,
                                        progress: progress ?? previous.progress,
                                        consecutiveMisses: misses)
        }
        // 单帧被喷头遮挡时先温和放宽；连续两帧失败才完全恢复原图。
        let progressFraction = (progress ?? previous.progress ?? 0) / 100
        let floor = cropFloor(for: progressFraction)
        let side = min(max(previous.crop.width * 1.18, floor), 1)
        return BambuCameraZoomState(crop: squareCrop(
            center: CGPoint(x: previous.crop.midX, y: previous.crop.midY), side: side),
                                    progress: progress ?? previous.progress,
                                    consecutiveMisses: misses)
    }

    private static func squareCrop(center: CGPoint, side: CGFloat) -> CGRect {
        let safeSide = min(max(side, 0.01), 1)
        let x = min(max(center.x - safeSide / 2, 0), 1 - safeSide)
        let y = min(max(center.y - safeSide / 2, 0), 1 - safeSide)
        return CGRect(x: x, y: y, width: safeSide, height: safeSide)
    }

    /// 早期积极聚焦，随后随打印进度平滑恢复更多画面：5% 约保留 43%，
    /// 50% 约保留 67%，80% 约保留 82%，完成时至少保留 92%。
    private static func cropFloor(for progressFraction: Double) -> CGFloat {
        let normalized = min(max(progressFraction, 0), 1)
        return 0.40 + 0.52 * pow(normalized, 0.95)
    }

    private static func encodedCrop(_ image: CIImage, normalized crop: CGRect) -> Data? {
        let extent = image.extent
        let pixelRect = CGRect(x: extent.minX + crop.minX * extent.width,
                               y: extent.minY + crop.minY * extent.height,
                               width: crop.width * extent.width,
                               height: crop.height * extent.height).integral
            .intersection(extent)
        guard pixelRect.width >= 32, pixelRect.height >= 32,
              let cgImage = context.createCGImage(image, from: pixelRect) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage,
                                   [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let result = data as Data
        guard !result.isEmpty,
              CGImageSourceCreateWithData(result as CFData, nil) != nil else { return nil }
        return result
    }

    private static func fallback(imageData: Data, progress: Double?,
                                 previous: BambuCameraZoomState) -> BambuCameraZoomOutput {
        let state = missedState(progress: progress, previous: previous)
        return BambuCameraZoomOutput(imageData: imageData, state: state,
                                     usedZoom: false, confidence: 0)
    }
}
