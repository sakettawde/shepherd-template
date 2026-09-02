#!/usr/bin/env bash
# The manual and the skills are the product here, so their invariants get
# assertions rather than promises. This file reads the repo in place: it takes
# no sandbox and writes nothing.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
ROOT=$(cd "$HERE/../.." && pwd)

echo "test-docs:"

# --- working-agreement: reaches every surface that has to know about it ------
# The field only works if the writer, both readers and the template agree. A
# surface that never learned the field silently goes back to the T-0084
# behaviour: a Brief pointing at a CLAUDE.md the worker cannot open.
for f in CLAUDE.md \
         templates/task-card.md \
         .claude/skills/onboard/SKILL.md \
         .claude/skills/triage/SKILL.md \
         .claude/skills/dispatch/SKILL.md; do
  assert_ok "working-agreement: is known to $f" grep -q 'working-agreement:' "$ROOT/$f"
done

# One spelling, everywhere. Every field is greped for by name, so an
# underscore or a stray capital reads as the field being absent.
tokens=$(grep -rhoiE 'working[-_]agreement:' \
           --include='*.md' --include='*.sh' "$ROOT" 2>/dev/null | sort -u)
assert_eq "one spelling of the field, everywhere" "$tokens" "working-agreement:"

# --- CLAUDE.md is the field's spec home -------------------------------------
assert_ok "CLAUDE.md documents the 'none' value" \
  grep -q '`none` when the repo has no CLAUDE.md' "$ROOT/CLAUDE.md"
# The ref guard is the part a reader is most likely to drop as redundant, and
# dropping it makes a never-fetched checkout report 'no working agreement'.
assert_ok "the check fetches before it reads" grep -q 'fetch origin --quiet' "$ROOT/CLAUDE.md"
assert_ok "the check verifies the ref before the path" \
  grep -q 'rev-parse --verify --quiet' "$ROOT/CLAUDE.md"
assert_ok "the check tests the path at the ref" grep -q 'cat-file -e' "$ROOT/CLAUDE.md"

# --- the inlined rules exist, and there are four of them --------------------
rules=$(sed -n '/^\*\*This repo has no CLAUDE.md/,/^>/p' "$ROOT/templates/task-card.md" \
          | grep -cE '^[0-9]+\. ')
assert_eq "the template inlines four standing rules" "$rules" "4"

# --- dispatch's preconditions stay numbered in sequence ---------------------
# Inserting a precondition renumbers the rest, and three lines in ## Steps
# point back at them by index.
nums=$(sed -n '/^## Preconditions/,/^## Steps/p' "$ROOT/.claude/skills/dispatch/SKILL.md" \
         | grep -oE '^[0-9]+\.' | tr -d '.')
expected=$(seq 1 "$(printf '%s\n' "$nums" | grep -c .)")
assert_eq "dispatch preconditions are numbered 1..N with no gaps" \
  "$(printf '%s\n' "$nums")" "$(printf '%s\n' "$expected")"

last=$(printf '%s\n' "$nums" | tail -1)
dangling=$(grep -oE '[Pp]recondition[s]? item [0-9]+|precondition [0-9]+' \
             "$ROOT/.claude/skills/dispatch/SKILL.md" \
           | grep -oE '[0-9]+' | awk -v n="$last" '$1 < 1 || $1 > n')
assert_eq "no Steps line points at a precondition that does not exist" "$dangling" ""

# --- the ledger checkout never leaves main (F5) -----------------------------
# The guard in ledger-commit.sh is the mechanism; these two sentences are the
# reason a reader needs before the refusal makes sense.
assert_ok "FRAMEWORK.md sends framework changes to a separate checkout" \
  grep -q 'separate `shepherd-template` checkout' "$ROOT/FRAMEWORK.md"
assert_ok "FRAMEWORK.md says the instance may never leave main" \
  grep -q 'may never leave `main`' "$ROOT/FRAMEWORK.md"

# --- one spelling for the self-repo slug ------------------------------------
# `shepherd (self)` matches neither the S5 greps nor the lock name, so cards
# spelled that way are invisible to dispatch and retro.
assert_ok "CLAUDE.md names the self-repo slug" \
  grep -q '`project: shepherd`' "$ROOT/CLAUDE.md"
