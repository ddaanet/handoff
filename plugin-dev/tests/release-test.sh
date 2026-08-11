#!/usr/bin/env bash
# End-to-end test of release.sh against real git repos in a temp dir.
# No network: origins are local bare repos and `gh` is a stub on PATH.
#
# Usage: bash tests/release-test.sh   (run from repo root)
set -euo pipefail

# When run as this repo's own pre-commit hook, the enclosing `git commit`
# leaks GIT_DIR/GIT_INDEX_FILE/etc. into this process's environment. Every
# git command below targets a synthetic fixture repo via `-C`, never this
# repo, so it's always safe to drop them here.
# shellcheck disable=SC2046  # word-splitting is the point: a var-name list
unset $(git rev-parse --local-env-vars)

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

failures=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}
assert_eq() {
    # $1=actual $2=expected $3=label
    if [[ "$1" != "$2" ]]; then
        fail "$3: expected '$2', got '$1'"
    fi
}
assert_contains() {
    # $1=haystack $2=needle $3=label
    if ! printf '%s' "$1" | grep -q -- "$2"; then
        fail "$3: output did not contain '$2'"
        printf '  --- output ---\n%s\n  --------------\n' "$1" >&2
    fi
}

sandboxes=()
cleanup() {
    local s
    for s in "${sandboxes[@]:-}"; do
        [ -n "$s" ] && rm -rf "$s"
    done
}
trap cleanup EXIT

# out/rc from the last run_in call.
out=""
rc=0
run_in() {
    # $1=dir, rest=command. Captures stdout+stderr in $out, status in $rc.
    local dir="$1"
    shift
    set +e
    out="$(cd "$dir" && "$@" 2>&1)"
    rc=$?
    set -e
}

git_init() {
    # $1=path. A repo with a deterministic identity and a bare origin.
    git init -q -b main "$1"
    git -C "$1" config user.email test@example.com
    git -C "$1" config user.name "Toolkit Test"
    git -C "$1" config commit.gpgsign false
    git init -q --bare -b main "$1-origin.git"
    git -C "$1" remote add origin "$1-origin.git"
}

new_sandbox() {
    # $1=marketplace entry version, or "" for no entry (first publication).
    # Sets $sandbox, $plugin, $marketplace; exports MARKETPLACE_DIR, PATH, GH_*.
    local entry_version="$1"
    sandbox="$(mktemp -d)"
    sandboxes+=("$sandbox")
    plugin="$sandbox/plugin"
    marketplace="$sandbox/marketplace"

    # gh stub: records every call, and "remembers" created releases as marker
    # files so `release view` can answer truthfully on a second run.
    mkdir -p "$sandbox/bin" "$sandbox/releases"
    cat > "$sandbox/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
    "release view")   [ -f "$GH_RELEASES/$3" ] || exit 1 ;;
    "release create") : > "$GH_RELEASES/$3" ;;
    *) printf 'gh stub: unhandled: %s\n' "$*" >&2; exit 127 ;;
esac
STUB
    chmod +x "$sandbox/bin/gh"
    export GH_LOG="$sandbox/gh.log"
    export GH_RELEASES="$sandbox/releases"
    : > "$GH_LOG"
    export PATH="$sandbox/bin:$PATH"

    # Fixture plugin, vendoring the toolkit the way a consumer does.
    git_init "$plugin"
    mkdir -p "$plugin/.claude-plugin" "$plugin/plugin-dev"
    cat > "$plugin/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "fixture",
  "version": "1.2.3",
  "description": "test fixture",
  "license": "MIT"
}
JSON
    cp "$repo_root/release.sh" "$repo_root/check-version.sh" "$plugin/plugin-dev/"
    git -C "$plugin" add -A
    git -C "$plugin" commit -qm "init"
    git -C "$plugin" tag -a v1.2.3 -m "Release 1.2.3"
    git -C "$plugin" push -q -u origin main
    git -C "$plugin" push -q origin v1.2.3
    git -C "$plugin" remote set-head origin main

    # Fixture marketplace.
    git_init "$marketplace"
    mkdir -p "$marketplace/.claude-plugin"
    if [ -n "$entry_version" ]; then
        jq -n --arg v "$entry_version" \
            '{plugins: [{name: "fixture", source: {source: "github", repo: "o/fixture"}, version: $v}]}' \
            > "$marketplace/.claude-plugin/marketplace.json"
    else
        jq -n '{plugins: []}' > "$marketplace/.claude-plugin/marketplace.json"
    fi
    git -C "$marketplace" add -A
    git -C "$marketplace" commit -qm "init"
    git -C "$marketplace" push -q -u origin main
    export MARKETPLACE_DIR="$marketplace"
}

