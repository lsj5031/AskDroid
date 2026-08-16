# AskDroid

Press a hotkey on your Mac. A HUD drops from the notch. Ask Droid, paste images, watch the answer stream, keep a Markdown file.

<img src="docs/screenshots/composer.png" width="560" alt="AskDroid HUD with a question typed in the composer">

```
⌃⌘D  →  type or paste  →  ⌘Return  →  ~/Library/Application Support/AskDroid/answers/
```

AskDroid is a native Swift/SwiftUI agent app. It does not replace Droid. It talks to the `droid` CLI you already have, using your default `~/.factory/settings.json`.

## What you need

- macOS 14 or later
- [Droid CLI](https://docs.factory.ai/droid-exec/overview) so `droid` works in Terminal
- Xcode / Swift 6 to build from source

## Build

```bash
git clone <this-repo> AskDroid
cd AskDroid
./scripts/build-app.sh
open dist/AskDroid.app
```

The app is an accessory process: no Dock icon, no menu bar item. The hotkey is the front door.

To start it at login, open the HUD, click the gear, enable **Launch at login**.

## Use it

1. Press **⌃⌘D** from any app.
2. Type a question. Paste or drop images. **⌘Return** asks, **Esc** hides.
3. While Droid works, the HUD streams the answer. Hide it and a compact pill stays under the notch.
4. Copy the answer, or open the archived Markdown file.

The answer streams token by token while the activity log reports what Droid is doing — session startup, hooks, tool calls — alongside elapsed time and token counts:

<img src="docs/screenshots/progress.png" width="560" alt="AskDroid streaming an answer while the activity log shows session milestones">

When the turn finishes you get the whole answer, a copy button, and a link to the saved file:

<img src="docs/screenshots/answer.png" width="560" alt="AskDroid showing a finished answer with Copy, Open file, and New buttons">

Press **Esc** mid-run and the HUD collapses to a pill that keeps the status under the notch:

<img src="docs/screenshots/pill.png" width="280" alt="AskDroid collapsed to a compact pill reading Thinking with elapsed time">

Files land in **Application Support/AskDroid/answers**:

```
droid-2026-08-15_20-32-00.md
droid-2026-08-15_20-32-00-1.png
```

If two questions finish in the same second, the next file gets a `-2` suffix.

## Settings

<img src="docs/screenshots/settings.png" width="560" alt="AskDroid settings panel showing hotkey, model, reasoning, autonomy, directories, and launch at login">

All optional. Blank means “use Droid’s own defaults.”

- Model override
- Reasoning effort
- Autonomy (`off` / `low` / `medium` / `high`)
- Working directory (default `~/Library/Application Support/AskDroid/workspace`)
- Answers folder (default `~/Library/Application Support/AskDroid/answers`)
- Path to the `droid` binary
- Launch at login

AskDroid looks for `droid` on `PATH`, then in `~/.local/bin`, mise shims, and Homebrew.

Default autonomy is **high**: Droid can edit files, run commands, and push, scoped to the working directory (which defaults to a sandboxed workspace under Application Support). Choose Read-only in Settings to disable tools. Any permission prompt that still appears is auto-declined.

## Tests

```bash
swift test
```

## Why not Shortcuts?

Shortcuts cannot paste images into the agent, cannot stream progress, and start with a tiny `PATH`. AskDroid is a real process that speaks Droid’s JSON-RPC protocol:

```
droid exec --input-format stream-jsonrpc --output-format stream-jsonrpc
```
