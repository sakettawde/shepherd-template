# A re-armed watcher fired on the claim it had already handled; a dialog swallowed the reply

**Date:** 2026-08-14 · **Card:** T-0071 (re-arm anchor corrected again on T-0080, 2026-08-18)

## What happened

Two failures on one task. First, a naive re-arm of the status-file watcher fired instantly on the terminal claim still sitting in the file from the wake shepherd had just handled: the watcher's condition was already true at arming time. Second, Claude Code's onboarding dialog ("Set up auto mode?") was on screen when shepherd sent `3` through `pane run`; the trailing Enter confirmed whatever was highlighted, and the worker *entered* the wizard instead of dismissing it.

## What changed

The re-arm anchors on the **count of wake-worthy records**, never on line count, and the anchor is computed by `shepherd-watch` (`wake_count`) at every arming — a re-arm never fires on a claim already handled, and the general rule is that a watcher whose condition is already true when armed is worse than none. Dialogs are cancelled with `herdr pane send-keys <pane> Escape`, never answered through `pane run`, and an R6 read confirms the box is clear before any prompt is sent.

## Where the rule stands

Adapter R5 (the anchor) and the adapter Gotchas one-liners on dialogs; the count anchor's later deaths are in [2026-08-18-watcher-deaths.md](2026-08-18-watcher-deaths.md).
