#!/usr/bin/env bash
set -euo pipefail

# Release a Claude Code plugin: bump the manifest, commit, tag, push, create the
# GitHub release, and bump the plugin's entry in the marketplace repo.
#
# Usage:
#   release.sh [patch|minor|major]   full release
#   release.sh --resume              complete a release that landed partially
#
# A plugin that has never been released is a special case: with no previous
# release to bump forward from, `release.sh` with no bump argument publishes
# the manifest version as it stands. Passing a bump there is refused. See
# release_preflight.
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
# Distinct from $bump: whether a bump was actually *asked for*. `just release`
# passes an empty argument through, so the patch default lives here, and a
# first release can tell "the user typed patch" from "the user typed nothing".
bump_arg=""
case "${1:-}" in
    --resume)           mode="resume" ;;
    "")                 ;;
    -*)                 die "unknown option: $1 (usage: release.sh [patch|minor|major|--resume])" ;;
    patch|minor|major)  bump="$1"; bump_arg="$1" ;;
    *)                  die "unknown bump type: $1 (usage: release.sh [patch|minor|major|--resume])" ;;
esac
acted=0
first_release=0

check_marketplace_writable() {
    # bump_marketplace replaces marketplace.json with mktemp + mv, which unlinks
    # and recreates the file in its directory — so probe the directory, not just
    # the file's mode bits. A sandboxed Bash call commonly can't write here.
    # 2>&1, not 2>/dev/null: on failure $probe carries mktemp's own diagnosis
    # (permission denied, read-only file system, no such directory), which is
    # the only thing that distinguishes them. The sandbox line below is advice
    # for the common case, not a cause this probe established.
    local probe
    probe=$(mktemp "$marketplace_dir/.release-writability-check.XXXXXX" 2>&1) \
        || die "$marketplace_dir is not writable: $probe — release needs to replace marketplace.json there. If this is a Claude Code sandbox restriction: rerun this Bash call with dangerouslyDisableSandbox, or run '/add-dir $MARKETPLACE_DIR' first."
    rm -f "$probe"
}

tree_is_clean() {
    # $1=repo root. True when nothing tracked is uncommitted there, ignoring two
    # paths an agent session moves by design between commits.
    #
    # `.claude/` is the repo's own agent working environment — settings, hooks,
    # and the task frames the handoff and precompact skills stage for "whatever
    # commit lands next". None of it is plugin content: a plugin ships
    # .claude-plugin/ and the component directories beside it. Excluded whole
    # rather than by filename, because the set of files written there is a
    # function of which skills the maintainer runs, not of this script. The
    # pathspec matches at the path separator, so .claude-plugin/ — where a dirty
    # file must still stop a release — is untouched by it.
    #
    # The second is a gitlore-mounted memory submodule: its gitlink sits ahead
    # of what HEAD records between commits by design — gitlore's own pre-commit
    # hook folds that in on the next commit, not this one.
    #
    # The mount path is read from .gitmodules rather than assumed to be
    # `memory`: that is only gitlore's default, the path being $1 to gitlore's
    # install.sh. Keyed on the submodule NAME, which gitlore fixes, not its url
    # — git absolutises a relative url on the way into .git/config, so a url
    # only ever matches .gitmodules itself. `--get` of a single key returns the
    # value whole, so a path containing spaces needs no -z splitting.
    #
    # Deliberately this narrow. A consumer that vendors some other submodule
    # and forgets to commit its moved gitlink should be refused, so
    # `--ignore-submodules=all` is not the shortcut it looks like.
    local dir="$1" mem=""
    local specs=(. ':(exclude).claude')
    if [ -f "$dir/.gitmodules" ]; then
        mem=$(git config -f "$dir/.gitmodules" --get submodule.gitlore-memory.path) || mem=""
    fi
    if [ -n "$mem" ]; then
        specs+=(":(exclude)$mem")
    fi
    git -C "$dir" diff --quiet HEAD -- "${specs[@]}"
}

