#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
C="$HERE/../ledger-commit.sh"

echo "test-ledger-commit:"

# -b main, not a bare `git init`: git 2.43's default initial branch is still
# master (git-init.adoc, read 2026-08-23), and ledger-commit refuses to commit
# anywhere but main, so a master sandbox would fail every assertion below.
git -C "$SHEPHERD_ROOT" init -q -b main
git -C "$SHEPHERD_ROOT" config user.email t@t
git -C "$SHEPHERD_ROOT" config user.name T
printf 'seed\n' > "$SHEPHERD_ROOT/seed.md"
git -C "$SHEPHERD_ROOT" add seed.md
git -C "$SHEPHERD_ROOT" commit -qm seed

# an untracked new card is the most common commit in the system
printf 'reserved-by: shepherd-1 w6:p1 sess-1 now\n' > "$SHEPHERD_ROOT/ledger/tasks/T-0001.md"
assert_ok "commits a brand-new untracked card" bash "$C" "T-0001: captured -> queued" ledger/tasks/T-0001.md
assert_eq "the new card is in HEAD" \
  "$(git -C "$SHEPHERD_ROOT" show --name-only --format= HEAD | grep -c 'ledger/tasks/T-0001.md')" "1"

# another instance's unrelated work must not ride along
printf 'other-instance staged\n' > "$SHEPHERD_ROOT/other-staged.md"
git -C "$SHEPHERD_ROOT" add other-staged.md
printf 'other-instance unstaged\n' >> "$SHEPHERD_ROOT/seed.md"
printf 'mine\n' > "$SHEPHERD_ROOT/ledger/tasks/T-0002.md"

bash "$C" "T-0002: captured -> queued" ledger/tasks/T-0002.md >/dev/null
files=$(git -C "$SHEPHERD_ROOT" show --name-only --format= HEAD)
# grep -c . not wc -l: command substitution strips the trailing newline, so
# wc -l reports 0 for single-line output and the assertion could never pass.
assert_eq "commit contains only my path" "$(printf '%s' "$files" | grep -c .)" "1"
assert_eq "commit contains my path"      "$(printf '%s' "$files" | grep -c 'T-0002.md')" "1"
assert_eq "other instance's staged file survived staged" \
  "$(git -C "$SHEPHERD_ROOT" diff --cached --name-only | grep -c 'other-staged.md')" "1"
assert_eq "other instance's unstaged edit was not committed" \
  "$(git -C "$SHEPHERD_ROOT" show HEAD:seed.md | grep -c 'other-instance unstaged')" "0"

# nothing to commit is success, not failure
assert_ok "re-committing an unchanged path is a no-op success" \
  bash "$C" "no change" ledger/tasks/T-0002.md

# 5 concurrent commits on distinct paths all land
for i in 1 2 3 4 5; do printf 'p%s\n' "$i" > "$SHEPHERD_ROOT/ledger/tasks/T-010$i.md"; done
before=$(git -C "$SHEPHERD_ROOT" rev-list --count HEAD)
for i in 1 2 3 4 5; do
  ( bash "$C" "T-010$i: parallel" "ledger/tasks/T-010$i.md" >/dev/null 2>&1 ) &
done
wait
after=$(git -C "$SHEPHERD_ROOT" rev-list --count HEAD)
assert_eq "all five parallel commits landed" "$(( after - before ))" "5"
for i in 1 2 3 4 5; do
  assert_eq "T-010$i is committed" \
    "$(git -C "$SHEPHERD_ROOT" log --oneline --all -- "ledger/tasks/T-010$i.md" | wc -l)" "1"
done

# --- non-retryable failure: a rejecting pre-commit hook. git fails once and
# git_retry returns git's own status, not 99, so this must report the plain
# "commit failed" diagnostic - and, critically, still name the paths it left
# staged in the index every other instance shares.
hook="$SHEPHERD_ROOT/.git/hooks/pre-commit"
mkdir -p "$(dirname "$hook")"
printf '#!/bin/sh\necho "pre-commit says no" >&2\nexit 1\n' > "$hook"; chmod +x "$hook"
printf 'blocked\n' > "$SHEPHERD_ROOT/ledger/tasks/T-0200.md"
out=$(bash "$C" "T-0200: blocked by a hook" ledger/tasks/T-0200.md 2>&1); rc=$?
rm -f "$hook"
assert_eq "a rejected commit exits 1"            "$rc" "1"
assert_eq "and reports the failure"              "$(printf '%s' "$out" | grep -c 'ledger-commit: commit failed:')" "1"
assert_eq "not as a retry exhaustion"            "$(printf '%s' "$out" | grep -c 'attempts')" "0"
assert_eq "and names the still-staged paths"     "$(printf '%s' "$out" | grep -c 'left STAGED in the shared index: ledger/tasks/T-0200.md')" "1"
assert_eq "the path really is left staged"       \
  "$(git -C "$SHEPHERD_ROOT" diff --cached --name-only | grep -c 'ledger/tasks/T-0200.md')" "1"
assert_eq "and nothing was committed"            \
  "$(git -C "$SHEPHERD_ROOT" log --oneline --all -- ledger/tasks/T-0200.md | wc -l)" "0"

