# Linear conversation design (T-0235, 2026-09-07)

Design, 2026-09-07. Approved by Saket the same day with one change (§6: teacher-portal has no
preview mechanism, and a project without one says where the change now lives); §11 records every
ruling.

A message from Linear reaches shepherd-collie through the shepherd-inbox Worker and, today, runs
through the same five-way triage as a pane message: a state question gets a one-line answer, and
anything that needs the codebase read becomes a build card that queues behind builds and answers
hours later in the operator's toast wording. Between the card `thought` and retro's `response` the
session is silent and shows `stale`; a `prompted` reply is never acknowledged; a plain comment reply
arrives with no session and cannot be answered; `shepherd-inbox` sends `action` activities in a shape the
Worker rejects; the Worker's external-URL endpoint has no shepherd verb.

This document makes the Linear thread a conversation with a considerate engineering collaborator
while keeping shepherd thin. Four rulings are settled and not reopened (Saket, 2026-09-07,
decisions/2026-09-shepherd-huntaway.md): the responder for code-reading asks is a **read-only reply
worker**; the voice is **reader-first with milestone progress**; the scope is the **full phased
program**; **Saket's Linear identity is the operator**. Two boundaries survive every section:
**shepherd never reads a project's code in its own context**, and **the Worker never calls an LLM**.

Basis lines follow `${CLAUDE_PLUGIN_ROOT}/templates/decision.md`, one per decision: a URL with its read date where
CLAUDE.md §2 rule 11 fires, `uncited — <the trigger that did not fire>` where it does not.

## 0. What the design rests on

- **Linear** opens an agent session on a mention or a delegation and sends `AgentSessionEvent`
  webhooks: `created` (mention or delegation) and `prompted` (a new message in a session). The
  receiver answers within 5 s and, on `created`, posts an activity or updates the external URL
  within 10 s or the session shows unresponsive. Activities are `thought`, `elicitation`, `action`
  (`action`, `parameter`, `result`), `response`, `error`; `thought` and `action` may be
  `ephemeral`, which "should disappear after the next agent activity". Linear manages the six
  session states from the last activity — `pending`, `active`, `error`, `awaitingInput`,
  `complete`, `stale`: `response` completes, `elicitation` awaits input, thirty idle minutes make a
  session stale and any later activity revives it. An agent may open a session itself, on an issue
  or on a root comment (https://linear.app/developers/agent-interaction,
  https://linear.app/developers/agent-best-practices, and the SDK schema at
  https://raw.githubusercontent.com/linear/linear/master/packages/sdk/src/schema.graphql, all read
  2026-09-07).
- **The Worker** (`collie-inbox`, repo `sakettawde/shepherd-inbox`; its README holds the endpoint
  table) stores `created`, `prompted` and `comment_reply` (the last with no session id), posts one
  canned `thought` on `created` only, and stores the whole webhook as `raw` — the author survives
  only there. Its activity endpoint **already accepts** `{type: action, action, parameter,
  result}`; the rejected shape comes from `shepherd-inbox`, which sends `{type, body}` for every type
  (Worker `src/sessions.ts` and `shepherd-inbox cmd_activity`, read 2026-09-07). Its
  comment filter keeps only replies whose parent comment the app authored.
- **Shepherd** arms `shepherd-inbox watch 21600` at wake, drains through
  `.claude/skills/monitor/references/inbox-drain.md`, triages each event as a pane message, posts
  the post-back matrix's activity, acks, and completes the session from retro step 4.

## 1. Intents

Triage stays the one intake (§8 keeps the no-fifth-skill constraint); what changes is that a Linear
message is first read for **intent**, and the intent picks the handler and the shape of the first
word. The table is the whole taxonomy; `.claude/skills/triage/references/linear-intents.md` will
carry it, and triage §4's Linear branch will point there.

**Which activity type a word takes is decided by the session, not the intent.** `response`
completes a session, so on a session with a card in flight — a build's milestones still to come,
a reply worker still reading — every word is a `thought` (or an `elicitation` when it asks), and
the only `response` is the card's close-out. `response` is used where nothing is open on the
session: a fresh mention answered in one go, or a `prompted` on a session already complete, which
that reply reactivated and the `response` closes again. The table's "first word" and "answer"
columns name the type for the session-with-nothing-open case; on a live session read `thought`.

| intent | what the author wants | typical signals | handler | first word | answer |
|---|---|---|---|---|---|
| **status** | where something stands | "status", "is it done", "where is", a `prompted` on a session with a card in flight | shepherd, from the ledger | the answer itself: `thought` on a live session, `response` otherwise | the same |
| **ask** | an explanation that needs the code read — where, how, why | "how does", "where is", "explain", "what happens when" | reply worker | ephemeral `thought`: a reader is on it, expected time | `response` |
| **readiness** | is this issue buildable, what is missing | "is this ready", "what's missing", "gaps", a thin delegated issue | reply worker, against the issue text | ephemeral `thought` | `elicitation` with the gaps and `select` options: fill / build as-is / park |
| **estimate** | how big, how long | "how big", "estimate", "how long would" | reply worker + triage's sizing table | ephemeral `thought` | `response`: size, the decisions that drive it, the queue ahead |
| **review** | a verdict on a branch or PR | "review", a PR URL, "look at this diff" | reply worker on the PR head, read-only | ephemeral `thought` | `response`: findings by severity; `select`: fix now (carded) / leave |
| **investigate** | why something fails, where a bug lives | "why does", "fails", "broken", label `bug` without "fix" | reply worker | ephemeral `thought` | `response`: cause, evidence, the fix proposed; `select`: build it / not now |
| **build** | a change made | "build", "implement", "fix", "add", a delegation of a specified issue | build card (triage §4) | `thought`: carded, queue position | milestone `thought`s; close-out `response` |
| **build-with-preview** | a change made and a link to see it | build words + "preview", "link", "so I can see" | build card + the preview DoD line (§6) | as build, naming whether the project can preview | as build, with `externalUrls` Preview |
| **amend** | a change to a request in flight | "actually", "instead", "also", on a session with a card | triage §5, the card identified by session; §4's author rule | `thought`: noted, what changes — or who may amend | the card's close-out |
| **cancel** | the work stopped | "stop", "cancel", "drop", or the `stop` signal on a `prompted` | triage §5 cancel → `abandoned` (or retro when live); §4's author rule | — | `response`: stopped; what was left where |
| **answer-to-elicitation** | a reply to a question shepherd asked | the session is `awaitingInput` | monitor's blocked answer path, under §4's trust gate | `thought`: thanks, continuing — or: the operator's go is needed | the card's close-out |
| **passing mention / thanks** | nothing | "thanks", an FYI, a mention with no ask | shepherd | one line: `thought` on a live session, `response` otherwise | the same |
| **multi-intent** | several of the above | a message with a question and a build in it | split by triage: answerable parts now, build parts carded | one first word covering every part | each part's own; the last completes |
| **non-engineering** | something shepherd does not do | scheduling, HR, a person to contact | shepherd | `response` (or `thought` on a live session): not something shepherd does, who or where instead (registry `## Product` when it names one) | the same |

