#!/usr/bin/env bash
# Probe for scripts/context-rollover.sh's rollover/watch path — the sequence that
# resets shepherd's own context and prompts the fresh session back to work.
#
# Why this file exists: on 2026-08-25 the old `inject` subcommand gated on
# `agent_status == idle`, polled for six minutes, and exited having written
# nothing. Measurements in docs/specs/context-rollover-design.md show a shepherd
# pane can NEVER report idle — its watcher shells pin it to `working` through
# the detection manifest's background_shell_working rule (priority 965), which
# outranks the live_prompt_box idle rule (950) even when the prompt box is a
# bare "❯" — and that a bash-mode box, the OTHER failure this path has had,
# DOES report idle. The gate was unreachable in the healthy case and present
# in the failure case.
#
# So what is asserted here is: the gate is the SESSION ID, every exit path
# leaves a log line, and every give-up raises a toast. A herdr stub stands in
# for the real CLI, scripted from files so a case can make the clear land now,
# land late, or never land.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
SCRIPT="$HERE/../context-rollover.sh"

echo "test-rollover:"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is available" "python3 not found — the script and this probe both need it"
  finish
  exit
fi

# MANDATORY: a worker session running this probe inherits its own
# SHEPHERD_ROLLOVER_* and HERDR_* environment. A case that did not override them
# would otherwise poll the live instance's pane or append to the operator's
# real rollover log. Measured hazard, not theoretical — see test-notify.sh.
unset SHEPHERD_ROLLOVER_LOG SHEPHERD_ROLLOVER_SOUND SHEPHERD_TASK_ID

BIN="$SHEPHERD_ROOT/bin"
mkdir -p "$BIN"

# ---------------------------------------------------------------------------
# The herdr stub. Its world lives in files so each case can script a timeline:
#   sid    — the live Claude session id `pane get` reports
#   flip   — now | afterN | never: when the /clear takes effect. `pane get` is
#            what advances it, because that is what the real watchdog polls.
#            When it fires, the new id is persisted, exactly as herdr's own
#            SessionStart-driven report does.
#   status — what `pane get` reports as agent_status
#   box    — what `pane read` renders in the prompt box body
#   stuck  — present when Escape will NOT leave bash mode
#   calls  — every invocation, one per line, for asserting what was sent
# `agent prompt` always answers agent_prompted, exactly as the real CLI did
# when a bash-mode box swallowed the text. That is deliberate: it forces the
# script to verify arrival against the transcript rather than the return value.
# ---------------------------------------------------------------------------
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
S=$HERDR_STUB_DIR
printf '%s\n' "$*" >> "$S/calls"
case "$1 $2" in
  "pane get")
    flip=$(cat "$S/flip" 2>/dev/null || echo never)
    case "$flip" in
      now) printf 'SID-NEW\n' > "$S/sid" ;;
      after*)
        n=${flip#after}
        if [ "$n" -le 0 ]; then printf 'SID-NEW\n' > "$S/sid"
        else printf 'after%s\n' "$((n - 1))" > "$S/flip"; fi ;;
      *) : ;;
    esac
    printf '{"result":{"pane":{"agent_status":"%s","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"%s"}}}}\n' \
      "$(cat "$S/status")" "$(cat "$S/sid")"
    ;;
  "pane read")
    cat "$S/box"
    ;;
  "pane send-keys")
    # Escape leaves bash mode — measured 2026-08-25. A box marked "stuck"
    # ignores it, which is how the refusal path is exercised.
    [ -f "$S/stuck" ] || printf '\xe2\x9d\xaf\n' > "$S/box"
    ;;
  "agent prompt")
    if [ "$4" = "/clear" ]; then
      # Submitted into a bash-mode box it is swallowed and the id never moves.
      grep -q '^!' "$S/box" 2>/dev/null && printf 'never\n' > "$S/flip"
    else
      mkdir -p "$S/projects/proj"
      printf '{"type":"user","message":{"content":"%s"}}\n' "$4" >> "$S/projects/proj/$(cat "$S/sid").jsonl"
    fi
    printf '{"result":{"type":"agent_prompted"}}\n'
    ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN/herdr"

