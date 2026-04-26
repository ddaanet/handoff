#!/usr/bin/env bash
# Run extract.py against the most recent session transcript for this
# project and dump the resulting handoff.md to stdout. Useful for
# eyeballing extraction output during development.
#
# Usage: bash tests/smoke.sh   (run from plugin root)
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

proj="$HOME/.claude/projects/-Users-david-code-handoff"
transcript="$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1 || true)"
if [[ -z "$transcript" ]]; then
    echo "no session transcript at $proj — open this dir in claude first" >&2
    exit 1
fi

output="$(mktemp --suffix=.md)"
trap 'rm -f "$output"' EXIT

python3 scripts/extract.py "$transcript" "$output"
echo "--- $output ---"
cat "$output"
