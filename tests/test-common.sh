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

# --- now_iso: the clock hook, gated like every other hook (T-0217 §8) ---
export SHEPHERD_NOW_OVERRIDE=2030-01-01T00:00:00+00:00
assert_eq "now_iso honours SHEPHERD_NOW_OVERRIDE under the test gate" "$(now_iso)" "2030-01-01T00:00:00+00:00"
out=$( unset SHEPHERD_TEST_HOOKS; now_iso )
assert_eq "now_iso ignores SHEPHERD_NOW_OVERRIDE without SHEPHERD_TEST_HOOKS" \
  "$([ "$out" = "2030-01-01T00:00:00+00:00" ] && echo LEAKED || echo ok)" "ok"
unset SHEPHERD_NOW_OVERRIDE
assert_eq "now_iso without the hook is a real ISO-8601 timestamp" \
  "$(now_iso | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$')" "1"

# --- elog: one line per event, fixed five columns, never fails its caller ---
assert_eq "EVENTS_LOG lives under the sandbox root" "$EVENTS_LOG" "$SHEPHERD_ROOT/ledger/events.log"
rm -f "$EVENTS_LOG"
export SHEPHERD_NOW_OVERRIDE=2030-01-01T00:00:01+00:00
elog shepherd-t acquire project-x ACQUIRED T-0001; rc=$?
assert_eq "elog returns 0" "$rc" "0"
assert_eq "elog writes exactly the five columns plus detail" \
  "$(cat "$EVENTS_LOG")" "2030-01-01T00:00:01+00:00 shepherd-t acquire project-x ACQUIRED T-0001"
elog shepherd-t sweep project-y SWEPT
assert_eq "elog with no detail writes five columns and no trailing space" \
  "$(tail -1 "$EVENTS_LOG")" "2030-01-01T00:00:01+00:00 shepherd-t sweep project-y SWEPT"
elog "" sweep "" SWEEP-SKIPPED "oracle down"
assert_eq "elog substitutes - for an empty instance or target so columns never shift" \
  "$(tail -1 "$EVENTS_LOG")" "2030-01-01T00:00:01+00:00 - sweep - SWEEP-SKIPPED oracle down"
elog shepherd-t sweep project-z ORPHAN $'multi\nline detail'
assert_eq "elog folds newlines in the detail so one event stays one line" \
  "$(tail -1 "$EVENTS_LOG")" "2030-01-01T00:00:01+00:00 shepherd-t sweep project-z ORPHAN multi line detail"
assert_eq "elog appended, never truncated" "$(wc -l < "$EVENTS_LOG")" "4"
elog shepherd-t sweep project-z ORPHAN $'carriage\rreturn detail'
assert_eq "elog folds carriage returns in the detail too" \
  "$(tail -1 "$EVENTS_LOG")" "2030-01-01T00:00:01+00:00 shepherd-t sweep project-z ORPHAN carriage return detail"
# shepherd-lock release takes an arbitrary holder string: whitespace inside any of
# the four fixed columns would shift every column after it.
elog 'bad holder' release 'x y' 'RE FUSED'
assert_eq "elog folds whitespace inside the four fixed columns so they never shift" \
  "$(tail -1 "$EVENTS_LOG" | awk '{print $2, $3, $4, $5}')" "bad_holder release x_y RE_FUSED"
unset SHEPHERD_NOW_OVERRIDE

# elog must never fail the coordination verb that called it
rm -f "$EVENTS_LOG"; mkdir -p "$EVENTS_LOG"        # a directory where the file should be
elog shepherd-t acquire project-x ACQUIRED 2>"$SHEPHERD_ROOT/elog.err"; rc=$?
assert_eq "elog returns 0 when the log is unwritable" "$rc" "0"
assert_eq "and prints nothing to stderr" "$(wc -c < "$SHEPHERD_ROOT/elog.err")" "0"
rmdir "$EVENTS_LOG"
rm -rf "$SHEPHERD_ROOT/ledger"
elog shepherd-t acquire project-x ACQUIRED
assert_file "elog creates the ledger directory when it is missing" "$EVENTS_LOG"
mkdir -p "$SHEPHERD_ROOT/ledger/locks" "$SHEPHERD_ROOT/ledger/tasks" "$SHEPHERD_ROOT/ledger/shepherds"

