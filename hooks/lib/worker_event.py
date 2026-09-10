"""Event hook: PermissionRequest, PermissionDenied, StopFailure and SessionEnd,
one record each, `event` naming the hook and `kind` its sub-type. Records
only - it returns no decision, so nothing here changes what Claude Code does
(spec §2; hooks reference https://code.claude.com/docs/en/hooks, read 2026-09-02)."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shepherd_status as st  # noqa: E402

SUMMARY_KEYS = ("command", "file_path", "notebook_path", "url", "pattern", "prompt")


def summary_of(tool_input):
    """What the tool was asked to do, in one clipped string."""
    if isinstance(tool_input, dict):
        for key in SUMMARY_KEYS:
            value = tool_input.get(key)
            if isinstance(value, str) and value:
                return st.clip(value, 200)
        return st.clip(json.dumps(tool_input, ensure_ascii=False, sort_keys=True), 200)
    return st.clip(json.dumps(tool_input, ensure_ascii=False), 200)


def permission_record(event, data):
    line = st.record(
        event,
        kind=str(data.get("tool_name") or "unknown"),
        session_id=data.get("session_id"),
        tool_use_id=data.get("tool_use_id"),
        summary=summary_of(data.get("tool_input")),
    )
    if event == "permission_denied":
        line["reason"] = st.clip(data.get("denial_reason") or "", 200)
    # A subagent's dialog parks the whole worker, so it is recorded, and
    # labelled so a reader can tell it from the main thread's.
    if data.get("agent_id"):
        line["agent_id"] = data["agent_id"]
        line["agent_type"] = data.get("agent_type")
    return line


def main():
    data, why = st.read_input()
    if why:
        st.hook_error("event", why)
        return 0
    name = data.get("hook_event_name")
    if name == "PermissionRequest":
        line = permission_record("permission_request", data)
    elif name == "PermissionDenied":
        line = permission_record("permission_denied", data)
    elif name == "StopFailure":
        line = st.record(
            "stop_failure",
            kind=str(data.get("error_type") or "unknown"),
            session_id=data.get("session_id"),
            message=st.clip(data.get("error_message") or "", 200),
            tail=st.tail(data.get("last_assistant_message") or "", 400),
        )
    elif name == "SessionEnd":
        line = st.record(
            "session_end",
            kind=str(data.get("reason") or "unknown"),
            session_id=data.get("session_id"),
            turn_count=data.get("turn_count"),
        )
    else:
        st.hook_error("event", "unhandled hook event: %r" % (name,))
        return 0
    return st.emit("event", line)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - report, never block
        st.hook_error("event", "unexpected: %r" % (exc,))
        sys.exit(0)
