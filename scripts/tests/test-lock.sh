#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
LOCK="$HERE/../lock.sh"

echo "test-lock:"

assert_ok   "acquire a free lock"        bash "$LOCK" acquire project-alpha shepherd-1 w6:p1 sess-1 T-0091
assert_file "lock file exists"           "$SHEPHERD_ROOT/ledger/locks/project-alpha.lock"
assert_eq   "holder recorded"            "$(awk '{print $1}' "$SHEPHERD_ROOT/ledger/locks/project-alpha.lock")" "shepherd-1"
assert_eq   "task recorded"              "$(awk '{print $4}' "$SHEPHERD_ROOT/ledger/locks/project-alpha.lock")" "T-0091"
assert_eq   "five fields recorded"       "$(awk '{print NF}' "$SHEPHERD_ROOT/ledger/locks/project-alpha.lock")" "5"

assert_fail "second acquire is refused"  bash "$LOCK" acquire project-alpha shepherd-2 w6:p2 sess-2 T-0092
assert_eq   "holder unchanged"           "$(awk '{print $1}' "$SHEPHERD_ROOT/ledger/locks/project-alpha.lock")" "shepherd-1"

assert_ok   "check reports held"         bash "$LOCK" check project-alpha
assert_fail "release by wrong holder refused" bash "$LOCK" release project-alpha shepherd-2
assert_file "lock survived wrong-holder release" "$SHEPHERD_ROOT/ledger/locks/project-alpha.lock"

assert_ok   "release by owner"           bash "$LOCK" release project-alpha shepherd-1
assert_nofile "lock file gone"           "$SHEPHERD_ROOT/ledger/locks/project-alpha.lock"
assert_fail "check reports free"         bash "$LOCK" check project-alpha
assert_ok   "release of a free lock is a no-op" bash "$LOCK" release project-alpha shepherd-1

# task defaults to none
bash "$LOCK" acquire dispatch shepherd-1 w6:p1 sess-1 >/dev/null
assert_eq   "task defaults to none"      "$(awk '{print $4}' "$SHEPHERD_ROOT/ledger/locks/dispatch.lock")" "none"

# contention: 50 racers, exactly one winner
rm -f "$SHEPHERD_ROOT/ledger/locks/race.lock"
won=0
for i in $(seq 1 50); do
  ( bash "$LOCK" acquire race "shepherd-$i" "w6:p$i" "sess-$i" none >/dev/null 2>&1 && echo won > "$SHEPHERD_ROOT/won.$i" ) &
done
wait
won=$(find "$SHEPHERD_ROOT" -maxdepth 1 -name 'won.*' | wc -l)
assert_eq "exactly one racer acquired the lock" "$won" "1"

# a lock whose content cannot be parsed is reported free and is NOT deleted
printf '\n' > "$SHEPHERD_ROOT/ledger/locks/corrupt.lock"
assert_ok   "release reports a malformed lock as free" bash "$LOCK" release corrupt shepherd-1
assert_file "release does not delete a lock it cannot prove ownership of" \
  "$SHEPHERD_ROOT/ledger/locks/corrupt.lock"

# an empty holder argument must not be able to claim a malformed lock
assert_ok   "release with an empty holder is still free, not a deletion" bash "$LOCK" release corrupt ""
assert_file "malformed lock still present after an empty-holder release" \
  "$SHEPHERD_ROOT/ledger/locks/corrupt.lock"

# --- acquire validates its fields -------------------------------------------
# Every skill passes "$SHEPHERD_ID", and CLAUDE.md §0 documents unset as
# meaning shepherd-1 - so an empty holder is a real default state, not an
# abuse case. Unvalidated it wrote " w6:p1 sess-1 T-0091 <ts>", which
# `read -r holder pane session task ts` parses with every field shifted one
# left: the owner can never release it (release compares field 1) and sweep
# reads the timestamp as the task id, finds no such card, and deletes a
# project lock over a state: working task - admitting a second worker to the
# same checkout. These assertions go red the moment that guard is removed.
LK="$SHEPHERD_ROOT/ledger/locks"

