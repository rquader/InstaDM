import SwiftUI
import WebKit
import AppKit

/// SwiftUI host for an embedded `WKWebView`. Reusable across the Messages
/// and Requests tabs by parameterizing the start URL and whether this
/// instance should drive notifications.
///
/// Navigation decisions all delegate to `NavigationPolicy.isAllowed`, with
/// the click's source frame passed along so source-gated opt-in surfaces
/// (e.g. `SharedPosts`) get the context they need.
struct WebView: NSViewRepresentable {

    /// The URL this web view loads on creation and rebounds to when a
    /// blocked JS-driven navigation needs a home.
    let startURL: URL

    /// When `true`, this web view registers with `NotificationManager` to
    /// drive the dock badge and notification banners off its
    /// `document.title`. Only the Messages tab does this — the Requests
    /// tab's title isn't the unread-count source of truth.
    let tracksNotifications: Bool

    init(startURL: URL = NavigationPolicy.inboxURL, tracksNotifications: Bool = true) {
        self.startURL = startURL
        self.tracksNotifications = tracksNotifications
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(homeURL: startURL, tracksNotifications: tracksNotifications)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()  // persistent cookies
        configuration.userContentController.addUserScript(Self.cosmeticHideNavCSS)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false

        webView.load(URLRequest(url: startURL))
        if tracksNotifications {
            NotificationManager.shared.attach(to: webView)
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) { }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // Only the notification-tracking instance should tear down the
        // shared manager. Otherwise a Requests-tab teardown would clobber
        // the Messages-tab's attachment.
        //
        // We pass `forWebView:` so that if SwiftUI re-creates the Messages
        // WebView (new attach → singleton points at the new view), an old
        // instance's dismantleNSView firing later can't unhook the new one.
        if coordinator.tracksNotifications {
            NotificationManager.shared.detach(forWebView: nsView)
        }
    }

    // MARK: - Cosmetic CSS

    /// Hides Instagram's left-rail Home / Explore / Reels links so the user
    /// isn't visually tempted toward surfaces this app exists to block.
    ///
    /// The real defense is `NavigationPolicy` — these selectors *will* drift
    /// when Instagram re-shuffles class names, and it's fine when they do.
    /// The user will see a "Home" link until selectors are updated; clicking
    /// it still gets blocked.
    private static let cosmeticHideNavCSS: WKUserScript = {
        let css = """
        a[href='/']:not([href*='direct']),
        a[href^='/explore/'],
        a[href^='/reels/'],
        a[href*='notifications'],
        a[href^='/accounts/activity'],
        a[href^='/accounts/edit/'],
        a[href^='/accounts/manage'] { display: none !important; }
        """
        // JSON-encode the CSS into a JS string literal so a future backtick
        // or `$` in the CSS can't break the surrounding template.
        let cssLiteral = javaScriptStringLiteral(for: css)
        let source = """
        (function() {
            var s = document.createElement('style');
            s.appendChild(document.createTextNode(\(cssLiteral)));
            document.head.appendChild(s);
        })();
        """
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }()

