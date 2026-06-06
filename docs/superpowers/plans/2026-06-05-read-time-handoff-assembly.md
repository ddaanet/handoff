# Read-Time Handoff Assembly Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the generated `handoff.md` file; assemble the handoff frame in memory at SessionStart from a stored transcript pointer, bounded to the handoff moment, and version `handoff-task.md`.

**Architecture:** Move extraction from write-time (`PostToolUse`) to read-time (`SessionStart`). At handoff activation the wipe hook stores the session's `transcript_path` to `.claude/handoff-session`. At the next session, `load-handoff.sh` reads that pointer, runs `extract.py` (now emitting to stdout, bounded at the last handoff activation marker), and injects the result via `additionalContext`. `handoff.md` is never written. `handoff-task.md` becomes a tracked, versioned task trail; only its staging survives the old `PostToolUse` path.

**Tech Stack:** Bash hook scripts, Python 3 (`extract.py`), `jq`, Claude Code plugin hooks. Tests: `just extract-test` (fixture-driven), `just hook-test` (synthetic payloads), `just smoke`, `just precommit` (shellcheck + manifest lint).

**Design reference:** `DESIGN.md` → *Read-time assembly: pointer + bounded scrape (2026-06-05)*.

---

## File Structure

Created:
- `tests/fixtures/extract-bounded.jsonl` — prompts before + after a `Skill` activation marker, for the cut test.
- `scripts/write-stage.sh` — slim `PostToolUse(Write|Edit)` hook: `git add -f handoff-task.md` only (replaces `write-extract.sh`).

Modified:
- `scripts/_lib.sh` — add `HANDOFF_REL_SESSION`; remove `HANDOFF_REL_OUT`.
- `scripts/extract.py` — bounded cut at last activation; emit to stdout; task path from argv.
- `scripts/load-handoff.sh` — gate on task file; read pointer; assemble via `extract.py`; inject.
- `scripts/_wipe-emit.sh` — write the pointer (unconditional); accept `transcript_path` arg.
- `scripts/skill-pre-hook.sh`, `scripts/prompt-pre-hook.sh` — thread `transcript_path` into `_wipe-emit.sh`.
- `scripts/read-guard.sh`, `scripts/write-guard.sh` — drop the `handoff.md` (`exp_out`) branch.
- `hooks/hooks.json` — `write-extract.sh` → `write-stage.sh`.
- `tests/extract-test.sh`, `tests/hook-test.sh`, `tests/smoke.sh` — adapt to stdout/pointer; add cut coverage.
- `.claude-plugin/plugin.json` — version `0.4.1` → `0.5.0` (breaking: output path removed).
- `README.md`, `CLAUDE.md` — document the pointer, versioning, removal of `handoff.md`.

Deleted:
- `scripts/write-extract.sh` (replaced by `write-stage.sh`).

---

## Task 1: Path constants — add pointer, retire output

**Files:**
- Modify: `scripts/_lib.sh:9-16`

- [ ] **Step 1: Edit the constants block**

Replace the `HANDOFF_REL_OUT` constant with `HANDOFF_REL_SESSION`. In `scripts/_lib.sh`, the block currently reads:

```bash
HANDOFF_REL_TASK=".claude/handoff-task.md"
# shellcheck disable=SC2034
HANDOFF_REL_OUT=".claude/handoff.md"
# shellcheck disable=SC2034
HANDOFF_REL_ERR=".claude/handoff-error.log"
# shellcheck disable=SC2034
HANDOFF_REL_RENAME=".claude/autorename"
```

Change to:

```bash
HANDOFF_REL_TASK=".claude/handoff-task.md"
# shellcheck disable=SC2034  # machine-local pointer to the prior session JSONL
HANDOFF_REL_SESSION=".claude/handoff-session"
# shellcheck disable=SC2034
HANDOFF_REL_ERR=".claude/handoff-error.log"
# shellcheck disable=SC2034
HANDOFF_REL_RENAME=".claude/autorename"
```

