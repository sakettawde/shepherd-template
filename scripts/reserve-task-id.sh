#!/usr/bin/env bash
# Race-free task-id reservation. See docs/specs/multi-shepherd-design.md S4.
#
#   reserve-task-id.sh reserve <holder> <pane> <session>   -> prints T-NNNN
#   reserve-task-id.sh sweep                               -> removes reservations whose claimant is gone
#
# A reserved card holds one line and nothing else:
#   reserved-by: <holder> <pane> <session> <iso8601>
# Triage replaces it with the filled card. Cleanup is gated on the claimant
# being gone, NEVER on the reservation's age - an LLM session can legitimately
# sit half an hour between two tool calls.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shepherd-common.sh"

RESERVE_KEY='reserved-by:'
MAX_TRIES=50

usage() { sed -n '3,6p' "$0" >&2; exit 2; }

cmd_reserve() {
  local holder=$1 pane=$2 session=$3 max next id i arg
  # Validate arguments: must be non-empty and free of whitespace
  for arg in "$holder" "$pane" "$session"; do
    case $arg in
      ''|*[[:space:]]*)
        echo "ERROR: holder, pane and session must be non-empty and free of whitespace" >&2
        return 2 ;;
    esac
  done
  mkdir -p "$TASKS_DIR"
  for (( i = 1; i <= MAX_TRIES; i++ )); do
    max=$(ls "$TASKS_DIR"/T-[0-9][0-9][0-9][0-9].md 2>/dev/null \
          | sed 's|.*/T-\([0-9]\{4\}\)\.md$|\1|' | sort -n | tail -1)
    next=$(( 10#${max:-0} + 1 ))
    if [ "$next" -gt 9999 ]; then
      echo "ERROR: task id space exhausted (T-9999 reached)" >&2
      return 2
    fi
    id=$(printf 'T-%04d' "$next")
    atomic_create "$TASKS_DIR/$id.md" "$RESERVE_KEY $holder $pane $session $(now_iso)"
    case $? in
      0) echo "$id"; return 0 ;;
      1) : ;;                              # another instance won this number; try the next
      *) echo "ERROR: cannot write $TASKS_DIR" >&2; return 2 ;;
    esac
  done
  echo "ERROR: no free task id after $MAX_TRIES tries" >&2
  return 1
}

cmd_sweep() {
  # A liveness oracle that cannot answer must never be read as "every claimant is gone".
  # Without this, one herdr outage at session start would delete every live reservation.
  # The test-hook bypass below only applies when hooks_active (SHEPHERD_TEST_HOOKS=1):
  # outside a test harness, SHEPHERD_LIVENESS_OVERRIDE/UNKNOWN merely being set
  # in the environment must never itself skip the real pane_probe check.
  if ! hooks_active || { [ -z "${SHEPHERD_LIVENESS_OVERRIDE+x}" ] && [ -z "${SHEPHERD_LIVENESS_UNKNOWN+x}" ]; }; then
    if [ -z "${HERDR_PANE_ID:-}" ] || ! pane_probe "$HERDR_PANE_ID" >/dev/null 2>&1; then
      echo "SWEEP-SKIPPED liveness oracle unavailable - no reservations inspected"
      return 0
    fi
  fi

  local f id key holder pane session ts line live_rc
  for f in "$TASKS_DIR"/T-[0-9][0-9][0-9][0-9].md; do
    [ -e "$f" ] || continue
    line=$(head -1 "$f" 2>/dev/null)
    read -r key holder pane session ts <<<"$line"
    [ "$key" = "$RESERVE_KEY" ] || continue
    id=$(basename "$f" .md)
    if [ -z "$holder" ] || [ -z "$pane" ] || [ -z "$session" ]; then
      echo "MALFORMED $id - left in place, inspect by hand"
      continue
    fi
    shepherd_live "$pane" "$session"
    live_rc=$?
    case $live_rc in
      0) echo "RESERVED $id by $holder (claimant live - left alone)" ;;
      1)
        # The liveness probe above is a herdr round-trip. Another instance
        # may have swept this same reservation and a fresh reserve() landed
        # on this id while we waited. Deleting on the stale read would
        # unlink a LIVE claimant's reservation and hand the id to a second
        # instance. The timestamp field makes each acquisition's line
        # unique, so re-reading it here is a sound compare-before-delete.
        if [ "$(head -1 "$f" 2>/dev/null)" != "$line" ]; then
          echo "CHANGED $id - re-acquired during the liveness probe, left alone"
        else
          rm -f "$f"; echo "SWEPT $id (reserved by $holder, claimant gone)"
        fi
        ;;
      # Anything other than gone (1) - unresolved (2), or any
      # return code shepherd_live's contract does not promise - must never
      # reach the delete arm. Only an explicit 1 may free a reservation.
      *) echo "UNKNOWN-LIVENESS $id $holder - cannot reach herdr for pane $pane, left in place" ;;
    esac
  done
  find "$TASKS_DIR" -maxdepth 1 -name '.tmp.*' -mmin +60 -delete 2>/dev/null
  return 0
}

case ${1:-} in
  reserve) shift; [ $# -eq 3 ] || usage; cmd_reserve "$@" ;;
  sweep)   shift; cmd_sweep ;;
  *) usage ;;
esac
