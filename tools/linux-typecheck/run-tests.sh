#!/bin/bash
# Run the harness test binary from the repo root (DocDrift sentinels read repo files relatively).
# Only pure-logic cases can pass on Linux; compare against baseline-ok.txt to catch regressions.
# Usage: tools/linux-typecheck/run-tests.sh [--baseline] [tasty args, e.g. -p '/pattern/']
export PATH="$HOME/.ghcup/bin:$PATH"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${PM_HARNESS_DIR:-$HERE/work}"
T=$(find "$WORK/dist-newstyle" -type f -name pm-test -perm -u+x 2>/dev/null | head -1)
[ -n "$T" ] || { echo "no pm-test binary — run check.sh first"; exit 3; }
save=0; if [ "$1" = "--baseline" ]; then save=1; shift; fi
LOG="$WORK/test-run.log"
# Some Windows-only ingest cases block forever on the Win32 stubs; a per-case timeout lets the run finish.
( cd "$REPO" && timeout 1200 "$T" --num-threads 1 --timeout 60s "$@" ) > "$LOG" 2>&1
code=$?
grep -E 'tests passed|tests failed|out of' "$LOG" | tail -1
grep -E ':\s+OK' "$LOG" | sed -E 's/:\s+OK.*//; s/^\s+//' | sort > "$WORK/now-ok.txt"
echo "OK on Linux: $(wc -l < "$WORK/now-ok.txt")"
if [ $save = 1 ]; then cp "$WORK/now-ok.txt" "$HERE/baseline-ok.txt"; echo "baseline saved to $HERE/baseline-ok.txt"; fi
if [ -f "$HERE/baseline-ok.txt" ] && [ $# = 0 ]; then
  lost=$(comm -23 "$HERE/baseline-ok.txt" "$WORK/now-ok.txt")
  if [ -n "$lost" ]; then echo "REGRESSION — cases that passed in the baseline but not now:"; echo "$lost"; exit 1; fi
  echo "no regression against baseline (tasty exit $code is expected: Windows-only cases fail here)"
  echo "full log: $LOG"
  exit 0
fi
echo "full log: $LOG"
exit $code
