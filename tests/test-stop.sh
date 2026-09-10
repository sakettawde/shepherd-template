#!/usr/bin/env bash
# Probe for hooks/worker-stop.sh — the Stop hook that turns a worker's final
# message into the ground-truth `claim` record shepherd's status-file watcher
# reads (the manual §2 rule 1).
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
HOOK="${STOP_HOOK:-$HERE/../hooks/worker-stop.sh}"

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

# fire <status-file> <payload-json> — run the hook the way Claude Code does.
# The task id is the file's own basename: the hook refuses a pair that
# disagrees (T-0223), so every fixture here agrees by construction.
fire() {
  local f="$1" json="$2"
  local id=${f##*/}; id=${id%.jsonl}
  SHEPHERD_TASK_ID=$id SHEPHERD_STATUS_FILE="$f" bash "$HOOK" <<<"$json" >/dev/null 2>&1
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

# --- the decorated forms seen live (T-0214): quoted, bulleted, numbered, and
# --- emphasis on the claim word or around the label alone ------------------
assert_eq "blockquoted sentinel"            "$(claim_of '> SHEPHERD: blocked — need a ruling')" "blocked"
assert_eq "nested blockquote sentinel"      "$(claim_of '> > SHEPHERD: done — x')" "done"
assert_eq "dash-bulleted sentinel"          "$(claim_of '- SHEPHERD: done — merged')" "done"
assert_eq "star-bulleted sentinel"          "$(claim_of '* SHEPHERD: failed — x')" "failed"
assert_eq "numbered sentinel"               "$(claim_of '1. SHEPHERD: working — x')" "working"
assert_eq "bold claim word"                 "$(claim_of 'SHEPHERD: **done** — x')" "done"
assert_eq "bold label, bare word"           "$(claim_of '**SHEPHERD:** done — x')" "done"
assert_eq "bulleted bold sentinel"          "$(claim_of '- **SHEPHERD: blocked** — x')" "blocked"
assert_eq "a sentinel record says it came from the message" \
  "$(rm -f "$SHEPHERD_ROOT/one.jsonl"; fire "$SHEPHERD_ROOT/one.jsonl" "$(payload 'SHEPHERD: done — x')"; field "$SHEPHERD_ROOT/one.jsonl" claim_source)" "sentinel"
assert_eq "no sentinel: claim_source is none" \
  "$(rm -f "$SHEPHERD_ROOT/one.jsonl"; fire "$SHEPHERD_ROOT/one.jsonl" "$(payload 'nothing here')"; field "$SHEPHERD_ROOT/one.jsonl" claim_source)" "none"

# --- a PRINTED status command is a claim with weaker provenance (T-0249) ----
# A worker that finishes correctly and ends its message with the command
# WRITTEN OUT instead of run left `claim: none`, so the watcher had nothing to
# fire on and the done work waited two 1800 s heartbeats (T-0244, stop
# 2026-09-07T19:45:02, PR #118 already open). The shape is the command's own:
# the four claim words and a quoted one-liner filling a line of its own,
# decorated exactly as far as the sentinel may be. `claim_source` says
# `printed` so monitor reads off the ledger that the command never ran.
assert_eq "printed command line records the claim" \
  "$(claim_of 'Tests green, PR open.

shepherd-status done "T-0244: intro now says four walkthroughs; PR #118 open into dev"')" "done"
assert_eq "printed command line: claim_source says printed" \
  "$(rm -f "$SHEPHERD_ROOT/one.jsonl"; fire "$SHEPHERD_ROOT/one.jsonl" "$(payload 'Done.

shepherd-status done "shipped"')"; field "$SHEPHERD_ROOT/one.jsonl" claim_source)" "printed"
for c in done blocked failed working; do
  assert_eq "printed command records claim $c" "$(claim_of "shepherd-status $c \"x\"")" "$c"
done
assert_eq "backticked printed command"   "$(claim_of '`shepherd-status done "x"`')" "done"
assert_eq "bold backticked printed command" "$(claim_of '**`shepherd-status blocked "need a ruling"`**')" "blocked"
assert_eq "bulleted printed command"     "$(claim_of '- shepherd-status failed "DoD never passed"')" "failed"
assert_eq "blockquoted printed command"  "$(claim_of '> shepherd-status working "halfway"')" "working"
assert_eq "indented printed command"     "$(claim_of '    shepherd-status done "in a code block"')" "done"
assert_eq "single-quoted printed command" "$(claim_of "shepherd-status done 'shipped'")" "done"
assert_eq "typographic-quoted printed command" \
  "$(claim_of 'shepherd-status done “merged”')" "done"
assert_eq "emphasised claim word in a printed command" \
  "$(claim_of 'shepherd-status **done** "merged"')" "done"
# The LAST printed line wins, as the last sentinel does.
assert_eq "last printed command wins" \
  "$(claim_of 'shepherd-status working "still going"

shepherd-status done "merged"')" "done"

# --- ...and the command NAMED IN A SENTENCE is still nothing (T-0249) -------
# The pair is the point: the detector must be a shape, not the literal
# `shepherd-status`. A brief, a plan and this repo'"'"'s own docs all say the word.
assert_eq "the command promised mid-sentence records none" \
  "$(claim_of 'I will run shepherd-status done once the suite is green.')" "none"
assert_eq "the command quoted mid-sentence records none" \
  "$(claim_of 'Report with `shepherd-status done "<one short line>"` when you finish.')" "none"
assert_eq "the command with no quoted one-liner records none" \
  "$(claim_of 'shepherd-status done')" "none"
assert_eq "the command with an unrecognised word records none" \
  "$(claim_of 'shepherd-status merged "x"')" "none"
assert_eq "the template usage line records none" \
  "$(claim_of 'shepherd-status done|blocked|failed|working "<one short line>"')" "none"
assert_eq "a printed line with prose after it records none" \
  "$(claim_of 'shepherd-status done "x" is what I would have run.')" "none"
# The line must START the shape too, not only end it: "Now I run …" is the
# sentence a worker writes about the command it is ABOUT to run.
assert_eq "the command with prose before it records none" \
  "$(claim_of 'Now I run shepherd-status done "merged"')" "none"
assert_eq "the command after a lead-in phrase records none" \
  "$(claim_of 'Final step: shepherd-status blocked "need a ruling"')" "none"
# The template'"'"'s own placeholder is the text a worker paraphrasing its Brief
# copies, and it wears every other part of this shape.
assert_eq "the template placeholder one-liner records none" \
  "$(claim_of 'The Brief tells me to end with:

shepherd-status done "<one short line>"')" "none"
assert_eq "a bulleted placeholder records none" \
  "$(claim_of '- `shepherd-status blocked "<question>"`')" "none"
# A numbered line is a plan STEP here, not a bullet: `1. SHEPHERD: done` is a
# decorated claim, `3. shepherd-status done "…"` is step three of a plan.
assert_eq "a numbered plan step records none" \
  "$(claim_of '3. shepherd-status done "T-0249: printed claim recognised"')" "none"

# --- printed is the LAST resort: sentinel, then a RUN command, then printed --
# Order is the safety of the whole path. A printed claim is inferred from a
# shape a quoted example or a plan step can wear, so letting it outrank a claim
# the worker actually ran would report a `blocked` worker `done` — ground truth
# ① corrupted to save a heartbeat, which is a worse trade than the one this
# path exists to make.
assert_eq "a sentinel in the same message wins over a printed command" \
  "$(claim_of 'shepherd-status working "halfway"

SHEPHERD: blocked — need a ruling')" "blocked"
PRT="$SHEPHERD_ROOT/printed-cmd.jsonl"; rm -f "$PRT"
printf '{"ts": "t", "event": "claim", "task": "T-TEST", "kind": "command", "claim": "blocked", "message": "x"}\n' >>"$PRT"
fire "$PRT" "$(payload 'I need a ruling. The Brief says to end with:

shepherd-status done "merged"')"
assert_eq "a RUN command claim outranks a printed line" "$(field "$PRT" claim)" "blocked"
assert_eq "a run command claim keeps claim_source command" "$(field "$PRT" claim_source)" "command"
# …and a worker that runs the command AND echoes it still dedupes: the stop
# record repeats the command's claim, which the watcher does not re-fire on.
rm -f "$PRT"
printf '{"ts": "t", "event": "claim", "task": "T-TEST", "kind": "command", "claim": "done", "message": "x"}\n' >>"$PRT"
fire "$PRT" "$(payload 'All green. Reported with:

shepherd-status done "merged"')"
assert_eq "a worker that runs and echoes is still one claim" "$(field "$PRT" claim_source)" "command"
# The printed path reaches only what would otherwise have been `none`.
rm -f "$PRT"
fire "$PRT" "$(payload 'shepherd-status done "merged"')"
assert_eq "with no command claim, the printed line is the record" "$(field "$PRT" claim)" "done"
assert_eq "with no command claim, claim_source is printed" "$(field "$PRT" claim_source)" "printed"

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

# --- transcript fallback: a payload with no message reads the transcript ----
# The docs say last_assistant_message is the primary and the transcript may
# lag (hooks reference, read 2026-09-02); the transcript is only for a payload
# that carries no message at all.
# The tool_use row is LAST on purpose. worker_stop.py narrows to the last
# assistant entry with non-empty text (`if text.strip()`), and with a text row
# at the end "last assistant entry" and "last assistant entry that has text"
# return the same value — the assertion below then passes whether the
# narrowing is there or not. A trailing tool_use row is also the shape a real
# transcript ends in most often: the turn's last event is a tool call, and the
# text that carried the claim is the entry before it.
TRANSCRIPT="$SHEPHERD_ROOT/transcript.jsonl"
python3 - "$TRANSCRIPT" <<'PY'
import json, sys
rows = [
  {"type": "user", "message": {"role": "user", "content": "go"}},
  {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "First.\n\nSHEPHERD: working — early"}]}},
  {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Done.\n\n`SHEPHERD: blocked — approve the plan`"}]}},
  {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "x", "name": "Bash", "input": {}}]}},
]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for r in rows: fh.write(json.dumps(r) + "\n")
PY
# nomsg_payload <transcript-path> — a Stop payload carrying no message text
nomsg_payload() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps({
    "session_id":"test","hook_event_name":"Stop","stop_reason":"end_turn",
    "permission_mode":"auto","transcript_path":sys.argv[1]}))' "$1"
}
TF="$SHEPHERD_ROOT/tf.jsonl"; rm -f "$TF"
fire "$TF" "$(nomsg_payload "$TRANSCRIPT")"
assert_eq "no message: claim read from the transcript's last assistant text" "$(field "$TF" claim)" "blocked"
assert_eq "no message: claim_source says transcript" "$(field "$TF" claim_source)" "transcript"
rm -f "$TF"
fire "$TF" "$(nomsg_payload "$SHEPHERD_ROOT/does-not-exist.jsonl")"
assert_eq "no message, no transcript: still a record, claim none" "$(field "$TF" claim)" "none"
# The message wins over the transcript whenever it is present.
rm -f "$TF"
fire "$TF" "$(python3 -c 'import json,sys; sys.stdout.write(json.dumps({"session_id":"test","hook_event_name":"Stop","transcript_path":sys.argv[1],"last_assistant_message":"SHEPHERD: done — from the message"}))' "$TRANSCRIPT")"
assert_eq "message present: the transcript is not consulted" "$(field "$TF" claim)" "done"

