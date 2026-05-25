import SwiftUI

/// The Cmd-, preferences pane. Two `Section`s — Appearance and Notifications
/// — plus a quiet footer reminding the user that no data leaves the device.
///
/// Reads/writes settings through `@AppStorage` against the keys in
/// `SettingsKey`; the same keys are read by `NotificationManager` via the
/// static `AppSettings` interface, so the two paths can't drift.
struct SettingsView: View {

    // Notifications
    @AppStorage(SettingsKey.notificationLevel) private var levelRaw    = NotificationLevel.standard.rawValue
    @AppStorage(SettingsKey.notificationSound) private var sound       = true
    @AppStorage(SettingsKey.pollingInterval)   private var intervalRaw = PollingInterval.normal.rawValue

    // Appearance
    @AppStorage(SettingsKey.themeID)         private var themeIDRaw    = ThemeID.sage.rawValue
    @AppStorage(SettingsKey.colorSchemePref) private var schemePrefRaw = ColorSchemePreference.system.rawValue

    // Allowed surfaces (opt-in per feature module)
    @AppStorage(SettingsKey.allowFollowRequests) private var allowFollowRequests = FollowRequests.defaultEnabled
    @AppStorage(SettingsKey.allowSharedPosts)    private var allowSharedPosts    = SharedPosts.defaultEnabled

    @Environment(\.theme) private var theme

    var body: some View {
        Form {
            appearanceSection
            allowedSurfacesSection
            notificationsSection
            footerSection
        }
        // `Form` on macOS paints its own material background by default;
        // hiding the scroll-content background lets `theme.background` show
        // through and the form actually picks up the active palette.
        .scrollContentBackground(.hidden)
        .padding()
        .frame(width: 480, height: 460)
        .background(theme.background)
        .foregroundStyle(theme.text)
    }

    // MARK: - Sections

    private var appearanceSection: some View {
        Section {
            Picker("Theme", selection: themeBinding) {
                ForEach(ThemeID.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.segmented)

            Picker("Color scheme", selection: schemeBinding) {
                ForEach(ColorSchemePreference.allCases) { pref in
                    Text(pref.displayName).tag(pref)
                }
            }
        } header: {
            Text("Appearance").foregroundStyle(theme.textSecondary)
        }
    }

    private var notificationsSection: some View {
        Section {
            Picker("Level", selection: levelBinding) {
                ForEach(NotificationLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            Toggle("Play sound", isOn: $sound)
                .disabled(!currentLevel.wantsBanners)
            Picker("Check every", selection: intervalBinding) {
                ForEach(PollingInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            .disabled(currentLevel == .off)
        } header: {
            Text("Notifications").foregroundStyle(theme.textSecondary)
        }
    }

    /// Opt-in non-DM surfaces. Each toggle is gated by its feature module's
    /// compile-time `available` flag — flipping that flag to `false` (or
    /// deleting the feature file) makes the toggle disappear without
    /// touching anything else here.
    @ViewBuilder
    private var allowedSurfacesSection: some View {
        if FollowRequests.available || SharedPosts.available {
            Section {
                if FollowRequests.available {
                    Toggle("Show \(FollowRequests.displayName) tab", isOn: $allowFollowRequests)
                }
                if SharedPosts.available {
                    Toggle(SharedPosts.displayName, isOn: $allowSharedPosts)
                }
                Text("Each toggle opens a non-DM Instagram surface. Off by default; the more you turn on, the larger the area the app exposes.")
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
            } header: {
                Text("Allowed Surfaces").foregroundStyle(theme.textSecondary)
            }
        }
    }

    private var footerSection: some View {
        Section {
            Text("All settings are stored locally on this Mac. Nothing is sent anywhere except Instagram itself.")
                .font(.footnote)
                .italic()
                .foregroundStyle(theme.textSecondary)
        }
    }

    // MARK: - Derived state

    private var currentLevel: NotificationLevel {
        NotificationLevel(rawValue: levelRaw) ?? .standard
    }

    // MARK: - Bindings (raw String ↔ enum)

    private var levelBinding: Binding<NotificationLevel> {
        Binding(
            get: { NotificationLevel(rawValue: levelRaw) ?? .standard },
            set: { levelRaw = $0.rawValue }
        )
    }

    private var intervalBinding: Binding<PollingInterval> {
        Binding(
            get: { PollingInterval(rawValue: intervalRaw) ?? .normal },
            set: { intervalRaw = $0.rawValue }
        )
    }

    private var themeBinding: Binding<ThemeID> {
        Binding(
            get: { ThemeID(rawValue: themeIDRaw) ?? .sage },
            set: { themeIDRaw = $0.rawValue }
        )
    }

    private var schemeBinding: Binding<ColorSchemePreference> {
        Binding(
            get: { ColorSchemePreference(rawValue: schemePrefRaw) ?? .system },
            set: { schemePrefRaw = $0.rawValue }
        )
    }
}
