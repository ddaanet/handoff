#!/usr/bin/env bash
# PreToolUse hook for Write|Edit.
# Deny writes/edits whose target basename is handoff-task.md but whose
# resolved absolute path is not $cwd/.claude/handoff-task.md.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // ""' <<<"$input")"
[[ -n "$file_path" ]] || exit 0
[[ "$(basename "$file_path")" == "handoff-task.md" ]] || exit 0

cwd="$(jq -r '.cwd // ""' <<<"$input")"
[[ -n "$cwd" ]] || cwd="$PWD"

{ read -r target; read -r expected; } < <(handoff_resolve "$file_path" "$cwd/$HANDOFF_REL_TASK")
[[ "$target" == "$expected" ]] && exit 0

agent_reason="write blocked: handoff-task.md outside this project's .claude/. resolved: $target; expected: $expected."
human_msg="write-guard: blocked handoff-task.md write outside $cwd/.claude/"

# Modern PreToolUse deny: structured JSON on stdout, exit 0. Matches the
# wipe scripts' channel (also stdout/exit 0) and avoids mixing the
# legacy stderr-fed-to-Claude path with the structured permissionDecision
# output.
jq -nc --arg r "$agent_reason" --arg s "$human_msg" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}, systemMessage: $s}'
