# Agent Instructions — handoff plugin

Plugin development conventions. Applies when working inside this repo
to edit the plugin's skill, hook, or script.

## Layout

High-level flow: skill writes `.claude/handoff-task.md` →
`PostToolUse(Write|Edit)` stages `handoff-task.md` for commit → next
session's `SessionStart(startup|clear)` assembles the frame in memory
(header + inlined task file) and injects it. `README.md`
has the user-facing version of this. At wrap-up the skill also runs
`handoff-memory-probe`; when a gitlore-memory submodule is dirty, the probe
emits a directive and the agent summarizes → gets approval → writes gitlore's
message + trigger files, which gitlore's own `PostToolBatch` hook consumes.

Second flow, driven by the precompact skill: probe (memory commit + ledger
flush) → skill writes `handoff-task.md` and `.claude/autocompact` →
`PostToolUse` validates the latter → `Stop` arms the compaction →
`SessionStart(compact)` re-injects the task file and fires the continuation
prompt. Both typed lines go through detached tmux watchers spawned by hooks at
turn boundaries, never from inside a live turn.

Both skills write the same `handoff-task.md`. It is the durable side of the
seam — content that must survive verbatim — while the continuation prompt is
only a handle to it. Consequently `handoff_activated()` treats either skill as
an activation signal, and the file persists across the compaction to be
re-injected again at the next `startup|clear`.

- `.claude-plugin/plugin.json` — manifest
- `skills/handoff/SKILL.md` — the main skill (`/handoff:handoff`),
  contains the markdown template for `handoff-task.md`
- `skills/autoname/SKILL.md` — the `/handoff:autoname` skill. Decides a
  session title from the conversation (no tool calls) and writes it to
  `.claude/autorename`; the same `write-rename.sh` PostToolUse hook that
  handoff relies on does the rename. Rename-only — no task file, no
  memory. For `/btw` side conversations and any session worth a name
  while the main thread stays live.
- `skills/precompact/SKILL.md` — the `/handoff:precompact` skill.
  Drives **commit memory → compact → continue**: capture durable
  learnings in auto-memory, run `handoff-precompact-probe` and follow
  its directives (memory commit and/or ledger flush), then write
  `handoff-task.md` (per the handoff skill's template) and
  `.claude/autocompact` (line 1 the literal `/compact [directive]`,
  line 2 a single-line continuation prompt that is only a handle to the
  task file). The hooks do the rest; the skill never runs `/compact`
  itself. No rename.
- `skills/handoff/references/design.md` — condensed design notes;
  full rationale is in the plugin-root `DESIGN.md`
- `hooks/hooks.json` — declares nine hooks.
  `SessionStart(startup|clear)`: assemble the frame in memory via
  `load-handoff.sh` (header + inlined task file) and inject it via
  `additionalContext`.
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
  it is written; rename the session on an `autorename` write; validate
  an `autocompact` write.
  `Stop`: arm the compaction when `.claude/autocompact` exists.
  `SessionStart(compact)`: fire the continuation prompt after a
  compaction completes.
- `scripts/skill-pre-hook.sh` — PreToolUse(Skill) entry point:
  matches `tool_input.skill` being `handoff` or `handoff:handoff` (the
  Skill tool accepts both as launches of the same skill), then `exec`s
  `_wipe-emit.sh` with `hookEventName=PreToolUse`. Mechanical reset
  before the skill body is loaded — keeps the agent out of the
  cleanup path.
- `scripts/load-handoff.sh` — SessionStart(startup|clear) entry
  point. Gates on `.claude/handoff-task.md`, assembles the frame in
  memory (a timestamp header plus the inlined task file), and emits it
  via `hookSpecificOutput.additionalContext` (agent-facing) plus a curt
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
  transcript scraper — checks whether `handoff` **or** `precompact` has
  activated this session, scanning both invocation signals for each;
  either opens the guards, since both skills write the task file),
  `handoff_frame()` (assembles the injectable frame — timestamp header
  plus inlined task file — shared by `load-handoff.sh` and
  `load-compact.sh` so the two transitions cannot drift) and
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
  then stages the file with `git add -f`.