out=$(bash "$LOCK" acquire validate-empty "" w6:p1 sess-1 T-0091 2>&1); rc=$?
assert_eq   "acquire with an empty holder returns 2" "$rc" "2"
assert_eq   "and names the offending argument" "$(printf '%s' "$out" | grep -c '^ERROR: holder ')" "1"
assert_nofile "no lock file is created for an empty holder" "$LK/validate-empty.lock"

out=$(bash "$LOCK" acquire validate-space "shepherd 1" w6:p1 sess-1 T-0091 2>&1); rc=$?
assert_eq   "acquire with whitespace in the holder returns 2" "$rc" "2"
assert_eq   "and names the offending argument" "$(printf '%s' "$out" | grep -c '^ERROR: holder ')" "1"
assert_nofile "no lock file is created for a whitespace holder" "$LK/validate-space.lock"

out=$(bash "$LOCK" acquire validate-pane shepherd-1 "" sess-1 T-0091 2>&1); rc=$?
assert_eq   "acquire with an empty pane returns 2" "$rc" "2"
assert_eq   "and names pane as the offender" "$(printf '%s' "$out" | grep -c '^ERROR: pane ')" "1"
assert_nofile "no lock file is created for an empty pane" "$LK/validate-pane.lock"

out=$(bash "$LOCK" acquire validate-sess shepherd-1 w6:p1 "" T-0091 2>&1); rc=$?
assert_eq   "acquire with an empty session returns 2" "$rc" "2"
assert_eq   "and names session as the offender" "$(printf '%s' "$out" | grep -c '^ERROR: session ')" "1"
assert_nofile "no lock file is created for an empty session" "$LK/validate-sess.lock"

out=$(bash "$LOCK" acquire validate-task shepherd-1 w6:p1 sess-1 "T 0091" 2>&1); rc=$?
assert_eq   "acquire with whitespace in the task returns 2" "$rc" "2"
assert_nofile "no lock file is created for a whitespace task" "$LK/validate-task.lock"

# an omitted task is still the documented default, not a validation failure
assert_ok "a valid acquire with no task argument still succeeds" \
  bash "$LOCK" acquire validate-ok shepherd-1 w6:p1 sess-1
assert_eq "and records five fields" "$(awk '{print NF}' "$LK/validate-ok.lock")" "5"

# --- takeover ---------------------------------------------------------------
# CLAUDE.md §8 step 6, §4a and spec §10 step 3 all require taking over a
# project lock held by a dead instance. acquire returns HELD, release returns
# REFUSED, and sweep deliberately keeps the lock (orphan rule) - takeover is
# the only command that does it, and only on a definitively-dead holder.
export SHEPHERD_LIVENESS_OVERRIDE="w6:pLIVE:sess-live w6:pME:sess-me"

# no lock at all -> plain acquire
out=$(bash "$LOCK" takeover to-fresh shepherd-2 w6:pME sess-me T-0200); rc=$?
assert_eq   "takeover of an unheld lock succeeds" "$rc" "0"
assert_eq   "and reports it as an acquire" "$(printf '%s' "$out" | grep -c '^ACQUIRED to-fresh')" "1"
assert_eq   "with the caller as holder" "$(awk '{print $1}' "$LK/to-fresh.lock")" "shepherd-2"

# live holder -> refused
printf 'shepherd-1 w6:pLIVE sess-live T-0201 %s\n' "$(date -Iseconds)" > "$LK/to-live.lock"
out=$(bash "$LOCK" takeover to-live shepherd-2 w6:pME sess-me T-0202 2>&1); rc=$?
assert_eq "takeover of a live holder's lock is refused" "$rc" "1"
assert_eq "and says the holder is live" "$(printf '%s' "$out" | grep -c '^REFUSED to-live is held by a live instance')" "1"
assert_eq "the live holder keeps the lock" "$(awk '{print $2}' "$LK/to-live.lock")" "w6:pLIVE"

