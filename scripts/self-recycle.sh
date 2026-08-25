#!/usr/bin/env bash
# R10 self-recycle helpers (see herdr-adapter R10, docs/specs/self-recycle-design.md).
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
#   self-recycle.sh recycle <msg> [--pane P] [--sound S] [--log F]
#                                                 -> the whole reset: preflight own pane, arm the detached watchdog, submit /clear.
#                                                    Shepherd runs this in ONE turn and then ends the turn.
#   self-recycle.sh watch <pane> <old-session-id> <msg> [--sound S] [--log F]
#                                                 -> the watchdog itself. Armed by `recycle`; a separate subcommand so it is
#                                                    directly testable. Exit 0 recovered, 2 precondition, 3 the /clear never
#                                                    took, 4 the recovery prompt never arrived.
#
# WHY THE GATE IS THE SESSION ID, NOT `idle`
# The predecessor waited for `agent_status: idle` on shepherd's own pane. Measured
# 2026-08-25: a shepherd pane can never report idle, because its watcher shells match the
# detection manifest's background_shell_working rule (priority 965), which outranks the
# live_prompt_box idle rule (950) even when the prompt box is a bare "❯". Worse, a box
# stuck in bash mode drops the shell footer and DOES report idle — so the old gate was
# silent in the healthy case and fired in the failure case. It cost one instance 40
# minutes of silent death on 2026-08-25 and had no logging on any path.
# What replaces it is positive: herdr publishes the live Claude session id at
# `pane get -> result.pane.agent_session.value`, maintained by the herdr claude
# integration hook (v8) on SessionStart. /clear mints a new session id, observed at ~1s.
# A changed id proves the clear landed; an unchanged id is exactly the bash-mode swallow.
# Full measurements and citations: docs/specs/self-recycle-design.md.
set -euo pipefail
cmd=${1:?usage: ctx|decide|meter|recycle|watch}

CTX_IDLE=${CTX_IDLE:-60}        # percent of window
CTX_BUSY=${CTX_BUSY:-85}
CTX_IDLE_K=${CTX_IDLE_K:-200}   # absolute, thousands of tokens
CTX_BUSY_K=${CTX_BUSY_K:-350}
here=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
self=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")

# pane_probe lives here: one tri-state reader for "which Claude session does this pane
# run", already used by lock.sh and shepherd-identity.sh for liveness. The recycle gate
# needs exactly that value, so it reuses the primitive instead of re-deriving the JSON path.
. "$here/scripts/lib/shepherd-common.sh"

# --- recycle/watch tunables. Every one has a working default; tests shrink them. -------
POLL=${SHEPHERD_RECYCLE_POLL:-2}                    # seconds between polls
CLEAR_TIMEOUT=${SHEPHERD_RECYCLE_CLEAR_TIMEOUT:-120} # how long a /clear has to take
SETTLE=${SHEPHERD_RECYCLE_SETTLE:-5}                # pause after the clear, before prompting
ATTEMPTS=${SHEPHERD_RECYCLE_ATTEMPTS:-3}            # recovery prompt attempts
VERIFY=${SHEPHERD_RECYCLE_VERIFY:-25}               # seconds to wait for a prompt to show up
ESCAPE_SETTLE=${SHEPHERD_RECYCLE_ESCAPE_SETTLE:-1}  # pause after Escape, before re-reading the box
PROJECTS=${SHEPHERD_RECYCLE_PROJECTS:-$HOME/.claude/projects}
RECYCLE_LOG=${SHEPHERD_RECYCLE_LOG:-$HOME/.claude/shepherd-recycle.log}
SOUND=${SHEPHERD_RECYCLE_SOUND:-request}

# rlog <PHASE> <detail> — the single documented trail. Appended, never truncated, so a
# give-up is still readable hours later. Phases: ARM POLL CLEAR-CONFIRMED SETTLE
# PROMPT-SENT VERIFIED GIVE-UP REFUSED. Never fails the caller: a log that cannot be
# written must not be the reason a recycle dies.
rlog() {
  local dir
  dir=$(dirname "$RECYCLE_LOG")
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true
  printf '%s %s %s\n' "$(date -Iseconds)" "$1" "$2" >> "$RECYCLE_LOG" 2>/dev/null || true
}

# rtoast <title> <body> — the operator-visible half of a give-up. `--sound none` is
# honoured by omitting the flag entirely, which is what Operator `notifications: silent`
# means. The script never parses the Operator block; shepherd passes --sound none.
rtoast() {
  if [ "$SOUND" = none ]; then
    herdr notification show "$1" --body "$2" >/dev/null 2>&1 || true
  else
    herdr notification show "$1" --body "$2" --sound "$SOUND" >/dev/null 2>&1 || true
  fi
}

# parse_args "$@" — fills POSITIONAL[] and the OPT_* / SOUND / RECYCLE_LOG globals.
# Flags and positionals may appear in any order. Order-dependent parsing was a real bug:
# a caller that put --log before the positionals silently logged to the DEFAULT file,
# which in a test run means writing into the operator's live recycle log.
parse_args() {
  POSITIONAL=()
  OPT_PANE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pane)  OPT_PANE=${2:-};  shift 2 || shift $# ;;
      --sound) SOUND=${2:-request}; shift 2 || shift $# ;;
      --log)   RECYCLE_LOG=${2:-$RECYCLE_LOG}; shift 2 || shift $# ;;
      --) shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
      *) POSITIONAL+=("$1"); shift ;;
    esac
  done
}

