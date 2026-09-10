#!/usr/bin/env bash
# shepherd-preflight: preconditions 2-6 as one verdict. Every HOLD names its
# precondition; DISPATCH takes the lane lock, claims the slot and commits the
# claim; JUDGE stops at gate 3 with the registry excerpt and writes nothing.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
P="$HERE/../bin/shepherd-preflight"
C="$HERE/../bin/shepherd-card"
LOCK="$HERE/../bin/shepherd-lock"
T="$SHEPHERD_ROOT/ledger/tasks"
L="$SHEPHERD_ROOT/ledger/locks"
REG="$SHEPHERD_ROOT/registry/projects"
R="$SHEPHERD_ROOT/repos"
export SHEPHERD_ID=shepherd-kelpie HERDR_PANE_ID=w6:p1 CLAUDE_CODE_SESSION_ID=sess-k
export SHEPHERD_PREFLIGHT_RETRY=0
export SHEPHERD_NOW_OVERRIDE="2026-09-01T10:30:00+00:00"
HHMM=$(date -d "$SHEPHERD_NOW_OVERRIDE" +%H:%M)
# every liveness probe answers "gone" unless listed here
export SHEPHERD_LIVENESS_OVERRIDE="w6:p1:sess-k w6:p2:sess-c"

echo "test-preflight:"

# --- the instance: a git repo on main with worker-cap 3 ------------------------
git -C "$SHEPHERD_ROOT" init -q -b main
git -C "$SHEPHERD_ROOT" config user.email t@t
git -C "$SHEPHERD_ROOT" config user.name T
printf '# manual\n\n## 0. Operator\n\n- operator: T\n- worker-cap: 3\n' > "$SHEPHERD_ROOT/CLAUDE.md"
git -C "$SHEPHERD_ROOT" add CLAUDE.md; git -C "$SHEPHERD_ROOT" commit -qm seed
mkdir -p "$REG" "$R"

# --- the project repo the working-agreement probe reads ------------------------
g() { git -C "$1" -c user.email=t@t -c user.name=T "${@:2}"; }
git init -q --bare "$R/origin.git"
git init -q -b main "$R/karta"; g "$R/karta" commit -q --allow-empty -m seed
printf 'rules\n' > "$R/karta/CLAUDE.md"; g "$R/karta" add CLAUDE.md; g "$R/karta" commit -qm agreement
g "$R/karta" remote add origin "$R/origin.git"; g "$R/karta" push -q origin main

registry() {  # <slug> <onboarded> <working-agreement> [clone rows...]
  local slug=$1 onb=$2 wa=$3; shift 3
  {
    printf '# %s\npath: %s\nstack: x\ntest: true\ndev-branch: main\nworking-agreement: %s   # note\nonboarded: %s\nactive-task: none\npane: none\nclone-seed: .env\ninstall: true\nkeywords: %s\n\n' "$slug" "$R/karta" "$wa" "$onb" "$slug"
    printf '## Product\np\n\n## Context notes\n- Parallel lanes: safe (fixture)\n\n## Gotchas\n- port 3000 is shared\n\n## History\n\n## Clones\n| clone-id | path | active-task | pane |\n|---|---|---|---|\n'
    for row in "$@"; do printf '%s\n' "$row"; done
  } > "$REG/$slug.md"
}
registry karta yes main "| karta~2 | $R/karta-wt2 | none | none |"

card() {  # <id> <state> <owner> <project> <created> [extra header lines...]; Brief carries 4 numbered rules
  local id=$1 st=$2 own=$3 proj=$4 cr=$5; shift 5
  {
    printf '# %s: fixture\nstate: %s\nowner: %s\nproject: %s\nsize: M   tier: standard   budget: 120m\n' "$id" "$st" "$own" "$proj"
    for l in "$@"; do printf '%s\n' "$l"; done
    printf 'pane: none   session: none\ncreated: %s\n\nDepends on: none\n\n## Brief\n\n### Objective\nx\n\n### Context\nProject: p.\n1. a\n2. b\n3. c\n4. d\n\n### Constraints\n- c\n\n## Log\n- 09:00 captured (fixture)\n' "$cr"
  } > "$T/$id.md"
}
first() { printf '%s\n' "$1" | head -1; }
commits() { git -C "$SHEPHERD_ROOT" rev-list --count HEAD; }

# --- HOLDs, one per precondition ------------------------------------------------
card T-0101 working shepherd-kelpie karta 2026-09-01T09:00
out=$(bash "$P" T-0101); rc=$?
assert_eq "not queued -> HOLD state"           "$(first "$out")" "HOLD state working"
assert_eq "HOLD exits 1"                        "$rc" "1"

card T-0102 queued shepherd-collie karta 2026-09-01T09:00
out=$(bash "$P" T-0102)
assert_eq "another owner -> HOLD owner"         "$(first "$out")" "HOLD owner shepherd-collie"
card T-0103 queued shepherd-kelpie karta 2026-09-01T09:00; sed -i '/^owner:/d' "$T/T-0103.md"
out=$(bash "$P" T-0103)
assert_eq "no owner line reads as shepherd-1"   "$(first "$out")" "HOLD owner shepherd-1"

