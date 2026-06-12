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

handoff_hook_fields "$(cat)"
[[ -n "$HOOK_FILE_PATH" ]] || exit 0
[[ "$(basename "$HOOK_FILE_PATH")" == "handoff-task.md" ]] || exit 0

cwd="$(handoff_root "$HOOK_CWD")"

{ read -r target; read -r expected; } \
    < <(handoff_resolve "$HOOK_FILE_PATH" "$cwd/$HANDOFF_REL_TASK")

if [[ "$target" == "$expected" ]] && ! handoff_activated "$HOOK_TRANSCRIPT"; then
    handoff_deny \
        "handoff-task.md read blocked: handoff skill has not activated this session." \
        "read-guard: blocked handoff-task.md read before handoff activation"
fi

exit 0
