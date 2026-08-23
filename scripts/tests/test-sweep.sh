#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
LOCK="$HERE/../lock.sh"
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
# let a narrowing of lock.sh's arm to `working)` ship green - a regression
# that frees a project lock during the briefed or review window, both of
# which have a live worker in the checkout.
card T-0105 briefed
card T-0106 review

mklock project-alpha       shepherd-9 w6:p9 sess-9 T-0100 "$(date -Iseconds)"
mklock project-beta        shepherd-9 w6:p9 sess-9 T-0101 "$(date -Iseconds)"
mklock project-gamma       shepherd-9 w6:p9 sess-9 T-0102 "$(date -Iseconds)"
mklock project-captured    shepherd-9 w6:p9 sess-9 T-0103 "$(date -Iseconds)"
mklock project-taskless    shepherd-9 w6:p9 sess-9 none   "$(date -Iseconds)"
mklock card-alpha          shepherd-9 w6:p9 sess-9 none   "$(date -Iseconds)"
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

assert_file   "active task keeps its stale project lock" "$L/project-alpha.lock"
assert_eq     "and is reported as an orphan" "$(printf '%s' "$out" | grep -c '^ORPHAN project-alpha T-0100 state=working')" "1"
assert_nofile "closed task frees its project lock"  "$L/project-beta.lock"
assert_nofile "queued task frees its project lock"  "$L/project-gamma.lock"
assert_nofile "captured task frees its project lock"  "$L/project-captured.lock"
assert_nofile "taskless project lock is freed"      "$L/project-taskless.lock"
assert_nofile "stale card lock is freed"            "$L/card-alpha.lock"
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
assert_ok     "sweep exits 0"                        bash "$LOCK" sweep

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

finish
