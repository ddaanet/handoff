#!/usr/bin/env bash
# Run extract.py against the most recent session transcript for this
# project and print the assembled frame to stdout. Useful for eyeballing
# extraction output during development.
#
# Usage: bash tests/smoke.sh   (run from plugin root)
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

proj="$HOME/.claude/projects/-Users-david-code-handoff"
# Session JSONLs are UUID-named so ls -t is safe here; no non-alphanumeric names.
# shellcheck disable=SC2012
transcript="$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1 || true)"
if [[ -z "$transcript" ]]; then
    echo "no session transcript at $proj — open this dir in claude first" >&2
    exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/handoff-smoke.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

python3 scripts/extract.py "$transcript" "$repo_root/.claude/handoff-task.md" > "$tmp/handoff.md"
# Empty output is possible on a fresh repo with no handoff-task.md and an
# empty transcript — not a failure, but worth noting.
[[ -s "$tmp/handoff.md" ]] || { echo "smoke: empty output (no task file or empty transcript)" >&2; exit 1; }
echo "--- smoke output ---"
cat "$tmp/handoff.md"
