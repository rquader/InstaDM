import Foundation

// MARK: - Setting values

enum NotificationLevel: String, CaseIterable {
    case off
    case badgeOnly
    case standard
    case fullPreview

    var displayName: String {
        switch self {
        case .off:         return "Off"
        case .badgeOnly:   return "Badge only"
        case .standard:    return "Notify (no preview)"
        case .fullPreview: return "Notify with preview (experimental)"
        }
    }

    /// True for levels that fire OS notification banners (not just dock badges).
    var wantsBanners: Bool {
        switch self {
        case .off, .badgeOnly:      return false
        case .standard, .fullPreview: return true
        }
    }
}

enum PollingInterval: Double, CaseIterable {
    case fast   = 15
    case normal = 30
    case slow   = 60
    case slower = 120

    var displayName: String {
        switch self {
        case .fast:   return "Every 15 seconds"
        case .normal: return "Every 30 seconds"
        case .slow:   return "Every minute"
        case .slower: return "Every 2 minutes"
        }
    }
}

// MARK: - UserDefaults keys

/// The single source of truth for the `UserDefaults` key strings. Both
/// `SettingsView` (`@AppStorage`) and `Settings` (static read interface
/// below) reference these so the two paths can't drift.
enum SettingsKey {
    static let notificationLevel = "notificationLevel"
    static let notificationSound = "notificationSound"
    static let pollingInterval   = "pollingInterval"
    static let themeID           = "themeID"
    static let colorSchemePref   = "colorSchemePref"

    // Opt-in surfaces. Each is owned by its own feature module
    // (`FollowRequests.swift`, `SharedPosts.swift`) — these keys exist here
    // only so SwiftUI's `@AppStorage` and the feature modules can read the
    // same UserDefaults entry.
    static let allowFollowRequests = "allowFollowRequests"
    static let allowSharedPosts    = "allowSharedPosts"

    /// When `true`, blocked link taps and `target="_blank"` hops open in the
    /// user's default browser after login. Login/challenge flows always may
    /// open externally regardless of this toggle.
    static let openLinksInExternalBrowser = "openLinksInExternalBrowser"
}

// MARK: - Read interface

/// Non-view code (most notably `NotificationManager`) reads settings through
/// this enum so it doesn't have to participate in SwiftUI's observation
/// machinery. Views write via `@AppStorage` against the same keys.
///
/// Named `AppSettings` (not `Settings`) so it doesn't shadow `SwiftUI.Settings`,
/// the scene type used for the Cmd-, preferences pane in `InstaDMApp`.
enum AppSettings {

    static var notificationLevel: NotificationLevel {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.notificationLevel)
            ?? NotificationLevel.standard.rawValue
        return NotificationLevel(rawValue: raw) ?? .standard
    }

    static var notificationSound: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.notificationSound) as? Bool ?? true
    }

    static var pollingInterval: TimeInterval {
        let raw = UserDefaults.standard.double(forKey: SettingsKey.pollingInterval)
        return raw > 0 ? raw : PollingInterval.normal.rawValue
    }

    static var themeID: ThemeID {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.themeID) ?? ThemeID.sage.rawValue
        return ThemeID(rawValue: raw) ?? .sage
    }

    static var colorSchemePref: ColorSchemePreference {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.colorSchemePref)
            ?? ColorSchemePreference.system.rawValue
        return ColorSchemePreference(rawValue: raw) ?? .system
    }

    // MARK: - Allowed surfaces
    //
    // These are mirrored from each feature module's `enabled` getter so
    // non-view code can ask "is this on?" through one consistent API. The
    // feature modules apply the compile-time guard (`available`) — these
    // accessors just delegate.

    static var allowFollowRequests: Bool { FollowRequests.enabled }
    static var allowSharedPosts:    Bool { SharedPosts.enabled }

    /// Off after login when the user disables external link opening in Settings.
    static var openLinksInExternalBrowser: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.openLinksInExternalBrowser) as? Bool ?? true
    }
}
