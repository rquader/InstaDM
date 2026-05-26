import Foundation

/// Decides whether the embedded `WKWebView` may navigate to a given URL.
///
/// The policy is **layered**:
///
/// 1. A small, always-on **base allowlist** covers messaging (`/direct/*`),
///    the minimum auth surfaces a real user needs to log in / recover their
///    account, and the internal endpoints (`/api`, `/graphql`, `/ajax`,
///    `/static`) the page itself calls.
///
/// 2. **Opt-in surfaces** live in their own feature modules and only layer
///    extra paths on top when *both* the feature is compiled in *and* the
///    user has turned it on in Settings:
///     - `FollowRequests` — adds `/accounts/activity` access
///     - `SharedPosts`    — adds `/p/*`, `/reel/*`, `/tv/*` access, but
///                          only when the click's source frame is in `/direct/*`
///
/// Each feature owns its URLs and prefixes in its own file. This file is
/// the place that decides; the feature files are the place to extend. To
/// remove or disable an opt-in surface, flip its `available` flag (or delete
/// its file) — this file's logic survives without modification.
enum NavigationPolicy {

    /// URL the Messages tab loads on launch and any URL the policy rebounds
    /// blocked JS-driven navigations to.
    static let inboxURL = URL(string: "https://www.instagram.com/direct/inbox/")!

    // MARK: - Always-on allowlist

    /// Hosts that participate in Instagram's auth / messaging surface.
    /// `accounts.instagram.com` is a pure-auth host — membership alone is
    /// enough; we don't path-check it.
    private static let allowedHosts: Set<String> = [
        "www.instagram.com",
        "instagram.com",
        "accounts.instagram.com",
    ]

    /// Auth account subpaths only — not a blanket `/accounts` prefix.
    private static let authAccountPathPrefixes: [String] = [
        "/accounts/login",
        "/accounts/onetap",
        "/accounts/password",
        "/accounts/signup",
        "/accounts/emailsignup",
        "/accounts/check_email",
        "/accounts/logout",
        "/accounts/confirm",
        "/accounts/access",
        "/accounts/account_recovery",
        "/accounts/username",
    ]

    /// Path prefixes on `*.instagram.com` that the app always permits,
    /// regardless of feature toggles.
    ///
    /// `/accounts/*` is **deliberately narrowed** to specific auth
    /// subpaths via `authAccountPathPrefixes`. A blanket `/accounts` would
    /// silently let in `/accounts/activity`, `/accounts/notifications`, etc.
    private static let alwaysAllowedPathPrefixes: [String] = [
        // Security checkpoints (e.g. "we noticed an unusual login").
        "/challenge",

        // Page-internal endpoints. None are user-facing surfaces; the page
        // calls them as XHR/fetch/GraphQL. Blocking these breaks the inbox.
        "/api",
        "/graphql",
        "/ajax",
        "/static",
    ]

    // MARK: - JS guard allowlists (per-tab scope)

    /// Path prefixes that the document-start JS guard in
    /// `WebView.spaNavigationGuardScript` permits **regardless of which
    /// tab hosts the web view** — auth, challenge, and internal XHR
    /// endpoints. Without these, the page can't authenticate or fire its
    /// own AJAX. Tabs add their feature-specific prefixes on top.
    static let jsCommonAllowedPathPrefixes: [String] =
        authAccountPathPrefixes + alwaysAllowedPathPrefixes

    /// JS-guard allowlist for the Messages tab — direct-messaging surfaces.
    ///
    /// Mirrors `isDirectMessagingPath`. If you add a DM subpath here,
    /// extend `isDirectMessagingPath` to match (and vice versa) or the
    /// click-layer JS guard will fall out of sync with the URL-layer
    /// Swift policy: anchor clicks to the new surface would be blocked
    /// at the capture phase even though `decidePolicyFor` would allow
    /// them, and the new surface would simply do nothing in the UI.
    static let jsMessagesTabAllowedPathPrefixes: [String] = [
        "/direct/inbox",
        "/direct/t/",
        "/direct/new",
    ]

    // MARK: - Source context

    /// Information about where a navigation originated. Used to permit
    /// shared-post URLs only when the click came from inside a DM thread.
    struct Source {
        /// `true` iff the click/navigation originated from a `/direct/*` page.
        let fromDirect: Bool

        /// Used when the source frame is unknown (e.g. the very first load).
        /// Treated as "not from a DM" — the strictest interpretation.
        static let none = Source(fromDirect: false)
    }

    // MARK: - Decision

    /// Decide whether the embedded web view may navigate to `url`.
    /// Pass the navigation's source context where available; `.none` is a
    /// safe default that just won't permit source-gated opt-in surfaces.
    static func isAllowed(_ url: URL, source: Source = .none) -> Bool {
        guard let host = url.host, allowedHosts.contains(host) else {
            return false
        }

        // accounts.instagram.com only serves auth endpoints; host alone is enough.
        if host == "accounts.instagram.com" { return true }

        let path = url.path

        // Bare "/" is the feed. Always block. Post-login Instagram occasionally
        // redirects through "/"; the WebView coordinator catches the bounce
        // and reroutes to the tab's home URL.
        if path.isEmpty || path == "/" { return false }

        if isDirectMessagingPath(path) {
            return true
        }

        if pathMatches(path, anyOf: authAccountPathPrefixes) {
            return true
        }

        // Base allowlist — challenge + internal endpoints.
        if pathMatches(path, anyOf: alwaysAllowedPathPrefixes) {
            return true
        }

        // Opt-in: follow requests. Gated by compile-time flag + Settings toggle.
        if FollowRequests.enabled,
           pathMatches(path, anyOf: FollowRequests.allowedPathPrefixes) {
            return true
        }

        // Opt-in: shared posts. Additionally requires the click to have come
        // from inside a DM so Instagram chrome can't silently route the user
        // onto a post-scroll surface.
        if SharedPosts.enabled, source.fromDirect,
           pathMatches(path, anyOf: SharedPosts.allowedPathPrefixes) {
            return true
        }

        return false
    }

