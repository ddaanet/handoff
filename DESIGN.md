# handoff — Design

Living document. Captures the research, analysis, and decisions behind
this plugin. Updated as the design evolves.

Last updated: 2026-04-20.

## Problem

When a Claude Code session grows long or a user wants to `/clear` mid-task,
some state is worth preserving for the successor agent. Existing solutions
either over-capture (full-transcript summaries that drift) or under-capture
(nothing at all, relying on the user to re-explain).

The goal here is to identify the *irreducible residual* — what state
actually needs crossing the `/clear` boundary given everything else the
Claude Code ecosystem already handles — and build the minimum machinery
for it.

## Research — SOTA for session handoff (April 2026)

Four dominant families observed in the wild:

### 1. In-session auto-compaction

Claude Code `/compact`, Codex CLI, OpenCode. LLM summarises the full
trajectory at a threshold (80–95%), fresh context resumes with the
summary. Differ only in what's kept alongside the summary.

- Claude Code: summary only
- Codex CLI: summary + recent ~20k tokens
- OpenCode: summary + pruned tool outputs, last ~40k tokens protected

All acknowledge cumulative accuracy loss across multiple compactions.

### 2. Manual structured handoff

Amp handoff, jdhodges' CLAUDE.md + HANDOVER.md pattern. User-directed,
explicit. Typical envelope:

```
Goal / Status / Context / Decisions made / What to avoid /
Open questions / Next step
```

Often paired with a durable `HANDOVER.md` that survives across sessions.
This is SOTA for *cross-session* continuity. The existing `/ddaa:handoff`
skill in the `ddaa` plugin targets this pattern (claude.ai-oriented).

### 3. Structured note-taking / memory tools

Anthropic memory tool beta, Cursor/ChatGPT memory, Cline/Copilot "memory
bank". Agent writes to files outside the context, reads them at session
start. Claude Code auto-memory is this family.

### 4. Sub-agent isolation

Parent delegates to sub-agents with a clean minimal-viable-context
envelope; sub-agents return 1–2k-token summaries. LangGraph supervisor
patterns, OpenAI Agents SDK handoffs.

LangChain's framing — **write / select / compress / isolate** — is the
cleanest mental model for judging a given design.

## Analysis — what is the residual after auto-memory + harness?

Memory + harness + training already supply:

| SOTA field | Handled by |
|---|---|
| Context (durable) | auto-memory |
| Decisions (durable) | auto-memory |
| What to avoid | auto-memory (feedback files) |
| Goal (meta-level) | auto-memory (project files) |
| Status | code + `git status` |
| Conversation arc | session JSONL (orthogonal, used via `claude -c`) |

What's reconstructible from state:

| Field | Reconstruction |
|---|---|
| Agent responses | re-derive from intent + code state |
| Tool results | re-run |
| Files touched | parseable from tool_use events in the JSONL |

What's irreducible:

- **current_task** — a one-sentence pointer to what was in progress
- **open_decisions** — unmade choices still blocking progress

Plus one category that is reconstructible but *worth preserving verbatim*:

- **last N user prompts** — the only unreconstructable conversational
  signal. Verbatim phrasing cues better continuation than paraphrase.
  Anaphoric ("do it that way") so must be paired with a thin anchor from
  the preceding agent turn.

Those three constitute the artifact this plugin produces. Everything else
on the SOTA list is already handled, or reconstructible from code / git /
memory.

## Decomposition

Two distinct jobs:

1. **Mechanical extraction** — parse session JSONL for last user prompts
   and files touched. Deterministic, scriptable, zero LLM cost, zero
   summarisation loss.

2. **Judgment** — name the current task, list open decisions. Requires
   the agent; cannot be scripted.

The decomposition gives a clean single-turn split: the agent writes a
small JSON with the judgment fields, a hook does the extraction and
composition. No read+write round-trip, no LLM-summarising full history,
no drift.

