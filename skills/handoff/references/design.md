# handoff — Design Notes

Condensed rationale. Full design doc is `../../../docs/design.md`; the
dated write-time record of each design change is in
`../../../docs/changelog/`.

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

These are the irreducible residual. **Current task** lives alone in
`handoff-task.md` — a snapshot of a moment, agent-authored from the
template in `SKILL.md` and written only by `handoff-checkpoint`, staged via
its manifest. **Open decisions** lives in `handoff-todo.md`, alongside the
**remainder** below: both are open questions the agent keeps revisiting
over a session, so both belong in the scratch list it edits directly all
session (FR4) rather than in the checkpoint-only snapshot — a decision
that resolves or changes shape mid-session is corrected there on the spot,
not carried stale to the next checkpoint. Next session, a
`SessionStart(startup|clear)` hook assembles the frame in memory — a
timestamp header plus the inlined task and todo content — and injects it
into context. No generated file, no `@`-ref or project-CLAUDE.md setup
required.

Both the remainder of a task list and an open decision look derivable —
and the *finished* half of the former is, from `git log`, so that half is
dropped. The open half of either is not: reconstructing it after a
compaction means the model inferring, from a paraphrase, which items are
still outstanding or which choice is still unmade, and that inference
fails silently, by redoing finished work or re-litigating a settled
decision. Reconstructable-by-harness (`git status`, files touched) is free
and correct; reconstructable-only-by-inference is neither. The undone half
of a task list, like an unmade decision, is judgment — not state.

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
prior session's commits landed. See
`../../../docs/changelog/2026-07-17-task-frame-drops-transcript.md`.

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

`handoff-task.md` is written only by `handoff-checkpoint` (FR3 of "One
channel, one writer", 2026-07-27): a `PreToolUse(Write|Edit)` guard denies
any direct agent Write/Edit to it, unconditionally. `handoff-todo.md` is a
scratch list by design (FR4) — the agent edits it freely all session, and a
`PostToolUse(Write|Edit)` hook stages each direct edit with `git add -f`,
removing the file (and staging the removal) when an edit leaves it with no
substantive content. Neither guard scrapes the transcript for an activation
signal any more: the checkpoint is the only legitimate writer of the task
file, full stop, so there is no "before/after activation" distinction left to
detect. The write-guard still denies a `handoff-task.md` write whose
`realpath` is not `$cwd/.claude/<file>`, catching multi-checkout confusion
and absolute-path mistakes.
