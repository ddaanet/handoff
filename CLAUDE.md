# Agent Instructions — handoff plugin

Plugin development conventions. Applies when working inside this repo
to edit the plugin's skill, hook, or script.

## Layout

High-level flow: the skill decides the task/todo/rename content, then issues
one `handoff-checkpoint` Bash call carrying the whole wrap-up as a
schema-validated JSON payload on stdin → `checkpoint.sh` writes
`.claude/handoff-task.md`/`.claude/handoff-todo.md`/`.claude/autorename` (per
FR5/FR6 write semantics — a Write or Edit form, empty body ⟹ removed) and
leaves `.claude/checkpoint-manifest` behind, since staging and the tmux
rename watcher can't run from the agent's sandboxed Bash (NFR1) →
`PostToolUse(Bash)` (`bash-post.sh`) consumes the manifest: stages every
listed path with `git add -f` (deletions included) and spawns the rename
watcher → next session's `SessionStart(startup|clear)` assembles the frame in
memory (header + inlined task file) and injects it. `README.md` has the
user-facing version of this. The checkpoint also emits, on stdout, the same
directives the two probes it replaced used to print: when a gitlore-memory
submodule is dirty, a memory directive tells the agent to summarize → get
approval → write gitlore's message file, plus the trigger file only under
`without-commit`, which gitlore's own `PostToolBatch` hook consumes. Under
`with-commit` the message file alone leaves the memory commit to the parent
commit's pre-commit hook — one call instead of two, which is the whole gain,
since both paths end with one parent commit carrying the source change and
the gitlink bump. See `docs/changelog/2026-07-25-commit-awareness.md` and
`docs/changelog/2026-07-27-one-channel-one-writer.md`.

Second flow, driven by the precompact skill: same `handoff-checkpoint` call
(`"skill": "precompact"`, no `rename`) → its directive output composes the
memory gate with the SDD ledger nudge instead of the todo-file suppression →
skill writes `.claude/autocompact` → `PostToolUse` validates it → `Stop` arms
the compaction → `SessionStart(compact)` re-injects the task file and fires
the continuation prompt. Both typed lines go through detached tmux watchers
spawned by hooks at turn boundaries, never from inside a live turn.

Both skills route through the same checkpoint call, discriminated by the
payload's `skill` field, and both can carry `task` — the durable side of the
seam, content that must survive verbatim — while the continuation prompt is
only a handle to it. `handoff-task.md` is written **only** by the checkpoint
(FR3): a direct agent Write/Edit is denied outright by `write-guard.sh`.

`handoff-todo.md` is different: it is a scratch list the agent edits freely
all session (FR4), and the checkpoint's wrap-up call is only where the final
remainder gets folded in — not the only writer. It is the ledger; whatever
todo tracker the harness happens to expose is a cache, and nothing in the
plugin names one (the tool is behind a server-side flag and has already
changed generations once). A direct agent edit is staged by `write-stage.sh`
on the spot; the checkpoint stages its own task/todo writes via the manifest
instead. Content, not activation, decides when either file is considered
empty and removed: see `docs/changelog/2026-07-22-a-place-for-the-todo-list.md`,
`docs/changelog/2026-07-23-overflow-deserves-persistence.md`, and
`docs/changelog/2026-07-27-one-channel-one-writer.md`.

- `.claude-plugin/plugin.json` — manifest
- `skills/handoff/SKILL.md` — the main skill (`/handoff:handoff`),
  contains the markdown templates for `handoff-task.md` and
  `handoff-todo.md` (both are the single source of truth for their shape).
  Its first step is the commit-awareness decision — is a commit going to
  carry this session's memory — which it passes to the checkpoint call and
  which makes it write memory as if the change has landed. Step 3 decides
  the title/task/remainder, then issues one `handoff-checkpoint` Bash call
  with the whole wrap-up as a JSON heredoc; step 4 follows whatever
  directive the checkpoint prints.
