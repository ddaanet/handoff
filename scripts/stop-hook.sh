#!/usr/bin/env bash
# Stop hook: if a handoff-task.md exists and is newer than handoff.md
# (or handoff.md is missing), regenerate handoff.md from the session
# JSONL. No-op otherwise — cheap mtime check per stop.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

input="$(cat)"
cwd="$(jq -r '.cwd // ""' <<<"$input")"
transcript="$(jq -r '.transcript_path // ""' <<<"$input")"
[[ -n "$cwd" ]] || cwd="$PWD"

task="$cwd/.claude/handoff-task.md"
output="$cwd/.claude/handoff.md"

[[ -f "$task" ]] || exit 0
# Skip if output exists and is at least as new as the task file
if [[ -f "$output" && ! "$task" -nt "$output" ]]; then
    exit 0
fi

if [[ -z "$transcript" || ! -f "$transcript" ]]; then
    transcript=""
fi

log="$cwd/.claude/handoff-error.log"
if ! python3 "$script_dir/extract.py" "$transcript" "$output" >/dev/null 2>"$log"; then
    tail=$(tail -c 400 "$log" 2>/dev/null | tr '\n' ' ')
    printf '{"systemMessage": "handoff extract failed (see %s): %s"}\n' "$log" "$tail"
    exit 0
fi
rm -f "$log"

printf '{"systemMessage": "handoff extracted to %s"}\n' "$output"
