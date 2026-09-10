#!/usr/bin/env bash
# shepherd-lane: dispatch step 0 as one verdict. Every branch of the procedure
# has a case here — creation, reuse at the tip, a stale tip reset, the dirty
# refusal, the no-origin fallback, the two stops (diverged, fetch failed), the
# reply lane and its leftover, a row whose path is gone, and the dry run that
# prints a verdict and changes nothing.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
P="$HERE/../bin/shepherd-lane"
T="$SHEPHERD_ROOT/ledger/tasks"
REG="$SHEPHERD_ROOT/registry/projects"
R="$SHEPHERD_ROOT/repos"
export SHEPHERD_ID=shepherd-kelpie
mkdir -p "$REG" "$R"

echo "test-lane-prepare:"

g() { git -C "$1" -c user.email=t@t -c user.name=T "${@:2}"; }

# --- fixtures -----------------------------------------------------------------
# newrepo <name> [no-origin] — a parent checkout on main with two commits,
# pushed to its own bare origin unless told otherwise. It ignores `.env`,
# because the seed files a lane is given are gitignored in every project that
# has them: an unignored seed would read as dirt on the next reuse and refuse
# the lane it was just copied into.
newrepo() {
  local n=$1 origin=${2:-with-origin}
  git init -q -b main "$R/$n"
  printf '.env\n' > "$R/$n/.gitignore"
  g "$R/$n" add .gitignore
  g "$R/$n" commit -q -m one
  g "$R/$n" commit -q --allow-empty -m two
  if [ "$origin" = with-origin ]; then
    git init -q --bare "$R/$n-origin.git"
    g "$R/$n" remote add origin "$R/$n-origin.git"
    g "$R/$n" push -q origin main
  fi
}

registry() {  # <slug> <parent> <clone-seed> <install> [clone rows...]
  local slug=$1 parent=$2 seed=$3 inst=$4; shift 4
  {
    printf '# %s\npath: %s\nstack: x\ntest: true\ndev-branch: main\nworking-agreement: none\nonboarded: yes\nactive-task: none\npane: none\nclone-seed: %s\ninstall: %s\nkeywords: %s\n\n' \
      "$slug" "$parent" "$seed" "$inst" "$slug"
    printf '## Product\np\n\n## Context notes\n\n## Gotchas\n\n## History\n\n## Clones\n| clone-id | path | active-task | pane |\n|---|---|---|---|\n'
    for row in "$@"; do printf '%s\n' "$row"; done
  } > "$REG/$slug.md"
}

card() {  # <id> <state> <owner> <project> [kind]
  local id=$1 st=$2 own=$3 proj=$4 kind=${5:-build}
  printf '# %s: fixture\nstate: %s\nowner: %s\nproject: %s\nkind: %s\npane: none   session: none\ncreated: 2026-09-01T09:00\n\nDepends on: none\n\n## Brief\n\n## Log\n- 09:00 captured\n' \
    "$id" "$st" "$own" "$proj" "$kind" > "$T/$id.md"
}

first() { printf '%s\n' "$1" | head -1; }
detail() { printf '%s\n' "$1" | sed -n "s/^$2: //p" | head -1; }
head_of() { git -C "$1" rev-parse HEAD 2>/dev/null; }

# --- the base checkout is never prepared --------------------------------------
newrepo karta
registry karta "$R/karta" .env true
card T-0201 briefed shepherd-kelpie karta
before=$(head_of "$R/karta")
out=$(bash "$P" T-0201); rc=$?
assert_eq "a base-lane card is READY with nothing to do" "$(first "$out")" "READY karta"
assert_eq "READY exits 0"                                "$rc" "0"
assert_eq "the base row says so"                         "$(detail "$out" row)" "base"
assert_ok "and the action says the base is never prepared" \
  grep -q '^action: none - the base checkout is never prepared' <<<"$out"
assert_eq "the base checkout did not move"               "$(head_of "$R/karta")" "$before"

