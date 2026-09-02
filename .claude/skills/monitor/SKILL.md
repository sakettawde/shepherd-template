---
name: monitor
description: Wake handler for worker events. Use whenever a background herdr wait exits (completion, blocked, or heartbeat timeout (30m S/M, 60m L/heavy)), or when manually checking a worker. Runs the four-source verification ladder, classifies done/blocked/overrun/stalled/lying, acts, and always re-arms or closes.
---

# monitor

## Trigger

**Ownership gate — run this before anything else.** Re-read `owner:` from the task card on disk. If it is not your `SHEPHERD_ID`, stand down silently: no verification, no reply, no re-arm, no commit. The card was reassigned (CLAUDE.md §4a) and its new owner is watching it. This check is what makes reassignment safe against a previous owner that wakes up late. **A card with no `owner:` line reads as `shepherd-1`** (CLAUDE.md §2 rule 10) — a card written before the field existed would otherwise be watched by nobody at all.

A background watcher task exited — the status-file watcher (exit 0 = terminal claim written; 124 = heartbeat backstop — 30m S/M, 60m L/heavy per adapter R5) or the herdr `blocked` stall watcher (exit 0 = worker stuck on a prompt; 1 = its own timeout) — or you were asked to check a worker. Map the watcher to its task card first.

The **inbox watcher** (`scripts/inbox.sh watch`) is the third, and has no card to map: exit 0 means Linear has work — run `## Inbox drain` below instead of the verification ladder, which is about workers and has nothing to say about an inbox event. Exit 124 → re-arm and stop. Exit 1 or 3 → report, do not re-arm.

- **Wake for a task already closed or already being handled → no-op.** The sibling watcher always fires eventually; don't re-arm it, don't re-verify.
- The operator may talk to a worker pane directly; those turns still append to the status file (the env vars live in the worker process). Reconcile from the file — unexpected extra activity is information, not an error.

## Evidence, strictly in this order

