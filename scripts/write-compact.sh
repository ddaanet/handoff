#!/usr/bin/env bash
# PostToolUse(Write|Edit): validate .claude/autocompact the moment the agent
# writes it. VALIDATE ONLY — never spawns a watcher, never deletes the file.
# The file must survive to Stop, which is the hook that arms the compaction.
#
# Reporting the problem here rather than at Stop means the agent can rewrite
# the file in the same turn instead of discovering a silent no-op after the
# turn ends. This is a DIRECTIVE channel (the agent is meant to act on it), so
# the wording is imperative — unlike the deny channels in write-guard.sh.
#
# Path matching is the consume-time cross-project guard, exactly as in
# write-rename.sh: no PreToolUse guard and no activation gate, because the file
# is ephemeral and untracked.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

handoff_hook_fields "$(cat)"
[[ -n "$HOOK_FILE_PATH" ]] || exit 0
[[ "$(basename "$HOOK_FILE_PATH")" == "autocompact" ]] || exit 0

cwd="$(handoff_root "$HOOK_CWD")"
[[ -n "$cwd" ]] || exit 0

{ read -r target; read -r expected; } < <(handoff_resolve "$HOOK_FILE_PATH" "$cwd/$HANDOFF_REL_COMPACT")
[[ "$target" == "$expected" ]] || exit 0

[[ -f "$target" ]] || exit 0

if handoff_compact_read "$target"; then
    exit 0
fi

jq -nc --arg e "$COMPACT_ERR" '{
    systemMessage: ("handoff: autocompact malformed — " + $e + "; compaction not armed."),
    hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: ("The .claude/autocompact file is malformed: " + $e + ". Rewrite it now with exactly two lines — line 1 the literal /compact command (optionally with a focus directive), line 2 the single-line continuation prompt. Until it is well-formed the compaction will not be armed at the end of this turn.")
    }
}'
