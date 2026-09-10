#!/usr/bin/env bash
# shepherd-metrics runs over a fixture ledger copied into the sandbox. The git history the
# concurrency measure reads is built here, at fixed dates, so every number is known.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
M="$HERE/../bin/shepherd-metrics"
FIX="$HERE/fixtures/metrics"
# The context measure reads the wake skill and the adapter reference from the
# PLUGIN root, not the instance root (lib/metrics.py). The fixture stands in for
# both, so point the override at the same copied tree.
T="$SHEPHERD_ROOT/ledger/tasks"
J="$SHEPHERD_ROOT/out.json"
NOW="2026-09-01T14:00:00+00:00"
export SHEPHERD_MEMORY_INDEX="$SHEPHERD_ROOT/memory/MEMORY.md"

echo "test-metrics:"

# --- fixture + git history -------------------------------------------------
cp -R "$FIX/." "$SHEPHERD_ROOT/"
# The fixture stands in for the plugin as well, so the wake skill and the adapter
# reference resolve inside it.
export SHEPHERD_PLUGIN_ROOT="$SHEPHERD_ROOT"
# The inbox log (T-0237; spec 2026-09-07 §7), both shapes and every outcome. NOW
# is 14:00Z. Event 1 is in `all` only, 2 in `week` too, 3-10 and 13 in `since
# 2026-09-01` as well (12:00Z or later, which is past local midnight for every
# offset); 11 lies past --now. Event 10's received-at is not a time; 12 has eight
# columns; 14's bare `carded` is outside the vocabulary; 15's received-at is after
# its drain-start (a clock behind the Worker's); 98's and 99's answered lines have
# no event; 8's answered line lands past --now; 20 was drained twice, so its one
# answered line joins both lines.
# A separate root with no log at all is the missing-log case.
cat > "$SHEPHERD_ROOT/ledger/inbox.log" <<'LOG'
2026-08-20T10:00:00+00:00 1 s1 created ask operator answered 2026-08-20T09:50:00+00:00 2026-08-20T10:03:00+00:00
2026-08-28T09:00:00+00:00 2 s2 prompted build member carded:T-0001 2026-08-28T08:00:00+00:00 2026-08-28T09:02:00+00:00
answered 2 2026-08-28T11:00:00+00:00
2026-09-01T12:00:00+00:00 3 s3 prompted ask operator answered 2026-09-01T11:59:00+00:00 2026-09-01T12:05:00+00:00
2026-09-01T12:10:00+00:00 4 none created build operator carded:T-0002 2026-09-01T12:00:00+00:00 2026-09-01T12:11:00+00:00
2026-09-01T12:20:00+00:00 5 s5 prompted status unknown refused 2026-09-01T12:19:00+00:00 2026-09-01T12:21:00+00:00
2026-09-01T12:30:00+00:00 6 s6 prompted readiness member asked 2026-09-01T12:29:00+00:00 2026-09-01T12:34:00+00:00
2026-09-01T12:33:00+00:00 13 s13 prompted estimate operator answered 2026-09-01T12:32:00+00:00 2026-09-01T12:36:00+00:00
2026-09-01T12:40:00+00:00 7 s7 comment_reply ask operator routed:T-0003 2026-09-01T12:39:00+00:00 2026-09-01T12:41:00+00:00
answered 7 2026-09-01T13:40:00+00:00
2026-09-01T12:42:00+00:00 20 s20 prompted ask member carded:T-0005 2026-09-01T12:41:00+00:00 2026-09-01T12:43:00+00:00
2026-09-01T12:44:00+00:00 20 s20 prompted ask member carded:T-0005 2026-09-01T12:41:00+00:00 2026-09-01T12:45:00+00:00
answered 20 2026-09-01T12:54:00+00:00
answered 98 2026-08-27T10:00:00+00:00
2026-09-01T12:50:00+00:00 8 s8 prompted build member held:T-0004 2026-09-01T12:49:00+00:00 2026-09-01T12:52:00+00:00
answered 8 2026-09-01T15:00:00+00:00
2026-09-01T13:00:00+00:00 9 s9 prompted stop operator ignored 2026-09-01T12:58:00+00:00 2026-09-01T13:00:40+00:00
answered 99 2026-09-01T13:00:00+00:00
this line is garbage
2026-09-01T13:30:00+00:00 10 s10 prompted ask operator answered not-a-time 2026-09-01T13:31:00+00:00
2026-09-01T13:35:00+00:00 12 s12 prompted ask operator answered 2026-09-01T13:34:00+00:00
2026-09-01T13:36:00+00:00 14 s14 prompted build member carded 2026-09-01T13:35:00+00:00 2026-09-01T13:37:00+00:00
2026-09-01T13:38:00+00:00 15 s15 prompted status operator answered 2026-09-01T13:39:00+00:00 2026-09-01T13:38:30+00:00
2026-09-02T09:00:00+00:00 11 s11 prompted ask operator answered 2026-09-02T08:59:00+00:00 2026-09-02T09:01:00+00:00
LOG
NOLOG="$SHEPHERD_ROOT/nolog"; mkdir -p "$NOLOG/ledger/tasks"
seed_instance_env "$NOLOG"
commit_at() { GIT_AUTHOR_DATE=$1 GIT_COMMITTER_DATE=$1 git -C "$SHEPHERD_ROOT" commit -q --allow-empty -m "$2"; }
set_state() { sed -i "s/^state: .*/state: $2/" "$T/$1.md"; git -C "$SHEPHERD_ROOT" add "ledger/tasks/$1.md"; }
build_history() {
  git -C "$SHEPHERD_ROOT" init -q
  git -C "$SHEPHERD_ROOT" config user.email test@example.com
  git -C "$SHEPHERD_ROOT" config user.name test
  set_state T-0001 queued; set_state T-0002 queued
  git -C "$SHEPHERD_ROOT" add -A
  commit_at 2026-09-01T09:00:00+00:00 "fixture: initial ledger"
  set_state T-0001 briefed; commit_at 2026-09-01T10:00:00+00:00 "T-0001: queued → briefed"
  set_state T-0002 briefed; commit_at 2026-09-01T11:00:00+00:00 "T-0002: queued → briefed"
  set_state T-0001 working; commit_at 2026-09-01T11:30:00+00:00 "T-0001: briefed → working"
  # T-0004 opens and closes inside one author second. Correct ordering drops the
  # zero-length span; git's own newest-first order would read done before working
  # and leave a span open to --now, which moves the histogram, max and active_hours.
  set_state T-0004 working; commit_at 2026-09-01T11:15:00+00:00 "T-0004: briefed → working"
  set_state T-0004 done;    commit_at 2026-09-01T11:15:00+00:00 "T-0004: working → done"
  set_state T-0001 done;    commit_at 2026-09-01T12:00:00+00:00 "T-0001: working → done"
  set_state T-0002 done;    commit_at 2026-09-01T13:00:00+00:00 "T-0002: briefed → done"
}
build_history
snapshot() { find "$SHEPHERD_ROOT" -type f -not -path '*/.git/*' -not -name out.json -exec md5sum {} + | sort; }
before=$(snapshot)