- [ ] **Step 2: Verify nothing else references the old constant yet**

Run: `grep -rn HANDOFF_REL_OUT scripts/`
Expected: matches only in `read-guard.sh`, `write-guard.sh`, `write-extract.sh` (all rewritten/deleted in later tasks). Note them; do not fix here.

- [ ] **Step 3: Commit**

```bash
git add scripts/_lib.sh
git commit -m "refactor: replace HANDOFF_REL_OUT with HANDOFF_REL_SESSION pointer constant"
```

---

## Task 2: Bounded cut + stdout in `extract.py`

The cut excludes the `save handoff` request and any post-handoff prompts. The marker is the last activation signal in the **raw** JSONL (so the `isMeta` slash entry is still detectable), reusing the same two signals as `handoff_activated()`.

**Files:**
- Modify: `scripts/extract.py`
- Test: `tests/extract-test.sh`, `tests/fixtures/extract-bounded.jsonl`

- [ ] **Step 1: Write the bounded-cut fixture**

Create `tests/fixtures/extract-bounded.jsonl`. Two real user prompts, then a `Skill` activation tool_use, then a post-handoff prompt that must be excluded:

```jsonl
{"type":"user","message":{"role":"user","content":"BOUNDED_KEEP_ONE first real prompt"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working on it"}]}}
{"type":"user","message":{"role":"user","content":"BOUNDED_KEEP_TWO second real prompt"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"handoff:handoff"}}]}}
{"type":"user","message":{"role":"user","content":"BOUNDED_DROP_AFTER post-handoff digression"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}
```

- [ ] **Step 2: Add the failing test to `tests/extract-test.sh`**

Insert before the final `if (( failures > 0 ))` block. Note the new invocation form (stdout capture, task path as argv[2]):

```bash
# extract-bounded.jsonl: prompts after the last handoff activation marker
# are excluded; prompts before it are kept. The "save handoff" turn and any
# post-handoff digression must not leak into the next session's frame.
echo "=== extract-bounded (cut at last activation) ==="
out_dir="$tmp/bounded"
mkdir -p "$out_dir"
out="$out_dir/handoff.md"
python3 scripts/extract.py tests/fixtures/extract-bounded.jsonl "$out_dir/handoff-task.md" > "$out"
assert_contains "$out" "BOUNDED_KEEP_ONE" "bounded: pre-activation prompt 1 kept"
assert_contains "$out" "BOUNDED_KEEP_TWO" "bounded: pre-activation prompt 2 kept"
assert_not_contains "$out" "BOUNDED_DROP_AFTER" "bounded: post-activation prompt excluded"
```

- [ ] **Step 3: Run it to verify it fails**

Run: `just extract-test`
Expected: FAIL — current `extract.py` writes to the file given as argv[2] and ignores stdout, so `$out` is empty and `BOUNDED_KEEP_ONE` is missing; the `assert_not_contains` also fails because no bounding exists.

- [ ] **Step 4: Implement bounding + stdout in `extract.py`**

Make four changes to `scripts/extract.py`.

(a) Add the activation-marker scan and a raw-line loader near the top, after the `WRAPPER_EXACT` block:

```python
SLASH_MARKER = "<command-name>/handoff:handoff</command-name>"


def _is_activation(entry: dict) -> bool:
    msg = entry.get("message") or {}
    if msg.get("role") == "assistant":
        for block in msg.get("content") or []:
            if (isinstance(block, dict)
                    and block.get("type") == "tool_use"
                    and block.get("name") == "Skill"
                    and (block.get("input") or {}).get("skill") in ("handoff", "handoff:handoff")):
                return True
    if entry.get("type") == "user":
        content = msg.get("content")
        if isinstance(content, str) and SLASH_MARKER in content:
            return True
    return False
```

