#!/bin/sh
# shepherd worker Notification hook — logs permission/idle prompts to the task's
# status file (waking shepherd's watcher within ~2s) and raises a herdr toast.
# Registered user-globally; no-op for sessions without shepherd env vars.
[ -n "${SHEPHERD_TASK_ID:-}" ] || exit 0
[ -n "${SHEPHERD_STATUS_FILE:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

hook_input="$(mktemp "${TMPDIR:-/tmp}/shepherd-notify.XXXXXX")" || exit 0
trap 'rm -f "$hook_input"' EXIT HUP INT TERM
cat >"$hook_input" 2>/dev/null || true

SHEPHERD_HOOK_INPUT="$hook_input" python3 - <<'PY' 2>/dev/null || true
import json, os, time

data = {}
try:
    with open(os.environ["SHEPHERD_HOOK_INPUT"], encoding="utf-8") as fh:
        content = fh.read()
    if content.strip():
        data = json.loads(content)
except Exception:
    data = {}

line = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "event": "notification",
    "task": os.environ.get("SHEPHERD_TASK_ID"),
    "kind": data.get("notification_type") or data.get("matcher") or data.get("hook_event_name") or "unknown",
    "message": (data.get("message") or data.get("title") or "")[:200],
}
with open(os.environ["SHEPHERD_STATUS_FILE"], "a", encoding="utf-8") as f:
    f.write(json.dumps(line, ensure_ascii=False) + "\n")
PY

# Toast fires from inside the worker's herdr pane; static body avoids quoting traps.
if [ "${HERDR_ENV:-}" = "1" ] && command -v herdr >/dev/null 2>&1; then
  herdr notification show "$SHEPHERD_TASK_ID needs input" --body "worker is waiting on a prompt" --sound request >/dev/null 2>&1 || true
fi
exit 0
