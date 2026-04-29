# handoff — Design

Living document. Captures the research, analysis, and decisions behind
this plugin. Updated as the design evolves.

Last updated: 2026-04-29.

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

## Activation: PostToolUse extraction, agent-authored template file

Three patterns were considered:

- **SessionEnd hook**: fires on session termination. Cleaner
  semantically (one event, one artifact) but wrong in practice — a
  user who exits intending to resume via `claude -c` would trigger a
  handoff they did not want. SessionEnd cannot distinguish "done for
  now" from "done forever".

- **JSON marker + compose**: agent writes a JSON marker with
  `current_task` and `open_decisions`, a hook composes markdown from
  the marker + extracted session data. Works, but requires a JSON
  schema, a write-time validator, and a compose step that translates
  typed fields back into markdown.

- **Agent-authored template file + PostToolUse extract** (chosen):
  agent writes `./.claude/handoff-task.md` from a markdown template
  embedded in `SKILL.md`. A `PostToolUse(Write|Edit)` hook runs
  `extract.py` whenever the resolved file path is the project's task
  file, producing `./.claude/handoff.md` — a short wrapper containing
  `@handoff-task.md` plus extracted files-touched and last user
  prompts. Project `CLAUDE.md` has `@.claude/handoff.md`, and Claude
  Code's `@` resolution recurses (up to 5 hops) so both files load at
  session start. Each `@` is resolved relative to the file that
  contains it: `@.claude/handoff.md` is relative to project-root
  `CLAUDE.md`, and `@handoff-task.md` inside `handoff.md` is relative
  to `.claude/`.

The chosen pattern has three concrete wins over the JSON approach:

1. **No schema, no validator.** The template in `SKILL.md` is the
   single source of truth for format. The agent writes markdown in
   its own voice.
2. **Simpler extraction.** `extract.py` does not merge typed fields
   with extracted content — it writes a fixed header, an `@` ref,
   and the extracted sections. No JSON-to-markdown translation.
3. **Agent writes prose directly.** More natural than filling JSON
   fields, and the template makes the expected shape obvious.

### PostToolUse over Stop

An earlier iteration used a `Stop` hook with an mtime compare
(regenerate when `handoff-task.md` is fresher than `handoff.md`).
Replaced with `PostToolUse(Write|Edit)` filtered on the resolved
path. PostToolUse wins on:

- **Same-turn confirmation.** Extraction happens immediately after
  the write, so the agent sees `handoff.md` exists and can mention
  the path in the very same response. With Stop, the artifact only
  materialises after the agent has already finished talking — the
  next session sees it, but the user gets no confirmation in the
  current turn.
- **Causal trigger.** The hook fires because the task file was
  written, not because the session happened to stop. No surprise
  rewrites on unrelated stops; no dependency on mtime resolution.
- **No state machine.** Drop the mtime compare and the
  "self-synchronising" rationale that came with it.

The Stop-time-completeness concern from the earlier design (some
JSONL entries flush late) is theoretical for this use case: user
prompts are flushed by the time the agent is acting, and the only
tool_use event that matters is the Write of the task file itself —
which is in the JSONL by the time PostToolUse fires.

### Cleanup via activation hooks

Cleanup is mechanical and deterministic — exactly the kind of work
that belongs in the harness, not the agent. Two hooks together fire
the moment `handoff:handoff` activates, wipe any prior
`handoff-task.md` and `handoff.md`, and return. The skill body is
then loaded against a guaranteed-clean slate.

Two hooks are needed because the skill has two activation paths:

- **Agent invocation (`Skill` tool).** A `PreToolUse` hook matched
  on `Skill` and filtered to `tool_input.skill == "handoff:handoff"`
  fires before the tool runs.
- **User invocation (`/handoff:handoff` slash command).** This path
  loads the skill body directly into context without going through
  the `Skill` tool, so `PreToolUse(Skill)` does not fire. A
  `UserPromptSubmit` hook covers it: every submitted prompt is
  passed to the script, which checks whether the `prompt` field
  starts with `/handoff:handoff` and runs the same wipe if so.
  `UserPromptSubmit` does not support the `matcher` field (silently
  ignored), so the filter lives in the script.

Effect on the protocol: invoking the skill is unconditionally a
reset, regardless of invocation path. If the agent decides there is
an active task, it writes a fresh `handoff-task.md`. If not, it
writes nothing — the wipe at activation already finalized the
session.