assert_ok "CLAUDE.md retires the 'shepherd (self)' spelling" \
  grep -q 'spelling is retired' "$ROOT/CLAUDE.md"

# --- §6 states the guardrail's strength honestly ----------------------------
# The hook matches a shell command as a string, so quoting, variables, `eval`
# and wrapper scripts all get past it. A manual that calls destructive git
# "mechanically blocked" promises a boundary the hook does not provide, and a
# shepherd who believes it stops verifying — which is the one thing §2 rule 1
# exists to prevent. The hook's own header already says "speed bump"; §6 has to
# say the same thing, or the two disagree about the same mechanism.
assert_fail "CLAUDE.md does not call destructive git 'mechanically blocked'" \
  grep -q 'mechanically blocked' "$ROOT/CLAUDE.md"
assert_ok "the hook header frames itself as a speed bump" \
  grep -q 'speed bump' "$ROOT/hooks/worker-git-guardrail.sh"
assert_ok "CLAUDE.md uses the hook's own framing" \
  grep -q 'speed bump' "$ROOT/CLAUDE.md"
assert_ok "CLAUDE.md names the second layer that does not travel" \
  grep -q 'permissions.deny' "$ROOT/CLAUDE.md"

# --- parallelism metadata reaches its writer, its reader and the template ---
# `touch-areas:` is written by triage onto every card; `parallel-safety:` is
# triage's judgment and monitor's cue to re-run the DoD after a sibling merges.
# A surface that never learned a field leaves it either unfilled or unread, and
# an unread declaration is worse than no declaration: it reads as a check that
# happened.
for f in templates/task-card.md \
         .claude/skills/triage/SKILL.md; do
  assert_ok "touch-areas: is known to $f" grep -q 'touch-areas:' "$ROOT/$f"
done
for f in templates/task-card.md \
         .claude/skills/triage/SKILL.md \
         .claude/skills/monitor/SKILL.md; do
  assert_ok "parallel-safety: is known to $f" grep -q 'parallel-safety:' "$ROOT/$f"
done

# One spelling each, for the reason working-agreement: has one. Scoped to the
# framework surfaces rather than the whole tree: an instance's own task cards
# are its state, nobody rewrites them, and a Brief may well use these words in
# a sentence. The invariant that matters is that the writer, the readers and
# the template agree — not that the words never appear in prose.
FRAMEWORK_SURFACES=("$ROOT/templates" "$ROOT/.claude/skills" "$ROOT/scripts")

tokens=$(grep -rhoiE 'touch[-_]areas:' \
           --include='*.md' --include='*.sh' "${FRAMEWORK_SURFACES[@]}" 2>/dev/null | sort -u)
assert_eq "one spelling of touch-areas, everywhere" "$tokens" "touch-areas:"

tokens=$(grep -rhoiE 'parallel[-_]safe(ty)?:' \
           --include='*.md' --include='*.sh' "${FRAMEWORK_SURFACES[@]}" 2>/dev/null | sort -u)
assert_eq "one spelling of parallel-safety, everywhere" "$tokens" "parallel-safety:"

# --- the outcome path ends at an approved split, never at a plan ------------
# Both halves are load-bearing. Without the gate, triage cards an outcome from
# its own reading of it; without the behavioural boundary, the split becomes an
# implementation plan the orchestrator wrote for a worker that plans better.
TRIAGE="$ROOT/.claude/skills/triage/SKILL.md"
DECOMP="$ROOT/.claude/skills/triage/references/decomposition.md"
assert_file "the decomposition reference exists" "$DECOMP"
assert_ok "triage points at the decomposition reference" \
  grep -q 'references/decomposition.md' "$TRIAGE"
assert_ok "decomposition reserves no id before the operator answers" \
  grep -q 'reserve no id before' "$DECOMP"
assert_ok "decomposition holds the slice boundary at behaviour" \
  grep -q 'Behavioral, not procedural' "$DECOMP"

# --- intake covers compound messages and edits to existing cards ------------
assert_ok "triage classifies a message into one or more types" \
  grep -q 'one or more of five intake types' "$TRIAGE"
