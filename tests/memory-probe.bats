#!/usr/bin/env bats
# Tests for scripts/memory-probe.sh — the read-only gitlore-memory detector
# the handoff skill runs at wrap-up. Builds a synthetic gitlore repo (see
# tests/probe-helpers.bash) and asserts the probe's stdout contract:
#   not gitlore / clean / unmaterialized  -> silent (empty stdout)
#   dirty, without-commit                 -> file-trigger directive naming
#                                            the message + trigger paths
#   dirty, with-commit                    -> summary-only directive; no
#                                            mention of a trigger at all
#   bad/missing mode argument             -> exit 2, usage on stderr
#
# The directive body itself lives in scripts/_probe-lib.sh and is shared with
# the precompact probe; this suite pins handoff's composition of it (memory
# directive alone, no SDD nudge).
#
# Run with: bats tests/memory-probe.bats   (from plugin root)

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PROBE="$repo_root/scripts/memory-probe.sh"
    SHIM="$repo_root/bin/handoff-memory-probe"
    load probe-helpers
}

@test "probe: not gitlore-managed -> silent" {
    plain="$BATS_TEST_TMPDIR/plain"; mkdir -p "$plain"
    git -C "$plain" init -q
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$plain" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: gitlore + clean memory -> silent" {
    repo="$(make_gitlore_repo)"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# The mode selects a commit path for dirty memory; it must not conjure output
# where there is nothing to commit.
@test "probe: gitlore + clean memory, with-commit -> silent" {
    repo="$(make_gitlore_repo)"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" with-commit
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: submodule registered but not materialized -> silent" {
    repo="$(make_gitlore_repo)"
    rm -rf "$repo/memory/.git"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: gitlore stanza but empty path -> silent" {
    repo="$(make_gitlore_repo)"
    git -C "$repo" config --file "$repo/.gitmodules" \
        --unset submodule.gitlore-memory.path
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: dirty memory -> directive naming both IPC file paths" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'uncommitted changes'
    echo "$output" | grep -q 'feedback_x.md'
    echo "$output" | grep -qF "$repo/.claude/gitlore-memory-message"
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
}

# The summary file becomes the memory commit's message verbatim — gitlore feeds
# it to `git commit -F`, in the submodule and in each tier — so the directive
# asks for a commit message's shape. Preamble text, hence both modes.
@test "probe: dirty memory -> summary prescribed as a commit message" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi 'commit message'
    echo "$output" | grep -qF '72 characters'
    echo "$output" | grep -qi 'body'
}

@test "probe: dirty memory, with-commit -> same commit-message shape" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" with-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi 'commit message'
    echo "$output" | grep -qF '72 characters'
    echo "$output" | grep -qi 'body'
}

@test "probe: dirty memory -> directive demands blockquote + approval" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi 'blockquote'
    echo "$output" | grep -qi 'approv'
}

# The approval gate is the FR11 interactive gate and is mode-independent.
@test "probe: dirty memory, with-commit -> still demands blockquote + approval" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" with-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi 'blockquote'
    echo "$output" | grep -qi 'approv'
    echo "$output" | grep -q 'uncommitted changes'
    echo "$output" | grep -q 'feedback_x.md'
}

# THE load-bearing assertion: the with-commit output never mentions the
# trigger — not its path, not the concept. The reader is a fresh agent in an
# arbitrary project with no other source for that filename, so saying nothing
# is what makes the standalone commit unreachable. A prohibition would
# introduce the very thing it forbids.
#
# Mutation-checked: deleting the with-commit branch in _probe-lib.sh (so the
# mode falls through to the without-commit text) turns this test red.
@test "probe: with-commit -> summary write only, no mention of a trigger" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" with-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-memory-message"
    [[ "$output" != *"gitlore-commit-memory"* ]]
    [[ "$output" != *"trigger"* ]]
    [[ "$output" != *"two file writes"* ]]
}

# The mode is worth nothing if the agent is not told what replaces the
# standalone commit — a bare prohibition reads as "memory does not get
# committed", and the agent invents a recovery. One clause, no mechanism:
# the pre-commit hook and the gitlink staging are gitlore's business, and an
# agent given them checks them.
@test "probe: with-commit -> states the commit carries the memory" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" with-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "carries the memory"
    [[ "$output" != *"pre-commit hook"* ]]
}

# Freshness is real — gitlore aborts the parent commit when a memory file is
# newer than the summary — but nothing has to state it: "once approved" already
# places the write after the memory edits, and both skills finish memory before
# running the probe. A directive restating it addresses a reader who has already
# complied, and invites a check it cannot act on.
@test "probe: with-commit -> no freshness mechanism in the directive" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" with-commit
    [ "$status" -eq 0 ]
    [[ "$output" != *"newer than"* ]]
    [[ "$output" != *"memory edit"* ]]
}

@test "probe: without-commit keeps the standalone two-file instruction" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF 'two file writes'
    echo "$output" | grep -qF 'Write the trigger file (any content)'
    [[ "$output" != *"carries the memory"* ]]
}

@test "probe: dirty memory -> no stale commit-memory Bash path" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    [[ "$output" != *"-F -"* ]]
    [[ "$output" != *"commitCommand"* ]]
}

# --- mode argument validation -------------------------------------------

@test "probe: no argument -> exit 2 with usage on stderr" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    # shellcheck disable=SC2016   # positionals of the inner `bash -c` script
    run --separate-stderr -2 bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$output" = "" ]
    # shellcheck disable=SC2154   # set by bats `run --separate-stderr`
    [ "$stderr" = "usage: handoff-memory-probe <with-commit|without-commit>" ]
}

@test "probe: unknown mode -> exit 2 with usage on stderr" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    for bad in --with-commit commit yes ""; do
        # shellcheck disable=SC2016   # positionals of the inner `bash -c` script
        run --separate-stderr -2 bash -c 'cd "$1" && bash "$2" "$3"' \
            _ "$repo" "$PROBE" "$bad"
        [ "$output" = "" ]
        [ "$stderr" = "usage: handoff-memory-probe <with-commit|without-commit>" ]
    done
}

# Two recognized values is still not an answer to a two-way question.
@test "probe: two arguments -> exit 2" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    # shellcheck disable=SC2016   # positionals of the inner `bash -c` script
    run --separate-stderr -2 bash -c 'cd "$1" && bash "$2" "$3" "$4"' \
        _ "$repo" "$PROBE" with-commit without-commit
    [ "$output" = "" ]
    [ "$stderr" = "usage: handoff-memory-probe <with-commit|without-commit>" ]
}

# --- composition ---------------------------------------------------------

# A workflow ledger outlives a /clear exactly as it outlives a compaction, so
# handoff carries the todo-file suppression — but NOT the precompact-only
# bring-the-ledger-current nudge.
@test "probe: handoff composition carries the todo suppression, not the SDD nudge" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF '.superpowers/sdd/feature-plan/progress.md'
    echo "$output" | grep -qF 'handoff-todo.md'
    [[ "$output" != *"Minor findings"* ]]
    [[ "$output" != *"re-dispatched"* ]]
}

# The suppression is orthogonal to the commit mode: both compose the same way.
@test "probe: with-commit composes with the todo suppression, memory first" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" with-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF 'handoff-todo.md'
    [[ "$output" != *"trigger"* ]]
    mem_line=$(echo "$output" | grep -nF 'gitlore-memory-message' | head -1 | cut -d: -f1)
    todo_line=$(echo "$output" | grep -nF 'handoff-todo.md' | head -1 | cut -d: -f1)
    [ "$mem_line" -lt "$todo_line" ]
}

@test "probe: clean memory + SDD ledger -> suppression alone" {
    repo="$(make_gitlore_repo)"
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF 'handoff-todo.md'
    [[ "$output" != *"gitlore-commit-memory"* ]]
}

# handoff runs the probe in the SAME turn as the writes, so the suppression
# always arrives after the file it suppresses. A bare "do not write it" is a
# no-op there; the directive has to name the cleanup.
@test "probe: handoff suppression tells the agent to delete an already-written todo file" {
    repo="$(make_gitlore_repo)"
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qiF 'delete'
}

# The suppression is where an orphaned ledger does its damage: handoff-todo.md
# is the file that survives the /clear, so deferring to a leftover risks losing
# the real remainder. Neither shape of leftover may stand it down.
#
# Mutation-checked: restoring the flat-path branch in probe_ledger_path turns the
# first red; dropping the identity-line `case` turns the second red.
@test "probe: flat-path stray does not suppress the todo file" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    add_flat_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    [[ "$output" != *"handoff-todo.md"* ]]
}

@test "probe: workspace file without an identity line does not suppress the todo file" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    add_unidentified_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    [[ "$output" != *"handoff-todo.md"* ]]
}

# No ledger is the common case: nothing suppresses the todo file, so the
# probe must not mention it at all.
@test "probe: dirty memory, no ledger -> no todo suppression" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    [[ "$output" != *"handoff-todo.md"* ]]
}

@test "probe: detected from a subdirectory of the repo -> directive" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    mkdir -p "$repo/pkg/src"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo/pkg/src" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
}

@test "shim: bin/handoff-memory-probe execs the probe (dirty -> directive)" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && "$2" "$3"' _ "$repo" "$SHIM" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
}

# The shim forwards "$@" — the mode has to survive the exec, or every real
# invocation dies on the usage error.
@test "shim: bin/handoff-memory-probe forwards the mode argument" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && "$2" "$3"' _ "$repo" "$SHIM" with-commit
    [ "$status" -eq 0 ]
    [[ "$output" != *"trigger"* ]]
    echo "$output" | grep -qi "carries the memory"
}

@test "shim: bin/handoff-memory-probe rejects a missing mode" {
    repo="$(make_gitlore_repo)"
    # shellcheck disable=SC2016   # positionals of the inner `bash -c` script
    run --separate-stderr -2 bash -c 'cd "$1" && "$2"' _ "$repo" "$SHIM"
    [ "$stderr" = "usage: handoff-memory-probe <with-commit|without-commit>" ]
}
