import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ESP8266 AI Mac 240×240 小屏幕可显示的正式内容模式。
public enum AIMacScreenContentMode: String, CaseIterable, Codable, Identifiable {
    case dashboard
    case clock
    case customImage

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: return "系统仪表盘"
        case .clock: return "桌面时钟"
        case .customImage: return "自定义图片"
        }
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

    public init(host: String = "", mode: AIMacScreenContentMode = .dashboard,
                autoPush: Bool = true, pushIntervalSeconds: Int = 2,
                jpegQuality: Int = 82, customImagePath: String? = nil) {
        self.host = host
        self.mode = mode
        self.autoPush = autoPush
        self.pushIntervalSeconds = min(max(pushIntervalSeconds, 1), 60)
        self.jpegQuality = min(max(jpegQuality, 50), 90)
        self.customImagePath = customImagePath
    }

    public mutating func clamp() {
        pushIntervalSeconds = min(max(pushIntervalSeconds, 1), 60)
        jpegQuality = min(max(jpegQuality, 50), 90)
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
