# Agent Instructions — handoff plugin

Plugin development conventions. Applies when working inside this repo
to edit the plugin's skill, hook, or script.

## Layout

High-level flow: skill writes `.claude/handoff-task.md` and stores
the session pointer → `PostToolUse(Write|Edit)` stages
`handoff-task.md` for commit → next session's `SessionStart(startup|clear)`
calls `extract.py` in memory and injects the assembled frame. `README.md`
has the user-facing version of this. At wrap-up the skill also runs
`handoff-memory-probe`; when a gitlore-memory submodule is dirty, the probe
emits a directive and the agent summarizes → gets approval → commits memory
via gitlore's `commit-memory.sh`.

- `.claude-plugin/plugin.json` — manifest
- `skills/handoff/SKILL.md` — the main skill (`/handoff:handoff`),
  contains the markdown template for `handoff-task.md`
- `skills/autoname/SKILL.md` — the `/handoff:autoname` skill. Decides a
  session title from the conversation (no tool calls) and writes it to
  `.claude/autorename`; the same `write-rename.sh` PostToolUse hook that
  handoff relies on does the rename. Rename-only — no task file, no
  memory. For `/btw` side conversations and any session worth a name
  while the main thread stays live.
- `skills/handoff/references/design.md` — condensed design notes;
  full rationale is in the plugin-root `DESIGN.md`
- `hooks/hooks.json` — declares six hooks.
  `SessionStart(startup|clear)`: assemble the frame in memory via
  `load-handoff.sh` (reads pointer, calls `extract.py`) and inject
  it via `additionalContext`.
  `PreToolUse(Skill)` and `UserPromptSubmit`: wipe prior handoff files
  when `handoff:handoff` activates. The two together cover both
  invocation paths — the `Skill` tool (agent-driven) and the slash
  command `/handoff:handoff` (user-driven, which loads the skill body
  directly without going through the `Skill` tool).
  `PreToolUse(Read)`: deny reads of this project's `handoff-task.md`
  until `handoff:handoff` has activated this session.
  `PreToolUse(Write|Edit)`: deny `handoff-task.md` writes before
  activation; deny `handoff-task.md` writes whose resolved path is not
  `$cwd/.claude/handoff-task.md` (cross-project guard).
  `PostToolUse(Write|Edit)`: stage `handoff-task.md` for commit when
  it is written.
- `scripts/skill-pre-hook.sh` — PreToolUse(Skill) entry point:
  matches `tool_input.skill` being `handoff` or `handoff:handoff` (the
  Skill tool accepts both as launches of the same skill), then `exec`s
  `_wipe-emit.sh` with `hookEventName=PreToolUse`. Mechanical reset
  before the skill body is loaded — keeps the agent out of the
  cleanup path.
- `scripts/load-handoff.sh` — SessionStart(startup|clear) entry
  point. Gates on `.claude/handoff-task.md`. Reads the session pointer
  from `.claude/handoff-session`, calls `extract.py` (stdout) to
  assemble the frame in memory, and emits it via
  `hookSpecificOutput.additionalContext` (agent-facing) plus a curt
  `systemMessage` with bytes + age (user-facing). Silent no-op when
  the task file is missing or empty.
- `scripts/prompt-pre-hook.sh` — UserPromptSubmit entry point:
  matches prompts starting with `/handoff:handoff`, then `exec`s
  `_wipe-emit.sh` with `hookEventName=UserPromptSubmit`.
  `UserPromptSubmit` does not support the `matcher` field, so the
  script does its own prefix check on the `prompt` JSON field.
