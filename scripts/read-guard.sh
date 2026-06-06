#!/usr/bin/env bash
# PreToolUse hook for Read.
# - handoff-task.md: reads are refused until the handoff:handoff skill
#   has activated this session.
# Anything else passes through (the Read matcher cannot filter by path).
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // ""' <<<"$input")"
[[ -n "$file_path" ]] || exit 0

base="$(basename "$file_path")"
[[ "$base" == "handoff-task.md" ]] || exit 0

cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
transcript="$(jq -r '.transcript_path // ""' <<<"$input")"

{ read -r target; read -r exp_task; } \
    < <(handoff_resolve "$file_path" "$cwd/$HANDOFF_REL_TASK")

if [[ "$target" == "$exp_task" ]] && ! handoff_activated "$transcript"; then
    handoff_deny \
        "handoff-task.md read blocked: handoff skill has not activated this session." \
        "read-guard: blocked handoff-task.md read before handoff activation"
fi

exit 0
