# handoff — Design

Living document. Captures the research, analysis, and decisions behind
this plugin. Updated as the design evolves.

Last updated: 2026-07-27.

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

> **Superseded 2026-07-17** (see *Task frame drops the transcript and file
> list*) on mechanism only: there is no `extract.py` and no session pointer.
> `load-handoff.sh` assembles the frame itself — a timestamp header and the
> inlined task file — and `PostToolUse` does nothing but `git add -f`. The
> decision this section records, agent-authored markdown over a JSON marker,
> is unchanged, and its three wins below survive the collapse.

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

- **Agent-authored template file + read-time assembly** (chosen):
  agent writes `./.claude/handoff-task.md` from a markdown template
  embedded in `SKILL.md`. A `PostToolUse(Write|Edit)` hook stages that
  file for commit (`git add -f`) whenever the resolved path is the
  project's task file. At the next session a
  `SessionStart(startup|clear)` hook (`load-handoff.sh`) reads the
  session pointer, runs `extract.py` to assemble the frame in memory —
  the inlined task content plus extracted files-touched and last user
  prompts — and injects it via `additionalContext` (see the Loading
  section below). The old `@`-ref load chain is no longer used.
  (Originally the frame was extracted to a generated `./.claude/handoff.md`
  file at write time; that file was later dropped for read-time assembly —
  see *Read-time assembly* below.)

The chosen pattern has three concrete wins over the JSON approach:

1. **No schema, no validator.** The template in `SKILL.md` is the
   single source of truth for format. The agent writes markdown in
   its own voice.
2. **Simpler extraction.** `extract.py` does not merge typed fields
   with extracted content — it writes a fixed header, the inlined
   task content, and the extracted sections. No JSON-to-markdown
   translation.
3. **Agent writes prose directly.** More natural than filling JSON
   fields, and the template makes the expected shape obvious.

### PostToolUse over Stop

A write-triggered `PostToolUse(Write|Edit)` hook, filtered on the
resolved path, was chosen over an earlier `Stop`-hook iteration that
used an mtime compare (regenerate when `handoff-task.md` is fresher
than its derived artifact). PostToolUse wins on:

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

(Under read-time assembly the PostToolUse hook no longer runs
`extract.py` — it only `git add -f`'s `handoff-task.md`. The
trigger-choice reasoning above still holds; an earlier "same-turn
confirmation" win, which depended on a generated `handoff.md`
materialising at write time, no longer applies. See *Read-time
assembly*.)

### Cleanup via activation hooks

Cleanup is mechanical and deterministic — exactly the kind of work
that belongs in the harness, not the agent. Two hooks together fire
the moment `handoff:handoff` activates, wipe any prior
`handoff-task.md` (and the `autorename` trigger, plus a legacy
`handoff.md` left by ≤0.4.x upgrades), and return. The skill body is
then loaded against a guaranteed-clean slate.

Two hooks are needed because the skill has two activation paths:

- **Agent invocation (`Skill` tool).** A `PreToolUse` hook matched
  on `Skill` and filtered to `tool_input.skill` being either
  `handoff` or `handoff:handoff` fires before the tool runs. The Skill
  tool accepts both the bare and qualified name as launches of the
  same skill, so the filter is an explicit two-form allowlist — a
  bare-name launch must reset just like the qualified one.
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
splitting the cleanup logic into prose obscures it.

The wipe+emit logic lives in `scripts/_wipe-emit.sh` and is shared
by both entry scripts; each entry script is a thin filter (match the
activation condition, extract `cwd`, `exec` the helper with its
`hookEventName`). Originally the two scripts each did their own
five-line `rm` — clearer than an indirection at that size. Once the
dual-channel `systemMessage` + `additionalContext` emission was added
the duplicated portion grew past twenty lines and the bit most
likely to keep evolving (the output envelope) was the duplicated
bit, so it was factored out.

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
`$PROJECT_ROOT/.claude/handoff-task.md`. Catches absolute-path
mistakes and multi-checkout confusion (agent operating in project A
but resolving a path that lands in project B). The denial message
tells the agent the expected path so it can retry.

> **Superseded 2026-06-09** (see *Per-worktree handoff root*): hooks anchor on
> `handoff_root` — the enclosing linked-worktree root, falling back to
> `CLAUDE_PROJECT_DIR` — rather than on `CLAUDE_PROJECT_DIR` directly, so a
> worktree session resolves to its own `.claude/`. The cwd-is-untrustworthy
> reasoning below stands unchanged; the hook count does not (eleven, as of
> the compaction driver).

**Project root resolution.** Hook payloads include a `cwd` field,
but `cwd` tracks the Bash tool's *persistent shell working directory*,
not the project's configured directory. If the shell cwd drifts — for
example, via `/add-dir` adding a second repo and a subsequent `cd` to
it — `cwd` in the payload points to the wrong project. The guard
therefore uses `CLAUDE_PROJECT_DIR` (the project's configured root,
stable for the lifetime of the session) with a fallback to payload
`cwd` for contexts where the env var is absent. All six hooks in the
plugin follow this pattern.

### Pre-activation file guards: gating *when*, not just *where*

The cross-project guard above enforces *where* `handoff-task.md` may
be written. It does not enforce *when*. Observed failure: the agent
co-opted `handoff-task.md` as a general scratch/todo file *before* the
`handoff:handoff` skill had ever run — the path-only guard let the
write through, the artifact was polluted with todo-list junk, and (in
the then-current design) the derived file regenerated from it.

The fix tightens `handoff-task.md` to its owner:

- `handoff-task.md` is **skill-owned input**. Agent Read / Write /
  Edit is refused *until `handoff:handoff` has activated this session*,
  then allowed (the skill writes it and may read it back). The
  cross-project realpath guard is retained.

(The original fix also locked down the generated `handoff.md` as
**fully hook-owned** — refused to the agent unconditionally — but that
file was removed by *Read-time assembly*, and its guards with it.)

Read-gating is via the `Read` *tool* only; a Bash `cat`/`grep`
bypasses it. That gap is accepted — the assembled handoff frame is
injected at SessionStart, so reads are pointless, and parsing arbitrary
Bash command strings to close the gap is fragile and out of scope.

The guard needs to know "has the skill activated this session?"
without stored state. Three mechanisms were weighed:

- **Env var set by the skill/script** — unavailable. Each `Bash` tool
  call gets a fresh shell (env does not persist across calls); hooks
  are separate processes with no channel that mutates the session
  environment. Off the table.
- **Marker file** — wipe hooks `touch` a flag at activation,
  SessionStart clears it. O(1), but it is a stored armed/disarmed
  latch — the exact state machine the PostToolUse-over-Stop decision
  congratulates itself on *not* having — with arm/disarm logic split
  across two scripts. Rejected.
- **Transcript scraping (chosen)** — the guard reads `transcript_path`
  and derives the answer from the session JSONL each call, the same
  way `extract.py` then derived files-touched. Stateless, session-scoped by
  construction, no new artifact, no lifecycle. The JSONL parse is paid
  only on the rare guarded call (the cheap basename check
  short-circuits first). A `handoff_activated()` helper in `_lib.sh`
  scans for either activation signal the wipe hooks already key on: a
  `Skill` tool_use with `skill` equal to `handoff` or `handoff:handoff`
  (same two-form allowlist as the wipe hook — the guard must recognise a
  bare-name launch as activation, or it would deny the writes the skill
  is about to make), or the `/handoff:handoff` slash invocation. The slash form's exact JSONL
  shape must be verified against a real transcript (it may be stored
  as a `<command-name>` wrapper, not literal text) — the `Skill`
  signal is the dependable one.

See
`docs/superpowers/specs/2026-05-23-pre-activation-file-guards-design.md`
for the full decision record.

### Missing-frame edge case

> **Superseded 2026-07-17** (see *Task frame drops the transcript and file
> list*): `extract.py` and the `handoff-error.log` sink are gone —
> `load-handoff.sh` assembles the frame inline, so the crash branch below has
> no subprocess to crash. The staging half and the no-task-file no-op stand,
> as does the closing stance.

The frame is assembled at read time, so there is no write-time extract
to miss. If `extract.py` crashes at `SessionStart` (logged to
`handoff-error.log`), `load-handoff.sh` emits a `systemMessage`
reporting the failure and exits 0 — startup is never blocked. A failed
`PostToolUse` staging only means `handoff-task.md` was not `git add`'d;
the file is still on disk and the pointer still resolves it, so loading
is unaffected. With no task file at all, `load-handoff.sh` is a silent
no-op.

Acceptable — the user will notice (no handoff content in context) and
re-run save. The plugin does not try to be clever here.

### Release infrastructure delegated to claude-plugin-dev

The `release` recipe and the `version-guard.sh` PreToolUse hook live
in the [claude-plugin-dev](https://github.com/ddaanet/claude-plugin-dev)
toolkit, vendored at `plugin-dev/` via `git subtree`. Rationale:

- The release dance — clean-tree check, version bump, tag, push, GH
  release, marketplace bump, plus a guard that refuses agent-driven
  version edits — is identical across every plugin we ship. Inlining
  it in each consumer's justfile produces drift; vendoring the source
  of truth keeps the contract one file.
- `git subtree --squash` rather than a submodule keeps the toolkit
  files visible in this repo's tree (no extra clone, no fragile
  pointer), and pinning to a tag (`v0.4.0`) makes upgrades explicit.
- The toolkit's `release.just` requires consumers to define two
  recipes: `precommit`, the per-plugin checks that must pass before
  every commit, and `prerelease`, the gate `release` actually depends
  on. handoff's `precommit` lints its own manifests, syntax-checks
  scripts, and runs the handoff-specific hook + pytest suites; its
  `prerelease` is exactly `precommit`. The indirection exists so a
  plugin whose release gate is wider than its commit gate — slow or
  paid checks — can widen `prerelease` without slowing every commit.
- The release recipe also bumps the plugin's entry in the sibling
  `claude-plugins` marketplace repo (path from `$MARKETPLACE_DIR`,
  set in `.envrc`) and pushes that repo. A tag without a marketplace
  bump is invisible to end-users, so the recipe treats both pushes as
  one atomic release.

Updates: `just update-plugin-dev vX.Y.Z` (recipe imported from
`release.just`).

## Loading: SessionStart hook, not an `@` reference

An earlier iteration shipped an `@.claude/handoff.md` reference in the
project `CLAUDE.md`, added by a `/handoff:setup` skill. The chain
worked — Claude Code resolved `@` refs at session start, recursively
up to 5 hops, pulling the artifact into context — but it produced one
structural failure mode:

> User enables the plugin, invokes `/handoff:handoff`, runs `/clear`,
> and the next session sees nothing because they never ran setup.

Loading via a `SessionStart(startup|clear)` hook eliminates that class
entirely. The plugin owns its own load path; no setup step, no
CLAUDE.md mutation, no detection-and-warn machinery. See
`docs/superpowers/specs/2026-05-19-sessionstart-hook-loading-design.md`
for the full decision record.

