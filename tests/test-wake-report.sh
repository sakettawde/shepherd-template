#!/usr/bin/env bash
# shepherd-wake-report: wake steps 5-9 as one read. Every line kind is driven through
# the liveness hooks; the exit code says whether anything needs an act.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
W="$HERE/../bin/shepherd-wake-report"
LOCK="$HERE/../bin/shepherd-lock"
T="$SHEPHERD_ROOT/ledger/tasks"
L="$SHEPHERD_ROOT/ledger/locks"
export SHEPHERD_ID=shepherd-kelpie CLAUDE_CODE_SESSION_ID=sess-k
unset HERDR_PANE_ID                                   # decide answers unknown without a herdr call
export SHEPHERD_INBOX_ENV="$SHEPHERD_ROOT/no-inbox.env" # shepherd-inbox owner exits 3
export SHEPHERD_PANE_SESSION_OVERRIDE=sess-probe        # pane_probe's answer for a backfill
# live pairs: my own pane, a live peer, one live worker pane
export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-k w6:p2:sess-c w1:p1:sess-w1"
export SHEPHERD_LIVENESS_UNKNOWN="w1:p4:sess-w4"

echo "test-wake-report:"

card() {  # <id> <state> <owner-or-empty> <project> <pane> <session>
  {
    printf '# %s: f\nstate: %s\n' "$1" "$2"
    [ -n "$3" ] && printf 'owner: %s\n' "$3"
    printf 'project: %s\nsize: S   tier: standard   budget: 30m\npane: %s   session: %s\ncreated: 2026-09-01T0%s:00\n\n## Log\n- 09:00 x\n' "$4" "$5" "$6" "${1: -1}"
  } > "$T/$1.md"
}
lock() { printf '%s\n' "$2 $3 $4 $5 2026-09-01T09:00:00+00:00" > "$L/$1.lock"; }

# identity locks: me (live), collie (live), huntaway (gone)
lock shepherd-kelpie   shepherd-kelpie   w6:p1 sess-k none
lock shepherd-collie   shepherd-collie   w6:p2 sess-c none
lock shepherd-huntaway shepherd-huntaway w6:p3 sess-h none
lock shepherd-collie.reclaim shepherd-kelpie w6:p1 sess-k none

card T-0001 working shepherd-kelpie karta   w1:p1 sess-w1      # all good
card T-0002 blocked shepherd-kelpie karta~2 w1:p2 none         # pane live, session missing -> backfill
card T-0003 briefed shepherd-kelpie karta~3 claiming-shepherd-kelpie-T-0003 none   # died mid-claim
card T-0004 review  shepherd-kelpie ip      w1:p4 sess-w4      # pane unresolved; lock held by gone huntaway -> orphan/takeover
card T-0005 working shepherd-collie kk      w2:p1 sess-x       # a peer's
card T-0006 working ""              old     w1:p9 sess-9       # ownerless -> shepherd-1's, not mine
card T-0007 queued  shepherd-kelpie karta   none  none         # my queue
card T-0008 queued  shepherd-kelpie karta~2 none  none
card T-0009 done    shepherd-kelpie karta~4 none  none         # stale lock below
card T-0010 working shepherd-kelpie karta~5 w1:p1 sess-w1      # lock missing
lock project-karta   shepherd-kelpie w6:p1 sess-k T-0001
lock project-karta~2 shepherd-kelpie w6:p1 sess-k T-0002
lock project-karta~3 shepherd-kelpie w6:p1 sess-k T-0003
lock project-ip      shepherd-huntaway w6:p3 sess-h T-0004
lock project-kk      shepherd-collie w6:p2 sess-c T-0005
lock project-karta~4 shepherd-kelpie w6:p1 sess-k T-0009

# LOCK-MISMATCH (owned by): a lock I hold whose active task is owned by a peer
card T-0012 working shepherd-huntaway own1 w1:p12 sess-w12
lock project-own1 shepherd-kelpie w6:p1 sess-k T-0012

# LOCK-MISMATCH (names) + loop2 dedup: the lock on lane mmx names T-0013, whose
# own card names lane mmy; T-0014's own lane IS mmx, so loop 2 would re-report
# the same lock from the card's side without the dedup fix.
card T-0013 working shepherd-kelpie mmy w1:p1 sess-w1
card T-0014 working shepherd-kelpie mmx w1:p1 sess-w1
lock project-mmx shepherd-kelpie w6:p1 sess-k T-0013
lock project-mmy shepherd-kelpie w6:p1 sess-k T-0013