market_version() {
    jq -r '.plugins[] | select(.name=="fixture") | .version' \
        "$marketplace/.claude-plugin/marketplace.json"
}

mount_resting_memory_submodule() {
    # $1=parent repo path. Mounts a `memory` git submodule and commits the
    # mount, then advances the submodule's checked-out HEAD by one commit
    # without folding the moved gitlink into a parent commit — gitlore's
    # ordinary resting state between commits (see release.sh's
    # common_preflight comment on the memory pathspec exclusion).
    local parent="$1" sub_origin sub_seed
    sub_origin="$parent-memory-origin.git"
    sub_seed=$(mktemp -d)
    git init -q --bare -b main "$sub_origin"
    git init -q -b main "$sub_seed"
    git -C "$sub_seed" config user.email test@example.com
    git -C "$sub_seed" config user.name "Toolkit Test"
    git -C "$sub_seed" config commit.gpgsign false
    printf 'seed\n' > "$sub_seed/MEMORY.md"
    git -C "$sub_seed" add -A
    git -C "$sub_seed" commit -qm seed
    git -C "$sub_seed" remote add origin "$sub_origin"
    git -C "$sub_seed" push -q -u origin main
    rm -rf "$sub_seed"

    env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
        git -C "$parent" submodule add -q "$sub_origin" memory
    git -C "$parent" commit -qm "mount memory submodule"

    printf 'advance\n' >> "$parent/memory/MEMORY.md"
    git -C "$parent/memory" add -A
    git -C "$parent/memory" -c user.email=test@example.com -c user.name="Toolkit Test" \
        -c commit.gpgsign=false commit -qm advance
    # Deliberately no parent commit here.
}

make_virgin() {
    # $1=manifest version. Strips the fixture's release history so the plugin
    # has never been released: no v* tags locally or on origin, and the manifest
    # seeded at $1. Paired with new_sandbox "" (no marketplace entry) this is
    # the state a plugin scaffolded by the external plugin-dev marketplace
    # plugin arrives in; paired with new_sandbox "1.2.3" it isolates the
    # no-tags half of the conjunct.
    git -C "$plugin" tag -d v1.2.3 >/dev/null
    git -C "$plugin" push -q origin :refs/tags/v1.2.3
    jq --arg v "$1" '.version = $v' "$plugin/.claude-plugin/plugin.json" \
        > "$plugin/.claude-plugin/plugin.json.tmp"
    mv "$plugin/.claude-plugin/plugin.json.tmp" "$plugin/.claude-plugin/plugin.json"
    git -C "$plugin" add -A
    # Seeding the version the fixture already carries stages nothing, and a
    # no-op `git commit` is a hard error under set -e.
    if ! git -C "$plugin" diff --cached --quiet; then
        git -C "$plugin" commit -qm "scaffold at $1"
    fi
    git -C "$plugin" push -q origin main
}

echo "=== release: happy path ==="
new_sandbox "1.2.3"
run_in "$plugin" bash plugin-dev/release.sh patch
assert_eq "$rc" "0" "happy-path exit code"
assert_contains "$out" "Release v1.2.4 complete" "happy-path summary"
assert_eq "$(jq -r .version "$plugin/.claude-plugin/plugin.json")" "1.2.4" "manifest version"
assert_eq "$(git -C "$plugin" rev-parse --verify -q refs/tags/v1.2.4 >/dev/null && echo yes || echo no)" \
    "yes" "local tag created"
assert_eq "$(git -C "$plugin" ls-remote origin refs/tags/v1.2.4 | wc -l | tr -d ' ')" \
    "1" "tag pushed to origin"
