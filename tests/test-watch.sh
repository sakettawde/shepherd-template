#!/usr/bin/env bash
# Probe for shepherd-watch — the one program that watches a worker: the
# status-file watcher and the herdr stall watcher, armed as one process with
# one wake, recorded under ledger/watchers/ (spec:
# docs/superpowers/specs/2026-09-02-worker-observation-design.md §3-§4).
#
# herdr is a stub on PATH (the test-rollover precedent): it logs its argv to
# $HERDR_STUB_DIR/calls and answers `agent wait` from $HERDR_STUB_DIR/verdict.
# No real herdr, no real pane. Timing knobs SHEPHERD_WATCH_POLL and
# SHEPHERD_WATCH_REPROBE keep the run to seconds.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
unset SHEPHERD_TASK_ID SHEPHERD_STATUS_FILE
W="$HERE/../bin/shepherd-watch"

echo "test-watch:"

export CLAUDE_CODE_SESSION_ID=sess-me SHEPHERD_ID=shepherd-test SHEPHERD_WATCH_POLL=0.2 SHEPHERD_WATCH_REPROBE=0.2
unset SHEPHERD_PANE_SESSION_OVERRIDE SHEPHERD_LIVENESS_OVERRIDE SHEPHERD_LIVENESS_UNKNOWN
mkdir -p "$SHEPHERD_ROOT/ledger/status" "$SHEPHERD_ROOT/ledger/tasks"
WATCHERS="$SHEPHERD_ROOT/ledger/watchers"

# The herdr stub. `agent wait` honours --timeout unless a verdict file says
# otherwise; `pane get` answers from pane_json or reports pane_not_found.
export HERDR_STUB_DIR="$SHEPHERD_ROOT/stub"; mkdir -p "$HERDR_STUB_DIR/bin"
cat >"$HERDR_STUB_DIR/bin/herdr" <<'STUB'
#!/usr/bin/env bash
# The call log keeps argument boundaries: `printf ' %q'` quotes anything that
# would otherwise blur into its neighbour (a value with a space, an empty
# argument), and the leading separator is trimmed so a call still reads as one
# plain space-joined line for the greps in the probe.
log=$(printf ' %q' "$@"); printf '%s\n' "${log# }" >>"$HERDR_STUB_DIR/calls"
case "$1 $2" in
  "agent wait")
    v=$(cat "$HERDR_STUB_DIR/verdict" 2>/dev/null)
    case "$v" in
      blocked)         echo '{"result":{"status":"blocked"}}'; exit 0 ;;
      agent_not_found) echo '{"error":{"code":"agent_not_found","message":"no agent"}}' >&2; exit 1 ;;
      garbage)         echo 'herdr: something broke' >&2; exit 1 ;;
      # herdr 0.8.2 returning `timeout` well short of the --timeout it was
      # given (T-0256 b): the stall watcher must re-issue, not report the
      # window as elapsed. Always 0.3 s, whatever --timeout says.
      early_timeout)   sleep 0.3 & sp=$!; trap 'kill "$sp" 2>/dev/null; exit 143' TERM INT
                       wait "$sp"; echo '{"error":{"code":"timeout"}}' >&2; exit 1 ;;
      # The pathological case the anti-spin guard exists for: `timeout` with no
      # elapsed time at all. Unguarded, the re-issue loop would turn a window
      # into a busy-wait of thousands of calls.
      instant_timeout) echo '{"error":{"code":"timeout"}}' >&2; exit 1 ;;
      *) ms=
         # `ms=$2` with --timeout last read an unset positional and silently
         # produced an instant timeout; a malformed call now says so.
         while [ $# -gt 0 ]; do
           if [ "$1" = --timeout ]; then
             [ $# -ge 2 ] || { echo '{"error":{"code":"bad_request","message":"--timeout needs a value"}}' >&2; exit 2; }
             ms=$2
           fi
           shift
         done
         [ -n "$ms" ] || { echo '{"error":{"code":"bad_request","message":"no --timeout"}}' >&2; exit 2; }
         # Sleep in the background and wait on it, so a TERM from shepherd-watch's
         # cleanup takes the sleep with it instead of orphaning it for the
         # whole window.
         sleep "$(python3 -c "print($ms/1000)")" & sp=$!
         trap 'kill "$sp" 2>/dev/null; exit 143' TERM INT
         wait "$sp"
         echo '{"error":{"code":"timeout"}}' >&2; exit 1 ;;
    esac ;;
  "pane get")
    if [ -f "$HERDR_STUB_DIR/pane_json" ]; then cat "$HERDR_STUB_DIR/pane_json"; exit 0; fi
    echo '{"error":{"code":"pane_not_found","message":"no pane"}}' >&2; exit 1 ;;
  *) echo '{"error":{"code":"unstubbed"}}' >&2; exit 1 ;;
esac
STUB
chmod +x "$HERDR_STUB_DIR/bin/herdr"
export PATH="$HERDR_STUB_DIR/bin:$PATH"
verdict() { printf '%s' "$1" >"$HERDR_STUB_DIR/verdict"; }
calls()   { cat "$HERDR_STUB_DIR/calls" 2>/dev/null; }
export -f calls  # asserts below read the log from inside `bash -c`
reset_stub() { rm -f "$HERDR_STUB_DIR/calls" "$HERDR_STUB_DIR/verdict" "$HERDR_STUB_DIR/pane_json"; }

# card <task> <pane> [size] [tier] — a minimal task card
card() {
  printf '# %s: probe\nstate: working\nowner: shepherd-test\nproject: p\nsize: %s   tier: %s   budget: 30m\npane: %s   session: none\n' \
    "$1" "${3:-M}" "${4:-standard}" "$2" >"$SHEPHERD_ROOT/ledger/tasks/$1.md"
}
status_file() { printf '%s/ledger/status/%s.jsonl' "$SHEPHERD_ROOT" "$1"; }
stop_line()  { printf '{"ts": "t", "event": "stop", "task": "%s", "claim": "%s", "claim_source": "%s", "tail": ""}\n' "$1" "$2" "${3:-sentinel}"; }
first_word() { awk 'NR==1{print $1}' "$1"; }

# run_bg <verb-and-flags...> — run shepherd-watch in the background; its pid lands in
# $BG and its stdout in $OUT. wait_rc <pid> leaves the exit code in $RC.
# Both travel through variables rather than stdout because bash only waits on a
# DIRECT child of the shell that forked it: `p=$(run_bg …)` orphans the watcher
# in the command-substitution subshell, and a `wait` inside $( ) answers for a
# process it does not own (both measured, bash 5.2.21, 2026-09-02).
OUT="$SHEPHERD_ROOT/out"
BG= RC=
run_bg()  { bash "$W" "$@" >"$OUT" 2>"$OUT.err" & BG=$!; }
wait_rc() { wait "$1"; RC=$?; }

