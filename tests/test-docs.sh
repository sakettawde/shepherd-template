#!/usr/bin/env bash
# The manual and the skills are the product here, so their invariants get
# assertions rather than promises. This file reads the repo in place: it takes
# no sandbox and writes nothing.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
ROOT=$(cd "$HERE/.." && pwd)

echo "test-docs:"

# --- working-agreement: reaches every surface that has to know about it ------
# The field only works if the writer, both readers and the template agree. A
# surface that never learned the field silently goes back to the T-0084
# behaviour: a Brief pointing at a CLAUDE.md the worker cannot open.
for f in manual/shepherd.md \
         templates/task-card.md \
         skills/onboard/SKILL.md \
         skills/triage/SKILL.md \
         skills/dispatch/SKILL.md; do
  assert_ok "working-agreement: is known to $f" grep -q 'working-agreement:' "$ROOT/$f"
done

# One spelling, everywhere. Every field is greped for by name, so an
# underscore or a stray capital reads as the field being absent.
tokens=$(grep -rhoiE 'working[-_]agreement:' \
           --include='*.md' --include='*.sh' "$ROOT" 2>/dev/null | sort -u)
assert_eq "one spelling of the field, everywhere" "$tokens" "working-agreement:"

# --- docs/protocols.md is the field's spec home (moved from CLAUDE.md, T-0222)
assert_ok "protocols.md documents the 'none' value" \
  grep -q '`none` when the repo has no CLAUDE.md' "$ROOT/docs/protocols.md"
# The ref guard is the part a reader is most likely to drop as redundant, and
# dropping it makes a never-fetched checkout report 'no working agreement'.
assert_ok "the check fetches before it reads" grep -q 'fetch origin --quiet' "$ROOT/docs/protocols.md"
assert_ok "the check verifies the ref before the path" \
  grep -q 'rev-parse --verify --quiet' "$ROOT/docs/protocols.md"
assert_ok "the check tests the path at the ref" grep -q 'cat-file -e' "$ROOT/docs/protocols.md"
assert_ok "CLAUDE.md sends the field to protocols.md" \
  grep -q 'docs/protocols.md` § Working agreement' "$ROOT/manual/shepherd.md"

# --- the inlined rules exist, and there are four of them --------------------
rules=$(sed -n '/^\*\*This repo has no CLAUDE.md/,/^>/p' "$ROOT/templates/task-card.md" \
          | grep -cE '^[0-9]+\. ')
assert_eq "the template inlines four standing rules" "$rules" "4"

# --- dispatch's preconditions stay numbered in sequence ---------------------
# Inserting a precondition renumbers the rest, and three lines in ## Steps
# point back at them by index.
nums=$(sed -n '/^## Preconditions/,/^## Steps/p' "$ROOT/skills/dispatch/SKILL.md" \
         | grep -oE '^[0-9]+\.' | tr -d '.')
expected=$(seq 1 "$(printf '%s\n' "$nums" | grep -c .)")
assert_eq "dispatch preconditions are numbered 1..N with no gaps" \
  "$(printf '%s\n' "$nums")" "$(printf '%s\n' "$expected")"

last=$(printf '%s\n' "$nums" | tail -1)
dangling=$(grep -oE '[Pp]recondition[s]? item [0-9]+|precondition [0-9]+' \
             "$ROOT/skills/dispatch/SKILL.md" \
           | grep -oE '[0-9]+' | awk -v n="$last" '$1 < 1 || $1 > n')
assert_eq "no Steps line points at a precondition that does not exist" "$dangling" ""

# --- the ledger checkout never leaves main (F5) -----------------------------
# The guard in shepherd-commit is the mechanism; these two sentences are the
# reason a reader needs before the refusal makes sense.

# --- one spelling for the self-repo slug ------------------------------------
# `shepherd (self)` matches neither the S5 greps nor the lock name, so cards
# spelled that way are invisible to dispatch and retro.
assert_ok "CLAUDE.md names the self-repo slug" \
  grep -q '`project: shepherd`' "$ROOT/manual/shepherd.md"
assert_ok "CLAUDE.md retires the 'shepherd (self)' spelling" \
  grep -q 'spelling is retired' "$ROOT/manual/shepherd.md"

# --- §6 states the guardrail's strength honestly ----------------------------
# The hook matches a shell command as a string, so quoting, variables, `eval`
# and wrapper scripts all get past it. A manual that calls destructive git
# "mechanically blocked" promises a boundary the hook does not provide, and a
# shepherd who believes it stops verifying — which is the one thing §2 rule 1
# exists to prevent. The hook's own header already says "speed bump"; §6 has to
# say the same thing, or the two disagree about the same mechanism.
assert_fail "CLAUDE.md does not call destructive git 'mechanically blocked'" \
  grep -q 'mechanically blocked' "$ROOT/manual/shepherd.md"
assert_ok "the hook header frames itself as a speed bump" \
  grep -q 'speed bump' "$ROOT/hooks/worker-git-guardrail.sh"
assert_ok "CLAUDE.md uses the hook's own framing" \
  grep -q 'speed bump' "$ROOT/manual/shepherd.md"
assert_ok "CLAUDE.md names the second layer that does not travel" \
  grep -q 'permissions.deny' "$ROOT/manual/shepherd.md"

# --- parallelism metadata reaches its writer, its reader and the template ---
# `touch-areas:` is written by triage onto every card; `parallel-safety:` is
# triage's judgment and monitor's cue to re-run the DoD after a sibling merges.
# A surface that never learned a field leaves it either unfilled or unread, and
# an unread declaration is worse than no declaration: it reads as a check that
# happened.
for f in templates/task-card.md \
         skills/triage/SKILL.md; do
  assert_ok "touch-areas: is known to $f" grep -q 'touch-areas:' "$ROOT/$f"
done
for f in templates/task-card.md \
         skills/triage/SKILL.md \
         skills/monitor/SKILL.md; do
  assert_ok "parallel-safety: is known to $f" grep -q 'parallel-safety:' "$ROOT/$f"
done

# One spelling each, for the reason working-agreement: has one. Scoped to the
# framework surfaces rather than the whole tree: shepherd improvised a bolded
# prose constraint of the same name in the Briefs of T-0117/T-0118/T-0119 before
# the field existed, and those cards are instance state nobody rewrites. The
# invariant that matters is that the writer, the readers and the template agree
# — not that the words never appear in a sentence.
FRAMEWORK_SURFACES=("$ROOT/templates" "$ROOT/skills" "$ROOT/bin")

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
TRIAGE="$ROOT/skills/triage/SKILL.md"
DECOMP="$ROOT/skills/triage/references/decomposition.md"
assert_file "the decomposition reference exists" "$DECOMP"
assert_ok "triage points at the decomposition reference" \
  grep -q 'references/decomposition.md' "$TRIAGE"
assert_ok "decomposition reserves no id before the operator answers" \
  grep -qE 'reserve no id|no id .*before' "$DECOMP"
assert_ok "decomposition holds the slice boundary at behaviour" \
  grep -q 'Behavioral, not procedural' "$DECOMP"

# --- intake covers compound messages and edits to existing cards ------------
assert_eq "triage carries the five intake sections, numbered 1..5" \
  "$(grep -cE '^## [1-5]\. ' "$TRIAGE")" "5"
assert_ok "triage has an amend/cancel path" grep -q '^## 5\. Amend' "$TRIAGE"
assert_ok "cancelling reaches the state the manual already defines" \
  grep -q 'shepherd-card transition T-NNNN abandoned' "$TRIAGE"

# --- the claim placeholder is unique per card -------------------------------
# The cap counts DISTINCT `pane:` values, so two simultaneous claims by one
# instance must not spell the same string — they would collapse into a single
# occupied slot and the cap would overshoot by one per extra claim. Lane
# selection makes back-to-back claims on independent siblings ordinary rather
# than rare, so all three surfaces have to carry the task id, or the count is
# wrong wherever the odd one out is read.
for f in skills/dispatch/SKILL.md \
         skills/wake/SKILL.md \
         docs/specs/2026-08-18-multi-shepherd-design.md; do
  assert_ok "the claim placeholder carries the task id in $f" \
    grep -qE 'claiming-<(shepherd-id|your-id)>-T-NNNN' "$ROOT/$f"
  assert_fail "no bare placeholder survives in $f" \
    grep -qE 'claiming-<(shepherd-id|your-id)>[^-]' "$ROOT/$f"
done

# --- one queue per project, not one per working copy ------------------------
# Lanes are interchangeable, so a project's queued cards are one FIFO line.
# Selecting per working copy splits it into half-queues that cannot see each
# other, and the oldest card waits behind a younger one that happens to hold a
# different lane. Dispatch and retro have to agree on what "the queue" is, or
# a close-out hands off a card the next dispatch will not select.
DISPATCH="$ROOT/skills/dispatch/SKILL.md"
RETRO="$ROOT/skills/retro/SKILL.md"
assert_ok "dispatch selects across the project family" \
  grep -q 'project family' "$DISPATCH"
assert_ok "retro hands off across the project family" \
  grep -q 'project family' "$RETRO"

# FIFO within one working copy WAS the dependency enforcement: a blocker queued
# earlier simply ran first. A second lane removes that guarantee, so the
# declaration has to be checked outright — and a predecessor that ended failed
# never satisfied it under FIFO either.
assert_ok "dispatch enforces Depends on before it launches" \
  grep -q 'Depends on: T-XXXX' "$DISPATCH"

# --- lane selection consumes the parallelism metadata -----------------------
# T-0121 landed touch-areas: and parallel-safety: with no reader at all. An
# unread declaration is worse than no declaration: it reads as a check that
# happened.
for field in 'touch-areas:' 'parallel-safety:'; do
  assert_ok "dispatch reads $field" grep -q "$field" "$DISPATCH"
done

# Every card written before 2026-08-24 carries neither field. Reading absence
# as permission would open a second lane for the whole back catalogue at once,
# so absence has to resolve to the serialized answer.
assert_ok "an undeclared card reads as serialized" \
  grep -qE 'reads as .?serialized|absent[^.]*serialized' "$DISPATCH"

# The self-repo's base checkout may never leave main: every
# instance commits its ledger there concurrently. This one sentence is what
# carries that invariant into lane selection without a field to hold it.
assert_ok "a clone card never falls back to the base checkout" \
  grep -qE 'never (falls back|tries|moves) to the base' "$DISPATCH"

# A worktree isolates the filesystem and nothing else — ports, a local
# database, a Docker daemon and build caches stay shared. That hazard lives in
# prose on the registry card, so the call is dispatch's judgment; a judgment
# whose default is unstated is not a default.
assert_ok "dispatch judges the shared-resource hazard from the registry card" \
  grep -qE 'silen(ce|t)[^.]*safe' "$DISPATCH"

# project: is both the lock key and the worker's working copy. A relocation
# that is never written back sends monitor, retro and the next dispatch to the
# lane the card still names rather than the one the worker is in.
assert_ok "a relocated card records the lane it landed on" \
  grep -qE 'relocat[a-z]* into .?project' "$DISPATCH"

# --- a relocation that aborts is unsaid -------------------------------------
# The undo already restores state: and pane:. project: joined them at T-0124:
# a card left pointing at a lane that was never materialised sends the next
# dispatch to a directory that does not exist.
assert_ok "the undo restores the original project:" \
  grep -qE 'original .?project' "$DISPATCH"

# CLAUDE.md is where a reader looks up what project: means. The lane rule has
# to be there too, or the field reads as fixed at card-creation time and the
# reader treats a relocated card as corrupt.
assert_ok "CLAUDE.md calls project: the preferred lane" \
  grep -q 'preferred lane' "$ROOT/manual/shepherd.md"

# --- lanes run in parallel; their merges do not -----------------------------
# Every system that runs parallel lanes serializes integration back to the
# trunk. Two branches landing at once is exactly the case monitor's post-merge
# DoD re-run exists for, and that re-run only means anything if the second
# close-out waits for the first to land before it runs.
assert_ok "monitor lands one lane at a time" \
  grep -qE 'one (lane|branch) at a time|completion order' "$ROOT/skills/monitor/SKILL.md"
assert_ok "retro lands one branch at a time" \
  grep -qE 'one (branch|lane) at a time' "$RETRO"

# --- the cap counts workers, not lanes --------------------------------------
# A reader who has just met lane selection reasonably wonders whether a second
# lane needs its own budget. It does not: the three limits are independent and
# already compose, and saying so is what stops someone inventing a fourth.
assert_ok "dispatch states what a lane costs against the cap" \
  grep -qiE 'lane costs (one|a) slot' "$DISPATCH"

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
  grep -q 'needs your input to continue' "$ROOT/manual/shepherd.md"
assert_ok "CLAUDE.md names the template as the canonical wording" \
  grep -q 'canonical wording every Brief carries' "$ROOT/manual/shepherd.md"
assert_ok "monitor reads claim blocked as the worker waiting on you" \
  grep -qE 'blocked.*(waiting on you|needs your input|waiting for you)' "$ROOT/skills/monitor/SKILL.md"
assert_ok "monitor points at the rule's home" \
  grep -q 'the manual §6 holds the rule' "$ROOT/skills/monitor/SKILL.md"
# onboard's own Status protocol block REPLACES the template's, so an
# onboarding worker never reads the canonical rule unless this block sends it
# there.
onboard_proto=$(sed -n '/^### Status protocol/,$p' \
                  "$ROOT/skills/onboard/SKILL.md")
assert_ok "onboard's status block points back at the canonical rule" \
  grep -q 'task-card.md' <<<"$onboard_proto"
assert_ok "onboard covers pauses its own two lines do not name" \
  grep -qiE '(any|every) other pause' <<<"$onboard_proto"

# --- the wake skill carries §8's session-start procedure (T-0187) -----------
# §8 kept ten numbered steps inline, and every fresh session after a context
# rollover re-derived them from prose. The procedure now lives in one skill the
# recovery message invokes by name; §8 keeps the rules. Both halves are
# asserted, because either half alone is a recovery that skips something.
WAKE="$ROOT/skills/wake/SKILL.md"
assert_file "the wake skill exists" "$WAKE"
assert_fail "the wake skill declares NO name: field" grep -q '^name:' "$WAKE"
assert_ok "so /shepherd:wake is the only invocation, taken from the directory" \
  grep -q '^description:' "$WAKE"
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
         'shepherd-identity acquire' \
         'shepherd-lock sweep' \
         'shepherd-reserve sweep' \
         'shepherd-lock takeover' \
         'shepherd-rollover decide'; do
  assert_ok "the wake skill names \`$c\`" grep -qF "$c" "$WAKE"
done

# Both sweeps exit 3 when a line needs a human (T-0217 §5). A fresh session
# that reads only the verdict lines can miss one; the exit code is the
# summary it cannot miss, so what a 3 means for the operator report is said
# once, in step 3, for both sweeps, and step 4 defers to it — T-0255 f moved
# step 4's copy here, because two copies of one rule drift.
# Flattened to one line each: the paragraphs wrap, and grep matches per line.
step3=$(sed -n '/^### 3\. /,/^### 4\. /p' "$WAKE" | tr '\n' ' ')
step4=$(sed -n '/^### 4\. /,/^### 5\. /p' "$WAKE" | tr '\n' ' ')
assert_ok "wake step 3 names the sweep exit code" grep -qi 'exit code' <<<"$step3"
assert_ok "wake step 3 says a 3 goes to the operator report" grep -qiE 'exit.*3.*(operator|report)' <<<"$step3"
assert_ok "wake step 3's exit-code sentence covers step 4's sweep too" grep -qiE 'exit code[^.]*step 4' <<<"$step3"
assert_ok "wake step 3 names the dry run" grep -qF 'sweep --dry-run' <<<"$step3"
assert_ok "wake step 4 reports its exit code and line kinds as step 3 does" grep -qiE 'exit code[^.]*step 3' <<<"$step4"
assert_fail "wake step 4 no longer restates what a 3 means" grep -qE '\`3\` *=' <<<"$step4"

# Every verdict the lock sweep can print has to be a line kind step 3 teaches.
# One the procedure never names is one a fresh session reads as routine and
# drops from the operator report - and the human-needed kinds are exactly the
# ones nobody else will act on. Derived from the script rather than listed
# here, so a new sweep arm cannot ship without its line in the skill.
sweep_verdicts=$(grep -oE '\bsay [A-Z][A-Z-]+' "$ROOT/bin/shepherd-lock" | awk '{print $2}' | sort -u)
sweep_verdicts="$sweep_verdicts SWEEP-SKIPPED"   # printed by the pre-flight, not through say
for kind in $sweep_verdicts; do
  assert_ok "wake step 3 names the \`$kind\` line kind" grep -qF "\`$kind\`" <<<"$step3"
done

# The rules stay in CLAUDE.md; the skill cites them rather than restating them.
assert_ok "the wake skill cites the manual §8 as the rules home" \
  grep -q 'the manual §8' "$WAKE"
# Thresholds have exactly one home (§8). A second copy drifts, and the copy a
# fresh session reads first is the one that decides whether it rolls over.
assert_fail "the wake skill does not restate the rollover thresholds" \
  grep -qE '200k|350k|60 ?%|85 ?%' "$WAKE"

assert_ok "the manual §8 sends session start to the wake skill" \
  grep -q '`wake` skill' "$ROOT/manual/shepherd.md"

# --- one `decide` per wake (T-0253 item 6, T-0259 item 1) -------------------
# shepherd-wake-report runs `decide` for the STATUS word and step 10 reads that word.
# §8 kept listing step 10 among the points that run the probe, so a shepherd
# following the manual literally ran it twice — the manual and the skill
# disagreeing about a procedure every wake performs.
ctxcheck=$(grep -F 'Context check — you measure yourself' "$ROOT/manual/shepherd.md")
assert_fail "the manual §8 no longer sends wake step 10 to run \`decide\` itself" \
  grep -qE 'Run it at every point you are already awake:[^.]*wake step 10' <<<"$ctxcheck"
# The pointer, not the format: shepherd-wake-report's line shape is pinned where it is
# produced (test-wake-report), and an always-loaded copy of it here is the same
# duplication this fix removes.
assert_ok "§8 names the report's STATUS line as the wake verdict instead" \
  grep -qE 'shepherd-wake-report.*STATUS.*wake step 10' <<<"$ctxcheck"
assert_ok "§8 still names the other three run points" \
  grep -qE 'monitor wake.*retro step 7.*triage' <<<"$ctxcheck"
assert_ok "§8 still carries the absolute-or-percent thresholds" \
  grep -qE 'whichever fires first.*200k.*60 %.*350k.*85 %' <<<"$ctxcheck"

# --- one recovery message, on every surface that quotes it ------------------
# The watchdog proves recovery by grepping the fresh session's transcript for
# this exact string (shepherd-rollover verify_prompt). A surface quoting a
# different one either reports a rollover that never recovered, or recovers a
# session that then does nothing.
# The prose surfaces quote it as a code span; the script carries it as the
# default. Both are matched literally — a bare `/shepherd:wake` also matches the word
# "tasks/wakes" in R10's meter paragraph, which is not a quotation of anything.
assert_ok "the script carries the message as its default" \
  grep -qF 'ROLLOVER_MSG:-/shepherd:wake' "$ROOT/bin/shepherd-rollover"
assert_ok "the test pins the same message" \
  grep -qF 'MSG="/shepherd:wake"' "$ROOT/tests/test-rollover.sh"
for f in manual/shepherd.md \
         skills/herdr-adapter/references/v0.8.2.md \
         docs/specs/context-rollover-design.md; do
  assert_ok "the recovery message is \`/shepherd:wake\` in $f" grep -qF '`/shepherd:wake`' "$ROOT/$f"
done

# The prose it replaced is gone from every surface that INVOKES it. The spec
# may still quote it as history — that is the record of what was interrupted.
for f in bin/shepherd-rollover \
         tests/test-rollover.sh \
         manual/shepherd.md \
         skills/herdr-adapter/references/v0.8.2.md; do
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
R10=$(sed -n '/^## R10 /,/^## Surfaces shepherd/p' "$ROOT/skills/herdr-adapter/references/v0.8.2.md")
assert_ok "R10 says the foreground call is read-only" \
  grep -qi 'read-only' <<<"$R10"
assert_ok "R10 names the interrupt-your-own-tool failure" \
  grep -qi 'interrupt' <<<"$R10"
assert_ok "the manual §8 says the keystrokes come from the detached watchdog" \
  grep -qi 'detached watchdog' "$ROOT/manual/shepherd.md"

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
for f in manual/shepherd.md \
         templates/task-card.md \
         skills/monitor/SKILL.md \
         skills/triage/SKILL.md \
         skills/retro/SKILL.md; do
  assert_ok "linear-session: is known to $f" grep -q 'linear-session:' "$ROOT/$f"
done

tokens=$(grep -rhoiE 'linear[-_]session:' --include='*.md' --include='*.sh' "$ROOT" 2>/dev/null | sort -u)
assert_eq "one spelling of linear-session, everywhere" "$tokens" "linear-session:"

assert_ok "wake arms the inbox watcher through shepherd-watch" \
  grep -qF 'shepherd-watch arm inbox --window 21600' "$ROOT/skills/wake/SKILL.md"
assert_ok "monitor re-arms the inbox watcher" \
  grep -qiE 're-arm(ed)?[^.]*inbox|inbox[^.]*re-arm' <<<"$(sed -n '/^## Invariants/,$p' "$ROOT/skills/monitor/SKILL.md")"
# The drain is reached only from an inbox wake, so it lives behind a reference
# (T-0234, progressive disclosure); the wake path in monitor has to name it, or
# it is never loaded.
DRAIN_REF="$ROOT/skills/monitor/references/inbox-drain.md"
assert_file "the inbox drain reference exists" "$DRAIN_REF"
assert_ok "the drain reference is titled" grep -q '^# Inbox drain' "$DRAIN_REF"
assert_ok "monitor names the drain reference on its inbox path" \
  grep -q 'references/inbox-drain.md' "$ROOT/skills/monitor/SKILL.md"
# response completes the Linear session, so exactly one surface may post it,
# and it is the close-out. A response posted at drain time for carded work
# would close the session before the work started.
assert_ok "retro is where the closing response is posted" \
  grep -q 'activity <linear-session> response' "$ROOT/skills/retro/SKILL.md"
assert_ok "the drain acks at drain time, and says why it cannot wait for retro" \
  grep -qiE 'ack[^.]*drain time|drain time[^.]*ack' "$DRAIN_REF"
assert_ok "CLAUDE.md names the inbox config file" \
  grep -q 'config/shepherd/inbox.env' "$ROOT/manual/shepherd.md"

# --- wake's two inbox slots -------------------------------------------------
# Step 8 arms on cmd_owner's exit 1 as well as exit 0, and step 10's status
# line has a slot to report the watcher's state at all.
inbox_step=$(sed -n '/^### 8\. /,/^### 9\. /p' "$ROOT/skills/wake/SKILL.md")
assert_ok "wake step 8 arms on cmd_owner's exit 1, not only exit 0" \
  grep -qE '\(exit 1\)' <<<"$inbox_step"
assert_ok "wake step 10 reports the inbox watcher's state" \
  grep -q "inbox watcher's state" <<<"$(sed -n '/^### 10\. /,/^## Done when/p' "$ROOT/skills/wake/SKILL.md")"

# --- the inbox watcher is armed through shepherd-watch, six-hour window (T-0224, T-0238)
# The poll loop costs no model tokens; each INBOX TIMEOUT costs one model turn
# whose whole handler is "re-arm". A one-hour window bought ~24 no-op wakes a
# day and no responsiveness, because cmd_watch re-checks ownership inside the
# loop. Arming through shepherd-watch (T-0237's inbox kind) is what lets `list` and
# `check` see the watcher and a rolled-over session's copy be replaced; a bare
# `shepherd-inbox watch` armed beside it would run two pollers on one inbox.
ARM_INBOX='shepherd-watch arm inbox --window 21600'
assert_ok "wake step 8 arms the six-hour window through shepherd-watch" \
  grep -qF "$ARM_INBOX" <<<"$inbox_step"
assert_ok "wake step 8 says why the window is long" \
  grep -qE 'model turn' <<<"$inbox_step"
assert_eq "no surface still arms the one-hour inbox window" \
  "$(grep -rl 'shepherd-inbox watch 3600' --exclude-dir=tests \
       "$ROOT/skills" "$ROOT/bin" "$ROOT/manual/shepherd.md" 2>/dev/null)" ""
assert_eq "no skill, manual, protocol or template arms shepherd-inbox watch directly any more" \
  "$(grep -rlE 'shepherd-inbox watch [0-9]+' \
       "$ROOT/skills" "$ROOT/manual/shepherd.md" "$ROOT/docs/protocols.md" "$ROOT/templates" 2>/dev/null)" ""
assert_ok "monitor's inbox re-arm names the same command and window" \
  grep -qF "$ARM_INBOX" <<<"$(sed -n '/^## Invariants/,$p' "$ROOT/skills/monitor/SKILL.md")"
assert_ok "the manual §3 names the same command and window" \
  grep -qF "$ARM_INBOX" "$ROOT/manual/shepherd.md"
assert_ok "shepherd-inbox's watch header explains the window's cost" \
  grep -qE 'costs one model turn' "$ROOT/bin/shepherd-inbox"
assert_ok "the design doc states the six-hour window" \
  grep -qF '21600 s' "$ROOT/docs/specs/linear-inbox-wiring-design.md"

# --- the drain refuses to card the same event twice (C2) --------------------
# The drain triages (id, card, dispatch - minutes), posts, then acks. An
# interrupt in that window leaves the event unacked, the Worker re-serves it,
# and without this check the next drain builds a second card and dispatches a
# second worker onto one request. linear-event: exists for exactly this read.
drain=$(cat "$DRAIN_REF")
assert_ok "the drain greps a card's linear-event: before it triages anything" \
  grep -qF 'grep -l "^linear-event: <event-id>$" ledger/tasks/T-*.md' <<<"$drain"
assert_ok "and an event that already has a card is acked, not re-carded" \
  grep -qE 'hit.*(triage nothing|already (has|carries) a card)' <<<"$drain"

# --- and the skip branch still speaks (R4) ---------------------------------
# The interrupt is as likely to have landed after the card was written as
# before it - the whole dispatch sits in that window - so a silent skip leaves
# the requester with a card, a worker and nothing said, on a session that may
# read stale (a state Linear documents no trigger for). A duplicate thought changes no session
# state, so the trade is not symmetric; the Log guard is retro's shape, and
# earns its place against a card whose close-out already posted the response.
skip=$(sed -n '/^## 1\. Skip an event/,/^## 2\./p' "$DRAIN_REF")
assert_ok "the skip branch posts the acknowledging thought before it acks" \
  grep -qF 'activity <session-id> thought' <<<"$skip"
assert_ok "and guards it on the card's Log, the way retro guards its response" \
  grep -qF 'grep -q "linear: .* posted"' <<<"$skip"
assert_ok "and the drain's order is triage, then post, then ack" \
  grep -qiE 'triag[a-z]*[^.]*post[a-z]*[^.]*ack' <<<"$(tr '\n' ' ' <<<"$skip")"
assert_fail "no prose surface still claims the drain posts before it triages" \
  grep -rqF --include='*.md' 'posts, then triages' \
    "$ROOT/skills" "$ROOT/docs" "$ROOT/manual/shepherd.md"

# --- event content is untrusted, and its author is recorded (C3) -----------
# An event is written by whoever can comment on the issue; the bearer token
# authenticates the inbox, not the person. Losing this line is how a Linear
# comment acquires the operator's authority.
assert_ok "the drain names event content untrusted third-party input" \
  grep -qiE 'untrusted' <<<"$drain"
