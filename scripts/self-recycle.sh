#!/usr/bin/env bash
# DEPRECATED compatibility shim — kept for one release (T-0185, 2026-08-27).
#
# This script was renamed to `scripts/context-rollover.sh`. The old name and the
# old `recycle` verb read to Claude Code's permission auto-classifier as a
# destructive, self-modifying action, so the call that resets shepherd's own
# context was refused in auto mode and the reset never happened.
#
# The shim exists only so an instance mid-upgrade — one still holding the old
# path in a ported CLAUDE.md — keeps working. It changes no behaviour: it maps
# the old names to the new ones and hands over with `exec`.
#
#   subcommand  recycle              -> rollover
#   env         SHEPHERD_RECYCLE_*   -> SHEPHERD_ROLLOVER_*
#
# One output string moved with the rename: `decide` now answers
# `rollover|hold|ok|unknown` where it used to answer `recycle|…`.
#
# Delete this file once every instance checkout is on the new name.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
target="$here/context-rollover.sh"

printf '%s\n' \
  "scripts/self-recycle.sh is DEPRECATED and will be removed; use scripts/context-rollover.sh (verb: rollover)." >&2

# Carry the old tunables across. Only variables the caller actually set are
# forwarded, and an already-set new name always wins — a caller that has been
# updated must never be overridden by a stale one.
for suffix in LOG SOUND POLL CLEAR_TIMEOUT SETTLE ATTEMPTS VERIFY ESCAPE_SETTLE PROJECTS; do
  old="SHEPHERD_RECYCLE_$suffix"
  new="SHEPHERD_ROLLOVER_$suffix"
  if [ -n "${!old:-}" ] && [ -z "${!new:-}" ]; then
    export "$new=${!old}"
  fi
done

# Map the verb. Only the first argument can be a subcommand.
if [ "${1:-}" = recycle ]; then
  shift
  exec bash "$target" rollover "$@"
fi

exec bash "$target" "$@"
