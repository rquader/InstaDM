# InstaDM

A native macOS app that's meant to give you Instagram **messaging and nothing else** —
direct messages and group chats, without the feed, reels, explore, or
stories.

## What it is

A small SwiftUI app that embeds Instagram's web client in a `WKWebView` and
enforces a **layered** navigation policy: a Swift-side URL allowlist in
`NavigationPolicy` plus a document-start JavaScript guard that blocks SPA
click/`history.pushState` leaks Instagram's React bundle would otherwise
slip past `decidePolicyFor`. Anything outside direct-messaging paths (plus
login / challenge / internal AJAX) stays blocked. Posts and reels shared in
your messages render inline in the thread — they stay in-app and do not open
an external browser.

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

- **DM-only navigation**: layered URL policy + document-start JS guard block
  clicks and SPA `pushState`/`replaceState` that would leave direct-messaging
  paths. Blocked link taps can open in your default browser (configurable).
  Server-side redirects into blocked URLs are caught by a bounce-cooldown
  loop guard so a misbehaving Instagram surface can't trap the web view in
  an infinite reload. Cosmetic CSS hides left-rail Home / Explore / Reels /
  Notifications links so you aren't tempted toward surfaces the policy blocks
  anyway — that CSS is not a security layer and will drift when Instagram
  reshuffles its DOM.
- **Allowed-surfaces toggles** (opt-in): show a "Requests" tab for follow
  requests. A compile-time `SharedPosts` module exists for the rare case
  where Instagram navigates away from the thread to a `/p/` or `/reel/`
  URL instead of rendering inline; it is currently disabled because the
  inline path covers normal use. Off by default; each surface is a one-file
  feature module so flipping its compile-time flag (or deleting the file)
  removes the feature cleanly.
- **Appearance**: Sage accent on native chrome (tab bar, system tints).
  Color scheme override (System / Light / Dark) in Settings. Instagram's web
  view keeps its own theme — InstaDM does not restyle it.
- **Native notifications**: three levels — Off, Dock badge only, Banner
  alert — plus configurable polling interval and a sound toggle when banners
  fire. If notification permission is denied, the level silently demotes to
  Dock badge only so the UI doesn't lie about firing banners.
- **Dock badge** showing the unread count (when notifications aren't Off).
- **No background process**: closing the window fully quits the app.

### Intentional quirks

- **Messenger minimize is a no-op.** Instagram's minimize button pushes
  `/direct` or `/`, both blocked by design so the feed never renders
  underneath an open thread. The URL stays on the thread — that matches the
  DM-only intent.

## Configuration

Cmd-, opens Settings (macOS grouped Form):

- **Notifications**: Off / Dock badge only / Banner alert, sound toggle
  (when banners fire), polling cadence.
- **Links**: open blocked link taps in your default browser, or keep them
  in-app (they cancel silently). Login and account-recovery flows may still
  use the browser when Instagram requires it.
- **Appearance**: color scheme override (System / Light / Dark).
- **Allowed Surfaces**: opt-in non-DM tabs / behaviors.

All settings are stored in
`~/Library/Containers/io.github.rquader.instadm/Data/Library/Preferences/io.github.rquader.instadm.plist`
on your machine and never leave it.

## Caveats

- Instagram's web client is the source of truth. If they redesign URLs or
  page structure, the navigation allowlist, JS guard allowlists, cosmetic
  CSS selectors, or notification-count parser may need a touch-up — see
  `Maintenance and References.md` in the project notes. When adding a DM
  subpath, update both `NavigationPolicy.isDirectMessagingPath` and
  `NavigationPolicy.jsMessagesTabAllowedPathPrefixes` together or the two
  layers will drift.
- For personal use. Do not use with multiple accounts in parallel.
- Tested on macOS 14–26. macOS 26 (Tahoe) required login-handoff and
  first-navigation crash fixes in 1.0.1–1.0.2.

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
  git tag v1.0.3
  git push origin v1.0.3
  ```

### Removing optional features in code

Each opt-in non-DM surface lives in a single file with a
`static let available` compile-time flag at the top. Flip to `false`
to hide its Settings toggle, hide its tab, and lock its URLs
unconditionally. Delete the file plus the few `grep`-findable call
sites for a permanent removal.

- `InstaDM/FollowRequests.swift` — Requests tab + `/accounts/activity/*` access
- `InstaDM/SharedPosts.swift` — in-app rendering of `/p/*`, `/reel/*`, `/tv/*`
  when clicked from a DM (`available` is currently `false`)

### Navigation policy layers

Two layers must stay in sync when you extend allowed paths:

1. **`NavigationPolicy`** — Swift-side `decidePolicyFor` allowlist
   (`isDirectMessagingPath`, auth prefixes, opt-in surfaces).
2. **`WebView.spaNavigationGuardJS`** — document-start user script that
   blocks capture-phase clicks and wraps `history.pushState` /
   `history.replaceState`. Allowlists live in
   `NavigationPolicy.jsCommonAllowedPathPrefixes` and
   `NavigationPolicy.jsMessagesTabAllowedPathPrefixes`.

`#if DEBUG`-gated `dlog(...)` in `WebView.Coordinator` traces navigation
decisions during regression repros. Filter Console.app for `[InstaDM/`.
Release builds compile it to a no-op.
