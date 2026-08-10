#!/usr/bin/env bash
# PostToolUse hook for Write|Edit. handoff-todo.md is a scratch list the
# agent edits freely all session (FR4); this is the one path the checkpoint
# never sees, so it still needs its own git add -f on every direct write.
# handoff-task.md no longer comes through here — it is checkpoint-only (FR3)
# and staged via the manifest instead.
#
# Empty-body removal mirrors handoff-checkpoint's own write semantics (FR6),
# through the same shared helper — checkpoint_lib.py's --is-empty-body CLI
# (Python; see docs/changelog/2026-08-10-python-split.md) — so the two
# writers cannot drift on what counts as empty: a todo file the agent has
# edited down to nothing (its last item struck) is removed and the removal
# staged, rather than left behind reading as "nothing pending" while still
# present. Paying a spawn here is fine — this is the cold branch, reached
# only after the basename and path match already narrowed it.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

handoff_match_target "$(cat)" "handoff-todo.md" "$HANDOFF_REL_TODO" || exit 0
[[ -f "$target" ]] || exit 0

if python3 "$(dirname "$0")/_checkpoint_lib.py" --is-empty-body < "$target"; then
    rm -f "$target"
    if git -C "$cwd" add -f -- "$HANDOFF_REL_TODO" 2>/dev/null; then
        jq -nc '{systemMessage: "handoff-todo.md emptied — removed and staged.", hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: "handoff-todo.md had no remaining items and was removed; the deletion is staged (git add -f)."}}'
    fi
    exit 0
fi

if git -C "$cwd" add -f "$target" 2>/dev/null; then
    agent_ctx="handoff-todo.md staged (git add -f) and version-tracked. The task frame enters git history paired with this handoff's gitlore memory commit, which supplies the durable context that makes the frame meaningful."
    jq -nc \
        --arg c "$agent_ctx" \
        '{systemMessage: "handoff — staged for commit", hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
fi
