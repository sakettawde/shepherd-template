# Scripts hygiene — design (T-0219, 2026-09-02)

Five bounded changes to `scripts/`, one new script that composes adapter recipes, and the
three manual edits that make them reachable. Report §R10, scripts half. This note is the
approval artifact; the implementation plan follows it.

## 1. `shepherd-smoke` — the canary

**What it proves.** The dispatch → hook → watcher path works on this machine, end to end,
before a live task depends on it. One command, run from shepherd's own pane, PASS/FAIL per
step, exit 0 only when every step passed.

**Steps, live form** (each prints `smoke: PASS|FAIL|SKIP <step>  <detail>`):

| step | does | recipe |
|---|---|---|
| `gate` | `HERDR_ENV=1`; `herdr --version` equals the pin read from `.claude/skills/herdr-adapter/SKILL.md` (`**Pinned version: X**`); `herdr status` says `compatible: yes`; `~/.claude/settings.json` registers a `Stop` hook whose command ends in `worker-stop.sh'`; `HERDR_PANE_ID` set; `claude` on PATH | R1 |
| `pane` | `pane split --current --direction right --no-focus`, parse `result.pane.pane_id`, `pane rename <pid> w-smoke` | R2 |
| `launch` | `pane run <pid> "cd <tmp>/work && SHEPHERD_TASK_ID=SMOKE-<hhmmss> SHEPHERD_STATUS_FILE=<tmp>/status.jsonl CLAUDE_CODE_SUBAGENT_MODEL=opus claude -n worker-SMOKE --model $SMOKE_MODEL --effort $SMOKE_EFFORT --permission-mode auto"`; poll `pane get` until `agent` is populated (the `agent wait` gotcha: it returns `agent_not_found` before detection); `agent wait <pid> --until idle --until blocked --timeout 45000`; if `blocked` and the visible pane mentions `trust`, `pane send-keys <pid> Enter` and wait for `idle` again (the brand-new-directory dialog, adapter Gotchas); any other `blocked` fails the step and prints the pane | R3, R6 |
| `kickoff` | `agent prompt <pid> "<one-line task>" --wait --until working --timeout 15000`. `agent_blocked` fails the step (pane printed); `agent_prompt_stalled`/`timeout` do not — the status file decides | R4 |
| `claim` | R5's count-anchored grep on the status file, `PAT='"claim": "\(done\|blocked\|failed\)"'`, anchor 0, window `SMOKE_WAIT` (default 300 s); every 10 s also `pane get`, and a `blocked` agent fails the step with the pane text instead of burning the window | R5 |
| `verify` | last record: `event=stop`, `task=<smoke id>`, `claim=done`, `session_id` non-empty and **equal to `pane get`'s `agent_session.value`**, `transcript_path` names an existing file, `permission_mode=auto`; and `<tmp>/work/smoke-ok.txt` reads `ok` — the DoD run by the canary, not believed from the claim (CLAUDE.md §2 rule 1) | R7 |
| `retire` | R9 guards — label `w-smoke`, `agent_status` idle, `focused` false — then `pane close <pid>`. A failed guard leaves the pane open and fails the step, naming the guard | R9 |

The worker's task line (single line, no double quotes): *Smoke canary. Create a file named
smoke-ok.txt in the current directory containing exactly the word ok, then stop and end your
reply with this exact line on its own: SHEPHERD: done — smoke ok*. Everything the canary
writes lives under one `mktemp -d`; it never touches `ledger/`, a project repo, or `~/.claude/`.
On PASS the temp dir is removed; on FAIL it is kept and its path printed. After a FAIL the
remaining steps print `SKIP`, except `retire`, which still runs when the pane exists and its
agent is idle (a working or blocked agent is never closed — R9).

Model/effort: `SMOKE_MODEL` default `opus`, `SMOKE_EFFORT` default `low` — every worker runs
Opus (CLAUDE.md §6), and a one-file task needs no depth.

