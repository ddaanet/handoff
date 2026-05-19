# SessionStart-hook loading — design

Status: design, not yet implemented.

Date: 2026-05-19.

## Problem

Today, handoff content reaches a fresh agent via an `@.claude/handoff.md`
reference that the user has to add to their project `CLAUDE.md` (one-time,
via `/handoff:setup`). The `@`-resolution path is elegant in isolation,
but it produces a structural failure mode:

> User enables the plugin, invokes `/handoff:handoff`, runs `/clear`, and
> the next session sees nothing — because they never ran `/handoff:setup`.

This failure is silent: the agent and the user both think handoff
"works." The artifact files exist on disk; they just never load.

The original DESIGN.md (lines 288–304) framed dropping a SessionStart
hook as a win on the grounds of "no hook overhead, no race conditions."
On re-examination, both arguments are thin:

- *Hook overhead* is a stat + read on session start. Negligible.
- *Race conditions* don't exist — the artifact is written in a prior
  session; the hook reads it in a later one. No concurrency.

Meanwhile, the cost of the `@`-ref path is structural: a whole user-facing
setup concept (`/handoff:setup`), a CLAUDE.md mutation the plugin owns,
and an entire failure mode whose mitigation we were about to discuss
(grep CLAUDE.md, warn the agent, nudge to re-run setup).

This spec inverts that earlier decision.

## Goals

- **Eliminate the "never ran setup" failure class.** Plugin owns its own
  load path.
- **No CLAUDE.md mutation by the plugin.** Drop `/handoff:setup`
  entirely.
- **Preserve same-turn confirmation on save.** PostToolUse extraction
  must still fire immediately when the task file is written.
- **Preserve mechanical extraction.** Files-touched and last-N user
  prompts continue to be hook-extracted from session JSONL.

## Non-goals

- Token measurement subsystem. The plugin reports artifact *bytes* on
  load, not API-measured tokens. (Considered and rejected: see
  "Token-counting decision" below.)
- Backwards compatibility with the `@`-ref path. Users who have
  `@.claude/handoff.md` in their CLAUDE.md after upgrade will see
  duplicate content until they remove it; release notes call this out.

## Architecture

### Loading: SessionStart hook

A new `SessionStart(startup|clear)` hook runs `scripts/load-handoff.sh`,
which:

1. Reads `cwd` from hook input JSON.
2. Resolves `$cwd/.claude/handoff.md`.
3. If the file exists and is non-empty:
   - Emit `hookSpecificOutput.additionalContext` with the file's
     contents (the handoff payload reaches the agent's input for the
     turn).
   - Emit `systemMessage` with a curt user-facing line:
     `handoff loaded — <size>, saved <relative-time>`
4. Otherwise emit nothing (silent no-op, exit 0).

Matcher rationale:

- **`startup`**: fresh `claude` invocation. The most common entry point
  after the user finished a previous session.
- **`clear`**: after `/clear` within the same session. The original
  raison d'être of the plugin.
- **`resume` (omitted)**: `claude -c` / `--resume` replays the prior
  JSONL into context. That JSONL already contains the previous
  injection from when this hook fired at startup. Re-injecting on
  resume would duplicate the content.

### Error policy

- Hook timeout is 5 s.
- If `load-handoff.sh` fails (parse error, jq missing, anything), it
  logs to `.claude/handoff-error.log` and exits 0, matching the
  established pattern in `write-extract.sh`. A failure must never
  prevent session startup.

### `systemMessage` format

```
handoff loaded — <size>, saved <relative-time>
```

- **`<size>`**: bytes of `handoff.md`, formatted as integer for < 1024
  ("840 B"), `KiB` with one decimal for ≥ 1024 ("3.2 KiB"), `MiB` if it
  ever applied (unlikely for this artifact).
- **`<relative-time>`**: file mtime against now. Single largest unit, no
  compound: `8m ago`, `3h ago`, `12d ago`. Below 60 s reports `just now`.
- Lowercase, em-dash, factual. No instructions, no actionable phrases
  (matches the `_wipe-emit.sh` style).

