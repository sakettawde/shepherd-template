"""The wake set: ONE predicate, imported by every reader.

`shepherd-watch`'s per-task status watcher (its anchor and its poll loop) and
`shepherd-watch monitor` (the plugin monitor over the whole status directory)
both decide "is this record worth waking shepherd for" here, and nowhere else.
Two copies of this rule once drifted apart and killed the T-0090 watcher; the
manual states the single-predicate invariant, and this module is where it lives.

Records are counted, never lines: immune to an unterminated last line
(T-0079/80) and needing no `|| echo 0` (T-0090).
"""

import json

TERMINAL = {"done", "blocked", "failed"}
PARKED = {"permission_prompt", "elicitation_dialog", "agent_needs_input"}


def wake_worthy(r, task=""):
    # 0. a record that names ANOTHER task never wakes this watcher. A stray
    #    line written into the wrong status file - a partial env override in
    #    some other session (measured 2026-09-02) - must not reach shepherd as
    #    this task's claim. A record carrying no `task` field at all still
    #    counts: files written before the field existed have none.
    rt = r.get("task")
    if task and rt is not None and rt != task:
        return False
    # 1. a terminal claim - unless the stop record merely repeats a claim the
    #    status command already wrote this turn (one claim per turn, spec §1)
    if r.get("claim") in TERMINAL and r.get("claim_source") != "command":
        return True
    # 2. the worker is gone, or its turn died on an API error
    if r.get("event") in ("session_end", "stop_failure"):
        return True
    # 3. parked mid-turn on something only shepherd or the operator answers
    if r.get("event") == "notification" and r.get("kind") in PARKED:
        return True
    return False


def describe(r):
    if r.get("claim") in TERMINAL:
        return "claim %s" % r["claim"]
    return "%s %s" % (r.get("event"), r.get("kind", ""))


def records(path):
    """Every parsed JSON object in the file, in order; [] when it is missing."""
    out = []
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                try:
                    r = json.loads(raw)
                except Exception:
                    continue
                if isinstance(r, dict):
                    out.append(r)
    except FileNotFoundError:
        pass
    except OSError:
        pass
    return out
