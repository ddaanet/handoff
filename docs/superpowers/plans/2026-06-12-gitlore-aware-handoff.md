# gitlore-aware handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/handoff:handoff` proactively detect a dirty gitlore-memory submodule at wrap-up and drive a summarize → approve → commit flow through gitlore's blessed `commit-memory.sh`.

**Architecture:** A read-only probe script (`scripts/memory-probe.sh`) owns the entire dirty-or-not branch and prints the agent's next action on stdout — the skill body carries no conditional. The probe is exposed to the agent's Bash by a PATH-resident shim (`bin/handoff-memory-probe`); Claude Code auto-adds every plugin's `bin/` to PATH (verified). The agent runs the absolute `commit-memory.sh` the probe inlines (resolved via `git config gitlore.commitCommand`). A separate one-line fix routes the non-tmux rename hint through agent-facing `additionalContext`.

**Tech Stack:** Bash, `git config`/`.gitmodules`, `jq`; tested with **bats**. No Python changes.

**Reference spec:** `docs/superpowers/specs/2026-06-12-gitlore-aware-handoff-design.md`.

**Task grouping rationale:** The probe, its PATH shim, and the justfile wiring are one coupled TDD unit (the shim execs the probe; the recipe lists the bats file; all three mutate `tests/memory-probe.bats`) — Task 1. The non-tmux `additionalContext` fix is fully independent (different files) — Task 2. The skill wiring and docs are no-test prose that depend on the code existing — Task 3. Final verification (`just precommit`/`just smoke`) is an orchestrator gate, run inline in the main session, not a dispatched task.

---

## File structure

- **Create** `scripts/memory-probe.sh` — read-only detector; prints a directive or stays silent.
- **Create** `bin/handoff-memory-probe` — thin PATH shim that execs the probe.
- **Create** `tests/memory-probe.bats` — probe + shim tests against a synthetic gitlore repo.
- **Modify** `scripts/write-rename.sh:32-36` — add `additionalContext` to the non-tmux branch.
- **Modify** `tests/hook-test.bats` — extend the non-tmux write-rename test to assert `additionalContext`.
- **Modify** `skills/handoff/SKILL.md` — add the probe to the Step 2 batch, add a follow-the-probe step, drop the dead rename-relay lines.
- **Modify** `justfile:24,53` — add `tests/memory-probe.bats` to the `precommit` and `hook-test` recipes (both list bats files explicitly).
- **Modify** `CLAUDE.md`, `README.md`, `DESIGN.md` — document the new files, flow, and decision.

---

## Task 1: Probe + PATH shim + recipe wiring

One coupled TDD unit. Build the probe (red→green), then its PATH shim (red→green) which execs the probe, then wire the shared bats file into the recipes. Each sub-step keeps its own red phase; they share `tests/memory-probe.bats` and so cannot be parallelized — hence one task.

**Files:**
- Create: `scripts/memory-probe.sh`
- Create: `bin/handoff-memory-probe`
- Create: `tests/memory-probe.bats`
- Modify: `justfile:24` (the `precommit` recipe) and `justfile:53` (the `hook-test` recipe)

### Probe script

- [ ] **Step 1: Write the failing tests**

Create `tests/memory-probe.bats`:

```bash
#!/usr/bin/env bats
# Tests for scripts/memory-probe.sh — the read-only gitlore-memory detector
# the handoff skill runs at wrap-up. Builds a synthetic gitlore repo (a repo
# with a gitlore-memory submodule registration in .gitmodules and a nested
# memory git repo) and asserts the probe's stdout contract:
#   not gitlore / clean / unmaterialized  -> silent (empty stdout)
#   dirty + resolvable committer          -> directive naming `<abs> -F -`
#   dirty + unresolvable committer        -> restart hint
#
# Run with: bats tests/memory-probe.bats   (from plugin root)

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PROBE="$repo_root/scripts/memory-probe.sh"
    SHIM="$repo_root/bin/handoff-memory-probe"
}

# Build a synthetic gitlore-managed repo and echo its path. The memory
# submodule is a nested git repo with one committed file (clean by default).
# Pass a commitCommand path as $1 (defaults to an executable stub in the repo).
make_gitlore_repo() {
    local repo="$BATS_TEST_TMPDIR/glrepo"
    rm -rf "$repo"; mkdir -p "$repo/memory"
    git -C "$repo" init -q
    cat > "$repo/.gitmodules" <<'EOF'
[submodule "gitlore-memory"]
	path = memory
	url = ./memory
EOF
    git -C "$repo/memory" init -q
    echo "seed" > "$repo/memory/seed.md"
    git -C "$repo/memory" add -A
    git -C "$repo/memory" -c user.email=t@t -c user.name=t commit -qm seed
    cat > "$repo/fake-commit-memory.sh" <<'EOF'
#!/usr/bin/env bash
echo "COMMIT-MEMORY $*"
EOF
    chmod +x "$repo/fake-commit-memory.sh"
    git -C "$repo" config gitlore.commitCommand "${1:-$repo/fake-commit-memory.sh}"
    printf '%s\n' "$repo"
}

@test "probe: not gitlore-managed -> silent" {
    plain="$BATS_TEST_TMPDIR/plain"; mkdir -p "$plain"
    git -C "$plain" init -q
    run bash -c 'cd "$1" && bash "$2"' _ "$plain" "$PROBE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: gitlore + clean memory -> silent" {
    repo="$(make_gitlore_repo)"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: submodule registered but not materialized -> silent" {
    repo="$(make_gitlore_repo)"
    rm -rf "$repo/memory/.git"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "probe: dirty memory -> directive naming the abs commit command" {
    repo="$(make_gitlore_repo)"
    echo "new entry" > "$repo/memory/feedback_x.md"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'uncommitted changes'
    echo "$output" | grep -q 'feedback_x.md'
    echo "$output" | grep -qF "$repo/fake-commit-memory.sh -F -"
    echo "$output" | grep -qi 'approval'
}

@test "probe: dirty memory + unresolvable committer -> restart hint" {
    repo="$(make_gitlore_repo "/nonexistent/commit-memory.sh")"
    echo "new entry" > "$repo/memory/feedback_x.md"
    run bash -c 'cd "$1" && bash "$2"' _ "$repo" "$PROBE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi 'restart'
    echo "$output" | grep -q 'gitlore.commitCommand'
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/memory-probe.bats`
Expected: FAIL — `scripts/memory-probe.sh` does not exist (every case errors).

- [ ] **Step 3: Write the probe**

Create `scripts/memory-probe.sh`:

```bash
#!/usr/bin/env bash
# Read-only gitlore-memory detector for the handoff skill. Invoked by the
# agent through bin/handoff-memory-probe (on PATH) during the handoff
# snapshot. Owns the entire dirty-or-not branch so the skill body carries no
# conditional: prints the agent's next action on stdout, or stays silent when
# there is nothing to commit.
#
# Couples only to two public gitlore contracts: the gitlore-memory submodule
# registration in .gitmodules (FR12 activation gate) and the
# `git config gitlore.commitCommand` discovery key. No reach into gitlore
# internals; the commit machinery stays in gitlore's commit-memory.sh.
set -euo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# FR12 activation gate: the gitlore-memory submodule registration.
mempath=$(git config --file "$root/.gitmodules" \
    submodule.gitlore-memory.path 2>/dev/null) || exit 0
[ -n "$mempath" ] || exit 0

mem="$root/$mempath"
# Submodule worktree not materialized (session-less checkout): nothing to do.
[ -e "$mem/.git" ] || exit 0

# Clean memory: nothing to commit.
[ -n "$(git -C "$mem" status --porcelain 2>/dev/null)" ] || exit 0

# Dirty. Resolve gitlore's blessed committer (absolute path, self-healing key).
script=$(git config gitlore.commitCommand 2>/dev/null || true)
if [ -z "$script" ] || [ ! -x "$script" ]; then
    printf '%s\n' \
"gitlore memory has uncommitted changes, but its commit command is not resolvable (gitlore.commitCommand = '${script:-unset}'). Tell the user to restart the session so gitlore re-pins it, then memory can be committed."
    exit 0
fi

status=$(git -C "$mem" status --porcelain)
printf '%s\n' \
"gitlore memory has uncommitted changes:" \
"" \
"$status" \
"" \
"Summarize these changes in 1-3 sentences. Present the summary to the user for approval (they may edit it). Once approved, commit the memory by piping the approved summary on stdin:" \
"" \
"    $script -F -"
```

- [ ] **Step 4: Make it executable and run the tests to verify they pass**

Run: `chmod +x scripts/memory-probe.sh && bats tests/memory-probe.bats`
Expected: PASS (5 tests).

- [ ] **Step 5: Lint**

