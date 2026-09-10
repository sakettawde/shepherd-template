#!/usr/bin/env bash
# The plugin surface: the two manifests, the SHEPHERD_ROOT ladder, shepherd-paths,
# shepherd-manual, the instance SessionStart hook, the status monitor, and the two
# text rules that only hold if something checks them (T-0267).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
. "$HERE/harness.sh"
echo "test-plugin:"

# --- the manifests ----------------------------------------------------------
PJ="$ROOT/.claude-plugin/plugin.json"
MJ="$ROOT/.claude-plugin/marketplace.json"
assert_file "plugin.json is at .claude-plugin/plugin.json" "$PJ"
assert_file "marketplace.json is beside it" "$MJ"
assert_ok "plugin.json is valid JSON" python3 -c "import json;json.load(open('$PJ'))"
assert_ok "marketplace.json is valid JSON" python3 -c "import json;json.load(open('$MJ'))"
assert_eq "the plugin is named shepherd" \
  "$(python3 -c "import json;print(json.load(open('$PJ'))['name'])")" "shepherd"
assert_eq "the marketplace is named shepherd-plugins" \
  "$(python3 -c "import json;print(json.load(open('$MJ'))['name'])")" "shepherd-plugins"
assert_eq "it lists exactly one plugin" \
  "$(python3 -c "import json;print(len(json.load(open('$MJ'))['plugins']))")" "1"
# "source": "./" makes the repository root double as the plugin root. Measured
# 2026-09-10: `claude plugin validate --strict` accepts it on Claude Code 2.1.267.
assert_eq "its source is the repository root" \
  "$(python3 -c "import json;print(json.load(open('$MJ'))['plugins'][0]['source'])")" "./"
# An explicit version is the update gate: "users only receive updates when you
# bump this field" (https://code.claude.com/docs/en/plugins-reference#version-management,
# read 2026-09-10). `claude plugin tag` also refuses unless plugin.json and the
# marketplace entry AGREE on it, so a drift here blocks the release.
assert_ok "plugin.json carries an explicit semver" \
  python3 -c "
import json,re,sys
v=json.load(open('$PJ')).get('version','')
sys.exit(0 if re.fullmatch(r'\d+\.\d+\.\d+', v) else 1)"
assert_ok "and the marketplace entry carries the same version" \
  python3 -c "
import json,sys
a=json.load(open('$PJ'))['version']; b=json.load(open('$MJ'))['plugins'][0].get('version')
sys.exit(0 if a==b else 1)"
assert_ok "CHANGELOG names the manifest version" \
  grep -qF "$(python3 -c "import json;print(json.load(open('$PJ'))['version'])")" "$ROOT/CHANGELOG.md"
# Only plugin.json belongs inside .claude-plugin/; every component sits at the
# plugin root (https://code.claude.com/docs/en/plugins-reference#plugin-directory-structure).
for d in skills hooks bin lib monitors manual templates docs tests; do
  assert_ok "$d/ is at the plugin root" test -d "$ROOT/$d"
  assert_ok "…and not inside .claude-plugin/" test ! -e "$ROOT/.claude-plugin/$d"
done

# --- no machine paths, no bare skill invocations ----------------------------
# Both rules exist because the plugin is distributable: a hard-coded home
# directory is unusable by anyone else, and an un-namespaced skill name does not resolve for a
# plugin skill that declares no `name:` (measured 2026-09-10: `/ping` answered
# `Unknown command`, `/shepherd:ping` ran). Historical records are in scope too —
# an adopter reads them.
TEXT_DIRS=("$ROOT/manual" "$ROOT/skills" "$ROOT/templates" "$ROOT/docs" "$ROOT/bin"
           "$ROOT/hooks" "$ROOT/lib" "$ROOT/tests" "$ROOT/README.md" "$ROOT/CHANGELOG.md")
homes=$(grep -rn '/home/[a-z]' "${TEXT_DIRS[@]}" 2>/dev/null | grep -v '^Binary' || true)
assert_eq "no hard-coded home directory anywhere in plugin text" "$(printf '%s' "$homes" | grep -c . )" "0"
[ -n "$homes" ] && printf '       %s\n' "$homes" | head -5
bare=$(grep -rnoE '(^|[^:/[:alnum:]_-])/(wake|triage|dispatch|monitor|retro|onboard|init|herdr-adapter)([^:[:alnum:]_-]|$)' \
        "${TEXT_DIRS[@]}" 2>/dev/null || true)
