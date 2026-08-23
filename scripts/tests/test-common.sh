#!/usr/bin/env bash
# Tests for scripts/lib/shepherd-common.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
. "$HERE/../lib/shepherd-common.sh"

echo "test-common:"

# --- atomic_create ---
t="$SHEPHERD_ROOT/ledger/locks/a.lock"
atomic_create "$t" "holder-1 w6:p1 sess-1 none 2026-08-18T10:00:00+05:30"
assert_eq "atomic_create returns 0 on first create" "$?" "0"
assert_eq "content landed whole" "$(cat "$t")" "holder-1 w6:p1 sess-1 none 2026-08-18T10:00:00+05:30"

atomic_create "$t" "holder-2 w6:p2 sess-2 none 2026-08-18T10:00:01+05:30"
assert_eq "atomic_create returns 1 when it already exists" "$?" "1"
assert_eq "loser did not overwrite the winner" "$(awk '{print $1}' "$t")" "holder-1"

# --- atomic_create error path: distinguishes EEXIST from other failures ---
# mktemp failure (no [ -e ] check needed, always returns 2)
readonly_dir="$SHEPHERD_ROOT/readonly"
mkdir -p "$readonly_dir"
chmod 000 "$readonly_dir"
atomic_create "$readonly_dir/x" "content"
assert_eq "atomic_create returns 2 when mktemp fails" "$?" "2"
chmod 755 "$readonly_dir"  # restore for cleanup

# ln failure with absent target: tests the [ -e "$target" ] branch
# Shim ln so mktemp succeeds but ln fails, forcing execution through
# the new [ -e "$target" ] && return 1 / return 2 logic.
shim="$SHEPHERD_ROOT/shim"; mkdir -p "$shim"
printf '#!/bin/sh\nexit 1\n' > "$shim/ln"; chmod +x "$shim/ln"
( PATH="$shim:$PATH"; . "$HERE/../lib/shepherd-common.sh"
  atomic_create "$SHEPHERD_ROOT/ledger/locks/err.lock" "content" )
assert_eq "atomic_create returns 2 when ln fails and target is absent" "$?" "2"
assert_nofile "no target created on failed ln" "$SHEPHERD_ROOT/ledger/locks/err.lock"
assert_eq "no temp file left after failed ln" \
  "$(find "$SHEPHERD_ROOT/ledger/locks" -name '.tmp.*' | wc -l)" "0"

# --- 100-way contention: exactly one winner, no empty-file window ---
race="$SHEPHERD_ROOT/ledger/locks/race.lock"
for i in $(seq 1 100); do
  ( . "$HERE/../lib/shepherd-common.sh"; atomic_create "$race" "racer-$i x y none z" ) &
done >/dev/null 2>&1
wait
assert_file "race produced a lock" "$race"
assert_eq "race lock has exactly one line" "$(wc -l < "$race")" "1"
assert_eq "race lock is non-empty" "$( [ -s "$race" ] && echo yes || echo no )" "yes"
assert_eq "no temp files left behind" "$(find "$SHEPHERD_ROOT/ledger/locks" -name '.tmp.*' | wc -l)" "0"

# --- shepherd_live honours the test override ---
export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1 w6:p9:sess-9"
assert_ok   "declared-live pane is live"      shepherd_live "w6:p1" "sess-1"
assert_fail "unlisted pane is gone"           shepherd_live "w6:p2" "sess-2"
assert_fail "right pane wrong session is gone" shepherd_live "w6:p1" "sess-OTHER"
export SHEPHERD_LIVENESS_OVERRIDE=""
assert_fail "empty override means nothing is live" shepherd_live "w6:p1" "sess-1"

# --- pane_probe: tri-state probe against a stubbed herdr ---
# herdr 0.7.4's real shape: a missing pane's pane_not_found document lands
# on STDERR with exit 1 (verified directly against the live herdr binary,
# see the fix-round report). pane_probe must classify the JSON body, never
# the exit status, so the stderr/exit-1 shape is the primary case here and
# the older stdout/exit-0 shape is kept as a second, tolerated case.
s1="$SHEPHERD_ROOT/stub-pnf-stderr"; mkdir -p "$s1"
cat > "$s1/herdr" <<'STUB'
#!/bin/sh
echo '{"error":{"code":"pane_not_found","message":"pane w6:pZZZ not found"},"id":"cli:pane:get"}' >&2
exit 1
STUB
chmod +x "$s1/herdr"
out=$( PATH="$s1:$PATH" pane_probe w6:pZZZ ); rc=$?
assert_eq "pane_probe returns 1 for pane_not_found on stderr, exit 1 (the real herdr shape)" "$rc" "1"
assert_eq "pane_probe prints nothing for pane_not_found" "$out" ""

