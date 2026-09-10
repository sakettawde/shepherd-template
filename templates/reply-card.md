# T-NNNN: <the question, in a few words>
state: captured
owner: <shepherd-id>
project: <slug — the base checkout's family; the lane is dispatch's throwaway worktree, never a ~N clone>
kind: reply
size: S   tier: standard   budget: 20m
branch: none
touch-areas: none — read-only
parallel-safety: independent — writes nothing and shares no lock
pane: none   session: none
created: <YYYY-MM-DDTHH:MM>
linear-session: <agent session id, when this card came from Linear | none>
linear-event: <the inbox event id that created it | none>
linear-author: <the event's `author.id` — who may amend or cancel besides the operator (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice) | none>

Depends on: none

<shepherd, before the Brief: `size: S` / `tier: standard` / `budget: 20m` is the reply ladder's default — opus/high on the `tiers:` line in the manual §0. A *review* or *investigate* may be sized `M` at triage's judgment — fable/high, `budget: 60m`. Never `L`: an L reply is a build in disguise (spec §11 Q5). `branch: none`, `touch-areas:` and `parallel-safety:` stay as written — nothing that scans a card header trips on a missing field, and the values say why they are moot: a reply lane is skipped by the gates that read them. Delete this note.>

## Brief

### Objective
<one paragraph: what the reader asked, read as a spike — the output is an answer in `## Reply`, never a change. Say what a complete answer covers and what it may leave out>

### Why
<who is waiting on this and what they will do with the answer — a decision, a build ask, a ticket closed. Use it to judge depth: a reader deciding whether to card a build needs the where and the how-big, not the whole mechanism>

### Question
<verbatim, as asked>
Issue <identifier>; thread <the root comment or the primary directive thread>; asked by <author's name — role unknown>.

### Audience
<who reads the reply and what they can be assumed to know: the author, a member of the workspace, not necessarily an engineer of this repo. Name what needs spelling out and what does not>

### Context
Project: <the lane — a worktree detached at <dev-branch>, or at the PR head for a review, named on the Log's `briefed` line>. Stack: <stack>. Dev branch: <dev-branch>.
<gotchas + product pointers copied from the registry card, durable over precise. The project's own CLAUDE.md is readable in the lane: read it for the map, not for rules to run>

### No code changes
The hard line of this card: nothing edited, nothing committed, no branch, no push, no deploy, no service started that writes. The lane is a detached worktree that is removed at close-out, so anything written there is discarded — and anything sent anywhere is not: `Edit`, `Write` and `NotebookEdit` are absent from this session, and the push, commit, deploy and GitHub-posting verbs are refused. A change the question needs is named in **Next step**; a reader who wants it built asks, and that becomes a build card.

### Answer bar
`## Reply` is what gets posted, verbatim, to a colleague whose role you do not know — write as a considerate engineering collaborator. Write plainly: short sentences, common words, one idea per sentence. Four parts, each starting a line with its bold label, in this order, the whole reply at most 150 words — a ceiling, never a target, so use as few as the question needs:

**Answer** — the thing asked, in plain words, first; at most 80 words.
**What I checked** — a bare comma-joined list of references, no prose around it: the files, commits, commands and PRs you read, each real at the lane's head — a path that exists, a sha that resolves, a branch on `origin`, a PR number. Shepherd verifies every one before posting; a reference that fails comes back to you once.
**Confidence** — high, medium or low, and the one fact that would change it.
**Next step** — one sentence, one offer. Where it is a choice, a short list of options in plain text, never a `select`: the reply is the last word on the session, the reader clicks nothing, and a pick comes back as a new request.

Anything beyond the reply goes in your final message; nothing else is written anywhere.

### Constraints
- ALWAYS start with the superpowers:brainstorming skill before reading code — every size, no exceptions (Saket, 2026-07-24) — as a spike: its output is your reading of the question, in conversation, with no design document, and this session has no `Write`. Then read, and answer in this session: the brief's conversation, your memory and your output style live here, and a subagent starts with none of them (code.claude.com/docs/en/sub-agents, read 2026-09-06). Subagents earn their isolation for verbose exploration you do not need in your context.
- **Ask in one round.** When you need shepherd's input, batch every question you can ask now into one numbered list, each with your recommended answer (`➡️`), and end that turn `blocked`; a question that depends on an answer still open waits for the next round. One pause with five questions costs one wake; five pauses cost five, each up to 30 minutes. A question only the reader can answer goes in **Next step** instead.
- **Validate against live sources, and cite what you read** (the operator standing rule, 2026-08-14, restated 2026-08-19 — the manual §2 rule 11). Two triggers: (a) the answer rests on a **third party or on infrastructure** you do not own — a vendor API, SDK, console, CDN, CRM or cloud platform; (b) you face a **choice with no clear winner**. When either fires, check it against a live source before answering on it: `ctx7` for library and SDK documentation, web search for vendor product behaviour and changelogs. Never from memory, and never from this card — a card can sit queued for days. Name the source in **What I checked**. When the source does not settle it, answer anyway, name the best source you found, and say so in **Confidence**.
  <shepherd: keep this bullet by default; delete it only when neither trigger can apply to this question>
- Budget: <budget>. A reply that outruns it fails and is re-briefed with a narrower question — there is no handoff: say what you could not cover in **Confidence** and stop.

### Definition of Done
- `## Reply` written through `shepherd-reply <file>|-` (on your PATH; it checks the four labels and records the delivery), then `shepherd-status done "<one line>"`.
- Every path, commit, branch and PR the reply names is real at the lane's head.
- The lane's `git status --porcelain` is empty, and no ref on `origin` was created from the lane.

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

## Reply
<written by shepherd-reply: the four parts of the Answer bar. Retro posts this section as the response>
