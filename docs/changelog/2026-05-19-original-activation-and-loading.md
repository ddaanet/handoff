# Original design: activation, loading, extraction (2026-05-19)

## The residual: what the artifact carries

> **Superseded 2026-07-17** (see [Task frame drops the transcript and file
> list](2026-07-17-task-frame-drops-transcript.md)) on two of the three
> categories: the file list defers to the harness's own `gitStatus` block,
> and the verbatim-prompt category was withdrawn whole. Superseded again
> 2026-07-22 (see [A place for the todo
> list](2026-07-22-a-place-for-the-todo-list.md)) on the reconstructibility
> claim, which conflated harness-deterministic with model-inferrable. Kept
> here because the argument *for* verbatim prompts is what a future reader
> would re-derive, and it is only answerable next to the refutation.

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

> **Superseded 2026-07-17** (see [Task frame drops the transcript and file
> list](2026-07-17-task-frame-drops-transcript.md)) on mechanism only: there
> is no `extract.py` and no session pointer. `load-handoff.sh` assembles the
> frame itself — a timestamp header and the inlined task file — and
> `PostToolUse` does nothing but `git add -f`. The decision this section
> records, agent-authored markdown over a JSON marker, is unchanged, and its
> three wins below survive the collapse.

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
  see [Read-time assembly](2026-06-05-read-time-assembly.md) below.)

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
materialising at write time, no longer applies. See [Read-time
assembly](2026-06-05-read-time-assembly.md).)

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

> **Superseded 2026-06-09** (see [Per-worktree handoff
> root](2026-06-09-per-worktree-handoff-root.md)): hooks anchor on
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

(The original fix also locked down the generated `handoff.md` as **fully
hook-owned** — refused to the agent unconditionally — but that file was
removed by [Read-time assembly](2026-06-05-read-time-assembly.md), and its
guards with it.)

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

> **Superseded 2026-07-17** (see [Task frame drops the transcript and file
> list](2026-07-17-task-frame-drops-transcript.md)): `extract.py` and the
> `handoff-error.log` sink are gone — `load-handoff.sh` assembles the frame
> inline, so the crash branch below has no subprocess to crash. The staging
> half and the no-task-file no-op stand, as does the closing stance.

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

> **Superseded 2026-07-17** (see [Task frame drops the transcript and file
> list](2026-07-17-task-frame-drops-transcript.md)): the pointer read, the
> `extract.py` subprocess, and the `handoff-error.log` sink below are gone.
> `load-handoff.sh` now assembles the frame inline (a timestamp header plus
> the inlined task file). The hook-vs-`@`-ref thesis of this section is
> unchanged.

The hook (`scripts/load-handoff.sh`) gates on `.claude/handoff-task.md`,
reads the session pointer from `.claude/handoff-session`, runs `extract.py`
to assemble the frame in memory (see [Read-time
assembly](2026-06-05-read-time-assembly.md)), and emits it via
`hookSpecificOutput.additionalContext`. It anchors on `handoff_root` (the
enclosing worktree root, else `CLAUDE_PROJECT_DIR` — see Cross-project guard
and [Per-worktree handoff root](2026-06-09-per-worktree-handoff-root.md)). A
curt `systemMessage` ("handoff loaded — 3.2 KiB, saved 8m ago") is emitted
alongside for the user. Errors log to `handoff-error.log` and exit 0 so a
hook failure never blocks session startup.

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
> and no hook reads it. Kept as history; see [Read-time
> assembly](2026-06-05-read-time-assembly.md), which notes the same.

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

> **Superseded 2026-06-05** (see
> [Read-time assembly](2026-06-05-read-time-assembly.md)): `handoff.md` is no
> longer written. `extract.py` emits this same block on stdout and
> `load-handoff.sh` injects it directly; the structure below still describes
> the assembled text.
>
> **Superseded 2026-07-17** (see [Task frame drops the transcript and file
> list](2026-07-17-task-frame-drops-transcript.md)): the `## Files touched`,
> `## Last user prompts`, and `Session:`
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

> **Superseded 2026-07-17** (see [Task frame drops the transcript and file
> list](2026-07-17-task-frame-drops-transcript.md)): the transcript is no
> longer read at all — `extract.py` and its
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
  itself 2026-07-20 — see
  [Session compaction](2026-07-12-session-compaction.md),
  [precompact drives the compaction](2026-07-20-precompact-drives-the-compaction.md),
  and [One task file, two transitions](2026-07-20-one-task-file-two-transitions.md).

The skill is named `handoff` (matching the plugin) so CLI completion
on `/handoff:` lands directly on the action, with no second namespace
hop.

An earlier `/handoff:setup` skill was removed in v0.3.0 — see the
Loading section above.

## Open questions

- Should `Read/Grep/Glob` paths be included as "scope of investigation"
  in the output? Resolved (2026-07-17): moot. The frame carries no file
  list of any kind — `## Files touched` went with the transcript scrape
  ([Task frame drops the transcript and file list](2026-07-17-task-frame-drops-transcript.md)),
  and the harness's own
  `gitStatus` block supplies the working set at read time. Answering this
  now would mean reversing that decision, not settling this question.
- Should the output live inside `.claude/` (gitignored by convention) or
  outside the repo (e.g., `~/.claude/handoff/<project-hash>/`)? Resolved
  (2026-06-05): in-repo. `handoff-task.md` is **tracked** (a versioned task
  trail, paired with gitlore memory commits); the session pointer and error
  log are gitignored. See [Read-time assembly](2026-06-05-read-time-assembly.md).
- Should a slash command wrap the skill for explicit triggering?
  Resolved: the skill itself is invokable as `/handoff:handoff` (CLI
  completion on `/handoff:` lands on it directly), and the skill's
  description phrases cover the natural-language path. No separate
  command needed.
