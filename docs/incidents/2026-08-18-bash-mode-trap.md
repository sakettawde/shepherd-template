# A /clear typed into a pane in bash mode ran as a shell command

**Date:** 2026-08-18 · **Card:** T-0085 session

## What happened

Saket's last input in the shepherd pane had used the `!` prefix, so the input box was in bash mode. The context rollover then submitted `/clear` into it, and the pane answered `/bin/bash: /clear: No such file or directory`. The context was never cleared, and nothing said so: `herdr agent prompt` returns `agent_prompted` even when the box swallows the text.

## What changed

`shepherd-rollover` handles it without judgement on shepherd's part: the detached watchdog sends `Escape`, re-reads the prompt box and proves it is back in prompt mode (measured: `Escape` reliably restores `❯`), refuses only if it is still in bash mode, and then submits `/clear`. Arrival of the recovery prompt is confirmed from the fresh session's transcript, never from `agent prompt`'s return value. By hand, `herdr pane send-keys <pane> Escape` clears the box, and asking Saket to type `/clear` himself always works.

## Where the rule stands

Adapter R10 ("its return value is never evidence"); the manual §8's rollover invariants; `docs/specs/context-rollover-design.md`.
