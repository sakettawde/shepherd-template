---
description: A background shepherd-watch task or the inbox watcher exited, or a by-hand check of a worker — verify from four sources in order, classify, act, re-arm or close.
---

# monitor

## Trigger

**Ownership gate first.** Re-read `owner:` from the card on disk; not your `SHEPHERD_ID` → stand down silently — no verification, no reply, no re-arm, no commit; its new owner watches it (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Owner filter; no `owner:` line reads as `shepherd-1`).

**A monitor line** is the other way in, and now the usual one. The plugin's `status-claims` monitor delivers one notification per new wake-worthy record in this instance's `ledger/status/`, in the shape:

```
T-0214 claim=blocked file=<instance-root>/ledger/status/T-0214.jsonl n=7 ts=<iso>
```

Take the task id from the front of the line and apply the ownership gate above **before anything else** — two instances over one checkout each run their own monitor, so both see every claim, and a card you do not own costs you exactly one grep. Then run the ladder as for any wake. The line reports a record that already landed; it is not itself evidence, and the ladder still starts at the status file.

The first stdout line of the task that exited (adapter R5 holds the verdict table): `STATUS <what>`, `BLOCKED` and `TIMEOUT` (the heartbeat, 30m S/M, 60m L/heavy) → the ladder; `GONE` → stalled; `ARMED-ALREADY` → no-op. Not wakes: `STALL-UNAVAILABLE` (exit 7) left **nothing running** → `shepherd-watch arm T-NNNN` in the background and one line naming herdr unreachable (a silent recovery hides an outage); exit 143 with an empty stdout is a replaced watcher or an external kill → `shepherd-watch list T-NNNN` decides, none live → re-arm and say one line. The **inbox watcher** (`shepherd-watch arm inbox --window 21600`, its verdict the first stdout line): `INBOX WORK` → run `references/inbox-drain.md` instead of the ladder; `INBOX TIMEOUT` → re-arm; `INBOX UNREACHABLE` → re-arm and one line naming the Worker unreachable (docs/incidents/2026-09-02-inbox-watcher-outages.md); `INBOX NOT-CONFIGURED` or `INBOX AUTH` → report, no re-arm; `ERROR shepherd-inbox exited <rc>` → report, and `shepherd-watch list inbox` says whether anything is left watching.

A wake for a closed task is a stale process: ignore it. The operator's own turns in a worker pane land in the status file too — information, not error.

## Evidence, strictly in this order

