# Sourced by hooks/worker-*.sh. Never executed directly. POSIX sh.
#
# shepherd_hook_run <kind> <program.py>
#   Runs the hook's Python program with the hook payload still on stdin and
#   the program's stdout passed through. Whatever happens, the caller's exit
#   code is 0: a Stop hook that exits 2 blocks the worker's turn, and no hook
#   here may ever do that. A failure - python3 missing, the program crashing
#   before it could report - is written where shepherd reads it, never
#   swallowed (T-0214; before this, every hook ended `2>/dev/null || true`).

# shepherd_hook_pair_ok - 0 when SHEPHERD_STATUS_FILE is SHEPHERD_TASK_ID's own
# file. The wrappers check that the two are non-empty; this is the check that
# they AGREE. A worker relaunched with a stale id in one of the pair - or a
# probe that overrode one and inherited the other, measured 2026-09-02 - wrote
# its turn into ANOTHER task's ground truth (CLAUDE.md §2 rule 1), and nothing
# said so (T-0214's report; T-0223). The file's basename is the task's own, so
# the comparison is the whole check - the same one scripts/bin/shepherd-status
# makes before it writes a claim.
shepherd_hook_pair_ok() {
  [ "${SHEPHERD_STATUS_FILE##*/}" = "$SHEPHERD_TASK_ID.jsonl" ]
}

# shepherd_hook_mismatch <kind> - the disagreement, reported where a failed
# write is reported: the sidecar beside the file that was about to receive
# another task's record, then stderr. Never the status file itself - a record
# there, even one announcing the mismatch, is the corruption being prevented.
# The wrappers' hand-built record (run-hook.sh missing) makes the same refusal
# without these helpers, in the same words.
#
# Both env values are FOLDED and TRUNCATED before they are printed, for the
# reason shepherd_hook_error spends the block below on: these two strings come
# from a launch line, and a newline in either would make one failure into
# several sidecar lines - the one-line-per-failure shape monitor reads.
shepherd_hook_mismatch() {
  _shm_ts=$(date +%Y-%m-%dT%H:%M:%S%z)
  _shm_id=$(printf '%s' "$SHEPHERD_TASK_ID" | tr -c '[:print:] ' ' ' | cut -c1-80)
  _shm_file=$(printf '%s' "$SHEPHERD_STATUS_FILE" | tr -c '[:print:] ' ' ' | cut -c1-160)
  _shm_msg="SHEPHERD_TASK_ID $_shm_id is not the task of $_shm_file (expected basename $_shm_id.jsonl); nothing recorded"
  printf '%s %s %s\n' "$_shm_ts" "$1" "$_shm_msg" >>"$SHEPHERD_STATUS_FILE.err" 2>/dev/null \
    || printf 'shepherd hook %s: %s\n' "$1" "$_shm_msg" >&2
}

# shepherd_hook_error <kind> <message> - pure shell, for when python3 itself
# is unusable. Same record shape as shepherd_status.hook_error, same fallbacks:
# the status file, then the .err sidecar, then stderr - the status file only
# while the pair agrees (a mismatch skips straight to the sidecar).
#
# The message is FOLDED, then TRUNCATED, then ESCAPED, and that order is the
# whole point. Escaping first and cutting after put the cut inside an escape:
# 177 A's followed by twelve backslashes left a trailing lone backslash that
# escaped the closing quote, and 199 B's followed by a quote cut the `\"` in
# half - both measured unparseable, 2026-09-02. Folding first is the other
# half: `tr '\n\t'` let every other control byte through raw, and a single
# carriage return is enough to make the line invalid JSON. tr -c keeps
# printable ASCII and space and turns everything else - control bytes and
# non-ASCII alike - into a space, so the result is always valid UTF-8 too: a
# cut through a multi-byte character would raise UnicodeDecodeError in
# shepherd-watch's reader, which parses no line of the file after it.
#
# It matters because BOTH readers (shepherd-watch's status_py, worker_stop.py) skip
# a line they cannot parse. An unparseable hook_error is the record announcing
# that a hook failed being thrown away for the same reason.
shepherd_hook_error() {
  _shk_kind=$1
  _shk_msg=$(printf '%s' "$2" | tr -c '[:print:] ' ' ' | cut -c1-180 | sed 's/\\/\\\\/g; s/"/\\"/g')
  _shk_ts=$(date +%Y-%m-%dT%H:%M:%S%z)
  _shk_line=$(printf '{"ts": "%s", "event": "hook_error", "task": "%s", "kind": "%s", "message": "%s"}' \
    "$_shk_ts" "$SHEPHERD_TASK_ID" "$_shk_kind" "$_shk_msg")
  { shepherd_hook_pair_ok && printf '%s\n' "$_shk_line" >>"$SHEPHERD_STATUS_FILE" 2>/dev/null; } \
    || printf '%s %s %s\n' "$_shk_ts" "$_shk_kind" "$_shk_msg" >>"$SHEPHERD_STATUS_FILE.err" 2>/dev/null \
    || printf 'shepherd hook %s: %s\n' "$_shk_kind" "$_shk_msg" >&2
}

shepherd_hook_run() {
  _shr_kind=$1
  _shr_program=$2
  # Before python3 is even looked for: a mismatch is refused on every path.
  if ! shepherd_hook_pair_ok; then
    shepherd_hook_mismatch "$_shr_kind"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    shepherd_hook_error "$_shr_kind" "python3 not found; nothing recorded for this event"
    return 0
  fi
  _shr_errf=$(mktemp "${TMPDIR:-/tmp}/shepherd-hook.XXXXXX" 2>/dev/null) || _shr_errf=/dev/null
  python3 "$_shr_program" 2>"$_shr_errf"
  _shr_rc=$?
  if [ "$_shr_rc" -ne 0 ]; then
    shepherd_hook_error "$_shr_kind" "$(basename "$_shr_program") exited $_shr_rc: $(head -c 200 "$_shr_errf" 2>/dev/null)"
  fi
  [ "$_shr_errf" = /dev/null ] || rm -f "$_shr_errf"
  return 0
}
