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

    # Shared synthetic fixture: hermetic across machines and forks, and lets
    # the test assert that the transcript path is actually exercised (not just
    # that the inlined task content survives).
    transcript="$repo_root/tests/fixtures/extract-basic.jsonl"
    [ -f "$transcript" ] || return 1

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

# --- _lib.sh: handoff_activated detector ---

@test "handoff_activated: Skill tool_use (qualified) -> activated" {
    run handoff_activated "$repo_root/tests/fixtures/activated-skill.jsonl"
    [ "$status" -eq 0 ]
}

@test "handoff_activated: Skill tool_use (bare name) -> activated" {
    run handoff_activated "$repo_root/tests/fixtures/activated-skill-bare.jsonl"
    [ "$status" -eq 0 ]
}

@test "handoff_activated: slash command -> activated" {
    run handoff_activated "$repo_root/tests/fixtures/activated-slash.jsonl"
    [ "$status" -eq 0 ]
}

@test "handoff_activated: no signal -> not activated" {
    run handoff_activated "$repo_root/tests/fixtures/extract-basic.jsonl"
    [ "$status" -eq 1 ]
}

@test "handoff_activated: empty path -> not activated" {
    run handoff_activated ""
    [ "$status" -eq 1 ]
}

@test "handoff_activated: missing file -> not activated" {
    run handoff_activated "$tmp/.claude/does-not-exist.jsonl"
    [ "$status" -eq 1 ]
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

# --- write-stage ---
# Stages handoff-task.md, saves the session pointer, and does NOT create
# handoff.md. The pointer is saved at write time (not activation time) so
# agents that update the task after later user input point to the right JSONL.

@test "write-stage (git staging): stages task, saves pointer, no handoff.md" {
    git_tmp="$BATS_TEST_TMPDIR/git"
    mkdir -p "$git_tmp"
    git -C "$git_tmp" init -q
    mkdir -p "$git_tmp/.claude"
    cp "$tmp/.claude/handoff-task.md" "$git_tmp/.claude/handoff-task.md"
    run bash -c '
        jq -nc --arg t "$1" --arg fp "$2/.claude/handoff-task.md" \
            "{transcript_path:\$t, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | CLAUDE_PROJECT_DIR="$2" bash scripts/write-stage.sh
    ' _ "$transcript" "$git_tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.systemMessage == "handoff — staged for commit"' >/dev/null
    git -C "$git_tmp" status --porcelain | grep -q 'handoff-task.md'
    [ "$(cat "$git_tmp/.claude/handoff-session" 2>/dev/null)" = "$transcript" ]
    [ ! -f "$git_tmp/.claude/handoff.md" ]
}

@test "write-stage (unrelated path: no-op)" {
    run bash -c '
        jq -nc --arg t "$1" --arg fp "$2/README.md" \
            "{transcript_path:\$t, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-stage.sh
    ' _ "$transcript" "$tmp"
    [ "$status" -eq 0 ]
}

# --- write-guard ---

@test "write-guard (handoff-task.md, not activated: deny)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg t "$2" --arg fp "$1/.claude/handoff-task.md" \
            "{cwd:\$cwd, transcript_path:\$t, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-guard.sh
    ' _ "$tmp" "$repo_root/tests/fixtures/extract-basic.jsonl"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
}

@test "write-guard (handoff-task.md, activated: allow)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg t "$2" --arg fp "$1/.claude/handoff-task.md" \
            "{cwd:\$cwd, transcript_path:\$t, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-guard.sh
    ' _ "$tmp" "$repo_root/tests/fixtures/activated-skill.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
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

@test "write-guard (CLAUDE_PROJECT_DIR overrides cwd drift: allow)" {
    # Simulates shell cwd drifting to another directory (e.g. /add-dir + cd)
    # while the project root stays $tmp. Write to $tmp should be allowed.
    run bash -c '
        jq -nc --arg cwd "$1" --arg t "$2" --arg fp "$3/.claude/handoff-task.md" \
            "{cwd:\$cwd, transcript_path:\$t, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | CLAUDE_PROJECT_DIR="$3" bash scripts/write-guard.sh
    ' _ "$other" "$repo_root/tests/fixtures/activated-skill.jsonl" "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "write-guard (unrelated filename: allow)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$2/.claude/some-other-file.md" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-guard.sh
    ' _ "$tmp" "$other"
    [ "$status" -eq 0 ]
}

# --- read-guard ---

@test "read-guard (handoff-task.md, not activated: deny)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg t "$2" --arg fp "$1/.claude/handoff-task.md" \
            "{cwd:\$cwd, transcript_path:\$t, tool_name:\"Read\", tool_input:{file_path:\$fp}}" \
        | bash scripts/read-guard.sh
    ' _ "$tmp" "$repo_root/tests/fixtures/extract-basic.jsonl"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
}

@test "read-guard (handoff-task.md, activated: allow)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg t "$2" --arg fp "$1/.claude/handoff-task.md" \
            "{cwd:\$cwd, transcript_path:\$t, tool_name:\"Read\", tool_input:{file_path:\$fp}}" \
        | bash scripts/read-guard.sh
    ' _ "$tmp" "$repo_root/tests/fixtures/activated-slash.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "read-guard (unrelated file: allow)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/README.md" \
            "{cwd:\$cwd, tool_name:\"Read\", tool_input:{file_path:\$fp}}" \
        | bash scripts/read-guard.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# --- skill-pre-hook ---

@test "skill-pre-hook (handoff:handoff: wipe)" {
    : > "$tmp/.claude/handoff-task.md"
    : > "$tmp/.claude/handoff.md"
    run bash -c '
        jq -nc --arg cwd "$1" \
            "{cwd:\$cwd, tool_name:\"Skill\", tool_input:{skill:\"handoff:handoff\"}}" \
        | bash scripts/skill-pre-hook.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/handoff-task.md" ]
    [ ! -e "$tmp/.claude/handoff.md" ]
    [ "$(echo "$output" | jq -r '.systemMessage // ""')" = "handoff: wiped prior handoff-task.md, handoff.md" ]
    [ "$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // ""')" = "handoff activation hook wiped prior handoff files (handoff-task.md, handoff.md); they are absent." ]
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null
}

@test "skill-pre-hook (bare handoff: wipe)" {
    : > "$tmp/.claude/handoff-task.md"
    : > "$tmp/.claude/handoff.md"
    run bash -c '
        jq -nc --arg cwd "$1" \
            "{cwd:\$cwd, tool_name:\"Skill\", tool_input:{skill:\"handoff\"}}" \
        | bash scripts/skill-pre-hook.sh >/dev/null
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/handoff-task.md" ]
    [ ! -e "$tmp/.claude/handoff.md" ]
}

@test "skill-pre-hook (other skill: no-op)" {
    : > "$tmp/.claude/handoff-task.md"
    run bash -c '
        jq -nc --arg cwd "$1" \
            "{cwd:\$cwd, tool_name:\"Skill\", tool_input:{skill:\"some-other:skill\"}}" \
        | bash scripts/skill-pre-hook.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ -e "$tmp/.claude/handoff-task.md" ]
}

@test "skill-pre-hook (missing .claude: create)" {
    fresh="$BATS_TEST_TMPDIR/fresh"
    mkdir -p "$fresh"
    run bash -c '
        jq -nc "{tool_name:\"Skill\", tool_input:{skill:\"handoff:handoff\"}}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/skill-pre-hook.sh
    ' _ "$fresh"
    [ "$status" -eq 0 ]
    [ -d "$fresh/.claude" ]
}

# --- prompt-pre-hook ---

@test "prompt-pre-hook (/handoff:handoff: wipe)" {
    : > "$tmp/.claude/handoff-task.md"
    : > "$tmp/.claude/handoff.md"
    run bash -c '
        jq -nc --arg cwd "$1" \
            "{cwd:\$cwd, prompt:\"/handoff:handoff\"}" \
        | bash scripts/prompt-pre-hook.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/handoff-task.md" ]
    [ ! -e "$tmp/.claude/handoff.md" ]
    [ "$(echo "$output" | jq -r '.systemMessage // ""')" = "handoff: wiped prior handoff-task.md, handoff.md" ]
    [ "$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // ""')" = "handoff activation hook wiped prior handoff files (handoff-task.md, handoff.md); they are absent." ]
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null
}

@test "prompt-pre-hook (/handoff:setup: no-op)" {
    : > "$tmp/.claude/handoff-task.md"
    run bash -c '
        jq -nc --arg cwd "$1" \
            "{cwd:\$cwd, prompt:\"/handoff:setup\"}" \
        | bash scripts/prompt-pre-hook.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ -e "$tmp/.claude/handoff-task.md" ]
}

@test "prompt-pre-hook (unrelated prompt: no-op)" {
    run bash -c '
        jq -nc --arg cwd "$1" \
            "{cwd:\$cwd, prompt:\"hello world\"}" \
        | bash scripts/prompt-pre-hook.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ -e "$tmp/.claude/handoff-task.md" ]
}

