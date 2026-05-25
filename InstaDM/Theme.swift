import SwiftUI

// MARK: - Palette

/// The colors the app paints onto every surface it owns (Settings window,
/// system control tints). Instagram's web view is *not* themed in Phase 1 —
/// that surface stays as Instagram renders it.
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

/// Three calm, natural-green palettes. Hex values come from the design spec
/// in `UI Design and Theming.md`; each is verified for WCAG AA text contrast
/// in both light and dark variants.
enum ThemeID: String, CaseIterable, Identifiable {
    case sage, forest, mist

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sage:   return "Sage"
        case .forest: return "Forest"
        case .mist:   return "Mist"
        }
    }

    func palette(for scheme: ColorScheme) -> Palette {
        switch (self, scheme) {

        // MARK: Sage
        case (.sage, .light):
            return Palette(
                background:    Color(hex: 0xF7F7F2),
                surface:       Color(hex: 0xF0F2EA),
                primary:       Color(hex: 0x6B8C5F),
                accent:        Color(hex: 0x4A6B3C),
                text:          Color(hex: 0x2A332A),
                textSecondary: Color(hex: 0x5C6B5A),
                divider:       Color(hex: 0xD9DDD0)
            )
        case (.sage, .dark):
            return Palette(
                background:    Color(hex: 0x161A15),
                surface:       Color(hex: 0x1F241D),
                primary:       Color(hex: 0x9CB58F),
                accent:        Color(hex: 0xB8D1A8),
                text:          Color(hex: 0xE4E6DF),
                textSecondary: Color(hex: 0x8E948A),
                divider:       Color(hex: 0x2A3028)
            )

        // MARK: Forest
        case (.forest, .light):
            return Palette(
                background:    Color(hex: 0xF2EFE5),
                surface:       Color(hex: 0xEAE6D7),
                primary:       Color(hex: 0x2D5A3D),
                accent:        Color(hex: 0x1B4332),
                text:          Color(hex: 0x1B2A1B),
                textSecondary: Color(hex: 0x4A5A4A),
                divider:       Color(hex: 0xC4BFB0)
            )
        case (.forest, .dark):
            return Palette(
                background:    Color(hex: 0x0E1612),
                surface:       Color(hex: 0x15201A),
                primary:       Color(hex: 0x4A8067),
                accent:        Color(hex: 0x6FA88B),
                text:          Color(hex: 0xD8D4C6),
                textSecondary: Color(hex: 0x7A8579),
                divider:       Color(hex: 0x1F2A24)
            )

        // MARK: Mist
        case (.mist, .light):
            return Palette(
                background:    Color(hex: 0xF4F6F1),
                surface:       Color(hex: 0xE9EDE3),
                primary:       Color(hex: 0x88A786),
                accent:        Color(hex: 0x5F8A6A),
                text:          Color(hex: 0x2E3A2E),
                textSecondary: Color(hex: 0x5E6B5E),
                divider:       Color(hex: 0xD5DCCB)
            )
        case (.mist, .dark):
            return Palette(
                background:    Color(hex: 0x131914),
                surface:       Color(hex: 0x1B2219),
                primary:       Color(hex: 0xA8C8A8),
                accent:        Color(hex: 0xC8E0C8),
                text:          Color(hex: 0xE8ECE3),
                textSecondary: Color(hex: 0x8E948A),
                divider:       Color(hex: 0x262E26)
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
