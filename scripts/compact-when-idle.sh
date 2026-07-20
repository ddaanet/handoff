#!/usr/bin/env bash
# handoff watcher: wait for this tmux pane's prompt to go idle, then type the
# `/compact [directive]` line into it. Run detached by stop-compact.sh, which
# fires at Stop — so the idle-wait here is a settle delay, not the safety
# mechanism (the Stop hook already guarantees the turn is over).
#
# Usage: compact-when-idle.sh <pane-id> <line1...>
#
# Completion is NOT this watcher's problem: SessionStart(compact) owns firing
# the continuation. This script types one line and exits.
#
# No `set -e`: arithmetic `(( ))` returning 0 would otherwise abort the loop.
set -uo pipefail

PANE="${1:?pane id required}"; shift
LINE1="$*"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=_rename-lib.sh
. "$DIR/_rename-lib.sh"

TIMEOUT="${AUTONAME_TIMEOUT:-30}"
POLL="${AUTONAME_POLL:-0.1}"
VERIFY_DELAY="${AUTONAME_VERIFY_DELAY:-0.5}"

# Read only the VISIBLE pane, never `capture-pane -S` history: a stale timer
# glyph in scrollback matches is_busy long after the turn ended (spike, 2026-07-19).
snap() { tmux capture-pane -p -t "$PANE" 2>/dev/null | tail -n 40; }

deadline=$((SECONDS + TIMEOUT)); stable=0
while (( SECONDS < deadline )); do
    if snap | is_busy; then stable=0; sleep "$POLL"; continue; fi
    stable=$((stable + 1))
    (( stable >= 3 )) && break
    sleep "$POLL"
done

# Load-bearing, not defensive: send-keys concatenates onto half-typed user text,
# which is the principal corruption risk once the turn-boundary gate is in place.
snap | is_typing && exit 0

# Type-verify-submit. Send the command literally with NO Enter, then read back
# whether the TUI recognized it before committing to a keystroke that runs it.
tmux send-keys -t "$PANE" -l "$LINE1"
sleep "$VERIFY_DELAY"
if snap | is_unknown_command; then
    # Clear the composer and leave the pane as we found it. Never Enter on a
    # command the TUI has already said it cannot run.
    tmux send-keys -t "$PANE" C-u
    exit 1
fi

# Recognized. Enter, then confirm the composer drained; retry the Enter only
# (re-sending the text would concatenate a second copy).
for _ in 1 2 3; do
    tmux send-keys -t "$PANE" Enter
    sleep "$VERIFY_DELAY"
    snap | is_typing || exit 0
done
exit 1