common_preflight() {
    [ -f "$manifest" ] || die "$manifest not found — run from the plugin root"
    tree_is_clean "." || die "uncommitted changes"
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
    # A detached HEAD there is only discovered by the marketplace push, which
    # runs after the plugin's commit, tag, tag push and GitHub release are all
    # public. Catch it here instead, with the other MARKETPLACE_DIR checks.
    git -C "$MARKETPLACE_DIR" symbolic-ref -q --short HEAD >/dev/null \
        || die "$MARKETPLACE_DIR is on a detached HEAD — check out its branch first"
    marketplace_dir=$(dirname "$marketplace_json")
    # A release always bumps to a version the marketplace doesn't have yet, so
    # the write is never a no-op — check fails fast here, before the tag and
    # the GitHub release. A resume may find the marketplace already correct
    # (a true no-op bump_marketplace can skip entirely); its own writability
    # need is checked there, only when a write actually happens.
    # Keep this off the last line of the function: a false `&&` list is exempt
    # from errexit mid-function, but as the final command its status becomes the
    # function's, and `common_preflight` would exit 1 with no message on resume.
    [ "$mode" = "release" ] && check_marketplace_writable
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
    tree_is_clean "$MARKETPLACE_DIR" \
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

    # A plugin that has never been released has no last-released version to bump
    # forward from: its manifest holds the version it wants to publish FIRST.
    # Plugins scaffolded by the unrelated official `plugin-dev` marketplace
    # plugin arrive seeded at 0.1.0 exactly this way, and bumping past it
    # publishes a version nobody asked for. So publish the manifest verbatim.
    #
    # Both conjuncts are load-bearing. No-tags alone would misread a repo whose
    # tags were lost or never fetched as never-released, and republish a version
    # already out there. No-entry alone would misread a plugin that is tagged but
    # not yet in the marketplace — check-version.sh treats that as the ordinary
    # pre-first-publication state. Only a repo with neither has demonstrably
    # never been through this script.
    #
    # `git tag --list 'v*'` and not `git describe`: describe only sees tags
    # reachable from HEAD, so a release tagged on a since-abandoned branch would
    # read as no tags at all.
    if [ -z "$(git tag --list 'v*')" ] && [ "$marketplace_entry_exists" = 0 ]; then
        first_release=1
        if [ -n "$bump_arg" ]; then
            printf 'hint: a first release publishes the manifest version as-is — there is no\n' >&2
            printf '      previous release to bump forward from. Re-run with no bump argument\n' >&2
            printf '      to publish v%s.\n' "$manifest_version" >&2
            die "'$bump_arg' bump refused: this plugin has never been released"
        fi
        V="$manifest_version"
        tag="v$V"
        ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "tag $tag already exists"
        note "first release: publishing the manifest version $V as-is (no bump)"
        return
    fi

    # `git tag --list 'v*'` for the same reason as the first-release check
    # above, plus one more: describe returns the nearest tag of ANY name,
    # distance-ordered rather than version-ordered, so any unrelated tag on a
    # later commit reads as the last release. --sort=-v:refname orders by
    # version; sed -n '1s…p' takes the newest without exiting early, which
    # under pipefail would surface as a SIGPIPE on a repo with many tags.
    latest_tag=$(git tag --list 'v*' --sort=-v:refname | sed -n '1s/^v//p')
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
    if [ "$first_release" = 1 ]; then
        # The manifest already holds $V — a first release publishes it as-is, so
        # there is nothing to rewrite and nothing to commit. Tag HEAD, which
        # common_preflight has already established is clean and on the main branch.
        git tag -a "$tag" -m "Release $V"
        acted=1
        note "tag: $tag created locally (manifest already at $V)"
        return
    fi
    local prev
    prev=$(jq -r .version "$manifest")
    tmp=$(mktemp)
    jq --arg v "$V" '.version = $v' "$manifest" > "$tmp"
    mv "$tmp" "$manifest"
    git add "$manifest"
    # A consumer's pre-commit hook can refuse this commit. Dying here with the
    # bump written and staged strands it: nothing committed, nothing tagged, and
    # a dirty manifest that then blocks BOTH a re-run and --resume on
    # common_preflight's "uncommitted changes" — which names neither the gate nor
    # the leftover. Restoring from HEAD leaves the tree as this run found it, so
    # satisfying the gate and re-running is the whole recovery.
    git commit -m "release: $V" || {
        git checkout HEAD -- "$manifest"
        printf 'hint: the manifest was rolled back to %s and nothing was tagged.\n' "$prev" >&2
        printf '      fix what the gate reported above, then run the same command again.\n' >&2
        die "commit gate refused the release commit"
    }
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
    # A consumer's pre-push hook can refuse this. gitlore's publishes every
    # memory store before the parent push and refuses when one diverged, and the
    # window it opens is human-paced: the release commit's own approval round
    # sits inside it. The commit and the tag are already local, so the recovery
    # is resume — never an amend re-pinning the gitlink at the merged memory.
    # The gitlink a release commit records is always an ancestor of memory's
    # `live` or `live` itself (each merge takes the pending commit as its second
    # parent), and a push of `live` publishes every ancestor — so nothing needs
    # the tagged commit to name the merge, and the tag is never rewritten.
    # shellcheck disable=SC2016  # backticks are literal markdown, not command substitution
    git push || {
        printf 'hint: the release commit and tag %s are local; nothing was pushed.\n' "$tag" >&2
        printf '      clear what the push reported above, then run `just resume-release`.\n' >&2
        printf '      gitlore refuses the push while a memory store is diverged: `/gitlore:resolve`\n' >&2
        printf '      in Claude Code clears it. Repeat the pair if the push is refused again.\n' >&2
        die "push of $branch failed"
    }
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
    # A no-op rewrite (marketplace already at $V) must not touch the file: the
    # mktemp+mv replace needs to unlink and recreate marketplace.json in its
    # directory, which a sandboxed resume-release can't do even when nothing
    # actually needs to change.
    if cmp -s "$mp_tmp" "$marketplace_json"; then
        rm -f "$mp_tmp"
    else
        check_marketplace_writable
        # mktemp creates 0600 and mv carries that mode onto the destination, so
        # every bump silently narrowed a tracked file. 644 is the mode a clone
        # of the marketplace repo gets under the usual umask; the mv is kept
        # (rather than writing through the file) because the no-op guard above
        # depends on the replace needing directory write, not file write.
        chmod 644 "$mp_tmp"
        mv "$mp_tmp" "$marketplace_json"
        git -C "$MARKETPLACE_DIR" add .claude-plugin/marketplace.json
    fi
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
