#!/usr/bin/env bash
# PreToolUse hook for Read.
# - this project's .claude/handoff.md is hook-owned: reads are refused
#   always.
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
[[ "$base" == "handoff.md" || "$base" == "handoff-task.md" ]] || exit 0

cwd="$(jq -r '.cwd // ""' <<<"$input")"
[[ -n "$cwd" ]] || cwd="$PWD"
transcript="$(jq -r '.transcript_path // ""' <<<"$input")"

{ read -r target; read -r exp_task; read -r exp_out; } \
    < <(handoff_resolve "$file_path" "$cwd/$HANDOFF_REL_TASK" "$cwd/$HANDOFF_REL_OUT")

# This project's handoff.md: hook-owned, never agent-read.
if [[ "$target" == "$exp_out" ]]; then
    handoff_deny \
        "handoff.md is generated and read by the handoff hooks; agent reads are refused." \
        "read-guard: blocked agent read of hook-owned handoff.md"
fi

if [[ "$target" == "$exp_task" ]] && ! handoff_activated "$transcript"; then
    handoff_deny \
        "handoff-task.md read blocked: handoff skill has not activated this session." \
        "read-guard: blocked handoff-task.md read before handoff activation"
fi

exit 0