# --- the status watcher: count-anchored, so a handled claim never re-fires --
card T-0001 none
F=$(status_file T-0001)
stop_line T-0001 done >"$F"
reset_stub
run_bg arm T-0001 status --window 1; pid=$BG
wait_rc "$pid"
assert_eq "arm over an existing terminal claim runs to its window (124)" "$RC" "124"
assert_eq "…and says TIMEOUT" "$(first_word "$OUT")" "TIMEOUT"
assert_eq "…and herdr was not called for a status-only arm" "$(calls | wc -l)" "0"

run_bg arm T-0001 status --window 10; pid=$BG
sleep 0.6
assert_file "an armed status watcher has a record" "$WATCHERS/T-0001.status"
assert_eq "the record carries the anchor" "$(sed -n 's/^anchor=//p' "$WATCHERS/T-0001.status")" "1"
assert_eq "the record carries the session" "$(sed -n 's/^session=//p' "$WATCHERS/T-0001.status")" "sess-me"
assert_eq "the record carries the owner" "$(sed -n 's/^owner=//p' "$WATCHERS/T-0001.status")" "shepherd-test"
assert_ok "list shows it live" bash -c "bash '$W' list T-0001 | grep -q '^T-0001 status live '"
assert_ok "check reports a pane-less stall watcher as unarmable" bash -c "bash '$W' check T-0001 | grep -q 'unarmable'"
stop_line T-0001 blocked >>"$F"
wait_rc "$pid"
assert_eq "a new terminal claim fires (0)" "$RC" "0"
assert_eq "…with the STATUS verdict naming it" "$(head -n 1 "$OUT")" "STATUS claim blocked"
assert_nofile "the record is removed when the watcher exits" "$WATCHERS/T-0001.status"

# --- the wake set beyond claims -------------------------------------------
fires_on() {  # <name> <line> — arm, append line, expect 0
  local p; run_bg arm T-0001 status --window 10; p=$BG; sleep 0.6
  printf '%s\n' "$2" >>"$F"
  wait_rc "$p"
  assert_eq "fires on $1" "$RC" "0"
}
ignores() {   # <name> <line> — arm with a 2 s window, append line, expect 124
  local p; run_bg arm T-0001 status --window 2; p=$BG; sleep 0.3
  printf '%s\n' "$2" >>"$F"
  wait_rc "$p"
  assert_eq "ignores $1" "$RC" "124"
}
fires_on "session_end"            '{"ts": "t", "event": "session_end", "task": "T-0001", "kind": "other"}'
fires_on "stop_failure"           '{"ts": "t", "event": "stop_failure", "task": "T-0001", "kind": "rate_limit"}'
fires_on "a permission_prompt notification" '{"ts": "t", "event": "notification", "task": "T-0001", "kind": "permission_prompt", "message": "x"}'
fires_on "a command claim"        '{"ts": "t", "event": "claim", "task": "T-0001", "kind": "command", "claim": "failed", "message": "x"}'
fires_on "an old-style stop claim without claim_source" '{"ts": "t", "event": "stop", "task": "T-0001", "claim": "done", "tail": ""}'
ignores  "an idle_prompt notification" '{"ts": "t", "event": "notification", "task": "T-0001", "kind": "idle_prompt", "message": "x"}'
ignores  "a working checkpoint"   "$(stop_line T-0001 working)"
ignores  "a claim none turn end"  "$(stop_line T-0001 none none)"
ignores  "a permission_request record (recorded, not waking — spec §3)" '{"ts": "t", "event": "permission_request", "task": "T-0001", "kind": "Bash", "summary": "ls"}'
ignores  "a stop record that inherited a command claim" "$(stop_line T-0001 blocked command)"
# A PRINTED claim wakes exactly as a sentinel does (T-0249). Nothing in
# wake_worthy names the source it fires on - it names the one it does NOT,
# `command`, the repeat of a claim already recorded this turn - so the hook's
# new source is wake-worthy by construction. This pins that it stays so.
fires_on "a printed claim"        "$(stop_line T-0001 done printed)"
ignores  "a printed working checkpoint" "$(stop_line T-0001 working printed)"
ignores  "a line that is not JSON" 'not json at all'
# A record naming ANOTHER task never wakes this watcher: a stray line written
# into the wrong status file by a partial env override elsewhere (measured
# 2026-09-02) must not reach shepherd as this task's claim.
ignores  "a terminal claim naming another task" '{"ts": "t", "event": "claim", "task": "T-9999", "kind": "command", "claim": "done", "message": "x"}'
ignores  "a session_end naming another task" '{"ts": "t", "event": "session_end", "task": "T-9999", "kind": "other"}'
fires_on "the same claim naming the watched task" '{"ts": "t", "event": "claim", "task": "T-0001", "kind": "command", "claim": "done", "message": "x"}'
fires_on "a claim with no task field at all (old files predate it)" '{"ts": "t", "event": "claim", "kind": "command", "claim": "done", "message": "x"}'

# --- the adaptive window ---------------------------------------------------
# Newest record wake-worthy (just handled) or file empty → HB; anything else →
# 900 (adapter R5). Read from the record's window= field.
window_after() {  # <last-line-or-empty> <size> <tier> [extra flags…]
  card T-0002 none "$2" "$3"; local f p w; f=$(status_file T-0002); rm -f "$f"
  [ -n "$1" ] && printf '%s\n' "$1" >"$f"
  run_bg arm T-0002 status "${@:4}"; p=$BG; sleep 0.6
  w=$(sed -n 's/^window=//p' "$WATCHERS/T-0002.status"); kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
  echo "$w"
}
assert_eq "empty file, S/M → 1800"            "$(window_after '' M standard)" "1800"
assert_eq "empty file, L → 3600"              "$(window_after '' L standard)" "3600"
assert_eq "empty file, heavy → 3600"          "$(window_after '' M heavy)" "3600"
assert_eq "newest is a terminal claim → HB"   "$(window_after "$(stop_line T-0002 done)" M standard)" "1800"
assert_eq "newest is a working checkpoint → 900" "$(window_after "$(stop_line T-0002 working)" M standard)" "900"
assert_eq "newest is claim none → 900"        "$(window_after "$(stop_line T-0002 none none)" L heavy)" "900"
assert_eq "newest is an idle_prompt → 900"    "$(window_after '{"ts": "t", "event": "notification", "task": "T-0002", "kind": "idle_prompt"}' M standard)" "900"
# --window overrides both arms (spec §3, §4). The first row is monitor re-arming
# an overrunning task: a long window asked for over a non-wake checkpoint, which
# the 900 s floor used to clamp silently.
assert_eq "--window 1200 beats the 900 floor" "$(window_after "$(stop_line T-0002 working)" M standard --window 1200)" "1200"
assert_eq "--window 60 beats the tier ceiling" "$(window_after '' L heavy --window 60)" "60"
# A leading zero is base TEN. Bash arithmetic reads one as octal, so the window
# reached every downstream reader unnormalised: the record's own field said
# `010` while the deadline counted 8 seconds.
assert_eq "--window 010 is ten seconds"       "$(window_after '' M standard --window 010)" "10"
assert_eq "--window 007 is seven seconds"     "$(window_after '' M standard --window 007)" "7"

