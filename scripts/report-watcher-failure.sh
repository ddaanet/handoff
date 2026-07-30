#!/usr/bin/env bash
# UserPromptSubmit: reconcile the armed-transition state at the start of a turn,
# and report anything that went wrong in the last one.
#
# 1. The walker's non-delivery. It runs detached, so its exit status goes
#    nowhere. Left alone, a line that never lands is silent — worst on the
#    recognition abort, which wipes the composer and leaves the pane looking
#    untouched while the agent carries on believing it armed a transition, and
#    on the composing-bail, which leaves the arming hook's "will run once idle"
#    promise standing forever. The walker writes its reason to
#    .claude/autodrive.failed; this reads it at the first moment anything can
#    act on it. It is written only on paths the walker observed itself — never
#    inferred from a stale .pending, whose presence is legitimate for the whole
#    Stop -> transition window.
#
# 2. An autodrive that outlived its turn. The file is armed at the Stop of the
#    turn that writes it, and Stop renames or removes it. So one still present
#    when a *later* turn begins never armed: that turn ended abnormally (Esc —
#    Stop does not fire on an interrupt — or a crash, or a quit). Left on disk
#    it is armed by the next Stop that does fire, days later and possibly in an
#    unrelated session, driving a stale transition into work it was never
#    written for. UserPromptSubmit is the exact discriminator: it cannot fire
#    between the write and that turn's own Stop. (Prose injected into a
#    still-running turn is the one exception, and it fails safe — the
#    transition is cancelled and said so, not deferred.)
#
# UserPromptSubmit rather than Stop: the walker runs *after* the Stop that
# spawned it, so the next Stop is a whole turn later. It also fires on every
# prompt, so the no-file path must be silent and cheap.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

hook_cwd="$(jq -r '.cwd // ""')"
cwd="$(handoff_root "$hook_cwd")"
[[ -n "$cwd" ]] || exit 0

failed="$cwd/$HANDOFF_REL_DRIVE_FAILED"
armed="$cwd/$HANDOFF_REL_DRIVE"
[[ -f "$failed" || -f "$armed" ]] || exit 0

msgs=()
notes=()

if [[ -f "$failed" ]]; then
    reason="$(head -n1 "$failed")"
    rm -f "$failed"
    # A failure part-way through a sequence strands the armed file as .pending:
    # nothing will consume it (the transition's SessionStart never fires) and
    # Stop cannot re-arm from it, since it gates on .claude/autodrive. Clear it
    # with the report. Only here — a stale autodrive says nothing about a
    # .pending, and sweeping one on that evidence would race a live
    # SessionStart(compact|clear).
    rm -f "$cwd/$HANDOFF_REL_DRIVE_PENDING"
    msgs+=("transition watcher did not deliver — $reason")
    notes+=("The handoff transition watcher failed to deliver its line: $reason. The transition or continuation it was driving did not happen, and any lines after it in the sequence were never typed.")
fi

if [[ -f "$armed" ]]; then
    rm -f "$armed"
    msgs+=("stale autodrive discarded — its turn ended without arming")
    notes+=("A .claude/autodrive file was still on disk when this turn began. It is armed at the Stop of the turn that writes it, so one surviving into a later turn never armed — that turn ended on an interrupt, a crash or a quit. It has been discarded, so the transition it described did not happen and cannot fire into unrelated work later.")
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
