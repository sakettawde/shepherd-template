---
name: onboard
description: Bring a project under shepherd management. Dispatches a product-perspective deep-scan worker, relays its clarifying questions to the operator, banks the answers into the registry and project memory, and installs standing worker rules in the project's own CLAUDE.md. Only onboarded projects accept tasks.
---

# onboard

Onboarding is itself a task — card, branch, worker, verification — so the whole machine exercises normally. The output is *context*: a registry card that answers "what is this product and how do we work in it", plus a project CLAUDE.md that makes every future worker behave correctly for free.

## Flow

1. **Stub the card** — create/refresh `registry/projects/<slug>.md` with known fields, `onboarded: in-progress` (the task gate greps for `yes`, so tasks stay refused), all four sections present. Add/update the index row.
2. **Create the onboarding task** — title `Onboard <slug>`, size M, tier standard, branch `task/T-NNNN-onboard`, Brief from the template below. Commit; invoke dispatch (normal path, normal watchers).
3. **Worker phase 1** (one turn): deep scan → writes its report INTO the task card (append `## Onboarding report`), drafts the project CLAUDE.md on the task branch, commits + pushes, ends `SHEPHERD: blocked — onboarding report and questions ready`.
4. **Question relay** — on wake, read the report in the card. Relay the worker's numbered questions to the operator **verbatim** in chat (this is the one intake where human answers are the whole point — do not answer them yourself). Wait.
5. **Bank the answers** — registry card: `## Product` gets What/Why/How + the full Q&A; fields enriched (stack, test, dev-branch, keywords); `## Gotchas` gets scan findings. Seed the project's Claude auto-memory directory (`~/.claude/projects/<encoded-project-path>/memory/`) with durable product facts + MEMORY.md index lines. Log each answer-bank in the card.
6. **Worker phase 2** — send the worker any answers that change its CLAUDE.md draft or report (single-line messages via adapter R4, or point it at the updated registry card). Worker finalizes, verifies DoD, ends `SHEPHERD: done`.
7. **Close** — monitor verifies (CLAUDE.md commit on the branch, pushed), retro closes, and retro flips `onboarded: yes  # <date>` + index. The operator merges the small onboarding PR at leisure via their normal review flow; the registry is authoritative for shepherd either way.

## Onboarding Brief template (goes in the card's `## Brief`)

### Objective
Produce a product-perspective understanding of <slug> and install shepherd's working agreement in its CLAUDE.md.

### Deliverables
1. Append a section `## Onboarding report` to THIS card file (<shepherd-root>/ledger/tasks/T-NNNN.md) containing:
   - **What** is being built (user-visible, one paragraph). **Why** (who uses it, what problem). **Who, really** — the real-world users (concrete roles/personas, not abstractions), what they actually use the product for day-to-day, and what matters most to them. This is tiebreaker context: when a design decision is at a point of contention, it guides the direction. **How** (architecture, stack, data stores, deploy story, test story, branch model).
   - Facts table: dev branch (verify against origin HEAD), test/build command, deploy mechanism, environments/preview URLs.
   - Risks & gotchas a coding agent must know.
   - **Numbered questions** — everything the code cannot tell you: product intent, priorities, constraints, stakeholders, tribal knowledge, anything surprising. ALWAYS include (unless the scan already answered them with confidence): who the real-world users are, and what they are using the product for. Ask about everything; unasked questions become bad future decisions.
2. Create or update `CLAUDE.md` in the project root with a `## Working agreement (shepherd)` section:
   - Before starting any task: `git fetch origin && git checkout <dev-branch> && git pull`, then branch `task/T-NNNN-<slug>` from it.
   - Never merge or push `<dev-branch>` or main. Push only your task branch; after pushing, check out `<dev-branch>` again so the repo rests in a neutral state.
   - Run `<test-command>` before claiming done.
   - Repo-specific quirks you discovered (deploy cautions, generated files, env handling).
   Preserve all existing CLAUDE.md content — append/merge, never overwrite. Write rules per <shepherd-root>/docs/writing-for-agents.md: positive phrasing, no restating what config files already answer, every rule earning its always-loaded cost.
3. Commit CLAUDE.md on branch `task/T-NNNN-onboard` and push it.

### Constraints
Read-only with respect to all other files — this task changes nothing but CLAUDE.md and this card.

### Status protocol
End phase 1 with `SHEPHERD: blocked — onboarding report and questions ready`. After receiving answers, finalize and end `SHEPHERD: done — onboarding complete, CLAUDE.md pushed`.
