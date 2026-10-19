import Foundation
import CoreGraphics
import C6DisplayRenderer

/// Values must come from the corresponding printer snapshot. A missing progress
/// is not converted to a fictitious zero-percent job.
public struct C6PrinterSummary: Equatable, Sendable {
    public var name: String, status: String
    public var progress: Double?
    public var enabled: Bool, connected: Bool, formlabs: Bool
    public init(name: String, status: String, progress: Double?, enabled: Bool = true,
                connected: Bool, formlabs: Bool = false) {
        self.name = name; self.status = status; self.progress = progress
        self.enabled = enabled; self.connected = connected; self.formlabs = formlabs
    }
}

/// Portable classic-style cards for the C6's local firmware. Their palette and
/// information hierarchy come from the existing AI Mac cards, rather than replacing
/// the richer online renderer. Complex SwiftUI glass is not reproduced offline.
/// Every invocation owns its frame and font cache; simultaneous previews cannot
/// change another device's pixels or strings.
public enum C6LocalRenderer {
    public static let width = 240
    public static let height = 240
    public static let frameBytes = 115_200

    public static func printerOverviewFrame(_ summaries: [C6PrinterSummary],
                                             palette: ScreenPalette? = nil,
                                             language: C6Language = .chinese,
                                             digitStyle: C6DigitStyle = .pixel,
                                             saturationPercent: Int = 100, contrastPercent: Int = 100) -> Data {
        let strings = Strings()
        var style = portableStyle(palette)
        var rows = summaries.prefix(3).map { summary -> c6_render_printer_summary_t in
            var row = c6_render_printer_summary_t()
            row.name = strings.add(summary.name); row.status = strings.add(summary.status)
            row.enabled = summary.enabled; row.connected = summary.connected; row.formlabs = summary.formlabs
            row.progress_available = summary.progress?.isFinite == true
            row.progress = Int32((summary.progress?.isFinite == true ? min(100, max(0, summary.progress!)) : 0).rounded(.towardZero))
            return row
        }
        return withExtendedLifetime(strings) {
            render(language: language, digitStyle: digitStyle, saturationPercent: saturationPercent, contrastPercent: contrastPercent) { renderer in
                rows.withUnsafeMutableBufferPointer {
                    c6_renderer_printer_overview_styled(renderer, $0.baseAddress, UInt32($0.count), &style)
                }
            }
        }
    }

    public static func weatherFrame(_ snapshot: WeatherSnapshot?, city: String,
                                    now: Date = Date(), timeZone: TimeZone = .current,
                                    language: C6Language = .chinese, digitStyle: C6DigitStyle = .pixel,
                                    saturationPercent: Int = 100, contrastPercent: Int = 100) -> Data {
        let strings = Strings()
        var value = c6_render_weather_t()
        value.city = strings.add(city)
        value.valid = snapshot != nil
        if let s = snapshot {
            value.temperature = s.temperature; value.apparent = s.apparent
            value.low = s.low; value.high = s.high; value.code = Int32(s.code)
            value.rain = Int32(s.rainProbability)
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            value.updated_hour = Int32(calendar.component(.hour, from: s.updatedAt))
            value.updated_minute = Int32(calendar.component(.minute, from: s.updatedAt))
            value.stale = now.timeIntervalSince(s.updatedAt) > 10_800
        }
        return withExtendedLifetime(strings) {
            render(language: language, digitStyle: digitStyle, saturationPercent: saturationPercent, contrastPercent: contrastPercent) {
                c6_renderer_weather($0, &value)
            }
        }
    }

    public static func weather(_ snapshot: WeatherSnapshot?, city: String,
                               now: Date = Date(), timeZone: TimeZone = .current,
                               language: C6Language = .chinese, digitStyle: C6DigitStyle = .pixel,
                               saturationPercent: Int = 100, contrastPercent: Int = 100) -> CGImage? {
        image(fromRGB565: weatherFrame(snapshot, city: city, now: now, timeZone: timeZone,
            language: language, digitStyle: digitStyle,
            saturationPercent: saturationPercent, contrastPercent: contrastPercent))
    }

