import Foundation
import CoreGraphics
import ImageIO

/// Wire contract shared by the Mac configuration editor and the C6 firmware.
/// Credentials deliberately do not belong to this document.
public enum C6ClockStyle: Int, Codable, CaseIterable, Identifiable, Sendable {
    case flip = 0
    case rounded = 1
    public var id: Int { rawValue }
    public var title: String { self == .flip ? String(localized: "翻页钟") : String(localized: "圆角粗数字") }
}
public enum C6Language: Int, Codable, CaseIterable, Identifiable, Sendable {
    case chinese = 0, english = 1
    public var id: Int { rawValue }
    public var title: String { self == .chinese ? String(localized: "简体中文") : "English" }
}
public enum C6DigitStyle: Int, Codable, CaseIterable, Identifiable, Sendable {
    case pixel = 0, aerospace = 1
    public var id: Int { rawValue }
    public var title: String { self == .pixel ? String(localized: "像素数字") : String(localized: "航天圆角数字") }
}
public enum C6SleepMode: Int, Codable, CaseIterable, Identifiable, Sendable {
    case off = 0, idle = 1, schedule = 2
    public var id: Int { rawValue }
    public var title: String { switch self { case .off: return String(localized: "不自动休眠"); case .idle: return String(localized: "无操作后休眠"); case .schedule: return String(localized: "按时间段休眠") } }
}
public enum C6PrinterCardStyle: Int, Codable, CaseIterable, Identifiable, Sendable {
    case standard = 0, percentage = 1, remaining = 2
    public var id: Int { rawValue }
    public var title: String { switch self { case .standard: return String(localized: "标准 · 含任务图"); case .percentage: return String(localized: "超大百分比"); case .remaining: return String(localized: "超大剩余时间") } }
}
public struct C6HAEntity: Codable, Equatable, Sendable, Identifiable {
    public var id = ""
    public var name = ""
    public init(id: String = "", name: String = "") { self.id = id; self.name = name }
}
public struct C6HAConfiguration: Codable, Equatable, Sendable {
    public var enabled = false
    public var host = ""
    public var port = 8123
    public var tls = false
    public var tokenSet = false
    public var entities: [C6HAEntity] = []
    public init() {}
    enum CodingKeys: String, CodingKey { case enabled, host, port, tls, entities; case tokenSet = "token_set" }
}
/// Resolved classic palette. No device identity or glass-rendering claim is encoded.
public struct C6RenderTheme: Codable, Equatable, Sendable {
    public var enabled = false, dark = true
    public var background = 0x080B12, card = 0x111827, inset = 0x0B1220, border = 0x26344A
    public var accent = 0x55E6B8, secondaryAccent = 0x60A5FA
    public var primaryText = 0xF8FAFC, secondaryText = 0xB9C4D6, tertiaryText = 0x8A9AB0
    public init(enabled: Bool = false, dark: Bool = true, background: Int = 0x080B12,
                card: Int = 0x111827, inset: Int = 0x0B1220, border: Int = 0x26344A,
                accent: Int = 0x55E6B8, secondaryAccent: Int = 0x60A5FA,
                primaryText: Int = 0xF8FAFC, secondaryText: Int = 0xB9C4D6, tertiaryText: Int = 0x8A9AB0) {
        self.enabled = enabled; self.dark = dark; self.background = background; self.card = card
        self.inset = inset; self.border = border; self.accent = accent; self.secondaryAccent = secondaryAccent
        self.primaryText = primaryText; self.secondaryText = secondaryText; self.tertiaryText = tertiaryText
    }
    enum CodingKeys: String, CodingKey { case enabled, dark, background, card, inset, border, accent
        case secondaryAccent = "secondary_accent", primaryText = "primary_text", secondaryText = "secondary_text", tertiaryText = "tertiary_text" }
    public var isValid: Bool { [background, card, inset, border, accent, secondaryAccent, primaryText, secondaryText, tertiaryText].allSatisfy { (0...0xFFFFFF).contains($0) } }
    public init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false; dark = try c.decodeIfPresent(Bool.self, forKey: .dark) ?? true
        background = try c.decodeIfPresent(Int.self, forKey: .background) ?? background; card = try c.decodeIfPresent(Int.self, forKey: .card) ?? card
        inset = try c.decodeIfPresent(Int.self, forKey: .inset) ?? inset; border = try c.decodeIfPresent(Int.self, forKey: .border) ?? border
        accent = try c.decodeIfPresent(Int.self, forKey: .accent) ?? accent; secondaryAccent = try c.decodeIfPresent(Int.self, forKey: .secondaryAccent) ?? secondaryAccent
        primaryText = try c.decodeIfPresent(Int.self, forKey: .primaryText) ?? primaryText; secondaryText = try c.decodeIfPresent(Int.self, forKey: .secondaryText) ?? secondaryText
        tertiaryText = try c.decodeIfPresent(Int.self, forKey: .tertiaryText) ?? tertiaryText
    }
}
public struct C6PrinterConfiguration: Codable, Equatable, Sendable {
    public var enabled = true
    public var rotate = true
    public var host = ""
    public var serial = ""
    public var name = ""
    public var trustLAN = false
    public var certificate = ""
    public var accessCodeSet = false
    public var sourceHA = false
    /// Formlabs Dashboard client-credentials API; credentials are sent separately.
    public var sourceFormlabs = false, formCredentialsSet = false
    public var formClientID = ""
    public var showLayers = true, showMaterial = true
    public var statusEntity = "", progressEntity = "", taskEntity = "", remainingEntity = "", imageEntity = ""
    public var showStatus = true, showProgress = true, showTask = true, showRemaining = true, showImage = true
    public var showNozzle = false, showBed = false, showError = false
    /// Image-domain camera snapshots also need periodic sampling, unlike task covers.
    public var liveImage = false
    public var taskCoverEntity = ""
    public var nozzleEntity = "", bedEntity = "", errorEntity = "", endTimeEntity = ""
    /// 0: remaining duration; 1: expected finish (HA timestamp or remaining-time fallback).
    public var timeMode = 0
    public var cardStyle: C6PrinterCardStyle = .standard
    public var brandAccent = true
    public var brand: String { sourceFormlabs ? "formlabs" : "bambu" }
    public var brandName: String { sourceFormlabs ? "Formlabs" : "Bambu Lab" }
    public var source: String { sourceFormlabs ? "formlabs" : sourceHA ? "ha" : "mqtt" }
    /// Display names are never identifiers. Accounts/origins isolate transient secrets.
    public var identity: String { brand + "|" + serial }
    public var credentialKey: String { identity + "|" + source + "|" + (sourceFormlabs ? formClientID : host) }
    public init() {}
    enum CodingKeys: String, CodingKey { case enabled, rotate, host, serial, name, certificate; case trustLAN = "trust_lan"; case accessCodeSet = "access_code_set"; case sourceHA = "source_ha"; case statusEntity = "status_entity"; case progressEntity = "progress_entity"; case taskEntity = "task_entity"; case remainingEntity = "remaining_entity"; case imageEntity = "image_entity"; case showStatus = "show_status"; case showProgress = "show_progress"; case showTask = "show_task"; case showRemaining = "show_remaining"; case showImage = "show_image"
        case showNozzle = "show_nozzle", showBed = "show_bed", showError = "show_error", nozzleEntity = "nozzle_entity", bedEntity = "bed_entity", errorEntity = "error_entity", endTimeEntity = "end_time_entity", timeMode = "time_mode", brandAccent = "brand_accent", liveImage = "live_image"
        case sourceFormlabs = "source_formlabs", formCredentialsSet = "form_credentials_set", formClientID = "form_client_id", showLayers = "show_layers", showMaterial = "show_material", taskCoverEntity = "task_cover_entity", cardStyle = "card_style" }
    public init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
        rotate = try c.decodeIfPresent(Bool.self, forKey: .rotate) ?? true
        enabled = try c.decode(Bool.self, forKey: .enabled); host = try c.decode(String.self, forKey: .host)
        serial = try c.decode(String.self, forKey: .serial); name = try c.decode(String.self, forKey: .name)
        certificate = try c.decode(String.self, forKey: .certificate); trustLAN = try c.decode(Bool.self, forKey: .trustLAN)
        accessCodeSet = try c.decodeIfPresent(Bool.self, forKey: .accessCodeSet) ?? false
        sourceHA = try c.decodeIfPresent(Bool.self, forKey: .sourceHA) ?? false
        sourceFormlabs = try c.decodeIfPresent(Bool.self, forKey: .sourceFormlabs) ?? false
        formCredentialsSet = try c.decodeIfPresent(Bool.self, forKey: .formCredentialsSet) ?? false
        formClientID = try c.decodeIfPresent(String.self, forKey: .formClientID) ?? ""
        showLayers = try c.decodeIfPresent(Bool.self, forKey: .showLayers) ?? true
        showMaterial = try c.decodeIfPresent(Bool.self, forKey: .showMaterial) ?? true
        statusEntity = try c.decodeIfPresent(String.self, forKey: .statusEntity) ?? ""
        progressEntity = try c.decodeIfPresent(String.self, forKey: .progressEntity) ?? ""
        taskEntity = try c.decodeIfPresent(String.self, forKey: .taskEntity) ?? ""
        remainingEntity = try c.decodeIfPresent(String.self, forKey: .remainingEntity) ?? ""
        imageEntity = try c.decodeIfPresent(String.self, forKey: .imageEntity) ?? ""
        taskCoverEntity = try c.decodeIfPresent(String.self, forKey: .taskCoverEntity) ?? ""
        liveImage = try c.decodeIfPresent(Bool.self, forKey: .liveImage) ?? imageEntity.hasPrefix("camera.")
        showStatus = try c.decodeIfPresent(Bool.self, forKey: .showStatus) ?? true
        showProgress = try c.decodeIfPresent(Bool.self, forKey: .showProgress) ?? true
        showTask = try c.decodeIfPresent(Bool.self, forKey: .showTask) ?? true
        showRemaining = try c.decodeIfPresent(Bool.self, forKey: .showRemaining) ?? true
        showImage = try c.decodeIfPresent(Bool.self, forKey: .showImage) ?? true
        showNozzle = try c.decodeIfPresent(Bool.self, forKey: .showNozzle) ?? false; showBed = try c.decodeIfPresent(Bool.self, forKey: .showBed) ?? false; showError = try c.decodeIfPresent(Bool.self, forKey: .showError) ?? false
        nozzleEntity = try c.decodeIfPresent(String.self, forKey: .nozzleEntity) ?? ""; bedEntity = try c.decodeIfPresent(String.self, forKey: .bedEntity) ?? ""
        errorEntity = try c.decodeIfPresent(String.self, forKey: .errorEntity) ?? ""; endTimeEntity = try c.decodeIfPresent(String.self, forKey: .endTimeEntity) ?? ""
        timeMode = try c.decodeIfPresent(Int.self, forKey: .timeMode) ?? 0
        cardStyle = try c.decodeIfPresent(C6PrinterCardStyle.self, forKey: .cardStyle) ?? .standard
        brandAccent = try c.decodeIfPresent(Bool.self, forKey: .brandAccent) ?? true
    }
}
public struct C6StandaloneConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var revision = 0
    public var enabled = false
    public var rotation = 0
    public var cardMask = 15
    public var brightness = 80
    public var interval = 15
    public var timezone = TimeZone.current.secondsFromGMT()
    public var clock = true
    public var diagnostics = true
    public var flipAnimation = true
    public var clockStyle: C6ClockStyle = .flip
    public var language: C6Language = .chinese
    public var digitStyle: C6DigitStyle = .pixel
    public var sleepMode: C6SleepMode = .off
    public var idleSleepMinutes = 5, sleepStartMinute = 1380, sleepEndMinute = 420
    public var keepPrintingAwake = true
    public var saturationPercent = 100, contrastPercent = 100
    public var localFirst = false
    public var theme = C6RenderTheme()
    public var ha = C6HAConfiguration()
    public var printers: [C6PrinterConfiguration] = []
    public var weather = false
    public var latitude = 0.0, longitude = 0.0
    public var weatherCity = ""
    public var weatherMinutes = 30
    public init() {}
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case cardMask = "card_mask"
        case revision, enabled, rotation, brightness, interval, timezone, clock, diagnostics, ha, printers, weather, latitude, longitude, theme
        case weatherCity = "weather_city"
        case weatherMinutes = "weather_minutes"
        case localFirst = "local_first"
        case flipAnimation = "flip_animation"
        case clockStyle = "clock_style"
        case language, digitStyle = "digit_style", sleepMode = "sleep_mode"
        case idleSleepMinutes = "sleep_idle_minutes", sleepStartMinute = "sleep_start", sleepEndMinute = "sleep_end", keepPrintingAwake = "sleep_keep_printing"
        case saturationPercent = "saturation_percent"
        case contrastPercent = "contrast_percent"
    }
    public var isValid: Bool {
        guard (0...15).contains(cardMask), schemaVersion == 2, revision >= 0, [0, 90, 180, 270].contains(rotation), theme.isValid,
              (1...120).contains(idleSleepMinutes), (0...1439).contains(sleepStartMinute), (0...1439).contains(sleepEndMinute) else { return false }
        guard sleepMode != .schedule || sleepStartMinute != sleepEndMinute else { return false }
        guard (50...200).contains(saturationPercent), (75...150).contains(contrastPercent),
              (0...100).contains(brightness), (5...300).contains(interval), (-43200...50400).contains(timezone) else { return false }
        guard ha.entities.count <= 6, Set(ha.entities.map(\.id)).count == ha.entities.count,
              ha.entities.allSatisfy({ Self.validEntityID($0.id) && $0.name.utf8.count < 64 }),
              (1...65535).contains(ha.port), !ha.enabled || Self.privateIP(ha.host) else { return false }
        guard printers.count <= 3, Set(printers.map(\.identity)).count == printers.count else { return false }
        for p in printers {
            guard p.name.utf8.count < 64, p.certificate.utf8.count < 2048, p.serial.utf8.count < 40,
                  !p.serial.isEmpty, !(p.sourceHA && p.sourceFormlabs), p.formClientID.utf8.count < 128 else { return false }
            guard p.serial.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || (p.sourceFormlabs && $0 == "-")) }) else { return false }
            let fields = [p.statusEntity, p.progressEntity, p.taskEntity, p.remainingEntity,
                          p.nozzleEntity, p.bedEntity, p.errorEntity, p.endTimeEntity]
            guard fields.allSatisfy({ $0.isEmpty || Self.validEntityID($0) }), [0, 1].contains(p.timeMode) else { return false }
            if !p.imageEntity.isEmpty {
                guard p.imageEntity.hasPrefix("image.") || p.imageEntity.hasPrefix("camera."), Self.validEntityID(p.imageEntity) else { return false }
            }
            if !p.taskCoverEntity.isEmpty {
                guard p.taskCoverEntity.hasPrefix("image."), Self.validEntityID(p.taskCoverEntity) else { return false }
            }
            if !p.enabled { continue }
            if p.sourceFormlabs { guard !p.formClientID.isEmpty else { return false } }
            else if p.sourceHA { guard ha.enabled, Self.validEntityID(p.statusEntity) else { return false } }
            else { guard Self.privateIP(p.host), p.trustLAN || p.certificate.contains("BEGIN CERTIFICATE") else { return false } }
        }
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude),
              weatherCity.utf8.count < 64, (15...180).contains(weatherMinutes) else { return false }
        return !enabled || clock || diagnostics || (ha.enabled && !ha.entities.isEmpty) || printers.contains(where: \.enabled) || weather
    }
    public static func privateIP(_ host: String) -> Bool { (try? C6StandaloneClient(host: host)) != nil }
    public static func validEntityID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && value.utf8.count < 128
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }
    }
    public init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decode(Int.self, forKey: .schemaVersion)
        guard [1, 2].contains(schema) else { throw C6StandaloneError.unsupported }
        schemaVersion = schema
        revision = try c.decode(Int.self, forKey: .revision); enabled = try c.decode(Bool.self, forKey: .enabled)
        rotation = try c.decode(Int.self, forKey: .rotation); brightness = try c.decode(Int.self, forKey: .brightness)
        interval = try c.decode(Int.self, forKey: .interval); timezone = try c.decode(Int.self, forKey: .timezone)
        clock = try c.decode(Bool.self, forKey: .clock); diagnostics = try c.decode(Bool.self, forKey: .diagnostics)
        cardMask = try c.decodeIfPresent(Int.self, forKey: .cardMask) ?? 15
        flipAnimation = try c.decodeIfPresent(Bool.self, forKey: .flipAnimation) ?? true
        clockStyle = try c.decodeIfPresent(C6ClockStyle.self, forKey: .clockStyle) ?? .flip
        language = try c.decodeIfPresent(C6Language.self, forKey: .language) ?? .chinese
        digitStyle = try c.decodeIfPresent(C6DigitStyle.self, forKey: .digitStyle) ?? .pixel
        sleepMode = try c.decodeIfPresent(C6SleepMode.self, forKey: .sleepMode) ?? .off
        idleSleepMinutes = try c.decodeIfPresent(Int.self, forKey: .idleSleepMinutes) ?? 5
        sleepStartMinute = try c.decodeIfPresent(Int.self, forKey: .sleepStartMinute) ?? 1380
        sleepEndMinute = try c.decodeIfPresent(Int.self, forKey: .sleepEndMinute) ?? 420
        keepPrintingAwake = try c.decodeIfPresent(Bool.self, forKey: .keepPrintingAwake) ?? true
        saturationPercent = try c.decodeIfPresent(Int.self, forKey: .saturationPercent) ?? 100
        contrastPercent = try c.decodeIfPresent(Int.self, forKey: .contrastPercent) ?? 100
        localFirst = try c.decodeIfPresent(Bool.self, forKey: .localFirst) ?? false
        theme = try c.decodeIfPresent(C6RenderTheme.self, forKey: .theme) ?? .init()
        ha = try c.decodeIfPresent(C6HAConfiguration.self, forKey: .ha) ?? .init()
        printers = try c.decodeIfPresent([C6PrinterConfiguration].self, forKey: .printers) ?? []
        weather = try c.decodeIfPresent(Bool.self, forKey: .weather) ?? false
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude) ?? 0
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude) ?? 0
        weatherCity = try c.decodeIfPresent(String.self, forKey: .weatherCity) ?? ""
        weatherMinutes = try c.decodeIfPresent(Int.self, forKey: .weatherMinutes) ?? 30
    }
}

