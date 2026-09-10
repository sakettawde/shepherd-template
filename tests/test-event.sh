#!/usr/bin/env bash
# Probe for hooks/worker-event.sh — one script registered under four Claude
# Code events (PermissionRequest, PermissionDenied, StopFailure, SessionEnd),
# each recorded as a status-file line with `event` naming the hook and `kind`
# its sub-type (spec: docs/superpowers/specs/2026-09-02-worker-observation-design.md §1).
#
# Every payload here is the shape the hooks reference documents for that event
# (https://code.claude.com/docs/en/hooks, read 2026-09-02). Exit codes are
# ignored by Claude Code for all four (exit 2 is "not honoured"), so what is
# asserted is the RECORD - and that the exit is 0 regardless.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
HOOK="${EVENT_HOOK:-$HERE/../hooks/worker-event.sh}"

# MANDATORY, and the first thing this file does after the sandbox: a worker
# session running this probe inherits its OWN SHEPHERD_TASK_ID and
# SHEPHERD_STATUS_FILE, and any case that does not set them explicitly would
# then append test records to the live instance's ground-truth status file.
unset SHEPHERD_TASK_ID SHEPHERD_STATUS_FILE

echo "test-event:"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is available" "python3 not found — the hook and this probe both need it"
  finish
  exit
fi

# field <status-file> <key> — the value of <key> on the file's last record
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
COMMON='"session_id":"sess-1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp","permission_mode":"auto"'

# --- PermissionRequest ------------------------------------------------------
fire "$STATUS" "{$COMMON,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /tmp/build\",\"description\":\"clean\"},\"tool_use_id\":\"toolu_01\"}"
assert_eq "PermissionRequest: event"   "$(field "$STATUS" event)" "permission_request"
assert_eq "PermissionRequest: kind is the tool" "$(field "$STATUS" kind)" "Bash"
assert_eq "PermissionRequest: summary is the command" "$(field "$STATUS" summary)" "rm -rf /tmp/build"
assert_eq "PermissionRequest: tool_use_id" "$(field "$STATUS" tool_use_id)" "toolu_01"
assert_eq "PermissionRequest: session id" "$(field "$STATUS" session_id)" "sess-1"
assert_eq "PermissionRequest: task"    "$(field "$STATUS" task)" "T-TEST"

fire "$STATUS" "{$COMMON,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/repo/a.py\",\"old_string\":\"x\",\"new_string\":\"y\"},\"tool_use_id\":\"toolu_02\"}"
assert_eq "PermissionRequest: summary is the file for a file tool" "$(field "$STATUS" summary)" "/repo/a.py"

fire "$STATUS" "{$COMMON,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"mcp__x__y\",\"tool_input\":{\"q\":\"1\"},\"tool_use_id\":\"toolu_03\"}"
assert_eq "PermissionRequest: summary falls back to the input as JSON" "$(field "$STATUS" summary)" '{"q": "1"}'

# A subagent's permission dialog parks the whole worker: recorded, with agent_id.
fire "$STATUS" "{$COMMON,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"tool_use_id\":\"toolu_04\",\"agent_id\":\"sub-1\",\"agent_type\":\"general-purpose\"}"
assert_eq "PermissionRequest inside a subagent is recorded" "$(field "$STATUS" event)" "permission_request"
assert_eq "PermissionRequest inside a subagent carries agent_id" "$(field "$STATUS" agent_id)" "sub-1"

# --- PermissionDenied -------------------------------------------------------
fire "$STATUS" "{$COMMON,\"hook_event_name\":\"PermissionDenied\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sudo rm -rf /\"},\"tool_use_id\":\"toolu_05\",\"denial_reason\":\"Destructive command\"}"
assert_eq "PermissionDenied: event"  "$(field "$STATUS" event)" "permission_denied"
assert_eq "PermissionDenied: kind is the tool" "$(field "$STATUS" kind)" "Bash"
assert_eq "PermissionDenied: reason" "$(field "$STATUS" reason)" "Destructive command"
assert_eq "PermissionDenied: summary" "$(field "$STATUS" summary)" "sudo rm -rf /"

