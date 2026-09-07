#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dsh-menubar-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/cache" -parse-as-library -o "$TEST_DIR/tests" \
  "$HERE/CommandRunner.swift" "$HERE/CommandRunnerTests.swift"
"$TEST_DIR/tests"
node --test "$HERE/../scripts/plugins.test.mjs" "$HERE/../scripts/ready.test.mjs"
python3 "$HERE/../scripts/update-control.test.py"
python3 "$HERE/../scripts/restart-control.test.py"
