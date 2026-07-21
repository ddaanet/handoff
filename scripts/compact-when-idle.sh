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
# No `set -e`: the sourced scaffold's `(( ))` arithmetic (wait_for_idle) returning 0 would abort under errexit.
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

# Recognized. Submit and confirm the turn actually started.
submit_or_fail "\`$LINE1\` was typed but three Enters did not submit it"
