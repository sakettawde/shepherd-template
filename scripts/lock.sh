#!/usr/bin/env bash
# Shepherd's coordination lock. See docs/specs/multi-shepherd-design.md S6.
#
#   lock.sh acquire  <name> <holder> <pane> <session> [task]
#   lock.sh takeover <name> <holder> <pane> <session> [task]
#   lock.sh release  <name> <holder>
#   lock.sh check    <name>
#   lock.sh sweep
#
# A lock file holds exactly one line:
#   <holder> <pane> <session> <task|none> <acquired-iso8601>
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/shepherd-common.sh"
LONG_HOLD_SECONDS=600

usage() { sed -n '3,10p' "$0" >&2; exit 2; }
lock_path() { printf '%s/%s.lock' "$LOCKS_DIR" "$1"; }

# validate_fields <holder> <pane> <session> <task>
# Every field of a lock line must be one whitespace-free token, or the line
# cannot be read back: `read -r holder pane session task ts` silently shifts
# every later field left. An empty holder - which is exactly what an unset
# $SHEPHERD_ID produces, and CLAUDE.md S0 documents unset as a real default -
# would write a line whose "task" field holds the timestamp: a lock its owner
# can never release, and one sweep frees out from under a running worker
# because task_state finds no such card. Refuse to write it at all.
validate_fields() {
  local names=(holder pane session task) vals=("$1" "$2" "$3" "$4") i
  for i in 0 1 2 3; do
    case ${vals[$i]} in
      ''|*[[:space:]]*)
        echo "ERROR: ${names[$i]} must be non-empty and free of whitespace (got '${vals[$i]}')" >&2
        return 2 ;;
    esac
  done
  return 0
}

cmd_acquire() {
  local name=$1 holder=$2 pane=$3 session=$4 task=${5:-none} f
  validate_fields "$holder" "$pane" "$session" "$task" || return 2
  f=$(lock_path "$name")
  atomic_create "$f" "$holder $pane $session $task $(now_iso)"
  case $? in
    0) echo "ACQUIRED $name"; return 0 ;;
    1) echo "HELD $name $(cat "$f" 2>/dev/null)"; return 1 ;;
    *) echo "ERROR could not write $f" >&2; return 2 ;;
  esac
}

# S10 step 3 / CLAUDE.md S8 step 6: the one sanctioned way to claim a lock
# whose holder is gone. `acquire` returns HELD, `release` returns REFUSED and
# `sweep` deliberately keeps a project lock over an active task (the orphan
# rule), so without this the most common recovery - a shepherd that crashed
# with an active task and restarted under the same id - has no runnable
# command for the step that tells it to take the lock back.
#
# Gated on liveness, never on age, and never on a read from an earlier step.
cmd_takeover() {
  local name=$1 holder=$2 pane=$3 session=$4 task=${5:-none}
  local f line h_holder h_pane h_session live_rc dir tmp
  validate_fields "$holder" "$pane" "$session" "$task" || return 2
  f=$(lock_path "$name")

  # Nothing to take over: this is a plain acquire, atomic against a racer
  # that creates the lock between these two lines.
  if [ ! -f "$f" ]; then
    cmd_acquire "$@"
    return $?
  fi

  line=$(head -1 "$f" 2>/dev/null)
  h_holder= h_pane= h_session=
  [ -n "$line" ] && read -r h_holder h_pane h_session _ <<<"$line"
  if [ -z "$h_pane" ] || [ -z "$h_session" ]; then
    echo "MALFORMED $name - left in place, inspect by hand" >&2
    return 1
  fi

  shepherd_live "$h_pane" "$h_session"
  live_rc=$?
  if [ "$live_rc" -eq 0 ]; then
    echo "REFUSED $name is held by a live instance ($h_holder, pane $h_pane) - never steal from a live holder" >&2
    return 1
  fi
  # Only an explicit 1 (gone) authorises a takeover - the same
  # polarity sweep uses. "Unresolved" is not evidence that the holder is gone.
  if [ "$live_rc" -ne 1 ]; then
    echo "UNKNOWN-LIVENESS $name $h_holder - cannot reach herdr for pane $h_pane, left in place" >&2
    return 1
  fi

  # The liveness probe was a herdr round-trip. Another instance may have
  # taken this same lock over while we waited; the timestamp field makes
  # each acquisition's line unique, so re-reading it here is a sound
  # compare-before-write - the same guard cmd_sweep uses before it unlinks.
  if [ "$(head -1 "$f" 2>/dev/null)" != "$line" ]; then
    echo "CHANGED $name - re-acquired during the liveness probe, left alone" >&2
    return 1
  fi

  dir=$(dirname "$f")
  tmp=$(mktemp "$dir/.tmp.XXXXXX") || { echo "ERROR could not write $f" >&2; return 2; }
  if ! printf '%s\n' "$holder $pane $session $task $(now_iso)" > "$tmp"; then
    rm -f "$tmp"; echo "ERROR could not write $f" >&2; return 2
  fi
  # Atomic rename, never an in-place rewrite (spec S10 step 3): a rewrite
  # across two operations lets a sweeper observe a truncated or absent lock,
  # classify it "names no task", delete it, and admit a third instance.
  if ! mv -f "$tmp" "$f"; then
    rm -f "$tmp"; echo "ERROR could not rename over $f" >&2; return 2
  fi
  echo "TOOK-OVER $name (from $h_holder, holder gone)"
  return 0
}

