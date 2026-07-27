#!/usr/bin/env bash
# Shared helpers for handoff hook scripts. Source-only; no shebang
# execution. Source from siblings via:
#   # shellcheck source-path=SCRIPTDIR source=_lib.sh
#   source "$(dirname "$0")/_lib.sh"

# Canonical relative paths inside the project. Changing these is a
# breaking change (see CLAUDE.md conventions).
# shellcheck disable=SC2034  # consumed by sourcing scripts
HANDOFF_REL_TASK=".claude/handoff-task.md"
# The remainder ledger: open todo items only, never completion state. Tracked
# on the same terms as the task file (write-stage.sh force-adds both) — it is
# overflow from that file, so it earns the same persistence. See DESIGN.md,
# "A place for the todo list" and "Overflow deserves the same persistence".
# shellcheck disable=SC2034
HANDOFF_REL_TODO=".claude/handoff-todo.md"
# shellcheck disable=SC2034
HANDOFF_REL_RENAME=".claude/autorename"
# shellcheck disable=SC2034
HANDOFF_REL_COMPACT=".claude/autocompact"
# The armed rename target. Stop moves autocompact here before spawning, so a
# later Stop in the same session cannot re-arm; SessionStart(compact) consumes it.
# shellcheck disable=SC2034
HANDOFF_REL_COMPACT_PENDING=".claude/autocompact.pending"
# Where a detached watcher records a line it could not deliver, one file per
# driven line. A watcher's exit status goes nowhere, so these are the only path
# back to the agent; both are consumed and reported by report-watcher-failure.sh
# at the next UserPromptSubmit.
# shellcheck disable=SC2034
HANDOFF_REL_COMPACT_FAILED=".claude/autocompact.failed"
# shellcheck disable=SC2034
HANDOFF_REL_RENAME_FAILED=".claude/autorename.failed"

# Assemble the injectable frame from the task file ($1) and the optional todo
# remainder ($2): a timestamp header plus each file inlined verbatim, in that
# order. Either file alone is enough; prints nothing and returns 1 only when
# both are missing or empty, so callers can gate on the exit status. Shared by
# load-handoff.sh (startup|clear) and load-compact.sh (compact) — one frame
# shape for both transitions, since both inject the same files.
#
# The hook does not re-state either template: each file carries its own `##`
# section headings (SKILL.md is the single source of truth) and is concatenated
# verbatim under the one `#` header prepended here.
handoff_frame() {
    local task="$1" todo="${2:-}" out=""
    if [[ ! -s "$task" && ( -z "$todo" || ! -s "$todo" ) ]]; then
        return 1
    fi
    out="# Task — $(date '+%Y-%m-%d %H:%M:%S %z')"
    if [[ -s "$task" ]]; then
        out+=$'\n\n'"$(cat "$task")"
    fi
    if [[ -n "$todo" && -s "$todo" ]]; then
        out+=$'\n\n'"$(cat "$todo")"
    fi
    printf '%s\n' "$out"
}

# Parse and validate an autocompact file ($1) into the caller's COMPACT_L1
# (the literal /compact command to type) and COMPACT_L2 (the continuation
# prompt). Returns 0 when well-formed; otherwise returns 1 with COMPACT_ERR set
# to a one-phrase reason naming the constraint that failed.
#
# Exactly two lines, a single trailing newline tolerated. Line 2 must be a
# single line because in the TUI one Enter is one submit — an embedded newline
# would submit the continuation early. Read with a `read` loop rather than
# mapfile: bash 3.2 (macOS system bash) has no mapfile.
# shellcheck disable=SC2034  # assigned for the caller's scope
handoff_compact_read() {
    local file="$1" line count=0
    COMPACT_L1=""; COMPACT_L2=""; COMPACT_ERR=""

    while IFS= read -r line || [ -n "$line" ]; do
        count=$((count + 1))
        case $count in
            1) COMPACT_L1="$line" ;;
            2) COMPACT_L2="$line" ;;
        esac
    done < "$file"

    if [ "$count" -ne 2 ]; then
        COMPACT_ERR="the file must hold exactly two lines (found $count)"
        return 1
    fi
    case "$COMPACT_L1" in
        "/compact"|"/compact "*) ;;
        *) COMPACT_ERR="line 1 must be \`/compact\` or \`/compact <directive>\`"
           return 1 ;;
    esac
    if [ -z "${COMPACT_L2// /}" ]; then
        COMPACT_ERR="line 2 must be the continuation prompt, and must not be empty"
        return 1
    fi
    return 0
}

# Portable path canonicalization. `realpath -m` is GNU-only; BSD
# `realpath` rejects non-existent components. Python handles both and
# resolves multiple paths in one subprocess to amortize cold start.
# Prints one line per argument, in order.
handoff_resolve() {
    python3 -c 'import os,sys
for p in sys.argv[1:]: print(os.path.realpath(p))' "$@"
}