s1b="$SHEPHERD_ROOT/stub-pnf-stdout"; mkdir -p "$s1b"
cat > "$s1b/herdr" <<'STUB'
#!/bin/sh
echo '{"error":{"code":"pane_not_found","message":"pane w6:pZZZ not found"},"id":"cli:pane:get"}'
STUB
chmod +x "$s1b/herdr"
out=$( PATH="$s1b:$PATH" pane_probe w6:pZZZ ); rc=$?
assert_eq "pane_probe also returns 1 for pane_not_found on stdout, exit 0" "$rc" "1"

s2="$SHEPHERD_ROOT/stub-othererr"; mkdir -p "$s2"
cat > "$s2/herdr" <<'STUB'
#!/bin/sh
echo '{"error":{"code":"internal_error","message":"boom"},"id":"cli:pane:get"}' >&2
exit 1
STUB
chmod +x "$s2/herdr"
out=$( PATH="$s2:$PATH" pane_probe w6:pX ); rc=$?
assert_eq "pane_probe returns 2 for a non-pane_not_found error code" "$rc" "2"

s3="$SHEPHERD_ROOT/stub-nonjson"; mkdir -p "$s3"
cat > "$s3/herdr" <<'STUB'
#!/bin/sh
echo "not json at all"
STUB
chmod +x "$s3/herdr"
out=$( PATH="$s3:$PATH" pane_probe w6:pX ); rc=$?
assert_eq "pane_probe returns 2 for non-JSON output" "$rc" "2"

s4="$SHEPHERD_ROOT/stub-failsilent"; mkdir -p "$s4"
cat > "$s4/herdr" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$s4/herdr"
out=$( PATH="$s4:$PATH" pane_probe w6:pX ); rc=$?
assert_eq "pane_probe returns 2 when herdr exits non-zero with no output on either stream" "$rc" "2"

s5="$SHEPHERD_ROOT/stub-ok"; mkdir -p "$s5"
cat > "$s5/herdr" <<'STUB'
#!/bin/sh
echo '{"result":{"pane":{"agent_session":{"value":"sess-42"}}},"id":"cli:pane:get"}'
STUB
chmod +x "$s5/herdr"
out=$( PATH="$s5:$PATH" pane_probe w6:pX ); rc=$?
assert_eq "pane_probe returns 0 for a well-formed document" "$rc" "0"
assert_eq "pane_probe prints the session id" "$out" "sess-42"

# --- pane_probe: previously-unpinned branches (a reviewer mutated these
# exit codes and the suite stayed green) ---
s5b="$SHEPHERD_ROOT/stub-emptyresult"; mkdir -p "$s5b"
cat > "$s5b/herdr" <<'STUB'
#!/bin/sh
echo '{"result":{}}'
STUB
chmod +x "$s5b/herdr"
out=$( PATH="$s5b:$PATH" pane_probe w6:pX ); rc=$?
assert_eq "pane_probe returns 2 for a result with no pane object" "$rc" "2"

s5c="$SHEPHERD_ROOT/stub-nosession"; mkdir -p "$s5c"
cat > "$s5c/herdr" <<'STUB'
#!/bin/sh
echo '{"result":{"pane":{"pane_id":"w6:pX"}},"id":"cli:pane:get"}'
STUB
chmod +x "$s5c/herdr"
out=$( PATH="$s5c:$PATH" pane_probe w6:pX ); rc=$?
assert_eq "pane_probe returns 1 for a pane present with no agent_session" "$rc" "1"

# --- shepherd_live: tri-state via the real probe path (no override hooks set) ---
unset SHEPHERD_LIVENESS_OVERRIDE SHEPHERD_LIVENESS_UNKNOWN
s6="$SHEPHERD_ROOT/stub-diffsession"; mkdir -p "$s6"
cat > "$s6/herdr" <<'STUB'
#!/bin/sh
echo '{"result":{"pane":{"agent_session":{"value":"sess-real"}}},"id":"cli:pane:get"}'
STUB
chmod +x "$s6/herdr"
PATH="$s6:$PATH" shepherd_live w6:pX sess-expected; rc=$?
assert_eq "shepherd_live returns 1 when the pane exists but runs a different session" "$rc" "1"

