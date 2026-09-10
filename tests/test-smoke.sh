#!/usr/bin/env bash
# Probe for shepherd-smoke — the dispatch → hook → watcher canary the adapter's
# regeneration procedure cites (step 6). Everything here is --dry-run: herdr is a
# shell function inside the script and claude is never launched, but the Stop hook
# is the REAL hooks/worker-stop.sh, so the fields `verify` reads are hook-written.
# Asserted: the happy path passes 7/7 and cleans up; the canary FAILS when the
# worker claims nothing, when it lies, and when a retire guard refuses — a canary
# that cannot fail proves nothing; the trust-dialog path is exercised; and outside
# herdr the live form refuses before calling anything.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
SMOKE="$HERE/../bin/shepherd-smoke"
ROOT=$(cd "$HERE/.." && pwd)

echo "test-smoke:"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is available" "python3 not found"
  finish; exit
fi

# MANDATORY: a worker running this inherits the live instance's HERDR_ENV,
# HERDR_PANE_ID and SHEPHERD_* — the live gate must not pass here, and no hook
# may write a live file. TMPDIR is redirected so the temp dirs are observable.
unset HERDR_ENV HERDR_PANE_ID SHEPHERD_TASK_ID SHEPHERD_STATUS_FILE SHEPHERD_SMOKE_SCENARIO
export TMPDIR="$SHEPHERD_ROOT/tmp"; mkdir -p "$TMPDIR"
export HOME="$SHEPHERD_ROOT/home"; mkdir -p "$HOME/.claude"

# run [scenario] — a dry run with short windows; OUT and RC hold the result
run() {
  OUT=$(SHEPHERD_SMOKE_SCENARIO="${1:-pass}" SMOKE_WAIT=2 SMOKE_READY=3 bash "$SMOKE" --dry-run 2>&1); RC=$?
}
# step <name> — PASS|FAIL|SKIP for that step
step() { printf '%s\n' "$OUT" | grep -E "^smoke: (PASS|FAIL|SKIP) $1 " | awk '{print $2}'; }
kept() { ls -d "$TMPDIR"/shepherd-smoke.* 2>/dev/null | wc -l; }

# === the happy path =========================================================
run pass
assert_eq "dry-run exits 0" "$RC" "0"
for s in gate pane launch kickoff claim verify retire; do
  assert_eq "step $s passes" "$(step "$s")" "PASS"
done
assert_ok "the summary counts 7/7" grep -q '^smoke: PASS 7/7 (dry-run)$' <<<"$OUT"
assert_ok "verify read the hook-written session" grep -q 'PASS verify .*session dry-' <<<"$OUT"
assert_ok "verify ran the DoD itself" grep -q 'PASS verify .*smoke-ok.txt reads ok' <<<"$OUT"
assert_ok "the pane was closed" grep -q 'PASS retire .*pane wD:p9 closed' <<<"$OUT"
# R9's tab guard: the retire reads pane_count before closing, and says what
# happened to the tab. The stub answers 1, so the tab goes with the pane.
assert_ok "…and the tab went with it" grep -q 'PASS retire .*tab wD:t9 with it' <<<"$OUT"
assert_ok "retire reads the tab's pane_count before closing" \
  bash -c 'sed -n "/^step_retire()/,/^}/p" "$1" | grep -q "herdr tab get"' _ "$SMOKE"
assert_eq "the temp dir is removed on PASS" "$(kept)" "0"
assert_eq "nothing landed in the repo's ledger" "$(ls "$ROOT/ledger/status" 2>/dev/null | grep -c SMOKE)" "0"

# === the trust-folder dialog is answered ====================================
run trust-dialog
assert_eq "trust dialog: still passes" "$RC" "0"
assert_ok "trust dialog: launch says it answered it" grep -q 'PASS launch .*trust dialog answered' <<<"$OUT"

# === the worker claims nothing: the R5 window expires =======================
run no-claim
assert_eq "no claim: exits 1" "$RC" "1"
assert_eq "no claim: fails at claim" "$(step claim)" "FAIL"
assert_ok "no claim: the recorded claim is shown" grep -q "FAIL claim .*claim: 'none'" <<<"$OUT"
assert_eq "no claim: verify is skipped" "$(step verify)" "SKIP"
assert_eq "no claim: the idle pane is still retired" "$(step retire)" "PASS"
assert_ok "no claim: the temp dir is kept and named" grep -q 'FAIL 1/7 failed at claim — kept .*shepherd-smoke' <<<"$OUT"
assert_eq "no claim: the kept dir exists" "$(kept)" "1"
rm -rf "$TMPDIR"/shepherd-smoke.*

