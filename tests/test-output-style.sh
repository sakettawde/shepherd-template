#!/usr/bin/env bash
# Fixture-driven probe for `shepherd-output-style` — the wake-time check that a
# session's output style keeps Claude Code's software-engineering instructions
# (the manual §6, T-0233). Under test: the four DoD cases (custom with the field
# passes, custom without fails naming the file, a built-in passes, no setting
# passes); the style file is found by `name:` before file name; the user level is
# the default scope and project resolution needs an argument; project local beats
# project beats user; a worktree reads the main checkout's local file; managed
# outranks everything; and the check never writes.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
SCRIPT="$HERE/../bin/shepherd-output-style"

echo "test-output-style:"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is available" "python3 not found"
  finish; exit
fi

# MANDATORY: HOME is redirected because the check reads ~/.claude, and the
# fixtures below must never be mistaken for the operator's live files.
export HOME="$SHEPHERD_ROOT/home"; mkdir -p "$HOME/.claude/output-styles"
export OSC_MANAGED="$SHEPHERD_ROOT/managed-settings.json"   # absent unless a case writes it
USER_SETTINGS="$HOME/.claude/settings.json"
STYLES="$HOME/.claude/output-styles"

# settings <file> <style|-> — writes a settings file; "-" = a file with no outputStyle
settings() { if [ "$2" = "-" ]; then printf '{"model":"opus"}\n' > "$1"; else printf '{"outputStyle":"%s"}\n' "$2" > "$1"; fi; }
# stylefile <path> <name|-> <keep|-> — a custom style; "-" = the field absent
stylefile() {
  { printf -- '---\n'
    [ "$2" != "-" ] && printf 'name: %s\n' "$2"
    printf 'description: fixture\n'
    [ "$3" != "-" ] && printf 'keep-coding-instructions: %s\n' "$3"
    printf -- '---\n\nWrite tersely.\n'; } > "$1"
}
run() { bash "$SCRIPT" "$@" 2>&1 </dev/null; }

# === the four DoD cases, user level ==========================================
rm -f "$USER_SETTINGS"
out=$(run); rc=$?
assert_eq "no outputStyle anywhere exits 0" "$rc" "0"
assert_ok "no outputStyle is named as Default" grep -q 'no outputStyle set.*Default' <<<"$out"
assert_ok "no outputStyle ends ok" grep -q '^style: ok$' <<<"$out"
assert_ok "the default scope is the user level" grep -q '^style: scope user level' <<<"$out"

settings "$USER_SETTINGS" Concise
out=$(run); rc=$?
assert_eq "a built-in name exits 0" "$rc" "0"
assert_ok "a built-in name is named as built-in" grep -q 'Concise is a built-in style' <<<"$out"
assert_ok "the setting's file and level are named" grep -q "outputStyle \"Concise\" from $USER_SETTINGS (user)" <<<"$out"

settings "$USER_SETTINGS" STE100
stylefile "$STYLES/ste100.md" STE100 true
out=$(run); rc=$?
assert_eq "a custom style with the field exits 0" "$rc" "0"
assert_ok "a custom style with the field names its file" grep -q "STE100 -> $STYLES/ste100.md" <<<"$out"
assert_ok "and says the instructions stay" grep -q 'keep-coding-instructions: true' <<<"$out"
assert_fail "and names no degradation" grep -q DEGRADED <<<"$out"

stylefile "$STYLES/ste100.md" STE100 -
out=$(run); rc=$?
assert_eq "a custom style without the field exits 1" "$rc" "1"
assert_ok "the failure names the file" grep -q "DEGRADED.*$STYLES/ste100.md has no keep-coding-instructions: true" <<<"$out"
assert_ok "the failure names the repair" grep -q 'repair: add keep-coding-instructions: true' <<<"$out"
assert_ok "the failure ends DEGRADED" grep -q '^style: DEGRADED$' <<<"$out"

stylefile "$STYLES/ste100.md" STE100 false
out=$(run); rc=$?
assert_eq "an explicit false exits 1 too" "$rc" "1"