card T-0104 queued shepherd-kelpie karta 2026-09-01T09:00
sed -i 's/^Depends on: none/Depends on: T-0101 (the worker), T-0102/' "$T/T-0104.md"
out=$(bash "$P" T-0104)
assert_eq "an unmet dependency -> HOLD depends-on" "$(first "$out")" "HOLD depends-on T-0101 working"
sed -i 's/^Depends on: .*/Depends on: T-0999/' "$T/T-0104.md"
out=$(bash "$P" T-0104)
assert_eq "a missing dependency card is named"  "$(first "$out")" "HOLD depends-on T-0999 missing"
sed -i 's/^Depends on: .*/Depends on: nothing. T-0101 is unrelated prose/' "$T/T-0104.md"
sed -i 's/^state: working/state: done/' "$T/T-0101.md"

# family FIFO: an older queued sibling of mine that can move holds this one
card T-0105 queued shepherd-kelpie karta~2 2026-09-01T08:00
out=$(bash "$P" T-0104)
assert_eq "an older dispatchable sibling holds"  "$(first "$out")" "HOLD queue T-0105 older"
sed -i 's/^Depends on: none/Depends on: T-0102/' "$T/T-0105.md"     # T-0102 is queued, so T-0105 cannot move
out=$(bash "$P" T-0104)
assert_eq "an older sibling blocked on Depends on does not hold" "$(first "$out" | cut -d' ' -f1)" "DISPATCH"
bash "$P" undo T-0104 >/dev/null
sed -i 's/^state: queued/state: captured/' "$T/T-0104.md"   # parked: every later card is younger, so it must not hold the line

card T-0106 queued shepherd-kelpie other 2026-09-01T09:00
out=$(bash "$P" T-0106)
assert_eq "no registry card -> HOLD"            "$(first "$out")" "HOLD no registry card other"
registry other no none
out=$(bash "$P" T-0106)
assert_eq "not onboarded -> HOLD onboarded"     "$(first "$out")" "HOLD onboarded no"

# working agreement: unreadable + no inlined rules is the one direction that holds
registry nofile yes main
sed -i "s|^path: .*|path: $R/nofile|" "$REG/nofile.md"
git init -q --bare "$R/nofile-origin.git"; git init -q -b main "$R/nofile"; g "$R/nofile" commit -q --allow-empty -m seed
g "$R/nofile" remote add origin "$R/nofile-origin.git"; g "$R/nofile" push -q origin main
card T-0107 queued shepherd-kelpie nofile 2026-09-01T09:00
sed -i '/^[1-4]\. /d' "$T/T-0107.md"
out=$(bash "$P" T-0107)
assert_eq "unreadable agreement + no rules -> HOLD" \
  "$(first "$out" | cut -c1-59)" "HOLD working-agreement: CLAUDE.md unreadable on origin/main"
card T-0107 queued shepherd-kelpie nofile 2026-09-01T09:00     # rules back
out=$(bash "$P" T-0107); rc=$?
assert_eq "unreadable agreement + inlined rules passes" "$rc" "0"
bash "$LOCK" release project-nofile shepherd-kelpie >/dev/null 2>&1
bash "$C" set T-0107 state captured pane none --no-commit >/dev/null 2>&1   # fixture only: give its worker-cap slot back

# --- T-0253 item 1: the rule counter reads ### Context and nothing after it ----
# Without a ### Constraints heading the old sed range ran to end-of-file, so the
# numbered lines of a later section (a DoD list here) counted as inlined rules
# and a Brief with two rules passed precondition 4 on an unreadable agreement.
card T-0160 queued shepherd-kelpie nofile 2026-09-01T09:00
sed -i '/^[3-4]\. /d; /^### Constraints$/,/^- c$/d' "$T/T-0160.md"
printf '\n### Definition of Done\n1. x\n2. y\n3. z\n' >> "$T/T-0160.md"
out=$(bash "$P" T-0160)
assert_eq "two Context rules and three numbered DoD lines still HOLD: the counter stops at the section's end" \
  "$(first "$out" | cut -c1-59)" "HOLD working-agreement: CLAUDE.md unreadable on origin/main"
bash "$LOCK" release project-nofile shepherd-kelpie >/dev/null 2>&1
bash "$C" set T-0160 state captured pane none --no-commit >/dev/null 2>&1   # fixture only: give its worker-cap slot back

# --- T-0259 item 2: the section's end, from a real card's shape -----------------
# The five cards whose Context counts zero (T-0002, T-0013, T-0079, T-0080,
# T-0116) are counted correctly, not held falsely: their numbered lines are a
# sibling ### section's deliverables, never standing rules. This is T-0116's
# actual shape - a Context of prose followed by `### Phase 1 ...` - and it is the
# direction the counter must never lose, because losing it over-counts into a
# false DISPATCH. Red under the pre-T-0253 end-of-file range, which read 4 here.
card T-0163 queued shepherd-kelpie nofile 2026-09-01T09:00
sed -i '/^[1-4]\. /d' "$T/T-0163.md"
sed -i 's|^### Constraints$|### Phase 1 — critique + direction (deliverables on the branch)\n1. drive the app\n2. critique.md\n3. direction.md\n4. checkpoint\n\n### Constraints|' "$T/T-0163.md"
out=$(bash "$P" T-0163)
assert_eq "a sibling ### section's four numbered deliverables are not standing rules" \
  "$(first "$out" | cut -c1-59)" "HOLD working-agreement: CLAUDE.md unreadable on origin/main"


