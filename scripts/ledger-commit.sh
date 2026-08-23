#!/usr/bin/env bash
# Path-scoped commit for a working tree shared by several shepherds.
# See docs/specs/multi-shepherd-design.md S8.1.
#
#   ledger-commit.sh "<message>" <path>...
#
# `git add` first: `--only` cannot commit an untracked path, and every new
# task card is untracked. Flags must precede `--`, or git reads `-m` as a
# pathspec. Committing with a pathspec isolates other paths—`--only` is the
# explicit spelling of git's default when a pathspec is given. A shared file
# must be committed inside its card lock (spec S6.2).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shepherd-common.sh"

# Every branch below classifies git's porcelain output by matching English
# substrings. Pin the locale so a translated message cannot be misread as a
# failure - or worse, a genuine failure misread as a no-op.
export LC_ALL=C LANGUAGE=C

ATTEMPTS=30

git_retry() {
  local i out rc
  for (( i = 1; i <= ATTEMPTS; i++ )); do
    out=$(git -C "$SHEPHERD_ROOT" "$@" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then printf '%s' "$out"; return 0; fi
    case $out in
      *index.lock*|*"Another git process"*)
        sleep "1.$(( RANDOM % 9 ))"
        continue ;;
      *) printf '%s' "$out"; return "$rc" ;;
    esac
  done
  printf '%s' "$out"
  return 99
}

msg=${1:-}
shift || true
if [ -z "$msg" ] || [ $# -lt 1 ]; then
  echo 'usage: ledger-commit.sh "<message>" <path>...' >&2
  exit 2
fi
# Empty messages are never legitimate - every commit in this system must have a
# descriptive transition message like "T-0001: captured -> queued".

if ! out=$(git_retry add -- "$@"); then
  echo "ledger-commit: add failed: $out" >&2
  exit 1
fi

# Capture the status of the command itself. `rc=$?` after an `if` block reads
# the status of the *`if`*, and a POSIX `if` whose branch was not taken exits
# 0 - so the old shape left rc permanently 0 and the retry-exhaustion
# diagnostic below could never fire. Proof:
#   bash -c 'f(){ return 99; }; if out=$(f); then exit 0; fi; rc=$?; echo rc=$rc'
# prints rc=0.
out=$(git_retry commit --only -m "$msg" -- "$@"); rc=$?
if [ "$rc" -eq 0 ]; then
  printf '%s\n' "$out" | tail -1
  exit 0
fi

case $out in
  *"nothing to commit"*|*"no changes added"*|*"nothing added"*)
    echo "ledger-commit: nothing to commit for: $*"
    exit 0 ;;
esac

if [ "$rc" -eq 99 ]; then
  echo "ledger-commit: commit failed after $ATTEMPTS attempts: $out" >&2
else
  echo "ledger-commit: commit failed: $out" >&2
fi
echo "ledger-commit: these paths are left STAGED in the shared index: $*" >&2
echo "ledger-commit: do NOT run 'git commit -a' - it would sweep them into an unrelated commit" >&2
exit 1
