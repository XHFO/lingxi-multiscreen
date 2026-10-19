import Foundation

/// Resolves shared color-screen editors without changing either family's saved active ID.
/// Disabled devices and non-screen types can never become an editor or push target.
public enum ColorWiFiScreenSelectionPolicy {
    public static func device(in settings: AppSettings,
                              preferredType: DeviceType) -> ManagedDevice? {
        let enabled = settings.devices.filter { $0.isEnabled && $0.type.isColorWiFiScreen }
        let preferred = enabled.filter { $0.type == preferredType }
        let family = preferred.isEmpty ? enabled.first?.type : preferredType
        guard let family else { return nil }
        let candidates = enabled.filter { $0.type == family }
        let activeID = settings.activeDeviceID(for: family)
        return candidates.first { $0.id == activeID } ?? candidates.first
    }

    public static func requestedType(for id: UUID,
                                     in settings: AppSettings) -> DeviceType? {
        settings.devices.first {
            $0.id == id && $0.isEnabled && $0.type.isColorWiFiScreen
        }?.type
    }
}
