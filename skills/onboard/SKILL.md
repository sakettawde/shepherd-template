---
description: A project not yet onboarded that the operator wants work in: a deep-scan worker, the operator's answers banked into registry and memory, standing rules in the project's CLAUDE.md.
---

# onboard

Onboarding is itself a task whose output is *context*: a registry card answering "what is this product and how do we work in it", and a project CLAUDE.md workers inherit.

## Flow

1. **Stub the card** from `${CLAUDE_PLUGIN_ROOT}/templates/registry-card.md`, every field and section: `onboarded: in-progress`, `working-agreement:` from `shepherd-working-agreement <path> <dev-branch>` run now (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Working agreement). Then the index row: two locks, `card-<slug>` (`registry: <slug> card stub`) then `card-_index` (`registry: onboard <slug>`), one at a time (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Card lock).
2. **Create the onboarding task** — `Onboard <slug>`, size M, tier standard, branch `task/T-NNNN-onboard`, the Brief below; dispatch normally.
3. **Worker phase 1**: deep scan → `## Onboarding report` on the task card, the project CLAUDE.md drafted on the branch and pushed, `SHEPHERD: blocked — onboarding report and questions ready`.
4. **Question relay** — relay the worker's numbered questions to the operator **verbatim**, in one message; human answers are the point, so never answer them yourself. A likely answer goes under it as `➡️ suggested:`, never banked unconfirmed. Wait.
5. **Bank the answers** — `## Product` gets What/Why/How and the full Q&A; the fields, `preview:` among them in one of the template's two shapes — `none — <why>`, or `<mechanism> — <URL pattern> — by <push|worker|shepherd>`, the line triage reads before it writes a build-with-preview DoD; `## Gotchas` the scan findings; `## Context notes` the parallel-lanes answer, exactly `- Parallel lanes: safe (onboarding Q&A, <date>)` or `- Parallel lanes: hazard — <what is shared> (onboarding Q&A, <date>)`, the line dispatch's lane gate reads. Seed the project's auto-memory at the directory the worker's session reports and record it as `memory-dir:` — a slug guess is wrong for a nested checkout, and worktrees share one directory (code.claude.com/docs/en/memory, read 2026-09-06). Log each bank.
6. **Worker phase 2** — send the answers that change its draft (adapter R4); it finalises and ends `SHEPHERD: done`.
7. **Close** — monitor verifies, retro flips `onboarded: yes  # <date>` on card and index and **sets `working-agreement:` in the same locked edit** from `shepherd-working-agreement <path> <dev-branch>` run inside the lock: the branch it prints, else `task/T-NNNN-onboard`; same two locks (`registry: <slug> onboarded`, `registry: <slug> onboarded (index)`). The operator merges the PR at leisure; until then Briefs inline the four rules (triage §4), and dispatch flips the field after the merge.

## Onboarding Brief template (goes in the card's `## Brief`)

### Objective
Produce a product-perspective understanding of <slug> and install shepherd's working agreement in its CLAUDE.md.

### Deliverables
1. Append `## Onboarding report` to THIS card (`ledger/tasks/T-NNNN.md`): **What** is built, **Why**, **Who, really** (concrete roles, daily use, what matters most), **How** (architecture, stack, deploy, test, branches); a facts table (dev branch verified against origin HEAD, test, deploy, environments); gotchas; **numbered questions** for everything the code cannot tell you, always including, unless the scan already answered them with confidence, the real users, their use, and whether the project tolerates **two live working copies at once** (a second worktree shares ports, databases, Docker, build caches), and whether a branch can be **seen running before it merges** — the platform builds a preview from the push, a preview-only command produces one, or nothing does — with the URL it appears at and who runs the command; a promotion to a shared environment is not a preview, and the honest answer is often none.
2. Create or update the root `CLAUDE.md` with a `## Working agreement (shepherd)` section: `git fetch origin && git checkout <dev-branch> && git pull` before any task, then branch `task/T-NNNN-<slug>`; never merge or push `<dev-branch>` or main — push the task branch only, then check `<dev-branch>` out again; run `<test-command>` before claiming done; the repo's quirks. These four are what `${CLAUDE_PLUGIN_ROOT}/templates/task-card.md` inlines when `working-agreement:` is not the dev branch; keep them in step. Append or merge, never overwrite, per `${CLAUDE_PLUGIN_ROOT}/docs/writing-for-agents.md`.
3. Commit CLAUDE.md on `task/T-NNNN-onboard` and push it.

### Constraints
This task changes nothing but CLAUDE.md and this card.

### Status protocol
End phase 1 with `SHEPHERD: blocked — onboarding report and questions ready`; after the answers, `SHEPHERD: done — onboarding complete, CLAUDE.md pushed`. Any other pause: `${CLAUDE_PLUGIN_ROOT}/templates/task-card.md` `### Status protocol` decides — `blocked` whenever you need shepherd input.
