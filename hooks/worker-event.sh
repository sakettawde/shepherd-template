#!/bin/sh
# shepherd worker event hook — one script registered under four Claude Code
# events (the init skill step 4): PermissionRequest, PermissionDenied,
# StopFailure, SessionEnd. Each becomes one status-file record with `event`
# naming the hook and `kind` its sub-type (tool name, tool name, error type,
# end reason), written by lib/worker_event.py. Records only: it returns no
# decision and never blocks - exit 2 is not honoured for any of the four, and
# nothing here relies on the exit code anyway. Registered user-globally; no-op
# for sessions without shepherd env vars. A failure to record is itself
# recorded (lib/run-hook.sh).
[ -n "${SHEPHERD_TASK_ID:-}" ] || exit 0
[ -n "${SHEPHERD_STATUS_FILE:-}" ] || exit 0
HERE=$(cd "$(dirname "$0")" && pwd)

# `.` on an unreadable file aborts a POSIX shell outright - dash exits 2. This
# hook's four events do not honour exit 2, but the wrapper shape is shared with
# the Stop hook, where exit 2 blocks the worker's turn - so the missing library
# is reported the only way still available here too: a hand-built record, no
# helpers, with the same status-file-then-sidecar ladder
# shepherd_status.hook_error uses - and the hook exits 0 like every other path.
if [ -r "$HERE/lib/run-hook.sh" ]; then
  . "$HERE/lib/run-hook.sh"
else
  now=$(date +%Y-%m-%dT%H:%M:%S%z)
  msg="hooks/lib/run-hook.sh is missing; nothing recorded"
  # The library's pair check, made here by hand: a task id that is not this
  # file's own writes nothing into it, on this path as on every other (T-0223).
  [ "${SHEPHERD_STATUS_FILE##*/}" = "$SHEPHERD_TASK_ID.jsonl" ] || { printf '%s event SHEPHERD_TASK_ID %s is not the task of %s (expected basename %s.jsonl); %s\n' "$now" "$SHEPHERD_TASK_ID" "$SHEPHERD_STATUS_FILE" "$SHEPHERD_TASK_ID" "$msg" >>"$SHEPHERD_STATUS_FILE.err" 2>/dev/null; exit 0; }
  printf '{"ts": "%s", "event": "hook_error", "task": "%s", "kind": "event", "message": "%s"}\n' \
    "$now" "$SHEPHERD_TASK_ID" "$msg" >>"$SHEPHERD_STATUS_FILE" 2>/dev/null \
    || printf '%s event %s\n' "$now" "$msg" >>"$SHEPHERD_STATUS_FILE.err" 2>/dev/null
  exit 0
fi

shepherd_hook_run event "$HERE/lib/worker_event.py"
exit 0
