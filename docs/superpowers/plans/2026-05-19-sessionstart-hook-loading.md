# SessionStart-hook Loading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `@.claude/handoff.md` ref-in-CLAUDE.md loading path with a `SessionStart(startup|clear)` hook that injects handoff content directly. Eliminate `/handoff:setup` and the "user never ran setup" failure class.

**Architecture:** New bash hook `scripts/load-handoff.sh` reads `$cwd/.claude/handoff.md` and emits its contents via `hookSpecificOutput.additionalContext` plus a curt `systemMessage` (bytes + age). `extract.py` inlines `handoff-task.md` contents into `handoff.md` at write time (replacing the now-obsolete `@handoff-task.md` line). The `skills/setup/` directory is removed entirely. Migration is release-notes only — users delete the `## Handoff` block from their project `CLAUDE.md`.

**Tech Stack:** bash, jq, python3, GNU coreutils + BSD-stat fallback for cross-platform `stat`.

**Reference spec:** `docs/superpowers/specs/2026-05-19-sessionstart-hook-loading-design.md`

**Out of scope:** Version bump in `.claude-plugin/plugin.json` — the `version-guard.sh` PreToolUse hook refuses agent edits to `.version`. The user runs `just release v0.3.0` manually after this plan completes.

---

## File Structure

**Add:**
- `scripts/load-handoff.sh` — SessionStart entry script. Bash. Reads `cwd`, checks for `.claude/handoff.md`, emits dual-channel JSON (`additionalContext` + `systemMessage`).

**Modify:**
- `scripts/extract.py` — inline `handoff-task.md` content; drop the `@handoff-task.md` marker line.
- `hooks/hooks.json` — add `SessionStart` block with matcher `startup|clear`.
- `tests/hook-test.sh` — update the existing write-extract assertion (it currently greps for `@handoff-task.md`); add load-handoff scenarios.
- `tests/extract-test.sh` — update fixtures and assertions for inlined task content.
- `skills/handoff/SKILL.md` — second paragraph mentions SessionStart loading.
- `skills/handoff/references/design.md` — mirror DESIGN.md updates.
- `DESIGN.md` — rewrite "Loading" section, update "Output schema", drop "Skills: handoff and setup" → "Skill: handoff".
- `CLAUDE.md` (project root) — update Layout, hooks summary; drop `skills/setup/SKILL.md` entry.

**Remove:**
- `skills/setup/` (entire directory).

**Untouched:** `scripts/skill-pre-hook.sh`, `scripts/prompt-pre-hook.sh`, `scripts/_wipe-emit.sh`, `scripts/write-guard.sh`, `scripts/write-extract.sh`, `plugin-dev/`, `.envrc`, `.claude/settings.json`.

---

## Task 1: Update extract.py tests for inlined task content (failing tests first)

**Why first:** `extract.py` is the foundational change. Tests fail before the script changes; updating the script makes them pass. Standard TDD.

**Files:**
- Modify: `tests/extract-test.sh`

- [ ] **Step 1.1: Replace `@handoff-task.md` assertions with inlined-content assertions**

The existing test asserts `@handoff-task.md` is present in the rendered output. After this change, the line is gone — replaced by the contents of a `handoff-task.md` written next to the output. The test must also create that task file (the script reads `<output_dir>/handoff-task.md`).

Open `tests/extract-test.sh`. Replace the entire `extract-basic` block (lines 39–88 in the current file) with:

```bash
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
```

- [ ] **Step 1.2: Replace empty-transcript assertions**

In the same file, replace the `empty-transcript` and `missing-transcript` blocks (lines 90–105 in the current file) with:

```bash
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
```

- [ ] **Step 1.3: Run the test, verify it fails**

Run: `bash tests/extract-test.sh`

Expected: FAIL — most assertions fail because `extract.py` still emits `@handoff-task.md` and never reads the task file. This is the failing-test state before Task 2 implements the change.