    /// User-facing surfaces the web view should stay on after login.
    /// Auth paths and internal XHR endpoints are allowed for loading but
    /// should not persist as the main document.
    static func isInAppUserSurface(_ path: String, source: Source = .none) -> Bool {
        if isDirectMessagingPath(path) { return true }
        if pathMatches(path, anyOf: authAccountPathPrefixes) { return true }
        if pathMatches(path, anyOf: ["/challenge"]) { return true }
        if FollowRequests.enabled,
           pathMatches(path, anyOf: FollowRequests.allowedPathPrefixes) {
            return true
        }
        if SharedPosts.enabled, source.fromDirect,
           pathMatches(path, anyOf: SharedPosts.allowedPathPrefixes) {
            return true
        }
        return false
    }

    /// Main document was outside inbox/threads/auth (profile, feed, stories, …).
    static func isOutsideDMSurface(_ path: String) -> Bool {
        if isDirectMessagingPath(path) { return false }
        if isInAppUserSurface(path) { return false }
        return true
    }

    /// Background hops IG fires while you're already on DMs (`/`, explore,
    /// account-linking prefetch, …). Cancel silently — never `stopLoading()`.
    static func isIncidentalBlockedPrefetch(_ url: URL) -> Bool {
        if isOffPlatformURL(url) { return true }
        guard let host = url.host, allowedHosts.contains(host) else { return false }
        let path = url.path
        if path.isEmpty || path == "/" { return true }
        if path == "/explore" || path.hasPrefix("/explore/") { return true }
        if path.hasPrefix("/reels") { return true }
        if path.contains("notifications") { return true }
        if path.hasPrefix("/accounts/manage") { return true }
        if path.hasPrefix("/accounts/link") { return true }
        if path.hasPrefix("/accounts/connected") { return true }
        if path.contains("meta") && path.hasPrefix("/accounts") { return true }
        return false
    }

    /// Non-Instagram hosts (Facebook/Meta account sync, etc.).
    static func isOffPlatformURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return !allowedHosts.contains(host)
    }

    /// `/{username}/` — the usual one-click profile escape from a DM thread.
    static func isProfilePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 1 else { return false }
        return isLikelyUsernameSegment(parts[0])
    }

    /// Blocked in-app page (profile, explore page, …) — not auth/XHR/prefetch.
    static func isBlockedInAppChrome(_ url: URL, source: Source = .none) -> Bool {
        if isAllowed(url, source: source) { return false }
        if isIncidentalBlockedPrefetch(url) { return false }
        return true
    }

    /// Main-frame document committed outside DMs — always bounce back (feed,
    /// profile, bare `/direct` minimize shell, stories, …). Unlike
    /// `isIncidentalBlockedPrefetch`, which only applies to cancelled background hops.
    static func shouldRecoverFromMainDocument(_ url: URL, source: Source = .none) -> Bool {
        guard let host = url.host, allowedHosts.contains(host) else { return true }
        let path = url.path
        if path.isEmpty || path == "/" { return true }
        if path == "/direct" || path == "/direct/" { return true }
        if isProfilePath(path) { return true }
        if isDirectMessagingPath(path) { return false }
        if isInAppUserSurface(path, source: source) { return false }
        if isAllowed(url, source: source) { return false }
        return true
    }

    /// DM surfaces the app intentionally exposes — not every `/direct/…` path.
    /// Group-chat sender links can route to other `/direct/…` URLs that render
    /// full Instagram; those must stay blocked. Bare `/direct` is the minimized-
    /// messenger shell and renders full IG — not allowed.
    static func isDirectMessagingPath(_ path: String) -> Bool {
        if path.hasPrefix("/direct/inbox") { return true }
        if path.hasPrefix("/direct/t/") { return true }
        if path.hasPrefix("/direct/new") { return true }
        return false
    }

    /// Matches `path` against any of `prefixes` on a **directory boundary**.
    ///
    /// Plain `path.hasPrefix("/p")` matches `/profile/`, `/privacy/`,
    /// `/press/...` — surfaces this app exists to hide. We require either
    /// an exact match or a `/`-terminated prefix so `/p` only matches `/p`
    /// or `/p/<shortcode>/`, never `/profile/<user>/`. Same logic guards
    /// every other prefix: `/direct` no longer accidentally matches
    /// `/directory`, `/api` doesn't match `/api-status`, and the narrowed
    /// `/accounts/login` doesn't match a hypothetical `/accounts/login_aux`.
    private static func pathMatches(_ path: String, anyOf prefixes: [String]) -> Bool {
        prefixes.contains { prefix in
            path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    /// Reserved first path segments — not profile usernames.
    private static let reservedTopLevelSegments: Set<String> = [
        "direct", "accounts", "explore", "reels", "p", "tv", "stories",
        "about", "legal", "api", "graphql", "static", "challenge",
        "directory", "session", "nametag", "web", "developer", "privacy",
        "terms", "lite",
    ]

    private static func isLikelyUsernameSegment(_ segment: String) -> Bool {
        guard !segment.isEmpty,
              !reservedTopLevelSegments.contains(segment.lowercased()) else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
        return segment.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
