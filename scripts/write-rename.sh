#!/usr/bin/env bash
# PostToolUse(Write|Edit): when the agent writes .claude/autorename, read the
# title, spawn the rename watcher, and delete the file. Running as a hook (not
# via the Bash tool) means no sandbox restriction on the tmux socket.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

script_dir="$(cd "$(dirname "$0")" && pwd)"

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // ""' <<<"$input")"
[[ -n "$file_path" ]] || exit 0
[[ "$(basename "$file_path")" == "autorename" ]] || exit 0

cwd="$(handoff_root "$(jq -r '.cwd // ""' <<<"$input")")"
[[ -n "$cwd" ]] || exit 0

{ read -r target; read -r expected; } < <(handoff_resolve "$file_path" "$cwd/$HANDOFF_REL_RENAME")
[[ "$target" == "$expected" ]] || exit 0

[[ -f "$target" ]] || exit 0
title="$(tr -s '[:space:]' ' ' < "$target")"
title="${title## }"; title="${title%% }"
rm -f "$target"

if [[ -z "${title// /}" ]]; then
    jq -nc '{systemMessage: "handoff: autorename file was empty; session not renamed."}'
    exit 0
fi

if [[ -z "${TMUX:-}" || -z "${TMUX_PANE:-}" ]]; then
    jq -nc --arg t "$title" \
        '{systemMessage: ("handoff: not in tmux — paste to rename: /rename " + $t)}'
    exit 0
fi

PANE="$TMUX_PANE"
setsid bash "$script_dir/rename-when-idle.sh" "$PANE" "$title" >/dev/null 2>&1 &
disown 2>/dev/null || true
jq -nc --arg t "$title" --arg p "$PANE" \
    '{systemMessage: ("handoff: will rename to \"" + $t + "\" once prompt is idle (tmux pane " + $p + ").")}'