---

## Task 2: Update extract.py to inline task content

**Files:**
- Modify: `scripts/extract.py:182-188` (around the `@handoff-task.md` write)

- [ ] **Step 2.1: Replace the `@handoff-task.md` emission with inlining**

Open `scripts/extract.py`. Locate the `emit` function (around line 169). The current relevant lines are:

```python
    lines.append("@handoff-task.md")
    lines.append("")
```

Replace those two lines with:

```python
    task_path = output_path.parent / "handoff-task.md"
    if task_path.exists():
        task_content = task_path.read_text(encoding="utf-8", errors="replace").rstrip()
        if task_content:
            lines.append(task_content)
            lines.append("")
```

Rationale: `rstrip()` strips trailing whitespace/newlines from the task content (it may or may not end with a newline depending on how the agent wrote it). The `if task_content` guard handles the empty-file edge case (write the file but with no content). Either way, we follow with one blank line for visual separation from the next section.

- [ ] **Step 2.2: Update the module docstring**

In the same file, the module docstring (lines 3–32) shows the output format including `@handoff-task.md`. Replace the docstring's `Output format` block with:

```python
"""Extract session data into `.claude/handoff.md`.

Output format:

    # Handoff — <timestamp>

    Session: `<session-id>`

    <inlined contents of ./.claude/handoff-task.md, if it exists>

    ## Files touched
    - ...

    ## Last user prompts

    **after <anchor>**
    > <verbatim prompt>
    ...

The task content is read from `output_path.parent / "handoff-task.md"`
and inlined verbatim (rstripped, plus one trailing blank line). The
task file is agent-authored from the SKILL.md template; if missing,
the inlined block is omitted entirely (no placeholder text, no orphan
heading).

Usage:
    extract.py <transcript.jsonl> <output.md>

Missing or empty transcript is treated as "no session data" — the file
is still written with the extracted sections (or empty-section notes)
plus whatever the task file contains.
"""
```

- [ ] **Step 2.3: Run the test, verify it passes**

Run: `bash tests/extract-test.sh`

Expected: PASS — all `extract-basic`, `empty-transcript`, `missing-transcript`, and `missing-task` scenarios green. Output ends with: `all extract scenarios passed`.

- [ ] **Step 2.4: Update the write-extract assertion in hook-test.sh**

`tests/hook-test.sh` line 47–48 currently greps for `^@handoff-task.md$` and will now fail. Replace those two lines with an assertion that the inlined task content (the smoke fixture's "hook smoke test" string) is present:

```bash
grep -q 'hook smoke test' "$tmp/.claude/handoff.md" \
    || fail "handoff.md missing inlined task content"
grep -q '^@handoff-task.md$' "$tmp/.claude/handoff.md" \
    && fail "handoff.md should not contain @handoff-task.md ref"
```

- [ ] **Step 2.5: Run hook tests, verify they pass**

Run: `bash tests/hook-test.sh`

Expected: PASS — all existing wipe/guard/extract scenarios green. The new load-handoff scenarios don't exist yet (they're added in Task 3). Output ends with: `all hook scenarios passed`.

- [ ] **Step 2.6: Commit**

```bash
git add scripts/extract.py tests/extract-test.sh tests/hook-test.sh
git commit -m "$(cat <<'EOF'
♻️ extract: inline handoff-task.md instead of @-ref

Replaces the `@handoff-task.md` marker line in `handoff.md` with the
inlined contents of `<output_dir>/handoff-task.md`. Prepares for the
SessionStart hook (which reads a single self-contained file) and
drops the dependency on Claude Code's `@` resolution for the load
path.

Tests updated: extract-test covers inlining + missing-task path;
hook-test covers the same via write-extract.
EOF
)"
```

---

## Task 3: Add `scripts/load-handoff.sh` with tests

**Files:**
- Test: `tests/hook-test.sh` (add scenarios)
- Create: `scripts/load-handoff.sh`

