import Foundation
import UserNotifications
import AppKit
import WebKit

/// Polls the embedded `WKWebView`'s `document.title` for Instagram's
/// `"(N) Inbox • Instagram"` unread count, drives the dock badge, and fires
/// local notifications when the count increases while the user isn't already
/// looking at the DM window.
///
/// Privacy: this class **does not** persist message content, sender names, or
/// cookies anywhere. The notification body at the Standard level is generic
/// by design ("N new messages") so a banner left on screen never leaks
/// message content.
///
/// Threading: all entry points run on the main thread (enforced by
/// `dispatchPrecondition`). `UserDefaults` change notifications can be posted
/// from any thread; `settingsChanged` bounces to main before touching state.
final class NotificationManager: NSObject {

    static let shared = NotificationManager()

    private weak var webView: WKWebView?
    private var pollTimer: Timer?

    /// `nil` until the first successful read after `attach` (or after a
    /// level change). Stays nil long enough that we never fire a notification
    /// for the unread state that already existed when the app launched or
    /// when the user re-enabled notifications.
    private var lastSeenCount: Int?

    /// Tracks the last applied notification level so `applySettings` can
    /// distinguish a level change (which should reset the baseline so
    /// re-enabling doesn't fire for already-known unreads) from unrelated
    /// `UserDefaults` writes.
    private var lastKnownLevel: NotificationLevel?

    /// Tracks the last applied polling interval so `applySettings` can
    /// avoid tearing down + restarting the timer on every unrelated
    /// `UserDefaults` write (theme tweaks, allowed-surface toggles, etc.).
    private var lastKnownInterval: TimeInterval?

    /// Whether the Messages tab is currently the active tab in the
    /// multi-tab layout. Used by banner suppression: silencing a banner
    /// when the window is key only makes sense if the user is actually
    /// looking at messages. In single-tab mode this stays `true` (there's
    /// nothing else to be looking at).
    private var messagesTabVisible: Bool = true

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    // MARK: - Lifecycle

