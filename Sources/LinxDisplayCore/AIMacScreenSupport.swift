import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ESP8266 AI Mac 240×240 小屏幕可显示的正式内容模式。
public enum AIMacScreenContentMode: String, CaseIterable, Codable, Identifiable {
    case canvas
    /// 由统一卡片能力目录驱动的功能卡片。
    case card
    case dashboard
    case clock
    case customImage

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .canvas: return "AI Mac 画板"
        case .card: return "功能卡片"
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
    /// Mac 锁屏或休眠时熄灭背光，解锁/唤醒后恢复原亮度与画面。
    public var followSystemSleep: Bool
    /// 最近一次熄屏前的亮度，用于应用意外退出后仍能在下次启动恢复。
    public var awakeBrightness: Int?
    /// 可选的灵犀 68 歌词联动目标；nil 表示保持各设备原有显示，互不关联。
    public var lyricsKeyboardDeviceID: UUID?
    public var pushIntervalSeconds: Int
    public var jpegQuality: Int
    public var customImagePath: String?
    public var canvasBoards: [AIMacCanvasBoard]
    public var canvasBoardIndex: Int
    public var boardRotationEnabled: Bool
    public var boardRotationMinutes: Int
    /// 当前功能卡片，以及这台设备自己的侧栏顺序与自动轮播池。
    /// 均使用 DisplayMode.rawValue 存储，新增卡片时旧设置文件可自然向前兼容。
    public var cardModeRawValue: Int?
    public var cardPanels: [Int]?
    public var cardRotationModes: [Int]?
    public var cardRotationEnabled: Bool
    public var cardRotationMinutes: Int
    /// 这台小屏幕独立 Home Assistant 卡片的实体列表。nil 仅表示旧设置文件，
    /// 由应用首次读取时兼容原键盘选择；空数组表示用户明确未选择。
    public var haCardEntityIDs: [String]?

    public init(host: String = "", mode: AIMacScreenContentMode = .canvas,
                autoPush: Bool = true, followSystemSleep: Bool = true,
                awakeBrightness: Int? = nil,
                lyricsKeyboardDeviceID: UUID? = nil,
                pushIntervalSeconds: Int = 2,
                jpegQuality: Int = 82, customImagePath: String? = nil,
                canvasBoards: [AIMacCanvasBoard] = [], canvasBoardIndex: Int = 0,
                boardRotationEnabled: Bool = false, boardRotationMinutes: Int = 5,
                cardModeRawValue: Int? = nil, cardPanels: [Int]? = [],
                cardRotationModes: [Int]? = [], cardRotationEnabled: Bool = false,
                cardRotationMinutes: Int = 5, haCardEntityIDs: [String]? = []) {
        self.host = host
        self.mode = mode
        self.autoPush = autoPush
        self.followSystemSleep = followSystemSleep
        self.awakeBrightness = awakeBrightness
        self.lyricsKeyboardDeviceID = lyricsKeyboardDeviceID
        self.pushIntervalSeconds = min(max(pushIntervalSeconds, 1), 60)
        self.jpegQuality = min(max(jpegQuality, 50), 90)
        self.customImagePath = customImagePath
        self.canvasBoards = canvasBoards
        self.canvasBoardIndex = canvasBoardIndex
        self.boardRotationEnabled = boardRotationEnabled
        self.boardRotationMinutes = boardRotationMinutes
        self.cardModeRawValue = cardModeRawValue
        self.cardPanels = cardPanels
        self.cardRotationModes = cardRotationModes
        self.cardRotationEnabled = cardRotationEnabled
        self.cardRotationMinutes = cardRotationMinutes
        self.haCardEntityIDs = haCardEntityIDs
        clamp()
    }

