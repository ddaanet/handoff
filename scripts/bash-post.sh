#!/usr/bin/env bash
# PostToolUse(Bash) hook: consumes .claude/checkpoint-manifest, which
# handoff-checkpoint (scripts/checkpoint.sh) leaves behind because its own
# invocation runs in the agent's sandboxed Bash, where NFR1 forbids git staging
# (a sandboxed `git add` can strand .git/index.lock).
#
# Staging is all it does. A sentinel the checkpoint writes needs nothing from
# this hook: it is armed at Stop like any other, by stop-drive.sh.
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

summary="handoff-checkpoint: staged ${#staged[@]}, deleted ${#deleted[@]}"
agent_ctx="checkpoint manifest consumed — staged: ${staged[*]:-none}; deleted: ${deleted[*]:-none}."

jq -nc --arg s "$summary" --arg c "$agent_ctx" \
    '{systemMessage: $s, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
