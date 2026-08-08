#!/usr/bin/env bats
# Tests for scripts/checkpoint.sh (handoff-checkpoint), bin/handoff-checkpoint,
# and scripts/bash-post.sh — the one-write-path channel that replaced
# scripts/memory-probe.sh, scripts/precompact-probe.sh, the activation wipe,
# and the agent's three separate Write calls. See
# docs/changelog/2026-07-27-one-channel-one-writer.md.
#
# The checkpoint reads a JSON payload on stdin (schema in
# plans/2026-07-27-checkpoint-channel-design.md), applies task/todo
# Write-or-Edit semantics, removes a file whose body ends up empty, and
# prints the same directives (memory gate, SDD nudge) the two deleted probes
# printed. bash-post.sh (PostToolUse(Bash)) consumes the manifest it leaves,
# since git/tmux cannot run from the agent's sandboxed Bash (NFR1).
#
# Merged from tests/memory-probe.bats + tests/precompact-probe.bats: the
# commit-awareness contract, the mutation-checked with-commit negative, the
# composed memory-then-SDD ordering, and the ledger-liveness matrix all carry
# over unchanged in substance, retargeted at the single entry point.
#
# Run with: bats tests/checkpoint.bats   (from plugin root)

# shellcheck disable=SC2154   # $stderr is set by bats `run --separate-stderr`
bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    CHECKPOINT="$repo_root/scripts/checkpoint.sh"
    SHIM="$repo_root/bin/handoff-checkpoint"
    APPROVED="$repo_root/bin/handoff-approved"
    BASHPOST="$repo_root/scripts/bash-post.sh"
    load probe-helpers

    # No tmux stub here, unlike tests/hook-test.bats: neither script this suite
    # exercises reaches a pane. checkpoint.sh is forbidden to (NFR1 — it runs in
    # the agent's sandboxed Bash), and bash-post.sh only stages, since a
    # checkpoint-written sentinel is armed at Stop like any other.

    # The checkpoint runs in the agent's Bash, where CLAUDE_PROJECT_DIR is
    # unset and $PWD is wherever the session cwd has drifted to. It reads the
    # root from the session-keyed pointer SessionStart published instead — so
    # these tests set the session id and redirect the pointer directory away
    # from the runner's real /tmp/claude, and never set CLAUDE_PROJECT_DIR.
    export HANDOFF_POINTER_DIR="$BATS_TEST_TMPDIR/pointer"
    export CLAUDE_CODE_SESSION_ID="sess-checkpoint"

    # For asserting that what the checkpoint writes is what the arming hook
    # will accept.
    # shellcheck source-path=SCRIPTDIR source=../scripts/_lib.sh disable=SC1091
    source "$repo_root/scripts/_lib.sh"
}

# Publish $1 as this session's root, the way scripts/session-pointer.sh does at
# SessionStart.
write_pointer() {
    mkdir -p "$HANDOFF_POINTER_DIR"
    printf '%s\n' "$1" > "$HANDOFF_POINTER_DIR/handoff-root-$CLAUDE_CODE_SESSION_ID"
}

# A plain git repo with .claude/ present — for the schema/write/manifest
# tests that don't need the gitlore/SDD fixture shapes from probe-helpers.
make_repo() {
    local repo="${1:-$BATS_TEST_TMPDIR/repo}"
    rm -rf "$repo"; mkdir -p "$repo/.claude"
    git -C "$repo" init -q
    printf '%s\n' "$repo"
}

# Run the checkpoint against $2 (a JSON payload string) with cwd = $1 and the
# published root = $3 (default $1: cwd and root agree, the undrifted case).
run_checkpoint() {
    local repo="$1" payload="$2" root="${3:-$1}"
    write_pointer "$root"
    run bash -c 'cd "$1" && bash "$2" <<<"$3"' \
        _ "$repo" "$CHECKPOINT" "$payload"
}

# Same, asserting exit 2 with stderr captured separately — for schema and
# write-time error paths.
run_checkpoint_err() {
    local repo="$1" payload="$2" root="${3:-$1}"
    write_pointer "$root"
    # shellcheck disable=SC2016   # $1/$2/$3 are the inner bash -c's own positional params
    run --separate-stderr -2 bash -c 'cd "$1" && bash "$2" <<<"$3"' \
        _ "$repo" "$CHECKPOINT" "$payload"
}

task_write() { jq -nc --arg fp "$1" --arg c "$2" '{file_path:$fp, content:$c}'; }
todo_write() { jq -nc --arg fp "$1" --arg c "$2" '{file_path:$fp, content:$c}'; }

# ==========================================================================
# The session root — read from the pointer SessionStart published, not
# resolved here.
#
# The agent's Bash has no CLAUDE_PROJECT_DIR, so the old `handoff_root "$PWD"`
# fell back to cwd. When the session cwd leaves the launch repo that is
# silently wrong in exactly the way it matters: the checkpoint wrote and staged
# one repo's handoff files while the loaders kept reading the other's.
# ==========================================================================