# scene <sid> <status> <box> <flip> — a fresh world for one case. Each scene gets
# its own directory, so a watchdog still detached from an earlier case can never
# write into a later case's assertions.
scene() {
  local dir
  dir=$(mktemp -d "$SHEPHERD_ROOT/stub.XXXXXX")
  mkdir -p "$dir/projects/proj"
  printf '%s\n' "$1" > "$dir/sid"
  printf '%s\n' "$2" > "$dir/status"
  printf '%s\n' "$3" > "$dir/box"
  printf '%s\n' "$4" > "$dir/flip"
  : > "$dir/calls"
  export HERDR_STUB_DIR="$dir"
  LOG="$dir/rollover.log"
  CALLS="$dir/calls"
}

# run <subcommand-and-args...> — the script, with the stub ahead of the real herdr
# and every timing shrunk so the suite stays fast.
run() {
  PATH="$BIN:$PATH" \
  SHEPHERD_ROLLOVER_POLL=1 SHEPHERD_ROLLOVER_CLEAR_TIMEOUT=3 \
  SHEPHERD_ROLLOVER_SETTLE=0 SHEPHERD_ROLLOVER_VERIFY=2 SHEPHERD_ROLLOVER_ATTEMPTS=2 \
  SHEPHERD_ROLLOVER_ESCAPE_SETTLE=0 \
  SHEPHERD_ROLLOVER_HANDOFF="${HANDOFF_OVERRIDE:-0}" \
  SHEPHERD_ROLLOVER_PARENT_TIMEOUT="${PARENT_TIMEOUT_OVERRIDE:-3}" \
  SHEPHERD_ROLLOVER_PROJECTS="${PROJECTS_OVERRIDE:-$HERDR_STUB_DIR/projects}" \
  SHEPHERD_ROLLOVER_LOG="$LOG" \
  bash "$SCRIPT" "$@" --log "$LOG" >/dev/null 2>&1
}

# The recovery line the watchdog types into the fresh session. One word, and a
# word Claude Code resolves deterministically: the repo's own `.claude/skills/`
# entries are user-invocable as `/<name>`, so `/wake` reaches the wake skill
# without the fresh session reading anything first. T-0187 shortened it from a
# sentence of prose; the script now carries it as a default, so the command a
# shepherd turn actually types is `context-rollover.sh rollover` and nothing else.
MSG="/wake"

# === F1: the clear never lands — this is the failure that used to be silent ==
scene SID-OLD working "❯" never
run watch w1:p1 SID-OLD "$MSG"
assert_eq "a clear that never lands exits 3" "$?" "3"
assert_ok "the poll trail is logged"                  grep -q ' POLL '    "$LOG"
assert_ok "the verdict is logged"                     grep -q ' GIVE-UP ' "$LOG"
assert_ok "the give-up names the session it watched"  grep -q 'SID-OLD'   "$LOG"
assert_ok "the give-up raises a toast"    grep -q 'notification show' "$CALLS"
assert_ok "the toast tells the operator what to type" grep -q "$MSG" "$CALLS"
assert_fail "no recovery prompt was sent" grep -q "agent prompt w1:p1 $MSG" "$CALLS"

# === F2: the happy path =====================================================
scene SID-OLD working "❯" now
run watch w1:p1 SID-OLD "$MSG"
assert_eq "a landed clear plus a verified prompt exits 0" "$?" "0"
assert_ok "the clear is logged as confirmed"  grep -q ' CLEAR-CONFIRMED ' "$LOG"
assert_ok "the new session id is logged"      grep -q 'SID-NEW'           "$LOG"
assert_ok "the prompt is logged as sent"      grep -q ' PROMPT-SENT '     "$LOG"
assert_ok "the prompt is logged as verified"  grep -q ' VERIFIED '        "$LOG"
assert_ok "the prompt went to the pane"       grep -q "agent prompt w1:p1 $MSG" "$CALLS"
assert_fail "a success raises no toast"       grep -q 'notification show' "$CALLS"

