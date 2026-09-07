#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.nvm/versions/node/v22.22.3/bin:/opt/homebrew/bin:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = status ]; then exec node "$ROOT/plugins.mjs" status; fi
case "${1:-}" in build|update) ;; *) echo 'Expected build or update and a plugin name' >&2; exit 2;; esac
LOCKDIR="${DSH_HOME:-$HOME/.dsh}/app-update.lock.d"
mkdir "$LOCKDIR" 2>/dev/null || { echo 'Another update or reload is running (or a stale lock needs repair)' >&2; exit 4; }
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT
node "$ROOT/plugins.mjs" "$@"