# --- one claim per turn: a command claim this turn is inherited, not doubled -
# scripts/bin/shepherd-status writes an `event: claim` line; a worker told
# "command first, sentinel fallback" often does both. The stop record carries
# the turn's effective claim either way, and claim_source says whether it is
# NEW information (sentinel) or a repeat of the command's (command) - the
# watcher counts only the former (spec §1, §3).
CMD="$SHEPHERD_ROOT/cmd.jsonl"; rm -f "$CMD"
printf '{"ts": "t", "event": "claim", "task": "T-TEST", "kind": "command", "claim": "blocked", "message": "x"}\n' >>"$CMD"
fire "$CMD" "$(payload 'Paused, see the card.')"
assert_eq "no sentinel after a command claim: the claim is inherited" "$(field "$CMD" claim)" "blocked"
assert_eq "no sentinel after a command claim: claim_source is command" "$(field "$CMD" claim_source)" "command"
# The inheritance only reaches back to the previous stop record.
fire "$CMD" "$(payload 'Next turn, nothing claimed.')"
assert_eq "a command claim from an earlier turn is not inherited" "$(field "$CMD" claim)" "none"
# A sentinel that disagrees with the command is new information.
printf '{"ts": "t", "event": "claim", "task": "T-TEST", "kind": "command", "claim": "working", "message": "x"}\n' >>"$CMD"
fire "$CMD" "$(payload 'Changed my mind.

