import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ESP8266 AI Mac 240×240 小屏幕可显示的正式内容模式。
public enum AIMacScreenContentMode: String, CaseIterable, Codable, Identifiable {
    case canvas
    case dashboard
    case clock
    case customImage

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .canvas: return "AI Mac 画板"
        case .dashboard: return "系统仪表盘"
        case .clock: return "桌面时钟"
        case .customImage: return "自定义图片"
        }
    }
}

/// AI Mac 彩色小屏的一块画板。沿用口袋先知的模块组合、命名、侧栏和轮播逻辑，
/// 但不保存墨水屏专属的灰阶、抖动和插值参数。
public struct AIMacCanvasBoard: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var sidebarVisible: Bool?
    public var rotationEnabled: Bool?
    public var modules: [Int]
    public var backgroundMode: CanvasBackgroundMode
    public var sspaiCount: Int
    public var sspaiRandom: Bool
    public var nowPlayingCover: Bool?
    public var nowPlayingHorizontal: Bool
    /// 彩色画板包含“正在播放”模块时，是否用专辑封面生成整板背景、文字与强调色。
    /// 可选字段保证旧版画板无损迁移；旧记录默认启用彩色取色效果。
    public var nowPlayingSmartBackground: Bool?
    public var printerFields: [Int: CanvasPrinterFields]
    public var haEntityIDs: [String]
    public var imagePath: String?
    public var imageName: String?

    public init(id: UUID = UUID(), name: String = CanvasBoardNamingPolicy.untitledName,
                sidebarVisible: Bool? = true, rotationEnabled: Bool? = true,
                modules: [Int] = [], backgroundMode: CanvasBackgroundMode = .dark,
                sspaiCount: Int = 3, sspaiRandom: Bool = false,
                nowPlayingCover: Bool? = true,
                nowPlayingHorizontal: Bool = false,
                nowPlayingSmartBackground: Bool? = true,
                printerFields: [Int: CanvasPrinterFields] = [:],
                haEntityIDs: [String] = [], imagePath: String? = nil,
                imageName: String? = nil) {
        self.id = id
        self.name = name
        self.sidebarVisible = sidebarVisible
        self.rotationEnabled = rotationEnabled
        self.modules = modules
        self.backgroundMode = backgroundMode
        self.sspaiCount = min(max(sspaiCount, 1), 6)
        self.sspaiRandom = sspaiRandom
        self.nowPlayingCover = nowPlayingCover
        self.nowPlayingHorizontal = nowPlayingHorizontal
        self.nowPlayingSmartBackground = nowPlayingSmartBackground
        self.printerFields = printerFields
        self.haEntityIDs = haEntityIDs
        self.imagePath = imagePath
        self.imageName = imageName
    }

    public var isSidebarVisible: Bool { sidebarVisible ?? true }
    public var participatesInRotation: Bool { rotationEnabled ?? true }
    public var usesNowPlayingCover: Bool { nowPlayingCover ?? true }
    public var usesNowPlayingSmartBackground: Bool { nowPlayingSmartBackground ?? true }
    public var moduleList: [CanvasModule] { modules.compactMap(CanvasModule.init(rawValue:)) }

    public mutating func clamp() {
        var seen = Set<Int>()
        modules = modules.filter { CanvasModule(rawValue: $0) != nil && seen.insert($0).inserted }
        sspaiCount = min(max(sspaiCount, 1), 6)
        var entitySeen = Set<String>()
        haEntityIDs = haEntityIDs.filter { !$0.isEmpty && entitySeen.insert($0).inserted }
    }
}

/// 每台 AI Mac 小屏幕独立保存的连接与显示设置。
public struct AIMacScreenDeviceSettings: Codable, Equatable {
    public var host: String
    public var mode: AIMacScreenContentMode
    public var autoPush: Bool
    public var pushIntervalSeconds: Int
    public var jpegQuality: Int
    public var customImagePath: String?
    public var canvasBoards: [AIMacCanvasBoard]
    public var canvasBoardIndex: Int
    public var boardRotationEnabled: Bool
    public var boardRotationMinutes: Int

