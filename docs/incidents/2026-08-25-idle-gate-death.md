# The rollover waited for an idle a shepherd pane can never report

**Date:** 2026-08-25

## What happened

The context-rollover injector waited for `agent_status: idle` on shepherd's own pane before typing the recovery prompt. **A shepherd pane can never report `idle`**: its background watcher shells match herdr's `background_shell_working` rule (priority 965), which outranks the `live_prompt_box` idle rule (950) even when the prompt box is a bare `❯`. The injector polled for six minutes against a state the pane was structurally incapable of producing, wrote nothing, and the instance sat dead for 40 minutes. Worse, the gate was inverted: a box in bash mode drops the `· N shells` footer, so `background_shell_working` stops matching and the pane reports `idle` via `osc_title_idle` (250) — the gate stayed silent in the healthy case and fired in the failure case.

Two measurements from the same day corrected earlier beliefs: a pane whose box read Claude Code's own suggested prompt accepted `/clear` normally and its session id moved, so text after `❯` is not a refusal; and background Bash watchers **survive** `/clear` (a `sleep 900` started before a clear was still running after it), so a rising shell count across rollovers is expected, not a leak.

## What changed

The watchdog gates on the pane's **Claude session id changing** (`pane get` → `result.pane.agent_session.value`, maintained by the herdr `claude` integration hook on `SessionStart`), never on `idle`. Every poll and verdict is logged to `~/.claude/shepherd-rollover.log`, every give-up raises a toast naming the line to type by hand, and wake step 10 reads the log tail so a failed rollover reaches the operator and the decision log.

## Where the rule stands

the manual §8 (the gate and the exit semantics); adapter R10; `docs/specs/context-rollover-design.md`; memory `own-pane-never-idle`.
