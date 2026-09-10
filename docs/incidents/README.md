# Incidents

One file per incident: the date, what happened, what changed, and where the rule now stands. The rules themselves live in `CLAUDE.md`, `docs/protocols.md`, the adapter reference and the skills; these files hold the why, so a rule can be short where it is read and still be traceable to the failure that produced it. Add a file when a failure changes a rule; link it from where the rule stands with one line.

| Date | File | One line |
|---|---|---|
| 2026-08-08 | [2026-08-08-idle-prompt-subagents.md](2026-08-08-idle-prompt-subagents.md) | `idle_prompt` fires at every turn boundary under background subagents; it is not in the wake set |
| 2026-08-14 | [2026-08-14-dialogs-and-consumed-claims.md](2026-08-14-dialogs-and-consumed-claims.md) | a re-arm fired on an already-handled claim; a dialog swallowed a `pane run` reply |
| 2026-08-15 | [2026-08-15-askuserquestion-dialogs.md](2026-08-15-askuserquestion-dialogs.md) | AskUserQuestion rounds cannot be driven reliably; Escape twice, answer in prose |
| 2026-08-18 | [2026-08-18-bash-mode-trap.md](2026-08-18-bash-mode-trap.md) | `/clear` submitted into a bash-mode box ran as a shell command |
| 2026-08-18 | [2026-08-18-watcher-deaths.md](2026-08-18-watcher-deaths.md) | `wc -l` anchor misfired twice; `\|\| echo 0` killed a watcher silently |
| 2026-08-18 | [2026-08-18-t0084-unreadable-agreement.md](2026-08-18-t0084-unreadable-agreement.md) | a Brief pointed at a CLAUDE.md on a branch the worker could not read |
| 2026-08-22 | [2026-08-22-t0093-cluster.md](2026-08-22-t0093-cluster.md) | ghost text held a finished worker 56 minutes; piped watcher; `agent wait` races startup |
| 2026-08-24 | [2026-08-24-approval-pause-claimed-working.md](2026-08-24-approval-pause-claimed-working.md) | an approval pause claimed `working` and waited for the heartbeat |
| 2026-08-25 | [2026-08-25-idle-gate-death.md](2026-08-25-idle-gate-death.md) | the rollover waited for an `idle` a shepherd pane can never report |
| 2026-08-27 | [2026-08-27-rollover-self-interrupt.md](2026-08-27-rollover-self-interrupt.md) | the foreground rollover's Escape interrupted its own tool call |
| 2026-08-27 | [2026-08-27-oversized-cards.md](2026-08-27-oversized-cards.md) | a 120 m M ran 264 m, one L ran 12 h, an L ran 24 m; size by decisions, split up front |
| 2026-08-28 | [2026-08-28-unreachable-auto-names.md](2026-08-28-unreachable-auto-names.md) | instances launched without `-n` answered to no id |
| 2026-09-02 | [2026-09-02-trust-dialog-caret.md](2026-09-02-trust-dialog-caret.md) | the trust dialog's caret defaults to "No, exit" |
| 2026-09-02 | [2026-09-02-inbox-watcher-outages.md](2026-09-02-inbox-watcher-outages.md) | a Cloudflare blip retired Linear intake; the one-hour window woke shepherd 24 times a day |
| 2026-09-02 | [2026-09-02-introspection-measures.md](2026-09-02-introspection-measures.md) | five dead feedback loops measured: budget, approvals, folds, close-out, memory provenance |
| 2026-09-02 | [2026-09-02-stale-clone-tip.md](2026-09-02-stale-clone-tip.md) | a reused clone started on a stale base; a clone could not be made without an origin |
| 2026-09-06 | [2026-09-06-launch-drift.md](2026-09-06-launch-drift.md) | shepherd's model drifted, the subagent pin became a ceiling, workers lost the coding instructions |
