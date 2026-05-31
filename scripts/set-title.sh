#!/usr/bin/env bash
# handoff: set the current Claude Code session title.
#
# Usage: set-title.sh <title...>
#
# There is no agent-side API to rename a session and hooks cannot run slash
# commands; the only reliable, exact rename is the user typing
# `/rename <title>`. Inside tmux we type it for them: launch a detached watcher
# (rename-when-idle.sh) that waits for the prompt to be idle, then send-keys the
# command into this pane. Outside tmux there is nothing to drive, so we print a
# `/rename` line to paste. See autoname DESIGN.md.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TITLE="$*"
if [[ -z "${TITLE// /}" ]]; then
    echo "handoff: no title provided" >&2
    exit 2
fi

# $TMUX and $TMUX_PANE are set by tmux for every process running in a pane.
if [[ -z "${TMUX:-}" || -z "${TMUX_PANE:-}" ]]; then
    cat <<EOF
handoff: not in a tmux session, cannot rename automatically.
Run Claude Code inside tmux for hands-free renaming. Meanwhile, paste this:

/rename ${TITLE}
EOF
    exit 0
fi

PANE="$TMUX_PANE"
setsid bash "$DIR/rename-when-idle.sh" "$PANE" "$TITLE" >/dev/null 2>&1 &
disown 2>/dev/null || true
echo "handoff: will rename this session to \"$TITLE\" once the prompt is idle (tmux pane $PANE)."
