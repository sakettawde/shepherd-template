---
description: A card verified done, or declared failed or abandoned — close it out: learnings, downstream proposals, metrics, the lock, the operator, the next queued card. Weekly mode consolidates memory and audits decisions.
---

# retro

## Per-task close-out (precondition: monitor verified done, or the verdict is failed/abandoned)

1. **Metrics** — `shepherd-card-tokens T-NNNN` prints the card's `tokens` fragment from its worker transcripts; paste it onto the line:

   ```bash
   shepherd-card log T-NNNN "metrics: duration <wall-clock>, wakes <n>, decisions <n>, retries <n>, tier <t>, tokens <in>/<out> <model>"
   ```

   `tokens` is billed input (fresh + cache write + cache read) over output, deduped by message id — a transcript repeats one message's usage once per content block, so a hand count overreads by about 2.6x (T-0245). No transcript survives → the script says `tokens none`; write that, never a guess. The script is also the reader the field has: `shepherd-card-tokens T-A T-B ...` puts cards side by side, which is what the S-tier ladder question needs (F-20, `docs/reports/2026-09-07-prompt-audit.md`).
2. **Learnings** — what the task revealed:
   - Project facts → the project's auto-memory at its registry card's `memory-dir:`, never a slug guess (onboard step 5); a card that lacks the field → resolve it (the directory a session in the base checkout reports, or `ls -d ~/.claude/projects/*/memory`) and write `memory-dir:` under `card-<slug>` first. Then `## Gotchas`.
   - Every memory file you write carries `modified: <today, ISO date>` and `source: T-NNNN` under `metadata:` — Claude Code stamps `modified` only on its own writes and never adds `source` (code.claude.com/docs/en/memory, read 2026-09-06) — `source:` is what the weekly audit traces.
   - Locks: a one-fact file needs none; the shepherd `MEMORY.md` index takes `card-_memory`, re-read inside, never committed; registry edits take `card-<slug>`, committed inside (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Card lock).
   - **Prune while banking**: a learning that supersedes a gotcha, note or fact rewrites or deletes the old entry — a stale note poisons every future Brief.
   - Repo-specific recurring behaviour → a tiny S task folds it into that repo's CLAUDE.md, so workers inherit it and shepherd stays thin. Cross-project lessons → the card Log, where weekly step 3 reads them.
   - **The step ends with one Log line, always:** `downstream: T-NNNN` when a rule was carded for the project's CLAUDE.md, or `downstream: none — <reason>` (a `project: shepherd` card: `downstream: none — self-repo; a framework rule goes through weekly step 3's proposals`). The fold card is an S, `queued`, docs-only, its Brief carrying the rule, the why, and CLAUDE.md as the only file in scope. With neither line written the step is not finished: the fold pattern was law for 212 cards and produced zero folds (docs/incidents/2026-09-02-introspection-measures.md).
3. **Records** — registry `## History` one-liner (date, task, outcome, key fact) under `card-<slug>`; backfill `Outcome:` on this task's entries in `decisions/YYYY-MM-<your-shepherd-id>.md`.
4. **Notify** — adapter R8 toast: done `--sound done`, failed `--sound request`, plus one line to the operator. A real `linear-session:` also gets its answer in Linear, once, guarded on the Log: the close-out `response` of `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Linear voice — three lines by rule 5, rule 6's footnote below them — for `done`, `failed` and `abandoned` alike. The links go on the session first, because a `response` completes it and Linear does not say whether `externalUrls` still update afterwards (linear.app/developers/agent-interaction, read 2026-09-07): `Branch` from the remote, where the branch reached it; `PR` where the project uses one (`gh pr view <branch> --json url`); `Preview` only when the registry card's `preview:` names a mechanism and verification produced the URL — the field absent or `none`, no `Preview` label, and the body says where the change now lives instead ("now merged to dev", "now live on uat", "now on branch …"; Saket, 2026-09-07). Nothing linkable → skip `urls`; the body's where-it-lives line carries it.

   ```bash
   grep -q "linear: response posted" ledger/tasks/T-NNNN.md || {
     shepherd-inbox urls <linear-session> [Branch=<url>] [PR=<url>] [Preview=<url>]
     shepherd-inbox activity <linear-session> response "<line 1: what changed; line 2: where to see it; line 3: what happens next; last line: — shepherd-<id> · T-NNNN>"
     shepherd-inbox log answered <linear-event> now
   }
   ```

   Log it as `HH:MM linear: response posted to <session>`. The posting completes the Linear session: once, at close-out — a dropped task still owes its requester an answer. The `answered` line is the event's second `ledger/inbox.log` line, the answer clock's stop (`${CLAUDE_PLUGIN_ROOT}/docs/specs/2026-09-07-linear-conversation-design.md` §7), and rides step 6's transition commit through `--also ledger/inbox.log`. Never ack here; the drain did.
5. **Worker pane** — retire it through adapter R9's safe-close guards, then `pane close`. Never `/exit` first — `pane run` would submit a draft; drafts never block retirement (Saket, 2026-07-24). A failed guard → leave the pane, log which, retry later.
6. **Release** — registry `active-task: none` and `pane: none` (or the Clones row's fields) under `card-<slug>` (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Card lock), committed as `<slug>: T-NNNN closed`; then the card:

   ```bash
   shepherd-card transition T-NNNN done|failed|abandoned --also 'ledger/status/T-NNNN*.jsonl' --also ledger/inbox.log
   ```

   Two commits; the status JSONL rides the transition as evidence ① (the manual §2 rule 1) that nothing else commits, and step 4's `answered` line beside it — a card with no Linear session left the file untouched, and an unchanged path adds nothing. Then release the project lock, on a failure too, or the working copy is stranded:

   ```bash
   shepherd-lock release "project-<clone-id>" "$SHEPHERD_ID"
   ```

   **The worktree stays.** A clone's — a reply lane is the one exception (§ Reply close-out below). A clone's row is cleared, not deleted (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Lanes); `git worktree remove` runs only on the operator's word, since a worktree may hold uncommitted work (`${CLAUDE_PLUGIN_ROOT}/docs/specs/2026-08-18-multi-shepherd-design.md` §7); dispatch step 0 handles a stale or dirty one. Two lanes closing together land one branch at a time, in completion order.
7. **Context check, then next** — `shepherd-rollover decide` first (the manual §8): `rollover` → adapter R10 now; session start dispatches the next card. Otherwise the oldest `queued` card for the **project family** (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Lanes): yours → dispatch, cap permitting; another instance's → `shepherd-lock live <owner-id>` and the tri-state in `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Ownership and handoff — live → `SendMessage` by shepherd id (once `ListAgents` shows it) and a Log line; gone → report, awaiting reassignment; unresolved, or the id absent from `ListAgents` → send anyway and report. Never take it: a peer checks its queue only at session start.

