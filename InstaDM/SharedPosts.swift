import Foundation

/// Single source of truth for the **opt-in "View posts/reels shared in DMs"
/// surface**.
///
/// When enabled, clicking a `/p/<id>/` or `/reel/<id>/` link **inside a DM**
/// opens the post in the same web view. Crucially, the navigation policy only
/// allows these URLs when the click's source frame is a `/direct/*` page —
/// so Instagram (or stray CSS) can't sneak the user onto a post from
/// elsewhere. Disabled, shared posts always open in Safari (the original
/// Phase 1 behavior).
///
/// ## How to disable the feature
///
/// Set `available = false`. The Settings toggle disappears, the navigation
/// policy ignores any stored preference, and links always open in Safari.
///
/// ## How to delete the feature permanently
///
/// Delete this file. `grep -r SharedPosts InstaDM/` lists the remaining call
/// sites (`NavigationPolicy.isAllowed`, `SettingsView`'s toggle, and the
/// matching `SettingsKey` line). Remove and the feature is gone.
enum SharedPosts {

    /// Compile-time master switch. `false` removes the feature entirely.
    ///
    /// **Currently `false`** — Instagram's DM web client renders most
    /// shared posts inline in the thread (no navigation event fires, so
    /// the toggle is a no-op). When it does navigate, it uses
    /// `target="_blank"` / `window.open` which routes through our
    /// `createWebViewWith` handler to Safari. The setting promised in-app
    /// rendering it can't reliably deliver. Flip back to `true` only after
    /// confirming the current IG DM client actually generates `/p/<id>/`
    /// main-frame navigations from inside `/direct/*`.
    static let available = false

    /// First-launch default. `true` because the most common DM action —
    /// "look at what my friend just sent me" — should just work without
    /// hunting through settings. The source-frame guard keeps this safe.
    static let defaultEnabled = true

    /// True when the feature is compiled in **and** the user has opted in.
    static var enabled: Bool {
        guard available else { return false }
        return UserDefaults.standard.object(forKey: SettingsKey.allowSharedPosts) as? Bool
            ?? defaultEnabled
    }

    /// Path prefixes the policy permits when `enabled` AND the click's
    /// source frame is in `/direct/*`. Anything outside these stays blocked.
    static let allowedPathPrefixes: [String] = [
        "/p",      // posts (/p/<shortcode>/)
        "/reel",   // single reel (/reel/<shortcode>/)
        "/reels",  // reel-detail pages (/reels/<shortcode>/)
        "/tv",     // IGTV (/tv/<shortcode>/)
    ]

    /// User-facing label for the Settings toggle.
    static let displayName = "Open shared posts in app"
}
