# Design

<!-- impeccable:design-schema 1 -->

## World

AskDroid is a notch-hugging macOS accessory. The visual world is a dark instrument panel that appears only when summoned: charcoal fill, one amber accent, SF Pro, hairline separators. It is an Operate surface. The HUD is the product.

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

- Compact pill: 280 × 34 capsule under the notch while a run is live and the panel is hidden.
- Expanded panel: 560 pt wide, 18 pt continuous corners, header / composer / answer / footer.
- Primary action: amber capsule. Secondary: well capsule.
- Status dot: 8 pt, amber pulse while running.

## Motion

180 ms ease-out expand from the notch. Status-dot pulse only, and it honors Reduce Motion.

## Surfaces

- Idle / composing HUD
- Running stream + compact pill
- Completed answer with copy / open file
- Failed / missing droid
- Settings overrides
