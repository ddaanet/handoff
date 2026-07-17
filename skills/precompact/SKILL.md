---
name: precompact
description: Flush durable learnings to auto-memory before a session compaction, so they survive the summarizer at full fidelity instead of paraphrased. Use when the user asks to "precompact", "before compact", "before I compact", "prepare compact", "about to compact", "flush memory before compact", or otherwise signals an imminent manual `/compact`. For an imminent `/clear` or end of task, use the handoff skill instead — it also snapshots the task and names the session.
---

# precompact — Flush Before /compact

Compaction paraphrases the conversation; disk survives it untouched.
The steps worth taking before a manual `/compact`:

1. If durable learnings surfaced this session, capture them in
   auto-memory now. Skip if nothing durable surfaced — do not force.

2. If this session is mid-structured-task and keeps a durable
   progress/state file — a ledger the compaction summary can't reliably
   reproduce — bring it current before compacting.

3. Run `handoff-precompact-probe` and follow any directive it prints.
   Nothing printed → nothing to do.

Then tell the user to run `/compact`.

## Anti-patterns

- Writing `handoff-task.md` or `./.claude/autorename`. precompact is
  the memory flush alone; the task crosses compaction in the summary,
  and a rename is `/handoff:autoname`'s job when wanted.
- Committing memory. A commit can ride any later commit — compaction
  loses conversation state, never disk state.
- Forcing a memory write to have something to show. An empty flush is
  the normal case.
