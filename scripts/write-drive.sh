#!/usr/bin/env bash
# PostToolUse(Write|Edit): validate .claude/autodrive the moment the agent
# writes it. VALIDATE ONLY — never spawns a watcher, never deletes the file.
# The file must survive to Stop, which is the hook that arms the transition.
#
# Reporting the problem here rather than at Stop means the agent can rewrite
# the file in the same turn instead of discovering a silent no-op after the
# turn ends. This is a DIRECTIVE channel (the agent is meant to act on it), so
# the wording is imperative — unlike the deny channels in write-guard.sh.
#
# Path matching is the consume-time cross-project guard: no PreToolUse guard
# and no activation gate, because the file is ephemeral and untracked.
#
# The legal shapes are not restated here. handoff_drive_read names the
# constraint that failed, and the skill body that wrote the file is the single
# source of truth for the format. One rule IS enforced here, because no skill
# body owns it: this channel is arm-only. handoff_drive_read accepts both
# `armed` and `pending` — which state a caller wants is the caller's business —
# but a `pending` the agent wrote is inert on every gate downstream, so this is
# the one place that has to reject it.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

handoff_match_target "$(cat)" "autodrive" "$HANDOFF_REL_DRIVE" || exit 0
[[ -f "$target" ]] || exit 0

if ! handoff_drive_read "$target"; then
    err="$DRIVE_ERR"
elif [[ "$DRIVE_STATE" != "armed" ]]; then
    # Arm-only: every later state is a hook's to write. The parser accepts them
    # all — which state a caller wants is the caller's business — and this
    # caller is the agent-authored channel.
    err="line 1 must be \`armed\` — every state after that is written by a hook, not by an agent"
else
    exit 0
fi

jq -nc --arg e "$err" '{
    systemMessage: ("handoff: autodrive malformed — " + $e + "; transition not armed."),
    hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: ("The .claude/autodrive file is malformed: " + $e + ". Rewrite it now. Until it is well-formed the transition will not be armed at the end of this turn.")
    }
}'
