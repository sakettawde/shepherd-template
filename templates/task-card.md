# T-NNNN: <title>
state: captured
owner: <shepherd-id>
project: <slug|slug~N for a clone working copy>
size: <S|M|L>   tier: <standard|heavy>   budget: <30m|120m|240m>
branch: task/T-NNNN-<short-slug>
touch-areas: <what the work reaches, comma-separated: modules, schemas, config domains, shared interfaces — durable names, never file paths>
parallel-safety: <independent|serialized> — <one line: the shared contract that decides it>
pane: none   session: none
created: <YYYY-MM-DDTHH:MM>

## Brief

### Objective
<one paragraph: current behavior vs desired behavior, stated user-visibly. Behavioral, not procedural — the worker explores and plans its own route>

### Why
<the intent behind the ask — why the operator wants this now, and the working mode (quick-and-dirty vs built-for-the-long-term). Use it to judge trade-offs the brief didn't anticipate; keep the diff proportionate to it>

### Context
Project: <path>. Stack: <stack>. Dev branch: <dev-branch>. DoD command: `<cmd>`.
<gotchas + product pointers copied from the registry card. Durable over precise: name interfaces, types, commands, behavioral contracts — never file paths or line numbers; cards can sit queued for days>

<KEEP THIS BLOCK ONLY when the registry card's `working-agreement:` is not `<dev-branch>` (CLAUDE.md §5); delete it outright when it is:

**This repo has no CLAUDE.md on `<dev-branch>`.** Its working agreement lives on `<working-agreement>`, a branch you never check out, so the four standing rules are inlined here — these four are the whole of it:
1. Before you start: `git fetch origin && git checkout <dev-branch> && git pull`, then branch from there.
2. Never merge or push `<dev-branch>` or main. Push your task branch only, then check `<dev-branch>` back out so the repo rests neutral.
3. Run `<test-command>` before you claim done.
4. Repo-specific quirks: <copied from the registry card `## Gotchas`>.
>

### Constraints
- Branch `task/T-NNNN-<short-slug>` off the latest `<dev-branch>`; never merge or push `<dev-branch>` or main directly.
- This repository's own CLAUDE.md is the authoritative working agreement (git sync, tests, push discipline) — follow it.
  <shepherd: keep this line only when the registry card's `working-agreement:` is `<dev-branch>`. Otherwise the worker cannot open that file from its branch — delete this line and keep the inlined block in `### Context` instead>
- ALWAYS start with the superpowers:brainstorming skill before touching code — every size, no exceptions. Then: S = test-driven-development; M/L = writing-plans → subagent-driven-development.
- **Validate against live sources, and cite what you read** (CLAUDE.md §2 rule 11). Two triggers: (a) the work rests on a **third party or on infrastructure** you do not own — a vendor API, SDK, console, CDN, CRM or cloud platform; (b) you face a **choice with no clear winner**. When either fires, check it against a live source before building on it: a documentation-retrieval tool for library and SDK documentation, web search for vendor product behaviour and changelogs. Never from memory, and never from this card — a card can sit queued for days. Name the source next to the claim it supports. When the source does not settle it, decide anyway, name the best source you found, and state your confidence; end `SHEPHERD: blocked` only if the choice is also expensive or hard to reverse.
  <shepherd: keep this bullet by default; delete it only when neither trigger can apply to this task>

### Out of scope
<what this task must NOT touch: adjacent features that look related but are separate, refactors not asked for. Kills gold-plating; delete the section only if truly nothing borders the work>

### Definition of Done
- `<cmd>` passes.
- Branch pushed to origin (preview deploy where configured).
- <bug tasks: a single repro command that went red on the bug and green after the fix — shepherd reruns it at verification>

### Status protocol
End every pause and your final message with exactly one line, on a line of its own — written bare, exactly as shown here, with nothing else on the line:

SHEPHERD: done|blocked|failed|working — <one short line>

Emphasis and backticks around it are tolerated, so a decorated copy still records; bare is the form to write. Pick by what happens next. **`blocked`** — you need shepherd input to continue: a design approval, an answer, a ruling, a permission. **`working`** — you continue on your own next turn; a progress checkpoint, never terminal. `done` and `failed` end the task; `blocked` pauses it.
Shepherd wakes on `blocked` within seconds and on `working` only at the next heartbeat, so an approval pause that ends `working` waits up to 30 minutes for a reply.

## Log
- <HH:MM> captured (<source thought, verbatim-ish>)
