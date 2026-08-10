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

    # The session-keyed pointer and drift marker live at a literal path
    # (/tmp/claude) so a hook and the agent's Bash can address them without
    # sharing an environment. Redirect it, or the suite writes into the
    # runner's own real one.
    export HANDOFF_POINTER_DIR="$BATS_TEST_TMPDIR/pointer"
    export SESSION_ID="sess-hook-test"

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

# --- _lib.sh: handoff_root_read branch labels ---
#
# The root alone collapses four different situations into one answer. The
# branch label is what separates "cwd is still in the launch repo" from "cwd
# has left it", which is the whole drift signal. It reaches the caller as a
# global rather than on stdout, in the handoff_drive_read idiom: every printing
# caller runs handoff_root in a command substitution, where a global set inside
# the subshell would not survive.

@test "handoff_root_read: worktree cwd -> branch worktree" {
    wt="$(make_worktree wtBR)"
    handoff_root_read "$wt"
    [ "$HANDOFF_ROOT" = "$wt" ]
    [ "$HANDOFF_ROOT_BRANCH" = "worktree" ]
}

@test "handoff_root_read: cwd in another repo -> branch foreign" {
    mkdir -p "$other/.git"
    handoff_root_read "$other"
    [ "$HANDOFF_ROOT" = "$tmp" ]
    [ "$HANDOFF_ROOT_BRANCH" = "foreign" ]
}

@test "handoff_root_read: cwd in no repo at all -> branch unrelated" {
    handoff_root_read "$other"
    [ "$HANDOFF_ROOT" = "$tmp" ]
    [ "$HANDOFF_ROOT_BRANCH" = "unrelated" ]
}

# The fast path returns without spawning python3, so it has to label the branch
# itself or a caller reads whatever the previous resolution left behind.
@test "handoff_root_read: project root and empty cwd -> branch inside, no python3" {
    run bash -c '
        stub="$1/nopy-branch"; mkdir -p "$stub"
        printf "#!/usr/bin/env bash\nexit 97\n" > "$stub/python3"
        chmod +x "$stub/python3"
        PATH="$stub:$PATH"
        source "$2/scripts/_lib.sh"
        HANDOFF_ROOT_BRANCH=stale; handoff_root_read "$3"
        printf "%s\n%s\n" "$HANDOFF_ROOT" "$HANDOFF_ROOT_BRANCH"
        HANDOFF_ROOT_BRANCH=stale; handoff_root_read ""
        printf "%s\n" "$HANDOFF_ROOT_BRANCH"
    ' _ "$BATS_TEST_TMPDIR" "$repo_root" "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "$tmp
inside
inside" ]
}

@test "handoff_root_read: subdirectory of the project -> branch inside" {
    mkdir -p "$tmp/scripts"
    handoff_root_read "$tmp/scripts"
    [ "$HANDOFF_ROOT" = "$tmp" ]
    [ "$HANDOFF_ROOT_BRANCH" = "inside" ]
}

# handoff_root itself keeps its contract: the root alone on stdout, one line.
@test "handoff_root: prints the root alone, not the branch" {
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
    read_drive "armed" "rename" "/rename Driven Transitions"
    [ "$DRIVE_STATE" = armed ]
    [ "$DRIVE_KIND" = rename ]
    [ "${#DRIVE_BEFORE[@]}" -eq 1 ]
    [ "${DRIVE_BEFORE[0]}" = "/rename Driven Transitions" ]
    [ "${#DRIVE_AFTER[@]}" -eq 0 ]
}

@test "handoff_drive_read (compact): command before, prose after" {
    read_drive "armed" "compact" "/compact focus on the parser" "continue with task 3"
    [ "$DRIVE_KIND" = compact ]
    [ "${DRIVE_BEFORE[0]}" = "/compact focus on the parser" ]
    [ "${DRIVE_AFTER[0]}" = "continue with task 3" ]
}

@test "handoff_drive_read (compact, bare command): accepted, /compact takes no argument" {
    read_drive "armed" "compact" "/compact" "continue with task 3"
    [ "${DRIVE_BEFORE[0]}" = "/compact" ]
}

# FR-G: the kind line alone. Nothing is typed, but the transition is expected,
# and that expectation is what the frame's re-injection is gated on.
@test "handoff_drive_read (compact, kind line alone): legal, both sequences empty" {
    read_drive "armed" "compact"
    [ "$DRIVE_KIND" = compact ]
    [ "${#DRIVE_BEFORE[@]}" -eq 0 ]
    [ "${#DRIVE_AFTER[@]}" -eq 0 ]
}

@test "handoff_drive_read (clear): two before-lines in order, prose after" {
    read_drive "armed" "clear" "/rename A Title" "/clear" "pick up per the task file"
    [ "$DRIVE_KIND" = clear ]
    [ "${#DRIVE_BEFORE[@]}" -eq 2 ]
    [ "${DRIVE_BEFORE[0]}" = "/rename A Title" ]
    [ "${DRIVE_BEFORE[1]}" = "/clear" ]
    [ "${DRIVE_AFTER[0]}" = "pick up per the task file" ]
}

# The continuation is optional on both driven kinds: driving a transition and
# submitting a prompt into what it opens are separate decisions, and the cross
# product is what the two payload fields express.
@test "handoff_drive_read (clear, no continuation): typed, nothing submitted after" {
    read_drive "armed" "clear" "/rename A Title" "/clear"
    [ "$DRIVE_KIND" = clear ]
    [ "${#DRIVE_BEFORE[@]}" -eq 2 ]
    [ "${DRIVE_BEFORE[1]}" = "/clear" ]
    [ "${#DRIVE_AFTER[@]}" -eq 0 ]
}