# --- arm replaces, records are per process --------------------------------
card T-0003 none; rm -f "$(status_file T-0003)"
run_bg arm T-0003 status --window 30; p1=$BG; sleep 0.6
old=$(sed -n 's/^pid=//p' "$WATCHERS/T-0003.status")
run_bg arm T-0003 status --window 30; p2=$BG; sleep 0.8
assert_ok "arm kills the previous watcher of the same task" bash -c "! kill -0 $old 2>/dev/null"
assert_eq "the replaced arm process has exited" "$(kill -0 "$p1" 2>/dev/null && echo alive || echo gone)" "gone"
assert_eq "list shows exactly one live status watcher" "$(bash "$W" list T-0003 | grep -c '^T-0003 status live ')" "1"
kill "$p2" 2>/dev/null; wait "$p2" 2>/dev/null
assert_nofile "a killed arm removes its record" "$WATCHERS/T-0003.status"

# --- rearm fills the gap, and only the gap -------------------------------
card T-0004 none; rm -f "$(status_file T-0004)"
run_bg rearm T-0004 --window 30; p=$BG; sleep 0.6
assert_file "rearm with nothing armed arms the status watcher" "$WATCHERS/T-0004.status"
out=$(bash "$W" rearm T-0004 --window 30 2>"$OUT.err"); rc=$?
assert_eq "rearm with everything armed exits 4" "$rc" "4"
assert_eq "…and says ARMED-ALREADY" "${out%% *}" "ARMED-ALREADY"
assert_ok "…and the pane-less stall note went to stderr, never the verdict" grep -q '^STALL-SKIPPED' "$OUT.err"
assert_eq "…and the live watcher is untouched" "$(bash "$W" list T-0004 | grep -c '^T-0004 status live ')" "1"
kill "$p" 2>/dev/null; wait "$p" 2>/dev/null

# A record from a session that has rolled over: alive but can wake nobody.
# The stand-in has to LOOK like a watcher, because kill_record TERMs only a pid
# whose /proc/<pid>/cmdline says it runs this script (the bystander case
# below). A bare `sleep` would be spared - correctly - and this case would then
# pass for the wrong reason.
mkdir -p "$SHEPHERD_ROOT/fake" "$WATCHERS"
printf '#!/usr/bin/env bash\nsleep 60\n' >"$SHEPHERD_ROOT/fake/shepherd-watch"
bash "$SHEPHERD_ROOT/fake/shepherd-watch" & sl=$!
printf 'task=T-0004\nkind=status\npid=%s\nppid=%s\narmed_at=t\nwindow=30\nanchor=0\nsession=sess-old\nowner=shepherd-test\npane=none\nfile=x\n' "$sl" "$sl" >"$WATCHERS/T-0004.status"
assert_ok "list marks another session's watcher stale" bash -c "bash '$W' list T-0004 | grep -q '^T-0004 status stale '"
run_bg rearm T-0004 --window 30; p=$BG; sleep 0.8
assert_ok "rearm kills the stale watcher" bash -c "! kill -0 $sl 2>/dev/null"
assert_eq "rearm re-arms in its place" "$(sed -n 's/^session=//p' "$WATCHERS/T-0004.status")" "sess-me"
kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; kill "$sl" 2>/dev/null; wait "$sl" 2>/dev/null

# A live watcher of another INSTANCE. It reads `stale` here too - the session
# differs - but killing it would unwatch that instance's task with nobody told,
# and the thing that would have announced the failure is what was killed
# (T-0268). rearm refuses the whole target; `arm` stays the deliberate way to
# take one over. Same stand-in as above, so the case cannot pass on
# kill_record's is_watch_process guard instead of on the fix.
bash "$SHEPHERD_ROOT/fake/shepherd-watch" & peer=$!
printf 'task=T-0004\nkind=status\npid=%s\nppid=%s\narmed_at=t\nwindow=30\nanchor=0\nsession=sess-peer\nowner=shepherd-peer\npane=none\nfile=x\n' "$peer" "$peer" >"$WATCHERS/T-0004.status"
out=$(bash "$W" rearm T-0004 --window 30 2>"$OUT.err"); rc=$?
assert_eq "rearm over another instance's live watcher exits 9" "$rc" "9"
assert_eq "…and says ARMED-ELSEWHERE, naming the instance" "$out" "ARMED-ELSEWHERE T-0004 status=shepherd-peer"
assert_ok "…and that watcher is untouched" bash -c "kill -0 $peer 2>/dev/null"
assert_eq "…and so is its record" "$(sed -n 's/^session=//p' "$WATCHERS/T-0004.status")" "sess-peer"
assert_eq "…and nothing of this session was armed in its place" "$(bash "$W" list T-0004 | grep -c 'session=sess-me')" "0"
assert_ok "…and the reason names arm as the way to take the task over" grep -q 'shepherd-watch arm T-0004' "$OUT.err"
# The other two situations stay tellable apart: `check` answers this reader's
# own question - am I armed - and says no; `list` says whose the watcher is.
assert_eq "check counts another instance's watcher as missing for this session" "$(bash "$W" check T-0004 | grep -c '^status$')" "1"
assert_ok "list names the instance a stale record belongs to" bash -c "bash '$W' list T-0004 | grep -q '^T-0004 status stale .*owner=shepherd-peer$'"
# Refused with SHEPHERD_ID unset too: shells on this machine lose it
# mid-session, and an unknown identity is not evidence that the record is ours.
out=$(env -u SHEPHERD_ID bash "$W" rearm T-0004 --window 30 2>/dev/null); rc=$?
assert_eq "…and a reader with no SHEPHERD_ID refuses it as well" "$rc" "9"
assert_ok "…leaving that watcher alive" bash -c "kill -0 $peer 2>/dev/null"
kill "$peer" 2>/dev/null; wait "$peer" 2>/dev/null