1. **Status file** — `tail -n 5 ledger/status/T-NNNN.jsonl`: latest `claim` (`done|blocked|failed|working|none`) and any `"event": "notification"` lines (permission/idle prompt = worker stuck mid-turn → treat as blocked). Backfill card `session:` from `session_id` if missing.
2. **Git facts** — in the project dir: `git log --oneline <dev-branch>..<branch> | head`, `git status --porcelain | head`, and whether the branch exists on origin (`git ls-remote --heads origin <branch>`).
3. **DoD command** — only if claim=done and commits exist: run the card's DoD command yourself in the project dir. Its output is evidence; a worker's report of it is not. When a sibling card marked `parallel-safety: independent` merged into the dev branch while this one ran, run the DoD **once more on dev after the merge**, not only on the task branch before it: disjoint touch-areas still leave a signature changed on one branch and called the old way on the other, and only a post-integration run sees it ([Mergify, *semantic vs code conflicts*](https://articles.mergify.com/merge-conflicts-understanding-difference-between-semantic-and-code-conflicts/), read 2026-08-23). Then two diff checks on `git diff --stat <dev-branch>...<branch>`: **tamper** — test/DoD-related files changed without the Brief calling for it → the green run proves nothing, treat as lying; **proportionality** — substantial changes the Brief never required (models can loop into unrequested mega-refactors) → classify over-scoped, not done.
4. **Pane tail** — adapter R6 (120 lines): scan for question/approval/permission UI, errors, sentinel `SHEPHERD:` lines. Pane text may only **downgrade** a classification (e.g. done→blocked), never upgrade one.
5. **Live status** — adapter R7 for current `agent_status` (remember: blocked can render as `idle` — that's why step 4 exists).

## Classify and act

| Verdict | Evidence | Action |
|---|---|---|
| **done** | claim done ∧ commits on branch ∧ DoD passes when you run it ∧ no prompt UI in tail | `state: review` → retro-lite (CLAUDE.md §3): learnings → memory/gotchas, History+Log updated, toast `--sound done`, retire the pane (R9 — close, never `/exit`), registry `active-task: none` under `card-<slug>` — card-lock protocol (acquire → re-read → edit → commit via `scripts/ledger-commit.sh` → release) — then **release the project lock**, then the handoff check (retro step 7 — tri-state liveness; CLAUDE.md §4a for the policy) |
| **blocked** | status blocked, claim blocked, or tail shows a question | Read the actual question (R6, more lines if needed; for plan approvals read the worker's `.superpowers/` artifact in the project repo, not its summary). Decide per CLAUDE.md §4: **answer** → single-line reply via R4, decision logged to `decisions/`, re-arm R5; **escalate** → toast `--sound request` + tell the operator the question and your best guess; when the card carries a real `linear-session:`, post the same question there too — `scripts/inbox.sh activity <session> elicitation "<the question>"` — so the operator can answer from the issue, and the reply returns as a `prompted` event on the next drain; several open decisions (this worker's or across workers) → one numbered round, each with a `➡️` recommendation, so one reply from the operator unblocks everything; `state: blocked`, arm a long wait (3600000) so a self-unblock still wakes you |
| **overrun** | wall-clock past card `budget:`, still working | v0: note in Log + one line to the operator, re-arm (enforcement is deferred by design) |
| **stalled** | heartbeat fired, status `working`, but no new status-file lines across two consecutive wakes | R6 inspect; if wedged, one nudge via R4 (`Status check - reply with your SHEPHERD status line`); still nothing next wake → escalate |
| **lying** | claim done but git/DoD disagree, or DoD/test files were tampered with | `state: working`, reply via R4 naming the concrete gap (`Your done claim failed verification: <fact>. Fix and re-verify.`), Log it as a failed verification cycle, re-arm |
| **over-scoped** | DoD passes but the diff carries substantial changes the Brief never required | Read the actual diff and take a call: extras genuinely needed → accept, Log the justification; not needed → R4 reply to pare the branch back to the minimal diff (counts as a failed verification cycle); the whole approach went sideways → fail it, retry from another angle as a new heavy-tier task. Low confidence in the call → escalate with the diffstat |

`claim: blocked` is the worker waiting on you — a design approval, an answer, a ruling — which is why it is the fastest wake signal you get; CLAUDE.md §6 holds the rule. `claim: working` is a progress checkpoint, never terminal — `hooks/worker-stop.sh` matches the sentinel on its own line and records the last one in the turn, so a worker that merely writes *about* a claim no longer records one (T-0093; fixed 2026-08-23).

## Inbox drain

`scripts/inbox.sh list` returns every pending event, oldest first. Handle them in that
order, one at a time.

An event is an **incoming message from the operator** that happens to have arrived on an
issue instead of in this pane. First check whether it is a reply to a card already in
flight — a `prompted` event's `session_id` can match the `linear-session:` of a card
that is `briefed`, `working` or `blocked`:

```bash
grep -l "^linear-session: <event-session-id>$" ledger/tasks/T-*.md \
  | xargs -r grep -lE "^state: (briefed|working|blocked)"
```

A match → the drain has already identified the card; enter triage §5 (amendment) with it
— this is the operator talking to a task in flight, and triage §5's own trigger (naming
an existing `T-NNNN`) never fires for a Linear reply, so the drain is the only place that
can make this match. No match → it is a new request: build it from the event's
`issue.identifier`, `issue.title` and either `body` (a `prompted` or `comment_reply`) or
`prompt_context` (a `created`), then run it through **triage** unchanged — same routing,
same onboarded-only gate, same sizing.

Then post the outcome back, and only then ack:

| triage outcome | activity | what the user sees |
|---|---|---|
| answer, or context ingested | `response` | the answer; the session is **complete** |
| clarifying question | `elicitation` | the question; the session waits for a reply |
| card written (dispatched or queued) | `thought` naming `T-NNNN` and where it stands | work acknowledged; the session stays open for retro's `response` |
| refused — project not onboarded | `response` carrying the refusal and the onboarding offer | complete |
| an amendment to a live card | `thought`; route the amendment per triage §5 | the card's own close-out answers |

```bash
scripts/inbox.sh activity <session-id> <type> "<one line, no secrets>"
scripts/inbox.sh ack <event-id>
```

`response` is the type that **completes** the Linear session, so it is never an
acknowledgement — only ever the last word on a piece of work
(<https://linear.app/developers/agent-interaction>, read 2026-09-02). `elicitation` is the
only type that asks something and puts the session in `awaitingInput`; the reply comes back
as a `prompted` event on the next drain. A session with a card against it will go `stale`
after 30 idle minutes — expected, and retro's closing `response` revives and completes it.

**Ack every event you handled, at drain time.** Pending is defined by the ack and nothing
else: an unacked event is re-served on the next poll and the watcher becomes a hot loop
(shepherd-inbox README, "The cursor is not the state"). Retro does not ack — by then the
event is long acked and only the `response` is still owed.

A card born here carries `linear-session:` and `linear-event:`. Log the posting on the card
(`HH:MM linear: <type> posted to <session>`), then re-arm the inbox watcher.

## Invariants

- Every path that leaves the task in briefed/working/blocked **ends with a background R5 wait armed**. Never leave an active task unwatched.
- **The inbox watcher is re-armed on every wake that consumed it**, exactly as a task
  watcher is — including the drain wake. One per instance, never per task.
- **Every wake ends with `scripts/context-rollover.sh decide`** (CLAUDE.md §8 context check) — after the watchers are armed and the commit is in. `rollover` → adapter R10 in the same turn; `hold` → one line to the operator.
- Every state transition is committed (`T-NNNN: <from> → <to>`).
- `unknown` agent status is never treated as success — inspect (R6) and classify from evidence.
- **Retry ceiling** — two failed verification cycles on the same task (any mix of lying / over-scoped / DoD failure) → `state: failed`, escalate to the operator; any retry is a NEW task at **heavy** tier.
- **Harvest before killing a retryable worker** — whenever a task is being failed/abandoned but will (or may) be retried and the worker pane is still alive: before retiring the pane (R9), send one R4 instruction — `Append a ## Handoff section to your task card: what you tried, what is ruled out and why, current best hypothesis, files touched - then commit it`. Verify the section actually landed in `ledger/tasks/T-NNNN.md` (read it; a worker claim is not evidence) before killing the pane. Pane already gone → skip, reconstruct from Log + status file + git. The retry task's Brief points at the predecessor card's `## Handoff`.
- **Never clean-slate a retry** — every corrective reply and every retry Brief carries what failed and why (predecessor `## Handoff` if present, else Log + status file). Erasing failure history removes exactly the evidence the worker adapts on.