- [ ] **Step 3.1: Add load-handoff test scenarios to hook-test.sh**

Append these scenarios to `tests/hook-test.sh` immediately before the final failures-summary block (`if (( failures > 0 )); then`):

```bash
# load-handoff emits additionalContext + systemMessage when handoff.md
# exists. The script must be a no-op when the file is missing or empty.
echo "=== load-handoff (handoff.md present: emit) ==="
load_dir="$(mktemp -d)"
mkdir -p "$load_dir/.claude"
cat > "$load_dir/.claude/handoff.md" <<'HOF'
# Handoff — 2026-05-19 21:26:46 +0200

Session: `test-session`

## Current task

load-handoff sentinel cafef00d
HOF
# Touch the file to a recent mtime so the "saved" age is deterministic.
touch "$load_dir/.claude/handoff.md"
out="$(
    jq -nc --arg cwd "$load_dir" \
        '{cwd:$cwd, hook_event_name:"SessionStart"}' \
        | bash scripts/load-handoff.sh
)"
ctx="$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')"
echo "$ctx" | grep -q 'load-handoff sentinel cafef00d' \
    || fail "load-handoff additionalContext missing inlined content"
echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null \
    || fail "load-handoff hookEventName != SessionStart"
msg="$(echo "$out" | jq -r '.systemMessage // ""')"
echo "$msg" | grep -Eq '^handoff loaded — [0-9]+ B, saved (just now|[0-9]+m ago)$' \
    || fail "load-handoff systemMessage format: '$msg'"
rm -rf "$load_dir"

# load-handoff is a no-op when handoff.md is missing.
echo "=== load-handoff (missing handoff.md: no-op) ==="
load_dir="$(mktemp -d)"
out="$(
    jq -nc --arg cwd "$load_dir" \
        '{cwd:$cwd, hook_event_name:"SessionStart"}' \
        | bash scripts/load-handoff.sh
)"
[[ -z "$out" ]] || fail "load-handoff produced output when handoff.md missing: '$out'"
rm -rf "$load_dir"

# load-handoff is a no-op when handoff.md is empty.
echo "=== load-handoff (empty handoff.md: no-op) ==="
load_dir="$(mktemp -d)"
mkdir -p "$load_dir/.claude"
: > "$load_dir/.claude/handoff.md"
out="$(
    jq -nc --arg cwd "$load_dir" \
        '{cwd:$cwd, hook_event_name:"SessionStart"}' \
        | bash scripts/load-handoff.sh
)"
[[ -z "$out" ]] || fail "load-handoff produced output when handoff.md empty: '$out'"
rm -rf "$load_dir"

# load-handoff size formatting: bytes for <1024, KiB.X for >=1024.
echo "=== load-handoff (size formatting: KiB threshold) ==="
load_dir="$(mktemp -d)"
mkdir -p "$load_dir/.claude"
# 2048 bytes = exactly 2.0 KiB.
yes "padding" | head -c 2048 > "$load_dir/.claude/handoff.md"
touch "$load_dir/.claude/handoff.md"
out="$(
    jq -nc --arg cwd "$load_dir" \
        '{cwd:$cwd, hook_event_name:"SessionStart"}' \
        | bash scripts/load-handoff.sh
)"
msg="$(echo "$out" | jq -r '.systemMessage // ""')"
echo "$msg" | grep -Eq '^handoff loaded — 2\.0 KiB, saved' \
    || fail "load-handoff KiB formatting: '$msg'"
rm -rf "$load_dir"
```

- [ ] **Step 3.2: Run tests, verify load-handoff scenarios fail**

Run: `bash tests/hook-test.sh`

Expected: FAIL — the four new scenarios fail because `scripts/load-handoff.sh` does not exist yet. Existing scenarios still pass.

- [ ] **Step 3.3: Create `scripts/load-handoff.sh`**

