#!/usr/bin/env bash
# PreToolUse hook for Write|Edit. handoff-task.md is written only by
# handoff-checkpoint (FR3): any direct agent Write/Edit to that path is
# denied outright, cross-project or not. The activation predicate this guard
# used to check against is gone along with the wipe it protected — with no
# legitimate agent write left, the rule collapses to one invariant.
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
        "write blocked: $MATCHED_NAME outside this project's .claude/. resolved: $target; expected: $expected." \
        "write-guard: blocked $MATCHED_NAME write outside $cwd/.claude/"
fi

handoff_deny \
    "handoff-task.md is written only by handoff-checkpoint; direct Write/Edit is not allowed." \
    "write-guard: handoff-task.md is checkpoint-only"