assert_contains "$(cat "$GH_LOG")" "release create v1.2.4" "gh release created"
assert_eq "$(market_version)" "1.2.4" "marketplace bumped"
assert_eq "$(git -C "$marketplace" log -1 --format=%s)" "release: fixture 1.2.4" "marketplace commit"

echo "=== release: first publication creates the marketplace entry ==="
new_sandbox ""   # empty .plugins — pre-first-publication
run_in "$plugin" bash plugin-dev/release.sh minor
assert_eq "$rc" "0" "first-publication exit code"
assert_contains "$out" "marketplace: entry created at 1.3.0" "first-publication summary"
entry="$(jq -c '.plugins[] | select(.name=="fixture")' \
    "$marketplace/.claude-plugin/marketplace.json")"
assert_eq "$(printf '%s' "$entry" | jq -r .version)" "1.3.0" "created entry version"
assert_eq "$(printf '%s' "$entry" | jq -r .source.source)" "github" "created entry source type"
assert_eq "$(printf '%s' "$entry" | jq -r .license)" "MIT" "created entry license from manifest"
assert_eq "$(printf '%s' "$entry" | jq -r .description)" "test fixture" "created entry description"
# The repo slug is derived from origin, which is a local path in the fixture:
# it must be a non-empty owner/repo pair, not the whole path.
assert_eq "$(printf '%s' "$entry" | jq -r '.source.repo | split("/") | length')" \
    "2" "created entry repo slug shape"

echo "=== resume: completes a release whose push was rejected ==="
new_sandbox "1.2.3"
# A pre-push hook that refuses, reproducing the gitlore 0.4.3 failure: the
# recipe dies after the irreversible commit and tag, before the tag push.
cat > "$plugin/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
echo "pre-push: refusing" >&2
exit 1
HOOK
chmod +x "$plugin/.git/hooks/pre-push"
run_in "$plugin" bash plugin-dev/release.sh patch
assert_eq "$rc" "1" "interrupted release exit code"
assert_eq "$(jq -r .version "$plugin/.claude-plugin/plugin.json")" "1.2.4" "manifest bumped before the failure"
assert_eq "$(git -C "$plugin" ls-remote origin refs/tags/v1.2.4 | wc -l | tr -d ' ')" \
    "0" "tag not on origin after the failure"
assert_eq "$(market_version)" "1.2.3" "marketplace still stale after the failure"

rm -f "$plugin/.git/hooks/pre-push"
run_in "$plugin" bash plugin-dev/release.sh --resume
assert_eq "$rc" "0" "resume exit code"
assert_eq "$(git -C "$plugin" ls-remote origin refs/heads/main | cut -f1)" \
    "$(git -C "$plugin" rev-parse HEAD)" "resume pushed the branch"
assert_eq "$(git -C "$plugin" ls-remote origin refs/tags/v1.2.4 | wc -l | tr -d ' ')" \
    "1" "resume pushed the tag"
assert_contains "$(cat "$GH_LOG")" "release create v1.2.4" "resume created the GitHub release"
assert_eq "$(market_version)" "1.2.4" "resume bumped the marketplace"
assert_contains "$out" "Release v1.2.4 complete" "resume summary"

echo "=== resume: completes a release whose marketplace push was rejected ==="
new_sandbox "1.2.3"
# Same idea as the plugin-push scenario above, but the rejecting hook sits on
# the marketplace repo: the marketplace commit lands locally, its push fails,
# and a naive "is the working tree at $V" probe would call that done.
cat > "$marketplace/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
echo "pre-push: refusing" >&2
exit 1
HOOK
chmod +x "$marketplace/.git/hooks/pre-push"
run_in "$plugin" bash plugin-dev/release.sh patch
assert_eq "$rc" "1" "marketplace-push-interrupted release exit code"
assert_eq "$(git -C "$plugin" ls-remote origin refs/tags/v1.2.4 | wc -l | tr -d ' ')" \
    "1" "plugin tag reached origin despite the marketplace push failure"
