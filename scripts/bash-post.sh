#!/usr/bin/env bash
# PostToolUse(Bash) hook: consumes .claude/checkpoint-manifest, which
# handoff-checkpoint (scripts/checkpoint.sh) leaves behind because its own
# invocation runs in the agent's sandboxed Bash, where NFR1 forbids both git
# staging (a sandboxed `git add` can strand .git/index.lock) and tmux (the
# rename watcher's socket is unreachable there).
#
# This hook fires on every Bash call in every session with the plugin
# installed (NFR2) — the checkpoint runs once per wrap-up, so the negative
# case (manifest absent) is nearly every call. The raw session cwd is stat'd
# directly first; the worktree-aware root resolution (a python3 spawn, via
# handoff_root) is deferred to the rare positive path so the hot path stays
# one jq parse plus one stat.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

json="$(cat)"
raw_cwd="$(jq -r '.cwd // empty' <<<"$json")"
[ -n "$raw_cwd" ] || exit 0
[ -f "$raw_cwd/.claude/checkpoint-manifest" ] || exit 0

cwd="$(handoff_root "$raw_cwd")"
manifest="$cwd/.claude/checkpoint-manifest"
[ -f "$manifest" ] || exit 0

staged=()
deleted=()
while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    op="${line%% *}"
    rel="${line#* }"
    if git -C "$cwd" add -f -- "$rel" 2>/dev/null; then
        if [ "$op" = "D" ]; then
            deleted+=("$rel")
        else
            staged+=("$rel")
        fi
    fi
done < "$manifest"
rm -f "$manifest"

# Consume .claude/autorename the same way write-rename.sh does for the
# Write-tool path — the checkpoint wrote it with a plain redirect, so no
# PostToolUse(Write|Edit) fired for it, and this is the only hook context
# that will.
rename_note=""
rename_file="$cwd/$HANDOFF_REL_RENAME"
if [ -f "$rename_file" ]; then
    title="$(tr -s '[:space:]' ' ' < "$rename_file")"
    title="${title## }"; title="${title%% }"
    rm -f "$rename_file"
    if [ -n "${title// /}" ]; then
        if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
            export HANDOFF_FAIL_FILE="$cwd/$HANDOFF_REL_RENAME_FAILED"
            handoff_spawn_detached rename-when-idle.sh "$TMUX_PANE" "$title"
            rename_note="will rename to \"$title\" once prompt is idle (tmux pane $TMUX_PANE)"
        else
            rename_note="not in tmux — paste to rename: /rename $title"
        fi
    fi
fi

summary="handoff-checkpoint: staged ${#staged[@]}, deleted ${#deleted[@]}"
[ -n "$rename_note" ] && summary="$summary; $rename_note"
agent_ctx="checkpoint manifest consumed — staged: ${staged[*]:-none}; deleted: ${deleted[*]:-none}."
[ -n "$rename_note" ] && agent_ctx="$agent_ctx $rename_note."

jq -nc --arg s "$summary" --arg c "$agent_ctx" \
    '{systemMessage: $s, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
