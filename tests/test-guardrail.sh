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
HOOK="${GUARDRAIL_HOOK:-$HERE/../hooks/worker-git-guardrail.sh}"

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
#
# `env -u SHEPHERD_STATUS_FILE` is mandatory, and it is the same rule the other
# probes get from sandbox() — this is the one file that takes no sandbox, so it
# says it here. Setting SHEPHERD_TASK_ID while INHERITING the status-file path
# is a partial override, and a partial override is exactly what wrote a stray
# record into a live instance's ground-truth file mid-run on 2026-09-02. The
# guardrail hook writes no records today; the shape is the hazard, and the next
# hook to be probed from this file would inherit it.
verdict() {
  local json out rc reason
  json=$(payload "$1")
  # a here-string, not a pipe: the hook may exit before it reads stdin, and a
  # pipe would then report the writer's EPIPE instead of the hook's verdict.
  out=$(env -u SHEPHERD_STATUS_FILE SHEPHERD_TASK_ID=T-TEST bash "$HOOK" <<<"$json" 2>&1)
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
  out=$(env -u SHEPHERD_STATUS_FILE SHEPHERD_TASK_ID=T-TEST PATH="$FB_DIR:$PATH" bash "$HOOK" <<<"$json" 2>&1)
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

# --- whole-tree discards (T-0214) -------------------------------------------
# `git checkout .` was blocked; `git checkout -- .` was not, and neither were
# the restore forms that reach the working tree. Per-path forms stay allowed:
# a worker restoring one file it broke is ordinary work.
assert_eq "checkout -- ."                  "$(verdict 'git checkout -- .')"                  "blocked: discard working tree"
assert_eq "checkout ."                     "$(verdict 'git checkout .')"                     "blocked: discard working tree"
assert_eq "checkout HEAD -- ."             "$(verdict 'git checkout HEAD -- .')"             "blocked: discard working tree"
assert_eq "checkout -- ./"                 "$(verdict 'git checkout -- ./')"                 "blocked: discard working tree"
assert_eq "-C <dir> before checkout -- ."  "$(verdict 'git -C /repo checkout -- .')"        "blocked: discard working tree"
assert_eq "restore ."                      "$(verdict 'git restore .')"                      "blocked: discard working tree"
assert_eq "restore --worktree ."           "$(verdict 'git restore --worktree .')"           "blocked: discard working tree"
assert_eq "restore --staged --worktree ."  "$(verdict 'git restore --staged --worktree .')"  "blocked: discard working tree"
assert_eq "restore -SW ."                  "$(verdict 'git restore -SW .')"                  "blocked: discard working tree"
assert_eq "restore --source=HEAD ."        "$(verdict 'git restore --source=HEAD .')"        "blocked: discard working tree"
assert_eq "restore . after a chain"        "$(verdict 'npm test && git restore .')"          "blocked: discard working tree"

# Fix round 1: a command holding TWO `git restore` invocations used to let a
# greedy command-wide sed read the LAST restore's flags for the whole match,
# so a destructive `restore .` followed by a benign `restore --staged .` fell
# through to allowed. restore is now evaluated per command segment.
assert_eq "restore . && restore --staged ." "$(verdict 'git restore . && git restore --staged .')" "blocked: discard working tree"
assert_eq "restore . && restore --staged x" "$(verdict 'git restore . && git restore --staged x')" "blocked: discard working tree"
assert_eq "restore . ; restore --staged x"  "$(verdict 'git restore . ; git restore --staged x')"  "blocked: discard working tree"
assert_eq "status && restore . && restore --staged ." "$(verdict 'git status && git restore . && git restore --staged .')" "blocked: discard working tree"

# Fix round 2: the two arms disagreed on what `$` meant. Giving restore a
# per-segment loop made its `( |$)` end-of-SEGMENT, while checkout still ran
# against the whole command, where `$` is end-of-COMMAND — so a whole-tree
# discard followed DIRECTLY by a separator (no space between the `.` and the
# `;`, `&&`, `|` or trailing `&`) matched neither alternative and was allowed,
# in all four separator forms and with an explicit `HEAD --` prefix too. The
# spaced forms blocked throughout, which is what kept the hole quiet. Both arms
# now run through the one loop.
assert_eq "checkout .;echo x"              "$(verdict 'git checkout .;echo x')"              "blocked: discard working tree"
assert_eq "checkout .&&echo x"             "$(verdict 'git checkout .&&echo x')"             "blocked: discard working tree"
assert_eq "checkout .|cat"                 "$(verdict 'git checkout .|cat')"                 "blocked: discard working tree"
assert_eq "checkout .& (backgrounded)"     "$(verdict 'git checkout .&')"                    "blocked: discard working tree"
assert_eq "checkout HEAD -- .;echo x"      "$(verdict 'git checkout HEAD -- .;echo x')"      "blocked: discard working tree"
# The spaced forms were already blocked; pinned so a later rewrite cannot fix
# the unspaced half by breaking the half that worked.
assert_eq "checkout . ; echo x"            "$(verdict 'git checkout . ; echo x')"            "blocked: discard working tree"
assert_eq "checkout . && echo x"           "$(verdict 'git checkout . && echo x')"           "blocked: discard working tree"

assert_eq "checkout -b x"                  "$(verdict 'git checkout -b x')"                  "allowed"
assert_eq "checkout a branch"              "$(verdict 'git checkout main')"                  "allowed"
assert_eq "checkout -- one file"           "$(verdict 'git checkout -- src/a.py')"           "allowed"
assert_eq "checkout a dotfile"             "$(verdict 'git checkout -- .env')"               "allowed"
assert_eq "restore --staged file"          "$(verdict 'git restore --staged src/a.py')"      "allowed"
assert_eq "restore --staged . (unstaging is recoverable)" "$(verdict 'git restore --staged .')" "allowed"
assert_eq "restore one file"               "$(verdict 'git restore src/a.py')"               "allowed"
assert_eq "restore a dotted path"          "$(verdict 'git restore ./src/a.py')"             "allowed"
assert_eq "checkout . by a program merely ending in git stays allowed" "$(verdict 'legit checkout -- .')" "allowed"
# …and moving checkout into the segment loop must not start blocking ordinary
# chained work. The unspaced separator is the case the fix turns on, so the
# allowed side gets it too.
assert_eq "checkout a branch;then something"  "$(verdict 'git checkout main;npm test')"        "allowed"
assert_eq "checkout -- one file&&then something" "$(verdict 'git checkout -- src/a.py&&npm test')" "allowed"
assert_eq "checkout a branch, then a bare . elsewhere" "$(verdict 'git checkout main && ls .')" "allowed"

# Fix round 3 (T-0254): per SEGMENT was not per INVOCATION. A `$(…)`, a `#`
# comment or a `--` puts two `git restore` in one segment, and the greedy sed
# still read the LAST one's flags for the whole segment - so a destructive
# `restore .` with a benign `restore --staged .` anywhere after it in the same
# segment fell through to allowed (measured against this hook 2026-09-08).
# Every invocation now reads its own arguments, in order, and the first
# destructive one decides.
assert_eq "restore . with restore --staged . in a substitution" \
  "$(verdict 'git restore . $(git restore --staged .)')" "blocked: discard working tree"
assert_eq "restore . with restore --staged . in a comment" \
  "$(verdict 'git restore . # git restore --staged .')" "blocked: discard working tree"
assert_eq "restore . with restore --staged . after --" \
  "$(verdict 'git restore . -- git restore --staged .')" "blocked: discard working tree"
assert_eq "restore --staged . with restore . in a substitution" \
  "$(verdict 'git restore --staged . $(git restore .)')" "blocked: discard working tree"
# …and a benign invocation is still judged on its own arguments, not its
# neighbour's.
assert_eq "restore --staged . with restore --staged x in a substitution" \
  "$(verdict 'git restore --staged . $(git restore --staged x)')" "allowed"
# The `.` inside `$(…)` is closed by `)`, not a space - the unspaced-terminator
# hole of fix round 2 in its substitution form. Both arms read `)` as the end
# of the pathspec now; a branch name or a --staged-only unstage inside `$(…)`
# stays ordinary work.
assert_eq "checkout . inside a substitution"       "$(verdict 'out=$(git checkout .)')"          "blocked: discard working tree"
assert_eq "checkout -- . inside a substitution"    "$(verdict 'out=$(git checkout -- .)')"       "blocked: discard working tree"
assert_eq "restore . inside a substitution"        "$(verdict 'out=$(git restore .)')"           "blocked: discard working tree"
assert_eq "restore --staged . inside a substitution stays allowed" "$(verdict 'out=$(git restore --staged .)')" "allowed"
assert_eq "checkout a branch inside a substitution stays allowed"  "$(verdict 'out=$(git checkout main)')"    "allowed"
# The cost of reading `)` as a terminator, pinned so a later rewrite cannot
# quietly change it: a `)` closing an UNRELATED substitution ends the pathspec
# too, so an ordinary command carrying one after the git word blocks. That is
# the header's fail-closed trade, the same one that blocks a heredoc merely
# mentioning a pattern - not a case anybody has needed.
assert_eq "a branch checkout with an unrelated substitution after it blocks" \
  "$(verdict 'git checkout main $(echo .)')" "blocked: discard working tree"
assert_eq "a per-path restore with an unrelated substitution after it blocks" \
  "$(verdict 'git restore src/a.py $(ls .)')" "blocked: discard working tree"

# --- reply mode (T-0240) ----------------------------------------------------
# SHEPHERD_WORKER_KIND=reply marks a read-only reply worker (spec
# docs/specs/2026-09-07-linear-conversation-design.md §2 Launch): the hook
# refuses every push, commit, deploy and outward post outright, because the
# worker's only voice is shepherd-reply and every post is shepherd's. Build
# mode is unchanged: the same commands stay allowed without the variable.
rverdict() {
  local json out rc reason
  json=$(payload "$1")
  out=$(env -u SHEPHERD_STATUS_FILE SHEPHERD_TASK_ID=T-TEST SHEPHERD_WORKER_KIND=reply bash "$HOOK" <<<"$json" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] && { printf 'allowed'; return 0; }
  reason=$(printf '%s' "$out" | sed -n "s/^BLOCKED by shepherd guardrail: '\([^']*\)'\..*/\1/p")
  printf 'blocked: %s' "${reason:-exit $rc, unparsed: $out}"
}
# rboth <name> <command> <reply-reason> - refused in reply mode, allowed in build mode
rboth() {
  assert_eq "reply: $1" "$(rverdict "$2")" "blocked: reply: $3"
  assert_eq "build mode unchanged: $1" "$(verdict "$2")" "allowed"
}
rboth "a task-branch push"                 'git push origin task/T-0240-x'        "git push"
rboth "a bare push"                        'git push'                            "git push"
rboth "-C <dir> before a push"             'git -C /repo push origin x'          "git push"
rboth "a push behind &&"                   'npm test && git push origin x'       "git push"
rboth "a commit"                           'git commit -m x'                     "git commit"
rboth "-C <dir> before a commit"           'git -C /repo commit -am x'           "git commit"
rboth "a tab between git and commit"       "$(printf 'git\tcommit -m x')"        "git commit"
rboth "wrangler deploy"                    'wrangler deploy'                     "wrangler"
rboth "npx wrangler deploy"                'npx wrangler deploy --env prod'      "wrangler"
rboth "a pinned npx wrangler"              'npx wrangler@4 d1 execute db --remote --command x' "wrangler"
rboth "pnpm dlx wrangler"                  'pnpm dlx wrangler deploy'            "wrangler"
rboth "bunx wrangler"                      'bunx wrangler deploy'                "wrangler"
rboth "npm run deploy"                     'npm run deploy'                      "deploy script"
rboth "npm run deploy:prod"                'npm run deploy:prod'                 "deploy script"
rboth "pnpm deploy"                        'pnpm deploy'                         "deploy script"
rboth "yarn deploy"                        'yarn deploy'                         "deploy script"
rboth "bun run deploy"                     'bun run deploy'                      "deploy script"
rboth "gh pr merge"                        'gh pr merge 12 --squash'             "gh pr merge"
rboth "gh pr close"                        'gh pr close 12'                      "gh pr close"
rboth "gh pr create"                       'gh pr create --fill'                 "gh pr create"
rboth "gh pr edit"                         'gh pr edit 12 --title x'             "gh pr edit"
rboth "gh pr review"                       'gh pr review 12 --approve'           "gh pr review"
rboth "gh pr comment"                      'gh pr comment 12 --body hi'          "gh pr comment"
rboth "gh issue comment"                   'gh issue comment 7 --body hi'        "gh issue comment"
rboth "gh release create"                  'gh release create v1'                "gh release"
rboth "gh api -X POST"                     'gh api -X POST repos/o/r/issues'     "gh api write"
rboth "gh api --method DELETE"             'gh api --method DELETE repos/o/r/git/refs/heads/x' "gh api write"
rboth "gh api with a field (an implicit POST)" 'gh api repos/o/r/issues/1/comments -f body=hi' "gh api write"
rboth "gh api --input"                     'gh api repos/o/r/pulls --input body.json' "gh api write"
# review fix round: the GET exemption must not cross a separator, the attached
# pflag form counts, a graphql mutation is a write, and two more egress verbs
rboth "gh api -X GET, then -X DELETE"      'gh api -X GET repos/o/r && gh api -X DELETE repos/o/r/git/refs/heads/x' "gh api write"
rboth "gh api -X GET ; -X POST"            'gh api -X GET repos/o/r ; gh api -X POST repos/o/r/issues' "gh api write"
rboth "gh api -XPOST (attached)"           'gh api -XPOST repos/o/r/issues'      "gh api write"
rboth "gh api --method=DELETE"             'gh api --method=DELETE repos/o/r/git/refs/heads/x' "gh api write"
rboth "gh api graphql with a mutation"     "gh api graphql -f query='mutation { x }'" "gh api write"
rboth "gh workflow run"                    'gh workflow run deploy.yml'          "gh workflow run"
rboth "curl -X POST"                       'curl -X POST https://x/api'          "curl write"
rboth "curl -XDELETE"                      'curl -XDELETE https://x/api/1'       "curl write"
rboth "curl --request PUT"                 'curl --request PUT https://x/api/1'  "curl write"
rboth "curl with a body"                   'curl -d @body.json https://x/api'    "curl write"
rboth "curl --json"                        'curl --json @b.json https://x/api'   "curl write"
rboth "wrangler in a substitution"         'out=$(wrangler deploy)'              "wrangler"
rboth "wrangler behind an env assignment"  'CLOUDFLARE_ENV=prod wrangler deploy' "wrangler"
rboth "wrangler behind &&"                 'cd app && wrangler deploy'           "wrangler"
rboth "npm run deploy behind &&"           'npm ci && npm run deploy'            "deploy script"
# Fix round 3 (T-0254): the GET and graphql exemptions read the whole segment,
# so a benign invocation anywhere in it excused a destructive one - in either
# order - once `$(…)` put two in one segment (measured against this hook
# 2026-09-08). Each invocation is now judged on its own arguments; the first
# destructive one decides.
rboth "gh api -X DELETE with a -X GET in a substitution" \
  'gh api -X DELETE repos/o/r/git/refs/heads/x $(gh api -X GET repos/o/r)' "gh api write"
rboth "gh api -X GET with a -X DELETE in a substitution" \
  'gh api -X GET repos/o/r $(gh api -X DELETE repos/o/r/git/refs/heads/x)' "gh api write"
rboth "gh api field write with a graphql query in a substitution" \
  "gh api repos/o/r/issues -f body=hi \$(gh api graphql -f query='query { x }')" "gh api write"
rboth "gh api graphql query with a field write in a substitution" \
  "gh api graphql -f query='query { x }' \$(gh api repos/o/r/issues -f body=hi)" "gh api write"
rboth "curl -X POST with a -X GET in a substitution" \
  'curl -X POST https://x/api $(curl -X GET https://y)' "curl write"
rboth "curl -X GET with a -X POST in a substitution" \
  'curl -X GET https://x $(curl -X POST https://y)' "curl write"
# The field-flag boundary moved with the per-invocation split: it reads the
# invocation's own arguments from their start, where the old command-wide
# pattern needed something before the flag. A field flag FIRST is an implicit
# POST like any other, and used to fall through to allowed.
rboth "gh api with a leading field flag"   'gh api -f body=hi repos/o/r/issues'  "gh api write"
rboth "gh api with a leading --input"      'gh api --input body.json repos/o/r/pulls' "gh api write"
assert_eq "reply: two read-only gh api calls in one segment stay allowed" \
  "$(rverdict 'gh api -X GET repos/o/r $(gh api -X GET repos/o/r/pulls)')" "allowed"
assert_eq "reply: two read-only curls in one segment stay allowed" \
  "$(rverdict 'curl -X GET https://x $(curl -s https://y)')" "allowed"

# reading stays allowed in reply mode: the lane is for reading
for c in 'git status' 'git log --oneline -5' 'git diff main...HEAD' 'git -C /repo log -1' \
         'git show HEAD:src/a.ts' 'git ls-remote --heads origin' 'gh pr view 12' 'gh pr diff 12' \
         'gh pr checks 12' 'gh pr list' 'gh api repos/o/r/pulls/12' 'gh api -X GET repos/o/r' \
         'npm test' 'npm run build' 'npm run lint' 'grep -rn deploy src/' 'legit push origin x' \
         'cat wrangler.jsonc' 'grep -rn wrangler src/' 'rg -l wrangler' 'grep -rn "npm run deploy" package.json' \
         "gh api graphql -f query='query { repository(owner: \"o\", name: \"r\") { id } }'" \
         'curl -s https://x/api/1' 'curl -X GET https://x/api/1' 'curl -sL -o /tmp/x https://x/f' \
         'gh workflow list' 'gh workflow view deploy.yml' 'cat wrangler.toml'; do
  assert_eq "reply allows: $c" "$(rverdict "$c")" "allowed"
done

# the reply refusal tells the worker what to do instead of asking for approval
json=$(payload 'git push origin x')
out=$(env -u SHEPHERD_STATUS_FILE SHEPHERD_TASK_ID=T-TEST SHEPHERD_WORKER_KIND=reply bash "$HOOK" <<<"$json" 2>&1)
assert_ok "the reply refusal says a reply worker changes nothing" grep -q 'reply worker changes nothing' <<<"$out"
assert_fail "and does not ask the worker to seek approval" grep -q 'need approval' <<<"$out"
assert_ok "and points at Next step for a change the question needs" grep -q 'Next step' <<<"$out"

# reply mode keeps the build rules underneath it
assert_eq "reply: reset --hard still blocks by the build rule" "$(rverdict 'git reset --hard HEAD~1')" "blocked: git reset --hard"
# the fail-closed cost holds here as in build mode
assert_eq "reply: a command that merely mentions a push still blocks" "$(rverdict "echo 'git push origin x'")" "blocked: reply: git push"
# a value other than reply is build mode; the gate on SHEPHERD_TASK_ID comes first
json=$(payload 'git push origin task/x')
out=$(env -u SHEPHERD_STATUS_FILE SHEPHERD_TASK_ID=T-TEST SHEPHERD_WORKER_KIND=build bash "$HOOK" <<<"$json" 2>&1)
assert_eq "SHEPHERD_WORKER_KIND=build is build mode" "$?" "0"
out=$(env -u SHEPHERD_TASK_ID SHEPHERD_WORKER_KIND=reply bash "$HOOK" <<<"$json" 2>&1)
assert_eq "reply mode without SHEPHERD_TASK_ID is inert" "$?" "0"
# the fallback path decodes for reply mode too
json=$(payload "$(printf 'git\tpush origin x')")
out=$(env -u SHEPHERD_STATUS_FILE SHEPHERD_TASK_ID=T-TEST SHEPHERD_WORKER_KIND=reply PATH="$FB_DIR:$PATH" bash "$HOOK" <<<"$json" 2>&1)
assert_eq "fallback: reply mode blocks a tab-separated push" "$?" "2"
finish