# A live record whose owner= is empty is not evidence either way, so it takes
# the same recoverable direction: named and refused, never TERMed. Both
# directions of the empty cell are asserted, because they fail differently: a
# NAMED reader gets "" != "shepherd-test" for free from the inequality, while
# an UNSET one compares "" against "" and reads the record as its own. The
# second is the cell T-0275 fixed, and it is the likelier of the two - shells
# on this machine start without SHEPHERD_ID, so the record with no owner and
# the reader with no identity are the same condition seen twice.
bash "$SHEPHERD_ROOT/fake/shepherd-watch" & anon=$!
printf 'task=T-0004\nkind=status\npid=%s\nppid=%s\narmed_at=t\nwindow=30\nanchor=0\nsession=sess-old\nowner=\npane=none\nfile=x\n' "$anon" "$anon" >"$WATCHERS/T-0004.status"
out=$(bash "$W" rearm T-0004 --window 30 2>/dev/null); rc=$?
assert_eq "a live record with no owner is refused, not killed" "$rc" "9"
assert_eq "…and reports the owner as unknown" "$out" "ARMED-ELSEWHERE T-0004 status=unknown"
assert_ok "…and it is still alive" bash -c "kill -0 $anon 2>/dev/null"
# …and empty on BOTH sides: unknown-vs-unknown is still two unknowns, never a
# match. `timeout` bounds the regression - unfixed, this call kills the record
# and arms its own watcher in the foreground, so it hangs rather than failing.
out=$(timeout 10 env -u SHEPHERD_ID bash "$W" rearm T-0004 --window 30 2>/dev/null); rc=$?
assert_eq "…and a reader with no SHEPHERD_ID refuses it too, not owns it" "$rc" "9"
assert_eq "…still naming the owner unknown" "$out" "ARMED-ELSEWHERE T-0004 status=unknown"
assert_ok "…and it survives that reader as well" bash -c "kill -0 $anon 2>/dev/null"
assert_file "…with its record left in place" "$WATCHERS/T-0004.status"
# No "nothing of this session armed over it" here, though the named-peer case
# above asserts exactly that: under `timeout` it cannot fail. A regression TERMs
# the parent, whose cleanup removes the record it just armed, so `list` prints
# nothing either way - the assertion would pass against the broken predicate and
# measure nothing. The record surviving, one line up, is the real claim.
kill "$anon" 2>/dev/null; wait "$anon" 2>/dev/null

# A dead record (its process is gone) is simply missing.
printf 'task=T-0004\nkind=status\npid=999999\nppid=999999\narmed_at=t\nwindow=30\nanchor=0\nsession=sess-me\nowner=shepherd-test\npane=none\nfile=x\n' >"$WATCHERS/T-0004.status"
assert_ok "list marks a dead watcher dead" bash -c "bash '$W' list T-0004 | grep -q '^T-0004 status dead '"
assert_eq "check counts a dead watcher as missing" "$(bash "$W" check T-0004 | grep -c '^status$')" "1"

# A record naming a pid that is NOT a watcher must not get a TERM.
# ledger/watchers/ survives a reboot and nothing prunes a record orphaned by
# SIGKILL or a power cut; PIDs restart low afterwards, so a stale record
# routinely names some live, unrelated process. Every arm and rearm goes
# through kill_record - wake step 8 runs one at every session start - which
# made an unguarded TERM a recurring shot at a stranger.
card T-0005 none; rm -f "$(status_file T-0005)"
sleep 30 & bystander=$!
printf 'task=T-0005\nkind=status\npid=%s\nppid=%s\narmed_at=t\nwindow=30\nanchor=0\nsession=sess-old\nowner=shepherd-test\npane=none\nfile=x\n' \
  "$bystander" "$bystander" >"$WATCHERS/T-0005.status"
bash "$W" arm T-0005 status --window 1 >/dev/null 2>&1
assert_ok "arm leaves a record's non-watcher pid alone" bash -c "kill -0 $bystander 2>/dev/null"
assert_nofile "…and the stale record is cleared anyway, so it stops coming back" "$WATCHERS/T-0005.status"
printf 'task=T-0005\nkind=status\npid=%s\nppid=%s\narmed_at=t\nwindow=30\nanchor=0\nsession=sess-old\nowner=shepherd-test\npane=none\nfile=x\n' \
  "$bystander" "$bystander" >"$WATCHERS/T-0005.status"
run_bg rearm T-0005 --window 30; p=$BG; sleep 0.8
assert_ok "rearm leaves it alone too" bash -c "kill -0 $bystander 2>/dev/null"
kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
kill "$bystander" 2>/dev/null; wait "$bystander" 2>/dev/null

# --- errors are loud ---------------------------------------------------------
out=$(bash "$W" arm T-9999 2>&1); rc=$?
assert_eq "no card → exit 2" "$rc" "2"
assert_eq "no card → ERROR first" "${out%% *}" "ERROR"
out=$(bash "$W" arm not-a-task 2>&1); rc=$?
assert_eq "bad id → exit 2" "$rc" "2"
out=$(bash "$W" arm T-0001 status --window abc 2>/dev/null); rc=$?
assert_eq "a --window that is not seconds → exit 2" "$rc" "2"
assert_eq "…and ERROR first, not a silent 900 s watcher" "${out%% *}" "ERROR"
out=$(bash "$W" arm T-0001 status --window 2>/dev/null); rc=$?
assert_eq "--window with no value → exit 2" "$rc" "2"
out=$(bash "$W" arm T-0001 status --window= 2>/dev/null); rc=$?
assert_eq "an empty --window= → exit 2" "$rc" "2"
# …and a leading zero is neither an error nor an octal window. `--window 008`
# used to reach the arithmetic as octal and die with the shell's OWN exit 1 and
# an empty stdout ("008: value too great for base") - the bash-level exit this
# whole validator exists to prevent, with no verdict for monitor to read.
out=$(bash "$W" arm T-0001 status --window 008 2>"$OUT.err"); rc=$?
assert_eq "--window 008 runs its eight seconds (124), not a base error" "$rc" "124"
assert_eq "…with a verdict naming 8s, not 008s" "$out" "TIMEOUT 8s"
assert_eq "…and nothing on stderr" "$(wc -c <"$OUT.err")" "0"
out=$(bash "$W" arm 2>&1); rc=$?
assert_eq "arm with no task id → exit 2" "$rc" "2"
out=$(bash "$W" 2>/dev/null); rc=$?
assert_eq "no verb → usage, exit 2" "$rc" "2"
assert_eq "…with ERROR on stdout, so every exit 2 has a parsable verdict" "${out%% *}" "ERROR"