## Activation: Stop hook with mtime trigger, agent-authored template file

Three patterns were considered:

- **SessionEnd hook**: fires on session termination. Cleaner
  semantically (one event, one artifact) but wrong in practice — a
  user who exits intending to resume via `claude -c` would trigger a
  handoff they did not want. SessionEnd cannot distinguish "done for
  now" from "done forever".

- **JSON marker + compose**: agent writes a JSON marker with
  `current_task` and `open_decisions`, a Stop hook composes markdown
  from the marker + extracted session data. Works, but requires a JSON
  schema, a PostToolUse validator, and a compose step that translates
  typed fields back into markdown.

- **Agent-authored template file + Stop-hook extract** (chosen): agent
  writes `./.claude/handoff-task.md` from a markdown template embedded
  in `SKILL.md`. A Stop hook runs `extract.py`, which produces
  `./.claude/handoff.md` — a short wrapper containing
  `@handoff-task.md` plus extracted files-touched and last user
  prompts. Project `CLAUDE.md` has `@.claude/handoff.md`, and Claude
  Code's `@` resolution recurses (up to 5 hops) so both files load at
  session start. Each `@` is resolved relative to the file that
  contains it: `@.claude/handoff.md` is relative to project-root
  `CLAUDE.md`, and `@handoff-task.md` inside `handoff.md` is relative
  to `.claude/`.

The chosen pattern has three concrete wins over the JSON approach:

1. **No schema, no validator.** The template in `SKILL.md` is the
   single source of truth for format. The agent writes markdown in its
   own voice. No PostToolUse hook needed.
2. **Simpler extraction.** `extract.py` no longer merges typed fields
   with extracted content — it just writes a fixed header, an `@`
   ref, and the extracted sections. No JSON-to-markdown translation.
3. **Agent writes prose directly.** More natural than filling JSON
   fields, and the template makes the expected shape obvious.

The Stop hook uses an mtime comparison: if `handoff-task.md` is newer
than `handoff.md` (or `handoff.md` is missing), regenerate. Otherwise
no-op. Self-synchronising — no marker file needed.

### Cleanup via the "nothing to do" case

The skill has two outcomes:

- Active task → write `handoff-task.md`
- Nothing to hand off → remove both `handoff-task.md` and
  `handoff.md`

This gives `save handoff` a second useful semantic: "finalize, nothing
outstanding, clean up." Stale handoff files are the main UX failure
mode; folding cleanup into the save skill handles it deterministically
at the user-triggered moment.

### Missing-extract edge case

If the agent writes `handoff-task.md` but the Stop hook never fires
(e.g., the user quits before the next stop), `handoff.md` is missing.
Next session, `@.claude/handoff.md` resolves to nothing. The task file
alone is not loaded.

Acceptable — the user will notice (no handoff content in context) and
re-run save. The plugin does not try to be clever here.

## Loading: `@` reference in CLAUDE.md, not a SessionStart hook

An earlier iteration shipped a SessionStart hook that announced
`handoff.md` with its age. Removed in favour of the simpler pattern used
in the `edify` plugin: recommend users add `@.claude/handoff.md` to
their project `CLAUDE.md`. Claude Code resolves `@` references at
session start, so the fresh agent sees the handoff content directly in
its context — zero hook overhead, no race conditions, no notification
channel to maintain.

Missing files resolve silently to nothing, so the reference is safe to
leave in `CLAUDE.md` permanently.

