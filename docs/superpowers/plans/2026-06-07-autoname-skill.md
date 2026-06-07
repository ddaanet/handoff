# autoname skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a standalone `/handoff:autoname` skill that names the current Claude Code session (and only that), and remove the now-vestigial `set-title.sh`.

**Architecture:** autoname is handoff's rename-half, extracted. The skill body decides a title from the conversation (no tool calls) and writes it as the sole line of `.claude/autorename`. The existing `write-rename.sh` `PostToolUse(Write|Edit)` hook — which keys on the resolved path, not on handoff activation — drives the actual `/rename`. No new scripts, no new hooks, no new tests. Separately, `set-title.sh` (wired nowhere, superseded by the file+hook path) and its references are deleted.

**Tech Stack:** Markdown skill (`SKILL.md`), bash test suite (`tests/rename-test.sh`), `just precommit` as the verification gate. The rename mechanics (`write-rename.sh`, `rename-when-idle.sh`, `_rename-lib.sh`) are untouched.

**Note on TDD:** Tasks 1 and 3 are pure prose (a skill body and docs) with no script of their own — there is nothing mechanical to unit-test, so `just precommit` staying green is the verification gate. Task 2 is a deletion whose gate is the existing `rename-test.sh` suite continuing to pass once its `set-title.sh` branches are removed.

---

## File Structure

- **Create:** `skills/autoname/SKILL.md` — the new skill (frontmatter triggers + short body).
- **Delete:** `scripts/set-title.sh` — vestigial naming entry point.
- **Modify:** `tests/rename-test.sh` — drop the two `set-title.sh` test blocks and the header comment mention.
- **Modify:** `scripts/rename-when-idle.sh:3` — comment says "Run detached by set-title.sh"; it is now spawned by `write-rename.sh`.
- **Modify:** `CLAUDE.md` — remove the `set-title.sh` layout bullet, fix the `rename-when-idle.sh` "Spawned by" clause and the `rename-test.sh` "Covers …" line, and add an `skills/autoname/SKILL.md` bullet.
- **Modify:** `DESIGN.md` — the "Skill: handoff" section now describes two skills.
- **Modify:** `README.md` — mention `/handoff:autoname` as the name-only entry point.

---

## Task 1: Create the autoname skill

**Files:**
- Create: `skills/autoname/SKILL.md`

- [ ] **Step 1: Write the skill file**

Create `skills/autoname/SKILL.md` with exactly this content:

```markdown
---
name: autoname
description: This skill should be used when the user asks to "name this conversation", "name this chat", "name this session", "rename session", "rename this session", "title this session", or "autoname" — to set the Claude Code session title without doing a handoff. Suited to /btw side conversations and any session worth a name while the main thread stays live. Does NOT write a task snapshot or touch memory; for "save handoff", "before /clear", "wrap up", or "I'm done" use the handoff skill instead.
---

# autoname — Session Title Only

Name the current Claude Code session — nothing else. This is handoff's
rename-half on its own: no task snapshot, no memory write, no `/clear`.
Use it for a `/btw` side conversation, or any session worth a name while
the main thread stays live.

## Protocol

Decide a concise session title from the conversation. Make **no tool
calls** to decide it. Title rules: ≤ ~50 characters, Title Case, no
surrounding quotes, no trailing punctuation. The title is always
derived from the conversation — autoname takes no argument.

Then issue a single `Write` of that title as the sole line of
`./.claude/autorename`. That is the only tool call.

A `PostToolUse(Write|Edit)` hook picks the file up, renames the session
via tmux `send-keys` once the prompt goes idle, then deletes it. Outside
tmux the hook's `systemMessage` carries a `/rename <title>` line
instead — relay it in a fenced code block so the user can paste it.

## Anti-patterns

- Writing `handoff-task.md`, updating memory, or running any other tool.
  autoname is rename-only; for residual task state use the handoff skill.
- Taking a title from the user's words verbatim when the conversation
  implies a better one. Derive the title; do not transcribe the request.
- Any location other than `./.claude/autorename` — the hook reads this
  exact path.
```

- [ ] **Step 2: Verify the skill is discoverable and precommit is green**

Run: `just precommit`
Expected: ends with `ok` (the new skill adds no script, so lint/tests are unaffected).

Then confirm the file parses as a skill (frontmatter present, name matches dir):

Run: `head -4 skills/autoname/SKILL.md`
Expected: a `---` fenced frontmatter block with `name: autoname`.

- [ ] **Step 3: Commit**