**Three verdicts close a card, and none is retro's to pick.** `done` is monitor's four-source verification; `failed` is monitor's too (the retry ceiling, or an approach gone sideways), so a cancelled task is never a failed one and a verified done is never downgraded here; `abandoned` is triage §5's cancel.

Failed tasks: the same flow, plus the failure reason to `## Gotchas` as a guardrail, and any retry as a **new** heavy-tier task whose Brief carries `### Prior attempts` (tried, failed, why) and, after an over-scope or dead end, a steer to another angle. Never clean-slate a retry.

Abandoned tasks: the same flow minus the guardrail, the retry and the toast — nothing failed. The Log carries the operator's reason in his words; a live worker's `## Handoff` (harvested on the way in, triage §5) stays for the next card on that ground; one line in chat.

## Reply close-out (`kind: reply`)

A reply card runs the seven steps with these readings; `${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Reply workers holds the invariants, the budget rule and the re-brief's shape. The lane is `<parent-path>-reply-T-NNNN`; the session, event and author ids are on the card. Steps 2, 3 and 5 as written — what a reader found is a project fact like any other, and the `downstream:` line is still owed.

1. **Metrics** — the same line plus the reply's length, `… tokens <in>/<out> <model>, words <n>`, `words` read from the `event: reply` record (`grep '"event": "reply"' ledger/status/T-NNNN.jsonl | tail -1 | grep -oE '"words": [0-9]+'`), so the weekly read sees how replies sit against the 150.
4. **Notify** — the toast as written. A real `linear-session:` gets `## Reply` **verbatim** as its answer — the section as `shepherd-reply` left it, nothing rewritten, the Next step's options staying text (§ Reply workers says why) — with rule 6's footnote as its last line. `urls` first, one pair per PR and branch the reply names — the PR's URL is what the ladder's `gh pr view` printed, a branch's is `$(cd <lane-path> && gh repo view --json url -q .url)/tree/<branch>` (an ssh origin has no https form to paste); nothing named → skip `urls`. Logged `linear: response posted to <session>` as written:

   ```bash
   grep -q "linear: response posted" ledger/tasks/T-NNNN.md || {
     body=$(sed -n '/^## Reply$/,$p' ledger/tasks/T-NNNN.md | sed '1d')   # ## Reply is the card's last section
     shepherd-inbox urls <linear-session> [PR=<url>] [Branch=<url>]
     shepherd-inbox activity <linear-session> response "$body"$'\n'"— shepherd-<id> · T-NNNN"
     shepherd-inbox log answered <linear-event> now
   }
   ```

   A **failed** reply gets the honest `response` — what could not be answered, from the ladder's fact or the worker's final message — and its `answered` line, **unless** a re-brief is carded (below): then a `thought` saying the full question ran out of time and a narrower reading is on it, no `answered` line, and the session stays open for the retry's `response`.