assert_ok "triage has an amend/cancel path" grep -q 'Amend or cancel' "$TRIAGE"
assert_ok "cancelling reaches the state the manual already defines" \
  grep -q 'state: abandoned' "$TRIAGE"

# --- an approval pause claims blocked, never working (T-0152) ---------------
# A pause that waits on shepherd input is the highest-value wake signal there
# is, and the status-file watcher greps only done|blocked|failed - so a worker
# that ends an approval pause `working` sits invisible until the heartbeat
# backstop (~30 min). The wording is the whole fix: the watchers already treat
# `blocked` as an instant wake. The canonical statement lives in the template,
# because the card is the only surface a worker reads.
CARD_TPL="$ROOT/templates/task-card.md"
proto=$(sed -n '/^### Status protocol/,/^## Log/p' "$CARD_TPL")
assert_ok "the template sorts the two by what happens next" \
  grep -q 'Pick by what happens next' <<<"$proto"
assert_ok "the template names approval as a blocked case" \
  grep -q 'design approval' <<<"$proto"
assert_ok "the template says blocked means shepherd input is needed" \
  grep -q 'shepherd input to continue' <<<"$proto"
assert_ok "the template says working means the worker continues alone" \
  grep -q 'continue on your own next turn' <<<"$proto"
# The why is what makes the rule survive a worker under pressure: without the
# cost, `working - waiting for approval` reads as a perfectly honest report.
assert_ok "the template states what the wrong choice costs" \
  grep -q 'heartbeat' <<<"$proto"

# One canonical statement, references elsewhere. Each of the three readers
# below states the rule in a sentence and points home, so no two surfaces can
# drift into disagreeing about the same sentinel.
assert_ok "CLAUDE.md carries the blocked-vs-working rule" \
  grep -q 'needs your input to continue' "$ROOT/CLAUDE.md"
assert_ok "CLAUDE.md names the template as the canonical wording" \
  grep -q 'canonical wording every Brief carries' "$ROOT/CLAUDE.md"
assert_ok "monitor reads claim blocked as the worker waiting on you" \
  grep -q 'waiting on you' "$ROOT/.claude/skills/monitor/SKILL.md"
assert_ok "monitor points at the rule's home" \
  grep -q 'CLAUDE.md §6 holds the rule' "$ROOT/.claude/skills/monitor/SKILL.md"
# onboard's own Status protocol block REPLACES the template's, so an
# onboarding worker never reads the canonical rule unless this block sends it
# there.
onboard_proto=$(sed -n '/^### Status protocol/,$p' \
                  "$ROOT/.claude/skills/onboard/SKILL.md")
assert_ok "onboard's status block points back at the canonical rule" \
  grep -q 'task-card.md' <<<"$onboard_proto"
assert_ok "onboard covers pauses its own two lines do not name" \
  grep -q 'any other pause' <<<"$onboard_proto"

# --- the wake skill carries §8's session-start procedure (T-0187) -----------
# §8 kept ten numbered steps inline, and every fresh session after a context
# rollover re-derived them from prose. The procedure now lives in one skill the
# recovery message invokes by name; §8 keeps the rules. Both halves are
# asserted, because either half alone is a recovery that skips something.
WAKE="$ROOT/.claude/skills/wake/SKILL.md"
assert_file "the wake skill exists" "$WAKE"
assert_ok "the wake skill declares its name" grep -q '^name: wake$' "$WAKE"
assert_ok "the wake skill front-loads its trigger" \
  grep -qi '^description:.*session start' "$WAKE"

# Ten steps, numbered 1..10 with no gaps. A dropped step is a sweep that never
# runs or a watcher that never re-arms, and nothing else in the system notices.
nums=$(grep -oE '^### [0-9]+\.' "$WAKE" | grep -oE '[0-9]+')
assert_eq "the wake skill carries ten steps, numbered 1..10" \
  "$(printf '%s\n' "$nums")" "$(seq 1 10)"