```bash
git add skills/autoname/SKILL.md
git commit -m "feat: add /handoff:autoname session-naming skill"
```

---

## Task 2: Remove vestigial set-title.sh and its references

`set-title.sh` is wired nowhere (`hooks.json` has no reference; the handoff skill writes `.claude/autorename` directly). The file+hook path autoname now uses supersedes it. Remove the script and every reference in one cohesive commit. The gate is `rename-test.sh` still passing — so remove its `set-title.sh` test blocks first, then delete the script.

**Files:**
- Modify: `tests/rename-test.sh`
- Delete: `scripts/set-title.sh`
- Modify: `scripts/rename-when-idle.sh:3`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Remove the set-title.sh blocks from the test suite**

In `tests/rename-test.sh`, delete the two `set-title.sh` blocks — lines 37–48, i.e. from the comment `# --- set-title.sh: missing title -> exit 2 ...` through the `fallback mentions tmux` assertion (the blank line before `# --- rename-when-idle.sh end-to-end ...` becomes the new separator). The deleted text is exactly:

```bash
# --- set-title.sh: missing title -> exit 2 -------------------------------------
bash "$SCRIPTS/set-title.sh" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 2 ]]; then pass "no title exits 2"; else fail "no title exits 2 (rc=$rc)"; fi

bash "$SCRIPTS/set-title.sh" '   ' >/dev/null 2>&1; rc=$?
if [[ $rc -eq 2 ]]; then pass "whitespace-only title exits 2"; else fail "whitespace-only title exits 2 (rc=$rc)"; fi

# --- set-title.sh: not in tmux -> paste fallback -------------------------------
out="$(env -u TMUX -u TMUX_PANE bash "$SCRIPTS/set-title.sh" 'My Title' 2>&1)"
if [[ "$out" == *"/rename My Title"* ]]; then pass "fallback prints the /rename line"
else fail "fallback prints the /rename line"; fi
if [[ "$out" == *tmux* ]]; then pass "fallback mentions tmux"; else fail "fallback mentions tmux"; fi

```

- [ ] **Step 2: Update the test suite header comment**

In `tests/rename-test.sh`, the header comment (lines 3–6) lists `set-title.sh` branches. Replace:

```bash
# Covers the pure predicates (_rename-lib.sh), the set-title.sh branches
# (no title / not-in-tmux), and the rename-when-idle.sh watcher end-to-end
# against a tmux stub on PATH (no real tmux/Claude needed).
```

with:

```bash
# Covers the pure predicates (_rename-lib.sh) and the rename-when-idle.sh
# watcher end-to-end against a tmux stub on PATH (no real tmux/Claude
# needed).
```

- [ ] **Step 3: Run the rename suite to confirm it still passes without those blocks**

Run: `bash tests/rename-test.sh`
Expected: `All tests passed.` (the remaining `_rename-lib.sh` and `rename-when-idle.sh` assertions, no longer referencing `set-title.sh`).

- [ ] **Step 4: Delete the script**

```bash
git rm scripts/set-title.sh
```

- [ ] **Step 5: Fix the rename-when-idle.sh provenance comment**

In `scripts/rename-when-idle.sh`, line 3 reads:

```bash
# `/rename <title>` into it. Run detached by set-title.sh so it outlives the
```

Replace `set-title.sh` with `write-rename.sh`:

```bash
# `/rename <title>` into it. Run detached by write-rename.sh so it outlives the
```

- [ ] **Step 6: Remove the set-title.sh bullet and fix the two dependent mentions in CLAUDE.md**

In `CLAUDE.md`, delete the entire `set-title.sh` layout bullet:

```markdown
- `scripts/set-title.sh` — skill entry point for session naming. Takes the
  title as arguments. Inside tmux, spawns a detached `rename-when-idle.sh`
  watcher and returns immediately; outside tmux prints a `/rename <title>`
  line to paste.
```

In the `rename-when-idle.sh` bullet, the clause `Spawned by \`set-title.sh\`;` now names the wrong spawner — change it to `Spawned by \`write-rename.sh\`;` so the sentence reads:

```markdown
  landed (status bar) and retries up to 3×. Spawned by `write-rename.sh`;
  outlives the agent turn.
```

In the `tests/rename-test.sh` description further down, replace:

```markdown
  `_rename-lib.sh` predicates, `set-title.sh` branches (no title,
  not-in-tmux), and `rename-when-idle.sh` end-to-end via a tmux stub.
```

with:

```markdown
  `_rename-lib.sh` predicates and `rename-when-idle.sh` end-to-end via a
  tmux stub.
```

- [ ] **Step 7: Run precommit to confirm the whole suite is green**

Run: `just precommit`
Expected: ends with `ok`. `shellcheck -x scripts/*.sh tests/*.sh` now has one fewer file; `rename-test.sh` passes without the `set-title.sh` blocks.

- [ ] **Step 8: Commit**

```bash
git add CLAUDE.md scripts/rename-when-idle.sh tests/rename-test.sh
git commit -m "refactor: remove vestigial set-title.sh"
```

---

## Task 3: Document the autoname skill

**Files:**
- Modify: `CLAUDE.md`
- Modify: `DESIGN.md`
- Modify: `README.md`

- [ ] **Step 1: Add the autoname skill to the CLAUDE.md layout list**

In `CLAUDE.md`, directly after the `skills/handoff/SKILL.md` bullet (the one describing `/handoff:handoff` and the task template), add:

```markdown
- `skills/autoname/SKILL.md` — the `/handoff:autoname` skill. Decides a
  session title from the conversation (no tool calls) and writes it to
  `.claude/autorename`; the same `write-rename.sh` PostToolUse hook that
  handoff relies on does the rename. Rename-only — no task file, no
  memory. For `/btw` side conversations and any session worth a name
  while the main thread stays live.
```

- [ ] **Step 2: Update the DESIGN.md "Skill: handoff" section**

In `DESIGN.md`, the "## Skill: handoff" section opens with "One skill ships with the plugin:". Replace that line and the existing single bullet so it reads:

```markdown
Two skills ship with the plugin:

- **`/handoff:handoff`** — the main skill. Updates memory, then
  decides whether to write `handoff-task.md` from a template. The
  cleanup case is handled by the PreToolUse hook at activation; the
  load case is handled by the SessionStart hook at the next session.
  As part of its flow it also writes the session title to
  `.claude/autorename`.
- **`/handoff:autoname`** — handoff's rename-half on its own: decides a
  session title from the conversation and writes it to
  `.claude/autorename`, letting the shared `write-rename.sh` hook drive
  the `/rename`. No task snapshot, no memory write. For a `/btw` side
  conversation or any session worth a name while the main thread stays
  live. handoff does not route through it (no benefit, one extra turn);
  the two skills only share the `.claude/autorename` trigger file. See
  `docs/superpowers/specs/2026-06-07-autoname-skill-design.md`.
```

- [ ] **Step 3: Mention /handoff:autoname in the README**

In `README.md`, the "## Usage" section ends with "Or invoke explicitly with `/handoff:handoff`." Immediately after that line, add a short paragraph:

```markdown
To name the session *without* a handoff — a `/btw` side conversation, or
any session worth a title while the main thread stays live — invoke
`/handoff:autoname`. It derives a title from the conversation and renames
the session (via the same tmux `send-keys`-when-idle path as handoff, or
a `/rename` line to paste outside tmux); it writes no task file and
touches no memory.
```

- [ ] **Step 4: Verify precommit is still green**

Run: `just precommit`
Expected: ends with `ok` (docs-only changes, no script/test impact).

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md DESIGN.md README.md
git commit -m "docs: document /handoff:autoname skill"
```

---

## Self-Review

**Spec coverage:**
- Mechanism (decide title, write `.claude/autorename`, hook drives rename, relay paste line) → Task 1 SKILL.md body. ✓
- Triggers, disjoint from handoff phrases → Task 1 frontmatter. ✓
- No argument / always auto-derive → Task 1 Protocol + anti-pattern. ✓
- Zero new scripts/hooks/tests → no task adds any; verification is `just precommit`. ✓
- Remove `set-title.sh` + test branches + CLAUDE.md mentions → Task 2 (also catches the `rename-when-idle.sh:3` and CLAUDE.md "Spawned by" dependents the spec implied). ✓
- Docs: DESIGN.md "Skill: handoff", CLAUDE.md layout bullet, README → Task 3. ✓
- Non-goal: handoff unchanged → no task modifies `skills/handoff/SKILL.md` or the rename scripts' behavior. ✓

**Placeholder scan:** No TBD/TODO; every edit shows exact old/new text. ✓

**Type/name consistency:** Skill name `autoname`, dir `skills/autoname/`, invocation `/handoff:autoname`, trigger file `.claude/autorename`, driving hook `write-rename.sh` — consistent across all tasks. ✓
