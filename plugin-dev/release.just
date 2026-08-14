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
# `.claude-plugin/plugin.json` must exist with a semver `.version` field. It
# holds the LAST released version and `just release <bump>` bumps forward from
# it — except on a plugin that has never been released, where there is no
# previous version to bump from and `just release` (no argument) publishes the
# version the manifest already holds. That is what makes a first release work
# straight out of a scaffold, whatever version the scaffold seeded. Passing an
# explicit bump on a first release is refused rather than silently ignored.
#
# The `patch` default lives in release.sh, not in the recipe signature: the
# recipe passes its argument through even when empty, so release.sh can tell an
# explicit `patch` from no argument at all.
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

# Bump plugin.json (patch by default), commit, tag, push, GitHub release, bump marketplace.
release bump='': prerelease
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
    # Only a dist tag is vendorable. Every other ref -- source tag, branch,
    # sha -- resolves to the toolkit's root tree, which is its own working
    # environment: a `memory` gitlink, .claude/, CLAUDE.md, its own justfile.
    # Pulling one copies all of that into this plugin and is invisible until
    # someone runs `git submodule status`, so it is refused, not warned about.
    case "{{ref}}" in
      dist-v*) ;;
      v*)
        echo "error: '{{ref}}' is a source tag — pull the dist tag instead: dist-{{ref}}" >&2
        exit 1
        ;;
      *)
        echo "error: '{{ref}}' is not a dist tag — pull dist-vX.Y.Z" >&2
        echo "       only the dist lineage contains the consumer-facing files." >&2
        exit 1
        ;;
    esac
    git subtree pull --prefix="{{toolkit_prefix}}" "{{toolkit_url}}" "{{ref}}" --squash
    # Verify VERSION matches the requested tag (catches half-applied subtree
    # pulls). Unconditional: the guard above means only a dist-v* ref reaches
    # here, so the version is always extractable. Still best-effort on the
    # file, which a ref older than v0.2.0 lacks.
    expected="$(printf '%s' "{{ref}}" | sed 's/^dist-v//')"
    if [ -f "{{toolkit_prefix}}/VERSION" ]; then
      actual=$(tr -d '[:space:]' < "{{toolkit_prefix}}/VERSION")
      [ "$actual" = "$expected" ] \
        || echo "warning: {{toolkit_prefix}}/VERSION ($actual) does not match requested ref ({{ref}})" >&2
    fi
