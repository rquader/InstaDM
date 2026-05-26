# Changelog

All notable changes to this project are documented here. Dates use
`YYYY-MM-DD`.

## [Unreleased]

## [1.0.2] - 2026-05-25

### Fixed
- Login spinner never completing after entering credentials on macOS 26.
  Two regressions from the macOS 26 `safeRequest` work and the 2026-05-16
  silent-cancel path in `handleBlocked`:
  - When KVC could not read `navigationAction.request`, the delegate
    cancelled the navigation — that broke login form/AJAX submits and
    left the Log-in button spinning forever. Unknown URLs now `.allow`
    instead of `.cancel`.
  - After a successful login Instagram often 302s through `/` (the feed).
    `/` is blocked by policy, and the "already on an allowed page → silent
    cancel" path swallowed that redirect while the web view was still on
    `/accounts/login/`. Auth pages now bounce to `homeURL` (inbox) when
    a blocked `/` redirect fires, restoring pre-2026-05-16 behavior for
    that case only.

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
