# Pre-activation File Guards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the two handoff files inert outside their owner's control path — `handoff.md` is never agent-read/written, `handoff-task.md` is read/write-refused until the `handoff:handoff` skill has activated this session.

**Architecture:** Two PreToolUse guard scripts (`write-guard.sh`, extended; `read-guard.sh`, new) consult a stateless `handoff_activated()` helper that scrapes the session transcript JSONL for the same activation signals the wipe hooks key on. No stored state, no new artifact. Deny emission is factored into a shared `handoff_deny()` helper.

**Tech Stack:** Bash hook scripts, `jq` for envelope parsing, inline `python3` for JSONL scanning (matching `extract.py` / `handoff_resolve`), the existing `tests/hook-test.sh` assertion harness with JSONL fixtures under `tests/fixtures/`.

---

## Background facts (verified against real transcripts 2026-05-23)

Activation signals as they actually appear in the session JSONL:

- **Agent path** — an assistant entry with a content block
  `{"type":"tool_use","name":"Skill","input":{"skill":"handoff:handoff"}}`.
- **Slash path** — a `type:"user"` entry whose `message.content` is a
  **string** containing the literal substring
  `<command-name>/handoff:handoff</command-name>` (leading slash; the
  `/handoff:handoff` slash command loads the skill body directly without
  a `Skill` tool_use, so this is the only signal on that path).

PreToolUse hook input carries `cwd`, `transcript_path`, `tool_name`, and
`tool_input.file_path` (for Read/Write/Edit). The `Read` matcher cannot
filter by path in `hooks.json`, so `read-guard.sh` does a cheap basename
check and exits 0 (allow) for everything that is not a guarded file.

## File structure

- `scripts/_lib.sh` — **modify**: add `handoff_activated()` (transcript
  scraper) and `handoff_deny()` (shared deny emitter). Reuses existing
  `HANDOFF_REL_TASK` / `HANDOFF_REL_OUT` constants.
- `scripts/write-guard.sh` — **modify**: add the `handoff.md` always-deny
  rule and the `handoff-task.md` activation gate; refactor the existing
  cross-project deny onto `handoff_deny()`.
- `scripts/read-guard.sh` — **create**: PreToolUse(Read) gate.
- `hooks/hooks.json` — **modify**: add a `PreToolUse` matcher `"Read"`.
- `tests/fixtures/activated-skill.jsonl` — **create**: minimal transcript
  with a `Skill` activation.
- `tests/fixtures/activated-slash.jsonl` — **create**: minimal transcript
  with a slash-command activation.
- `tests/hook-test.sh` — **modify**: unit-test the detector; update the
  now-obsolete "canonical path = allow" write-guard scenario; add the new
  write-guard and read-guard scenarios.
- `CLAUDE.md` — **modify**: document `read-guard.sh`, the extended
  `write-guard.sh`, and the two new `_lib.sh` helpers.
- `README.md` — **modify**: one line noting the files are owner-scoped.

`DESIGN.md` already carries the design section (committed in `ad99998`);
no further DESIGN.md change is required by this plan.

---

## Task 1: Detector + deny helpers in `_lib.sh`, with fixtures

**Files:**
- Create: `tests/fixtures/activated-skill.jsonl`
- Create: `tests/fixtures/activated-slash.jsonl`
- Modify: `scripts/_lib.sh`
- Modify: `tests/hook-test.sh` (new unit-test block)

- [ ] **Step 1: Create the two activation fixtures**

These mirror the verified real JSONL shapes. `tests/fixtures/activated-skill.jsonl`:

```json
{"type":"user","isSidechain":false,"message":{"role":"user","content":"please save a handoff"}}
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"handoff:handoff"}}]}}
```

`tests/fixtures/activated-slash.jsonl`:

```json
{"type":"user","isSidechain":false,"message":{"role":"user","content":"<command-name>/handoff:handoff</command-name>\n<command-message>handoff:handoff</command-message>\n<command-args></command-args>"}}
```

The not-activated transcript is the existing `tests/fixtures/extract-basic.jsonl` (it contains a `Write` tool_use and plain prompts, but no `Skill` block and no `<command-name>/handoff:handoff</command-name>` — reused as-is, no new file).

- [ ] **Step 2: Write the failing unit test for `handoff_activated`**

Add this block to `tests/hook-test.sh` immediately after the `assert_eq` definition (around line 43), before the first `write-extract` scenario. It sources `_lib.sh` and exercises the detector directly:

```bash
# --- _lib.sh: handoff_activated detector ---
echo "=== handoff_activated (detector) ==="
# shellcheck source=../scripts/_lib.sh
source "$repo_root/scripts/_lib.sh"

set +e
handoff_activated "$repo_root/tests/fixtures/activated-skill.jsonl"; rc=$?
set -e
assert_eq "$rc" "0" "handoff_activated: Skill tool_use → activated"

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
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `just hook-test`
Expected: FAIL — `handoff_activated: command not found` (or the assertions report unexpected rc), because the function does not exist yet.

- [ ] **Step 4: Implement `handoff_activated()` and `handoff_deny()` in `_lib.sh`**

Append both functions to `scripts/_lib.sh` (after `handoff_resolve`):

```bash
# Has the handoff:handoff skill activated in this session? Stateless:
# derive the answer from the transcript JSONL each call (no marker, no
# env). Scans for either activation signal the wipe hooks key on — a
# Skill tool_use (agent path) or the /handoff:handoff slash command
# (user path, stored as a <command-name> wrapper). Verified against real
# transcripts 2026-05-23. Exit 0 if activated, 1 otherwise (incl.
# empty/missing transcript).
handoff_activated() {
    local transcript="$1"
    [[ -n "$transcript" && -f "$transcript" ]] || return 1
    python3 - "$transcript" <<'PY'
import json, sys

SLASH = "<command-name>/handoff:handoff</command-name>"
try:
    fh = open(sys.argv[1], encoding="utf-8", errors="replace")
except OSError:
    sys.exit(1)
with fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("isSidechain"):
            continue
        msg = entry.get("message") or {}
        # Agent path: Skill tool_use with skill == handoff:handoff.
        if msg.get("role") == "assistant":
            for block in msg.get("content") or []:
                if (isinstance(block, dict)
                        and block.get("type") == "tool_use"
                        and block.get("name") == "Skill"
                        and (block.get("input") or {}).get("skill") == "handoff:handoff"):
                    sys.exit(0)
        # User path: slash command stored as a <command-name> wrapper.
        if entry.get("type") == "user":
            content = msg.get("content")
            if isinstance(content, str) and SLASH in content:
                sys.exit(0)
sys.exit(1)
PY
}

# Emit a PreToolUse deny on stdout and exit 0 — the modern
# permissionDecision channel, identical envelope to the wipe scripts.
# $1 = agent-facing reason (factual, no actionable phrasing); $2 =
# user-facing systemMessage.
handoff_deny() {
    jq -nc --arg r "$1" --arg s "$2" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}, systemMessage: $s}'
    exit 0
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `just hook-test`
Expected: the `=== handoff_activated (detector) ===` scenario passes; the run continues to other scenarios (some later write-guard scenarios may still fail — they are updated in Task 2). The five `handoff_activated:` assertions must all pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/_lib.sh tests/fixtures/activated-skill.jsonl tests/fixtures/activated-slash.jsonl tests/hook-test.sh
git commit -m "feat: add handoff_activated detector and handoff_deny helper to _lib.sh"
```

---

## Task 2: Extend `write-guard.sh` (handoff.md deny + activation gate)

**Files:**
- Modify: `scripts/write-guard.sh`
- Modify: `tests/hook-test.sh` (update one scenario, add three)

- [ ] **Step 1: Update the obsolete test and add failing new scenarios**

The existing "write-guard (matching path: allow)" scenario (around lines 67-75) encodes the OLD behavior — canonical path always allowed. Under the new design that path is denied without activation. **Replace** that scenario with the following, and add the three new scenarios after it. (Locate the block beginning `echo "=== write-guard (matching path: allow) ==="`.)

```bash
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
```

The existing "cross-project: deny" and "unrelated filename: allow" scenarios remain unchanged and must keep passing.

- [ ] **Step 2: Run to verify the new scenarios fail**

Run: `just hook-test`
Expected: FAIL — the not-activated case currently ALLOWS (old guard), the handoff.md case currently ALLOWS (basename not `handoff-task.md`), so the new deny assertions fail.

- [ ] **Step 3: Rewrite `write-guard.sh`**

Replace the whole file with:

```bash
#!/usr/bin/env bash
# PreToolUse hook for Write|Edit.
# - handoff.md is hook-owned output: agent writes are refused.
# - handoff-task.md is skill-owned input: writes are refused until the
#   handoff:handoff skill has activated this session, and refused if the
#   resolved path is not $cwd/.claude/handoff-task.md (cross-project).
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // ""' <<<"$input")"
[[ -n "$file_path" ]] || exit 0

