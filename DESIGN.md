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

- Compact pill: leading and trailing wings beside the camera housing (charcoal `#141416` + hairline) while a run is live. The gap under the lens stays black and click-through. Non-notch displays use a 280 × 34 floating capsule.
- Expanded panel: 560 pt wide, Island silhouette (top radius 12, bottom 18), black notch band, then header / composer / answer / footer on panel fill.
- Primary action: amber capsule. Secondary: well capsule.
- Status dot: 8 pt, amber pulse while running.

## Motion

Jelly spring on expand/collapse (mass 0.62, stiffness 210, damping 15.5) with a vertical squash / horizontal stretch pulse, anchored at the notch. Reduce Motion is a 120 ms ease-out with no squash. Hover-peek uses a slightly stiffer spring. Status-dot pulse honors Reduce Motion.

## Surfaces

- Idle / composing HUD
- Running stream + compact pill
- Completed answer with copy / open file
- Failed / missing droid
- Settings overrides
