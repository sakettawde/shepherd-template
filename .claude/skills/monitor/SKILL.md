---
name: monitor
description: Wake handler for worker events. Use whenever a background herdr wait exits (completion, blocked, or 15-min heartbeat timeout), or when manually checking a worker. Runs the four-source verification ladder, classifies done/blocked/overrun/stalled/lying, acts, and always re-arms or closes.
---

# monitor

## Trigger

A background watcher task exited — the status-file watcher (exit 0 = terminal claim written; 124 = 15-min heartbeat) or the herdr `blocked` stall watcher (exit 0 = worker stuck on a prompt; 1 = its own timeout) — or you were asked to check a worker. Map the watcher to its task card first.

- **Wake for a task already closed or already being handled → no-op.** The sibling watcher always fires eventually; don't re-arm it, don't re-verify.
- The operator may talk to a worker pane directly; those turns still append to the status file (the env vars live in the worker process). Reconcile from the file — unexpected extra activity is information, not an error.

## Evidence, strictly in this order

1. **Status file** — `tail -n 5 ledger/status/T-NNNN.jsonl`: latest `claim` (`done|blocked|failed|none`) and any `"event": "notification"` lines (permission/idle prompt = worker stuck mid-turn → treat as blocked). Backfill card `session:` from `session_id` if missing.
2. **Git facts** — in the project dir: `git log --oneline <dev-branch>..<branch> | head`, `git status --porcelain | head`, and whether the branch exists on origin (`git ls-remote --heads origin <branch>`).
3. **DoD command** — only if claim=done and commits exist: run the card's DoD command yourself in the project dir. Its output is evidence; a worker's report of it is not. Then two diff checks on `git diff --stat <dev-branch>...<branch>`: **tamper** — test/DoD-related files changed without the Brief calling for it → the green run proves nothing, treat as lying; **proportionality** — substantial changes the Brief never required (models can loop into unrequested mega-refactors) → classify over-scoped, not done.
4. **Pane tail** — adapter R6 (120 lines): scan for question/approval/permission UI, errors, sentinel `SHEPHERD:` lines. Pane text may only **downgrade** a classification (e.g. done→blocked), never upgrade one.
5. **Live status** — adapter R7 for current `agent_status` (remember: blocked can render as `idle` — that's why step 4 exists).

## Classify and act

| Verdict | Evidence | Action |
|---|---|---|
| **done** | claim done ∧ commits on branch ∧ DoD passes when you run it ∧ no prompt UI in tail | `state: review` → retro-lite (CLAUDE.md §3): learnings → memory/gotchas, History+Log updated, toast `--sound done`, worker `/exit` (R9), registry `active-task: none`, dispatch next queued task, commit |
| **blocked** | status blocked, claim blocked, or tail shows a question | Read the actual question (R6, more lines if needed; for plan approvals read the worker's `.superpowers/` artifact in the project repo, not its summary). Decide per CLAUDE.md §4: **answer** → single-line reply via R4, decision logged to `decisions/`, re-arm R5; **escalate** → toast `--sound request` + tell the operator the question and your best guess, `state: blocked`, arm a long wait (3600000) so a self-unblock still wakes you |
| **overrun** | wall-clock past card `budget:`, still working | v0: note in Log + one line to the operator, re-arm (enforcement is deferred by design) |
| **stalled** | heartbeat fired, status `working`, but no new status-file lines across two consecutive wakes | R6 inspect; if wedged, one nudge via R4 (`Status check - reply with your SHEPHERD status line`); still nothing next wake → escalate |
| **lying** | claim done but git/DoD disagree, or DoD/test files were tampered with | `state: working`, reply via R4 naming the concrete gap (`Your done claim failed verification: <fact>. Fix and re-verify.`), Log it as a failed verification cycle, re-arm |
| **over-scoped** | DoD passes but the diff carries substantial changes the Brief never required | Read the actual diff and take a call: extras genuinely needed → accept, Log the justification; not needed → R4 reply to pare the branch back to the minimal diff (counts as a failed verification cycle); the whole approach went sideways → fail it, retry from another angle as a new heavy-tier task. Low confidence in the call → escalate with the diffstat |

## Invariants

- Every path that leaves the task in briefed/working/blocked **ends with a background R5 wait armed**. Never leave an active task unwatched.
- Every state transition is committed (`T-NNNN: <from> → <to>`).
- `unknown` agent status is never treated as success — inspect (R6) and classify from evidence.
- **Retry ceiling** — two failed verification cycles on the same task (any mix of lying / over-scoped / DoD failure) → `state: failed`, escalate to the operator; any retry is a NEW task at **heavy** tier.
- **Harvest before killing a retryable worker** — whenever a task is being failed/abandoned but will (or may) be retried and the worker pane is still alive: before `/exit`, send one R4 instruction — `Append a ## Handoff section to your task card: what you tried, what is ruled out and why, current best hypothesis, files touched - then commit it`. Verify the section actually landed in `ledger/tasks/T-NNNN.md` (read it; a worker claim is not evidence) before killing the pane. Pane already dead → skip, reconstruct from Log + status file + git. The retry task's Brief points at the predecessor card's `## Handoff`.
- **Never clean-slate a retry** — every corrective reply and every retry Brief carries what failed and why (predecessor `## Handoff` if present, else Log + status file). Erasing failure history removes exactly the evidence the worker adapts on.