Create the new file with the following contents:

```bash
#!/usr/bin/env bash
# SessionStart hook for handoff loading. Fires on `startup` and
# `clear` (see hooks/hooks.json). Reads $cwd/.claude/handoff.md and:
#   - emits its contents via hookSpecificOutput.additionalContext so
#     the fresh agent sees the handoff in its input for this turn;
#   - emits a curt systemMessage with file size + age for the user
#     ("handoff loaded — 3.2 KiB, saved 8m ago").
# Silent no-op when handoff.md is missing or empty. Errors are logged
# to .claude/handoff-error.log; the hook exits 0 either way so a
# failure never blocks session startup.
set -euo pipefail

input="$(cat)"
cwd="$(jq -r '.cwd // ""' <<<"$input")"
hook_event="$(jq -r '.hook_event_name // "SessionStart"' <<<"$input")"
[[ -n "$cwd" ]] || cwd="$PWD"

handoff="$cwd/.claude/handoff.md"
log="$cwd/.claude/handoff-error.log"

[[ -s "$handoff" ]] || exit 0

if ! content="$(cat "$handoff" 2>"$log")"; then
    tail=$(tail -c 400 "$log" 2>/dev/null | tr '\n' ' ')
    jq -nc --arg log "$log" --arg tail "$tail" \
        '{systemMessage: ("handoff load failed (see " + $log + "): " + $tail)}'
    exit 0
fi
rm -f "$log"

bytes=$(wc -c < "$handoff" | tr -d ' ')
if (( bytes < 1024 )); then
    size="${bytes} B"
else
    size=$(awk -v b="$bytes" 'BEGIN { printf "%.1f KiB", b/1024 }')
fi

# GNU `stat -c %Y` on Linux; fall back to BSD `stat -f %m` on macOS.
mtime=$(stat -c '%Y' "$handoff" 2>/dev/null || stat -f '%m' "$handoff")
now=$(date +%s)
delta=$(( now - mtime ))
if (( delta < 60 )); then
    age="just now"
elif (( delta < 3600 )); then
    age="$((delta / 60))m ago"
elif (( delta < 86400 )); then
    age="$((delta / 3600))h ago"
else
    age="$((delta / 86400))d ago"
fi

msg="handoff loaded — ${size}, saved ${age}"

jq -nc \
    --arg m "$msg" \
    --arg c "$content" \
    --arg e "$hook_event" \
    '{systemMessage: $m, hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
```

- [ ] **Step 3.4: Make the script executable**

Run: `chmod +x scripts/load-handoff.sh`

(The other scripts in `scripts/` are likewise executable — keeps the perm bit consistent.)

- [ ] **Step 3.5: Run tests, verify they pass**

Run: `bash tests/hook-test.sh`

Expected: PASS — all scenarios including the four new load-handoff cases green. Output ends with: `all hook scenarios passed`.

- [ ] **Step 3.6: Commit**

```bash
git add scripts/load-handoff.sh tests/hook-test.sh
git commit -m "$(cat <<'EOF'
✨ load-handoff: SessionStart hook injects handoff content

New `scripts/load-handoff.sh` reads $cwd/.claude/handoff.md, emits the
contents via hookSpecificOutput.additionalContext (so the fresh agent
sees the handoff in its input), and a curt systemMessage with bytes
+ relative age for the user. Silent no-op when the file is missing or
empty; errors log to .claude/handoff-error.log without blocking
session startup.

Tests cover: present-emits, missing-noop, empty-noop, KiB threshold
formatting.

Not yet wired into hooks.json — that's the next commit.
EOF
)"
```

---

## Task 4: Wire SessionStart into hooks.json

**Files:**
- Modify: `hooks/hooks.json`

- [ ] **Step 4.1: Add SessionStart block**

Open `hooks/hooks.json`. After the `PostToolUse` block (closing at line 47 in the current file), but inside the `hooks` object (before its closing `}`), add:

```json
    ,
    "SessionStart": [
      {
        "matcher": "startup|clear",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/load-handoff.sh",
            "timeout": 5
          }
        ]
      }
    ]
```

The leading comma is required because `PostToolUse` is no longer the last key. JSON does not allow trailing commas, so the comma goes before the new key.

Final file should look like:

```json
{
  "description": "...",
  "hooks": {
    "UserPromptSubmit": [...],
    "PreToolUse": [...],
    "PostToolUse": [...],
    "SessionStart": [
      {
        "matcher": "startup|clear",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/load-handoff.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 4.2: Update the top-level `description`**

Same file. Replace the existing top-level `description` value with one that mentions the new hook. Concretely:

```json
  "description": "SessionStart(startup|clear): inject handoff.md content via additionalContext. PreToolUse(Skill) and UserPromptSubmit: wipe prior handoff files when handoff:handoff activates (covers both the Skill-tool and slash-command invocation paths). PreToolUse(Write|Edit): deny handoff-task.md writes outside this project's .claude/. PostToolUse(Write|Edit): regenerate .claude/handoff.md when handoff-task.md is written.",
```

- [ ] **Step 4.3: Verify JSON validity**

Run: `jq -e . hooks/hooks.json > /dev/null && echo ok`

Expected: `ok`. If `jq` reports a parse error, fix the JSON before continuing.

- [ ] **Step 4.4: Run precommit (lints manifests including hooks.json)**

Run: `just precommit`

Expected: PASS. All checks green: manifest lint, syntax checks, hook-test suite, extract-test suite.

- [ ] **Step 4.5: Commit**

```bash
git add hooks/hooks.json
git commit -m "$(cat <<'EOF'
✨ hooks: wire SessionStart(startup|clear) load-handoff

Activates the new `scripts/load-handoff.sh` on session startup and
after `/clear`. Skip `resume` — the prior JSONL already contains the
content from when this hook fired earlier.

Top-level description updated to list the new hook alongside the
existing four.
EOF
)"
```

---

## Task 5: Remove the setup skill

**Files:**
- Remove: `skills/setup/` (entire directory)

- [ ] **Step 5.1: Delete the directory**

Run: `git rm -r skills/setup/`

Expected output: `rm 'skills/setup/SKILL.md'` (the directory contains only this one file).

- [ ] **Step 5.2: Verify no other file references the setup skill path**

Run: `git grep -n 'skills/setup' || echo "(no references)"`

Expected: `(no references)`. If grep finds anything, those references will be updated in Task 6 (docs). If grep finds references in code (scripts, hooks, settings), stop and reconsider — the setup skill should have no code dependencies, only doc mentions.

- [ ] **Step 5.3: Run hook tests (should still pass — no script depends on the setup skill)**

Run: `bash tests/hook-test.sh`

Expected: PASS. The `/handoff:setup` no-op assertion in prompt-pre-hook tests (line 161 region) still passes — it's testing that prompts other than `/handoff:handoff` don't trigger the wipe, and `/handoff:setup` is one such prompt. Even though the skill itself is gone, the prompt-pre-hook behavior is unchanged.

- [ ] **Step 5.4: Commit**

```bash
git add -u skills/setup
git commit -m "$(cat <<'EOF'
🔥 remove /handoff:setup skill

The skill existed only to add `@.claude/handoff.md` to the project
CLAUDE.md so the @-ref would resolve at session start. With loading
now handled by the SessionStart hook, the skill is obsolete.

Migration is documented in the v0.3.0 release notes: users delete
the `## Handoff` block from their project CLAUDE.md. Leaving it in
place is harmless but causes content to load twice.
EOF
)"
```

---

## Task 6: Update documentation

**Files:**
- Modify: `DESIGN.md`
- Modify: `CLAUDE.md` (project root)
- Modify: `skills/handoff/SKILL.md`
- Modify: `skills/handoff/references/design.md`

This task has the most prose. Each step is one file, with concrete edits described.

- [ ] **Step 6.1: Update `DESIGN.md` — invert the Loading section**

Open `DESIGN.md`. Find the section titled `## Loading: \`@\` reference in CLAUDE.md, not a SessionStart hook` (around line 288).

