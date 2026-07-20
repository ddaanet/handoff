#!/usr/bin/env bash
# UserPromptSubmit: surface a compaction watcher's non-delivery.
#
# The watchers are detached, so their exit status goes nowhere. Left alone, a
# line that never lands is silent — worst on the compact watcher's C-u abort,
# which wipes the composer and leaves the pane looking untouched while the agent
# carries on believing it armed a compaction. The watcher writes the reason to
# .claude/autocompact.failed; this reads it at the first moment anything can act
# on it.
#
# UserPromptSubmit rather than Stop: a watcher runs *after* the Stop that spawned
# it, so the next Stop is a whole turn later. It also fires on every prompt, so
# the no-file path must be silent and cheap.
#
# The file is written only on paths the watcher observed itself — never inferred
# from a stale .pending, whose presence is legitimate for the whole Stop ->
# compaction window.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

hook_cwd="$(jq -r '.cwd // ""')"
cwd="$(handoff_root "$hook_cwd")"
[[ -n "$cwd" ]] || exit 0

failed="$cwd/$HANDOFF_REL_COMPACT_FAILED"
[[ -f "$failed" ]] || exit 0

reason="$(head -n1 "$failed")"
rm -f "$failed"

# A line-1 failure strands the armed file as .pending: nothing will consume it
# (SessionStart(compact) never fires) and Stop cannot re-arm from it, since it
# gates on .claude/autocompact. Clear it with the report.
rm -f "$cwd/$HANDOFF_REL_COMPACT_PENDING"

jq -nc --arg r "$reason" '{
    systemMessage: ("handoff: compaction watcher did not deliver — " + $r + "."),
    hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: ("The handoff compaction watcher failed to deliver its line: " + $r + ". The compaction or continuation it was driving did not happen.")
    }
}'
