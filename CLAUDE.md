# Agent Instructions — handoff plugin

Plugin development conventions. Applies when working inside this repo
to edit the plugin's skill, hook, or script.

## Layout

- `.claude-plugin/plugin.json` — manifest
- `skills/save/SKILL.md` — the save-and-cleanup skill
  (`/handoff:save`), contains the markdown template for
  `handoff-task.md`
- `skills/save/references/design.md` — condensed design notes; full
  rationale is in the plugin-root `DESIGN.md`
- `skills/setup/SKILL.md` — the first-run setup skill
  (`/handoff:setup`), adds `@.claude/handoff.md` to the project's
  `CLAUDE.md`. Idempotent, append-only.
- `hooks/hooks.json` — declares one hook: `Stop` (regenerate
  `handoff.md` when `handoff-task.md` is fresher)
- `scripts/stop-hook.sh` — Stop hook entry point: mtime-compare; no-op
  unless `.claude/handoff-task.md` is newer than `.claude/handoff.md`;
  delegates extraction to `extract.py`; captures stderr to
  `.claude/handoff-error.log` on failure
- `scripts/extract.py` — parses the session JSONL, writes
  `.claude/handoff.md` with `@handoff-task.md` at the top (resolved
  relative to `handoff.md`'s own directory) and extracted sections
  below
- `DESIGN.md` — living design document, research, and decisions

Loading is delegated to the user's project `CLAUDE.md` via
`@.claude/handoff.md`. Claude Code's `@` resolution recurses up to 5
hops, so the single reference pulls in both files.

## Conventions

- Use `${CLAUDE_PLUGIN_ROOT}` in `hooks.json` for portability.
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

- `just validate` — lint manifest, hooks JSON, bash/python syntax.
- `just smoke` — run `extract.py` against the most recent session
  JSONL and print the result.
- `just hook-test` — dry-run the Stop hook in an ephemeral tmpdir
  with a synthetic task file.

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