assert_eq "$(market_version)" "1.2.4" "marketplace committed locally despite the failure"
assert_eq "$(git -C "$marketplace" ls-remote origin refs/heads/main | cut -f1)" \
    "$(git -C "$marketplace" log -1 --format=%H HEAD^)" "marketplace origin not yet at the bumped commit"

rm -f "$marketplace/.git/hooks/pre-push"
run_in "$plugin" bash plugin-dev/release.sh --resume
assert_eq "$rc" "0" "marketplace-push resume exit code"
assert_eq "$(git -C "$marketplace" ls-remote origin refs/heads/main | cut -f1)" \
    "$(git -C "$marketplace" rev-parse HEAD)" "resume pushed the marketplace"
if printf '%s' "$out" | grep -q "already complete (nothing to do)"; then
    fail "marketplace-push resume falsely claimed nothing-to-do"
fi
assert_contains "$out" "Release v1.2.4 complete" "marketplace-push resume summary"

echo "=== resume: completes a first-publication release whose marketplace push was rejected ==="
new_sandbox ""   # empty .plugins — pre-first-publication, same as the plain
                 # first-publication scenario above, but interrupted+resumed.
cat > "$marketplace/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
echo "pre-push: refusing" >&2
exit 1
HOOK
chmod +x "$marketplace/.git/hooks/pre-push"
run_in "$plugin" bash plugin-dev/release.sh minor
assert_eq "$rc" "1" "first-publication marketplace-push-interrupted release exit code"
assert_eq "$(jq -r .version "$plugin/.claude-plugin/plugin.json")" "1.3.0" "manifest bumped despite the marketplace push failure"
assert_eq "$(jq '[.plugins[] | select(.name=="fixture")] | length' "$marketplace/.claude-plugin/marketplace.json")" \
    "1" "marketplace entry created locally despite the failure"

rm -f "$marketplace/.git/hooks/pre-push"
run_in "$plugin" bash plugin-dev/release.sh --resume
assert_eq "$rc" "0" "first-publication resume exit code"
assert_contains "$out" "Release v1.3.0 complete" "first-publication resume summary"
assert_eq "$(git -C "$marketplace" ls-remote origin refs/heads/main | cut -f1)" \
    "$(git -C "$marketplace" rev-parse HEAD)" "first-publication resume pushed the marketplace"
assert_eq "$(jq '[.plugins[] | select(.name=="fixture")] | length' "$marketplace/.claude-plugin/marketplace.json")" \
    "1" "first-publication resume created the entry exactly once, not a duplicate"
assert_eq "$(market_version)" "1.3.0" "first-publication resume entry version"

echo "=== resume: refuses to move a tag origin already has elsewhere ==="
new_sandbox "1.2.3"
init_sha="$(git -C "$plugin" rev-parse HEAD)"   # the "init" commit, already on origin
cat > "$plugin/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
echo "pre-push: refusing" >&2
exit 1
HOOK
chmod +x "$plugin/.git/hooks/pre-push"
run_in "$plugin" bash plugin-dev/release.sh patch
assert_eq "$rc" "1" "setup interrupted release exit code"
rm -f "$plugin/.git/hooks/pre-push"
# Simulate someone else publishing a different v1.2.4 on origin while this
# release was stalled: point the plugin origin's tag at the pre-bump commit,
# not this run's local tag.
git -C "$plugin-origin.git" tag v1.2.4 "$init_sha"
run_in "$plugin" bash plugin-dev/release.sh --resume
assert_eq "$rc" "1" "moved-tag resume exit code"
assert_contains "$out" "refusing to move a published tag" "moved-tag resume message"
assert_eq "$(cat "$GH_LOG")" "" "moved-tag resume must not call gh"
assert_eq "$(market_version)" "1.2.3" "moved-tag resume must not touch the marketplace"

echo "=== resume: refuses when no tag exists for the manifest version ==="
new_sandbox "1.2.3"
git -C "$plugin" tag -d v1.2.3 >/dev/null
run_in "$plugin" bash plugin-dev/release.sh --resume
assert_eq "$rc" "1" "no-tag resume exit code"
assert_contains "$out" "no tag v1.2.3 for plugin.json version 1.2.3" "no-tag resume message"
assert_contains "$out" "run \`just release <bump>\` instead" "no-tag resume hint"
assert_eq "$(cat "$GH_LOG")" "" "no-tag resume must not call gh"

