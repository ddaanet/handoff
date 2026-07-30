#!/usr/bin/env bash
# handoff watcher: type a sequence of lines into this tmux pane, one at a time,
# each one waited for and each one confirmed. Run detached — by stop-drive.sh
# for the lines typed before a transition, and by the transition's own
# SessionStart loader for the lines typed after it — so it outlives the turn
# that spawned it.
#
# Usage: drive-when-idle.sh <pane-id> <line>...
#
# One argument per line: the caller passes the sentinel's lines through
# verbatim, and they are the literal keystrokes. The walker does not know which
# command belongs to which kind of transition — that is fixed by
# handoff_drive_read's per-kind validation, upstream. What it dispatches on is
# the command itself, which is what lets `/rename` appear in two kinds with two
# different fates: terminal under `rename`, followed by `/clear` under `clear`.
#
# No `set -e`: a watcher must reach its watcher_fail line rather than die
# part-way through on any non-zero command — a transient tmux call, a grep
# that does not match. Under errexit that death is silent, which is the one
# outcome these scripts exist to prevent.
set -uo pipefail

PANE="${1:?pane id required}"; shift

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=_watcher-lib.sh
. "$DIR/_watcher-lib.sh"

for line in "$@"; do
    # FR-H: every line re-gates. Confirming the previous one can take minutes
    # (CONSUME_TIMEOUT is 300s) and the pane is live throughout, so idleness
    # established before it says nothing about now.
    wait_for_idle

    # Load-bearing, not defensive: send-keys concatenates onto half-typed user
    # text, which is the principal corruption risk once the turn-boundary gate
    # is in place. A bail is a non-delivery like any other — the spawning hook
    # has already told the user the line is coming.
    snap | is_typing \
        && watcher_fail "the user was composing a prompt, so \`$line\` was never typed"

    # Send literally (-l) so nothing in the line is read as tmux key names;
    # Enter is always a separate keystroke, sent by the confirmation below.
    tmux send-keys -t "$PANE" -l "$line"

    # Two things at once, for the two line classes. For a `/` line this is the
    # type-verify-submit gap: read back whether the TUI recognized the command
    # before committing to a keystroke that runs it. For prose it is a settle —
    # an Enter sent immediately after a long literal send lands inside the TUI's
    # paste window and is absorbed as a line break, not a submit. Prose has no
    # readback to earn the gap for free, so it is explicit here; do not remove
    # it as redundant.
    sleep "$VERIFY_DELAY"

    case "$line" in /*)
        if snap | is_unknown_command; then
            # Clear the composer and leave the pane as we found it. Never Enter
            # on a command the TUI has already said it cannot run.
            tmux send-keys -t "$PANE" C-u
            watcher_fail "the TUI did not recognize \`$line\`, so it was cleared unrun"
        fi ;;
    esac

    # Confirm against a harness-authoritative signal, never the pane (FR-F).
    # Failing here stops the sequence: the remaining lines are never typed,
    # which is what makes a `/rename` that never lands under kind `clear` cost
    # a wrong title and nothing more.
    case "$line" in
        "/rename "*)
            submit_titled "${line#/rename }" \
                || watcher_fail "\`$line\` was typed and Entered, but the session title never changed" ;;
        /compact*|/clear*)
            submit_consumed \
                || watcher_fail "\`$line\` was typed and Entered, but no ${line%% *} followed" ;;
        *)
            submit_prompted "$line" \
                || watcher_fail "the continuation prompt was typed but three Enters did not submit it" ;;
    esac
done
