#!/usr/bin/env bash
# PreToolUse hook for Write|Edit.
# Deny writes/edits whose target basename is handoff-task.md but whose
# resolved absolute path is not $cwd/.claude/handoff-task.md. Catches
# cross-project misfires and absolute-path mistakes; the message tells
# the agent the right path.
set -euo pipefail

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // ""' <<<"$input")"
[[ -n "$file_path" ]] || exit 0
[[ "$(basename "$file_path")" == "handoff-task.md" ]] || exit 0

cwd="$(jq -r '.cwd // ""' <<<"$input")"
[[ -n "$cwd" ]] || cwd="$PWD"

target="$(realpath -m -- "$file_path")"
expected="$(realpath -m -- "$cwd/.claude/handoff-task.md")"
[[ "$target" == "$expected" ]] && exit 0

read -r -d '' msg <<EOF || true
handoff: refusing to write a handoff-task.md outside this project's .claude/ directory. Resolved target: $target. Expected exactly: $expected. The handoff plugin is per-project — write to './.claude/handoff-task.md' relative to the current working directory ($cwd) and try again. If you intended to write a different file with the same name, choose a different filename.
EOF
jq -nc --arg m "$msg" '{hookSpecificOutput: {permissionDecision: "deny"}, systemMessage: $m}' >&2
exit 2
