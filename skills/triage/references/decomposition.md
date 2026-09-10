# Decomposition — an outcome, or an oversized task, into approved slices

Reached from triage §4 on either entry: a message describing an **end result** rather than a task, or a task **too big for one worker session**. Both end in the same artifact — sibling cards, blockers first, one approval gate — so both run this loop.

## 1. Elaborate (outcome entry only)

Enumerate candidate slices. Each is a **tracer bullet**: a narrow but complete vertical path (schema → API → UI → test), independently demoable, sized to one fresh worker context. Name each by **what it makes true**, never by how it is built — `Behavioral, not procedural` (§4) turned on the orchestrator: the slice boundary is where elaboration stops and the worker's planning starts, and a slice you can describe as a sequence of edits has been planned, not sliced. Draft against the registry card (stack, dev branch, Product, Gotchas), or the slice invents context the registry already holds.

## 2. Right-size

Prefer the **fewest slices that each stand alone**; one that cannot be demoed by itself folds into its neighbour. **One card is often the right answer**: where the parts share one context or lean on each other, splitting costs more than it buys — Anthropic measured over-spawning as a leading failure of this pattern, and names domains that "require all agents to share the same context or involve many dependencies between agents", most coding tasks among them, as a poor fit ([How we built our multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system), read 2026-08-23). Split for genuine independence, not because the outcome sounds large.

**One shape is never one card.** The sizing table's split row — greenfield plus a live integration plus a full SDD chain, or any L whose plan is likely more than ~8 tasks — arrives here already decided: sequential M / heavy cards, each `Depends on:` the one before, because a plan past ~8 tasks crosses half a worker's context before its last task and the handoff that rescues it costs more than the split (docs/incidents/2026-08-27-oversized-cards.md).

**One mechanical wide refactor** (rename, retype) is the exception to vertical slicing: expand → migrate in batches → contract, each batch its own card.

## 3. Order and declare

Dependencies stay Brief prose — `Depends on: T-XXXX`, with the sentence saying what the later slice needs from the earlier one; blockers queue first, FIFO by `created:`. Fill `touch-areas:` and `parallel-safety:` on every sibling (§4), and write `parallel-safety:` **symmetrically** across the set: a card that claims a sibling as independent while the sibling says otherwise is a declaration nobody can act on, and agreeing now, in one pass, costs nothing.

## 4. Present for approval

One frontier round (§3): each slice on one line — title, what it makes true, its `Depends on:` — then the set's parallel-safety verdict with its one line of reasoning and a `➡️` recommendation. **Create no card and reserve no id before the operator answers**: a reservation writes shared state other instances can see, a side effect rather than a draft.

## 5. Card each approved slice

Back to §4 from step 2, once per slice.
