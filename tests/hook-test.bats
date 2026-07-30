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

    # Three hooks here (stop-drive, load-compact, load-handoff) spawn the
    # detached walker, which drives tmux. Without a stub they reach the real
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

# --- _lib.sh: handoff_drive_read shape matrix ---
#
# Line 1 is the kind and the kind fixes the shape, so the remaining lines need
# no separator and each kind keeps its own rules. The lines are the literal
# keystrokes: the walker must not know which command any kind uses, and
# validation is what anchors it — the nth line of kind k must begin with the
# expected command literal, so the file cannot be made to type something else.

# Write the args as lines of a sentinel and read it back. On rejection the
# reason is printed, so a `run read_drive ...` can assert on it — the reader
# itself only sets DRIVE_ERR, which a subshell would swallow. Call it bare (not
# under `run`) when the test needs the DRIVE_* variables it populates.
read_drive() {
    printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/sentinel"
    handoff_drive_read "$BATS_TEST_TMPDIR/sentinel" && return 0
    printf '%s\n' "$DRIVE_ERR"
    return 1
}

@test "handoff_drive_read (rename): one before-line, no after-line" {
    read_drive "rename" "/rename Driven Transitions"
    [ "$DRIVE_KIND" = rename ]
    [ "${#DRIVE_BEFORE[@]}" -eq 1 ]
    [ "${DRIVE_BEFORE[0]}" = "/rename Driven Transitions" ]
    [ "${#DRIVE_AFTER[@]}" -eq 0 ]
}

@test "handoff_drive_read (compact): command before, prose after" {
    read_drive "compact" "/compact focus on the parser" "continue with task 3"
    [ "$DRIVE_KIND" = compact ]
    [ "${DRIVE_BEFORE[0]}" = "/compact focus on the parser" ]
    [ "${DRIVE_AFTER[0]}" = "continue with task 3" ]
}

@test "handoff_drive_read (compact, bare command): accepted, /compact takes no argument" {
    read_drive "compact" "/compact" "continue with task 3"
    [ "${DRIVE_BEFORE[0]}" = "/compact" ]
}

# FR-G: the kind line alone. Nothing is typed, but the transition is expected,
# and that expectation is what the frame's re-injection is gated on.
@test "handoff_drive_read (compact, kind line alone): legal, both sequences empty" {
    read_drive "compact"
    [ "$DRIVE_KIND" = compact ]
    [ "${#DRIVE_BEFORE[@]}" -eq 0 ]
    [ "${#DRIVE_AFTER[@]}" -eq 0 ]
}

@test "handoff_drive_read (clear): two before-lines in order, prose after" {
    read_drive "clear" "/rename A Title" "/clear" "pick up per the task file"
    [ "$DRIVE_KIND" = clear ]
    [ "${#DRIVE_BEFORE[@]}" -eq 2 ]
    [ "${DRIVE_BEFORE[0]}" = "/rename A Title" ]
    [ "${DRIVE_BEFORE[1]}" = "/clear" ]
    [ "${DRIVE_AFTER[0]}" = "pick up per the task file" ]
}

@test "handoff_drive_read (unknown kind): rejected, naming the kinds" {
    run read_drive "reboot" "/reboot"
    [ "$status" -ne 0 ]
    [[ "$output" == *"transition kind"* ]]
}

# The old autorename shape. No back-compat branch: a bare title has no kind
# line, so it is simply an unknown kind.
@test "handoff_drive_read (bare title, the old autorename shape): rejected" {
    run read_drive "Some Session Title"
    [ "$status" -ne 0 ]
}

@test "handoff_drive_read (empty file): rejected" {
    run read_drive ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"transition kind"* ]]
}

@test "handoff_drive_read (wrong line count for the kind): rejected, naming the count" {
    run read_drive "rename" "/rename A Title" "extra line"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exactly 2 lines"* ]]

    run read_drive "clear" "/rename A Title" "/clear"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exactly 4 lines"* ]]

    run read_drive "compact" "/compact" "continue" "extra"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exactly 3 lines"* ]]
}

@test "handoff_drive_read (command literal not in the kind's slot): rejected" {
    run read_drive "clear" "/clear" "/rename A Title" "resume"
    [ "$status" -ne 0 ]
    [[ "$output" == *"line 2"* ]]

    run read_drive "compact" "compact now" "continue"
    [ "$status" -ne 0 ]
    [[ "$output" == *"/compact"* ]]
}

