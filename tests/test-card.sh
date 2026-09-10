#!/usr/bin/env bash
# shepherd-card: owner-gated card edits, one card per commit, Log lines with the time.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
C="$HERE/../bin/shepherd-card"
T="$SHEPHERD_ROOT/ledger/tasks"
export SHEPHERD_ID=shepherd-kelpie
export SHEPHERD_NOW_OVERRIDE="2026-09-01T10:30:00+00:00"
HHMM=$(date -d "$SHEPHERD_NOW_OVERRIDE" +%H:%M)

echo "test-card:"

git -C "$SHEPHERD_ROOT" init -q -b main
git -C "$SHEPHERD_ROOT" config user.email t@t
git -C "$SHEPHERD_ROOT" config user.name T
git -C "$SHEPHERD_ROOT" commit -q --allow-empty -m seed

write_card() {  # <id> <owner-line-or-empty>
  cat > "$T/$1.md" <<EOF
# $1: fixture
state: queued
${2:+$2
}project: karta~2
size: M   tier: standard   budget: 120m
pane: none   session: none
created: 2026-09-01T09:00

## Brief

### Objective
x

## Log
- 09:00 captured (fixture)

## Handoff
- Branch: none
EOF
}
last_msg() { git -C "$SHEPHERD_ROOT" log -1 --format=%s; }
count() { git -C "$SHEPHERD_ROOT" rev-list --count HEAD; }

# --- get ------------------------------------------------------------------------
write_card T-0001 "owner: shepherd-kelpie"
assert_eq "get reads a field"                    "$(bash "$C" get T-0001 state)" "queued"
assert_fail "get exits 1 for an absent field"    bash "$C" get T-0001 linear-session
write_card T-0002 ""
assert_eq "get owner defaults to shepherd-1"     "$(bash "$C" get T-0002 owner)" "shepherd-1"

# --- transition ------------------------------------------------------------------
before=$(count)
out=$(bash "$C" transition T-0001 briefed --log "slot 1/6"); rc=$?
assert_eq "transition exits 0"                   "$rc" "0"
assert_eq "transition verdict line"              "$(printf '%s\n' "$out" | head -1)" "TRANSITION T-0001 queued → briefed"
assert_eq "state rewritten"                      "$(bash "$C" get T-0001 state)" "briefed"
assert_eq "one commit per transition"            "$(( $(count) - before ))" "1"
assert_eq "commit message is the transition"     "$(last_msg)" "T-0001: queued → briefed"
assert_eq "Log line carries time, transition and detail" \
  "$(grep -c "^- $HHMM queued → briefed (slot 1/6)$" "$T/T-0001.md")" "1"
assert_eq "Log line lands before ## Handoff" \
  "$(awk '/^## Log/{p=1} /^## Handoff/{p=0} p' "$T/T-0001.md" | grep -c 'queued → briefed')" "1"
assert_eq "commit carries only the card" \
  "$(git -C "$SHEPHERD_ROOT" show --name-only --format= HEAD | grep -c .)" "1"

out=$(bash "$C" transition T-0001 briefed); rc=$?
assert_eq "same-state transition is refused"     "$rc" "1"
assert_eq "and says so"                          "$(printf '%s\n' "$out" | head -1)" "REFUSED T-0001 is already briefed"
out=$(bash "$C" transition T-0001 sleeping 2>&1); rc=$?
assert_eq "unknown state exits 2"                "$rc" "2"

# --also: extra paths ride the transition commit
mkdir -p "$SHEPHERD_ROOT/ledger/status"; printf '{}\n' > "$SHEPHERD_ROOT/ledger/status/T-0001.jsonl"
bash "$C" transition T-0001 done --also 'ledger/status/T-0001*.jsonl' >/dev/null
assert_eq "--also path is in the commit" \
  "$(git -C "$SHEPHERD_ROOT" show --name-only --format= HEAD | grep -c 'status/T-0001.jsonl')" "1"
assert_eq "--also commit message is still the transition" "$(last_msg)" "T-0001: briefed → done"
bash "$C" transition T-0001 review --also 'ledger/status/T-0001-nomatch*.jsonl' >/dev/null; rc=$?
assert_eq "an --also glob matching nothing is skipped, not fatal" "$rc" "0"

# --- owner rule ------------------------------------------------------------------
out=$(bash "$C" transition T-0002 briefed); rc=$?
assert_eq "a card owned by shepherd-1 refuses shepherd-kelpie" "$rc" "1"
assert_eq "refusal names both"                   "$(printf '%s\n' "$out" | head -1)" "REFUSED T-0002 is owned by shepherd-1, not shepherd-kelpie"
assert_eq "refused card unchanged"               "$(bash "$C" get T-0002 state)" "queued"
out=$(SHEPHERD_ID=shepherd-1 bash "$C" transition T-0002 briefed); rc=$?
assert_eq "shepherd-1 owns the ownerless card"   "$rc" "0"
out=$(env -u SHEPHERD_ID bash "$C" log T-0001 "x: y" 2>&1); rc=$?
assert_eq "unset SHEPHERD_ID exits 2"            "$rc" "2"
out=$(SHEPHERD_ID="bad id" bash "$C" log T-0001 "x: y" 2>&1); rc=$?
assert_eq "malformed SHEPHERD_ID exits 2"        "$rc" "2"

