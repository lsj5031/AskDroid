# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Stack

delegated: native Swift 6 / SwiftUI + AppKit, SwiftPM-built `.app` (CLI-buildable). Platform recorded as `ios` because that is the Impeccable native-Apple slot; the shipping OS is macOS 14+.

## Users

Factory Droid users on a Mac. They are already in another app (browser, editor, mail, Slack) and want an answer from Droid without opening a terminal or fighting macOS Shortcuts.

## Product Purpose

AskDroid is a always-available desktop assistant for Droid. Press a global hotkey, a HUD drops from the notch, type a question and/or paste images, watch the answer stream, keep a Markdown archive. Success is: one keystroke from any app to a usable answer, with live progress while Droid works.

## Positioning

Unlike Shortcuts wrappers (ask-pi) it is a real native surface: image paste, live tool/progress events, cancel, settings, and a notch-hugging HUD. Unlike the interactive `droid` TUI it is one-shot, non-blocking, and lives above whatever the user is already doing. It does not replace Droid; it is a front door that uses the user's existing `droid` install and `~/.factory/settings.json` defaults.

## Operating Context

- Requires a working `droid` CLI (discovered on PATH, then common install locations).
- Default autonomy is high (`--auto high`), scoped to a sandboxed working directory; settings may lower it to read-only.
- Answers land in `~/Library/Application Support/AskDroid/answers` as timestamped Markdown plus any pasted images.
- The default working directory is `~/Library/Application Support/AskDroid/workspace`, not the user's home folder.
- Used at the laptop, often while another app is focused; the HUD must not steal the Dock or a menu-bar slot.
- External / non-notch displays fall back to a top-center HUD.

## Capabilities and Constraints

Confirmed for v1:
- Notch-only surface (no Dock icon, no menu bar item). `LSUIElement`.
- Global hotkey (default ⌃⌘D), configurable in Settings via a key recorder. Carbon `RegisterEventHotKey` with an NSEvent-monitor fallback; registration failure is surfaced in the HUD.
- One-shot conversation per question.
- Image paste and drag-and-drop (PNG/JPEG/GIF/WebP).
- Streamed Markdown in the expanded HUD.
- Compact notch pill while a run is active and the panel is dismissed.
- Archive `.md` files, copy-to-clipboard, completion notification.
- Advanced settings: hotkey, model, reasoning, autonomy, cwd, answers folder, droid path, launch at login.
- JSON-RPC client over `droid exec --input-format stream-jsonrpc --output-format stream-jsonrpc`.

Out of scope for v1: multi-turn chat, menu bar item, HTML session traces, interactive permission prompts (auto-declined).

## Brand Commitments

- Name: **AskDroid**.
- Voice: direct, short, operational. No hype.
- Mark: dark notch HUD + one amber Ask capsule (`docs/icon.png`). No wordmark, no Factory lockup.
- Visual world is the native macOS notch HUD: charcoal, one amber accent, "operate, don't decorate."

## Evidence on Hand

- Inspiration: https://github.com/lsj5031/ask-pi
- Integration: https://docs.factory.ai/droid-exec/overview and `@factory/droid-sdk` image/stream APIs
- Local: Xcode 26.6, Swift 6.3, `droid` 0.197.0 at `~/.local/bin/droid`

Do not invent testimonials, user counts, or Factory-official branding. This is a local assistant that talks to the user's Droid, not a Factory-shipped product unless that changes later.

## Product Principles

1. Stay out of the way until summoned; then be instantly usable.
2. Prefer the user's Droid defaults over our own opinions.
3. Show work as it happens (progress, tools, streaming text), not a spinner that dies into a file.
4. Persist answers so the HUD can disappear without losing the result.
5. Fail clearly when `droid` is missing, unauthenticated, or a run is cancelled.

## Accessibility & Inclusion

Honor Reduce Motion. Keep hit targets at least 24 pt in the compact pill and 28 pt in the expanded panel. Support VoiceOver labels on submit, cancel, copy, settings, and quit. Dynamic Type is limited by the HUD's fixed notch geometry; body text should still remain readable at default and large sizes.