/// Transient input only: never persisted in the Mac device/settings snapshot or returned by GET.
public struct C6Credentials: Sendable {
    public var haToken = ""
    public var printerAccessCodes: [String: String] = [:]
    public var formClientSecrets: [String: String] = [:]
    public init() {}
}

/// Feature negotiation is independent of firmware version labels. Older C6
/// builds keep their schema2 defaults, but must not silently discard new choices.
public struct C6StandaloneCapabilities: Equatable, Sendable {
    public var uiOptions = false
    public var rotations = [0, 180], languages = [0], digitStyles = [0], sleepModes = [0], printerCardStyles = [0]
    public var printerOverview = false
    public init() {}
    public static func fromInfo(_ data: Data) throws -> Self {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["device"] as? String == "lingxi-esp32-c6-screen" else { throw C6StandaloneError.unsupported }
        var value = Self()
        value.uiOptions = json["ui_options"] as? Bool ?? false
        value.rotations = json["rotations"] as? [Int] ?? [0, 180]
        value.languages = json["languages"] as? [Int] ?? [0]
        value.digitStyles = json["digit_styles"] as? [Int] ?? [0]
        value.sleepModes = json["sleep_modes"] as? [Int] ?? [0]
        value.printerCardStyles = json["printer_card_styles"] as? [Int] ?? [0]
        value.printerOverview = json["printer_overview"] as? Bool ?? false
        return value
    }
    public func supports(_ configuration: C6StandaloneConfiguration) -> Bool {
        guard rotations.contains(configuration.rotation), languages.contains(configuration.language.rawValue),
              digitStyles.contains(configuration.digitStyle.rawValue),
              sleepModes.contains(configuration.sleepMode.rawValue),
              configuration.printers.allSatisfy({ printerCardStyles.contains($0.cardStyle.rawValue) }) else { return false }
        return uiOptions || (configuration.sleepMode == .off && configuration.idleSleepMinutes == 5
            && configuration.sleepStartMinute == 1380 && configuration.sleepEndMinute == 420 && configuration.keepPrintingAwake)
    }
}

