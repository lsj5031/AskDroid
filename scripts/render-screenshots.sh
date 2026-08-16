#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT/docs/screenshots}"
mkdir -p "$DEST"

"$ROOT/scripts/build-app.sh" debug
ASKDROID_SCREENSHOTS="$DEST" "$ROOT/dist/AskDroid.app/Contents/MacOS/AskDroid"
echo "Wrote screenshots to $DEST"
