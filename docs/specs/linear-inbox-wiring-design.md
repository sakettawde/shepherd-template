# T-0212 — shepherd wiring for the Linear inbox

Design, 2026-09-02. Approved in chat before implementation (watcher window 3600 s;
elicitation on escalation; ack at drain time).

A companion task built the Worker side (the shepherd-inbox Worker), which holds the Linear
credentials and the whole vendor contract. This document covers only the shepherd side: how an
instance learns there is work, how that work enters the existing loop, and how the answer gets
back.

## 1. What exists already

- A deployed Worker (the shepherd-inbox Worker), authenticated with one bearer token, exposing
  `GET /inbox/pending`, `GET /inbox`, `POST /inbox/:id/ack`, `POST /sessions/:id/activity`,
  `POST /heartbeat` and an unauthenticated `GET /health` (shepherd-inbox `README.md`, read
  2026-09-02).
- `~/.config/shepherd/inbox.env` (mode 0600, outside every repo) carrying `INBOX_URL` and
  `INBOX_TOKEN`.
- The loop the events must enter: **triage → dispatch → monitor → retro**, and the watcher
  discipline in adapter R5 (bare background command, exit 0 = work, 124 = window elapsed).

## 2. The three Linear facts the design rests on

Read live at https://linear.app/developers/agent-interaction and
https://linear.app/developers/agent-best-practices on 2026-09-02:

1. **`response` completes the session.** It "indicates work has been completed or a final
   result is available" and transitions the session to `complete`. It is therefore the *last*
   thing shepherd ever posts about a piece of work, never an acknowledgement.
2. **`elicitation` is the only type that yields `awaitingInput`.** It "requests clarification
   or confirmation from the user" and pauses the agent until the user replies. That reply
   arrives as a `prompted` webhook with the text in `agentActivity.body`.
3. **A session goes `stale` after 30 idle minutes and any later activity revives it.** So a
   task that takes hours may leave its session stale in the UI; the closing `response` brings
   it back and completes it. No keep-alive posting is needed, and none is built.

`thought` is an internal note that communicates nothing to the user directly but keeps the
session `active` — the right shape for "I have carded this".

## 3. `scripts/inbox.sh`

One script is the only place the Worker contract lives on the shepherd side, exactly as
`lock.sh` is the only place the lock-file format lives.

```
inbox.sh owner                 # is this instance the one this inbox serves?
inbox.sh pending               # -> the pending count on stdout
inbox.sh list                  # -> the pending events as JSON
inbox.sh ack <eventId>
inbox.sh activity <sessionId> <type> <body>
inbox.sh heartbeat
inbox.sh watch <seconds>       # the background watcher
```

**Config.** `INBOX_URL` and `INBOX_TOKEN` are read from `$SHEPHERD_INBOX_ENV`, defaulting to
`~/.config/shepherd/inbox.env`. The override exists so the tests can point the script at a stub
without touching the operator's file. No token ever reaches a repo, a card, an argument list or
an error message.

**Exit codes** are the interface, because a watcher's exit code is all the caller sees:

| code | meaning | what the caller does |
|---|---|---|
| 0 | success; for `watch`, there is work | drain the inbox |
| 124 | `watch` only: the window elapsed with nothing pending | re-arm, nothing else |
| 3 | not configured, or this inbox belongs to another instance | do not arm; say so once |
| 1 | hard error — 401, malformed config, a 4xx that will not fix itself | report; do not re-arm |

`3` is deliberately not `1`. An instance with no `inbox.env` is the normal case for every
shepherd but this one, and a normal case must not read as a failure at every wake.

**`owner`** asks `GET /health` and compares its `shepherd_id` to `$SHEPHERD_ID`. The Worker
already knows which single shepherd it serves, so ownership needs no second source of truth and
no new config key. This is the seam where multi-instance routing will be built (§8).

**`watch <seconds>`** polls `/inbox/pending` every 60 s and exits 0 the moment the count is
above zero. Every fifth poll — about every five minutes — it posts `/heartbeat`. That is the
reason the heartbeat lives in the watcher rather than in the wake handlers: the Worker's
canned acknowledgement says how long ago shepherd was last online, and a heartbeat posted only
at model wakes would make that text wrong for hours at a time. A shell poll costs nothing.
Transient failures (curl exit, 5xx) are retried; a 401 or a malformed config exits 1
immediately, because those cannot fix themselves and a watcher that can only spin is worse
than no watcher (adapter R5).

The window is **3600 s**, matching the heavy-tier heartbeat. Its only job is to bound an
invisibly dead watcher; the cost is one no-op wake an hour whose whole handler is "re-arm".

## 4. Drain: an inbox event is an incoming message

The drain lives in **monitor**, which is already the handler for "a background watcher exited".
A new `## Inbox drain` section, entered when the watcher that fired is the inbox watcher.

