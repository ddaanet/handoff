# Deciding makes zero tool calls, stated once (2026-08-11)

In a live session, an agent fully loaded the `handoff` skill body — including
Step 3's "First, decide all of the following without making any tool
calls" — and then ran `cat` on `.claude/handoff-task.md` and
`.claude/handoff-todo.md` before deciding what to write, despite already
holding that exact content in its own conversation context from earlier the
same session (injected via `SessionStart` and already acted on). The check
was not just against the stated rule; it was informationally redundant, and
its answer could only be staler than the conversation already in hand.

The agent's own diagnosis, when asked to reflect: a general "verify claims
against their source before acting" habit fired reflexively and overrode the
specific, freshly-read instruction, because that instruction read as
descriptive of how the decision happens rather than as a hard constraint on
the next action. It wasn't buried — it was the first line of the step just
read — the failure was in how it was weighted against a competing default,
not in finding it.

The rule had lived as two soft, differently-worded mentions, one in Step 1
and one in Step 3, each easy to skim past and neither stating why. It is now
one standing prohibition ahead of both steps: phrased as an imperative on
the action itself ("make zero tool calls before invoking
`handoff-checkpoint`") rather than a property of the decision, with the
reason inline (the checkpoint does this verification internally, and a
Read/Bash/Grep call here can only observe state that is stale by write
time). `## Anti-patterns` gains a matching entry naming the exact
rationalization — reading either file "to check" before deciding — since
anti-pattern entries are where a rationalized workaround gets pre-empted by
name.

Mechanically enforcing this (a hook blocking Read/Bash/Grep between skill
invocation and `handoff-checkpoint`) was not attempted here — this is a
wording fix, scoped to `skills/handoff/SKILL.md`. If wording alone proves
insufficient, a harness-level gate is the next escalation, not further
wording tweaks.