run_metrics() { bash "$M" "$@" --json --now "$NOW" > "$J"; }
jq_() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval("d"+sys.argv[2]))' "$J" "$1"; }

# --- argument handling -----------------------------------------------------
assert_ok   "--help exits 0"                 bash "$M" --help
assert_eq   "--help prints the definitions"  "$(bash "$M" --help | grep -c 'Definitions')" "1"
assert_fail "no mode is a usage error"       bash "$M"
assert_fail "unknown mode is a usage error"  bash "$M" fortnight
assert_fail "since without a date fails"     bash "$M" since
assert_fail "two modes fail"                 bash "$M" week all

# --- cards + filter --------------------------------------------------------
run_metrics all
assert_eq "all: total cards — the undated card is in no window" "$(jq_ '["filter"]["cards"]')" "8"
assert_eq "all: done"                 "$(jq_ '["cards"]["done"]')"              "6"
assert_eq "all: failed"               "$(jq_ '["cards"]["failed"]')"            "0"
assert_eq "all: abandoned"            "$(jq_ '["cards"]["abandoned"]')"         "1"
assert_eq "all: by_state"             "$(jq_ '["cards"]["by_state"]')"          "{'abandoned': 1, 'done': 6, 'queued': 1}"
assert_eq "all: self-maintenance"     "$(jq_ '["cards"]["self_maintenance"]')"  "1"
assert_eq "all: self-maintenance pct" "$(jq_ '["cards"]["self_maintenance_pct"]')" "12.5"
assert_eq "all: the undated card is counted, in every mode" "$(jq_ '["cards"]["missing"]')" "{'state': 0, 'created': 1}"
assert_eq "all: undated count in the filter" "$(jq_ '["filter"]["undated"]')"       "1"
assert_eq "all: filter echoes mode"   "$(jq_ '["filter"]["mode"]')"             "all"

run_metrics week
assert_eq "week: drops the 2026-08-01 card only" "$(jq_ '["filter"]["cards"]')" "7"
assert_eq "week: the undated card is counted there too" "$(jq_ '["cards"]["missing"]')" "{'state': 0, 'created': 1}"
assert_eq "week: done"                           "$(jq_ '["cards"]["done"]')"   "5"
assert_eq "week: undated card excluded but still counted" "$(jq_ '["filter"]["undated"]')" "1"

run_metrics since 2026-09-01
assert_eq "since: cards created on/after the day" "$(jq_ '["filter"]["cards"]')" "5"
assert_eq "since: echoes the date"                "$(jq_ '["filter"]["since"]')" "2026-09-01"
assert_eq "since: cards_total is unfiltered"      "$(jq_ '["filter"]["cards_total"]')" "9"