SHEPHERD: blocked — need a ruling')"
assert_eq "a sentinel after a command claim wins" "$(field "$CMD" claim)" "blocked"
assert_eq "a sentinel after a command claim is recorded as sentinel" "$(field "$CMD" claim_source)" "sentinel"

# --- a hook that cannot record says so --------------------------------------
ERRF="$SHEPHERD_ROOT/T-ERR.jsonl"
SHEPHERD_TASK_ID=T-ERR SHEPHERD_STATUS_FILE="$ERRF" bash "$HOOK" <<<'{not json' >/dev/null 2>&1
assert_eq "malformed payload: hook exits 0" "$?" "0"
assert_eq "malformed payload: a hook_error record is written" "$(field "$ERRF" event)" "hook_error"
assert_eq "malformed payload: the record names the hook" "$(field "$ERRF" kind)" "stop"
RO="$SHEPHERD_ROOT/T-RO.jsonl"; : >"$RO"; chmod 444 "$RO"
SHEPHERD_TASK_ID=T-RO SHEPHERD_STATUS_FILE="$RO" bash "$HOOK" <<<"$(payload 'SHEPHERD: done — x')" >/dev/null 2>&1
assert_eq "unwritable status file: hook exits 0" "$?" "0"
assert_file "unwritable status file: the .err sidecar exists" "$RO.err"
chmod 644 "$RO"

