#!/usr/bin/env bash
# End-to-end test of the three hook scripts against synthetic input.
# Each scenario is a real invocation of the hook with a hand-crafted
# tool-event payload; assertions exit non-zero on failure.
#
# Usage: bash tests/hook-test.sh   (run from plugin root)
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

tmp="$(mktemp -d)"
other="$(mktemp -d)"
mkdir -p "$tmp/.claude" "$other/.claude"
trap 'rm -rf "$tmp" "$other"' EXIT

cat > "$tmp/.claude/handoff-task.md" <<'TASK'
## Current task

hook smoke test

## Open decisions

- none
TASK

transcript="$(ls -t "$HOME/.claude/projects/-Users-david-code-handoff"/*.jsonl 2>/dev/null | head -1 || echo "")"

failures=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}
assert_eq() {
    # $1=actual $2=expected $3=label
    if [[ "$1" != "$2" ]]; then
        fail "$3: expected '$2', got '$1'"
    fi
}

# write-extract on the matching path produces handoff.md.
echo "=== write-extract (matching path) ==="
jq -nc --arg cwd "$tmp" --arg t "$transcript" --arg fp "$tmp/.claude/handoff-task.md" \
    '{cwd:$cwd, transcript_path:$t, tool_name:"Write", tool_input:{file_path:$fp}}' \
    | bash scripts/write-extract.sh
[[ -f "$tmp/.claude/handoff.md" ]] || fail "write-extract did not create handoff.md"
grep -q '^@handoff-task.md$' "$tmp/.claude/handoff.md" \
    || fail "handoff.md missing @handoff-task.md ref"

# write-extract on an unrelated path is a no-op.
echo "=== write-extract (unrelated path: no-op) ==="
rm -f "$tmp/.claude/handoff.md"
jq -nc --arg cwd "$tmp" --arg t "$transcript" --arg fp "$tmp/README.md" \
    '{cwd:$cwd, transcript_path:$t, tool_name:"Write", tool_input:{file_path:$fp}}' \
    | bash scripts/write-extract.sh
[[ ! -e "$tmp/.claude/handoff.md" ]] || fail "write-extract regenerated on unrelated path"

# write-guard allows the canonical path.
echo "=== write-guard (matching path: allow) ==="
set +e
jq -nc --arg cwd "$tmp" --arg fp "$tmp/.claude/handoff-task.md" \
    '{cwd:$cwd, tool_name:"Write", tool_input:{file_path:$fp}}' \
    | bash scripts/write-guard.sh
rc=$?
set -e
assert_eq "$rc" "0" "write-guard same-project exit code"

# write-guard denies cross-project writes via structured JSON on stdout
# (exit 0). Modern PreToolUse deny path; matches the wipe scripts.
echo "=== write-guard (cross-project: deny) ==="
set +e
out="$(
    jq -nc --arg cwd "$tmp" --arg fp "$other/.claude/handoff-task.md" \
        '{cwd:$cwd, tool_name:"Write", tool_input:{file_path:$fp}}' \
        | bash scripts/write-guard.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "write-guard cross-project exit code"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
    || fail "write-guard did not emit deny decision"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason' >/dev/null \
    || fail "write-guard did not include permissionDecisionReason"
echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null \
    || fail "write-guard hookEventName != PreToolUse"
echo "$out" | jq -e '.systemMessage' >/dev/null \
    || fail "write-guard missing systemMessage"

# write-guard ignores writes to other filenames.
echo "=== write-guard (unrelated filename: allow) ==="
set +e
jq -nc --arg cwd "$tmp" --arg fp "$other/.claude/some-other-file.md" \
    '{cwd:$cwd, tool_name:"Write", tool_input:{file_path:$fp}}' \
    | bash scripts/write-guard.sh
rc=$?
set -e
assert_eq "$rc" "0" "write-guard non-matching filename exit code"