    public init(host: String = "", mode: AIMacScreenContentMode = .canvas,
                autoPush: Bool = true, pushIntervalSeconds: Int = 2,
                jpegQuality: Int = 82, customImagePath: String? = nil,
                canvasBoards: [AIMacCanvasBoard] = [], canvasBoardIndex: Int = 0,
                boardRotationEnabled: Bool = false, boardRotationMinutes: Int = 5) {
        self.host = host
        self.mode = mode
        self.autoPush = autoPush
        self.pushIntervalSeconds = min(max(pushIntervalSeconds, 1), 60)
        self.jpegQuality = min(max(jpegQuality, 50), 90)
        self.customImagePath = customImagePath
        self.canvasBoards = canvasBoards
        self.canvasBoardIndex = canvasBoardIndex
        self.boardRotationEnabled = boardRotationEnabled
        self.boardRotationMinutes = boardRotationMinutes
        clamp()
    }

    public mutating func clamp() {
        pushIntervalSeconds = min(max(pushIntervalSeconds, 1), 60)
        jpegQuality = min(max(jpegQuality, 50), 90)
        canvasBoards = canvasBoards.map { board in
            var clean = board
            clean.clamp()
            return clean
        }
        canvasBoardIndex = canvasBoards.isEmpty
            ? 0 : min(max(canvasBoardIndex, 0), canvasBoards.count - 1)
        boardRotationMinutes = min(max(boardRotationMinutes, 1), 1_440)
    }

    private enum CodingKeys: String, CodingKey {
        case host, mode, autoPush, pushIntervalSeconds, jpegQuality, customImagePath
        case canvasBoards, canvasBoardIndex, boardRotationEnabled, boardRotationMinutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        mode = try container.decodeIfPresent(AIMacScreenContentMode.self, forKey: .mode) ?? .dashboard
        autoPush = try container.decodeIfPresent(Bool.self, forKey: .autoPush) ?? true
        pushIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pushIntervalSeconds) ?? 2
        jpegQuality = try container.decodeIfPresent(Int.self, forKey: .jpegQuality) ?? 82
        customImagePath = try container.decodeIfPresent(String.self, forKey: .customImagePath)
        canvasBoards = try container.decodeIfPresent([AIMacCanvasBoard].self,
                                                     forKey: .canvasBoards) ?? []
        canvasBoardIndex = try container.decodeIfPresent(Int.self, forKey: .canvasBoardIndex) ?? 0
        boardRotationEnabled = try container.decodeIfPresent(Bool.self,
                                                             forKey: .boardRotationEnabled) ?? false
        boardRotationMinutes = try container.decodeIfPresent(Int.self,
                                                             forKey: .boardRotationMinutes) ?? 5
        clamp()
    }
}

public struct AIMacScreenCapabilities: Equatable {
    public let host: String
    public let jpegUploadURL: URL
    public let rgb565UploadURL: URL?

    public init(host: String, jpegUploadURL: URL, rgb565UploadURL: URL?) {
        self.host = host
        self.jpegUploadURL = jpegUploadURL
        self.rgb565UploadURL = rgb565UploadURL
    }

    public var supportsLosslessRGB565: Bool { rgb565UploadURL != nil }
}

public enum AIMacScreenSupportError: Error, LocalizedError {
    case invalidHost
    case invalidDevice
    case imageTooLarge(Int)
    case encodeFailed
    case noCustomImage

    public var errorDescription: String? {
        switch self {
        case .invalidHost: return "请先填写小屏幕的 IP 地址。"
        case .invalidDevice: return "已连接，但目标不是兼容的 AI Mac 240×240 固件。"
        case .imageTooLarge(let size): return "图片压缩后仍有 \(size) 字节，超过旧固件 24KB 上限。"
        case .encodeFailed: return "无法生成 240×240 画面。"
        case .noCustomImage: return "请先选择一张图片。"
        }
    }
}

/// 正式主应用与独立实验版共用的 240×240 渲染、能力解析与帧编码实现。
public enum AIMacScreenSupport {
    public static let frameSize = 240
    public static let maximumJPEGBytes = 24 * 1024

    public static func normalizedHost(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("http://") { value.removeFirst("http://".count) }
        if value.hasPrefix("https://") { value.removeFirst("https://".count) }
        return value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
    }

    public static func infoURL(host input: String) -> URL? {
        let host = normalizedHost(input)
        guard !host.isEmpty else { return nil }
        return URL(string: "http://\(host)/api/info")
    }

