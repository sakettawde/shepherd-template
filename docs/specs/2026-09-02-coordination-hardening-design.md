# Coordination hardening: events log, validated locks, honest sweep exits, rollover-safe liveness

Task: T-0217. Program: `docs/reports/2026-09-02-introspection.md` §R8, plus §R3's
`shepherd-lock live` and the captured T-0128 item 2. Extends
`docs/specs/2026-08-18-multi-shepherd-design.md` (§3.3, §6, §9); where the two disagree,
this document wins for the behaviours it names and the older spec stands for everything else.

## 1. Problem

Every coordination verdict — a sweep, a takeover, a release, a reservation — exists only in
the context window of the instance that ran it. `sweep` exits 0 even when it printed
`MALFORMED` or `SWEEP-SKIPPED`. Lock names are not validated, so a `/` in a name writes a
file outside the sweep glob. `release` deletes on holder match without re-reading the line.
`shepherd_live` treats a changed session id as death, so after a context rollover an
instance's own project locks read as gone until something re-writes them. Nothing counts how
often each sweep line kind fires, so nobody knows which arms are dead code. And one identity
test depends on the wall clock.

## 2. Events log

### 2.1 File and line shape

`$SHEPHERD_ROOT/ledger/events.log`, append-only, one line per event:

```
<iso8601> <instance> <verb> <target> <verdict> [detail…]
```

Fields 1–5 are fixed, whitespace-separated tokens; field 6 onward is free text. Examples:

```
2026-09-02T06:20:11+00:00 shepherd-kelpie acquire project-karta ACQUIRED T-0217
2026-09-02T06:20:14+00:00 shepherd-kelpie sweep project-karta ORPHAN T-0100 state=working holder shepherd-9
2026-09-02T06:20:14+00:00 shepherd-kelpie sweep - SWEEP-SKIPPED liveness oracle unavailable
2026-09-02T06:21:02+00:00 shepherd-collie reserve T-0224 RESERVED
2026-09-02T06:21:40+00:00 shepherd-collie identity shepherd-collie IDENTITY pane=w6:p1 session=abc
```

- **instance** — the actor. The holder argument where the verb has one (`acquire`, `release`,
  `takeover`, `reserve`, `identity`); otherwise `$SHEPHERD_ID`, or `-` when that is unset.
- **verb** — `acquire`, `release`, `takeover`, `live`, `sweep` (shepherd-lock); `reserve`,
  `reserve-sweep` (shepherd-reserve); `identity`, `identity-touch` (shepherd-identity).
  `check` is read-only and writes no event.
- **target** — the lock name, task id or shepherd id the event is about; `-` when there is
  none (a `SWEEP-SKIPPED` pre-flight).
- **verdict** — exactly the first word the command prints for that outcome (`ACQUIRED`,
  `HELD`, `ERROR`, `RELEASED`, `FREE`, `REFUSED`, `CHANGED`, `TOOK-OVER`, `MALFORMED`,
  `UNKNOWN-LIVENESS`, `SWEPT`, `RM-FAILED`, `ORPHAN`, `LONG-HELD`, `UNKNOWN-LOCK`,
  `SWEEP-SKIPPED`, `RESERVED`, `IDENTITY`, `REFUSE`, `TOUCHED`, `live`, `gone`,
  `unresolved`). Stdout and the log therefore never disagree, and a grep that works on
  one works on the other.

Why whitespace tokens and not JSON lines: every field is already whitespace-free by
validation (§3), `awk` and `grep` count it natively, and it mirrors the lock line these same
scripts already parse with `read -r`. Confidence high; a later consumer that wants JSON can
convert a fixed-column line in one `awk`.

### 2.2 `elog`

One function in `scripts/lib/shepherd-common.sh`:

```
elog <instance> <verb> <target> <verdict> [detail…]
```

- Writes one line with a single `printf` to a file opened `>>`. The guarantee is `O_APPEND`
  plus the line being emitted as one `write(2)`, which holds while the line stays under bash's
  stdio buffer (about 4 KiB); `PIPE_BUF` governs pipes, not regular files. So concurrent
  instances never interleave inside a line and no lock is taken.
