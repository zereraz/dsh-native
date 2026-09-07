#!/usr/bin/env bash
# update-app.sh — the ONLY sanctioned way to update DeepSeek Harness.
#
# Build/check a candidate and stage it. restart-app.sh drains before activation.
# A failed gate leaves the installed app and other runtime copies untouched.
set -euo pipefail
# Portable cross-url lock: mkdir is atomic everywhere (flock binary is absent
# from launchd's minimal PATH — a missing flock binary used to be indistinguishable
# from a held lock and gated runs forever).
LOCKDIR="$HOME/.dsh/app-update.lock.d"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "another update/apply runs (lock $LOCKDIR) — exiting" >&2; exit 4
fi
GATE_PID=""; GATE_HOME=""
cleanup() {
  if [ -n "$GATE_PID" ]; then kill "$GATE_PID" 2>/dev/null || true; wait "$GATE_PID" 2>/dev/null || true; fi
  [ -z "$GATE_HOME" ] || rm -rf "$GATE_HOME"
  rmdir "$LOCKDIR" 2>/dev/null || true
}
trap cleanup EXIT

# GUI-launched PATH (app menu / menubar extra) has no nvm — node/pnpm/git
# would be invisible and the script would die mid-pipeline with a polite
# error message. Anchor them where the supervisor plist anchors node.
if ! command -v node >/dev/null 2>&1; then
  NVM_CANDIDATES="${DSH_NVM_BIN:-$HOME/.nvm/versions/node/v22.22.3/bin}"
  [ -x "$NVM_CANDIDATES/node" ] || NVM_CANDIDATES="/opt/homebrew/bin"
  export PATH="$NVM_CANDIDATES:$PATH"
fi

# Point HARNESS_REPO at your local deepseek-harness checkout (git, not npm).
HARNESS="${HARNESS_REPO:?set HARNESS_REPO to your deepseek-harness checkout, e.g. export HARNESS_REPO=~/Code/deepseek-harness}"
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUP="$APP_ROOT/zig-out/package/dsh-native.app/Contents/Resources/supervisor"
DST="${DST:-/Applications/DeepSeek Harness.app}"
ROLLBACK="${ROLLBACK:-$HOME/Applications/dsh-app-rollback.app}"
GATE_PORT="${GATE_PORT:-41799}"
# PATH only needs a node >= 22.19 on it; nothing user-specific is assumed.
export PATH="${DSH_CONTROL_PATH:-/opt/homebrew/bin}:$PATH" CI=true

say() { printf '\n[%s] %s\n' "$1" "$2"; }

say 1/6 "snapshot ~/.dsh"
git -C "$HOME/.dsh" add -A
git -C "$HOME/.dsh" -c user.email=dsh-local@local -c user.name="dsh snapshot" commit -qm "pre-update $(date +%F-%H%M)" || true

say 2/6 "git pull $HARNESS"
[ -z "$(git -C "$HARNESS" status --porcelain)" ] || { echo 'Harness checkout has local edits; commit or stash them before updating.' >&2; exit 1; }
git -C "$HARNESS" pull --ff-only
git -C "$HARNESS" log --oneline -1

say 3/6 "build"
pnpm --dir "$HARNESS" install
pnpm --dir "$HARNESS" build

say 4/6 "sync runtime into app bundle"
node "$APP_ROOT/scripts/sync-runtime.mjs" "$HARNESS" "$SUP"

say 5/6 "HEALTH GATE: boot candidate on :$GATE_PORT in a throwaway home"
GATE_HOME=$(mktemp -d /tmp/dsh-gate.XXXXXX)
GATE_LOG="$GATE_HOME/boot.log"
lsof -nP -iTCP:"$GATE_PORT" -sTCP:LISTEN -t >/dev/null 2>&1 && { echo "Gate port occupied" >&2; exit 1; }
DSH_HOME="$GATE_HOME" node "$SUP/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  web --host 127.0.0.1 --port "$GATE_PORT" --trusted-host "127.0.0.1:$GATE_PORT" --no-open >"$GATE_LOG" 2>&1 &
GATE_PID=$!

