#!/usr/bin/env bash
# Probe for scripts/bin/shepherd-status — the worker's status command: it
# appends the claim line itself, so the watcher fires on it without any prose
# for a regex to miss (spec §5). The prose sentinel stays as the fallback and
# the command says so whenever it cannot record.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
unset SHEPHERD_TASK_ID SHEPHERD_STATUS_FILE
S="$HERE/../bin/shepherd-status"
W="$HERE/../bin/shepherd-watch"

echo "test-status:"

field() {
  python3 -c 'import json,sys
line=[l for l in open(sys.argv[1],encoding="utf-8") if l.strip()][-1]
sys.stdout.write(str(json.loads(line).get(sys.argv[2],"")))' "$1" "$2"
}

F="$SHEPHERD_ROOT/T-TEST.jsonl"
assert_ok "the command is executable" test -x "$S"

out=$(SHEPHERD_TASK_ID=T-TEST SHEPHERD_STATUS_FILE="$F" CLAUDE_CODE_SESSION_ID=sess-w "$S" blocked "need a ruling on X"); rc=$?
assert_eq "records: exit 0" "$rc" "0"
assert_eq "records: says so" "$out" "recorded blocked for T-TEST"
assert_eq "records: event claim" "$(field "$F" event)" "claim"
assert_eq "records: kind command" "$(field "$F" kind)" "command"
assert_eq "records: the claim" "$(field "$F" claim)" "blocked"
assert_eq "records: the message" "$(field "$F" message)" "need a ruling on X"
assert_eq "records: the task" "$(field "$F" task)" "T-TEST"
assert_eq "records: the session" "$(field "$F" session_id)" "sess-w"
assert_ok "records: greppable like a stop claim" grep -q '"claim": "blocked"' "$F"

SHEPHERD_TASK_ID=T-TEST SHEPHERD_STATUS_FILE="$F" "$S" done unquoted words are joined >/dev/null
assert_eq "an unquoted one-liner is joined" "$(field "$F" message)" "unquoted words are joined"
for c in done blocked failed working; do
  SHEPHERD_TASK_ID=T-TEST SHEPHERD_STATUS_FILE="$F" "$S" "$c" x >/dev/null
  assert_eq "accepts $c" "$(field "$F" claim)" "$c"
done
assert_eq "one line per call" "$(grep -c '"event": "claim"' "$F")" "6"

# usage
SHEPHERD_TASK_ID=T-TEST SHEPHERD_STATUS_FILE="$F" "$S" finished "x" >/dev/null 2>&1
assert_eq "a bad claim word is a usage error (2)" "$?" "2"
SHEPHERD_TASK_ID=T-TEST SHEPHERD_STATUS_FILE="$F" "$S" done >/dev/null 2>&1
assert_eq "a missing one-liner is a usage error (2)" "$?" "2"
"$S" >/dev/null 2>&1
assert_eq "no arguments is a usage error (2)" "$?" "2"

# cannot record → exit 1, and the fallback is named.
# Each case also pins the REASON, not just the exit code: all three fallback
# messages name the sentinel, so `grep SHEPHERD:` alone passes for any of them
# and would keep passing if the env check answered the unwritable-file case or
# the other way round. That exact trap already bit once inside Task 6.
out=$(env -u SHEPHERD_TASK_ID -u SHEPHERD_STATUS_FILE "$S" done "x" 2>&1 >/dev/null); rc=$?
assert_eq "outside a worker session: exit 1" "$rc" "1"
assert_ok "outside a worker session: names the sentinel fallback" grep -q 'SHEPHERD:' <<<"$out"
assert_ok "outside a worker session: and says the env is missing" grep -q 'are not set' <<<"$out"
RO="$SHEPHERD_ROOT/T-RO.jsonl"; : >"$RO"; chmod 444 "$RO"
out=$(SHEPHERD_TASK_ID=T-RO SHEPHERD_STATUS_FILE="$RO" "$S" done "x" 2>&1 >/dev/null); rc=$?
assert_eq "unwritable file: exit 1" "$rc" "1"
assert_ok "unwritable file: names the sentinel fallback" grep -q 'SHEPHERD:' <<<"$out"
assert_ok "unwritable file: and says it could not write" grep -q 'cannot write' <<<"$out"
chmod 644 "$RO"

