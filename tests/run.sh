#!/usr/bin/env bash
# Runs every shepherd script test, then the spec §12 drill. Non-zero if any fails.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rc=0
failed=""
for f in "$HERE"/test-*.sh; do
  bash "$f" || { rc=1; failed="$failed $(basename "$f")"; }
done
# shepherd-drill targets the crash WINDOWS the unit tests do not, and needs no
# herdr: every liveness probe goes through the SHEPHERD_TEST_HOOKS overrides
# (measured 2026-09-02: 13 checks in ~2 s). Its summary line is kept on a green
# run; the full output is printed only when it fails.
echo "drill:"
out=$(bash "$HERE/../bin/shepherd-drill" 2>&1); drc=$?
if [ "$drc" -eq 0 ]; then
  printf '  %s\n' "$(printf '%s\n' "$out" | tail -1)"
else
  printf '%s\n' "$out"; rc=1
fi
if [ "$rc" -eq 0 ]; then
  echo "ALL TESTS PASSED"
elif [ -n "$failed" ]; then
  echo "SOME TESTS FAILED:${failed}"
else
  echo "SOME TESTS FAILED"
fi
exit "$rc"
