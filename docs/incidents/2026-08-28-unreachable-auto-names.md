# Instances launched without -n were unreachable by id

**Date:** 2026-08-28

## What happened

Shepherd instances launched with `--remote-control <id>` but without `-n <id>`. `--remote-control` titles the *remote* session in the Claude apps and carries identity when messaging a session on another machine; it names the session to no local peer. Left unnamed, Claude Code names a session itself, `<working-directory>-<two characters>`, so every instance launched from one clone listed as `shepherd-4c`, `shepherd-e3`, … in `ListAgents` — telling nobody which was which and answering to no id. Claude Code's duplicate-name protection does not cover those auto names either. Every handoff aimed at a shepherd id landed nowhere, and a peer's queue could starve on a card it was never told about. Verified the same day: a sender under an auto name still delivers (`shepherd-cd` reached a freshly renamed `shepherd-collie`) — only the **recipient** needs the id.

## What changed

The canonical launch passes the same id three times: `SHEPHERD_ID=<id>` (who you are), `-n <id>` (the address peers send to), `--remote-control <id>` (the remote title). `/rename <id>` typed in the pane repairs a session already running without the flag. Wake step 10 confirms `ListAgents` opens with your `SHEPHERD_ID` at every wake — a plan title replaces an *unnamed* session's label, so the check is not only for restarts — and asks the operator for the `/rename` otherwise. A handoff to an id `ListAgents` does not show is the unresolved case: report it, never take the card. Workers are named `worker-T-NNNN` for the same reason, so one listing separates instances from workers and says which card each runs ([Manage sessions](https://code.claude.com/docs/en/sessions) § "Name your sessions"; [Message your other Claude Code sessions](https://code.claude.com/docs/en/cross-session-messaging), both read 2026-08-28).

## Where the rule stands

the manual §1 (the launch line); `docs/protocols.md` § Ownership and handoff (addressing a peer); wake step 10.
