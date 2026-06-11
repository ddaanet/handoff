# handoff — Design

Living document. Captures the research, analysis, and decisions behind
this plugin. Updated as the design evolves.

Last updated: 2026-06-09.

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
  not entirely composed of `tool_result` blocks. Last 5.
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
  the top-level log, isolated via `git log .claude/handoff-task.md`.

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

## References

- LangChain's context engineering framing:
  `https://www.langchain.com/blog/context-engineering-for-agents`
- Anthropic on long-horizon agents:
  `https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents`
- Context compaction comparison (Claude Code / Codex / OpenCode / Amp):
  `https://gist.github.com/badlogic/cd2ef65b0697c4dbe2d13fbecb0a0a5f`
- jdhodges handoff pattern:
  `https://www.jdhodges.com/blog/ai-session-handoffs-keep-context-across-conversations/`
