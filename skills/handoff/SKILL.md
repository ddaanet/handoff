---
name: handoff
description: Snapshot the in-progress task and still-open decisions before a `/clear` or new session, so the next one resumes where this left off — and, when asked, carry the reset out: name the session, `/clear`, and submit a continuation prompt into the fresh one. A lightweight, local task frame, not a conversation summary. Use when the user asks to "save handoff", "save context", "prepare handoff", "prepare clear", "write handoff", "before /clear", "before I clear", "clear handoff", "discard handoff", "clean handoff", "finalize", "wrap up", "I'm done", "/handoff", "handoff", "conversation too long", "end", "goodbye", "continue after clear", "continue in a new session", "clear and continue", "pick this up in a new chat", or otherwise signals an imminent `/clear` or end of task. To compact rather than clear, use the precompact skill.
---

# handoff — Task Snapshot at the Clear Boundary

Preserve the irreducible residual across `/clear`: what was in progress
and what's still undecided. When the user wants the reset carried out
rather than prepared, this skill drives it too — the rename, the `/clear`,
and the prompt that resumes the work on the far side.

A clear is the cheaper reset. A compaction pays to summarise and loses
accuracy doing it; a clear discards the conversation and carries the frame
across intact. What it gives up is everything the frame does not carry,
which is the plugin's whole thesis about what a session boundary needs.

`handoff-checkpoint` handles the writes, the staging and the transition
file — this skill's job is deciding what goes in them.

## Protocol

**Make zero tool calls before invoking `handoff-checkpoint`.** Steps 1 and 3
both decide from the conversation already in context — the deciding agent
already holds everything it needs. A Read, Bash, or Grep call here
duplicates work `handoff-checkpoint` does internally, and risks acting on
state that is stale by the time it writes.

### Step 1: Decide what this call is for

Three answers, from the request and the state of the work. None of them has
a default: a default is the answer given by an agent that never considered
the question, and considering it is the whole contribution.

**Is the transition typed?** `clear: true` when the user asked for the
reset to be carried out — "clear and continue", "continue in a new
session", "pick this up in a new chat". `clear: false` when they are
preparing one they will run themselves — "save handoff", "before I clear",
"wrap up". A request that asks for the clear **is** the authorization to
clear; do not ask whether to proceed.

**Is there a continuation prompt?** `continue` is one line of prose,
submitted into the session the clear opens, or `null` when nothing follows
it. The seam section below decides what it carries. It is only meaningful
alongside a typed transition — nothing would type it otherwise, and the
checkpoint rejects the combination.

**Does the ask imply a commit?** Two answers of equal weight:

- **`with-commit`** — the request this call serves implies a commit.
  "handoff and commit" does; so do "handoff and amend" and "handoff and
  ci", which contain neither the word nor a substring of it. The test is
  interpretation, not a keyword.
- **`without-commit`** — it does not. What the session learned stands on
  its own.

The ask stops at the transition. A commit named in a continuation prompt is
on the far side of it, where no live session owes it, so it is not evidence
of `with-commit`.

Under `with-commit`, memory bodies state present-tense truth — the change
described as made rather than proposed. Memory phrased as pending is false
from the moment the change exists, and gets re-injected that way at the
next session start.

### Step 2: Update memory

If durable learnings surfaced this session, capture them in
auto-memory now. Skip if nothing durable surfaced — do not force.

### Step 3: Decide, then checkpoint

First, decide all of the following:

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
  "clear": <true|false>,
  "continue": <"one line of prose"|null>,
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

Author the continuation prompt **silently**. It gets typed visibly into the
composer and lands in scrollback, so reprinting it in the reply shows the
same text twice with no veto value.

When the ask includes a commit, it lands **before** the transition is
armed: before this call when nothing holds the sentinel back, and before
`handoff-approved` when the directive in step 4 does. Arm first and the
clear runs at the turn boundary instead of the commit — and under
`with-commit` that strands memory owed to a commit nobody makes.

### Step 4: Follow the directive

`handoff-checkpoint` prints nothing when there is nothing further to do. If
it prints a directive, follow it exactly; the directive carries its own
instructions. The checkpoint owns the decision — do not re-derive or verify
it. A non-zero exit names the offending field on stderr — fix the payload
and retry.

A driven transition whose directive needs an answer is written but not
armed, and the directive says how to release it. That is what keeps the
clear from running at the end of the turn that asked the question.

### Step 5: Say what the boundary is ready for

Once nothing is left awaiting an answer, end on one line. Where the
transition is prepared, name what comes next: under `with-commit` the
commit then the clear — "Ready to commit, then /clear" — and under
`without-commit` the clear alone. Where it is driven, one line saying the
clear is armed, and the turn ends. The frame is on disk and this is a
handover, not a report.

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

Both files are re-injected verbatim on the far side of the transition. The
continuation prompt is one line typed into a composer. So they carry
different things:

- **Task file** — everything that must survive exactly: in-flight threads,
  open questions, identifiers, commit ranges, paths a decision hinges on.
- **Todo file** — the open items of an active task list, and only those.
- **Prompt** — a handle to that context plus the next concrete action.
  Nothing else.

The failure mode is a prompt carrying facts. `report on the driver, then
cut the release covering 7f3c70c..a3b9cef` is wrong: that commit range is
content, and it belongs in the task file. `pick up the release described
in the task file` is right. A clear does not summarise, so a fact left out
of the files is simply gone.

Write the prompt as an instruction to the agent on the far side, which will
have the files and the repo — and, after a compaction, a summary — but not
this conversation. Name the next action, not the topic.

- Good: `continue with the watcher tests per the task file`
- Bad: `continue` / `keep going with the plugin work`

It must be a **single line**: one Enter is one submit, so an embedded
newline would submit it early.

## Anti-patterns

- Reading `handoff-task.md`, `handoff-todo.md`, or any other file "to
  check" before deciding what to write in Step 1 or Step 3. The decision
  comes from the conversation already in context — re-reading duplicates
  what `handoff-checkpoint` does internally.
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
- Asking whether to clear, or telling the user to run `/clear`, under a
  driven transition. Both are settled by the request and the armed file.
- Reprinting the continuation prompt, or printing the `/clear` line, as
  something for the user to run. There is one producer of that pasteable
  form and it is the hook — which is also what covers a session outside
  tmux, where there is no composer to type into.
- Writing `.claude/autodrive` directly. The checkpoint composes it from
  the payload; a hand-written one is a second writer of the same channel.

## Additional resources

- **`references/design.md`** — design rationale: what the residual is
  and why the agent-authored task file plus read-time assembly split.