# --- lane: preferred free -> DISPATCH on it, slot claimed, committed -------------
card T-0110 queued shepherd-kelpie karta 2026-09-01T09:00
before=$(commits)
out=$(bash "$P" T-0110); rc=$?
assert_eq "preferred lane free -> DISPATCH"     "$(first "$out")" "DISPATCH karta"
assert_eq "DISPATCH exits 0"                     "$rc" "0"
assert_eq "lane lock taken for the task"         "$(awk '{print $1, $4}' "$L/project-karta.lock")" "shepherd-kelpie T-0110"
assert_eq "dispatch lock released"               "$(ls "$L" | grep -c '^dispatch.lock$')" "0"
assert_eq "state briefed"                        "$(bash "$C" get T-0110 state)" "briefed"
assert_eq "pane is the claim placeholder"        "$(bash "$C" get T-0110 pane)" "claiming-shepherd-kelpie-T-0110"
assert_eq "project unchanged"                    "$(bash "$C" get T-0110 project)" "karta"
assert_eq "one commit, the transition"           "$(( $(commits) - before ))" "1"
assert_eq "commit message"                       "$(git -C "$SHEPHERD_ROOT" log -1 --format=%s)" "T-0110: queued → briefed"
assert_eq "Log line names slot and lane"         "$(grep -c "^- $HHMM queued → briefed (slot 1/3 claimed as claiming-shepherd-kelpie-T-0110; lane karta)$" "$T/T-0110.md")" "1"
assert_eq "detail: path is the registry path"    "$(printf '%s\n' "$out" | sed -n 's/^path: //p')" "$R/karta"
assert_eq "detail: row base"                     "$(printf '%s\n' "$out" | sed -n 's/^row: //p')" "base"
assert_eq "detail: slots"                        "$(printf '%s\n' "$out" | sed -n 's/^slots: //p')" "1/3"
assert_eq "detail: clone-seed from the registry" "$(printf '%s\n' "$out" | sed -n 's/^clone-seed: //p')" ".env"

# a present-but-EMPTY clone-seed/install must not read as the default: card_field
# exits 0 with an empty value, so a bare `|| default` never fires for it.
registry blankdefaults yes main
sed -i 's/^clone-seed:.*/clone-seed:/; s/^install:.*/install:/' "$REG/blankdefaults.md"
card T-0150 queued shepherd-kelpie blankdefaults 2026-09-01T09:00
out=$(bash "$P" T-0150); rc=$?
assert_eq "blank clone-seed/install still dispatches" "$rc" "0"
assert_eq "detail: blank clone-seed prints copy-nothing, not the default" \
  "$(printf '%s\n' "$out" | sed -n 's/^clone-seed: //p')" "(empty - copy nothing)"
assert_eq "detail: blank install prints run-nothing, not the default" \
  "$(printf '%s\n' "$out" | sed -n 's/^install: //p')" "(empty - run nothing)"
bash "$LOCK" release project-blankdefaults shepherd-kelpie >/dev/null 2>&1
bash "$C" set T-0150 state captured pane none --no-commit >/dev/null 2>&1   # fixture only: give its worker-cap slot back

# --- lane held -> gates ---------------------------------------------------------
card T-0111 queued shepherd-kelpie karta 2026-09-01T09:10
out=$(bash "$P" T-0111)
assert_eq "held lane, this card serialized -> gate 1" "$(first "$out")" "HOLD gate 1 this card serialized (parallel-safety: serialized)"
card T-0111 queued shepherd-kelpie karta 2026-09-01T09:10 "touch-areas: docs, api" "parallel-safety: independent — x"
out=$(bash "$P" T-0111)
assert_eq "active sibling serialized -> gate 1"  "$(first "$out")" "HOLD gate 1 T-0110 serialized"
bash "$C" set T-0110 parallel-safety "independent — y" touch-areas "api, schema" --no-commit >/dev/null
out=$(bash "$P" T-0111)
assert_eq "shared touch-area -> gate 2"          "$(first "$out")" "HOLD gate 2 overlaps T-0110 on \"api\""
bash "$C" set T-0110 touch-areas "" --no-commit >/dev/null
out=$(bash "$P" T-0111)
assert_eq "empty touch-areas touches everything" "$(first "$out")" "HOLD gate 2 overlaps T-0110 (touch-areas: everything)"
bash "$C" set T-0110 touch-areas "schema, Build" --no-commit >/dev/null
bash "$C" set T-0111 touch-areas "docs, build" --no-commit >/dev/null
out=$(bash "$P" T-0111)
assert_eq "comparison is case-folded"            "$(first "$out")" "HOLD gate 2 overlaps T-0110 on \"build\""
bash "$C" set T-0111 touch-areas "docs, api" --no-commit >/dev/null