# Each step's actual command, named. A skill that describes a sweep without
# naming the script leaves the fresh session to guess the invocation.
for c in 'herdr --version' \
         'shepherd-identity.sh acquire' \
         'lock.sh sweep' \
         'reserve-task-id.sh sweep' \
         'lock.sh takeover' \
         'context-rollover.sh decide'; do
  assert_ok "the wake skill names \`$c\`" grep -qF "$c" "$WAKE"
done

# The rules stay in CLAUDE.md; the skill cites them rather than restating them.
assert_ok "the wake skill cites CLAUDE.md §8 as the rules home" \
  grep -q 'CLAUDE.md §8' "$WAKE"
# Thresholds have exactly one home (§8). A second copy drifts, and the copy a
# fresh session reads first is the one that decides whether it rolls over.
assert_fail "the wake skill does not restate the rollover thresholds" \
  grep -qE '200k|350k|60 ?%|85 ?%' "$WAKE"

assert_ok "CLAUDE.md §8 sends session start to the wake skill" \
  grep -q '`wake` skill' "$ROOT/CLAUDE.md"

# --- one recovery message, on every surface that quotes it ------------------
# The watchdog proves recovery by grepping the fresh session's transcript for
# this exact string (context-rollover.sh verify_prompt). A surface quoting a
# different one either reports a rollover that never recovered, or recovers a
# session that then does nothing.
# The prose surfaces quote it as a code span; the script carries it as the
# default. Both are matched literally — a bare `/wake` also matches the word
# "tasks/wakes" in R10's meter paragraph, which is not a quotation of anything.
assert_ok "the script carries the message as its default" \
  grep -qF 'ROLLOVER_MSG:-/wake' "$ROOT/scripts/context-rollover.sh"
assert_ok "the test pins the same message" \
  grep -qF 'MSG="/wake"' "$ROOT/scripts/tests/test-rollover.sh"
for f in CLAUDE.md \
         .claude/skills/herdr-adapter/references/v0.8.2.md \
         docs/specs/context-rollover-design.md; do
  assert_ok "the recovery message is \`/wake\` in $f" grep -qF '`/wake`' "$ROOT/$f"
done

# The prose it replaced is gone from every surface that INVOKES it. The spec
# may still quote it as history — that is the record of what was interrupted.
for f in scripts/context-rollover.sh \
         scripts/tests/test-rollover.sh \
         CLAUDE.md \
         .claude/skills/herdr-adapter/references/v0.8.2.md; do
  assert_fail "the long recovery prompt is gone from $f" \
    grep -qF 'Run session-start recovery per CLAUDE.md section 8' "$ROOT/$f"
done

# --- the spec records what actually interrupts a rollover -------------------
# Two attempts on 2026-08-27 died at the tool call and the cause was guessed at
# twice. The section is asserted so the next guess has to displace a written
# runbook rather than an absence.
# --- the foreground rollover call touches nothing (T-0187) ------------------
# Root cause of the 2026-08-27 stalls: the foreground sent `pane send-keys
# <own-pane> Escape` while running as the shepherd's own Bash tool call, Claude
# Code read the Escape as "interrupt the running tool", and the script died
# before it armed anything. The behaviour is asserted in test-rollover.sh; what
# is asserted here is that both surfaces a shepherd actually reads say so, so
# nobody reintroduces the shape from the prose.
R10=$(sed -n '/^## R10 /,/^## New in/p' "$ROOT/.claude/skills/herdr-adapter/references/v0.8.2.md")
assert_ok "R10 says the foreground call is read-only" \
  grep -qi 'read-only' <<<"$R10"
assert_ok "R10 names the interrupt-your-own-tool failure" \
  grep -qi 'interrupt' <<<"$R10"
assert_ok "CLAUDE.md §8 says the keystrokes come from the detached watchdog" \
  grep -qi 'detached watchdog' "$ROOT/CLAUDE.md"

SPEC="$ROOT/docs/specs/context-rollover-design.md"
assert_ok "the spec has a validation section" \
  grep -q '^## 8. Validation: what interrupts the rollover' "$SPEC"
val=$(sed -n '/^## 8. Validation: what interrupts the rollover/,$p' "$SPEC")
assert_ok "the validation names the observable that settled it" \
  grep -qi 'Recently denied' <<<"$val"
