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

# quote() and not a double-quoted interpolation: just substitutes the argument
# as raw text before this recipe's shell parses the line, so surrounding double
# quotes do not stop a caller's $(...) from being evaluated. quote() emits a
# single-quoted literal instead. Written without braces because a recipe body's
# comments are interpolated too — only file-level ones like this are inert.
# Bump plugin.json (patch by default), commit, tag, push, GitHub release, bump marketplace.
release bump='': prerelease
    bash "{{toolkit_prefix}}/release.sh" {{quote(bump)}}

# Complete a release that landed only partially. Idempotent, no gate.
resume-release:
    bash "{{toolkit_prefix}}/release.sh" --resume

# Check plugin.json's version against its marketplace.json entry.
check-version:
    bash "{{toolkit_prefix}}/check-version.sh"

# Pull the vendored toolkit up to a dist tag; no ref = newest on the remote.
update-plugin-dev ref='':
    TOOLKIT_URL="{{toolkit_url}}" bash "{{toolkit_prefix}}/update.sh" {{quote(ref)}}
