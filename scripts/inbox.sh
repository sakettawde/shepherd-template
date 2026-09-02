#!/usr/bin/env bash
# Shepherd's side of the Linear agent inbox: the only place the shepherd-inbox
# Worker's HTTP contract lives. See
# docs/specs/linear-inbox-wiring-design.md
#
# Exit codes are the interface, because a watcher's exit code is all its caller
# sees:
#
#   0    ok; for watch, there is work to drain
#   124  watch only: the window elapsed with nothing pending
#   4    watch only: transient - the Worker was unreachable for the whole
#        consecutive-failure ceiling. Re-arm, and say so once.
#   3    not configured, or this inbox serves another instance
#   1    hard error - 401/403, or a usable answer that says stop
#   2    usage
set -uo pipefail

ENV_FILE="${SHEPHERD_INBOX_ENV:-$HOME/.config/shepherd/inbox.env}"
POLL_SECONDS="${SHEPHERD_INBOX_POLL:-60}"
HEARTBEAT_EVERY=5          # polls, so ~5 minutes at the default interval
# The ceiling on consecutive unusable polls. Overridable so the tests can reach
# it in seconds instead of ten real minutes; nothing else has a reason to set it.
MAX_CONSECUTIVE_FAILURES="${SHEPHERD_INBOX_MAX_FAILURES:-10}"

usage() {
  cat >&2 <<'EOF'
inbox.sh owner                 is this instance the one this inbox serves?
inbox.sh pending               the pending event count, on stdout
inbox.sh list                  the pending events, as the Worker's JSON
inbox.sh ack      <event-id>
inbox.sh activity <session-id> <thought|action|elicitation|response|error> <body>
inbox.sh heartbeat
inbox.sh watch    <seconds>    the background watcher

Exit: 0 ok (watch: there is work) / 124 watch window elapsed / 4 watch: the
Worker was unreachable for the whole ceiling / 3 not configured or this inbox
serves another instance / 1 hard error / 2 usage.
EOF
  exit 2
}

# cfg_value <key> — reads KEY=value out of the env file without executing it.
# Sourcing an operator-owned file to get two strings would run anything else in
# it; there is no reason to hand that power to a config file.
cfg_value() {
  sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" 2>/dev/null \
    | tail -n1 | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'
}

# load_config — sets INBOX_URL and INBOX_TOKEN, and on any refusal CONFIG_ERROR,
# the line the caller prints. CONFIG_ERROR never carries the token value.
load_config() {
  CONFIG_ERROR="no usable config at $ENV_FILE (need INBOX_URL and INBOX_TOKEN)"
  [ -f "$ENV_FILE" ] || return 3
  INBOX_URL=$(cfg_value INBOX_URL)
  INBOX_TOKEN=$(cfg_value INBOX_TOKEN)
  case $INBOX_URL in http://*|https://*) ;; *) return 3 ;; esac
  [ -n "$INBOX_TOKEN" ] || return 3
  # The token is interpolated into a curl -K line — header = "Authorization:
  # Bearer <token>" — where a double quote, a backslash or a newline ends the
  # value early and lets the remainder become a second header. A real Worker
  # token is URL-safe and carries none of those, so this costs an honest config
  # nothing and closes the injection. The message names the constraint; the
  # value stays out of it.
  case $INBOX_TOKEN in
    *'"'*|*'\'*|*[[:space:]]*)
      CONFIG_ERROR="INBOX_TOKEN in $ENV_FILE holds a double quote, a backslash or whitespace; a Worker token carries none of those. Fix the file — the value is not printed."
      return 3 ;;
  esac
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

# pending_probe — sets PENDING, and (via api()) HTTP_CODE, in the CURRENT
# shell. cmd_watch must read HTTP_CODE after a failed poll to tell a 401 from
# a transient error; `n=$(cmd_pending)` would run cmd_pending in a command
# substitution subshell, where api()'s `HTTP_CODE=...` assignment dies with
# the subshell and never reaches the caller — HTTP_CODE would read back
# "000" forever, out there. pending_probe exists solely so nothing ever
# captures cmd_pending's stdout again.
pending_probe() {
  api GET /inbox/pending || return 1
  # A 2xx carrying a body that is not the JSON we asked for fails here too. It
  # has to: PENDING would be empty, the loop would read "nothing pending" and
  # spin out its whole window against a Worker that is answering nonsense. It
  # feeds the same consecutive-failure counter as an unreachable Worker, and
  # that counter's ceiling is exit 4 — transient, re-armed — not a disarm.
  PENDING=$(json_field "$BODY" pending) || return 1
  # A pending count is a non-negative integer or it is not an answer, and the
  # type matters as much as the presence: {"pending":"many"}, {"pending":true}
  # and {"pending":-1} all arrive here as a non-empty string, so a probe that
  # only asked "is it empty?" passed them on, failed no poll, counted no
  # failure and polled the whole window away in silence. Everything that is not
  # a run of digits is a failed poll, on the one road to the ceiling and exit 4.
  case $PENDING in ''|*[!0-9]*) PENDING=; return 1 ;; esac
  return 0
}

