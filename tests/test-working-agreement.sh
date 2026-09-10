#!/usr/bin/env bash
# CLAUDE.md S5's working-agreement check as a command: prints the branch when
# origin/<dev-branch>:CLAUDE.md is readable, nothing when it is not. The ref
# guard (rev-parse first) is what keeps a never-fetched checkout from reading
# as "no working agreement".
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
WA="$HERE/../bin/shepherd-working-agreement"
R="$SHEPHERD_ROOT/repos"

echo "test-working-agreement:"

g() { git -C "$1" -c user.email=t@t -c user.name=T "${@:2}"; }
mkdir -p "$R"
git init -q --bare "$R/origin.git"
git init -q -b main "$R/with"
g "$R/with" commit -q --allow-empty -m seed
printf 'rules\n' > "$R/with/CLAUDE.md"; g "$R/with" add CLAUDE.md; g "$R/with" commit -qm agreement
g "$R/with" remote add origin "$R/origin.git"; g "$R/with" push -q origin main

assert_eq "prints the branch when origin/<dev>:CLAUDE.md exists" "$(bash "$WA" "$R/with" main)" "main"
assert_ok "and exits 0" bash "$WA" "$R/with" main

# a fresh clone that has fetched: same answer
git clone -q "$R/origin.git" "$R/clone"
assert_eq "a clone answers the same" "$(bash "$WA" "$R/clone" main)" "main"

# the file removed on origin: nothing, exit 1
g "$R/with" rm -q CLAUDE.md; g "$R/with" commit -qm "drop"; g "$R/with" push -q origin main
assert_eq "prints nothing once the file is gone from origin" "$(bash "$WA" "$R/clone" main)" ""
assert_fail "and exits 1" bash "$WA" "$R/clone" main

# a branch origin never had: nothing, exit 1, no fatal on stdout
out=$(bash "$WA" "$R/clone" nosuch 2>/dev/null); rc=$?
assert_eq "an unknown ref prints nothing" "$out" ""
assert_eq "an unknown ref exits 1" "$rc" "1"

# no origin at all: answers from local refs only -> nothing
git init -q -b main "$R/alone"; g "$R/alone" commit -q --allow-empty -m seed
printf 'x\n' > "$R/alone/CLAUDE.md"; g "$R/alone" add CLAUDE.md; g "$R/alone" commit -qm a
assert_fail "a repo with no origin reads as no working agreement" bash "$WA" "$R/alone" main

# argument errors
out=$(bash "$WA" "$R/nowhere" main 2>&1); rc=$?
assert_eq "a non-repo path exits 2" "$rc" "2"
out=$(bash "$WA" "$R/with" 2>&1); rc=$?
assert_eq "a missing branch argument exits 2" "$rc" "2"

finish
