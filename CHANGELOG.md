# Changelog

All notable changes to this project are documented here. Dates use
`YYYY-MM-DD`.

## [Unreleased]

### Fixed
- Profile tap while DMs are minimized no longer leaks the full Instagram
  UI. The leak path is Instagram's React-handled click — `preventDefault()`
  + `history.pushState('/<username>/')` — which fires **no** navigation
  event, so `decidePolicyFor` never gets to refuse. URL-only defense in
  `NavigationPolicy` cannot block this in principle.

  Defense added in `WebView.spaNavigationGuardJS` (documentStart user
  script, `forMainFrameOnly: true`):
  - **Capture-phase click listener** on `document` that resolves the
    target `<a href>`'s path and `preventDefault()` +
    `stopImmediatePropagation()`s any non-DM path. Runs before IG's
    bundle hydrates, so IG's delegated handler never sees the click.
  - **Wraps `history.pushState` / `history.replaceState`** to silently
    drop URL changes targeting non-DM paths. IG reads the wrapped
    versions when its bundle loads.

  Allowed prefixes mirror `NavigationPolicy.isDirectMessagingPath` +
  auth/internal allowlist; update both sides together when adding a
  surface.

  Side effect: clicking the messenger's "minimize" button is now a
  no-op (its pushState target is `/direct` or `/`, both blocked). URL
  stays on the thread; the feed never renders underneath. Matches the
  DM-only product intent.

### Added
- `#if DEBUG`-gated `dlog(...)` instrumentation in `WebView.Coordinator`
  for tracing navigation decisions during regression repros. Filter
  `Console.app` for `[InstaDM/` to capture the full trace. Release
  builds compile to a no-op.

## [1.0.2] - 2026-05-25

### Fixed
- Login spinner never completing after entering credentials on macOS 26.
  Root causes and fixes in `WebView.swift`:
  - Nil `safeRequest` during login AJAX: allow only in auth context (not
    globally — a global allow leaked full Instagram).
  - Post-login 302 through `/`: allow redirect to commit Set-Cookie, then
    cookie-gated route to inbox (`awaitingInboxHandoff` +
    `routeToInboxWhenAuthenticated`).
  - Auth redirect detection uses source-frame auth surface, not stale
    `webView.url`.
- Full Instagram UI leaking in-app (notifications, search, profiles,
  group-chat chrome). `NavigationPolicy` + `WebView.Coordinator`:
  - Replaced blanket `/accounts` prefix with auth-only subpaths
    (`/accounts/login`, `/accounts/onetap`, …).
  - Replaced blanket `/direct` with narrowed `isDirectMessagingPath()`
    (`/direct/inbox`, `/direct/t/`, `/direct/new` only).
  - Added `isInAppUserSurface()` — internal endpoints (`/api`, …) may
    load as XHR but must not become the main document.
  - Cancel blocked navigations at action + response; `stopLoading()` +
    `didFinish` bounce as safety net.
  - DM context link taps to blocked URLs open in Safari; group-chat
    sender taps use `isInDirectContext()` (source frame **or** current URL).

### Changed
- Cosmetic CSS hides notification / activity / account-edit links in
  addition to Home / Explore / Reels.

### Notes for maintainers
- A **WKContentRuleList + didCommit hardening experiment** in the same
  session was reverted before release — it regressed profile blocking
  and login handoff. See Obsidian note [[2026-05-25 — Navigation Policy
  Session and Agent Handoff]] § "Experiments that failed".

## [1.0.1] - 2026-05-25

### Fixed
- Crash on first navigation on macOS 26 (Tahoe).
  `WKNavigationAction.request` and `WKFrameInfo.request` are imported
  into Swift as IUO `URLRequest!`. On macOS 26 WebKit, both are
  empirically nil for synthetic / session-restored frames during the
  very first `decidePolicyForNavigationAction` call. The IUO bridge
  trap (`URLRequest._unconditionallyBridgeFromObjectiveC`) crashed the
  app with `EXC_BREAKPOINT` before any UI rendered. All three call
  sites in `WebView.Coordinator` now read `.request` through KVC
  (`safeRequest`) so a runtime-nil value does not trap. macOS 14/15
  builds are unaffected.
- App version bumped to `1.0.1` so the new release is distinguishable
  from the broken `1.0` build.

## [1.0.0] - 2026-05-25

### Fixed
- Requests tab no longer infinite-reloads when Instagram's
  follow-requests URL 302s into a blocked URL. `WebView.Coordinator`
  now records the timestamp of every bounce-to-home and refuses to
  bounce again within a 5-second cooldown, breaking the
  302 → blocked → bounce → 302 cycle. A successful navigation clears
  the timestamp so legitimate bouncing later is not suppressed.

### Changed
- `FollowRequests.available` is back to `true`. The historical reason
  for disabling it (the reload loop above) no longer applies; worst
  case the tab renders blank, which is recoverable by switching tabs.
- Bundle identifier set to `io.github.rquader.instadm` — a real
  reverse-DNS string keyed to this GitHub project, stable across the
  upstream repo and the maintainer's personal install. Forks should
  retarget to their own namespace.

### Added
- App icon: a brown speech-bubble mark with three text lines composed
  in Canva from free content-library elements. Generated into the
  AppIcon.appiconset at all ten Mac sizes (16×16 through 512×512 @1x
  and @2x) from a single 1024×1024 source. Underlying elements remain
  © Canva and their contributors per the
  [Canva Content License Agreement](https://www.canva.com/policies/content-license-agreement/);
  see README's Acknowledgments section.
- `v0.1.0` GitHub Release with a pre-built unsigned `InstaDM.app.zip`
  so users without Xcode can drop the app into `/Applications`.

### Removed
- `LICENSE` and `CONTRIBUTING.md`. The repo is source-available but no
  rights are explicitly granted at this time; default copyright applies.
  Not explicitly denying outside contributions either — issues are
  welcome, PRs will be considered case-by-case.

### Repo hygiene
- Removed committed `.DS_Store` and `xcuserdata/` artifacts.
- `.gitignore` extended to cover `.cursor/` and `.claude/` local
  tool-state folders.
- Added GitHub Actions CI workflow that typechecks the Swift sources
  and runs an unsigned Debug build on every push.
- Added this `CHANGELOG.md`.

## 2026-05-16 — Allowed Surfaces Pass

See the project notes' `2026-05-16 — Allowed Surfaces Pass.md` entry
for the full record. Headline items:

- Two opt-in non-DM surfaces (`FollowRequests`, `SharedPosts`) under
  one-file feature modules.
- `NavigationPolicy.pathMatches` directory-boundary helper that fixes
  a class of greedy-match bugs (e.g. `/p` no longer matches
  `/profile/`).
- `NotificationManager` race-safe `detach(forWebView:)`, permission-
  denial demotion to `.badgeOnly`, pending/delivered notifications
  cleared on level → Off, settings-change work guarded on
  `levelChanged || intervalChanged`.

## 2026-05-11 — Phase 1 MVP

Initial Phase 1 build: SwiftUI window hosting `WKWebView` with a
navigation allowlist, three palettes (Sage / Forest / Mist) with
light + dark variants, native notifications with four levels and
configurable polling, and `applicationShouldTerminateAfterLastWindowClosed`
lifecycle. Apple frameworks only; zero third-party dependencies.
