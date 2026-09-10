#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
R="$HERE/../bin/shepherd-reserve"
T="$SHEPHERD_ROOT/ledger/tasks"

echo "test-reserve:"

# empty ledger starts at T-0001
id=$(bash "$R" reserve shepherd-1 w6:p1 sess-1)
assert_eq "first id on an empty ledger" "$id" "T-0001"
assert_eq "reservation names its claimant" "$(awk '{print $1, $2, $3, $4}' "$T/T-0001.md")" "reserved-by: shepherd-1 w6:p1 sess-1"
assert_eq "reservation is one line" "$(wc -l < "$T/T-0001.md")" "1"

# continues from the highest existing card
printf '# T-0087: x\nstate: done\n' > "$T/T-0087.md"
id=$(bash "$R" reserve shepherd-2 w6:p2 sess-2)
assert_eq "next id follows the max" "$id" "T-0088"

# 30-way contention: all distinct
rm -rf "$T"; mkdir -p "$T"
for i in $(seq 1 30); do
  ( bash "$R" reserve "shepherd-$i" "w6:p$i" "sess-$i" >> "$SHEPHERD_ROOT/ids.txt" ) &
done
wait
assert_eq "30 reservations produced" "$(wc -l < "$SHEPHERD_ROOT/ids.txt")" "30"
assert_eq "all 30 are distinct" "$(sort -u "$SHEPHERD_ROOT/ids.txt" | wc -l)" "30"
assert_eq "every reserved card names a claimant" \
  "$(grep -L '^reserved-by:' "$T"/T-*.md | wc -l)" "0"

# sweep: live claimant is left alone, gone claimant is removed
rm -rf "$T"; mkdir -p "$T"
printf 'reserved-by: shepherd-1 w6:p1 sess-1 %s\n' "$(date -Iseconds -d '2 hours ago')" > "$T/T-0001.md"
printf 'reserved-by: shepherd-9 w6:p9 sess-9 %s\n' "$(date -Iseconds -d '2 hours ago')" > "$T/T-0002.md"
printf '# T-0003: real card\nstate: queued\nowner: shepherd-9\n' > "$T/T-0003.md"
export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1"

out=$(bash "$R" sweep)
assert_file   "live claimant's 2-hour-old reservation survives" "$T/T-0001.md"
assert_nofile "gone claimant's reservation is removed"          "$T/T-0002.md"
assert_file   "a filled card is never touched"                  "$T/T-0003.md"
assert_eq     "live reservation is reported, not swept" "$(printf '%s' "$out" | grep -c '^RESERVED T-0001')" "1"

# tri-state liveness: a claimant whose liveness is unresolved survives
# the sweep untouched - "unresolved" must never collapse into "gone".
rm -rf "$T"; mkdir -p "$T"
printf 'reserved-by: shepherd-5 w6:p5 sess-5 %s\n' "$(date -Iseconds -d '2 hours ago')" > "$T/T-0005.md"
export SHEPHERD_LIVENESS_OVERRIDE=""
export SHEPHERD_LIVENESS_UNKNOWN="w6:p5:sess-5"
out=$(bash "$R" sweep)
assert_file "reservation with unresolvable liveness survives the sweep" "$T/T-0005.md"
assert_eq   "unresolvable-liveness reservation is reported" \
  "$(printf '%s' "$out" | grep -c '^UNKNOWN-LIVENESS T-0005 shepherd-5')" "1"
unset SHEPHERD_LIVENESS_UNKNOWN

# tri-state liveness: the CHANGED re-verify guards the delete against a race
# where another instance sweeps this same reservation and a fresh reserve()
# lands during our herdr round-trip. The stub simulates that race by
# rewriting the reservation file as a side effect of the liveness probe
# itself - the probe IS the round-trip the race window depends on.
rm -rf "$T"; mkdir -p "$T"
printf 'reserved-by: shepherd-6 w6:p6 sess-6 %s\n' "$(date -Iseconds -d '2 hours ago')" > "$T/T-0006.md"
unset SHEPHERD_LIVENESS_OVERRIDE SHEPHERD_LIVENESS_UNKNOWN
racestub="$SHEPHERD_ROOT/racestub"; mkdir -p "$racestub"
cat > "$racestub/herdr" <<STUB
#!/bin/sh
case "\$3" in
  w6:pOWN)
    echo '{"result":{"pane":{"agent_session":{"value":"sess-own"}}},"id":"cli:pane:get"}'
    ;;
  w6:p6)
    printf 'reserved-by: shepherd-6-new w6:p6new sess-6new 2027-01-01T00:00:00+00:00\n' > "$T/T-0006.md"
    echo '{"error":{"code":"pane_not_found","message":"pane w6:p6 not found"},"id":"cli:pane:get"}' >&2
    exit 1
    ;;
