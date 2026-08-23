#!/usr/bin/env bash
# Spec S12 drill. Targets the WINDOWS, not the primitives - the unit tests in
# scripts/tests/ already cover the primitives.
# Runs entirely in a sandbox; never touches the real ledger.
#
# S12.5 (shared-path commit under the card lock) is deliberately absent: it is
# a procedure two live instances perform, not something one script can drive.
# What protects a shared path is S6.2's commit-INSIDE-the-lock rule. It is not
# the `--only` isolation test in test-ledger-commit.sh, and that test must
# never be read as covering S12.5: S8.1 says outright that `--only` does not
# protect a shared path - it snapshots working-tree content and will commit
# another instance's half-written edit to the same file under your message.
# `--only` isolates OTHER paths, which is a different guarantee.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PASS=0; FAIL=0
say() { printf '\n== %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export SHEPHERD_ROOT="$SANDBOX"
# Every liveness/pane-session test hook is gated on SHEPHERD_TEST_HOOKS=1.
# Without this, all hooks below are inert and the drill round-trips to the
# real herdr server instead of exercising the sandbox.
export SHEPHERD_TEST_HOOKS=1
mkdir -p "$SANDBOX/ledger/locks" "$SANDBOX/ledger/tasks" "$SANDBOX/ledger/shepherds"
L="$SANDBOX/ledger/locks"; T="$SANDBOX/ledger/tasks"

say "S12.1 reserve under contention"
for i in $(seq 1 30); do
  ( bash "$HERE/reserve-task-id.sh" reserve "shepherd-$i" "w6:p$i" "sess-$i" >> "$SANDBOX/ids" ) &
done; wait
check "30 distinct ids" "$(sort -u "$SANDBOX/ids" | wc -l)" "30"
check "every reservation names a claimant" "$(grep -L '^reserved-by:' "$T"/T-*.md | wc -l)" "0"

say "S12.2 kill between reserve and fill"
rm -f "$T"/T-*.md
bash "$HERE/reserve-task-id.sh" reserve shepherd-1 w6:p1 sess-1 >/dev/null
export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1"
bash "$HERE/reserve-task-id.sh" sweep >/dev/null
check "a live claimant's reservation is never re-issued" "$(ls "$T" | wc -l)" "1"
export SHEPHERD_LIVENESS_OVERRIDE=""
bash "$HERE/reserve-task-id.sh" sweep >/dev/null
check "a gone claimant's reservation is cleared" "$(ls "$T" | wc -l)" "0"

say "S12.3 simultaneous same-id boot"
export HERDR_ENV=1
# SHEPHERD_PANE_SESSION was renamed to SHEPHERD_PANE_SESSION_OVERRIDE - the
# old name read like ordinary configuration next to SHEPHERD_TASK_ID and
# SHEPHERD_STATUS_FILE, and a leaked value could make a sweep delete every
# lock in the system.
export HERDR_PANE_ID=w6:p1 SHEPHERD_PANE_SESSION_OVERRIDE=sess-1 SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1 w6:p2:sess-2"
bash "$HERE/shepherd-identity.sh" acquire shepherd-1 >/dev/null
export HERDR_PANE_ID=w6:p2 SHEPHERD_PANE_SESSION_OVERRIDE=sess-2
bash "$HERE/shepherd-identity.sh" acquire shepherd-1 >/dev/null 2>&1
check "the second instance is refused" "$?" "1"
check "the first instance still holds the id" "$(awk '{print $2}' "$L/shepherd-1.lock")" "w6:p1"

say "S12.4 commit under contention"
G="$SANDBOX/git"; mkdir -p "$G/ledger/tasks"
# -b main: git 2.43 still opens on master, and ledger-commit.sh refuses to
# commit ledger state anywhere but main.
git -C "$G" init -q -b main; git -C "$G" config user.email t@t; git -C "$G" config user.name T
printf 'seed\n' > "$G/seed"; git -C "$G" add seed; git -C "$G" commit -qm seed
( export SHEPHERD_ROOT="$G"
  for i in 1 2 3 4 5; do printf 'x\n' > "$G/ledger/tasks/T-020$i.md"; done
  for i in 1 2 3 4 5; do ( bash "$HERE/ledger-commit.sh" "T-020$i" "ledger/tasks/T-020$i.md" >/dev/null 2>&1 ) & done
  wait )
check "all five parallel commits landed" "$(git -C "$G" rev-list --count HEAD)" "6"

say "S12.6 kill mid-reassignment (card owned, lock not taken)"
export SHEPHERD_ROOT="$SANDBOX"
printf '# T-0300: x\nstate: working\nowner: shepherd-2\n' > "$T/T-0300.md"
printf 'shepherd-1 w6:p1 sess-1 T-0300 %s\n' "$(date -Iseconds)" > "$L/project-alpha.lock"
export SHEPHERD_LIVENESS_OVERRIDE=""
out=$(bash "$HERE/lock.sh" sweep)
check "the mid-reassignment lock is reported, not freed" "$(printf '%s' "$out" | grep -c '^ORPHAN project-alpha T-0300')" "1"
check "and the lock file survives for the new owner" "$( [ -f "$L/project-alpha.lock" ] && echo yes || echo no )" "yes"

say "S12.7 orphan rule"
rm -f "$L"/*.lock
printf '# T-0400: x\nstate: working\nowner: shepherd-9\n' > "$T/T-0400.md"
printf '# T-0401: x\nstate: done\nowner: shepherd-9\n' > "$T/T-0401.md"
printf 'shepherd-9 w6:p9 sess-9 T-0400 %s\n' "$(date -Iseconds)" > "$L/project-a.lock"
printf 'shepherd-9 w6:p9 sess-9 T-0401 %s\n' "$(date -Iseconds)" > "$L/project-b.lock"
bash "$HERE/lock.sh" sweep >/dev/null
check "active task keeps its lock" "$( [ -f "$L/project-a.lock" ] && echo yes || echo no )" "yes"
check "closed task frees its lock"  "$( [ -f "$L/project-b.lock" ] && echo yes || echo no )" "no"

say "S12.8 unresolvable liveness never reclaims"
# shepherd_live is tri-state: 0 live, 1 gone, 2
# unresolved. Only 1 authorises a reclaim. This is the only scenario above that
# exercises the "2" branch, and it deliberately fixtures a CLOSED task
# (state: done) - the orphan rule already protects an active task regardless
# of liveness, so an active fixture here would pass even if the liveness
# gate were broken. Only the liveness gate can save a closed task's lock.
rm -f "$L"/*.lock; rm -f "$T"/T-*.md
printf '# T-0500: x\nstate: done\nowner: shepherd-9\n' > "$T/T-0500.md"
printf 'shepherd-9 w6:p9 sess-9 T-0500 %s\n' "$(date -Iseconds)" > "$L/project-unresolvable.lock"
export SHEPHERD_LIVENESS_UNKNOWN="w6:p9:sess-9"
export SHEPHERD_LIVENESS_OVERRIDE=""
out=$(bash "$HERE/lock.sh" sweep)
check "unresolvable holder is reported, not swept" \
  "$(printf '%s' "$out" | grep -c '^UNKNOWN-LIVENESS project-unresolvable')" "1"
check "and its lock survives" "$( [ -f "$L/project-unresolvable.lock" ] && echo yes || echo no )" "yes"
unset SHEPHERD_LIVENESS_UNKNOWN

printf '\nDRILL: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
