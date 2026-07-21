#!/usr/bin/env bash
# Shared helpers for handoff hook scripts. Source-only; no shebang
# execution. Source from siblings via:
#   # shellcheck source-path=SCRIPTDIR source=_lib.sh
#   source "$(dirname "$0")/_lib.sh"

# Canonical relative paths inside the project. Changing these is a
# breaking change (see CLAUDE.md conventions).
# shellcheck disable=SC2034  # consumed by sourcing scripts
HANDOFF_REL_TASK=".claude/handoff-task.md"
# shellcheck disable=SC2034
HANDOFF_REL_RENAME=".claude/autorename"
# shellcheck disable=SC2034
HANDOFF_REL_COMPACT=".claude/autocompact"
# The armed rename target. Stop moves autocompact here before spawning, so a
# later Stop in the same session cannot re-arm; SessionStart(compact) consumes it.
# shellcheck disable=SC2034
HANDOFF_REL_COMPACT_PENDING=".claude/autocompact.pending"
# Where a detached watcher records a line it could not deliver. Its exit status
# goes nowhere, so this file is the only path back to the agent; consumed and
# reported by report-compact-failure.sh at the next UserPromptSubmit.
# shellcheck disable=SC2034
HANDOFF_REL_COMPACT_FAILED=".claude/autocompact.failed"

# Assemble the injectable frame for a task file ($1): a timestamp header plus
# the file inlined verbatim. Prints nothing and returns 1 when the file is
# missing or empty, so callers can gate on the exit status. Shared by
# load-handoff.sh (startup|clear) and load-compact.sh (compact) — one frame
# shape for both transitions, since both inject the same file.
handoff_frame() {
    local task="$1"
    [[ -s "$task" ]] || return 1
    printf '# Task — %s\n\n%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S %z')" "$(cat "$task")"
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

# Match the hook-input JSON ($1) against one handoff-owned file: basename ($2)
# as the cheap filter, then resolved-path equality with $cwd/$3 as the
# cross-project guard. Populates the caller's HOOK_* fields (via
# handoff_hook_fields) plus cwd, target and expected. Returns 0 when the event
# resolves to this project's file, 1 when it is about some other file
# (no file_path, basename mismatch, or the root cannot be resolved), and 2
# when the basename matches but the resolved path is elsewhere
# (cross-project) — write-guard.sh denies on 2, every other caller treats it
# as 1.
# shellcheck disable=SC2034  # cwd/target/expected assigned for the caller
handoff_match_target() {
    local json="$1" name="$2" rel="$3"
    handoff_hook_fields "$json"
    [[ -n "$HOOK_FILE_PATH" ]] || return 1
    [[ "$(basename "$HOOK_FILE_PATH")" == "$name" ]] || return 1
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

# Has a task-file-writing skill activated in this session? Stateless:
# derive the answer from the transcript JSONL each call (no marker, no
# env). Either `handoff` or `precompact` counts — both write
# handoff-task.md, so both must open the read and write guards. Scans both
# invocation paths per skill: a Skill tool_use (agent path; the bare and
# plugin-qualified skill arg are both launches of the same skill) or the
# slash command (user path, stored as a <command-name> wrapper). Verified
# against real transcripts 2026-05-23. Exit 0 if activated, 1 otherwise
# (incl. empty/missing/unreadable transcript).
handoff_activated() {
    local transcript="$1"
    [[ -n "$transcript" && -f "$transcript" ]] || return 1
    python3 - "$transcript" <<'PY'
import json, sys

# Both skills write handoff-task.md, so either activates the guards. The bare
# and qualified skill args are both launches of the same skill.
SKILLS = {"handoff", "handoff:handoff", "precompact", "handoff:precompact"}
SLASHES = (
    "<command-name>/handoff:handoff</command-name>",
    "<command-name>/handoff:precompact</command-name>",
)
try:
    fh = open(sys.argv[1], encoding="utf-8", errors="replace")
except OSError:
    sys.exit(1)
with fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("isSidechain"):
            continue
        msg = entry.get("message") or {}
        # Agent path: Skill tool_use naming either skill.
        if msg.get("role") == "assistant":
            for block in msg.get("content") or []:
                if (isinstance(block, dict)
                        and block.get("type") == "tool_use"
                        and block.get("name") == "Skill"
                        and (block.get("input") or {}).get("skill") in SKILLS):
                    sys.exit(0)
        # User path: slash command stored as a <command-name> wrapper.
        if entry.get("type") == "user":
            content = msg.get("content")
            if isinstance(content, str) and any(s in content for s in SLASHES):
                sys.exit(0)
sys.exit(1)
PY
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