# The two variables must describe the same task. A PARTIAL override - task id
# set, status file inherited from the surrounding session - is what put a
# `task: T-TEST` claim into a live T-0214.jsonl on 2026-09-02.
MM="$SHEPHERD_ROOT/T-0999.jsonl"; rm -f "$MM"
out=$(SHEPHERD_TASK_ID=T-TEST SHEPHERD_STATUS_FILE="$MM" "$S" done "x" 2>&1 >/dev/null); rc=$?
assert_eq "another task's status file: exit 1" "$rc" "1"
assert_nofile "another task's status file: nothing is written" "$MM"
assert_ok "another task's status file: names the task" grep -q 'T-TEST' <<<"$out"
assert_ok "another task's status file: names the file" grep -q 'T-0999.jsonl' <<<"$out"
assert_ok "another task's status file: names the sentinel fallback" grep -q 'SHEPHERD:' <<<"$out"
# …and the matching pair still writes, so the check cannot be passing by refusing everything.
MOK="$SHEPHERD_ROOT/T-0999x.jsonl"; rm -f "$MOK"
SHEPHERD_TASK_ID=T-0999x SHEPHERD_STATUS_FILE="$MOK" "$S" done "x" >/dev/null
assert_eq "the matching pair writes" "$(field "$MOK" claim)" "done"

# no hard-coded root: the script names no /home path
assert_ok "the command carries no instance path" bash -c "! grep -q '/home/' '$S'"


# --- shepherd-reply (T-0240): the reply worker's one delivery ----------------
# `shepherd-reply <file>|-` replaces the card's `## Reply` section and appends
# an `event: reply` record to the status file; it commits nothing (shepherd
# commits the card at verification). Same env pair and basename guard as
# shepherd-status; the card path is derived from the status file's directory.
# It refuses a reply missing one of the four labels, in order, and warns past
# 150 words (spec §2 Persona and the reply format, amended 2026-09-08: the
# whole reply drops from 250 to 150 words, the Answer from 120 to 80).
RP="$HERE/../bin/shepherd-reply"
assert_ok "shepherd-reply is executable" test -x "$RP"
assert_ok "shepherd-reply carries no instance path" bash -c "! grep -q '/home/' '$RP'"

mkdir -p "$SHEPHERD_ROOT/ledger/status" "$SHEPHERD_ROOT/ledger/tasks"
git -C "$SHEPHERD_ROOT" init -q -b main 2>/dev/null
git -C "$SHEPHERD_ROOT" config user.email t@t; git -C "$SHEPHERD_ROOT" config user.name T
RC="$SHEPHERD_ROOT/ledger/tasks/T-0300.md"; RF="$SHEPHERD_ROOT/ledger/status/T-0300.jsonl"
rcard() {  # a reply card with the template's empty ## Reply section last
  printf '# T-0300: where is the retry?\nstate: working\nowner: shepherd-test\nproject: p\nkind: reply\nsize: S   tier: standard   budget: 20m\npane: w1:p1   session: s\n\n## Brief\n\n### Question\nwhere is the retry?\n\n## Log\n- 09:00 captured (fixture)\n\n## Reply\n<written by shepherd-reply>\n' >"$RC"
}
rcard
git -C "$SHEPHERD_ROOT" add ledger/tasks/T-0300.md; git -C "$SHEPHERD_ROOT" commit -qm card
before=$(git -C "$SHEPHERD_ROOT" rev-list --count HEAD)
good="$SHEPHERD_ROOT/reply.md"
printf '**Answer** — the retry lives in the queue consumer.\n\n**What I checked** — src/queue.ts at HEAD, PR 12.\n\n**Confidence** — high; a second consumer would change it.\n\n**Next step** — I can card the fix.\n' >"$good"
rrun() { SHEPHERD_TASK_ID=T-0300 SHEPHERD_STATUS_FILE="$RF" CLAUDE_CODE_SESSION_ID=sess-r "$RP" "$@"; }
out=$(rrun "$good"); rc=$?
assert_eq "reply from a file: exit 0" "$rc" "0"
assert_eq "reply: says so, with the word count" "$out" "recorded reply for T-0300 (31 words)"
assert_eq "reply: the section carries the file's text" "$(sed -n '/^## Reply/,$p' "$RC" | grep -c '^\*\*Answer\*\* — the retry lives in the queue consumer.$')" "1"
assert_eq "reply: the placeholder is gone" "$(grep -c 'written by shepherd-reply' "$RC")" "0"
assert_eq "reply: one ## Reply section" "$(grep -c '^## Reply$' "$RC")" "1"
assert_eq "reply: the Log is untouched" "$(grep -c '^- 09:00 captured (fixture)$' "$RC")" "1"
assert_eq "reply: the Brief is untouched" "$(grep -c '^where is the retry?$' "$RC")" "1"
assert_eq "reply: the header is untouched" "$(grep -c '^kind: reply$' "$RC")" "1"
assert_eq "reply: event reply" "$(field "$RF" event)" "reply"
assert_eq "reply: kind command" "$(field "$RF" kind)" "command"
assert_eq "reply: the task" "$(field "$RF" task)" "T-0300"
assert_eq "reply: the word count" "$(field "$RF" words)" "31"
assert_eq "reply: the session" "$(field "$RF" session_id)" "sess-r"
assert_eq "reply: commits nothing" "$(git -C "$SHEPHERD_ROOT" rev-list --count HEAD)" "$before"
assert_eq "reply: the card is left modified for shepherd to commit" "$(git -C "$SHEPHERD_ROOT" status --porcelain -- ledger/tasks/T-0300.md | cut -c1-2)" " M"