# === the worker lies: claims done, wrote nothing =============================
run no-file
assert_eq "lying worker: exits 1" "$RC" "1"
assert_eq "lying worker: the claim step passes (the claim did land)" "$(step claim)" "PASS"
assert_eq "lying worker: verify fails" "$(step verify)" "FAIL"
assert_ok "lying worker: verify names the missing file" grep -q 'FAIL verify .*smoke-ok.txt missing' <<<"$OUT"
rm -rf "$TMPDIR"/shepherd-smoke.*

# === a retire guard refuses ================================================
run pane-focused
assert_eq "focused pane: exits 1" "$RC" "1"
assert_eq "focused pane: retire fails" "$(step retire)" "FAIL"
assert_ok "focused pane: the guard is named and the pane left open" grep -q 'FAIL retire .*focused.*left open' <<<"$OUT"
rm -rf "$TMPDIR"/shepherd-smoke.*

# === outside herdr, the live form refuses before touching anything ==========
BIN="$SHEPHERD_ROOT/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls"\n' "$SHEPHERD_ROOT" > "$BIN/herdr"; chmod +x "$BIN/herdr"
OUT=$(PATH="$BIN:$PATH" HERDR_ENV= bash "$SMOKE" 2>&1); RC=$?
assert_eq "the live form outside herdr exits 1" "$RC" "1"
assert_ok "and says NOT-INSIDE-HERDR" grep -q 'NOT-INSIDE-HERDR' <<<"$OUT"
assert_nofile "and called herdr not once" "$SHEPHERD_ROOT/calls"
assert_eq "and left no temp dir" "$(kept)" "0"

# === structure ==============================================================
assert_fail "an unknown flag is refused" bash "$SMOKE" --nope
assert_ok "--help prints the usage" bash -c 'bash "$1" --help | grep -q -- "--dry-run"' _ "$SMOKE"
assert_ok "every herdr verb used is one the 0.8.2 reference documents" bash -c '
  ref="$1/skills/herdr-adapter/references/v0.8.2.md"
  for v in "tab create" "tab get" "pane rename" "pane run" "pane get" "pane read" "pane send-keys" "pane close" "agent wait" "agent prompt"; do
    grep -qF "herdr $v" "$ref" || { echo "$v not in reference"; exit 1; }
  done' _ "$ROOT"
assert_fail "the task line sent through the pane carries no double quote" \
  bash -c 'grep -E "^TASK_LINE=" "$1" | sed "s/^TASK_LINE=.//; s/.$//" | grep -q "\""' _ "$SMOKE"

# === the registration race, measured live from main on 2026-09-02 ==========
# The live canary failed 1/7 at kickoff: launch passed with the agent idle after
# 3s, then `agent prompt` answered agent_not_found. herdr screen-detects an agent
# (publishing `agent`) SECONDS BEFORE it registers the session that `agent prompt`
# addresses. Waiting on `agent` alone was a race the canary lost on a fast
# machine, and it blamed the dispatch path for herdr's own lag. Two defences are
# asserted here: the launch step waits for agent_session, and the kickoff step
# retries agent_not_found before believing it.
SMOKE_KICKOFF_BACKOFF=1 run agent-lag
assert_eq "a registration lag still reaches 7/7" "$RC" "0"
assert_eq "lag: launch passes" "$(step launch)" "PASS"
assert_ok "lag: launch waited for registration, and says how long" \
  grep -qE 'PASS launch .*registered after [0-9]+s' <<<"$OUT"
assert_eq "lag: kickoff passes" "$(step kickoff)" "PASS"
assert_ok "lag: kickoff names the retry that worked" \
  grep -q 'PASS kickoff .*on attempt 2 after agent_not_found' <<<"$OUT"
rm -rf "$TMPDIR"/shepherd-smoke.*

# Registration that never arrives must give up at LAUNCH — never prompt a pane
# herdr cannot address — and name both fields it read.
SMOKE_REGISTER=3 run never-registers
assert_eq "no registration: exits 1" "$RC" "1"
assert_eq "no registration: fails at launch, not kickoff" "$(step launch)" "FAIL"
assert_eq "no registration: kickoff is skipped" "$(step kickoff)" "SKIP"
assert_ok "no registration: the diagnostic names agent and agent_session" \
  grep -q 'FAIL launch .*agent=claude, agent_session=None' <<<"$OUT"
rm -rf "$TMPDIR"/shepherd-smoke.*

# Registered but never addressable: the retries must run out and FAIL, not loop
# forever and not report success.
SMOKE_KICKOFF_BACKOFF=1 run agent-unaddressable
assert_eq "unaddressable agent: exits 1" "$RC" "1"
assert_eq "unaddressable agent: fails at kickoff" "$(step kickoff)" "FAIL"
assert_ok "unaddressable agent: the give-up counts its attempts" \
  grep -qE 'FAIL kickoff .*agent_not_found after 3 attempt\(s\)' <<<"$OUT"