# --- one predicate: the anchor and the loop cannot drift (T-0090) -----------
assert_eq "wake_count is defined once" "$(grep -c '^wake_count()' "$W")" "1"
assert_ok "the anchor reads wake_count" grep -q 'anchor=\$(wake_count' "$W"
assert_ok "the loop reads wake_count" grep -q 'n=\$(wake_count' "$W"
assert_ok "no grep -c anchor anywhere" bash -c "! grep -q 'grep -c' '$W'"
assert_ok "no wc -l anchor anywhere" bash -c "! grep -q 'wc -l' '$W'"

# === the stall watcher (Task 5) ===============================================
card T-0010 w1:p9; F=$(status_file T-0010); rm -f "$F"

# herdr says blocked → 3, and the call is R5's line, unpiped.
reset_stub; verdict blocked
run_bg arm T-0010 --window 30; p=$BG
wait_rc "$p"
assert_eq "herdr blocked fires (3)" "$RC" "3"
assert_eq "…with the BLOCKED verdict" "$(first_word "$OUT")" "BLOCKED"
assert_ok "the herdr call is agent wait <pane> --until blocked --timeout <ms>" \
  bash -c "calls | grep -qE '^agent wait w1:p9 --until blocked --timeout [0-9]+\$'"
assert_ok "the timeout is the window in ms" bash -c "calls | grep -q -- '--timeout 30000'"
assert_nofile "both records are gone after the wake" "$WATCHERS/T-0010.status"
assert_nofile "…including the stall record" "$WATCHERS/T-0010.stall"

# Both armed by default: while it runs, list shows two live lines.
reset_stub
run_bg arm T-0010 --window 30; p=$BG; sleep 0.6
assert_eq "arm with no kind arms both" "$(bash "$W" list T-0010 | grep -c ' live ')" "2"
stop_line T-0010 done >>"$F"
wait_rc "$p"
assert_eq "a status fire wins and the stall child dies with it (0)" "$RC" "0"
sleep 0.3
assert_eq "no herdr process is left behind" "$(pgrep -cf "$HERDR_STUB_DIR/bin/herdr agent wait")" "0"

# The window elapses on both → 124.
reset_stub
run_bg arm T-0010 --window 1; p=$BG
wait_rc "$p"
assert_eq "window elapsed on both → 124" "$RC" "124"

# Every window deadline is measured on a MONOTONIC clock, never `date +%s`.
# Measured 2026-09-08 over one hour on w13:p16: realtime advanced 3519 s while
# /proc/uptime advanced 3600 s, and herdr's own `--timeout 3600000` returned at
# 3600.0 monotonic seconds - so a window kept in realtime is not the window
# herdr is keeping. SHEPHERD_WATCH_UPTIME is the seam: point it at a file this
# test advances and the window must end on THAT clock. On main, which reads
# `date +%s`, the jump changes nothing and the arm runs its full 20 s.
reset_stub
FAKE="$SHEPHERD_ROOT/fake-uptime"; printf '100.00 100.00\n' > "$FAKE"
SHEPHERD_WATCH_UPTIME="$FAKE" run_bg arm T-0010 status --window 20; p=$BG
started=$(date +%s)
sleep 1; printf '400.00 400.00\n' > "$FAKE"      # +300 monotonic seconds, no realtime jump
wait_rc "$p"
elapsed=$(( $(date +%s) - started ))
assert_eq "a monotonic jump past the deadline ends the window (124)" "$RC" "124"
assert_eq "…naming the window it was armed with" "$(cat "$OUT")" "TIMEOUT 20s"
assert_ok "…without waiting out the 20 s of realtime" test "$elapsed" -lt 8
rm -f "$FAKE"

# The STALL watcher measures on the same clock. Its deadline is a second
# arithmetic site (shepherd-watch's stall_watch), and a mutation reverting only that
# one would survive the status-watcher test above - so it gets its own. The
# early_timeout stub returns in 0.3 s, which is what lets the loop re-read the
# clock at all; on main the arm runs its full 20 s of realtime.
reset_stub; verdict early_timeout
FAKE="$SHEPHERD_ROOT/fake-uptime"; printf '100.00 100.00\n' > "$FAKE"
SHEPHERD_WATCH_UPTIME="$FAKE" run_bg arm T-0010 stall --window 20; p=$BG
started=$(date +%s)
sleep 1; printf '400.00 400.00\n' > "$FAKE"
wait_rc "$p"
elapsed=$(( $(date +%s) - started ))
assert_eq "the stall watcher's deadline is monotonic too (124)" "$RC" "124"
assert_ok "…ending in monotonic time, not 20 s of realtime" test "$elapsed" -lt 8
rm -f "$FAKE"

# A clock that answered at arming and stops answering is an ERROR, never a
# silent switch back to `date +%s`: uptime seconds and epoch seconds are six
# orders of magnitude apart, so a deadline taken on one and compared against
# the other fires on the first poll or never at all.
reset_stub
FAKE="$SHEPHERD_ROOT/fake-uptime"; printf '100.00 100.00\n' > "$FAKE"
SHEPHERD_WATCH_UPTIME="$FAKE" run_bg arm T-0010 status --window 30; p=$BG
sleep 0.6; printf 'not-a-clock\n' > "$FAKE"
wait_rc "$p"
assert_eq "a clock lost mid-window stops the watcher (2)" "$RC" "2"
assert_ok "…saying so, and naming the file" grep -q "ERROR the mono clock $FAKE" "$OUT"
rm -f "$FAKE"

# A herdr `timeout` short of the window it was given is HERDR's wait ending,
# not this window: shepherd-watch re-issues until its own deadline. On main the first
# early timeout returned 124 at once - one call, ~0.3 s of a 3 s arm - so the
# tail of every window went unwatched (~52-55 min of a 60 min arm, twice on
# four panes, 2026-09-02).
# The elapsed check reads /proc/uptime, the clock the watcher itself now keeps:
# bounding a monotonic window with `date +%s` made this flake at 2 of 3 s, which
# is the very drift this card measured (~2.3 % slow over an hour on this host).
mono() { u=$(cut -d' ' -f1 /proc/uptime); echo "${u%.*}"; }
reset_stub; verdict early_timeout
run_bg arm T-0010 stall --window 3; p=$BG
started=$(mono)
wait_rc "$p"
elapsed=$(( $(mono) - started ))
assert_eq "an early herdr timeout still ends 124" "$RC" "124"
assert_eq "…naming the window that was asked for" "$(cat "$OUT")" "TIMEOUT 3s"
assert_ok "…only after the window really elapsed" test "$elapsed" -ge 3
assert_ok "…having re-issued the wait rather than believing the first" \
  test "$(calls | grep -c '^agent wait w1:p9 ')" -ge 3

