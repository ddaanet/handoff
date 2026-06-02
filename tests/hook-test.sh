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
export CLAUDE_PROJECT_DIR="$tmp"

cat > "$tmp/.claude/handoff-task.md" <<'TASK'
## Current task

hook smoke test

## Open decisions

- none
TASK

# Use the shared synthetic fixture: hermetic across machines and forks,
# and lets the test assert that the transcript path is actually exercised
# (not just that the inlined task content survives).
transcript="$repo_root/tests/fixtures/extract-basic.jsonl"
[[ -f "$transcript" ]] || { printf 'FAIL: fixture missing: %s\n' "$transcript" >&2; exit 1; }

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

# --- _lib.sh: handoff_activated detector ---
echo "=== handoff_activated (detector) ==="
# shellcheck source-path=SCRIPTDIR source=../scripts/_lib.sh
source "$repo_root/scripts/_lib.sh"

set +e
handoff_activated "$repo_root/tests/fixtures/activated-skill.jsonl"; rc=$?
set -e
assert_eq "$rc" "0" "handoff_activated: Skill tool_use (qualified) → activated"

set +e
handoff_activated "$repo_root/tests/fixtures/activated-skill-bare.jsonl"; rc=$?
set -e
assert_eq "$rc" "0" "handoff_activated: Skill tool_use (bare name) → activated"

set +e
handoff_activated "$repo_root/tests/fixtures/activated-slash.jsonl"; rc=$?
set -e
assert_eq "$rc" "0" "handoff_activated: slash command → activated"

set +e
handoff_activated "$repo_root/tests/fixtures/extract-basic.jsonl"; rc=$?
set -e
assert_eq "$rc" "1" "handoff_activated: no signal → not activated"

set +e
handoff_activated ""; rc=$?
set -e
assert_eq "$rc" "1" "handoff_activated: empty path → not activated"

set +e
handoff_activated "$tmp/.claude/does-not-exist.jsonl"; rc=$?
set -e
assert_eq "$rc" "1" "handoff_activated: missing file → not activated"

# --- _lib.sh: handoff_deny emitter ---
echo "=== handoff_deny (emitter) ==="
# Runs in a subshell via command substitution, so handoff_deny's exit 0
# terminates only the subshell, not the test harness.
out="$(handoff_deny "reason text" "system text")"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
    || fail "handoff_deny: permissionDecision != deny"
echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null \
    || fail "handoff_deny: hookEventName != PreToolUse"
assert_eq "$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')" "reason text" \
    "handoff_deny: reason passthrough"
assert_eq "$(echo "$out" | jq -r '.systemMessage')" "system text" \
    "handoff_deny: systemMessage passthrough"

# write-extract on the matching path produces handoff.md.
echo "=== write-extract (matching path) ==="
jq -nc --arg cwd "$tmp" --arg t "$transcript" --arg fp "$tmp/.claude/handoff-task.md" \
    '{cwd:$cwd, transcript_path:$t, tool_name:"Write", tool_input:{file_path:$fp}}' \
    | bash scripts/write-extract.sh
[[ -f "$tmp/.claude/handoff.md" ]] || fail "write-extract did not create handoff.md"
grep -q 'hook smoke test' "$tmp/.claude/handoff.md" \
    || fail "handoff.md missing inlined task content"
grep -q 'fifth prompt' "$tmp/.claude/handoff.md" \
    || fail "handoff.md missing transcript-derived content (fixture not exercised)"
if grep -q '^@handoff-task.md$' "$tmp/.claude/handoff.md"; then
    fail "handoff.md should not contain @handoff-task.md ref"
fi