# --- StopFailure ------------------------------------------------------------
fire "$STATUS" "{$COMMON,\"hook_event_name\":\"StopFailure\",\"error_type\":\"rate_limit\",\"error_message\":\"Rate limit exceeded\",\"last_assistant_message\":\"I was about to...\"}"
assert_eq "StopFailure: event"   "$(field "$STATUS" event)" "stop_failure"
assert_eq "StopFailure: kind is the error type" "$(field "$STATUS" kind)" "rate_limit"
assert_eq "StopFailure: message" "$(field "$STATUS" message)" "Rate limit exceeded"
assert_eq "StopFailure: tail"    "$(field "$STATUS" tail)" "I was about to..."

# --- SessionEnd -------------------------------------------------------------
fire "$STATUS" "{$COMMON,\"hook_event_name\":\"SessionEnd\",\"reason\":\"prompt_input_exit\",\"turn_count\":15}"
assert_eq "SessionEnd: event"  "$(field "$STATUS" event)" "session_end"
assert_eq "SessionEnd: kind is the reason" "$(field "$STATUS" kind)" "prompt_input_exit"
assert_eq "SessionEnd: turn count" "$(field "$STATUS" turn_count)" "15"

# Seven firings so far - four PermissionRequest, one each of the other three.
assert_eq "one record per firing" "$(grep -c '"task": "T-TEST"' "$STATUS")" "7"

# --- exit code is 0 for every event, and for everything else -------------
for ev in PermissionRequest PermissionDenied StopFailure SessionEnd; do
  SHEPHERD_TASK_ID=T-TEST SHEPHERD_STATUS_FILE="$STATUS" bash "$HOOK" <<<"{$COMMON,\"hook_event_name\":\"$ev\"}" >/dev/null 2>&1
  assert_eq "$ev with minimal fields exits 0" "$?" "0"
done

# --- an event this script was never registered for is an error, not silence -
fire "$STATUS" "{$COMMON,\"hook_event_name\":\"PreCompact\"}"
assert_eq "unhandled event: hook_error" "$(field "$STATUS" event)" "hook_error"
assert_ok "unhandled event: the record names it" grep -q 'PreCompact' "$STATUS"

# --- a hook that cannot record says so --------------------------------------
ERRF="$SHEPHERD_ROOT/T-ERR.jsonl"
SHEPHERD_TASK_ID=T-ERR SHEPHERD_STATUS_FILE="$ERRF" bash "$HOOK" <<<'garbage' >/dev/null 2>&1
assert_eq "malformed payload: hook exits 0" "$?" "0"
assert_eq "malformed payload: a hook_error record" "$(field "$ERRF" event)" "hook_error"
assert_eq "malformed payload: the record names the hook" "$(field "$ERRF" kind)" "event"
RO="$SHEPHERD_ROOT/T-RO.jsonl"; : >"$RO"; chmod 444 "$RO"
SHEPHERD_TASK_ID=T-RO SHEPHERD_STATUS_FILE="$RO" bash "$HOOK" <<<"{$COMMON,\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}" >/dev/null 2>&1
assert_eq "unwritable status file: hook exits 0" "$?" "0"
assert_file "unwritable status file: the .err sidecar exists" "$RO.err"
chmod 644 "$RO"

