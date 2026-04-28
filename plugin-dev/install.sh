#!/usr/bin/env bash
# Install or re-wire the claude-plugin-dev toolkit in the current
# Claude Code plugin repository.
#
# First-time install (toolkit not yet vendored):
#
#     git clone --depth 1 -b vX.Y.Z \
#         git@github.com:ddaanet/claude-plugin-dev.git /tmp/cpd
#     cd /path/to/plugin
#     bash /tmp/cpd/install.sh vX.Y.Z
#
# The script will:
#   1. git subtree add the toolkit at plugin-dev/ (skipped if present)
#   2. add 'import "plugin-dev/release.just"' to justfile
#   3. wire the version-guard hook into .claude/settings.json
#
# Re-run (after the toolkit is already vendored):
#
#     bash plugin-dev/install.sh
#
# Idempotent: re-running with everything already in place is a no-op.
set -euo pipefail

TOOLKIT_URL="git@github.com:ddaanet/claude-plugin-dev.git"
TOOLKIT_PREFIX="plugin-dev"

ref="${1:-}"

# Run-in-target safety guard.
if [ ! -f ".claude-plugin/plugin.json" ]; then
    echo "error: .claude-plugin/plugin.json not found in $PWD" >&2
    echo "hint: run this script from a Claude Code plugin's root directory." >&2
    exit 1
fi

changed=()
settings=".claude/settings.json"
# shellcheck disable=SC2016  # ${CLAUDE_PROJECT_DIR} is for Claude Code to expand at hook-fire time, not bash now.
hook_cmd='bash ${CLAUDE_PROJECT_DIR}/plugin-dev/version-guard.sh'

# Pre-flight: validate any existing settings.json BEFORE the slow subtree
# add, so a malformed file fails fast instead of leaving a half-installed
# state behind.
if [ -f "$settings" ] && ! jq empty "$settings" 2>/dev/null; then
    echo "error: $settings exists but is not valid JSON. Fix it first." >&2
    exit 1
fi

# 1. Vendor the toolkit if missing.
if [ ! -d "$TOOLKIT_PREFIX" ]; then
    if [ -z "$ref" ]; then
        echo "error: $TOOLKIT_PREFIX/ not found and no ref given." >&2
        echo "usage: bash install.sh vX.Y.Z   (pass a tag to vendor on first install)" >&2
        exit 1
    fi
    case "$ref" in
      v*) ;;
      main|master|HEAD)
          echo "warning: pulling a branch ref ($ref) — prefer a tag (vX.Y.Z) for reproducibility" >&2
          ;;
    esac
    git diff --quiet HEAD || { echo "error: uncommitted changes — commit or stash before vendoring" >&2; exit 1; }
    git subtree add --prefix="$TOOLKIT_PREFIX" "$TOOLKIT_URL" "$ref" --squash
    changed+=("$TOOLKIT_PREFIX/ (vendored at $ref)")
elif [ -n "$ref" ]; then
    echo "warning: $TOOLKIT_PREFIX/ already vendored — ignoring ref '$ref'." >&2
    echo "         to update, run: just update-plugin-dev $ref" >&2
fi

# 2. Justfile import.
import_line="import 'plugin-dev/release.just'"
if [ -f justfile ]; then
    if ! grep -qxF "$import_line" justfile; then
        printf '%s\n\n%s' "$import_line" "$(cat justfile)" > justfile.tmp
        mv justfile.tmp justfile
        changed+=("justfile (added import)")
    fi
else
    cat > justfile <<EOF
$import_line

# Define your project-specific precommit recipe.
# (The release recipe imported above depends on it.)
precommit:
    jq . .claude-plugin/plugin.json > /dev/null
EOF
    changed+=("justfile (created)")
fi

# 3. .claude/settings.json hook block. Single jq pass: read (or stub),
# append the hook only if not already present, write only if changed.
mkdir -p .claude
tmp="$(mktemp)"
jq --arg cmd "$hook_cmd" '
  if ([.hooks.PreToolUse[]? | select(.matcher | test("Write|Edit"))
       | .hooks[]? | select(.command == $cmd)] | length > 0)
  then .
  else .hooks //= {} |
       .hooks.PreToolUse //= [] |
       .hooks.PreToolUse += [{
         matcher: "Write|Edit",
         hooks: [{type: "command", command: $cmd}]
       }]
  end
' "${settings}" 2>/dev/null > "$tmp" || jq --arg cmd "$hook_cmd" -n '
  {hooks: {PreToolUse: [{matcher: "Write|Edit",
                         hooks: [{type: "command", command: $cmd}]}]}}
' > "$tmp"

if ! [ -f "$settings" ] || ! cmp -s "$settings" "$tmp"; then
    mv "$tmp" "$settings"
    changed+=("$settings (added version-guard hook)")
else
    rm -f "$tmp"
fi

if [ "${#changed[@]}" -eq 0 ]; then
    echo "claude-plugin-dev: already installed, nothing to do."
else
    echo "claude-plugin-dev: installed."
    for c in "${changed[@]}"; do
        echo "  - $c"
    done
    echo
    echo "Next steps:"
    echo "  1. Define your precommit recipe in justfile (project-specific checks)."
    echo "  2. Commit the changes:"
    echo "     git add $TOOLKIT_PREFIX justfile .claude/settings.json"
    echo "     git commit -m 'add claude-plugin-dev toolkit'"
fi