# === F3: the clear lands late — the gate must not give up early =============
# The old design slept a fixed 30s and hoped. This one polls from t=0 and takes
# the change whenever it arrives.
scene SID-OLD working "❯" after1
run watch w1:p1 SID-OLD "$MSG"
assert_eq "a clear that lands on a later poll still succeeds" "$?" "0"
assert_ok "the earlier poll is logged too" test "$(grep -c ' POLL ' "$LOG")" -ge 2

# === F4: submitted but never arrived ========================================
# Modelled by pointing the transcript search at an empty directory: the
# submission "succeeds" and the verification correctly refuses to believe it.
scene SID-OLD working "❯" now
PROJECTS_OVERRIDE="$SHEPHERD_ROOT/nowhere" run watch w1:p1 SID-OLD "$MSG"
assert_eq "an unverifiable prompt exits 4" "$?" "4"
assert_ok "every attempt is logged"    test "$(grep -c ' PROMPT-SENT ' "$LOG")" -eq 2
assert_ok "the verdict is logged"      grep -q ' GIVE-UP ' "$LOG"
assert_ok "the give-up raises a toast" grep -q 'notification show' "$CALLS"

# === F5: arrival is proven from the transcript, not from herdr's answer ======
# The stub answers agent_prompted unconditionally — as the real CLI did when a
# bash-mode box swallowed a /clear. F2 passing therefore proves the script read
# the transcript; F4 failing proves it did not settle for the return value.
assert_eq "the stub always claims success" \
  "$(PATH="$BIN:$PATH" herdr agent prompt w1:p1 anything | grep -c agent_prompted)" "1"

# === F6: THE FOREGROUND SENDS NO KEYSTROKE ==================================
# The 2026-08-27 root cause, asserted so it cannot come back. The old shape sent
# `pane send-keys <own-pane> Escape` from the foreground, while that foreground
# was running as the shepherd's own Bash tool call. Claude Code reads an Escape
# into its pane as "interrupt the running tool" — and the running tool was this
# script. The pane showed `Bash interrupted`, nothing was armed, and the
# instance sat idle with no watchers for hours. The foreground is read-only now:
# it may call `pane get` and `pane read`, and nothing else.
scene SID-OLD working "!" now
HANDOFF_OVERRIDE=30 run rollover "$MSG" --pane w1:p1
assert_eq "a read-only foreground arms and exits 0" "$?" "0"
assert_ok "arming is logged"          grep -q ' ARM '        "$LOG"
assert_ok "the observed box is logged" grep -q 'box_before=' "$LOG"
assert_ok "the armed watchdog is told which pid to outlive" grep -q 'parent=' "$LOG"
assert_fail "the foreground sends no keystroke" \
  grep -q 'pane send-keys' "$CALLS"
assert_fail "the foreground submits no prompt" \
  grep -q 'agent prompt' "$CALLS"
# Structural, because a future edit that moves either call back into the
# foreground would pass every behavioural case above on a fast machine.
fg=$(sed -n '/^  rollover)/,/^  watch)/p' "$SCRIPT")
assert_fail "the rollover branch carries no send-keys call" \
  grep -q 'send-keys' <<<"$fg"
assert_fail "the rollover branch carries no agent prompt call" \
  grep -q 'agent prompt' <<<"$fg"

# === F6a: the watchdog waits for the foreground pid before touching anything =
# `watch --parent <live pid>` must send nothing while that pid lives, and must
# give up loudly rather than send anyway.
scene SID-OLD working "❯" now
sleep 30 &
LIVE=$!
run watch w1:p1 SID-OLD "$MSG" --parent "$LIVE"
assert_eq "a foreground that never exits gives up with 5" "$?" "5"
kill "$LIVE" 2>/dev/null
assert_ok "the give-up names the pid it waited on" grep -q "$LIVE" "$LOG"
assert_ok "the give-up raises a toast" grep -q 'notification show' "$CALLS"
assert_fail "and it sent no keystroke"  grep -q 'pane send-keys' "$CALLS"
assert_fail "and it submitted no clear" grep -q 'agent prompt w1:p1 /clear' "$CALLS"

