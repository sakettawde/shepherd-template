---
description: A card is queued and a slot may be free: preflight, launch at the card's tier, arm the watchers.
---

# dispatch

## Preconditions (check, don't assume)

1. The adapter version gate passed this session (R1).
2. **Run the preflight** — preconditions 2–6 as one command, holding on the first failure and naming it; on success it takes the lane lock, claims a slot and commits the claim:

   ```bash
   shepherd-preflight T-NNNN                               # → DISPATCH <lane> | HOLD <reason> | JUDGE …
   shepherd-preflight T-NNNN --lane-ok "<what you read>"   # answers a JUDGE (precondition 5, gate 3)
   ```

   | first line | exit | what it means |
   |---|---|---|
   | `DISPATCH <lane>` | 0 | the lane lock is yours, the card reads `state: briefed` / `pane: claiming-<shepherd-id>-T-NNNN`, the claim is committed; `key: value` lines follow for step 0, `NOTE` lines are non-blocking repairs (precondition 4) |
   | `DISPATCH reply` | 0 | a `kind: reply` card: the slot is yours and **no lane lock was taken** — its lane is the throwaway worktree the `lane:` line names, outside the family FIFO and the three gates, one slot under the cap like any session (`${CLAUDE_PLUGIN_ROOT}/templates/reply-card.md`; spec `${CLAUDE_PLUGIN_ROOT}/docs/specs/2026-09-07-linear-conversation-design.md` §2). The claim is committed as above; `key: value` lines follow for step 0 |
   | `HOLD <reason>` | 1 | a precondition failed, named; nothing held, the card unchanged. Report it: it names what the operator can fix |
   | `JUDGE …` | 3 | gates 1–2 passed on a held lane; the registry excerpt follows — read it, decide, re-run with `--lane-ok` or leave the card queued |
   | `ERROR <why>` | 2 | bad id, no card, a `kind:` that is neither `build` nor `reply`, no `worker-cap` in §0, or `SHEPHERD_ID` / `HERDR_PANE_ID` / `CLAUDE_CODE_SESSION_ID` unset |

   **Target:** the given `T-NNNN`, reading `state: queued` and carrying your `owner:` — never dispatch a card you do not own (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Owner filter). The oldest queued card of yours across the **project family** goes first (`HOLD queue T-XXXX older`; `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Lanes says why); an older sibling blocked on `Depends on:` holds nothing, starvation not order. **Blockers first:** every `Depends on: T-XXXX` — the card's own field, above the Brief (`${CLAUDE_PLUGIN_ROOT}/templates/task-card.md`), not a line inside it — reads `state: done` (`HOLD depends-on T-XXXX <state>`), a guarantee FIFO loses once a second lane opens. A `kind: reply` card is in no FIFO: it neither waits behind an older queued build nor holds one, and the gates' sibling scan skips it too.
3. `onboarded: yes` on the registry card (`HOLD onboarded <value>`); a clone's parent card governs.
4. **The working agreement is reachable, or the Brief carries it.** `shepherd-working-agreement <path> <dev-branch>` runs now against the registry `path:` — `working-agreement:` was set at onboarding, a claim until re-checked (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Working agreement); every lane shares the base checkout's refs (`git rev-parse --git-common-dir`), so one answer serves all. Nothing printed and no numbered rules in `### Context` → `HOLD working-agreement …`: fill the notice and the four rules from `${CLAUDE_PLUGIN_ROOT}/templates/task-card.md` and the registry card, Log, re-run — a worker whose repo rules it cannot read has none (docs/incidents/2026-08-18-t0084-unreadable-agreement.md). The branch printed and the field disagreeing → `NOTE`, and the preflight continues: the onboarding PR merged, so correct the field under `card-<slug>` (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Card lock), delete the now-false notice from `### Context` and restore the Constraints line — unless deliberate (the self-repo's `none`); the inlined rules stay, true either way. It precedes the lock because it only reads refs.
5. **Choose the lane, and take its lock.** The card's `project:` is its *preferred* lane, tried first with `shepherd-lock acquire`; `HELD` is the only entry to lane selection; a lock error is reported with its actual message (`HOLD lock error: <message>`), never as "held by another instance". The three gates (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Lanes), the first failure naming itself:

   1. Both sides — this card and every active card in the family, all owners — declare `parallel-safety: independent`; absent reads as `serialized` (`HOLD gate 1 …`).
   2. `touch-areas:` disjoint, any shared token serializing — blunt on purpose, a card spanning two areas joins both queues ([Mergify](https://mergify.com/product/merge-queue), read 2026-08-24; `HOLD gate 2 overlaps T-XXXX on "<token>"`).
   3. **Your judgment** at `JUDGE`, which prints `## Gotchas` and `## Context notes`, because a worktree isolates the filesystem and nothing else — ports, databases, Docker, build caches stay shared ([Zylos](https://zylos.ai/research/2026-02-22-git-worktree-parallel-ai-development/), read 2026-08-24): a named hazard serializes, silence means safe → `--lane-ok "<what you read>"` (Logged); a lane opened despite a hazard, or at low confidence, is a decision-log entry (§4).

   The preflight then walks the family — existing `~N` rows, then a new lowest `~N`, its lock taken before the directory exists so two instances cannot both create it — and writes a relocation into `project:` with a Log line `undo` reads back. **A card whose `project:` is already a clone never falls back to the base checkout** — the self-repo's base stays on `main` with no field to say so.
6. **Under `dispatch.lock`, claim a slot.** `worker-cap` (the manual §0) is a total across instances, counted as distinct `pane:` values over every owner's active cards; a `claiming-<shepherd-id>-T-NNNN` placeholder counts as one and carries the task id so two claims from one instance stay two. At or over the cap → `HOLD worker-cap M/N`; the lock contended → `HOLD dispatch lock held by <holder> - waiting`; both release the project lock — the preflight never proceeds without `dispatch.lock`. **A lane costs one slot**: the cap bounds workers, the project lock one worker per working copy, the gates a project's live copies.

## Steps

0. **Prepare the lane** — one call, whatever the card's `project:` names; the script reads the card and the registry itself, and the preflight's `lane:` and `path:` lines say which lane it will be. It takes no lock: the fetch, the worktree, the seed and the install all run **outside** any, and only the `## Clones` row below is locked.

   ```bash
   shepherd-lane T-NNNN                 # → READY <lane> | HOLD … | JUDGE … | REFUSED … | ERROR …
   shepherd-lane T-NNNN --dry-run       # the same verdict, acting on nothing
   shepherd-lane T-NNNN --tip <ref>     # a review reply's lane belongs at the PR head
   ```

   | first line | exit | what it means |
   |---|---|---|
   | `READY <lane>` | 0 | the lane is detached at the tip; one this call created is seeded and installed too, a reused one keeps the seed and install it has. `action:` says which — `created`, `reset`, `already-at-tip`, or `none`, a base checkout being never prepared |
   | `HOLD dirty <path>` | 1 | uncommitted work, its porcelain lines below. Undo (step 6) and report the path; never reset over it — the work would ride onto a different base, and the directory is the operator's call |
   | `HOLD lane path exists: …` | 1 | a leftover reply lane, or a stray directory where the lane goes. Undo and report it, never reset or remove it — removal is retro's `## Reply close-out`. This check is the whole guard: `git worktree add --detach` **adopts** an existing directory, empty or not, rather than refusing it (git 2.43.0, measured 2026-09-08) |
   | `HOLD lane path is not a worktree of <parent>: …` | 1 | the row's path is a plain directory, or a *different repository* — being a git repo is not enough, since only a shared object store makes the parent's tip mean anything there. Undo and report the row: resetting it would detach a stranger's checkout off its branch, and the worker would land in the wrong repository with shepherd verifying the wrong repo's facts |
   | `JUDGE fetch failed: …` | 3 | `origin` is configured and the fetch failed, so every ref may be stale: undo and report. No `origin` at all is the other answer, not this one — the local ref, under a `NOTE` (T-0129) |
   | `JUDGE diverged: …` | 3 | local and remote have each moved past the other, so no tip is right: undo and report to the operator rather than choosing for him |
   | `REFUSED …` | 1 | the card is not `briefed`, or not yours; nothing was done |
   | `ERROR <why>` | 2 | bad id, no card, no registry card, no `path:` or `dev-branch:`, a `kind:` that is neither `build` nor `reply`, a `project:` that is neither the family nor `<family>~<N>`, a parent that is no git working tree, a `--tip` that does not resolve, or no tip ref at all |

   Every lane ends at one tip, chosen one way: the remote-tracking ref at or ahead of the local branch, the local when strictly ahead (the self-repo, whose `main` routinely leads `origin`), whichever of the two exists when only one does (no `origin`, or no local branch yet). A detached worktree never moves on its own — that is why a reused lane is reset at all — and `--detach` is required throughout, a worktree being unable to check out a branch the base copy holds (docs/incidents/2026-09-02-stale-clone-tip.md). Registry defaults: `clone-seed: .dev.vars .env .env.local`, `install: npm install`, `none` on either meaning the lane gets neither. Any failure is reported before dispatch, never left to the worker — and a creation whose seed or install fails takes its own worktree back out, so a failed `npm install` cannot leave a half-built lane the next run would refuse as a leftover.

   **`row-needed: <clone-id> <path> write|rewrite`** is all the script leaves you, writing no registry card itself: the `## Clones` row, under `card-<slug>` (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Card lock), committed as `<slug>: clone <clone-id> created`. A card lacking `## Clones` gets the heading and its `| clone-id | path | active-task | pane |` header row in the same locked edit as its first row, never in place of another section. `rewrite` says the row was there and its path was not: pruned and rebuilt, so the row is corrected rather than added.

   **Reply target** (`DISPATCH reply`) — the same call and the same stops, preparing a throwaway worktree at the preflight's `path:` line, `<parent-path>-reply-T-NNNN`, whose `lane:` is the id, `reply-T-NNNN`: no `## Clones` row, no lock, no install — a reader that needs the test suite installs in its own lane, a local write the worktree discards with everything else — while `clone-seed:` applies as for a clone. Same tip, same reason: a reader answering about the self-repo from `origin/main` reads a tip that local `main` is routinely ahead of. For a *review* the lane belongs at the PR head — `gh pr view <n> --json headRefName -q .headRefName`, then `--tip origin/<that>`. The heads snapshot the reply ladder diffs against (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Reply workers) stays yours, taken in the same breath, before the worker exists:

   ```bash
   git -C <parent-path> ls-remote --heads origin | sort > ledger/attachments/T-NNNN-heads.txt
   ```

1. **Pane** — registry `pane:` not `none` → verify it is alive and reusable (R7: no agent, shell idle), else spawn one (R2, label `w-<slug>`) and write it to the registry card.
2. **Launch** — adapter R3 with `<model>/<effort>` read from `.shepherd/instance.env` (`SHEPHERD_TIER_S`, `SHEPHERD_TIER_STANDARD`, `SHEPHERD_TIER_HEAVY`) by the card's `size:` and `tier:`, and `CLAUDE_CODE_SUBAGENT_MODEL` the same alias so subagents follow the worker (R3 holds the line and the why); `shepherd-status` is already in reach as a bare command through the plugin's `bin/`, and `-n worker-T-NNNN` lets one `ListAgents` tell workers from shepherds ([CLI reference](https://code.claude.com/docs/en/cli-reference), read 2026-08-28). **Poll `pane get` until the agent is both detected and registered, then wait, then prompt** — R3 holds the loop and the numbers: `pane run` returns before herdr has seen the agent, so a wait or a kickoff issued straight after fails `agent_not_found` at once (w12:pD–pH, 2026-09-02). The 45 s idle wait times out → read the pane (R6), diagnose, fix or escalate; the poll itself running out is a launch that never started, read before you prompt; `--permission-mode auto` rejected → relaunch without it and flag it before further dispatches. **A reply card launches through R3's reply line**: `cd` into the lane, `SHEPHERD_WORKER_KIND=reply` in the env, `--disallowedTools Edit Write NotebookEdit` and `--settings $(shepherd-paths hooks/reply-permissions.json)` — the three layers R3 names, with why none is a boundary; model and effort from `instance.env` exactly as a build's, the budget from the card. A project whose deploy verb is none the deny file spells (its registry `stack:` line or `## Gotchas` name it) gets one more bare-name rule on the line, `--disallowedTools Edit Write NotebookEdit 'Bash(<verb> *)'`.

   **Check the output style the worker will start with**, against the directory it launches in — the preflight's `path:` line, which is the lane for a clone or a reply card, not the registry `path:`. The no-argument form resolves only the operator's user-level style, and the check reads every `.claude/output-styles/` between that directory and the repository root, so the base checkout can resolve a different style than the lane:

   ```bash
   shepherd-output-style <the preflight's path:>
   ```

   `style: DEGRADED` names the file and its one-line repair: Log it on the card and tell the operator, and **dispatch anyway** — the setting is read once at session start, so no repair reaches this worker, and holding the card would cost the work without buying the fix (wake step 1's pattern; docs/incidents/2026-09-06-launch-drift.md).

3. **Kickoff** — adapter R4: `You are a shepherd worker. Read <instance-root>/ledger/tasks/T-NNNN.md and execute its Brief exactly.` Kickoff and confirmation are one call, `herdr agent prompt <pane> "<kickoff>" --wait --until working --timeout 15000` (foreground).
4. **Record** — overwrite the `claiming-<shepherd-id>-T-NNNN` placeholder with the real pane id, backfill `session:`, Log it, one commit (no lock):

   ```bash
   shepherd-card set T-NNNN pane <pane-id> session <agent_session> --log "briefed pane <pane-id>, <model>/<effort>, launched <HH:MM>"
   ```

   **A reply card's `briefed` line carries the heads snapshot** — the count, a digest and the file, so monitor's `## A reply card` can say which ref appeared, not only that one did — and the file rides its own commit:

   ```bash
   shepherd-card set T-NNNN pane <pane-id> session <agent_session> --log "briefed pane <pane-id>, <model>/<effort>, launched <HH:MM>; heads $(wc -l < ledger/attachments/T-NNNN-heads.txt) refs sha256 $(sha256sum ledger/attachments/T-NNNN-heads.txt | cut -c1-12) ledger/attachments/T-NNNN-heads.txt"
   shepherd-commit "T-NNNN: heads snapshot" ledger/attachments/T-NNNN-heads.txt
   ```

   Registry: `active-task: T-NNNN` (or the Clones row's) under `card-<slug>` (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Card lock), committed as `<slug>: active-task T-NNNN`. A reply card writes no registry field: it holds no working copy the registry tracks.

   **A Linear-born card** (`linear-session:` not `none`) **whose reader was not already told the work began** tells them here, once: the kickoff just confirmed `working`, and the later `briefed → working` state edit is bookkeeping the reader never needs. The drain marks every first word that said the work was not starting yet — *in line behind N*, or awaiting the operator's go — with ` — in line` on its Log line, so the marker is the gate (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice rule 4):

   ```bash
   grep -q "linear: thought posted to .* — in line" ledger/tasks/T-NNNN.md && \
     shepherd-inbox activity <linear-session> thought "<started, in the reader's words>"
   ```

   No marker means the first word said *on it* — usually right, because dispatch follows the drain in the same wake. When it did not, and this card is going out a wake or more later, that *on it* was wrong and the reader has been waiting since: post the started thought anyway. Either way, Logged `linear: thought posted to <session>` — the shape the drain's skip check reads, so a re-served event is not told twice; a card that posted nothing here Logs nothing.
5. **Arm the watchers** — `shepherd-watch arm T-NNNN` as **one background Bash task** (adapter R5); its exit is your wake → monitor with its first stdout line. Log `watchers armed`.
6. **Commit** — already done: the preflight committed the claim, step 4 the pane; `git log --oneline -2 -- ledger/tasks/T-NNNN.md` shows both.

   **Anything failed after the preflight claimed the slot → undo the claim before you stop:**

   ```bash
   shepherd-preflight undo T-NNNN
   ```

   The ladder, in order: `state: queued`, `pane: none` and the **original `project:`** if precondition 5 relocated it; `dispatch.lock` released if held; the project lock released (a reply claim held none, and the detail line says so); `T-NNNN: briefed → queued` committed. A reply lane step 0 already created has run nothing; leave it and report its path — removal is retro's `## Reply close-out`, and step 0 refuses to reuse the path meanwhile — and delete its heads file. Then report; left as is, the claim burns a slot, the lock strands the working copy, a phantom lane misdirects the next dispatch.

Never send the Brief through the pane, only the one-line kickoff: the card file is the contract.
