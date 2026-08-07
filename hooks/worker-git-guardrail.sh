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

[ -n "${SHEPHERD_TASK_ID:-}" ] || exit 0

INPUT=$(cat)
# jq is not guaranteed on worker machines (WSL); python3 is. If even that fails,
# match against the raw JSON — spaces/letters survive JSON escaping, so patterns
# still hit and the failure mode stays fail-closed, not fail-open.
COMMAND=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null) || COMMAND="$INPUT"

[ -z "$COMMAND" ] && exit 0

# Protected integration branches; extend per project at onboarding if needed.
PROTECTED='(main|master|dev|develop)'

block() {
  echo "BLOCKED by shepherd guardrail: '$1'. Destructive git is escalation-only. Do not retry or work around this — pause and end your message with: SHEPHERD: blocked — need approval for: $1" >&2
  exit 2
}

# Force push (any remote/refspec), incl. --force-with-lease and +refspec form
echo "$COMMAND" | grep -qE 'git +push +[^|;&]*(--force|-f\b|--force-with-lease)' && block "force push"
echo "$COMMAND" | grep -qE 'git +push +[^|;&]* \+[^ ]' && block "forced refspec push"

# Push to / deletion of protected branches ([ /:] catches origin/dev and HEAD:dev forms)
echo "$COMMAND" | grep -qE "git +push +[^|;&]*[ /:]${PROTECTED}( |\$|:)" && block "push touching a protected branch"
echo "$COMMAND" | grep -qE 'git +push +[^|;&]*(--delete| :[a-zA-Z0-9_/-]+)' && block "remote branch deletion"

# History / worktree destruction
echo "$COMMAND" | grep -qE 'git +reset +[^|;&]*--hard' && block "git reset --hard"
echo "$COMMAND" | grep -qE 'git +clean +[^|;&]*-[a-zA-Z]*f' && block "git clean -f"
echo "$COMMAND" | grep -qE 'git +branch +[^|;&]*-D\b' && block "git branch -D"
echo "$COMMAND" | grep -qE 'git +(checkout|restore) +\.( |$)' && block "discard working tree"
echo "$COMMAND" | grep -qE 'git +stash +(drop|clear)' && block "git stash drop/clear"

exit 0