@test "checkpoint: no root pointer -> refuses, naming the path it looked for" {
    repo="$(make_repo)"
    rm -rf "$HANDOFF_POINTER_DIR"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:null, todo:null}')
    # shellcheck disable=SC2016   # $1/$2/$3 are the inner bash -c's own positional params
    run --separate-stderr -2 bash -c 'cd "$1" && bash "$2" <<<"$3"' \
        _ "$repo" "$CHECKPOINT" "$payload"
    [[ "$stderr" == *"handoff-root-$CLAUDE_CODE_SESSION_ID"* ]]
}

@test "checkpoint: no session id -> refuses, naming the variable" {
    repo="$(make_repo)"
    write_pointer "$repo"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:null, todo:null}')
    # shellcheck disable=SC2016   # $1/$2/$3 are the inner bash -c's own positional params
    run --separate-stderr -2 bash -c 'cd "$1" && CLAUDE_CODE_SESSION_ID= bash "$2" <<<"$3"' \
        _ "$repo" "$CHECKPOINT" "$payload"
    [[ "$stderr" == *"CLAUDE_CODE_SESSION_ID"* ]]
}

# The load-bearing negative: cwd is a different repo from the published root,
# and nothing of the wrap-up may land in it. Both halves matter — writing the
# launch repo's file is only half the fix if cwd's is written too.
@test "checkpoint: drifted cwd -> writes the published root, never cwd's .claude/" {
    root="$(make_repo "$BATS_TEST_TMPDIR/launch")"
    elsewhere="$(make_repo "$BATS_TEST_TMPDIR/elsewhere")"
    payload=$(jq -nc --argjson task "$(task_write "$root/.claude/handoff-task.md" $'## Current task\n\nbody\n')" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:$task, todo:null}')
    run_checkpoint "$elsewhere" "$payload" "$root"
    [ "$status" -eq 0 ]
    [ -f "$root/.claude/handoff-task.md" ]
    [ -f "$root/.claude/checkpoint-manifest" ]
    [ ! -e "$elsewhere/.claude/handoff-task.md" ]
    [ ! -e "$elsewhere/.claude/checkpoint-manifest" ]
}

# The incident's own symptom, now inverted: the path under the launch root is
# the one that resolves, and the path under cwd is the schema violation.
@test "checkpoint: drifted cwd -> a task path under cwd is rejected" {
    root="$(make_repo "$BATS_TEST_TMPDIR/launch2")"
    elsewhere="$(make_repo "$BATS_TEST_TMPDIR/elsewhere2")"
    payload=$(jq -nc --argjson task "$(task_write "$elsewhere/.claude/handoff-task.md" "body")" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:$task, todo:null}')
    run_checkpoint_err "$elsewhere" "$payload" "$root"
    [[ "$stderr" == *"task.file_path"* ]]
    [ ! -e "$elsewhere/.claude/handoff-task.md" ]
}

# ==========================================================================
# Schema validation (FR2) — each asserts exit 2 and that stderr names the
# offending field.
# ==========================================================================

@test "checkpoint: skill missing -> error naming skill" {
    repo="$(make_repo)"
    payload=$(jq -nc '{commit:"with-commit", rename:"T", task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"skill"* ]]
}

@test "checkpoint: skill unknown value -> error naming skill" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"bogus", commit:"with-commit", rename:"T", task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"skill"* ]]
}

@test "checkpoint: commit missing -> error naming commit" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", rename:"T", clear:false, continue:null, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"commit"* ]]
}

@test "checkpoint: commit unknown value -> error naming commit" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"maybe", rename:"T", clear:false, continue:null, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"commit"* ]]
}

@test "checkpoint: rename missing under skill:handoff -> error naming rename" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", clear:false, continue:null, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"rename"* ]]
}

# Two values, one per boundary. Whether the transition is typed is a payload
# field now rather than a skill of its own, so the enum names the boundary and
# nothing else. What it still buys is the check that a `handoff` invocation
# which forgot its title is an error rather than a silent non-rename.
@test "checkpoint: each of the two skill values is accepted" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"precompact", commit:"without-commit", compact:false, continue:null, task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    payload=$(jq -nc '{skill:"handoff", commit:"without-commit", rename:"T", clear:false, continue:null, task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
}

# The names the two deleted skills used. A payload still carrying one is a stale
# skill body, and saying so beats composing a boundary nobody asked for.
@test "checkpoint: the retired driven-skill names are rejected" {
    repo="$(make_repo)"
    for s in handoff-continue compact-continue; do
        payload=$(jq -nc --arg s "$s" '{skill:$s, commit:"without-commit", clear:false, continue:null, task:null, todo:null}')
        run_checkpoint_err "$repo" "$payload"
        [[ "$stderr" == *"skill"* ]]
        [[ "$stderr" == *"$s"* ]]
    done
}

@test "checkpoint: rename present under precompact -> error naming rename and the skill" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"precompact", commit:"with-commit", rename:"Not Allowed", compact:false, continue:null, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"rename"* ]]
    [[ "$stderr" == *"precompact"* ]]
}

@test "checkpoint: precompact with rename omitted entirely -> accepted" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"precompact", commit:"without-commit", compact:false, continue:null, task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
}

