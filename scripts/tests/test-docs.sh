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

finish
