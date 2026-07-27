---
name: precompact
description: Commit durable memory, run `/compact`, and resume the work against the compacted context — an attended "compact and continue" driven end to end. Use when the user asks to "precompact", "before compact", "before I compact", "prepare compact", "about to compact", "flush memory before compact", or otherwise signals an imminent manual `/compact`. For an imminent `/clear` or end of task, use the handoff skill instead — it snapshots the task and names the session.
---

# precompact — Compact and Continue

Compaction paraphrases the conversation; disk survives it untouched.
So: put what matters on disk, compact, and resume.

**Continuation is intrinsic.** precompact ⟹ compact ⟹ continue. Nobody
compacts right before a `/clear` (that discards what compaction just paid
to summarise) or before stopping (there is nothing to prepare for). If the
work is ending, that is `handoff` + `/clear`, not this skill.

Invoking precompact **is** the authorization to compact. Do not ask the
user whether to proceed.

## Steps

1. Decide, from the request and the state of the work and without making
   any tool calls, whether a commit is going to carry this session's
   memory. Two answers, of equal weight: **`with-commit`** — a commit is
   going to land the change that memory documents, whether this request is
   what commits it or a later one is — and **`without-commit`** — no such
   commit is coming. There is no default, and the answer is about where the
   memory belongs rather than which command the user typed. It feeds the
   checkpoint call in step 3, and it changes what step 4 does.

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

   The `handoff` skill holds the full templates and the rules behind them,
   in the `SKILL.md` beside this one — `../handoff/SKILL.md`, relative to
   this skill's own directory. Read that file when the rules matter.

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

4. Write `./.claude/autocompact` — **only once step 3 is fully complete**,
   never in the same turn as a question the directive requires.
   Writing it arms compaction at the *next* turn boundary, and a question
   ends the turn — so an autocompact written alongside an approval request
   compacts away the very conversation the answer applies to. When a
   directive needs an answer, end the turn on the question and write the
   file in the turn after it is resolved.

   When the commit is part of this request, it lands **before** this file
   is written, for the same reason: arm the compaction first and it runs at
   the turn boundary instead of the commit. Exactly two lines:

   - **Line 1** — the literal command to run: `/compact`, or
     `/compact <directive>` when a focus instruction would help the
     summariser keep the right material.
   - **Line 2** — the continuation prompt: one line of prose that resumes
     the work. It must be a **single line** — one Enter is one submit, so
     an embedded newline would submit it early.

The normal case — nothing durable, clean memory, no directive — is one
silent checkpoint call and one file write (`autocompact`).

## The seam: task file vs. prompt

The task file and the todo remainder are re-injected verbatim once the
compaction finishes. The prompt is one line typed into a composer. So they
carry different things:

- **Task file** — everything that must survive exactly: in-flight threads,
  open questions, identifiers, commit ranges, paths a decision hinges on.
- **Todo file** — the open items of an active task list, and only those.
- **Prompt** — a handle to that context plus the next concrete action.
  Nothing else.

The failure mode is a prompt carrying facts. `report on the driver, then
cut the release covering 7f3c70c..a3b9cef` is wrong: that commit range is
content, and it belongs in the task file. `pick up the release described
in the task file` is right.

Write the prompt as an instruction to your post-compaction self, which
will have the summary, the task file, and the repo — but not this
conversation. Name the next action, not the topic.

- Good: `continue with the watcher tests per the task file`
- Bad: `continue` / `keep going with the plugin work`

Author it **silently**. Do not reprint it in the reply: it gets typed
visibly into the prompt and lands in scrollback, so echoing it shows the
same text twice with no veto value. At most one line confirming the
compaction is armed.

## What happens next

Nothing further remains. Writing `autocompact` arms the machinery:
the compaction runs at the end of this turn, the task file is re-injected
once it completes, and the continuation prompt is submitted automatically.
Do not run `/compact` directly, do not tell the user to run it, and do not
end with a handoff-style summary — the turn simply ends.

## Anti-patterns

- Asking whether to compact, or telling the user to run `/compact`. Both
  are already settled by the invocation and the armed file.
- A prompt that carries content the task file should hold. If losing a
  fact would break the continuation, it goes in the file.
- Writing `./.claude/autorename`. A rename is `/handoff:autoname`'s job
  when wanted.
- Forcing a memory write to have something to show. An empty flush is the
  normal case.
- A multi-line or vague continuation prompt. The first breaks submission;
  the second wastes the compaction.
