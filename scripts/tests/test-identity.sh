#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
I="$HERE/../shepherd-identity.sh"
L="$SHEPHERD_ROOT/ledger/locks"
S="$SHEPHERD_ROOT/ledger/shepherds"

reg_field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }

echo "test-identity:"

export HERDR_ENV=1
export HERDR_PANE_ID=w6:p1
export SHEPHERD_PANE_SESSION_OVERRIDE=sess-1          # test hook, stands in for herdr
export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1"

assert_ok   "first acquire succeeds"    bash "$I" acquire shepherd-1
assert_file "identity lock written"     "$L/shepherd-1.lock"
assert_file "registration written"      "$S/shepherd-1.json"
assert_eq   "registration records the pane" "$(reg_field "$S/shepherd-1.json" pane)" "w6:p1"

started_first=$(reg_field "$S/shepherd-1.json" started)
last_seen_first=$(reg_field "$S/shepherd-1.json" last_seen)
sleep 1

# re-acquire from the SAME pane+session is idempotent (a restart of the script)
assert_ok "re-acquire from the same session is idempotent" bash "$I" acquire shepherd-1
started_after=$(reg_field "$S/shepherd-1.json" started)
last_seen_after=$(reg_field "$S/shepherd-1.json" last_seen)
assert_eq "idempotent re-acquire preserves the original started timestamp" \
  "$started_after" "$started_first"
assert_eq "idempotent re-acquire refreshes last_seen" \
  "$([ "$last_seen_after" != "$last_seen_first" ] && echo changed || echo unchanged)" "changed"

# a different session claiming a LIVE id must refuse
export HERDR_PANE_ID=w6:p2
export SHEPHERD_PANE_SESSION_OVERRIDE=sess-2
export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1 w6:p2:sess-2"
assert_fail "second instance cannot take a live id" bash "$I" acquire shepherd-1
assert_eq "the live holder still owns the lock" "$(awk '{print $2}' "$L/shepherd-1.lock")" "w6:p1"

# a different session claiming a GONE id takes it over
export SHEPHERD_LIVENESS_OVERRIDE="w6:p2:sess-2"
assert_ok "gone id is taken over" bash "$I" acquire shepherd-1
assert_eq "lock now names the new pane" "$(awk '{print $2}' "$L/shepherd-1.lock")" "w6:p2"

# a distinct id is independent
assert_ok   "shepherd-2 acquires its own id" bash "$I" acquire shepherd-2
assert_file "shepherd-2 lock exists"         "$L/shepherd-2.lock"

# --- bad ids are rejected outright, including attempts to smuggle
# whitespace, shell metacharacters, or a path-traversal segment through
# the id. An earlier, looser glob accepted all of these; one of them
# (the traversal id) wrote its lock OUTSIDE LOCKS_DIR, where sweep's glob
# can never find it, and still exited 0.
assert_fail "rejects a malformed id"        bash "$I" acquire not-a-shepherd
assert_fail "rejects an embedded space"     bash "$I" acquire "shepherd-1 2"
assert_fail "rejects shell metacharacters"  bash "$I" acquire 'shepherd-2;echo INJECT'
assert_fail "rejects a path-traversal id"   bash "$I" acquire 'shepherd-1/../../../../tmp/pwned'
assert_fail "rejects an empty suffix"       bash "$I" acquire 'shepherd-'
assert_fail "rejects an uppercase suffix"   bash "$I" acquire 'shepherd-Blue'
assert_fail "rejects a trailing hyphen"     bash "$I" acquire 'shepherd-blue-'
assert_fail "rejects a doubled hyphen"      bash "$I" acquire 'shepherd--blue'
assert_fail "rejects a dotted suffix"       bash "$I" acquire 'shepherd-bl.ue'

# Named ids are accepted alongside numbered ones. Each must land its lock
# INSIDE LOCKS_DIR under exactly its own name, so sweep's `shepherd-*` arm
# still sees it.
for fun in blue north two-dogs; do
  assert_ok   "accepts the named id shepherd-$fun" bash "$I" acquire "shepherd-$fun"
  assert_file "shepherd-$fun's lock lands in LOCKS_DIR" "$L/shepherd-$fun.lock"
