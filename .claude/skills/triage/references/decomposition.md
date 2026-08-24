# Decomposition — an outcome, or an oversized task, into approved slices

Reached from triage §4 on either entry: a message describing an **end result**
rather than a task, or a task **too big for one worker session**. Both end in
the same artifact — sibling cards, blockers first, one approval gate — so both
run this loop.

## 1. Elaborate (outcome entry only)

Enumerate candidate slices. Each is a **tracer bullet**: a narrow but complete
vertical path (schema→API→UI→test), independently demoable, sized to one fresh
worker context.

Name each slice by **what it makes true**, never by how it is built. This is
`Behavioral, not procedural` (§4) turned on the orchestrator itself — the slice
boundary is exactly where the elaboration stops and the worker's own planning
starts. A slice you can describe as a sequence of edits has been planned, not
sliced.

Draft each slice against the registry card — stack, dev branch, Product,
Gotchas. A slice drafted without it invents context the registry already holds.

## 2. Right-size

Scale the number of slices to the outcome, and prefer the **fewest that each
stand alone**. A slice that cannot be demoed by itself is not a slice: fold it
into its neighbour.

**One card is often the right answer.** Where the parts share one context or
lean heavily on each other, splitting costs more than it buys — Anthropic
measured over-spawning as a leading failure mode of this exact pattern, and
names domains that "require all agents to share the same context or involve many
dependencies between agents" — most coding tasks among them — as a poor fit for
splitting at all ([How we built our multi-agent research
system](https://www.anthropic.com/engineering/multi-agent-research-system), read
2026-08-23). Reach for a split when the slices are genuinely independent, not
when the outcome merely sounds large.

**One mechanical wide refactor** (rename, retype) is the exception to vertical
slicing: expand → migrate in batches → contract, each batch its own card.

## 3. Order and declare

Dependencies stay Brief prose — `Depends on: T-XXXX`, with the sentence saying
what the later slice needs from the earlier one. Blockers queue first, FIFO by
`created:`.

Fill `touch-areas:` and `parallel-safety:` on every sibling (§4), and write
`parallel-safety:` **symmetrically** across the set. Every card in a split is
created in one pass, so agreeing now costs nothing; a card that claims a sibling
as independent while the sibling says otherwise is a declaration nobody can act
on.

## 4. Present for approval

One frontier round (§3): each slice on one line — title, what it makes true, its
`Depends on:` — then the parallel-safety verdict for the set with its one line
of reasoning, and a `➡️` recommendation.

**Create no card and reserve no id before the operator answers.** A reservation
writes to shared state other instances can see, which makes it a side effect
rather than a draft.

## 5. Card each approved slice

Back to §4 from step 2, once per slice.
