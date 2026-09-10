#!/usr/bin/env bash
# Table-driven probe for `shepherd-rollover decide` — the meter every shepherd
# wake reads (the manual §8). Under test: absolute tokens AND percent are both
# checked and WHICHEVER FIRES FIRST wins (on a 1M window a comfortable percent is
# already an expensive turn; on a 200k window the percent fires long before the
# absolute); only cards YOU own hold you at `hold`; a percent-only reading is
# named on stderr; and `--self-test` names every degraded case and exits 1.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
SCRIPT="$HERE/../bin/shepherd-rollover"
INSTALL="$HERE/../bin/shepherd-statusline"

echo "test-decide:"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is available" "python3 not found"
  finish; exit
fi

# MANDATORY: a worker running this inherits the live instance's thresholds, id
# and pane. HOME is redirected because --self-test reads ~/.claude and the
# install it checks against must only ever be run into the sandbox.
unset SHEPHERD_ROLLOVER_LOG SHEPHERD_TASK_ID HERDR_PANE_ID CTX_IDLE CTX_BUSY CTX_IDLE_K CTX_BUSY_K
export HOME="$SHEPHERD_ROOT/home"; mkdir -p "$HOME/.claude"

# The herdr stub renders what statusline.py renders: "ctx <bar> <pct>%[/<size>k]".
# An empty size = a status line with no window (the percent-only reading);
# an empty pct = no status line on screen at all.
BIN="$SHEPHERD_ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
S=$HERDR_STUB_DIR
case "$1 $2" in
  "pane read")
    pct=$(cat "$S/pct"); size=$(cat "$S/size")
    printf '  ❯\n'
    if [ -n "$pct" ]; then
      if [ -n "$size" ]; then printf '  Opus 5 │ ctx ▓▓░░░░░░░░ %s%%/%sk │ shepherd-test\n' "$pct" "$size"
      else printf '  Opus 5 │ ctx ▓▓░░░░░░░░ %s%% │ shepherd-test\n' "$pct"; fi
    fi
    printf '  ⏵⏵ auto mode on · 2 shells\n' ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"
export HERDR_STUB_DIR="$SHEPHERD_ROOT/stub"; mkdir -p "$HERDR_STUB_DIR"
T="$SHEPHERD_ROOT/ledger/tasks"
ERR="$SHEPHERD_ROOT/stderr"

# screen <pct> <size-k>   ("" for either = absent)
screen() { printf '%s\n' "$1" > "$HERDR_STUB_DIR/pct"; printf '%s\n' "$2" > "$HERDR_STUB_DIR/size"; }
# cards <state[:owner]>... — rebuilds the sandbox ledger; owner "-" = no owner: line
cards() {
  rm -f "$T"/T-*.md
  local i=0 s st ow
  for s in "$@"; do
    i=$((i + 1)); st=${s%%:*}; ow=${s#*:}
    { printf '# T-%04d: x\nstate: %s\n' "$i" "$st"
      if [ "$s" != "$st" ] && [ "$ow" != "-" ]; then printf 'owner: %s\n' "$ow"; fi
    } > "$T/T-$(printf '%04d' "$i").md"
  done
}
# decide — as shepherd-test (or $ME), against the stub pane
decide() { PATH="$BIN:$PATH" SHEPHERD_ID="${ME:-shepherd-test}" bash "$SCRIPT" decide w1:p1 2>"$ERR" </dev/null; }

# === the table ==============================================================
# pct  size  owned-active  verdict   why
while read -r pct size active want why; do
  [ -n "$pct" ] || continue
  case "$active" in 0) cards ;; 1) cards working:shepherd-test ;; esac
  screen "$pct" "$([ "$size" = - ] || echo "$size")"
  assert_eq "decide ${pct}% /${size}k active=$active → $want ($why)" "$(decide)" "$want"
done <<'TABLE'
10  1000 0 ok       100k and 10%: neither threshold
19  1000 0 ok       190k: just under the idle absolute
20  1000 0 rollover 200k: the idle ABSOLUTE fires at 20% of a 1M window
20  1000 1 hold     200k with an owned active card: hold until close-out
34  1000 1 hold     340k: under the busy absolute
35  1000 1 rollover 350k: the busy ABSOLUTE fires regardless of active cards
59  200  0 ok       118k and 59%: neither threshold on a 200k window
60  200  0 rollover the idle PERCENT fires on a 200k window at 120k tokens
60  200  1 hold     60% with an owned active card
84  200  1 hold     168k and 84%: under both busy thresholds
85  200  1 rollover the busy PERCENT fires regardless
59  -    0 ok       percent-only, under the idle percent
60  -    0 rollover percent-only, the idle percent still fires
60  -    1 hold     percent-only, held by the active card
85  -    1 rollover percent-only, the busy percent still fires
TABLE

# === the owner filter =======================================================
screen 60 200
cards working:shepherd-other
assert_eq "another instance's active card does not hold you" "$(decide)" "rollover"
cards working:-
assert_eq "an ownerless card is shepherd-1's, so it does not hold shepherd-test" "$(decide)" "rollover"
assert_eq "an ownerless card holds shepherd-1" "$(ME=shepherd-1 decide)" "hold"
cards done:shepherd-test queued:shepherd-test captured:shepherd-test failed:shepherd-test
assert_eq "closed, queued and captured cards are not active" "$(decide)" "rollover"
cards review:shepherd-test
assert_eq "a card in review is active" "$(decide)" "hold"
cards briefed:shepherd-test
assert_eq "a briefed card is active" "$(decide)" "hold"
cards blocked:shepherd-test
assert_eq "a blocked card is active" "$(decide)" "hold"