- `skills/autoname/SKILL.md` — the `/handoff:autoname` skill. Decides a
  session title from the conversation (no tool calls) and writes it to
  `.claude/autorename` directly with the Write tool; the same
  `write-rename.sh` PostToolUse(Write|Edit) hook that handoff's checkpoint
  call ultimately triggers (via `bash-post.sh`, since the checkpoint writes
  the same file from Bash) does the rename. Rename-only — no task file, no
  memory. For `/btw` side conversations and any session worth a name
  while the main thread stays live.
- `skills/precompact/SKILL.md` — the `/handoff:precompact` skill.
  Drives **commit memory → compact → continue**: decide commit awareness
  (same first step as handoff, with the extra load-bearing rule that when
  the commit is part of the request it lands *before* `.claude/autocompact`
  is written — arming the compaction ends the turn), capture durable
  learnings in auto-memory, decide the task/todo content, then run one
  `handoff-checkpoint` Bash call (`"skill": "precompact"`, no `rename` —
  schema-forbidden there) and follow whatever directive it prints (memory
  commit and/or ledger flush), then write `.claude/autocompact` (line 1 the
  literal `/compact [directive]`, line 2 a single-line continuation prompt
  that is only a handle to the task file). The hooks do the rest; the skill
  never runs `/compact` itself. No rename.
- `skills/handoff/references/design.md` — condensed design notes;
  full rationale is in `docs/design.md`
- `hooks/hooks.json` — declares nine hooks.
  `SessionStart(startup|clear)`: assemble the frame in memory via
  `load-handoff.sh` (header + inlined task file) and inject it via
  `additionalContext`.
  `PreToolUse(Write|Edit)`: deny any direct agent Write/Edit to
  `handoff-task.md` — it is checkpoint-only (FR3) — and deny writes whose
  resolved path is not `$cwd/.claude/<file>` (cross-project guard).
  `PostToolUse(Write|Edit)`: stage `handoff-todo.md` for commit when the
  agent writes it directly; rename the session on an `autorename` write;
  validate an `autocompact` write.
  `PostToolUse(Bash)`: consume `.claude/checkpoint-manifest` after
  `handoff-checkpoint` runs — stage every listed path (deletions included)
  and spawn the rename watcher for a checkpoint-written `autorename`.
  `Stop`: arm the compaction when `.claude/autocompact` exists.
  `SessionStart(compact)`: fire the continuation prompt after a
  compaction completes.
- `scripts/load-handoff.sh` — SessionStart(startup|clear) entry
  point. Gates on `.claude/handoff-task.md`, assembles the frame in
  memory (a timestamp header plus the inlined task file), and emits it
  via `hookSpecificOutput.additionalContext` (agent-facing) plus a curt
  `systemMessage` with bytes + age (user-facing). Silent no-op when
  the task file is missing or empty.
- `scripts/_lib.sh` — sourced helper for the write hooks and
  `bash-post.sh`. Defines the `HANDOFF_REL_*` path constants and
  `handoff_resolve()`, which canonicalizes multiple paths in one `python3`
  subprocess (GNU/BSD `realpath` are incompatible; python is portable and
  amortizes startup). Also defines
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
  by all watcher-spawning hooks (setsid is Linux-only; nohup is the
  macOS fallback) — `rename-when-idle.sh` (from both `write-rename.sh` and
  `bash-post.sh`) and both compaction watchers.
  There is no more transcript-scraping activation predicate: with
  `handoff-task.md` written only by the checkpoint (FR3), there is no
  "before/after activation" distinction left to detect. See
  `docs/changelog/2026-07-27-one-channel-one-writer.md`.
- `scripts/write-guard.sh` — PreToolUse(Write|Edit) guard. Denies any
  direct agent Write/Edit to `handoff-task.md` unconditionally — it is
  checkpoint-only (FR3) — and denies writes whose resolved path is not
  `$cwd/.claude/<file>` (cross-project misfires). No longer covers
  `handoff-todo.md`, which the agent is meant to edit directly (FR4).
