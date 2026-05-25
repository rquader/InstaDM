# Changelog

All notable changes to this project are documented here. Dates use
`YYYY-MM-DD`.

## [Unreleased]

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

### Repo hygiene
- Removed committed `.DS_Store` and `xcuserdata/` artifacts.
- `.gitignore` extended to cover `.cursor/` and `.claude/` local
  tool-state folders.
- Added GitHub Actions CI workflow that typechecks the Swift sources
  and runs an unsigned Debug build on every push.
- Added `CONTRIBUTING.md` and this `CHANGELOG.md`.

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
