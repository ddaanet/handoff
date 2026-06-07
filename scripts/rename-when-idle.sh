#!/usr/bin/env bash
# handoff watcher: wait for this tmux pane's prompt to go idle, then type
# `/rename <title>` into it. Run detached by write-rename.sh so it outlives the
# turn (the rename only lands once Claude stops and the prompt is idle).
#
# Usage: rename-when-idle.sh <pane-id> <title...>
#
# No `set -e`: arithmetic `(( ))` returning 0 would otherwise abort the loop.
set -uo pipefail

PANE="${1:?pane id required}"; shift
TITLE="$*"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=_rename-lib.sh
. "$DIR/_rename-lib.sh"

# Tunables (overridden by the tests for speed).
TIMEOUT="${AUTONAME_TIMEOUT:-30}"
POLL="${AUTONAME_POLL:-0.1}"
VERIFY_DELAY="${AUTONAME_VERIFY_DELAY:-0.5}"

snap() { tmux capture-pane -p -t "$PANE" 2>/dev/null | tail -n 40; }

# Wait until idle has been stable for ~3 consecutive polls, up to TIMEOUT.
deadline=$((SECONDS + TIMEOUT)); stable=0
while (( SECONDS < deadline )); do
    if snap | is_busy; then stable=0; sleep "$POLL"; continue; fi
    stable=$((stable + 1))
    (( stable >= 3 )) && break
    sleep "$POLL"
done

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
