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

## 4. Task

1. **Route** via `registry/projects.md` keywords + card contents. If the project is **not `onboarded: yes`** → refuse the task in one line and offer onboarding (which is itself a task — see the onboard skill). Never brief a worker into a non-onboarded repo.
2. **Number**: `T-NNNN` = max existing in `ledger/tasks/` + 1, zero-padded to 4.
3. **Size / tier / budget**:

   | | size | budget | tier |
   |---|---|---|---|
   | one-file fix, config, small bug | S | 30m | standard (opus/xhigh) |
   | feature, multi-file bug, refactor | M | 120m | standard |
   | large feature, migration, cross-cutting | L | 240m | standard or heavy |
   | novel architecture · security-sensitive · >1-day scope · retry after failure | any | — | **heavy** (fable/max) |

4. **Card** from `templates/task-card.md`, `state: queued`. Fill the Brief from the registry card (stack, test, dev-branch, gotchas, product pointers) — the worker should never rediscover what the registry already knows. Retry of a failed task → the Brief also points at the predecessor card's `## Handoff` section (and its Log) so the new worker starts from what's already ruled out.
5. Commit (`T-NNNN: captured → queued`), then **invoke dispatch** if the project has no active task and the 3-worker cap has headroom; otherwise say "queued behind T-XXXX" and stop.

Triage decides *what and where*; dispatch decides *when and how*. Keep them separate.
