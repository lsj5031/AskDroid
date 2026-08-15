#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${1:-release}"
DEST="${2:-$ROOT/dist/AskDroid.app}"

echo "Building AskDroid ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product AskDroid

BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)/AskDroid"
APP="$DEST"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN" "$MACOS/AskDroid"
chmod +x "$MACOS/AskDroid"
cp "$ROOT/packaging/Info.plist" "$CONTENTS/Info.plist"

if [[ -f "$ROOT/packaging/AppIcon.icns" ]]; then
  cp "$ROOT/packaging/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null

echo "Built $APP"
echo "Launch with: open \"$APP\""
echo "Optional: cp -R \"$APP\" /Applications/"
