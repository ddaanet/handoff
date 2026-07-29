#!/usr/bin/env bash
# SessionStart hook for handoff loading. Fires on `startup` and
# `clear` (see hooks/hooks.json). Gates on .claude/handoff-task.md:
#   - assembles the frame in memory — a timestamp header plus the
#     inlined agent-authored task file;
#   - emits the frame via hookSpecificOutput.additionalContext so the
#     fresh agent sees the handoff in its input for this turn;
#   - emits a curt systemMessage with content size + task file age.
# Silent no-op when the task file is missing or empty. The hook exits 0
# on every path so it never blocks session startup.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

{ read -r hook_cwd; read -r hook_event; } < <(
    jq -r '.cwd // "", .hook_event_name // "SessionStart"'
)
cwd="$(handoff_root "$hook_cwd")"

task="$cwd/$HANDOFF_REL_TASK"
todo="$cwd/$HANDOFF_REL_TODO"

# The frame is the header plus the agent-authored files inlined verbatim, and
# it gates itself: either file alone is enough, neither means nothing to
# inject. The prior session's working set is served by the harness's own
# gitStatus block, not reproduced here (see
# docs/changelog/2026-07-17-task-frame-drops-transcript.md).
assembled="$(handoff_frame "$task" "$todo")" || exit 0

bytes=${#assembled}
if (( bytes < 1024 )); then
    size="${bytes} B"
else
    size=$(awk -v b="$bytes" 'BEGIN { printf "%.1f KiB", b/1024 }')
fi

# Age of the frame is the newest of whichever files it drew on — the frame
# assembled, so at least one of them exists.
mtime=$(python3 -c 'import os,sys
print(int(max(os.path.getmtime(p) for p in sys.argv[1:] if os.path.exists(p))))' \
    "$task" "$todo")
now=$(date +%s)
delta=$(( now - mtime ))
if (( delta < 60 )); then age="just now"
elif (( delta < 3600 )); then age="$((delta / 60))m ago"
elif (( delta < 86400 )); then age="$((delta / 3600))h ago"
else age="$((delta / 86400))d ago"
fi

msg="handoff loaded — ${size}, saved ${age}"

jq -nc \
    --arg m "$msg" \
    --arg c "$assembled" \
    --arg e "$hook_event" \
    '{systemMessage: $m, hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
