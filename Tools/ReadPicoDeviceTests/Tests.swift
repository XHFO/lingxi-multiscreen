import Foundation
import LinxDisplayCore

@main
struct ReadPicoDeviceTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw Failure(message: message) }
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func main() throws {
        let legacyTypes: [DeviceType] = [.keyboard, .oracle, .excerpt, .homeAssistant, .bambuLab,
                                        .formlabs, .aiMacScreen, .awtrix, .m5Controller, .c6Screen]
        for (value, type) in legacyTypes.enumerated() {
            try check(type.rawValue == value, "Existing device raw value changed: \(type)")
            let decoded = try JSONDecoder().decode(DeviceType.self, from: Data("\(value)".utf8))
            try check(decoded == type, "Existing device raw value cannot decode: \(value)")
        }
        try check(DeviceType.readPico.rawValue == 10, "Pico must use a new stable raw value")
        try check(DeviceType.readPico.title == "小纸 Pico", "Pico title")
        let profile = try require(DeviceType.readPico.capabilityProfile, "Missing registry profile")
        try check(profile.maximumInstances == nil, "Pico must allow multiple devices")
        try check(profile.cardSurface == nil, "Pico must not join card rendering/rotation")
        try check(profile.isManagementOnly, "Pico management-only capability")
        try check(DeviceType.readPico.isManagementOnly, "Type capability access")
        try check(!DeviceType.readPico.isColorWiFiScreen, "Pico is not a color Wi-Fi push target")
        try check(profile.transport == .localDeviceManagement, "Pico dedicated transport")
        try check(profile.screenSize == .init(width: 684, height: 1216), "Pico screen dimensions")
        try check(DeviceCapabilityRegistry.all.count == DeviceType.allCases.count, "Every type needs one registry entry")
        try check(Set(DeviceCapabilityRegistry.all.map(\.type)).count == DeviceType.allCases.count, "Registry duplicates")
        for type in legacyTypes {
            try check(!type.isManagementOnly, "Existing type capabilities must stay unchanged")
        }

        let addresses: [(String, String)] = [
            ("", ""), (" \n ", ""), ("192.168.1.42", "http://192.168.1.42"),
            ("192.168.1.42:8080/manage", "http://192.168.1.42:8080"),
            ("https://pico.local/manage?key=secret#key=another", "https://pico.local"),
            ("http://[::1]:8783/?session=private#key=private", "http://[::1]:8783"),
            ("HTTPS://pico.local/a/b?password=sensitive", "https://pico.local")
        ]
        for (source, expected) in addresses {
            let settings = try ReadPicoManagedDeviceSettings(managementAddress: source)
            try check(settings.managementAddress == expected, "Address normalization: \(source)")
            let data = try JSONEncoder().encode(settings)
            let roundtrip = try JSONDecoder().decode(ReadPicoManagedDeviceSettings.self, from: data)
            try check(roundtrip == settings, "Address roundtrip")
            let string = String(decoding: data, as: UTF8.self)
            for secret in ["secret", "another", "private", "sensitive", "password", "#key"] {
                try check(!string.contains(secret), "Session data persisted")
            }
        }
        for invalid in ["file:///tmp/pico", "ftp://pico.local", "http://user:password@pico.local", "http://@pico.local",
                        "http://pico.local:0", "http://pico.local:65536", "http://", "my pico.local"] {
            do {
                _ = try ReadPicoManagedDeviceSettings(managementAddress: invalid)
                throw Failure(message: "Invalid address accepted: \(invalid)")
            } catch is ReadPicoManagedDeviceSettingsError {
                checks += 1
            }
        }
        let imported = try JSONDecoder().decode(ReadPicoManagedDeviceSettings.self,
            from: Data(#"{"managementAddress":"http://pico.local/manage?session=secret#key=secret"}"#.utf8))
        try check(imported.managementAddress == "http://pico.local", "Imported address must clear session data")
        try check(imported.informationPush == .init(), "Legacy devices receive manual clock defaults")
        try check(imported.automaticUSBPreparation, "Legacy devices can prepare USB after device confirmation")
        let invalidPush = ReadPicoInformationPushSettings(source: "unsupported", intervalSeconds: 2,
            entityIDs: ["", "sensor.a", "sensor.a", String(repeating: "a", count: 256)] + (1...9).map { "sensor.\($0)" })
        try check(invalidPush.source == "clock" && invalidPush.intervalSeconds == 0, "Imported unsupported source or interval defaults safely")
        try check(invalidPush.entityIDs.count == 6 && invalidPush.entityIDs.first == "sensor.a" && Set(invalidPush.entityIDs).count == 6,
                  "Entity choices are bounded and unique")
        let invalidImported = try JSONDecoder().decode(ReadPicoManagedDeviceSettings.self,
            from: Data(#"{"managementAddress":"http://user:pass@pico.local"}"#.utf8))
        try check(invalidImported.managementAddress.isEmpty, "Bad imported address must not discard the device list")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadPicoDeviceTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(dataDirectory: root)
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"devices":[{"type":0,"name":"旧键盘","settings":{"endpoint":"http://keyboard/image/upload"}}]}"#.utf8))
        try check(settings.devices.count == 1, "Legacy configuration survives")
        try check(settings.activeReadPicoDeviceID == nil, "Legacy configuration needs no migration")
        let keyboard = settings.devices[0]
        settings.setActiveDeviceID(.keyboard, keyboard.id)
        keyboard.settings.apply(to: settings, type: .keyboard)
        settings.captureActiveDeviceSnapshots()
        let originalKeyboardSettings = settings.devices[0].settings
        var firstSettings = DeviceSettings()
        firstSettings.readPico = try .init(managementAddress: "http://pico-one.local/manage#key=secret")
        firstSettings.readPico?.automaticUSBPreparation = false
        firstSettings.readPico?.informationPush = .init(source: "home", landscape: true, dither: false,
                                                       intervalSeconds: 300, entityIDs: ["light.study", "sensor.room"])
        try firstSettings.readPico?.updateManagementAddress("http://pico-one.local/manage#key=secret")
        try check(firstSettings.readPico?.informationPush.source == "home", "Changing the management address preserves information preferences")
        try check(firstSettings.readPico?.automaticUSBPreparation == false, "Address changes preserve USB preparation preference")
        let first = ManagedDevice(type: .readPico, name: "书房小纸", settings: firstSettings)
        var secondSettings = DeviceSettings()
        secondSettings.readPico = try .init(managementAddress: "http://pico-two.local:8080")
        let second = ManagedDevice(type: .readPico, name: "床头小纸", settings: secondSettings)
        settings.devices.append(contentsOf: [first, second])
        settings.setActiveDeviceID(.readPico, second.id)
        try check(settings.canAddDevice(of: .readPico), "Adding Pico must stay available")
        try check(settings.devices(for: .readPico).map(\.id) == [first.id, second.id], "Separate Pico identities")
        try check(ColorWiFiScreenSelectionPolicy.requestedType(for: first.id, in: settings) == nil, "Pico is not selectable for color-screen push")
        try check(ColorWiFiScreenSelectionPolicy.device(in: settings, preferredType: .readPico) == nil, "No Pico color-screen fallback")
        settings.captureActiveDeviceSnapshots()
        try check(settings.devices.first { $0.id == second.id }?.settings == secondSettings, "Snapshot capture must preserve Pico address")
        _ = settings.switchActiveDevice(of: .readPico, to: first.id)
        try check(settings.activeReadPicoDeviceID == first.id, "Active Pico switches")
        try check(settings.activeDevice(for: .readPico)?.settings == firstSettings, "Pico settings stay separate")
        try check(settings.devices.first { $0.id == keyboard.id }?.settings == originalKeyboardSettings, "Pico switching must not change keyboard")
        store.save(settings)
        let encoded = try String(contentsOf: store.settingsURL, encoding: .utf8)
        try check(!encoded.contains("secret"), "Full settings must not save pairing secret")
        let reopened = store.load()
        try check(reopened.devices(for: .readPico).count == 2, "Two Pico devices reload")
        try check(reopened.activeReadPicoDeviceID == first.id, "Selected Pico reloads")
        try check(reopened.devices.first { $0.id == first.id }?.settings.readPico == firstSettings.readPico, "First Pico address reloads")
        try check(reopened.devices.first { $0.id == second.id }?.settings.readPico == secondSettings.readPico, "Second Pico address reloads")
        try check(reopened.devices.first { $0.id == first.id }?.settings.readPico?.automaticUSBPreparation == false &&
                  reopened.devices.first { $0.id == second.id }?.settings.readPico?.automaticUSBPreparation == true,
                  "Automatic USB is saved separately for each Pico")
        try check(reopened.removeManagedDevice(id: first.id)?.id == first.id, "Delete first Pico")
        try check(reopened.activeReadPicoDeviceID == second.id, "Deleting active Pico selects remaining device")
        try check(reopened.devices.first { $0.id == second.id }?.settings == secondSettings, "Deleting one Pico preserves another")
        _ = reopened.removeManagedDevice(id: second.id)
        try check(reopened.activeReadPicoDeviceID == nil, "Deleting last Pico clears selection")
        try check(reopened.devices.count == 1 && reopened.devices.first?.id == keyboard.id, "Deleting Pico preserves legacy device")
        store.save(reopened)
        try check(store.load().devices(for: .readPico).isEmpty, "Deleted Pico devices remain deleted")
        print("Read Pico unified device registry: \(checks) passed, 0 failed")
    }

    static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(message: message) }
        return value
    }
}