echo "=== resume: no-op on a healthy repo ==="
new_sandbox "1.2.3"
run_in "$plugin" bash plugin-dev/release.sh patch
assert_eq "$rc" "0" "setup release exit code"
: > "$GH_LOG"
marketplace_head_before="$(git -C "$marketplace" rev-parse HEAD)"
run_in "$plugin" bash plugin-dev/release.sh --resume
assert_eq "$rc" "0" "healthy resume exit code"
assert_contains "$out" "already complete (nothing to do)" "healthy resume summary"
assert_contains "$(cat "$GH_LOG")" "release view v1.2.4" "healthy resume probed the release"
if grep -q "release create" "$GH_LOG"; then
    fail "healthy resume re-created the GitHub release"
fi
assert_eq "$(git -C "$marketplace" rev-parse HEAD)" "$marketplace_head_before" \
    "healthy resume left the marketplace untouched"

echo "=== release: unknown option is refused cleanly ==="
new_sandbox "1.2.3"
run_in "$plugin" bash plugin-dev/release.sh --bogus
assert_eq "$rc" "1" "unknown option exit code"
assert_contains "$out" "unknown option: --bogus" "unknown option message"
assert_eq "$(cat "$GH_LOG")" "" "unknown option must not call gh"

echo "=== release: unknown bump word is refused cleanly ==="
new_sandbox "1.2.3"
run_in "$plugin" bash plugin-dev/release.sh bogusword
assert_eq "$rc" "1" "unknown bump word exit code"
assert_contains "$out" "unknown bump type: bogusword" "unknown bump word message"
assert_contains "$out" "usage: release.sh" "unknown bump word usage hint"
assert_eq "$(jq -r .version "$plugin/.claude-plugin/plugin.json")" "1.2.3" "unknown bump word left manifest untouched"
assert_eq "$(git -C "$plugin" rev-parse --verify -q refs/tags/v1.2.4 >/dev/null && echo yes || echo no)" \
    "no" "unknown bump word created no tag"
assert_eq "$(cat "$GH_LOG")" "" "unknown bump word must not call gh"

echo "=== release: refuses when the marketplace directory isn't writable ==="
new_sandbox "1.2.3"
chmod 555 "$marketplace/.claude-plugin"
run_in "$plugin" bash plugin-dev/release.sh patch
chmod 755 "$marketplace/.claude-plugin"
assert_eq "$rc" "1" "read-only marketplace dir exit code"
assert_contains "$out" "$marketplace/.claude-plugin is not writable" "read-only marketplace dir message names the path"
assert_contains "$out" "dangerouslyDisableSandbox" "read-only marketplace dir message names the sandbox escape"
assert_contains "$out" "/add-dir $marketplace" "read-only marketplace dir message names the add-dir escape"
assert_eq "$(jq -r .version "$plugin/.claude-plugin/plugin.json")" "1.2.3" "read-only marketplace dir left manifest untouched"
assert_eq "$(git -C "$plugin" rev-parse --verify -q refs/tags/v1.2.4 >/dev/null && echo yes || echo no)" \
    "no" "read-only marketplace dir created no tag"
assert_eq "$(cat "$GH_LOG")" "" "read-only marketplace dir must not call gh"

echo "=== resume: succeeds on a no-op marketplace bump even when its directory isn't writable ==="
new_sandbox "1.2.3"
run_in "$plugin" bash plugin-dev/release.sh patch
assert_eq "$rc" "0" "setup release exit code"
chmod 555 "$marketplace/.claude-plugin"
run_in "$plugin" bash plugin-dev/release.sh --resume
chmod 755 "$marketplace/.claude-plugin"
assert_eq "$rc" "0" "no-op resume exit code despite read-only marketplace dir"
assert_contains "$out" "already complete (nothing to do)" "no-op resume summary despite read-only marketplace dir"