@test "handoff_drive_read (/rename with no argument): rejected" {
    run read_drive "rename" "/rename"
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-empty argument"* ]]

    run read_drive "rename" "/rename    "
    [ "$status" -ne 0 ]
}

@test "handoff_drive_read (/clear with an argument): rejected" {
    run read_drive "clear" "/rename A Title" "/clear now" "resume"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exactly"* ]]
}

@test "handoff_drive_read (empty continuation prompt): rejected" {
    run read_drive "compact" "/compact" ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not be empty"* ]]
}

# The walker dispatches on the leading character: a `/` line takes the
# recognition path and is confirmed by a command primitive, prose takes the
# direct path. A prose line that looks like a command would be confirmed by the
# wrong one.
@test "handoff_drive_read (continuation prompt beginning with /): rejected" {
    run read_drive "clear" "/rename A Title" "/clear" "/resume the work"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not begin"* ]]
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
    echo "$output" | jq -r '.systemMessage // ""' | grep -Eq '^handoff: loaded — [0-9]+\.[0-9]+ KiB, saved'
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

# --- load-handoff on source: "clear" (consume the armed clear, spawn line 4) ---
#
# `/clear` mints a new session and a new transcript, and this payload reports
# both, so the after-line confirms against .transcript_path here exactly as it
# does at the compact boundary.

# Write a .claude/autodrive.pending under $1 with the remaining args as lines.
seed_pending() {
    local dir="$1"; shift
    printf '%s\n' "$@" > "$dir/.claude/autodrive.pending"
}

run_load_handoff() {
    run bash -c '
        jq -nc --arg cwd "$1" --arg s "$2" \
            "{cwd:\$cwd, hook_event_name:\"SessionStart\", source:\$s, transcript_path:(\$cwd + \"/t.jsonl\")}" \
        | '"$3"' bash scripts/load-handoff.sh
    ' _ "$1" "$2"
}

@test "load-handoff (clear, pending present: consumes it and reports the continuation)" {
    seed_pending "$tmp" "clear" "/rename A Title" "/clear" "pick up per the task file"
    run_load_handoff "$tmp" clear 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive.pending" ]
    echo "$output" | jq -e '.systemMessage | test("pick up per the task file")' >/dev/null
    # The frame still goes out alongside it.
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("hook smoke test")' >/dev/null
}

# The ordering hazard, and the regression this row exists to catch: the script
# exits when handoff_frame finds nothing to inject, so the consume and the spawn
# have to come first. Otherwise a driven clear whose task file is empty strands
# the pending file and never continues.
@test "load-handoff (clear, pending present but NO frame: still continues)" {
    rm -f "$tmp/.claude/handoff-task.md" "$tmp/.claude/handoff-todo.md"
    seed_pending "$tmp" "clear" "/rename A Title" "/clear" "resume anyway"
    run_load_handoff "$tmp" clear 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive.pending" ]
    echo "$output" | jq -e '.systemMessage | test("resume anyway")' >/dev/null
    echo "$output" | jq -e 'has("hookSpecificOutput") | not' >/dev/null
}

@test "load-handoff (clear, no pending: frame only, silent about any transition)" {
    run_load_handoff "$tmp" clear 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.systemMessage | test("loaded")' >/dev/null
    echo "$output" | jq -e '.systemMessage | test("resume") | not' >/dev/null
}

# Each loader consumes only its own transition. A hand-typed /clear fires the
# same hook, and a compact armed in the outgoing session must survive it.
@test "load-handoff (clear, pending of kind compact: left for SessionStart(compact))" {
    seed_pending "$tmp" "compact" "/compact" "continue with task 3"
    run_load_handoff "$tmp" clear 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ -f "$tmp/.claude/autodrive.pending" ]
}

@test "load-handoff (startup with a pending present: does not consume it)" {
    seed_pending "$tmp" "clear" "/rename A Title" "/clear" "pick up per the task file"
    run_load_handoff "$tmp" startup 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ -f "$tmp/.claude/autodrive.pending" ]
    echo "$output" | jq -e '.systemMessage | test("pick up") | not' >/dev/null
}

