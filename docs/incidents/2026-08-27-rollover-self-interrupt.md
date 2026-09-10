# The rollover script interrupted its own tool call

**Date:** 2026-08-27 · **Card:** T-0187

## What happened

Two rollovers died at the tool call and the cause was guessed at twice. The foreground `shepherd-rollover` sent `pane send-keys <own-pane> Escape` while running as shepherd's own Bash tool call. **Claude Code reads an Escape into its own pane as "interrupt the running tool"**, and the running tool was the call carrying the script. The pane showed `Bash interrupted`, the watchdog was never armed, the `/clear` never went out, and the instance sat idle with no watchers for hours — looking exactly like a permission block, and being nothing of the kind.

## What changed

The foreground call is **read-only**: it runs `pane get` and `pane read`, logs what it saw, arms the detached watchdog with its own pid, and exits inside a second, sending no keystroke. Every keystroke — `Escape`, the bash-mode read-back, `/clear`, the recovery prompt — comes from the watchdog, which waits for the foreground pid to exit and settles before the first one. A rollover either completes or reports: the foreground refuses (exit 2, logged, toasted) before anything is armed when the pane is `blocked` or reports no session id; the watchdog's exits 2/3/4/5 reach the operator through its toast. A non-zero foreground exit means you did not roll over; a `0` means it armed, and the log tail at the next wake is what confirms recovery. `docs/specs/context-rollover-design.md` §8 records the validation, and `test-rollover.sh` asserts the shape.

## Where the rule stands

the manual §8 (foreground read-only, keystrokes from the detached watchdog); adapter R10; memory `rollover-self-interrupt`.
