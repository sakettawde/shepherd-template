# Procedure scripts — design (T-0221, 2026-09-06)

Four scripts replace the procedures shepherd types by hand: dispatch's preconditions and
undo ladder, card field edits, the working-agreement probe, and wake steps 5–9. Report §R3,
wave 2. The rules stay where they are — CLAUDE.md and the skills — and each skill calls the
command instead of restating the procedure. This note is the approval artifact; the
implementation plan follows it.

**Conventions every script follows** (the ones `shepherd-lock`, `shepherd-watch` and `shepherd-reserve`
already follow): sourced from `scripts/lib/shepherd-common.sh`, so `SHEPHERD_ROOT` is the base
instance even when the script runs from a `shepherd~N` worktree; the first stdout line is the
verdict and its first word is the verdict kind; exit `0` success, `1` a refusal or hold, `2` a
usage or filesystem error, `3` "a human decides" (the code both sweeps use for that); every test
runs in `harness.sh`'s sandbox with `SHEPHERD_TEST_HOOKS=1`, and every herdr round-trip goes
through `pair_live`/`pane_probe` so the hooks stand in for it. Nothing here changes a lock's
semantics (T-0217 owns them): the scripts call `shepherd-lock acquire|release|live` and read its exit
codes.

**Card parsing lives in one place.** `scripts/lib/shepherd-common.sh` gains four read-only
helpers, because three of the four scripts read the same header fields and two of them apply
the same defaults:

- `card_field <file> <field>` — the header value. A field that starts its line owns the text up
  to the first run of three or more spaces or the end of the line, which is how the template
  packs `pane: … session: …`, `size: … tier: … budget: …` and trailing `# comments`; a
  field that sits after such a run (`session:`, `tier:`, `budget:`) owns the next whitespace-free
  token. Prints nothing and exits 1 when the field is absent. Works on registry cards too.
- `card_owner <file>` — `owner:`, or `shepherd-1` when the line is absent (CLAUDE.md §2 rule 10).
- `card_family <project>` — `karta~2` → `karta`; the registry slug and the lock family.
- `card_log_time` — `HH:MM` from `now_iso`, so `SHEPHERD_NOW_OVERRIDE` pins it under test.

## 1. `shepherd-card` — one card, one commit

```
shepherd-card get        T-NNNN <field>                                   # value on stdout; owner defaults to shepherd-1
shepherd-card set        T-NNNN <field> <value> [<field> <value>…] [--log "<event>: <detail>"] [--no-commit]
shepherd-card log        T-NNNN "<event>: <detail>" [--orphan] [--no-commit]
shepherd-card transition T-NNNN <state> [--log "<detail>"] [--also <path>]… [--no-commit]
```

**The owner rule is the gate.** Every write re-reads `owner:` from disk and refuses (exit 1,
`REFUSED T-NNNN is owned by <owner>, not <me>`) unless it is `$SHEPHERD_ID`. `SHEPHERD_ID`
unset or malformed is exit 2 before any file is read — the same fail-closed stance `shepherd-lock`
takes on an empty holder. The one exception CLAUDE.md §4a names — the orphan Log line from the
sweep report — is `log --orphan`, accepted only for `log` and only when the text starts with
`orphan`. Nothing else writes a card it does not own.

**Edits.** `set` replaces the value in place, using `card_field`'s boundaries, so `set session X`
leaves `pane:` alone and `set pane X` leaves `session:` alone. A field absent from the header is
inserted: `owner` directly under `state:` (CLAUDE.md §5), anything else at the end of the header.
`log` appends `- HH:MM <text>` as the last line of `## Log` — before `## Handoff` when the card
has one, at the end otherwise, and it creates the `## Log` heading when a card lacks it.
`transition` sets `state:` and appends `- HH:MM <from> → <to>` (with ` (<detail>)` when `--log`
is given). It accepts the nine states of CLAUDE.md §5 and nothing else, and refuses a
transition to the state the card is already in — an empty transition would be a commit with no
diff, which `shepherd-commit` reports as success and metrics can never time.

The file is rewritten by temp-file-and-rename in `ledger/tasks/`, never truncated in place, for
the reason `shepherd-lock takeover` gives: a reader mid-rewrite must see the old card or the new one.

**Commits.** One card per commit, through `shepherd-commit` and nothing else:

| verb | message |
|---|---|
| `transition` | `T-NNNN: <from> → <to>` — the shape every Log line, retro step 6 and `git log` already use |
| `set` | `T-NNNN: <field> <value>[, <field> <value>]` |
| `log` | `T-NNNN: <message>` — the whole message when it fits 72 characters, else the text up to the first `. ` or `; `, never cut at a `:` (T-0253 Q3, Saket 2026-09-08) |

