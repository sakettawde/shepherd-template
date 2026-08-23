# shepherd-template

**Shepherd** is a thin orchestrator pattern for Claude Code: one Claude session that routes your stream of thoughts to your projects, dispatches worker Claude sessions in [herdr](https://herdr.dev) panes to do the actual work, watches them via hook-written status files, verifies results against git facts and a Definition-of-Done command it runs itself, and records everything in a git-tracked ledger. Shepherd never edits project code in its own context — it routes, briefs, verifies, decides, and remembers.

Two or more shepherd sessions can share one clone. Each launches with its own `SHEPHERD_ID`, owns only the task cards it created, and coordinates through filesystem locks in `ledger/locks/` — see `docs/specs/multi-shepherd-design.md`.

This repo is the **framework**: skills, hooks, scripts, and an empty ledger/registry. Your instance's state (tasks, project cards, decisions) accumulates in your clone and never syncs back.

## Prerequisites

- **herdr 0.8.2** installed, with its server running — shepherd is herdr-native and refuses to dispatch outside it (`HERDR_ENV=1`).
- **Claude Code** with access to capable models (worker tiers default to `opus --effort high` / `opus --effort xhigh` — adjust in `CLAUDE.md` §6 if your plan differs).
- The **superpowers** Claude Code plugin installed — worker briefs mandate its skills (brainstorming, test-driven-development, writing-plans, subagent-driven-development), and the retro skill proposes framework edits via writing-skills.
- Linux/WSL with `bash`, `git` and `python3` (hooks, locks and JSON parsing use them; no jq needed). The coordination scripts rely on `link(2)` and atomic rename, so keep the clone on a local filesystem — re-verify before running it from a network or translated mount.
- A code directory containing the project repos you want shepherd to manage.

## Setup

```bash
git clone <your-copy-of-this-template> shepherd && cd shepherd
claude
```

Run the clone-and-launch above **from a pane inside herdr** — init-shepherd's environment gate (`HERDR_ENV`, version pin) refuses to run outside it. Then tell Claude: **run the init-shepherd skill**. It gates on the herdr version, interviews you (name, code directory, notification preferences, worker cap, shepherd-id scheme), writes the `## 0. Operator` block in `CLAUDE.md`, registers the three worker hooks in your user-global `~/.claude/settings.json`, and seeds `registry/projects.md` from your code directory.

Daily launch, from a pane inside herdr — the env var and the `--remote-control` name must be the same string:

```bash
cd <your shepherd clone> && SHEPHERD_ID=shepherd-1 claude --remote-control shepherd-1
```

A second concurrent instance launches identically with `shepherd-2`, and so on. Peers address each other by that name to hand off a freed queue, so a session launched without it — or with a name that differs from `SHEPHERD_ID` — cannot be reached.

**Moving to a new machine:** clone your instance repo, open Claude in it, re-run init-shepherd. It re-registers hooks with the new paths and touches nothing else.

## How it works

Every message you send is triaged into exactly one of: an answer, context ingestion, a clarifying question, or a task card. Tasks flow `captured → queued → briefed → working → blocked → review → done|failed`, each transition a git commit. Workers get a one-line kickoff pointing at their task card; two background watchers (a status-file grep and a herdr stall wait) wake shepherd on completion or blockage; a four-source verification ladder (status file → git facts → DoD run → pane tail) decides whether "done" is true. Projects must be **onboarded** (deep scan + your Q&A → registry card + project CLAUDE.md) before they accept tasks.

Concurrency is filesystem-coordinated: `scripts/shepherd-identity.sh` claims an instance id, `scripts/lock.sh` guards one active task per working copy plus the worker cap, `scripts/reserve-task-id.sh` hands out `T-NNNN` ids race-free, and `scripts/ledger-commit.sh` commits path-scoped so two instances never clobber each other's index. Every reclaim is gated on liveness — a pane that cannot be resolved is reported, never assumed dead.

Read `CLAUDE.md` — it is the operating manual the shepherd session itself runs on.

## Fresh-clone drill (self-verify after setup)

1. init-shepherd completed: `CLAUDE.md` `## 0. Operator` holds your values; `grep -c '^| ' registry/projects.md` counts your projects + 1 header row.
2. Hooks registered: `python3 -c "import json,pathlib;print(json.dumps(json.load(open(pathlib.Path.home()/'.claude/settings.json'))['hooks']['Stop'],indent=1))"` shows a command pointing into *this clone's* `hooks/`.
3. Stub worker check: `SHEPHERD_TASK_ID=T-TEST SHEPHERD_STATUS_FILE=$PWD/ledger/status/T-TEST.jsonl sh hooks/worker-stop.sh </dev/null` then confirm `ledger/status/T-TEST.jsonl` contains a `"event": "stop"` line; delete the file afterwards.
4. Coordination scripts: `bash scripts/tests/run.sh` ends `ALL TESTS PASSED`. It runs entirely in temp sandboxes and never touches your ledger.
5. Crash-window drill: `bash scripts/drill.sh` ends `DRILL: N passed, 0 failed` — it exercises reservation contention, same-id boot, parallel commits, and the orphan rule.
6. Identity: from inside a herdr pane, `SHEPHERD_ID=shepherd-1 bash scripts/shepherd-identity.sh acquire` prints `IDENTITY shepherd-1 pane=… session=…` and creates `ledger/locks/shepherd-1.lock` (gitignored). Run it again — it prints `(already mine)`, never a second claim.
7. Grep cookbook: the recipes in `CLAUDE.md` §5 find nothing on a fresh clone — expect empty results, plus `No such file or directory` from the unexpanded globs until your first task card and project card exist.

## Updating

Framework improvements land in this template first. In your instance: `git remote add template <template-url>`, then cherry-pick framework commits as they appear. `FRAMEWORK.md` lists which paths are framework (safe to pull) vs instance state (never crosses).