**`--dry-run`.** `herdr` becomes a shell function inside the script; `claude` is never
launched. The function answers each recipe with the JSON shape the reference documents
(`result.pane.pane_id`, `result.pane.agent_status`, `result.pane.agent_session.value`,
`result.type: agent_prompted`) from a state directory under the temp dir, and `agent prompt`
plays the worker: it writes `smoke-ok.txt` and runs the **real** `${CLAUDE_PLUGIN_ROOT}/hooks/worker-stop.sh` with
a Stop payload whose last line is the sentinel, so the hook-written fields the `verify` step
reads are produced by the hook, not typed by the stub. `SHEPHERD_SMOKE_SCENARIO` (dry-run
only) makes the canary fail on purpose, because a canary that cannot fail proves nothing:
`pass` (default), `trust-dialog` (first post-launch status is `blocked` with the trust text,
Enter clears it), `no-claim` (the worker's turn ends without a sentinel → `claim` times out),
`no-file` (claims `done`, writes nothing → `verify` fails), `pane-focused` (`retire` guard
refuses). Without `--dry-run` and without `HERDR_ENV=1` the script prints
`NOT-INSIDE-HERDR`, exits 1, and calls nothing.

**Manual.** Adapter Regeneration step 6 names the live command and what it proves; the
dry-run form is noted as the harness's. Shepherd runs the live form once at this task's
verification (the worker never runs herdr).

## 2. The context meter: source of truth, install, self-test

**`scripts/statusline.py`** — the current `~/.claude/statusline.py`, copied verbatim (it
already cites the status-line reference). The render shape `ctx ▓░░░░░░░░░ 13%/1000k` is a
contract with `shepherd-rollover`'s `read_ctx` regex, and a test pins the round trip:
render from the documented stdin JSON, parse with `ctx`, expect `13 130`.

Contract, checked live 2026-09-02 (<https://code.claude.com/docs/en/statusline>): the
script is registered as `"statusLine": {"type": "command", "command": "<cmd>"}` in
`~/.claude/settings.json` (optional `padding`, `refreshInterval`, `hideVimModeIndicator`);
stdin carries `model.display_name`, `effort.level`, `context_window.context_window_size`
(200000, or 1000000 for extended-context models) and `context_window.used_percentage`,
which "may be `null` early in the session" and is computed from input tokens only; updates
are event-driven and debounced at 300 ms.

**`shepherd-statusline`** — idempotent, diff-aware, `$HOME`-relative so a test can
point it at a temp HOME. Copies `scripts/statusline.py` to `~/.claude/statusline.py` when
absent or different (the displaced copy is kept once as `statusline.py.prev`), sets the exec
bit, and merges `statusLine.type`/`.command` (`python3 <HOME>/.claude/statusline.py`) into
`~/.claude/settings.json`, preserving every other key including an existing `padding`.
Prints one line, `statusline: file=<installed|updated|unchanged> settings=<registered|unchanged>`.
`--check` reports without writing and exits 1 when anything would change. `init-shepherd`
gains a step that runs it, placed after the hook registration (T-0214's block is not
touched; steps after it renumber), and its Hard lines admit the one new file.

**`shepherd-rollover decide --self-test`** — a diagnostic for wake step 10. It reads the
same status line `decide` reads and reports each degraded case explicitly, exit 1 on any:

- no status line visible on the pane → `decide` answers `unknown`; fallback named;
- status line without a window size → percent-only, **the absolute 200k/350k thresholds
  cannot fire**;
- `~/.claude/statusline.py` missing or stale against the repo copy, or `statusLine` not
  registered (via `shepherd-statusline --check`).

Healthy: one line per check and `meter: ok`. Plain `decide` keeps answering the four words
on stdout for every existing caller, and adds one stderr line when the reading is
percent-only, so the degradation is visible wherever it is measured, not only at wake.

One behavioural change inside `decide`: it counts active cards in `$TASKS_DIR` from
`scripts/lib/shepherd-common.sh` (already sourced) instead of `<script-dir>/../ledger/tasks`.
Identical for an instance running from its base checkout; correct for one running from a
clone; and it is what lets the table-driven test sandbox the ledger.

**Tests.** `test-decide.sh`: a herdr stub renders the status line from `pct`/`size` files, the
sandbox ledger holds the cards; rows of `pct size active-owned → verdict`, including the
absolute-fires-first rows (`25 1000k 0 → rollover`, `25 1000k 1 → hold`, `40 1000k 1 →
rollover`), the percent-fires-first rows (`60 200k 0 → rollover`, `85 200k 1 → rollover`),
the boundaries (`59 200k 0 → ok`, `84 200k 1 → hold`), the owner filter (another
instance's active card does not hold you; an ownerless card is `shepherd-1`'s), the
percent-only rows with the stderr note, and `unknown`. `--self-test` rows for each degraded
case. `test-statusline.sh`: the render/parse round trip, the `null` percentage, install run
twice against a temp HOME (second run reports unchanged on both halves; unrelated settings
and `padding` survive).

## 3. Delete `scripts/self-recycle.sh`

`git rm` the shim. `test-rollover.sh` F13 (shim behaviour) and F14's two shim lines go;
F14 keeps "the new script carries no recycle vocabulary" and gains "the old path is gone".

References found (grep, 2026-09-02) and what happens to each:

| where | action |
|---|---|
| `scripts/tests/test-rollover.sh` F13/F14 | rewritten as above |
| `FRAMEWORK.md` file table, `scripts/**` row | drop "(+ a deprecated shim at its old path)"; add `shepherd-smoke`, `shepherd-statusline`, `statusline.py` |
| `docs/specs/context-rollover-design.md` | already says the vocabulary was renamed; untouched |
| `docs/superpowers/plans/2026-08-25-self-recycle-reliability.md` | historical plan; one line under its title: renamed to `shepherd-rollover` (T-0185), shim removed (T-0219) |
| `.claude/skills/herdr-adapter/references/v0.7.4.md` | historical recipes kept for diffs, marked never-read; untouched |
| `docs/specs/2026-09-02-plugin-packaging-design.md` | already says the shim is dropped; untouched |
| `ledger/`, `registry/`, `decisions/`, `docs/reports/` | instance state; untouched |

Outside this repo: `~/.claude/settings.json`, `~/.claude/hooks/`, the user-global skills and
rules, and the crontab carry no reference. The rollover watchdog re-executes its own path
(`$self`), never the shim. the plugin repository still carries its own copy of
the shim and its F13 tests — that repo's business, reported in the final message.

## 4. `shepherd-drill`

Measured 2026-09-02: it passes in ~2 s with no herdr (every liveness probe goes through the
`SHEPHERD_TEST_HOOKS` overrides). `scripts/tests/run.sh` runs it after the `test-*.sh` loop
and folds its exit into the suite's; its header says so. Nothing about it becomes manual.

## 5. Threshold tests

Covered by §2's `test-decide.sh`. The thresholds stay where they are (`CTX_IDLE`, `CTX_BUSY`,
`CTX_IDLE_K`, `CTX_BUSY_K`, env-overridable), and the tests run against the defaults.

## Files

New: `shepherd-smoke`, `scripts/statusline.py`, `shepherd-statusline`,
`scripts/tests/test-smoke.sh`, `scripts/tests/test-decide.sh`, `scripts/tests/test-statusline.sh`.
Modified: `shepherd-rollover` (`decide` TASKS_DIR, stderr note, `--self-test`),
`scripts/tests/run.sh`, `shepherd-drill` (header), `scripts/tests/test-rollover.sh`
(F13/F14), `.claude/skills/herdr-adapter/SKILL.md` (Regeneration step 6),
`.claude/skills/init-shepherd/SKILL.md` (new install step + Hard lines), `.claude/skills/wake/SKILL.md`
(step 10), `CLAUDE.md` §8 (the `unknown` bullet names the self-test), `FRAMEWORK.md` (file
table row), `docs/superpowers/plans/2026-08-25-self-recycle-reliability.md` (one line).
Deleted: `scripts/self-recycle.sh`.

Outside the Brief's named paths, and called out for that reason: the `FRAMEWORK.md` row and
the one-line note on the historical plan (both fall under "every reference to the old name").
