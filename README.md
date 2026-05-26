# InstaDM

A native macOS app that's meant to give you Instagram **messaging and nothing else** —
direct messages and group chats, without the feed, reels, explore, or
stories.

## What it is

A small SwiftUI app that embeds Instagram's web client in a `WKWebView` and
enforces a navigation allowlist: anything outside `/direct/*` (plus login /
challenge / internal AJAX) is blocked. Reels and posts in your messages open properly within the app.

- **Privacy**: everything stays on your Mac. Session cookies live in the
  standard WebKit data store; settings live in `UserDefaults`. No analytics,
  no telemetry, no third-party SDKs, no cloud sync. (beyond that done by the Instagram website)
- **Dependencies**: Apple frameworks only (SwiftUI, WebKit, AppKit,
  UserNotifications, Foundation). No SPM packages, no CocoaPods.
- **Lifecycle**: standard Mac app. Cmd-Q quits; closing the window quits.
  Nothing runs in the background.

## Requirements

- macOS 14 (Sonoma) or later

## Install

1. Download **`InstaDM.app.zip`** from the
   [**latest release**](https://github.com/rquader/InstaDM/releases/latest).
2. If you already have InstaDM in `/Applications`, delete the old
   `InstaDM.app` first, then unzip and drag the new one in.
3. First launch only: right-click the app → **Open** so macOS accepts
   the unsigned build. Alternatively, run once in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/InstaDM.app
   ```

4. Log in with your Instagram credentials the first time; the session
   persists across launches.

## Features

- **DM-only navigation**: any click that would leave `/direct/*` is blocked.
  External link clicks open in your default browser. Server-side redirects
  into blocked URLs are caught by a bounce-cooldown loop guard so a
  misbehaving Instagram surface can't trap the web view in an infinite
  reload.
- **Allowed-surfaces toggles** (opt-in): show a "Requests" tab for follow
  requests, or open posts shared in DMs in-app instead of bouncing to Safari.
  Off by default; each is a one-file feature module so flipping its
  compile-time flag (or deleting the file) removes the feature cleanly.
- **Three themes**: Sage (default), Forest, Mist — each with light and dark
  variants. Color scheme override (System / Light / Dark) in Settings.
- **Native notifications**: four levels (Off, Badge only, Notify, Notify with
  preview), configurable polling interval, sound toggle. If notification
  permission is denied, the level silently demotes to Badge only so the UI
  doesn't lie about firing banners.
- **Dock badge** showing the unread count.
- **No background process**: closing the window fully quits the app.

## Configuration

Cmd-, opens Settings:

- **Appearance**: theme palette + color scheme override.
- **Allowed Surfaces**: opt-in non-DM tabs / behaviors.
- **Notifications**: level, sound toggle, polling cadence.

All settings are stored in
`~/Library/Containers/io.github.rquader.instadm/Data/Library/Preferences/io.github.rquader.instadm.plist`
on your machine and never leave it.

## Caveats

- Instagram's web client is the source of truth. If they redesign URLs or
  page structure, the navigation allowlist or notification-count parser may
  need a touch-up — see `Maintenance and References.md` in the project
  notes.
- For personal use. Do not use with multiple accounts in parallel.

## Disclaimer

Not affiliated with Instagram or Meta. The "Instagram" name is used
descriptively only. "InstaDM" is also a name which is descriptive to convey what the app is. Use at your own risk. The app may break when Instagram
changes its web client; users are responsible for compliance with
Instagram's Terms of Service.

## Acknowledgments

App icon composed in [Canva](https://www.canva.com/) using free
elements from Canva's content library. The underlying design elements
are © Canva and their contributors and are used here under the
[Canva Content License Agreement](https://www.canva.com/policies/content-license-agreement/);
they are not claimed as original work of this project.

---

## For developers

Everything below is for people who want to build from source or
contribute. End users should use the
[Releases](https://github.com/rquader/InstaDM/releases) download
described in **Install** above.

### Build from source

Requirements: macOS 14+ and Xcode 15+.

1. Clone the repo and open `InstaDM.xcodeproj` in Xcode.
2. In **Signing & Capabilities**, set your own Team (or "None" for an
   unsigned local build). The bundle identifier is
   `io.github.rquader.instadm`; if you fork the project for your own
   personal install, point it at your own reverse-DNS namespace.
3. Build & run (Cmd-R), or **Product → Archive → Distribute App →
   Copy App** to produce a standalone `.app` you can drop into
   `/Applications`.

### Continuous integration

- `.github/workflows/build.yml` runs `swiftc -typecheck` and an
  unsigned `xcodebuild` of the Debug configuration on every push and
  pull request to `main`.
- `.github/workflows/release.yml` triggers on `v*` tags: it does a
  Release-configuration build on the GitHub-hosted macOS runner, zips
  the resulting `.app`, and uploads it as the asset of a new GitHub
  Release. Cut a new release by running:

  ```sh
  git tag v0.2.0
  git push origin v0.2.0
  ```

### Removing optional features in code

Each opt-in non-DM surface lives in a single file with a
`static let available` compile-time flag at the top. Flip to `false`
to hide its Settings toggle, hide its tab, and lock its URLs
unconditionally. Delete the file plus the few `grep`-findable call
sites for a permanent removal.

- `InstaDM/FollowRequests.swift` — Requests tab + `/accounts/activity/*` access
- `InstaDM/SharedPosts.swift` — in-app rendering of `/p/*`, `/reel/*`, `/tv/*`
  when clicked from a DM
