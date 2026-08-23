#!/usr/bin/env bash
# Probe for hooks/worker-git-guardrail.sh — the eleven cases of report T-0107 F6
# plus the option forms that report's proposal did not enumerate.
#
# Every case is fed to the real hook as a real PreToolUse payload, exactly as
# Claude Code delivers one (https://code.claude.com/docs/en/hooks): a JSON object
# on stdin carrying tool_input.command, exit 2 = block, exit 0 = no decision.
#
# The fixtures live in this file and never in a Bash tool call, because the hook
# matches the raw command string: an agent that tried to run these cases from the
# command line would block itself on its own probe.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
# GUARDRAIL_HOOK points the probe at another copy of the hook. Only use is
# re-running this file against a pristine copy to confirm a case is a genuine
# regression guard and not one that already passed.
HOOK="${GUARDRAIL_HOOK:-$HERE/../../hooks/worker-git-guardrail.sh}"

echo "test-guardrail:"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is available" "python3 not found — the hook and this probe both need it"
  finish
  exit
fi

# payload <command> — the PreToolUse JSON the hook reads on stdin
payload() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps({"session_id":"test","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

# verdict <command> — "allowed", or "blocked: <the hook s own reason>"
verdict() {
  local json out rc reason
  json=$(payload "$1")
  # a here-string, not a pipe: the hook may exit before it reads stdin, and a
  # pipe would then report the writer's EPIPE instead of the hook's verdict.
  out=$(SHEPHERD_TASK_ID=T-TEST bash "$HOOK" <<<"$json" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] && { printf 'allowed'; return 0; }
  reason=$(printf '%s' "$out" | sed -n "s/^BLOCKED by shepherd guardrail: '\([^']*\)'\..*/\1/p")
  printf 'blocked: %s' "${reason:-exit $rc, unparsed: $out}"
}

# --- the eleven cases of F6, in the report's order -------------------------
# The six the report measured as ALLOWED must all read BLOCKED now, and the one
# it measured as correctly allowed must stay allowed.

assert_eq "force push"                     "$(verdict 'git push --force origin x')" \
  "blocked: force push"
assert_eq "-C <dir> before a force push"   "$(verdict 'git -C /repo push --force origin x')" \
  "blocked: force push"
assert_eq "-c <k=v> before a force push"   "$(verdict 'git -c user.name=x push --force origin x')" \
  "blocked: force push"
assert_eq "reset --hard"                   "$(verdict 'git reset --hard HEAD~1')" \
  "blocked: git reset --hard"
assert_eq "-C <dir> before reset --hard"   "$(verdict 'git -C /repo reset --hard HEAD~1')" \
  "blocked: git reset --hard"
assert_eq "-C <dir> before clean -fd"      "$(verdict 'git -C /repo clean -fd')" \
  "blocked: git clean -f"
assert_eq "a tab between git and push"     "$(verdict "$(printf 'git\tpush --force origin x')")" \
  "blocked: force push"
assert_eq "push to main"                   "$(verdict 'git push origin main')" \
  "blocked: push touching a protected branch"
assert_eq "push to HEAD:dev"               "$(verdict 'git push origin HEAD:dev')" \
  "blocked: push touching a protected branch"
assert_eq "a task-branch push stays allowed" "$(verdict 'git push origin task/T-0107-x')" \
  "allowed"
assert_eq "force push behind &&"           "$(verdict 'echo hi && git push --force origin x')" \
  "blocked: force push"

# --- global-option forms the report's proposal did not enumerate -----------
# git accepts an argument-taking global option in both the = form and the space
# form (verified against git 2.43.0), and it has flag-only globals beyond the
# six the report listed. Normalisation strips any option, not a fixed list.

# the path deliberately does not end in `.git`: `/repo/.git push --force` would
# put the literal `git push --force` into the string and pass without any
# normalisation at all.
assert_eq "--git-dir= before a force push" "$(verdict 'git --git-dir=/srv/bare.gd push --force origin x')" \
  "blocked: force push"
assert_eq "--git-dir <dir> before a force push" "$(verdict 'git --git-dir /srv/bare.gd push --force origin x')" \
  "blocked: force push"
assert_eq "--work-tree <dir> before clean -fd" "$(verdict 'git --work-tree /repo clean -fd')" \
  "blocked: git clean -f"
assert_eq "--no-optional-locks before a force push" "$(verdict 'git --no-optional-locks push --force origin x')" \
  "blocked: force push"
assert_eq "a flag-only global before an argument-taking one" \
  "$(verdict 'git --no-pager -C /repo push --force origin x')" \
  "blocked: force push"
assert_eq "two argument-taking globals in a row" \
  "$(verdict 'git -C /repo -c user.name=x push --force origin x')" \
  "blocked: force push"
assert_eq "-C <dir> before branch -D"      "$(verdict 'git -C /repo branch -D somebranch')" \
  "blocked: git branch -D"
assert_eq "-C <dir> before push to dev"    "$(verdict 'git -C /repo push origin HEAD:dev')" \
  "blocked: push touching a protected branch"
assert_eq "a line continuation between git and push" \
  "$(verdict "$(printf 'git \\\n  push --force origin x')")" \
  "blocked: force push"

# --- `git` is not always the first word ------------------------------------
# Normalisation has to find `git` wherever it sits, but must not fire on a word
# that merely ends in those three letters.

assert_eq "-C <dir> after a && chain"      "$(verdict 'cd /repo && git -C . push --force origin x')" \
  "blocked: force push"
assert_eq "-C <dir> inside a substitution" "$(verdict 'out=$(git -C /repo push --force origin x)')" \
  "blocked: force push"
assert_eq "-C <dir> behind an absolute path" "$(verdict '/usr/bin/git -C /repo push --force origin x')" \
  "blocked: force push"

# --- normalisation must not invent blocks ----------------------------------
# A newline is a command separator, like ; | and &. Collapsing it to a space
# would splice two commands into one and block this pair on a --force that
# belongs to neither git nor push.

assert_eq "a newline still separates two commands" \
  "$(verdict "$(printf 'git push origin task/T-0107-x\necho --force')")" \
  "allowed"
assert_eq "-C <dir> before a task-branch push stays allowed" \
  "$(verdict 'git -C /repo push origin task/T-0107-x')" \
  "allowed"
assert_eq "a global option alone is not a subcommand" \
  "$(verdict 'git -C /repo status --short')" \
  "allowed"

# --- a word that merely ends in `git` is not git ----------------------------
# Every pattern anchors on the sequence `git <subcommand>`, and without a
# boundary guard the three letters inside `legit` satisfy it: an unrelated
# program with a `push` subcommand of its own blocks on shepherd's git rules.
# The guard is the one normalisation already uses — the character before `git`
# must not be alphanumeric, `_` or `-` — so `deploy-git` is its own program too.
# One case per block pattern: the guard has to reach all nine, not just the
# force-push one the flag was raised against.

assert_eq "a force push by a program merely ending in git" \
  "$(verdict 'legit push --force origin x')" "allowed"
assert_eq "a forced refspec by a program merely ending in git" \
  "$(verdict 'mygit push origin +main:main')" "allowed"
assert_eq "a protected-branch push by a program merely ending in git" \
  "$(verdict 'legit push origin main')" "allowed"
assert_eq "a branch deletion by a program merely ending in git" \
  "$(verdict 'legit push origin --delete somebranch')" "allowed"
assert_eq "reset --hard by a program merely ending in git" \
  "$(verdict 'digit reset --hard HEAD~1')" "allowed"
assert_eq "clean -fd by a program merely ending in git" \
  "$(verdict 'legit clean -fd')" "allowed"
assert_eq "branch -D by a program merely ending in git" \
  "$(verdict 'mygit branch -D somebranch')" "allowed"
assert_eq "checkout . by a program merely ending in git" \
  "$(verdict 'legit checkout .')" "allowed"
assert_eq "stash drop by a program merely ending in git" \
  "$(verdict 'legit stash drop')" "allowed"
assert_eq "a hyphen before git makes it another program" \
  "$(verdict 'deploy-git push --force origin x')" "allowed"

# The same nine patterns must still block real git. The suite above already
# covers force push, protected-branch push, reset --hard, clean -f and
# branch -D; these are the four it never asserted.

assert_eq "a forced refspec still blocks" \
  "$(verdict 'git push origin +main:main')" "blocked: forced refspec push"
assert_eq "a remote branch deletion still blocks" \
  "$(verdict 'git push origin --delete somebranch')" "blocked: remote branch deletion"
assert_eq "discarding the working tree still blocks" \
  "$(verdict 'git checkout .')" "blocked: discard working tree"
assert_eq "stash drop still blocks" \
  "$(verdict 'git stash drop')" "blocked: git stash drop/clear"
assert_eq "sudo before git still blocks" \
  "$(verdict 'sudo git push --force origin x')" "blocked: force push"

# The boundary guard narrows *which word counts as git*. It does not narrow the
# hook's fail-closed cost: a command that merely mentions the pattern in its own
# arguments still blocks, exactly as the hook header says it does. Pinned here
# so a later widening of this guard cannot weaken the hook by accident.
assert_eq "a command that merely mentions the pattern still blocks" \
  "$(verdict "echo 'git push --force origin x'")" "blocked: force push"

# --- the python3 fallback path ----------------------------------------------
# python3 is not guaranteed either, so the hook falls back to matching the raw
# JSON envelope. In that envelope a tab is the two characters \t and a newline
# is \n — escapes the whitespace normalisation never sees. Undecoded they cut
# both ways: a tab-separated destructive command slips, and a two-command line
# joined by \n reads as one command and blocks on a flag belonging to neither.

FB_DIR=$(mktemp -d)
trap 'rm -rf "$FB_DIR"' EXIT
# A stub that fails, not a missing binary: this probe needs python3 itself to
# build the payload, and the hook inherits PATH from the probe.
printf '#!/bin/sh\ntouch "%s/called"\nexit 1\n' "$FB_DIR" >"$FB_DIR/python3"
chmod +x "$FB_DIR/python3"

# fb_verdict <command> — verdict, with the hook's python3 forced to fail
fb_verdict() {
  local json out rc reason
  json=$(payload "$1")
  out=$(SHEPHERD_TASK_ID=T-TEST PATH="$FB_DIR:$PATH" bash "$HOOK" <<<"$json" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] && { printf 'allowed'; return 0; }
  reason=$(printf '%s' "$out" | sed -n "s/^BLOCKED by shepherd guardrail: '\([^']*\)'\..*/\1/p")
  printf 'blocked: %s' "${reason:-exit $rc, unparsed: $out}"
}

# Without this the cases below would quietly re-test the python3 path and pass
# for the wrong reason the day the hook learns to reach for something else.
rm -f "$FB_DIR/called"
fb_verdict 'true' >/dev/null
assert_file "the fallback is the path under test" "$FB_DIR/called"

# fb_same <name> <expected> <command> — the fallback reaches <expected>, and it
# reaches the same verdict the python3 path does. The second half is why the
# fallback decodes at all: however the command was extracted, normalisation has
# to receive the same characters. A row that diverges is a fallback-only hole.
fb_same() {
  assert_eq "fallback: $1" "$(fb_verdict "$3")" "$2"
  assert_eq "fallback agrees with the python3 path: $1" \
    "$(fb_verdict "$3")" "$(verdict "$3")"
}

fb_same "a space-separated force push" "blocked: force push" \
  'git push --force origin x'
fb_same "a tab between git and push" "blocked: force push" \
  "$(printf 'git\tpush --force origin x')"
fb_same "a tab before reset --hard" "blocked: git reset --hard" \
  "$(printf 'git\treset --hard HEAD~1')"
fb_same "a line continuation between git and push" "blocked: force push" \
  "$(printf 'git \\\n  push --force origin x')"
fb_same "a newline still separates two commands" "allowed" \
  "$(printf 'git push origin task/T-0107-x\necho --force')"
fb_same "the boundary guard holds here too" "allowed" \
  'legit push --force origin x'
fb_same "-C <dir> before a force push" "blocked: force push" \
  'git -C /repo push --force origin x'

# --- the gate ---------------------------------------------------------------
# The hook is inert outside a worker session: no SHEPHERD_TASK_ID, no opinion.

json=$(payload 'git push --force origin x')
out=$(env -u SHEPHERD_TASK_ID bash "$HOOK" <<<"$json" 2>&1)
assert_eq "without SHEPHERD_TASK_ID the hook is inert" "$?" "0"
assert_eq "and it says nothing" "$out" ""

assert_eq "an empty command is allowed" "$(verdict '')" "allowed"

finish