assert_eq "no bare skill invocation anywhere in plugin text" "$(printf '%s' "$bare" | grep -c . )" "0"
[ -n "$bare" ] && printf '       %s\n' "$bare" | head -5
# ${CLAUDE_PLUGIN_ROOT} expands to the EMPTY STRING in the Bash tool (measured
# 2026-09-10), so a fenced shell block that used it would build a wrong absolute
# path with no error. shepherd-paths is the resolver those blocks must call.
shellsubst=$(python3 - "$ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
bad = []
for p in list((root/"manual").rglob("*.md")) + list((root/"skills").rglob("*.md")):
    text = p.read_text(encoding="utf-8", errors="replace")
    for block in re.findall(r"^```(?:bash|sh|shell)\n(.*?)^```", text, re.S | re.M):
        if "${CLAUDE_PLUGIN_ROOT}" in block:
            bad.append(str(p.relative_to(root)))
print("\n".join(sorted(set(bad))))
PY
)
assert_eq "no shell block substitutes \${CLAUDE_PLUGIN_ROOT}" "$(printf '%s' "$shellsubst" | grep -c . )" "0"
[ -n "$shellsubst" ] && printf '       %s\n' "$shellsubst"
# A plugin skill must not declare `name:`: with one set the bare /<name> ALSO
# invokes it (measured 2026-09-10), which is the alias the rule above forbids.
for f in "$ROOT"/skills/*/SKILL.md; do
  assert_fail "$(basename "$(dirname "$f")") declares no name: field" grep -q '^name:' "$f"
  assert_ok "$(basename "$(dirname "$f")") declares a description" grep -q '^description:' "$f"
done
assert_ok "herdr-adapter is model-invoked only" \
  grep -q '^user-invocable: false' "$ROOT/skills/herdr-adapter/SKILL.md"

# --- monitors.json ----------------------------------------------------------
MON="$ROOT/monitors/monitors.json"
assert_file "monitors.json is at monitors/monitors.json" "$MON"
assert_ok "it is valid JSON" python3 -c "import json;json.load(open('$MON'))"
assert_eq "one monitor, named status-claims" \
  "$(python3 -c "import json;m=json.load(open('$MON'));print(len(m), m[0]['name'])")" "1 status-claims"
# `when: always` would start the monitor in EVERY session the plugin is enabled
# in — every worker and every unrelated session on the machine. Tied to the wake
# skill it starts only in a shepherd instance session.
assert_eq "it starts on the wake skill, never always" \
  "$(python3 -c "import json;print(json.load(open('$MON'))[0]['when'])")" "on-skill-invoke:wake"
assert_ok "its command is the plugin's own shepherd-watch monitor" \
  grep -q 'bin/shepherd-watch monitor' "$MON"
# The trigger does not start the monitor on 2.1.267 (measured 2026-09-10), so
# wake must not assume the monitor is there: it says to arm the primary by hand.
assert_ok "wake step 1 expects the monitor to be absent and arms by hand" \
  grep -q 'arm the primary by hand' "$ROOT/skills/wake/SKILL.md"
assert_ok "…and dates the measurement behind that" \
  grep -q '2026-09-10 on Claude Code 2.1.267' "$ROOT/skills/wake/SKILL.md"
assert_ok "the CHANGELOG records it as a known limitation" \
  grep -qi 'monitor does not start yet' "$ROOT/CHANGELOG.md"
assert_ok "the wake handler filters by owner before anything else" \
  grep -qi 'Ownership gate first' "$ROOT/skills/monitor/SKILL.md"
assert_ok "and the monitor line is named as a wake source there" \
  grep -q 'status-claims' "$ROOT/skills/monitor/SKILL.md"

# --- shepherd-paths ---------------------------------------------------------
P="$ROOT/bin/shepherd-paths"
assert_eq "shepherd-paths with no argument prints the plugin root" "$(bash "$P")" "$ROOT"
assert_eq "…and resolves a path inside it" "$(bash "$P" hooks/reply-permissions.json)" \
  "$ROOT/hooks/reply-permissions.json"
assert_fail "it refuses a path that escapes the plugin" bash "$P" ../shepherd/CLAUDE.md
assert_fail "it refuses an absolute path" bash "$P" /etc/passwd
assert_fail "it refuses a path that is not there" bash "$P" nope/nope.md
assert_eq "the escape is exit 2, not a not-found 1" \
  "$(bash "$P" ../shepherd/CLAUDE.md >/dev/null 2>&1; echo $?)" "2"

# --- the SHEPHERD_ROOT ladder ----------------------------------------------
# Three rungs and no default. The hard-coded default that used to sit in
# lib/shepherd-common.sh made the framework unusable on a second machine and by
# any other operator, so the refusal is the feature.
LADDER=$(mktemp -d); trap 'rm -rf "$LADDER"' EXIT
probe() {  # runs in a subshell so the exit inside the sourced lib is contained
  ( cd "$1" && shift && env "$@" bash -c \
    '. "'"$ROOT"'/lib/shepherd-common.sh" >/dev/null 2>&1 || exit $?; printf "%s\n" "$SHEPHERD_ROOT"' )
}
# rung 1 — the environment wins, and it is what the harness and shepherd-drill use
seed_instance_env "$LADDER/env-root"
assert_eq "rung 1: \$SHEPHERD_ROOT is taken as given" \
  "$(probe / SHEPHERD_ROOT="$LADDER/env-root")" "$LADDER/env-root"
assert_eq "rung 1: a trailing slash is trimmed" \
  "$(probe / SHEPHERD_ROOT="$LADDER/env-root/")" "$LADDER/env-root"
# rung 2 — git. --git-common-dir resolves a worktree LANE to its base checkout,
# which is where the one ledger lives (measured 2026-09-10, git 2.43.0).
base="$LADDER/base"
mkdir -p "$base" && git -C "$base" init -q && git -C "$base" config user.email t@t \
  && git -C "$base" config user.name t
seed_instance_env "$base"
( cd "$base" && git add -A >/dev/null 2>&1 && git commit -qm seed >/dev/null 2>&1 )
assert_eq "rung 2: a base checkout resolves to itself" \
  "$(probe "$base" SHEPHERD_ROOT=)" "$base"
git -C "$base" worktree add -q "$LADDER/lane" -b lane-1 2>/dev/null
assert_eq "rung 2: a worktree lane resolves to the BASE checkout, not the lane" \
  "$(probe "$LADDER/lane" SHEPHERD_ROOT=)" "$base"
assert_eq "rung 2: a subdirectory of the checkout resolves to the checkout" \
  "$(mkdir -p "$base/ledger/tasks"; probe "$base/ledger/tasks" SHEPHERD_ROOT=)" "$base"
# rung 3 — nothing. Refuse, loudly, rather than write a ledger somewhere else.
outside="$LADDER/not-a-repo"; mkdir -p "$outside"
assert_eq "rung 3: outside a git repository it refuses with exit 2" \
  "$(probe "$outside" SHEPHERD_ROOT= >/dev/null 2>&1; echo $?)" "2"
noenv="$LADDER/no-marker"
mkdir -p "$noenv" && git -C "$noenv" init -q
assert_eq "a git repository with no .shepherd/instance.env is refused too" \
  "$(probe "$noenv" SHEPHERD_ROOT= >/dev/null 2>&1; echo $?)" "2"
assert_ok "…and the refusal names the file and the fix" \
  bash -c "cd '$noenv' && SHEPHERD_ROOT= bash -c '. \"$ROOT/lib/shepherd-common.sh\"' 2>&1 | grep -q 'instance.env'"
# The operator facts reach every command that resolves a root.
assert_eq "instance.env is sourced, so the operator facts are readable" \
  "$( ( cd / && SHEPHERD_ROOT="$LADDER/env-root" bash -c \
      '. "'"$ROOT"'/lib/shepherd-common.sh"; printf "%s\n" "$SHEPHERD_WORKER_CAP"' ) )" "6"
# A gitignored local.env overrides the machine-specific values on a second machine.
printf 'SHEPHERD_CODE_DIR=/other/machine\n' > "$LADDER/env-root/.shepherd/local.env"
assert_eq "local.env overrides the committed value" \
  "$( ( cd / && SHEPHERD_ROOT="$LADDER/env-root" bash -c \
      '. "'"$ROOT"'/lib/shepherd-common.sh"; printf "%s\n" "$SHEPHERD_CODE_DIR"' ) )" "/other/machine"
# Worker-side commands must NOT need a root: they run in arbitrary project
# directories and get their two variables from the launch line.
assert_fail "shepherd-status does not source the root resolver" \
  grep -q 'shepherd-common' "$ROOT/bin/shepherd-status"
assert_fail "nor does shepherd-reply" grep -q 'shepherd-common' "$ROOT/bin/shepherd-reply"
for h in "$ROOT"/hooks/worker-*.sh; do
  assert_fail "$(basename "$h") does not source the root resolver" grep -q 'shepherd-common' "$h"
done

# --- shepherd-manual and the instance SessionStart hook ---------------------
# The manual ships in the plugin; an instance carries a GENERATED, COMMITTED copy
# that its thin CLAUDE.md imports. The hook refreshes it in a base checkout and is
# read-only in a worktree lane, where a generated diff would land in the worker's
# commit and pollute the merge.
MANUAL="$ROOT/bin/shepherd-manual"
HOOK="$ROOT/hooks/instance-session-start.sh"
assert_ok "shepherd-manual is executable" test -x "$MANUAL"
assert_ok "the SessionStart hook is executable" test -x "$HOOK"
assert_file "the plugin ships manual/shepherd.md" "$ROOT/manual/shepherd.md"

MT=$(mktemp -d)
inst="$MT/inst"
mkdir -p "$inst" && git -C "$inst" init -q -b main && git -C "$inst" config user.email t@t \
  && git -C "$inst" config user.name t
bash "$ROOT/bin/shepherd-init" seed --dir "$inst" >/dev/null
assert_file "shepherd-init seed writes the thin CLAUDE.md" "$inst/CLAUDE.md"
assert_file "…and .shepherd/instance.env" "$inst/.shepherd/instance.env"
assert_file "…and the permission rules" "$inst/.claude/settings.json"
assert_file "…and the registry index" "$inst/registry/projects.md"
assert_ok "the thin CLAUDE.md imports the generated manual" \
  grep -qx '@.claude/shepherd-manual.md' "$inst/CLAUDE.md"
assert_ok "…and the operator facts" grep -qx '@.shepherd/instance.env' "$inst/CLAUDE.md"
assert_ok "it says the copy is generated and not to be edited" \
  grep -qi 'generated' "$inst/CLAUDE.md"
assert_ok "the seeded .gitignore keeps local.env out of git" \
  grep -qx '.shepherd/local.env' "$inst/.gitignore"

assert_eq "check on a fresh instance says missing" "$(bash "$MANUAL" check --dir "$inst")" "missing"
assert_eq "sync writes it and reports refreshed" "$(bash "$MANUAL" sync --dir "$inst")" "refreshed"
assert_ok "the copy is byte-identical to the plugin's manual" \
  cmp -s "$ROOT/manual/shepherd.md" "$inst/.claude/shepherd-manual.md"
( cd "$inst" && git add -A >/dev/null 2>&1 && git commit -qm seed >/dev/null 2>&1 )
assert_eq "once committed it reads current" "$(bash "$MANUAL" check --dir "$inst")" "current"
printf 'DRIFTED\n' >> "$inst/.claude/shepherd-manual.md"
assert_eq "a hand-edited copy reads stale" "$(bash "$MANUAL" check --dir "$inst")" "stale"
# sync restores the committed bytes, so git goes clean again: `current`, not
# `refreshed`. `refreshed` is reserved for a copy that now differs from HEAD,
# which is the state that owes a commit.
assert_eq "sync repairs it, and a copy equal to HEAD is current" \
  "$(bash "$MANUAL" sync --dir "$inst")" "current"

# The state that matters: the committed copy is BEHIND the installed plugin, as
# it is after every release. sync must then leave the file dirty and say so, so
# wake step 1 commits it.
printf 'OLD-RELEASE\n' > "$inst/.claude/shepherd-manual.md"
( cd "$inst" && git commit -q -am "an older release's manual" >/dev/null 2>&1 )
assert_eq "a committed copy behind the plugin reads stale" "$(bash "$MANUAL" check --dir "$inst")" "stale"
assert_eq "sync brings it forward and reports refreshed" "$(bash "$MANUAL" sync --dir "$inst")" "refreshed"
assert_ok "git sees the refreshed copy as modified, which is what wake commits" \
  bash -c "cd '$inst' && test -n \"\$(git status --porcelain -- .claude/shepherd-manual.md)\""
assert_ok "and the copy now matches the plugin exactly" \
  cmp -s "$ROOT/manual/shepherd.md" "$inst/.claude/shepherd-manual.md"
( cd "$inst" && git commit -q -am "manual synced" >/dev/null 2>&1 )
assert_eq "committing it returns the state to current" "$(bash "$MANUAL" check --dir "$inst")" "current"

# a lane: read-only for this file
git -C "$inst" worktree add -q "$MT/lane" -b task/T-9999 2>/dev/null
assert_eq "a lane whose copy matches reads current" "$(bash "$MANUAL" check --dir "$MT/lane")" "current"
printf 'LANE-DRIFT\n' >> "$MT/lane/.claude/shepherd-manual.md"
( cd "$MT/lane" && git commit -q -am drift >/dev/null 2>&1 )
assert_eq "a lane whose COMMITTED copy differs reads lane-stale" \
  "$(bash "$MANUAL" check --dir "$MT/lane")" "lane-stale"
assert_fail "sync refuses inside a lane" bash "$MANUAL" sync --dir "$MT/lane"
assert_ok "…and the lane's copy is left exactly as committed" \
  grep -q 'LANE-DRIFT' "$MT/lane/.claude/shepherd-manual.md"
assert_eq "a directory with no instance.env is not an instance" \
  "$(bash "$MANUAL" check --dir "$MT")" "not-instance"

# the hook: gated on the marker, silent outside an instance, facts only inside
hookrun() { CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_ROOT="$ROOT" SHEPHERD_ID="${2:-shepherd-1}" \
            bash "$HOOK" 2>/dev/null; }
assert_eq "the hook writes nothing outside an instance" "$(hookrun "$MT")" ""
out=$(hookrun "$inst")
assert_ok "inside a base checkout it emits SessionStart JSON" \
  python3 -c "
import json,sys
d=json.loads('''$out''')
sys.exit(0 if d['hookSpecificOutput']['hookEventName']=='SessionStart' else 1)"
ctx=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')
assert_ok "the injected facts name the plugin version" grep -qE 'shepherd plugin v[0-9]+\.[0-9]+\.[0-9]+' <<<"$ctx"
assert_ok "…the plugin root, for a placeholder read out of a reference file" grep -qF "$ROOT" <<<"$ctx"
assert_ok "…the instance root" grep -qF "$inst" <<<"$ctx"
assert_ok "…the shepherd id as the environment has it" grep -q 'SHEPHERD_ID shepherd-1' <<<"$ctx"
assert_ok "…and the manual's state" grep -qE 'manual (current|refreshed|stale)' <<<"$ctx"
# "at most ~100 tokens of facts": ceil(bytes / 4) is the house approximation.
assert_ok "the injection stays under 100 tokens" \
  test "$(( ( $(printf '%s' "$ctx" | wc -c) + 3 ) / 4 ))" -le 100
# A lane is read-only: the hook must not write, and must say why.
before=$(cat "$MT/lane/.claude/shepherd-manual.md")
lout=$(hookrun "$MT/lane")
assert_eq "the hook leaves a lane's copy untouched" "$(cat "$MT/lane/.claude/shepherd-manual.md")" "$before"
lctx=$(printf '%s' "$lout" | python3 -c 'import json,sys;print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')
assert_ok "a lane-stale lane is told the file is generated and not edited here" \
  grep -qi 'generated and is not edited here' <<<"$lctx"
assert_ok "…and where the current copy lives" grep -qF "$inst" <<<"$lctx"
# Off main the hook must not write either: a generated diff would ride the branch.
git -C "$inst" checkout -q -b side 2>/dev/null
rm -f "$inst/.claude/shepherd-manual.md"
hookrun "$inst" >/dev/null
assert_nofile "the hook does not write on a branch that is not main" "$inst/.claude/shepherd-manual.md"
git -C "$inst" checkout -q main 2>/dev/null
rm -rf "$MT"

# --- the status monitor -----------------------------------------------------
# `shepherd-watch monitor` is what monitors/monitors.json runs. Claude Code
# delivers each stdout line to the session as a notification, so this is the
# primary status watcher: no arming, no anchor to carry, no re-arm on any wake.
# It anchors what is already on disk and prints only NEW wake-worthy records.
MW=$(mktemp -d)
seed_instance_env "$MW"
mkdir -p "$MW/ledger/status"
rec() {  # <task> <json-body>
  printf '{"ts": "2026-09-10T10:00:00+0000", "task": "%s", %s}\n' "$1" "$2" \
    >> "$MW/ledger/status/$1.jsonl"
}
# history: present before the monitor starts, so it must never be reported
rec T-0100 '"event": "claim", "kind": "command", "claim": "done", "message": "old"'
start_monitor() {  # → pid, stdout in $1
  SHEPHERD_ROOT="$MW" SHEPHERD_TEST_HOOKS=1 bash "$ROOT/bin/shepherd-watch" monitor >"$1" 2>&1 &
  echo $!
}
OUT_A="$MW/a.out"; OUT_B="$MW/b.out"
# Two instances over ONE checkout each run their own monitor process. That is by
# design: both see every claim, and the owner filter is the first act of the wake
# handler. Filtering inside the monitor was rejected because a monitor that
# filtered on an unset id would print nothing and lose every wake silently.
pid_a=$(start_monitor "$OUT_A")
pid_b=$(start_monitor "$OUT_B")
sleep 3
assert_eq "the anchor reports nothing for records already on disk" "$(wc -c < "$OUT_A" | tr -d ' ')" "0"

rec T-0201 '"event": "claim", "kind": "command", "claim": "blocked", "message": "need a ruling"'
rec T-0202 '"event": "notification", "kind": "idle_prompt", "message": "waiting"'
rec T-0203 '"event": "claim", "kind": "command", "claim": "working", "message": "checkpoint"'
rec T-0204 '"event": "session_end", "reason": "clear"'
rec T-0205 '"event": "notification", "kind": "permission_prompt", "message": "asking"'
sleep 5
kill "$pid_a" "$pid_b" 2>/dev/null; wait "$pid_a" 2>/dev/null; wait "$pid_b" 2>/dev/null

assert_ok "a terminal claim is reported" grep -q '^T-0201 claim=blocked ' "$OUT_A"
assert_ok "…with the file it landed in" grep -q "file=$MW/ledger/status/T-0201.jsonl" "$OUT_A"
assert_ok "…its ordinal among wake-worthy records" grep -q 'n=1 ' "$OUT_A"
assert_ok "…and its timestamp" grep -q 'ts=2026-09-10T10:00:00+0000' "$OUT_A"
assert_fail "idle_prompt is never a wake" grep -q 'T-0202' "$OUT_A"
assert_fail "a working checkpoint is never a wake" grep -q 'T-0203' "$OUT_A"
assert_ok "a session that ended is a wake" grep -q '^T-0204 event=session_end ' "$OUT_A"
assert_ok "a permission prompt is a wake, with its kind" \
  grep -q '^T-0205 event=notification kind=permission_prompt ' "$OUT_A"
assert_fail "history is still not reported" grep -q 'T-0100' "$OUT_A"
assert_eq "exactly three wakes, not five records" "$(grep -c '^T-0' "$OUT_A")" "3"
# Both instances see the same three: that is what makes the handler-side owner
# filter the only filter, and it costs the non-owner one grep.
assert_eq "the second instance's monitor saw the same three" "$(grep -c '^T-0' "$OUT_B")" "3"
assert_ok "the two monitors agree line for line" \
  bash -c "diff <(grep '^T-0' '$OUT_A' | sort) <(grep '^T-0' '$OUT_B' | sort) >/dev/null"
# One predicate, two readers: the per-task watcher and the monitor must never
# disagree about what a wake is. Two copies of this rule once killed a watcher.
assert_file "the wake set is one shared module" "$ROOT/lib/status_wake.py"
assert_ok "the per-task watcher imports it" grep -q 'from status_wake import' "$ROOT/bin/shepherd-watch"
assert_eq "and defines the predicate nowhere else" \
  "$(grep -c 'def wake_worthy' "$ROOT/bin/shepherd-watch" "$ROOT/lib/status_wake.py" | awk -F: '{s+=$2} END {print s}')" "1"
rm -rf "$MW"

finish