- Creates `ledger/` if missing.
- **Never fails its caller.** Every error path is `|| true` with stderr discarded: a
  coordination verb must not refuse because the log is unwritable. The log is an audit trail,
  not a gate.
- `EVENTS_LOG` is a variable next to `LOCKS_DIR`, so tests running under a sandbox
  `SHEPHERD_ROOT` get their own file.

No rotation. One line per lock operation is hundreds of lines a day; a year is a few
megabytes. Rotation is a later task if the file ever matters.

### 2.3 Gitignored

`ledger/events.log` joins `ledger/locks/` and `ledger/shepherds/` in `.gitignore`.

- It is machine-local runtime state: pane ids and session ids mean nothing on another machine.
- Every instance appends outside any card lock. Committing it would need a lock around every
  append and a commit per sweep, with no ledger transition to name in the message.
- `SHEPHERD_ROOT` is hard-coded on purpose, so a worktree's scripts append into the base
  checkout; a tracked file there would sit permanently dirty, and `shepherd-commit`'s
  path-scoped commits would never carry it.

Confidence high.

### 2.4 Dry runs write nothing

A `--dry-run` sweep (§5) writes no events. "Changes nothing" includes the log; a dry run that
logged `SWEPT` lines would double-count every verdict in `stats`.

## 3. Validated names

`valid_name <what> <value>` in the lib, one pattern:

```
^[A-Za-z0-9_][A-Za-z0-9_.~-]*$
```

It admits every name in use — `dispatch`, `card-_index`, `card-_memory`, `project-karta~2`,
`shepherd-kelpie`, `shepherd-kelpie.reclaim` — and rejects `/` (path escape), whitespace
(field shift), and a leading `.` (a name that would match the `.tmp.*` cleanup glob or hide
from `ls`). Every `shepherd-lock` verb that takes a name (`acquire`, `takeover`, `release`, `check`)
runs it before any file is touched; a bad name is **exit 2**, and the message names the rule:

```
ERROR: name must match ^[A-Za-z0-9_][A-Za-z0-9_.~-]*$ (got 'bad/name')
```

Reservation ids are generated (`T-NNNN`) and cannot be bad; `shepherd-reserve` keeps its
existing holder/pane/session field check. `shepherd-identity` keeps its stricter
`shepherd-…` regex, a subset of this pattern, because the sweep's `shepherd-*` arm depends on
the prefix.

## 4. Release compares before it deletes

```
shepherd-lock release <name> <holder> [pane] [session]
```

- Two arguments behave as today: the holder must match field 1, else `REFUSED`, exit 1.
- With pane and session given, fields 2 and 3 must match too, else `REFUSED`, exit 1.
- In both forms the line is captured on the first read and **re-read immediately before
  `rm`**. A changed line is reported `CHANGED <name> - re-acquired since the check, left
  alone`, exit 1, file intact. The timestamp field makes every acquisition's line unique, so
  string equality is the compare.
- `FREE` on a missing or unparseable file stays exit 0 with nothing deleted, as today.

Holder-only remains the default because a rolled-over instance legitimately releases a lock
its previous session acquired (§6): the holder id is the identity, the session is not.

## 5. Sweep exit codes and `--dry-run`

Both `shepherd-lock sweep` and `shepherd-reserve sweep` accept `--dry-run`.

**Exit codes.** `3` when at least one printed line needs a human: `MALFORMED`,
`SWEEP-SKIPPED`, `UNKNOWN-LOCK`, `UNKNOWN-LIVENESS`, `RM-FAILED`. `0` only when everything
it saw was routine. `SWEPT`, `ORPHAN`, `LONG-HELD`, `CHANGED`, `RESERVED` are routine for
this purpose: they are reported at wake as before, but each either resolved itself or has
a step that handles it (wake step 6, §4a reassignment).

**`RM-FAILED`.** A `SWEPT` line asserts the file is gone and every reader treats it that
way, so both sweeps check the `rm` and neither prints `SWEPT` unless it succeeded. A
failure prints `RM-FAILED <target> - could not remove, inspect by hand`, with `rm`'s own
stderr discarded because the verdict line replaces it; the target survives, and the exit
is 3. This is the rule `release` already follows for its own delete (§4): the one claim
an audit log must never carry is a deletion that did not happen. A new verdict rather than
an overloaded `MALFORMED`, which means "could not parse" and would blur the two — so it is
an eighth line kind at the operator surface, and wake step 3 gains an entry for it. A dry
run takes the success path without calling `rm` at all.