@test "handoff_drive_read (compact, no continuation): typed, nothing submitted after" {
    read_drive "armed" "compact" "/compact focus on the parser"
    [ "$DRIVE_KIND" = compact ]
    [ "${DRIVE_BEFORE[0]}" = "/compact focus on the parser" ]
    [ "${#DRIVE_AFTER[@]}" -eq 0 ]
}

# restart's shape mirrors clear's exactly (4 or 5 lines, two required
# before-lines, one optional prose after) — only the literal commands differ.
@test "handoff_drive_read (restart): two before-lines in order, prose after" {
    read_drive "armed" "restart" "/exit" "claude --resume sess-42" "pick up per the task file"
    [ "$DRIVE_KIND" = restart ]
    [ "${#DRIVE_BEFORE[@]}" -eq 2 ]
    [ "${DRIVE_BEFORE[0]}" = "/exit" ]
    [ "${DRIVE_BEFORE[1]}" = "claude --resume sess-42" ]
    [ "${DRIVE_AFTER[0]}" = "pick up per the task file" ]
}

@test "handoff_drive_read (restart, no continuation): typed, nothing submitted after" {
    read_drive "armed" "restart" "/exit" "claude --resume sess-42"
    [ "$DRIVE_KIND" = restart ]
    [ "${#DRIVE_BEFORE[@]}" -eq 2 ]
    [ "${DRIVE_BEFORE[1]}" = "claude --resume sess-42" ]
    [ "${#DRIVE_AFTER[@]}" -eq 0 ]
}

@test "handoff_drive_read (restart, /exit with an argument): rejected" {
    run read_drive "armed" "restart" "/exit now" "claude --resume sess-42"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exactly"* ]]
}

@test "handoff_drive_read (restart, resume line with no session id): rejected" {
    run read_drive "armed" "restart" "/exit" "claude --resume"
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-empty argument"* ]]
}

@test "handoff_drive_read (restart, wrong line count): rejected, naming the count" {
    run read_drive "armed" "restart" "/exit"
    [ "$status" -ne 0 ]
    [[ "$output" == *"4 or 5 lines"* ]]
}

# The state a Stop has already consumed. The parser does not know which caller
# wants which state — it reports the value and the gates decide.
@test "handoff_drive_read (pending): parsed like any other state" {
    read_drive "pending" "clear" "/rename A Title" "/clear" "pick up per the task file"
    [ "$DRIVE_STATE" = pending ]
    [ "$DRIVE_KIND" = clear ]
    [ "${DRIVE_AFTER[0]}" = "pick up per the task file" ]
}

@test "handoff_drive_read (unknown kind): rejected, naming the kinds" {
    run read_drive "armed" "reboot" "/reboot"
    [ "$status" -ne 0 ]
    [[ "$output" == *"transition kind"* ]]
}

# The state a memory approval holds a typing transition in, so the keystrokes
# do not reach a pane whose turn is about to end on the approval question.
#
# Alone among the states it names its owner: the session whose approval it waits
# on. Every other state is this turn's or the walker's, and both are reached
# from the session that wrote them; `held` is the one that outlives a turn
# boundary on purpose, so it is the one that has to say whose boundary.
@test "handoff_drive_read (held): parsed like any other state, and names its owner" {
    read_drive "held sess-42" "clear" "/rename A Title" "/clear" "pick up per the task file"
    [ "$DRIVE_STATE" = held ]
    [ "$DRIVE_OWNER" = sess-42 ]
    [ "$DRIVE_KIND" = clear ]
    [ "${DRIVE_AFTER[0]}" = "pick up per the task file" ]
}

# An unowned `held` names no session, so nothing can tell whose approval it
# waits on — which is exactly the file the sweep and handoff-approved must be
# able to reject.
@test "handoff_drive_read (held with no owner): rejected, naming the owner" {
    run read_drive "held" "clear" "/rename A Title" "/clear" "resume"
    [ "$status" -ne 0 ]
    [[ "$output" == *"session"* ]]
}

# Rejected as an owned state, not as an unknown one: `armed` is a state this
# parser knows, and the reason has to name what is actually wrong with the line,
# or the same message covers a typo and this.
@test "handoff_drive_read (owner on a state that takes none): rejected" {
    run read_drive "armed sess-42" "clear" "/rename A Title" "/clear" "resume"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no session"* ]]
}

# The other states carry no owner. Read a held file first: the owner must be
# cleared by the next read, or a caller comparing it acts on the previous file's
# session — which is the whole discriminator.
@test "handoff_drive_read (armed after held): no owner carried over" {
    read_drive "held sess-42" "clear" "/rename A Title" "/clear"
    [ "$DRIVE_OWNER" = sess-42 ]
    read_drive "armed" "clear" "/rename A Title" "/clear"
    [ "$DRIVE_STATE" = armed ]
    [ "$DRIVE_OWNER" = "" ]
}

@test "handoff_drive_read (unknown state): rejected, naming the states" {
    run read_drive "queued" "clear" "/rename A Title" "/clear" "resume"
    [ "$status" -ne 0 ]
    [[ "$output" == *"transition state"* ]]
    [[ "$output" == *"queued"* ]]
}

# The state line alone. It says which state, but there is no transition for it
# to be the state of.
@test "handoff_drive_read (state line alone): rejected, naming the missing kind" {
    run read_drive "armed"
    [ "$status" -ne 0 ]
    [[ "$output" == *"transition kind"* ]]
}