# A parent already gone hands over immediately and proceeds.
scene SID-OLD working "❯" now
sleep 0.1 &
DEAD=$!
wait "$DEAD" 2>/dev/null
run watch w1:p1 SID-OLD "$MSG" --parent "$DEAD"
assert_eq "a foreground already gone lets the watchdog run" "$?" "0"
assert_ok "the handover is logged" grep -q ' HANDOFF ' "$LOG"
assert_ok "and only then is Escape sent" grep -q 'pane send-keys w1:p1 Escape' "$CALLS"

# === F6b: the watchdog forces prompt mode, then submits the clear ============
scene SID-OLD working "!" now
run watch w1:p1 SID-OLD "$MSG"
assert_eq "a box that comes clean after Escape recovers" "$?" "0"
assert_ok "Escape is sent by the watchdog" grep -q 'pane send-keys w1:p1 Escape' "$CALLS"
assert_ok "the clear is submitted"         grep -q 'agent prompt w1:p1 /clear'   "$CALLS"
assert_ok "the clear is logged as sent"    grep -q ' CLEAR-SENT '                "$LOG"

# === F6c: a SUGGESTED prompt in the box must not hold the rollover ===========
# Measured live 2026-08-25: a pane whose box read
#   "❯  I need a task description to suggest your next step."
# accepted /clear normally and its session id moved — the suggestion is ghost
# text, and Escape does not dismiss it. A pane read cannot tell a suggestion
# from a human draft (R10 Gotchas), so refusing on either would hold a
# legitimate rollover over nothing. Only bash mode is a real blocker; a genuine
# draft that did break the clear is caught loudly by the session-id gate.
scene SID-OLD working "❯  I need a task description to suggest your next step." now
touch "$HERDR_STUB_DIR/stuck"        # Escape leaves it exactly as it is
run watch w1:p1 SID-OLD "$MSG"
assert_eq "a suggested prompt does not hold the rollover" "$?" "0"
assert_ok "the clear is still submitted" grep -q 'agent prompt w1:p1 /clear' "$CALLS"
assert_ok "and the box state is logged for diagnosis" grep -q 'box=other' "$LOG"

# === F7: a box that will not leave bash mode refuses, and submits nothing ====
scene SID-OLD working "!" now
touch "$HERDR_STUB_DIR/stuck"
run watch w1:p1 SID-OLD "$MSG"
assert_eq "a box stuck in bash mode refuses" "$?" "2"
assert_ok "the refusal is logged"     grep -q ' REFUSED '                 "$LOG"
assert_ok "the refusal toasts"        grep -q 'notification show'         "$CALLS"
assert_fail "no /clear was submitted" grep -q 'agent prompt w1:p1 /clear' "$CALLS"

# === F8: a blocked pane refuses — /clear would answer an open dialog ========
scene SID-OLD blocked "❯" now
run rollover "$MSG" --pane w1:p1
assert_eq "a blocked pane refuses" "$?" "2"
assert_ok "the refusal is logged"     grep -q ' REFUSED '                 "$LOG"
assert_fail "no /clear was submitted" grep -q 'agent prompt w1:p1 /clear' "$CALLS"

# === F9: no session id at all — the herdr claude integration is missing =====
scene "" unknown "❯" never
run rollover "$MSG" --pane w1:p1
assert_eq "a pane with no Claude session refuses" "$?" "2"
assert_ok "the refusal is logged"     grep -q ' REFUSED '                 "$LOG"
assert_fail "no /clear was submitted" grep -q 'agent prompt w1:p1 /clear' "$CALLS"

