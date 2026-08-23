---
name: dispatch
description: Send a queued task to a worker Claude in a herdr pane. Use after a task card is created, or after a task closes and that project's queue is non-empty. Enforces one-task-per-working-copy and the worker cap (CLAUDE.md §0), launches a fresh worker at the right tier, arms the background completion wait.
---

# dispatch

## Preconditions (check, don't assume)

1. Adapter version gate has passed this session (herdr-adapter R1).
2. Target task: the given `T-NNNN`, else the oldest `state: queued` card for the working copy **whose `owner:` is you** (by `created:`). Never dispatch a card you do not own — see CLAUDE.md §4a.
3. Registry card shows `onboarded: yes`. For a clone target, the parent card's `onboarded:` governs.
4. **The working agreement is reachable, or the Brief already carries it.** Run CLAUDE.md §5's check against the target working copy now. The card's `working-agreement:` was set at onboarding and the card may have sat queued for days, so the recorded value is a claim until this moment makes it a fact again.
   - **The check prints `<dev-branch>` and the field disagrees** — the onboarding PR merged in the meantime. Correct the field under `card-<slug>` (re-read from disk, edit, commit inside the lock, release), and delete the now-false *no CLAUDE.md on `<dev-branch>`* notice from the card's `### Context`, restoring the template's Constraints line. Leave the four inlined rules where they are: they are true either way, and only the notice lies.
   - **The check prints nothing** — the file is unreadable from the branch this worker checks out. The card's `### Context` must carry the notice and the four inlined rules from `templates/task-card.md`. Absent → fill them in from the template and the registry card before you launch, and Log it; you own the card, so this needs no lock.

   Never launch a worker into a repo whose standing rules it cannot read. §6 strips those rules out of every Brief on the assumption the file is readable, so when it is not, nothing else in the system supplies them (T-0084). This precondition sits ahead of the project lock on purpose: the check only fetches and reads refs, so it disturbs no working tree, and the field correction takes `card-<slug>` by itself rather than nesting inside a lock you do not hold yet.
5. Take the project lock:

   ```bash
   scripts/lock.sh acquire "project-<clone-id>" "$SHEPHERD_ID" "$HERDR_PANE_ID" "<session>" "T-NNNN"
   ```

   Read the exit code, not just the failure: **1** (`HELD …`) means another instance holds the working copy → leave the card queued, say so in one line, stop. **2** (`ERROR …`) is a filesystem or argument failure — nobody holds anything, and reporting it as "held by another instance" sends the operator hunting for a shepherd that does not exist. Report the actual message. An empty `$SHEPHERD_ID` lands here.

6. Under `dispatch.lock`, count active workers and claim a slot.

   ```bash
   scripts/lock.sh acquire dispatch "$SHEPHERD_ID" "$HERDR_PANE_ID" "<session>"
   # count, decide, then write BOTH fields on the card:
   #   state: briefed
   #   pane: claiming-<shepherd-id>
   scripts/lock.sh release dispatch "$SHEPHERD_ID"
   ```

   The count is the distinct `pane:` values across cards in `briefed|working|blocked|review`, **all owners included**, ignoring `none` — and **a `claiming-<shepherd-id>` value counts as one occupied slot**, exactly like a real pane id. Claim the slot in the field you count: `state: briefed` alone leaves the card reading `pane: none` until step 1 spawns the pane, so every pending claim collapses into one `none` and N claims count as one worker. That window is minutes wide — step 0's clone creation and step 2's 45-second idle wait both sit inside it.

   At or over `worker-cap` (CLAUDE.md §0) → release `dispatch.lock` and the project lock, leave queued, note in the card Log.

   `dispatch` **already held** (rc 1): it is a seconds-scale lock, so wait ~5s and retry, once or twice at most. Still held → **release the project lock you are holding** (or you strand the working copy for everyone), leave the card `queued`, report `waiting on <holder>` in one line, and stop. Never spin (CLAUDE.md §4a; `docs/specs/multi-shepherd-design.md` §6.5), and never proceed without the lock — that is the overshoot the cap exists to prevent. `check dispatch` names the holder. rc **2** here is the same filesystem/argument failure as item 5, not contention: release the project lock, report the message, stop — retrying will not clear it.

   Hold `dispatch.lock` for seconds only. It spans count → decide → write the two fields, nothing more.

## Steps

