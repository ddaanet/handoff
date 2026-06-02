#!/usr/bin/env bash
# Shared wipe+emit for the two handoff activation hooks. Invoked by
# skill-pre-hook.sh (PreToolUse) and prompt-pre-hook.sh
# (UserPromptSubmit) once each has matched its activation condition.
# Removes any prior handoff files and, if anything was removed, emits
# the dual-channel JSON on stdout: systemMessage for the user and
# hookSpecificOutput.additionalContext for the agent (so the agent
# knows the wipe happened and doesn't redundantly verify with ls/cat).
# hookEventName in the output must match the event of the calling hook.
# When gitlore is active the task file lives in the memory root; this
# script detects that via handoff_maybe_use_gitlore and, when the path
# differs from the default, appends the target path to additionalContext
# so the skill can write to the right location.
#
# Usage: _wipe-emit.sh <cwd> <hook_event_name>
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

cwd="${1:?cwd required}"
hook_event="${2:?hook_event_name required}"

handoff_maybe_use_gitlore "$cwd"

mkdir -p "$cwd/.claude"

removed=()
for f in "$cwd/$HANDOFF_REL_TASK" "$cwd/$HANDOFF_REL_OUT" "$cwd/$HANDOFF_REL_RENAME"; do
    if [[ -f "$f" ]]; then
        rm -f "$f"
        removed+=("$(basename "$f")")
    fi
done

# When gitlore redirects the task file, include the target path in the
# agent message so the skill writes to the right location.
task_path="$cwd/$HANDOFF_REL_TASK"
gitlore_note=""
if [[ "$task_path" != "$cwd/.claude/handoff-task.md" ]]; then
    gitlore_note=" Write handoff-task.md to: $task_path"
fi

if (( ${#removed[@]} == 0 )); then
    # Emit path note even when nothing was wiped — agent still needs the
    # redirected path.
    [[ -n "$gitlore_note" ]] || exit 0
    jq -nc \
        --arg c "handoff activation; no prior files.$gitlore_note" \
        --arg e "$hook_event" \
        '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
    exit 0
fi

# IFS only uses its first character to join "${arr[*]}", so `IFS=', '`
# joins on `,` alone. Build the comma-space list with printf instead.
printf -v files '%s, ' "${removed[@]}"
files="${files%, }"
msg="handoff: wiped prior $files"
agent_ctx="handoff activation hook wiped prior handoff files ($files); they are absent.$gitlore_note"
jq -nc \
    --arg m "$msg" \
    --arg c "$agent_ctx" \
    --arg e "$hook_event" \
    '{systemMessage: $m, hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
