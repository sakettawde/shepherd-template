---
description: Any herdr operation — spawning worker panes, launching workers, prompting, waiting, reading panes, notifications — and the version gate at session start. The only place herdr syntax lives; holds the regeneration procedure for upgrades.
user-invocable: false
---

# herdr-adapter

All herdr interaction goes through the recipes in `references/v<pinned>.md`; no other skill or ad-hoc command carries raw herdr syntax, which is what makes an upgrade one file's problem.

**Pinned version: 0.8.2** → `references/v0.8.2.md` (recipes R1–R10) and `references/surfaces-0.8.2.md` (surfaces shepherd does not use). `references/v0.7.4.md` and `${CLAUDE_PLUGIN_ROOT}/docs/herdr-schema-0.7.4.json` are history for diffs, never syntax.

## Version gate (once per session, before any other herdr command)

```bash
test "${HERDR_ENV:-}" = 1 || echo "NOT-INSIDE-HERDR"
herdr --version     # must print: herdr 0.8.2
herdr status        # server must be: running, compatible: yes
```

`NOT-INSIDE-HERDR` → tell the operator; run no herdr control command. Version off the pin, or `compatible: no` → **stop dispatching**, tell the operator, regenerate below. `herdr status` is the authority, not `--version` alone: a newer binary can silently talk to an older running server.

## Using recipes

Read `references/v0.8.2.md` and use recipes by name. Every recipe: parse IDs and state from the JSON (python3; no jq here), and print and read a shape that differs from the reference rather than guess a field; `--timeout` on every wait (none has a default); `--no-focus` on anything background; never bare `herdr`, never `herdr server stop`, never close a pane, tab or workspace shepherd did not create.

## Regeneration (on a version change — by hand with the operator until the M3 upgrade skill exists)

1. Zero active tasks; the operator informed.
2. `herdr --version && herdr status` — record version and protocol.
3. `herdr api schema --json > docs/herdr-schema-<new>.json`; diff against the pinned snapshot.
4. Print each command group's help (`herdr pane`, `agent`, `workspace`, `tab`, `notification`, `session`, `api`, `plugin`, `integration`) and rewrite `references/v<new>.md` — same recipe names R1–R10, new syntax. Diff the socket surface too: `python3` over the two schema JSONs comparing the `method` consts under `schemas.request` catches removals the help never advertises; the result is `references/surfaces-<new>.md`, the dated table of surfaces shepherd does not use.
5. Update the pin here and in the manual §7.
6. Canary: `bash shepherd-smoke` from inside a herdr pane with no active tasks — a real worker end to end, one PASS/FAIL per step, exit 0 only on 7/7; a FAIL names the step (its header holds the rest). Fix the recipe it exercises before dispatching anything. `--dry-run` proves the script against a stub, not the new herdr.
7. Commit: `herdr-adapter: regenerate for <new>`.
