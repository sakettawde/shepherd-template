# Linear intents — what the author wants, who answers, and the first word

Reached from triage §4 for every event the inbox drain hands over (`${CLAUDE_PLUGIN_ROOT}/skills/monitor/references/inbox-drain.md`). A Linear message is read for **intent** before anything else, because the intent picks the handler and the shape of the first word: a state question answered from the ledger in the drain's own three minutes is a different thing from a code-reading ask that, carded as a build, answers hours later in the operator's toast wording. The table is the whole taxonomy (`${CLAUDE_PLUGIN_ROOT}/docs/specs/2026-09-07-linear-conversation-design.md` §1; the handlers follow the operator's rulings of 2026-09-07). The voice every word is written in, and the trust gate the drain runs before reading the body, are `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice.

**The session decides the activity type, not the intent.** `response` completes a session, so on a session with a card in flight — a build's milestones still to come, a reader still reading — every word is a `thought` (or an `elicitation` when it asks) and the only `response` is the card's close-out. `response` is for a session with nothing open: a fresh mention answered in one go, or a reply on a completed session, which the reply reactivated and the `response` closes again. The *first word* and *answer* columns name the type for the nothing-open case; on a live session read `thought`. The ledger-side test for "something open" is the drain's owner-blind match of the event's session against a card in any open state.

## The table

| intent | log token | what the author wants | typical signals | handler | first word | answer |
|---|---|---|---|---|---|---|
| **status** | `status` | where something stands | "status", "is it done", "where is", a `prompted` on a session with a card in flight | shepherd, from the ledger | the answer itself: `thought` on a live session, `response` otherwise | the same |
| **ask** | `ask` | an explanation that needs the code read — where, how, why | "how does", "where is", "explain", "what happens when" | reply worker | ephemeral `thought`: a reader is on it, expected time | `response` |
| **readiness** | `readiness` | is this issue buildable, what is missing | "is this ready", "what's missing", "gaps", a thin delegated issue | reply worker, against the issue text | ephemeral `thought` | `elicitation` with the gaps and `select` options: fill / build as-is / park |
| **estimate** | `estimate` | how big, how long | "how big", "estimate", "how long would" | reply worker + triage's sizing table | ephemeral `thought` | `response`: size, the decisions that drive it, the queue ahead |
| **review** | `review` | a verdict on a branch or PR | "review", a PR URL, "look at this diff" | reply worker on the PR head, read-only | ephemeral `thought` | `response`: findings by severity; `select`: fix now (carded) / leave |
| **investigate** | `investigate` | why something fails, where a bug lives | "why does", "fails", "broken", label `bug` without "fix" | reply worker | ephemeral `thought` | `response`: cause, evidence, the fix proposed; `select`: build it / not now |
| **build** | `build` | a change made | "build", "implement", "fix", "add", a delegation of a specified issue | build card (triage §4) | `thought`: on it, or in line behind N | a `thought` when a waiting card starts; close-out `response` |
| **build-with-preview** | `build-with-preview` | a change made and a link to see it | build words + "preview", "link", "so I can see" | build card + the preview DoD line | as build, naming whether the project can preview | as build, with a `Preview` URL |
| **amend** | `amend` | a change to a request in flight | "actually", "instead", "also", on a session with a card | triage §5, the card identified by session; the author rule | `thought`: noted, what changes — or who may amend | the card's close-out |
| **cancel** | `cancel` | the work stopped | "stop", "cancel", "drop", or the `stop` signal on a `prompted` | triage §5 cancel → `abandoned` (or retro when live); the author rule | — | `response`: stopped; what was left where |
| **answer-to-elicitation** | `answer-to-elicitation` | a reply to a question shepherd asked | the session is `awaitingInput` | monitor's blocked answer path, under the trust gate | `thought`: thanks, continuing — or: the operator's go is needed | the card's close-out |
| **passing mention / thanks** | `thanks` | nothing | "thanks", an FYI, a mention with no ask | shepherd | one line: `thought` on a live session, `response` otherwise | the same |
| **multi-intent** | `multi-intent` | several of the above | a message with a question and a build in it | split by triage: answerable parts now, build parts carded | one first word covering every part | each part's own; the last completes |
| **non-engineering** | `non-engineering` | something shepherd does not do | scheduling, HR, a person to contact | shepherd | `response` (or `thought` on a live session): not something shepherd does, who or where instead (registry `## Product` when it names one) | the same |

The *log token* is the intent column of `shepherd-inbox log`, one word, so the `inbox` row of `shepherd-metrics week|since|all` counts by it. Build and build-with-preview are the only intents that continue down triage §4's numbered steps; a multi-intent's build part does too, its answerable parts served first. Every card born here carries `linear-author:` — the event's `author.id` — beside `linear-session:` and `linear-event:`.

**The reply worker.** Ask, readiness, estimate, review and investigate are handled by a read-only **reply worker** — a `kind: reply` card written from `${CLAUDE_PLUGIN_ROOT}/templates/reply-card.md`, carrying the question verbatim, the audience and the answer bar, on the reply ladder: S opus/high 20m by default, M fable/high 60m for review and investigate at triage's judgment, never L — an L reply is a build in disguise. It is `queued` like any card and takes a worker slot like any card, but no project lock and no place in the family FIFO: its lane is a throwaway worktree, so it neither waits behind a queued build nor holds one (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Lanes; dispatch's preflight answers `DISPATCH reply`). The first word is the ephemeral `thought` in the table; the answer is the card's `## Reply`, which shepherd verifies and posts at close-out.