# --- load-handoff ---

@test "load-handoff (read-time assembly): injects task + scraped prompt, echoes event" {
    asm_tmp="$BATS_TEST_TMPDIR/asm"; mkdir -p "$asm_tmp/.claude"
    cat > "$asm_tmp/.claude/handoff-task.md" <<'ASMTASK'
## Current task

hook smoke test

## Open decisions

- none
ASMTASK
    printf '%s\n' "$transcript" > "$asm_tmp/.claude/handoff-session"
    run bash -c '
        jq -nc --arg e "clear" "{hook_event_name:\$e}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/load-handoff.sh
    ' _ "$asm_tmp"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    echo "$ctx" | grep -q 'hook smoke test'
    echo "$ctx" | grep -q 'fifth prompt'
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "clear"' >/dev/null
}

@test "load-handoff (read-time assembly): silent no-op without task file" {
    asm_tmp="$BATS_TEST_TMPDIR/asm"; mkdir -p "$asm_tmp/.claude"
    printf '%s\n' "$transcript" > "$asm_tmp/.claude/handoff-session"
    run bash -c '
        jq -nc --arg e "clear" "{hook_event_name:\$e}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/load-handoff.sh
    ' _ "$asm_tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
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

@test "write-rename (matching path, not in tmux): deletes file, systemMessage has /rename line" {
    echo "the title" > "$tmp/.claude/autorename"
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/.claude/autorename" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | env -u TMUX -u TMUX_PANE bash scripts/write-rename.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autorename" ]
    echo "$output" | jq -e '.systemMessage | test("/rename the title")' >/dev/null
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
