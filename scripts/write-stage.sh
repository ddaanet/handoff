#!/usr/bin/env bash
# PostToolUse hook for Write|Edit.
# When the agent writes this project's .claude/handoff-task.md, stage it
# with `git add -f` so the versioned task trail rides the user's next
# commit. No extraction, no generated file — the frame is assembled at
# read-time by load-handoff.sh.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // ""' <<<"$input")"
[[ -n "$file_path" ]] || exit 0
[[ "$(basename "$file_path")" == "handoff-task.md" ]] || exit 0

cwd="$(handoff_root "$(jq -r '.cwd // ""' <<<"$input")")"

{ read -r target; read -r expected; } < <(handoff_resolve "$file_path" "$cwd/$HANDOFF_REL_TASK")
[[ "$target" == "$expected" ]] || exit 0
[[ -f "$target" ]] || exit 0

# Save the session pointer here (write time), not at activation time.
# extract.py cuts the scrape at the last write to handoff-task.md, so
# the pointer must reference the session containing that write.
transcript="$(jq -r '.transcript_path // ""' <<<"$input")"
if [[ -n "$transcript" ]]; then
    printf '%s\n' "$transcript" > "$cwd/$HANDOFF_REL_SESSION"
fi

if git -C "$cwd" add -f "$cwd/$HANDOFF_REL_TASK" 2>/dev/null; then
    jq -nc '{systemMessage: "handoff — staged for commit"}'
fi