# === how the file is found ===================================================
# The docs (output-styles, read 2026-09-06): "The file name becomes the style
# name unless you set `name` in the frontmatter."
rm -f "$STYLES"/*.md
settings "$USER_SETTINGS" diagrams
stylefile "$STYLES/diagrams.md" - true
out=$(run); rc=$?
assert_eq "a file matched by its name exits 0" "$rc" "0"
assert_ok "a file matched by its name is named" grep -q "diagrams -> $STYLES/diagrams.md" <<<"$out"

rm -f "$STYLES"/*.md
stylefile "$STYLES/odd-file.md" Fancy true
settings "$USER_SETTINGS" Fancy
out=$(run); rc=$?
assert_eq "name: frontmatter wins over the file name" "$rc" "0"
assert_ok "and the file is named" grep -q "Fancy -> $STYLES/odd-file.md" <<<"$out"
settings "$USER_SETTINGS" odd-file
out=$(run); rc=$?
assert_eq "a file name shadowed by name: does not match" "$rc" "1"
assert_ok "an unresolved name is named, with the setting file" \
  grep -q 'DEGRADED.*"odd-file" is neither a built-in style nor.*repair:.*'"$USER_SETTINGS" <<<"$out"

settings "$USER_SETTINGS" Nowhere
out=$(run); rc=$?
assert_eq "an unknown name exits 1" "$rc" "1"

# === project resolution needs the argument ===================================
# A worker starts in a project repo where the user setting is usually the only
# one; the shepherd repo itself overrides with Concise in settings.local.json,
# which is exactly why the default scope must NOT be the current directory.
rm -f "$STYLES"/*.md
settings "$USER_SETTINGS" STE100
stylefile "$STYLES/ste100.md" STE100 -                      # user level: degraded
P="$SHEPHERD_ROOT/proj"; mkdir -p "$P/.claude"
git -C "$SHEPHERD_ROOT" init -q "$P" 2>/dev/null
settings "$P/.claude/settings.json" Explanatory
out=$(run); rc=$?
assert_eq "without an argument the project is not read" "$rc" "1"
out=$(run "$P"); rc=$?
assert_eq "with the project dir the project file wins over user" "$rc" "0"
assert_ok "the project level is named" grep -q "from $P/.claude/settings.json (project)" <<<"$out"
assert_ok "the scope line names the directory" grep -q "^style: scope $P " <<<"$out"

settings "$P/.claude/settings.local.json" Concise
out=$(run "$P"); rc=$?
assert_ok "project local beats project" grep -q "settings.local.json (project local)" <<<"$out"

# a subdirectory resolves the same files as the root
mkdir -p "$P/src/deep"
out=$(run "$P/src/deep"); rc=$?
assert_ok "a subdirectory reads the repo's project local file" grep -q "$P/.claude/settings.local.json (project local)" <<<"$out"

# a project style dir is searched before the user dir
rm -f "$P/.claude/settings.local.json"
settings "$P/.claude/settings.json" Team
mkdir -p "$P/.claude/output-styles"
stylefile "$P/.claude/output-styles/team.md" Team true
stylefile "$STYLES/team.md" Team -                            # same name, user level, degraded
out=$(run "$P"); rc=$?
assert_eq "a project style file is found before the user's" "$rc" "0"
assert_ok "and it is the project file that is named" grep -q "Team -> $P/.claude/output-styles/team.md" <<<"$out"

# === a worktree reads the main checkout's settings.local.json ================
# settings doc, read 2026-09-06: "In a worktree, it uses the file at the main
# checkout's root." Measured the same day: a session in shepherd-wt5, which has
# no settings.local.json, ran the base checkout's Concise.
settings "$P/.claude/settings.json" STE100                    # tracked file: degraded style
settings "$P/.claude/settings.local.json" Concise             # main checkout only
git -C "$P" -c user.email=t@t -c user.name=t add .claude/settings.json >/dev/null 2>&1
git -C "$P" -c user.email=t@t -c user.name=t commit -qm fixture >/dev/null 2>&1
W="$SHEPHERD_ROOT/proj-wt"
git -C "$P" worktree add -q --detach "$W" >/dev/null 2>&1
assert_file "the worktree fixture exists" "$W/.claude/settings.json"
assert_nofile "and carries no local file of its own" "$W/.claude/settings.local.json"
out=$(run "$W"); rc=$?
assert_eq "a worktree resolves the main checkout's local file" "$rc" "0"
assert_ok "and names it" grep -q "$P/.claude/settings.local.json (project local)" <<<"$out"
assert_ok "and says which checkout it read" grep -q "main checkout $P" <<<"$out"

# === managed settings outrank everything =====================================
printf '{"outputStyle":"Learning"}\n' > "$OSC_MANAGED"
out=$(run); rc=$?
assert_eq "a managed outputStyle wins" "$rc" "0"
assert_ok "and is named as managed" grep -q "(managed)" <<<"$out"
rm -f "$OSC_MANAGED"

# === the check only ever reads ===============================================
before=$(cat "$USER_SETTINGS" "$STYLES"/*.md "$P/.claude/settings.json" | md5sum)
run >/dev/null; run "$P" >/dev/null; run "$W" >/dev/null
after=$(cat "$USER_SETTINGS" "$STYLES"/*.md "$P/.claude/settings.json" | md5sum)
assert_eq "no fixture changed across three runs" "$after" "$before"

# === arguments ===============================================================
out=$(run "$SHEPHERD_ROOT/absent-dir"); rc=$?
assert_eq "a missing directory is a usage error (2)" "$rc" "2"
out=$(run --bogus); rc=$?
assert_eq "an unknown flag is a usage error (2)" "$rc" "2"

finish
