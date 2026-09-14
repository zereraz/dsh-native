#!/usr/bin/env bash
# profile-preflight.sh — sandbox-boot the REAL web profile before any restart.
#
# dsh-local 2026-09-14 (chat-notes incident): hand-linked plugins
# (~/Code/ds4/misc/*) bypass the transactional install flow entirely — no
# build, no test, no rollback ever sees them. The only chokepoint every
# profile change funnels through is a backend restart, so that is where the
# gate lives: a profile that cannot boot must never take the live backend
# down with it. This script boots an isolated copy of the current profile
# against the installed supervisor and fails loudly on the first error.
#
# Lessons encoded: relative symlinks break under `cp -a` (repoint absolute);
# a bare "dsh web:" line means composition succeeded; loader-entry failures
# are the silent-rot signal.
set -uo pipefail
export PATH="${DSH_CONTROL_PATH:-$HOME/.nvm/versions/node/v22.22.3/bin:/opt/homebrew/bin}:$PATH"
PROFILE="${PROFILE_DIR:-${DSH_HOME:-$HOME/.dsh}/profiles/web}"
DST="${DST:-/Applications/DeepSeek Harness.app}"
SUP="$DST/Contents/Resources/supervisor"
[ -d "$PROFILE" ] || { echo "PREFLIGHT FAIL: profile dir missing: $PROFILE" >&2; exit 1; }
[ -d "$SUP" ] || { echo "PREFLIGHT FAIL: installed supervisor missing" >&2; exit 1; }

SB=$(mktemp -d /tmp/dsh-preflight.XXXXXX)
trap 'kill "$PROBE_PID" 2>/dev/null; rm -rf "$SB"' EXIT
mkdir -p "$SB/profiles"
cp -a "$PROFILE" "$SB/profiles/web"

# cp -a preserves relative symlinks verbatim — repoint every broken one to
# the absolute target it resolves to in the REAL profile.
cd "$PROFILE/node_modules" 2>/dev/null && for l in *; do
  [ -L "$l" ] || continue
  if [ ! -e "$SB/profiles/web/node_modules/$l" ]; then
    T=$(readlink -f "$l" 2>/dev/null) && [ -n "$T" ] && ln -sfn "$T" "$SB/profiles/web/node_modules/$l"
  fi
done

# Pick a free probe port.
PORT=41813
while lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; do PORT=$((PORT+1)); done

DSH_HOME="$SB" node "$SUP/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  web --host 127.0.0.1 --port "$PORT" --trusted-host "127.0.0.1:$PORT" --no-open \
  > "$SB/boot.log" 2>&1 &
PROBE_PID=$!

for _ in $(seq 1 40); do
  if grep -aq "dsh web: http" "$SB/boot.log" 2>/dev/null; then
    # Composition succeeded. Loader-entry failures are NOT fatal to boot but
    # are silent rot — report them without failing the restart.
    ROT=$(grep -ac "failed to apply loader entry" "$SB/boot.log" || true)
    [ "${ROT:-0}" -gt 0 ] && echo "preflight note: $ROT loader-entry failure(s) in this profile (non-fatal; check plugin rows)"
    echo "preflight passed: profile boots clean on :$PORT"
    exit 0
  fi
  if ! kill -0 "$PROBE_PID" 2>/dev/null; then
    echo "PREFLIGHT FAIL: profile cannot boot — first error:" >&2
    grep -aE "Error|error:|failed|duplicate" "$SB/boot.log" | head -5 >&2
    exit 1
  fi
  sleep 1
done
echo "PREFLIGHT FAIL: profile boot timed out after 40s" >&2
exit 1
