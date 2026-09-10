# A worker waiting for approval claimed `working` and waited 30 minutes for nothing

**Date:** 2026-08-24 · **Card:** T-0152

## What happened

A worker paused for a design approval and ended its turn `SHEPHERD: working — waiting for approval`. An honest report, and invisible: the status-file watcher wakes on `done|blocked|failed`, so the pause sat until the heartbeat backstop fired ~30 minutes later. A pause that waits on shepherd's input is the highest-value wake signal there is, and the wording alone had thrown it away.

## What changed

The template's `### Status protocol` sorts the claims by what happens next and names approval as a `blocked` case: **`blocked`** — you need shepherd input to continue (a design approval, an answer, a ruling, a permission); **`working`** — you continue on your own next turn, a checkpoint, never terminal. It states the cost, because the why is what makes the rule survive a worker under pressure: shepherd wakes on `blocked` within seconds and on `working` only at the next heartbeat. The canonical statement lives in the template because the card is the only surface a worker reads; the manual §6, monitor and onboard state the rule in a sentence and point home.

## Where the rule stands

`templates/task-card.md` `### Status protocol` (canonical); `docs/protocols.md` § Status protocol; the manual §6.