# …and the re-issue cannot become a busy-wait: a herdr answering `timeout` with
# no elapsed time at all is slept off for REPROBE first. REPROBE_INT is the
# CEILING of REPROBE - flooring 0.2 to 0 would switch the guard off in exactly
# the configuration these tests run under, which is how it went untested once.
# REPROBE stays this file's 0.2: the guard has to be exercised at a SUB-SECOND
# value, because that is the only place floor and ceiling differ. At 0.2 the
# guard allows ~15 re-issues across a 3 s window; without it the loop spawns a
# herdr per iteration and runs to several hundred.
reset_stub; verdict instant_timeout
run_bg arm T-0010 stall --window 3; p=$BG
wait_rc "$p"
assert_eq "an instant herdr timeout still ends 124" "$RC" "124"
assert_ok "…without spinning: the re-issues are bounded by REPROBE" \
  test "$(calls | grep -c '^agent wait w1:p9 ')" -le 40

# agent_not_found is transient (launch, detection hiccups): three probes
# ~REPROBE apart, GONE only when every probe reports no session.
reset_stub; verdict agent_not_found
run_bg arm T-0010 --window 30; p=$BG
wait_rc "$p"
assert_eq "agent_not_found confirmed by probes → GONE (5)" "$RC" "5"
assert_eq "…with the GONE verdict" "$(first_word "$OUT")" "GONE"
assert_eq "…after three pane get probes" "$(calls | grep -c '^pane get w1:p9')" "3"

# A probe that finds a session re-issues the wait instead of returning GONE.
reset_stub; verdict agent_not_found
printf '{"result":{"pane":{"agent_status":"working","agent_session":{"value":"sess-w"}}}}' >"$HERDR_STUB_DIR/pane_json"
run_bg arm T-0010 --window 2; p=$BG
wait_rc "$p"
assert_eq "agent_not_found with a live session never returns GONE" "$RC" "124"
assert_ok "…and the wait was re-issued" bash -c "[ \$(calls | grep -c '^agent wait') -ge 2 ]"

# herdr unusable → the stall child stands down, the status watcher keeps running.
reset_stub; verdict garbage
run_bg arm T-0010 --window 30; p=$BG; sleep 0.8
assert_eq "herdr unusable: the status watcher is still live" "$(bash "$W" list T-0010 | grep -c '^T-0010 status live ')" "1"
assert_eq "herdr unusable: the stall record is gone" "$(bash "$W" list T-0010 | grep -c '^T-0010 stall ')" "0"
assert_ok "herdr unusable: a STALL-UNAVAILABLE note on stderr" grep -q 'STALL-UNAVAILABLE' "$OUT.err"
stop_line T-0010 blocked >>"$F"
wait_rc "$p"
assert_eq "…and a claim still wakes (0)" "$RC" "0"

# …and when stall is the ONLY watcher armed, that rc-7 IS the arm's exit code:
# a genuine herdr outage on a stall-only re-arm must not read as a wake.
reset_stub; verdict garbage
run_bg arm T-0010 stall --window 30; p=$BG
wait_rc "$p"
assert_eq "herdr unusable on a stall-only arm exits 7" "$RC" "7"
assert_ok "…with STALL-UNAVAILABLE on stderr, not on the verdict" grep -q '^STALL-UNAVAILABLE' "$OUT.err"
assert_eq "…and nothing on stdout to mistake for a verdict" "$(wc -c <"$OUT")" "0"
assert_nofile "…and the stall record is cleaned up" "$WATCHERS/T-0010.stall"

# A TERMed herdr child is a signal, not a verdict. cleanup()'s FIRST act is
# `pkill -TERM -P` on the stall child, which takes the herdr process alone:
# `wait` then returns 128+n with an EMPTY stderr file, the verdict parse
# produced an empty code, and the catch-all announced `STALL-UNAVAILABLE
# herdr:` with no text at all - after a perfectly normal wake. Reproduced here
# the way cleanup reaches it, because the whole-cleanup path is a race the TERM
# trap usually wins.
reset_stub
card T-0013 w1:p9; rm -f "$(status_file T-0013)"
run_bg arm T-0013 stall --window 30; p=$BG; sleep 1.0
stall_pid=$(sed -n 's/^pid=//p' "$WATCHERS/T-0013.stall")
pkill -TERM -P "$stall_pid" 2>/dev/null
wait_rc "$p"
assert_eq "a TERMed herdr child exits as a signal (143), not a verdict" "$RC" "143"
assert_ok "…and raises no STALL-UNAVAILABLE note" bash -c "! grep -q 'STALL-UNAVAILABLE' '$OUT.err'"
assert_eq "…and says nothing on stdout either" "$(wc -c <"$OUT")" "0"

# rearm arms only the missing kind: a live same-session status record stays,
# only the stall watcher is started.
reset_stub; verdict blocked
sleep 60 & sl=$!
printf 'task=T-0010\nkind=status\npid=%s\nppid=%s\narmed_at=t\nwindow=30\nanchor=0\nsession=sess-me\nowner=shepherd-test\npane=w1:p9\nfile=x\n' "$sl" "$sl" >"$WATCHERS/T-0010.status"
run_bg rearm T-0010 --window 30; p=$BG
wait_rc "$p"
assert_eq "rearm with status live arms only stall, which fires (3)" "$RC" "3"
assert_ok "the live status watcher was not touched" bash -c "kill -0 $sl 2>/dev/null"
assert_file "…and its record survives" "$WATCHERS/T-0010.status"
kill "$sl" 2>/dev/null; wait "$sl" 2>/dev/null; rm -f "$WATCHERS/T-0010.status"

# pane none → the stall watcher is skipped, not an error.
card T-0011 none; rm -f "$(status_file T-0011)"; reset_stub
run_bg arm T-0011 --window 1; p=$BG
wait_rc "$p"
assert_eq "pane none: status-only arm runs to its window" "$RC" "124"
assert_ok "pane none: a STALL-SKIPPED note" grep -q 'STALL-SKIPPED' "$OUT.err"
assert_eq "pane none: herdr never called" "$(calls | wc -l)" "0"
card T-0012 claiming-shepherd-test-T-0012
assert_ok "check reports a claiming pane as unarmable" bash -c "bash '$W' check T-0012 | grep -q 'unarmable'"

