# idle_prompt fires at every turn boundary while a worker drives subagents

**Date:** 2026-08-08 · **Card:** T-0059

## What happened

A fable worker running background subagents emitted an `idle_prompt` notification at every turn boundary while a subagent was still running, then resumed on its own. The notification watcher woke shepherd five times in one task for a worker that was never actually waiting on anyone.

## What changed

`idle_prompt` is not in the wake set: `shepherd-watch` wakes on terminal claims, `session_end` / `stop_failure`, and the `permission_prompt`, `elicitation_dialog` and `agent_needs_input` notification kinds, and deliberately not on `idle_prompt` — a worker parked on a checkpoint awaiting Saket is exactly the case where an idle prompt should not wake you. On any wake that looks like a pause, `agent_status` is read first: `working` is a no-op (re-arm), and `blocked` is classified only from an actual question in the pane tail.

## Where the rule stands

Adapter R5 (the wake set) and the adapter Gotchas one-liner; monitor's blocked row classifies from evidence, never from a notification alone.
