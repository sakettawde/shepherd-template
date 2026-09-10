# Shared helpers for shepherd's instance-side commands.
# Sourced by shepherd-lock, shepherd-reserve, shepherd-commit, shepherd-identity
# and the other bin/ commands that touch the ledger. Never executed directly.
# See ${CLAUDE_PLUGIN_ROOT}/docs/specs/2026-08-18-multi-shepherd-design.md.
#
# Worker-side commands (shepherd-status, shepherd-reply) and every hook do NOT
# source this file, on purpose: they need no root at all, only the two env vars
# the launch line hands them. That is what makes the refusal below safe.

# --- SHEPHERD_ROOT: three rungs, no default ---------------------------------
# The instance repository this command acts on. The hard-coded default that
# used to sit here made the framework unusable on a second machine and by any
# other operator (T-0218 §4). The rungs, in order:
#   1. $SHEPHERD_ROOT from the environment. The test harness and shepherd-drill
#      set it; so may an operator.
#   2. git, from $PWD. `--git-common-dir` resolves a `shepherd~N` worktree lane
#      to the BASE checkout, which is where the one ledger lives — measured
#      2026-09-10: from a lane it prints the base checkout's .git, same as from
#      the base checkout itself. `--path-format=absolute` needs git >= 2.31.
#   3. Nothing. Refuse, loudly — the same fail-closed stance shepherd-lock
#      already takes on an empty holder.
# The resolved root must hold .shepherd/instance.env, or this is not a shepherd
# instance and the command refuses rather than writing a ledger somewhere else.
shepherd_resolve_root() {
  if [ -n "${SHEPHERD_ROOT:-}" ]; then
    printf '%s\n' "${SHEPHERD_ROOT%/}"
    return 0
  fi
  local d
  d=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$d" ] || return 1
  d=${d%/}
  d=${d%/.git}
  [ -n "$d" ] || return 1
  printf '%s\n' "$d"
}

if ! SHEPHERD_ROOT=$(shepherd_resolve_root); then
  echo "ERROR: cannot resolve SHEPHERD_ROOT: \$SHEPHERD_ROOT is unset and $PWD is not inside a git repository. Run from the instance checkout, or set SHEPHERD_ROOT." >&2
  exit 2
fi
if [ ! -f "$SHEPHERD_ROOT/.shepherd/instance.env" ]; then
  echo "ERROR: $SHEPHERD_ROOT is not a shepherd instance: no .shepherd/instance.env. Run /shepherd:init to create one." >&2
  exit 2
fi
export SHEPHERD_ROOT

