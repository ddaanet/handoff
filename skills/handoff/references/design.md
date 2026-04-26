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
`PostToolUse(Write|Edit)` hook adds the mechanical extras (files
touched, last user prompts) into `handoff.md`, which `@`-refs the
task file.

## Why user prompts verbatim instead of summarised

Last user prompts are the only unreconstructable conversational
signal:

- Agent responses re-derive from intent + code state
- Tool results re-run
- User intent leaves no trace elsewhere

Summaries lose the verbatim phrasing that often cues better
continuation than paraphrase. So the hook quotes the last N user
prompts directly, with only a thin anchor from the preceding agent
turn to resolve anaphora ("do it that way", "refactor that
function").

## Why markdown template, not JSON schema

An earlier iteration used a JSON marker (`current_task` +
`open_decisions`) that a `compose.py` script merged with extracted
content into the final markdown. It worked, but required:

- A JSON schema for the marker
- A PostToolUse validator hook to catch schema drift at write time
- A compose step that translated typed fields into markdown prose

Replaced by a markdown template in `SKILL.md`. The agent writes prose
directly in its own voice. No schema, no validator, no translation —
the extract script just appends its sections after an `@` ref to the
task file.

Trade-off: markdown is softer than JSON, but the template is fixed and
the skill's anti-patterns section guards against drift. The agent's
natural output quality is higher when writing prose than when filling
JSON fields.

## Why PostToolUse rather than Stop or inline extraction

Inline extraction (skill body has the agent run extract.py after
writing) puts mechanical work back on the agent. Skipping that.

A `Stop` hook with mtime compare works but ships extraction *after*
the agent's reply, so the user gets no same-turn confirmation that
`handoff.md` was generated. It also fires on every stop, regardless
of whether anything handoff-related happened.

`PostToolUse(Write|Edit)` filtered on the resolved file path is
causally tied to the actual write: extraction happens immediately
after `handoff-task.md` is created, the agent sees the result in the
same turn, and unrelated stops don't trigger anything.

## Cross-project guard

A `PreToolUse(Write|Edit)` hook denies writes whose target basename
is `handoff-task.md` but whose `realpath` is not
`$cwd/.claude/handoff-task.md`. Catches multi-checkout confusion and
absolute-path mistakes; the deny message points the agent at the
correct path.
