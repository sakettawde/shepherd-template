# Framework vs instance state

Sync rule: **framework files are edited in shepherd-template first**, then pulled into instances (`git remote add template …`; cherry-pick). Instance-state files never cross in either direction — in a template-repo PR, a diff touching an instance-state path is a leak.

Framework changes are made in a **separate `shepherd-template` checkout**, never on a branch in an instance working copy. An instance may never leave `main`: every instance commits its ledger, registry and decision state into that one checkout, concurrently, so a task branch checked out there silently collects every other instance's commits, and checking `main` back out strands them. `scripts/ledger-commit.sh` enforces this — it refuses, exit 1, to commit ledger state on any branch but `main`, before it stages anything.

Measure drift with `git log template/main..HEAD -- <framework paths>`; a `diff --stat` between two personalised trees reports the personalisation layer as drift (T-0101).

| Path | Kind | Notes |
|---|---|---|
| `CLAUDE.md` | framework, except `## 0. Operator` | the Operator block is instance state written by init-shepherd; instances may also append local overrides at the end of §6 |
| `.claude/skills/**` | framework | includes init-shepherd |
| `.claude/settings.json` | framework | repo-scoped permissions, incl. the `deny` block |
| `.claude/settings.local.json` | instance state | per-machine permission overrides; gitignored, never synced — and never hand-copied into a new clone, where its pane ids and paths are stale |
| `hooks/**` | framework | registered user-globally by init-shepherd |
| `templates/**` | framework | task-card skeleton |
| `scripts/**` | framework | bootstrap-registry.sh, lock.sh, reserve-task-id.sh, ledger-commit.sh, shepherd-identity.sh, context-rollover.sh (+ a deprecated shim at its old path), inbox.sh, drill.sh, lib/, tests/ |
| `README.md`, `FRAMEWORK.md` | framework | |
| `docs/herdr-schema-*.json` | framework | pin snapshots |
| `docs/writing-for-agents.md` | framework | reference for skills/CLAUDE.md authoring (onboard, retro) |
| `docs/specs/multi-shepherd-design.md` | framework | the concurrency design CLAUDE.md §8 cites (§6.1 lock kinds, §9 session start) |
| `docs/specs/linear-inbox-wiring-design.md` | framework | the Linear inbox design `scripts/inbox.sh`'s header cites |
| `ledger/**` | instance state | task cards, status JSONLs, attachments |
| `ledger/locks/**`, `ledger/shepherds/**` | instance state | runtime coordination; gitignored, never synced |
| `registry/**` | instance state | project index + cards |
| `decisions/**` | instance state | decision log |
| `docs/**` (everything else) | instance state | specs, plans, drills, ideas |