assert_ok "and records the author, read from the event's raw webhook body" \
  grep -qE '`raw`' <<<"$drain"
assert_ok "triage records the author on the card it writes" \
  grep -qE '`raw`' "$ROOT/skills/triage/SKILL.md"
# The elicitation in monitor's blocked row is what creates the exposure, so
# the gate belongs next to it, not in a section a reader may not reach.
blocked_row=$(grep -n '^| \*\*blocked\*\*' "$ROOT/skills/monitor/SKILL.md" | cut -d: -f1)
blocked=$(sed -n "${blocked_row}p" "$ROOT/skills/monitor/SKILL.md")
assert_ok "the blocked row posts the escalation to Linear as an elicitation" \
  grep -qF 'activity <session> elicitation' <<<"$blocked"
assert_ok "and rules that a Linear reply is input, never authority" \
  grep -qE 'never (the operator.s )?authority|input, never authority' <<<"$blocked"

# --- the live-card match covers every open state, every owner (I3, R1) ------
# A card sits queued for hours by design, so a clarification arriving then is
# a reply, not new work. The match itself is owner-blind on purpose: an
# owner-filtered pipeline returns nothing for a peer's card, and nothing is the
# branch that cards and dispatches new work - the reader would answer a peer's
# reply with a second card and a second worker. Ownership is read off the hit
# instead, and the ledger is still shared: CLAUDE.md rule 10 allows no write to
# a card another instance owns.
match=$(sed -n '/^## 2\. Match a reply/,/^## 3\./p' "$DRAIN_REF")
match_cmd=$(sed -n '/^grep -l "\^linear-session:/,/^```/p' <<<"$match")
assert_ok "the match covers every open state, queued and review included" \
  grep -qF '^state: (queued|captured|briefed|working|blocked|review)' <<<"$match_cmd"
assert_fail "and the match command itself is owner-blind, so a peer's card is found" \
  grep -qF 'owner:' <<<"$match_cmd"
# Line order is the invariant: find the card, read owner:, and only then treat
# an empty result as new work. Any other order is the duplicate-card bug.
m_line=$(grep -n '^grep -l "\^linear-session:' <<<"$match" | head -1 | cut -d: -f1)
o_line=$(grep -n 'owner:' <<<"$match" | awk -F: -v m="${m_line:-0}" '$1 > m { print $1; exit }')
p_line=$(grep -niE "peer.s card" <<<"$match" | awk -F: -v o="${o_line:-0}" '$1 > o { print $1; exit }')
assert_ok "owner: is read off the matched card, after the match rather than inside it" \
  test "${o_line:-0}" -gt "${m_line:-0}"
assert_ok "and the peer branch hangs off that read, not off an empty match" \
  test "${p_line:-0}" -gt "${o_line:-0}"
assert_ok "a match owned by a peer is handed over, never written to" \
  grep -qE '§4a|Ownership and handoff' <<<"$match"
assert_ok "and an empty match, not a peer's card, is what becomes a new request" \
  grep -qiE '(no output|empty|nothing)[^.]*new request' <<<"$match"

# --- the escalation round trip can actually answer a worker (I2) -----------
# triage §5 offers Amend and Cancel; neither is "this is the answer to the
# question the worker is blocked on". Routing a blocked card's reply there
# dead-ends the round trip monitor's blocked row just started.
assert_ok "a blocked card's reply returns to the blocked row's answer path" \
  grep -qE 'blocked.*elicitation' <<<"$drain"
assert_ok "and any other open state still routes to triage §5" \
  grep -qE 'triage §5' <<<"$drain"

# --- the failure ceiling is transient, and both callers know it (I4) -------
# Exit 1 there retired Linear intake for the rest of the session over ~12
# minutes of Cloudflare trouble. 4 means transient: re-arm, and say so.
assert_ok "the script's header documents exit 4" \
  grep -qE '^#   4 ' "$ROOT/bin/shepherd-inbox"
assert_ok "the design's exit table documents exit 4" \
  grep -qE '^\| 4 \|' "$ROOT/docs/specs/linear-inbox-wiring-design.md"
# shepherd-watch maps shepherd-inbox's codes to verdict lines (its 3 and 4 already mean
# BLOCKED and ARMED-ALREADY), so the skills read the words, not the numbers:
# UNREACHABLE re-arms and says so, TIMEOUT re-arms silently, NOT-CONFIGURED
# and AUTH report and stop.
for f in skills/wake/SKILL.md skills/monitor/SKILL.md; do
  assert_ok "$f re-arms on INBOX UNREACHABLE rather than reporting and stopping" \
    grep -qiE 'INBOX UNREACHABLE`? → re-arm' "$ROOT/$f"
  assert_ok "$f says one line on INBOX UNREACHABLE, so a silent recovery cannot hide an outage" \
    grep -qiE 'INBOX UNREACHABLE`? → re-arm and one line' "$ROOT/$f"
  assert_ok "$f re-arms on INBOX TIMEOUT" \
    grep -qiE 'INBOX TIMEOUT`? → re-arm' "$ROOT/$f"
  assert_ok "$f still refuses to re-arm on INBOX NOT-CONFIGURED or INBOX AUTH" \
    grep -qiE 'INBOX NOT-CONFIGURED`? or `?INBOX AUTH`? → report, no re-arm' "$ROOT/$f"
  assert_ok "$f reports shepherd-watch's ERROR verdict and checks what is left watching" \
    grep -qiE 'ERROR shepherd-inbox exited <rc>`? → report[^.]*shepherd-watch list inbox' "$ROOT/$f"
  assert_ok "$f runs the drain on INBOX WORK" \
    grep -qiE 'INBOX WORK`? → (run `references/inbox-drain\.md` instead of the ladder|monitor.s drain)' "$ROOT/$f"
  assert_fail "$f no longer reads shepherd-inbox's raw exit codes for the inbox watcher" \
    grep -qiE 'exit 4[^.]*re-arm|exit 1 or 3' "$ROOT/$f"
done

# --- every close-out answers in Linear, including the two that are not "done" -
# A cancelled or parked card whose session nobody completes shows a requester
# an agent that acknowledged and then went permanently silent.
retro_notify=$(sed -n '/^4\. \*\*Notify\*\*/,/^5\. \*\*Worker pane/p' "$ROOT/skills/retro/SKILL.md")
assert_ok "retro's closing response covers abandoned as well as done and failed" \
  grep -qE 'abandoned' <<<"$retro_notify"
assert_ok "and posts it only where the card has not logged one already" \
  grep -qF 'grep -q "linear: response posted"' <<<"$retro_notify"
# triage §5's captured/queued cancel is the only close-out that skips retro,
# so it is the only place the obligation has to be restated.
triage_amend=$(sed -n '/^## 5. Amend or cancel/,$p' "$ROOT/skills/triage/SKILL.md")
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
watch_fn=$(sed -n '/^cmd_watch()/,/^}/p' "$ROOT/bin/shepherd-inbox")
watch_pre=$(sed -n '1,/^  while :; do/p' <<<"$watch_fn" | grep -c 'still_ours')
watch_loop=$(sed -n '/^  while :; do/,/^  done/p' <<<"$watch_fn" | grep -c 'still_ours')
assert_ok "watch re-checks ownership inside its loop, not only at arm time" \
  test "${watch_loop:-0}" -ge 2
assert_ok "and still refuses to arm at all for another instance's inbox" \
  test "${watch_pre:-0}" -ge 1
assert_ok "the pre-drain gate stands between a positive count and the return 0" \
  grep -qE 'still_ours \|\| return 3[[:space:]]*$' <<<"$(sed -n '/if \[ "\$PENDING" -gt 0 \]/,/fi/p' <<<"$watch_fn")"
assert_ok "wake says why arming on exit 1 is safe" \
  grep -qiE 'ownership[^.]*(itself|inside|loop|tick)' <<<"$inbox_step"
assert_fail "the design no longer claims a second instance races nothing" \
  grep -qF 'arms no watcher and races nothing' "$ROOT/docs/specs/linear-inbox-wiring-design.md"
# --- the Linear conversation: intents, the trust gate, the voice (T-0238) --
# Spec docs/specs/2026-09-07-linear-conversation-design.md §1, §3, §4, §7.
# A Linear message is read for intent before it is typed, because the intent
# picks the handler and the first word: a state question answered from the
# ledger in the drain's three minutes is not a build card answering hours
# later. The table is triage's, behind a reference; the trust gate and the
# voice are protocols'; the drain, monitor's blocked row and wake step 8 read
# them. Each pin below holds a behaviour, so a rewrite that keeps the words
# but loses the rule still fails.
INTENTS="$ROOT/skills/triage/references/linear-intents.md"
PROTO="$ROOT/docs/protocols.md"
TRIAGE="$ROOT/skills/triage/SKILL.md"
MON="$ROOT/skills/monitor/SKILL.md"
assert_file "the intents reference exists" "$INTENTS"
assert_ok "the intents reference is titled" grep -q '^# Linear intents' "$INTENTS"
triage_task=$(sed -n '/^## 4\. Task/,/^## 5\./p' "$TRIAGE")
assert_ok "triage §4 points at the intents reference" \
  grep -qF 'references/linear-intents.md' <<<"$triage_task"
# The pointer has to fire before the message is typed: after the numbered
# steps it would be read only by a card already written.
ptr_line=$(grep -n 'references/linear-intents.md' <<<"$triage_task" | head -1 | cut -d: -f1)
route_line=$(grep -n '^1\. \*\*Route\*\*' <<<"$triage_task" | head -1 | cut -d: -f1)
assert_ok "and the Linear branch comes before step 1, so intent is read before routing" \
  test "${ptr_line:-0}" -gt 0 -a "${ptr_line:-0}" -lt "${route_line:-0}"
assert_ok "triage §4 says which intents continue down its steps" \
  grep -qiE 'only \*?build\*?[^.]*continue' <<<"$triage_task"

# --- the fourteen intents, each with a log token --------------------------
intent_rows=$(grep -c '^| \*\*' "$INTENTS")
assert_eq "the intents table has fourteen rows" "$intent_rows" "14"
for tok in status ask readiness estimate review investigate build build-with-preview \
           amend cancel answer-to-elicitation thanks multi-intent non-engineering; do
  assert_ok "the table carries the log token \`$tok\`" \
    grep -qE "^\| \*\*[^|]*\*\* \| \`$tok\` \|" "$INTENTS"
done
# A token with a space in it is refused by shepherd-inbox log (one word per column).
log_tokens=$(grep -oE '^\| \*\*[^|]*\*\* \| `[^`]*`' "$INTENTS" | sed -E 's/.*`([^`]*)`/\1/')
assert_eq "every log token is one word, and there are fourteen of them" \
  "$(grep -c . <<<"$log_tokens"):$(grep -c ' ' <<<"$log_tokens")" "14:0"
assert_ok "the reference says the token is shepherd-inbox log's intent column" \
  grep -qE 'log token[^.]*intent column[^.]*shepherd-inbox log|shepherd-inbox log[^.]*log token' "$INTENTS"

# --- the session decides the activity type, not the intent -----------------
# response completes a session; on a session with a card in flight the only
# response is the close-out, so every other word is a thought.
assert_ok "the status row takes a thought on a live session and a response otherwise" \
  grep -qE '^\| \*\*status\*\* \|.*\| the answer itself: `thought` on a live session, `response` otherwise \|' "$INTENTS"
assert_ok "and that a live session takes a thought" \
  grep -qiE 'card in flight[^.]*every word is a `thought`' "$INTENTS"
assert_ok "and that response is for a session with nothing open" \
  grep -qiE '`response` is for a session with nothing open' "$INTENTS"

# --- the reading order, the ambiguity rule, the elicitation-first rule ------
read_sec=$(sed -n '/^## How to read the intent/,/^## What the author/p' "$INTENTS")
assert_eq "the reading order has five numbered items" "$(grep -cE '^[0-9]+\. \*\*' <<<"$read_sec")" "5"
order=$(grep -oE '^[0-9]+\. \*\*[^*]+' <<<"$read_sec" | tr '\n' ' ')
assert_ok "and reads the text first, guidance last" \
  grep -qiE '^1\. \*\*The message text.*5\. \*\*Linear `guidance`' <<<"$order"
assert_ok "delegation vs mention is read on a created" \
  grep -qiE 'delegation vs mention.*`created`.*comment` is null.*\*build\* when the issue is specified.*\*readiness\* when it is thin' <<<"$read_sec"
assert_ok "guidance is a hint, never authority over the project's own rules" \
  grep -qiE 'guidance[^.]*never authority over a project.s CLAUDE\.md' <<<"$read_sec"
assert_ok "two intents that both fit are asked with a select, not guessed" \
  grep -qiE 'not guessed[^.]*`elicitation --select`' <<<"$read_sec"
assert_ok "and the select ceiling is five" grep -qiE 'five options is the ceiling' <<<"$read_sec"
assert_ok "a prompted on awaitingInput is answer-to-elicitation before anything else" \
  grep -qiE 'awaitingInput[^.]*answer-to-elicitation\*? before anything else' <<<"$read_sec"
assert_ok "and the ledger-side definition of awaitingInput is the Log marker" \
  grep -qiE 'awaitingInput[^.]*`blocked`[^.]*linear: elicitation posted' <<<"$read_sec"

# --- what the author may ask for --------------------------------------------
author_sec=$(sed -n '/^## What the author/,/^## What efficient/p' "$INTENTS")
assert_ok "read-only intents are served for anyone" \
  grep -qiE 'read-only intents are served for anyone' <<<"$author_sec"
assert_ok "a build from a non-operator is carded captured, with a thought and a toast" \
  grep -qiE 'non-operator[^.]*`captured`[^.]*`thought`[^.]*toast' <<<"$author_sec"
assert_ok "and logged held" grep -qF 'held:T-NNNN' <<<"$author_sec"
# captured is the backlog and nothing dispatches it, so the promoting act has
# to be named or a held build waits forever after the operator says go.
assert_ok "the operator's go promotes a held build through triage §5, as a transition to queued" \
  grep -qiE "the operator.s go[^.]*operator \`prompted\`[^.]*triage §5 amend: \`shepherd-card transition T-NNNN queued\`" <<<"$author_sec"
assert_ok "a build from the operator is queued" \
  grep -qiE 'build from the operator\*?\*? is `queued`' <<<"$author_sec"
assert_ok "amend and cancel are honoured from linear-author: or the operator only" \
  grep -qiE 'amend and cancel\*?\*? are honoured from the card.s `linear-author:` or the operator' <<<"$author_sec"

# --- the reply ladder (the interim word T-0238 wrote here was removed by T-0240,
# whose pins below name the reply card as the handler) -----------------------
assert_ok "the reply ladder is S by default, M for review and investigate, never L" \
  grep -qiE 'S opus/high 20m by default, M fable/high 60m for review and investigate[^.]*never L' "$INTENTS"

# --- the targets and the two clocks -------------------------------------------
targets=$(sed -n '/^## What efficient/,$p' "$INTENTS")
assert_ok "two clocks run from drain-start" \
  grep -qiE 'two clocks[^.]*drain starts' <<<"$targets"
assert_ok "the offline gap is logged beside them and never folded in" \
  grep -qiE 'offline gap\*?\*?[^.]*never folded in' <<<"$targets"
assert_eq "the targets table covers every intent group" "$(grep -cE '^\| (status, |ask, |readiness, |build, |answer-to-elicitation )' <<<"$targets")" "5"
assert_ok "a missed target goes to retro, and no verdict word hangs off it" \
  bash -c "grep -qiE 'missing one[^.]*retro' <<<\"\$1\" && ! grep -qiE 'missing one[^.]*(state: )?\`?failed\`?' <<<\"\$1\"" _ "$targets"
assert_ok "the reply-worker targets are explained as budget plus launch, verification and posting" \
  grep -qiE 'reply-worker targets are the card budget plus launch, verification and posting' <<<"$targets"

# --- linear-author: reaches every surface, one spelling ------------------------
for f in templates/task-card.md \
         skills/triage/SKILL.md \
         skills/triage/references/linear-intents.md \
         skills/monitor/references/inbox-drain.md \
         docs/protocols.md; do
  assert_ok "linear-author: is known to $f" grep -q 'linear-author:' "$ROOT/$f"
done
tokens=$(grep -rhoiE 'linear[-_]author:' --include='*.md' --include='*.sh' "$ROOT" 2>/dev/null | sort -u)
assert_eq "one spelling of linear-author, everywhere" "$tokens" "linear-author:"
tpl_event=$(grep -n '^linear-event:' "$ROOT/templates/task-card.md" | cut -d: -f1)
tpl_author=$(grep -n '^linear-author:' "$ROOT/templates/task-card.md" | cut -d: -f1)
assert_eq "the template puts linear-author: directly under linear-event:" \
  "$tpl_author" "$((tpl_event + 1))"
assert_ok "triage writes linear-author: from the event's author.id" \
  grep -qE 'linear-author:`[^.]*`author\.id`' "$TRIAGE"
assert_ok "and triage's amend/cancel entry honours the author rule" \
  grep -qiE 'linear-author:`[^.]*or the operator' <<<"$(sed -n '/^## 5\. Amend or cancel/,$p' "$TRIAGE")"

# --- the drain: the trust gate before the body ---------------------------------
drain=$(cat "$DRAIN_REF")
gate_line=$(grep -n 'author\.operator' <<<"$drain" | head -1 | cut -d: -f1)
skip_line=$(grep -n '^## 1\. Skip' <<<"$drain" | head -1 | cut -d: -f1)
assert_ok "the drain reads author.operator before its first step" \
  test "${gate_line:-0}" -gt 0 -a "${gate_line:-0}" -lt "${skip_line:-0}"

assert_ok "the drain maps the author to the log's trust column" \
  grep -qiE 'null id[^.]*no `author` field[^.]*`unknown`' <<<"$drain"
assert_ok "a Worker serving no author keeps the pane-confirmation rule" \
  grep -qiE 'serves no `author`[^.]*confirmed in the pane' <<<"$drain"
assert_ok "the drain notes drain-start at list time" \
  grep -qiE 'drain-start\*?\*?[^.]*clock' <<<"$drain"

# --- the drain: session decides the type; stop is cancel ----------------------
first_word=$(sed -n '/^## 3\. Intent/,/^## 4\./p' "$DRAIN_REF")
assert_ok "the drain lets the session pick the type" \
  grep -qiE 'session picks the type' <<<"$first_word"
assert_ok "a §2 hit means thought, no hit means response" \
  grep -qiE 'hit in §2[^.]*`thought`[^.]*no hit[^.]*`response`' <<<"$first_word"
assert_ok "the drain reads the stop signal as cancel" \
  grep -qiE '`stop` signal[^.]*is cancel' <<<"$drain"
# A prompted on a live card is not amend-or-cancel by default: a status
# question on a working card is answered from the ledger, and only the intent
# read in §3 says which it is. The review of this branch caught §2 routing
# every such reply to triage §5 before §3 was reached.
assert_ok "any other open state reads the intent first, and answers status and thanks with a thought" \
  grep -qiE 'Any other open state → §3 reads the intent first: status and thanks on the live card are answered with a `thought`' <<<"$drain"
assert_ok "and amend and cancel on that card still go to triage §5 under the author rule" \
  grep -qiE 'amend and cancel go to triage §5[^.]*author rule' <<<"$drain"
assert_ok "the stop signal outranks the awaitingInput marker in the drain" \
  grep -qiE 'outranks the marker is the `stop` signal' <<<"$drain"
assert_ok "and in the reference" \
  grep -qiE 'only the `stop` signal on the event outranks the marker' "$INTENTS"
assert_ok "a peer's card gets its thought, then the log line, then the ack" \
  grep -qiE 'post a `thought` naming the card and its owner, log it `routed:T-NNNN`, ack' <<<"$drain"
assert_ok "the ambiguity select's values are the log tokens, so the reply reads as that intent" \
  grep -qiE 'its values are the two log tokens[^.]*reads as that intent' "$INTENTS"
assert_ok "and answers a stop with nothing open" \
  grep -qiE '`stop` on a session with nothing open[^.]*`response`' <<<"$drain"
for outcome in answered asked 'carded:T-NNNN' 'held:T-NNNN' 'routed:T-NNNN' refused ignored; do
  assert_ok "the first-word table can produce outcome \`$outcome\`" \
    grep -qF "| \`$outcome\` |" <<<"$first_word"
done
assert_ok "a cancel with nothing open answers with a response, logged answered" \
  grep -qiE '^\| cancel[^|]*with nothing open \| `response`: nothing was running here \| `answered` \|' <<<"$first_word"
assert_ok "a build from a non-operator is held in the drain too" \
  grep -qiE 'non-operator \| card `captured`[^|]*toast' <<<"$first_word"
# The reader intents were the interim `--select` here until T-0240 built the
# reply kind; a drain reading the old row would ask the question the reply
# card now answers. The row cards, and the ladder stays in the intents
# reference rather than being restated here.
reader_row=$(grep -m1 -F 'templates/reply-card.md' <<<"$first_word")
# The row is matched by its first intent and read for what it produces, so a
# reordered or requalified intent list is a legitimate edit and not a failure.
reader_intents=$(cut -d'|' -f2 <<<"$reader_row")
for i in ask readiness estimate review investigate; do
  assert_ok "the reader row still covers $i" grep -qiw "$i" <<<"$reader_intents"
done
assert_ok "the five reader intents card a reply from the template, carded like a build" \
  grep -qiE '\| card `queued` from `\${CLAUDE_PLUGIN_ROOT}/templates/reply-card.md`[^|]*reply ladder[^|]*\| `carded:T-NNNN` \|' <<<"$reader_row"
assert_ok "and their first word is the ephemeral thought, not a question" \
  grep -qiE 'ephemeral `thought`' <<<"$reader_row"
assert_fail "the drain no longer posts the interim select the reply kind replaced" \
  grep -qF -- '--select "build it now=build|wait for a reader=wait"' "$DRAIN_REF"
assert_fail "and no longer waits on T-0240" grep -q 'T-0240' "$DRAIN_REF"
assert_ok "the answer-to-elicitation row goes through monitor's blocked row" \
  grep -qiE 'answer-to-elicitation \| monitor.s blocked row' <<<"$first_word"

# --- the drain: the log line, then the ack, then one commit, then the re-arm ----
log_sec=$(sed -n '/^## 4\. Log/,$p' "$DRAIN_REF")
assert_ok "the drain writes the inbox.log line through shepherd-inbox log" \
  grep -qF 'shepherd-inbox log <drain-start> <event-id> <session|none> <kind> <intent> <operator|member|unknown> <outcome> <received-at>' <<<"$log_sec"
log_line=$(grep -n '^shepherd-inbox log' <<<"$log_sec" | head -1 | cut -d: -f1)
ack_line=$(grep -n '^shepherd-inbox ack' <<<"$log_sec" | head -1 | cut -d: -f1)
assert_ok "and the log line lands before the ack" \
  test "${log_line:-0}" -gt 0 -a "${log_line:-0}" -lt "${ack_line:-0}"
assert_ok "the log is committed through shepherd-commit" \
  grep -qF 'shepherd-commit' <<<"$log_sec"
assert_ok "and the commit carries only ledger/inbox.log" \
  grep -qE 'shepherd-commit "[^"]*" ledger/inbox\.log`' <<<"$log_sec"
assert_ok "the re-arm is the last thing the drain does, through shepherd-watch" \
  grep -qF "$ARM_INBOX" <<<"$(tail -n 1 "$DRAIN_REF")"
assert_ok "the skip branch writes no second log line" \
  grep -qiE 'no second log line' <<<"$(sed -n '/^## 1\. Skip an event/,/^## 2\./p' "$DRAIN_REF")"

# --- one event at a time: its own line right after its own first word (T-0246) -
# `shepherd-inbox log … now` stamps the line as it is written, so the write is where
# the first-word clock stops. The first live drain posted three first words and
# then looped back for three lines: all three carried the last post's time, two
# of them overstated by about a minute, and the `inbox` measure of shepherd-metrics
# read the inflated numbers. Both halves are pinned - the loop shape, and the
# why, without which a later editor reads the order as a stylistic preference.
assert_ok "the drain finishes one event before it reads the next" \
  grep -qiE '(one|each|every) event[^.]*before the next' <<<"$log_sec"
assert_ok "and the why: a batched log stamps every line at the last post" \
  grep -qiE '(loop|batch|then wr[a-z]*)[^.]*(overstat|inflat|stamps them all)' <<<"$log_sec"
# The reference's opening names the same shape, so a drain that reads no
# further than `list` still knows it may not batch.
assert_ok "the drain's opening names the per-event shape and points at §4" \
  grep -qiE 'handle them in order[^.]*before the next is read \(§4\)' "$DRAIN_REF"
# The clock definition is the other end of the same rule: if the stop is not
# the post, the ordering in §4 has no reason and drifts back out.
assert_ok "the intents reference stops the first-word clock at the post" \
  grep -qiE 'first word\*?\*?,? stopped when that word is posted' <<<"$targets"
assert_ok "and points at the drain reference for the ordering it forces" \
  grep -qF 'monitor/references/inbox-drain.md' <<<"$targets"

# --- monitor's blocked row: the operator's reply is a pane answer --------------
blocked=$(sed -n "$(grep -n '^| \*\*blocked\*\*' "$MON" | cut -d: -f1)p" "$MON")
assert_ok "the blocked row sends the Linear reply through the trust gate" \
  grep -qF '§ Linear voice' <<<"$blocked"
assert_ok "an operator-authored reply is logged as the operator's word in Linear" \
  grep -qF "Basis: uncited — the operator's word in Linear <session>, <timestamp>" <<<"$blocked"
assert_ok "and unblocks the worker with one line and no pane round-trip" \
  grep -qiE 'operator\*?\*? it is a pane answer[^|]*one R4 line[^|]*no pane round-trip' <<<"$blocked"
assert_ok "and confirms on the thread with a thought" \
  grep -qiE 'pane answer[^|]*`thought` confirming' <<<"$blocked"
assert_ok "a non-operator's reply is input: ephemeral thought, toast with the reply quoted, card stays blocked" \
  grep -qiE 'non-operator\*?\*? it is input[^|]*ephemeral `thought`[^|]*toast[^|]*reply quoted[^|]*stays `blocked`' <<<"$blocked"
assert_ok "and the escalation can carry select options" \
  grep -qF -- '`--select` when the answers are enumerable' <<<"$blocked"
# The drain's awaitingInput is a Log marker, so the row that posts the
# elicitation has to write it, or no reply is ever read as an answer.
assert_ok "the blocked row Logs the marker the drain reads as awaitingInput" \
  grep -qF 'Logged `linear: elicitation posted to <session>`' <<<"$blocked"
assert_ok "and the drain reads that same marker" \
  grep -qF 'Log carries `linear: elicitation posted`' "$DRAIN_REF"

# --- protocols § Linear voice: the eight rules and the trust gate ---------------
voice=$(sed -n '/^## Linear voice/,$p' "$PROTO")
assert_ok "protocols carries § Linear voice" test -n "$voice"
rules=$(sed -n '/^## Linear voice/,/^### The trust gate/p' "$PROTO" | grep -cE '^[0-9]+\. \*\*')
assert_eq "the voice has eight numbered rules" "$rules" "8"
assert_ok "rule 1 writes for the author, with none of shepherd's nouns" \
  grep -qiE '^1\. \*\*Write for the author\.\*\*.*event.s `author`.*no card, lane, worker, tier, watcher or `T-NNNN` in the body' <<<"$voice"