(b) Replace `load_entries` so it reads once, finds the cut at the last activation, and parses only the slice before it (keeping the existing `isSidechain`/`isMeta` filters):

```python
def load_entries(transcript: pathlib.Path) -> list[dict]:
    raw: list[dict] = []
    for line in transcript.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            raw.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    # Bound at the last handoff activation: drop the "save handoff" turn and
    # everything after it. The marker is found on raw entries so the isMeta
    # slash entry is still detectable before the isMeta filter below.
    cut = len(raw)
    for i in range(len(raw) - 1, -1, -1):
        if _is_activation(raw[i]):
            cut = i
            break
    entries: list[dict] = []
    for entry in raw[:cut]:
        if entry.get("isSidechain") or entry.get("isMeta"):
            continue
        entries.append(entry)
    return entries
```

(c) In `emit`, take the task path from a parameter instead of `output_path.parent`, and build the text without writing a file. Change the signature and the tail of `emit`:

```python
def emit(transcript_path: str, task_path: str) -> None:
    entries: list[dict] = []
    transcript = pathlib.Path(transcript_path) if transcript_path else None
    if transcript and transcript.exists():
        entries = load_entries(transcript)

    files_touched = extract_files_touched(entries)
    user_prompts = extract_user_prompts(entries)
    tail_prompts = user_prompts[-LAST_N_PROMPTS:]

    now = _dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    session_id = transcript.stem if transcript else "(no transcript)"

    lines: list[str] = []
    lines.append(f"# Handoff — {now}")
    lines.append("")
    lines.append(f"Session: `{session_id}`")
    lines.append("")
    task = pathlib.Path(task_path)
    if task.exists():
        task_content = task.read_text(encoding="utf-8", errors="replace").rstrip()
        if task_content:
            lines.append(task_content)
            lines.append("")
    lines.append("## Files touched")
    # ... (unchanged through the prompts section) ...
    sys.stdout.write("\n".join(lines) + "\n")
```

Keep the `## Files touched` and `## Last user prompts` rendering exactly as-is; only the final `output_path.write_text(...)` is replaced by the `sys.stdout.write(...)` above, and the `output_path.parent.mkdir(...)` line is removed.

(d) Update `main` to the new two-arg contract (transcript, task path) and drop the printed output path:

```python
def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <transcript.jsonl> <handoff-task.md>", file=sys.stderr)
        return 2
    emit(argv[1], argv[2])
    return 0
```

- [ ] **Step 5: Adapt the existing extract-test invocations to stdout**

Every call in `tests/extract-test.sh` of the form `python3 scripts/extract.py <transcript> "$out" > /dev/null` must become `python3 scripts/extract.py <transcript> "$out_dir/handoff-task.md" > "$out"`. There are five (basic, empty, missing, missing-task, skill-meta, anchor-multiline). For the `missing-task` case (no task file), pass a path that does not exist: `"$out_dir/handoff-task.md"` (the dir has none), preserving the assertion that the inlined block is absent.

- [ ] **Step 6: Run the test to verify it passes**

Run: `just extract-test`
Expected: PASS — `all extract scenarios passed`, including the three bounded assertions.

- [ ] **Step 7: Commit**

```bash
git add scripts/extract.py tests/extract-test.sh tests/fixtures/extract-bounded.jsonl
git commit -m "feat: bound extract.py at last handoff activation, emit to stdout"
```

---

## Task 3: Write the pointer at activation

**Files:**
- Modify: `scripts/_wipe-emit.sh`, `scripts/skill-pre-hook.sh`, `scripts/prompt-pre-hook.sh`
- Test: `tests/hook-test.sh`

- [ ] **Step 1: Add a failing pointer test to `tests/hook-test.sh`**

After the `handoff_deny` section, before the `write-extract` section:

```bash
# Activation writes the session pointer (current transcript_path) so the
# next session knows which JSONL to scrape.
echo "=== activation pointer (skill path) ==="
ptr_tmp="$(mktemp -d)"; mkdir -p "$ptr_tmp/.claude"
jq -nc --arg t "$transcript" \
    '{tool_name:"Skill", tool_input:{skill:"handoff:handoff"}, transcript_path:$t}' \
    | CLAUDE_PROJECT_DIR="$ptr_tmp" bash scripts/skill-pre-hook.sh >/dev/null
assert_eq "$(cat "$ptr_tmp/.claude/handoff-session" 2>/dev/null)" "$transcript" \
    "activation: pointer holds transcript_path"
rm -rf "$ptr_tmp"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `just hook-test`
Expected: FAIL — `handoff-session` is not created; assertion gets empty string.

- [ ] **Step 3: Add the `transcript_path` arg to `_wipe-emit.sh` and write the pointer**

In `scripts/_wipe-emit.sh`, accept a third argument and write the pointer unconditionally (before the `removed`-count early-exit). Source `_lib.sh` for the constant. The head of the script becomes:

```bash
# Usage: _wipe-emit.sh <cwd> <hook_event_name> <transcript_path>
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

cwd="${1:?cwd required}"
hook_event="${2:?hook_event_name required}"
transcript="${3:-}"

mkdir -p "$cwd/.claude"

# Pointer to this session's JSONL — read at the next SessionStart to
# assemble the frame. Written unconditionally (even on a first, nothing-to-
# wipe activation). Skipped only if the payload carried no transcript path.
if [[ -n "$transcript" ]]; then
    printf '%s\n' "$transcript" > "$cwd/$HANDOFF_REL_SESSION"
fi
```

Leave the existing wipe loop (which removes `handoff-task.md`, `handoff.md`, `autorename`) and the dual-channel emit unchanged below this. Keeping `handoff.md` in the wipe loop doubles as legacy cleanup for users upgrading from ≤0.4.x.

- [ ] **Step 4: Pass `transcript_path` from both pre-hooks**

In `scripts/skill-pre-hook.sh`, the final line is currently:

```bash
exec bash "$(dirname "$0")/_wipe-emit.sh" "$cwd" "PreToolUse"
```

Change to extract and forward the transcript path (add the `transcript=` line after the `cwd=` line, then extend the `exec`):

```bash
transcript="$(jq -r '.transcript_path // ""' <<<"$input")"

exec bash "$(dirname "$0")/_wipe-emit.sh" "$cwd" "PreToolUse" "$transcript"
```

Apply the identical change to `scripts/prompt-pre-hook.sh`, with `"UserPromptSubmit"` as the event:

```bash
transcript="$(jq -r '.transcript_path // ""' <<<"$input")"

exec bash "$(dirname "$0")/_wipe-emit.sh" "$cwd" "UserPromptSubmit" "$transcript"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `just hook-test`
Expected: the `activation pointer (skill path)` assertion passes. (Other sections still reference `write-extract`; they are fixed in Task 5.)

- [ ] **Step 6: Commit**

```bash
git add scripts/_wipe-emit.sh scripts/skill-pre-hook.sh scripts/prompt-pre-hook.sh tests/hook-test.sh
git commit -m "feat: store session pointer at handoff activation"
```

---

## Task 4: Read-time assembly in `load-handoff.sh`

**Files:**
- Modify: `scripts/load-handoff.sh`
- Test: `tests/hook-test.sh`

- [ ] **Step 1: Add a failing assembly test to `tests/hook-test.sh`**

