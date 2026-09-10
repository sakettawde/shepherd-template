"""Shared code for shepherd's worker hooks. Imported by the per-hook programs
in this directory (worker_stop.py, worker_notify.py, worker_event.py); never
run on its own.

Every hook appends one JSON object per line to $SHEPHERD_STATUS_FILE, the
task's ground-truth status file (CLAUDE.md §2 rule 1). A hook that cannot do
its job says so in the same file (event "hook_error"), or in the sidecar
"<status-file>.err" when the status file itself cannot be written, or on
stderr as the last resort — never silently. Nothing here raises past main().
"""
import json
import os
import sys
import time

TASK = os.environ.get("SHEPHERD_TASK_ID", "")
STATUS_FILE = os.environ.get("SHEPHERD_STATUS_FILE", "")


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def clip(text, n):
    """The first n characters of text ('' for None)."""
    return ("" if text is None else str(text))[:n]


def tail(text, n):
    """The last n characters of text ('' for None)."""
    return ("" if text is None else str(text))[-n:]


def read_input():
    """The hook payload from stdin: (dict, None), or ({}, why) when unusable."""
    try:
        raw = sys.stdin.read()
    except Exception as exc:  # noqa: BLE001 - a hook reports, never raises
        return {}, "stdin unreadable: %s" % exc
    if not raw.strip():
        return {}, "empty stdin"
    try:
        data = json.loads(raw)
    except Exception as exc:  # noqa: BLE001
        return {}, "stdin is not JSON: %s" % clip(exc, 120)
    if not isinstance(data, dict):
        return {}, "stdin JSON is not an object"
    return data, None


def record(event, **fields):
    """A status record: ts, event and task first, then the event's fields."""
    line = {"ts": now(), "event": event, "task": TASK}
    line.update(fields)
    return line


def append(line):
    """Append one record. None on success, else the reason."""
    try:
        with open(STATUS_FILE, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(line, ensure_ascii=False) + "\n")
        return None
    except Exception as exc:  # noqa: BLE001
        return "cannot write %s: %s" % (STATUS_FILE, clip(exc, 120))


def hook_error(kind, message):
    """Record a hook failure where shepherd will read it. Never raises."""
    line = record("hook_error", kind=kind, message=clip(message, 200))
    if append(line) is None:
        return
    try:
        with open(STATUS_FILE + ".err", "a", encoding="utf-8") as fh:
            fh.write("%s %s %s\n" % (line["ts"], kind, line["message"]))
    except Exception:  # noqa: BLE001
        sys.stderr.write("shepherd hook %s: %s\n" % (kind, line["message"]))


def emit(kind, line):
    """Append line, or report why it could not be. Always 0: hooks never block."""
    err = append(line)
    if err:
        hook_error(kind, err)
    return 0
