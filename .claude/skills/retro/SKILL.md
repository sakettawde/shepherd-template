---
name: retro
description: Close out a task after monitor verified it done (or declared it failed). Extracts learnings into memory and the registry, proposes downstream CLAUDE.md standing-rule updates, records metrics, releases the project lock, notifies the operator, and dispatches the next queued task. Weekly mode consolidates memory and audits decisions.
---

# retro

## Per-task close-out (precondition: monitor's four-source verification already passed, or verdict is failed/abandoned)

1. **Metrics** — append one Log line: `metrics: duration <wall-clock>, wakes <n>, decisions <n>, retries <n>, tier <t>`.
2. **Learnings** — anything durable the task revealed:
   - Project-specific facts → the project's Claude auto-memory directory (`~/.claude/projects/<encoded-project-path>/memory/`) + registry card `## Gotchas`.
   - **Locks:** a one-fact memory file needs none — two instances writing different facts cannot collide. Editing the shepherd's own `MEMORY.md` index does: take `card-_memory`, re-read the index from disk, add or rewrite the line, release. You are not necessarily the only instance closing a task right now, and an unlocked read-modify-write silently drops the other one's line. `MEMORY.md` is **not** committed — it lives outside this repo (CLAUDE.md §2 rule 10); the lock is the whole protection. Registry card edits take `card-<slug>` as usual, and those *are* committed inside the lock.
   - **Prune while banking**: if a new learning supersedes an existing gotcha/context note or memory fact, rewrite or delete the old entry — don't stack contradictions. Stale near-miss context measurably hurts more than none (context rot); a wrong note banked once poisons every future brief.
   - **Repo-specific recurring behavior** (e.g. "always regenerate the client after schema changes", "push after complete") → do NOT keep it in shepherd: queue a tiny S task to fold it into that repo's `CLAUDE.md` working agreement. This is the downstream pattern — shepherd stays thin, future workers inherit the rule for free.
   - Cross-project shepherd lessons → note in the card Log; if it recurs, propose a skill/CLAUDE.md edit in weekly mode.
3. **Records** — registry `## History` one-liner (date, task, outcome, key fact) under `card-<slug>`, re-read and committed inside the lock; backfill `Outcome:` on this task's entries in `decisions/YYYY-MM-<your-shepherd-id>.md`.
4. **Notify** — adapter R8 toast: done `--sound done` (or failed `--sound request`), plus a one-line summary to the operator in chat.

   A card carrying a real `linear-session:` also gets its answer in Linear. Read the card's
   `## Log` first and post only if no `linear: response posted` line is already there:

   ```bash
   grep -q "linear: response posted" ledger/tasks/T-NNNN.md \
     || scripts/inbox.sh activity <linear-session> response "<the same one-line outcome the operator gets in chat>"
   ```

   Then Log it as `HH:MM linear: response posted to <session>`. That posting is what moves the
   Linear session to `complete`, so it happens **once**, at close-out, for `done`, `failed` and
   `abandoned` alike — a task that was dropped or that failed still owes an answer to the
   person who asked, and a session left open shows an agent that acknowledged and then went
   permanently silent. The Log guard is what makes "once" survive a retro that is re-run or
   that was interrupted after the posting; one card per session is the drain's job (monitor's
   `## Inbox drain` matches a second event on a live session to the card it already has,
   rather than carding it again). Do not ack anything here — the drain acked the event when it
   created the card.
