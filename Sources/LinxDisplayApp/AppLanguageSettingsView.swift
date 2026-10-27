import Foundation
import SwiftUI

enum AppInterfaceLanguage: String, CaseIterable, Identifiable {
    case followSystem = "system"
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var labelKey: String {
        switch self {
        case .followSystem: "跟随系统"
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}

/// AppleLanguages belongs to this application's preferences domain. Reading the
/// persistent domain explicitly distinguishes an override from the system fallback.
struct AppLanguagePreferences {
    private static let languagesKey = "AppleLanguages"
    private let defaults: UserDefaults
    private let applicationDomain: String

    init(defaults: UserDefaults = .standard,
         applicationDomain: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) {
        self.defaults = defaults
        self.applicationDomain = applicationDomain
    }

    func load() -> AppInterfaceLanguage {
        guard let languages = defaults.persistentDomain(forName: applicationDomain)?[Self.languagesKey] as? [String],
              let language = languages.first?.lowercased() else { return .followSystem }
        if language == "zh-hans" || language.hasPrefix("zh-hans-") || language == "zh-cn" {
            return .simplifiedChinese
        }
        if language == "en" || language.hasPrefix("en-") { return .english }
        return .followSystem
    }

    func save(_ language: AppInterfaceLanguage) {
        if language == .followSystem {
            defaults.removeObject(forKey: Self.languagesKey)
        } else {
            defaults.set([language.rawValue], forKey: Self.languagesKey)
        }
    }
}

/// The process keeps its current localization until its next launch. Changing
/// this preference never quits the app or interrupts unsaved device work.
struct AppLanguageSettingsView: View {
    private let preferences: AppLanguagePreferences
    @State private var language: AppInterfaceLanguage

    init(preferences: AppLanguagePreferences = .init()) {
        self.preferences = preferences
        _language = State(initialValue: preferences.load())
    }

    var body: some View {
        Section {
            Picker("界面语言", selection: Binding(get: { language }, set: { selected in
                guard selected != language else { return }
                preferences.save(selected)
                language = selected
            })) {
                ForEach(AppInterfaceLanguage.allCases) { option in
                    Text(LocalizedStringKey(option.labelKey)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("app-interface-language")
            Text("仅更改多屏灵犀的界面语言，不影响系统或设备。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("软件语言")
        } footer: {
            Text("重新打开应用后生效。")
        }
        .onAppear { language = preferences.load() }
    }
}