**Dry run.** Prints `DRY-RUN no changes will be made` first, then exactly the verdict lines a
real sweep would print, and performs no `rm`, no `.tmp.*` cleanup and no `elog`. The exit code
follows the same rule, so `sweep --dry-run; echo $?` is a safe pre-check.

The wake skill's steps 3 and 4 each gain one line: what exit 3 means and that the operator
report must name the lines behind it.

## 6. Rollover-safe liveness

### 6.1 `shepherd_live <pane> <session> [holder]`

Two-argument calls are unchanged: the tri-state pair check, 0 live / 1 gone / 2 unresolved,
with the existing test hooks.

With a third argument that matches `shepherd-*`, a direct **gone** is re-resolved through the
holder's identity lock, `ledger/locks/<holder>.lock`:

| Identity lock | Result |
|---|---|
| absent, empty, or short line | gone (1) — as today |
| names the **same** pane and session as the lock being checked | gone (1) — as today |
| names a **different** pane/session pair | that pair's own pair check decides: 0, 1 or 2 |

The re-resolution calls the pair check directly, never `shepherd_live` again, so there is no
recursion and the test hooks (`SHEPHERD_LIVENESS_OVERRIDE`, `SHEPHERD_LIVENESS_UNKNOWN`)
apply to the identity pair exactly as to any other pair.

A direct **live** or **unresolved** answer is never re-resolved: an unresolved probe is still
not evidence of anything, and the identity lock cannot make it one.

Callers that pass the holder: `shepherd-lock sweep` (field 1 of each line), `shepherd-lock takeover`
(the current line's holder), `shepherd-reserve sweep` (the reservation's holder),
`shepherd-lock live`. `shepherd-identity acquire` also passes it; for an identity lock the pair
is by definition the same, so its behaviour is unchanged.

### 6.2 What this buys

After a context rollover the pane's Claude session id changes. Wake step 2 re-acquires the
identity lock with the new pair. Every other lock that instance holds — project locks above
all — still carries the old session. Before this change each of them resolved gone: a peer's
sweep reported them `ORPHAN` (kept only by the active-task rule) or freed them outright, and
wake step 6 had to take them over. Now each resolves **live** through the identity lock, so a
peer sweep keeps them, `LONG-HELD` still applies to a live holder's card locks, and step 6
finds nothing to take over. The stale session field inside those locks is informational.

The trade: a lock left behind by a **crashed** incarnation of an id that has since
relaunched is no longer swept by anyone, because its holder now resolves live through the
new incarnation's identity lock, and `LONG-HELD` covers only `card-*` and `dispatch`. Where
the task is closed or absent and the live instance does not know it holds the lock, nothing
in the system frees it on its own. The recovery is the two-argument form, which compares on
the holder alone by design (§4) and so matches a line its previous session wrote:

```
shepherd-lock release project-<clone-id> "$SHEPHERD_ID"
```

Wake step 6 carries it as the first of its two repairs.

### 6.3 The residual gap, stated

The seconds between `/clear` and wake step 2 are not covered: the identity lock itself still
names the old session, so the table's second row applies and the instance's locks read gone.
Only a peer sweep landing inside that window could act, and what it could act on is narrow:
the `ORPHAN` rule keeps every project lock over a `briefed|working|blocked|review` task, and
CLAUDE.md §8 forbids rolling over while holding `dispatch` or a card lock. The exposure is a
project lock over a `queued`, `none` or closed task during those seconds.