# the operator's fifth ruling of 2026-09-08 lives in rule 1, which already owns how to
# write for the reader; a ninth rule would have split one instruction in two.
assert_ok "rule 1 carries the plain-English ruling" \
  grep -qiE '^1\. .*short sentences, common words, one idea per sentence' <<<"$voice"
assert_ok "rule 3 caps a select at five options, the recommended first" \
  grep -qiE 'recommended option first and no more than five' <<<"$voice"
assert_ok "rule 3 keeps the reply readable as free text" \
  grep -qiE 'reply still read as free text' <<<"$voice"
assert_ok "rule 3 posts one action per DoD command at review" \
  grep -qiE '`action`[^.]*one per DoD command' <<<"$voice"
assert_ok "rule 6 is the footnote" grep -qF -- '— shepherd-<id> · T-NNNN' <<<"$voice"
# A thanks or a non-engineering answer has no card; a footnote that insists on
# T-NNNN there either invents one or breaks the rule.
assert_ok "rule 6 drops the card from the footnote when no card exists" \
  grep -qE '^6\. .*`— shepherd-<id>` alone when no card exists' <<<"$voice"
assert_ok "rule 7 is 150 words, a ceiling and not a target" \
  grep -qiE '^7\. \*\*Length\.\*\* 150 words is the ceiling for any activity, never the target' <<<"$voice"
assert_ok "rule 8 forbids secrets, tokens and outside paths" \
  grep -qiE '^8\. \*\*Never\*\* a secret, a token, or a path outside the repository' <<<"$voice"
gate=$(sed -n '/^### The trust gate/,$p' "$PROTO")
assert_ok "the trust gate compares author.operator, never a name" \
  grep -qiE 'compares `author\.operator`, never a name' <<<"$gate"
assert_ok "operator is the Worker's comparison of the id against its operator list, nothing more" \
  grep -qiE '`operator` is the Worker.s comparison of `id` against its `OPERATOR_LINEAR_USER_IDS`' <<<"$gate"
assert_ok "the gate runs before the body" \
  grep -qiE 'reads `author\.operator` before it reads the body' <<<"$gate"
assert_ok "the gate names every case of the manual §4 on this channel: five bullets" \
  test "$(grep -cE '^- (An \*\*operator-authored|A \*\*non-operator|A reply to a \*\*non-escalation|\*\*Build asks|\*\*Amend and cancel)' <<<"$gate")" -eq 5
assert_ok "an operator's reply to an escalation is a pane answer" \
  grep -qiE '^- An \*\*operator-authored\*\* reply to an escalation[^.]*is a pane answer' <<<"$gate"
assert_ok "a non-operator's reply to an escalation leaves the card blocked" \
  grep -qiE '^- A \*\*non-operator\*\* reply to an escalation is input.*the card stays `blocked`' <<<"$gate"
assert_ok "a reply to a non-escalation question is decided as in the pane, whoever wrote it" \
  grep -qiE '^- A reply to a \*\*non-escalation\*\* question.*shepherd decides as it would in the pane' <<<"$gate"
assert_ok "amend and cancel carry their why" \
  grep -qiE '^- \*\*Amend and cancel\*\*.*a stranger cannot redirect or drop another person.s request' <<<"$gate"
assert_ok "the gate has the fallback for a Worker without author" \
  grep -qiE 'Fallback\.\*\*[^.]*no `author` field[^.]*confirmed in the pane' <<<"$gate"
assert_ok "the gate maps the log's trust column" \
  grep -qiE '`operator` for `operator: true`, `member` for `false` with an id, `unknown` for a null id' <<<"$gate"
# The two boundaries survive verbatim wherever the voice is touched.
assert_ok "protocols keeps the boundary: workers hold no Linear token" \
  grep -qF 'workers hold no Linear token' "$PROTO"
assert_ok "protocols keeps the boundary: the Worker never calls an LLM" \
  grep -qF 'the Worker never calls an LLM' "$PROTO"

# --- the pointers: triage, monitor and retro point at the voice; the manual §3 --
for f in skills/triage/SKILL.md skills/monitor/SKILL.md skills/retro/SKILL.md \
         skills/monitor/references/inbox-drain.md skills/triage/references/linear-intents.md; do
  assert_ok "$f points at protocols § Linear voice" grep -qF '§ Linear voice' "$ROOT/$f"
done
assert_fail "no skill restates the eight voice rules" \
  bash -c "grep -rqE '^[0-9]+\. \*\*Footnote, never headline' '$ROOT/skills'"
s3=$(sed -n '/^## 3\. The loop/,/^## 4\. /p' "$ROOT/manual/shepherd.md")
assert_ok "the manual §3 reads a Linear message for intent first" \
  grep -qiE 'read for \*\*intent\*\* first' <<<"$s3"
assert_ok "the manual §3 names the intents table" grep -qF 'references/linear-intents.md' <<<"$s3"
assert_ok "the manual §3 names the voice" grep -qF '§ Linear voice' <<<"$s3"
assert_ok "the manual §3 keeps every post shepherd's" \
  grep -qF "every post to Linear is shepherd's — workers hold no Linear token" <<<"$s3"
assert_ok "the manual §3 arms through shepherd-watch" grep -qF "$ARM_INBOX" <<<"$s3"
assert_fail "the manual §3 no longer names shepherd-inbox watch as the arming" \
  grep -qF 'picked up by `shepherd-inbox watch`' <<<"$s3"

# --- wake step 8: the arm command, the verdicts, operators=empty once --------------
assert_ok "wake step 8 reads the watcher's verdict line" \
  grep -qiE 'verdict is the first stdout line' <<<"$inbox_step"
assert_ok "wake step 8 explains operators=empty once" \
  grep -qiE 'operators=empty`?[^.]*every author reads as a member[^.]*once' <<<"$inbox_step"

# --- the adapter's unused-surfaces table matches the schema diff (T-0215) --
# The table was titled "New in 0.8.2" and dated events.subscribe and the
# plugin system to that release; both are in the 0.7.4 snapshot verbatim. A
# table that mis-dates a surface sends the next regeneration hunting for a
# change that never happened, so the socket diff is computed here from the
# two snapshots and the table is held to it.
ADAPTER="$ROOT/skills/herdr-adapter/references/v0.8.2.md"
S074="$ROOT/docs/herdr-schema-0.7.4.json"
S082="$ROOT/docs/herdr-schema-0.8.2.json"
schema_methods() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for alt in d["schemas"]["request"]["oneOf"]:
    m = alt.get("properties", {}).get("method", {}).get("const")
    if m:
        print(m)
' "$1" | sort
}
added=$(comm -13 <(schema_methods "$S074") <(schema_methods "$S082"))
removed=$(comm -23 <(schema_methods "$S074") <(schema_methods "$S082"))
assert_eq "the snapshots differ by exactly one removed method" "$removed" "agent.send"
assert_eq "the snapshots differ by seven added methods" \
  "$(printf '%s\n' "$added" | grep -c .)" "7"
# T-0222 moved the table to its own reference file — a regeneration aid, read
# at upgrade time, not at wake — and the recipes file keeps a pointer to it.
SURF="$ROOT/skills/herdr-adapter/references/surfaces-0.8.2.md"
assert_file "the surfaces reference exists" "$SURF"
assert_ok "the recipes file points at the surfaces reference" grep -q 'references/surfaces-0.8.2.md' "$ADAPTER"
assert_ok "the adapter skill names the surfaces reference" grep -q 'references/surfaces-0.8.2.md' "$ROOT/skills/herdr-adapter/SKILL.md"
tbl=$(cat "$SURF")
assert_ok "the table sits under a title that does not date it" test -n "$tbl"
for m in $added; do
  assert_ok "the reference names \`$m\` as added between the pins" \
    grep -qF "\`$m\`" <<<"$tbl"
done
assert_fail "no heading dates the whole table to 0.8.2" \
  grep -q '^#* *New in 0.8.2' "$ADAPTER" "$SURF"
assert_ok "events.subscribe is dated to the 0.7.4 snapshot" \
  grep -qE '^\| `events\.subscribe`[^|]*\| 0\.7\.4' <<<"$tbl"
assert_ok "the 0.7.4 snapshot carries events.subscribe" \
  grep -q '"events.subscribe"' "$S074"
assert_ok "the plugin system is dated to the 0.7.4 snapshot" \
  grep -qE '^\| `herdr plugin.*\| 0\.7\.4 or earlier' <<<"$tbl"
assert_ok "the 0.7.4 snapshot carries plugin.list" grep -q '"plugin.list"' "$S074"
assert_ok "pane.input.set is right-click routing" \
  grep -qE '^\| `pane\.input\.set`.*[Rr]ight-click' <<<"$tbl"
assert_ok "the 0.8.2 snapshot keys pane.input.set on right_click" \
  python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
p = d["schemas"]["request"]["$defs"]["PaneInputSetParams"]["properties"]
sys.exit(0 if "right_click" in p else 1)' "$S082"
# Each row names what settled it. A row without a source is a recollection.
rows=$(grep -cE '^\| `' <<<"$tbl")
cited=$(grep -E '^\| `' <<<"$tbl" | grep -ciE 'snapshot|release notes|herdr\.dev|read 2026')
assert_eq "every table row cites a snapshot, release note or doc" "$cited" "$rows"
# The same claim, wherever else the manual and the reference make it.
assert_fail "the manual §7 no longer says the regeneration added events.subscribe" \
  grep -q 'It also added two surfaces' "$ROOT/manual/shepherd.md"
assert_fail "the Gotchas bullet no longer dates socket push to 0.8.x" \
  grep -q 'gained real push in 0.8.x' "$ADAPTER"

# --- §2 rule 3 says what dispatch does (T-0215) ---------------------------
# The rule said tasks run FIFO within a working copy; dispatch precondition 2
# selects the oldest queued card across the project family. A manual that
# disagrees with the skill it summarises is read as the skill being wrong.
rule3=$(grep -E '^3\. \*\*One active task per working copy' "$ROOT/manual/shepherd.md")
assert_ok "rule 3 is where it was" test -n "$rule3"
assert_ok "rule 3 queues across the project's lanes" \
  grep -q 'across all of its lanes' <<<"$rule3"
assert_ok "rule 3 points at dispatch's selection" grep -q 'precondition 2' <<<"$rule3"
assert_ok "rule 3 cites precondition 5 for the lane pick" \
  grep -q 'the lane (its precondition 5' <<<"$rule3"
assert_fail "rule 3 no longer queues per working copy" \
  grep -q 'Within a working copy, tasks run sequentially' "$ROOT/manual/shepherd.md"

# --- §9 lists only what is still deferred (T-0215) ------------------------
# A deferred-list that names shipped work, or a trigger that already fired,
# tells a reader not to build what already exists.
s9=$(sed -n '/^## 9\. Deferred by design/,$p' "$ROOT/manual/shepherd.md")
assert_ok "§9 is where it was" test -n "$s9"
assert_fail "§9 no longer promises a crash-recovery script" \
  grep -q 'session-start.sh' <<<"$s9"
assert_fail "§9 no longer names the 0.7.5 upgrade as the pending test" \
  grep -q '0\.7\.5' <<<"$s9"
assert_ok "§9 records the upgrade that already happened" \
  grep -q '0.7.4 → 0.8.2 on 2026-08-22' <<<"$s9"
assert_fail "§9 no longer defers Linear intake" grep -q 'Linear/email intake' <<<"$s9"
assert_fail "§9 no longer lists a shipped item" \
  grep -q 'Pane hygiene shipped early' <<<"$s9"
# Budget enforcement landed (T-0220, f556c99); a §9 that still calls it carded
# tells a reader the checkpoint does not exist yet.
assert_fail "§9 no longer names budget enforcement as deferred" \
  grep -q 'carded as T-0220' <<<"$s9"

# --- a verified done invokes retro, whole (T-0215) ------------------------
# monitor's done row named a "retro-lite" that no skill defines, and the path
# it improvised skipped metrics and the decisions' Outcome backfill (30 of 197
# done cards have no metrics line). One close-out, owned by one skill.
MONITOR="$ROOT/skills/monitor/SKILL.md"
assert_fail "retro-lite is defined nowhere, so it is named nowhere" \
  grep -rq 'retro-lite' "$ROOT/manual/shepherd.md" "$ROOT/skills"
done_row=$(grep -E '^\| \*\*done\*\*' "$MONITOR")
assert_ok "the done row is where it was" test -n "$done_row"
assert_ok "the done row hands the close-out to retro" \
  grep -q '→ \*\*retro\*\*' <<<"$done_row"
assert_ok "the done row names the Outcome backfill retro owns" \
  grep -q 'Outcome:' <<<"$done_row"

# --- retro closes all three terminal states, each by its own rule (T-0215) -
# triage §5 routes a cancel through retro with verdict abandoned, and retro
# wrote only done|failed — so a merely cancelled task closed as failed and
# banked a guardrail against nothing. `failed` itself had no written rule and
# 0 uses in 212 cards; the rule is that monitor alone produces it.
assert_ok "retro's release step writes abandoned" \
  grep -q 'shepherd-card transition T-NNNN done|failed|abandoned' "$RETRO"
assert_ok "abandoned closes without the failure guardrail or a retry" \
  grep -qiE 'abandoned.*(minus|without|no)\b[^.]*(guardrail|toast)' "$RETRO"
assert_ok "retro says where failed comes from" grep -q 'retry ceiling' "$RETRO"
assert_ok "a cancel is never closed as failed" \
  grep -qiE 'cancel[a-z]*[^.]*(not|never)[^.]*fail' "$RETRO"
assert_ok "the manual §5 sends the verdict rule to retro" \
  grep -q 'terminal states are verdicts' "$ROOT/manual/shepherd.md"
# The worktree's fate is written once, in retro; §5 already says "cleared
# (not deleted)" and points here. A second copy of the removal rule drifts.
assert_ok "retro says the worktree stays" grep -qi 'worktree stays' "$RETRO"
assert_ok "removal waits for the operator" \
  grep -qE 'worktree remove[^.]*the operator' "$RETRO"
homes=$(grep -rl 'worktree remove' "$ROOT/manual/shepherd.md" "$ROOT/skills" | wc -l)
assert_eq "the removal rule has one home across the manual and the skills" "$homes" "1"

# --- the lane procedure is a script; step 0 is the call (T-0215, T-0257) -----
# A worktree is detached and nothing pulls it forward: wt2 sat at a stale
# commit until its worker noticed. Creation assumed an origin, which the
# self-repo pattern does not have (T-0129). Both rules lived as prose in step 0
# and were duplicated by the incident, so `shepherd-lane` owns them
# now and `tests/test-lane-prepare.sh` proves each branch of them.
# What is pinned here is the seam: the skill teaches every stop the script can
# reach, and no copy of the procedure has grown back beside it.
LP="$ROOT/bin/shepherd-lane"
step0=$(sed -n '/^0\. \*\*Prepare the lane\*\*/,/^1\. \*\*Pane\*\*/p' "$DISPATCH")
assert_ok "step 0 is where it was" test -n "$step0"
assert_ok "step 0 is the call"     grep -qF 'shepherd-lane T-NNNN' <<<"$step0"
assert_ok "and offers the dry run" grep -qF 'shepherd-lane T-NNNN --dry-run' <<<"$step0"
# Every stop the script can print is a row a shepherd can read. The list is
# DERIVED from the script's own hold/judge calls, so a new stop cannot ship
# without its row; the four mechanical failures are allowed to report
# themselves, since a shepherd reads the git error rather than a rule.
lp_stops() {
  grep -oE '(hold|judge) "[a-z][a-z ]*' "$LP" \
    | sed -E 's/^hold "/HOLD /; s/^judge "/JUDGE /; s/ +$//' \
    | grep -vE '(install|worktree add|checkout|seed copy) failed' | sort -u
}
assert_ok "the script has stops to derive" test -n "$(lp_stops)"
while IFS= read -r v; do
  assert_ok "step 0's table carries \`$v\`" grep -qF "$v" <<<"$step0"
done < <(lp_stops)
for v in 'READY <lane>' 'REFUSED' 'ERROR <why>'; do
  assert_ok "step 0's table carries \`$v\`" grep -qF "$v" <<<"$step0"
done
assert_ok "the tip rule survives the move" \
  grep -qF 'the remote-tracking ref at or ahead of the local branch, the local when strictly ahead' <<<"$step0"
assert_ok "and the self-repo is why the local branch can win" grep -q 'self-repo' <<<"$step0"
assert_ok "step 0 still says why a reused lane is reset at all" \
  grep -qF 'A detached worktree never moves on its own' <<<"$step0"
assert_ok "and why --detach is required" \
  grep -qF 'unable to check out a branch the base copy holds' <<<"$step0"
assert_ok "a dirty lane is never reset over, and both reasons survive" \
  grep -qE "never reset over it — the work would ride onto a different base, and the directory is the operator's call" <<<"$step0"
assert_ok "a failed creation takes its own worktree back out" \
  grep -qF 'takes its own worktree back out' <<<"$step0"
assert_ok "and says why: a leftover the next run would refuse" \
  grep -qF 'the next run would refuse as a leftover' <<<"$step0"
assert_ok "the lane script takes no lock; only the ## Clones row is locked" \
  grep -qE 'seed and the install all run \*\*outside\*\* any' <<<"$step0"
assert_ok "and both halves of \"whichever exists when only one does\" are named" \
  grep -qF 'no `origin`, or no local branch yet' <<<"$step0"
assert_ok "a repo with no origin is an answer, not the failed-fetch stop" \
  grep -qF 'No `origin` at all is the other answer' <<<"$step0"
assert_ok "the seed and install defaults are still readable here" \
  grep -qF 'clone-seed: .dev.vars .env .env.local' <<<"$step0"
assert_ok "and `none` on either is not the default" grep -qF 'the lane gets neither' <<<"$step0"
assert_ok "step 0 asks shepherd for the ## Clones row the script will not write" \
  grep -qF 'row-needed: <clone-id> <path> write|rewrite' <<<"$step0"
assert_ok "the row is written under the card lock and committed" \
  grep -qF '<slug>: clone <clone-id> created' <<<"$step0"
assert_ok "a card lacking the section gets it beside its first row, not instead of another" \
  grep -qF 'never in place of another section' <<<"$step0"
assert_ok "and a rewrite is what a pruned-and-rebuilt lane earns" \
  grep -qF 'pruned and rebuilt' <<<"$step0"
# The procedure is gone from the skill, not copied into it.
assert_fail "step 0 no longer types the tip resolution" grep -qF 'merge-base --is-ancestor' <<<"$step0"
assert_fail "nor the dirty test"                        grep -qF 'status --porcelain' <<<"$step0"
assert_fail "nor the reset"                             grep -qF 'checkout --detach' <<<"$step0"
assert_fail "nor the worktree creation"                 grep -qF 'worktree add --detach <parent-path>-wt<N>' <<<"$step0"
assert_eq "and no skill anywhere resolves a tip by hand" \
  "$(grep -rl 'merge-base --is-ancestor' "$ROOT/skills" 2>/dev/null | wc -l)" "0"

# The script carries the procedure the skill stopped carrying, and its usage
# line is what step 0 quotes, so a renamed flag shows up here first.
assert_file "shepherd-lane exists" "$LP"
assert_ok "it is executable"                 test -x "$LP"
assert_ok "its header carries the usage step 0 quotes" \
  grep -qF 'shepherd-lane T-NNNN [--dry-run] [--tip <ref>]' "$LP"
assert_ok "the local ref is verified before it is trusted" grep -qF 'rev-parse --verify --quiet' "$LP"
assert_ok "the tip choice is the ancestor test"            grep -qF 'merge-base --is-ancestor' "$LP"
assert_ok "a reused lane is checked clean"                 grep -qF 'status --porcelain' "$LP"
assert_ok "and reset detached"                             grep -qF 'checkout --detach' "$LP"
assert_ok "creation adds a detached worktree"              grep -qF 'worktree add --detach' "$LP"
assert_ok "a row whose path is gone is pruned first"       grep -qF 'worktree prune' "$LP"
# The one thing git will not do for us, and the reason the check exists at all.
assert_ok "the lane path is tested before creation" grep -qF '[ ! -e "$LANE_PATH" ]' "$LP"
assert_ok "and the comment says why: git adopts an existing directory" \
  grep -qF 'ADOPTS an existing directory' "$LP"

# --- the two card shapes live in templates, not in whoever writes them (T-0215)
# onboard's stub step enumerated the registry card's fields from memory, and
# the four cards missing working-agreement: are what that produces
# (centralised-identity, eo-tech, shepherd-deck, test-hono, 2026-09-02).
# shepherd-init writes only index rows, never cards — the card shape
# has one home now, and writers copy it.
REG_TPL="$ROOT/templates/registry-card.md"
assert_file "the registry-card template exists" "$REG_TPL"
for f in path stack test dev-branch working-agreement preview onboarded active-task \
         pane clone-seed install keywords; do
  assert_ok "registry-card template carries $f:" grep -q "^$f:" "$REG_TPL"
done
for s in 'Product' 'Context notes' 'Gotchas' 'History' 'Clones'; do
  assert_ok "registry-card template carries ## $s" grep -q "^## $s\$" "$REG_TPL"
done
assert_ok "the Clones section carries its table header" \
  grep -q '^| clone-id | path | active-task | pane |$' "$REG_TPL"
assert_ok "the manual §5 names the same five permanent sections" \
  grep -q '`## Product`, `## Context notes`, `## Gotchas`, `## History`, `## Clones` are permanent' "$ROOT/manual/shepherd.md"
# The task card carries the section a handoff fills and the line dispatch
# reads for blockers, so neither is invented per card.
assert_ok "task-card template carries ## Handoff" grep -q '^## Handoff$' "$CARD_TPL"
assert_ok "task-card template carries Depends on:" grep -q '^Depends on:' "$CARD_TPL"

# --- onboarding asks the question dispatch's lane gate reads (T-0215) ------
# Lane gate 3 reads ## Gotchas and ## Context notes and treats silence as
# safe, so a project nobody asked reads as safe by omission. The interview
# asks, and the answer lands under one label the gate can find.
ONBOARD="$ROOT/skills/onboard/SKILL.md"
assert_ok "onboard stubs the card from the template" \
  grep -q 'templates/registry-card.md' "$ONBOARD"
assert_ok "the interview always asks about two live working copies" \
  grep -qi 'two live working copies' "$ONBOARD"
assert_ok "the answer lands under a fixed label" \
  grep -q 'Parallel lanes: safe' "$ONBOARD"
assert_ok "the registry template carries the same label" \
  grep -q '^- Parallel lanes:' "$REG_TPL"
assert_ok "dispatch's gate still reads the two sections the label lands in" \
  grep -qE '## Gotchas.*## Context notes' "$DISPATCH"

# --- preview: the field, the question that fills it, the DoD it buys (T-0242) -
# A build-with-preview ask from Linear had no rule to answer by: no card said
# whether the project can show a branch running before it merges, and
# onboarding never asked. The field answers it once, per project, honestly —
# three of the projects that exist cannot preview at all.
preview_ln=$(grep -m1 '^preview:' "$REG_TPL")
assert_ok "the template offers the no-preview shape with its reason" \
  grep -qF 'none — <why>' <<<"$preview_ln"
assert_ok "and the mechanism shape, which names who produces it" \
  grep -qF '<mechanism> — <URL pattern> — by <push|worker|shepherd>' <<<"$preview_ln"
# Each `by` value has to name a different producer, or a card cannot be filled
# in from the template alone: push runs nothing, the worker runs it in the
# task, shepherd runs it at verification off its allow list.
assert_ok "by push means the platform builds it and nobody runs a command" \
  grep -qiE '`push`, the platform builds it from the pushed branch and nobody runs a command' <<<"$preview_ln"
assert_ok "by worker means the worker runs a preview-only command in the task" \
  grep -qiE '`worker`, the worker runs a preview-only command' <<<"$preview_ln"
assert_ok "by shepherd means shepherd runs the deploy at verification, reading no code" \
  grep -qiE '`shepherd`,[^.]*shepherd runs the one deploy command at verification[^.]*reading no code' <<<"$preview_ln"
# The URL shapes are Cloudflare's, so rule 11 fires: a live source with its
# read date, not a shape remembered.
assert_ok "the URL shapes are cited to Cloudflare with a read date" \
  grep -qE 'developers\.cloudflare\.com/(workers/configuration/previews|pages/configuration/preview-deployments).*read 2026-09-07' <<<"$preview_ln"
# A `worker` or `shepherd` mechanism is a command somebody has to run, and the
# field is the only place it is written down — the two confirmed facts of
# T-0242 (a Pages deploy, a versions-list lookup) have nowhere else to live.
assert_ok "the command lives in the mechanism when someone has to run it" \
  grep -qiE '`worker` or `shepherd`.*`<mechanism>` carries the command' <<<"$preview_ln"
# `none` is a real answer, and the field is the one place a promotion could be
# passed off as a preview (Saket, 2026-09-07).
assert_ok "a promotion is never dressed up as a preview" \
  grep -qiE 'promotion.*never.*preview' <<<"$preview_ln"
assert_ok "no build pipeline is examined to manufacture one" \
  grep -qiE 'build pipeline is examined' <<<"$preview_ln"
# The template says what the field means; how a Linear ask is answered from it
# is triage's, and restating it here would be the fourth home of one sentence
# (docs/writing-for-agents.md § Pruning).
assert_ok "the template points at triage rather than restating its procedure" \
  grep -qiE "Linear ask[^#]*is triage's, not this line" <<<"$preview_ln"
assert_fail "and does not carry triage's answering procedure" \
  grep -qiE 'answered in its first word|close-out says where the change now lives' <<<"$preview_ln"

# Onboarding is where the field gets filled, so the interview has to ask —
# silence would leave every future project unset, the way the lane gate was.
onboard_deliv=$(sed -n '/^1\. Append `## Onboarding report`/,/^2\. Create or update/p' "$ONBOARD")
assert_ok "the interview asks whether a branch can be seen running before it merges" \
  grep -qiE 'seen running before it merges' <<<"$onboard_deliv"
assert_ok "it offers the three answers the field takes, none among them" \
  grep -qiE 'builds a preview from the push[^.]*preview-only command[^.]*or nothing does' <<<"$onboard_deliv"
assert_ok "and asks for the URL and who runs the command, so the by value can be filled" \
  grep -qiE 'URL it appears at and who runs the command' <<<"$onboard_deliv"
assert_ok "the interview says a promotion is not a preview" \
  grep -qiE 'promotion to a shared environment is not a preview' <<<"$onboard_deliv"
onboard_bank=$(sed -n '/^5\. \*\*Bank the answers\*\*/,/^6\. \*\*Worker phase 2/p' "$ONBOARD")
assert_ok "banking names preview: among the fields it writes" \
  grep -qF '`preview:`' <<<"$onboard_bank"
assert_ok "and points at the two shapes the template defines" \
  grep -qF 'by <push|worker|shepherd>' <<<"$onboard_bank"

# Triage turns the field into the Brief. The DoD line is shepherd-checkable by
# construction — an HTTP fetch shepherd runs — because "preview works" is not.
tri_prev=$(grep -m1 -- '- \*\*Build-with-preview' "$TRIAGE")
assert_ok "triage carries the build-with-preview principle" test -n "$tri_prev"
assert_ok "it reads the registry field before writing the DoD" \
  grep -qiE "registry card.s \`preview:\` before the DoD" <<<"$tri_prev"
assert_ok "the DoD line is one shepherd can check alone: a fetch, and what it shows" \
  grep -qF 'A preview of the branch is reachable at `<URL>` (HTTP 200, shepherd fetches it) and shows `<the change>`' <<<"$tri_prev"
