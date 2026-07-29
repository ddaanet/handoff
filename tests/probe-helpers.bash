#!/usr/bin/env bash
# Shared synthetic-repo builders for tests/checkpoint.bats (which merges the
# former tests/memory-probe.bats + tests/precompact-probe.bats).
#
# checkpoint.sh composes the same memory directive out of
# scripts/_checkpoint-lib.sh regardless of which skill invoked it, so one
# builder here stops fixtures from drifting apart as the directive evolves.

# A gitlore-managed repo: a .gitmodules registration for the gitlore-memory
# submodule (the FR12 activation gate) plus a nested memory git repo holding
# one committed file, and an empty .claude/ (checkpoint.sh's write target).
# Clean by default — dirty it by writing into memory/. Echoes the repo path.
make_gitlore_repo() {
    local repo="${1:-$BATS_TEST_TMPDIR/glrepo}"
    rm -rf "$repo"; mkdir -p "$repo/memory" "$repo/.claude"
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
    # gitlore.memoryApprovalClauseFile: what a real gitlore SessionStart would
    # have seeded/re-pinned this session — checkpoint_memory_directive discovers
    # it the same way it discovers gitlore.commitCommand. See
    # docs/changelog/2026-07-28-memory-approval-from-gitlore.md.
    printf '%s\n' "$GITLORE_MEMORY_APPROVAL_CLAUSE" > "$repo/.gitlore-memory-approval-clause.txt"
    git -C "$repo" config gitlore.memoryApprovalClauseFile "$repo/.gitlore-memory-approval-clause.txt"
    printf '%s\n' "$repo"
}

# The fixture's stand-in for gitlore's canonical clause text (real wording
# lives in gitlore's reference/memory-approval-clause.txt) — a fixed value so
# tests can assert on it without reading the file back.
GITLORE_MEMORY_APPROVAL_CLAUSE="as one line per memory file — New, Update, Augment, Reduce, or Remove, its tier/slug, and a one-line summary of what changed"

# Materialize a live superpowers SDD ledger inside $1 (a repo path) for the plan
# whose basename is $2 (default feature-plan). Layout and identity line are
# 6.2.0's: one git-ignored workspace directory per plan, first line naming the
# plan file. Note the em dash — it is literal in SDD's format.
add_sdd_ledger() {
    local repo="$1" slug="${2:-feature-plan}" dir
    dir="$repo/.superpowers/sdd/$slug"
    mkdir -p "$dir"
    printf '*\n' > "$repo/.superpowers/sdd/.gitignore"
    printf '%s\n' \
        "# SDD ledger — plan: docs/plans/$slug.md" \
        "Task 1: complete (commits abc1234..def5678, review clean)" \
        > "$dir/progress.md"
}

# A ledger at the pre-6.2.0 flat path. SDD names this one as another plan's
# progress and never removes it, so the probe must not count it.
add_flat_sdd_ledger() {
    local repo="$1"
    mkdir -p "$repo/.superpowers/sdd"
    printf '*\n' > "$repo/.superpowers/sdd/.gitignore"
    printf '%s\n' "Task 1: complete (commits abc1234..def5678, review clean)" \
        > "$repo/.superpowers/sdd/progress.md"
}

# A hand-rolled file in a workspace-shaped directory, with no identity line —
# the shape that hijacked a session in /Users/david/code/micro on 2026-07-25.
add_unidentified_sdd_ledger() {
    local repo="$1" slug="${2:-ghmem}" dir
    dir="$repo/.superpowers/sdd/$slug"
    mkdir -p "$dir"
    printf '*\n' > "$repo/.superpowers/sdd/.gitignore"
    printf '%s\n' "# ghmem — progress (C2 COMPLETE)" > "$dir/progress.md"
}

# Dirty the memory submodule of $1 so the memory directive fires.
dirty_memory() {
    echo "new entry" > "$1/memory/feedback_x.md"
}
