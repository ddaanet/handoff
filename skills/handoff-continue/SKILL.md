---
name: handoff-continue
description: Snapshot the in-progress task, then carry out the reset — name the session, `/clear`, and submit a continuation prompt into the fresh one, driven end to end. No summarisation cost: the task frame is what crosses. Use when the user asks to "continue after clear", "continue in a new session", "handoff, clear, continue", "clear and continue", "pick this up in a new chat", or otherwise asks for the reset to be carried out rather than prepared. For preparation alone, where the user types `/clear` themselves, use the handoff skill instead; to compact rather than clear, use precompact or compact-continue.
---

# handoff-continue — Clear and Continue

Everything `handoff` does, plus the three lines that carry out the reset:
the session title, the `/clear`, and the prompt that resumes the work in
the fresh session.

This is the cheaper reset. A compaction pays to summarise and loses
accuracy doing it; a clear discards the conversation and carries the frame
across intact. For a session whose task file is current, it is the better
one — what it gives up is everything the frame does not carry, which is
the plugin's whole thesis about what a session boundary actually needs.

Invoking handoff-continue **is** the authorization to clear. Do not ask the
user whether to proceed.

## Protocol

Run steps 1–4 of the `handoff` skill — `../handoff/SKILL.md`, relative to
this skill's own directory — exactly as written. Read that file; the
commit-awareness decision, the memory flush, the templates and the
file-vs-prompt seam are identical here, and they live in one place so the
two cannot disagree.

Two changes to the checkpoint payload: pass `"skill": "handoff-continue"`,
and **omit `rename`**. The session title still has to be decided in step 3
— it becomes a line of the file below rather than a field, and the
checkpoint rejects the field here.

Then, in place of that skill's step 5:

**Write `./.claude/autodrive`** — only once the checkpoint step is fully
complete, never in the same turn as a question the directive requires.
Writing it arms the clear at the *next* turn boundary, and a question ends
the turn — so a sentinel written alongside an approval request clears away
the very conversation the answer applies to.

When the commit is part of this request, it lands **before** this file is
written. Arm the clear first and it runs at the turn boundary instead of
the commit — and under `with-commit` that strands memory owed to a commit
nobody makes.

Both rules matter most on a cold invocation, where this skill is the first
thing at the boundary and dirty memory raises an approval question. After a
`handoff` has already settled that gate, the checkpoint prints no directive
and there is a turn for everything.

Exactly five lines:

```
armed
clear
/rename <session title>
/clear
<continuation prompt>
```

- **Line 1** — the literal word `armed`, and nothing else. It is the
  transition's state; the hooks own every state after this one.
- **Line 2** — the literal word `clear`, and nothing else. It says which
  transition this is.
- **Line 3** — the rename as it will be typed, carrying the title decided
  in step 3.
- **Line 4** — the literal `/clear`, with no argument.
- **Line 5** — the continuation prompt: one line of prose that resumes the
  work, following the seam rules in `../handoff/SKILL.md`. It must be a
  **single line** — one Enter is one submit, so an embedded newline would
  submit it early.

Author line 5 **silently**. It gets typed visibly into the composer and
lands in scrollback, so reprinting it in the reply shows the same text
twice with no veto value.

## What happens next

Nothing further remains. Writing the file arms the machinery: the session
is renamed and cleared at the end of this turn, the task file is
re-injected into the fresh session, and the continuation prompt is
submitted automatically. Do not run `/clear` directly, do not tell the user
to run it, and do not end with a handoff-style summary — at most one line
saying the clear is armed, and the turn ends.

Outside tmux there is no composer to type into. The hook that arms the
transition is what notices, and it emits the lines for the user to paste,
in order, from the file just written. Nothing in this skill changes.

## Anti-patterns

- Asking whether to clear, or telling the user to run `/clear`. Both are
  settled by the invocation and the armed file.
- Reprinting the continuation prompt, or printing the `/clear` line, as
  something for the user to run. One producer of the pasteable form, and it
  is the hook.
- A `rename` field in the checkpoint payload. The title is line 3 of the
  file, and the checkpoint rejects the field here.
- A prompt that carries content the task file should hold. A clear does not
  summarise, so a fact left out of the files is simply gone.
- A multi-line or vague continuation prompt. The first breaks submission;
  the second wastes the reset.