```bash
# SessionStart assembles the frame in memory from the pointer: task file +
# bounded scrape, injected via additionalContext. No handoff.md is read.
echo "=== load-handoff (read-time assembly) ==="
asm_tmp="$(mktemp -d)"; mkdir -p "$asm_tmp/.claude"
cp "$tmp/.claude/handoff-task.md" "$asm_tmp/.claude/handoff-task.md"
printf '%s\n' "$transcript" > "$asm_tmp/.claude/handoff-session"
out="$(jq -nc --arg e "clear" '{hook_event_name:$e}' \
    | CLAUDE_PROJECT_DIR="$asm_tmp" bash scripts/load-handoff.sh)"
ctx="$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext')"
echo "$ctx" | grep -q 'hook smoke test' || fail "load-handoff: task content not injected"
echo "$ctx" | grep -q 'fifth prompt' || fail "load-handoff: scraped prompt not injected"
echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "clear"' >/dev/null \
    || fail "load-handoff: hookEventName not echoed"
# No task file → silent no-op (empty output).
rm -f "$asm_tmp/.claude/handoff-task.md"
out="$(jq -nc --arg e "clear" '{hook_event_name:$e}' \
    | CLAUDE_PROJECT_DIR="$asm_tmp" bash scripts/load-handoff.sh)"
assert_eq "$out" "" "load-handoff: no task file → no-op"
rm -rf "$asm_tmp"
```

(`fifth prompt` is present in `extract-basic.jsonl`, which has no activation marker, so the bound is a no-op there and the tail prompts survive.)

- [ ] **Step 2: Run it to verify it fails**

Run: `just hook-test`
Expected: FAIL — current `load-handoff.sh` reads `handoff.md` (absent here), so output is empty and the task-content assertion fails.

- [ ] **Step 3: Rewrite `load-handoff.sh`**

Replace the body (keep the header comment intent, the `set -euo pipefail`, and the size/age helpers). New logic:

```bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

input="$(cat)"
cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
hook_event="$(jq -r '.hook_event_name // "SessionStart"' <<<"$input")"

task="$cwd/$HANDOFF_REL_TASK"
pointer="$cwd/$HANDOFF_REL_SESSION"
log="$cwd/$HANDOFF_REL_ERR"
script_dir="$(cd "$(dirname "$0")" && pwd)"

# Gate on the agent-authored task file. No task file → nothing to inject.
[[ -s "$task" ]] || exit 0

# Pointer → prior session JSONL. Missing/stale pointer degrades to task-only
# (extract.py treats an empty/absent transcript as "no session data").
jsonl=""
if [[ -s "$pointer" ]]; then
    jsonl="$(<"$pointer")"
    [[ -f "$jsonl" ]] || jsonl=""
fi

if ! assembled="$(python3 "$script_dir/extract.py" "$jsonl" "$task" 2>"$log")"; then
    tail=$(tail -c 400 "$log" 2>/dev/null | tr '\n' ' ')
    jq -nc --arg log "$log" --arg tail "$tail" \
        '{systemMessage: ("handoff load failed (see " + $log + "): " + $tail)}'
    exit 0
fi
rm -f "$log"
```

Then keep the existing size/age block, but compute `bytes` from the assembled text and `mtime` from the task file:

```bash
bytes=${#assembled}
if (( bytes < 1024 )); then
    size="${bytes} B"
else
    size=$(awk -v b="$bytes" 'BEGIN { printf "%.1f KiB", b/1024 }')
fi

mtime=$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$task")
now=$(date +%s)
delta=$(( now - mtime ))
if (( delta < 60 )); then age="just now"
elif (( delta < 3600 )); then age="$((delta / 60))m ago"
elif (( delta < 86400 )); then age="$((delta / 3600))h ago"
else age="$((delta / 86400))d ago"
fi

msg="handoff loaded — ${size}, saved ${age}"

jq -nc \
    --arg m "$msg" \
    --arg c "$assembled" \
    --arg e "$hook_event" \
    '{systemMessage: $m, hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
```

Note: `--arg c` (not `--rawfile`) since the content is now a shell variable. `bytes=${#assembled}` is byte-approximate (char count); acceptable for the 1–5 KiB "is this material?" signal per DESIGN.md.

- [ ] **Step 4: Run the test to verify it passes**

