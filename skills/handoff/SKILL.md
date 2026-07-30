---
name: handoff
description: Snapshot the in-progress task and still-open decisions before a `/clear` or new session, so the next session resumes where this one left off. A lightweight, local task frame — not a conversation summary. Prepares only; it types nothing. Use when the user asks to "save handoff", "save context", "prepare handoff", "prepare clear", "write handoff", "before /clear", "before I clear", "clear handoff", "discard handoff", "clean handoff", "finalize", "wrap up", "I'm done", "/handoff", "handoff", "conversation too long", "end", or "goodbye", or otherwise signals an imminent `/clear` or end of task. When the user wants the reset carried out rather than prepared — "continue after clear", "continue in a new session" — use the handoff-continue skill instead.
---

# handoff — Pre-Clear Task Snapshot

Preserve the irreducible residual across `/clear`: what was in
progress and what's still undecided. `handoff-checkpoint` handles the
writes and staging — this skill's job is deciding what goes in the task
file.

## Protocol

### Step 1: Will a commit carry this session's memory?

Decide from the request and the state of the work, without making any tool
calls. Two answers, of equal weight:

- **`with-commit`** — a commit is going to land the change this session's
  memory documents. The routine wrap-up (`/handoff`, then `/commit`) is
  this answer; so is a change already made but committed later, even in a
  later session, since the memory belongs in that commit either way.
- **`without-commit`** — no such commit is coming. What the session learned
  stands on its own.

There is no default, and the answer is about where the memory belongs
rather than which command the user typed. It feeds the probe invocation in
Step 3, and it changes what the other steps write.

Under `with-commit`, memory bodies state present-tense truth — the change
described as made rather than proposed. Memory phrased as pending is false
from the moment the change exists, and gets re-injected that way at the
next session start.

### Step 2: Update memory

If durable learnings surfaced this session, capture them in
auto-memory now. Skip if nothing durable surfaced — do not force.

### Step 3: Decide, then checkpoint

First, decide all of the following without making any tool calls:

- **Session title** — a concise, specific title (≤ ~50 characters, Title
  Case, no surrounding quotes, no trailing punctuation) for the work done
  this session.
- **Task snapshot** — whether there's an active task with specific next
  steps, unmade decisions, or non-obvious context worth preserving; if so,
  draft the content using the template below.
- **Remaining items** — whether a task list with open items is in play; if
  so, draft the remainder using the todo template below. A `/clear` does not
  paraphrase that list the way a compaction would — it discards it, so disk
  is the only place it survives.

Then run `handoff-checkpoint` (Bash), piping the whole wrap-up as JSON on
stdin via a heredoc:

```
handoff-checkpoint <<'JSON'
{
  "skill": "handoff",
  "commit": "<with-commit|without-commit>",
  "rename": "<session title>",
  "task": {"file_path": "<abs path to>/.claude/handoff-task.md", "content": "<task content, or omit the whole field with null>"},
  "todo": {"file_path": "<abs path to>/.claude/handoff-todo.md", "content": "<todo content, or omit the whole field with null>"}
}
JSON
```

`task` and `todo` are each the file's content, or `null` when there is
nothing to say for that file — the checkpoint decides absence from content,
not from a wipe. `todo` may also carry an incremental edit
(`old_string`/`new_string`) instead of full `content`, for striking a
finished item without regenerating the whole list.

### Step 4: Follow the directive

`handoff-checkpoint` prints nothing when there is nothing further to do. If
it prints a directive, follow it exactly; the directive carries its own
instructions. The checkpoint owns the decision — do not re-derive or verify
it. A non-zero exit names the offending field on stderr — fix the payload
and retry.

### Step 5: Say what the boundary is ready for

Once nothing is left awaiting an answer, end on one line naming what comes
next. Under `with-commit` that is the commit, then the clear — "Ready to
commit, then /clear". Under `without-commit` it is the clear alone. One
line: the frame is on disk and this is a handover, not a report.

**Task file template:**

```markdown
## Current task

<What was in progress — task state, what needs to resume when a fresh
agent picks up. Usually one sentence. Where work genuinely spans several
concurrent threads, name them; a session under pressure carries what it
carries. Threads, not steps — a list of steps is a task list, and that
goes in `handoff-todo.md`. Not a recap. Not git bookkeeping: whether work
is committed/pushed is reconstructable from `git status` at load time, so
never write it here.>

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

**Todo file template** (`./.claude/handoff-todo.md`):

```markdown
## Remaining

- <Open item, one line, phrased as work still to do.>
```

Todo file rules:

- **Open items only.** A finished item is dropped, never checked off.
  What landed is reconstructable from `git log`; a done item still listed
  reads as outstanding and gets redone.
- No `#` heading and no other sections — same shape as the task file.
- No location other than `./.claude/handoff-todo.md`.
- It is a remainder, not a plan of record — but it is versioned like the
  task file, so write it as something that reads well in history.

## The seam: files vs. continuation prompt

Both files are re-injected verbatim on the far side of the transition. A
continuation prompt — which the driven skills author and this one does not
— is one line typed into a composer. So they carry different things:

- **Task file** — everything that must survive exactly: in-flight threads,
  open questions, identifiers, commit ranges, paths a decision hinges on.
- **Todo file** — the open items of an active task list, and only those.
- **Prompt** — a handle to that context plus the next concrete action.
  Nothing else.

The failure mode is a prompt carrying facts. `report on the driver, then
cut the release covering 7f3c70c..a3b9cef` is wrong: that commit range is
content, and it belongs in the task file. `pick up the release described
in the task file` is right.

Write the prompt as an instruction to the agent on the far side, which will
have the files and the repo — and, after a compaction, a summary — but not
this conversation. Name the next action, not the topic.

- Good: `continue with the watcher tests per the task file`
- Bad: `continue` / `keep going with the plugin work`

Author it **silently**. Do not reprint it in the reply: it gets typed
visibly into the prompt and lands in scrollback, so echoing it shows the
same text twice with no veto value.

## Anti-patterns

- Padding "Current task" to look thorough. Length should track how many
  threads are genuinely in flight, not effort.
- A task list in `## Current task`. Steps go to `handoff-todo.md`; the
  task file says what is in progress, not the checklist to get there.
- Completion state in `handoff-todo.md` — `- [x]` lines, "done:" prefixes,
  a struck-through item. The file holds the remainder and nothing else.
- Durable lessons in `## Open decisions`. Those go to feedback memory.
- Extra sections in either file. Both templates are fixed.
- Commit/push status anywhere in either file ("work is uncommitted",
  "ready to commit", a `handoff-todo.md` item saying "commit the work" or
  "push the branch"). It's reconstructable from `git status`/`git log`
  at load time and goes stale the moment the user commits after handoff.
  If uncommitted work matters, what matters is *why* (tests red, decision
  pending) — write that as an open decision, not a status line.

## Additional resources

- **`references/design.md`** — design rationale: what the residual is
  and why the agent-authored task file plus read-time assembly split.
