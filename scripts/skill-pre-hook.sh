#!/usr/bin/env bash
# PreToolUse hook for the Skill tool.
# When the activated skill is `handoff` or `handoff:handoff` (the
# Skill tool accepts both as launches of the same skill), wipe any
# prior handoff files so the skill runs against a clean slate. The skill
# itself then either writes a fresh handoff-task.md or leaves nothing
# (the "nothing to hand off" case).
#
# Mechanical work — agent is not involved. Wipe+emit is shared with
# prompt-pre-hook.sh via _wipe-emit.sh; this script is just the
# Skill-tool filter on top.
set -euo pipefail

input="$(cat)"
tool_name="$(jq -r '.tool_name // ""' <<<"$input")"
[[ "$tool_name" == "Skill" ]] || exit 0

skill="$(jq -r '.tool_input.skill // ""' <<<"$input")"
# The Skill tool accepts both the bare and qualified name as launches
# of the same skill, so match both. Explicit allowlist (not a substring
# match) keeps unrelated skills no-ops.
[[ "$skill" == "handoff" || "$skill" == "handoff:handoff" ]] || exit 0

cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

exec bash "$(dirname "$0")/_wipe-emit.sh" "$cwd" "PreToolUse"