# --- the wrapper survives a missing library ---------------------------------
# `.` on an unreadable file aborts a POSIX shell outright - dash exits 2. Exit 2
# is not honoured for any of these four events, but the wrapper shape is shared
# with the Stop hook, where an exit 2 BLOCKS the worker's turn - so it is the
# same guarded source here, proved the same way. Run under sh, not bash: dash's
# `.`-abort is the path under test, and bash merely warns and carries on.
NOLIB="$SHEPHERD_ROOT/nolib"; mkdir -p "$NOLIB/lib"
cp "$HOOK" "$NOLIB/worker-event.sh"
NOLIBF="$SHEPHERD_ROOT/T-NOLIB.jsonl"
SHEPHERD_TASK_ID=T-NOLIB SHEPHERD_STATUS_FILE="$NOLIBF" sh "$NOLIB/worker-event.sh" <<<"{$COMMON,\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}" >/dev/null 2>&1
assert_eq "missing run-hook.sh: hook exits 0" "$?" "0"
assert_eq "missing run-hook.sh: a hook_error record is written" "$(field "$NOLIBF" event)" "hook_error"
assert_eq "missing run-hook.sh: the record names the hook" "$(field "$NOLIBF" kind)" "event"
assert_ok "missing run-hook.sh: the record says which file is gone" grep -q 'run-hook\.sh' "$NOLIBF"
# The hand-built record falls back to the sidecar, like every other path here.
NOLIBRO="$SHEPHERD_ROOT/T-NOLIBRO.jsonl"; : >"$NOLIBRO"; chmod 444 "$NOLIBRO"
SHEPHERD_TASK_ID=T-NOLIBRO SHEPHERD_STATUS_FILE="$NOLIBRO" sh "$NOLIB/worker-event.sh" <<<"{$COMMON,\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}" >/dev/null 2>&1
assert_eq "missing run-hook.sh, unwritable status file: hook exits 0" "$?" "0"
assert_file "missing run-hook.sh, unwritable status file: the .err sidecar exists" "$NOLIBRO.err"
chmod 644 "$NOLIBRO"

# --- the shell hook_error is parseable JSON for ANY message -----------------
# hooks/lib/run-hook.sh builds this record with printf, not a JSON library, and
# its reachable caller embeds `head -c 200` of a crashing program's stderr - a
# Python traceback, full of quotes, backslashes and control bytes, and easily
# over 200 characters. It used to escape and THEN truncate, so a cut landing
# between a backslash and the character it escapes left a trailing backslash
# that escaped the closing quote; control bytes other than newline and tab went
# through raw, and a single carriage return was enough. Measured unparseable
# 2026-09-02: 177 A's then backslashes, 199 B's then a quote, any CR.
#
# It matters because BOTH readers - shepherd-watch's status_py and worker_stop.py -
# skip a line they cannot parse. An unparseable hook_error is the record saying
# a hook failed being discarded for the very reason it was written.
LIB="$HERE/../hooks/lib/run-hook.sh"
HE="$SHEPHERD_ROOT/T-HOOKERR.jsonl"
parses() { python3 -c 'import json,sys
[json.loads(l) for l in open(sys.argv[1],encoding="utf-8") if l.strip()]' "$1"; }
adversarial() {  # <name> <message>
  rm -f "$HE"
  ( export SHEPHERD_TASK_ID=T-HOOKERR SHEPHERD_STATUS_FILE="$HE"
    . "$LIB"
    shepherd_hook_error event "$2" ) >/dev/null 2>&1
  assert_ok "hook_error stays parseable JSON: $1" parses "$HE"
}
adversarial "177 A's then twelve backslashes" "$(python3 -c 'import sys; sys.stdout.write("A"*177 + chr(92)*12)')"
adversarial "199 B's then a quote"            "$(python3 -c 'import sys; sys.stdout.write("B"*199 + chr(34))')"
adversarial "a carriage return"               "$(printf 'before\rafter')"
adversarial "a raw control byte"              "$(printf 'before\aafter')"
adversarial "long, with quotes, backslashes and a CR" \
  "$(python3 -c 'import sys; sys.stdout.write(("ValueError: bad \\ path \"C:\\tmp\\x\"\r\n")*20)')"
# …and the record is still USEFUL, not just parseable: the hook is named and
# the message survives.
assert_eq "the adversarial record is a hook_error" "$(field "$HE" event)" "hook_error"
assert_eq "…naming the hook"                       "$(field "$HE" kind)" "event"
assert_ok "…and carrying its message"              test -n "$(field "$HE" message)"
assert_ok "…which still reads as the failure"      grep -q 'ValueError' "$HE"

