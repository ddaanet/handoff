---
name: setup
description: This skill should be used when the user asks to "setup handoff", "install handoff in this project", "initialize handoff", "wire up handoff", "add handoff to CLAUDE.md", "enable handoff", or otherwise wants to configure the current project so handoff artifacts load automatically at session start. Ensures the project's `./CLAUDE.md` contains an `@.claude/handoff.md` reference.
---

# setup — Wire handoff into the project's CLAUDE.md

The handoff plugin produces `./.claude/handoff.md` per project, but the
file only loads automatically when the project's `./CLAUDE.md`
contains an `@.claude/handoff.md` reference. This skill adds that
reference once per project. Idempotent.

## When to invoke

Invoke when the user:

- Asks to "setup handoff", "install handoff in this project",
  "initialize handoff"
- Says "wire up handoff" or "add handoff to CLAUDE.md"
- Asks to enable handoff loading at the start of new sessions

If the reference is already present, proceed as a no-op and confirm in
Step 3.

## Protocol

### Step 1: Check the current state

Look at `./CLAUDE.md` (project root, same level as `.claude/`).

- If it exists, check for a line containing the literal string
  `@.claude/handoff.md` (exact match, not regex). If present, skip to
  Step 3 and report "already set up".
- If it does not exist, proceed to Step 2 — the skill will create it.

Do not look at `~/.claude/CLAUDE.md` or sub-project `CLAUDE.md` files.
Handoff is per-project; the reference belongs in the project root
`CLAUDE.md` only.

### Step 2: Add the reference

Append this exact block to `./CLAUDE.md`:

```markdown
## Handoff

@.claude/handoff.md
```

Idempotency is keyed on the `@.claude/handoff.md` line (the heading is
cosmetic). Do not invent a different heading on re-run — the same
heading text keeps re-runs clean.

If `./CLAUDE.md` does not exist, create it with just this block using
Write.

If `./CLAUDE.md` exists, use Edit to append safely: set `old_string`
to the final line of the current file (read it first), and
`new_string` to that same final line followed by a blank line and the
block above. This preserves all existing content exactly — no
reformatting, no re-ordering, no whitespace changes elsewhere.

### Step 3: Confirm

Report one of:

- "Already set up — `@.claude/handoff.md` already referenced in
  `./CLAUDE.md`."
- "Added `@.claude/handoff.md` reference to `./CLAUDE.md`."
- "Created `./CLAUDE.md` with `@.claude/handoff.md` reference."

Mention that the reference loads any existing `.claude/handoff.md` at
the start of the next session. No further action needed.

## Anti-patterns

- Rewriting or reformatting the existing `./CLAUDE.md`. Append-only
  change. Leave unrelated content exactly as it was.
- Adding the reference to `~/.claude/CLAUDE.md` or a parent
  directory's `CLAUDE.md`. Handoff files are per-project; pollution in
  shared CLAUDE.md is a bug.
- Adding the reference multiple times. The skill is idempotent — run
  twice should produce the same file as run once.
- Inventing a different section heading. Users may re-run the skill,
  and a different heading each time would accumulate duplicates.