    /// Supply one group of at most four entities, in their saved order.
    public static func entitiesFrame(_ entities: [HAEntity], title: String = "Home System",
                                     connected: Bool = true,
                                     language: C6Language = .chinese,
                                     palette: ScreenPalette? = nil,
                                     images: [String: Data] = [:],
                                     saturationPercent: Int = 100, contrastPercent: Int = 100) -> Data {
        let strings = Strings(); let titlePointer = strings.add(title)
        var style = portableStyle(palette)
        var items = entities.prefix(4).map { entity -> c6_render_entity_t in
            var value = c6_render_entity_t()
            value.name = strings.add(entity.displayName)
            value.state = strings.add(entity.displayState)
            value.unit = strings.add(entity.unitOfMeasurement ?? "")
            value.available = entity.state != "unavailable" && entity.state != "unknown"
            value.media = entity.entityId.hasPrefix("camera.") || entity.entityId.hasPrefix("image.")
            if let data = images[entity.entityId], let frame = C6TaskThumbnail.encodeMedia(from: data) { value.picture = strings.picture(frame) }
            return value
        }
        return withExtendedLifetime(strings) { render(language: language, saturationPercent: saturationPercent, contrastPercent: contrastPercent) { renderer in
            items.withUnsafeMutableBufferPointer {
                c6_renderer_entities_styled(renderer, titlePointer, $0.baseAddress, UInt32($0.count), connected, &style)
            }
        } }
    }

    public static func entities(_ entities: [HAEntity], title: String = "Home System",
                                connected: Bool = true,
                                language: C6Language = .chinese,
                                palette: ScreenPalette? = nil,
                                images: [String: Data] = [:],
                                saturationPercent: Int = 100, contrastPercent: Int = 100) -> CGImage? {
        image(fromRGB565: entitiesFrame(entities, title: title, connected: connected,
            language: language,
            palette: palette, images: images,
            saturationPercent: saturationPercent, contrastPercent: contrastPercent))
    }

