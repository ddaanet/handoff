#!/usr/bin/env bash
# SessionStart(compact): fire the continuation. `source: "compact"` is the
# authoritative compaction-complete signal — no pane-marker scraping, and it
# also covers a compaction that finishes too fast to observe as a busy->idle
# transition.
#
# The hook fires for auto-compaction too, so the no-pending path must be silent.
#
# Line 2 is TYPED as an ordinary prompt at idle, not injected as
# additionalContext: additionalContext is context, not a prompt, and cannot
# start a turn. Typing it means it drains as its own turn and fires
# UserPromptSubmit normally.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

input="$(cat)"
hook_cwd="$(jq -r '.cwd // ""' <<<"$input")"
cwd="$(handoff_root "$hook_cwd")"
[[ -n "$cwd" ]] || exit 0

pending="$cwd/$HANDOFF_REL_COMPACT_PENDING"
[[ -f "$pending" ]] || exit 0

if ! handoff_compact_read "$pending"; then
    rm -f "$pending"
    jq -nc --arg e "$COMPACT_ERR" \
        '{systemMessage: ("handoff: autocompact.pending malformed — " + $e + "; not resuming.")}'
    exit 0
fi

# Consume unconditionally: the continuation fires at most once per compaction.
rm -f "$pending"

# The task file and the todo remainder carry the content across the compaction;
# the typed prompt is only a handle to it. Inject the frame here so the handle
# resolves against the real thing rather than the summariser's paraphrase. Not
# consumed by reading — both stay on disk for the next
# SessionStart(startup|clear).
frame="$(handoff_frame "$cwd/$HANDOFF_REL_TASK" "$cwd/$HANDOFF_REL_TODO")" \
    || frame=""

if [[ -z "${TMUX:-}" || -z "${TMUX_PANE:-}" ]]; then
    jq -nc --arg n "$COMPACT_L2" --arg f "$frame" '{
        systemMessage: "handoff: not in tmux — continuation not typed; emitted to paste.",
        hookSpecificOutput: {
            hookEventName: "SessionStart",
            additionalContext: (
                (if $f == "" then "" else $f + "\n" end)
                + "Compaction finished, but the continuation prompt could not be typed (not in tmux). Present this line to the user in a fenced code block so they can paste it:\n"
                + $n)
        }
    }'
    exit 0
fi

PANE="$TMUX_PANE"
# See stop-compact.sh: the detached watcher's exit status goes nowhere, so give
# it somewhere to record a non-delivery.
export HANDOFF_FAIL_FILE="$cwd/$HANDOFF_REL_COMPACT_FAILED"
# The watcher confirms delivery by watching this session's transcript for the
# accepted prompt (submit_confirmed_or_fail), which tolerates a queued submit
# that shows no spinner yet. Every hook payload carries transcript_path.
HANDOFF_TRANSCRIPT="$(jq -r '.transcript_path // ""' <<<"$input")"
export HANDOFF_TRANSCRIPT
handoff_spawn_detached continue-when-idle.sh "$PANE" "$COMPACT_L2"

jq -nc --arg n "$COMPACT_L2" --arg p "$PANE" --arg f "$frame" \
    '{systemMessage: ("handoff: compacted — will resume with \"" + $n + "\" once the prompt is idle (tmux pane " + $p + ").")}
     + (if $f == "" then {}
        else {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $f}}
        end)'
