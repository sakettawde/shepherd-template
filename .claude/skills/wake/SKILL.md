---
name: wake
description: Session start and recovery for a shepherd instance. Use as the first act of every fresh session — after a context rollover clears the pane, after a restart, after a crash — and whenever you are unsure what you still own. Runs CLAUDE.md §8's ten ordered steps: version gate, identity, both sweeps, active cards, self-reconcile, pane check, watcher re-arm, queue check, and a closing step that covers context, reachability and the one-line status to the operator.
---

# wake

A fresh session knows nothing and owns everything it owned before. These ten steps
rebuild that from the repo, in order, and end with one line to the operator.

**CLAUDE.md §8 holds the rules; this file holds the procedure.** Where a step needs a
judgment the manual already settled, it says which section settled it. Read the manual
when a step's outcome is not on its list — never in place of running the step.

**Order is load-bearing.** Each step reads state an earlier step changes. Run them 1
to 10 and skip none: a skipped sweep leaves a lock nobody will free, a skipped re-arm
leaves a worker nobody is watching, and neither announces itself.

You are the `SHEPHERD_ID` you launched with. Steps 5 to 9 act on **your** cards only
(CLAUDE.md §2 rule 10, §4a). A card with no `owner:` line is `shepherd-1`'s.

## Steps

### 1. Version gate

```bash
herdr --version && herdr status
```

Matches the pin in CLAUDE.md §7 and `compatible: yes` → continue. Anything else →
**stop dispatching**, tell the operator, and follow the herdr-adapter regeneration
procedure. Recipes are adapter R1.

### 2. Identity

```bash
scripts/shepherd-identity.sh acquire
```

Takes the identity lock and writes the registration. Sort its refusal by kind:

- **Hard stops — report and stop.** `is already live in pane …` (another session runs
  as this id), `is unresolved` (its holder's liveness is unknown, and guessing puts two
  sessions on one id), `MALFORMED` (the lock could not be parsed and was left in
  place). Tell the operator; relaunch with a different `SHEPHERD_ID`. Never retry into
  these.
- **Race-window outcomes — pause a few seconds and run `acquire` once more.**
  `already reclaiming`, `changed hands while its holder was probed`, `lost the race`,
  `re-acquired by another instance`. Another instance was mid-takeover of the same gone
  id while you probed. Freezing on the first momentary contention is the failure this
  step exists to prevent. A second refusal of any kind → report and stop.

### 3. Lock sweep

```bash
scripts/lock.sh sweep
```

Seven line kinds. Report every one to the operator:

- `ORPHAN` — a gone instance's lock over a still-active task; its worker may still run.
  **Yours → do nothing here; step 6 reclaims it.** Another instance's → report it,
  append one `## Log` line to that task card noting the orphan (the only sanctioned
  write to a card you do not own), and wait for reassignment (§4a).
- `LONG-HELD` — a live instance has held a seconds-scale lock over ten minutes. Report
  it; leave it alone.
- `UNKNOWN-LIVENESS` — the holder is unresolved, so nothing was reclaimed.
- `SWEEP-SKIPPED` — the liveness oracle could not answer; no locks were inspected. The
  sweep did nothing, and its safety value depends entirely on the operator hearing so.
- `CHANGED` — a lock was re-acquired during the probe and left alone. Report it if it
  recurs.
- `MALFORMED` — a lock or reservation could not be parsed and was left in place. It
  blocks acquisition until someone inspects it by hand.
- `UNKNOWN-LOCK` — a lock whose name matches no known kind, holder gone. Nothing was
  deleted. Report it **and name the file**: nobody creates these, so one means a
  hand-made file or a lock kind added without teaching `sweep` about it.

`SWEPT` is the routine outcome — say how many, not each one. Expect
`SWEPT shepherd-<name>.reclaim` sometimes: an earlier identity takeover died mid-flight,
and clearing it is what the sweep is for.

### 4. Reservation sweep

```bash
scripts/reserve-task-id.sh sweep
```

Clears reservations whose claimant is gone. `SWEEP-SKIPPED`, `UNKNOWN-LIVENESS`,
`CHANGED` and `MALFORMED` are reported exactly as in step 3.

### 5. Active cards, owner-filtered

```bash
grep -lE "^state: (briefed|working|blocked|review)" ledger/tasks/T-*.md
```

