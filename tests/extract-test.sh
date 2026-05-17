#!/usr/bin/env bash
# Fixture-driven test of scripts/extract.py. Runs the extractor against
# hand-crafted JSONL fixtures and asserts the rendered handoff.md is
# correct. Each fixture exercises one or more behaviour paths; see the
# inline comments below for the coverage map.
#
# Usage: bash tests/extract-test.sh   (run from plugin root)
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}
assert_contains() {
    # $1=file $2=needle $3=label
    if ! grep -qF -- "$2" "$1"; then
        fail "$3: expected '$2' in $1"
    fi
}
assert_not_contains() {
    # $1=file $2=needle $3=label
    if grep -qF -- "$2" "$1"; then
        fail "$3: did not expect '$2' in $1"
    fi
}
assert_eq() {
    if [[ "$1" != "$2" ]]; then
        fail "$3: expected '$2', got '$1'"
    fi
}

# extract-basic.jsonl exercises the core extraction paths:
# - Files touched: Write/Edit only, Read filtered, dedup, sidechain stripped
# - User prompts: 5-cap, wrapper-prefix filter, wrapper-exact filter,
#   tool_result-only filter, non-text placeholder
# - Anchors: (session start), text fallback, file_path, command fallback
# - format_quote: multi-line with blank line renders bare `>` (no trailing space)
echo "=== extract-basic (full-coverage fixture) ==="
out="$tmp/basic.md"
python3 scripts/extract.py tests/fixtures/extract-basic.jsonl "$out" > /dev/null

# Header + @ ref are always present.
assert_contains "$out" "# Handoff — " "basic: header"
assert_contains "$out" "Session: \`extract-basic\`" "basic: session line"
assert_contains "$out" "@handoff-task.md" "basic: @ ref"

# Files touched: Write + Edit, dedup, order = first-appearance.
assert_contains "$out" "- \`/handoff-test/file1.py\`" "basic: file1 listed"
assert_contains "$out" "- \`/handoff-test/file2.py\`" "basic: file2 listed"
assert_not_contains "$out" "/handoff-test/file3.py" "basic: Read excluded"
assert_not_contains "$out" "/handoff-test/sidechain.py" "basic: sidechain stripped"

# File order: file1 before file2 (first-appearance ordering).
order="$(grep -n '/handoff-test/file' "$out" | head -2 | cut -d: -f1 | paste -sd, -)"
f1_line="$(grep -n '/handoff-test/file1.py' "$out" | head -1 | cut -d: -f1)"
f2_line="$(grep -n '/handoff-test/file2.py' "$out" | head -1 | cut -d: -f1)"
[[ -n "$f1_line" && -n "$f2_line" && $f1_line -lt $f2_line ]] \
    || fail "basic: expected file1 before file2 (got file1=$f1_line, file2=$f2_line)"

# Exactly 5 prompts retained (last-N cap with all 5 retained).
prompt_count="$(grep -c '^\*\*after ' "$out" || true)"
assert_eq "$prompt_count" "5" "basic: prompt count"

# Anchor variants.
assert_contains "$out" "**after (session start)**" "basic: session-start anchor"
assert_contains "$out" "**after Wrote file1**" "basic: text anchor"
assert_contains "$out" "**after Done editing**" "basic: text anchor (image prompt)"
assert_contains "$out" "**after [Bash] echo hi**" "basic: command anchor"
assert_contains "$out" "**after [Edit] /handoff-test/file2.py**" "basic: file_path anchor"

# Non-text placeholder for image-only user content.
assert_contains "$out" "> [image block]" "basic: image placeholder"

# Wrapper filtering: these should NOT appear as quoted prompts.
assert_not_contains "$out" "> <system-reminder>" "basic: system-reminder wrapper filtered"
assert_not_contains "$out" "> [Request interrupted by user]" "basic: exact wrapper filtered"
assert_not_contains "$out" "> <local-command-stdout>" "basic: local-command wrapper filtered"
assert_not_contains "$out" "sidechain prompt" "basic: sidechain user prompt stripped"

# format_quote: blank line in a prompt renders as bare `>` (no trailing space).
grep -q '^>$' "$out" || fail "basic: expected bare '>' line for blank line in multi-line prompt"

# Empty transcript path: extract.py still writes a valid file with the
# @ ref and empty-section notes. This is the "no session data" path
# documented at the top of extract.py.
echo "=== empty-transcript (no session data) ==="
out="$tmp/empty.md"
python3 scripts/extract.py "" "$out" > /dev/null
assert_contains "$out" "@handoff-task.md" "empty: @ ref present"
assert_contains "$out" "Session: \`(no transcript)\`" "empty: no-transcript session id"
assert_contains "$out" "(none extracted)" "empty: empty-section note"

# Missing transcript file: same fallback (treated as no session data).
echo "=== missing-transcript (path doesn't exist) ==="
out="$tmp/missing.md"
python3 scripts/extract.py "$tmp/does-not-exist.jsonl" "$out" > /dev/null
assert_contains "$out" "@handoff-task.md" "missing: @ ref present"
assert_contains "$out" "(none extracted)" "missing: empty-section note"

if (( failures > 0 )); then
    printf '\n%d failure(s)\n' "$failures" >&2
    exit 1
fi
printf '\nall extract scenarios passed\n'