- `scripts/write-compact.sh` — PostToolUse(Write|Edit) entry point for the
  compaction driver. Matches writes resolving to `$cwd/.claude/autocompact`
  and **validates only**: exactly two lines, line 1 begins `/compact`. Never
  spawns, never deletes — the file must survive to `Stop`. A malformed file
  gets a `systemMessage` plus an imperative `additionalContext` so the agent
  can fix it in the same turn instead of hitting a silent no-op at `Stop`.
  Path matching is the consume-time cross-project guard (same shape as
  `autorename`): no PreToolUse guard, no activation gate.
- `scripts/stop-compact.sh` — `Stop` entry point: arms the compaction.
  Renames `autocompact` → `autocompact.pending` **before** spawning, so a
  later `Stop` in the same session cannot re-arm, then spawns a detached
  `compact-when-idle.sh` (or emits both lines to paste outside tmux). Silent
  no-op when the file is absent — `Stop` fires every turn. `Stop` does not
  fire on Esc, so an interrupted turn cannot arm compaction.
- `scripts/load-compact.sh` — `SessionStart(compact)` entry point: consumes
  `autocompact.pending`, injects the task-file frame via `additionalContext`
  (`handoff_frame`; omitted when there is no task file), and spawns
  `continue-when-idle.sh`. `source: "compact"` is the authoritative
  compaction-complete signal — no pane scraping. Silent when there is no
  pending file (auto-compaction fires the same hook). Reading the task file
  does not consume it.
- `scripts/compact-when-idle.sh` — detached watcher for line 1.
  Type-verify-submit: sends the command with `send-keys -l` and **no** Enter,
  reads back whether the TUI rendered command recognition, and only then
  Enters — sending `C-u` and aborting if it rendered `No commands match`.
  Retries the Enter alone (re-sending the text would concatenate a copy).
- `scripts/continue-when-idle.sh` — detached watcher for line 2. Same idle
  wait, no recognition check: line 2 is prose, and prose at idle is the safe
  class. Both watchers read only the **visible** pane — a `capture-pane -S`
  history read matches a stale timer and reports busy long after `Stop`.
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
  agent's next action or stays silent. Composes the memory directive from
  `_probe-lib.sh` alone (no SDD nudge — that is a precompact concern).
- `scripts/_probe-lib.sh` — sourced helper holding both probe directives, so
  the memory-commit prompt is authored once and composed twice.
  `probe_memory_directive` gates on the `gitlore-memory` submodule
  registration (FR12) and a dirty worktree, then instructs the agent to
  summarize → get approval → write `.claude/gitlore-memory-message` and
  `.claude/gitlore-commit-memory`. That file-trigger IPC replaced the old
  `git config gitlore.commitCommand` + `commit-memory.sh -F -` Bash path:
  all file writes, so it sidesteps the sandbox and the auto-mode classifier.
  Couples only to the two IPC filenames — never gitlore internals.
  `probe_sdd_directive` holds the structured-workflow ledger nudge.
- `bin/handoff-precompact-probe` — PATH-resident shim that execs
  `scripts/precompact-probe.sh`. Invoked by the precompact skill body by
  bare name (same pattern as `handoff-memory-probe`).
- `scripts/precompact-probe.sh` — read-only detector run by the precompact
  skill before `/compact`. Owns the plugin-specific vocabulary so the skill
  body stays vocab-free: composes the memory directive **then** the SDD
  ledger nudge from `_probe-lib.sh`, or stays silent when neither applies.
  Memory goes first — it is the flow's one interactive gate (FR11 approval)
  and must commit while context is still full, before the summariser runs.
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
  Changing it is a breaking change and requires a version bump.
- The markdown template lives in `SKILL.md` (single source of truth).
  `load-handoff.sh` does not re-state the template — it just inlines
  whatever the agent wrote.