/// Static task covers only. MQTT reports do not themselves contain image bytes.
public enum C6TaskThumbnail {
    public static let maximumEdge = 80
    /// Hashes the exact UTF-8 state, not the display name; identical to the firmware.
    public static func taskKey(source: String, value: String) -> String? {
        guard !value.isEmpty, value != "unknown", value != "unavailable" else { return nil }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (source + ":" + value).utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(format: "%016llx", hash)
    }
    public static func homeAssistantTaskKey(_ rawState: String) -> String? { taskKey(source: "ha", value: rawState) }
    public static func formlabsTaskKey(runID: String?, name: String) -> String? {
        taskKey(source: "formlabs", value: runID?.isEmpty == false ? runID! : name)
    }
    public struct MediaFrame: Sendable { public let bytes: Data; public let width, height: Int }
    /// Preserve aspect ratio. Fit vs fill belongs to the final card layout.
    public static func encodeMedia(from imageData: Data) -> MediaFrame? {
        guard !imageData.isEmpty, imageData.count <= 2_000_000,
              let source = CGImageSourceCreateWithData(imageData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumEdge, kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), image.width > 0, image.height > 0, image.width <= maximumEdge, image.height <= maximumEdge,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let success = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let c = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Bitmap-context rows already match CGImage's canonical top-first
            // storage. A UIKit-style transform would invert uploaded pictures.
            c.interpolationQuality = .high; c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard success else { return nil }
        var result = Data(count: w * h * 2)
        result.withUnsafeMutableBytes { bytes in
            let out = bytes.bindMemory(to: UInt8.self)
            for i in 0..<w*h { let pixel = (UInt16(rgba[i*4] & 0xf8) << 8) | (UInt16(rgba[i*4+1] & 0xfc) << 3) | UInt16(rgba[i*4+2] >> 3)
                out[i*2] = UInt8(pixel >> 8); out[i*2+1] = UInt8(pixel & 255) }
        }
        return MediaFrame(bytes: result, width: w, height: h)
    }
    public static func mqttTaskKey(fields: [String: String]) -> String? {
        for field in ["subtask_id", "task_id", "gcode_file", "subtask_name"] {
            if let value = fields[field], !value.isEmpty,
               (!["subtask_id", "task_id"].contains(field) || value != "0"),
               let key = taskKey(source: field, value: value) { return key }
        }
        return nil
    }
    public static func validTaskKey(_ key: String) -> Bool {
        key.utf8.count == 16 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    /// OS thumbnail decoding avoids allocating a full-size print-cover bitmap.
    /// Aspect-fit black letterboxing matches the C6's direct JPEG decoder.
    public static func encodeThumbnail(from imageData: Data) -> Data? {
        guard !imageData.isEmpty, imageData.count <= 2_000_000,
              let source = CGImageSourceCreateWithData(imageData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), image.width > 0, image.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: maximumEdge * maximumEdge * 4)
        let scale = min(Double(maximumEdge) / Double(image.width), Double(maximumEdge) / Double(image.height))
        let width = max(1, floor(Double(image.width) * scale)), height = max(1, floor(Double(image.height) * scale))
        let success = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: maximumEdge, height: maximumEdge,
                bitsPerComponent: 8, bytesPerRow: maximumEdge * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: maximumEdge, height: maximumEdge))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: floor((Double(maximumEdge) - width) / 2),
                y: floor((Double(maximumEdge) - height) / 2), width: width, height: height))
            return true
        }
        guard success else { return nil }
        var result = Data(); result.reserveCapacity(maximumEdge * maximumEdge * 2)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let color = (UInt16(rgba[offset] & 0xf8) << 8) | (UInt16(rgba[offset + 1] & 0xfc) << 3) | UInt16(rgba[offset + 2] >> 3)
            result.append(UInt8(color >> 8)); result.append(UInt8(color & 255))
        }
        return result
    }
}