`--also <path>` adds a path to the transition's commit: retro's close-out carries
`ledger/status/T-NNNN*.jsonl` because no other step commits it (retro step 6). The registry
card is **not** an `--also` candidate: it is committed inside `card-<slug>` by its own
`shepherd-commit` call, as today. `--no-commit` exists for scripted sequences that make several
edits and commit once (the preflight below); a shepherd typing by hand never needs it.

Metrics read transitions from the `+state:` lines in each commit's diff, not from messages
(`scripts/lib/metrics.py` `load_transitions`), so a `set` or `log` commit between two
transitions costs nothing there; what the message shape buys is a `git log --oneline` a human
can read.

## 2. `shepherd-working-agreement <path> <dev-branch>`

The working-agreement check of `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Working agreement (in CLAUDE.md §5 when
this was written; T-0222 moved it), verbatim, as a command: `fetch origin --quiet` (its failure
is not a verdict — a repo with no origin still answers from the refs it has, exactly as the
manual's block does), then `rev-parse --verify --quiet origin/<dev-branch>` (the ref guard,
first), then `cat-file -e origin/<dev-branch>:CLAUDE.md` with stderr discarded. Prints
`<dev-branch>` and exits 0 when the file is readable there; prints nothing and exits 1 when it
is not; exits 2 when `<path>` is not a git working tree or an argument is missing. The manual
keeps the block (now in `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Working agreement) — it is the specification and
test-docs pins its three load-bearing parts — and gains one sentence naming the script.
Dispatch precondition 4 and onboard steps 1 and 7 call it; the registry field is still set by
the caller, because the field and the probe deliberately disagree on the self-repo
(`working-agreement: none` with a readable `origin/main:CLAUDE.md` — see §3, working agreement).

## 3. `shepherd-preflight` — preconditions 2–6, the claim, the undo

```
shepherd-preflight T-NNNN [--lane-ok "<what you read>"]   →  DISPATCH <lane> | HOLD <reason> | JUDGE …
shepherd-preflight undo T-NNNN                            →  UNDONE T-NNNN … | REFUSED …
```

Exit `0` DISPATCH, `1` HOLD, `3` JUDGE, `2` ERROR (bad id, no card, no `worker-cap`, missing
`SHEPHERD_ID`/`HERDR_PANE_ID`/`CLAUDE_CODE_SESSION_ID` — the three lock fields, read from the
same variables `shepherd-watch` and the skills use). Detail lines follow the verdict as `key: value`,
and `NOTE` lines follow those. The checks run in the skill's order and the first failure holds,
naming its precondition, so the one line shepherd reports names the thing Saket can fix:

| # | check | HOLD reads |
|---|---|---|
| 2 | `state: queued` | `HOLD state <s>` |
| 2 | `card_owner` is `$SHEPHERD_ID` | `HOLD owner <o>` |
| 2 | every `T-XXXX` on the `Depends on:` line reads `state: done`; a line whose first word is `none` or `nothing` has none | `HOLD depends-on T-XXXX <state|missing>` |
| 2 | family FIFO: no older `queued` card of mine in the family whose own blockers are satisfied | `HOLD queue T-XXXX older` |
| 3 | registry card exists and `onboarded: yes` (the parent card governs a clone) | `HOLD onboarded <v>` / `HOLD no registry card <slug>` |
| 4 | working agreement (below) | `HOLD working-agreement …` |
| 5 | lane (below) | `HOLD gate 1 …` / `HOLD gate 2 …` / `HOLD lock error …` |
| 6 | slot (below) | `HOLD worker-cap N/N` / `HOLD dispatch lock held by <holder> — waiting` / `HOLD commit failed …` |

**Family FIFO, the one rule the skill leaves open.** Precondition 2 dispatches "the given
`T-NNNN`, else the oldest queued card" and never says what an explicit id does to the line.
The chosen rule: an older queued sibling of mine **whose blockers are all done** holds this
card, because that sibling could be dispatched right now and FIFO says it goes first; an older
sibling that is itself blocked on `Depends on:` does not, because holding behind a card that
cannot move is starvation, not order. Confidence high — it is what shepherd does by hand
(`T-0232 queued behind T-0231`).

**Working agreement.** The probe runs against the registry `path:` and `dev-branch:` — every
lane shares the base checkout's refs (`git rev-parse --git-common-dir`), so one answer serves
all of them. Two outcomes act:

- Probe prints **nothing** (the worker cannot read the file) and the Brief's `### Context`
  inlines **fewer than four** numbered rules → `HOLD working-agreement: CLAUDE.md unreadable on
  origin/<dev-branch> and the Brief inlines no standing rules — fill them from the template`.
  The count is test-docs's own measure of the template block (`^[0-9]+\. ` lines), and the
  self-repo's differently worded notice passes it because its five rules are numbered the same
  way. This is the dangerous direction (T-0084) and the only one that blocks.
- Probe prints the branch and the registry field **disagrees** → `NOTE working-agreement: probe
  reads <dev-branch>, registry says <x> — correct the field unless the disagreement is
  deliberate (precondition 4)`, and the check passes. The skill says "correct the field", the
  registry card for `shepherd` says its `none` is deliberate, and the script cannot tell an
  onboarding PR that merged from a decision; a hold here would stop every self-repo dispatch.
  The field edit stays with shepherd because it takes `card-<slug>` and the matching Brief
  edit is editorial. Reported in the final report as a skill/registry inconsistency.
  The NOTE itself is suppressed for the one case that isn't a disagreement to fix: the
  registry field reads `none` and the Brief's `### Context` already inlines four or more
  numbered rules (the same count `inlined_rules` gives precondition 4) — a deliberate `none`
  with the rules already inlined leaves nothing to correct, and a NOTE on every self-repo
  dispatch would teach shepherd to skip NOTE lines (the code's comment on
  `check_working_agreement`).

**Lane.** `shepherd-lock acquire project-<preferred> …` with the card's `project:`. Exit 0 → the lane.
Exit 2 → `HOLD lock error: <message>` — the actual message, never "held" (the skill's warning).
Exit 1 (`HELD`) is the only entry to lane selection, and the three gates run in order:

1. This card and every active card in the family (all owners) carry `parallel-safety:
   independent` — the value's first word, case-folded; absent or anything else reads as
   `serialized`. Fail → `HOLD gate 1 T-XXXX serialized` (or `this card serialized`).
2. `touch-areas:` disjoint against each active sibling — comma-split, trimmed, case-folded;
   absent or empty touches everything. Fail → `HOLD gate 2 overlaps T-XXXX on "<token>"`.
3. The judgment. Without `--lane-ok`: `JUDGE lane <preferred> held by <holder>; gates 1–2 pass
   against T-XXXX[, …]`, then the registry card's `## Gotchas` and `## Context notes` sections
   verbatim, then `next: re-run with --lane-ok "<what you read>" to open a lane, or leave the
   card queued`; exit 3, nothing written, nothing held. With `--lane-ok "<text>"`: the walk.

The walk: the other `~N` rows of `## Clones` in id order, then a new lane at the lowest `~N`
(N ≥ 2) the table lacks; `acquire` each, first success wins; exit 2 anywhere is `HOLD lock
error`. A card whose `project:` is already a clone never tries the base checkout — the base is
not in the walk at all, which is how the self-repo invariant holds without a field. The new
lane's lock is taken before anything materialises it, so whoever wins the name owns the right
to build it. A `--lane-ok` given when the preferred lane turns out free is simply unused.

**Slot.** `shepherd-lock acquire dispatch …`; `HELD` → sleep `SHEPHERD_PREFLIGHT_RETRY` seconds
(default 5) and retry, three attempts in all; still held → release the project lock, `HOLD
dispatch lock held by <holder> — waiting`; exit 2 → release the project lock, `HOLD dispatch
lock error: <message>`. Held → count the distinct `pane:` values across `briefed|working|
blocked|review` cards, all owners, `none` excluded, `claiming-*` counted like any pane; read
`worker-cap` from `$SHEPHERD_ROOT/CLAUDE.md`'s Operator block (absent → exit 2: a cap nobody
wrote down is not a cap of infinity). At or over → release both locks, Log
`dispatch held: worker-cap N reached (M active)`, `HOLD worker-cap M/N`. Under → one card
write: `state: briefed`, `pane: claiming-<id>-T-NNNN`, `project: <lane>` when the walk landed
elsewhere, the Log lines `queued → briefed (slot M+1/N claimed as claiming-…; lane <lane>)` and,
on relocation, `lane <lane>: <lane-ok text> (relocated from <orig>)`. Release `dispatch`. Then
commit `T-NNNN: queued → briefed` through `shepherd-commit`; a failed commit runs the undo
below and holds with the message. The lock is held across count → decide → write and nothing
more, as the skill requires; the commit falls outside it.

Committing the claim here, rather than at dispatch step 6, is the change that makes the
`queued → briefed` transition timeable: today it rides a commit made after the pane spawned,
the launch settled and the watchers armed. Step 6 becomes the commit of step 4's edits
(`shepherd-card set pane <id> session <sid> --log "briefed pane …"`).

