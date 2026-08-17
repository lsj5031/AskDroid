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
- Expanded panel: 560 pt wide, one Island fill, content inset below the lens. Idle is prompt + Ask. A live or finished turn shows the question as a line, then the answer. Activity is a disclosure. Quit lives in Settings.
- Primary action: amber capsule. Secondary: well capsule.
- Status dot: 8 pt, amber pulse while running.

## Motion

220 ms ease-out expand/collapse. Reduce Motion is 120 ms. Status-dot pulse honors Reduce Motion.

## Surfaces

- Idle / composing HUD
- Running stream + compact pill
- Completed answer with copy / open file
- Failed / missing droid
- Settings overrides
