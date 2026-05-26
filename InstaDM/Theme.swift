import SwiftUI

// MARK: - Palette

/// The colors the app paints onto the surfaces it owns (tab tint, accent for
/// system controls). Instagram's web view is **not** themed — that surface
/// stays as Instagram renders it.
///
/// Settings used to override these onto its window background and section
/// labels; that was dropped in 1.0.3 in favour of macOS-native grouped Form
/// styling, which handles contrast and dark-mode flips correctly without
/// us reaching for explicit colors. The palette is now used for the tint
/// accent only.
struct Palette: Equatable {
    let background: Color
    let surface: Color
    let primary: Color
    let accent: Color
    let text: Color
    let textSecondary: Color
    let divider: Color
}

// MARK: - Theme

/// Sage — a calm, natural-green palette. The original spec shipped three
/// themes (Sage / Forest / Mist) but a one-window utility app didn't need
/// the variety: themes only touch Settings and the tab bar, and the
/// WebView (the visible majority of the app) is Instagram's own UI.
///
/// The enum survives as `enum ThemeID { case sage }` so the rest of the
/// codebase keeps reading `ThemeID.sage.palette(for: ...)` without an
/// architecture rewrite. Adding another palette later is a single new
/// case plus a `switch` arm in `palette(for:)`.
enum ThemeID: String, CaseIterable, Identifiable {
    case sage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sage: return "Sage"
        }
    }

    func palette(for scheme: ColorScheme) -> Palette {
        switch scheme {
        case .light:
            return Palette(
                background:    Color(hex: 0xF7F7F2),
                surface:       Color(hex: 0xF0F2EA),
                primary:       Color(hex: 0x6B8C5F),
                accent:        Color(hex: 0x4A6B3C),
                text:          Color(hex: 0x2A332A),
                textSecondary: Color(hex: 0x5C6B5A),
                divider:       Color(hex: 0xD9DDD0)
            )
        case .dark:
            return Palette(
                background:    Color(hex: 0x161A15),
                surface:       Color(hex: 0x1F241D),
                primary:       Color(hex: 0x9CB58F),
                accent:        Color(hex: 0xB8D1A8),
                text:          Color(hex: 0xE4E6DF),
                textSecondary: Color(hex: 0x8E948A),
                divider:       Color(hex: 0x2A3028)
            )
        @unknown default:
            return palette(for: .light)
        }
    }
}

// MARK: - Color scheme preference

enum ColorSchemePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// The concrete `ColorScheme` to apply, or `nil` to follow the OS.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Palette = ThemeID.sage.palette(for: .light)
}

extension EnvironmentValues {
    var theme: Palette {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Color hex helper

extension Color {
    /// Initialize from a 24-bit RGB integer, e.g. `0xF7F7F2`.
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
