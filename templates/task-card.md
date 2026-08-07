# T-NNNN: <title>
state: captured
project: <slug>
size: <S|M|L>   tier: <standard|heavy>   budget: <30m|120m|240m>
branch: task/T-NNNN-<short-slug>
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

### Constraints
- Branch `task/T-NNNN-<short-slug>` off the latest `<dev-branch>`; never merge or push `<dev-branch>` or main directly.
- This repository's own CLAUDE.md is the authoritative working agreement (git sync, tests, push discipline) — follow it.
- ALWAYS start with the superpowers:brainstorming skill before touching code — every size, no exceptions. Then: S = test-driven-development; M/L = writing-plans → subagent-driven-development.

### Definition of Done
- `<cmd>` passes.
- Branch pushed to origin (preview deploy where configured).

### Status protocol
End every pause and your final message with exactly one line:
`SHEPHERD: done|blocked|failed — <one short line>`

## Log
- <HH:MM> captured (<source thought, verbatim-ish>)
