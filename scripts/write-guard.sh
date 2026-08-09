#!/usr/bin/env bash
# PreToolUse hook for Write|Edit. Two files are written only by
# handoff-checkpoint: handoff-task.md (FR3) and the autodrive sentinel, which
# the checkpoint composes from the payload's transition fields and reads back
# through the parser. Any direct agent Write/Edit to either is denied outright,
# cross-project or not. With no agent writer left, the sentinel needs no
# PostToolUse validator and no arm-only rule — both had the agent's pen as their
# only subject.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

rc=0
handoff_match_target "$(cat)" \
    "handoff-task.md" "$HANDOFF_REL_TASK" \
    "autodrive" "$HANDOFF_REL_DRIVE" || rc=$?
if [[ "$rc" -eq 1 ]]; then
    exit 0
fi
if [[ "$rc" -eq 2 ]]; then
    handoff_deny \
        "write blocked: $MATCHED_NAME outside this project's .claude/. resolved: $target; expected: $expected." \
        "write-guard: blocked $MATCHED_NAME write outside $cwd/.claude/"
fi

handoff_deny \
    "$MATCHED_NAME is written only by handoff-checkpoint; direct Write/Edit is not allowed." \
    "write-guard: $MATCHED_NAME is checkpoint-only"