Run: `just hook-test`
Expected: the two `load-handoff` assertions pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/load-handoff.sh tests/hook-test.sh
git commit -m "feat: assemble handoff frame at read-time from session pointer"
```

---

## Task 5: Slim staging hook (replace `write-extract.sh`)

**Files:**
- Create: `scripts/write-stage.sh`
- Delete: `scripts/write-extract.sh`
- Modify: `hooks/hooks.json`, `tests/hook-test.sh`

- [ ] **Step 1: Update the hook-test write section to expect staging-only**

In `tests/hook-test.sh`, replace the `=== write-extract (matching path) ===` block (which asserts `handoff.md` is created) with a staging-only assertion, and keep the git-staging block but point it at `write-stage.sh` and drop the `handoff-task.md, handoff.md` pair down to `handoff-task.md`:

```bash
# write-stage stages handoff-task.md and does NOT create handoff.md.
echo "=== write-stage (git staging) ==="
git_tmp="$(mktemp -d)"
git -C "$git_tmp" init -q
mkdir -p "$git_tmp/.claude"
cp "$tmp/.claude/handoff-task.md" "$git_tmp/.claude/handoff-task.md"
out="$(jq -nc --arg t "$transcript" --arg fp "$git_tmp/.claude/handoff-task.md" \
        '{transcript_path:$t, tool_name:"Write", tool_input:{file_path:$fp}}' \
    | CLAUDE_PROJECT_DIR="$git_tmp" bash scripts/write-stage.sh)"
echo "$out" | jq -e '.systemMessage == "handoff — staged for commit"' >/dev/null \
    || fail "write-stage: expected staged message"
git -C "$git_tmp" status --porcelain | grep -q 'handoff-task.md' \
    || fail "write-stage: handoff-task.md not staged"
[[ ! -f "$git_tmp/.claude/handoff.md" ]] || fail "write-stage: must not create handoff.md"
rm -rf "$git_tmp"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `just hook-test`
Expected: FAIL — `scripts/write-stage.sh` does not exist.

- [ ] **Step 3: Create `scripts/write-stage.sh`**

```bash
#!/usr/bin/env bash
# PostToolUse hook for Write|Edit.
# When the agent writes this project's .claude/handoff-task.md, stage it
# with `git add -f` so the versioned task trail rides the user's next
# commit. No extraction, no generated file — the frame is assembled at
# read-time by load-handoff.sh.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // ""' <<<"$input")"
[[ -n "$file_path" ]] || exit 0
[[ "$(basename "$file_path")" == "handoff-task.md" ]] || exit 0

cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

{ read -r target; read -r expected; } < <(handoff_resolve "$file_path" "$cwd/$HANDOFF_REL_TASK")
[[ "$target" == "$expected" ]] || exit 0
[[ -f "$target" ]] || exit 0

if git -C "$cwd" add -f "$cwd/$HANDOFF_REL_TASK" 2>/dev/null; then
    jq -nc '{systemMessage: "handoff — staged for commit"}'
fi
```

- [ ] **Step 4: Delete the old script and repoint `hooks.json`**

```bash
git rm scripts/write-extract.sh
```

In `hooks/hooks.json`, the `PostToolUse` → `Write|Edit` block lists two command hooks. Change the first command from `${CLAUDE_PLUGIN_ROOT}/scripts/write-extract.sh` to `${CLAUDE_PLUGIN_ROOT}/scripts/write-stage.sh` (leave `write-rename.sh` untouched). Its `timeout` can drop from `30` to `5` (no Python extraction anymore).

- [ ] **Step 5: Run the test to verify it passes**

