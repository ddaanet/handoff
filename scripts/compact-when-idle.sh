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
# No `set -e`: a watcher must reach its watcher_fail line rather than die
# part-way through on any non-zero command — a transient tmux call, a grep
# that does not match. Under errexit that death is silent, which is the one
# outcome these scripts exist to prevent.
set -uo pipefail

PANE="${1:?pane id required}"; shift
LINE1="$*"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=_rename-lib.sh
. "$DIR/_rename-lib.sh"

wait_for_idle

# Load-bearing, not defensive: send-keys concatenates onto half-typed user text,
# which is the principal corruption risk once the turn-boundary gate is in place.
snap | is_typing && watcher_fail "the user was composing a prompt, so \`$LINE1\` was never typed"

# Type-verify-submit. Send the command literally with NO Enter, then read back
# whether the TUI recognized it before committing to a keystroke that runs it.
tmux send-keys -t "$PANE" -l "$LINE1"
sleep "$VERIFY_DELAY"
if snap | is_unknown_command; then
    # Clear the composer and leave the pane as we found it. Never Enter on a
    # command the TUI has already said it cannot run.
    tmux send-keys -t "$PANE" C-u
    watcher_fail "the TUI did not recognize \`$LINE1\`, so it was cleared unrun"
fi

# Recognized. Submit, then confirm against the compaction itself rather than
# against the pane — see submit_consumed_or_fail.
submit_consumed_or_fail "\`$LINE1\` was typed and Entered, but no compaction followed"