Read `owner:` from each and split into two lists: the cards you own, and the cards
other instances own. Steps 6, 7 and 8 act on the first list. Step 10 reports both.
A card with no `owner:` line is `shepherd-1`'s.

### 6. Reconcile self

Every project lock naming you must match a card you own, and every active card you own
must hold its project lock. Repair the one unambiguous direction — you own the card and
no live instance holds the lock:

```bash
scripts/lock.sh takeover "project-<clone-id>" "$SHEPHERD_ID" "$HERDR_PANE_ID" "<session>" T-NNNN
```

This is the common case after a crash: you restart under the same id, the project lock
still names your gone pane, and step 3 reported it `ORPHAN`. `takeover` refuses when the
holder turns out live or unresolvable, so running it is always safe — take the refusal
as the answer and report it. **Report every other kind of mismatch instead of repairing
it.**

### 7. Pane check

`herdr pane list` (adapter R2), then per active card you own:

- Card active, pane gone → mark the card `blocked` and investigate.
- Pane alive, card `session:` missing → backfill it from `herdr pane get`
  (`agent_session`).
- Card reads `pane: claiming-<your-id>` → this is a dispatch that died between claiming
  its slot and spawning the worker, not a lost pane. Put the card back to
  `state: queued` / `pane: none`, release the project lock if you hold it, commit, and
  let step 9 dispatch it again. The placeholder counts against `worker-cap` until you do.

### 8. Re-arm watchers

One background completion wait per active task **you own** (adapter R5). Never for
another instance's task. Anchor the re-arm on the count of terminal claims already in
the status file — adapter R5's primary recipe is that anchor, and a naive re-arm fires
instantly on the claim you already handled.

### 9. Your queue

```bash
grep -l "^state: queued" ledger/tasks/T-*.md | xargs -r grep -l "^owner: $SHEPHERD_ID"
```

As `shepherd-1`, add the cards carrying no `owner:` line at all
(`xargs -r grep -L "^owner: "`). Dispatch selection is owner-filtered (§4a), so
`state: queued` alone is not "dispatchable by you". Hand the result to the **dispatch**
skill, subject to `worker-cap`.

### 10. Context check, rollover log, reachability, status

```bash
scripts/context-rollover.sh decide
tail -5 "${SHEPHERD_ROLLOVER_LOG:-$HOME/.claude/shepherd-rollover.log}"
```

`decide` answers `ok | hold | rollover | unknown`. Act on `rollover` **before anything
else** — CLAUDE.md §8 holds the thresholds and the rules, and adapter R10 holds the
sequence. The command exits `0` as soon as it has **armed** — that is not the same as
recovered. The log tail below is what tells you whether the last one landed.

Then the log tail. A `GIVE-UP` or `REFUSED` as the last verdict means the previous
rollover failed: report it to the operator and log it to
`decisions/YYYY-MM-<your-shepherd-id>.md`, because the watchdog can toast but cannot
write ledger state. A `VERIFIED` tail is how a session that followed a **successful**
rollover confirms itself.

Then confirm peers can reach you. `ListAgents` opens with this session's own name — the
name other sessions address it by — and it must read your `SHEPHERD_ID`. A
`<clone-directory>-<two characters>` name instead means this session launched without
`-n` (CLAUDE.md §1), so every handoff aimed at your id lands nowhere (§4a): ask the
operator to type `/rename <your SHEPHERD_ID>` in this pane, and report it. The check
belongs at every wake rather than only after a restart, because accepting a plan also
replaces the name in those listings ([Manage sessions](https://code.claude.com/docs/en/sessions)
§ "Name your sessions", read 2026-08-28).

Then one line to the operator, in this order: your context %, your active tasks, the
other live instances with their active tasks, and any orphans. The live set comes from
the identity locks — `ls ledger/locks/shepherd-*.lock`, skipping `*.reclaim.lock`, each
resolved through its pane/session (adapter R7). A lock whose holder is gone was already
swept at step 3, so what remains and answers is the live set
(`docs/specs/multi-shepherd-design.md` §9 step 7).

## Done when

- Steps 1 to 10 have each run, or a hard stop at step 1 or 2 was reported to the operator.
- Every sweep line kind that appeared has reached the operator.
- Every active card you own holds its project lock and has one watcher armed.
- `ListAgents` shows this session under your `SHEPHERD_ID`, or the operator has been asked to `/rename` it.
- The operator has the one-line status.
