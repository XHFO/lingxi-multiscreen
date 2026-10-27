import Foundation
import LinxDisplayCore

/// Saved source records and the always-available system media source. Building this
/// list never selects a source, reads a credential,
/// starts a refresh or changes the active device. Managed services appear here once, rather
/// than also pretending to be display devices in the screen collection.
struct DeviceControlCenterDataSource: Identifiable, Equatable {
    enum Kind: Equatable { case cloudflare, homeAssistant, printer, weather, nowPlaying }
    enum Destination: Equatable {
        case managedDevice(UUID)
        case cloudflare(UUID)
        case weather
        case nowPlaying
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    var status: String
    let symbolName: String
    let destination: Destination
    var previewError: String? = nil

    static func sources(settings: AppSettings) -> [Self] {
        var result = settings.cloudflareSources.map { source in
            let config = source.configuration
            let domain = [config.hostname, config.zoneName].first {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let reading = source.snapshot.flatMap { $0.matches(config) ? $0 : nil }
            let status: String
            if !config.isValid { status = String(localized: "连接信息待完善") }
            else if let reading {
                status = String(localized: "最近统计") + " · "
                    + CloudflareAnalyticsSnapshot.countText(reading.requests) + " " + String(localized: "次请求")
                    + " · " + CloudflareAnalyticsSnapshot.bytesText(reading.bytes)
            } else { status = String(localized: "尚无统计缓存") }
            return Self(id: "cloudflare:" + source.id.uuidString, kind: .cloudflare,
                        title: source.name, subtitle: ["Cloudflare", domain].compactMap { $0 }.joined(separator: " · "),
                        status: status, symbolName: "cloud.fill", destination: .cloudflare(source.id))
        }

        for device in settings.devices {
            let kind: Kind
            let subtitle: String
            let symbol: String
            switch device.type {
            case .homeAssistant:
                kind = .homeAssistant; symbol = "house.fill"
                // Do not render credentials, URL user-info, query parameters or private API paths.
                let host = URLComponents(string: device.settings.haServerURL ?? "")?.host
                subtitle = ["Home Assistant", host].compactMap { $0 }.joined(separator: " · ")
            case .bambuLab:
                kind = .printer; symbol = "printer.fill"
                subtitle = "Bambu Lab · " + (device.settings.bambuDataSource ?? .homeAssistant).title
            case .formlabs:
                kind = .printer; symbol = "printer.fill"
                subtitle = "Formlabs Dashboard"
            default: continue
            }
            result.append(Self(id: "managed:" + device.id.uuidString, kind: kind,
                               title: MenuBarNamingPolicy.resolvedDeviceName(device), subtitle: subtitle,
                               status: device.isEnabled ? String(localized: "打开连接设置") : String(localized: "设备已停用"),
                               symbolName: symbol, destination: .managedDevice(device.id)))
        }

        // Weather is one shared Open-Meteo city in AppSettings, not an account and not a
        // per-device setting. An unchosen/invalid city does not create a fictional source.
        let weather = settings.weather
        if weather.isValid {
            let reading = settings.weatherSnapshot.flatMap { $0.matches(weather) ? $0 : nil }
            let status: String
            if let reading, reading.temperature.isFinite {
                status = String(localized: "最近天气") + " · "
                    + reading.temperature.formatted(.number.precision(.fractionLength(0...1))) + " °C"
            } else { status = String(localized: "尚无天气缓存") }
            result.append(Self(id: "weather:open-meteo", kind: .weather,
                               title: weather.city, subtitle: "Open-Meteo · " + String(localized: "共享天气"),
                               status: status, symbolName: reading?.condition.symbolName ?? "cloud.sun.fill", destination: .weather))
        }
        // System media is an always-available software source, including its honest
        // idle state. Its stable ID participates in the same saved layout/groups.
        result.append(Self(id: "now-playing:system", kind: .nowPlaying,
                           title: String(localized: "正在播放"), subtitle: String(localized: "系统媒体"),
                           status: String(localized: "未在播放"), symbolName: "music.note",
                           destination: .nowPlaying))
        return result
    }
}

extension AppModel {
    @MainActor func controlCenterDataSources() -> [DeviceControlCenterDataSource] {
        DeviceControlCenterDataSource.sources(settings: settings).map { source in
            guard case .managedDevice(let id) = source.destination,
                  let device = settings.devices.first(where: { $0.id == id }), device.isEnabled else { return source }
            let error: String?
            switch device.type {
            case .homeAssistant:
                error = controlCenterHAPreviewError(for: id)
            case .bambuLab where device.settings.bambuDataSource != .localMQTT:
                error = activeHADeviceID.flatMap { controlCenterHAPreviewError(for: $0) }
            case .formlabs:
                error = formlabsSnapshots[id]?.cloudError
            default: error = nil
            }
            guard let error else { return source }
            var updated = source
            updated.previewError = error
            updated.status = error
            return updated
        }
    }
}