# PANE-NONE: an active card of mine carrying no pane at all
card T-0015 working shepherd-kelpie pn1 none none
lock project-pn1 shepherd-kelpie w6:p1 sess-k T-0015

out=$(bash "$W"); rc=$?
has() { assert_eq "$1" "$(printf '%s\n' "$out" | grep -c -- "$2")" "1"; }
has "active mine"                    "^ACTIVE-MINE T-0001 working karta pane=w1:p1 session=sess-w1$"
has "active other names its owner"   "^ACTIVE-OTHER T-0005 working kk owner=shepherd-collie pane=w2:p1$"
has "ownerless active card is shepherd-1's" "^ACTIVE-OTHER T-0006 working old owner=shepherd-1 "
has "lock ok"                        "^LOCK-OK project-karta T-0001$"
has "stale lock over a done card"    "^LOCK-STALE project-karta~4 held by me over T-0009 (done) - release$"
has "orphan lock over my card"       "^LOCK-ORPHAN project-ip held by shepherd-huntaway (gone) over T-0004 (mine) - takeover$"
has "missing lock"                   "^LOCK-MISSING T-0010 (mine, working) has no project-karta~5 lock - report$"
has "lock mismatch owned by"         "^LOCK-MISMATCH project-own1 held by me over T-0012 owned by shepherd-huntaway - report$"
has "lock mismatch names"            "^LOCK-MISMATCH project-mmx held by me, but T-0013 names mmy - report$"
assert_eq "lock mismatch names has no second line from loop 2" "$(printf '%s\n' "$out" | grep -c 'LOCK-MISMATCH project-mmx')" "1"
has "pane none"                      "^PANE-NONE T-0015 - no pane on the card - report$"
has "pane live, session matches"     "^PANE-LIVE T-0001 w1:p1 session=match$"
has "pane live, session missing"     "^PANE-LIVE T-0002 w1:p2 session=missing agent_session=sess-probe - backfill$"
has "claiming placeholder"           "^CLAIMING T-0003 claiming-shepherd-kelpie-T-0003 - dispatch died mid-claim: shepherd-preflight undo T-0003$"
has "pane unresolved"                "^PANE-UNRESOLVED T-0004 w1:p4 - herdr unreachable$"
has "watchers missing"               "^WATCH-MISSING T-0001 status,stall - shepherd-watch rearm T-0001$"
has "inbox none"                     "^INBOX none$"
has "queue oldest first (1)"         "^QUEUE-MINE T-0007 karta created=2026-09-01T07:00$"
assert_eq "queue order" "$(printf '%s\n' "$out" | grep '^QUEUE-MINE' | awk '{print $2}' | tr '\n' ' ')" "T-0007 T-0008 "
has "instance me"                    "^INSTANCE shepherd-kelpie live pane=w6:p1 tasks=T-0001,T-0002,T-0003,T-0004,T-0010,T-0013,T-0014,T-0015 (you)$"
has "instance peer live"             "^INSTANCE shepherd-collie live pane=w6:p2 tasks=T-0005$"
has "instance gone"                  "^INSTANCE shepherd-huntaway gone "
assert_eq "reclaim lock is not an instance" "$(printf '%s\n' "$out" | grep -c 'INSTANCE shepherd-collie.reclaim')" "0"
assert_eq "STATUS is the last line" "$(printf '%s\n' "$out" | tail -1 | cut -c1-11)" "STATUS ctx "
has "STATUS names the parts"         "^STATUS ctx unknown, active: T-0001 T-0002 T-0003 T-0004 T-0010 T-0013 T-0014 T-0015; others: shepherd-collie T-0005, shepherd-huntaway (gone) T-0012; inbox: none; orphans: T-0004$"
assert_eq "attention -> exit 3" "$rc" "3"

# a pane that is gone
card T-0011 working shepherd-kelpie karta~6 w1:p7 sess-w7
lock project-karta~6 shepherd-kelpie w6:p1 sess-k T-0011
out=$(bash "$W")
has "pane gone"                      "^PANE-GONE T-0011 w1:p7 - mark blocked and investigate$"

