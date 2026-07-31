# Agent Instructions — handoff plugin

Plugin development conventions. Applies when working inside this repo
to edit the plugin's skill, hook, or script.

## Layout

High-level flow: the skill decides the task/todo/rename content, then issues
one `handoff-checkpoint` Bash call carrying the whole wrap-up as a
schema-validated JSON payload on stdin → `checkpoint.sh` writes
`.claude/handoff-task.md`/`.claude/handoff-todo.md`/`.claude/autodrive` (per
FR5/FR6 write semantics — a Write or Edit form, empty body ⟹ removed) and
leaves `.claude/checkpoint-manifest` behind, since staging can't run from the
agent's sandboxed Bash (NFR1) → `PostToolUse(Bash)` (`bash-post.sh`) consumes
the manifest and stages every listed path with `git add -f` (deletions
included) → `Stop` (`stop-drive.sh`) arms whatever transition the sentinel
describes → next session's `SessionStart(startup|clear)` assembles the frame
in memory (header + inlined task file) and injects it. `README.md` has the
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

**Two boundaries, four skills, one flow.** At each boundary a skill prepares
and a sibling also drives: `handoff`/`handoff-continue` for `/clear`,
`precompact`/`compact-continue` for `/compact`. All four route through the
same checkpoint call, discriminated by the payload's `skill` field, from which
`checkpoint.sh` derives the **boundary** — that is what keys the directive
composition (memory gate + todo suppression for clear, memory gate + SDD
ledger nudge for compact), so the pair at each boundary cannot drift. All four
can carry `task` — the durable side of the seam, content that must survive
verbatim — while the continuation prompt is only a handle to it.

The judgment is per-boundary, not per-drive-mode, so each boundary's full
protocol lives in one file (`handoff/SKILL.md`, `precompact/SKILL.md`) and the
driven skills are short bodies that run their sibling's protocol by reference
and then arm. What the driven skills add is `.claude/autodrive` with lines to
type; the prepare-only compact path arms the kind line alone (FR-G), which
types nothing but is what `SessionStart(compact)` gates the frame's
re-injection on. Every typed line goes through the detached walker spawned by
a hook at a turn boundary, never from inside a live turn. See
`docs/changelog/2026-07-29-driven-transitions.md`. `handoff-task.md` is written **only** by the checkpoint
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
- `skills/handoff/SKILL.md` — the clear boundary's full protocol
  (`/handoff:handoff`), and the single source of truth for the markdown
  templates of `handoff-task.md` and `handoff-todo.md`, plus the seam between
  what belongs in a file and what belongs in a continuation prompt (the seam
  lives here rather than in `precompact/SKILL.md` because both driven skills
  read this file). Its first step is the commit-awareness decision — is a
  commit going to carry this session's memory — which it passes to the
  checkpoint call and which makes it write memory as if the change has
  landed. Step 3 decides the title/task/remainder, then issues one
  `handoff-checkpoint` Bash call with the whole wrap-up as a JSON heredoc;
  step 4 follows whatever directive the checkpoint prints; step 5 reports what
  the boundary is ready for, in one line. Prepares only — it arms nothing.
- `skills/handoff-continue/SKILL.md` — the `/handoff:handoff-continue` skill.
  Runs `handoff`'s protocol by reference with `"skill": "handoff-continue"`
  and **no** `rename` (schema-forbidden — the title is a line of the
  sentinel), then writes `.claude/autodrive`: `clear`, `/rename <title>`,
  `/clear`, continuation prose. Carries the arming discipline `handoff` has no
  need of — never in the same turn as a question the directive requires, and
  the commit lands before the sentinel is written.
- `skills/autoname/SKILL.md` — the `/handoff:autoname` skill. Decides a
  session title from the conversation (no tool calls) and writes
  `.claude/autodrive` directly with the Write tool, two lines: `rename`, then
  `/rename <title>`. Rename-only — no task file, no memory. For `/btw` side
  conversations and any session worth a name while the main thread stays live.