assert_ok "the validation cites its source" \
  grep -qF 'code.claude.com/docs' <<<"$val"

# --- the Linear inbox reaches every surface that has to know about it -------
# The field is the whole handoff between the drain that creates a card and the
# close-out that answers in Linear hours later. A surface that quietly forgets
# it leaves a Linear user with a question that is never answered.
for f in CLAUDE.md \
         templates/task-card.md \
         .claude/skills/monitor/SKILL.md \
         .claude/skills/triage/SKILL.md \
         .claude/skills/retro/SKILL.md; do
  assert_ok "linear-session: is known to $f" grep -q 'linear-session:' "$ROOT/$f"
done

tokens=$(grep -rhoiE 'linear[-_]session:' --include='*.md' --include='*.sh' "$ROOT" 2>/dev/null | sort -u)
assert_eq "one spelling of linear-session, everywhere" "$tokens" "linear-session:"

assert_ok "wake arms the inbox watcher" \
  grep -q 'inbox.sh watch' "$ROOT/.claude/skills/wake/SKILL.md"
assert_ok "monitor re-arms the inbox watcher" \
  grep -q 'inbox watcher is re-armed' "$ROOT/.claude/skills/monitor/SKILL.md"
assert_ok "monitor holds the drain procedure" \
  grep -q '^## Inbox drain' "$ROOT/.claude/skills/monitor/SKILL.md"
# response completes the Linear session, so exactly one surface may post it,
# and it is the close-out. A response posted at drain time for carded work
# would close the session before the work started.
assert_ok "retro is where the closing response is posted" \
  grep -q 'activity <linear-session> response' "$ROOT/.claude/skills/retro/SKILL.md"
assert_ok "the drain acks at drain time, and says why it cannot wait for retro" \
  grep -qE 'Ack every event you handled.*drain time' "$ROOT/.claude/skills/monitor/SKILL.md"
assert_ok "CLAUDE.md names the inbox config file" \
  grep -q 'config/shepherd/inbox.env' "$ROOT/CLAUDE.md"

# --- wake's two inbox slots -------------------------------------------------
# Step 8 arms on cmd_owner's exit 1 as well as exit 0, and step 10's status
# line has a slot to report the watcher's state at all.
inbox_step=$(sed -n '/Plus one inbox watcher/,/^### 9/p' "$ROOT/.claude/skills/wake/SKILL.md")
assert_ok "wake step 8 arms on cmd_owner's exit 1, not only exit 0" \
  grep -qE 'exit 1' <<<"$inbox_step"
assert_ok "wake step 10 reports the inbox watcher's state" \
  grep -q "inbox watcher's state" "$ROOT/.claude/skills/wake/SKILL.md"

# --- the drain refuses to card the same event twice (C2) --------------------
# The drain triages (id, card, dispatch - minutes), posts, then acks. An
# interrupt in that window leaves the event unacked, the Worker re-serves it,
# and without this check the next drain builds a second card and dispatches a
# second worker onto one request. linear-event: exists for exactly this read.
drain=$(sed -n '/^## Inbox drain/,/^## Invariants/p' "$ROOT/.claude/skills/monitor/SKILL.md")
assert_ok "the drain greps a card's linear-event: before it triages anything" \
  grep -qF 'grep -l "^linear-event: <event-id>$" ledger/tasks/T-*.md' <<<"$drain"
assert_ok "and an event that already has a card is acked, not re-carded" \
  grep -qE 'A hit →.*triage nothing' <<<"$drain"

# --- and the skip branch still speaks (R4) ---------------------------------
# The interrupt is as likely to have landed after the card was written as
# before it - the whole dispatch sits in that window - so a silent skip leaves
# the requester with a card, a worker and nothing said, on a session Linear
# marks stale after 30 idle minutes. A duplicate thought changes no session
# state, so the trade is not symmetric; the Log guard is retro's shape, and
# earns its place against a card whose close-out already posted the response.
skip=$(sed -n '/^### 1\. Skip an event/,/^### 2\./p' "$ROOT/.claude/skills/monitor/SKILL.md")
assert_ok "the skip branch posts the acknowledging thought before it acks" \
  grep -qF 'activity <session-id> thought' <<<"$skip"
