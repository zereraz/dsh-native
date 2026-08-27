#!/usr/bin/env bash
# apply-native-sdk-patches.sh — re-apply dsh-local patches to the locally
# installed @native-sdk/cli before every build.
#
# Why this exists (2026-08 incident): the npm CLI ships appkit_host.m where
# declaring ANY manifest .menus REPLACES the whole macOS menu bar, silently
# dropping File/Edit/View/Window — so Cmd+C/V/X/A beeped and did nothing in
# a packaged app. npm upgrades reinstall node_modules and would silently
# reintroduce the bug, so package-and-install.sh calls this BEFORE building.
#
# Idempotent: looks for the patch marker; applies with `patch -N` otherwise.
set -euo pipefail

MARKER="dsh-local fix"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$HERE/../patches/native-sdk-cli"

SDK_DIR="${NATIVE_SDK_PATH:-}"
if [ -z "$SDK_DIR" ]; then
  NATIVE_BIN="$(command -v native || true)"
  [ -n "$NATIVE_BIN" ] || { echo "native CLI not on PATH and NATIVE_SDK_PATH unset" >&2; exit 1; }
  SDK_DIR="$(cd "$(dirname "$NATIVE_BIN")/../lib/node_modules/@native-sdk/cli" && pwd)"
fi

TARGET="$SDK_DIR/src/platform/macos/appkit_host.m"
for p in "$PATCH_DIR"/*.patch; do
  [ -f "$p" ] || continue
  if grep -q "$MARKER" "$TARGET"; then
    echo "patch(es) already applied in $TARGET"
    exit 0
  fi
  if patch -N -p1 -d "$SDK_DIR" < "$p" >/dev/null; then
    echo "applied $(basename "$p") → $TARGET"
  else
    echo "FAILED to apply $p — refusing to build with unpatched host (would silently drop the standard menu bar)" >&2
    exit 1
  fi
done
