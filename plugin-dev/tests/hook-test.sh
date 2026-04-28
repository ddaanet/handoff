#!/usr/bin/env bash
# End-to-end test of the toolkit's hook scripts against synthetic
# tool-event payloads. Each scenario is a real invocation of the hook
# with a hand-crafted JSON input; assertions exit non-zero on failure.
#
# Usage: bash tests/hook-test.sh   (run from repo root)
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

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

# version-guard scenarios use a fake plugin root with a hand-crafted
# .claude-plugin/plugin.json fixture, so assertions are independent of
# whatever consumer plugin happens to vendor this toolkit.
proj="$(mktemp -d)"
trap 'rm -rf "$proj"' EXIT
mkdir -p "$proj/.claude-plugin"
cat > "$proj/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "fixture",
  "version": "1.2.3",
  "license": "MIT"
}
JSON

# version-guard denies an Edit that changes .version.
echo "=== version-guard (Edit version change: deny) ==="
set +e
out="$(
    jq -nc --arg cwd "$proj" --arg fp "$proj/.claude-plugin/plugin.json" \
        '{cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$fp, old_string:"\"version\": \"1.2.3\"", new_string:"\"version\": \"1.3.0\""}}' \
        | bash version-guard.sh 2>&1
)"
rc=$?
set -e
assert_eq "$rc" "2" "version-guard Edit-bump exit code"
echo "$out" | grep -q '"permissionDecision":"deny"' \
    || fail "version-guard did not emit deny decision for Edit"
echo "$out" | grep -q '"permissionDecisionReason"' \
    || fail "version-guard did not include permissionDecisionReason"

# version-guard allows an Edit that touches plugin.json without changing version.
echo "=== version-guard (Edit unrelated field: allow) ==="
set +e
jq -nc --arg cwd "$proj" --arg fp "$proj/.claude-plugin/plugin.json" \
    '{cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$fp, old_string:"\"license\": \"MIT\"", new_string:"\"license\": \"Apache-2.0\""}}' \
    | bash version-guard.sh
rc=$?
set -e
assert_eq "$rc" "0" "version-guard Edit-unrelated exit code"

# version-guard denies a Write whose content changes .version.
echo "=== version-guard (Write version change: deny) ==="
new_content="$(jq -c '.version="9.9.9"' "$proj/.claude-plugin/plugin.json")"
set +e
out="$(
    jq -nc --arg cwd "$proj" --arg fp "$proj/.claude-plugin/plugin.json" --arg c "$new_content" \
        '{cwd:$cwd, tool_name:"Write", tool_input:{file_path:$fp, content:$c}}' \
        | bash version-guard.sh 2>&1
)"
rc=$?
set -e
assert_eq "$rc" "2" "version-guard Write-bump exit code"
echo "$out" | grep -q '"permissionDecision":"deny"' \
    || fail "version-guard did not emit deny decision for Write"

# version-guard ignores Edits to unrelated files.
echo "=== version-guard (unrelated file: allow) ==="
set +e
jq -nc --arg cwd "$proj" --arg fp "$proj/README.md" \
    '{cwd:$cwd, tool_name:"Edit", tool_input:{file_path:$fp, old_string:"a", new_string:"b"}}' \
    | bash version-guard.sh
rc=$?
set -e
assert_eq "$rc" "0" "version-guard unrelated-file exit code"

if (( failures > 0 )); then
    printf '\n%d failure(s)\n' "$failures" >&2
    exit 1
fi
printf '\nall hook scenarios passed\n'
