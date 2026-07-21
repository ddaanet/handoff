#!/usr/bin/env bash
# PreToolUse hook for Write|Edit.
# - handoff-task.md is skill-owned input: writes are refused until the
#   handoff:handoff skill has activated this session, and refused if the
#   resolved path is not $cwd/.claude/handoff-task.md (cross-project).
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

rc=0
handoff_match_target "$(cat)" "handoff-task.md" "$HANDOFF_REL_TASK" || rc=$?
if [[ "$rc" -eq 1 ]]; then
    exit 0
fi
if [[ "$rc" -eq 2 ]]; then
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
