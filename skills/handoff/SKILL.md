---
name: handoff
description: This skill should be used when the user asks to "save handoff", "save context", "prepare handoff", "before /clear", "before I clear", "write handoff", "clean handoff", "discard handoff", "clear handoff", "finalize", "wrap up", "I'm done", or otherwise signals imminent `/clear` or end-of-task. Writes a short markdown task file when there is residual state worth preserving across `/clear`; otherwise leaves nothing in place.
---

# handoff — Pre-Clear Task Snapshot

Preserve the irreducible residual across `/clear`: what was in
progress and what's still undecided. A `PreToolUse(Skill)` hook wipes
any prior handoff files before this skill runs, so every invocation
starts clean. A `PostToolUse(Write|Edit)` hook regenerates
`.claude/handoff.md` (last user prompts, files touched) the moment
the task file is written, so extraction is visible in the same turn.

## Protocol

### Step 1: Update memory

If durable learnings surfaced this session, capture them in
auto-memory now. Skip if nothing durable surfaced — do not force.

### Step 2: Decide

Is there an active task with specific next steps, unmade decisions, or
non-obvious context worth preserving for the next agent?

- **Yes** → write the task file (Step 3).
- **No** → done. Prior files were already wiped at activation; the
  next session starts clean.

### Step 3: Write the task file

Write `./.claude/handoff-task.md` with this template. Create the
directory if missing.

```markdown
## Current task

<ONE SENTENCE describing what was in progress. Not a recap. What needs
to resume when a fresh agent picks up. Overflow belongs in memory or
git.>

## Open decisions

- <Unmade choice, phrased as a decision still to make, with enough
  context to decide.>

<Drop the section if there are no open decisions. No filler.>
```

Rules:

- No `#` heading — the wrapper provides one.
- No file paths or code unless a decision hinges on them. The
  post-write hook adds files-touched.
- No location other than `./.claude/handoff-task.md` — the hook reads
  this exact path.

### Step 4: Confirm

Report what happened: task file written (and `handoff.md` regenerated
by the post-write hook in the same turn), or nothing to hand off.

## Anti-patterns

- A multi-sentence "Current task". One sentence; the rest goes to
  memory or git.
- Durable lessons in `## Open decisions`. Those go to feedback memory.
- Extra sections in `handoff-task.md`. The template is fixed.

## Additional resources

- **`references/design.md`** — design rationale: what the residual is
  and why the agent-authored task file plus mechanical extract split.