# Parse the three fields every path-scoped tool hook needs from the
# hook-input JSON ($1) in a single jq pass, populating the caller's
# HOOK_FILE_PATH, HOOK_CWD, and HOOK_TRANSCRIPT. HOOK_CWD is the raw
# .cwd — callers pass it through handoff_root to anchor on the worktree
# root. One field per line (not @tsv: tab is IFS-whitespace, so an empty
# field between two tabs would collapse and shift the rest).
# shellcheck disable=SC2034  # assigned for the caller's scope
handoff_hook_fields() {
    { read -r HOOK_FILE_PATH; read -r HOOK_CWD; read -r HOOK_TRANSCRIPT; } < <(
        jq -r '.tool_input.file_path // "", .cwd // "", .transcript_path // ""' \
            <<<"$1"
    )
}

# Effective project root for the handoff files of THIS session. When the
# session cwd ($1, from hook-input .cwd) is inside a linked git worktree of
# CLAUDE_PROJECT_DIR, returns the worktree root so each worktree owns its own
# .claude/; otherwise returns CLAUDE_PROJECT_DIR (fallback $PWD). The
# branch-heavy resolution lives in worktree_root.py (unit-tested with pytest);
# this is the thin shell wrapper. See
# plans/2026-06-09-per-worktree-handoff-root-design.md.
handoff_root() {
    local project="${CLAUDE_PROJECT_DIR:-$PWD}"
    # Fast path: an empty cwd or one already at the project root is exactly
    # worktree_root.py's trivial branches (`if not cwd` / `if d == project`).
    # Skipping the interpreter matters because Stop and UserPromptSubmit call
    # this on every turn, where python3 startup dominates the hook's cost.
    if [[ -z "${1:-}" || "${1:-}" == "$project" ]]; then
        printf '%s\n' "$project"
        return 0
    fi
    python3 "$(dirname "${BASH_SOURCE[0]}")/worktree_root.py" \
        "$1" "$project"
}

# Match the hook-input JSON ($1) against one or more handoff-owned files, given
# as (basename, project-relative-path) pairs: the basename is the cheap filter,
# then resolved-path equality with $cwd/<rel> is the cross-project guard. Pairs
# are tried in order and the first basename hit wins. Populates the caller's
# HOOK_* fields (via handoff_hook_fields) plus cwd, target, expected and
# MATCHED_NAME (the basename that matched, so a caller guarding several files
# can name the right one in a deny). Returns 0 when the event resolves to this
# project's file, 1 when it is about some other file (no file_path, no basename
# hit, or the root cannot be resolved), and 2 when a basename matched but the
# resolved path is elsewhere (cross-project) — write-guard.sh denies on 2,
# every other caller treats it as 1.
#
# Variadic rather than one call per file because the JSON parse is a jq spawn
# on the Write/Edit hot path: guarding N files must stay one parse, not N.
# shellcheck disable=SC2034  # cwd/target/expected/MATCHED_NAME for the caller
handoff_match_target() {
    local json="$1"; shift
    local base rel=""
    handoff_hook_fields "$json"
    [[ -n "$HOOK_FILE_PATH" ]] || return 1
    base="$(basename "$HOOK_FILE_PATH")"
    MATCHED_NAME=""
    while (( $# >= 2 )); do
        if [[ "$base" == "$1" ]]; then
            MATCHED_NAME="$1"; rel="$2"; break
        fi
        shift 2
    done
    [[ -n "$MATCHED_NAME" ]] || return 1
    cwd="$(handoff_root "$HOOK_CWD")"
    [[ -n "$cwd" ]] || return 1
    { read -r target; read -r expected; } \
        < <(handoff_resolve "$HOOK_FILE_PATH" "$cwd/$rel")
    [[ "$target" == "$expected" ]] || return 2
}

# Spawn a detached watcher (scripts/<$1>, remaining args passed through) so it
# outlives the hook turn. setsid fully detaches it into its own session but is
# Linux-only — macOS ships no setsid(1) — so fall back to nohup (POSIX, ignores
# SIGHUP). An exported HANDOFF_FAIL_FILE propagates to the child; exporting it
# stays with the caller, which owns the path.
handoff_spawn_detached() {
    local watcher
    watcher="$(dirname "${BASH_SOURCE[0]}")/$1"; shift
    if command -v setsid >/dev/null 2>&1; then
        setsid bash "$watcher" "$@" >/dev/null 2>&1 &
    else
        nohup bash "$watcher" "$@" >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
}

# Emit a PreToolUse deny on stdout, then `exit 0` (not `return`) —
# terminates the calling process, so only safe from a standalone hook
# script, not a general sourced context (subshell/interactive/setup).
# Modern PreToolUse permissionDecision deny channel. $1 = agent-facing
# reason (factual, no actionable phrasing);
# $2 = user-facing systemMessage.
handoff_deny() {
    jq -nc --arg r "$1" --arg s "$2" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}, systemMessage: $s}'
    exit 0
}
