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

say "apply native-sdk patches"
bash "$ROOT/scripts/apply-native-sdk-patches.sh"

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
# config/cordis.patch.yml: dsh-web.mjs installs the privacy patch into
# profiles/web on every boot; native package does NOT copy the app-root
# config/ dir into the bundle, so the supervisor would boot-crash (ENOENT
# copyfile) without this step.
rm -rf "$ARTIFACT/Contents/Resources/config"
cp -R "$ROOT/config" "$ARTIFACT/Contents/Resources/config"
if ! grep -q ensureSpawnableCwd "$ARTIFACT/Contents/Resources/supervisor/node_modules/@deepseek-ai/dsh-code-runtime-worker-thread/lib/index.js"; then
  echo "REFUSING install: harness-repo runtime missing from artifact (uv_cwd fix absent)" >&2
  exit 1
fi

# --- GATE: prove the candidate serves BEFORE touching /Applications --------
# A broken bundle must never get swapped in and launched again: three cheap
# decisive probes, any one of them blocks the whole install.
GATE_PORT="${GATE_PORT:-41798}"
say "gate candidate on :$GATE_PORT"
SUP="$ARTIFACT/Contents/Resources/supervisor"
# dsh-local fix: the ESM probes below need an ABSOLUTE path — relative SUP
# like 'zig-out/...' makes `await import('zig-out/...')` resolve as a bare
# package name (ERR_MODULE_NOT_FOUND for package 'zig-out'), failing the gate
# even when the closure is perfect. Anchor to $PWD before probing.
SUP="$(cd "$SUP" && pwd)"
[ -f "$ARTIFACT/Contents/Resources/config/cordis.patch.yml" ] \
  || { echo "GATE FAIL: bundle missing Resources/config/cordis.patch.yml (supervisor crashes on boot)" >&2; exit 1; }
if [ -d "$SUP/node_modules/@earendil-works/pi-ai" ]; then
  node --input-type=module -e "await import('$SUP/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js')" \
    || { echo "GATE FAIL: pi-ai openai-completions not importable (dependency closure broken)" >&2; exit 1; }
fi
GATE_HOME="$(mktemp -d /tmp/dsh-gate-XXXXXX)"
DSH_HOME="$GATE_HOME" node "$SUP/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  web --host 127.0.0.1 --port "$GATE_PORT" --trusted-host "127.0.0.1:$GATE_PORT" --no-open >"$GATE_HOME/boot.log" 2>&1 &
GATE_PID=$!
page=""
for _ in $(seq 1 40); do page="$(curl -s -m 2 "http://127.0.0.1:$GATE_PORT/" 2>/dev/null || true)"; [ -n "$page" ] && break; sleep 1; done
kill "$GATE_PID" 2>/dev/null || true
printf '%s' "$page" | grep -q '__DSH_BOOT__'     || { echo "GATE FAIL: no boot graph (log: $GATE_HOME/boot.log)" >&2; exit 1; }
printf '%s' "$page" | grep -q '__ModuleLoader__=' || { echo "GATE FAIL: facade script missing (would boot to 'Failed to load plugins')" >&2; exit 1; }
rm -rf "$GATE_HOME"
echo "gate passed: config present + pi-ai closure importable + boot graph + facade"

codesign --force --deep --sign - "$ARTIFACT" >/dev/null

say "swap into /Applications (rollback at $ROLLBACK)"
rm -rf "$ROLLBACK"; [ -d "$DST" ] && cp -a "$DST" "$ROLLBACK"
rm -rf "$DST"; ditto "$ARTIFACT" "$DST"; codesign --force --deep --sign - "$DST" >/dev/null

node "$ROOT/scripts/stamp-update-state.mjs" installed "$DST"
say "installed v$VER. Relaunch when ready: bash $ROOT/scripts/restart-app.sh"
