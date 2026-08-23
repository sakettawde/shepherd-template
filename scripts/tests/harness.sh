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
# SHEPHERD_LIVENESS_UNKNOWN and SHEPHERD_PANE_SESSION_OVERRIDE are inert
# everywhere except inside a sandboxed test - see shepherd-common.sh. Tests
# that need to prove the gate itself must explicitly unset this var.
sandbox() {
  SHEPHERD_ROOT=$(mktemp -d)
  export SHEPHERD_ROOT
  export SHEPHERD_TEST_HOOKS=1
  mkdir -p "$SHEPHERD_ROOT/ledger/locks" "$SHEPHERD_ROOT/ledger/tasks" "$SHEPHERD_ROOT/ledger/shepherds"
  trap 'rm -rf "$SHEPHERD_ROOT"' EXIT
}

finish() {
  printf '%s: %d run, %d failed\n' "$(basename "$0")" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
