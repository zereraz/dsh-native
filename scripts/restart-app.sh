#!/usr/bin/env bash
# Idle-gated restart of the primary launchd job; other DSH hosts are never signaled.
set -euo pipefail
export PATH="${DSH_CONTROL_PATH:-$HOME/.nvm/versions/node/v22.22.3/bin:/opt/homebrew/bin}:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="${DSH_HOME:-$HOME/.dsh}"
DST="${DST:-/Applications/DeepSeek Harness.app}"
ROLLBACK="${ROLLBACK:-$HOME/Applications/dsh-app-rollback.app}"
PORT="${PORT:-41730}"; export PORT
JOB="gui/$(id -u)/com.zereraz.dsh-app"
PLIST="$HOME/Library/LaunchAgents/com.zereraz.dsh-app.plist"
IDLE=5; FORCE=0; DRY=0
while [ $# -gt 0 ]; do
 case "$1" in --force) FORCE=1;; --dry-run) DRY=1;; --idle) IDLE="${2:?missing minutes}"; shift;; *) echo "Unknown argument: $1" >&2; exit 2;; esac; shift
done
case "$IDLE" in ''|*[!0-9]*) echo 'Idle minutes must be a non-negative integer' >&2; exit 2;; esac
[ -f "$PLIST" ] || { echo 'Primary launchd plist missing' >&2; exit 1; }
# Missing/unreadable session state must not be interpreted as idle.
[ -d "$DATA/sessions" ] || { echo 'Session directory missing; cannot determine activity' >&2; exit 1; }
ACTIVITY=$(find "$DATA/sessions" -type f \( -name 'session.jsonl.zstd' -o -name 'session.jsonl' \) -mmin "-$IDLE")
if [ -n "$ACTIVITY" ] && [ "$FORCE" = 0 ]; then
 echo 'Recent chat activity: reload deferred. Wait for chats to finish, then retry.'
 [ "$DRY" = 1 ] || exit 3
fi
if [ "$DRY" = 1 ]; then
 echo "DRY-RUN: quit native window; bootout $JOB; wait for port $PORT to close; activate staged plugins; bootstrap; authenticated readiness + PTC; rollback on failure."
 exit 0
fi
LOCK="$DATA/app-update.lock.d"
mkdir "$LOCK" 2>/dev/null || { echo 'Another update/reload is running (or a stale lock needs repair)' >&2; exit 4; }
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
alive() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; }
drain() {
 local supervisor_pid
 supervisor_pid=$(launchctl print "$JOB" 2>/dev/null | awk '$1 == "pid" && $2 == "=" {print $3; exit}' || true)
 launchctl bootout "$JOB" 2>/dev/null || true
 for _ in $(seq 1 20); do
  if ! alive && { [ -z "$supervisor_pid" ] || ! kill -0 "$supervisor_pid" 2>/dev/null; }; then return 0; fi
  sleep 1
 done
 echo "Port $PORT is still owned by a process; refusing to replace files or kill other hosts." >&2
 return 1
}
boot() {
 # Never accept an old process's published URL as the readiness signal.
 rm -f "${DSH_WEB_URL_FILE:-$DATA/web-url.txt}"
 launchctl bootstrap "gui/$(id -u)" "$PLIST" || return 1
 for _ in $(seq 1 40); do
  if node "$ROOT/ready.mjs"; then
   DSH_APP_SUP="$DST/Contents/Resources/supervisor" node "$ROOT/verify-ptc.mjs" && return 0
   return 1
  fi
  sleep 1
 done
 return 1
}
CANDIDATE=""
OLD_APP=""
if [ -f "$DATA/app-candidate.json" ]; then
 CANDIDATE=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).path)' "$DATA/app-candidate.json")
 [ -d "$CANDIDATE" ] || { echo 'Staged app is missing' >&2; exit 1; }
 codesign --verify --deep --strict "$CANDIDATE"
 READY_APP="$(dirname "$DST")/.dsh-ready-$$.app"
 ditto "$CANDIDATE" "$READY_APP"
fi
if [ "$FORCE" = 0 ] && [ -n "$(find "$DATA/sessions" -type f \( -name 'session.jsonl.zstd' -o -name 'session.jsonl' \) -mmin "-$IDLE")" ]; then
 echo 'Chat activity resumed while preparing the reload; retry when idle.'; exit 3
fi
# Quitting only this bundle ID never targets a browser or another DSH server.
osascript -e 'if application id "com.zereraz.dsh-native" is running then tell application id "com.zereraz.dsh-native" to quit' >/dev/null 2>&1 || true
echo 'Draining primary backend…'
drain || exit 1
if [ -n "$CANDIDATE" ]; then
 OLD_APP="$(dirname "$DST")/.dsh-previous-$$.app"
 mv "$DST" "$OLD_APP"
 if ! mv "$READY_APP" "$DST"; then mv "$OLD_APP" "$DST"; boot || true; exit 1; fi
fi
if ! { node "$ROOT/plugins.mjs" rollback && node "$ROOT/plugins.mjs" activate; }; then
 echo 'Plugin activation refused; restoring primary backend.' >&2
 if [ -n "$OLD_APP" ]; then mv "$DST" "$READY_APP"; mv "$OLD_APP" "$DST"; fi
 boot && open -g "$DST"
 exit 1
fi
if boot; then
 node "$ROOT/plugins.mjs" commit
 if [ -n "$OLD_APP" ]; then
  mkdir -p "$(dirname "$ROLLBACK")"
  rm -rf "$ROLLBACK"; mv "$OLD_APP" "$ROLLBACK"
  rm -f "$DATA/app-candidate.json"
 fi
 node "$ROOT/stamp-update-state.mjs" applied "$DST"
 open -g "$DST"
 echo 'Reload complete: authenticated boot and PTC passed. Test the plugin behavior in the app.'
 exit 0
fi
echo 'Readiness failed. Draining before recovery…' >&2
drain || exit 1
if [ -f "$DATA/plugin-activation.json" ]; then
 node "$ROOT/plugins.mjs" rollback
fi
if [ -n "$OLD_APP" ]; then
 mv "$DST" "$(dirname "$DST")/.dsh-failed-$$.app"; mv "$OLD_APP" "$DST"
elif [ -d "$ROLLBACK" ] && [ ! -f "$DATA/plugin-control.json" ]; then
 # Copy recovery candidate before moving the failed bundle. Never delete the only copy.
 RESTORE="$(dirname "$DST")/.dsh-restore-$$.app"
 FAILED="$(dirname "$DST")/.dsh-failed-$$.app"
 ditto "$ROLLBACK" "$RESTORE"
 mv "$DST" "$FAILED"
 if ! mv "$RESTORE" "$DST"; then mv "$FAILED" "$DST"; exit 1; fi
 echo "Failed bundle retained at $FAILED"
else
 echo 'No rollback available; retrying the existing bundle.' >&2
fi
if boot; then
 open -g "$DST"
 echo 'Recovery boot passed. Requested reload failed; inspect the log before retrying.' >&2
else
 echo 'Recovery failed; primary backend needs repair. Other hosts were not signaled.' >&2
fi
exit 1
