"""Stop hook: turns the worker's final message into the turn's claim record.
See shepherd_status.py for the file contract."""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shepherd_status as st  # noqa: E402

# The sentinel is a LINE, and only the last one counts. Matching anywhere in
# the message records a claim from a worker that merely wrote *about* one
# (T-0093). `working` is admitted as a non-terminal checkpoint - the watcher
# (shepherd-watch) never wakes on it.
#
# Everything a worker has been seen to put in front of the sentinel is
# skipped: blockquote `>`, a `-`/`*`/`+` bullet, a `1.` number, and up to four
# emphasis/backtick characters - before the label, between the label and the
# word, and around the word (T-0213: a backticked line recorded "none";
# T-0214: `> SHEPHERD:`, `- SHEPHERD:` and `SHEPHERD: **done**` did too).
# Horizontal-whitespace classes only: \s would let the anchor step over a
# newline and match a claim word on the following line.
SENTINEL = re.compile(
    r"(?m)^[ \t]*(?:>[ \t]*|[-*+][ \t]+|\d+[.)][ \t]+)*"
    r"[`*_]{0,4}SHEPHERD:[`*_]{0,4}[ \t]*[`*_]{0,4}(done|blocked|failed|working)\b"
)
CLAIMS = ("done", "blocked", "failed", "working")

# A worker that PRINTS the status command instead of running it (T-0244: a
# finished turn, PR open, ending `shepherd-status done "…"` as display text)
# used to record `claim: none` - nothing for the watcher to fire on, so the
# done work waited two 1800 s heartbeats. So the command's own shape, written
# on a line, is a third claim path. It is a SHAPE, never the literal: the
# claim word and a quoted one-liner must fill the line, because a brief, a
# plan and this repo's own docs all say the word `shepherd-status` in prose.
# The decoration tolerated is the sentinel's, for the same reason.
#
# `claim_source: printed` is what makes this cheap: shepherd verifies every
# claim from four sources anyway (the manual §2 rule 1), so a wrong printed
# claim costs one verification wake while a missed one costs two heartbeats.
# That trade only holds against `none`, which is why this path is the LAST one
# main() tries - see there.
#
# Two narrowings the sentinel does not need, because a shape inferred from an
# example is not a label a worker deliberately wrote:
#   * a `1.` NUMBERED prefix is not decoration here. `1. SHEPHERD: done` is a
#     bulleted claim; `3. shepherd-status done "..."` is step 3 of a plan.
#   * a PLACEHOLDER one-liner - `"<one short line>"`, `"<question>"` - is the
#     template being quoted, never a claim. It is the exact text of
#     templates/task-card.md, so a worker paraphrasing its own Brief trips
#     every other part of this shape.
# Typographic quotes are admitted because a worker writing prose reaches for
# them, and a curly-quoted line is still a line nobody ran.
PRINTED = re.compile(
    r"(?m)^[ \t]*(?:>[ \t]*|[-*+][ \t]+)*"
    r"[`*_]{0,4}shepherd-status[ \t]+[`*_]{0,4}(?P<claim>done|blocked|failed|working)"
    r"[`*_]{0,4}[ \t]+"
    r"(?:\"(?P<d>(?!<[^\"]*>\")[^\"]+)\"|'(?P<s>(?!<[^']*>')[^']+)'"
    r"|\u201c(?P<D>(?!<[^\u201d]*>\u201d)[^\u201d]+)\u201d"
    r"|\u2018(?P<S>(?!<[^\u2019]*>\u2019)[^\u2019]+)\u2019)"
    r"[`*_]{0,4}[ \t]*$"
)


def printed_claims_in(text):
    return [m.group("claim") for m in PRINTED.finditer(text or "")]


def claims_in(text):
    return SENTINEL.findall(text or "")


def transcript_message(path):
    """The text of the last assistant entry in a transcript JSONL, or ''."""
    if not path or not os.path.isfile(path):
        return ""
    last = ""
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                try:
                    entry = json.loads(raw)
                except Exception:  # noqa: BLE001
                    continue
                if not isinstance(entry, dict) or entry.get("type") != "assistant":
                    continue
                msg = entry.get("message") or {}
                content = msg.get("content") if isinstance(msg, dict) else None
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    text = "\n".join(b.get("text", "") for b in content
                                     if isinstance(b, dict) and b.get("type") == "text")
                else:
                    text = ""
                if text.strip():
                    last = text
    except Exception:  # noqa: BLE001
        return ""
    return last


def command_claim_this_turn():
    """The claim shepherd-status wrote since the previous stop
    record, or None. A `stop` record resets the search: inheritance never
    reaches into an earlier turn."""
    claim = None
    try:
        with open(st.STATUS_FILE, encoding="utf-8") as fh:
            for raw in fh:
                try:
                    entry = json.loads(raw)
                except Exception:  # noqa: BLE001
                    continue
                if not isinstance(entry, dict):
                    continue
                if entry.get("event") == "stop":
                    claim = None
                elif entry.get("event") == "claim" and entry.get("claim") in CLAIMS:
                    claim = entry["claim"]
    except Exception:  # noqa: BLE001 - no file yet, or unreadable: no inheritance
        return None
    return claim


def main():
    data, why = st.read_input()
    if why:
        st.hook_error("stop", why)
        return 0
    # Subagent completions must never speak for the worker itself.
    if data.get("agent_id") or data.get("hook_event_name") == "SubagentStop":
        return 0

    msg = data.get("last_assistant_message") or ""
    source = "sentinel"
    if not msg.strip():
        # The docs call the transcript a lagging copy; it is the fallback for a
        # payload that carries no message at all, never the primary.
        msg = transcript_message(data.get("transcript_path"))
        source = "transcript"
    found = claims_in(msg)
    if found:
        claim = found[-1]
    else:
        claim = command_claim_this_turn()
        if claim:
            # A claim the worker RAN outranks one merely printed, and the
            # sentinel outranks both. Order is the whole safety of the printed
            # path: it is inferred from a shape that a quoted example, a plan
            # step or a diff hunk can wear, so letting it overwrite an executed
            # claim would report a `blocked` worker `done` - corrupting ground
            # truth ① to save a heartbeat. Last resort, or nothing.
            source = "command"
        else:
            printed = printed_claims_in(msg)
            claim = printed[-1] if printed else "none"
            # `transcript` keeps its name: that the payload carried no message
            # is what monitor needs first, and the sentinel path collapses the
            # same way.
            if printed:
                source = source if source == "transcript" else "printed"
            else:
                source = "none"

    line = st.record(
        "stop",
        session_id=data.get("session_id"),
        transcript_path=data.get("transcript_path"),
        stop_reason=data.get("stop_reason"),
        permission_mode=data.get("permission_mode"),
        claim=claim,
        claim_source=source,
        tail=st.tail(msg, 400),
    )
    return st.emit("stop", line)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - report, never block the worker's stop
        st.hook_error("stop", "unexpected: %r" % (exc,))
        sys.exit(0)