**How triage reads the intent.** The signals are input to a judgment, not a rule table for a
regex — the Worker holds no LLM, so classification is triage's and happens at drain. Triage reads,
in this order: the message text (the verbs above); **delegation vs mention** — a `created` whose
`agentSession.comment` is null is a delegation of the issue itself and reads as *build* when the
issue is specified and *readiness* when it is thin; the **thread** — the `primary-directive-thread`
in `promptContext` is the ask, `other-thread`s are context; **labels** on the issue (`bug` leans
investigate-or-build, `question` leans ask); Linear **`guidance`** rules (workspace or team) as
routing hints — a preferred repository, a constraint — never as authority over a project's
CLAUDE.md or registry card (§11 Q8). Two intents that both fit and would be handled differently
(ask vs build; investigate vs build) are not guessed: the first word is an `elicitation` with
`select` naming the two readings, because a wrong guess spends a worker slot or hours. A
`prompted` on a session in `awaitingInput` is *answer-to-elicitation* before anything else.

**Basis (Linear facts).** https://linear.app/developers/agent-interaction (read 2026-09-07) — the
`promptContext` structure (`issue`, `primary-directive-thread`, `other-thread`, `guidance`), the
delegation-vs-mention distinction on `created`, `agentActivity.body` on `prompted`, `response`
completing the session; https://linear.app/developers/agent-signals (read 2026-09-07) — `select`
and `stop`.

**Basis (the taxonomy and the handlers).** uncited — Saket's word in the pane, 2026-09-07, listing
the kinds a comment can be; the handlers follow the four rulings.

