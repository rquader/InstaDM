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
        configuration.userContentController.addUserScript(Self.spaNavigationGuardJS)
        configuration.userContentController.addUserScript(Self.cosmeticHideNavCSS)
        configuration.userContentController.add(
            context.coordinator,
            name: Self.authHandoffMessageHandler
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.webView = webView
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
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: authHandoffMessageHandler
        )
    }

    /// JS → Swift bridge name for post-login SPA handoff (must match the
    /// string in `spaNavigationGuardJS`).
    private static let authHandoffMessageHandler = "instaDMAuthHandoff"

    // MARK: - SPA navigation guard

    /// Document-start guard against Instagram SPA navigation patterns that
    /// no Swift-side URL policy can see.
    ///
    /// Two leak classes URL policy can't catch on its own:
    ///   - **Profile click while DMs are minimized.** Instagram's bundle
    ///     intercepts the click, calls `preventDefault()` itself, then
    ///     `history.pushState('/<username>/')` and renders the profile in
    ///     React. No `decidePolicyFor` fires — there is no navigation
    ///     event the Swift layer can vote on, so `NavigationPolicy.isAllowed`
    ///     never gets to refuse the URL.
    ///   - **Minimize messenger.** A `pushState('/direct')` or `pushState('/')`
    ///     flips SPA state to render the feed under a small messenger
    ///     bubble. Same story — no navigation event.
    ///
    /// We defend at the JavaScript layer, before React's delegated click
    /// handler runs:
    ///   1. **Capture-phase click listener** on `document`. Any `<a>` whose
    ///      `href` resolves to a non-DM path gets `preventDefault()` +
    ///      `stopImmediatePropagation()` — which also prevents React from
    ///      ever seeing the click. Registered at `documentStart` so we
    ///      precede any listener IG installs from its bundle.
    ///   2. **Wraps `history.pushState` / `history.replaceState`** to
    ///      silently drop URL changes targeting non-DM paths. IG's
    ///      bundle reads `history.pushState` AFTER us, so it gets the
    ///      wrapped version.
    ///
    /// Allowed prefixes mirror `NavigationPolicy.isDirectMessagingPath` +
    /// the auth / internal allowlist. **These two lists will drift if you
    /// only update one side** — update this script whenever you touch the
    /// Swift allowlist.
    ///
    /// Side effect: clicking the messenger's "minimize" button no-ops.
    /// URL stays on the thread, the feed never gets to render underneath.
    /// That matches the DM-only product intent — minimizing into a feed
    /// is exactly the leak this app exists to prevent.
    ///
    /// Post-login handoff: Instagram often `pushState`s to `/` or `/direct`
    /// after credentials commit. Block those (feed/minimize shell) but ping
    /// Swift via `webkit.messageHandlers` so it can wait for `sessionid`
    /// before loading `/direct/inbox/` — never `location.replace` early.
    private static let spaNavigationGuardJS: WKUserScript = {
        let handoffHandler = authHandoffMessageHandler
        let source = """
        (function() {
            if (window.__InstaDMNavGuard) { return; }
            window.__InstaDMNavGuard = true;

            function pathAllowed(path) {
                if (!path) { return false; }
                return (
                    path.indexOf('/direct/inbox') === 0
                    || path.indexOf('/direct/t/') === 0
                    || path.indexOf('/direct/new') === 0
                    || path.indexOf('/accounts/login') === 0
                    || path.indexOf('/accounts/onetap') === 0
                    || path.indexOf('/accounts/password') === 0
                    || path.indexOf('/accounts/signup') === 0
                    || path.indexOf('/accounts/emailsignup') === 0
                    || path.indexOf('/accounts/check_email') === 0
                    || path.indexOf('/accounts/logout') === 0
                    || path.indexOf('/accounts/confirm') === 0
                    || path.indexOf('/accounts/access') === 0
                    || path.indexOf('/accounts/account_recovery') === 0
                    || path.indexOf('/accounts/username') === 0
                    || path.indexOf('/accounts/two_factor') === 0
                    || path.indexOf('/challenge') === 0
                    || path.indexOf('/api') === 0
                    || path.indexOf('/graphql') === 0
                    || path.indexOf('/ajax') === 0
                    || path.indexOf('/static') === 0
                );
            }

            function isAuthPath(path) {
                if (!path) { return false; }
                return path.indexOf('/accounts/') === 0
                    || path.indexOf('/challenge') === 0;
            }

            /// Post-login SPA hops that would render the feed if allowed.
            function authHandoffTarget(path) {
                if (path === '/' || path === ''
                    || path === '/direct' || path === '/direct/') {
                    return '/direct/inbox/';
                }
                return null;
            }

            function resolvePath(href) {
                if (!href || typeof href !== 'string') { return null; }
                if (href.charAt(0) === '#') { return null; }
                try {
                    var u = new URL(href, location.href);
                    if (u.protocol !== 'http:' && u.protocol !== 'https:') {
                        return null;
                    }
                    if (u.host !== location.host) { return null; }
                    return u.pathname || '/';
                } catch (e) {
                    return null;
                }
            }

            function blockEvent(e) {
                try {
                    e.preventDefault();
                    if (typeof e.stopImmediatePropagation === 'function') {
                        e.stopImmediatePropagation();
                    }
                    e.stopPropagation();
                } catch (err) { /* defensive */ }
            }

            function clickHandler(e) {
                var t = e.target;
                if (!t || !t.closest) { return; }
                var a = t.closest('a[href]');
                if (!a) { return; }
                var path = resolvePath(a.getAttribute('href'));
                if (path === null) { return; }
                if (pathAllowed(path)) { return; }
                blockEvent(e);
            }

            document.addEventListener('click', clickHandler, true);
            document.addEventListener('auxclick', clickHandler, true);

            function wrapHistory(name) {
                var orig = history[name];
                if (typeof orig !== 'function' || orig.__instaDMWrapped) {
                    return;
                }
                var wrapped = function(state, title, url) {
                    if (typeof url === 'string' && url.length > 0) {
                        var path = resolvePath(url);
                        if (path !== null && !pathAllowed(path)) {
                            var current = location.pathname || '/';
                            if (isAuthPath(current) && authHandoffTarget(path) !== null) {
                                try {
                                    window.webkit.messageHandlers.\(handoffHandler).postMessage('postLogin');
                                } catch (e) { /* no handler yet */ }
                                return undefined;
                            }
                            return undefined;
                        }
                    }
                    return orig.apply(this, arguments);
                };
                wrapped.__instaDMWrapped = true;
                history[name] = wrapped;
            }
            wrapHistory('pushState');
            wrapHistory('replaceState');
        })();
        """
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }()

    // MARK: - Cosmetic CSS

    /// Hides Instagram's left-rail items that lead off the DM surface so
    /// the user isn't visually tempted toward surfaces the JS guard / URL
    /// policy block anyway. Removing the temptation is the *only* job of
    /// this CSS — it is not a security layer.
    ///
    /// Selectors are a mix of:
    ///   - **`href` patterns** (stable across class-name churn, language-
    ///     independent), and
    ///   - **`aria-label` patterns** qualified to interactive elements
    ///     (`a`, `button`, `[role=link|button]`) so the messenger's own
    ///     `<input>` search field isn't caught. Aria labels rely on the
    ///     English locale; if a user switches Instagram's language, the
    ///     rail will partially reappear. JS guard + URL policy keep them
    ///     unclickable regardless.
    ///
    /// Expected drift: Instagram reshuffles its DOM every few months.
    /// Cosmetic regressions show up as visible rail items; check the live
    /// site in Safari DevTools and add the new selector here. The
    /// navigation allowlist is the actual defense.
    private static let cosmeticHideNavCSS: WKUserScript = {
        let css = """
        /* Anchor targets — language-independent */
        a[href='/']:not([href*='direct']),
        a[href^='/explore/'],
        a[href^='/explore'],
        a[href^='/reels/'],
        a[href^='/reels'],
        a[href*='notifications'],
        a[href^='/accounts/activity'],
        a[href^='/accounts/edit/'],
        a[href^='/accounts/manage'],
        a[href^='/accounts/password'],
        a[href^='/your_activity'],
        a[href^='/saved/'],
        a[href*='/create/'],
        a[href*='threads.net'],
        a[href*='threads.com'],

        /* Aria-labelled rail controls (English locale).
           Qualified to interactive non-input elements so the messenger's
           own Search input/textarea is not caught. */
        a[aria-label='Search'],
        button[aria-label='Search'],
        [role='link'][aria-label='Search'],
        [role='button'][aria-label='Search'],
        a[aria-label='Home'],
        button[aria-label='Home'],
        [role='link'][aria-label='Home'],
        a[aria-label='Explore'],
        button[aria-label='Explore'],
        [role='link'][aria-label='Explore'],
        a[aria-label='Reels'],
        button[aria-label='Reels'],
        [role='link'][aria-label='Reels'],
        a[aria-label='Notifications'],
        button[aria-label='Notifications'],
        [role='link'][aria-label='Notifications'],
        button[aria-label='New post'],
        [role='button'][aria-label='New post'],
        button[aria-label='Create'],
        [role='button'][aria-label='Create'],
        button[aria-label='More'],
        [role='button'][aria-label='More'],
        a[aria-label='Threads'],
        button[aria-label='Threads'],
        [role='link'][aria-label='Threads'] {
            display: none !important;
        }
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

        weak var webView: WKWebView?

        /// The URL this coordinator rebounds blocked JS-driven navigations
        /// to. For Messages it's the inbox; for Requests it's the follow-
        /// requests URL. Set once at init from the parent `WebView`.
        let homeURL: URL

        /// Carries the parent `WebView`'s `tracksNotifications` so
        /// `dismantleNSView` only tears down the manager for the instance
        /// that attached it.
        let tracksNotifications: Bool

        /// Reload loops where `homeURL` 302s before any URL commits (`webView.url`
        /// stays nil). User-visible blocked pages always recover — never gated
        /// by this counter.
        private var nilUrlLoopCount = 0

        private let maxNilUrlLoopCount = 8

        /// Coalesces recovery loads when a blocked **page** actually commits.
        private var pendingRecovery: DispatchWorkItem?

        private let recoveryDebounce: TimeInterval = 0.12

        /// Set when the user submits credentials; post-login blocked redirects
        /// are only allowed inside this window so idle prefetch on the login
        /// page doesn't trigger a premature inbox load.
        private var authSubmitAt: Date?

        /// Set when we deliberately allowed a post-login redirect to a blocked
        /// URL so `didFinish` can route to the inbox once `sessionid` exists.
        private var awaitingInboxHandoff = false

        /// True after the first successful inbox/thread load. Guards scroll-only
        /// optimizations so they never interfere with cold launch.
        private var hasSettledOnUserSurface = false

        /// Last committed inbox/thread URL — used to bounce back from a blocked
        /// page without always dumping the user at the inbox root.
        private var lastDMSurfaceURL: URL?

        /// Previous main-frame path — detects returns to DMs from profile/feed/etc.
        private var lastCommittedPath: String?

        /// Set when full IG chrome leaks; cleared by `restoreDMSurface`.
        private var surfaceNeedsHeal = false

        /// Prevents heal-reload loops.
        private var isRestoringDMSurface = false

        /// Rate-limit overlay-dismiss JS so rapid prefetch bursts don't stack.
        private var lastChromeDismissAt: Date?

        private let chromeDismissCooldown: TimeInterval = 0.35

        init(homeURL: URL, tracksNotifications: Bool) {
            self.homeURL = homeURL
            self.tracksNotifications = tracksNotifications
        }

        // MARK: - DEBUG instrumentation

        /// Diagnostic log used to trace navigation decisions when reproducing
        /// SPA-layer leaks (profile click while DMs are minimized, scroll
        /// pagination → reload, white-screen launch). `#if DEBUG` only —
        /// Release builds compile to a no-op, so production users never see
        /// these in `Console.app`.
        ///
        /// Filter `Console.app` for `[InstaDM/` to capture the full trace
        /// during a repro. `@autoclosure` means the `details` string is only
        /// built when the log actually fires.
        private func dlog(_ tag: String, _ details: @autoclosure () -> String = "") {
            #if DEBUG
            NSLog("%@", "[InstaDM/\(tag)] \(details())")
            #endif
        }

        // MARK: - Navigation policy

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

            dlog(
                "decideAction.in",
                "url=\(url.absoluteString) wv=\(webView.url?.absoluteString ?? "nil") type=\(navigationAction.navigationType.rawValue) src=\(sourcePath.isEmpty ? "nil" : sourcePath) inDMSession=\(isInDMSession(webView)) settled=\(hasSettledOnUserSurface)"
            )

            if isOnAuthSurface(webView) || isAuthSource(navigationAction) {
                noteAuthSubmit(navigationAction, url: url)
            }

            if NavigationPolicy.isAllowed(url, source: source) {
                if !isOnAuthSurface(webView),
                   !isAuthSource(navigationAction),
                   !NavigationPolicy.isInAppUserSurface(url.path, source: source) {
                    decisionHandler(.cancel)
                    // Still on DMs — don't stopLoading(); that aborts pagination
                    // XHR and other in-flight requests while scrolling history.
                    return
                }
                // Open threads only: IG sometimes re-navigates the same thread
                // (`.other`) when paginating history — allowing it reloads and
                // snaps scroll to the bottom. Never apply during cold launch.
                if hasSettledOnUserSurface,
                   navigationAction.navigationType == .other,
                   let current = webView.url,
                   current.path.hasPrefix("/direct/t/"),
                   refersToSameDMSurface(current, url) {
                    decisionHandler(.cancel)
                    return
                }
                decisionHandler(.allow)
                return
            }

            // Blocked navigation during an active DM session (includes minimized
            // messenger — URL may be `/`, bare `/direct`, or still on inbox).
            if isInDMSession(webView)
                || isInDirectContext(webView, navigationAction: navigationAction) {
                decisionHandler(.cancel)
                handleBlockedWhileOnDMs(
                    url: url,
                    navigationAction: navigationAction,
                    in: webView,
                    source: source
                )
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

            // Mid-login blocked hops (prefetch, XHR-as-navigation, etc.) must
            // not bounce to inbox — that loads /direct/inbox without a session
            // cookie and Instagram sends the user straight back to login.
            if isOnAuthSurface(webView) || isAuthSource(navigationAction) {
                return
            }

            if isViewingInAppUserSurface(webView) {
                handleBlockedWhileOnDMs(
                    url: url,
                    navigationAction: navigationAction,
                    in: webView,
                    source: source
                )
                return
            }
            webView.stopLoading()
            handleBlocked(
                url: url,
                in: webView,
                navigationAction: navigationAction,
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

            dlog(
                "decideResponse.in",
                "url=\(url.absoluteString) wv=\(webView.url?.absoluteString ?? "nil") awaitingInboxHandoff=\(awaitingInboxHandoff)"
            )

            if awaitingInboxHandoff {
                let path = url.path
                if path.isEmpty || path == "/" {
                    decisionHandler(.allow)
                    return
                }
                decisionHandler(.cancel)
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
                    return
                }
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
            if isViewingInAppUserSurface(webView) {
                if NavigationPolicy.isBlockedInAppChrome(url, source: source) {
                    markSurfaceCompromised()
                    dismissInstagramChrome(in: webView)
                    scheduleDelayedChromeDismiss(in: webView)
                    if NavigationPolicy.isProfilePath(url.path) {
                        reboundToLastDMSurface(in: webView)
                    }
                }
                return
            }
            if isInDMSession(webView),
               NavigationPolicy.shouldRecoverFromMainDocument(url, source: source) {
                markSurfaceCompromised()
                scheduleRecovery(in: webView, url: lastDMSurfaceURL ?? homeURL, force: true)
                return
            }
            webView.stopLoading()
            scheduleRecovery(in: webView, url: homeURL)
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
                openInExternalBrowserIfAllowed(url, in: webView)
            }
            return nil
        }

        private func handleBlocked(
            url: URL,
            in webView: WKWebView,
            navigationAction: WKNavigationAction,
            navigationType: WKNavigationType
        ) {
            // User-initiated link click to a non-allowed URL → open in
            // Safari so the "friend shared something we don't render" flow
            // still works gracefully.
            if navigationType == .linkActivated {
                openInExternalBrowserIfAllowed(
                    url,
                    in: webView,
                    navigationAction: navigationAction
                )
                return
            }
            if let currentURL = webView.url,
               NavigationPolicy.isAllowed(currentURL),
               NavigationPolicy.isInAppUserSurface(currentURL.path) {
                // Only after the user actually submitted credentials — not on
                // every blocked prefetch while the login form is idle.
                if isOnAuthSurface(webView), authSubmitAt != nil {
                    routeToInboxWhenAuthenticated(in: webView)
                }
                return
            }
            if webView.url == nil {
                nilUrlLoopCount += 1
                if nilUrlLoopCount >= maxNilUrlLoopCount {
                    return
                }
            } else {
                nilUrlLoopCount = 0
            }
            scheduleRecovery(in: webView, url: homeURL)
        }

        /// Blocked navigation while the committed URL is still a DM surface.
        /// Never `stopLoading()` — that aborts scroll pagination XHR.
        /// Safari opens only for an explicit link click, not `.other` prefetch.
        private func handleBlockedWhileOnDMs(
            url: URL,
            navigationAction: WKNavigationAction,
            in webView: WKWebView,
            source: NavigationPolicy.Source
        ) {
            let isExplicitLinkClick = navigationAction.navigationType == .linkActivated

            dlog(
                "blockedOnDMs.in",
                "url=\(url.absoluteString) wv=\(webView.url?.absoluteString ?? "nil") type=\(navigationAction.navigationType.rawValue) isExplicit=\(isExplicitLinkClick) isProfile=\(NavigationPolicy.isProfilePath(url.path)) isIncidental=\(NavigationPolicy.isIncidentalBlockedPrefetch(url)) isOffPlatform=\(NavigationPolicy.isOffPlatformURL(url))"
            )

            if NavigationPolicy.isIncidentalBlockedPrefetch(url),
               !NavigationPolicy.isProfilePath(url.path) {
                dlog("blockedOnDMs.skipIncidental", "url=\(url.absoluteString)")
                return
            }

            if NavigationPolicy.isOffPlatformURL(url) {
                if isExplicitLinkClick {
                    openInExternalBrowserIfAllowed(
                        url,
                        in: webView,
                        navigationAction: navigationAction
                    )
                }
                markSurfaceCompromised()
                reboundToLastDMSurface(in: webView)
                return
            }

            markSurfaceCompromised()
            dismissInstagramChrome(in: webView)
            scheduleDelayedChromeDismiss(in: webView)

            if isExplicitLinkClick {
                openInExternalBrowserIfAllowed(
                    url,
                    in: webView,
                    navigationAction: navigationAction
                )
            }

            if NavigationPolicy.isProfilePath(url.path)
                || NavigationPolicy.isBlockedInAppChrome(url, source: source)
                || !isViewingInAppUserSurface(webView) {
                reboundToLastDMSurface(in: webView)
            }
        }

        /// Active DM session — stays true after first inbox load until the app quits.
        private func isInDMSession(_ webView: WKWebView) -> Bool {
            hasSettledOnUserSurface
                && lastDMSurfaceURL != nil
                && !isOnAuthSurface(webView)
        }

        private func reboundToLastDMSurface(in webView: WKWebView) {
            guard let target = lastDMSurfaceURL ?? (
                webView.url.flatMap {
                    NavigationPolicy.isDirectMessagingPath($0.path) ? $0 : nil
                }
            ) else {
                dlog("rebound.fallbackHome", "wv=\(webView.url?.absoluteString ?? "nil")")
                scheduleRecovery(in: webView, url: homeURL, force: true)
                return
            }
            dlog("rebound.toLastDM", "target=\(target.absoluteString) wv=\(webView.url?.absoluteString ?? "nil")")
            restoreDMSurface(in: webView, url: target)
        }

        /// Login/challenge may need Facebook/Meta in the browser; after that,
        /// respect Settings → Open links in default browser.
        private func mayOpenExternalBrowser(
            in webView: WKWebView,
            navigationAction: WKNavigationAction? = nil
        ) -> Bool {
            if isOnAuthSurface(webView) { return true }
            if awaitingInboxHandoff { return true }
            if let navigationAction, isAuthSource(navigationAction) { return true }
            return AppSettings.openLinksInExternalBrowser
        }

        private func openInExternalBrowserIfAllowed(
            _ url: URL,
            in webView: WKWebView,
            navigationAction: WKNavigationAction? = nil
        ) {
            guard mayOpenExternalBrowser(in: webView, navigationAction: navigationAction) else {
                return
            }
            NSWorkspace.shared.open(url)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard let url = webView.url else { return }

            // Post-login `/` may commit before didFinish; never stopLoading here
            // or Set-Cookie may not land. didFinish + routeToInboxWhenAuthenticated
            // owns the handoff. (Fresh login has hasSettledOnUserSurface == false,
            // so this must not be gated on that flag.)
            if awaitingInboxHandoff { return }

            guard hasSettledOnUserSurface else { return }

            if isOnAuthSurface(webView) { return }

            let path = url.path
            let source = NavigationPolicy.Source(
                fromDirect: NavigationPolicy.isDirectMessagingPath(path)
            )
            if NavigationPolicy.isInAppUserSurface(path, source: source) { return }
            if NavigationPolicy.isAllowed(url, source: source) { return }
            guard NavigationPolicy.shouldRecoverFromMainDocument(url, source: source) else {
                return
            }

            dlog(
                "didCommit.recover",
                "wv=\(url.absoluteString) target=\((lastDMSurfaceURL ?? homeURL).absoluteString)"
            )
            markSurfaceCompromised()
            webView.stopLoading()
            scheduleRecovery(in: webView, url: lastDMSurfaceURL ?? homeURL, force: true)
        }

        /// Debounced reload — only when a blocked surface actually committed.
        private func scheduleRecovery(in webView: WKWebView, url: URL, force: Bool = false) {
            if !force {
                if let current = webView.url, refersToSameDMSurface(current, url) {
                    return
                }
                // A blocked background nav was cancelled while DMs are still visible.
                if isViewingInAppUserSurface(webView) {
                    return
                }
            }
            pendingRecovery?.cancel()
            let work = DispatchWorkItem { [weak webView] in
                guard let webView else { return }
                if !force, self.isViewingInAppUserSurface(webView) { return }
                self.surfaceNeedsHeal = false
                webView.stopLoading()
                webView.load(URLRequest(url: url))
            }
            pendingRecovery = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + recoveryDebounce,
                execute: work
            )
        }

        private func isViewingInAppUserSurface(_ webView: WKWebView) -> Bool {
            guard let path = webView.url?.path else { return false }
            return NavigationPolicy.isInAppUserSurface(path)
        }

        /// Avoid reloading the same thread/inbox — that resets scroll position.
        private func refersToSameDMSurface(_ current: URL, _ target: URL) -> Bool {
            if current.absoluteString == target.absoluteString { return true }
            let currentPath = current.path
            let targetPath = target.path
            if NavigationPolicy.isDirectMessagingPath(currentPath),
               NavigationPolicy.isDirectMessagingPath(targetPath),
               currentPath == targetPath {
                return true
            }
            return false
        }

        private func markSettledOnUserSurface(from url: URL) {
            nilUrlLoopCount = 0
            hasSettledOnUserSurface = true
            if NavigationPolicy.isDirectMessagingPath(url.path) {
                lastDMSurfaceURL = url
            }
            pendingRecovery?.cancel()
            pendingRecovery = nil
        }

        private func markSurfaceCompromised() {
            surfaceNeedsHeal = true
        }

        /// True when the user navigated back to a DM route from profile, feed,
        /// stories, notifications chrome, etc., or overlay leak was detected.
        private func shouldRestoreDMSurface(landingOn path: String) -> Bool {
            guard hasSettledOnUserSurface,
                  !isRestoringDMSurface,
                  NavigationPolicy.isDirectMessagingPath(path) else {
                return false
            }
            if surfaceNeedsHeal { return true }
            guard let last = lastCommittedPath else { return false }
            return NavigationPolicy.isOutsideDMSurface(last)
        }

        /// One clean reload of a DM URL after IG chrome leaked — only on return
        /// to DMs, never during normal inbox ↔ thread hops or scroll pagination.
        private func restoreDMSurface(in webView: WKWebView, url: URL) {
            dlog("restoreDM.in", "target=\(url.absoluteString) wasRestoring=\(isRestoringDMSurface) wv=\(webView.url?.absoluteString ?? "nil")")
            guard !isRestoringDMSurface else { return }
            isRestoringDMSurface = true
            surfaceNeedsHeal = false
            pendingRecovery?.cancel()
            pendingRecovery = nil
            dismissInstagramChrome(in: webView)
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let current = webView.url else { return }

            dlog(
                "didFinish.in",
                "wv=\(current.absoluteString) onAuth=\(isOnAuthSurface(webView)) settled=\(hasSettledOnUserSurface) needsHeal=\(surfaceNeedsHeal) restoring=\(isRestoringDMSurface) lastDMSurface=\(lastDMSurfaceURL?.absoluteString ?? "nil")"
            )

            // AJAX login often keeps the auth URL while Set-Cookie lands — poll
            // for session cookies after submit even if no redirect/pushState fired.
            if isOnAuthSurface(webView), authSubmitAt != nil {
                routeToInboxWhenAuthenticated(in: webView)
                lastCommittedPath = current.path
                return
            }

            if NavigationPolicy.isAllowed(current) {
                let path = current.path
                let fromDirect = NavigationPolicy.isDirectMessagingPath(path)
                let source = NavigationPolicy.Source(fromDirect: fromDirect)
                if !isOnAuthSurface(webView),
                   !NavigationPolicy.isInAppUserSurface(path, source: source) {
                    if hasSettledOnUserSurface {
                        lastCommittedPath = path
                        return
                    }
                    webView.stopLoading()
                    scheduleRecovery(in: webView, url: homeURL)
                    lastCommittedPath = path
                    return
                }

                if !isOnAuthSurface(webView),
                   shouldRestoreDMSurface(landingOn: path) {
                    restoreDMSurface(in: webView, url: current)
                    return
                }

                if isRestoringDMSurface {
                    isRestoringDMSurface = false
                }

                if !isOnAuthSurface(webView) {
                    awaitingInboxHandoff = false
                    if NavigationPolicy.isDirectMessagingPath(path),
                       !hasSettledOnUserSurface {
                        routeToInboxWhenAuthenticated(in: webView)
                        lastCommittedPath = path
                        return
                    }
                    authSubmitAt = nil
                    markSettledOnUserSurface(from: current)
                }
                lastCommittedPath = path
                return
            }

            // Landed on a blocked surface (profile, feed, explore, …).
            dlog(
                "didFinish.blocked",
                "wv=\(current.absoluteString) target=\((lastDMSurfaceURL ?? homeURL).absoluteString) awaitingInboxHandoff=\(awaitingInboxHandoff)"
            )
            markSurfaceCompromised()
            if awaitingInboxHandoff {
                awaitingInboxHandoff = false
                routeToInboxWhenAuthenticated(in: webView)
                lastCommittedPath = current.path
                return
            }

            webView.stopLoading()
            scheduleRecovery(in: webView, url: lastDMSurfaceURL ?? homeURL, force: true)
            lastCommittedPath = current.path
        }

        /// Pop IG's in-page profile/modal chrome without reloading the thread.
        private func dismissInstagramChrome(in webView: WKWebView) {
            if let last = lastChromeDismissAt,
               Date().timeIntervalSince(last) < chromeDismissCooldown {
                return
            }
            lastChromeDismissAt = Date()
            webView.evaluateJavaScript(
                """
                (function() {
                    var close = document.querySelector(
                        'button[aria-label="Close"], [role="button"][aria-label="Close"], ' +
                        'button[aria-label="Back"], [role="button"][aria-label="Back"]'
                    );
                    if (!close) {
                        var svg = document.querySelector(
                            'svg[aria-label="Close"], svg[aria-label="Back"]'
                        );
                        close = svg && svg.closest('button');
                    }
                    if (close) { close.click(); return 'close'; }
                    document.dispatchEvent(new KeyboardEvent('keydown', {
                        key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true
                    }));
                    if (window.history.length > 1) {
                        window.history.back();
                        return 'back';
                    }
                    return 'none';
                })();
                """
            )
        }

        private func scheduleDelayedChromeDismiss(in webView: WKWebView) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.lastChromeDismissAt = nil
                self.dismissInstagramChrome(in: webView)
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
            guard isOnAuthSurface(webView)
                || isAuthSource(navigationAction)
                || authSubmitAt != nil else {
                return false
            }
            let path = url.path
            // Post-login 302 through feed root only — inbox load waits for cookies.
            return path.isEmpty || path == "/"
        }

        // MARK: - JS auth handoff

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == WebView.authHandoffMessageHandler else { return }
            authSubmitAt = authSubmitAt ?? Date()
            awaitingInboxHandoff = true
            guard let webView else { return }
            routeToInboxWhenAuthenticated(in: webView)
        }

        /// True when the user is viewing DMs — uses source frame **or** the
        /// committed web-view URL. Group-chat UI often fails the source check.
        private func isInDirectContext(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction
        ) -> Bool {
            if isInDMSession(webView) { return true }
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
                        self.awaitingInboxHandoff = false
                        if let current = webView.url,
                           NavigationPolicy.isAllowed(current),
                           NavigationPolicy.isDirectMessagingPath(current.path) {
                            self.markSettledOnUserSurface(from: current)
                            return
                        }
                        webView.load(URLRequest(url: homeURL))
                        return
                    }
                    guard attempt < 30 else { return }
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