# --- measured work + wakes -------------------------------------------------
run_metrics all
assert_eq "timed: cards with duration and budget"  "$(jq_ '["timed"]["timed_cards"]')"   "4"
assert_eq "timed: hours (310+12+120+30 min)"        "$(jq_ '["timed"]["hours"]')"         "7.9"
assert_eq "timed: median ratio"                     "$(jq_ '["timed"]["median_ratio"]')"  "0.7"
assert_eq "timed: overrun count is ratio > 1 only"  "$(jq_ '["timed"]["overrun"]')"       "1"
assert_eq "timed: overrun pct"                      "$(jq_ '["timed"]["overrun_pct"]')"   "25.0"
assert_eq "timed: by size L"                        "$(jq_ '["timed"]["by_size"]["L"]')"  "{'cards': 1, 'overrun': 1, 'overrun_pct': 100.0, 'median_ratio': 1.29}"
assert_eq "timed: by size M has no overrun"         "$(jq_ '["timed"]["by_size"]["M"]["overrun"]')" "0"
assert_eq "timed: worst card first"                 "$(jq_ '["timed"]["worst"][0]["id"]')" "T-0001"
assert_eq "timed: worst ratio"                      "$(jq_ '["timed"]["worst"][0]["ratio"]')" "1.3"
assert_eq "timed: worst-five share"                 "$(jq_ '["timed"]["worst_share_pct"]')" "100.0"
assert_eq "timed: missing accounting"               "$(jq_ '["timed"]["missing"]')" "{'no_metrics_line': 1, 'unparsable_duration': 0, 'unparsable_budget': 1}"
assert_eq "wakes: cards with a figure"              "$(jq_ '["wakes"]["cards"]')"  "4"
assert_eq "wakes: total"                            "$(jq_ '["wakes"]["total"]')"  "12"
assert_eq "wakes: mean"                             "$(jq_ '["wakes"]["mean"]')"   "3.0"
assert_eq "wakes: max card"                         "$(jq_ '["wakes"]["max"]')"    "{'id': 'T-0001', 'wakes': 6}"
assert_eq "wakes: missing accounting"               "$(jq_ '["wakes"]["missing"]')" "{'no_metrics_line': 1, 'no_wakes_figure': 1}"

run_metrics since 2026-09-01
assert_eq "since: timed cards follow the filter"    "$(jq_ '["timed"]["timed_cards"]')" "2"
assert_eq "since: wakes follow the filter"          "$(jq_ '["wakes"]["total"]')"       "9"

# --- duration parsing (unit) ----------------------------------------------
# The corpus carries shapes no fixture card can hold all of at once, and a
# mis-read duration is worse than an unparsable one: it lands in the counted
# bucket as a guess. Pin the parser directly.
parse_dur() { PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys, importlib.util
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.parse_duration(sys.argv[2]))
' "$HERE/../lib/metrics.py" "$1"; }
assert_eq "duration: whole hours"          "$(parse_dur 'metrics: duration ~2h, wakes 3')"          "120"
assert_eq "duration: hours and minutes"    "$(parse_dur 'metrics: duration 3h18m wall')"            "198"
assert_eq "duration: decimal hours"        "$(parse_dur 'metrics: duration ~12.5h wall (20:44)')"   "750"
assert_eq "duration: spaced minutes"       "$(parse_dur 'metrics: duration 2h 30m total')"          "150"
assert_eq "duration: minutes with seconds" "$(parse_dur 'metrics: ~20m15s worker wall-clock')"      "20"
assert_eq "duration: the token after the word duration wins" "$(parse_dur 'metrics: 5m note, duration 90m real')" "90"
assert_eq "duration: nothing parsable is None" "$(parse_dur 'metrics: wakes 3, decisions 0')"       "None"

# --- worker turns + blocked ------------------------------------------------
run_metrics all
assert_eq "turns: stop events"                 "$(jq_ '["turns"]["stop_events"]')"    "7"
assert_eq "turns: claim none"                  "$(jq_ '["turns"]["claim_none"]')"     "1"
assert_eq "turns: claim none pct"              "$(jq_ '["turns"]["claim_none_pct"]')" "14.3"
assert_eq "turns: per-claim histogram"         "$(jq_ '["turns"]["by_claim"]')"       "{'blocked': 2, 'done': 3, 'none': 1, 'working': 1}"
assert_eq "turns: task ids with a status file" "$(jq_ '["turns"]["status_files"]')"   "4"
assert_eq "turns: rotated files are read too"  "$(jq_ '["turns"]["files"]')"          "5"
assert_eq "turns: missing accounting"          "$(jq_ '["turns"]["missing"]')"        "{'done_cards_without_status_file': 2, 'unparsable_lines': 1}"
assert_eq "blocked: events"                    "$(jq_ '["blocked"]["events"]')"        "2"
assert_eq "blocked: timed — closed by a stop in a ROTATED file" "$(jq_ '["blocked"]["timed"]')" "1"
assert_eq "blocked: hours"                     "$(jq_ '["blocked"]["hours"]')"         "1.8"
assert_eq "blocked: median minutes"            "$(jq_ '["blocked"]["median_minutes"]')" "108"
assert_eq "blocked: mean minutes"              "$(jq_ '["blocked"]["mean_minutes"]')"   "108"
assert_eq "blocked: cause classes"             "$(jq_ '["blocked"]["by_cause"]')"      "{'design-approval': {'events': 1, 'pct': 50.0}, 'question': {'events': 1, 'pct': 50.0}}"
assert_eq "blocked: human share is everything but other" "$(jq_ '["blocked"]["human_pct"]')" "100.0"