**The DISPATCH detail lines** are step 0's inputs, already parsed: `lane:`, `path:` (the Clones
row's path, the registry `path:` for the base, `none` for a lane with no row), `row: existing|
missing|base`, `parent:`, `dev-branch:`, `clone-seed:`, `install:` (defaults applied),
`relocated: from <orig>|none`, `claim:`, `slots: M+1/N`, `commit: <ledger-commit's line>`.

**Undo** is the skill's ladder, in its order, as one command. Refuses unless the card is
`state: briefed` and mine (`REFUSED T-NNNN is <state>, not briefed`) — the state the claim
wrote, whether the pane is still the placeholder or step 4 already wrote a real id. Then:
`state: queued`, `pane: none`, `project:` restored from the last `(relocated from <orig>)` Log
line not followed by a `briefed → queued` line; the Log line `briefed → queued (dispatch
undone)`; release `dispatch` if I hold it (`FREE` and another holder's `REFUSED` are both
fine); release `project-<lane the card named before the restore>`; commit `T-NNNN: briefed →
queued`; print `UNDONE T-NNNN lane <lane> project <restored to …|unchanged>` with one line per
step. Wake step 7's `claiming-` repair is this same command.

## 4. `shepherd-wake-report` — steps 5–9 as one read

Enumeration only; it repairs nothing and takes no lock. One line per finding, the first word
the kind, so a skill can act per kind. `$SHEPHERD_ID` is "me"; a card with no `owner:` is
`shepherd-1`'s.

| kind | reads | who acts |
|---|---|---|
| `ACTIVE-MINE T state project pane=… session=…` / `ACTIVE-OTHER … owner=…` | step 5 | step 10 reports both |
| `LOCK-OK project-<lane> T` | step 6 | — |
| `LOCK-STALE project-<lane> held by me over T (<state>) — release` | step 6 repair A | wake releases |
| `LOCK-ORPHAN project-<lane> held by <other> (gone) over T (mine) — takeover` | step 6 repair B | wake runs `takeover` |
| `LOCK-HELD-LIVE …` / `LOCK-UNRESOLVED …` / `LOCK-MISSING T (mine, <state>) — report` / `LOCK-MISMATCH project-<lane> names T-YYYY, card T-XXXX — report` | step 6 | wake reports, repairs nothing |
| `PANE-LIVE T <pane> session=match` | step 7 | — |
| `PANE-LIVE T <pane> session=missing agent_session=<sid> — backfill` | step 7 | `shepherd-card set T session <sid>` |
| `PANE-GONE T <pane> — mark blocked and investigate` / `PANE-UNRESOLVED …` | step 7 | wake |
| `CLAIMING T claiming-<me>-T — dispatch died mid-claim: shepherd-preflight undo T` | step 7 | wake runs undo |
| `WATCH-OK T` / `WATCH-MISSING T <kinds> — shepherd-watch rearm T` | step 8, via `shepherd-watch check` | wake re-arms |
| `INBOX yours|none|unreachable` | step 8, via `shepherd-inbox owner` (exit 0/3/1) | wake arms or says why not |
| `QUEUE-MINE T project created=…` (oldest first; as `shepherd-1`, ownerless cards included) | step 9 | dispatch |
| `INSTANCE <id> live|gone|unresolved pane=… tasks=…` (identity locks minus `*.reclaim`, via `shepherd-lock live`) | step 10 | the status line |
| `STATUS ctx <pct>% (<decide>), active: …; others: <id> T…; inbox: …; orphans: …` | step 10 | the one line to the operator |

Liveness goes through `pair_live` per card (pane and session from the card) and `shepherd-lock live`
per instance, so the sandbox hooks drive every branch under test. `ctx` is the operator-facing
PERCENT (CLAUDE.md §8 promises a percent, not a bare verdict word): `shepherd-rollover ctx`
(no pane argument; it reads `HERDR_PANE_ID`) for the reading, `shepherd-rollover decide` for
the verdict word in parentheses beside it — `ctx 42% (ok)`. With `HERDR_PANE_ID` unset, or no
status line visible, it answers `unknown` without a herdr call, which is what the test uses.
Exit `0` when every line is `-OK`, `ACTIVE-*`,
`PANE-LIVE … match`, `QUEUE-*`, `INSTANCE`, `INBOX` or `STATUS`; `3` when any line needs an act
or a report — the same meaning the two sweeps give `3`.

## 5. The skills call the scripts

Every rule survives where test-docs already pins it; what goes is the procedure.

