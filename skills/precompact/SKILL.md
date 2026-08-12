---
name: precompact
description: Commit durable memory and snapshot the in-progress task before a `/compact`, so the compaction has nothing left to lose — and, when asked, carry the compaction out: run `/compact` and submit a continuation prompt into the compacted context. Use when the user asks to "precompact", "prepare compaction", "prepare compact", "before compact", "before I compact", "about to compact", "flush memory before compact", "compact and continue", "compact then continue", "do this after compact", "compact and pick up", or otherwise signals an imminent `/compact`. For an imminent `/clear` or end of task, use the handoff skill.
---

# precompact — Task Snapshot at the Compact Boundary

Compaction paraphrases the conversation; disk survives it untouched. So:
put what matters on disk before it runs. When the user wants the compaction
carried out rather than prepared, this skill drives it too — the `/compact`
itself, and the prompt that resumes the work on the far side.

## Steps

1. Decide, from the request and the state of the work and without making
   any tool calls, three things. None of them has a default: a default is
   the answer given by an agent that never considered the question, and
   considering it is the whole contribution.

   **Is the transition typed?** `compact: true` when the user asked for the
   compaction to be carried out — "compact and continue", "compact then
   continue" — or the focus directive itself (`compact: "keep the parser
   work"`) when one would help the summariser keep the right material.
   `compact: false` when they are preparing one they will run themselves —
   "precompact", "before I compact". A request that asks for the compaction
   **is** the authorization to compact; do not ask whether to proceed.

   **Is there a continuation prompt?** `continue` is one line of prose,
   submitted into the compacted context, or `null` when nothing follows it.
   It is only meaningful alongside a typed transition — nothing would type
   it otherwise, and the checkpoint rejects the combination. The `handoff`
   skill beside this one holds the seam rules that decide its content.

   **Does the ask imply a commit?** Two answers of equal weight:
   **`with-commit`** — the request this call serves implies a commit, a
   test of interpretation rather than of keywords — and **`without-commit`**
   — it does not. The ask stops at the transition: a commit named in a
   continuation prompt is on the far side of it, so it is not evidence of
   `with-commit`.

   Under `with-commit`, memory bodies state present-tense truth — the
   change described as made rather than proposed. Memory phrased as pending
   is false from the moment the change exists, and the compaction
   re-injects it that way.

2. If durable learnings surfaced this session, capture them in auto-memory
   now. Skip if nothing durable surfaced — do not force.

3. Decide the task snapshot and, when open decisions or a task list with
   open items are in play, the todo content — one `## Current task`
   section for the task file; `## Open decisions`, when any remain, plus
   `## Remaining`, open items only, for the todo file. Both lists live in
   the context the compaction is about to paraphrase; deciding them now is
   what spares your post-compaction self from inferring which are still
   open — an inference that fails silently by redoing finished work or
   re-litigating a settled decision.

   The `handoff` skill holds the full templates, the rules behind them, and
   the seam between what belongs in a file and what belongs in a prompt, in
   the `SKILL.md` beside this one — `../handoff/SKILL.md`, relative to this
   skill's own directory. Read that file when the rules matter.

   Then run `handoff-checkpoint` (Bash) with `"skill": "precompact"` (no
   `rename` field — precompact never renames), the three answers from step
   1, and `task`/`todo` each either the drafted content or `null`:

   ```
   handoff-checkpoint <<'JSON'
   {
     "skill": "precompact",
     "commit": "<with-commit|without-commit>",
     "compact": <true|false|"focus directive">,
     "continue": <"one line of prose"|null>,
     "task": {"file_path": "<abs path to>/.claude/handoff-task.md", "content": "<task content, or null>"},
     "todo": {"file_path": "<abs path to>/.claude/handoff-todo.md", "content": "<todo content, or null>"}
   }
   JSON
   ```

   Author the continuation prompt **silently**. It gets typed visibly into
   the composer and lands in scrollback, so reprinting it in the reply
   shows the same text twice with no veto value.

   Even under `compact: false` the checkpoint writes the transition file.
   Nothing is typed; what it records is that a compaction is *expected*,
   which is what the frame's re-injection is gated on. Without it the
   compaction re-injects nothing and the summariser's paraphrase is all
   that survives of the files just written.

   When the ask includes a commit, it lands **before** the transition is
   armed: before this call when nothing holds the sentinel back, and before
   `handoff-approved` when the directive in step 4 does.

4. Follow any directive it prints **exactly**. Nothing printed → nothing
   further to do. The checkpoint owns the decision; do not re-derive or
   verify it. A non-zero exit names the offending field on stderr — fix the
   payload and retry.

   A driven compaction whose directive needs an answer is written but not
   armed, and the directive says how to release it. That is what keeps the
   compaction from running at the end of the turn that asked the question.

5. Once nothing is left awaiting an answer, end on one line. Where the
   compaction is prepared, name what comes next: under `with-commit` the
   commit then the compaction — "Ready to commit, then /compact" — and
   under `without-commit` the compaction alone. Where it is driven, one
   line saying the compaction is armed, and the turn ends. One line: the
   frame is on disk and this is a handover, not a report.

The normal case — nothing durable, clean memory, no directive — is one
silent checkpoint call and one line of reply.

## Anti-patterns

- Running `/compact` yourself, or telling the user to run it under a driven
  transition. Both are settled by the request and the armed file.
- Reprinting the continuation prompt, or printing the `/compact` line, as
  something for the user to run. There is one producer of that pasteable
  form and it is the hook — which is also what covers a session outside
  tmux, where there is no composer to type into.
- Authoring a continuation prompt for a prepared compaction. Nothing types
  it, and the checkpoint rejects it.
- Writing `.claude/autodrive` directly. The checkpoint composes it from the
  payload; a hand-written one is a second writer of the same channel.
- A `rename` field in the checkpoint payload. A rename is
  `/handoff:autoname`'s job when wanted, and the checkpoint rejects it here.
- Forcing a memory write to have something to show. An empty flush is the
  normal case.
- Padding the closing line into a summary of the session. The compaction is
  about to produce one.
