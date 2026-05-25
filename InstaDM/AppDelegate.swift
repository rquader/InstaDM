import AppKit

/// Opt into "quit on last window close". This matches the user-facing
/// promise that the app runs only when they want it to: when the window is
/// closed, no background process lingers and no polling timer keeps running.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
