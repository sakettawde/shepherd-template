---
description: Session start — after a rollover, restart or crash — and whenever you are unsure what you own: ten ordered steps rebuild the instance and end with one line to the operator.
---

# wake

A fresh session knows nothing and owns everything it owned before; **the manual §8 holds the rules**, this file the procedure. No `owner:` line means `shepherd-1` (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Owner filter).

## Steps

### 1. Version gate

```bash
herdr --version && herdr status
shepherd-output-style
claude plugin list --json
shepherd-manual check
```

Five checks, in that order.

**herdr** — the pin in the manual §7 and `compatible: yes` → continue; else **stop dispatching**, tell the operator, regenerate (R1).

**Output style** — needs no herdr: `style: ok`, or `style: DEGRADED` naming the file every worker starts with and its repair, reported in step 10 and holding nothing (`${CLAUDE_PLUGIN_ROOT}/docs/incidents/2026-09-06-launch-drift.md`).

**Plugin version** — read the installed `shepherd` version from the JSON. Below `SHEPHERD_MIN_PLUGIN` in `.shepherd/instance.env` → **stop dispatching** and tell the operator to run `claude plugin update shepherd@shepherd-plugins`; a newer release available → say so in step 10 and carry on, because an update takes effect at the next rollover, never mid-task.

**Manual** — `shepherd-manual check` prints one word:

| Word | Do |
|---|---|
| `current` | nothing |
| `refreshed` | the `SessionStart` hook rewrote the generated copy this session, so commit it: `shepherd-commit "framework: manual synced to shepherd v<X.Y.Z>" .claude/shepherd-manual.md`. Two instances waking after one update write identical bytes — the first commit wins, the second finds a clean file and commits nothing, and no card lock is needed because the content is a function of the installed version |
| `stale` | the hook could not write. Run `shepherd-manual sync`, then commit as above; if it refuses, report it |
| `lane-stale` | you are in a worktree lane, which is read-only for this file. Report it and do nothing |
| `missing` | run `/shepherd:init` — this is not a seeded instance |
| `not-instance` or `no-manual` | you are not in a seeded instance, or the installed plugin ships no manual. Report it and stop dispatching: the install is wrong |

**Monitor** — the status line names a running monitor count. **Expect none today, and arm the primary by hand:** `shepherd-watch arm T-NNNN` in the background per active card you own, which step 7 does anyway. The plugin's `status-claims` monitor declares `when: "on-skill-invoke:wake"`, and that trigger does not start it — measured 2026-09-10 on Claude Code 2.1.267; the CHANGELOG's known limitations hold the detail and why the declaration stays. Say in step 10 which of the two you are on.

### 2. Identity

```bash
shepherd-identity acquire
```

**Hard stops — report, stop, relaunch under another id:** `is already live in pane …`, `is unresolved`, `MALFORMED`. **Race-window outcomes — pause a few seconds, `acquire` once more:** `already reclaiming`, `changed hands while its holder was probed`, `lost the race`, `re-acquired by another instance`; a second refusal → report and stop.

### 3. Lock sweep

```bash
shepherd-lock sweep
```

Report every line kind: `ORPHAN` — a gone instance's lock over an active task: yours → step 6 reclaims it; another's → report it, `shepherd-card log T-NNNN "orphan: <what the sweep said>" --orphan`, wait for reassignment (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Ownership and handoff). `LONG-HELD` — a live holder past ten minutes; leave it. `UNKNOWN-LIVENESS` — nothing reclaimed. `SWEEP-SKIPPED` — nothing inspected. `CHANGED` — re-acquired mid-probe, untouched. `MALFORMED` — left in place, blocking acquisition until inspected. `RM-FAILED` — `rm` refused; name the file, clear it by hand. `UNKNOWN-LOCK` — a kind `sweep` was never taught; name the file. `SWEPT` — routine, say how many (`SWEPT shepherd-<name>.reclaim` is a dead takeover).

**Exit code** `3` = a `MALFORMED`, `SWEEP-SKIPPED`, `UNKNOWN-LOCK`, `UNKNOWN-LIVENESS` or `RM-FAILED` line, each reported with what was left in place; `0` = routine, and step 4's sweep exits the same way over its own kinds. `shepherd-lock sweep --dry-run` previews.

### 4. Reservation sweep

```bash
shepherd-reserve sweep
```

Clears gone claimants' reservations; `SWEEP-SKIPPED`, `UNKNOWN-LIVENESS`, `CHANGED`, `MALFORMED`, `RM-FAILED` and the exit code are reported exactly as in step 3, and `--dry-run` works too.

### 5. Active cards, owner-filtered

```bash
shepherd-wake-report
```

One read for steps 5 to 9: one line per finding, first word its kind, last the `STATUS` line step 10 reports; exit `3` when a line needs an act or a report. Here: `ACTIVE-MINE` (steps 6 to 8 act on these), `ACTIVE-OTHER … owner=<id>`.

### 6. Reconcile self

Locks and cards must match both ways — for build cards only: a `kind: reply` card takes no project lock (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Reply workers), so `shepherd-wake-report` raises no `LOCK-MISSING` for one; a lock that names one is still the anomaly below. Repair only these two:

- `LOCK-STALE project-<clone-id> held by me over T-NNNN (<state>) — release` → `shepherd-lock release "project-<clone-id>" "$SHEPHERD_ID"`; no sweep covers it, so nothing but you frees it.
- `LOCK-ORPHAN project-<clone-id> held by <other> (gone) over T-NNNN (mine) — takeover` → `shepherd-lock takeover "project-<clone-id>" "$SHEPHERD_ID" "$HERDR_PANE_ID" "<session>" T-NNNN` (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Ownership and handoff); it refuses a live or unresolvable holder, so the refusal is the answer.

`LOCK-OK` → nothing. `LOCK-HELD-LIVE`, `LOCK-UNRESOLVED`, `LOCK-MISSING`, `LOCK-MISMATCH` → **report, repair nothing**: a live or unresolved holder is never stolen from; the rest is the operator's call.

### 7. Pane check

- `PANE-GONE T-NNNN <pane>` → `shepherd-card transition T-NNNN blocked --log "pane gone at wake"`, then investigate.
- `PANE-LIVE … session=missing agent_session=<sid> — backfill` → `shepherd-card set T-NNNN session <sid>`; `session=match` → nothing.
- `PANE-UNRESOLVED` → say so in step 10, check again next wake.
- `PANE-NONE T-NNNN` → an active card with no pane; report it.
- `CLAIMING T-NNNN claiming-<your-id>-T-NNNN — dispatch died mid-claim` → `shepherd-preflight undo T-NNNN`, then step 9 redispatches; the placeholder counts against `worker-cap` until then.

`ListAgents` lists a worker as `worker-T-NNNN` (adapter R3): a hint, never evidence (the manual §2 rule 1).

### 8. Re-arm watchers

`WATCH-OK T-NNNN` → nothing. `WATCH-MISSING T-NNNN <kinds> — shepherd-watch rearm T-NNNN` → `shepherd-watch rearm T-NNNN` as a background Bash task (adapter R5), for cards **you own** only; it arms what this session lacks (exit 4 `ARMED-ALREADY` when nothing), and `shepherd-watch list` shows the records.

**Plus one inbox watcher per instance.** The `INBOX` line is `shepherd-inbox owner`'s answer: `none` (exit 3) → arm nothing, say so in step 10; `yours` (exit 0) or `unreachable` (exit 1) → arm in the background, through `shepherd-watch` so `list` and `check` see it and a rolled-over session's watcher is replaced like any other:

```bash
shepherd-watch arm inbox --window 21600
```

Six hours: each `INBOX TIMEOUT` costs a model turn, the loop none, and the loop re-checks ownership every tick — which is why arming on exit 1 is safe (docs/incidents/2026-09-02-inbox-watcher-outages.md). Its verdict is the first stdout line: `INBOX WORK` → monitor's drain; `INBOX TIMEOUT` → re-arm; `INBOX UNREACHABLE` → re-arm and one line naming the Worker unreachable; `INBOX NOT-CONFIGURED` or `INBOX AUTH` → report, no re-arm; `ERROR shepherd-inbox exited <rc>` → report, and `shepherd-watch list inbox` says whether anything is left watching. `operators=empty` on the `INBOX` line means the Worker's operator list is unset, so every author reads as a member — say so once in step 10 (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice).

### 9. Your queue

`QUEUE-MINE T-NNNN <project> created=…` lines, oldest first — `queued` cards whose `owner:` is you (ownerless too, as `shepherd-1`); `queued` alone is never "dispatchable by you" (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Owner filter). Hand them to **dispatch**, under `worker-cap`.

### 10. Context check, rollover log, reachability, status

```bash
shepherd-rollover decide --self-test
tail -5 "${SHEPHERD_ROLLOVER_LOG:-$HOME/.claude/shepherd-rollover.log}"
```

Step 5's report already ran `decide` once: its `STATUS ctx <N>% (<word>)` carries the answer, `ok | hold | rollover | unknown` — read the word there rather than running `decide` again, and where the meter could not read the pane the line reads `STATUS ctx unknown` with no word, which is the `unknown` verdict. Act on `rollover` **before anything else** (the manual §8, adapter R10). It exits `0` once **armed**, not recovered, and the log tail says whether the last one landed — `GIVE-UP` or `REFUSED` last is a failed rollover, reported and logged to `decisions/` (the watchdog cannot), `VERIFIED` a success. `--self-test` reports the meter's health: anything but `meter: ok` goes in your line, `bash shepherd-statusline` repairs it.

Reachability: `ListAgents` must open with your `SHEPHERD_ID`; an auto name means no handoff can reach you — ask the operator for `/rename <your SHEPHERD_ID>`, and report it, every wake (docs/incidents/2026-08-28-unreachable-auto-names.md).

Then the one line to the operator: the report's `STATUS` line (context %, tasks, the `INSTANCE` lines, the inbox watcher's state, orphans), with step 8's arming and steps 3–4's sweep kinds appended.

## Done when

- Steps 1 to 10 each ran, or a hard stop at step 1 or 2 was reported; the style verdict (when not `style: ok`) and every sweep line kind reached the operator.

- Every active card you own holds its lock and has a watcher armed; `ListAgents` shows your `SHEPHERD_ID` or the operator was asked to `/rename` it; the operator has the one-line status.