This was an explicit design decision *against* an in-skill `rm` step.
Skills should not have the agent doing mechanical work the harness
can do — agent compliance is a weaker guarantee than a hook, and
splitting the cleanup logic into prose obscures it. The hook scripts
are thin filters on top of one shared wipe — duplicated rather than
factored, since five lines of `rm` per script is clearer than an
indirection.

#### Two notification channels: user and agent

Each wipe-hook emits both a `systemMessage` (user-facing, shown in
the Claude Code UI/transcript) and a
`hookSpecificOutput.additionalContext` (agent-facing, injected into
the agent's input for that turn). The two channels are independent:
`systemMessage` does not reach the agent. Without
`additionalContext`, the agent has no signal that the wipe happened
and is tempted to verify with `ls`/`cat` — exactly the redundant
work the hook exists to avoid. The agent message is short and
factual ("handoff activation hook wiped prior handoff files (X, Y);
they are absent.") so it informs without instructing — consistent
with the deny-message convention elsewhere in the plugin.

### Cross-project guard via PreToolUse(Write|Edit)

Per-project scope is enforced at write time. A
`PreToolUse(Write|Edit)` hook denies any Write/Edit whose target
basename is `handoff-task.md` and whose `realpath` differs from
`$cwd/.claude/handoff-task.md`. Catches absolute-path mistakes and
multi-checkout confusion (agent operating in project A but resolving
a path that lands in project B). The denial message tells the agent
the expected path so it can retry.

### Missing-extract edge case

If the agent's Write of `handoff-task.md` somehow doesn't fire the
PostToolUse hook (hook timeout, extract.py crash logged to
`handoff-error.log`), `handoff.md` is missing. Next session,
`@.claude/handoff.md` resolves to nothing. The task file alone is not
loaded.

Acceptable — the user will notice (no handoff content in context) and
re-run save. The plugin does not try to be clever here.

### Release infrastructure delegated to claude-plugin-dev

The `release` recipe and the `version-guard.sh` PreToolUse hook live
in the [claude-plugin-dev](https://github.com/ddaanet/claude-plugin-dev)
toolkit, vendored at `plugin-dev/` via `git subtree`. Rationale:

- The release dance — clean-tree check, version bump, tag, push, GH
  release, plus a guard that refuses agent-driven version edits — is
  identical across every plugin we ship. Inlining it in each
  consumer's justfile produces drift; vendoring the source of truth
  keeps the contract one file.
- `git subtree --squash` rather than a submodule keeps the toolkit
  files visible in this repo's tree (no extra clone, no fragile
  pointer), and pinning to a tag (`v0.1.2`) makes upgrades explicit.
- The toolkit's `release.just` requires consumers to define a
  `precommit` recipe — the per-plugin checks that must pass before a
  release. handoff's `precommit` lints its own manifests, syntax-
  checks scripts, and runs the handoff-specific hook test suite.

Updates: `just update-plugin-dev vX.Y.Z` (recipe imported from
`release.just`).

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

## Skills: handoff and setup

Two skills ship with the plugin:

- **`/handoff:handoff`** — the main skill. Updates memory, then
  decides whether to write `handoff-task.md` from a template. The
  cleanup case is handled by the PreToolUse hook at activation.
- **`/handoff:setup`** — first-run helper. Adds the
  `@.claude/handoff.md` reference to the project's `CLAUDE.md`.
  Idempotent, append-only. Keeps setup to a single command per
  project; manual editing remains possible.

The split is intentional: `setup` is a once-per-project action with no
bearing on the runtime save/load flow, so it doesn't belong in the
main skill's protocol.

The skill is named `handoff` (matching the plugin) so CLI completion
on `/handoff:` lands directly on the action, with no second namespace
hop.

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
- Should a slash command wrap the skill for explicit triggering?
  Resolved: the skill itself is invokable as `/handoff:handoff` (CLI
  completion on `/handoff:` lands on it directly), and the skill's
  description phrases cover the natural-language path. No separate
  command needed.

## References

- LangChain's context engineering framing:
  `https://www.langchain.com/blog/context-engineering-for-agents`
- Anthropic on long-horizon agents:
  `https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents`
- Context compaction comparison (Claude Code / Codex / OpenCode / Amp):
  `https://gist.github.com/badlogic/cd2ef65b0697c4dbe2d13fbecb0a0a5f`
- jdhodges handoff pattern:
  `https://www.jdhodges.com/blog/ai-session-handoffs-keep-context-across-conversations/`
