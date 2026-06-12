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

Then issue a single `Write` of that title as the sole line of
`./.claude/autorename`. That is the only tool call.

A `PostToolUse(Write|Edit)` hook picks the file up, renames the session
via tmux `send-keys` once the prompt goes idle, then deletes it. Outside
tmux the hook's `systemMessage` carries a `/rename <title>` line
instead — relay it in a fenced code block so the user can paste it.

## Anti-patterns

- Writing `handoff-task.md`, updating memory, or running any other tool.
  autoname is rename-only; for residual task state use the handoff skill.
- Taking a title from the user's words verbatim when the conversation
  implies a better one. Derive the title; do not transcribe the request.
- Any location other than `./.claude/autorename` — the hook reads this
  exact path.
