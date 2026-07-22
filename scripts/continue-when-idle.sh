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
# No `set -e`: the sourced scaffold's `(( ))` arithmetic (wait_for_idle) returning 0 would abort under errexit.
set -uo pipefail

PANE="${1:?pane id required}"; shift
LINE2="$*"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=_rename-lib.sh
. "$DIR/_rename-lib.sh"

wait_for_idle

snap | is_typing && watcher_fail "the user was composing a prompt, so the continuation was never typed"

tmux send-keys -t "$PANE" -l "$LINE2"

# Load-bearing settle. An Enter sent immediately after a long literal send lands
# inside the TUI's paste window and is absorbed as a line break, not a submit.
# compact-when-idle.sh gets this gap for free from its recognition readback;
# line 2 has no readback, so the gap has to be explicit. Do not remove it as
# redundant — the prose path has no other protection.
sleep "$VERIFY_DELAY"

# Confirm via the transcript, not is_busy: this fires right after compaction, so
# the submit is often queued behind the session's post-compaction settling —
# accepted at once, but no spinner until the queued turn starts seconds later.
# is_busy would false-fail it. HANDOFF_TRANSCRIPT is exported by load-compact.sh.
submit_confirmed_or_fail "$LINE2" "the continuation prompt was typed but three Enters did not submit it"
