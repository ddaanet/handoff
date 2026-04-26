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

# 1. write-extract on the matching path produces handoff.md.
echo "=== write-extract (matching path) ==="
jq -nc --arg cwd "$tmp" --arg t "$transcript" --arg fp "$tmp/.claude/handoff-task.md" \
    '{cwd:$cwd, transcript_path:$t, tool_name:"Write", tool_input:{file_path:$fp}}' \
    | bash scripts/write-extract.sh
[[ -f "$tmp/.claude/handoff.md" ]] || fail "write-extract did not create handoff.md"
grep -q '^@handoff-task.md$' "$tmp/.claude/handoff.md" \
    || fail "handoff.md missing @handoff-task.md ref"

# 2. write-extract on an unrelated path is a no-op.
echo "=== write-extract (unrelated path: no-op) ==="
rm -f "$tmp/.claude/handoff.md"
jq -nc --arg cwd "$tmp" --arg t "$transcript" --arg fp "$tmp/README.md" \
    '{cwd:$cwd, transcript_path:$t, tool_name:"Write", tool_input:{file_path:$fp}}' \
    | bash scripts/write-extract.sh
[[ ! -e "$tmp/.claude/handoff.md" ]] || fail "write-extract regenerated on unrelated path"

# 3. write-guard allows the canonical path.
echo "=== write-guard (matching path: allow) ==="
set +e
jq -nc --arg cwd "$tmp" --arg fp "$tmp/.claude/handoff-task.md" \
    '{cwd:$cwd, tool_name:"Write", tool_input:{file_path:$fp}}' \
    | bash scripts/write-guard.sh
rc=$?
set -e
assert_eq "$rc" "0" "write-guard same-project exit code"

# 4. write-guard denies cross-project writes with exit 2 and JSON deny.
echo "=== write-guard (cross-project: deny) ==="
set +e
out="$(
    jq -nc --arg cwd "$tmp" --arg fp "$other/.claude/handoff-task.md" \
        '{cwd:$cwd, tool_name:"Write", tool_input:{file_path:$fp}}' \
        | bash scripts/write-guard.sh 2>&1
)"
rc=$?
set -e
assert_eq "$rc" "2" "write-guard cross-project exit code"
echo "$out" | grep -q '"permissionDecision":"deny"' \
    || fail "write-guard did not emit deny decision"

# 5. write-guard ignores writes to other filenames.
echo "=== write-guard (unrelated filename: allow) ==="
set +e
jq -nc --arg cwd "$tmp" --arg fp "$other/.claude/some-other-file.md" \
    '{cwd:$cwd, tool_name:"Write", tool_input:{file_path:$fp}}' \
    | bash scripts/write-guard.sh
rc=$?
set -e
assert_eq "$rc" "0" "write-guard non-matching filename exit code"

# 6. skill-pre-hook on handoff:handoff wipes both files.
echo "=== skill-pre-hook (handoff:handoff: wipe) ==="
: > "$tmp/.claude/handoff-task.md"
: > "$tmp/.claude/handoff.md"
jq -nc --arg cwd "$tmp" \
    '{cwd:$cwd, tool_name:"Skill", tool_input:{skill:"handoff:handoff"}}' \
    | bash scripts/skill-pre-hook.sh
[[ ! -e "$tmp/.claude/handoff-task.md" ]] || fail "skill-pre-hook left handoff-task.md"
[[ ! -e "$tmp/.claude/handoff.md" ]] || fail "skill-pre-hook left handoff.md"

# 7. skill-pre-hook on a different skill is a no-op.
echo "=== skill-pre-hook (other skill: no-op) ==="
: > "$tmp/.claude/handoff-task.md"
jq -nc --arg cwd "$tmp" \
    '{cwd:$cwd, tool_name:"Skill", tool_input:{skill:"some-other:skill"}}' \
    | bash scripts/skill-pre-hook.sh
[[ -e "$tmp/.claude/handoff-task.md" ]] || fail "skill-pre-hook wiped on unrelated skill"

if (( failures > 0 )); then
    printf '\n%d failure(s)\n' "$failures" >&2
    exit 1
fi
printf '\nall hook scenarios passed\n'