# --- cause classification (unit) ------------------------------------------
# The class decides how an operator reads the blocked row, and 23 live events
# sat in `other` while every one of them was a wait on Saket. Pin the pipeline
# a fixture cannot reach: the sentinel is parsed, then the class assigned.
cause() { PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys, importlib.util
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.classify_cause(m.blocked_oneliner({"tail": sys.argv[2]})))
' "$HERE/../lib/metrics.py" "$1"; }
assert_eq "cause: design approval"   "$(cause 'SHEPHERD: blocked — design approval needed')"          "design-approval"
assert_eq "cause: a question"        "$(cause 'SHEPHERD: blocked — need Saket answer to two')"        "question"
assert_eq "cause: a permission"      "$(cause 'SHEPHERD: blocked — waiting for the authorize click')" "permission"
assert_eq "cause: waiting on Saket"  "$(cause 'SHEPHERD: blocked — awaiting Saket ship-list sign')"   "operator-action"
assert_eq "cause: unclassified"      "$(cause 'SHEPHERD: blocked — the CI runner died mid-suite')"    "other"
assert_eq "cause: the last sentinel wins" "$(cause $'SHEPHERD: blocked — design approval.\nSHEPHERD: blocked — awaiting your call')" "operator-action"
assert_eq "cause: no sentinel falls back to the tail" "$(cause 'prose with no sentinel about a dead runner')" "other"
assert_eq "blocked: open block is missing"     "$(jq_ '["blocked"]["missing"]')"       "{'unclosed': 1, 'unparsable_ts': 0}"

run_metrics since 2026-09-01
assert_eq "since: blocked follows the card filter" "$(jq_ '["blocked"]["events"]')" "1"
assert_eq "since: turns follow the card filter"    "$(jq_ '["turns"]["stop_events"]')" "5"

# --- concurrency -----------------------------------------------------------
run_metrics all
assert_eq "concurrency: hours from first transition to --now" "$(jq_ '["concurrency"]["total_hours"]')" "4"
assert_eq "concurrency: window start"          "$(jq_ '["concurrency"]["from"]')"         "2026-09-01T10:00+00:00"
assert_eq "concurrency: histogram"             "$(jq_ '["concurrency"]["hours"]')"        "{'0': 1, '1': 2, '2': 1, '3+': 0}"
assert_eq "concurrency: pct"                   "$(jq_ '["concurrency"]["pct"]')"          "{'0': 25.0, '1': 50.0, '2': 25.0, '3+': 0.0}"
assert_eq "concurrency: max active"            "$(jq_ '["concurrency"]["max"]')"          "2"
assert_eq "concurrency: hours at max"          "$(jq_ '["concurrency"]["hours_at_max"]')" "1"
assert_eq "concurrency: summed active spans, same-second pair contributing none" "$(jq_ '["concurrency"]["active_hours"]')" "4.0"
assert_eq "concurrency: done cards never active in git are missing" "$(jq_ '["concurrency"]["missing"]')" "{'done_without_dated_interval': 4, 'git_unavailable': 0}"
assert_eq "blocked: share of active card time" "$(jq_ '["blocked"]["share_of_active_pct"]')" "45.0"

run_metrics since 2026-09-01
assert_eq "since: concurrency follows the card filter" "$(jq_ '["concurrency"]["missing"]')" "{'done_without_dated_interval': 1, 'git_unavailable': 0}"

# `--json` is a named downstream seam, so the `missing` key set must not change with
# the branch taken. No fixture can remove git from the sandbox, so call the measure.
concurrency_missing_no_git() { PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys, datetime, importlib.util
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.measure_concurrency({}, None, datetime.datetime.now(datetime.timezone.utc))["missing"])
' "$HERE/../lib/metrics.py"; }
assert_eq "concurrency: git unavailable seeds the same two keys" \
  "$(concurrency_missing_no_git)" "{'done_without_dated_interval': 0, 'git_unavailable': 1}"

