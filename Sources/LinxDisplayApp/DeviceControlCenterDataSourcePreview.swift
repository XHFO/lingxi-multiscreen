import AppKit
import LinxDisplayCore

extension AppModel {
    /// Renders existing, source-matched readings with the same module renderer as device
    /// canvases. No network, credential-store access, source selection or upload occurs here.
    @MainActor func controlCenterDataSourcePreview(for source: DeviceControlCenterDataSource) -> NSImage? {
        if source.destination == .nowPlaying { return nil }
        let copy = AppSettings()
        copy.cardTheme = settings.cardTheme
        copy.backgroundTone = settings.backgroundTone
        copy.customBackgroundHex = settings.customBackgroundHex
        copy.accentTone = settings.accentTone
        copy.customAccentHex = settings.customAccentHex
        copy.cardRenderingMode = settings.cardRenderingMode
        copy.softwareIsDark = settings.softwareIsDark
        var module: CanvasModule
        var ha: HASnapshot = .empty
        var forms: [FormlabsCanvasItem] = []

        switch source.destination {
        case .nowPlaying:
            // The dashboard uses the native live media card instead of a rendered
            // device image. No player or fake hardware session is created.
            return nil
        case .cloudflare(let id):
            guard let saved = settings.cloudflareSources.first(where: { $0.id == id }),
                  let reading = saved.snapshot, reading.matches(saved.configuration) else { return nil }
            copy.cloudflare = saved.configuration
            copy.cloudflareSnapshot = reading
            module = .cloudflare
        case .weather:
            guard settings.weather.isValid, let reading = settings.weatherSnapshot,
                  reading.matches(settings.weather), reading.temperature.isFinite else { return nil }
            copy.weather = settings.weather
            copy.weatherSnapshot = reading
            module = .weather
        case .managedDevice(let id):
            guard let device = settings.devices.first(where: { $0.id == id }), device.isEnabled else { return nil }
            switch device.type {
            case .formlabs:
                guard let snapshot = formlabsSnapshots[id], snapshot.hasData,
                      let saved = device.settings.formlabsConnection else { return nil }
                // Only display controls and the printer serial enter the renderer; OAuth secrets do not.
                let connection = FormlabsConnectionSettings(printerSerial: saved.printerSerial,
                    showThumbnail: saved.showThumbnail, showLayers: saved.showLayers,
                    showMaterial: saved.showMaterial, useBrandAccent: saved.useBrandAccent)
                let serial = connection.printerSerial.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !serial.isEmpty, let cachedDevice = snapshot.device,
                      cachedDevice.id.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare(serial) == .orderedSame else { return nil }
                forms = [.init(deviceName: device.name, connection: connection, snapshot: snapshot)]
                module = .formlabs
            case .bambuLab:
                let cached: [HAEntity]?
                if device.settings.bambuDataSource == .localMQTT {
                    cached = existingBambuMQTTEntities(for: id)
                } else {
                    cached = activeHADeviceID.flatMap { existingHASourceEntities(for: $0) }
                }
                guard let entities = cached, !entities.isEmpty else { return nil }
                let config = BambuLabCardSettings.from(device)
                guard !config.statusEntityID.isEmpty,
                      entities.contains(where: { $0.entityId == config.statusEntityID }) else { return nil }
                var safeSettings = DeviceSettings()
                config.apply(to: &safeSettings)
                var safeDevice = ManagedDevice(type: .bambuLab, name: device.name, settings: safeSettings)
                safeDevice.id = id
                copy.devices = [safeDevice]
                ha = HASnapshot(entities: entities, selectedEntities: entities)
                module = .bambuLab
            case .homeAssistant:
                // Use the dedicated request-origin cache, never the mixed global HA/MQTT pool.
                guard let entities = existingHASourceEntities(for: id), !entities.isEmpty else { return nil }
                let requested = device.settings.haEntities
                    ?? device.settings.haEntityID.map { [$0] } ?? []
                let selected = requested.isEmpty ? Array(entities.prefix(6))
                    : requested.compactMap { wanted in entities.first { $0.entityId == wanted } }
                guard !selected.isEmpty else { return nil }
                ha = HASnapshot(entities: entities, selectedEntities: selected,
                                aliases: device.settings.haEntityAliases ?? [:])
                module = .homeAssistant
            default: return nil
            }
        }

        let image = ScreenRenderer.renderDeviceCanvas(modules: [module], system: system,
            nowPlaying: nowPlaying, pomodoro: pomodoroSnapshot, customText: "", settings: copy,
            ha: ha, formlabsItems: forms, width: 640, height: 400,
            palette: copy.resolvedPalette, optimizeForEInk: false)
        return NSImage(cgImage: image, size: NSSize(width: 640, height: 400))
    }
}