cmd_pending() {
  pending_probe || return 1
  printf '%s' "$PENDING"
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

# still_ours — the in-loop ownership gate. Only a definite answer stops the
# watcher: cmd_owner's exit 3 means the Worker named a different instance. An
# unreachable /health cannot disprove ownership, so it is left to the
# consecutive-failure ceiling instead of being read as a verdict.
still_ours() { cmd_owner >/dev/null; [ $? -ne 3 ]; }

# watch <seconds> — the background watcher wake and monitor arm (adapter R5
# shape: a bare command, never piped, whose exit code is the whole signal).
#
# It polls rather than subscribes because a poll costs nothing and needs no
# long-lived connection from a laptop that sleeps. It heartbeats from inside
# the loop, not from the caller, so the Worker's "last online N min ago" ack
# stays honest at five-minute resolution without waking the model at all.
#
# Ownership is re-checked *inside* the loop, not only before it. One box runs
# several instances sharing one inbox.env and one bearer token, and that token
# authenticates the inbox, not the instance — so a non-owner that armed while
# /health was briefly unreachable would otherwise poll the owner's inbox for
# the whole window, and both instances would drain the same event into two
# cards and two workers.
cmd_watch() {
  [ $# -eq 1 ] || usage
  local window=$1 deadline now rc polls=0 failures=0
  case $window in ''|*[!0-9]*) usage ;; esac

  # An inbox that serves another instance must arm nothing. An unreachable
  # /health is NOT that case — the box may simply be offline for a moment — so
  # it falls through to the loop, where the same check runs again on every
  # heartbeat tick and once more before any drain.
  still_ours || return 3

  deadline=$(( $(date +%s) + window ))
  while :; do
    now=$(date +%s)
    [ "$now" -ge "$deadline" ] && return 124

    # The heartbeat tick fires on the first poll and every HEARTBEAT_EVERY
    # after it. It sits ahead of the probe because the loop returns the moment
    # work is pending: a busy inbox would otherwise never post one, and the
    # Worker's "last online" text would go stale exactly when shepherd is
    # busiest. Ownership rides the same tick.
    if [ $((polls % HEARTBEAT_EVERY)) -eq 0 ]; then
      still_ours || return 3
      cmd_heartbeat >/dev/null 2>&1
    fi
    polls=$((polls + 1))

    pending_probe; rc=$?
    if [ "$rc" -eq 0 ]; then
      # rc 0 means pending_probe validated the count, so the only question
      # left here is whether it is above zero. The type check lives there and
      # only there: a second, quieter one here was how a wrong-typed count
      # reached this branch and fell out of it counting nothing.
      failures=0
      if [ "$PENDING" -gt 0 ]; then
        # Never hand a drain to a non-owner. This is the last gate before the
        # caller reads exit 0 and starts posting to Linear.
        still_ours || return 3
        return 0
      fi
    else
      # A 401 cannot fix itself, and a watcher that can only ever spin is worse
      # than no watcher at all (adapter R5).
      if [ "${HTTP_CODE:-000}" = "401" ] || [ "${HTTP_CODE:-000}" = "403" ]; then
        echo "inbox: $HTTP_CODE from $INBOX_URL/inbox/pending - check INBOX_TOKEN" >&2
        return 1
      fi
      failures=$((failures + 1))
      if [ "$failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
        # Transient, and it says so: exit 4. Cloudflare trouble or a laptop
        # that resumed ahead of its Wi-Fi both land here, and both are over in
        # minutes. Exit 1 would have retired Linear intake and the heartbeat
        # for the rest of the session over a blip, so the callers re-arm on 4
        # and name the Worker as unreachable while they do.
        echo "inbox: $failures consecutive failures reaching $INBOX_URL - transient, re-arm" >&2
        return 4
      fi
    fi
    sleep "$POLL_SECONDS"
  done
}

[ $# -ge 1 ] || usage
verb=$1; shift
load_config; rc=$?
if [ "$rc" -ne 0 ]; then
  echo "inbox: $CONFIG_ERROR" >&2
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
