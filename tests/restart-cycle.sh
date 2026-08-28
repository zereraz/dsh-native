#!/usr/bin/env bash
# restart-cycle.sh — hermetic end-to-end proof of the restart cycle's every
# branch, run entirely against mocks: a fake installed bundle, a fake rollback,
# a stub launchctl that owns a REAL throwaway http server (the mock host), and
# an isolated $HOME so no real ~/.dsh state is touched.
# Exit 0 = all five scenarios behave exactly as designed.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok()  { printf 'ok  %s\n' "$*"; }
bad() { printf 'BAD %s\n' "$*" >&2; fail=1; }

T=$(mktemp -d /tmp/restart-cycle-XXXXXX)
trap 'kill $(cat $T/server.pid 2>/dev/null) 2>/dev/null; rm -rf "$T"' EXIT
HOME_F="$T/home"; BIN="$T/bin"
mkdir -p "$HOME_F/.dsh/sessions/x/y" "$HOME_F/Library/LaunchAgents" "$BIN"
export HOME="$HOME_F"
export PATH="$BIN:$PATH"

# --- mocks ------------------------------------------------------------------
cat > "$BIN/launchctl" <<'MOCK'
#!/bin/bash
# Mock launchctl. bootout kills the fake host; bootstrap starts it when the
# file $MOCK_T/bootstrap-ok exists (absent = simulate a bundle that never serves).
cat >> "$MOCK_T/launchctl.log" 2>/dev/null <<< "launchctl $*"
case "$1" in
  bootout)   kill "$(cat "$MOCK_T/server.pid" 2>/dev/null)" 2>/dev/null || true ;;
  bootstrap)
    if [ -f "$MOCK_T/bootstrap-ok" ]; then
      python3 -m http.server 41798 --bind 127.0.0.1 >/dev/null 2>&1 &
      echo $! > "$MOCK_T/server.pid"
    fi ;;
  kickstart)
    kill "$(cat "$MOCK_T/server.pid" 2>/dev/null)" 2>/dev/null
    python3 -m http.server 41798 --bind 127.0.0.1 >/dev/null 2>&1 &
    echo $! > "$MOCK_T/server.pid" ;;
esac
exit 0
MOCK
cat > "$BIN/osascript" <<'MOCK'
#!/bin/bash
exit 0
MOCK
cat > "$BIN/open" <<'MOCK'
#!/bin/bash
cat >> "$MOCK_T/opened.log" <<EOF
open $*
EOF
exit 0
MOCK
chmod +x "$BIN/launchctl" "$BIN/osascript" "$BIN/open"
PLIST="$HOME_F/Library/LaunchAgents/com.zereraz.dsh-app.plist"
printf '<plist version="1.0"/>' > "$PLIST"

# --- fake bundles ------------------------------------------------------------
mkfake() { # $1 = target app dir
  mkdir -p "$1/Contents/Resources/supervisor" "$1/Contents/MacOS"
  cat > "$1/Contents/Info.plist" <<'EOF'
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>0.2.2</string>
<key>CFBundleExecutable</key><string>dsh-native</string>
</dict></plist>
EOF
  echo '#!/bin/sh' > "$1/Contents/MacOS/dsh-native"; chmod +x "$1/Contents/MacOS/dsh-native"
}
DST_F="$T/Applications/DeepSeek Harness.app"; ROLLBACK_F="$HOME_F/Applications/dsh-app-rollback.app"
mkdir -p "$T/Applications" "$HOME_F/Applications"
mkfake "$DST_F"; mkfake "$ROLLBACK_F"
export DST="$DST_F" ROLLBACK="$ROLLBACK_F"
export MOCK_T="$T"
# Sandbox the pgrep pattern: a GLOBAL pattern in restart-app.sh would match
# the REAL GUI binary and kill it (did — once). Namespace everything.
export APP_BIN="restart-cycle-mock-bin-never-real"
# the sandbox $HOME has no nvm; hand the script the REAL one via DSH_NVM_BIN
export DSH_NVM_BIN="/Users/zereraz/.nvm/versions/node/v22.22.3/bin"