# write-extract stages both files when project is a git repo.
echo "=== write-extract (git staging) ==="
git_tmp="$(mktemp -d)"
git -C "$git_tmp" init -q
mkdir -p "$git_tmp/.claude"
cp "$tmp/.claude/handoff-task.md" "$git_tmp/.claude/handoff-task.md"
out="$(jq -nc --arg t "$transcript" --arg fp "$git_tmp/.claude/handoff-task.md" \
        '{transcript_path:$t, tool_name:"Write", tool_input:{file_path:$fp}}' \
    | CLAUDE_PROJECT_DIR="$git_tmp" bash scripts/write-extract.sh)"
echo "$out" | jq -e '.systemMessage == "handoff — staged for commit"' >/dev/null \
    || fail "write-extract (git staging): expected staged message"
git -C "$git_tmp" status --porcelain | grep -q 'handoff-task.md' \
    || fail "write-extract (git staging): handoff-task.md not staged"
git -C "$git_tmp" status --porcelain | grep -q 'handoff\.md' \
    || fail "write-extract (git staging): handoff.md not staged"
rm -rf "$git_tmp"

# write-extract on an unrelated path is a no-op.
echo "=== write-extract (unrelated path: no-op) ==="
rm -f "$tmp/.claude/handoff.md"
jq -nc --arg cwd "$tmp" --arg t "$transcript" --arg fp "$tmp/README.md" \
    '{cwd:$cwd, transcript_path:$t, tool_name:"Write", tool_input:{file_path:$fp}}' \
    | bash scripts/write-extract.sh
[[ ! -e "$tmp/.claude/handoff.md" ]] || fail "write-extract regenerated on unrelated path"

# write-guard: canonical handoff-task.md path is DENIED before activation.
echo "=== write-guard (handoff-task.md, not activated: deny) ==="
set +e
out="$(
    jq -nc --arg cwd "$tmp" --arg t "$repo_root/tests/fixtures/extract-basic.jsonl" --arg fp "$tmp/.claude/handoff-task.md" \
        '{cwd:$cwd, transcript_path:$t, tool_name:"Write", tool_input:{file_path:$fp}}' \
        | bash scripts/write-guard.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "write-guard not-activated exit code"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
    || fail "write-guard did not deny handoff-task.md before activation"

# write-guard: canonical handoff-task.md path is ALLOWED after activation.
echo "=== write-guard (handoff-task.md, activated: allow) ==="
set +e
out="$(
    jq -nc --arg cwd "$tmp" --arg t "$repo_root/tests/fixtures/activated-skill.jsonl" --arg fp "$tmp/.claude/handoff-task.md" \
        '{cwd:$cwd, transcript_path:$t, tool_name:"Write", tool_input:{file_path:$fp}}' \
        | bash scripts/write-guard.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "write-guard activated exit code"
assert_eq "$out" "" "write-guard activated produced no deny output"

# write-guard: handoff.md is hook-owned — denied even when activated.
echo "=== write-guard (handoff.md: deny) ==="
set +e
out="$(
    jq -nc --arg cwd "$tmp" --arg t "$repo_root/tests/fixtures/activated-skill.jsonl" --arg fp "$tmp/.claude/handoff.md" \
        '{cwd:$cwd, transcript_path:$t, tool_name:"Write", tool_input:{file_path:$fp}}' \
        | bash scripts/write-guard.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "write-guard handoff.md exit code"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
    || fail "write-guard did not deny write to hook-owned handoff.md"

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

# write-guard: CLAUDE_PROJECT_DIR overrides payload cwd for cross-project check.
# Simulates shell cwd drifting to another directory (e.g. via /add-dir + cd)
# while the project root stays $tmp. Write to $tmp should be allowed.
echo "=== write-guard (CLAUDE_PROJECT_DIR overrides cwd drift: allow) ==="
set +e
out="$(
    jq -nc --arg cwd "$other" --arg t "$repo_root/tests/fixtures/activated-skill.jsonl" --arg fp "$tmp/.claude/handoff-task.md" \
        '{cwd:$cwd, transcript_path:$t, tool_name:"Write", tool_input:{file_path:$fp}}' \
        | CLAUDE_PROJECT_DIR="$tmp" bash scripts/write-guard.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "write-guard CLAUDE_PROJECT_DIR override exit code"
