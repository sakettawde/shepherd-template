#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
LOCK="$HERE/../bin/shepherd-lock"

echo "test-lock:"

assert_ok   "acquire a free lock"        bash "$LOCK" acquire project-karta shepherd-1 w6:p1 sess-1 T-0091
assert_file "lock file exists"           "$SHEPHERD_ROOT/ledger/locks/project-karta.lock"
assert_eq   "holder recorded"            "$(awk '{print $1}' "$SHEPHERD_ROOT/ledger/locks/project-karta.lock")" "shepherd-1"
assert_eq   "task recorded"              "$(awk '{print $4}' "$SHEPHERD_ROOT/ledger/locks/project-karta.lock")" "T-0091"
assert_eq   "five fields recorded"       "$(awk '{print NF}' "$SHEPHERD_ROOT/ledger/locks/project-karta.lock")" "5"

assert_fail "second acquire is refused"  bash "$LOCK" acquire project-karta shepherd-2 w6:p2 sess-2 T-0092
assert_eq   "holder unchanged"           "$(awk '{print $1}' "$SHEPHERD_ROOT/ledger/locks/project-karta.lock")" "shepherd-1"

assert_ok   "check reports held"         bash "$LOCK" check project-karta
assert_fail "release by wrong holder refused" bash "$LOCK" release project-karta shepherd-2
assert_file "lock survived wrong-holder release" "$SHEPHERD_ROOT/ledger/locks/project-karta.lock"

assert_ok   "release by owner"           bash "$LOCK" release project-karta shepherd-1
assert_nofile "lock file gone"           "$SHEPHERD_ROOT/ledger/locks/project-karta.lock"
assert_fail "check reports free"         bash "$LOCK" check project-karta
assert_ok   "release of a free lock is a no-op" bash "$LOCK" release project-karta shepherd-1

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
# Every skill passes "$SHEPHERD_ID", and the manual §0 documents unset as
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
# the manual §8 step 6, §4a and spec §10 step 3 all require taking over a
# project lock held by a gone instance. acquire returns HELD, release returns
# REFUSED, and sweep deliberately keeps the lock (orphan rule) - takeover is
# the only command that does it, and only on a gone holder.
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

# gone holder -> taken over by atomic rename
printf 'shepherd-1 w6:pGONE sess-gone T-0206 %s\n' "$(date -Iseconds)" > "$LK/to-gone.lock"
out=$(bash "$LOCK" takeover to-gone shepherd-2 w6:pME sess-me T-0207); rc=$?
assert_eq "takeover of a gone holder's lock succeeds" "$rc" "0"
assert_eq "and reports TOOK-OVER" "$(printf '%s' "$out" | grep -c '^TOOK-OVER to-gone')" "1"
assert_eq "the lock now names the new holder" "$(awk '{print $1, $2, $3, $4}' "$LK/to-gone.lock")" \
  "shepherd-2 w6:pME sess-me T-0207"
assert_eq "the lock is still exactly one line of five fields" \
  "$(awk 'END{print NR}' "$LK/to-gone.lock") $(awk '{print NF}' "$LK/to-gone.lock")" "1 5"
assert_eq "the rename left no temp file behind" \
  "$(find "$LK" -maxdepth 1 -name '.tmp.*' | wc -l)" "0"

# a takeover that would field-shift the line is refused like an acquire
out=$(bash "$LOCK" takeover to-gone "" w6:pME sess-me T-0208 2>&1); rc=$?
assert_eq "takeover validates its fields too" "$rc" "2"
assert_eq "and the previous takeover's line is untouched" "$(awk '{print $1}' "$LK/to-gone.lock")" "shepherd-2"

# the line changed during the liveness probe -> refused, never overwritten.
# Same racestub technique as test-reserve.sh: the probe IS the round-trip the
# race window depends on, so the stub rewrites the lock as a side effect of
# being asked about the holder's pane, then reports it gone.
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