Run: `shellcheck -x scripts/memory-probe.sh tests/memory-probe.bats`
Expected: no findings.

### PATH shim

- [ ] **Step 6: Write the failing test**

Append to `tests/memory-probe.bats` (the `make_gitlore_repo` helper and `SHIM` are already defined in setup):

```bash
@test "shim: bin/handoff-memory-probe execs the probe (dirty -> directive)" {
    repo="$(make_gitlore_repo)"
    echo "new entry" > "$repo/memory/feedback_x.md"
    run bash -c 'cd "$1" && "$2"' _ "$repo" "$SHIM"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "$repo/fake-commit-memory.sh -F -"
}
```

- [ ] **Step 7: Run to verify it fails**

Run: `bats tests/memory-probe.bats -f shim`
Expected: FAIL — `bin/handoff-memory-probe` does not exist / not executable.

- [ ] **Step 8: Write the shim**

Create `bin/handoff-memory-probe`:

```bash
#!/usr/bin/env bash
# PATH-resident entry point for the handoff skill's memory probe. Claude Code
# adds every installed plugin's bin/ to PATH, so the skill body can invoke
# this by bare name. Self-locates and execs the real logic in scripts/.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
exec bash "$here/../scripts/memory-probe.sh" "$@"
```

- [ ] **Step 9: Make it executable and run the test to verify it passes**

Run: `chmod +x bin/handoff-memory-probe && bats tests/memory-probe.bats -f shim`
Expected: PASS.

- [ ] **Step 10: Lint**

Run: `shellcheck -x bin/handoff-memory-probe`
Expected: no findings.

### Wire the bats file into the recipes

Both recipes list bats files explicitly, so a new file is invisible until added.

- [ ] **Step 11: Edit `precommit`**

Change line 24 from:

```
    bats tests/hook-test.bats tests/rename-test.bats
```

to:

```
    bats tests/hook-test.bats tests/rename-test.bats tests/memory-probe.bats
```

- [ ] **Step 12: Edit `hook-test`**

Change the `hook-test` recipe body from:

```
    bats tests/hook-test.bats tests/rename-test.bats
```

to:

```
    bats tests/hook-test.bats tests/rename-test.bats tests/memory-probe.bats
```

- [ ] **Step 13: Verify the recipe runs the new file**

Run: `just hook-test`
Expected: PASS — all three suites run, including the 6 memory-probe tests.

- [ ] **Step 14: Commit**

```bash
git add scripts/memory-probe.sh bin/handoff-memory-probe tests/memory-probe.bats justfile
git commit -m "feat: add gitlore-memory probe, PATH shim, and recipe wiring"
```

---

## Task 2: Non-tmux rename → agent-facing additionalContext

Fully independent of Task 1 (different files; no shared state). The non-tmux branch currently emits only `systemMessage` (user-facing). The skill body's dead "relay the systemMessage" line never fires because the agent doesn't see `systemMessage`. Route the instruction through `additionalContext` so the agent fences the `/rename` line itself.

**Files:**
- Modify: `scripts/write-rename.sh:32-36`
- Test: `tests/hook-test.bats` (extend the existing non-tmux case)

- [ ] **Step 1: Write the failing test**

In `tests/hook-test.bats`, replace the existing test at lines 460-470 (`write-rename (matching path, not in tmux)...`) with:

```bash
@test "write-rename (not in tmux): systemMessage + agent-facing additionalContext carry /rename line" {
    echo "the title" > "$tmp/.claude/autorename"
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/.claude/autorename" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | env -u TMUX -u TMUX_PANE bash scripts/write-rename.sh
    ' _ "$tmp"
    [ "$status" -eq 0 ]
    [ ! -e "$tmp/.claude/autorename" ]
    echo "$output" | jq -e '.systemMessage | test("/rename the title")' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("/rename the title")' >/dev/null
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/hook-test.bats -f "not in tmux"`
Expected: FAIL — `.hookSpecificOutput.additionalContext` is null (script emits only `systemMessage`).

- [ ] **Step 3: Edit the non-tmux branch**

In `scripts/write-rename.sh`, replace lines 32-36:

```bash
if [[ -z "${TMUX:-}" || -z "${TMUX_PANE:-}" ]]; then
    jq -nc --arg t "$title" \
        '{systemMessage: ("handoff: not in tmux — paste to rename: /rename " + $t)}'
    exit 0
fi
```

with:

```bash
if [[ -z "${TMUX:-}" || -z "${TMUX_PANE:-}" ]]; then
    jq -nc --arg t "$title" '{
        systemMessage: ("handoff: not in tmux — paste to rename: /rename " + $t),
        hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: ("Session auto-rename is unavailable (not in tmux). Present this line to the user in a fenced code block so they can paste it:\n/rename " + $t)
        }
    }'
    exit 0
fi
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/hook-test.bats -f "not in tmux"`
Expected: PASS.

- [ ] **Step 5: Lint**

Run: `shellcheck -x scripts/write-rename.sh tests/hook-test.bats`
Expected: no findings.

- [ ] **Step 6: Commit**

```bash
git add scripts/write-rename.sh tests/hook-test.bats
git commit -m "fix: route non-tmux rename hint through agent-facing additionalContext"
```

---

## Task 3: SKILL.md wiring + documentation

Both halves are no-test prose edits that depend on the code from Tasks 1–2 existing. The skill edits make the feature actually fire; the docs describe it. Grouped because neither carries an independent test gate.

**Files:**
- Modify: `skills/handoff/SKILL.md`
- Modify: `CLAUDE.md`, `README.md`, `DESIGN.md`

### SKILL.md

- [ ] **Step 1: Add the probe to the Step 2 batch**

In `skills/handoff/SKILL.md`, replace the block (lines 30-35):

```markdown
Then issue the Write calls in the **same turn**:
- `./.claude/autorename` — sole line is the session title (always)
- `./.claude/handoff-task.md` — only if there's an active task

If there's no active task, omit `handoff-task.md` — the activation hook
already finalized the session.
```

with:

```markdown
Then, in the **same turn**, issue the writes and run the memory probe:
- Write `./.claude/autorename` — sole line is the session title (always)
- Write `./.claude/handoff-task.md` — only if there's an active task
- Run `handoff-memory-probe` (Bash) — deterministic gitlore-memory check

If there's no active task, omit `handoff-task.md` — the activation hook
already finalized the session.

### Step 3: Follow the probe

`handoff-memory-probe` prints nothing when there is no gitlore-managed
memory to commit — finish normally. If it prints a directive, follow it:
summarize the pending memory changes in 1-3 sentences, get the user's
approval (they may edit the summary), then run the commit command the
directive names. The probe owns the decision — do not re-derive it or
inspect the submodule yourself.
```

- [ ] **Step 2: Remove the dead rename-relay lines**

