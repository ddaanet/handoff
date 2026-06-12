#!/usr/bin/env bats
# Tests for scripts/memory-probe.sh — the read-only gitlore-memory detector
# the handoff skill runs at wrap-up. Builds a synthetic gitlore repo (a repo
# with a gitlore-memory submodule registration in .gitmodules and a nested
# memory git repo) and asserts the probe's stdout contract:
#   not gitlore / clean / unmaterialized  -> silent (empty stdout)
#   dirty + resolvable committer          -> directive naming `<abs> -F -`
#   dirty + unresolvable committer        -> restart hint
#
# Run with: bats tests/memory-probe.bats   (from plugin root)

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PROBE="$repo_root/scripts/memory-probe.sh"
    SHIM="$repo_root/bin/handoff-memory-probe"
}

# Build a synthetic gitlore-managed repo and echo its path. The memory
# submodule is a nested git repo with one committed file (clean by default).
# Pass a commitCommand path as $1 (defaults to an executable stub in the repo).
make_gitlore_repo() {
    local repo="$BATS_TEST_TMPDIR/glrepo"
    rm -rf "$repo"; mkdir -p "$repo/memory"
    git -C "$repo" init -q
    cat > "$repo/.gitmodules" <<'EOF'
[submodule "gitlore-memory"]
	path = memory
	url = ./memory
EOF
    git -C "$repo/memory" init -q
    echo "seed" > "$repo/memory/seed.md"
    git -C "$repo/memory" add -A
    git -C "$repo/memory" -c user.email=t@t -c user.name=t commit -qm seed
    cat > "$repo/fake-commit-memory.sh" <<'EOF'
#!/usr/bin/env bash
echo "COMMIT-MEMORY $*"
EOF
    chmod +x "$repo/fake-commit-memory.sh"
    git -C "$repo" config gitlore.commitCommand "${1:-$repo/fake-commit-memory.sh}"
    printf '%s\n' "$repo"
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
    git -C "$repo" config --file "$repo/.gitmodules" --unset submodule.gitlore-memory.path
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: dirty memory -> directive naming the abs commit command" {
    repo="$(make_gitlore_repo)"
    echo "new entry" > "$repo/memory/feedback_x.md"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'uncommitted changes'
    echo "$output" | grep -q 'feedback_x.md'
    echo "$output" | grep -qF "$repo/fake-commit-memory.sh -F -"
    echo "$output" | grep -qi 'approval'
}

@test "probe: dirty memory + unresolvable committer -> restart hint" {
    repo="$(make_gitlore_repo "/nonexistent/commit-memory.sh")"
    echo "new entry" > "$repo/memory/feedback_x.md"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi 'restart'
    echo "$output" | grep -q 'gitlore.commitCommand'
}

@test "shim: bin/handoff-memory-probe execs the probe (dirty -> directive)" {
    repo="$(make_gitlore_repo)"
    echo "new entry" > "$repo/memory/feedback_x.md"
    run bash -c 'cd "$1" && "$2"' _ "$repo" "$SHIM"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/fake-commit-memory.sh -F -"
}
