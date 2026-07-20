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

1. If durable learnings surfaced this session, capture them in auto-memory
   now. Skip if nothing durable surfaced — do not force.

2. Run `handoff-precompact-probe` (Bash) and follow any directive it prints
   **exactly**. Nothing printed → nothing to do. The probe owns the
   decision; do not re-derive or verify it yourself.

3. Write `./.claude/autocompact` — **only once step 2 is fully complete**,
   never in the same turn as a question the directive told you to ask.
   Writing it arms compaction at the *next* turn boundary, and a question
   ends the turn — so an autocompact written alongside an approval request
   compacts away the very conversation the answer applies to. When a
   directive needs an answer, end the turn on the question and write the
   file in the turn after it is resolved. Exactly two lines:

   - **Line 1** — the literal command to run: `/compact`, or
     `/compact <directive>` when a focus instruction would help the
     summariser keep the right material.
   - **Line 2** — the continuation prompt: one line of prose that resumes
     the work. It must be a **single line** — one Enter is one submit, so
     an embedded newline would submit it early.

That is the whole flow. The normal case — nothing durable, clean memory,
no probe output — is one silent probe call and one file write.

## The continuation prompt

Write it as an instruction to your post-compaction self, which will have
the summary and the repo but not this conversation. Name the next concrete
action, not the topic.

- Good: `continue implementing the watcher tests in tests/rename-test.bats`
- Bad: `continue` / `keep going with the plugin work`

Author it **silently**. Do not reprint it in your message: it gets typed
visibly into the prompt and lands in scrollback, so echoing it shows the
same text twice with no veto value. At most one line confirming the
compaction is armed.

## What happens next

Nothing further is yours to do. Writing the file arms the machinery: the
compaction runs at the end of this turn, and the continuation prompt is
submitted for you once compaction completes. Do not run `/compact`
yourself, do not tell the user to run it, and do not end with a
handoff-style summary — the turn simply ends.

## Anti-patterns

- Asking whether to compact, or telling the user to run `/compact`. Both
  are already settled by the invocation and the armed file.
- Writing `handoff-task.md` or `./.claude/autorename`. The task crosses
  compaction in the summary and in the continuation prompt; a rename is
  `/handoff:autoname`'s job when wanted.
- Forcing a memory write to have something to show. An empty flush is the
  normal case.
- A multi-line or vague continuation prompt. The first breaks submission;
  the second wastes the compaction.