assert_eq "unaddressable agent: the idle pane is still retired" "$(step retire)" "PASS"
rm -rf "$TMPDIR"/shepherd-smoke.*

# Structural: the launch gate must read agent_session, not just agent. A future
# edit that drops back to detection-only would pass every behavioural case above
# on a machine where herdr happens to be fast.
assert_ok "the launch gate waits on agent_session" \
  bash -c 'sed -n "/^await_registered()/,/^}/p" "$1" | grep -q "agent_session.value"' _ "$SMOKE"
assert_ok "step_launch calls the registration gate" \
  bash -c 'sed -n "/^step_launch()/,/^}/p" "$1" | grep -q await_registered' _ "$SMOKE"
assert_ok "the kickoff retries agent_not_found" \
  bash -c 'sed -n "/^step_kickoff()/,/^}/p" "$1" | grep -q SMOKE_KICKOFF_TRIES' _ "$SMOKE"


# === the trust dialog, round two of the live findings (2026-09-02) =========
# A brand-new directory raises Claude Code's folder-trust prompt, and herdr
# publishes NO agent_session while it is up. The registration gate therefore sat
# through its whole budget staring at an unanswered dialog, failed launch, and
# retire then REFUSED the pane because it read blocked — leaving the canary's own
# pane open for the operator to close by hand. Three properties are asserted:
# the dialog is polled for rather than answered on a fixed delay, registration is
# only read once no dialog is showing, and retire clears its own pane's dialog.

# A dialog that appears two polls in — the case a fixed-delay answer misses.
run late-dialog
assert_eq "a late dialog still reaches 7/7" "$RC" "0"
assert_eq "late dialog: launch passes" "$(step launch)" "PASS"
assert_ok "late dialog: launch says it answered it" \
  grep -q 'PASS launch .*(trust dialog answered)' <<<"$OUT"
assert_ok "late dialog: registration is still reported" \
  grep -qE 'PASS launch .*registered after [0-9]+s' <<<"$OUT"
assert_eq "late dialog: the pane is retired" "$(step retire)" "PASS"
rm -rf "$TMPDIR"/shepherd-smoke.*

# A dialog Enter will not dismiss: launch must fail, and retire must STILL close
# the pane — the canary never leaves one behind.
SMOKE_REGISTER=4 run dialog-left-open
assert_eq "a stuck dialog exits 1" "$RC" "1"
assert_eq "stuck dialog: launch fails" "$(step launch)" "FAIL"
assert_ok "stuck dialog: the diagnostic names the dialog, not a missing session" \
  grep -q 'FAIL launch .*folder-trust dialog is still on screen' <<<"$OUT"
assert_eq "stuck dialog: retire STILL closes the pane" "$(step retire)" "PASS"
assert_ok "stuck dialog: retire says it cleared the dialog first" \
  grep -q 'PASS retire .*after clearing the trust dialog' <<<"$OUT"
# A failing run keeps its temp dir, and the stub's call log is inside it — so what the
# canary actually SENT is checkable here, not merely what it reported.
KEPT=$(grep -oE 'kept [^ ]+' <<<"$OUT" | head -1 | cut -d' ' -f2)
assert_ok "stuck dialog: the failing run kept its temp dir" test -d "$KEPT"
assert_ok "stuck dialog: retire sent Escape to clear it" \
  grep -q 'pane send-keys wD:p9 Escape' "$KEPT/stub/calls"
assert_ok "stuck dialog: the pane was actually closed" \
  grep -q 'pane close wD:p9' "$KEPT/stub/calls"
rm -rf "$TMPDIR"/shepherd-smoke.*

# Structural, because both defects passed every behavioural test on a machine
# where the dialog happened not to appear.
assert_ok "the launch gate polls for the dialog every iteration" \
  bash -c 'sed -n "/^await_registered()/,/^}/p" "$1" | grep -q trust_dialog_showing' _ "$SMOKE"
assert_ok "retire clears its own pane's dialog before judging the guard" \
  bash -c 'sed -n "/^step_retire()/,/^}/p" "$1" | grep -q trust_dialog_showing' _ "$SMOKE"
assert_ok "retire re-reads the state after Escape rather than assuming it" \
  bash -c 'sed -n "/^step_retire()/,/^}/p" "$1" | grep -A3 "send-keys .* Escape" | grep -q "agent_status"' _ "$SMOKE"
assert_ok "one dialog matcher serves both, so they cannot disagree" \
  bash -c 'grep -c "^trust_dialog_showing()" "$1" | grep -q "^1$"' _ "$SMOKE"