- `scripts/_wipe-emit.sh` — shared helper used by both entry scripts.
  Removes `.claude/handoff-task.md`, `.claude/autorename`, and (as legacy
  cleanup for ≤0.4.x upgrades) `.claude/handoff.md` if present.
  If anything was removed, emits dual-channel JSON: `systemMessage`
  (user-facing) and `hookSpecificOutput.additionalContext` (agent-facing,
  so the agent knows the wipe happened and doesn't redundantly verify).
  When `handoff-task.md` (the one tracked artifact) is wiped, stages the
  deletion with `git add -f` on the now-absent path, mirroring
  `write-stage.sh`'s write-side staging so the removal rides the next commit
  (suppressed no-op outside a git repo / when untracked).
  The session pointer is NOT written here — see `write-stage.sh`.
- `scripts/_lib.sh` — sourced helper for the write and read hooks.
  Defines the `HANDOFF_REL_*` path constants and `handoff_resolve()`,
  which canonicalizes multiple paths in one `python3` subprocess
  (GNU/BSD `realpath` are incompatible; python is portable and
  amortizes startup). Also defines `handoff_activated()` (stateless
  transcript scraper — checks whether the handoff skill has activated
  this session by scanning for either invocation signal) and
  `handoff_deny()` (shared PreToolUse deny emitter; calls `exit 0`
  after printing the deny JSON, so only safe from a standalone hook
  script).
  Also defines `handoff_root()` — the effective handoff root for the session:
  `handoff_root "<.cwd>"` shells out to `worktree_root.py`, returning the
  enclosing worktree root or `CLAUDE_PROJECT_DIR`. Every cwd-scoped hook
  anchors on this rather than `CLAUDE_PROJECT_DIR` directly, so worktree
  sessions resolve to their own `.claude/`.
- `scripts/read-guard.sh` — PreToolUse(Read) guard. Denies reads of
  this project's `handoff-task.md` until `handoff:handoff` has
  activated this session.
- `scripts/write-guard.sh` — PreToolUse(Write|Edit) guard. Denies
  `handoff-task.md` writes whose resolved path is not
  `$cwd/.claude/handoff-task.md` (catches cross-project misfires).
  Denies `handoff-task.md` writes before `handoff:handoff` has
  activated this session.
- `scripts/rename-when-idle.sh` — detached watcher. Polls for the Claude TUI
  spinner to be absent (idle), checks the user isn't composing, then fires
  `tmux send-keys -l` to type `/rename <title>` + Enter. Verifies the rename
  landed (status bar) and retries up to 3×. Spawned by `write-rename.sh`;
  outlives the agent turn.
- `scripts/_rename-lib.sh` — sourced helper for `rename-when-idle.sh`.
  Defines `is_busy` (spinner present) and `is_typing` (prompt has content)
  over captured tmux pane text. Pure predicates; tested directly in
  `tests/rename-test.sh`.
- `scripts/write-rename.sh` — PostToolUse(Write|Edit) entry point for session
  renaming. Matches writes whose resolved path is `$cwd/.claude/autorename`,
  reads the title from that file, deletes it, then either spawns a detached
  `rename-when-idle.sh` watcher (in tmux) or emits a `/rename <title>` line
  for the user to paste (outside tmux). Running as a hook rather than via the
  Bash tool means the tmux socket is accessible with no sandbox bypass.
- `scripts/write-stage.sh` — PostToolUse(Write|Edit) entry point:
  matches writes/edits that resolve to `$cwd/.claude/handoff-task.md`,
  saves the session pointer to `.claude/handoff-session` (at write time,
  not activation time — agents update the task after later user input, so
  the pointer must reference the session of the last write), then stages
  the file with `git add -f`.
- `scripts/extract.py` — parses the session JSONL (bounded at the
  last handoff activation), inlines `.claude/handoff-task.md` (if it
  exists), and emits the assembled frame to stdout. Called at
  SessionStart by `load-handoff.sh`; contract: `extract.py
  <transcript.jsonl> <handoff-task.md>`.
- `scripts/worktree_root.py` — pure resolver `worktree_root(cwd, project)`:
  walks up from the session cwd via on-disk `.git` linkage to the enclosing
  linked-worktree root, else returns `project`. Backs `_lib.sh`'s
  `handoff_root`; lets each worktree own its `.claude/`. Unit-tested in
  `tests/test_worktree_root.py` (pytest).
- `bin/handoff-memory-probe` — PATH-resident shim (Claude Code adds each
  plugin's `bin/` to PATH) that execs `scripts/memory-probe.sh`. The skill
  body invokes it by bare name; `${CLAUDE_PLUGIN_ROOT}` is not available in
  the agent's Bash, so the shim is the entry point.
- `scripts/memory-probe.sh` — read-only gitlore-memory detector run by the
  handoff skill at wrap-up. Owns the dirty-or-not branch and prints the
  agent's next action (summarize → approve → commit via
  `git config gitlore.commitCommand`) or stays silent. Couples only to the
  `gitlore-memory` submodule registration (FR12) and the `commitCommand`
  key — never gitlore internals.
- `plugin-dev/` — vendored
  [claude-plugin-dev](https://github.com/ddaanet/claude-plugin-dev)
  toolkit (currently `v0.2.0`). Provides:
  - `release.just` — shared `release` recipe imported by the top-level
    justfile. Owns version bumps, tagging, push, GH release, and the
    marketplace bump in `$MARKETPLACE_DIR`. The plugin's own
    `precommit` recipe is its dependency.
  - `version-guard.sh` — PreToolUse(Write|Edit) hook wired in
    `.claude/settings.json` that refuses agent edits that change
    `plugin.json`'s `.version` (release recipe is the only path).
  - `install.sh` — first-run wiring (idempotent). To update the
    vendored copy: `just update-plugin-dev vX.Y.Z`.
- `.envrc` — exports `MARKETPLACE_DIR` (sibling `claude-plugins`
  repo). Required by `just release`; if the marketplace isn't bumped
  alongside the plugin tag, end-users won't see the new version.
  Run `direnv allow` once per clone.
- `.claude/settings.json` — project Claude Code settings. Wires the
  toolkit's `version-guard.sh` as a PreToolUse(Write|Edit) hook.
  Tracked in git so the guard applies to every clone.
- `DESIGN.md` — living design document, research, and decisions

## Conventions

- Use `${CLAUDE_PLUGIN_ROOT}` in `hooks.json` for portability.
- All hooks are mechanical and cwd-scoped. They anchor on `handoff_root`
  (the enclosing git-worktree root, else `CLAUDE_PROJECT_DIR`) — never on the
  raw hook-input `.cwd` (drift-prone) nor on `CLAUDE_PROJECT_DIR` directly
  (pinned to the main tree in a worktree session). Anything that requires
  judgement belongs in the skill, not a hook.
- Keep the skill body lean (≤2000 words); move detailed rationale to
  references or `DESIGN.md`.
- Output path: `.claude/handoff-task.md` (agent-written, git-tracked).
  The session pointer is `.claude/handoff-session` (machine-local).
  Changing these is a breaking change and requires a version bump.
- `extract.py` must succeed even when the transcript path is empty or
  missing — a handoff with just the inlined task content (if any) and
  empty extracted sections is still valid.
- Extraction constants (`LAST_N_PROMPTS`, `MAX_FILES`,
  `ANCHOR_TEXT_LIMIT`, `ANCHOR_LINE_LIMIT`, `ANCHOR_HEAD_LINES`,
  `ANCHOR_TAIL_LINES`, `WRAPPER_PREFIXES`, `WRAPPER_EXACT`,
  `SKILL_ARTIFACT_SUFFIXES`) live at the top of `extract.py`; do not
  inline them.
- The markdown template lives in `SKILL.md` (single source of truth).
  The script does not re-state the template — it just inlines whatever
  the agent wrote.
- Sourced helpers (`_lib.sh`, `_wipe-emit.sh`) need
  `# shellcheck source-path=SCRIPTDIR source=<file>.sh` above the
  `source` line so `shellcheck -x` follows them. Add
  `# shellcheck disable=SC2034` to vars consumed only by sourcing
  scripts.

## Testing

The shell hooks are tested with **bats**; `extract.py` with **pytest**.
pytest runs off a uv-managed venv that **direnv** activates (`.envrc`
exports `VIRTUAL_ENV` + prepends `$VIRTUAL_ENV/bin` to `PATH`), so the
recipes call bare `pytest` — no `uv run`. Materialize/refresh the venv
with `uv sync` (the only `uv` invocation; `uv.lock` is committed,
`.venv/` is gitignored). See [[feedback-uv-direnv-venv]].

- `just precommit` — lint manifest + settings, syntax-check scripts,
  `shellcheck -x` the scripts + `.bats` files, then run both test
  suites (`bats tests/*.bats` + `pytest`). The toolkit's `release`
  recipe depends on this name; it is also gitlore's `precommitCommand`,
  so it runs on every memory commit (needs the direnv-activated venv).
- `just smoke` — `tests/smoke.sh`: run `extract.py` against the most
  recent session JSONL and print the result.
- `just hook-test` — `bats tests/hook-test.bats tests/rename-test.bats
  tests/memory-probe.bats`: end-to-end test of the handoff-specific hook
  scripts (and the rename scripts) against synthetic tool-event payloads. `bats run` captures
  exit codes/output without the `set +e` dance. `version-guard.sh` is
  tested in the toolkit, not here.
  `tests/memory-probe.bats` covers `scripts/memory-probe.sh` and the
  `bin/` shim against a synthetic gitlore repo; it is listed in both the
  `precommit` and `hook-test` recipes.
- `just extract-test` — `pytest`: fixture-driven tests of `extract.py`
  (`tests/test_extract.py`). Unit tests import the pure functions;
  end-to-end tests render a full frame (via `emit()` captured with
  `redirect_stdout`, or the `extract.py` subprocess for the
  `__main__` contract) against hand-crafted JSONL under
  `tests/fixtures/` — files touched, prompt cap, anchors, wrapper
  filtering, sidechain/isMeta stripping, bounded scrape,
  empty/missing transcript.

Test files live under `tests/`. The justfile recipes are one-liners
that delegate. Add new scenarios to the existing `.bats`/`test_*.py`
files rather than adding new just recipes.

The smoke test must run against a real session JSONL — the format is
undocumented and evolves. The fixture-driven pytest suite is allowed
to use synthetic JSONL, but the fixtures must mirror the real format
(verify by eyeballing a recent transcript); fictional shapes mislead.

## Extraction logic

- **Files touched**: `tool_use` events where `name` is `Edit` or
  `Write`. Reading (`Read`, `Grep`, `Glob`) is *investigation*, not
  touch — intentionally excluded. The handoff/gitlore *control* files
  written while operating the skills (`SKILL_ARTIFACT_SUFFIXES` in
  `extract.py`: `.claude/handoff-task.md`, `handoff-session`,
  `handoff-error.log`, `autorename`, gitlore's `gitlore-commit-msg`,
  `gitlore-merge-state`) are byproducts, not the active set — also
  excluded. gitlore memory *content* (`memory/*.md`) is real work and
  is kept.
- **User prompts**: entries with `type == "user"`. Messages whose
  `content` is entirely `tool_result` blocks are filtered out
  (internal wrappers). CLI-injected wrappers (`<local-command-*>`,
  `<bash-*>`, `<command-*>`, `<system-reminder>`, `<task-notification>`)
  are filtered via `WRAPPER_PREFIXES`; `[Request interrupted by user]`
  via `WRAPPER_EXACT`.
- **isMeta entries**: harness-injected entries (`isMeta == true`) are
  dropped in `load_entries`, alongside `isSidechain`. This is how skill
  bodies are kept out of the handoff: a skill activation injects its
  full body as an `isMeta` user entry on both paths (the `Skill` tool
  and the `/slash-command`), and a native skill body can be 100+ KB and
  starts with its own heading, not a known wrapper prefix — so
  `WRAPPER_PREFIXES` alone misses it. Drop on the structural flag.
- **Anchor**: walk backwards from each kept user prompt to the nearest
  assistant turn. Prefer `tool_use` name + target; fall back to first
  line of assistant text.
- **Cutoff**: the scrape is bounded at the last Write/Edit to
  `handoff-task.md` (not at skill activation). Agents sometimes update
  the task after later user input; cutting at the write captures those
  correction prompts in the last-N window.

## Non-goals

- Summarising the conversation. Extraction is deterministic; summary
  is already handled by `/compact`, Session Memory, and training.
- Validating the markdown schema at write time. Markdown is soft; we
  trust the template in SKILL.md.
- Cross-session thread management. This plugin handles one `/clear`
  transition; auto-memory handles durable state.
