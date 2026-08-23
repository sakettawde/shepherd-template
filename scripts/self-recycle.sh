#!/usr/bin/env bash
# R10 self-recycle helpers (see herdr-adapter R10).
# Usage:
#   self-recycle.sh ctx [pane]                    -> prints own context use as "<percent> <tokens>" (tokens = percent x window,
#                                                    in thousands, 0 if the window is unknown), read from the status line Claude
#                                                    Code renders in own pane (needs ~/.claude/statusline.py);
#                                                    prints "unknown" (exit 2) when no status line is visible
#   self-recycle.sh decide [pane]                 -> prints one of: recycle|hold|ok|unknown. Absolute tokens AND percent are
#                                                    checked and WHICHEVER FIRES FIRST wins (on a 1M window a comfortable
#                                                    percent is already an expensive, degraded turn):
#                                                    recycle = (>= CTX_IDLE_K (200k) or >= CTX_IDLE (60%)) and no active card owned,
#                                                              or (>= CTX_BUSY_K (350k) or >= CTX_BUSY (85%)) regardless
#                                                    hold    = the idle trigger fired but active cards are owned (recycle at next close-out)
#   self-recycle.sh meter <session-id>            -> prints current context tokens (from own transcript; legacy, approximate)
#   self-recycle.sh inject <pane> <delay-s> <msg> -> detached: wait for pane idle, then herdr pane run <msg>
set -euo pipefail
cmd=${1:?usage: ctx|decide|meter|inject}

CTX_IDLE=${CTX_IDLE:-60}        # percent of window
CTX_BUSY=${CTX_BUSY:-85}
CTX_IDLE_K=${CTX_IDLE_K:-200}   # absolute, thousands of tokens
CTX_BUSY_K=${CTX_BUSY_K:-350}
here=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

read_ctx() {
  # prints "<percent> <ktokens>"; ktokens is 0 when the status line carries no window size
  local pane=${1:-${HERDR_PANE_ID:-}} line pct size
  [ -n "$pane" ] || { echo unknown; return 2; }
  line=$(herdr pane read "$pane" --source visible --lines 12 --format text 2>/dev/null \
    | grep -oE 'ctx [▓░]* *[0-9]+%(/[0-9]+k)?' | tail -1) || true
  [ -n "$line" ] || { echo unknown; return 2; }
  pct=$(printf '%s' "$line" | grep -oE '[0-9]+%' | tr -d '%')
  size=$(printf '%s' "$line" | grep -oE '/[0-9]+k' | tr -d '/k' || true)
  echo "$pct $(( pct * ${size:-0} / 100 ))"
}

case "$cmd" in
  ctx)
    read_ctx "${2:-}"
    ;;
  decide)
    read -r pct kt <<<"$(read_ctx "${2:-}")" || true
    [ "$pct" != unknown ] && [ -n "$pct" ] || { echo unknown; exit 0; }
    me=${SHEPHERD_ID:-shepherd-1}
    active=$(grep -lE '^state: (briefed|working|blocked|review)' "$here"/ledger/tasks/T-*.md 2>/dev/null \
      | while read -r f; do o=$(grep -m1 '^owner:' "$f" | awk '{print $2}'); [ "${o:-shepherd-1}" = "$me" ] && echo "$f"; done | wc -l || true)
    active=${active:-0}
    busy=0; idle=0
    { [ "$pct" -ge "$CTX_BUSY" ] || [ "$kt" -ge "$CTX_BUSY_K" ]; } && busy=1
    { [ "$pct" -ge "$CTX_IDLE" ] || [ "$kt" -ge "$CTX_IDLE_K" ]; } && idle=1
    if [ "$busy" -eq 1 ]; then echo recycle
    elif [ "$idle" -eq 1 ] && [ "$active" -eq 0 ]; then echo recycle
    elif [ "$idle" -eq 1 ]; then echo hold
    else echo ok; fi
    ;;
  meter)
    sid=${2:?session id}
    # Claude Code stores a session transcript under
    # ~/.claude/projects/<clone-path-with-slashes-as-hyphens>/<session-id>.jsonl.
    proj=${3:-$HOME/.claude/projects/$(printf '%s' "$here" | tr '/' '-')}
    python3 - "$proj/$sid.jsonl" << 'PY'
import json,sys
last=None
with open(sys.argv[1]) as fh:
    for line in fh:
        try:
            u=(json.loads(line).get('message') or {}).get('usage')
            if u: last=u
        except Exception: pass
if last:
    print(last.get('input_tokens',0)+last.get('cache_read_input_tokens',0)+last.get('cache_creation_input_tokens',0))
else:
    print(0)
PY
    ;;
  inject)
    pane=${2:?pane id}
    delay=${3:?initial delay seconds}
    msg=${4:?message}
    # Detached from the calling claude session so it survives /clear.
    setsid nohup bash -c '
      pane="$1"; delay="$2"; msg="$3"
      sleep "$delay"
      for i in $(seq 1 60); do
        st=$(herdr pane get "$pane" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)[\"result\"][\"pane\"].get(\"agent_status\",\"unknown\"))" 2>/dev/null || echo unknown)
        if [ "$st" = idle ]; then
          sleep 8
          st2=$(herdr pane get "$pane" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)[\"result\"][\"pane\"].get(\"agent_status\",\"unknown\"))" 2>/dev/null || echo unknown)
          if [ "$st2" = idle ]; then
            herdr pane run "$pane" "$msg"
            exit 0
          fi
        fi
        sleep 5
      done
    ' _ "$pane" "$delay" "$msg" >/tmp/self-recycle-inject.log 2>&1 &
    echo "injector armed: pane=$pane delay=${delay}s"
    ;;
  *) echo "unknown cmd: $cmd" >&2; exit 1;;
esac
