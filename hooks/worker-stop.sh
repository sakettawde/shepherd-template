#!/bin/sh
# shepherd worker Stop hook — appends a ground-truth event line to the task's status file.
# Registered user-globally in ~/.claude/settings.json; exits instantly for any session
# that does not carry shepherd's env vars, so manual Claude sessions are unaffected.
[ -n "${SHEPHERD_TASK_ID:-}" ] || exit 0
[ -n "${SHEPHERD_STATUS_FILE:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Spool the hook JSON from stdin to a file: `python3 -` reads the *program* from
# stdin, so the payload must travel via file instead (same pattern as herdr's hook).
hook_input="$(mktemp "${TMPDIR:-/tmp}/shepherd-stop.XXXXXX")" || exit 0
trap 'rm -f "$hook_input"' EXIT HUP INT TERM
cat >"$hook_input" 2>/dev/null || true

SHEPHERD_HOOK_INPUT="$hook_input" python3 - <<'PY' 2>/dev/null || true
import json, os, re, time

data = {}
try:
    with open(os.environ["SHEPHERD_HOOK_INPUT"], encoding="utf-8") as fh:
        content = fh.read()
    if content.strip():
        data = json.loads(content)
except Exception:
    data = {}

# Subagent completions must never speak for the worker itself.
if data.get("agent_id") or data.get("hook_event_name") == "SubagentStop":
    raise SystemExit(0)

msg = data.get("last_assistant_message") or ""
claims = re.findall(r"SHEPHERD:\s*(done|blocked|failed)", msg)

line = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "event": "stop",
    "task": os.environ.get("SHEPHERD_TASK_ID"),
    "session_id": data.get("session_id"),
    "transcript_path": data.get("transcript_path"),
    "stop_reason": data.get("stop_reason"),
    "permission_mode": data.get("permission_mode"),
    "claim": claims[-1] if claims else "none",
    "tail": msg[-400:],
}
with open(os.environ["SHEPHERD_STATUS_FILE"], "a", encoding="utf-8") as f:
    f.write(json.dumps(line, ensure_ascii=False) + "\n")
PY
exit 0