# The old autorename shape, and the shape this pass replaces. Neither has a
# state line, so both fail on line 1 rather than on anything below it.
@test "handoff_drive_read (bare title, the old autorename shape): rejected" {
    run read_drive "Some Session Title"
    [ "$status" -ne 0 ]
}

@test "handoff_drive_read (a pre-state-line sentinel): rejected on line 1" {
    run read_drive "clear" "/rename A Title" "/clear" "resume"
    [ "$status" -ne 0 ]
    [[ "$output" == *"transition state"* ]]
}

@test "handoff_drive_read (empty file): rejected" {
    run read_drive ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"transition state"* ]]
}

@test "handoff_drive_read (wrong line count for the kind): rejected, naming the count" {
    run read_drive "armed" "rename" "/rename A Title" "extra line"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exactly 3 lines"* ]]

    run read_drive "armed" "clear" "/rename A Title"
    [ "$status" -ne 0 ]
    [[ "$output" == *"4 or 5 lines"* ]]

    run read_drive "armed" "compact" "/compact" "continue" "extra"
    [ "$status" -ne 0 ]
    [[ "$output" == *"2, 3 or 4 lines"* ]]
}

@test "handoff_drive_read (command literal not in the kind's slot): rejected" {
    run read_drive "armed" "clear" "/clear" "/rename A Title" "resume"
    [ "$status" -ne 0 ]
    [[ "$output" == *"line 3"* ]]

    run read_drive "armed" "compact" "compact now" "continue"
    [ "$status" -ne 0 ]
    [[ "$output" == *"/compact"* ]]
}

@test "handoff_drive_read (/rename with no argument): rejected" {
    run read_drive "armed" "rename" "/rename"
    [ "$status" -ne 0 ]
    [[ "$output" == *"non-empty argument"* ]]

    run read_drive "armed" "rename" "/rename    "
    [ "$status" -ne 0 ]
}

@test "handoff_drive_read (/clear with an argument): rejected" {
    run read_drive "armed" "clear" "/rename A Title" "/clear now" "resume"
    [ "$status" -ne 0 ]
    [[ "$output" == *"exactly"* ]]
}

@test "handoff_drive_read (empty continuation prompt): rejected" {
    run read_drive "armed" "compact" "/compact" ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not be empty"* ]]
}

# The walker dispatches on the leading character: a `/` line takes the
# recognition path and is confirmed by a command primitive, prose takes the
# direct path. A prose line that looks like a command would be confirmed by the
# wrong one.
@test "handoff_drive_read (continuation prompt beginning with /): rejected" {
    run read_drive "armed" "clear" "/rename A Title" "/clear" "/resume the work"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not begin"* ]]
}

# --- _lib.sh: handoff_drive_arm ---