# --- the wrapper survives a missing library ---------------------------------
# `.` on an unreadable file aborts a POSIX shell outright - dash exits 2, and
# exit 2 from a STOP hook BLOCKS the worker's turn, the one thing no hook here
# may do. So the wrapper records the failure without the library and still
# exits 0. Run under sh, not bash: dash's `.`-abort is the path under test, and
# bash merely warns and carries on.
NOLIB="$SHEPHERD_ROOT/nolib"; mkdir -p "$NOLIB/lib"
cp "$HOOK" "$NOLIB/worker-stop.sh"
NOLIBF="$SHEPHERD_ROOT/T-NOLIB.jsonl"
SHEPHERD_TASK_ID=T-NOLIB SHEPHERD_STATUS_FILE="$NOLIBF" sh "$NOLIB/worker-stop.sh" <<<"$(payload 'SHEPHERD: done — x')" >/dev/null 2>&1
assert_eq "missing run-hook.sh: hook exits 0" "$?" "0"
assert_eq "missing run-hook.sh: a hook_error record is written" "$(field "$NOLIBF" event)" "hook_error"
assert_eq "missing run-hook.sh: the record names the hook" "$(field "$NOLIBF" kind)" "stop"
assert_ok "missing run-hook.sh: the record says which file is gone" grep -q 'run-hook\.sh' "$NOLIBF"
# The hand-built record falls back to the sidecar, like every other path here.
NOLIBRO="$SHEPHERD_ROOT/T-NOLIBRO.jsonl"; : >"$NOLIBRO"; chmod 444 "$NOLIBRO"
SHEPHERD_TASK_ID=T-NOLIBRO SHEPHERD_STATUS_FILE="$NOLIBRO" sh "$NOLIB/worker-stop.sh" <<<"$(payload 'SHEPHERD: done — x')" >/dev/null 2>&1
assert_eq "missing run-hook.sh, unwritable status file: hook exits 0" "$?" "0"
assert_file "missing run-hook.sh, unwritable status file: the .err sidecar exists" "$NOLIBRO.err"
chmod 644 "$NOLIBRO"

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
env -u SHEPHERD_TASK_ID SHEPHERD_STATUS_FILE="$OUTSIDE" bash "$HOOK" <<<"$(payload 'SHEPHERD: done — x')" >/dev/null 2>&1
assert_eq "no task id, hook exits 0" "$?" "0"
assert_nofile "no record without SHEPHERD_TASK_ID" "$OUTSIDE"

before=$(find "$SHEPHERD_ROOT" -type f | wc -l)
env -u SHEPHERD_STATUS_FILE SHEPHERD_TASK_ID=T-TEST bash "$HOOK" <<<"$(payload 'SHEPHERD: done — x')" >/dev/null 2>&1
assert_eq "no status file, hook exits 0" "$?" "0"
assert_eq "no status file, nothing written" "$(find "$SHEPHERD_ROOT" -type f | wc -l)" "$before"