Matcher choice: `startup` covers fresh `claude` invocations; `clear`
covers in-session `/clear`. `resume` is omitted — the prior JSONL
already contains the injection from when this hook fired earlier.

> **Superseded 2026-07-17** (see *Task frame drops the transcript and file
> list*): the pointer read, the `extract.py` subprocess, and the
> `handoff-error.log` sink below are gone. `load-handoff.sh` now assembles
> the frame inline (a timestamp header plus the inlined task file). The
> hook-vs-`@`-ref thesis of this section is unchanged.

The hook (`scripts/load-handoff.sh`) gates on
`.claude/handoff-task.md`, reads the session pointer from
`.claude/handoff-session`, runs `extract.py` to assemble the frame in
memory (see *Read-time assembly*), and emits it via
`hookSpecificOutput.additionalContext`. It anchors on `handoff_root`
(the enclosing worktree root, else `CLAUDE_PROJECT_DIR` — see
Cross-project guard and *Per-worktree handoff root*). A curt
`systemMessage` ("handoff loaded — 3.2 KiB, saved 8m ago") is emitted
alongside for the user. Errors log to `handoff-error.log` and exit 0
so a hook failure never blocks session startup.

Token measurement: the `systemMessage` reports bytes, not API
tokens. Anthropic has not open-sourced an exact offline tokenizer for
Claude 3+; the `messages.count_tokens` API endpoint is the only
precise option, and adds a network round-trip, an API key
dependency, and a caching subsystem the plugin doesn't otherwise
need. Bytes answers "is this material enough to care?" just as well
for a 1–5 KiB artifact.

## Marker file schema

> **Never implemented.** The JSON-marker pattern lost to the agent-authored
> template file (*Activation*), so `handoff-pending.json` was never written
> and no hook reads it. Kept as history; see *Read-time assembly*, which
> notes the same.

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

> **Superseded 2026-06-05** (see *Read-time assembly*): `handoff.md` is no
> longer written. `extract.py` emits this same block on stdout and
> `load-handoff.sh` injects it directly; the structure below still describes
> the assembled text.
>
> **Superseded 2026-07-17** (see *Task frame drops the transcript and file
> list*): the `## Files touched`, `## Last user prompts`, and `Session:`
> lines below are gone. The frame is now a timestamp header plus the inlined
> task file only.

```markdown
# Handoff — <timestamp>

Session: `<session-id>`

<inlined contents of ./.claude/handoff-task.md, if it exists>

## Files touched
<extracted>

## Last user prompts

**after <anchor>**
> <verbatim user message>

...
```

Location: `./.claude/handoff.md`. Overwrites previous. History is in
git (if the user commits the file) or the session JSONL. The task
content is inlined verbatim at write time by `extract.py` (reading
`./.claude/handoff-task.md`); if the task file is missing the
inlined block is omitted entirely.

## Extraction rules

> **Superseded 2026-07-17** (see *Task frame drops the transcript and file
> list*): the transcript is no longer read at all — `extract.py` and its
> rules below are gone. The frame is a timestamp header plus the inlined
> task file.

- **Files touched**: `tool_use` with `name ∈ {Edit, Write}`.
  `Read/Grep/Glob` are investigation, not touch. Deduplicated, ordered by
  first appearance, tail-capped at 30. The control/scratch files the
  handoff and gitlore machinery write while *operating* — handoff's task
  file, the `autorename` trigger, the session pointer/error log, and
  gitlore's `gitlore-commit-msg` / `gitlore-merge-state` — are incidental
  to running the skills, not part of the active set the user is working
  on, so they are filtered out (`SKILL_ARTIFACT_SUFFIXES` in `extract.py`).
  gitlore's memory *content* (`memory/*.md`) is deliberately **not**
  filtered: those edits are real work and belong in the list.
- **User prompts**: entries with `type == "user"` where the content is
  not entirely composed of `tool_result` blocks. Last 5. `/compact`-injected
  summary entries (`isCompactSummary == true`) are excluded structurally,
  same as `isMeta`/`isSidechain`.
- **Anchor**: walk backwards from the user turn to the nearest assistant
  turn. Prefer `tool_use` name + target; fall back to the first line of
  assistant text, trimmed to 120 chars.

## Skill: handoff

Three skills ship with the plugin:

- **`/handoff:handoff`** — the main skill. Updates memory, then
  decides whether to write `handoff-task.md` from a template. The
  cleanup case is handled by the PreToolUse hook at activation; the
  load case is handled by the SessionStart hook at the next session.
  As part of its flow it also writes the session title to
  `.claude/autorename`.
- **`/handoff:autoname`** — handoff's rename-half on its own: decides a
  session title from the conversation and writes it to
  `.claude/autorename`, letting the shared `write-rename.sh` hook drive
  the `/rename`. No task snapshot, no memory write. For a `/btw` side
  conversation or any session worth a name while the main thread stays
  live. handoff does not route through it (no benefit, one extra turn);
  the two skills only share the `.claude/autorename` trigger file. See
  `docs/superpowers/specs/2026-06-07-autoname-skill-design.md`.
- **`/handoff:precompact`** — commit memory, drive `/compact`, resume. Shares
  `handoff-task.md` with the main skill and the same wipe-at-activation
  protocol; no rename. Added 2026-07-12, inverted to drive the compaction
  itself 2026-07-20 — see *Session compaction*, *precompact drives the
  compaction*, and *One task file, two transitions*.

The skill is named `handoff` (matching the plugin) so CLI completion
on `/handoff:` lands directly on the action, with no second namespace
hop.

An earlier `/handoff:setup` skill was removed in v0.3.0 — see the
Loading section above.

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

## Read-time assembly: pointer + bounded scrape (2026-06-05)

> **Superseded 2026-07-17** (see *Task frame drops the transcript and file
> list*): the scrape is gone, and with it the pointer chain this section
> built — `.claude/handoff-session`, `extract.py`, and `handoff-error.log`.
> `load-handoff.sh` now assembles the frame from the task file alone.

**Supersedes, below:** the *Activation: PostToolUse extraction* mechanism
(the `handoff.md` generation half — the `handoff-task.md` template authoring
is kept), the *Output schema* (`handoff.md`), the `handoff.md` branches of the
read/write guards, and the "reads `handoff.md`" mechanics of *Loading*. The
`handoff-task.md` authoring, the wipe-at-activation, the cross-project guard,
and the SessionStart `additionalContext` injection are unchanged. Earlier
strata that already conflicted with the chosen design (the `handoff-pending.json`
*Marker file schema*) were never implemented and remain history.

### The defect

`handoff.md` is a generated file derived from `handoff-task.md` and
`git add -f`'d next to it — a non-versioned twin shadowing a versionable
source. It also inlines the verbatim last-N user prompts, so committing it
would dump raw transcript into history. And `PostToolUse` extraction freezes
the scrape at handoff time, which is both an extra hook event and the wrong
moment — the tail of the transcript at that instant is the "save handoff"
request itself.

### The change

Eliminate `handoff.md`. The assembled frame becomes ephemeral — built in
memory at read time, never written.

- **Pointer, not artifact.** At handoff activation, persist the session's
  `transcript_path` to `.claude/handoff-session` (machine-local). Every hook
  payload already carries `transcript_path` (`write-extract.sh` reads it
  today).
- **Read-time assembly.** `load-handoff.sh` (SessionStart): if
  `handoff-task.md` exists, read the pointer, scrape that JSONL, assemble
  `handoff-task.md` + extracted sections, emit via `additionalContext`.
  Pointer's JSONL missing → inject the task file alone. No task file →
  silent no-op.
- **Bounded scrape.** The scrape cuts at the last handoff activation in the
  pointed JSONL, reusing the `handoff_activated()` signal: a `Skill` tool_use
  with `skill ∈ {handoff, handoff:handoff}` — the dependable marker; the
  `/handoff:handoff` slash shape is unverified (may be a `<command-name>`
  wrapper), per the guard section. Last-N user prompts are taken *before*
  the cut.

### Why bounded

Read-time scraping otherwise runs to `/clear`, capturing prompts typed
*after* the handoff. The effect is asymmetric: if those continue the task
they help only marginally (the task frame is already in `handoff-task.md`);
if they digress, the next session glues the task frame to unrelated recent
prompts and anaphora ("do it that way") resolves to the wrong thing —
silently. The cut excludes both the digression and the "save handoff"
request. The frozen-at-handoff semantics the old `handoff.md` got right are
preserved; only the generated file is dropped.

### Versioning `handoff-task.md`

Removing the scrape from the file leaves `handoff-task.md` as pure judgment
prose — clean to track. The handoff flow already writes durable learnings to
auto-memory in the same turn; under **gitlore** that write becomes a versioned
memory commit. So `handoff-task.md` (task frame, main repo) and the gitlore
memory commit (durable context) form a paired, in-history record — gitlore
supplies the surrounding context the task frame omits, which is what makes
versioning it worthwhile rather than noise.

- **Track** `handoff-task.md`. Keep a slim `PostToolUse(Write|Edit)` hook
  filtered to it doing only `git add -f handoff-task.md` (the staging
  survives from `write-extract.sh`; the `extract.py` regeneration does not).
- **Gitignore** the pointer (`handoff-session`) and `handoff-error.log` —
  machine-local.

### Consequences (accepted)

- **No self-contained committable artifact.** Not a loss — the durable
  context lives in gitlore's versioned memory, not in a baked scrape.
- **Non-atomic pairing.** gitlore commits memory at handoff time;
  `handoff-task.md` enters history at the user's next main-repo commit. The
  two halves drift; the user's commit is the sync point.
- **Wipe-churn.** Tracked + wiped-at-activation = delete/rewrite each
  handoff, deletion on finalize. A real trail of task transitions, churny in
  the top-level log, isolated via `git log .claude/handoff-task.md`. The wipe
  *stages* the deletion (`git add -f` on the now-absent path, in
  `_wipe-emit.sh`), mirroring the write-side `git add -f` in `write-stage.sh`
  — otherwise a finalized/transitioned task would linger as an unstaged
  removal and never ride the user's next commit. Suppressed no-op when the
  file was never tracked or the root isn't a git repo.

## Open questions

- Should `Read/Grep/Glob` paths be included as "scope of investigation"
  in the output? Resolved (2026-07-17): moot. The frame carries no file
  list of any kind — `## Files touched` went with the transcript scrape
  (*Task frame drops the transcript and file list*), and the harness's own
  `gitStatus` block supplies the working set at read time. Answering this
  now would mean reversing that decision, not settling this question.
- Should the output live inside `.claude/` (gitignored by convention) or
  outside the repo (e.g., `~/.claude/handoff/<project-hash>/`)? Resolved
  (2026-06-05): in-repo. `handoff-task.md` is **tracked** (a versioned task
  trail, paired with gitlore memory commits); the session pointer and error
  log are gitignored. See *Read-time assembly*.
- Should a slash command wrap the skill for explicit triggering?
  Resolved: the skill itself is invokable as `/handoff:handoff` (CLI
  completion on `/handoff:` lands on it directly), and the skill's
  description phrases cover the natural-language path. No separate
  command needed.

