# Shepherd as a Claude Code plugin — packaging design and migration plan

**Date:** 2026-09-02
**Task:** T-0218 (introspection report R7, phase 1, wave 1)
**Status:** outline approved by shepherd-kelpie 2026-09-02; this is the full note. Nothing moves yet — the wave-3 build card executes it.
**Claude Code measured against:** 2.1.258 (`claude --version`, 2026-09-02). Every doc citation below was read on 2026-09-02; the URL table is in §11.

## 0. The decision in one screen

The framework — skills, worker hooks, scripts, templates, the manual, the framework specs, the test harness — becomes **one Claude Code plugin named `shepherd`**, published from the existing `shepherd-template` repository, which becomes its own single-plugin GitHub marketplace. An instance repository (this one) keeps only data: ledger, registry, decisions, reports, a ten-line `CLAUDE.md`, a committed `.shepherd/instance.env`, its permission rules, and one **generated, committed** copy of the manual that a plugin `SessionStart` hook refreshes and a wake step commits.

What this buys, each grounded in a doc claim or a live probe (§0.1):

- **No port.** Framework edits land in the plugin repo, are released as a version, and every instance updates with one command. The cherry-pick, the re-personalisation conflicts, and FRAMEWORK.md's table all go away.
- **Worker hooks travel by themselves.** A plugin's `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json` fires in every session where the plugin is enabled; at user scope that is every session on the machine, which is exactly what init-shepherd's user-global registration achieves today by hand.
- **`shepherd-status` is a bare command in every worker.** A plugin `bin/` is on the Bash tool's PATH while the plugin is enabled — measured in this very worker session.
- **The status-file watcher becomes a plugin monitor** the harness starts and owns, instead of an eight-line recipe re-typed at every dispatch.
- **Skill names gain the `shepherd:` prefix.** `/shepherd:wake` replaces the un-namespaced `wake`, and the probe shows the bare form does not resolve, so every explicit invocation changes.

### 0.1 The probe (throwaway, scratchpad only)

The docs were silent on three things the design depends on, so a throwaway plugin was loaded with `--plugin-dir` into a headless (`-p`, haiku) session in a scratch project, with every shepherd and herdr variable stripped from the environment so no hook could touch the ledger or the pane registry. Nothing from it is in this repo. Measured 2026-09-02:

| Question | Result |
|---|---|
| Does a plugin `SessionStart` hook run **before** `CLAUDE.md` and its `@imports` are read? | **Yes.** `SessionStart` fired at t = 1788330143.232; `InstructionsLoaded` for `CLAUDE.md` at t = .312, for the imported `generated.md` at t = .313 (`load_reason: include`). The hook rewrote `generated.md` from `STALE` to `STAMP-1788330143`, and the model reported `second=STAMP-1788330143`. The same session reads what its own hook wrote. |
| Is a plugin `bin/` on the Bash tool's PATH, and does a bin script see `CLAUDE_PLUGIN_ROOT`? | **On PATH: yes**, also for a `--plugin-dir` plugin (`bin=hello-from-bin self=<plugin>/bin/shepproto-hello`). This worker session's own PATH already carries `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/bin` for every enabled plugin. **`CLAUDE_PLUGIN_ROOT` in the bin script: unset** — bin scripts self-locate from `$0`. |
| Which plugin variables reach a **hook**? | `CLAUDE_PLUGIN_ROOT=<plugin dir>`, `CLAUDE_PLUGIN_DATA=~/.claude/plugins/data/shepproto-inline`, `CLAUDE_PROJECT_DIR=<project>`. Note the data-dir id for a `--plugin-dir` plugin is `<name>-inline`, not `<name>-<marketplace>`. |
| Does a plugin skill answer to its **bare** name? | **No** (headless, no `name:` frontmatter): `/ping` → `Unknown command: /ping`; `/shepproto:ping` → `PONG-OK`. |
| Does `git rev-parse --git-common-dir` resolve a `shepherd~N` lane to the base checkout? | **Yes**: from a `shepherd-wt6` lane it prints `<instance-root>`; from the base checkout, the same. |

Two further facts read from this machine, not the docs: the Bash tool's environment carries `SHEPHERD_TASK_ID`, `SHEPHERD_STATUS_FILE`, `HERDR_*` and `CLAUDE_CODE_SUBAGENT_MODEL` from the launch line but **no** `CLAUDE_PLUGIN_*` or `CLAUDE_PROJECT_DIR`; and the Skill tool in this session lists plugin skills as `superpowers:brainstorming`, `commit-commands:commit`, so a prose reference to "the triage skill" resolves to `shepherd:triage` without a path.

## 1. Layout

**Recommendation.** `sakettawde/shepherd-template` continues its history and becomes the plugin repository (rename to `shepherd-plugin`, drop the GitHub "template repository" flag; §9 Q1). The repository root **is** the plugin root, and the same repository carries `.claude-plugin/marketplace.json` listing one plugin with `"source": "./"`. Plugin name `shepherd`, marketplace name `shepherd-plugins`; the enable key is therefore `shepherd@shepherd-plugins` and skills are `/shepherd:<name>`.

