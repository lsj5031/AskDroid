# Plan 006: Restrict answer-link opening to http/https

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: This repo may have uncommitted working-tree
> changes (the ongoing AskDroid refactor round). The excerpts below describe
> the *current working tree*. Compare each excerpt against the live file
> before starting. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `b380f1b`, 2026-08-20

## Why this matters

Streamed answers render with `MarkdownUI` and a theme that colors links
(`Controls.swift:170-173`) but no `OpenURLAction` override. SwiftUI's default
action for a link in a macOS view opens the URL with the system handler — and,
for `file://` URLs, with the file viewer. A model answer containing
`[x](file:///Users/…)` is then one click from poking a local file/Finder action.
Model output is semi-trusted (the CLI already has the user's credentials), so
this is defense-in-depth, but it is a one-view change with zero downside:
allow opening only `http`/`https` URLs.

## Current state

- `Sources/AskDroid/HUD/HUDRootView.swift`, the answer rendering
  (lines 350–355):

  ```swift
  if !session.answer.isEmpty {
      Markdown(session.answer)
          .markdownTheme(AskDroidMarkdown.theme)
          .lineSpacing(3)
          .tracking(0.1)
          .textSelection(.enabled)
  } else if session.phase == .running {
  ```

  — no `.environment(\.openURL, …)` anywhere in `HUDRootView`.

- `Sources/AskDroid/HUD/Controls.swift`, link styling (lines 170–173):

  ```swift
  .link {
      ForegroundColor(Theme.accent)
  }
  ```

- The whole panel is one `HUDRootView` → `ExpandedHUD` view tree, so an
  `environment(\.openURL:)` modifier on the `Markdown` itself (or on the
  expanded panel) scopes the policy to answer links only.

## Commands you will need

| Purpose   | Command           | Expected on success |
|-----------|-------------------|---------------------|
| Build     | `swift build`     | exit 0              |
| Tests     | `swift test`      | 65 tests executed, 0 failures (1 skipped) |

## Scope

**In scope** (the only file you should modify):
- `Sources/AskDroid/HUD/HUDRootView.swift`

**Out of scope** (do NOT touch, even though they look related):
- `Sources/AskDroid/HUD/Controls.swift` — link *color* stays as-is.
- `Sources/AskDroid/HUD/SettingsPane.swift` — the settings documentation
  links must keep working (they are `URL(string:)` links in `Link` views, not
  answer markdown; do not change the links or their targets).

## Git workflow

- Branch: `advisor/006-answer-link-scheme`
- Conventional commit, e.g. `security(hud): only allow http(s) links in answers`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add an `openURL` override scoped to the answer renderer

Attach an `.environment(\.openURL, …)` modifier to the `Markdown(session.answer)`
view. Restrict to `http`/`https` and open via `NSWorkspace` so game behavior
stays identical for normal web links:

```swift
if !session.answer.isEmpty {
    Markdown(session.answer)
        .markdownTheme(AskDroidMarkdown.theme)
        .lineSpacing(3)
        .tracking(0.1)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            let scheme = url.scheme?.lowercased()
            if scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                return .handled
            }
            return .discarded
        })
} else if session.phase == .running {
```

Notes for the executor:
- `OpenURLAction` is in `SwiftUI` (already imported in this file).
- `NSWorkspace` is in `AppKit` (already imported transitively by this file's
  `import SwiftUI`? No — import `AppKit` explicitly at the top if the
  compiler complains; check existing imports. `HUDRootView.swift` currently
  imports `MarkdownUI`, `SwiftUI`, `UniformTypeIdentifiers` — add
  `import AppKit` if needed to resolve `NSWorkspace`).
- Returning `.discarded` swallows non-http(s) link clicks entirely (no
  fallback to the system opener).

**Verify**: `swift build` → exit 0.

### Step 2: Run the full suite

Nothing else changes.

**Verify**: `swift test` → 65 tests, 0 failures.

## Test plan

- No unit test: this is a SwiftUI environment hookup that is impractical to
  test with the current suite (no view-test infrastructure). Verification is
  the build plus manual behavior unchanged for `https` links.
- If a human reviews manually: an answer containing `[x](file:///etc/hosts)`
  should do nothing on click; `[x](https://example.com)` should open a browser.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `swift build` exits 0
- [ ] `swift test` exits 0, 65 tests, 0 failures
- [ ] `grep -n "OpenURLAction" Sources/AskDroid/HUD/HUDRootView.swift` shows the override attached to `Markdown(session.answer)`
- [ ] `grep -n "return .discarded" Sources/AskDroid/HUD/HUDRootView.swift` shows the non-http(s) branch
- [ ] `git status` shows only `Sources/AskDroid/HUD/HUDRootView.swift` modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The `Markdown(session.answer)` block at `HUDRootView.swift:350-355` differs
  from the excerpt (drift).
- `OpenURLAction` fails to compile in this file (report the exact error; do
  not work around it by moving the override to a different file without
  reporting).

## Maintenance notes

- If more rich-content surfaces are added (e.g. history browser, notifications
  with deep links), apply the same http(s)-only policy rather than embedding
  `NSWorkspace.shared.open` directly.
- If the app ever ships custom URL schemes (e.g. `askdroid://…` for internal
  navigations), whitelist them here explicitly.
- The settings pane's `Link` views are URLs in markup, outside this override's
  scope — untouched, and unaffected by it.