#!/usr/bin/env bash
# package-and-install.sh — the ONLY safe shell-only install path.
#
# Background (2026-08-26 lesson): bare `native package` reseeds
# supervisor/node_modules from npm metadata. Any harness packages built from
# the LOCAL deepseek-harness checkout (HEAD may contain unpublished fixes,
# e.g. 933bcc176c) disappear from the bundle, silently. Never install the
# output of a bare package run: ALWAYS re-sync from the harness repo first.
#
#   package-and-install.sh [--skip-build] [--skip-check]
#
# Steps: native check → (build) → package (with the @img/libvips StreamTooLong
# dance) → scripts/sync-runtime.mjs from the harness repo → codesign → swap
# /Applications with rollback → stamp ~/.dsh/update-state.json.
# Does NOT relaunch the running app (restart-app.sh owns that).
set -euo pipefail
say() { printf 'p+i %s\n' "$*"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="${HARNESS_REPO:-$HOME/Code/ds4/deepseek-harness}"
DST="/Applications/DeepSeek Harness.app"
ROLLBACK="$HOME/Applications/dsh-app-rollback.app"
STATE="$HOME/.dsh/update-state.json"
BUILD=1
for a in "$@"; do case "$a" in --skip-build) BUILD=0 ;; *) echo "unknown flag $a" >&2; exit 2 ;; esac; done
cd "$ROOT"

say "native check"
native check

[ "$BUILD" = 1 ] && { say "native build"; native build; }

# --- packaging with the dylib workaround ------------------------------------
ARTIFACT=zig-out/package/dsh-native.app
ARTIFACT_SUP="$ARTIFACT/Contents/Resources/supervisor"
DYLIB_REL=node_modules/@img/sharp-libvips-darwin-arm64/lib/libvips-cpp.8.18.3.dylib
[ -f "supervisor/$DYLIB_REL" ] && mv "supervisor/$DYLIB_REL" /tmp/libvips-cpp.8.18.3.dylib.away
rm -rf zig-out/package
BIN="zig-out/bin/$(ls zig-out/bin | grep -m1 shell || true)"
native package --target macos --binary "$BIN" --manifest app.zon
if [ -f /tmp/libvips-cpp.8.18.3.dylib.away ]; then
  cp /tmp/libvips-cpp.8.18.3.dylib.away "$ARTIFACT_SUP/$DYLIB_REL"
  mv /tmp/libvips-cpp.8.18.3.dylib.away "supervisor/$DYLIB_REL"
fi
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ARTIFACT/Contents/Info.plist")

# --- CRITICAL: re-sync the real runtime BEFORE anything else ---------------
say "sync-runtime from $HARNESS"
node "$ROOT/scripts/sync-runtime.mjs" "$HARNESS" "$ARTIFACT/Contents/Resources/supervisor"
if ! grep -q ensureSpawnableCwd "$ARTIFACT/Contents/Resources/supervisor/node_modules/@deepseek-ai/dsh-code-runtime-worker-thread/lib/index.js"; then
  echo "REFUSING install: harness-repo runtime missing from artifact (uv_cwd fix absent)" >&2
  exit 1
fi

codesign --force --deep --sign - "$ARTIFACT" >/dev/null

say "swap into /Applications (rollback at $ROLLBACK)"
rm -rf "$ROLLBACK"; [ -d "$DST" ] && cp -a "$DST" "$ROLLBACK"
rm -rf "$DST"; ditto "$ARTIFACT" "$DST"; codesign --force --deep --sign - "$DST" >/dev/null

node "$ROOT/scripts/stamp-update-state.mjs" installed "$DST"
say "installed v$VER. Relaunch when ready: bash $ROOT/scripts/restart-app.sh"
