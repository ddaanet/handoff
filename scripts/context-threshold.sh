#!/usr/bin/env bash
# PostToolBatch: nudge the agent across a boundary once this session's prompt
# has grown past a threshold.
#
# A turn that runs long has no boundary at which anything can notice — Stop and
# UserPromptSubmit fire only at turn boundaries, which is exactly what a
# runaway turn escapes. PostToolBatch fires once per assistant message, the
# session log's own granularity: one API call, one usage sample. Its
# additionalContext reaches the model on the next call of the same turn.
#
# What this buys is context quality and cost, not survival: the non-Haiku
# windows are 1M and auto-compaction is expected off, so there is no wall to
# race. A prompt at 150k is worth compacting because attention and price say
# so, and the plugin can cross that boundary carrying the task frame and a
# memory flush where an untended session would just keep growing.
#
# Not cwd-scoped — the only hook that is not. It reads the transcript named in
# its own payload and writes one marker under the pointer directory, so it
# resolves no root and spawns no python3. NFR2: this fires on every tool batch
# of every session with the plugin installed.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

{ read -r agent_id; read -r session_id; read -r transcript; } < <(
    jq -r '.agent_id // "", .session_id // "", .transcript_path // ""'
)

# A subagent has no boundary to prepare and nothing that survives one, so the
# directive below would name a remedy it cannot act on. Its own usage lives in
# <session-dir>/subagents/agent-<agent_id>.jsonl; transcript_path here points
# at the parent, whose newest sample is stale for the duration of the subagent.
[[ -z "$agent_id" ]] || exit 0

[[ -n "$session_id" ]] || exit 0

# Fire once per climb, and gate on it before touching the transcript. Still
# over threshold means the boundary has not happened yet; re-injecting every
# batch would burn the context the nudge exists to conserve. session-pointer.sh
# clears this at the next SessionStart, which is the harness-authoritative
# signal that the context was rebuilt.
marker="$(handoff_context_path "$session_id")"
[[ ! -e "$marker" ]] || exit 0

[[ -n "$transcript" && -f "$transcript" ]] || exit 0

# The newest usage sample in the tail window. `inputs` with `fromjson? // empty`
# skips the partial line tail -c lands on, and `last` — rather than a sum — is
# what makes the repeated message id harmless: the several JSONL entries of one
# API response each repeat the same usage.
size="$(
    tail -c "${HANDOFF_CONTEXT_WINDOW:-262144}" "$transcript" |
        jq -Rn '[inputs
                 | fromjson? // empty
                 | select(.message.usage)
                 | .message.usage
                 | (.input_tokens // 0)
                   + (.cache_creation_input_tokens // 0)
                   + (.cache_read_input_tokens // 0)]
                | last // empty'
)"
[[ -n "$size" ]] || exit 0

threshold="${HANDOFF_CONTEXT_THRESHOLD:-150000}"
(( size >= threshold )) || exit 0

mkdir -p "$HANDOFF_POINTER_DIR"
: > "$marker"

# Lead the user-facing line with a style reset: a compaction that appears to
# start on its own needs a stated cause, and the hook chatter it sits among is
# rendered dimmed.
jq -nc --arg lead $'\033[0m' \
    --arg brief "context ${size}, past ${threshold}" \
    --arg note "This session's prompt reached ${size} tokens, past the ${threshold} handoff threshold. Finish the step you are on, then run /handoff:compact-continue." '{
    systemMessage: ($lead + "handoff: " + $brief + " — asked the agent to run compact-continue."),
    hookSpecificOutput: {
        hookEventName: "PostToolBatch",
        additionalContext: $note
    }
}'