public enum C6StandaloneError: LocalizedError, Equatable {
    case address, invalidConfiguration, unsupported, upgradeRequired, unauthorized, conflict, response(Int)
    case invalidPIN, incorrectPIN, pairingNotOpen, pairingExpired, pairingLocked, invalidPairingResponse
    case configurationSave(String)
    public var errorDescription: String? {
        switch self {
        case .address: return "请输入设备的局域网 IP 地址。"
        case .invalidConfiguration: return "请检查局域网地址、实体与打印机设置；独立运行至少需要一个页面。"
        case .unsupported: return "设备尚未安装支持独立模式的 2.0 测试固件。"
        case .upgradeRequired: return "当前 C6 固件不支持所选语言、数字样式、休眠或屏幕方向；请在设备管理中更新内置固件后重试。"
        case .unauthorized: return "设备连接已失效，请在同一局域网重新连接并读取配置。"
        case .conflict: return "配置已在其他入口修改，请重新读取后再保存。"
        case .response(let status): return "设备返回错误（\(status)）。"
        case .configurationSave(let reason):
            switch reason {
            case "low_memory": return "设备内存不足，未保存配置（500）；请稍后重试。"
            case "storage_full": return "设备配置存储空间不足，未保存配置（500）；原配置保留。"
            case "storage_size": return "设备无法保存较大的配置（500）；请更新 C6 固件后重试。"
            default: return "设备配置写入失败（500）；原配置保留，请更新固件后重试。"
            }
        case .invalidPIN: return "请输入设备屏幕上的 4 位数字 PIN 码。"
        case .incorrectPIN: return "PIN 码不正确，请核对设备屏幕上的 4 位数字。"
        case .pairingNotOpen: return "请先长按设备 BOOT 键，打开 PIN 配对窗口。"
        case .pairingExpired: return "PIN 码已过期，请长按设备 BOOT 键获取新 PIN 码。"
        case .pairingLocked: return "PIN 码尝试次数过多，请长按设备 BOOT 键重新配对。"
        case .invalidPairingResponse: return "设备未返回有效授权，请更新 C6 固件后重新配对。"
        }
    }
}

