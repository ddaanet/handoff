---
name: pending
description: List pending tasks from the session's already-injected context — no tool calls, no file reads. Reports the current task frame's "Open decisions" and "Remaining" items as loaded. Use when the user asks "what's pending", "list pending tasks", "show pending", "pending", or "/handoff:pending".
---

# pending — List Pending Tasks From Context

Report the pending work already visible in context: the `## Current task`
section and the `## Open decisions` / `## Remaining` sections that follow
it in the task frame injected at session start (or after a compact). Make
**no tool calls** — this is a read of what is already in context, not of
the files on disk.

## Protocol

1. Find the most recent task frame already in context.
2. List its open decisions and remaining items, grouped as they appear
   ("Open decisions" / "Remaining"). Trim for brevity; do not re-derive
   or editorialize beyond that.
3. If no frame was injected this session, or it has nothing pending,
   say so plainly rather than guessing.

## Anti-patterns

- Reading `.claude/handoff-task.md` or `.claude/handoff-todo.md` to
  double-check. The point is a zero-cost report of what is already
  loaded; a stale answer here is corrected by editing `handoff-todo.md`
  directly (open decisions, remaining items) or at the next checkpoint
  (the current task), not by a file read now.
- Treating this as a task-management action. It reports only — it never
  edits `handoff-task.md`, `handoff-todo.md`, or memory.