assert_eq "$out" "" "write-guard CLAUDE_PROJECT_DIR override produced no deny output"

# write-guard ignores writes to other filenames.
echo "=== write-guard (unrelated filename: allow) ==="
set +e
jq -nc --arg cwd "$tmp" --arg fp "$other/.claude/some-other-file.md" \
    '{cwd:$cwd, tool_name:"Write", tool_input:{file_path:$fp}}' \
    | bash scripts/write-guard.sh
rc=$?
set -e
assert_eq "$rc" "0" "write-guard non-matching filename exit code"

# read-guard: handoff.md is hook-owned — reads refused always.
echo "=== read-guard (handoff.md: deny) ==="
set +e
out="$(
    jq -nc --arg cwd "$tmp" --arg t "$repo_root/tests/fixtures/activated-skill.jsonl" --arg fp "$tmp/.claude/handoff.md" \
        '{cwd:$cwd, transcript_path:$t, tool_name:"Read", tool_input:{file_path:$fp}}' \
        | bash scripts/read-guard.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "read-guard handoff.md exit code"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
    || fail "read-guard did not deny read of hook-owned handoff.md"

# read-guard: handoff-task.md read refused before activation.
echo "=== read-guard (handoff-task.md, not activated: deny) ==="
set +e
out="$(
    jq -nc --arg cwd "$tmp" --arg t "$repo_root/tests/fixtures/extract-basic.jsonl" --arg fp "$tmp/.claude/handoff-task.md" \
        '{cwd:$cwd, transcript_path:$t, tool_name:"Read", tool_input:{file_path:$fp}}' \
        | bash scripts/read-guard.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "read-guard not-activated exit code"
echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
    || fail "read-guard did not deny handoff-task.md read before activation"

# read-guard: handoff-task.md read allowed after activation.
echo "=== read-guard (handoff-task.md, activated: allow) ==="
set +e
out="$(
    jq -nc --arg cwd "$tmp" --arg t "$repo_root/tests/fixtures/activated-slash.jsonl" --arg fp "$tmp/.claude/handoff-task.md" \
        '{cwd:$cwd, transcript_path:$t, tool_name:"Read", tool_input:{file_path:$fp}}' \
        | bash scripts/read-guard.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "read-guard activated exit code"
assert_eq "$out" "" "read-guard activated produced no deny output"

# read-guard: unrelated file passes through.
echo "=== read-guard (unrelated file: allow) ==="
set +e
out="$(
    jq -nc --arg cwd "$tmp" --arg fp "$tmp/README.md" \
        '{cwd:$cwd, tool_name:"Read", tool_input:{file_path:$fp}}' \
        | bash scripts/read-guard.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "read-guard unrelated exit code"
assert_eq "$out" "" "read-guard unrelated produced no output"

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

# skill-pre-hook on the bare `handoff` arg wipes too — the Skill tool
# accepts both forms as launches of the same skill.
echo "=== skill-pre-hook (bare handoff: wipe) ==="
: > "$tmp/.claude/handoff-task.md"
: > "$tmp/.claude/handoff.md"
jq -nc --arg cwd "$tmp" \
    '{cwd:$cwd, tool_name:"Skill", tool_input:{skill:"handoff"}}' \
    | bash scripts/skill-pre-hook.sh >/dev/null
[[ ! -e "$tmp/.claude/handoff-task.md" ]] || fail "skill-pre-hook (bare) left handoff-task.md"
[[ ! -e "$tmp/.claude/handoff.md" ]] || fail "skill-pre-hook (bare) left handoff.md"

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
jq -nc '{tool_name:"Skill", tool_input:{skill:"handoff:handoff"}}' \
    | CLAUDE_PROJECT_DIR="$fresh" bash scripts/skill-pre-hook.sh
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

