#!/usr/bin/env bats
# Tests for scripts/memory-probe.sh — the read-only gitlore-memory detector
# the handoff skill runs at wrap-up. Builds a synthetic gitlore repo (see
# tests/probe-helpers.bash) and asserts the probe's stdout contract:
#   not gitlore / clean / unmaterialized  -> silent (empty stdout)
#   dirty                                 -> file-trigger directive naming
#                                            the message + trigger paths
#
# The directive body itself lives in scripts/_probe-lib.sh and is shared with
# the precompact probe; this suite pins handoff's composition of it (memory
# directive alone, no SDD nudge).
#
# Run with: bats tests/memory-probe.bats   (from plugin root)

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PROBE="$repo_root/scripts/memory-probe.sh"
    SHIM="$repo_root/bin/handoff-memory-probe"
    load probe-helpers
}

@test "probe: not gitlore-managed -> silent" {
    plain="$BATS_TEST_TMPDIR/plain"; mkdir -p "$plain"
    git -C "$plain" init -q
    run bash -c 'cd "$1" && bash "$2"' _ "$plain" "$PROBE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: gitlore + clean memory -> silent" {
    repo="$(make_gitlore_repo)"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: submodule registered but not materialized -> silent" {
    repo="$(make_gitlore_repo)"
    rm -rf "$repo/memory/.git"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: gitlore stanza but empty path -> silent" {
    repo="$(make_gitlore_repo)"
    git -C "$repo" config --file "$repo/.gitmodules" \
        --unset submodule.gitlore-memory.path
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: dirty memory -> directive naming both IPC file paths" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'uncommitted changes'
    echo "$output" | grep -q 'feedback_x.md'
    echo "$output" | grep -qF "$repo/.claude/gitlore-memory-message"
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
}

@test "probe: dirty memory -> directive demands blockquote + approval" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi 'blockquote'
    echo "$output" | grep -qi 'approv'
}

@test "probe: dirty memory -> no stale commit-memory Bash path" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"-F -"* ]]
    [[ "$output" != *"commitCommand"* ]]
}

# A workflow ledger outlives a /clear exactly as it outlives a compaction, so
# handoff carries the todo-file suppression — but NOT the precompact-only
# bring-the-ledger-current nudge.
@test "probe: handoff composition carries the todo suppression, not the SDD nudge" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF '.superpowers/sdd/progress.md'
    echo "$output" | grep -qF 'handoff-todo.md'
    [[ "$output" != *"Minor findings"* ]]
    [[ "$output" != *"re-dispatched"* ]]
}

@test "probe: clean memory + SDD ledger -> suppression alone" {
    repo="$(make_gitlore_repo)"
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF 'handoff-todo.md'
    [[ "$output" != *"gitlore-commit-memory"* ]]
}

# No ledger is the common case: nothing suppresses the todo file, so the
# probe must not mention it at all.
@test "probe: dirty memory, no ledger -> no todo suppression" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"handoff-todo.md"* ]]
}

@test "probe: detected from a subdirectory of the repo -> directive" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    mkdir -p "$repo/pkg/src"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo/pkg/src" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
}

@test "shim: bin/handoff-memory-probe execs the probe (dirty -> directive)" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && "$2"' _ "$repo" "$SHIM"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
}