Delete lines 63-64 (now handled by `write-rename.sh`'s `additionalContext`):

```markdown
If the autorename systemMessage contains a `/rename ...` line (not in
tmux), relay it in a fenced code block so the user can paste it.
```

- [ ] **Step 3: Verify the skill body stays within budget**

Run: `wc -w skills/handoff/SKILL.md`
Expected: under 2000 words (the conventions cap). Confirm the number is well below.

### Documentation

- [ ] **Step 4: Update `CLAUDE.md`**

In the high-level flow paragraph (top of "Layout"), append a sentence after the existing flow description:

```
At wrap-up the skill also runs `handoff-memory-probe`; when a gitlore-memory
submodule is dirty, the probe emits a directive and the agent summarizes →
gets approval → commits memory via gitlore's `commit-memory.sh`.
```

Add two bullets to the Layout list (after the `scripts/worktree_root.py` bullet):

```
- `bin/handoff-memory-probe` — PATH-resident shim (Claude Code adds each
  plugin's `bin/` to PATH) that execs `scripts/memory-probe.sh`. The skill
  body invokes it by bare name; `${CLAUDE_PLUGIN_ROOT}` is not available in
  the agent's Bash, so the shim is the entry point.
- `scripts/memory-probe.sh` — read-only gitlore-memory detector run by the
  handoff skill at wrap-up. Owns the dirty-or-not branch and prints the
  agent's next action (summarize → approve → commit via
  `git config gitlore.commitCommand`) or stays silent. Couples only to the
  `gitlore-memory` submodule registration (FR12) and the `commitCommand`
  key — never gitlore internals.
```

Add to "Testing" (after the `just hook-test` bullet description), noting the new file is wired into both `precommit` and `hook-test`:

```
`tests/memory-probe.bats` covers `scripts/memory-probe.sh` and the
`bin/` shim against a synthetic gitlore repo; it is listed in both the
`precommit` and `hook-test` recipes.
```

- [ ] **Step 5: Update `README.md`**

Add a short user-facing paragraph to the section describing what handoff does at wrap-up:

```
In a gitlore-managed repository, handoff also offers to commit your memory:
when the memory submodule has uncommitted changes, it summarizes them, asks
you to approve (or edit) the summary, and commits via gitlore — so durable
learnings land instead of waiting for your next commit.
```

- [ ] **Step 6: Append a decision entry to `DESIGN.md`**

Add a dated entry capturing: the four-part split (detect/summarize/approve/commit); why detection is a PATH-shimmed script and not a hook (the agent must act on the result, and `CLAUDE_PLUGIN_ROOT` is unavailable in agent Bash while plugin `bin/` is on PATH — both verified by test); and why gitlore's `commit-memory.sh` stays in `scripts/` discovered via `gitlore.commitCommand` (self-healing, no layout coupling) rather than moving to `bin/`.

```
| 2026-06-12 | **gitlore-aware handoff.** handoff runs a read-only probe
(`bin/handoff-memory-probe` → `scripts/memory-probe.sh`) at wrap-up; on a
dirty gitlore-memory submodule it emits a directive and the agent
summarizes → gets approval → commits via gitlore's `commit-memory.sh`
(resolved through `git config gitlore.commitCommand`). The probe is a
PATH-shimmed script, not a hook: the agent must act on the result, and
verification showed `CLAUDE_PLUGIN_ROOT` is absent from the agent's Bash
while every plugin's `bin/` is on PATH. The conditional lives entirely in
the probe (harness-over-agent); the skill body just runs it and follows
its output. gitlore's committer stays in its `scripts/` behind the
self-healing `commitCommand` key — moving it to `bin/` would reopen a
shipped feature and break the no-layout-coupling abstraction. |
```

- [ ] **Step 7: Commit**

```bash
git add skills/handoff/SKILL.md CLAUDE.md README.md DESIGN.md
git commit -m "feat: drive proactive gitlore memory commit from handoff skill + docs"
```

---

## Final verification (inline — main session, not a dispatched task)

Run after Task 3 lands. This is an orchestrator gate, not subagent work.

- [ ] **Step 1: Run the full precommit suite**

Run: `just precommit`
Expected: PASS — manifest/settings lint, shellcheck (incl. the new scripts and bats file), ruff/mypy/ty (unchanged Python), `bats tests/hook-test.bats tests/rename-test.bats tests/memory-probe.bats`, and `pytest` all green, ending in `ok`.

- [ ] **Step 2: Smoke-test extraction is unaffected**

Run: `just smoke`
Expected: `extract.py` runs against the most recent session JSONL and prints a frame (this change does not touch extraction; confirm no regression).

- [ ] **Step 3: Final commit (if any docs/lint touch-ups remain)**

```bash
git status
# commit any remaining changes with an appropriate message
```

---

## Self-review

**Spec coverage:**
- Probe (`scripts/memory-probe.sh`), all branches — Task 1.
- `bin/handoff-memory-probe` PATH shim — Task 1.
- Three-line batch + follow-the-probe in SKILL.md — Task 3.
- Absolute `commit-memory.sh -F -` invocation (inlined by probe) — Task 1 (directive) + Task 3 (agent acts).
- Prose, editable approval — Task 3 (skill instruction: "they may edit the summary").
- Non-tmux rename `additionalContext` fix + drop dead lines — Task 2 + Task 3.
- Tests (probe cases + rename additionalContext) — Task 1, 2; wired into recipes in Task 1.
- Docs/decision record — Task 3. Release (minor bump) — out of plan scope; run `just release` after merge.

**Non-goals honored:** no gitlore changes; no commit without approval; `handoff-task.md`/`autorename` staging untouched (Task 2 only adds a field to the non-tmux branch).

**Type/name consistency:** `handoff-memory-probe` (bin), `scripts/memory-probe.sh`, `tests/memory-probe.bats`, `make_gitlore_repo`, `gitlore.commitCommand`, `submodule.gitlore-memory.path` — used identically across all tasks.

**No placeholders:** every code and test block is concrete; every run step names the command and expected result.

**Granularity:** 3 dispatched tasks (coupled probe unit / independent rename fix / prose) + an inline verification gate, down from an over-sharded 7. Task 1's sub-steps share `tests/memory-probe.bats` and run sequentially; Task 2 is file-disjoint from Task 1 and could run in parallel under dispatching-parallel-agents.