    /// Called from `WebView.makeNSView` once the embedded WKWebView is ready.
    /// Resets the seen-count baseline so we don't fire for pre-existing unreads.
    func attach(to webView: WKWebView) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.webView = webView
        self.lastSeenCount = nil
        self.lastKnownLevel = AppSettings.notificationLevel
        self.lastKnownInterval = AppSettings.pollingInterval
        requestPermissionIfNeeded()
        restartPolling()
    }

    /// Called from `WebView.dismantleNSView`. Tears down the timer and
    /// clears any visible badge — useful when the user turns notifications
    /// off at runtime or when SwiftUI rebuilds the view tree.
    ///
    /// (Dock badges are cleared by the OS on app termination regardless;
    /// this clearing exists for the runtime-toggle and view-rebuild paths,
    /// not for quit.)
    ///
    /// Pass the dismantling web view as `forWebView` so a race-y teardown
    /// (SwiftUI re-creating the Messages WebView) can't have the old
    /// instance's dismantle call clobber the new instance's attach.
    func detach(forWebView webView: WKWebView? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let webView, self.webView != nil, self.webView !== webView {
            // Caller isn't the currently-attached web view (likely an old
            // instance tearing down after a newer one already attached).
            // Do nothing — leave the current attachment intact.
            return
        }
        pollTimer?.invalidate()
        pollTimer = nil
        lastSeenCount = nil
        lastKnownLevel = nil
        lastKnownInterval = nil
        NSApp.dockTile.badgeLabel = nil
        self.webView = nil
    }

    /// Tells the manager whether the Messages tab is currently the active
    /// tab. `ContentView` calls this on tab changes (in the multi-tab
    /// layout) so banner suppression doesn't silence DM notifications
    /// while the user is staring at the Requests tab.
    func setMessagesTabVisible(_ visible: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        messagesTabVisible = visible
    }

    // MARK: - Settings observation

    @objc private func settingsChanged() {
        // `UserDefaults.didChangeNotification` is posted on the thread that
        // wrote the change. SwiftUI `@AppStorage` writes happen on main, so
        // this is almost always main — but hop explicitly to be safe.
        if Thread.isMainThread {
            applySettings()
        } else {
            DispatchQueue.main.async { [weak self] in self?.applySettings() }
        }
    }

    private func applySettings() {
        dispatchPrecondition(condition: .onQueue(.main))
        let level = AppSettings.notificationLevel
        let interval = AppSettings.pollingInterval

        let levelChanged    = level    != lastKnownLevel
        let intervalChanged = interval != lastKnownInterval

        // Most `UserDefaults.didChangeNotification` posts are for unrelated
        // keys (theme tweak, allowed-surface toggle, sound checkbox). Skip
        // the expensive work — permission lookup, JS eval, timer churn —
        // unless the change actually affects us.
        guard levelChanged || intervalChanged else { return }

        if levelChanged {
            // Reset the baseline so a re-enable doesn't fire a banner for
            // unreads that already existed before the user turned us back on.
            lastSeenCount = nil
            lastKnownLevel = level
            requestPermissionIfNeeded()
        }
        if intervalChanged {
            lastKnownInterval = interval
        }

        if level == .off {
            // Tear down everything and clear lingering banners; the user
            // explicitly asked for quiet.
            pollTimer?.invalidate()
            pollTimer = nil
            NSApp.dockTile.badgeLabel = nil
            let center = UNUserNotificationCenter.current()
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
            return
        }

        restartPolling()
    }

    /// Asks the OS for banner / badge / sound permission the first time the
    /// user lands on a level that needs banners — and silently demotes the
    /// stored level to Badge-only if permission is (or has been) denied.
    /// The demotion keeps the Settings UI honest: the picker reflects what
    /// will actually happen instead of pretending banners will fire.
    private func requestPermissionIfNeeded() {
        guard AppSettings.notificationLevel.wantsBanners else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                    guard !granted else { return }
                    DispatchQueue.main.async { Self.demoteToBadgeOnly() }
                }
            case .denied:
                // Permission was denied (now or in a prior session). Demote
                // silently — don't nag, don't keep retrying.
                DispatchQueue.main.async { Self.demoteToBadgeOnly() }
            case .authorized, .provisional, .ephemeral:
                break
            @unknown default:
                break
            }
        }
    }

    /// Writes Badge-only back to the stored level, but only if the current
    /// stored level wanted banners. Preserves an explicit `.off` choice.
    private static func demoteToBadgeOnly() {
        guard AppSettings.notificationLevel.wantsBanners else { return }
        UserDefaults.standard.set(
            NotificationLevel.badgeOnly.rawValue,
            forKey: SettingsKey.notificationLevel
        )
    }

    // MARK: - Polling

    private func restartPolling() {
        pollTimer?.invalidate()
        pollTimer = nil

        guard AppSettings.notificationLevel != .off else { return }

        // Schedule on .common so modal interactions (opening Settings, sheets)
        // don't pause the timer.
        let timer = Timer(
            timeInterval: AppSettings.pollingInterval,
            repeats: true
        ) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        poll()
    }

    private func poll() {
        guard AppSettings.notificationLevel != .off, let webView else { return }
        webView.evaluateJavaScript("document.title") { [weak self] result, _ in
            // WKWebView delivers evaluateJavaScript completions on main.
            guard let self, let title = result as? String else { return }
            self.handleUpdate(count: Self.parseUnreadCount(from: title))
        }
    }

    /// `nil` count means we couldn't parse a recognized Instagram title and
    /// should leave the badge + baseline alone rather than collapse to a
    /// false zero. See `parseUnreadCount` for the recognized shapes.
    private func handleUpdate(count: Int?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let count else { return }
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        defer { lastSeenCount = count }
        guard let previous = lastSeenCount, count > previous else { return }
        fireNotification(previous: previous, current: count)
    }

    // MARK: - Notification firing

    private func fireNotification(previous: Int, current: Int) {
        guard AppSettings.notificationLevel.wantsBanners else { return }

        // Suppress only when the user is actively focused on the Messages
        // surface. We require:
        //   1. The app is active (foreground).
        //   2. The hosting window is the key window.
        //   3. The Messages tab is the visible tab (matters only in the
        //      multi-tab layout — `messagesTabVisible` stays `true` in
        //      single-tab mode).
        // Missing any of these → fire the banner; the user isn't reading DMs.
        if NSApp.isActive,
           webView?.window?.isKeyWindow == true,
           messagesTabVisible {
            return
        }

        let added = current - previous
        let content = UNMutableNotificationContent()
        content.title = "New messages"
        content.body = added == 1 ? "1 new message" : "\(added) new messages"
        if AppSettings.notificationSound { content.sound = .default }

        // Full-preview level (sender + snippet) is the deferred Phase 2
        // stretch goal. See `Notifications.md` § Option B for the DOM-scraping
        // approach. When implemented, set content.subtitle = sender and
        // content.body = snippet here, with a graceful fallback to the
        // generic body above when scraping fails.

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Title parsing

    /// Reads the unread count out of Instagram's `document.title`.
    ///
    /// Returns:
    /// - `N` for `"(N) Inbox • Instagram"` (positive count).
    /// - `0` for `"Inbox • Instagram"` (any title containing "Instagram"
    ///   with no leading "(N)" — i.e. a recognized page with zero unreads).
    /// - `nil` when the title is something else (empty, transient, an error
    ///   page, mid-navigation). The caller leaves state alone on `nil` so we
    ///   don't collapse the badge to a false zero or fire a spurious banner
    ///   when the page later loads with a non-zero count.
    static func parseUnreadCount(from title: String) -> Int? {
        if title.hasPrefix("("), let closeParen = title.firstIndex(of: ")") {
            let digits = title[title.index(after: title.startIndex)..<closeParen]
            return Int(digits)
        }
        return title.contains("Instagram") ? 0 : nil
    }
}
