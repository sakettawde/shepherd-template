#!/bin/bash
# shepherd worker PreToolUse hook (matcher: Bash) — blocks destructive git before
# it executes. Adapted from mattpocock/skills git-guardrails (MIT).
# Registered user-globally in ~/.claude/settings.json; exits instantly for any
# session that does not carry shepherd's env vars, so manual Claude sessions and
# shepherd itself are unaffected.
#
# Shepherd delta vs upstream: plain `git push` is ALLOWED — project working
# agreements require workers to push their task branch. Blocked instead:
# force pushes, pushes to protected branches, remote branch deletion, and
# history/worktree destruction. Everything here is escalation-only per
# shepherd's decision-authority table (CLAUDE.md §4).
#
# WHAT THIS IS NOT. Matching a shell command as a string is inherently leaky:
# quoting, aliases, variables, `eval`, and a wrapper script all defeat it, and
# Claude Code's own permissions doc says as much about the same technique —
# "Attempting to constrain command arguments using Bash permission patterns is
# considered fragile" (https://code.claude.com/docs/en/permissions). Treat this
# hook as a speed bump against the destructive command a worker reaches for by
# habit, not as a boundary. A worker that means to get past it can.
#
# It is also the *only* mechanical guard a worker session has. The `permissions
# .deny` rules in this repo's `.claude/settings.json` are a second layer for
# shepherd's own session, and Claude Code evaluates those with a shell-aware
# parser rather than a grep — but they are project settings and do not travel
# to a worker running in another repo. Give a project its own deny list at
# onboarding where its workers warrant one.
#
# It costs something, too: the raw command string is what gets matched, so a
# worker cannot run any Bash command that merely *mentions* a blocked pattern —
# writing about `git push --force` in a heredoc blocks the heredoc. That is
# fail-closed and deliberate. Route such text through a file edit instead.
# `scripts/tests/test-guardrail.sh` is the probe; it keeps its fixtures in the
# file for exactly this reason.

[ -n "${SHEPHERD_TASK_ID:-}" ] || exit 0