# --- a fresh worktree: creation ------------------------------------------------
card T-0202 briefed shepherd-kelpie karta~2
printf 'secret\n' > "$R/karta/.env"
out=$(bash "$P" T-0202); rc=$?
assert_eq "a lane with no row is created"       "$(first "$out")" "READY karta~2"
assert_eq "creation exits 0"                    "$rc" "0"
assert_eq "the row is reported missing"         "$(detail "$out" row)" "missing"
assert_eq "the path is derived from the lane id" "$(detail "$out" path)" "$R/karta-wt2"
assert_ok "the worktree is there"               test -d "$R/karta-wt2"
assert_eq "and detached at the tip"             "$(head_of "$R/karta-wt2")" "$(head_of "$R/karta")"
assert_eq "the branch is detached, not checked out" \
  "$(git -C "$R/karta-wt2" branch --show-current)" ""
assert_file "the seed was copied"               "$R/karta-wt2/.env"
assert_ok "the seed line counts what was copied" grep -q '^seed: 1 copied, 0 of 1 not in the parent' <<<"$out"
assert_ok "the install ran"                     grep -q '^install: ran: true' <<<"$out"
assert_ok "shepherd is asked for the row it must write" \
  grep -qF "row-needed: karta~2 $R/karta-wt2 write" <<<"$out"

# --- reuse: already at the tip -------------------------------------------------
registry karta "$R/karta" .env true "| karta~2 | $R/karta-wt2 | none | none |"
out=$(bash "$P" T-0202)
assert_eq "an existing row is reused"           "$(detail "$out" row)" "existing"
assert_eq "a lane already at the tip is left alone" "$(detail "$out" action)" "already-at-tip"
assert_ok "an existing lane keeps its seed"     grep -q '^seed: skipped' <<<"$out"
assert_ok "an existing lane keeps its install"  grep -q '^install: skipped' <<<"$out"
assert_fail "and no row is asked for"           grep -q '^row-needed:' <<<"$out"

# --- reuse: a stale tip is reset ----------------------------------------------
# A worktree is detached and nothing pulls it forward (T-0129): parked at the
# first commit, it must come back to the tip of the dev branch.
old=$(git -C "$R/karta" rev-parse HEAD~1)
git -C "$R/karta-wt2" checkout -q --detach "$old"
g "$R/karta" commit -q --allow-empty -m three
g "$R/karta" push -q origin main
tip=$(head_of "$R/karta")
out=$(bash "$P" T-0202); rc=$?
assert_eq "a stale lane is reset"               "$rc" "0"
assert_ok "the action names both ends of the move, and the ref it used" \
  grep -qF "action: reset from ${old:0:12} to origin/main" <<<"$out"
assert_eq "and the lane is at the tip"          "$(head_of "$R/karta-wt2")" "$tip"

# --- the dirty refusal ---------------------------------------------------------
git -C "$R/karta-wt2" checkout -q --detach "$old"
printf 'work in progress\n' > "$R/karta-wt2/WIP.txt"
out=$(bash "$P" T-0202); rc=$?
assert_eq "uncommitted work is refused"         "$(first "$out")" "HOLD dirty $R/karta-wt2"
assert_eq "HOLD exits 1"                        "$rc" "1"
assert_eq "the lane did not move"               "$(head_of "$R/karta-wt2")" "$old"
assert_file "and the uncommitted file is untouched" "$R/karta-wt2/WIP.txt"
assert_ok "the porcelain lines are shown"       grep -q '^?? WIP.txt' <<<"$out"
assert_ok "and the next line sends it to undo"  grep -q '^next: undo the claim' <<<"$out"
rm -f "$R/karta-wt2/WIP.txt"

# --- the dry run prints a verdict and changes nothing --------------------------
git -C "$R/karta-wt2" checkout -q --detach "$old"
listing_before=$(ls -1 "$R")
out=$(bash "$P" T-0202 --dry-run); rc=$?
assert_eq "a dry run answers READY"             "$(first "$out")" "READY karta~2"
assert_eq "a dry run exits 0"                   "$rc" "0"
assert_ok "the action is the one it would take" grep -q '^action: would-reset from' <<<"$out"
assert_eq "the lane did not move"               "$(head_of "$R/karta-wt2")" "$old"
assert_ok "and it says the fetch was skipped"   grep -q '^fetch: skipped (dry run)' <<<"$out"
card T-0203 briefed shepherd-kelpie karta~7
out=$(bash "$P" T-0203 --dry-run)
assert_ok "a dry run on a lane with no worktree says it would create it" \
  grep -q '^action: would-create at ' <<<"$out"
