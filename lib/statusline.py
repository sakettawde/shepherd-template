#!/usr/bin/env python3
# Claude Code status line: Model · Effort · Context utilisation (+ shepherd identity when set).
# Fields per https://code.claude.com/docs/en/statusline (read 2026-08-23).
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
model = (d.get("model") or {}).get("display_name") or "?"
effort = (d.get("effort") or {}).get("level")            # absent when the model has no effort param
cw = d.get("context_window") or {}
pct = cw.get("used_percentage")                           # null early in the session / right after /compact
size = cw.get("context_window_size")
shep, task = os.environ.get("SHEPHERD_ID", ""), os.environ.get("SHEPHERD_TASK_ID", "")

def c(code, s): return f"\033[{code}m{s}\033[0m"
parts = [c("1;36", model)]
if effort: parts.append(c("35", f"effort:{effort}"))
if pct is None:
    parts.append(c("2", "ctx: –"))
else:
    p = int(round(float(pct)))
    filled = min(10, max(0, round(p / 10)))
    bar = "▓" * filled + "░" * (10 - filled)
    col = "32" if p < 50 else ("33" if p < 75 else "31")
    size_s = f"/{int(size/1000)}k" if size else ""
    parts.append(c(col, f"ctx {bar} {p}%{size_s}"))
if task:   parts.append(c("1;33", f"worker {task}"))
elif shep: parts.append(c("1;34", shep))
print(" │ ".join(parts))