# --- T-0217 §3: names are validated before any file is touched -------------
unset SHEPHERD_LIVENESS_OVERRIDE SHEPHERD_LIVENESS_UNKNOWN
export SHEPHERD_LIVENESS_OVERRIDE="w6:pME:sess-me"
E="$SHEPHERD_ROOT/ledger/events.log"
before_files=$(find "$SHEPHERD_ROOT" -type f | sort)
# The set of paths alone cannot catch an append to a file that already exists,
# and the events log exists by now - so snapshot its size too.
before_bytes=0; [ -f "$E" ] && before_bytes=$(wc -c < "$E")
for verb in acquire takeover; do
  out=$(bash "$LOCK" $verb 'bad/name' shepherd-2 w6:pME sess-me T-0300 2>&1); rc=$?
  assert_eq "$verb with a slash in the name exits 2" "$rc" "2"
  assert_eq "and $verb names the rule" "$(printf '%s' "$out" | grep -cF 'ERROR: name must match ^[A-Za-z0-9_][A-Za-z0-9_.~-]*$')" "1"
done
out=$(bash "$LOCK" release 'bad/name' shepherd-2 2>&1); rc=$?
assert_eq "release with a bad name exits 2" "$rc" "2"
out=$(bash "$LOCK" check '.tmp.sneaky' 2>&1); rc=$?
assert_eq "check with a leading-dot name exits 2" "$rc" "2"
out=$(bash "$LOCK" acquire 'has space' shepherd-2 w6:pME sess-me 2>&1); rc=$?
assert_eq "acquire with whitespace in the name exits 2" "$rc" "2"
assert_eq "nothing was written anywhere for a bad name, the events log included" \
  "$(find "$SHEPHERD_ROOT" -type f | sort)" "$before_files"
