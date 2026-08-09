---
name: autoname
description: Set the Claude Code session title from the conversation — a rename only, with no task snapshot and no memory write. Suited to /btw side conversations and any session worth a name while the main thread stays live. Use when the user asks to "name this conversation", "name this chat", "name this session", "rename session", "rename this session", "title this session", or "autoname". For "save handoff", "before /clear", "wrap up", or "I'm done", use the handoff skill instead.
---

# autoname — Session Title Only

Name the current Claude Code session — nothing else. This is handoff's
rename-half on its own: no task snapshot, no memory write, no `/clear`.
Use it for a `/btw` side conversation, or any session worth a name while
the main thread stays live.

## Protocol

Decide a concise session title from the conversation. Make **no tool
calls** to decide it. Title rules: ≤ ~50 characters, Title Case, no
surrounding quotes, no trailing punctuation. The title is always
derived from the conversation — autoname takes no argument.

Then run `handoff-checkpoint` (Bash), piping the whole call as JSON on
stdin via a heredoc:

```
handoff-checkpoint <<'JSON'
{"skill": "autoname", "rename": "<session title>"}
JSON
```

Those two fields are the whole payload. Every other field the checkpoint
takes belongs to a boundary this skill is not — no task file, no memory,
no transition — and each is a schema error here rather than a silent
ignore. A non-zero exit names the offending field on stderr.

That is the only tool call. The checkpoint composes the transition file
and the hooks do the rest at the end of the turn: the session is renamed
once the prompt goes idle, and outside tmux the lines are emitted for the
user to paste instead.

## Anti-patterns

- Writing `handoff-task.md`, updating memory, or running any other tool.
  autoname is rename-only; for residual task state use the handoff skill.
- Taking a title from the user's words verbatim when the conversation
  implies a better one. Derive the title; do not transcribe the request.
- Writing `.claude/autodrive` directly. The checkpoint is its one writer,
  and a direct Write or Edit is denied.
