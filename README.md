# shepherd-template

**Shepherd** is a thin orchestrator pattern for Claude Code: one Claude session that routes your stream of thoughts to your projects, dispatches worker Claude sessions in [herdr](https://herdr.dev) panes to do the actual work, watches them via hook-written status files, verifies results against git facts and a Definition-of-Done command it runs itself, and records everything in a git-tracked ledger. Shepherd never edits project code in its own context — it routes, briefs, verifies, decides, and remembers.

This repo is the **framework**: skills, hooks, and an empty ledger/registry. Your instance's state (tasks, project cards, decisions) accumulates in your clone and never syncs back.

## Prerequisites

- **herdr 0.7.4** installed, with its server running — shepherd is herdr-native and refuses to dispatch outside it (`HERDR_ENV=1`).
- **Claude Code** with access to capable models (worker tiers default to `fable --effort high` / `fable --effort max` — adjust in `CLAUDE.md` §6 if your plan differs).
- Linux/WSL with `python3` (hooks and JSON parsing use it; no jq needed).
- A code directory containing the project repos you want shepherd to manage.

## Setup

```bash
git clone <your-copy-of-this-template> shepherd && cd shepherd
claude
```

Then tell Claude: **run the init-shepherd skill**. It gates on the herdr version, interviews you (name, code directory, notification preferences), writes the `## Operator` block in `CLAUDE.md`, registers the two worker hooks in your user-global `~/.claude/settings.json`, and seeds `registry/projects.md` from your code directory.

Daily launch, from a pane inside herdr:

```bash
cd <your shepherd clone> && claude --remote-control shepherd
```

**Moving to a new machine:** clone your instance repo, open Claude in it, re-run init-shepherd. It re-registers hooks with the new paths and touches nothing else.

## How it works

Every message you send is triaged into exactly one of: an answer, context ingestion, a clarifying question, or a task card. Tasks flow `captured → queued → briefed → working → blocked → review → done|failed`, each transition a git commit. Workers get a one-line kickoff pointing at their task card; two background watchers (a status-file grep and a herdr stall wait) wake shepherd on completion or blockage; a four-source verification ladder (status file → git facts → DoD run → pane tail) decides whether "done" is true. Projects must be **onboarded** (deep scan + your Q&A → registry card + project CLAUDE.md) before they accept tasks.

Read `CLAUDE.md` — it is the operating manual the shepherd session itself runs on.

## Fresh-clone drill (self-verify after setup)

1. init-shepherd completed: `CLAUDE.md` `## 0. Operator` holds your values; `grep -c '^| ' registry/projects.md` counts your projects + 1 header row.
2. Hooks registered: `python3 -c "import json,pathlib;print(json.dumps(json.load(open(pathlib.Path.home()/'.claude/settings.json'))['hooks']['Stop'],indent=1))"` shows a command pointing into *this clone's* `hooks/`.
3. Stub worker check: `SHEPHERD_TASK_ID=T-TEST SHEPHERD_STATUS_FILE=$PWD/ledger/status/T-TEST.jsonl sh hooks/worker-stop.sh </dev/null` then confirm `ledger/status/T-TEST.jsonl` contains a `"event": "stop"` line; delete the file afterwards.
4. Grep cookbook: the four recipes in `CLAUDE.md` §5 run clean (empty results, no errors) against the empty ledger.

## Updating

Framework improvements land in this template first. In your instance: `git remote add template <template-url>`, then cherry-pick framework commits as they appear. `FRAMEWORK.md` lists which paths are framework (safe to pull) vs instance state (never crosses).
