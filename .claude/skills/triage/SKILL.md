---
name: triage
description: Turn every incoming message from the operator into exactly one of - a direct answer, context ingestion, a clarifying question, or a task card. Routes to onboarded projects, sizes/tiers/budgets tasks, enforces the onboarded-only gate, and offers onboarding when needed. Never dispatches work itself.
---

# triage

Every message is exactly ONE of four intake types. Classify first, then act.

## 1. Answer

Question about state, history, a project, or a decision → answer from registry/ledger/decisions/memory (grep cookbook in CLAUDE.md §5). One line where possible. No task.

## 2. Context ingestion

The operator is sharing knowledge (decisions, meeting notes, stakeholder conversations, priorities):

1. Identify the project (ask if ambiguous).
2. Append a dated entry to the registry card `## Context notes` (verbatim-ish, compressed).
3. Distill durable facts into the project's Claude auto-memory directory (`~/.claude/projects/<encoded-project-path>/memory/`) (one-fact files + MEMORY.md index line).
4. Commit, confirm in one line.

## 3. Clarifying question

Routing or intent ambiguous → ask. Never guess the project. If two projects plausibly match, name both and ask.

Ask in **frontier rounds** (grilling pattern): batch every question askable *now* into one numbered message, each with your recommended answer (`➡️`) so the operator can rubber-stamp or override in a single reply. Questions that depend on an answer still open wait for the next round. Facts you can look up (repo, registry, ledger) are never questions — only genuine decisions go to the operator.

## 4. Task

1. **Route** via `registry/projects.md` keywords + card contents. If the project is **not `onboarded: yes`** → refuse the task in one line and offer onboarding (which is itself a task — see the onboard skill). Never brief a worker into a non-onboarded repo.
2. **Number**: `T-NNNN` = max existing in `ledger/tasks/` + 1, zero-padded to 4.
3. **Size / tier / budget**:

   | | size | budget | tier |
   |---|---|---|---|
   | one-file fix, config, small bug | S | 30m | standard (fable/high) |
   | feature, multi-file bug, refactor | M | 120m | standard |
   | large feature, migration, cross-cutting | L | 240m | standard or heavy |
   | novel architecture · security-sensitive · >1-day scope · retry after failure | any | — | **heavy** (fable/max) |

4. **Card** from `templates/task-card.md`, `state: queued`. Fill the Brief from the registry card (stack, test, dev-branch, gotchas, product pointers) — the worker should never rediscover what the registry already knows. Retry of a failed task → the Brief also points at the predecessor card's `## Handoff` section (and its Log) so the new worker starts from what's already ruled out.

   **Brief-writing principles** (adapted from mattpocock/skills AGENT-BRIEF):
   - **Behavioral, not procedural** — describe what the system should do after the work, current behavior vs desired behavior; the worker explores and plans itself (briefs, not plans — CLAUDE.md §6).
   - **Fill `### Why`** — the intent behind the operator's ask and the working mode (quick-and-dirty vs long-term-thorough), so the worker inherits it and can judge unanticipated trade-offs; monitor judges diff proportionality against it.
   - **Durable over precise** — a card can sit queued for days behind other tasks. Name interfaces, types, commands, and behavioral contracts; never file paths or line numbers — they go stale between queueing and dispatch.
   - **DoD criteria independently checkable** — each line something shepherd can verify alone ("`<cmd>` passes", "route X returns Y"), never "works correctly".
   - **Fill `### Out of scope`** — the adjacent things the worker must not touch. This is the cheapest defense against gold-plating and over-scoped diffs (monitor's over-scoped verdict starts here).
   - **Bug tasks: repro-first DoD** — the Brief requires the worker to produce one command that goes red on the bug before fixing (test, curl, CLI invocation). That command goes into the DoD; monitor reruns it at verification. No repro command → the fix claim is unverifiable.

   **Decomposing L work**: when a thought is too big for one worker session, split it into **tracer-bullet slices** — each a narrow but complete vertical path (schema→API→UI→test), independently demoable, sized to one fresh worker context — as separate cards queued FIFO with blockers first. Note cross-card dependencies in each Brief (`Depends on: T-XXXX`). One mechanical wide refactor (rename, retype) is the exception: expand → migrate in batches → contract, each batch its own card. Present the proposed split to the operator for approval before creating the cards.
5. Commit (`T-NNNN: captured → queued`), then **invoke dispatch** if the project has no active task and the 3-worker cap has headroom; otherwise say "queued behind T-XXXX" and stop.

Triage decides *what and where*; dispatch decides *when and how*. Keep them separate.