# load-handoff emits additionalContext + systemMessage when handoff.md
# exists. The script must be a no-op when the file is missing or empty.
# Exit code is always 0 (errors go to .claude/handoff-error.log).
echo "=== load-handoff (handoff.md present: emit) ==="
rm -f "$tmp/.claude/handoff.md"
cat > "$tmp/.claude/handoff.md" <<'HOF'
# Handoff — 2026-05-19 21:26:46 +0200

Session: `test-session`

## Current task

load-handoff sentinel cafef00d
HOF
# Touch the file to a recent mtime so the "saved" age is deterministic.
touch "$tmp/.claude/handoff.md"
set +e
out="$(
    jq -nc --arg cwd "$tmp" \
        '{cwd:$cwd, hook_event_name:"SessionStart"}' \
        | bash scripts/load-handoff.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "load-handoff exit code (present)"
ctx="$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')"
echo "$ctx" | grep -q 'load-handoff sentinel cafef00d' \
    || fail "load-handoff additionalContext missing inlined content"
echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null \
    || fail "load-handoff hookEventName != SessionStart"
msg="$(echo "$out" | jq -r '.systemMessage // ""')"
echo "$msg" | grep -Eq '^handoff loaded — [0-9]+ B, saved (just now|[0-9]+m ago)$' \
    || fail "load-handoff systemMessage format: '$msg'"

# load-handoff is a no-op when handoff.md is missing.
echo "=== load-handoff (missing handoff.md: no-op) ==="
rm -f "$tmp/.claude/handoff.md"
set +e
out="$(
    jq -nc --arg cwd "$tmp" \
        '{cwd:$cwd, hook_event_name:"SessionStart"}' \
        | bash scripts/load-handoff.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "load-handoff exit code (missing)"
echo "${out:-{}}" | jq -e '(.hookSpecificOutput.additionalContext // "") == "" and (.systemMessage // "") == ""' >/dev/null \
    || fail "load-handoff produced output when handoff.md missing: '$out'"

# load-handoff is a no-op when handoff.md is empty.
echo "=== load-handoff (empty handoff.md: no-op) ==="
: > "$tmp/.claude/handoff.md"
set +e
out="$(
    jq -nc --arg cwd "$tmp" \
        '{cwd:$cwd, hook_event_name:"SessionStart"}' \
        | bash scripts/load-handoff.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "load-handoff exit code (empty)"
echo "${out:-{}}" | jq -e '(.hookSpecificOutput.additionalContext // "") == "" and (.systemMessage // "") == ""' >/dev/null \
    || fail "load-handoff produced output when handoff.md empty: '$out'"

# load-handoff size formatting: bytes for <1024, KiB.X for >=1024.
echo "=== load-handoff (size formatting: KiB threshold) ==="
# 2048 bytes = exactly 2.0 KiB. `yes | head -c` triggers SIGPIPE on
# `yes` once head closes — tolerate it here (pure test setup).
set +o pipefail
yes "padding" | head -c 2048 > "$tmp/.claude/handoff.md"
set -o pipefail
touch "$tmp/.claude/handoff.md"
set +e
out="$(
    jq -nc --arg cwd "$tmp" \
        '{cwd:$cwd, hook_event_name:"SessionStart"}' \
        | bash scripts/load-handoff.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "load-handoff exit code (kib)"
msg="$(echo "$out" | jq -r '.systemMessage // ""')"
echo "$msg" | grep -Eq '^handoff loaded — 2\.0 KiB, saved' \
    || fail "load-handoff KiB formatting: '$msg'"

# load-handoff must survive handoffs larger than the per-argument execve
# limit (MAX_ARG_STRLEN = 128 KiB on Linux). Regression: passing the body
# via `jq --arg` crashed with "Argument list too long" and dropped the
# context; reading the file with `jq --rawfile` bypasses the limit.
echo "=== load-handoff (>128 KiB handoff: no arg-limit crash) ==="
set +o pipefail
yes "padding line to bulk up the handoff body well past the 128 KiB limit" \
    | head -c 153600 > "$tmp/.claude/handoff.md"