@test "checkpoint: task with old_string/new_string -> error naming task (Write form only)" {
    repo="$(make_repo)"
    payload=$(jq -nc --arg fp "$repo/.claude/handoff-task.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null,
          task:{file_path:$fp, old_string:"a", new_string:"b"}, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"task"* ]]
}

@test "checkpoint: todo with content and old_string together -> error naming todo" {
    repo="$(make_repo)"
    payload=$(jq -nc --arg fp "$repo/.claude/handoff-todo.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:null,
          todo:{file_path:$fp, content:"## Remaining\n", old_string:"a"}}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"todo"* ]]
}

@test "checkpoint: todo with only old_string (no new_string) -> error naming todo" {
    repo="$(make_repo)"
    payload=$(jq -nc --arg fp "$repo/.claude/handoff-todo.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:null,
          todo:{file_path:$fp, old_string:"a"}}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"todo"* ]]
}

@test "checkpoint: todo with only new_string (no old_string) -> error naming todo" {
    repo="$(make_repo)"
    payload=$(jq -nc --arg fp "$repo/.claude/handoff-todo.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:null,
          todo:{file_path:$fp, new_string:"b"}}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"todo"* ]]
}

@test "checkpoint: task.file_path outside project .claude/ -> error naming task.file_path" {
    repo="$(make_repo)"
    payload=$(jq -nc --arg fp "$repo/elsewhere.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null,
          task:{file_path:$fp, content:"## Current task\n\nx\n"}, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"task.file_path"* ]]
}

@test "checkpoint: todo.file_path outside project .claude/ -> error naming todo.file_path" {
    repo="$(make_repo)"
    payload=$(jq -nc --arg fp "/tmp/not-the-project/.claude/handoff-todo.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:null,
          todo:{file_path:$fp, content:"## Remaining\n\n- x\n"}}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"todo.file_path"* ]]
}

@test "checkpoint: malformed JSON on stdin -> error naming payload" {
    repo="$(make_repo)"
    run_checkpoint_err "$repo" "{not valid json"
    [[ "$stderr" == *"payload"* ]]
}

# ==========================================================================
# {"content": null} is equivalent to the field being bare null (no-op) —
# guards against the literal string "null" being written to the file body.
# ==========================================================================

@test "checkpoint: task {content:null}, no file_path -> no-op, no file, no manifest line" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null,
        task:{content:null}, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ ! -e "$repo/.claude/handoff-task.md" ]
    run ! grep -q "handoff-task.md" "$repo/.claude/checkpoint-manifest"
}

@test "checkpoint: task {file_path, content:null} -> no-op, no file, no manifest line" {
    repo="$(make_repo)"
    payload=$(jq -nc --arg fp "$repo/.claude/handoff-task.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null,
          task:{file_path:$fp, content:null}, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ ! -e "$repo/.claude/handoff-task.md" ]
    run ! grep -q "handoff-task.md" "$repo/.claude/checkpoint-manifest"
}

@test "checkpoint: todo {content:null}, no file_path -> no-op, no file, no manifest line" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null,
        task:null, todo:{content:null}}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ ! -e "$repo/.claude/handoff-todo.md" ]
    run ! grep -q "handoff-todo.md" "$repo/.claude/checkpoint-manifest"
}

@test "checkpoint: todo {file_path, content:null} -> no-op, no file, no manifest line" {
    repo="$(make_repo)"
    payload=$(jq -nc --arg fp "$repo/.claude/handoff-todo.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:null,
          todo:{file_path:$fp, content:null}}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ ! -e "$repo/.claude/handoff-todo.md" ]
    run ! grep -q "handoff-todo.md" "$repo/.claude/checkpoint-manifest"
}

# ==========================================================================
# Write semantics (FR5) and empty-body removal (FR6)
# ==========================================================================

@test "checkpoint: task write -> file created with exact content, manifest records W" {
    repo="$(make_repo)"
    payload=$(jq -nc --arg fp "$repo/.claude/handoff-task.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null,
          task:{file_path:$fp, content:"## Current task\n\nreal content\n"}, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ -f "$repo/.claude/handoff-task.md" ]
    grep -q "real content" "$repo/.claude/handoff-task.md"
    grep -qx "W .claude/handoff-task.md" "$repo/.claude/checkpoint-manifest"
}

@test "checkpoint: task write with only headings -> file removed, manifest records D" {
    repo="$(make_repo)"
    payload=$(jq -nc --arg fp "$repo/.claude/handoff-task.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null,
          task:{file_path:$fp, content:"## Current task\n\n## Open decisions\n"}, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ ! -e "$repo/.claude/handoff-task.md" ]
    grep -qx "D .claude/handoff-task.md" "$repo/.claude/checkpoint-manifest"
}

@test "checkpoint: todo write -> file created, manifest records W" {
    repo="$(make_repo)"
    payload=$(jq -nc --arg fp "$repo/.claude/handoff-todo.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:null,
          todo:{file_path:$fp, content:"## Remaining\n\n- an item\n"}}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    grep -q "an item" "$repo/.claude/handoff-todo.md"
    grep -qx "W .claude/handoff-todo.md" "$repo/.claude/checkpoint-manifest"
}