assert_ok "only a worker mechanism puts a command in the Brief" \
  grep -qiE '`worker` puts the preview command in the Brief' <<<"$tri_prev"
# A DoD line the worker cannot make true is a block or a deploy, and a deploy
# is an escalation — so the Brief has to say the push is where the worker stops.
assert_ok "under push and shepherd the Brief says the worker's part ends at the push" \
  grep -qiE "under \`push\` and \`shepherd\` the worker.s part ends at the push" <<<"$tri_prev"
assert_ok "and shepherd, not the worker, resolves and fetches the URL at verification" \
  grep -qiE 'shepherd resolves the URL and fetches it at verification' <<<"$tri_prev"
assert_ok "because a worker running that deploy would be escalating past §4" \
  grep -qiE 'a worker that tried would be running a deploy' <<<"$tri_prev"
assert_ok "preview: none is answered in the first word, not silently dropped" \
  grep -qiE '`preview: none`[^.]*first word' <<<"$tri_prev"
assert_ok "and the none card is a plain build whose close-out says where it now lives" \
  grep -qiE 'plain build whose close-out says where the change now lives' <<<"$tri_prev"
assert_ok "triage repeats neither dodge: no promotion-as-preview, no pipeline hunt" \
  grep -qiE 'promotion.*never.*preview.*build pipeline is examined' <<<"$tri_prev"
# The DoD line has one home. Retro reads the field for the `Preview` label
# (its own pins above); nothing else restates the sentence.
assert_eq "the preview DoD line lives only in triage" \
  "$(grep -rlF 'HTTP 200, shepherd fetches it' "$ROOT/skills" 2>/dev/null | wc -l)" "1"
# The three `by` values are one vocabulary: the template defines them and
# triage spends them, so a rename in one file fails here rather than in a Brief.
for v in push worker shepherd; do
  assert_ok "by value $v is known to both the template and triage" \
    bash -c "grep -qF '\`$v\`' <<<\"\$(grep -m1 '^preview:' '$REG_TPL')\" && grep -qF '\`$v\`' <<<\"\$(grep -m1 -- '- \*\*Build-with-preview' '$TRIAGE')\""
done

# --- the suite runs the spec §12 drill ---------------------------------------
# shepherd-drill needs no herdr (every liveness probe goes through the
# SHEPHERD_TEST_HOOKS overrides), so nothing justified leaving it manual.
assert_ok "run.sh runs shepherd-drill" grep -q 'shepherd-drill' "$ROOT/tests/run.sh"
assert_ok "shepherd-drill says the suite runs it" grep -q 'run.sh' "$ROOT/bin/shepherd-drill"

# --- the canary and the meter are reachable from the manual ------------------
# A script nobody is told to run is a script nobody runs. Each of these three is
# cited by exactly one procedure, and the citation is what makes it real.
assert_ok "the adapter's regeneration step names the live canary" \
  grep -q 'shepherd-smoke' "$ROOT/skills/herdr-adapter/SKILL.md"
assert_fail "and no longer says the canary does not exist" \
  grep -q 'once it exists in M2' "$ROOT/skills/herdr-adapter/SKILL.md"
assert_ok "init installs the status line" \
  grep -q 'shepherd-statusline' "$ROOT/skills/init/SKILL.md"
assert_ok "wake step 10 self-tests the meter" \
  grep -q 'decide --self-test' "$ROOT/skills/wake/SKILL.md"
assert_ok "CLAUDE.md sends a degraded meter to the self-test" \
  grep -q 'decide --self-test' "$ROOT/manual/shepherd.md"

# init's steps stay numbered 1..N with no gaps — inserting the install
# step renumbers everything after it.
nums=$(sed -n '/^## Steps/,/^## Hard lines/p' "$ROOT/skills/init/SKILL.md" \
         | grep -oE '^[0-9]+\.' | tr -d '.')
expected=$(seq 1 "$(printf '%s\n' "$nums" | grep -c .)")
assert_eq "init steps are numbered 1..N with no gaps" \
  "$(printf '%s\n' "$nums")" "$(printf '%s\n' "$expected")"

# --- worker observation is one program (T-0214), shipped by the plugin (T-0267)
# The seven worker hooks used to be merged into ~/.claude/settings.json by
# init-shepherd, once per machine, by hand. They now ship in hooks/hooks.json and
# fire wherever the plugin is enabled, so the manifest — not a skill's prose — is
# what these assertions read. The skill must NOT still tell anyone to register
# them: two copies of the same handler both run, and the plugin's copy stays
# separate from a settings copy (https://code.claude.com/docs/en/hooks#hook-locations,
# read 2026-09-10).
INIT="$ROOT/skills/init/SKILL.md"
HOOKSJSON="$ROOT/hooks/hooks.json"
assert_ok "hooks.json is valid JSON" python3 -c "import json;json.load(open('$HOOKSJSON'))"
for ev in SessionStart Stop Notification PreToolUse PermissionRequest PermissionDenied StopFailure SessionEnd; do
  assert_ok "hooks.json registers $ev" grep -q "\"$ev\"" "$HOOKSJSON"
done
assert_ok "hooks.json registers the event hook script" grep -q 'worker-event.sh' "$HOOKSJSON"
assert_ok "hooks.json's Notification matcher carries the twelve documented kinds" \
  grep -q 'permission_prompt|idle_prompt|auth_success|elicitation_dialog|elicitation_url_dialog|elicitation_complete|elicitation_response|agent_needs_input|agent_completed|quota_auto_resume_fired|quota_auto_resume_stale|quota_auto_resume_disabled' "$HOOKSJSON"
# Exec form: `args` set means Claude Code spawns `command` directly with no
# shell, so no quoting of the plugin path can go wrong.
assert_ok "every handler is exec form" \
  python3 -c "
import json,sys
h=json.load(open('$HOOKSJSON'))['hooks']
bad=[(e,x) for e,l in h.items() for m in l for x in m['hooks'] if 'args' not in x]
sys.exit(1 if bad else 0)"
assert_ok "every handler path is \${CLAUDE_PLUGIN_ROOT}-relative" \
  python3 -c "
import json,sys
h=json.load(open('$HOOKSJSON'))['hooks']
bad=[x['command'] for l in h.values() for m in l for x in m['hooks']
     if not x['command'].startswith('\${CLAUDE_PLUGIN_ROOT}/hooks/')]
sys.exit(1 if bad else 0)"
assert_ok "every handler script exists and is executable" \
  python3 -c "
import json,os,sys
h=json.load(open('$HOOKSJSON'))['hooks']
paths=[x['command'].replace('\${CLAUDE_PLUGIN_ROOT}','$ROOT') for l in h.values() for m in l for x in m['hooks']]
sys.exit(0 if all(os.access(p, os.X_OK) for p in paths) else 1)"
assert_ok "SessionStart covers the four re-fire sources as well as startup" \
  grep -q 'startup|resume|clear|compact|fork' "$HOOKSJSON"
assert_fail "the init skill no longer registers hooks by hand" \
  grep -q 'Register hooks user-globally' "$INIT"
assert_ok "and says why there is nothing to merge" \
  grep -q 'They ship in this plugin' "$INIT"
assert_ok "the init skill still refuses to touch that file's hooks" \
  grep -q "never touches that file's \`hooks\`" "$INIT"
assert_ok "ledger/watchers/ is runtime state the instance skeleton never commits" \
  grep -qx 'ledger/watchers/' "$ROOT/templates/instance/.gitignore"
# Every file the hooks and the watcher reach for must exist in the plugin: a
# missing one is a hook that records nothing, silently.
for f in hooks/worker-event.sh hooks/lib/shepherd_status.py hooks/lib/run-hook.sh bin/shepherd-watch bin/shepherd-status; do
  assert_file "$f exists" "$ROOT/$f"
done
for f in hooks/worker-stop.sh hooks/worker-notify.sh hooks/worker-event.sh hooks/worker-git-guardrail.sh; do
  assert_ok "$f never swallows its whole body" bash -c "! grep -q '2>/dev/null || true\$' '$ROOT/$f'"
done

# --- the recipe lives in the script; the skills call it (T-0214) -------------
# Every skill that used to restate the eight-line grep loop now calls
# shepherd-watch. A skill that still carries the loop is a recipe that will
# be re-typed by hand, which is how three watchers died.
REF="$ROOT/skills/herdr-adapter/references/v0.8.2.md"
R5=$(sed -n '/^## R5 /,/^## R6 /p' "$REF")
assert_ok "R5 names shepherd-watch arm" grep -q 'shepherd-watch arm T-NNNN' <<<"$R5"
assert_ok "R5 keeps the herdr stall line" grep -q 'herdr agent wait "\$pid" --until blocked' <<<"$R5"
assert_ok "R5 documents the verdict words" grep -q 'ARMED-ALREADY' <<<"$R5"
assert_ok "R5 keeps the never-pipe rule" grep -q 'NEVER pipe' <<<"$R5"
assert_ok "R5 carries the permission_request confirm step" grep -q 'permission_request' <<<"$R5"
assert_ok "R5 says GONE is re-probed" grep -qi 're-probe\|three probes\|3 probes' <<<"$R5"
assert_ok "R5's table carries the stall-only exit 7" grep -q '^| 7 | `STALL-UNAVAILABLE`' <<<"$R5"
if grep -q 'sh -c .while :; do' <<<"$R5"; then fail "R5 no longer restates the grep loop" "found the loop"; else ok "R5 no longer restates the grep loop"; fi
R3=$(sed -n '/^## R3 /,/^## R4 /p' "$REF")
assert_fail "R3's launch line no longer prepends a PATH" \
  grep -q 'PATH=' <<<"$R3"
assert_ok "…because the plugin's bin/ is already on the Bash tool's PATH" \
  grep -qi "plugin's \`bin/\` is on the Bash tool" <<<"$R3"
assert_ok "R3 dates that measurement" grep -q '2026-09-10' <<<"$R3"
assert_ok "R3 says what a machine without the plugin falls back to" \
  grep -qi 'sentinel' <<<"$R3"
assert_ok "dispatch step 5 arms through shepherd-watch" grep -q 'shepherd-watch arm T-NNNN' "$DISPATCH"
assert_ok "dispatch names the PATH prepend as what reaches shepherd-status" grep -q 'shepherd-status' "$DISPATCH"
MON="$ROOT/skills/monitor/SKILL.md"
assert_ok "monitor wakes on shepherd-watch's verdict" grep -q 'shepherd-watch' "$MON"
for word in STATUS BLOCKED GONE TIMEOUT ARMED-ALREADY STALL-UNAVAILABLE; do
  assert_ok "monitor knows the verdict $word" grep -q "$word" "$MON"
done
assert_ok "monitor's evidence step names the new events" grep -q 'session_end' "$MON"
assert_ok "monitor's evidence step names hook_error" grep -q 'hook_error' "$MON"
# The .err sidecar is written in four places and read nowhere until monitor
# says to read it. An unwritable status file is the one failure no watcher can
# announce - no record lands, so nothing fires, recovery falls to the heartbeat
# and the operator is never told why. The sidecar carries the reason.
assert_ok "monitor's evidence step reads the .err sidecar" \
  grep -q 'T-NNNN\.jsonl\.err' "$MON"
assert_ok "…and says when to look at it" \
  grep -qiE 'gained nothing|nothing new|no new (record|line)' "$MON"
# A record in T-NNNN's file that names another task is not T-NNNN's claim:
# a session whose env pair disagreed wrote it (T-0223). The hooks now refuse
# the write and shepherd-watch never wakes on one; the ladder's own read has to
# filter the same way, or the tail can still count a stray line as the claim.
assert_ok "monitor's evidence step counts only this task's records" \
  grep -q 'naming another task is an anomaly' "$MON"
# …and agrees with the watcher it cites: shepherd-watch rejects a record whose task
# is another's, never one with no task field (status_py's rule 0, for files
# written before the field existed). A ladder that discarded those would
# disagree with the process that wakes it.
assert_ok "…and keeps the records that carry no task field" \
  grep -qE 'no `task` field at all still counts' "$MON"
# arm replaces a live watcher, so the replaced background task exits 143 with
# an empty stdout. Monitor reaches that through its own exit-7 instruction, and
# without a row for it a non-wake reads as a wake with no verdict.
assert_ok "monitor knows 143 with an empty stdout is a replaced watcher, not a wake" \
  grep -qiE 'exit 143 with an empty stdout' "$MON"
# The same 143 also arrives when an external signal (OOM, a stray pkill) kills
# the watcher with no replacement arming - assuming "replacement" without
# checking leaves that task unwatched until the next session start.
assert_ok "monitor's 143 guidance confirms via shepherd-watch list before assuming a replacement" \
  grep -q 'shepherd-watch list T-NNNN' "$MON"
assert_ok "monitor's invariant re-arms through shepherd-watch" \
  grep -q 'shepherd-watch arm T-NNNN' <<<"$(sed -n '/^## Invariants/,$p' "$MON")"
assert_ok "monitor no longer says re-arm R5" bash -c "! grep -q 're-arm R5' '$MON'"
WAKE8=$(sed -n '/^### 8\. /,/^### 9\. /p' "$ROOT/skills/wake/SKILL.md")
assert_ok "wake step 8 re-arms through shepherd-watch rearm" grep -q 'shepherd-watch rearm T-NNNN' <<<"$WAKE8"
assert_ok "wake step 8 lists first" grep -q 'shepherd-watch list' <<<"$WAKE8"
assert_ok "wake step 8 knows exit 4" grep -q 'ARMED-ALREADY' <<<"$WAKE8"
# The inbox watcher is a separate arming that lives in the same step, folded
# into shepherd-watch as the `inbox` kind (T-0237/T-0238); step 8 must still carry it.
assert_ok "wake step 8 still arms the inbox watcher" grep -q 'shepherd-watch arm inbox' <<<"$WAKE8"
for f in skills/dispatch/SKILL.md skills/monitor/SKILL.md skills/wake/SKILL.md skills/retro/SKILL.md; do
  assert_ok "$f does not restate the count anchor" bash -c "! grep -q 'grep -c' '$ROOT/$f'"
done

# Command first, sentinel fallback — in the one place a worker reads (the
# template) and the one place shepherd reads (§6), agreeing.
proto=$(sed -n '/^### Status protocol/,/^## Log/p' "$ROOT/templates/task-card.md")
assert_ok "the template names the status command" grep -q 'shepherd-status done|blocked|failed|working' <<<"$proto"
first=$(grep -n 'shepherd-status\|SHEPHERD: done' <<<"$proto" | head -n 1)
assert_ok "the template puts the command before the sentinel" grep -q 'shepherd-status' <<<"$first"
assert_ok "the template keeps the sentinel as the fallback" grep -q 'SHEPHERD: done|blocked|failed|working — <one short line>' <<<"$proto"
assert_ok "the template says when to fall back" grep -qi 'not found\|fails' <<<"$proto"
# …and that the command is RUN, not written. T-0244 ended a finished turn by
# printing the line as display text and its done work waited two heartbeats:
# "report status with the command, as the last thing you do" reads, to a worker
# summarising its own turn, as *write the line last*. The imperative sits under
# the bare command where the misreading happens, and the second half names the
# shape that is not a run — without naming what the hook does with one, because
# a fallback that gets advertised gets used.
assert_ok "the template tells the worker to run the command" \
  grep -q 'Run it — a Bash call whose answer you read' <<<"$proto"
assert_ok "the template says a written copy is not a run" \
  grep -q 'written into your message is not a run' <<<"$proto"
assert_fail "the template does not advertise the printed claim path" \
  grep -qiE 'claim_source|printed' <<<"$proto"
assert_ok "the manual §6 names the status command" grep -q 'shepherd-status' "$ROOT/manual/shepherd.md"
assert_ok "the manual §6 names the watcher script" grep -q 'shepherd-watch' "$ROOT/manual/shepherd.md"
assert_ok "the manual §6 lists the recorded events" grep -q 'permission_request|permission_denied|stop_failure|session_end' "$ROOT/manual/shepherd.md"
# …and says WHICH file records them. "The same file" put the nearer antecedent
# on templates/task-card.md, which records none of this.
assert_ok "the manual §6 names the status file, not 'the same file'" \
  grep -q 'ledger/status/T-NNNN.jsonl` also records' "$ROOT/manual/shepherd.md"
assert_ok "the manual §6 names the .err sidecar" \
  grep -q 'ledger/status/T-NNNN.jsonl.err' "$ROOT/manual/shepherd.md"

# --- the budget is a checkpoint, not a Log line (T-0220 item 1) --------------
# 17 of the first 212 cards ran past budget and every overrun was accepted ad
# hoc. The row has to demand a scope decision and say what happens when none
# arrives, or the budget field measures nothing. The tail is bounded up front
# too: the one shape that always overruns is split at triage.
MONITOR="$ROOT/skills/monitor/SKILL.md"
TRIAGE="$ROOT/skills/triage/SKILL.md"
DECOMP="$ROOT/skills/triage/references/decomposition.md"
overrun=$(grep '^| \*\*overrun\*\*' "$MONITOR")
assert_ok "monitor has an overrun row" test -n "$overrun"
assert_ok "the overrun row demands a scope decision" grep -q 'scope decision' <<<"$overrun"
assert_ok "the overrun row names the three options" \
  grep -qE 'finish within a stated bound.*split the rest.*hand off' <<<"$overrun"
for l in 'overrun: bound accepted' 'overrun: split' 'overrun: handoff'; do
  assert_ok "the overrun row names the decision line \`$l\`" grep -qF "$l" <<<"$overrun"
done
assert_ok "the nudge is logged under a fixed label" grep -q 'overrun: nudged' <<<"$overrun"
assert_ok "a bound becomes the next checkpoint and budget: stays" \
  grep -qE 'budget:. stays' <<<"$overrun"
assert_ok "the second wake without a decision escalates" grep -q 'overrun: escalated' <<<"$overrun"
assert_fail "the overrun row no longer defers enforcement to M2" \
  grep -q 'enforcement lands in M2' <<<"$overrun"
assert_ok "the overrun row carries its why" \
  grep -q 'docs/incidents/2026-09-02-introspection-measures.md' <<<"$overrun"
assert_ok "triage's sizing table splits the greenfield shape up front" \
  grep -qiE 'greenfield.*split' "$TRIAGE"
assert_ok "triage names the ~8-task threshold" grep -q '~8 tasks' "$TRIAGE"
assert_fail "triage no longer sizes that shape as one L" \
  grep -q 'never an M (T-0093' "$TRIAGE"
assert_ok "decomposition knows the shape that is never one card" \
  grep -q 'never one card' "$DECOMP"
assert_ok "decomposition carries the same threshold" grep -q '~8 tasks' "$DECOMP"

# --- a worker's questions come as one round, pre-answered where Product can (T-0220 item 2)
# 83 % of blocks waited for a human yes, and Briefs read ## Gotchas 93 times
# against ## Product 3. Three surfaces: triage pre-answers, the template tells
# the worker to batch, monitor holds the line when a worker does not.
CARD_TPL="$ROOT/templates/task-card.md"
assert_ok "triage pre-answers from ## Product" grep -qiE 'pre-answer[^.]*## Product' "$TRIAGE"
assert_ok "the Brief cites the Product line it relied on" grep -q 'Product: <line>' "$TRIAGE"
assert_ok "an unanswerable question goes to the operator at triage, not to the worker" \
  grep -qiE 'cannot answer.*(§3|frontier|the operator)' "$TRIAGE"
constraints=$(sed -n '/^### Constraints/,/^### Out of scope/p' "$CARD_TPL")
assert_ok "the template tells the worker to ask in one round" grep -q 'Ask in one round' <<<"$constraints"
assert_ok "each question carries a recommendation" grep -q '➡️' <<<"$constraints"
assert_ok "the round ends the turn blocked" grep -q 'end that turn `blocked`' <<<"$constraints"
assert_ok "the template states what a pause costs" grep -q 'five pauses cost five' <<<"$constraints"
blocked=$(grep '^| \*\*blocked\*\*' "$MONITOR")
assert_ok "monitor answers a worker's questions as one round" grep -q 'one numbered reply' <<<"$blocked"
assert_ok "monitor points at the bullet the worker read" grep -q 'Ask in one round' <<<"$blocked"

# --- a decision cites, or says why not (T-0220 item 3) ----------------------
# 15.4 % of entries cited a live source (metrics, 2026-09-02). A Basis that
# may be a recollection cannot be audited; `uncited — <reason>` makes the gap
# a number shepherd-metrics can count, so the shape has to be one the counter reads
# as NOT cited — and the cited example has to be one it reads as cited.
DEC_TPL="$ROOT/templates/decision.md"
assert_file "the decision template exists" "$DEC_TPL"
labels=$(grep -oE '^\*\*(Context|Options considered|Decision|Basis|Confidence|Outcome)\.\*\*' "$DEC_TPL" \
           | tr -d '*.' | tr '\n' ' ')
assert_eq "the template carries the six labels in order" \
  "$labels" "Context Options considered Decision Basis Confidence Outcome "
assert_ok "the template shows the uncited shape" grep -q 'uncited — ' "$DEC_TPL"
assert_ok "the manual §4 names the template" grep -q 'templates/decision.md' "$ROOT/manual/shepherd.md"
assert_ok "the manual §4 carries the uncited shape" grep -q 'uncited — <reason>' "$ROOT/manual/shepherd.md"
assert_ok "the manual §4 says a Basis is never from memory" \
  grep -q 'never a source from memory' "$ROOT/manual/shepherd.md"
assert_fail "the manual §4 no longer leaves the uncited case unsaid" \
  grep -q 'not your recollection' "$ROOT/manual/shepherd.md"
regex_verdict=$(python3 - "$ROOT" <<'PY'
import re, sys
sys.path.insert(0, sys.argv[1] + "/lib")
import metrics
text = open(sys.argv[1] + "/templates/decision.md", encoding="utf-8").read()
uncited = re.findall(r"uncited — [^`>]*", text)
cited = re.findall(r"`(https?://[^`]*)`", text)
ok = (uncited and not any(metrics.LIVE_SOURCE.search(u) for u in uncited)
      and cited and all(metrics.LIVE_SOURCE.search(c) for c in cited))
print("ok" if ok else "bad: uncited=%r cited=%r" % (uncited, cited))
PY
)
assert_eq "metrics reads the template's uncited examples as uncited and its cited one as cited" \
  "$regex_verdict" "ok"

# --- retro ends its learnings step with a downstream verdict (T-0220 item 4) --
# The fold pattern was law for 212 cards and produced zero folds. A written
# `none — <reason>` is the difference between a skipped obligation and an
# auditable one.
RETRO="$ROOT/skills/retro/SKILL.md"
learn=$(sed -n '/^2\. \*\*Learnings\*\*/,/^3\. \*\*Records\*\*/p' "$RETRO")
assert_ok "retro's learnings step is where it was" test -n "$learn"
assert_ok "retro's learnings step writes downstream: T-NNNN" grep -q 'downstream: T-NNNN' <<<"$learn"
assert_ok "or downstream: none with a reason" grep -q 'downstream: none — <reason>' <<<"$learn"
assert_ok "a retro that writes neither is incomplete" grep -qiE 'neither[^.]*(not finished|incomplete|unfinished)' <<<"$learn"
assert_ok "the fold card is queued and docs-only" grep -qE 'queued.*docs-only' <<<"$learn"
assert_ok "the fold Brief names CLAUDE.md as the only file in scope" grep -q 'only file' <<<"$learn"

# --- memory carries provenance and lives where Claude Code puts it (T-0220 item 5)
# 12 of 36 memory files lacked a modified: stamp, none named its source, and
# karta's memory was unreachable because its path was guessed from the slug.
# The resolved directory is recorded once (memory-dir:) and every writer reads
# it; the weekly review is a look, not a delete.
REG_TPL="$ROOT/templates/registry-card.md"
ONBOARD="$ROOT/skills/onboard/SKILL.md"
assert_ok "registry-card template carries memory-dir:" grep -q '^memory-dir:' "$REG_TPL"
assert_ok "the field says worktrees share one directory" grep -q 'every worktree' "$REG_TPL"
assert_ok "the field cites the live doc" grep -q 'code.claude.com/docs/en/memory' "$REG_TPL"
for f in skills/onboard/SKILL.md skills/retro/SKILL.md skills/triage/SKILL.md; do
  assert_ok "memory-dir: is known to $f" grep -q 'memory-dir:' "$ROOT/$f"
done
assert_ok "onboard records the directory a session resolved" \
  grep -qE 'memory-dir:' <<<"$(sed -n '/^5\. \*\*Bank/,/^6\. /p' "$ONBOARD")"
assert_eq "no framework surface still guesses the memory path from the slug" \
  "$(grep -rl 'Code-<slug>/memory' "$ROOT/manual/shepherd.md" "$ROOT/skills" "$ROOT/templates" 2>/dev/null)" ""
learn=$(sed -n '/^2\. \*\*Learnings\*\*/,/^3\. \*\*Records\*\*/p' "$RETRO")
assert_ok "retro stamps modified: on every memory file it writes" grep -q 'modified:' <<<"$learn"
assert_ok "retro stamps source: T-NNNN" grep -q 'source: T-NNNN' <<<"$learn"
weekly=$(sed -n '/^## Weekly mode/,$p' "$RETRO")
assert_ok "weekly mode reviews at 30 days" grep -q '30 days' <<<"$weekly"
assert_ok "weekly mode restamps a still-true fact" grep -q 'restamp' <<<"$weekly"
assert_ok "age is the trigger for the look, never the reason for the delete" \
  grep -qi 'never the reason' <<<"$weekly"
assert_ok "weekly mode reads memory-dir: too" grep -q 'memory-dir:' <<<"$weekly"

# --- fix round 1: no unbounded card, no unexecutable field, countable reasons (T-0220 review)
# The task review found three holes in the rules as first written: a split or
# handoff left the card with no next checkpoint, a registry card without
# memory-dir: left retro with a rule it could not execute, and a reason that
# happens to say `ctx7` or `read <date>` would count as a citation.
overrun=$(grep '^| \*\*overrun\*\*' "$ROOT/skills/monitor/SKILL.md")
assert_ok "every overrun decision line names the next checkpoint" grep -qE 'never unbounded|next checkpoint' <<<"$overrun"
assert_ok "a split names the bound for the part the worker keeps" grep -q 'rest done by <when>' <<<"$overrun"
assert_ok "a handoff names the bound the fresh worker inherits" grep -q 'fresh worker bounded to <when>' <<<"$overrun"
assert_ok "the overrun escalation says why the card is not blocked" grep -qE 'stays .working.|not waiting' <<<"$overrun"
learn=$(sed -n '/^2\. \*\*Learnings\*\*/,/^3\. \*\*Records\*\*/p' "$ROOT/skills/retro/SKILL.md")
assert_ok "retro says what to do when a card lacks memory-dir:" grep -qiE 'lacks (the field|memory-dir)' <<<"$learn"
assert_ok "the resolved directory is written to the card under its lock" \
  grep -qE 'memory-dir:.*card-<slug>' <<<"$learn"
assert_ok "retro cites the live doc for the modified/source claim" \
  grep -q 'code.claude.com/docs/en/memory' <<<"$learn"
assert_ok "the decision template warns that a source word in the reason counts as a citation" \
  grep -q 'counts any of those as a citation' "$ROOT/templates/decision.md"

# --- final review: the nudge's reply comes back as a blocked wake (T-0220 review)
# The nudge tells the worker to end `blocked`, so its answer classifies as
# the blocked row, whose procedure never writes the decision line — and the
# next heartbeat would escalate spuriously. The row has to route the reply.
overrun=$(grep '^| \*\*overrun\*\*' "$ROOT/skills/monitor/SKILL.md")
assert_ok "the overrun row routes the worker's blocked reply back to itself" \
  grep -qE 'blocked.? wake' <<<"$overrun"
