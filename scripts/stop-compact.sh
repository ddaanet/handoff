#!/usr/bin/env bash
# Stop: arm the compaction. Fires when the main loop has actually finished the
# turn — the only point at which typing a slash command means what this design
# assumes. A watcher spawned mid-turn has no safe idle window to find (see
# DESIGN.md, "Mid-turn TUI input").
#
# Stop fires on every turn, so the no-file path must be silent and cheap.
# Stop does NOT fire on an Esc interrupt, so an interrupted turn cannot arm the
# compaction — the fail-safe direction, for free.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

script_dir="$(cd "$(dirname "$0")" && pwd)"

# Stop input carries no tool_input; only .cwd is needed.
hook_cwd="$(jq -r '.cwd // ""')"
cwd="$(handoff_root "$hook_cwd")"
[[ -n "$cwd" ]] || exit 0

armed="$cwd/$HANDOFF_REL_COMPACT"
pending="$cwd/$HANDOFF_REL_COMPACT_PENDING"

[[ -f "$armed" ]] || exit 0

if ! handoff_compact_read "$armed"; then
    # write-compact.sh already told the agent in-turn; consuming the file here
    # stops the same complaint from repeating at every subsequent Stop.
    rm -f "$armed"
    jq -nc --arg e "$COMPACT_ERR" \
        '{systemMessage: ("handoff: autocompact malformed — " + $e + "; discarded, compaction not armed.")}'
    exit 0
fi

# Rename BEFORE spawning: a later Stop in this session must not re-arm.
mv -f "$armed" "$pending"

if [[ -z "${TMUX:-}" || -z "${TMUX_PANE:-}" ]]; then
    rm -f "$pending"
    jq -nc --arg c "$COMPACT_L1" --arg n "$COMPACT_L2" '{
        systemMessage: "handoff: not in tmux — compaction not driven; lines emitted to paste.",
        hookSpecificOutput: {
            hookEventName: "Stop",
            additionalContext: ("Automatic compaction is unavailable (not in tmux). Present these two lines to the user in a fenced code block, to run in order:\n" + $c + "\n" + $n)
        }
    }'
    exit 0
fi

PANE="$TMUX_PANE"
# setsid is Linux-only; nohup is the POSIX fallback so the watcher outlives the
# hook on macOS too. Same detach dance as write-rename.sh.
if command -v setsid >/dev/null 2>&1; then
    setsid bash "$script_dir/compact-when-idle.sh" "$PANE" "$COMPACT_L1" >/dev/null 2>&1 &
else
    nohup bash "$script_dir/compact-when-idle.sh" "$PANE" "$COMPACT_L1" >/dev/null 2>&1 &
fi
disown 2>/dev/null || true

jq -nc --arg c "$COMPACT_L1" --arg p "$PANE" \
    '{systemMessage: ("handoff: will run \"" + $c + "\" once the prompt is idle (tmux pane " + $p + "), then resume.")}'
