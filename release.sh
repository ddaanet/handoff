#!/usr/bin/env bash
set -euo pipefail

# Release a Claude Code plugin: bump the manifest, commit, tag, push, create the
# GitHub release, and bump the plugin's entry in the marketplace repo.
#
# Usage:
#   release.sh [patch|minor|major]   full release
#   release.sh --resume              complete a release that landed partially
#
# Run from the plugin root (the directory holding .claude-plugin/plugin.json);
# `just release` does that for you. Requires bash, jq, git, gh, and
# MARKETPLACE_DIR pointing at the claude-plugins repo.

unset CDPATH   # else `cd` may echo its target into the $(cd … && pwd) capture
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

manifest=".claude-plugin/plugin.json"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

mode="release"
bump="patch"
case "${1:-}" in
    --resume)           mode="resume" ;;
    "")                 ;;
    -*)                 die "unknown option: $1 (usage: release.sh [patch|minor|major|--resume])" ;;
    patch|minor|major)  bump="$1" ;;
    *)                  die "unknown bump type: $1 (usage: release.sh [patch|minor|major|--resume])" ;;
esac
acted=0

common_preflight() {
    [ -f "$manifest" ] || die "$manifest not found — run from the plugin root"
    git diff --quiet HEAD || die "uncommitted changes"
    branch=$(git symbolic-ref -q --short HEAD || echo "")
    # Use symbolic-ref (not rev-parse): when origin/HEAD is unset, rev-parse
    # exits non-zero AND prints "origin/HEAD" to stdout, so the substitution
    # captures both the failed output and the fallback.
    main_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || echo "main")
    [ "$branch" = "$main_branch" ] || die "must be on $main_branch (currently $branch)"

    [ -n "${MARKETPLACE_DIR:-}" ] \
        || die "MARKETPLACE_DIR not set (set in .envrc to the claude-plugins repo root)"
    marketplace_json="$MARKETPLACE_DIR/.claude-plugin/marketplace.json"
    [ -f "$marketplace_json" ] || die "$marketplace_json not found"
    plugin_name=$(jq -r .name "$manifest")
    # A missing entry is not an error: on first publication we create one from
    # plugin.json. Synthesising its `source` needs an `origin` remote to derive
    # owner/repo from, so validate that here, before any destructive op.
    if jq -e --arg n "$plugin_name" 'any(.plugins[]; .name == $n)' "$marketplace_json" >/dev/null; then
        marketplace_entry_exists=1
    else
        marketplace_entry_exists=0
        git remote get-url origin >/dev/null 2>&1 \
            || die "'$plugin_name' has no entry in $marketplace_json and no 'origin' remote to derive one from"
    fi
    git -C "$MARKETPLACE_DIR" diff --quiet HEAD \
        || die "$MARKETPLACE_DIR has uncommitted changes"
}

