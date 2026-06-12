#!/usr/bin/env bash
# PreToolUse hook for Write|Edit.
# - handoff-task.md is skill-owned input: writes are refused until the
#   handoff:handoff skill has activated this session, and refused if the
#   resolved path is not $cwd/.claude/handoff-task.md (cross-project).
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

handoff_hook_fields "$(cat)"
[[ -n "$HOOK_FILE_PATH" ]] || exit 0
[[ "$(basename "$HOOK_FILE_PATH")" == "handoff-task.md" ]] || exit 0

cwd="$(handoff_root "$HOOK_CWD")"

{ read -r target; read -r expected; } \
    < <(handoff_resolve "$HOOK_FILE_PATH" "$cwd/$HANDOFF_REL_TASK")

if [[ "$target" != "$expected" ]]; then
    handoff_deny \
        "write blocked: handoff-task.md outside this project's .claude/. resolved: $target; expected: $expected." \
        "write-guard: blocked handoff-task.md write outside $cwd/.claude/"
fi
if ! handoff_activated "$HOOK_TRANSCRIPT"; then
    handoff_deny \
        "handoff-task.md write blocked: handoff skill has not activated this session." \
        "write-guard: blocked handoff-task.md write before handoff activation"
fi

exit 0