    /// 旧固件没有 /api/info 时仍可使用既有 JPEG 上传端点。
    public static func jpegOnlyCapabilities(host input: String) throws -> AIMacScreenCapabilities {
        let host = normalizedHost(input)
        guard !host.isEmpty,
              let jpegURL = URL(string: "http://\(host)/image/upload") else {
            throw AIMacScreenSupportError.invalidHost
        }
        return AIMacScreenCapabilities(host: host, jpegUploadURL: jpegURL, rgb565UploadURL: nil)
    }

    public static func parseCapabilities(data: Data, host input: String) throws
        -> AIMacScreenCapabilities {
        let host = normalizedHost(input)
        guard !host.isEmpty,
              let jpegURL = URL(string: "http://\(host)/image/upload"),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["device"] as? String == "esp8266-ai-screen",
              let screen = json["screen"] as? [String: Any],
              screen["width"] as? Int == frameSize,
              screen["height"] as? Int == frameSize else {
            throw AIMacScreenSupportError.invalidDevice
        }
        var rgb565URL: URL?
        if let raw = json["rgb565_api"] as? [String: Any],
           raw["content_type"] as? String == "application/x-rgb565",
           raw["byte_order"] as? String == "big-endian",
           raw["bytes"] as? Int == frameSize * frameSize * 2,
           let path = raw["path"] as? String, path.hasPrefix("/") {
            rgb565URL = URL(string: "http://\(host)\(path)")
        }
        return AIMacScreenCapabilities(host: host, jpegUploadURL: jpegURL,
                                       rgb565UploadURL: rgb565URL)
    }

