import Foundation
import CryptoKit

/// A desktop playlist may point at either a generated image or a device renderer.
/// This intentionally does not add a case to the legacy AI Mac content-mode enum.
public enum C6MergedCardTarget: Equatable, Hashable {
    case software(DisplayMode)
    case native(String)

    public var id: String {
        switch self {
        case .software(let mode): return "software:\(mode.rawValue)"
        case .native(let id): return "native:\(id)"
        }
    }
}

public struct C6NativeCard: Identifiable, Equatable {
    public var id: String
    public var kind: String
    public var title: String
    public var icon: String
    public var headers: [String: String]
    public var displayMode: DisplayMode?
    public var defaultVisible: Bool
    public var defaultParticipatesInRotation: Bool

    public init(id: String, kind: String, title: String, icon: String,
                headers: [String: String] = [:], displayMode: DisplayMode? = nil,
                defaultVisible: Bool = true, defaultParticipatesInRotation: Bool = true) {
        self.id = id; self.kind = kind; self.title = title; self.icon = icon
        self.headers = headers; self.displayMode = displayMode
        self.defaultVisible = defaultVisible
        self.defaultParticipatesInRotation = defaultParticipatesInRotation
    }
}

public struct C6CardDescriptor: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var icon: String
    public var sourceTitle: String
    public var displayMode: DisplayMode?
    public var nativeCard: C6NativeCard?
    public var visible: Bool
    public var participatesInRotation: Bool
    public var target: C6MergedCardTarget {
        nativeCard.map { .native($0.id) } ?? .software(displayMode ?? .systemMonitor)
    }

    public init(id: String, title: String, icon: String, sourceTitle: String,
                displayMode: DisplayMode? = nil, nativeCard: C6NativeCard? = nil,
                visible: Bool, participatesInRotation: Bool) {
        self.id = id; self.title = title; self.icon = icon; self.sourceTitle = sourceTitle
        self.displayMode = displayMode; self.nativeCard = nativeCard
        self.visible = visible; self.participatesInRotation = participatesInRotation
    }
}

