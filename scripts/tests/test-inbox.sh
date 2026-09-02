#!/usr/bin/env bash
# Probe for scripts/inbox.sh — the shepherd side of the Linear agent inbox.
#
# Every case runs against a local python3 stub, never the deployed Worker and
# never the operator's ~/.config/shepherd/inbox.env. The token in these tests is
# a fixture string; the assertions below include one that no token value ever
# reaches stdout or stderr, because this script is the only place a real one is
# ever in memory.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/harness.sh"
sandbox
SCRIPT="$HERE/../inbox.sh"

echo "test-inbox:"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is available" "python3 not found"
  finish; exit
fi

# A worker running this probe inherits the live instance's environment. Clear
# every variable the script reads, or a case silently tests the real inbox.
unset SHEPHERD_INBOX_ENV INBOX_URL INBOX_TOKEN SHEPHERD_INBOX_POLL SHEPHERD_INBOX_MAX_FAILURES

TOKEN='tok-fixture-do-not-log'
STUB="$SHEPHERD_ROOT/stub.py"
LOG="$SHEPHERD_ROOT/requests.log"
REPLIES="$SHEPHERD_ROOT/replies"
mkdir -p "$REPLIES"

cat > "$STUB" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

REPLIES = sys.argv[1]
LOG = sys.argv[2]

def read_reply(f):
    raw = open(f).read().split('\n', 1)
    return int(raw[0]), (raw[1] if len(raw) > 1 else '')

def reply_for(path):
    # A case drops <name>.json into REPLIES to script a route. The file's first
    # line is the status code, the rest is the body.
    stem = path.strip('/').replace('/', '_').split('?')[0]
    # <stem>.onceN.json is a one-shot: served once, in queued order, then
    # deleted, after which the persistent file has the route back. That is how
    # a case makes one route answer differently on the first request than on
    # the second — the shape every ownership-change case needs.
    once = sorted((n for n in os.listdir(REPLIES) if n.startswith(stem + '.once')),
                  key=lambda n: int(n[len(stem) + 5:-5]))
    if once:
        f = os.path.join(REPLIES, once[0])
        code, out = read_reply(f)
        os.remove(f)
        return code, out
    f = os.path.join(REPLIES, stem + '.json')
    if not os.path.exists(f):
        return 404, '{"error":"not found"}'
    return read_reply(f)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def handle_one(self, method):
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length).decode() if length else ''
        with open(LOG, 'a') as fh:
            fh.write(json.dumps({
                'method': method, 'path': self.path,
                'auth': self.headers.get('Authorization', ''),
                'content_type': self.headers.get('Content-Type', ''),
                'body': body,
            }) + '\n')
        code, out = reply_for(self.path)
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(out)))
        self.end_headers()
        self.wfile.write(out.encode())
    def do_GET(self): self.handle_one('GET')
    def do_POST(self): self.handle_one('POST')

srv = HTTPServer(('127.0.0.1', 0), H)
print(srv.server_port, flush=True)
srv.serve_forever()
PY

python3 "$STUB" "$REPLIES" "$LOG" > "$SHEPHERD_ROOT/port" &
STUB_PID=$!
trap 'kill "$STUB_PID" 2>/dev/null; rm -rf "$SHEPHERD_ROOT"' EXIT
for _ in $(seq 1 50); do [ -s "$SHEPHERD_ROOT/port" ] && break; sleep 0.1; done
PORT=$(cat "$SHEPHERD_ROOT/port")
URL="http://127.0.0.1:$PORT"

ENVFILE="$SHEPHERD_ROOT/inbox.env"
printf 'INBOX_URL=%s\nINBOX_TOKEN=%s\n' "$URL" "$TOKEN" > "$ENVFILE"
export SHEPHERD_INBOX_ENV="$ENVFILE"
export SHEPHERD_ID=shepherd-fixture