    public static func render(settings: AIMacScreenDeviceSettings,
                              system: SystemSnapshot, now: Date = Date()) throws -> CGImage {
        let size = frameSize
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)
                                        ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AIMacScreenSupportError.encodeFailed
        }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        switch settings.mode {
        case .canvas:
            // 完整画板由 AppModel 注入 HA、打印机、媒体等实时数据；核心层单独调用时
            // 返回有效的空白彩色帧，保证新设备尚未添加模块也能正常预览和推送。
            fillBackground(context)
        case .dashboard:
            drawDashboard(in: context, system: system, now: now)
        case .clock:
            drawClock(in: context, now: now)
        case .customImage:
            try drawCustomImage(in: context, path: settings.customImagePath)
        }
        guard let image = context.makeImage() else { throw AIMacScreenSupportError.encodeFailed }
        return image
    }

    public static func encodeRGB565(_ image: CGImage) throws -> Data {
        guard image.width == frameSize, image.height == frameSize,
              let context = CGContext(
                data: nil, width: frameSize, height: frameSize,
                bitsPerComponent: 8, bytesPerRow: frameSize * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)
                    ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue),
              let source = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw AIMacScreenSupportError.encodeFailed
        }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: frameSize, height: frameSize))
        var output = Data(count: frameSize * frameSize * 2)
        output.withUnsafeMutableBytes { storage in
            let destination = storage.bindMemory(to: UInt8.self)
            for pixel in 0..<(frameSize * frameSize) {
                let offset = pixel * 4
                let red = UInt16(source[offset])
                let green = UInt16(source[offset + 1])
                let blue = UInt16(source[offset + 2])
                let rgb565 = ((red & 0xF8) << 8) | ((green & 0xFC) << 3) | (blue >> 3)
                destination[pixel * 2] = UInt8(rgb565 >> 8)
                destination[pixel * 2 + 1] = UInt8(rgb565 & 0xFF)
            }
        }
        return output
    }

    public static func encodeJPEG(_ image: CGImage, preferredQuality: Int) throws -> Data {
        var lastSize = 0
        let preferred = min(max(preferredQuality, 50), 90)
        for quality in stride(from: preferred, through: 45, by: -5) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw AIMacScreenSupportError.encodeFailed
            }
            CGImageDestinationAddImage(destination, image,
                [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw AIMacScreenSupportError.encodeFailed
            }
            lastSize = data.length
            if data.length <= maximumJPEGBytes { return data as Data }
        }
        throw AIMacScreenSupportError.imageTooLarge(lastSize)
    }

    private static func fillBackground(_ context: CGContext) {
        context.setFillColor(CGColor(red: 0.025, green: 0.04, blue: 0.075, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
    }

    private static func drawDashboard(in context: CGContext, system: SystemSnapshot, now: Date) {
        fillBackground(context)
        drawText("LINGXI", size: 13, weight: .bold,
                 color: NSColor(calibratedRed: 0.33, green: 0.90, blue: 0.72, alpha: 1),
                 rect: CGRect(x: 14, y: 210, width: 100, height: 18), context: context)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        drawText(formatter.string(from: now), size: 31, weight: .bold,
                 color: .white, rect: CGRect(x: 14, y: 164, width: 212, height: 42), context: context)
        formatter.dateFormat = "M月d日 EEE"
        drawText(formatter.string(from: now), size: 12, weight: .regular,
                 color: NSColor(white: 0.70, alpha: 1),
                 rect: CGRect(x: 15, y: 145, width: 210, height: 18), context: context)
        drawMetric("CPU", value: system.cpuPercent, y: 103, context: context)
        drawMetric("MEM", value: system.memoryPercent, y: 66, context: context)
        drawText("↓ \(ScreenRenderer.formatRate(system.downloadBytesPerSecond))", size: 12,
                 weight: .medium,
                 color: NSColor(calibratedRed: 0.33, green: 0.90, blue: 0.72, alpha: 1),
                 rect: CGRect(x: 14, y: 20, width: 105, height: 22), context: context)
        drawText("↑ \(ScreenRenderer.formatRate(system.uploadBytesPerSecond))", size: 12,
                 weight: .medium,
                 color: NSColor(calibratedRed: 0.38, green: 0.65, blue: 0.98, alpha: 1),
                 rect: CGRect(x: 121, y: 20, width: 105, height: 22), context: context)
    }

    private static func drawClock(in context: CGContext, now: Date) {
        fillBackground(context)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        drawText(formatter.string(from: now), size: 58, weight: .bold, color: .white,
                 rect: CGRect(x: 8, y: 105, width: 224, height: 72), context: context,
                 alignment: .center)
        formatter.dateFormat = "ss"
        drawText(formatter.string(from: now), size: 22, weight: .bold,
                 color: NSColor(calibratedRed: 0.33, green: 0.90, blue: 0.72, alpha: 1),
                 rect: CGRect(x: 8, y: 82, width: 224, height: 26), context: context,
                 alignment: .center)
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        drawText(formatter.string(from: now), size: 14, weight: .medium,
                 color: NSColor(white: 0.72, alpha: 1),
                 rect: CGRect(x: 8, y: 55, width: 224, height: 22), context: context,
                 alignment: .center)
    }

    private static func drawCustomImage(in context: CGContext, path: String?) throws {
        guard let path,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AIMacScreenSupportError.noCustomImage
        }
        let side = min(image.width, image.height)
        let crop = CGRect(x: CGFloat(image.width - side) / 2,
                          y: CGFloat(image.height - side) / 2,
                          width: CGFloat(side), height: CGFloat(side))
        guard let square = image.cropping(to: crop) else {
            throw AIMacScreenSupportError.noCustomImage
        }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: 240, height: 240))
    }

    private static func drawMetric(_ name: String, value: Double, y: CGFloat,
                                   context: CGContext) {
        let value = min(max(value, 0), 100)
        drawText(name, size: 11, weight: .bold, color: NSColor(white: 0.75, alpha: 1),
                 rect: CGRect(x: 14, y: y + 9, width: 38, height: 18), context: context)
        drawText("\(Int(value.rounded()))%", size: 13, weight: .bold, color: .white,
                 rect: CGRect(x: 170, y: y + 8, width: 56, height: 18), context: context,
                 alignment: .right)
        let bar = CGRect(x: 54, y: y + 12, width: 108, height: 9)
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 4.5, cornerHeight: 4.5,
                               transform: nil))
        context.fillPath()
        let fill = CGRect(x: bar.minX, y: bar.minY,
                          width: max(9, bar.width * value / 100), height: bar.height)
        context.setFillColor(CGColor(red: 0.33, green: 0.90, blue: 0.72, alpha: 1))
        context.addPath(CGPath(roundedRect: fill, cornerWidth: 4.5, cornerHeight: 4.5,
                               transform: nil))
        context.fillPath()
    }

    private static func drawText(_ text: String, size: CGFloat, weight: NSFont.Weight,
                                 color: NSColor, rect: CGRect, context: CGContext,
                                 alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSString(string: text).draw(in: rect, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}
