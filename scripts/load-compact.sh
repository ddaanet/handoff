#!/usr/bin/env bash
# SessionStart(compact): consume the armed compaction and fire its continuation.
# `source: "compact"` is the authoritative compaction-complete signal — no
# pane-marker scraping, and it also covers a compaction that finishes too fast
# to observe as a busy->idle transition.
#
# Consuming .claude/autodrive is itself the confirmation the walker was waiting
# on for the `/compact` line it typed: the file disappearing is what tells that
# watcher the compaction happened.
#
# The hook fires for auto-compaction too, so the no-transition path must be
# silent.
#
# The after-line is TYPED as an ordinary prompt at idle, not injected as
# additionalContext: additionalContext is context, not a prompt, and cannot
# start a turn. Typing it means it drains as its own turn and fires
# UserPromptSubmit normally. Under FR-G there may be no after-line at all — the
# prepare-only path arms the kind line alone, so the frame is injected and
# nothing is typed.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

input="$(cat)"
hook_cwd="$(jq -r '.cwd // ""' <<<"$input")"
cwd="$(handoff_root "$hook_cwd")"
[[ -n "$cwd" ]] || exit 0

drive="$cwd/$HANDOFF_REL_DRIVE"
[[ -f "$drive" ]] || exit 0

if ! handoff_drive_read "$drive"; then
    rm -f "$drive"
    jq -nc --arg e "$DRIVE_ERR" \
        '{systemMessage: ("handoff: autodrive malformed — " + $e + "; not resuming.")}'
    exit 0
fi

# Only a transition in flight is ours to complete, and only our own kind. An
# armed file belongs to a Stop that has not fired; a pending `clear` armed in
# this session and overtaken by a threshold auto-compaction would otherwise fire
# its continuation into the session the clear was meant to replace.
[[ "$DRIVE_STATE" == "pending" && "$DRIVE_KIND" == "compact" ]] || exit 0

# Consume unconditionally: the continuation fires at most once per compaction.
rm -f "$drive"

after=( ${DRIVE_AFTER[@]+"${DRIVE_AFTER[@]}"} )

# The task file and the todo remainder carry the content across the compaction;
# the typed prompt is only a handle to it. Inject the frame here so the handle
# resolves against the real thing rather than the summariser's paraphrase. Not
# consumed by reading — both stay on disk for the next
# SessionStart(startup|clear).
frame="$(handoff_frame "$cwd/$HANDOFF_REL_TASK" "$cwd/$HANDOFF_REL_TODO")" \
    || frame=""

frame_ctx() {  # $1 = extra prose appended after the frame, or empty
    jq -n --arg f "$frame" --arg x "$1" \
        'if $f == "" and $x == "" then {}
         else {hookSpecificOutput: {hookEventName: "SessionStart",
               additionalContext: ((if $f == "" then "" else $f + "\n" end) + $x)}}
         end'
}

# FR-G: nothing to type. The frame is the whole effect, which is the point of
# the prepare-only path — a hand-typed /compact re-injects nothing without it.
if (( ${#after[@]} == 0 )); then
    jq -nc --argjson c "$(frame_ctx "")" \
        '{systemMessage: "handoff: compacted — frame re-injected."} + $c'
    exit 0
fi

if [[ -z "${TMUX:-}" || -z "${TMUX_PANE:-}" ]]; then
    paste="$(printf '%s\n' "${after[@]}")"
    jq -nc --argjson c "$(frame_ctx "Compaction finished, but the continuation prompt could not be typed (not in tmux). Present this line to the user in a fenced code block so they can paste it:
$paste")" \
        '{systemMessage: "handoff: not in tmux — continuation not typed; emitted to paste."} + $c'
    exit 0
fi

PANE="$TMUX_PANE"
# See stop-drive.sh: the detached walker's exit status goes nowhere, so give it
# somewhere to record a non-delivery.
export HANDOFF_FAIL_FILE="$cwd/$HANDOFF_REL_DRIVE_FAILED"
# The walker confirms delivery by watching this session's transcript for the
# accepted prompt (submit_prompted), which tolerates a queued submit that shows
# no spinner yet. Every hook payload carries transcript_path.
HANDOFF_TRANSCRIPT="$(jq -r '.transcript_path // ""' <<<"$input")"
export HANDOFF_TRANSCRIPT
handoff_spawn_detached drive-when-idle.sh "$PANE" "${after[@]}"

jq -nc --arg n "${after[0]}" --arg p "$PANE" --argjson c "$(frame_ctx "")" \
    '{systemMessage: ("handoff: compacted — will resume with \"" + $n + "\" once the prompt is idle (tmux pane " + $p + ").")} + $c'
