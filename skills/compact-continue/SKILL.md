---
name: compact-continue
description: Commit durable memory, snapshot the in-progress task, then carry out the compaction — run `/compact` and submit a continuation prompt into the compacted context, driven end to end. Use when the user asks to "compact and continue", "compact then continue", "do this after compact", "compact and pick up", or otherwise asks for the compaction to be carried out rather than prepared. For preparation alone, where the user types `/compact` themselves, use the precompact skill instead; for an imminent `/clear`, use handoff or handoff-continue.
---

# compact-continue — Compact and Continue

Everything `precompact` does, plus the two lines that carry it out: the
`/compact` command, and the prompt that resumes the work on the far side.

**Continuation is intrinsic.** compact ⟹ continue. Nobody compacts right
before a `/clear` (that discards what compaction just paid to summarise) or
before stopping (there is nothing to prepare for). If the work is ending,
that is `handoff`, not this skill.

Invoking compact-continue **is** the authorization to compact. Do not ask
the user whether to proceed.

## Protocol

Run steps 1–3 of the `precompact` skill — `../precompact/SKILL.md`,
relative to this skill's own directory — exactly as written. Read that
file; the commit-awareness decision, the memory flush and the task/todo
drafting rules are identical here, and they live in one place so the two
cannot disagree. Pass `"skill": "compact-continue"` in the checkpoint
payload rather than `"precompact"`.

Then, in place of that skill's steps 4 and 5:

**Write `./.claude/autodrive`** — only once step 3 is fully complete, never
in the same turn as a question the directive requires. Writing it arms the
compaction at the *next* turn boundary, and a question ends the turn — so a
sentinel written alongside an approval request compacts away the very
conversation the answer applies to. When a directive needs an answer, end
the turn on the question and write the file in the turn after it is
resolved.

When the commit is part of this request, it lands **before** this file is
written, for the same reason: arm the compaction first and it runs at the
turn boundary instead of the commit.

Exactly four lines:

```
armed
compact
/compact <focus directive, or nothing>
<continuation prompt>
```

- **Line 1** — the literal word `armed`, and nothing else. It is the
  transition's state; the hooks own every state after this one.
- **Line 2** — the literal word `compact`, and nothing else. It says which
  transition this is.
- **Line 3** — the command as it will be typed: `/compact`, or
  `/compact <directive>` when a focus instruction would help the summariser
  keep the right material.
- **Line 4** — the continuation prompt: one line of prose that resumes the
  work, following the seam rules in `../handoff/SKILL.md`. It must be a
  **single line** — one Enter is one submit, so an embedded newline would
  submit it early.

Author line 4 **silently**. It gets typed visibly into the composer and
lands in scrollback, so reprinting it in the reply shows the same text
twice with no veto value.

## What happens next

Nothing further remains. Writing the file arms the machinery: the
compaction runs at the end of this turn, the task file is re-injected once
it completes, and the continuation prompt is submitted automatically. Do
not run `/compact` directly, do not tell the user to run it, and do not end
with a handoff-style summary — at most one line saying the compaction is
armed, and the turn ends.

Outside tmux there is no composer to type into. The hook that arms the
transition is what notices, and it emits the lines for the user to paste,
in order, from the file just written. Nothing in this skill changes.

## Anti-patterns

- Asking whether to compact, or telling the user to run `/compact`. Both
  are settled by the invocation and the armed file.
- Reprinting the continuation prompt, or printing the `/compact` line, as
  something for the user to run. One producer of the pasteable form, and it
  is the hook.
- A prompt that carries content the task file should hold. If losing a fact
  would break the continuation, it goes in the file.
- A `rename` field in the checkpoint payload. The checkpoint rejects it
  here; a rename is `/handoff:autoname`'s job when wanted.
- A multi-line or vague continuation prompt. The first breaks submission;
  the second wastes the compaction.
