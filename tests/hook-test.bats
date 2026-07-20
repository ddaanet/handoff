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

# precompact writes the same task file, so it is an activation signal too.
@test "handoff_activated: precompact Skill tool_use -> activated" {
    run handoff_activated "$repo_root/tests/fixtures/activated-precompact-skill.jsonl"
    [ "$status" -eq 0 ]
}

@test "handoff_activated: precompact slash command -> activated" {
    run handoff_activated "$repo_root/tests/fixtures/activated-precompact-slash.jsonl"
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
# Stages handoff-task.md with `git add -f` and does NOT create handoff.md.

@test "write-stage (git staging): stages task, no handoff.md" {
    git_tmp="$BATS_TEST_TMPDIR/git"
    mkdir -p "$git_tmp"
    git -C "$git_tmp" init -q
    mkdir -p "$git_tmp/.claude"
    cp "$tmp/.claude/handoff-task.md" "$git_tmp/.claude/handoff-task.md"
    run bash -c '
        jq -nc --arg fp "$1/.claude/handoff-task.md" \
            "{tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/write-stage.sh
    ' _ "$git_tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.systemMessage == "handoff — staged for commit"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("version-tracked") and test("gitlore")' >/dev/null
    git -C "$git_tmp" status --porcelain | grep -q 'handoff-task.md'
    [ ! -f "$git_tmp/.claude/handoff.md" ]
}

@test "write-stage (unrelated path: no-op)" {
    run bash -c '
        jq -nc --arg fp "$1/README.md" \
            "{tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-stage.sh
    ' _ "$tmp"
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

@test "write-guard (handoff-task.md, precompact activated: allow)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg t "$2" --arg fp "$1/.claude/handoff-task.md" \
            "{cwd:\$cwd, transcript_path:\$t, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-guard.sh
    ' _ "$tmp" "$repo_root/tests/fixtures/activated-precompact-skill.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "read-guard (handoff-task.md, precompact activated: allow)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg t "$2" --arg fp "$1/.claude/handoff-task.md" \
            "{cwd:\$cwd, transcript_path:\$t, tool_name:\"Read\", tool_input:{file_path:\$fp}}" \
        | bash scripts/read-guard.sh
    ' _ "$tmp" "$repo_root/tests/fixtures/activated-precompact-slash.jsonl"
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

@test "write-guard (worktree cwd: allow write to worktree .claude)" {
    wt="$(make_worktree wtG)"
    run bash -c '
        jq -nc --arg cwd "$1" --arg t "$2" --arg fp "$1/.claude/handoff-task.md" \
            "{cwd:\$cwd, transcript_path:\$t, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-guard.sh
    ' _ "$wt" "$repo_root/tests/fixtures/activated-skill.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
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

@test "read-guard (worktree cwd, not activated: deny)" {
    wt="$(make_worktree wtR)"
    run bash -c '
        jq -nc --arg cwd "$1" --arg t "$2" --arg fp "$1/.claude/handoff-task.md" \
            "{cwd:\$cwd, transcript_path:\$t, tool_name:\"Read\", tool_input:{file_path:\$fp}}" \
        | bash scripts/read-guard.sh
    ' _ "$wt" "$repo_root/tests/fixtures/extract-basic.jsonl"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
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

# handoff-task.md is git-tracked (write-stage.sh force-adds it). When the
# wipe deletes a committed task file, the deletion must be staged too — else
# the write-side `git add -f` and the wipe-side rm are asymmetric and the
# removal never rides the user's next commit. Seed a committed task file in a
# throwaway repo, wipe, assert the index shows a staged deletion (porcelain
# first column `D`, not the unstaged ` D`).
seed_tracked_task() {
    local repo="$1"
    mkdir -p "$repo/.claude"
    printf 'seed task body\n' > "$repo/.claude/handoff-task.md"
    git -C "$repo" init -q
    git -C "$repo" add -f .claude/handoff-task.md
    git -C "$repo" -c user.email=t@t -c user.name=t commit -qm seed
}

@test "skill-pre-hook (git staging): stages handoff-task.md deletion on wipe" {
    git_tmp="$BATS_TEST_TMPDIR/wipegit-ptu"
    mkdir -p "$git_tmp"
    seed_tracked_task "$git_tmp"
    run bash -c '
        jq -nc --arg cwd "$1" \
            "{cwd:\$cwd, tool_name:\"Skill\", tool_input:{skill:\"handoff:handoff\"}}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/skill-pre-hook.sh
    ' _ "$git_tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$git_tmp/.claude/handoff-task.md" ]
    git -C "$git_tmp" status --porcelain .claude/handoff-task.md | grep -q '^D'
}

@test "prompt-pre-hook (git staging): stages handoff-task.md deletion on wipe" {
    git_tmp="$BATS_TEST_TMPDIR/wipegit-ups"
    mkdir -p "$git_tmp"
    seed_tracked_task "$git_tmp"
    run bash -c '
        jq -nc --arg cwd "$1" \
            "{cwd:\$cwd, prompt:\"/handoff:handoff\"}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/prompt-pre-hook.sh
    ' _ "$git_tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$git_tmp/.claude/handoff-task.md" ]
    git -C "$git_tmp" status --porcelain .claude/handoff-task.md | grep -q '^D'
}

@test "skill-pre-hook (non-git cwd: wipe still succeeds)" {
    nogit="$BATS_TEST_TMPDIR/nogit"
    mkdir -p "$nogit/.claude"
    : > "$nogit/.claude/handoff-task.md"
    run bash -c '
        jq -nc --arg cwd "$1" \
            "{cwd:\$cwd, tool_name:\"Skill\", tool_input:{skill:\"handoff:handoff\"}}" \
        | CLAUDE_PROJECT_DIR="$1" bash scripts/skill-pre-hook.sh
    ' _ "$nogit"
    [ "$status" -eq 0 ]
    [ ! -e "$nogit/.claude/handoff-task.md" ]
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

@test "skill-pre-hook (worktree cwd: wipes worktree .claude, not main)" {
    wt="$(make_worktree wtW)"
    : > "$wt/.claude/handoff-task.md"
    run bash -c '
        jq -nc --arg cwd "$1" \
            "{cwd:\$cwd, tool_name:\"Skill\", tool_input:{skill:\"handoff:handoff\"}}" \
        | bash scripts/skill-pre-hook.sh
    ' _ "$wt"
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/handoff-task.md" ]
    [ -e "$tmp/.claude/handoff-task.md" ]
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

# --- report-compact-failure (UserPromptSubmit: surface a watcher non-delivery) ---
#
# Detached watchers have no channel back: a line that never lands is invisible to
# the agent, and the compact watcher's C-u abort leaves the pane looking
# untouched. The watcher drops a reason file; this hook is what reads it.

run_report_failure() {
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, prompt:\"anything\"}" \
        | bash scripts/report-compact-failure.sh
    ' _ "$1"
}

@test "report-compact-failure (no failure file: silent no-op)" {
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "report-compact-failure (failure present: reports on both channels)" {
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

@test "report-compact-failure (consumes the file: reports once, not every prompt)" {
    printf '%s\n' "typed but never submitted" > "$tmp/.claude/autocompact.failed"
    run_report_failure "$tmp"
    [ ! -e "$tmp/.claude/autocompact.failed" ]

    run_report_failure "$tmp"
    [ "$output" = "" ]
}

# A line-1 failure leaves the armed file stranded as .pending: no compaction will
# consume it, and Stop cannot re-arm from it. Clear it with the report.
@test "report-compact-failure (clears a stranded pending file)" {
    printf '%s\n' "typed but never submitted" > "$tmp/.claude/autocompact.failed"
    printf '%s\n' "/compact" "continue" > "$tmp/.claude/autocompact.pending"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autocompact.pending" ]
}

@test "report-compact-failure (worktree cwd: reads the worktree file)" {
    wt="$(make_worktree wtF)"
    printf '%s\n' "typed but never submitted" > "$wt/.claude/autocompact.failed"
    run_report_failure "$wt"
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/autocompact.failed" ]
    echo "$output" | jq -e '.systemMessage | test("never submitted")' >/dev/null
}
