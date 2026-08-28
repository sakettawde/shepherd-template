# Multi-shepherd — design

Revision: v2 (v1 rewritten after an adversarial review — see §14)
Status: adopted
Supersedes: the "one shepherd at a time" invariant

## 1. Goal

Let two or more shepherd Claude sessions run concurrently in the same
`<shepherd-root>` clone, sharing one ledger, one registry and one git working
tree, without corrupting each other's state.

The invariant this replaces allowed exactly one shepherd to hold the ledger. Running two in
parallel without coordination produced duplicate watchers on one task, back-to-back
"watchers re-armed" commits, and two nudge prompts into one worker pane. The old rule was
"detect a rival and stop".

### Non-goals

- Distributed operation. All instances share one filesystem and one machine.
- Automatic load balancing or task stealing. Reassignment happens only on the operator's word.
- Consensus algorithms. The filesystem is the coordinator.
- Many instances. The design targets 2–3.

### The governing principle

**Every claim records its claimant in the same atomic operation that creates it, and every
reclaim is gated on liveness — never on age, and never on a read that happened in an earlier
step.**

This matters because the participants are LLM sessions. They stall for minutes mid-sequence,
get compacted and forget what they hold, and die between any two tool calls. A procedure that
is correct for fast processes is not correct here. v1 of this spec stated this principle and
then violated it in three places.

## 2. Model

Ownership is claimed at task creation. The instance that creates a task card owns that task
until it closes: it briefs, watches, unblocks, verifies, retires the pane, and runs retro.
Every other instance may read the card and must not write it.

Everything below exists to make that claim race-free and crash-safe.

## 3. Identity and liveness

### 3.1 Launch

```bash
cd <shepherd-root> && SHEPHERD_ID=shepherd-1 claude -n shepherd-1 --remote-control shepherd-1
```

- `SHEPHERD_ID` is the source of truth. Nothing is auto-numbered or inferred.
- Unset `SHEPHERD_ID` means `shepherd-1`, so existing single-instance use is unchanged.
- The id must match `^shepherd-[a-z0-9]+(-[a-z0-9]+)*$` — the `shepherd-` prefix,
  then lowercase letters and digits in hyphen-joined words. `shepherd-1` and
  `shepherd-blue` are equally valid. The prefix is required because §6.4's sweep
  recognises an identity lock by its `shepherd-*` glob; an id without it would be
  reported `UNKNOWN-LOCK` and never cleaned up. The character class is what rejects
  whitespace, shell metacharacters and path traversal — an id containing `/` once
  wrote its lock outside `ledger/locks/`, where the sweep could never find it.
