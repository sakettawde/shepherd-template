---
name: retro
description: Close out a task after monitor verified it done (or declared it failed). Extracts learnings into memory and the registry, proposes downstream CLAUDE.md standing-rule updates, records metrics, releases the project lock, notifies the operator, and dispatches the next queued task. Weekly mode consolidates memory and audits decisions.
---

# retro

## Per-task close-out (precondition: monitor's four-source verification already passed, or verdict is failed/abandoned)

1. **Metrics** — append one Log line: `metrics: duration <wall-clock>, wakes <n>, decisions <n>, retries <n>, tier <t>`.
2. **Learnings** — anything durable the task revealed:
   - Project-specific facts → the project's Claude auto-memory directory (`~/.claude/projects/<encoded-project-path>/memory/`) + registry card `## Gotchas`.
   - **Prune while banking**: if a new learning supersedes an existing gotcha/context note or memory fact, rewrite or delete the old entry — don't stack contradictions. Stale near-miss context measurably hurts more than none (context rot); a wrong note banked once poisons every future brief.
   - **Repo-specific recurring behavior** (e.g. "always regenerate the client after schema changes", "push after complete") → do NOT keep it in shepherd: queue a tiny S task to fold it into that repo's `CLAUDE.md` working agreement. This is the downstream pattern — shepherd stays thin, future workers inherit the rule for free.
   - Cross-project shepherd lessons → note in the card Log; if it recurs, propose a skill/CLAUDE.md edit in weekly mode.
3. **Records** — registry `## History` one-liner (date, task, outcome, key fact); backfill `Outcome:` on this task's entries in `decisions/`.
4. **Notify** — adapter R8 toast: done `--sound done` (or failed `--sound request`), plus a one-line summary to the operator in chat.
5. **Worker pane** — retire it via adapter R9 safe-close: guards (task closed ∧ card's pane ∧ `w-` label ∧ idle ∧ session id matches card ∧ not focused) then `pane close`, which also ends the claude session. Never `/exit` first — `pane run` appends to input-box drafts and would submit them. Drafts never block retirement; discard silently. A failed guard → leave the pane, log which guard, retry on a later wake.
6. **Release** — registry `active-task: none` and `pane: none` (if retired); card `state: done|failed`; commit (`T-NNNN: review → done`).
7. **Next** — if the project has queued tasks and the worker cap has headroom, invoke dispatch for the oldest.

Failed tasks: same flow, plus the failure reason goes to `## Gotchas` as a guardrail, and any retry is created as a NEW task at **heavy** tier referencing the failed card. The retry card's Brief MUST include a `### Prior attempts` section — what was tried, what failed, why (from the failed card's Log + status file) — and, when the failure was over-scope or a dead-end approach, a steer to attack from a different angle. Never clean-slate a retry.

## Weekly mode (when the operator asks, or scheduled later)

1. **Memory consolidation** — for each active project's auto-memory + shepherd's own: merge duplicates, drop stale entries (check `modified:` timestamps and whether the referenced code still exists), rewrite MEMORY.md indexes to one line per fact. Same pass over registry cards: merge/delete superseded `## Gotchas` and `## Context notes` entries — entries are prunable, the sections themselves are permanent.
2. **Decision audit** — read the month's `decisions/` with outcomes; flag any decision that caused rework. If a pattern of bad approvals appears, raise the second-model-reviewer question with the operator (deferred by design until evidence demands it).
3. **Improvement proposals** — skill/CLAUDE.md diffs via superpowers:writing-skills, committed on a branch for the operator's git-diff review. Never self-adopt silently. Capture failures as guardrails, not just wins.
