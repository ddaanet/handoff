#!/usr/bin/env bash
# SessionStart(compact): fire the continuation. `source: "compact"` is the
# authoritative compaction-complete signal — no pane-marker scraping, and it
# also covers a compaction that finishes too fast to observe as a busy->idle
# transition.
#
# The hook fires for auto-compaction too, so the no-pending path must be silent.
#
# Line 2 is TYPED as an ordinary prompt at idle, not injected as
# additionalContext: additionalContext is context, not a prompt, and cannot
# start a turn. Typing it means it drains as its own turn and fires
# UserPromptSubmit normally.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

script_dir="$(cd "$(dirname "$0")" && pwd)"

hook_cwd="$(jq -r '.cwd // ""')"
cwd="$(handoff_root "$hook_cwd")"
[[ -n "$cwd" ]] || exit 0

pending="$cwd/$HANDOFF_REL_COMPACT_PENDING"
[[ -f "$pending" ]] || exit 0

if ! handoff_compact_read "$pending"; then
    rm -f "$pending"
    jq -nc --arg e "$COMPACT_ERR" \
        '{systemMessage: ("handoff: autocompact.pending malformed — " + $e + "; not resuming.")}'
    exit 0
fi

# Consume unconditionally: the continuation fires at most once per compaction.
rm -f "$pending"

if [[ -z "${TMUX:-}" || -z "${TMUX_PANE:-}" ]]; then
    jq -nc --arg n "$COMPACT_L2" '{
        systemMessage: "handoff: not in tmux — continuation not typed; emitted to paste.",
        hookSpecificOutput: {
            hookEventName: "SessionStart",
            additionalContext: ("Compaction finished, but the continuation prompt could not be typed (not in tmux). Present this line to the user in a fenced code block so they can paste it:\n" + $n)
        }
    }'
    exit 0
fi

PANE="$TMUX_PANE"
if command -v setsid >/dev/null 2>&1; then
    setsid bash "$script_dir/continue-when-idle.sh" "$PANE" "$COMPACT_L2" >/dev/null 2>&1 &
else
    nohup bash "$script_dir/continue-when-idle.sh" "$PANE" "$COMPACT_L2" >/dev/null 2>&1 &
fi
disown 2>/dev/null || true

jq -nc --arg n "$COMPACT_L2" --arg p "$PANE" \
    '{systemMessage: ("handoff: compacted — will resume with \"" + $n + "\" once the prompt is idle (tmux pane " + $p + ").")}'
