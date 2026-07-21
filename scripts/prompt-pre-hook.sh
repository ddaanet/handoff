#!/usr/bin/env bash
# UserPromptSubmit hook.
# Slash-command invocation (`/handoff:handoff`, `/handoff:precompact`)
# loads the skill body directly without a `Skill` tool call, so
# PreToolUse(Skill) does not fire on that path. This hook covers it:
# when the submitted prompt starts with either of the two skills that
# author handoff-task.md, wipe any prior handoff files so the skill
# runs against a clean slate.
#
# Mechanical work — agent is not involved. Wipe+emit is shared with
# skill-pre-hook.sh via _wipe-emit.sh; this script is just the
# slash-command-prefix filter on top.
set -euo pipefail

input="$(cat)"
prompt="$(jq -r '.prompt // ""' <<<"$input")"
[[ "$prompt" =~ ^/handoff:(handoff|precompact)([[:space:]]|$) ]] || exit 0

exec bash "$(dirname "$0")/_wipe-emit.sh" "$(jq -r '.cwd // ""' <<<"$input")" "UserPromptSubmit"
