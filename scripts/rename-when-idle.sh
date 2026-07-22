#!/usr/bin/env bash
# handoff watcher: wait for this tmux pane's prompt to go idle, then type
# `/rename <title>` into it. Run detached by write-rename.sh so it outlives the
# turn (the rename only lands once Claude stops and the prompt is idle).
#
# Usage: rename-when-idle.sh <pane-id> <title...>
#
# No `set -e`: a watcher must reach its watcher_fail line rather than die
# part-way through on any non-zero command — a transient tmux call, a grep
# that does not match. Under errexit that death is silent, which is the one
# outcome these scripts exist to prevent.
set -uo pipefail

PANE="${1:?pane id required}"; shift
TITLE="$*"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=_rename-lib.sh
. "$DIR/_rename-lib.sh"

wait_for_idle

# Never type over a prompt the user is editing. A bail is a non-delivery like
# any other: write-rename.sh has already told the user the rename is coming, so
# leaving silently would leave that promise standing.
snap | is_typing && watcher_fail "the user was composing a prompt, so \`/rename $TITLE\` was never typed"

# Send literally (-l) so the title is not read as tmux key names; Enter is a
# separate keystroke. Verify the title shows (status bar) and retry up to 3×.
needle="$(printf '%s' "$TITLE" | head -c 20)"
for _ in 1 2 3; do
    tmux send-keys -t "$PANE" -l "/rename $TITLE"
    tmux send-keys -t "$PANE" Enter
    sleep "$VERIFY_DELAY"
    snap | grep -Fq "$needle" && exit 0
done
watcher_fail "\`/rename $TITLE\` was typed three times and the title never appeared"
