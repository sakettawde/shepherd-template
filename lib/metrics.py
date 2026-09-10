#!/usr/bin/env python3
"""Engine behind shepherd-metrics: the introspection numbers recomputed from the ledger.

Stdlib only. Read-only. The measure definitions live in shepherd-metrics's header
(`shepherd-metrics --help`); this file implements them and nothing else.

    metrics.py --root <root> [--memory-index <path>] (week|all|since <date>) [--json] [--now <iso>]
"""
import argparse
import json
import math
import os
import re
import statistics
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

ACTIVE_STATES = {"briefed", "working", "blocked", "review"}
CARD_NAME = re.compile(r"^(T-\d{4})\.md$")
SELF_PROJECT = re.compile(r"^shepherd(?:-[a-z0-9-]+)?(?:~\d+)?$|^shepherd \(self\)$")


# ------------------------------------------------------------------ helpers

def parse_ts(value):
    """ISO-8601 text -> aware UTC datetime, or None. Naive values are local time."""
    if not value:
        return None
    s = str(value).strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        d = datetime.fromisoformat(s)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.astimezone()
    return d.astimezone(timezone.utc)


def pct(part, whole):
    return round(100.0 * part / whole, 1) if whole else None


def state_of(card):
    words = (card["fields"].get("state") or "").split()
    return words[0] if words else ""


def is_done(card):
    return state_of(card) == "done"


def in_window(event, now):
    """Is this status event at or before `now`?

    An event whose `ts` cannot be read can be placed on neither side of the edge,
    so it keeps the count it has always had rather than being silently dropped.
    """
    ts = parse_ts(event.get("ts"))
    return ts is None or ts <= now


# ------------------------------------------------------------------ loaders

