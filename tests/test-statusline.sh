#!/usr/bin/env bash
# scripts/statusline.py is the context meter's source of truth and
# shepherd-statusline puts it where Claude Code reads it. Asserted here:
# the render matches the shape shepherd-rollover's read_ctx parses (a contract
# between two files that never import each other), the null-percentage case
# renders, and the install is idempotent — against a TEMP HOME, never the
# operator's real ~/.claude.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
SL="$HERE/../lib/statusline.py"
INSTALL="$HERE/../bin/shepherd-statusline"
ROLLOVER="$HERE/../bin/shepherd-rollover"

echo "test-statusline:"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is available" "python3 not found"
  finish; exit
fi

# MANDATORY: everything below runs with HOME redirected into the sandbox. The
# install script writes ~/.claude/statusline.py and ~/.claude/settings.json;
# against the real HOME it would rewrite the operator's settings mid-session.
export HOME="$SHEPHERD_ROOT/home"
mkdir -p "$HOME"
unset SHEPHERD_ID SHEPHERD_TASK_ID HERDR_PANE_ID

# render <pct|null> <size|null> — the documented stdin JSON
# (https://code.claude.com/docs/en/statusline, read 2026-09-02), ANSI stripped
render() {
  python3 -c 'import json,sys
pct = None if sys.argv[1] == "null" else float(sys.argv[1])
size = None if sys.argv[2] == "null" else int(sys.argv[2])
print(json.dumps({"model":{"id":"claude-opus-5","display_name":"Opus 5"},
  "effort":{"level":"high"},
  "context_window":{"total_input_tokens":1,"total_output_tokens":1,
    "context_window_size":size,"used_percentage":pct,
    "remaining_percentage":None if pct is None else 100-pct,"current_usage":None}}))' "$1" "$2" \
  | python3 "$SL" | sed 's/\x1b\[[0-9;]*m//g'
}

# --- render: the shape read_ctx parses -------------------------------------
out=$(render 13 1000000)
assert_ok "renders the model"  grep -q 'Opus 5' <<<"$out"
assert_ok "renders the effort" grep -q 'effort:high' <<<"$out"
assert_ok "renders the ctx bar with percent and window" \
  grep -q 'ctx ▓░░░░░░░░░ 13%/1000k' <<<"$out"
assert_ok "a 200k window renders as /200k" grep -q '13%/200k' <<<"$(render 13 200000)"
assert_ok "a null percentage renders the placeholder" grep -q 'ctx: –' <<<"$(render null 1000000)"
assert_ok "a null window renders percent only" grep -qE 'ctx [▓░]+ 13%( |$)' <<<"$(render 13 null)"
assert_ok "a shepherd id is appended when set" \
  bash -c 'SHEPHERD_ID=shepherd-test python3 "$1" <<<"{}" | grep -q shepherd-test' _ "$SL"
assert_ok "an empty payload still renders" bash -c 'python3 "$1" <<<"" | grep -q "ctx: –"' _ "$SL"

# --- round trip: what statusline.py renders, shepherd-rollover ctx reads --
BIN="$SHEPHERD_ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pane read") cat "$HERDR_STUB_SCREEN" ;;
esac
STUB
chmod +x "$BIN/herdr"
SCREEN="$SHEPHERD_ROOT/screen"
{ printf '  ❯\n'; render 13 1000000; printf '  ⏵⏵ auto mode on\n'; } > "$SCREEN"
assert_eq "ctx parses the rendered line as percent and ktokens" \
  "$(PATH="$BIN:$PATH" HERDR_STUB_SCREEN="$SCREEN" bash "$ROLLOVER" ctx w1:p1)" "13 130"
{ printf '  ❯\n'; render 13 null; } > "$SCREEN"
assert_eq "a window-less line parses as percent-only (tokens 0)" \
  "$(PATH="$BIN:$PATH" HERDR_STUB_SCREEN="$SCREEN" bash "$ROLLOVER" ctx w1:p1)" "13 0"

# --- install: first run installs and registers ------------------------------
DST="$HOME/.claude/statusline.py"; SETTINGS="$HOME/.claude/settings.json"
out=$(bash "$INSTALL"); rc=$?
assert_eq "first run exits 0" "$rc" "0"
assert_eq "first run reports installed+registered" \
  "$out" "statusline: file=installed settings=registered -> $DST"
assert_file "the script is installed" "$DST"
assert_ok "the installed copy matches the repo" cmp -s "$SL" "$DST"
assert_ok "the installed copy is executable" test -x "$DST"
assert_eq "settings.json registers the command" \
  "$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["statusLine"]; print(s["type"], s["command"])' "$SETTINGS")" \
  "command python3 $DST"

# --- install: second run changes nothing ------------------------------------
out=$(bash "$INSTALL")
assert_eq "second run reports unchanged on both halves" \
  "$out" "statusline: file=unchanged settings=unchanged -> $DST"
assert_ok "--check exits 0 when current" bash "$INSTALL" --check
assert_nofile "no .prev is written when nothing was displaced" "$DST.prev"

# --- install: merges into existing settings, preserving everything else -----
python3 - "$SETTINGS" <<'PY'
import json, sys
json.dump({"permissions": {"allow": ["Bash(ls)"]},
           "hooks": {"Stop": [{"matcher": "*", "hooks": []}]},
           "statusLine": {"type": "command", "command": "old.sh", "padding": 2}},
          open(sys.argv[1], "w"), indent=2)
PY
out=$(bash "$INSTALL")
assert_eq "an old command is replaced" "$out" "statusline: file=unchanged settings=registered -> $DST"
python3 - "$SETTINGS" "$DST" <<'PY' && ok "unrelated keys and padding survive the merge" || fail "unrelated keys and padding survive the merge" "$(cat "$SETTINGS")"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["permissions"] == {"allow": ["Bash(ls)"]}, s
assert "Stop" in s["hooks"], s
assert s["statusLine"]["padding"] == 2, s
assert s["statusLine"]["command"] == "python3 " + sys.argv[2], s
PY

# --- install: a local edit is replaced and kept once as .prev ---------------
printf '# local edit\n' >> "$DST"
assert_fail "--check exits 1 when the file differs" bash "$INSTALL" --check
assert_ok "--check names the file half" bash -c 'bash "$1" --check | grep -q "file=updated"' _ "$INSTALL"
assert_ok "--check wrote nothing" grep -q 'local edit' "$DST"
out=$(bash "$INSTALL")
assert_eq "a differing file is updated" "$out" "statusline: file=updated settings=unchanged -> $DST"
assert_ok "the repo copy is back in place" cmp -s "$SL" "$DST"
assert_ok "the displaced copy is kept as .prev" grep -q 'local edit' "$DST.prev"

# --- install: a HOME with no ~/.claude at all -------------------------------
export HOME="$SHEPHERD_ROOT/home2"; mkdir -p "$HOME"
out=$(bash "$INSTALL"); rc=$?
assert_eq "a bare HOME is initialised" "$rc" "0"
assert_file "settings.json is created" "$HOME/.claude/settings.json"
assert_ok "--check on a missing file exits 1" \
  bash -c 'rm -f "$1/.claude/statusline.py"; ! bash "$2" --check >/dev/null' _ "$HOME" "$INSTALL"

# --- structure: the installer is HOME-relative and never names the real one -
assert_fail "the installer hard-codes no home directory" grep -q '/home/' "$INSTALL"
assert_ok "the installer resolves paths from HOME" grep -q '\$HOME/.claude' "$INSTALL"

finish
