import AppKit
import Combine
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LinxDisplayCore
import SwiftUI
import UniformTypeIdentifiers

enum AIMacScreenMode: String, CaseIterable, Codable, Identifiable {
    case dashboard
    case clock
    case customImage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "系统仪表盘"
        case .clock: return "桌面时钟"
        case .customImage: return "自定义图片"
        }
    }
}

struct AIMacScreenSettings: Codable, Equatable {
    var host = ""
    var mode: AIMacScreenMode = .dashboard
    var autoPush = true
    var pushIntervalSeconds = 2
    var jpegQuality = 82
    var customImagePath: String?
}

/// Storage exclusive to the experimental 240x240 app.  Deliberately does not
/// use LinxDisplayCore.SettingsStore and performs no migration from LinxDisplay.
struct AIMacScreenSettingsStore {
    let directory: URL

    init(root: URL? = nil) {
        let applicationSupport = root
            ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first!
        directory = applicationSupport
            .appendingPathComponent("LingxiAIMacScreenExperimental", isDirectory: true)
    }

    var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    func load() -> AIMacScreenSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(AIMacScreenSettings.self,
                                                        from: data) else {
            return AIMacScreenSettings()
        }
        return settings
    }

    func save(_ settings: AIMacScreenSettings) {
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            NSLog("[AIMacScreen] settings save failed: %@", error.localizedDescription)
        }
    }
}

enum AIMacScreenError: Error, LocalizedError {
    case invalidHost
    case invalidDevice(String)
    case imageTooLarge(Int)
    case encodeFailed
    case noCustomImage

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "请先填写小屏幕的 IP 地址。"
        case .invalidDevice(let message): return message
        case .imageTooLarge(let size): return "图片压缩后仍有 \(size) 字节，超过固件 24KB 上限。"
        case .encodeFailed: return "无法生成 240×240 JPEG。"
        case .noCustomImage: return "请先选择一张图片。"
        }
    }
}

@MainActor
final class AIMacScreenModel: ObservableObject {
    static let frameSize = 240
    static let maximumJPEGBytes = 24 * 1024

    @Published var settings: AIMacScreenSettings {
        didSet {
            store.save(settings)
            renderPreview()
        }
    }
    @Published private(set) var preview: NSImage?
    @Published private(set) var status = "等待连接小屏幕"
    @Published private(set) var lastPush = "尚未推送"
    @Published private(set) var busy = false

    private let store: AIMacScreenSettingsStore
    private let imageAPI = ImageApiClient()
    private let monitor = SystemMonitor()
    private var system = SystemSnapshot.empty
    private var timer: Timer?
    private var lastUploadedHash: String?
    private var lastPushAt: Date?

    init(store: AIMacScreenSettingsStore = AIMacScreenSettingsStore()) {
        self.store = store
        settings = store.load()
        system = monitor.sample()
        renderPreview()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    deinit { timer?.invalidate() }

    var hostBinding: Binding<String> {
        Binding(get: { self.settings.host }, set: { self.settings.host = $0 })
    }

    var modeBinding: Binding<AIMacScreenMode> {
        Binding(get: { self.settings.mode }, set: { self.settings.mode = $0 })
    }

    var autoPushBinding: Binding<Bool> {
        Binding(get: { self.settings.autoPush }, set: { self.settings.autoPush = $0 })
    }

    var intervalBinding: Binding<Int> {
        Binding(get: { self.settings.pushIntervalSeconds },
                set: { self.settings.pushIntervalSeconds = min(max($0, 1), 60) })
    }

    var qualityBinding: Binding<Int> {
        Binding(get: { self.settings.jpegQuality },
                set: { self.settings.jpegQuality = min(max($0, 50), 90) })
    }

    private func tick() {
        system = monitor.sample()
        renderPreview()
        guard settings.autoPush, !busy, !normalizedHost.isEmpty else { return }
        let interval = TimeInterval(settings.pushIntervalSeconds)
        if let lastPushAt, Date().timeIntervalSince(lastPushAt) < interval { return }
        Task { await push(force: false) }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .gif]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.customImagePath = url.path
        settings.mode = .customImage
        status = "已选择 \(url.lastPathComponent)"
    }