6. **Release** — the transition as written (`--also` the status file and `ledger/inbox.log`); **no lock**: none was taken, so `shepherd-lock release` is skipped, not run against nothing. Then the lane — the one worktree retro removes without the operator's word, because its contract is that nothing in it is kept. Read the porcelain first, Log what is discarded, and only then `--force`:

   ```bash
   git -C <lane-path> status --porcelain | head -5
   git -C <parent-path> worktree remove <lane-path>            # a clean lane goes; a dirty one refuses
   shepherd-card log T-NNNN "lane discarded: <n> lines — <the first>"
   git -C <parent-path> worktree remove --force <lane-path>    # after the Log line, never before it
   ```

   The heads file stays in `ledger/attachments/` as the record of what the ladder compared against. No registry edit: a reply card set no `active-task`.
7. **Next** — as written, with one difference: closing a reply frees a slot, not a lane, so no project family is unblocked — the oldest `queued` card of yours anywhere, cap permitting.

**A failed reply's retry** is § Reply workers' re-brief, carded here: its `### Prior attempts` takes the first attempt's final message from the pane (R6) or the transcript the status file's `stop` record names, and the fork is step 4's — a reply failed on the lying row twice, or on a question no budget answers, is not re-briefed and gets the honest `response`; a re-brief gets the `thought`. `## Gotchas` gets the guardrail as written when the failure taught one.

## Weekly mode (on the operator's word, or scheduled later)

1. **Memory consolidation** — each active project's auto-memory (`memory-dir:`) plus shepherd's own: merge duplicates, then a **provenance review, not an auto-delete** — every file whose `modified:` is older than 30 days and that no later card or decision names (grep the name stem across `ledger/tasks/T-*.md` and `decisions/YYYY-MM*.md`, only cards with a later `created:` and decision months from the stamp on) gets one verdict, **delete** (superseded, contradicted, referent gone) or **restamp** (`modified:` today, `source: weekly-retro-<date>`); age is the trigger for the look, never the reason for the delete. Then rewrite the indexes to one line per fact (shepherd's under `card-_memory`, re-read inside, never committed) and prune superseded `## Gotchas` and `## Context notes` entries; the sections stay.
2. **Decision audit** — the month's decisions across every instance (`decisions/YYYY-MM*.md`) with outcomes; flag rework, and a pattern of bad approvals raises the second-model question. Start with `shepherd-metrics week`.
3. **Improvement proposals** — from the recurring cross-project lessons the card Logs carry: skill and CLAUDE.md diffs via superpowers:writing-skills, checked against `${CLAUDE_PLUGIN_ROOT}/docs/writing-for-agents.md`, on a branch for the operator's review; never self-adopt. Capture failures as guardrails.