base="$(basename "$file_path")"
[[ "$base" == "handoff.md" || "$base" == "handoff-task.md" ]] || exit 0

cwd="$(jq -r '.cwd // ""' <<<"$input")"
[[ -n "$cwd" ]] || cwd="$PWD"
transcript="$(jq -r '.transcript_path // ""' <<<"$input")"

{ read -r target; read -r exp_task; read -r exp_out; } \
    < <(handoff_resolve "$file_path" "$cwd/$HANDOFF_REL_TASK" "$cwd/$HANDOFF_REL_OUT")

# handoff.md: hook-owned output, never agent-written.
if [[ "$target" == "$exp_out" ]]; then
    handoff_deny \
        "handoff.md is generated and read by the handoff hooks; agent writes are refused." \
        "write-guard: blocked agent write to hook-owned handoff.md"
fi

# handoff-task.md: must resolve into this project, and only after the
# skill has activated this session.
if [[ "$base" == "handoff-task.md" ]]; then
    if [[ "$target" != "$exp_task" ]]; then
        handoff_deny \
            "write blocked: handoff-task.md outside this project's .claude/. resolved: $target; expected: $exp_task." \
            "write-guard: blocked handoff-task.md write outside $cwd/.claude/"
    fi
    if ! handoff_activated "$transcript"; then
        handoff_deny \
            "handoff-task.md is inert until the handoff skill activates this session." \
            "write-guard: blocked handoff-task.md write before handoff activation"
    fi
fi

exit 0
```

- [ ] **Step 4: Run to verify all write-guard scenarios pass**

Run: `just hook-test`
Expected: PASS for every `write-guard` scenario (not-activated deny, activated allow, handoff.md deny, cross-project deny, unrelated-filename allow) and the Task 1 detector scenario.

- [ ] **Step 5: Commit**

```bash
git add scripts/write-guard.sh tests/hook-test.sh
git commit -m "feat: gate handoff-task.md writes on activation, deny handoff.md writes"
```

---

## Task 3: New `read-guard.sh` + wire PreToolUse(Read)

**Files:**
- Create: `scripts/read-guard.sh`
- Modify: `hooks/hooks.json`
- Modify: `tests/hook-test.sh` (add four scenarios)

- [ ] **Step 1: Write the failing read-guard scenarios**

Add to `tests/hook-test.sh` after the write-guard scenarios:

```bash
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
```

- [ ] **Step 2: Run to verify failure**

Run: `just hook-test`
Expected: FAIL — `scripts/read-guard.sh: No such file or directory`.

- [ ] **Step 3: Create `scripts/read-guard.sh`**

```bash
#!/usr/bin/env bash
# PreToolUse hook for Read.
# - handoff.md is hook-owned: reads are refused always.
# - handoff-task.md: reads are refused until the handoff:handoff skill
#   has activated this session.
# Anything else passes through (the Read matcher cannot filter by path).
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=_lib.sh
source "$(dirname "$0")/_lib.sh"

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // ""' <<<"$input")"
[[ -n "$file_path" ]] || exit 0

base="$(basename "$file_path")"
[[ "$base" == "handoff.md" || "$base" == "handoff-task.md" ]] || exit 0

cwd="$(jq -r '.cwd // ""' <<<"$input")"
[[ -n "$cwd" ]] || cwd="$PWD"
transcript="$(jq -r '.transcript_path // ""' <<<"$input")"

{ read -r target; read -r exp_task; read -r exp_out; } \
    < <(handoff_resolve "$file_path" "$cwd/$HANDOFF_REL_TASK" "$cwd/$HANDOFF_REL_OUT")

if [[ "$target" == "$exp_out" ]]; then
    handoff_deny \
        "handoff.md is generated and read by the handoff hooks; agent reads are refused." \
        "read-guard: blocked agent read of hook-owned handoff.md"
fi

if [[ "$target" == "$exp_task" ]] && ! handoff_activated "$transcript"; then
    handoff_deny \
        "handoff-task.md is inert until the handoff skill activates this session." \
        "read-guard: blocked handoff-task.md read before handoff activation"
fi

