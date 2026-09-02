#!/usr/bin/env bash
# Shepherd's side of the Linear agent inbox: the only place the shepherd-inbox
# Worker's HTTP contract lives. See
# docs/superpowers/specs/2026-09-02-linear-inbox-wiring-design.md
#
#   inbox.sh owner
#   inbox.sh pending
#   inbox.sh list
#   inbox.sh ack      <event-id>
#   inbox.sh activity <session-id> <thought|action|elicitation|response|error> <body>
#   inbox.sh heartbeat
#   inbox.sh watch    <seconds>
#
# Exit: 0 ok (for watch: there is work) / 124 watch window elapsed / 3 not
#   configured or this inbox serves another instance / 1 hard error / 2 usage.
set -uo pipefail

ENV_FILE="${SHEPHERD_INBOX_ENV:-$HOME/.config/shepherd/inbox.env}"
POLL_SECONDS="${SHEPHERD_INBOX_POLL:-60}"
HEARTBEAT_EVERY=5          # polls, so ~5 minutes at the default interval
MAX_CONSECUTIVE_FAILURES=10

usage() { sed -n '3,15p' "$0" >&2; exit 2; }

# cfg_value <key> — reads KEY=value out of the env file without executing it.
# Sourcing an operator-owned file to get two strings would run anything else in
# it; there is no reason to hand that power to a config file.
cfg_value() {
  sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" 2>/dev/null \
    | tail -n1 | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'
}

load_config() {
  [ -f "$ENV_FILE" ] || return 3
  INBOX_URL=$(cfg_value INBOX_URL)
  INBOX_TOKEN=$(cfg_value INBOX_TOKEN)
  case $INBOX_URL in http://*|https://*) ;; *) return 3 ;; esac
  [ -n "$INBOX_TOKEN" ] || return 3
  INBOX_URL=${INBOX_URL%/}
  return 0
}

# api <method> <path> [json-body] — sets BODY and HTTP_CODE. 0 on 2xx.
# The token goes in a header, never on the command line: an -H argument lands
# in curl's own argv, readable at /proc/<curl-pid>/cmdline for the life of the
# request. A -K config file read from stdin has no such exposure, so the
# Authorization header travels that way instead — every other option (method,
# writeout format, timeout, body) stays a normal argument since none of it is
# secret. -K - is the only stdin reader in this function (the body, when
# present, is a literal -d argument, never "-"), and curl is the last stage of
# the pipe, so pipefail still surfaces curl's exit status here, not printf's.
api() {
  local method=$1 path=$2 data=${3:-} raw
  local -a args=(-sS -X "$method" -K - -w '\n%{http_code}' --max-time 20)
  [ -n "$data" ] && args+=(-H 'Content-Type: application/json' -d "$data")
  raw=$(printf 'header = "Authorization: Bearer %s"\n' "$INBOX_TOKEN" \
          | curl "${args[@]}" "$INBOX_URL$path" 2>/dev/null) || { HTTP_CODE=000; BODY=; return 1; }
  HTTP_CODE=${raw##*$'\n'}
  BODY=${raw%$'\n'*}
  case $HTTP_CODE in 2*) return 0 ;; *) return 1 ;; esac
}

