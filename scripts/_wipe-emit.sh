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
# Usage: _wipe-emit.sh <cwd> <hook_event_name>
set -euo pipefail

cwd="${1:?cwd required}"
hook_event="${2:?hook_event_name required}"

mkdir -p "$cwd/.claude"

removed=()
for f in "$cwd/.claude/handoff-task.md" "$cwd/.claude/handoff.md"; do
    if [[ -f "$f" ]]; then
        rm -f "$f"
        removed+=("$(basename "$f")")
    fi
done

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