# skill-pre-hook on handoff:handoff wipes both files and notifies both
# audiences (systemMessage for the user, additionalContext for the agent).
echo "=== skill-pre-hook (handoff:handoff: wipe) ==="
: > "$tmp/.claude/handoff-task.md"
: > "$tmp/.claude/handoff.md"
out="$(
    jq -nc --arg cwd "$tmp" \
        '{cwd:$cwd, tool_name:"Skill", tool_input:{skill:"handoff:handoff"}}' \
        | bash scripts/skill-pre-hook.sh
)"
[[ ! -e "$tmp/.claude/handoff-task.md" ]] || fail "skill-pre-hook left handoff-task.md"
[[ ! -e "$tmp/.claude/handoff.md" ]] || fail "skill-pre-hook left handoff.md"
msg="$(echo "$out" | jq -r '.systemMessage // ""')"
assert_eq "$msg" "handoff: wiped prior handoff-task.md, handoff.md" \
    "skill-pre-hook systemMessage format"
ctx="$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')"
assert_eq "$ctx" \
    "handoff activation hook wiped prior handoff files (handoff-task.md, handoff.md); they are absent." \
    "skill-pre-hook additionalContext format"
echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null \
    || fail "skill-pre-hook hookEventName != PreToolUse"

# skill-pre-hook on a different skill is a no-op.
echo "=== skill-pre-hook (other skill: no-op) ==="
: > "$tmp/.claude/handoff-task.md"
jq -nc --arg cwd "$tmp" \
    '{cwd:$cwd, tool_name:"Skill", tool_input:{skill:"some-other:skill"}}' \
    | bash scripts/skill-pre-hook.sh
[[ -e "$tmp/.claude/handoff-task.md" ]] || fail "skill-pre-hook wiped on unrelated skill"

# skill-pre-hook creates .claude/ when missing.
echo "=== skill-pre-hook (missing .claude: create) ==="
fresh="$(mktemp -d)"
jq -nc --arg cwd "$fresh" \
    '{cwd:$cwd, tool_name:"Skill", tool_input:{skill:"handoff:handoff"}}' \
    | bash scripts/skill-pre-hook.sh
[[ -d "$fresh/.claude" ]] || fail "skill-pre-hook did not create .claude/"
rm -rf "$fresh"

# prompt-pre-hook on /handoff:handoff wipes both files and notifies both
# audiences (systemMessage for the user, additionalContext for the agent).
echo "=== prompt-pre-hook (/handoff:handoff: wipe) ==="
: > "$tmp/.claude/handoff-task.md"
: > "$tmp/.claude/handoff.md"
out="$(
    jq -nc --arg cwd "$tmp" \
        '{cwd:$cwd, prompt:"/handoff:handoff"}' \
        | bash scripts/prompt-pre-hook.sh
)"
[[ ! -e "$tmp/.claude/handoff-task.md" ]] || fail "prompt-pre-hook left handoff-task.md"
[[ ! -e "$tmp/.claude/handoff.md" ]] || fail "prompt-pre-hook left handoff.md"
msg="$(echo "$out" | jq -r '.systemMessage // ""')"
assert_eq "$msg" "handoff: wiped prior handoff-task.md, handoff.md" \
    "prompt-pre-hook systemMessage format"
ctx="$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')"
assert_eq "$ctx" \
    "handoff activation hook wiped prior handoff files (handoff-task.md, handoff.md); they are absent." \
    "prompt-pre-hook additionalContext format"
echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null \
    || fail "prompt-pre-hook hookEventName != UserPromptSubmit"

# prompt-pre-hook on /handoff:setup is a no-op.
echo "=== prompt-pre-hook (/handoff:setup: no-op) ==="
: > "$tmp/.claude/handoff-task.md"
jq -nc --arg cwd "$tmp" \
    '{cwd:$cwd, prompt:"/handoff:setup"}' \
    | bash scripts/prompt-pre-hook.sh
[[ -e "$tmp/.claude/handoff-task.md" ]] || fail "prompt-pre-hook wiped on /handoff:setup"

# prompt-pre-hook on an unrelated prompt is a no-op.
echo "=== prompt-pre-hook (unrelated prompt: no-op) ==="
jq -nc --arg cwd "$tmp" \
    '{cwd:$cwd, prompt:"hello world"}' \
    | bash scripts/prompt-pre-hook.sh
[[ -e "$tmp/.claude/handoff-task.md" ]] || fail "prompt-pre-hook wiped on unrelated prompt"

if (( failures > 0 )); then
    printf '\n%d failure(s)\n' "$failures" >&2
    exit 1
fi
printf '\nall hook scenarios passed\n'
