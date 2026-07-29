#!/usr/bin/env bash
# End-to-end test of release.sh against real git repos in a temp dir.
# No network: origins are local bare repos and `gh` is a stub on PATH.
#
# Usage: bash tests/release-test.sh   (run from repo root)
set -euo pipefail

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

if (( failures > 0 )); then
    printf '\n%d failure(s)\n' "$failures" >&2
    exit 1
fi
printf '\nall release scenarios passed\n'
