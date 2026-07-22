# handoff — Design

Living document. Captures the research, analysis, and decisions behind
this plugin. Updated as the design evolves.

Last updated: 2026-07-22.

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
  way `extract.py` derives files-touched. Stateless, session-scoped by
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
  pointer), and pinning to a tag (`v0.2.0`) makes upgrades explicit.
- The toolkit's `release.just` requires consumers to define a
  `precommit` recipe — the per-plugin checks that must pass before a
  release. handoff's `precommit` lints its own manifests, syntax-
  checks scripts, and runs the handoff-specific hook test suite.
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

Two skills ship with the plugin:

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
  in the output? Current answer: no — keeps the artifact focused on
  modifications. Revisit if user feedback says otherwise.
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
`report-compact-failure.sh` surfaces it on both channels at the next
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
lives in `report-compact-failure.sh`, which already owns compaction-state
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
