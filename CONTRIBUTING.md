# Contributing

This is a small, single-purpose macOS app. Contributions are welcome but
the project has strong opinions; please read this file before opening a
PR.

## Non-negotiable constraints

These are constraints, not preferences. PRs that violate them will be
closed without review.

1. **No external dependencies.** Apple frameworks only (`SwiftUI`,
   `WebKit`, `AppKit`, `UserNotifications`, `Foundation`). No Swift
   Package Manager packages, no CocoaPods, no third-party SDKs.
2. **No network traffic except to Instagram (and Meta auth).** The app
   makes one and only one external connection: the embedded `WKWebView`
   talking to `*.instagram.com` / `accounts.instagram.com`. No
   analytics, telemetry, crash reporters, A/B frameworks, "phone home
   for updates" mechanisms.
3. **No persistence of message content, sender names, cookies, or
   tokens** anywhere in source-controlled files or in the app's own
   files. The web view's cookie store (`WKWebsiteDataStore.default()`)
   is the only persistence surface for Instagram data.
4. **No debug logging of message content, cookies, or tokens.** Use
   `print()` / `os_log` / `NSLog` only for transient developer
   diagnostics that get removed before merge.
5. **No hardcoded paths under `/Users/<name>/`, no hardcoded usernames,
   no personal Apple ID / Team ID** in committed files.

## Architecture in 60 seconds

The app is a SwiftUI window hosting a `WKWebView`. A `WKNavigationDelegate`
checks every navigation against `NavigationPolicy.isAllowed(_:source:)`.
Anything outside the DM surface is cancelled and either opened in Safari
(user clicks) or silently dropped (server redirects / JS).

Optional non-DM surfaces (currently `FollowRequests`, `SharedPosts`) each
live in their own file with a compile-time `available` flag and a runtime
`enabled` getter. The pattern is documented in those files; see also
the relevant sections of the source for how they wire into
`NavigationPolicy`, `ContentView`, `SettingsView`, and `Settings`.

## Local development

```sh
git clone <fork-url>
cd InstagramDMOnlyApp
open InstaDM.xcodeproj   # or: xed .
```

Set your own Team in **Signing & Capabilities** (or leave it "None" for
an unsigned local build). The bundle identifier is
`io.github.rquader.instadm`. If you're forking for your own install,
point it at your own reverse-DNS namespace (e.g.
`io.github.<your-handle>.instadm`); contributions to this repo should
not change the upstream identifier.

### Typecheck without Xcode

```sh
swiftc -typecheck -target arm64-apple-macos14.0 InstaDM/*.swift
```

This is what CI runs and it catches most issues.

## Style

- Match the surrounding code. Existing files use heavy doc comments to
  explain the *why*; keep that going.
- No comments that narrate what the code does ("// increment counter").
  Comments should explain non-obvious intent, trade-offs, or invariants
  the code can't express on its own.
- 4-space indents, trailing commas where Xcode formats them in by default.

## PR checklist

Before opening a PR:

- [ ] `swiftc -typecheck -target arm64-apple-macos14.0 InstaDM/*.swift`
      passes.
- [ ] No `print(` / `os_log` / `NSLog` of cookies, tokens, or message
      content (grep your diff).
- [ ] No new dependency in any form.
- [ ] Bundle identifier is still `io.github.rquader.instadm` in
      `.pbxproj` (or your fork's equivalent — do not commit a personal
      bundle ID change back to upstream).
- [ ] `DEVELOPMENT_TEAM` is not set in `.pbxproj`.
- [ ] No `xcuserdata/`, `.DS_Store`, or other auto-generated personal
      files in the diff.
- [ ] If you added a new opt-in surface, it follows the feature-module
      pattern (single file with `available` / `defaultEnabled` /
      `enabled` / URL / allowed prefixes / display name).

## Reporting bugs

Open an issue. Include:

- macOS version.
- Xcode version (if it's a build issue).
- What you did and what happened.
- For navigation/blocking bugs: the URL involved, if you can capture it
  (Safari → Develop → [your machine] → InstaDM shows live WebKit
  inspector access to the running web view — easiest way to capture
  what was being navigated to).