# stdin, and a second delivery replaces the first
sed 's/queue consumer/cron worker/' "$good" | rrun - >/dev/null
assert_eq "reply from stdin replaces the section" "$(grep -c 'cron worker' "$RC")" "1"
assert_eq "…and the first delivery is gone" "$(grep -c 'queue consumer' "$RC")" "0"
assert_eq "…still one ## Reply section" "$(grep -c '^## Reply$' "$RC")" "1"
assert_eq "one record per delivery" "$(grep -c '"event": "reply"' "$RF")" "2"

# a card with no ## Reply section gets one appended, after everything else
sed -i '/^## Reply/,$d' "$RC"
rrun "$good" >/dev/null
assert_eq "no section: one is appended" "$(grep -c '^## Reply$' "$RC")" "1"
assert_eq "no section: it comes after the Log" "$(grep -n '^## ' "$RC" | tail -1 | cut -d: -f2)" "## Reply"

# ## Reply is not always last: the section that follows must survive a delivery
rcard; printf '\n## Notes\n- kept\n' >>"$RC"
rrun "$good" >/dev/null
assert_eq "a section after ## Reply survives" "$(grep -c '^- kept$' "$RC")" "1"
assert_eq "…and ## Reply holds the delivery, not the placeholder" "$(sed -n '/^## Reply/,/^## Notes/p' "$RC" | grep -c 'queue consumer')" "1"
assert_eq "…once" "$(grep -c '^## Reply$' "$RC")" "1"
chmod 664 "$RC"; rrun "$good" >/dev/null
assert_eq "the card keeps its file mode across the atomic write" "$(stat -c %a "$RC")" "664"

# the shape: four labels, in order, or nothing is written
rcard
bad="$SHEPHERD_ROOT/bad.md"
grep -v '^\*\*Confidence\*\*' "$good" >"$bad"
out=$(rrun "$bad" 2>&1 >/dev/null); rc=$?
assert_eq "a missing label: exit 1" "$rc" "1"
assert_ok "a missing label: names it" grep -q 'Confidence' <<<"$out"
assert_eq "a missing label: nothing written to the card" "$(grep -c 'written by shepherd-reply' "$RC")" "1"
assert_eq "a missing label: no record" "$(grep -c '"event": "reply"' "$RF")" "5"
{ sed -n '3,$p' "$good"; sed -n '1,2p' "$good"; } >"$bad"   # Answer last
out=$(rrun "$bad" 2>&1 >/dev/null); rc=$?
assert_eq "labels out of order: exit 1" "$rc" "1"
assert_ok "labels out of order: says so" grep -qi 'order' <<<"$out"
: >"$bad"
out=$(rrun "$bad" 2>&1 >/dev/null); rc=$?
assert_eq "an empty reply: exit 1" "$rc" "1"
assert_ok "an empty reply: says so (not the missing-label refusal)" grep -q 'is empty' <<<"$out"
{ cat "$good"; printf '\n## Extra heading\ntail content\n'; } >"$bad"
out=$(rrun "$bad" 2>&1 >/dev/null); rc=$?
assert_eq "an H2 inside the reply: exit 1" "$rc" "1"
assert_ok "an H2 inside the reply: says why" grep -q 'cannot hold an H2' <<<"$out"
assert_eq "an H2 inside the reply: nothing written" "$(grep -c 'Extra heading' "$RC")" "0"
# over 150 words: a warning on stderr, still recorded, the count on the record
{ cat "$good"; yes 'word' | head -240 | tr '\n' ' '; echo; } >"$bad"
out=$(rrun "$bad" 2>&1); rc=$?
assert_eq "over 150 words: still recorded (exit 0)" "$rc" "0"
assert_ok "over 150 words: warns, naming the cap" grep -q '150' <<<"$out"
assert_eq "over 150 words: the record carries the count" "$(field "$RF" words)" "271"
# The threshold itself, not just the message: a 271-word fixture is over 150 AND
# over the old 250, so it passes whichever number the script holds. These two
# bracket 150 — a revert of the comparison fails one of them (T-0263).
{ cat "$good"; yes 'word' | head -140 | tr '\n' ' '; echo; } >"$bad"
out=$(rrun "$bad" 2>&1); rc=$?
assert_eq "171 words: still recorded (exit 0)" "$rc" "0"
assert_eq "171 words: the record carries the count" "$(field "$RF" words)" "171"
assert_ok "171 words: over 150, so it warns" grep -q '150' <<<"$out"
{ cat "$good"; yes 'word' | head -100 | tr '\n' ' '; echo; } >"$bad"
out=$(rrun "$bad" 2>&1); rc=$?
assert_eq "131 words: still recorded (exit 0)" "$rc" "0"
assert_eq "131 words: the record carries the count" "$(field "$RF" words)" "131"
assert_fail "131 words: under 150, so it does not warn" grep -q 'trim before shepherd posts it' <<<"$out"