- **dispatch.** Preconditions stay numbered 1–6 (test-docs counts them and checks every
  back-reference). Item 1 is unchanged. Items 2–6 each keep their rule in a few sentences —
  `project family`, `Depends on: T-XXXX`, `reads as \`serialized\``, `never falls back to the
  base checkout`, `silence means safe`, `write it into the card`, `A lane costs one slot`, the
  `claiming-<shepherd-id>-T-NNNN` placeholder — and lose the grep, the count, the walk and the
  lock choreography to `shepherd-preflight T-NNNN`, whose verdict table sits under
  item 2. `JUDGE` is answered by reading the excerpt and re-running with `--lane-ok`, with the
  decision-log rule for a lane opened despite a named hazard kept as is. Step 4 uses `shepherd-card
  set … --log`, step 6 says what the preflight already committed, and the undo paragraph becomes
  `shepherd-preflight undo T-NNNN` with its `original \`project:\`` sentence kept.
- **wake.** Steps 5–9 keep their headings (ten steps, 1..10) and their judgment; each opens with
  the `shepherd-wake-report` line kind it acts on. Step 7's `claiming-` case names `shepherd-preflight
  undo`; step 6 keeps `shepherd-lock takeover` for `LOCK-ORPHAN` and `shepherd-lock release` for
  `LOCK-STALE`. The greps go.
- **triage.** §4 step 5: the filled card is written `state: captured` and
  `shepherd-card transition T-NNNN queued` makes the `captured → queued` commit and Log line. §5:
  `shepherd-card log` for an amendment, `shepherd-card transition T-NNNN abandoned --log "<reason>"` for a
  cancel.
- **monitor.** Every `state:` change in the verdict table and the invariants list is
  `shepherd-card transition`; the `session:` backfill is `shepherd-card set`.
- **retro.** Step 1's metrics line is `shepherd-card log`; step 6's card half is `shepherd-card transition
  T-NNNN done|failed|abandoned --also ledger/status/T-NNNN*.jsonl` with the registry card
  committed under its own lock as now; step 7's peer liveness is `shepherd-lock live <owner-id>`
  (T-0217 built it; retro still describes the by-hand read of `shepherd-lock check`).
- **onboard** (steps 1 and 7, one phrase each): "run `shepherd-working-agreement <path>
  <dev-branch>`" in place of the by-hand instruction to run the working-agreement check (then
  in CLAUDE.md §5, now `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Working agreement). Outside the card's `touch-areas:` list
  but inside its Objective ("the three skills that run the check call it"); flagged in the
  report.
- **CLAUDE.md §5.** The cookbook gains one block naming the four scripts and `shepherd-lock live`;
  the working-agreement block (moved to `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Working agreement by T-0222)
  gains the sentence naming its script. Nothing else in the manual
  moves (T-0222 owns the restructure).

**test-docs pins** that no skill restates a procedure a script owns: dispatch and wake name
their scripts; `cat-file -e` appears in the manual's working-agreement block (CLAUDE.md §5 then,
`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Working agreement now) and `shepherd-working-agreement` only; the
active-cards grep and the owner-filtered queue grep are gone from the wake skill; the
count-and-claim comment block is gone from dispatch; each script's usage line in its header
matches the invocation the skills quote.

## 6. Tests

`scripts/tests/test-card.sh`, `test-working-agreement.sh`, `test-preflight.sh`,
`test-wake-report.sh`, plus the test-docs additions. Each builds its ledger in the sandbox —
a git repo initialised `-b main` so `shepherd-commit` accepts it, a `CLAUDE.md` carrying
`- worker-cap: N`, registry cards with a `## Clones` table, task cards written from the
template's header shape — and a fixture git repo (bare origin + clone) for the probe. Every
HOLD in §3's table has a case that names it; DISPATCH covers the preferred lane, a walk to an
existing row and a walk to a new lane (with the Log line and the rewritten `project:`); JUDGE
checks the excerpt and that nothing was written or held; undo checks state, pane, project, both
locks and the commit message; the dispatch-lock contention case pre-seeds `dispatch.lock` under
a live holder and reads the project lock back as free. `shepherd-card` cases: each verb, the owner
refusal, the ownerless card as `shepherd-1`'s, mid-line fields, `--also`, `--orphan`, unknown
state, same-state, and one commit per transition carrying the exact message. `wake-report`
cases drive every line kind through the liveness hooks and pin the exit code.

## Files

New: `shepherd-card`, `shepherd-working-agreement`, `shepherd-preflight`,
`shepherd-wake-report`, four test files. Edited: `scripts/lib/shepherd-common.sh` (four
helpers), the five skills plus onboard's two phrases, CLAUDE.md §5, `scripts/tests/test-docs.sh`.