# --- shepherd_live: SHEPHERD_LIVENESS_UNKNOWN ---
unset SHEPHERD_LIVENESS_OVERRIDE
export SHEPHERD_LIVENESS_UNKNOWN="w6:p1:sess-1"
shepherd_live w6:p1 sess-1; rc=$?
assert_eq "shepherd_live returns 2 when SHEPHERD_LIVENESS_UNKNOWN lists the pair" "$rc" "2"

export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1"
shepherd_live w6:p1 sess-1; rc=$?
assert_eq "SHEPHERD_LIVENESS_UNKNOWN takes precedence over SHEPHERD_LIVENESS_OVERRIDE" "$rc" "2"
unset SHEPHERD_LIVENESS_UNKNOWN
export SHEPHERD_LIVENESS_OVERRIDE=""

# --- fold-in regression: SHEPHERD_LIVENESS_UNKNOWN set ALONE, queried with
# a pair in NEITHER list, must resolve to 1 without ever calling herdr.
# Every SHEPHERD_LIVENESS_UNKNOWN assertion above only ever queries a pair
# that IS listed, so all of them pass identically under the old buggy
# fall-through and under the fix - this is the only case that tells them
# apart. Shadowed with a shell function so the test fails the moment herdr
# would actually be invoked, not just on the wrong return code.
unset SHEPHERD_LIVENESS_OVERRIDE
export SHEPHERD_LIVENESS_UNKNOWN="w6:p1:sess-1"
herdr_invoked=0
herdr() { herdr_invoked=1; return 1; }
shepherd_live w6:pOTHER sess-other; rc=$?
assert_eq "SHEPHERD_LIVENESS_UNKNOWN alone still resolves an unlisted pair to 1" "$rc" "1"
assert_eq "and never calls herdr to do it" "$herdr_invoked" "0"
unset -f herdr
unset SHEPHERD_LIVENESS_UNKNOWN
export SHEPHERD_LIVENESS_OVERRIDE=""

# --- hooks_active gate: with SHEPHERD_TEST_HOOKS unset, every test hook is
# inert, even set to something hostile - this is what a hook leaking into a
# real shepherd shell looks like. herdr is on PATH in this dev environment
# and pinned (see CLAUDE.md S7), so pane_probe genuinely round-trips to it;
# regardless of what that round-trip returns, it must never mechanically
# echo back the fabricated override value below.
unset SHEPHERD_TEST_HOOKS
export SHEPHERD_PANE_SESSION_OVERRIDE=sess-fake
export SHEPHERD_LIVENESS_OVERRIDE="w6:pTESTHOSTILE999:sess-fake"
export SHEPHERD_LIVENESS_UNKNOWN=""
out=$(pane_probe w6:pTESTHOSTILE999 2>/dev/null); rc=$?
assert_eq "pane_probe ignores SHEPHERD_PANE_SESSION_OVERRIDE without SHEPHERD_TEST_HOOKS" \
  "$([ "$out" = "sess-fake" ] && echo LEAKED || echo ok)" "ok"
shepherd_live w6:pTESTHOSTILE999 sess-fake; live_rc=$?
assert_eq "shepherd_live ignores SHEPHERD_LIVENESS_OVERRIDE without SHEPHERD_TEST_HOOKS" \
  "$([ "$live_rc" = "0" ] && echo LEAKED || echo ok)" "ok"
unset SHEPHERD_PANE_SESSION_OVERRIDE SHEPHERD_LIVENESS_OVERRIDE SHEPHERD_LIVENESS_UNKNOWN
export SHEPHERD_TEST_HOOKS=1

# --- task_state ---
printf '# T-0001: x\nstate: working\nowner: shepherd-1\n' > "$SHEPHERD_ROOT/ledger/tasks/T-0001.md"
assert_eq "task_state reads the state field" "$(task_state T-0001)" "working"
assert_eq "task_state on a missing card prints nothing" "$(task_state T-9999)" ""

finish
