# Shared release recipe for Claude Code plugins.
#
# Imported into a plugin's justfile via:
#
#     import 'plugin-dev/release.just'
#
# The plugin must define its own `precommit` recipe; `release` depends on it.
# `.claude-plugin/plugin.json` must exist with a semver `.version` field.
#
# Requirements: bash, jq, git, gh.

toolkit_url := "git@github.com:ddaanet/claude-plugin-dev.git"
toolkit_prefix := "plugin-dev"

# Create release: bump plugin.json version, commit, tag, push, GH release.
# Pass `--yes` as the second arg to skip the interactive confirmation
# (useful when an outer permission layer already gates the command).
release bump='patch' yes='': precommit
    #!/usr/bin/env bash
    set -euo pipefail
    manifest=".claude-plugin/plugin.json"
    git diff --quiet HEAD || { echo "error: uncommitted changes" >&2; exit 1; }
    branch=$(git symbolic-ref -q --short HEAD || echo "")
    # Use symbolic-ref (not rev-parse): when origin/HEAD is unset,
    # rev-parse exits non-zero AND prints "origin/HEAD" to stdout, so
    # the substitution captures both the failed output and the
    # fallback. symbolic-ref is silent on stdout when the ref is unset.
    main_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || echo "main")
    [ "$branch" = "$main_branch" ] || { echo "error: must be on $main_branch (currently $branch)" >&2; exit 1; }
    manifest_version=$(jq -r .version "$manifest")
    latest_tag=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
    if [ -n "$latest_tag" ] && [ "$manifest_version" != "$latest_tag" ]; then
      echo "error: plugin.json version ($manifest_version) does not match latest tag (v$latest_tag)" >&2
      echo "hint: plugin.json holds the LAST released version. \`just release\` bumps from there." >&2
      echo "      revert any manual version bump and re-run." >&2
      exit 1
    fi
    new_version=$(jq -r --arg bump "{{bump}}" '
      (.version | split(".") | map(tonumber)) as [$maj,$min,$pat]
      | if   $bump == "major" then [$maj+1, 0, 0]
        elif $bump == "minor" then [$maj, $min+1, 0]
        elif $bump == "patch" then [$maj, $min, $pat+1]
        else error("unknown bump type: " + $bump) end
      | map(tostring) | join(".")
    ' "$manifest")
    tag="v$new_version"
    git rev-parse "$tag" >/dev/null 2>&1 && { echo "error: tag $tag already exists" >&2; exit 1; }
    if [ "{{yes}}" != "--yes" ]; then
        read -rp "Release $new_version? [y/N] " answer
        case "$answer" in y|Y) ;; *) exit 1 ;; esac
    fi
    tmp=$(mktemp)
    jq --arg v "$new_version" '.version = $v' "$manifest" > "$tmp"
    mv "$tmp" "$manifest"
    git add "$manifest"
    git commit -m "release: $new_version"
    git tag -a "$tag" -m "Release $new_version"
    git push
    git push origin "$tag"
    gh release create "$tag" --title "Release $new_version" --generate-notes
    echo "Release $tag complete"

# Update the vendored plugin-dev toolkit to a specific tag (recommended)
# or branch. Run from the consumer plugin root, on a clean tree.
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