assert_nofile "and creates nothing"             "$R/karta-wt7/.git"
assert_ok "no directory appeared"               test ! -e "$R/karta-wt7"
assert_eq "nothing at all appeared beside the lanes" "$(ls -1 "$R")" "$listing_before"
assert_ok "a dry run says what it would copy"   grep -q '^seed: would copy 1, 0 of 1 not in the parent' <<<"$out"
assert_ok "and what it would run"               grep -q '^install: would run: true' <<<"$out"
# a dry run reads a card in any state, and says which
card T-0204 working shepherd-kelpie karta~2
out=$(bash "$P" T-0204 --dry-run); rc=$?
assert_eq "a dry run reads a working card"      "$rc" "0"
assert_ok "and notes the state it read"         grep -q '^NOTE state working: a dry run reads any state' <<<"$out"
out=$(bash "$P" T-0204); rc=$?
assert_eq "the acting run refuses it"           "$(first "$out")" "REFUSED T-0204 is working, not briefed"
assert_eq "REFUSED exits 1"                     "$rc" "1"
assert_eq "and the lane a worker holds did not move" "$(head_of "$R/karta-wt2")" "$old"

# --- a row whose path is gone: prune, recreate, rewrite the row ----------------
# The directory goes without `git worktree remove`, which is how a lane really
# disappears, so the parent is left holding an administrative entry that would
# refuse `worktree add` at the same path until it is pruned.
rm -rf "$R/karta-wt2"
assert_file "the parent still holds the stale entry" "$R/karta/.git/worktrees/karta-wt2/gitdir"
out=$(bash "$P" T-0202); rc=$?
assert_eq "a row whose path is gone still succeeds" "$rc" "0"
assert_eq "the row is reported gone"            "$(detail "$out" row)" "gone"
assert_ok "and it says the path was not there"  grep -q '^NOTE row path gone:' <<<"$out"
assert_ok "the worktree is back"                test -d "$R/karta-wt2"
assert_ok "the row is rewritten, not added"     grep -qF "row-needed: karta~2 $R/karta-wt2 rewrite" <<<"$out"
assert_ok "and the lane is registered again"    grep -qF "$R/karta-wt2" <<<"$(git -C "$R/karta" worktree list --porcelain)"

# --- the no-origin fallback ----------------------------------------------------
# The self-repo pattern: every instance commits to local main and pushes by
# hand, or has no origin at all (T-0129). The local ref is the tip, and the
# script says which of "no origin" and "the fetch failed" it saw.
newrepo solo no-origin
registry solo "$R/solo" none true
card T-0205 briefed shepherd-kelpie solo~2
out=$(bash "$P" T-0205); rc=$?
assert_eq "a parent with no origin still prepares its lane" "$rc" "0"
assert_eq "the fetch line names the absence"    "$(detail "$out" fetch)" "none (no origin remote)"
assert_ok "the tip comes from the local ref"    grep -qE '^tip: main [0-9a-f]{12} \(local\)' <<<"$out"
assert_ok "and a NOTE cites the case"           grep -q '^NOTE no origin: ' <<<"$out"
assert_eq "the lane is at the local tip"        "$(head_of "$R/solo-wt2")" "$(head_of "$R/solo")"
assert_ok "clone-seed: none copies nothing"     grep -q '^seed: none (nothing to copy)' <<<"$out"

# --- a configured origin whose fetch fails is the stop -------------------------
newrepo broken
g "$R/broken" remote set-url origin "$R/no-such-origin.git"
registry broken "$R/broken" none true
card T-0206 briefed shepherd-kelpie broken~2
out=$(bash "$P" T-0206); rc=$?
assert_eq "a failed fetch is a JUDGE, not a NOTE" "$(first "$out" | cut -d' ' -f1-3)" "JUDGE fetch failed:"
assert_eq "JUDGE exits 3"                       "$rc" "3"
assert_ok "nothing was created"                 test ! -e "$R/broken-wt2"
assert_ok "and the operator decides"                   grep -q '^next: undo the claim (dispatch step 6) and report to the operator' <<<"$out"