# The operator facts, machine-readable. instance.env is committed; local.env is
# gitignored and overrides the machine-specific values (SHEPHERD_CODE_DIR) on a
# second machine. Both are the operator's own files in the operator's own repo,
# so sourcing them is the same trust level as running this script at all.
# shellcheck disable=SC1090,SC1091
. "$SHEPHERD_ROOT/.shepherd/instance.env"
if [ -r "$SHEPHERD_ROOT/.shepherd/local.env" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$SHEPHERD_ROOT/.shepherd/local.env"
fi
LOCKS_DIR="$SHEPHERD_ROOT/ledger/locks"
TASKS_DIR="$SHEPHERD_ROOT/ledger/tasks"
SHEPHERDS_DIR="$SHEPHERD_ROOT/ledger/shepherds"
# The events log: one line per coordination verdict, append-only, gitignored
# (machine-local runtime state, like ledger/locks/). Line shape:
#   <iso8601> <instance> <verb> <target> <verdict> [detail...]
# See docs/specs/2026-09-02-coordination-hardening-design.md S2.
EVENTS_LOG="$SHEPHERD_ROOT/ledger/events.log"

# The one pattern every lock name must match before any file is touched.
# Admits dispatch, card-_index, project-karta~2, shepherd-kelpie.reclaim;
# rejects `/` (a path escape that once wrote a lock outside LOCKS_DIR where
# sweep could never find it), whitespace (a field shift), and a leading `.`
# (a name the `.tmp.*` cleanup glob would match).
NAME_PATTERN='^[A-Za-z0-9_][A-Za-z0-9_.~-]*$'
# The identity pattern. The `shepherd-` prefix is load-bearing: shepherd-lock sweep
# recognises an identity lock by its `shepherd-*` glob. The suffix is
# lowercase alphanumeric words joined by single hyphens.
SHEPHERD_ID_PATTERN='^shepherd-[a-z0-9]+(-[a-z0-9]+)*$'

# now_iso - the one clock every script reads. Tests stub it through
# SHEPHERD_NOW_OVERRIDE, gated on hooks_active like every other hook: a
# fabricated timestamp could at most mislabel a LONG-HELD report, because
# nothing is ever reclaimed on a timestamp (multi-shepherd design S3.3).
now_iso() {
  if hooks_active && [ -n "${SHEPHERD_NOW_OVERRIDE:-}" ]; then
    printf '%s\n' "$SHEPHERD_NOW_OVERRIDE"
    return 0
  fi
  date -Iseconds
}

# elog <instance> <verb> <target> <verdict> [detail...]
#   Appends one event line to EVENTS_LOG. Always returns 0 and prints
#   nothing: the log is an audit trail, not a gate, so a coordination verb
#   must never refuse because the log is unwritable. An empty instance or
#   target is written as `-`, and whitespace inside any of the four fixed
#   columns is folded to `_`, so the five columns never shift — shepherd-lock
#   release takes an arbitrary holder string, and a holder with a space in
#   it would otherwise push every later column along. The atomicity
#   guarantee is O_APPEND plus the line being emitted as one write(2), which
#   holds while the line stays under bash's stdio buffer (about 4 KiB);
#   PIPE_BUF governs pipes, not regular files. So concurrent instances never
#   interleave inside a line and no lock is taken.
elog() {
  local instance=${1:--} verb=${2:--} target=${3:--} verdict=${4:--} detail
  if [ $# -ge 4 ]; then shift 4; else shift $#; fi
  instance=${instance//[[:space:]]/_}
  verb=${verb//[[:space:]]/_}
  target=${target//[[:space:]]/_}
  verdict=${verdict//[[:space:]]/_}
  detail="$*"
  detail=${detail//$'\n'/ }
  detail=${detail//$'\r'/ }
  {
    mkdir -p "$(dirname "$EVENTS_LOG")" &&
      printf '%s %s %s %s %s%s\n' "$(now_iso)" "$instance" "$verb" "$target" "$verdict" "${detail:+ $detail}" >> "$EVENTS_LOG"
  } 2>/dev/null || true
  return 0
}

# valid_name <what> <value> - 0 when <value> matches NAME_PATTERN, else 2
# with an ERROR line on stderr that names the rule. Run it before any file
# path is built from the value.
valid_name() {
  local what=$1 value=$2
  if [[ $value =~ $NAME_PATTERN ]]; then return 0; fi
  echo "ERROR: $what must match $NAME_PATTERN (got '$value')" >&2
  return 2
}

# valid_shepherd_id <id> - 0 when <id> matches SHEPHERD_ID_PATTERN, else 2.
valid_shepherd_id() {
  local id=$1
  if [[ $id =~ $SHEPHERD_ID_PATTERN ]]; then return 0; fi
  echo "ERROR: bad shepherd id: $id (want shepherd-<name>, lowercase letters/digits, e.g. shepherd-1 or shepherd-collie)" >&2
  return 2
}

# lock_line <file> - prints the first line of a lock file, nothing when the
# file is missing or empty. Always exits 0. Every compare-before-delete in
# the system reads through this so a test can stand a race in its place.
lock_line() {
  head -1 "$1" 2>/dev/null
  return 0
}

# hooks_active — 0 when the test hooks (SHEPHERD_PANE_SESSION_OVERRIDE,
# SHEPHERD_LIVENESS_OVERRIDE, SHEPHERD_LIVENESS_UNKNOWN, SHEPHERD_NOW_OVERRIDE)
# are allowed to take effect, 1 otherwise. Gated on SHEPHERD_TEST_HOOKS=1,
# which only tests/harness.sh's sandbox() sets. Every site that reads
# one of those variables — now_iso, pane_probe, pair_live, and the sweep
# pre-flights in shepherd-lock/reserve-task-id.sh — must check this first. Without
# the gate, one of these variables leaking into an operator's real shell (a
# leftover export, a copy-pasted debug session) could fabricate liveness
# answers or defeat the "herdr unreachable" safety pre-flight that authorises
# sweep's deletes — the exact failure mode a hostile or accidental value here
# must never be able to reach.
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
#   2 = unresolved (herdr unreachable, no output on either stream, output
#       was not JSON, any error code other than "pane_not_found", or a
#       document with no usable "pane" object). If python3 itself is
#       missing, this function propagates its shell exit code (127, not 2)
#       — only shepherd_live's tri-state normalisation folds that into
#       "unresolved".
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
# the distinction between gone and unresolved.
pane_session() {
  pane_probe "$1"
}

# pair_live <pane> <session> — tri-state liveness for one pane/session pair.
#   0 = live — the pane exists and runs exactly that session.
#   1 = gone — the pane is gone, or runs a different session,
#       or runs none.
#   2 = unresolved.
# Only 0 is success; a caller that acts on a negative must branch on $? to
# tell "gone" apart from "unresolved".
#
# Tests bypass herdr with two space-separated "<pane>:<session>" lists:
# SHEPHERD_LIVENESS_UNKNOWN (checked first — a listed pair returns 2) and
# SHEPHERD_LIVENESS_OVERRIDE (a listed pair returns 0, an unlisted one
# returns 1; setting it empty declares everything gone). This whole hook
# pair is gated on hooks_active (SHEPHERD_TEST_HOOKS=1 — see its doc
# comment): outside a test harness both variables are inert, no matter what
# they're set to. When the gate is on and EITHER variable is set — even to
# an empty string — herdr is never called: a pair that matches neither list
# resolves to 1 (gone). Only when the gate is off, or both
# hooks are completely unset, does pair_live fall through to a real
# herdr round-trip via pane_probe.
pair_live() {
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

# shepherd_live <pane> <session> [holder] — tri-state liveness for one holder.
#   0 = live, 1 = gone, 2 = unresolved. Two-argument calls are exactly
#   pair_live. With a third argument matching shepherd-*, a direct GONE is
#   re-resolved through that instance's identity lock
#   ($LOCKS_DIR/<holder>.lock): after a context rollover the pane's session
#   id changes, wake step 2 re-acquires the identity lock with the new pair,
#   and every other lock the instance holds still carries the old one. If the
#   identity lock names a different pair, that pair's own answer wins (0, 1
#   or 2). Same pair, or no usable identity lock -> gone, as before. A direct
#   live or unresolved answer is never re-resolved: an unresolved probe is
#   not evidence of anything, and the identity lock cannot make it one.
#   The gap between /clear and wake step 2, when the identity lock itself
#   still names the old session, is NOT covered - see
#   docs/specs/2026-09-02-coordination-hardening-design.md S6.3.
# Callers written as `if shepherd_live …; then` keep working unchanged.
shepherd_live() {
  local pane=$1 session=$2 holder=${3:-} rc f line i_holder i_pane i_session
  pair_live "$pane" "$session"
  rc=$?
  [ "$rc" -eq 1 ] || return "$rc"
  case $holder in shepherd-*) ;; *) return 1 ;; esac
  valid_name holder "$holder" 2>/dev/null || return 1
  f="$LOCKS_DIR/$holder.lock"
  line=$(lock_line "$f")
  i_holder= i_pane= i_session=
  [ -n "$line" ] && read -r i_holder i_pane i_session _ <<<"$line"
  if [ -z "$i_pane" ] || [ -z "$i_session" ]; then return 1; fi
  if [ "$i_pane" = "$pane" ] && [ "$i_session" = "$session" ]; then return 1; fi
  pair_live "$i_pane" "$i_session"
}

# The states in which a card is active - it holds its lane lock and a worker
# slot: the four between queued and the verdicts (CLAUDE.md S5). One home for
# every script that asks "which cards are active"; four spellings once drifted
# apart across shepherd-preflight, shepherd-wake-report, shepherd-rollover and
# shepherd-lock (T-0221 review).
ACTIVE_STATES='briefed working blocked review'

# active_cards — prints the path of every card in $TASKS_DIR whose state: is
# one of ACTIVE_STATES, sorted; nothing on an empty ledger. Always exits 0, so
# a `for f in $(active_cards)` under set -e reads an empty list, not a failure.
active_cards() {
  grep -lE "^state: (${ACTIVE_STATES// /|})" "$TASKS_DIR"/T-[0-9][0-9][0-9][0-9].md 2>/dev/null | sort
  return 0
}

# is_active_state <state> — 0 when <state> is one of ACTIVE_STATES, else 1.
is_active_state() {
  case " $ACTIVE_STATES " in *" $1 "*) return 0 ;; esac
  return 1
}

# task_state <task-id> — prints the card's state: value, nothing if absent.
task_state() {
  local id=$1
  local f="$TASKS_DIR/$id.md"
  [ -f "$f" ] || return 1
  sed -n 's/^state: *\([a-z]*\).*/\1/p' "$f" | head -1
}

# card_field <file> <field> — one header field of a task or registry card.
# The header runs from line 2 to the first blank line. A field that starts its
# line owns the text up to the first run of three or more spaces or the end of
# the line — the template packs `pane: … session: …`, `size: … tier: …
# budget: …` and trailing `# comments` behind such a run. A field that sits
# after one (`session:`, `tier:`, `budget:`) owns the next whitespace-free
# token. Prints the value; prints nothing and exits 1 when the field is absent.
card_field() {
  local file=$1 field=$2
  [ -f "$file" ] || return 1
  awk -v f="$field" '
    BEGIN { re = "(^|   +)" f ": *" }
    NR == 1 { next }
    NR > 1 && /^[[:space:]]*$/ { exit }
    match($0, re) {
      v = substr($0, RSTART + RLENGTH)
      if (RSTART == 1) sub(/   +.*$/, "", v); else sub(/[[:space:]].*$/, "", v)
      sub(/[[:space:]]+$/, "", v)
      print v; found = 1; exit
    }
    END { exit(found ? 0 : 1) }' "$file"
}

# card_owner <file> — `owner:`, or shepherd-1 when the line is absent or empty
# (CLAUDE.md S2 rule 10: every card written before the field existed is
# shepherd-1's).
card_owner() {
  local o
  o=$(card_field "$1" owner) || o=
  printf '%s\n' "${o:-shepherd-1}"
}

# card_kind <file> — `kind:`, or build when the line is absent or empty: every
# card written before the field existed is a build. `reply` is the read-only
# reply worker (templates/reply-card.md): no lane lock, no place in the FIFO.
card_kind() {
  local k
  k=$(card_field "$1" kind) || k=
  printf '%s\n' "${k:-build}"
}

# card_family <project> — the registry slug and lock family: `karta~2` -> karta.
card_family() { printf '%s\n' "${1%%~*}"; }

# card_log_time — HH:MM for a `## Log` line, from now_iso so a test can pin it.
card_log_time() { date -d "$(now_iso)" +%H:%M; }
