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

# 6. runtime census: EVERY copy of the worker on the machine must carry the
#    uv_cwd re-anchor (ensureSpawnableCwd x2). A drifting THIRD copy is exactly
#    how the 2026-08-28 pocket-server ghost happened again.
copies=$(python3 - <<'EOF'
import os
seen = set()
for b in [os.path.expanduser(p) for p in ("~/.pocket-server/lib", "~/.nvm")] + \
         ["/Applications/DeepSeek Harness.app/Contents/Resources"]:
    for root, dirs, files in os.walk(b):
        if root.count(os.sep) - b.count(os.sep) > 8: dirs[:] = []
        if "index.js" in files and root.endswith("dsh-code-runtime-worker-thread/lib"):
            seen.add(os.path.join(root, "index.js"))
for f in sorted(seen): print(f)
EOF
)
[ -n "$copies" ] || bad "census: no worker copies found at all"
while IFS= read -r f; do
  c=$(grep -c ensureSpawnableCwd "$f" 2>/dev/null || echo 0)
  [ "$c" = "2" ] && ok "census: fixed worker in $f" || bad "census: UNPATCHED worker ($c marks): $f"
done <<< "$copies"

# 7. installed app basics
AA="/Applications/DeepSeek Harness.app"
[ -f "$AA/Contents/Resources/config/cordis.patch.yml" ] && ok "install: config present" || bad "install: config MISSING"
[ -d "$AA/Contents/Resources/supervisor/node_modules/openai" ] && ok "install: pi-ai closure (openai) present" || bad "install: openai MISSING"
vA=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$AA/Contents/Info.plist")
vR=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HOME/Applications/dsh-app-rollback.app/Contents/Info.plist" 2>/dev/null || echo '?')
[ -n "$vA" ] && ok "install: app v$vA / rollback v$vR" || bad "install: version unreadable"

# 8. preset completeness: all four shipped presets present in BOTH runtime
#    copies, and minimal actually mounts compaction-basic (dsh-local fix; a
#    bundle that only has minimal/ would silently lose ptc/standard again).
for root in \
  "/Applications/DeepSeek Harness.app/Contents/Resources/supervisor/node_modules/@deepseek-ai/dsh-agent-presets/presets" \
  "$HOME/.pocket-server/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-agent-presets/presets"; do
  missing=""
  for p in cordis minimal ptc standard; do
    [ -d "$root/$p" ] || missing="$missing $p"
  done
  [ -z "$missing" ] && ok "presets complete: $root" || bad "presets MISSING:$missing in $root"
  mf="$root/minimal/agent.cordis.yml"
  [ -f "$mf" ] || bad "presets: minimal preset missing in $root"
  grep -q "compaction-basic" "$mf" 2>/dev/null && ok "minimal mounts compaction: $root" || bad "minimal LACKS compaction-basic: $root"
done

# 9. known-ghost census (twice bitten today): the bundle must always carry the
#    pi-ai LLM dependency trio AND the client-runtime loader pair the module
#    table compiles against. These silently shed across swaps (2026-08-29).
G_SUP="/Applications/DeepSeek Harness.app/Contents/Resources/supervisor"
for ghost in "node_modules/openai" "node_modules/@google/genai" "node_modules/@mistralai/mistralai"; do
  [ -d "$G_SUP/$ghost" ] && ok "ghost: $ghost present" || bad "ghost: MISSING $ghost"
done
for ghost in "node_modules/@deepseek-ai/dsh-client-runtime/lib/index.js" "node_modules/@deepseek-ai/dsh-client-runtime/lib/client.js"; do
  [ -f "$G_SUP/$ghost" ] && ok "ghost: $(basename $ghost) present" || bad "ghost: MISSING $ghost"
done
node --input-type=module -e "await import('$G_SUP/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js')" 2>/dev/null \
  && ok "ghost: pi-ai openai-completions importable" || bad "ghost: pi-ai import broken"
# client.js is a BROWSER-wrapped module table (window-based); a plain node
# import is a false negative. The decisive check: every require() INSIDE it
# resolves against the supervisor's node_modules.
ghost_out=$(python3 -c "
import re, subprocess, sys
src=open('$G_SUP/node_modules/@deepseek-ai/dsh-client-runtime/lib/client.js', errors='replace').read()
bad=[r for r in set(re.findall(r'require\"(\w[^\"]*)\"', src))
     if subprocess.run(['node','-e','require.resolve(sys.argv[1], {paths:[sys.argv[2]]})', r, '$G_SUP'], capture_output=True).returncode]
sys.exit(1 if bad else 0)
" 2>/dev/null) && ok "ghost: client-runtime table requires resolve" || bad "ghost: client-runtime table dangles"

exit $fail
