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
        a[href^='/reels/'] { display: none !important; }
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

        init(homeURL: URL, tracksNotifications: Bool) {
            self.homeURL = homeURL
            self.tracksNotifications = tracksNotifications
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            // Source frame is non-nil per the WebKit API contract but its
            // .request.url can be nil for synthetic frames. Default to "not
            // from a DM" when unknown — strictest interpretation, safe.
            let sourcePath = navigationAction.sourceFrame.request.url?.path ?? ""
            let source = NavigationPolicy.Source(fromDirect: sourcePath.hasPrefix("/direct"))

            if NavigationPolicy.isAllowed(url, source: source) {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            handleBlocked(
                url: url,
                in: webView,
                navigationType: navigationAction.navigationType
            )
        }

        /// `window.open(...)` / `target="_blank"` clicks come through here.
        /// Route them to the user's default browser rather than opening a
        /// popup inside the app.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
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
               NavigationPolicy.isAllowed(currentURL) {
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
        }
    }
}