**Basis.** A plugin is a directory whose components sit at the plugin root (`skills/`, `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json`, `bin/`, `monitors/monitors.json`, `templates/` is free-form, `scripts/` is conventional) with an optional `.claude-plugin/plugin.json`; only `plugin.json` lives inside `.claude-plugin/` (https://code.claude.com/docs/en/plugins-reference#plugin-directory-structure, 2026-09-02). A marketplace entry may use `"source": "./"` so the marketplace root doubles as the plugin root; relative sources resolve against the marketplace root, not `.claude-plugin/` (https://code.claude.com/docs/en/plugin-marketplaces#advanced-plugin-entries and #relative-paths, 2026-09-02). Marketplace-installed plugins are **copied** into `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`, and a plugin cannot reference files above its own root (#path-traversal-limitations, same page). A `CLAUDE.md` at the plugin root "is not loaded as project context" (plugins-reference, same section) — which is why §2 exists.

**Rejected.** A new repository: loses fifteen PRs of recorded rationale for a cleanliness the template already has (its history was scrubbed on 2026-08-05). The plugin as a subdirectory of the instance repo: the cache copies the whole source directory, so an instance's ledger would ride along, and huntaway's machine would need the private repo just to get hooks.

### 1.1 What the plugin contains

| Plugin path | Comes from (instance today) | Notes |
|---|---|---|
| `.claude-plugin/plugin.json` | new | `name: shepherd`, explicit semver `version`, `description`, `repository` |
| `.claude-plugin/marketplace.json` | new | `name: shepherd-plugins`, one entry `shepherd`, `source: "./"` |
| `skills/<name>/SKILL.md` (+ `references/`) | `.claude/skills/<name>/` | eight skills; `init-shepherd` becomes `init` (`/shepherd:init`) |
| `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json` | the three entries init-shepherd writes into `~/.claude/settings.json` | exec form, `"command": "${CLAUDE_PLUGIN_ROOT}/hooks/<script>", "args": []` |
| `${CLAUDE_PLUGIN_ROOT}/hooks/worker-*.sh` | `hooks/` | plus T-0214's `PermissionRequest`, `PermissionDenied`, `StopFailure`, `SessionEnd` hooks |
| `${CLAUDE_PLUGIN_ROOT}/hooks/instance-session-start.sh` | new | manual sync + context injection, gated on an instance marker (§2, §4) |
| `${CLAUDE_PLUGIN_ROOT}/bin/shepherd-*` | `scripts/*.sh` | see 1.2; bare commands on the Bash PATH |
| `${CLAUDE_PLUGIN_ROOT}/lib/shepherd-common.sh` | `scripts/lib/` | `SHEPHERD_ROOT` ladder (§4) |
| `monitors/monitors.json` | new | one monitor, `when: on-skill-invoke:wake` (§6) |
| `${CLAUDE_PLUGIN_ROOT}/templates/task-card.md` | `templates/` | unchanged |
| `${CLAUDE_PLUGIN_ROOT}/templates/instance/` | new | skeleton `shepherd-init` copies into a fresh instance: thin `CLAUDE.md`, `.shepherd/instance.env`, `.claude/settings.json`, `.gitignore`, empty `ledger/` `registry/` `decisions/` |
| `${CLAUDE_PLUGIN_ROOT}/manual/shepherd.md` | `CLAUDE.md` minus `## 0. Operator` | T-0222 shapes it; §2 says how it reaches an instance |
| `docs/specs/*.md`, `docs/herdr-schema-*.json`, `${CLAUDE_PLUGIN_ROOT}/docs/writing-for-agents.md` | same paths | framework specs only (multi-shepherd, context-rollover, template design, this note) |
| `tests/` | `scripts/tests/` | run from the plugin checkout; `test-docs.sh` asserts on `manual/` and `skills/` |
| `README.md`, `CHANGELOG.md` | `README.md`, `FRAMEWORK.md` | README = adoption guide; FRAMEWORK.md is retired (§8) |

The instance repository keeps: `CLAUDE.md` (≈10 lines, §2), `.claude/shepherd-manual.md` (generated, committed, §2), `.shepherd/instance.env` (§4), `.claude/settings.json` (permissions only, §4), `.gitignore`, `ledger/`, `registry/`, `decisions/`, `docs/reports/` and the other instance docs, a short `README.md`.

### 1.2 Script renames

| Today | Plugin `bin/` | Notes |
|---|---|---|
| `shepherd-lock` | `shepherd-lock` | |
| `shepherd-reserve` | `shepherd-reserve` | |
| `shepherd-commit` | `shepherd-commit` | still refuses off `main` |
| `shepherd-identity` | `shepherd-identity` | |
| `shepherd-rollover` | `shepherd-rollover` | `ROLLOVER_MSG` default becomes `/shepherd:wake` (§3); the `self-recycle.sh` shim is dropped |
| `shepherd-drill` | `shepherd-drill` | |
| `shepherd-init` | `shepherd-init` | grows the mechanical half of init: seed the instance skeleton, seed the registry, write `instance.env` |
| `shepherd-watch` (T-0214) | `shepherd-watch` | gains a `monitor` subcommand (§6) |
| `shepherd-status` (T-0214) | `shepherd-status` | |
| new | `shepherd-manual` | `sync` / `check` (§2) |

Every script sources `${CLAUDE_PLUGIN_ROOT}/lib/shepherd-common.sh` relative to `$0` (`"$(dirname "$0")/../lib/shepherd-common.sh"`), because the probe shows bin scripts get no `CLAUDE_PLUGIN_ROOT`.

### 1.3 Inventory the build must rewrite (measured on this main, 2026-09-02)

- Hard-coded home-directory paths: `CLAUDE.md` 1, `scripts/lib/shepherd-common.sh` 1, `dispatch/SKILL.md` 2, `herdr-adapter/references/v0.8.2.md` 4, `onboard/SKILL.md` 2. All become `$SHEPHERD_ROOT` or `<code-dir>` from `instance.env`.
- Repo-relative script and file references inside skills and the manual: about 70 lines (`shepherd-lock` ×14, `shepherd-commit` ×8, `shepherd-rollover` ×6, `${CLAUDE_PLUGIN_ROOT}/templates/task-card.md` ×6, adapter reference paths, herdr schema paths). Scripts become bare `shepherd-*` commands; files become `${CLAUDE_PLUGIN_ROOT}/…` (§3).
- Explicit the un-namespaced `wake`: `CLAUDE.md` 2, `shepherd-rollover` 4 (the default plus comments), adapter reference 1. All become `/shepherd:wake`.
- `scripts/tests/test-docs.sh`: 382 lines of wording assertions against `CLAUDE.md` and four skills. It moves to `tests/` and targets `${CLAUDE_PLUGIN_ROOT}/manual/shepherd.md`.

## 2. The manual

**Recommendation.** The plugin ships the framework manual as `${CLAUDE_PLUGIN_ROOT}/manual/shepherd.md`. The plugin's `SessionStart` hook (`${CLAUDE_PLUGIN_ROOT}/hooks/instance-session-start.sh`) copies it to `<instance>/.claude/shepherd-manual.md` when the two differ. That file is **generated and committed**. The instance `CLAUDE.md` shrinks to about ten lines:

```markdown
# shepherd instance
This repository is a shepherd instance; the framework is the `shepherd` plugin (see .claude/shepherd-manual.md, generated — never edit).
@.claude/shepherd-manual.md
@.shepherd/instance.env
## Local overrides
<!-- instance-specific standing rules only; keep short -->
```

**Who commits the generated copy.** A wake step does, as ledger state. Wake step 1 (version gate) grows a third check after the herdr version and the plugin version: `shepherd-manual check`, which reports `current | refreshed | lane-stale | missing`. On `refreshed` — the hook just rewrote the file, so `git status --porcelain .claude/shepherd-manual.md` shows it modified — the step runs `shepherd-commit "framework: manual synced to shepherd v<X.Y.Z>" .claude/shepherd-manual.md`. That command is today's `shepherd-commit`: path-scoped, retried on the index and ref races, and refusing on any branch but `main`. Two instances waking after the same plugin update both write identical bytes; the first commit wins and the second finds a clean file and commits nothing. No card lock is needed: the content is a function of the installed plugin version, so there is nothing two writers could disagree about.

**Inside a `shepherd~N` worktree lane.** A lane has the committed `.shepherd/instance.env` too, so the marker alone does not distinguish it. The hook therefore also asks git: when `git -C "$CLAUDE_PROJECT_DIR" rev-parse --git-dir` and `--git-common-dir` differ, the session is in a worktree. In a lane the hook **writes nothing** — a generated diff on a task branch would land in the worker's commit and pollute the merge — and stays silent unless the lane's committed copy differs from the plugin's manual, in which case it injects one factual line of `additionalContext`: "This lane carries the manual as committed at <sha>; the installed plugin ships v<X>. The base checkout at <root> holds the current copy; `.claude/shepherd-manual.md` is generated and is not edited here." The line exists so a worker on a shepherd-self card does not "fix" the generated copy. A worker session reads the manual as it was committed on the commit it checked out, which is the correct behaviour for the product it is editing.

**Cost in always-loaded tokens.** The report measured ≈21k tokens loaded at every wake today (CLAUDE.md + memory index + wake skill + adapter reference); T-0222 targets roughly half. Packaging changes that figure by ≈0: an `@import` "still load[s] and enter[s] the context window at launch" (memory doc), so the same text costs the same tokens wherever it lives. The additions are the hook's `additionalContext` (plugin version, resolved `SHEPHERD_ROOT`, manual state — under 100 tokens) and the plugin skills' listing text, which is already paid today for the eight project skills; `claude plugin details shepherd` prints the always-on figure and the build card records it (§10).

**Basis.** Imports: `@path` expands at launch, relative to the file that contains it, recursively to four hops; imported files enter context at launch; `CLAUDE.local.md` is gitignored and "only exists in the worktree where you created it"; an import that resolves outside the working directory is *external* and triggers a one-time approval dialog per project (https://code.claude.com/docs/en/memory#import-additional-files, 2026-09-02). Size target under 200 lines per file (same page, #write-effective-instructions). Hook ordering: probe §0.1 (hook before import read). `additionalContext` "capped at 10,000 characters" and delivered for `SessionStart` "at the start of the conversation, before the first prompt"; static instructions belong in CLAUDE.md (https://code.claude.com/docs/en/hooks#add-context-for-claude, 2026-09-02). `SessionStart` fires again on `resume`, `clear`, `compact` and `fork`, so the copy is re-checked after a rollover's `/clear` (same page, #sessionstart). Skill content re-attached after compaction keeps only the first 5,000 tokens per skill within a 25,000-token budget (https://code.claude.com/docs/en/skills#skill-content-lifecycle, 2026-09-02). A plugin-root `CLAUDE.md` is not loaded (plugins-reference, #plugin-directory-structure).

**Rejected, one line each.** *Keep the manual in the instance CLAUDE.md*: the drift this task exists to end. *Inject the whole manual as `SessionStart` `additionalContext`*: the 10,000-character cap; the manual is ≈40k characters today and stays above the cap after T-0222's halving. *Carry it as a skill*: loads only when invoked, is capped at 5k tokens after compaction, and a session that never invokes it has no rules. *Import from the plugin cache path*: `${CLAUDE_PLUGIN_ROOT}` "changes when the plugin updates" (plugins-reference, #environment-variables), so the import breaks on every release. *Import from `~/.claude/shepherd/manual.md`*: an external import raises the approval dialog once per project path, and each worktree lane is a project path a worker cannot answer a dialog in. *A `.claude/rules/` symlink to the data dir*: same external-target dialog, and the link is untracked in lanes. *`CLAUDE_PLUGIN_DATA` as the copy's home*: its id differs between an installed plugin (`shepherd-shepherd-plugins`) and a `--plugin-dir` session (`shepherd-inline`, probe), so dev sessions would read the installed manual.

## 3. Skill invocation

**Recommendation.** Every explicit invocation uses the full name. `ROLLOVER_MSG` in `shepherd-rollover` defaults to `/shepherd:wake`; the two the un-namespaced `wake` mentions in the manual and the adapter reference follow; `${CLAUDE_PLUGIN_ROOT}/tests/test-docs.sh` asserts that no bare the un-namespaced `wake`, the un-namespaced `triage`, … remains in plugin text. Prose references ("run the **triage** skill", "adapter R5") stay as they are: the Skill tool lists plugin skills under their full names, so the model resolves them. File references inside skills become `${CLAUDE_PLUGIN_ROOT}/skills/herdr-adapter/references/v0.8.2.md`, `${CLAUDE_PLUGIN_ROOT}/templates/task-card.md`, `${CLAUDE_PLUGIN_ROOT}/docs/herdr-schema-0.8.2.json`; script references become the bare `shepherd-*` commands of §1.2. Kickoff pointers to workers are unchanged — a worker receives a card path, never a skill name. `herdr-adapter` gets `user-invocable: false` (background knowledge, not an action); the other seven stay invocable by both Saket and the model, and none sets `disable-model-invocation` because shepherd invokes its own skills. Saket's habit: `/shepherd:wake`, `/shepherd:triage`; `/she` + Tab completes.

**Basis.** "Plugin skills are always namespaced (like `/my-first-plugin:hello`)"; after converting, "the original `/skill-name` and the plugin copy both remain available" while the originals exist (https://code.claude.com/docs/en/plugins#create-your-first-plugin and #what-changes-when-migrating, 2026-09-02). Command name = plugin prefix + frontmatter `name` or directory name (https://code.claude.com/docs/en/skills#how-a-skill-gets-its-command-name, 2026-09-02); the same section says a `name`-field skill's bare name "also invokes the skill unless another command already uses that name", but the probe (§0.1) shows a bare name **failing** in a headless session — the recovery prompt is typed into a fresh session by a watchdog and must not depend on a conditional, so the full form is mandatory. `${CLAUDE_PLUGIN_ROOT}` is substituted "anywhere the placeholder appears" in skill content (plugins-reference, #environment-variables); `user-invocable: false` hides a skill from the `/` menu while Claude can still invoke it (skills, #control-who-invokes-a-skill).

**Rejected.** A one-letter plugin name to shorten typing: it also prefixes every log line, `ListAgents`-adjacent listing and `enabledPlugins` key; clarity wins. Keeping bare-name invocations and relying on the fallback: disproved for the case that matters.

## 4. Instance identity and paths

**Recommendation.**

- **`SHEPHERD_ROOT`** resolves in `${CLAUDE_PLUGIN_ROOT}/lib/shepherd-common.sh` by a three-rung ladder and no default: the environment variable if set; else `git rev-parse --path-format=absolute --git-common-dir` from `$PWD` with the trailing `/.git` stripped; else refuse with an error. The result must contain `.shepherd/instance.env`, or the script refuses — the same fail-closed stance `shepherd-lock` already takes on an empty holder. Rung two is what makes a `shepherd~N` lane write into the base checkout (probe §0.1), which is the reason the path is hard-coded today (registry Gotcha, T-0114). The test harness's `sandbox()` already exports `SHEPHERD_ROOT`, so tests are unchanged.
- **`SHEPHERD_ID`** stays launch environment, as CLAUDE.md §1 has it. The canonical launch line loses nothing and gains nothing: `cd <instance> && SHEPHERD_ID=shepherd-collie claude -n shepherd-collie --remote-control shepherd-collie`.
- **`.shepherd/instance.env`**, committed, is the single machine-readable source for the operator facts. `## 0. Operator` leaves `CLAUDE.md`; the file is imported by the thin `CLAUDE.md` (§2) so the model reads the same lines the scripts do:

  ```sh
  SHEPHERD_INSTANCE=1                    # the marker hooks and scripts gate on
  SHEPHERD_OPERATOR=Saket
  SHEPHERD_CODE_DIR=<code-dir>
  SHEPHERD_NOTIFICATIONS=sounds          # or: silent
  SHEPHERD_WORKER_CAP=6                  # total across ALL instances
  SHEPHERD_IDS="shepherd-collie shepherd-kelpie shepherd-huntaway"
  SHEPHERD_MIN_PLUGIN=1.0.0              # wake refuses on an older plugin
  ```

  A gitignored `.shepherd/local.env` may override machine-specific values (`SHEPHERD_CODE_DIR`) on a second machine; `shepherd-init` writes both.
- **Permission rules** stay in the instance `.claude/settings.json`, framework-shaped but instance-owned: `shepherd-init` seeds it from `${CLAUDE_PLUGIN_ROOT}/templates/instance/.claude/settings.json`, and wake step 1 diffs the two and reports drift. A plugin cannot carry them — a plugin `settings.json` supports only `agent` and `subagentStatusLine`.
- **The instance-side hook** (`${CLAUDE_PLUGIN_ROOT}/hooks/instance-session-start.sh`) and every `bin/` script gate on the marker, not on a path: hooks test `$CLAUDE_PROJECT_DIR/.shepherd/instance.env`; bin scripts test `$SHEPHERD_ROOT/.shepherd/instance.env`. Worker hooks keep their existing gate, `SHEPHERD_TASK_ID`, and need no root at all: the launch line hands them `SHEPHERD_STATUS_FILE` as an absolute path (adapter R3).
- **Hook `additionalContext`** at session start, in the base checkout only: plugin version, resolved `SHEPHERD_ROOT`, manual state, and `SHEPHERD_ID` as seen in the environment. Written as facts, not instructions.

**Basis.** Probe §0.1 for `--git-common-dir` and for which variables reach hooks (`CLAUDE_PROJECT_DIR`, `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA`) versus the Bash tool (none of them). `${CLAUDE_PROJECT_DIR}` "stays put" when Claude enters a worktree while the hook input's `cwd` follows it (https://code.claude.com/docs/en/hooks#reference-scripts-by-path, 2026-09-02). Hook processes "inherit the parent environment" (same page, #common-input-fields). Plugin `settings.json`: "only the `agent` and `subagentStatusLine` keys are supported" (https://code.claude.com/docs/en/plugins#ship-default-settings-with-your-plugin, 2026-09-02). `CLAUDE.local.md` is per-worktree and gitignored (memory doc, #import-additional-files). `pluginConfigs`/`userConfig` values are read from user settings only and never from a repository's `.claude/settings.json` (plugins-reference, #user-configuration) — which is why the worker cap is not a plugin `userConfig` option: it is instance state, and the instance repo must carry it.

**Rejected.** *Hard-coded default root*: breaks the second machine and every adopter. *`CLAUDE.local.md` for the operator block*: absent in lanes and on the other machine by the doc's own description. *`userConfig` for worker-cap and ids*: stored per user in `~/.claude/settings.json`, not per instance, and unreadable by monitor commands. *`CLAUDE_PLUGIN_DATA` for instance state*: id differs between installed and `--plugin-dir` (probe).

## 5. Hooks in worker sessions

**Recommendation.** `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json` carries the three worker hooks that exist (Stop, Notification with the exact-string matcher, PreToolUse Bash) and T-0214's four new events, in exec form with `${CLAUDE_PLUGIN_ROOT}/hooks/<script>` and `"args": []`, `timeout: 10`, plus the instance-side `SessionStart` hook on `startup|resume|clear|compact|fork`. The `SHEPHERD_TASK_ID` gate stays the first line of every worker hook. **User scope is the right scope**: workers launch in arbitrary project directories, and a project-scope enable would have to be added to every onboarded repo. init-shepherd's step 4 (the python merge into `~/.claude/settings.json`) is deleted; the user-global file keeps only herdr's own `SessionStart` entry, which is herdr's, not shepherd's.

Three behaviours the build must respect:

1. **Duplicate handlers.** "If you define the same handler in more than one settings file, it runs once. A plugin's or skill's copy of the same handler stays separate." While both the settings entries and the plugin are live, every worker Stop writes two status lines. The count-anchored watcher still fires (the count only has to grow), but §8 sequences the removal so the window is short and contains no worker that started before the plugin was installed.
2. **`SessionEnd` budget.** All `SessionEnd` hooks share 1.5 s, raised only by timeouts set in *settings files*: "Timeouts set on plugin-provided hooks don't raise the budget." T-0214's `SessionEnd` hook must finish inside 1.5 s — one append, no python if it can be avoided.
3. **Workspace trust.** Interactive sessions hold back hooks "from every settings file, including your own `~/.claude/settings.json`, until you accept the workspace trust dialog"; the doc does not say whether plugin hooks are held the same way. Every worker runs in a repository Saket has already trusted, so this is not a live concern, but the build card verifies it once on a fresh scratch directory. Marked `unverified`.

**Basis.** Hook locations table — plugin `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json` scope "when plugin is enabled"; hooks from settings, managed policy and plugins also run inside subagents; the duplicate-handler rule; exec form and placeholders; the `SessionEnd` budget sentence (https://code.claude.com/docs/en/hooks#hook-locations, #hook-handler-fields, #sessionend, 2026-09-02). Plugin hooks merge with user and project hooks when enabled (same page, "Plugin scripts" tab). Scope table: user scope = `~/.claude/settings.json`, "available across all projects (default)" (plugins-reference, #plugin-installation-scopes). Project settings take precedence over user settings for `enabledPlugins`, so any single project can opt out with `"shepherd@shepherd-plugins": false` in its `.claude/settings.local.json` (https://code.claude.com/docs/en/settings-reference#enabledplugins, 2026-09-02).

**Rejected.** *Project-scope enablement per onboarded repo*: N repos to keep in step, and a worker in a not-yet-onboarded scratch dir has no guardrail. *Skill-frontmatter hooks*: registered only once a skill is invoked, and workers invoke none of shepherd's skills.

## 6. `bin/` and monitors

### 6.1 `bin/`

`shepherd-status done "<one-liner>"` reaches every worker as a bare command: a plugin's `bin/` is "added to the Bash tool's PATH and invokable as bare commands while the plugin is enabled" (plugins-reference, #file-locations-reference), and this worker session's PATH shows the mechanism live (§0.1). The dispatch launch line needs no path. Because the plugin is enabled at user scope, `shepherd-*` is on the PATH of every session on the machine, including Saket's unrelated ones — harmless, since every command refuses without `SHEPHERD_TASK_ID`/`SHEPHERD_STATUS_FILE` (workers) or an `instance.env` under the resolved root (instance commands), and the `shepherd-` prefix keeps the namespace clean. `bin/` is refused only for plugins distributed through claude.ai organisation settings (plugin-marketplaces, #keep-executables-out-of-the-top-level-bin-directory), which does not apply.

### 6.2 The monitor

**Recommendation.** One plugin monitor:

```json
[
  {
    "name": "status-claims",
    "command": "\"${CLAUDE_PLUGIN_ROOT}\"/bin/shepherd-watch monitor",
    "description": "new terminal claims and worker session events in ledger/status",
    "when": "on-skill-invoke:wake"
  }
]
```

`when: on-skill-invoke:wake` is load-bearing: a monitor with the default `always` "starts it at session start" in **every** session where the plugin is active — every worker, every unrelated session. Tied to `wake`, it starts the first time `/shepherd:wake` runs, which is only ever a shepherd instance session, and after a rollover the fresh session's `/shepherd:wake` starts a new one while the old one died with its session.

`shepherd-watch monitor` resolves `SHEPHERD_ROOT` (§4), records the current count of wake-worthy records per file, then polls `ledger/status/*.jsonl` every two seconds and prints **one line per new record** of a wake-worthy kind — the terminal claims `done|blocked|failed` and T-0214's `SessionEnd`, `StopFailure` and `PermissionRequest` kinds; never `working`, never `idle_prompt` — in the form:

```
T-0214 claim=blocked file=<instance-root>/ledger/status/T-0214.jsonl n=7 ts=2026-09-02T09:41:02+0530
```

Each line lands in the session that started the monitor as a notification, so the shepherd instance wakes within seconds of a hook write with no watcher to arm, no count to anchor and no re-arm on any wake. This replaces adapter R5's *primary* watcher and the `shepherd-watch arm/rearm` machinery for it. It **complements** the secondary stall watcher — `herdr agent wait <pane> --until blocked --timeout <ms>` is a herdr call per worker pane and stays a background Bash task armed by `shepherd-watch arm`.

**Two instances sharing one checkout.** collie and kelpie both run `/shepherd:wake`, so two monitor processes tail the same status directory. That is by design, and the line format above is what makes it safe: the line carries the **task id**, and the receiving instance's wake handler — the monitor skill's entry — reads `owner:` from the card *before anything else* and treats a card it does not own as a no-op: no ladder, no Log line, no re-arm, no report. The cost is one extra wake per claim for the non-owner, which ends at the first grep. Filtering by `SHEPHERD_ID` inside the monitor process is **rejected** because whether a monitor process inherits the session's environment is not documented (`unverified`); a monitor that filtered on an unset id would print nothing and lose every wake silently, whereas the handler-side filter fails loud and cheap. Monitor `name`s are unique per plugin per session, so each instance gets its own process; two readers of an append-only directory contend on nothing.

**What the monitor cannot do.** It cannot wake a *different* session — kelpie's monitor never wakes collie — so cross-instance handoff stays `SendMessage` (§4a). It cannot replace the rollover watchdog, which must outlive the session. It does not run in headless sessions ("run only in interactive CLI sessions"), which shepherd never is. It is unavailable when `DISABLE_TELEMETRY` or `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is set, or on Bedrock/Vertex/Foundry — none of which this instance uses; wake step 1 confirms a `status-claims` monitor is running among the session's background tasks and falls back to `shepherd-watch arm` for the primary watcher if it is not. Whether a monitor line wakes an *idle* shepherd turn the way the Monitor tool's events do ("Claude interjects when an event arrives") is documented for the tool and stated as "the same mechanism" for plugin monitors; the build card verifies it on the first live dispatch before R5's hand-armed primary is retired (`unverified` until then).

**Basis.** Monitors: location, fields, `when` values, "delivers every stdout line to Claude as a notification", "use the same mechanism as the Monitor tool and share its availability constraints", "run only in interactive CLI sessions", monitor commands substitute `${CLAUDE_PLUGIN_ROOT}` and run in the session working directory, don't receive `CLAUDE_PLUGIN_OPTION_*`, keep running if the plugin is disabled mid-session, and "require a session restart" to pick up an update (https://code.claude.com/docs/en/plugins-reference#monitors and #environment-variables, 2026-09-02). Monitor tool: interjection on events, Bash permission rules apply, unavailable under the two env flags and on the three hosted platforms (https://code.claude.com/docs/en/tools-reference#monitor-tool, 2026-09-02). Because monitor commands follow Bash permission rules and auto mode's classifier, the instance `.claude/settings.json` allow list adds `Bash(shepherd-watch *)` and `Bash(shepherd-*)` for the instance commands.

**Rejected.** *Keep the hand-armed R5 primary and skip the monitor*: R1's whole point is a watcher the harness owns. *One shared monitor for all instances*: no session can be told to deliver into another. *`when: always`*: starts in every worker and every unrelated session on the machine.

## 7. Dev loop, versioning, distribution

**Recommendation.**

- **Dev loop.** Framework work happens in the plugin checkout (`~/Code/shepherd-plugin`, an onboarded project with `test: bash tests/run.sh` and `claude plugin validate --strict` in its DoD). A shepherd session that wants to *run* the working copy launches with `claude --plugin-dir ~/Code/shepherd-plugin …`: "when a `--plugin-dir` plugin has the same name as an installed marketplace plugin, the local copy takes precedence for that session" — that instance runs the dev copy while the other instance and every worker keep the installed version. `/reload-plugins` picks up hook, bin and skill changes mid-session; monitors need a restart. `claude plugin validate --strict` runs in the plugin's test harness.
- **Versioning.** Explicit semver in `plugin.json`, bumped on every release, `CHANGELOG.md` entry, `claude plugin tag --push` producing the tag `shepherd--v1.4.0`. Explicit version = update gate: "users get updates only when you bump this field."
- **Update.** `claude plugin update shepherd@shepherd-plugins` (the shell form loads next launch), then roll the instance over; wake step 1 reads the installed version from `claude plugin list --json`, refuses below `SHEPHERD_MIN_PLUGIN`, and reports a newer release. A running instance and every running worker keep the previous version's path until reload or restart, and the old cache directory stays for about 14 days, so an update never interrupts a worker mid-task.
- **Distribution.** The plugin repo is its own GitHub marketplace, **public** as `shepherd-template` is today (§9 Q2). Adoption is two commands: `claude plugin marketplace add sakettawde/shepherd-plugin` then `claude plugin install shepherd@shepherd-plugins --scope user`. Auto-update stays off (the default for third-party marketplaces), so updates are deliberate wake-time acts.
- **collie and kelpie** share one user-scope install, hence one cache copy and one version at a time; an update takes effect per instance at its next rollover, so the two may run different versions for the length of one rollover — acceptable because both read the manual copy that the *first* one to wake committed, and ledger schemas are append-only (T-0214 constraint).
- **huntaway** on another machine runs the same two commands, clones the instance repo it belongs to (§9 Q4), and runs `/shepherd:init` once to write `.shepherd/local.env` for that machine's code dir.

**Basis.** `--plugin-dir` precedence and `/reload-plugins` (https://code.claude.com/docs/en/plugins#test-your-plugins-locally, 2026-09-02). Version resolution order and the three strategies; explicit version pins, commit-SHA fallback when omitted (https://code.claude.com/docs/en/plugins-reference#version-management, 2026-09-02). Tag convention `{plugin-name}--v{version}` and `claude plugin tag --push` needs a clean tree and an `origin` remote (https://code.claude.com/docs/en/plugin-dependencies#tag-plugin-releases-for-version-resolution, 2026-09-02). Update semantics — old path kept until `/reload-plugins`, monitors until restart, orphan sweep "roughly 14 days later" (plugins-reference, #environment-variables and #plugin-caching-and-file-resolution). `claude plugin install` from the shell loads on the next start; auto-update runs after startup with a random delay of up to ten minutes and the running session keeps the versions it loaded; third-party marketplaces have auto-update off by default (https://code.claude.com/docs/en/discover-plugins#install-plugins and #configure-auto-updates, 2026-09-02). Private repositories: foreground commands use your git credentials; the background refresh "disables git credential helpers" for HTTPS, SSH remotes are unaffected, and `owner/repo` shorthand clones over SSH by default (https://code.claude.com/docs/en/plugin-marketplaces#private-repositories, 2026-09-02). On this machine `gh auth status` reports SSH as the git protocol and `ssh -T git@github.com` authenticates, so a private repo would also work; public is simply free of the failure mode.

**Rejected.** *Skills-directory plugin* (`~/.claude/skills/shepherd/` as a git checkout): loads in place with no install step, which is attractive for one developer, but an edit is live in every new session on the machine — including every worker's hooks — with no release gate and no version to pin. *Commit-SHA versioning*: every push is an update; same missing gate. *A `command` source in link mode*: re-resolved once per session, content-hashed, and disabled under `allowManagedHooksOnly`; more machinery than a version bump. *Private marketplace over HTTPS*: background pulls cannot authenticate.

## 8. Migration and rollback

**Preconditions.** Waves 1 and 2 merged on this instance's `main` (T-0214–T-0217, T-0220–T-0222); herdr still at the 0.8.2 pin; the build card's plugin release tagged; the migration itself runs at a close-out with **no active cards**, or with every active worker having started *after* step 4 below.

**Ordered steps.**

1. **Build the plugin from this instance's `main`, not from the template.** The template is 114 framework commits behind and its 75 unique commits are the PR merges of what was cherry-picked here; `git diff template/main main -- CLAUDE.md .claude/skills scripts hooks templates` finds anything template-only to fold in (the three parked ports were folded into wave cards on 2026-09-02). Lay out §1.1, rename per §1.2, rewrite the §1.3 inventory, write `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json`, `monitors/monitors.json`, `${CLAUDE_PLUGIN_ROOT}/manual/shepherd.md`, `${CLAUDE_PLUGIN_ROOT}/templates/instance/`. `claude plugin validate --strict` and `bash tests/run.sh` green.
2. **Drill under `--plugin-dir`.** `shepherd-drill` runs the sandbox as it does today with `SHEPHERD_ROOT` exported; then a live dry run: a shepherd session launched as a spare id (`shepherd-drill`) with `--plugin-dir`, `/shepherd:wake` end to end, one throwaway worker dispatched into a scratch project to prove the plugin hooks write status lines, `shepherd-status` resolves bare, and a monitor line arrives and wakes the session.
3. **Release v1.0.0.** Tag `shepherd--v1.0.0`, merge to the plugin repo's `main`, rename the GitHub repo (§9 Q1; the old name redirects), un-tick "Template repository".
4. **Install on this machine.** `claude plugin marketplace add sakettawde/shepherd-plugin && claude plugin install shepherd@shepherd-plugins --scope user`. From now on every *new* session has the plugin hooks **and** the user-global ones (§5 item 1); running sessions are unchanged.
5. **Instance commit A** (through `shepherd-commit`, on `main`): add `.shepherd/instance.env`, the thin `CLAUDE.md`, the first `.claude/shepherd-manual.md`, and the widened allow list. Everything else stays; the un-namespaced `wake` and `/shepherd:wake` coexist.
6. **Roll each instance over** (collie, then kelpie) so their fresh sessions run `/shepherd:wake` on the plugin. Wake step 1 confirms the plugin version and the manual copy.
7. **Remove the three user-global hook entries** from `~/.claude/settings.json` — only once no worker launched before step 4 is still running (check active cards' `session:` start against the install time; simplest: no active cards). The file watcher applies the removal to running sessions at once, which is why the ordering matters: a worker launched after step 4 loses the settings copy and keeps the plugin copy — zero downtime. Leave herdr's `SessionStart` entry. Leave the instance `hooks/` directory in place until step 8, because the entries just removed referenced it by absolute path.
8. **Instance commit B — the one revertable deletion**: `git rm -r .claude/skills hooks scripts templates FRAMEWORK.md` plus the framework specs and herdr schemas now in the plugin, README shortened to "this is a shepherd instance; install the plugin; run `/shepherd:wake`". `.claude/settings.json` keeps permissions only.
9. **Verify** (build card DoD, §10): `claude plugin details shepherd` recorded; one real dispatch end to end on the installed plugin; `${CLAUDE_PLUGIN_ROOT}/tests/run.sh` green in the plugin checkout; a rollover drill lands `/shepherd:wake`; `ListAgents` names unchanged.
10. **Record.** Registry `shepherd` card: Product and Context notes rewritten (instance-first suspension ends; the sync rule below); Gotcha about the hard-coded root retired; onboard `shepherd-plugin` as a project with `working-agreement:` its own `CLAUDE.md`. Memory: the "shepherds share one ledger" entry gains "framework lives in the plugin".

**The personalisation layer.** FRAMEWORK.md's table is retired. Its replacement is the plugin README's one list of what an instance repo contains (§1.1's last paragraph); there is no longer a second copy of any framework file to personalise, so there is nothing to keep in step.

**The sync rule that replaces "template first".** *Plugin first, always.* A framework change is a task card with `project: shepherd-plugin`, briefed like any other, tested in the plugin's harness and in a `--plugin-dir` session, released as a version, and adopted by each instance at its next wake. Instances never carry framework edits; a rule that only this instance needs goes under `## Local overrides` in its thin `CLAUDE.md` and is a candidate for the next plugin release. The instance-first mode adopted for the introspection program (registry Context note, 2026-09-02) ends at step 8.

**Rollback.** Before step 8, `claude plugin disable shepherd@shepherd-plugins` and re-run the old init-shepherd step 4 registration is a complete rollback; the instance copies were never removed. After step 8, in this order: (1) `claude plugin disable shepherd@shepherd-plugins` — first, so the doubled-hook state cannot recur; (2) `git revert <commit B>` on instance `main`, which restores skills, hooks, scripts, templates and the old tests; (3) run the restored init-shepherd step 4 to re-register the user-global hooks; (4) restore `ROLLOVER_MSG=/shepherd:wake` (it comes back with the reverted script); (5) roll each instance over with the un-namespaced `wake`. Commit A can stay — a thin `CLAUDE.md` importing the generated manual is a correct manual — or be reverted too if the operator block is wanted back in prose. Nothing in the ledger changes shape in either direction (T-0214's append-only schema constraint).

## 9. Open questions for Saket, each with the recommended answer

1. **Rename `shepherd-template` to `shepherd-plugin` and drop the template flag?** Recommended: yes. GitHub redirects the old name, the `template` remote keeps working, and "template" will describe nothing after step 8. — **ANSWERED 2026-09-10: accepted as recommended** (§9.1).
2. **Public or private plugin repo?** Recommended: public, as today. Nothing private lives there, and public avoids the background-refresh authentication failure. If private: SSH already works on this machine; add `CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE=1` to the launch environment. — **ANSWERED 2026-09-10: accepted as recommended** (§9.1).
3. **Names — plugin `shepherd`, marketplace `shepherd-plugins`, skills `/shepherd:<name>`?** Recommended: accept. A shorter prefix saves keystrokes and costs clarity everywhere else. — **ANSWERED 2026-09-10: accepted as recommended** (§9.1).
4. **Does huntaway share this instance repo (its own clone of the private `shepherd` repo) or run its own instance?** Recommended: its own instance repo per machine unless the ledger is meant to be one across machines — the multi-shepherd design assumes one working tree per ledger, and a git-synchronised ledger is a different design. — **ANSWERED 2026-09-10, twice; the second answer stands: each machine gets its own instance and its own ledger** (§9.1).
5. **Retire the prose `## 0. Operator` block in favour of `.shepherd/instance.env` imported into `CLAUDE.md`?** Recommended: yes; one source, readable by scripts and model alike. — **ANSWERED 2026-09-10: accepted as recommended** (§9.1).
6. **Auto-update off, updates at wake only?** Recommended: off. A framework update that lands in the middle of a dispatch is exactly the surprise the version gate exists to prevent. — **ANSWERED 2026-09-10: accepted as recommended** (§9.1).
7. **When?** Recommended: first card of wave 3, size L, tier heavy, run at a quiet close-out; plus one S card for the instance conversion (steps 5–8) that can wait for a day with no active cards. — **ANSWERED 2026-09-10: accepted as recommended** (§9.1).
8. **Should any project opt out of the plugin (`"shepherd@shepherd-plugins": false` in its `.claude/settings.local.json`)?** Recommended: none. The worker hooks exit at once without `SHEPHERD_TASK_ID`, as they do today. — **ANSWERED 2026-09-10: accepted as recommended** (§9.1).

### 9.1 Answers recorded

**All eight are answered as of 2026-09-10.** Q4 and Q7 came on 2026-09-08 and were confirmed on 2026-09-10; Q1, Q2, Q3, Q5, Q6 and Q8 were accepted at their recommended answers in the same exchange — his words: *"1. Rename ok 2. Public is fine (personal github) 3. Names are ok 5. ok 6. ok 8. ok"*. Nothing in §9 gates the build card any longer.

**Q4 — answered twice, and the second answer is the one that stands: each machine gets its own instance and its own ledger.**

On 2026-09-08 he said *"the same Shepherds do not run in multiple places"*, which was read as one ledger shared across machines. On 2026-09-10, asked directly whether a new machine shares this ledger or stands alone, he answered: **"Yes, new machine, new shepherd, new ledger."** That is the operative answer, and it restores §4's and §7's original recommendation rather than overriding it — a second machine runs its own instance repository, its own ledger, its own shepherd id. The 2026-09-08 reading is superseded and is kept here only so the reversal is legible.

**The blocker this dissolves.** The paragraph below was written when Q4 read as a shared ledger, and it is recorded because it is what made the question worth asking twice — not because it still applies.

**The blocker that answer inherits, verified on this machine 2026-09-08, not inferred.** `ledger/locks/` is **gitignored**, and `shepherd-lock` acquires by atomically creating a file on the local filesystem. Locks therefore never travel through git, and a git-synchronised ledger has **no mutual exclusion at all**. The failure is not two instances of one id — his sentence rules that out — it is `shepherd-collie` on machine A and `shepherd-huntaway` on machine B both acquiring `project-karta.lock`, each seeing it free, and both dispatching into what they believe is an exclusive working copy. CLAUDE.md §2 rule 3 ("one active task per working copy") is enforced by nothing once the ledger spans machines. Ordinary ledger traffic conflicts too: every card write is also a commit, so two machines race on `main` for state that has no merge semantics.

**Consequence for the build: none any more.** Under the 2026-09-10 answer no ledger spans machines, so no lock spans machines either, and `shepherd-lock`'s local-filesystem acquire is correct as it stands. **The cross-machine lock layer is not a prerequisite and is not to be built** — the two shapes once sketched for it (a lock branch with compare-and-swap pushes; a small Worker holding locks in D1, as `collie-inbox` does) are recorded only so a future shared-ledger proposal starts from the analysis rather than repeating it. Anyone reviving a shared ledger inherits this blocker unsolved.

**Q7 — when: accepted as recommended.** First card of wave 3, size L, tier heavy, run at a quiet close-out, plus one S card for the instance conversion (§8 steps 5–8) on a day with no active cards. Neither card is written yet, and nothing in §9 gates them now.

**One steer that arrived with the blessing and is not a §9 question.** Saket, 2026-09-10: *optimise for a single shepherd running on a new machine* (registry `shepherd` card, `## Product`). Multi-instance stays supported, but where the two pull apart the single shepherd wins. The build card reads §4 and §7 against a fresh single-instance install, not against this machine's three-instance setup — which, with Q4 now answered the same way, is the configuration the whole design serves.

## 10. Build card checklist

- Plugin repo laid out per §1.1; `claude plugin validate --strict` clean; `bash tests/run.sh` green in the plugin checkout, `test-docs.sh` retargeted at `manual/` and `skills/`.
- No hard-coded home directory and no un-namespaced skill invocation anywhere in plugin text; test asserts both.
- `${CLAUDE_PLUGIN_ROOT}/lib/shepherd-common.sh` resolves `SHEPHERD_ROOT` by §4's ladder and refuses without `instance.env`; tests cover env, worktree and refusal.
- `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json` in exec form; the instance `SessionStart` hook writes only in the base checkout on `main`, stays read-only in lanes, injects ≤ 100 tokens of facts; tests cover base, lane-current, lane-stale.
- `shepherd-manual sync|check`; wake step 1 commits `refreshed` through `shepherd-commit`.
- `monitors/monitors.json` with `when: on-skill-invoke:wake`; `shepherd-watch monitor` prints §6.2's line format; the owner filter is the first act of the wake handler; test with two fake instances over one directory.
- `claude plugin details shepherd` always-on token figure recorded in the card Log.
- One live dispatch on the installed plugin proves: status lines from plugin hooks only, `shepherd-status` bare from the worker, a monitor line wakes the instance, `/shepherd:wake` recovers a rollover.
- The four `unverified` items closed or carried forward with a card: plugin-hook trust gating on a fresh directory (§5), monitor env inheritance (§6, design does not depend on it), monitor line waking an idle turn (§6), the external-import dialog under auto mode (avoided by design, §2).
- Migration §8 steps 1–10 logged on the card; rollback rehearsed once (disable + revert on a scratch clone).

## 11. Sources read (all 2026-09-02)

| Short name | URL |
|---|---|
| plugins | https://code.claude.com/docs/en/plugins |
| plugins-reference | https://code.claude.com/docs/en/plugins-reference |
| hooks | https://code.claude.com/docs/en/hooks |
| memory | https://code.claude.com/docs/en/memory |
| plugin-marketplaces | https://code.claude.com/docs/en/plugin-marketplaces |
| skills | https://code.claude.com/docs/en/skills |
| discover-plugins | https://code.claude.com/docs/en/discover-plugins |
| tools-reference (Monitor tool) | https://code.claude.com/docs/en/tools-reference#monitor-tool |
| plugin-dependencies | https://code.claude.com/docs/en/plugin-dependencies |
| settings-reference | https://code.claude.com/docs/en/settings-reference#enabledplugins |
| cli-reference | https://code.claude.com/docs/en/cli-reference |

Local state read: `claude --version` (2.1.258) and `claude plugin --help`; `~/.claude/settings.json` (the three shepherd hook entries and herdr's); `~/.claude/plugins/installed_plugins.json` and `known_marketplaces.json` (scope, cache layout, `github` marketplace source shape); the superpowers 6.3.0 plugin's `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json` as a real `${CLAUDE_PLUGIN_ROOT}` example; `gh repo view` for both repos (template public and flagged template; instance private); `gh auth status` (SSH). In-repo: FRAMEWORK.md, CLAUDE.md §0–§2 and §8, every SKILL.md, adapter v0.8.2 R3/R5, `scripts/lib/shepherd-common.sh`, `shepherd-lock`, `shepherd-commit`, `shepherd-rollover`, `scripts/tests/`, docs/specs/2026-08-05-shepherd-template-design.md, the introspection report §R1/§R7, cards T-0214 and T-0222. Probe: §0.1.