- `scripts/rename-when-idle.sh` — detached watcher. Polls for the Claude TUI
  spinner to be absent (idle), checks the user isn't composing, then fires
  `tmux send-keys -l` to type `/rename <title>` + Enter. Verifies the rename
  landed (status bar) and retries up to 3×. Spawned by `write-rename.sh`;
  outlives the agent turn. Both non-delivery paths — the composing-bail and
  three failed verifies — end in `watcher_fail`, so neither is silent. The bail
  is the shape `docs/changelog/2026-07-22-rename-watcher-failure-channel.md`
  calls indistinguishable from success: it used to
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
  `is_busy` would false-fail it. The count keys on structural flags (isMeta,
  isCompactSummary, isSidechain) rather than content, and is baselined before
  the first Enter, so neither a
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
  watcher stays ignorant of the layout. Fires only for the `/handoff:autoname`
  path, which still writes `autorename` with the Write tool; `bash-post.sh`
  covers the same file when `handoff-checkpoint` writes it from Bash instead,
  sharing the watcher-spawn body but not this hook.
- `scripts/write-stage.sh` — PostToolUse(Write|Edit) entry point: matches
  writes/edits that resolve to `$cwd/.claude/handoff-todo.md` — the one path
  the checkpoint never sees, since the agent edits that scratch list directly
  all session (FR4). Stages the file with `git add -f`, or — via
  `checkpoint_is_empty_body` from `_checkpoint-lib.sh` — removes it and stages
  the removal when the edit left it with no substantive content (a `##
  Remaining` with no items). `handoff-task.md` no longer takes this path; it
  is checkpoint-only (FR3) and staged via the manifest instead.
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
  `autocompact` would race a live `SessionStart(compact)`. See
  `docs/changelog/2026-07-22-stale-autocompact.md`.
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
- `bin/handoff-checkpoint` — PATH-resident shim (Claude Code adds each
  plugin's `bin/` to PATH) that execs `scripts/checkpoint.sh`. Both skill
  bodies invoke it by bare name; `${CLAUDE_PLUGIN_ROOT}` is not available in
  the agent's Bash, so the shim is the entry point. Replaces
  `bin/handoff-memory-probe` and `bin/handoff-precompact-probe`.
- `scripts/checkpoint.sh` — the one write path for the handoff/precompact
  wrap-up (FR1). Reads the JSON payload on stdin, validates it against the
  schema (FR2 — a violation exits 2 naming the offending field on stderr),
  applies the `task`/`todo` Write-or-Edit forms (FR5; `task` is Write-form-
  or-null only), removes a file whose resulting body is empty via
  `checkpoint_is_empty_body` (FR6), writes `.claude/checkpoint-manifest` —
  always, even with zero lines, so `bash-post.sh`'s presence-gate still
  fires for a rename-only call — and `.claude/autorename` when `rename` is
  present (FR8), then prints the same directive output the two probes it
  replaced used to (FR9, via `_checkpoint-lib.sh`). NFR1: it does no `git`
  or `tmux` work itself — see `bash-post.sh`. The Edit form's exact string
  replacement (first occurrence, error if `old_string` is absent or
  ambiguous) is applied by a `python3` heredoc, not shell, so a multi-line
  `old_string`/`new_string` needs no quoting.
- `scripts/_checkpoint-lib.sh` — sourced helper for `checkpoint.sh` and, for
  `checkpoint_is_empty_body`, `write-stage.sh`. Renamed from `_probe-lib.sh`;
  `probe_*` functions became `checkpoint_*`, unchanged in content and
  composition order (FR9) — only the commit-awareness mode's source moved
  from a positional CLI argument (`probe_require_mode`, now gone; the
  literal-value check is inline JSON validation in `checkpoint.sh`) to a
  payload field.
  `checkpoint_is_empty_body` is FR6's generic emptiness test: strips heading
  (`#`) and blank lines, and what remains decides — a `## Remaining` with no
  items or a task file with headings and no content both count as empty.
  Shared by `checkpoint.sh` (after a Write/Edit it just applied) and
  `write-stage.sh` (after the agent's own direct edit to `handoff-todo.md`)
  so the two writers cannot drift on what counts as empty.
  `checkpoint_memory_directive` gates on the `gitlore-memory` submodule
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
  checkpoint, and "once approved" already places the write after them.
  Neither skill body states it either: approval is a feedback loop that
  routinely edits memory, so a rule pinning memory as final forbids what
  the gate is for. What is left is one act plus one clause saying this
  turn's commit carries the memory, so its absence is not read as a failure.
  Mechanism a reader cannot act on gets verified and narrated instead.
  That file-trigger IPC replaced the old
  `git config gitlore.commitCommand` + `commit-memory.sh -F -` Bash path:
  all file writes, so it sidesteps the sandbox and the auto-mode classifier.
  Couples only to the two IPC filenames — never gitlore internals.
  `checkpoint_ledger_path` is the one-row registry of known workflow-owned
  progress ledgers (currently superpowers SDD), so the nudge and the
  suppression can never disagree about what exists — and both interpolate
  what it prints, because with a glob there is no path to hardcode. It
  detects **liveness**, not presence: a match under
  `.superpowers/sdd/*/progress.md` counts only with SDD's identity first
  line, the pre-6.2.0 flat path never counts, and among several the
  most-recently-modified wins. See
  `docs/changelog/2026-07-26-orphaned-ledger.md`. `checkpoint_sdd_directive`
  holds the structured-workflow ledger nudge (precompact only) and ends by
  standing `handoff-todo.md` down; `checkpoint_todo_suppression` is that
  stand-down alone, for the handoff path — composed in
  `checkpoint.sh`'s `skill: "handoff"` vs `skill: "precompact"` branch,
  memory first, same order the two deleted probes used.
- `scripts/bash-post.sh` — `PostToolUse(Bash)` entry point. Fires on every
  Bash call in every session with the plugin installed (NFR2), so the
  negative case (manifest absent, which is nearly every call) stays cheap:
  the raw session `cwd` from the hook payload is stat'd directly, and the
  worktree-aware root resolution (a `python3` spawn via `handoff_root`) is
  deferred to the rare positive path. When the manifest is present, stages
  every listed path with `git add -f` (deletions included), consumes
  `.claude/autorename` if present and spawns the rename watcher through the
  same helper `write-rename.sh` uses, then emits a dual-channel summary and
  deletes the manifest. This is where NFR1's git/tmux work happens instead
  of in the agent's sandboxed Bash — see
  `docs/changelog/2026-07-27-one-channel-one-writer.md`.
- `plugin-dev/` — vendored
  [claude-plugin-dev](https://github.com/ddaanet/claude-plugin-dev)
  toolkit (currently `v0.5.0`). Provides:
  - `release.just` — shared `release` recipe imported by the top-level
    justfile, a thin front for `release.sh`. Owns version bumps, tagging,
    push, GH release, and the marketplace bump in `$MARKETPLACE_DIR`. It
    depends on the plugin's own `prerelease` recipe, which here is just
    `precommit`. Two companions: `resume-release` completes a release that
    died partway (pushes whatever is missing, no-op when everything landed,
    no gate), and `check-version` reports whether `plugin.json` and the
    marketplace entry agree.
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
- `docs/design.md` — living design document: current architecture, standing
  decisions, rejected alternatives. Present tense, no dated entries.
- `docs/changelog.md` — the index: one line per design change, newest first,
  `- [<date> — Title](changelog/<file>.md) — hook (vX.Y.Z)`, the version only
  when the entry maps onto one release.
- `docs/changelog/` — one file per design change, dated, holding the full
  write-time reasoning: the defect, the alternatives weighed, what was
  believed at the time. Never edited after the fact; a later change that
  reverses one heads the affected section with a
  `> **Superseded <date>** (see [<title>](<sibling>.md))` blockquote, scoped
  to what actually changed. A design change adds a file here plus its index
  line, and rewrites whatever `docs/design.md` prose it invalidates — all
  three in the same pass, not as an optional follow-up. Appending a dated
  subsection to the design doc instead was the earlier rule, and it grew
  that file to 2036 lines / 113 KB of mostly superseded machinery.
- `plans/` — prospective content: specs, design proposals, implementation
  plans. Anything describing work not yet done, or describing how something
  was built rather than what it is. Write-time records like `docs/changelog/`
  entries, so they are not revised as the code moves past them.

## Conventions

- Use `${CLAUDE_PLUGIN_ROOT}` in `hooks.json` for portability.
- All hooks are mechanical and cwd-scoped. They anchor on `handoff_root`
  (the enclosing git-worktree root, else `CLAUDE_PROJECT_DIR`) — never on the
  raw hook-input `.cwd` (drift-prone) nor on `CLAUDE_PROJECT_DIR` directly
  (pinned to the main tree in a worktree session). Anything that requires
  judgement belongs in the skill, not a hook.
- Keep the skill body lean (≤2000 words); move detailed rationale to
  references or `docs/design.md`.
- Output paths: `.claude/handoff-task.md` (checkpoint-only, FR3) and
  `.claude/handoff-todo.md` (agent-editable scratch list, FR4), both
  git-tracked via `git add -f` (listed in `.gitignore` so only a hook adds
  them — the manifest for the task file, `write-stage.sh` for the todo
  file). Changing either's shape is a breaking change and requires a
  version bump.
- Both markdown templates live in `SKILL.md` (single source of truth).
  Neither loader re-states them — each file carries its own `##` headings
  and is inlined verbatim under the one `#` header the frame prepends.
- `handoff-todo.md` holds **open items only**. A finished item is dropped,
  never checked off: what landed is reconstructable from `git log`, and a
  done item still listed reads as outstanding and gets redone.
- Sourced helpers (`_lib.sh`, `_checkpoint-lib.sh`) need
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
  tests/checkpoint.bats`: end-to-end test of the handoff-specific hook
  scripts (and the rename scripts) against synthetic tool-event payloads. `bats run` captures
  exit codes/output without the `set +e` dance. `version-guard.sh` is
  tested in the toolkit, not here.
  `hook-test.bats` stubs `tmux` on `PATH` in `setup()` and shortens the
  `HANDOFF_WATCHER_*` tunables. Hooks it exercises that spawn a detached
  watcher rely on this, since `TMUX=fake` does not stop tmux falling back to
  the default socket — unstubbed, those watchers drive a real pane belonging
  to whoever is running the suite.
  `tests/checkpoint.bats` covers `scripts/checkpoint.sh`, `bin/handoff-checkpoint`,
  and `scripts/bash-post.sh` (merged from the deleted
  `tests/memory-probe.bats` + `tests/precompact-probe.bats`, over the shared
  `tests/probe-helpers.bash` fixtures). Carries forward the commit-awareness
  contract in full — the mode's four combinations with memory state, and the
  composed memory-then-SDD ordering under `skill: "precompact"` vs its
  absence under `skill: "handoff"` — plus the ledger-liveness matrix (flat
  path, unidentified workspace, several-workspaces mtime tiebreak). The
  load-bearing assertion is the negative — `with-commit` output never
  mentions the trigger file — and it is mutation-checked (disable the
  branch, watch it go red), not observed passing. New: schema validation
  (each required field missing, each literal with an unknown value, `rename`
  under `precompact`, `content`+`old_string` together, a partial Edit,
  `file_path` outside `$root/.claude/`, malformed JSON — each asserting a
  non-zero exit and that the message names the field), Edit application
  (`old_string` absent, ambiguous, successful), empty-body removal through
  both writers (`checkpoint.sh` and `write-stage.sh`) including that the
  deletion reaches the manifest, and `bash-post.sh` (manifest absent,
  manifest present, `autorename` present).
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

## Frame assembly

Neither loader touches the transcript. The frame is a timestamp header
plus the inlined agent-authored `handoff-task.md` and `handoff-todo.md`
(task first; either alone is enough), assembled by `handoff_frame()` and
injected at both transitions — `load-handoff.sh` on `startup|clear`,
`load-compact.sh` on `compact`.
There is no session id, no files-touched list, and no verbatim prompt
transcript — the working set is the harness's own `gitStatus` block at
load time, and reproducing prior exchanges verbatim manufactured false
continuity. See
`docs/changelog/2026-07-17-task-frame-drops-transcript.md`.

## Non-goals

- Summarising the conversation. Extraction is deterministic; summary
  is already handled by `/compact`, Session Memory, and training.
- Validating markdown structure at write time. `handoff-checkpoint`
  validates the JSON envelope (FR2), not the markdown content inside it;
  the templates in `SKILL.md` are trusted, not schema-checked.
- Cross-session thread management. This plugin handles one `/clear`
  transition; auto-memory handles durable state.