    /// The optional thumbnail is the same 80×80 canonical RGB565 payload sent
    /// through the task-cover cache API. Camera streams are not local sources.
    public static func printerFrame(settings: BambuLabCardSettings, entities: [HAEntity],
                                    thumbnailRGB565: Data? = nil, connected: Bool = true,
                                    language: C6Language = .chinese, digitStyle: C6DigitStyle = .pixel,
                                    cardStyle: C6PrinterCardStyle = .standard,
                                    palette: ScreenPalette? = nil, dataUpdatedAt: Date? = nil,
                                    cameraImage: Data? = nil, taskCoverImage: Data? = nil,
                                    saturationPercent: Int = 100, contrastPercent: Int = 100) -> Data {
        let strings = Strings()
        func entity(_ id: String) -> HAEntity? {
            guard !id.isEmpty, let item = entities.first(where: { $0.entityId == id }),
                  !["unknown", "unavailable", ""].contains(item.state.lowercased()) else { return nil }
            return item
        }
        func state(_ id: String) -> String { entity(id)?.state ?? "" }
        func number(_ id: String, limit: Double) -> Int32 {
            guard let value = Double(state(id)), value.isFinite else { return 0 }
            return Int32(min(limit, max(0, value)))
        }
        let rawStatus = state(settings.statusEntityID)
        var value = c6_render_printer_t()
        value.card_style = Int32(cardStyle.rawValue)
        value.name = strings.add(settings.name); value.task = strings.add(state(settings.taskEntityID))
        value.status = strings.add(rawStatus)
        value.style = portableStyle(palette)
        if settings.themeAccent == .bambuLab {
            if !value.style.enabled { value.style = c6_renderer_default_style() }
            value.style.accent = 0x629e4e
        }
        value.progress = number(settings.progressEntityID, limit: 100)
        value.remaining = number(settings.remainingEntityID, limit: 1_000_000)
        value.progress_available = Double(state(settings.progressEntityID))?.isFinite == true
        if let remaining = entity(settings.remainingEntityID), let amount = Double(remaining.state), amount.isFinite, amount >= 0 {
            let unit = remaining.unitOfMeasurement?.lowercased() ?? ""
            let seconds = amount * (["s", "sec", "seconds", "秒"].contains(unit) ? 1 : ["h", "hr", "hours", "小时"].contains(unit) ? 3600 : 60)
            value.remaining_seconds = UInt32(min(Double(UInt32.max), max(0, seconds)).rounded(.up))
            value.remaining_available = true
        }
        value.connected = connected && rawStatus != "unavailable" && rawStatus != "unknown"
        value.completed = ["finish", "finished", "completed"].contains(rawStatus.lowercased())
        value.show_task = settings.showTask
        value.show_progress = settings.showProgress && Double(state(settings.progressEntityID))?.isFinite == true
        value.show_status = settings.showStatus; value.show_remaining = settings.showRemaining
        let thumbnail = settings.showImage && thumbnailRGB565?.count == 80 * 80 * 2 ? thumbnailRGB565 : nil
        value.show_image = settings.showImage && (thumbnail != nil || !settings.selectedImageEntityID.isEmpty)
        value.image_label = strings.add(settings.imageSource == .camera ? "实况" : "任务")
        if cameraImage != nil || taskCoverImage != nil {
            value.camera_configured = cameraImage != nil || !settings.imageEntityID.isEmpty
            value.cover_configured = taskCoverImage != nil || !settings.taskImageEntityID.isEmpty
            value.show_image = settings.showImage && (value.camera_configured || value.cover_configured)
            if let data = cameraImage, let frame = C6TaskThumbnail.encodeMedia(from: data) { value.camera = strings.picture(frame) }
            if let data = taskCoverImage, let frame = C6TaskThumbnail.encodeMedia(from: data) { value.cover = strings.picture(frame) }
        }
        func temperature(_ id: String) -> String {
            guard let item = entity(id) else { return "" }
            return item.unitOfMeasurement?.isEmpty == false ? item.displayValue : "\(item.displayState) °C"
        }
        value.nozzle = strings.add(temperature(settings.nozzleTempEntityID))
        value.bed = strings.add(temperature(settings.bedTempEntityID))
        value.show_temperature = settings.showTemperature
        let errorRaw = state(settings.errorEntityID)
        value.is_error = rawStatus.lowercased() == "error"
            || (!["", "none", "无", "normal", "ok", "0", "off"].contains(errorRaw.lowercased()))
        value.error = strings.add(BambuHMSCode.reason(for: errorRaw) ?? errorRaw)
        value.show_error = settings.showError
        var timeText = ""
        if value.completed { timeText = language == .english ? "Completed · retained 30 min" : "已完成 · 保留30分钟" }
        else if let time = entity(settings.selectedTimeEntityID) {
            if settings.timeDisplayMode == .endTime {
                timeText = (language == .english ? "Finish " : "预计结束 ") + ScreenRenderer.bambuCompactCanvasTimeText(time, mode: .endTime)
            } else if (time.unitOfMeasurement ?? "").isEmpty, Double(time.state)?.isFinite == true {
                timeText = language == .english ? "Remaining \(value.remaining) min" : "剩余 \(value.remaining) 分钟"
            } else {
                timeText = (language == .english ? "Remaining " : "剩余 ") + ScreenRenderer.bambuCompactCanvasTimeText(time, mode: .remaining)
            }
        }
        value.time_text = strings.add(timeText)
        if let dataUpdatedAt {
            let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: dataUpdatedAt)
            value.updated_text = strings.add(String(format: language == .english ? "Updated  %02d:%02d:%02d" : "数据更新  %02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0))
        }
        return withExtendedLifetime(strings) { render(language: language, digitStyle: digitStyle, saturationPercent: saturationPercent, contrastPercent: contrastPercent) { renderer in
            if let thumbnail {
                thumbnail.withUnsafeBytes { bytes in
                    value.thumbnail_rgb565 = bytes.bindMemory(to: UInt8.self).baseAddress
                    value.thumbnail_width = 80; value.thumbnail_height = 80; value.thumbnail_stride = 160
                    c6_renderer_printer(renderer, &value)
                }
            } else { c6_renderer_printer(renderer, &value) }
        } }
    }

    public static func formlabsFrame(name: String, configuration: FormlabsConnectionSettings,
                                     snapshot: FormlabsSnapshot, palette: ScreenPalette? = nil,
                                     language: C6Language = .chinese, digitStyle: C6DigitStyle = .pixel,
                                     cardStyle: C6PrinterCardStyle = .standard,
                                     saturationPercent: Int = 100, contrastPercent: Int = 100) -> Data {
        let strings = Strings(); let print = snapshot.print
        var value = c6_render_printer_t()
        value.card_style = Int32(cardStyle.rawValue)
        value.formlabs = true; value.name = strings.add(name); value.task = strings.add(print?.name ?? "")
        value.status = strings.add(print?.status.isEmpty == false ? print!.status : snapshot.device?.status ?? "")
        value.connected = snapshot.device?.isConnected ?? false
        value.style = portableStyle(palette)
        if configuration.useBrandAccent { if !value.style.enabled { value.style = c6_renderer_default_style() }; value.style.accent = 0x2878db }
        let progress = print?.progress
        value.progress_available = progress?.isFinite == true
        value.show_task = true; value.show_status = true; value.show_progress = progress?.isFinite == true
        value.progress = Int32(((progress?.isFinite == true ? min(1, max(0, progress!)) : 0) * 100).rounded(.towardZero))
        value.show_image = configuration.showThumbnail; value.cover_configured = configuration.showThumbnail
        if let data = snapshot.thumbnail, let frame = C6TaskThumbnail.encodeMedia(from: data) { value.cover = strings.picture(frame) }
        if configuration.showLayers, let layer = print?.currentLayer, let total = print?.layerCount, total > 0 { value.layers = strings.add((language == .english ? "Layers " : "层数 ") + "\(layer) / \(total)") }
        value.material = strings.add(configuration.showMaterial ? print?.materialName ?? "" : "")
        if let remaining = print?.estimatedTimeRemainingMS ?? snapshot.device?.estimatedPrintTimeRemainingMS, remaining >= 0, remaining.isFinite {
            value.show_remaining = true
            value.remaining_seconds = UInt32(min(Double(UInt32.max), ceil(remaining / 1000)))
            value.remaining_available = true
            let minutes = Int(min(525600, ceil(remaining / 60000)))
            value.time_text = strings.add(language == .english ? "Remaining \(minutes) min" : "剩余 \(minutes) 分钟")
        }
        return withExtendedLifetime(strings) { render(language: language, digitStyle: digitStyle,
            saturationPercent: saturationPercent, contrastPercent: contrastPercent) { c6_renderer_printer($0, &value) } }
    }

    public static func printer(settings: BambuLabCardSettings, entities: [HAEntity],
                               thumbnailRGB565: Data? = nil, connected: Bool = true,
                               language: C6Language = .chinese, digitStyle: C6DigitStyle = .pixel,
                               cardStyle: C6PrinterCardStyle = .standard,
                               palette: ScreenPalette? = nil, dataUpdatedAt: Date? = nil,
                               saturationPercent: Int = 100, contrastPercent: Int = 100) -> CGImage? {
        image(fromRGB565: printerFrame(settings: settings, entities: entities,
            thumbnailRGB565: thumbnailRGB565, connected: connected,
            language: language, digitStyle: digitStyle, cardStyle: cardStyle,
            palette: palette, dataUpdatedAt: dataUpdatedAt,
            saturationPercent: saturationPercent, contrastPercent: contrastPercent))
    }

    private static func portableStyle(_ palette: ScreenPalette?) -> c6_render_style_t {
        guard let p = palette else { return c6_render_style_t() }
        func rgb(_ channel: (CGFloat, CGFloat, CGFloat)) -> UInt32 {
            func byte(_ number: CGFloat) -> UInt32 { UInt32((min(1, max(0, number)) * 255).rounded()) }
            return (byte(channel.0) << 16) | (byte(channel.1) << 8) | byte(channel.2)
        }
        var value = c6_render_style_t()
        value.background = rgb(p.background); value.card = rgb(p.card)
        value.inset = rgb(p.inset); value.border = rgb(p.border)
        value.accent = rgb(p.accent); value.secondary_accent = rgb(p.secondaryAccent)
        value.primary_text = rgb(p.primaryText); value.secondary_text = rgb(p.secondaryText)
        value.tertiary_text = rgb(p.tertiaryText); value.enabled = true
        return value
    }

    public static func clockFrame(now: Date, timeZone: TimeZone = .current,
                                  previous: Date? = nil, progress: Double = 1,
                                  style: C6ClockStyle = .flip, language: C6Language = .chinese,
                                  digitStyle: C6DigitStyle = .pixel, palette: ScreenPalette? = nil,
                                  saturationPercent: Int = 100, contrastPercent: Int = 100) -> Data {
        var current = clockValue(now, timeZone: timeZone)
        let old = previous.map { clockValue($0, timeZone: timeZone) }
        let fraction = UInt32((min(1, max(0, progress.isFinite ? progress : 1)) * 1000).rounded())
        var colors = portableStyle(palette)
        return render(language: language, digitStyle: digitStyle, saturationPercent: style == .rounded ? saturationPercent : 100,
                      contrastPercent: style == .rounded ? contrastPercent : 100) { renderer in
            if style == .rounded { c6_renderer_round_clock(renderer, &current, &colors); return }
            if var prior = old { c6_renderer_clock_smooth(renderer, &current, &prior, fraction, false) }
            else { c6_renderer_clock(renderer, &current, nil, 1000) }
        }
    }

    public static func clock(now: Date, timeZone: TimeZone = .current,
                             previous: Date? = nil, progress: Double = 1,
                             style: C6ClockStyle = .flip, language: C6Language = .chinese,
                             digitStyle: C6DigitStyle = .pixel, palette: ScreenPalette? = nil,
                             saturationPercent: Int = 100, contrastPercent: Int = 100) -> CGImage? {
        image(fromRGB565: clockFrame(now: now, timeZone: timeZone, previous: previous, progress: progress,
            style: style, language: language, digitStyle: digitStyle, palette: palette,
            saturationPercent: saturationPercent, contrastPercent: contrastPercent))
    }

    public static func image(fromRGB565 data: Data) -> CGImage? {
        guard data.count == frameBytes else { return nil }
        var rgb = Data(count: width * height * 3)
        data.withUnsafeBytes { input in
            rgb.withUnsafeMutableBytes { output in
                let bytes = input.bindMemory(to: UInt8.self); let pixels = output.bindMemory(to: UInt8.self)
                for n in 0..<(width * height) {
                    let value = (UInt16(bytes[n * 2]) << 8) | UInt16(bytes[n * 2 + 1])
                    pixels[n * 3] = UInt8((UInt32(value >> 11) * 255) / 31)
                    pixels[n * 3 + 1] = UInt8((UInt32((value >> 5) & 63) * 255) / 63)
                    pixels[n * 3 + 2] = UInt8((UInt32(value & 31) * 255) / 31)
                }
            }
        }
        guard let provider = CGDataProvider(data: rgb as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func render(language: C6Language = .chinese, digitStyle: C6DigitStyle = .pixel,
                               saturationPercent: Int = 100, contrastPercent: Int = 100,
                               _ draw: (UnsafeMutablePointer<c6_renderer_t>) -> Void) -> Data {
        var frame = Data(count: frameBytes)
        frame.withUnsafeMutableBytes { bytes in
            var renderer = c6_renderer_t()
            guard c6_renderer_init(&renderer, bytes.bindMemory(to: UInt8.self).baseAddress, frameBytes) else { return }
            renderer.english = language == .english
            renderer.smooth_digits = digitStyle == .aerospace
            draw(&renderer)
            c6_renderer_calibrate(&renderer, Int32(clamping: saturationPercent), Int32(clamping: contrastPercent))
        }
        return frame
    }

    private static func clockValue(_ date: Date, timeZone: TimeZone) -> c6_render_clock_t {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
        var value = c6_render_clock_t()
        value.year = Int32(c.year ?? 1970); value.month = Int32(c.month ?? 1); value.day = Int32(c.day ?? 1)
        value.weekday = Int32((c.weekday ?? 1) - 1); value.hour = Int32(c.hour ?? 0)
        value.minute = Int32(c.minute ?? 0); value.second = Int32(c.second ?? 0)
        return value
    }

    private final class Strings {
        private var pointers: [UnsafeMutablePointer<CChar>] = []
        private var pixels: [UnsafeMutablePointer<UInt8>] = []
        func picture(_ frame: C6TaskThumbnail.MediaFrame) -> c6_render_picture_t {
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: frame.bytes.count)
            frame.bytes.copyBytes(to: pointer, count: frame.bytes.count); pixels.append(pointer)
            return c6_render_picture_t(rgb565: UnsafePointer(pointer), width: UInt32(frame.width), height: UInt32(frame.height), stride: UInt32(frame.width * 2))
        }
        func add(_ string: String) -> UnsafePointer<CChar>? {
            guard let pointer = strdup(string) else { return nil }
            pointers.append(pointer); return UnsafePointer(pointer)
        }
        deinit { pointers.forEach { free($0) }; pixels.forEach { $0.deallocate() } }
    }
}
