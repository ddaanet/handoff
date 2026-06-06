#!/usr/bin/env bash
# SessionStart hook for handoff loading. Fires on `startup` and
# `clear` (see hooks/hooks.json). Gates on .claude/handoff-task.md:
#   - reads the session pointer from .claude/handoff-session
#   - calls extract.py (stdout) to assemble the frame in memory
#   - emits the assembled frame via hookSpecificOutput.additionalContext
#     so the fresh agent sees the handoff in its input for this turn;
#   - emits a curt systemMessage with content size + task file age.
# Silent no-op when the task file is missing or empty. Errors are
# logged to .claude/handoff-error.log; the hook exits 0 either way so
# a failure never blocks session startup.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

input="$(cat)"
cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
hook_event="$(jq -r '.hook_event_name // "SessionStart"' <<<"$input")"

task="$cwd/$HANDOFF_REL_TASK"
pointer="$cwd/$HANDOFF_REL_SESSION"
log="$cwd/$HANDOFF_REL_ERR"
script_dir="$(cd "$(dirname "$0")" && pwd)"

# Gate on the agent-authored task file. No task file → nothing to inject.
[[ -s "$task" ]] || exit 0

# Pointer → prior session JSONL. Missing/stale pointer degrades to task-only
# (extract.py treats an empty/absent transcript as "no session data").
jsonl=""
if [[ -s "$pointer" ]]; then
    jsonl="$(<"$pointer")"
    [[ -f "$jsonl" ]] || jsonl=""
fi

if ! assembled="$(python3 "$script_dir/extract.py" "$jsonl" "$task" 2>"$log")"; then
    tail_excerpt=$(tail -c 400 "$log" 2>/dev/null | tr '\n' ' ') || true
    jq -nc --arg log "$log" --arg tail "$tail_excerpt" \
        '{systemMessage: ("handoff load failed (see " + $log + "): " + $tail)}'
    exit 0
fi
rm -f "$log"

bytes=${#assembled}
if (( bytes < 1024 )); then
    size="${bytes} B"
else
    size=$(awk -v b="$bytes" 'BEGIN { printf "%.1f KiB", b/1024 }')
fi

mtime=$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$task")
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