# --- diverged: neither ref is the tip ------------------------------------------
newrepo forked
g "$R/forked" commit -q --allow-empty -m "local only"
# rewind origin/main's remote-tracking ref onto a commit the local branch never had
g "$R/forked" push -q origin "HEAD~2:refs/heads/side"
g "$R/forked" checkout -q -b side origin/side
g "$R/forked" commit -q --allow-empty -m "remote only"
g "$R/forked" push -q -f origin side:main
g "$R/forked" checkout -q main
g "$R/forked" fetch -q origin
registry forked "$R/forked" none true
card T-0207 briefed shepherd-kelpie forked~2
out=$(bash "$P" T-0207); rc=$?
assert_eq "a diverged dev branch is a JUDGE"    "$(first "$out" | cut -d' ' -f1-2)" "JUDGE diverged:"
assert_eq "JUDGE exits 3"                       "$rc" "3"
assert_ok "nothing was created"                 test ! -e "$R/forked-wt2"

# --- the reply lane: the same call, no row, no install -------------------------
card T-0208 briefed shepherd-kelpie karta reply
out=$(bash "$P" T-0208); rc=$?
assert_eq "a reply card prepares its own lane"  "$(first "$out")" "READY reply-T-0208"
assert_eq "reply exits 0"                       "$rc" "0"
assert_eq "the lane path is the throwaway one"  "$(detail "$out" path)" "$R/karta-reply-T-0208"
assert_eq "it is no clone row"                  "$(detail "$out" row)" "reply"
assert_ok "the worktree is there, at the tip"   test -d "$R/karta-reply-T-0208"
assert_eq "and detached at the tip"             "$(head_of "$R/karta-reply-T-0208")" "$(head_of "$R/karta")"
assert_ok "a reply lane runs no install"        grep -q '^install: skipped (reply lane: seed only)' <<<"$out"
assert_file "but it is seeded like a clone"     "$R/karta-reply-T-0208/.env"
assert_fail "and asks for no ## Clones row"     grep -q '^row-needed:' <<<"$out"

# a lane path that is already there is a leftover, never adopted: git would
# take an existing directory rather than refuse it (git 2.43.0, 2026-09-08)
card T-0209 briefed shepherd-kelpie karta reply
mkdir -p "$R/karta-reply-T-0209"
printf 'left over\n' > "$R/karta-reply-T-0209/answer.md"
out=$(bash "$P" T-0209); rc=$?
assert_eq "a leftover lane path is refused"     "$(first "$out" | cut -d' ' -f1-4)" "HOLD lane path exists:"
assert_eq "HOLD exits 1"                        "$rc" "1"
assert_ok "the reason names git's adoption"     grep -q 'git would adopt it rather than refuse it' <<<"$out"
assert_file "and the leftover is untouched"     "$R/karta-reply-T-0209/answer.md"
assert_ok "no worktree was registered for it" \
  test -z "$(git -C "$R/karta" worktree list --porcelain | grep -F "$R/karta-reply-T-0209")"

# --- --tip overrides the resolved tip (a review reply sits at the PR head) -----
card T-0210 briefed shepherd-kelpie karta reply
pr=$(git -C "$R/karta" rev-parse HEAD~1)
out=$(bash "$P" T-0210 --tip "$pr"); rc=$?
assert_eq "a given tip is used"                 "$rc" "0"
assert_eq "and the lane sits on it"             "$(head_of "$R/karta-reply-T-0210")" "$pr"
assert_ok "the tip line says it was given"      grep -qF "tip: $pr ${pr:0:12} (given)" <<<"$out"
card T-0211 briefed shepherd-kelpie karta reply
out=$(bash "$P" T-0211 --tip origin/no-such-branch); rc=$?
assert_eq "a tip that does not resolve is an ERROR" \
  "$(first "$out")" "ERROR --tip origin/no-such-branch does not resolve in $R/karta"
