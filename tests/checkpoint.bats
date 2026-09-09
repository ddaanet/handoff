#!/usr/bin/env bats
# Tests for the bash-side neighbors of the checkpoint channel that stayed
# bash in the Python split (docs/changelog/2026-08-10-python-split.md):
# scripts/inject-checkpoint-root.sh (PreToolUse(Bash) root injection),
# bin/handoff-approved (the one command that leaves a `held` sentinel),
# bin/handoff-checkpoint (the shim), and scripts/bash-post.sh
# (PostToolUse(Bash) manifest consumer).
#
# checkpoint.py's own behavior (schema validation, write semantics, manifest
# content, sentinel/directive composition) is covered in
# tests/test_checkpoint.py (pytest) — see docs/changelog/2026-07-27-one-channel-one-writer.md
# for the channel's original design and docs/changelog/2026-08-10-python-split.md
# for what moved.
#
# Run with: bats tests/checkpoint.bats   (from plugin root)

# shellcheck disable=SC2154   # $stderr is set by bats `run --separate-stderr`
bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SHIM="$repo_root/bin/handoff-checkpoint"
    APPROVED="$repo_root/bin/handoff-approved"
    BASHPOST="$repo_root/scripts/bash-post.sh"
    INJECT_ROOT="$repo_root/scripts/inject-checkpoint-root.sh"
    load probe-helpers

    export CLAUDE_CODE_SESSION_ID="sess-checkpoint"

    # For asserting that what handoff-approved writes is what a loader will
    # accept, and for handoff_drive_read itself in the tests below.
    # shellcheck source-path=SCRIPTDIR source=../scripts/_lib.sh disable=SC1091
    source "$repo_root/scripts/_lib.sh"
}

# A plain git repo with .claude/ present.
make_repo() {
    local repo="${1:-$BATS_TEST_TMPDIR/repo}"
    rm -rf "$repo"; mkdir -p "$repo/.claude"
    git -C "$repo" init -q
    printf '%s\n' "$repo"
}

# ==========================================================================
# scripts/inject-checkpoint-root.sh — PreToolUse(Bash): resolves this
# session's root and injects it as HANDOFF_ROOT straight into a
# handoff-checkpoint or handoff-approved command, replacing the pointer
# SessionStart used to publish. SessionStart(resume) fires with the RESUMING
# process's cwd, before the harness moves the session into its own project
# dir — the one moment sampling the root would stamp the wrong repo onto it.
# See plans/2026-08-05-checkpoint-root-via-updatedinput.md.
# ==========================================================================

# Run the hook against a Bash tool_input.command ($2) with cwd = $1. Exports
# CLAUDE_PROJECT_DIR=$1 first — a real PreToolUse(Bash) invocation always has
# it, unlike the agent's own Bash where checkpoint.py/handoff-approved run.
run_inject_root() {
    local repo="$1" command="$2"
    export CLAUDE_PROJECT_DIR="$repo"
    run bash -c '
        jq -nc --arg cwd "$1" --arg cmd "$2" \
          "{cwd:\$cwd, hook_event_name:\"PreToolUse\", tool_name:\"Bash\", tool_input:{command:\$cmd}}" \
        | bash "$3"
    ' _ "$repo" "$command" "$INJECT_ROOT"
}

@test "inject-checkpoint-root: rewrites a handoff-checkpoint call, carrying the resolved root" {
    repo="$(make_repo)"
    run_inject_root "$repo" 'handoff-checkpoint <<<"{}"'
    [ "$status" -eq 0 ]
    [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "allow" ]
    new_cmd="$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$output")"
    [[ "$new_cmd" == "export HANDOFF_ROOT="*";"*"handoff-checkpoint"* ]]
    [[ "$new_cmd" == *"$repo"* ]]
}

@test "inject-checkpoint-root: rewrites a handoff-approved call too" {
    repo="$(make_repo)"
    run_inject_root "$repo" 'handoff-approved'
    [ "$status" -eq 0 ]
    new_cmd="$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$output")"
    [[ "$new_cmd" == "export HANDOFF_ROOT="*";"*"handoff-approved"* ]]
}

@test "inject-checkpoint-root: leaves an unrelated Bash command untouched" {
    repo="$(make_repo)"
    run_inject_root "$repo" 'echo hello'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# A path containing whitespace must round-trip: assert the value the rewritten
# command's own shell sees, not the string the hook printed.
@test "inject-checkpoint-root: a root containing whitespace round-trips through the rewrite" {
    repo="$(make_repo "$BATS_TEST_TMPDIR/has space/repo")"
    # shellcheck disable=SC2016   # $HANDOFF_ROOT is meant literal — it expands inside new_cmd's own bash -c, below
    run_inject_root "$repo" 'printf %s "$HANDOFF_ROOT" > seen; true # handoff-checkpoint'
    [ "$status" -eq 0 ]
    new_cmd="$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$output")"
    (cd "$repo" && bash -c "$new_cmd")
    [ "$(cat "$repo/seen")" = "$repo" ]
}

# The row that would stay green under a bare `VAR=… cmd` prefix only by
# accident: `VAR=x a && b` sets the variable for `a` alone, so a batched
# command's SECOND stage would see nothing. `export …;` must survive it.
@test "inject-checkpoint-root: export survives a batched command, unlike a bare VAR= prefix" {
    repo="$(make_repo)"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/handoff-checkpoint" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/handoff-checkpoint"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export PATH
    # shellcheck disable=SC2016   # $HANDOFF_ROOT is meant literal — it expands inside new_cmd's own bash -c, below
    run_inject_root "$repo" 'handoff-checkpoint <<<"{}" && printf %s "$HANDOFF_ROOT" > seen'
    [ "$status" -eq 0 ]
    new_cmd="$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$output")"
    (cd "$repo" && bash -c "$new_cmd")
    [ "$(cat "$repo/seen")" = "$repo" ]
}

@test "inject-checkpoint-root: hooks.json dispatches PreToolUse(Bash) to it" {
    cmd="$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[0].command' "$repo_root/hooks/hooks.json")"
    [[ "$cmd" == *"scripts/inject-checkpoint-root.sh"* ]]
    [ -f "$repo_root/scripts/inject-checkpoint-root.sh" ]
}

# ==========================================================================
# bin/handoff-approved — the one command that leaves `held`
# ==========================================================================

# Run it with cwd = $1 and HANDOFF_ROOT = $2 (default $1). Invoked through
# its own path here; the bare-name row below is what covers the invocation path.
run_approved() {
    local repo="$1" root="${2:-$1}"
    # shellcheck disable=SC2016   # $1/$2/$3 are the inner bash -c's own positional params
    run --separate-stderr bash -c 'cd "$1" && HANDOFF_ROOT="$2" bash "$3"' _ "$repo" "$root" "$APPROVED"
}

@test "handoff-approved: a held sentinel becomes armed, every line below preserved" {
    repo="$(make_repo)"
    printf '%s\n' "held $CLAUDE_CODE_SESSION_ID" clear "/rename A Title" /clear \
        "pick up per the task file" > "$repo/.claude/autodrive"
    run_approved "$repo"
    [ "$status" -eq 0 ]
    [ "$(cat "$repo/.claude/autodrive")" = "armed
clear
/rename A Title
/clear
pick up per the task file" ]
}

# The approval this command speaks for is the one *this* session was asked for.
# A held file another session left behind waits on an answer that can no longer
# arrive, and arming it drives that session's /rename and /clear into this
# conversation — so the state alone is not enough to act on.
@test "handoff-approved: a held sentinel from another session -> exit 2, left held" {
    repo="$(make_repo)"
    printf '%s\n' "held sess-someone-else" clear "/rename A Title" /clear \
        > "$repo/.claude/autodrive"
    run_approved "$repo"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"session"* ]]
    [ "$(head -n1 "$repo/.claude/autodrive")" = "held sess-someone-else" ]
}

@test "handoff-approved: no sentinel -> exit 2 naming the absence" {
    repo="$(make_repo)"
    run_approved "$repo"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"autodrive"* ]]
}

# Already armed: this turn's Stop will fire it, and rewriting the state would
# say the approval released something it did not.
@test "handoff-approved: an armed sentinel -> exit 2 naming the state it found" {
    repo="$(make_repo)"
    printf '%s\n' armed clear "/rename A Title" /clear > "$repo/.claude/autodrive"
    run_approved "$repo"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"armed"* ]]
    [ "$(head -n1 "$repo/.claude/autodrive")" = "armed" ]
}

@test "handoff-approved: HANDOFF_ROOT unset -> refuses, naming the unrecognised invocation" {
    repo="$(make_repo)"
    # shellcheck disable=SC2016   # $1/$2 are the inner bash -c's own positional params
    run --separate-stderr bash -c 'cd "$1" && unset HANDOFF_ROOT; bash "$2"' _ "$repo" "$APPROVED"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"HANDOFF_ROOT"* ]]
}

# The invocation path: the agent runs this by bare name off PATH, so a
# non-executable entry point is a failure every other row here would miss.
@test "handoff-approved: runs by bare name off PATH" {
    repo="$(make_repo)"
    printf '%s\n' "held $CLAUDE_CODE_SESSION_ID" compact "/compact" \
        > "$repo/.claude/autodrive"
    run bash -c 'cd "$1" && PATH="$2:$PATH" HANDOFF_ROOT="$1" handoff-approved' _ "$repo" "$repo_root/bin"
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$repo/.claude/autodrive")" = "armed" ]
}

# ==========================================================================
# shim (bin/handoff-checkpoint)
# ==========================================================================

# The union's spelling, hardcoded outside the Python factories: keep in step
# with task_clear()/todo_keep() in tests/test_checkpoint.py.
handoff_payload() {
    jq -nc --arg commit "$1" '{skill:"handoff", commit:$commit, rename:"Session Title", clear:false, continue:null, task:{action:"clear"}, todo:{action:"keep"}}'
}

@test "shim: bin/handoff-checkpoint execs the checkpoint, forwards stdin" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run bash -c 'cd "$1" && HANDOFF_ROOT="$1" "$2" <<<"$3"' \
        _ "$repo" "$SHIM" "$(handoff_payload without-commit)"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
}

@test "shim: bin/handoff-checkpoint surfaces a schema violation" {
    repo="$(make_repo)"
    # shellcheck disable=SC2016   # $1/$2/$3 are the inner bash -c's own positional params
    run --separate-stderr -2 bash -c 'cd "$1" && HANDOFF_ROOT="$1" "$2" <<<"$3"' \
        _ "$repo" "$SHIM" '{"commit":"with-commit"}'
    [[ "$stderr" == *"skill"* ]]
}

# ==========================================================================
# bash-post.sh (PostToolUse(Bash))
# ==========================================================================

@test "bash-post: manifest absent -> silent no-op, negative path never resolves the root" {
    repo="$BATS_TEST_TMPDIR/bp-negative"; mkdir -p "$repo/.claude"
    stub="$BATS_TEST_TMPDIR/nopy3"; mkdir -p "$stub"
    printf '#!/usr/bin/env bash\nexit 97\n' > "$stub/python3"
    chmod +x "$stub/python3"
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, tool_name:\"Bash\", tool_input:{command:\"ls\"}}" \
        | PATH="$2:$PATH" bash "$3"
    ' _ "$repo" "$stub" "$BASHPOST"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "bash-post: manifest present -> stages W and D paths, deletes manifest" {
    repo="$BATS_TEST_TMPDIR/bp-stage"; mkdir -p "$repo/.claude"
    git -C "$repo" init -q
    printf 'seed\n' > "$repo/.claude/handoff-task.md"
    git -C "$repo" add -f .claude/handoff-task.md
    git -C "$repo" -c user.email=t@t -c user.name=t commit -qm seed
    rm -f "$repo/.claude/handoff-task.md"
    printf 'new todo body\n' > "$repo/.claude/handoff-todo.md"
    printf '%s\n' "D .claude/handoff-task.md" "W .claude/handoff-todo.md" \
        > "$repo/.claude/checkpoint-manifest"
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, tool_name:\"Bash\", tool_input:{command:\"ls\"}}" \
        | CLAUDE_PROJECT_DIR="$1" bash "$2"
    ' _ "$repo" "$BASHPOST"
    [ "$status" -eq 0 ]
    [ ! -e "$repo/.claude/checkpoint-manifest" ]
    git -C "$repo" status --porcelain .claude/handoff-task.md | grep -q '^D'
    git -C "$repo" status --porcelain .claude/handoff-todo.md | grep -q '^A'
    echo "$output" | jq -e '.systemMessage | test("staged 1, deleted 1")' >/dev/null
    # Paired with the empty-manifest row below, which must NOT carry this: an
    # agent meeting these already in the index otherwise reads a stray add.
    echo "$output" \
        | jq -e '.hookSpecificOutput.additionalContext | test("Leave them staged")' >/dev/null
}

# Staging is all this hook does. A sentinel the checkpoint wrote is armed at
# Stop like any other, so this must leave it alone — consuming it here would
# spawn the walker mid-turn, which is the one thing the Stop gate exists to
# prevent.
@test "bash-post: empty manifest (rename-only checkpoint call) -> consumed, sentinel untouched" {
    repo="$BATS_TEST_TMPDIR/bp-rename"; mkdir -p "$repo/.claude"
    git -C "$repo" init -q
    : > "$repo/.claude/checkpoint-manifest"
    printf 'armed\nrename\n/rename New Title\n' > "$repo/.claude/autodrive"
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, tool_name:\"Bash\", tool_input:{command:\"ls\"}}" \
        | CLAUDE_PROJECT_DIR="$1" TMUX=fake TMUX_PANE="%0" bash "$2"
    ' _ "$repo" "$BASHPOST"
    [ "$status" -eq 0 ]
    [ ! -e "$repo/.claude/checkpoint-manifest" ]
    [ -f "$repo/.claude/autodrive" ]
    echo "$output" | jq -e '.systemMessage | test("staged 0, deleted 0")' >/dev/null
    # The negative half of the pair above: nothing was staged, so a clause
    # telling the agent to leave it staged would describe nothing.
    echo "$output" \
        | jq -e '.hookSpecificOutput.additionalContext | test("Leave them staged") | not' >/dev/null
}

@test "bash-post: worktree cwd -> resolves the worktree root, not the main tree" {
    tmp="$BATS_TEST_TMPDIR/bp-main"; mkdir -p "$tmp/.claude"
    export CLAUDE_PROJECT_DIR="$tmp"
    git -C "$tmp" init -q
    wt="$BATS_TEST_TMPDIR/bp-wt"
    mkdir -p "$wt/.claude" "$tmp/.git/worktrees/wtbp"
    printf 'gitdir: %s\n' "$tmp/.git/worktrees/wtbp" > "$wt/.git"
    : > "$wt/.claude/checkpoint-manifest"
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, tool_name:\"Bash\", tool_input:{command:\"ls\"}}" \
        | TMUX=fake TMUX_PANE="%0" bash "$2"
    ' _ "$wt" "$BASHPOST"
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/checkpoint-manifest" ]
    echo "$output" | jq -e '.systemMessage | test("staged 0")' >/dev/null
}

# The two rows below are a pair over one fixture, differing only in whether the
# path was ever in the index. `git add -f` on a path that is neither on disk nor
# in the index exits 128 with "did not match any files" — a benign, expected
# failure, since both paths are gitignored and any `git reset` since the last
# checkpoint leaves one in exactly that state. Guarding it away is what lets the
# redirect go; without the guard the second row would report a failure.
@test "bash-post: D for a path in the index -> counted in deleted, no failure" {
    repo="$BATS_TEST_TMPDIR/bp-d-tracked"; mkdir -p "$repo/.claude"
    git -C "$repo" init -q
    printf 'seed\n' > "$repo/.claude/handoff-task.md"
    git -C "$repo" add -f .claude/handoff-task.md
    git -C "$repo" -c user.email=t@t -c user.name=t commit -qm seed
    rm -f "$repo/.claude/handoff-task.md"
    printf '%s\n' "D .claude/handoff-task.md" > "$repo/.claude/checkpoint-manifest"
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, tool_name:\"Bash\", tool_input:{command:\"ls\"}}" \
        | CLAUDE_PROJECT_DIR="$1" bash "$2"
    ' _ "$repo" "$BASHPOST"
    [ "$status" -eq 0 ]
    git -C "$repo" status --porcelain .claude/handoff-task.md | grep -q '^D'
    echo "$output" | jq -e '.systemMessage | test("staged 0, deleted 1")' >/dev/null
    echo "$output" | jq -e '.systemMessage | test("failed to stage") | not' >/dev/null
}

@test "bash-post: D for a path never in the index -> silent, uncounted, no failure" {
    repo="$BATS_TEST_TMPDIR/bp-d-untracked"; mkdir -p "$repo/.claude"
    git -C "$repo" init -q
    printf '%s\n' "D .claude/handoff-task.md" > "$repo/.claude/checkpoint-manifest"
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, tool_name:\"Bash\", tool_input:{command:\"ls\"}}" \
        | CLAUDE_PROJECT_DIR="$1" bash "$2"
    ' _ "$repo" "$BASHPOST"
    [ "$status" -eq 0 ]
    [ ! -e "$repo/.claude/checkpoint-manifest" ]
    echo "$output" | jq -e '.systemMessage | test("staged 0, deleted 0")' >/dev/null
    echo "$output" | jq -e '.systemMessage | test("failed to stage") | not' >/dev/null
}

# The failure channel itself. A stranded index.lock is the motivating case: today
# the redirect eats git's explanation and the path just vanishes from the counts,
# so this reports "staged 0, deleted 0" and nothing else.
@test "bash-post: a path that cannot be staged -> reported on both channels, named" {
    repo="$BATS_TEST_TMPDIR/bp-locked"; mkdir -p "$repo/.claude"
    git -C "$repo" init -q
    printf 'new todo body\n' > "$repo/.claude/handoff-todo.md"
    printf '%s\n' "W .claude/handoff-todo.md" > "$repo/.claude/checkpoint-manifest"
    : > "$repo/.git/index.lock"
    # stderr is captured separately, not merged: git's own explanation now
    # reaches it, and bats would otherwise fold it into $output ahead of the
    # JSON on stdout. Keeping them apart is also what lets the last assertion
    # below pin the explanation itself, which is the whole point of dropping
    # the redirect — the named path says which, git's message says why.
    err="$repo/stderr.txt"
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, tool_name:\"Bash\", tool_input:{command:\"ls\"}}" \
        | CLAUDE_PROJECT_DIR="$1" bash "$2" 2>"$3"
    ' _ "$repo" "$BASHPOST" "$err"
    [ "$status" -eq 0 ]
    [ ! -e "$repo/.claude/checkpoint-manifest" ]
    echo "$output" \
        | jq -e '.systemMessage | test("failed to stage: .claude/handoff-todo.md")' >/dev/null
    echo "$output" \
        | jq -e '.hookSpecificOutput.additionalContext | test("failed to stage: .claude/handoff-todo.md")' >/dev/null
    grep -q 'index.lock' "$err"
}

# The pair for row 2: the same `D` line for a path ls-files does not list, but
# here because git cannot read the index at all rather than because the path
# never entered it. `add` could not have staged into that repo either, so the
# guard must report it, not swallow it. `.git` is a garbage file so the failure
# holds wherever BATS_TEST_TMPDIR happens to sit — an enclosing repo cannot
# rescue it into a successful, empty ls-files.
@test "bash-post: D whose index cannot be read -> reported, not swallowed by the guard" {
    repo="$BATS_TEST_TMPDIR/bp-d-broken"; mkdir -p "$repo/.claude"
    printf 'not a gitfile\n' > "$repo/.git"
    printf '%s\n' "D .claude/handoff-task.md" > "$repo/.claude/checkpoint-manifest"
    err="$repo/stderr.txt"
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, tool_name:\"Bash\", tool_input:{command:\"ls\"}}" \
        | CLAUDE_PROJECT_DIR="$1" bash "$2" 2>"$3"
    ' _ "$repo" "$BASHPOST" "$err"
    [ "$status" -eq 0 ]
    [ ! -e "$repo/.claude/checkpoint-manifest" ]
    echo "$output" \
        | jq -e '.systemMessage | test("failed to stage: .claude/handoff-task.md")' >/dev/null
    echo "$output" \
        | jq -e '.hookSpecificOutput.additionalContext | test("failed to stage: .claude/handoff-task.md")' >/dev/null
    echo "$output" \
        | jq -e '.hookSpecificOutput.additionalContext | test("Leave them staged") | not' >/dev/null
    [ -s "$err" ]
}

# The one combination where both optional clauses of agent_ctx appear at once,
# which is what the trailing period moving out of the initial assignment has to
# survive: the failure joins the semicolon list, the sentence closes, and only
# then does the "Leave them staged" clause follow. A `W` line for a path that is
# not on disk is the cheapest way to fail one path while another succeeds; the
# checkpoint does not compose that manifest itself, and this row is about the
# composition, not the cause.
@test "bash-post: one staged and one failed -> both clauses compose in order" {
    repo="$BATS_TEST_TMPDIR/bp-mixed"; mkdir -p "$repo/.claude"
    git -C "$repo" init -q
    printf 'task body\n' > "$repo/.claude/handoff-task.md"
    printf '%s\n' "W .claude/handoff-task.md" "W .claude/handoff-todo.md" \
        > "$repo/.claude/checkpoint-manifest"
    err="$repo/stderr.txt"
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, tool_name:\"Bash\", tool_input:{command:\"ls\"}}" \
        | CLAUDE_PROJECT_DIR="$1" bash "$2" 2>"$3"
    ' _ "$repo" "$BASHPOST" "$err"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.systemMessage
        | test("staged 1, deleted 0; failed to stage: .claude/handoff-todo.md")' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext
        | test("staged: .claude/handoff-task.md; deleted: none; failed to stage: .claude/handoff-todo.md. Leave them staged")' >/dev/null
    grep -q 'did not match any files' "$err"
}