**What "efficient" means, per intent.** Two clocks run on every event, both from the moment the
drain starts: the time to the **first word** and the time to the **answer**. A third number, the
**offline gap** (drain start − the Worker's `received_at`), is logged beside them and never folded
in: the Worker's acknowledgement says how long shepherd has been offline, and a laptop asleep is
not a triage delay. Targets while shepherd is online:

| intent | first word | answer |
|---|---|---|
| status, passing mention, non-engineering, amend, cancel | ≤ 3 min into the drain, and it is the answer | same |
| ask, estimate | ≤ 3 min | ≤ 30 min (an S reply worker, §2) |
| readiness, review, investigate | ≤ 3 min | ≤ 30 min at S, ≤ 75 min at M |
| build, build-with-preview | ≤ 3 min, naming the queue position | a `thought` at every card transition; the `response` at close-out, hours |
| answer-to-elicitation | ≤ 3 min | the worker resumes in the same wake |

The 3 minutes are a drain's own duration for one event: read, classify, post. Before the drain, the
Worker's acknowledgement is the only word and lands within 10 s of `created`; §5 adds the same on
`prompted`. The reply-worker targets are the card budget plus launch, verification and posting.
The targets are what §7's log measures; missing one is a retro finding, not a failure.

**Basis.** uncited — no third party; the numbers follow from the reply budgets in §2 and the drain's
own steps.

## 2. The `reply` worker kind

A second kind of work a worker can do: read a project and answer a question, changing nothing.
Everything a build card carries that presumes a diff is dropped; what an answer needs is added.

### Card shape

`kind: reply` is a new header field under `project:`; absent reads as `build`, which every existing
card is. On a reply card:

- `branch: none` — there is no branch. The lane is a worktree **detached** at the dev branch head
  (or at the PR head for *review*), and nothing is ever committed there.
- `touch-areas: none — read-only`; `parallel-safety: independent — writes nothing and shares no
  lock`. Both stay as fields so dispatch's gates parse them, and the values say why they are moot.
- `size: S` and `tier: standard` by default — opus/high on the `tiers:` ladder, `budget: 20m`;
  *review* and *investigate* may be sized `M` at triage's judgment (fable/high, `budget: 60m`).
  Never `L`: an L reply is a build in disguise. (§11 Q2.)
- `linear-author: <Linear user id>` under `linear-event:`, written by the drain on every
  Linear-born card, reply or build — §4's amend and cancel rule compares against it.
- The Brief keeps `### Objective`, `### Why`, `### Context` and `### Status protocol`, drops
  `### Out of scope` and the DoD-as-command, and adds four sections: **`### Question`** — the text
  as asked, verbatim, with the issue identifier, the thread and the author's name (role unknown);
  **`### Audience`** — who reads the reply and what they can be assumed to know (the author, a
  member of the workspace, not necessarily an engineer of this repo); **`### No code changes`** —
  the hard line: nothing edited, nothing committed, no branch, no push, no deploy, no service
  started that writes; **`### Answer bar`** — the four parts every reply carries (below).
- The brainstorming bullet stays, worded for a spike: the brainstorm's output is the reading of
  the question, in conversation, with no design document — the reply session has no `Write`.
- `### Definition of Done` is checkable without a command: `## Reply` written through
  `shepherd-reply`; every path, commit, branch and PR the reply names is real; the lane's
  `git status --porcelain` is empty; no ref on `origin` was created from the lane.
- `## Handoff` is dropped. A reply that outruns its budget fails and is re-briefed with a narrower
  question; half an answer is not handed off.

**Basis.** uncited — repo-internal design, no third party; the field set follows the task-card
template and dispatch-preflight's gates, which parse `parallel-safety:` and `touch-areas:` on every
card.

### Lane

Dispatch step 0 creates it, through `shepherd-lane T-NNNN`: a detached worktree at
`<project-path>-reply-T-NNNN`, `clone-seed:` applied as for a clone. It sits at the dev branch's
**tip**, not at `origin/<dev-branch>` unconditionally — the remote ref is wrong whenever the local
branch is ahead of it, which the self-repo's is routinely
(docs/incidents/2026-09-02-stale-clone-tip.md); `--tip origin/<head>` puts a *review*'s lane on
the PR head instead.
It takes **no** `project-<slug>` lock: that lock serialises writers to one working copy, and a reply
lane is its own disposable copy that nothing else will ever read. It is **not** a clone in the
registry's sense — no `## Clones` row, no `~N` id — and **a reply card is not in the project's
FIFO**: it neither waits behind an older queued build nor holds a build behind it, and it is
excluded from the active siblings a build's lane gates consider. It **does** take one slot under
`worker-cap`: a Claude session is a Claude session, and the pane counts exactly as any other in
`active_pane_count`. Two reply lanes on one project at once are fine; a reply lane beside a build
lane is fine; the only bound is the cap. Retro removes the worktree.

`shepherd-preflight` gains a `kind: reply` branch: state, owner, depends-on and
`onboarded` unchanged; the family-FIFO check skipped; the working-agreement check unchanged (the
worker still reads the project's CLAUDE.md); lane selection and the three lane gates skipped; no
lock acquired; the slot claimed as today. `DISPATCH reply` is the verdict line, and the build
branch's sibling scan skips `kind: reply` cards.

**Basis.** uncited — repo-internal; `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Lanes defines what the lock, the clone
table and the family FIFO are for, and none of the three purposes applies to a copy nothing writes.

### Launch

The R3 line with three additions, exact rules in the settings the implementer writes:
`--disallowedTools Edit Write NotebookEdit` (a bare tool name removes the tool from the session);
deny rules for the write verbs in the forms workers type — `git push`, `git commit`, `git -C`,
`wrangler` and `npx wrangler`, the project's deploy script — deny outranking every allow rule at
every settings level; and `SHEPHERD_WORKER_KIND=reply` in the env, on which the user-global git
guardrail hook refuses any push, commit or deploy verb outright (exit 2 outranks an allow rule).
Plan mode is **not** used: `--permission-mode plan` blocks edits, but it ends in an approve-the-plan
prompt that a pane worker cannot answer and the watchers cannot see.

What each layer guarantees, honestly: the detached worktree with no branch guarantees that
**nothing lands** — a stray local write is discarded with the worktree; the permission rules and
the hook are speed bumps against **egress** (a push of the detached HEAD, a deploy), which quoting,
`eval` and wrappers can get past exactly as CLAUDE.md §6 says of the guardrail. Verification below
therefore checks the remote, not only the lane.

**Basis.** Third party: https://code.claude.com/docs/en/permissions (read 2026-09-07) — "A bare
tool name like `Bash` removes the tool from Claude's context entirely"; "Rules are evaluated in
order: deny, then ask, then allow"; "If a tool is denied at any level, no other level can allow
it"; Bash rules "match the whole command text, with `*` standing in for any text";
https://code.claude.com/docs/en/cli-reference (read 2026-09-07) for `--disallowedTools` and
`--permission-mode` values; https://code.claude.com/docs/en/permission-modes (read 2026-09-07) —
"Approving a plan exits plan mode", the prompt a pane cannot answer
(docs/incidents/2026-08-15-askuserquestion-dialogs.md).

### Persona and the reply format

**Amended 2026-09-08** — the word counts below are superseded, and so are parts 2 and 4 of the list: *What I checked* is now a bare reference list with no prose, and *Next step* is one sentence (§ Amendment — 2026-09-08).

The Brief's persona line: *a considerate engineering collaborator, writing to a colleague whose
role you do not know.* `## Reply` has four parts, in this order, and is what gets posted:

1. **Answer** — leads; the thing asked, in plain words, ≤ 120 words.
2. **What I checked** — the files, commits, commands and PRs read, each a real reference at the
   lane's head. This list is shepherd's verification checklist (below).
3. **Confidence** — high, medium or low, and the one fact that would change it.
4. **Next step** — one offer. Where it is a choice, a short list of options; shepherd turns them
   into a `select` elicitation.

Whole reply ≤ 250 words. Anything the worker wants to record beyond it goes in its final message,
which the status file keeps; nothing else is written anywhere.

**Basis.** uncited — the voice ruling (Saket, 2026-09-07) and docs/writing-for-agents.md; the 250
is a judgment about a Linear thread that no source settles.

### Delivery

A worker cannot use `shepherd-card` (it requires `SHEPHERD_ID`, which the R3 env does not carry) but
already edits its own card directly for `## Handoff`. `scripts/bin/shepherd-reply` mirrors
`shepherd-status`: `shepherd-reply <file>` (or `-` for stdin) replaces the `## Reply` section of
`ledger/tasks/$SHEPHERD_TASK_ID.md` — the card path derived from `SHEPHERD_STATUS_FILE`'s
directory, the same guard on the basename — commits nothing, and appends `event: reply` to the
status file. The worker then reports `shepherd-status done "<one line>"`. Shepherd commits the
card at verification through `shepherd-commit`.

**Basis.** uncited — repo-internal; `scripts/bin/shepherd-status` and the `## Handoff` convention
are the precedents.

### Verification before posting

Shepherd's ladder for a reply, in CLAUDE.md §2 rule 1's order:

1. **Status file** — `claim: done` and an `event: reply`; `## Reply` present on the card with all
   four parts.
2. **Git facts** — the lane's `git status --porcelain` is empty and `git branch --show-current`
   prints nothing (detached); `git ls-remote --heads origin` shows no ref the lane could have
   created (compare against the heads listed at dispatch, recorded on the card's `briefed` Log
   line); then every reference in *What I checked*: a path exists at the lane's HEAD, a sha answers
   `git cat-file -e`, a branch answers `git ls-remote --heads`, a PR answers `gh pr view`. A
   reference that fails is the **lying** row: back to the worker with the fact, once; twice →
   `failed`, and the reader is told honestly what could not be answered.
3. **No DoD command** — there is nothing to run.
4. **Pane tail** — prompt UI, errors; downgrades only.

What shepherd **trusts**: the interpretation, the reasoning and the confidence — reading the code to
second-guess them is exactly the boundary this design keeps. What shepherd **checks** is that
every fact the reader could click on is real, because a wrong path or a phantom PR in a reply is
what turns a collaborator into noise.

**Basis.** uncited — repo-internal; the ladder is CLAUDE.md §2 rule 1 applied to a card with no
diff.

### Close-out

Retro posts `## Reply` as the `response` (§3's footnote appended), adds `externalUrls` for any PR
or branch the reply names, removes the worktree, retires the pane, writes the metrics and the
inbox-log line, and releases nothing — there was no lock. A reply card never merges.

## 3. Voice

**Amended 2026-09-08** — rules 1, 4, 5 and 7 below are superseded (§ Amendment — 2026-09-08).

Every activity shepherd posts to Linear follows these rules; `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice
will carry them, and triage, monitor and retro point there.

1. **Write for the author.** The name from the event's `author` (§4), role unknown: plain words,
   the project's own nouns, and none of shepherd's — no card, lane, worker, tier, watcher or
   `T-NNNN` in the body, the footnote of rule 6 excepted. Saket is named only where the operator is
   being asked.
2. **Lead with the answer or the state**, then what was checked, then the one next step offered.
3. **One activity type per beat**, the session deciding between `thought` and `response` (§1).
   `thought` — progress the reader can see; `elicitation` — a question that pauses the work, with
   `signal: select` and `signalMetadata.options` (`label`/`value`) whenever the answers are
   enumerable, the recommended one first and, as shepherd's own ceiling, no more than five — and
   the reply is still read as free text, because the reader may type instead of picking;
   `action` — a verification and its result: at review shepherd posts one `action` per DoD command
   it ran (`action`: what was run, `parameter`: the command, `result`: one line), so *what was
   checked* is on the thread without prose (§11 Q7); `response` — the last word, once; `error` —
   only when the request could not be processed at all (a refusal stays a `response`).
4. **Milestones.** A `thought` at every card transition, in the reader's words: `queued` — "in
   line behind N; the work ahead adds up to about …" (the sum of the budgets ahead, nothing
   finer); `briefed`/`working` — "started"; `review` — "checking it"; `done`/`failed`/`abandoned`
   — the `response`. While `working`, a progress `thought` at a monitor heartbeat **only when there
   is news** (commits landed, a plan approved, a question answered), marked `ephemeral` so each
   replaces the last instead of piling up (§11 Q3). Between milestones a long build's session may
   still read `stale`; the next milestone revives it, and the reader sees the last real state
   rather than a keep-alive.
5. **The close-out `response`** carries what changed (behaviour, not files), where to see it (links
   in the body **and** `externalUrls` labelled `Branch`, `PR`, `Preview` — or, on a project with
   `preview: none`, where the change now lives, §6), and what happens next (merged, awaiting a
   deploy, needs a decision). Failed and abandoned get the same shape with the
   honest outcome and what was left where.
6. **Footnote, never headline.** The last line of every `response` is `— shepherd-<id> · T-NNNN`.
7. **Length.** ≤ 250 words per activity; more belongs behind a link (the PR description).
8. **Never** a secret, a token, or a path outside the repository.

Rendering of `externalUrls`: the docs say they let users "open the current session on your web
dashboard" and show one "Open" button; how several labelled URLs render together is not
documented, which is why rule 5 repeats the links in the body — the reader has them either way.

**Basis (Linear facts).** https://linear.app/developers/agent-signals (read 2026-09-07) — `select`
options as `label`/`value`, "your agent should always involve an LLM when interpreting the
prompt", free text dismisses the elicitation; https://linear.app/developers/agent-interaction
(read 2026-09-07) — `action` fields, `ephemeral` on `thought`/`action` only, external URLs opening
the session on the provider's dashboard; the SDK schema (read 2026-09-07) — `ephemeral: "should
disappear after the next agent activity"`, `addedExternalUrls`.

**Basis (the rules).** uncited — Saket's ruling in the pane, 2026-09-07; the five-option ceiling and
the 250 words are shepherd's judgment.

## 4. Trust model

The inbox authenticates the workspace; the **author** is Linear's assertion inside a signed
webhook, and Saket's Linear user id is the operator. Everyone else is input.

**What the Worker carries.** Every event served by `GET /inbox` carries
`author: {id, name, operator}`: on `created` from `agentSession.creatorId` / `creator`; on
`prompted` from `agentActivity.userId` / `user`; on `comment_reply` from `data.userId` (the
envelope `actor` is the fallback). A missing author is `{id: null, name: null, operator: false}`.
The `prompted` session upsert stops nulling `creator_id` on the way.

**What the Worker exposes.** `GET /health` gains `operator_ids: [...]`, read from a wrangler var
`OPERATOR_LINEAR_USER_IDS` (comma-separated; a Linear user id is not a secret, and a plain var is
visible in the repo, which is where a later workspace's operator is set). The value is Saket's own
Linear user id — the `author.id` the Worker serves on Saket's next mention, or `viewer { id }`
under Saket's own API key — and Saket supplies it for the C1 deploy. `author.operator` is the
Worker's comparison against the list — a fact it reports, not a decision it takes. An empty list is
the old world: every author reads `operator: false`. (§11 Q5.)

**What shepherd checks.** `shepherd-inbox list` surfaces `author`; the drain reads `author.operator`
before it reads the body, and writes `author.id` to `linear-author:` on any card it makes;
`shepherd-inbox owner` (and the wake report's `INBOX` line) says whether `operator_ids` is empty, once,
so an unconfigured Worker is visible rather than silently default-deny.

**How CLAUDE.md §4 applies, unchanged.** The escalation table decides what needs the operator; the
channel decides nothing.

- An **operator-authored** reply to an escalation posted as an `elicitation` is a pane answer: the
  decision is logged (`Basis: uncited — Saket's word in Linear <session>, <timestamp>`), the worker
  is unblocked with one R4 line, no pane round-trip, a `thought` confirms on the thread.
- A **non-operator** reply to an escalation is input: shepherd reads it, posts an ephemeral
  `thought` saying the operator's go is needed, and toasts Saket with the reply quoted; the card
  stays `blocked`. Input is not ignored — the reply may carry the fact that decides the case once
  Saket says yes.
- A reply to a **non-escalation** question — a clarification shepherd or the worker asked the
  requester, anything in §4's left column — is the requested input from whoever the question was
  addressed to, and shepherd decides as it would in the pane. The left column never needed
  authority; only the right column does.
- **Build asks from non-operators** (§11 Q1): read-only intents are served for anyone; a build
  from a non-operator is carded `captured` with a `thought` saying it awaits the operator's go and
  a toast to Saket; a build from the operator is `queued`.
- **Amend and cancel** are honoured from the card's `linear-author:` or the operator; anyone else
  gets a `thought` naming who may, and the card is untouched.

**Fallback.** A Worker that does not yet carry `author` (before C1 lands) keeps today's rule:
every Linear ruling is confirmed in the pane.

**Residual risk.** The author id is as trustworthy as the operator's Linear account — the same
class of risk as the operator's laptop, and accepted.

**Basis (Linear facts).** https://linear.app/developers/webhooks (read 2026-09-07) — the
`Linear-Signature` HMAC and the `actor` envelope field (`id`, `type`, `name`, `email`, `url`);
the SDK schema (read 2026-09-07) — `AgentSession.creator` "The human user responsible for the
agent session", `AgentActivity.user` "The user who created this agent activity"; the Worker's
`src/linear-types.ts` and fixtures (read 2026-09-07) for where each id sits in `raw`.

**Basis (the model).** uncited — Saket's ruling in the pane, 2026-09-07, that his Linear identity is
the operator; the non-operator build hold is §11 Q1.

## 5. Worker-side contract

A list the shepherd-inbox card implements; the Worker stays LLM-free.

- **W1 — acknowledge `prompted`.** Post an `ephemeral` `thought` in the `created` ack's shape and
  timing ("Got it — shepherd was last online N min ago; it picks this up on its next check");
  ephemeral so shepherd's first real word replaces it.
- **W2 — the author on every event** (§4), and the `prompted` upsert no longer nulls
  `session.creator_id`.
- **W3 — `operator_ids` on `/health`** from `OPERATOR_LINEAR_USER_IDS`; `author.operator` stamped.
- **W4 — answerable comment replies.** Verified live: an agent may open a session itself —
  `agentSessionCreateOnComment` ("Input for creating an agent session on a root comment") and
  `agentSessionCreateOnIssue` exist. The comment filter **widens**: today it keeps only replies
  whose parent the app authored, and a session's `comment_id` is the user's own mention comment,
  so the two never meet; after C1 a `Comment` webhook is kept when its parent is the app's **or**
  when `data.parentId` is a stored session's `comment_id`. The second case is stored as a
  `prompted` on that session; the first calls `agentSessionCreateOnComment(commentId:
  data.parentId)` and stores the event under the returned session id. Two things are unverified and
  handled by construction: Linear may deliver the thread reply as a `prompted` too, and may emit
  `created` for a self-created session — the handler dedupes on session id plus body within the
  same minute for the first, on session id for the second. A plain `commentCreate` reply stays
  unbuilt: one post-back protocol, one set of session states. (§11 Q4.)
- **W5 — activity passthrough.** `POST /sessions/:id/activity` accepts `signal` and
  `signalMetadata` beside `content` and `ephemeral`; `action` content is already accepted.
- **W6 — external URLs append.** The update sends `addedExternalUrls` instead of `externalUrls`,
  so Branch, then PR, then Preview accumulate on the session across a build.
- **W7 — the `stop` signal.** A `prompted` carrying `signal: stop` keeps it on the stored event, so
  the drain reads it as *cancel* and answers with the required final `response`.
- **W8 — follow-up, not this program:** the `created` ack is skipped when no installation row
  exists, which leaves a session unanswered while the event is inboxed.

**Shepherd-side verbs** (`shepherd-inbox`, the C2 card): `list` prints `author`;
`operators` prints `/health`'s list; `activity <sid> <type> <body> [--ephemeral]
[--select "label=value|…"]`; `action <sid> <action> <parameter> [<result>]` — the fix for the
rejected shape; `urls <sid> <label>=<url>…` for the external-URL endpoint.

**Basis (Linear facts).** https://linear.app/developers/agent-interaction (read 2026-09-07) — "If
your agent was not delegated or mentioned but you would like to proactively create an agent
session, you can do so via the SDK or API with the `agentSessionCreateOnIssue` or
`agentSessionCreateOnComment` mutations"; the SDK schema (read 2026-09-07) —
`AgentSessionCreateOnComment { commentId: String!, externalUrls }`, `AgentActivityCreateInput
{ signal, signalMetadata, ephemeral }`, `AgentSessionUpdateInput { addedExternalUrls }`,
`AgentActivitySignal { auth, continue, select, stop }`; https://linear.app/developers/agent-signals
(read 2026-09-07) — `stop` "instructs the agent to halt work immediately", answered by a final
`response` or `error`.

**Basis (the Worker's current behaviour).** uncited — the Worker's own source, a repo Saket owns.

## 6. Preview support

A registry card field, `preview:`, under `working-agreement:`:

```
preview: none — <why>
preview: <mechanism> — <URL pattern> — by <push|worker|shepherd>
```

`by` names who produces the preview: `push` when the platform builds a preview from the pushed
branch and nobody runs anything; `worker` when the worker runs a preview-only command; `shepherd`
when the deploy is a shepherd action — the worker builds and pushes, shepherd runs the one deploy
command at verification, as it already runs `wrangler deploy` on its allow list, and reads no
code. A **build-with-preview** ask on a project with `preview: none` is answered in the first word —
"this project has no preview; I can build it and link the branch" — and carded as a plain build;
its close-out `response` then says **where the change now lives** — "now merged to dev", "now
live on uat", "now on branch …" — and that wording is the rule for every project whose `preview:`
is `none` (Saket, 2026-09-07). A promotion is never called a preview, and no project's build
pipeline is examined to find one. Elsewhere the Brief's DoD gains one line, *A preview of the
branch is reachable at `<URL>` (HTTP 200, shepherd fetches it) and shows `<the change>`*, and the
close-out posts `externalUrls` `Preview`.

| project | preview | why |
|---|---|---|
| ip-landing-be | `versions upload` on push — `<version>-ip-landing-be.<subdomain>.workers.dev` — by push | branch pushes are versions uploads, preview only (Saket, 2026-08-18, registry); how the preview URL is obtained (build log, `wrangler versions list`) is C5's fact to confirm |
| unsung-everyday-heroes | Pages preview — `<hash>.<project>.pages.dev` / `<branch>.<project>.pages.dev` — by shepherd | preview URL only, no custom domain; shepherd has redeployed it (T-0065, T-0088); the exact deploy command is C5's fact to confirm |
| teacher-portal | none — no preview mechanism; the close-out says where the change now lives (merged to dev, live on uat) | Saket, 2026-09-07: a dev→uat promotion is not a preview and Workers Builds is not examined for one |
| ip-landing | none — main is production, every push deploys | registry, verified 2026-08-18 |
| meru-practicals | none — main and practicals-only are production; deploys are Saket's or shepherd's | registry; a versions-upload preview is possible on Saket's word, a later ruling |
| karta, eo-tech, centralised-identity | unset until onboard's question is asked of Saket (C5) | — |

**Basis (Cloudflare facts).** https://developers.cloudflare.com/workers/configuration/previews/
(read 2026-09-07) — "Preview URLs allow you to preview new versions of your Worker without
deploying it to production", `<VERSION_PREFIX OR ALIAS>-<WORKER_NAME>.<SUBDOMAIN>.workers.dev`,
`wrangler versions upload` "returns a preview URL for each version uploaded";
https://developers.cloudflare.com/pages/configuration/preview-deployments/ (read 2026-09-07) —
`<hash>.<project>.pages.dev` and the branch alias.

**Basis (the per-project rows).** uncited — the registry cards, instance state Saket answered, and
Saket's ruling on teacher-portal in the pane, 2026-09-07; what a row leaves to C5 is named in it.

## 7. Metrics and the watcher fold

**One line per drained event** in `ledger/inbox.log`, whitespace columns in `ledger/events.log`'s
style, committed through `shepherd-commit` with the drain's other commits (§11 Q10):

```
<drain-start> <event-id> <session|none> <kind> <intent> <operator|member|unknown> <outcome> <received-at> <first-word-at>
answered <event-id> <answer-at>
```

`received-at` is the Worker's `received_at`, the one timestamp `GET /inbox` serves. `outcome` is one
of `answered`, `asked`, `carded:T-NNNN`, `routed:T-NNNN`, `held:T-NNNN`, `refused`, `ignored`. The
second line shape is appended by retro when a carded event's `response` posts, so the file stays
append-only. `shepherd-metrics` gains an `inbox` measure: counts by intent and outcome, the
median first-word time and answer time per intent (both from `drain-start`), and the offline gap
(`drain-start − received-at`) as its own number. Retro's weekly mode reads it beside the rest.

**The inbox watcher folds into `shepherd-watch`** as a third kind, `inbox` (T-0223's open item):
`shepherd-watch arm inbox --window 21600` runs `shepherd-inbox watch` as the single process under a per-instance
record `ledger/watchers/inbox.<SHEPHERD_ID>`, so `list` and `check` see it, one process per instance
holds, and a replaced watcher dies like any other. `shepherd-inbox` keeps its exit codes and stays the one
home of the Worker contract; `shepherd-watch` maps them to a first stdout line and its own codes, because
its `3` and `4` already mean `BLOCKED` and `ARMED-ALREADY`: `INBOX WORK` 0, `INBOX TIMEOUT` 124,
`INBOX UNREACHABLE` 6, `INBOX NOT-CONFIGURED` 8, `INBOX AUTH` 1 — the verdict line is what monitor
reads, the codes are what `test-watch.sh` pins. Wake step 8 and monitor's re-arm become that one
command in C3a; C2 ships the kind with `shepherd-inbox watch` still armed directly, so nothing changes
hands until the skills do.

**Basis.** uncited — repo-internal; the verdict-line contract of `shepherd-watch` and the measure
shape of `scripts/lib/metrics.py`.

## 8. Definition assessment

The definition holds — routes, briefs, verifies, decides, records — and gains one clause and one
rule.

- **CLAUDE.md §1**: "dispatch worker Claude Code sessions in herdr panes to do the actual work" →
  "… to do the actual work — building, or reading a project to answer a question —"; and the
  boundary stated outright: *You never read a project's code in your own context; a question that
  needs it goes to a reply worker.*
- **§3**: the intake sentence names intent — *a Linear message is read for intent first
  (triage's Linear table) and answered in the reader's words (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear
  voice); every post to Linear is shepherd's — workers hold no Linear token* — and its
  `shepherd-inbox watch` mention becomes `shepherd-watch arm inbox`.
- **§6**: one bullet — *Reply workers: `kind: reply` cards run on a detached read-only lane, take
  no project lock, sit in no FIFO, count one slot, deliver through `shepherd-reply`;
  `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Reply workers holds the contract and the verification ladder.*
- **§2 rule 3** holds as written: a reply lane is its own working copy.
- **`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md`** gains § Reply workers and § Linear voice (with the trust gate); § Lanes
  gains one sentence saying a reply lane is neither a clone nor in the FIFO.
- **shepherd-inbox's CLAUDE.md** keeps its line: the Worker never calls an LLM.

**No fifth skill.** Intake stays triage (the intent table is a triage reference), the wake handler
stays monitor (the drain reference grows a trust gate and the milestone rule), arming stays wake
(through `shepherd-watch`). The cost a fifth skill would save — the drain reference growing past 100
lines — is smaller than a fifth place to keep in sync.

**Multi-instance routing stays deferred.** It is not load-bearing for efficiency: one instance
serves the inbox and latency is dominated by whether that instance is online, not by which one it
is. Proposal for a later slice, when a second inbox exists: a bearer token per instance and
`shepherd_ids` on `/health`, the Worker partitioning by the session's team — the seam spec §8 of the
wiring design already names.

**Basis.** uncited — the rulings (Saket, 2026-09-07) and docs/specs/linear-inbox-wiring-design.md
§8.

## 9. Changes by home

| home | change | slice |
|---|---|---|
| Worker `src/webhook.ts` | ack on `prompted`; author on every event; comment filter widened and replies resolved to a session or `agentSessionCreateOnComment`, deduped; `stop` signal kept | C1 |
| Worker `src/ack.ts` | the `prompted` acknowledgement text, ephemeral | C1 |
| Worker `src/linear.ts` | `agentSessionCreateOnComment` mutation; `addedExternalUrls` in the update; `signal`/`signalMetadata` in `agentActivityCreate` | C1 |
| Worker `src/sessions.ts` | `signal`/`signalMetadata` accepted on the activity endpoint | C1 |
| Worker `src/inbox.ts`, `src/db.ts`, migrations | `author` columns and output; `creator_id` no longer nulled on `prompted` | C1 |
| Worker `src/linear-types.ts`, `test/fixtures/*` | author and signal fields typed and pinned | C1 |
| Worker `src/index.ts` `/health` | `operator_ids` | C1 |
| Worker `wrangler.jsonc`, README, `test/*` | `OPERATOR_LINEAR_USER_IDS`; endpoint table; tests for W1–W7 | C1 |
| `shepherd-inbox` | `list` prints `author`; `operators`; `activity --ephemeral --select`; `action`; `urls` | C2 |
| `shepherd-watch` | kind `inbox`, per-instance record, `INBOX …` verdict line and codes | C2 |
| `shepherd-metrics`, `scripts/lib/metrics.py` | `inbox` measure over `ledger/inbox.log` | C2 |
| `shepherd-wake-report` | `INBOX` line reports an empty `operator_ids` | C2 |
| `scripts/tests/test-inbox.sh`, `test-watch.sh`, `test-metrics.sh`, `test-wake-report.sh` | the verbs, the kind, the measure, the line | C2 |
| `.claude/skills/triage/SKILL.md` §4 + new `references/linear-intents.md` | the intent table; session decides the type; delegation vs mention; ambiguity → `select`; non-operator builds `captured`; `linear-author:` written | C3a |
| `.claude/skills/monitor/references/inbox-drain.md` | trust gate before the body; intent first; first-word rules; the log line; `stop` → cancel | C3a |
| `.claude/skills/monitor/SKILL.md` | blocked row: operator reply = pane answer, non-operator = input + toast; trigger line and re-arm invariant → `shepherd-watch arm inbox` and its verdicts | C3a |
| `.claude/skills/wake/SKILL.md` step 8 | arm through `shepherd-watch arm inbox` | C3a |
| `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` | § Linear voice | C3a |
| `CLAUDE.md` §3 | the intake sentence; `shepherd-watch arm inbox` | C3a |
| `${CLAUDE_PLUGIN_ROOT}/templates/task-card.md` | `linear-author:` | C3a |
| `scripts/tests/test-docs.sh` | pins: intent table, trust gate wording, voice rules, the arm command (replacing the `shepherd-inbox watch 21600` pins) | C3a |
| `.claude/skills/dispatch/SKILL.md`, `monitor/SKILL.md` transitions, `retro/SKILL.md` step 4 and §5 cancel | milestone `thought`s; `action` per DoD run at review; close-out `response` with `externalUrls`, or the where-it-now-lives line for `preview: none`; the `answered` log line | C3b |
| `CLAUDE.md` §1 | the clause and the boundary | C3b |
| `scripts/tests/test-docs.sh` | pins: milestone posts, close-out shape | C3b |
| `${CLAUDE_PLUGIN_ROOT}/templates/task-card.md`, new `${CLAUDE_PLUGIN_ROOT}/templates/reply-card.md` | `kind:`; the reply card | C4a |
| `shepherd-preflight`, `scripts/tests/test-preflight.sh` | `kind: reply` branch: no lock, no FIFO, no lane gates, slot claimed; siblings skip reply cards | C4a |
| `.claude/skills/dispatch/SKILL.md` step 0 and launch, adapter R3 | reply lane creation; launch flags and `SHEPHERD_WORKER_KIND` | C4a |
| `${CLAUDE_PLUGIN_ROOT}/hooks/worker-git-guardrail.sh`, `scripts/tests/test-guardrail.sh` | reply mode refuses push, commit and deploy verbs | C4a |
| `scripts/bin/shepherd-reply`, `scripts/tests/test-status.sh` | `## Reply` delivery and the `reply` event | C4a |
| `.claude/skills/monitor/SKILL.md`, `retro/SKILL.md` | the reply verification ladder; reply close-out (post, worktree removal, no lock) | C4b |
| `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` | § Reply workers; § Lanes one sentence | C4b |
| `CLAUDE.md` §6 | the reply-worker bullet | C4b |
| `scripts/tests/test-docs.sh` | pins: ladder, close-out, the protocols sections | C4b |
| `${CLAUDE_PLUGIN_ROOT}/templates/registry-card.md`, `.claude/skills/onboard/SKILL.md` | `preview:` field and the onboarding question | C5 |
| `.claude/skills/triage/SKILL.md` | the build-with-preview DoD line | C5 |
| `registry/projects/*.md` (instance state, shepherd's own act at C5's close-out) | `preview:` on the five named projects, three of them `none` | C5 |

## 10. Proposed cards

Each a plan of eight tasks or fewer; `parallel-safety:` symmetric across the set: C1 and C2 are
independent of everything, and every card that edits a skill is `serialized`, which keeps it off a
lane beside any other.

- **C1 — Worker contract** (`project: shepherd-inbox`, M, standard): makes true W1–W7 of §5 with
  tests, deployed by shepherd with Saket's operator id set. `Depends on: none`. `touch-areas:
  webhook handler, ack text, Linear client, activity endpoint, inbox output, event schema,
  health endpoint, Worker config and tests`. `parallel-safety: independent — its own repository;
  nothing in shepherd reads the new fields until C3a`.
- **C2 — inbox verbs, log measure, watcher kind** (`project: shepherd`, M, heavy): makes true
  §5's shepherd-side verbs, §7's `inbox` measure and the `shepherd-watch` `inbox` kind, stub-tested;
  scripts only, no skill or manual edit. `Depends on: none`. `touch-areas: shepherd-inbox, shepherd-watch,
  metrics, wake-report, test-inbox, test-watch, test-metrics, test-wake-report`.
  `parallel-safety: independent — scripts C1 does not share and skills it does not touch; the
  shared contract is the Worker's endpoint shapes, fixed by §5`.
- **C3a — intents, trust gate, voice** (`project: shepherd`, M, heavy): makes true §1, §3 and
  §4 in triage, the drain, monitor's blocked row, wake step 8, protocols § Linear voice and
  CLAUDE.md §3, with test-docs pins and one live round-trip for each shepherd-answered intent
  (status, thanks, non-engineering, a build carded and held) against the deployed C1. `Depends
  on: C1, C2`. `touch-areas: triage skill, monitor skill, wake skill, protocols, CLAUDE.md,
  task-card template, test-docs`. `parallel-safety: serialized — edits the skills every instance
  reads`.
- **C3b — milestones and close-out** (`project: shepherd`, M, heavy): makes true §3 rules 3–6
  across a build's life — dispatch, monitor and retro post the milestone `thought`s, the `action`
  per DoD run, the close-out `response` with `externalUrls`, the `answered` log line — and
  CLAUDE.md §1, with pins and one live build followed on its thread. `Depends on: C3a`.
  `touch-areas: dispatch skill, monitor skill, retro skill, triage skill (§5 cancel), CLAUDE.md,
  test-docs`. `parallel-safety: serialized — edits the skills every instance reads`.
- **C4a — the reply kind: card, lane, launch, delivery** (`project: shepherd`, M, heavy): makes
  true §2's card shape, lane, preflight branch, launch flags, guardrail reply mode and
  `shepherd-reply`, each tested. `Depends on: C3a`. `touch-areas: task-card template, reply-card
  template, dispatch-preflight, dispatch skill, adapter reference, git guardrail hook,
  scripts/bin, test-preflight, test-guardrail, test-status`. `parallel-safety: serialized — edits
  the skills every instance reads`.
- **C4b — reply verification and close-out** (`project: shepherd`, M, heavy): makes true §2's
  ladder and close-out in monitor and retro, protocols § Reply workers, CLAUDE.md §6, with pins
  and one live reply answered on a real issue for each worker-answered intent class (ask, review).
  `Depends on: C4a`. `touch-areas: monitor skill, retro skill, protocols, CLAUDE.md, test-docs`.
  `parallel-safety: serialized — edits the skills every instance reads`.
- **C5 — preview facts** (`project: shepherd`, S, standard): makes true §6 — the registry field,
  onboard's question, triage's DoD line — and confirms the two facts the table leaves open
  (ip-landing-be's preview-URL source, Unsung's deploy command); nothing about teacher-portal is
  examined; shepherd banks the values under their card locks at close-out. `Depends on: C3b`.
  `touch-areas: registry-card template, onboard skill, triage skill`. `parallel-safety: serialized
  — shares the triage skill with C3a/C3b`.

Later, not carded: multi-instance inbox routing (§8); W8.

## 11. Questions for Saket, and the rulings

One round, answered by Saket on 2026-09-07 through shepherd-huntaway. The first three are
refinements of rulings already taken; the rest were open. Each `➡️` was the recommendation; the
**Ruling** line is what holds, and the sections above are written to it.

**Confirmations of the rulings**

1. **Comment replies** (item 5 of the card said: verify whether an agent may open a session, else a
   comment mutation) — an agent may; ➡️ the Worker opens a session on the root comment and a
   plain comment reply stays unbuilt. **Ruling:** accepted.
2. **Where the operator id list lives** (item 4 said the Worker exposes the id or a list) — ➡️ a
   Worker var exposed on `/health`, `author.operator` stamped on every event; Saket supplies his
   Linear user id for the C1 deploy. **Ruling:** accepted.
3. **Progress during long builds** (the milestone-progress ruling) — ➡️ milestones at every
   transition, plus an ephemeral `thought` at a heartbeat only when there is news; a long build's
   session may read `stale` between them. **Ruling:** accepted — milestones plus news-only
   ephemeral progress, no keep-alive.

**Open**

4. **Build asks from non-operators** — dispatch as today, or hold? ➡️ hold: `captured` plus a
   `thought` saying it awaits the operator's go and a toast; read-only intents are served for
   anyone. Holding costs a wait; dispatching spends a worker slot on anyone's word. **Ruling:**
   hold — carded `captured`, a `thought`, a toast; read-only intents served for anyone.
5. **Reply worker ladder** — ➡️ S/standard (opus/high, 20m) by default; M (fable/high, 60m) for
   *review* and *investigate* at triage's call; never L. **Ruling:** accepted.
6. **Previews on teacher-portal** — is a dev→uat promotion ever a "preview" shepherd may run for
   a Linear ask, or does per-branch Workers Builds already give one? ➡️ neither is assumed: C5
   examines the branch→environment mapping and asks again with what it finds; until then
   teacher-portal answers "no branch preview; here is the branch and the PR". **Ruling (Saket):**
   teacher-portal gets no preview mechanism at all — C5 does not examine Workers Builds and a
   dev→uat promotion is never treated as a preview; the close-out `response` says where the change
   now lives ("now merged to dev", "now live on uat"), and that wording is the rule for every
   project whose `preview:` is `none` (§6).
7. **Post shepherd's own DoD runs as `action` activities at review** — ➡️ yes, one per command:
   *what was checked* without prose. **Ruling:** accepted.
8. **Linear `guidance` rules** — ➡️ routing hints only, never authority over a project's CLAUDE.md
   or registry card. **Ruling:** accepted.
9. **The latency targets in §1** — ➡️ adopt as written; measured from the drain's start; the
   offline gap reported separately. **Ruling:** accepted.
10. **`ledger/inbox.log` committed** — ➡️ yes: retro's weekly count runs in the base checkout and
    should survive a machine; `events.log` stays gitignored because it is lock machinery.
    **Ruling:** accepted.

## Sources

- https://linear.app/developers/agent-interaction — read 2026-09-07: `created`/`prompted`, 5 s and
  10 s windows, `promptContext` structure, activity types and fields, `ephemeral`, external URLs,
  `agentSessionCreateOnIssue`/`agentSessionCreateOnComment`.
- https://linear.app/developers/agent-signals — read 2026-09-07: `select` and `auth` on
  `elicitation`, `stop` on prompts, free text dismisses a selection.
- https://linear.app/developers/agent-best-practices — read 2026-09-07: 10-second first response,
  30-minute stale window and its recovery, which type for which beat.
- https://linear.app/developers/webhooks — read 2026-09-07: the envelope, `actor`, the signature.
- https://raw.githubusercontent.com/linear/linear/master/packages/sdk/src/schema.graphql — read
  2026-09-07: `AgentSession.creator`, `AgentActivity.user`, `AgentActivityCreateInput`,
  `AgentSessionUpdateInput.addedExternalUrls`, `AgentSessionCreateOnComment`, the signal and
  status enums.
- https://code.claude.com/docs/en/permissions, https://code.claude.com/docs/en/permission-modes,
  https://code.claude.com/docs/en/cli-reference — read 2026-09-07: deny precedence, bare-name
  removal, Bash rule matching, `--disallowedTools`, plan mode's approval prompt.
- https://developers.cloudflare.com/workers/configuration/previews/ and
  https://developers.cloudflare.com/pages/configuration/preview-deployments/ — read 2026-09-07:
  preview URL shapes.
- shepherd-inbox source, README and design spec §12–§13; `shepherd-inbox`, `shepherd-watch`,
  `scripts/lib/metrics.py`, the triage, monitor, retro, wake and dispatch skills,
  `${CLAUDE_PLUGIN_ROOT}/templates/task-card.md`, `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md`, docs/specs/linear-inbox-wiring-design.md — read
  2026-09-07.
- Saket's rulings, 2026-09-07 — decisions/2026-09-shepherd-huntaway.md.

## Amendment — 2026-09-08

Saket read the first live Linear output and ruled: *"it seems to work great, but it would be great
if the language in the output is more concise … Also simply the English."* §2's reply format and
§3's rules 1, 4, 5 and 7 above are the 2026-09-07 record and are superseded on these five points.
`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice carries the amended rules; this section says what changed and on
whose word (T-0263).

1. **Reply length.** The Answer drops from ≤ 120 to **≤ 80 words**; the whole `## Reply` from
   ≤ 250 to **≤ 150**. Rule 7's per-activity ceiling drops to **150** with it, so one number
   governs every activity — that last part is shepherd's call for consistency, not Saket's word.
   Both read as ceilings, not targets: as few words as the thing needs.
2. **The four labelled parts stay** — Answer, What I checked, Confidence, Next step. *What I
   checked* is now a bare comma-joined list of references with no prose around it; shepherd still
   verifies each one before posting. *Next step* is one sentence.
3. **Fewer milestone posts.** The `review` "checking it" `thought` is dropped everywhere — the
   `action`s posted at review already say what was checked — and with it the reply card's
   exemption from a post that no longer exists. The separate "started" `thought` is posted only
   when the first word said the card was waiting in line. The first word itself stays: it is the
   reader's acknowledgement and what the 3-minute clock measures, and a build can sit queued for
   hours. A build therefore posts at most three prose activities — first word, started (only if it
   waited), close-out. The `action` records at review and the ephemeral heartbeat `thought` are
   unchanged; they are not prose.
4. **Close-out.** The build's close-out `response` is **three lines** — what changed, where to see
   it, what happens next — plus rule 6's footnote. Links stay in the body as well as on
   `shepherd-inbox urls`; rule 5's reason for that repetition is a cited Linear rendering fact
   and does not change.
5. **Plainer English wherever shepherd writes to Linear.** Short sentences, common words, one idea
   per sentence — no semicolon chains, no stacked em-dash asides. Folded into rule 1, which already
   owns how to write for the reader.

**One correction, not a ruling.** §3 rule 4 asserted that a session goes `stale` between milestones
and that the next milestone revives it, and the drain reference put a 30-minute figure on it.
Linear documents neither: `stale` is listed among the six session states with no trigger and no
revival described (https://linear.app/developers/agent-interaction, read 2026-09-08). Both surfaces
now say so instead of asserting it.

**Basis (the rulings).** uncited — Saket's ruling in the pane, 2026-09-08; the 150-word ceiling for
non-reply activities is shepherd's judgment. **Basis (the Linear facts).**
https://linear.app/developers/agent-interaction, read 2026-09-08 — "You don't need to manage agent
session state manually. Linear tracks session lifecycle automatically based on the last emitted
activity", so no activity is owed per state transition and cutting posts breaks nothing; the one
hard requirement is an activity or an external-URL update within 10 seconds of a `created` event,
which the Worker's own acknowledgement already satisfies before a drain runs; the six session
states with `stale` undocumented; and no limit on body length, formatting or the number of
activities, so every word ceiling here is shepherd's alone.
