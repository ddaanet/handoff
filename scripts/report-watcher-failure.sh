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
#    inferred from a file still in state `pending`, which is legitimate for the
#    whole Stop -> transition window.
#
# 2. An autodrive that outlived its turn. The file is armed at the Stop of the
#    turn that writes it, and Stop leaves it `pending` or removes it, so one
#    still in state `armed` when a later turn begins never armed: that turn
#    ended abnormally (Esc — Stop does not fire on an interrupt — or a crash,
#    or a quit). Left on disk it is armed by the next Stop that does fire, days
#    later and possibly in an unrelated session, driving a stale transition
#    into work it was never written for. UserPromptSubmit is the exact
#    discriminator: it cannot fire between the write and that turn's own Stop.
#    (Prose injected into a still-running turn is the one exception, and it
#    fails safe — the transition is cancelled and said so, not deferred.)
#
# 3. A session cwd that left the launch repo. Everything derived from cwd —
#    the environment block's working directory, gitStatus, the project
#    CLAUDE.md — follows it; the transcript, the scratchpad,
#    CLAUDE_PROJECT_DIR and every handoff file do not. Nothing announces the
#    split, and it is silent in both directions: the agent reasons about the
#    repo under cwd while the plugin reads and writes the one under the root.
#
# UserPromptSubmit rather than Stop: the walker runs *after* the Stop that
# spawned it, so the next Stop is a whole turn later. It also fires on every
# prompt, so the no-file path must be silent and cheap.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

{ read -r hook_cwd; read -r session_id; } < <(
    jq -r '.cwd // "", .session_id // ""'
)
handoff_root_read "$hook_cwd"
cwd="$HANDOFF_ROOT"
[[ -n "$cwd" ]] || exit 0

msgs=()
notes=()

# Drift is reported here rather than at some later gate because it can be
# transient: a check that asks "is cwd foreign now?" after the fact sees
# nothing, while the writer/reader split was live for the whole blip. This hook
# already resolves the root every turn and already owns a reporting channel.
#
# Once per episode: the marker holds the destination last announced, so a
# second turn in the same place is silent and a move somewhere else is not
# swallowed. It is cleared on the way back in, so a re-drift is a new episode
# rather than a repeat.
marker="$HANDOFF_POINTER_DIR/handoff-drift-$session_id"
case "$HANDOFF_ROOT_BRANCH" in
    foreign | unrelated)
        last=""
        if [[ -f "$marker" ]]; then
            last="$(head -n1 "$marker")"
        fi
        if [[ "$last" != "$hook_cwd" ]]; then
            mkdir -p "$HANDOFF_POINTER_DIR"
            printf '%s\n' "$hook_cwd" > "$marker"
            msgs+=("session cwd left the launch repo — now $hook_cwd, handoff root stays $cwd")
            notes+=("The session cwd is $hook_cwd, outside the launch repo $cwd. Everything derived from cwd describes $hook_cwd — the environment block's working directory, the gitStatus block, the project CLAUDE.md. The transcript, the scratchpad, CLAUDE_PROJECT_DIR and every handoff file are under $cwd.")
        fi
        ;;
    *)
        rm -f "$marker"
        ;;
esac

failed="$cwd/$HANDOFF_REL_DRIVE_FAILED"
drive="$cwd/$HANDOFF_REL_DRIVE"

# Parse once: the failure branch and the sweep want different states of the same
# file. A file that will not parse is recorded as its own value — it describes
# no transition anyone can complete, so the sweep takes it.
drive_state=""
if [[ -f "$drive" ]]; then
    if handoff_drive_read "$drive"; then
        drive_state="$DRIVE_STATE"
    else
        drive_state="malformed"
    fi
fi

if [[ -f "$failed" ]]; then
    reason="$(head -n1 "$failed")"
    rm -f "$failed"
    # A failure part-way through a sequence strands the transition in `pending`:
    # nothing will consume it (its SessionStart never fires) and Stop will not
    # re-arm from that state. Clear it with the report. Only here — a stale
    # armed file says nothing about one in flight, and sweeping on that evidence
    # would race a live SessionStart(compact|clear).
    if [[ "$drive_state" == "pending" ]]; then
        rm -f "$drive"
    fi
    msgs+=("transition watcher did not deliver — $reason")
    notes+=("The handoff transition watcher failed to deliver its line: $reason. The transition or continuation it was driving did not happen, and any lines after it in the sequence were never typed.")
fi

# An autodrive is armed at the Stop of the turn that writes it, and that Stop
# leaves it `pending` or removes it. So one still in state `armed` when a later
# turn begins never armed.
if [[ -n "$drive_state" && "$drive_state" != "pending" ]]; then
    rm -f "$drive"
    msgs+=("stale autodrive discarded — its turn ended without arming")
    notes+=("A .claude/autodrive file was still on disk when this turn began, and this session cannot act on it: either its Stop never fired to arm it — that turn ended on an interrupt, a crash or a quit — or it does not parse in this version's format. Either way it has been discarded, so the transition it described did not happen and cannot fire into unrelated work later.")
fi

(( ${#msgs[@]} > 0 )) || exit 0

printf -v msg '%s; ' "${msgs[@]}"
printf -v note '%s ' "${notes[@]}"

# Lead with a style reset. This hook speaks only when something went wrong, and
# the ordinary hook chatter it sits among is rendered dimmed.
jq -nc --arg m "${msg%; }" --arg n "${note% }" --arg lead $'\033[0m' '{
    systemMessage: ($lead + "handoff: " + $m + "."),
    hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: $n
    }
}'