# === F10: --sound is honoured, and none means none ==========================
scene SID-OLD working "❯" never
run watch w1:p1 SID-OLD "$MSG" --sound none
assert_ok "a silent give-up still toasts"     grep -q 'notification show' "$CALLS"
assert_fail "a silent give-up plays no sound" grep -q -- '--sound' "$CALLS"
scene SID-OLD working "❯" never
run watch w1:p1 SID-OLD "$MSG" --sound request
assert_ok "the requested sound is passed through" grep -q -- '--sound request' "$CALLS"

# === F11: no exit path is silent ============================================
# Structural, so a future edit that adds a bare `exit` fails here rather than in
# production at 3am. The EXIT trap is what makes the guarantee hold even for an
# abort nobody anticipated.
assert_ok "watch installs an EXIT trap so an unplanned abort still logs" \
  grep -q "trap .* EXIT" "$SCRIPT"
scene SID-OLD working "❯" never
run watch w1:p1 SID-OLD "$MSG"
assert_ok "the log is never left empty" test -s "$LOG"
scene SID-OLD working "❯" never
run watch
assert_eq "watch without arguments still exits non-zero" "$?" "2"
assert_ok "and still logs why" grep -q ' REFUSED ' "$LOG"

# --log must be honoured wherever it sits on the line. Order-dependent parsing
# was a real defect here: with --log ahead of the positionals the script kept
# the DEFAULT path, which in a test run is the operator's live rollover log.
scene SID-OLD working "❯" never
FLAGFIRST="$HERDR_STUB_DIR/flag-first.log"
PATH="$BIN:$PATH" SHEPHERD_ROLLOVER_CLEAR_TIMEOUT=1 SHEPHERD_ROLLOVER_POLL=1 \
  bash "$SCRIPT" watch --log "$FLAGFIRST" w1:p1 SID-OLD "$MSG" >/dev/null 2>&1
assert_file "--log is honoured before the positionals" "$FLAGFIRST"
assert_ok "and the run still reached a verdict" grep -q ' GIVE-UP ' "$FLAGFIRST"

# === F12: the out-of-scope subcommands still work ===========================
# ctx/decide/meter were correct in the 2026-08-25 incident and must not regress.
assert_eq "ctx with no pane says unknown" \
  "$(HERDR_PANE_ID= bash "$SCRIPT" ctx 2>/dev/null)" "unknown"
assert_eq "an unknown subcommand still fails loudly" \
  "$(bash "$SCRIPT" nonsense 2>&1 >/dev/null | head -1)" "unknown cmd: nonsense"

# === F13: the deprecation shim at the old path still works ==================
# An instance mid-upgrade may still hold the old path in its context or in a
# ported CLAUDE.md. The shim must forward every subcommand, map the old
# `recycle` verb to `rollover`, map SHEPHERD_RECYCLE_LOG, and say on stderr
# that it is deprecated — loudly enough that nobody keeps using it by accident.
SHIM="$HERE/../self-recycle.sh"
assert_file "the old path still exists as a shim" "$SHIM"

assert_eq "the shim forwards a plain subcommand" \
  "$(HERDR_PANE_ID= bash "$SHIM" ctx 2>/dev/null)" "unknown"
assert_ok "the shim warns on stderr" \
  bash -c 'HERDR_PANE_ID= bash "$1" ctx 2>&1 >/dev/null | grep -qi deprecat' _ "$SHIM"
assert_ok "the warning names the new script" \
  bash -c 'HERDR_PANE_ID= bash "$1" ctx 2>&1 >/dev/null | grep -q context-rollover.sh' _ "$SHIM"

# The verb map, proven by a side effect only `rollover` produces: an unmapped
# `recycle` would reach the new script as an unknown subcommand and exit 1.
scene SID-OLD working "❯" now
SCRIPT="$SHIM" HANDOFF_OVERRIDE=30 run recycle "$MSG" --pane w1:p1
assert_eq "the shim maps recycle to rollover" "$?" "0"
assert_ok "and the rollover armed"      grep -q ' ARM '        "$LOG"
assert_ok "and the watchdog got a parent to outlive" grep -q 'parent=' "$LOG"
assert_fail "and the shim's foreground sent no keystroke either" \
  grep -q 'pane send-keys' "$CALLS"

