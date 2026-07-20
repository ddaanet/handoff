#!/usr/bin/env bash
# Shared synthetic-repo builders for the probe suites
# (tests/memory-probe.bats, tests/precompact-probe.bats).
#
# Both probes compose the same memory directive out of scripts/_probe-lib.sh,
# so both need an identically-shaped gitlore repo. Keeping one builder here
# stops the two fixtures from drifting apart as the directive evolves.

# A gitlore-managed repo: a .gitmodules registration for the gitlore-memory
# submodule (the FR12 activation gate) plus a nested memory git repo holding
# one committed file. Clean by default — dirty it by writing into memory/.
# Echoes the repo path.
make_gitlore_repo() {
    local repo="${1:-$BATS_TEST_TMPDIR/glrepo}"
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
    printf '%s\n' "$repo"
}

# Materialize the SDD durable-progress ledger inside $1 (a repo path).
add_sdd_ledger() {
    local repo="$1"
    mkdir -p "$repo/.superpowers/sdd"
    printf '*\n' > "$repo/.superpowers/sdd/.gitignore"
    cat > "$repo/.superpowers/sdd/progress.md" <<'EOF'
Task 1: complete (commits abc1234..def5678, review clean)
EOF
}

# Dirty the memory submodule of $1 so the memory directive fires.
dirty_memory() {
    echo "new entry" > "$1/memory/feedback_x.md"
}
