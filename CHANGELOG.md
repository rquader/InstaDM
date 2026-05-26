# Changelog

All notable changes to this project are documented here. Dates use
`YYYY-MM-DD`.

## [Unreleased]

## [1.0.0] - 2026-05-26

First public release. InstaDM is a native macOS app for Instagram direct
messages only — no feed, reels tab, explore, or stories.

### Fixed (login)

- Fresh login looped back to the login form after correct credentials.
  Blocked navigations during auth were bouncing to `/direct/inbox/` before
  `sessionid` existed; Instagram immediately sent the user back to login.
  Mid-auth cancels now stay put; inbox load waits for `sessionid` only.
- Post-login SPA `pushState` to `/` or `/direct` is rewritten to
  `location.replace('/direct/inbox/')` on auth/challenge pages.
- CI release builds are ad-hoc signed with sandbox entitlements (login also
  failed on the first v1.0.0 zip for that reason).

### Highlights

- **DM-only navigation** — layered Swift URL policy plus a document-start
  JavaScript guard that blocks SPA `pushState` profile leaks; cosmetic CSS
  hides left-rail Home / Explore / Reels / Notifications distractions.
- **Shared media in DMs** — posts and reels shared in a thread render
  inline; they stay in-app and do not open an external browser.
- **Native notifications** — Off, Dock badge only, or Banner alert, with
  configurable polling and optional sound when banners fire.
- **Settings** — macOS grouped Form; Sage accent on native chrome; System /
  Light / Dark color scheme override. Instagram's web view keeps its own
  theme.
- **Opt-in Requests tab** for follow requests (`FollowRequests` feature
  module).
- **macOS 14+**, tested through macOS 26 (Tahoe), including first-
  navigation crash and login-handoff fixes.
- **Distribution** — ad-hoc signed `InstaDM.app.zip` on GitHub Releases
  (embeds `app-sandbox` + `network.client` entitlements). First launch:
  right-click → Open, or
  `xattr -dr com.apple.quarantine /Applications/InstaDM.app`.

### Intentional behavior

- Messenger **minimize is a no-op** — its `pushState` target (`/` or
  `/direct`) is blocked so the feed never renders under an open thread.
- Blocked link taps can open in the default browser (toggle in Settings →
  Links); login and account-recovery flows may still use the browser when
  Instagram requires it.

### For developers

- `#if DEBUG`-gated `dlog(...)` in `WebView.Coordinator` traces navigation
  decisions (filter Console.app for `[InstaDM/`). Release builds no-op.
- When extending allowed DM paths, keep `NavigationPolicy.isDirectMessagingPath`
  and `NavigationPolicy.jsMessagesTabAllowedPathPrefixes` in sync.

---

## Pre-release development

Internal milestones before the v1.0.0 tag. Earlier GitHub releases
(`v0.1.x`) were withdrawn.

### Navigation hardening (2026-05-25)

- Profile tap while DMs minimized blocked via `WebView.spaNavigationGuardJS`
  (capture-phase click listener + wrapped `history.pushState` /
  `history.replaceState`).
- Narrowed `/accounts` to auth-only subpaths; narrowed `/direct` to inbox,
  thread, and new-message paths; blocked full Instagram UI leaks at action,
  response, and `didFinish`.
- Login spinner / handoff fixes for macOS 26; nil `safeRequest` KVC guard
  for first-navigation crash on Tahoe.
- Bounce-cooldown loop guard for follow-requests tab 302 cycles.

### Settings simplification (2026-05-25)

- Removed Forest / Mist themes (Sage accent only).
- Notification levels trimmed to three; removed experimental preview level.
- Settings window switched to native grouped Form styling.

### Earlier milestones

- **2026-05-16 — Allowed Surfaces Pass** — `FollowRequests` / `SharedPosts`
  feature modules; `NavigationPolicy.pathMatches` directory-boundary helper;
  notification permission demotion and race-safe detach.
- **2026-05-11 — Phase 1 MVP** — SwiftUI + `WKWebView` shell, navigation
  allowlist, native notifications, no background process. Apple frameworks
  only.
