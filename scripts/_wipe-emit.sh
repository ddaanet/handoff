#!/usr/bin/env bash
# Shared wipe+emit for the two handoff activation hooks. Invoked by
# skill-pre-hook.sh (PreToolUse) and prompt-pre-hook.sh
# (UserPromptSubmit) once each has matched its activation condition.
# Removes any prior handoff files in $cwd/.claude/ and, if anything
# was removed, emits the dual-channel JSON on stdout: systemMessage
# for the user and hookSpecificOutput.additionalContext for the agent
# (so the agent knows the wipe happened and doesn't redundantly
# verify with ls/cat). hookEventName in the output must match the
# event of the calling hook.
#
# Usage: _wipe-emit.sh <session-cwd> <hook_event_name>
# <session-cwd> is the raw hook-input .cwd; the effective root (worktree
# root or CLAUDE_PROJECT_DIR) is derived here via handoff_root.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

cwd="$(handoff_root "${1:-}")"
hook_event="${2:?hook_event_name required}"

mkdir -p "$cwd/.claude"

task="$cwd/$HANDOFF_REL_TASK"
removed=()
task_removed=0
for f in "$task" "$cwd/.claude/handoff.md" "$cwd/.claude/autorename"; do
    if [[ -f "$f" ]]; then
        rm -f "$f"
        removed+=("$(basename "$f")")
        [[ "$f" == "$task" ]] && task_removed=1
    fi
done

# handoff-task.md is the one tracked artifact (write-stage.sh force-adds it).
# Stage its deletion too, mirroring the write-side `git add -f`, so a
# finalized/transitioned task rides the user's next commit instead of
# lingering as an unstaged removal. `git add` on the now-absent path stages
# the deletion of a tracked file; suppressed no-op when it was never tracked
# or $cwd isn't a git repo.
if (( task_removed )); then
    git -C "$cwd" add -f "$task" 2>/dev/null || true
fi

(( ${#removed[@]} > 0 )) || exit 0

# IFS only uses its first character to join "${arr[*]}", so `IFS=', '`
# joins on `,` alone. Build the comma-space list with printf instead.
printf -v files '%s, ' "${removed[@]}"
files="${files%, }"
msg="handoff: wiped prior $files"
agent_ctx="handoff activation hook wiped prior handoff files ($files); they are absent."
jq -nc \
    --arg m "$msg" \
    --arg c "$agent_ctx" \
    --arg e "$hook_event" \
    '{systemMessage: $m, hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