Examples:
```
handoff loaded — 840 B, saved just now
handoff loaded — 3.2 KiB, saved 8m ago
handoff loaded — 5.4 KiB, saved 12d ago
```

### Token-counting decision

`systemMessage` reports **bytes**, not API-measured tokens. A survey of
the ecosystem (cc-token, edify's `tokens.py`+`token_cache.py`, Anthropic's
own offline tokenizer, `claude-tokenizer` Rust crate) found:

- Anthropic has not open-sourced an exact offline tokenizer for Claude 3+.
  Offline tokenizers are approximations.
- The `messages.count_tokens` API endpoint is the only precise option,
  but it requires `ANTHROPIC_API_KEY`, a network round-trip, and caching
  to avoid burning RPM on every session start.
- Even the API endpoint returns an *estimate* per Anthropic's docs.

For an artifact in the 1–5 KiB range, "bytes" answers the user's actual
question ("is this material enough to care?") just as well as tokens,
with zero deps and zero scope creep into a token-counting subsystem.
The plugin's job is task-handoff, not token measurement.

### File structure

Two files on disk, one canonical artifact:

- **`./.claude/handoff-task.md`** (agent-authored). Unchanged write
  surface. The skill template still applies.
- **`./.claude/handoff.md`** (hook-authored). Same shape as today, with
  one change: where it used to contain the line `@handoff-task.md`,
  it now contains the **inlined contents** of `handoff-task.md`.

Inlining at write time (rather than concatenating at load time) means:

- `handoff.md` is the complete, self-contained artifact. `cat
  .claude/handoff.md` shows exactly what loads.
- `load-handoff.sh` reads one file. No internal `@` resolution.
- Same-turn confirmation is preserved: the agent saves the task file,
  the PostToolUse hook fires, `handoff.md` materialises in the same
  turn.

If `handoff-task.md` is missing at extract time, the inlined block is
omitted entirely (no placeholder text, no heading). The agent's
content already carries its own headings (`## Current task`, `## Open
decisions`), so there is no enclosing section header in `handoff.md`
to leave dangling. The surrounding extracted sections still have
value.

### What goes away

- **`/handoff:setup` skill**: entire `skills/setup/` directory removed.
  The skill exists only to add `@.claude/handoff.md` to `CLAUDE.md`, a
  job that no longer needs doing.
- **`@handoff-task.md`** marker line in `handoff.md`: replaced by
  inlined content.
- **The "user never ran setup" failure mode**: structurally impossible
  after this change.
- **The CLAUDE.md grep / setup-missing-warning** discussed in chat:
  never written.

### What stays

- Wipe-on-activation: `scripts/skill-pre-hook.sh`,
  `scripts/prompt-pre-hook.sh`, `scripts/_wipe-emit.sh`. Unchanged.
- Cross-project write guard: `scripts/write-guard.sh`. Unchanged.
- PostToolUse extract trigger: `scripts/write-extract.sh` →
  `scripts/extract.py`. Modified to inline rather than `@`-reference
  the task content.
- Agent-write/hook-extract split. The split exists because the two
  jobs have different authors and different content; removing
  `@`-resolution doesn't change that.

## Concrete changes

### Added

- `scripts/load-handoff.sh` — SessionStart entry script. Bash, ~30 lines.
  Reads cwd, checks `$cwd/.claude/handoff.md`, emits JSON with
  `additionalContext` + `systemMessage`. Errors log to
  `.claude/handoff-error.log`.

### Modified

- **`hooks/hooks.json`**:
  - Add `SessionStart` block with matcher `startup|clear`.
  - Update top-level `description` to mention the SessionStart load.
- **`scripts/extract.py`**:
  - Replace the literal `@handoff-task.md` line with inlined contents
    of `output_path.parent / "handoff-task.md"`.
  - If the task file is missing, omit the section (no placeholder).
- **`skills/handoff/SKILL.md`**:
  - Update the second paragraph to mention SessionStart loading.
  - The "No `#` heading" rule still applies (heading still provided by
    `handoff.md`). No protocol changes.