# --- set ------------------------------------------------------------------------
before=$(count)
out=$(bash "$C" set T-0001 pane w1:p2 session sess-9 --log "briefed pane w1:p2, opus/high")
assert_eq "set verdict"                          "$(printf '%s\n' "$out" | head -1)" "SET T-0001 pane=w1:p2 session=sess-9"
assert_eq "pane set, session set, on one line" \
  "$(grep -c '^pane: w1:p2   session: sess-9$' "$T/T-0001.md")" "1"
assert_eq "set --log appended"                   "$(grep -c "^- $HHMM briefed pane w1:p2, opus/high$" "$T/T-0001.md")" "1"
assert_eq "set is one commit"                    "$(( $(count) - before ))" "1"
assert_eq "set commit message"                   "$(last_msg)" "T-0001: pane w1:p2, session sess-9"
bash "$C" set T-0001 tier heavy >/dev/null
assert_eq "mid-line tier set leaves size and budget" \
  "$(grep -c '^size: M   tier: heavy   budget: 120m$' "$T/T-0001.md")" "1"
bash "$C" set T-0001 project karta >/dev/null
assert_eq "line-start field replaced whole"      "$(bash "$C" get T-0001 project)" "karta"
SHEPHERD_ID=shepherd-1 bash "$C" set T-0002 owner shepherd-1 >/dev/null
assert_eq "absent owner is inserted under state:" \
  "$(sed -n '2,3p' "$T/T-0002.md" | tr '\n' '|')" "state: briefed|owner: shepherd-1|"
bash "$C" set T-0001 linear-session abc >/dev/null
assert_eq "an absent field is appended to the header" \
  "$(awk 'NR>1 && /^$/{exit} /^linear-session: abc$/{f=1} END{print f+0}' "$T/T-0001.md")" "1"

# --- log ------------------------------------------------------------------------
before=$(count)
out=$(bash "$C" log T-0001 "watchers armed: status+stall")
assert_eq "log verdict"                          "$(printf '%s\n' "$out" | head -1)" "LOGGED T-0001 - $HHMM watchers armed: status+stall"
assert_eq "log commit message is the whole text when it fits" "$(last_msg)" "T-0001: watchers armed: status+stall"
assert_eq "log is one commit"                    "$(( $(count) - before ))" "1"
before=$(count)
bash "$C" log T-0001 "note without commit" --no-commit >/dev/null
assert_eq "--no-commit commits nothing"          "$(( $(count) - before ))" "0"
assert_eq "--no-commit still wrote the line"     "$(grep -c 'note without commit' "$T/T-0001.md")" "1"
# T-0253 item 2: the subject was the text before the first colon, so the
# 2026-09-06 23:57 line on T-0222 committed as "T-0222: blocked 23" (365389b).
# Now: the whole text when the subject fits 72 characters, else the text up to
# its first ". " or "; " - a clause, whatever colons it carries.
bash "$C" log T-0001 "blocked 23:53 → answered: design approved as written; ruling 1 writing-plans then in-session implement + one review subagent; ruling 2 two FRAMEWORK.md rows (protocols, incidents = framework); decision logged" >/dev/null
assert_eq "a long text with colons commits its first clause intact, not the text before the first colon" \
  "$(last_msg)" "T-0001: blocked 23:53 → answered: design approved as written"
bash "$C" log T-0001 "watchers armed: status+stall, both on 1800 s windows. Stall anchor is the last stop event; re-armed at the next heartbeat" >/dev/null
assert_eq "a long text ends its subject at the first sentence" \
  "$(last_msg)" "T-0001: watchers armed: status+stall, both on 1800 s windows"
bash "$C" log T-0001 "dispatch held: worker-cap 6 reached, e.g. two reply lanes and four builds count against the same cap" >/dev/null
assert_eq "an abbreviation's dot does not end the sentence" \
  "$(last_msg)" "T-0001: dispatch held: worker-cap 6 reached, e.g. two reply lanes and four builds count against the same cap"
bash "$C" log T-0001 "review: the worker's branch at 3ec5933 passes the suite with the fixtures Saket owes still open" >/dev/null
assert_eq "a long text with no sentence or clause break is the subject whole" \
  "$(last_msg)" "T-0001: review: the worker's branch at 3ec5933 passes the suite with the fixtures Saket owes still open"
out=$(bash "$C" log T-0002 "orphan: lock kept, holder shepherd-9 gone" --orphan); rc=$?
assert_eq "--orphan may write a card you do not own" "$rc" "0"
out=$(bash "$C" log T-0002 "orphan? no: a plain note" --orphan 2>&1); rc=$?
assert_eq "--orphan needs the text to start with orphan" "$rc" "2"
out=$(bash "$C" log T-0002 "plain note" 2>&1); rc=$?
assert_eq "a plain log on a foreign card is refused" "$rc" "1"

