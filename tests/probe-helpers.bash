#!/usr/bin/env bash
# Shared synthetic-repo builder for tests/checkpoint.bats's shim test — the
# one row left there that needs a gitlore-managed repo with dirty memory.
# checkpoint.py's own memory-directive tests (schema, composition, ledger
# liveness) moved to tests/test_checkpoint.py, which carries its own Python
# equivalents of these builders — see
# docs/changelog/2026-08-10-python-split.md.

# A gitlore-managed repo: a .gitmodules registration for the gitlore-memory
# submodule (the FR12 activation gate) plus a nested memory git repo holding
# one committed file, and an empty .claude/ (checkpoint.py's write target).
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
    # have seeded/re-pinned this session.
    printf '%s\n' "a stand-in approval clause" > "$repo/.gitlore-memory-approval-clause.txt"
    git -C "$repo" config gitlore.memoryApprovalClauseFile "$repo/.gitlore-memory-approval-clause.txt"
    printf '%s\n' "$repo"
}

# Dirty the memory submodule of $1 so the memory directive fires.
dirty_memory() {
    echo "new entry" > "$1/memory/feedback_x.md"
}
