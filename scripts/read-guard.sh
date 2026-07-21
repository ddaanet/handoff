#!/usr/bin/env bash
# PreToolUse hook for Read.
# - handoff-task.md: reads are refused until the handoff:handoff skill
#   has activated this session. Only this project's file is gated;
#   cross-project handoff-task.md reads pass through (contrast:
#   write-guard.sh denies them).
# Anything else passes through (the Read matcher cannot filter by path).
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

# Cross-project reads (match rc 2) pass through like any other file.
handoff_match_target "$(cat)" "handoff-task.md" "$HANDOFF_REL_TASK" || exit 0

if ! handoff_activated "$HOOK_TRANSCRIPT"; then
    handoff_deny \
        "handoff-task.md read blocked: handoff skill has not activated this session." \
        "read-guard: blocked handoff-task.md read before handoff activation"
fi

exit 0
