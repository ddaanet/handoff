# save — Design Notes

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
(agent-authored from the template in `SKILL.md`). The Stop hook adds
the mechanical extras (files touched, last user prompts) into
`handoff.md`, which `@`-refs the task file.

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

## Why a Stop hook rather than inline extraction

The skill could have the agent run the extract script inline after
writing the task file (one turn, two tool calls). Reasonable.

The Stop hook is preferred because it runs *after* the agent's
confirmation message, so the JSONL is more complete at extraction
time. Inline extraction might miss the final assistant turn if the
JSONL is flushed asynchronously.

The mtime trigger (task file newer than output) makes the hook
self-synchronising — no marker file, no explicit signalling.