assert_ok "the overrun row names where the launch time is read" \
  grep -qE 'briefed.? Log line' <<<"$overrun"
assert_ok "after an escalation later wakes wait rather than re-escalate" \
  grep -qE 're-arm and wait' <<<"$overrun"
assert_ok "the decision template's warning covers as of" grep -q '`as of`' "$ROOT/templates/decision.md"
learn=$(sed -n '/^2\. \*\*Learnings\*\*/,/^3\. \*\*Records\*\*/p' "$ROOT/skills/retro/SKILL.md")
assert_ok "a self-repo card has its own downstream verdict" grep -q 'self-repo' <<<"$learn"

# --- the procedures are scripts; the skills call them (T-0221) ---------------
# Each script's usage line in its header is what the skills quote, so a renamed
# verb or flag shows up here before a shepherd types the old one.
DISPATCH="$ROOT/skills/dispatch/SKILL.md"
WAKE="$ROOT/skills/wake/SKILL.md"
for s in shepherd-preflight shepherd-card shepherd-working-agreement shepherd-wake-report; do
  assert_file "bin/$s exists" "$ROOT/bin/$s"
  assert_ok "bin/$s is executable" test -x "$ROOT/bin/$s"
done
assert_ok "preflight header carries its usage" grep -qF 'shepherd-preflight T-NNNN [--lane-ok "<what you read>"]' "$ROOT/bin/shepherd-preflight"
assert_ok "preflight header carries undo"      grep -qF 'shepherd-preflight undo T-NNNN' "$ROOT/bin/shepherd-preflight"
assert_ok "shepherd-card header carries transition"  grep -qF 'shepherd-card transition T-NNNN <state>' "$ROOT/bin/shepherd-card"

assert_ok "dispatch runs the preflight"            grep -qF 'shepherd-preflight T-NNNN' "$DISPATCH"
assert_ok "dispatch answers JUDGE with --lane-ok"  grep -qF -- '--lane-ok' "$DISPATCH"
assert_ok "dispatch undoes with the script"        grep -qF 'shepherd-preflight undo T-NNNN' "$DISPATCH"
assert_ok "dispatch step 4 edits the card with shepherd-card" grep -qF 'shepherd-card set T-NNNN pane' "$DISPATCH"
assert_fail "dispatch no longer types the count-and-claim" grep -qF 'count, decide, then write BOTH fields' "$DISPATCH"
assert_fail "dispatch no longer acquires dispatch.lock by hand" grep -qF 'shepherd-lock acquire dispatch' "$DISPATCH"

assert_ok "wake runs the report"                   grep -qF 'shepherd-wake-report' "$WAKE"
assert_ok "wake undoes a dead claim with the script" grep -qF 'shepherd-preflight undo T-NNNN' "$WAKE"
assert_fail "wake no longer greps the active cards" grep -qF 'grep -lE "^state: (briefed' "$WAKE"
assert_fail "wake no longer greps its queue"        grep -qF 'xargs -r grep -l "^owner:' "$WAKE"
assert_ok "wake step 3 writes the orphan Log line through shepherd-card" grep -qF 'shepherd-card log T-NNNN "orphan:' "$WAKE"
# Every line kind the report prints is one the wake skill teaches - derived from
# the script, so a new kind cannot ship without its handling.
kinds=$(grep -oE '"(ACTIVE|LOCK|PANE|CLAIMING|WATCH|INBOX|QUEUE|INSTANCE|STATUS)[A-Z-]*' "$ROOT/bin/shepherd-wake-report" | tr -d '"' | sort -u)
assert_ok "wake-report emits line kinds" test -n "$kinds"
for k in $kinds; do
  assert_ok "the wake skill names the \`$k\` line kind" grep -qF "\`$k" "$WAKE"
done

for f in triage monitor retro; do
  assert_ok "$f transitions through shepherd-card" grep -qF 'shepherd-card transition' "$ROOT/skills/$f/SKILL.md"
done
assert_ok "retro logs metrics through shepherd-card"     grep -qF 'shepherd-card log T-NNNN "metrics:' "$ROOT/skills/retro/SKILL.md"
assert_ok "retro resolves a peer with shepherd-lock live" grep -qF 'shepherd-lock live <owner-id>' "$ROOT/skills/retro/SKILL.md"
assert_ok "retro carries the status file with --also" grep -qF -- "--also 'ledger/status/T-NNNN*.jsonl'" "$ROOT/skills/retro/SKILL.md"
for f in dispatch onboard; do
  assert_ok "$f runs the working-agreement script" grep -qF 'shepherd-working-agreement <path> <dev-branch>' "$ROOT/skills/$f/SKILL.md"
done
# The probe's load-bearing redirects live in exactly two places: protocols.md's
# spec block and the script. A third copy in a skill is the drift T-0221 removed.
# The probe is the `origin/<branch>:CLAUDE.md` form; monitor's reply ladder
# tests a path at the lane's HEAD with the same verb (T-0241), a different check.
assert_eq "the working-agreement probe appears in no skill" \
  "$(grep -rl 'cat-file -e "origin/' "$ROOT/skills" 2>/dev/null | wc -l)" "0"
assert_ok "the script carries the ref guard"  grep -q 'rev-parse --verify --quiet' "$ROOT/bin/shepherd-working-agreement"
assert_ok "the script carries the path test" grep -q 'cat-file -e' "$ROOT/bin/shepherd-working-agreement"
for s in shepherd-lane shepherd-preflight shepherd-card shepherd-working-agreement shepherd-wake-report 'shepherd-lock live'; do
  assert_ok "the manual §5's cookbook names $s" grep -qF "$s" "$ROOT/manual/shepherd.md"
done

# --- T-0233: launch policy ---------------------------------------------------
# Four silent downgrades were found on 2026-09-06 and nothing in the framework
# noticed any of them: a subagent pin that became a ceiling under a Fable
# worker, an SDD prescription from the M0 skeleton, an output style that
# dropped the coding instructions, and a shepherd model that drifted with the
# user default. Each of these pins the text that reverses one of them.

# 1. Subagents follow the worker: the env value IS the --model value.
R3="$ROOT/skills/herdr-adapter/references/v0.8.2.md"
launch=$(sed -n '/^## R3/,/^## R4/p' "$R3" | grep -m1 'herdr pane run')
assert_ok "R3's launch line sets the env var to the worker's alias" \
  grep -q 'CLAUDE_CODE_SUBAGENT_MODEL=<model> claude' <<<"$launch"
assert_ok "and --model takes the same placeholder" grep -q -- '--model <model> ' <<<"$launch"
assert_ok "and --effort is read from the ladder, not spelled here" grep -q -- '--effort <effort> ' <<<"$launch"
for f in manual/shepherd.md \
         skills/dispatch/SKILL.md \
         skills/herdr-adapter/references/v0.8.2.md \
         bin/shepherd-smoke; do
  assert_fail "no literal opus pin survives in $f" grep -q 'CLAUDE_CODE_SUBAGENT_MODEL=opus' "$ROOT/$f"
done
assert_ok "shepherd-smoke's rehearsal of R3 follows its own model" \
  grep -q 'CLAUDE_CODE_SUBAGENT_MODEL=\$SMOKE_MODEL claude -n worker-\$SMOKE_ID --model \$SMOKE_MODEL' "$ROOT/bin/shepherd-smoke"
# The variable is a default since v2.1.251; a reader who still believes it
# outranks per-call models will misread every pane that shows a Haiku reviewer.
assert_ok "R3 dates the precedence change" grep -q 'v2.1.251' "$R3"
assert_ok "R3 says why _FORCE stays unset" grep -q 'CLAUDE_CODE_SUBAGENT_MODEL_FORCE' "$R3"
assert_ok "§6 says subagents follow the worker" grep -q 'Subagents follow the worker' "$ROOT/manual/shepherd.md"

# 2. Plans stay in the worker's session; the brainstorming mandate is verbatim.
TPL="$ROOT/templates/task-card.md"
assert_ok "the template keeps the operator's brainstorming line byte for byte" \
  grep -qF -- '- ALWAYS start with the superpowers:brainstorming skill before touching code — every size, no exceptions (Saket, 2026-07-24).' "$TPL"
assert_fail "the template prescribes no subagent-driven implementation" grep -q 'subagent-driven-development' "$TPL"
assert_fail "nor a writing-plans chain" grep -q 'writing-plans' "$TPL"
assert_fail "nor a per-size skill chain" grep -q 'test-driven-development' "$TPL"
assert_ok "the template keeps planning and implementation in the session" grep -q 'implement in this session' "$TPL"
assert_ok "and cites the page that says so" grep -q 'docs/en/sub-agents, read 2026-09-06' "$TPL"
assert_ok "triage says the same, with the why" grep -q 'docs/en/sub-agents' "$ROOT/skills/triage/SKILL.md"
assert_ok "and §6 says it too" grep -q 'plans stay in the worker' "$ROOT/manual/shepherd.md"

# 3. The output-style trap is caught at every wake, without herdr.
CHK="$ROOT/bin/shepherd-output-style"
assert_file "the output-style check exists" "$CHK"
assert_ok "and is executable" test -x "$CHK"
assert_ok "and is read-only by contract" grep -q 'READ-ONLY' "$CHK"
assert_eq "wake step 1 runs it" \
  "$(sed -n '/^### 1\./,/^### 2\./p' "$ROOT/skills/wake/SKILL.md" | grep -c 'shepherd-output-style')" "1"
assert_ok "wake says the verdict reaches the operator" grep -qiE 'style[^.]*operator' "$ROOT/skills/wake/SKILL.md"
assert_ok "init runs it at its gate" grep -q 'shepherd-output-style' "$ROOT/skills/init/SKILL.md"
assert_ok "§6 names the check" grep -q 'shepherd-output-style' "$ROOT/manual/shepherd.md"
assert_ok "the check knows every built-in name" \
  grep -q 'BUILTINS="Default Proactive Concise Explanatory Learning"' "$CHK"

# 4. Shepherd pins its own model and effort; the ladder is one line in §0.
assert_ok "§1's launch line carries model and effort as fillable placeholders" \
  grep -qE 'SHEPHERD_ID=shepherd-1 claude -n shepherd-1 --remote-control shepherd-1 --model <model> --effort <effort>$' "$ROOT/manual/shepherd.md"
assert_ok "§1 cites the effort resolution it guards against" grep -q 'Adjust effort level' "$ROOT/manual/shepherd.md"
tiers=$(sed -n 's/^- tiers: //p' "$ROOT/manual/shepherd.md")
assert_ok "§0 carries the ladder as the three instance.env variables" \
  grep -qE 'SHEPHERD_TIER_S`, `SHEPHERD_TIER_STANDARD`, `SHEPHERD_TIER_HEAVY' "$ROOT/manual/shepherd.md"
for f in manual/shepherd.md \
         skills/dispatch/SKILL.md \
         skills/herdr-adapter/references/v0.8.2.md \
         skills/triage/SKILL.md \
         skills/init/SKILL.md; do
  assert_ok "$f points at the instance.env tier variables" \
    grep -qE 'SHEPHERD_TIER_(S|STANDARD|HEAVY)|instance\.env' "$ROOT/$f"
done
# One place. A model/effort pair spelled anywhere else is the copy that goes
# stale when the line changes. init-shepherd is exempt: its interview offers
# the ruling as the default answer, which is what it writes into §0.
pairs='(opus|fable|sonnet|haiku)/(low|medium|high|xhigh|max)'
assert_eq "CLAUDE.md spells no model/effort pair outside §0" \
  "$(awk '/^## 0\./{s=1;next} /^## 1\./{s=0} !s' "$ROOT/manual/shepherd.md" | grep -cE "$pairs")" "0"
flags='--model (opus|fable|sonnet|haiku) --effort (low|medium|high|xhigh|max)'
for f in skills/dispatch/SKILL.md \
         skills/herdr-adapter/references/v0.8.2.md \
         skills/triage/SKILL.md \
         templates/task-card.md; do
  assert_eq "$f spells no model/effort pair" \
    "$(grep -cE "$pairs|$flags" "$ROOT/$f")" "0"
done

# --- the shared protocols have one home (T-0222) -----------------------------
# CLAUDE.md restated the owner filter 12 times, the card-lock block 7 and the
# working-agreement inlining 12 (report §R2). One statement each, in one file
# the manual and the skills point at; a copy anywhere else is the drift.
PROTO="$ROOT/docs/protocols.md"
assert_file "docs/protocols.md exists" "$PROTO"
for s in 'Owner filter' 'Card lock' 'Commit rule' 'Working agreement' 'Lanes' 'Ownership and handoff' 'Status protocol'; do
  assert_ok "protocols.md carries ## $s" grep -q "^## $s\$" "$PROTO"
done
# § Status protocol names the third claim path and the value monitor reads off
# the ledger line (T-0249). Dropping either half puts the reader back where
# T-0244 was: a `claim: none` stop nobody could explain, and two heartbeats.
STATUS_SEC=$(sed -n '/^## Status protocol$/,/^## Reply workers$/p' "$PROTO")
assert_ok "§ Status protocol names the printed claim path" \
  grep -q 'prints\*\* the command rather than running it' <<<"$STATUS_SEC"
assert_ok "§ Status protocol names claim_source: printed" \
  grep -q '`claim_source: printed`' <<<"$STATUS_SEC"
assert_ok "§ Status protocol keeps the printed path a shape, not the literal" \
  grep -q 'the command named inside a sentence records nothing' <<<"$STATUS_SEC"
assert_ok "§ Status protocol says the printed path is tried last" \
  grep -q 'last\*\* path tried, under both the sentinel and a claim the worker actually ran' <<<"$STATUS_SEC"

# --- every incident has a date, a narrative and the rule it left (T-0222) ---
# The narratives left CLAUDE.md, the adapter Gotchas and the wake skill for
# one file each. A file without the three sections is a story with no rule,
# and one the index does not list is a story nobody will find.
INC="$ROOT/docs/incidents"
assert_file "the incidents index exists" "$INC/README.md"
for f in "$INC"/2026-*.md; do
  b=$(basename "$f")
  assert_ok "$b is dated in its name" grep -qE '^2026-[0-9]{2}-[0-9]{2}-' <<<"$b"
  for h in 'What happened' 'What changed' 'Where the rule stands'; do
    assert_ok "$b carries ## $h" grep -q "^## $h" "$f"
  done
  assert_ok "the index lists $b" grep -qF "$b" "$INC/README.md"
done
assert_ok "at least ten incidents are recorded" \
  test "$(ls "$INC"/2026-*.md 2>/dev/null | wc -l)" -ge 10

# --- the always-loaded set is bounded (T-0222, re-measured T-0256) -----------
# Loaded at every wake before any work, as ceil(bytes/4) — the approximation
# lib/metrics.py uses. Re-measured 2026-09-08, because the 2026-09-06
# figures this comment carried (≈26k: CLAUDE.md 8.7k, wake 4.2k, adapter 11.2k,
# memory index 2k) had gone stale downward as T-0234 and T-0255 cut the skills:
#   CLAUDE.md 5.6k · wake 2.0k · adapter 6.4k (SKILL 0.7k + v0.8.2 5.1k +
#   surfaces 0.6k) · memory index 2.5k  =  ~16.6k
# The recipes stay; the narratives moved to docs/incidents/, so a reference
# over the ceiling is a narrative creeping back in. Raised 4k → 5.25k on
# 2026-09-08: T-0256 bought the extra with three mechanisms, not narrative —
# R2's tab surface, R3's detect-and-register poll and R5's stall-window
# finding — each carrying the live citation the manual §2 rule 11 requires
# beside the claim it grounds. This pin and the word row in
# test-skill-ceilings.sh measure different things (bytes are what the model
# loads, words are what prose regrowth adds) and either may bind first as the
# file's density moves; both are ratchets, and the next recipe change trims
# before it raises either again.
assert_ok "the adapter reference is at most 5.25k tokens (21504 bytes)" \
  test "$(wc -c < "$ROOT/skills/herdr-adapter/references/v0.8.2.md")" -le 21504
# The manual grew from 117 to 138 lines when the framework became a plugin
# (T-0267): §0 stopped being one operator's prose block and became the
# .shepherd/instance.env contract an adopter has never seen, and a new paragraph
# states which paths are the plugin's and which are the instance's. The ceiling
# is raised here, in the same commit as the growth, which is the convention —
# a raise is a decision, never a reflex.
assert_ok "the manual is at most 145 lines" test "$(wc -l < "$ROOT/manual/shepherd.md")" -le 145
assert_ok "CLAUDE.md points at protocols.md" grep -q 'docs/protocols.md' "$ROOT/manual/shepherd.md"
assert_ok "CLAUDE.md points at the incidents" grep -q 'docs/incidents/' "$ROOT/manual/shepherd.md"

# --- milestones and the close-out (T-0239) -----------------------------------
# Spec docs/specs/2026-09-07-linear-conversation-design.md §3 rules 3–6, §6,
# §7, §8. A Linear-born build used to post one thought at carding and one
# response at close-out; the reader never learned when the work started, when
# it was being checked, what was checked, or where the result lives. Each pin
# is a behaviour: the post, at the transition shepherd already makes, through
# an shepherd-inbox verb, and its trace on the card Log.
DISPATCH="$ROOT/skills/dispatch/SKILL.md"
MONITOR="$ROOT/skills/monitor/SKILL.md"
RETRO="$ROOT/skills/retro/SKILL.md"
INBOX_SH="$ROOT/bin/shepherd-inbox"

# dispatch: "started", once, where the kickoff confirmed `working`.
dispatch_rec=$(sed -n '/^4\. \*\*Record\*\*/,/^5\. \*\*Arm the watchers\*\*/p' "$DISPATCH")
assert_ok "dispatch step 4 posts the started thought on a Linear-born card" \
  grep -qF 'shepherd-inbox activity <linear-session> thought' <<<"$dispatch_rec"
# T-0263: a card that never waited already said so in its first word, so the
# started post is gated on the marker the drain writes for the waiting form.
assert_ok "and only when the card waited: gated on the drain's in-line marker" \
  grep -qF 'grep -q "linear: thought posted to .* — in line" ledger/tasks/T-NNNN.md' <<<"$dispatch_rec"
assert_ok "the drain writes that marker on the waiting first word" \
  grep -qF 'ends its Log line ` — in line`' "$DRAIN_REF"
# §1's sentence is the re-served-event branch; the rows a shepherd follows when
# carding a NEW build are §3's, and they are what actually write the marker.
held_row=$(grep -E '^\| build from a non-operator' "$DRAIN_REF")
op_build_row=$(grep -E '^\| build \(with preview or not\) from the operator' "$DRAIN_REF")
assert_ok "the operator build row offers both first words" \
  grep -qiE 'on it if the work starts now, else in line behind N' <<<"$op_build_row"
assert_ok "and marks the waiting form" grep -qF 'the waiting form Logged ` — in line`' <<<"$op_build_row"
# A held build waits for the operator's go and then queues like any other; with
# no marker its reader would hear nothing between the hold and the close-out.
assert_ok "the held build row marks its first word too" \
  grep -qF "Logged \` — in line\`" <<<"$held_row"
# Derive dispatch's gate from the file and run it against drain-shaped lines,
# so the two surfaces are proved to agree rather than pinned as twin literals.
gate_re=$(grep -oE 'grep -q "linear: thought posted to [^"]*"' "$DISPATCH" | head -1 | sed -E 's/grep -q "(.*)"/\1/')
assert_ok "dispatch's started gate was found" test -n "$gate_re"
assert_ok "it matches a marked Log line" \
  grep -qE "${gate_re:-NO-GATE}" <<<'14:02 linear: thought posted to abc-123 — in line'
assert_fail "and not an unmarked one" \
  grep -qE "${gate_re:-NO-GATE}" <<<'14:02 linear: thought posted to abc-123'
assert_ok "and reads the card's linear-session: to decide" \
  grep -q 'linear-session:' <<<"$dispatch_rec"
assert_eq "dispatch posts to Linear in step 4 and nowhere else" \
  "$(grep -c 'shepherd-inbox activity' "$DISPATCH")" "1"
# The drain's skip check decides whether a re-served event's requester has
# heard anything by grepping the Log; dispatch's Log line has to match it.
assert_ok "dispatch Logs the posting as linear: thought posted to <session>" \
  grep -qF 'Logged `linear: thought posted to <session>`' <<<"$dispatch_rec"
skip_re=$(grep -oE 'grep -q "linear: [^"]*"' "$DRAIN_REF" | head -1 | sed -E 's/grep -q "(.*)"/\1/')
assert_ok "the drain's skip check was found (an empty pattern would match anything)" test -n "$skip_re"
assert_ok "and that Log shape is what the drain's skip check greps for" \
  grep -qE "${skip_re:-NO-SKIP-CHECK}" <<<'linear: thought posted to <session>'
# The in-line marker is a suffix, so a marked line still satisfies the skip
# check: a re-served event is not told twice just because the card waited.
assert_ok "and a marked line matches it too" \
  grep -qE "${skip_re:-NO-SKIP-CHECK}" <<<'linear: thought posted to <session> — in line'

# monitor: one action per DoD command, as the run starts, and no prose
# milestone announcing it (T-0263) — the posts live in evidence step 3 (the
# run), and the done row (the state edit to review) posts nothing.
mon_dod=$(sed -n '/^3\. \*\*DoD command\*\*/,/^4\. \*\*Pane tail\*\*/p' "$MONITOR")
# The review "checking it" thought is dropped everywhere (T-0263): the actions
# posted at review already say what was checked, so a prose milestone there is
# a post that carries nothing.
assert_fail "monitor posts no checking-it thought at the DoD run" \
  grep -qF 'shepherd-inbox activity <linear-session> thought' <<<"$mon_dod"
assert_fail "and no surface anywhere still posts one" \
  bash -c "grep -rqiE '(thought|activity)[^\n]*checking it' '$ROOT/skills' '$ROOT/docs/protocols.md' '$ROOT/templates'"
done_row=$(grep -E '^\| \*\*done\*\*' "$MONITOR")
assert_fail "the done row posts nothing to Linear: the check already announced itself" \
  grep -q 'shepherd-inbox' <<<"$done_row"
assert_ok "monitor posts one action per DoD command it ran, pass or fail" \
  grep -qiE 'action[^.]*per DoD command[^.]*pass or fail' <<<"$mon_dod"
assert_ok "the action carries what was run, the command and a one-line result" \
  grep -qF 'shepherd-inbox action <linear-session> "<what was run>" "<the command>" "<one-line result>"' <<<"$mon_dod"
assert_ok "and shepherd-inbox action takes exactly those three after the session" \
  grep -qE '^shepherd-inbox action +<session-id> <action> <parameter> \[<result>\]$' "$INBOX_SH"
lying=$(grep -E '^\| \*\*lying\*\*' "$MONITOR")
assert_ok "the lying row posts one ephemeral thought about the failure" \
  grep -qiE 'ephemeral[^|]*thought[^|]*fail' <<<"$lying"
assert_ok "and Logs it in the drain's shape" grep -qF 'linear: thought posted to <session>' <<<"$lying"

# monitor: progress at a heartbeat only when there is news, never a keep-alive.
prog=$(sed -n '/^\*\*Progress on a Linear-born card\*\*/,/^$/p' "$MONITOR")
assert_ok "monitor carries the progress paragraph" test -n "$prog"
assert_ok "progress posts only when there is news" grep -qiE 'only when there is news' <<<"$prog"
assert_ok "the progress thought is ephemeral, each replacing the last" \
  grep -qF 'thought "<the news>" --ephemeral' <<<"$prog"
assert_ok "shepherd-inbox accepts --ephemeral on an activity" \
  grep -qE '^shepherd-inbox activity .*\[--ephemeral\]' "$INBOX_SH"
assert_ok "the news is checkable: the posting Log line carries the branch tip" \
  grep -qF 'linear: thought posted to <session> at <sha>' <<<"$prog"
assert_ok "and the next heartbeat compares it against the branch" \
  grep -qF 'git log <sha>..<branch>' <<<"$prog"
assert_ok "the first heartbeat has a baseline: no tip logged yet, every branch commit is news" \
  grep -qiE 'no `at <sha>`[^.]*`<dev-branch>\.\.<branch>` is news' <<<"$prog"
assert_ok "no news means no post: a stale reading between posts is expected, not chased" \
  grep -qiE 'no (news|post)[^.]*`stale`|`stale`[^.]*no (news|post)' <<<"$prog"

# the drain: the queued first word, and voice rule 1 on every example body.
build_row=$(grep -E '^\| build \(with preview or not\) from the operator' "$DRAIN_REF")
assert_ok "the waiting first word names the queue position and the work ahead" \
  grep -qiE 'in line behind N[^|]*sum of the budgets ahead' <<<"$build_row"
assert_fail "no example thought or elicitation body carries T-NNNN (voice rule 1)" \
  bash -c "grep -rqE 'activity <[a-z-]*session[a-z-]*> (thought|elicitation) \"[^\"]*T-NNNN' '$ROOT/skills'"

# protocols rule 5 is the close-out's shape; retro and triage point at it.
assert_ok "voice rule 5's close-out carries what changed, where to see it and what happens next" \
  grep -qiE '^5\. \*\*The close-out `response`\*\* carries what changed.*where to see it.*what happens next' <<<"$voice"
assert_ok "rule 5 puts the links in the body and on the session" \
  grep -qiE '^5\. .*links in the body \*\*and\*\* `shepherd-inbox urls`' <<<"$voice"
assert_ok "rule 5's close-out is three lines, then rule 6's footnote" \
  grep -qiE '^5\. .*three lines, then rule 6.s footnote' <<<"$voice"

# The restatements the DoD requires to agree with the voice. Each is the surface
# that actually posts or measures the thing, and each was green when reverted
# before these pins existed (T-0263 review, findings D-3 to D-5).
assert_ok "retro's close-out names rule 5's three lines" \
  grep -qF 'three lines by rule 5' "$RETRO"
assert_ok "and its response placeholder is shaped as three lines" \
  grep -qF 'response "<line 1: what changed; line 2: where to see it; line 3: what happens next' "$RETRO"
assert_ok "retro's reply metric reads against the 150" \
  grep -qF 'sit against the 150' "$RETRO"
assert_ok "triage's cancel close-out names rule 5's three lines" \
  grep -qF "rule 5's three lines" "$TRIAGE"
# The intents reference is the surface most likely to drift back to the old
# every-transition wording, and had no pin at all.
intents_build=$(grep -E '^\| \*\*build\*\* \|' "$INTENTS")
assert_ok "the intents build row offers both first words" \
  grep -qiE 'on it, or in line behind N' <<<"$intents_build"
assert_ok "and names at most one thought between them" \
  grep -qiE 'a .thought. when a waiting card starts; close-out .response.' <<<"$intents_build"
assert_fail "and no longer promises a milestone thought at every transition" \
  bash -c "grep -rqiE 'thought. at every card transition|milestone .thought.s' '$ROOT/skills' '$ROOT/docs/protocols.md'"
assert_ok "rule 5 gives failed and abandoned the same shape with the honest outcome" \
  grep -qiE '^5\. .*Failed and abandoned get the same shape with the honest outcome and what was left where' <<<"$voice"
assert_fail "no skill restates rule 5's shape" \
  bash -c "grep -rqiE 'carries what changed[^.]*where to see it[^.]*what happens next' '$ROOT/skills'"

