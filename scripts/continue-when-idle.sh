#!/usr/bin/env bash
# handoff watcher: wait for this tmux pane's prompt to go idle, then type the
# continuation prompt into it. Run detached by load-compact.sh from
# SessionStart(compact), i.e. after compaction has already completed.
#
# Usage: continue-when-idle.sh <pane-id> <line2...>
#
# No recognition check, unlike compact-when-idle.sh: line 2 is prose, and prose
# submitted at idle is the safe class. (Prose typed MID-turn is the dangerous
# one — it is injected into the running turn — which is precisely why this runs
# off a harness-authoritative hook rather than a pane-polling watcher.)
#
# No `set -e`: arithmetic `(( ))` returning 0 would otherwise abort the loop.
set -uo pipefail

PANE="${1:?pane id required}"; shift
LINE2="$*"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=_rename-lib.sh
. "$DIR/_rename-lib.sh"

TIMEOUT="${AUTONAME_TIMEOUT:-30}"
POLL="${AUTONAME_POLL:-0.1}"
VERIFY_DELAY="${AUTONAME_VERIFY_DELAY:-0.5}"

# Visible pane only — see compact-when-idle.sh.
snap() { tmux capture-pane -p -t "$PANE" 2>/dev/null | tail -n 40; }

deadline=$((SECONDS + TIMEOUT)); stable=0
while (( SECONDS < deadline )); do
    if snap | is_busy; then stable=0; sleep "$POLL"; continue; fi
    stable=$((stable + 1))
    (( stable >= 3 )) && break
    sleep "$POLL"
done

snap | is_typing && watcher_fail "the user was composing a prompt, so the continuation was never typed"

tmux send-keys -t "$PANE" -l "$LINE2"

# Load-bearing settle. An Enter sent immediately after a long literal send lands
# inside the TUI's paste window and is absorbed as a line break, not a submit.
# compact-when-idle.sh gets this gap for free from its recognition readback;
# line 2 has no readback, so the gap has to be explicit. Do not remove it as
# redundant — the prose path has no other protection.
sleep "$VERIFY_DELAY"

# Confirm on is_busy — the turn actually started. `is_typing` is the wrong
# signal: it inspects only the last ❯ line, so an absorbed Enter leaves a
# multi-line composer that reads as empty and fakes a successful submit.
for _ in 1 2 3; do
    tmux send-keys -t "$PANE" Enter
    sleep "$VERIFY_DELAY"
    snap | is_busy && exit 0
done
watcher_fail "the continuation prompt was typed but three Enters did not submit it"
