---
name: herdr-adapter
description: The ONLY place herdr command syntax lives. Use for every herdr operation - spawning worker panes, launching workers, sending prompts, waiting for completion, reading panes, notifications. Also holds the version gate and the regeneration procedure for herdr upgrades.
---

# herdr-adapter

All herdr interaction goes through the recipes in `references/v<pinned>.md`. No other skill or ad-hoc command may contain raw herdr syntax — this file is the single choke point that makes herdr upgrades survivable.

**Pinned version: 0.8.2** → `references/v0.8.2.md`

`references/v0.7.4.md` and `docs/herdr-schema-0.7.4.json` are kept for historical diffs only — never read them for syntax.

## Version gate (run once per session, before any other herdr command)

```bash
test "${HERDR_ENV:-}" = 1 || echo "NOT-INSIDE-HERDR"
herdr --version     # must print: herdr 0.8.2
herdr status        # server must be: running, compatible: yes
```

- `NOT-INSIDE-HERDR` → tell the operator; do not run any herdr control command.
- Version ≠ pin, or `compatible: no` → **stop dispatching**, tell the operator, follow Regeneration below. A newer binary can silently talk to an older running server; `herdr status` is the authority, not `--version` alone.

## Using recipes

Read `references/v0.8.2.md` and use recipes by name (R1–R10). Rules that apply to every recipe:

- Parse IDs and state from the JSON responses (python3; do not assume jq is installed). If a JSON shape differs from the reference, print it and read it — never guess a field.
- Always pass `--timeout` on waits (they have no default and block forever).
- `--no-focus` on anything background; never steal the operator's focus.
- Never: bare `herdr`, `herdr server stop`, closing panes/tabs/workspaces shepherd didn't create.

## Regeneration (on version change — an upgrade skill is deferred by design — do this manually with the operator)

1. Preconditions: zero active tasks; operator informed.
2. `herdr --version && herdr status` — record new version + protocol.
3. `herdr api schema --json > docs/herdr-schema-<new>.json`; diff against `docs/herdr-schema-<pinned>.json`.
4. Print each command group's help (`herdr pane`, `herdr agent`, `herdr workspace`, `herdr tab`, `herdr notification`, `herdr session`, `herdr api`, `herdr plugin`, `herdr integration`) and rewrite `references/v<new>.md` — same recipe names R1–R10, new syntax. Diff the socket surface too, not just the CLI: `python3` over the two schema JSONs comparing the `method` consts under `schemas.request` catches removals the help text does not advertise.
5. Update the pin here and in `CLAUDE.md` §7.
6. Run the canary end-to-end (a scripted smoke test is deferred by design — CLAUDE.md §9; run a small canary task by hand) from inside a herdr pane.
7. Commit: `herdr-adapter: regenerate for <new>`.