# retro step 4: the close-out response, the URLs, the answered line.
retro_notify=$(sed -n '/^4\. \*\*Notify\*\*/,/^5\. \*\*Worker pane/p' "$RETRO")
assert_ok "retro points at rule 5 for the response's shape" grep -qF 'rule 5' <<<"$retro_notify"
assert_ok "retro sets the session URLs with the three labels, each optional" \
  grep -qF 'shepherd-inbox urls <linear-session> [Branch=<url>] [PR=<url>] [Preview=<url>]' <<<"$retro_notify"
# shepherd-inbox urls refuses a bare session id, so a card with nothing linkable
# has to skip the verb rather than call it empty.
assert_ok "and skips the verb when nothing is linkable" grep -qiE 'nothing linkable[^.]*skip `urls`' <<<"$retro_notify"
urls_ln=$(grep -n 'shepherd-inbox urls' <<<"$retro_notify" | head -1 | cut -d: -f1)
resp_ln=$(grep -n 'shepherd-inbox activity <linear-session> response' <<<"$retro_notify" | head -1 | cut -d: -f1)
ans_ln=$(grep -n 'shepherd-inbox log answered' <<<"$retro_notify" | head -1 | cut -d: -f1)
assert_ok "the URLs land before the response, which completes the session" \
  test -n "$urls_ln" -a -n "$resp_ln" -a "${urls_ln:-0}" -lt "${resp_ln:-0}"
assert_ok "and the answered line lands after the response it times" \
  test -n "$ans_ln" -a "${resp_ln:-0}" -lt "${ans_ln:-0}"
assert_ok "Preview is set only when the registry's preview: names a mechanism" \
  grep -qiE '`Preview`[^.]*only when[^.]*`preview:`' <<<"$retro_notify"
assert_ok "preview: none or absent gets the where-it-now-lives line instead" \
  grep -qiE '`none`[^.]*where the change now lives' <<<"$retro_notify"
assert_ok "the footnote ends the response" \
  grep -qF -- '— shepherd-<id> · T-NNNN>"' <<<"$retro_notify"
assert_ok "retro appends the answered line through shepherd-inbox log answered" \
  grep -qF 'shepherd-inbox log answered <linear-event> now' <<<"$retro_notify"
assert_ok "shepherd-inbox log knows the answered shape" \
  grep -qE '^shepherd-inbox log +answered <event-id>' "$INBOX_SH"
retro_release=$(sed -n '/^6\. \*\*Release\*\*/,/^7\. \*\*Context check/p' "$RETRO")
assert_ok "the answered line rides step 6's transition commit" \
  grep -qE 'transition T-NNNN done\|failed\|abandoned .*--also ledger/inbox\.log' <<<"$retro_release"
assert_ok "and step 4 names that path, so nobody commits it twice" \
  grep -qF -- '--also ledger/inbox.log' <<<"$retro_notify"
assert_ok "retro cites the Linear page it read for the URL order" \
  grep -qE 'linear\.app/developers/agent-interaction, read 20[0-9]{2}-[0-9]{2}-[0-9]{2}' <<<"$retro_notify"

# triage §5: the cancel that never reaches retro posts the same final word.
triage_amend=$(sed -n '/^## 5. Amend or cancel/,$p' "$TRIAGE")
assert_ok "triage's cancel posts the close-out response, footnote last" \
  grep -qE -- 'activity <linear-session> response "[^"]*— shepherd-<id> · T-NNNN>"' <<<"$triage_amend"
assert_ok "guarded on the Log like retro's" \
  grep -qF 'grep -q "linear: response posted"' <<<"$triage_amend"
assert_ok "and appends the answered line" \
  grep -qF 'shepherd-inbox log answered <linear-event> now' <<<"$triage_amend"
assert_ok "riding the abandoned transition" \
  grep -qE 'transition T-NNNN abandoned.*--also ledger/inbox\.log' <<<"$triage_amend"
t_resp=$(grep -n 'activity <linear-session> response' <<<"$triage_amend" | head -1 | cut -d: -f1)
t_ans=$(grep -n 'shepherd-inbox log answered' <<<"$triage_amend" | head -1 | cut -d: -f1)
t_tr=$(grep -n 'transition T-NNNN abandoned' <<<"$triage_amend" | head -1 | cut -d: -f1)
assert_ok "the response, then the answered line, then the card is abandoned" \
  test -n "$t_resp" -a -n "$t_ans" -a -n "$t_tr" -a "${t_resp:-0}" -lt "${t_ans:-0}" -a "${t_ans:-0}" -lt "${t_tr:-0}"

# the manual §1: the clause and the boundary, verbatim from spec §8.
s1=$(sed -n '/^## 1\. What shepherd is/,/^## 2\. /p' "$ROOT/manual/shepherd.md")
assert_ok "the manual §1 says what the actual work is: building, or reading a project to answer a question" \
  grep -qF 'to do the actual work — building, or reading a project to answer a question —' <<<"$s1"
assert_ok "the manual §1 carries the boundary verbatim" \
  grep -qF "You never read a project's code in your own context; a question that needs it goes to a reply worker." <<<"$s1"

# every post reads the card's session id first, and no skill embeds a curl.
# A verb call more than six lines below the nearest `linear-session:`
# mention is a post with no guard in sight (the real distances are 0–5).
for f in dispatch monitor retro triage; do
  skill="$ROOT/skills/$f/SKILL.md"
  assert_ok "$f posts to Linear through shepherd-inbox" grep -qE 'shepherd-inbox (activity|action|urls)' "$skill"
  unguarded=$(awk '/linear-session:/ { last = NR }
                   /shepherd-inbox (activity|action|urls)/ { if (last == 0 || NR - last > 6) print NR ": " $0 }' "$skill")
  assert_eq "$f posts only within reach of its linear-session: guard" "$unguarded" ""
done
assert_fail "no skill posts to Linear with a curl of its own" \
  bash -c "grep -rqiE 'curl[^.]*(linear|INBOX_URL|agentActivity)' '$ROOT/skills'"

# --- the reply worker kind (T-0240) -----------------------------------------
# Spec docs/specs/2026-09-07-linear-conversation-design.md §2. A question that
# needs the code read used to have nowhere to go but a build card. Each pin is
# a behaviour: the card shape a triage copies, the preflight verdict dispatch
# reads, the lane command and its snapshot, the three launch layers and their
# sources, the delivery command, and the intents reference naming the handler.
CARD_TPL="$ROOT/templates/task-card.md"
REPLY_TPL="$ROOT/templates/reply-card.md"
DISPATCH="$ROOT/skills/dispatch/SKILL.md"
R3="$ROOT/skills/herdr-adapter/references/v0.8.2.md"
INTENTS="$ROOT/skills/triage/references/linear-intents.md"
DENY="$ROOT/hooks/reply-permissions.json"

# the card shape
tpl_proj=$(grep -n '^project:' "$CARD_TPL" | cut -d: -f1)
tpl_kind=$(grep -n '^kind: build' "$CARD_TPL" | cut -d: -f1)
assert_eq "the task-card template puts kind: build directly under project:" "$tpl_kind" "$((tpl_proj + 1))"
assert_ok "and says an absent line reads build" grep -qE '^kind: build .*absent line reads build' "$CARD_TPL"
assert_file "the reply-card template exists" "$REPLY_TPL"
rp_proj=$(grep -n '^project:' "$REPLY_TPL" | cut -d: -f1)
rp_kind=$(grep -n '^kind: reply$' "$REPLY_TPL" | cut -d: -f1)
assert_eq "the reply-card template puts kind: reply directly under project:" "$rp_kind" "$((rp_proj + 1))"
for f in 'branch: none' 'touch-areas: none — read-only' 'parallel-safety: independent — writes nothing and shares no lock' 'size: S   tier: standard   budget: 20m' 'linear-author:'; do
  assert_ok "reply card carries $f" grep -qF "$f" "$REPLY_TPL"
done
assert_ok "the reply ladder's M is named, and never L" grep -qE 'sized `M`.*fable/high.*`budget: 60m`.*Never `L`' "$REPLY_TPL"
for h in Objective Why Question Audience Context 'No code changes' 'Answer bar' Constraints 'Definition of Done' 'Status protocol'; do
  assert_ok "reply card has ### $h" grep -q "^### $h\$" "$REPLY_TPL"
done
assert_fail "reply card drops ### Out of scope" grep -q '^### Out of scope$' "$REPLY_TPL"
assert_fail "reply card drops ## Handoff" grep -q '^## Handoff$' "$REPLY_TPL"
assert_eq "reply card ends with ## Reply" "$(grep '^## ' "$REPLY_TPL" | tail -1)" "## Reply"
assert_ok "the Question is verbatim with issue, thread and author" grep -qE 'Issue <identifier>; thread .*; asked by <author' "$REPLY_TPL"
assert_ok "the Answer bar caps the Answer at 80 words" grep -qE '^\*\*Answer\*\*.*80 words' "$REPLY_TPL"
assert_ok "and the whole reply at 150" grep -qE 'whole reply at most 150 words' "$REPLY_TPL"
assert_ok "and reads the cap as a ceiling, not a target" \
  grep -qiE 'a ceiling, never a target' "$REPLY_TPL"
assert_ok "What I checked is a bare reference list, no prose" \
  grep -qE '^\*\*What I checked\*\* — a bare comma-joined list of references, no prose around it' "$REPLY_TPL"
assert_ok "Next step is one sentence" grep -qE '^\*\*Next step\*\* — one sentence' "$REPLY_TPL"
assert_ok "the Answer bar asks for plain English" \
  grep -qiE 'short sentences, common words, one idea per sentence' "$REPLY_TPL"
labels=$(grep -oE '^\*\*(Answer|What I checked|Confidence|Next step)\*\*' "$REPLY_TPL" | tr -d '*' | tr '\n' '|')
assert_eq "the four labels, in shepherd-reply's order" "$labels" "Answer|What I checked|Confidence|Next step|"
assert_ok "the reply-card brainstorming bullet is a spike with no design document" \
  grep -qE 'superpowers:brainstorming.*as a spike.*no design document' "$REPLY_TPL"
assert_eq "the reply-card Status protocol matches the task-card's" \
  "$(sed -n '/^### Status protocol/,/^## Log/p' "$REPLY_TPL")" "$(sed -n '/^### Status protocol/,/^## Log/p' "$CARD_TPL")"
rdod=$(sed -n '/^### Definition of Done/,/^### Status protocol/p' "$REPLY_TPL")
assert_ok "the reply DoD delivers through shepherd-reply" grep -q 'shepherd-reply' <<<"$rdod"
assert_ok "the reply DoD checks the lane is clean" grep -q 'git status --porcelain' <<<"$rdod"
assert_ok "the reply DoD checks no ref was created on origin" grep -q 'no ref on `origin`' <<<"$rdod"
assert_fail "the reply DoD names no command that passes" grep -qE '^- `[^`]+` passes' <<<"$rdod"
assert_eq "the templates spell two kinds" \
  "$(grep -rhoE '^kind: [a-z]+' "$ROOT/templates" | sort -u | tr '\n' '|')" "kind: build|kind: reply|"

# the preflight verdict, in the script and in dispatch's table
assert_ok "dispatch-preflight documents DISPATCH reply" grep -q '^#       DISPATCH reply' "$ROOT/bin/shepherd-preflight"
assert_ok "dispatch's table carries DISPATCH reply" grep -q '^   | `DISPATCH reply` | 0 |' "$DISPATCH"
assert_ok "and says no lane lock was taken" grep -qE '`DISPATCH reply`.*no lane lock was taken' "$DISPATCH"
assert_ok "dispatch says a reply card is in no FIFO and skipped by the gates" grep -qE 'reply.*in no FIFO.*gates.*skips it' "$DISPATCH"

# step 0: the lane, no lock, no row, no install, seed applied, the snapshot
step0=$(sed -n '/^   \*\*Reply target\*\*/,/^1\. \*\*Pane\*\*/p' "$DISPATCH")
assert_ok "step 0 carries the reply target" test -n "$step0"
assert_ok "the reply lane is prepared by the same call, not a second procedure" \
  grep -qF 'the same call' <<<"$step0"
assert_ok "and says why the remote tip alone is wrong (the self-repo runs ahead of origin)" grep -qE 'self-repo.*ahead of' <<<"$step0"
assert_ok "seeded like a clone" grep -qF '`clone-seed:` applies as for a clone' <<<"$step0"
assert_ok "no Clones row, no lock, no install" grep -qE 'no `## Clones` row, no lock, no install' <<<"$step0"
assert_ok "and why a reader needs no install" grep -qF 'installs in its own lane' <<<"$step0"
assert_ok "the PR head for a review" grep -qE '\*review\*.*PR head' <<<"$step0"
assert_ok "which the script is told with --tip" grep -qF -- '--tip origin/<that>' <<<"$step0"
assert_ok "the heads snapshot is taken before the worker exists" \
  grep -qF 'git -C <parent-path> ls-remote --heads origin | sort > ledger/attachments/T-NNNN-heads.txt' <<<"$step0"
assert_ok "the lane path is the preflight's path: line, spelled as the preflight builds it" \
  grep -qE "preflight.s .path:. line, .<parent-path>-reply-T-NNNN." <<<"$step0"
# The leftover rule moved into the verdict table, where the script now enforces
# it: git adopts an existing directory rather than refusing it, so nothing else
# stands between a leftover lane and a worker started on top of it.
whole0=$(sed -n '/^0\. \*\*Prepare the lane\*\*/,/^1\. \*\*Pane\*\*/p' "$DISPATCH")
assert_ok "a leftover lane is undone and reported, never removed" \
  grep -qE 'lane path exists.*[Uu]ndo and report it, never reset or remove it' <<<"$whole0"
assert_ok "and the skill says git would adopt it rather than refuse it" \
  grep -qF 'adopts** an existing directory' <<<"$whole0"
assert_ok "the preflight's reply lane has that shape" grep -qF 'LANE="reply-$TASK"; LANE_PATH="$REG_PATH-reply-$TASK"' "$ROOT/bin/shepherd-preflight"
assert_ok "dispatch's ERROR row names the unknown-kind case" grep -qE '`ERROR <why>`.*`kind:` that is neither `build` nor `reply`' "$DISPATCH"
assert_ok "and the preflight errors on it" grep -qF 'is neither build nor reply' "$ROOT/bin/shepherd-preflight"

# the launch: three additions in step 2 and in R3, the same three
launch2=$(sed -n '/^2\. \*\*Launch\*\*/,/^3\. \*\*Kickoff\*\*/p' "$DISPATCH")
r3=$(sed -n '/^## R3 /,/^## R4 /p' "$R3")
rline=$(grep 'herdr pane run' <<<"$r3" | grep -m1 'SHEPHERD_WORKER_KIND=reply')
assert_ok "R3 carries a reply launch line" test -n "$rline"
for add in 'SHEPHERD_WORKER_KIND=reply' '--disallowedTools Edit Write NotebookEdit' '--settings $(shepherd-paths hooks/reply-permissions.json)'; do
  assert_ok "R3's reply line carries $add" grep -qF -- "$add" <<<"$rline"
  assert_ok "dispatch step 2 names $add" grep -qF -- "$add" <<<"$launch2"
done
assert_ok "the reply line keeps the build line's env and flags" \
  grep -qF -- 'CLAUDE_CODE_SUBAGENT_MODEL=<model> claude -n worker-T-NNNN --model <model> --effort <effort> --permission-mode auto' <<<"$rline"
assert_ok "the reply line cds into the lane" grep -qF -- '"cd <lane-path> &&' <<<"$rline"
assert_fail "the reply line carries no double quote inside the pane text" \
  python3 -c 'import re,sys; b=re.search(r"\"\$pid\" \"(.*)\"\s*$", sys.stdin.read()).group(1); sys.exit(0 if "\"" in b else 1)' <<<"$rline"
assert_fail "the reply line does not use plan mode" grep -q -- '--permission-mode plan' <<<"$rline"
assert_ok "R3 says why plan mode is out" grep -qE 'Plan mode is out.*approve-the-plan prompt' <<<"$r3"
assert_ok "R3 says a bare name removes the tool" grep -qE 'bare name in `--disallowedTools` removes the tool' <<<"$r3"
assert_ok "R3 says no level can allow past a deny, and that it is still not a boundary" \
  grep -qE 'no level can allow past it.*quoting and wrappers still can' <<<"$r3"
assert_ok "R3 says the env var turns the guardrail to reply mode" grep -qE 'env var turns the guardrail hook to reply mode' <<<"$r3"
assert_ok "R3 states honestly what stops anything landing" grep -qE 'none a boundary.*detached lane stops anything landing' <<<"$r3"
for src in cli-reference permissions permission-modes; do
  assert_ok "R3 cites $src" grep -qE "\[$src\]\(https://code.claude.com/docs/en/$src\)" <<<"$r3"
done
assert_ok "R3's reply sources carry a read date" grep -qE 'Read 2026-09-07: \[cli-reference\]' <<<"$r3"
assert_ok "dispatch step 2 reads model and effort from tiers: for a reply too" grep -qE "reply.*model and effort from .instance\\.env." <<<"$launch2"
assert_ok "step 2 names the per-project deploy verb rule and where the verb is read from" \
  grep -qE "deploy verb.*registry.*--disallowedTools Edit Write NotebookEdit 'Bash\(<verb> \*\)'" <<<"$launch2"

# the deny file: valid JSON, the verbs in the forms workers type, the sources
assert_file "the reply deny list exists" "$DENY"
deny=$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["permissions"]["deny"]))' "$DENY" 2>/dev/null)
assert_ok "and is valid JSON with a permissions.deny list" test -n "$deny"
for rule in 'Bash(git push *)' 'Bash(git commit *)' 'Bash(git -C *)' 'Bash(wrangler *)' 'Bash(npx wrangler *)' 'Bash(npm run deploy*)' \
            'Bash(gh pr merge *)' 'Bash(gh pr close *)' 'Bash(gh pr create *)' 'Bash(gh pr edit *)' 'Bash(gh pr review *)' \
            'Bash(gh pr comment *)' 'Bash(gh issue comment *)' 'Bash(gh release *)' 'Bash(gh api -X*)' 'Bash(gh api --method *)' \
            'Bash(gh workflow run *)' 'Bash(curl -X*)' 'Bash(curl -d *)'; do
  assert_ok "deny list carries $rule" grep -qxF -- "$rule" <<<"$deny"
done
assert_fail "the deny list holds no allow rules" \
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["permissions"].get("allow") else 1)' "$DENY"
assert_ok "the deny file cites the permissions page with a read date" grep -qE 'docs/en/permissions, read 2026-09-07' "$DENY"
assert_ok "and the cli-reference and settings pages" grep -qE 'docs/en/cli-reference and /docs/en/settings, read 2026-09-07' "$DENY"
assert_ok "and says it is a speed bump, not a boundary" grep -qE 'speed bump.*not a boundary' "$DENY"
assert_ok "the guardrail hook names the deny file as the reply worker's second layer" grep -q 'hooks/reply-permissions.json' "$ROOT/hooks/worker-git-guardrail.sh"
assert_ok "the guardrail hook gates reply mode on SHEPHERD_WORKER_KIND=reply" \
  grep -qF '[ "${SHEPHERD_WORKER_KIND:-}" = reply ]' "$ROOT/hooks/worker-git-guardrail.sh"

# step 4: the briefed Log line carries the snapshot; the file rides its own commit
rec=$(sed -n '/^4\. \*\*Record\*\*/,/^5\. \*\*Arm the watchers\*\*/p' "$DISPATCH")
assert_ok "step 4's reply Log line carries count, digest and file" \
  grep -qF -- '--log "briefed pane <pane-id>, <model>/<effort>, launched <HH:MM>; heads $(wc -l < ledger/attachments/T-NNNN-heads.txt) refs sha256 $(sha256sum ledger/attachments/T-NNNN-heads.txt | cut -c1-12) ledger/attachments/T-NNNN-heads.txt"' <<<"$rec"
assert_ok "and commits the snapshot through shepherd-commit" \
  grep -qF 'shepherd-commit "T-NNNN: heads snapshot" ledger/attachments/T-NNNN-heads.txt' <<<"$rec"
assert_ok "a reply card writes no registry field" grep -qE 'reply card writes no registry field' <<<"$rec"
assert_ok "step 6's undo names the reply case: no lock held, the lane left for retro's close-out" \
  grep -qE "reply claim held none.*leave it and report its path.*removal is retro's \`## Reply close-out\`" "$DISPATCH"

# delivery: the command, its precedent, the event
RPLY="$ROOT/bin/shepherd-reply"
assert_file "bin/shepherd-reply exists" "$RPLY"
assert_ok "and is executable" test -x "$RPLY"
assert_ok "it appends event: reply" grep -q '"event": "reply"' "$RPLY"
assert_ok "it derives the card from the status file's directory" grep -qF '/../tasks/$SHEPHERD_TASK_ID.md' "$RPLY"
assert_fail "it never commits" grep -qE 'git (commit|add)' "$RPLY"
assert_ok "the reply card's DoD sends the worker to it" grep -q 'shepherd-reply <file>|-' "$REPLY_TPL"

# the intents reference: the handler named, the interim line gone
assert_fail "the intents reference carries no interim line" grep -qi 'interim' "$INTENTS"
assert_fail "and no longer waits on T-0240" grep -q 'T-0240' "$INTENTS"
assert_ok "the reply worker paragraph names the reply card template" \
  grep -qE 'reply worker.*`kind: reply` card.*templates/reply-card.md' "$INTENTS"
assert_ok "with the ladder: S opus/high 20m, M fable/high 60m, never L" grep -qE 'S opus/high 20m.*M fable/high 60m.*never L' "$INTENTS"
assert_ok "and no lock, no FIFO, one slot" grep -qE 'no project lock and no place in the family FIFO' "$INTENTS"
assert_eq "the intents table still names the reply worker as the handler for its five intents" \
  "$(grep -cE '^\| \*\*(ask|readiness|estimate|review|investigate)\*\* .*\| reply worker' "$INTENTS")" "5"

# --- reply verification and close-out (T-0241) -----------------------------
# Spec docs/specs/2026-09-07-linear-conversation-design.md §2, verification and
# close-out. A reply is read by someone who can click every path, sha, branch
# and PR in it; the ladder is what makes those real, and the close-out is what
# leaves nothing behind — no lock released, no branch merged, no worktree left.
# Each pin is a behaviour: a command the ladder runs, an order it keeps, a
# verdict it reaches, a step retro takes, or two surfaces agreeing on one fact.
MON="$ROOT/skills/monitor/SKILL.md"
RET="$ROOT/skills/retro/SKILL.md"
SPEC="$ROOT/docs/specs/2026-09-07-linear-conversation-design.md"
RW=$(sed -n '/^## Reply workers$/,/^## Linear voice$/p' "$PROTO")
MREP=$(sed -n '/^## A reply card$/,/^## Invariants$/p' "$MON")
RREP=$(sed -n '/^## Reply close-out/,/^## Weekly mode/p' "$RET")
RBUILD=$(sed -n '/^## Per-task close-out/,/^## Reply close-out/p' "$RET")

# the protocol section is the one home; the manual and both skills point at it
assert_ok "protocols.md has § Reply workers, before § Linear voice" test -n "$RW"
for f in manual/shepherd.md skills/monitor/SKILL.md skills/retro/SKILL.md; do
  assert_ok "$f points at § Reply workers" grep -q 'docs/protocols.md` § Reply workers' "$ROOT/$f"
done
assert_ok "§ Lanes says a reply lane is neither a clone nor in the FIFO" \
  grep -qE 'reply lane .*neither a clone nor in the FIFO' <<<"$(sed -n '/^## Lanes$/,/^## Ownership/p' "$PROTO")"
# One lane path, spelled the same where it is created (dispatch), checked
# (monitor), removed (retro) and defined (protocols); the preflight builds it.
for f in "$DISPATCH" "$MON" "$RET" "$PROTO"; do
  assert_ok "$(basename "$(dirname "$f")")/$(basename "$f") spells the lane path as the preflight builds it" \
    grep -qF '<parent-path>-reply-T-NNNN' "$f"
done
# The reply sections cite § Linear voice by rule number and carry none of its
# bodies: a section that neither cites nor restates would be pointing nowhere.
assert_ok "the reply sections cite at least two § Linear voice rules by number" \
  test "$(grep -oE '§ Linear voice rule [0-9]' <<<"$RW$MREP$RREP" | sort -u | wc -l)" -ge 2
assert_ok "and restate none of the voice rules' bodies" \
  test "$(grep -cE 'Write for the author|Footnote, never headline|One activity type per beat|no card, lane, worker, tier' <<<"$RW$MREP$RREP")" -eq 0
assert_ok "the launch layers are named by pointing at R3, not by a third copy of the list" grep -qE 'adapter R3 names them' <<<"$RW"

# the launch guarantees, stated honestly
assert_ok "none of the three launch layers is called a boundary" grep -qE 'None is a boundary' <<<"$RW"
assert_ok "the lane is the one guarantee: nothing lands" grep -qE 'The one guarantee is the lane itself.*nothing lands' <<<"$RW"
assert_ok "what the layers slow is egress, which is why the ladder checks the remote" \
  grep -qE 'egress\*\*.*why the ladder checks the remote' <<<"$RW"

# the ladder: four sources in the manual §2 rule 1's order, each proving one thing
rungs=$(grep -oE '^[0-9]+\. \*\*[^*]+\*\*' <<<"$RW" | sed -E 's/^[0-9]+\. \*\*//; s/\*\*$//' | paste -sd'|')
assert_eq "§ Reply workers' ladder is the four sources, in rule 1's order" \
  "$rungs" "The status file|Git facts|No DoD command|The pane tail"
assert_ok "rung 1 needs the claim and the reply record both" \
  grep -qE '^1\. .*`claim: done` \*\*and\*\* an `event: reply` record' <<<"$RW"
assert_ok "rung 1 names the four parts in shepherd-reply's order" \
  grep -qE '^1\. .*Answer, What I checked, Confidence, Next step' <<<"$RW"
assert_ok "rung 2 checks the lane is clean, detached and unmoved" \
  grep -qE '^2\. .*`git status --porcelain` empty, `git branch --show-current` printing nothing, and HEAD still the sha dispatch checked out' <<<"$RW"
assert_ok "rung 2 says why: the answer was read off a tree that is not the tip dispatch chose" \
  grep -qE '^2\. .*read off a tree that is not the tip dispatch chose' <<<"$RW"
assert_ok "rung 2 names the commit past the guardrail that moves HEAD with a clean porcelain" \
  grep -qE '^2\. .*commit past the guardrail leaves the porcelain and the branch name empty while moving HEAD' <<<"$RW"
assert_ok "rung 2 names the install's residue as Logged, not the lying row" \
  grep -qE "^2\. .*install's residue, Logged and held against nothing; any other line counts" <<<"$RW"
assert_ok "rung 2 diffs the remote against dispatch's snapshot" \
  grep -qE '^2\. .*`git ls-remote --heads origin` against the snapshot.*ledger/attachments/T-NNNN-heads\.txt' <<<"$RW"
assert_ok "rung 2 tells the lane's own ref (a commit it made) from the ambiguous one (its shared tip) from the world moving" \
  grep -qE "^2\. .*moved to a commit the lane made is the lane's own; a new ref at the lane's unmoved HEAD is ambiguous.*world moving" <<<"$RW"
assert_ok "rung 2 checks the four reference kinds" \
  grep -qE "^2\. .*a path exists at the lane's HEAD, a sha resolves, a branch is on \`origin\`, a PR answers \`gh pr view\`" <<<"$RW"
