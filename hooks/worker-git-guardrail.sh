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
# It is also the *only* mechanical guard a BUILD worker session has. The
# `permissions.deny` rules in this repo's `.claude/settings.json` are a second
# layer for shepherd's own session, and Claude Code evaluates those with a
# shell-aware parser rather than a grep — but they are project settings and do
# not travel to a worker running in another repo. Give a project its own deny
# list at onboarding where its workers warrant one. A REPLY worker (the
# reply-mode block below, gated on SHEPHERD_WORKER_KIND=reply) gets a second
# layer that does travel: hooks/reply-permissions.json, loaded on its launch
# line with `--settings` (adapter R3).
#
# It costs something, too: the raw command string is what gets matched, so a
# worker cannot run any Bash command that merely *mentions* a blocked pattern —
# writing about `git push --force` in a heredoc blocks the heredoc. That is
# fail-closed and deliberate. Route such text through a file edit instead.
# `tests/test-guardrail.sh` is the probe; it keeps its fixtures in the
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

# `invocations` cuts a segment on \001, and on THIS path a real one can arrive:
# the note above about a control byte being unreachable is the raw-envelope
# fallback's, where \001 is the parking space - `json.load` decodes a
# backslash-u escape in the worker's own command into the byte itself. Fold it
# to a space here, as normalisation folds every other separator, so the marker is the loop's
# alone. It only ever manufactured extra fragments, each still judged on its
# own arguments, so nothing was fail-open; the assumption was simply wrong.
COMMAND=${COMMAND//$'\001'/ }

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

# invocations <segment> <anchor-regex> — the arguments of every invocation the
# anchor matches in the segment, one per line and in command order, each cut
# where the next begins. Every matcher below that reads flags OFF a match
# loops over these, so the FIRST destructive invocation decides. Splitting a
# command at `|;&` is not splitting it at invocations: a `$(…)`, a `#` comment
# or a `--` puts two `git restore` (or two `gh api`, two `curl`) in one
# segment, and a greedy `.*` from the segment start reaches the LAST one's
# flags - so a benign `--staged .`, `-X GET` or graphql query anywhere in the
# segment excused a bare `.`, a `-X DELETE` or a field write beside it, in
# either order (measured against this hook 2026-09-08; T-0223). Presence
# matchers need none of this: any match already blocks.
invocations() {
  local cut=$'\001'
  printf '%s\n' "$1" | sed -E "s/$2/$cut/g" | tr "$cut" '\n' | sed 1d
}

# args_have <args> <extended-regex> — printf, never echo: an invocation's
# arguments are a FRAGMENT that can begin with a flag, and bash's echo eats a
# leading -n, -e or -E (`curl -n …`, `curl -e ref …`, `curl -E cert.pem …`),
# handing the matcher a different string than the worker typed.
args_have() { printf '%s\n' "$1" | grep -qE -- "$2"; }

# --- reply mode -------------------------------------------------------------
# SHEPHERD_WORKER_KIND=reply marks a read-only reply worker (a `kind: reply`
# card; docs/specs/2026-09-07-linear-conversation-design.md §2). Its lane is a
# detached worktree nothing lands from, so the only thing left to guard is
# EGRESS: a push, a commit that a push could follow, a deploy, or a post to
# GitHub — the worker's one voice is shepherd-reply, and every outward word is
# shepherd's. These refuse outright and tell the worker what to do instead;
# there is no approval to ask for. The build rules below still run after them.
# Same speed-bump caveat as everything in this file: `wrangler` matches as a
# command word wherever it sits (npx, pnpm dlx, bunx, a pinned wrangler@4),
# and so does a heredoc that merely mentions it.
if [ "${SHEPHERD_WORKER_KIND:-}" = reply ]; then
  rblock() {
    echo "BLOCKED by shepherd guardrail: 'reply: $1'. A reply worker changes nothing and sends nothing: no commit, no push, no deploy, no post. Answer from what you read; a change the question needs goes in Next step, never in git." >&2
    exit 2
  }
  W='(^|[^[:alnum:]_-])'
  echo "$COMMAND" | grep -qE "${GIT} +push\b" && rblock "git push"
  echo "$COMMAND" | grep -qE "${GIT} +commit\b" && rblock "git commit"
  for v in merge close create edit review comment; do
    echo "$COMMAND" | grep -qE "${W}gh +pr +$v\b" && rblock "gh pr $v"
  done
  echo "$COMMAND" | grep -qE "${W}gh +issue +comment\b" && rblock "gh issue comment"
  echo "$COMMAND" | grep -qE "${W}gh +release\b" && rblock "gh release"
  echo "$COMMAND" | grep -qE "${W}gh +workflow +run\b" && rblock "gh workflow run"
  # The rest is judged per command segment, because a reader's whole job is
  # grepping: `grep -rn wrangler src/` must pass while `wrangler deploy` and
  # `out=$(wrangler deploy)` must not, and a `gh api -X GET` in one segment
  # must not excuse a `-X DELETE` in the next - nor, within a segment, one
  # beside it (`invocations`). CMD anchors a program to command position:
  # segment start, an opening `$(` or `(`, env assignments, `sudo`/`env`/`time`
  # wrappers, or a package runner.
  CMD='^ *([A-Za-z_][A-Za-z0-9_]*=)?(\$\(|\()? *([A-Za-z_][A-Za-z0-9_]*=[^ ]* +)*((sudo|env|time|nohup) +)*'
  RUNNER='((npx|bunx) +|(pnpm|yarn) +dlx +|yarn +)?'
  while IFS= read -r SEG; do
    # `( |$|@)`, not `\b`: `wrangler.jsonc` is a file a reader opens, `wrangler@4`
    # is the pinned invocation.
    echo "$SEG" | grep -qE "${CMD}${RUNNER}wrangler( |\$|@)" && rblock "wrangler"
    echo "$SEG" | grep -qE "${CMD}(npm|pnpm|yarn|bun) +(run +)?deploy\b" && rblock "deploy script"
    # gh api writes: an explicit method other than GET (pflag also takes the
    # attached `-XPOST`), or a field/body flag, which makes gh POST without
    # one - except `gh api graphql -f query=…`, the documented way to run a
    # read-only query, unless the query is a mutation. Each invocation's own
    # arguments: the exemptions must not reach a neighbour's.
    while IFS= read -r ARGS; do
      if args_have "$ARGS" '(-X *|--method[ =])' \
         && ! args_have "$ARGS" '(-X *|--method[ =])GET\b'; then
        rblock "gh api write"
      fi
      if args_have "$ARGS" '(^| )(-f|-F|--field|--raw-field|--input)( |=)' \
         && ! { args_have "$ARGS" '^graphql\b' && ! args_have "$ARGS" 'mutation'; }; then
        rblock "gh api write"
      fi
    done < <(invocations "$SEG" "${W}gh +api +")
    # curl writes: an explicit method other than GET, or a body. Gated on a
    # curl in command position, as before; then every curl in the segment is
    # judged on its own arguments.
    if echo "$SEG" | grep -qE "${CMD}curl "; then
      while IFS= read -r ARGS; do
        if args_have "$ARGS" '(-X *|--request[ =])' \
           && ! args_have "$ARGS" '(-X *|--request[ =])GET\b'; then
          rblock "curl write"
        fi
        args_have "$ARGS" '(^| )(-d|--data|--data-raw|--data-binary|--data-urlencode|--json|-F|--form|-T|--upload-file)( |=)' && rblock "curl write"
      done < <(invocations "$SEG" "${W}curl +")
    fi
  done < <(printf '%s\n' "$COMMAND" | tr '|;&' '\n\n\n')
fi

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
# Whole-tree discards. A bare `.` (or `./`, or the `:/` root pathspec) as a
# pathspec after checkout throws the working tree away, `--` or not, HEAD or
# not; after restore it does the same unless the only flag is --staged/-S,
# which merely unstages and is recoverable. Per-path forms are ordinary work
# and stay allowed (T-0214). A `)` ends the pathspec too: inside `$(…)` the
# `.` is followed by the substitution's close, not a space (`out=$(git
# checkout .)` and `$(git restore .)` were both allowed on the same day fix
# round 2 closed the `;&|` forms of the identical hole; measured 2026-09-08).
TREE='(\.|\./|:/)( |$|\))'
# BOTH arms run per command segment, and they have to agree on what `$` means.
# `( |$)` inside a segment is end-of-segment; matched against the whole command
# it is end-of-COMMAND, so a discard followed directly by a separator — no
# space between the `.` and the `;`, `&&`, `|` or trailing `&` — satisfied
# neither alternative and fell through to allowed, in every one of those four
# forms and with an explicit `HEAD --` prefix too (measured against this hook
# 2026-09-02). The spaced forms blocked, which is what made the hole quiet.
# restore had already been moved here for its own reason: a command can hold
# more than one `git restore`, and a single command-wide sed capture (greedy
# `.*`) always returns the LAST restore's arguments — so a destructive
# `restore .` followed by a benign `restore --staged .` read the second
# invocation's flags and fell through. One loop now serves both, so a third
# subcommand cannot be added against the whole command by mistake. Use process
# substitution, not a pipe, so `block`'s exit 2 propagates out of the loop
# instead of only exiting a subshell. Within a segment, restore is judged per
# INVOCATION (`invocations` above): the per-segment sed had the same greedy
# `.*`, one level down.
while IFS= read -r SEG; do
  echo "$SEG" | grep -qE "${GIT} +checkout +([^|;&]* )?${TREE}" && block "discard working tree"
  while IFS= read -r RESTORE_ARGS; do
    args_have "$RESTORE_ARGS" "(^| )${TREE}" || continue
    if args_have "$RESTORE_ARGS" '(^| )(--worktree|-[a-zA-Z]*W[a-zA-Z]*)( |$)' \
       || ! args_have "$RESTORE_ARGS" '(^| )(--staged|-[a-zA-Z]*S[a-zA-Z]*)( |$)'; then
      block "discard working tree"
    fi
  done < <(invocations "$SEG" "${GIT} +restore +")
done < <(printf '%s\n' "$COMMAND" | tr '|;&' '\n\n\n')
echo "$COMMAND" | grep -qE "${GIT} +stash +(drop|clear)" && block "git stash drop/clear"

exit 0