@test "checkpoint: todo write with no items -> file removed, manifest records D" {
    repo="$(make_repo)"
    payload=$(jq -nc --arg fp "$repo/.claude/handoff-todo.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:null,
          todo:{file_path:$fp, content:"## Remaining\n"}}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ ! -e "$repo/.claude/handoff-todo.md" ]
    grep -qx "D .claude/handoff-todo.md" "$repo/.claude/checkpoint-manifest"
}

@test "checkpoint: todo edit replaces first occurrence, stages W" {
    repo="$(make_repo)"
    printf '## Remaining\n\n- finish A\n- finish B\n' > "$repo/.claude/handoff-todo.md"
    payload=$(jq -nc --arg fp "$repo/.claude/handoff-todo.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:null,
          todo:{file_path:$fp, old_string:"- finish A\n", new_string:""}}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    run ! grep -q "finish A" "$repo/.claude/handoff-todo.md"
    grep -q "finish B" "$repo/.claude/handoff-todo.md"
    grep -qx "W .claude/handoff-todo.md" "$repo/.claude/checkpoint-manifest"
}

@test "checkpoint: todo edit whose old_string is absent -> error naming old_string" {
    repo="$(make_repo)"
    printf '## Remaining\n\n- keep this\n' > "$repo/.claude/handoff-todo.md"
    payload=$(jq -nc --arg fp "$repo/.claude/handoff-todo.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:null,
          todo:{file_path:$fp, old_string:"- not present", new_string:"- x"}}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"old_string"* ]]
    [[ "$stderr" == *"not found"* ]]
    grep -q "keep this" "$repo/.claude/handoff-todo.md"
}

@test "checkpoint: todo edit whose old_string is ambiguous -> error naming old_string" {
    repo="$(make_repo)"
    printf '## Remaining\n\n- dup\n- dup\n' > "$repo/.claude/handoff-todo.md"
    payload=$(jq -nc --arg fp "$repo/.claude/handoff-todo.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:null,
          todo:{file_path:$fp, old_string:"- dup", new_string:"- single"}}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"old_string"* ]]
    [[ "$stderr" == *"ambiguous"* ]]
}

@test "checkpoint: todo edit requested but file does not exist -> error" {
    repo="$(make_repo)"
    payload=$(jq -nc --arg fp "$repo/.claude/handoff-todo.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:null,
          todo:{file_path:$fp, old_string:"a", new_string:"b"}}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"does not exist"* ]]
}

@test "checkpoint: todo null on a session that never touched it -> list left alone" {
    repo="$(make_repo)"
    printf '## Remaining\n\n- untouched\n' > "$repo/.claude/handoff-todo.md"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null, task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    grep -q "untouched" "$repo/.claude/handoff-todo.md"
}

# ==========================================================================
# Manifest (FR7) and rename (FR8)
# ==========================================================================

# The sentinel holds literal keystrokes, so the title becomes the argument of a
# /rename line under a kind line — the same file every other transition uses.
@test "checkpoint: rename only, no task/todo -> manifest present but empty, sentinel written" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"Two Words Title", clear:false, continue:null, task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ -f "$repo/.claude/checkpoint-manifest" ]
    [ ! -s "$repo/.claude/checkpoint-manifest" ]
    [ "$(cat "$repo/.claude/autodrive")" = "armed
rename
/rename Two Words Title" ]
    # And what it wrote is what the arming hook will accept.
    run handoff_drive_read "$repo/.claude/autodrive"
    [ "$status" -eq 0 ]
}

# A title carrying its own newline would make the line-oriented sentinel
# unreadable, so it is flattened at write time — there is no consumer left to do
# it. Whitespace-only is a schema error, not an empty rename.
@test "checkpoint: a multi-line title is flattened to one line" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"Two  Words\nAnd More", clear:false, continue:null, task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$repo/.claude/autodrive")" -eq 3 ]
    grep -qx '/rename Two Words And More' "$repo/.claude/autodrive"
}

@test "checkpoint: a whitespace-only title -> error naming rename" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"   ", clear:false, continue:null, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"rename"* ]]
}

@test "checkpoint: precompact, nothing touched -> manifest still written (empty)" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"precompact", commit:"without-commit", compact:false, continue:null, task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ -f "$repo/.claude/checkpoint-manifest" ]
    [ ! -s "$repo/.claude/checkpoint-manifest" ]
}

@test "checkpoint: task and todo both written -> manifest lists both" {
    repo="$(make_repo)"
    payload=$(jq -nc --arg tfp "$repo/.claude/handoff-task.md" --arg dfp "$repo/.claude/handoff-todo.md" \
        '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:null,
          task:{file_path:$tfp, content:"## Current task\n\nbody\n"},
          todo:{file_path:$dfp, content:"## Remaining\n\n- x\n"}}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    grep -qx "W .claude/handoff-task.md" "$repo/.claude/checkpoint-manifest"
    grep -qx "W .claude/handoff-todo.md" "$repo/.claude/checkpoint-manifest"
}

