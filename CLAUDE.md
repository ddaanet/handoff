# Agent Instructions — handoff plugin

Plugin development conventions. Applies when working inside this repo
to edit the plugin's skill, hook, or script.

## Layout

High-level flow: skill writes `.claude/handoff-task.md` →
`PostToolUse(Write|Edit)` stages `handoff-task.md` for commit → next
session's `SessionStart(startup|clear)` assembles the frame in memory
(header + inlined task file) and injects it. `README.md`
has the user-facing version of this. At wrap-up the skill also runs
`handoff-memory-probe <with-commit|without-commit>`; when a gitlore-memory
submodule is dirty, the probe emits a directive and the agent summarizes →
gets approval → writes gitlore's message file, plus the trigger file only
under `without-commit`, which gitlore's own `PostToolBatch` hook consumes.
Under `with-commit` the message file alone leaves the memory commit to the
parent commit's pre-commit hook — one call instead of two, which is the whole
gain, since both paths end with one parent commit carrying the source change and
the gitlink bump. See DESIGN.md, "Commit awareness (2026-07-25)".

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

Both skills also write `.claude/handoff-todo.md` when an active task list has
open items: the **remainder** only, never completion state. It is the ledger;
whatever todo tracker the harness happens to expose is a cache, and nothing in
the plugin names one (the tool is behind a server-side flag and has already
changed generations once). Same wipe, same guards, same frame, same
force-added staging as the task file — it is overflow from it. See DESIGN.md,
"A place for the todo list (2026-07-22)" and "Overflow deserves the same
persistence (2026-07-23)".

- `.claude-plugin/plugin.json` — manifest
- `skills/handoff/SKILL.md` — the main skill (`/handoff:handoff`),
  contains the markdown templates for `handoff-task.md` and
  `handoff-todo.md` (both are the single source of truth for their shape).
  Its first step is the commit-awareness decision — is a commit going to
  carry this session's memory — which it passes to the probe and which
  makes it write memory as if the change has landed.
- `skills/autoname/SKILL.md` — the `/handoff:autoname` skill. Decides a
  session title from the conversation (no tool calls) and writes it to
  `.claude/autorename`; the same `write-rename.sh` PostToolUse hook that
  handoff relies on does the rename. Rename-only — no task file, no
  memory. For `/btw` side conversations and any session worth a name
  while the main thread stays live.
- `skills/precompact/SKILL.md` — the `/handoff:precompact` skill.
  Drives **commit memory → compact → continue**: decide commit awareness
  (same first step as handoff, with the extra load-bearing rule that when
  the commit is part of the request it lands *before* `.claude/autocompact`
  is written — arming the compaction ends the turn), capture durable
  learnings in auto-memory, run `handoff-precompact-probe <mode>` and follow
  its directives (memory commit and/or ledger flush), then write
  `handoff-task.md` (and `handoff-todo.md` when a task list has open
  items — with no tracker the list is context-resident, and context is
  exactly what compaction paraphrases), per the handoff skill's templates,
  and `.claude/autocompact` (line 1 the literal `/compact [directive]`,
  line 2 a single-line continuation prompt that is only a handle to the
  task file). The hooks do the rest; the skill never runs `/compact`
  itself. No rename.
- `skills/handoff/references/design.md` — condensed design notes;
  full rationale is in the plugin-root `DESIGN.md`
