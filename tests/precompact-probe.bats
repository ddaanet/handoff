#!/usr/bin/env bats
# Tests for scripts/precompact-probe.sh — the read-only detector the precompact
# skill runs before /compact. It composes TWO concerns out of
# scripts/_probe-lib.sh, so the skill body stays vocab-free:
#   dirty gitlore memory  -> file-trigger memory-commit directive
#   SDD progress ledger   -> bring-the-ledger-current nudge
#   both                  -> both, memory directive first
#   neither               -> silent (empty stdout)
#
# Memory comes first because it is the one interactive gate (FR11 approval)
# and must land as a durable commit before the summariser runs.
#
# Run with: bats tests/precompact-probe.bats   (from plugin root)

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PROBE="$repo_root/scripts/precompact-probe.sh"
    SHIM="$repo_root/bin/handoff-precompact-probe"
    load probe-helpers
}

@test "probe: not a git repo -> silent" {
    plain="$BATS_TEST_TMPDIR/plain"; mkdir -p "$plain"
    run bash -c 'cd "$1" && bash "$2"' _ "$plain" "$PROBE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: git repo, no ledger and no gitlore -> silent" {
    repo="$BATS_TEST_TMPDIR/bare"; mkdir -p "$repo"
    git -C "$repo" init -q
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: gitlore + clean memory, no ledger -> silent" {
    repo="$(make_gitlore_repo)"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: SDD ledger only -> nudge, no memory directive" {
    repo="$BATS_TEST_TMPDIR/sddonly"; mkdir -p "$repo"
    git -C "$repo" init -q
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF '.superpowers/sdd/progress.md'
    echo "$output" | grep -qi 'minor'
    echo "$output" | grep -qi 're-dispatch'
    [[ "$output" != *"gitlore-commit-memory"* ]]
}

@test "probe: dirty memory only -> memory directive, no SDD nudge" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-memory-message"
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
    echo "$output" | grep -qi 'blockquote'
    [[ "$output" != *".superpowers/sdd/progress.md"* ]]
}

@test "probe: dirty memory + SDD ledger -> both, memory directive first" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
    echo "$output" | grep -qF '.superpowers/sdd/progress.md'
    mem_line=$(echo "$output" | grep -nF 'gitlore-commit-memory' | head -1 | cut -d: -f1)
    sdd_line=$(echo "$output" | grep -nF '.superpowers/sdd/progress.md' | head -1 | cut -d: -f1)
    [ "$mem_line" -lt "$sdd_line" ]
}

@test "probe: clean memory + SDD ledger -> nudge only" {
    repo="$(make_gitlore_repo)"
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF '.superpowers/sdd/progress.md'
    [[ "$output" != *"gitlore-commit-memory"* ]]
}

@test "probe: composed output detected from a subdirectory -> both" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    add_sdd_ledger "$repo"
    mkdir -p "$repo/pkg/src"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo/pkg/src" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
    echo "$output" | grep -qF '.superpowers/sdd/progress.md'
}

@test "shim: bin/handoff-precompact-probe execs the probe (ledger -> nudge)" {
    repo="$BATS_TEST_TMPDIR/shimrepo"; mkdir -p "$repo"
    git -C "$repo" init -q
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && "$2"' _ "$repo" "$SHIM"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF '.superpowers/sdd/progress.md'
}