## Per-worktree handoff root (2026-06-09)

Worktree sessions must own their own `.claude/handoff-task.md`. Hooks now
anchor on `handoff_root` — the enclosing linked-worktree root derived from
on-disk `.git` linkage (`scripts/worktree_root.py`, ported from the cwd-safety
plugin), falling back to `CLAUDE_PROJECT_DIR` outside a worktree. Rejected:
trusting the raw `.cwd` field (drifts with `cd`/`/add-dir`) and recording the
root via `WorktreeCreate`/`CwdChanged` hooks (observational, no clean
per-worktree storage, fragile vs. the stateless `.git` walk). Full rationale:
`plans/2026-06-09-per-worktree-handoff-root-design.md`.

## gitlore-aware handoff (2026-06-12)

> **Superseded 2026-07-20** (see *precompact drives the compaction*): the
> commit path is no longer `commit-memory.sh` resolved through
> `git config gitlore.commitCommand`. The agent writes an approved message
> file plus a trigger file and gitlore's own `PostToolBatch` commits — all
> file writes, sidestepping the sandbox and the auto-mode classifier. The
> probe-as-PATH-shim rationale and the harness-over-agent split below are
> unchanged, and the directive text is now shared with the precompact probe.

The handoff skill runs a read-only probe (`bin/handoff-memory-probe` →
`scripts/memory-probe.sh`) at wrap-up; on a dirty gitlore-memory submodule
it emits a directive and the agent summarizes → gets approval → commits via
gitlore's `commit-memory.sh` (resolved through
`git config gitlore.commitCommand`). The probe is a PATH-shimmed script, not
a hook: the agent must act on the result, and verification showed
`CLAUDE_PLUGIN_ROOT` is absent from the agent's Bash while every plugin's
`bin/` is on PATH. The conditional lives entirely in the probe
(harness-over-agent); the skill body just runs it and follows its output.
gitlore's committer stays in its `scripts/` behind the self-healing
`commitCommand` key — moving it to `bin/` would reopen a shipped feature and
break the no-layout-coupling abstraction.

## Commit status excluded from the task frame (2026-06-24)

Observed defect: the routine wrap-up is `/handoff` then `/commit`. The
handoff writes `handoff-task.md` *before* the commit, so an agent that
narrates git bookkeeping ("work is uncommitted", "ready to commit") bakes
a fact that the very next routine action falsifies. The note then lands in
history (the `/commit` includes the staged task file) and is re-injected
stale at the next session's SessionStart.

This is not a sequencing problem to fix by reordering or amend-after-commit
— both fight the deliberate frozen-at-handoff semantics (*Read-time
assembly*) and, in the reorder case, the memory/commit dependency (gitlore
needs memory clean+committed, which the handoff turn handles). It is a
*content* problem: commit/push status is **reconstructable** state — the
Status row of the residual analysis already classifies it as "code +
`git status`" (lines 69–76), and the load-time frame injects files-touched.
The task frame's job is the irreducible residual (current task, open
decisions), never git bookkeeping.

Two alternatives were rejected:

- **Reorder + amend** (commit, regenerate handoff, amend the commit):
  reopens a closed artifact, amends across the memory/code boundary, and
  breaks the paired in-history record. Machinery to make a wrong fact
  accurate.
- **Live `git status` in `load-handoff.sh`**: would make staleness
  impossible by surfacing real state at read time, but adds a git
  shell-out to a pure assembler and contradicts the stance that git status
  is the user's to read (Open questions, line 610). Scope creep for a
  content problem.

The fix is template-level, not a remembered prohibition: the `## Current
task` guidance in `SKILL.md` now frames the field as task state and
explicitly excludes commit/push status, and the Anti-patterns list names
the failure. Because the template has no slot for commit status, this is
about as reliable as the template itself — the agent fills the shape, it is
not asked to recall a ban. The legitimate case ("changed X but not
committed because tests are red") is routed to `## Open decisions` as the
*why*, not written as a status line.

## Session compaction (2026-07-12)

Compaction intersects the plugin twice: as a *transcript feature* the
extractor must parse, and as a *candidate boundary* the plugin might
serve. The two get opposite answers.

### As a transcript feature: in scope — defect found and fixed

Verified against real transcripts (CC 2.0.74, 12 compactions;
corroborated by current docs): compaction appends to the **same JSONL,
same session ID** — a `type:"system", subtype:"compact_boundary"` entry
(`compactMetadata: {trigger: manual|auto, preTokens}`), the entry chain
re-rooted (`parentUuid: null` plus a `logicalParentUuid` back-pointer),
then the summary injected as a `type:"user"` entry flagged
`isCompactSummary: true` but **not** `isMeta`. That entry passed every
extractor filter (`isMeta`, `isSidechain`, `WRAPPER_PREFIXES` — its text
starts "This session is being continued...", not a known wrapper), so a
compaction inside the last-N window inlined a multi-KB stale summary
into the frame as a "user prompt" — violating the small-frame property
and the no-summarisation-layer non-goal at once. Fixed structurally,
same pattern as `isMeta` (see *Extraction rules*). Everything else
survives compaction unaided: the JSONL is append-only, so
`handoff_activated()` signals persist, the session pointer stays valid,
and no `/clear`-style bridge is needed.

### As a boundary: non-goal for the task frame

> **Superseded 2026-07-20** (see *One task file, two transitions*):
> `SessionStart(compact)` is matched — `load-compact.sh` injects the same
> `handoff_frame` there that `load-handoff.sh` injects at `startup|clear`.
> The staleness argument below held only while the frame could come from a
> *previous* boundary; precompact now writes the file in the turn that arms
> the compaction, so the frame is fresher than the summary rather than older
> than it. The verbatim-tail argument stands and is why the frame carries no
> transcript. Auto-compact remains out of scope.

`SessionStart` deliberately does not match the `compact` source (the
matcher exists and supports `additionalContext`). Two reasons:

- **The mechanical residual crosses natively.** Current compaction
  retains a verbatim tail of recent messages alongside the summary —
  this supersedes the April 2026 research row "Claude Code: summary
  only". Re-injecting extracted last-N prompts would duplicate context
  the harness already kept.
- **The judgment residual cannot be fresh.** The only frame available
  at compact time is the one from the last handoff — a *previous*
  boundary by definition. Re-injecting it glues a stale task statement
  onto a fresher summary: the commit-status defect (2026-06-24)
  generalised to the whole frame.

Auto-compact is fully out of scope: the harness picks the moment
mid-turn (no agent-judgment turn exists), and it cannot be disabled —
only its threshold moved (`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`; the
disable requests are open upstream issues). Community consensus since
the 2025 preservation improvements is to leave it on and rely on disk
durability for anything that must survive. That is this plugin's stance
too: durable context belongs in gitlore memory and the task frame, not
in machinery that fights the summariser.

### Manual compact as a wrap-up moment

> **Superseded 2026-07-20** on two of its three exclusions. precompact writes
> `handoff-task.md` (*One task file, two transitions*: with no durable channel,
> anything verbatim-critical gets crammed into the continuation prompt), and it
> runs the memory probe and commits through it (*precompact drives the
> compaction*: the commit can wait, but the conversation it summarises cannot).
> It also drives `/compact` and the continuation rather than telling the user to.
> The rename stays unbundled, and the `PreCompact`-hook rejection stands —
> the compaction is driven from `Stop`, still not from a hook that cannot run
> an agent turn.

A manual `/compact` is a user-chosen milestone — structurally like
`/clear` with lossy continuation instead of a reset. Testing handoff's
wrap-up bundle against it, the components transfer unevenly:

- **Task frame — no** (above; in-session continuity is the summary's
  job, and a frame written at compact time would arm the next
  `SessionStart(startup|clear)` injection with a frame the session
  continued past — stale by construction).
- **Memory flush — yes, the real loss channel.** Durable learnings that
  live only in conversation are paraphrased or dropped by the
  summariser; flushing them to gitlore memory *before* compacting
  preserves fidelity, and the machinery exists whole
  (`handoff-memory-probe` → summarize → approve → commit).
- **Rename — mild yes.** The pre-compact transcript is the richest
  naming input, and `/handoff:autoname` exists for exactly "a session
  worth a name while the main thread stays live".

Decision (revised same day): ship it as **`/handoff:precompact`** — a
thin skill packaging the memory-flush paragraph from the handoff
skill's Step 1, nothing else. No task file (the summary carries the
task), no rename bundled (use `/handoff:autoname` when wanted), and no
memory probe or commit: compaction threatens conversation state only —
disk survives it, so committing can ride any later commit. The probe's
commit dance is wrap-up logic, not pre-compact logic. A `PreCompact`
hook was rejected: hooks are mechanical and the flush is judgment —
`PreCompact(manual)` can annotate or block the compaction but cannot
run an agent turn.