# Everything below line 1 is copied through untouched: the arm never has to know
# the kind's shape, which is what lets one helper serve Stop and, in the next
# pass, handoff-approved.
@test "handoff_drive_arm (rewrites line 1, preserves every line below)" {
    printf '%s\n' "armed" "clear" "/rename A Title" "/clear" "pick up per the task file" \
        > "$BATS_TEST_TMPDIR/sentinel"
    handoff_drive_arm "$BATS_TEST_TMPDIR/sentinel" pending
    [ "$(cat "$BATS_TEST_TMPDIR/sentinel")" = "pending
clear
/rename A Title
/clear
pick up per the task file" ]
}

# The FR-G marker is two lines, so the tail below line 1 is a single line.
@test "handoff_drive_arm (two-line file: still just the state line)" {
    printf '%s\n' "armed" "compact" > "$BATS_TEST_TMPDIR/sentinel"
    handoff_drive_arm "$BATS_TEST_TMPDIR/sentinel" pending
    [ "$(cat "$BATS_TEST_TMPDIR/sentinel")" = "pending
compact" ]
}

# Leaving `held` drops the owner with it: the owner answers "whose approval is
# outstanding", and past the approval there is none. Every state below `held`
# takes no owner, so carrying it through would compose a file the parser rejects.
@test "handoff_drive_arm (leaving held: the owner goes with the state)" {
    printf '%s\n' "held sess-42" "clear" "/rename A Title" "/clear" \
        > "$BATS_TEST_TMPDIR/sentinel"
    handoff_drive_arm "$BATS_TEST_TMPDIR/sentinel" armed
    [ "$(head -n1 "$BATS_TEST_TMPDIR/sentinel")" = "armed" ]
    handoff_drive_read "$BATS_TEST_TMPDIR/sentinel"
    [ "$DRIVE_STATE" = armed ]
    [ "$DRIVE_OWNER" = "" ]
}

# Readers exist concurrently — both loaders and Stop parse this file, and the
# walker stats it — so a half-written file must never be observable under the
# real name. The temp lands beside it and is renamed over it.
@test "handoff_drive_arm (leaves no temp file behind)" {
    printf '%s\n' "armed" "compact" "/compact" "continue" > "$BATS_TEST_TMPDIR/sentinel"
    handoff_drive_arm "$BATS_TEST_TMPDIR/sentinel" pending
    [ "$(find "$BATS_TEST_TMPDIR" -maxdepth 1 -name 'sentinel*' | wc -l)" -eq 1 ]
}

# --- _lib.sh: handoff_resume_command ---

# HANDOFF_TEST_CMDLINE_PATH substitutes a fixture file for /proc/<pid>/cmdline
# — /proc itself cannot be faked. Round-trip the output back through a shell
# to check the CONTRACT ("survives being retyped") rather than the exact
# quoting bash's %q happens to choose.
resplit() {
    bash -c 'eval "set -- $1"; printf "%s\n" "$@"' _ "$1"
}

@test "handoff_resume_command (argv[0] and every flag replayed, --resume appended)" {
    printf 'claude\0--plugin-dir\0/foo\0' > "$BATS_TEST_TMPDIR/cmdline"
    HANDOFF_TEST_CMDLINE_PATH="$BATS_TEST_TMPDIR/cmdline" \
        run handoff_resume_command "" "sess-99"
    [ "$status" -eq 0 ]
    got="$(resplit "$output")"
    [ "$got" = "claude
--plugin-dir
/foo
--resume
sess-99" ]
}

# A value containing a space (a --plugin-dir path, say) must survive as ONE
# argument once retyped, not split into two.
@test "handoff_resume_command (an argument containing a space survives whole)" {
    printf 'claude\0--plugin-dir\0/a path/with space\0' > "$BATS_TEST_TMPDIR/cmdline"
    HANDOFF_TEST_CMDLINE_PATH="$BATS_TEST_TMPDIR/cmdline" \
        run handoff_resume_command "" "sess-99"
    [ "$status" -eq 0 ]
    got="$(resplit "$output")"
    [ "$got" = "claude
--plugin-dir
/a path/with space
--resume
sess-99" ]
}

@test "handoff_resume_command (no cmdline source readable: bare resume, still succeeds)" {
    HANDOFF_TEST_CMDLINE_PATH="$BATS_TEST_TMPDIR/nope" PATH="" \
        run handoff_resume_command "" "sess-99"
    [ "$status" -eq 0 ]
    [ "$output" = "claude --resume sess-99" ]
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
# "nothing pending" while still present. Shares is_empty_body with
# checkpoint.py (tests/test_checkpoint.py) via _checkpoint_lib.py's
# --is-empty-body CLI, so the two writers cannot drift.
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

# autodrive is the guard's second (basename, rel) pair. It is composed by
# handoff-checkpoint, which reads its own output back through the parser, so a
# direct agent write is denied on the same ground as handoff-task.md — and the
# arm-only rule dies with the channel it lived in.
@test "write-guard (autodrive: deny a Write, checkpoint-only)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/.claude/autodrive" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-guard.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason
        | test("autodrive") and test("checkpoint")' >/dev/null
}

@test "write-guard (autodrive: deny an Edit too)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/.claude/autodrive" \
            "{cwd:\$cwd, tool_name:\"Edit\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-guard.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
}

# MATCHED_NAME is what lets one deny name the file that matched; with two pairs,
# a cross-project autodrive that reported handoff-task.md would send the agent
# to the wrong file.
@test "write-guard (cross-project autodrive: deny naming autodrive)" {
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$2/.claude/autodrive" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-guard.sh
    ' _ "$tmp" "$other"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason
        | test("autodrive")' >/dev/null
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

# The same file in state `pending`: a transition Stop has already armed, waiting
# on the SessionStart that confirms it.
seed_pending() {
    local dir="$1"; shift
    printf '%s\n' "pending" "$@" > "$dir/.claude/autodrive"
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
    [ ! -e "$tmp/.claude/autodrive" ]
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
    [ ! -e "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.systemMessage | test("resume anyway")' >/dev/null
    echo "$output" | jq -e 'has("hookSpecificOutput") | not' >/dev/null
}

# A driven clear with no continuation: the `/clear` was typed by the walker at
# Stop, and there is nothing to submit into the session it opened. The pending
# file is still this loader's to consume — it is what confirms the `/clear`
# landed — and the frame still goes out.
@test "load-handoff (clear, pending with no continuation: consumed, frame only)" {
    seed_pending "$tmp" "clear" "/rename A Title" "/clear"
    run_load_handoff "$tmp" clear 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("hook smoke test")' >/dev/null
    echo "$output" | jq -e '.systemMessage | test("resume") | not' >/dev/null
    # Without the widened shape this row passes for the wrong reason: the
    # sentinel fails to parse, and the malformed branch also consumes the file
    # and says nothing about resuming.
    echo "$output" | jq -e '.systemMessage | test("malformed") | not' >/dev/null
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
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "pending" ]
    [ "$(sed -n 2p "$tmp/.claude/autodrive")" = "compact" ]
}

@test "load-handoff (startup with a pending present: does not consume it)" {
    seed_pending "$tmp" "clear" "/rename A Title" "/clear" "pick up per the task file"
    run_load_handoff "$tmp" startup 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ -f "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.systemMessage | test("pick up") | not' >/dev/null
}

@test "load-handoff (clear, not in tmux: emits the after-line to paste)" {
    seed_pending "$tmp" "clear" "/rename A Title" "/clear" "pick up per the task file"
    run_load_handoff "$tmp" clear 'env -u TMUX -u TMUX_PANE'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("pick up per the task file")' >/dev/null
}

@test "load-handoff (clear, malformed pending: discarded, reported, not armed)" {
    seed_pending "$tmp" "clear" "/rename A Title" "not a clear" "resume"
    run_load_handoff "$tmp" clear 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.systemMessage | test("malformed")' >/dev/null
}

# Each loader consumes only a transition in flight. An armed file belongs to a
# Stop that has not fired — the agent wrote it and the turn ended on an Esc, so
# the sweep is what deals with it, not this.
@test "load-handoff (clear, armed file: not consumed, left for the sweep)" {
    seed_drive "$tmp" "clear" "/rename A Title" "/clear" "pick up per the task file"
    run_load_handoff "$tmp" clear 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "armed" ]
    echo "$output" | jq -e '.systemMessage | test("pick up") | not' >/dev/null
}

# Seed .claude/autodrive under $1 in state `armed` — what the checkpoint, the
# file's one writer, leaves behind — with the remaining args as the lines below.
seed_drive() {
    local dir="$1"; shift
    printf '%s\n' "armed" "$@" > "$dir/.claude/autodrive"
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

@test "stop-drive (kind with a confirming source: rewrites to pending, reports armed)" {
    seed_drive "$tmp" "compact" "/compact keep the parser work" "continue with task 3"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "pending" ]
    echo "$output" | jq -e '.systemMessage | test("/compact keep the parser work")' >/dev/null
}

@test "stop-drive (kind restart: confirming source too, rewrites to pending)" {
    seed_drive "$tmp" "restart" "/exit" "claude --resume sess-hook-test"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "pending" ]
    echo "$output" | jq -e '.systemMessage | test("/exit")' >/dev/null
}

# The checkpoint composed only the session id (it cannot see this process's
# own argv); stop-drive.sh fills in the rest right before the line would be
# typed or pasted. The not-in-tmux path prints the paste text synchronously,
# so it is the direct seam to assert the composed line against — no detached
# process or timing involved.
@test "stop-drive (kind restart, not in tmux: pastes the full resume command)" {
    printf 'claude\0--plugin-dir\0/foo\0' > "$BATS_TEST_TMPDIR/cmdline"
    seed_drive "$tmp" "restart" "/exit" "claude --resume sess-hook-test"
    run_stop_drive "$tmp" \
        "HANDOFF_TEST_CMDLINE_PATH=$BATS_TEST_TMPDIR/cmdline env -u TMUX -u TMUX_PANE"
    [ "$status" -eq 0 ]
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    echo "$ctx" | grep -q '^/exit$'
    echo "$ctx" | grep -q -- '--plugin-dir /foo --resume sess-hook-test$'
}

@test "stop-drive (kind restart: clears a stale exited marker before proceeding)" {
    : > "$tmp/.claude/autodrive.exited"
    seed_drive "$tmp" "restart" "/exit" "claude --resume sess-hook-test"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive.exited" ]
}

# `rename` has no loader, so nothing would ever clear a pending armed for it.
@test "stop-drive (kind rename: deletes the sentinel outright)" {
    seed_drive "$tmp" "rename" "/rename Driven Transitions"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
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
# pending file alone is the whole effect, and it is what SessionStart(compact)
# gates the frame re-injection on.
@test "stop-drive (empty before-sequence: leaves it pending, spawns nothing)" {
    seed_drive "$tmp" "compact"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "pending" ]
    echo "$output" | jq -e '.systemMessage | test("nothing to type")' >/dev/null
}

@test "stop-drive (not in tmux: emits every line to paste, in order, clears pending)" {
    seed_drive "$tmp" "clear" "/rename A Title" "/clear" "pick up per the task file"
    run_stop_drive "$tmp" 'env -u TMUX -u TMUX_PANE'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
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
    echo "$output" | jq -e '.systemMessage | test("malformed")' >/dev/null
}

@test "stop-drive (worktree cwd: arms the worktree file)" {
    wt="$(make_worktree wtS)"
    seed_drive "$wt" "compact" "/compact" "continue with task 3"
    run_stop_drive "$wt" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$wt/.claude/autodrive")" = "pending" ]
}

# The consume-before-spawn guarantee, stated directly. A pending file is a
# transition already in flight — its confirming SessionStart has not fired yet —
# and a Stop in the window between the two must not retype the sequence. That
# window is real: the walker submits its lines as ordinary prompts, and each one
# ends a turn.
@test "stop-drive (pending file: ignored, left untouched)" {
    seed_pending "$tmp" "compact" "/compact" "continue with task 3"
    run_stop_drive "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "pending" ]
}

# --- session-end (SessionEnd: confirm /exit for a restart in flight) ---

run_session_end() {
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, hook_event_name:\"SessionEnd\", reason:\"other\"}" \
        | bash scripts/session-end.sh
    ' _ "$1"
}

@test "session-end (no autodrive: silent no-op)" {
    run_session_end "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ ! -e "$tmp/.claude/autodrive.exited" ]
}

@test "session-end (armed, not pending yet: silent, nothing written)" {
    seed_drive "$tmp" "restart" "/exit" "claude --resume sess-hook-test"
    run_session_end "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ ! -e "$tmp/.claude/autodrive.exited" ]
}

@test "session-end (pending of a different kind: left alone, not written)" {
    seed_pending "$tmp" "compact" "/compact" "continue with task 3"
    run_session_end "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ ! -e "$tmp/.claude/autodrive.exited" ]
}

@test "session-end (pending restart: writes the exited marker)" {
    seed_pending "$tmp" "restart" "/exit" "claude --resume sess-hook-test"
    run_session_end "$tmp"
    [ "$status" -eq 0 ]
    [ -e "$tmp/.claude/autodrive.exited" ]
}

@test "session-end (worktree cwd: writes the worktree's own marker)" {
    wt="$(make_worktree wtE)"
    seed_pending "$wt" "restart" "/exit" "claude --resume sess-hook-test"
    run_session_end "$wt"
    [ "$status" -eq 0 ]
    [ -e "$wt/.claude/autodrive.exited" ]
    [ ! -e "$tmp/.claude/autodrive.exited" ]
}

@test "hooks.json dispatches SessionEnd to session-end.sh" {
    run jq -e '.hooks.SessionEnd[0].hooks[0].command | test("session-end.sh")' \
        "$repo_root/hooks/hooks.json"
    [ "$status" -eq 0 ]
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
    [ ! -e "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.systemMessage | test("continue with task 3")' >/dev/null
}

@test "load-compact (pending of kind clear: left for SessionStart(clear))" {
    seed_pending "$tmp" "clear" "/rename A Title" "/clear" "pick up per the task file"
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "pending" ]
    [ "$(sed -n 2p "$tmp/.claude/autodrive")" = "clear" ]
}

@test "load-compact (not in tmux: emits continuation to paste, clears pending)" {
    seed_pending "$tmp" "compact" "/compact" "continue with task 3"
    run_load_compact "$tmp" 'env -u TMUX -u TMUX_PANE'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
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

# A driven compaction with no continuation — the /compact line was typed, and
# nothing follows it. Same effect here as the prepare-only marker, from a
# different sentinel: consume, inject, type nothing.
@test "load-compact (pending with no continuation: consumed, frame only)" {
    seed_pending "$tmp" "compact" "/compact keep the parser work"
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("hook smoke test")' >/dev/null
    echo "$output" | jq -e '.systemMessage | test("frame re-injected")' >/dev/null
}

# FR-G's other half: the prepare-only marker arrives here as a pending file with
# no after-line. Inject the frame, type nothing.
@test "load-compact (empty after-sequence: frame injected, nothing typed)" {
    seed_pending "$tmp" "compact"
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
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
    [ ! -e "$wt/.claude/autodrive" ]
}

@test "load-compact (armed file: not consumed, no frame)" {
    seed_drive "$tmp" "compact" "/compact" "continue with task 3"
    run_load_compact "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "armed" ]
}

# --- load-restart (SessionStart(resume): fire the continuation, no frame) ---
#
# Unlike /clear or /compact, --resume restores the full prior conversation on
# its own — there is nothing for a frame to hand a summariser's paraphrase
# back to, so this loader never assembles or injects one. That is the whole
# difference from load-compact.sh's shape below.

run_load_restart() {
    run bash -c '
        jq -nc --arg cwd "$1" "{cwd:\$cwd, source:\"resume\", transcript_path:(\$cwd + \"/t.jsonl\")}" \
        | '"$2"' bash scripts/load-restart.sh
    ' _ "$1"
}

@test "load-restart (no pending: silent)" {
    run_load_restart "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "load-restart (pending restart with continuation: consumes it, reports it)" {
    seed_pending "$tmp" "restart" "/exit" "claude --resume sess-hook-test" "continue with task 3"
    run_load_restart "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.systemMessage | test("continue with task 3")' >/dev/null
}

@test "load-restart (pending restart, no continuation: consumed, reports resumed)" {
    seed_pending "$tmp" "restart" "/exit" "claude --resume sess-hook-test"
    run_load_restart "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.systemMessage | test("resumed")' >/dev/null
}

@test "load-restart (pending of kind compact: left for SessionStart(compact))" {
    seed_pending "$tmp" "compact" "/compact" "continue with task 3"
    run_load_restart "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "pending" ]
    [ "$(sed -n 2p "$tmp/.claude/autodrive")" = "compact" ]
}

@test "load-restart (armed file: not consumed)" {
    seed_drive "$tmp" "restart" "/exit" "claude --resume sess-hook-test"
    run_load_restart "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "armed" ]
}

@test "load-restart (not in tmux: emits continuation to paste, clears pending)" {
    seed_pending "$tmp" "restart" "/exit" "claude --resume sess-hook-test" "continue with task 3"
    run_load_restart "$tmp" 'env -u TMUX -u TMUX_PANE'
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("continue with task 3")' >/dev/null
}

@test "load-restart (worktree cwd: consumes the worktree pending file)" {
    wt="$(make_worktree wtLR)"
    seed_pending "$wt" "restart" "/exit" "claude --resume sess-hook-test"
    run_load_restart "$wt" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/autodrive" ]
}

# The differentiator from load-compact.sh: --resume already restores the full
# conversation, so even with a task file present, no frame is assembled.
@test "load-restart (task file present: still no frame injected)" {
    seed_pending "$tmp" "restart" "/exit" "claude --resume sess-hook-test" "continue with task 3"
    printf '%s\n' "## Now" "- rewire the parser" > "$tmp/.claude/handoff-task.md"
    run_load_restart "$tmp" 'TMUX=fake TMUX_PANE="%0"'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'has("hookSpecificOutput") | not' >/dev/null
}

@test "hooks.json dispatches SessionStart(resume) to load-restart.sh" {
    run jq -e '[.hooks.SessionStart[] | select(.matcher == "resume") | .hooks[0].command | test("load-restart.sh")] | any' \
        "$repo_root/hooks/hooks.json"
    [ "$status" -eq 0 ]
}

# --- session-pointer (SessionStart, every source: sweep stale pointer files) ---
#
# Used to also publish this session's resolved root here, at a session-keyed
# path handoff-checkpoint (running in the agent's own Bash, where
# CLAUDE_PROJECT_DIR is unset) could address blind. Replaced by
# scripts/inject-checkpoint-root.sh (PreToolUse(Bash)), which resolves the
# root fresh on every matching call instead.

run_session_pointer() {
    local cwd="$1"
    run bash -c '
        jq -nc --arg cwd "$1" --arg sid "$2" \
          "{cwd:\$cwd, session_id:\$sid, source:\"startup\", hook_event_name:\"SessionStart\"}" \
        | bash scripts/session-pointer.sh
    ' _ "$cwd" "$SESSION_ID"
}

# scripts/inject-checkpoint-root.sh (PreToolUse(Bash)) resolves the root fresh
# on every matching call and injects it straight into the command now, instead
# of this hook sampling and publishing it once at SessionStart.
# SessionStart(resume) fires with the RESUMING process's cwd, before the
# harness moves the session into its own project dir — the one moment a sample
# taken here would stamp the wrong repo onto it. Mutation-checked: the first
# assertion cannot go red before the write is removed, so it is verified by
# reintroducing the old write and watching this alone go red. See
# plans/2026-08-05-checkpoint-root-via-updatedinput.md.
@test "session-pointer (no longer writes a root pointer)" {
    run_session_pointer "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$HANDOFF_POINTER_DIR/handoff-root-$SESSION_ID" ]
}

@test "session-pointer (creates the pointer directory)" {
    [ ! -d "$HANDOFF_POINTER_DIR" ]
    run_session_pointer "$tmp"
    [ "$status" -eq 0 ]
    [ -d "$HANDOFF_POINTER_DIR" ]
}

# Nothing else removes these. The pointer outlives the session that published
# it, the drift marker outlives the episode it recorded, and the directory they
# share is swept by nobody. The producer sweeps its own leavings — once per
# session start, which is the only moment anything of this plugin's runs there.

@test "session-pointer (sweeps its own long-stale files)" {
    mkdir -p "$HANDOFF_POINTER_DIR"
    touch -t 202001010000 "$HANDOFF_POINTER_DIR/handoff-root-ancient" \
        "$HANDOFF_POINTER_DIR/handoff-drift-ancient"
    run_session_pointer "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$HANDOFF_POINTER_DIR/handoff-root-ancient" ]
    [ ! -e "$HANDOFF_POINTER_DIR/handoff-drift-ancient" ]
}

