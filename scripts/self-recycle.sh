#!/usr/bin/env bash
# R10 self-recycle helpers (see herdr-adapter R10).
# Usage:
#   self-recycle.sh meter <session-id>            -> prints current context tokens (from own transcript)
#   self-recycle.sh inject <pane> <delay-s> <msg> -> detached: wait for pane idle, then herdr pane run <msg>
set -euo pipefail
cmd=${1:?usage: meter|inject}

case "$cmd" in
  meter)
    sid=${2:?session id}
    # Claude Code stores a session transcript under
    # ~/.claude/projects/<clone-path-with-slashes-as-hyphens>/<session-id>.jsonl.
    root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
    proj=${3:-$HOME/.claude/projects/$(printf '%s' "$root" | tr '/' '-')}
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
