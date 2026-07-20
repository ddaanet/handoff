---
name: handoff
description: Snapshot the in-progress task and still-open decisions before a `/clear` or new session, so the next session resumes where this one left off. A lightweight, local task frame — not a conversation summary. Use when the user asks to "save handoff", "save context", "prepare handoff", "write handoff", "before /clear", "before I clear", "clear handoff", "discard handoff", "clean handoff", "finalize", "wrap up", "I'm done", "/handoff", "handoff", "conversation too long", "let's pick this up in a new chat", "end", or "goodbye", or otherwise signals an imminent `/clear` or end of task.
---

# handoff — Pre-Clear Task Snapshot

Preserve the irreducible residual across `/clear`: what was in
progress and what's still undecided. Hooks handle wipe-before-write
and stage-after-write — your job is the task file.

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

Then, in the **same turn**, issue the writes and run the memory probe:
- Write `./.claude/autorename` — sole line is the session title (always)
- Write `./.claude/handoff-task.md` — only if there's an active task
- Run `handoff-memory-probe` (Bash) — deterministic memory check

If there's no active task, omit `handoff-task.md` — the activation hook
already finalized the session.

### Step 3: Follow the probe

`handoff-memory-probe` prints nothing when there is nothing to do —
finish normally. If it prints a directive, follow it exactly; the
directive carries its own instructions. The probe owns the decision —
do not re-derive or verify it yourself.

**Task file template:**

```markdown
## Current task

<What was in progress — task state, what needs to resume when a fresh
agent picks up. Usually one sentence. Where work genuinely spans several
in-flight threads, list them; a session under pressure carries what it
carries, and cramming it into one line loses the thing worth keeping. Not
a recap. Not git bookkeeping: whether work is committed/pushed is
reconstructable from `git status` at load time, so never write it here.>

## Open decisions

- <Unmade choice, phrased as a decision still to make, with enough
  context to decide.>

<Drop the section if there are no open decisions. No filler.>
```

This file is the durable side of the seam: anything that must survive
**verbatim** — identifiers, commit ranges, file paths a decision hinges
on, the exact shape of an open question — belongs here, because this is
what gets re-injected intact. Prose that a summary would preserve just as
well does not need to be here.

Task file rules:

- No `#` heading — the read-time hook prepends one when it assembles
  the frame next session.
- No file paths or code unless a decision hinges on them. The working
  set is reconstructable from `git status` at load time.
- No location other than `./.claude/handoff-task.md` — the hook reads
  this exact path.

## Anti-patterns

- Padding "Current task" to look thorough. Length should track how many
  threads are genuinely in flight, not effort.
- Durable lessons in `## Open decisions`. Those go to feedback memory.
- Extra sections in `handoff-task.md`. The template is fixed.
- Commit/push status anywhere in the file ("work is uncommitted",
  "ready to commit"). It's reconstructable from `git status`/`git log`
  at load time and goes stale the moment the user commits after handoff.
  If uncommitted work matters, what matters is *why* (tests red, decision
  pending) — write that as an open decision, not a status line.

## Additional resources

- **`references/design.md`** — design rationale: what the residual is
  and why the agent-authored task file plus read-time assembly split.
