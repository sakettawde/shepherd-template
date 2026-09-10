# Cards sized by volume: a 120 m M ran 264 m, one L ran 12 h, and an L ran 24 m

**Date:** 2026-08-22 (T-0093), 2026-08-27 (T-0179), 2026-09-06 (T-0231) · **Rules landed:** T-0220

## What happened

T-0093 (shepherd-deck bridge — greenfield, a live integration shepherd does not control, the full brainstorm → plan → implement chain) was sized M at 120 m. It ran 264 m with steady progress, no stall and no retry; shepherd raised the budget twice (120 → 210 → 300) and was wrong both times. The estimate had read the imagined diff, not the shape: a live integration is probed, not read about, and four of its seventeen findings overturned the approved design. T-0179 (karta docs editor, a 13-task L) ran one worker for 12 h to 72 % of a 1M context; every turn on a 700k context costs the whole context again, and Saket asked for handoffs mid-plan. T-0231 (teacher-portal, 1,223 lines relocated *verbatim*) was sized L at 240 m and ran 24 m: bulk copied under a no-rewrite constraint carries no decisions.

## What changed

Size by the decisions the worker must make, not the volume it moves. The sizing table's split row: greenfield **and** a live integration **and** a full SDD chain — or any L whose plan is likely more than ~8 tasks — is split up front into sequential M / heavy cards through `triage/references/decomposition.md`, each `Depends on:` the one before; never one L, never one M. A plan past ~8 tasks crosses half a worker's context before its last task, and the handoff that rescues it costs more than the split would have. A worker at ~50 % context with two or more tasks left is handed off to a fresh session on the same card through `## Handoff`, never `--resume`. Steady progress past budget is a sizing error, not drift: monitor's overrun row asks for a bound, it does not accuse.

## Where the rule stands

Triage §4 sizing table (the split row); `triage/references/decomposition.md` § Right-size; monitor's overrun row; memory `size-greenfield-tasks-L`, `worker-context-handoff`.
