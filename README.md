# handoff

A task snapshot that survives a context reset in Claude Code — whether
that reset is a `/clear` or a `/compact`. Designed as a narrow
complement to Claude Code's auto-memory: memory holds durable facts
(preferences, feedback, project context); this plugin holds the
*ephemeral task frame* memory avoids — what you were doing right now,
what decisions are still open.

Five skills sit on that seam — two boundaries, and at each one a skill that
prepares and a skill that also carries the reset out for you:

| | prepare only | prepare, then do it |
|---|---|---|
| **before `/clear`** | `/handoff:handoff` | `/handoff:handoff-continue` |
| **before `/compact`** | `/handoff:precompact` | `/handoff:compact-continue` |

The prepare-only pair write the task file and stop; you type the command.
The driven pair write the same file and then type the command for you, plus
a one-line prompt that resumes the work on the far side. `/handoff:autoname`
is the fifth: the rename alone, for a session worth a title while the main
thread stays live.

All four write the same file; a `SessionStart` hook injects it back,
verbatim, into whatever comes next.

## Setup

Install the plugin:

```
/plugin marketplace add ddaanet/claude-plugins
/plugin install handoff@ddaanet
```

That's it. No per-project setup step. A `SessionStart(startup|clear)`
hook assembles the handoff frame in memory at session start — stamping
a header onto `./.claude/handoff-task.md` and the todo remainder beside
it, when either exists — and injects the result into
the fresh agent's context. No generated file is involved, and the
transcript is never touched: the live working set is the harness's own
git status.

**Migrating from v0.2.x**: if your project's `CLAUDE.md` contains a
`## Handoff` section with `@.claude/handoff.md` (added by the old
`/handoff:setup` skill, removed in v0.3.0), delete it. Leaving it in
place is harmless but causes the content to load twice (once via the
SessionStart hook, once via the `@`-ref).

## Usage

Before `/clear`, ask the agent to save a handoff:

- "save handoff"
- "before I clear"
- "prepare handoff"
- "wrap up"
- "I'm done"

Or invoke explicitly with `/handoff:handoff`. That prepares and stops —
it saves the frame and tells you what the boundary is ready for, and you
type `/clear` yourself.

To have the reset carried out instead, ask for the continuation:

- "continue after clear"
- "continue in a new session"
- "handoff, clear, continue"

or invoke `/handoff:handoff-continue`. It does everything `handoff` does,
then names the session, clears it, and submits a one-line prompt into the
fresh one. No summarisation cost — the task frame is what crosses.

To name the session *without* a handoff — a `/btw` side conversation, or
any session worth a title while the main thread stays live — invoke
`/handoff:autoname`. It derives a title from the conversation and renames
the session (via the same tmux `send-keys`-when-idle path as handoff, or
a `/rename` line to paste outside tmux); it writes no task file and
touches no memory.

## Compact and continue

The compact boundary is the other half: not a wrap-up, but a way to keep
going. Long sessions eventually have to compact, and compaction paraphrases
the conversation — anything that has to survive *exactly* should be on disk
first. Both skills capture durable learnings in auto-memory, commit them if
your repo is gitlore-managed, and write the task file.

`/handoff:precompact` stops there, and you run `/compact` yourself; the task
file is still re-injected when it finishes, because the skill marked the
compaction as expected. `/handoff:compact-continue` goes on to drive it:
`/compact` is typed into the prompt once your turn ends, and once it
finishes, the task file is re-injected and a one-line continuation prompt is
submitted. You do not run `/compact` yourself, and you do not have to type
anything to resume.

All four write the same `.claude/handoff-task.md`. That is the durable side
of the seam — it carries whatever must survive verbatim, at whatever length
the work demands. The continuation prompt is only a handle to it.

When the session is working through a task list, both skills also write the
**remainder** — the still-open items, never the finished ones — to
`.claude/handoff-todo.md`, which is injected alongside the task file. That
file is the ledger; a todo panel in the UI, when there is one, is a cache of
it. Finished items are dropped rather than ticked off: `git log` already
records what landed, and a done item still listed reads as outstanding and
gets redone. It is staged for commit like the task file — it is overflow from
that file, so it belongs in the same trail.

Driving the prompt needs tmux; outside it, the lines are printed for you to
paste, in order. If a line fails to land — the pane was busy, you were
mid-sentence, the command was not recognized — the watcher records why, and
you and the agent are told at your next prompt rather than being left to
wonder whether the transition happened. A line that cannot be confirmed
stops the sequence, so a rename that never took costs you a wrong title and
nothing more.

Use a compact-boundary skill when the work continues past a long session,
and a clear-boundary one when the thread itself should restart. Compacting
right before `/clear` throws away what the compaction just paid for.