@test "session-pointer (keeps another live session's files)" {
    mkdir -p "$HANDOFF_POINTER_DIR"
    touch "$HANDOFF_POINTER_DIR/handoff-root-other" \
        "$HANDOFF_POINTER_DIR/handoff-drift-other"
    run_session_pointer "$tmp"
    [ "$status" -eq 0 ]
    [ -e "$HANDOFF_POINTER_DIR/handoff-root-other" ]
    [ -e "$HANDOFF_POINTER_DIR/handoff-drift-other" ]
}

# The load-bearing negative: the directory is shared and holds files this
# plugin never wrote, some of them weeks old. The sweep is scoped to the two
# names it publishes, at the one level it publishes them.
#
# The handoff-prefixed file pins the narrower claim — the two names, not the
# prefix. Collapsing the two -name clauses into one `handoff-*` is the
# plausible refactor, and every other row here is blind to it: it would claim
# any later handoff- file in this shared directory whose lifetime is not seven
# days. A new published name must be added here as deliberately as to the
# filter.
@test "session-pointer (never sweeps a file it does not own)" {
    mkdir -p "$HANDOFF_POINTER_DIR/sub"
    touch -t 202001010000 "$HANDOFF_POINTER_DIR/somebody-elses-file" \
        "$HANDOFF_POINTER_DIR/handoff-unpublished-ancient" \
        "$HANDOFF_POINTER_DIR/sub/handoff-root-nested"
    run_session_pointer "$tmp"
    [ "$status" -eq 0 ]
    [ -e "$HANDOFF_POINTER_DIR/somebody-elses-file" ]
    [ -e "$HANDOFF_POINTER_DIR/handoff-unpublished-ancient" ]
    [ -e "$HANDOFF_POINTER_DIR/sub/handoff-root-nested" ]
}

