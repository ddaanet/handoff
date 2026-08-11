#!/usr/bin/env bash
# End-to-end test of release.just's `update-plugin-dev` recipe against real
# git repos in a temp dir. No network: the toolkit and its "memory" submodule
# are local bare repos.
#
# Usage: bash tests/update-plugin-dev-test.sh   (run from repo root)
set -euo pipefail

# See release-test.sh's identical comment: an enclosing `git commit` leaks
# GIT_DIR/GIT_INDEX_FILE/etc. into this process. Every git command below
# targets a synthetic fixture repo via `-C`, never this repo, so it's always
# safe to drop them here.
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

# Recursive submodule transports (add/subtree's on-demand submodule fetch)
# default protocol.file.allow to "user", which local bare-repo fixtures still
# trip on. Every git call below targets local paths only, so allow it broadly
# instead of threading `-c` through each call site.
allow_file() {
    env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always "$@"
}

git_id() {
    git -C "$1" config user.email test@example.com
    git -C "$1" config user.name "Toolkit Test"
    git -C "$1" config commit.gpgsign false
}

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

# Advances the fixture toolkit repo (shaped like this repo: a `memory`
# submodule mounted at top level, a VERSION file at root) by one commit and
# tags it, mirroring a toolkit release.
make_toolkit_release() {
    local toolkit="$1" tag="$2" version="$3"
    printf '%s\n' "$version" > "$toolkit/VERSION"
    git -C "$toolkit" add -A
    git -C "$toolkit" commit -qm "toolkit: $version"
    git -C "$toolkit" tag "$tag"
}

new_sandbox() {
    # Sets $sandbox, $toolkit, $consumer.
    sandbox="$(mktemp -d)"
    sandboxes+=("$sandbox")
    toolkit="$sandbox/toolkit"
    consumer="$sandbox/consumer"

    # Toolkit-side memory remote, standing in for claude-plugin-dev-memory.git.
    git init -q --bare -b main "$sandbox/toolkit-memory-origin.git"
    local seed
    seed="$(mktemp -d)"
    git init -q -b main "$seed"
    git_id "$seed"
    git -C "$seed" commit --allow-empty -qm seed
    git -C "$seed" remote add origin "$sandbox/toolkit-memory-origin.git"
    git -C "$seed" push -q -u origin main
    rm -rf "$seed"

    git init -q -b main "$toolkit"
    git_id "$toolkit"
    git -C "$toolkit" commit --allow-empty -qm init
    allow_file git -C "$toolkit" submodule add -q "$sandbox/toolkit-memory-origin.git" memory
    git -C "$toolkit" commit -qm "toolkit: mount memory"
    make_toolkit_release "$toolkit" v1 1.0.0

    # Consumer-side memory remote: unrelated to the toolkit's, same path.
    git init -q --bare -b main "$sandbox/consumer-memory-origin.git"
    seed="$(mktemp -d)"
    git init -q -b main "$seed"
    git_id "$seed"
    git -C "$seed" commit --allow-empty -qm seed
    git -C "$seed" remote add origin "$sandbox/consumer-memory-origin.git"
    git -C "$seed" push -q -u origin main
    rm -rf "$seed"

    git init -q -b main "$consumer"
    git_id "$consumer"
    git -C "$consumer" commit --allow-empty -qm init
}

echo "=== update-plugin-dev: survives a consumer's unrelated memory submodule at the same path ==="
new_sandbox

# Vendor the toolkit first, like install.sh's initial `subtree add` -- before
# the consumer mounts its own memory submodule. This is the real-world order
# (install, then `/gitlore:add-tier` later), and the initial add has no
# collision to hit yet, since the consumer has no submodule registered at
# "memory" at this point.
run_in "$consumer" allow_file git subtree add --prefix=plugin-dev "$toolkit" v1 --squash
assert_eq "$rc" "0" "initial vendor exit code"
assert_eq "$(cat "$consumer/plugin-dev/VERSION" 2>/dev/null)" "1.0.0" "initial vendor VERSION"

# Consumer mounts its own gitlore memory submodule at the same top-level path
# the toolkit uses internally for its own memory -- this is the collision
# surface: `fetch.recurseSubmodules=on-demand` will try to resolve the
# toolkit's "memory" gitlink using the CONSUMER's registered submodule URL.
run_in "$consumer" allow_file git submodule add -q "$sandbox/consumer-memory-origin.git" memory
assert_eq "$rc" "0" "consumer memory submodule mount exit code"
git -C "$consumer" commit -qm "consumer: mount memory"

# The toolkit releases a new version.
make_toolkit_release "$toolkit" v2 1.0.1

# A consumer justfile importing THIS repo's real release.just, so the recipe
# under test is the one about to ship, not a copy.
printf "import '%s/release.just'\n\nprecommit:\n    @echo stub-precommit\n\nprerelease: precommit\n" \
    "$repo_root" > "$consumer/justfile"

run_in "$consumer" allow_file just --set toolkit_url "$toolkit" update-plugin-dev v2
assert_eq "$rc" "0" "update-plugin-dev exit code through the submodule collision"
if grep -q 'not our ref' <<< "$out"; then
    fail "update-plugin-dev output shows the submodule collision (not our ref)"
    printf '  --- output ---\n%s\n  --------------\n' "$out" >&2
fi
assert_eq "$(cat "$consumer/plugin-dev/VERSION" 2>/dev/null)" "1.0.1" "update-plugin-dev pulled the new VERSION"
assert_eq "$(git -C "$consumer" config --get submodule.memory.url)" \
    "$sandbox/consumer-memory-origin.git" "consumer's own memory submodule registration untouched"

if (( failures > 0 )); then
    printf '\n%d failure(s)\n' "$failures" >&2
    exit 1
fi
printf '\nupdate-plugin-dev scenarios passed\n'
