# Design

<!-- impeccable:design-schema 1 -->

## World

AskDroid is a notch-hugging macOS accessory. The visual world is a dark instrument panel that appears only when summoned: charcoal fill, one amber accent, SF Pro, hairline separators. It is an Operate surface. The HUD is the product.

The app icon is that surface as a mark: a charcoal island hanging from a camera-notch bite, two ink prompt lines, one amber Ask capsule. No wordmark. Master art is `packaging/AppIcon-source.jpg`; `swift scripts/make-icon.swift` packs the `.icns`.

## Palette

- Panel: `#121213` at ~96% opacity
- Pill: `#141416`
- Ink: white @ 92%
- Mute: white @ 56%
- Hairline: white @ 10%
- Well: black @ 28%
- Accent: `#FA9E2E`
- Success: `#73D685`
- Danger: `#FF7361`

Light mode is not shipped. The HUD sits against the menu bar / notch in a typically dark chrome strip.

## Type

SF Pro only. 15 pt composer, 14 pt answer, 13 pt chrome, 12 pt buttons, 11 pt meta. No display face.

## Components

- Compact pill: leading and trailing wings beside the camera housing (charcoal `#141416` + hairline) while a run is live. The gap under the lens stays black and never reacts to clicks (the camera cutout is dead space in every app, so clicks there are inert rather than pass-through — AppKit has no per-region `ignoresMouseEvents`). The pill sits in the menu-bar row beside the lens; its wings cover the strip of menu bar next to the notch, so clicks there expand the HUD rather than reaching the menu bar. Non-notch displays use a 280 × 34 floating capsule.
- Expanded panel: 560 pt wide, one Island fill, content inset below the lens. Idle is prompt + Ask. With conversation history the panel is the multi-turn surface: collapsed prior turns above the newest turn, footer meta, then the composer, which persists for follow-ups. While a turn streams the composer offers the engine default (Steer on wire-steering engines, Queue elsewhere) plus a secondary Queue ghost on wire-steering engines; pending messages chip per mode ("Steering…" until delivered, "Queued · after this turn" until sent).
- Collapsed turn row: the question-as-a-line repeated — status glyph, question truncated to one line, duration, disclosure chevron (13 pt, Mute; duration 11 pt monospaced digit). Tap expands that turn's answer in place inside the shared scroll.
- Primary action: amber capsule. Secondary: well capsule.
- Status dot: 8 pt, amber pulse while running.

## Motion

220 ms ease-out expand/collapse. Reduce Motion is 120 ms. Status-dot pulse honors Reduce Motion.

## Surfaces

- Idle / composing HUD
- Running stream + compact pill
- Multi-turn conversation: collapsed prior turns above the full-size newest turn in one capped scroll; composer stays available below for follow-ups and steering
- Completed answer with copy / open file
- Failed / missing droid
- Settings overrides
