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
# - Task inlining: when handoff-task.md exists next to handoff.md, its
#   contents are inlined into handoff.md (no `@` ref).
echo "=== extract-basic (full-coverage fixture) ==="
out_dir="$tmp/basic"
mkdir -p "$out_dir"
out="$out_dir/handoff.md"
cat > "$out_dir/handoff-task.md" <<'TASK'
## Current task

inlining test sentinel value 7f3a1b9c

## Open decisions

- none
TASK
python3 scripts/extract.py tests/fixtures/extract-basic.jsonl "$out" > /dev/null

# Header is always present.
assert_contains "$out" "# Handoff — " "basic: header"
assert_contains "$out" "Session: \`extract-basic\`" "basic: session line"

# Task file inlined (no @ ref anywhere).
assert_contains "$out" "inlining test sentinel value 7f3a1b9c" "basic: task content inlined"
assert_not_contains "$out" "@handoff-task.md" "basic: @ ref gone"

# Files touched: Write + Edit, dedup, order = first-appearance.
assert_contains "$out" "- \`/handoff-test/file1.py\`" "basic: file1 listed"
assert_contains "$out" "- \`/handoff-test/file2.py\`" "basic: file2 listed"
assert_not_contains "$out" "/handoff-test/file3.py" "basic: Read excluded"
assert_not_contains "$out" "/handoff-test/sidechain.py" "basic: sidechain stripped"

# File order: file1 before file2 (first-appearance ordering).
f1_line="$(grep -n '/handoff-test/file1.py' "$out" | head -1 | cut -d: -f1)"
f2_line="$(grep -n '/handoff-test/file2.py' "$out" | head -1 | cut -d: -f1)"
[[ -n "$f1_line" && -n "$f2_line" && $f1_line -lt $f2_line ]] \
    || fail "basic: expected file1 before file2 (got file1=$f1_line, file2=$f2_line)"

# Exactly 5 prompts retained (last-N cap with all 5 retained).
prompt_count="$(grep -c '^\*\*after\*\* ' "$out" || true)"
assert_eq "$prompt_count" "5" "basic: prompt count"

# Anchor variants.
assert_contains "$out" "**after** (session start)" "basic: session-start anchor"
assert_contains "$out" "**after** Wrote file1" "basic: text anchor"
assert_contains "$out" "**after** Done editing" "basic: text anchor (image prompt)"
assert_contains "$out" "**after** [Bash] echo hi" "basic: command anchor"
assert_contains "$out" "**after** [Edit] /handoff-test/file2.py" "basic: file_path anchor"

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
# inlined task content and empty-section notes. The "no session data"
# path documented at the top of extract.py.
echo "=== empty-transcript (no session data) ==="
out_dir="$tmp/empty"
mkdir -p "$out_dir"
out="$out_dir/handoff.md"
cat > "$out_dir/handoff-task.md" <<'TASK'
## Current task

empty-transcript sentinel 4c8d2e1f
TASK
python3 scripts/extract.py "" "$out" > /dev/null
assert_contains "$out" "empty-transcript sentinel 4c8d2e1f" "empty: task content inlined"
assert_not_contains "$out" "@handoff-task.md" "empty: @ ref gone"
assert_contains "$out" "Session: \`(no transcript)\`" "empty: no-transcript session id"
assert_contains "$out" "(none extracted)" "empty: empty-section note"

# Missing transcript file: same fallback (treated as no session data).
echo "=== missing-transcript (path doesn't exist) ==="
out_dir="$tmp/missing"
mkdir -p "$out_dir"
out="$out_dir/handoff.md"
cat > "$out_dir/handoff-task.md" <<'TASK'
## Current task

missing-transcript sentinel 9b6e3f0a
TASK
python3 scripts/extract.py "$tmp/does-not-exist.jsonl" "$out" > /dev/null
assert_contains "$out" "missing-transcript sentinel 9b6e3f0a" "missing: task content inlined"
assert_not_contains "$out" "@handoff-task.md" "missing: @ ref gone"
assert_contains "$out" "(none extracted)" "missing: empty-section note"

# Missing task file: the inlined block is absent. No placeholder text,
# no orphan heading. The surrounding sections still render.
echo "=== missing-task (no handoff-task.md in output dir) ==="
out_dir="$tmp/missing-task"
mkdir -p "$out_dir"
out="$out_dir/handoff.md"
python3 scripts/extract.py "" "$out" > /dev/null
assert_not_contains "$out" "@handoff-task.md" "missing-task: no @ ref"
assert_not_contains "$out" "## Current task" "missing-task: no task heading"
assert_contains "$out" "## Files touched" "missing-task: files section still present"
assert_contains "$out" "## Last user prompts" "missing-task: prompts section still present"

