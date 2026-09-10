# Minimal assert harness for shepherd's bash scripts. Sourced, never executed.
TESTS_RUN=0
TESTS_FAILED=0

ok()   { TESTS_RUN=$((TESTS_RUN + 1)); printf '  ok   %s\n' "$1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }

assert_eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$3] got [$2]"; fi; }
assert_ok()   { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else fail "$1" "command failed: ${*:2}"; fi; }
assert_fail() { if "${@:2}" >/dev/null 2>&1; then fail "$1" "command unexpectedly succeeded: ${*:2}"; else ok "$1"; fi; }
assert_file() { if [ -f "$2" ]; then ok "$1"; else fail "$1" "missing file: $2"; fi; }
assert_nofile() { if [ -f "$2" ]; then fail "$1" "file should not exist: $2"; else ok "$1"; fi; }

# sandbox <dir-var-name> — fresh SHEPHERD_ROOT, removed on exit
# Also turns on the SHEPHERD_TEST_HOOKS gate: SHEPHERD_LIVENESS_OVERRIDE,
# SHEPHERD_LIVENESS_UNKNOWN, SHEPHERD_PANE_SESSION_OVERRIDE and
# SHEPHERD_NOW_OVERRIDE are inert everywhere except inside a sandboxed test
# - see shepherd-common.sh. Tests
# that need to prove the gate itself must explicitly unset this var.
#
# It also points SHEPHERD_TASK_ID and SHEPHERD_STATUS_FILE INTO the sandbox, so
# that inheritance is harmless: a probe run from a worker session inherits that
# session's own two variables, and anything it invokes without setting them —
# a hook, scripts/bin/shepherd-status — would otherwise append test records to
# a live instance's ground-truth status file. Measured on 2026-09-02: a
# PARTIAL override (SHEPHERD_TASK_ID set, SHEPHERD_STATUS_FILE inherited) put a
# stray `claim: done` into a real ledger file. Overriding both here means the
# worst case is a stray record in a temp directory. The basenames agree
# (T-SANDBOX / T-SANDBOX.jsonl) because shepherd-status refuses a status file
# that belongs to another task. A case that must prove behaviour when one of
# these is ABSENT says so explicitly: `env -u SHEPHERD_STATUS_FILE …`.
sandbox() {
  SHEPHERD_ROOT=$(mktemp -d)
  export SHEPHERD_ROOT
  export SHEPHERD_TEST_HOOKS=1
  export SHEPHERD_TASK_ID=T-SANDBOX
  export SHEPHERD_STATUS_FILE="$SHEPHERD_ROOT/T-SANDBOX.jsonl"
  mkdir -p "$SHEPHERD_ROOT/ledger/locks" "$SHEPHERD_ROOT/ledger/tasks" "$SHEPHERD_ROOT/ledger/shepherds"
  seed_instance_env "$SHEPHERD_ROOT"
  trap 'rm -rf "$SHEPHERD_ROOT"' EXIT
}

# seed_instance_env <root> — the .shepherd/instance.env marker every instance
# command refuses without (lib/shepherd-common.sh, T-0218 §4). sandbox() calls
# it; a test that builds a second root by hand calls it too. A test that must
# prove the refusal itself creates the root WITHOUT calling this.
seed_instance_env() {
  mkdir -p "$1/.shepherd"
  cat > "$1/.shepherd/instance.env" <<'ENVEOF'
SHEPHERD_INSTANCE=1
SHEPHERD_OPERATOR=test
SHEPHERD_CODE_DIR=/tmp/code
SHEPHERD_NOTIFICATIONS=silent
SHEPHERD_WORKER_CAP=6
SHEPHERD_IDS="shepherd-1"
SHEPHERD_MIN_PLUGIN=1.0.0
ENVEOF
}

finish() {
  printf '%s: %d run, %d failed\n' "$(basename "$0")" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
