#!/usr/bin/env bash
# Install or re-wire the claude-plugin-dev toolkit in the current
# Claude Code plugin repository.
#
# First-time install (toolkit not yet vendored):
#
#     git clone --depth 1 -b vX.Y.Z \
#         git@github.com:ddaanet/claude-plugin-dev.git /tmp/cpd
#     cd /path/to/plugin
#     bash /tmp/cpd/toolkit/install.sh [dist-vX.Y.Z]
#
# With no ref, the newest dist- tag on the remote is resolved and
# vendored. Clone the SOURCE tag (vX.Y.Z) to get the script; vendor the
# DIST tag (dist-vX.Y.Z), whose root tree is only the consumer-facing
# files. A subtree add of the source tag would copy this repo's whole
# working environment into the plugin -- see docs/design.md "Consumers
# vendor a split dist ref".
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

# Env-overridable so tests can point it at a local fixture repo.
TOOLKIT_URL="${TOOLKIT_URL:-git@github.com:ddaanet/claude-plugin-dev.git}"
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
# jq's own parse error goes to stderr and names the line and column, which is
# the only actionable half of this report — so it is not redirected away.
if [ -f "$settings" ] && ! jq empty "$settings"; then
    echo "error: $settings exists but is not valid JSON. Fix it first." >&2
    exit 1
fi

# 1. Vendor the toolkit if missing.
if [ ! -d "$TOOLKIT_PREFIX" ]; then
    if [ -z "$ref" ]; then
        # Same resolver as update.sh's no-ref default. Kept as a copy here:
        # the bootstrap script must stay runnable on its own, without
        # depending on a sibling file.
        ref="$(git ls-remote --tags --refs --sort=-v:refname "$TOOLKIT_URL" 'dist-v*' | sed -n '1s|.*/||p')"
        if [ -z "$ref" ]; then
            echo "error: could not resolve a dist tag from $TOOLKIT_URL" >&2
            echo "hint: pass one explicitly: bash install.sh dist-vX.Y.Z" >&2
            exit 1
        fi
        echo "install: resolved newest dist tag: $ref"
    fi
    # Only a dist tag is vendorable. Every other ref -- source tag, branch,
    # sha -- resolves to the toolkit's root tree, which is its own working
    # environment: a `memory` gitlink, .claude/, CLAUDE.md, its own justfile.
    # Vendoring one copies all of that into this plugin and is invisible until
    # someone runs `git submodule status`, so it is refused, not warned about.
    case "$ref" in
      dist-v*) ;;
      v*)
          echo "error: '$ref' is a source tag — vendor the dist tag instead: dist-$ref" >&2
          exit 1
          ;;
      *)
          echo "error: '$ref' is not a dist tag — vendor dist-vX.Y.Z" >&2
          echo "       only the dist lineage contains the consumer-facing files." >&2
          exit 1
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
        # Trailing '\n': $(cat justfile) strips every trailing newline, so
        # without one the consumer's justfile comes back with no final newline.
        printf '%s\n\n%s\n' "$import_line" "$(cat justfile)" > justfile.tmp
        mv justfile.tmp justfile
        changed+=("justfile (added import)")
    fi
else
    cat > justfile <<EOF
$import_line

# Checks that run before every commit.
precommit:
    jq . .claude-plugin/plugin.json > /dev/null

# Checks that run before a release. Add slow or paid checks here.
prerelease: precommit
EOF
    changed+=("justfile (created)")
fi

# 3. .claude/settings.json hook block. Append the hook only if not already
# present, and write only if that changed something.
#
# The two cases are separate branches, not a jq failure falling through to a
# fallback: the fallback writes a document holding nothing but this hook, so
# reaching it with an existing settings.json replaces the consumer's whole
# configuration. `.matcher == null` is what used to get there — a PreToolUse
# entry with no matcher is legal and matches every tool, but `null | test(...)`
# aborts jq with exit 5.
mkdir -p .claude
tmp="$(mktemp)"
if [ -f "$settings" ]; then
    jq --arg cmd "$hook_cmd" '
      if ([.hooks.PreToolUse[]?
           | select(.matcher == null or (.matcher | test("Write|Edit")))
           | .hooks[]? | select(.command == $cmd)] | length > 0)
      then .
      else .hooks //= {} |
           .hooks.PreToolUse //= [] |
           .hooks.PreToolUse += [{
             matcher: "Write|Edit",
             hooks: [{type: "command", command: $cmd}]
           }]
      end
    ' "$settings" > "$tmp" || {
        rm -f "$tmp"
        echo "error: could not rewrite $settings — left unchanged." >&2
        exit 1
    }
else
    jq --arg cmd "$hook_cmd" -n '
      {hooks: {PreToolUse: [{matcher: "Write|Edit",
                             hooks: [{type: "command", command: $cmd}]}]}}
    ' > "$tmp"
fi

if [ -f "$settings" ] && cmp -s "$settings" "$tmp"; then
    rm -f "$tmp"
else
    # Write through the destination rather than `mv`-ing the mktemp file over
    # it: mktemp creates 0600, and mv carries that mode onto the consumer's
    # settings file. Redirection keeps an existing file's mode, ownership and
    # ACL, and creates a new one at the umask like any other tool would.
    cat "$tmp" > "$settings"
    rm -f "$tmp"
    changed+=("$settings (added version-guard hook)")
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
    echo "  1. Define your precommit and prerelease recipes in justfile."
    echo "  2. Commit the changes:"
    echo "     git add $TOOLKIT_PREFIX justfile .claude/settings.json"
    echo "     git commit -m 'add claude-plugin-dev toolkit'"
fi