    public var cardMode: DisplayMode {
        get { cardModeRawValue.flatMap(DisplayMode.init(rawValue:)) ?? .systemMonitor }
        set { cardModeRawValue = newValue.rawValue }
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
        cardRotationMinutes = min(max(cardRotationMinutes, 1), 60)
        if let awakeBrightness {
            self.awakeBrightness = min(max(awakeBrightness, 1), 100)
        }
        if let values = cardPanels {
            var seen = Set<Int>()
            cardPanels = values.filter { DisplayMode(rawValue: $0) != nil && seen.insert($0).inserted }
        }
        if let values = cardRotationModes {
            var seen = Set<Int>()
            cardRotationModes = values.filter { DisplayMode(rawValue: $0) != nil && seen.insert($0).inserted }
        }
        if let values = haCardEntityIDs {
            var seen = Set<String>()
            haCardEntityIDs = values.compactMap { raw in
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return !value.isEmpty && seen.insert(value).inserted ? value : nil
            }
        }
        if DisplayMode(rawValue: cardModeRawValue ?? -1) == nil { cardModeRawValue = nil }
    }

    private enum CodingKeys: String, CodingKey {
        case host, mode, autoPush, followSystemSleep, awakeBrightness, lyricsKeyboardDeviceID
        case pushIntervalSeconds, jpegQuality, customImagePath
        case canvasBoards, canvasBoardIndex, boardRotationEnabled, boardRotationMinutes
        case cardModeRawValue, cardPanels, cardRotationModes, cardRotationEnabled, cardRotationMinutes
        case haCardEntityIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        mode = try container.decodeIfPresent(AIMacScreenContentMode.self, forKey: .mode) ?? .dashboard
        autoPush = try container.decodeIfPresent(Bool.self, forKey: .autoPush) ?? true
        followSystemSleep = try container.decodeIfPresent(Bool.self,
                                                          forKey: .followSystemSleep) ?? true
        awakeBrightness = try container.decodeIfPresent(Int.self, forKey: .awakeBrightness)
        lyricsKeyboardDeviceID = try container.decodeIfPresent(UUID.self,
                                                               forKey: .lyricsKeyboardDeviceID)
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
        cardModeRawValue = try container.decodeIfPresent(Int.self, forKey: .cardModeRawValue)
        cardPanels = try container.decodeIfPresent([Int].self, forKey: .cardPanels)
        cardRotationModes = try container.decodeIfPresent([Int].self, forKey: .cardRotationModes)
        cardRotationEnabled = try container.decodeIfPresent(Bool.self,
                                                            forKey: .cardRotationEnabled) ?? false
        cardRotationMinutes = try container.decodeIfPresent(Int.self,
                                                            forKey: .cardRotationMinutes) ?? 5
        haCardEntityIDs = try container.decodeIfPresent([String].self, forKey: .haCardEntityIDs)
        // 把旧版固定页面无损迁移到统一卡片模式。旧桌面时钟升级为设备端
        // 原生时钟卡片，避免继续按秒上传整张图片。
        if cardModeRawValue == nil {
            switch mode {
            case .dashboard:
                cardModeRawValue = DisplayMode.systemMonitor.rawValue
                mode = .card
            case .customImage:
                cardModeRawValue = DisplayMode.customImage.rawValue
                mode = .card
            case .clock:
                cardModeRawValue = DisplayMode.aiMacClock.rawValue
                mode = .card
                if var panels = cardPanels,
                   !panels.contains(DisplayMode.aiMacClock.rawValue) {
                    panels.append(DisplayMode.aiMacClock.rawValue)
                    cardPanels = panels
                }
            case .canvas, .card:
                break
            }
        }
        clamp()
    }
}

public struct AIMacScreenCapabilities: Equatable {
    public let host: String
    public let jpegUploadURL: URL
    public let rgb565UploadURL: URL?
    public let brightnessURL: URL?
    public let brightnessLevel: Int?
    public let nativeClockURL: URL?
    public let nativeNowPlayingURL: URL?

    public init(host: String, jpegUploadURL: URL, rgb565UploadURL: URL?,
                brightnessURL: URL? = nil, brightnessLevel: Int? = nil,
                nativeClockURL: URL? = nil,
                nativeNowPlayingURL: URL? = nil) {
        self.host = host
        self.jpegUploadURL = jpegUploadURL
        self.rgb565UploadURL = rgb565UploadURL
        self.brightnessURL = brightnessURL
        self.brightnessLevel = brightnessLevel
        self.nativeClockURL = nativeClockURL
        self.nativeNowPlayingURL = nativeNowPlayingURL
    }