def load_cards(root):
    """{id: {"id", "fields", "log"}} for every real card under ledger/tasks/.

    Header fields are the `key: value` lines before `## Log`; the first occurrence wins.
    `size:` shares its line with `tier:` and `budget:`, so those two are searched for
    separately and `size` is cut to its first word. A one-line reservation
    (`reserved-by: …`) is not a card.
    """
    cards = {}
    tasks = os.path.join(root, "ledger", "tasks")
    if not os.path.isdir(tasks):
        return cards
    for name in sorted(os.listdir(tasks)):
        m = CARD_NAME.match(name)
        if not m:
            continue
        with open(os.path.join(tasks, name), encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        if text.startswith("reserved-by:"):
            continue
        head, _, log = text.partition("\n## Log")
        fields = {}
        for line in head.splitlines():
            fm = re.match(r"^([a-z][a-z-]*):\s*(.*)$", line)
            if fm:
                fields.setdefault(fm.group(1), fm.group(2).strip())
        for key in ("tier", "budget"):
            km = re.search(r"(?:^|\s)%s:\s*(\S+)" % key, head, re.M)
            if km:
                fields.setdefault(key, km.group(1))
        if "size" in fields:
            fields["size"] = (fields["size"].split() or [""])[0]
        cards[m.group(1)] = {"id": m.group(1), "fields": fields, "log": log}
    return cards


def select_cards(cards, since_utc, now):
    """The cards whose `created:` falls inside the window.

    Two edges, and `now` is the right one in every mode — `all` included, so a run
    with a backdated `--now` reports the ledger as it stood at that instant rather
    than as it stands today. `since_utc` is the left edge, absent in `all`.
    A card whose `created:` cannot be read belongs to no window and is selected in
    no mode; the filter line's `undated` count, and the cards row's `created`
    missing bucket, are where it stays visible.
    """
    out = {}
    for tid, card in cards.items():
        created = parse_ts(card["fields"].get("created"))
        if created is None or created > now:
            continue
        if since_utc is not None and created < since_utc:
            continue
        out[tid] = card
    return out


# ----------------------------------------------------------------- measures

def measure_cards(cards, undated):
    states = Counter()
    # `undated` is counted over the whole ledger, not over the selection: a card
    # whose `created:` cannot be read is never selected (select_cards), so counting
    # it here is the only way the cards row can report it at all.
    missing = Counter(state=0, created=undated)
    self_n = 0
    for card in cards.values():
        st = state_of(card)
        if st:
            states[st] += 1
        else:
            missing["state"] += 1
        if SELF_PROJECT.match(card["fields"].get("project", "")):
            self_n += 1
    total = len(cards)
    return {
        "total": total,
        "by_state": dict(sorted(states.items())),
        "done": states["done"],
        "failed": states["failed"],
        "abandoned": states["abandoned"],
        "self_maintenance": self_n,
        "self_maintenance_pct": pct(self_n, total),
        "missing": dict(missing),
    }


DURATION = re.compile(r"[~≈]?(\d+(?:\.\d+)?)h(?:\s?(\d+)m)?(?:\d+s)?\b|[~≈]?(\d+)m(?:\d+s)?\b")
BUDGET = re.compile(r"^(\d+)m$")


def last_metrics_line(log):
    """The last Log line carrying `metrics:` — the close-out line retro wrote.

    A Log line starts with `- HH:MM` or, in 16 live cards, the bare `HH:MM` of
    CLAUDE.md §5; both count. Anything else carrying the word is prose.
    """
    found = None
    for line in log.splitlines():
        first = line.lstrip()[:1]
        if first and first in "-0123456789" and "metrics:" in line:
            found = line
    return found


def parse_duration(line):
    """Minutes from the first NhNm token after `duration`, else the first after `metrics:`.

    Decimal hours (`12.5h`) and a space before the minutes (`2h 30m`) are read;
    a trailing seconds suffix (`9m33s`) is accepted and dropped.
    """
    body = line.split("metrics:", 1)[1] if "metrics:" in line else line
    dm = re.search(r"\bduration\b", body)
    if dm:
        body = body[dm.end():]
    tok = DURATION.search(body)
    if not tok:
        return None
    hours, hmin, mins = tok.groups()
    if hours is not None:
        return int(round(float(hours) * 60)) + int(hmin or 0)
    return int(mins)


def measure_timed(cards):
    rows = []
    missing = Counter(no_metrics_line=0, unparsable_duration=0, unparsable_budget=0)
    for card in cards.values():
        line = last_metrics_line(card["log"])
        if line is None:
            if is_done(card):
                missing["no_metrics_line"] += 1
            continue
        minutes = parse_duration(line)
        if minutes is None:
            missing["unparsable_duration"] += 1
            continue
        bm = BUDGET.match(card["fields"].get("budget", ""))
        if not bm:
            missing["unparsable_budget"] += 1
            continue
        budget = int(bm.group(1))
        rows.append({"id": card["id"], "size": card["fields"].get("size") or "?",
                     "minutes": minutes, "budget": budget, "ratio": minutes / budget})
    by_size = {}
    for size in sorted({r["size"] for r in rows}):
        group = [r for r in rows if r["size"] == size]
        over = sum(1 for r in group if r["ratio"] > 1)
        by_size[size] = {"cards": len(group), "overrun": over, "overrun_pct": pct(over, len(group)),
                         "median_ratio": round(statistics.median(r["ratio"] for r in group), 2)}
    total_min = sum(r["minutes"] for r in rows)
    overrun = sum(1 for r in rows if r["ratio"] > 1)
    worst = sorted(rows, key=lambda r: -r["ratio"])[:5]
    worst_min = sum(r["minutes"] for r in worst)
    return {
        "timed_cards": len(rows),
        "hours": round(total_min / 60, 1),
        "median_ratio": round(statistics.median(r["ratio"] for r in rows), 2) if rows else None,
        "overrun": overrun,
        "overrun_pct": pct(overrun, len(rows)),
        "by_size": by_size,
        "worst": [{"id": r["id"], "size": r["size"], "ratio": round(r["ratio"], 1),
                   "hours": round(r["minutes"] / 60, 1)} for r in worst],
        "worst_hours": round(worst_min / 60, 1),
        "worst_share_pct": pct(worst_min, total_min),
        "missing": dict(missing),
    }


def measure_wakes(cards):
    figures = []
    missing = Counter(no_metrics_line=0, no_wakes_figure=0)
    for card in cards.values():
        line = last_metrics_line(card["log"])
        if line is None:
            if is_done(card):
                missing["no_metrics_line"] += 1
            continue
        wm = re.search(r"\bwakes\s*[~≈]?(\d+)", line)
        if not wm:
            missing["no_wakes_figure"] += 1
            continue
        figures.append((card["id"], int(wm.group(1))))
    total = sum(n for _, n in figures)
    top = max(figures, key=lambda f: f[1]) if figures else None
    return {
        "cards": len(figures),
        "total": total,
        "mean": round(total / len(figures), 1) if figures else None,
        "max": {"id": top[0], "wakes": top[1]} if top else None,
        "missing": dict(missing),
    }


EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
STATUS_NAME = re.compile(r"^(T-\d{4})(?:\..*)?\.jsonl$")
CAUSE_CLASSES = (
    ("design-approval", re.compile(r"approv|design|plan|spec|checkpoint|brainstorm")),
    ("question", re.compile(r"question|answer|\bask|clarif|ruling|decid")),
    ("permission", re.compile(r"permission|login|auth|credential|token|access")),
    ("operator-action", re.compile(r"wait|await|feedback|confirm|consent|disposition|\byour\b|human")),
)
SENTINEL = re.compile(r"SHEPHERD:\s*\**\s*blocked\**\s*[—–-]+\s*(.*)")


def load_status(root, ids):
    """{id: {"events": [dict], "bad_lines": int, "files": int}} merged per task id.

    A task's turns can be spread over rotated status files — `T-0041.block7.jsonl`,
    `T-0059.done.jsonl`, `T-0076.turn1.jsonl` — and a large minority of the live
    folder is one. They are a single stream: every `T-NNNN*.jsonl` is read and the
    events ordered by `ts`, so a blocked walk crosses a rotation boundary. An event
    whose `ts` cannot be read keeps its file order and sorts last.
    """
    out = {}
    folder = os.path.join(root, "ledger", "status")
    if not os.path.isdir(folder):
        return out
    for name in sorted(os.listdir(folder)):
        m = STATUS_NAME.match(name)
        if not m or m.group(1) not in ids:
            continue
        entry = out.setdefault(m.group(1), {"events": [], "bad_lines": 0, "files": 0})
        entry["files"] += 1
        with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except ValueError:
                    entry["bad_lines"] += 1
                    continue
                if isinstance(event, dict):
                    entry["events"].append(event)
                else:
                    entry["bad_lines"] += 1
    for entry in out.values():
        entry["events"].sort(key=lambda e: (parse_ts(e.get("ts")) is None,
                                            parse_ts(e.get("ts")) or EPOCH))
    return out


def measure_turns(status, cards, now):
    claims = Counter()
    stops = bad = 0
    for tid, s in status.items():
        bad += s["bad_lines"]
        for event in s["events"]:
            if event.get("event") != "stop" or not in_window(event, now):
                continue
            stops += 1
            claim = event.get("claim")
            claims["null" if claim is None else str(claim)] += 1
    none = claims.get("none", 0)
    without = sum(1 for c in cards.values() if is_done(c) and c["id"] not in status)
    return {
        "stop_events": stops,
        "claim_none": none,
        "claim_none_pct": pct(none, stops),
        "by_claim": dict(sorted(claims.items())),
        "status_files": len(status),
        "files": sum(s["files"] for s in status.values()),
        "missing": {"done_cards_without_status_file": without, "unparsable_lines": bad},
    }


def classify_cause(text):
    low = text.lower()
    for name, rx in CAUSE_CLASSES:
        if rx.search(low):
            return name
    return "other"


def blocked_oneliner(event):
    """The one-liner after the LAST `SHEPHERD: blocked —` in the tail, else the tail's end."""
    tail = event.get("tail") or ""
    last = None
    for m in SENTINEL.finditer(tail):
        last = m
    return last.group(1) if last else tail[-200:]


def measure_blocked(status, active_hours, now):
    events = 0
    durations = []
    causes = Counter()
    missing = Counter(unclosed=0, unparsable_ts=0)
    for s in status.values():
        ev = s["events"]
        for i, event in enumerate(ev):
            if event.get("event") != "stop" or event.get("claim") != "blocked":
                continue
            if not in_window(event, now):
                continue
            events += 1
            causes[classify_cause(blocked_oneliner(event))] += 1
            later = next((x for x in ev[i + 1:] if x.get("event") == "stop"), None)
            if later is None:
                missing["unclosed"] += 1
                continue
            t0, t1 = parse_ts(event.get("ts")), parse_ts(later.get("ts"))
            if t0 is None or t1 is None or t1 < t0:
                missing["unparsable_ts"] += 1
                continue
            # The unblocking turn may land after --now. The block is still closed —
            # it is the duration that is clipped, so the numerator of the share and
            # `active_hours`, its denominator, span the same window.
            durations.append((min(t1, now) - t0).total_seconds() / 60)
    hours = sum(durations) / 60
    return {
        "events": events,
        "timed": len(durations),
        "hours": round(hours, 1),
        "median_minutes": round(statistics.median(durations)) if durations else None,
        "mean_minutes": round(statistics.mean(durations)) if durations else None,
        "share_of_active_pct": pct(hours, active_hours) if active_hours else None,
        "by_cause": {name: {"events": n, "pct": pct(n, events)} for name, n in causes.most_common()},
        "human_pct": pct(events - causes["other"], events),
        "missing": dict(missing),
    }


# ------------------------------------------------------------------ inbox

INBOX_LOG = os.path.join("ledger", "inbox.log")
INBOX_COLUMNS = ("start", "id", "session", "kind", "intent", "trust", "outcome", "received", "first")
OUTCOME_WORD = re.compile(r"^(answered|asked|refused|ignored|(?:carded|routed|held):T-\d{4})$")   # what inbox.sh log writes
TRUST_WORDS = ("operator", "member", "unknown")
FINAL_WORD = ("answered", "refused")      # the first word was the last: a refusal is a response
OPEN_OUTCOMES = ("carded", "routed", "held")


def load_inbox_log(root):
    """(events, answers, unparsable) from ledger/inbox.log, or None when there is no log.

    An event line is nine columns whose drain-start is a time and whose trust and
    outcome words are in their vocabularies; an answered line is `answered <id> <time>`.
    Every other non-blank line is unparsable: it belongs to no window, so the count is
    the same in every mode. Timestamps other than those two are parsed by the measure,
    per selected event, so a bad received-at costs that event its gap and nothing else.
    """
    path = os.path.join(root, INBOX_LOG)
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    events, answers, unparsable = [], [], 0
    for raw in lines:
        cols = raw.split()
        if not cols:
            continue
        if cols[0] == "answered" and len(cols) == 3 and parse_ts(cols[2]) is not None:
            answers.append((cols[1], parse_ts(cols[2])))
        elif (len(cols) == 9 and parse_ts(cols[0]) is not None
              and cols[5] in TRUST_WORDS and OUTCOME_WORD.match(cols[6])):
            e = dict(zip(INBOX_COLUMNS, cols))
            e["start_ts"] = parse_ts(cols[0])
            events.append(e)
        else:
            unparsable += 1
    return events, answers, unparsable


def _minutes(a, b):
    return (b - a).total_seconds() / 60


def _median(xs):
    return round(statistics.median(xs), 1) if xs else None


def measure_inbox(root, since_utc, now):
    """The inbox latencies (shepherd-metrics header, `inbox`)."""
    missing = Counter(log=0, unparsable_lines=0, unparsable_ts=0,
                      answered_without_event=0, unclosed=0, first_word_after_now=0, negative=0)
    loaded = load_inbox_log(root)
    if loaded is None:
        missing["log"] = 1
        events, answers = [], []
    else:
        events, answers, missing["unparsable_lines"] = loaded
    # An answered line joins every event line with its id, whatever window those
    # events fall in: one outside the window is ignored, an id no line records at all
    # is missing - and only when the answer itself is in the window, since an orphan
    # can be placed by nothing else.
    known = {e["id"] for e in events}
    selected = [e for e in events
                if e["start_ts"] <= now and (since_utc is None or e["start_ts"] >= since_utc)]
    answer_at = {}
    for eid, at in answers:
        if at > now:
            continue
        if eid not in known:
            if since_utc is None or at >= since_utc:
                missing["answered_without_event"] += 1
            continue
        answer_at[eid] = max(answer_at.get(eid, at), at)
    first_words, answer_times, gaps = [], [], []
    by_intent = defaultdict(lambda: {"events": 0, "first": [], "answer": []})
    by_outcome, by_trust = Counter(), Counter({w: 0 for w in TRUST_WORDS})
    for e in selected:
        start, outcome = e["start_ts"], e["outcome"].split(":")[0]
        intent = by_intent[e["intent"]]
        intent["events"] += 1
        by_outcome[outcome] += 1
        by_trust[e["trust"]] += 1
        first, received = parse_ts(e["first"]), parse_ts(e["received"])
        if first is None or received is None:
            missing["unparsable_ts"] += 1
        # A clock behind the Worker's, or a hand-written line, can put received-at
        # after drain-start or a first word before it. A negative latency is not a
        # latency: it is counted, and kept out of every median.
        if received is not None:
            gap = _minutes(received, start)
            if gap < 0:
                missing["negative"] += 1
            else:
                gaps.append(gap)
        fw = None
        if first is not None:
            if first > now:
                missing["first_word_after_now"] += 1
            elif first < start:
                missing["negative"] += 1
            else:
                fw = _minutes(start, first)
                first_words.append(fw)
                intent["first"].append(fw)
        if e["id"] in answer_at:
            ans = _minutes(start, answer_at[e["id"]])
            if ans < 0:
                missing["negative"] += 1
                ans = None
        elif outcome in FINAL_WORD:
            ans = fw
        else:
            ans = None
            if outcome in OPEN_OUTCOMES:
                missing["unclosed"] += 1
        if ans is not None:
            answer_times.append(ans)
            intent["answer"].append(ans)
    return {
        "events": len(selected),
        "first_word_events": len(first_words),
        "first_word_median_minutes": _median(first_words),
        "answered": len(answer_times),
        "answer_median_minutes": _median(answer_times),
        "by_intent": {name: {"events": v["events"],
                             "first_word_events": len(v["first"]),
                             "first_word_median_minutes": _median(v["first"]),
                             "answered": len(v["answer"]),
                             "answer_median_minutes": _median(v["answer"])}
                      for name, v in sorted(by_intent.items())},
        "by_outcome": dict(sorted(by_outcome.items())),
        "by_trust": {w: by_trust[w] for w in TRUST_WORDS},
        "offline_gap": {"events": len(gaps),
                        "median_minutes": _median(gaps),
                        "max_minutes": round(max(gaps), 1) if gaps else None},
        "missing": dict(missing),
    }


def load_transitions(root, now):
    """{id: [(ts, state), …]} from every commit whose diff adds a `state:` header line.

    One `git log -p` pass over ledger/tasks/. Author date is the moment the shepherd
    made the change; a diff line `+state: X` inside `diff --git … b/ledger/tasks/T-NNNN.md`
    is one transition. Returns None when git cannot answer (no repo, no git).

    `--reverse` is load-bearing: git emits newest-first and `list.sort` is stable, so
    two transitions sharing an author second would otherwise keep git's reversed order
    and `card_intervals` would read `done` before `working` — turning a closed span
    into one open to `now`. This history already holds five same-second commit pairs.
    `--no-ext-diff` keeps a user's `diff.external` or `GIT_EXTERNAL_DIFF` from replacing
    the patch text with something carrying no `+state:` lines at all.

    A commit authored after `now` is dropped here rather than in `card_intervals`,
    so a backdated `--now` can never open an interval on a transition that had not
    happened yet.
    """
    try:
        proc = subprocess.run(
            ["git", "-C", root, "log", "-p", "--reverse", "--no-ext-diff",
             "--format=COMMIT\t%aI", "--", "ledger/tasks/"],
            capture_output=True, text=True, errors="replace", check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    transitions = defaultdict(list)
    ts = tid = None
    for line in proc.stdout.splitlines():
        if line.startswith("COMMIT\t"):
            ts, tid = parse_ts(line.split("\t", 1)[1]), None
            if ts is not None and ts > now:
                ts = None  # nothing after --now is counted; the `and ts` guard below drops it
        elif line.startswith("diff --git "):
            # End-anchored on the destination path rather than a ` b/…` prefix: a user's
            # diff.noprefix or diff.mnemonicPrefix changes the prefix. The pathspec above
            # already bounds the search to ledger/tasks/.
            m = re.search(r"ledger/tasks/(T-\d{4})\.md$", line)
            tid = m.group(1) if m else None
        elif tid and ts and line.startswith("+state: "):
            words = line[len("+state: "):].split()
            if words:
                transitions[tid].append((ts, words[0]))
    for tid in transitions:
        transitions[tid].sort(key=lambda t: t[0])
    return transitions


def card_intervals(transitions, now):
    """Half-open [start, end) intervals during which the card was in an active state."""
    intervals, start = [], None
    for ts, state in transitions:
        active = state in ACTIVE_STATES
        if active and start is None:
            start = ts
        elif not active and start is not None:
            if ts > start:
                intervals.append((start, ts))
            start = None
    if start is not None and now > start:
        intervals.append((start, now))
    return intervals


def measure_concurrency(cards, transitions, now):
    empty = {"total_hours": 0, "from": None, "hours": {"0": 0, "1": 0, "2": 0, "3+": 0},
             "pct": {"0": None, "1": None, "2": None, "3+": None}, "max": 0, "hours_at_max": 0,
             "active_hours": 0.0}
    if transitions is None:
        return dict(empty, missing={"done_without_dated_interval": 0, "git_unavailable": 1})
    spans, missing = [], 0
    for tid, card in cards.items():
        own = card_intervals(transitions.get(tid, []), now)
        if not own and is_done(card):
            missing += 1
        spans.extend((tid, start, end) for start, end in own)
    if not spans:
        return dict(empty, missing={"done_without_dated_interval": missing, "git_unavailable": 0})
    t0 = min(s for _, s, _ in spans).replace(minute=0, second=0, microsecond=0)
    span = (now - t0).total_seconds() / 3600
    buckets = max(1, math.ceil(span))
    # An hour counts CARDS, not intervals: a card that leaves an active state and
    # re-enters it inside one hour is one active card in that hour, not two.
    seen = [set() for _ in range(buckets)]
    for tid, start, end in spans:
        first = int((start - t0).total_seconds() // 3600)
        last = math.ceil((end - t0).total_seconds() / 3600) - 1
        for h in range(max(first, 0), min(last, buckets - 1) + 1):
            seen[h].add(tid)
    counts = [len(s) for s in seen]
    hist = {"0": 0, "1": 0, "2": 0, "3+": 0}
    for n in counts:
        hist["3+" if n >= 3 else str(n)] += 1
    peak = max(counts)
    return {
        "total_hours": buckets,
        "from": t0.isoformat(timespec="minutes"),
        "hours": hist,
        "pct": {k: pct(v, buckets) for k, v in hist.items()},
        "max": peak,
        "hours_at_max": counts.count(peak) if peak else 0,
        "active_hours": round(sum(max((min(e, now) - max(s, t0)).total_seconds(), 0)
                                  for _, s, e in spans) / 3600, 1),
        "missing": {"done_without_dated_interval": missing, "git_unavailable": 0},
    }


DECISION_FILE = re.compile(r"^(\d{4}-\d{2})[^/]*\.md$")
LABEL = re.compile(
    r"(?:^\s*(?:-\s*)?|\*\*\s*)\*{0,2}(decision|basis|confidence|outcome|context|by)\b"
    r"(?=\*{0,2}\s*(?:[:.]|\d|—|–|-))", re.I | re.M)
LABEL_PREFIX = re.compile(r"^\s*(?:-\s*)?\*{0,2}\s*\w+\*{0,2}\s*[:.]?\s*\*{0,2}\s*")
LIVE_SOURCE = re.compile(
    r"https?://|\bctx7\b|\b(?:read|verified|checked|as of)\s+\d{4}-\d{2}-\d{2}"
    r"|\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|dev|app|io|org|net|ai)/", re.I)
OUTCOME_PLACEHOLDERS = {"", "pending", "tbd", "open", "n/a"}
ADAPTER_DIR = os.path.join("skills", "herdr-adapter", "references")
ADAPTER_NAME = re.compile(r"^v(\d+(?:\.\d+)*)\.md$")
# What a wake actually loads, and where each piece lives now that the framework
# is a plugin. Two roots, not one: the manual reaches the session as the
# instance's own generated copy, while the wake skill and the adapter reference
# are read out of the plugin. Measuring all four against the instance root
# reported the two plugin files as missing (T-0267).
#   "@instance:<rel>"  under the instance repository
#   "@plugin:<rel>"    under the installed plugin
CONTEXT_FILES = (
    ("manual", "@instance:.claude/shepherd-manual.md"),
    ("memory index", "@memory"),
    ("wake skill", "@plugin:skills/wake/SKILL.md"),
    ("adapter reference", "@adapter"),
)


def plugin_root():
    """The installed plugin's root. SHEPHERD_PLUGIN_ROOT overrides it, which is
    how the tests point the context measure at a fixture; otherwise this file
    self-locates, because it is always <plugin>/lib/metrics.py."""
    env = os.environ.get("SHEPHERD_PLUGIN_ROOT")
    if env:
        return env
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_decisions(root):
    """[(month, entry_text)] for every `## ` entry in decisions/YYYY-MM*.md."""
    out = []
    folder = os.path.join(root, "decisions")
    if not os.path.isdir(folder):
        return out
    for name in sorted(os.listdir(folder)):
        m = DECISION_FILE.match(name)
        if not m:
            continue
        with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        parts = re.split(r"^## ", text, flags=re.M)
        for entry in parts[1:]:
            out.append((m.group(1), entry))
    return out


def decision_fields(entry):
    """Which of Basis / backfilled Outcome / live source an entry carries."""
    labels = list(LABEL.finditer(entry))
    segments = {}
    for i, m in enumerate(labels):
        end = labels[i + 1].start() if i + 1 < len(labels) else len(entry)
        segments.setdefault(m.group(1).lower(), LABEL_PREFIX.sub("", entry[m.start():end], count=1))
    basis = segments.get("basis")
    outcome = segments.get("outcome")
    backfilled = False
    if outcome is not None:
        backfilled = outcome.strip().strip("—–-*: \t\n").strip().lower() not in OUTCOME_PLACEHOLDERS
    return {"basis": basis is not None,
            "outcome": backfilled,
            "cited": bool(basis and LIVE_SOURCE.search(basis))}


def measure_decisions(root, since_utc, now):
    floor = since_utc.astimezone().strftime("%Y-%m") if since_utc else None
    ceiling = now.astimezone().strftime("%Y-%m")
    by_month = {}
    for month, entry in load_decisions(root):
        if (floor and month < floor) or month > ceiling:
            continue
        row = by_month.setdefault(month, Counter(entries=0, basis=0, outcome=0, cited=0))
        row["entries"] += 1
        for key, val in decision_fields(entry).items():
            row[key] += int(val)
    rows = {}
    for month in sorted(by_month):
        r = by_month[month]
        rows[month] = {"entries": r["entries"],
                       "basis": r["basis"], "basis_pct": pct(r["basis"], r["entries"]),
                       "outcome": r["outcome"], "outcome_pct": pct(r["outcome"], r["entries"]),
                       "cited": r["cited"], "cited_pct": pct(r["cited"], r["entries"])}
    total = sum(r["entries"] for r in by_month.values())
    basis = sum(r["basis"] for r in by_month.values())
    outcome = sum(r["outcome"] for r in by_month.values())
    cited = sum(r["cited"] for r in by_month.values())
    return {"entries": total,
            "basis": basis, "basis_pct": pct(basis, total),
            "outcome": outcome, "outcome_pct": pct(outcome, total),
            "cited": cited, "cited_pct": pct(cited, total),
            "by_month": rows,
            "missing": {"entries_without_basis": total - basis}}


def adapter_reference(root=None):
    """The herdr adapter reference that is actually loaded: the highest-versioned
    `references/v*.md`. CLAUDE.md §7 pins one version and keeps the older files
    beside it for historical diffs, so a hard-coded filename would quietly read a
    stale 9.6k-token file after the next upgrade instead of reporting it missing.
    Versions compare numerically, so v0.10.0 beats v0.8.2 — lexical order does not.
    """
    folder = os.path.join(root or plugin_root(), ADAPTER_DIR)
    best, best_key = None, None
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        names = []
    for name in names:
        m = ADAPTER_NAME.match(name)
        if not m:
            continue
        key = tuple(int(part) for part in m.group(1).split("."))
        if best_key is None or key > best_key:
            best, best_key = os.path.join(folder, name), key
    return best or os.path.join(folder, "v*.md")


def default_memory_index(root):
    encoded = os.path.abspath(root).replace("/", "-")
    return os.path.expanduser(os.path.join("~", ".claude", "projects", encoded, "memory", "MEMORY.md"))


def measure_context(root, memory_index):
    files, total, absent = {}, 0, 0
    for label, rel in CONTEXT_FILES:
        if rel == "@memory":
            path = memory_index or default_memory_index(root)
        elif rel == "@adapter":
            path = adapter_reference(plugin_root())
        elif rel.startswith("@plugin:"):
            path = os.path.join(plugin_root(), rel[len("@plugin:"):])
        elif rel.startswith("@instance:"):
            path = os.path.join(root, rel[len("@instance:"):])
        else:
            path = os.path.join(root, rel)
        try:
            size = os.path.getsize(path) if os.path.isfile(path) else None
        except OSError:
            size = None
        if size is None:
            absent += 1
            files[label] = {"path": path, "bytes": None, "tokens": None}
        else:
            tokens = math.ceil(size / 4)
            total += tokens
            files[label] = {"path": path, "bytes": size, "tokens": tokens}
    return {"files": files, "total_tokens": total, "approximation": "bytes / 4",
            "missing": {"files": absent}}


def _missing(m):
    items = ["%s %s" % (k, v) for k, v in m.items() if v]
    return ", ".join(items) if items else "0"


def _parts(*items):
    """Join a row's clauses, dropping the empty ones.

    A window with no cards in it is a normal weekly result, and it must not print
    dangling separators (`overrun 0 (— %) — `, `claims `, `human — % ()`). Any
    clause that has nothing to say returns "" and disappears here.
    """
    return "; ".join(str(i) for i in items if i)


def _row(name, value, missing):
    return "| %s | %s | %s |" % (name, value.replace("None", "—"), _missing(missing))


def render_table(r):
    c, t, w, u, b, k, d, x = (r[key] for key in
                              ("cards", "timed", "wakes", "turns", "blocked", "concurrency", "decisions", "context"))
    rows = [_row("cards done / failed / abandoned",
                 _parts("%s / %s / %s of %s" % (c["done"], c["failed"], c["abandoned"], c["total"]),
                        "self-maintenance %s (%s %%)" % (c["self_maintenance"], c["self_maintenance_pct"])),
                 c["missing"])]
    by_size = ", ".join("%s %s/%s overrun (%s %%)" % (s, v["overrun"], v["cards"], v["overrun_pct"])
                        for s, v in t["by_size"].items())
    rows.append(_row("measured work",
                     _parts("%s h across %s timed cards" % (t["hours"], t["timed_cards"]),
                            "median ratio %s× budget" % t["median_ratio"] if t["timed_cards"] else "",
                            "overrun %s (%s %%)" % (t["overrun"], t["overrun_pct"]) if t["timed_cards"] else "",
                            by_size),
                     t["missing"]))
    worst = ", ".join("%s %s×" % (e["id"], e["ratio"]) for e in t["worst"])
    rows.append(_row("tail",
                     "worst five %s: %s h = %s %% of measured work"
                     % (worst, t["worst_hours"], t["worst_share_pct"])
                     if worst else "no timed cards in this window", {}))
    top = w["max"]
    rows.append(_row("shepherd wakes",
                     _parts("%s for %s cards" % (w["total"], w["cards"]),
                            "%s per card" % w["mean"] if w["cards"] else "",
                            "max %s %s" % (top["id"], top["wakes"]) if top else ""),
                     w["missing"]))
    claims = ", ".join("%s %s" % kv for kv in u["by_claim"].items())
    rows.append(_row("worker turns claim: none",
                     _parts("%s of %s stop events (%s %%)"
                            % (u["claim_none"], u["stop_events"], u["claim_none_pct"]),
                            "claims %s" % claims if claims else ""),
                     u["missing"]))
    causes = ", ".join("%s %s %%" % (name, v["pct"]) for name, v in b["by_cause"].items())
    rows.append(_row("blocked",
                     _parts("%s events, %s timed (upper bound, to the next stop)" % (b["events"], b["timed"]),
                            "%s h = %s %% of active card time" % (b["hours"], b["share_of_active_pct"])
                            if b["timed"] else "",
                            "median %s m, mean %s m" % (b["median_minutes"], b["mean_minutes"])
                            if b["timed"] else "",
                            "human %s %% (%s)" % (b["human_pct"], causes) if causes else ""),
                     b["missing"]))
    i = r["inbox"]
    if i["missing"]["log"]:
        inbox_text = "no inbox log"
    elif not i["events"]:
        inbox_text = "no inbox events in this window"
    else:
        def intent_cell(name, v):
            bits = ["first %s m" % v["first_word_median_minutes"]] if v["first_word_events"] else []
            if v["answered"]:
                bits.append("answer %s m" % v["answer_median_minutes"])
            return "%s %s%s" % (name, v["events"], " (%s)" % ", ".join(bits) if bits else "")
        g = i["offline_gap"]
        inbox_text = _parts(
            "%s events" % i["events"],
            "first word median %s m" % i["first_word_median_minutes"] if i["first_word_events"] else "",
            "answer median %s m over %s answered" % (i["answer_median_minutes"], i["answered"])
            if i["answered"] else "",
            "intents " + ", ".join(intent_cell(n, v) for n, v in i["by_intent"].items()),
            "outcomes " + ", ".join("%s %s" % kv for kv in i["by_outcome"].items()),
            "trust " + ", ".join("%s %s" % (w, i["by_trust"][w]) for w in TRUST_WORDS),
            "offline gap median %s m, max %s m over %s events"
            % (g["median_minutes"], g["max_minutes"], g["events"]) if g["events"] else "")
    rows.append(_row("inbox", inbox_text, i["missing"]))
    h, p = k["hours"], k["pct"]
    rows.append(_row("concurrency",
                     "%s h from %s; hours with 0/1/2/3+ active: %s (%s %%) / %s / %s / %s (%s %%); "
                     "max %s active for %s h"
                     % (k["total_hours"], k["from"], h["0"], p["0"], h["1"], h["2"], h["3+"], p["3+"],
                        k["max"], k["hours_at_max"])
                     if k["from"] else "no dated active intervals in this window", k["missing"]))
    months = "; ".join("%s: %s entries, Basis %s %%, Outcome %s %%, cited %s %%"
                       % (m, v["entries"], v["basis_pct"], v["outcome_pct"], v["cited_pct"])
                       for m, v in d["by_month"].items())
    rows.append(_row("decisions",
                     _parts("%s entries" % d["entries"],
                            "Basis %s %%, Outcome backfilled %s %%, live source cited %s %%"
                            % (d["basis_pct"], d["outcome_pct"], d["cited_pct"]) if d["entries"] else "",
                            months),
                     d["missing"]))
    files = ", ".join("%s %.1fk" % (name, v["tokens"] / 1000)
                      for name, v in x["files"].items() if v["tokens"] is not None)
    rows.append(_row("always-loaded context",
                     _parts("≈%.1fk tokens (%s)" % (x["total_tokens"] / 1000, files) if files
                            else "no always-loaded file found",
                            x["approximation"]),
                     x["missing"]))
    f = r["filter"]
    # `since` already names itself, so "since since <date>" must not happen.
    scope = f["mode"] if not f["since"] else (
        "%s %s" % (f["mode"], f["since"]) if f["mode"] == "since"
        else "%s since %s" % (f["mode"], f["since"]))
    where = "%s — %s of %s cards, %s undated; now %s" % (
        scope, f["cards"], f["cards_total"], f["undated"], f["now"])
    return "\n".join(["| measure | value | missing |", "|---|---|---|"] + rows + ["", "filter: " + where])


# ------------------------------------------------------------------ driver

def compute(root, mode, since, now, memory_index):
    if mode == "week":
        since_utc = now - timedelta(days=7)
        since_text = since_utc.isoformat(timespec="minutes")
    elif mode == "since":
        since_utc = parse_ts(since)
        if since_utc is None:
            raise ValueError("since: not a date: %s" % since)
        since_text = since
    else:
        since_utc, since_text = None, None
    all_cards = load_cards(root)
    cards = select_cards(all_cards, since_utc, now)
    undated = sum(1 for c in all_cards.values()
                  if parse_ts(c["fields"].get("created")) is None)
    status = load_status(root, cards)
    concurrency = measure_concurrency(cards, load_transitions(root, now), now)
    result = {
        "filter": {
            "mode": mode,
            "since": since_text,
            "now": now.isoformat(timespec="minutes"),
            "cards": len(cards),
            "cards_total": len(all_cards),
            # Over ALL cards, not the selection: a card with no parsable `created:`
            # cannot be placed in or out of a window, so select_cards drops it. Counting
            # it here keeps it visible, and identical, in every mode.
            "undated": undated,
        },
        "cards": measure_cards(cards, undated),
        "timed": measure_timed(cards),
        "wakes": measure_wakes(cards),
        "turns": measure_turns(status, cards, now),
        "blocked": measure_blocked(status, concurrency["active_hours"], now),
        "inbox": measure_inbox(root, since_utc, now),
        "concurrency": concurrency,
        "decisions": measure_decisions(root, since_utc, now),
        "context": measure_context(root, memory_index),
    }
    return result


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--root", required=True)
    ap.add_argument("--memory-index", default="")
    ap.add_argument("mode", choices=("week", "all", "since"))
    ap.add_argument("since", nargs="?")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--now")
    a = ap.parse_args(argv)
    if a.mode == "since" and not a.since:
        print("ERROR: since needs a date", file=sys.stderr)
        return 2
    now = parse_ts(a.now) if a.now else datetime.now(timezone.utc)
    if now is None:
        print("ERROR: --now is not an ISO-8601 instant: %s" % a.now, file=sys.stderr)
        return 2
    try:
        result = compute(a.root, a.mode, a.since, now, a.memory_index or None)
    except ValueError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 2
    if a.json:
        print(json.dumps(result, indent=2))
    else:
        print(render_table(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