# a clean ledger: only routine lines, exit 0
rm -f "$T"/T-*.md "$L"/project-*.lock
card T-0001 working shepherd-kelpie karta w1:p1 sess-w1
lock project-karta shepherd-kelpie w6:p1 sess-k T-0001
mkdir -p "$SHEPHERD_ROOT/ledger/watchers"
sleep 300 & SP=$!
for k in status stall; do
  printf 'task=T-0001\nkind=%s\npid=%s\nppid=%s\narmed_at=x\nwindow=1800\nanchor=0\nsession=sess-k\nowner=shepherd-kelpie\npane=w1:p1\nfile=x\n' "$k" "$SP" "$$" > "$SHEPHERD_ROOT/ledger/watchers/T-0001.$k"
done
out=$(bash "$W"); rc=$?
kill "$SP" 2>/dev/null
has "watchers ok"                    "^WATCH-OK T-0001$"
assert_eq "clean ledger -> exit 0" "$rc" "0"
assert_eq "no attention lines" "$(printf '%s\n' "$out" | grep -cE '^(LOCK-(STALE|ORPHAN|MISSING|MISMATCH|HELD-LIVE|UNRESOLVED)|PANE-(GONE|UNRESOLVED)|CLAIMING|WATCH-MISSING)')" "0"

# --- T-0240: a live reply card holds no lane lock by design -----------------
# kind: reply runs on a throwaway worktree with no project lock; beside the
# build on project-karta it must draw no LOCK-MISSING and no LOCK-MISMATCH.
card T-0002 working shepherd-kelpie karta w1:p1 sess-w1
sed -i '/^state:/a kind: reply' "$T/T-0002.md"
out=$(bash "$W")
assert_eq "a reply card draws no LOCK line" "$(printf '%s\n' "$out" | grep '^LOCK-' | grep -c 'T-0002')" "0"
has "the build lane's lock beside it still reads OK" "^LOCK-OK project-karta T-0001$"
has "the reply card is still an active card of mine" "^ACTIVE-MINE T-0002 working karta pane=w1:p1 session=sess-w1$"
rm -f "$T/T-0002.md"

# --- T-0221 fix 2: STATUS ctx carries the percent, with decide's word beside it --
# The herdr stub renders what statusline.py renders (test-decide.sh's pattern,
# reused here): "ctx <bar> <pct>%/<size>k". shepherd-rollover's own probe_ctx
# is what reads it - the liveness overrides above don't touch this path.
BIN="$SHEPHERD_ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pane read") printf '  Opus 5 | ctx ▓▓░░░░░░░░ 42%%/196k | shepherd-test\n' ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
out=$(PATH="$BIN:$PATH" HERDR_PANE_ID=w9:p9 bash "$W")
has "STATUS carries the percent with decide's word beside it" \
  "^STATUS ctx 42% (ok), active: T-0001; others: shepherd-collie -, shepherd-huntaway (gone) -; inbox: none; orphans: none$"

# --- T-0237: the INBOX line says when the Worker names no operator ------------
# shepherd-inbox is a stub through SHEPHERD_INBOX_SCRIPT (the seam hooks_active gates):
# `owner` exits STUB_OWNER_RC, `operators` prints STUB_OPERATORS and exits
# STUB_OPERATORS_RC; every call is logged so a state that must not consult the
# operator list can be shown not to.
cat > "$BIN/shepherd-inbox" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$STUB_CALLS"
case "$1" in
  owner)     exit "${STUB_OWNER_RC:-0}" ;;
  operators) printf '%s' "${STUB_OPERATORS:-}"; exit "${STUB_OPERATORS_RC:-0}" ;;
esac
exit 2
STUB
chmod +x "$BIN/shepherd-inbox"
export SHEPHERD_INBOX_SCRIPT="$BIN/shepherd-inbox" STUB_CALLS="$SHEPHERD_ROOT/inbox-calls"
# run_inbox — the report with the stub answering; `out` lands in this shell for `has`
run_inbox() { : >"$STUB_CALLS"; out=$(PATH="$BIN:$PATH" HERDR_PANE_ID=w9:p9 bash "$W"); }
STUB_OWNER_RC=0 STUB_OPERATORS= run_inbox
has "yours, operator_ids empty → the trailing token" "^INBOX yours operators=empty$"
has "…and STATUS carries it too" \
  "^STATUS ctx 42% (ok), active: T-0001; others: shepherd-collie -, shepherd-huntaway (gone) -; inbox: yours operators=empty; orphans: none$"