public struct C6StandaloneClient: Sendable {
    public let baseURL: URL
    #if C6_TRANSPORT_CONTRACT_TEST
    // Available only to the isolated transport harness; never in the app.
    init(testingBaseURL: URL) { self.baseURL = testingBaseURL }
    #endif
    public init(host: String) throws {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ p in
            !p.isEmpty && p.allSatisfy({ $0.isASCII && $0.isNumber })
            && UInt8(p) != nil
        }), let url = URL(string: "http://\(value)") else { throw C6StandaloneError.address }
        // LAN-only test transport; never send this configuration to Internet hosts.
        let first = Int(parts[0])!, second = Int(parts[1])!
        guard first == 10 || (first == 192 && second == 168)
            || (first == 172 && (16...31).contains(second)) else { throw C6StandaloneError.address }
        baseURL = url
    }
    /// A short, single-use code only opens pairing; subsequent requests still use a long secret.
    /// Do not normalize Unicode digits or trim the input, so leading zeroes remain unambiguous.
    public static func validPIN(_ pin: String) -> Bool {
        pin.utf8.count == 4 && pin.utf8.allSatisfy { (48...57).contains($0) }
    }
    public func connectLAN() async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pair")); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Lingxi-LAN")
        request.httpBody = Data("{\"mode\":\"lan\"}".utf8)
        request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 8
        let (data, status) = try await Self.exchange(request)
        guard status == 200 else { throw C6StandaloneError.response(status) }
        return try Self.pairingToken(from: data, status: status)
    }
    public func pair(pin: String) async throws -> String {
        guard Self.validPIN(pin) else { throw C6StandaloneError.invalidPIN }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pair"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["pin": pin])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        let (data, status) = try await Self.exchange(request)
        return try Self.pairingToken(from: data, status: status)
    }
    /// Kept separate from transport so the firmware response contract can be regression-tested.
    public static func pairingToken(from data: Data, status: Int) throws -> String {
        switch status {
        case 200:
            struct PairingResponse: Decodable { let token: String }
            guard let response = try? JSONDecoder().decode(PairingResponse.self, from: data),
                  response.token.utf8.count == 16,
                  response.token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw C6StandaloneError.invalidPairingResponse
            }
            return response.token
        case 400: throw C6StandaloneError.invalidPIN
        case 401: throw C6StandaloneError.incorrectPIN
        case 403: throw C6StandaloneError.pairingNotOpen
        case 404: throw C6StandaloneError.unsupported
        case 410: throw C6StandaloneError.pairingExpired
        case 423, 429: throw C6StandaloneError.pairingLocked
        default: throw C6StandaloneError.response(status)
        }
    }
    public func read(token: String) async throws -> C6StandaloneConfiguration {
        try JSONDecoder().decode(C6StandaloneConfiguration.self, from: await request(token: token, config: nil))
    }
    public func capabilities(token: String) async throws -> C6StandaloneCapabilities {
        try C6StandaloneCapabilities.fromInfo(await transfer(token: token, path: "api/info", method: "GET"))
    }
    public func ensureSupports(_ configuration: C6StandaloneConfiguration, token: String) async throws {
        guard try await capabilities(token: token).supports(configuration) else { throw C6StandaloneError.upgradeRequired }
    }
    public func save(_ config: C6StandaloneConfiguration, token: String, credentials: C6Credentials = .init()) async throws -> C6StandaloneConfiguration {
        return try JSONDecoder().decode(C6StandaloneConfiguration.self, from: await transfer(token: token, path: "api/standalone", method: "PUT", body: Self.configurationPayload(config, credentials: credentials)))
    }
    public static func configurationPayload(_ config: C6StandaloneConfiguration, credentials: C6Credentials = .init()) throws -> Data {
        guard config.isValid else { throw C6StandaloneError.invalidConfiguration }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
        if !credentials.haToken.isEmpty {
            guard credentials.haToken.utf8.count < 1024 else { throw C6StandaloneError.invalidConfiguration }
            var ha = object["ha"] as! [String: Any]; ha["token"] = credentials.haToken; object["ha"] = ha
        }
        var printers = object["printers"] as! [[String: Any]]
        for index in printers.indices {
            let p = config.printers[index]
            printers[index]["brand"] = p.brand
            if p.sourceFormlabs,
               let secret = credentials.formClientSecrets[p.credentialKey], !secret.isEmpty {
                guard secret.utf8.count < 256 else { throw C6StandaloneError.invalidConfiguration }
                printers[index]["form_client_secret"] = secret
            }
            if !p.sourceHA && !p.sourceFormlabs,
               let code = credentials.printerAccessCodes[p.credentialKey], !code.isEmpty {
                guard code.utf8.count < 32 else { throw C6StandaloneError.invalidConfiguration }
                printers[index]["access_code"] = code
            }
        }
        object["printers"] = printers
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func request(token: String, config: C6StandaloneConfiguration?) async throws -> Data {
        try await transfer(token: token, path: "api/standalone", method: "GET")
    }
    public func health(token: String) async throws -> Data { try await transfer(token: token, path: "api/health", method: "GET") }
    /// Authenticated, bounded handoff on normal quit. A crash still uses lease expiry.
    public func releaseSoftwareControl(token: String) async throws {
        _ = try await transfer(token: token, path: "api/software", method: "POST",
                               body: JSONSerialization.data(withJSONObject: ["action": "release"]), timeout: 1.8)
    }
    /// Only releases this device's software ownership; local subscriptions keep running.
    public func simulateSoftwareOffline(_ enabled: Bool, token: String) async throws {
        _ = try await transfer(token: token, path: "api/simulation", method: "POST",
                               body: JSONSerialization.data(withJSONObject: ["enabled": enabled]))
    }
    /// A missing/disabled native counterpart falls back to the Mac image (404).
    /// Menus pause selection without changing the visible card (204).
    public func selectNativeCard(token: String, headers: [String: String], explicitNative: Bool = false) async throws -> Int {
        guard token.utf8.count == 16, token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw C6StandaloneError.unauthorized
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/card"))
        request.httpMethod = "POST"; request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (key, value) in headers where key.hasPrefix("X-Lingxi-") {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Version 2 requests select native playlist members regardless of the
        // preferred data source. Callers cannot accidentally opt in via headers.
        request.setValue(explicitNative ? "1" : nil, forHTTPHeaderField: "X-Lingxi-Native")
        let (_, status) = try await Self.exchange(request)
        if status == 401 { throw C6StandaloneError.unauthorized }
        guard [200, 204, 404].contains(status) else { throw C6StandaloneError.response(status) }
        return status
    }

    /// Reads the actual canonical framebuffer without renewing the software lease.
    public func previewFrame(token: String) async throws -> Data {
        let bytes = try await transfer(token: token, path: "api/frame", method: "GET", timeout: 4)
        guard bytes.count == 240 * 240 * 2 else { throw C6StandaloneError.response(0) }
        return bytes
    }
    public func updateFirmware(_ data: Data, token: String, sha256: String) async throws {
        _ = try await transfer(token: token, path: "api/ota", method: "POST", body: data,
                               headers: ["X-Firmware-SHA256": sha256], timeout: 120)
    }
    /// Upload a bounded, task-keyed cover after configuration is synchronized.
    /// The device validates revision, enabled printer serial, and current task twice.
    public func uploadThumbnail(rgb565: Data, width: Int, height: Int, serial: String,
                                taskKey: String, revision: Int, token: String) async throws {
        let headers = try Self.thumbnailHeaders(width: width, height: height, serial: serial,
                                                taskKey: taskKey, revision: revision, byteCount: rgb565.count)
        _ = try await transfer(token: token, path: "api/thumbnail", method: "POST", body: rgb565,
                               headers: headers, timeout: 12)
    }
    public func uploadMedia(_ frame: C6TaskThumbnail.MediaFrame, serial: String = "", entityID: String = "",
                            brand: String = "", source: String = "", cover: Bool = false, taskKey: String, revision: Int, token: String) async throws {
        guard entityID.isEmpty || (C6StandaloneConfiguration.validEntityID(entityID)
            && (entityID.hasPrefix("camera.") || entityID.hasPrefix("image.")) && !cover) else { throw C6StandaloneError.invalidConfiguration }
        var headers = try Self.thumbnailHeaders(width: frame.width, height: frame.height, serial: entityID.isEmpty ? serial : "entity",
            taskKey: taskKey, revision: revision, byteCount: frame.bytes.count)
        if !entityID.isEmpty { headers.removeValue(forKey: "X-Printer-Serial"); headers["X-Entity-ID"] = entityID }
        if entityID.isEmpty && (!brand.isEmpty || !source.isEmpty) {
            guard (brand == "formlabs" && source == "formlabs") || (brand == "bambu" && ["ha", "mqtt"].contains(source)) else { throw C6StandaloneError.invalidConfiguration }
            headers["X-Printer-Brand"] = brand; headers["X-Printer-Source"] = source
        }
        if cover { headers["X-Media-Role"] = "cover" }
        _ = try await transfer(token: token, path: "api/thumbnail", method: "POST", body: frame.bytes, headers: headers, timeout: 12)
    }
    public static func thumbnailHeaders(width: Int, height: Int, serial: String, taskKey: String,
                                        revision: Int, byteCount: Int) throws -> [String: String] {
        guard (1...C6TaskThumbnail.maximumEdge).contains(width), (1...C6TaskThumbnail.maximumEdge).contains(height),
              byteCount == width * height * 2, revision >= 0, revision < Int(Int32.max),
              !serial.isEmpty, serial.utf8.count < 40,
              serial.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }),
              C6TaskThumbnail.validTaskKey(taskKey) else { throw C6StandaloneError.invalidConfiguration }
        return ["Content-Type": "application/octet-stream", "X-Config-Revision": String(revision),
                "X-Printer-Serial": serial, "X-Task-Key": taskKey,
                "X-Thumbnail-Width": String(width), "X-Thumbnail-Height": String(height)]
    }
    private func transfer(token: String, path: String, method: String, body: Data? = nil, headers: [String: String] = [:], timeout: TimeInterval = 8) async throws -> Data {
        guard token.utf8.count == 16, token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw C6StandaloneError.unauthorized }
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpMethod = method; req.httpBody = body
        req.setValue(path == "api/ota" ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        let (data, status) = try await Self.exchange(req)
        switch status {
        case 200: return data
        case 401: throw C6StandaloneError.unauthorized
        case 409: throw C6StandaloneError.conflict
        case 404: throw C6StandaloneError.unsupported
        case 500:
            if path == "api/standalone", method == "PUT" {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let reason = object?["reason"] as? String ?? "storage_error"
                throw C6StandaloneError.configurationSave(["low_memory", "storage_full", "storage_size"].contains(reason) ? reason : "storage_error")
            }
            throw C6StandaloneError.response(status)
        default: throw C6StandaloneError.response(status)
        }
    }
    private static func exchange(_ request: URLRequest) async throws -> (Data, Int) {
        let sessionConfig = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: sessionConfig, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw C6StandaloneError.response(0) }
        return (data, http.statusCode)
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