# ==========================================================================
# The transition (clear/compact) and the continuation
#
# Both fields are required, with no default: a default is the answer given by an
# agent that never considered the question, and considering it is the whole
# contribution. `false` does not mean "no sentinel" — it means the command is
# not typed.
# ==========================================================================

@test "checkpoint: clear missing under handoff -> error naming clear" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"T", continue:null, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"clear"* ]]
}

@test "checkpoint: clear not a boolean -> error naming clear" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"T", clear:"yes", continue:null, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"clear"* ]]
}

# Each boundary takes its own transition field, named after the command it
# types. The other one is a schema error rather than a silent ignore, for the
# same reason `rename` is: a field nobody reads is a decision nobody made.
@test "checkpoint: clear present under precompact -> error naming clear" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"precompact", commit:"with-commit", clear:true, compact:false, continue:null, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"clear"* ]]
}

@test "checkpoint: compact missing under precompact -> error naming compact" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"precompact", commit:"with-commit", continue:null, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"compact"* ]]
}

@test "checkpoint: compact present under handoff -> error naming compact" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, compact:true, continue:null, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"compact"* ]]
}

# /compact takes an optional focus directive, so the field is a bool or that
# directive. Anything else is neither.
@test "checkpoint: compact neither boolean nor string -> error naming compact" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"precompact", commit:"with-commit", compact:["focus"], continue:null, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"compact"* ]]
}

@test "checkpoint: an empty compact directive -> error naming compact" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"precompact", commit:"with-commit", compact:"", continue:null, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"compact"* ]]
}

@test "checkpoint: a multi-line compact directive -> error naming compact" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"precompact", commit:"with-commit", compact:"keep the parser\nand the tests", continue:null, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"compact"* ]]
}

@test "checkpoint: continue missing -> error naming continue, at either boundary" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"T", clear:true, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"continue"* ]]

    payload=$(jq -nc '{skill:"precompact", commit:"with-commit", compact:true, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"continue"* ]]
}

# Nothing would type it. A silent drop would lose a prompt the agent authored
# and reported nothing about.
@test "checkpoint: a continuation against an untyped transition -> error naming continue" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"T", clear:false, continue:"pick up per the task file", task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"continue"* ]]

    payload=$(jq -nc '{skill:"precompact", commit:"with-commit", compact:false, continue:"pick up per the task file", task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"continue"* ]]
}

# One Enter is one submit, so an embedded newline would submit the prompt early.
@test "checkpoint: a multi-line continuation -> error naming continue" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"T", clear:true, continue:"first line\nsecond line", task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"continue"* ]]
}

# The walker dispatches on the leading character: a prose line that looked like
# a command would be confirmed by the wrong primitive.
@test "checkpoint: a continuation beginning with / -> error naming continue" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"T", clear:true, continue:"/resume the work", task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"continue"* ]]
}

@test "checkpoint: a whitespace-only continuation -> error naming continue" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"T", clear:true, continue:"   ", task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"continue"* ]]
}

@test "checkpoint: continue neither null nor a string -> error naming continue" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"with-commit", rename:"T", clear:true, continue:true, task:null, todo:null}')
    run_checkpoint_err "$repo" "$payload"
    [[ "$stderr" == *"continue"* ]]
}

# --- the six legal combinations, each pinned to its exact sentinel ---
#
# The checkpoint composes the whole file, so these rows are the contract. Each
# also reads its own output back through handoff_drive_read: the composer and
# the parser are the two halves of one format, and nothing else would notice
# them drifting apart.

@test "checkpoint: handoff, clear:true, no continuation -> the clear kind, no prose line" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"without-commit", rename:"A Title", clear:true, continue:null, task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ "$(cat "$repo/.claude/autodrive")" = "armed
clear
/rename A Title
/clear" ]
    run handoff_drive_read "$repo/.claude/autodrive"
    [ "$status" -eq 0 ]
}

@test "checkpoint: handoff, clear:true with a continuation -> prose last" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"without-commit", rename:"A Title", clear:true, continue:"pick up per the task file", task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ "$(cat "$repo/.claude/autodrive")" = "armed
clear
/rename A Title
/clear
pick up per the task file" ]
    run handoff_drive_read "$repo/.claude/autodrive"
    [ "$status" -eq 0 ]
}

# FR-G: the kind line alone. Nothing is typed, and the file's whole effect is
# that the compaction is *expected* — which is what the frame's re-injection is
# gated on.
@test "checkpoint: precompact, compact:false -> the two-line expectation marker" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"precompact", commit:"without-commit", compact:false, continue:null, task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ "$(cat "$repo/.claude/autodrive")" = "armed
compact" ]
}

@test "checkpoint: precompact, compact:true, no continuation -> a bare /compact" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"precompact", commit:"without-commit", compact:true, continue:null, task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ "$(cat "$repo/.claude/autodrive")" = "armed
compact
/compact" ]
    run handoff_drive_read "$repo/.claude/autodrive"
    [ "$status" -eq 0 ]
}