# The reachable caller, end to end: a hook program that crashes with exactly
# that kind of stderr (run-hook.sh's `exited N: <head -c 200>` branch).
CRASH="$SHEPHERD_ROOT/crash.py"
cat >"$CRASH" <<'PY'
import sys
sys.stderr.write('Traceback (most recent call last):\n')
sys.stderr.write('  File "/x/lib/worker_event.py", line 42, in <module>\r\n' * 6)
sys.stderr.write('ValueError: bad \\ path "C:\\tmp\\x" ' + 'Z' * 120)
raise SystemExit(3)
PY
CR="$SHEPHERD_ROOT/T-CRASH.jsonl"
( export SHEPHERD_TASK_ID=T-CRASH SHEPHERD_STATUS_FILE="$CR"
  . "$LIB"
  shepherd_hook_run event "$CRASH" ) </dev/null >/dev/null 2>&1; rc=$?
assert_eq "a crashing hook program still exits 0" "$rc" "0"
assert_ok "…and its hook_error record parses as JSON" parses "$CR"
assert_eq "…as a hook_error"                       "$(field "$CR" event)" "hook_error"
assert_ok "…naming the exit code"                  grep -q 'exited 3' "$CR"

# --- non-worker sessions are untouched --------------------------------------
OUTSIDE="$SHEPHERD_ROOT/outside.jsonl"
env -u SHEPHERD_TASK_ID SHEPHERD_STATUS_FILE="$OUTSIDE" bash "$HOOK" <<<"{$COMMON,\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}" >/dev/null 2>&1
assert_eq "no task id, hook exits 0" "$?" "0"
assert_nofile "no record without SHEPHERD_TASK_ID" "$OUTSIDE"
before=$(find "$SHEPHERD_ROOT" -type f | wc -l)
env -u SHEPHERD_STATUS_FILE SHEPHERD_TASK_ID=T-TEST bash "$HOOK" <<<"{$COMMON,\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}" >/dev/null 2>&1
assert_eq "no status file, hook exits 0" "$?" "0"
assert_eq "no status file, nothing written" "$(find "$SHEPHERD_ROOT" -type f | wc -l)" "$before"

# --- the two env vars must name the SAME task (T-0223) ----------------------
# test-stop.sh carries the why; this hook shares the wrapper and the library,
# so the refusal has to hold here too, for the python path and the
# hand-built one alike.
MM="$SHEPHERD_ROOT/T-TEST.jsonl"; rm -f "$MM" "$MM.err"
fire "$MM" "{$COMMON,\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}"
SHEPHERD_TASK_ID=T-OTHER SHEPHERD_STATUS_FILE="$MM" bash "$HOOK" <<<"{$COMMON,\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}" >/dev/null 2>&1
assert_eq "mismatched pair: hook exits 0" "$?" "0"
assert_eq "mismatched pair: nothing lands in the other task's file" "$(grep -c '' "$MM")" "1"
assert_eq "mismatched pair: one sidecar line" "$(grep -c '' "$MM.err")" "1"
assert_ok "mismatched pair: the line names the stray task id and the hook" grep -q 'T-OTHER.* event \|event .*T-OTHER' "$MM.err"
NOLIBMM="$SHEPHERD_ROOT/nolib-mm.jsonl"; : >"$NOLIBMM"
SHEPHERD_TASK_ID=T-OTHER SHEPHERD_STATUS_FILE="$NOLIBMM" sh "$NOLIB/worker-event.sh" <<<"{$COMMON,\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}" >/dev/null 2>&1
assert_eq "missing run-hook.sh, mismatched pair: hook exits 0" "$?" "0"
assert_eq "missing run-hook.sh, mismatched pair: the file stays empty" "$(grep -c '' "$NOLIBMM")" "0"
assert_ok "missing run-hook.sh, mismatched pair: the sidecar names the stray task id" grep -q 'T-OTHER' "$NOLIBMM.err"

finish
