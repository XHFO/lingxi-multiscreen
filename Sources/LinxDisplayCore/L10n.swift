import Foundation

/// App chrome localization: Chinese development language keys, English via `en.lproj`.
/// Prefer `String(localized:)` / SwiftUI `Text("…")` literals; use `L10n.t` when a
/// plain `String` must resolve against Bundle.main (menus, computed titles, alerts).
///
/// Shared Pico / Home Link / lock-style surfaces use dotted keys from
/// `read_pico_firmware_slices/docs/I18N_KEY_LIST.md` (see `PicoKeys`).
public enum L10n {
    /// Resolve a user-visible string against the main app bundle.
    public static func t(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .main)
    }

    /// Resolve a dynamic key (already a Chinese source string or Pico dotted id).
    public static func t(_ key: String) -> String {
        String(localized: String.LocalizationValue(stringLiteral: key), bundle: .main)
    }
}

/// Dotted keys shared with Pico firmware i18n (`I18N_KEY_LIST.md`).
/// Use these at ReadPico manager / Home Link / lock-style call sites only.
public enum PicoKeys {
    public enum Common {
        public static let cancel = "common.cancel"
        public static let done = "common.done"
        public static let confirm = "common.confirm"
        public static let back = "common.back"
        public static let prev = "common.prev"
        public static let next = "common.next"
    }

    public enum HomeLink {
        public static let fieldLocal = "settings.home_link.field.local"
        public static let fieldExternal = "settings.home_link.field.external"
        public static let fieldToken = "settings.home_link.field.token"
        public static let fieldCfId = "settings.home_link.field.cf_id"
        public static let fieldCfSecret = "settings.home_link.field.cf_secret"
        public static let fieldWifi = "settings.home_link.field.wifi"
        public static let on = "settings.home_link.on"
        public static let off = "settings.home_link.off"
        public static let save = "settings.home_link.save"
        public static let savedToast = "settings.home_link.saved_toast"
        public static let unset = "settings.home_link.unset"
        public static let monitor = "settings.home_link.monitor"
        public static let settingsTitle = "settings.home_link.settings_title"
        public static let printers = "settings.home_link.printers"
        public static let setupTitle = "settings.home_link.setup_title"
        public static let setupSub = "settings.home_link.setup_sub"
        /// Mac chrome (not on device I18N list): portal-active banner / PGA backup note.
        public static let portalActive = "settings.home_link.portal_active"
        public static let portalWait = "settings.home_link.portal_wait"
        public static let pgaBackup = "settings.home_link.pga_backup"
    }

    public enum Power {
        public static let title = "settings.power.title"
        public static let styleClock = "settings.power.style.clock"
        public static let styleQuotes = "settings.power.style.quotes"
        public static let styleCovers = "settings.power.style.covers"
        public static let stylePage = "settings.power.style.page"
        public static let styleImage = "settings.power.style.image"
        public static let styleBoard = "settings.power.style.board"
    }

    public enum Nav {
        public static let printers = "nav.printers"
        public static let home = "nav.home"
        public static let books = "nav.books"
        public static let apps = "nav.apps"
    }
}