# === the inbox kind (T-0237; spec 2026-09-07 §7) ================================
# shepherd-inbox is a stub reached through SHEPHERD_INBOX_SCRIPT, a seam hooks_active
# gates like the liveness overrides. It logs its argv, then exits what
# $HERDR_STUB_DIR/inbox_rc says - or holds until TERMed, so a record can be
# looked at while its watcher lives.
cat >"$HERDR_STUB_DIR/bin/shepherd-inbox" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_STUB_DIR/inbox_calls"
rc=$(cat "$HERDR_STUB_DIR/inbox_rc" 2>/dev/null)
case "$rc" in
  hold) sleep 60 & sp=$!; trap 'kill "$sp" 2>/dev/null; exit 143' TERM INT; wait "$sp"; exit 124 ;;
  '')   exit 124 ;;
  *)    echo "inbox: stub says $rc" >&2; exit "$rc" ;;
esac
STUB
chmod +x "$HERDR_STUB_DIR/bin/shepherd-inbox"
export SHEPHERD_INBOX_SCRIPT="$HERDR_STUB_DIR/bin/shepherd-inbox"
inbox_rc()    { printf '%s' "$1" >"$HERDR_STUB_DIR/inbox_rc"; }
inbox_calls() { cat "$HERDR_STUB_DIR/inbox_calls" 2>/dev/null; }
reset_inbox() { rm -f "$HERDR_STUB_DIR/inbox_calls" "$HERDR_STUB_DIR/inbox_rc"; }
IREC="$WATCHERS/inbox.shepherd-test"
# inbox_case <rc> [flags…] — arm with shepherd-inbox exiting <rc>; RC and OUT carry the result.
# A function, not a command substitution: the watcher must be a direct child of
# this shell for wait_rc to answer for it (see run_bg).
inbox_case() { reset_inbox; inbox_rc "$1"; shift; run_bg arm inbox "$@"; wait_rc "$BG"; }

# --- the five verdicts: shepherd-inbox's codes mapped, because 3 and 4 are taken here --
inbox_case 0 --window 21600
assert_eq "shepherd-inbox 0 → exit 0"                          "$RC" "0"
assert_eq "…with INBOX WORK"                             "$(head -n 1 "$OUT")" "INBOX WORK"
assert_eq "the single child is shepherd-inbox watch <window>"  "$(inbox_calls)" "watch 21600"
assert_nofile "the record is gone after the verdict"     "$IREC"
inbox_case 124 --window 21600
assert_eq "shepherd-inbox 124 → exit 124"                      "$RC" "124"
assert_eq "…with INBOX TIMEOUT naming the window"        "$(head -n 1 "$OUT")" "INBOX TIMEOUT 21600s"
inbox_case 4 --window 21600
assert_eq "shepherd-inbox 4 (unreachable ceiling) → exit 6"    "$RC" "6"
assert_eq "…with INBOX UNREACHABLE"                      "$(head -n 1 "$OUT")" "INBOX UNREACHABLE"
assert_ok "…and shepherd-inbox's own stderr line passes through" grep -q 'inbox: stub says 4' "$OUT.err"
inbox_case 3 --window 21600
assert_eq "shepherd-inbox 3 (not configured / not ours) → exit 8" "$RC" "8"
assert_eq "…with INBOX NOT-CONFIGURED"                   "$(head -n 1 "$OUT")" "INBOX NOT-CONFIGURED"
inbox_case 1 --window 21600
assert_eq "shepherd-inbox 1 (auth) → exit 1"                   "$RC" "1"
assert_eq "…with INBOX AUTH"                             "$(head -n 1 "$OUT")" "INBOX AUTH"
inbox_case 2 --window 21600
assert_eq "an unknown shepherd-inbox code → exit 2"            "$RC" "2"
assert_eq "…with ERROR first, naming the code"           "$(head -n 1 "$OUT")" "ERROR shepherd-inbox exited 2"
for c in 0 124 4 3 1 2; do
  inbox_case "$c" --window 21600
  assert_eq "shepherd-inbox $c: exactly one stdout line"       "$(wc -l <"$OUT")" "1"
done

# --- the record: per instance, seen by list and check ------------------------------
reset_inbox; inbox_rc hold
run_bg arm inbox; p=$BG; sleep 0.6
assert_file "an armed inbox watcher has the per-instance record" "$IREC"
assert_eq "arm inbox with no --window arms the six-hour window" "$(inbox_calls)" "watch 21600"
assert_eq "the record's window says so"        "$(sed -n 's/^window=//p' "$IREC")" "21600"
assert_eq "the record names the kind"          "$(sed -n 's/^kind=//p' "$IREC")" "inbox"
assert_eq "the record names the instance"      "$(sed -n 's/^owner=//p' "$IREC")" "shepherd-test"
assert_eq "the record carries the session"     "$(sed -n 's/^session=//p' "$IREC")" "sess-me"
assert_eq "the record's anchor is -: nothing is counted" "$(sed -n 's/^anchor=//p' "$IREC")" "-"
assert_ok "list shows it live, owner last" \
  bash -c "bash '$W' list inbox | grep -qE '^inbox inbox live pid=[0-9]+ window=21600 anchor=- armed=[^ ]+ session=sess-me owner=shepherd-test\$'"
assert_eq "list with no filter includes it"    "$(bash "$W" list | grep -c '^inbox inbox live ')" "1"
assert_eq "list T-NNNN excludes it"            "$(bash "$W" list T-0001 | grep -c '^inbox ')" "0"
out=$(bash "$W" check inbox); rc=$?
assert_eq "check inbox: live → 0"              "$rc" "0"
assert_eq "…and prints nothing"                "$out" ""
assert_eq "check T-NNNN never mentions the inbox" "$(bash "$W" check T-0011 2>/dev/null | grep -c inbox)" "0"
# the pid the record names answers the kill_record guard, so a replace can reach it
ipid=$(sed -n 's/^pid=//p' "$IREC")
assert_ok "the recorded pid runs this script" bash -c "tr '\0' ' ' </proc/$ipid/cmdline | grep -q 'shepherd-watch'"
kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
assert_nofile "a killed arm removes the inbox record" "$IREC"
sleep 0.3
assert_eq "…and its shepherd-inbox child died with it" "$(pgrep -cf "$HERDR_STUB_DIR/bin/shepherd-inbox watch")" "0"
out=$(bash "$W" check inbox); rc=$?
assert_eq "check inbox: nothing live → 1"      "$rc" "1"
assert_eq "…and names the missing kind"        "$out" "inbox"