# unresolvable liveness -> refused, with a distinct message
export SHEPHERD_LIVENESS_UNKNOWN="w6:pFOG:sess-fog"
printf 'shepherd-1 w6:pFOG sess-fog T-0203 %s\n' "$(date -Iseconds)" > "$LK/to-fog.lock"
out=$(bash "$LOCK" takeover to-fog shepherd-2 w6:pME sess-me T-0204 2>&1); rc=$?
assert_eq "takeover on unresolvable liveness is refused" "$rc" "1"
assert_eq "and is reported as UNKNOWN-LIVENESS, not as a live holder" \
  "$(printf '%s' "$out" | grep -c '^UNKNOWN-LIVENESS to-fog')" "1"
assert_eq "the unresolved holder keeps the lock" "$(awk '{print $2}' "$LK/to-fog.lock")" "w6:pFOG"
unset SHEPHERD_LIVENESS_UNKNOWN

# malformed line -> refused, never stolen
printf '\n' > "$LK/to-bad.lock"
out=$(bash "$LOCK" takeover to-bad shepherd-2 w6:pME sess-me T-0205 2>&1); rc=$?
assert_eq "takeover of a malformed lock is refused" "$rc" "1"
assert_eq "and is reported MALFORMED" "$(printf '%s' "$out" | grep -c '^MALFORMED to-bad')" "1"
assert_file "the malformed lock is left in place" "$LK/to-bad.lock"

# definitively dead holder -> taken over by atomic rename
printf 'shepherd-1 w6:pDEAD sess-dead T-0206 %s\n' "$(date -Iseconds)" > "$LK/to-dead.lock"
out=$(bash "$LOCK" takeover to-dead shepherd-2 w6:pME sess-me T-0207); rc=$?
assert_eq "takeover of a dead holder's lock succeeds" "$rc" "0"
assert_eq "and reports TOOK-OVER" "$(printf '%s' "$out" | grep -c '^TOOK-OVER to-dead')" "1"
assert_eq "the lock now names the new holder" "$(awk '{print $1, $2, $3, $4}' "$LK/to-dead.lock")" \
  "shepherd-2 w6:pME sess-me T-0207"
assert_eq "the lock is still exactly one line of five fields" \
  "$(awk 'END{print NR}' "$LK/to-dead.lock") $(awk '{print NF}' "$LK/to-dead.lock")" "1 5"
assert_eq "the rename left no temp file behind" \
  "$(find "$LK" -maxdepth 1 -name '.tmp.*' | wc -l)" "0"

# a takeover that would field-shift the line is refused like an acquire
out=$(bash "$LOCK" takeover to-dead "" w6:pME sess-me T-0208 2>&1); rc=$?
assert_eq "takeover validates its fields too" "$rc" "2"
assert_eq "and the previous takeover's line is untouched" "$(awk '{print $1}' "$LK/to-dead.lock")" "shepherd-2"

# the line changed during the liveness probe -> refused, never overwritten.
# Same racestub technique as test-reserve.sh: the probe IS the round-trip the
# race window depends on, so the stub rewrites the lock as a side effect of
# being asked about the holder's pane, then reports it dead.
unset SHEPHERD_LIVENESS_OVERRIDE SHEPHERD_LIVENESS_UNKNOWN
printf 'shepherd-1 w6:pRACE sess-race T-0209 %s\n' "$(date -Iseconds)" > "$LK/to-race.lock"
racestub="$SHEPHERD_ROOT/racestub"; mkdir -p "$racestub"
cat > "$racestub/herdr" <<STUB
#!/bin/sh
case "\$3" in
  w6:pRACE)
    printf 'rival-shepherd w6:pRIVAL sess-rival T-0210 2027-01-01T00:00:00+00:00\n' > "$LK/to-race.lock"
    echo '{"error":{"code":"pane_not_found","message":"pane w6:pRACE not found"},"id":"cli:pane:get"}' >&2
    exit 1
    ;;
esac
STUB
chmod +x "$racestub/herdr"
out=$( PATH="$racestub:$PATH" bash "$LOCK" takeover to-race shepherd-2 w6:pME sess-me T-0211 2>&1 ); rc=$?
assert_eq "a lock that changed during the probe is refused" "$rc" "1"
assert_eq "and is reported CHANGED" "$(printf '%s' "$out" | grep -c '^CHANGED to-race')" "1"
assert_eq "the racing instance's claim survives untouched" \
  "$(awk '{print $1}' "$LK/to-race.lock")" "rival-shepherd"

finish
