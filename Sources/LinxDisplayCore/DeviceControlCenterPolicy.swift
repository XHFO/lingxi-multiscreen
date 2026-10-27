import Foundation

/// The overview keeps every saved device, including disabled profiles and devices without a screen.
/// Identity and destination never depend on a display name or current active-device pointer.
public enum DeviceControlCenterPolicy {
    public enum Destination: Equatable {
        case keyboard, oracle, excerpt, colorScreen, c6, awtrix, pico, controller, deviceSettings
    }
    public static func devices(_ devices: [ManagedDevice]) -> [ManagedDevice] { devices }
    public static func destination(for device: ManagedDevice) -> Destination {
        guard device.isEnabled else { return .deviceSettings }
        switch device.type {
        case .keyboard: return .keyboard
        case .oracle: return .oracle
        case .excerpt: return .excerpt
        case .aiMacScreen: return .colorScreen
        case .c6Screen: return .c6
        case .awtrix: return .awtrix
        case .readPico: return .pico
        case .m5Controller: return .controller
        case .homeAssistant, .bambuLab, .formlabs: return .deviceSettings
        }
    }
    public static func hasDisplay(_ type: DeviceType) -> Bool {
        [.keyboard, .oracle, .excerpt, .aiMacScreen, .c6Screen, .awtrix, .readPico, .m5Controller].contains(type)
    }
}
