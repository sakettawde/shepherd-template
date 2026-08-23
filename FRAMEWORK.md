# Framework vs instance state

Sync rule: **framework files are edited in shepherd-template first**, then pulled into instances (`git remote add template …`; cherry-pick). Instance-state files never cross in either direction — in a template-repo PR, a diff touching an instance-state path is a leak.

| Path | Kind | Notes |
|---|---|---|
| `CLAUDE.md` | framework, except `## 0. Operator` | the Operator block is instance state written by init-shepherd; instances may also append local overrides at the end of §6 |
| `.claude/skills/**` | framework | includes init-shepherd |
| `.claude/settings.json` | framework | repo-scoped permissions |
| `hooks/**` | framework | registered user-globally by init-shepherd |
| `templates/**` | framework | task-card skeleton |
| `scripts/**` | framework | bootstrap-registry.sh, lock.sh, reserve-task-id.sh, ledger-commit.sh, shepherd-identity.sh, self-recycle.sh, drill.sh, lib/, tests/ |
| `README.md`, `FRAMEWORK.md` | framework | |
| `docs/herdr-schema-*.json` | framework | pin snapshots |
| `docs/writing-for-agents.md` | framework | reference for skills/CLAUDE.md authoring (onboard, retro) |
| `docs/specs/multi-shepherd-design.md` | framework | the concurrency design CLAUDE.md §8 cites (§6.1 lock kinds, §9 session start) |
| `ledger/**` | instance state | task cards, status JSONLs, attachments |
| `ledger/locks/**`, `ledger/shepherds/**` | instance state | runtime coordination; gitignored, never synced |
| `registry/**` | instance state | project index + cards |
| `decisions/**` | instance state | decision log |
| `docs/**` (everything else) | instance state | specs, plans, drills, ideas |
