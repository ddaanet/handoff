#!/usr/bin/env bash
# PostToolUse(Bash) hook: consumes .claude/checkpoint-manifest, which
# handoff-checkpoint (scripts/checkpoint.py) leaves behind because its own
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
failed=()
while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    op="${line%% *}"
    rel="${line#* }"
    # A `D` line for a path that never entered the index is the expected,
    # benign case, and the only one the old 2>/dev/null was carrying that is
    # not a real failure: both paths are gitignored, so nothing but this hook
    # ever stages them, and any `git reset` since the last checkpoint — or a
    # file the user wrote by hand — leaves one on disk but untracked. `git add
    # -f` exits 128 there with "did not match any files". Guard it away rather
    # than redirecting, so whatever still reaches stderr is a genuine failure.
    # Not `ls-files --error-unmatch`, which writes its own message to stderr
    # and would need back the very redirect this removes.
    if [ "$op" = "D" ] && [ -z "$(git -C "$cwd" ls-files -- "$rel")" ]; then
        continue
    fi
    if git -C "$cwd" add -f -- "$rel"; then
        if [ "$op" = "D" ]; then
            deleted+=("$rel")
        else
            staged+=("$rel")
        fi
    else
        failed+=("$rel")
    fi
done < "$manifest"
rm -f "$manifest"

summary="handoff-checkpoint: staged ${#staged[@]}, deleted ${#deleted[@]}"
agent_ctx="checkpoint manifest consumed — staged: ${staged[*]:-none}; deleted: ${deleted[*]:-none}"

# A path that could not be staged used to vanish from the counts with git's own
# explanation eaten by the redirect — a stranded index.lock read as "staged 0,
# deleted 0" on both channels. git's stderr now reaches the user; this names
# which path it was, on both channels and in one spelling, since the counts
# alone cannot say and two wordings of one fact read as two facts.
if [ ${#failed[@]} -gt 0 ]; then
    summary="$summary; failed to stage: ${failed[*]}"
    agent_ctx="$agent_ctx; failed to stage: ${failed[*]}"
fi
agent_ctx="$agent_ctx."

# Both paths are gitignored, so this add -f is the only staging they ever get —
# there is no later step at either boundary or under either commit mode. An
# agent composing an unrelated commit therefore meets them already in the index;
# without this clause it reads that as a stray add and unstages the artifact the
# boundary exists to produce. Suppressed when nothing was staged (a rename-only
# call leaves an empty manifest), where it would describe nothing.
if [ $(( ${#staged[@]} + ${#deleted[@]} )) -gt 0 ]; then
    agent_ctx="$agent_ctx Leave them staged; whatever commit lands next carries them."
fi

jq -nc --arg s "$summary" --arg c "$agent_ctx" \
    '{systemMessage: $s, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
