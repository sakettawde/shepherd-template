#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
LOCK="$HERE/../bin/shepherd-lock"
L="$SHEPHERD_ROOT/ledger/locks"
T="$SHEPHERD_ROOT/ledger/tasks"

echo "test-sweep:"

card() { printf '# %s: x\nstate: %s\nowner: shepherd-9\n' "$1" "$2" > "$T/$1.md"; }
mklock() { printf '%s %s %s %s %s\n' "$2" "$3" "$4" "$5" "$6" > "$L/$1.lock"; }

# shepherd-1 is live in w6:p1; shepherd-9 is gone.
export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1"

card T-0100 working
card T-0101 done
card T-0102 queued
card T-0103 captured
card T-0104 done
# The orphan rule protects four states, not one. Fixturing only `working`
# let a narrowing of shepherd-lock's arm to `working)` ship green - a regression
# that frees a project lock during the briefed or review window, both of
# which have a live worker in the checkout.
card T-0105 briefed
card T-0106 review

mklock project-karta       shepherd-9 w6:p9 sess-9 T-0100 "$(date -Iseconds)"
mklock project-eo-tech     shepherd-9 w6:p9 sess-9 T-0101 "$(date -Iseconds)"
mklock project-ip-landing  shepherd-9 w6:p9 sess-9 T-0102 "$(date -Iseconds)"
mklock project-captured    shepherd-9 w6:p9 sess-9 T-0103 "$(date -Iseconds)"
mklock project-teacher     shepherd-9 w6:p9 sess-9 none   "$(date -Iseconds)"
mklock card-karta          shepherd-9 w6:p9 sess-9 none   "$(date -Iseconds)"
mklock dispatch            shepherd-9 w6:p9 sess-9 none   "$(date -Iseconds)"
mklock shepherd-9          shepherd-9 w6:p9 sess-9 none   "$(date -Iseconds)"
mklock project-live        shepherd-1 w6:p1 sess-1 T-0100 "$(date -Iseconds)"
mklock project-livedone    shepherd-1 w6:p1 sess-1 T-0104 "$(date -Iseconds)"
mklock card-old            shepherd-1 w6:p1 sess-1 none   "$(date -Iseconds -d '30 minutes ago')"
mklock unknown-xyz         shepherd-9 w6:p9 sess-9 none   "$(date -Iseconds)"
mklock project-unknown     shepherd-7 w6:p7 sess-7 none   "$(date -Iseconds)"
mklock card-unknown        shepherd-7 w6:p7 sess-7 none   "$(date -Iseconds)"
mklock project-briefed     shepherd-9 w6:p9 sess-9 T-0105 "$(date -Iseconds)"
mklock project-review      shepherd-9 w6:p9 sess-9 T-0106 "$(date -Iseconds)"
# A lock whose line cannot be parsed must be reported and left alone. Named
# card-* deliberately: that arm deletes unconditionally once the holder is
# gone, so removing the MALFORMED guard both loses the report and unlinks
# the file - a lock nobody can account for, gone without a trace.
printf '\n' > "$L/card-malformed.lock"
# A SHORT line over a LIVE holder. `read` leaves session empty, shepherd_live
# compares the live pane's session id against "" and answers gone, and sweep
# unlinks the project lock of a running instance - the one failure the whole
# multi-instance design exists to prevent, reported as a routine SWEPT line.
# takeover, shepherd-identity acquire/touch and reserve-task-id sweep all
# already refuse this input; sweep is the one that mass-deletes.
printf 'shepherd-1 w6:p1\n' > "$L/project-live-truncated.lock"

# the oracle pre-flight: with no override and no pane, sweep must do nothing
before=$(ls "$L" | wc -l)
out_skip=$( unset SHEPHERD_LIVENESS_OVERRIDE HERDR_PANE_ID; bash "$LOCK" sweep )
assert_eq "sweep skips when the liveness oracle cannot answer" \
  "$(printf '%s' "$out_skip" | grep -c '^SWEEP-SKIPPED')" "1"
assert_eq "and deletes nothing" "$(ls "$L" | wc -l)" "$before"

# shepherd-7's liveness is unresolved: both lock kinds must be left in
# place, not deleted - "unresolved" must never collapse into "gone".
export SHEPHERD_LIVENESS_UNKNOWN="w6:p7:sess-7"

# Now run the main sweep with liveness override
out=$(bash "$LOCK" sweep)

