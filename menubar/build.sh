#!/usr/bin/env bash
# build.sh — compile + install the DSH Menubar app (no Xcode project needed).
# Usage: bash menubar/build.sh [--login-item]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/Applications/DSH Menubar.app"

echo "compiling DSHMenubarApp.swift"
swiftc -O -parse-as-library -o /tmp/dsh-menubar-bin "$HERE/DSHMenubarApp.swift"

rm -rf "$DEST"; mkdir -p "$DEST/Contents/MacOS"
cp /tmp/dsh-menubar-bin "$DEST/Contents/MacOS/dsh-menubar"
cp "$HERE/Info.plist" "$DEST/Contents/Info.plist"
codesign --force --sign - "$DEST"
echo "installed: $DEST"

if [ "${1:-}" = "--login-item" ]; then
  osascript -e 'tell application "System Events" to make login item at end with properties {name:"DSH Menubar", path:"'"$DEST"'", hidden:false}' >/dev/null \
    && echo "login item added (launches at every login)"
fi

# stop any old copy, launch the fresh one
killall dsh-menubar 2>/dev/null || true
open "$DEST"
echo "launched. The DeepSeek Harness icon is now in your menu bar."
