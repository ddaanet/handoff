#!/usr/bin/env bash
# PreToolUse hook for Write|Edit.
# - this project's .claude/handoff.md is hook-owned output: agent
#   writes are refused.
# - handoff-task.md is skill-owned input: writes are refused until the
#   handoff:handoff skill has activated this session, and refused if the
#   resolved path is not $cwd/.claude/handoff-task.md (cross-project).
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // ""' <<<"$input")"
[[ -n "$file_path" ]] || exit 0

base="$(basename "$file_path")"
[[ "$base" == "handoff.md" || "$base" == "handoff-task.md" ]] || exit 0

cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
transcript="$(jq -r '.transcript_path // ""' <<<"$input")"

{ read -r target; read -r exp_task; read -r exp_out; } \
    < <(handoff_resolve "$file_path" "$cwd/$HANDOFF_REL_TASK" "$cwd/$HANDOFF_REL_OUT")

# This project's handoff.md: hook-owned output, never agent-written.
if [[ "$target" == "$exp_out" ]]; then
    handoff_deny \
        "handoff.md is generated and read by the handoff hooks; agent writes are refused." \
        "write-guard: blocked agent write to hook-owned handoff.md"
fi

# handoff-task.md: must resolve into this project, and only after the
# skill has activated this session.
if [[ "$base" == "handoff-task.md" ]]; then
    if [[ "$target" != "$exp_task" ]]; then
        handoff_deny \
            "write blocked: handoff-task.md outside this project's .claude/. resolved: $target; expected: $exp_task." \
            "write-guard: blocked handoff-task.md write outside $cwd/.claude/"
    fi
    if ! handoff_activated "$transcript"; then
        handoff_deny \
            "handoff-task.md write blocked: handoff skill has not activated this session." \
            "write-guard: blocked handoff-task.md write before handoff activation"
    fi
fi

exit 0
