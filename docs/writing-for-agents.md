# Writing for agents — reference

Condensed from mattpocock/skills `writing-for-agents` (MIT, adapted 2026-08-06).
Consult whenever shepherd writes or edits a document an agent will consume: its own
skills, a project CLAUDE.md working agreement (onboard), or a downstream standing-rule
proposal (retro). The goal is the agent taking the same *process* every run.

## Context pointers

A pointer (a skill description, a CLAUDE.md line naming a doc) decides *when* the
material behind it gets reached — its wording, not its target, does the work. A
must-have rule behind a weakly worded pointer is a variance bug: sharpen the wording
first; inline the material only if sharpening fails. Front-load the trigger word; one
trigger per genuinely distinct branch; cut identity the body already carries.

## The two loads

- **Context load** — always-loaded material (CLAUDE.md lines, skill descriptions)
  costs tokens and attention every turn, firing or not.
- **Cognitive load** — the human remembering what exists and when to reach for it.
  Not a cost to minimize — spend it where human judgment matters.

Push reference behind pointers (progressive disclosure) so the always-loaded top stays
legible: inline what every path needs, disclose what only some paths reach.

## Steps and completion criteria

Every step ends on a checkable completion criterion. "Understanding reached" invites
premature completion; "every modified model accounted for" forces legwork. The
strongest criteria are both checkable and exhaustive. (Shepherd's DoD lines and the
four-source completion gate are this principle applied.)

## Prompt the positive

Negation drags the forbidden behavior into context and makes it *more* available —
half the ban reads as an instruction. State the target behavior instead ("write
one-line comments", not "don't write long comments"). A prohibition earns its place
only as a hard guardrail you cannot phrase positively — and even then pair it with the
positive target. (Shepherd's hard lines — git, destructive ops, status protocol — are
the legitimate exceptions.)

## Leading words

A compact pretrained concept the agent thinks with (*tracer bullet*, *frontier*,
*tight loop*) anchors a region of behavior in one token. Repeated as a token, it beats
a restated sentence every time. Hunt for passages begging to collapse into one word.

## Pruning

- **Single source of truth** — one meaning, one place; a repo rule lives in that
  repo's CLAUDE.md, never restated in a Brief (already shepherd law).
- **Don't cache the environment** — a doc restating `package.json` scripts, `--help`
  output, or directory layout goes stale; cache only what the agent cannot look up
  (the unwritten convention, the why, the gotcha no config confesses).
- **Hunt no-ops** — a sentence the model already obeys by default ("be thorough")
  pays load to say nothing; delete the sentence, or replace the weak word with a
  stronger one (*relentless*).
- **Watch for sediment** — stale layers settle because adding feels safe and removing
  feels risky. Retro's prune-while-banking rule is this discipline for gotchas;
  apply the same pass to skills and working agreements.
