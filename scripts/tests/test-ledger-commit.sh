#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
C="$HERE/../ledger-commit.sh"

echo "test-ledger-commit:"

git -C "$SHEPHERD_ROOT" init -q
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

finish