5. **Worker pane** — retire it via adapter R9 safe-close: guards (task closed ∧ card's pane ∧ `w-` label ∧ idle ∧ session id matches card ∧ not focused) then `pane close`, which also ends the claude session. Never `/exit` first — `pane run` appends to input-box drafts and would submit them. Drafts never block retirement; discard silently. A failed guard → leave the pane, log which guard, retry on a later wake.
6. **Release** — registry `active-task: none` and `pane: none` (if retired), or the Clones row's fields for a clone target; card `state: done|failed`. Take `card-<slug>` for the registry edit, commit inside the lock, release:

   ```bash
   scripts/lock.sh acquire "card-<slug>" "$SHEPHERD_ID" "$HERDR_PANE_ID" "<session>"
   # re-read registry/projects/<slug>.md from disk, edit, then:
   scripts/ledger-commit.sh "T-NNNN: review → done|failed" \
     registry/projects/<slug>.md ledger/tasks/T-NNNN.md ledger/status/T-NNNN*.jsonl
   scripts/lock.sh release "card-<slug>" "$SHEPHERD_ID"
   ```

   The status JSONL rides along because no other step commits it, and it is evidence ① (CLAUDE.md §2 rule 1) — without this the close-out lands in git while the record that justified it does not. `ledger-commit.sh` treats "nothing to commit" as success, so the extra path is safe when the file is unchanged.

   Then release the project lock:

   ```bash
   scripts/lock.sh release "project-<clone-id>" "$SHEPHERD_ID"
   ```

   Release the project lock even when the close-out is a failure — a held lock strands the working copy for every instance.
7. **Context check, then next** — run `scripts/context-rollover.sh decide` first (CLAUDE.md §8): `rollover` → adapter R10 now and let session-start recovery (§8 step 9) dispatch the next card on the fresh context; otherwise find the oldest `queued` card for that working copy:
   - **Yours** → invoke dispatch, if the worker cap has headroom.
   - **Another instance's** → look up its pane and session first: `scripts/lock.sh check <owner-id>` prints `HELD <owner-id> <holder> <pane> <session> <task> <acquired>` — the 4th and 5th fields are what `shepherd_live` needs (adapter R7 "peer identity"). Resolve liveness, tri-state:
     - **Live** → send that instance one message by its shepherd id (`SendMessage` to `shepherd-<name>`, once `ListAgents` shows that id live — CLAUDE.md §4a) naming the freed working copy and the card, and append a Log line recording the handoff. Do not dispatch it. The id missing from `ListAgents` means that instance launched without `-n` and no message can reach it: take the **Unresolved** branch below.
     - **Gone** → report it to the operator in one line as awaiting reassignment. Do not take it.
     - **Unresolved** → send the message anyway — it costs nothing if the peer turns out to be gone, and clears the stall if it's actually alive — then report it to the operator as unresolved. Do not take it. The peer's own session-start queued-card check (CLAUDE.md §8) only re-runs at that instance's own restart, not per wake, so an unreachable-but-live peer can otherwise sit on the card indefinitely; the report is the real safety net here, not the backstop.

Failed tasks: same flow, plus the failure reason goes to `## Gotchas` as a guardrail, and any retry is created as a NEW task at **heavy** tier referencing the failed card. The retry card's Brief MUST include a `### Prior attempts` section — what was tried, what failed, why (from the failed card's Log + status file) — and, when the failure was over-scope or a dead-end approach, a steer to attack from a different angle. Never clean-slate a retry.

## Weekly mode (when the operator asks, or scheduled later)

1. **Memory consolidation** — for each active project's auto-memory + shepherd's own: merge duplicates, drop stale entries (check `modified:` timestamps and whether the referenced code still exists), rewrite MEMORY.md indexes to one line per fact — the shepherd's own index under `card-_memory`, re-read inside the lock, released only once the rewrite is on disk. This step replaces the whole file, so it is the one most able to erase another instance's freshly banked line; it is never committed (outside this repo — CLAUDE.md §2 rule 10). Same pass over registry cards: merge/delete superseded `## Gotchas` and `## Context notes` entries — entries are prunable, the sections themselves are permanent.
2. **Decision audit** — read the month's decisions across every instance (`decisions/YYYY-MM*.md`, which also matches any legacy unsuffixed file) with outcomes; flag any decision that caused rework. If a pattern of bad approvals appears, raise the second-model-reviewer question with the operator (deferred by design until evidence demands it).
3. **Improvement proposals** — skill/CLAUDE.md diffs via superpowers:writing-skills, checked against `docs/writing-for-agents.md` (positive phrasing, no-op hunt, single source of truth, don't cache the environment), committed on a branch for the operator's git-diff review. Never self-adopt silently. Capture failures as guardrails, not just wins.