assert_ok "a command in What I checked is trusted with the reasoning, not checked as a reference" \
  grep -qE '^2\. .*A command in that list is what the worker ran.*trusted with the reasoning' <<<"$RW"
assert_ok "rung 3 has nothing to run; the reference check is the one action" \
  grep -qE '^3\. .*nothing to run.*the one `action`' <<<"$RW"
assert_ok "rung 3 says the response follows in the same wake" \
  grep -qE '^3\. .*`response` follows in the same wake' <<<"$RW"
assert_ok "rung 4 downgrades only" grep -qE '^4\. .*downgrades only' <<<"$RW"

# trusted vs checked, and the rows that follow from it
assert_ok "trusted: the interpretation, the reasoning and the confidence" \
  grep -qE 'Trusted: the interpretation, the reasoning and the confidence' <<<"$RW"
assert_ok "and second-guessing them is named as the boundary" grep -qE 'second-guess them is exactly the boundary' <<<"$RW"
assert_ok "checked: every fact the reader could click on" grep -qE 'Checked: every fact the reader could click on' <<<"$RW"
assert_ok "the lying row: a failing reference or a dirty, branched or moved lane; back once; twice failed; reader told" \
  grep -qE 'lying\*\* row of a reply is a reference that fails, or a lane that is dirty, branched or moved.*once; a second failure is `failed`.*reader is told honestly' <<<"$RW"
assert_ok "egress is a ref at a commit the lane made: failed plus an escalation, never shepherd's deletion" \
  grep -qE 'at a commit the lane made is \*\*egress\*\*, not lying: `failed`, and an escalation.*never shepherd' <<<"$RW"
assert_ok "a new ref at the unmoved HEAD is the operator's question, the reply unposted meanwhile" \
  grep -qE "unmoved HEAD is the operator's question.*unposted" <<<"$RW"

# the close-out invariants
assert_ok "the reply is posted verbatim with rule 6's footnote last" \
  grep -qE 'posted \*\*verbatim\*\* as the `response`, § Linear voice rule 6.s footnote as its last line' <<<"$RW"
assert_ok "Next step's options stay text, and the spec's select is named as what this overrides" \
  grep -qE 'options stay text in the body — not the `select` spec §2 names.*comes back as a `prompted`' <<<"$RW"
assert_ok "urls carries every PR and branch the reply names" grep -qE '`shepherd-inbox urls` carries every PR and branch' <<<"$RW"
assert_ok "the worktree is removed, the one retro removes without the operator's word" \
  grep -qE "worktree is removed — the one worktree retro removes without the operator's word" <<<"$RW"
for inv in 'The `answered` line stops the answer clock' 'No lock is released\*\*, because none was taken' 'a reply card never merges'; do
  assert_ok "close-out invariant: $inv" grep -qE "$inv" <<<"$RW"
done

# the budget rule: spec §2's sentence, read from the spec, refined, never a handoff
spec_budget=$(tr '\n' ' ' < "$SPEC" | tr -s ' ' | grep -oE '[Aa] reply that outruns its budget fails and is re-briefed with a narrower question')
rw_budget=$(grep -oE '\*[Aa] reply that outruns its budget fails and is re-briefed with a narrower question\*' <<<"$RW" | tr -d '*')
assert_ok "the spec carries the budget sentence" test -n "$spec_budget"
assert_eq "§ Reply workers cites it verbatim, as spec §2's" "${rw_budget,}" "${spec_budget,}"
assert_ok "and names the spec as its source" grep -qE "The rule is spec §2's" <<<"$RW"
assert_ok "half an answer is never handed to another worker: no Handoff" \
  grep -qE 'never handed to another worker.*no `## Handoff`' <<<"$RW"
assert_ok "the refinement: one bounded chance, delivered in this turn" \
  grep -qE 'one bounded chance.*deliver what it has \*\*in this turn\*\*' <<<"$RW"
assert_ok "a partial reply verifies and posts like any other" grep -qE 'partial reply verifies and posts like any other' <<<"$RW"
assert_ok "no done claim by the next wake is failed" grep -qE 'no `done` claim by the next wake is `failed`' <<<"$RW"
assert_ok "the re-brief stays on the reply ladder, never heavy" grep -qE 'reply ladder \(never heavy\)' <<<"$RW"
assert_ok "the re-brief inherits the three Linear fields" \
  grep -qE '`linear-session:`, `linear-event:` and `linear-author:` inherited' <<<"$RW"
assert_ok "Prior attempts carries the first attempt's final message" \
  grep -qE "\`### Prior attempts\` carrying the first attempt's final message" <<<"$RW"
assert_ok "a re-briefed failure posts a thought, not a response, and the answered line waits" \
  grep -qE 'posts a `thought` rather than a `response`.*`answered` line waits' <<<"$RW"

# monitor: the rungs as commands
assert_ok "monitor carries a reply section" test -n "$MREP"
mrungs=$(grep -oE '^[0-9]+\. \*\*[^*]+\*\*' <<<"$MREP" | sed -E 's/^[0-9]+\. \*\*//; s/\*\*$//' | paste -sd'|')
assert_eq "monitor's reply rungs are the four sources, in order" "$mrungs" "Status file|Git facts|No DoD command|Pane tail"
assert_ok "rung 1 tails the status file" grep -qF 'tail -n 8 ledger/status/T-NNNN.jsonl' <<<"$MREP"
assert_ok "and reads the reply record itself, which a round-trip pushes past the tail" \
  grep -qF "grep '\"event\": \"reply\"' ledger/status/T-NNNN.jsonl | tail -1" <<<"$MREP"
mlabels=$(grep -oE '\(Answer\|What I checked\|Confidence\|Next step\)' <<<"$MREP" | head -1 | tr -d '()')
script_labels=$(grep -oE '^LABELS = \[.*\]' "$ROOT/bin/shepherd-reply" | grep -oE '\*\*[^*]+\*\*' | tr -d '*' | paste -sd'|')
assert_eq "the labels monitor reads off the card are the ones shepherd-reply enforces, in its order" "$mlabels" "$script_labels"
assert_ok "and monitor anchors them at a line start, as shepherd-reply does" \
  grep -qF -- "grep -oE '^[[:space:]]*([-*]|[0-9]+\\.)?[[:space:]]*\\*\\*(Answer" <<<"$MREP"
for c in 'git -C <lane-path> status --porcelain' 'git -C <lane-path> branch --show-current' \
         'test "$(git -C <lane-path> reflog --format=%H | tail -1)" = "$(git -C <lane-path> rev-parse HEAD)"' \
         'diff ledger/attachments/T-NNNN-heads.txt <(git -C <lane-path> ls-remote --heads origin | sort)' \
         'git -C <lane-path> cat-file -e HEAD:<path>' 'git -C <lane-path> cat-file -e <sha>^{commit}' \
         'git -C <lane-path> ls-remote --heads origin refs/heads/<branch>' 'gh pr view <n> --json url -q .url'; do
  assert_ok "monitor's rung 2 runs: $c" grep -qF -- "$c" <<<"$MREP"
done
assert_ok "the heads file monitor diffs is the one dispatch's step 0 writes" \
  grep -qF 'ls-remote --heads origin | sort > ledger/attachments/T-NNNN-heads.txt' "$DISPATCH"
assert_ok "a ref that appeared or moved is read, not counted: a commit the lane made is egress" \
  grep -qE 'appeared or moved.*reflog past the first entry.*\*\*egress\*\*' <<<"$MREP"
assert_ok "a new ref at the unmoved HEAD is ambiguous, with the two innocent causes named" \
  grep -qE 'unmoved HEAD is ambiguous.*pushing `main` after a merge.*cutting a branch' <<<"$MREP"
assert_ok "the world moving is Logged and held against nothing" \
  grep -qE 'world moving.*Log it, hold nothing against the reply' <<<"$MREP"
assert_ok "the install's residue is Logged, any other porcelain line is the lying row" \
  grep -qE "install's residue.*Log them, hold nothing; any other line is the lying row" <<<"$MREP"
assert_ok "a command in What I checked is trusted with the reasoning" \
  grep -qE 'A command in \*What I checked\*.*trusted with the reasoning' <<<"$MREP"
assert_ok "rung 3 posts the reference check as one action" \
  grep -qF 'shepherd-inbox action <linear-session> "verified the references in the answer"' <<<"$MREP"
assert_fail "and no checking-it thought precedes it" grep -qE 'shepherd-inbox activity <linear-session> thought' <<<"$MREP"
assert_ok "rung 3 says the response follows in the same wake" \
  grep -qE '`response` follows in the same wake' <<<"$MREP"
assert_ok "rung 3 Logs the action" grep -qF 'Logged `linear: action posted to <session>`' <<<"$MREP"

# monitor: the verdicts
mrows=$(grep -oE '^\| \*\*[a-z-]+\*\*' <<<"$MREP" | tr -d '|* ' | paste -sd'|')
assert_eq "monitor's reply verdicts are done, lying, egress, overrun" "$mrows" "done|lying|egress|overrun"
mdone=$(grep -E '^\| \*\*done\*\*' <<<"$MREP")
assert_ok "done needs the reply record, the four parts, a clean detached unmoved lane, no egress, every reference" \
  grep -qE "event: reply\` ∧ four parts in order ∧ lane clean, detached and unmoved ∧ no ref of the lane's on \`origin\` ∧ every reference real" <<<"$mdone"
assert_ok "done transitions to review, the commit that puts the reply in git" \
  grep -qE 'transition T-NNNN review.*puts `## Reply` in git' <<<"$mdone"
assert_ok "lying: a dirty, branched or moved lane too; the second cycle is failed and retro tells the reader" \
  grep -qE 'dirty, branched or moved lane.*second cycle → `failed`.*retro tells the reader' <<<"$(grep -E '^\| \*\*lying\*\*' <<<"$MREP")"
meg=$(grep -E '^\| \*\*egress\*\*' <<<"$MREP")
assert_ok "egress: a ref at a commit the lane made; transition failed with the ref, escalate, never delete it yourself" \
  grep -qE 'at a commit the lane made.*transition T-NNNN failed --log "egress: <ref> at <sha>".*escalate `--sound request`.*never yours' <<<"$meg"
assert_ok "a new ref at the unmoved HEAD is the question, not the verdict: toast, Log, reply unposted until the operator's word" \
  grep -qE 'unmoved HEAD\*\* is the question, not the verdict.*egress\? <ref> at HEAD — asked the operator.*unposted' <<<"$meg"
mov=$(grep -E '^\| \*\*overrun\*\*' <<<"$MREP")
assert_ok "overrun on a reply has one option, deliver now, with the rule's home named" \
  grep -qF 'a reply'"'"'s one option is deliver now (`${CLAUDE_PLUGIN_ROOT}/docs/protocols.md` § Reply workers' <<<"$mov"
assert_ok "one bounded chance: deliver in this turn" grep -qE 'One bounded chance\*\*.*deliver what you have in this turn' <<<"$mov"
assert_ok "timed by a Log line" grep -qE 'overrun: deliver-now nudge at N\.Nx' <<<"$mov"
assert_ok "no done by the next wake: failed, then the narrower re-brief" \
  grep -qE 'No `done` claim by the next wake → `shepherd-card transition T-NNNN failed.*re-briefs narrower' <<<"$mov"
assert_ok "a reply record with no claim is read in the pane before it is failed" \
  grep -qE 'an `event: reply` with no claim → R6 first' <<<"$mov"
assert_ok "blocked and stalled stay the build rows" grep -qE 'blocked\*\* and \*\*stalled\*\* are the build rows as written' <<<"$MREP"
assert_ok "monitor keeps a re-brief off the heavy tier" grep -qE 're-brief after `failed` stays on the reply ladder.*never heavy' <<<"$MREP"

# retro: the steps that read differently for a reply, by the build's numbers
assert_ok "retro carries a reply close-out" test -n "$RREP"
assert_eq "the reply close-out keeps the build's numbering for the steps that change" \
  "$(grep -oE '^[0-9]+\. \*\*' <<<"$RREP" | tr -d '. *' | paste -sd,)" "1,4,6,7"
assert_ok "and says which steps are as written" grep -qE 'Steps 2, 3 and 5 as written' <<<"$RREP"
for n in 1 4 6; do
  assert_eq "reply step $n carries the build's name" \
    "$(grep -oE "^$n\. \*\*[^*]+\*\*" <<<"$RREP")" "$(grep -oE "^$n\. \*\*[^*]+\*\*" <<<"$RBUILD")"
done
assert_ok "step 1 adds words, read from the reply record in the status file" \
  grep -qE '^1\. .*words <n>.*`event: reply` record.*ledger/status/T-NNNN\.jsonl \| tail -1 \| grep -oE .\"words\": \[0-9\]\+.' <<<"$RREP"
assert_ok "step 4 posts the reply verbatim, nothing rewritten, options as text with the why pointed at" \
  grep -qE '^4\. .*`## Reply` \*\*verbatim\*\*.*nothing rewritten.*options staying text \(§ Reply workers says why\)' <<<"$RREP"
assert_ok "step 4 lifts the section as the card's last" \
  grep -qF "body=\$(sed -n '/^## Reply\$/,\$p' ledger/tasks/T-NNNN.md | sed '1d')" <<<"$RREP"
# Three things make ## Reply the last section: the template puts it last,
# shepherd-card's Log append inserts inside ## Log rather than at end of file, and
# shepherd-reply refuses an H2 inside the reply body.
assert_eq "the reply-card template ends with ## Reply" "$(grep '^## ' "$REPLY_TPL" | tail -1)" "## Reply"
assert_ok "shepherd-card appends a Log line inside ## Log, before the next heading of any level" \
  grep -qF 'not re.match(r"#+ ", lines[j])' "$ROOT/bin/shepherd-card"
assert_ok "shepherd-reply refuses an H2 inside the reply" \
  grep -qF 'refuse("the reply has a line starting with `## `' "$ROOT/bin/shepherd-reply"
assert_ok "step 4 appends the footnote as the last line" \
  grep -qF "response \"\$body\"\$'\\n'\"— shepherd-<id> · T-NNNN\"" <<<"$RREP"
assert_ok "guarded on the Log like the build's, and the Log line named" \
  bash -c 'grep -qF "grep -q \"linear: response posted\" ledger/tasks/T-NNNN.md ||" <<<"$1" && grep -qF "Logged \`linear: response posted to <session>\` as written" <<<"$1"' _ "$RREP"
r_urls=$(grep -n 'shepherd-inbox urls' <<<"$RREP" | head -1 | cut -d: -f1)
r_resp=$(grep -n 'shepherd-inbox activity <linear-session> response' <<<"$RREP" | head -1 | cut -d: -f1)
r_ans=$(grep -n 'shepherd-inbox log answered' <<<"$RREP" | head -1 | cut -d: -f1)
assert_ok "urls first, then the response, then the answered line" \
  test -n "$r_urls" -a -n "$r_resp" -a -n "$r_ans" -a "${r_urls:-0}" -lt "${r_resp:-0}" -a "${r_resp:-0}" -lt "${r_ans:-0}"
assert_ok "the PR URL is the ladder's; the branch URL comes from gh, so an ssh origin still yields a link" \
  grep -qE "the ladder's \`gh pr view\` printed.*gh repo view --json url -q \.url\)/tree/<branch>" <<<"$RREP"
assert_ok "a failed reply gets the honest response unless a re-brief is carded" \
  grep -qE 'failed\*\* reply gets the honest `response`.*\*\*unless\*\* a re-brief is carded' <<<"$RREP"
assert_ok "then a thought, no answered line, and the session stays open" \
  grep -qE 'a `thought`.*no `answered` line.*session stays open' <<<"$RREP"
assert_ok "step 6 releases no lock: the release is skipped, not run against nothing" \
  grep -qE '^6\. .*\*\*no lock\*\*.*`shepherd-lock release` is skipped' <<<"$RREP"
r_p=$(grep -n 'git -C <lane-path> status --porcelain | head -5' <<<"$RREP" | head -1 | cut -d: -f1)
r_r=$(grep -n 'git -C <parent-path> worktree remove <lane-path>' <<<"$RREP" | head -1 | cut -d: -f1)
r_l=$(grep -n 'shepherd-card log T-NNNN "lane discarded: <n> lines — <the first>"' <<<"$RREP" | head -1 | cut -d: -f1)
r_f=$(grep -n 'git -C <parent-path> worktree remove --force <lane-path>' <<<"$RREP" | head -1 | cut -d: -f1)
assert_ok "step 6's block reads the porcelain, removes, Logs what a dirty lane held, and forces last" \
  test -n "$r_p" -a -n "$r_r" -a -n "$r_l" -a -n "$r_f" -a "${r_p:-0}" -lt "${r_r:-0}" -a "${r_r:-0}" -lt "${r_l:-0}" -a "${r_l:-0}" -lt "${r_f:-0}"
assert_ok "the heads file stays as the record" grep -qE 'heads file stays in `ledger/attachments/`' <<<"$RREP"
assert_ok "no registry edit for a reply" grep -qE 'No registry edit' <<<"$RREP"
assert_ok "step 7 frees a slot, not a lane" grep -qE '^7\. .*frees a slot, not a lane' <<<"$RREP"
assert_ok "the retry points at § Reply workers' re-brief instead of restating its shape" \
  grep -qE "retry\*\* is § Reply workers' re-brief" <<<"$RREP"
assert_ok "and adds where the final message lives: the pane or the transcript the stop record names" \
  grep -qE "the pane \(R6\) or the transcript the status file's \`stop\` record names" <<<"$RREP"
assert_ok "a lying-twice failure is not re-briefed" grep -qE 'lying row twice.*is not re-briefed' <<<"$RREP"
assert_ok "the clone rule still says the worktree stays, and names the reply lane as its one exception" \
  grep -qE "\*\*The worktree stays\.\*\* A clone's — a reply lane is the one exception" <<<"$RBUILD"

# the manual §6: the bullet as spec §8 wrote it, read from the spec; the completion bullet scoped to builds
s6=$(sed -n '/^## 6\. /,/^## 7\. /p' "$ROOT/manual/shepherd.md")
spec_bullet=$(sed -n '/^## 8\. /,/^## 9\. /p' "$SPEC" | tr '\n' ' ' | tr -s ' ' | grep -oE 'Reply workers: `kind: reply` cards run.*verification ladder\.')
s6_bullet=$(grep -oE 'Reply workers:\*\* `kind: reply` cards run.*verification ladder\.' <<<"$s6" | sed 's/:\*\* /: /')
assert_ok "spec §8 carries the §6 bullet" test -n "$spec_bullet"
assert_eq "§6 carries it verbatim" "$s6_bullet" "$spec_bullet"
assert_ok "§6's completion bullet is a build's four, and sends a reply to the ladder" \
  grep -qE "all four\*\* agree.*a build's four; a reply card's are § Reply workers' ladder" <<<"$s6"

# --- the reply kind and template loose ends (T-0248) -------------------------
# T-0240 and T-0241 merged; six sentences around them still described the world
# before they landed, and a framework whose text contradicts its own rules
# briefs the next worker wrongly. Each pin is the behaviour the sentence has to
# produce, not the sentence.
CARD_TPL="$ROOT/templates/task-card.md"
REPLY_TPL="$ROOT/templates/reply-card.md"
DISPATCH="$ROOT/skills/dispatch/SKILL.md"
WAKE="$ROOT/skills/wake/SKILL.md"
PROTO="$ROOT/docs/protocols.md"
TRIAGE="$ROOT/skills/triage/SKILL.md"

# 1. A reply's Next step options reach the reader as text. An `elicitation`
# would hold the session open, and the `response` is the last word — so the
# Answer bar must not promise the worker a `select` that never gets built.
nextstep=$(grep -m1 -- '^\*\*Next step\*\*' "$REPLY_TPL")
assert_ok "the Answer bar's Next step says the options reach the reader as text" \
  grep -qiE 'plain text, never a `select`' <<<"$nextstep"
assert_ok "and says what a picked option becomes, so the worker knows nothing is lost" \
  grep -qiE 'reader clicks nothing.*pick comes back as a new request' <<<"$nextstep"
assert_fail "the template no longer promises shepherd will build a select" \
  grep -qiE 'turns them into a `select`' "$REPLY_TPL"

# 2. Rule 4 used to list a `thought` at every transition and exempt a reply
# card from the `review` one. T-0263 dropped the review thought everywhere, so
# the exemption has nothing to opt out of; what the rule now bounds is how many
# prose activities a build posts at all.
rule4=$(grep -m1 -- '^4\. \*\*Milestones\.\*\*' "$PROTO")
assert_ok "rule 4 caps a build at three milestone posts" \
  grep -qiE 'three milestone posts at most' <<<"$rule4"
# The cap counts milestones, not every prose activity: rule 4 itself mandates a
# heartbeat progress thought, and monitor posts an elicitation on a blocked
# card. Saying "three prose activities" contradicted both (T-0263 review, F-1).
assert_ok "and says what does not count against the three" \
  grep -qiE 'ephemeral progress `thought`, and the `elicitation` a blocked card asks with, are not milestones' <<<"$rule4"
assert_ok "the first word is always posted, on it or in line behind N" \
  grep -qiE 'first word\*\*, always.*\*on it\*.*\*in line behind N\*' <<<"$rule4"
# Three ways a reader can still be waiting: told to queue, told the build is
# held for the operator, or told "on it" when it turned out not to be.
assert_ok "started is posted only when the reader was not already told the work began" \
  grep -qiE 'started\*\*, only when the reader has not already been told the work began' <<<"$rule4"
assert_ok "and names all three waiting cases" \
  grep -qiE 'in line behind N\*, or it said the card awaits the operator.s go, or it said \*on it\* and the card waited anyway' <<<"$rule4"
assert_ok "and nothing is posted at review" \
  grep -qiE 'Nothing is posted at review' <<<"$rule4"
# The stale reading is Linear's undocumented behaviour, not a vendor promise.
assert_ok "rule 4 does not assert what makes a session stale or that a post revives it" \
  grep -qiE 'do not say what puts a session there, or whether a later post clears it' <<<"$rule4"
assert_ok "and cites the page it read that on" \
  grep -qF 'linear.app/developers/agent-interaction, read 2026-09-08' <<<"$rule4"

# 3. Dispatch's two reply-lane sentences pointed at an unmerged card for the
# removal rule. Retro's `## Reply close-out` is where it now lives, and a
# pointer at a task id rots the moment the task closes.
assert_fail "dispatch no longer defers the lane's removal to an unmerged card" \
  grep -qi 'arrives with T-0241' "$DISPATCH"
assert_ok "both reply-lane sentences point at retro's close-out section" \
  test "$(grep -c "removal is retro's \`## Reply close-out\`" "$DISPATCH")" -ge 2

# 4. Wake step 6 reconciles locks against active cards. A reply card holds no
# lock, and shepherd-wake-report already skips it — without the clause, a shepherd
# reading step 6 would report LOCK-MISSING for a card that is behaving.
step6=$(sed -n '/^### 6\. Reconcile self/,/^### 7\./p' "$WAKE")
assert_ok "step 6 says a reply card takes no lock, so no LOCK-MISSING is owed for one" \
  grep -qiE '`kind: reply` card takes no project lock.*no `LOCK-MISSING` for one' <<<"$step6"
assert_ok "and still calls a lock that names a reply card an anomaly to report" \
  grep -qiE 'lock that names one is still the anomaly' <<<"$step6"

# 5. The task-card DoD carried "(preview deploy where configured)" — the idea
# without the field that answers it or the person who checks it. Triage §4's
# build-with-preview bullet owns both; the template points there.
card_dod=$(sed -n '/^### Definition of Done/,/^### Status protocol/p' "$CARD_TPL")
assert_fail "the DoD no longer hides the preview in a parenthesis" \
  grep -qF 'preview deploy where configured' <<<"$card_dod"
assert_ok "it sends shepherd to the registry field that decides whether there is a line" \
  grep -qE 'registry `preview:`.*one more DoD line' <<<"$card_dod"
assert_ok "and to triage's bullet for the wording, rather than restating it" \
  grep -qiE "build-with-preview bullet" <<<"$card_dod"
# The note must not half-enumerate the three `by` values: it says the value
# decides and sends the reader to the bullet that reads all three, or a
# shepherd fills the DoD in from two of them.
assert_ok "the by value is named as what decides, and the bullet as where all three are read" \
  grep -qiE "\`by\` value decides who satisfies it.*reads all three" <<<"$card_dod"
assert_fail "the note enumerates no subset of the by values itself" \
  grep -qiE 'under .?(by )?push.? and|worker puts the preview command' <<<"$card_dod"
assert_ok "preview: none gets no line" grep -qiE '`preview: none` gets no line' <<<"$card_dod"
# The bullet it points at has to be there, or the pointer is the fourth home of
# a sentence that rots (docs/writing-for-agents.md § Pruning).
assert_ok "triage still carries the build-with-preview bullet the template names" \
  grep -qE -- '- \*\*Build-with-preview' "$TRIAGE"

# 6. Third appearance of a piped gate reading green (T-0224, the 2026-08-22
# watcher incident, T-0244). The registry gotcha only reaches a shepherd
# reading that card; the DoD line reaches every worker.
assert_ok "the DoD says the gate runs unpiped" grep -qiE 'unpiped' <<<"$card_dod"
assert_ok "and why: the pipe's exit status is what comes back, so a failure reads as 0" \
  grep -qiE "pipe.s exit status, not the command.s.*exit 0" <<<"$card_dod"
# A worker who cannot avoid the pipe needs the other half of the remedy, or
# the rule reads as a ban and gets ignored the fourth time.
assert_ok "and gives both ways out: a redirect, and PIPESTATUS for a pipe that has to stay" \
  grep -qiE 'file with `>`.*PIPESTATUS' <<<"$card_dod"

# --- dispatch's reply paragraphs name a home, not a task id (T-0250) ---------
# Two sentences still sent the reader to T-0241 for the ladder that verifies a
# reply. The card is closed; the ladder lives in protocols.md and monitor, and
# a pointer at a task id rots the moment the task does (docs/writing-for-agents.md
# § Pruning). Each pin is the behaviour: the reader lands where the rule is.
DISPATCH="$ROOT/skills/dispatch/SKILL.md"
MON="$ROOT/skills/monitor/SKILL.md"
reply_target=$(grep -m1 -- '\*\*Reply target\*\*' "$DISPATCH")
# Each pin reads the sentence for where it sends the reader, not for its word
# order, so a rewording that keeps the pointer passes.
assert_ok "the heads snapshot names the ladder's own section as what it is diffed against" \
  grep -qiE 'heads snapshot.*§ Reply workers' <<<"$reply_target"
heads_log=$(grep -m1 -- "A reply card's \`briefed\` line carries the heads snapshot" "$DISPATCH")
assert_ok "and the briefed line names the section that holds the commands" \
  grep -qF 'monitor'"'"'s `## A reply card`' <<<"$heads_log"
assert_ok "and says what that section reads off the snapshot" \
  grep -qiE 'which ref appeared' <<<"$heads_log"
# The shape, not the one id: rot that pointed at a different closed card would
# pass an absence pin naming T-0241 alone.
assert_fail "dispatch sends nobody to a task id for the reply ladder" \
  grep -qE 'T-0[0-9]{3}.s (verification )?ladder' "$DISPATCH"
# The pointer's target has to exist, or the fix is a fourth home that rots.
assert_ok "monitor still carries the ## A reply card section dispatch names" \
  grep -q '^## A reply card$' "$MON"