# watchdog_exit — the EXIT trap body for `watch`. A one-line trap keeps the guarantee
# greppable: every intentional exit sets FINAL=1 first, so reaching here with FINAL=0
# means an abort nobody anticipated, and it STILL costs a log line and a toast.
watchdog_exit() {
  local rc=$?
  [ "${FINAL:-0}" = 1 ] && return 0
  rlog GIVE-UP "watchdog aborted without a verdict (rc=$rc) pane=${WATCH_PANE:-?} baseline=${WATCH_OLD:-?}"
  rtoast "shepherd recycle FAILED" "The recycle watchdog died without a verdict. Check $RECYCLE_LOG."
  return 0
}

# pane_status <pane> — agent_status, or "unknown" when it cannot be read.
pane_status() {
  local out
  out=$(herdr pane get "$1" 2>/dev/null) || true
  [ -n "$out" ] || { printf 'unknown\n'; return 0; }
  printf '%s' "$out" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d["result"]["pane"].get("agent_status") or "unknown")
except Exception:
    print("unknown")
' 2>/dev/null || printf 'unknown\n'
}

# prompt_box <pane> — clean | bash | other. Reported for the log; only `bash` decides.
#   clean = a bare "❯" and nothing after it.
#   bash  = the box is in shell mode; anything submitted runs as a shell command and the
#           /clear is swallowed (measured 2026-08-25, and the 2026-08-18 incident).
#   other = text after the "❯". USUALLY Claude Code's own suggested prompt, which is ghost
#           text: measured 2026-08-25, a box reading "❯  I need a task description to
#           suggest your next step." accepted /clear normally and the session id moved. A
#           pane read cannot tell a suggestion from a human draft (R10 Gotchas), so `other`
#           is logged and proceeded through — refusing on it would hold a legitimate
#           recycle over ghost text, and the session-id gate catches a real failure loudly.
prompt_box() {
  local out
  out=$(herdr pane read "$1" --source visible --lines 8 --format text 2>/dev/null) || true
  [ -n "$out" ] || { printf 'other\n'; return 0; }
  if printf '%s\n' "$out" | grep -qE '^[[:space:]]*!([[:space:]]|$)' \
     || printf '%s\n' "$out" | grep -qF '! for shell mode'; then
    printf 'bash\n'; return 0
  fi
  if printf '%s\n' "$out" | grep -qE '^[[:space:]]*❯[[:space:]]*$'; then
    printf 'clean\n'; return 0
  fi
  printf 'other\n'
}

# prompt_mode_ok <pane> — force the box out of bash mode, then PROVE it left.
# Escape leaves bash mode (measured 2026-08-25); forcing without verifying is what the old
# recipe did by hand, and it is how a swallowed /clear got through. The read-back is the
# part that matters. Only bash mode fails this check — see prompt_box on why `other` does
# not. Prints the observed state so the caller can log what it saw.
prompt_mode_ok() {
  local pane=$1 st
  herdr pane send-keys "$pane" Escape >/dev/null 2>&1 || true
  [ "$ESCAPE_SETTLE" = 0 ] || sleep "$ESCAPE_SETTLE"
  st=$(prompt_box "$pane")
  BOX_STATE=$st
  [ "$st" != bash ]
}