exit 0
```

- [ ] **Step 4: Wire the hook in `hooks/hooks.json`**

Add a third entry to the `PreToolUse` array (after the `Write|Edit` matcher object, before the closing `]`):

```json
      {
        "matcher": "Read",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/read-guard.sh",
            "timeout": 5
          }
        ]
      }
```

Update the top-level `"description"` string to mention the read guard, e.g. append `, and read guard` after `write guard`.

- [ ] **Step 5: Run the full suite**

Run: `just hook-test`
Expected: PASS — all read-guard scenarios plus everything from Tasks 1-2.

- [ ] **Step 6: Validate manifest + scripts**

Run: `just precommit`
Expected: PASS — manifest/settings lint, `shellcheck -x` on all scripts (including the new `read-guard.sh` and the heredoc in `_lib.sh`), and the full hook test suite. Fix any shellcheck findings inline (e.g. quoting) and re-run.

- [ ] **Step 7: Commit**

```bash
git add scripts/read-guard.sh hooks/hooks.json tests/hook-test.sh
git commit -m "feat: add read-guard for handoff files, wire PreToolUse(Read)"
```

---

## Task 4: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Update `CLAUDE.md` layout/conventions**

In the hooks bullet list, change the `hooks.json` description from "declares five hooks" to "declares six hooks" and add a sentence: `PreToolUse(Read): deny reads of handoff.md (always) and handoff-task.md (until handoff:handoff activates this session).` Extend the existing `PreToolUse(Write|Edit)` sentence to note it now also denies `handoff.md` writes and gates `handoff-task.md` writes on activation.

Add a `scripts/read-guard.sh` bullet mirroring the `write-guard.sh` bullet:

```markdown
- `scripts/read-guard.sh` — PreToolUse(Read) guard. Denies reads of
  `handoff.md` (hook-owned) always, and reads of `handoff-task.md`
  until `handoff:handoff` has activated this session.
```

Extend the `scripts/_lib.sh` bullet to mention the two new helpers:
`handoff_activated()` (transcript scraper — stateless activation check)
and `handoff_deny()` (shared PreToolUse deny emitter).

Extend the `scripts/write-guard.sh` bullet to note it now also denies
`handoff.md` writes and refuses `handoff-task.md` writes before activation.

- [ ] **Step 2: Update `README.md`**

Add one user-facing line (in the section describing the files or hooks) noting that `.claude/handoff.md` and `.claude/handoff-task.md` are managed by the handoff skill and hooks, and the agent is prevented from reading or writing them outside that flow.

- [ ] **Step 3: Verify docs build/lint**

Run: `just precommit`
Expected: PASS (docs are not linted by the recipe, but this confirms nothing regressed).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: document read-guard, activation-gated write-guard, _lib helpers"
```

---

## Release note (out of plan scope)

This is a behavior change (new PreToolUse(Read) hook + activation-gated
writes); the output paths are unchanged, so it is not breaking. The
version bump and marketplace push are owned by `just release` (the
`version-guard.sh` hook refuses manual `plugin.json` version edits), so
do **not** bump the version in any task above. Ship via `just release`
when ready.

---

## Self-Review

**Spec coverage:**
- handoff.md read/write denied always → Task 2 (write), Task 3 (read). ✓
- handoff-task.md gated on activation (read + write) → Task 2 (write), Task 3 (read). ✓
- cross-project handoff-task.md guard retained → Task 2 `write-guard.sh` keeps the `target != exp_task` deny. ✓
- transcript-scraping detector reusing wipe-hook signals → Task 1 `handoff_activated()`. ✓
- slash-command shape verified against real JSONL → Background facts + fixture in Task 1. ✓
- Read-tool-only scope (Bash cat bypass accepted) → only `PreToolUse(Read)` wired; documented in Task 3 / CLAUDE.md. ✓
- env-var/marker alternatives rejected → recorded in DESIGN.md (already committed); not re-litigated here. ✓
- tests mirror real JSONL → fixtures derived from verified shapes. ✓

**Placeholder scan:** No TBD/TODO; every code and test step contains complete content and exact run commands with expected output. ✓

**Type/name consistency:** `handoff_activated` and `handoff_deny` are defined in Task 1 and called with the same signatures in Tasks 2-3. `HANDOFF_REL_TASK` / `HANDOFF_REL_OUT` are the existing `_lib.sh` constants. `handoff_resolve` is called with three args (target, exp_task, exp_out) consistently in both guards, matching the three-line read. ✓