assert_file   "active task keeps its stale project lock" "$L/project-karta.lock"
assert_eq     "and is reported as an orphan" "$(printf '%s' "$out" | grep -c '^ORPHAN project-karta T-0100 state=working')" "1"
assert_nofile "closed task frees its project lock"  "$L/project-eo-tech.lock"
assert_nofile "queued task frees its project lock"  "$L/project-ip-landing.lock"
assert_nofile "captured task frees its project lock"  "$L/project-captured.lock"
assert_nofile "taskless project lock is freed"      "$L/project-teacher.lock"
assert_nofile "stale card lock is freed"            "$L/card-karta.lock"
assert_nofile "stale dispatch lock is freed"        "$L/dispatch.lock"
assert_nofile "stale identity lock is freed"        "$L/shepherd-9.lock"
assert_file   "live holder's project lock over a closed task is untouched" "$L/project-livedone.lock"
assert_eq     "long-held live card lock is reported" "$(printf '%s' "$out" | grep -c '^LONG-HELD card-old shepherd-1')" "1"
assert_file   "long-held live lock is NOT stolen"   "$L/card-old.lock"
assert_eq     "SWEPT lines are printed" "$(printf '%s' "$out" | grep -c '^SWEPT ')" "7"
assert_file   "unknown-lock name is left in place" "$L/unknown-xyz.lock"
assert_eq     "unknown-lock name is reported" "$(printf '%s' "$out" | grep -c '^UNKNOWN-LOCK unknown-xyz')" "1"
assert_file   "project lock with unresolvable liveness is not deleted" "$L/project-unknown.lock"
assert_eq     "project lock with unresolvable liveness is reported" \
  "$(printf '%s' "$out" | grep -c '^UNKNOWN-LIVENESS project-unknown shepherd-7')" "1"
assert_file   "card lock with unresolvable liveness is not deleted (old code deleted it outright)" "$L/card-unknown.lock"
assert_eq     "card lock with unresolvable liveness is reported" \
  "$(printf '%s' "$out" | grep -c '^UNKNOWN-LIVENESS card-unknown shepherd-7')" "1"
assert_file   "briefed task keeps its stale project lock" "$L/project-briefed.lock"
assert_eq     "and the briefed orphan is reported" \
  "$(printf '%s' "$out" | grep -c '^ORPHAN project-briefed T-0105 state=briefed')" "1"
assert_file   "review task keeps its stale project lock" "$L/project-review.lock"
assert_eq     "and the review orphan is reported" \
  "$(printf '%s' "$out" | grep -c '^ORPHAN project-review T-0106 state=review')" "1"
assert_file   "unparseable lock is left in place"   "$L/card-malformed.lock"
assert_eq     "unparseable lock is reported MALFORMED" \
  "$(printf '%s' "$out" | grep -c '^MALFORMED card-malformed')" "1"
assert_file   "short lock line over a LIVE holder is not deleted" "$L/project-live-truncated.lock"
assert_eq     "short lock line is reported MALFORMED" \
  "$(printf '%s' "$out" | grep -c '^MALFORMED project-live-truncated')" "1"
# The fixture still holds MALFORMED, UNKNOWN-LOCK and UNKNOWN-LIVENESS locks,
# each of which needs a human. Exit 3 is that fact, reported honestly (T-0217 §5).
bash "$LOCK" sweep >/dev/null; rc=$?
assert_eq    "sweep exits 3 while human-needed lines remain" "$rc" "3"