0. **Clone target only** — if the card's `project:` carries a `~N` suffix and the registry `## Clones` table has no row for it, create the working copy first. **The card may have no `## Clones` section at all** — cards created before 2026-08-22 may lack it, and nothing seeds one. Create the section (heading + the `| clone-id | path | active-task | pane |` header row) in the same locked edit that appends the first row; place it with the card's other sections, and never in place of one. The fetch, worktree, seed and install run **outside** any lock; only the Clones-row append is locked.

   ```bash
   git -C <parent-path> fetch origin
   git -C <parent-path> worktree add --detach <parent-path>-wt<N> origin/<dev-branch>
   cp <parent-path>/<each clone-seed path that exists> <parent-path>-wt<N>/
   ( cd <parent-path>-wt<N> && <install command> )
   ```

   `--detach` is required: a worktree cannot check out a branch the base copy already has. Defaults when the registry card omits them: `clone-seed: .dev.vars .env .env.local`, `install: npm install`. A failure here is reported to the operator before dispatch — never left for the worker to discover. Then take `card-<slug>`, re-read, append the Clones row, commit, release:

   ```bash
   scripts/lock.sh acquire "card-<slug>" "$SHEPHERD_ID" "$HERDR_PANE_ID" "<session>"
   # re-read registry/projects/<slug>.md from disk, append the Clones row, then:
   scripts/ledger-commit.sh "<slug>: clone <clone-id> created" "registry/projects/<slug>.md"
   scripts/lock.sh release "card-<slug>" "$SHEPHERD_ID"
   ```

1. **Pane** — if registry `pane:` is not `none`, verify it's alive and reusable (adapter R7: pane exists, no agent running / shell idle). Else spawn one (R2, label `w-<slug>`) and write it to the registry card.
2. **Launch** — adapter R3 with the card's tier: standard → `--model opus --effort high`; heavy → `--model opus --effort xhigh`. **A different model only when the operator specifically asked for it, and then only at `--effort high`.** Env vars in the launch line: `SHEPHERD_TASK_ID=T-NNNN`, `SHEPHERD_STATUS_FILE=<shepherd-root>/ledger/status/T-NNNN.jsonl`.
   - If the idle wait (45s) times out: read the pane (R6), diagnose (login prompt? flag rejected? trust-folder dialog?), fix or escalate. If `--permission-mode auto` was rejected, relaunch without it and flag to the operator before further dispatches.
3. **Kickoff** — adapter R4: `You are a shepherd worker. Read <shepherd-root>/ledger/tasks/T-NNNN.md and execute its Brief exactly.` On 0.8.2 the kickoff and its confirmation are one call — `herdr agent prompt <pane> "<kickoff>" --wait --until working --timeout 15000` (foreground; a timeout on a very fast task is fine — check the status file before worrying).
4. **Record** — task card: `state: briefed` (already set under `dispatch.lock` in Preconditions item 6 to claim the slot; this step completes the rest of the card, not setting the state a second time), `owner:` already yours, `pane:` — **overwrite the `claiming-<shepherd-id>` placeholder with the real pane id here**, Log line (`briefed pane <id>, model/effort, launch time`) — no lock, you are its only writer. Registry card: under `card-<slug>`, set `active-task: T-NNNN` (or the Clones row's `active-task` for a clone target):

   ```bash
   scripts/lock.sh acquire "card-<slug>" "$SHEPHERD_ID" "$HERDR_PANE_ID" "<session>"
   # re-read registry/projects/<slug>.md from disk, edit, then:
   scripts/ledger-commit.sh "<slug>: active-task T-NNNN" "registry/projects/<slug>.md"
   scripts/lock.sh release "card-<slug>" "$SHEPHERD_ID"
   ```
5. **Arm both watchers** — adapter R5, each as a **background Bash task**: the ground-truth status-file watcher (primary) and the herdr `blocked` stall watcher (secondary). Either exit is your wake-up call → invoke the monitor skill. Log `watchers armed`.
6. **Commit** — `scripts/ledger-commit.sh "T-NNNN: queued → briefed" ledger/tasks/T-NNNN.md`.

   **If anything above failed after precondition 6 claimed the slot, undo the claim before you stop** — all of it, in this order: put the card back to `state: queued` and `pane: none`, release `dispatch.lock` if you still hold it, release the project lock, commit the card, then report. Leaving `state: briefed` with a `claiming-…` placeholder and no worker burns a slot against `worker-cap` that nothing will ever free, and leaving the project lock strands the working copy for every instance.

Never send the Brief content through the pane — only the one-line kickoff. The card file is the contract.