# --- report-watcher-failure (UserPromptSubmit: surface a non-delivery) ---
#
# The walker is detached and has no channel back: a line that never lands is
# invisible to the agent, and the recognition abort leaves the pane looking
# untouched. The walker drops a reason file; this hook is what reads it. One
# channel now, not two — the transition is a singleton.

run_report_failure() {
    run bash -c '
        jq -nc --arg cwd "$1" --arg sid "$2" \
          "{cwd:\$cwd, session_id:\$sid, prompt:\"anything\"}" \
        | bash scripts/report-watcher-failure.sh
    ' _ "$1" "${2-$SESSION_ID}"
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

# A failure part-way through a sequence leaves the transition stranded in
# state `pending`: no transition will consume it, and Stop cannot re-arm from it.
@test "report-watcher-failure (clears a stranded pending file)" {
    printf '%s\n' "typed but never submitted" > "$tmp/.claude/autodrive.failed"
    seed_pending "$tmp" "compact" "/compact" "continue"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
}

@test "report-watcher-failure (worktree cwd: reads the worktree file)" {
    wt="$(make_worktree wtF)"
    printf '%s\n' "typed but never submitted" > "$wt/.claude/autodrive.failed"
    run_report_failure "$wt"
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/autodrive.failed" ]
    echo "$output" | jq -e '.systemMessage | test("never submitted")' >/dev/null
}

# An autodrive is armed at the Stop of the turn that writes it, and that Stop
# leaves it `pending` or removes it. So one still in state `armed` at a *later*
# turn's UserPromptSubmit never armed — its turn ended abnormally (Esc, crash,
# quit). Left alone it is armed by the next normal Stop, days later and
# possibly in another session, driving a stale transition into unrelated work.
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

# A sentinel that does not parse — here, a `clear` with only one of its four
# command/prose lines — describes no transition this session can complete.
# handoff_drive_read returns 1, drive_state is recorded as "malformed", and
# the sweep (any state other than "pending") discards it exactly as it would
# a stale armed file.
@test "report-watcher-failure (malformed sentinel: discarded and reported)" {
    seed_drive "$tmp" "clear" "/rename A Title"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.systemMessage | test("discarded")' >/dev/null
}

# A pending file is legitimate for the whole Stop -> transition window, and that
# window contains the walker's own submits — each of which is a
# UserPromptSubmit. Sweeping one here would race SessionStart(compact|clear) and
# kill a live continuation. Only the failure branch above, which acts on
# something the walker observed itself, may clear one.
@test "report-watcher-failure (pending file: left alone, no report)" {
    seed_pending "$tmp" "compact" "/compact" "continue"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "pending" ]
}

