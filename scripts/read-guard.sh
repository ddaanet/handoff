#!/usr/bin/env bash
# PreToolUse hook for Read.
# - handoff-task.md and handoff-todo.md: reads are refused until the
#   handoff:handoff or handoff:precompact skill has activated this session.
#   Both are injected into context at SessionStart, so a read before then is
#   pointless as well as premature. Only this project's files are gated;
#   cross-project reads pass through (contrast: write-guard.sh denies them).
# Anything else passes through (the Read matcher cannot filter by path).
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

# Cross-project reads (match rc 2) pass through like any other file.
handoff_match_target "$(cat)" \
    "handoff-task.md" "$HANDOFF_REL_TASK" \
    "handoff-todo.md" "$HANDOFF_REL_TODO" || exit 0

if ! handoff_activated "$HOOK_TRANSCRIPT"; then
    handoff_deny \
        "$MATCHED_NAME read blocked: handoff skill has not activated this session." \
        "read-guard: blocked $MATCHED_NAME read before handoff activation"
fi

exit 0
