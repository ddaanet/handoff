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

# `realpath -m` is GNU-only; use python3 for portability (BSD realpath
# rejects -m). Equivalent: returns an absolute path even when components
# don't exist yet.
resolve() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
target="$(resolve "$file_path")"
expected="$(resolve "$cwd/.claude/handoff-task.md")"
[[ "$target" == "$expected" ]] && exit 0

read -r -d '' agent_reason <<EOF || true
Refusing to write 'handoff-task.md' outside this project's '.claude/' directory.
Resolved target: $target
Expected:        $expected

The handoff plugin is per-project. The intended path is
'./.claude/handoff-task.md' relative to the current working directory
($cwd). If a different file with the same name was intended, choose a
different filename.
EOF

human_msg="write-guard: blocked handoff-task.md write outside $cwd/.claude/"

jq -nc --arg r "$agent_reason" --arg s "$human_msg" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}, systemMessage: $s}' >&2
exit 2
