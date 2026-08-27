#!/usr/bin/env bash
# R10 context-rollover helpers (see herdr-adapter R10, docs/specs/context-rollover-design.md).
# Usage:
#   context-rollover.sh ctx [pane]
#       prints own context use as "<percent> <tokens>" (tokens = percent x window, in thousands,
#       0 if the window is unknown), read from the status line Claude Code renders in own pane
#       (needs ~/.claude/statusline.py); prints "unknown" (exit 2) when no status line is visible
#   context-rollover.sh decide [pane]
#       prints one of: rollover|hold|ok|unknown. Absolute tokens AND percent are checked and
#       WHICHEVER FIRES FIRST wins (on a 1M window a comfortable percent is already an
#       expensive, degraded turn):
#         rollover = (>= CTX_IDLE_K (200k) or >= CTX_IDLE (60%)) and no active card owned,
#                    or (>= CTX_BUSY_K (350k) or >= CTX_BUSY (85%)) regardless
#         hold     = the idle trigger fired but active cards are owned (roll over at close-out)
#   context-rollover.sh meter <session-id>
#       prints current context tokens (from own transcript; legacy, approximate)
#   context-rollover.sh rollover [msg] [--pane P] [--sound S] [--log F]
#       READ-ONLY foreground: preflight own pane, arm the detached watchdog, print, exit.
#       It sends NO keystroke to the pane — see WHY THE FOREGROUND TOUCHES NOTHING below.
#       Shepherd runs this in ONE turn and then ends the turn. `msg` defaults to the
#       one-word recovery line below, so the whole invocation is `rollover` and nothing
#       else — pass one only to recover a pane into something other than the wake skill.
#   context-rollover.sh watch <pane> <old-session-id> <msg> [--parent PID] [--sound S] [--log F]
#       the watchdog itself, and the only thing that ever touches the pane. Armed by
#       `rollover`; a separate subcommand so it is directly testable. With --parent it
#       waits for that pid to exit before the first keystroke. Exit 0 recovered,
#       2 precondition, 3 the /clear never took, 4 the recovery prompt never arrived,
#       5 the foreground call never finished so nothing was sent.
#
# WHY THE FOREGROUND TOUCHES NOTHING
# Measured 2026-08-27. The previous shape sent `herdr pane send-keys <own-pane> Escape`
# from the foreground, while that foreground was still running as the shepherd's own
# Bash tool call. Claude Code reads an Escape into its pane as INTERRUPT THE RUNNING
# TOOL — and the running tool was this very script. The pane showed `Bash interrupted`,
# the script died before it armed the watchdog and before the /clear, and the instance
# sat idle with no watchers for hours. It looked like a permission block and was not:
# the command interrupted itself. So the foreground is read-only (`pane get`,
# `pane read`), and every keystroke — Escape, the bash-mode read-back, /clear, the
# recovery prompt — is sent by the DETACHED watchdog only after the foreground pid is
# gone. Full account: docs/specs/context-rollover-design.md §8.
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
# Full measurements and citations: docs/specs/context-rollover-design.md.
set -euo pipefail
cmd=${1:?usage: ctx|decide|meter|rollover|watch}

CTX_IDLE=${CTX_IDLE:-60}        # percent of window
CTX_BUSY=${CTX_BUSY:-85}
CTX_IDLE_K=${CTX_IDLE_K:-200}   # absolute, thousands of tokens
CTX_BUSY_K=${CTX_BUSY_K:-350}
here=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
self=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")

# pane_probe lives here: one tri-state reader for "which Claude session does this pane
# run", already used by lock.sh and shepherd-identity.sh for liveness. The rollover gate
# needs exactly that value, so it reuses the primitive instead of re-deriving the JSON path.
. "$here/scripts/lib/shepherd-common.sh"

# --- rollover/watch tunables. Every one has a working default; tests shrink them. -------
POLL=${SHEPHERD_ROLLOVER_POLL:-2}                    # seconds between polls
PARENT_TIMEOUT=${SHEPHERD_ROLLOVER_PARENT_TIMEOUT:-60} # how long the foreground has to exit
HANDOFF=${SHEPHERD_ROLLOVER_HANDOFF:-5}              # settle after it does, before keystroke 1
CLEAR_TIMEOUT=${SHEPHERD_ROLLOVER_CLEAR_TIMEOUT:-120} # how long a /clear has to take
SETTLE=${SHEPHERD_ROLLOVER_SETTLE:-5}                # pause after the clear, before prompting
ATTEMPTS=${SHEPHERD_ROLLOVER_ATTEMPTS:-3}            # recovery prompt attempts
VERIFY=${SHEPHERD_ROLLOVER_VERIFY:-25}               # seconds to wait for a prompt to show up
ESCAPE_SETTLE=${SHEPHERD_ROLLOVER_ESCAPE_SETTLE:-1}  # pause after Escape, before re-reading the box
PROJECTS=${SHEPHERD_ROLLOVER_PROJECTS:-$HOME/.claude/projects}
ROLLOVER_LOG=${SHEPHERD_ROLLOVER_LOG:-$HOME/.claude/shepherd-rollover.log}
SOUND=${SHEPHERD_ROLLOVER_SOUND:-request}