assert_ok "and guards it on the card's Log, the way retro guards its response" \
  grep -qF 'grep -q "linear: .* posted"' <<<"$skip"
assert_ok "and the drain's order is triage, then post, then ack" \
  grep -qE 'triages .*then posts, and only then acks' <<<"$(tr '\n' ' ' <<<"$skip")"
assert_fail "no prose surface still claims the drain posts before it triages" \
  grep -rqF --include='*.md' 'posts, then triages' \
    "$ROOT/.claude/skills" "$ROOT/docs" "$ROOT/CLAUDE.md"

# --- event content is untrusted, and its author is recorded (C3) -----------
# An event is written by whoever can comment on the issue; the bearer token
# authenticates the inbox, not the person. Losing this line is how a Linear
# comment acquires the operator's authority.
assert_ok "the drain names event content untrusted third-party input" \
  grep -qiE 'untrusted' <<<"$drain"
assert_ok "and records the author, read from the event's raw webhook body" \
  grep -qE '`raw`' <<<"$drain"
assert_ok "triage records the author on the card it writes" \
  grep -qE '`raw`' "$ROOT/.claude/skills/triage/SKILL.md"
# The elicitation in monitor's blocked row is what creates the exposure, so
# the gate belongs next to it, not in a section a reader may not reach.
blocked_row=$(grep -n '^| \*\*blocked\*\*' "$ROOT/.claude/skills/monitor/SKILL.md" | cut -d: -f1)
blocked=$(sed -n "${blocked_row}p" "$ROOT/.claude/skills/monitor/SKILL.md")
assert_ok "the blocked row posts the escalation to Linear as an elicitation" \
  grep -qF 'activity <session> elicitation' <<<"$blocked"
assert_ok "and rules that a Linear reply is input, never authority" \
  grep -qE 'input, never authority' <<<"$blocked"

# --- the live-card match covers every open state, every owner (I3, R1) ------
# A card sits queued for hours by design, so a clarification arriving then is
# a reply, not new work. The match itself is owner-blind on purpose: an
# owner-filtered pipeline returns nothing for a peer's card, and nothing is the
# branch that cards and dispatches new work - the reader would answer a peer's
# reply with a second card and a second worker. Ownership is read off the hit
# instead, and the ledger is still shared: CLAUDE.md rule 10 allows no write to
# a card another instance owns.
match=$(sed -n '/^### 2\. Match a reply/,/^### 3\./p' "$ROOT/.claude/skills/monitor/SKILL.md")
match_cmd=$(sed -n '/^grep -l "\^linear-session:/,/^```/p' <<<"$match")
assert_ok "the match covers every open state, queued and review included" \
  grep -qF '^state: (queued|captured|briefed|working|blocked|review)' <<<"$match_cmd"
assert_fail "and the match command itself is owner-blind, so a peer's card is found" \
  grep -qF 'owner:' <<<"$match_cmd"
# Line order is the invariant: find the card, read owner:, and only then treat
# an empty result as new work. Any other order is the duplicate-card bug.
m_line=$(grep -n '^grep -l "\^linear-session:' <<<"$match" | head -1 | cut -d: -f1)
o_line=$(grep -n 'read `owner:` on that card' <<<"$match" | head -1 | cut -d: -f1)
p_line=$(grep -n "peer's card → leave the card alone" <<<"$match" | head -1 | cut -d: -f1)
assert_ok "owner: is read off the matched card, after the match rather than inside it" \
  test "${o_line:-0}" -gt "${m_line:-0}"
assert_ok "and the peer branch hangs off that read, not off an empty match" \
  test "${p_line:-0}" -gt "${o_line:-0}"
assert_ok "a match owned by a peer is handed over, never written to" \
  grep -qE '§4a' <<<"$match"
assert_ok "and an empty match, not a peer's card, is what becomes a new request" \
  grep -qE 'No output →.*new request' <<<"$match"

