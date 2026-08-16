#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT/docs/screenshots}"
mkdir -p "$DEST"

cd "$ROOT"
swift run --skip-update AskDroidScreenshots "$DEST"
echo "Wrote screenshots to $DEST"