    func pushNow() {
        Task { await push(force: true) }
    }

    func testConnection() {
        Task {
            guard let url = infoURL else {
                status = AIMacScreenError.invalidHost.localizedDescription
                return
            }
            busy = true
            defer { busy = false }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 4
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["device"] as? String == "esp8266-ai-screen",
                      let screen = json["screen"] as? [String: Any],
                      screen["width"] as? Int == Self.frameSize,
                      screen["height"] as? Int == Self.frameSize else {
                    throw AIMacScreenError.invalidDevice("已连接，但目标不是兼容的 AI Mac 240×240 固件。")
                }
                status = "连接成功 · 240×240 图片 API 可用"
            } catch {
                status = Self.friendly(error)
            }
        }
    }

    private func push(force: Bool) async {
        guard !busy else { return }
        guard let endpoint = uploadURL?.absoluteString else {
            status = AIMacScreenError.invalidHost.localizedDescription
            return
        }
        busy = true
        defer { busy = false }
        do {
            let result = try renderFrame()
            let jpeg = try Self.encodeJPEG(result, preferredQuality: settings.jpegQuality)
            let hash = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
            if !force, hash == lastUploadedHash {
                lastPushAt = Date()
                return
            }
            status = "正在推送 240×240 画面…"
            let code = try await imageAPI.upload(jpeg: jpeg, endpoint: endpoint, timeout: 8)
            lastUploadedHash = hash
            lastPushAt = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            lastPush = "最后推送 \(formatter.string(from: Date())) · \(jpeg.count) B"
            status = "推送成功（HTTP \(code)）"
        } catch {
            lastPushAt = Date()
            status = Self.friendly(error)
        }
    }

    private var normalizedHost: String {
        var value = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("http://") { value.removeFirst("http://".count) }
        if value.hasPrefix("https://") { value.removeFirst("https://".count) }
        value = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return value
    }

    private var uploadURL: URL? {
        guard !normalizedHost.isEmpty else { return nil }
        return URL(string: "http://\(normalizedHost)/image/upload")
    }

    private var infoURL: URL? {
        guard !normalizedHost.isEmpty else { return nil }
        return URL(string: "http://\(normalizedHost)/api/info")
    }

    private func renderPreview() {
        guard let image = try? renderFrame() else { return }
        preview = NSImage(cgImage: image,
                          size: NSSize(width: Self.frameSize, height: Self.frameSize))
    }

    private func renderFrame() throws -> CGImage {
        let size = Self.frameSize
        guard let context = CGContext(data: nil, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AIMacScreenError.encodeFailed
        }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        switch settings.mode {
        case .dashboard: drawDashboard(in: context)
        case .clock: drawClock(in: context)
        case .customImage: try drawCustomImage(in: context)
        }
        guard let image = context.makeImage() else { throw AIMacScreenError.encodeFailed }
        return image
    }

    private func fillBackground(_ context: CGContext) {
        context.setFillColor(CGColor(red: 0.025, green: 0.04, blue: 0.075, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
    }

    private func drawDashboard(in context: CGContext) {
        fillBackground(context)
        drawText("LINGXI", size: 13, weight: .bold,
                 color: NSColor(calibratedRed: 0.33, green: 0.90, blue: 0.72, alpha: 1),
                 rect: CGRect(x: 14, y: 210, width: 100, height: 18), context: context)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        drawText(formatter.string(from: Date()), size: 31, weight: .bold,
                 color: .white, rect: CGRect(x: 14, y: 164, width: 212, height: 42),
                 context: context)
        formatter.dateFormat = "M月d日 EEE"
        drawText(formatter.string(from: Date()), size: 12, weight: .regular,
                 color: NSColor(white: 0.70, alpha: 1),
                 rect: CGRect(x: 15, y: 145, width: 210, height: 18), context: context)

        drawMetric("CPU", value: system.cpuPercent, y: 103, context: context)
        drawMetric("MEM", value: system.memoryPercent, y: 66, context: context)
        let down = ScreenRenderer.formatRate(system.downloadBytesPerSecond)
        let up = ScreenRenderer.formatRate(system.uploadBytesPerSecond)
        drawText("↓ \(down)", size: 12, weight: .medium,
                 color: NSColor(calibratedRed: 0.33, green: 0.90, blue: 0.72, alpha: 1),
                 rect: CGRect(x: 14, y: 20, width: 105, height: 22), context: context)
        drawText("↑ \(up)", size: 12, weight: .medium,
                 color: NSColor(calibratedRed: 0.38, green: 0.65, blue: 0.98, alpha: 1),
                 rect: CGRect(x: 121, y: 20, width: 105, height: 22), context: context)
    }

    private func drawClock(in context: CGContext) {
        fillBackground(context)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        drawText(formatter.string(from: Date()), size: 58, weight: .bold,
                 color: .white, rect: CGRect(x: 8, y: 105, width: 224, height: 72),
                 context: context, alignment: .center)
        formatter.dateFormat = "ss"
        drawText(formatter.string(from: Date()), size: 22, weight: .bold,
                 color: NSColor(calibratedRed: 0.33, green: 0.90, blue: 0.72, alpha: 1),
                 rect: CGRect(x: 8, y: 82, width: 224, height: 26),
                 context: context, alignment: .center)
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        drawText(formatter.string(from: Date()), size: 14, weight: .medium,
                 color: NSColor(white: 0.72, alpha: 1),
                 rect: CGRect(x: 8, y: 55, width: 224, height: 22),
                 context: context, alignment: .center)
    }

    private func drawCustomImage(in context: CGContext) throws {
        guard let path = settings.customImagePath,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AIMacScreenError.noCustomImage
        }
        let side = min(image.width, image.height)
        let crop = CGRect(x: CGFloat(image.width - side) / 2,
                          y: CGFloat(image.height - side) / 2,
                          width: CGFloat(side), height: CGFloat(side))
        guard let square = image.cropping(to: crop) else {
            throw AIMacScreenError.noCustomImage
        }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: 240, height: 240))
    }

    private func drawMetric(_ name: String, value: Double, y: CGFloat, context: CGContext) {
        let clamped = min(max(value, 0), 100)
        drawText(name, size: 11, weight: .bold, color: NSColor(white: 0.75, alpha: 1),
                 rect: CGRect(x: 14, y: y + 9, width: 38, height: 18), context: context)
        drawText("\(Int(clamped.rounded()))%", size: 13, weight: .bold, color: .white,
                 rect: CGRect(x: 170, y: y + 8, width: 56, height: 18),
                 context: context, alignment: .right)
        let bar = CGRect(x: 54, y: y + 12, width: 108, height: 9)
        let path = CGPath(roundedRect: bar, cornerWidth: 4.5, cornerHeight: 4.5,
                          transform: nil)
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.addPath(path)
        context.fillPath()
        let fill = CGRect(x: bar.minX, y: bar.minY,
                          width: max(9, bar.width * clamped / 100), height: bar.height)
        context.setFillColor(CGColor(red: 0.33, green: 0.90, blue: 0.72, alpha: 1))
        context.addPath(CGPath(roundedRect: fill, cornerWidth: 4.5, cornerHeight: 4.5,
                               transform: nil))
        context.fillPath()
    }

    private func drawText(_ text: String, size: CGFloat, weight: NSFont.Weight,
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

    static func encodeJPEG(_ image: CGImage, preferredQuality: Int) throws -> Data {
        var lastSize = 0
        let preferred = min(max(preferredQuality, 50), 90)
        let qualities = stride(from: preferred, through: 45, by: -5)
        for quality in qualities {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw AIMacScreenError.encodeFailed
            }
            CGImageDestinationAddImage(destination, image,
                [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw AIMacScreenError.encodeFailed
            }
            lastSize = data.length
            if data.length <= maximumJPEGBytes { return data as Data }
        }
        throw AIMacScreenError.imageTooLarge(lastSize)
    }

    private static func friendly(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
