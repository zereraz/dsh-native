#!/usr/bin/env bash
# update-guard.sh — the always-cheap battery, pre-release and any time.
# Exit 0 means: the pipeline machinery is trustworthy as of right now.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
ok() { printf 'ok  %s\n' "$*"; }
bad() { printf 'BAD %s\n' "$*" >&2; fail=1; }

# 1. every pipeline script must parse
for s in scripts/*.sh scripts/*.mjs; do
  case "$s" in *.sh) bash -n "$s" || bad "parse: $s" ;; *) node --check "$s" || bad "parse: $s" ;; esac
done
ok "parsers"

# 2. mkdir-lock semantics: held → 4, released → proceeds past lock
LOCK="$HOME/.dsh/app-update.lock.d"
[ -d "$LOCK" ] && bad "stale lock present before test: $LOCK"
mkdir "$LOCK"
bash scripts/restart-app.sh --idle 99999 >/dev/null 2>&1; code=$?
[ "$code" = 4 ] && ok "lock: held blocks (exit 4)" || bad "lock: held gave exit $code, want 4"
rmdir "$LOCK"
echo x > /dev/null
bash scripts/restart-app.sh --idle 99999 --force --dry-run >/dev/null 2>&1; code=$?
[ "$code" = 0 ] && ok "lock: released proceeds (dry-run exit 0)" || bad "lock: released gave exit $code, want 0"
[ -d "$LOCK" ] && bad "lock left behind after dry-run" || ok "lock: trap cleanup"

# 3. stamp semantics (throwaway file)
T="$(mktemp -d /tmp/stamp-guard-XXXXXX)/s.json"
DSH_STATE_FILE="$T" node scripts/stamp-update-state.mjs installed "/Applications/DeepSeek Harness.app" >/dev/null
DSH_STATE_FILE="$T" node scripts/stamp-update-state.mjs applied "/Applications/DeepSeek Harness.app" >/dev/null
python3 - "$T" <<'EOF' && ok "stamp: fields/ISO/order" || bad "stamp semantics"
import json, sys, datetime
s = json.loads(open(sys.argv[1]).read())
for f in ('installedAt', 'appliedAt'):
    datetime.datetime.strptime(s[f], '%Y-%m-%dT%H:%M:%S%z')
assert s['appliedAt'] >= s['installedAt'] and s['version']
EOF

# 4. http() deadlock guard: the double-000 class must never regress
! grep -n '^[^#]*|| echo 000' scripts/restart-app.sh >/dev/null && ok "http(): no double-000 trap" || bad "http(): double-000 trap returned"

# 5. SDK menu-merge patch marker must be present in the CLI the build uses
grep -q "dsh-local fix" "${NATIVE_SDK_PATH:-$HOME/.nvm/versions/node/v22.22.3/lib/node_modules/@native-sdk/cli}/src/platform/macos/appkit_host.m" \
  && ok "sdk: menu-merge patch present" || bad "sdk: menu-merge patch MISSING (re-run scripts/apply-native-sdk-patches.sh)"

# 6. installed app basics
AA="/Applications/DeepSeek Harness.app"
[ -f "$AA/Contents/Resources/config/cordis.patch.yml" ] && ok "install: config present" || bad "install: config MISSING"
[ -d "$AA/Contents/Resources/supervisor/node_modules/openai" ] && ok "install: pi-ai closure (openai) present" || bad "install: openai MISSING"
vA=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$AA/Contents/Info.plist")
vR=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HOME/Applications/dsh-app-rollback.app/Contents/Info.plist" 2>/dev/null || echo '?')
[ -n "$vA" ] && ok "install: app v$vA / rollback v$vR" || bad "install: version unreadable"

exit $fail