- **`skills/handoff/references/design.md`**: mirror DESIGN.md updates.
- **`DESIGN.md`**:
  - Rewrite the "Loading: `@` reference in CLAUDE.md, not a SessionStart
    hook" section to invert the conclusion. Reference this spec as the
    decision record.
  - Update "Output schema" — task content inlined.
  - Update "Skills: handoff and setup" — drop the setup half.
- **`CLAUDE.md`** (project root):
  - Layout: add `load-handoff.sh`; remove `skills/setup/SKILL.md`.
  - Hooks summary: mention SessionStart.

### Removed

- `skills/setup/` (entire directory).
- Any prose in DESIGN.md, CLAUDE.md, or `skills/handoff/references/`
  that walked users through `/handoff:setup` or the manual
  `@.claude/handoff.md` setup step.

### Untouched

- `scripts/skill-pre-hook.sh`, `prompt-pre-hook.sh`, `_wipe-emit.sh`,
  `write-guard.sh`, `write-extract.sh`.
- `plugin-dev/` vendored toolkit.
- `.envrc`, `justfile`, `.claude/settings.json`.

## Migration

Single breaking release: **v0.2.1 → v0.3.0**.

Release notes (CHANGELOG / GitHub release body):

> **Breaking**: handoff content now loads via a SessionStart hook
> instead of the `@.claude/handoff.md` reference. The `/handoff:setup`
> skill has been removed.
>
> **To migrate**: open your project's `./CLAUDE.md` and delete the
> `## Handoff` section that contains `@.claude/handoff.md`. Leaving it
> in place is harmless but causes the content to load twice (once via
> the hook, once via the `@`-ref).

No in-plugin migration code. No backward-compatibility shim. The hook
detects nothing about CLAUDE.md content — the only check is whether
`.claude/handoff.md` exists.

## Testing

All tests in this section are **automated bash scripts with
assertions** that run under `just precommit` and propagate exit codes
to CI. No agent-driven verification, no "run it and eyeball the
output." If a behaviour is worth testing, it gets an assertion in the
existing script — the marginal cost of automating a new case on top
of an already-automated harness is small.

- **`tests/hook-test.sh`** — add a SessionStart load scenario:
  - Fixture: write a small `.claude/handoff.md` with known size and
    mtime.
  - Run `load-handoff.sh` with synthetic SessionStart payload
    (`cwd`, `hook_event_name`).
  - Assert: stdout is valid JSON; `hookSpecificOutput.additionalContext`
    equals the file content; `systemMessage` matches the expected
    `handoff loaded — <size>, saved <reltime>` shape.
  - Negative case: no `handoff.md` present → stdout is empty (or empty
    JSON object), exit 0.
- **`tests/extract-test.sh`** — update existing fixtures and assertions:
  - `handoff.md` no longer contains `@handoff-task.md`. Instead, it
    contains the inlined task content (or omits the section if task is
    missing).
  - Add a "task file missing" case asserting the inlined block is
    absent (no placeholder text, no orphan heading).
- **`tests/smoke.sh`** — unchanged. Still runs `extract.py` against the
  most recent session JSONL.

## Risks

- **Hook misconfiguration**: if `load-handoff.sh` has a bug, every
  session start exits with an error. Mitigation: 5 s timeout, exit 0 on
  failure, log to `handoff-error.log`. The hook never blocks session
  startup.
- **Future Claude Code change to SessionStart payload shape**: the
  hook reads `cwd`; if that field is renamed, the hook breaks. Same
  risk applies to existing hooks (`skill-pre-hook.sh` already reads
  `cwd`); no new exposure.
- **Migration friction for current users**: a stale `@`-ref in
  CLAUDE.md doubles content load. Documented in release notes as a
  one-line manual cleanup. No silent failure — duplicated content is
  visible.

## Open questions

None blocking. The token-counting question (raised and resolved during
brainstorming) is documented above as a non-goal.
