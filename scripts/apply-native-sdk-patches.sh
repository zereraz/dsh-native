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
# 2026-09-26: per-patch idempotence. The old single-marker check stopped at
# the FIRST applied patch, so a second patch added to this directory would
# never have been applied to an already-once-patched SDK. Each patch now
# carries its own marker (see marker_for below); a patch is skipped only
# when ITS marker is present in the target.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$HERE/../patches/native-sdk-cli"

SDK_DIR="${NATIVE_SDK_PATH:-}"
if [ -z "$SDK_DIR" ]; then
  NATIVE_BIN="$(command -v native || true)"
  [ -n "$NATIVE_BIN" ] || { echo "native CLI not on PATH and NATIVE_SDK_PATH unset" >&2; exit 1; }
  SDK_DIR="$(cd "$(dirname "$NATIVE_BIN")/../lib/node_modules/@native-sdk/cli" && pwd)"
fi

# Per-patch marker: a string the patch embeds in the target when applied.
# Adding a patch? Add its marker here AND embed the same words in the patch.
marker_for() {
  case "$1" in
    00-manifest-menus-merge.patch) echo "manifest menus must MERGE" ;;
    01-disable-app-nap.patch) echo "never App-Nap" ;;
    *) echo "" ;;
  esac
}

TARGET="$SDK_DIR/src/platform/macos/appkit_host.m"
for p in "$PATCH_DIR"/*.patch; do
  [ -f "$p" ] || continue
  name="$(basename "$p")"
  marker="$(marker_for "$name")"
  [ -n "$marker" ] || { echo "no marker registered for $name — add one to marker_for() in $0" >&2; exit 1; }
  if grep -q "$marker" "$TARGET"; then
    echo "$name already applied in $TARGET"
    continue
  fi
  if patch -N -p1 -d "$SDK_DIR" < "$p" >/dev/null; then
    echo "applied $name → $TARGET"
  else
    echo "FAILED to apply $p — refusing to build with unpatched host" >&2
    exit 1
  fi
done