1. `scripts/inbox.sh list` — every pending event, oldest first.
2. For each event, in order, build the incoming message from the event's `issue.identifier`,
   `issue.title`, and `body` (a `prompted` or `comment_reply`) or `prompt_context` (a
   `created`), then run it through **triage** exactly as a message typed in chat. Nothing about
   triage changes except that it learns to record the source.
3. Post the outcome back through the Worker:

   | triage outcome | activity | resulting session state |
   |---|---|---|
   | answer, or context ingested | `response` | complete |
   | clarifying question | `elicitation` | awaitingInput |
   | task carded (dispatched or queued) | `thought` naming `T-NNNN` | active; retro completes it |
   | refused — project not onboarded | `response` carrying the refusal and the onboarding offer | complete |
   | amendment to a live card | `thought`; the amendment routes through triage §5 | active |

4. **Ack the event** — always, once the posting landed. Pending is defined by `handled_at`, and
   only the ack sets it (shepherd-inbox README, "The cursor is not the state"). An event left
   unacked is re-served on the next poll, so a drain that defers its ack turns the watcher into
   a hot loop. This is why retro does not ack: by the time retro runs, the event was acked hours
   ago and only the `response` is still owed.
5. Re-arm the inbox watcher.

A `prompted` event whose `session_id` matches the `linear-session:` of a card that is briefed,
working or blocked is the operator talking to a task in flight — triage §5's amendment path,
which already routes a live card's edits through monitor.

## 5. The card carries the session

`templates/task-card.md` gains two optional fields under `created:`:

```
linear-session: <agent session id | none>
linear-event: <the inbox event id that created this card | none>
```

Triage sets them when the source is a Linear event; every other card carries `none` or omits
them. `linear-session:` is what lets retro answer in the thread the work came from, hours or
days later, in a fresh context, with no memory of the drain that created the card.

## 6. Retro closes the session

Retro step 4 (Notify) gains one clause: a card carrying a real `linear-session:` also gets

```
scripts/inbox.sh activity <session> response "<the same one-line outcome the operator gets in chat>"
```

and a Log line recording it. That posting is what moves the Linear session to `complete`, so it
happens once, at close-out, for done and for failed alike — a task that failed still owes the
person who asked an answer.

## 7. Escalation answers can come from Linear

Monitor's **blocked** row gains one clause: when the card carries a `linear-session:`, the
escalation is also posted as an `elicitation`. The session moves to `awaitingInput`, the
operator sees the question on the issue, and the reply arrives as a `prompted` event that the
drain routes straight back to the card. The toast stays — Linear is an additional surface, not
a replacement.

## 8. What is deliberately not built

- **Multi-instance routing.** One Worker serves one `SHEPHERD_ID`. `inbox.sh owner` reads that
  from `/health`, so a second instance on the same box arms no watcher and races nothing. The
  seam is Worker-side: a per-shepherd inbox partition, not a shepherd-side change.
- **Auto-execution.** Every event goes through triage. Nothing dispatches a worker without the
  same gates a chat message passes.
- **Keep-alive activity posting.** Sessions may go stale; §2.3 says that is recoverable and
  costs nothing.
- **A new skill.** The intake reuses triage, the wake handler is monitor, the arming is wake.
  A fifth skill would be a fifth place to keep in sync.

## 9. Tests and verification

- `scripts/tests/test-inbox.sh` — the script against a stub HTTP server: each verb's request
  shape, the four exit codes, config precedence, 401 behaviour, that no token appears in any
  output, and that `watch` exits 0 on a pending count and 124 on an elapsed window.
- `scripts/tests/test-docs.sh` — assertions that `linear-session:` has one spelling and reaches
  the template, triage, monitor and retro, and that wake step 8 and monitor's re-arm invariant
  both name the inbox watcher. The manual is the product here; a surface that silently forgets
  the field is the failure mode this file exists to catch.
- Live: `inbox.sh pending` and `inbox.sh heartbeat` against the deployed Worker, then one real
  agent mention driven end to end — watcher fires, triage answers, `response` visible in
  Linear, event acked, `pending` back to 0.

## 10. Landing

Everything except the instance's own `CLAUDE.md` §0 line is framework: it is made in the
`shepherd-template` checkout on `task/T-0212-linear-inbox-wiring`, PR'd to its main, and
cherry-picked into the instance (FRAMEWORK.md). Ledger state in the instance commits only
through `scripts/ledger-commit.sh`, on `main`.

## Sources

- shepherd-inbox `README.md` (companion repo), read 2026-09-02 — endpoint table, event shape,
  "the cursor is not the state".
- https://linear.app/developers/agent-interaction, read 2026-09-02 — activity types and the
  session states each produces.
- https://linear.app/developers/agent-best-practices, read 2026-09-02 — 10-second first
  activity, 30-minute stale window, which type ends the work.
- `.claude/skills/herdr-adapter/references/v0.8.2.md` R5, read 2026-09-02 — watcher shape and
  the rule against a watcher that can only time out.
