#!/usr/bin/env bats
# Tests for scripts/precompact-probe.sh — the read-only durable-progress
# detector the precompact skill runs before /compact. Builds synthetic repos
# and asserts the probe's stdout contract:
#   not a git repo                     -> silent (empty stdout)
#   git repo, no known ledger          -> silent
#   git repo + SDD progress ledger     -> flush directive naming the file
#
# The probe owns the plugin-specific vocabulary (superpowers SDD); the skill
# body stays vocab-free. Detection is file existence under git root — the same
# root SDD's own sdd-workspace resolves via `git rev-parse --show-toplevel`.
#
# Run with: bats tests/precompact-probe.bats   (from plugin root)

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PROBE="$repo_root/scripts/precompact-probe.sh"
    SHIM="$repo_root/bin/handoff-precompact-probe"
}

# A git repo with an SDD progress ledger materialized at the path SDD uses.
make_sdd_repo() {
    local repo="$BATS_TEST_TMPDIR/sddrepo"
    rm -rf "$repo"; mkdir -p "$repo/.superpowers/sdd"
    git -C "$repo" init -q
    printf '*\n' > "$repo/.superpowers/sdd/.gitignore"
    cat > "$repo/.superpowers/sdd/progress.md" <<'EOF'
Task 1: complete (commits abc1234..def5678, review clean)
EOF
    printf '%s\n' "$repo"
}

@test "probe: not a git repo -> silent" {
    plain="$BATS_TEST_TMPDIR/plain"; mkdir -p "$plain"
    run bash -c 'cd "$1" && bash "$2"' _ "$plain" "$PROBE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: git repo, no SDD ledger -> silent" {
    repo="$BATS_TEST_TMPDIR/bare"; mkdir -p "$repo"
    git -C "$repo" init -q
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: SDD ledger present -> flush directive naming the file" {
    repo="$(make_sdd_repo)"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF '.superpowers/sdd/progress.md'
    echo "$output" | grep -qi 'complete'
    echo "$output" | grep -qi 'minor'
    echo "$output" | grep -qi 're-dispatch'
}

@test "probe: ledger detected from a subdirectory of the repo -> directive" {
    repo="$(make_sdd_repo)"
    mkdir -p "$repo/pkg/src"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo/pkg/src" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF '.superpowers/sdd/progress.md'
}

@test "shim: bin/handoff-precompact-probe execs the probe (ledger -> directive)" {
    repo="$(make_sdd_repo)"
    run bash -c 'cd "$1" && "$2"' _ "$repo" "$SHIM"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF '.superpowers/sdd/progress.md'
}