Recorded as a requirement while here (previously implicit in the
skill's shape): in the non-gitlore case the handoff wrap-up completes
in a **single parallel tool-call turn** — the memory probe is
unconditional and batched with the task/autorename writes precisely so
no detection round-trip exists. Any rebalancing of the gitlore seam
(e.g. moving the probe into a gitlore-shipped command behind a
`command -v` lookup — considered and rejected 2026-07-12) must
preserve this.

### Plugin boundary: the handoff/gitlore separation stands

Pulling on the pre-compact thread ("without gitlore, the memory step is
one paragraph — the interesting logic is gitlore's") opened the plugin
boundary. Three restructurings were considered and rejected:

- **Merge handoff into gitlore** — distinct timescales (durable memory
  vs one-transition working state), distinct machinery (git plumbing vs
  session plumbing), asymmetric adoption cost (built-in auto-memory vs
  submodule + commit gates).
- **Move the probe into gitlore** behind a `command -v` lookup — adds
  the detection round-trip the current packaging exists to avoid (the
  single-turn FR above). Verified en route: every *enabled* plugin's
  `bin/` is on PATH, so cross-plugin bare-name invocation does work —
  the mechanism is fine, the extra call is not.
- **gitlore supersedes handoff** (gitlore ships its own
  handoff/precompact/autoname; handoff reduces to the non-gitlore
  case) — attractive as product tiers, but supersession means gitlore
  carries *all* of handoff's machinery (six hooks, `extract.py`, the
  rename watcher), vendored and kept in sync. Duplication cost exceeds
  the benefit.

Standing model: handoff owns the wrap-up including the unconditional
memory-flush step; the probe is its one gitlore seam, and it is a
**mandatory commit point** — a review-commit-push-resolve gate for
gitlore memory, not a suggestion (gitlore's advisory dirty-memory hook
is not a substitute). The skill body is gitlore-free: Step 3 says
"follow the probe's directive" and nothing else, so in the non-gitlore
case the agent never learns gitlore exists. The three-tier framing
survives as *positioning*, not plugin boundaries: ddaa-handoff
(claude.ai summaries), handoff (Claude Code native continuity), gitlore
(versioned memory on top).

### Durable progress files: the precompact probe (2026-07-17)

precompact was memory-only by construction — the task crosses
compaction in the summary. That default is right for a plain
conversation but wrong for a structured execution workflow that keeps a
**durable progress ledger** the summary cannot reproduce. superpowers
SDD is the motivating case: its `.superpowers/sdd/progress.md` records
`Task N: complete (commits <base>..<head>, review clean)` lines and
deferred Minor findings, and the SDD skill itself says to trust that
ledger over post-compaction recollection. A mid-run `/compact` with a
stale ledger is the most expensive SDD failure — completed tasks get
re-dispatched.

Two-part fix, matching the handoff/gitlore split:

- **General line in the skill body** (plugin-agnostic): if the session
  is mid-structured-task with a durable progress/state file, bring it
  current before compacting. Covers *unknown* workflows; carries no
  foreign vocabulary.
- **`handoff-precompact-probe`** (`scripts/precompact-probe.sh` + `bin/`
  shim): the probe owns the plugin-specific vocabulary, exactly as
  `handoff-memory-probe` owns gitlore's. Read-only, silent by default; a
  one-row registry resolves git root (`git rev-parse --show-toplevel`,
  mirroring SDD's own `sdd-workspace`) and, if
  `.superpowers/sdd/progress.md` exists, emits the calibrated flush
  directive. No git root → no known ledger → silent.

> **Corrected 2026-07-26** (see *An orphaned ledger hijacks the handoff*):
> that path is superpowers 6.1.1's. 6.2.0 moved the ledger into a per-plan
> workspace and the flat path became a stray the probe must ignore, so the
> registry now matches `.superpowers/sdd/*/progress.md` and requires SDD's
> identity first line. The existence-not-currency exclusion below stands —
> liveness is structural, currency is not.

Named after the *moment* (`precompact`), not the mechanism
(`progress`): the agent runs it opaquely and follows whatever it prints,
with no name-level hint that would prompt it to re-derive on its own —
the same opaqueness the gitlore Step-3 simplification bought.

Two deliberate exclusions. The probe detects a file's **existence**, not
its currency — only the agent, from conversation context, can judge
whether the ledger is current, so the directive says "bring it current"
rather than guessing at staleness. And precompact **still does not run
`handoff-memory-probe`**: committing memory stays wrap-up logic (the
commit rides the following session), so the probe is advisory — a nudge,
not the gitlore probe's mandatory commit gate.

> **Superseded 2026-07-20** (see *precompact drives the compaction*): the
> second exclusion is reversed. precompact composes the memory directive
> ahead of the ledger nudge and commits before the summariser runs, because
> the summary is written from the conversation and after compaction that
> conversation is a paraphrase. The existence-not-currency exclusion stands.

Calibrated against superpowers 6.1.1: the origin note's vocabulary
("in-flight fix-waves", "how to verify an incoming subagent report") was
dropped — those are live controller behaviors, not durable ledger state.
The ledger holds only completed-task lines and deferred Minor findings.

### Session JSONL schema reference

Transcript-parsing defects recur because the format is
reverse-engineered. Researched 2026-07-12: **no authoritative schema
exists** — the official sessions doc states the entry format is
internal to Claude Code and changes between versions. Best maintained
external references (both verified): claude-dev.tools' JSONL format doc
(field-level, practical) and `simonw/claude-code-transcripts` (actively
maintained parser — the code is the reference; its README documents
usage, not the format). The repo's existing stance stands, now with
backing: fixtures must mirror eyeballed real transcripts, and filtering
keys on structural flags (`isMeta`, `isSidechain`, `isCompactSummary`),
never content heuristics.

## Task frame drops the transcript and file list (2026-07-17)

The frame is a timestamp header plus the inlined agent-authored task
file. `load-handoff.sh` reads nothing but that file. The `## Files
touched` and `## Last user prompts` sections, the transcript scrape, and
the whole machinery that fed it are gone.

### The injection manufactured false continuity

A session where the injection actually fooled the reader: a fresh
session opened at ~61k context, clean tree, having done nothing; on the
first prompt ("Continue") it asserted "this session's context is spent
on the splits" — narrating a *prior* session's work as its own.

The injected transcript reproduced prior exchanges verbatim, in
conversational grammar (agent voice, user voice, turn after turn). That
does not read as *a report about a past session* — it reads as
**memory**. There is no felt boundary between "what I did" and "a
transcript of what someone did in my voice"; both arrive as the same
kind of text, so a faithful transcript overwrites the actual short
session with a fabricated long one, and "Continue" demands a
continuation the transcript stands ready to fake. The hazard scales
with volume: one exchange is a seam; five prior exchanges are a fake
episode you start living inside.

The two irreducible fields — **Current task** and **Open decisions** —
already live in the task file, in report register; that file is the
"where we left off" seam. The verbatim transcript was a second capture
of the same ground, in the one register that does the harm. A shorter
transcript is no cure: trimming changes length, not register. The only
genuinely-uncaptured content is the tail *after* the task-file write,
but the handoff skill writes that file as its last action, so the tail
is structurally empty — non-empty only when the user works past handoff
and `/clear`s without re-running it, a misuse whose honest signal is
"nothing pending — re-run handoff." So the transcript goes whole.

### The file list presented durable state as live

The honest capture boundary for files is the **commit**, not the
task-file write. Committed files are done, in git — yet
`## Files touched`, spanning the whole session, made them look
in-flight; in the origin session the listed files were committed and
the list contradicted the harness's own `Status: (clean)` in the same
context window.

The harness injects a live `gitStatus` block at SessionStart, current
as of the successor's start — after the prior session's commits landed.
It dominates any snapshot the handoff could embed and dissolves the
"which subset" question (touched-since-write? uncommitted? the
intersection drops files left dirty before the write). Deferring to it
is safe even where `gitStatus` is absent: the fallback is an empty
working set, which is the truth — "nothing is pending; you have not
done anything yet." The old list degraded that honest empty state into
committed files that kept whispering continuity.

### No session id, no pointer chain

Once nothing reads the transcript, the entire read-time pointer chain is
vestigial — its sole job was handing the prior transcript to
`extract.py`. It comes out in one pass: the `.claude/handoff-session`
pointer, the `extract.py` subprocess (frame assembly collapses into
`load-handoff.sh` — a `date` header and a `cat` of the task file), the
`handoff-error.log` sink that only `extract.py` could fill, and the
`Session: <id>` line the id fed. The header's timestamp already dates
the frame; the session id only ever named a transcript nothing opens.
`write-stage.sh` keeps just its `git add -f`. A design that proved
harmful is removed whole, not left as a scaffold guarding its return.

## Mid-turn TUI input: the taxonomy that shapes compaction driving (2026-07-19)

The precompact-drive spec (`docs/2026-07-18-precompact-drive-design.md`)
proposed typing `/compact` and a continuation prompt into the pane via a
watcher spawned at `PostToolUse` time. That rested on an assumption carried
over from `write-rename.sh`: input typed while the agent is busy is queued
inertly and runs afterward. Renaming had never falsified it because a
mistimed `/rename` fails harmlessly.

A spike against v2.1.215 (recorded in the spec) showed there is no single
"queued" behavior. Four distinct classes exist: TUI-local commands (`/focus`)
are intercepted immediately and never queue; harness actions (`/compact`) queue
and are interpreted at the next turn boundary; plugin commands (`/handoff`)
queue and drain as their own turn; and **plain prose is injected into the
running turn's next model call**.

That last row is the load-bearing one. The continuation prompt — prose — was
the input the original design treated as safe and the compaction command was
the one it feared. It is the other way round. Slash-shaped input can never
reach the model as prose (an unrecognized command drains to `Unknown command`),
so the compaction step cannot induce a hallucinated compaction; but prose typed
into a live turn contaminates the work the continuation is supposed to follow.

The fix is to stop inferring idleness from the screen. `Stop` and
`SessionStart(compact)` are harness-authoritative and fire exactly at the two
boundaries the design needs, so both typed lines are gated on hooks; the
watchers keep an idle-wait, demoted from safety mechanism to settle delay.
`Stop` not firing on Esc interrupt makes an interrupted turn fail safe without
extra machinery.

Two incidental results are worth keeping. `is_busy` must read only the visible
pane — a `capture-pane -S` history read matches a stale timer and reports busy
long after `Stop`. And the suspicion that queued input bypasses
`UserPromptSubmit` — which would have meant `prompt-pre-hook.sh` silently
missing a `/handoff:handoff` typed at a busy session — is false: `/compact`
skips the hook because it never becomes a prompt, while a queued `/handoff`
fires it with the raw command text. The wipe path is sound.

## precompact drives the compaction (2026-07-20)

> **Superseded 2026-07-25** (see *Commit awareness*) on one point: the
> file-trigger IPC described below — approved message file *plus* trigger file
> — is now the **without-commit** path, taken when the request does not imply a
> commit. When it does, the agent writes the message file alone and gitlore's
> parent pre-commit hook folds the memory commit into the source commit. The
> ordering constraint at the end of this section gains a sibling: under
> with-commit the commit lands before `autocompact` is written, for the same
> reason.

precompact used to end by telling the user to run `/compact`, and was
explicitly forbidden from committing memory. Both are now inverted: the skill
commits memory through the probe's directive and arms the compaction plus the
prompt that resumes the work.

The hands-off ending was never a considered position so much as caution about
acting on the user's session. But **continuation is intrinsic to compacting**:
`/compact` summarises the context so the session can keep going. Nobody
compacts before a `/clear` — that discards what compaction just paid to
summarise — or before stopping, where there is nothing to prepare for. If the
work is ending, the tool is `handoff` + `/clear`. So invoking precompact is
already the decision to compact and continue; stopping short of it just made
the operator type two things the skill had already worked out.

The ban on committing memory rested on "compaction loses conversation state,
never disk state" — true, and it does mean the commit *could* ride any later
commit. What it misses is that the memory summary is written from the
conversation, and after compaction that conversation is a paraphrase. The
commit can wait; the material it summarises cannot. Committing before the
summariser runs is the only point where the summary is written from the real
thing.

That reframes the interactive gate too. The flow now has exactly one pause —
gitlore's FR11 per-commit approval — and only when memory is dirty. The
compact directive and continuation prompt are quality details, not
authorizations: the operator watches them typed and can interrupt. A durable
git write is the different category, and it keeps its gate.

Two consequences worth stating. The memory commit moved to gitlore's
file-trigger IPC (write an approved message file, write a trigger file, let
gitlore's `PostToolBatch` commit) — all file writes, which sidesteps the
sandbox and auto-mode classifier that made an agent-issued
`commit-memory.sh -F -` fragile, and it orders memory-before-compaction for
free, since the trigger is consumed in the same batch while the compaction
watcher only arms at turn end. And the directive text is shared with
`handoff-memory-probe`, which had been left on the older Bash path when gitlore
built the file-trigger *for* handoff; one helper realigns both.

One ordering constraint fell out of the first live run. The design assumed the
FR11 approval and the `autocompact` write could land in one turn, but an
approval is a *user response*, so asking for it ends the turn — and `Stop` is
exactly where the compaction arms. An `autocompact` written alongside the
approval request would compact away the conversation the unapproved summary is
drawn from, defeating the reason memory commits first. So the write is deferred
to the turn after the directive resolves; the skill body states this as a
condition on step 3 rather than leaving it to be rediscovered.

## The settle gap and the submit signal (2026-07-20)

The first live run submitted line 1 and silently failed to submit line 2; the
operator pressed Enter without it being obvious that the watcher had not.

Two defects, stacked. An Enter sent immediately after a long literal
`send-keys -l` lands inside the TUI's paste window and is absorbed as a line
break. `compact-when-idle.sh` never hit this because its recognition readback
sits between the text and the Enter — the delay was load-bearing for
*submission*, not just verification, which was invisible until line 2 dropped
the readback on the reasoning that prose needs no recognition check. The gap is
now explicit in both watchers, with a comment saying it is not redundant.

The second defect is why it went unreported. Verification asked `is_typing`
whether the composer had drained, but `is_typing` inspects only the last `❯`
line, and an absorbed Enter leaves a multi-line composer whose last `❯` line is
empty. The watcher read that as drained, exited 0, and the run looked clean.
Verification now keys on `is_busy` — the turn actually started — which is
unambiguous on a multi-line composer. "Composer looks empty" was never evidence
of a submit; "the session went busy" is.

## One task file, two transitions (2026-07-20)

precompact used to be forbidden from writing `handoff-task.md`, on the grounds
that the task crosses compaction in the summary and in the continuation prompt.
The first live run showed what that costs. The prompt written for it was
`report whether the compaction driver worked end to end … then cut the release
covering 7f3c70c..a3b9cef` — a commit range and a three-part checklist, carried
in a single line typed into a composer. It survived only because the summariser
happened to keep it too. With no durable channel available, anything
verbatim-critical gets crammed into the one channel there is.

So the file is shared. Both skills write `.claude/handoff-task.md`, and
`load-compact.sh` injects it at `SessionStart(compact)` the same way
`load-handoff.sh` does at `startup|clear` — one `handoff_frame` helper, one
frame shape. The seam is clean: the task file carries content at whatever
fidelity the work demands, and the prompt carries only a handle to it plus the
next action.

Three consequences. `handoff_activated()` now treats either skill as an
activation signal, since the read and write guards gate on it and would
otherwise deny precompact's own write — the failure would have been a mid-flow
deny, not a silent one, but it blocks the flow either way. The frame header
changed from `# Handoff` to `# Task`, because the file no longer means "a
handoff happened" but "this is the current task state". And precompact now
leaves durable cross-session state where before it left none: the file persists
after the compaction and is re-injected at the next `startup|clear`. That is
correct under the new meaning rather than a leak — it is still the current task
state — but it is a real shift, and it is why the one-sentence mandate on
`## Current task` was relaxed at the same time. That mandate was already being
violated under work pressure, harmlessly and usefully; a rule that useful
practice routinely breaks is the wrong rule.

## A detached watcher's failure has to become a file (2026-07-20)

The second live run was clean end to end — Stop armed, `/compact` typed and
submitted, the frame injected, the continuation auto-submitted with no keystroke
from the operator. The task file's open decision said to add failure
observability only "if this run's submit looks marginal", and that framing was
wrong in kind. A clean run says nothing about whether a dirty one would be
noticed. The failing run is the one that needs the breadcrumb, and it is exactly
the run where nobody is watching.

The watchers are spawned detached, so their exit status is read by nothing. That
leaves three non-delivery paths. The line-2 Enter failing is invisible to the
agent but visible to the operator — the prose sits in the composer, which is
precisely how the first run's defect surfaced. The `is_typing` bail is the same
shape and used to `exit 0`, indistinguishable from success. The dangerous one is
the line-1 recognition abort: `compact-when-idle.sh` sends `C-u` and gives up,
wiping the composer, so the pane looks untouched, no compaction happens, and the
agent continues on a full context believing it armed one.

So the watchers write the reason to `.claude/autocompact.failed` and
`report-watcher-failure.sh` surfaces it on both channels at the next
`UserPromptSubmit`. `UserPromptSubmit` rather than `Stop`: a watcher runs *after*
the Stop that spawned it, so the next Stop is a full turn later, while the next
prompt is the first moment anything can act on the news.

The path comes from the spawning hook as `HANDOFF_FAIL_FILE` rather than being
derived in the watcher, keeping the layout knowledge in the hooks. And the report
fires only on paths a watcher observed itself — never inferred from a stale
`.pending`, which is legitimately present for the whole Stop → compaction window
and would produce false alarms on a race with the operator typing. A watcher
killed outright is therefore still silent; a false-positive-free signal is worth
more than that tail.

## precompact resets the task file too (2026-07-21)

Sharing the task file (*One task file, two transitions*) left the two skills
on different activation protocols: handoff wiped `handoff-task.md` at
activation, precompact did not. The stated reason — a wipe would drop state
precompact carries across the compaction — does not survive contact with the
flow. precompact authors the file from the conversation, not from the file's
prior contents; nothing on disk is input to it.

What the asymmetry actually bought was a stale file surviving into precompact's
turn, where the agent is asked to write the same path. That is the shape the
wipe exists to prevent — a prior frame available to be read, extended, or
partially edited instead of replaced, and, if the flow stalls at the FR11
approval gate, a previous session's frame left behind masquerading as the
current one. "The skill writes the whole file" is an agent-compliance
guarantee; the wipe is a harness guarantee, which is the one the plugin
prefers everywhere else.

So both activation matchers now cover both skills — `precompact` /
`handoff:precompact` in the `Skill`-tool allowlist, `/handoff:precompact` in
the slash-prefix check. One protocol for the one file: invoking either skill
is unconditionally a reset.

The cost is real but small and already priced in for handoff: an abandoned
precompact leaves no task file where a stale one used to sit. That is the
honest state (nothing pending) rather than a frame from a session that has
since moved on.

## Consolidation pass: shared preamble, detach, watcher scaffold (2026-07-20)

A four-angle review (reuse / simplification / efficiency / altitude) of the
whole plugin converged on the same three duplications, all the same species:
shared logic that predated the helper that should hold it. No behavior change.

- The five path-scoped hooks opened with the same six-line match sequence
  (field parse → basename filter → root resolution → resolve-pair → compare).
  That sequence is the cross-project security boundary, and five copies meant
  a missed edit is a silent guard bypass. Now `handoff_match_target()` in
  `_lib.sh`, with rc 2 ("basename matched, resolved elsewhere") kept distinct
  because `write-guard.sh` denies on it while everyone else passes through.
- The setsid-else-nohup detach block lived in triplicate; now
  `handoff_spawn_detached()`. The portability invariant (setsid Linux-only)
  is stated once.
- The three watchers each carried a byte-identical copy of the tunables,
  `snap()`, and the stable-idle poll loop — in the exact file family whose
  shared lib (`_rename-lib.sh`) existed to prevent that. The drift had
  already begun: the visible-pane-only invariant (2026-07-19 spike) was
  commented in two copies and absent from the third. `snap`, `wait_for_idle`
  and `submit_or_fail` now live in the lib; each watcher keeps only its
  distinct middle. The tunable overrides renamed `AUTONAME_*` →
  `HANDOFF_WATCHER_*` (they gate all three watchers, not the rename).

One efficiency fix rode along: `handoff_root()` short-circuits in bash when
the cwd is empty or already the project root — a strict subset of
`worktree_root.py`'s own trivial branches, so output is identical. Stop and
UserPromptSubmit call it every turn before their real gates, so the common
case no longer pays a python3 startup. The fast path must stay a subset of
the resolver's semantics; a bats test pins it by hiding python3.

Considered and declined: merging the three PostToolUse(Write|Edit) scripts
into one dispatcher to cut two jq spawns per write. It trades the
one-script-per-concern hook layout for a modest saving; the shared preamble
already removed the duplication that made it tempting.

## The submit signal, again: is_busy false-fails a queued continuation (2026-07-22)

The prior section (*The settle gap and the submit signal*) moved line-2
confirmation to `is_busy` — "the turn actually started" — over the
absorbed-Enter false-positive that `is_typing` had missed. The third live run
(session 8e39f620) showed the other edge. The continuation fires from
`SessionStart(compact)`, i.e. the instant compaction completes, while the
session is still settling. A submit landing there is **queued**, not run: the
transcript recorded it (`promptSource: "queued"`) at 20:54:06, but the queued
turn's spinner did not appear until 20:54:19 — thirteen seconds later, long
past the ~1.5s confirm window. `is_busy` times the spinner, so it reported "three
Enters did not submit it" for a line that had in fact arrived and would run.

The lesson across both runs: neither pane signal answers the actual question.
`is_typing` and `is_busy` both proxy *submission* through the pane — "composer
drained" or "turn running" — and each proxy has a state the other catches and it
misses. A queued submit is drained-and-accepted but not-yet-running; an absorbed
Enter is running-nothing and still-composing. No single pane predicate separates
all three of {absorbed, queued, fresh} because the pane conflates them.

The authoritative record is the transcript: an accepted prompt — queued or
fresh — is written as a `type:"user"` entry immediately, whereas an absorbed
Enter submits nothing and writes nothing. So line-2 confirmation now baselines
the count of genuine user-prompt entries containing the typed line, Enters, and
polls for that count to rise (`submit_confirmed_or_fail`,
`transcript_prompt_count` in `_rename-lib.sh`). `load-compact.sh` exports the
session `transcript_path` to the watcher; the entry appears within the confirm
window (it is synchronous with acceptance), so the poll needs no longer than
before.

Two guards against the obvious traps. The task text is typically strewn through
the transcript already — the compact summary, the injected frame, attachments —
so a raw substring grep would read as "submitted" before any Enter. The count
keys on the same structural flags as `handoff_activated` (`type:"user"`, not
`isMeta`/`isCompactSummary`/`isSidechain`), excluding every harness-injected
echo; and it is *baselined before the first Enter*, so a stale pre-compaction
copy of the same prompt cannot mask a real non-delivery. This is the JSONL
coupling the open decision flagged as the cost of the robust path — bounded to
one substring-in-decoded-content check over flag-filtered entries, the same
discipline the guards already carry, and preferred over the alternative
(downgrading the message to "could not confirm submission", which would have
retired the absorbed-Enter failure signal the previous run had just added).

Line 1 keeps `is_busy` (`submit_or_fail`). Its `/compact` is typed at `Stop`,
when the session is idle rather than settling, and submitting it starts the
compaction — a long, reliably-busy operation the spinner shows at once. Only the
continuation, firing into the post-compaction settle, is exposed to queueing.
(The premise in that last paragraph is false; superseded below, "The submit
signal, a third time".)

## A place for the todo list (2026-07-22)

`handoff-task.md` was being used to carry full task lists, and the same
items were tracked again in gitlore memory — so completing one task meant
editing several places, each with an approval-gated commit. The fix is not
another prohibition. It is a file: `.claude/handoff-todo.md`, holding the
**remainder** of an active task list and nothing else.

### Memory is not the place, and says so

The memory harness has no todo affordance at all, and the silence is
structural. A memory is "one file holding one fact"; a task list is N items
plus a mutating completion state. The four types are user / feedback /
project / reference, and the nearest — `project` — is scoped to work
"not derivable from the code or git history", which a todo list is: its done
half *is* git history. The exclusions name it twice over ("what the repo
already records… or what only matters to this conversation").

The cost of ignoring that is measurable in this repo. `project_precompact_drive.md`
took five commits in three days, four of which changed nothing but completion
state — shipped-but-unreleased → released → also v0.10.1 → fixed → shipped in
v0.10.2. A status line is a task list of one, and it has to be re-approved
every time the work moves.

### Reconstructable is two categories, not one

The residual analysis drops reconstructable state — git status, files
touched — and that rule, applied flatly, would drop a todo list too. It
shouldn't, because those are reconstructed by the **harness**:
deterministically, free, at read time, correct by construction. A todo list
after a compaction is reconstructed by the **model**, from a paraphrase, with
real error probability, and it fails silently by redoing finished work.

So the test splits. Reconstructable-by-machine → drop it, defer to the
harness. Reconstructable-only-by-inference → carry it, because the inference
is avoidable and its failure is invisible. The undone half of a task list is
a decomposition, which is judgment; it clears the residual bar that the done
half does not.

### The design names no tool

`TodoWrite` was superseded, not removed. In Claude Code 2.1.217 the string
survives 13 times with **no tool definition** — a bare constant, membership in
timeout/permission name-sets, the stale nag copy, and a scan that reads
historical `TodoWrite` entries out of old transcripts. The replacement is a
task-list family (`TaskCreate`/`TaskGet`/`TaskList`/`TaskUpdate`),
`shouldDefer: true`, gated `isEnabled(){ return bL() && !TZ() }` — where `bL()`
is on unless `CLAUDE_CODE_ENABLE_TASKS=false` and `TZ()` is a server-side
killswitch matching a `tengu_vellum_ash` gate list. Neither family was
reachable in the session where this was designed, with the flag unset locally
and nothing in any changelog.

An affordance that can vanish between two sessions on the same binary cannot
be a dependency. So the framing inverts: **the file is the ledger, whatever
tracker is live is a cache.** Nothing in the skill body names a tool; the
remainder is injected as content, and an agent with a tracker may load it in,
which is its own business. The cache may legitimately hold more than the
ledger — item identity, ordering, per-item history — because that surplus is
boundary-local, the same way the task file declines to duplicate `git status`.

Identity loss across the ledger is therefore not a cost to price. At `/clear`
nothing survives but files, so the remainder is an accurate account of what
crosses; at `/compact` the session continues and a tracker survives on its
own. The operator's choice of boundary is the lever.

### It rides the existing frame

The remainder is injected by `handoff_frame`, next to `## Current task`, at
both transitions. No new hook, no directive, no latch.

First-`UserPromptSubmit` was considered, to put a new user task ahead of the
injected list. The hazard is real and documented — *Task frame drops the
transcript and file list* records a session that read injected content as its
own memory. But the fix that worked there was **register and volume**, not
position: the report-register task file still injects at SessionStart and has
not reproduced it. A remainder list is on the safe side of that line. Position
is a weak lever anyway (recency argues the opposite way), explicit conditional
wording is the strong one, and "first UPS" needs the once-per-session latch
this design rejected as an armed/disarmed marker — on a per-turn hook.

### The skill body decides, not a probe

No script can see the agent's list: there is no todo store on disk here, and
scraping the transcript means keying on a tool name. Claude Code's own nag
does exactly that (`tool_use` with `name === "TodoWrite"`, plus an
`attachment.type === "todo_reminder"`) and now reads a dead string — the
maintenance trap the JSONL-coupling stance already warns about. The agent
knows its own list for free and cannot rot, and a probe branch would cost the
single-parallel-turn requirement a detection round-trip.

The probes keep the one question a script *can* answer: whether a foreign
workflow ledger exists. `probe_ledger_path` is the registry; when it hits,
`handoff-todo.md` stands down, so an SDD session tracks in one place. Both
probes compose it — a ledger outlives a `/clear` exactly as it outlives a
compaction — with precompact folding the suppression into its
bring-the-ledger-current nudge and handoff emitting it alone.

### Both skills write it; it is wiped; it is not tracked

> **Superseded 2026-07-23** (see *Overflow deserves the same persistence*): the
> gitignored-not-tracked paragraph below is reversed; `write-stage.sh`
> force-adds the todo file exactly as it does the task file. Everything else in
> this section stands.

precompact writes it too, and the reason is *not* the one that justifies its
task-file write. A tracker-backed list would survive compaction untouched —
but with no tracker the list is context-resident, and context is exactly what
compaction paraphrases. Writing before the summariser runs is what spares the
successor an inference it would make wrong and silently.

It is wiped at activation despite being input carried forward, because both
loaders put it back in front of the agent at SessionStart — so re-authoring is
from context, never from the file — and because without the wipe a finished
list lingers on disk forever, re-injecting done items as outstanding. The
alternative, an agent-issued delete when the list empties, is mechanical work
the harness should do.

It is **gitignored**, and that is the one place it departs from the task file.
`handoff-task.md` is tracked because it pairs with a gitlore memory commit as
an in-history record; a remainder has no such pairing, and a tracked checklist
would reintroduce the churn at boundary cadence. Snapshot versus ledger: the
task file is a frozen account of a moment worth versioning, the todo file is
working state carried forward.

The guards cover it on the same terms as the task file — the defect that
motivated them was the agent co-opting a handoff file as a scratch todo list
before any skill ran, which shipping a real todo file would reopen. Guarding a
second path made `handoff_match_target` variadic over (basename, rel) pairs:
the JSON parse is a jq spawn on the Write/Edit hot path, so N files must stay
one parse.

## A stale autocompact is one a later turn can see (2026-07-22)

`stop-compact.sh` checked only that `.claude/autocompact` existed. Its header
claimed the fail-safe direction for free: *"Stop does NOT fire on an Esc
interrupt, so an interrupted turn cannot arm the compaction."* True of the
interrupted turn, and silent about the file outliving it. The write is validated
by `PostToolUse` in the same turn, so the file is on disk the instant it is
written; if that turn then ends on an Esc, a crash, or a quit, nothing removes
it. The next turn that *does* end normally arms it — days later, in another
session, on unrelated work — driving a stale `/compact <old directive>` and a
stale continuation prompt into a conversation they were never written for. The
`mv` to `.pending` before spawning correctly blocks re-arming *within* a
session, which is likely what made the whole class feel handled.

The first shape considered was a session sidecar: stamp `session_id` at
validation time, refuse to arm on mismatch. It misses the most likely trigger.
Esc leaves the file in the *same* session, so the id matches and the next Stop
arms it anyway. Recency would patch that, but a timeout is a guess about how
long a turn may run, and a wrong guess silently drops a wanted compaction.

There is an exact discriminator, and it is structural. An autocompact is armed
at the `Stop` of the turn that writes it, and `Stop` renames it away. A turn
begins with a `UserPromptSubmit`. So a `UserPromptSubmit` that can *see* a bare
`autocompact` is by construction a turn later than the one that wrote it, and
that file never armed. No timestamp, no session id, no heuristic: the sweep
lives in `report-watcher-failure.sh`, which already owns compaction-state
reconciliation at prompt time, and reports on both channels like the watcher
failures it sits beside.

Two boundaries the sweep must respect. Prose injected into a still-running turn
fires `UserPromptSubmit` mid-turn, which could see a legitimately-written file;
that fails in the safe direction — the compaction is cancelled and said so,
rather than deferred into unrelated work. And the sweep must not touch
`.pending`: that file is legitimate for the whole `Stop` → compaction window,
and that window *contains* the watcher's own `/compact` submit, which is itself
a `UserPromptSubmit`. Clearing it on the evidence of a stale `autocompact` would
race `SessionStart(compact)` and kill a live continuation. Only a
watcher-observed failure clears `.pending`.

Adding `autocompact` to `_wipe-emit.sh`'s list was considered as a complement
and dropped. The wipe runs on skill re-activation, which the lingering-file
scenario does not involve, and a second mechanism covering a strict subset is
the vestigial half-measure the cleanup rule exists to prevent.

## The rename watcher joins the failure channel (2026-07-22)

The 2026-07-20 pass gave the compaction watchers a way to report a line that
never landed and left the rename watcher out, even while naming its `is_typing`
bail as the archetype of "the same shape [that] used to `exit 0`,
indistinguishable from success". It was written first and the retrofit did not
reach back to it: both its non-delivery paths — the composing-bail and three
failed verifies — ended in a bare exit nobody reads, `write-rename.sh` never
exported `HANDOFF_FAIL_FILE` for it to write to, and no consumer existed on the
rename side. So the hook announced "will rename to X once idle" and nothing ever
contradicted it.

The fix is entirely existing parts: `watcher_fail` at both exits,
`HANDOFF_FAIL_FILE` exported by `write-rename.sh` as `stop-compact.sh` already
does, and one more file for the consumer to read. The consumer did not need
duplicating — `report-compact-failure.sh` becomes `report-watcher-failure.sh`
and reads both files, joining whatever it finds into a single message. They
differ only in which line never landed; a second `UserPromptSubmit` hook doing
the same work under a different name would be the vestigial half-measure, not
the general one.

`.pending` stays coupled to the compaction failure alone. A rename says nothing
about a compaction, so clearing it on that evidence would race a live
`SessionStart(compact)` — the same reasoning as the stale-`autocompact` sweep.

## The submit signal, a third time: confirm the compaction, not the keystroke (2026-07-22)

"A long, reliably-busy operation the spinner shows at once" was an assumption,
never a measurement. A live run falsified it: `/compact` was typed, Entered,
submitted at 20:06:46, and the compaction ran for 103 seconds — and the watcher
still wrote *"typed but three Enters did not submit it"*, which surfaced at the
next prompt as a failure report for something that had plainly worked. Whatever
the TUI renders in the ~1.5 seconds after that keystroke, `is_busy` does not
match it.

The transcript trick that fixed line 2 does not transfer. The `/compact` entry
carries the submit timestamp but is *persisted* only once the command finishes —
in the session JSONL it sits physically after the compact summary written 103
seconds later. Polling it would fail for exactly as long as `is_busy` did.

So line 1 stops asking "did the keystroke land?" and asks "did the compaction
happen?" — which is the question the report is about, and which has an
authoritative answer already in the design: `SessionStart(compact)` consumes
`autocompact.pending`. `stop-compact.sh` hands the watcher that path in
`HANDOFF_PENDING_FILE`, exactly as it already hands over `HANDOFF_FAIL_FILE`,
and `submit_consumed_or_fail` waits for the file to go. No pane read, no JSONL
read, no guess about chrome.

Three consequences, all accepted deliberately. Confirmation now takes minutes,
so a genuine non-delivery is reported one `CONSUME_TIMEOUT` late — but it
surfaces at the next `UserPromptSubmit` either way, and a false alarm is worse
than a slow one. The short Enter-retry burst stays, since it is the only
recovery from an unregistered keystroke, and its per-iteration check is now
near-vacuous. And with no file to confirm against the watcher exits 0: an
unconfirmable submit is not a failed one.

The wider lesson is the one this signal has now taught three times. Every
pane-derived predicate is a guess about undocumented chrome, and each has failed
in a different way — a stale scrollback timer reading as busy, a queued submit
showing no spinner, and now a compaction showing none either. `is_typing` and
`is_unknown_command` survive because they gate *typing into* the composer, where
the pane is the only witness there is. Nothing that asks whether an action
*took effect* should look at the pane again.

## A directive must fit where in the turn it lands (2026-07-22)

The todo-file suppression shipped as one sentence composed by both probes:
*"do not write `.claude/handoff-todo.md`."* Correct for precompact, which runs
its probe at step 2 and writes at step 3. A no-op for handoff, which runs the
probe **in the same turn as the writes** — deliberately, so the snapshot costs
one round trip — and therefore always reads the directive after the file
exists. An agent following it exactly does nothing, and the session ends with
the two ledgers the suppression exists to prevent, the losing one gitignored
and re-injected next session as if it were current.

So `probe_todo_suppression` now names the cleanup — delete it if already
written — while `probe_sdd_directive` keeps the plain prohibition. The two
still agree on what exists, which is what `probe_ledger_path` is for; they
differ on the remedy, because a directive is only as good as its position in
the turn. The general form: shared prompt text composed into two flows is only
shared where the flows agree, and *when the agent reads it* is part of the
contract, not an implementation detail of the caller.

A skill that cross-references another skill's template has the same shape of
bug. precompact said to use "the template in the `handoff` skill" and stopped
there. A path existed — the harness loads a skill body with its own absolute
base directory, so `../handoff/SKILL.md` was always one Read away — but the
skill never named it, and the route that *looks* available from inside a turn
is invoking `handoff`, which is the wipe trigger, firing between precompact's
task-file write and its todo write and taking both with it. precompact now
states the section shapes inline for the common case, names the relative path
for the full rules, and forbids the invocation explicitly. Naming the safe
route is the load-bearing half: a prohibition with no alternative just moves
the guess.

Both fixes are the same lesson at two scales. Guidance is not a statement of
fact to be checked for truth; it is read at a particular moment by a reader
with particular reach, and it is correct only if it works from there.

## Overflow deserves the same persistence (2026-07-23)

`handoff-todo.md` is force-added by `write-stage.sh` like the task file, and
its deletion staged by the wipe like the task file's. The one property that
distinguished the two files is gone.

The todo file exists because task lists were being crammed into
`handoff-task.md`. That split was hygiene — two shapes of content, two
templates, two sections of one frame — and persistence quietly followed the
file rather than the content. Overflow from a tracked artifact is still that
artifact's content.

Neither reason given for the exception survives being stated against the flow.
The pairing argument — the task file earns history by sitting next to a gitlore
memory commit — is about a *moment*: one skill invocation writes both files and
commits the memory. Both halves share the pairing or neither does. The churn
argument imported a cost from where it was measured: the five-commit status
line was expensive because gitlore's per-commit approval gate charged for every
move. In the main repo the todo file changes only when a skill rewrites it,
which is exactly when the task file changes, and that churn was already priced
and accepted (*Read-time assembly*, "Wipe-churn").

The positive case is the trail's completeness. `## Current task` and
`## Remaining` are two sections of one snapshot; tracking one and discarding
the other puts half a frame in history — and the discarded half is the one
naming work not yet done, which is what a reader of the trail is looking for.
Nor is the file a mutating ledger in the sense that argued against versioning
it: it is rewritten whole at a boundary and holds the open set at that instant.
It is a snapshot with a different subject.

There is a durability point too, smaller but real. At `/clear` the remainder is
the only copy of the decomposition that crosses. Untracked, it is one
`git clean` — or one clone, one machine — from gone, with nothing to recover it
from.

Unchanged: the file still holds **open items only**. History records the list
narrowing; the file never carries completion state, which is the rule that
keeps a done item from re-injecting as outstanding.

Mechanically this is one call site each. `handoff_match_target` is already
variadic, so `write-stage.sh` covers both files in the one jq parse the
Write/Edit hot path allows; `_wipe-emit.sh` collects the removed tracked paths
and stages them in a single `git add -f`. Both stay listed in `.gitignore`, so
only the hook adds them and an incidental `git add .` still cannot.

## Commit awareness (2026-07-25)

The routine wrap-up is `/handoff` then `/commit`. Handoff's memory step always
took gitlore's standalone path — write the approved summary *and* the trigger,
let `PostToolBatch` commit the submodule on the spot.

**This is not a history defect, and the first draft of this section said it
was.** The standalone commit is a commit in the *submodule*. The parent's
pre-commit hook stages the moved gitlink unconditionally
(`scripts/git-hooks/pre-commit:75-91`, whether or not the sync it just ran
moved anything), so the next parent commit records the source change and the
pointer bump together regardless of which path ran. Both paths end with one
parent commit and one memory commit, pointing at each other identically.
`feedback_bundle_memory_with_source` is about *parent* commits — one carrying
both, not two — and neither path violates it.

What the standalone path actually costs is a round trip. It needs two file
writes, and they are free only if the agent issues them in one tool batch.
Measured over every transcript that writes either IPC file, grouped by
assistant `message.id` (Claude Code splits one message across several JSONL
entries, so per-entry counting reads every write as unbatched): of 65 IPC
writes inside a handoff or precompact activation, 28 batched both files into
one message and 37 split them across two — 43% batched, 39% excluding
gitlore's own development sessions. A split costs one extra API round trip,
median 5.9 s (quartiles 4.9 / 5.9 / 8.6). So the second file is a wasted round
trip 57% of the time, and buys nothing the bundled path does not already give.

The mechanism already existed on gitlore's side. Its parent pre-commit hook
commits memory whenever it finds a fresh approved summary, and the trigger file
is the *only* thing that makes `PostToolBatch` commit standalone. So the whole
difference is one file: summary alone defers, summary plus trigger commits now.
Freshness is an mtime comparison against the newest file in the memory
worktree, which makes "write the summary last" a real constraint rather than
style — a memory edit after it stales the summary and aborts the parent commit.

Because the difference is one *filename*, withholding it is the mechanism. The
with-commit directive does not mention `.claude/gitlore-commit-memory`, nor the
idea of a trigger at all: its reader is a fresh agent in an arbitrary project,
with no memory of a previous session and no maintainer documentation, so that
path has no other source and the standalone commit is simply unreachable. The
approved design had it the other way — name the trigger, forbid it explicitly —
reasoning that an agent who knows the two-file protocol needs it forbidden
rather than omitted. Two things are wrong with that. The agent who knows it is
the rare case, and the prohibition hands the common case the one string it was
missing. And a prohibition is not free: it introduces the concept, and an
introduced concept gets reasoned about.

The same cut applies to everything else the directive was carrying. An earlier
draft explained the pre-commit hook, the gitlink staging, and gitlore's mtime
freshness rule. None of it is actionable — the agent's entire contribution is
to write one file — and mechanism a reader cannot act on does not sit inert: it
gets verified, narrated back to the user, and worked around.

The freshness rule is the interesting cut, because it *is* a real constraint. A
memory edit after the summary write aborts the parent commit. But it is an
ordering between the skill's own steps, and both skills finish memory before
they run the probe — so a directive saying "only after every memory edit is
final" reaches a reader who has already complied, and asks a question whose
only possible answer is narration. Nor does it move to a skill body: "once
approved" already places the summary write after the memory edits, and approval
is the end of a feedback loop rather than the start of one — the user may well
ask for a memory change there, which is what review is for. An intermediate
draft did state it as a skill-body rule ("memory is final at its memory step"),
which forbids the thing the gate exists to enable; if an edit does land after
the summary write, gitlore's abort says so at the point where that is
actionable. What is left in the directive is one act plus one clause
saying the commit that lands the change carries the memory, which exists only
so the absence
of a commit is not read as a failure worth recovering from. The load-bearing
test is the corresponding negative, mutation-checked.

A second, smaller defect rides along, and it is the reason this is a skill-body
concern and not only a probe branch. When a commit is part of the request, the
snapshot is written *before* it lands, so anything phrased as pending — a
memory body describing a change as proposed, a `handoff-todo.md` item saying
"commit the work" — is false the second the user commits, and gets re-injected
that way at the next session start. Only the memory half is new guidance.
Commit/push status in the task file was already an anti-pattern, and an
unconditional one; a mode-scoped restatement of it would imply the item is
acceptable under `without-commit`, so handoff's step 1 leaves that half to the
anti-pattern list and speaks only about memory bodies. precompact's step 1 kept
the `handoff-todo.md` form of it until the re-phrasing below took its condition
away; the anti-pattern now covers both files, and both step 1s say the same
thing.

**The agent supplies one fact; the code owns the branch.** Both probes take a
required positional argument, `with-commit` or `without-commit`, answering
*"is a commit going to carry this session's memory?"* — which is a fact about
the conversation and the tree, not something a script can see. Everything
downstream of that answer is
deterministic. Detecting it in the probe was rejected twice over: a transcript
scrape is the maintenance trap this design already refuses for the todo list,
and a slash-command name is not the question. Defaulting the argument was
rejected too: a default is the answer given by an agent that has not thought
about the question, and thinking about it is the entire contribution. The two
values are peers, validated by a shared `probe_require_mode` that sets a global
rather than printing — `exit 2` inside a command substitution ends only the
subshell, and the caller would sail on with an empty mode.

The question was first phrased as *does this request imply a commit?*, and
dogfooding broke that phrasing on the first divergent case: a precompact run
with no commit anywhere in the request, whose memory documented the very
implementation sitting uncommitted in the tree. That case has to answer
`with-commit` to route the memory correctly and `without-commit` to answer the
question as written, and the agent silently resolved it by routing and ignoring
the rest. The flag was carrying two conditions that coincide in both routine
cases — which files the probe names, keyed on whether a commit carries the
memory; and how the snapshot is tensed, keyed on whether that commit lands
before the snapshot is read again. Neither failure is expensive, and an earlier
version of this paragraph claimed routing was: answering `without-commit` when a
commit is coming costs the wasted round trip above, answering `with-commit` when
none is leaves memory uncommitted behind an approved summary until some later
commit collects it. The binary asks the routing question because that is the
half the probe branches on — the tense half needs no mode, since present-tense
truth is the standing rule whenever the change exists in the tree. It stays a
binary: a third value would branch identically in the probe and only rename a
shade of prose. The two rules that genuinely needed *this request* now carry that
condition themselves: precompact's commit-before-`autocompact` ordering states
it, and the `handoff-todo.md` half joined the anti-pattern that already held the
task-file half unconditionally.

Where each half of the guidance lives is forced by *when it is read*, the same
constraint as *A directive must fit where in the turn it lands* (2026-07-22).
handoff runs its probe in the same turn as the writes, so a directive about how
to write them arrives after they exist. The skill body is read before step 1.
So the memory branch — read at the moment it acts — stays in the probe, and the
decision plus the write-as-landed rules go in both skill bodies, where they are
read in time to change what gets written. Emitting the write-as-landed guidance
from the probe would have been correct for precompact and a no-op for handoff.

precompact carries one extra rule, and it is load-bearing: when the commit is
part of the request, it lands **before** `./.claude/autocompact` is written.
Arming the
compaction ends the turn at `Stop`, so an autocompact written first means the
compaction runs instead of the commit. Same shape as the existing "never in the
same turn as a question the directive requires", and stated as such.

Committing is not one of either skill's steps, and neither skill says so. An
earlier draft did — "this skill never commits" — plus anti-patterns against
defaulting the answer and against running git under `with-commit`. All three
came out. "handoff and commit" is the ordinary request in this mode, so a line
reading as *do not run git* refuses the thing that was asked for; and the two
anti-patterns described defects nobody had seen, in lists that otherwise record
ones that happened. The only ordering that matters is precompact's, and step 5
states it positively. gitlore's FR11 approval remains the flow's one gate.

The approved summary *is* the memory commit's message — gitlore feeds the file
to `git commit -F` verbatim, in the submodule and in each tier — so the
directive asks for the shape of one: a title line of at most 72 characters, a
blank line, then a body of one bullet per memory file. The earlier "1-3
sentences" produced a paragraph where git's conventions want a subject line, and
it landed in history that way. This is preamble text, shared by both modes and
both probes, and it also changes what the approval gate shows: the user reviews
the commit message itself rather than a prose gloss on it.

## An orphaned ledger hijacks the handoff (2026-07-26)

`probe_ledger_path` decided a workflow-owned ledger existed by testing one
path — `.superpowers/sdd/progress.md`. That was superpowers SDD's layout
through 6.1.1. As of 6.2.0 each plan owns a git-ignored **workspace**
directory, `.superpowers/sdd/<plan-basename>/progress.md`, and the skill
names the flat path explicitly as *another plan's progress, to be left in
place*. The one path the probe treated as authoritative is the one path SDD
treats as a stray — and nothing removes it: the lifecycle deletes a plan's
*workspace* when the final whole-branch review is clean, and a flat-path file
is in no workspace. The tree is git-ignored, so it never shows in
`git status` either. Only `git clean -fdx` reaches it.

Observed 2026-07-25 in `/Users/david/code/micro`, which carried a
hand-rolled `.superpowers/sdd/progress.md` headed `# ghmem — progress (C2
COMPLETE…)` from a plan that had landed the day before. A session running no
SDD at all — a read-only statistical calibration — had `handoff-todo.md`
suppressed by that file and was told to bring "the ledger" current. It
complied: unrelated findings appended to a ledger whose header claims a
different plan, and the todo file it had already written deleted.

**The harm is the suppression, not the nudge.** `handoff-todo.md` is the half
of the frame that survives a `/clear`; deferring to an abandoned ledger risks
losing the real remainder or believing a stale one — precisely the failure
the registry's own comment warns about ("two ledgers drift, and the stale one
gets believed"), inverted.

So the property to detect is **liveness, not presence**, and it takes three
things:

- **The current layout.** Match `.superpowers/sdd/*/progress.md`. The flat
  path stops counting entirely. Accepting it "for back-compatibility" would
  be honouring the bug, since the current skill guarantees such a file is
  somebody else's leftover.
- **SDD's identity first line**, `# SDD ledger — plan: ` (the em dash is
  literal in SDD's format). This is what separates a live ledger from a
  hand-rolled file that happens to sit in the right place, and it costs one
  `read`. A near-miss fails open — no ledger found means `handoff-todo.md`
  gets written, which is the safe direction.
- **A deterministic choice among several.** An abandoned run and a live one
  both leave a workspace. Most-recently-modified wins: it is the honest
  signal for the one in play, where glob order is only alphabetical. Equal
  mtimes fall back to glob order. Plan-scoping does not make the abandoned
  case impossible, so the tiebreak is mitigation, not a cure.

Checking that the *named plan file* still exists was considered as a fourth
signal and rejected as a gate: it false-negatives on a plan that landed and
was tidied away. Available as a tiebreak if the identity line alone proves
insufficient.

The registry stays the single source of layout truth, and now actually is
one: `probe_sdd_directive` had hardcoded the flat path in its directive text
rather than interpolating `probe_ledger_path`'s output — tolerable with one
fixed path, impossible with a glob. Both consumers interpolate.

The probe remains advisory and read-only. A stale workspace is another
workflow's file, never ours to delete or rewrite however abandoned it looks;
deleting the offending file in `micro` fixed one repo, and any repo with an
abandoned or pre-6.2.0 SDD run reproduces this. Dropping the suppression
altogether and always writing `handoff-todo.md` was also rejected — the
two-ledgers-drift rationale is sound, and the defect was in the detection,
not the policy.

## One channel, one writer (2026-07-27)

The wrap-up was five mechanisms sharing one act: an activation hook wiped the
prior files, the agent issued three Write calls, a `PreToolUse` guard vetted
each against a transcript-scraped activation predicate, a `PostToolUse` hook
staged each, and a separate Bash call ran the probe. Each piece was locally
sound. Together they encoded an assumption that does not hold — that a session
hands off once.

The wipe is where it shows. It fires on activation, and activation is not the
event it wants. Multiple compactions in a session are normal; repeated
`/handoff` invocations, slash or agent-driven, happen too. Every one destroys
`handoff-todo.md` before the agent has re-authored it. That file is the half of
the frame a `/clear` discards outright, and after a compaction the context it
would be re-authored from is a paraphrase. *precompact resets the task file
too* (2026-07-21) argued the reset was a harness guarantee where "the skill
writes the whole file" is only an agent-compliance guarantee. That reasoning
holds for the task file, which is authored fresh from the conversation every
time. It never held for the todo remainder, which is a ledger — and the two
were given one protocol because they shared one activation hook.

So the todo file stops being wiped and starts being edited. It is a scratch
list by design: the agent strikes finished items and adds new ones all session,
and the wrap-up folds in the final remainder rather than regenerating the
document from a paraphrase.

Removing the wipe exposes what it was silently paying for. The Write tool
refuses to overwrite a file it has not Read in the current conversation, and an
absent file is what let the skill Write both as fresh creates. The fix is not
to restore a deletion but to stop routing the write through the Write tool at
all. The skill assembles the whole wrap-up as JSON — the task frame, the todo
Write or Edit, the session title, the commit-awareness answer — and pipes it to
`handoff-checkpoint` on stdin. One call replaces a wipe, three writes and a
probe.

The payload uses the harness's own tool-call shape (`file_path` + `content`, or
`file_path` + `old_string`/`new_string`) rather than a bespoke one. It is
redundant — the checkpoint owns the paths — but it is the shape the agent emits
most reliably, and validating `file_path` strictly against
`$root/.claude/<name>` is where the cross-project guard lives for this path.
The cost is a new failure mode: multi-line markdown inside a JSON string is
`\n`-escaped, and a botched escape is a way the wrap-up can fail that a Write
call never had. That is what the schema validation is for, and why a violation
must name the field rather than merely exit non-zero — a silent drop lands at
exactly the moment nothing else carries the frame.

"Probe" no longer describes it. The two probes were read-only detectors; this
writes. One `handoff-checkpoint` replaces both, with the transition as a
payload field — the schema already forces a discriminator in, so two binaries
differing only by it were the duplication the channel makes redundant.

**What the checkpoint may not do.** It runs in the agent's sandboxed Bash,
where a `git add` can stage successfully yet fail to remove `.git/index.lock`,
and the failure surfaces on the *next* command as `Another git process seems to
be running`. The next command here is the routine one: the wrap-up is
`/handoff` then `/commit`. tmux is likewise unreachable, so writing
`.claude/autorename` from the checkpoint would leave the rename watcher
unspawned and the promise of a rename unkept. Both jobs stay in hook context,
reached the way this plugin already reaches them — a file the checkpoint leaves
behind and a hook consumes. `PostToolUse(Bash)` stages the manifest's paths and
spawns the watcher.

**Content, not activation, decides absence.** A file whose body is empty is
removed and the removal staged. `file present ⟹ content pending` becomes an
invariant two writers enforce, instead of an instruction the agent has to
remember. That was the wipe's real job, and it survives the wipe.

Deleting the activation hooks removes the last consumer of `handoff_activated`,
and with it the transcript scraping and its JSONL fixtures. The predicate was
always a proxy — "has a skill run?" standing in for "is this write legitimate?"
— and the channel answers the real question directly. `write-guard.sh` keeps
one file and one rule: `handoff-task.md` is written by the checkpoint or not at
all. `read-guard.sh` goes entirely; a scratch list the agent edits must be
readable, and gating reads of the task file alone protects nothing.
`write-stage.sh` narrows to the todo file, which is the one path the checkpoint
never sees.

## `{"content": null}` is a no-op, not "content supplied" (2026-07-27)

`checkpoint.sh` distinguishes Write-form-with-content from field-absent by key
presence (`field_has_key task content`), not by the key's value. That's right
for distinguishing Write from Edit on `todo`, but wrong for `content` itself:
an agent that sends `{"file_path": "…", "content": null}` — or bare
`{"content": null}` — meant "nothing to write here," the same as sending
`task: null`. Key-presence validation instead treated `content` as supplied,
so `jq -r '.task.content'` (or `.todo.content`) ran on a JSON `null` and
printed the literal four-character string `"null"`, which got written into
`handoff-task.md`/`handoff-todo.md` as corrupted body text — silently, since
this passed schema validation and even satisfied the `file_path`-required
check when `file_path` happened to be present too.

The fix: both `validate_task` and `validate_todo` short-circuit to a no-op
(`return 0`, action stays `none`) as soon as `content` is present and
`field_is_null` on it — before the `file_path`-required check, so `file_path`
is not required for what is, in effect, an absent field. `todo`'s
short-circuit only fires when `old_string`/`new_string` are also absent, so
it can't shadow a genuine Edit-form schema error. Both reuse the existing
`field_is_null` helper, which already accepts a dotted path
(`field_is_null task.content` → `.task.content == null`) — no new helper
needed. Relaxation applies to both fields for consistency, not just the one
where the bug was first noticed.

## References

- LangChain's context engineering framing:
  `https://www.langchain.com/blog/context-engineering-for-agents`
- Anthropic on long-horizon agents:
  `https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents`
- Context compaction comparison (Claude Code / Codex / OpenCode / Amp):
  `https://gist.github.com/badlogic/cd2ef65b0697c4dbe2d13fbecb0a0a5f`
- jdhodges handoff pattern:
  `https://www.jdhodges.com/blog/ai-session-handoffs-keep-context-across-conversations/`
- Session JSONL format, community-maintained reference:
  `https://claude-dev.tools/docs/jsonl-format`
- Maintained session-transcript parser (code as format reference):
  `https://github.com/simonw/claude-code-transcripts`
- Hooks reference (PreCompact matchers/output, SessionStart `compact`):
  `https://code.claude.com/docs/en/hooks`