# --- the CHANGED re-verify. Sweep's liveness probe is a herdr round-trip;
# another instance can sweep the same lock and re-acquire the name while we
# wait, and deleting on that stale read unlinks a LIVE holder's claim. The
# guard was previously untested - deleting the whole block left the suite
# green. Same racestub technique as test-reserve.sh: the stub rewrites the
# lock file as a side effect of being asked about the holder's pane, because
# that probe IS the round-trip the race window depends on. It answers for our
# own pane too, or sweep's oracle pre-flight would skip everything.
rm -f "$L"/*.lock
printf 'shepherd-6 w6:p6 sess-6 none %s\n' "$(date -Iseconds)" > "$L/card-race.lock"
racestub="$SHEPHERD_ROOT/racestub"; mkdir -p "$racestub"
cat > "$racestub/herdr" <<STUB
#!/bin/sh
case "\$3" in
  w6:pOWN)
    echo '{"result":{"pane":{"agent_session":{"value":"sess-own"}}},"id":"cli:pane:get"}'
    ;;
  w6:p6)
    printf 'shepherd-6-new w6:p6new sess-6new none 2027-01-01T00:00:00+00:00\n' > "$L/card-race.lock"
    echo '{"error":{"code":"pane_not_found","message":"pane w6:p6 not found"},"id":"cli:pane:get"}' >&2
    exit 1
    ;;
esac
STUB
chmod +x "$racestub/herdr"
out_race=$(
  unset SHEPHERD_LIVENESS_OVERRIDE SHEPHERD_LIVENESS_UNKNOWN
  PATH="$racestub:$PATH" HERDR_PANE_ID=w6:pOWN bash "$LOCK" sweep
)
assert_file "a lock re-acquired during the probe is left alone, not deleted" "$L/card-race.lock"
assert_eq   "and is reported CHANGED" \
  "$(printf '%s' "$out_race" | grep -c '^CHANGED card-race - re-acquired during the liveness probe, left alone')" "1"
assert_eq   "the racing instance's new claim survives untouched" \
  "$(awk '{print $1}' "$L/card-race.lock")" "shepherd-6-new"

# --- hooks_active gate: with SHEPHERD_TEST_HOOKS unset, SHEPHERD_LIVENESS_*
# being set to something hostile must NOT bypass the real "herdr
# unreachable" pre-flight - sweep must still skip and delete nothing. This
# is what leaking one of these variables into a live shepherd's shell,
# during a genuine herdr outage, would otherwise do to every lock in the
# system. HERDR_PANE_ID names a pane that cannot exist, standing in for
# "herdr cannot vouch for us" without depending on the real server's
# reachability at test time.
before_hostile=$(ls "$L" | wc -l)
out_hostile=$(
  unset SHEPHERD_TEST_HOOKS
  export HERDR_PANE_ID=w6:pTESTHOSTILE999
  export SHEPHERD_PANE_SESSION_OVERRIDE=sess-fake
  export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1 w6:p9:sess-9 w6:p7:sess-7"
  export SHEPHERD_LIVENESS_UNKNOWN=""
  bash "$LOCK" sweep
)
assert_eq "hooks are inert without SHEPHERD_TEST_HOOKS: sweep still skips" \
  "$(printf '%s' "$out_hostile" | grep -c '^SWEEP-SKIPPED')" "1"
assert_eq "and deletes nothing" "$(ls "$L" | wc -l)" "$before_hostile"

# --- T-0217 §5: exit codes, one kind at a time --------------------------------
E="$SHEPHERD_ROOT/ledger/events.log"
export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1"
unset SHEPHERD_LIVENESS_UNKNOWN
reset_locks() { rm -f "$L"/*.lock "$T"/T-*.md; }

reset_locks
card T-0100 working
mklock project-karta shepherd-9 w6:p9 sess-9 T-0100 "$(date -Iseconds)"      # ORPHAN
mklock card-old      shepherd-1 w6:p1 sess-1 none   "$(date -Iseconds -d '30 minutes ago')"  # LONG-HELD
mklock card-stale    shepherd-9 w6:p9 sess-9 none   "$(date -Iseconds)"      # SWEPT
out=$(bash "$LOCK" sweep); rc=$?
assert_eq "a routine run (SWEPT, ORPHAN, LONG-HELD) exits 0" "$rc" "0"
assert_eq "and still prints its three verdicts" \
  "$(printf '%s\n' "$out" | grep -cE '^(SWEPT|ORPHAN|LONG-HELD) ')" "3"

reset_locks; printf '\n' > "$L/card-bad.lock"
bash "$LOCK" sweep >/dev/null; rc=$?
assert_eq "MALFORMED alone exits 3" "$rc" "3"

reset_locks; mklock unknown-kind shepherd-9 w6:p9 sess-9 none "$(date -Iseconds)"
bash "$LOCK" sweep >/dev/null; rc=$?
assert_eq "UNKNOWN-LOCK alone exits 3" "$rc" "3"

reset_locks; mklock project-fog shepherd-7 w6:p7 sess-7 none "$(date -Iseconds)"
export SHEPHERD_LIVENESS_UNKNOWN="w6:p7:sess-7"
bash "$LOCK" sweep >/dev/null; rc=$?
assert_eq "UNKNOWN-LIVENESS alone exits 3" "$rc" "3"
unset SHEPHERD_LIVENESS_UNKNOWN

reset_locks; mklock card-x shepherd-9 w6:p9 sess-9 none "$(date -Iseconds)"
( unset SHEPHERD_LIVENESS_OVERRIDE HERDR_PANE_ID; bash "$LOCK" sweep >/dev/null ); rc=$?
assert_eq "SWEEP-SKIPPED exits 3" "$rc" "3"
assert_file "and inspected nothing" "$L/card-x.lock"

reset_locks
bash "$LOCK" sweep >/dev/null; rc=$?
assert_eq "an empty locks dir exits 0" "$rc" "0"

# --- T-0217 §5: --dry-run prints every verdict and changes nothing -----------
reset_locks
card T-0100 working
card T-0101 done
mklock project-karta   shepherd-9 w6:p9 sess-9 T-0100 "$(date -Iseconds)"   # ORPHAN
mklock project-eo-tech shepherd-9 w6:p9 sess-9 T-0101 "$(date -Iseconds)"   # would be SWEPT
mklock card-stale      shepherd-9 w6:p9 sess-9 none   "$(date -Iseconds)"   # would be SWEPT
mklock unknown-kind    shepherd-9 w6:p9 sess-9 none   "$(date -Iseconds)"   # UNKNOWN-LOCK
printf '\n' > "$L/card-bad.lock"                                             # MALFORMED
touch -d '2 hours ago' "$L/.tmp.old"
rm -f "$E"
before=$(find "$L" -type f | sort | xargs -r md5sum)
out=$(bash "$LOCK" sweep --dry-run); rc=$?
assert_eq "dry run announces itself first" "$(printf '%s\n' "$out" | head -1)" "DRY-RUN no changes will be made"
assert_eq "dry run prints the SWEPT lines it would act on" "$(printf '%s\n' "$out" | grep -c '^SWEPT ')" "2"
assert_eq "dry run prints ORPHAN" "$(printf '%s\n' "$out" | grep -c '^ORPHAN project-karta')" "1"
assert_eq "dry run prints UNKNOWN-LOCK" "$(printf '%s\n' "$out" | grep -c '^UNKNOWN-LOCK unknown-kind')" "1"
assert_eq "dry run prints MALFORMED" "$(printf '%s\n' "$out" | grep -c '^MALFORMED card-bad')" "1"
assert_eq "dry run exit code follows the same rule (3 here)" "$rc" "3"
assert_eq "dry run changed no file, deleted no lock, cleaned no temp file" \
  "$(find "$L" -type f | sort | xargs -r md5sum)" "$before"
assert_nofile "dry run wrote no events" "$E"
out=$(bash "$LOCK" sweep --bogus 2>&1); rc=$?
assert_eq "an unknown sweep flag is a usage error" "$rc" "2"

# --- T-0217 §2: every real verdict is one events line, verdict = first word --
# Both instance-column cases are pinned rather than read from the ambient
# shell: this run has SHEPHERD_ID unset and proves the `-` fallback, the run
# below sets it and proves the id is actually carried. Comparing against
# "${SHEPHERD_ID:--}" proved only whichever case the operator's shell was in.
out=$( unset SHEPHERD_ID; bash "$LOCK" sweep ); rc=$?
assert_file "the real sweep wrote events" "$E"
assert_eq "one events line per printed verdict" \
  "$(wc -l < "$E")" "$(printf '%s\n' "$out" | grep -c .)"
assert_eq "events carry verb sweep and the verdict word" \
  "$(awk '$3 == "sweep" {print $5}' "$E" | sort | tr '\n' ' ')" "MALFORMED ORPHAN SWEPT SWEPT UNKNOWN-LOCK "
assert_eq "events name - as the instance when SHEPHERD_ID is unset" \
  "$(awk '{print $2}' "$E" | sort -u)" "-"
rm -f "$E"
# shepherd-7 sweeps locks whose holder is shepherd-9. The ids must differ, or
# the assertion cannot tell "column 2 is the sweeping instance" from "column 2
# is the lock's holder" - the sweep verb logs the actor, not the holder.
SHEPHERD_ID=shepherd-7 bash "$LOCK" sweep >/dev/null
assert_file "a sweep run under a shepherd id wrote events" "$E"
assert_eq "and every one of its lines names that instance" \
  "$(awk '{print $2}' "$E" | sort -u)" "shepherd-7"
rm -f "$E"
( unset SHEPHERD_LIVENESS_OVERRIDE HERDR_PANE_ID; bash "$LOCK" sweep >/dev/null )
assert_eq "SWEEP-SKIPPED is logged with target -" "$(awk '{print $3, $4, $5}' "$E")" "sweep - SWEEP-SKIPPED"

# --- T-0217 §6.2: a rolled-over holder's project lock survives the sweep -----
# shepherd-roll's project lock still names its pre-rollover pair (w6:pR,
# sess-old). Its identity lock, re-acquired at wake step 2, names the live
# pair (w6:pR, sess-new). Before: ORPHAN at best, SWEPT at worst. Now: live.
reset_locks; rm -f "$E"
card T-0102 queued
export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1 w6:pR:sess-new"
mklock shepherd-roll   shepherd-roll w6:pR sess-new none   "$(date -Iseconds)"
mklock project-rolled  shepherd-roll w6:pR sess-old T-0102 "$(date -Iseconds)"
mklock card-rolled     shepherd-roll w6:pR sess-old none   "$(date -Iseconds -d '30 minutes ago')"
out=$(bash "$LOCK" sweep); rc=$?
assert_file "a queued task's project lock held by a rolled-over instance is kept" "$L/project-rolled.lock"
assert_eq  "and is not reported ORPHAN or SWEPT" "$(printf '%s\n' "$out" | grep -cE '^(ORPHAN|SWEPT) project-rolled')" "0"
assert_file "its card lock is kept too" "$L/card-rolled.lock"
assert_eq  "and reads as a live holder's long hold" "$(printf '%s\n' "$out" | grep -c '^LONG-HELD card-rolled shepherd-roll')" "1"
assert_eq  "routine run: exit 0" "$rc" "0"
# ...but a holder whose identity lock is ALSO stale is gone, as before
export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1"
out=$(bash "$LOCK" sweep); rc=$?
assert_nofile "once the identity pair is gone too, the queued task's lock is swept" "$L/project-rolled.lock"
assert_nofile "and the identity lock itself" "$L/shepherd-roll.lock"

# --- T-0217 fix wave: an rm that fails must never print or log SWEPT ---------
# Unchecked, an unwritable locks directory produced a raw `rm: cannot remove`
# on stderr, then `SWEPT`, then exit 0, with the lock still on disk - the same
# false audit claim cmd_release was hardened against in this branch. Skipped
# under root, where rm succeeds whatever the directory mode says.
if [ "$(id -u)" -ne 0 ]; then
  reset_locks; rm -f "$E"
  mklock card-ro shepherd-9 w6:p9 sess-9 none "$(date -Iseconds)"
  chmod 500 "$L"
  out=$(bash "$LOCK" sweep 2>&1); rc=$?
  chmod 700 "$L"
  assert_eq   "a sweep whose rm fails exits 3" "$rc" "3"
  assert_eq   "and reports RM-FAILED" \
    "$(printf '%s\n' "$out" | grep -c '^RM-FAILED card-ro - could not remove, inspect by hand')" "1"
  assert_eq   "and never claims SWEPT" "$(printf '%s\n' "$out" | grep -c '^SWEPT')" "0"
  assert_eq   "and lets no bare rm error reach the operator" \
    "$(printf '%s\n' "$out" | grep -c 'cannot remove')" "0"
  assert_eq   "and logs verdict RM-FAILED" "$(awk '{print $3, $4, $5}' "$E" | tail -1)" "sweep card-ro RM-FAILED"
  assert_file "and the lock is still there" "$L/card-ro.lock"

  # The same failure on the project-* arm, which reaches the delete through a
  # closed task's state rather than the card-* arm's unconditional path.
  reset_locks; rm -f "$E"
  card T-0107 done
  mklock project-ro shepherd-9 w6:p9 sess-9 T-0107 "$(date -Iseconds)"
  chmod 500 "$L"
  out=$(bash "$LOCK" sweep 2>&1); rc=$?
  chmod 700 "$L"
  assert_eq   "the project arm reports RM-FAILED too" \
    "$(printf '%s\n' "$out" | grep -c '^RM-FAILED project-ro - could not remove, inspect by hand')" "1"
  assert_eq   "and exits 3" "$rc" "3"
  assert_file "and the project lock is still there" "$L/project-ro.lock"

  # A dry run calls no rm at all, so the new status check must not turn it
  # into an RM-FAILED: over the same unwritable directory it still prints the
  # SWEPT line a real run would print, and still exits 0.
  rm -f "$E"
  chmod 500 "$L"
  out=$(bash "$LOCK" sweep --dry-run 2>&1); rc=$?
  chmod 700 "$L"
  assert_eq "a dry run over an unwritable locks dir still prints SWEPT" \
    "$(printf '%s\n' "$out" | grep -c '^SWEPT project-ro ')" "1"
  assert_eq "and never RM-FAILED" "$(printf '%s\n' "$out" | grep -c '^RM-FAILED')" "0"
  assert_eq "and exits 0" "$rc" "0"
  assert_nofile "and wrote no events" "$E"
fi

finish
