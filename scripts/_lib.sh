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
# overflow from that file, so it earns the same persistence. See
# docs/changelog/2026-07-22-a-place-for-the-todo-list.md and
# docs/changelog/2026-07-23-overflow-deserves-persistence.md.
# shellcheck disable=SC2034
HANDOFF_REL_TODO=".claude/handoff-todo.md"
# The transition. One composer, one session, at most one transition in flight —
# so one file, whose *body* names both the transition and where it has got to.
# Line 1 is the state (armed -> pending -> gone), line 2 the kind. See
# docs/design.md, "The armed transition is a singleton".
# shellcheck disable=SC2034
HANDOFF_REL_DRIVE=".claude/autodrive"
# Where the walker records a line it could not deliver. A watcher's exit status
# goes nowhere, so this is the only path back to the agent; consumed and
# reported by report-watcher-failure.sh at the next UserPromptSubmit.
# shellcheck disable=SC2034
HANDOFF_REL_DRIVE_FAILED=".claude/autodrive.failed"

# Where this session's resolved root is published (session-pointer.sh) for the
# agent's own Bash to read back (handoff-checkpoint), and where the drift
# report records the last destination it announced. Not the project's .claude/:
# the checkpoint cannot address a path under the root, since resolving that
# root is the very thing it cannot do. A literal directory rather than $TMPDIR
# for the same reason — the producer is a hook and the consumer is the agent's
# sandboxed Bash, and the two share no environment but the session id.
HANDOFF_POINTER_DIR="${HANDOFF_POINTER_DIR:-/tmp/claude}"

# Path of the root pointer for session id $1.
handoff_pointer_path() {
    printf '%s/handoff-root-%s\n' "$HANDOFF_POINTER_DIR" "$1"
}

# Path of the context-threshold marker for session id $1. Written when the
# nudge fires and removed by session-pointer.sh at the next SessionStart: the
# nudge fires once per climb, and the boundary is what re-arms it. A helper
# rather than an inline path (as the drift marker is) because two scripts
# address it — the same reason handoff_pointer_path exists.
handoff_context_path() {
    printf '%s/handoff-context-%s\n' "$HANDOFF_POINTER_DIR" "$1"
}

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

# Shape helpers for handoff_drive_read. Each sets DRIVE_ERR and returns 1.
_handoff_drive_expect() {  # <found> <want>
    [ "$1" -eq "$2" ] && return 0
    DRIVE_ERR="kind \`$DRIVE_KIND\` takes exactly $2 lines (found $1)"
    return 1
}