Run: `just hook-test`
Expected: the `write-stage` assertions pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/write-stage.sh hooks/hooks.json tests/hook-test.sh
git commit -m "refactor: replace write-extract with staging-only write-stage hook"
```

---

## Task 6: Drop `handoff.md` from the guards

**Files:**
- Modify: `scripts/read-guard.sh`, `scripts/write-guard.sh`
- Test: `tests/hook-test.sh`

- [ ] **Step 1: Update guard tests**

In `tests/hook-test.sh`, remove any assertion that a Read/Write of `handoff.md` is denied (the file no longer exists). Keep and verify the `handoff-task.md` gating assertions (denied before activation, cross-project denial). If a `handoff.md`-deny scenario block is present, delete it.

- [ ] **Step 2: Run it to verify the suite still drives the guards**

Run: `just hook-test`
Expected: at this point the suite passes against the *old* guards too (removing assertions never fails); this step just confirms no `handoff.md` assertions remain. Proceed to simplify the guards.

- [ ] **Step 3: Simplify `read-guard.sh`**

Replace the basename filter and resolution so only `handoff-task.md` is handled:

```bash
base="$(basename "$file_path")"
[[ "$base" == "handoff-task.md" ]] || exit 0

cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
transcript="$(jq -r '.transcript_path // ""' <<<"$input")"

{ read -r target; read -r exp_task; } \
    < <(handoff_resolve "$file_path" "$cwd/$HANDOFF_REL_TASK")

if [[ "$target" == "$exp_task" ]] && ! handoff_activated "$transcript"; then
    handoff_deny \
        "handoff-task.md read blocked: handoff skill has not activated this session." \
        "read-guard: blocked handoff-task.md read before handoff activation"
fi

exit 0
```

Delete the `exp_out` resolution line and the entire `if [[ "$target" == "$exp_out" ]]` block.

- [ ] **Step 4: Simplify `write-guard.sh`**

Same treatment: basename filter to `handoff-task.md` only, resolve just `exp_task`, delete the `exp_out` block. Keep the cross-project and activation gates intact:

```bash
base="$(basename "$file_path")"
[[ "$base" == "handoff-task.md" ]] || exit 0

cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
transcript="$(jq -r '.transcript_path // ""' <<<"$input")"

{ read -r target; read -r exp_task; } \
    < <(handoff_resolve "$file_path" "$cwd/$HANDOFF_REL_TASK")

if [[ "$target" != "$exp_task" ]]; then
    handoff_deny \
        "write blocked: handoff-task.md outside this project's .claude/. resolved: $target; expected: $exp_task." \
        "write-guard: blocked handoff-task.md write outside $cwd/.claude/"
fi
if ! handoff_activated "$transcript"; then
    handoff_deny \
        "handoff-task.md write blocked: handoff skill has not activated this session." \
        "write-guard: blocked handoff-task.md write before handoff activation"
fi