# The recovery line typed into the fresh session. ONE WORD, and a word Claude Code
# resolves without reading anything first: `.claude/skills/wake/SKILL.md` is
# user-invocable as `/wake` (observed live 2026-08-27 — a session that created the
# directory had `/wake` in its skill list on the next turn). The predecessor was a
# sentence of prose telling the fresh session to go read CLAUDE.md §8 and improvise
# the steps; the skill now holds those steps, so the prose has nothing left to say.
# Keeping it here rather than at every call site also shrinks the command a shepherd
# turn actually types down to `context-rollover.sh rollover`, which is the smallest
# surface any permission layer can be shown. Verify the message ARRIVES (verify_prompt
# greps the new transcript for this exact string), so every quoting surface must match:
# CLAUDE.md §8, adapter R10, docs/specs/context-rollover-design.md, test-rollover.sh.
ROLLOVER_MSG=${SHEPHERD_ROLLOVER_MSG:-/wake}

# rlog <PHASE> <detail> — the single documented trail. Appended, never truncated, so a
# give-up is still readable hours later. Phases: ARM HANDOFF CLEAR-SENT POLL
# CLEAR-CONFIRMED SETTLE PROMPT-SENT VERIFIED GIVE-UP REFUSED. Never fails the caller:
# a log that cannot be written must not be the reason a rollover dies.
rlog() {
  local dir
  dir=$(dirname "$ROLLOVER_LOG")
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true
  printf '%s %s %s\n' "$(date -Iseconds)" "$1" "$2" >> "$ROLLOVER_LOG" 2>/dev/null || true
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

# parse_args "$@" — fills POSITIONAL[] and the OPT_* / SOUND / ROLLOVER_LOG globals.
# Flags and positionals may appear in any order. Order-dependent parsing was a real bug:
# a caller that put --log before the positionals silently logged to the DEFAULT file,
# which in a test run means writing into the operator's live rollover log.
parse_args() {
  POSITIONAL=()
  OPT_PANE=""
  OPT_PARENT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pane)   OPT_PANE=${2:-};   shift 2 || shift $# ;;
      --parent) OPT_PARENT=${2:-}; shift 2 || shift $# ;;
      --sound) SOUND=${2:-request}; shift 2 || shift $# ;;
      --log)   ROLLOVER_LOG=${2:-$ROLLOVER_LOG}; shift 2 || shift $# ;;
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
  rtoast "shepherd context rollover FAILED" "The rollover watchdog died without a verdict. Check $ROLLOVER_LOG."
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
#           rollover over ghost text, and the session-id gate catches a real failure loudly.
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
# CALLED FROM THE WATCHDOG ONLY. Sending this Escape from the foreground is what killed
# the foreground's own tool call on 2026-08-27 (see the header note).
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
    if [ "$busy" -eq 1 ]; then echo rollover
    elif [ "$idle" -eq 1 ] && [ "$active" -eq 0 ]; then echo rollover
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

  rollover)
    # READ-ONLY. Preflight, arm, print, exit — inside a second, and without touching the
    # pane. Everything that can refuse from here does so BEFORE the watchdog is armed, so
    # a refusal leaves shepherd exactly as it was: context intact, nothing queued, no
    # detached process left behind. The keystroke half lives in `watch` and starts only
    # once this process is gone (header note: an Escape from here interrupts the Bash
    # tool call that is running this very script).
    shift
    parse_args "$@"
    msg=${POSITIONAL[0]:-$ROLLOVER_MSG}
    pane=${OPT_PANE:-${HERDR_PANE_ID:-}}
    set +e
    if [ -z "$pane" ]; then
      rlog REFUSED "rollover needs a pane and found none (HERDR_PANE_ID unset and no --pane)"
      rtoast "shepherd context rollover REFUSED" "rollover was called with no pane; nothing was cleared."
      exit 2
    fi

    st=$(pane_status "$pane")
    if [ "$st" = blocked ]; then
      rlog REFUSED "pane=$pane is blocked; a /clear would answer the open dialog instead of clearing"
      rtoast "shepherd context rollover REFUSED" "Pane $pane is blocked by a dialog. Clear the dialog, then run the rollover again."
      exit 2
    fi

    s0=$(pane_probe "$pane" 2>/dev/null); prc=$?
    if [ "$prc" -ne 0 ] || [ -z "$s0" ]; then
      rlog REFUSED "pane=$pane reports no Claude session (probe_rc=$prc); the herdr claude integration may be missing"
      rtoast "shepherd context rollover REFUSED" "No Claude session id for $pane — check: herdr integration status. Nothing was cleared."
      exit 2
    fi

    # Observed, not acted on. A box in bash mode is the watchdog's problem: it is what
    # sends the Escape, and it refuses there if the box will not leave. Recording the
    # state here still costs nothing and dates the observation in the log.
    box=$(prompt_box "$pane")

    rlog ARM "pane=$pane session=$s0 box_before=$box watchdog armed (parent=$$ handoff=${HANDOFF}s clear_timeout=${CLEAR_TIMEOUT}s attempts=$ATTEMPTS) msg=$msg"
    # Detached so it outlives this process AND the tool call carrying it. Measured
    # 2026-08-25: setsid+nohup keeps its own session and process group, survives the
    # calling turn, and inherits HERDR_SOCKET_PATH. stderr joins the log, so even a crash
    # before the first rlog leaves a trace.
    setsid nohup bash "$self" watch "$pane" "$s0" "$msg" \
      --parent "$$" --sound "$SOUND" --log "$ROLLOVER_LOG" \
      >> "$ROLLOVER_LOG" 2>&1 &

    printf 'rollover armed: pane=%s session=%s log=%s\n' "$pane" "$s0" "$ROLLOVER_LOG"
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

    # --- phase 0: wait for the foreground call to finish ------------------------------
    # THE root cause of the 2026-08-27 stalls. `herdr pane send-keys <own-pane> Escape`
    # reaches Claude Code as "interrupt the running tool", and the running tool was the
    # Bash call carrying the foreground half of this script: the pane showed
    # `Bash interrupted`, nothing was ever armed, and the instance sat idle with no
    # watchers for hours. Every keystroke below therefore waits until that pid is gone.
    # Without --parent the wait is skipped, which is how a test drives `watch` directly.
    if [ -n "${OPT_PARENT:-}" ]; then
      pdead=$(( $(date +%s) + PARENT_TIMEOUT ))
      while kill -0 "$OPT_PARENT" 2>/dev/null; do
        if [ "$(date +%s)" -ge "$pdead" ]; then
          rlog GIVE-UP "the foreground rollover (pid $OPT_PARENT) was still alive after ${PARENT_TIMEOUT}s; no keystroke was sent"
          rtoast "shepherd context rollover FAILED" "The rollover call never finished on $pane. Nothing was cleared. Type: $msg"
          FINAL=1; exit 5
        fi
        sleep 1
      done
      rlog HANDOFF "foreground pid $OPT_PARENT exited; settling ${HANDOFF}s before the first keystroke"
      [ "$HANDOFF" = 0 ] || sleep "$HANDOFF"
    fi

    # --- phase 0b: force prompt mode, prove it left, then submit the /clear ------------
    # This is the first thing that touches the pane, and it happens with no tool call of
    # shepherd's own left running. The refusal still lands before the /clear goes out.
    if ! prompt_mode_ok "$pane"; then
      rlog REFUSED "pane=$pane prompt box is still in bash mode after Escape; a /clear there would run as a shell command"
      rtoast "shepherd context rollover REFUSED" "The input box on $pane will not leave bash mode. Nothing was cleared."
      FINAL=1; exit 2
    fi
    rlog CLEAR-SENT "pane=$pane box=$BOX_STATE submitting /clear"
    herdr agent prompt "$pane" "/clear" >/dev/null 2>&1 || true

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
      rtoast "shepherd context rollover FAILED" "The /clear never took on $pane (session unchanged). Shepherd did NOT roll over and is idle. Type: $msg"
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
          rlog VERIFIED "session=$new received the recovery prompt on attempt $a; rollover complete"
          FINAL=1; exit 0
        fi
        [ "$(date +%s)" -ge "$vdead" ] && break
        sleep "$POLL"
      done
      rlog POLL "phase=verify attempt $a/$ATTEMPTS session=$new prompt not visible after ${VERIFY}s"
      a=$((a + 1))
    done
    rlog GIVE-UP "the recovery prompt never reached session $new on pane=$pane after $ATTEMPTS attempts"
    rtoast "shepherd context rollover FAILED" "Shepherd cleared but never restarted on $pane. Type: $msg"
    FINAL=1; exit 4
    ;;

  *) echo "unknown cmd: $cmd" >&2; exit 1;;
esac
