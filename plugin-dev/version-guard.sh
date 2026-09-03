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

# CLAUDE_PROJECT_DIR, not the payload `cwd`: `cwd` tracks the Bash tool's
# persistent shell and drifts with a `cd` or an /add-dir. Locating the
# manifest from a drifted cwd finds nothing and exits 0 -- a silent, total
# bypass. install.sh wires the hook command around CLAUDE_PROJECT_DIR for
# the same reason. No fallback to the payload cwd: that reintroduces it.
project="${CLAUDE_PROJECT_DIR:-$PWD}"
manifest="${project%/}/.claude-plugin/plugin.json"
[[ -f "$manifest" ]] || exit 0

# Absolutise in shell rather than with `realpath -m`: BSD/macOS realpath
# has no -m, so both substitutions come back empty, `[[ "" == "" ]]` is
# true, and the guard fires on every file instead of just the manifest.
# The manifest path is built here rather than supplied, so symlink
# resolution buys nothing. tool_input.file_path is whatever the model
# emitted and is not always absolute, and a relative one may be meant
# against either root, so a match on either counts.
abspath() {
    local root="$1" p="${2#./}"
    case "$p" in
      /*) printf '%s\n' "$p" ;;
      *)  printf '%s\n' "${root%/}/$p" ;;
    esac
}
[[ "$(abspath "$project" "$file_path")" == "$manifest" \
   || "$(abspath "$PWD" "$file_path")" == "$manifest" ]] || exit 0

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
    # Apply the edit to the manifest and re-read .version from the result,
    # instead of pattern-matching new_string for a "version" key. The
    # shortest edit that bumps the version is old_string "1.2.3" ->
    # new_string "9.9.9", which repeats no key to match, and it is the
    # form an agent reaches for first.
    old_string="$(jq -r '.tool_input.old_string // ""' <<<"$input")"
    new_string="$(jq -r '.tool_input.new_string // ""' <<<"$input")"
    if [[ -n "$old_string" ]]; then
      replace_all="$(jq -r 'if .tool_input.replace_all then "true" else "false" end' <<<"$input")"
      # jq's split/1 splits on a literal string, not a regex, so JSON
      # punctuation in old_string matches as written -- which a bash
      # ${text/pat/rep} would not, its pattern being a glob. `empty` when
      # old_string is absent from the manifest: that edit fails anyway.
      patched="$(jq -rn --arg t "$(cat "$manifest")" --arg o "$old_string" \
                        --arg n "$new_string" --argjson all "$replace_all" '
        ($t | split($o)) as $parts
        | if ($parts | length) < 2 then empty
          elif $all then ($parts | join($n))
          else $parts[0] + $n + ($parts[1:] | join($o))
          end')"
      proposed="$(jq -r '.version // ""' <<<"$patched" 2>/dev/null || echo "")"
    fi
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

# stdout and exit 0, not stderr and exit 2. Claude Code parses a hook's
# stdout as JSON, and only on exit 0. `permissionDecision: "deny"` there
# blocks the call exactly as exit 2 does, and additionally delivers
# systemMessage; on exit 2 the JSON is handed to the model as raw stderr
# text and the human channel never fires at all.
jq -nc --arg r "$agent_reason" --arg s "$human_msg" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}, systemMessage: $s}'
exit 0
