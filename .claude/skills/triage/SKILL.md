---
name: triage
description: Turn every incoming message from the operator into one or more of - a direct answer, context ingestion, a clarifying question, a task card, or an amendment to an existing card. Routes to onboarded projects, decomposes outcomes into approved slices, sizes/tiers/budgets tasks, enforces the onboarded-only gate, and offers onboarding when needed. Never dispatches work itself.
---

# triage

Every message carries **one or more of five intake types**. Split it into parts, classify each part, and act on context ingestion first — a Brief written before the note is banked cites nothing, and the note is what makes the Brief current. "We decided X, so change Y" is §2 followed by §4, in that order.

## 1. Answer

Question about state, history, a project, or a decision → answer from registry/ledger/decisions/memory (grep cookbook in CLAUDE.md §5). One line where possible. No task.

## 2. Context ingestion

The operator is sharing knowledge (decisions, meeting notes, stakeholder conversations, priorities):

1. Identify the project (ask if ambiguous).
2. Take the card lock, then append a dated entry to the registry card `## Context notes` (verbatim-ish, compressed):

   ```bash
   scripts/lock.sh acquire "card-<slug>" "$SHEPHERD_ID" "$HERDR_PANE_ID" "<session>"
   # re-read registry/projects/<slug>.md from disk, edit, then:
   scripts/ledger-commit.sh "<slug>: context note" "registry/projects/<slug>.md"
   scripts/lock.sh release "card-<slug>" "$SHEPHERD_ID"
   ```

   Re-read inside the lock and commit inside the lock. Your in-context copy may be minutes stale, and a commit after release can capture another instance's half-written edit to the same file.
3. Distill durable facts into the project's Claude auto-memory directory (`~/.claude/projects/<encoded-project-path>/memory/`) (one-fact files + MEMORY.md index line). Individual fact files need no lock; the shepherd `MEMORY.md` index takes `card-_memory` under the same protocol.
4. Confirm in one line.

## 3. Clarifying question

Routing or intent ambiguous → ask. Never guess the project. If two projects plausibly match, name both and ask.

Ask in **frontier rounds** (grilling pattern): batch every question askable *now* into one numbered message, each with your recommended answer (`➡️`) so the operator can rubber-stamp or override in a single reply. Questions that depend on an answer still open wait for the next round. Facts you can look up (repo, registry, ledger) are never questions — only genuine decisions go to the operator.

## 4. Task

**Shape first.** A message naming one thing to change is one card — continue below. A message describing an **end result**, or a task too big for one worker session, becomes sibling cards first: run `.claude/skills/triage/references/decomposition.md`, then return here to card each approved slice.

1. **Route** via `registry/projects.md` keywords + card contents. If the project is **not `onboarded: yes`** → refuse the task in one line and offer onboarding (which is itself a task — see the onboard skill). Never brief a worker into a non-onboarded repo.

   If another instance already holds this project's lock and the operator wants a second lane, route to a **clone**: `project: <slug>~N`, path from the registry card's `## Clones` table. A clone is never onboarded again — it inherits the parent card's `onboarded:`, Product, Gotchas and History. Create it per the dispatch skill before briefing.
2. **Number**: reserve the id — never compute `max + 1` yourself, another instance may be doing the same at this moment:

   ```bash
   scripts/reserve-task-id.sh reserve "$SHEPHERD_ID" "$HERDR_PANE_ID" "<your agent_session>"
   ```

   It prints `T-NNNN` and creates the card file holding a one-line reservation. Fill that file from `templates/task-card.md` in your very next action, and set `owner:` to your `SHEPHERD_ID`. A reservation left unfilled is safe — no other instance touches it while your pane is alive — but it is not a card until you fill it.
3. **Size / tier / budget**:

   | | size | budget | tier |
   |---|---|---|---|
   | one-file fix, config, small bug | S | 30m | standard (opus/high) |
   | feature, multi-file bug, refactor | M | 120m | standard |
   | large feature, migration, cross-cutting | L | 240m | standard or heavy |
   | novel architecture · security-sensitive · >1-day scope · retry after failure | any | — | **heavy** (opus/xhigh) |
   | greenfield **and** a live integration **and** a full SDD chain | **L** | 240m | **heavy** — never an M (T-0093: budgeted 120m as an M, raised twice, ran 264m) |

