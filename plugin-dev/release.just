# Shared release recipe for Claude Code plugins.
#
# Imported into a plugin's justfile via:
#
#     import 'plugin-dev/release.just'
#
# The plugin must define two recipes of its own:
#
#     precommit:  ...        # the gate that runs before every commit
#     prerelease: precommit  # the gate `release` depends on
#
# `release` depends on `prerelease`, never on `precommit` directly. For most
# plugins the two are the same and `prerelease: precommit` is the whole
# recipe. A plugin whose release gate is larger — slow or paid checks that
# shouldn't fire on every commit — widens it there:
#
#     prerelease: precommit evals
#
# `prerelease` is mandatory: just rejects the whole justfile if a dependency
# names a recipe that doesn't exist, so a plugin that hasn't defined it finds
# out immediately, not at release time.
#
# `.claude-plugin/plugin.json` must exist with a semver `.version` field.
#
# Required env (typically set via .envrc):
#   MARKETPLACE_DIR — path to the `claude-plugins` marketplace repo. The
#   release recipe bumps the plugin's entry in
#   `$MARKETPLACE_DIR/.claude-plugin/marketplace.json` and pushes that
#   repo too. A release without the marketplace bump is incomplete:
#   end-users discover plugins via the marketplace, so a tag without a
#   marketplace bump is invisible to them.
#
# If a release dies partway — a rejected push, a `gh` failure — the plugin is
# left tagged at the new version with a stale marketplace entry. `just
# resume-release` completes it: it pushes whatever is missing and is a no-op
# when everything already landed.
#
# `check-version` reports whether plugin.json and the marketplace entry agree.
# It skips non-fatally when MARKETPLACE_DIR is unset, the marketplace repo
# isn't checked out, or the plugin has no entry yet (pre-first-publication).
#
# Requirements: bash, jq, git, gh.

toolkit_url := "git@github.com:ddaanet/claude-plugin-dev.git"
toolkit_prefix := "plugin-dev"

# Bump plugin.json, commit, tag, push, GitHub release, bump marketplace.
release bump='patch': prerelease
    bash "{{toolkit_prefix}}/release.sh" "{{bump}}"

# Complete a release that landed only partially. Idempotent, no gate.
resume-release:
    bash "{{toolkit_prefix}}/release.sh" --resume

# Check plugin.json's version against its marketplace.json entry.
check-version:
    bash "{{toolkit_prefix}}/check-version.sh"

# Pull the vendored plugin-dev toolkit up to a tag. Plugin root, clean tree.
update-plugin-dev ref:
    #!/usr/bin/env bash
    set -euo pipefail
    git diff --quiet HEAD || { echo "error: uncommitted changes" >&2; exit 1; }
    [ -d "{{toolkit_prefix}}" ] || { echo "error: {{toolkit_prefix}}/ not found — is the toolkit vendored here?" >&2; exit 1; }
    case "{{ref}}" in
      v*) ;;
      main|master|HEAD) echo "warning: pulling a branch ref ({{ref}}) — prefer a tag (vX.Y.Z) for reproducibility" >&2 ;;
    esac
    git subtree pull --prefix="{{toolkit_prefix}}" "{{toolkit_url}}" "{{ref}}" --squash
    # Verify VERSION matches the requested tag (catches half-applied
    # subtree pulls). VERSION first appeared in v0.2.0; older refs
    # lack it, so the check is best-effort.
    case "{{ref}}" in
      v*)
        expected="$(printf '%s' "{{ref}}" | sed 's/^v//')"
        if [ -f "{{toolkit_prefix}}/VERSION" ]; then
          actual=$(tr -d '[:space:]' < "{{toolkit_prefix}}/VERSION")
          [ "$actual" = "$expected" ] \
            || echo "warning: {{toolkit_prefix}}/VERSION ($actual) does not match requested ref ({{ref}})" >&2
        fi
        ;;
    esac