# extract-skill-meta.jsonl: skill bodies arrive as `isMeta` user entries
# (both the Skill-tool path, with sourceToolUseID, and the slash-command
# path, without). A native skill body can be 100+ KB and does NOT start
# with a known wrapper prefix, so it must be dropped structurally on the
# isMeta flag — never surfaced as a "last user prompt". Real prompts
# (no isMeta) around it must still be retained.
echo "=== extract-skill-meta (isMeta skill bodies dropped) ==="
out_dir="$tmp/skill-meta"
mkdir -p "$out_dir"
out="$out_dir/handoff.md"
python3 scripts/extract.py tests/fixtures/extract-skill-meta.jsonl "$out" > /dev/null
# Real user prompts on either side of the skill bodies are kept.
assert_contains "$out" "real prompt KEEPME_ONE" "skill-meta: real prompt before skill kept"
assert_contains "$out" "real prompt KEEPME_TWO" "skill-meta: real prompt between skills kept"
assert_contains "$out" "real prompt KEEPME_THREE" "skill-meta: real prompt after skill kept"
# Skill bodies (both modes) must not leak into the prompts section.
assert_not_contains "$out" "DROPME_SKILL_TOOL" "skill-meta: Skill-tool body dropped"
assert_not_contains "$out" "DROPME_SKILL_SLASH" "skill-meta: slash-command body dropped"
assert_not_contains "$out" "# Update Config Skill" "skill-meta: tool skill heading dropped"
assert_not_contains "$out" "# Plugin Creation Workflow" "skill-meta: slash skill heading dropped"
# Background-job <task-notification> wrappers are harness-injected, not
# user prompts — filtered via WRAPPER_PREFIXES like <system-reminder>.
assert_not_contains "$out" "TASKNOTIF_DROP" "skill-meta: task-notification body dropped"
assert_not_contains "$out" "<task-notification>" "skill-meta: task-notification wrapper dropped"

# anchor-multiline.jsonl: assistant text anchors with 3, 7, and 8 lines.
# 3-line and 7-line: all lines shown (≤ ANCHOR_LINE_LIMIT=7).
# 8-line: first 3 + [...] + last 3, two middle lines absent.
# Format change: **after** text (no closing **).
echo "=== anchor-multiline (multi-line anchor display) ==="
out_dir="$tmp/anchor-multiline"
mkdir -p "$out_dir"
out="$out_dir/handoff.md"
python3 scripts/extract.py tests/fixtures/anchor-multiline.jsonl "$out" > /dev/null

# 3-line anchor: all 3 lines shown, no truncation.
assert_contains "$out" "**after** ANCHOR3_L1" "anchor-multiline: 3-line L1"
assert_contains "$out" "ANCHOR3_L2" "anchor-multiline: 3-line L2"
assert_contains "$out" "ANCHOR3_L3" "anchor-multiline: 3-line L3"

# 7-line anchor: all 7 lines shown (boundary — exactly ANCHOR_LINE_LIMIT).
assert_contains "$out" "**after** ANCHOR7_L1" "anchor-multiline: 7-line L1"
assert_contains "$out" "ANCHOR7_L2" "anchor-multiline: 7-line L2"
assert_contains "$out" "ANCHOR7_L3" "anchor-multiline: 7-line L3"
assert_contains "$out" "ANCHOR7_L4" "anchor-multiline: 7-line L4"
assert_contains "$out" "ANCHOR7_L5" "anchor-multiline: 7-line L5"
assert_contains "$out" "ANCHOR7_L6" "anchor-multiline: 7-line L6"
assert_contains "$out" "ANCHOR7_L7" "anchor-multiline: 7-line L7"

# 8-line anchor: 3+[…]+3, two middle lines absent.
assert_contains "$out" "**after** ANCHOR8_L1" "anchor-multiline: 8-line L1 (head)"
assert_contains "$out" "ANCHOR8_L2" "anchor-multiline: 8-line L2 (head)"
assert_contains "$out" "ANCHOR8_L3" "anchor-multiline: 8-line L3 (head)"
assert_contains "$out" "ANCHOR8_L6" "anchor-multiline: 8-line L6 (tail)"
assert_contains "$out" "ANCHOR8_L7" "anchor-multiline: 8-line L7 (tail)"
assert_contains "$out" "ANCHOR8_L8" "anchor-multiline: 8-line L8 (tail)"
assert_not_contains "$out" "ANCHOR8_MIDDLE_DROP_4" "anchor-multiline: middle L4 absent"
assert_not_contains "$out" "ANCHOR8_MIDDLE_DROP_5" "anchor-multiline: middle L5 absent"

# [...] appears, and in correct order: L3 < [...] < L6.
l3_line="$(grep -n 'ANCHOR8_L3' "$out" | head -1 | cut -d: -f1)"
ellipsis_line="$(grep -nF '[…]' "$out" | head -1 | cut -d: -f1)"
l6_line="$(grep -n 'ANCHOR8_L6' "$out" | head -1 | cut -d: -f1)"
[[ -n "$l3_line" && -n "$ellipsis_line" && -n "$l6_line" \
    && $l3_line -lt $ellipsis_line && $ellipsis_line -lt $l6_line ]] \
    || fail "anchor-multiline: expected L3 < [...] < L6 order"

if (( failures > 0 )); then
    printf '\n%d failure(s)\n' "$failures" >&2
    exit 1
fi
printf '\nall extract scenarios passed\n'
