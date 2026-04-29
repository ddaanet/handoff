# Agent Instructions — handoff plugin

Plugin development conventions. Applies when working inside this repo
to edit the plugin's skill, hook, or script.

## Layout

- `.claude-plugin/plugin.json` — manifest
- `skills/handoff/SKILL.md` — the main skill (`/handoff:handoff`),
  contains the markdown template for `handoff-task.md`
- `skills/handoff/references/design.md` — condensed design notes;
  full rationale is in the plugin-root `DESIGN.md`
- `skills/setup/SKILL.md` — the first-run setup skill
  (`/handoff:setup`), adds `@.claude/handoff.md` to the project's
  `CLAUDE.md`. Idempotent, append-only.
- `hooks/hooks.json` — declares four hooks.
  `PreToolUse(Skill)` and `UserPromptSubmit`: wipe prior handoff files
  when `handoff:handoff` activates. The two together cover both
  invocation paths — the `Skill` tool (agent-driven) and the slash
  command `/handoff:handoff` (user-driven, which loads the skill body
  directly without going through the `Skill` tool).
  `PreToolUse(Write|Edit)`: deny `handoff-task.md` writes whose
  resolved path is not `$cwd/.claude/handoff-task.md`.
  `PostToolUse(Write|Edit)`: regenerate `.claude/handoff.md` whenever
  `handoff-task.md` is written, so extraction is visible in the same
  agent turn.
- `scripts/skill-pre-hook.sh` — PreToolUse(Skill) entry point:
  matches `tool_input.skill == "handoff:handoff"` and `rm`s any prior
  `.claude/handoff-task.md` and `.claude/handoff.md`. Mechanical reset
  before the skill body is loaded — keeps the agent out of the
  cleanup path.
- `scripts/prompt-pre-hook.sh` — UserPromptSubmit entry point:
  matches prompts starting with `/handoff:handoff` and runs the same
  wipe. `UserPromptSubmit` does not support the `matcher` field, so
  the script does its own prefix check on the `prompt` JSON field.
- `scripts/write-guard.sh` — PreToolUse(Write|Edit) guard. Refuses
  with a helpful agent-facing message when `basename` is
  `handoff-task.md` but `realpath` differs from
  `$cwd/.claude/handoff-task.md` (catches cross-project misfires).
- `scripts/write-extract.sh` — PostToolUse(Write|Edit) entry point:
  matches writes/edits that resolve to `$cwd/.claude/handoff-task.md`
  and runs `extract.py` to (re)generate `$cwd/.claude/handoff.md`.
  Captures stderr to `.claude/handoff-error.log` on failure.
- `scripts/extract.py` — parses the session JSONL, writes
  `.claude/handoff.md` with `@handoff-task.md` at the top (resolved
  relative to `handoff.md`'s own directory) and extracted sections
  below
- `plugin-dev/` — vendored
  [claude-plugin-dev](https://github.com/ddaanet/claude-plugin-dev)
  toolkit (currently `v0.1.2`). Provides:
  - `release.just` — shared `release` recipe imported by the top-level
    justfile. Owns version bumps, tagging, push, GH release. The
    plugin's own `precommit` recipe is its dependency.
  - `version-guard.sh` — PreToolUse(Write|Edit) hook wired in
    `.claude/settings.json` that refuses agent edits that change
    `plugin.json`'s `.version` (release recipe is the only path).
  - `install.sh` — first-run wiring (idempotent). To update the
    vendored copy: `just update-plugin-dev vX.Y.Z`.
- `.claude/settings.json` — project Claude Code settings. Wires the
  toolkit's `version-guard.sh` as a PreToolUse(Write|Edit) hook.
  Tracked in git so the guard applies to every clone.
- `DESIGN.md` — living design document, research, and decisions

Loading is delegated to the user's project `CLAUDE.md` via
`@.claude/handoff.md`. Claude Code's `@` resolution recurses up to 5
hops, so the single reference pulls in both files.

## Conventions

- Use `${CLAUDE_PLUGIN_ROOT}` in `hooks.json` for portability.
- All hooks are mechanical and cwd-scoped. Anything that requires
  judgement belongs in the skill, not a hook.
- Keep the skill body lean (≤2000 words); move detailed rationale to
  references or `DESIGN.md`.
- Output paths are fixed: `.claude/handoff-task.md` (agent-written)
  and `.claude/handoff.md` (hook-written) in the project root.
  Changing these is a breaking change and requires a version bump.
- `extract.py` must succeed even when the transcript path is empty or
  missing — a handoff with just the `@` ref and empty extracted
  sections is still valid.
- Extraction constants (`LAST_N_PROMPTS`, `MAX_FILES`,
  `ANCHOR_TEXT_LIMIT`, `WRAPPER_PREFIXES`, `WRAPPER_EXACT`) live at the
  top of `extract.py`; do not inline them.
- The markdown template lives in `SKILL.md` (single source of truth).
  The script does not re-state the template — it just @-refs whatever
  the agent wrote.

## Testing

- `just precommit` — lint manifest + settings, syntax-check scripts,
  run the hook test suite. The toolkit's `release` recipe depends on
  this name.
- `just smoke` — `tests/smoke.sh`: run `extract.py` against the most
  recent session JSONL and print the result.
- `just hook-test` — `tests/hook-test.sh`: end-to-end test of the
  handoff-specific hook scripts against synthetic tool-event payloads,
  with assertions and a pass/fail summary. Exit code is propagated.
  `version-guard.sh` is tested in the toolkit, not here.

Test scripts live under `tests/`. The justfile recipes are
one-liners that delegate. Add new test scenarios to the existing
script rather than adding new just recipes.

Never mock the session JSONL format — always test against a real
transcript. The format is undocumented and evolves; tests against
fictional data will mislead.

## Extraction logic

- **Files touched**: `tool_use` events where `name` is `Edit` or
  `Write`. Reading (`Read`, `Grep`, `Glob`) is *investigation*, not
  touch — intentionally excluded.
- **User prompts**: entries with `type == "user"`. Messages whose
  `content` is entirely `tool_result` blocks are filtered out
  (internal wrappers). CLI-injected wrappers (`<local-command-*>`,
  `<bash-*>`, `<command-*>`, `<system-reminder>`) are filtered via
  `WRAPPER_PREFIXES`; `[Request interrupted by user]` via
  `WRAPPER_EXACT`.
- **Anchor**: walk backwards from each kept user prompt to the nearest
  assistant turn. Prefer `tool_use` name + target; fall back to first
  line of assistant text.

## Non-goals

- Summarising the conversation. Extraction is deterministic; summary
  is already handled by `/compact`, Session Memory, and training.
- Validating the markdown schema at write time. Markdown is soft; we
  trust the template in SKILL.md.
- Cross-session thread management. This plugin handles one `/clear`
  transition; auto-memory handles durable state.

## Handoff

@.claude/handoff.md
