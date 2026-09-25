#!/bin/bash
# Re-sync the repo tree into the harness and build lib + exe + test-suite. Exit code = cabal's.
# Usage: tools/linux-typecheck/check.sh [max-output-lines]
export PATH="$HOME/.ghcup/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${PM_HARNESS_DIR:-$HERE/work}"
"$HERE/gen-cabal.sh" >/dev/null || exit 3
cd "$WORK" || exit 3
cabal build lib:photo-manager exe:pm test:pm-test 2>&1 \
  | grep -v '^\[' | grep -E -A6 'error|Error|warning|Warning|Linking|Failed|Up to date' | head -"${1:-150}"
exit ${PIPESTATUS[0]}