# 50 concurrent appends: every line whole, none interleaved
rm -f "$EVENTS_LOG"
for i in $(seq 1 50); do ( elog "shepherd-$i" acquire "lock-$i" ACQUIRED "detail-$i" ) & done
wait
assert_eq "50 concurrent elog calls produce 50 lines" "$(wc -l < "$EVENTS_LOG")" "50"
assert_eq "every concurrent line has its five columns intact" \
  "$(awk 'NF < 5 || $3 != "acquire" || $5 != "ACQUIRED" {bad++} END{print bad+0}' "$EVENTS_LOG")" "0"

# --- valid_name: one pattern for every lock name (T-0217 §3) ---
for good in dispatch card-_index card-_memory project-karta 'project-karta~2' shepherd-kelpie shepherd-kelpie.reclaim T-0001 a 9; do
  assert_ok "valid_name accepts '$good'" valid_name name "$good"
done
for bad in '' 'bad/name' '../up' '.tmp.abc' '-lead' 'has space' $'tab\there' $'new\nline' 'semi;colon' 'shepherd-1/../../tmp/x' 'é'; do
  out=$(valid_name name "$bad" 2>&1); rc=$?
  # ${bad@Q} keeps a tab or newline in the value from breaking the test line
  assert_eq "valid_name rejects ${bad@Q} with exit 2" "$rc" "2"
  assert_eq "and names the rule for ${bad@Q}" "$(printf '%s' "$out" | grep -cF 'ERROR: name must match ^[A-Za-z0-9_][A-Za-z0-9_.~-]*$')" "1"
done

# --- valid_shepherd_id: the identity pattern, shared by identity and shepherd-lock live ---
for good in shepherd-1 shepherd-collie shepherd-kelpie-2; do
  assert_ok "valid_shepherd_id accepts $good" valid_shepherd_id "$good"
done
for bad in not-a-shepherd 'shepherd-' shepherd-Collie shepherd-collie- shepherd--collie shepherd-col.lie 'shepherd-1 2' 'shepherd-1/../x'; do
  out=$(valid_shepherd_id "$bad" 2>&1); rc=$?
  assert_eq "valid_shepherd_id rejects '$bad' with exit 2" "$rc" "2"
  assert_eq "and says bad shepherd id for '$bad'" "$(printf '%s' "$out" | grep -c '^ERROR: bad shepherd id: ')" "1"
done

# --- lock_line: first line or nothing, never an error ---
printf 'h p s none ts\nsecond line\n' > "$SHEPHERD_ROOT/ledger/locks/ll.lock"
assert_eq "lock_line prints the first line only" "$(lock_line "$SHEPHERD_ROOT/ledger/locks/ll.lock")" "h p s none ts"
assert_eq "lock_line on a missing file prints nothing" "$(lock_line "$SHEPHERD_ROOT/ledger/locks/nope.lock" 2>&1)" ""
assert_ok "lock_line on a missing file exits 0" lock_line "$SHEPHERD_ROOT/ledger/locks/nope.lock"

# --- shepherd_live with a holder: rollover-safe liveness (T-0217 §6.1) ---
# A project lock still carries the session its holder had BEFORE a context
# rollover. Wake step 2 re-acquired the identity lock with the new session.
# The old pair is gone; the identity lock's pair is live; so the holder is live.
L="$SHEPHERD_ROOT/ledger/locks"
export SHEPHERD_LIVENESS_OVERRIDE="w6:pNEW:sess-new"
unset SHEPHERD_LIVENESS_UNKNOWN
printf 'shepherd-roll w6:pNEW sess-new none 2026-01-01T00:00:00+00:00\n' > "$L/shepherd-roll.lock"
shepherd_live w6:pOLD sess-old shepherd-roll; rc=$?
assert_eq "a gone pair resolves live through the holder's identity lock" "$rc" "0"
shepherd_live w6:pOLD sess-old; rc=$?
assert_eq "the same pair with no holder is still gone (two-arg contract unchanged)" "$rc" "1"
shepherd_live w6:pOLD sess-old other-holder; rc=$?
assert_eq "a holder that is not shepherd-* is never re-resolved" "$rc" "1"

# identity lock names the SAME pair as the lock being checked: nothing new
# to learn, gone stays gone. This is the /clear -> wake-step-2 gap (S6.3).
printf 'shepherd-same w6:pOLD sess-old none 2026-01-01T00:00:00+00:00\n' > "$L/shepherd-same.lock"
shepherd_live w6:pOLD sess-old shepherd-same; rc=$?
assert_eq "identity lock naming the same pair leaves gone as gone" "$rc" "1"