# the guards shepherd-status has
out=$(env -u SHEPHERD_TASK_ID -u SHEPHERD_STATUS_FILE "$RP" "$good" 2>&1 >/dev/null); rc=$?
assert_eq "outside a worker session: exit 1" "$rc" "1"
assert_ok "outside a worker session: says the env is missing" grep -q 'are not set' <<<"$out"
MM2="$SHEPHERD_ROOT/ledger/status/T-0999.jsonl"; rm -f "$MM2"
out=$(SHEPHERD_TASK_ID=T-0300 SHEPHERD_STATUS_FILE="$MM2" "$RP" "$good" 2>&1 >/dev/null); rc=$?
assert_eq "another task's status file: exit 1" "$rc" "1"
assert_nofile "another task's status file: nothing is written" "$MM2"
assert_ok "another task's status file: names the task" grep -q 'T-0300' <<<"$out"
assert_ok "another task's status file: names the file" grep -q 'T-0999.jsonl' <<<"$out"
out=$(SHEPHERD_TASK_ID=T-0301 SHEPHERD_STATUS_FILE="$SHEPHERD_ROOT/ledger/status/T-0301.jsonl" "$RP" "$good" 2>&1 >/dev/null); rc=$?
assert_eq "no card at the derived path: exit 1" "$rc" "1"
assert_ok "no card: names the path it derived" grep -q 'ledger/tasks/T-0301.md' <<<"$out"
out=$(rrun 2>&1 >/dev/null); rc=$?
assert_eq "no argument is a usage error (2)" "$rc" "2"

# --- the watcher fires on it ------------------------------------------------
export CLAUDE_CODE_SESSION_ID=sess-me SHEPHERD_ID=shepherd-test SHEPHERD_WATCH_POLL=0.2
mkdir -p "$SHEPHERD_ROOT/ledger/status" "$SHEPHERD_ROOT/ledger/tasks"
printf '# T-0020: probe\nstate: working\nowner: shepherd-test\nproject: p\nsize: M   tier: standard   budget: 30m\npane: none   session: none\n' >"$SHEPHERD_ROOT/ledger/tasks/T-0020.md"
WF="$SHEPHERD_ROOT/ledger/status/T-0020.jsonl"; rm -f "$WF"
bash "$W" arm T-0020 status --window 10 >"$SHEPHERD_ROOT/out" 2>/dev/null & wp=$!
sleep 0.6
SHEPHERD_TASK_ID=T-0020 SHEPHERD_STATUS_FILE="$WF" "$S" blocked "approve the plan" >/dev/null
wait "$wp"; rc=$?
assert_eq "a command claim wakes the status watcher (0)" "$rc" "0"
assert_eq "…and the verdict names it" "$(head -n 1 "$SHEPHERD_ROOT/out")" "STATUS claim blocked"

finish
