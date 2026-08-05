# T-NNNN: <title>
state: captured
project: <slug>
size: <S|M|L>   tier: <standard|heavy>   budget: <30m|120m|240m>
branch: task/T-NNNN-<short-slug>
pane: none   session: none
created: <YYYY-MM-DDTHH:MM>

## Brief

### Objective
<one paragraph: the outcome, stated user-visibly>

### Context
Project: <path>. Stack: <stack>. Dev branch: <dev-branch>. DoD command: `<cmd>`.
<gotchas + product pointers copied from the registry card>

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