# --- the two env vars must name the SAME task (T-0223) ----------------------
# Non-empty was the whole gate. A worker relaunched with a stale id in one of
# the pair — or a probe that overrode one and inherited the other, measured
# 2026-09-02 — wrote its turn into ANOTHER task's ground truth (the manual §2
# rule 1) and nothing said so. The file's basename is the task's own, so the
# hook now refuses to write when they disagree, and says so where a failed
# write says so: the sidecar beside the file it was about to corrupt.
MM="$SHEPHERD_ROOT/T-TEST.jsonl"; rm -f "$MM" "$MM.err"
fire "$MM" "$(payload 'SHEPHERD: working — x')"
SHEPHERD_TASK_ID=T-OTHER SHEPHERD_STATUS_FILE="$MM" bash "$HOOK" <<<"$(payload 'SHEPHERD: done — x')" >/dev/null 2>&1
assert_eq "mismatched pair: hook exits 0" "$?" "0"
assert_eq "mismatched pair: nothing lands in the other task's file" "$(grep -c '' "$MM")" "1"
assert_file "mismatched pair: the sidecar exists" "$MM.err"
assert_eq "mismatched pair: one sidecar line" "$(grep -c '' "$MM.err")" "1"
assert_ok "mismatched pair: the line names the stray task id" grep -q 'T-OTHER' "$MM.err"
assert_ok "mismatched pair: …and the file it is not the task of" grep -qF "$MM" "$MM.err"
assert_ok "mismatched pair: …and the hook" grep -q ' stop ' "$MM.err"
# The wrapper's own hand-built record (run-hook.sh missing) makes the same
# refusal: a mismatch writes into the status file from no path at all.
NOLIBMM="$SHEPHERD_ROOT/nolib-mm.jsonl"; : >"$NOLIBMM"
SHEPHERD_TASK_ID=T-OTHER SHEPHERD_STATUS_FILE="$NOLIBMM" sh "$NOLIB/worker-stop.sh" <<<"$(payload 'SHEPHERD: done — x')" >/dev/null 2>&1
assert_eq "missing run-hook.sh, mismatched pair: hook exits 0" "$?" "0"
assert_eq "missing run-hook.sh, mismatched pair: the file stays empty" "$(grep -c '' "$NOLIBMM")" "0"
assert_ok "missing run-hook.sh, mismatched pair: the sidecar names the stray task id" grep -q 'T-OTHER' "$NOLIBMM.err"

# One failure is one line. Both halves of the pair come from a launch line, so
# a newline in either would split one report across several lines and break
# the shape monitor reads - the discipline shepherd_hook_error already keeps
# for its message.
NLMM="$SHEPHERD_ROOT/T-NL.jsonl"; : >"$NLMM"; rm -f "$NLMM.err"
SHEPHERD_TASK_ID="$(printf 'T-OTHER\nclaim done')" SHEPHERD_STATUS_FILE="$NLMM" bash "$HOOK" <<<"$(payload 'SHEPHERD: done — x')" >/dev/null 2>&1
assert_eq "a task id carrying a newline: hook exits 0" "$?" "0"
assert_eq "a task id carrying a newline: the file stays empty" "$(grep -c '' "$NLMM")" "0"
assert_eq "a task id carrying a newline: still one sidecar line" "$(grep -c '' "$NLMM.err")" "1"

# The sidecar unwritable too: the report reaches stderr rather than vanishing.
ROMM="$SHEPHERD_ROOT/T-ROMM.jsonl"; : >"$ROMM"; : >"$ROMM.err"; chmod 444 "$ROMM.err"
out=$(SHEPHERD_TASK_ID=T-OTHER SHEPHERD_STATUS_FILE="$ROMM" bash "$HOOK" <<<"$(payload 'SHEPHERD: done — x')" 2>&1 >/dev/null)
assert_eq "mismatched pair, unwritable sidecar: hook exits 0" "$?" "0"
assert_eq "mismatched pair, unwritable sidecar: the file stays empty" "$(grep -c '' "$ROMM")" "0"
assert_ok "mismatched pair, unwritable sidecar: stderr carries the report" grep -q 'T-OTHER' <<<"$out"
chmod 644 "$ROMM.err"

finish
