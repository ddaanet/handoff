#!/usr/bin/env bash
# SessionStart hook for handoff loading. Fires on `startup` and `clear`
# (see hooks/hooks.json), and does two things:
#
#   - assembles the frame in memory — a timestamp header plus the inlined
#     agent-authored task file and todo remainder — and emits it via
#     hookSpecificOutput.additionalContext so the fresh agent sees the handoff
#     in its input for this turn, plus a curt systemMessage with content size
#     and age;
#   - on `clear`, consumes an armed transition of kind `clear` and spawns the
#     walker for the lines to type into this new session. Consuming
#     .claude/autodrive.pending is itself the confirmation the walker was
#     waiting on for the `/clear` line it typed.
#
# Those two are independent: a driven clear whose task file is empty must still
# continue, so the consume and the spawn come BEFORE the no-frame exit. Silent
# only when there is nothing to inject and nothing was armed.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

{ read -r hook_cwd; read -r hook_event; read -r hook_source; read -r hook_transcript; } < <(
    jq -r '.cwd // "", .hook_event_name // "SessionStart", .source // "", .transcript_path // ""'
)
cwd="$(handoff_root "$hook_cwd")"
[[ -n "$cwd" ]] || exit 0

notes=()   # systemMessage fragments from the transition, if any
extra=""   # additionalContext appended after the frame

# `/clear` mints a new session and a new transcript, and this payload reports
# both — measured 2026-07-30, see the design doc. So the after-line confirms
# against .transcript_path here exactly as it does at the compact boundary.
pending="$cwd/$HANDOFF_REL_DRIVE_PENDING"
if [[ "$hook_source" == "clear" && -f "$pending" ]]; then
    if ! handoff_drive_read "$pending"; then
        rm -f "$pending"
        notes+=("autodrive.pending malformed — $DRIVE_ERR; not resuming")
    elif [[ "$DRIVE_KIND" == "clear" ]]; then
        # Each loader consumes only its own kind, so a compact armed in the
        # outgoing session is left for SessionStart(compact) — or, failing
        # that, for the walker's own timeout to report.
        rm -f "$pending"
        after=( ${DRIVE_AFTER[@]+"${DRIVE_AFTER[@]}"} )
        if (( ${#after[@]} > 0 )); then
            if [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]]; then
                # The walker is detached, so a failed delivery has no way back
                # to the agent; this hook owns the path it records at.
                export HANDOFF_FAIL_FILE="$cwd/$HANDOFF_REL_DRIVE_FAILED"
                export HANDOFF_TRANSCRIPT="$hook_transcript"
                handoff_spawn_detached drive-when-idle.sh "$TMUX_PANE" "${after[@]}"
                notes+=("cleared — will resume with \"${after[0]}\" once the prompt is idle (tmux pane $TMUX_PANE)")
            else
                extra="The session was cleared, but the continuation prompt could not be typed (not in tmux). Present this line to the user in a fenced code block so they can paste it:
$(printf '%s\n' "${after[@]}")"
                notes+=("not in tmux — continuation not typed; emitted to paste")
            fi
        fi
    fi
fi

# The frame is the header plus the agent-authored files inlined verbatim, and
# it gates itself: either file alone is enough, neither means nothing to
# inject. The prior session's working set is served by the harness's own
# gitStatus block, not reproduced here (see
# docs/changelog/2026-07-17-task-frame-drops-transcript.md).
task="$cwd/$HANDOFF_REL_TASK"
todo="$cwd/$HANDOFF_REL_TODO"
assembled="$(handoff_frame "$task" "$todo")" || assembled=""

if [[ -n "$assembled" ]]; then
    bytes=${#assembled}
    if (( bytes < 1024 )); then
        size="${bytes} B"
    else
        size=$(awk -v b="$bytes" 'BEGIN { printf "%.1f KiB", b/1024 }')
    fi

    # Age of the frame is the newest of whichever files it drew on — the frame
    # assembled, so at least one of them exists.
    mtime=$(python3 -c 'import os,sys
print(int(max(os.path.getmtime(p) for p in sys.argv[1:] if os.path.exists(p))))' \
        "$task" "$todo")
    now=$(date +%s)
    delta=$(( now - mtime ))
    if (( delta < 60 )); then age="just now"
    elif (( delta < 3600 )); then age="$((delta / 60))m ago"
    elif (( delta < 86400 )); then age="$((delta / 3600))h ago"
    else age="$((delta / 86400))d ago"
    fi
    notes=("loaded — ${size}, saved ${age}" ${notes[@]+"${notes[@]}"})
fi

(( ${#notes[@]} > 0 )) || exit 0

printf -v msg '%s; ' "${notes[@]}"

jq -nc \
    --arg m "handoff: ${msg%; }" \
    --arg c "$assembled" \
    --arg x "$extra" \
    --arg e "$hook_event" \
    '{systemMessage: $m}
     + (if $c == "" and $x == "" then {}
        else {hookSpecificOutput: {hookEventName: $e,
              additionalContext: ((if $c == "" then "" else $c + "\n" end) + $x)}}
        end)'