esac
STUB
chmod +x "$racestub/herdr"
out=$( PATH="$racestub:$PATH" HERDR_PANE_ID=w6:pOWN bash "$R" sweep )
assert_file "reservation changed during the probe is left alone, not deleted" "$T/T-0006.md"
assert_eq   "changed-during-probe reservation is reported CHANGED" \
  "$(printf '%s' "$out" | grep -c '^CHANGED T-0006 - re-acquired during the liveness probe, left alone')" "1"
assert_eq   "the racing instance's new reservation content survives untouched" \
  "$(awk '{print $2}' "$T/T-0006.md")" "shepherd-6-new"

# liveness oracle safety guard: sweep must skip if the oracle cannot answer
before=$(ls "$T" | wc -l)
out=$( unset SHEPHERD_LIVENESS_OVERRIDE HERDR_PANE_ID; bash "$R" sweep )
assert_eq "sweep skips when the liveness oracle cannot answer" \
  "$(printf '%s' "$out" | grep -c '^SWEEP-SKIPPED')" "1"
assert_eq "and deletes nothing" "$(ls "$T" | wc -l)" "$before"

# Fix 1: malformed reservation lines are reported, not deleted
rm -rf "$T"; mkdir -p "$T"
printf 'reserved-by: onlyholder\n' > "$T/T-0001.md"
export SHEPHERD_LIVENESS_OVERRIDE=""
out=$(bash "$R" sweep)
assert_file "malformed reservation is left in place" "$T/T-0001.md"
assert_eq "malformed reservation is reported" "$(printf '%s' "$out" | grep -c '^MALFORMED T-0001')" "1"

# Fix 1b: reservation without trailing newline is still inspected
rm -rf "$T"; mkdir -p "$T"
printf 'reserved-by: shepherd-1 w6:p1 sess-1 2024-01-01T12:00:00+00:00' > "$T/T-0001.md"  # no trailing newline
export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1"
out=$(bash "$R" sweep)
assert_file "reservation without trailing newline is inspected" "$T/T-0001.md"
assert_eq "and reported as live" "$(printf '%s' "$out" | grep -c '^RESERVED T-0001')" "1"

# Fix 2: whitespace in holder/pane/session is rejected at reserve time
bash "$R" reserve "shepherd one" w6:p1 sess-1 >/dev/null 2>&1
rc=$?
assert_eq "reserve with space in holder returns error code" "$rc" "2"
assert_nofile "no file created for invalid reserve" "$T/T-0002.md"  # T-0001 already exists from earlier tests

# Fix 3: filesystem errors are distinguished from collisions
rm -rf "$T"
chmod 000 "$SHEPHERD_ROOT/ledger"  # Make directory unwritable
out=$(bash "$R" reserve shepherd-1 w6:p1 sess-1 2>&1)
rc=$?
chmod 755 "$SHEPHERD_ROOT/ledger"  # Restore permissions
assert_eq "reserve on permission error returns 2" "$rc" "2"
assert_eq "permission error names the directory" "$(printf '%s' "$out" | grep -c 'cannot write')" "1"

# Fix 4a: 9999 ceiling is detected explicitly
mkdir -p "$T"
for n in $(seq 9990 9999); do printf '# T-%04d\n' "$n" > "$T/T-$n.md"; done
out=$(bash "$R" reserve shepherd-1 w6:p1 sess-1 2>&1)
rc=$?
assert_eq "reserve at 9999 ceiling returns error" "$rc" "2"
assert_eq "error message names exhaustion, not retry count" "$(printf '%s' "$out" | grep -c 'task id space exhausted')" "1"

# Fix 4b: extra arguments are rejected
rm -rf "$T"; mkdir -p "$T"
out=$(bash "$R" reserve h p s EXTRA 2>&1)
rc=$?
assert_eq "reserve with extra args returns error" "$rc" "2"

