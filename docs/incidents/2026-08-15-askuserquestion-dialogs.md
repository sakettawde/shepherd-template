# A worker's AskUserQuestion round renders as a dialog shepherd cannot reliably drive

**Date:** 2026-08-15 · **Cards:** T-0074; T-0097 (2026-08-23)

## What happened

On T-0074 a worker asked several questions in one AskUserQuestion round. The pane showed one question at a time under a `☐ ☐ ☐ ✔ Submit` header; driving the selection with `pane run` would have confirmed whatever was highlighted. The same task showed that a worker ending its turn with `SHEPHERD: blocked` reports `idle` to herdr, not `blocked`, so the herdr stall watcher ran to its full timeout and missed the pause. On T-0097 shepherd tried to navigate a round by keys: `Tab` did nothing, `Right` advanced but overshot onto the review screen and stuck there with a question unanswered, `Left` would not go back, and a single `Escape` landed on a `Ready to submit your answers?` confirm rather than cancelling.

## What changed

One read per question at most, then cancel the round — `Escape` **twice** — and answer in prose through a normal R4 reply carrying the rulings; the worker logs "User declined to answer questions", drops to `idle`, and accepts the single-line reply. Tell the worker in that reply to ask in prose from then on. A question you missed is asked to be restated, never guessed at. The status-file watcher, not the stall watcher, is the primary signal for a checkpoint pause: a `blocked` claim reaches shepherd within seconds however herdr classifies the pane.

## Where the rule stands

Adapter Gotchas (one line each on the round and on `blocked`-reports-`idle`); adapter R5 names the status-file watcher primary; the template's *Ask in one round* bullet is why a worker should not need a dialog at all.