@test "load-handoff (clear, not in tmux: emits the after-line to paste)" {
    seed_pending "$tmp" "clear" "/rename A Title" "/clear" "pick up per the task file"
    run_load_handoff "$tmp" clear 'env -u TMUX -u TMUX_PANE'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive.pending" ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("pick up per the task file")' >/dev/null
}

@test "load-handoff (clear, malformed pending: discarded, reported, not armed)" {
    seed_pending "$tmp" "clear" "/rename A Title" "not a clear" "resume"
    run_load_handoff "$tmp" clear 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive.pending" ]
    echo "$output" | jq -e '.systemMessage | test("malformed")' >/dev/null
}

# --- write-drive (PostToolUse validator) ---
#
# Validate only: never spawns, never deletes. The file must survive to Stop,
# which is the hook that actually arms the transition.

# Write a .claude/autodrive under $1 with the remaining args as lines.
seed_drive() {
    local dir="$1"; shift
    printf '%s\n' "$@" > "$dir/.claude/autodrive"
}

run_write_drive() {
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$2/.claude/autodrive" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-drive.sh
    ' _ "$1" "${2:-$1}"
}

@test "write-drive (well-formed rename: silent, file survives)" {
    seed_drive "$tmp" "rename" "/rename Driven Transitions"
    run_write_drive "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ -f "$tmp/.claude/autodrive" ]
}

