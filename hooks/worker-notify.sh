#!/bin/sh
# shepherd worker Notification hook — logs every notification to the task's
# status file (waking shepherd's watcher within ~2s) and raises a herdr toast
# for the kinds that actually need the operator (see the allowlist below).
# Registered user-globally; no-op for sessions without shepherd env vars.
[ -n "${SHEPHERD_TASK_ID:-}" ] || exit 0
[ -n "${SHEPHERD_STATUS_FILE:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

hook_input="$(mktemp "${TMPDIR:-/tmp}/shepherd-notify.XXXXXX")" || exit 0
kind_file="$(mktemp "${TMPDIR:-/tmp}/shepherd-notify-kind.XXXXXX")" || exit 0
trap 'rm -f "$hook_input" "$kind_file"' EXIT HUP INT TERM
cat >"$hook_input" 2>/dev/null || true

SHEPHERD_HOOK_INPUT="$hook_input" SHEPHERD_KIND_FILE="$kind_file" python3 - <<'PY' 2>/dev/null || true
import json, os, time

data = {}
try:
    with open(os.environ["SHEPHERD_HOOK_INPUT"], encoding="utf-8") as fh:
        content = fh.read()
    if content.strip():
        data = json.loads(content)
except Exception:
    data = {}

kind = data.get("notification_type") or data.get("matcher") or data.get("hook_event_name") or "unknown"

# The docs show the body in two shapes for this one event: flat `message`/`title`
# ("Notification Hook Input Data") and nested under `notification_data`
# (Notification reference, both read 2026-08-23 at
# https://code.claude.com/docs/en/hooks). Read both - the kind alone does not say
# WHICH permission or WHICH agent, and that is what the operator needs.
nested = data.get("notification_data")
nested = nested if isinstance(nested, dict) else {}
message = (data.get("message") or data.get("title")
           or nested.get("message") or nested.get("title") or "")

line = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "event": "notification",
    "task": os.environ.get("SHEPHERD_TASK_ID"),
    "kind": kind,
    "message": message[:200],
}
with open(os.environ["SHEPHERD_STATUS_FILE"], "a", encoding="utf-8") as f:
    f.write(json.dumps(line, ensure_ascii=False) + "\n")

# Hand the kind to the shell, which decides whether it is worth a toast.
with open(os.environ["SHEPHERD_KIND_FILE"], "w", encoding="utf-8") as f:
    f.write(kind)
PY

# Every kind gets the status line above; only these three get the operator's
# attention. `idle_prompt` is 165 of 194 recorded notifications and is routine
# noise - a fable worker driving background subagents emits one at every turn
# boundary while a subagent runs, then self-resumes (adapter v0.8.2, R5 notes).
# An allowlist, not a denylist: a kind nobody has classified is not an alarm.
# `agent_completed` is recorded and deliberately NOT toasted: a finished worker
# is the watcher's business (adapter R5), not an interruption for the operator.
kind=$(cat "$kind_file" 2>/dev/null)
case "$kind" in
  permission_prompt|elicitation_dialog|agent_needs_input) ;;
  *) exit 0 ;;
esac

# Toast fires from inside the worker's herdr pane; static body avoids quoting traps.
if [ "${HERDR_ENV:-}" = "1" ] && command -v herdr >/dev/null 2>&1; then
  herdr notification show "$SHEPHERD_TASK_ID needs input" --body "worker is waiting on a prompt" --sound request >/dev/null 2>&1 || true
fi
exit 0