exit 0
```

- [ ] **Step 5: Run the full hook suite**

Run: `just hook-test`
Expected: PASS — all scenarios, no `handoff.md` references remain.

- [ ] **Step 6: Commit**

```bash
git add scripts/read-guard.sh scripts/write-guard.sh tests/hook-test.sh
git commit -m "refactor: drop hook-owned handoff.md branch from read/write guards"
```

---

## Task 7: Smoke test, version bump, docs

**Files:**
- Modify: `tests/smoke.sh`, `.claude-plugin/plugin.json`, `README.md`, `CLAUDE.md`

- [ ] **Step 1: Update `tests/smoke.sh` to the new invocation**

`smoke.sh` runs `extract.py` against the most recent real session JSONL. Update the call to the two-arg stdout form and assert non-empty output. Locate the `python3 scripts/extract.py` line and change it to:

```bash
python3 scripts/extract.py "$latest" "$repo_root/.claude/handoff-task.md" > "$tmp/handoff.md"
[[ -s "$tmp/handoff.md" ]] || { echo "smoke: empty output" >&2; exit 1; }
```

(Use whatever variable the script already binds for the latest transcript and its tmp dir; only the invocation contract changed.)

- [ ] **Step 2: Run the full test suite**

Run: `just precommit && just extract-test && just hook-test && just smoke`
Expected: all green.

- [ ] **Step 3: Bump the plugin version**

This is a breaking change (the `handoff.md` output path is gone, `extract.py`'s CLI contract changed). In `.claude-plugin/plugin.json`, change `"version": "0.4.1"` to `"version": "0.5.0"`.

Do **not** hand-edit beyond the manifest — the marketplace bump and tag are handled by `just release` (see DESIGN.md → *Release infrastructure*). Flag for the user that release is a separate, guarded step.

- [ ] **Step 4: Update `README.md`**

- Remove every mention of `handoff.md` as a generated/committable file and the "commit the files to git if you want an archived trail / self-contained" framing.
- In *Files touched on your system*: `handoff-task.md` is the agent-written, **git-tracked** task trail; add `handoff-session` as a machine-local pointer to the prior session JSONL (gitignore it) and keep `handoff-error.log` (gitignore it). Drop the `handoff.md` entry.
- State the recommended `.gitignore` for users: `.claude/handoff-session` and `.claude/handoff-error.log`; track `.claude/handoff-task.md`.
- Note the gitlore synergy in one line: the durable context that pairs with the task trail lives in versioned auto-memory (gitlore), not in the handoff file.

- [ ] **Step 5: Update `CLAUDE.md`**

Update the hooks description / architecture notes: `PostToolUse` now stages (`write-stage.sh`), not extracts; `extract.py` runs at `SessionStart` from `load-handoff.sh` and emits to stdout; the pointer (`handoff-session`) is written at activation; `handoff.md` no longer exists.

- [ ] **Step 6: Commit**

```bash
git add tests/smoke.sh .claude-plugin/plugin.json README.md CLAUDE.md
git commit -m "docs: read-time assembly — bump to 0.5.0, drop handoff.md, document pointer"
```

---

## Self-Review

**Spec coverage** (against DESIGN.md *Read-time assembly*):
- Pointer written at activation → Task 3. ✓
- Read-time assembly, gate on task file, JSONL-missing fallback → Task 4. ✓
- Bounded scrape at last activation marker → Task 2. ✓
- `handoff.md` eliminated (extract→stdout, guards, hooks.json, wipe-as-legacy-cleanup) → Tasks 2, 5, 6; legacy cleanup noted in Task 3 Step 3. ✓
- Version `handoff-task.md` (staging hook survives) → Task 5; gitignore split → Task 7. ✓
- gitlore context pairing documented → Task 7 Steps 4. ✓
- Consequences (non-atomic pairing, wipe-churn) → documented in DESIGN.md; no code action required. ✓

**Placeholder scan:** no TBD/"handle errors"/"similar to" — each code step carries real code. Test steps carry real fixtures and assertions. One soft spot: Task 7 Step 1 references "whatever variable the script already binds" for `smoke.sh` — the executor must open `tests/smoke.sh` (short) to match its tmp/latest bindings; flagged inline.

**Type/contract consistency:** `extract.py` two-arg contract `(transcript, task_path) → stdout` is used identically in Tasks 2 (test), 4 (`load-handoff.sh`), 7 (`smoke.sh`). Constant `HANDOFF_REL_SESSION` defined in Task 1, consumed in Tasks 3 (`_wipe-emit`), 4 (`load-handoff`). `_wipe-emit.sh` 3-arg signature defined in Task 3 Step 3, called from both pre-hooks in Task 3 Step 4. Marker signals (`Skill`/`handoff[:handoff]`, slash wrapper) match `handoff_activated()` in `_lib.sh`. Consistent.

**Caveat carried from DESIGN.md:** the `/handoff:handoff` slash marker's JSONL shape is the less-reliable signal; the `Skill` tool_use is dependable. The bounded-cut fixture (Task 2) uses the `Skill` marker. If real-world slash transcripts reveal a different wrapper, add a fixture mirroring `tests/fixtures/activated-slash.jsonl` and extend `_is_activation`.
