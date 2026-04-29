#!/usr/bin/env bash
# PreToolUse hook for the Skill tool.
# When the activated skill is `handoff:handoff`, wipe any prior
# handoff files so the skill runs against a clean slate. The skill
# itself then either writes a fresh handoff-task.md or leaves nothing
# (the "nothing to hand off" case).
#
# Mechanical work — agent is not involved.
set -euo pipefail

input="$(cat)"
tool_name="$(jq -r '.tool_name // ""' <<<"$input")"
[[ "$tool_name" == "Skill" ]] || exit 0

skill="$(jq -r '.tool_input.skill // ""' <<<"$input")"
[[ "$skill" == "handoff:handoff" ]] || exit 0

cwd="$(jq -r '.cwd // ""' <<<"$input")"
[[ -n "$cwd" ]] || cwd="$PWD"

mkdir -p "$cwd/.claude"

removed=()
for f in "$cwd/.claude/handoff-task.md" "$cwd/.claude/handoff.md"; do
    if [[ -f "$f" ]]; then
        rm -f "$f"
        removed+=("$(basename "$f")")
    fi
done

if (( ${#removed[@]} > 0 )); then
    files="$(IFS=', '; echo "${removed[*]}")"
    msg="handoff: wiped prior $files"
    agent_ctx="handoff activation hook wiped prior handoff files ($files); they are absent."
    jq -nc --arg m "$msg" --arg c "$agent_ctx" \
        '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $c}}'
fi
