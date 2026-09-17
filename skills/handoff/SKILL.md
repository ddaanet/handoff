---
name: handoff
description: Snapshot the in-progress task and still-open decisions before a `/clear` or new session, so the next one resumes where this left off — and, when asked, carry the reset out: name the session, `/clear`, and submit a continuation prompt into the fresh one. A lightweight, local task frame, not a conversation summary. Use when the user asks to "save handoff", "save context", "prepare handoff", "prepare clear", "write handoff", "before /clear", "before I clear", "clear handoff", "discard handoff", "clean handoff", "finalize", "wrap up", "I'm done", "/handoff", "handoff", "conversation too long", "end", "goodbye", "continue after clear", "continue in a new session", "clear and continue", "pick this up in a new chat", or otherwise signals an imminent `/clear` or end of task. To compact rather than clear, use the precompact skill.
---

# handoff — Task Snapshot at the Clear Boundary

Preserve the irreducible residual across `/clear`: what was in progress
and what's still undecided. When the user wants the reset carried out
rather than prepared, this skill drives it too — the rename, the `/clear`,
and the prompt that resumes the work on the far side.

`handoff-checkpoint` handles the writes, the staging and the transition
file — this skill's job is deciding what goes in them.

## Protocol

### Step 1: Decide, then checkpoint

**Make no tool call before `handoff-checkpoint` other than memory
writes.**

Decide the following from the request and the state of the work. None of
them has a default: considering the question is the whole contribution.

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
checkpoint rejects the combination. Author it **silently**: it is typed
visibly into the composer, so reprinting it in the reply shows it twice.

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

**Capture memory.** If durable learnings surfaced this session, write them
to auto-memory now, before the checkpoint. Under `with-commit`, memory
bodies state present-tense truth — the change described as made rather
than proposed. Skip if nothing durable surfaced — do not force.

Then decide the content:

- **Session title** — a concise, specific title (≤ ~50 characters, Title
  Case, no surrounding quotes, no trailing punctuation) for the work done
  this session.
- **Task snapshot** — whether there's an active task with specific next
  steps or non-obvious context worth preserving; if so, draft the content
  using the template below.
- **Todo content** — whether there are open decisions still to make, or a
  task list with open items in play; if so, draft the todo content using
  the template below (open decisions first, then remaining items).

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
  "task": <"task content"|{"action": "clear"}>,
  "todo": <"todo content"|{"action": "clear"}|{"action": "keep"}|{"action": "edit", "old_string": "…", "new_string": "…"}>
}
JSON
```

Both keys are required, each carrying content as a string or an object
naming an action. `{"action": "clear"}` removes that file — for `task`, this
is how a boundary with nothing to carry says so; for `todo`, it says every
item landed. Content that is empty once headings and blank lines are
stripped removes the file too, on either key — a `## Remaining` with no
items stands the list down as surely as `clear` does. When the call has
nothing to say about the list, send `{"action": "keep"}`, which leaves it
untouched: a scratch list must survive a call that is silent about it, so
`keep` is the default and `clear` is a deliberate stand-down.
`{"action": "edit", …}` strikes a finished item without regenerating it.
`keep` and `edit` apply to `todo` only; `edit` needs the file to exist and
`old_string` to appear in it exactly once. `null` is an error on both, as
is omitting a key, or adding one inside an action object.

### Step 2: Follow the directive

`handoff-checkpoint` prints nothing when there is nothing further to do. If
it prints a directive, follow it exactly; the directive carries its own
instructions. The checkpoint owns the decision — do not re-derive or verify
it. A non-zero exit names the offending field on stderr — fix the payload
and retry.

A driven transition whose directive needs an answer is written but not
armed, and the directive says how to release it.

When the ask includes a commit, make it **after** the checkpoint, so it
carries the handoff files the checkpoint staged, and **before** the
transition is armed: before the turn ends when no directive holds the
transition, and before `handoff-approved` when one does. Arm first and the
clear runs instead of the commit — under `with-commit`, stranding memory
owed to a commit nobody makes.

### Step 3: Say what the boundary is ready for

Once nothing is left awaiting an answer, end on one line. Where the
transition is prepared, name what comes next: under `with-commit` the
commit then the clear — "Ready to commit, then /clear" — and under
`without-commit` the clear alone. Where it is driven, one line saying the
clear is armed, and the turn ends.

## File templates

Neither file takes a `#` heading — the read-time hook prepends one when it
assembles the frame next session. Neither has a location to choose: the
paths below are the only ones, and the checkpoint composes the task file's
from the session root, denying a direct Write there.

**Task file template** (`./.claude/handoff-task.md`):

```markdown
## Current task

<What was in progress — task state, what needs to resume when a fresh
agent picks up. Usually one sentence. Where work genuinely spans several
concurrent threads, name them; a session under pressure carries what it
carries. Threads, not steps — a list of steps is a task list, and that
goes in `handoff-todo.md`. Not a recap.>
```

Task file rules:

- No file paths or code beyond what's needed to say what's in progress.
  The working set is reconstructable from `git status` at load time.

**Todo file template** (`./.claude/handoff-todo.md`):

```markdown
## Open decisions

- <Unmade choice, phrased as a decision still to make, with enough
  context to decide — identifiers, commit ranges, file paths, the exact
  shape of the question, whatever must survive verbatim.>

<Drop the section if there are no open decisions. No filler.>

## Remaining

- <Open item, one line, phrased as work still to do.>
```

Todo file rules:

- **Open items only, in both sections.** A finished item is dropped,
  never checked off, and a resolved decision is dropped too. What
  landed is reconstructable from `git log`; anything still listed reads
  as outstanding and gets redone.
- **A decision the user has left unanswered across several frames is
  declined, not missed.** Drop it, and never annotate one with the number of
  times it has been raised. A listed decision blocks nothing either: work
  that can proceed without the answer is listed as work.
- It is a remainder plus the open questions blocking it, not a plan of
  record — but it is versioned like the task file, so write it as
  something that reads well in history.

## The seam: files vs. continuation prompt

Both files are re-injected verbatim on the far side of the transition. The
continuation prompt is one line typed into a composer. So they carry
different things:

- **Task file** — current task state alone: in-flight threads, what needs
  to resume.
- **Todo file** — the open items of an active task list, plus open
  decisions: identifiers, commit ranges, paths a decision hinges on, the
  exact shape of an open question — everything that must survive verbatim
  for a choice still to be made.
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
  check" before deciding what to write in Step 1. The decision
  comes from the conversation already in context — re-reading duplicates
  what `handoff-checkpoint` does internally, against state that may be
  stale by the time it writes.
- Padding "Current task" to look thorough. Length should track how many
  threads are genuinely in flight, not effort.
- A task list in `## Current task`. Steps go to `handoff-todo.md`; the
  task file says what is in progress, not the checklist to get there.
- Completion state in `handoff-todo.md` — `- [x]` lines, "done:" prefixes,
  a resolved decision left in place, a struck-through item. The file
  holds only what's still open — decisions and remainder alike.
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
  something for the user to run. The hook is the one producer of that
  pasteable form.
- Writing `.claude/autodrive` directly. The checkpoint composes it from
  the payload; a hand-written one is a second writer of the same channel.

## Additional resources

- **`references/design.md`** — design rationale: what the residual is
  and why the agent-authored task file plus read-time assembly split.
