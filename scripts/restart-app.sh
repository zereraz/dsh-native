#!/usr/bin/env bash
# restart-app.sh — one-button graceful quit → relaunch → verify cycle for the
# DeepSeek Harness native app. Run when a new build has been installed (usually
# by update-app.sh step 6) and you want the running instance to pick it up
# WITHOUT any of the historical footguns:
#   - refuses to cycle while a chat wrote to its log recently (agents mid-run),
#   - quits the WebView app short of force (osascript), THEN drains the launchd
#     host, so no cleanup writes are raced by a swap,
#   - waits for the backend to be fully down before relaunching (no zombie
#     holding a deleted bundle as its cwd — the 2026-08-24 uv_cwd incident),
#   - health-checks and PTC-smokes the new host; on failure swaps in the
#     rollback copy and relaunches THAT, then says so loudly.
#
# Options:
#   --force         skip the activity check anyway (agent IS the activity)
#   --idle N        quiet-period minutes before cycling (default 5)
#   --dry-run       print every step and the activity report; touch nothing
set -euo pipefail

DOMAIN="gui/$(id -u)"
APP_NAME="DeepSeek Harness"
APP_BIN="Contents/MacOS/dsh-native"
SUP_PATTERN="supervisor/dsh-web.mjs"
WEB_PATTERN="dsh/lib/bin.js web"
PORT="${PORT:-41730}"
HOST_URL="http://127.0.0.1:$PORT"
ROLLBACK="${ROLLBACK:-$HOME/Applications/dsh-app-rollback.app}"
DST="${DST:-/Applications/DeepSeek Harness.app}"
IDLE_MINUTES=5
FORCE=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    --idle) IDLE_MINUTES="${2:?--idle needs minutes}"; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done
say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
http() { curl -sS -o /dev/null -m 2 -w '%{http_code}' "$HOST_URL/" 2>/dev/null || echo 000; }

# --- 0. activity gate -------------------------------------------------------
MAPFILE=()
while IFS= read -r f; do MAPFILE+=("$f"); done < <(find "$HOME/.dsh/sessions" -name 'session.jsonl.zstd' -newermt "-${IDLE_MINUTES} minutes" 2>/dev/null)
if [ "${#MAPFILE[@]}" -gt 0 ] && [ "$FORCE" = 0 ]; then
  say "ACTIVITY: ${#MAPFILE[@]} session(s) wrote within ${IDLE_MINUTES}m:"
  printf '       %s\n' "${MAPFILE[@]}" | sed "s|$HOME/.dsh/sessions/||"
  if [ "$DRY" = 0 ]; then
    echo "cycling now kills their in-flight runs. Re-run with --force or wait; aborting." >&2
    exit 3
  fi
fi

if [ "$DRY" = 1 ]; then
  say "DRY-RUN plan:"
  say "  1. osascript: tell application \"$APP_NAME\" to quit   (graceful GUI)"
  say "  2. launchctl bootout $DOMAIN/com.zereraz.dsh-app     (drain backend)"
  say "  3. wait for :$PORT to stop + no $WEB_PATTERN processes"
  say "  4. launchctl bootstrap $DOMAIN ~/Library/LaunchAgents/com.zereraz.dsh-app.plist"
  say "  5. wait for :$PORT to answer 200 (<40s)"
  say "  6. scripts/verify-ptc.mjs against the live bundle"
  say "  7. on any health failure: swap $ROLLBACK back into place and relaunch"
  exit 0
fi

# --- 1. graceful GUI quit ---------------------------------------------------
if pgrep -f "$APP_BIN" >/dev/null; then
  say "quitting $APP_NAME (graceful)"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -f "$APP_BIN" >/dev/null || break; sleep 1; done
  pgrep -f "$APP_BIN" >/dev/null && { say "GUI still up after 20s — TERM"; pkill -TERM -f "$APP_BIN" || true; }
fi

# --- 2. drain the backend ---------------------------------------------------
say "draining backend (launchd job com.zereraz.dsh-app)"
launchctl bootout "$DOMAIN/com.zereraz.dsh-app" 2>/dev/null || true
for _ in $(seq 1 15); do [ "$(http)" = 000 ] && break; sleep 1; done
[ "$(http)" != 000 ] && { echo "port $PORT still answering after 15s — refusing to relaunch over a zombie" >&2; exit 1; }
pgrep -f "$WEB_PATTERN" >/dev/null && pkill -TERM -f "$WEB_PATTERN" || true
sleep 1

# --- 3. relaunch ------------------------------------------------------------
say "relaunching"
launchctl bootstrap "$DOMAIN" "$HOME/Library/LaunchAgents/com.zereraz.dsh-app.plist" 2>/dev/null \
  || launchctl kickstart "$DOMAIN/com.zereraz.dsh-app"
for _ in $(seq 1 40); do [ "$(http)" = 200 ] && break; sleep 1; done

# --- 4. verify or rollback --------------------------------------------------
if [ "$(http)" != 200 ]; then
  say "HEALTH FAIL after relaunch — swapping rollback back in"
  [ -d "$ROLLBACK" ] || { echo "no rollback copy at $ROLLBACK — manual repair needed" >&2; exit 1; }
  rm -rf "$DST"; ditto "$ROLLBACK" "$DST"
  launchctl kickstart -k "$DOMAIN/com.zereraz.dsh-app"
  for _ in $(seq 1 40); do [ "$(http)" = 200 ] && break; sleep 1; done
  [ "$(http)" = 200 ] && { echo "ROLLED BACK and serving. Investigate before retrying." >&2; exit 1; }
  echo "FATAL: rollback also failed health check. Manual repair." >&2; exit 1
fi

WEB_PID=$(pgrep -f "$WEB_PATTERN" | head -1)
say "up: port $PORT 200, web pid $WEB_PID"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/verify-ptc.mjs" ]; then
  node "$SCRIPT_DIR/verify-ptc.mjs" && say "PTC smoke: OK" || say "PTC smoke: WARN (see above) — old build still healthy enough to report"
fi
python3 - "$DST" <<'PYEOF'
import json, pathlib, subprocess, sys, datetime
state = pathlib.Path.home()/'.dsh'/'update-state.json'
old = json.loads(state.read_text()) if state.exists() else {}
ver = subprocess.run(['/usr/libexec/PlistBuddy','-c','Print :CFBundleShortVersionString', sys.argv[1]+'/Contents/Info.plist'], capture_output=True, text=True).stdout.strip()
now = datetime.datetime.now().astimezone().strftime('%Y-%m-%dT%H:%M:%S%z')
old.update(version=ver, appliedAt=now, lastAction='apply', lastActionStatus='ok')
state.write_text(json.dumps(old, indent=2))
PYEOF
say "done. Go ahead and use the app."
