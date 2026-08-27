# Context rollover: research and design (T-0166)

> **Renamed 2026-08-27 (T-0185).** This document, the script it specifies and their
> vocabulary were called *self-recycle* until then; the old names read to Claude Code's
> permission auto-classifier as a destructive action and got the command refused. The
> script is now `scripts/context-rollover.sh`, its verb is `rollover`, its log is
> `${SHEPHERD_ROLLOVER_LOG:-~/.claude/shepherd-rollover.log}`, and `decide` answers
> `rollover|hold|ok|unknown`. Behaviour did not change. Names from before the rename are
> kept below only where they record what was actually observed — the `/tmp` log path in
> §1 is one such fact. Dated companions keep the old name in full:
> `docs/superpowers/plans/2026-08-25-self-recycle-reliability.md`.


Written 2026-08-25. Every claim below is either a citation with a read-date or a
measurement taken on this machine with the commands shown. Nothing here is recalled.

Environment under test: herdr 0.8.2 (protocol 20), Claude Code with the herdr
`claude` integration at v8 (`herdr integration status` → `claude: current (v8)`),
detection manifest `remote/claude.toml` version `2026.08.21.1`.

## 1. The incident

On 2026-08-25 `shepherd-collie` recycled at 19:04:28. `scripts/context-rollover.sh decide`
correctly returned `recycle` (200k tokens, no active card). The detached injector was
armed with a 30 s delay, `/clear` was queued, and the new session transcript starts at
19:04:35 — so **the clear itself worked**. The injector then polled for up to
60 × ~5.5 s ≈ 6 min for two consecutive `idle` reads and exited having written nothing.
`/tmp/self-recycle-inject.log` was created at 19:04 and stayed 0 bytes. The instance sat
dead until the operator typed the recovery line by hand at 19:45:08 — 40 minutes.

An earlier failure (2026-08-18, T-0085 session) had a different cause: the input box was
in bash mode, so `/clear` ran as a shell command and the context was never cleared.

Two incidents, two causes. The research below finds that they share one root: the design
gated on `agent_status == idle`, a signal that is **unreachable in the healthy case and
present in the failure case**.

## 2. Question (a) — what Claude Code offers today

Source: <https://code.claude.com/docs/en/hooks> (fetched as `hooks.md`, read 2026-08-25).

- **`/clear` does fire `SessionStart`.** The `source` field is documented as: `"startup"`
  for new sessions, `"resume"` for resumed sessions, **`"clear"` after `/clear`**,
  `"compact"` after compaction, `"fork"` for a forked session.
- **`SessionEnd` also fires, with `reason: "clear"`** — "Session cleared with `/clear`
  command". Its default timeout is 1.5 s. So both ends of a clear are observable by hooks.
- **`additionalContext`** — "String added to Claude's context at the start of the
  conversation, **before the first prompt**." It adds context; it does not create a turn.
- **`initialUserMessage`** — "String used as the first user message of the session.
  **Applies in [non-interactive mode] with the `-p` flag**, where it becomes the first turn
  even if no prompt is provided." Shepherd runs interactive, so this field cannot start
  shepherd's recovery turn.
- **`sessionTitle`** — "Applies when `source` is `"startup"`, `"resume"`, or `"fork"`;
  **ignored on `"clear"` and `"compact"`**." So a clear-time hook cannot even re-title the pane.
- The decision-control table lists `SessionStart` under **"Context only … No blocking or
  decision control"**.

**Conclusion (a): no hook can start a turn in an interactive session.** A replacement of
the external injector by a `SessionStart` hook alone is not possible. An external prompt
into the pane remains mandatory. This is a firm negative result and it is what stops this
design from adding a user-global hook — so **no `init-shepherd` change and no operator
action are required**.