assert_eq "ERROR exits 2"                       "$rc" "2"

# --- the gates that come before any git call -----------------------------------
card T-0212 briefed shepherd-collie karta~3
out=$(bash "$P" T-0212); rc=$?
assert_eq "another instance's card is refused"  "$(first "$out")" "REFUSED T-0212 is owned by shepherd-collie, not shepherd-kelpie"
assert_eq "REFUSED exits 1"                     "$rc" "1"
out=$(bash "$P" T-9999); rc=$?
assert_eq "a card that is not there is an ERROR" "$(first "$out" | cut -d' ' -f1-2)" "ERROR no"
assert_eq "ERROR exits 2"                       "$rc" "2"
out=$(bash "$P" nonsense); rc=$?
assert_eq "a bad id is an ERROR"                "$(first "$out")" "ERROR bad task id: nonsense"
assert_eq "and exits 2"                         "$rc" "2"
card T-0213 briefed shepherd-kelpie ghost~2
out=$(bash "$P" T-0213); rc=$?
assert_eq "a project with no registry card is an ERROR" \
  "$(first "$out")" "ERROR no registry card: $REG/ghost.md"
assert_eq "and exits 2"                         "$rc" "2"
registry noparent "$R/not-a-repo" none true
card T-0214 briefed shepherd-kelpie noparent~2
out=$(bash "$P" T-0214); rc=$?
assert_eq "a parent that is no working tree is an ERROR" \
  "$(first "$out")" "ERROR parent $R/not-a-repo is not a git working tree"
assert_eq "and exits 2"                         "$rc" "2"
out=$(env -u SHEPHERD_ID bash "$P" T-0202); rc=$?
assert_eq "an unset SHEPHERD_ID fails closed"   "$(first "$out")" "ERROR SHEPHERD_ID is unset"
assert_eq "and exits 2"                         "$rc" "2"

# --- the tip choice: which of the two refs actually won ------------------------
# Inverting the whole preference rule once passed all 98 assertions: every
# fixture above is at parity with its origin, origin-less, unreachable or
# diverged, so the two arms that decide between a live local and a live remote
# were never reached (T-0257 review). These name the winner.
newrepo ahead
g "$R/ahead" commit -q --allow-empty -m "local only, never pushed"
registry ahead "$R/ahead" none true
card T-0215 briefed shepherd-kelpie ahead~2
out=$(bash "$P" T-0215); rc=$?
assert_eq "a local branch strictly ahead of origin wins" "$rc" "0"
assert_eq "and the tip says so"  "$(detail "$out" tip)" "main $(git -C "$R/ahead" rev-parse --short=12 HEAD) (local)"
assert_eq "the lane is at the unpushed commit" "$(head_of "$R/ahead-wt2")" "$(head_of "$R/ahead")"

# no local branch at all — the remote-only arm, which nothing reached either
git init -q -b scratch "$R/remoteonly"
g "$R/remoteonly" remote add origin "$R/karta-origin.git"
g "$R/remoteonly" fetch -q origin
registry remoteonly "$R/remoteonly" none true
card T-0216 briefed shepherd-kelpie remoteonly~2
out=$(bash "$P" T-0216); rc=$?
assert_eq "a checkout that never made the local branch falls to the remote ref" "$rc" "0"
assert_ok "and the tip says so" grep -qE '^tip: origin/main [0-9a-f]{12} \(remote\)' <<<"$out"
assert_eq "the lane is at origin/main" \
  "$(head_of "$R/remoteonly-wt2")" "$(git -C "$R/remoteonly" rev-parse origin/main)"

# A tag named like the dev branch must lose to the branch, twice over:
# gitrevisions resolves `refs/tags/main` BEFORE `refs/heads/main`, so a bare
# name would pick the tag when the tip is read AND again when the lane is moved
# onto it. Refs are read fully qualified and the lane is moved by SHA, so
# neither reads the tag. No origin here, so the local ref is the tip and the
# tag is the only other candidate.
newrepo tagged no-origin
tag_at=$(git -C "$R/tagged" rev-parse HEAD~1)
branch_at=$(git -C "$R/tagged" rev-parse refs/heads/main)
g "$R/tagged" tag main "$tag_at"
registry tagged "$R/tagged" none true
card T-0217 briefed shepherd-kelpie tagged~2
out=$(bash "$P" T-0217)
assert_eq "the tip is read from refs/heads, not the same-named tag" \
  "$(head_of "$R/tagged-wt2")" "$branch_at"
