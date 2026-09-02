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
unset SHEPHERD_INBOX_ENV INBOX_URL INBOX_TOKEN SHEPHERD_INBOX_POLL

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

def reply_for(path):
    # A case drops <name>.json into REPLIES to script a route. The file's first
    # line is the status code, the rest is the body.
    name = path.strip('/').replace('/', '_').split('?')[0] + '.json'
    f = os.path.join(REPLIES, name)
    if not os.path.exists(f):
        return 404, '{"error":"not found"}'
    raw = open(f).read().split('\n', 1)
    return int(raw[0]), (raw[1] if len(raw) > 1 else '')

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
export SHEPHERD_ID=shepherd-collie

route() { printf '%s\n%s' "$2" "$3" > "$REPLIES/$1.json"; }
last_request() { tail -n1 "$LOG"; }
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
  "shepherd-collie"

# --- owner -----------------------------------------------------------------
route health 200 '{"status":"ok","shepherd_id":"shepherd-collie"}'
assert_ok "owner exits 0 when the inbox serves this instance" "$SCRIPT" owner
route health 200 '{"status":"ok","shepherd_id":"shepherd-kelpie"}'
"$SCRIPT" owner >/dev/null 2>&1; assert_eq "owner exits 3 for another instance's inbox" "$?" "3"
assert_eq "owner does not authenticate" "$(last_request | field auth)" ""

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

finish