@test "checkpoint: precompact, a focus directive and a continuation -> both carried" {
    repo="$(make_repo)"
    payload=$(jq -nc '{skill:"precompact", commit:"without-commit", compact:"keep the parser work", continue:"continue with task 3", task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ "$(cat "$repo/.claude/autodrive")" = "armed
compact
/compact keep the parser work
continue with task 3" ]
    run handoff_drive_read "$repo/.claude/autodrive"
    [ "$status" -eq 0 ]
}

# --- held versus armed ---
#
# The hazard is keystrokes reaching a pane whose turn is about to end on an
# approval question: a transition armed alongside that question clears or
# compacts away the very conversation the answer applies to. So a sentinel that
# types a transition waits in `held` while a memory gate is outstanding.
#
# The pair below is one fixture, one line apart: the same payload against dirty
# and clean memory. The composition rows above pin every other line.

@test "checkpoint: a typed transition with a memory gate pending -> held" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    payload=$(jq -nc '{skill:"handoff", commit:"without-commit", rename:"A Title", clear:true, continue:"pick up per the task file", task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$repo/.claude/autodrive")" = "held" ]
    echo "$output" | grep -qF 'handoff-approved'
}

@test "checkpoint: a typed transition with no memory gate -> armed, no arming instruction" {
    repo="$(make_gitlore_repo)"
    payload=$(jq -nc '{skill:"handoff", commit:"without-commit", rename:"A Title", clear:true, continue:"pick up per the task file", task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$repo/.claude/autodrive")" = "armed" ]
    [[ "$output" != *"handoff-approved"* ]]
}

# A sentinel that types nothing carries no such hazard, so both non-typing kinds
# keep today's behaviour exactly — and a prepare-only precompact cannot lose its
# FR-G marker to a memory gate it has no reason to wait on.
@test "checkpoint: the non-typing kinds arm even with a memory gate pending" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    payload=$(jq -nc '{skill:"handoff", commit:"without-commit", rename:"A Title", clear:false, continue:null, task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$repo/.claude/autodrive")" = "armed" ]

    payload=$(jq -nc '{skill:"precompact", commit:"without-commit", compact:false, continue:null, task:null, todo:null}')
    run_checkpoint "$repo" "$payload"
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$repo/.claude/autodrive")" = "armed" ]
}

# ==========================================================================
# bin/handoff-approved — the one command that leaves `held`
# ==========================================================================

# Run it with cwd = $1 and the published root = $2 (default $1). Invoked through
# its own path here; the bare-name row below is what covers the invocation path.
run_approved() {
    local repo="$1" root="${2:-$1}"
    write_pointer "$root"
    # shellcheck disable=SC2016   # $1/$2 are the inner bash -c's own positional params
    run --separate-stderr bash -c 'cd "$1" && bash "$2"' _ "$repo" "$APPROVED"
}

@test "handoff-approved: a held sentinel becomes armed, every line below preserved" {
    repo="$(make_repo)"
    printf '%s\n' held clear "/rename A Title" /clear "pick up per the task file" \
        > "$repo/.claude/autodrive"
    run_approved "$repo"
    [ "$status" -eq 0 ]
    [ "$(cat "$repo/.claude/autodrive")" = "armed
clear
/rename A Title
/clear
pick up per the task file" ]
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

@test "handoff-approved: no root pointer -> refuses, naming the path it looked for" {
    repo="$(make_repo)"
    rm -rf "$HANDOFF_POINTER_DIR"
    # shellcheck disable=SC2016   # $1/$2 are the inner bash -c's own positional params
    run --separate-stderr bash -c 'cd "$1" && bash "$2"' _ "$repo" "$APPROVED"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"handoff-root-$CLAUDE_CODE_SESSION_ID"* ]]
}

# The invocation path: the agent runs this by bare name off PATH, so a
# non-executable entry point is a failure every other row here would miss.
@test "handoff-approved: runs by bare name off PATH" {
    repo="$(make_repo)"
    printf '%s\n' held compact "/compact" > "$repo/.claude/autodrive"
    write_pointer "$repo"
    run bash -c 'cd "$1" && PATH="$2:$PATH" handoff-approved' _ "$repo" "$repo_root/bin"
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$repo/.claude/autodrive")" = "armed" ]
}

# ==========================================================================
# Memory directive (carried from tests/memory-probe.bats + precompact-probe.bats)
# ==========================================================================

handoff_payload() {
    jq -nc --arg commit "$1" '{skill:"handoff", commit:$commit, rename:"Session Title", clear:false, continue:null, task:null, todo:null}'
}

precompact_payload() {
    jq -nc --arg commit "$1" '{skill:"precompact", commit:$commit, compact:false, continue:null, task:null, todo:null}'
}