git -C "$R/tagged-wt2" checkout -q --detach "$tag_at"
registry tagged "$R/tagged" none true "| tagged~2 | $R/tagged-wt2 | none | none |"
out=$(bash "$P" T-0217)
assert_eq "and a reused lane is moved onto the branch, not the tag" \
  "$(head_of "$R/tagged-wt2")" "$branch_at"
assert_eq "so the lane really moved"           "$(detail "$out" action | cut -d' ' -f1)" "reset"

# --- a lane path that is not this project's worktree ---------------------------
# The dirty check is not this guard: an unrelated CLEAN repo sailed through it,
# was detached off its own branch and reset onto its OWN origin/main, and a
# worker would then have been launched into the wrong repository (T-0257 review).
newrepo host
newrepo stranger
g "$R/stranger" checkout -q -b feature
g "$R/stranger" commit -q --allow-empty -m "the stranger's own work"
stranger_head=$(head_of "$R/stranger")
registry host "$R/host" none true "| host~2 | $R/stranger | none | none |"
card T-0218 briefed shepherd-kelpie host~2
out=$(bash "$P" T-0218); rc=$?
assert_eq "a different repository at the lane path is refused" \
  "$(first "$out" | cut -d' ' -f1-9)" "HOLD lane path is not a worktree of $R/host:"
assert_eq "HOLD exits 1"                       "$rc" "1"
assert_ok "the reason names the shared object store" grep -q 'shares no object store' <<<"$out"
assert_eq "the stranger stayed on its branch"  "$(git -C "$R/stranger" branch --show-current)" "feature"
assert_eq "and did not move"                   "$(head_of "$R/stranger")" "$stranger_head"

mkdir -p "$R/host-plain"
registry host "$R/host" none true "| host~2 | $R/host-plain | none | none |"
out=$(bash "$P" T-0218); rc=$?
assert_eq "a plain directory at the lane path is refused too" \
  "$(first "$out" | cut -d' ' -f1-9)" "HOLD lane path is not a worktree of $R/host:"
assert_ok "and says it is no git working tree at all" grep -q 'not a git working tree at all' <<<"$out"

# --- a creation that fails after the worktree exists takes it back out ---------
# Without the rollback a failed `npm install` leaves the path in place, the next
# run refuses it as a leftover, and the skill's own rule forbids removing one —
# so the lane number is burnt for good (T-0257 review).
newrepo badinstall
registry badinstall "$R/badinstall" none 'sh -c "echo could not reach the registry >&2; exit 7"'
card T-0219 briefed shepherd-kelpie badinstall~2
out=$(bash "$P" T-0219); rc=$?
assert_eq "a failed install holds"             "$(first "$out")" "HOLD install failed in $R/badinstall-wt2"
assert_eq "HOLD exits 1"                       "$rc" "1"
assert_ok "the failing command and its exit code are named" \
  grep -qE '^install: failed: .*\(exit 7\)' <<<"$out"
assert_ok "its output is shown"                grep -q 'could not reach the registry' <<<"$out"
assert_ok "the worktree was taken back out"    test ! -e "$R/badinstall-wt2"
assert_ok "and the action says the path is free again" \
  grep -q '^action: rolled back: the worktree this call created was removed' <<<"$out"
assert_ok "no row is asked for, since nothing was created" \
  test -z "$(grep '^row-needed:' <<<"$out")"
assert_ok "the parent holds no registration for it" \
  test -z "$(git -C "$R/badinstall" worktree list --porcelain | grep -F "$R/badinstall-wt2")"