# Fix 4c: herdr error path is tested (second branch of pre-flight)
rm -rf "$T"; mkdir -p "$T"
printf 'reserved-by: shepherd-1 w6:p1 sess-1 %s\n' "$(date -Iseconds)" > "$T/T-0001.md"
stub="$SHEPHERD_ROOT/stub"; mkdir -p "$stub"
cat > "$stub/herdr" <<'STUB'
#!/bin/sh
echo '{"error":{"code":"unreachable"}}'
STUB
chmod +x "$stub/herdr"
before=$(ls "$T" | wc -l)
out=$( unset SHEPHERD_LIVENESS_OVERRIDE; PATH="$stub:$PATH" HERDR_PANE_ID=w6:p1 bash "$R" sweep )
assert_eq "sweep skips when herdr cannot answer for our own pane" \
  "$(printf '%s' "$out" | grep -c '^SWEEP-SKIPPED')" "1"
assert_eq "and deletes nothing when the oracle is unreachable" "$(ls "$T" | wc -l)" "$before"

# --- T-0217: events, exit codes, dry run, rollover-safe claimant ------------
E="$SHEPHERD_ROOT/ledger/events.log"
L="$SHEPHERD_ROOT/ledger/locks"; mkdir -p "$L"
rm -rf "$T"; mkdir -p "$T"; rm -f "$E"
export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1"
unset SHEPHERD_LIVENESS_UNKNOWN

id=$(bash "$R" reserve shepherd-1 w6:p1 sess-1)
assert_eq "reserve logs RESERVED under the claimant with the id as target" \
  "$(awk '{print $2, $3, $4, $5}' "$E" | tail -1)" "shepherd-1 reserve $id RESERVED"

# exit codes, one kind at a time
rm -rf "$T"; mkdir -p "$T"
printf 'reserved-by: shepherd-1 w6:p1 sess-1 %s\n' "$(date -Iseconds)" > "$T/T-0001.md"
printf 'reserved-by: shepherd-9 w6:p9 sess-9 %s\n' "$(date -Iseconds)" > "$T/T-0002.md"
bash "$R" sweep >/dev/null; rc=$?
assert_eq "a routine reserve sweep (RESERVED + SWEPT) exits 0" "$rc" "0"
rm -rf "$T"; mkdir -p "$T"
printf 'reserved-by: onlyholder\n' > "$T/T-0003.md"
bash "$R" sweep >/dev/null; rc=$?
assert_eq "MALFORMED alone exits 3" "$rc" "3"
rm -rf "$T"; mkdir -p "$T"
printf 'reserved-by: shepherd-7 w6:p7 sess-7 %s\n' "$(date -Iseconds)" > "$T/T-0004.md"
export SHEPHERD_LIVENESS_UNKNOWN="w6:p7:sess-7"
bash "$R" sweep >/dev/null; rc=$?
assert_eq "UNKNOWN-LIVENESS alone exits 3" "$rc" "3"
unset SHEPHERD_LIVENESS_UNKNOWN
( unset SHEPHERD_LIVENESS_OVERRIDE HERDR_PANE_ID; bash "$R" sweep >/dev/null ); rc=$?
assert_eq "SWEEP-SKIPPED exits 3" "$rc" "3"

# dry run
rm -rf "$T"; mkdir -p "$T"; rm -f "$E"
printf 'reserved-by: shepherd-1 w6:p1 sess-1 %s\n' "$(date -Iseconds)" > "$T/T-0001.md"
printf 'reserved-by: shepherd-9 w6:p9 sess-9 %s\n' "$(date -Iseconds)" > "$T/T-0002.md"
printf 'reserved-by: onlyholder\n' > "$T/T-0003.md"
touch -d '2 hours ago' "$T/.tmp.old"   # the temp cleanup a real run would do, and a dry run must not
before=$(find "$T" -type f | sort | xargs -r md5sum)
out=$(bash "$R" sweep --dry-run); rc=$?
assert_eq "dry run announces itself first" "$(printf '%s\n' "$out" | head -1)" "DRY-RUN no changes will be made"
assert_eq "dry run prints RESERVED, SWEPT and MALFORMED" \
  "$(printf '%s\n' "$out" | grep -cE '^(RESERVED T-0001|SWEPT T-0002|MALFORMED T-0003)')" "3"
assert_eq "dry run exit code follows the rule (3 here)" "$rc" "3"
assert_eq "dry run changed nothing" "$(find "$T" -type f | sort | xargs -r md5sum)" "$before"
assert_nofile "dry run wrote no events" "$E"
out=$(bash "$R" sweep --bogus 2>&1); rc=$?
assert_eq "an unknown sweep flag is a usage error" "$rc" "2"