# a card with no ## Log section gets one
printf '# T-0003: bare\nstate: queued\nowner: shepherd-kelpie\nproject: karta\ncreated: 2026-09-01T09:00\n' > "$T/T-0003.md"
bash "$C" log T-0003 "first: line" >/dev/null
assert_eq "## Log created when absent" "$(grep -c '^## Log$' "$T/T-0003.md")" "1"
assert_eq "and the line sits under it"  "$(sed -n '/^## Log$/{n;p}' "$T/T-0003.md")" "- $HHMM first: line"

# --- T-0253 item 1: the Log scan stops at any heading, a ### sub-heading included --
# add_log walked to the next "## " line, so a ### heading inside ## Log collected
# the new line under itself instead of at the Log's own end.
write_card T-0005 "owner: shepherd-kelpie"
sed -i '/^- 09:00 captured (fixture)$/a \\n### Notes\nnot a log line' "$T/T-0005.md"
bash "$C" log T-0005 "second: line" --no-commit >/dev/null
assert_eq "a Log line lands before a ### heading inside ## Log" \
  "$(sed -n '/^## Log$/,/^### Notes$/p' "$T/T-0005.md" | grep -c "^- $HHMM second: line$")" "1"
assert_eq "and not after the heading's text" \
  "$(sed -n '/^### Notes$/,/^## Handoff$/p' "$T/T-0005.md" | grep -c 'second: line')" "0"

# --- errors --------------------------------------------------------------------
out=$(bash "$C" get T-9999 state 2>&1); rc=$?
assert_eq "missing card exits 2"                 "$rc" "2"
printf 'reserved-by: shepherd-1 w6:p1 sess-1 now\n' > "$T/T-0004.md"
out=$(bash "$C" log T-0004 "x: y" 2>&1); rc=$?
assert_eq "a reservation is not a card"          "$rc" "2"

# --- fix round 1: finding 1 - a commit failure rolls the card edit back --------
hook="$SHEPHERD_ROOT/.git/hooks/pre-commit"
mkdir -p "$(dirname "$hook")"
printf '#!/bin/sh\necho "pre-commit says no" >&2\nexit 1\n' > "$hook"; chmod +x "$hook"
state_before=$(bash "$C" get T-0003 state)
out=$(bash "$C" transition T-0003 briefed --log "should not land" 2>&1); rc=$?
assert_eq "a rejected commit exits 2"                  "$rc" "2"
assert_eq "first stdout line is COMMIT-FAILED T-0003"  \
  "$(printf '%s\n' "$out" | head -1 | grep -c '^COMMIT-FAILED T-0003 ')" "1"
assert_eq "state on disk is unchanged"                 "$(bash "$C" get T-0003 state)" "$state_before"
assert_eq "the Log line was not added"                 "$(grep -c 'should not land' "$T/T-0003.md")" "0"
assert_eq "the card is not left staged"                \
  "$(git -C "$SHEPHERD_ROOT" diff --cached --name-only | grep -c 'T-0003.md')" "0"
rm -f "$hook"
out=$(bash "$C" transition T-0003 briefed --log "now it lands"); rc=$?
assert_eq "the same transition commits normally once the hook is gone" "$rc" "0"
assert_eq "state landed this time"                     "$(bash "$C" get T-0003 state)" "briefed"

# --- fix round 1: finding 2 - identity is checked before any file is read -----
out=$(env -u SHEPHERD_ID bash "$C" log T-9999 "x: y" 2>&1); rc=$?
assert_eq "unset SHEPHERD_ID on a missing card still exits 2" "$rc" "2"
assert_eq "and names the identity problem, not 'no card'" \
  "$(printf '%s\n' "$out" | head -1 | grep -c '^ERROR SHEPHERD_ID is unset')" "1"

# --- fix round 1: finding 3 - usage errors print on stdout too -----------------
out=$(bash "$C" 2>/dev/null); rc=$?
assert_eq "bare invocation exits 2"              "$rc" "2"
assert_eq "and ERROR usage is on stdout"         "$(printf '%s\n' "$out" | head -1 | grep -c '^ERROR usage')" "1"

# --- T-0221 final review fix 1: --log/--also with a missing value must not hang ---
# (shift 2 with one positional left is a no-op returning 1: the loop never advances)
out=$(timeout 5 bash "$C" transition T-0001 done --log 2>/dev/null); rc=$?
assert_eq "transition --log with no value exits 2, not a timeout (124)" "$rc" "2"
assert_eq "and the first stdout line is the usage error" \
  "$(printf '%s\n' "$out" | head -1 | grep -c '^ERROR usage')" "1"
out=$(timeout 5 bash "$C" transition T-0001 done --also 2>/dev/null); rc=$?
assert_eq "transition --also with no value exits 2, not a timeout (124)" "$rc" "2"
assert_eq "and the first stdout line is the usage error" \
  "$(printf '%s\n' "$out" | head -1 | grep -c '^ERROR usage')" "1"

finish