RUN() { PORT=41798 APP_BIN="$APP_BIN" bash "$ROOT/scripts/restart-app.sh" "$@"; echo "exit=$?"; }

# --- 1. dry-run: plan only, nothing touched ----------------------------------
out=$(RUN --dry-run --force 2>&1)
grep -q "DRY-RUN plan" <<< "$out" && grep -q "launchctl bootstrap" <<< "$out" \
  && ok "1 dry-run prints the 7-phase plan" || bad "1 dry-run: $out"

# --- 2. busy-gate refuses with active sessions --------------------------------
touch "$HOME_F/.dsh/sessions/x/y/session.jsonl.zstd"
out=$(RUN 2>&1)
tail_line=$(tail -1 <<< "$out")
grep -q "exit=3" <<< "$out" && grep -q "ACTIVITY: 1 session" <<< "$out" \
  && ok "2 busy-gate exit 3" || bad "2 busy-gate: $out"
[ -d "$HOME_F/.dsh/app-update.lock.d" ] && bad "2 lock leaked" || ok "2 lock released"

# --- 3. happy path: bootout → bootstrap → healthy → stamp ---------------------
touch "$T/bootstrap-ok"
out=$(RUN --force --idle 0 2>&1)
grep -q "exit=0" <<< "$out" && grep -q "bootout gui.*/com.zereraz.dsh-app" "$T/launchctl.log" \
  && grep -q "bootstrap gui" "$T/launchctl.log" && grep -q "up: port 41798 200" <<< "$out" \
  && ok "3 happy path full cycle" || bad "3 happy: $(echo "$out" | tail -4); log: $(cat $T/launchctl.log)"
node -e "
const s=JSON.parse(require('fs').readFileSync('$HOME_F/.dsh/update-state.json','utf8'))
if (s.lastAction==='applied' && s.appliedAt) process.exit(0); process.exit(1)
" && ok "3 state stamped applied" || bad "3 state: $(cat $HOME_F/.dsh/update-state.json 2>/dev/null)"
# the app must re-open ITSELF — the "only the backend came back" gap
grep -q "open -g $DST_F" "$T/opened.log" 2>/dev/null \
  && ok "3 GUI re-opened via open -g" || bad "3 GUI NOT re-opened by the cycle"
kill "$(cat $T/server.pid)" 2>/dev/null

# --- 4. health-fail → rollback swapped back + exit 1 --------------------------
rm -f "$T/bootstrap-ok"
: > "$T/launchctl.log"
# capture state so we can prove the failure run didn't rewrite it
BEFORE=$(cat "$HOME_F/.dsh/update-state.json" 2>/dev/null | shasum | cut -d' ' -f1)
out=$(RUN --force --idle 0 2>&1)
AFTER=$(cat "$HOME_F/.dsh/update-state.json" 2>/dev/null | shasum | cut -d' ' -f1)
grep -q "exit=1" <<< "$out" && grep -q "HEALTH FAIL" <<< "$out" && grep -q "ROLLED BACK" <<< "$out" \
  && ok "4 health-fail rolls back and aborts" || bad "4 rollback: $(echo "$out" | tail -5)"
[ "$BEFORE" = "$AFTER" ] && ok "4 failure run did not rewrite state" || bad "4 failure run rewrote state!"
kill "$(cat $T/server.pid 2>/dev/null)" 2>/dev/null

# --- 5. concurrency: a held lock blocks immediately ---------------------------
mkdir -p "$HOME_F/.dsh/app-update.lock.d"
out=$(RUN --force --idle 0 2>&1)
grep -q "exit=4" <<< "$out" && grep -q "another update/apply runs" <<< "$out" \
  && ok "5 held lock blocks (exit 4)" || bad "5 lock: $out"
rmdir "$HOME_F/.dsh/app-update.lock.d"

exit $fail