Replace the entire section (heading + body, through to the next `##` heading) with:

```markdown
## Loading: SessionStart hook, not an `@` reference

An earlier iteration shipped an `@.claude/handoff.md` reference in the
project `CLAUDE.md`, added by a `/handoff:setup` skill. The chain
worked — Claude Code resolved `@` refs at session start, recursively
up to 5 hops, pulling the artifact into context — but it produced one
structural failure mode:

> User enables the plugin, invokes `/handoff:handoff`, runs `/clear`,
> and the next session sees nothing because they never ran setup.

Loading via a `SessionStart(startup|clear)` hook eliminates that class
entirely. The plugin owns its own load path; no setup step, no
CLAUDE.md mutation, no detection-and-warn machinery. See
`docs/superpowers/specs/2026-05-19-sessionstart-hook-loading-design.md`
for the full decision record.

Matcher choice: `startup` covers fresh `claude` invocations; `clear`
covers in-session `/clear`. `resume` is omitted — the prior JSONL
already contains the injection from when this hook fired earlier.

The hook (`scripts/load-handoff.sh`) reads `$cwd/.claude/handoff.md`
and emits its contents via `hookSpecificOutput.additionalContext`. A
curt `systemMessage` ("handoff loaded — 3.2 KiB, saved 8m ago") is
emitted alongside for the user. Errors log to `handoff-error.log`
and exit 0 so a hook failure never blocks session startup.

Token measurement: the `systemMessage` reports bytes, not API
tokens. Anthropic has not open-sourced an exact offline tokenizer for
Claude 3+; the `messages.count_tokens` API endpoint is the only
precise option, and adds a network round-trip, an API key
dependency, and a caching subsystem the plugin doesn't otherwise
need. Bytes answers "is this material enough to care?" just as well
for a 1–5 KiB artifact.
```

- [ ] **Step 6.2: Update `DESIGN.md` — Output schema**

In `DESIGN.md`, find the `## Output schema` section (around line 323). Replace the markdown example block with:

```markdown
## Output schema

```markdown
# Handoff — <timestamp>

Session: `<session-id>`

<inlined contents of ./.claude/handoff-task.md, if it exists>

## Files touched
<extracted>

## Last user prompts

**after <anchor>**
> <verbatim user message>

...
```
```

Below the example, replace the explanatory paragraph with:

```markdown
Location: `./.claude/handoff.md`. Overwrites previous. History is in
git (if the user commits the file) or the session JSONL. The task
content is inlined verbatim at write time by `extract.py` (reading
`./.claude/handoff-task.md`); if the task file is missing the
inlined block is omitted entirely.
```

- [ ] **Step 6.3: Update `DESIGN.md` — Skills section**

In `DESIGN.md`, find the `## Skills: handoff and setup` section (around line 360). Replace the section heading + body (down to the next `##`) with:

```markdown
## Skill: handoff

One skill ships with the plugin:

- **`/handoff:handoff`** — the main skill. Updates memory, then
  decides whether to write `handoff-task.md` from a template. The
  cleanup case is handled by the PreToolUse hook at activation; the
  load case is handled by the SessionStart hook at the next session.

The skill is named `handoff` (matching the plugin) so CLI completion
on `/handoff:` lands directly on the action, with no second namespace
hop.

An earlier `/handoff:setup` skill was removed in v0.3.0 — see the
Loading section above.
```

- [ ] **Step 6.4: Update `DESIGN.md` — bump the Last-updated line**

In `DESIGN.md`, at the top, find the line `Last updated: 2026-04-29.` and replace with:

```markdown
Last updated: 2026-05-19.
```

- [ ] **Step 6.5: Update project `CLAUDE.md` — Layout section**

Open `CLAUDE.md` at the project root. Find the Layout section.

(a) Remove the `skills/setup/SKILL.md` entry entirely (4 lines starting with `- \`skills/setup/SKILL.md\``).

(b) Update the `hooks/hooks.json` entry. Replace the description block (currently lists 4 hooks) with:

```markdown
- `hooks/hooks.json` — declares five hooks.
  `SessionStart(startup|clear)`: inject handoff.md content into the
  fresh agent's context via additionalContext.
  `PreToolUse(Skill)` and `UserPromptSubmit`: wipe prior handoff files
  when `handoff:handoff` activates. The two together cover both
  invocation paths — the `Skill` tool (agent-driven) and the slash
  command `/handoff:handoff` (user-driven, which loads the skill body
  directly without going through the `Skill` tool).
  `PreToolUse(Write|Edit)`: deny `handoff-task.md` writes whose
  resolved path is not `$cwd/.claude/handoff-task.md`.
  `PostToolUse(Write|Edit)`: regenerate `.claude/handoff.md` whenever
  `handoff-task.md` is written, so extraction is visible in the same
  agent turn.
```

(c) Add a new entry for `scripts/load-handoff.sh` after `scripts/skill-pre-hook.sh` (or in a position that groups it with other entry scripts):

```markdown
- `scripts/load-handoff.sh` — SessionStart(startup|clear) entry
  point. Reads `$cwd/.claude/handoff.md` and emits its contents via
  `hookSpecificOutput.additionalContext` (agent-facing) plus a curt
  `systemMessage` with bytes + age (user-facing). Silent no-op when
  the file is missing or empty.
```

(d) Find the paragraph that begins `Loading is delegated to the user's project \`CLAUDE.md\` via \`@.claude/handoff.md\`...` and replace it with:

```markdown
Loading is handled by the `SessionStart(startup|clear)` hook —
`load-handoff.sh` reads `.claude/handoff.md` and injects its contents
directly into the fresh agent's input. No user setup, no CLAUDE.md
mutation required.
```

- [ ] **Step 6.6: Update `skills/handoff/SKILL.md`**

Open `skills/handoff/SKILL.md`. Find the second paragraph (currently starts `Preserve the irreducible residual...`). Replace the second sentence onward (everything after "what's still undecided.") with:

```markdown
A `PreToolUse(Skill)` hook wipes
any prior handoff files before this skill runs, so every invocation
starts clean. A `PostToolUse(Write|Edit)` hook regenerates
`.claude/handoff.md` (inlining the task content, plus last user
prompts and files touched) the moment the task file is written, so
extraction is visible in the same turn. A
`SessionStart(startup|clear)` hook injects that file into the next
session.
```

- [ ] **Step 6.7: Update `skills/handoff/references/design.md`**

Open `skills/handoff/references/design.md`. The file is a condensed mirror of `DESIGN.md`. Read the file and apply parallel updates:

- Any mention of "@ reference" / "@.claude/handoff.md" loading → replace with "SessionStart hook loading"
- Any mention of `/handoff:setup` → remove the bullet (and any reference to it as a skill the plugin ships)
- Add one sentence noting that task content is inlined at write time rather than `@`-referenced

The exact edits depend on the current content; read the file first, then make matching updates inline. Keep the file short — it's a condensed reference, not a full duplicate.

- [ ] **Step 6.8: Run precommit (lints docs and runs all tests)**

Run: `just precommit`

Expected: PASS. All checks green.

- [ ] **Step 6.9: Commit**

