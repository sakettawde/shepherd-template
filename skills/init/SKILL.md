---
description: A fresh shepherd instance, or one moved to a new machine: seed the skeleton, interview the operator, write .shepherd/instance.env, install the status line, seed the registry. Idempotent; run inside the instance directory.
---

# init

Turns the working directory into a **shepherd instance**: a repository that holds data only — ledger, registry, decisions, reports — and gets its framework from this plugin. The working directory must be a git repository; if it is not, say so and stop rather than seeding a directory git cannot track.

A directory with no `.shepherd/instance.env` is a fresh instance. One that has it is a re-run: skip every question the file already answers, and report what you kept.

The worker hooks are **not** registered here. They ship in this plugin's `hooks/hooks.json` and fire in every session where the plugin is enabled, which at user scope is every session on the machine. There is nothing to merge into `~/.claude/settings.json` and nothing to undo on uninstall.

## Steps

1. **Gates** — the herdr-adapter R1 gate (`HERDR_ENV`, `herdr --version` against the manual §7's pin, `herdr status`); on failure report what failed and what to install, then stop. Then `shepherd-output-style`: `style: DEGRADED` names the style file missing `keep-coding-instructions: true` and the repair; report it and continue — every worker lacks Claude Code's coding instructions until the operator fixes it (the manual §6).
2. **Seed the skeleton** — `shepherd-init seed`. It copies the thin `CLAUDE.md`, `.shepherd/instance.env`, `.claude/settings.json`, `.gitignore` and the empty `ledger/`, `registry/`, `decisions/` trees, and **never overwrites**: report its `created` and `kept` counts.
3. **Interview**, one question at a time, asking only what `instance.env` does not already answer: the operator's name; the code directory (default the parent of the working directory); notification sounds (default yes); the **worker cap**, a total across *all* instances on this machine (default 6); the **tier ladder** as three `<model>/<effort>` pairs (default `S=opus/high`, `standard=opus/high`, `heavy=opus/xhigh`; effort is a cost lever, not a quality dial, and `max` stays off the ladder — the manual §6); the **shepherd ids** as a scheme — `SHEPHERD_ID=shepherd-<name>`, lowercase letters and digits, hyphen-joined, the same id passed to `-n` and `--remote-control`; default `shepherd-1`.
4. **Write `.shepherd/instance.env`** — replace only the values, never the comments or the file's shape. On a **second machine sharing one instance repository**, put the machine-specific values in a gitignored `.shepherd/local.env` beside it instead, so the committed file stays true for both. A new machine that is getting its *own* instance and its own ledger writes the committed file normally.
5. **Install the status line** — `shepherd-statusline`, the context meter `shepherd-rollover decide` reads (the manual §8): idempotent, a differing copy kept as `statusline.py.prev`; report its line. `shepherd-rollover decide --self-test` confirms with `meter: statusline.py installed and current, statusLine registered` (two DEGRADED pane checks on a fresh session are normal).
6. **Seed the registry** — `shepherd-init registry <code-dir>`; report the rows.
7. **Sync the manual** — `shepherd-manual sync`; it should print `refreshed` on a fresh instance. This is the generated `.claude/shepherd-manual.md` the thin `CLAUDE.md` imports.
8. **Commit** — `shepherd-commit "init: shepherd instance configured" CLAUDE.md .shepherd/instance.env .claude/settings.json .claude/shepherd-manual.md .gitignore registry/projects.md`; name the paths, never `git add -A` (the manual §2 rule 6). A re-run that changed nothing commits nothing — say so.
9. **Trust the workspace once.** A repository whose trust dialog has never been accepted has its `.claude/settings.json` allow list **ignored entirely** — measured 2026-09-10 on Claude Code 2.1.267: `Ignoring 22 permissions.allow entries from .claude/settings.json: this workspace has not been trusted`. The plugin's hooks and `bin/` are unaffected, so this shows up as permission prompts for commands the seeded allow list already covers. Tell the operator to accept the dialog once in this directory. Plugin hooks are **not** gated this way: they fire in a directory that has never been trusted (measured the same day).
10. **Confirm** in one line: operator, code dir, cap, ladder, registry rows, and the manual §1 launch line with their `SHEPHERD_ID` in all three places. Then tell them to restart the session, because `CLAUDE.md` and its imports are read at launch and this run wrote both.

## Hard lines

- This skill writes nothing outside the instance directory except `~/.claude/statusline.py` and its `.prev`, and the `statusLine` key in `~/.claude/settings.json`. It never touches that file's `hooks` — the plugin owns those.
- Never overwrite a file the operator already has. `shepherd-init seed` refuses by design; keep that stance for every hand edit too.
- A failed step stops the run — report it; never leave the instance half-initialized silently.