4. **Card** from `templates/task-card.md`, `state: queued`. Fill the Brief from the registry card (stack, test, dev-branch, gotchas, product pointers) — the worker should never rediscover what the registry already knows. Retry of a failed task → the Brief also points at the predecessor card's `## Handoff` section (and its Log) so the new worker starts from what's already ruled out.

   **Touch-areas and parallel-safety** — fill both header fields on every card, including a lone S. `touch-areas:` names what the work reaches in durable terms (modules, schemas, config domains, shared interfaces), never file paths, which go stale while a card sits queued. It is the mechanical half: any two cards can be compared for overlap without reading either Brief. `parallel-safety:` is the judgment half — `independent` or `serialized`, plus the one line naming the shared contract that decides it — and it carries what no comparison can derive. Disjoint touch-areas are a **declaration, not a guarantee**: two cards sharing no area still clash when one changes a signature the other calls, which is why monitor re-runs the DoD after a sibling merges rather than trusting the field. Whether two cards actually run side by side stays dispatch's call.

   **Brief-writing principles** (adapted from mattpocock/skills AGENT-BRIEF):
   - **Behavioral, not procedural** — describe what the system should do after the work, current behavior vs desired behavior; the worker explores and plans itself (briefs, not plans — CLAUDE.md §6).
   - **Fill `### Why`** — the intent behind the operator's ask and the working mode (quick-and-dirty vs long-term-thorough), so the worker inherits it and can judge unanticipated trade-offs; monitor judges diff proportionality against it. You are the task's owner, not its dispatcher: the Why is what lets you and the worker judge scope-fit, not just DoD pass/fail.
   - **Durable over precise** — a card can sit queued for days behind other tasks. Name interfaces, types, commands, and behavioral contracts; never file paths or line numbers — they go stale between queueing and dispatch.
   - **Working agreement reachability** — read the registry card's `working-agreement:` (CLAUDE.md §5) before you write `### Context`. When it is the dev branch, keep the template's Constraints line pointing at the project's own CLAUDE.md. When it is anything else the worker cannot open that file from the branch it checks out: say so in `### Context` — *this repo has no CLAUDE.md on `<dev-branch>`; the working agreement lives on `<branch>` and is inlined below* — then keep the template's four-rule block, filled from the registry card, and delete the Constraints line. §6 strips repo rules out of every Brief on the assumption the file is readable, so a Brief that points at an unreadable one has silently left the worker with no repo rules at all (T-0084: the worker never saw the check-out-the-dev-branch rule, and left the work stranded on its task branch).
   - **DoD criteria independently checkable** — each line something shepherd can verify alone ("`<cmd>` passes", "route X returns Y"), never "works correctly".
   - **Fill `### Out of scope`** — the adjacent things the worker must not touch. This is the cheapest defense against gold-plating and over-scoped diffs (monitor's over-scoped verdict starts here).
   - **Bug tasks: repro-first DoD** — the Brief requires the worker to produce one command that goes red on the bug before fixing (test, curl, CLI invocation). That command goes into the DoD; monitor reruns it at verification. No repro command → the fix claim is unverifiable.
   - **Cited validation, judged per card** (CLAUDE.md §2 rule 11) — the template's validation bullet is present by default. Delete it only when neither trigger can apply: no third party, no infrastructure you do not own, and no choice without a clear winner. When you keep it, name in `### Context` the specific vendors, APIs or consoles the worker will have to verify, so the mandate is concrete rather than generic.
   - **Research before you commit, in proportion to the commitment** — the bullet above binds the worker; this one binds you. A Brief that names a library, an architectural pattern or a split strategy is a decision *you* made, so check it live first (a documentation-retrieval tool for library and SDK documentation, web search for vendor product behaviour and changelogs). Two exemptions carry most cases: the choice the **repo already made** (it is in the lockfile, or it is the pattern the codebase uses), and the choice you can **decline to make** — state the requirement and let the worker pick, since its own validation bullet already binds it there. Record what you compared, what won and why, with URL and read-date: `decisions/YYYY-MM-<your-shepherd-id>.md` is the home (its **Basis** is that source — CLAUDE.md §4), the one-line conclusion and URL also go in the card's `### Context` so the worker inherits it, and registry `## Context notes` takes it only when the finding outlives the task. An unrecorded search is no search.

5. Commit (`T-NNNN: captured → queued`) via `scripts/ledger-commit.sh`, then **invoke dispatch** if the working copy has no active task and the worker cap (CLAUDE.md §0) has headroom; otherwise say "queued behind T-XXXX" and stop.

## 5. Amend or cancel

The operator names an existing `T-NNNN` to change, extend or drop. Nothing is created; the target card's **`state:` decides who owns the edit**.

- **`captured` or `queued`** — yours. Re-read the card from disk, edit the Brief, append the Log line in the operator's words, commit via `scripts/ledger-commit.sh` (`T-NNNN: brief amended`). Cancel → `state: abandoned`, reason in the Log. Task cards take no lock: their `owner:` is the only writer (CLAUDE.md §2 rule 10). Locks guard *registry* cards.
- **`briefed`, `working` or `blocked`** — a worker is live, so the edit belongs to the owner acting through **monitor**. Classify it and hand it over.
  - *Amend*: when the addition is separable, a new card beats a wider brief — one focused task per worker. When it genuinely changes what done means, update the card first, then send the worker one line pointing at it; the card is the contract.
  - *Cancel*: route it through **retro** with verdict `abandoned` — harvest the `## Handoff`, retire the pane, release the project lock, registry `active-task: none`. The close-out path already does every step.
- **`review`, `done` or `failed`** — the work is closed. What the operator wants is a new task; card it through §4.

Triage decides *what and where*; dispatch decides *when and how*; an amendment goes to whichever skill owns the card's state now. Keep them separate.

When a triage ends with nothing dispatched (answer, context ingestion, question, or a card queued behind another), finish with `scripts/context-rollover.sh decide` (CLAUDE.md §8 context check) — an idle moment is the cheapest time to roll over.