Archival stays an agent-judgement call on read (timestamp in the
artifact's first heading makes staleness obvious). Each new save
overwrites `handoff.md`, so in the steady-state case archival is
unnecessary — the artifact naturally turns over.

## Marker file schema

```json
{
  "current_task": "string — one sentence",
  "open_decisions": ["string", "..."]
}
```

Fixed at two fields to resist bloat. If a future need arises, add via
version bump, not schema drift.

Location: `./.claude/handoff-pending.json` (project-root-relative). The
`cwd` from hook input resolves this path. Per-project scope by design —
handoffs are task-scoped, not user-scoped.

## Output schema

```markdown
# Handoff — <timestamp>

Session: `<session-id>`

## Current task
<from marker>

## Open decisions
<from marker>

## Files touched
<extracted>

## Last user prompts

**after <anchor>**
> <verbatim user message>

...
```

Location: `./.claude/handoff.md`. Overwrites previous. History is in
git (if the user commits the file) or the session JSONL.

## Extraction rules

- **Files touched**: `tool_use` with `name ∈ {Edit, Write}`.
  `Read/Grep/Glob` are investigation, not touch. Deduplicated, ordered by
  first appearance, tail-capped at 30.
- **User prompts**: entries with `type == "user"` where the content is
  not entirely composed of `tool_result` blocks. Last 5.
- **Anchor**: walk backwards from the user turn to the nearest assistant
  turn. Prefer `tool_use` name + target; fall back to the first line of
  assistant text, trimmed to 120 chars.

## Skills: save and setup

Two skills ship with the plugin:

- **`/handoff:save`** — the main skill. Updates memory, writes
  `handoff-task.md` from a template, or cleans up when there's
  nothing outstanding.
- **`/handoff:setup`** — first-run helper. Adds the
  `@.claude/handoff.md` reference to the project's `CLAUDE.md`.
  Idempotent, append-only. Keeps setup to a single command per
  project; manual editing remains possible.

The split is intentional: `setup` is a once-per-project action with no
bearing on the runtime save/load flow, so it doesn't belong in the
save skill's protocol.

## Relationship to `/ddaa:handoff`

`/ddaa:handoff` in the `ddaa` plugin is a claude.ai-oriented full-session
summariser (75–150 line markdown document intended for pasting into a new
web conversation). It is SOTA family #2, manual structured handoff.

This plugin is narrower: Claude Code-only, `/clear`-focused, mechanical
extraction + minimal judgment. Non-overlapping. Both can coexist.

## Non-goals

- **Summarising the conversation.** Claude Code already has
  `/compact` (manual and automatic-at-threshold) and Session Memory
  (background summaries surfaced in the transcript). The model is
  trained to handle compacted context. This plugin does not add a
  third summarisation layer — it captures only the two fields those
  mechanisms cannot supply (current task, open decisions).
- **Cross-session thread management.** Auto-memory persists durable
  state across sessions; `claude -c` continues a specific session.
  This plugin addresses the single `/clear` transition, not multi-day
  thread juggling.
- **Replacing `/ddaa:handoff`.** Different target (claude.ai vs
  Claude Code), different scope (full-session summary vs residual task
  frame). Non-overlapping.
- **Claude.ai portability.** The plugin depends on session JSONL,
  Claude Code hooks, and filesystem — all Claude Code-specific. A
  claude.ai variant would need an entirely different mechanism.

## Open questions

- Should `Read/Grep/Glob` paths be included as "scope of investigation"
  in the output? Current answer: no — keeps the artifact focused on
  modifications. Revisit if user feedback says otherwise.
- Should the output live inside `.claude/` (gitignored by convention) or
  outside the repo (e.g., `~/.claude/handoff/<project-hash>/`)? Current:
  in-repo, leave gitignore choice to the user.
- Should a slash command `/handoff:save` wrap the skill for explicit
  triggering? Currently relying on skill auto-trigger from description
  phrases. Add if it proves insufficient.

## References

- LangChain's context engineering framing:
  `https://www.langchain.com/blog/context-engineering-for-agents`
- Anthropic on long-horizon agents:
  `https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents`
- Context compaction comparison (Claude Code / Codex / OpenCode / Amp):
  `https://gist.github.com/badlogic/cd2ef65b0697c4dbe2d13fbecb0a0a5f`
- jdhodges handoff pattern:
  `https://www.jdhodges.com/blog/ai-session-handoffs-keep-context-across-conversations/`
