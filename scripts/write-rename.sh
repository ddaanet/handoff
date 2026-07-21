#!/usr/bin/env bash
# PostToolUse(Write|Edit): when the agent writes .claude/autorename, read the
# title, spawn the rename watcher, and delete the file. Running as a hook (not
# via the Bash tool) means no sandbox restriction on the tmux socket.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

handoff_match_target "$(cat)" "autorename" "$HANDOFF_REL_RENAME" || exit 0
[[ -f "$target" ]] || exit 0
title="$(tr -s '[:space:]' ' ' < "$target")"
title="${title## }"; title="${title%% }"
rm -f "$target"

if [[ -z "${title// /}" ]]; then
    jq -nc '{systemMessage: "handoff: autorename file was empty; session not renamed."}'
    exit 0
fi

if [[ -z "${TMUX:-}" || -z "${TMUX_PANE:-}" ]]; then
    jq -nc --arg t "$title" '{
        systemMessage: ("handoff: not in tmux — paste to rename: /rename " + $t),
        hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: ("Session auto-rename is unavailable (not in tmux). Present this line to the user in a fenced code block so they can paste it:\n/rename " + $t)
        }
    }'
    exit 0
fi

PANE="$TMUX_PANE"
handoff_spawn_detached rename-when-idle.sh "$PANE" "$title"
jq -nc --arg t "$title" --arg p "$PANE" \
    '{systemMessage: ("handoff: will rename to \"" + $t + "\" once prompt is idle (tmux pane " + $p + ").")}'
