#!/usr/bin/env bash
# PreToolUse hook for Write|Edit.
# - handoff-task.md and handoff-todo.md are skill-owned: writes are refused
#   until the handoff:handoff or handoff:precompact skill has activated this
#   session, and refused if the resolved path is not $cwd/.claude/<file>
#   (cross-project).
# The todo file is gated for the same reason the task file is: the defect that
# motivated these guards was the agent co-opting a handoff file as a general
# scratch/todo file before any skill had run. Shipping an actual todo file
# without the gate would reopen exactly that.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

rc=0
handoff_match_target "$(cat)" \
    "handoff-task.md" "$HANDOFF_REL_TASK" \
    "handoff-todo.md" "$HANDOFF_REL_TODO" || rc=$?
if [[ "$rc" -eq 1 ]]; then
    exit 0
fi
if [[ "$rc" -eq 2 ]]; then
    handoff_deny \
        "write blocked: $MATCHED_NAME outside this project's .claude/. resolved: $target; expected: $expected." \
        "write-guard: blocked $MATCHED_NAME write outside $cwd/.claude/"
fi
if ! handoff_activated "$HOOK_TRANSCRIPT"; then
    handoff_deny \
        "$MATCHED_NAME write blocked: handoff skill has not activated this session." \
        "write-guard: blocked $MATCHED_NAME write before handoff activation"
fi

exit 0