- `hooks/hooks.json` — declares eleven hooks.
  `SessionStart(startup|clear)`: assemble the frame in memory via
  `load-handoff.sh` (header + inlined task file) and inject it via
  `additionalContext`.
  `PreToolUse(Skill)` and `UserPromptSubmit`: wipe prior handoff files
  when `handoff:handoff` or `handoff:precompact` activates. The two
  together cover both invocation paths — the `Skill` tool (agent-driven)
  and the slash command (user-driven, which loads the skill body
  directly without going through the `Skill` tool). Both skills wipe:
  both author `handoff-task.md` from the conversation, never from the
  file's prior contents, so each runs against a clean slate.
  `PreToolUse(Read)`: deny reads of this project's `handoff-task.md` and
  `handoff-todo.md` until `handoff` or `precompact` has activated this
  session.
  `PreToolUse(Write|Edit)`: deny `handoff-task.md` / `handoff-todo.md`
  writes before activation; deny them when the resolved path is not
  `$cwd/.claude/<file>` (cross-project guard).
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
  Removes `.claude/handoff-task.md`, `.claude/handoff-todo.md`,
  `.claude/autorename`, and (as legacy cleanup for ≤0.4.x upgrades)
  `.claude/handoff.md` if present. The todo file is wiped despite being
  input carried forward: both loaders re-inject it at SessionStart, so the
  agent re-authors from context, and without the wipe a finished list would
  linger and keep re-injecting done items as outstanding.
  If anything was removed, emits dual-channel JSON: `systemMessage`
  (user-facing) and `hookSpecificOutput.additionalContext` (agent-facing,
  so the agent knows the wipe happened and doesn't redundantly verify).
  When `handoff-task.md` or `handoff-todo.md` (the tracked artifacts) is
  wiped, stages the deletion with `git add -f` on the now-absent path,
  mirroring `write-stage.sh`'s write-side staging so the removal rides the
  next commit (suppressed no-op outside a git repo / when untracked).
- `scripts/_lib.sh` — sourced helper for the write and read hooks.
  Defines the `HANDOFF_REL_*` path constants and `handoff_resolve()`,
  which canonicalizes multiple paths in one `python3` subprocess
  (GNU/BSD `realpath` are incompatible; python is portable and
  amortizes startup). Also defines `handoff_activated()` (stateless
  transcript scraper — checks whether `handoff` **or** `precompact` has
  activated this session, scanning both invocation signals for each;
  either opens the guards, since both skills write the task file),
  `handoff_frame()` (assembles the injectable frame — timestamp header
  plus the inlined task file and todo remainder, task first; either alone
  is enough, rc 1 only when both are missing or empty — shared by
  `load-handoff.sh` and `load-compact.sh` so the two transitions cannot
  drift) and
  `handoff_deny()` (shared PreToolUse deny emitter; calls `exit 0`
  after printing the deny JSON, so only safe from a standalone hook
  script).
  Also defines `handoff_root()` — the effective handoff root for the session:
  `handoff_root "<.cwd>"` shells out to `worktree_root.py`, returning the
  enclosing worktree root or `CLAUDE_PROJECT_DIR`. Every cwd-scoped hook
  anchors on this rather than `CLAUDE_PROJECT_DIR` directly, so worktree
  sessions resolve to their own `.claude/`. An empty or project-root cwd
  short-circuits in bash (mirroring `worktree_root.py`'s trivial branches)
  so the every-turn hooks (`Stop`, `UserPromptSubmit`) skip the python3
  spawn in the common case.
  `handoff_match_target()` is the shared preamble of every path-scoped
  hook: one call does the jq field parse, basename fast-path, root
  resolution, and resolved-path comparison against the expected
  `$cwd/<rel>`, distinguishing "other file" (rc 1) from "basename matched
  but cross-project" (rc 2, which only `write-guard.sh` denies). It is
  variadic over (basename, rel) pairs and sets `MATCHED_NAME` — the guards
  cover two files, and the jq parse is on the Write/Edit hot path, so N
  files must stay one parse.
  `handoff_spawn_detached()` is the shared setsid-else-nohup detach used
  by all three watcher-spawning hooks (setsid is Linux-only; nohup is the
  macOS fallback).
- `scripts/read-guard.sh` — PreToolUse(Read) guard. Denies reads of
  this project's `handoff-task.md` and `handoff-todo.md` until `handoff`
  or `precompact` has activated this session.
- `scripts/write-guard.sh` — PreToolUse(Write|Edit) guard. Denies
  `handoff-task.md` / `handoff-todo.md` writes whose resolved path is not
  `$cwd/.claude/<file>` (catches cross-project misfires). Denies them
  before `handoff` or `precompact` has activated this session. The todo
  file is gated on the same terms as the task file: the defect these
  guards exist for was the agent co-opting a handoff file as a scratch
  todo list before any skill ran.
- `scripts/rename-when-idle.sh` — detached watcher. Polls for the Claude TUI
  spinner to be absent (idle), checks the user isn't composing, then fires
  `tmux send-keys -l` to type `/rename <title>` + Enter. Verifies the rename
  landed (status bar) and retries up to 3×. Spawned by `write-rename.sh`;
  outlives the agent turn. Both non-delivery paths — the composing-bail and
  three failed verifies — end in `watcher_fail`, so neither is silent. The bail
  is the shape DESIGN.md calls indistinguishable from success: it used to
  `exit 0` while `write-rename.sh` had already promised the user a rename.
- `scripts/_rename-lib.sh` — sourced helper for every detached watcher
  (`rename-when-idle.sh` and both compaction watchers, despite the name).
  Defines `is_busy` (spinner present), `is_typing` (prompt has content) and
  `is_unknown_command` over captured tmux pane text — pure predicates, tested
  directly in `tests/rename-test.bats`. Also the shared watcher scaffold:
  the `HANDOFF_WATCHER_*` tunables, `snap` (visible-pane capture — never
  scrollback), `wait_for_idle` (stable-idle poll loop) and two submit
  confirmations, neither of which reads the pane. `submit_consumed_or_fail` is
  for line 1: it Enters, then waits for `$HANDOFF_PENDING_FILE` (exported by
  `stop-compact.sh`) to disappear, which `SessionStart(compact)` is what does —
  confirming the compaction rather than the keystroke. `is_busy` was the
  original criterion and false-fails here: the TUI shows no matching chrome in
  the ~1.5s after the keystroke, so a live 103-second compaction was reported as
  never submitted. The trade is latency, since a real non-delivery now waits out
  `CONSUME_TIMEOUT`; with no file to confirm against it exits 0, because an
  unconfirmable submit is not a failed one. The continuation
  watcher instead uses `submit_confirmed_or_fail` + `transcript_prompt_count`,
  which confirm via the session transcript (`$HANDOFF_TRANSCRIPT`, exported by
  `load-compact.sh`) rather than the spinner — line 2 fires into the
  post-compaction settle where a submit is *queued* (accepted, transcript-logged
  at once) but shows no spinner until the queued turn starts seconds later, so
  `is_busy` would false-fail it. The count keys on the same structural flags as
  `handoff_activated` and is baselined before the first Enter, so neither a
  quoted echo in the summary/frame nor a stale pre-compaction copy reads as a
  submit. Each watcher keeps only its distinct middle — rename-verify vs
  type-verify-submit vs prose-settle-confirm. And `watcher_fail`, which records a
  non-delivery reason to `$HANDOFF_FAIL_FILE` (set by the spawning hook, which
  owns the path) and exits 1; unset is tolerated.
- `scripts/write-rename.sh` — PostToolUse(Write|Edit) entry point for session
  renaming. Matches writes whose resolved path is `$cwd/.claude/autorename`,
  reads the title from that file, deletes it, then either spawns a detached
  `rename-when-idle.sh` watcher (in tmux) or emits a `/rename <title>` line
  for the user to paste (outside tmux). Running as a hook rather than via the
  Bash tool means the tmux socket is accessible with no sandbox bypass.
  Exports `HANDOFF_FAIL_FILE` (`.claude/autorename.failed`) before spawning,
  the same arrangement `stop-compact.sh` uses: the hook owns the path, the
  watcher stays ignorant of the layout.
- `scripts/write-stage.sh` — PostToolUse(Write|Edit) entry point:
  matches writes/edits that resolve to `$cwd/.claude/handoff-task.md` or
  `$cwd/.claude/handoff-todo.md`, then stages the matched file with
  `git add -f`. One `handoff_match_target` call covers both, so the two
  tracked halves of the frame cost one jq parse.
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
  `continue-when-idle.sh` with the session `transcript_path` exported as
  `$HANDOFF_TRANSCRIPT` (the watcher's delivery-confirmation signal).
  `source: "compact"` is the authoritative compaction-complete signal — no pane
  scraping. Silent when there is no pending file (auto-compaction fires the same
  hook). Reading the task file does not consume it.
- `scripts/report-watcher-failure.sh` — `UserPromptSubmit` entry point:
  reconciles watcher and compaction state at the start of a turn.
  It consumes `.claude/autocompact.failed` and `.claude/autorename.failed` —
  one file per driven line, differing only in which line never landed — and
  reports the reasons on both channels in a single message, also clearing a
  stranded `autocompact.pending` (compaction failure only). Detached watchers'
  exit status is read by nothing, so these files are their only path back to the
  agent — most of all on the line-1 recognition abort, which wipes the composer
  and leaves the pane looking untouched. `UserPromptSubmit` rather than `Stop`
  because a watcher runs *after* the Stop that spawned it. Reports only what a
  watcher observed itself; a stale `.pending` alone is never treated as failure
  (it is legitimate for the whole Stop → compaction window).
  It also sweeps a bare `.claude/autocompact`: the file is armed at the `Stop`
  of the turn that writes it and renamed away, so one still present when a
  later turn begins never armed, and would otherwise be armed by the next
  `Stop` — days later, possibly in another session. `UserPromptSubmit` is the
  exact discriminator; it cannot fire between the write and that turn's own
  `Stop`. Only the failure branch touches `.pending` — sweeping it on a stale
  `autocompact` would race a live `SessionStart(compact)`. See DESIGN.md, "A
  stale autocompact is one a later turn can see (2026-07-22)".
- `scripts/compact-when-idle.sh` — detached watcher for line 1.
  Type-verify-submit: sends the command with `send-keys -l` and **no** Enter,
  reads back whether the TUI rendered command recognition, and only then
  Enters — sending `C-u` and aborting if it rendered `No commands match`.
  Retries the Enter alone (re-sending the text would concatenate a copy).
- `scripts/continue-when-idle.sh` — detached watcher for line 2. Same idle
  wait, no recognition check: line 2 is prose, and prose at idle is the safe
  class. Confirms delivery via the transcript (`submit_confirmed_or_fail`), not
  `is_busy`: it fires into the post-compaction settle, where the submit is
  queued and shows no spinner in the confirm window even though it was accepted.
  Both watchers read only the **visible** pane — a `capture-pane -S`
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
  handoff skill at wrap-up. Takes the required commit-awareness mode
  (`probe_require_mode`, validated before anything else — a bad mode is
  exit 2 even where the probe would have stayed silent). Owns the
  dirty-or-not branch and prints the
  agent's next action or stays silent. Composes the memory directive plus
  the todo-file suppression from `_probe-lib.sh`. No SDD *nudge* — the
  bring-the-ledger-current prompt is a precompact concern — but the
  suppression does apply here, since a workflow ledger outlives a `/clear`
  exactly as it outlives a compaction.
- `scripts/_probe-lib.sh` — sourced helper holding the probe directives, so
  each prompt is authored once and composed twice.
  `probe_require_mode` validates each probe's sole positional argument, the
  commit-awareness mode, and sets `PROBE_MODE` — a global rather than stdout,
  because `exit 2` inside a command substitution ends only the subshell and
  the caller would sail on with an empty mode (same shape as
  `handoff_match_target`'s `MATCHED_NAME`). No default: the two values are
  peers, since a default is the answer an agent gives when it has not thought
  about the question.
  `probe_memory_directive` gates on the `gitlore-memory` submodule
  registration (FR12) and a dirty worktree, then instructs the agent to
  summarize → get approval → write `.claude/gitlore-memory-message`, and
  under `without-commit` also `.claude/gitlore-commit-memory`. That trigger
  file is the whole difference between the two paths: written, gitlore's
  `PostToolBatch` commits memory standalone; withheld, the parent commit's
  pre-commit hook bundles it into the source commit. The `with-commit` text
  therefore never mentions the trigger — not its path, not the concept. The
  reader is a fresh agent with no other source for that filename, so saying
  nothing is what makes the standalone commit unreachable, and a prohibition
  would introduce what it forbids. It states no mechanism either (no
  pre-commit hook, no mtime freshness rule) and does not order the write
  against the memory edits — both skills finish memory before running the
  probe, and "once approved" already places the write after them. Neither
  skill body states it either: approval is a feedback loop that routinely
  edits memory, so a rule pinning memory as final forbids what the gate is
  for. What is left is one act plus one clause saying this
  turn's commit carries the memory, so its absence is not read as a failure.
  Mechanism a reader cannot act on gets verified and narrated instead.
  That file-trigger IPC replaced the old
  `git config gitlore.commitCommand` + `commit-memory.sh -F -` Bash path:
  all file writes, so it sidesteps the sandbox and the auto-mode classifier.
  Couples only to the two IPC filenames — never gitlore internals.
  `probe_ledger_path` is the one-row registry of known workflow-owned
  progress ledgers (currently superpowers SDD), so the nudge and the
  suppression can never disagree about what exists — and both interpolate
  what it prints, because with a glob there is no path to hardcode. It
  detects **liveness**, not presence: a match under
  `.superpowers/sdd/*/progress.md` counts only with SDD's identity first
  line, the pre-6.2.0 flat path never counts, and among several the
  most-recently-modified wins. See DESIGN.md, "An orphaned ledger hijacks
  the handoff (2026-07-26)". `probe_sdd_directive`
  holds the structured-workflow ledger nudge (precompact only) and ends by
  standing `handoff-todo.md` down; `probe_todo_suppression` is that
  stand-down alone, for the handoff path.
- `bin/handoff-precompact-probe` — PATH-resident shim that execs
  `scripts/precompact-probe.sh`. Invoked by the precompact skill body by
  bare name (same pattern as `handoff-memory-probe`).
- `scripts/precompact-probe.sh` — read-only detector run by the precompact
  skill before `/compact`. Takes the same required commit-awareness mode as
  `memory-probe.sh`. Owns the plugin-specific vocabulary so the skill
  body stays vocab-free: composes the memory directive **then** the SDD
  ledger nudge from `_probe-lib.sh`, or stays silent when neither applies.
  Composition order is a property of the probe, not the mode.
  Memory goes first — it is the flow's one interactive gate (FR11 approval)
  and must commit while context is still full, before the summariser runs.
- `plugin-dev/` — vendored
  [claude-plugin-dev](https://github.com/ddaanet/claude-plugin-dev)
  toolkit (currently `v0.4.0`). Provides:
  - `release.just` — shared `release` recipe imported by the top-level
    justfile. Owns version bumps, tagging, push, GH release, and the
    marketplace bump in `$MARKETPLACE_DIR`. It depends on the plugin's
    own `prerelease` recipe, which here is just `precommit`.
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
- Output paths: `.claude/handoff-task.md` and `.claude/handoff-todo.md`, both
  agent-written and both git-tracked via `git add -f` (listed in `.gitignore`
  so only the hook adds them). Changing either is a breaking change and
  requires a version bump.
- Both markdown templates live in `SKILL.md` (single source of truth).
  Neither loader re-states them — each file carries its own `##` headings
  and is inlined verbatim under the one `#` header the frame prepends.
- `handoff-todo.md` holds **open items only**. A finished item is dropped,
  never checked off: what landed is reconstructable from `git log`, and a
  done item still listed reads as outstanding and gets redone.
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
  `hook-test.bats` stubs `tmux` on `PATH` in `setup()` and shortens the
  `HANDOFF_WATCHER_*` tunables. Three of the hooks it exercises spawn a
  detached watcher, and `TMUX=fake` does not stop tmux falling back to the
  default socket — unstubbed, those watchers drive a real pane belonging to
  whoever is running the suite.
  `tests/memory-probe.bats` covers `scripts/memory-probe.sh` and the
  `bin/` shim against a synthetic gitlore repo; `tests/precompact-probe.bats`
  covers `scripts/precompact-probe.sh` and its shim, including the composed
  memory-then-SDD ordering. Both cover the commit-awareness contract in
  full: the mode's four combinations with memory state, the argument
  validation (missing / unknown / two), and each shim forwarding the mode.
  The load-bearing assertion is the negative — `with-commit` output never
  mentions a trigger — and it is mutation-checked (disable the branch, watch
  it go red), not observed passing.
  Both build their fixtures from
  `tests/probe-helpers.bash` (one shared synthetic-repo shape, so the two
  suites cannot drift). Both are listed in the `precommit` and `hook-test`
  recipes.
  The compaction driver is covered in the two existing suites rather than a
  new file: `tests/hook-test.bats` for `write-compact.sh` / `stop-compact.sh`
  / `load-compact.sh` / `report-watcher-failure.sh`, `tests/rename-test.bats`
  for the two watchers, the `is_unknown_command` predicate and the
  `watcher_fail` recording (they share `_rename-lib.sh` and the tmux stub).
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
plus the inlined agent-authored `handoff-task.md` and `handoff-todo.md`
(task first; either alone is enough), assembled by `handoff_frame()` and
injected at both transitions — `load-handoff.sh` on `startup|clear`,
`load-compact.sh` on `compact`.
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
