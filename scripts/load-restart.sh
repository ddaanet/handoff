#!/usr/bin/env bash
# SessionStart(resume): consume the armed restart and fire its continuation.
#
# Unlike load-compact.sh and load-handoff.sh, this loader never assembles or
# injects the task-frame: --resume already restores the full prior
# conversation on its own, so there is nothing for a frame to hand a
# summariser's paraphrase back to. That is the whole reason restart "costs no
# context at all" (see brief-driven-restart.md) — the only effect here is
# firing whatever continuation prompt was typed after the resume.
#
# Consuming .claude/autodrive is itself the confirmation the walker was
# waiting on for the `claude --resume` line it typed: the file disappearing
# is what submit_consumed polls for.
#
# The hook fires on every `resume` (a hand-typed --resume too), so the
# no-transition path must be silent.
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

# Only a transition in flight, and only our own kind: an armed file belongs to
# a Stop that has not fired, and a pending file of another kind is a different
# loader's to complete.
[[ "$DRIVE_STATE" == "pending" && "$DRIVE_KIND" == "restart" ]] || exit 0

# Consume unconditionally: the continuation fires at most once per resume.
rm -f "$drive"

after=( ${DRIVE_AFTER[@]+"${DRIVE_AFTER[@]}"} )

if (( ${#after[@]} == 0 )); then
    jq -nc '{systemMessage: "handoff: resumed."}'
    exit 0
fi

if [[ -z "${TMUX:-}" || -z "${TMUX_PANE:-}" ]]; then
    paste="$(printf '%s\n' "${after[@]}")"
    jq -nc --arg l "$paste" '{
        systemMessage: "handoff: resumed, but the continuation could not be typed (not in tmux); emitted to paste.",
        hookSpecificOutput: {
            hookEventName: "SessionStart",
            additionalContext: ("Present this line to the user in a fenced code block so they can paste it:\n" + $l)
        }
    }'
    exit 0
fi

PANE="$TMUX_PANE"
export HANDOFF_FAIL_FILE="$cwd/$HANDOFF_REL_DRIVE_FAILED"
HANDOFF_TRANSCRIPT="$(jq -r '.transcript_path // ""' <<<"$input")"
export HANDOFF_TRANSCRIPT
handoff_spawn_detached drive_when_idle.py "$PANE" "${after[@]}"

jq -nc --arg n "${after[0]}" --arg p "$PANE" \
    '{systemMessage: ("handoff: resumed — will run \"" + $n + "\" once the prompt is idle (tmux pane " + $p + ").")}'
