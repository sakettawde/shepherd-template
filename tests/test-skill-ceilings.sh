#!/usr/bin/env bash
# Per-skill word ceilings — the regrowth guard (Saket, 2026-09-08; T-0255 h).
#
# T-0234 halved every skill; nothing then stopped the next incident from
# growing one back a sentence at a time. Each .md under skills has a
# ceiling here: its `wc -w` word count on main when this test was written
# (2026-09-08, a581c47) plus about 15 % headroom, rounded up. Counted by
# `wc -w < <file>` — whitespace-separated words, so a fenced block or a table
# counts like prose (docs/writing-for-agents.md § Counting); the number in a
# FAIL line is that count.
#
# A file that grows past its ceiling fails this test, and the fix is one of
# two: cut the growth, or raise the row DELIBERATELY IN THE SAME COMMIT as
# the growth, the commit message saying why the skill legitimately needs the
# words — a raise is a decision, never a reflex. A new .md under
# skills needs a row before the test passes (the last loop fails on
# an unlisted file); a deleted file's row goes with it. The T-0222 byte pin
# on the adapter reference in test-docs.sh is the tighter bound there and
# stays.
#
# Counts on main when the rows were written:
#   skills/dispatch/SKILL.md                            2148 on main → 2471
#     raised to 3047 by T-0257 (2026-09-08): step 0 stopped being four bash
#     blocks and became a call plus an eight-row verdict table, and `wc -w`
#     counts a table far more heavily than the terse commands it replaced —
#     2353 to 2649 words for strictly fewer rules, every one of them still
#     pinned in test-docs.sh. This is the ratchet re-cut at the convention
#     (count + ~15 %), not a narrative growing back.
#   skills/herdr-adapter/SKILL.md                        420 on main → 483
#   Two rows raised by T-0267, both for the plugin packaging and both paid for:
#     wake 1305 → 1520: step 1 grew from one gate to five (herdr, output style,
#       the installed plugin version against SHEPHERD_MIN_PLUGIN, the generated
#       manual's five states, and the monitor's presence). Each is a check a
#       session cannot make for itself if the words are not here.
#     adapter reference 3050 → 3200: a placeholder block (`<instance-root>`,
#       `<code-dir>`) replaced one machine's hard-coded paths, and R3 gained the
#       measured reason its PATH prepend is gone. The R3 line itself got shorter.
#   skills/herdr-adapter/references/surfaces-0.8.2.md    278 on main → 320
#   skills/herdr-adapter/references/v0.7.4.md           2742 on main → 3154
#   skills/herdr-adapter/references/v0.8.2.md           2321 on main → 2670
#     raised to 3050 by T-0256 (2026-09-08): R2's tab surface, R3's
#     detect-and-register poll and R5's stall-window finding are three
#     mechanisms with their live citations, not a narrative growing back. This
#     row and the T-0222 byte pin (21504, test-docs.sh) measure different
#     things and either can bind first as the file's density moves - the
#     header's "the byte pin is the tighter bound" is true at today's ~6.9
#     bytes per word and is not a guarantee. Both are ratchets; trim first.
#   skills/init/SKILL.md                                 708 on main → 815
#     the skill was renamed from init-shepherd and rewritten for the plugin by
#     T-0267: it no longer registers hooks by hand (the plugin ships them) and
#     it now seeds an instance skeleton. Shorter than the row it replaces.
#   skills/monitor/SKILL.md                             2602 on main → 2993
#   skills/monitor/references/inbox-drain.md            1289 on main → 1483
#   skills/onboard/SKILL.md                              720 on main → 828
#   skills/retro/SKILL.md                               1824 on main → 2098
#   skills/triage/SKILL.md                              1522 on main → 1751
#   skills/triage/references/decomposition.md            520 on main → 598
#   skills/triage/references/linear-intents.md          1814 on main → 2087
#   skills/wake/SKILL.md                                1134 on main → 1305
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
ROOT=$(cd "$HERE/.." && pwd)

echo "test-skill-ceilings:"

CEILINGS='
skills/dispatch/SKILL.md                           3047
skills/herdr-adapter/SKILL.md                      483
skills/herdr-adapter/references/surfaces-0.8.2.md  320
skills/herdr-adapter/references/v0.7.4.md          3154
skills/herdr-adapter/references/v0.8.2.md          3200
skills/init/SKILL.md                               815
skills/monitor/SKILL.md                            2993
skills/monitor/references/inbox-drain.md           1483
skills/onboard/SKILL.md                            828
skills/retro/SKILL.md                              2098
skills/triage/SKILL.md                             1751
skills/triage/references/decomposition.md          598
skills/triage/references/linear-intents.md         2087
skills/wake/SKILL.md                               1520
'

# Every listed file exists and sits within its ceiling.
while read -r path ceiling; do
  [ -n "$path" ] || continue
  f="$ROOT/$path"
  assert_file "$path exists" "$f"
  [ -f "$f" ] || continue
  words=$(wc -w < "$f")
  assert_ok "$path is within its ceiling ($words of $ceiling words; a deliberate growth raises the row in the same commit)" \
    test "$words" -le "$ceiling"
done <<<"$CEILINGS"

# Every .md under skills has a row, so growth cannot hide in a new
# file or a reference the table never learned.
while IFS= read -r f; do
  assert_ok "$f has a ceiling row" awk -v p="$f" '$1 == p { hit = 1 } END { exit !hit }' <<<"$CEILINGS"
done < <(cd "$ROOT" && find skills -name '*.md' | sort)

finish