done
assert_eq "no lock escaped LOCKS_DIR" "$(find "$SHEPHERD_ROOT" -name 'shepherd-*.lock' -not -path "$L/*" | wc -l)" "0"

# --- tri-state rule: a holder whose liveness is unresolved must be
# refused, not taken over. "unresolved" must never collapse into "gone".
# The current holder of shepherd-1 is w6:p2/sess-2 (left there by the
# takeover above). A third pane tries to acquire it while that holder's
# liveness is unresolvable, driven with SHEPHERD_LIVENESS_UNKNOWN.
export HERDR_PANE_ID=w6:p3
export SHEPHERD_PANE_SESSION_OVERRIDE=sess-3
export SHEPHERD_LIVENESS_OVERRIDE=""
export SHEPHERD_LIVENESS_UNKNOWN="w6:p2:sess-2"
out=$(bash "$I" acquire shepherd-1 2>&1 >/dev/null); rc=$?
assert_eq "unresolvable holder liveness is refused (exit 1), not taken over" "$rc" "1"
assert_eq "the unresolved holder still owns the lock" "$(awk '{print $2}' "$L/shepherd-1.lock")" "w6:p2"
assert_eq "refusal message says the holder is unresolved" \
  "$(printf '%s' "$out" | grep -c 'is unresolved')" "1"
unset SHEPHERD_LIVENESS_UNKNOWN

# --- malformed identity lock: refused, never silently stolen (matches
# lock.sh's own "MALFORMED - left in place" convention). Both an empty
# file and a single-field line used to produce a successful takeover.
export HERDR_PANE_ID=w6:p4
export SHEPHERD_PANE_SESSION_OVERRIDE=sess-4

printf '' > "$L/shepherd-4.lock"
out=$(bash "$I" acquire shepherd-4 2>&1 >/dev/null); rc=$?
assert_eq "empty identity lock is refused, not stolen" "$rc" "1"
assert_eq "empty-lock refusal is reported as MALFORMED" \
  "$(printf '%s' "$out" | grep -c '^MALFORMED')" "1"
assert_eq "empty lock file is left exactly as it was" "$(wc -c < "$L/shepherd-4.lock")" "0"

printf 'onlyholder\n' > "$L/shepherd-4.lock"
out=$(bash "$I" acquire shepherd-4 2>&1 >/dev/null); rc=$?
assert_eq "single-field identity lock is refused, not stolen" "$rc" "1"
assert_eq "single-field refusal is reported as MALFORMED" \
  "$(printf '%s' "$out" | grep -c '^MALFORMED')" "1"
assert_eq "single-field lock file is left exactly as it was" "$(cat "$L/shepherd-4.lock")" "onlyholder"
rm -f "$L/shepherd-4.lock"

# --- write_registration's failure is not silently swallowed: acquire
# must fail overall (exit 2) rather than print IDENTITY and move on with
# no registration to back the claim.
export HERDR_PANE_ID=w6:p5
export SHEPHERD_PANE_SESSION_OVERRIDE=sess-5
chmod 000 "$S"
out=$(bash "$I" acquire shepherd-5 2>&1); rc=$?
chmod 755 "$S"
assert_eq "acquire fails when the registration cannot be written" "$rc" "2"
assert_eq "no success line is printed" "$(printf '%s' "$out" | grep -c '^IDENTITY')" "0"
assert_file   "the lock is still created (registration is advisory, the lock is authoritative)" "$L/shepherd-5.lock"
assert_nofile "no registration file was written when it could not be" "$S/shepherd-5.json"

# --- cmd_touch: no test existed at all before this round. Owning instance
# refreshes last_seen and preserves started; a non-owner is refused and
# leaves the registration untouched; an id with no lock is refused, never
# silently creating one for nobody.
export HERDR_PANE_ID=w6:p2
export SHEPHERD_PANE_SESSION_OVERRIDE=sess-2   # shepherd-2's actual owner

ts_before=$(reg_field "$S/shepherd-2.json" last_seen)
started_before=$(reg_field "$S/shepherd-2.json" started)
sleep 1
assert_ok "touch by the owning instance succeeds" bash "$I" touch shepherd-2
ts_after=$(reg_field "$S/shepherd-2.json" last_seen)
started_after2=$(reg_field "$S/shepherd-2.json" started)
assert_eq "touch refreshes last_seen" "$([ "$ts_after" != "$ts_before" ] && echo changed || echo unchanged)" "changed"
assert_eq "touch preserves started" "$started_after2" "$started_before"

export HERDR_PANE_ID=w6:pINTRUDER
export SHEPHERD_PANE_SESSION_OVERRIDE=sess-intruder
before_reg=$(cat "$S/shepherd-2.json")
assert_fail "touch by a non-owning instance is refused" bash "$I" touch shepherd-2
after_reg=$(cat "$S/shepherd-2.json")
assert_eq "refused touch leaves the registration untouched" "$after_reg" "$before_reg"

assert_nofile "shepherd-6 has no lock yet" "$L/shepherd-6.lock"
assert_fail "touch on an id with no identity lock is refused" bash "$I" touch shepherd-6
assert_nofile "touch never creates a lock for an unheld id" "$L/shepherd-6.lock"
assert_nofile "touch never creates a registration for an unheld id" "$S/shepherd-6.json"

# race_copy <dest> — a private copy of shepherd-identity.sh + lock.sh + the
# real lib, so one test can override a single function (shepherd_live)
# without touching the real scripts. $HERE-relative sourcing inside the
# copies resolves to <dest>, so they behave exactly like the real scripts
# except for whatever gets appended to <dest>/lib/shepherd-common.sh -
# appending a second "shepherd_live() { ... }" redefines it, since the
# last definition in a sourced file wins; every other function (pane_probe,
# atomic_create, hooks_active, ...) is untouched.
race_copy() {
  local dest=$1
  mkdir -p "$dest/lib"
  cp "$HERE/../shepherd-identity.sh" "$dest/shepherd-identity.sh"
  cp "$HERE/../lock.sh" "$dest/lock.sh"
  cp "$HERE/../lib/shepherd-common.sh" "$dest/lib/shepherd-common.sh"
}

# --- CRITICAL: two instances racing a takeover must not both win. Without
# the reclaim-lock + re-read guard, a genuinely slow shepherd_live (a real
# herdr round-trip in production) opens a window: both instances sample
# the same gone holder, both call shepherd_live, and both delete-then-
# create the identity lock, each believing it now owns the id.
#
# Simulated deterministically: shepherd_live is stubbed to, on its one
# call, plant a RIVAL holder into the identity lock file before returning
# 1 (gone) - standing in for a second instance that finished
# its own takeover during this instance's probe.
race="$SHEPHERD_ROOT/race-critical"
race_copy "$race"
cat >> "$race/lib/shepherd-common.sh" <<RACESTUB
shepherd_live() {
  printf 'rival-holder w6:pRIVAL sess-rival none %s\n' "\$(now_iso)" > "$L/shepherd-9.lock"
  return 1
}
RACESTUB

printf 'old-holder w6:pOLD sess-old none %s\n' "$(date -Iseconds)" > "$L/shepherd-9.lock"
export HERDR_PANE_ID=w6:pNEW
export SHEPHERD_PANE_SESSION_OVERRIDE=sess-new
out=$(bash "$race/shepherd-identity.sh" acquire shepherd-9 2>&1 >/dev/null); rc=$?
assert_eq "a holder that changed hands during the probe is refused, not stolen" "$rc" "1"
assert_eq "refusal names the race, not a generic error" \
  "$(printf '%s' "$out" | grep -c 'changed hands while its holder was probed')" "1"
assert_eq "the rival's freshly-planted claim survives untouched" \
  "$(awk '{print $2}' "$L/shepherd-9.lock")" "w6:pRIVAL"
assert_nofile "no reclaim lock is left behind after the refusal" "$L/shepherd-9.reclaim.lock"

# --- an out-of-contract shepherd_live return code must not authorise a
# takeover either. shepherd_live's contract is 0/1/2; only an explicit 1
# may free an id, the same safe polarity lock.sh's sweep uses.
race2="$SHEPHERD_ROOT/race-oob"
race_copy "$race2"
cat >> "$race2/lib/shepherd-common.sh" <<'RACESTUB'
shepherd_live() { return 42; }
RACESTUB

# --- a reclaim lock left behind by a crashed takeover must not wedge the id
# forever. Before this, every boot of shepherd-11 printed "another instance
# is already reclaiming shepherd-11", naming a rival that does not exist -
# and the only cleaner (lock.sh sweep) runs at session-start step 3, AFTER
# identity at step 2 has already told the shepherd to stop. For a solo
# shepherd-1 nothing ever cleared it. The stale reclaim lock's holder is
# resolved like any other: cleared only when gone.
export HERDR_PANE_ID=w6:p12
export SHEPHERD_PANE_SESSION_OVERRIDE=sess-12
export SHEPHERD_LIVENESS_OVERRIDE="w6:p12:sess-12 w6:pRECLAIMER:sess-reclaimer"

printf 'shepherd-11 w6:pGONE sess-gone none %s\n' "$(date -Iseconds)" > "$L/shepherd-11.lock"
printf 'shepherd-11 w6:pGHOST sess-ghost none %s\n' "$(date -Iseconds)" > "$L/shepherd-11.reclaim.lock"
assert_ok "a stale reclaim lock whose holder is gone does not wedge the id" \
  bash "$I" acquire shepherd-11
assert_eq "the id is now held by the booting instance" \
  "$(awk '{print $2}' "$L/shepherd-11.lock")" "w6:p12"
assert_nofile "and the reclaim lock is released again" "$L/shepherd-11.reclaim.lock"

# ...but a reclaim lock held by a LIVE instance still refuses. "Clear it if
# gone" must never widen into "clear it".
printf 'shepherd-13 w6:pGONE sess-gone none %s\n' "$(date -Iseconds)" > "$L/shepherd-13.lock"
printf 'shepherd-13 w6:pRECLAIMER sess-reclaimer none %s\n' "$(date -Iseconds)" > "$L/shepherd-13.reclaim.lock"
out=$(bash "$I" acquire shepherd-13 2>&1 >/dev/null); rc=$?
assert_eq   "a live reclaimer still wins the id" "$rc" "1"
assert_eq   "and the refusal names the reclaim in progress" \
  "$(printf '%s' "$out" | grep -c 'already reclaiming shepherd-13')" "1"
assert_file "the live reclaimer's lock is left in place" "$L/shepherd-13.reclaim.lock"
assert_eq   "and the identity lock is not stolen" \
  "$(awk '{print $2}' "$L/shepherd-13.lock")" "w6:pGONE"

# ...and neither does an unresolvable reclaim holder.
export SHEPHERD_LIVENESS_UNKNOWN="w6:pFOG:sess-fog"
printf 'shepherd-14 w6:pGONE sess-gone none %s\n' "$(date -Iseconds)" > "$L/shepherd-14.lock"
printf 'shepherd-14 w6:pFOG sess-fog none %s\n' "$(date -Iseconds)" > "$L/shepherd-14.reclaim.lock"
out=$(bash "$I" acquire shepherd-14 2>&1 >/dev/null); rc=$?
assert_eq   "an unresolvable reclaim holder is refused, not cleared" "$rc" "1"
assert_file "its reclaim lock survives" "$L/shepherd-14.reclaim.lock"
unset SHEPHERD_LIVENESS_UNKNOWN

printf 'old-holder w6:pOLD sess-old none %s\n' "$(date -Iseconds)" > "$L/shepherd-10.lock"
export HERDR_PANE_ID=w6:pNEW2
export SHEPHERD_PANE_SESSION_OVERRIDE=sess-new2
out=$(bash "$race2/shepherd-identity.sh" acquire shepherd-10 2>&1 >/dev/null); rc=$?
assert_eq "an out-of-contract liveness code refuses rather than takes over" "$rc" "1"
assert_eq "shepherd-10's original holder still owns the lock" \
  "$(awk '{print $2}' "$L/shepherd-10.lock")" "w6:pOLD"

finish