```bash
git add DESIGN.md CLAUDE.md skills/handoff/SKILL.md skills/handoff/references/design.md
git commit -m "$(cat <<'EOF'
📝 docs: SessionStart-hook loading

Inverts the earlier "@ reference in CLAUDE.md" decision in DESIGN.md
and updates the downstream documents (project CLAUDE.md, SKILL.md,
condensed design reference) to describe the new load path. The
setup-skill bullet is gone everywhere it appeared.

See docs/superpowers/specs/2026-05-19-sessionstart-hook-loading-design.md
for the full decision record.
EOF
)"
```

---

## Task 7: Final verification

**Files:** none modified.

- [ ] **Step 7.1: Full test suite**

Run: `just precommit`

Expected: PASS — manifest lint, all script syntax checks, full hook-test suite (including new load-handoff scenarios), full extract-test suite (including inlining + missing-task), no warnings.

- [ ] **Step 7.2: Smoke test against a real JSONL**

Run: `just smoke`

Expected: prints a rendered `handoff.md`. The output should contain the inlined contents of whatever `handoff-task.md` exists in the project's `.claude/` (or omit the block if not present), and NOT contain the line `@handoff-task.md`.

- [ ] **Step 7.3: Manual end-to-end sanity check (optional)**

Optional but recommended: invoke `/handoff:handoff` in a real session, save a task, exit, restart Claude Code, verify the SessionStart hook fires and the `systemMessage` appears in the transcript as `handoff loaded — N B, saved (just now|Nm ago)`.

- [ ] **Step 7.4: Hand off to the user for release**

Print, verbatim:

```
Implementation complete. Ready for release.

The version bump to 0.3.0 cannot be done by the agent (version-guard
hook refuses it). Run, in this order:

  1. cd $MARKETPLACE_DIR && git status   # verify marketplace tree clean
  2. cd back to the handoff repo
  3. just release v0.3.0                 # bumps plugin.json, tags, pushes, bumps marketplace

Release notes to paste into the GitHub release body:

> **Breaking**: handoff content now loads via a SessionStart hook
> instead of the `@.claude/handoff.md` reference. The `/handoff:setup`
> skill has been removed.
>
> **To migrate**: open your project's `./CLAUDE.md` and delete the
> `## Handoff` section that contains `@.claude/handoff.md`. Leaving it
> in place is harmless but causes the content to load twice (once via
> the hook, once via the `@`-ref).
```

Do not run `just release` yourself.

---

## Self-Review

(Checked inline by the planner. Captured here for traceability.)

**Spec coverage:**
- ✓ SessionStart matcher `startup|clear` → Task 4.
- ✓ `load-handoff.sh` script: cwd/handoff.md read, additionalContext, systemMessage with bytes+age, silent no-op, error logging → Task 3.
- ✓ `extract.py` inlines task content, omits when missing → Task 2.
- ✓ Drop `/handoff:setup` skill entirely → Task 5.
- ✓ DESIGN.md / CLAUDE.md / SKILL.md / references/design.md updates → Task 6.
- ✓ Migration release notes documented → Task 7.4.
- ✓ Tests: automated bash with assertions, run under `just precommit` → all test tasks.
- ✓ Token measurement: bytes only, documented as non-goal in DESIGN.md → Step 6.1.

**Placeholder scan:** no "TBD"/"TODO"/"implement later"/"similar to Task N" patterns. Every code-changing step contains the actual code or grep-able anchors. The one prose-edit step that depends on current file contents (Step 6.7, `references/design.md`) instructs the executor to read first because the file is small and changes can be inferred — acceptable because the substitution rules are stated explicitly.

**Type consistency:**
- Hook script name: `load-handoff.sh` everywhere.
- Matcher string: `"startup|clear"` (literal, not separate strings).
- systemMessage shape: `handoff loaded — <size>, saved <age>` consistent across script, tests, and DESIGN.md.
- additionalContext field path: `hookSpecificOutput.additionalContext` matches existing wipe hooks.
- hookEventName: `"SessionStart"` in script + test (matches PreToolUse / UserPromptSubmit convention from existing hooks).