# --- --window is validated for the inbox too ------------------------------------
reset_inbox; inbox_rc 0
out=$(bash "$W" arm inbox --window abc 2>/dev/null); rc=$?
assert_eq "arm inbox --window abc → exit 2"    "$rc" "2"
assert_eq "…with ERROR first"                  "${out%% *}" "ERROR"
assert_eq "…and shepherd-inbox was never run"        "$(inbox_calls | wc -l)" "0"
out=$(bash "$W" arm inbox status 2>/dev/null); rc=$?
assert_eq "arm inbox takes no kind → exit 2"   "$rc" "2"
out=$(bash "$W" arm inbox --window 0300 2>/dev/null); rc=$?
assert_eq "a leading zero is base ten for the inbox window too" "$(inbox_calls)" "watch 300"

# --- arm replaces THIS instance's watcher, and only that one --------------------------
reset_inbox; inbox_rc hold
run_bg arm inbox; p1=$BG; sleep 0.6
old=$(sed -n 's/^pid=//p' "$IREC")
# a peer instance's record, alive, must survive a replace here
mkdir -p "$SHEPHERD_ROOT/fake"
printf '#!/usr/bin/env bash\nsleep 60\n' >"$SHEPHERD_ROOT/fake/shepherd-watch"
bash "$SHEPHERD_ROOT/fake/shepherd-watch" & peer=$!
printf 'task=inbox\nkind=inbox\npid=%s\nppid=%s\narmed_at=t\nwindow=21600\nanchor=-\nsession=sess-peer\nowner=shepherd-peer\npane=none\nfile=\n' \
  "$peer" "$peer" >"$WATCHERS/inbox.shepherd-peer"
run_bg arm inbox; p2=$BG; sleep 0.8
assert_ok "arm inbox kills the previous watcher of this instance" bash -c "! kill -0 $old 2>/dev/null"
assert_eq "the replaced arm process has exited"  "$(kill -0 "$p1" 2>/dev/null && echo alive || echo gone)" "gone"
assert_eq "exactly one live inbox watcher for this instance" "$(bash "$W" list inbox | grep -c ' owner=shepherd-test$')" "1"
assert_ok "the peer instance's watcher is untouched" bash -c "kill -0 $peer 2>/dev/null"
assert_file "…and so is its record"            "$WATCHERS/inbox.shepherd-peer"
assert_eq "list shows both instances"          "$(bash "$W" list inbox | grep -c '^inbox inbox ')" "2"
kill "$p2" 2>/dev/null; wait "$p2" 2>/dev/null
kill "$peer" 2>/dev/null; wait "$peer" 2>/dev/null; rm -f "$WATCHERS/inbox.shepherd-peer"

# --- rearm: only when this session's is not live -----------------------------------
reset_inbox; inbox_rc hold
run_bg rearm inbox; p=$BG; sleep 0.6
assert_file "rearm inbox with nothing armed arms it" "$IREC"
assert_eq "…through shepherd-inbox watch"            "$(inbox_calls)" "watch 21600"
out=$(bash "$W" rearm inbox 2>"$OUT.err"); rc=$?
assert_eq "rearm inbox with this session's live → 4"  "$rc" "4"
assert_eq "…and says ARMED-ALREADY inbox"      "$out" "ARMED-ALREADY inbox"
assert_ok "…and the live watcher is untouched" bash -c "kill -0 $p 2>/dev/null"
assert_eq "…and it was not re-run"             "$(inbox_calls | wc -l)" "1"
kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
# a rolled-over session's watcher: alive, stale, replaced
bash "$SHEPHERD_ROOT/fake/shepherd-watch" & sl=$!
printf 'task=inbox\nkind=inbox\npid=%s\nppid=%s\narmed_at=t\nwindow=21600\nanchor=-\nsession=sess-old\nowner=shepherd-test\npane=none\nfile=\n' \
  "$sl" "$sl" >"$IREC"
assert_ok "list marks another session's inbox watcher stale" bash -c "bash '$W' list inbox | grep -q '^inbox inbox stale '"
assert_eq "check inbox counts a stale watcher as missing" "$(bash "$W" check inbox)" "inbox"
reset_inbox; inbox_rc hold
run_bg rearm inbox; p=$BG; sleep 0.8
assert_ok "rearm inbox kills the stale watcher"  bash -c "! kill -0 $sl 2>/dev/null"
assert_eq "…and re-arms in its place"          "$(sed -n 's/^session=//p' "$IREC")" "sess-me"
kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; kill "$sl" 2>/dev/null; wait "$sl" 2>/dev/null
# a dead record is simply missing
printf 'task=inbox\nkind=inbox\npid=999999\nppid=999999\narmed_at=t\nwindow=21600\nanchor=-\nsession=sess-me\nowner=shepherd-test\npane=none\nfile=\n' >"$IREC"
assert_ok "list marks a dead inbox watcher dead" bash -c "bash '$W' list inbox | grep -q '^inbox inbox dead '"
assert_eq "check inbox counts it missing"      "$(bash "$W" check inbox)" "inbox"
reset_inbox; inbox_rc 124
run_bg rearm inbox --window 21600; wait_rc "$BG"
assert_eq "rearm over a dead record arms, and the verdict is the child's" "$(head -n 1 "$OUT")" "INBOX TIMEOUT 21600s"

# --- no identity, no record ------------------------------------------------------------
reset_inbox; inbox_rc 0
out=$(env -u SHEPHERD_ID bash "$W" arm inbox 2>/dev/null); rc=$?
assert_eq "arm inbox without SHEPHERD_ID → exit 2"  "$rc" "2"
assert_eq "…with ERROR first"                  "${out%% *}" "ERROR"
assert_eq "…and shepherd-inbox never ran"            "$(inbox_calls | wc -l)" "0"
out=$(SHEPHERD_ID=bad_id bash "$W" check inbox 2>/dev/null); rc=$?
assert_eq "check inbox with a malformed SHEPHERD_ID → exit 2" "$rc" "2"

# --- the seam is gated: without the test hooks the real sibling script runs ----------
reset_inbox; inbox_rc 0
out=$(env -u SHEPHERD_TEST_HOOKS SHEPHERD_INBOX_ENV="$SHEPHERD_ROOT/absent.env" bash "$W" arm inbox --window 1 2>/dev/null); rc=$?
assert_eq "without SHEPHERD_TEST_HOOKS the stub is ignored: the real shepherd-inbox answers 3 → 8" "$rc" "8"
assert_eq "…and the stub was never called"     "$(inbox_calls | wc -l)" "0"

# --- the task kinds are untouched -----------------------------------------------
card T-0014 none; rm -f "$(status_file T-0014)"
reset_inbox
run_bg arm T-0014 --window 1; wait_rc "$BG"
assert_eq "a task arm still runs to its window"   "$RC" "124"
assert_eq "…and never runs shepherd-inbox"            "$(inbox_calls | wc -l)" "0"

finish
