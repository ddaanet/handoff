#!/usr/bin/env bash
# PostToolUse hook for Write|Edit.
# When the agent successfully writes/edits $cwd/.claude/handoff-task.md,
# regenerate $cwd/.claude/handoff.md from the session JSONL so the
# extraction is visible in the same agent turn.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // ""' <<<"$input")"
cwd="$(jq -r '.cwd // ""' <<<"$input")"
transcript="$(jq -r '.transcript_path // ""' <<<"$input")"
[[ -n "$cwd" ]] || cwd="$PWD"

[[ -n "$file_path" ]] || exit 0
[[ "$(basename "$file_path")" == "handoff-task.md" ]] || exit 0

# `realpath -m` is GNU-only; use python3 for portability.
resolve() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
target="$(resolve "$file_path")"
expected="$(resolve "$cwd/.claude/handoff-task.md")"
[[ "$target" == "$expected" ]] || exit 0

[[ -f "$target" ]] || exit 0

[[ -n "$transcript" && -f "$transcript" ]] || transcript=""

output="$cwd/.claude/handoff.md"
log="$cwd/.claude/handoff-error.log"
if ! python3 "$script_dir/extract.py" "$transcript" "$output" >/dev/null 2>"$log"; then
    tail=$(tail -c 400 "$log" 2>/dev/null | tr '\n' ' ')
    jq -nc --arg log "$log" --arg tail "$tail" \
        '{systemMessage: ("handoff extract failed (see " + $log + "): " + $tail)}'
    exit 0
fi
rm -f "$log"

jq -nc --arg output "$output" \
    '{systemMessage: ("handoff extracted to " + $output)}'
