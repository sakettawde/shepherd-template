---
name: dispatch
description: Send a queued task to a worker Claude in a herdr pane. Use after a task card is created, or after a task closes and that project's queue is non-empty. Enforces one-task-per-project and the 3-worker cap, launches a fresh worker at the right tier, arms the background completion wait.
---

# dispatch

## Preconditions (check, don't assume)

1. Adapter version gate has passed this session (herdr-adapter R1).
2. Target task: the given `T-NNNN`, else the oldest `state: queued` card for the project (by `created:`).
3. Registry card shows `onboarded: yes` and `active-task: none`. If a task is active → leave queued, say so in one line.
4. Active workers < 3 (count distinct `pane:` values across cards in states briefed/working/blocked/review). At cap → leave queued, note in card Log.

## Steps

1. **Pane** — if registry `pane:` is not `none`, verify it's alive and reusable (adapter R7: pane exists, no agent running / shell idle). Else spawn one (R2, label `w-<slug>`) and write it to the registry card.
2. **Launch** — adapter R3 with the card's tier: standard → `--model fable --effort high`; heavy → `--model fable --effort max`. Env vars in the launch line: `SHEPHERD_TASK_ID=T-NNNN`, `SHEPHERD_STATUS_FILE=<shepherd-root>/ledger/status/T-NNNN.jsonl`.
   - If the idle wait (45s) times out: read the pane (R6), diagnose (login prompt? flag rejected?), fix or escalate. If `--permission-mode auto` was rejected, relaunch without it and flag to the operator before further dispatches.
3. **Kickoff** — adapter R4: `You are a shepherd worker. Read <shepherd-root>/ledger/tasks/T-NNNN.md and execute its Brief exactly.` Then confirm the prompt took: `herdr wait agent-status <pane> --status working --timeout 15000` (foreground; a timeout on a very fast task is fine — check the status file before worrying).
4. **Record** — task card: `state: briefed`, `pane:`, Log line (`briefed pane <id>, model/effort, launch time`). Registry card: `active-task: T-NNNN`.
5. **Arm both watchers** — adapter R5, each as a **background Bash task**: the ground-truth status-file watcher (primary) and the herdr `blocked` stall watcher (secondary). Either exit is your wake-up call → invoke the monitor skill. Log `watchers armed`.
6. **Commit** — `T-NNNN: queued → briefed`.

Never send the Brief content through the pane — only the one-line kickoff. The card file is the contract.