# `held` is the one state that legitimately survives a turn boundary: the
# approval round trip it waits on costs at least one turn, and the answer arrives
# at a UserPromptSubmit — this hook. Sweeping this session's own held file would
# silently cancel the transition the user is in the middle of approving.
@test "report-watcher-failure (held file owned by this session: left alone)" {
    printf '%s\n' "held $SESSION_ID" "clear" "/rename A Title" "/clear" "resume" \
        > "$tmp/.claude/autodrive"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(head -n1 "$tmp/.claude/autodrive")" = "held $SESSION_ID" ]
}

# The exemption reaches exactly as far as its reason. A held file belongs to the
# session whose approval it waits on; once *another* session is taking prompts in
# this repo, that approval can never arrive — the session that would have given
# it is gone. Left on disk it stays armable indefinitely, and handoff-approved
# would arm a dead session's `/rename` + `/clear` into a live conversation.
@test "report-watcher-failure (held file owned by a dead session: discarded)" {
    printf '%s\n' "held sess-someone-else" "clear" "/rename A Title" "/clear" "resume" \
        > "$tmp/.claude/autodrive"
    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autodrive" ]
    echo "$output" | jq -e '.systemMessage | test("stale|discarded")' >/dev/null
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

# --- report-watcher-failure: session-root drift ---
#
# Nothing announces a cwd that leaves the launch repo: the environment block,
# gitStatus and the project CLAUDE.md all follow cwd, while the transcript, the
# scratchpad, CLAUDE_PROJECT_DIR and every handoff file stay behind. The check
# rides UserPromptSubmit because drift can be transient — a gate that asks "is
# cwd foreign now?" later sees nothing — and because this hook already resolves
# the root every turn and already owns a reporting channel.

@test "report-watcher-failure (drift: reports the destination and the root)" {
    mkdir -p "$other/.git"
    run_report_failure "$other"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg c "$other" '.systemMessage | test($c)' >/dev/null
    echo "$output" | jq -e --arg r "$tmp" '.systemMessage | test($r)' >/dev/null
    echo "$output" | jq -e \
        '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null
    echo "$output" | jq -e --arg c "$other" \
        '.hookSpecificOutput.additionalContext | test($c)' >/dev/null
}

# Dimmed like the ordinary hook chatter around it, the one line that says the
# agent is reasoning about the wrong repo reads as noise.
@test "report-watcher-failure (drift: systemMessage leads with an ANSI reset)" {
    mkdir -p "$other/.git"
    run_report_failure "$other"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.systemMessage | startswith("\u001b[0m")' >/dev/null
}

@test "report-watcher-failure (drift: reports once per destination, not every prompt)" {
    mkdir -p "$other/.git"
    run_report_failure "$other"
    [ -n "$output" ]

    run_report_failure "$other"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# A blip is announced once; a later move somewhere else is a new fact, not the
# same one repeating.
@test "report-watcher-failure (drift: a different destination reports again)" {
    mkdir -p "$other/.git"
    run_report_failure "$other"
    [ -n "$output" ]

    elsewhere="$BATS_TEST_TMPDIR/elsewhere"
    mkdir -p "$elsewhere/.git"
    run_report_failure "$elsewhere"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg c "$elsewhere" '.systemMessage | test($c)' >/dev/null
}

# Back inside the launch repo, and back to silence — including from the marker
# the earlier drift left behind.
@test "report-watcher-failure (drift: cwd back in the project is silent)" {
    mkdir -p "$other/.git"
    run_report_failure "$other"
    [ -n "$output" ]

    run_report_failure "$tmp"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# Returning ends the episode, so the same destination reached again is a new
# fact — the transient blip is the shape this has to survive.
@test "report-watcher-failure (drift: returning and drifting again reports again)" {
    mkdir -p "$other/.git"
    run_report_failure "$other"
    [ -n "$output" ]

    run_report_failure "$tmp"
    [ "$output" = "" ]

    run_report_failure "$other"
    echo "$output" | jq -e --arg c "$other" '.systemMessage | test($c)' >/dev/null
}

@test "report-watcher-failure (drift: a worktree cwd is not drift)" {
    wt="$(make_worktree wtDR)"
    run_report_failure "$wt"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "report-watcher-failure (drift and a non-delivery: one report covering both)" {
    mkdir -p "$other/.git"
    printf '%s\n' "typed but never submitted" > "$other/.claude/autodrive.failed"
    # The failure file the hook reads is the *root's*, not cwd's — that is the
    # split being reported.
    printf '%s\n' "typed but never submitted" > "$tmp/.claude/autodrive.failed"
    run_report_failure "$other"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -sr 'length')" = "1" ]
    echo "$output" | jq -e '.systemMessage | test("never submitted")' >/dev/null
    echo "$output" | jq -e --arg c "$other" '.systemMessage | test($c)' >/dev/null
}

@test "report-watcher-failure (worktree cwd: sweeps the worktree file)" {
    wt="$(make_worktree wtG)"
    seed_drive "$wt" "compact" "/compact" "continue"
    run_report_failure "$wt"
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/autodrive" ]
    echo "$output" | jq -e '.systemMessage | test("stale")' >/dev/null
}
