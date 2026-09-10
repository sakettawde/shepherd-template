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
HOOK="${NOTIFY_HOOK:-$HERE/../hooks/worker-notify.sh}"

# MANDATORY, and the first thing this file does after the sandbox: a worker
# session running this probe inherits its OWN SHEPHERD_TASK_ID and
# SHEPHERD_STATUS_FILE, and any case that does not set them explicitly would
# then append test records to the live instance's ground-truth status file.
# Measured, not theorised — it happened while this probe was being written.
unset SHEPHERD_TASK_ID SHEPHERD_STATUS_FILE

# And the same for HERDR_ENV, so the header above is true rather than hopeful:
# a probe run from inside a worker's own herdr pane inherits HERDR_ENV=1, and the
# three allowlisted kinds would then reach the live `herdr notification show`.
unset HERDR_ENV

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

# fire <status-file> <payload-json> — run the hook the way Claude Code does.
# The task id is the file's own basename: the hook refuses a pair that
# disagrees (T-0223), so every fixture here agrees by construction.
fire() {
  local f="$1" json="$2"
  local id=${f##*/}; id=${id%.jsonl}
  SHEPHERD_TASK_ID=$id SHEPHERD_STATUS_FILE="$f" bash "$HOOK" <<<"$json" >/dev/null 2>&1
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
env -u SHEPHERD_TASK_ID SHEPHERD_STATUS_FILE="$OUTSIDE" bash "$HOOK" <<<"$(payload agent_completed)" >/dev/null 2>&1
assert_eq "no task id, hook exits 0" "$?" "0"
assert_nofile "no record without SHEPHERD_TASK_ID" "$OUTSIDE"

before=$(find "$SHEPHERD_ROOT" -type f | wc -l)
env -u SHEPHERD_STATUS_FILE SHEPHERD_TASK_ID=T-TEST bash "$HOOK" <<<"$(payload agent_completed)" >/dev/null 2>&1
assert_eq "no status file, hook exits 0" "$?" "0"
assert_eq "no status file, nothing written" "$(find "$SHEPHERD_ROOT" -type f | wc -l)" "$before"

# --- the toast allowlist ---------------------------------------------------
# Read from the source, because the toast itself cannot fire in a test (HERDR_ENV
# is unset). agent_completed is deliberately NOT on it: a finished worker is the
# watcher's business, not an interruption for the operator.
allow=$(sed -n 's/^  \(permission_prompt|.*\)) ;;$/\1/p' "$HOOK")
assert_eq "toast allowlist is exactly the three input-needed kinds" \
  "$allow" "permission_prompt|elicitation_dialog|agent_needs_input"

# --- a hook that cannot record says so (T-0214) -----------------------------
# The old hook wrapped its whole body in `2>/dev/null || true`: a malformed
# payload or an unwritable file left nothing behind, and shepherd read the
# silence as a quiet worker. Now the failure is a record of its own.
ERRF="$SHEPHERD_ROOT/T-ERR.jsonl"
SHEPHERD_TASK_ID=T-ERR SHEPHERD_STATUS_FILE="$ERRF" bash "$HOOK" <<<'this is not json' >/dev/null 2>&1
assert_eq "malformed payload: hook exits 0" "$?" "0"
assert_eq "malformed payload: a hook_error record is written" "$(field "$ERRF" event)" "hook_error"
assert_eq "malformed payload: the record names the hook" "$(field "$ERRF" kind)" "notify"
assert_ok "malformed payload: the record says why" grep -q 'not JSON' "$ERRF"

# The status file itself unwritable → the sidecar carries the report.
RO="$SHEPHERD_ROOT/T-RO.jsonl"; : >"$RO"; chmod 444 "$RO"
SHEPHERD_TASK_ID=T-RO SHEPHERD_STATUS_FILE="$RO" bash "$HOOK" <<<"$(payload permission_prompt "x")" >/dev/null 2>&1
assert_eq "unwritable status file: hook exits 0" "$?" "0"
assert_file "unwritable status file: the .err sidecar exists" "$RO.err"
assert_ok "unwritable status file: the sidecar names the hook" grep -q ' notify ' "$RO.err"
chmod 644 "$RO"

# python3 missing → the shell layer writes the hook_error itself.
NOPY=$(mktemp -d); trap 'rm -rf "$SHEPHERD_ROOT" "$NOPY"' EXIT
printf '#!/bin/sh\nexit 127\n' >"$NOPY/python3"; chmod +x "$NOPY/python3"
PYLESS="$SHEPHERD_ROOT/T-NOPY.jsonl"
SHEPHERD_TASK_ID=T-NOPY SHEPHERD_STATUS_FILE="$PYLESS" PATH="$NOPY:$PATH" bash "$HOOK" <<<"$(payload permission_prompt "x")" >/dev/null 2>&1
assert_eq "python3 failing: hook exits 0" "$?" "0"
assert_ok "python3 failing: a hook_error record is written by the shell" grep -q '"event": "hook_error"' "$PYLESS"
assert_ok "python3 failing: the record names the hook" grep -q '"kind": "notify"' "$PYLESS"

# --- the wrapper survives a missing library (T-0214, fix round 1) -----------
# `.` on an unreadable file aborts a POSIX shell outright - measured at exit 2
# under dash, which is /bin/sh here. For a Stop hook on this same wrapper shape
# an exit 2 BLOCKS the worker's turn, the one thing no hook here may do. So the
# wrapper must record the failure without the library and still exit 0. Run
# under sh, not bash: dash's `.`-abort is the path under test, and bash merely
# warns and carries on.
NOLIB="$SHEPHERD_ROOT/nolib"; mkdir -p "$NOLIB/lib"
cp "$HOOK" "$NOLIB/worker-notify.sh"
NOLIBF="$SHEPHERD_ROOT/T-NOLIB.jsonl"
SHEPHERD_TASK_ID=T-NOLIB SHEPHERD_STATUS_FILE="$NOLIBF" sh "$NOLIB/worker-notify.sh" <<<"$(payload permission_prompt "x")" >/dev/null 2>&1
assert_eq "missing run-hook.sh: hook exits 0" "$?" "0"
assert_eq "missing run-hook.sh: a hook_error record is written" "$(field "$NOLIBF" event)" "hook_error"
assert_eq "missing run-hook.sh: the record names the hook" "$(field "$NOLIBF" kind)" "notify"
assert_ok "missing run-hook.sh: the record says which file is gone" grep -q 'run-hook\.sh' "$NOLIBF"

# --- the two env vars must name the SAME task (T-0223) ----------------------
# test-stop.sh carries the why. This probe has the python-less fixture, so it
# is where the ORDER is pinned: a mismatch reaches the sidecar whether python3
# works or not, so no arm of the python branch can start writing again. The
# fixture is a python3 that EXITS 1, not a missing one, so what it proves is
# that the pair outranks python3's result; `command -v` still succeeds.
MM="$SHEPHERD_ROOT/T-TEST.jsonl"; rm -f "$MM" "$MM.err"
fire "$MM" "$(payload idle_prompt "x")"
SHEPHERD_TASK_ID=T-OTHER SHEPHERD_STATUS_FILE="$MM" bash "$HOOK" <<<"$(payload permission_prompt "x")" >/dev/null 2>&1
assert_eq "mismatched pair: hook exits 0" "$?" "0"
assert_eq "mismatched pair: nothing lands in the other task's file" "$(grep -c '' "$MM")" "1"
assert_eq "mismatched pair: one sidecar line" "$(grep -c '' "$MM.err")" "1"
assert_ok "mismatched pair: the line names the stray task id and the hook" grep -q 'T-OTHER.* notify \|notify .*T-OTHER' "$MM.err"
SHEPHERD_TASK_ID=T-OTHER SHEPHERD_STATUS_FILE="$MM" PATH="$NOPY:$PATH" bash "$HOOK" <<<"$(payload permission_prompt "x")" >/dev/null 2>&1
assert_eq "mismatched pair, python3 failing: hook exits 0" "$?" "0"
assert_eq "mismatched pair, python3 failing: still nothing in the file" "$(grep -c '' "$MM")" "1"
assert_eq "mismatched pair, python3 failing: a second sidecar line" "$(grep -c '' "$MM.err")" "2"
NOLIBMM="$SHEPHERD_ROOT/nolib-mm.jsonl"; : >"$NOLIBMM"
SHEPHERD_TASK_ID=T-OTHER SHEPHERD_STATUS_FILE="$NOLIBMM" sh "$NOLIB/worker-notify.sh" <<<"$(payload permission_prompt "x")" >/dev/null 2>&1
assert_eq "missing run-hook.sh, mismatched pair: hook exits 0" "$?" "0"
assert_eq "missing run-hook.sh, mismatched pair: the file stays empty" "$(grep -c '' "$NOLIBMM")" "0"
assert_ok "missing run-hook.sh, mismatched pair: the sidecar names the stray task id" grep -q 'T-OTHER' "$NOLIBMM.err"

finish