# <line> <lineno> <literal> <arg|optional|none>. The kind fixes which command
# belongs in which slot, so the file cannot be made to type something else.
_handoff_drive_command() {
    local line="$1" no="$2" cmd="$3" mode="$4"
    case "$mode" in
        none)
            [ "$line" = "$cmd" ] && return 0
            DRIVE_ERR="line $no must be exactly \`$cmd\`" ;;
        optional)
            case "$line" in "$cmd"|"$cmd "*) return 0 ;; esac
            DRIVE_ERR="line $no must be \`$cmd\` or \`$cmd <argument>\`" ;;
        arg)
            case "$line" in "$cmd "*)
                if [ -n "$(printf '%s' "${line#"$cmd" }" | tr -d '[:space:]')" ]; then
                    return 0
                fi ;;
            esac
            DRIVE_ERR="line $no must be \`$cmd <argument>\`, with a non-empty argument" ;;
    esac
    return 1
}

# <line> <lineno>. Prose is submitted with a bare Enter, so a line that looks
# like a command would take the recognition path instead and be confirmed by
# the wrong primitive.
_handoff_drive_prose() {
    local line="$1" no="$2"
    if [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ]; then
        DRIVE_ERR="line $no is the continuation prompt, and must not be empty"
        return 1
    fi
    case "$line" in /*)
        DRIVE_ERR="line $no is the continuation prompt, and must not begin with \`/\`"
        return 1 ;;
    esac
    return 0
}

# Parse and validate the sentinel ($1) into the caller's DRIVE_STATE, DRIVE_KIND,
# DRIVE_BEFORE (lines typed before the transition) and DRIVE_AFTER (lines typed
# into the session the transition opens). Returns 0 when well-formed; otherwise
# returns 1 with DRIVE_ERR set to a one-phrase reason naming the constraint that
# failed.
#
# Line 1 is the state and line 2 is the kind, and the kind fixes the shape — so
# the remaining lines need no separator, and each kind keeps its own rules:
#
#   armed    the transition this turn's Stop will arm
#   pending  armed, in flight, waiting on its confirming SessionStart
#
#   rename   /rename <title>
#   compact  /compact [directive]         + continuation prose
#   compact  (kind line alone: a transition is expected, nothing is typed)
#   clear    /rename <title>, /clear      + continuation prose
#
# The state is reported, never interpreted: which state a caller wants is the
# caller's business, and the parser serves the Stop gate, both loaders and the
# UserPromptSubmit sweep with one answer.
#
# The lines are literal keystrokes: the walker must not know which command any
# kind uses. Every prose line is a single line because in the TUI one Enter is
# one submit — an embedded newline would submit it early. Read with a `read`
# loop rather than mapfile: bash 3.2 (macOS system bash) has no mapfile, and for
# the same reason callers must expand the arrays as
# `${DRIVE_BEFORE[@]+"${DRIVE_BEFORE[@]}"}` — an empty array is an unbound
# variable under `set -u` before bash 4.4.
# shellcheck disable=SC2034  # assigned for the caller's scope
handoff_drive_read() {
    local file="$1" line n
    local -a lines=()
    DRIVE_STATE=""; DRIVE_KIND=""; DRIVE_BEFORE=(); DRIVE_AFTER=(); DRIVE_ERR=""

    while IFS= read -r line || [ -n "$line" ]; do
        lines+=("$line")
    done < "$file"

    n=${#lines[@]}
    if [ "$n" -eq 0 ]; then
        DRIVE_ERR="the file is empty; line 1 must be the transition state"
        return 1
    fi
    DRIVE_STATE="${lines[0]}"
    case "$DRIVE_STATE" in
        armed | pending) ;;
        *)
            DRIVE_ERR="line 1 must be the transition state — armed or pending — not \`$DRIVE_STATE\`"
            return 1 ;;
    esac

    if [ "$n" -eq 1 ]; then
        DRIVE_ERR="line 2 must be the transition kind — rename, compact or clear"
        return 1
    fi
    DRIVE_KIND="${lines[1]}"

    case "$DRIVE_KIND" in
        rename)
            _handoff_drive_expect "$n" 3 || return 1
            _handoff_drive_command "${lines[2]}" 3 "/rename" arg || return 1
            DRIVE_BEFORE=("${lines[2]}")
            ;;
        compact)
            # The kind line alone is the prepare-only marker: nothing is typed,
            # but the transition is expected, so the loader still injects.
            [ "$n" -eq 2 ] && return 0
            _handoff_drive_expect "$n" 4 || return 1
            _handoff_drive_command "${lines[2]}" 3 "/compact" optional || return 1
            _handoff_drive_prose "${lines[3]}" 4 || return 1
            DRIVE_BEFORE=("${lines[2]}")
            DRIVE_AFTER=("${lines[3]}")
            ;;
        clear)
            _handoff_drive_expect "$n" 5 || return 1
            _handoff_drive_command "${lines[2]}" 3 "/rename" arg || return 1
            _handoff_drive_command "${lines[3]}" 4 "/clear" none || return 1
            _handoff_drive_prose "${lines[4]}" 5 || return 1
            DRIVE_BEFORE=("${lines[2]}" "${lines[3]}")
            DRIVE_AFTER=("${lines[4]}")
            ;;
        *)
            DRIVE_ERR="line 2 must be the transition kind — rename, compact or clear — not \`$DRIVE_KIND\`"
            return 1
            ;;
    esac
    return 0
}

# Kinds whose transition is confirmed by a SessionStart. `rename` is not one:
# no loader consumes it, so stop-drive.sh deletes its sentinel outright instead
# of leaving it pending for nobody to clear.
handoff_drive_has_source() {
    case "$1" in
        compact|clear) return 0 ;;
        *) return 1 ;;
    esac
}

# Rewrite the sentinel ($1) into state $2, preserving every line below the
# first. The state is the only field any transition changes, so one helper
# serves them all and none of them has to know the kind's shape.
#
# Atomic: a sibling temp file renamed over the original. Concurrent readers
# exist — both loaders and Stop parse this file, and the walker stats it — so a
# partially written file must never be observable under the real name. The temp
# lands in the same directory because rename(2) is only atomic within one
# filesystem, and .claude/autodrive* is gitignored, so a temp orphaned by a kill
# is never committed.
handoff_drive_arm() {
    local file="$1" state="$2" tmp="$1.arming.$$"
    if ! printf '%s\n' "$state" > "$tmp" || ! tail -n +2 "$file" >> "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$file"
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

# Effective project root for the handoff files of THIS session, into the
# caller's HANDOFF_ROOT, plus the branch that produced it in
# HANDOFF_ROOT_BRANCH: `inside` (cwd is the project or under it), `worktree`
# (a linked worktree of it), `foreign` (another repo) or `unrelated` (no repo).
# When the session cwd ($1, from hook-input .cwd) is inside a linked git
# worktree of CLAUDE_PROJECT_DIR, the root is the worktree root so each
# worktree owns its own .claude/; otherwise CLAUDE_PROJECT_DIR (fallback $PWD).
# The branch-heavy resolution lives in worktree_root.py (unit-tested with
# pytest); this is the thin shell wrapper. See
# plans/2026-06-09-per-worktree-handoff-root-design.md and
# plans/2026-07-31-session-root-drift-design.md.
#
# Caller-scope globals rather than stdout (the handoff_drive_read idiom):
# every other caller wants the root printed, and a global set inside the
# `$(...)` that captures it would die with the subshell.
# shellcheck disable=SC2034  # assigned for the caller's scope
handoff_root_read() {
    local project="${CLAUDE_PROJECT_DIR:-$PWD}"
    # Fast path: an empty cwd or one already at the project root is exactly
    # worktree_root.py's trivial branches (`if not cwd` / `if d == project`).
    # Skipping the interpreter matters because Stop and UserPromptSubmit call
    # this on every turn, where python3 startup dominates the hook's cost. It
    # labels the branch itself — leaving the previous resolution's label in
    # place would report drift on a session that never drifted.
    if [[ -z "${1:-}" || "${1:-}" == "$project" ]]; then
        HANDOFF_ROOT="$project"
        HANDOFF_ROOT_BRANCH="inside"
        return 0
    fi
    { read -r HANDOFF_ROOT; read -r HANDOFF_ROOT_BRANCH; } < <(
        python3 "$(dirname "${BASH_SOURCE[0]}")/worktree_root.py" "$1" "$project"
    )
}

# The root alone, on stdout — one line, unchanged. Callers that also want the
# branch call handoff_root_read directly.
handoff_root() {
    handoff_root_read "${1:-}" || return 1
    printf '%s\n' "$HANDOFF_ROOT"
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
