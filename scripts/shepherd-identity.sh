#!/usr/bin/env bash
# Identity claim for one shepherd instance.
# See docs/specs/multi-shepherd-design.md S3.
#
#   shepherd-identity.sh acquire [<id>]   # <id> defaults to $SHEPHERD_ID, then shepherd-1
#   shepherd-identity.sh touch   [<id>]   # refresh last_seen
#
# The identity LOCK is the authority. The registration JSON is advisory and is
# never deleted by another instance.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/lib/shepherd-common.sh"

usage() { sed -n '3,7p' "$0" >&2; exit 2; }

resolve() {
  id=${1:-${SHEPHERD_ID:-shepherd-1}}
  # The `shepherd-` prefix is load-bearing, not decoration: lock.sh sweep
  # recognises an identity lock by its `shepherd-*` glob, so an id without it
  # would be swept as UNKNOWN-LOCK and never cleaned up. The suffix is
  # lowercase alphanumeric words joined by single hyphens — that admits
  # shepherd-1 and shepherd-blue alike while still rejecting whitespace,
  # shell metacharacters and path traversal (an id containing `/` once wrote
  # its lock outside LOCKS_DIR, where sweep could never find it).
  if ! [[ $id =~ ^shepherd-[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "ERROR: bad shepherd id: $id (want shepherd-<name>, lowercase letters/digits, e.g. shepherd-1 or shepherd-blue)" >&2
    exit 2
  fi
  [ "${HERDR_ENV:-0}" = "1" ] || { echo "ERROR: not inside herdr" >&2; exit 2; }
  pane=${HERDR_PANE_ID:-}
  [ -n "$pane" ] || { echo "ERROR: HERDR_PANE_ID unset" >&2; exit 2; }
  session=$(pane_session "$pane") || { echo "ERROR: no agent session on $pane" >&2; exit 2; }
}

# write_registration <new|touch> — propagates python3's exit code, so a
# caller that ignores it does not silently believe it registered.
write_registration() {
  mkdir -p "$SHEPHERDS_DIR" || return 1
  python3 - "$SHEPHERDS_DIR/$id.json" "$id" "$pane" "$session" "$(now_iso)" "$1" <<'PY'
import json, os, sys
path, sid, pane, session, now, mode = sys.argv[1:7]
data = {"id": sid, "pane": pane, "session": session,
        "remote_control": sid, "started": now, "last_seen": now}
if mode == "touch" and os.path.exists(path):
    try:
        old = json.load(open(path))
        data["started"] = old.get("started", now)
    except Exception:
        pass
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
}

cmd_acquire() {
  resolve "${1:-}"
  local f="$LOCKS_DIR/$id.lock" reclaim="$id.reclaim"
  local line h_holder h_pane h_session acq_rc live_rc r_out r_rc

  bash "$HERE/lock.sh" acquire "$id" "$id" "$pane" "$session" none >/dev/null 2>&1
  acq_rc=$?
  if [ "$acq_rc" -eq 0 ]; then
    if ! write_registration new; then
      echo "ERROR: acquired $id but could not write its registration" >&2
      return 2
    fi
    echo "IDENTITY $id pane=$pane session=$session"
    return 0
  fi
  if [ "$acq_rc" -ne 1 ]; then
    echo "ERROR: could not write lock for $id" >&2
    return 2
  fi

  # acq_rc == 1: the id is already held. Sample the exact line we will act
  # on now, before anything else runs - the reclaim path below re-verifies
  # this exact line is still there before it deletes anything. A vanished
  # or short-field lock file is reported and left alone, never stolen.
  line=$(head -1 "$f" 2>/dev/null)
  h_holder= h_pane= h_session=
  if [ -n "$line" ]; then
    read -r h_holder h_pane h_session _ <<<"$line"
  fi
  if [ -z "$h_pane" ] || [ -z "$h_session" ]; then
    echo "MALFORMED $id.lock - left in place, inspect by hand" >&2
    return 1
  fi

  if [ "$h_pane" = "$pane" ] && [ "$h_session" = "$session" ]; then
    if ! write_registration touch; then
      echo "ERROR: still hold $id but could not write its registration" >&2
      return 2
    fi
    echo "IDENTITY $id pane=$pane session=$session (already mine)"
    return 0
  fi

  shepherd_live "$h_pane" "$h_session"
  live_rc=$?
  if [ "$live_rc" -ne 1 ]; then
    # Only an explicit 1 (gone) authorises a takeover, the
    # same safe polarity lock.sh's sweep uses. Live (0), unresolved (2),
    # and any code shepherd_live's contract does not promise must all
    # refuse. Two sessions running as the same shepherd id, each believing
    # it owns the other's tasks, is exactly what this lock exists to
    # prevent, and an unresolved probe is not evidence that the holder is gone.
    if [ "$live_rc" -eq 0 ]; then
      echo "REFUSE: $id is already live in pane $h_pane (session $h_session). Launch with a different SHEPHERD_ID." >&2
    else
      echo "REFUSE: $id's holder (pane $h_pane, session $h_session) is unresolved - refusing to guess. Launch with a different SHEPHERD_ID." >&2
    fi
    return 1
  fi

  # live_rc == 1: the holder looked gone a moment ago.
  # shepherd_live made a subprocess round-trip (mktemp + herdr + python3);
  # another instance may have sampled this same gone holder and be mid-
  # takeover right now, or have already finished. A reclaim lock plus a
  # re-read closes that window - the same compare-before-delete pattern
  # lock.sh's own sweep uses for exactly this race (S6.4). Only the
  # instance holding the reclaim lock may delete-then-create the identity
  # lock, and only if the line it sampled is still there. shepherd-* (this
  # reclaim lock's name is "$id.reclaim") already matches sweep's arm, so
  # one orphaned by a crash gets cleaned up like any other identity lock.
  #
  # `takeover`, not `acquire`: a takeover that dies between these two steps
  # leaves the reclaim lock behind, and a plain acquire would then refuse
  # every future boot of this id - naming a rival that does not exist. The
  # only cleaner is `lock.sh sweep`, which runs at session-start step 3,
  # AFTER identity at step 2 tells the shepherd to stop, so for a solo
  # shepherd-1 nothing would ever clear it. takeover resolves the reclaim
  # holder's liveness and takes it only on a gone answer -
  # never on age, never on "unresolved" - so a live rival still wins.
  r_out=$(bash "$HERE/lock.sh" takeover "$reclaim" "$id" "$pane" "$session" none 2>&1)
  r_rc=$?
  if [ "$r_rc" -ne 0 ]; then
    echo "REFUSE: another instance is already reclaiming $id ($r_out)" >&2
    return 1
  fi

  if [ "$(head -1 "$f" 2>/dev/null)" != "$line" ]; then
    bash "$HERE/lock.sh" release "$reclaim" "$id" >/dev/null 2>&1
    echo "REFUSE: $id changed hands while its holder was probed" >&2
    return 1
  fi

  rm -f "$f"
  if ! bash "$HERE/lock.sh" acquire "$id" "$id" "$pane" "$session" none >/dev/null 2>&1; then
    bash "$HERE/lock.sh" release "$reclaim" "$id" >/dev/null 2>&1
    echo "REFUSE: lost the race for $id" >&2
    return 1
  fi

  # Read our own claim back and confirm it names this pane and session.
  # The reclaim lock already serialises every patched instance through
  # this path one at a time, so this should always hold - it is the
  # cheapest possible check against anything that slipped past it.
  h_holder= h_pane= h_session=
  read -r h_holder h_pane h_session _ < "$f" 2>/dev/null || true
  if [ "$h_pane" != "$pane" ] || [ "$h_session" != "$session" ]; then
    bash "$HERE/lock.sh" release "$reclaim" "$id" >/dev/null 2>&1
    echo "REFUSE: $id was re-acquired by another instance" >&2
    return 1
  fi

  bash "$HERE/lock.sh" release "$reclaim" "$id" >/dev/null 2>&1
  if ! write_registration new; then
    echo "ERROR: took over $id but could not write its registration" >&2
    return 2
  fi
  echo "IDENTITY $id pane=$pane session=$session (took over from a gone instance)"
  return 0
}

cmd_touch() {
  resolve "${1:-}"
  local f="$LOCKS_DIR/$id.lock" h_holder h_pane h_session
  h_holder= h_pane= h_session=

  if [ ! -f "$f" ]; then
    echo "REFUSE: $id has no identity lock to touch" >&2
    return 1
  fi
  read -r h_holder h_pane h_session _ < "$f" 2>/dev/null || true
  if [ -z "$h_pane" ] || [ -z "$h_session" ]; then
    echo "MALFORMED $id.lock - left in place, inspect by hand" >&2
    return 1
  fi
  if [ "$h_pane" != "$pane" ] || [ "$h_session" != "$session" ]; then
    echo "REFUSE: $id is held by pane $h_pane (session $h_session), not this instance." >&2
    return 1
  fi

  if ! write_registration touch; then
    echo "ERROR: hold $id but could not write its registration" >&2
    return 2
  fi
  echo "TOUCHED $id"
}

case ${1:-} in
  acquire) shift; cmd_acquire "${1:-}" ;;
  touch)   shift; cmd_touch   "${1:-}" ;;
  *) usage ;;
esac
