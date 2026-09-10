# shepherd

A thin orchestrator for Claude Code, packaged as a plugin.

Shepherd receives a stream of thoughts from you, routes them to onboarded
projects, dispatches worker Claude Code sessions in [herdr](https://github.com/)
panes to do the actual work, watches them, unblocks them, verifies their results
against ground truth, and remembers. It never does project work in its own
context.

## Install

```bash
claude plugin marketplace add sakettawde/shepherd-plugin
claude plugin install shepherd@shepherd-plugins --scope user
```

Then create the repository that holds your data, and initialise it:

```bash
mkdir my-shepherd && cd my-shepherd && git init
claude
```

and run `/shepherd:init`. It seeds the instance skeleton, asks you the handful of
questions it cannot answer itself, writes `.shepherd/instance.env`, installs the
context-meter status line and seeds the project registry.

User scope is the right scope: workers launch in arbitrary project directories,
so a project-scope install would have to be added to every repository you work
in. Every command refuses outside a shepherd instance, and every worker hook
exits immediately without `SHEPHERD_TASK_ID`, so the plugin is inert in your
unrelated sessions.

## Requirements

- Claude Code 2.1.258 or later (measured against 2.1.267).
- [herdr](https://github.com/) 0.8.2 — the terminal multiplexer shepherd drives.
  The pin is in the manual §7; a different version stops dispatch until the
  adapter recipes are regenerated.
- `git` 2.31 or later (`git rev-parse --path-format=absolute`), `python3`, `bash`.

## What an instance repository holds

Data only:

```
CLAUDE.md                    ~15 lines: imports the two files below
.claude/shepherd-manual.md   GENERATED from the plugin, committed, never edited
.claude/settings.json        your permission rules
.shepherd/instance.env       the operator facts, committed
.shepherd/local.env          machine-specific overrides, gitignored
ledger/                      task cards, status JSONLs, attachments
registry/                    the project index and one card per project
decisions/                   the decision log
docs/reports/                whatever you keep
```

Everything else — the skills, the worker hooks, the ledger commands, the manual,
the framework specs and the test harness — is this plugin. There is no second
copy of a framework file to keep in step, and nothing to personalise.

## What the plugin provides

| Component | What |
|---|---|
| `skills/` | `/shepherd:wake`, `:triage`, `:dispatch`, `:monitor`, `:retro`, `:onboard`, `:init`, and `herdr-adapter` (model-invoked only) |
| `hooks/hooks.json` | the worker hooks — `Stop`, `Notification`, `PreToolUse Bash`, `PermissionRequest`, `PermissionDenied`, `StopFailure`, `SessionEnd` — plus the instance `SessionStart` hook that refreshes the manual copy |
| `bin/` | `shepherd-status`, `shepherd-lock`, `shepherd-card`, `shepherd-commit` and the rest, as bare commands on the Bash tool's `PATH` |
| `monitors/monitors.json` | `status-claims`, the harness-owned watcher over `ledger/status/` |
| `manual/shepherd.md` | the operating manual an instance imports |
| `templates/instance/` | the skeleton `/shepherd:init` copies into a fresh instance |
| `lib/` | the shared helpers every command sources — `shepherd-common.sh` resolves `SHEPHERD_ROOT` and holds the lock and card primitives |

## Updating

```bash
claude plugin update shepherd@shepherd-plugins
```

Auto-update is off by default for third-party marketplaces, which is what you
want: a framework update landing mid-dispatch is exactly the surprise the
version gate exists to prevent. A running session and every running worker keep
the version they loaded, so an update never interrupts a task. Wake step 1 reads
the installed version, refuses below `SHEPHERD_MIN_PLUGIN`, and reports a newer
release.

## Developing

```bash
git clone git@github.com:sakettawde/shepherd-plugin.git
cd shepherd-plugin
bash tests/run.sh
claude plugin validate . --strict
```

To run a shepherd instance on your working copy instead of the installed
version, launch it with `--plugin-dir`:

```bash
cd <your instance> && SHEPHERD_ID=shepherd-1 claude -n shepherd-1 --plugin-dir <path to this checkout>
```

A `--plugin-dir` plugin takes precedence over an installed plugin of the same
name for that session only, so one instance runs the working copy while every
other session keeps the release. `/reload-plugins` picks up skill, hook and bin
changes mid-session; monitors need a restart.

**Plugin first, always.** A framework change is a task card against this
repository, tested here and under `--plugin-dir`, released as a version, and
adopted by each instance at its next wake. Instances never carry framework
edits; a rule only one instance needs goes under `## Local overrides` in its
thin `CLAUDE.md`.

## Releasing

```bash
# bump "version" in .claude-plugin/plugin.json AND the marketplace entry — they
# must agree or `claude plugin tag` refuses — and add a CHANGELOG.md entry
claude plugin tag --push          # creates and pushes shepherd--v<X.Y.Z>
```

## License

MIT.