# --- triage §4 cards the reply-worker intents, not an interim word (T-0252) ---
# The Linear paragraph is the routing rule a shepherd reads on an `INBOX WORK`
# wake — the drain's §3 sends the reader here for the intent. It still ended at
# the interim word T-0238 wrote and T-0240 replaced with the reply kind, so a
# third live surface described the world before the reply kind, contradicting
# the two surfaces T-0248 and T-0250 had just corrected. Each pin reads the clause for where it sends the reader and
# what it produces, not for its word order.
TRIAGE="$ROOT/skills/triage/SKILL.md"
linear_para=$(grep -m1 -F '**From Linear, intent first.**' "$TRIAGE")
# The clause, not the paragraph: the paragraph is one line, so a `.*` anchored
# at its start would also be satisfied by a later sentence, and a gutted clause
# would read green. Cut from the intents to the end of their own sentence — a
# period inside `${CLAUDE_PLUGIN_ROOT}/templates/reply-card.md` is followed by a letter, a sentence's
# by a space.
reply_clause=$(sed -E 's/^.*reply-worker intents//; s/\. .*$//' <<<"$linear_para")
assert_ok "triage §4 still says what becomes of the reply-worker intents" \
  test -n "$reply_clause"
assert_ok "they become a \`kind: reply\` card" \
  grep -qF '`kind: reply` card' <<<"$reply_clause"
assert_ok "and it is written from the reply template" \
  grep -qF 'templates/reply-card.md' <<<"$reply_clause"
assert_ok "and they go on the reply ladder" \
  grep -qi 'reply ladder' <<<"$reply_clause"
# The ladder's sizes and the per-intent first words are the reference's;
# restating either here would be the fourth home of a sentence that rots
# (docs/writing-for-agents.md § Pruning).
assert_ok "and the first word is left to the intents reference rather than restated" \
  grep -qiE 'first word.*reference' <<<"$reply_clause"
assert_fail "and no activity type is named for them here" \
  grep -qiE '(thought|response|elicitation)' <<<"$reply_clause"
# A third pin, not a widening: the two that exist read one file each — the
# intents reference (any `interim`) and the drain's interim `--select`. Three
# surfaces carried this word, so the one that keeps a fourth from coming back
# unnoticed reads the whole skills tree.
assert_fail "no skill sends a reader to an interim word any more" \
  grep -rqi 'interim word' "$ROOT/skills"

# --- the skills point at protocols.md instead of restating it (T-0222) --------
# Five skills carried the same acquire / re-read / commit / release block. A
# copy is the one that drifts when the protocol changes.
assert_eq "no skill restates the card-lock block" \
  "$(grep -rlE 'shepherd-lock acquire "?card-' "$ROOT/skills" 2>/dev/null | wc -l)" "0"
for f in dispatch retro triage onboard monitor wake; do
  assert_ok "$f points at protocols.md" grep -q 'docs/protocols.md' "$ROOT/skills/$f/SKILL.md"
done
# Every section a pointer names exists: the text after "§" starts with one of
# protocols.md's headings. Prose may follow the name ("§ Card lock says why").
proto_heads=$(grep -E '^## ' "$PROTO" | sed 's/^## //')
# `< <(…)`, not a pipe: a `| while` runs in a subshell, where fail()'s counter
# is lost and a FAIL could print without failing the run.
while IFS= read -r ptr; do
  hit=0
  while IFS= read -r h; do case "$ptr" in "$h"|"$h "*) hit=1 ;; esac; done <<<"$proto_heads"
  assert_ok "protocols.md has a section for the pointer \"§ $ptr\"" test "$hit" = 1
done < <(grep -rhoE 'protocols\.md` § [A-Z][A-Za-z ]+' "$ROOT/manual/shepherd.md" "$ROOT/skills" "$ROOT/docs/incidents" 2>/dev/null \
           | sed -E 's/.*§ //; s/ +$//' | sort -u)
# Every incident a rule names exists.
for inc in $(grep -rhoE 'docs/incidents/[0-9a-z.-]+\.md' "$ROOT/manual/shepherd.md" "$ROOT/skills" "$ROOT/docs/protocols.md" | sort -u); do
  assert_file "$inc exists" "$ROOT/$inc"
done


# --- a self-repo card runs on a clone lane; only the base stays on main (T-0255 a)
# §5 and § Commit rule said a self-repo card "also stays on main" — a retired
# procedure. Self-repo work runs on a clone lane's task branch and only the base
# checkout never leaves main (shepherd-commit's refusal, FRAMEWORK.md); T-0246
# was dispatched into the base checkout on exactly this wording gap.
for f in manual/shepherd.md docs/protocols.md; do
  assert_fail "$f no longer says a self-repo card also stays on main" \
    grep -q 'also stays on `main`' "$ROOT/$f"
  assert_ok "$f sends self-repo work to a clone lane's task branch" \
    grep -q "runs on that clone lane's task branch" "$ROOT/$f"
  assert_ok "$f still keeps the base checkout on main" \
    grep -q 'never leaves `main`' "$ROOT/$f"
  # The lane rule is a build card's. A reply card carries the bare slug and
  # its lane is dispatch's throwaway worktree (templates/reply-card.md), so a
  # rule stated for every self-repo card would have triage writing `~N` on one.
  assert_ok "$f scopes the lane rule to a build card" \
    grep -qE 'self-repo (\*\*)?build(\*\*)? card' "$ROOT/$f"
  assert_ok "$f keeps the reply card on the bare slug" \
    grep -qE '`kind: reply` card carries the bare slug' "$ROOT/$f"
done
assert_ok "the reply-card template is where that came from" \
  grep -q 'never a ~N clone' "$ROOT/templates/reply-card.md"


# --- §4a hands off across the project family, as protocols does (T-0255 b) ----
# The manual said a released lock hands off "its oldest queued card" — per
# working copy — while § Ownership and handoff reads the oldest card of the
# project family, the queue § Lanes defines. A shepherd acting on the manual's
# sentence would leave the family's oldest card behind a younger lane-mate.
sec4a=$(sed -n '/^## 4a\. /,/^## 5\. /p' "$ROOT/manual/shepherd.md")
assert_ok "§4a is where it was" test -n "$sec4a"
assert_ok "§4a hands off the oldest queued card of the project family" \
  grep -q 'oldest queued card of that project family' <<<"$sec4a"
assert_ok "protocols § Ownership and handoff reads the same queue" \
  grep -q 'oldest `queued` card for that project family' "$ROOT/docs/protocols.md"


# --- the working-agreement check has one home, and the pointers name it (T-0255 c)
# T-0222 moved the check from the manual §5 to docs/protocols.md § Working
# agreement; both templates and the procedure-scripts spec still sent a reader
# to "§5's check", which resolves only through a hop a fresh session may not
# take. The state list and the cookbook are still §5's, so only the check's
# home moved.
assert_fail "no template or spec still names §5 as the check's home" \
  grep -rq "§5's check" "$ROOT/templates" "$ROOT/docs/specs"
for f in templates/registry-card.md templates/task-card.md \
         docs/specs/2026-09-06-procedure-scripts-design.md; do
  assert_ok "$f points at protocols § Working agreement" \
    grep -q '§ Working agreement' "$ROOT/$f"
done


# --- the multi-shepherd spec's clone section matches the lane script (T-0255 d,
# T-0257). Retro cites the spec as live authority for worktrees, and its §7.2
# described an unconditional `worktree add … origin/<dev-branch>` — no reuse, no
# dirty refusal, no tip choice, no no-origin fallback — while the procedure does
# all four. The script is the fact; the spec's stops are derived from the
# script's own hold/judge calls, so a new stop cannot ship without its sentence
# here or in dispatch's verdict table.
SPEC="$ROOT/docs/specs/2026-08-18-multi-shepherd-design.md"
spec7=$(sed -n '/^## 7\. Project clones/,/^## 8\. /p' "$SPEC")
assert_ok "the spec's clone section is where it was" test -n "$spec7"
step0=$(sed -n '/^0\. \*\*Prepare the lane\*\*/,/^1\. \*\*Pane\*\*/p' "$DISPATCH")
# The rule stops a shepherd acts on differently, derived from the script by the
# same helper the skill's table is checked against, so the spec and the skill
# can never disagree about what the procedure can refuse.
while IFS= read -r stop; do
  assert_ok "dispatch's verdict table carries \`$stop\`" grep -qF "$stop" <<<"$step0"
  assert_ok "the spec's clone section names the \`$stop\` stop" grep -qF "$stop" <<<"$spec7"
done < <(lp_stops)
assert_ok "the spec names the script as the procedure" \
  grep -qF 'shepherd-lane` is the procedure' <<<"$spec7"
assert_ok "and records that git adopts an existing directory rather than refusing it" \
  grep -qF 'adopts the directory, empty or not' <<<"$spec7"
assert_ok "the spec creates from the resolved tip" \
  grep -qF 'worktree add --detach <parent-path>-wt<N> "$tip"' <<<"$spec7"
assert_fail "the spec no longer adds from origin/<dev-branch> unconditionally" \
  grep -qF 'worktree add --detach <parent-path>-wt<N> origin/' <<<"$spec7"
assert_ok "the spec resets a reused worktree to the tip" grep -qF 'checkout --detach "$tip"' <<<"$spec7"
assert_ok "the spec names the template that seeds ## Clones" grep -q 'registry-card.md' <<<"$spec7"


# --- the README files what the plugin ships (T-0267) --------------------------
# FRAMEWORK.md's sync map is retired: there is no second copy of a framework
# file, so nothing can cross between template and instance. What replaced it is
# the README's own list of the plugin's components and of what an instance
# repository holds (T-0218 § "The personalisation layer"). A top-level directory
# the README does not name is a component a reader cannot discover.
README="$ROOT/README.md"
for d in skills hooks bin monitors manual templates; do
  assert_ok "README names the plugin's $d/" grep -q "$d/" "$README"
done
assert_ok "README names lib/ or says where the shared helpers live" \
  bash -c "grep -qE 'lib/|shepherd-common' \"$README\""
for d in ledger registry decisions; do
  assert_ok "README says an instance holds $d/" grep -q "$d/" "$README"
done
assert_ok "README gives the two install commands" \
  bash -c "grep -q 'claude plugin marketplace add' '$README' && grep -q 'claude plugin install shepherd@shepherd-plugins' '$README'"
assert_ok "README says the instance is initialised with the namespaced skill" \
  grep -q '/shepherd:init' "$README"
assert_ok "README states the plugin-first sync rule" \
  grep -qi 'Plugin first, always' "$README"


# --- the proposal rule has one home, weekly step 3 (T-0255 f) -----------------
# Retro's learnings step said "recurring → a weekly-mode proposal" and weekly
# step 3 owns proposals; the second copy is the one that drifts. The learnings
# step keeps the fact it alone holds (cross-project lessons go to the card Log)
# and points at weekly step 3, which now names those Logs as its input, so no
# fact moved out of reach.
assert_ok "the learnings and weekly captures are non-empty" test -n "$learn" -a -n "$weekly"
assert_ok "retro's learnings step sends cross-project lessons to the card Log" \
  grep -q 'Cross-project lessons → the card Log' <<<"$learn"
assert_ok "and points at weekly step 3 for what becomes a proposal" grep -q 'weekly step 3' <<<"$learn"
assert_fail "the learnings step no longer restates the proposal rule" \
  grep -qi 'weekly-mode proposal' <<<"$learn"
assert_ok "weekly step 3 names the card Logs' recurring lessons as its input" \
  grep -qiE 'Improvement proposals[^.]*recurring[^.]*card Log' <<<"$weekly"


# --- a size target names its counting method (T-0255 g) ------------------------
# T-0234's Brief gave per-skill word baselines that sat below `wc -w`, so the
# worker's "half" and the Brief's "half" were different numbers. The house
# style now names the methods — words by `wc -w`, tokens by ceil(bytes / 4) —
# and the ceilings test says which one it counts by.
counting=$(sed -n '/^## Counting/,$p' "$ROOT/docs/writing-for-agents.md")
assert_ok "writing-for-agents.md has a Counting section" test -n "$counting"
assert_ok "it names the word count method" grep -q 'wc -w' <<<"$counting"
assert_ok "and the token approximation" grep -q 'bytes / 4' <<<"$counting"
assert_ok "and points at the ceilings test" grep -q 'test-skill-ceilings.sh' <<<"$counting"

# --- one tab per worker (T-0256 c) -------------------------------------------
# R2 spawned a worker as a split of the shepherd's own pane; five splits left
# worker panes ~35 columns wide and truncated the ctx status line the
# worker-context-handoff check reads. the operator's ruling, 2026-09-08: one tab per
# worker. These pin the surface (`tab create`, both ids from the one response),
# the focus rule, and the close-out fact that lets R9 stay a `pane close`.
ADAPT="$ROOT/skills/herdr-adapter/references/v0.8.2.md"
r2=$(sed -n '/^## R2 /,/^## R3 /p' "$ADAPT")
assert_ok "R2 spawns a tab" grep -q 'herdr tab create' <<<"$r2"
assert_ok "R2 spawns it unfocused" grep -q '\-\-no-focus' <<<"$r2"
assert_ok "R2 reads the pane id out of the tab_created response" \
  grep -q 'result.root_pane.pane_id' <<<"$r2"
assert_fail "R2 no longer splits the shepherd's pane" grep -q 'herdr pane split' <<<"$r2"
assert_ok "R2 says why a tab and not a split" grep -qE '35 columns|status line' <<<"$r2"
assert_ok "R2 keeps the w- pane label R9 guards on" grep -q 'herdr pane rename' <<<"$r2"
r9=$(sed -n '/^## R9 /,/^## R10 /p' "$ADAPT")
assert_ok "R9 retires the tab" grep -qi 'tab goes with its last pane' <<<"$r9"
assert_ok "R9 dates that measurement" grep -q '2026-09-08' <<<"$r9"
assert_ok "R9 leaves a shared tab standing" grep -q 'pane_count' <<<"$r9"
assert_ok "R9 still closes the pane" grep -q 'herdr pane close' <<<"$r9"

# --- poll before the first wait (T-0256 a) -----------------------------------
# R3 issued `agent wait` (and R4's kickoff) straight after `pane run`; herdr
# had not detected the agent yet, so both returned `agent_not_found` at once —
# all five of w12:pD–pH, 2026-09-02. The recipe now polls `pane get` until the
# agent is BOTH detected (`agent`) and registered (`agent_session`), because
# those are separate moments (+0.67 s and +1.54 s, measured 2026-09-08).
r3=$(sed -n '/^## R3 /,/^## R4 /p' "$ADAPT")
# The launch block ALONE - R3's prose names `agent_session` too, so a section-wide
# grep passed with the predicate gutted to `p.get("agent")` (caught in review).
r3block=$(sed -n '/^## R3 /,/^## R4 /p' "$ADAPT" |
  awk '/^```bash$/{n++; next} /^```$/{if(n==1) exit; next} n==1')
assert_ok "R3's launch block was found" test -n "$r3block"
assert_ok "R3's poll gates on detection" grep -q 'p.get("agent")' <<<"$r3block"
assert_ok "R3's poll gates on registration too" grep -q 'agent_session' <<<"$r3block"
# …and the whole point is the ORDER: a poll below the wait pins nothing.
poll_ln=$(grep -n 'herdr pane get "\$pid"' <<<"$r3block" | head -1 | cut -d: -f1)
wait_ln=$(grep -n 'herdr agent wait "\$pid" --until idle --timeout 45000' <<<"$r3block" | head -1 | cut -d: -f1)
assert_ok "R3 polls pane get in the launch block" test -n "$poll_ln"
assert_ok "R3 keeps the 45 s readiness wait" test -n "$wait_ln"
assert_ok "…with the poll BEFORE the wait" test "${poll_ln:-99}" -lt "${wait_ln:-0}"
assert_ok "R3's poll carries its own verdict, not the loop's exit" grep -q 'ready=' <<<"$r3block"
assert_ok "R3 says a poll that runs out is a failed launch" grep -qi 'failed launch' <<<"$r3"
DISP="$ROOT/skills/dispatch/SKILL.md"
launch=$(sed -n '/^2\. \*\*Launch\*\*/,/^3\. \*\*Kickoff\*\*/p' "$DISP")
assert_ok "dispatch's launch step polls before waiting or prompting" \
  grep -qi 'poll .*pane get.*detected and registered' <<<"$launch"

# --- the output style is checked against the project (T-0256 d) --------------
# The no-argument form resolves the operator's user-level style; a project that
# sets its own outputStyle is only seen with its path. The verdict holds
# nothing — the setting is read once at session start (wake step 1's pattern).
launch=$(sed -n '/^2\. \*\*Launch\*\*/,/^3\. \*\*Kickoff\*\*/p' "$DISP")
assert_ok "dispatch's launch step runs the output-style check" \
  grep -q 'shepherd-output-style' <<<"$launch"
assert_ok "and runs it against the lane the worker launches in, not the registry path" \
  grep -qF "shepherd-output-style <the preflight's path:>" <<<"$launch"
assert_ok "and says a DEGRADED verdict holds nothing" grep -qi 'dispatch anyway' <<<"$launch"
assert_ok "and sends it to the card Log and the operator" grep -qi 'Log it on the card' <<<"$launch"

# --- Depends on: is a card field, not a Brief line (T-0256 e) ----------------
# The template puts the field above the Brief and shepherd-preflight reads
# it with an anchored `^Depends on:`; precondition 2 now says so, so a reader
# looking for it does not go hunting inside the Brief.
assert_ok "the template puts Depends on above the Brief" \
  python3 -c "import sys; t=open(sys.argv[1]).read(); sys.exit(0 if t.index('Depends on:') < t.index('## Brief') else 1)" \
  "$ROOT/templates/task-card.md"
assert_ok "dispatch precondition 2 places the field above the Brief" \
  grep -qE "Depends on: T-XXXX.*above the Brief" "$DISP"
assert_ok "the preflight reads it anchored at line start" \
  grep -qF "grep -m1 '^Depends on:'" "$ROOT/bin/shepherd-preflight"

# --- the stall window is monotonic, and herdr honours it (T-0256 b) ----------
# `agent wait --until blocked --timeout 3600000` came back at ~52-55 min, twice
# on four panes (2026-09-02). Neither the schema snapshot, nor `--help`, nor
# the published 0.8.2 CLI reference documents a cap - and measuring settled it:
# herdr keeps the window exactly on a monotonic clock (3600.0 s of
# /proc/uptime) while this host's realtime clock ran 81 s slow over the same
# hour. The reference states that finding with its sources; shepherd-watch reads the
# clock herdr keeps, and no longer takes herdr's `timeout` as its own window.
r5=$(sed -n '/^## R5 /,/^## R6 /p' "$ADAPT")
assert_ok "R5 states that herdr does not cap the wait" grep -qi 'does \*\*not\*\* cap' <<<"$r5"
assert_ok "R5 gives both clocks' numbers" grep -qE '3600\.0 s of .{0,3}/proc/uptime' <<<"$r5"
assert_ok "…and the realtime figure beside it" grep -q '3519 s' <<<"$r5"
assert_ok "R5 cites the published CLI reference with a read date" \
  grep -qE 'cli-reference\.mdx\).{0,40}read 2026-09-08' <<<"$r5"
assert_ok "R5 cites the schema snapshot for the absent cap" \
  grep -q 'AgentWaitParams.timeout_ms' <<<"$r5"
assert_ok "R5 no longer reads herdr's timeout as the window elapsing" \
  grep -qi "herdr's wait ended, which is not this window elapsing" <<<"$r5"
WATCH="$ROOT/bin/shepherd-watch"
assert_ok "shepherd-watch measures its windows on a monotonic clock" grep -q 'set_now()' "$WATCH"
# R5 calls this block "the script's exact line"; nothing held it to the script,
# and it drifted to `window * 1000` while shepherd-watch asked for `remaining`. A
# reader rebuilding the loop from R5 would overshoot the deadline by a window.
assert_ok "R5's stall line asks for what is LEFT of the window" \
  grep -qF 'herdr agent wait "$pid" --until blocked --timeout $((remaining * 1000))' <<<"$r5"
assert_ok "…which is the line shepherd-watch actually runs" \
  grep -qF 'herdr agent wait "$PANE" --until blocked --timeout $((remaining * 1000))' "$WATCH"
assert_ok "shepherd-watch resolves its clock once, and never mixes the two" grep -q 'CLOCK=mono' "$WATCH"
assert_ok "…rounding REPROBE UP, so a sub-second value cannot disable the guard" \
  grep -q 'REPROBE_INT=' "$WATCH"
assert_ok "…reading /proc/uptime" grep -q '/proc/uptime' "$WATCH"
assert_fail "…and no window deadline is taken from date +%s" \
  grep -qE '(deadline|remaining|issued)=.*date \+%s' "$WATCH"

# --- T-0260: the prompt audit's top three, adopted -------------------------
# docs/reports/2026-09-07-prompt-audit.md pile 2. Two of these change what
# every future worker does, so each is pinned at the sentence that carries the
# behaviour, not at the paragraph around it.

# F-22: the claim audit. The vendor measured this one sentence as nearly
# eliminating fabricated status reports (prompting-claude-fable-5 § Ground
# progress claims during long runs, re-read 2026-09-08), and monitor keeps a
# whole `lying` verdict for the failure it prevents.
CARD_TPL="$ROOT/templates/task-card.md"
REPLY_TPL="$ROOT/templates/reply-card.md"
proto=$(sed -n '/^### Status protocol/,/^## Log/p' "$CARD_TPL")
assert_ok "the block audits each claim against a tool result" \
  grep -q 'audit each claim in your final message against a tool result from this session' <<<"$proto"
assert_ok "…names what counts as evidence" grep -q "a command's output, a diff, a sha that resolves" <<<"$proto"
assert_ok "…asks for the unverified to be said plainly" grep -q 'say plainly what is not verified' <<<"$proto"
assert_ok "…and for a failed check to come with its output" \
  grep -q 'if a check failed, say so with its output' <<<"$proto"
# The audit has to precede the claim; after it, it is advice about a turn that
# already ended.
audit_at=$(grep -n 'audit each claim' <<<"$proto" | head -1 | cut -d: -f1)
cmd_at=$(grep -n 'shepherd-status done' <<<"$proto" | head -1 | cut -d: -f1)
assert_ok "the audit sentence comes before the status command" test "$audit_at" -lt "$cmd_at"
# The two blocks are pinned equal above; assert the reply card independently so
# that a future split of the pin cannot drop the sentence from one of them.
assert_ok "the reply card carries the same audit sentence" \
  grep -q 'audit each claim in your final message against a tool result' "$REPLY_TPL"

# F-23: the scope limit. Build cards only - a reply card edits nothing.
constraints=$(sed -n '/^### Constraints/,/^### Out of scope/p' "$CARD_TPL")
assert_ok "an unasked-for find is reported, not fixed" \
  grep -q 'report it as a follow-up in your summary' <<<"$constraints"
assert_ok "…with the one exception named" \
  grep -q 'unless the requested behaviour cannot work without it' <<<"$constraints"
assert_ok "…and the asked-for behaviour still implemented completely" \
  grep -q 'implement every behaviour the task asks for, completely' <<<"$constraints"
assert_ok "…and the page it came from cited with a read date" \
  grep -qE 'prompting-claude-fable-5-1.*read 2026-09-08' <<<"$constraints"
assert_fail "the reply card carries no scope bullet" grep -q 'Extras are follow-ups' "$REPLY_TPL"

# F-24: a token figure on the metrics line, produced by a script.
RETRO="$ROOT/skills/retro/SKILL.md"
TOKENS="$ROOT/bin/shepherd-card-tokens"
assert_file "the token script exists" "$TOKENS"
assert_ok "retro's metrics line carries a token figure" \
  grep -qF 'tier <t>, tokens <in>/<out> <model>' "$RETRO"
assert_ok "retro produces it with the script, not by hand" \
  grep -qF 'shepherd-card-tokens T-NNNN' "$RETRO"
assert_ok "…and writes tokens none rather than a guess when nothing survives" \
  grep -qF 'tokens none' "$RETRO"
assert_ok "the reply close-out's line carries the field too" \
  grep -qF 'tokens <in>/<out> <model>, words <n>' "$RETRO"
# The dedupe IS the measurement: a transcript repeats one message's usage once
# per content block, so summing the entries overcounts by about 2.6x (T-0245).
assert_ok "the script names the dedupe as its correctness" \
  grep -q 'DEDUPE BY `message.id` IS THE CORRECTNESS' "$TOKENS"
# A subagent's turns are not in the parent transcript, so a script that reads
# only the path the Stop hook records bills a delegating card at its
# orchestrator's cost alone (T-0245: 13.3M against a true 14.1M).
assert_ok "…and reads the subagent files beside the transcript" \
  grep -q 'SUBAGENTS ARE IN THE FIGURE' "$TOKENS"
assert_ok "…through a sibling-file lookup, not the parent's own lines" \
  grep -qF 'def subagent_files' "$TOKENS"

# The writer moved; the reader must still read. `duration` and `wakes` are the
# only two fields lib/metrics.py takes off this line, and both are
# searched for by name - so an appended field is invisible to them. Proven
# through metrics.py's own measures, not a copy of its regexes.
parse_verdict=$(python3 - "$ROOT" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1] + "/lib")
import metrics

OLD = "- 14:05 metrics: duration 1h30m, wakes 4, decisions 2, retries 0, tier heavy"
NEW = OLD + ", tokens 13.3M/79.0k claude-fable-5-1"


def card(cid, line):
    return {"id": cid, "log": line,
            "fields": {"state": "done", "budget": "120m", "size": "M"}}


cards = {"old": card("T-0001", OLD), "new": card("T-0002", NEW)}
timed = metrics.measure_timed(cards)
wakes = metrics.measure_wakes(cards)
# Both cards timed, 90 minutes each (3.0 h total, 90/120 = 0.75 of budget) and
# 4 wakes each: the appended field changed neither reading.
ok = (timed["timed_cards"] == 2 and timed["hours"] == 3.0
      and timed["median_ratio"] == 0.75
      and not any(timed["missing"].values())
      and wakes["cards"] == 2 and wakes["total"] == 8
      and not any(wakes["missing"].values()))
print("ok" if ok else "bad: timed=%r wakes=%r" % (timed, wakes))
PYEOF
)
assert_eq "metrics.py reads duration and wakes off a line carrying tokens" "$parse_verdict" "ok"

# The duplicate check: cross-owner, before the id is reserved (T-0245/T-0247).
TRIAGE="$ROOT/skills/triage/SKILL.md"
number=$(sed -n '/^2\. \*\*Number\*\*/,/^3\. \*\*Size/p' "$TRIAGE")
assert_ok "triage greps every owner's open cards" \
  grep -qF "grep -lE '^state: (captured|queued|briefed|working|blocked|review)' ledger/tasks/T-*.md" <<<"$number"
assert_ok "…for their titles, which is what a duplicate looks like" \
  grep -qF "grep -h '^# T-'" <<<"$number"
dup_at=$(grep -n "state: (captured" <<<"$number" | head -1 | cut -d: -f1)
res_at=$(grep -n 'shepherd-reserve reserve' <<<"$number" | head -1 | cut -d: -f1)
assert_ok "the check runs before the id is reserved" test "$dup_at" -lt "$res_at"
assert_ok "a matching ask reserves nothing" grep -q 'reserve nothing' <<<"$number"
assert_ok "…yours is amended through §5" grep -q 'yours, amend it through §5' <<<"$number"
assert_ok "…and a peer's is reported, never taken" \
  grep -q "report it to the operator and stand down" <<<"$number"
assert_ok "an adjacent ask is carded with the sibling named" \
  grep -q 'name the sibling' <<<"$number"
assert_ok "the pair that earns the check is named" grep -qE 'T-0245 .*T-0247' <<<"$number"

finish