assert_eq "…and operators was consulted once" "$(grep -c operators "$STUB_CALLS")" "1"
STUB_OWNER_RC=0 STUB_OPERATORS=$'u1\nu2' run_inbox
has "yours, operator_ids set → INBOX yours, nothing trailing" "^INBOX yours$"
STUB_OWNER_RC=0 STUB_OPERATORS= STUB_OPERATORS_RC=1 run_inbox
has "yours, operators unreachable → nothing trailing: it knows nothing" "^INBOX yours$"
STUB_OWNER_RC=3 STUB_OPERATORS= run_inbox
has "none → INBOX none, exactly" "^INBOX none$"
assert_eq "…and operators was not consulted" "$(grep -c operators "$STUB_CALLS")" "0"
STUB_OWNER_RC=1 STUB_OPERATORS= run_inbox
has "unreachable → INBOX unreachable, exactly" "^INBOX unreachable$"
assert_eq "…and operators was not consulted" "$(grep -c operators "$STUB_CALLS")" "0"
has "…and STATUS names the state as before" "; inbox: unreachable; orphans: none$"
# the seam is gated: without the test hooks the real shepherd-inbox runs, and with no
# config it answers none
: >"$STUB_CALLS"
out=$(env -u SHEPHERD_TEST_HOOKS PATH="$BIN:$PATH" STUB_OWNER_RC=0 STUB_OPERATORS= bash "$W")
has "without SHEPHERD_TEST_HOOKS the stub is ignored" "^INBOX none$"
assert_eq "…and never called"                 "$(wc -l <"$STUB_CALLS")" "0"
unset SHEPHERD_INBOX_SCRIPT

# --- T-0253 item 6c: the session-missing probe's rc 1 and rc 2 branches ------
# pane_probe answers from herdr's JSON, never its exit status; with the
# SHEPHERD_PANE_SESSION_OVERRIDE hook unset it calls `herdr pane get`, which the
# PATH stub answers per pane the way herdr does: pane_not_found on stderr with
# exit 1 (rc 1, PANE-GONE), a non-JSON stderr (rc 2, PANE-UNRESOLVED). The
# cards with a session still resolve through the liveness hooks, never herdr.
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2 ${3:-}" in
  "pane read "*)    printf '  Opus 5 | ctx ▓▓░░░░░░░░ 42%%/196k | shepherd-test\n' ;;
  "pane get w1:pg") printf '{"error":{"code":"pane_not_found","message":"pane w1:pg not found"},"id":"cli:pane:get"}\n' >&2; exit 1 ;;
  "pane get w1:pu") printf 'herdr: connection refused\n' >&2; exit 1 ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
card T-0021 working shepherd-kelpie karta~7 w1:pg none
card T-0022 working shepherd-kelpie karta~8 w1:pu none
lock project-karta~7 shepherd-kelpie w6:p1 sess-k T-0021
lock project-karta~8 shepherd-kelpie w6:p1 sess-k T-0022
out=$(env -u SHEPHERD_PANE_SESSION_OVERRIDE PATH="$BIN:$PATH" HERDR_PANE_ID=w9:p9 bash "$W"); rc=$?
has "session missing, pane_not_found -> PANE-GONE" "^PANE-GONE T-0021 w1:pg - mark blocked and investigate$"
has "session missing, herdr unreachable -> PANE-UNRESOLVED" "^PANE-UNRESOLVED T-0022 w1:pu - herdr unreachable$"
has "the card with a session still reads through the liveness hook" "^PANE-LIVE T-0001 w1:p1 session=match$"
assert_eq "neither branch reports a session it could not read" \
  "$(printf '%s\n' "$out" | grep -c 'agent_session=')" "0"
rm -f "$T/T-0021.md" "$T/T-0022.md" "$L/project-karta~7.lock" "$L/project-karta~8.lock"

out=$(env -u SHEPHERD_ID bash "$W"); rc=$?
assert_eq "no SHEPHERD_ID -> exit 2" "$rc" "2"

finish