set -o pipefail
printf '\nbig-handoff sentinel deadbeef\n' >> "$tmp/.claude/handoff.md"
touch "$tmp/.claude/handoff.md"
set +e
out="$(
    jq -nc --arg cwd "$tmp" \
        '{cwd:$cwd, hook_event_name:"SessionStart"}' \
        | bash scripts/load-handoff.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "load-handoff exit code (>128 KiB)"
ctx="$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')"
echo "$ctx" | grep -q 'big-handoff sentinel deadbeef' \
    || fail "load-handoff dropped body of >128 KiB handoff (arg-limit crash)"

# write-rename: matching path, in tmux → deletes file, systemMessage confirms rename.
echo "=== write-rename (matching path, in tmux) ==="
echo "the title" > "$tmp/.claude/autorename"
set +e
out="$(
    jq -nc --arg cwd "$tmp" --arg fp "$tmp/.claude/autorename" \
        '{cwd:$cwd, tool_name:"Write", tool_input:{file_path:$fp}}' \
        | TMUX=fake TMUX_PANE='%0' bash scripts/write-rename.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "write-rename in-tmux exit code"
[[ ! -e "$tmp/.claude/autorename" ]] || fail "write-rename in-tmux: autorename not deleted"
echo "$out" | jq -e '.systemMessage | test("will rename")' >/dev/null \
    || fail "write-rename in-tmux: systemMessage missing 'will rename'"
echo "$out" | jq -e '.systemMessage | test("the title")' >/dev/null \
    || fail "write-rename in-tmux: systemMessage missing title"

# write-rename: matching path, not in tmux → deletes file, systemMessage has /rename line.
echo "=== write-rename (matching path, not in tmux) ==="
echo "the title" > "$tmp/.claude/autorename"
set +e
out="$(
    jq -nc --arg cwd "$tmp" --arg fp "$tmp/.claude/autorename" \
        '{cwd:$cwd, tool_name:"Write", tool_input:{file_path:$fp}}' \
        | env -u TMUX -u TMUX_PANE bash scripts/write-rename.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "write-rename not-in-tmux exit code"
[[ ! -e "$tmp/.claude/autorename" ]] || fail "write-rename not-in-tmux: autorename not deleted"
echo "$out" | jq -e '.systemMessage | test("/rename the title")' >/dev/null \
    || fail "write-rename not-in-tmux: systemMessage missing /rename line"

# write-rename: unrelated path → no-op.
echo "=== write-rename (unrelated path: no-op) ==="
set +e
jq -nc --arg cwd "$tmp" --arg fp "$tmp/README.md" \
    '{cwd:$cwd, tool_name:"Write", tool_input:{file_path:$fp}}' \
    | bash scripts/write-rename.sh
rc=$?
set -e
assert_eq "$rc" "0" "write-rename unrelated exit code"

# write-rename: empty autorename file → error message, file deleted.
echo "=== write-rename (empty file: error message) ==="
: > "$tmp/.claude/autorename"
set +e
out="$(
    jq -nc --arg cwd "$tmp" --arg fp "$tmp/.claude/autorename" \
        '{cwd:$cwd, tool_name:"Write", tool_input:{file_path:$fp}}' \
        | bash scripts/write-rename.sh
)"
rc=$?
set -e
assert_eq "$rc" "0" "write-rename empty exit code"
[[ ! -e "$tmp/.claude/autorename" ]] || fail "write-rename empty: autorename not deleted"
echo "$out" | jq -e '.systemMessage | test("empty")' >/dev/null \
    || fail "write-rename empty: systemMessage missing 'empty'"

if (( failures > 0 )); then
    printf '\n%d failure(s)\n' "$failures" >&2
    exit 1
fi
printf '\nall hook scenarios passed\n'