# dsh-local fix (alpha+): bare GET / is 401 on token-gated runtimes — resolve
# the authoritative URL from the boot line and follow it through a cookie jar.
jar="$GATE_HOME/cookies"
page=""
for i in $(seq 1 40); do
  sleep 1
  weburl=$(sed -n 's/^dsh web: \(http:\/\/[^ ]*\).*/\1/p' "$GATE_LOG" 2>/dev/null | head -1)
  if [ -n "$weburl" ]; then
    page="$(curl -sL -c "$jar" -b "$jar" -m 5 "$weburl" 2>/dev/null || true)"
    printf '%s' "$page" | grep -q '__DSH_BOOT__' && break
  fi
  page="$(curl -s -m 2 "http://127.0.0.1:$GATE_PORT/" 2>/dev/null || true)"
  printf '%s' "$page" | grep -q '__DSH_BOOT__' && break
done
# dsh-local (0.1.3): plugin bundles are served ONLY as combined, rev-pinned
# `/plugins/??<modules>&rev=<hash>` URLs advertised inside the boot graph —
# the pre-0.1.3 per-module path `/plugins/<pkg>/client.js` no longer exists.
# Extract the exact URL the boot graph itself advertises for the module and
# fetch THAT, so the probe can never go stale again.
bundle_ok=1
bundle_url="$(printf '%s' "$page" | grep -o 'plugins/[^"'"'"' ]*dsh-client-modules/client\.js[^"'"'"']*' | head -1 | sed 's/&amp;/\&/g')"
if [ -n "$bundle_url" ]; then
  curl -fsS -b "$jar" -m 5 -o /dev/null "http://127.0.0.1:$GATE_PORT/$bundle_url" || bundle_ok=0
else
  bundle_ok=0
fi
if ! printf '%s' "$page" | grep -q '__DSH_BOOT__'; then
  echo "GATE FAIL: no boot graph in served page — aborting, app untouched"; exit 1
elif ! printf '%s' "$page" | grep -q '__ModuleLoader__='; then
  echo "GATE FAIL: facade script missing (would boot to 'Failed to load plugins') — aborting, app untouched"; exit 1
elif [ "$bundle_ok" = "0" ]; then
  echo "GATE FAIL: plugin bundles not served — aborting"; exit 1
fi
# pi-ai dependency closure: ESM-only exports of @earendil-works/pi-ai used to
# defeat the alignment probe and silently ship a bundle that errors on every
# LLM turn ("Cannot find package 'openai'"). Prove the import path NOW:
if [ -d "$SUP/node_modules/@earendil-works/pi-ai" ] \
  && ! node --input-type=module -e "await import('$SUP/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js')" 2>/dev/null; then
  echo "GATE FAIL: pi-ai openai-completions not importable (dependency closure broken) — aborting, app untouched"; exit 1
fi
[ -f "$APP_ROOT/zig-out/package/dsh-native.app/Contents/Resources/config/cordis.patch.yml" ] \
  || { echo "GATE FAIL: bundle missing Resources/config/cordis.patch.yml (supervisor crashes on boot) — aborting"; exit 1; }
kill "$GATE_PID" 2>/dev/null || true
wait "$GATE_PID" 2>/dev/null || true
GATE_PID=""
echo "gate passed: boot graph + facade + bundles + pi-ai closure + config"

say 6/6 "stage checked app for idle activation"
node "$APP_ROOT/scripts/stage-app.mjs" "$APP_ROOT/zig-out/package/dsh-native.app"
if [ "${1:-}" = "--restart" ] || [ "${RESTART:-0}" = "1" ]; then
  cleanup
  trap - EXIT
  exec bash "$APP_ROOT/scripts/restart-app.sh"
fi
