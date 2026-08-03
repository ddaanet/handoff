---
name: precompact
description: Commit durable memory and snapshot the in-progress task before a manual `/compact`, so the compaction has nothing left to lose. Prepares only — it types nothing and runs no command. Use when the user asks to "precompact", "prepare compaction", "prepare compact", "before compact", "before I compact", "about to compact", "flush memory before compact", or otherwise signals an imminent manual `/compact`. When the user wants the compaction carried out rather than prepared — "compact and continue" — use the compact-continue skill instead; for an imminent `/clear` or end of task, use the handoff skill.
---

# precompact — Prepare for Compaction

Compaction paraphrases the conversation; disk survives it untouched. So:
put what matters on disk before it runs.

This skill prepares and stops. It flushes memory, writes the task and todo
files, and marks the compaction as expected. It types nothing, runs no
command, and authors no continuation prompt — `compact-continue` is the
skill that adds those.

## Steps

1. Decide, from the request and the state of the work and without making
   any tool calls, whether a commit is going to carry this session's
   memory. Two answers, of equal weight: **`with-commit`** — a commit is
   going to land the change that memory documents, whether this request is
   what commits it or a later one is — and **`without-commit`** — no such
   commit is coming. There is no default, and the answer is about where the
   memory belongs rather than which command the user typed.

   Under `with-commit`, memory bodies state present-tense truth — the
   change described as made rather than proposed. Memory phrased as pending
   is false from the moment the change exists, and the compaction
   re-injects it that way.

2. If durable learnings surfaced this session, capture them in auto-memory
   now. Skip if nothing durable surfaced — do not force.

3. Decide the task snapshot and, when a task list with open items is in
   play, the todo remainder — one `## Current task` section and, when any
   remain, `## Open decisions`, for the task file; one `## Remaining`
   section, open items only, for the todo file. That list lives in the
   context the compaction is about to paraphrase; deciding it now is what
   spares your post-compaction self from inferring which items are still
   open — an inference that fails silently by redoing finished work.

   The `handoff` skill holds the full templates, the rules behind them, and
   the seam between what belongs in a file and what belongs in a prompt, in
   the `SKILL.md` beside this one — `../handoff/SKILL.md`, relative to this
   skill's own directory. Read that file when the rules matter.

   Then run `handoff-checkpoint` (Bash) with `"skill": "precompact"` (no
   `rename` field — precompact never renames), the `commit` answer from
   step 1, and `task`/`todo` each either the drafted content or `null`:

   ```
   handoff-checkpoint <<'JSON'
   {
     "skill": "precompact",
     "commit": "<with-commit|without-commit>",
     "task": {"file_path": "<abs path to>/.claude/handoff-task.md", "content": "<task content, or null>"},
     "todo": {"file_path": "<abs path to>/.claude/handoff-todo.md", "content": "<todo content, or null>"}
   }
   JSON
   ```

   Follow any directive it prints **exactly**. Nothing printed → nothing
   further to do. The checkpoint owns the decision; do not re-derive or
   verify it. A non-zero exit names the offending field on stderr — fix the
   payload and retry.

4. Write `./.claude/autodrive`, containing exactly two lines:

   ```
   armed
   compact
   ```

   Those two words are the whole file: the state the hooks take it from, and
   the transition it describes. Nothing is armed to type; what it records is
   that a compaction is *expected*, which is what the frame's re-injection is
   gated on. Without it the compaction that follows re-injects nothing, and
   the summariser's paraphrase is all that survives of the files just
   written.

5. Once nothing is left awaiting an answer, end on one line naming what
   comes next. Under `with-commit` that is the commit, then the compaction
   — "Ready to commit, then /compact". Under `without-commit` it is the
   compaction alone. One line: the frame is on disk and this is a handover,
   not a report.

The normal case — nothing durable, clean memory, no directive — is one
silent checkpoint call, one file write, and one line of reply.

## Anti-patterns

- Running `/compact`, or arming anything that types it. This skill's
  contract is that it touches no composer; a user who wants the compaction
  driven invokes `compact-continue`.
- Authoring a continuation prompt. There is nothing here to type it, and an
  unprinted line is one the user cannot run.
- A `rename` field in the checkpoint payload. A rename is
  `/handoff:autoname`'s job when wanted, and the checkpoint rejects it here.
- Forcing a memory write to have something to show. An empty flush is the
  normal case.
- Padding the closing line into a summary of the session. The compaction is
  about to produce one.
