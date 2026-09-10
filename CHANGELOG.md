# Changelog

## 1.0.0 — unreleased

First release as a Claude Code plugin. The framework previously lived twice —
once in this repository and once in each instance — kept in step by cherry-pick.
It now lives here only.

### The shape

- The repository root is the plugin root and doubles as its own single-plugin
  marketplace, `shepherd-plugins`, through `"source": "./"`.
- `.claude/skills/` became `skills/`; the `init-shepherd` skill became `init`,
  so every skill is `/shepherd:<name>`. No skill sets a `name:` field, so no
  un-namespaced alias exists to collide with anything.
- `scripts/*.sh` became bare `shepherd-*` commands in `bin/`, on the Bash tool's
  `PATH` in every session where the plugin is enabled. `shepherd-status` reaches
  a worker without a `PATH` prepend on its launch line.
- `CLAUDE.md` became `manual/shepherd.md`. An instance carries a generated,
  committed copy at `.claude/shepherd-manual.md` that its thin `CLAUDE.md`
  imports; the plugin's `SessionStart` hook refreshes it and wake step 1 commits
  it.
- The `## 0. Operator` block became `.shepherd/instance.env` — committed,
  machine-readable, imported by the thin `CLAUDE.md`, so scripts and model read
  the same lines. A gitignored `.shepherd/local.env` overrides the
  machine-specific values.
- `FRAMEWORK.md` is retired. There is no second copy of a framework file, so
  there is nothing to keep in step.

### New

- `hooks/hooks.json` ships the seven worker hooks. They no longer have to be
  merged into `~/.claude/settings.json` per machine.
- `monitors/monitors.json` ships `status-claims`, a harness-owned monitor that
  delivers one notification per new wake-worthy record in `ledger/status/`. It
  replaces the hand-armed primary status watcher.
- `shepherd-manual sync|check` — the one place the plugin's manual and an
  instance's generated copy are compared.
- `shepherd-paths [<relative-path>]` — prints a path inside the installed
  plugin. Shell commands need it because `${CLAUDE_PLUGIN_ROOT}` is not set in
  the Bash tool's environment and expands to the empty string there.
- `shepherd-init` grew `seed` and `registry` verbs; `seed` copies
  `templates/instance/` into a fresh instance and never overwrites.
- `lib/status_wake.py` — the wake-set predicate, extracted so the per-task
  watcher and the monitor read one copy and cannot drift.

### Changed

- `SHEPHERD_ROOT` resolves by three rungs and no default: the environment; else
  `git rev-parse --path-format=absolute --git-common-dir`, which resolves a
  `shepherd~N` worktree lane to its base checkout; else refuse. The resolved
  root must hold `.shepherd/instance.env`. The hard-coded
  one-machine default is gone, which is what made the framework
  usable by anyone else.
- `shepherd-init` resolved the registry against its own directory, which after
  the move would have been the plugin rather than the instance. It now resolves
  the instance explicitly.
