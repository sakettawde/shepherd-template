#!/usr/bin/env bash
# Runs every shepherd script test. Non-zero if any file fails.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rc=0
for f in "$HERE"/test-*.sh; do
  bash "$f" || rc=1
done
[ "$rc" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$rc"
