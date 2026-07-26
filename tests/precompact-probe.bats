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
# The probe takes one required argument, the commit-awareness mode, which
# selects between gitlore's standalone and parent-commit memory paths — the
# trigger is mentioned under without-commit only. The composition and its
# ordering are the same under both modes.
#
# Run with: bats tests/precompact-probe.bats   (from plugin root)

bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PROBE="$repo_root/scripts/precompact-probe.sh"
    SHIM="$repo_root/bin/handoff-precompact-probe"
    load probe-helpers
}

@test "probe: not a git repo -> silent" {
    plain="$BATS_TEST_TMPDIR/plain"; mkdir -p "$plain"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$plain" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: git repo, no ledger and no gitlore -> silent" {
    repo="$BATS_TEST_TMPDIR/bare"; mkdir -p "$repo"
    git -C "$repo" init -q
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: gitlore + clean memory, no ledger -> silent" {
    repo="$(make_gitlore_repo)"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: gitlore + clean memory, with-commit -> silent" {
    repo="$(make_gitlore_repo)"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" with-commit
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: SDD ledger only -> nudge, no memory directive" {
    repo="$BATS_TEST_TMPDIR/sddonly"; mkdir -p "$repo"
    git -C "$repo" init -q
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF '.superpowers/sdd/feature-plan/progress.md'
    echo "$output" | grep -qi 'minor'
    echo "$output" | grep -qi 're-dispatch'
    [[ "$output" != *"gitlore-commit-memory"* ]]
}

# --- ledger liveness ------------------------------------------------------
#
# What counts is a *live* SDD run, not a file that looks like one. 6.2.0 gives
# each plan a workspace directory and deletes it when the final review is clean,
# so presence at the old flat path — or without the identity first line — is
# somebody else's leftover.

# The pre-6.2.0 flat path is what SDD itself calls another plan's progress, and
# nothing in its lifecycle removes it. Counting it stood handoff-todo.md down in
# a session that ran no SDD at all.
#
# Mutation-checked: restoring the flat-path branch in probe_ledger_path turns
# this test red.
@test "probe: flat-path ledger alone -> silent" {
    repo="$BATS_TEST_TMPDIR/sddflat"; mkdir -p "$repo"
    git -C "$repo" init -q
    add_flat_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# The identity line is what separates a live ledger from a hand-rolled file that
# happens to sit in a workspace-shaped directory.
#
# Mutation-checked: dropping the identity-line `case` in probe_ledger_path turns
# this test red.
@test "probe: workspace file without SDD's identity line -> silent" {
    repo="$BATS_TEST_TMPDIR/sddnoident"; mkdir -p "$repo"
    git -C "$repo" init -q
    add_unidentified_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: flat-path stray beside a live ledger -> only the live one is named" {
    repo="$BATS_TEST_TMPDIR/sddboth"; mkdir -p "$repo"
    git -C "$repo" init -q
    add_flat_sdd_ledger "$repo"
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF '.superpowers/sdd/feature-plan/progress.md'
    [[ "$output" != *"sdd/progress.md"* ]]
}

# An abandoned run and a live one both leave a workspace, so mtime decides. The
# assertion has to rule out both "glob-first wins" and "glob-last wins": run it
# once with the live ledger lexically first, once lexically last.
@test "probe: several live workspaces -> most recently modified wins" {
    i=0
    for pair in a-live:z-stale z-live:a-stale; do
        i=$((i + 1))
        live="${pair%%:*}"; stale="${pair##*:}"
        repo="$BATS_TEST_TMPDIR/sddmulti$i"; mkdir -p "$repo"
        git -C "$repo" init -q
        add_sdd_ledger "$repo" "$stale"
        add_sdd_ledger "$repo" "$live"
        touch -t 202601010000 "$repo/.superpowers/sdd/$stale/progress.md"
        run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
        [ "$status" -eq 0 ]
        echo "$output" | grep -qF ".superpowers/sdd/$live/progress.md"
        [[ "$output" != *"$stale"* ]]
    done
}

# The nudge interpolates whatever probe_ledger_path prints — the registry is the
# only place that knows the layout.
@test "probe: nudge names the ledger's own workspace, not a fixed path" {
    repo="$BATS_TEST_TMPDIR/sddslug"; mkdir -p "$repo"
    git -C "$repo" init -q
    add_sdd_ledger "$repo" some-other-plan
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF '.superpowers/sdd/some-other-plan/progress.md'
}

# The ledger is the session's task list, so the nudge must also stand
# handoff-todo.md down — two ledgers drift and the stale one gets believed.
@test "probe: SDD nudge suppresses the todo file" {
    repo="$BATS_TEST_TMPDIR/sddsupp"; mkdir -p "$repo"
    git -C "$repo" init -q
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF 'handoff-todo.md'
}

@test "probe: no ledger -> no todo suppression" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    [[ "$output" != *"handoff-todo.md"* ]]
}

@test "probe: dirty memory only -> memory directive, no SDD nudge" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-memory-message"
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
    echo "$output" | grep -qi 'blockquote'
    echo "$output" | grep -qi 'commit message'
    echo "$output" | grep -qF '72 characters'
    [[ "$output" != *".superpowers/sdd/feature-plan/progress.md"* ]]
}

# The with-commit half of the branch, in precompact's composition: summary
# write only, no mention of a trigger — see the same test in
# tests/memory-probe.bats for why saying nothing is the mechanism.
#
# Mutation-checked: deleting the with-commit branch in _probe-lib.sh (so the
# mode falls through to the without-commit text) turns this test red.
@test "probe: with-commit -> summary write only, no mention of a trigger" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" with-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-memory-message"
    [[ "$output" != *"trigger"* ]]
    [[ "$output" != *"two file writes"* ]]
    echo "$output" | grep -qi "carries the memory"
}

@test "probe: dirty memory + SDD ledger -> both, memory directive first" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
    echo "$output" | grep -qF '.superpowers/sdd/feature-plan/progress.md'
    mem_line=$(echo "$output" | grep -nF 'gitlore-commit-memory' | head -1 | cut -d: -f1)
    sdd_line=$(echo "$output" | grep -nF '.superpowers/sdd/feature-plan/progress.md' | head -1 | cut -d: -f1)
    [ "$mem_line" -lt "$sdd_line" ]
}

# Composition order is a property of the probe, not of the commit mode: memory
# is the interactive gate either way, so it stays first.
@test "probe: with-commit + SDD ledger -> both, memory directive first" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" with-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-memory-message"
    echo "$output" | grep -qF '.superpowers/sdd/feature-plan/progress.md'
    [[ "$output" != *"trigger"* ]]
    mem_line=$(echo "$output" | grep -nF 'gitlore-memory-message' | head -1 | cut -d: -f1)
    sdd_line=$(echo "$output" | grep -nF '.superpowers/sdd/feature-plan/progress.md' | head -1 | cut -d: -f1)
    [ "$mem_line" -lt "$sdd_line" ]
}

@test "probe: clean memory + SDD ledger -> nudge only" {
    repo="$(make_gitlore_repo)"
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF '.superpowers/sdd/feature-plan/progress.md'
    [[ "$output" != *"gitlore-commit-memory"* ]]
}

@test "probe: composed output detected from a subdirectory -> both" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    add_sdd_ledger "$repo"
    mkdir -p "$repo/pkg/src"
    run bash -c 'cd "$1" && bash "$2" "$3"' _ "$repo/pkg/src" "$PROBE" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
    echo "$output" | grep -qF '.superpowers/sdd/feature-plan/progress.md'
}

# --- mode argument validation -------------------------------------------

# The usage line names the shim, which is what the skill body invokes — an
# agent that misreads it must be told what to fix, not shown scripts/.
@test "probe: no argument -> exit 2 with usage on stderr" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    # shellcheck disable=SC2016   # positionals of the inner `bash -c` script
    run --separate-stderr -2 bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$output" = "" ]
    # shellcheck disable=SC2154   # set by bats `run --separate-stderr`
    [ "$stderr" = "usage: handoff-precompact-probe <with-commit|without-commit>" ]
}

@test "probe: unknown mode -> exit 2 with usage on stderr" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    for bad in --with-commit commit yes ""; do
        # shellcheck disable=SC2016   # positionals of the inner `bash -c` script
        run --separate-stderr -2 bash -c 'cd "$1" && bash "$2" "$3"' \
            _ "$repo" "$PROBE" "$bad"
        [ "$output" = "" ]
        [ "$stderr" = "usage: handoff-precompact-probe <with-commit|without-commit>" ]
    done
}

@test "probe: two arguments -> exit 2" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    # shellcheck disable=SC2016   # positionals of the inner `bash -c` script
    run --separate-stderr -2 bash -c 'cd "$1" && bash "$2" "$3" "$4"' \
        _ "$repo" "$PROBE" with-commit without-commit
    [ "$output" = "" ]
    [ "$stderr" = "usage: handoff-precompact-probe <with-commit|without-commit>" ]
}

# Validation precedes every other check, so a bad mode is an error even where
# the probe would otherwise have stayed silent.
@test "probe: bad mode outside a git repo -> still exit 2" {
    plain="$BATS_TEST_TMPDIR/plain2"; mkdir -p "$plain"
    # shellcheck disable=SC2016   # positionals of the inner `bash -c` script
    run --separate-stderr -2 bash -c 'cd "$1" && bash "$2" "$3"' \
        _ "$plain" "$PROBE" nonsense
    [ "$output" = "" ]
    [ "$stderr" = "usage: handoff-precompact-probe <with-commit|without-commit>" ]
}

@test "shim: bin/handoff-precompact-probe execs the probe (ledger -> nudge)" {
    repo="$BATS_TEST_TMPDIR/shimrepo"; mkdir -p "$repo"
    git -C "$repo" init -q
    add_sdd_ledger "$repo"
    run bash -c 'cd "$1" && "$2" "$3"' _ "$repo" "$SHIM" without-commit
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF '.superpowers/sdd/feature-plan/progress.md'
}

@test "shim: bin/handoff-precompact-probe forwards the mode argument" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && "$2" "$3"' _ "$repo" "$SHIM" with-commit
    [ "$status" -eq 0 ]
    [[ "$output" != *"trigger"* ]]
    echo "$output" | grep -qi "carries the memory"
}

@test "shim: bin/handoff-precompact-probe rejects a missing mode" {
    repo="$(make_gitlore_repo)"
    # shellcheck disable=SC2016   # positionals of the inner `bash -c` script
    run --separate-stderr -2 bash -c 'cd "$1" && "$2"' _ "$repo" "$SHIM"
    [ "$stderr" = "usage: handoff-precompact-probe <with-commit|without-commit>" ]
}
