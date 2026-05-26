import SwiftUI

/// The Cmd-, preferences pane.
///
/// macOS-native `Form` with `.formStyle(.grouped)` so each section renders
/// as a rounded card that picks up the system's light/dark appearance and
/// gets proper text contrast for free. No custom backgrounds — the OS does
/// a better job here than a hand-painted palette.
///
/// Reads/writes through `@AppStorage` against `SettingsKey`. `AppSettings`
/// reads the same keys for non-view code so the two paths can't drift.
struct SettingsView: View {

    @AppStorage(SettingsKey.notificationLevel) private var levelRaw    = NotificationLevel.standard.rawValue
    @AppStorage(SettingsKey.notificationSound) private var sound       = true
    @AppStorage(SettingsKey.pollingInterval)   private var intervalRaw = PollingInterval.normal.rawValue
    @AppStorage(SettingsKey.colorSchemePref)   private var schemePrefRaw = ColorSchemePreference.system.rawValue

    @AppStorage(SettingsKey.openLinksInExternalBrowser)
    private var openLinksInExternalBrowser = true

    @AppStorage(SettingsKey.allowFollowRequests)
    private var allowFollowRequests = FollowRequests.defaultEnabled

    @AppStorage(SettingsKey.allowSharedPosts)
    private var allowSharedPosts = SharedPosts.defaultEnabled

    var body: some View {
        Form {
            notificationsSection
            linksSection
            appearanceSection
            allowedSurfacesSection
            footerSection
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }

    // MARK: - Sections

    /// How aggressively to notify on new DMs, plus the polling cadence that
    /// drives detection. Sound is only shown when banners actually fire.
    private var notificationsSection: some View {
        Section {
            Picker("Notify me about new messages", selection: levelBinding) {
                Text("Off").tag(NotificationLevel.off)
                Text("Dock badge only").tag(NotificationLevel.badgeOnly)
                Text("Banner alert").tag(NotificationLevel.standard)
            }

            if currentLevel.wantsBanners {
                Toggle("Play sound when a banner fires", isOn: $sound)
            }

            Picker("Check Instagram every", selection: intervalBinding) {
                Text("15 seconds").tag(PollingInterval.fast)
                Text("30 seconds").tag(PollingInterval.normal)
                Text("1 minute").tag(PollingInterval.slow)
                Text("2 minutes").tag(PollingInterval.slower)
            }
            .disabled(currentLevel == .off)

            Text(
                "InstaDM polls Instagram’s tab title (e.g. \u{201C}(3) Inbox • Instagram\u{201D}) to detect new "
                + "unread messages and update the dock badge. A faster interval notifies you sooner; "
                + "a slower interval uses slightly less battery."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
            Text("Notifications")
        }
    }

    /// External-browser routing for blocked link taps.
    private var linksSection: some View {
        Section {
            Toggle("Open links in default browser", isOn: $openLinksInExternalBrowser)

            Text(
                "When on, profile taps and shared links open in Safari (or your default browser) "
                + "instead of staying in-app. Turn it off to keep everything in InstaDM — blocked "
                + "links cancel silently. Login and account-recovery flows may still use your "
                + "browser when Instagram requires it."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
            Text("Links")
        }
    }

    /// Light / Dark / System override. Theme palette is fixed (Sage).
    private var appearanceSection: some View {
        Section {
            Picker("Color scheme", selection: schemeBinding) {
                ForEach(ColorSchemePreference.allCases) { pref in
                    Text(pref.displayName).tag(pref)
                }
            }

            Text(
                "Affects InstaDM’s own surfaces (this window, the tab bar). Instagram’s web view "
                + "follows its own theme — InstaDM doesn’t restyle it."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
            Text("Appearance")
        }
    }

    /// Opt-in non-DM surfaces. Each toggle is gated on its feature module's
    /// compile-time `available` flag, so deleting a feature also removes its
    /// setting without touching this view.
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
                Text(
                    "Each toggle exposes a non-DM Instagram surface. Off by default; the more you "
                    + "turn on, the larger the area the app reaches."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } header: {
                Text("Allowed surfaces")
            }
        }
    }

    private var footerSection: some View {
        Section {
            Text(
                "All settings are stored locally on this Mac. Nothing is sent anywhere except "
                + "Instagram itself."
            )
            .font(.footnote)
            .italic()
            .foregroundStyle(.secondary)
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

    private var schemeBinding: Binding<ColorSchemePreference> {
        Binding(
            get: { ColorSchemePreference(rawValue: schemePrefRaw) ?? .system },
            set: { schemePrefRaw = $0.rawValue }
        )
    }
}
