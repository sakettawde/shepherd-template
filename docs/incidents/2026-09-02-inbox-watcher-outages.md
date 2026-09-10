# The inbox watcher died on a Cloudflare blip, then woke shepherd hourly for nothing

**Date:** 2026-09-02 · **Cards:** T-0212 (review finding I4), T-0224

## What happened

`scripts/inbox.sh watch` polls the Linear inbox Worker every 60 s and gives up after a ceiling of consecutive failures — about twelve minutes of a Worker it cannot reach, which Cloudflare trouble or a laptop resuming ahead of its Wi-Fi both produce and both clear in minutes. As first written the ceiling exited `1`, the code both callers treat as "report and do not re-arm", so one blip retired Linear intake and the heartbeat for the rest of the session while the Worker told every new mention that shepherd was last online hours ago. The window was 3600 s: the loop costs no model tokens, but each exit 124 costs one model turn whose whole handler is "re-arm", so an idle instance woke about 24 times a day to do nothing.

## What changed

The ceiling exits `4`, meaning transient: wake step 8 and monitor both re-arm on it and say one line naming the Worker as unreachable, because a silent recovery hides an outage the operator can see from Linear's side; `1` (auth) and `3` (another instance's inbox) still report and stop. The window is 21600 s (T-0224): nothing is lost, because `cmd_watch` re-checks ownership on every heartbeat tick and once more before it hands over a drain — which is also why arming on `inbox.sh owner`'s exit 1 (an unreachable `/health`) is safe, the loop settles ownership itself and exits 3 the moment the Worker names another instance.

## Where the rule stands

Wake step 8; monitor's trigger table (the inbox watcher row); `docs/specs/linear-inbox-wiring-design.md` exit table; `scripts/inbox.sh` header.