    /// Encodes a Swift string as a JavaScript string literal (including the
    /// surrounding quotes) by routing it through `JSONSerialization`. JSON
    /// string syntax is a strict subset of JavaScript string literal syntax,
    /// so the result is always safe to splice into a JS source.
    private static func javaScriptStringLiteral(for string: String) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: [string],
                options: [.fragmentsAllowed]
            ),
            let json = String(data: data, encoding: .utf8),
            json.hasPrefix("["), json.hasSuffix("]")
        else {
            return "\"\""
        }
        // JSON output is `["..."]`; strip the brackets to get the literal.
        return String(json.dropFirst().dropLast())
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {

        /// The URL this coordinator rebounds blocked JS-driven navigations
        /// to. For Messages it's the inbox; for Requests it's the follow-
        /// requests URL. Set once at init from the parent `WebView`.
        let homeURL: URL

        /// Carries the parent `WebView`'s `tracksNotifications` so
        /// `dismantleNSView` only tears down the manager for the instance
        /// that attached it.
        let tracksNotifications: Bool

        /// Timestamp of the most recent bounce-to-`homeURL`. Read by
        /// `handleBlocked` as a loop guard: if `homeURL` itself triggers
        /// a server-side redirect into a blocked URL, the first bounce
        /// will fire again immediately, and again, and again. The
        /// cooldown breaks that cycle. See `bounceCooldown` for the
        /// window length and the comment in `handleBlocked` for the full
        /// reasoning.
        private var lastBounceAt: Date?

        /// Minimum gap between consecutive bounces to `homeURL`. If a
        /// second bounce would fire inside this window, we abandon
        /// instead — the page is genuinely unreachable under the current
        /// policy, and looping wastes CPU + battery without ever
        /// resolving. Five seconds is short enough that a transient
        /// network blip won't permanently strand the user (they can
        /// switch tabs and back, or relaunch) and long enough that the
        /// redirect chain from a 302-into-blocked-URL pattern will have
        /// finished firing.
        private let bounceCooldown: TimeInterval = 5.0

        /// Set when the user submits credentials; post-login blocked redirects
        /// are only allowed inside this window so idle prefetch on the login
        /// page doesn't trigger a premature inbox load.
        private var authSubmitAt: Date?

        /// Set when we deliberately allowed a post-login redirect to a blocked
        /// URL so `didFinish` can route to the inbox once `sessionid` exists.
        private var awaitingInboxHandoff = false

        init(homeURL: URL, tracksNotifications: Bool) {
            self.homeURL = homeURL
            self.tracksNotifications = tracksNotifications
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.safeRequest?.url else {
                // KVC can return nil during login AJAX on macOS 26. Allow only
                // in auth context — a global allow lets profile/feed URLs load
                // and stay in the web view (full Instagram access).
                if isAuthSource(navigationAction) || isOnAuthSurface(webView) {
                    authSubmitAt = Date()
                    decisionHandler(.allow)
                    return
                }
                decisionHandler(.cancel)
                return
            }

            // WebKit's header declares both `WKNavigationAction.request`
            // and `WKFrameInfo.request` as non-nullable, but on
            // macOS 26 (Tahoe) the ObjC layer empirically hands back
            // nil for synthetic / session-restored frames. Direct
            // Swift access traps in
            // `URLRequest._unconditionallyBridgeFromObjectiveC`, which
            // crashed the app with `EXC_BREAKPOINT` on the first
            // `decidePolicyForNavigationAction` before any UI rendered.
            // `safeRequest` (defined at file scope below) reads the
            // property via KVC, which returns an honestly-optional
            // `Any?` and round-trips cleanly to `URLRequest?`. A nil
            // source frame request falls back to "not from a DM" —
            // strictest interpretation, safe.
            let sourcePath = navigationAction.sourceFrame.safeRequest?.url?.path ?? ""
            let source = NavigationPolicy.Source(
                fromDirect: NavigationPolicy.isDirectMessagingPath(sourcePath)
            )

            if isOnAuthSurface(webView) || isAuthSource(navigationAction) {
                noteAuthSubmit(navigationAction, url: url)
            }

            if NavigationPolicy.isAllowed(url, source: source) {
                if !isOnAuthSurface(webView),
                   !isAuthSource(navigationAction),
                   !NavigationPolicy.isInAppUserSurface(url.path, source: source) {
                    decisionHandler(.cancel)
                    webView.stopLoading()
                    return
                }
                decisionHandler(.allow)
                return
            }

            // Blocked link tapped while viewing DMs. Group-chat participant
            // headers often report a non-/direct source frame even though the
            // web view is on /direct/t/… — fall back to the current URL.
            if isInDirectContext(webView, navigationAction: navigationAction),
               navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            // Post-login 302s target blocked URLs (`/`, etc.). Allow the response
            // to commit Set-Cookie, then route to inbox in `didFinish` once a
            // session cookie exists. Use source-frame auth detection — during
            // redirects `webView.url` is often still nil/stale, which is why
            // checking only `isOnAuthSurface(webView)` brought the spinner back.
            if navigationAction.navigationType != .linkActivated,
               shouldAllowAuthRedirect(
                   webView,
                   navigationAction: navigationAction,
                   url: url
               ) {
                if authSubmitAt == nil { authSubmitAt = Date() }
                awaitingInboxHandoff = true
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
            webView.stopLoading()
            handleBlocked(
                url: url,
                in: webView,
                navigationType: navigationAction.navigationType
            )
        }

        /// Cancel blocked main-frame **responses** so HTML never downloads.
        /// Action-level `.cancel` alone still lets the page flash for seconds
        /// before `didFinish` fires — this is the early exit.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            guard navigationResponse.isForMainFrame,
                  let url = navigationResponse.response.url else {
                decisionHandler(.allow)
                return
            }

            if awaitingInboxHandoff {
                decisionHandler(.allow)
                return
            }

            let fromDirect = NavigationPolicy.isDirectMessagingPath(
                webView.url?.path ?? ""
            )
            let source = NavigationPolicy.Source(fromDirect: fromDirect)
            if NavigationPolicy.isAllowed(url, source: source) {
                if !isOnAuthSurface(webView),
                   !NavigationPolicy.isInAppUserSurface(url.path, source: source) {
                    decisionHandler(.cancel)
                    webView.stopLoading()
                    return
                }
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
            webView.stopLoading()
        }

        /// `window.open(...)` / `target="_blank"` clicks come through here.
        /// Route them to the user's default browser rather than opening a
        /// popup inside the app. `request` goes through `safeRequest`
        /// for the same nullability-mismatch reason as
        /// `decidePolicyFor` above.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.safeRequest?.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        private func handleBlocked(
            url: URL,
            in webView: WKWebView,
            navigationType: WKNavigationType
        ) {
            // User-initiated link click to a non-allowed URL → open in
            // Safari so the "friend shared something we don't render" flow
            // still works gracefully.
            if navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                return
            }
            // If we're already on an allowed page, do nothing — just cancel
            // the unwanted navigation. Bouncing to homeURL when we're
            // already on a fine page (the inbox, a thread, the requests
            // tab's follow-requests page) causes an infinite reload loop:
            // Instagram's page JS triggers a blocked nav → we reload home →
            // home's JS triggers another blocked nav → we reload again, etc.
            //
            // This silent-cancel is the right move: the unwanted nav is
            // already cancelled, and there's no reason to force a refresh
            // just because something tried to take us somewhere we won't go.
            if let currentURL = webView.url,
               NavigationPolicy.isAllowed(currentURL),
               NavigationPolicy.isInAppUserSurface(currentURL.path) {
                // Silent-cancel on the login page is what causes the infinite
                // spinner when a post-login redirect gets blocked. If we're
                // mid-auth (or just submitted credentials), try routing to the
                // inbox once session cookies exist — they may already be set on
                // the login POST even when the follow-up redirect was cancelled.
                if isOnAuthSurface(webView) {
                    routeToInboxWhenAuthenticated(in: webView)
                }
                return
            }
            // Loop guard: a second layer of defense for the case the
            // above check can't catch — when `homeURL` itself triggers a
            // server-side 302 to a blocked URL. In that scenario
            // `webView.url` is still nil/empty (the redirect target
            // never committed), so the "already on an allowed page"
            // check above lets us through, and we'd bounce back to
            // `homeURL` → 302 → blocked → bounce → forever.
            //
            // If we bounced within the cooldown window, the bounce
            // target is most likely the source of the redirect we just
            // blocked. A second bounce would just reproduce the loop.
            // Abandon — leave the web view in its empty state. The user
            // can switch tabs or relaunch; we don't burn CPU spinning.
            // Historical symptom this prevents: the Requests tab
            // infinite-reloading on `/accounts/activity/?followRequests=1`
            // when Instagram 302s that path into a non-allowlisted URL.
            if let last = lastBounceAt,
               Date().timeIntervalSince(last) < bounceCooldown {
                return
            }
            // We're on an unknown / non-allowed page (typically the
            // initial blank load, or a state we got into during a
            // redirect chain). Land on homeURL. Record the timestamp
            // first so a back-to-back blocked redirect can detect the
            // loop and bail. Async to avoid reentering the decision
            // handler synchronously.
            lastBounceAt = Date()
            DispatchQueue.main.async { [homeURL] in
                webView.load(URLRequest(url: homeURL))
            }
        }

        /// Clear the bounce-cooldown timestamp on any successful
        /// navigation. A successful load means we're no longer in a
        /// stuck-loop state and a future blocked redirect should be
        /// allowed to bounce home again. Without this, a user who hit
        /// the loop guard, then navigated away (e.g. switched tabs) and
        /// back, would inherit a stale timestamp and bouncing might be
        /// suppressed when it shouldn't be.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            lastBounceAt = nil

            guard let current = webView.url else { return }

            if NavigationPolicy.isAllowed(current) {
                let path = current.path
                let fromDirect = NavigationPolicy.isDirectMessagingPath(path)
                let source = NavigationPolicy.Source(fromDirect: fromDirect)
                if !isOnAuthSurface(webView),
                   !NavigationPolicy.isInAppUserSurface(path, source: source) {
                    webView.stopLoading()
                    returnToHome(in: webView)
                    return
                }
                if !isOnAuthSurface(webView) {
                    authSubmitAt = nil
                    awaitingInboxHandoff = false
                }
                return
            }

            // Landed on a blocked surface (profile, feed, explore, …).
            if awaitingInboxHandoff {
                awaitingInboxHandoff = false
                routeToInboxWhenAuthenticated(in: webView)
                return
            }

            // Never leave the user browsing full Instagram in-app.
            webView.stopLoading()
            returnToHome(in: webView)
        }

        /// Loads `homeURL` when the web view committed to a blocked page.
        private func returnToHome(in webView: WKWebView) {
            DispatchQueue.main.async { [homeURL, self] in
                guard let url = webView.url else { return }
                let path = url.path
                if NavigationPolicy.isInAppUserSurface(path)
                    || isOnAuthSurface(webView) {
                    return
                }
                webView.stopLoading()
                webView.load(URLRequest(url: homeURL))
            }
        }

        private func noteAuthSubmit(_ navigationAction: WKNavigationAction, url: URL) {
            if navigationAction.navigationType == .formSubmitted {
                authSubmitAt = Date()
                return
            }
            guard navigationAction.safeRequest?.httpMethod == "POST" else { return }
            let path = url.path
            if path.hasPrefix("/accounts/login") || path.contains("/accounts/login/") {
                authSubmitAt = Date()
            }
        }

        private func shouldAllowAuthRedirect(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            url: URL
        ) -> Bool {
            guard navigationAction.navigationType != .linkActivated else { return false }
            guard isOnAuthSurface(webView) || isAuthSource(navigationAction) else {
                return false
            }
            let path = url.path
            // Only the post-login feed-root hop — never profiles, explore, etc.
            return path.isEmpty || path == "/"
        }

        /// True when the user is viewing DMs — uses source frame **or** the
        /// committed web-view URL. Group-chat UI often fails the source check.
        private func isInDirectContext(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction
        ) -> Bool {
            let sourcePath = navigationAction.sourceFrame.safeRequest?.url?.path ?? ""
            if NavigationPolicy.isDirectMessagingPath(sourcePath) { return true }
            if let path = webView.url?.path,
               NavigationPolicy.isDirectMessagingPath(path) {
                return true
            }
            return false
        }

        private func isAuthSource(_ navigationAction: WKNavigationAction) -> Bool {
            let sourcePath = navigationAction.sourceFrame.safeRequest?.url?.path ?? ""
            let sourceHost = navigationAction.sourceFrame.safeRequest?.url?.host ?? ""
            if sourceHost == "accounts.instagram.com" { return true }
            return sourcePath.hasPrefix("/accounts")
                || sourcePath.hasPrefix("/challenge")
        }

        /// Loads `homeURL` only after Instagram's `sessionid` cookie is visible.
        /// Loading the inbox without it produces the empty-login flash.
        private func routeToInboxWhenAuthenticated(in webView: WKWebView, attempt: Int = 0) {
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            cookieStore.getAllCookies { [homeURL] cookies in
                let hasSession = cookies.contains { cookie in
                    guard cookie.domain.contains("instagram"), !cookie.value.isEmpty else {
                        return false
                    }
                    return cookie.name == "sessionid" || cookie.name == "ds_user_id"
                }
                DispatchQueue.main.async {
                    if hasSession {
                        self.authSubmitAt = nil
                        if let current = webView.url,
                           NavigationPolicy.isAllowed(current),
                           NavigationPolicy.isDirectMessagingPath(current.path) {
                            return
                        }
                        webView.load(URLRequest(url: homeURL))
                        return
                    }
                    guard attempt < 8 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.routeToInboxWhenAuthenticated(in: webView, attempt: attempt + 1)
                    }
                }
            }
        }

        /// True when the web view is mid-login or mid-challenge.
        private func isOnAuthSurface(_ webView: WKWebView) -> Bool {
            guard let current = webView.url else { return false }
            if current.host == "accounts.instagram.com" { return true }
            let path = current.path
            return path.hasPrefix("/accounts") || path.hasPrefix("/challenge")
        }
    }
}