after_bytes=0; [ -f "$E" ] && after_bytes=$(wc -c < "$E")
assert_eq "and the events log did not grow by one byte" "$after_bytes" "$before_bytes"
assert_eq "no lock escaped LOCKS_DIR" "$(find "$SHEPHERD_ROOT" -name '*.lock' -not -path "$LK/*" | wc -l)" "0"
assert_ok "a clone-lane name with ~ is accepted" bash "$LOCK" acquire 'project-karta~2' shepherd-2 w6:pME sess-me T-0301
assert_ok "a reclaim name with . is accepted" bash "$LOCK" acquire 'shepherd-2.reclaim' shepherd-2 w6:pME sess-me

# --- T-0217 §2: every verb writes one events line, verdict = first printed word
rm -f "$E"
bash "$LOCK" acquire ev-1 shepherd-2 w6:pME sess-me T-0302 >/dev/null
assert_eq "acquire logs ACQUIRED with holder, verb, target, task" \
  "$(awk '{print $2, $3, $4, $5, $6}' "$E" | tail -1)" "shepherd-2 acquire ev-1 ACQUIRED T-0302"
bash "$LOCK" acquire ev-1 shepherd-3 w6:pX sess-x >/dev/null 2>&1
assert_eq "a refused acquire logs HELD under the caller's id" \
  "$(awk '{print $2, $3, $4, $5}' "$E" | tail -1)" "shepherd-3 acquire ev-1 HELD"
bash "$LOCK" release ev-1 shepherd-3 >/dev/null 2>&1
assert_eq "a refused release logs REFUSED" "$(awk '{print $2, $3, $4, $5}' "$E" | tail -1)" "shepherd-3 release ev-1 REFUSED"
bash "$LOCK" release ev-1 shepherd-2 >/dev/null
assert_eq "release logs RELEASED" "$(awk '{print $2, $3, $4, $5}' "$E" | tail -1)" "shepherd-2 release ev-1 RELEASED"
bash "$LOCK" release ev-1 shepherd-2 >/dev/null
assert_eq "release of a free lock logs FREE" "$(awk '{print $3, $4, $5}' "$E" | tail -1)" "release ev-1 FREE"
printf 'shepherd-1 w6:pGONE sess-gone T-0303 %s\n' "$(date -Iseconds)" > "$LK/ev-2.lock"
bash "$LOCK" takeover ev-2 shepherd-2 w6:pME sess-me T-0304 >/dev/null
assert_eq "takeover logs TOOK-OVER" "$(awk '{print $2, $3, $4, $5}' "$E" | tail -1)" "shepherd-2 takeover ev-2 TOOK-OVER"
bash "$LOCK" takeover ev-2 shepherd-3 w6:pX sess-x T-0305 >/dev/null 2>&1
assert_eq "a refused takeover logs REFUSED" "$(awk '{print $2, $3, $4, $5}' "$E" | tail -1)" "shepherd-3 takeover ev-2 REFUSED"
export SHEPHERD_LIVENESS_UNKNOWN="w6:pFOG:sess-fog"
printf 'shepherd-1 w6:pFOG sess-fog T-0306 %s\n' "$(date -Iseconds)" > "$LK/ev-3.lock"
bash "$LOCK" takeover ev-3 shepherd-2 w6:pME sess-me T-0307 >/dev/null 2>&1
assert_eq "an unresolved takeover logs UNKNOWN-LIVENESS" "$(awk '{print $3, $4, $5}' "$E" | tail -1)" "takeover ev-3 UNKNOWN-LIVENESS"
unset SHEPHERD_LIVENESS_UNKNOWN
printf '\n' > "$LK/ev-4.lock"
bash "$LOCK" takeover ev-4 shepherd-2 w6:pME sess-me >/dev/null 2>&1
assert_eq "a malformed takeover logs MALFORMED" "$(awk '{print $3, $4, $5}' "$E" | tail -1)" "takeover ev-4 MALFORMED"
bash "$LOCK" check ev-2 >/dev/null
assert_eq "check is read-only and logs nothing" "$(awk '{print $3}' "$E" | tail -1)" "takeover"
assert_eq "every events line has at least five columns" "$(awk 'NF < 5 {bad++} END{print bad+0}' "$E")" "0"

# --- T-0217 §4: release compares before it deletes ---------------------------
bash "$LOCK" acquire rel-1 shepherd-2 w6:pME sess-me T-0310 >/dev/null
out=$(bash "$LOCK" release rel-1 shepherd-2 w6:pOTHER sess-me 2>&1); rc=$?
assert_eq "four-arg release with a different pane is refused" "$rc" "1"
assert_eq "and says REFUSED" "$(printf '%s' "$out" | grep -c '^REFUSED rel-1')" "1"
assert_file "the lock survives a pane mismatch" "$LK/rel-1.lock"
out=$(bash "$LOCK" release rel-1 shepherd-2 w6:pME sess-other 2>&1); rc=$?
assert_eq "four-arg release with a different session is refused" "$rc" "1"
assert_file "the lock survives a session mismatch" "$LK/rel-1.lock"
assert_ok "four-arg release with the matching pane and session succeeds" bash "$LOCK" release rel-1 shepherd-2 w6:pME sess-me
assert_nofile "and deletes the lock" "$LK/rel-1.lock"
out=$(bash "$LOCK" release rel-1 shepherd-2 w6:pME 2>&1); rc=$?
assert_eq "three arguments is a usage error" "$rc" "2"

# A four-argument release ALWAYS compares. Gating the comparison on content
# ("$pane$session" non-empty) instead of arity let `release <name> <holder> "" ""`
# satisfy the dispatcher's four-argument form and then skip the comparison
# outright - deleting the very lock the caller passed the pair to guard.
bash "$LOCK" acquire rel-empty shepherd-2 w6:pME sess-me T-0312 >/dev/null
out=$(bash "$LOCK" release rel-empty shepherd-2 "" "" 2>&1); rc=$?
assert_eq "four-arg release with two empty strings still compares" "$rc" "1"
assert_eq "and says REFUSED" "$(printf '%s' "$out" | grep -c '^REFUSED rel-empty')" "1"
assert_file "the lock survives an empty-pair release" "$LK/rel-empty.lock"
assert_ok "a two-argument release of the same lock is unaffected" bash "$LOCK" release rel-empty shepherd-2
assert_nofile "and deletes it" "$LK/rel-empty.lock"

# An rm that fails must not print or log RELEASED. Unchecked, an unwritable
# locks directory produced an audit line asserting a release that never
# happened - the one claim an audit trail must never carry.
bash "$LOCK" acquire rel-ro shepherd-2 w6:pME sess-me T-0313 >/dev/null
chmod 500 "$LK"
out=$(bash "$LOCK" release rel-ro shepherd-2 2>&1); rc=$?
chmod 700 "$LK"
assert_eq "a release whose rm fails exits 2" "$rc" "2"
assert_eq "and reports ERROR" "$(printf '%s' "$out" | grep -c '^ERROR could not remove')" "1"
assert_eq "and never claims RELEASED" "$(printf '%s' "$out" | grep -c '^RELEASED')" "0"
assert_eq "and logs verdict ERROR" "$(awk '{print $3, $4, $5}' "$E" | tail -1)" "release rel-ro ERROR"
assert_file "and the lock is still there" "$LK/rel-ro.lock"

# The line changes between release's first read and its re-read. lock_line is
# the library's one reader for exactly this reason: a private copy of shepherd-lock
# + lib, with lock_line redefined to plant a rival's line on its second call,
# stands the race in the window. (Same technique as test-identity's race_copy.)
race_copy() {
  mkdir -p "$1/bin" "$1/lib"
  cp "$HERE/../bin/shepherd-lock" "$1/bin/shepherd-lock"
  cp "$HERE/../lib/shepherd-common.sh" "$1/lib/shepherd-common.sh"
}
race="$SHEPHERD_ROOT/race-release"; race_copy "$race"
cat >> "$race/lib/shepherd-common.sh" <<RACESTUB
lock_line() {
  local n
  n=\$(cat "$SHEPHERD_ROOT/ll.calls" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$SHEPHERD_ROOT/ll.calls"
  [ "\$n" -eq 2 ] && printf 'rival-shepherd w6:pRIVAL sess-rival T-0311 2027-01-01T00:00:00+00:00\n' > "\$1"
  head -1 "\$1" 2>/dev/null
  return 0
}
RACESTUB
printf 'shepherd-2 w6:pME sess-me T-0310 %s\n' "$(date -Iseconds)" > "$LK/rel-race.lock"
rm -f "$SHEPHERD_ROOT/ll.calls"
out=$(bash "$race/bin/shepherd-lock" release rel-race shepherd-2 2>&1); rc=$?
assert_eq "a lock whose line changed before the delete is refused" "$rc" "1"
assert_eq "and is reported CHANGED" "$(printf '%s' "$out" | grep -c '^CHANGED rel-race')" "1"
assert_eq "the rival's line survives untouched" "$(awk '{print $1}' "$LK/rel-race.lock")" "rival-shepherd"
assert_eq "the refusal is logged CHANGED" "$(awk '{print $3, $4, $5}' "$E" | tail -1)" "release rel-race CHANGED"

# --- T-0217 §6.4: shepherd-lock live <id> ------------------------------------------
export SHEPHERD_LIVENESS_OVERRIDE="w6:pA:sess-a w6:pC:sess-c-new"
export SHEPHERD_LIVENESS_UNKNOWN="w6:pB:sess-b"
export SHEPHERD_ID=shepherd-tester
rm -f "$E"
printf 'shepherd-alive w6:pA sess-a none %s\n' "$(date -Iseconds)" > "$LK/shepherd-alive.lock"
out=$(bash "$LOCK" live shepherd-alive); rc=$?
assert_eq "live: a live identity lock answers live" "$out" "live shepherd-alive w6:pA sess-a"
assert_eq "live: exit 0" "$rc" "0"
printf 'shepherd-fog w6:pB sess-b none %s\n' "$(date -Iseconds)" > "$LK/shepherd-fog.lock"
out=$(bash "$LOCK" live shepherd-fog); rc=$?
assert_eq "live: an unresolved identity pair answers unresolved" "$out" "unresolved shepherd-fog w6:pB sess-b"
assert_eq "live: exit 2" "$rc" "2"
printf 'shepherd-dead w6:pD sess-d none %s\n' "$(date -Iseconds)" > "$LK/shepherd-dead.lock"
out=$(bash "$LOCK" live shepherd-dead); rc=$?
assert_eq "live: a gone identity pair answers gone" "$out" "gone shepherd-dead w6:pD sess-d"
assert_eq "live: exit 1" "$rc" "1"
out=$(bash "$LOCK" live shepherd-never); rc=$?
assert_eq "live: no identity lock answers gone with - -" "$out" "gone shepherd-never - -"
assert_eq "live: no identity lock exits 1" "$rc" "1"
printf 'onlyholder\n' > "$LK/shepherd-broken.lock"
out=$(bash "$LOCK" live shepherd-broken); rc=$?
assert_eq "live: a malformed identity lock answers unresolved" "$out" "unresolved shepherd-broken - -"
assert_eq "live: malformed exits 2" "$rc" "2"
# A zero-byte identity lock is the truncated-write state, and it takes the
# other branch: the file exists, so `live` reads it, but lock_line returns
# nothing and `read` never runs. Only the h_holder/h_pane/h_session
# pre-initialisation keeps this arm answerable - without it the emptiness
# test reads locals that were declared and never assigned, and `set -u`
# aborts mid-answer. The short-line case above never reaches it: `read` runs
# there, so the names are always assigned.
: > "$LK/shepherd-empty.lock"
out=$(bash "$LOCK" live shepherd-empty); rc=$?
assert_eq "live: an empty identity lock answers unresolved" "$out" "unresolved shepherd-empty - -"
assert_eq "live: empty exits 2" "$rc" "2"
out=$(bash "$LOCK" live 'not-a-shepherd' 2>"$SHEPHERD_ROOT/live.err"); rc=$?
assert_eq "live: a bad id prints nothing on stdout" "$out" ""
assert_eq "live: a bad id exits 2" "$rc" "2"
assert_eq "live: a bad id names the rule on stderr" "$(grep -c '^ERROR: bad shepherd id: ' "$SHEPHERD_ROOT/live.err")" "1"
assert_eq "live: every answer is logged under verb live" \
  "$(awk '$3 == "live" {print $2, $4, $5}' "$E" | tr '\n' ';')" \
  "shepherd-tester shepherd-alive live;shepherd-tester shepherd-fog unresolved;shepherd-tester shepherd-dead gone;shepherd-tester shepherd-never gone;shepherd-tester shepherd-broken unresolved;shepherd-tester shepherd-empty unresolved;"
unset SHEPHERD_LIVENESS_UNKNOWN SHEPHERD_ID

# --- T-0217 §7: shepherd-lock stats counts verb+verdict from the events log --------
rm -f "$E"
out=$(bash "$LOCK" stats); rc=$?
assert_eq "stats on no log exits 0" "$rc" "0"
assert_eq "stats on no log says so" "$(printf '%s' "$out" | grep -c '^no events yet')" "1"
cat > "$E" <<'LOG'
2026-09-02T06:00:00+00:00 shepherd-a sweep card-x SWEPT (holder shepherd-b gone)
2026-09-02T06:00:00+00:00 shepherd-a sweep card-y SWEPT
2026-09-02T06:00:01+00:00 shepherd-a sweep project-z ORPHAN T-0100 state=working
2026-09-02T06:00:02+00:00 shepherd-b acquire dispatch ACQUIRED none
2026-09-02T06:00:03+00:00 shepherd-b release dispatch RELEASED
2026-09-02T06:00:04+00:00 - sweep - SWEEP-SKIPPED liveness oracle unavailable
LOG
out=$(bash "$LOCK" stats)
assert_eq "stats prints count verb verdict, sorted by verb then verdict" "$out" \
"1 acquire ACQUIRED
1 release RELEASED
1 sweep ORPHAN
1 sweep SWEEP-SKIPPED
2 sweep SWEPT"
assert_eq "the usage text documents the same count as a one-liner" \
  "$(grep -c "^#.*awk '{c\[\$3\" \"\$5\]++}" "$LOCK")" "1"
assert_eq "the one-liner's awk over the whole log agrees with stats (the documented form adds the month grep)" \
  "$(awk '{c[$3" "$5]++} END{for(k in c) print c[k], k}' "$E" | sort -k2 | tr '\n' ';')" \
  "$(bash "$LOCK" stats | tr '\n' ';')"
rm -f "$E"

finish