# and the next run is a clean creation, not a leftover refusal
registry badinstall "$R/badinstall" none true
out=$(bash "$P" T-0219); rc=$?
assert_eq "so the lane number is not burnt"    "$rc" "0"
assert_eq "the next run creates it"            "$(detail "$out" action | cut -d' ' -f1)" "created"

# a seed present in the parent but uncopyable is a stop, not "not present"
newrepo badseed
printf 'secret\n' > "$R/badseed/.env"
chmod 000 "$R/badseed/.env"
registry badseed "$R/badseed" '.env .missing' true
card T-0220 briefed shepherd-kelpie badseed~2
out=$(bash "$P" T-0220); rc=$?
assert_eq "a seed that cannot be copied holds" "$(first "$out")" "HOLD seed copy failed for $R/badseed-wt2"
assert_eq "HOLD exits 1"                       "$rc" "1"
assert_ok "the seed line names the file, and that the parent HAS it" \
  grep -q '^seed: failed on .env (present in the parent, not copied)' <<<"$out"
assert_ok "the worktree was taken back out"    test ! -e "$R/badseed-wt2"
chmod 644 "$R/badseed/.env"

# a worktree that cannot be added at all
newrepo locked
mkdir -p "$R/locked-box"
g "$R/locked-box" 2>/dev/null || true
registry locked "$R/locked" none true "| locked~2 | $R/locked-box/lane | none | none |"
rm -rf "$R/locked-box/lane"; chmod 500 "$R/locked-box"
card T-0221 briefed shepherd-kelpie locked~2
out=$(bash "$P" T-0221); rc=$?
assert_eq "a worktree that cannot be added holds" \
  "$(first "$out")" "HOLD worktree add failed for $R/locked-box/lane"
assert_eq "HOLD exits 1"                       "$rc" "1"
assert_ok "git's own message is shown"         test -n "$(grep -i 'permission denied\|could not create\|fatal' <<<"$out")"
chmod 700 "$R/locked-box"

# a checkout that fails on a clean lane. The dirty gate passes it — porcelain
# reads a read-only tree fine — so this is the failure that gate cannot see,
# and the reason a failed checkout has a verdict of its own.
newrepo blocked
card T-0222 briefed shepherd-kelpie blocked~2
registry blocked "$R/blocked" none true
out=$(bash "$P" T-0222)
assert_eq "the lane is created"                "$(detail "$out" action | cut -d' ' -f1)" "created"
printf 'new\n' > "$R/blocked/added.txt"
g "$R/blocked" add added.txt; g "$R/blocked" commit -qm "a file the lane must gain"
g "$R/blocked" push -q origin main
registry blocked "$R/blocked" none true "| blocked~2 | $R/blocked-wt2 | none | none |"
assert_ok "the lane is clean before the attempt" \
  test -z "$(git -C "$R/blocked-wt2" status --porcelain)"
adm=$(git -C "$R/blocked-wt2" rev-parse --absolute-git-dir)
chmod 500 "$adm"
out=$(bash "$P" T-0222); rc=$?
chmod 700 "$adm"
assert_eq "a checkout that fails holds"        "$(first "$out")" "HOLD checkout failed in $R/blocked-wt2"
assert_eq "HOLD exits 1"                       "$rc" "1"
assert_ok "git's own message is shown"         test -n "$(grep -iE 'fatal|error|denied' <<<"$out")"

# --- the registry's two optional fields, defaulted -----------------------------
newrepo defaults
printf 'v\n' > "$R/defaults/.dev.vars"; printf 'e\n' > "$R/defaults/.env"
registry defaults "$R/defaults" none true
sed -i '/^clone-seed:/d; s/^install: true/install: none/' "$REG/defaults.md"
card T-0223 briefed shepherd-kelpie defaults~2
out=$(bash "$P" T-0223); rc=$?
assert_eq "an absent clone-seed takes the default set" "$rc" "0"
assert_ok "which is the three the manual names"        grep -q '^seed: 2 copied, 1 of 3 not in the parent' <<<"$out"
assert_file ".dev.vars came across"                    "$R/defaults-wt2/.dev.vars"
assert_file "and .env"                                 "$R/defaults-wt2/.env"
assert_ok "install: none runs nothing"                 grep -q '^install: none (nothing to run)' <<<"$out"

