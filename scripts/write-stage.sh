#!/usr/bin/env bash
# PostToolUse hook for Write|Edit.
# When the agent writes this project's .claude/handoff-task.md or
# .claude/handoff-todo.md, stage it with `git add -f` so the versioned task
# trail rides the user's next commit. Both halves of the frame are tracked on
# the same terms: the todo file is overflow from the task file, and a trail
# whose decomposition is untracked records only half of what was in flight.
# No extraction, no generated file — the frame is assembled at read-time by
# load-handoff.sh.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

handoff_match_target "$(cat)" \
    "handoff-task.md" "$HANDOFF_REL_TASK" \
    "handoff-todo.md" "$HANDOFF_REL_TODO" || exit 0
[[ -f "$target" ]] || exit 0

if git -C "$cwd" add -f "$target" 2>/dev/null; then
    agent_ctx="$MATCHED_NAME staged (git add -f) and version-tracked. The task frame enters git history paired with this handoff's gitlore memory commit, which supplies the durable context that makes the frame meaningful."
    jq -nc \
        --arg c "$agent_ctx" \
        '{systemMessage: "handoff — staged for commit", hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
fi
