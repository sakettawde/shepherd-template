#!/usr/bin/env bash
# Probe for hooks/worker-notify.sh — the Notification hook that turns a worker's
# notification into a status-file record (shepherd's watcher reads it) and, for a
# few kinds only, into an operator toast.
#
# Every case is fed to the real hook as a real Notification payload, exactly as
# Claude Code delivers one (https://code.claude.com/docs/en/hooks): a JSON object
# on stdin carrying notification_type. Exit code and output are ignored for
# Notification hooks, so what is asserted here is the RECORD the hook appends.
#
# HERDR_ENV is deliberately left unset: the toast branch must never fire from a
# test run. What the toast branch would have done is asserted from the allowlist
# in the hook source instead.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
HOOK="${NOTIFY_HOOK:-$HERE/../../hooks/worker-notify.sh}"

# MANDATORY, and the first thing this file does after the sandbox: a worker
# session running this probe inherits its OWN SHEPHERD_TASK_ID and
# SHEPHERD_STATUS_FILE, and any case that does not set them explicitly would
# then append test records to the live instance's ground-truth status file.
# Measured, not theorised — it happened while this probe was being written.
unset SHEPHERD_TASK_ID SHEPHERD_STATUS_FILE

echo "test-notify:"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is available" "python3 not found — the hook and this probe both need it"
  finish
  exit
fi

# payload <notification_type> [message] — the flat shape documented at
# https://code.claude.com/docs/en/hooks ("Notification Hook Input Data")
payload() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps({
    "session_id":"test","hook_event_name":"Notification",
    "notification_type":sys.argv[1],"message":(sys.argv[2] if len(sys.argv)>2 else "")}))' "$@"
}

# nested_payload <notification_type> <message> — the notification_data shape the
# Notification reference page shows for the same event. The hook must read both.
nested_payload() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps({
    "session_id":"test","hook_event_name":"Notification",
    "notification_type":sys.argv[1],
    "notification_data":{"title":"Permission Required","message":sys.argv[2]}}))' "$@"
}

# field <status-file> <key> — the value of <key> on the file s last record
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

STATUS="$SHEPHERD_ROOT/T-TEST.jsonl"

# --- F3a: the two agent kinds are recorded, not just the three long-registered ones
for kind in permission_prompt idle_prompt elicitation_dialog agent_needs_input agent_completed; do
  fire "$STATUS" "$(payload "$kind" "hello")"
  assert_eq "records kind $kind" "$(field "$STATUS" kind)" "$kind"
done

assert_eq "one record appended per firing" "$(grep -c '"event": "notification"' "$STATUS")" "5"
assert_eq "every record carries the task id" "$(field "$STATUS" task)" "T-TEST"

# --- the message travels in either documented shape ------------------------
fire "$STATUS" "$(payload agent_needs_input "flat body")"
assert_eq "message read from the flat payload" "$(field "$STATUS" message)" "flat body"

fire "$STATUS" "$(nested_payload agent_needs_input "nested body")"
assert_eq "message read from notification_data" "$(field "$STATUS" message)" "nested body"
assert_eq "kind still read from the nested payload" "$(field "$STATUS" kind)" "agent_needs_input"

# --- an unclassified kind is still recorded (allowlist, not denylist) ------
fire "$STATUS" "$(payload auth_success)"
assert_eq "records a kind nobody has classified" "$(field "$STATUS" kind)" "auth_success"

# --- a payload with no notification_type still yields a usable record ------
fire "$STATUS" '{"session_id":"test","hook_event_name":"Notification"}'
assert_eq "falls back to the hook event name" "$(field "$STATUS" kind)" "Notification"

# --- non-worker sessions are untouched -------------------------------------
OUTSIDE="$SHEPHERD_ROOT/outside.jsonl"
SHEPHERD_STATUS_FILE="$OUTSIDE" bash "$HOOK" <<<"$(payload agent_completed)" >/dev/null 2>&1
assert_eq "no task id, hook exits 0" "$?" "0"
assert_nofile "no record without SHEPHERD_TASK_ID" "$OUTSIDE"

before=$(find "$SHEPHERD_ROOT" -type f | wc -l)
SHEPHERD_TASK_ID=T-TEST bash "$HOOK" <<<"$(payload agent_completed)" >/dev/null 2>&1
assert_eq "no status file, hook exits 0" "$?" "0"
assert_eq "no status file, nothing written" "$(find "$SHEPHERD_ROOT" -type f | wc -l)" "$before"

# --- the toast allowlist ---------------------------------------------------
# Read from the source, because the toast itself cannot fire in a test (HERDR_ENV
# is unset). agent_completed is deliberately NOT on it: a finished worker is the
# watcher's business, not an interruption for the operator.
allow=$(sed -n 's/^  \(permission_prompt|.*\)) ;;$/\1/p' "$HOOK")
assert_eq "toast allowlist is exactly the three input-needed kinds" \
  "$allow" "permission_prompt|elicitation_dialog|agent_needs_input"

finish
