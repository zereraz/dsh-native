#!/usr/bin/env bash
# preflight.sh — the "trust, then verify" button for your next Apply&Restart.
# Runs every guard battery + the dry-plan, so the next click has checks behind
# it, not ceremonies. Designed so a future me doesn't ever have to remind
# themselves to run all the checks: everything IS the check.
#
# exit 0 = every battery green: the button is safe to click. exit != 0 = one of
# the tripwires fired; don't trust the cycle until it prints why.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
FAIL=0

say "1/4 update guard battery"
bash tests/update-guard.sh || FAIL=1

say "2/4 restart-cycle hermetic battery"
bash tests/restart-cycle.sh || FAIL=1

say "3/4 post-restart gate dry-plan (proof the cycle can name its own path)"
bash scripts/restart-app.sh --dry-run || FAIL=1

say "4/4 supervision stack census"
for p in "/Applications/DeepSeek Harness.app/Contents/Resources/supervisor/dsh-web.mjs" \
         "$HOME/.pocket-server/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-code-runtime-worker-thread/lib/index.js"; do
  [ -f "$p" ] && echo "ok  $p" || { echo "BAD $p"; FAIL=1; }
done

if [ "$FAIL" = 0 ]; then
  say "ALL GREEN — safe to click Apply & Restart."
else
  say "PRE-FLIGHT FAILED — do not click apply."
  exit 1
fi
