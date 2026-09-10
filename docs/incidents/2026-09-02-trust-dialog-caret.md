# The trust-folder dialog's caret defaults to "No, exit"

**Date:** 2026-09-02 · **Card:** T-0219 (first seen on T-0093, 2026-08-22)

## What happened

A worker launched into a directory shepherd had just created parked at `agent_status: blocked` on `Is this a project you created or one you trust?`, with no output on `--source recent` (read `visible` or `detection` to see it). The adapter's Gotcha said the caret defaulted to the accepting option and a bare `Enter` would proceed. Measured on a live dispatch, **the caret defaults to `2. No, exit`**: a bare `herdr pane send-keys <pane> Enter` confirmed the exit, Claude quit, the pane fell back to a shell with no agent and no `agent_session`, and every downstream check then reported a pane herdr could not classify.

## What changed

Move the caret onto `1. Yes, I trust this folder` first (`send-keys <pane> Down`, or `Tab` on builds that cycle), **re-read the pane and confirm the caret is on that line**, and only then send `Enter`. Never confirm a selection you have not read back; `scripts/smoke.sh`'s `select_trust_yes` is the worked implementation. Expect the dialog on every first dispatch into a repo shepherd just created; it is a routine permission prompt under CLAUDE.md §4, not an escalation.

## Where the rule stands

Adapter Gotchas (two lines); `scripts/smoke.sh select_trust_yes`.