# The old env var still steers the log for one release.
scene SID-OLD working "❯" never
OLDVAR="$HERDR_STUB_DIR/old-var.log"
# HOME is redirected too: if the mapping ever breaks, the run must land in the
# sandbox and fail this assertion — never append to the operator's real log.
PATH="$BIN:$PATH" HOME="$HERDR_STUB_DIR" SHEPHERD_RECYCLE_LOG="$OLDVAR" \
  SHEPHERD_ROLLOVER_CLEAR_TIMEOUT=1 SHEPHERD_ROLLOVER_POLL=1 \
  bash "$SHIM" watch w1:p1 SID-OLD "$MSG" >/dev/null 2>&1
assert_file "the shim maps SHEPHERD_RECYCLE_LOG to SHEPHERD_ROLLOVER_LOG" "$OLDVAR"
SCRIPT="$HERE/../context-rollover.sh"

# === F14: the invocation vocabulary stays neutral ===========================
# The whole point of the rename (T-0185): the command a shepherd turn actually
# types must not read to a permission classifier like a destructive or
# self-modifying action. Structural, so a future edit cannot quietly undo it.
assert_ok "the shim hands over with exec"          grep -q 'exec bash' "$SHIM"
assert_fail "the shim carries no logic of its own" grep -q 'herdr ' "$SHIM"
assert_fail "the new script carries no recycle vocabulary" \
  grep -qi 'recycl' "$SCRIPT"
assert_ok "the new script answers the rollover verb" \
  grep -q '^  rollover)' "$SCRIPT"

# === F15: the recovery message defaults, so the typed command is bare ========
# T-0187. Two rollover attempts on 2026-08-27 were interrupted at the tool call
# — first under the old script name, then under the new name carrying a
# sentence of prose. Whatever reads that command line, the smallest surface it
# can read is the one with no argument at all. The default lives in the script,
# so `context-rollover.sh rollover` is the whole invocation and every caller
# gets the same recovery line for free.
assert_ok "the script carries a default recovery message" \
  grep -q 'ROLLOVER_MSG:-/wake' "$SCRIPT"
assert_ok "the default is one word, slash-prefixed, no prose" \
  bash -c 'grep -oE "ROLLOVER_MSG:-[^}]*" "$1" | grep -qE "^ROLLOVER_MSG:-/[a-z]+$"' _ "$SCRIPT"

scene SID-OLD working "❯" now
HANDOFF_OVERRIDE=30 run rollover --pane w1:p1
assert_eq "rollover with no message still arms" "$?" "0"
assert_ok "the default message is what got armed" grep -q 'msg=/wake' "$LOG"
assert_fail "and it still sent no keystroke" grep -q 'pane send-keys' "$CALLS"

# End to end on the default: the watchdog must prompt the fresh session with
# the same string the arming line logged, or a rollover recovers into silence.
scene SID-OLD working "❯" now
run watch w1:p1 SID-OLD "/wake"
assert_eq "the default message verifies end to end" "$?" "0"
assert_ok "the fresh session is prompted with /wake" \
  grep -q 'agent prompt w1:p1 /wake' "$CALLS"

# A missing pane is still a refusal — the default covers the message only.
scene SID-OLD working "❯" now
HERDR_PANE_ID= run rollover
assert_eq "rollover with no pane still refuses" "$?" "2"
assert_ok "the refusal is logged"     grep -q ' REFUSED '                 "$LOG"
assert_fail "no /clear was submitted" grep -q 'agent prompt w1:p1 /clear' "$CALLS"

# === F16: the wake skill is what the recovery message invokes ===============
# The message is only as good as the thing it reaches. If the skill directory
# is gone, `/wake` is an unknown slash command and the fresh session stands up
# with no procedure at all — a rollover that reports success and recovers
# nothing.
assert_file "the wake skill the message invokes exists" \
  "$HERE/../../.claude/skills/wake/SKILL.md"

finish
