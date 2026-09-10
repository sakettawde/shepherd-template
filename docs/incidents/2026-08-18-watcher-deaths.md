# Three watchers died silently: a wc -l anchor twice, then an `|| echo 0`

**Date:** 2026-08-18 (T-0079, T-0080) and 2026-08-19 (T-0090)

## What happened

The status-file watcher was a hand-typed grep loop anchored on `wc -l`. `wc -l` counts newlines, and the Stop hook writes its record unterminated (the newline lands later), so the anchor was set one short and the watcher fired on a line it was meant to skip — twice, on T-0079 and T-0080. The anchor moved to a count of terminal claims, and on T-0090 a shepherd wrote it as `C=$(grep -c ... || echo 0)`. `grep -c` prints `0` **and exits 1** on no match, so the variable held the two-line string `0\n0`; `[ "$n" -gt "$C" ]` failed every iteration with `[: Illegal number: 0`, the loop spun to its timeout, and the completion was caught only because an unrelated stale watcher happened to wake shepherd. The failure looked exactly like a quiet worker.

## What changed

The recipe became code: `scripts/watch.sh` (T-0214) computes the anchor in Python over parsed records — the count of wake-worthy records, immune to the unterminated last line, needing no `|| echo 0` — and one predicate, `wake_count`, is read by both the anchor and the loop so the two can never drift. No skill restates the loop, and the test suite asserts that none carries a `grep -c`. Two rules survive in prose: a wait that can only ever time out is worse than no wait, because a heartbeat exit is indistinguishable from a healthy quiet task; and never pipe a watcher command, because a pipe reports the last command's exit status ([2026-08-22-t0093-cluster.md](2026-08-22-t0093-cluster.md)).

## Where the rule stands

Adapter R5 (the anchor, the never-pipe rule); `scripts/watch.sh` is the implementation.
