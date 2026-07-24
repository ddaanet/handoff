# handoff

A task snapshot that survives a context reset in Claude Code — whether
that reset is a `/clear` or a `/compact`. Designed as a narrow
complement to Claude Code's auto-memory: memory holds durable facts
(preferences, feedback, project context); this plugin holds the
*ephemeral task frame* memory avoids — what you were doing right now,
what decisions are still open.

Three skills sit on that seam. `/handoff:handoff` snapshots the task
before a `/clear` and names the session on its way out.
`/handoff:precompact` drives an attended compact-and-continue, so a
session that has to compact keeps its thread instead of resuming from a
paraphrase. `/handoff:autoname` is the rename alone, for a session worth
a title while the main thread stays live. The first two write the same
file; a `SessionStart` hook injects it back, verbatim, into whatever
comes next.

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

Or invoke explicitly with `/handoff:handoff`.

To name the session *without* a handoff — a `/btw` side conversation, or
any session worth a title while the main thread stays live — invoke
`/handoff:autoname`. It derives a title from the conversation and renames
the session (via the same tmux `send-keys`-when-idle path as handoff, or
a `/rename` line to paste outside tmux); it writes no task file and
touches no memory.

## Compact and continue

`/handoff:precompact` is the other half: not a wrap-up, but a way to keep
going. Long sessions eventually have to compact, and compaction paraphrases
the conversation — anything that has to survive *exactly* should be on disk
first. So the skill captures durable learnings in auto-memory, commits them if
your repo is gitlore-managed, writes the task file, and then drives the
compaction for you: `/compact` is typed into the prompt once your turn ends,
and once it finishes, the task file is re-injected and a one-line continuation
prompt is submitted. You do not run `/compact` yourself, and you do not have
to type anything to resume.

Both skills write the same `.claude/handoff-task.md`. That is the durable side
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

Driving the prompt needs tmux; outside it, the two lines are printed for you to
paste. If a line fails to land — the pane was busy, you were mid-sentence, the
command was not recognized — the watcher records why, and you and the agent are
told at your next prompt rather than being left to wonder whether the
compaction happened.

Use `precompact` when the work continues and `handoff` when it ends. Compacting
right before `/clear` throws away what the compaction just paid for.

A `PreToolUse(Skill)` hook wipes any prior handoff files the moment the skill activates, so the slate is always clean — and tells the agent so it doesn't redundantly verify. The agent then updates auto-memory with any durable learnings, and in a single turn writes a short task snapshot (if anything is outstanding), the remaining todo items (if a task list is in flight), and a session title to `.claude/autorename`. A `PostToolUse(Write|Edit)` hook stages `handoff-task.md` and `handoff-todo.md` for commit. A second hook picks up `autorename` and renames the session via tmux `send-keys` once the prompt goes idle (or emits a `/rename` line to paste if not in tmux). Guards prevent the agent from reading or writing `.claude/handoff-task.md` or `.claude/handoff-todo.md` outside the handoff flow. After `/clear` (or in a fresh session), the `SessionStart` hook assembles and injects the handoff frame into the new agent's context automatically. Auto-memory restores independently.

In a gitlore-managed repository, handoff also offers to commit your memory:
when the memory submodule has uncommitted changes, it summarizes them, asks
you to approve (or edit) the summary, and commits via gitlore — so durable
learnings land instead of waiting for your next commit.

## Staleness and cleanup

The artifact carries its own timestamp in its first heading. When the
task is finished, invoke the skill again with nothing outstanding —
the activation hook wipes prior files and the agent writes nothing
new, so the next session starts clean.

`handoff-task.md` and `handoff-todo.md` are staged automatically by the PostToolUse hook and ride your next commit — together they are the durable task trail. gitlore auto-memory is the complement for durable context that outlives tasks.

## Scope

| Concern | Handled by |
|---|---|
| Durable facts, preferences, feedback | auto-memory |
| Conversation transcript, resume | session JSONL + `claude -c` |
| Summarising the conversation | Claude Code `/compact`, Session Memory |
| **Compacting without losing the thread** | **this plugin** (`precompact`) |
| Code state | the repo |
| **Current task + open decisions across `/clear`** | **this plugin** |

See [`DESIGN.md`](DESIGN.md) for the research and analysis behind this
split.

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

Per project, under `./.claude/`. The PostToolUse hook runs `git add -f`
on `handoff-task.md` and `handoff-todo.md` so they appear staged for your next
commit.

- `handoff-task.md` — agent-written task + open decisions; staged for git automatically (track this).
- `handoff-todo.md` — agent-written remainder of an in-flight task list;
  staged for git automatically, same as the task file (track this).
- `autorename` — transient trigger file; written by the agent with the
  session title, consumed and deleted immediately by the PostToolUse
  hook.
- `autocompact` — transient trigger file written by `precompact`: the
  `/compact` line and the continuation prompt. Renamed to
  `autocompact.pending` when the compaction is armed, and consumed once it
  completes.
- `autocompact.failed` — written only when a line could not be delivered,
  and consumed when you are told about it at your next prompt.

Both `handoff-task.md` and `handoff-todo.md` are wiped at activation (the "finalize" case): invoke the skill again with nothing outstanding and the next session starts clean. Nothing outside the current project is modified.

## Uninstall

```
/plugin uninstall handoff@ddaanet
```

## Further reading

- [`DESIGN.md`](DESIGN.md) — research, SOTA analysis, decisions.
- [`CLAUDE.md`](CLAUDE.md) — agent instructions for working on the
  plugin itself.
- [`skills/handoff/SKILL.md`](skills/handoff/SKILL.md) — the skill
  that the agent follows when you ask for a handoff.
- [`skills/precompact/SKILL.md`](skills/precompact/SKILL.md) — the
  compact-and-continue skill.

## License

MIT
