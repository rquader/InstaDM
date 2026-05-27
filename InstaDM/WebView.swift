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

    /// Per-tab JS-guard allowlist. The document-start guard blocks anchor
    /// clicks and `history.pushState`/`replaceState` to any path outside
    /// this list (merged with the always-on auth/internal prefixes). The
    /// Messages tab passes DM paths; the Requests tab passes only the
    /// follow-requests path — so you can't click out of the Requests tab
    /// into DMs, the feed, or a profile.
    let allowedPathPrefixes: [String]

    /// When `true`, this web view registers with `NotificationManager` to
    /// drive the dock badge and notification banners off its
    /// `document.title`. Only the Messages tab does this — the Requests
    /// tab's title isn't the unread-count source of truth.
    let tracksNotifications: Bool

    init(
        startURL: URL = NavigationPolicy.inboxURL,
        allowedPathPrefixes: [String] = NavigationPolicy.jsMessagesTabAllowedPathPrefixes,
        tracksNotifications: Bool = true
    ) {
        self.startURL = startURL
        self.allowedPathPrefixes = allowedPathPrefixes
        self.tracksNotifications = tracksNotifications
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(homeURL: startURL, tracksNotifications: tracksNotifications)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()  // persistent cookies

        // Present a complete Safari user agent. WKWebView's stock UA omits the
        // trailing "Version/<v> Safari/<build>" tokens, and Instagram's login
        // endpoint treats that truncated UA as an unsupported / automated
        // client — the login request then never completes (the spinner circles
        // forever). The exact same fresh login works in real Safari, which
        // sends the full token. `applicationNameForUserAgent` appends to the
        // stock WebKit UA, producing a normal macOS Safari string — *more*
        // Safari-like than the default, not less, so it doesn't raise the
        // "unusual UA" ban risk noted in the project's risk docs.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"

        configuration.userContentController.addUserScript(
            Self.spaNavigationGuardScript(allowedPathPrefixes: allowedPathPrefixes)
        )
        configuration.userContentController.addUserScript(Self.cosmeticHideNavCSS)
        #if DEBUG
        configuration.userContentController.add(context.coordinator, name: "instaDMDiag")
        configuration.userContentController.addUserScript(Self.diagnosticScript)
        #endif

        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        // Debug builds only: lets you attach Safari Web Inspector
        // (Develop → your Mac → InstaDM) to watch the Console / Network during
        // a repro. Release builds are never inspectable.
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif
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
        coordinator.stopAuthWatch()
        #if DEBUG
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "instaDMDiag")
        #endif
    }

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
    /// `allowedPathPrefixes` is the per-tab surface (Messages → DM paths,
    /// Requests → the follow-requests path); the always-on auth / internal
    /// prefixes are merged in from `NavigationPolicy.jsCommonAllowedPathPrefixes`.
    /// The JS allowlist mirrors the Swift one — keep them in sync if you add
    /// a surface.
    ///
    /// **Stands down on auth surfaces.** While `location.pathname` matches an
    /// auth prefix (`NavigationPolicy.authSurfacePathPrefixes` → login /
    /// recovery / challenge), both the click listener and the history wrappers
    /// no-op so Instagram's real login flow runs completely untouched. The
    /// Swift-side cookie watcher (`startAuthWatch`) routes to the inbox once a
    /// session exists. Trying to intercept the post-login navigation in JS or
    /// Swift is what broke login repeatedly — so we simply don't.
    ///
    /// Side effect: clicking the messenger's "minimize" button no-ops (its
    /// pushState target `/` or `/direct` is outside the allowlist and not an
    /// auth path), so the feed never renders under an open thread.
    private static func spaNavigationGuardScript(
        allowedPathPrefixes: [String]
    ) -> WKUserScript {
        func jsonArray(_ items: [String]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: items),
                  let json = String(data: data, encoding: .utf8) else {
                return "[]"
            }
            return json
        }
        let allowedJSON = jsonArray(NavigationPolicy.jsCommonAllowedPathPrefixes + allowedPathPrefixes)
        let authJSON = jsonArray(NavigationPolicy.authSurfacePathPrefixes)
        let source = """
        (function() {
            if (window.__InstaDMNavGuard) { return; }

            var ALLOWED_PREFIXES = \(allowedJSON);
            var AUTH_PREFIXES = \(authJSON);

            function matchesPrefix(path, list) {
                if (!path) { return false; }
                for (var i = 0; i < list.length; i++) {
                    if (path.indexOf(list[i]) === 0) { return true; }
                }
                return false;
            }

            function pathAllowed(path) {
                return matchesPrefix(path, ALLOWED_PREFIXES);
            }

            // Auth paths only — /accounts/activity (FollowRequests) is not
            // auth, so the guard stays active there.
            function isAuthContext() {
                return matchesPrefix(location.pathname || '/', AUTH_PREFIXES);
            }

            // CRITICAL: do not install the guard at all on a login / challenge
            // surface. Instagram's fresh-login flow needs a pristine JS
            // environment — native history.pushState, no injected capture-phase
            // click listeners — which is exactly what Safari gives it (where
            // fresh login works). Wrapping history on the login page stalls
            // Instagram's login request. This script re-runs on every new
            // document, so the guard reactivates the instant we're off auth.
            if (isAuthContext()) { return; }

            window.__InstaDMNavGuard = true;

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
                if (isAuthContext()) { return; }
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
                    if (!isAuthContext()
                        && typeof url === 'string' && url.length > 0) {
                        var path = resolvePath(url);
                        if (path !== null && !pathAllowed(path)) {
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
    }

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
        /* Kill Instagram's entire primary nav rail — icons AND the
           hover-expanded text labels (Search, Explore, Reels, Messages,
           Notifications, Create, Profile, More). :has() targets the rail by
           the Instagram logo / home link it contains; the messenger's own
           thread list is not inside this rail, so it's untouched. WebKit
           supports :has() on macOS 14+. This is the primary hide; the
           per-item selectors below are a fallback for DOM shapes where the
           rail isn't a single nav landmark. */
        nav:has(a[href='/']:not([href*='direct'])),
        [role='navigation']:has(a[href='/']:not([href*='direct'])) {
            display: none !important;
        }

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

#if DEBUG
    // MARK: - Login diagnostics (DEBUG only)

    /// Temporary instrumentation to diagnose the fresh-login failure without a
    /// Safari Web Inspector. Injected at documentStart on every page; observes
    /// (never modifies) the login request and posts a one-line summary to Swift,
    /// which `NSLog`s it as `[InstaDM/page] …` in Xcode's console.
    ///
    /// Logs **URLs and HTTP status codes only** — never request/response bodies,
    /// so credentials are never captured. Compiled out of Release entirely.
    private static let diagnosticScript: WKUserScript = {
        let source = """
        (function() {
            if (window.__InstaDMDiag) { return; }
            window.__InstaDMDiag = true;
            function post(m) {
                try {
                    window.webkit.messageHandlers.instaDMDiag.postMessage(String(m).slice(0, 500));
                } catch (e) {}
            }
            post('doc ' + location.pathname + ' ready=' + document.readyState);
            window.addEventListener('error', function(e) {
                post('js-error: ' + (e.message || '') + ' @' + (e.lineno || ''));
            });
            window.addEventListener('unhandledrejection', function(e) {
                var r = e.reason;
                post('reject: ' + ((r && r.message) ? r.message : String(r)));
            });
            function watched(u) {
                return u.indexOf('login') !== -1 || u.indexOf('/accounts/') !== -1;
            }
            var of = window.fetch;
            if (typeof of === 'function') {
                window.fetch = function(input) {
                    var url = '';
                    try { url = (input && input.url) ? input.url : String(input); } catch (e) {}
                    var w = watched(url);
                    if (w) { post('fetch-> ' + url); }
                    return of.apply(this, arguments).then(function(r) {
                        if (w) { post('fetch<- ' + r.status + ' ' + url); }
                        return r;
                    }, function(err) {
                        if (w) { post('fetch-x ' + (err && err.message) + ' ' + url); }
                        throw err;
                    });
                };
            }
            var oOpen = XMLHttpRequest.prototype.open;
            var oSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url) {
                try { this.__diagUrl = url; this.__diagMethod = method; } catch (e) {}
                return oOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function() {
                var u = this.__diagUrl || '';
                if (watched(u)) {
                    post('xhr-> ' + (this.__diagMethod || '') + ' ' + u);
                    var self = this;
                    this.addEventListener('loadend', function() {
                        post('xhr<- ' + self.status + ' ' + u);
                    });
                }
                return oSend.apply(this, arguments);
            };
        })();
        """
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }()
#endif

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

        /// Reload loops where `homeURL` 302s before any URL commits (`webView.url`
        /// stays nil). User-visible blocked pages always recover — never gated
        /// by this counter.
        private var nilUrlLoopCount = 0

        private let maxNilUrlLoopCount = 8

        /// Coalesces recovery loads when a blocked **page** actually commits.
        private var pendingRecovery: DispatchWorkItem?

        private let recoveryDebounce: TimeInterval = 0.12

        /// Cookie-driven login watcher (see `startAuthWatch`). Replaces the
        /// old `authSubmitAt` / `awaitingInboxHandoff` / JS-handoff-message
        /// machinery. Rather than guess how Instagram navigates after login
        /// (form submit vs. fetch vs. pushState vs. in-place render — each
        /// version differs, and guessing wrong is what kept breaking login),
        /// we poll the cookie store while on an auth surface and load the
        /// inbox the moment a `sessionid` exists.
        private var authWatchActive = false

        /// Bumped on every start/stop so a stale in-flight poll callback
        /// no-ops instead of resuming a watch we already finished.
        private var authWatchGeneration = 0

        private let maxAuthWatchAttempts = 900  // ~6 min at 0.4s

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
                if isOnAuthSurface(webView) || isAuthSource(navigationAction) {
                    startAuthWatch(in: webView)
                    decisionHandler(.allow)
                    return
                }
                decisionHandler(.cancel)
                return
            }

            // WebKit's header declares both `WKNavigationAction.request`
            // and `WKFrameInfo.request` as non-nullable, but on macOS 26
            // (Tahoe) the ObjC layer empirically hands back nil for
            // synthetic / session-restored frames. Direct Swift access
            // traps in `URLRequest._unconditionallyBridgeFromObjectiveC`,
            // which crashed the app with `EXC_BREAKPOINT` on the first
            // `decidePolicyForNavigationAction` before any UI rendered.
            // `safeRequest` (file scope below) reads the property via KVC,
            // returning an honestly-optional `Any?`. A nil source frame
            // request falls back to "not from a DM" — strictest, safe.
            let sourcePath = navigationAction.sourceFrame.safeRequest?.url?.path ?? ""
            let source = NavigationPolicy.Source(
                fromDirect: NavigationPolicy.isDirectMessagingPath(sourcePath)
            )

            dlog(
                "decideAction.in",
                "url=\(url.absoluteString) wv=\(webView.url?.absoluteString ?? "nil") type=\(navigationAction.navigationType.rawValue) src=\(sourcePath.isEmpty ? "nil" : sourcePath) inDMSession=\(isInDMSession(webView)) settled=\(hasSettledOnUserSurface)"
            )

            // AUTH FLOW: stand down. While the web view is showing a login /
            // challenge surface (or the navigation originated from one), allow
            // every navigation so Instagram's real auth flow — AJAX login,
            // one-tap, 2FA, the post-login hop to the feed — runs untouched.
            // The cookie watcher routes to the inbox the moment a session
            // exists. Second-guessing IG's post-login navigation here is what
            // broke login repeatedly.
            if isOnAuthSurface(webView) || isAuthSource(navigationAction) {
                startAuthWatch(in: webView)
                dlog("decideAction.authAllow", "url=\(url.absoluteString)")
                decisionHandler(.allow)
                return
            }

            // From here down we are NOT on an auth surface — normal DM-only policy.
            if NavigationPolicy.isAllowed(url, source: source) {
                if !NavigationPolicy.isInAppUserSurface(url.path, source: source) {
                    // Allowed-but-not-a-surface (an /api or /graphql doc trying
                    // to become the main frame). Cancel — but don't stopLoading();
                    // that aborts pagination XHR while scrolling thread history.
                    decisionHandler(.cancel)
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

            decisionHandler(.cancel)

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
                "url=\(url.absoluteString) wv=\(webView.url?.absoluteString ?? "nil") onAuth=\(isOnAuthSurface(webView))"
            )

            // AUTH FLOW: let login pages and the post-login feed hop commit.
            // The cookie watcher routes to the inbox once a session exists.
            if isOnAuthSurface(webView) {
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
                // Already on an allowed surface; cancelling the nav is enough.
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

            // On a login / challenge surface — keep the cookie watcher armed
            // and don't touch the page. It routes to the inbox once a session
            // lands.
            if isOnAuthSurface(webView) {
                startAuthWatch(in: webView)
                return
            }

            // Scroll/heal recovery only kicks in after the first settled DM
            // load; during cold launch / login it stays out of the way.
            guard hasSettledOnUserSurface else { return }

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

            // AUTH FLOW: keep the cookie watcher running; it owns routing to
            // the inbox once a session lands. Never bounce to the inbox from
            // here — loading /direct/inbox/ before Set-Cookie commits lands
            // the user straight back on the login page.
            if isOnAuthSurface(webView) {
                startAuthWatch(in: webView)
                lastCommittedPath = current.path
                return
            }

            if NavigationPolicy.isAllowed(current) {
                let path = current.path
                let source = NavigationPolicy.Source(
                    fromDirect: NavigationPolicy.isDirectMessagingPath(path)
                )

                // Allowed-but-not-a-surface (an /api or /graphql doc as the
                // main frame). Recover to a DM surface unless already settled.
                if !NavigationPolicy.isInAppUserSurface(path, source: source) {
                    if hasSettledOnUserSurface {
                        lastCommittedPath = path
                        return
                    }
                    webView.stopLoading()
                    scheduleRecovery(in: webView, url: homeURL)
                    lastCommittedPath = path
                    return
                }

                if shouldRestoreDMSurface(landingOn: path) {
                    restoreDMSurface(in: webView, url: current)
                    return
                }
                if isRestoringDMSurface { isRestoringDMSurface = false }

                // Settled on a real user surface — login (if any) is complete.
                stopAuthWatch()
                markSettledOnUserSurface(from: current)
                lastCommittedPath = path
                return
            }

            // Landed on a blocked surface (feed, profile, …).
            dlog(
                "didFinish.blocked",
                "wv=\(current.absoluteString) settled=\(hasSettledOnUserSurface)"
            )
            markSurfaceCompromised()

            // Before the user has ever settled on a DM surface, a blocked
            // landing is almost always the post-login feed hop. Don't bounce
            // blindly — let the cookie watcher route once a session is
            // confirmed, so we never reload /direct/inbox/ ahead of Set-Cookie.
            if !hasSettledOnUserSurface {
                startAuthWatch(in: webView)
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

        // MARK: - Auth watch (cookie-driven login completion)

        /// Arm the cookie watcher. Idempotent.
        ///
        /// Instagram's login can complete via a full navigation, a server
        /// 302, an SPA `pushState`, or an in-place React render — and which
        /// one happens varies by build. Rather than detect the post-login
        /// navigation (the approach that broke login repeatedly), we poll the
        /// cookie store while on an auth surface: the moment a `sessionid`
        /// exists and we're not already on a DM surface, load the inbox. One
        /// mechanism, no shared flags, independent of how IG navigates.
        private func startAuthWatch(in webView: WKWebView) {
            guard !authWatchActive else { return }
            authWatchActive = true
            authWatchGeneration &+= 1
            dlog("authWatch.start", "wv=\(webView.url?.absoluteString ?? "nil")")
            pollAuthCookies(in: webView, generation: authWatchGeneration, attempt: 0)
        }

        func stopAuthWatch() {
            guard authWatchActive else { return }
            authWatchActive = false
            authWatchGeneration &+= 1
            dlog("authWatch.stop")
        }

        private func pollAuthCookies(in webView: WKWebView, generation: Int, attempt: Int) {
            guard authWatchActive, generation == authWatchGeneration else { return }

            // Already on a DM surface — login finished, nothing to route.
            if let url = webView.url, NavigationPolicy.isDirectMessagingPath(url.path) {
                stopAuthWatch()
                return
            }

            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            cookieStore.getAllCookies { [weak self, weak webView] cookies in
                // WKHTTPCookieStore delivers on the main thread; hop anyway to
                // be defensive about future WebKit changes.
                DispatchQueue.main.async {
                    guard let self, let webView else { return }
                    guard self.authWatchActive,
                          generation == self.authWatchGeneration else { return }

                    let hasSession = cookies.contains { cookie in
                        guard cookie.domain.contains("instagram"),
                              !cookie.value.isEmpty else { return false }
                        return cookie.name == "sessionid"
                    }

                    if hasSession {
                        self.dlog("authWatch.session", "wv=\(webView.url?.absoluteString ?? "nil")")
                        self.stopAuthWatch()
                        if let url = webView.url,
                           NavigationPolicy.isDirectMessagingPath(url.path) {
                            self.markSettledOnUserSurface(from: url)
                        } else {
                            webView.load(URLRequest(url: self.homeURL))
                        }
                        return
                    }

                    // No session yet — keep polling. Capped so an abandoned
                    // login page eventually stops (re-armed on the next auth
                    // commit if the user returns).
                    guard attempt < self.maxAuthWatchAttempts else {
                        self.stopAuthWatch()
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        self.pollAuthCookies(
                            in: webView,
                            generation: generation,
                            attempt: attempt + 1
                        )
                    }
                }
            }
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
            return NavigationPolicy.isAuthSurfacePath(sourcePath)
        }

        /// True when the web view is mid-login or mid-challenge — a real auth
        /// surface only. Deliberately **not** every `/accounts/*` path:
        /// `/accounts/activity` is the opt-in FollowRequests surface, not an
        /// auth page, so it must not trip the auth stand-down (which would
        /// disarm the DM-only guard on the Requests tab).
        private func isOnAuthSurface(_ webView: WKWebView) -> Bool {
            guard let current = webView.url else { return false }
            if current.host == "accounts.instagram.com" { return true }
            return NavigationPolicy.isAuthSurfacePath(current.path)
        }
    }
}

#if DEBUG
// Receives the login-diagnostics messages and prints them to Xcode's console
// as `[InstaDM/page] …`. DEBUG only; the handler is never registered in Release.
extension WebView.Coordinator: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "instaDMDiag" else { return }
        NSLog("%@", "[InstaDM/page] \(message.body)")
    }
}
#endif

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