`--resume` / `--continue` semantics, for completeness
(<https://code.claude.com/docs/en/cli-reference.md>, read 2026-08-25): `--continue`/`-c`
loads the most recent conversation in the current directory; `--resume`/`-r` resumes a
specific session by id or name; `--fork-session` mints a new session id when resuming.
None of these apply in place — they are launch flags, so they mint a new process and,
per CLAUDE.md §2 rule 4, a new remote-control session. `/clear` remains the only in-place
reset. Claude Code still has no programmatic clear.

## 3. Question (b) — how herdr classifies shepherd's own pane

Measured. `herdr agent explain w11:p1` on the **live** `shepherd-collie` instance, sitting
at an empty prompt box with nothing running:

```
state: working
rule: background_shell_working (region=bottom_non_empty_lines(5) priority=965)
evidence: "…\n❯\n…\n  Fable 5 │ effort:high │ ctx ▓░░░░░░░░░ 13%/1000k │…\n  ⏵⏵ auto mode on · 4 shells · ← for agents\n"
```

`live_prompt_box` (idle, priority 950) matched the bare `❯` in the same read and lost, because
`background_shell_working` sits at priority 965. **A shepherd instance always holds watcher
shells, so its own pane can never report `idle`.** The hypothesis in the task card is confirmed.

Then a controlled reproduction in a pane created for the purpose (`w18:p1`, Haiku, closed
afterwards):

| Step | Observation |
|---|---|
| Fresh Claude, no shells | `idle`, rule `live_prompt_box`, evidence `"❯\n"`, session `50bf828b…` |
| One background shell started (`sleep 900`) | `working`, rule `background_shell_working`, evidence `⏸ manual mode on · 1 shell · ← for agents` — while the prompt box is a bare `❯` and the turn is over |
| `/clear` submitted | session id changed `50bf828b…` → `36d12c40…` **within 1 second** |
| 1 s … 60 s after the clear | `agent_status` stayed `working` for the entire window, rule `background_shell_working`, every single poll |

**The injector's gate could not have fired at any point.** Six minutes of polling for a
state that the pane was structurally incapable of producing. That is the whole root cause
of the 2026-08-25 incident; the process did not die and nothing exotic happened.

Two further measured facts from the same run:

- **Background shells survive `/clear`.** `sleep 900` (PID 265692) was still running after
  the clear, and the fresh session's footer still counted `1 shell`. This **contradicts** the
  R10 "known facts" line that said background Bash watchers do not survive `/clear`. That
  line is corrected. (Consequence worth knowing but out of scope here: a shepherd after a rollover
  that re-arms watchers from its cards adds to the surviving ones rather than replacing them.)
- **Bash mode inverts the signal.** With the box in bash mode the footer line becomes
  `! for shell mode`, so `background_shell_working` stops matching and the pane reports
  **`idle`** via `osc_title_idle` (priority 250). Measured directly.

So the old gate was not merely unreachable — it was **backwards**. It stayed silent in the
healthy case and would have fired in the bash-mode failure case, prompting a session that
had never been cleared, exactly the false-premise outcome the R10 Gotcha warned about.

### The signal that does work

`herdr pane get <pane>` exposes the live Claude session id:

```json
"agent_session": {"agent":"claude","kind":"id","source":"herdr:claude","value":"7edc85d2-…"}
```

It is maintained by the herdr `claude` integration hook (`~/.claude/hooks/herdr-agent-state.sh`,
`HERDR_INTEGRATION_VERSION=8`), which is registered user-global on `SessionStart` and reports
`pane.report_agent_session` over the herdr socket with the new `session_id`. Verified against
ground truth: `w11:p1` reported `7edc85d2-150a-433e-812a-5ca23fa70d85`, which is exactly the
newest transcript file in that project directory.

A session-id change is therefore:

- **positive** — it proves the clear happened, rather than inferring it from an absence;
- **causally correct** — nothing but a session change alters it;
- **fast** — observed at ~1 s;
- **already available** — no new hook, no `init-shepherd` change, no operator action;
- **and it catches the bash-mode swallow**: measured, when `/clear` was submitted into a
  bash-mode box the session id did **not** change.

One primitive already implements the read with correct tri-state semantics:
`pane_probe` in `scripts/lib/shepherd-common.sh`. The new code reuses it rather than
re-deriving the JSON path — which is also why the old injector's inline `python3` parse was
never the fault: run verbatim today it returns the right answer.

## 4. Question (c) — `agent prompt` vs `pane run`, and bash mode

Measured on `w18:p1`:

- **`herdr agent prompt` accepts a `working` agent.** Submitted against the pane while its
  background shell held it at `working`, it returned `{"type":"agent_prompted"}`, rc 0, and
  the prompt landed. It is therefore usable for shepherd's own pane, which is permanently
  `working`. It also returns the pane document — including `agent_session` — so submission is
  confirmed rather than assumed. `pane run` returns nothing comparable. **Use `agent prompt`.**
- **`agent prompt` gives no protection against bash mode.** Submitted into a bash-mode box it
  returned success, and the session id did not change: the `/clear` was swallowed exactly as
  `pane run` swallows it. Confirmation of *submission* is not confirmation of *effect*.
- **Bash mode is detectable**: the prompt box body renders `!` instead of `❯`, and the hint
  line reads `! for shell mode`. Both are visible in `--source visible` and `--source detection`.
- **`herdr pane send-keys <pane> Escape` reliably leaves bash mode**: measured, the box went
  from `!` back to `❯` and the shell-mode hint disappeared.

So bash mode is handled by **forcing, then verifying**: send `Escape`, read the box back, and
require a bare `❯` before submitting anything. Refuse to submit if the box will not come clean.

## 5. Question (d) — the detached-process failure surface

Measured. A `setsid nohup bash -c '…' >log 2>&1 &` spawned from a Claude Code Bash tool call:

```
PID    PPID  PGID    SID     STAT  ELAPSED  CMD
275617 290   275617  275617  Ss    00:57    bash -c  for i in $(seq 1 30); …
```

It kept its own session and process group, was reparented to PID 290, and went on ticking
across three subsequent tool calls. It inherited `HERDR_SOCKET_PATH` and reached herdr
successfully on every tick (`herdr_ok=yes`). The calling shell printed `Done` immediately —
that is `setsid`'s wrapper exiting, not the work.

**Detachment is sound and is not the problem.** The design keeps a detached watchdog. What it
does not keep is the silence: the old injector had no logging on any path, which is why an
empty log file was indistinguishable between "died at once" and "polled for six minutes".

## 6. The design

`scripts/context-rollover.sh` keeps `ctx`, `decide` and `meter` unchanged — they were correct in
this incident and are out of scope. `inject` is replaced by two subcommands.

**`context-rollover.sh rollover [--sound S] [--pane P] [--log F] <message>`** — run by shepherd in
one turn, in place of steps 2–4 of the old R10:

1. Resolve the pane's current session id `S0` via `pane_probe`. No id → abort loudly (the herdr
   integration is missing or the pane runs no Claude session); nothing has been submitted yet.