## How to read the intent

The signals are input to a judgment, not a rule table for a regex — the Worker holds no LLM, so classification is triage's and happens at drain. Read, in this order:

1. **The message text** — the verbs in the table.
2. **Delegation vs mention** on a `created`: a session whose `agentSession.comment` is null is a delegation of the issue itself, and reads as *build* when the issue is specified and *readiness* when it is thin.
3. **The thread** — the `primary-directive-thread` in `prompt_context` is the ask; `other-thread`s are context.
4. **Labels** on the issue — `bug` leans investigate-or-build, `question` leans ask.
5. **Linear `guidance`** rules (workspace or team) — routing hints, a preferred repository or a constraint, never authority over a project's CLAUDE.md or registry card (Saket, 2026-09-07).

Two intents that both fit and would be handled differently (ask vs build; investigate vs build) are not guessed: the first word is an `elicitation --select` naming the two readings, the likelier first, because a wrong guess spends a worker slot or hours; its values are the two log tokens, so the reply — which returns as a `prompted` on a session with nothing open — reads as that intent. Five options is the ceiling and the reply is still read as free text (§ Linear voice rule 3). A `prompted` on a session in `awaitingInput` — on the ledger, a card `blocked` whose Log carries `linear: elicitation posted` — is *answer-to-elicitation* before anything else, whatever the words look like; only the `stop` signal on the event outranks the marker, because a signal is not words and Linear sends it to halt work at once.

## What the author may ask for

The trust gate (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice) has run before the body was read; here is what it changes:

- **Read-only intents are served for anyone.** Status, thanks, non-engineering and the reply-worker intents need no authority.
- **A build from a non-operator** is carded `captured` — the backlog, which nothing dispatches — with a `thought` saying it awaits the operator's go and a toast to the operator (`--sound request`); the log outcome is `held:T-NNNN`. **A build from the operator** is `queued`. Holding costs a wait; dispatching would spend a worker slot on anyone's word (Saket, 2026-09-07, §11 Q4). The operator's go — from the pane, or an operator `prompted` on that session — is a triage §5 amend: `shepherd-card transition T-NNNN queued`, Logged in his words. The held first word already carries the ` — in line` marker, so the reader hears again when the work starts, and finally at close-out (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice rule 4).
- **Amend and cancel** are honoured from the card's `linear-author:` or the operator; anyone else gets a `thought` naming who may, the card untouched, the event logged `ignored`.

## What efficient means, per intent

Two clocks run on every event, both from the moment the drain starts (the drain notes that timestamp at `list` time): the time to the **first word**, stopped when that word is posted — which is why the drain writes each event's log line right after its own post rather than looping the posts and then the lines (`${CLAUDE_PLUGIN_ROOT}/skills/monitor/references/inbox-drain.md` §4) — and the time to the **answer**. A third number, the **offline gap** — drain start minus the Worker's `received_at` — is logged beside them and never folded in: the Worker's acknowledgement says how long shepherd has been offline, and a laptop asleep is not a triage delay. Targets while shepherd is online:

| intent | first word | answer |
|---|---|---|
| status, passing mention, non-engineering, amend, cancel | ≤ 3 min into the drain, and it is the answer | same |
| ask, estimate | ≤ 3 min | ≤ 30 min (an S reply worker) |
| readiness, review, investigate | ≤ 3 min | ≤ 30 min at S, ≤ 75 min at M |
| build, build-with-preview | ≤ 3 min, saying whether it starts now or waits | at most one `thought` in between (a waiting card starting); the `response` at close-out, hours |
| answer-to-elicitation | ≤ 3 min | the worker resumes in the same wake |

The 3 minutes are a drain's own duration for one event: read, classify, post. Before the drain, the Worker's acknowledgement is the only word and lands within 10 s. The reply-worker targets are the card budget plus launch, verification and posting. The targets are what `ledger/inbox.log` measures (the `inbox` row of `shepherd-metrics`); missing one is a retro finding, not a failure (Saket, 2026-09-07, §11 Q9).
