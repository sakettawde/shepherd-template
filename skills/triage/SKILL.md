---
description: Every incoming message, from the pane or the Linear inbox, becomes an answer, a context note, a question, a task card or an amendment; routes to onboarded projects, sizes, decomposes; never dispatches.
---

# triage

A message carries **one or more of five intake types**: split it, classify each part, bank context before writing a Brief — a Brief written first cites nothing.

## 1. Answer

A question about state, history, a project or a decision → answer from registry, ledger, decisions and memory (the manual §5 cookbook), one line, no task.

## 2. Context ingestion

The operator is sharing knowledge: identify the project (ask if ambiguous); append a dated entry to the registry card's `## Context notes` under `card-<slug>` (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Card lock), committed as `<slug>: context note`; distill durable facts into the project's auto-memory at its `memory-dir:` (retro step 2 holds the stamp rule and the locks). Confirm in one line.

## 3. Clarifying question

Routing or intent ambiguous → ask; never guess the project, name both when two match. Ask in **frontier rounds**: every question askable now in one numbered message, each with a `➡️` recommended answer so one reply settles it; a dependent question waits for the next round. Facts you can look up are never questions.

## 4. Task

**From Linear, intent first.** An event the inbox drain hands over is read for intent through `references/linear-intents.md` before it is typed: the table names the fourteen intents, who answers each, the first word and its target, the reading order, and what the trust gate changes. Only *build*, *build-with-preview* and a multi-intent's build part continue down the steps below; status, thanks, non-engineering and an answer to an elicitation are served from the drain, amend and cancel through §5, and the reply-worker intents become a `kind: reply` card from `${CLAUDE_PLUGIN_ROOT}/templates/reply-card.md`, queued for the reply ladder, with the first word the reference gives. Every word posted follows `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice.

**Shape first.** One thing to change is one card. An **end result**, or a task too big for one worker session, becomes sibling cards through `${CLAUDE_PLUGIN_ROOT}/skills/triage/references/decomposition.md`; each approved slice then returns here.

