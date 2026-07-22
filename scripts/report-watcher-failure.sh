#!/usr/bin/env bash
# UserPromptSubmit: reconcile watcher and compaction state at the start of a
# turn, and report anything that went wrong in the last one.
#
# 1. A watcher's non-delivery. The watchers are detached, so their exit status
#    goes nowhere. Left alone, a line that never lands is silent — worst on the
#    compact watcher's C-u abort, which wipes the composer and leaves the pane
#    looking untouched while the agent carries on believing it armed a
#    compaction, and on the rename watcher's composing-bail, which leaves
#    write-rename.sh's "will rename once idle" promise standing forever. Each
#    watcher writes its reason to a file named for the line it was driving
#    (.claude/autocompact.failed, .claude/autorename.failed); this reads them at
#    the first moment anything can act on them. They are written only on paths a
#    watcher observed itself — never inferred from a stale .pending, whose
#    presence is legitimate for the whole Stop -> compaction window.
#
# 2. An autocompact that outlived its turn. The file is armed at the Stop of
#    the turn that writes it, and Stop renames it to .pending. So one still
#    present when a *later* turn begins never armed: that turn ended abnormally
#    (Esc — Stop does not fire on an interrupt — or a crash, or a quit). Left on
#    disk it is armed by the next Stop that does fire, days later and possibly
#    in an unrelated session, driving a stale /compact and a stale continuation
#    prompt into work they were never written for. UserPromptSubmit is the exact
#    discriminator: it cannot fire between the write and that turn's own Stop.
#    (Prose injected into a still-running turn is the one exception, and it
#    fails safe — the compaction is cancelled and said so, not deferred.)
#
# UserPromptSubmit rather than Stop: a watcher runs *after* the Stop that spawned
# it, so the next Stop is a whole turn later. It also fires on every prompt, so
# the no-file path must be silent and cheap.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

hook_cwd="$(jq -r '.cwd // ""')"
cwd="$(handoff_root "$hook_cwd")"
[[ -n "$cwd" ]] || exit 0

compact_failed="$cwd/$HANDOFF_REL_COMPACT_FAILED"
rename_failed="$cwd/$HANDOFF_REL_RENAME_FAILED"
armed="$cwd/$HANDOFF_REL_COMPACT"
[[ -f "$compact_failed" || -f "$rename_failed" || -f "$armed" ]] || exit 0

msgs=()
notes=()

if [[ -f "$compact_failed" ]]; then
    reason="$(head -n1 "$compact_failed")"
    rm -f "$compact_failed"
    # A line-1 failure strands the armed file as .pending: nothing will consume
    # it (SessionStart(compact) never fires) and Stop cannot re-arm from it,
    # since it gates on .claude/autocompact. Clear it with the report. Only
    # here — neither a rename failure nor a stale autocompact says anything
    # about a .pending, and sweeping one on that evidence would race a live
    # SessionStart(compact).
    rm -f "$cwd/$HANDOFF_REL_COMPACT_PENDING"
    msgs+=("compaction watcher did not deliver — $reason")
    notes+=("The handoff compaction watcher failed to deliver its line: $reason. The compaction or continuation it was driving did not happen.")
fi

if [[ -f "$rename_failed" ]]; then
    reason="$(head -n1 "$rename_failed")"
    rm -f "$rename_failed"
    msgs+=("rename watcher did not deliver — $reason")
    notes+=("The handoff rename watcher failed to deliver its line: $reason. The session was not renamed.")
fi

if [[ -f "$armed" ]]; then
    rm -f "$armed"
    msgs+=("stale autocompact discarded — its turn ended without arming")
    notes+=("A .claude/autocompact file was still on disk when this turn began. It is armed at the Stop of the turn that writes it, so one surviving into a later turn never armed — that turn ended on an interrupt, a crash or a quit. It has been discarded, so the compaction it described did not happen and cannot fire into unrelated work later.")
fi

printf -v msg '%s; ' "${msgs[@]}"
printf -v note '%s ' "${notes[@]}"

jq -nc --arg m "${msg%; }" --arg n "${note% }" '{
    systemMessage: ("handoff: " + $m + "."),
    hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: $n
    }
}'
