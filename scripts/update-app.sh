#!/usr/bin/env bash
# update-app.sh — the ONLY sanctioned way to update DeepSeek Harness.
#
# Pipeline: pull → build → sync runtime → HEALTH-GATE the candidate on a
# throwaway port → only then swap the installed app. A failed gate leaves the
# current app untouched. Every run snapshots ~/.dsh (git) and stages a
# rollback copy of the working app.
set -euo pipefail

# Point HARNESS_REPO at your local deepseek-harness checkout (git, not npm).
HARNESS="${HARNESS_REPO:?set HARNESS_REPO to your deepseek-harness checkout, e.g. export HARNESS_REPO=~/Code/deepseek-harness}"
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUP="$APP_ROOT/zig-out/package/dsh-native.app/Contents/Resources/supervisor"
DST="${DST:-/Applications/DeepSeek Harness.app}"
ROLLBACK="${ROLLBACK:-$HOME/Applications/dsh-app-rollback.app}"
GATE_PORT="${GATE_PORT:-41799}"
# PATH only needs a node >= 22.19 on it; nothing user-specific is assumed.
export PATH="/opt/homebrew/bin:$PATH" CI=true

say() { printf '\n[%s] %s\n' "$1" "$2"; }

say 1/6 "snapshot ~/.dsh"
git -C "$HOME/.dsh" add -A
git -C "$HOME/.dsh" -c user.email=dsh-local@local -c user.name="dsh snapshot" commit -qm "pre-update $(date +%F-%H%M)" || true

say 2/6 "git pull $HARNESS"
git -C "$HARNESS" pull --rebase --autostash
git -C "$HARNESS" log --oneline -1

say 3/6 "build"
pnpm --dir "$HARNESS" install
pnpm --dir "$HARNESS" build

say 4/6 "sync runtime into app bundle"
node "$APP_ROOT/scripts/sync-runtime.mjs" "$HARNESS" "$SUP"

say 5/6 "HEALTH GATE: boot candidate on :$GATE_PORT in a throwaway home"
GATE_LOG=/tmp/dsh-gate.log
DSH_HOME=/tmp/dsh-gate-home node "$SUP/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  web --host 127.0.0.1 --port "$GATE_PORT" --trusted-host "127.0.0.1:$GATE_PORT" --no-open >"$GATE_LOG" 2>&1 &
GATE_PID=$!
trap 'kill $GATE_PID 2>/dev/null || true' EXIT
for i in $(seq 1 40); do
  sleep 1
  page="$(curl -s -m 2 "http://127.0.0.1:$GATE_PORT/" 2>/dev/null || true)"
  [ -n "$page" ] && break
done
bundle_ok=1
curl -s -m 2 -o /dev/null "http://127.0.0.1:$GATE_PORT/plugins/@deepseek-ai/dsh-client-modules/client.js" || bundle_ok=0
kill $GATE_PID 2>/dev/null || true
if   ! printf '%s' "$page" | grep -q '__DSH_BOOT__';    then
  echo "GATE FAIL: no boot graph in served page — aborting, app untouched"; exit 1
elif ! printf '%s' "$page" | grep -q '__ModuleLoader__='; then
  echo "GATE FAIL: facade script missing (would boot to 'Failed to load plugins') — aborting, app untouched"; exit 1
elif [ "$bundle_ok" = "0" ]; then
  echo "GATE FAIL: plugin bundles not served — aborting"; exit 1
fi
echo "gate passed: boot graph + facade + bundles all served"

say 6/6 "swap installed app"
mkdir -p "$HOME/Applications"
[ -d "$DST" ] && { rm -rf "$ROLLBACK"; cp -a "$DST" "$ROLLBACK"; }
rm -rf "$DST"
ditto "$APP_ROOT/zig-out/package/dsh-native.app" "$DST"
codesign --force --deep --sign - "$DST" 2>/dev/null || true
echo "installed. rollback copy: $ROLLBACK"
if [ "${1:-}" = "--restart" ] || [ "${RESTART:-0}" = "1" ]; then
  say + "graceful relaunch cycle"
  bash "$APP_ROOT/scripts/restart-app.sh" ${FORCE:+--force}
else
  echo "QUIT and relaunch the app whenever ready — or rerun with:"
  echo "  bash $APP_ROOT/scripts/restart-app.sh   (graceful: quits, drains, relaunches, health-gates)"
fi