1. **Route** by `registry/projects.md` keywords. Not `onboarded: yes` → refuse in one line and offer onboarding — never brief a worker into a non-onboarded repo. A second lane while another instance holds the project → a clone, `project: <slug>~N` (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Lanes).
2. **Number** — read every owner's open cards, then reserve the id; never compute `max + 1`, another instance may be:

   ```bash
   grep -lE '^state: (captured|queued|briefed|working|blocked|review)' ledger/tasks/T-*.md | xargs -r grep -h '^# T-'
   shepherd-reserve reserve "$SHEPHERD_ID" "$HERDR_PANE_ID" "<your agent_session>"
   ```

   The titles grep is cross-owner because the duplicate is: one operator thought became T-0245 (huntaway) and T-0247 (kelpie) twenty minutes apart on 2026-09-07, each triage blind to the other, and nothing caught it until the operator asked the next day. **The same ask** → reserve nothing: yours, amend it through §5 and say so; another instance's, report it to the operator and stand down (§4a — never take a peer's card). **Adjacent, not the same** → card it, and name the sibling on the new card's `## Log`.

   Fill the file it creates from `${CLAUDE_PLUGIN_ROOT}/templates/task-card.md` in your next action, `owner:` your `SHEPHERD_ID` (nobody else touches it while your pane lives; not yet a card). A Linear-born card also sets `linear-session:`, `linear-event:` and `linear-author:` (the event's `author.id` — who may amend or cancel it besides the operator, `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice) and opens `## Log` with the issue identifier and the author's name (`author.name`; the whole webhook stays in `raw`) — the session id is how retro answers the thread. A build from a non-operator is written `captured`, not `queued` (the reference's author rule).
3. **Size / tier / budget**:

   | | size | budget | tier |
   |---|---|---|---|
   | one-file fix, config, small bug | S | 30m | standard (`SHEPHERD_TIER_S`) |
   | feature, multi-file bug, refactor | M | 120m | standard |
   | large feature, migration, cross-cutting | L | 240m | standard or heavy |
   | novel architecture · security-sensitive · >1-day scope · retry after failure | any | — | **heavy** (`SHEPHERD_TIER_HEAVY`) |
   | greenfield **and** a live integration **and** a full SDD chain — or any L whose plan is likely more than ~8 tasks | **split up front** | — | sequential **M / heavy** cards via `references/decomposition.md`, each `Depends on:` the one before (docs/incidents/2026-08-27-oversized-cards.md) |

   Size by the decisions the worker must make, not the volume it moves. Model and effort per tier are the `SHEPHERD_TIER_*` variables in `.shepherd/instance.env`, the line in the manual §0, read by dispatch at launch.
4. **Card** from `${CLAUDE_PLUGIN_ROOT}/templates/task-card.md`, the Brief filled from the registry card so the worker rediscovers nothing; a retry points at the predecessor's `## Handoff`. Fill `touch-areas:` (durable names, never file paths — they go stale in the queue) and `parallel-safety:` (`independent` or `serialized`, plus the contract that decides it) on every card, even an S; disjoint areas are a declaration, not a guarantee (monitor re-runs the DoD after a sibling merges), and dispatch decides what runs side by side.

   **Brief-writing principles** (adapted from mattpocock/skills AGENT-BRIEF, 2026-08-06):
   - **Behavioural, not procedural** — current vs desired behaviour; the worker explores and plans (memory: briefs-not-plans).
   - **Plans stay in the worker's session** — brainstorm, then plan and implement in one context, subagents for exploration and one review: a non-fork subagent starts without the brief's conversation, memory or output style (code.claude.com/docs/en/sub-agents, read 2026-09-06).
   - **Fill `### Why`** — intent and working mode: the worker judges trade-offs by it, monitor proportionality.
   - **Durable over precise** — interfaces, commands, contracts; never file paths or line numbers.
   - **Working-agreement reachability** — read `working-agreement:` first (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Working agreement): the dev branch → keep the Constraints line pointing at the project's CLAUDE.md; else say so in `### Context`, keep the four-rule block from the registry card, delete that line — an unreadable file leaves the worker with no repo rules (docs/incidents/2026-08-18-t0084-unreadable-agreement.md).
   - **DoD independently checkable** — each line something you can verify alone, never "works correctly".
   - **Fill `### Out of scope`** — the adjacent things not to touch; where monitor's over-scoped verdict starts.
   - **Bug tasks: repro-first DoD** — one command red before the fix, green after; monitor reruns it.
   - **Build-with-preview: the DoD line, or the honest first word** — read the registry card's `preview:` before the DoD is written. A mechanism named → one more DoD line, *A preview of the branch is reachable at `<URL>` (HTTP 200, shepherd fetches it) and shows `<the change>`*, and `by` decides who satisfies it: `worker` puts the preview command in the Brief; under `push` and `shepherd` the worker's part ends at the push, so say so on the line — shepherd resolves the URL and fetches it at verification, and a worker that tried would be running a deploy (the manual §4). `preview: none` → the ask is answered in its first word — no preview here, a build and a link to the branch — and the card is a plain build whose close-out says where the change now lives (retro step 4). A promotion to a shared environment is never called a preview, and no project's build pipeline is examined to find one (Saket, 2026-09-07).
   - **Pre-answer from `## Product`** — write the answer into `### Context`, citing the line (`Product: <line>`); what Product cannot answer goes to the operator in this triage's round (§3), never to the worker's checkpoint (83 % of blocks waited on a human yes — docs/incidents/2026-09-02-introspection-measures.md).
   - **Cited validation, judged per card** (the manual §2 rule 11) — keep the template's validation bullet unless neither trigger can apply, and name the vendors and consoles in `### Context`.
   - **Research before you commit** — a library, pattern or split you name is your decision: check it live (web search, `ctx7`) unless the repo already chose or the worker can; record it in `decisions/YYYY-MM-<your-shepherd-id>.md` (Basis, the manual §4), the card's `### Context`, and registry `## Context notes` when it outlives the task — an unrecorded search is no search.
5. **Queue** — write `state: captured`, then `shepherd-card transition T-NNNN queued` (one card per commit); invoke **dispatch** if the working copy is free and `worker-cap` (the manual §0) has headroom, else "queued behind T-XXXX" and stop.

## 5. Amend or cancel

The operator names an existing `T-NNNN` — or a Linear author does, honoured only from the card's `linear-author:` or the operator (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice); the card's `state:` decides who owns the edit.

- **`captured` or `queued`** — yours: re-read from disk, edit, `shepherd-card log T-NNNN "amended: <the operator's words>"`. Cancel → a real `linear-session:` gets the final word first, the close-out `response` of `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice (rule 5's three lines, rule 6's footnote: stopped and why, what was left where), guarded on the Log as retro guards its own; then the card:

  ```bash
  grep -q "linear: response posted" ledger/tasks/T-NNNN.md || {
    shepherd-inbox activity <linear-session> response "<stopped, and why; what was left where; last line: — shepherd-<id> · T-NNNN>"
    shepherd-inbox log answered <linear-event> now
  }
  shepherd-card transition T-NNNN abandoned --log "<reason, in the operator's words>" --also ledger/inbox.log
  ```

  Logged `linear: response posted to <session>` — the one close-out that never reaches retro, so the `answered` line rides here. Task cards take no lock; `owner:` is the only writer (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Owner filter).
- **`briefed`, `working` or `blocked`** — a worker is live; the owner acts through **monitor**. A separable addition is a new card (memory: narrow-briefs-phased-continuation); a change to what done means updates the card first, then one line to the worker. Cancel → **retro** with verdict `abandoned`.
- **`review`, `done` or `failed`** — closed; what the operator wants is a new task through §4.

A triage that dispatches nothing ends with `shepherd-rollover decide` (the manual §8).
