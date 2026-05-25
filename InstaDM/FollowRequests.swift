import Foundation

/// Single source of truth for the **opt-in "Follow Requests" surface**.
///
/// When enabled, the app gains a second main-window tab that loads Instagram's
/// follow-requests page, and the navigation policy permits its URLs. Disabled,
/// none of those URLs are reachable and the tab is hidden — even if a stale
/// `UserDefaults` value somewhere still says "on."
///
/// ## How to disable the feature
///
/// Flip a single compile-time switch:
///
/// ```swift
/// static let available = false
/// ```
///
/// That alone removes the Settings toggle, hides the tab, and makes
/// `NavigationPolicy` reject the URLs unconditionally.
///
/// ## How to delete the feature permanently
///
/// Delete this file. Then `grep -r FollowRequests InstaDM/` will list every
/// remaining call site (a handful: `NavigationPolicy.isAllowed`, `ContentView`'s
/// tab branch, `SettingsView`'s toggle, and the matching `SettingsKey` line).
/// Remove those and the feature is gone with no orphan strings or stored
/// preferences ever touched again.
enum FollowRequests {

    /// Compile-time master switch. `false` removes the feature entirely.
    ///
    /// **Currently `true`** — the historical infinite-reload symptom
    /// (`/accounts/activity/?followRequests=1` 302ing into a blocked URL)
    /// is now defended against in `WebView.Coordinator.handleBlocked` by a
    /// bounce-cooldown loop guard. Worst case if Instagram's URL is
    /// stale: the tab shows a blank web view instead of looping. To
    /// disable the feature without losing the code, flip this to
    /// `false`. To delete it permanently, delete this file and follow
    /// the `grep -r FollowRequests InstaDM/` cleanup recipe below.
    ///
    /// If the user reports the Requests tab is blank, verify the URL
    /// below by opening it in Safari while logged in. Instagram has
    /// moved follow-requests pages historically; update `url` to match
    /// what currently renders.
    static let available = true

    /// First-launch default for the runtime toggle. `false` matches the
    /// app's "DMs only" stance — the user has to actively opt in via
    /// Settings before this surface appears.
    static let defaultEnabled = false

    /// True when the feature is compiled in **and** the user has opted in.
    /// Read this from anywhere that conditionally enables follow-request
    /// behavior (tab visibility, navigation policy, etc.). Re-evaluates on
    /// every access so a settings change is reflected immediately.
    static var enabled: Bool {
        guard available else { return false }
        return UserDefaults.standard.object(forKey: SettingsKey.allowFollowRequests) as? Bool
            ?? defaultEnabled
    }

    /// URL the "Requests" tab loads. Verify this path in Safari before
    /// changing — Instagram has moved follow-requests pages historically.
    static let url = URL(string: "https://www.instagram.com/accounts/activity/?followRequests=1")!

    /// Path prefixes `NavigationPolicy` permits when `enabled`. Keep narrow:
    /// `/accounts/activity` covers the page itself plus its AJAX-driven
    /// approve/deny round-trips.
    static let allowedPathPrefixes: [String] = [
        "/accounts/activity",
    ]

    /// User-facing label for the tab + Settings toggle.
    static let displayName = "Requests"

    /// SF Symbol for the tab item.
    static let symbolName = "person.crop.circle.badge.plus"
}
