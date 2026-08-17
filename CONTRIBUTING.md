# Contributing to AskDroid

Thanks for wanting to help! AskDroid is a small native macOS app; keep changes
proportional to the surface.

## Project layout

- `Sources/AskDroid/` — the `AskDroidKit` library: app, HUD, engine, protocol
- `Sources/AskDroidMain/` — thin executable entry point
- `Sources/AskDroidScreenshots/` — off-process screenshot renderer
- `Tests/AskDroidTests/` — unit tests (mostly the engine, protocol, and geometry)

## First

1. **Say what you're doing** — open an issue or comment on one before a big PR
   so the effort isn't wasted.
2. **Build and test:**
   ```bash
   swift build
   swift test
   ```
3. **Read `DESIGN.md` and `PRODUCT.md`** — the visual and product commitments
   are short and load-bearing (one accent, dark-only, "operate, don't decorate").

## Conventions

- **Commits**: conventional style (`feat:`, `fix:`, `refactor:`, `docs:`,
  `test:`, `chore:`), lower-case summary, one logical change per commit.
- **HUD changes** update the README captures:
  ```bash
  ./scripts/render-screenshots.sh
  ```
- **API surface**: `AskDroidKit` is a library; exported types should stay
  minimal. New AppKit/SwiftUI interactions must respect Reduce Motion and
  VoiceOver labels the way the existing HUD does.
- **No secrets or personal data**: the app talks only to the user's own
  `droid` CLI. Keep it that way.

## Pull requests

- Small, focused PRs review fastest.
- Keep tests green: `swift test` (the real-CLI integration test skips unless
  `ASKDROID_INTEGRATION=1` is set).
- Note in the PR body if you changed the HUD visuals, so screenshots get a
  regeneration pass.

## Code of conduct

Contributors are expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).