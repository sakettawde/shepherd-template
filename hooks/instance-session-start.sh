#!/usr/bin/env bash
# SessionStart hook, instance side. Two jobs, both gated on the session being
# a shepherd INSTANCE ($CLAUDE_PROJECT_DIR/.shepherd/instance.env):
#
#   1. Keep the generated manual copy in step with the installed plugin. It
#      writes ONLY in a base checkout on main. Inside a shepherd~N worktree
#      lane it writes nothing — a generated diff on a task branch would land in
#      the worker's commit and pollute the merge — and says so instead.
#   2. Inject a handful of facts as additionalContext: plugin version, resolved
#      root, manual state, SHEPHERD_ID. Facts, never instructions; the standing
#      rules live in the manual the session already imports. The plugin root is
#      among them because ${CLAUDE_PLUGIN_ROOT} is NOT substituted in a
#      skills/*/references/ file and expands to EMPTY in a Bash command
#      (measured 2026-09-10, Claude Code 2.1.267) — so a literal placeholder
#      read from a reference file needs this fact, and a shell command needs
#      `shepherd-paths` instead. Kept under ~100
#      tokens (the cap is 10,000 characters:
#      https://code.claude.com/docs/en/hooks#add-context-for-claude, 2026-09-10).
#
# The hook fires before CLAUDE.md and its @imports are read, so the same session
# reads what this hook just wrote — measured 2026-09-10 on Claude Code 2.1.267:
# SessionStart at t=…185.787, CLAUDE.md InstructionsLoaded at .859, the imported
# file at .860 (load_reason: include), and the model reported the new content.
#
# Exit 0 always. A SessionStart hook that fails must never block a session.
set -u

proj=${CLAUDE_PROJECT_DIR:-}
[ -n "$proj" ] || exit 0
[ -f "$proj/.shepherd/instance.env" ] || exit 0

plugin_root=${CLAUDE_PLUGIN_ROOT:-}
if [ -z "$plugin_root" ]; then
  plugin_root=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 0
fi
manual_cmd="$plugin_root/bin/shepherd-manual"

version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$plugin_root/.claude-plugin/plugin.json" 2>/dev/null | head -1)
[ -n "$version" ] || version=unknown

# Base checkout or worktree lane? A lane carries the committed instance.env too,
# so the marker cannot tell them apart; git can.
gd=$(git -C "$proj" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)
gc=$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
in_lane=0
[ -n "$gd" ] && [ -n "$gc" ] && [ "$gd" != "$gc" ] && in_lane=1
branch=$(git -C "$proj" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

root=${gc%/.git}
[ -n "$root" ] || root=$proj

state=unknown
if [ -x "$manual_cmd" ]; then
  if [ "$in_lane" = 0 ] && [ "$branch" = main ]; then
    state=$("$manual_cmd" sync --dir "$proj" 2>/dev/null) || state=$("$manual_cmd" check --dir "$proj" 2>/dev/null) || state=unknown
  else
    state=$("$manual_cmd" check --dir "$proj" 2>/dev/null) || state=unknown
  fi
fi

line="shepherd plugin v$version at $plugin_root | instance root $root | SHEPHERD_ID ${SHEPHERD_ID:-unset} | manual $state"
if [ "$state" = lane-stale ]; then
  line="$line
This lane carries .claude/shepherd-manual.md as committed on its branch; the installed plugin ships v$version. The base checkout at $root holds the current copy. The file is generated and is not edited here."
elif [ "$state" = refreshed ]; then
  line="$line
.claude/shepherd-manual.md was rewritten this session and is uncommitted."
fi

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' \
  "$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
exit 0
