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
hook assembles the handoff frame in memory at session start — reading
`./.claude/handoff-task.md` and scraping the prior session transcript
— and injects the result into the fresh agent's context. No generated
file is involved.

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

A `PreToolUse(Skill)` hook wipes any prior handoff files the moment the skill activates, so the slate is always clean — and tells the agent so it doesn't redundantly verify. The hook also records the current session's transcript path to `.claude/handoff-session` so the next session knows which JSONL to scrape. The agent then updates auto-memory with any durable learnings, and in a single turn writes a short task snapshot (if anything is outstanding) and a session title to `.claude/autorename`. A `PostToolUse(Write|Edit)` hook stages `handoff-task.md` for commit. A second hook picks up `autorename` and renames the session via tmux `send-keys` once the prompt goes idle (or emits a `/rename` line to paste if not in tmux). Guards prevent the agent from reading or writing `.claude/handoff-task.md` outside the handoff flow. After `/clear` (or in a fresh session), the `SessionStart` hook assembles and injects the handoff frame into the new agent's context automatically. Auto-memory restores independently.

## Staleness and cleanup

The artifact carries its own timestamp in its first heading. When the
task is finished, invoke the skill again with nothing outstanding —
the activation hook wipes prior files and the agent writes nothing
new, so the next session starts clean.

`handoff-task.md` is staged automatically by the PostToolUse hook and rides your next commit — it is the durable task trail. The `.claude/handoff-session` pointer and `.claude/handoff-error.log` are machine-local; add them to `.gitignore`. A useful `.gitignore` snippet:
```
.claude/handoff-session
.claude/handoff-error.log
```
gitlore auto-memory is the complement for durable context that outlives tasks.

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

Per project, under `./.claude/`. The PostToolUse hook runs `git add -f`
on `handoff-task.md` so it appears staged for your next commit.

- `handoff-task.md` — agent-written task + open decisions; staged for git automatically (track this).
- `handoff-session` — machine-local pointer to the prior session JSONL; read at the next SessionStart to assemble the frame (gitignore this).
- `autorename` — transient trigger file; written by the agent with the
  session title, consumed and deleted immediately by the PostToolUse
  hook.
- `handoff-error.log` — written only if the SessionStart assembly fails (gitignore this).

`handoff-task.md` and the session pointer are wiped at activation (the "finalize" case): invoke the skill again with nothing outstanding and the next session starts clean. Nothing outside the current project is modified.

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

## License

MIT