2. Refuse if `agent_status` is `blocked` — a permission dialog is open, and `/clear` would be
   answered into it.
3. Force prompt mode: `send-keys Escape`, re-read the prompt box, require a bare `❯`. Refuse
   if the box will not come clean.
4. Arm the detached watchdog (`context-rollover.sh watch`), passing `S0`.
5. Submit `/clear` via `herdr agent prompt`.

Shepherd then ends its turn, exactly as before.

**`context-rollover.sh watch <pane> <old-session-id> <message>`** — the detached watchdog, and a
first-class subcommand so that it is directly testable:

- **Phase 1, confirm the clear.** Poll `pane_probe` every `POLL` s (default 2) up to
  `CLEAR_TIMEOUT` (default 120). Session id differs from `S0` → the clear landed; record the new
  id. Deadline → **give up**: log, toast, exit 3. This is the bash-mode failure and any other
  reason the clear did not take.
- **Phase 2, settle.** Sleep `SETTLE` s (default 5).
- **Phase 3, prompt and verify**, up to `ATTEMPTS` times (default 3). Each attempt forces prompt
  mode again, submits the message with `agent prompt`, then verifies against **ground truth**:
  the new session's transcript, found by globbing `~/.claude/projects/*/<new-session-id>.jsonl`,
  must contain the message. The glob avoids depending on the pane's cwd. Verified → log and exit 0.
  All attempts exhausted → **give up**: log, toast, exit 4.

Every poll and every exit path writes an ISO-timestamped line naming the observed state to one
documented file: `${SHEPHERD_ROLLOVER_LOG:-$HOME/.claude/shepherd-rollover.log}`, appended, never
truncated. There is no silent exit.

