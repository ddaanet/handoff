# handoff — Design Notes

Condensed rationale. Full design doc lives at the plugin root
(`../../../DESIGN.md`).

## The residual

Structured-handoff SOTA (Amp handoff, jdhodges' CLAUDE.md +
HANDOVER.md pattern) captures seven fields: Goal, Status, Context,
Decisions, Avoid, Open questions, Next step.

Three are handled by auto-memory:

| Field | Handled by |
|---|---|
| Context (durable) | auto-memory (`MEMORY.md`) |
| Decisions (durable) | auto-memory (feedback files) |
| Avoid | auto-memory (feedback files) |

Three are derivable from state:

| Field | Derived from |
|---|---|
| Status | code + `git status` |
| Goal (if task-scoped) | last user prompts |
| Next step | current task + open decisions |

That leaves two fields only the agent can fill:

- **Current task** — a one-sentence pointer to what was in progress
- **Open decisions** — unmade choices still blocking progress

These are the irreducible residual. They live in `handoff-task.md`
(agent-authored from the template in `SKILL.md`). A
`PostToolUse(Write|Edit)` hook stages the file. Next session, a
`SessionStart(startup|clear)` hook assembles the frame in memory — a
timestamp header plus the inlined task content — and injects it into
context. No generated file, no `@`-ref or project-CLAUDE.md setup
required.

## Why no verbatim transcript or file list

The frame is the task file alone; the transcript is never read.
Reproducing prior exchanges verbatim
read as *memory* rather than as a report about a past session, and
manufactured false continuity — a fresh session narrating a prior
session's work as its own. The two irreducible fields already carry the
"where we left off" seam in report register, so the transcript was a
redundant second capture in the one register that does the harm. The
per-session file list is likewise dropped: the honest working set is
the harness's own `gitStatus` block at load time, current after the
prior session's commits landed. See the plugin-root DESIGN.md, "Task
frame drops the transcript and file list".

## Why markdown template, not JSON schema

An earlier iteration used a JSON marker (`current_task` +
`open_decisions`) that a `compose.py` script merged with extracted
content into the final markdown. It worked, but required:

- A JSON schema for the marker
- A PostToolUse validator hook to catch schema drift at write time
- A compose step that translated typed fields into markdown prose

Replaced by a markdown template in `SKILL.md`. The agent writes prose
directly in its own voice. No schema, no validator, no translation —
the extract script just inlines the task file's contents and appends
its sections below.

Trade-off: markdown is softer than JSON, but the template is fixed and
the skill's anti-patterns section guards against drift. The agent's
natural output quality is higher when writing prose than when filling
JSON fields.

## Why read-time assembly rather than a generated file

Inline extraction (skill body has the agent assemble the frame after
writing) puts mechanical work back on the agent. Skipping that.

An earlier iteration generated a `handoff.md` at write time and
committed it next to the task file — a non-versioned twin that also
baked the verbatim last-N prompts into git history, and froze the
scrape at handoff time (when the tail of the transcript is just the
"save handoff" request itself).

Instead the frame is assembled at *read* time. `SessionStart` reads the
task file and prepends a timestamp header. Nothing generated, nothing
committed but the agent-authored task file.

## File guards

`PreToolUse(Write|Edit)` and `PreToolUse(Read)` hooks keep
`handoff-task.md` inert outside the skill's control path.
`handoff-task.md` is skill-owned: reads and writes are denied until the
`handoff:handoff` skill has activated this session — detected
statelessly by scraping the transcript for the same activation signals
the wipe hooks key on (a `Skill` tool_use or a `/handoff:handoff` slash
command). The write-guard additionally denies `handoff-task.md` writes
whose `realpath` is not `$cwd/.claude/handoff-task.md`, catching
multi-checkout confusion and absolute-path mistakes. The hooks
themselves do plain filesystem I/O rather than agent tool calls, so
they are never intercepted by these guards.
