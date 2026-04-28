#!/usr/bin/env bash
# UserPromptSubmit hook.
# Slash-command invocation (`/handoff:handoff`) loads the skill body
# directly without a `Skill` tool call, so PreToolUse(Skill) does not
# fire on that path. This hook covers it: when the submitted prompt
# starts with `/handoff:handoff`, wipe any prior handoff files so the
# skill runs against a clean slate.
#
# Mechanical work — agent is not involved.
set -euo pipefail

input="$(cat)"
prompt="$(jq -r '.prompt // ""' <<<"$input")"
[[ "$prompt" =~ ^/handoff:handoff([[:space:]]|$) ]] || exit 0

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
    msg="handoff: wiped prior $(IFS=', '; echo "${removed[*]}")"
    printf '{"systemMessage": "%s"}\n' "$msg"
fi