# verify_prompt <session-id> <message> — ground truth that the prompt ARRIVED, not that
# it was accepted for submission. herdr answers `agent_prompted` even when a bash-mode
# box swallows the text (measured), so a return value is not evidence. The transcript is.
# Globbing every project directory avoids depending on the pane's cwd; session ids are unique.
verify_prompt() {
  local sid=$1 msg=$2 f
  for f in "$PROJECTS"/*/"$sid".jsonl; do
    [ -f "$f" ] || continue
    grep -qF -- "$msg" "$f" && return 0
  done
  return 1
}

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

  recycle)
    # Preflight, arm, submit. Everything that can refuse does so BEFORE the /clear goes
    # out, so a refusal leaves shepherd exactly as it was — context intact, nothing queued.
    shift
    parse_args "$@"
    msg=${POSITIONAL[0]:-}
    pane=${OPT_PANE:-${HERDR_PANE_ID:-}}
    set +e
    if [ -z "$msg" ] || [ -z "$pane" ]; then
      rlog REFUSED "recycle needs a message and a pane (pane=${pane:-none})"
      rtoast "shepherd recycle REFUSED" "recycle was called without a message or a pane; nothing was cleared."
      exit 2
    fi

    st=$(pane_status "$pane")
    if [ "$st" = blocked ]; then
      rlog REFUSED "pane=$pane is blocked; a /clear would answer the open dialog instead of clearing"
      rtoast "shepherd recycle REFUSED" "Pane $pane is blocked by a dialog. Clear the dialog, then recycle again."
      exit 2
    fi

    s0=$(pane_probe "$pane" 2>/dev/null); prc=$?
    if [ "$prc" -ne 0 ] || [ -z "$s0" ]; then
      rlog REFUSED "pane=$pane reports no Claude session (probe_rc=$prc); the herdr claude integration may be missing"
      rtoast "shepherd recycle REFUSED" "No Claude session id for $pane — check: herdr integration status. Nothing was cleared."
      exit 2
    fi

    if ! prompt_mode_ok "$pane"; then
      rlog REFUSED "pane=$pane prompt box is still in bash mode after Escape; a /clear there would run as a shell command"
      rtoast "shepherd recycle REFUSED" "The input box on $pane will not leave bash mode. Nothing was cleared."
      exit 2
    fi

    rlog ARM "pane=$pane session=$s0 box=$BOX_STATE watchdog armed (clear_timeout=${CLEAR_TIMEOUT}s attempts=$ATTEMPTS) msg=$msg"
    # Detached so it outlives the /clear. Measured 2026-08-25: setsid+nohup keeps its own
    # session and process group, survives the calling turn, and inherits HERDR_SOCKET_PATH.
    # stderr joins the log, so even a crash before the first rlog leaves a trace.
    setsid nohup bash "$self" watch "$pane" "$s0" "$msg" --sound "$SOUND" --log "$RECYCLE_LOG" \
      >> "$RECYCLE_LOG" 2>&1 &

    herdr agent prompt "$pane" "/clear" >/dev/null 2>&1 || true
    printf 'recycle armed: pane=%s session=%s log=%s\n' "$pane" "$s0" "$RECYCLE_LOG"
    exit 0
    ;;

  watch)
    shift
    parse_args "$@"
    pane=${POSITIONAL[0]:-}; old=${POSITIONAL[1]:-}; msg=${POSITIONAL[2]:-}
    set +e
    if [ -z "$pane" ] || [ -z "$old" ] || [ -z "$msg" ]; then
      rlog REFUSED "watch needs <pane> <old-session-id> <message>"
      exit 2
    fi

    # The backstop. Every intentional exit sets FINAL=1 first, so anything that reaches
    # this trap with FINAL=0 is an abort nobody anticipated — and it still leaves a line
    # and a toast. "Either completes or reports, never neither" is enforced here.
    FINAL=0
    WATCH_PANE=$pane WATCH_OLD=$old
    trap watchdog_exit EXIT

    # --- phase 1: did the /clear actually take? ---------------------------------------
    deadline=$(( $(date +%s) + CLEAR_TIMEOUT ))
    new=""
    while :; do
      sid=$(pane_probe "$pane" 2>/dev/null); prc=$?
      rlog POLL "phase=clear pane=$pane session=${sid:-none} probe_rc=$prc baseline=$old"
      if [ "$prc" -eq 0 ] && [ -n "$sid" ] && [ "$sid" != "$old" ]; then new=$sid; break; fi
      [ "$(date +%s)" -ge "$deadline" ] && break
      sleep "$POLL"
    done
    if [ -z "$new" ]; then
      rlog GIVE-UP "the /clear never took: pane=$pane still runs session $old after ${CLEAR_TIMEOUT}s"
      rtoast "shepherd recycle FAILED" "The /clear never took on $pane (session unchanged). Shepherd is NOT recycled and is idle. Type: $msg"
      FINAL=1; exit 3
    fi
    rlog CLEAR-CONFIRMED "pane=$pane session $old -> $new"

    # --- phase 2: let the fresh session finish standing up ----------------------------
    [ "$SETTLE" = 0 ] || sleep "$SETTLE"
    rlog SETTLE "waited ${SETTLE}s before prompting pane=$pane session=$new"

    # --- phase 3: prompt, then verify against the transcript --------------------------
    a=1
    while [ "$a" -le "$ATTEMPTS" ]; do
      if prompt_mode_ok "$pane"; then
        herdr agent prompt "$pane" "$msg" >/dev/null 2>&1 || true
        rlog PROMPT-SENT "attempt $a/$ATTEMPTS pane=$pane session=$new box=$BOX_STATE"
      else
        rlog REFUSED "attempt $a/$ATTEMPTS pane=$pane still in bash mode; not submitting"
      fi
      vdead=$(( $(date +%s) + VERIFY ))
      while :; do
        if verify_prompt "$new" "$msg"; then
          rlog VERIFIED "session=$new received the recovery prompt on attempt $a; recycle complete"
          FINAL=1; exit 0
        fi
        [ "$(date +%s)" -ge "$vdead" ] && break
        sleep "$POLL"
      done
      rlog POLL "phase=verify attempt $a/$ATTEMPTS session=$new prompt not visible after ${VERIFY}s"
      a=$((a + 1))
    done
    rlog GIVE-UP "the recovery prompt never reached session $new on pane=$pane after $ATTEMPTS attempts"
    rtoast "shepherd recycle FAILED" "Shepherd cleared but never restarted on $pane. Type: $msg"
    FINAL=1; exit 4
    ;;

  *) echo "unknown cmd: $cmd" >&2; exit 1;;
esac