# real run: one events line per verdict
out=$(bash "$R" sweep)
assert_eq "one events line per printed verdict" "$(wc -l < "$E")" "$(printf '%s\n' "$out" | grep -c .)"
assert_eq "events carry verb reserve-sweep and the verdict words" \
  "$(awk '$3 == "reserve-sweep" {print $5}' "$E" | sort | tr '\n' ' ')" "MALFORMED RESERVED SWEPT "

# a claimant that rolled over: its reservation names the old session, its
# identity lock the new live one -> RESERVED, not SWEPT
rm -rf "$T"; mkdir -p "$T"
export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1 w6:pR:sess-new"
printf 'shepherd-roll w6:pR sess-new none %s\n' "$(date -Iseconds)" > "$L/shepherd-roll.lock"
printf 'reserved-by: shepherd-roll w6:pR sess-old %s\n' "$(date -Iseconds)" > "$T/T-0005.md"
out=$(bash "$R" sweep)
assert_file "a rolled-over claimant keeps its reservation" "$T/T-0005.md"
assert_eq  "and it is reported RESERVED" "$(printf '%s\n' "$out" | grep -c '^RESERVED T-0005 by shepherd-roll')" "1"
rm -f "$L/shepherd-roll.lock"

# --- T-0217 fix wave: an rm that fails must never print or log SWEPT --------
# The sweep's inline `rm -f` ignored its status, so an unwritable tasks
# directory printed a raw rm error, then `SWEPT`, then exited 0, with the
# reservation still on disk. Skipped under root, where rm succeeds whatever
# the directory mode says.
if [ "$(id -u)" -ne 0 ]; then
  rm -rf "$T"; mkdir -p "$T"; rm -f "$E"
  export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-1"
  printf 'reserved-by: shepherd-9 w6:p9 sess-9 %s\n' "$(date -Iseconds)" > "$T/T-0009.md"
  chmod 500 "$T"
  out=$(bash "$R" sweep 2>&1); rc=$?
  chmod 700 "$T"
  assert_eq   "a reserve sweep whose rm fails exits 3" "$rc" "3"
  assert_eq   "and reports RM-FAILED" \
    "$(printf '%s\n' "$out" | grep -c '^RM-FAILED T-0009 - could not remove, inspect by hand')" "1"
  assert_eq   "and never claims SWEPT" "$(printf '%s\n' "$out" | grep -c '^SWEPT')" "0"
  assert_eq   "and lets no bare rm error reach the operator" \
    "$(printf '%s\n' "$out" | grep -c 'cannot remove')" "0"
  assert_eq   "and logs verdict RM-FAILED" \
    "$(awk '{print $3, $4, $5}' "$E" | tail -1)" "reserve-sweep T-0009 RM-FAILED"
  assert_file "and the reservation is still there" "$T/T-0009.md"

  # A dry run calls no rm at all, so the new status check must not turn it into
  # an RM-FAILED: over the same unwritable directory it still prints the SWEPT
  # line a real run would print, and still exits 0.
  rm -f "$E"
  chmod 500 "$T"
  out=$(bash "$R" sweep --dry-run 2>&1); rc=$?
  chmod 700 "$T"
  assert_eq "a dry run over an unwritable tasks dir still prints SWEPT" \
    "$(printf '%s\n' "$out" | grep -c '^SWEPT T-0009 ')" "1"
  assert_eq "and never RM-FAILED" "$(printf '%s\n' "$out" | grep -c '^RM-FAILED')" "0"
  assert_eq "and exits 0" "$rc" "0"
  assert_nofile "and wrote no events" "$E"
fi

# --- T-0253 item 5: the header says exactly what logs ---------------------------
# "Every verdict that touches a reservation is appended" read as universal, while
# reserve's cannot-write ERROR (which touched none) logs and a dry run (which
# prints every verdict) logs nothing (T-0217 review).
assert_fail "the header no longer claims every verdict that touches a reservation" \
  grep -qF 'Every verdict that touches a reservation' "$R"
assert_ok "it names reserve's RESERVED and its cannot-write ERROR as what logs" \
  grep -qE 'RESERVED and its cannot-write ERROR' "$R"
assert_ok "and says a dry run prints the same lines and logs none" \
  grep -qE 'same lines and logs none' "$R"

finish
