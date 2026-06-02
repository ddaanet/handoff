#!/usr/bin/env bash
# SessionStart hook for handoff loading. Fires on `startup` and
# `clear` (see hooks/hooks.json). Reads $cwd/.claude/handoff.md and:
#   - emits its contents via hookSpecificOutput.additionalContext so
#     the fresh agent sees the handoff in its input for this turn;
#   - emits a curt systemMessage with file size + age for the user
#     ("handoff loaded — 3.2 KiB, saved 8m ago").
# Silent no-op when handoff.md is missing or empty. Errors are logged
# to .claude/handoff-error.log; the hook exits 0 either way so a
# failure never blocks session startup.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

input="$(cat)"
cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
hook_event="$(jq -r '.hook_event_name // "SessionStart"' <<<"$input")"

handoff_maybe_use_gitlore "$cwd"

handoff="$cwd/$HANDOFF_REL_OUT"
log="$cwd/$HANDOFF_REL_ERR"

[[ -s "$handoff" ]] || exit 0

if ! cat "$handoff" >/dev/null 2>"$log"; then
    tail=$(tail -c 400 "$log" 2>/dev/null | tr '\n' ' ')
    jq -nc --arg log "$log" --arg tail "$tail" \
        '{systemMessage: ("handoff load failed (see " + $log + "): " + $tail)}'
    exit 0
fi
rm -f "$log"

bytes=$(wc -c < "$handoff" | tr -d ' ')
if (( bytes < 1024 )); then
    size="${bytes} B"
else
    size=$(awk -v b="$bytes" 'BEGIN { printf "%.1f KiB", b/1024 }')
fi

# GNU/BSD stat are incompatible; use python3 like the sibling write hooks.
mtime=$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$handoff")
now=$(date +%s)
delta=$(( now - mtime ))
if (( delta < 60 )); then
    age="just now"
elif (( delta < 3600 )); then
    age="$((delta / 60))m ago"
elif (( delta < 86400 )); then
    age="$((delta / 3600))h ago"
else
    age="$((delta / 86400))d ago"
fi

msg="handoff loaded — ${size}, saved ${age}"

jq -nc \
    --arg m "$msg" \
    --rawfile c "$handoff" \
    --arg e "$hook_event" \
    '{systemMessage: $m, hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