# identity lock missing, empty, or short: gone as today
shepherd_live w6:pOLD sess-old shepherd-nolock; rc=$?
assert_eq "no identity lock for the holder: gone" "$rc" "1"
printf '' > "$L/shepherd-empty.lock"
shepherd_live w6:pOLD sess-old shepherd-empty; rc=$?
assert_eq "empty identity lock: gone" "$rc" "1"
printf 'shepherd-short w6:pNEW\n' > "$L/shepherd-short.lock"
shepherd_live w6:pOLD sess-old shepherd-short; rc=$?
assert_eq "short identity lock line: gone" "$rc" "1"

# identity pair is itself gone -> gone; unresolved -> unresolved (2, never 1)
printf 'shepherd-dead w6:pDEAD sess-dead none 2026-01-01T00:00:00+00:00\n' > "$L/shepherd-dead.lock"
shepherd_live w6:pOLD sess-old shepherd-dead; rc=$?
assert_eq "identity pair gone too: gone" "$rc" "1"
export SHEPHERD_LIVENESS_UNKNOWN="w6:pFOG:sess-fog"
printf 'shepherd-fog w6:pFOG sess-fog none 2026-01-01T00:00:00+00:00\n' > "$L/shepherd-fog.lock"
shepherd_live w6:pOLD sess-old shepherd-fog; rc=$?
assert_eq "identity pair unresolved: unresolved, never collapsed to gone" "$rc" "2"

# a direct live or unresolved answer is never re-resolved
export SHEPHERD_LIVENESS_OVERRIDE="w6:pLIVE:sess-live"
printf 'shepherd-x w6:pDEAD sess-dead none 2026-01-01T00:00:00+00:00\n' > "$L/shepherd-x.lock"
shepherd_live w6:pLIVE sess-live shepherd-x; rc=$?
assert_eq "a directly live pair stays live whatever the identity lock says" "$rc" "0"
export SHEPHERD_LIVENESS_UNKNOWN="w6:pFOG:sess-fog"
export SHEPHERD_LIVENESS_OVERRIDE="w6:pNEW:sess-new"
printf 'shepherd-y w6:pNEW sess-new none 2026-01-01T00:00:00+00:00\n' > "$L/shepherd-y.lock"
shepherd_live w6:pFOG sess-fog shepherd-y; rc=$?
assert_eq "a directly unresolved pair stays unresolved; the identity lock cannot make it live" "$rc" "2"

# a holder that would escape LOCKS_DIR is never used to build a path
shepherd_live w6:pOLD sess-old 'shepherd-1/../../etc/passwd' 2>/dev/null; rc=$?
assert_eq "a holder with a path segment is treated as gone, no file read" "$rc" "1"

# pair_live is the two-argument body, exported for the re-resolution
assert_ok   "pair_live: listed pair is live" pair_live w6:pNEW sess-new
assert_fail "pair_live: unlisted pair is gone" pair_live w6:pZZ sess-zz
unset SHEPHERD_LIVENESS_UNKNOWN
rm -f "$L"/shepherd-*.lock
export SHEPHERD_LIVENESS_OVERRIDE=""

# --- task_state ---
printf '# T-0001: x\nstate: working\nowner: shepherd-1\n' > "$SHEPHERD_ROOT/ledger/tasks/T-0001.md"
assert_eq "task_state reads the state field" "$(task_state T-0001)" "working"
assert_eq "task_state on a missing card prints nothing" "$(task_state T-9999)" ""


# --- card helpers (T-0221) ----------------------------------------------------
CARD="$SHEPHERD_ROOT/ledger/tasks/T-0500.md"
cat > "$CARD" <<'EOCARD'
# T-0500: helper fixture
state: queued
owner: shepherd-kelpie
project: karta~2
size: L   tier: heavy   budget: 240m
model: fable --effort high   # Saket said so
touch-areas: docs site, sidebar
parallel-safety: independent — wave 1 is done
pane: w1:p2   session: sess-abc
created: 2026-09-02T06:12

pane: w9:p9   session: sess-below

