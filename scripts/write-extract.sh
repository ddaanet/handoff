#!/usr/bin/env bash
# PostToolUse hook for Write|Edit.
# When the agent successfully writes/edits $cwd/.claude/handoff-task.md,
# regenerate $cwd/.claude/handoff.md from the session JSONL so the
# extraction is visible in the same agent turn.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

script_dir="$(cd "$(dirname "$0")" && pwd)"

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // ""' <<<"$input")"
[[ -n "$file_path" ]] || exit 0
[[ "$(basename "$file_path")" == "handoff-task.md" ]] || exit 0

cwd="$(jq -r '.cwd // ""' <<<"$input")"
[[ -n "$cwd" ]] || cwd="$PWD"

{ read -r target; read -r expected; } < <(handoff_resolve "$file_path" "$cwd/$HANDOFF_REL_TASK")
[[ "$target" == "$expected" ]] || exit 0

[[ -f "$target" ]] || exit 0

transcript="$(jq -r '.transcript_path // ""' <<<"$input")"
[[ -n "$transcript" && -f "$transcript" ]] || transcript=""

output="$cwd/$HANDOFF_REL_OUT"
log="$cwd/$HANDOFF_REL_ERR"
if ! python3 "$script_dir/extract.py" "$transcript" "$output" >/dev/null 2>"$log"; then
    tail=$(tail -c 400 "$log" 2>/dev/null | tr '\n' ' ')
    jq -nc --arg log "$log" --arg tail "$tail" \
        '{systemMessage: ("handoff extract failed (see " + $log + "): " + $tail)}'
    exit 0
fi
rm -f "$log"
