#!/usr/bin/env bash
# Stop: arm the driven transition. Fires when the main loop has actually
# finished the turn — the only point at which typing a slash command means what
# this design assumes. A watcher spawned mid-turn has no safe idle window to
# find (see docs/changelog/2026-07-19-mid-turn-tui-input-taxonomy.md).
#
# Stop fires on every turn, so the no-file path must be silent and cheap.
# Stop does NOT fire on an Esc interrupt, so an interrupted turn cannot arm a
# transition — but the file it wrote outlives it, and a later Stop would arm
# that. Existence alone is therefore not enough evidence to arm on; what makes
# it enough is report-watcher-failure.sh sweeping any autodrive still visible
# at the next UserPromptSubmit, so one reaching this hook is always the current
# turn's own.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

# Stop input carries no tool_input; .cwd anchors the root, and
# .transcript_path is what a /rename line confirms itself against.
{ read -r hook_cwd; read -r hook_transcript; } < <(
    jq -r '.cwd // "", .transcript_path // ""'
)
cwd="$(handoff_root "$hook_cwd")"
[[ -n "$cwd" ]] || exit 0

armed="$cwd/$HANDOFF_REL_DRIVE"
pending="$cwd/$HANDOFF_REL_DRIVE_PENDING"

[[ -f "$armed" ]] || exit 0

if ! handoff_drive_read "$armed"; then
    # write-drive.sh already told the agent in-turn; consuming the file here
    # stops the same complaint from repeating at every subsequent Stop.
    rm -f "$armed"
    jq -nc --arg e "$DRIVE_ERR" \
        '{systemMessage: ("handoff: autodrive malformed — " + $e + "; discarded, transition not armed.")}'
    exit 0
fi

# Consume BEFORE spawning: a later Stop in this session must not re-arm. A kind
# with a confirming SessionStart becomes the .pending file that loader consumes;
# `rename` has no loader, so nothing would ever clear a .pending for it.
if handoff_drive_has_source "$DRIVE_KIND"; then
    mv -f "$armed" "$pending"
else
    rm -f "$armed"
fi

before=( ${DRIVE_BEFORE[@]+"${DRIVE_BEFORE[@]}"} )
after=( ${DRIVE_AFTER[@]+"${DRIVE_AFTER[@]}"} )

# FR-G: an empty sequence arms nothing and spawns nothing. The .pending file
# alone is the whole effect — it is the loader's signal that this compaction
# was expected, and therefore that the frame belongs in it.
if (( ${#before[@]} == 0 )); then
    jq -nc --arg k "$DRIVE_KIND" \
        '{systemMessage: ("handoff: prepared for " + $k + "; nothing to type, frame will be re-injected.")}'
    exit 0
fi

if [[ -z "${TMUX:-}" || -z "${TMUX_PANE:-}" ]]; then
    rm -f "$pending"
    paste="$(printf '%s\n' "${before[@]}" ${after[@]+"${after[@]}"})"
    jq -nc --arg l "$paste" '{
        systemMessage: "handoff: not in tmux — transition not driven; lines emitted to paste.",
        hookSpecificOutput: {
            hookEventName: "Stop",
            additionalContext: ("Driving the transition is unavailable (not in tmux). Present these lines to the user in a fenced code block, to run in order:\n" + $l)
        }
    }'
    exit 0
fi

PANE="$TMUX_PANE"
# The watcher is detached, so a failed delivery has no way back to the agent.
# Hand it the path to drop a reason at; report-watcher-failure.sh picks it up.
# The hook owns the path — the watcher stays ignorant of the layout.
export HANDOFF_FAIL_FILE="$cwd/$HANDOFF_REL_DRIVE_FAILED"
# Same arrangement for the other direction, one export per confirmation
# primitive the walker may need: /compact and /clear confirm by this file
# disappearing, which the transition's own SessionStart is what does, and
# /rename confirms by a custom-title entry in this session's transcript.
export HANDOFF_PENDING_FILE="$pending"
export HANDOFF_TRANSCRIPT="$hook_transcript"
handoff_spawn_detached drive-when-idle.sh "$PANE" "${before[@]}"

jq -nc --arg p "$PANE" --arg l "${before[0]}" \
    '{systemMessage: ("handoff: will run " + $l + " once the prompt is idle (tmux pane " + $p + ").")}'
