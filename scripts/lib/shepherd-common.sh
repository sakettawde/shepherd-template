# Shared helpers for shepherd's multi-instance coordination scripts.
# Sourced by lock.sh, reserve-task-id.sh, ledger-commit.sh, shepherd-identity.sh.
# Never executed directly. See docs/specs/multi-shepherd-design.md.

# Default: the shepherd clone this library lives in (scripts/lib/.. /..).
# Tests and drills override SHEPHERD_ROOT to point at a sandbox instead.
SHEPHERD_ROOT="${SHEPHERD_ROOT:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
LOCKS_DIR="$SHEPHERD_ROOT/ledger/locks"
TASKS_DIR="$SHEPHERD_ROOT/ledger/tasks"
SHEPHERDS_DIR="$SHEPHERD_ROOT/ledger/shepherds"

now_iso() { date -Iseconds; }

# hooks_active — 0 when the test hooks below (SHEPHERD_PANE_SESSION_OVERRIDE,
# SHEPHERD_LIVENESS_OVERRIDE, SHEPHERD_LIVENESS_UNKNOWN) are allowed to take
# effect, 1 otherwise. Gated on SHEPHERD_TEST_HOOKS=1, which only
# scripts/tests/harness.sh's sandbox() sets. Every site that reads one of
# those variables — pane_probe, shepherd_live, and the sweep pre-flights in
# lock.sh/reserve-task-id.sh — must check this first. Without the gate, one
# of these variables leaking into an operator's real shell (a leftover
# export, a copy-pasted debug session) could fabricate liveness answers or
# defeat the "herdr unreachable" safety pre-flight that authorises sweep's
# deletes — the exact failure mode a hostile or accidental value here must
# never be able to reach.
hooks_active() { [ "${SHEPHERD_TEST_HOOKS:-0}" = "1" ]; }

# atomic_create <target> <content>
#   0 = this call created <target>, 1 = it already existed, 2 = error.
# The content is written to a temp file in the same directory and then
# hardlinked into place. link(2) fails with EEXIST if the target exists, so
# exactly one racer wins — and the target never exists empty, which a plain
# O_EXCL redirect cannot promise (it opens, then writes).
atomic_create() {
  local target=$1 content=$2 dir tmp
  dir=$(dirname "$target")
  mkdir -p "$dir" || return 2
  tmp=$(mktemp "$dir/.tmp.XXXXXX") || return 2
  if ! printf '%s\n' "$content" > "$tmp"; then rm -f "$tmp"; return 2; fi
  if ln "$tmp" "$target" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  [ -e "$target" ] && return 1
  return 2
}

# pane_probe <pane> — tri-state liveness probe against a single pane.
#   0 = the pane exists and runs a Claude session; prints the session id.
#   1 = definitively no such pane, or the pane runs no Claude session.
#   2 = cannot tell (herdr unreachable, no output on either stream, output
#       was not JSON, any error code other than "pane_not_found", or a
#       document with no usable "pane" object). If python3 itself is
#       missing, this function propagates its shell exit code (127, not 2)
#       — only shepherd_live's tri-state normalisation folds that into
#       "cannot tell".
# Never trust herdr's exit status. On this machine (herdr 0.7.4) a live
# pane's document lands on stdout with exit 0; a missing pane's
# pane_not_found document lands on STDERR with exit 1. Only the JSON body —
# never $? — decides which of the three outcomes this is. Prefer stdout so
# a well-formed success document stays authoritative even if herdr also
# writes to stderr; fall back to stderr only when stdout is empty.
pane_probe() {
  local pane=$1 out tmp
  # Test hook: stands in for a real herdr round-trip so callers — and their
  # tests — don't need a live pane. shepherd_live and the sweep pre-flights
  # call pane_probe directly, so the hook lives here, not in pane_session.
  # Gated on hooks_active (SHEPHERD_TEST_HOOKS=1) — see its doc comment.
  if hooks_active && [ -n "${SHEPHERD_PANE_SESSION_OVERRIDE:-}" ]; then
    printf '%s\n' "$SHEPHERD_PANE_SESSION_OVERRIDE"
    return 0
  fi
  tmp=$(mktemp) || return 2
  out=$(herdr pane get "$pane" 2>"$tmp")
  [ -n "$out" ] || out=$(cat "$tmp" 2>/dev/null)
  rm -f "$tmp"
  [ -n "$out" ] || return 2
  printf '%s' "$out" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if not isinstance(d, dict):
    sys.exit(2)
err = d.get("error")
if isinstance(err, dict):
    sys.exit(1 if err.get("code") == "pane_not_found" else 2)
try:
    pane = d["result"]["pane"]
except Exception:
    sys.exit(2)
if not isinstance(pane, dict):
    sys.exit(2)
try:
    sid = pane["agent_session"]["value"]
except Exception:
    sid = None
if not sid:
    sys.exit(1)
sys.stdout.write(str(sid))
sys.exit(0)
'
  return $?
}

# pane_session <pane-id> — prints the Claude session id herdr reports.
# Non-zero (1 or 2 from pane_probe) when it cannot. Implemented in terms of
# pane_probe: existing and future callers only need "did I get an id", not
# the distinction between definitively-gone and cannot-tell.
pane_session() {
  pane_probe "$1"
}

# shepherd_live <pane> <session> — tri-state liveness for one holder.
#   0 = live — the pane exists and runs exactly that session.
#   1 = definitively dead — the pane is gone, or runs a different session,
#       or runs none.
#   2 = cannot tell.
# Callers written as `if shepherd_live …; then` keep working unchanged,
# because only 0 is success; a caller that acts on a negative must branch
# on $? to tell "dead" apart from "cannot tell".
#
# Tests bypass herdr with two space-separated "<pane>:<session>" lists:
# SHEPHERD_LIVENESS_UNKNOWN (checked first — a listed pair returns 2) and
# SHEPHERD_LIVENESS_OVERRIDE (a listed pair returns 0, an unlisted one
# returns 1; setting it empty declares everything dead). This whole hook
# pair is gated on hooks_active (SHEPHERD_TEST_HOOKS=1 — see its doc
# comment): outside a test harness both variables are inert, no matter what
# they're set to. When the gate is on and EITHER variable is set — even to
# an empty string — herdr is never called: a pair that matches neither list
# resolves to 1 (definitively dead). Only when the gate is off, or both
# hooks are completely unset, does shepherd_live fall through to a real
# herdr round-trip via pane_probe.
shepherd_live() {
  local pane=$1 session=$2 got rc
  if hooks_active && { [ -n "${SHEPHERD_LIVENESS_UNKNOWN+x}" ] || [ -n "${SHEPHERD_LIVENESS_OVERRIDE+x}" ]; }; then
    if [ -n "${SHEPHERD_LIVENESS_UNKNOWN+x}" ]; then
      case " $SHEPHERD_LIVENESS_UNKNOWN " in
        *" $pane:$session "*) return 2 ;;
      esac
    fi
    if [ -n "${SHEPHERD_LIVENESS_OVERRIDE+x}" ]; then
      case " $SHEPHERD_LIVENESS_OVERRIDE " in
        *" $pane:$session "*) return 0 ;;
      esac
    fi
    return 1
  fi
  got=$(pane_probe "$pane" 2>/dev/null)
  rc=$?
  case $rc in
    0) [ "$got" = "$session" ] && return 0 || return 1 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# task_state <task-id> — prints the card's state: value, nothing if absent.
task_state() {
  local id=$1
  local f="$TASKS_DIR/$id.md"
  [ -f "$f" ] || return 1
  sed -n 's/^state: *\([a-z]*\).*/\1/p' "$f" | head -1
}
