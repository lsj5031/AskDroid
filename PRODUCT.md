# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Stack

delegated: native Swift 6 / SwiftUI + AppKit, SwiftPM-built `.app` (CLI-buildable). Platform recorded as `ios` because that is the Impeccable native-Apple slot; the shipping OS is macOS 14+.

## Users

Users of Pi or Factory Droid on a Mac. They are already in another app (browser, editor, mail, Slack) and want an answer from an AI coding agent without opening a terminal or fighting macOS Shortcuts.

## Product Purpose

AskDroid is an always-available desktop assistant for Pi and Droid. Press a global hotkey, a HUD drops from the notch, type a question and/or paste images, watch the answer stream, keep a Markdown archive. Success is: one keystroke from any app to a usable answer, with live progress while the agent works.

## Positioning

Unlike Shortcuts wrappers (ask-pi) it is a real native surface: image paste, live tool/progress events, cancel, settings, and a notch-hugging HUD. Unlike interactive terminal TUIs it is one-shot, non-blocking, and lives above whatever the user is already doing. It does not replace Pi or Droid; it is a front door that uses the user's existing CLI installations.

## Operating Context

- Requires a working `pi` or `droid` CLI (discovered on PATH, then common install locations like mise, Homebrew, ~/.local/bin).
- Default engine is Pi (`pi --mode rpc --no-session`).
- For Droid, default autonomy is high (`--auto high`), scoped to a sandboxed working directory; settings may lower it to read-only.
- Answers land in `~/Library/Application Support/AskDroid/answers` as timestamped Markdown plus any pasted images.
- The default working directory is `~/Library/Application Support/AskDroid/workspace`, not the user's home folder.
- Used at the laptop, often while another app is focused; the HUD must not steal the Dock or a menu-bar slot.
- External / non-notch displays fall back to a top-center HUD.

## Capabilities and Constraints

Confirmed for v1:
- Notch-only surface (no Dock icon, no menu bar item). `LSUIElement`.
- Global hotkey (default ⌃⌘D), configurable in Settings via a key recorder. Carbon `RegisterEventHotKey` with an NSEvent-monitor fallback; registration failure is surfaced in the HUD.
- Dual-engine architecture: Pi (RPC) and Droid (JSON-RPC).
- One-shot conversation per question.
- Image paste and drag-and-drop (PNG/JPEG/GIF/WebP).
- Streamed Markdown and thinking tokens in the expanded HUD.
- Compact notch pill while a run is active and the panel is dismissed.
- Archive `.md` files, copy-to-clipboard, completion notification.
- Advanced settings: engine picker, hotkey, model, reasoning superset, autonomy, cwd, answers folder, binary path, launch at login.
- Real-time JSON-RPC and RPC stdio clients (`pi --mode rpc`, `droid exec --input-format stream-jsonrpc`).

Out of scope for v1: multi-turn chat, menu bar item, HTML session traces, interactive permission prompts (auto-declined).

## Brand Commitments

- Name: **AskDroid**.
- Voice: direct, short, operational. No hype.
- Mark: dark notch HUD + one amber Ask capsule (`docs/icon.png`). No wordmark, no Factory lockup.
- Visual world is the native macOS notch HUD: charcoal, one amber accent, "operate, don't decorate."

## Evidence on Hand

- Inspiration: https://github.com/lsj5031/ask-pi
- Integration: https://pi.dev/docs/latest and https://docs.factory.ai/droid-exec/overview
- Local: Xcode 26.6, Swift 6.3, `pi` 0.84.2, `droid` 0.197.0

Do not invent testimonials, user counts, or official branding. This is a local assistant that talks to the user's CLI tools.

## Product Principles

1. Stay out of the way until summoned; then be instantly usable.
2. Prefer the user's CLI defaults over our own opinions.
3. Show work as it happens (progress, tools, streaming text), not a spinner that dies into a file.
4. Persist answers so the HUD can disappear without losing the result.
5. Fail clearly when the engine is missing, unauthenticated, or a run is cancelled.

## Accessibility & Inclusion

Honor Reduce Motion. Keep hit targets at least 24 pt in the compact pill and 28 pt in the expanded panel. Support VoiceOver labels on submit, cancel, copy, settings, and quit. Dynamic Type is limited by the HUD's fixed notch geometry; body text should still remain readable at default and large sizes.