Closing the gap fully would mean treating "same pane, different session" as **unresolved**
rather than gone. That contradicts spec §3.3 ("a pane that exists but runs a different session
is gone"), would leave a reused pane's identity lock reported `UNKNOWN-LIVENESS` at every wake
until a human removed it, and would break `shepherd-identity acquire` from the instance's
own pane after a rollover. The gap is accepted and recorded here. Confidence high that the
brief's reading is this one; medium that the gap will never bite, which is why it is written
down.

### 6.4 `shepherd-lock live <id>`

```
shepherd-lock live <id>      # prints: live|gone|unresolved <id> <pane> <session>
```

Exit 0 live, 1 gone, 2 unresolved. Reads the identity lock `ledger/locks/<id>.lock` and runs
`shepherd_live <pane> <session> <id>` on its pair. No identity lock → `gone <id> - -`, exit 1:
the instance never launched or was swept. Malformed identity lock → `unresolved <id> - -`,
exit 2. An id that fails the `shepherd-…` pattern → `ERROR` on stderr, nothing on stdout, exit
2. Every answer is logged with verb `live`.

The wake and dispatch skills that currently source the library function by hand are outside
this task's touch-areas; T-0221 wires the dispatch preflight to this verb.

## 7. Counters

```
shepherd-lock stats          # prints: <count> <verb> <verdict>, sorted by verb then verdict
```

One `awk` over the events log, `c[$3" "$5]++`. The usage text carries the equivalent
one-liner so the count works with nothing but `awk`, and a `grep '^2026-09-'` prefix bounds
it to a month. No `--since` flag: the log is small and the grep is the flag.

## 8. Deterministic `last_seen`

`now_iso` honours a new test hook, `SHEPHERD_NOW_OVERRIDE`, only when `hooks_active`
(`SHEPHERD_TEST_HOOKS=1`). `test-identity.sh` sets it to two fixed values around the
re-acquire and the touch, drops both `sleep 1`s, and asserts `last_seen` equals the second
value and `started` the first. The test no longer depends on the wall clock at all.

The hook is safe by the same argument as the others: it is gated, and timestamps never
authorise a reclaim (spec §3.3), so a fabricated value could at most mislabel a `LONG-HELD`
report.

## 9. Invariants kept

- Atomic rename, never an in-place rewrite. No new write path is added; `elog` appends.
- Only a resolved gone (1) authorises a reclaim. The identity-lock re-resolution can turn a
  gone into live or unresolved, never the reverse.
- `takeover` still refuses on live, unresolved and changed lines. A rolled-over instance's own
  project lock now reads live, so `takeover` on it is refused as "held by a live instance" —
  which is correct: the instance holds it and does not need to take it.
- Every existing verb keeps its exit codes and output prefixes. `release` gains optional
  arguments; `sweep` gains a flag and a new exit value on paths that previously exited 0
  while reporting a problem. `shepherd_live` gains an optional argument. Skills and
  `shepherd-rollover` need no change.

## 10. Tests

Each behaviour has an assertion in `scripts/tests/`:

- `test-lock.sh`: bad name → exit 2, nothing written, message names the pattern; each verb
  validates; `release` with a changed line → `CHANGED`, exit 1, file intact; four-arg
  `release` refuses a pane/session mismatch; `shepherd-lock live` for live, gone, unresolved,
  missing lock, bad id; `stats` counts a seeded log; each verb writes one events line.
- `test-sweep.sh`: `--dry-run` deletes nothing and logs nothing yet prints every verdict;
  exit 3 for each of `MALFORMED`, `SWEEP-SKIPPED`, `UNKNOWN-LOCK`, `UNKNOWN-LIVENESS`
  individually; exit 0 on a routine run that includes `SWEPT`, `ORPHAN`, `LONG-HELD`; a
  `shepherd-*` holder whose identity lock carries a new live pair keeps its project lock; every
  sweep line has a log line; over an unwritable locks directory both delete arms print and log
  `RM-FAILED` rather than `SWEPT`, exit 3 and leave the file, while a dry run over the same
  directory still prints `SWEPT` and exits 0.
- `test-reserve.sh`: `--dry-run`; exit 3 / 0; identity-lock re-resolution; log lines; the same
  `RM-FAILED` pair over an unwritable tasks directory.
- `test-identity.sh`: clock stub; `last_seen` and `started` exact; log lines for acquire,
  takeover, refuse, touch.
- `test-common.sh`: `elog` line shape, atomic append under contention, unwritable log does not
  fail the caller; `valid_name` accept/reject table; `shepherd_live` three-arg table from §6.1;
  `now_iso` override gated on `hooks_active`.
- `test-docs.sh` already pins the wake skill's commands; steps 3–4 get the exit-code line.