## Brief
EOCARD
assert_eq "card_field reads a line-start field"      "$(card_field "$CARD" state)" "queued"
assert_eq "card_field stops at a 3-space run"         "$(card_field "$CARD" pane)" "w1:p2"
assert_eq "card_field reads a mid-line field"         "$(card_field "$CARD" session)" "sess-abc"
assert_eq "card_field reads tier mid-line"            "$(card_field "$CARD" tier)" "heavy"
assert_eq "card_field reads budget mid-line"          "$(card_field "$CARD" budget)" "240m"
assert_eq "card_field drops a trailing comment"       "$(card_field "$CARD" model)" "fable --effort high"
assert_eq "card_field keeps a value with spaces"      "$(card_field "$CARD" parallel-safety)" "independent — wave 1 is done"
assert_fail "card_field exits 1 for an absent field"  card_field "$CARD" linear-session
assert_eq "card_field prints nothing for an absent field" "$(card_field "$CARD" linear-session)" ""
assert_eq "card_field stops at header boundary"       "$(card_field "$CARD" pane)" "w1:p2"
assert_eq "card_owner reads owner:"                   "$(card_owner "$CARD")" "shepherd-kelpie"
sed -i '/^owner:/d' "$CARD"
assert_eq "card_owner defaults to shepherd-1"         "$(card_owner "$CARD")" "shepherd-1"
CARD2="$SHEPHERD_ROOT/ledger/tasks/T-0501.md"
cat > "$CARD2" <<'EOCARD2'
# T-0501: title with   state: poisoned
state: queued
owner: shepherd-1
EOCARD2
assert_eq "card_field ignores title line poison"      "$(card_field "$CARD2" state)" "queued"
assert_fail "card_field does not read title-only fields" card_field "$CARD2" title
assert_eq "card_family strips ~N"                     "$(card_family karta~2)" "karta"
assert_eq "card_family keeps a base slug"             "$(card_family karta)" "karta"
SHEPHERD_NOW_OVERRIDE="2026-09-01T10:30:00+00:00"
assert_eq "card_log_time is HH:MM of now_iso"         "$(card_log_time)" "$(date -d 2026-09-01T10:30:00+00:00 +%H:%M)"
unset SHEPHERD_NOW_OVERRIDE

# --- card_kind (T-0240): build unless the card says reply ---------------------
K="$SHEPHERD_ROOT/kind.md"
printf '# T-0001: x\nstate: queued\nproject: p\n' >"$K"
assert_eq "card_kind: absent reads build" "$(card_kind "$K")" "build"
printf '# T-0001: x\nstate: queued\nproject: p\nkind:\n' >"$K"
assert_eq "card_kind: empty reads build" "$(card_kind "$K")" "build"
printf '# T-0001: x\nstate: queued\nproject: p\nkind: reply\n' >"$K"
assert_eq "card_kind: reply" "$(card_kind "$K")" "reply"
printf '# T-0001: x\nstate: queued\nproject: p\nkind: build   # a note\n' >"$K"
assert_eq "card_kind: a trailing comment is stripped" "$(card_kind "$K")" "build"

# --- the active-cards set (T-0253 item 3): one spelling for every script --------
# shepherd-preflight, shepherd-wake-report, shepherd-rollover and shepherd-lock each
# spelled the states that hold a lane lock and a worker slot; this is the home.
assert_eq "ACTIVE_STATES is the four between queued and the verdicts" "$ACTIVE_STATES" "briefed working blocked review"
A="$SHEPHERD_ROOT/ledger/tasks"; rm -f "$A"/T-*.md
i=0
for st in captured queued briefed working blocked review done failed abandoned; do
  i=$((i + 1)); printf '# T-%04d: x\nstate: %s\n' "$i" "$st" > "$A/T-$(printf '%04d' "$i").md"
done
printf 'reserved-by: shepherd-1 w6:p1 sess-1 now\n' > "$A/T-0010.md"
assert_eq "active_cards lists exactly the cards in those states, sorted" \
  "$(active_cards | xargs -n1 basename | tr '\n' ' ')" "T-0003.md T-0004.md T-0005.md T-0006.md "
for st in briefed working blocked review; do assert_ok "is_active_state $st" is_active_state "$st"; done
for st in captured queued done failed abandoned ""; do assert_fail "is_active_state '$st' is not" is_active_state "$st"; done
assert_fail "is_active_state matches a state exactly, never as a glob" is_active_state '*'
rm -f "$A"/T-*.md
assert_eq "active_cards prints nothing and exits 0 on an empty ledger" "$(active_cards; echo "rc=$?")" "rc=0"

finish