# === the ledger read is SHEPHERD_ROOT-relative ==============================
# The sandbox ledger is what every case above counted; the repo's own
# ledger/tasks holds live cards and must not have been what decided `hold`.
cards
screen 60 200
assert_eq "an empty sandbox ledger means no active cards, whatever the repo holds" "$(decide)" "rollover"

# === unknown ================================================================
screen "" ""; cards
assert_eq "no status line → unknown" "$(decide)" "unknown"
assert_eq "no pane → unknown" \
  "$(PATH="$BIN:$PATH" HERDR_PANE_ID= bash "$SCRIPT" decide 2>/dev/null </dev/null)" "unknown"

# === the percent-only reading is named on stderr, stdout unchanged ==========
screen 30 ""; cards
assert_eq "percent-only stdout is still one of the four words" "$(decide)" "ok"
assert_ok "a percent-only reading says so on stderr" grep -q '^meter degraded:' "$ERR"
assert_ok "and names the thresholds that cannot fire" grep -q '200k/350k' "$ERR"
assert_ok "and points at the self-test" grep -q -- '--self-test' "$ERR"
screen 30 1000; decide >/dev/null
assert_fail "a full reading is silent on stderr" test -s "$ERR"
screen "" ""; decide >/dev/null
assert_fail "unknown is silent on stderr (it is already the loud answer)" test -s "$ERR"

# === the env overrides still steer the thresholds ===========================
screen 10 1000; cards
assert_eq "CTX_IDLE_K is honoured" \
  "$(PATH="$BIN:$PATH" SHEPHERD_ID=shepherd-test CTX_IDLE_K=100 bash "$SCRIPT" decide w1:p1 2>/dev/null </dev/null)" "rollover"
assert_eq "CTX_IDLE is honoured" \
  "$(PATH="$BIN:$PATH" SHEPHERD_ID=shepherd-test CTX_IDLE=10 bash "$SCRIPT" decide w1:p1 2>/dev/null </dev/null)" "rollover"

# === --self-test: every degraded case named, exit 1 =========================
st() { PATH="$BIN:$PATH" bash "$SCRIPT" decide --self-test w1:p1 2>&1 </dev/null; }

bash "$INSTALL" >/dev/null                    # HOME is the sandbox — see the top
screen 13 1000
out=$(st); rc=$?
assert_eq "a healthy meter exits 0" "$rc" "0"
assert_ok "a healthy meter reports the reading" grep -q '13%/1000k' <<<"$out"
assert_ok "a healthy meter reports the install" grep -q 'statusline.py installed and current' <<<"$out"
assert_ok "a healthy meter ends with ok" grep -q '^meter: ok$' <<<"$out"
assert_fail "a healthy meter names no degradation" grep -q DEGRADED <<<"$out"

screen 13 ""
out=$(st); rc=$?
assert_eq "percent-only exits 1" "$rc" "1"
assert_ok "percent-only is named" grep -q 'DEGRADED.*no window size' <<<"$out"
assert_ok "percent-only says what cannot fire" grep -q 'absolute 200k/350k' <<<"$out"
assert_ok "percent-only ends DEGRADED" grep -q '^meter: DEGRADED$' <<<"$out"

screen "" ""
out=$(st); rc=$?
assert_eq "no status line exits 1" "$rc" "1"
assert_ok "no status line is named, with the fallback" grep -q 'DEGRADED.*no status line visible.*meter <' <<<"$out"

out=$(PATH="$BIN:$PATH" HERDR_PANE_ID= bash "$SCRIPT" decide --self-test 2>&1 </dev/null); rc=$?
assert_eq "no pane exits 1" "$rc" "1"
assert_ok "no pane is named" grep -q 'DEGRADED.*no pane' <<<"$out"

screen 13 1000
printf '# local edit\n' >> "$HOME/.claude/statusline.py"
out=$(st); rc=$?
assert_eq "a stale statusline.py exits 1" "$rc" "1"
assert_ok "a stale statusline.py is named with the repair" grep -q 'DEGRADED.*file=updated.*shepherd-statusline' <<<"$out"
assert_ok "and the self-test did NOT repair it itself" grep -q 'local edit' "$HOME/.claude/statusline.py"
bash "$INSTALL" >/dev/null

python3 - "$HOME/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s.pop("statusLine", None); json.dump(s, open(p, "w"))
PY
out=$(st); rc=$?
assert_eq "an unregistered statusLine exits 1" "$rc" "1"
assert_ok "an unregistered statusLine is named" grep -q 'DEGRADED.*settings=registered' <<<"$out"

# structural: the self-test only ever CHECKS, never installs. Counted on the
# invocation, not on any line mentioning the script — the DEGRADED branch names
# `bash shepherd-statusline` as the operator's repair, and must.
assert_eq "meter_selftest invokes the installer exactly once" \
  "$(sed -n '/^meter_selftest()/,/^}/p' "$SCRIPT" | grep -c 'bash "$here/bin/shepherd-statusline"')" "1"
assert_eq "and that invocation carries --check" \
  "$(sed -n '/^meter_selftest()/,/^}/p' "$SCRIPT" | grep -c 'shepherd-statusline" --check')" "1"
assert_ok "the header documents --self-test" grep -q 'decide \[pane\] \[--self-test\]' "$SCRIPT"

finish