@test "checkpoint: not gitlore-managed -> silent" {
    plain="$(make_repo "$BATS_TEST_TMPDIR/plain")"
    run_checkpoint "$plain" "$(handoff_payload without-commit)"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "checkpoint: gitlore + clean memory -> silent" {
    repo="$(make_gitlore_repo)"
    run_checkpoint "$repo" "$(handoff_payload without-commit)"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "checkpoint: submodule registered but not materialized -> silent" {
    repo="$(make_gitlore_repo)"
    rm -rf "$repo/memory/.git"
    run_checkpoint "$repo" "$(handoff_payload without-commit)"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "checkpoint: dirty memory -> directive naming both IPC file paths" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run_checkpoint "$repo" "$(handoff_payload without-commit)"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'uncommitted changes'
    echo "$output" | grep -q 'feedback_x.md'
    echo "$output" | grep -qF "$repo/.claude/gitlore-memory-message"
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
}

# The clause is gitlore's, multi-line, and arbitrary in shape — so it is
# rendered as its own block rather than spliced into a sentence. `grep -qF`
# would pass on any single matching line; bash substring matching is what
# asserts the whole clause arrived contiguous, and the blank-line framing is
# what asserts it is a block.
@test "checkpoint: gitlore.memoryApprovalClauseFile resolved -> its content is a block of its own" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run_checkpoint "$repo" "$(handoff_payload without-commit)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$GITLORE_MEMORY_APPROVAL_CLAUSE"* ]]
    [[ "$output" == *$'\n\n'"$GITLORE_MEMORY_APPROVAL_CLAUSE"$'\n\n'* ]]
    # The title-length limit is handoff's, not the clause's: it survives.
    echo "$output" | grep -q '72 characters'
}

@test "checkpoint: gitlore.memoryApprovalClauseFile unset -> names the key and the restart, never the IPC instructions" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    git -C "$repo" config --unset gitlore.memoryApprovalClauseFile
    run_checkpoint "$repo" "$(handoff_payload without-commit)"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi 'gitlore.memoryApprovalClauseFile'
    echo "$output" | grep -qi 'restart'
    [[ "$output" != *"$repo/.claude/gitlore-memory-message"* ]]
    [[ "$output" != *"$repo/.claude/gitlore-commit-memory"* ]]
    [[ "$output" != *"two file writes"* ]]
}

@test "checkpoint: gitlore.memoryApprovalClauseFile points at a missing file -> same key-and-restart report" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    git -C "$repo" config gitlore.memoryApprovalClauseFile "$repo/.gitlore-memory-approval-clause-missing.txt"
    run_checkpoint "$repo" "$(handoff_payload without-commit)"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi 'gitlore.memoryApprovalClauseFile'
    echo "$output" | grep -qi 'restart'
    [[ "$output" != *"$repo/.claude/gitlore-memory-message"* ]]
}

# THE load-bearing assertion: the with-commit output never mentions the
# trigger — not its path, not the concept. Mutation-checked: temporarily
# deleting the with-commit branch in checkpoint_memory_directive (so the mode
# falls through to the without-commit text) must turn this red.
@test "checkpoint: with-commit -> summary write only, no mention of a trigger" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run_checkpoint "$repo" "$(handoff_payload with-commit)"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-memory-message"
    [[ "$output" != *"gitlore-commit-memory"* ]]
    [[ "$output" != *"trigger"* ]]
    [[ "$output" != *"two file writes"* ]]
}

@test "checkpoint: with-commit -> states the commit carries the memory" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run_checkpoint "$repo" "$(handoff_payload with-commit)"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "carries the memory"
}

@test "checkpoint: without-commit keeps the standalone two-file instruction" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run_checkpoint "$repo" "$(handoff_payload without-commit)"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF 'two file writes'
    echo "$output" | grep -qF 'Write the trigger file (any content)'
    [[ "$output" != *"carries the memory"* ]]
}

# ==========================================================================
# Composition: handoff (memory + todo boundary) vs precompact (memory +
# SDD nudge), and ledger liveness. Carried from both deleted probe suites.
# ==========================================================================

@test "checkpoint: handoff composition carries the todo boundary, not the SDD nudge" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    add_sdd_ledger "$repo"
    run_checkpoint "$repo" "$(handoff_payload without-commit)"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF '.superpowers/sdd/feature-plan/progress.md'
    echo "$output" | grep -qF 'handoff-todo.md'
    [[ "$output" != *"Minor findings"* ]]
    [[ "$output" != *"re-dispatched"* ]]
}

@test "checkpoint: precompact composition carries the SDD nudge, memory first" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    add_sdd_ledger "$repo"
    run_checkpoint "$repo" "$(precompact_payload without-commit)"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
    echo "$output" | grep -qF '.superpowers/sdd/feature-plan/progress.md'
    mem_line=$(echo "$output" | grep -nF 'gitlore-commit-memory' | head -1 | cut -d: -f1)
    sdd_line=$(echo "$output" | grep -nF '.superpowers/sdd/feature-plan/progress.md' | head -1 | cut -d: -f1)
    [ "$mem_line" -lt "$sdd_line" ]
}