echo "=== resume: still refuses when a real marketplace write is needed and the directory isn't writable ==="
new_sandbox "1.2.3"
# Plugin push rejected: manifest+tag land locally, but the marketplace is
# never touched (still 1.2.3) — a real write is needed to catch it up.
cat > "$plugin/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
echo "pre-push: refusing" >&2
exit 1
HOOK
chmod +x "$plugin/.git/hooks/pre-push"
run_in "$plugin" bash plugin-dev/release.sh patch
assert_eq "$rc" "1" "setup interrupted-release exit code"
assert_eq "$(market_version)" "1.2.3" "setup marketplace still stale"
rm -f "$plugin/.git/hooks/pre-push"
chmod 555 "$marketplace/.claude-plugin"
run_in "$plugin" bash plugin-dev/release.sh --resume
chmod 755 "$marketplace/.claude-plugin"
assert_eq "$rc" "1" "real-write resume exit code"
assert_contains "$out" "$marketplace/.claude-plugin is not writable" "real-write resume message names the path"
assert_eq "$(git -C "$plugin" ls-remote origin refs/tags/v1.2.4 | wc -l | tr -d ' ')" \
    "1" "real-write resume still pushed the plugin tag before failing at the marketplace"
assert_eq "$(market_version)" "1.2.3" "real-write resume left the marketplace untouched"

echo "=== release: major bump end-to-end ==="
new_sandbox "1.2.3"
run_in "$plugin" bash plugin-dev/release.sh major
assert_eq "$rc" "0" "major bump exit code"
assert_contains "$out" "Release v2.0.0 complete" "major bump summary"
assert_eq "$(jq -r .version "$plugin/.claude-plugin/plugin.json")" "2.0.0" "major bump manifest version"
assert_eq "$(market_version)" "2.0.0" "major bump marketplace bumped"

echo "=== release: zero-argument shape defaults to patch ==="
new_sandbox "1.2.3"
run_in "$plugin" bash plugin-dev/release.sh
assert_eq "$rc" "0" "zero-argument exit code"
assert_contains "$out" "Release v1.2.4 complete" "zero-argument summary"
assert_eq "$(jq -r .version "$plugin/.claude-plugin/plugin.json")" "1.2.4" "zero-argument manifest version"
assert_eq "$(market_version)" "1.2.4" "zero-argument marketplace bumped"

echo "=== release: proceeds with a resting memory submodule in the plugin root ==="
new_sandbox "1.2.3"
mount_resting_memory_submodule "$plugin"
run_in "$plugin" bash plugin-dev/release.sh patch
assert_eq "$rc" "0" "resting-memory release exit code"
assert_contains "$out" "Release v1.2.4 complete" "resting-memory release summary"
assert_eq "$(market_version)" "1.2.4" "resting-memory release bumped the marketplace"

echo "=== release: still refuses a genuinely dirty non-memory path in the plugin root ==="
new_sandbox "1.2.3"
mount_resting_memory_submodule "$plugin"
jq '.description = "dirty"' "$plugin/.claude-plugin/plugin.json" > "$plugin/.claude-plugin/plugin.json.tmp"
mv "$plugin/.claude-plugin/plugin.json.tmp" "$plugin/.claude-plugin/plugin.json"
run_in "$plugin" bash plugin-dev/release.sh patch
assert_eq "$rc" "1" "dirty-plugin-root release exit code"
assert_contains "$out" "uncommitted changes" "dirty-plugin-root release message"
assert_eq "$(cat "$GH_LOG")" "" "dirty-plugin-root release must not call gh"

echo "=== release: proceeds with a resting memory submodule in the marketplace repo ==="
new_sandbox "1.2.3"
mount_resting_memory_submodule "$marketplace"
run_in "$plugin" bash plugin-dev/release.sh patch
assert_eq "$rc" "0" "resting-memory marketplace release exit code"
assert_contains "$out" "Release v1.2.4 complete" "resting-memory marketplace release summary"
assert_eq "$(market_version)" "1.2.4" "resting-memory marketplace release bumped the marketplace"

