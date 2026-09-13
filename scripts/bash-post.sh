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

emit() {
    jq -nc --arg s "$1" --arg c "$2" \
        '{systemMessage: $s, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
}

# A root that is not a git repository is the environment, not a defect: nothing
# can be staged, and nothing is wrong with the checkpoint that wrote the
# manifest. Without this check every line fails its own `git add` and one fact
# is reported once per path, in the wording reserved for breakage and with a
# remedy naming a repository that does not exist. The manifest is consumed all
# the same: there is no staging here to lose, and a later checkpoint composes a
# fresh one. The `2>/dev/null` is the one kind this file keeps — provoking
# `fatal: not a git repository` is this check's whole mechanism, and the branch
# below is what speaks for that message.
if ! git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    rm -f "$manifest"
    emit "handoff-checkpoint: nothing staged, $cwd is not a git repository" \
        "checkpoint manifest consumed — nothing staged: $cwd is not a git repository. The task and todo files are written; only staging them needs one."
    exit 0
fi

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
    #
    # ls-files *itself* failing is not that case — a repo `git add` could not
    # have staged into either — so it is reported rather than swallowed. The
    # branch is load-bearing: a failed command substitution does not trip
    # `set -e` from inside a `[ ]` test, so folded into one condition its empty
    # output reads as "never in the index" and skips the path silently, which
    # is the exact swallow this item exists to remove.
    if [ "$op" = "D" ]; then
        if ! indexed="$(git -C "$cwd" ls-files -- "$rel")"; then
            failed+=("$rel")
            continue
        fi
        [ -n "$indexed" ] || continue
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
# deleted 0" on both channels. Naming the path on both channels is the whole
# report: a PostToolUse hook's stderr on exit 0 reaches neither audience. It is
# recorded on a `hook_success` transcript attachment, which carries no
# `rendered` field and so is neither echoed to the user nor injected into the
# model's context — unlike `additionalContext`, which arrives as its own,
# rendered attachment (verified against CC 2.1.270). One spelling on both
# channels, since the counts alone cannot say which path it was and two
# wordings of one fact read as two facts.
#
# `${failed[*]}` joins on a space, which would be ambiguous for a path holding
# one. It cannot: checkpoint.py composes every manifest line from its two path
# constants and the payload no longer carries a `file_path`, so the only names
# that reach here are `.claude/handoff-task.md` and `.claude/handoff-todo.md`.
# Same bound as the `${staged[*]}` / `${deleted[*]}` joins above.
#
# The manifest is consumed either way, so a failure costs the staging outright:
# retrying here would re-run the same `git add` against the same stranded lock,
# and nothing downstream stages these paths. The remedy therefore rides the
# agent channel alone — it is an act, and an act belongs where something can
# perform it; the user channel carries the fact.
if [ ${#failed[@]} -gt 0 ]; then
    summary="$summary; failed to stage: ${failed[*]}"
    agent_ctx="$agent_ctx; failed to stage: ${failed[*]} — stage with git add -f before the next commit"
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

emit "$summary" "$agent_ctx"