// MARK: - WebKit nullability workaround
//
// WebKit ships its public Objective-C headers with `request` declared
// as non-nullable on both `WKNavigationAction` and `WKFrameInfo`:
//
//     @property (nonatomic, readonly, copy) NSURLRequest *request;
//
// (no `nullable`, and the surrounding `NS_ASSUME_NONNULL_BEGIN` makes
// the absence of an annotation imply non-null). Swift therefore
// imports it as plain `URLRequest`, which means dot-access compiles
// without an optional but goes through
// `URLRequest._unconditionallyBridgeFromObjectiveC` at runtime — and
// that bridge traps with `EXC_BREAKPOINT` when the underlying ObjC
// pointer is nil.
//
// On macOS 26 (Tahoe) the runtime *does* hand back nil for synthetic
// frames during the very first `decidePolicyForNavigationAction`,
// crashing the app on launch before any UI renders. The header
// annotation is, in practice, wrong for that case.
//
// The cleanest workaround that doesn't require an ObjC bridge file:
// read the property through KVC (`value(forKey:)`), which returns
// `Any?` regardless of the property's declared nullability and lets
// us cast to `URLRequest?` honestly.

private extension WKNavigationAction {
    /// `request`, read via KVC so a runtime-nil value doesn't trap
    /// the IUO bridge. Use this instead of the direct property.
    var safeRequest: URLRequest? {
        guard let value = (self as NSObject).value(forKey: "request") else {
            return nil
        }
        if let request = value as? URLRequest { return request }
        if let nsRequest = value as? NSURLRequest { return nsRequest as URLRequest }
        return nil
    }
}

private extension WKFrameInfo {
    /// `request`, read via KVC so a runtime-nil value doesn't trap
    /// the IUO bridge. Use this instead of the direct property.
    var safeRequest: URLRequest? {
        guard let value = (self as NSObject).value(forKey: "request") else {
            return nil
        }
        if let request = value as? URLRequest { return request }
        if let nsRequest = value as? NSURLRequest { return nsRequest as URLRequest }
        return nil
    }
}