# --- the escalation round trip can actually answer a worker (I2) -----------
# triage §5 offers Amend and Cancel; neither is "this is the answer to the
# question the worker is blocked on". Routing a blocked card's reply there
# dead-ends the round trip monitor's blocked row just started.
assert_ok "a blocked card's reply returns to the blocked row's answer path" \
  grep -qE '\| .blocked. on a question .*elicitation.* \|' <<<"$drain"
assert_ok "and any other open state still routes to triage §5" \
  grep -qE 'triage §5' <<<"$drain"

# --- the failure ceiling is transient, and both callers know it (I4) -------
# Exit 1 there retired Linear intake for the rest of the session over ~12
# minutes of Cloudflare trouble. 4 means transient: re-arm, and say so.
assert_ok "the script's header documents exit 4" \
  grep -qE '^#   4 ' "$ROOT/scripts/inbox.sh"
assert_ok "the design's exit table documents exit 4" \
  grep -qE '^\| 4 \|' "$ROOT/docs/specs/linear-inbox-wiring-design.md"
for f in .claude/skills/wake/SKILL.md .claude/skills/monitor/SKILL.md; do
  assert_ok "$f re-arms on exit 4 rather than reporting and stopping" \
    grep -qE 'Exit 4 → *re-arm' "$ROOT/$f"
  assert_ok "$f still refuses to re-arm on exit 1 or 3" \
    grep -qE 'Exit 1 or 3 →' "$ROOT/$f"
done

# --- every close-out answers in Linear, including the two that are not "done" -
# A cancelled or parked card whose session nobody completes shows a requester
# an agent that acknowledged and then went permanently silent.
retro_notify=$(sed -n '/^4\. \*\*Notify\*\*/,/^5\. \*\*Worker pane/p' "$ROOT/.claude/skills/retro/SKILL.md")
assert_ok "retro's closing response covers abandoned as well as done and failed" \
  grep -qE 'abandoned' <<<"$retro_notify"
assert_ok "and posts it only where the card has not logged one already" \
  grep -qF 'grep -q "linear: response posted"' <<<"$retro_notify"
# triage §5's captured/queued cancel is the only close-out that skips retro,
# so it is the only place the obligation has to be restated.
triage_amend=$(sed -n '/^## 5. Amend or cancel/,$p' "$ROOT/.claude/skills/triage/SKILL.md")
assert_ok "triage's captured/queued cancel posts the closing response itself" \
  grep -qF 'activity <linear-session> response' <<<"$triage_amend"

# --- ownership is not settled once (C1) ------------------------------------
# One box, several instances, one inbox.env and one bearer token that
# authenticates the inbox rather than the caller. A watcher that decided
# ownership only at arm time handed a non-owner a whole window on the owner's
# inbox after any /health blip.
# Naming still_ours is not enough: the function's own definition and the
# pre-check both match a file-wide grep, so both survive deleting every gate
# inside the loop. Count the call sites where they actually stand instead - the
# heartbeat tick and the gate between a positive pending count and exit 0.
watch_fn=$(sed -n '/^cmd_watch()/,/^}/p' "$ROOT/scripts/inbox.sh")
watch_pre=$(sed -n '1,/^  while :; do/p' <<<"$watch_fn" | grep -c 'still_ours')
watch_loop=$(sed -n '/^  while :; do/,/^  done/p' <<<"$watch_fn" | grep -c 'still_ours')
assert_ok "watch re-checks ownership inside its loop, not only at arm time" \
  test "${watch_loop:-0}" -ge 2
assert_ok "and still refuses to arm at all for another instance's inbox" \
  test "${watch_pre:-0}" -ge 1
assert_ok "the pre-drain gate stands between a positive count and the return 0" \
  grep -qE 'still_ours \|\| return 3[[:space:]]*$' <<<"$(sed -n '/if \[ "\$PENDING" -gt 0 \]/,/fi/p' <<<"$watch_fn")"
assert_ok "wake says why arming on exit 1 is safe" \
  grep -qE 'settles ownership itself' <<<"$inbox_step"
assert_fail "the design no longer claims a second instance races nothing" \
  grep -qF 'arms no watcher and races nothing' "$ROOT/docs/specs/linear-inbox-wiring-design.md"

finish