# === the dialog's DEFAULT OPTION, round three of the live findings ==========
# The adapter's Gotchas said "1. Yes, I trust this folder is pre-highlighted, so
# Enter clears it", and this script believed it. Measured 2026-09-02: the caret
# defaults to "No, exit". The bare Enter CONFIRMED THE EXIT — Claude quit, the
# pane fell back to a bash prompt with no agent and no session, the gate timed
# out against a dead pane, and retire refused it as unknown and left it open.
# The canary must therefore select before it confirms, refuse to confirm what it
# cannot verify, and adopt its own dead pane.

# The measured default: the caret starts on "No, exit" and must be moved.
run wrong-default-option
assert_eq "the wrong default still reaches 7/7" "$RC" "0"
assert_eq "wrong default: launch passes" "$(step launch)" "PASS"
assert_ok "wrong default: launch reports answering the dialog" \
  grep -q 'PASS launch .*(trust dialog answered)' <<<"$OUT"
assert_eq "wrong default: the worker actually ran, so verify passes" "$(step verify)" "PASS"
rm -rf "$TMPDIR"/shepherd-smoke.*

# A caret that will not move: REFUSE to confirm. Confirming the default is the
# whole defect, so guessing here would reintroduce it.
run caret-stuck
assert_eq "an unmovable caret exits 1" "$RC" "1"
assert_eq "caret stuck: launch fails" "$(step launch)" "FAIL"
assert_ok "caret stuck: the refusal says why it did not press Enter" \
  grep -q "FAIL launch .*refused to confirm an unverified option" <<<"$OUT"
assert_ok "caret stuck: and names the default that made it dangerous" \
  grep -q "FAIL launch .*defaults to 'No, exit'" <<<"$OUT"
KEPT=$(grep -oE 'kept [^ ]+' <<<"$OUT" | head -1 | cut -d' ' -f2)
assert_fail "caret stuck: no Enter was ever sent" \
  grep -q 'pane send-keys wD:p9 Enter' "$KEPT/stub/calls"
assert_ok "caret stuck: it did try to move the caret first" \
  grep -q 'pane send-keys wD:p9 Down' "$KEPT/stub/calls"
assert_eq "caret stuck: the pane is still retired" "$(step retire)" "PASS"
rm -rf "$TMPDIR"/shepherd-smoke.*

# Claude exits anyway: fail FAST naming the exit, and close the dead pane.
run claude-exited
assert_eq "a dead worker exits 1" "$RC" "1"
assert_eq "claude exited: launch fails" "$(step launch)" "FAIL"
assert_ok "claude exited: the diagnostic says the worker is gone" \
  grep -q 'FAIL launch .*claude exited and left a shell' <<<"$OUT"
assert_fail "claude exited: it is NOT reported as a slow herdr" \
  grep -q 'FAIL launch .*never registered an agent' <<<"$OUT"
assert_eq "claude exited: retire adopts the canary's own dead pane" "$(step retire)" "PASS"
assert_ok "claude exited: retire says why it closed an unclassified pane" \
  grep -q 'PASS retire .*no agent and a shell prompt' <<<"$OUT"
KEPT=$(grep -oE 'kept [^ ]+' <<<"$OUT" | head -1 | cut -d' ' -f2)
assert_ok "claude exited: the pane was actually closed" \
  grep -q 'pane close wD:p9' "$KEPT/stub/calls"
rm -rf "$TMPDIR"/shepherd-smoke.*

# Structural: the two properties that stop this recurring.
assert_ok "the canary verifies the caret before confirming" \
  bash -c 'sed -n "/^select_trust_yes()/,/^}/p" "$1" | grep -q trust_yes_selected' _ "$SMOKE"
assert_fail "select_trust_yes never sends Enter itself" \
  bash -c 'sed -n "/^select_trust_yes()/,/^}/p" "$1" | grep -q "send-keys .* Enter"' _ "$SMOKE"
assert_ok "the gate only confirms once selection is verified" \
  bash -c 'sed -n "/^await_registered()/,/^}/p" "$1" | grep -A2 "if select_trust_yes" | grep -q "send-keys .* Enter"' _ "$SMOKE"
assert_ok "retire treats an agentless shell pane as its own dead pane" \
  bash -c 'sed -n "/^step_retire()/,/^}/p" "$1" | grep -q shell_prompt_showing' _ "$SMOKE"

# The reference that misled this script is corrected, so the next reader is not
# told the opposite of what was measured.
assert_ok "the adapter reference records the measured default" \
  grep -q 'caret defaults to .2. No, exit' "$HERE/../skills/herdr-adapter/references/v0.8.2.md"
assert_fail "and no longer claims the accepting option is pre-highlighted" \
  grep -q 'Yes, I trust this folder` is pre-highlighted' "$HERE/../skills/herdr-adapter/references/v0.8.2.md"

finish