# gate 3: JUDGE with the excerpt, nothing written, nothing held
before=$(commits)
out=$(bash "$P" T-0111); rc=$?
assert_eq "gates pass -> JUDGE"                  "$(first "$out")" "JUDGE lane karta held by shepherd-kelpie T-0110; gates 1-2 pass against T-0110"
assert_eq "JUDGE exits 3"                        "$rc" "3"
assert_eq "JUDGE prints the Gotchas"             "$(printf '%s\n' "$out" | grep -c '^- port 3000 is shared$')" "1"
assert_eq "JUDGE prints the Context notes"       "$(printf '%s\n' "$out" | grep -c '^- Parallel lanes: safe')" "1"
assert_eq "JUDGE says how to answer"             "$(printf '%s\n' "$out" | grep -c '^next: re-run with --lane-ok')" "1"
assert_eq "JUDGE wrote nothing"                  "$(bash "$C" get T-0111 state)" "queued"
assert_eq "JUDGE held nothing"                   "$(ls "$L" | grep -vc '^project-karta.lock$')" "0"
assert_eq "JUDGE committed nothing"              "$(( $(commits) - before ))" "0"

# --lane-ok: walk to the existing clone row, relocate, Log it
out=$(bash "$P" T-0111 --lane-ok "Gotchas name a shared port; sibling runs no server"); rc=$?
assert_eq "--lane-ok -> DISPATCH on the clone"   "$(first "$out")" "DISPATCH karta~2"
assert_eq "clone lock taken"                     "$(awk '{print $4}' "$L/project-karta~2.lock")" "T-0111"
assert_eq "project rewritten to the lane"        "$(bash "$C" get T-0111 project)" "karta~2"
assert_eq "relocation Log line"                  "$(grep -c "^- $HHMM lane karta~2: Gotchas name a shared port; sibling runs no server (relocated from karta)$" "$T/T-0111.md")" "1"
assert_eq "detail: relocated"                    "$(printf '%s\n' "$out" | sed -n 's/^relocated: //p')" "from karta"
assert_eq "detail: row existing with its path"   "$(printf '%s\n' "$out" | sed -n 's/^path: //p')" "$R/karta-wt2"
assert_eq "detail: slots counts the placeholder" "$(printf '%s\n' "$out" | sed -n 's/^slots: //p')" "2/3"

# walk to a NEW lane: rows 2 held, so ~3 (lowest missing) is taken before it exists
card T-0112 queued shepherd-kelpie karta 2026-09-01T09:20 "touch-areas: ui" "parallel-safety: independent — z"
out=$(bash "$P" T-0112 --lane-ok "silent")
assert_eq "new lane at the lowest ~N the table lacks" "$(first "$out")" "DISPATCH karta~3"
assert_eq "detail: row missing"                  "$(printf '%s\n' "$out" | sed -n 's/^row: //p')" "missing"
assert_eq "detail: path none"                    "$(printf '%s\n' "$out" | sed -n 's/^path: //p')" "none"
assert_eq "a clone card never walks to the base" "$(bash "$C" get T-0112 project)" "karta~3"
printf '| karta~3 | %s | T-0112 | none |\n' "$R/karta-wt3" >> "$REG/karta.md"   # what dispatch step 0 does after a new lane

# --- worker-cap: three claims are in; the fourth holds and leaves no lock --------
card T-0113 queued shepherd-kelpie karta 2026-09-01T09:30 "touch-areas: db" "parallel-safety: independent — w"
before=$(commits)
out=$(bash "$P" T-0113 --lane-ok "silent"); rc=$?
assert_eq "cap reached -> HOLD worker-cap"       "$(first "$out")" "HOLD worker-cap 3/3"
assert_eq "cap hold leaves the card queued"      "$(bash "$C" get T-0113 state)" "queued"
assert_eq "cap hold leaves project: alone"       "$(bash "$C" get T-0113 project)" "karta"
assert_eq "cap hold released its lane"           "$(ls "$L" | grep -c 'project-karta~4')" "0"
assert_eq "cap hold released dispatch"           "$(ls "$L" | grep -c '^dispatch.lock$')" "0"
assert_eq "cap hold noted in the Log"            "$(grep -c "^- $HHMM dispatch held: worker-cap 3 reached (3 active)$" "$T/T-0113.md")" "1"
assert_eq "the note is its own commit"           "$(( $(commits) - before ))" "1"

# --- dispatch lock contention: held by a live peer -> HOLD waiting, lane released --
sed -i 's/^state: briefed/state: done/' "$T/T-0112.md"
bash "$LOCK" release project-karta~3 shepherd-kelpie >/dev/null
bash "$LOCK" acquire dispatch shepherd-collie w6:p2 sess-c none >/dev/null
out=$(bash "$P" T-0113 --lane-ok "silent"); rc=$?
assert_eq "dispatch lock held -> HOLD waiting"   "$(first "$out")" "HOLD dispatch lock held by shepherd-collie - waiting"
assert_eq "its lane was released"                "$(ls "$L" | grep -c 'project-karta~3')" "0"
bash "$LOCK" release dispatch shepherd-collie >/dev/null

# --- lock error (rc 2) is reported as the message, never as held -----------------
chmod 500 "$L"
out=$(bash "$P" T-0113 --lane-ok "silent"); rc=$?
chmod 700 "$L"
assert_eq "an unwritable locks dir -> HOLD lock error" "$(first "$out" | cut -c1-15)" "HOLD lock error"

