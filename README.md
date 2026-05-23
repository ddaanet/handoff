# handoff

A pre-`/clear` task snapshot for Claude Code. Designed as a narrow
complement to Claude Code's auto-memory: memory holds durable facts
(preferences, feedback, project context); this plugin holds the
*ephemeral task frame* memory avoids — what you were doing right now,
what decisions are still open.

## Setup

Install the plugin:

```
/plugin marketplace add ddaanet/claude-plugins
/plugin install handoff@ddaanet
```

That's it. No per-project setup step. A `SessionStart(startup|clear)`
hook reads `./.claude/handoff.md` at session start and injects its
contents into the fresh agent's context.

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

A `PreToolUse(Skill)` hook wipes any prior handoff files the moment
the skill activates, so the slate is always clean — and tells the
agent so it doesn't redundantly verify. The agent then updates
auto-memory with any durable learnings, and either writes a short
task file or — if there's nothing outstanding — leaves the slate
clean. The instant the task file is written, a
`PostToolUse(Write|Edit)` hook produces `./.claude/handoff.md`
combining the task file with auto-extracted session data (last few
user prompts verbatim, files edited this session) — the agent sees
the result in the same turn. Guards prevent the agent from reading or writing `.claude/handoff.md`
and `.claude/handoff-task.md` outside the handoff flow — both files
are managed exclusively by the skill and its hooks. After `/clear` (or
in a fresh session), the `SessionStart` hook injects `handoff.md` into
the new agent's context automatically. Auto-memory restores independently.

## Staleness and cleanup

The artifact carries its own timestamp in its first heading. When the
task is finished, invoke the skill again with nothing outstanding —
the activation hook wipes prior files and the agent writes nothing
new, so the next session starts clean.

Commit the files to git if you want an archived trail. There is no
separate archive directory.

## Scope

| Concern | Handled by |
|---|---|
| Durable facts, preferences, feedback | auto-memory |
| Conversation transcript, resume | session JSONL + `claude -c` |
| In-session compaction | Claude Code `/compact`, Session Memory |
| Code state | the repo |
| **Current task + open decisions across `/clear`** | **this plugin** |

See [`DESIGN.md`](DESIGN.md) for the research and analysis behind this
split.

## Requirements

- Claude Code (depends on session JSONL format and plugin hooks)
- `python3` in `$PATH`
- `jq` in `$PATH`

## Files touched on your system

Per project, under `./.claude/`:

- `handoff-task.md` — agent-written task + open decisions.
- `handoff.md` — hook-generated, self-contained file with the inlined
  task content plus extracted session data (last user prompts, files
  edited).
- `handoff-error.log` — written only if extraction fails.

The two files are paired: invoke the skill again with nothing
outstanding and both get wiped at activation (the "finalize" case).
Nothing outside the current project is modified.

## Uninstall

```
/plugin uninstall handoff@ddaanet
```

Existing `handoff.md` files stay where they are.

## Further reading

- [`DESIGN.md`](DESIGN.md) — research, SOTA analysis, decisions.
- [`CLAUDE.md`](CLAUDE.md) — agent instructions for working on the
  plugin itself.
- [`skills/handoff/SKILL.md`](skills/handoff/SKILL.md) — the skill
  that the agent follows when you ask for a handoff.

## License

MIT