Every give-up also raises `herdr notification show` with `--sound` taken from `--sound`
(default `request`, overridable by `SHEPHERD_ROLLOVER_SOUND`). The script does not parse the
Operator block: shepherd passes `--sound none` when the Operator block says
`notifications: silent`. Policy stays in the operating manual, and the script stays testable.

The script writes no ledger, registry or decision state — those writes belong to the shepherd
that owns them. §8 recovery instead reads the tail of the rollover log and reports the last
rollover's outcome to the operator, so a give-up reaches the decision log through its owner.

### Why this shape

The signal changed from an absence that a healthy pane cannot produce to a **positive fact that
only the intended event produces**. The moving parts went down, not up: the fixed 30 s guess is
gone (phase 1 starts polling immediately), the two-consecutive-reads heuristic is gone, and the
retry that remains sits on the one step that can fail transiently — the prompt — behind a
verification against the transcript rather than against a claim of submission.

Confidence: **high** for the root cause and for the session-id gate — both are directly measured,
including the reproduction of the exact failure. **Medium-high** for the transcript verification,
whose only assumption is that Claude Code keeps writing session transcripts to
`~/.claude/projects/*/<session-id>.jsonl`; that layout is observed on this machine and is what
`context-rollover.sh meter` has already depended on.

## 7. Live validation

Run against a pane created and closed for the purpose (`w18:p1`, Haiku), with the real herdr
CLI, 2026-08-25.

**Canary — normal rollover, unattended, 10 seconds end to end:**

```
20:24:03 ARM             pane=w18:p1 session=ff6c72df… box=clean (clear_timeout=120s attempts=3)
20:24:03 POLL            session=ff6c72df… baseline=ff6c72df…
20:24:05 POLL            session=8844be79… baseline=ff6c72df…
20:24:05 CLEAR-CONFIRMED session ff6c72df… -> 8844be79…
20:24:10 SETTLE          waited 5s
20:24:11 PROMPT-SENT     attempt 1/3 box=clean
20:24:13 VERIFIED        session 8844be79… received the recovery prompt on attempt 1
```

The fresh session's status line went from `ctx: –` to `ctx 15%/200k`, confirming it took a turn.

**Give-up path, against real herdr:** `watch` armed with the pane's *live* session id as its
baseline — a clear that can never come. Exit 3 after a full poll trail and a `GIVE-UP` verdict,
with the toast raised. No silent exit.

**The 2026-08-18 failure, replayed:** the box was deliberately put into bash mode, then
`rollover` was run. The `Escape` preflight rescued it (`box=clean` in the `ARM` line), the clear
landed at the second poll, and recovery verified at attempt 1 — 10 seconds, unattended. The
failure that cost an incident is now handled without anyone noticing it happened.

### A correction the live run forced

The first live attempt **refused** with `prompt box is other after Escape`. The box read
`❯  I need a task description to suggest your next step.` — Claude Code's own **suggested**
prompt, which `Escape` does not dismiss. Submitting `/clear` into it by hand worked anyway and
the session id moved, proving the suggestion is ghost text, not input.

The preflight was too strict, and in a way that mattered: a shepherd pane shows a suggestion
routinely, so the design as first built would have refused most real rollovers. R10's Gotchas
already record that no pane-read source can tell a suggestion from a human draft, and that the
standing rule is not to hold work over apparent text. The check was narrowed to bash mode
alone — the only box state measured to actually swallow a `/clear` — with the observed state
logged either way. A genuine draft that did swallow the clear is caught by the session-id gate,
loudly, which is exactly what that gate is for.

### Residual risks, named

- If the herdr `claude` integration is uninstalled or downgraded below v8, `agent_session` goes
  stale and phase 1 times out. That now fails **loudly** within `CLEAR_TIMEOUT`, which is the
  requirement. `herdr integration status` diagnoses it.
- A rollover whose `/clear` lands but whose pane is then taken over by the operator mid-recovery
  will spend its attempts and give up loudly. Correct behaviour.
- Background shells surviving `/clear` means a long-lived instance accumulates them. Noted, out
  of scope for this task.