# --- ERRORs ---------------------------------------------------------------------
out=$(bash "$P" T-9999); rc=$?
assert_eq "no card -> ERROR 2"                   "$rc" "2"
out=$(env -u SHEPHERD_ID bash "$P" T-0113); rc=$?
assert_eq "no SHEPHERD_ID -> ERROR 2"            "$rc" "2"
out=$(env -u CLAUDE_CODE_SESSION_ID bash "$P" T-0113); rc=$?
assert_eq "no session -> ERROR 2"                "$rc" "2"
sed -i '/worker-cap/d' "$SHEPHERD_ROOT/CLAUDE.md"
out=$(bash "$P" T-0113 --lane-ok "silent"); rc=$?
assert_eq "no worker-cap line -> ERROR 2"        "$rc" "2"
assert_eq "and the lane was released"            "$(ls "$L" | grep -c 'project-karta~3')" "0"

# --- undo: the ladder in order ----------------------------------------------------
printf -- '- worker-cap: 3\n' >> "$SHEPHERD_ROOT/CLAUDE.md"
# T-0111 was relocated karta -> karta~2 and claimed; undo restores every field
before=$(commits)
out=$(bash "$P" undo T-0111); rc=$?
assert_eq "undo verdict"                         "$(first "$out")" "UNDONE T-0111 lane karta~2 project restored to karta"
assert_eq "undo exits 0"                         "$rc" "0"
assert_eq "undo: state queued"                   "$(bash "$C" get T-0111 state)" "queued"
assert_eq "undo: pane none"                      "$(bash "$C" get T-0111 pane)" "none"
assert_eq "undo: original project restored"      "$(bash "$C" get T-0111 project)" "karta"
assert_eq "undo: lane lock released"             "$(ls "$L" | grep -c 'project-karta~2')" "0"
assert_eq "undo: Log line"                       "$(grep -c "^- $HHMM briefed → queued (dispatch undone)$" "$T/T-0111.md")" "1"
assert_eq "undo: one commit"                     "$(( $(commits) - before ))" "1"
assert_eq "undo: commit message"                 "$(git -C "$SHEPHERD_ROOT" log -1 --format=%s)" "T-0111: briefed → queued"

# a second dispatch after an undo relocates again and a second undo restores again
out=$(bash "$P" T-0111 --lane-ok "silent"); assert_eq "re-dispatch after undo" "$(first "$out")" "DISPATCH karta~2"
out=$(bash "$P" undo T-0111); assert_eq "second undo reads the latest relocation" "$(bash "$C" get T-0111 project)" "karta"

# a card on its preferred lane: project unchanged, lock released
out=$(bash "$P" undo T-0110)
assert_eq "undo on the preferred lane"           "$(first "$out")" "UNDONE T-0110 lane karta project unchanged"
assert_eq "preferred lane lock released"         "$(ls "$L" | grep -c '^project-karta.lock$')" "0"

# --- T-0221 fix 7: undo writes no lock line, so it needs only SHEPHERD_ID -------
bash "$P" T-0110 >/dev/null
out=$(env -u HERDR_PANE_ID -u CLAUDE_CODE_SESSION_ID bash "$P" undo T-0110); rc=$?
assert_eq "undo needs only SHEPHERD_ID, not the two lock env vars" "$rc" "0"
assert_eq "and it actually ran the ladder" "$(first "$out")" "UNDONE T-0110 lane karta project unchanged"

# a real pane id (step 4 already ran) is still undone to none
bash "$P" T-0110 >/dev/null
bash "$C" set T-0110 pane w9:p9 session s9 --no-commit >/dev/null
bash "$P" undo T-0110 >/dev/null
assert_eq "undo after a real pane id"            "$(bash "$C" get T-0110 pane)" "none"

# a dispatch.lock I still hold is released; another holder's is left alone
bash "$P" T-0110 >/dev/null
bash "$LOCK" acquire dispatch shepherd-kelpie w6:p1 sess-k none >/dev/null
bash "$P" undo T-0110 >/dev/null
assert_eq "undo releases my dispatch.lock"       "$(ls "$L" | grep -c '^dispatch.lock$')" "0"
bash "$P" T-0110 >/dev/null
bash "$LOCK" acquire dispatch shepherd-collie w6:p2 sess-c none >/dev/null
out=$(bash "$P" undo T-0110)
assert_eq "undo leaves a peer's dispatch.lock"   "$(awk '{print $1}' "$L/dispatch.lock")" "shepherd-collie"
assert_eq "and says so"                          "$(printf '%s\n' "$out" | grep -c '^dispatch: REFUSED')" "1"
bash "$LOCK" release dispatch shepherd-collie >/dev/null

# refusals
out=$(bash "$P" undo T-0110); rc=$?
assert_eq "undo on a queued card is refused"     "$(first "$out")" "REFUSED T-0110 is queued, not briefed"
assert_eq "refusal exits 1"                      "$rc" "1"
bash "$P" T-0110 >/dev/null
out=$(SHEPHERD_ID=shepherd-collie bash "$P" undo T-0110); rc=$?
assert_eq "undo by another instance is refused"  "$(first "$out")" "REFUSED T-0110 is owned by shepherd-kelpie, not shepherd-collie"
bash "$P" undo T-0110 >/dev/null
# T-0110 and T-0111 are queued again now that undo works - park them (like
# T-0104 above) so neither one's earlier `created` holds the FIFO line
# against every later fixture card dispatched in the karta family below.
sed -i 's/^state: queued/state: captured/' "$T/T-0110.md"
sed -i 's/^state: queued/state: captured/' "$T/T-0111.md"