# An hour counts CARDS, not intervals. No fixture card leaves an active state and
# re-enters it inside one hour, so reverting the bucket loop to `counts[h] += 1`
# leaves every other assertion green — this is the only one that fails.
concurrency_peak() { PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys, importlib.util
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
t = lambda hhmm: m.parse_ts("2026-09-01T%s:00+00:00" % hhmm)
cards = {"T-0001": {"id": "T-0001", "fields": {"state": "done"}, "log": ""}}
# active 10:00-10:30, idle, active again 10:40-12:00: two intervals, one card,
# and both intervals open in the 10:00 bucket.
tr = {"T-0001": [(t("10:00"), "working"), (t("10:30"), "queued"),
                 (t("10:40"), "working"), (t("12:00"), "done")]}
k = m.measure_concurrency(cards, tr, t("12:00"))
print(k["max"], k["hours"], k["active_hours"])
' "$HERE/../lib/metrics.py"; }
assert_eq "concurrency: one card active twice in an hour is one active card, not two" \
  "$(concurrency_peak)" "1 {'0': 0, '1': 2, '2': 0, '3+': 0} 1.8"

# --- the window's right edge: --now in the past ---------------------------
# Every assertion above pins NOW after every fixture event, so none of them has
# ever exercised a window that ends before the data does. Nothing after --now is
# counted, anywhere: cards by `created:`, decision months, status events by `ts`,
# and git transitions by commit date. TZ is pinned because the fixture's
# `created:` values are naive, so they are read as local time, and both instants
# below sit between two of them.
PAST_EDGE="2026-09-01T09:05:00+00:00"   # before every status event and every transition
PAST_MID="2026-09-01T12:00:00+00:00"    # inside the blocked span and inside T-0002's
run_past() { TZ=UTC bash "$M" "$1" --json --now "$2" > "$J"; }

run_past all "$PAST_EDGE"
assert_eq "past --now: cards created after it are not selected" "$(jq_ '["filter"]["cards"]')" "6"
assert_eq "past --now: cards_total stays unfiltered"            "$(jq_ '["filter"]["cards_total"]')" "9"
assert_eq "past --now: the undated card is still counted"       "$(jq_ '["filter"]["undated"]')" "1"
assert_eq "past --now: only the six survive by state"           "$(jq_ '["cards"]["by_state"]')" "{'done': 6}"
assert_eq "past --now: stop events stamped after it are dropped" "$(jq_ '["turns"]["stop_events"]')" "2"
assert_eq "past --now: per-claim histogram"                     "$(jq_ '["turns"]["by_claim"]')" "{'blocked': 1, 'done': 1}"
assert_eq "past --now: a block opening after it is not an event" "$(jq_ '["blocked"]["events"]')" "1"
assert_eq "past --now: nothing is timed"                        "$(jq_ '["blocked"]["timed"]')" "0"
assert_eq "past --now: the surviving block has no later stop"   "$(jq_ '["blocked"]["missing"]')" "{'unclosed': 1, 'unparsable_ts': 0}"
assert_eq "past --now: no active interval had opened yet"       "$(jq_ '["concurrency"]["from"]')" "None"
assert_eq "past --now: active_hours clamps to zero"             "$(jq_ '["concurrency"]["active_hours"]')" "0.0"
assert_eq "past --now: every selected done card lacks an interval" "$(jq_ '["concurrency"]["missing"]')" "{'done_without_dated_interval': 6, 'git_unavailable': 0}"
assert_eq "past --now: the blocked share is null, not impossible" "$(jq_ '["blocked"]["share_of_active_pct"]')" "None"

# Mid-window: the block is open at --now and its closing stop is later, so the
# duration is clipped to --now; T-0002's active interval is open and closes at
# --now. Neither path is reachable with NOW after every event.
run_past all "$PAST_MID"
assert_eq "mid --now: cards created after it are not selected"  "$(jq_ '["filter"]["cards"]')" "8"
assert_eq "mid --now: both blocks are events"                   "$(jq_ '["blocked"]["events"]')" "2"
assert_eq "mid --now: the closing stop after --now still closes it" "$(jq_ '["blocked"]["timed"]')" "1"
assert_eq "mid --now: the duration is clipped to --now, not 108 m" "$(jq_ '["blocked"]["median_minutes"]')" "50"
assert_eq "mid --now: blocked hours"                            "$(jq_ '["blocked"]["hours"]')" "0.8"
assert_eq "mid --now: an interval still open at --now closes there" "$(jq_ '["concurrency"]["active_hours"]')" "3.0"
assert_eq "mid --now: window start"                             "$(jq_ '["concurrency"]["from"]')" "2026-09-01T10:00+00:00"
assert_eq "mid --now: hours to --now"                           "$(jq_ '["concurrency"]["total_hours"]')" "2"
assert_eq "mid --now: blocked share of active card time"        "$(jq_ '["blocked"]["share_of_active_pct"]')" "27.8"
assert_eq "mid --now: the blocked share is never above 100 %" \
  "$(jq_ '["blocked"]["share_of_active_pct"] is None or d["blocked"]["share_of_active_pct"] <= 100')" "True"

# The decision window is month-granular on both edges: a month later than
# --now's own month is not counted, in any mode.
run_past all "2026-08-15T00:00:00+00:00"
assert_eq "past --now: months after it are dropped"  "$(jq_ '["decisions"]["by_month"].keys()')" "dict_keys(['2026-08'])"
assert_eq "past --now: all is bounded on the right too" "$(jq_ '["filter"]["cards"]')" "1"

# --- decisions + always-loaded context ------------------------------------
run_metrics all
assert_eq "decisions: entries across months"   "$(jq_ '["decisions"]["entries"]')"     "6"
assert_eq "decisions: Basis present"           "$(jq_ '["decisions"]["basis"]')"       "5"
assert_eq "decisions: Basis pct"               "$(jq_ '["decisions"]["basis_pct"]')"   "83.3"
assert_eq "decisions: Outcome backfilled"      "$(jq_ '["decisions"]["outcome"]')"     "3"
assert_eq "decisions: live source cited"       "$(jq_ '["decisions"]["cited"]')"       "4"
assert_eq "decisions: cited pct"               "$(jq_ '["decisions"]["cited_pct"]')"   "66.7"
assert_eq "decisions: month rows, incl. a label after a closed bold run" "$(jq_ '["decisions"]["by_month"]["2026-08"]')" "{'entries': 4, 'basis': 3, 'basis_pct': 75.0, 'outcome': 2, 'outcome_pct': 50.0, 'cited': 2, 'cited_pct': 50.0}"
assert_eq "decisions: a mid-line Basis and Outcome count" "$(jq_ '["decisions"]["by_month"]["2026-09"]')" "{'entries': 2, 'basis': 2, 'basis_pct': 100.0, 'outcome': 1, 'outcome_pct': 50.0, 'cited': 2, 'cited_pct': 100.0}"
assert_eq "decisions: TEMPLATE.md is ignored"  "$(jq_ '["decisions"]["by_month"].keys()')" "dict_keys(['2026-08', '2026-09'])"
assert_eq "decisions: missing accounting"      "$(jq_ '["decisions"]["missing"]')"     "{'entries_without_basis': 1}"
claude_tokens=$(( ( $(wc -c < "$SHEPHERD_ROOT/.claude/shepherd-manual.md") + 3 ) / 4 ))
wake_tokens=$(( ( $(wc -c < "$SHEPHERD_ROOT/skills/wake/SKILL.md") + 3 ) / 4 ))
mem_tokens=$(( ( $(wc -c < "$SHEPHERD_MEMORY_INDEX") + 3 ) / 4 ))
assert_eq "context: manual tokens = ceil(bytes/4)" "$(jq_ '["context"]["files"]["manual"]["tokens"]')" "$claude_tokens"
assert_eq "context: wake skill tokens"                "$(jq_ '["context"]["files"]["wake skill"]["tokens"]')" "$wake_tokens"
assert_eq "context: memory index via SHEPHERD_MEMORY_INDEX" "$(jq_ '["context"]["files"]["memory index"]["tokens"]')" "$mem_tokens"
assert_eq "context: absent adapter reference is null"  "$(jq_ '["context"]["files"]["adapter reference"]["tokens"]')" "None"
assert_eq "context: total"                             "$(jq_ '["context"]["total_tokens"]')" "$(( claude_tokens + wake_tokens + mem_tokens ))"
assert_eq "context: missing accounting"                "$(jq_ '["context"]["missing"]')" "{'files': 1}"

# --- decision labels and the adapter pin (unit) ---------------------------
# A placeholder Outcome that the prefix stripper cannot reach reads as backfilled
# — a wrong value in a counted bucket, in the one shape round 2 newly admitted.
outcome_backfilled() { PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys, importlib.util
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.decision_fields(sys.argv[2])["outcome"])
' "$HERE/../lib/metrics.py" "$1"; }
assert_eq "outcome: an em-dash after a closed bold run is NOT backfilled" "$(outcome_backfilled '- **Ruled.** Outcome: —')" "False"
assert_eq "outcome: a real outcome after a closed bold run is backfilled"  "$(outcome_backfilled '- **Ruled.** Outcome: shipped in PR #1')" "True"
assert_eq "outcome: a bolded em-dash is NOT backfilled"                    "$(outcome_backfilled '- **Outcome:** —')" "False"
assert_eq "outcome: a bolded outcome is backfilled"                        "$(outcome_backfilled '- **Outcome:** shipped')" "True"

# The adapter reference is 46 % of the always-loaded headline and its filename
# carries the herdr version, which the manual §7 says will change.
adapter_pick() { PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys, os, importlib.util
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(os.path.basename(m.adapter_reference(sys.argv[2])))
' "$HERE/../lib/metrics.py" "$1"; }
assert_eq "adapter reference: highest version wins, numerically not lexically" \
  "$(adapter_pick "$HERE/fixtures/metrics-adapter")" "v0.10.0.md"

run_metrics since 2026-09-01
assert_eq "since: decisions keep months overlapping the window" "$(jq_ '["decisions"]["by_month"].keys()')" "dict_keys(['2026-09'])"

# --- inbox (T-0237) --------------------------------------------------------
run_metrics all
assert_eq "inbox: events selected by drain-start, unparsable lines apart" "$(jq_ '["inbox"]["events"]')" "14"
assert_eq "inbox: by intent, sorted, with both medians" "$(jq_ '["inbox"]["by_intent"]["ask"]')" \
  "{'events': 6, 'first_word_events': 6, 'first_word_median_minutes': 1.0, 'answered': 6, 'answer_median_minutes': 7.5}"
assert_eq "inbox: an intent whose answers are all still open" "$(jq_ '["inbox"]["by_intent"]["build"]')" \
  "{'events': 3, 'first_word_events': 3, 'first_word_median_minutes': 2.0, 'answered': 1, 'answer_median_minutes': 120.0}"
assert_eq "inbox: a refusal is a final word, so it has an answer time" "$(jq_ '["inbox"]["by_intent"]["status"]')" "{'events': 2, 'first_word_events': 2, 'first_word_median_minutes': 0.8, 'answered': 2, 'answer_median_minutes': 0.8}"
assert_eq "inbox: asked has a first word and no answer" "$(jq_ '["inbox"]["by_intent"]["readiness"]')" \
  "{'events': 1, 'first_word_events': 1, 'first_word_median_minutes': 4.0, 'answered': 0, 'answer_median_minutes': None}"
assert_eq "inbox: ignored has no answer either" "$(jq_ '["inbox"]["by_intent"]["stop"]["answered"]')" "0"
assert_eq "inbox: sub-minute first words are rounded to one decimal, not truncated" "$(jq_ '["inbox"]["by_intent"]["stop"]["first_word_median_minutes"]')" "0.7"
assert_eq "inbox: intents are every intent word in the window" "$(jq_ '["inbox"]["by_intent"].keys()')" \
  "dict_keys(['ask', 'build', 'estimate', 'readiness', 'status', 'stop'])"
assert_eq "inbox: first-word median overall" "$(jq_ '["inbox"]["first_word_median_minutes"]')" "1.0"
assert_eq "inbox: first words counted" "$(jq_ '["inbox"]["first_word_events"]')" "14"
assert_eq "inbox: answer median overall, from drain-start" "$(jq_ '["inbox"]["answer_median_minutes"]')" "4.0"
assert_eq "inbox: answered = answered + refused + closed carded/routed, every line an id joins" "$(jq_ '["inbox"]["answered"]')" "10"
assert_eq "inbox: by outcome, carded:T-NNNN folded to carded" "$(jq_ '["inbox"]["by_outcome"]')" \
  "{'answered': 5, 'asked': 1, 'carded': 4, 'held': 1, 'ignored': 1, 'refused': 1, 'routed': 1}"
assert_eq "inbox: by trust word" "$(jq_ '["inbox"]["by_trust"]')" "{'operator': 8, 'member': 5, 'unknown': 1}"
assert_eq "inbox: the offline gap is its own number" "$(jq_ '["inbox"]["offline_gap"]')" \
  "{'events': 12, 'median_minutes': 1.0, 'max_minutes': 60.0}"
assert_eq "inbox: missing accounting" "$(jq_ '["inbox"]["missing"]')" \
  "{'log': 0, 'unparsable_lines': 3, 'unparsable_ts': 1, 'answered_without_event': 2, 'unclosed': 2, 'first_word_after_now': 0, 'negative': 1}"
assert_eq "inbox: a negative gap is counted, never averaged" "$(jq_ '["inbox"]["offline_gap"]["events"]')" "12"
# The gap must never leak into either latency: event 2's first word is 2 m after
# drain-start but 62 m after the Worker received it.
assert_eq "inbox: the gap is not folded into the first word" "$(jq_ '["inbox"]["by_intent"]["build"]["first_word_median_minutes"]')" "2.0"

run_metrics week
assert_eq "week: inbox drops the August-20 event only" "$(jq_ '["inbox"]["events"]')" "13"
assert_eq "week: ask loses event 1"                    "$(jq_ '["inbox"]["by_intent"]["ask"]["answer_median_minutes"]')" "10.0"
assert_eq "week: both orphans are in the window"      "$(jq_ '["inbox"]["missing"]["answered_without_event"]')" "2"
run_metrics since 2026-09-01
assert_eq "since: inbox follows the window"            "$(jq_ '["inbox"]["events"]')" "12"
assert_eq "since: an answered line whose event is outside the window is ignored, and an orphan outside it is not missing" \
  "$(jq_ '["inbox"]["missing"]["answered_without_event"]')" "1"
assert_eq "since: build is the two open cards"         "$(jq_ '["inbox"]["by_intent"]["build"]')" \
  "{'events': 2, 'first_word_events': 2, 'first_word_median_minutes': 1.5, 'answered': 0, 'answer_median_minutes': None}"
# --now inside the log: a first word past the edge is not counted, an orphan
# answered line past it is not missing, an event past it is not selected.
run_past all 2026-09-01T12:35:00+00:00
assert_eq "past --now: inbox events"                   "$(jq_ '["inbox"]["events"]')" "7"
assert_eq "past --now: a first word after the edge is not counted" "$(jq_ '["inbox"]["missing"]["first_word_after_now"]')" "1"
assert_eq "past --now: …and neither is its answer"     "$(jq_ '["inbox"]["answered"]')" "4"
assert_eq "past --now: first-word median over the six spoken" "$(jq_ '["inbox"]["first_word_median_minutes"]')" "2.5"
assert_eq "past --now: an orphan answered past the edge is not missing, one before it is" "$(jq_ '["inbox"]["missing"]["answered_without_event"]')" "1"
assert_eq "past --now: unparsable lines belong to no window" "$(jq_ '["inbox"]["missing"]["unparsable_lines"]')" "3"
assert_eq "past --now: an unselected event's bad timestamp is not counted" "$(jq_ '["inbox"]["missing"]["unparsable_ts"]')" "0"
# no log at all: a missing column, not an error
SHEPHERD_ROOT="$NOLOG" bash "$M" all --json --now "$NOW" > "$J"; rc=$?
assert_eq "no log: metrics still exits 0"              "$rc" "0"
assert_eq "no log: the missing column says so"         "$(jq_ '["inbox"]["missing"]["log"]')" "1"
assert_eq "no log: zero events, every key present"     "$(jq_ '["inbox"]["events"]')" "0"
assert_eq "no log: the key set is the same"            "$(jq_ '["inbox"]["missing"].keys()')" \
  "dict_keys(['log', 'unparsable_lines', 'unparsable_ts', 'answered_without_event', 'unclosed', 'first_word_after_now', 'negative'])"
assert_eq "no log: the table row says so" "$(SHEPHERD_ROOT="$NOLOG" bash "$M" all --now "$NOW" | grep -c '^| inbox | no inbox log |')" "1"

# --- the table -------------------------------------------------------------
table=$(bash "$M" all --now "$NOW")
assert_eq "table: inbox row" "$(printf '%s\n' "$table" | grep -c '^| inbox | 14 events; first word median 1.0 m; answer median 4.0 m over 10 answered; intents ask 6 (first 1.0 m, answer 7.5 m), build 3 (first 2.0 m, answer 120.0 m), estimate 1 (first 3.0 m, answer 3.0 m), readiness 1 (first 4.0 m), status 2 (first 0.8 m, answer 0.8 m), stop 1 (first 0.7 m); outcomes answered 5, asked 1, carded 4, held 1, ignored 1, refused 1, routed 1; trust operator 8, member 5, unknown 1; offline gap median 1.0 m, max 60.0 m over 12 events | unparsable_lines 3, unparsable_ts 1, answered_without_event 2, unclosed 2, negative 1 |$')" "1"
assert_eq "table: header row"                 "$(printf '%s\n' "$table" | grep -c '^| measure | value | missing |$')" "1"
assert_eq "table: cards row"                  "$(printf '%s\n' "$table" | grep -c '^| cards done / failed / abandoned | 6 / 0 / 1 of 8')" "1"
assert_eq "table: measured-work row"          "$(printf '%s\n' "$table" | grep -c '^| measured work | 7.9 h across 4 timed cards; median ratio 0.7')" "1"
assert_eq "table: since does not stutter"     "$(bash "$M" since 2026-09-01 --now "$NOW" | grep -c '^filter: since 2026-09-01 — 5 of 9 cards, 1 undated;')" "1"

# An empty window is a normal weekly result. It must read as a table, not as a
# row of dangling separators.
empty=$(bash "$M" since 2027-01-01 --now "$NOW")
assert_eq "empty window: the tail row says so"   "$(printf '%s\n' "$empty" | grep -c 'no timed cards in this window')" "1"
assert_eq "empty window: concurrency says so"    "$(printf '%s\n' "$empty" | grep -c 'no dated active intervals in this window')" "1"
# Assert on the shape a dangling clause actually leaves — a row that ends in a
# word or a separator with nothing after it — not on punctuation that `_parts`
# can never emit. The first version of this check was green while the turns row
# printed `claims  |`. A well-formed cell ends with exactly one space before the
# `|` that `_row` adds; a dangling label leaves its own trailing space too, so
# the defect signature is two spaces, not one.
assert_eq "empty window: no row ends in an orphan label" "$(printf '%s\n' "$empty" | grep -cE '[[:alpha:]]   *\|')" "0"
assert_eq "empty window: no row ends in a separator"     "$(printf '%s\n' "$empty" | grep -cE '(; |, |— |\(\)) *\|')" "0"
assert_eq "empty window: the turns row has no orphan claims label" "$(printf '%s\n' "$empty" | grep -c 'claims  ')" "0"
assert_eq "empty window: the inbox row says so"  "$(printf '%s\n' "$empty" | grep -c '^| inbox | no inbox events in this window |')" "1"
# 12 table lines; the `^| ` pattern excludes the `|---|---|---|` separator, so the
# count is the header plus one row per measure (10) = 11.
assert_eq "empty window: still one row per measure" "$(printf '%s\n' "$empty" | grep -c '^| ')" "11"

# --- self-maintenance (unit) ----------------------------------------------
self_project() { PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys, importlib.util
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(bool(m.SELF_PROJECT.match(sys.argv[2])))
' "$HERE/../lib/metrics.py" "$1"; }
assert_eq "self: the base checkout"                "$(self_project 'shepherd')" "True"
assert_eq "self: a clone"                          "$(self_project 'shepherd~4')" "True"
assert_eq "self: the framework template"           "$(self_project 'shepherd-template')" "True"
assert_eq "self: the retired spelling"             "$(self_project 'shepherd (self)')" "True"
assert_eq "self: the deck is shepherd's own tooling"      "$(self_project 'shepherd-deck')" "True"
assert_eq "self: the inbox is shepherd's own tooling"     "$(self_project 'shepherd-inbox')" "True"
assert_eq "self: a business project that merely starts the same way" "$(self_project 'shepherdess-crm')" "False"
assert_eq "self: another project entirely"         "$(self_project 'karta')" "False"
assert_eq "table: blocked row says upper bound" "$(printf '%s\n' "$table" | grep -c '^| blocked | 2 events, 1 timed')" "1"
assert_eq "table: concurrency row"            "$(printf '%s\n' "$table" | grep -c '^| concurrency | 4 h from 2026-09-01T10:00+00:00; hours with 0/1/2/3+ active: 1 (25.0 %) / 2 / 1 / 0')" "1"
assert_eq "table: missing column carries the counts" "$(printf '%s\n' "$table" | grep -c 'no_metrics_line 1, unparsable_budget 1')" "1"
assert_eq "table: filter line"                "$(printf '%s\n' "$table" | grep -c '^filter: all — 8 of 9 cards, 1 undated; now 2026-09-01T14:00+00:00$')" "1"
assert_eq "table: never prints a bare None"   "$(printf '%s\n' "$table" | grep -c 'None')" "0"
assert_eq "--json is one object"              "$(bash "$M" all --json --now "$NOW" | python3 -c 'import json,sys; print(type(json.load(sys.stdin)).__name__)')" "dict"

# --- read-only -------------------------------------------------------------
assert_eq "the sandbox is byte-identical after every run" "$(snapshot)" "$before"

finish
