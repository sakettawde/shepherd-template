#!/usr/bin/env bash
# Probe for hooks/worker-stop.sh — the Stop hook that turns a worker's final
# message into the ground-truth `claim` record shepherd's status-file watcher
# reads (CLAUDE.md §2 rule 1).
#
# Every case is fed to the real hook as a real Stop payload, exactly as Claude
# Code delivers one (https://code.claude.com/docs/en/hooks): a JSON object on
# stdin carrying last_assistant_message. Exit code and output are ignored for
# Stop hooks, so what is asserted here is the RECORD the hook appends.
#
# Two properties are asserted together, and they pull against each other:
#   * the sentinel is recognised however a worker DECORATES it — bare, bold,
#     backticked, or both (T-0213: a backticked line recorded "claim": "none",
#     so the watcher never fired and the blocked worker sat unnoticed);
#   * the sentinel is still a LINE — a worker who merely writes *about* a claim
#     mid-paragraph records nothing (T-0093).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
HOOK="${STOP_HOOK:-$HERE/../../hooks/worker-stop.sh}"

# MANDATORY, and the first thing this file does after the sandbox: a worker
# session running this probe inherits its OWN SHEPHERD_TASK_ID and
# SHEPHERD_STATUS_FILE, and any case that does not set them explicitly would
# then append test records to the live instance's ground-truth status file.
unset SHEPHERD_TASK_ID SHEPHERD_STATUS_FILE

echo "test-stop:"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is available" "python3 not found — the hook and this probe both need it"
  finish
  exit
fi

# payload <last-assistant-message> — the Stop shape the hooks reference documents
payload() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps({
    "session_id":"test","hook_event_name":"Stop","stop_reason":"end_turn",
    "permission_mode":"auto","transcript_path":"/tmp/t.jsonl",
    "last_assistant_message":sys.argv[1]}))' "$1"
}

# field <status-file> <key> — the value of <key> on the file's last record
field() {
  python3 -c 'import json,sys
line=[l for l in open(sys.argv[1],encoding="utf-8") if l.strip()][-1]
sys.stdout.write(str(json.loads(line).get(sys.argv[2],"")))' "$1" "$2"
}

# fire <status-file> <payload-json> — run the hook the way Claude Code does
fire() {
  local f="$1" json="$2"
  SHEPHERD_TASK_ID=T-TEST SHEPHERD_STATUS_FILE="$f" bash "$HOOK" <<<"$json" >/dev/null 2>&1
}

# claim_of <message> — the claim the hook records for that final message
claim_of() {
  local f="$SHEPHERD_ROOT/one.jsonl"
  rm -f "$f"
  fire "$f" "$(payload "$1")"
  field "$f" claim
}

STATUS="$SHEPHERD_ROOT/T-TEST.jsonl"

# --- the sentinel is recognised however it is decorated --------------------
# The template shows the line in backticks, so workers copy it that way; bold
# is what an unprompted worker reaches for. Both must record.
assert_eq "bare sentinel" \
  "$(claim_of 'Work paused.

SHEPHERD: blocked — need a ruling')" "blocked"
assert_eq "bold sentinel" \
  "$(claim_of 'Work paused.

**SHEPHERD: blocked — need a ruling**')" "blocked"
assert_eq "backticked sentinel" \
  "$(claim_of 'Work paused.

`SHEPHERD: blocked — need a ruling`')" "blocked"
assert_eq "bold + backticked sentinel" \
  "$(claim_of 'Work paused.

**`SHEPHERD: blocked — need a ruling`**')" "blocked"
assert_eq "triple-emphasis sentinel" \
  "$(claim_of '***SHEPHERD: done — shipped***')" "done"
assert_eq "underscore-emphasised sentinel" \
  "$(claim_of '_SHEPHERD: failed — DoD never passed_')" "failed"
assert_eq "indented backticked sentinel" \
  "$(claim_of '  `SHEPHERD: working — halfway`')" "working"

# --- all four claim words ---------------------------------------------------
for c in done blocked failed working; do
  assert_eq "records claim $c" "$(claim_of "\`SHEPHERD: $c — x\`")" "$c"
done

# --- but it is still a LINE, not a substring (T-0093) -----------------------
assert_eq "mid-paragraph mention records none" \
  "$(claim_of 'The card T-0093 was recorded SHEPHERD: failed yesterday, which was wrong.')" "none"
assert_eq "backticked mid-paragraph mention records none" \
  "$(claim_of 'Its tail ended `SHEPHERD: working` and nobody noticed.')" "none"
assert_eq "no sentinel at all records none" \
  "$(claim_of 'All finished, tests green.')" "none"

# --- the LAST sentinel in the turn is the one recorded ----------------------
assert_eq "last sentinel wins" \
  "$(claim_of 'First checkpoint.

SHEPHERD: working — still going

Then it finished.

`SHEPHERD: done — merged`')" "done"

# --- the record carries the task id and one line per firing -----------------
rm -f "$STATUS"
fire "$STATUS" "$(payload '`SHEPHERD: done — x`')"
fire "$STATUS" "$(payload 'SHEPHERD: working — x')"
assert_eq "one record appended per firing" "$(grep -c '"event": "stop"' "$STATUS")" "2"
assert_eq "record carries the task id" "$(field "$STATUS" task)" "T-TEST"
assert_eq "record carries the session id" "$(field "$STATUS" session_id)" "test"

# --- a subagent must never speak for the worker -----------------------------
SUB="$SHEPHERD_ROOT/sub.jsonl"
fire "$SUB" '{"session_id":"test","hook_event_name":"SubagentStop","last_assistant_message":"`SHEPHERD: done — x`"}'
assert_nofile "SubagentStop writes no record" "$SUB"
fire "$SUB" '{"session_id":"test","hook_event_name":"Stop","agent_id":"a1","last_assistant_message":"`SHEPHERD: done — x`"}'
assert_nofile "a payload carrying agent_id writes no record" "$SUB"

# --- non-worker sessions are untouched --------------------------------------
OUTSIDE="$SHEPHERD_ROOT/outside.jsonl"
SHEPHERD_STATUS_FILE="$OUTSIDE" bash "$HOOK" <<<"$(payload 'SHEPHERD: done — x')" >/dev/null 2>&1
assert_eq "no task id, hook exits 0" "$?" "0"
assert_nofile "no record without SHEPHERD_TASK_ID" "$OUTSIDE"

before=$(find "$SHEPHERD_ROOT" -type f | wc -l)
SHEPHERD_TASK_ID=T-TEST bash "$HOOK" <<<"$(payload 'SHEPHERD: done — x')" >/dev/null 2>&1
assert_eq "no status file, hook exits 0" "$?" "0"
assert_eq "no status file, nothing written" "$(find "$SHEPHERD_ROOT" -type f | wc -l)" "$before"

finish
