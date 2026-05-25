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

    /// Path prefixes on `*.instagram.com` that the app always permits,
    /// regardless of feature toggles.
    ///
    /// `/accounts/*` is **deliberately narrowed** to specific auth
    /// subpaths. A blanket `/accounts` would silently let in
    /// `/accounts/activity` (follow requests), `/accounts/edit`,
    /// `/accounts/notifications`, etc. — surfaces this app exists to hide.
    private static let alwaysAllowedPathPrefixes: [String] = [
        // Messaging — covers 1:1 DMs, group chats, and `/direct/new` compose.
        "/direct",

        // Auth surfaces. **Broadened to the entire `/accounts` tree** after
        // the narrowed list (login/onetap/password/signup/emailsignup/
        // check_email/logout) broke the login loop in practice on 2026-05-16
        // — Instagram's post-login redirect hits something else under
        // `/accounts/*` we hadn't enumerated, and our bounce-to-inbox sends
        // the user right back to login.
        //
        // Trade-off: this lets `/accounts/edit`, `/accounts/notifications`,
        // `/accounts/manage_access` etc. through if Instagram chrome links
        // to them. The Follow-Requests feature module still gates its tab
        // separately, so it remains "off by default" in the UI sense, but
        // the URL itself is now reachable if the user finds a link to it.
        //
        // To re-narrow safely later: log blocked URLs (add NSLog in the
        // navigation delegate), capture the real post-login redirect chain,
        // and enumerate the missing subpath. See [[Risks and Failure Modes]]
        // § "Highest-risk drift point" for the diagnostic recipe.
        "/accounts",

        // Security checkpoints (e.g. "we noticed an unusual login").
        "/challenge",

        // Page-internal endpoints. None are user-facing surfaces; the page
        // calls them as XHR/fetch/GraphQL. Blocking these breaks the inbox.
        "/api",
        "/graphql",
        "/ajax",
        "/static",
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

        // Base allowlist — messaging, auth, internal endpoints.
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
}