@test "write-drive (well-formed compact: silent)" {
    seed_drive "$tmp" "compact" "/compact focus on the parser" "continue with task 3"
    run_write_drive "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "write-drive (well-formed clear: silent)" {
    seed_drive "$tmp" "clear" "/rename A Title" "/clear" "pick up per the task file"
    run_write_drive "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "write-drive (prepare-only compact marker: silent)" {
    seed_drive "$tmp" "compact"
    run_write_drive "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "write-drive (malformed: directive on both channels, file survives)" {
    seed_drive "$tmp" "clear" "/rename A Title" "/clear"
    run_write_drive "$tmp"
    [ "$status" -eq 0 ]
    [ -f "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.systemMessage | test("malformed")' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("4 lines")' >/dev/null
}

@test "write-drive (unknown kind: directive names the kinds)" {
    seed_drive "$tmp" "reboot" "/reboot now"
    run_write_drive "$tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("transition kind")' >/dev/null
}

@test "write-drive (unrelated path: no-op)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/README.md" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-drive.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "write-drive (cross-project autodrive: no-op)" {
    seed_drive "$other" "clear" "/rename A Title" "/clear"
    run_write_drive "$tmp" "$other"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "write-drive (worktree cwd: validates the worktree autodrive)" {
    wt="$(make_worktree wtC)"
    seed_drive "$wt" "bad kind" "/whatever"
    run_write_drive "$wt"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("transition kind")' >/dev/null
}

# --- stop-drive (Stop: arm the transition) ---

run_stop_drive() {
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, stop_hook_active:false, transcript_path:(\$cwd + \"/t.jsonl\")}" \
        | '"$2"' bash scripts/stop-drive.sh
    ' _ "$1"
}

@test "stop-drive (no autodrive: silent no-op)" {
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "stop-drive (kind with a confirming source: renames to .pending, reports armed)" {
    seed_drive "$tmp" "compact" "/compact keep the parser work" "continue with task 3"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    [ -f "$tmp/.claude/autodrive.pending" ]
    echo "$output" | jq -e '.systemMessage | test("/compact keep the parser work")' >/dev/null
}

# `rename` has no loader, so nothing would ever clear a .pending armed for it.
@test "stop-drive (kind rename: deletes the sentinel, arms no .pending)" {
    seed_drive "$tmp" "rename" "/rename Driven Transitions"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    [ ! -e "$tmp/.claude/autodrive.pending" ]
    echo "$output" | jq -e '.systemMessage | test("/rename Driven Transitions")' >/dev/null
}

@test "stop-drive (arms once only: second Stop is silent)" {
    seed_drive "$tmp" "compact" "/compact" "continue with task 3"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# FR-G: the prepare-only marker. Nothing is typed and nothing is spawned; the
# .pending file alone is the whole effect, and it is what SessionStart(compact)
# gates the frame re-injection on.
@test "stop-drive (empty before-sequence: arms .pending, spawns nothing)" {
    seed_drive "$tmp" "compact"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ -f "$tmp/.claude/autodrive.pending" ]
    echo "$output" | jq -e '.systemMessage | test("nothing to type")' >/dev/null
}

@test "stop-drive (not in tmux: emits every line to paste, in order, clears pending)" {
    seed_drive "$tmp" "clear" "/rename A Title" "/clear" "pick up per the task file"
    run_stop_drive "$tmp" 'env -u TMUX -u TMUX_PANE'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    [ ! -e "$tmp/.claude/autodrive.pending" ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    echo "$ctx" | grep -q '^/rename A Title$'
    echo "$ctx" | grep -q '^/clear$'
    echo "$ctx" | grep -q '^pick up per the task file$'
    # Before-lines precede the after-line: the paste order is the run order.
    r=$(echo "$ctx" | grep -n '^/rename A Title$' | cut -d: -f1)
    c=$(echo "$ctx" | grep -n '^/clear$' | cut -d: -f1)
    p=$(echo "$ctx" | grep -n '^pick up per the task file$' | cut -d: -f1)
    [ "$r" -lt "$c" ] && [ "$c" -lt "$p" ]
}

@test "stop-drive (malformed file survived write-drive: discarded, not armed)" {
    seed_drive "$tmp" "clear" "/rename A Title"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    [ ! -e "$tmp/.claude/autodrive.pending" ]
    echo "$output" | jq -e '.systemMessage | test("malformed")' >/dev/null
}

@test "stop-drive (worktree cwd: arms the worktree file)" {
    wt="$(make_worktree wtS)"
    seed_drive "$wt" "compact" "/compact" "continue with task 3"
    run_stop_drive "$wt" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ -f "$wt/.claude/autodrive.pending" ]
}

# --- load-compact (SessionStart(compact): fire the continuation) ---
#
# The regression this matrix guards is silent: a frame that stops being injected
# fails by the successor knowing less, not by anything going red.

run_load_compact() {
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, source:\"compact\", transcript_path:(\$cwd + \"/t.jsonl\")}" \
        | '"$2"' bash scripts/load-compact.sh
    ' _ "$1"
}

@test "load-compact (no pending: silent, and no frame — a hand-typed /compact injects nothing)" {
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "load-compact (pending present: consumes it and reports the continuation)" {
    seed_pending "$tmp" "compact" "/compact" "continue with task 3"
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive.pending" ]
    echo "$output" | jq -e '.systemMessage | test("continue with task 3")' >/dev/null
}

@test "load-compact (pending of kind clear: left for SessionStart(clear))" {
    seed_pending "$tmp" "clear" "/rename A Title" "/clear" "pick up per the task file"
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ -f "$tmp/.claude/autodrive.pending" ]
}

@test "load-compact (not in tmux: emits continuation to paste, clears pending)" {
    seed_pending "$tmp" "compact" "/compact" "continue with task 3"
    run_load_compact "$tmp" 'env -u TMUX -u TMUX_PANE'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive.pending" ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("continue with task 3")' >/dev/null
}

# The task file carries the content across compaction; the typed prompt is only
# a handle to it. So the frame has to be injected here, the same way
# load-handoff.sh injects it at startup|clear.
@test "load-compact (task file present: injects the frame)" {
    seed_pending "$tmp" "compact" "/compact" "resume per the task file"
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
    seed_pending "$tmp" "compact" "/compact" "continue with task 3"
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.systemMessage | test("continue")' >/dev/null
    echo "$output" | jq -e 'has("hookSpecificOutput") | not' >/dev/null
}

# FR-G's other half: the prepare-only marker arrives here as a pending file with
# no after-line. Inject the frame, type nothing.
@test "load-compact (empty after-sequence: frame injected, nothing typed)" {
    seed_pending "$tmp" "compact"
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive.pending" ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("hook smoke test")' >/dev/null
    echo "$output" | jq -e '.systemMessage | test("frame re-injected")' >/dev/null
}

@test "load-compact (not in tmux, task file present: frame and prompt both emitted)" {
    seed_pending "$tmp" "compact" "/compact" "resume per the task file"
    printf '%s\n' "## Now" "- rewire the parser" > "$tmp/.claude/handoff-task.md"
    run_load_compact "$tmp" 'env -u TMUX -u TMUX_PANE'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("rewire the parser")' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("resume per the task file")' >/dev/null
}

@test "load-compact (worktree cwd: consumes the worktree pending file)" {
    wt="$(make_worktree wtLC)"
    seed_pending "$wt" "compact" "/compact" "continue with task 3"
    run_load_compact "$wt" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/autodrive.pending" ]
}

# --- report-watcher-failure (UserPromptSubmit: surface a non-delivery) ---
#
# The walker is detached and has no channel back: a line that never lands is
# invisible to the agent, and the recognition abort leaves the pane looking
# untouched. The walker drops a reason file; this hook is what reads it. One
# channel now, not two — the transition is a singleton.

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
        > "$tmp/.claude/autodrive.failed"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.systemMessage | test("did not recognize")' >/dev/null
    echo "$output" | jq -e \
        '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null
    echo "$output" | jq -e \
        '.hookSpecificOutput.additionalContext | test("did not recognize")' >/dev/null
}

@test "report-watcher-failure (consumes the file: reports once, not every prompt)" {
    printf '%s\n' "typed but never submitted" > "$tmp/.claude/autodrive.failed"
    run_report_failure "$tmp"
    [ ! -e "$tmp/.claude/autodrive.failed" ]

    run_report_failure "$tmp"
    [ "$output" = "" ]
}

# A failure part-way through a sequence leaves the armed file stranded as
# .pending: no transition will consume it, and Stop cannot re-arm from it.
@test "report-watcher-failure (clears a stranded pending file)" {
    printf '%s\n' "typed but never submitted" > "$tmp/.claude/autodrive.failed"
    seed_pending "$tmp" "compact" "/compact" "continue"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive.pending" ]
}

@test "report-watcher-failure (worktree cwd: reads the worktree file)" {
    wt="$(make_worktree wtF)"
    printf '%s\n' "typed but never submitted" > "$wt/.claude/autodrive.failed"
    run_report_failure "$wt"
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/autodrive.failed" ]
    echo "$output" | jq -e '.systemMessage | test("never submitted")' >/dev/null
}

# An autodrive is armed at the Stop of the turn that writes it, and Stop renames
# or removes it. So one still present at a *later* turn's UserPromptSubmit never
# armed — its turn ended abnormally (Esc, crash, quit). Left alone it is armed by
# the next normal Stop, days later and possibly in another session, driving a
# stale transition into unrelated work.
@test "report-watcher-failure (stale autodrive: discards it and reports)" {
    seed_drive "$tmp" "compact" "/compact keep the parser work" "continue with task 3"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.systemMessage | test("stale")' >/dev/null
    echo "$output" | jq -e \
        '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null
    echo "$output" | jq -e \
        '.hookSpecificOutput.additionalContext | test("autodrive")' >/dev/null
}

@test "report-watcher-failure (stale autodrive: reports once, not every prompt)" {
    seed_drive "$tmp" "compact" "/compact" "continue with task 3"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    run_report_failure "$tmp"
    [ "$output" = "" ]
}

# .pending is legitimate for the whole Stop -> transition window, and that window
# contains the walker's own submit — a UserPromptSubmit. Only a watcher-observed
# failure may clear it; a stale autodrive must not, or the sweep would race
# SessionStart(compact|clear) and kill a live continuation.
@test "report-watcher-failure (stale autodrive leaves .pending alone)" {
    seed_drive "$tmp" "compact" "/compact" "continue"
    seed_pending "$tmp" "compact" "/compact" "continue"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    [ -f "$tmp/.claude/autodrive.pending" ]
}

@test "report-watcher-failure (failure and stale file: one report covering both)" {
    printf '%s\n' "typed but never submitted" > "$tmp/.claude/autodrive.failed"
    seed_drive "$tmp" "compact" "/compact" "continue"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -sr 'length')" = "1" ]
    echo "$output" | jq -e '.systemMessage | test("never submitted")' >/dev/null
    echo "$output" | jq -e '.systemMessage | test("stale")' >/dev/null
}

@test "report-watcher-failure (worktree cwd: sweeps the worktree file)" {
    wt="$(make_worktree wtG)"
    seed_drive "$wt" "compact" "/compact" "continue"
    run_report_failure "$wt"
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/autodrive" ]
    echo "$output" | jq -e '.systemMessage | test("stale")' >/dev/null
}