# Boundary, not skill, decides what gets composed, so the two skills at each
# boundary cannot drift in what they tell the agent. Each row asserts both
# halves: the directive its boundary composes, and the absence of the other
# boundary's — a positive-only check passes on a hook that emits both.
@test "checkpoint: each boundary composes its own directive, not the other's" {
    for s in handoff precompact; do
        repo="$(make_gitlore_repo "$BATS_TEST_TMPDIR/bnd")"
        dirty_memory "$repo"
        add_sdd_ledger "$repo"
        if [ "$s" = handoff ]; then
            payload=$(jq -nc --arg s "$s" '{skill:$s, commit:"without-commit", rename:"T", clear:false, continue:null, task:null, todo:null}')
        else
            payload=$(jq -nc --arg s "$s" '{skill:$s, commit:"without-commit", compact:false, continue:null, task:null, todo:null}')
        fi
        run_checkpoint "$repo" "$payload"
        [ "$status" -eq 0 ]
        case "$s" in
            handoff)
                echo "$output" | grep -qF 'survives the /clear'
                [[ "$output" != *"re-dispatched"* ]] ;;
            precompact)
                echo "$output" | grep -qF 're-dispatched'
                [[ "$output" != *"survives the /clear"* ]] ;;
        esac
        # Memory first at both boundaries — the composition order the two
        # deleted probes used, unchanged (FR9).
        mem=$(echo "$output" | grep -nF 'gitlore-memory-message' | head -1 | cut -d: -f1)
        led=$(echo "$output" | grep -nF '.superpowers/sdd/feature-plan/progress.md' | head -1 | cut -d: -f1)
        [ "$mem" -lt "$led" ]
    done
}

# The ledger and the todo file are different scopes, not two copies of one list.
# The ledger holds the tasks of the plan being executed; handoff-todo.md holds
# work that outlives the session and belongs to no plan. Only the overlap — the
# plan's own tasks, copied across — can drift, so only the overlap is excluded.
# Standing the whole file down instead discards every item the ledger will never
# carry, which is most of them.
#
# The retired claim is the load-bearing negative: neither boundary may tell the
# agent that handoff-todo.md must not exist alongside a ledger.
@test "checkpoint: a live ledger scopes the todo file rather than standing it down" {
    for s in handoff precompact; do
        repo="$(make_gitlore_repo "$BATS_TEST_TMPDIR/scope")"
        add_sdd_ledger "$repo"
        if [ "$s" = handoff ]; then
            payload="$(handoff_payload without-commit)"
        else
            payload="$(precompact_payload without-commit)"
        fi
        run_checkpoint "$repo" "$payload"
        [ "$status" -eq 0 ]
        echo "$output" | grep -qF '.claude/handoff-todo.md'
        echo "$output" | grep -qF 'outside the plan'
        [[ "$output" != *"must not exist"* ]]
    done
}

@test "checkpoint: precompact, no ledger -> memory directive only, no SDD nudge" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    run_checkpoint "$repo" "$(precompact_payload without-commit)"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-memory-message"
    [[ "$output" != *".superpowers/sdd/feature-plan/progress.md"* ]]
}

@test "checkpoint: flat-path stray does not suppress the todo file" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    add_flat_sdd_ledger "$repo"
    run_checkpoint "$repo" "$(handoff_payload without-commit)"
    [ "$status" -eq 0 ]
    [[ "$output" != *"handoff-todo.md"* ]]
}

@test "checkpoint: workspace file without an identity line does not suppress the todo file" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    add_unidentified_sdd_ledger "$repo"
    run_checkpoint "$repo" "$(handoff_payload without-commit)"
    [ "$status" -eq 0 ]
    [[ "$output" != *"handoff-todo.md"* ]]
}

@test "checkpoint: flat-path ledger alone (precompact) -> silent" {
    repo="$BATS_TEST_TMPDIR/sddflat"; mkdir -p "$repo/.claude"
    git -C "$repo" init -q
    add_flat_sdd_ledger "$repo"
    run_checkpoint "$repo" "$(precompact_payload without-commit)"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "checkpoint: several live workspaces -> most recently modified wins" {
    i=0
    for pair in a-live:z-stale z-live:a-stale; do
        i=$((i + 1))
        live="${pair%%:*}"; stale="${pair##*:}"
        repo="$BATS_TEST_TMPDIR/sddmulti$i"; mkdir -p "$repo/.claude"
        git -C "$repo" init -q
        add_sdd_ledger "$repo" "$stale"
        add_sdd_ledger "$repo" "$live"
        touch -t 202601010000 "$repo/.superpowers/sdd/$stale/progress.md"
        run_checkpoint "$repo" "$(precompact_payload without-commit)"
        [ "$status" -eq 0 ]
        echo "$output" | grep -qF ".superpowers/sdd/$live/progress.md"
        [[ "$output" != *"$stale"* ]]
    done
}

# ==========================================================================
# shim (bin/handoff-checkpoint)
# ==========================================================================

@test "shim: bin/handoff-checkpoint execs the checkpoint, forwards stdin" {
    repo="$(make_gitlore_repo)"
    dirty_memory "$repo"
    write_pointer "$repo"
    run bash -c 'cd "$1" && "$2" <<<"$3"' \
        _ "$repo" "$SHIM" "$(handoff_payload without-commit)"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/.claude/gitlore-commit-memory"
}

@test "shim: bin/handoff-checkpoint surfaces a schema violation" {
    repo="$(make_repo)"
    write_pointer "$repo"
    # shellcheck disable=SC2016   # $1/$2/$3 are the inner bash -c's own positional params
    run --separate-stderr -2 bash -c 'cd "$1" && "$2" <<<"$3"' \
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
