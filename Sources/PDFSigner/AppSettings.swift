import SwiftUI

/// App-wide theme preference.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }

    /// The SwiftUI color scheme to force, or nil to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// App language preference. `system` follows the OS; the others force a locale.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, es, en
    var id: String { rawValue }

    /// BCP-47 code to force, or nil to follow the system.
    var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .es: return "es"
        case .en: return "en"
        }
    }
}

/// Persisted user preferences (theme, language). Stored in UserDefaults so they
/// survive launches. Language changes that affect already-built views take full
/// effect on next launch; theme applies live.
@MainActor
@Observable
final class AppSettings {
    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }
    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Keys.language)
            applyLanguage()
        }
    }

    private enum Keys {
        static let theme = "settings.theme"
        static let language = "settings.language"
    }

    init() {
        let d = UserDefaults.standard
        theme = AppTheme(rawValue: d.string(forKey: Keys.theme) ?? "") ?? .system
        language = AppLanguage(rawValue: d.string(forKey: Keys.language) ?? "") ?? .system
    }

    /// Push the chosen language into AppleLanguages so a relaunch (or newly
    /// presented windows) pick it up. Returns silently for `.system`.
    private func applyLanguage() {
        let d = UserDefaults.standard
        if let id = language.localeIdentifier {
            d.set([id], forKey: "AppleLanguages")
        } else {
            d.removeObject(forKey: "AppleLanguages")
        }
    }
}