    public var supportsLosslessRGB565: Bool { rgb565UploadURL != nil }
    public var supportsBrightnessControl: Bool { brightnessURL != nil }
    public var supportsNativeClock: Bool { nativeClockURL != nil }
    public var supportsNativeNowPlaying: Bool { nativeNowPlayingURL != nil }
}

public enum AIMacScreenSupportError: Error, LocalizedError {
    case invalidHost
    case invalidDevice
    case imageTooLarge(Int)
    case encodeFailed
    case noCustomImage
    case nativeClockUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidHost: return "请先填写小屏幕的 IP 地址。"
        case .invalidDevice: return "已连接，但目标不是兼容的 AI Mac 240×240 固件。"
        case .imageTooLarge(let size): return "图片压缩后仍有 \(size) 字节，超过旧固件 24KB 上限。"
        case .encodeFailed: return "无法生成 240×240 画面。"
        case .noCustomImage: return "请先选择一张图片。"
        case .nativeClockUnavailable: return "当前小屏幕固件不支持设备端时钟，请重新刷入最新固件。"
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
        let brightnessLevel = (json["brightness"] as? Int).map { min(max($0, 0), 100) }
        let brightnessURL = brightnessLevel == nil
            ? nil : URL(string: "http://\(host)/api/brightness")
        var nativeClockURL: URL?
        if let raw = json["native_clock_api"] as? [String: Any],
           raw["device_rendered"] as? Bool == true,
           let path = raw["path"] as? String, path.hasPrefix("/") {
            nativeClockURL = URL(string: "http://\(host)\(path)")
        }
        var nativeNowPlayingURL: URL?
        if let raw = json["native_now_playing_api"] as? [String: Any],
           raw["device_rendered_progress"] as? Bool == true,
           let path = raw["path"] as? String, path.hasPrefix("/") {
            nativeNowPlayingURL = URL(string: "http://\(host)\(path)")
        }
        return AIMacScreenCapabilities(host: host, jpegUploadURL: jpegURL,
                                       rgb565UploadURL: rgb565URL,
                                       brightnessURL: brightnessURL,
                                       brightnessLevel: brightnessLevel,
                                       nativeClockURL: nativeClockURL,
                                       nativeNowPlayingURL: nativeNowPlayingURL)
    }

    /// 0.8.1+ 固件使用 POST 查询参数调整背光；0 表示彻底熄屏。
    public static func brightnessRequest(url: URL, level: Int) -> URLRequest? {
        let bounded = min(max(level, 0), 100)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "level", value: String(bounded))]
        guard let target = components.url else { return nil }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    /// 切入设备端时钟时只发送一次校时和时区；之后的逐秒计算、排版与绘制
    /// 均在小屏幕固件内完成，不再依赖图片推送节拍。
    public static func nativeClockRequest(url: URL, now: Date,
                                          timeZone: TimeZone = .current) -> URLRequest? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let epoch = Int(now.timeIntervalSince1970.rounded(.down))
        let offset = timeZone.secondsFromGMT(for: now)
        components.queryItems = [
            URLQueryItem(name: "enabled", value: "1"),
            URLQueryItem(name: "epoch", value: String(epoch)),
            URLQueryItem(name: "tz", value: String(offset))
        ]
        guard let target = components.url else { return nil }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    /// 把播放时间锚点交给设备。封面、标题等低频内容仍由完整图片提供；进度条、
    /// 已播放和剩余时间由固件按本地毫秒时钟连续绘制。
    public static func nativeNowPlayingRequest(
        url: URL, info: NowPlayingInfo,
        background: (CGFloat, CGFloat, CGFloat),
        track: (CGFloat, CGFloat, CGFloat),
        accent: (CGFloat, CGFloat, CGFloat),
        text: (CGFloat, CGFloat, CGFloat),
        now: Date = Date()
    ) -> URLRequest? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        func rgb24(_ color: (CGFloat, CGFloat, CGFloat)) -> Int {
            let r = Int((min(max(color.0, 0), 1) * 255).rounded())
            let g = Int((min(max(color.1, 0), 1) * 255).rounded())
            let b = Int((min(max(color.2, 0), 1) * 255).rounded())
            return (r << 16) | (g << 8) | b
        }
        let elapsed = Int((info.effectiveElapsed(at: now) * 1_000).rounded())
        let duration = Int((max(info.duration, 0) * 1_000).rounded())
        let rate = Int((max(info.playbackRate, 0) * 1_000).rounded())
        components.queryItems = [
            URLQueryItem(name: "enabled", value: "1"),
            URLQueryItem(name: "playing", value: info.isPlaying ? "1" : "0"),
            URLQueryItem(name: "elapsed_ms", value: String(max(elapsed, 0))),
            URLQueryItem(name: "duration_ms", value: String(max(duration, 0))),
            URLQueryItem(name: "rate_milli", value: String(rate)),
            URLQueryItem(name: "bg", value: String(rgb24(background))),
            URLQueryItem(name: "track", value: String(rgb24(track))),
            URLQueryItem(name: "accent", value: String(rgb24(accent))),
            URLQueryItem(name: "text", value: String(rgb24(text)))
        ]
        guard let target = components.url else { return nil }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
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
        case .canvas, .card:
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

    /// 方形彩屏 Emoji 壁纸专用渲染。布局参数继续复用同一张功能卡片设置，
    /// 但按目标设备的原生尺寸重新排版，不缩放灵犀 68 的纵向成品图。
    public static func renderEmojiWallpaper(settings: AppSettings) throws -> CGImage {
        let size = frameSize
        let palette = settings.resolvedPalette
        let emojis = Array(settings.emojiWallpaperText)
        let base = CGFloat(min(max(settings.emojiWallpaperSize, 20), 76))
        let gap = CGFloat(min(max(settings.emojiWallpaperSpacing, 0), 28))

        // Emoji 壁纸先在更大的完整画布上排版，最终只截取正中央的 240×240。
        // 网格外围的中心点会主动落在最终裁切线及其外侧：这样溢出的是整张壁纸，
        // 不是放大某一个 Emoji；布局中心仍精确对应小屏幕中心。螺旋则保持自然
        // 轨迹并继续生成到裁切范围之外，不额外叠加人工外围环。
        let overscan = max(48, Int(ceil(base + gap)))
        let wallpaperSize = size + overscan * 2
        let wallpaperSide = CGFloat(wallpaperSize)
        let center = wallpaperSide / 2
        let visibleSide = CGFloat(size)
        let visibleHalf = visibleSide / 2
        guard let context = CGContext(data: nil, width: wallpaperSize, height: wallpaperSize,
                                      bitsPerComponent: 8, bytesPerRow: wallpaperSize * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)
                                        ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AIMacScreenSupportError.encodeFailed
        }
        context.setFillColor(CGColor(red: palette.background.0, green: palette.background.1,
                                     blue: palette.background.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: wallpaperSide, height: wallpaperSide))
        guard !emojis.isEmpty else {
            drawText("在设置中输入 emoji", size: 14, weight: .medium,
                     color: NSColor(calibratedRed: palette.secondaryText.0,
                                    green: palette.secondaryText.1,
                                    blue: palette.secondaryText.2, alpha: 1),
                     rect: CGRect(x: center - 108, y: center - 16, width: 216, height: 32),
                     context: context, alignment: .center)
            guard let wallpaper = context.makeImage(),
                  let output = wallpaper.cropping(
                    to: CGRect(x: CGFloat(overscan), y: CGFloat(overscan),
                               width: CGFloat(size), height: CGFloat(size))) else {
                throw AIMacScreenSupportError.encodeFailed
            }
            return output
        }
        func emoji(at index: Int) -> String {
            let normalized = (index % emojis.count + emojis.count) % emojis.count
            return String(emojis[normalized])
        }
        // 以屏幕半边为基准把近似步距吸附到整数份。网格仍以屏幕中心为原点，
        // 同时必然在 x/y = 0、240 的裁切线上各有一列/行，图案会自然跨出边界。
        func edgeAlignedStep(near requested: CGFloat) -> (step: CGFloat, intervals: Int) {
            let target = max(requested, 1)
            // 向下取整让实际间距只会略放大，不会为了对齐边缘突然挤出更多行列。
            let intervals = max(1, Int(floor(visibleHalf / target)))
            return (visibleHalf / CGFloat(intervals), intervals)
        }
        switch settings.emojiWallpaperLayout {
        case .grid:
            let aligned = edgeAlignedStep(near: max(28, base + gap))
            let cell = aligned.step
            let extent = aligned.intervals + 2
            let stride = extent * 2 + 1
            for row in -extent...extent {
                for column in -extent...extent {
                    drawEmoji(emoji(at: row * stride + column), size: base,
                              center: CGPoint(x: center + CGFloat(column) * cell,
                                              y: center + CGFloat(row) * cell),
                              context: context)
                }
            }
        case .mixedSize:
            let aligned = edgeAlignedStep(near: max(34, base * 0.82 + gap))
            let cell = aligned.step
            let extent = aligned.intervals + 2
            let stride = extent * 2 + 1
            for row in -extent...extent {
                for column in -extent...extent {
                    // 最外围保持足够大的图案，使裁切后的四边确实能看到出血内容；
                    // 屏幕内部继续保留原来的大小交替节奏。
                    let onVisibleEdge = abs(row) == aligned.intervals
                        || abs(column) == aligned.intervals
                    let scale: CGFloat = onVisibleEdge
                        ? 1.04 : ((row + column).isMultiple(of: 3) ? 1.18 : 0.78)
                    drawEmoji(emoji(at: row * stride + column), size: base * scale,
                              center: CGPoint(x: center + CGFloat(column) * cell,
                                              y: center + CGFloat(row) * cell),
                              context: context)
                }
            }
        case .spiral:
            let maxGlyphSize = base * 1.45
            let maxRadius = hypot(center, center) + maxGlyphSize
            let minGlyphSize = max(18, base * 0.55)
            var angle: CGFloat = 0
            var radius: CGFloat = 0
            var index = 0
            while radius <= maxRadius, index < 1600 {
                let progress = min(radius / max(maxRadius, 1), 1)
                let glyphSize = minGlyphSize + (maxGlyphSize - minGlyphSize) * progress
                let point = CGPoint(x: center + cos(angle) * radius,
                                    y: center + sin(angle) * radius)
                if point.x > -glyphSize, point.x < wallpaperSide + glyphSize,
                   point.y > -glyphSize, point.y < wallpaperSide + glyphSize {
                    drawEmoji(emoji(at: index), size: glyphSize * 0.82,
                              center: point, context: context)
                }
                let localGap = gap * (0.35 + progress * 0.65)
                let step = max(glyphSize + localGap, minGlyphSize)
                let delta = step / max(radius, step)
                angle += delta
                radius += step * delta / (2 * .pi)
                index += 1
            }
        }
        guard let wallpaper = context.makeImage(),
              let output = wallpaper.cropping(
                to: CGRect(x: CGFloat(overscan), y: CGFloat(overscan),
                           width: CGFloat(size), height: CGFloat(size))) else {
            throw AIMacScreenSupportError.encodeFailed
        }
        return output
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
        AIMacFirmwareClockPreview.draw(in: context, now: now)
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

    /// Emoji 的排布步距只决定中心点，不再兼作字形裁切框。Apple Color Emoji 的
    /// 彩色位图经常会超出字体标称方框，直接按单元格 draw(in:) 会在字号增大时
    /// 出现整齐的矩形缺口；Core Text 按基线绘制后只受最终画布边缘裁切。
    private static func drawEmoji(_ text: String, size: CGFloat,
                                  center: CGPoint, context: CGContext) {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.saveGState()
        context.textPosition = CGPoint(x: center.x - width / 2,
                                       y: center.y - (ascent - descent) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