# --- a real clone-project card: it walks only among clones, never the base ------
# project-karta is FREE here (just released above); karta~2 is held by another
# card (simulated) - a clone card must still never fall back to the base lane.
card T-0114 queued shepherd-kelpie karta~2 2026-09-01T00:00 "parallel-safety: independent — clone"
bash "$LOCK" acquire project-karta~2 shepherd-kelpie w6:p1 sess-k T-9002 >/dev/null
out=$(bash "$P" T-0114 --lane-ok "silent"); rc=$?
assert_eq "a clone card walks to another clone, never the base" "$(first "$out")" "DISPATCH karta~3"
assert_eq "DISPATCH exits 0 for the clone card" "$rc" "0"
assert_eq "the base lane lock is never touched"  "$(ls "$L" | grep -c '^project-karta.lock$')" "0"
bash "$LOCK" release project-karta~3 shepherd-kelpie >/dev/null
bash "$LOCK" release project-karta~2 shepherd-kelpie >/dev/null
sed -i 's/^state: briefed/state: done/' "$T/T-0114.md"   # retire it too: not an active sibling for what follows

# --- fix round 1: run_undo releases the lane the card CURRENTLY holds -----------
# T-0113 (still queued from way above, preferred lane karta) has its preferred
# lane held by another card; --lane-ok relocates it to karta~2, then a
# rejecting pre-commit hook fails the claim commit, driving commit_claim's own
# in-process run_undo call - the exact call where $PROJECT (still "karta") and
# the card's now-relocated project: ("karta~2") disagree.
bash "$LOCK" acquire project-karta shepherd-kelpie w6:p1 sess-k T-9003 >/dev/null
hook="$SHEPHERD_ROOT/.git/hooks/pre-commit"
mkdir -p "$(dirname "$hook")"
printf '#!/bin/sh\necho "pre-commit says no" >&2\nexit 1\n' > "$hook"; chmod +x "$hook"
out=$(bash "$P" T-0113 --lane-ok "silent"); rc=$?
rm -f "$hook"
assert_eq "in-process undo: commit failure -> HOLD" "$(printf '%s\n' "$out" | head -1 | cut -c1-18)" "HOLD commit failed"
assert_eq "HOLD exits 1"                         "$rc" "1"
assert_eq "the card reads queued again"          "$(bash "$C" get T-0113 state)" "queued"
assert_eq "pane cleared"                         "$(bash "$C" get T-0113 pane)" "none"
assert_eq "the ORIGINAL project is restored, not the relocated one" \
                                                  "$(bash "$C" get T-0113 project)" "karta"
assert_eq "the relocated lane's lock is released, not leaked" \
                                                  "$(ls "$L" | grep -c 'project-karta~2')" "0"
assert_eq "dispatch.lock is absent"              "$(ls "$L" | grep -c '^dispatch.lock$')" "0"
assert_eq "a NOTE undo line carries the ladder's output" \
                                                  "$(printf '%s\n' "$out" | grep -c '^NOTE undo: ')" "1"
bash "$LOCK" release project-karta shepherd-kelpie >/dev/null
out=$(bash "$P" T-0113); rc=$?
assert_eq "a following dispatch commits normally" "$(first "$out")" "DISPATCH karta"
assert_eq "and exits 0"                          "$rc" "0"