public enum C6MergedCardPolicy {
    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Same wire representation as the firmware's X-Lingxi-Origin comparison.
    public static func homeAssistantOrigin(_ config: C6StandaloneConfiguration) -> String {
        "\(config.ha.host):\(config.ha.port):\(config.ha.tls ? 1 : 0)"
    }
    public static func printerOrigin(_ printer: C6PrinterConfiguration,
                                     configuration: C6StandaloneConfiguration) -> String {
        if printer.sourceFormlabs { return printer.formClientID }
        if printer.sourceHA { return homeAssistantOrigin(configuration) }
        return printer.host
    }
    public static func printerIdentity(_ printer: C6PrinterConfiguration,
                                       configuration: C6StandaloneConfiguration) -> String {
        [printer.brand, printer.source, printer.serial,
         printerOrigin(printer, configuration: configuration)].joined(separator: "|")
    }
    private static func validNativePrinter(_ printer: C6PrinterConfiguration,
                                           configuration: C6StandaloneConfiguration) -> Bool {
        guard !printer.serial.isEmpty, printer.serial.utf8.count < 40,
              !(printer.sourceHA && printer.sourceFormlabs),
              printer.serial.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || (printer.sourceFormlabs && $0 == "-")) }) else { return false }
        if printer.sourceFormlabs {
            return !printer.formClientID.isEmpty && printer.formClientID.utf8.count < 128
                && !printer.formClientID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
        if printer.sourceHA {
            return C6StandaloneConfiguration.privateIP(configuration.ha.host) && (1...65535).contains(configuration.ha.port)
        }
        return C6StandaloneConfiguration.privateIP(printer.host)
    }

    /// The catalogue contains configured local capabilities, not their display
    /// names as identity. Clock and diagnostics remain available to enable later.
    public static func nativeCards(configuration c: C6StandaloneConfiguration,
                                   printerDisplayModes: [String: DisplayMode] = [:]) -> [C6NativeCard] {
        func card(_ id: String, _ kind: String, _ title: String, _ icon: String,
                  mode: DisplayMode? = nil, visible: Bool,
                  headers: [String: String] = [:]) -> C6NativeCard {
            var headers = headers
            headers["X-Lingxi-Card"] = kind
            headers["X-Lingxi-Native"] = "1"
            return C6NativeCard(id: id, kind: kind, title: title, icon: icon,
                                headers: headers, displayMode: mode,
                                defaultVisible: visible, defaultParticipatesInRotation: visible)
        }
        var cards = [
            card("clock", "clock", "桌面时钟", "clock", mode: .aiMacClock,
                 visible: c.clock && c.cardMask & 1 != 0),
            card("diagnostics", "diagnostics", "设备状态", "cpu",
                 visible: c.diagnostics && c.cardMask & 2 != 0)
        ]
        if c.weather || !c.weatherCity.isEmpty {
            cards.append(card("weather", "weather", "天气", "cloud.sun", mode: .weather,
                              visible: c.weather && c.cardMask & 4 != 0))
        }
        if !c.ha.entities.isEmpty {
            let origin = homeAssistantOrigin(c)
            // Decoding a response does not certify it as valid firmware config.
            // Never build unbounded UI groups from a malformed remote array.
            let entityCount = min(c.ha.entities.count, 6)
            for group in 0..<((entityCount + 3) / 4) {
                cards.append(card("ha:\(digest(origin)):\(group)", "ha",
                                  entityCount > 4 ? "Home Assistant · \(group + 1)" : "Home Assistant",
                                  "house", mode: group == 0 ? .homeAssistant : nil,
                                  visible: c.ha.enabled && c.cardMask & 8 != 0,
                                  headers: ["X-Lingxi-Group": String(group), "X-Lingxi-Origin": origin]))
            }
        }
        var printerIDs = Set<String>()
        var enabledPrinterCount = 0
        for printer in c.printers.prefix(3) {
            // Invalid serial delimiters or header-control characters must not
            // alias a different identity or enter an explicit-native request.
            guard validNativePrinter(printer, configuration: c) else { continue }
            let identity = printerIdentity(printer, configuration: c)
            let id = "printer:\(digest(identity))"
            // Keep the first whole record for an exact repeated source identity.
            // Do not OR flags, copy names or combine data from the duplicate.
            guard printerIDs.insert(id).inserted else { continue }
            if printer.enabled { enabledPrinterCount += 1 }
            let name = printer.name.trimmingCharacters(in: .whitespacesAndNewlines)
            cards.append(card(id, "printer",
                              name.isEmpty ? printer.brandName : name, "printer",
                              mode: printerDisplayModes[identity], visible: printer.enabled && printer.rotate,
                              headers: ["X-Lingxi-Serial": printer.serial,
                                        "X-Lingxi-Brand": printer.brand,
                                        "X-Lingxi-Source": printer.source,
                                        "X-Lingxi-Origin": printerOrigin(printer, configuration: c)]))
        }
        if enabledPrinterCount >= 2 {
            cards.append(card("overview", "overview", "打印机总览", "square.grid.2x2", visible: true))
        }
        return cards
    }

    /// All descriptors include hidden cards so management can re-enable them.
    /// Native preference removes only identical, visible software counterparts;
    /// computer-only cards always survive. Clock has exactly one native entry.
    public static func descriptors(settings: AIMacScreenDeviceSettings,
                                   configuration: C6StandaloneConfiguration,
                                   softwareModes: [DisplayMode],
                                   printerDisplayModes: [String: DisplayMode] = [:]) -> [C6CardDescriptor] {
        let natives = nativeCards(configuration: configuration, printerDisplayModes: printerDisplayModes)
        let softwareVisible = settings.cardPanels.map(Set.init)
        let softwareRotation = Set(settings.cardRotationModes ?? [])
        let nativeVisible = settings.c6NativeCardPanels.map(Set.init)
        let nativeRotation = settings.c6NativeCardRotationIDs.map(Set.init)
        let legacyClockVisible = softwareVisible?.contains(DisplayMode.aiMacClock.rawValue)
            ?? softwareModes.contains(.aiMacClock)
        var descriptors = natives.map { card -> C6CardDescriptor in
            let clockMigration = card.kind == "clock" && legacyClockVisible
            let visible = nativeVisible?.contains(card.id) ?? (card.defaultVisible || clockMigration)
            let rotates = nativeRotation?.contains(card.id)
                ?? (clockMigration ? softwareRotation.contains(DisplayMode.aiMacClock.rawValue)
                    : card.defaultParticipatesInRotation)
            return C6CardDescriptor(id: C6MergedCardTarget.native(card.id).id,
                                    title: card.title, icon: card.icon, sourceTitle: "设备本地",
                                    displayMode: card.displayMode, nativeCard: card,
                                    visible: visible, participatesInRotation: visible && rotates)
        }
        let replaced = Set(descriptors.filter { $0.visible }.compactMap(\.displayMode))
        var seen = Set<DisplayMode>()
        for mode in softwareModes where mode != .aiMacClock && seen.insert(mode).inserted {
            if configuration.localFirst && replaced.contains(mode) { continue }
            let visible = softwareVisible?.contains(mode.rawValue) ?? true
            descriptors.append(C6CardDescriptor(id: C6MergedCardTarget.software(mode).id,
                                                title: mode.title, icon: mode.icon, sourceTitle: "电脑推送",
                                                displayMode: mode, visible: visible,
                                                participatesInRotation: visible && softwareRotation.contains(mode.rawValue)))
        }
        // A legacy clock order token maps to the only native clock item.
        let legacyOrder = (settings.c6MergedCardOrder ?? (settings.cardPanels ?? []).map { "software:\($0)" })
            .map { $0 == "software:\(DisplayMode.aiMacClock.rawValue)" ? "native:clock" : $0 }
        let order = normalizedOrder(legacyOrder, availableIDs: descriptors.map(\.id))
        // A bad/stale remote document must not trigger Dictionary's duplicate-key
        // precondition. Preserve first-record ownership even for future kinds.
        let byID = Dictionary(descriptors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    public static func rotationTargets(in cards: [C6CardDescriptor]) -> [C6MergedCardTarget] {
        cards.filter { $0.visible && $0.participatesInRotation }.map(\.target)
    }
    public static func normalizedOrder(_ order: [String]?, availableIDs: [String]) -> [String] {
        let available = Set(availableIDs)
        var seen = Set<String>()
        return ((order ?? []) + availableIDs).filter { available.contains($0) && seen.insert($0).inserted }
    }
    public static func cleanNativeID(_ id: String) -> String? {
        guard !id.isEmpty, id.utf8.count <= 192,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ":" || $0 == "_" || $0 == "-") }) else { return nil }
        return id
    }
    public static func cleanNativeIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap(cleanNativeID).filter { seen.insert($0).inserted }
    }
    public static func cleanOrder(_ order: [String]) -> [String] {
        var seen = Set<String>()
        return order.filter { id in
            let valid: Bool
            if id.hasPrefix("native:") { valid = cleanNativeID(String(id.dropFirst(7))) != nil }
            else if id.hasPrefix("software:"), let raw = Int(id.dropFirst(9)) { valid = DisplayMode(rawValue: raw) != nil }
            else { valid = false }
            return valid && seen.insert(id).inserted
        }
    }
}