release_preflight() {
    local manifest_version latest_tag
    # Catch a previous release that didn't fully complete (tag/manifest bumped,
    # marketplace bump never landed) before starting a new one on top of it.
    bash "$here/check-version.sh" || {
        # shellcheck disable=SC2016  # backticks are literal markdown, not command substitution
        printf 'hint: `just resume-release` completes a release that landed partially.\n' >&2
        die "fix the version drift above before releasing"
    }
    manifest_version=$(jq -r .version "$manifest")
    latest_tag=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
    if [ -n "$latest_tag" ] && [ "$manifest_version" != "$latest_tag" ]; then
        # shellcheck disable=SC2016  # backticks are literal markdown, not command substitution
        printf 'hint: plugin.json holds the LAST released version. `just release` bumps from there.\n' >&2
        printf '      revert any manual version bump and re-run.\n' >&2
        die "plugin.json version ($manifest_version) does not match latest tag (v$latest_tag)"
    fi
    V=$(jq -r --arg bump "$bump" '
      (.version | split(".") | map(tonumber)) as [$maj,$min,$pat]
      | if   $bump == "major" then [$maj+1, 0, 0]
        elif $bump == "minor" then [$maj, $min+1, 0]
        elif $bump == "patch" then [$maj, $min, $pat+1]
        else error("unknown bump type: " + $bump) end
      | map(tostring) | join(".")
    ' "$manifest")
    tag="v$V"
    ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "tag $tag already exists"
}

resume_preflight() {
    V=$(jq -r .version "$manifest")
    tag="v$V"
    # Resume only ever finishes a release whose commit and tag already landed
    # locally. No tag means no release was started at this version, and tagging
    # HEAD on a guess would tag whatever work landed since.
    git rev-parse -q --verify "refs/tags/$tag" >/dev/null || {
        printf 'hint: no release was started at this version.\n' >&2
        # shellcheck disable=SC2016  # backticks are literal markdown, not command substitution
        printf '      run `just release <bump>` instead.\n' >&2
        die "no tag $tag for plugin.json version $V"
    }
}

bump_commit_tag() {
    local tmp
    tmp=$(mktemp)
    jq --arg v "$V" '.version = $v' "$manifest" > "$tmp"
    mv "$tmp" "$manifest"
    git add "$manifest"
    git commit -m "release: $V"
    git tag -a "$tag" -m "Release $V"
    acted=1
    note "manifest + tag: $tag created locally"
}

push_branch() {
    local remote_head
    remote_head=$(git ls-remote origin "refs/heads/$branch" | cut -f1)
    if [ -n "$remote_head" ] && [ "$remote_head" = "$(git rev-parse HEAD)" ]; then
        note "branch $branch: already pushed"
        return
    fi
    git push
    acted=1
    note "branch $branch: pushed"
}

push_tag() {
    local remote_tag local_tag
    remote_tag=$(git ls-remote origin "refs/tags/$tag" | cut -f1)
    local_tag=$(git rev-parse "$tag")
    if [ -n "$remote_tag" ]; then
        # Never move a published tag: a mismatch means it was reused, which no
        # recovery should paper over.
        [ "$remote_tag" = "$local_tag" ] \
            || die "$tag on origin points at $remote_tag, not $local_tag — refusing to move a published tag"
        note "github tag $tag: already pushed"
        return
    fi
    git push origin "$tag"
    acted=1
    note "github tag $tag: pushed"
}

create_github_release() {
    if gh release view "$tag" >/dev/null 2>&1; then
        note "github release $tag: already created"
        return
    fi
    gh release create "$tag" --title "Release $V" --generate-notes
    acted=1
    note "github release $tag: created"
}

bump_marketplace() {
    local mp_tmp repo_slug mp_branch mp_remote_head mp_local_head committed=0
    mp_tmp=$(mktemp)
    if [ "$marketplace_entry_exists" = 1 ]; then
        jq --arg n "$plugin_name" --arg v "$V" \
            '(.plugins[] | select(.name == $n) | .version) = $v' \
            "$marketplace_json" > "$mp_tmp"
    else
        # Derive owner/repo from origin for the `github` source. Strip a trailing
        # .git, then everything up to the host separator, leaving `owner/repo`
        # for both git@host:owner/repo and https://host/owner/repo.
        repo_slug=$(git remote get-url origin | sed -E 's#\.git$##; s#^.*[:/]([^/]+/[^/]+)$#\1#')
        jq --arg v "$V" --arg repo "$repo_slug" --slurpfile m "$manifest" '
          .plugins += [{
            name: $m[0].name,
            source: { source: "github", repo: $repo },
            description: ($m[0].description // ""),
            version: $v,
            author: ($m[0].author // { name: "" }),
            repository: ($m[0].repository // $m[0].homepage // ("https://github.com/" + $repo)),
            license: ($m[0].license // "MIT")
          }]
        ' "$marketplace_json" > "$mp_tmp"
    fi
    mv "$mp_tmp" "$marketplace_json"
    git -C "$MARKETPLACE_DIR" add .claude-plugin/marketplace.json
    # Committing and pushing are separate questions: the working tree can
    # already hold $V (nothing to commit) while the commit that put it there
    # never reached origin (nothing pushed) — e.g. this same push rejected on
    # a previous run. A no-op diff must not short-circuit before the push is
    # checked, or an interrupted marketplace push can never be resumed.
    if git -C "$MARKETPLACE_DIR" diff --cached --quiet; then
        : # already at $V locally; still must check whether it reached origin
    else
        git -C "$MARKETPLACE_DIR" commit -m "release: $plugin_name $V"
        committed=1
        acted=1
    fi

    mp_branch=$(git -C "$MARKETPLACE_DIR" symbolic-ref -q --short HEAD || echo "")
    mp_remote_head=$(git -C "$MARKETPLACE_DIR" ls-remote origin "refs/heads/$mp_branch" | cut -f1)
    mp_local_head=$(git -C "$MARKETPLACE_DIR" rev-parse HEAD)
    if [ "$mp_remote_head" = "$mp_local_head" ]; then
        if [ "$committed" = 1 ]; then
            if [ "$marketplace_entry_exists" = 1 ]; then
                note "marketplace: bumped to $V"
            else
                note "marketplace: entry created at $V"
            fi
        else
            note "marketplace: already at $V"
        fi
        return
    fi

    git -C "$MARKETPLACE_DIR" push
    acted=1
    if [ "$committed" = 1 ]; then
        if [ "$marketplace_entry_exists" = 1 ]; then
            note "marketplace: bumped to $V"
        else
            note "marketplace: entry created at $V"
        fi
    else
        note "marketplace: committed earlier, pushed now"
    fi
}

common_preflight
if [ "$mode" = "release" ]; then
    release_preflight
    bump_commit_tag
else
    resume_preflight
fi
push_branch
push_tag
create_github_release
bump_marketplace
if [ "$mode" = "resume" ] && [ "$acted" = 0 ]; then
    note "release $tag is already complete (nothing to do)"
else
    note "Release $tag complete"
fi