echo "=== release: still refuses a genuinely dirty non-memory path in the marketplace repo ==="
new_sandbox "1.2.3"
mount_resting_memory_submodule "$marketplace"
jq '.plugins[0].description = "dirty"' "$marketplace/.claude-plugin/marketplace.json" > "$marketplace/.claude-plugin/marketplace.json.tmp"
mv "$marketplace/.claude-plugin/marketplace.json.tmp" "$marketplace/.claude-plugin/marketplace.json"
run_in "$plugin" bash plugin-dev/release.sh patch
assert_eq "$rc" "1" "dirty-marketplace release exit code"
assert_contains "$out" "$MARKETPLACE_DIR has uncommitted changes" "dirty-marketplace release message"
assert_eq "$(cat "$GH_LOG")" "" "dirty-marketplace release must not call gh"

echo "=== release: a first release publishes the manifest version verbatim ==="
new_sandbox ""            # no marketplace entry
make_virgin "0.1.0"       # no v* tags, manifest seeded by an external scaffold
head_before="$(git -C "$plugin" rev-parse HEAD)"
run_in "$plugin" bash plugin-dev/release.sh
assert_eq "$rc" "0" "first-release exit code"
assert_contains "$out" "Release v0.1.0 complete" "first-release summary"
assert_eq "$(jq -r .version "$plugin/.claude-plugin/plugin.json")" "0.1.0" "first-release manifest untouched"
# Nothing to bump means nothing to commit: the tag lands on the commit that was
# already HEAD, not on a synthetic "release: 0.1.0" commit above it.
assert_eq "$(git -C "$plugin" rev-parse HEAD)" "$head_before" "first-release makes no commit"
assert_eq "$(git -C "$plugin" rev-parse -q --verify 'refs/tags/v0.1.0^{commit}')" \
    "$head_before" "first-release tags HEAD"
assert_eq "$(git -C "$plugin" ls-remote origin refs/tags/v0.1.0 | wc -l | tr -d ' ')" \
    "1" "first-release tag pushed to origin"
assert_contains "$(cat "$GH_LOG")" "release create v0.1.0" "first-release gh release created"
assert_eq "$(market_version)" "0.1.0" "first-release marketplace entry created at the manifest version"

echo "=== release: a first release refuses an explicit bump ==="
for word in patch minor major; do
    new_sandbox ""
    make_virgin "0.1.0"
    run_in "$plugin" bash plugin-dev/release.sh "$word"
    assert_eq "$rc" "1" "first-release '$word' exit code"
    assert_contains "$out" "never been released" "first-release '$word' explains why"
    assert_contains "$out" "0.1.0" "first-release '$word' names the version it would publish"
    assert_eq "$(git -C "$plugin" tag --list 'v*')" "" "first-release '$word' creates no tag"
    assert_eq "$(cat "$GH_LOG")" "" "first-release '$word' must not call gh"
    assert_eq "$(market_version)" "" "first-release '$word' must not touch the marketplace"
done

echo "=== release: a marketplace entry with no tags is not a first release ==="
new_sandbox "1.2.3"       # entry exists — this plugin HAS been published
make_virgin "1.2.3"       # ...but its tags are gone
run_in "$plugin" bash plugin-dev/release.sh patch
assert_eq "$rc" "0" "lost-tags exit code"
assert_contains "$out" "Release v1.2.4 complete" "lost-tags bumps forward instead of republishing"
assert_eq "$(jq -r .version "$plugin/.claude-plugin/plugin.json")" "1.2.4" "lost-tags manifest bumped"
assert_eq "$(market_version)" "1.2.4" "lost-tags marketplace bumped"

echo "=== release: tags with no marketplace entry is not a first release ==="
new_sandbox ""            # no entry...
run_in "$plugin" bash plugin-dev/release.sh patch   # ...but the fixture's v1.2.3 tag stands
assert_eq "$rc" "0" "tagged-unpublished exit code"
assert_contains "$out" "Release v1.2.4 complete" "tagged-unpublished bumps forward"
assert_eq "$(market_version)" "1.2.4" "tagged-unpublished marketplace entry created at the bumped version"

if (( failures > 0 )); then
    printf '\n%d failure(s)\n' "$failures" >&2
    exit 1
fi
printf '\nall release scenarios passed\n'
