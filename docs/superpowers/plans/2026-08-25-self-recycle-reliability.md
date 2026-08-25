# Self-Recycle Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild shepherd's `/clear` → recovery path so that it either completes unattended or reports its failure to the operator within a minute, never neither.

**Architecture:** Replace the `agent_status == idle` gate — measured unreachable for a shepherd pane, and inverted in the bash-mode failure case — with a positive gate on the Claude **session id** that herdr already exposes at `pane get → result.pane.agent_session.value`. `scripts/self-recycle.sh` gains two subcommands: `recycle` (preflight, arm, submit `/clear`) and `watch` (the detached watchdog: confirm the clear by session-id change, prompt, verify against the new session's transcript). Every poll and every exit path writes a timestamped line to one log file; every give-up also raises a herdr toast.

**Tech Stack:** bash 5, `scripts/lib/shepherd-common.sh` (`pane_probe`, `hooks_active`), herdr 0.8.2 CLI, `scripts/tests/harness.sh` assert harness, python3 for JSON.

**Spec:** `docs/specs/self-recycle-design.md`

## Global Constraints

- Branch `task/T-0166-self-recycle-reliability` off the latest `main`. Never merge or push `main`.
- DoD command: `bash scripts/tests/run.sh` must print `ALL TESTS PASSED`.
- `ctx`, `decide` and `meter` are **out of scope** and must keep their current behaviour and output format.
- The script writes no ledger, registry or decision state, and takes no lock.
- Test hooks that fabricate herdr answers stay gated on `SHEPHERD_TEST_HOOKS=1` via `hooks_active`, matching `scripts/lib/shepherd-common.sh`.
- Log file: `${SHEPHERD_RECYCLE_LOG:-$HOME/.claude/shepherd-recycle.log}`, appended, never truncated, ISO-8601 timestamps.
- Toast sound: `--sound` flag, default `request`, `SHEPHERD_RECYCLE_SOUND` overrides the default. The script never parses the Operator block.
- Never byte-copy instance personalisation (paths, ids, allow-rules) into the template.

---

### Task 1: The `watch` watchdog and its probe

**Files:**
- Modify: `scripts/self-recycle.sh` (replace the `inject` subcommand)
- Test: `scripts/tests/test-recycle.sh` (create)

**Interfaces:**
- Consumes: `pane_probe <pane>` from `scripts/lib/shepherd-common.sh` — prints the Claude session id on stdout, exit 0; exit 1 = definitively no session; exit 2 = unresolved. `hooks_active` — exit 0 when `SHEPHERD_TEST_HOOKS=1`.
- Produces:
  - `self-recycle.sh watch <pane> <old-sid> <message> [--sound S] [--log F]` — exit 0 recovered, 3 clear never landed, 4 prompt never verified, 2 usage/precondition error.
  - `self-recycle.sh recycle <message> [--pane P] [--sound S] [--log F]` — exit 0 armed and `/clear` submitted, 2 preflight refused.
  - Log line format: `<iso8601> <PHASE> <detail>` where PHASE is one of `ARM POLL CLEAR-CONFIRMED SETTLE PROMPT-SENT VERIFIED GIVE-UP REFUSED`.
  - Tunables, all env, all with defaults: `SHEPHERD_RECYCLE_POLL` (2), `SHEPHERD_RECYCLE_CLEAR_TIMEOUT` (120), `SHEPHERD_RECYCLE_SETTLE` (5), `SHEPHERD_RECYCLE_ATTEMPTS` (3), `SHEPHERD_RECYCLE_VERIFY` (25), `SHEPHERD_RECYCLE_PROJECTS` (`$HOME/.claude/projects`).

- [ ] **Step 1: Write the failing test for the give-up path**

Add to `scripts/tests/test-recycle.sh`. A stub `herdr` on `PATH` records its calls and never changes the session id, so phase 1 must time out:

```bash
stub_herdr() {                      # writes a fake herdr into $BIN
  cat > "$BIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_CALLS"
case "$1 $2" in
  "pane get")   printf '{"result":{"pane":{"agent_status":"working","agent_session":{"value":"%s"}}}}\n' "$(cat "$SID_FILE")" ;;
  "pane read")  printf '❯\n' ;;
  "agent prompt") printf '{"result":{"type":"agent_prompted"}}\n' ;;
  *) : ;;
esac
SH
  chmod +x "$BIN/herdr"
}

echo "SID-OLD" > "$SID_FILE"
SHEPHERD_RECYCLE_CLEAR_TIMEOUT=4 SHEPHERD_RECYCLE_POLL=1 \
  bash "$SCRIPT" watch w1:p1 SID-OLD "recovery line" --log "$LOG" >/dev/null 2>&1
assert_eq "clear that never lands exits 3" "$?" "3"
assert_ok "give-up is logged" grep -q 'GIVE-UP' "$LOG"
assert_ok "the poll trail is logged" grep -q 'POLL' "$LOG"
assert_ok "give-up raises a toast" grep -q 'notification show' "$HERDR_CALLS"
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `bash scripts/tests/test-recycle.sh`
Expected: FAIL — `unknown cmd: watch`.

- [ ] **Step 3: Implement `watch` phase 1 and the logging/toast helpers**

In `scripts/self-recycle.sh`, source the shared library and add:

```bash
. "$here/scripts/lib/shepherd-common.sh"

RECYCLE_LOG=${SHEPHERD_RECYCLE_LOG:-$HOME/.claude/shepherd-recycle.log}
rlog() { mkdir -p "$(dirname "$RECYCLE_LOG")" 2>/dev/null; printf '%s %s %s\n' "$(date -Iseconds)" "$1" "$2" >> "$RECYCLE_LOG"; }
rtoast() {  # <title> <body>
  [ "$SOUND" = none ] && herdr notification show "$1" --body "$2" >/dev/null 2>&1 \
                      || herdr notification show "$1" --body "$2" --sound "$SOUND" >/dev/null 2>&1
  return 0
}
```

Phase 1 polls `pane_probe` until the id differs or the deadline passes, logging each poll,
then logs `GIVE-UP` and toasts and exits 3.

- [ ] **Step 4: Run the test and confirm it passes**

Run: `bash scripts/tests/test-recycle.sh`
Expected: PASS for all four assertions.

- [ ] **Step 5: Write the failing test for the happy path**

The stub flips the session id after two polls and appends the message to a fake transcript
when `agent prompt` is called:

```bash
assert_eq "a landed clear plus a verified prompt exits 0" "$?" "0"
assert_ok "the clear is logged as confirmed" grep -q 'CLEAR-CONFIRMED' "$LOG"
assert_ok "the prompt is logged as sent"    grep -q 'PROMPT-SENT' "$LOG"
assert_ok "the prompt is logged as verified" grep -q 'VERIFIED' "$LOG"
```

- [ ] **Step 6: Implement phases 2 and 3**

Settle, then up to `ATTEMPTS` rounds of: force prompt mode, `agent prompt`, then poll up to
`VERIFY` s for the message inside `$SHEPHERD_RECYCLE_PROJECTS/*/<new-sid>.jsonl`. Exhausted →
log `GIVE-UP`, toast, exit 4.

- [ ] **Step 7: Run the full file and commit**

```bash
bash scripts/tests/run.sh
git add scripts/self-recycle.sh scripts/tests/test-recycle.sh
git commit -m "T-0166: self-recycle watchdog gates on the session id, never on idle"
```

---

### Task 2: The `recycle` preflight, including bash mode

**Files:**
- Modify: `scripts/self-recycle.sh`
- Test: `scripts/tests/test-recycle.sh`

**Interfaces:**
- Consumes: everything Task 1 produced.
- Produces: `prompt_mode_ok <pane>` — sends `Escape`, re-reads the prompt box, exit 0 when the box body is a bare `❯`, exit 1 otherwise.

- [ ] **Step 1: Write the failing tests for preflight**

```bash
# a box stuck in bash mode must refuse, loudly, and submit no /clear
assert_eq "a box stuck in bash mode refuses" "$?" "2"
assert_ok "the refusal is logged" grep -q 'REFUSED' "$LOG"
assert_ok "the refusal toasts" grep -q 'notification show' "$HERDR_CALLS"
assert_fail "no /clear was submitted" grep -q 'agent prompt w1:p1 /clear' "$HERDR_CALLS"
# a box that comes clean after Escape proceeds
assert_ok "Escape is sent before the box is re-read" grep -q 'send-keys w1:p1 Escape' "$HERDR_CALLS"
assert_ok "/clear is submitted once the box is clean" grep -q '/clear' "$HERDR_CALLS"
assert_ok "arming is logged" grep -q 'ARM' "$LOG"
```

- [ ] **Step 2: Run and confirm it fails**

Run: `bash scripts/tests/test-recycle.sh`
Expected: FAIL — `unknown cmd: recycle`.

- [ ] **Step 3: Implement `recycle`**

Resolve `S0` via `pane_probe` (abort 2 if none); refuse if `agent_status` is `blocked`;
`prompt_mode_ok`; arm `watch` with `setsid nohup`; submit `/clear` via `agent prompt`.

- [ ] **Step 4: Run and confirm it passes**

Run: `bash scripts/tests/test-recycle.sh`

- [ ] **Step 5: Add the no-silent-exit test**

Assert that every `exit` in the script is preceded by a log call, by reading the source:

```bash
# every exit path in watch/recycle logs first — read from the source, so a future
# edit that adds a silent exit fails this test
silent=$(awk '/^(watch|recycle)\)/,/^;;$/' "$SCRIPT" | grep -n 'exit [0-9]' | wc -l)
logged=$(awk '/^(watch|recycle)\)/,/^;;$/' "$SCRIPT" | grep -c 'rlog ')
assert_ok "each exit path has at least one log call" test "$logged" -ge "$silent"
```

- [ ] **Step 6: Commit**

```bash
git add scripts/self-recycle.sh scripts/tests/test-recycle.sh
git commit -m "T-0166: recycle preflight forces prompt mode and refuses loudly"
```

---

### Task 3: Documentation — R10, the Gotchas, and CLAUDE.md §8

**Files:**
- Modify: `.claude/skills/herdr-adapter/references/v0.8.2.md` (R10 and the bash-mode Gotcha)
- Modify: `CLAUDE.md` (§8, the recycle bullet and session-start step 10)

**Interfaces:**
- Consumes: the subcommands and exit codes from Tasks 1 and 2.
- Produces: nothing code depends on.

- [ ] **Step 1: Rewrite R10's recycle sequence**

Replace steps 2–5 with the single `scripts/self-recycle.sh recycle "<message>"` call, name the
log file, name the exit codes, and correct the "background Bash watchers do NOT survive /clear"
known-fact line with the measurement from the spec.

- [ ] **Step 2: Supersede the bash-mode Gotcha**

Keep the incident, but replace the manual mitigation list with: the preflight forces and
verifies prompt mode, and the session-id gate catches a swallowed `/clear` regardless. Record
the measured inversion — bash mode makes the pane read `idle`.

- [ ] **Step 3: Update CLAUDE.md §8**

The context-check bullet points at `recycle`, not at the old arm-then-clear dance. Session-start
step 10 also reports the tail of the recycle log, so a give-up reaches the operator.

- [ ] **Step 4: Run the docs test and the full suite**

Run: `bash scripts/tests/run.sh`
Expected: `ALL TESTS PASSED` — `test-docs.sh` checks doc invariants.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md .claude/skills/herdr-adapter/references/v0.8.2.md docs/
git commit -m "T-0166: R10 and CLAUDE.md section 8 describe the session-id gate"
```

---

### Task 4: Live end-to-end validation and push

**Files:** none modified.

- [ ] **Step 1: Run a real recycle in a pane created for the purpose**

Create a pane, launch Claude, start a background shell so the pane reads `working`, then run
`scripts/self-recycle.sh recycle` against it and confirm from the log that the sequence reached
`VERIFIED` unattended.

- [ ] **Step 2: Force the failure path live**

Put the box in bash mode and confirm the watchdog gives up with exit 3, a `GIVE-UP` log line and
a toast.

- [ ] **Step 3: Close the experiment pane and push**

```bash
bash scripts/tests/run.sh
git push -u origin task/T-0166-self-recycle-reliability
```

---

## Self-Review

**Spec coverage:** §6 design → Tasks 1 and 2. §3 and §4 measurements → Task 3 documentation.
Logging and toast requirements → Task 1 Step 3 and Task 2 Step 5. Live canary → Task 4.
Out-of-scope items (`ctx`/`decide`/`meter`, the accumulating-shells finding) are recorded in the
spec and deliberately carry no task.

**Placeholder scan:** none — every step names its file, command and expected result.

**Type consistency:** `pane_probe`, `rlog`, `rtoast`, `prompt_mode_ok`, and the eight log phases
are used with the same names in every task.