# --- retry exhaustion: every attempt fails on index.lock. This is the branch
# whose diagnostic was dead code - `rc=$?` after an `if` block reads the
# `if`'s own status (0 when its branch was not taken), so rc was never 99 and
# the "after N attempts" message could never print. git is stubbed to fail
# only for `commit`, and sleep is stubbed away so 30 attempts take no time.
stub="$SHEPHERD_ROOT/gitstub"; mkdir -p "$stub"
cat > "$stub/git" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case $a in
    rev-parse) echo main; exit 0 ;;
    add)    exit 0 ;;
    commit) echo "fatal: Unable to create '/repo/.git/index.lock': File exists."; exit 1 ;;
  esac
done
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$stub/sleep"
chmod +x "$stub/git" "$stub/sleep"
out=$( PATH="$stub:$PATH" bash "$C" "T-0201: contended" ledger/tasks/T-0201.md 2>&1 ); rc=$?
assert_eq "an exhausted retry budget exits 1" "$rc" "1"
assert_eq "and says how many attempts were made, not just that it failed" \
  "$(printf '%s' "$out" | grep -c 'commit failed after 30 attempts')" "1"

# --- the branch guard: this checkout is shared by every instance, so a task
# branch checked out here would silently collect all of their ledger commits.
# The guard must refuse BEFORE `git add`, so a refusal leaves the shared index
# exactly as it found it (F5).
git -C "$SHEPHERD_ROOT" checkout -q -b task/T-0112-guard
printf 'on a task branch\n' > "$SHEPHERD_ROOT/ledger/tasks/T-0300.md"
out=$(bash "$C" "T-0300: captured -> queued" ledger/tasks/T-0300.md 2>&1); rc=$?
assert_eq "a commit off main exits 1" "$rc" "1"
assert_eq "and names the branch it refused, and the one it expected" \
  "$(printf '%s' "$out" | grep -c "refusing to commit ledger state on branch 'task/T-0112-guard' (expected main)")" "1"
assert_eq "and says why, and what to do" \
  "$(printf '%s' "$out" | grep -c "would land here too. Check out main first")" "1"
assert_eq "the refused path was never staged" \
  "$(git -C "$SHEPHERD_ROOT" diff --cached --name-only | grep -c 'T-0300.md')" "0"
assert_eq "and nothing was committed" \
  "$(git -C "$SHEPHERD_ROOT" log --oneline --all -- ledger/tasks/T-0300.md | wc -l)" "0"

# fail-closed: a detached HEAD is not main either. `rev-parse --abbrev-ref`
# answers HEAD for a detached head AND for an unborn branch (measured, git
# 2.43.0), so both refuse.
git -C "$SHEPHERD_ROOT" checkout -q --detach HEAD
assert_fail "a commit on a detached HEAD is refused too" \
  bash "$C" "T-0300: detached" ledger/tasks/T-0300.md

git -C "$SHEPHERD_ROOT" checkout -q main
assert_ok "and the same commit succeeds on main" \
  bash "$C" "T-0300: captured -> queued" ledger/tasks/T-0300.md
assert_eq "the card really landed on main" \
  "$(git -C "$SHEPHERD_ROOT" log --oneline main -- ledger/tasks/T-0300.md | wc -l)" "1"

# --- the ref-lock race is retryable too. Two instances committing at the same
# moment both read HEAD; the loser's ref update fails its compare-and-swap with
# "cannot lock ref 'HEAD': is at <sha> but expected <sha>". That message carries
# neither "index.lock" nor "Another git process", so the retry loop used to fall
# through to its catch-all and drop the commit on the first collision - measured
# live: `bash scripts/tests/run.sh` failed the five-way parallel assertion in
# 1 run of 5, and the same rate on main before this port. git is stubbed to lose
# the race twice and then succeed, so the assertion is deterministic.
refstub="$SHEPHERD_ROOT/refstub"; mkdir -p "$refstub"
cat > "$refstub/git" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case $a in
    rev-parse) echo main; exit 0 ;;
    add)    exit 0 ;;
    commit)
      n=$(cat "$REFRACE_COUNT" 2>/dev/null); n=${n:-0}
      if [ "$n" -lt 2 ]; then
        echo $((n + 1)) > "$REFRACE_COUNT"
        echo "fatal: cannot lock ref 'HEAD': is at 4b59717 but expected be93a90"
        exit 128
      fi
      echo "[main abc1234] stubbed"; exit 0 ;;
  esac
done
exit 0
STUB
printf '#!/bin/sh\nexit 0\n' > "$refstub/sleep"
chmod +x "$refstub/git" "$refstub/sleep"
REFRACE_COUNT="$SHEPHERD_ROOT/refrace.count"; echo 0 > "$REFRACE_COUNT"
export REFRACE_COUNT
out=$( PATH="$refstub:$PATH" bash "$C" "T-0302: ref race" ledger/tasks/T-0302.md 2>&1 ); rc=$?
assert_eq "a lost HEAD race is retried, not dropped" "$rc" "0"
assert_eq "and it took the two retries the stub forced" "$(cat "$REFRACE_COUNT")" "2"
assert_eq "no failure diagnostic was printed" \
  "$(printf '%s' "$out" | grep -c 'ledger-commit: commit failed')" "0"

finish
