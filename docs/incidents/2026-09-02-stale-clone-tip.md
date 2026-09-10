# A reused clone started its worker on a stale base, and a clone could not be made without an origin

**Date:** 2026-08-24 (T-0129), 2026-09-02 (T-0215)

## What happened

A worktree is detached and nothing pulls it forward. `shepherd-wt2` sat at the commit where its last task ended, and the next dispatch into it would have branched a worker from a base weeks behind `main`; the worker noticed, shepherd had not. Separately, dispatch step 0 created clones with `git fetch origin && git worktree add … origin/<dev-branch>`, and the shepherd self-repo pattern — every instance commits to local `main` and pushes by hand, or has no `origin` at all — failed it the first time a `~N` lane was needed (T-0129).

## What changed

Both cases end at the current dev-branch tip, and a reused worktree is reset only when `git status --porcelain` is empty — what happens to uncommitted work is Saket's call, so a dirty lane undoes the dispatch and reports its path instead. `scripts/lane-prepare.sh` is that procedure now, in one place: the tip choice — whose refs are read fully qualified and verified before they are trusted, because a checkout that never created the local branch must fall to the remote ref and a tag sharing the branch's name must not win — the dirty refusal, the prune-and-rewrite of a row whose path is gone, and the two stops no script may resolve — a configured `origin` whose fetch fails, and a local branch and its remote each holding commits the other lacks. Its header is the specification, `scripts/tests/test-lane-prepare.sh` exercises every branch of it, and dispatch step 0 is the call plus the verdict table saying what shepherd does with each answer.

One thing changed on the way in. The old one-liner could only report `no origin, or the fetch failed`, because a shell running `fetch || echo` cannot tell the two apart, and so both had to stop. A script can ask, so a repo with **no** `origin` is an ordinary answer from the local ref under a `NOTE` — the T-0129 case this incident already blessed — and only a failed fetch on a configured `origin` still stops.

## Where the rule stands

`scripts/lane-prepare.sh` and its tests (the procedure); dispatch step 0 (the call and its verdict table); `docs/specs/2026-08-18-multi-shepherd-design.md` §7.2 (what the two do); retro step 6 (the worktree stays; removal only on Saket's word).
