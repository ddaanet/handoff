#!/usr/bin/env bash
# PreToolUse hook (Write|Edit) for the plugin manifest.
# Refuses any edit that changes plugin.json's .version. The release
# recipe owns version bumps; manual edits desync the manifest from the
# latest tag and only get caught at release time.
#
# Mechanical: agent is not involved.
set -euo pipefail

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // ""' <<<"$input")"
[[ -n "$file_path" ]] || exit 0

cwd="$(jq -r '.cwd // ""' <<<"$input")"
[[ -n "$cwd" ]] || cwd="$PWD"

manifest="$cwd/.claude-plugin/plugin.json"
[[ -f "$manifest" ]] || exit 0
[[ "$(realpath -m -- "$file_path")" == "$(realpath -m -- "$manifest")" ]] || exit 0

current="$(jq -r '.version // ""' "$manifest" 2>/dev/null || echo "")"
[[ -n "$current" ]] || exit 0  # manifest unparseable; let the edit through.

tool_name="$(jq -r '.tool_name // ""' <<<"$input")"

proposed=""
case "$tool_name" in
  Write)
    proposed="$(jq -r '.tool_input.content // ""' <<<"$input" \
      | jq -r '.version // ""' 2>/dev/null || echo "")"
    ;;
  Edit)
    new_string="$(jq -r '.tool_input.new_string // ""' <<<"$input")"
    version_line="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$new_string" | head -1 || true)"
    [[ -n "$version_line" ]] && proposed="$(sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/' <<<"$version_line")"
    ;;
  *) exit 0 ;;
esac

[[ -z "$proposed" || "$proposed" == "$current" ]] && exit 0

read -r -d '' agent_reason <<EOF || true
plugin.json version edit refused: $current -> $proposed.

The manifest version is the last released version. It is changed only by
'just release {patch|minor|major}', which validates state, bumps, commits,
tags, and pushes in one step. The release recipe also refuses if plugin.json
and the latest git tag disagree.

If the goal is to ship a release, invoke the recipe instead of editing this
file. Do not bypass this guard, modify the recipe, or alter version state by
other means.
EOF

human_msg="version-guard: blocked plugin.json version edit ($current -> $proposed)"

jq -nc --arg r "$agent_reason" --arg s "$human_msg" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}, systemMessage: $s}' >&2
exit 2
