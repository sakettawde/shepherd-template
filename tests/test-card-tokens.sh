#!/usr/bin/env bash
# shepherd-card-tokens over a fabricated status file and transcript, so every number
# below is known by construction.
#
# The case that matters is the dedupe: a real transcript writes one line per
# content block of the same assistant message, each repeating that message's
# usage verbatim (T-0245: 134 entries, 49 messages, a 2.6x overcount if summed).
# The fixture reproduces that shape — one message written three times — so a
# regression that drops the dedupe shows up as a tripled figure, not as a crash.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
S="$HERE/../bin/shepherd-card-tokens"
TX="$SHEPHERD_ROOT/transcripts"
mkdir -p "$SHEPHERD_ROOT/ledger/status" "$TX"

echo "test-card-tokens:"

# --- the fixture -----------------------------------------------------------
# Two messages, each written three times (the content-block repeat), plus a
# `<synthetic>` harness notice and a non-assistant line that must be ignored.
# Truth in the parent alone: 2 turns, input 1000+2000+3000 + 10+20+30 = 6060,
# output 500+5 = 505; the subagent file below adds one turn, 600 and 50.
w() { printf '%s\n' "$1" >> "$TX/a.jsonl"; }
for _ in 1 2 3; do
  w '{"type":"assistant","uuid":"u1","requestId":"r1","message":{"id":"m1","model":"test-model","usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":3000,"output_tokens":500}}}'
done
for _ in 1 2 3; do
  w '{"type":"assistant","uuid":"u2","requestId":"r2","message":{"id":"m2","model":"test-model","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":5}}}'
done
w '{"type":"assistant","uuid":"u3","message":{"id":"m3","model":"<synthetic>","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}'
w '{"type":"user","uuid":"u4","message":{"role":"user","content":"hi"}}'
w 'not json at all'
# A subagent's turns are NOT in the parent transcript: Claude Code writes each
# to its own file at <transcript without .jsonl>/subagents/. Reading only the
# path the Stop hook records bills a delegating card at its orchestrator's cost
# alone — 13.3M instead of 14.1M on T-0245. One message, written twice, so the
# dedupe is proven on this path too. Truth: 1 more turn, +600 input, +50 output.
mkdir -p "$TX/a/subagents"
for _ in 1 2; do
  printf '%s\n' '{"type":"assistant","uuid":"s1","isSidechain":true,"message":{"id":"sm1","model":"test-model","usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":50}}}' \
    >> "$TX/a/subagents/agent-x.jsonl"
done
printf '{"ts":"2026-09-08T01:00:00+0000","event":"stop","task":"T-0001","transcript_path":"%s"}\n' "$TX/a.jsonl" \
  > "$SHEPHERD_ROOT/ledger/status/T-0001.jsonl"
# The same transcript named again on a rotated file: distinct paths only, so it
# must not be counted twice.
printf '{"ts":"2026-09-08T02:00:00+0000","event":"stop","task":"T-0001","transcript_path":"%s"}\n' "$TX/a.jsonl" \
  > "$SHEPHERD_ROOT/ledger/status/T-0001.block1.jsonl"

j=$("$S" --json T-0001)
get() { printf '%s' "$j" | python3 -c "import json,sys; print(json.load(sys.stdin)['cards'][0]['$1'])"; }

assert_eq "one message counts once however many lines repeat it" "$(get turns)" "3"
assert_eq "input sums fresh, cache write and cache read" "$(get input)" "6660"
assert_eq "output is the deduped output total"           "$(get output)" "555"
assert_eq "fresh input is reported on its own"           "$(get input_fresh)" "1110"
assert_eq "cache writes are reported on their own"       "$(get input_cache_write)" "2220"
assert_eq "cache reads are reported on their own"        "$(get input_cache_read)" "3330"
assert_eq "a <synthetic> harness notice is not a turn"   "$(get model)" "test-model"
assert_eq "both of the card's status files are read"     "$(get status_files)" "2"
assert_eq "a transcript named twice is read once"        "$(get transcripts)" "1"
assert_eq "a subagent file beside it is found"           "$(get subagent_files)" "1"
assert_eq "…and its turns counted, deduped like any other" "$(get subagent_turns)" "1"
assert_ok "the table names the subagent share" \
  bash -c "'$S' T-0001 | grep -qF 'turns 3 (1 in subagents) across 1 transcript(s) and 1 subagent file(s)'"
assert_eq "an unreadable line is counted, not skipped silently" \
  "$(printf '%s' "$j" | python3 -c "import json,sys; print(json.load(sys.stdin)['cards'][0]['missing']['unparsable_transcript_lines'])")" "1"

# The fragment retro pastes onto the metrics line.
assert_eq "the fragment is the metrics-line field, compacted" \
  "$(get fragment)" "tokens 6.7k/555 test-model"
assert_ok "and the table prints it behind an arrow" \
  bash -c "'$S' T-0001 | grep -qF '→ tokens 6.7k/555 test-model'"

# --- nothing is guessed ----------------------------------------------------
assert_ok "a card with no status file exits 1" \
  bash -c "! '$S' T-0777 >/dev/null 2>&1"
assert_ok "and says so rather than reporting a number" \
  bash -c "'$S' T-0777 2>/dev/null | grep -q 'no status file'"
assert_ok "and its fragment is tokens none" \
  bash -c "'$S' T-0777 2>/dev/null | grep -qF 'tokens none'"

printf '{"ts":"2026-09-08T01:00:00+0000","event":"stop","task":"T-0002","transcript_path":"%s"}\n' "$TX/gone.jsonl" \
  > "$SHEPHERD_ROOT/ledger/status/T-0002.jsonl"
assert_ok "a transcript that is no longer on disk is named, not counted" \
  bash -c "'$S' T-0002 2>/dev/null | grep -q 'none still on disk'"

printf '{"ts":"2026-09-08T01:00:00+0000","event":"session_end","task":"T-0003"}\n' \
  > "$SHEPHERD_ROOT/ledger/status/T-0003.jsonl"
assert_ok "a card whose records name no transcript says that" \
  bash -c "'$S' T-0003 2>/dev/null | grep -q 'no stop record names a transcript'"

# A card that produced a figure and one that did not: exit 1, both reported.
out=$("$S" T-0001 T-0777 2>/dev/null); rc=$?
assert_eq "a mixed run exits 1" "$rc" "1"
assert_ok "and still reports the card that has a figure" grep -qF "tokens 6.7k/555" <<<"$out"

# --- arguments -------------------------------------------------------------
assert_ok "a malformed task id is refused" bash -c "! '$S' T-abc >/dev/null 2>&1"
assert_ok "no task id at all is refused"   bash -c "! '$S' --json >/dev/null 2>&1"
assert_ok "--help exits 0"                 bash -c "'$S' --help >/dev/null"
assert_ok "the script writes nothing into the ledger" \
  bash -c "'$S' T-0001 >/dev/null 2>&1; [ ! -e '$SHEPHERD_ROOT/ledger/tasks/T-0001.md' ]"

finish