cmd_release() {
  local name=$1 holder=$2 f cur
  f=$(lock_path "$name")
  cur=$(awk '{print $1}' "$f" 2>/dev/null)
  if [ -z "$cur" ]; then echo "FREE $name"; return 0; fi
  if [ "$cur" != "$holder" ]; then
    echo "REFUSED $name is held by $cur, not $holder" >&2
    return 1
  fi
  rm -f "$f"
  echo "RELEASED $name"
}

cmd_check() {
  local name=$1 f
  f=$(lock_path "$name")
  if [ ! -f "$f" ]; then echo "FREE $name"; return 1; fi
  echo "HELD $name $(cat "$f")"
}

# S6.4. Prints one line per lock acted on. Never steals from a live holder.
cmd_sweep() {
  local f base holder pane session task ts state age nowsec tssec line live_rc
  [ -d "$LOCKS_DIR" ] || return 0

  # A liveness oracle that cannot answer must never be read as "everyone is gone".
  # Sweep is the only mass-deleting command in the system and it runs unattended
  # at session start, so one herdr outage would otherwise unlink every lock.
  # The test-hook bypass below only applies when hooks_active (SHEPHERD_TEST_HOOKS=1):
  # outside a test harness, SHEPHERD_LIVENESS_OVERRIDE/UNKNOWN merely being set
  # in the environment must never itself skip the real pane_probe check.
  if ! hooks_active || { [ -z "${SHEPHERD_LIVENESS_OVERRIDE+x}" ] && [ -z "${SHEPHERD_LIVENESS_UNKNOWN+x}" ]; }; then
    if [ -z "${HERDR_PANE_ID:-}" ] || ! pane_probe "$HERDR_PANE_ID" >/dev/null 2>&1; then
      echo "SWEEP-SKIPPED liveness oracle unavailable - no locks inspected"
      return 0
    fi
  fi

  nowsec=$(date +%s)
  for f in "$LOCKS_DIR"/*.lock; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .lock)
    line=$(head -1 "$f" 2>/dev/null)
    if [ -z "$line" ]; then
      echo "MALFORMED $base - left in place, inspect by hand"
      continue
    fi
    read -r holder pane session task ts <<<"$line"

    shepherd_live "$pane" "$session"
    live_rc=$?

    if [ "$live_rc" -eq 0 ]; then
      case $base in
        card-*|dispatch)
          tssec=""
          [ -n "$ts" ] && tssec=$(date -d "$ts" +%s 2>/dev/null)
          [ -n "$tssec" ] || tssec=$nowsec
          age=$(( nowsec - tssec ))
          if [ "$age" -gt "$LONG_HOLD_SECONDS" ]; then
            echo "LONG-HELD $base $holder ${age}s - report to the operator, never steal"
          fi
          ;;
      esac
      continue
    fi

    # Anything other than gone (1) - unresolved (2), or any
    # return code shepherd_live's contract does not promise - must never
    # reach the delete logic below. Only an explicit 1 may free a lock.
    # Deleting on an unresolved probe would free a live holder's claim on
    # nothing more than a failed round-trip - the exact defect this gate
    # exists to close.
    if [ "$live_rc" -ne 1 ]; then
      echo "UNKNOWN-LIVENESS $base $holder - cannot reach herdr for pane $pane, left in place"
      continue
    fi

    # live_rc == 1 (gone). The liveness probe above is a herdr
    # round-trip. Another instance may have swept this same lock and
    # re-acquired the name while we waited. Deleting on the stale read would
    # unlink a LIVE holder's lock and let a third instance into the same
    # checkout. The timestamp field makes each acquisition unique.
    if [ "$(head -1 "$f" 2>/dev/null)" != "$line" ]; then
      echo "CHANGED $base - re-acquired during the liveness probe, left alone"
      continue
    fi

    case $base in
      card-*|dispatch|shepherd-*)
        rm -f "$f"; echo "SWEPT $base (holder $holder gone)" ;;
      project-*)
        state=""
        [ "$task" != none ] && state=$(task_state "$task")
        case $state in
          briefed|working|blocked|review)
            echo "ORPHAN $base $task state=$state (holder $holder gone) - lock kept, worker still running" ;;
          *)
            rm -f "$f"; echo "SWEPT $base (holder $holder gone, task $task state=${state:-none})" ;;
        esac
        ;;
      *)
        echo "UNKNOWN-LOCK $base (holder $holder gone) - left in place" ;;
    esac
  done
  find "$LOCKS_DIR" -maxdepth 1 -name '.tmp.*' -mmin +60 -delete 2>/dev/null
  return 0
}

case ${1:-} in
  acquire)  shift; [ $# -ge 4 ] || usage; cmd_acquire  "$@" ;;
  takeover) shift; [ $# -ge 4 ] || usage; cmd_takeover "$@" ;;
  release)  shift; [ $# -ge 2 ] || usage; cmd_release  "$@" ;;
  check)    shift; [ $# -ge 1 ] || usage; cmd_check    "$@" ;;
  sweep)    shift; cmd_sweep ;;
  *) usage ;;
esac
