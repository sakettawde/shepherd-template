# T-NNNN: <title>
state: captured
owner: <shepherd-id>
project: <slug|slug~N for a clone working copy>
kind: build   # the card's kind: `build` (this template) or `reply` (templates/reply-card.md, a read-only answer); an absent line reads build
size: <S|M|L>   tier: <standard|heavy>   budget: <30m|120m|240m>
branch: task/T-NNNN-<short-slug>
touch-areas: <what the work reaches, comma-separated: modules, schemas, config domains, shared interfaces — durable names, never file paths>
parallel-safety: <independent|serialized> — <one line: the shared contract that decides it>
pane: none   session: none
created: <YYYY-MM-DDTHH:MM>
linear-session: <agent session id, when this card came from Linear | none>
linear-event: <the inbox event id that created it | none>
linear-author: <the event's `author.id` — who may amend or cancel besides the operator (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice) | none>

Depends on: <none | T-XXXX — what it must have landed; dispatch holds this card queued until each reads done>

## Brief

### Objective
<one paragraph: current behavior vs desired behavior, stated user-visibly. Behavioral, not procedural — the worker explores and plans its own route>

### Why
<the intent behind the ask — why the operator wants this now, and the working mode (quick-and-dirty vs built-for-the-long-term). Use it to judge trade-offs the brief didn't anticipate; keep the diff proportionate to it>

### Context
Project: <path>. Stack: <stack>. Dev branch: <dev-branch>. DoD command: `<cmd>`.
<gotchas + product pointers copied from the registry card. Durable over precise: name interfaces, types, commands, behavioral contracts — never file paths or line numbers; cards can sit queued for days>

<KEEP THIS BLOCK ONLY when the registry card's `working-agreement:` is not `<dev-branch>` (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Working agreement); delete it outright when it is:

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
- ALWAYS start with the superpowers:brainstorming skill before touching code — every size, no exceptions (Saket, 2026-07-24). Then plan, and implement in this session: the brief's conversation, your memory and your output style live here, and a subagent starts with none of them — the docs say to use the main conversation when "multiple phases share significant context, such as planning, implementation, and testing" (code.claude.com/docs/en/sub-agents, read 2026-09-06). Subagents earn their isolation for verbose exploration you do not need in your context, and for one independent review of the finished branch.
- **Ask in one round.** When you need shepherd's input, batch every question you can ask now into one numbered list, each with your recommended answer (`➡️`), and end that turn `blocked`; a question that depends on an answer still open waits for the next round. One pause with five questions costs one wake; five pauses cost five, each up to 30 minutes.
- **Validate against live sources, and cite what you read** (the operator standing rule, 2026-08-14, restated 2026-08-19 — the manual §2 rule 11). Two triggers: (a) the work rests on a **third party or on infrastructure** you do not own — a vendor API, SDK, console, CDN, CRM or cloud platform; (b) you face a **choice with no clear winner**. When either fires, check it against a live source before building on it: `ctx7` for library and SDK documentation, web search for vendor product behaviour and changelogs. Never from memory, and never from this card — a card can sit queued for days. Name the source next to the claim it supports. When the source does not settle it, decide anyway, name the best source you found, and state your confidence; end `SHEPHERD: blocked` only if the choice is also expensive or hard to reverse.
  <shepherd: keep this bullet by default; delete it only when neither trigger can apply to this task>
- **Extras are follow-ups, not fixes.** If, while working or testing, you find a pre-existing bug, a performance concern, or behaviour the task doesn't mention, don't fix, optimize or extend it in this change unless the requested behaviour cannot work without it; report it as a follow-up in your summary. Verify your work however you like; scratch scripts and quick checks need not be kept. Commit tests only where the task asks for them or this repository already keeps tests for this kind of change, sized like the neighbouring test files — roughly one focused test per stated behaviour. This is about extras only: implement every behaviour the task asks for, completely. (platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-1 § Keep changes and tests to what the task asks for, read 2026-09-08: with this instruction "unrequested additions and committed test code drop substantially with no measurable change in task success".)

### Out of scope
<what this task must NOT touch: adjacent features that look related but are separate, refactors not asked for. Kills gold-plating; delete the section only if truly nothing borders the work>

### Definition of Done
- `<cmd>` passes, run unpiped: a `| tail` reports the pipe's exit status, not the command's, so a failing gate comes back as exit 0 and the `done` claim is false. Long output goes to a file with `>`; a pipe you must keep is read through `${PIPESTATUS[0]}`.
- Branch pushed to origin.
  <shepherd: a project whose registry `preview:` names a mechanism gets one more DoD line here, worded as triage §4's build-with-preview bullet writes it; the field's `by` value decides who satisfies it, and that bullet reads all three. `preview: none` gets no line>
- <bug tasks: a single repro command that went red on the bug and green after the fix — shepherd reruns it at verification>

### Status protocol
Before you claim, audit each claim in your final message against a tool result from this session — a command's output, a diff, a sha that resolves — and report only what you can point at; say plainly what is not verified, and if a check failed, say so with its output.

Report status with the command, as the last thing you do before your turn ends:

shepherd-status done|blocked|failed|working "<one short line>"

Run it — a Bash call whose answer you read. It is on your PATH in a shepherd worker session and answers `recorded <claim> for T-NNNN`; a copy of the line written into your message is not a run, and reads as the weaker claim it is. If it is not found or fails, end your message with the sentinel line instead — bare, on a line of its own, with nothing else on the line:

SHEPHERD: done|blocked|failed|working — <one short line>

Emphasis, backticks, a `>` or a `-` in front of the sentinel are tolerated, so a decorated copy still records; bare is the form to write. Either way, one claim per turn. Pick by what happens next. **`blocked`** — you need shepherd input to continue: a design approval, an answer, a ruling, a permission. **`working`** — you continue on your own next turn; a progress checkpoint, never terminal. `done` and `failed` end the task; `blocked` pauses it.
Shepherd wakes on `blocked` within seconds and on `working` only at the next heartbeat, so an approval pause that ends `working` waits up to 30 minutes for a reply.

## Log
- <HH:MM> captured (<source thought, verbatim-ish>)

## Handoff
<empty until shepherd asks for one — a context reset past ~50 % (memory: worker-context-handoff) or a retry harvest (monitor). The worker writes it and commits it; a fresh session on this card, or the retry's Brief, reads it before anything else>
- Branch: <tip sha, base ref and sha, pushed or local-only>
- Gate at handoff: <the DoD command and its result, verbatim>
- Done: <tasks finished, each with its commits>
- Remaining: <tasks left, each with its plan or Brief pointer>
- Ruled out: <what was tried and failed, and why — the steer a retry starts from>
- Best hypothesis: <where you would go next, and why — the forward half of what a retry inherits>
- Open rulings: <questions waiting on shepherd>
- Files touched:
