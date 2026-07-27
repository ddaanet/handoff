#!/usr/bin/env bats
# End-to-end test of the hook scripts against synthetic input.
# Each scenario is a real invocation of the hook with a hand-crafted
# tool-event payload. bats `run` captures exit codes and output without
# toggling errexit.
#
# Usage: bats tests/hook-test.bats   (run from plugin root)

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    cd "$repo_root" || return 1

    tmp="$BATS_TEST_TMPDIR/proj"
    other="$BATS_TEST_TMPDIR/other"
    mkdir -p "$tmp/.claude" "$other/.claude"
    export CLAUDE_PROJECT_DIR="$tmp"

    cat > "$tmp/.claude/handoff-task.md" <<'TASK'
## Current task

hook smoke test

## Open decisions

- none
TASK

    # Three hooks here (write-rename, stop-compact, load-compact) spawn a
    # detached watcher, which drives tmux. Without a stub they reach the real
    # server: TMUX=fake does not stop tmux falling back to the default socket,
    # so `%0` is somebody's actual pane. Stub it to an idle, empty composer —
    # the spawned watchers then find nothing to do and exit on their own
    # timeouts, which the tunables below cut to ~1s.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  capture-pane) printf '%s\n' '──── x ──' '❯ ' ;;
esac
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/tmux"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export PATH
    export HANDOFF_WATCHER_TIMEOUT=1 HANDOFF_WATCHER_POLL=0.01 \
           HANDOFF_WATCHER_VERIFY_DELAY=0.01 \
           HANDOFF_WATCHER_CONSUME_TIMEOUT=1 HANDOFF_WATCHER_CONSUME_POLL=0.05

    # shellcheck source-path=SCRIPTDIR source=../scripts/_lib.sh disable=SC1091
    source "$repo_root/scripts/_lib.sh"
}

# Build a fake linked git worktree of $tmp under $BATS_TEST_TMPDIR/$name and
# echo its path. Its .git is a *file* pointing under $tmp/.git/worktrees/$name,
# mirroring real git worktree layout. $tmp is CLAUDE_PROJECT_DIR (set in setup).
make_worktree() {
    local name="${1:-wt}"
    local wt="$BATS_TEST_TMPDIR/$name"
    mkdir -p "$wt/.claude" "$tmp/.git/worktrees/$name"
    printf 'gitdir: %s\n' "$tmp/.git/worktrees/$name" > "$wt/.git"
    printf '%s\n' "$wt"
}

# --- _lib.sh: handoff_root resolver ---

@test "handoff_root: worktree cwd -> worktree root" {
    wt="$(make_worktree wtA)"
    run handoff_root "$wt"
    [ "$status" -eq 0 ]
    [ "$output" = "$wt" ]
}

@test "handoff_root: worktree subdir -> worktree root" {
    wt="$(make_worktree wtB)"
    run handoff_root "$wt/scripts"
    [ "$status" -eq 0 ]
    [ "$output" = "$wt" ]
}

@test "handoff_root: non-worktree cwd -> CLAUDE_PROJECT_DIR" {
    run handoff_root "$other"
    [ "$status" -eq 0 ]
    [ "$output" = "$tmp" ]
}

# The project-root and empty-cwd cases resolve in bash without spawning
# python3 (they mirror worktree_root.py's trivial branches) — Stop and
# UserPromptSubmit hit this on every turn. A broken python3 on PATH proves
# the fast path never leaves the shell.
@test "handoff_root: project-root or empty cwd -> fast path, no python3" {
    run bash -c '
        stub="$1/nopy"; mkdir -p "$stub"
        printf "#!/usr/bin/env bash\nexit 97\n" > "$stub/python3"
        chmod +x "$stub/python3"
        PATH="$stub:$PATH"
        source "$2/scripts/_lib.sh"
        handoff_root "$CLAUDE_PROJECT_DIR" && handoff_root ""
    ' _ "$BATS_TEST_TMPDIR" "$repo_root"
    [ "$status" -eq 0 ]
    [ "$output" = "$tmp
$tmp" ]
}

# --- _lib.sh: handoff_deny emitter ---
# handoff_deny calls `exit 0`; `run` invokes it in a subshell so that exit
# terminates only the subshell, not the test.

@test "handoff_deny (emitter): deny decision, event, reason and systemMessage passthrough" {
    run handoff_deny "reason text" "system text"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null
    [ "$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')" = "reason text" ]
    [ "$(echo "$output" | jq -r '.systemMessage')" = "system text" ]
}

# --- _lib.sh: handoff_frame assembly ---
# One header, then whichever of the two agent-authored files have content,
# task first. Either alone is enough; neither means no frame at all.

@test "handoff_frame: task + todo -> one header, both inlined, task first" {
    fr="$BATS_TEST_TMPDIR/frame"; mkdir -p "$fr"
    printf '## Current task\n\ntask body\n' > "$fr/task.md"
    printf '## Remaining\n\n- todo body\n' > "$fr/todo.md"
    run handoff_frame "$fr/task.md" "$fr/todo.md"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c '^# Task — ')" -eq 1 ]
    echo "$output" | grep -q 'task body'
    echo "$output" | grep -q '^- todo body'
    # Task section precedes the remainder.
    [ "$(echo "$output" | grep -n 'task body' | cut -d: -f1)" \
      -lt "$(echo "$output" | grep -n 'todo body' | cut -d: -f1)" ]
}

@test "handoff_frame: todo alone -> frame still assembles" {
    fr="$BATS_TEST_TMPDIR/frame-todo"; mkdir -p "$fr"
    printf '## Remaining\n\n- lone remainder\n' > "$fr/todo.md"
    run handoff_frame "$fr/task.md" "$fr/todo.md"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '^# Task — '
    echo "$output" | grep -q 'lone remainder'
}

@test "handoff_frame: task alone -> unchanged single-file shape" {
    fr="$BATS_TEST_TMPDIR/frame-task"; mkdir -p "$fr"
    printf '## Current task\n\nsolo task\n' > "$fr/task.md"
    run handoff_frame "$fr/task.md" "$fr/todo.md"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'solo task'
    [ "$(echo "$output" | grep -c '^# Task — ')" -eq 1 ]
}

@test "handoff_frame: neither file -> rc 1, no output" {
    fr="$BATS_TEST_TMPDIR/frame-none"; mkdir -p "$fr"
    run handoff_frame "$fr/task.md" "$fr/todo.md"
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
}

@test "handoff_frame: empty files count as absent" {
    fr="$BATS_TEST_TMPDIR/frame-empty"; mkdir -p "$fr"
    : > "$fr/task.md"; : > "$fr/todo.md"
    run handoff_frame "$fr/task.md" "$fr/todo.md"
    [ "$status" -eq 1 ]
}

# --- write-stage ---
# Stages handoff-task.md with `git add -f` and does NOT create handoff.md.

# handoff-task.md no longer comes through write-stage.sh at all (it is
# checkpoint-only, FR3) — a direct Write to it is caught by write-guard.sh
# before write-stage.sh would ever see it, so there is nothing to test here.

@test "write-stage (git staging): stages handoff-todo.md, reports version-tracked" {
    git_tmp="$BATS_TEST_TMPDIR/git"
    mkdir -p "$git_tmp/.claude"
    git -C "$git_tmp" init -q
    printf '## Remaining\n\n- an item\n' > "$git_tmp/.claude/handoff-todo.md"
    run bash -c '
        jq -nc --arg fp "$1/.claude/handoff-todo.md" \
            "{tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/write-stage.sh
    ' _ "$git_tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.systemMessage == "handoff — staged for commit"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("version-tracked") and test("gitlore")' >/dev/null
    git -C "$git_tmp" status --porcelain | grep -q 'handoff-todo.md'
}

# FR6: an edit that leaves handoff-todo.md with no remaining items removes it
# and stages the removal, rather than leaving behind a file that reads as
# "nothing pending" while still present. Shares checkpoint_is_empty_body with
# checkpoint.sh (tests/checkpoint.bats), so the two writers cannot drift.
@test "write-stage (handoff-todo.md emptied): removed and the removal staged" {
    git_tmp="$BATS_TEST_TMPDIR/git-empty"
    mkdir -p "$git_tmp/.claude"
    git -C "$git_tmp" init -q
    printf '## Remaining\n\n- item\n' > "$git_tmp/.claude/handoff-todo.md"
    git -C "$git_tmp" add -f .claude/handoff-todo.md
    git -C "$git_tmp" -c user.email=t@t -c user.name=t commit -qm seed
    printf '## Remaining\n' > "$git_tmp/.claude/handoff-todo.md"
    run bash -c '
        jq -nc --arg fp "$1/.claude/handoff-todo.md" \
            "{tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/write-stage.sh
    ' _ "$git_tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$git_tmp/.claude/handoff-todo.md" ]
    echo "$output" | jq -e '.systemMessage == "handoff-todo.md emptied — removed and staged."' >/dev/null
    git -C "$git_tmp" status --porcelain .claude/handoff-todo.md | grep -q '^D'
}

@test "write-stage (unrelated path: no-op)" {
    run bash -c '
        jq -nc --arg fp "$1/README.md" \
            "{tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-stage.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
}

# The remainder is overflow from the task file, so it is force-added on the
# same terms — a frame split across a tracked and an untracked half would enter
# history with its decomposition missing.
@test "write-stage (handoff-todo.md: staged)" {
    git_tmp="$BATS_TEST_TMPDIR/git-todo"
    mkdir -p "$git_tmp/.claude"
    git -C "$git_tmp" init -q
    printf '## Remaining\n\n- item\n' > "$git_tmp/.claude/handoff-todo.md"
    run bash -c '
        jq -nc --arg fp "$1/.claude/handoff-todo.md" \
            "{tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/write-stage.sh
    ' _ "$git_tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.systemMessage == "handoff — staged for commit"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext
        | test("handoff-todo.md")' >/dev/null
    staged="$(git -C "$git_tmp" diff --cached --name-only)"
    [[ "$staged" == *handoff-todo.md* ]]
}

# --- write-guard ---
# handoff-task.md is checkpoint-only (FR3): any direct agent Write/Edit is
# denied unconditionally, no activation predicate left to check. read-guard.sh
# is gone entirely — nothing gates a Read any more.

@test "write-guard (handoff-task.md: deny, checkpoint-only)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/.claude/handoff-task.md" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-guard.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason
        | test("checkpoint")' >/dev/null
}

@test "write-guard (cross-project: deny)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$2/.claude/handoff-task.md" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-guard.sh
    ' _ "$tmp" "$other"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null
    echo "$output" | jq -e '.systemMessage' >/dev/null
}

@test "write-guard (CLAUDE_PROJECT_DIR overrides cwd drift: denies as checkpoint-only, not cross-project)" {
    # Simulates shell cwd drifting to another directory (e.g. /add-dir + cd)
    # while the project root stays $tmp. Despite the drifted cwd, the write
    # resolves as in-project and is denied on the checkpoint-only ground, not
    # misclassified as cross-project.
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$2/.claude/handoff-task.md" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | CLAUDE_PROJECT_DIR="$2" bash scripts/write-guard.sh
    ' _ "$other" "$tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason
        | test("checkpoint")' >/dev/null
}

@test "write-guard (unrelated filename: allow)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$2/.claude/some-other-file.md" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-guard.sh
    ' _ "$tmp" "$other"
    [ "$status" -eq 0 ]
}

@test "write-guard (worktree cwd: denies the worktree's own handoff-task.md, not main)" {
    wt="$(make_worktree wtG)"
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/.claude/handoff-task.md" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-guard.sh
    ' _ "$wt"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason
        | test("checkpoint")' >/dev/null
}

# handoff-todo.md is a scratch list the agent edits freely all session (FR4)
# — no PreToolUse guard covers it any more.
@test "write-guard (handoff-todo.md: allow, no longer guarded)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/.claude/handoff-todo.md" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-guard.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# --- load-handoff ---

@test "load-handoff (read-time assembly): injects header + task, echoes event" {
    asm_tmp="$BATS_TEST_TMPDIR/asm"; mkdir -p "$asm_tmp/.claude"
    cat > "$asm_tmp/.claude/handoff-task.md" <<'ASMTASK'
## Current task

hook smoke test

## Open decisions

- none
ASMTASK
    run bash -c '
        jq -nc --arg e "clear" "{hook_event_name:\$e}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/load-handoff.sh
    ' _ "$asm_tmp"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    # "Task", not "Handoff": the file is current task state now, written by
    # either skill and injected at both transitions.
    echo "$ctx" | grep -q '^# Task — '
    echo "$ctx" | grep -q 'hook smoke test'
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "clear"' >/dev/null
}

@test "load-handoff (read-time assembly): silent no-op without task file" {
    asm_tmp="$BATS_TEST_TMPDIR/asm"; mkdir -p "$asm_tmp/.claude"
    run bash -c '
        jq -nc --arg e "clear" "{hook_event_name:\$e}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/load-handoff.sh
    ' _ "$asm_tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "load-handoff (read-time assembly): injects the todo remainder too" {
    asm_tmp="$BATS_TEST_TMPDIR/asm-todo"; mkdir -p "$asm_tmp/.claude"
    printf '## Current task\n\ntask body\n' > "$asm_tmp/.claude/handoff-task.md"
    printf '## Remaining\n\n- wire the loader\n' > "$asm_tmp/.claude/handoff-todo.md"
    run bash -c '
        jq -nc --arg e "clear" "{hook_event_name:\$e}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/load-handoff.sh
    ' _ "$asm_tmp"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    echo "$ctx" | grep -q 'task body'
    echo "$ctx" | grep -q '^- wire the loader'
    [ "$(echo "$ctx" | grep -c '^# Task — ')" -eq 1 ]
}

# A remainder with no active task still has to cross: the todo file alone
# must not read as "nothing pending".
@test "load-handoff (read-time assembly): todo alone still injects" {
    asm_tmp="$BATS_TEST_TMPDIR/asm-todo-only"; mkdir -p "$asm_tmp/.claude"
    printf '## Remaining\n\n- lone remainder\n' > "$asm_tmp/.claude/handoff-todo.md"
    run bash -c '
        jq -nc --arg e "clear" "{hook_event_name:\$e}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/load-handoff.sh
    ' _ "$asm_tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -r '.hookSpecificOutput.additionalContext' \
        | grep -q 'lone remainder'
}

@test "load-handoff (size formatting: KiB threshold)" {
    sz_tmp="$BATS_TEST_TMPDIR/sz"; mkdir -p "$sz_tmp/.claude"
    # ~2048 bytes of content so the assembled output crosses the KiB threshold.
    python3 -c "print('x' * 2048)" > "$sz_tmp/.claude/handoff-task.md"
    touch "$sz_tmp/.claude/handoff-task.md"
    run bash -c '
        jq -nc --arg e "SessionStart" "{hook_event_name:\$e}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/load-handoff.sh
    ' _ "$sz_tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -r '.systemMessage // ""' | grep -Eq '^handoff loaded — [0-9]+\.[0-9]+ KiB, saved'
}

@test "load-handoff (worktree cwd: reads worktree task, not main)" {
    wt="$(make_worktree wtL)"
    cat > "$wt/.claude/handoff-task.md" <<'WTTASK'
## Current task

worktree handoff body

## Open decisions

- none
WTTASK
    run bash -c '
        jq -nc --arg cwd "$1" --arg e "clear" "{cwd:\$cwd, hook_event_name:\$e}" \
        | bash scripts/load-handoff.sh
    ' _ "$wt"
    [ "$status" -eq 0 ]
    echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'worktree handoff body'
}

# --- write-rename ---

@test "write-rename (matching path, in tmux): deletes file, systemMessage confirms rename" {
    echo "the title" > "$tmp/.claude/autorename"
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/.claude/autorename" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | TMUX=fake TMUX_PANE="%0" bash scripts/write-rename.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autorename" ]
    echo "$output" | jq -e '.systemMessage | test("will rename")' >/dev/null
    echo "$output" | jq -e '.systemMessage | test("the title")' >/dev/null
}

@test "write-rename (not in tmux): systemMessage + agent-facing additionalContext carry /rename line" {
    echo "the title" > "$tmp/.claude/autorename"
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/.claude/autorename" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | env -u TMUX -u TMUX_PANE bash scripts/write-rename.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autorename" ]
    echo "$output" | jq -e '.systemMessage | test("/rename the title")' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("/rename the title")' >/dev/null
}

@test "write-rename (unrelated path: no-op)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/README.md" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-rename.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
}

@test "write-rename (empty file: error message, file deleted)" {
    : > "$tmp/.claude/autorename"
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/.claude/autorename" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-rename.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autorename" ]
    echo "$output" | jq -e '.systemMessage | test("empty")' >/dev/null
}

@test "write-rename (worktree cwd: resolves worktree autorename)" {
    wt="$(make_worktree wtN)"
    echo "WT Title" > "$wt/.claude/autorename"
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/.claude/autorename" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | env -u TMUX -u TMUX_PANE bash scripts/write-rename.sh
    ' _ "$wt"
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/autorename" ]
    echo "$output" | jq -e '.systemMessage | test("/rename WT Title")' >/dev/null
}

# --- write-compact (PostToolUse validator) ---
#
# Validate only: never spawns, never deletes. The file must survive to Stop,
# which is the hook that actually arms the compaction.

# Write a .claude/autocompact under $1 with the remaining args as lines.
seed_autocompact() {
    local dir="$1"; shift
    printf '%s\n' "$@" > "$dir/.claude/autocompact"
}

run_write_compact() {
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/.claude/autocompact" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-compact.sh
    ' _ "$1"
}

@test "write-compact (well-formed: silent, file survives)" {
    seed_autocompact "$tmp" "/compact focus on the parser" "continue with task 3"
    run_write_compact "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ -f "$tmp/.claude/autocompact" ]
}

@test "write-compact (bare /compact: accepted)" {
    seed_autocompact "$tmp" "/compact" "continue with task 3"
    run_write_compact "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "write-compact (one line: directive names the two-line constraint)" {
    seed_autocompact "$tmp" "/compact"
    run_write_compact "$tmp"
    [ "$status" -eq 0 ]
    [ -f "$tmp/.claude/autocompact" ]
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("two lines")' >/dev/null
    echo "$output" | jq -e '.systemMessage | test("malformed")' >/dev/null
}

@test "write-compact (three lines: directive)" {
    seed_autocompact "$tmp" "/compact" "continue" "extra"
    run_write_compact "$tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("two lines")' >/dev/null
}

@test "write-compact (line 1 not /compact: directive names the prefix)" {
    seed_autocompact "$tmp" "compact now" "continue with task 3"
    run_write_compact "$tmp"
    [ "$status" -eq 0 ]
    [ -f "$tmp/.claude/autocompact" ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("/compact")' >/dev/null
}

@test "write-compact (unrelated path: no-op)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/README.md" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-compact.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "write-compact (cross-project autocompact: no-op)" {
    seed_autocompact "$other" "/compact" "continue"
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$2/.claude/autocompact" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-compact.sh
    ' _ "$tmp" "$other"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "write-compact (worktree cwd: validates worktree autocompact)" {
    wt="$(make_worktree wtC)"
    seed_autocompact "$wt" "bad first line" "continue"
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/.claude/autocompact" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-compact.sh
    ' _ "$wt"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("/compact")' >/dev/null
}

# --- stop-compact (Stop: arm the compaction) ---

run_stop_compact() {
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, stop_hook_active:false}" \
        | '"$2"' bash scripts/stop-compact.sh
    ' _ "$1"
}

@test "stop-compact (no autocompact: silent no-op)" {
    run_stop_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "stop-compact (in tmux: renames to .pending and reports armed)" {
    seed_autocompact "$tmp" "/compact keep the parser work" "continue with task 3"
    run_stop_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autocompact" ]
    [ -f "$tmp/.claude/autocompact.pending" ]
    echo "$output" | jq -e '.systemMessage | test("compact")' >/dev/null
}

@test "stop-compact (arms once only: second Stop is silent)" {
    seed_autocompact "$tmp" "/compact" "continue with task 3"
    run_stop_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    run_stop_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "stop-compact (not in tmux: emits both lines to paste, clears pending)" {
    seed_autocompact "$tmp" "/compact keep the parser work" "continue with task 3"
    run_stop_compact "$tmp" 'env -u TMUX -u TMUX_PANE'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autocompact" ]
    [ ! -e "$tmp/.claude/autocompact.pending" ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("/compact keep the parser work")' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("continue with task 3")' >/dev/null
}

@test "stop-compact (malformed file survived write-compact: no arming)" {
    seed_autocompact "$tmp" "not a command" "continue"
    run_stop_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autocompact.pending" ]
    echo "$output" | jq -e '.systemMessage | test("malformed")' >/dev/null
}

@test "stop-compact (worktree cwd: arms the worktree file)" {
    wt="$(make_worktree wtS)"
    seed_autocompact "$wt" "/compact" "continue with task 3"
    run_stop_compact "$wt" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ -f "$wt/.claude/autocompact.pending" ]
}

# --- load-compact (SessionStart(compact): fire the continuation) ---

run_load_compact() {
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, source:\"compact\"}" \
        | '"$2"' bash scripts/load-compact.sh
    ' _ "$1"
}

@test "load-compact (no pending: silent no-op)" {
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "load-compact (pending present: consumes it and reports the continuation)" {
    printf '%s\n' "/compact" "continue with task 3" > "$tmp/.claude/autocompact.pending"
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autocompact.pending" ]
    echo "$output" | jq -e '.systemMessage | test("continue")' >/dev/null
}

@test "load-compact (not in tmux: emits continuation to paste, clears pending)" {
    printf '%s\n' "/compact" "continue with task 3" > "$tmp/.claude/autocompact.pending"
    run_load_compact "$tmp" 'env -u TMUX -u TMUX_PANE'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autocompact.pending" ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("continue with task 3")' >/dev/null
}

# The task file carries the content across compaction; the typed prompt is only
# a handle to it. So the frame has to be injected here, the same way
# load-handoff.sh injects it at startup|clear.
@test "load-compact (task file present: injects the frame)" {
    printf '%s\n' "/compact" "resume per the task file" > "$tmp/.claude/autocompact.pending"
    printf '%s\n' "## Now" "- rewire the parser" > "$tmp/.claude/handoff-task.md"
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("rewire the parser")' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
    # The task file survives — it is not consumed by being read.
    [ -s "$tmp/.claude/handoff-task.md" ]
}

@test "load-compact (no task file: continuation still fires, no frame)" {
    rm -f "$tmp/.claude/handoff-task.md"
    printf '%s\n' "/compact" "continue with task 3" > "$tmp/.claude/autocompact.pending"
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.systemMessage | test("continue")' >/dev/null
    echo "$output" | jq -e 'has("hookSpecificOutput") | not' >/dev/null
}

@test "load-compact (not in tmux, task file present: frame and prompt both emitted)" {
    printf '%s\n' "/compact" "resume per the task file" > "$tmp/.claude/autocompact.pending"
    printf '%s\n' "## Now" "- rewire the parser" > "$tmp/.claude/handoff-task.md"
    run_load_compact "$tmp" 'env -u TMUX -u TMUX_PANE'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("rewire the parser")' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("resume per the task file")' >/dev/null
}

@test "load-compact (worktree cwd: consumes the worktree pending file)" {
    wt="$(make_worktree wtL)"
    printf '%s\n' "/compact" "continue with task 3" > "$wt/.claude/autocompact.pending"
    run_load_compact "$wt" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/autocompact.pending" ]
}

# --- report-watcher-failure (UserPromptSubmit: surface a watcher non-delivery) ---
#
# Detached watchers have no channel back: a line that never lands is invisible to
# the agent, and the compact watcher's C-u abort leaves the pane looking
# untouched. The watcher drops a reason file; this hook is what reads it.

run_report_failure() {
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, prompt:\"anything\"}" \
        | bash scripts/report-watcher-failure.sh
    ' _ "$1"
}

@test "report-watcher-failure (no failure file: silent no-op)" {
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "report-watcher-failure (failure present: reports on both channels)" {
    printf '%s\n' "the TUI did not recognize \`/compact\`" \
        > "$tmp/.claude/autocompact.failed"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.systemMessage | test("did not recognize")' >/dev/null
    echo "$output" | jq -e \
        '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null
    echo "$output" | jq -e \
        '.hookSpecificOutput.additionalContext | test("did not recognize")' >/dev/null
}

@test "report-watcher-failure (consumes the file: reports once, not every prompt)" {
    printf '%s\n' "typed but never submitted" > "$tmp/.claude/autocompact.failed"
    run_report_failure "$tmp"
    [ ! -e "$tmp/.claude/autocompact.failed" ]

    run_report_failure "$tmp"
    [ "$output" = "" ]
}

# A line-1 failure leaves the armed file stranded as .pending: no compaction will
# consume it, and Stop cannot re-arm from it. Clear it with the report.
@test "report-watcher-failure (clears a stranded pending file)" {
    printf '%s\n' "typed but never submitted" > "$tmp/.claude/autocompact.failed"
    printf '%s\n' "/compact" "continue" > "$tmp/.claude/autocompact.pending"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autocompact.pending" ]
}

@test "report-watcher-failure (worktree cwd: reads the worktree file)" {
    wt="$(make_worktree wtF)"
    printf '%s\n' "typed but never submitted" > "$wt/.claude/autocompact.failed"
    run_report_failure "$wt"
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/autocompact.failed" ]
    echo "$output" | jq -e '.systemMessage | test("never submitted")' >/dev/null
}

# An autocompact is armed at the Stop of the turn that writes it, and Stop
# renames it away. So one still present at a *later* turn's UserPromptSubmit
# never armed — its turn ended abnormally (Esc, crash, quit). Left alone it is
# armed by the next normal Stop, days later and possibly in another session,
# driving a stale /compact into unrelated work.
@test "report-watcher-failure (stale autocompact: discards it and reports)" {
    printf '%s\n' "/compact keep the parser work" "continue with task 3" \
        > "$tmp/.claude/autocompact"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autocompact" ]
    echo "$output" | jq -e '.systemMessage | test("stale")' >/dev/null
    echo "$output" | jq -e \
        '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null
    echo "$output" | jq -e \
        '.hookSpecificOutput.additionalContext | test("autocompact")' >/dev/null
}

@test "report-watcher-failure (stale autocompact: reports once, not every prompt)" {
    printf '%s\n' "/compact" "continue with task 3" > "$tmp/.claude/autocompact"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run_report_failure "$tmp"
    [ "$output" = "" ]
}

# .pending is legitimate for the whole Stop -> compaction window, and that
# window contains the watcher's own /compact submit — a UserPromptSubmit. Only
# a watcher-observed failure may clear it; a stale autocompact must not, or the
# sweep would race SessionStart(compact) and kill a live continuation.
@test "report-watcher-failure (stale autocompact leaves .pending alone)" {
    printf '%s\n' "/compact" "continue" > "$tmp/.claude/autocompact"
    printf '%s\n' "/compact" "continue" > "$tmp/.claude/autocompact.pending"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autocompact" ]
    [ -f "$tmp/.claude/autocompact.pending" ]
}

@test "report-watcher-failure (failure and stale file: one report covering both)" {
    printf '%s\n' "typed but never submitted" > "$tmp/.claude/autocompact.failed"
    printf '%s\n' "/compact" "continue" > "$tmp/.claude/autocompact"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -sr 'length')" = "1" ]
    echo "$output" | jq -e '.systemMessage | test("never submitted")' >/dev/null
    echo "$output" | jq -e '.systemMessage | test("stale")' >/dev/null
}

# The rename watcher is detached on the same terms as the compaction ones, so
# its non-deliveries need the same path back. One hook reads both files: they
# differ only in which line never landed.
@test "report-watcher-failure (rename failure: reports on both channels)" {
    printf '%s\n' "the user was composing a prompt" \
        > "$tmp/.claude/autorename.failed"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autorename.failed" ]
    echo "$output" | jq -e '.systemMessage | test("composing")' >/dev/null
    echo "$output" | jq -e \
        '.hookSpecificOutput.additionalContext | test("rename")' >/dev/null
}

@test "report-watcher-failure (both watchers failed: one report covering both)" {
    printf '%s\n' "typed but never submitted" > "$tmp/.claude/autocompact.failed"
    printf '%s\n' "the user was composing a prompt" \
        > "$tmp/.claude/autorename.failed"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -sr 'length')" = "1" ]
    echo "$output" | jq -e '.systemMessage | test("never submitted")' >/dev/null
    echo "$output" | jq -e '.systemMessage | test("composing")' >/dev/null
}

# A rename failure says nothing about a compaction, so it must not clear the
# armed file — same reasoning as the stale-autocompact sweep.
@test "report-watcher-failure (rename failure leaves .pending alone)" {
    printf '%s\n' "the user was composing a prompt" \
        > "$tmp/.claude/autorename.failed"
    printf '%s\n' "/compact" "continue" > "$tmp/.claude/autocompact.pending"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autorename.failed" ]
    [ -f "$tmp/.claude/autocompact.pending" ]
}

@test "report-watcher-failure (worktree cwd: sweeps the worktree file)" {
    wt="$(make_worktree wtG)"
    printf '%s\n' "/compact" "continue" > "$wt/.claude/autocompact"
    run_report_failure "$wt"
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/autocompact" ]
    echo "$output" | jq -e '.systemMessage | test("stale")' >/dev/null
}
