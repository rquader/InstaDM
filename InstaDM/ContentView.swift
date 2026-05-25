import SwiftUI

/// The main window's content. Renders either a single `WebView` (Messages
/// only) or a `TabView` (Messages + Requests) depending on whether the user
/// has turned on the follow-requests surface in Settings.
///
/// The toggle is observed live via `@AppStorage` so flipping it in Settings
/// adds or removes the tab without restarting the app.
///
/// In the multi-tab layout, the active tab is reported to `NotificationManager`
/// so banner suppression doesn't accidentally silence DM notifications when
/// the user is staring at the Requests tab.
struct ContentView: View {

    /// Mirrors the `FollowRequests` runtime toggle. `@AppStorage` makes
    /// SwiftUI re-render this view when the user flips it in Settings.
    @AppStorage(SettingsKey.allowFollowRequests)
    private var followRequestsEnabled = FollowRequests.defaultEnabled

    /// Currently selected tab in the multi-tab layout. Ignored in single-
    /// tab mode.
    @State private var selectedTab: Tab = .messages

    private enum Tab: Hashable {
        case messages, requests
    }

    /// Show the Requests tab only when the feature is compiled in *and*
    /// the user has opted in. Either being false collapses back to the
    /// single-`WebView` layout, no chrome wasted.
    private var showRequestsTab: Bool {
        FollowRequests.available && followRequestsEnabled
    }

    var body: some View {
        Group {
            if showRequestsTab {
                tabbedLayout
            } else {
                WebView()
                    .onAppear {
                        // Single-tab mode is always "Messages visible."
                        NotificationManager.shared.setMessagesTabVisible(true)
                    }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    private var tabbedLayout: some View {
        TabView(selection: $selectedTab) {
            WebView()
                .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(Tab.messages)

            WebView(startURL: FollowRequests.url, tracksNotifications: false)
                .tabItem { Label(FollowRequests.displayName, systemImage: FollowRequests.symbolName) }
                .tag(Tab.requests)
        }
        .onAppear {
            NotificationManager.shared.setMessagesTabVisible(selectedTab == .messages)
        }
        .onChange(of: selectedTab) { _, newTab in
            NotificationManager.shared.setMessagesTabVisible(newTab == .messages)
        }
    }
}
