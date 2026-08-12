# Open decisions move from the task file to the todo file

`handoff-task.md` carried two sections: `## Current task` always, and
`## Open decisions` whenever any remained. `handoff-todo.md` carried one:
`## Remaining`. That split put open decisions in the checkpoint-only file
(FR3) — writable only through a `handoff-checkpoint` call — even though a
decision routinely resolves or changes shape mid-session, well before the
next `/handoff` or `/precompact`. The todo file is the scratch list the
agent edits directly all session (FR4) for exactly that reason; open
decisions needed the same home, not the task file's.

Moved `## Open decisions` into the todo file, ahead of `## Remaining` — the
same read order the frame already produced (task file first, todo file
after), so the assembled frame reads identically; only the file boundary
between "current task" and "still open" moves. `handoff-task.md` now holds
`## Current task` alone.

Nothing downstream needed to change. `handoff_frame()`
(`scripts/_lib.sh`) concatenates both files' raw content verbatim with no
heading-specific logic, and `checkpoint.py` validates only the JSON
envelope (FR2), never markdown structure — so this is a template-and-prose
change: `skills/handoff/SKILL.md` (task/todo templates, Step 3, the seam
section, two anti-pattern entries), `skills/precompact/SKILL.md` (Step 3),
`skills/handoff/references/design.md`, `docs/design.md`, and the new
`skills/pending/SKILL.md`.

Considered leaving the shape alone and only correcting the two stale lines
that prompted this — a TDD-ordering open decision settled as fine, and the
`micro` tier migration item marked done — at the next checkpoint. Rejected:
the request named a standing rule ("the task frame should be just the
current or next task"), not a one-off correction to this session's frame.
