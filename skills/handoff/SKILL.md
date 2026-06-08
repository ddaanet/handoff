---
name: handoff
description: This skill should be used when the user asks to "save handoff", "save context", "prepare handoff", "before /clear", "before I clear", "write handoff", "clean handoff", "discard handoff", "clear handoff", "finalize", "wrap up", "I'm done", or otherwise signals imminent `/clear` or end-of-task. Writes a short markdown task file when there is residual state worth preserving across `/clear`; otherwise leaves nothing in place.
---

# handoff — Pre-Clear Task Snapshot

Preserve the irreducible residual across `/clear`: what was in
progress and what's still undecided. Hooks handle wipe-before-write
and extract-after-write — your job is the task file.

## Protocol

### Step 1: Update memory

If durable learnings surfaced this session, capture them in
auto-memory now. Skip if nothing durable surfaced — do not force.

### Step 2: Decide, then write in parallel

First, decide both of the following without making any tool calls:

- **Session title** — a concise, specific title (≤ ~50 characters, Title
  Case, no surrounding quotes, no trailing punctuation) for the work done
  this session.
- **Task snapshot** — whether there's an active task with specific next
  steps, unmade decisions, or non-obvious context worth preserving; if so,
  draft the content using the template below.

Then issue the Write calls in the **same turn**:
- `./.claude/autorename` — sole line is the session title (always)
- `./.claude/handoff-task.md` — only if there's an active task

If there's no active task, omit `handoff-task.md` — the activation hook
already finalized the session.

**Task file template:**

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

Task file rules:

- No `#` heading — the read-time hook prepends one when it assembles
  the frame next session.
- No file paths or code unless a decision hinges on them. The
  read-time hook adds files-touched.
- No location other than `./.claude/handoff-task.md` — the hook reads
  this exact path.

If the autorename systemMessage contains a `/rename ...` line (not in
tmux), relay it in a fenced code block so the user can paste it.

## Anti-patterns

- A multi-sentence "Current task". One sentence; the rest goes to
  memory or git.
- Durable lessons in `## Open decisions`. Those go to feedback memory.
- Extra sections in `handoff-task.md`. The template is fixed.

## Additional resources

- **`references/design.md`** — design rationale: what the residual is
  and why the agent-authored task file plus mechanical extract split.
