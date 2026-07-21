#!/usr/bin/env bash
# handoff watcher: wait for this tmux pane's prompt to go idle, then type
# `/rename <title>` into it. Run detached by write-rename.sh so it outlives the
# turn (the rename only lands once Claude stops and the prompt is idle).
#
# Usage: rename-when-idle.sh <pane-id> <title...>
#
# No `set -e`: the sourced scaffold's `(( ))` arithmetic (wait_for_idle) returning 0 would abort under errexit.
set -uo pipefail

PANE="${1:?pane id required}"; shift
TITLE="$*"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=_rename-lib.sh
. "$DIR/_rename-lib.sh"

wait_for_idle

# Never type over a prompt the user is editing.
snap | is_typing && exit 0

# Send literally (-l) so the title is not read as tmux key names; Enter is a
# separate keystroke. Verify the title shows (status bar) and retry up to 3×.
needle="$(printf '%s' "$TITLE" | head -c 20)"
for _ in 1 2 3; do
    tmux send-keys -t "$PANE" -l "/rename $TITLE"
    tmux send-keys -t "$PANE" Enter
    sleep "$VERIFY_DELAY"
    snap | grep -Fq "$needle" && exit 0
done
exit 1
