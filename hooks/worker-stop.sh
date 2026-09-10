#!/bin/sh
# shepherd worker Stop hook — appends the turn's claim record to the task's
# status file (ground truth, CLAUDE.md §2 rule 1). Registered user-globally in
# ~/.claude/settings.json; exits instantly for any session that does not carry
# shepherd's env vars, so manual Claude sessions are unaffected.
#
# The record is written by lib/worker_stop.py: the SHEPHERD: sentinel on its
# own line (however decorated), the transcript as a fallback when the payload
# carries no message, and a claim written by shepherd-status this
# turn inherited when the message carries no sentinel. A failure to record is
# itself recorded (lib/run-hook.sh). Exit 0 always: exit 2 would block the stop.
[ -n "${SHEPHERD_TASK_ID:-}" ] || exit 0
[ -n "${SHEPHERD_STATUS_FILE:-}" ] || exit 0
HERE=$(cd "$(dirname "$0")" && pwd)

# `.` on an unreadable file aborts a POSIX shell outright - dash exits 2, and
# exit 2 from THIS hook blocks the worker's turn. So the missing library is
# reported the only way still available - a hand-built record, no helpers, with
# the same status-file-then-sidecar ladder shepherd_status.hook_error uses -
# and the hook exits 0 like every other path here.
if [ -r "$HERE/lib/run-hook.sh" ]; then
  . "$HERE/lib/run-hook.sh"
else
  now=$(date +%Y-%m-%dT%H:%M:%S%z)
  msg="hooks/lib/run-hook.sh is missing; nothing recorded"
  # The library's pair check, made here by hand: a task id that is not this
  # file's own writes nothing into it, on this path as on every other (T-0223).
  [ "${SHEPHERD_STATUS_FILE##*/}" = "$SHEPHERD_TASK_ID.jsonl" ] || { printf '%s stop SHEPHERD_TASK_ID %s is not the task of %s (expected basename %s.jsonl); %s\n' "$now" "$SHEPHERD_TASK_ID" "$SHEPHERD_STATUS_FILE" "$SHEPHERD_TASK_ID" "$msg" >>"$SHEPHERD_STATUS_FILE.err" 2>/dev/null; exit 0; }
  printf '{"ts": "%s", "event": "hook_error", "task": "%s", "kind": "stop", "message": "%s"}\n' \
    "$now" "$SHEPHERD_TASK_ID" "$msg" >>"$SHEPHERD_STATUS_FILE" 2>/dev/null \
    || printf '%s stop %s\n' "$now" "$msg" >>"$SHEPHERD_STATUS_FILE.err" 2>/dev/null
  exit 0
fi

shepherd_hook_run stop "$HERE/lib/worker_stop.py"
exit 0