INPUT=$(cat)
# jq is not guaranteed on worker machines (WSL); python3 is. If even that fails,
# match against the raw JSON envelope: spaces and letters survive JSON escaping,
# so the patterns still hit and the failure mode stays fail-closed, not
# fail-open. Whitespace does not survive it, which is what the decoding is for.
COMMAND=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null) || {
  # The raw JSON carries the command's whitespace as the two-character escapes
  # \t and \n, which the normalisation below never sees. Undecoded they cut
  # both ways: a tab-separated destructive command slips the fallback entirely,
  # and two commands joined by a newline read as one and block on a flag that
  # belongs to neither. Decode the whitespace escapes here, so both paths hand
  # normalisation the same real characters.
  #
  # Escaped backslashes come out first and go back last. A literal backslash
  # arrives as \\, and reading the second one together with a following `t`
  # would turn the two-character text \t into a tab that the worker never
  # typed. \001 is the parking space: JSON writes a real control byte as
  # a backslash-u escape, so one cannot reach here inside the envelope.
  COMMAND=$INPUT
  COMMAND=${COMMAND//\\\\/$'\001'}
  COMMAND=${COMMAND//\\t/$'\t'}
  COMMAND=${COMMAND//\\n/$'\n'}
  COMMAND=${COMMAND//\\r/ }
  COMMAND=${COMMAND//$'\001'/\\}
}

[ -z "$COMMAND" ] && exit 0

# --- normalise before matching ----------------------------------------------
# Every pattern below anchors on the sequence `git <subcommand>`. Two things sit
# between the two in real use and used to slip all of them: any whitespace, and
# git's global options. `git -C <dir>` is the house style in this very repo, and
# a worker in a clone works inside a git worktree — the situation that produces
# it most naturally.

# Whitespace first. A line continuation joins its two lines; a tab is a
# separator to the shell and to git alike. A newline becomes `;`, never a space:
# it separates two commands exactly like `;` `|` and `&` do, and the `[^|;&]*`
# guards below depend on that. Collapsing it to a space would splice unrelated
# commands together and block on a flag that belongs to neither.
COMMAND=${COMMAND//$'\\\n'/ }
COMMAND=${COMMAND//$'\t'/ }
COMMAND=${COMMAND//$'\n'/;}

# Then the global options: `git -C <dir> push …`, `git -c k=v push …`,
# `git --git-dir=… push …`, `git --no-optional-locks push …` → `git push …`.
# Strip them leftmost-first, one per pass. Rule A takes an option that consumes
# a *separate* argument and removes both tokens; rule B takes any other option.
# A must run before B in each pass, or B would eat `-C` alone and leave the
# directory standing where the subcommand belongs — which reads as no match at
# all. Every pass removes at least one token, so the loop terminates.
#
# Only the options whose value is a separate argument need naming. Git rejects
# the attached forms (`git -C/repo` → "unknown option"), so the space is
# guaranteed; the `--opt=value` forms are single tokens and rule B handles them.
GIT_ARG_OPTS='-c|-C|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix|--attr-source|--config-env'
while :; do
  NEXT=$(printf '%s' "$COMMAND" | sed -E "s/(^|[^[:alnum:]_-])git +($GIT_ARG_OPTS) +[^ ]+ +/\1git /g")
  if [ "$NEXT" != "$COMMAND" ]; then COMMAND=$NEXT; continue; fi
  NEXT=$(printf '%s' "$COMMAND" | sed -E 's/(^|[^[:alnum:]_-])git +-[^ ]+ +/\1git /g')
  [ "$NEXT" = "$COMMAND" ] && break
  COMMAND=$NEXT
done

# Protected integration branches; extend per project at onboarding if needed.
PROTECTED='(main|master|dev|develop)'

# `git` has to be a whole word. Every pattern below anchors on the sequence
# `git <subcommand>`, and the three letters sit inside ordinary words: without
# this guard `legit push --force` and `mygit branch -D b` block on shepherd's
# git rules, and a program called `deploy-git` cannot use its own subcommands
# at all. The boundary is the one normalisation already uses above — an
# alphanumeric, `_` or `-` before those letters means another word, while `^`,
# a space or the `/` of `/usr/bin/git` means a real invocation. Use GIT in every
# pattern, so a tenth pattern cannot be added without the guard.
GIT='(^|[^[:alnum:]_-])git'

block() {
  echo "BLOCKED by shepherd guardrail: '$1'. Destructive git is escalation-only. Do not retry or work around this — pause and end your message with: SHEPHERD: blocked — need approval for: $1" >&2
  exit 2
}

# Force push (any remote/refspec), incl. --force-with-lease and +refspec form
echo "$COMMAND" | grep -qE "${GIT} +push +[^|;&]*(--force|-f\b|--force-with-lease)" && block "force push"
echo "$COMMAND" | grep -qE "${GIT} +push +[^|;&]* \+[^ ]" && block "forced refspec push"

# Push to / deletion of protected branches ([ /:] catches origin/dev and HEAD:dev forms)
echo "$COMMAND" | grep -qE "${GIT} +push +[^|;&]*[ /:]${PROTECTED}( |\$|:)" && block "push touching a protected branch"
echo "$COMMAND" | grep -qE "${GIT} +push +[^|;&]*(--delete| :[a-zA-Z0-9_/-]+)" && block "remote branch deletion"

# History / worktree destruction
echo "$COMMAND" | grep -qE "${GIT} +reset +[^|;&]*--hard" && block "git reset --hard"
echo "$COMMAND" | grep -qE "${GIT} +clean +[^|;&]*-[a-zA-Z]*f" && block "git clean -f"
echo "$COMMAND" | grep -qE "${GIT} +branch +[^|;&]*-D\b" && block "git branch -D"
echo "$COMMAND" | grep -qE "${GIT} +(checkout|restore) +\.( |\$)" && block "discard working tree"
echo "$COMMAND" | grep -qE "${GIT} +stash +(drop|clear)" && block "git stash drop/clear"

exit 0