- `skills/precompact/SKILL.md` — the compact boundary's full protocol
  (`/handoff:precompact`). Decide commit awareness (same first step as
  handoff), capture durable learnings in auto-memory, decide the task/todo
  content, run one `handoff-checkpoint` Bash call (`"skill": "precompact"`, no
  `rename` — schema-forbidden there), follow whatever directive it prints
  (memory commit and/or ledger flush), write `.claude/autodrive` containing
  the single line `compact` (FR-G's expectation marker), and report readiness
  in one line. Prepares only: no compact directive, no continuation prompt, no
  keystrokes, no tmux.
- `skills/compact-continue/SKILL.md` — the `/handoff:compact-continue` skill.
  Runs `precompact`'s steps 1–3 by reference with
  `"skill": "compact-continue"`, then writes `.claude/autodrive`: `compact`,
  `/compact [directive]`, continuation prose. Carries the same arming
  discipline as `handoff-continue`, and the anti-patterns that used to forbid
  `precompact` from stopping short ("telling the user to run `/compact`";
  "invoking it is the authorization to compact") live here now.
- `skills/handoff/references/design.md` — condensed design notes;
  full rationale is in `docs/design.md`
- `hooks/hooks.json` — declares nine hooks.
  `SessionStart` (every source, wildcard matcher): publish this session's
  resolved root at `/tmp/claude/handoff-root-<session_id>` via
  `session-pointer.sh`, so the agent's own Bash can reach it.
  `SessionStart(startup|clear)`: assemble the frame in memory via
  `load-handoff.sh` (header + inlined task file) and inject it via
  `additionalContext`; on `clear`, also consume an armed transition of kind
  `clear` and spawn the walker for its after-line.
  `PreToolUse(Write|Edit)`: deny any direct agent Write/Edit to
  `handoff-task.md` — it is checkpoint-only (FR3) — and deny writes whose
  resolved path is not `$cwd/.claude/<file>` (cross-project guard).
  `PostToolUse(Write|Edit)`: stage `handoff-todo.md` for commit when the
  agent writes it directly; validate an `autodrive` write.
  `PostToolUse(Bash)`: consume `.claude/checkpoint-manifest` after
  `handoff-checkpoint` runs — stage every listed path (deletions included).
  `Stop`: arm the transition when `.claude/autodrive` exists.
  `SessionStart(compact)`: re-inject the frame and fire the continuation
  prompt after a compaction completes.
  `UserPromptSubmit`: report a non-delivery, sweep a stale sentinel, and
  report a session cwd that has left the launch repo.
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
  Also defines `handoff_root_read()` — the effective handoff root for the
  session, plus the branch that produced it. `handoff_root_read "<.cwd>"`
  shells out to `worktree_root.py` and sets the caller's `HANDOFF_ROOT`
  (the enclosing worktree root or `CLAUDE_PROJECT_DIR`) and
  `HANDOFF_ROOT_BRANCH` (`inside`, `worktree`, `foreign`, `unrelated` — the
  last two are drift). Caller-scope globals in the `handoff_drive_read`
  idiom, because `handoff_root()`, the printing form every other caller
  uses, is invoked inside a `$(...)` where a global would die with the
  subshell; `handoff_root()` still prints the root alone, one line. Every
  cwd-scoped hook anchors on this rather than `CLAUDE_PROJECT_DIR` directly,
  so worktree sessions resolve to their own `.claude/`. An empty or
  project-root cwd short-circuits in bash (mirroring `worktree_root.py`'s
  trivial branches) so the every-turn hooks (`Stop`, `UserPromptSubmit`)
  skip the python3 spawn in the common case — and labels the branch itself,
  or a caller would read the previous resolution's label.
  `HANDOFF_POINTER_DIR` (`/tmp/claude`, overridable for tests) and
  `handoff_pointer_path()` address the session root pointer: a literal
  directory rather than `$TMPDIR`, since its producer is a hook and its
  consumer the agent's sandboxed Bash, and the two share no environment but
  the session id.
  `handoff_match_target()` is the shared preamble of every path-scoped
  hook: one call does the jq field parse, basename fast-path, root
  resolution, and resolved-path comparison against the expected
  `$cwd/<rel>`, distinguishing "other file" (rc 1) from "basename matched
  but cross-project" (rc 2, which only `write-guard.sh` denies). It is
  variadic over (basename, rel) pairs and sets `MATCHED_NAME` — the guards
  cover two files, and the jq parse is on the Write/Edit hot path, so N
  files must stay one parse.
  `handoff_drive_read()` parses and validates the sentinel into `DRIVE_KIND`,
  `DRIVE_BEFORE[]`, `DRIVE_AFTER[]` — or `DRIVE_ERR` naming the constraint that
  failed. Line 1 is the kind and the kind fixes the shape, so the remaining
  lines need no separator: `rename` takes 2 lines, `compact` 3 or the kind line
  alone (FR-G), `clear` 4. Each command literal is pinned to its slot, so the
  file cannot be made to type something else, and a prose line may not begin
  with `/` — the walker dispatches on the leading character, and a prose line
  that looked like a command would be confirmed by the wrong primitive. Read
  with a `read` loop, not `mapfile` (bash 3.2 has none), and for the same
  vintage callers must expand the arrays as `${DRIVE_BEFORE[@]+"${DRIVE_BEFORE[@]}"}`.
  `handoff_drive_has_source()` says whether a kind's transition is confirmed by
  a `SessionStart`; `rename` is not one, so `stop-drive.sh` deletes its sentinel
  outright rather than arming a `.pending` nobody would clear.
  `handoff_spawn_detached()` is the shared setsid-else-nohup detach used
  by every hook that spawns the walker (setsid is Linux-only; nohup is the
  macOS fallback) — `stop-drive.sh`, `load-compact.sh` and `load-handoff.sh`.
  There is no more transcript-scraping activation predicate: with
  `handoff-task.md` written only by the checkpoint (FR3), there is no
  "before/after activation" distinction left to detect. See
  `docs/changelog/2026-07-27-one-channel-one-writer.md`.
- `scripts/write-guard.sh` — PreToolUse(Write|Edit) guard. Denies any
  direct agent Write/Edit to `handoff-task.md` unconditionally — it is
  checkpoint-only (FR3) — and denies writes whose resolved path is not
  `$cwd/.claude/<file>` (cross-project misfires). No longer covers
  `handoff-todo.md`, which the agent is meant to edit directly (FR4).
- `scripts/drive-when-idle.sh` — the one detached watcher: the walker.
  Spawned by `stop-drive.sh` for the lines typed before a transition, and by
  the transition's own `SessionStart` loader for the lines typed after it. One
  argument per line, and the lines are the literal keystrokes — it never learns
  which command belongs to which kind. Per line: `wait_for_idle`, bail if
  `is_typing`, `send-keys -l`, then a `VERIFY_DELAY` gap that is the
  recognition read-back for a `/` line and the paste-window settle for prose,
  then confirm by the command's own primitive. A line that fails to confirm
  ends the sequence, so a `/rename` that never lands under kind `clear` costs a
  wrong title and nothing more. The re-gate at the top of each iteration is
  FR-H: confirming a line can take `CONSUME_TIMEOUT` (300s) and the pane is
  live throughout.
- `scripts/_watcher-lib.sh` — sourced helper for the walker. Defines `is_busy`
  (spinner present), `is_typing` (prompt has content) and `is_unknown_command`
  over captured tmux pane text — pure predicates, tested directly in
  `tests/watcher-test.bats`. Also the shared scaffold: the `HANDOFF_WATCHER_*`
  tunables, `snap` (visible-pane capture — never scrollback), `wait_for_idle`
  (stable-idle poll loop), and the three confirmation primitives, none of which
  reads the pane. `_submit_until` is their shared body: Enter, three fast
  retries at `VERIFY_DELAY` (the first Enter can be absorbed into the paste
  window as a line break), then a long poll without resending, since a
  registered Enter can take far longer than `VERIFY_DELAY` to reach the signal.
  `submit_consumed` waits for `$HANDOFF_PENDING_FILE` (exported by the spawning
  hook) to disappear, which the confirming `SessionStart` is what does —
  confirming the transition rather than the keystroke. `is_busy` was the
  original criterion and false-fails here: the TUI shows no matching chrome in
  the ~1.5s after the keystroke, so a live 103-second compaction was reported as
  never submitted. The trade is latency, since a real non-delivery now waits out
  `CONSUME_TIMEOUT`; with no file to confirm against it returns success, because
  an unconfirmable submit is not a failed one. `submit_prompted` +
  `transcript_prompt_count` confirm prose via the session transcript
  (`$HANDOFF_TRANSCRIPT`, exported by the spawning hook): prose fires into a
  post-transition settle where a submit is *queued* (accepted, transcript-logged
  at once) but shows no spinner until the queued turn starts seconds later, so
  `is_busy` would false-fail it. The count keys on structural flags (isMeta,
  isCompactSummary, isSidechain) rather than content. `submit_titled` +
  `transcript_title_count` confirm a `/rename` by an exact `customTitle` match
  on a `custom-title` entry — the harness's own auto-titling writes `ai-title`,
  a distinct type, so it cannot false-positive; this retired the last
  pane-reading confirmation, a grep for the title's first 20 characters that
  matched whenever the title was on screen for any other reason. All three
  baseline before the first Enter, so a stale pre-transition copy never reads as
  a submit. All three **return** rather than exit: the walker owns failure for
  the whole sequence and calls `watcher_fail` once, at the top — which records a
  non-delivery reason to `$HANDOFF_FAIL_FILE` (set by the spawning hook, which
  owns the path) and exits 1; unset is tolerated.
- `scripts/write-stage.sh` — PostToolUse(Write|Edit) entry point: matches
  writes/edits that resolve to `$cwd/.claude/handoff-todo.md` — the one path
  the checkpoint never sees, since the agent edits that scratch list directly
  all session (FR4). Stages the file with `git add -f`, or — via
  `checkpoint_is_empty_body` from `_checkpoint-lib.sh` — removes it and stages
  the removal when the edit left it with no substantive content (a `##
  Remaining` with no items). `handoff-task.md` no longer takes this path; it
  is checkpoint-only (FR3) and staged via the manifest instead.
- `scripts/write-drive.sh` — PostToolUse(Write|Edit) entry point for the
  transition driver. Matches writes resolving to `$cwd/.claude/autodrive` and
  **validates only**, via `handoff_drive_read`. Never spawns, never deletes —
  the file must survive to `Stop`. A malformed file gets a `systemMessage` plus
  an imperative `additionalContext` naming the constraint that failed, so the
  agent can fix it in the same turn instead of hitting a silent no-op at `Stop`;
  it deliberately does not restate the legal shapes, since the skill body that
  wrote the file is their source of truth. Path matching is the consume-time
  cross-project guard: no PreToolUse guard, no activation gate.
- `scripts/stop-drive.sh` — `Stop` entry point: arms the transition. Consumes
  the sentinel **before** spawning, so a later `Stop` in the same session
  cannot re-arm — `mv` to `.pending` for a kind with a confirming source, `rm`
  for `rename`, which no loader would ever clear. Then spawns the walker with
  the before-lines, exporting `HANDOFF_FAIL_FILE`, `HANDOFF_PENDING_FILE` and
  `HANDOFF_TRANSCRIPT` (this session's, from `Stop`'s own payload — what a
  `/rename` line confirms against): the hook owns the paths, the walker stays
  ignorant of the layout. An empty before-sequence (FR-G) arms the `.pending`
  and spawns nothing. Outside tmux it emits every line, before then after, for
  the user to paste in order — and it is the *single* producer of that
  pasteable form, which is why no skill body prints one. Silent no-op when the
  file is absent — `Stop` fires every turn. `Stop` does not fire on Esc, so an
  interrupted turn cannot arm a transition.
- `scripts/load-compact.sh` — `SessionStart(compact)` entry point: consumes
  `autodrive.pending` — which is itself the confirmation the walker was waiting
  on for the `/compact` line it typed — injects the task-file frame via
  `additionalContext` (`handoff_frame`; omitted when there is no task file),
  and spawns the walker for the after-line with the session `transcript_path`
  exported as `$HANDOFF_TRANSCRIPT`. Gates on `DRIVE_KIND == compact`: each
  loader consumes only its own kind, so a `clear` armed in this session and
  overtaken by a threshold auto-compaction is not consumed here.
  `source: "compact"` is the authoritative compaction-complete signal — no pane
  scraping. Silent when there is no pending file (auto-compaction fires the same
  hook), which is also what keeps a hand-typed `/compact` from re-injecting a
  days-old frame. Reading the task file does not consume it.
- `scripts/report-watcher-failure.sh` — `UserPromptSubmit` entry point:
  reconciles the armed-transition state at the start of a turn.
  It consumes `.claude/autodrive.failed` — one channel now, since the
  transition is a singleton — and reports the reason on both channels, also
  clearing a stranded `autodrive.pending`. The detached walker's exit status is
  read by nothing, so that file is its only path back to the agent — most of all
  on the recognition abort, which wipes the composer and leaves the pane looking
  untouched. `UserPromptSubmit` rather than `Stop` because the walker runs
  *after* the Stop that spawned it. Reports only what the walker observed
  itself; a stale `.pending` alone is never treated as failure (it is legitimate
  for the whole Stop → transition window).
  It also reports **session-root drift** — a cwd whose branch is `foreign` or
  `unrelated`, meaning it has left the launch repo while the root and every
  handoff file under it have not. Here rather than at a later gate because
  drift can be transient, and this hook resolves the root every turn anyway.
  One report per episode: `/tmp/claude/handoff-drift-<session_id>` holds the
  destination last announced, so a second turn in the same place is silent, a
  move elsewhere is not swallowed, and returning clears the marker so a
  re-drift is a new episode. Its `systemMessage` leads with an ANSI style
  reset — this hook speaks only when something went wrong, and the chatter
  around it renders dimmed.
  It also sweeps a bare `.claude/autodrive`: the file is armed at the `Stop`
  of the turn that writes it and renamed or removed, so one still present when a
  later turn begins never armed, and would otherwise be armed by the next
  `Stop` — days later, possibly in another session. `UserPromptSubmit` is the
  exact discriminator; it cannot fire between the write and that turn's own
  `Stop`. Only the failure branch touches `.pending` — sweeping it on a stale
  sentinel would race a live `SessionStart(compact|clear)`. See
  `docs/changelog/2026-07-22-stale-autocompact.md`.
- `scripts/worktree_root.py` — pure resolver `worktree_root(cwd, project)`:
  walks up from the session cwd via on-disk `.git` linkage to the enclosing
  linked-worktree root, else returns `project`. Returns `(root, branch)` and
  the CLI prints both, one per line; containment wins over the branch the walk
  took, so a submodule or vendored checkout inside the project is `inside`
  rather than `foreign` (or `cd memory/` would read as drift). Backs `_lib.sh`'s
  `handoff_root_read`; lets each worktree own its `.claude/`. Unit-tested in
  `tests/test_worktree_root.py` (pytest).
- `scripts/session-pointer.sh` — `SessionStart` entry point on the wildcard
  matcher (the only hook that reaches `resume`): writes the resolved root as
  one line at `/tmp/claude/handoff-root-<session_id>`. Its own script rather
  than a preamble on the two loaders because the write must be unconditional
  and both of those are gated. Silent no-op without a session id.
- `bin/handoff-checkpoint` — PATH-resident shim (Claude Code adds each
  plugin's `bin/` to PATH) that execs `scripts/checkpoint.sh`. Both skill
  bodies invoke it by bare name; `${CLAUDE_PLUGIN_ROOT}` is not available in
  the agent's Bash, so the shim is the entry point. Replaces
  `bin/handoff-memory-probe` and `bin/handoff-precompact-probe`.
- `scripts/checkpoint.sh` — the one write path for the handoff/precompact
  wrap-up (FR1). Takes its root from the pointer `session-pointer.sh`
  published, keyed by `CLAUDE_CODE_SESSION_ID`, and refuses when there is
  none: it runs in the agent's Bash, where `CLAUDE_PROJECT_DIR` is unset and
  the old fallback to `$PWD` wrote one repo's handoff files while every reader
  stayed in the other. Reads the JSON payload on stdin, validates it against
  the schema (FR2 — a violation exits 2 naming the offending field on stderr),
  applies the `task`/`todo` Write-or-Edit forms (FR5; `task` is Write-form-
  or-null only), removes a file whose resulting body is empty via
  `checkpoint_is_empty_body` (FR6), writes `.claude/checkpoint-manifest` —
  always, even with zero lines, so `bash-post.sh`'s presence-gate still
  fires for a rename-only call — and `.claude/autodrive` when `rename` is
  present (FR8), as the two-line `rename` kind, flattening the title's
  whitespace on the way (`bash-post.sh` used to do that at consume time, and
  there is no consumer left to). `rename` is required under `skill: "handoff"`
  and forbidden under the other three, which is the whole reason the enum has
  four values rather than two: it makes a `handoff` call that forgot its title
  an error rather than a silent non-rename. Then it prints the directive output
  (FR9, via `_checkpoint-lib.sh`), composed on the **boundary** derived from
  `skill`, not on `skill` itself. NFR1: it does no `git`
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
  then emits a dual-channel summary and deletes the manifest. Staging is all it
  does: a sentinel the checkpoint wrote is armed at `Stop` like any other, so
  consuming it here would spawn the walker mid-turn, which is the one thing the
  `Stop` gate exists to prevent. This is where NFR1's git/tmux work happens instead
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
- `just hook-test` — `bats tests/hook-test.bats tests/watcher-test.bats
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
  manifest present, a sentinel left untouched). The `skill` enum's four values
  each accepted, `rename` rejected under each of the three that forbid it, the
  boundary derivation asserted through the directive output, and the
  load-bearing negative — `handoff-continue` writes no sentinel — mutation-
  checked rather than observed passing.
  Session-root drift is covered across all three: `tests/test_worktree_root.py`
  for the branch matrix (including the containment rule that keeps a submodule
  `inside`), `tests/hook-test.bats` for `handoff_root_read`'s labels, the fast
  path labelling its own branch, `session-pointer.sh`, and the drift report's
  episode semantics, and `tests/checkpoint.bats` for the pointer refusals plus
  the load-bearing negative — a drifted cwd gets nothing written into its
  `.claude/`, mutation-checked against the old `$PWD` fallback.
  The compaction driver is covered in the two existing suites rather than a
  new file: `tests/hook-test.bats` for the `handoff_drive_read` shape matrix,
  `write-drive.sh` / `stop-drive.sh` / `load-compact.sh` / `load-handoff.sh` on
  `source: "clear"` / `report-watcher-failure.sh`, and `tests/watcher-test.bats`
  for the walker, the pane predicates,
  `transcript_title_count`, and the `watcher_fail` recording. Two rows there are
  load-bearing and mutation-checked: the FR-H re-idle gate, asserted on the
  *delay* between two literal sends rather than on suppression (`wait_for_idle`
  falls through on timeout by design, so a busy pane is typed into eventually),
  and that the confirmation primitives return rather than exit. The same holds
  for `load-handoff.sh`'s ordering hazard — a driven clear with an empty task
  file must still continue, so the consume and the spawn precede the no-frame
  exit.
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