- Sourced helpers (`_lib.sh`, `_wipe-emit.sh`) need
  `# shellcheck source-path=SCRIPTDIR source=<file>.sh` above the
  `source` line so `shellcheck -x` follows them. Add
  `# shellcheck disable=SC2034` to vars consumed only by sourcing
  scripts.

## Testing

The shell hooks are tested with **bats**; the `worktree_root.py`
resolver with **pytest**. pytest runs off a uv-managed venv that
**direnv** activates (`.envrc` exports `VIRTUAL_ENV` + prepends
`$VIRTUAL_ENV/bin` to `PATH`), so the recipes call bare `pytest` — no
`uv run`. Materialize/refresh the venv with `uv sync` (the only `uv`
invocation; `uv.lock` is committed, `.venv/` is gitignored). See
[[feedback-uv-direnv-venv]].

- `just precommit` — lint manifest + settings, `shellcheck -x` the
  scripts + `.bats` files, ruff/docformatter/mypy/ty the Python, then
  run both test suites (`bats tests/*.bats` + `pytest`). The toolkit's
  `release` recipe depends on this name; it is also gitlore's
  `precommitCommand`, so it runs on every memory commit (needs the
  direnv-activated venv).
- `just hook-test` — `bats tests/hook-test.bats tests/rename-test.bats
  tests/memory-probe.bats tests/precompact-probe.bats`: end-to-end test of
  the handoff-specific hook
  scripts (and the rename scripts) against synthetic tool-event payloads. `bats run` captures
  exit codes/output without the `set +e` dance. `version-guard.sh` is
  tested in the toolkit, not here.
  `tests/memory-probe.bats` covers `scripts/memory-probe.sh` and the
  `bin/` shim against a synthetic gitlore repo; `tests/precompact-probe.bats`
  covers `scripts/precompact-probe.sh` and its shim, including the composed
  memory-then-SDD ordering. Both build their fixtures from
  `tests/probe-helpers.bash` (one shared synthetic-repo shape, so the two
  suites cannot drift). Both are listed in the `precommit` and `hook-test`
  recipes.
  The compaction driver is covered in the two existing suites rather than a
  new file: `tests/hook-test.bats` for `write-compact.sh` / `stop-compact.sh`
  / `load-compact.sh`, `tests/rename-test.bats` for the two watchers and the
  `is_unknown_command` predicate (they share `_rename-lib.sh` and the tmux
  stub).
- `just py-test` — `pytest`: unit tests of `worktree_root.py`
  (`tests/test_worktree_root.py`) — the worktree-root resolver's branch
  matrix.

Test files live under `tests/`. The justfile recipes are one-liners
that delegate. Add new scenarios to the existing `.bats`/`test_*.py`
files rather than adding new just recipes.

The JSONL fixtures the bats suite feeds to `handoff_activated`
(`tests/fixtures/*.jsonl`) must mirror the real transcript format — the
format is undocumented and evolves, so verify by eyeballing a recent
transcript; fictional shapes mislead.

## Frame assembly

Neither loader touches the transcript. The frame is a timestamp header
plus the inlined agent-authored `handoff-task.md`, assembled by
`handoff_frame()` and injected at both transitions — `load-handoff.sh`
on `startup|clear`, `load-compact.sh` on `compact`.
There is no session id, no files-touched list, and no verbatim prompt
transcript — the working set is the harness's own `gitStatus` block at
load time, and reproducing prior exchanges verbatim manufactured false
continuity. See DESIGN.md, "Task frame drops the transcript and file
list (2026-07-17)".

## Non-goals

- Summarising the conversation. Extraction is deterministic; summary
  is already handled by `/compact`, Session Memory, and training.
- Validating the markdown schema at write time. Markdown is soft; we
  trust the template in SKILL.md.
- Cross-session thread management. This plugin handles one `/clear`
  transition; auto-memory handles durable state.
