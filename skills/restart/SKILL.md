---
name: restart
description: Exit and relaunch this Claude Code process with --resume, so it picks up plugin, hook, MCP, or settings.json state that only resolves at startup — the conversation carries over in full, unlike /clear or /compact. Use when the user asks to "restart claude code", "restart the session", "relaunch claude", "restart to pick up the new hooks/plugin/settings", or a gitlore stale-plugin-root notice points here as the remedy.
---

# restart — Exit and Relaunch, Conversation Intact

Nothing running inside a live session can adopt an upgraded plugin, a
changed `hooks.json`, a new MCP server, or an edited `settings.json` — those
resolve once, at process startup. Exit and relaunch is the only remedy, and
`--resume` is what makes it free: the full conversation carries over, so
unlike `/clear` this costs no context at all.

## Protocol

Decide, from the request, whether a continuation prompt should be submitted
once the resumed session is up — `continue`, one line of prose, or `null`
when nothing needs to follow the resume (the common case: the user is
usually just watching for the relaunch to land, not handing off mid-task).
Make no tool calls to decide it.

Then run `handoff-checkpoint` (Bash), piping the whole call as JSON on
stdin via a heredoc:

```
handoff-checkpoint <<'JSON'
{"skill": "restart", "continue": <"one line of prose"|null>}
JSON
```

Those two fields are the whole payload. No `task`, no `todo`, no `rename`,
no `commit`, no `clear`/`compact` — every one of those belongs to a
boundary this skill is not, and each is a schema error here rather than a
silent ignore. The session id and the exact command line to replay
(argv[0] plus every flag the process was launched with) are filled in by
the hooks, not decided here — this call carries only what the conversation
itself determines.

That is the only tool call. The checkpoint composes the transition file and
the hooks do the rest at the end of the turn: `/exit`, then the resumed
process, then the continuation if one was given — each confirmed by a
harness event (`SessionEnd`, `SessionStart(resume)`, the transcript), never
by reading the pane. Outside tmux the lines are emitted for the user to
run instead.

## Anti-patterns

- Deciding the resume command's flags, or the session id, here. Neither is
  available to this skill — the hooks read them from the exiting process
  itself, at the moment it matters.
- Writing `handoff-task.md`, updating memory, or running any other tool.
  The conversation survives `--resume` whole; there is nothing to snapshot.
  For a boundary that does lose context, use the handoff or precompact
  skill instead.
- Treating a gitlore stale-plugin-root notice as license to restart
  unprompted. The detector names the remedy; the user asks for it.
- Writing `.claude/autodrive` directly. The checkpoint is its one writer,
  and a direct Write or Edit is denied.
