import Foundation

/// Stable identity shared by menu selection and preview. Never infer a device from a title.
public enum MenuBarPreviewTarget: Hashable {
    case card(UUID, DisplayMode)
    case board(UUID, UUID)
    case awtrix(UUID, String)
    case c6Local(UUID, String)

    public var deviceID: UUID {
        switch self {
        case let .card(id, _), let .board(id, _), let .awtrix(id, _), let .c6Local(id, _): return id
        }
    }
}

public enum MenuBarPresentationPolicy {
    public static func displayDevices(_ devices: [ManagedDevice]) -> [ManagedDevice] {
        devices.filter {
            $0.isEnabled && [.keyboard, .oracle, .excerpt, .aiMacScreen, .c6Screen, .awtrix].contains($0.type)
        }
    }

    /// A detached settings object is essential: applying a snapshot to live settings
    /// would change active devices, trigger persistence and potentially push a frame.
    public static func previewSettings(from settings: AppSettings, device: ManagedDevice) throws -> AppSettings {
        let copy = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        copy.deviceSyncInFlight = true
        if settings.activeDeviceID(for: device.type) != device.id {
            device.settings.apply(to: copy, type: device.type)
        }
        copy.setActiveDeviceID(device.type, device.id)
        return copy
    }
}