# a trailing slash on the registry path must not build the lane inside the parent
newrepo slashy
registry slashy "$R/slashy/" none true
card T-0224 briefed shepherd-kelpie slashy~2
out=$(bash "$P" T-0224)
assert_eq "the lane sits beside the parent, not inside it" "$(detail "$out" path)" "$R/slashy-wt2"
assert_ok "and the parent is clean"            test -z "$(git -C "$R/slashy" status --porcelain)"

# --tip on an existing lane, and on a base card where it cannot apply
card T-0225 briefed shepherd-kelpie karta~2
pin=$(git -C "$R/karta" rev-parse HEAD~1)
out=$(bash "$P" T-0225 --tip "$pin"); rc=$?
assert_eq "a given tip resets an existing lane to it" "$rc" "0"
assert_eq "and the lane is on it"              "$(head_of "$R/karta-wt2")" "$pin"
card T-0226 briefed shepherd-kelpie karta
out=$(bash "$P" T-0226 --tip "$pin")
assert_ok "a base card says the given tip went unused" \
  grep -q '^NOTE --tip .* is unused: a base checkout is never moved to a tip' <<<"$out"
# and an origin-less parent given a tip does not also claim the local ref
card T-0227 briefed shepherd-kelpie solo~3
out=$(bash "$P" T-0227 --tip "$(git -C "$R/solo" rev-parse HEAD~1)")
assert_fail "the no-origin NOTE does not contradict a given tip" grep -q '^NOTE no origin:' <<<"$out"

# --- the rest of the header's ERROR list ---------------------------------------
card T-0228 briefed shepherd-kelpie karta~x
out=$(bash "$P" T-0228); rc=$?
assert_eq "a project that is neither the family nor a ~N is an ERROR" \
  "$(first "$out")" "ERROR karta~x is neither karta nor karta~<N>"
assert_eq "and exits 2"                        "$rc" "2"
card T-0229 briefed shepherd-kelpie karta~2 audit
out=$(bash "$P" T-0229); rc=$?
assert_eq "a kind that is neither build nor reply is an ERROR" \
  "$(first "$out")" "ERROR T-0229 kind: audit is neither build nor reply"
assert_eq "and exits 2"                        "$rc" "2"
registry nobranch "$R/karta" none true
sed -i '/^dev-branch:/d' "$REG/nobranch.md"
card T-0230 briefed shepherd-kelpie nobranch~2
out=$(bash "$P" T-0230); rc=$?
assert_eq "a registry card with no dev-branch is an ERROR" \
  "$(first "$out")" "ERROR registry card nobranch has no dev-branch:"
assert_eq "and exits 2"                        "$rc" "2"
newrepo notip
g "$R/notip" checkout -q -b other
g "$R/notip" branch -q -d main
registry notip "$R/notip" none true
sed -i 's/^dev-branch: main/dev-branch: nowhere/' "$REG/notip.md"
card T-0231 briefed shepherd-kelpie notip~2
out=$(bash "$P" T-0231); rc=$?
assert_eq "a dev branch that exists on neither side is an ERROR" \
  "$(first "$out")" "ERROR no tip: neither nowhere nor origin/nowhere exists in $R/notip"
assert_eq "and exits 2"                        "$rc" "2"
out=$(SHEPHERD_ID=Shepherd_Kelpie bash "$P" T-0202); rc=$?
assert_eq "a malformed SHEPHERD_ID fails closed" "$(first "$out")" "ERROR bad SHEPHERD_ID: Shepherd_Kelpie"
assert_eq "and exits 2"                        "$rc" "2"
out=$(bash "$P" T-0202 --tip); rc=$?
assert_eq "a --tip with no value is a usage ERROR" "$(first "$out" | cut -d' ' -f1-2)" "ERROR usage:"
assert_eq "and exits 2"                        "$rc" "2"

# --- the usage line the skill quotes -------------------------------------------
assert_ok "the header carries the usage the skill calls" \
  grep -qF 'shepherd-lane T-NNNN [--dry-run] [--tip <ref>]' "$P"

finish