- `-n` and `--remote-control` both take the id. `-n` sets the display name, which is the
  address §5.3 sends a handoff to; `--remote-control` titles the session in the Claude
  apps and sets nothing locally ([Manage sessions](https://code.claude.com/docs/en/sessions),
  [CLI reference](https://code.claude.com/docs/en/cli-reference), read 2026-08-28).

### 3.2 The identity lock

Identity is taken with the same atomic primitive as everything else, not with a
check-then-write on a data file:

```
ledger/locks/shepherd-<id>.lock
```

At session start the instance attempts an atomic exclusive create (§6). Outcomes:

- **Create succeeds** → this instance is `<id>`. Continue.
- **Create fails and the holder is live** (§3.3) → **refuse to start.** Report the collision to
  the operator and stop. Two instances sharing an id would each believe they own the other's tasks.
- **Create fails and the holder is gone** → the lock is stale. Delete it, then retry the create
  once. If the retry also fails, another instance won the race for the same id; refuse to start.

This closes the window v1 left open, where two sessions launched with the same default id could
both read "absent or gone" before either wrote.

### 3.3 Liveness

Liveness is **not** derived from a pid. All shepherds run inside herdr (CLAUDE.md §2 rule 8)
and share one working directory, so a pid's cwd cannot distinguish one shepherd from another,
and a pid captured from a Bash tool call is a transient shell that dies immediately.

Every lock and every reservation records two fields: `pane` (from `HERDR_PANE_ID`) and
`session` (the `agent_session` from `herdr pane get "$HERDR_PANE_ID"`, adapter R7).

Liveness is **three-valued**, not boolean. `herdr pane get <pane>` distinguishes two very
different failures that a plain true/false cannot, and it does so through the combination of
which stream carries the document and what the document says — never through exit status alone.
Verified directly against the herdr binary at the pinned version; re-verify on a pin change:

- a live pane's document lands on **stdout with exit 0**;
- a pane that genuinely no longer exists reports the error code `pane_not_found` — but that
  document lands on **stderr, with exit status 1**;
- `herdr` being unreachable, its JSON shape changing, or `python3` being missing produces no
  recognizable document on either stream — some *other* failure, not evidence the pane is gone.

Exit status alone cannot separate the second case from the third: both can exit non-zero, or
in principle either could exit 0 in a future herdr release. `pane_not_found` — the code inside
whichever stream actually carries a document — is what makes "gone" distinguishable
from "unresolved". Nothing else in the response reliably does: an unreachable server or a
malformed document look, from the caller's side, like they could still be hiding a live pane.
A prior draft of this section stated the opposite — that the failure document arrives on stdout
with exit 0 — which had never been checked against the real binary.

`pane_probe <pane>` (`scripts/lib/shepherd-common.sh`) surfaces this as three outcomes. It reads
stdout first and falls back to stderr only when stdout is empty, so a well-formed success
document stays authoritative even if herdr also writes to stderr, and then classifies whichever
document it found — never the exit status:

| Return | Meaning | Condition |
|---|---|---|
| 0 | live | `agent_session` present; prints the session id |
| 1 | gone | error code is exactly `pane_not_found`, or the pane object carries no usable `agent_session` |
| 2 | unresolved | no document on either stream, output was not JSON, any other error code, or no usable pane object at all |

`shepherd_live <pane> <session>` composes this with the recorded session id and returns the same
three values: **0** when the pane exists and runs exactly that session, **1** when the pane is
gone or runs a different session (or none), **2** when liveness is unresolved. A pane that
exists but runs a *different* session is gone — that shepherd is gone and someone
else's session occupies the pane — so it is a 1, not a 2.

**A reclaim (deleting a lock, deleting a reservation) happens only on a gone (1)
result. A 2 is never treated as evidence that the holder is gone; it is reported and the reclaim skipped.**
Both sweeps (§6.4) implement this: they act on `shepherd_live`'s return value, not on its
truthiness, so "0 = success" callers written as `if shepherd_live …; then` still work unchanged,
but a caller that must act on a negative branches on the exact code.

Timestamps are informational only. A shepherd may idle for days and is still the rightful
owner of its tasks. **Nothing is ever reclaimed on a timestamp alone.**

### 3.4 Registration file

`ledger/shepherds/<id>.json` is written after the identity lock is held. It duplicates the
lock's facts in readable form and adds `started` and `last_seen`:

```json
{
  "id": "shepherd-1",
  "pane": "w6:p1",
  "session": "153a03…",
  "remote_control": "shepherd-1",
  "started": "2026-01-14T09:02:00+00:00",
  "last_seen": "2026-01-14T10:31:00+00:00"
}
```

It is a convenience for reporting, never an authority. The identity lock is the authority.
**No instance ever deletes another instance's registration file** — v1's registration sweep is
removed. Liveness is computed on read, so a stale file is harmless.

`ledger/shepherds/` and `ledger/locks/` are gitignored. Both are machine-local runtime state.

## 4. Race-free task ids

The id stays `T-NNNN`. Ownership lives in a card field, never in the filename, because
reassignment must stay possible: an owner-encoded id would either lie after a handover or force
a rename that breaks every reference in git history, decisions and memory.

### 4.1 `scripts/reserve-task-id.sh <shepherd-id> <pane> <session>`

```
loop up to 50 times:
  max  <- highest NNNN among ledger/tasks/T-[0-9][0-9][0-9][0-9].md
  next <- max + 1, zero-padded to 4
  if atomically-create T-<next>.md holding "reserved-by: <id> <pane> <session> <now>" succeeds:
      print T-<next>; exit 0
exit 1
```

Two properties matter, and both come from publishing the file's name only after its
content is already in it:

- The claim is atomic: the content is written to a temp file and then hardlinked
  into place. `link(2)` fails with `EEXIST` if the target exists, so exactly one
  racer wins any given number, and the file never exists empty. A plain
  `O_EXCL` redirect opens first and writes second, leaving a brief window where
  another instance could read a claimant-less file.
- The reserved file is **never empty**. It carries its claimant from the instant it exists, so
  no other instance ever has to guess whether a reservation is live.

Triage then fills the card from `templates/task-card.md`, replacing the reservation line.

Verified empirically: 100 processes racing one filename yield exactly one winner, five rounds
out of five; 60 concurrent reservation loops yield 60 distinct ids.

### 4.2 Abandoned reservations

A crash between reserve and fill leaves a card holding only its reservation line.

Cleanup is **gated on holder liveness, never on age**, and liveness is three-valued (§3.3), not
a live/gone pair:

- Reservation line names a **live** claimant → leave it alone, however old. An LLM session can
  legitimately sit 30 minutes between two tool calls.
- Reservation line names a **gone** claimant → delete the file and report it.
- Claimant liveness is **unresolved** → leave the file alone and report `UNKNOWN-LIVENESS`
  (§6.4's table, which also documents the sweep output tokens shared by both sweeps). Deleting
  here on nothing more than a failed probe is exactly the defect this section exists to prevent —
  it is never treated as evidence the claimant is gone.

v1 deleted these on a 10-minute timer. That was the worst defect in the spec: a stalled
instance would return, find its reservation deleted and re-issued to another task, and clobber
that card — two tasks sharing one id, one card destroyed, branch names and status files
ambiguous. Tri-state liveness closes a narrower version of the same failure: collapsing
"unresolved" into "gone" lets one unreachable pane free a live claimant's reservation exactly as the
age-based timer once did.

If the deleted id was the highest, the next reservation wins it back. Otherwise it leaves a gap,
which is harmless — nothing ever referenced it.

## 5. Ownership

New field in `templates/task-card.md`, directly under `state:`:

```
owner: shepherd-1
```

### 5.1 Rules

1. The instance that reserved the id sets `owner:` to itself.
2. Only the owner may write the card.
3. Only the owner briefs, arms watchers, monitors, unblocks, verifies, retires the pane, and
   runs retro for that task.
4. Any instance may read any card, at any time, without a lock.
5. Every wake handler **re-reads `owner:` from disk before it acts**. An instance that is no
   longer the owner stands down silently. This makes reassignment safe against a previous owner
   that wakes up late.
6. Cards created before this change have no `owner:` field. Treat a missing `owner:` as
   `shepherd-1`.
7. **Exception, narrowly scoped:** the orphan reporter (§6.4) appends one Log line to a card it
   does not own. It changes no field and no state. This is the only sanctioned write by a
   non-owner.

### 5.2 Dispatch selection is owner-filtered

This is the correction to the largest hole in v1. Today, retro step 7 and dispatch
precondition 2 both pick "the oldest `state: queued` card for the project", owner-blind. Left
unchanged, that produces one of two failures the moment two instances share a project queue:

- the instance respects ownership and cannot dispatch, so the card starves with no wake source; or
- it dispatches anyway, writes another instance's card, and arms watchers that the
  ownership check then makes refuse to act — the worker runs to completion with nobody
  processing it, or both instances act. That is the §1 incident, reintroduced by the
  fix meant to prevent it.

**Rule: a shepherd dispatches only cards it owns.** Both skill texts get an explicit
`owner: <me>` filter in their selection step.

### 5.3 Handoff on lock release

Owner-filtered dispatch needs a wake source, or queues starve. At retro step 6, after releasing
`project-<clone-id>.lock`:

1. Find the oldest `state: queued` card for that working copy.
2. If it is mine → dispatch as usual.
3. If it belongs to another **live** instance → notify that instance by its shepherd id
   (`SendMessage` to `shepherd-2`, once `ListAgents` shows that id live), and append a Log line
   recording the handoff.
4. If it belongs to a **gone** instance → report it to the operator in one line as awaiting
   reassignment (§10). Do not take it unilaterally.

Peer sessions are addressable by the display name they launched with — their shepherd id, per
§3.1's `-n`. An instance running under an auto name answers to no id and is unreachable until it
is renamed.

### 5.4 If the notification fails

Message delivery is not a guarantee to build correctness on. It is an optimisation that turns a
starved queue into a prompt dispatch. The backstop: **every instance checks for its own
dispatchable queued cards at every wake and at session start.** So the worst case of a lost
message is a delay, not a lost task.

## 6. Locks

One primitive, `ledger/locks/`, gitignored. Every lock is created with an atomic exclusive
create **whose content is written before the file becomes visible (write-temp-then-hardlink; see §4.1)** — acquire-then-write is two steps, and a death
in between leaves a holderless lock that a sweeper misreads:

```
<holder-id> <pane> <session> <task-id-or-none> <ISO8601 acquired>
```

`scripts/lock.sh acquire|takeover|release|check|sweep <name> [holder] [pane] [session] [task]`

- **acquire** — atomic create with content. Success means the lock is yours. `holder`, `pane` and
  `session` must each be one non-empty, whitespace-free token, or it refuses with exit 2 naming
  the offending argument: a blank field (an unset `SHEPHERD_ID` is the obvious source) writes a
  line every later reader parses one field to the left, which no `release` can match and which
  sweep resolves to a task that does not exist.
- **takeover** — the sanctioned way to claim a lock whose holder is gone (§10 step 3, §9 step 6).
  No lock present → behaves as `acquire`. Holder **live** → refuse. Liveness **unresolvable** →
  refuse, with a distinct message; never take over on "unresolved". Holder **gone**
  → re-read the line, refuse if it changed since the probe (§6.4's `CHANGED` guard), otherwise
  write the new line to a temp file in the same directory and `mv` it over the target. Atomic
  rename only, never an in-place rewrite.
- **release** — read the file, verify the holder is you, then delete. Never delete another
  instance's lock outside `sweep`.
- **sweep** — see §6.4.

### 6.1 Lock kinds

| Name | Lifetime | Guards |
|---|---|---|
| `shepherd-<id>.lock` | whole session | identity (§3.2) |
| `shepherd-<id>.reclaim.lock` | seconds, during a takeover | serialises two instances reclaiming one gone id (§3.2) |
| `project-<clone-id>.lock` | dispatch → close-out (hours) | one active task per working copy |
| `dispatch.lock` | seconds | the worker cap (§6.3) |
| `card-<slug>.lock` | seconds | read-modify-write of `registry/projects/<slug>.md` |
| `card-_index.lock` | seconds | read-modify-write of `registry/projects.md` |
| `card-_memory.lock` | seconds | read-modify-write of the shepherd `MEMORY.md` index |

The short-lived card locks are deliberately separate from the long-lived project lock.
Appending a context note must not wait hours for a worker to finish.

The reclaim lock is the only one an instance holds on behalf of *another* id. It is named
`<id>.reclaim`, so it matches sweep's `shepherd-*` arm and one orphaned by a crash mid-takeover
is cleared like any other identity lock. It is also taken with `takeover`, not `acquire`, for the
same reason in reverse: session start reaches identity (§9 step 2) *before* the sweep (§9 step 4),
so an instance that finds its own id wedged behind a stale reclaim lock must be able to resolve
that lock's holder itself rather than wait for a sweep it will never reach.

### 6.2 Card-lock protocol

Acquire → **re-read the file from disk** → edit → **commit (§8.1)** → release.

Both middle steps are mandatory:

- The re-read defeats a stale in-context copy of the file.
- The commit must happen **inside** the lock. `git commit` snapshots working-tree content, so
  committing after release can capture another instance's half-written edit to the same file
  under your message. Proven, not theorised.

### 6.3 The worker cap

`worker-cap` is a number in the CLAUDE.md Operator block, default **6**, and it is a total
across all instances rather than a per-instance figure.

The cap is enforced by counting: active workers = distinct `pane:` values across all cards in
`briefed|working|blocked|review`, **regardless of owner**, ignoring `none`. The count is already
a shared view.

**The slot must be claimed in the same field it is counted in.** Writing only `state: briefed`
under the lock does not claim a slot: the card reads `pane: none` until the pane is actually
spawned, so every pending claim collapses into the single value `none` and N simultaneous claims
count as one worker. That window is minutes wide, not seconds — dispatch step 0's clone creation
(`fetch`, `worktree add`, `install`) and step 2's 45-second idle wait both sit inside it. So
under `dispatch.lock` the claiming instance writes **`pane: claiming-<shepherd-id>`** alongside
`state: briefed`, and the count treats any `claiming-*` value as one occupied slot exactly like a
real pane id. Step 4 overwrites the placeholder with the real pane; an abort before that reverts
both fields.

The only race is two instances counting simultaneously and both dispatching. `dispatch.lock`
closes it: held for seconds across "count → decide → write `state: briefed` + `pane:
claiming-<shepherd-id>`", then released. A loser of `dispatch.lock` never spins (§6.5): it
retries once or twice, then releases the project lock it already holds, leaves the card
`queued`, and reports what it is waiting on.

v1 specified six per-slot lock files with lowest-free-slot scanning and their own release
discipline. That added three failure modes — crash between acquire and launch, a live instance
forgetting to release, and an undefined sweep case — to prevent an overshoot bounded at two
workers. One short-lived lock is strictly better and makes the cap exact.

### 6.4 Stale locks and the orphan rule

A lock is **stale** when its holder is not live (§3.3).

Sweeping is not unconditional. A shepherd can die while its worker keeps running. Freeing the
lock would let another instance dispatch a second worker into the same checkout, with two Claude
sessions editing one working tree.

| Stale lock | Task it names | Action |
|---|---|---|
| `card-*.lock`, `dispatch.lock` | any | delete — these guard writes, not workers |
| `shepherd-<id>.lock` | — | delete (§3.2) |
| `project-*.lock` | none, or `done`/`failed`/`abandoned` | delete |
| `project-*.lock` | `captured` or `queued` | delete — dispatch died before any worker existed |
| `project-*.lock` | `briefed`/`working`/`blocked`/`review` | **keep.** Mark the task orphaned |
| any other name | — | **keep**, report `UNKNOWN-LOCK`. Nobody creates these |

`UNKNOWN-LOCK` is the seventh line kind and the one outcome that never resolves itself: the name
matches no kind in §6.1, so sweep cannot know what freeing it would release. It is reported at
every session start and left in place until someone looks — either a hand-made file, or a new
lock kind added without teaching sweep about it.

Marking a task orphaned means: append one Log line to the card (the §5.1 rule 7 exception),
report it to the operator at session start, and leave the running worker untouched. It waits
for reassignment (§10).

Sweep re-verifies before it deletes. The liveness probe is a herdr round-trip, long
enough for another instance to sweep the same lock (or reservation, §4.2) and re-acquire the
name. Both sweeps therefore capture the line when they read it and re-compare it immediately
before unlinking; a changed line means the lock or reservation now belongs to someone live —
or to a fresh acquisition — and it is left alone, reported `CHANGED`. A microsecond-scale window
remains between that re-check and the unlink, which is accepted — the shell has no atomic
compare-and-delete.

Sweep also refuses to run at all when its own liveness oracle cannot answer for its own pane:
if `HERDR_PANE_ID` is unset, or `pane_probe "$HERDR_PANE_ID"` does not return 0, it reports
`SWEEP-SKIPPED` and inspects nothing. Sweep is the only mass-deleting command in the system,
running unattended at every session start, so this pre-flight catches a total herdr outage
before it reads one failure as every instance being gone.

That pre-flight catches an outage affecting the sweeping instance itself; it does nothing for a
per-holder failure — `herdr` answering for most panes but failing for one. So every lock, once
past the pre-flight, is gated individually on `shepherd_live`'s three-valued result (§3.3):

- **0 (live)** — existing behaviour: kept, and reported `LONG-HELD` if a `card-*`/`dispatch.lock`
  has been held past `LONG_HOLD_SECONDS`.
- **2 (unresolved)** — printed as `UNKNOWN-LIVENESS <lock> <holder> - cannot reach herdr for
  pane <pane>, left in place` and skipped. Nothing is deleted or re-verified; a liveness answer
  that cannot be trusted is never grounds for a reclaim.
- **1 (gone)** — the stale path above: the `CHANGED` re-verify, then the table's
  delete/keep rule.
- **anything else** — treated exactly like 2, never like 1. Both sweeps match `1` explicitly for
  the delete arm and route every other value, not only 2, to `UNKNOWN-LIVENESS`; a future
  `shepherd_live` contract violation must fail toward "left in place", not toward a default
  `rm -f`.

No reclaim in either sweep can be reached with `shepherd_live` returning anything but 1.

### 6.5 Live-but-wedged holders

Sweep only clears locks whose holder is gone. A live instance can still hold a "seconds" lock
for a long time — stalled on a permission prompt, blocked on the operator overnight, or
compacted into forgetting it holds anything. There is no clean automatic answer, so the spec
states the limits instead of pretending otherwise:

- A `card-*.lock` or `dispatch.lock` held by a **live** instance for more than 10 minutes is
  reported to the operator. It is never stolen. The operator decides.
- A waiter never spins. It reports "waiting on `<holder>`" and moves on to other work.

## 7. Project clones (git worktrees)

A clone is a second working copy of an already-onboarded repo. It is not a new project and it is
never onboarded again.

### 7.1 Identity and registry

- Clone id is `<slug>~<N>`, e.g. `myproject~2`. The base working copy has no suffix.
- A task card's `project:` field carries the clone id: `project: myproject~2`.
- Routing strips the `~N` suffix to find the registry card. There is exactly one registry card
  per project, ever.
- The registry card gains a `## Clones` section:

  | clone-id | path | active-task | pane |
  |---|---|---|---|
  | myproject~2 | <code-dir>/myproject-wt2 | T-NNNN | w6:p4 |

  No existing card carries this section, and no template seeds it: dispatch step 0 creates it,
  under `card-<slug>`, the first time a `~N` task needs a working copy. From then on it is a
  permanent fixture of that card like the four below — listed in CLAUDE.md §5 so a later
  normalising pass cannot drop it.

- Product, Context notes, Gotchas and History stay shared and unsuffixed. That is the point: the
  same project, the same knowledge.
- `onboarded:` is inherited. A clone of a non-onboarded repo is refused like any other task.

### 7.2 Creation

```bash
git -C <parent-path> fetch origin
git -C <parent-path> worktree add --detach <parent-path>-wt<N> origin/<dev-branch>
```

`--detach` is required. A worktree cannot check out a branch another worktree already has, and
the base copy normally sits on the dev branch. The worker then creates its own
`task/T-NNNN-<slug>` branch from the detached head.

Verified: `worktree add` with the dev branch already checked out is refused; checking out that
branch inside the new worktree is refused; creating a same-named branch there is refused; even
`git branch -f` on a branch checked out elsewhere is refused. The shared `.git` is a real safety
net against two workers on one branch.

**Lock scope:** `card-<slug>.lock` is held **only** for the Clones-row append — acquire,
re-read, append, commit, release. The fetch, the `worktree add`, the seed copy and the install
all run **outside** the lock. They take minutes; a "seconds" lock must never wrap them.

### 7.3 Seeding

A fresh worktree has no `node_modules` and none of the gitignored env files, so the DoD command
fails. Two new optional registry-card fields:

```
clone-seed: .dev.vars .env .env.local     # default if absent
install: npm install                       # default if absent
```

Creation copies each `clone-seed` path that exists in the parent copy, then runs `install` in
the worktree. A failure here is reported before dispatch, never discovered by the worker.

### 7.4 Removal

`git worktree remove` runs only on the operator's word. A worktree may hold uncommitted work, and
nothing about a finished task proves the checkout is disposable. Retro clears the Clones row's
`active-task` and `pane`, and leaves the worktree.

## 8. Shared-file discipline

### 8.1 Git

`scripts/ledger-commit.sh "<message>" <path>...` runs:

```bash
git add -- <paths>
git commit --only -m "<message>" -- <paths>
```

Three corrections to v1, all proven by running them:

- **Flag order.** v1 wrote `git commit --only -- <paths> -m "<msg>"`. Everything after `--` is a
  pathspec, so git reports `error: pathspec '-m' did not match any file(s)` and commits nothing.
  Flags must precede `--`.
- **`git add` is required.** `--only` cannot commit an untracked path. A freshly reserved task
  card has never been tracked, so without the `add` the most common commit in the whole system
  (`T-NNNN: captured → queued`) fails outright.
- **Isolation is path-scoped, not absolute.** `--only` correctly excludes another instance's
  staged and unstaged changes to **other** paths. It does **not** protect a shared path: it
  snapshots working-tree content and will happily commit another instance's half-written edit to
  the same file. v1 claimed such files "can never ride along". False. §6.2's commit-inside-the-lock
  rule is what actually protects shared files.

Also:

- `git add -A` and `git commit -a` are forbidden in shepherd sessions. A give-up (below) can
  leave paths staged in the shared index, and `-a` would sweep them into an unrelated commit.
- Retry on `index.lock`: 30 attempts, 1 s apart with jitter. The observed failure text is
  `fatal: Unable to create '<repo>/.git/index.lock': File exists.` v1's 10 × 500 ms budget was
  measured failing 10 of 20 fully-parallel commits. At 2–3 instances committing a few times an
  hour, contention is rare and brief; the larger budget covers it without exotic plumbing.
- On give-up, report loudly and name the still-staged paths. Do not attempt an unstage — that
  takes the same lock.
- State commits never push. Pushing stays a manual act by the operator, or the framework
  backport to the `template` remote.

### 8.2 Decision log

Decisions live in `decisions/YYYY-MM-<shepherd-id>.md`. Retro and audits grep
`decisions/YYYY-MM*.md`, which also matches any legacy unsuffixed `decisions/YYYY-MM.md` file
from before this design; those stay where they are.

### 8.3 Task cards and status files

No lock. Only the owner writes a card, and each task's status JSONL is written by its own
worker's hooks.

### 8.4 Shepherd auto-memory

Individual memory files hold one fact each and need no lock — two instances writing different
facts cannot collide. `MEMORY.md` is a genuine shared read-modify-write file and gets
`card-_memory.lock`: acquire → re-read from disk → edit → release. v1 prescribed "re-read before
appending" with no lock, which narrows the window but cannot close it.

This is the one exception to §6.2's commit-inside-the-lock step, and the lock is what carries the
whole guarantee here. The shepherd `MEMORY.md` lives under `~/.claude/projects/…/memory/`,
**outside this repo**: `git add` answers `fatal: … is outside repository` and
`ledger-commit.sh` exits 1. So it is locked and never committed. Its principal writers are retro
step 2 (banking learnings) and weekly step 1 (rewriting the index) — both must take the lock, or
two instances closing tasks at the same time silently lose an index line.

## 9. Session start

Replaces CLAUDE.md §8's "find a rival and stop". The steps are ordered, not concurrent — several
of them read state that earlier steps change.

1. Version gate (herdr pin).
2. Resolve identity from `SHEPHERD_ID`. Acquire `shepherd-<id>.lock` (§3.2). On a live collision,
   stop here and report.
3. Read `HERDR_PANE_ID`; get own `agent_session` (adapter R7). Write the registration file.
4. Sweep stale locks (§6.4). Report anything marked orphaned.
5. Delete abandoned reservations whose claimant is gone (§4.2).
6. **Reconcile self:** every lock naming me must correspond to a card I own, and every active
   card I own must have its project lock. A mismatch means a crash mid-sequence — most likely a
   half-finished reassignment (§10). Report each mismatch to the operator; repair only the unambiguous
   direction (I own the card and no live instance holds the lock → take the lock, with
   `lock.sh takeover`, §6 — it re-checks liveness itself and refuses if the holder turns out live
   or unresolvable, so attempting it is always safe).
7. List live instances: the identity locks that remain (`ledger/locks/shepherd-*.lock`, ignoring
   `*.reclaim.lock`), each resolved through its recorded pane and session with `shepherd_live`.
   Step 4 already swept the gone ones, so what remains and answers is the live set. Reported as
   part of step 10's line, not as a separate message (CLAUDE.md §8 step 10).
8. Grep active cards. Re-arm watchers **only** where `owner:` is me.
9. Check for my own dispatchable queued cards (§5.4).
10. Report: my active tasks, then one line naming other instances' active tasks and any orphans.

## 10. Reassignment

Triggered only by the operator: *"shepherd-2, take T-NNNN."*

Order matters. The card is written **before** the lock, so that every crash point leaves a state
that §9 step 6 can detect:

1. Confirm the previous owner is not live, or that the operator has said to take it anyway.
2. Set `owner:` on the card. Append a Log line naming both instances and the reason. Commit.
3. Take `project-<clone-id>.lock`:
   - Not held → acquire normally.
   - Held by a gone instance under the orphan rule → `lock.sh takeover` (§6), which does the
     **atomic rename**: write a fresh lock file with my details under a temporary name, then `mv`
     it over the old one. Rename is atomic on
     one filesystem, so no sweeper ever observes a truncated or absent lock. v1 specified an
     in-place rewrite, which across two tool calls opens a window where a sweeper reads an empty
     lock, classifies it "names no task", deletes it, and a third instance then creates its own —
     two holders of one project lock, exactly the disaster the orphan rule exists to prevent.
4. Arm the watchers.
5. Commit.

A crash after step 2 leaves a card I own without its lock — detected and repaired by §9 step 6.
A crash before step 2 leaves the task orphaned and reported, which is the pre-reassignment state.

The previous owner, if it wakes, re-reads `owner:` (§5.1 rule 5), sees it is no longer the owner,
and stands down without acting.

## 11. Files this design touches

| File | Change |
|---|---|
| `CLAUDE.md` | new `## 0. Operator` block (`id`, `worker-cap: 6`, `notifications`); §2 rule 3 rewritten around the cap and the project lock; §2 gains the multi-instance rule; §8 session start replaced by §9 |
| `.claude/skills/triage/SKILL.md` | step 2 calls `reserve-task-id.sh`; sets `owner:`; card locks + commit-inside-lock for registry writes |
| `.claude/skills/dispatch/SKILL.md` | `owner: <me>` filter on selection; `dispatch.lock` around count-and-claim; project lock; clone resolution |
| `.claude/skills/monitor/SKILL.md` | re-read `owner:` at every wake, stand down if not mine |
| `.claude/skills/retro/SKILL.md` | release project lock; owner-filtered next-dispatch + handoff notification; per-instance decision file; Clones row cleanup |
| `.claude/skills/onboard/SKILL.md` | `card-_index.lock` around the registry index edit |
| `.claude/skills/herdr-adapter/…` | R7 already returns `agent_session`; add the self-pane recipe used by §3.3 |
| `templates/task-card.md` | `owner:` field |
| `scripts/` | new: `reserve-task-id.sh`, `lock.sh`, `ledger-commit.sh` |
| `.gitignore` | `ledger/locks/`, `ledger/shepherds/` |
| `FRAMEWORK.md` | locks and shepherds dirs are instance state; new scripts are framework |
| shepherd auto-memory | any "one shepherd at a time" note rewritten as the multi-instance contract |

## 12. Verification

The primitives already passed (§4.1, §7.2, §8.1). The drill therefore targets the **windows**,
which is where v1 actually broke:

1. **Reserve under contention** — 30 parallel `reserve-task-id.sh` → 30 distinct ids, every file
   carrying its claimant line.
2. **Kill between reserve and fill** — kill an instance holding a reservation. Another instance's
   session start must leave it alone while the pane is alive, and delete it once the pane is gone.
   It must never re-issue a live reservation.
3. **Simultaneous same-id boot** — two sessions, same `SHEPHERD_ID`. Exactly one starts; the other
   refuses and reports.
4. **Commit under contention** — 5 parallel `ledger-commit.sh` on distinct paths → 5 commits, no
   lost file, no cross-contaminated commit. (Five, not twenty: twenty simultaneous commits is not
   a load this system can produce.)
5. **Shared-path commit** — two instances editing one registry card under the card lock → no torn
   file in history.
6. **Kill mid-reassignment** — kill between §10 step 2 and step 3. Session start must detect the
   card-without-lock mismatch and repair it.
7. **Orphan rule** — kill an instance holding a project lock with an active task → sweep keeps the
   lock and reports the task orphaned. Repeat with a closed task → sweep frees it.

## 13. Known limits

- **Live-but-wedged holders** cannot be resolved automatically (§6.5). They are reported to the operator.
- **Orphaned workers.** A gone shepherd's worker keeps running with nobody watching. §6.4 makes
  this visible instead of silent, but it still needs the operator to reassign.
- **Handoff messages are best-effort.** §5.4's backstop turns a lost message into a delay.
- **FIFO is per-instance.** Two instances may both queue cards for one project; each dispatches
  only its own when the lock frees, so strict FIFO by `created:` is not guaranteed across
  instances. Accepted.
- **Sweep's re-verify window.** Sweep re-reads a lock's line immediately before unlinking
  it, which narrows the delete-after-stale-read race from a herdr round-trip to two
  syscalls, but does not close it. Accepted: the shell offers no atomic compare-and-delete.
- **Persistent per-pane failures never self-clear.** If `herdr pane get` keeps failing for one
  specific pane while answering for every other — a wedged pane, not an outage — its lock or
  reservation is reported `UNKNOWN-LIVENESS` and left in place on every sweep, forever, rather
  than risk deleting a live holder's claim (§3.3, §6.4). It never disappears silently, but it
  also never resolves itself; a human has to notice the repeated report and investigate.
- **Cards with no `owner:` field** default to `owner: shepherd-1`. If shepherd-1 is not running,
  those cards get no watchers and — holding no locks — no orphan report either. This only bites a
  clone carrying cards written before the field existed.
- **Filesystem assumption.** O_EXCL and atomic rename are verified on a local Linux ext4 volume.
  If the clone lives on a translated or network filesystem (WSL's `/mnt/*` 9p/drvfs, NFS, SMB),
  re-verify both before trusting them.

## 14. Review record

v1 was reviewed adversarially by a fresh session with instructions to break it, including
running the load-bearing primitives rather than reasoning about them.

**Confirmed sound and kept unchanged:** O_EXCL reservation (100-way contention, exactly one
winner, five rounds of five), git worktree branch exclusivity (stronger than claimed — `branch -f`
is refused too), per-instance decision files, the `owner:` field, and the orphan rule's refusal to
free a lock over a running worker.

**Accepted and fixed:** the age-based reservation cleanup (§4.2) — the most serious defect;
owner-blind dispatch selection (§5.2), which would have reintroduced the exact incident this
design prevents; the check-then-write identity guard (§3.2); non-atomic reassignment (§10);
commit-after-release on shared paths (§6.2); three false claims about the git commit command
(§8.1); pid-based liveness (§3.3); the registration sweep, now removed (§3.4); the undefined
sweep case for queued tasks (§6.4); the unlocked `MEMORY.md` (§8.4); and the ambiguous lock scope
during clone creation (§7.2).

**Accepted as over-engineering:** per-slot worker locks, replaced by one short-lived
`dispatch.lock` (§6.3).

**Departures from the reviewer's suggestions:**

- It called the whole registration subsystem over-engineered. Kept, but reduced: the identity
  lock does the enforcing, the registration file is now advisory only, and nothing sweeps it.
- On commits it noted the retry budget failing a 20-way parallel drill. The budget is raised, but
  the drill is also corrected to 5-way: twenty simultaneous commits is not a load two or three LLM
  sessions can generate, and designing around it would mean private-index plumbing whose own
  failure mode (a stale shared index showing the operator phantom modifications) is worse than
  the problem.
- On liveness it suggested capturing the claude pid via `$PPID`. Rejected as implementation lore.
  The herdr pane plus `agent_session` is an authority shepherd already relies on for workers.