route() { printf '%s\n%s' "$2" "$3" > "$REPLIES/$1.json"; }
# route_once <name> <code> <body> — queued one-shot replies, served before the
# persistent route and in the order queued.
ONCE=0
route_once() { ONCE=$((ONCE + 1)); printf '%s\n%s' "$2" "$3" > "$REPLIES/$1.once$ONCE.json"; }
clear_once() { rm -f "$REPLIES"/*.once*.json; }
last_request() { tail -n1 "$LOG"; }
count_path() { grep -c "\"path\": \"$1\"" "$LOG"; }
field() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1],""))' "$1"; }

# --- pending ---------------------------------------------------------------
route inbox_pending 200 '{"pending":3}'
out=$("$SCRIPT" pending); rc=$?
assert_eq "pending prints the bare count" "$out" "3"
assert_eq "pending exits 0" "$rc" "0"
assert_eq "pending sends the bearer token" \
  "$(last_request | field auth)" "Bearer $TOKEN"
assert_eq "pending calls GET /inbox/pending" \
  "$(last_request | field path)" "/inbox/pending"

# --- list ------------------------------------------------------------------
route inbox 200 '{"events":[{"id":7,"kind":"created","session_id":"s1"}],"cursor":7}'
out=$("$SCRIPT" list)
assert_eq "list prints the Worker's JSON verbatim" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["events"][0]["id"])')" "7"
assert_eq "list calls GET /inbox with no since" "$(last_request | field path)" "/inbox"

# --- ack -------------------------------------------------------------------
route inbox_7_ack 200 '{"ok":true,"already":false}'
assert_ok "ack exits 0" "$SCRIPT" ack 7
assert_eq "ack POSTs to /inbox/<id>/ack" "$(last_request | field path)" "/inbox/7/ack"
assert_eq "ack uses POST" "$(last_request | field method)" "POST"

# --- activity --------------------------------------------------------------
route sessions_s1_activity 200 '{"ok":true,"activityId":"a1"}'
assert_ok "activity exits 0" "$SCRIPT" activity s1 response 'done: "quoted" and \ backslashed'
sent=$(last_request | field body)
assert_eq "activity sends the type" \
  "$(printf '%s' "$sent" | python3 -c 'import json,sys; print(json.load(sys.stdin)["type"])')" "response"
assert_eq "activity JSON-escapes the body rather than breaking the request" \
  "$(printf '%s' "$sent" | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"])')" \
  'done: "quoted" and \ backslashed'
assert_fail "activity refuses an unknown type" "$SCRIPT" activity s1 mumble hello

# --- heartbeat -------------------------------------------------------------
route heartbeat 200 '{"ok":true,"at":1}'
assert_ok "heartbeat exits 0" "$SCRIPT" heartbeat
assert_eq "heartbeat names this instance" \
  "$(last_request | field body | python3 -c 'import json,sys; print(json.load(sys.stdin)["shepherd_id"])')" \
  "shepherd-fixture"

# --- owner -----------------------------------------------------------------
route health 200 '{"status":"ok","shepherd_id":"shepherd-fixture"}'
assert_ok "owner exits 0 when the inbox serves this instance" "$SCRIPT" owner
route health 200 '{"status":"ok","shepherd_id":"shepherd-other"}'
"$SCRIPT" owner >/dev/null 2>&1; assert_eq "owner exits 3 for another instance's inbox" "$?" "3"
assert_eq "owner does not authenticate" "$(last_request | field auth)" ""

# --- token delivery (regression: -K stdin, not -H argv) --------------------
# api() moved the Authorization header off curl's command line and onto a -K
# config file read from stdin, to keep the token out of /proc/<pid>/cmdline.
# The stub can't inspect curl's live argv, but it can confirm the header still
# arrives at the Worker intact after the change, and that owner (which never
# calls api()) still sends none.
route inbox_pending 200 '{"pending":9}'
out=$("$SCRIPT" pending)
assert_eq "the -K-delivered bearer token still arrives at the Worker" \
  "$(last_request | field auth)" "Bearer $TOKEN"
assert_eq "and the request still round-trips correctly" "$out" "9"
route health 200 '{"status":"ok","shepherd_id":"shepherd-fixture"}'
"$SCRIPT" owner >/dev/null 2>&1
assert_eq "owner still sends no Authorization header after the api() change" \
  "$(last_request | field auth)" ""

# --- config and secrecy ----------------------------------------------------
SHEPHERD_INBOX_ENV="$SHEPHERD_ROOT/absent.env" "$SCRIPT" pending >/dev/null 2>&1
assert_eq "a missing config file exits 3, not 1" "$?" "3"
printf 'INBOX_URL=%s\n' "$URL" > "$SHEPHERD_ROOT/half.env"
SHEPHERD_INBOX_ENV="$SHEPHERD_ROOT/half.env" "$SCRIPT" pending >/dev/null 2>&1
assert_eq "a config missing the token exits 3" "$?" "3"
route inbox_pending 401 '{"error":"unauthorized"}'
"$SCRIPT" pending >/dev/null 2>&1
assert_eq "a 401 is a hard error, not a 3" "$?" "1"
noise=$("$SCRIPT" pending 2>&1; "$SCRIPT" owner 2>&1; "$SCRIPT" heartbeat 2>&1)
case $noise in *"$TOKEN"*) fail "no verb ever prints the token" "token found in output" ;;
               *) ok "no verb ever prints the token" ;; esac
route inbox_pending 200 '{"pending":0}'

# --- watch -----------------------------------------------------------------
export SHEPHERD_INBOX_POLL=1
route health 200 '{"status":"ok","shepherd_id":"shepherd-fixture"}'

route inbox_pending 200 '{"pending":0}'
"$SCRIPT" watch 2 >/dev/null 2>&1
assert_eq "watch exits 124 when the window elapses with nothing pending" "$?" "124"

route inbox_pending 200 '{"pending":1}'
start=$(date +%s)
"$SCRIPT" watch 60 >/dev/null 2>&1; rc=$?
assert_eq "watch exits 0 as soon as something is pending" "$rc" "0"
assert_ok "watch returns promptly rather than serving out its window" \
  test $(( $(date +%s) - start )) -lt 15

route health 200 '{"status":"ok","shepherd_id":"shepherd-other"}'
"$SCRIPT" watch 5 >/dev/null 2>&1
assert_eq "watch exits 3 for another instance's inbox, and arms nothing" "$?" "3"
route health 200 '{"status":"ok","shepherd_id":"shepherd-fixture"}'

route inbox_pending 401 '{"error":"unauthorized"}'
: > "$LOG"
start=$(date +%s)
"$SCRIPT" watch 30 >/dev/null 2>&1; rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "watch exits 1 immediately on a 401 rather than spinning" "$rc" "1"
# rc alone passes for the wrong reason too: the consecutive-failure ceiling
# also exits 1. HTTP_CODE only survives to the check below if the poll that
# set it ran in cmd_watch's own shell, never inside a command substitution -
# a regression here means the fast path is dead and every 401 is silently
# retried ~10 times before falling through the ceiling instead. Assert the
# fast path actually fired: exactly one request, and well under the window.
reqs=$(grep -c '"path": "/inbox/pending"' "$LOG")
assert_eq "a 401 makes exactly one pending request, never a retry storm" "${reqs:-0}" "1"
assert_ok "watch exits the 401 promptly rather than spinning out its window" \
  test "$elapsed" -lt 15

# The heartbeat is the reason this loop exists at all: the Worker's canned ack
# tells the user how long ago shepherd was online, and a heartbeat posted only
# at model wakes would make that text wrong for hours.
route inbox_pending 200 '{"pending":0}'
route heartbeat 200 '{"ok":true,"at":1}'
: > "$LOG"
"$SCRIPT" watch 7 >/dev/null 2>&1
beats=$(grep -c '"path": "/heartbeat"' "$LOG")
assert_ok "watch posts a heartbeat while it polls" test "${beats:-0}" -ge 1

# pending_probe's refactor (HTTP_CODE must survive outside a subshell) must
# not change the public CLI: `inbox.sh pending` still prints a bare integer.
route inbox_pending 200 '{"pending":42}'
out=$("$SCRIPT" pending); rc=$?
assert_eq "pending still prints the bare count after the pending_probe refactor" "$out" "42"
assert_eq "pending still exits 0 after the pending_probe refactor" "$rc" "0"

# --- ownership is re-checked inside the loop, not only before it -----------
# Several instances share one box, one inbox.env and one bearer token, and that
# token authenticates the inbox rather than the instance. The pre-check
# deliberately tolerates an unreachable /health, so a 30-second Worker blip
# during a non-owner's wake used to buy it a full window of polling the owner's
# inbox — and when an event landed, both instances drained it into two cards
# and two workers.
export SHEPHERD_INBOX_POLL=1
clear_once
route health 200 '{"status":"ok","shepherd_id":"shepherd-other"}'
route_once health 503 '{"error":"unavailable"}'      # what the pre-check sees
route inbox_pending 200 '{"pending":1}'
: > "$LOG"
"$SCRIPT" watch 30 >/dev/null 2>&1; rc=$?
assert_eq "an unreachable /health at arm time never becomes a licence to drain" "$rc" "3"
assert_ok "because ownership is asked again inside the loop, not only before it" \
  test "$(count_path /health)" -ge 2
assert_eq "and nothing was posted to the other instance's Linear sessions" \
  "$(grep -c '/activity' "$LOG")" "0"

# The pre-drain gate is separate from the heartbeat-tick gate: between two ticks
# only this one stands between a stolen inbox and a drain. Three scripted
# /health answers walk the watcher to it — pre-check, tick, then the gate.
clear_once
route_once health 200 '{"status":"ok","shepherd_id":"shepherd-fixture"}'
route_once health 200 '{"status":"ok","shepherd_id":"shepherd-fixture"}'
route_once health 200 '{"status":"ok","shepherd_id":"shepherd-other"}'
: > "$LOG"
"$SCRIPT" watch 30 >/dev/null 2>&1; rc=$?
assert_eq "the gate before exit 0 refuses a drain the owner changed under" "$rc" "3"
assert_eq "and it runs after the pending probe, which is the only place it helps" \
  "$(last_request | field path)" "/health"

clear_once
route health 200 '{"status":"ok","shepherd_id":"shepherd-fixture"}'

# --- a busy inbox still heartbeats -----------------------------------------
# The loop returns the moment work is pending, so a heartbeat that fired only
# every fifth poll never fired at all on a busy inbox — the Worker's "shepherd
# was last online N ago" text went stale exactly when shepherd was busiest.
route inbox_pending 200 '{"pending":2}'
: > "$LOG"
"$SCRIPT" watch 30 >/dev/null 2>&1; rc=$?
assert_eq "a pending count still ends the watch at once" "$rc" "0"
assert_ok "and the first poll heartbeats, so a busy inbox is not a silent one" \
  test "$(count_path /heartbeat)" -ge 1

# --- the failure ceiling is transient, not terminal ------------------------
# Ten minutes of Cloudflare trouble, or a laptop resuming ahead of its Wi-Fi,
# used to exit 1 — which wake and monitor both read as "report, do not re-arm",
# retiring Linear intake and the heartbeat for the rest of the session.
export SHEPHERD_INBOX_MAX_FAILURES=3
route inbox_pending 503 '{"error":"unavailable"}'
: > "$LOG"
"$SCRIPT" watch 60 >/dev/null 2>&1; rc=$?
assert_eq "an unreachable Worker exhausts the ceiling as 4 (transient), not 1" "$rc" "4"
assert_eq "and it spent the whole ceiling before saying so" "$(count_path /inbox/pending)" "3"

# A 2xx whose body is not the JSON we asked for is the second road to the same
# place: PENDING comes back empty, and reading that as "nothing pending" would
# spin the window out against a Worker answering nonsense.
route inbox_pending 200 'this is not json'
: > "$LOG"
"$SCRIPT" watch 60 >/dev/null 2>&1; rc=$?
assert_eq "a 2xx with an unusable body is a failure, not a quiet zero" "$rc" "4"
assert_eq "and it feeds the same ceiling rather than polling the window away" \
  "$(count_path /inbox/pending)" "3"

# The third road, and the one that used to be silent: a 2xx that parses, that
# carries `pending`, and whose `pending` is not a count. "many", true and -1 all
# arrive as a non-empty string, so a probe that only asked "is it empty?" passed
# each of them on to a loop that failed no poll and counted no failure - the
# watcher spun its whole window against a Worker answering nonsense and then
# reported 124, "nothing pending". An 8s window against a 3-poll ceiling at a 1s
# interval separates the two: exit 4 lands in about three seconds, where the old
# behaviour served out all eight and returned 124.
for bad in '{"pending":"many"}' '{"pending":true}' '{"pending":-1}'; do
  route inbox_pending 200 "$bad"
  : > "$LOG"
  "$SCRIPT" watch 8 >/dev/null 2>&1; rc=$?
  assert_eq "a 2xx carrying $bad is a failed poll, never a quiet zero" "$rc" "4"
  assert_eq "and $bad reaches the ceiling instead of spinning the window out" \
    "$(count_path /inbox/pending)" "3"
done
unset SHEPHERD_INBOX_MAX_FAILURES

# The same gate on the public verb: `pending` answers with a count or it fails.
route inbox_pending 200 '{"pending":"many"}'
out=$("$SCRIPT" pending 2>/dev/null); rc=$?
assert_eq "pending fails rather than printing a count that is not one" "$rc" "1"
assert_eq "and prints nothing when it does" "$out" ""
route inbox_pending 200 '{"pending":0}'

# --- the token is checked before it reaches a curl -K line -----------------
# api() interpolates the token into `header = "Authorization: Bearer <token>"`.
# A double quote, a backslash or a newline in the value would end that string
# early and let the rest of it become a second header.
for bad in 'tok with space' 'tok"quoted' 'tok\backslashed'; do
  printf 'INBOX_URL=%s\nINBOX_TOKEN=%s\n' "$URL" "$bad" > "$SHEPHERD_ROOT/bad.env"
  : > "$LOG"
  err=$(SHEPHERD_INBOX_ENV="$SHEPHERD_ROOT/bad.env" "$SCRIPT" pending 2>&1); rc=$?
  assert_eq "a token holding [$bad] exits 3" "$rc" "3"
  case $err in *whitespace*)
    ok "the refusal for [$bad] names the constraint" ;;
  *) fail "the refusal for [$bad] names the constraint" "got [$err]" ;; esac
  case $err in *"$bad"*)
    fail "the refusal for [$bad] withholds the value" "the value was printed" ;;
  *) ok "the refusal for [$bad] withholds the value" ;; esac
  assert_eq "and nothing carrying [$bad] ever left for the Worker" \
    "$(wc -l < "$LOG")" "0"
done

finish
