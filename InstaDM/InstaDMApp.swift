import SwiftUI

/// App entry point. Resolves the active palette and color scheme from
/// settings + the current OS appearance, then propagates them into every
/// scene's environment so the entire app re-paints instantly when either
/// changes.
@main
struct InstaDMApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @AppStorage(SettingsKey.themeID)         private var themeIDRaw    = ThemeID.sage.rawValue
    @AppStorage(SettingsKey.colorSchemePref) private var schemePrefRaw = ColorSchemePreference.system.rawValue

    @Environment(\.colorScheme) private var systemColorScheme

    var body: some Scene {
        WindowGroup("DMs") {
            ContentView()
                .modifier(ThemedScene(palette: palette, scheme: schemePref.preferredColorScheme))
        }
        // Default .automatic resizability lets the user grow the window beyond
        // the ContentView's min size (800x600). Don't switch to .contentSize —
        // that pins the window to the min and breaks the spec's "resizable".
        .commands {
            // Strip default "New Window" / "Open Recent" menu items —
            // a one-window app shouldn't pretend to support them.
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SettingsView()
                .modifier(ThemedScene(palette: palette, scheme: schemePref.preferredColorScheme))
        }
    }

    // MARK: - Resolved theme state

    private var themeID: ThemeID {
        ThemeID(rawValue: themeIDRaw) ?? .sage
    }

    private var schemePref: ColorSchemePreference {
        ColorSchemePreference(rawValue: schemePrefRaw) ?? .system
    }

    /// The concrete `ColorScheme` we'll resolve the palette against. Follows
    /// the OS when the user hasn't overridden it.
    private var resolvedScheme: ColorScheme {
        schemePref.preferredColorScheme ?? systemColorScheme
    }

    private var palette: Palette {
        themeID.palette(for: resolvedScheme)
    }
}

/// Applies the three theme-related modifiers each scene needs: environment
/// palette, scene-wide color scheme override, and accent tint for system
/// controls. Centralizing here means a future theme variable can't be added
/// to one scene and forgotten on the other.
private struct ThemedScene: ViewModifier {
    let palette: Palette
    let scheme: ColorScheme?

    func body(content: Content) -> some View {
        content
            .environment(\.theme, palette)
            .preferredColorScheme(scheme)
            .tint(palette.primary)
    }
}