# --- T-0221 fix 6: claim_slot's own card-write failure must not leak locks or
# leave the card partially rewritten (state briefed but pane/project untouched).
# A python3 stub that fails on exactly the SECOND shepherd-card edit() call reproduces
# the case run_undo is built for: the first write (queued -> briefed) has
# already landed on disk when the second (pane <- claim) fails.
REALPY=$(command -v python3)
BIN="$SHEPHERD_ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/python3" <<'STUB'
#!/usr/bin/env bash
CTR="__ROOT__/py-calls"
n=$(( $(cat "$CTR" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$CTR"
if [ "$n" -eq "${PYFAIL_AT:-0}" ]; then
  echo "stub: simulated write failure on call $n" >&2
  exit 1
fi
exec "__REALPY__" "$@"
STUB
sed -i "s#__ROOT__#$SHEPHERD_ROOT#; s#__REALPY__#$REALPY#" "$BIN/python3"
chmod +x "$BIN/python3"

registry claimfail yes main
card T-0116 queued shepherd-kelpie claimfail 2026-09-01T09:00
rm -f "$SHEPHERD_ROOT/py-calls"
out=$(PATH="$BIN:$PATH" PYFAIL_AT=2 bash "$P" T-0116 2>/dev/null); rc=$?
assert_eq "a mid-claim write failure is an ERROR, not silently held" "$rc" "2"
assert_eq "first stdout line names the write failure" \
  "$(first "$out")" "ERROR could not write $T/T-0116.md"
assert_eq "run_undo ran and reports the ladder"  "$(printf '%s\n' "$out" | grep -c '^NOTE undo: UNDONE T-0116 ')" "1"
assert_eq "the card was fully unwound back to queued, not left briefed" \
  "$(bash "$C" get T-0116 state)" "queued"
assert_eq "pane cleared, not left as the claim placeholder" \
  "$(bash "$C" get T-0116 pane)" "none"
assert_eq "the project lane lock was released, not leaked" \
  "$(ls "$L" | grep -c '^project-claimfail.lock$')" "0"
assert_eq "the dispatch lock was released, not leaked" \
  "$(ls "$L" | grep -c '^dispatch.lock$')" "0"

# --- T-0253 item 4: claim_slot's FIRST write failing is one ERROR, the undo whole --
# The card never left queued, so run_undo's transition to queued was REFUSED
# and it reported a second "ERROR could not write" for a card it had not
# touched (T-0221 review). The ladder still releases both locks and skips the
# commit; the one ERROR line is the write that failed.
card T-0161 queued shepherd-kelpie claimfail 2026-09-01T09:00
rm -f "$SHEPHERD_ROOT/py-calls"
out=$(PATH="$BIN:$PATH" PYFAIL_AT=1 bash "$P" T-0161 2>/dev/null); rc=$?
assert_eq "a first-write failure is an ERROR"       "$rc" "2"
assert_eq "first stdout line names the write failure" "$(first "$out")" "ERROR could not write $T/T-0161.md"
assert_eq "and it is the only ERROR in the output"  "$(printf '%s\n' "$out" | grep -o 'ERROR' | wc -l)" "1"
assert_eq "the undo names the card untouched"       "$(printf '%s\n' "$out" | grep -c 'card: unchanged - still queued')" "1"
assert_eq "and skipped the commit"                  "$(printf '%s\n' "$out" | grep -c 'commit: skipped')" "1"
assert_eq "the card is still queued"                "$(bash "$C" get T-0161 state)" "queued"
assert_eq "with no pane"                            "$(bash "$C" get T-0161 pane)" "none"
assert_eq "the project lane lock was released"      "$(ls "$L" | grep -c '^project-claimfail.lock$')" "0"
assert_eq "the dispatch lock was released"          "$(ls "$L" | grep -c '^dispatch.lock$')" "0"

# --- kind: reply (T-0240): a read-only lane with no lock, no FIFO, no gates ----
# Spec docs/specs/2026-09-07-linear-conversation-design.md §2 Lane. The card
# still passes state, owner, depends-on, onboarded and working-agreement; it
# skips the family FIFO, lane selection and the three gates; it takes no
# project lock and one worker-cap slot. Here project-karta is held by T-0113
# (briefed above), which would send a build card into the gates.
rcard() {  # <id> <created> [extra header lines...] - a queued reply card of mine on karta
  local id=$1 cr=$2; shift 2
  card "$id" queued shepherd-kelpie karta "$cr" "kind: reply" "$@"
}
card T-0121 queued shepherd-kelpie karta 2026-09-01T07:00 "parallel-safety: independent — b"   # an older dispatchable BUILD sibling
rcard T-0120 2026-09-01T09:00
before=$(commits)
out=$(bash "$P" T-0120); rc=$?
assert_eq "a reply card dispatches past an older queued build (no FIFO)" "$(first "$out")" "DISPATCH reply"
assert_eq "DISPATCH reply exits 0"                    "$rc" "0"
assert_eq "no lane lock was taken for it"             "$(ls "$L" | grep -c 'project-karta')" "1"
assert_eq "and the held base lock still belongs to T-0113" "$(awk '{print $4}' "$L/project-karta.lock")" "T-0113"
assert_eq "dispatch lock released"                    "$(ls "$L" | grep -c '^dispatch.lock$')" "0"
assert_eq "reply: state briefed"                      "$(bash "$C" get T-0120 state)" "briefed"
assert_eq "reply: pane is the claim placeholder"      "$(bash "$C" get T-0120 pane)" "claiming-shepherd-kelpie-T-0120"
assert_eq "reply: project unchanged (never relocated)" "$(bash "$C" get T-0120 project)" "karta"
assert_eq "reply: one commit, the transition"         "$(( $(commits) - before ))" "1"
assert_eq "reply: commit message"                     "$(git -C "$SHEPHERD_ROOT" log -1 --format=%s)" "T-0120: queued → briefed"
assert_eq "reply: Log line names the slot, the lane id and its path" \
  "$(grep -c "^- $HHMM queued → briefed (slot 2/3 claimed as claiming-shepherd-kelpie-T-0120; lane reply-T-0120 at $R/karta-reply-T-0120)$" "$T/T-0120.md")" "1"
assert_eq "detail: kind reply"                        "$(printf '%s\n' "$out" | sed -n 's/^kind: //p')" "reply"
assert_eq "detail: lane is the id reply-<task>"       "$(printf '%s\n' "$out" | sed -n 's/^lane: //p')" "reply-T-0120"
assert_eq "detail: path is <parent>-reply-<task>"     "$(printf '%s\n' "$out" | sed -n 's/^path: //p')" "$R/karta-reply-T-0120"
assert_eq "detail: parent is the registry path"       "$(printf '%s\n' "$out" | sed -n 's/^parent: //p')" "$R/karta"
assert_eq "detail: dev-branch"                        "$(printf '%s\n' "$out" | sed -n 's/^dev-branch: //p')" "main"
assert_eq "detail: clone-seed still applies"          "$(printf '%s\n' "$out" | sed -n 's/^clone-seed: //p')" ".env"
assert_eq "detail: install is skipped on a reply lane" "$(printf '%s\n' "$out" | sed -n 's/^install: //p')" "skipped (reply lane: seed only)"
assert_eq "detail: slots counts the reply claim"      "$(printf '%s\n' "$out" | sed -n 's/^slots: //p')" "2/3"
assert_eq "detail: no clone row and no relocation lines" "$(printf '%s\n' "$out" | grep -cE '^(row|relocated): ')" "0"

# a build card's two sibling scans skip reply cards: the briefed reply above has
# no parallel-safety (reads serialized) and no touch-areas (touches everything),
# and a queued reply older than every build sits in the family - none of it
# holds the build, which reaches JUDGE against T-0113 alone.
sed -i 's/^state: queued/state: captured/' "$T/T-0121.md"
rcard T-0123 2026-09-01T06:00
card T-0122 queued shepherd-kelpie karta 2026-09-01T09:30 "touch-areas: ui" "parallel-safety: independent — u"
out=$(bash "$P" T-0122); rc=$?
assert_eq "a build card's FIFO and gates ignore reply cards" "$(first "$out")" "JUDGE lane karta held by shepherd-kelpie T-0113; gates 1-2 pass against T-0113"
assert_eq "and stops at JUDGE (3)"                    "$rc" "3"

# the unchanged checks still hold a reply card
rcard T-0124 2026-09-01T09:00; sed -i 's/^Depends on: none/Depends on: T-0102/' "$T/T-0124.md"
out=$(bash "$P" T-0124)
assert_eq "reply: an unmet dependency still holds"    "$(first "$out")" "HOLD depends-on T-0102 queued"
card T-0125 queued shepherd-kelpie nofile 2026-09-01T09:00 "kind: reply"; sed -i '/^[1-4]\. /d' "$T/T-0125.md"
out=$(bash "$P" T-0125)
assert_eq "reply: the working-agreement check still holds" \
  "$(first "$out" | cut -c1-59)" "HOLD working-agreement: CLAUDE.md unreadable on origin/main"
card T-0126 queued shepherd-collie karta 2026-09-01T09:00 "kind: reply"
out=$(bash "$P" T-0126)
assert_eq "reply: another owner still holds"          "$(first "$out")" "HOLD owner shepherd-collie"
card T-0127 queued shepherd-kelpie karta 2026-09-01T09:20 "kind: build"   # older than T-0122, so the FIFO is silent and the gate answers
out=$(bash "$P" T-0127)
assert_eq "an explicit kind: build takes the build path" "$(first "$out")" "HOLD gate 1 this card serialized (parallel-safety: serialized)"
card T-0128 queued shepherd-kelpie karta 2026-09-01T09:40 "kind: question"
out=$(bash "$P" T-0128); rc=$?
assert_eq "an unknown kind is an ERROR"               "$(first "$out")" "ERROR T-0128 kind: question is neither build nor reply"
assert_eq "and exits 2"                               "$rc" "2"

# two reply lanes on one project are fine; the cap is the only bound
out=$(bash "$P" T-0123); rc=$?
assert_eq "a second reply lane on the same project"   "$(first "$out")" "DISPATCH reply"
assert_eq "its slot is the third"                     "$(printf '%s\n' "$out" | sed -n 's/^slots: //p')" "3/3"
rcard T-0129 2026-09-01T09:50
before=$(commits)
out=$(bash "$P" T-0129); rc=$?
assert_eq "a reply card at the cap holds"             "$(first "$out")" "HOLD worker-cap 3/3"
assert_eq "cap hold leaves the reply card queued"     "$(bash "$C" get T-0129 state)" "queued"
assert_eq "cap hold noted in its Log"                 "$(grep -c "^- $HHMM dispatch held: worker-cap 3 reached (3 active)$" "$T/T-0129.md")" "1"

# undo on a reply claim: queued, pane none, no lane lock to release, committed
before=$(commits)
out=$(bash "$P" undo T-0120); rc=$?
assert_eq "undo verdict on a reply claim"             "$(first "$out")" "UNDONE T-0120 lane reply-T-0120 project unchanged"
assert_eq "undo exits 0"                              "$rc" "0"
assert_eq "undo: reply state queued"                  "$(bash "$C" get T-0120 state)" "queued"
assert_eq "undo: reply pane none"                     "$(bash "$C" get T-0120 pane)" "none"
assert_eq "undo: says no lane lock was held"          "$(printf '%s\n' "$out" | grep -c '^project: none - a reply lane takes no lock$')" "1"
assert_eq "undo: the base lock is untouched"          "$(awk '{print $4}' "$L/project-karta.lock")" "T-0113"
assert_eq "undo: one commit"                          "$(( $(commits) - before ))" "1"
assert_eq "undo: commit message"                      "$(git -C "$SHEPHERD_ROOT" log -1 --format=%s)" "T-0120: briefed → queued"
bash "$P" undo T-0123 >/dev/null

finish
