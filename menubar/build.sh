#!/usr/bin/env bash
# Build, sign, and install only the menu-bar app; never restart the DSH host.
# Usage: bash menubar/build.sh [--login-item]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/Applications/DSH Menubar.app"
BACKUP="$HOME/Applications/DSH Menubar.previous.app"
[ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --login-item ]; } || { echo "usage: $0 [--login-item]" >&2; exit 2; }
mkdir -p "$HOME/Applications"
STAGE=$(mktemp -d "$HOME/Applications/.dsh-menubar-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
CANDIDATE="$STAGE/DSH Menubar.app"
mkdir -p "$CANDIDATE/Contents/MacOS"
swiftc -module-cache-path "$STAGE/module-cache" -O -parse-as-library \
  -o "$CANDIDATE/Contents/MacOS/dsh-menubar" "$HERE/DSHMenubarApp.swift" "$HERE/CommandRunner.swift"
cp "$HERE/Info.plist" "$CANDIDATE/Contents/Info.plist"
codesign --force --sign - "$CANDIDATE"
codesign --verify --strict "$CANDIDATE"
# Compilation and signing finish before the existing menubar is stopped.
killall dsh-menubar 2>/dev/null || true
if [ -d "$DEST" ]; then
  rm -rf "$BACKUP"
  mv "$DEST" "$BACKUP"
fi
if ! mv "$CANDIDATE" "$DEST"; then
  [ ! -d "$BACKUP" ] || mv "$BACKUP" "$DEST"
  open "$DEST" || true
  exit 1
fi
if [ "${1:-}" = --login-item ]; then
  osascript - "$DEST" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    if not (exists login item "DSH Menubar") then
      make login item at end with properties {name:"DSH Menubar", path:item 1 of argv, hidden:false}
    end if
  end tell
end run
APPLESCRIPT
fi
open "$DEST"
echo "Installed and launched DSH Menubar. Previous version: $BACKUP"