json_field() { printf '%s' "$1" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
v = d.get(sys.argv[1])
sys.stdout.write("" if v is None else str(v))
' "$2"; }

cmd_pending() {
  api GET /inbox/pending || return 1
  json_field "$BODY" pending
}

cmd_list() { api GET /inbox || return 1; printf '%s\n' "$BODY"; }

cmd_ack() {
  [ $# -eq 1 ] || usage
  api POST "/inbox/$1/ack" || return 1
  printf '%s\n' "$BODY"
}

cmd_activity() {
  [ $# -eq 3 ] || usage
  local session=$1 type=$2 body=$3 payload
  case $type in thought|action|elicitation|response|error) ;; *)
    echo "inbox: unknown activity type '$type'" >&2; return 2 ;;
  esac
  # python3 builds the JSON so a body carrying quotes, newlines or backslashes
  # cannot break the request or smuggle a field.
  payload=$(python3 -c 'import json,sys; print(json.dumps({"type":sys.argv[1],"body":sys.argv[2]}))' "$type" "$body")
  api POST "/sessions/$session/activity" "$payload" || return 1
  printf '%s\n' "$BODY"
}

cmd_heartbeat() {
  local payload='{}'
  [ -n "${SHEPHERD_ID:-}" ] && payload=$(python3 -c 'import json,sys; print(json.dumps({"shepherd_id":sys.argv[1]}))' "$SHEPHERD_ID")
  api POST /heartbeat "$payload" || return 1
  printf '%s\n' "$BODY"
}

# owner — /health is unauthenticated and reports the single shepherd id this
# Worker serves. Asking the Worker means ownership needs no second config key,
# and it is the seam a future multi-instance partition changes.
cmd_owner() {
  local raw code got
  raw=$(curl -sS -w '\n%{http_code}' --max-time 20 "$INBOX_URL/health" 2>/dev/null) || return 1
  code=${raw##*$'\n'}
  case $code in 2*) ;; *) return 1 ;; esac
  got=$(json_field "${raw%$'\n'*}" shepherd_id)
  [ -n "$got" ] || return 1
  [ "$got" = "${SHEPHERD_ID:-}" ] && return 0
  echo "inbox: this inbox serves $got, not ${SHEPHERD_ID:-<unset>}" >&2
  return 3
}

# watch <seconds> — the background watcher wake and monitor arm (adapter R5
# shape: a bare command, never piped, whose exit code is the whole signal).
#
# It polls rather than subscribes because a poll costs nothing and needs no
# long-lived connection from a laptop that sleeps. It heartbeats from inside
# the loop, not from the caller, so the Worker's "last online N min ago" ack
# stays honest at five-minute resolution without waking the model at all.
cmd_watch() {
  [ $# -eq 1 ] || usage
  local window=$1 deadline now n rc polls=0 failures=0
  case $window in ''|*[!0-9]*) usage ;; esac

  # An inbox that serves another instance must arm nothing. An unreachable
  # /health is NOT that case — the box may simply be offline for a moment — so
  # it falls through to the loop, which retries and gives up on its own terms.
  cmd_owner >/dev/null 2>&1
  [ $? -eq 3 ] && return 3

  deadline=$(( $(date +%s) + window ))
  while :; do
    now=$(date +%s)
    [ "$now" -ge "$deadline" ] && return 124
    n=$(cmd_pending); rc=$?
    if [ "$rc" -eq 0 ]; then
      failures=0
      case $n in ''|*[!0-9]*) : ;; *) [ "$n" -gt 0 ] && return 0 ;; esac
    else
      # A 401 cannot fix itself, and a watcher that can only ever spin is worse
      # than no watcher at all (adapter R5).
      if [ "${HTTP_CODE:-000}" = "401" ] || [ "${HTTP_CODE:-000}" = "403" ]; then
        echo "inbox: $HTTP_CODE from $INBOX_URL/inbox/pending - check INBOX_TOKEN" >&2
        return 1
      fi
      failures=$((failures + 1))
      if [ "$failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
        echo "inbox: $failures consecutive failures reaching $INBOX_URL - giving up" >&2
        return 1
      fi
    fi
    polls=$((polls + 1))
    [ $((polls % HEARTBEAT_EVERY)) -eq 0 ] && cmd_heartbeat >/dev/null 2>&1
    sleep "$POLL_SECONDS"
  done
}

[ $# -ge 1 ] || usage
verb=$1; shift
load_config; rc=$?
if [ "$rc" -ne 0 ]; then
  echo "inbox: no usable config at $ENV_FILE (need INBOX_URL and INBOX_TOKEN)" >&2
  exit 3
fi

case $verb in
  owner)     cmd_owner ;;
  pending)   cmd_pending ;;
  list)      cmd_list ;;
  ack)       cmd_ack "$@" ;;
  activity)  cmd_activity "$@" ;;
  heartbeat) cmd_heartbeat ;;
  watch)     cmd_watch "$@" ;;
  *)         usage ;;
esac