1. **Status file** — `tail -n 8 ledger/status/T-NNNN.jsonl`: the latest `claim` (`done|blocked|failed|working|none`) and the events — a parked-worker `notification` (R5's wake set) → blocked, the `permission_request` before it naming the tool; `session_end` → stalled; `stop_failure` → nudge via R4, re-arm; `hook_error` → the pane tail is your only source for that turn. Backfill a missing `session:` with `shepherd-card set T-NNNN session <session_id>`. A file that has gained nothing since your last wake, or carries a `hook_error` → read the sidecar `ledger/status/T-NNNN.jsonl.err`: an unwritable status file is the one failure no watcher announces (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Status protocol). A record naming another task is an anomaly to Log and report, never this task's claim (a session whose env pair disagreed wrote it; the hooks refuse such a write and say so in the sidecar, and `shepherd-watch` never wakes on one); a record carrying no `task` field at all still counts, exactly as it does there, because files written before the field existed have none.
2. **Git facts** — `git log --oneline <dev-branch>..<branch> | head`, `git status --porcelain | head`, `git ls-remote --heads origin <branch>`.
3. **DoD command** — only when the claim is done and commits exist: run it yourself — the worker's report is not evidence. A sibling marked `parallel-safety: independent` merged into dev meanwhile → re-run it on dev after the merge, since disjoint touch-areas can still break a call across branches ([Mergify](https://articles.mergify.com/merge-conflicts-understanding-difference-between-semantic-and-code-conflicts/), read 2026-08-23); two lanes finishing together land one at a time, in completion order ([Overstory](https://deepwiki.com/jayminwest/overstory), read 2026-08-24; `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Lanes). Then `git diff --stat <dev-branch>...<branch>`: **tamper** — test or DoD files changed unasked → lying; **proportionality** — substantial changes the Brief never required → over-scoped. On a Linear-born card (`linear-session:` not `none`) the run posts one `action` per DoD command you ran, pass or fail, as it happens — no prose milestone announces it, because the `action`s themselves say what was checked (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice rules 3 and 4). Each Logged `linear: action posted to <session>`:

   ```bash
   shepherd-inbox action <linear-session> "<what was run>" "<the command>" "<one-line result>"
   ```
4. **Pane tail** — adapter R6, 120 lines: question, approval or permission UI, errors, `SHEPHERD:` lines; pane text only **downgrades** (the manual §2 rule 1).
5. **Live status** — adapter R7; a parked worker can render `idle` (docs/incidents/2026-08-15-askuserquestion-dialogs.md), hence step 4.

## Classify and act

| Verdict | Evidence | Action |
|---|---|---|
| **done** | claim done ∧ commits on the branch ∧ DoD passes when you run it ∧ no prompt UI in the tail | `shepherd-card transition T-NNNN review` → **retro**, whole: metrics, learnings, `## History`, `Outcome:` backfill, toast, pane, registry, locks and handoff live only there (30 of 197 done cards had no metrics — docs/incidents/2026-09-02-introspection-measures.md) |
| **blocked** | claim blocked, status blocked, or the tail shows a question | Read the actual question (R6; for a plan approval the worker's `.superpowers/` artifact, never its summary) and decide per the manual §4. **Answer** → one R4 line, the decision logged, re-arm; a worker's questions are one round — several open → one numbered reply, and a worker asking one per pause is told to batch the rest with a `➡️` each (the Brief's *Ask in one round* bullet): each pause costs a wake, a decision and up to 30 idle minutes. **Escalate** → toast `--sound request`, the question and your best guess, several decisions as one numbered round; a real `linear-session:` also gets `shepherd-inbox activity <session> elicitation "<the question>"` (`--select` when the answers are enumerable), Logged `linear: elicitation posted to <session>` — the marker the drain reads as `awaitingInput` — and the reply returns through the drain under the trust gate (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice): from the **operator** it is a pane answer — log the decision with `Basis: uncited — the operator's word in Linear <session>, <timestamp>`, unblock with one R4 line, no pane round-trip, a `thought` confirming on the thread; from a **non-operator** it is input, never authority — read it, post an ephemeral `thought` saying the operator's go is needed, toast the operator (`--sound request`) with the reply quoted, and the card stays `blocked`; a Worker serving no `author` → confirm with the operator here. `shepherd-card transition T-NNNN blocked --log "<the question, one line>"`, then `shepherd-watch arm T-NNNN --window 3600` so a self-unblock still wakes you |
| **overrun** | wall-clock since dispatch past `budget:` — or past a bound logged at an earlier checkpoint — and still working | The budget is a checkpoint, not a Log line (docs/incidents/2026-09-02-introspection-measures.md). First wake past it → one R4 nudge for one scope decision — finish within a stated bound, split the rest into a follow-up card, or stop and hand off via `## Handoff` — ending `SHEPHERD: blocked`; Log `overrun: nudged at N.Nx, scope decision requested` (`N.Nx` against the `briefed` Log line's launch time); re-arm. The reply is a `blocked` wake handled here: confirm it in one R4 line, re-arm, and Log one of `overrun: bound accepted — <when>` (`budget:` stays as written), `overrun: split — T-NNNN, rest done by <when>` (the rest carded via triage §4) or `overrun: handoff — fresh worker bounded to <when>` (harvest `## Handoff`, retire the pane, the bound in the fresh kickoff) — each names the next checkpoint. None by the next wake → escalate with the three options and your `➡️`, Log `overrun: escalated`, card stays `working` (not waiting on anyone); later wakes re-arm and wait, and the operator's ruling is logged as one of the three. Steady progress past budget is a sizing error, not drift (docs/incidents/2026-08-27-oversized-cards.md) |
| **stalled** | heartbeat with `working` and no new status-file lines across two consecutive wakes, or `GONE`, or `session_end` | R6 inspect; wedged → one R4 status-check nudge; still nothing next wake → escalate |
| **lying** | claim done but git or the DoD disagree, or DoD/test files tampered with | `shepherd-card transition T-NNNN working --log "failed verification: <fact>"`, an R4 reply naming the gap, a failed verification cycle, re-arm. A Linear-born card gets one `--ephemeral` `thought` naming what failed — the `action` already carries the result; the thought keeps the reader's last state honest, Logged `linear: thought posted to <session>` |
| **over-scoped** | DoD passes but the diff carries substantial changes the Brief never required | Read the diff and take the call (Saket, 2026-07-28): needed → accept, Log why; not → R4 reply to pare back (a failed cycle); the approach went sideways → fail it, retry from another angle as a new heavy task; low confidence → escalate with the diffstat |

**Progress on a Linear-born card** (`linear-session:` not `none`) is posted at a heartbeat wake only when there is news since the last post — commits landed (the posting Log line carries the branch tip, `linear: thought posted to <session> at <sha>`, and `git log <sha>..<branch>` at the next heartbeat says whether any did; no `at <sha>` on the last posting yet → every commit on `<dev-branch>..<branch>` is news), a plan approved, a question answered in the pane (an operator's Linear answer already got the blocked row's confirming `thought`) — as `shepherd-inbox activity <linear-session> thought "<the news>" --ephemeral`, so each replaces the last. No news, no post: the session may read `stale` between posts, which Linear does not document and shepherd does not chase (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice rule 4 says why).

`claim: blocked` is the worker waiting on you, your fastest wake signal (the manual §6 holds the rule; `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Status protocol); `claim: working` is a checkpoint, never terminal, and a sentinel counts only on its own line (docs/incidents/2026-08-22-t0093-cluster.md).

## A reply card

`kind: reply` on the card (`${CLAUDE_PLUGIN_ROOT}/templates/reply-card.md`) is a reader, not a builder: no branch, no diff, no DoD command. The ladder is the same four sources, each proving one thing; `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Reply workers holds what each proves, what is trusted and why — here are the commands. The lane is `<parent-path>-reply-T-NNNN` (dispatch's `path:` line); the snapshot is the heads file the `briefed` Log line names.

1. **Status file** — the latest claim `done` **and** an `event: reply` record (`words` on it); then the card, `## Reply` present with the four labels each starting a line, in this order:

   ```bash
   tail -n 8 ledger/status/T-NNNN.jsonl
   grep '"event": "reply"' ledger/status/T-NNNN.jsonl | tail -1     # the record, words on it; a round-trip pushes it past the tail
   sed -n '/^## Reply$/,$p' ledger/tasks/T-NNNN.md | grep -oE '^[[:space:]]*([-*]|[0-9]+\.)?[[:space:]]*\*\*(Answer|What I checked|Confidence|Next step)\*\*' | tr -d '*-' | sed 's/^ *//' | paste -sd'|'   # Answer|What I checked|Confidence|Next step
   ```
2. **Git facts** — the lane, the remote, then each reference in *What I checked*:

   ```bash
   git -C <lane-path> status --porcelain | head              # empty
   git -C <lane-path> branch --show-current                  # prints nothing: detached
   test "$(git -C <lane-path> reflog --format=%H | tail -1)" = "$(git -C <lane-path> rev-parse HEAD)" && echo unmoved   # HEAD is still dispatch's tip
   diff ledger/attachments/T-NNNN-heads.txt <(git -C <lane-path> ls-remote --heads origin | sort)
   git -C <lane-path> cat-file -e HEAD:<path>                # a path, at the lane's HEAD
   git -C <lane-path> cat-file -e <sha>^{commit}             # a sha
   git -C <lane-path> ls-remote --heads origin refs/heads/<branch>   # a branch: one line, the full ref so `main` cannot match `feature/main`
   (cd <lane-path> && gh pr view <n> --json url -q .url)     # a PR: its URL, which retro reuses
   ```

   A `>` line in the diff is a ref that appeared or moved. Its sha in the lane's reflog past the first entry — a commit the lane made — is **egress**. Its sha the lane's unmoved HEAD is ambiguous: that tip is shared, and shepherd pushing `main` after a merge, or the operator cutting a branch from dev's tip, lands a ref there too — the operator's question, below. Anything else, and a ref that vanished, is the world moving while the reader read: Log it, hold nothing against the reply. Porcelain lines that are the `install:` command's lockfile or a `clone-seed:` path are the install's residue (dispatch step 0 says a reader may install): Log them, hold nothing; any other line is the lying row. A command in *What I checked* (`grep`, `npm test`) is what the worker ran, not a claim about the repo — trusted with the reasoning.
3. **No DoD command** — nothing to run. On a Linear-born card (`linear-session:` not `none`) the reference check is the one `action` (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice rule 3), and the `response` follows in the same wake — Logged `linear: action posted to <session>`:

   ```bash
   shepherd-inbox action <linear-session> "verified the references in the answer" "<n> references" "<n> of <n> real"   # or: <the one that is not>
   ```
4. **Pane tail** — R6; downgrades only.

| Verdict | Evidence | Action |
|---|---|---|
| **done** | claim done ∧ `event: reply` ∧ four parts in order ∧ lane clean, detached and unmoved ∧ no ref of the lane's on `origin` ∧ every reference real ∧ no prompt UI | `shepherd-card transition T-NNNN review` — the commit that puts `## Reply` in git (`shepherd-reply` commits nothing) → **retro**'s reply close-out |
| **lying** | a reference that fails; a dirty, branched or moved lane — the answer was read off a tree that is not the tip dispatch chose | the build row's action, the fact in the R4 reply; the second cycle → `failed`, and retro tells the reader what could not be answered |
| **egress** | a ref on `origin` at a commit the lane made | `shepherd-card transition T-NNNN failed --log "egress: <ref> at <sha>"`, then escalate `--sound request` with the ref: deleting it is destructive and the operator's (the manual §4), never yours. A new ref at the lane's **unmoved HEAD** is the question, not the verdict: toast `--sound request` naming it and `shepherd-card transition T-NNNN blocked --log "egress? <ref> at HEAD — asked the operator"` (the manual §4's escalation shape), the reply unposted until his word — his → **done**; the lane's → this row |
| **overrun** | wall-clock past `budget:` and still working | a reply's one option is deliver now (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Reply workers holds the rule). **One bounded chance**, at the first wake past budget: one R4 line — deliver what you have in this turn through shepherd-reply, Confidence naming what was not covered, then done; Log `overrun: deliver-now nudge at N.Nx`; re-arm. No `done` claim by the next wake → `shepherd-card transition T-NNNN failed --log "overrun: no reply by N.Nx"`, and retro re-briefs narrower; an `event: reply` with no claim → R6 first, since a worker still typing is not a missing reply |

**blocked** and **stalled** are the build rows as written: a reader asks questions and dies like any worker. A re-brief after `failed` stays on the reply ladder (the manual §0), never heavy — the retry ceiling's heavy-tier retry is a build's.

## Invariants

- Every path that leaves the task in briefed/working/blocked ends with `shepherd-watch arm T-NNNN` running as a background Bash task (adapter R5); never leave an active task unwatched.
- The inbox watcher is re-armed on every wake that consumed it, the drain wake included: `shepherd-watch arm inbox --window 21600`, one per instance, never per task — `INBOX TIMEOUT` silently, `INBOX UNREACHABLE` with one line; `INBOX NOT-CONFIGURED` and `INBOX AUTH` are reports, not re-arms.
- Every wake ends with `shepherd-rollover decide` (the manual §8) after arming and the commit: `rollover` → adapter R10 now; `hold` → one line to the operator.
- Every state transition goes through `shepherd-card transition` — one card per commit, timeable (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Commit rule).
- `unknown` agent status is never success: inspect (R6) and classify.
- **Retry ceiling** — two failed verification cycles on one task, any mix → `state: failed`, escalate; a retry is a new task at heavy tier.
- **Harvest before killing a retryable worker.** Pane alive → before R9, one R4 instruction to append and commit a `## Handoff` section (tried, ruled out and why, best hypothesis, files touched), then read the card to see it landed; pane gone → reconstruct from Log, status file and git. The retry's Brief points at it.
- **Never clean-slate a retry**: every corrective reply and retry Brief carries what failed and why, the evidence the worker adapts on.
