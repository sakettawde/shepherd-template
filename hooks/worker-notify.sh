#!/bin/sh
# shepherd worker Notification hook — logs every notification to the task's
# status file (waking shepherd's watcher within ~2s for the parked-worker
# kinds, shepherd-watch) and raises a herdr toast for the kinds that need the
# operator (see the allowlist below). Registered user-globally; no-op for
# sessions without shepherd env vars. The record is written by
# lib/worker_notify.py; a failure to record is itself recorded (lib/run-hook.sh).
[ -n "${SHEPHERD_TASK_ID:-}" ] || exit 0
[ -n "${SHEPHERD_STATUS_FILE:-}" ] || exit 0
HERE=$(cd "$(dirname "$0")" && pwd)

# `.` on an unreadable file aborts a POSIX shell outright - dash exits 2, and a
# Stop hook on this same wrapper shape exiting 2 would BLOCK the worker's turn.
# So the missing library is reported the only way still available - a hand-built
# record, no helpers, with the same status-file-then-sidecar ladder
# shepherd_status.hook_error uses - and the hook exits 0 like every other path
# here. The sidecar arm is not decoration: the status file being unwritable is
# exactly when a watcher can never fire, and without it that outage is silent.
if [ -r "$HERE/lib/run-hook.sh" ]; then
  . "$HERE/lib/run-hook.sh"
else
  now=$(date +%Y-%m-%dT%H:%M:%S%z)
  msg="hooks/lib/run-hook.sh is missing; nothing recorded"
  # The library's pair check, made here by hand: a task id that is not this
  # file's own writes nothing into it, on this path as on every other (T-0223).
  [ "${SHEPHERD_STATUS_FILE##*/}" = "$SHEPHERD_TASK_ID.jsonl" ] || { printf '%s notify SHEPHERD_TASK_ID %s is not the task of %s (expected basename %s.jsonl); %s\n' "$now" "$SHEPHERD_TASK_ID" "$SHEPHERD_STATUS_FILE" "$SHEPHERD_TASK_ID" "$msg" >>"$SHEPHERD_STATUS_FILE.err" 2>/dev/null; exit 0; }
  printf '{"ts": "%s", "event": "hook_error", "task": "%s", "kind": "notify", "message": "%s"}\n' \
    "$now" "$SHEPHERD_TASK_ID" "$msg" >>"$SHEPHERD_STATUS_FILE" 2>/dev/null \
    || printf '%s notify %s\n' "$now" "$msg" >>"$SHEPHERD_STATUS_FILE.err" 2>/dev/null
  exit 0
fi

kind=$(shepherd_hook_run notify "$HERE/lib/worker_notify.py")

# Every kind gets a status record; only these three get the operator's
# attention. `idle_prompt` is the bulk of recorded notifications and is routine
# noise - a worker driving background subagents emits one at every turn
# boundary while a subagent runs, then self-resumes (adapter v0.8.2, R5 notes).
# An allowlist, not a denylist: a kind nobody has classified is not an alarm.
# `agent_completed` is recorded and deliberately NOT toasted: a finished worker
# is the watcher's business (adapter R5), not an interruption for the operator.
case "$kind" in
  permission_prompt|elicitation_dialog|agent_needs_input) ;;
  *) exit 0 ;;
esac

# Toast fires from inside the worker's herdr pane; static body avoids quoting traps.
if [ "${HERDR_ENV:-}" = "1" ] && command -v herdr >/dev/null 2>&1; then
  herdr notification show "$SHEPHERD_TASK_ID needs input" --body "worker is waiting on a prompt" --sound request >/dev/null 2>&1 || true
fi
exit 0