The agent updates auto-memory with any durable learnings, then in a single turn decides the task snapshot (if anything is outstanding), the todo remainder (if a task list is in flight), and a session title, and pipes all three to one `handoff-checkpoint` call as a JSON payload. The checkpoint writes or edits `.claude/handoff-task.md` and `.claude/handoff-todo.md`, and `.claude/autodrive` when a rename is wanted, leaving a manifest behind — an empty task or todo body removes the file rather than leaving a stale one, so content decides absence, not a wipe on activation. A `PostToolUse(Bash)` hook consumes that manifest and stages every listed path for commit (deletions included). Anything to be typed waits for the turn to end: a `Stop` hook arms it and spawns one watcher, which types each line via tmux `send-keys` once the prompt goes idle, confirms each against the harness rather than the screen, and moves on to the next. A guard denies any direct agent Write or Edit to `.claude/handoff-task.md` — it is written by the checkpoint only. `.claude/handoff-todo.md` stays open for the agent to edit directly all session; a `PostToolUse(Write|Edit)` hook stages those edits on the spot. After `/clear` (or in a fresh session), the `SessionStart` hook assembles and injects the handoff frame into the new agent's context automatically. Auto-memory restores independently. `SessionStart` also publishes the session's root at `/tmp/claude/handoff-root-<session id>`, which is how `handoff-checkpoint` finds it from the agent's own shell — the same hook sweeps its own week-old leavings there, and nothing else — and if the session's working directory ever leaves the repo it was launched in, the next prompt says so, once per episode.

In a gitlore-managed repository, handoff also offers to commit your memory:
when the memory submodule has uncommitted changes, it drafts a commit message
for them, asks you to approve (or edit) it, and commits via gitlore — so durable
learnings land instead of waiting for your next commit. When a commit is going
to land the change that memory documents — the one you are about to make, or a
later one — the memory rides *that* commit instead of committing separately
first, which saves a step, and it is written as if the change has already
happened, because it has.

## Staleness and cleanup

The artifact carries its own timestamp in its first heading. When the
task is finished, invoke the skill again with nothing outstanding —
the checkpoint sees an empty task and todo body and removes both
files instead of leaving stale ones, so the next session starts clean.

`handoff-task.md` and `handoff-todo.md` are staged automatically — the task file via the checkpoint's manifest, the todo file whenever the agent edits it directly — and ride your next commit; together they are the durable task trail. gitlore auto-memory is the complement for durable context that outlives tasks.

## Scope

| Concern | Handled by |
|---|---|
| Durable facts, preferences, feedback | auto-memory |
| Conversation transcript, resume | session JSONL + `claude -c` |
| Summarising the conversation | Claude Code `/compact`, Session Memory |
| **Compacting without losing the thread** | **this plugin** (`precompact` / `compact-continue`) |
| Code state | the repo |
| **Current task + open decisions across `/clear`** | **this plugin** |

See [`docs/design.md`](docs/design.md) for the research and analysis behind
this split.

### Choosing a handoff provider

This is the lightweight, local pre-`/clear` snapshot. A separate plugin,
`ddaa-handoff` (and its French `ddaa-passation`), provides a heavier
end-of-session *summary* delivered to Notion when available. They share
the same trigger phrases on purpose, so the same words work whichever you
pick — therefore **enable exactly one handoff provider per project**.
Enabling both reloads the collision this split was made to remove.

## Requirements

- Claude Code (depends on session JSONL format and plugin hooks)
- `python3` in `$PATH`
- `jq` in `$PATH`

## Files touched on your system

Per project, under `./.claude/`. `git add -f` runs on `handoff-task.md`
and `handoff-todo.md` so they appear staged for your next commit — the task
file via the checkpoint's manifest and a `PostToolUse(Bash)` hook, the todo
file via its own `PostToolUse(Write|Edit)` hook when the agent edits it
directly.

- `handoff-task.md` — checkpoint-written task + open decisions; staged for git automatically (track this).
- `handoff-todo.md` — agent-written remainder of an in-flight task list;
  staged for git automatically, same as the task file (track this).
- `autodrive` — transient file describing the transition to carry out:
  first line its state, second the kind (`rename`, `compact` or `clear`),
  then the lines to type. Written by whichever skill is arming one, or by
  the checkpoint for a rename, always in state `armed`. When the transition
  is armed at the end of your turn its state becomes `pending`, and it is
  consumed once the transition completes. At most one exists at a time — one
  prompt, one transition.
- `autodrive.failed` — written only when a line could not be delivered, and
  consumed when you are told about it at your next prompt.

Both `handoff-task.md` and `handoff-todo.md` are removed when the checkpoint
sees an empty body (the "finalize" case): invoke the skill again with
nothing outstanding and the next session starts clean. Nothing outside the
current project is modified.

## Uninstall

```
/plugin uninstall handoff@ddaanet
```

## Further reading

- [`docs/design.md`](docs/design.md) — research, SOTA analysis, decisions.
- [`docs/changelog.md`](docs/changelog.md) — one line per design change,
  linking the dated write-time record of each under `docs/changelog/`.
- [`plans/`](plans) — prospective content: specs, design proposals,
  implementation plans.
- [`CLAUDE.md`](CLAUDE.md) — agent instructions for working on the
  plugin itself.
- [`skills/handoff/SKILL.md`](skills/handoff/SKILL.md) — the skill
  that the agent follows when you ask for a handoff.
- [`skills/precompact/SKILL.md`](skills/precompact/SKILL.md) — the
  compact-boundary protocol; `compact-continue` runs it and then arms the
  transition.

## License

MIT
