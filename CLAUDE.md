# Agent Instructions — handoff plugin

Plugin development conventions. Applies when working inside this repo
to edit the plugin's skill, hook, or script.

## Layout

High-level flow: the skill decides the task/todo/rename content, then issues
one `handoff-checkpoint` Bash call carrying the whole wrap-up as a
schema-validated JSON payload on stdin → `checkpoint.py` writes
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

**Two boundaries, two skills, one flow.** One skill per boundary — `handoff`
for `/clear`, `precompact` for `/compact` — and the `skill` field names it,
which is also what keys the directive composition (memory gate + todo
boundary for clear, memory gate + SDD ledger nudge for compact). Both carry
`task`, the durable side of the seam: content that must survive verbatim,
while the continuation prompt is only a handle to it.

Whether the transition is typed is a **field of the payload**, not a skill of
its own: `clear` (bool) at one boundary, `compact` (bool or focus directive)
at the other, plus `continue` (null or one line of prose) at both. All three
are required with no default. The judgment was always per-boundary — commit
awareness, memory capture, the drafting rules and the seam are identical
either way — so a separate driven skill per boundary bought nothing and cost
routing, duplicated prose, and a cross product it could not express (a driven
transition with no continuation). `checkpoint.py` composes `.claude/autodrive`
from those fields and reads it back through `handoff_drive_read`, so the
composer and the parser cannot drift; `compact: false` still writes the
two-line expectation marker (FR-G), which types nothing but is what
`SessionStart(compact)` gates the frame's re-injection on. Every typed line
goes through the detached walker spawned by a hook at a turn boundary, never
from inside a live turn. See
`docs/changelog/2026-08-05-transitions-become-modes.md` and
`docs/changelog/2026-07-29-driven-transitions.md`. `handoff-task.md` is written **only** by the checkpoint
(FR3), and so is the sentinel — `autoname` is a third `skill` value on the same
call rather than a Write from a template in its skill body, which leaves one
producer for a file whose composer reads its own output back through the
parser. A direct agent Write/Edit to either is denied outright by
`write-guard.sh`. See
`docs/changelog/2026-08-09-one-writer-for-the-sentinel.md`.

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
  (`/handoff:handoff`), driven or not, and the single source of truth for the
  markdown templates of `handoff-task.md` and `handoff-todo.md`, plus the seam
  between what belongs in a file and what belongs in a continuation prompt
  (the seam lives here rather than in `precompact/SKILL.md` because that file
  reads this one). Step 1 decides all three fields the payload cannot derive:
  whether the transition is typed, whether a continuation follows it, and
  commit awareness — **does the ask this call serves imply a commit** — which
  makes it write memory as if the change has landed. Step 3 decides the
  title/task/remainder, then issues one `handoff-checkpoint` Bash call with
  the whole wrap-up as a JSON heredoc; step 4 follows whatever directive the
  checkpoint prints, which may be the one naming `handoff-approved`; step 5
  reports what the boundary is ready for, in one line. It writes no sentinel
  itself — the checkpoint composes it.
- `skills/autoname/SKILL.md` — the `/handoff:autoname` skill. Decides a
  session title from the conversation (no tool calls), then runs one
  `handoff-checkpoint` Bash call whose whole payload is
  `{"skill": "autoname", "rename": "<title>"}`. Rename-only — no task file, no
  memory, no transition — and every other field is schema-forbidden there,
  which is also what keeps the memory directive from being composed for a call
  whose description promises no memory write. It writes no sentinel itself; the
  checkpoint composes the same `rename` kind it composes for an untyped
  `handoff`. For `/btw` side conversations and any session worth a name while
  the main thread stays live. See
  `docs/changelog/2026-08-09-one-writer-for-the-sentinel.md`.
- `skills/precompact/SKILL.md` — the compact boundary's full protocol
  (`/handoff:precompact`), driven or not. Decide the same three fields as
  handoff's step 1 (`compact` carries the focus directive when there is one),
  capture durable learnings in auto-memory, decide the task/todo content, run
  one `handoff-checkpoint` Bash call (`"skill": "precompact"`, no `rename` —
  schema-forbidden there), follow whatever directive it prints (memory commit,
  ledger flush, and/or the arming instruction), and report readiness in one
  line. It defers the templates and the seam rules to `handoff/SKILL.md` and
  writes no sentinel itself.
- `skills/handoff/references/design.md` — condensed design notes;
  full rationale is in `docs/design.md`
- `skills/restart/SKILL.md` — the `/handoff:restart` skill. Decides only
  whether a continuation prompt follows the resume (no tool calls), then runs
  one `handoff-checkpoint` Bash call whose whole payload is
  `{"skill": "restart", "continue": "<prompt>"|null}`. Neither boundary — no
  title, no task file, no todo, no commit awareness — and every boundary
  field is schema-forbidden there, the same key-presence rule `autoname`
  uses; no directive is composed either, for the same reason. The session id
  and the argv to replay are filled in downstream (`checkpoint.py` from
  `CLAUDE_CODE_SESSION_ID`, `stop-drive.sh` from the exiting process's own
  cmdline), not decided here. For a mid-session plugin upgrade, a `hooks.json`
  edit, or any other frozen-at-startup config that only a relaunch adopts —
  `--resume` carries the conversation over whole, so this costs no context.
  See `docs/changelog/2026-08-10-restart-transition-kind.md`.
- `hooks/hooks.json` — declares twelve hooks.
  `SessionStart` (every source, wildcard matcher): re-arm the context-size
  nudge and sweep this plugin's stale files at `$HANDOFF_POINTER_DIR` via
  `session-pointer.sh`.
  `SessionStart(startup|clear)`: assemble the frame in memory via
  `load-handoff.sh` (header + inlined task file) and inject it via
  `additionalContext`; on `clear`, also consume a transition in state `pending`
  of kind `clear` and spawn the walker for its after-line.
  `PreToolUse(Write|Edit)`: deny any direct agent Write/Edit to
  `handoff-task.md` (checkpoint-only, FR3) or to `autodrive` (composed by the
  checkpoint, which reads its own output back) — and deny writes whose
  resolved path is not `$cwd/.claude/<file>` (cross-project guard).
  `PreToolUse(Bash)`: match a `handoff-checkpoint`/`handoff-approved`
  invocation and inject this session's resolved root into it as
  `HANDOFF_ROOT`, via `inject-checkpoint-root.sh`, since neither entry point
  can resolve it itself.
  `PostToolUse(Write|Edit)`: stage `handoff-todo.md` for commit when the
  agent writes it directly.
  `PostToolUse(Bash)`: consume `.claude/checkpoint-manifest` after
  `handoff-checkpoint` runs — stage every listed path (deletions included).
  `PostToolBatch` (no matcher): measure this session's prompt size and nudge
  the boundary once it crosses a threshold, via `context-threshold.sh`.
  `Stop`: arm the transition when `.claude/autodrive` is in state `armed`.
  `SessionEnd`: confirm a `restart`'s `/exit` line by writing
  `.claude/autodrive.exited`, via `session-end.sh`.
  `SessionStart(compact)`: re-inject the frame and fire the continuation
  prompt after a compaction completes.
  `SessionStart(resume)`: consume a `pending` `restart` and fire its
  continuation, via `load-restart.sh` — no frame, since `--resume` already
  restores the conversation whole.
  `UserPromptSubmit`: report a non-delivery, sweep a stale sentinel, and
  report a session cwd that has left the launch repo.
- `scripts/load-handoff.sh` — SessionStart(startup|clear) entry
  point. Gates on `.claude/handoff-task.md`, assembles the frame in
  memory (a timestamp header plus the inlined task file), and emits it
  via `hookSpecificOutput.additionalContext` (agent-facing) plus a curt
  `systemMessage` with bytes + age (user-facing). Silent no-op when
  the task file is missing or empty.
- `scripts/load-restart.sh` — `SessionStart(resume)` entry point: consumes a
  `restart` sentinel in state `pending` and fires its continuation, exactly
  like `load-compact.sh`'s after-line handling, but assembles and injects no
  frame at all — `--resume` already restores the full prior conversation, so
  there is nothing for a frame to hand a summariser's paraphrase back to.
  Silent when nothing is pending (a hand-typed `--resume` fires the same
  hook) or when the pending file is another kind's.
- `scripts/session-end.sh` — `SessionEnd` entry point: writes
  `.claude/autodrive.exited` when a `restart` sentinel is `pending` —
  otherwise silent, since this fires on every session end. The opposite
  polarity of `.claude/autodrive.failed`: created, never removed by this
  hook, and `stop-drive.sh` clears any stale copy before spawning the walker
  so an earlier, only-partly-successful restart cannot false-positive a
  later one's `/exit` confirmation.
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
  `HANDOFF_POINTER_DIR` (`/tmp/claude`, overridable for tests) holds this
  plugin's remaining state outside a project — the context-size marker and
  the drift marker — a literal directory rather than `$TMPDIR`, since its
  writers are hooks and one reader is the agent's sandboxed Bash, which
  shares no environment with them but the session id. It used to also hold a
  session-keyed root pointer (`handoff_pointer_path()`); that mechanism is
  gone (see `scripts/inject-checkpoint-root.sh` below), and the sweep in
  `session-pointer.sh` still cleans up whatever such files are left on disk.
  `handoff_match_target()` is the shared preamble of every path-scoped
  hook: one call does the jq field parse, basename fast-path, root
  resolution, and resolved-path comparison against the expected
  `$cwd/<rel>`, distinguishing "other file" (rc 1) from "basename matched
  but cross-project" (rc 2, which only `write-guard.sh` denies). It is
  variadic over (basename, rel) pairs and sets `MATCHED_NAME` — the guards
  cover two files, and the jq parse is on the Write/Edit hot path, so N
  files must stay one parse.
  `handoff_drive_read()` parses and validates the sentinel into `DRIVE_STATE`,
  `DRIVE_OWNER`, `DRIVE_KIND`, `DRIVE_BEFORE[]`, `DRIVE_AFTER[]` — or
  `DRIVE_ERR` naming the
  constraint that failed. Line 1 is the state (`held`, `armed` or `pending`)
  and line 2 the kind, and the kind still fixes the shape, so the remaining
  lines need no separator; the counts are of the whole file, state line
  included: `rename` takes 3 lines, `compact` 2, 3 or 4, `clear` and `restart`
  each 4 or 5 — `restart`'s shape is `clear`'s exactly, `/exit` then
  `claude --resume <sid…>` in the two command slots. The
  continuation line is optional on both driven kinds — typing the transition
  and submitting a prompt into what it opens are separate decisions, and the
  payload carries them as separate fields. `held` alone carries an owner on
  line 1 (`held <session-id>`) — it is the one state that outlives the turn
  that wrote it, and the approval it waits on arrives in that session or not at
  all; `armed` and `pending` reject one rather than ignoring it. Both ends
  check it: `handoff-approved` refuses another session's held file, and
  `report-watcher-failure.sh` sweeps it as abandoned. The state is reported,
  never
  interpreted — which state a caller wants is
  the caller's business, and one answer serves the `Stop` gate, both loaders
  and the sweep. Each command literal is pinned to its slot, so the
  file cannot be made to type something else, and a prose line may not begin
  with `/` — the walker dispatches on the leading character, and a prose line
  that looked like a command would be confirmed by the wrong primitive. Read
  with a `read` loop, not `mapfile` (bash 3.2 has none), and for the same
  vintage callers must expand the arrays as `${DRIVE_BEFORE[@]+"${DRIVE_BEFORE[@]}"}`.
  `handoff_drive_has_source()` says whether a kind's transition is confirmed by
  a `SessionStart`; `rename` is not one, so `stop-drive.sh` deletes its sentinel
  outright rather than leaving a `pending` nobody would clear (`compact`,
  `clear` and `restart` all are).
  `handoff_resume_command()` composes the actual `claude --resume <sid>
  <argv…>` line `stop-drive.sh` types or pastes for a `restart`: the
  checkpoint can only supply the session id, not this process's own launch
  flags, so this reads them fresh from `/proc/<pid>/cmdline` (Linux; NUL-
  separated, so a value with an embedded space survives as one argument) or
  falls back to `ps -o command=` (macOS, no `/proc`; a known, accepted gap for
  that same case) and re-quotes each for replay.
  `HANDOFF_TEST_CMDLINE_PATH` substitutes a fixture file for the `/proc` path
  in tests, since `/proc` itself cannot be faked.
  `handoff_drive_arm()` rewrites line 1 into a new state, preserving every line
  below it — so it never has to know the kind's shape, which is what lets one
  helper serve `stop-drive.sh` and, in the next pass, `handoff-approved`. The
  replacement is atomic (sibling temp, then `mv`): both loaders and `Stop` parse
  this file and the walker stats it, so a half-written one must never be
  observable under the real name.
  `handoff_spawn_detached()` is the shared setsid-else-nohup detach used
  by every hook that spawns the walker (setsid is Linux-only; nohup is the
  macOS fallback) — `stop-drive.sh`, `load-compact.sh` and `load-handoff.sh`.
  There is no more transcript-scraping activation predicate: with
  `handoff-task.md` written only by the checkpoint (FR3), there is no
  "before/after activation" distinction left to detect. See
  `docs/changelog/2026-07-27-one-channel-one-writer.md`.
- `scripts/write-guard.sh` — PreToolUse(Write|Edit) guard over the two
  checkpoint-only files: `handoff-task.md` (FR3) and `autodrive`, the second
  (basename, rel) pair `handoff_match_target` takes. Denies any direct agent
  Write/Edit to either unconditionally, naming the one that matched via
  `MATCHED_NAME`, and denies writes whose resolved path is not
  `$cwd/.claude/<file>` (cross-project misfires). Its deny is what replaced
  `write-drive.sh`, the sentinel's `PostToolUse` validator: with no agent
  writer left, a second parser position had no subject, and the arm-only rule
  it enforced died with it. No longer covers `handoff-todo.md`, which the agent
  is meant to edit directly (FR4).
- `scripts/drive_when_idle.py` — the one detached watcher: the walker.
  Python since 2026-08-10 (see
  `docs/changelog/2026-08-10-python-split.md`); ported behavior-for-behavior
  from `drive-when-idle.sh`, spawned by `handoff_spawn_detached()` picking
  `python3` for its `.py` extension.
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
  A `claude --resume …` line (`restart`'s second command) is dispatched to
  `_drive_shell_line` instead, bypassing `wait_for_idle`/`is_typing`
  entirely: it targets a bare shell once `/exit` is confirmed, where neither
  exists nor would reliably signal readiness across every user's shell
  prompt. A fixed `HANDOFF_WATCHER_SHELL_SETTLE` stands in, then the same
  `submit_consumed` confirmation as `/compact`/`/clear`.
- `scripts/_watcher_lib.py` — imported helper module for the walker,
  ported from `_watcher-lib.sh`. Defines `is_busy`
  (spinner present), `is_typing` (prompt has content) and `is_unknown_command`
  over captured tmux pane text — pure predicates, tested directly in
  `tests/test_watcher_lib.py`. Also the shared scaffold: the `HANDOFF_WATCHER_*`
  tunables, `snap` (visible-pane capture — never scrollback), `wait_for_idle`
  (stable-idle poll loop), and the four confirmation primitives, none of which
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
  `submit_exited` confirms `/exit` by `$HANDOFF_EXIT_FILE` appearing (then
  consumes it) — the opposite polarity of `submit_consumed`, since
  `SessionEnd` can only ever create that marker.
- `scripts/write-stage.sh` — PostToolUse(Write|Edit) entry point: matches
  writes/edits that resolve to `$cwd/.claude/handoff-todo.md` — the one path
  the checkpoint never sees, since the agent edits that scratch list directly
  all session (FR4). Stages the file with `git add -f`, or — via
  `python3 _checkpoint_lib.py --is-empty-body` (a `python3` subprocess spawn
  into the Python `is_empty_body`, paid only on this cold branch) — removes
  it and stages the removal when the edit left it with no substantive
  content (a `## Remaining` with no items). `handoff-task.md` no longer
  takes this path; it is checkpoint-only (FR3) and staged via the manifest
  instead.
- `scripts/stop-drive.sh` — `Stop` entry point: arms the transition. Acts only
  on state `armed`, so a transition already in flight cannot be re-armed — the
  guarantee its consume-before-spawn ordering used to give implicitly, and that
  window is real, since the walker submits each of its lines as an ordinary
  prompt. Leaves `armed` **before** spawning: `handoff_drive_arm` to `pending`
  for a kind with a confirming source, `rm` for `rename`, which no loader would
  ever clear. Then spawns the walker with
  the before-lines, exporting `HANDOFF_FAIL_FILE`, `HANDOFF_PENDING_FILE`,
  `HANDOFF_EXIT_FILE` and
  `HANDOFF_TRANSCRIPT` (this session's, from `Stop`'s own payload — what a
  `/rename` line confirms against): the hook owns the paths, the walker stays
  ignorant of the layout. An empty before-sequence (FR-G) leaves the file
  `pending` and spawns nothing. Outside tmux it emits every line, before then after, for
  the user to paste in order — and it is the *single* producer of that
  pasteable form, which is why no skill body prints one. Silent no-op when the
  file is absent — `Stop` fires every turn. `Stop` does not fire on Esc, so an
  interrupted turn cannot arm a transition.
  For kind `restart`, before either the tmux check or the pasteable-form
  fallback: clears a stale `.claude/autodrive.exited` (an earlier attempt's
  leftover would false-positive `submit_exited`) and rewrites the
  checkpoint-composed `claude --resume <sid>` before-line to the full launch
  command via `handoff_resume_command` — the only place with access to the
  exiting process's own argv.
- `scripts/load-compact.sh` — `SessionStart(compact)` entry point: consumes
  `.claude/autodrive` — whose disappearance is itself the confirmation the
  walker was waiting on for the `/compact` line it typed — injects the
  task-file frame via
  `additionalContext` (`handoff_frame`; omitted when there is no task file),
  and spawns the walker for the after-line with the session `transcript_path`
  exported as `$HANDOFF_TRANSCRIPT`. Gates on `DRIVE_STATE == pending` and
  `DRIVE_KIND == compact`: only a transition in flight is a loader's to
  complete, and only its own kind, so an `armed` file is left for the sweep and
  a `clear` armed in this session and overtaken by a threshold auto-compaction
  is not consumed here.
  `source: "compact"` is the authoritative compaction-complete signal — no pane
  scraping. Silent when nothing is pending (auto-compaction fires the same
  hook), which is also what keeps a hand-typed `/compact` from re-injecting a
  days-old frame. Reading the task file does not consume it.
- `scripts/report-watcher-failure.sh` — `UserPromptSubmit` entry point:
  reconciles the armed-transition state at the start of a turn.
  It consumes `.claude/autodrive.failed` — one channel now, since the
  transition is a singleton — and reports the reason on both channels, also
  clearing a transition stranded in `pending`. The detached walker's exit status
  is
  read by nothing, so that file is its only path back to the agent — most of all
  on the recognition abort, which wipes the composer and leaves the pane looking
  untouched. `UserPromptSubmit` rather than `Stop` because the walker runs
  *after* the Stop that spawned it. Reports only what the walker observed
  itself; a file in state `pending` alone is never treated as failure (it is
  legitimate for the whole Stop → transition window). Unmodified for
  `restart`: its files are already project-scoped, so a restart that fails
  after `/exit` — where the session that armed it is gone — is reported by
  whatever session next opens in that directory, at its own first
  `UserPromptSubmit`. A deferred report, not a lost one.
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
  It also sweeps a sentinel still in state `armed`: the file is armed at the
  `Stop` of the turn that writes it, which leaves it `pending` or removes it, so
  one still `armed` when a
  later turn begins never armed, and would otherwise be armed by the next
  `Stop` — days later, possibly in another session. A file that will not parse
  is swept too — it describes no transition anyone can complete, which is what
  the bare-filename gate did before the states were content. `held` is exempt,
  which is why the sweep names the states it takes rather than taking anything
  that is not `pending`: a held transition waits on an approval whose answer
  arrives at this very hook, so outliving the turn boundary is what it is for.
  The exemption reaches exactly as far as that reason — a `held` file whose
  owner is not the session at the prompt is reclassified as abandoned before
  the sweep, since the session that would approve it is gone and
  `handoff-approved` would otherwise arm it into this conversation.
  `UserPromptSubmit` is the
  exact discriminator; it cannot fire between the write and that turn's own
  `Stop`. Only the failure branch touches a `pending` — sweeping on that
  evidence would race a live `SessionStart(compact|clear)`. See
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
  matcher (the only hook that reaches `resume`). Used to also publish the
  resolved root here, at a session-keyed path `handoff-checkpoint` (running in
  the agent's own Bash, where `CLAUDE_PROJECT_DIR` is unset) could address
  blind; replaced by `scripts/inject-checkpoint-root.sh` (`PreToolUse(Bash)`),
  which resolves the root fresh on every matching call instead of once at
  `SessionStart` — see `docs/changelog/2026-08-10-checkpoint-root-via-updatedinput.md`.
  Its own script rather than a preamble on the two loaders because the sweep
  below must be unconditional and both of those are gated. Silent no-op
  without a session id. Removes this session's context marker, which is the
  context-size nudge's re-arm: that nudge fires once per climb, and a
  `SessionStart` is the harness-authoritative signal that the context was
  rebuilt — `compact` (auto-compaction included), `clear`, or a `resume` that
  restored it whole and may still be over. Then sweeps the pointer directory —
  `-mtime +7`, scoped by name to `handoff-root-*` (still on the filter, to
  clean up whatever the retired pointer mechanism left on disk),
  `handoff-drift-*` and `handoff-context-*`, and by `-maxdepth 1`, since that
  directory is shared and holds files this plugin never wrote. The producer
  sweeps because none of those files has an owner that outlives the session,
  and the ends that strand one are the ends no `SessionEnd` fires for. See
  `docs/changelog/2026-07-31-pointer-lifecycle.md`.
- `scripts/context-threshold.sh` — `PostToolBatch` entry point: the only hook
  that is **not** cwd-scoped. It touches no file under `.claude/`, so it
  resolves no root and spawns no `python3`, and sources `_lib.sh` only for
  `HANDOFF_POINTER_DIR` and `handoff_context_path()`. A long turn reaches no
  boundary — `Stop` and `UserPromptSubmit` fire only at turn boundaries, which
  is what a runaway turn escapes — and `PostToolBatch` is the only event that
  fires *inside* one, at the session log's own granularity: one API call, one
  `usage` sample, with `additionalContext` reaching the model on the next call
  of the same turn. Takes the **last** `.message.usage` in a `tail -c` window
  (never a sum: the several JSONL entries of one API response repeat the same
  `usage`) **since the last `isCompactSummary` entry** — the hook fires before
  the current call's entry is flushed, so it reads the previous call's sample,
  harmless while the prompt grows and wrong across a compaction, where that
  sample measures the discarded context. A boundary with nothing newer measures
  nothing rather than falling back. Every parsed line is `select`ed to objects
  first: `fromjson?` filters lines that do not parse, not lines that parse to a
  scalar or an array, and indexing one of those is a jq error that would kill
  the hook on every tool batch until it left the window. Past
  `HANDOFF_CONTEXT_THRESHOLD` it injects one directive naming
  `/handoff:precompact` and asking for the compaction to be carried out — the
  skill reads the transition decision off the ask, so naming it alone would
  turn every crossing into a prepared compaction nobody runs. A nudge, never a
  halt. Exits before reading
  anything when `agent_id` is present (a subagent has no boundary to prepare,
  and the transcript it is handed is the parent's) or when the marker already
  exists (still over threshold means the boundary has not happened yet).
  NFR2: this fires on every tool batch of every session with the plugin
  installed, so the negative path is a `jq` over stdin and a `stat`. See
  `docs/changelog/2026-08-01-context-threshold-trigger.md`.
- `bin/handoff-checkpoint` — PATH-resident shim (Claude Code adds each
  plugin's `bin/` to PATH) that execs `scripts/checkpoint.py`. Both skill
  bodies invoke it by bare name; `${CLAUDE_PLUGIN_ROOT}` is not available in
  the agent's Bash, so the shim is the entry point. Replaces
  `bin/handoff-memory-probe` and `bin/handoff-precompact-probe`.
- `bin/handoff-approved` — the one command that leaves the sentinel's `held`
  state, invoked by bare name off PATH when the checkpoint's memory directive
  says so. No stdin, no arguments. The whole script rather than a shim over
  `scripts/`: it is short enough to read at once, its only caller would be its
  own shim, and `bin/*` is already inside the `shellcheck -x` line, so sourcing
  `../scripts/_lib.sh` from here lints as it does from `scripts/`. Takes its
  root from `HANDOFF_ROOT`, injected the same way and by the same hook as
  `handoff-checkpoint`'s, and refuses on its absence with the same message;
  moves the file to `armed` through
  `handoff_drive_arm`; exits 2 naming the state it found when the file is
  absent or not `held`, and naming the owner when the held file is another
  session's — the approval it speaks for is the one *this* session was asked
  for, and the state alone does not say that. NFR1: no git, no tmux — it
  rewrites one file.
- `scripts/checkpoint.py` — the one write path for the handoff/precompact
  wrap-up (FR1). Python since 2026-08-10, ported from `checkpoint.sh` (see
  `docs/changelog/2026-08-10-python-split.md`). Takes its root from
  `HANDOFF_ROOT`, injected by
  `scripts/inject-checkpoint-root.sh` (`PreToolUse(Bash)`) into the very
  command that invokes it, and refuses when unset or naming a non-directory:
  it runs in the agent's Bash, where `CLAUDE_PROJECT_DIR` is unset, so nothing
  else can supply it. Reads the JSON payload on stdin, validates it against
  the schema (FR2 — a violation exits 2 naming the offending field on stderr),
  applies the `task`/`todo` Write-or-Edit forms (FR5; `task` is Write-form-
  or-null only), removes a file whose resulting body is empty via
  `is_empty_body` (FR6), writes `.claude/checkpoint-manifest` —
  always, even with zero lines, so `bash-post.sh`'s presence-gate still
  fires for a call that touched neither file — and composes `.claude/autodrive`
  (FR8) from the transition fields, flattening the title's whitespace on the
  way (`bash-post.sh` used to do that at consume time, and there is no consumer
  left to), then reads its own output back through `handoff_drive_read` so the
  composer and the parser cannot drift. The state it writes is `held <session>`
  iff the sentinel types **anything at all** and a memory directive was emitted,
  and `armed` otherwise; the gate is the keystrokes, not the transition, since
  an untyped handoff types no transition but still types `/rename` into the pane
  holding the approval question, and the one exemption is the sentinel that
  types nothing (FR-G's marker, which holding would strand).
  `bin/handoff-approved` is the only thing that leaves
  `held`. `rename` is required wherever a title is decided — `skill: "handoff"`
  and `skill: "autoname"`, where it must be a **string**, checked before the
  whitespace flattening that would otherwise pretty-print an object into a
  title — and forbidden under `precompact` and `restart`, by key presence
  rather than value emptiness, the way the `autoname` branch beside it
  already reads: it makes a
  call that forgot its title, or carried one to a boundary that renames
  nothing, an error rather than a silent non-rename. `autoname` and
  `restart` are the third and fourth `skill` values and neither boundary:
  each one's whole payload is its own name plus one or two small fields
  (a title for `autoname`; an optional continuation for `restart`, its one
  field besides the name), every boundary field is a schema error under
  either, and the memory gate lives inside the boundary branch so neither
  call composes a directive at all — `restart` never implies a memory write,
  since the conversation is never lost, only the process. Then it prints the
  directive output (FR9, via
  `_checkpoint_lib.py`), with the arming instruction composed onto the memory
  directive when the sentinel is held. NFR1: it does no `git` or `tmux` work
  itself — see `bash-post.sh`. The Edit form's exact string
  replacement (first occurrence, error if `old_string` is absent or
  ambiguous) needs no shell quoting for a multi-line `old_string`/`new_string`
  now that the whole script is Python — it was a `python3` heredoc from
  `checkpoint.sh` before the 2026-08-10 port.
- `scripts/inject-checkpoint-root.sh` — `PreToolUse(Bash)` entry point:
  matches any command containing `handoff-checkpoint` or `handoff-approved`
  (a loose substring test — a false positive costs an unused env var on an
  unrelated command, a false negative the refusal in `checkpoint.py`/
  `bin/handoff-approved`), resolves this session's root the same way every
  other cwd-scoped hook does, and rewrites the command to
  `export HANDOFF_ROOT=<quoted>; <original command>` via `updatedInput`.
  `export …;` rather than a bare `VAR=…` prefix, so the value survives a
  batched command — `VAR=x a && b` would scope to `a` alone. Replaces a
  session-keyed pointer file `session-pointer.sh` used to publish once at
  `SessionStart`, sampled at the one moment the cwd does not yet belong to
  the session: `SessionStart(resume)` fires with the resuming process's cwd,
  before the harness moves the session into its own project dir. Resolving
  here, on every matching call, has no such moment — the value is sampled
  when it is used. NFR2: fires on every Bash call in every session with the
  plugin installed, so the negative path is one jq field parse and a
  substring test, with no root resolution unless the command matches. See
  `docs/changelog/2026-08-10-checkpoint-root-via-updatedinput.md`.
- `scripts/_checkpoint_lib.py` — imported helper module for `checkpoint.py`
  and, for `is_empty_body`, `write-stage.sh` (via a `python3
  _checkpoint_lib.py --is-empty-body` subprocess spawn — its `_cli` entry
  point). Python since 2026-08-10, ported from `_checkpoint-lib.sh` (see
  `docs/changelog/2026-08-10-python-split.md`); the `checkpoint_*` name
  prefix dropped in the port since the module namespace now does that job —
  `checkpoint_is_empty_body` is `is_empty_body`, `checkpoint_memory_directive`
  is `memory_directive`, `checkpoint_ledger_path` is `ledger_path`,
  `checkpoint_sdd_directive` is `sdd_directive`,
  `checkpoint_todo_boundary` is `todo_boundary` — content and composition
  order (FR9) unchanged.
  `is_empty_body` is FR6's generic emptiness test: strips heading
  (`#`) and blank lines, and what remains decides — a `## Remaining` with no
  items or a task file with headings and no content both count as empty.
  Shared by `checkpoint.py` (after a Write/Edit it just applied) and
  `write-stage.sh` (after the agent's own direct edit to `handoff-todo.md`)
  so the two writers cannot drift on what counts as empty.
  `memory_directive` gates on the `gitlore-memory` submodule
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
  `ledger_path` is the one-row registry of known workflow-owned
  progress ledgers (currently superpowers SDD), so the nudge and the
  boundary can never disagree about what exists — and both interpolate
  what it prints, because with a glob there is no path to hardcode. It
  detects **liveness**, not presence: a match under
  `.superpowers/sdd/*/progress.md` counts only with SDD's identity first
  line, the pre-6.2.0 flat path never counts, and among several the
  most-recently-modified wins. See
  `docs/changelog/2026-07-26-orphaned-ledger.md`. `sdd_directive`
  holds the structured-workflow ledger nudge (precompact only) and ends by
  drawing the boundary between the two lists — the plan's tasks belong to the
  ledger, `handoff-todo.md` holds only work outstanding outside the plan, and
  the file is never stood down (`docs/changelog/2026-08-08-ledger-and-todo-are-different-scopes.md`);
  `todo_boundary` is that boundary alone, for the handoff path,
  naming the removal as well because it lands in the same turn as the writes
  — composed in
  `checkpoint.py`'s `skill: "handoff"` vs `skill: "precompact"` branch,
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
  - `install.sh` — first-run wiring (idempotent).
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
  (pinned to the main tree in a worktree session).
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
- `_lib.sh`, the one remaining sourced bash helper, needs
  `# shellcheck source-path=SCRIPTDIR source=_lib.sh` above the
  `source` line so `shellcheck -x` follows it. Add
  `# shellcheck disable=SC2034` to vars consumed only by sourcing
  scripts. `_checkpoint_lib.py` and `_watcher_lib.py` are imported, not
  sourced, so this convention does not apply to them.

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
- `just hook-test` — `bats tests/hook-test.bats
  tests/checkpoint.bats`: end-to-end test of the handoff-specific hook
  scripts (and the rename scripts) against synthetic tool-event payloads. `bats run` captures
  exit codes/output without the `set +e` dance. `version-guard.sh` is
  tested in the toolkit, not here.
  `hook-test.bats` stubs `tmux` on `PATH` in `setup()` and shortens the
  `HANDOFF_WATCHER_*` tunables. Hooks it exercises that spawn a detached
  watcher rely on this, since `TMUX=fake` does not stop tmux falling back to
  the default socket — unstubbed, those watchers drive a real pane belonging
  to whoever is running the suite.
  `tests/checkpoint.bats` covers only what stayed bash after the
  2026-08-10 Python split (see
  `docs/changelog/2026-08-10-python-split.md`): `inject-checkpoint-root.sh`,
  `bin/handoff-approved`, the `bin/handoff-checkpoint` shim, and
  `scripts/bash-post.sh`. Everything it used to cover about `checkpoint.sh`
  itself — schema validation, write semantics, directive composition, the
  transition/sentinel matrix — moved with the port to
  `tests/test_checkpoint.py` (pytest), described below.
  `tests/test_checkpoint.py` (89 tests) covers `scripts/checkpoint.py`'s own
  behavior end-to-end via subprocess, ported from what was
  `tests/checkpoint.bats`'s exhaustive coverage of `checkpoint.sh` (merged,
  before that, from the deleted `tests/memory-probe.bats` +
  `tests/precompact-probe.bats`). Carries forward the commit-awareness
  contract in full — the mode's four combinations with memory state, and the
  composed memory-then-SDD ordering under `skill: "precompact"` vs its
  absence under `skill: "handoff"` — plus the ledger-liveness matrix (flat
  path, unidentified workspace, several-workspaces mtime tiebreak). The
  load-bearing assertion is the negative — `with-commit` output never
  mentions the trigger file — and it is mutation-checked (disable the
  branch, watch it go red), not observed passing. Also: schema validation
  (each required field missing, each literal with an unknown value, `rename`
  under `precompact`, `content`+`old_string` together, a partial Edit,
  `file_path` outside `$root/.claude/`, malformed JSON — each asserting a
  non-zero exit and that the message names the field), Edit application
  (`old_string` absent, ambiguous, successful), empty-body removal through
  both writers (`checkpoint.py` and `write-stage.sh`) including that the
  deletion reaches the manifest, and `bash-post.sh` (manifest absent,
  manifest present, a sentinel left untouched). The `skill` enum's four values
  each accepted, the two retired driven-skill names rejected, `rename` rejected
  under `precompact` and `restart`, required under the other two, and each
  boundary's directive asserted against the absence of the other's.
  `skill: "autoname"` adds five rows: the exact sentinel it composes (read back
  through `handoff_drive_read` as kind `rename` in state `armed`), the empty
  manifest with neither file touched, `rename` missing, each of the six fields
  the boundaries carry rejected by name, and the load-bearing negative —
  an `autoname` call against a dirty memory submodule emits no directive at
  all, mutation-checked by restoring the unconditional
  `memory_directive` and watching that row alone go red.
  `skill: "restart"` mirrors that shape in `tests/test_checkpoint.py`: the
  exact sentinel with and without a continuation (read back as kind `restart`
  in state `armed`, never `held` — restart composes no memory directive, so
  the same never-holds row that is load-bearing for `autoname` needs no
  restart-specific mutation check, since there is no gate for the mutation to
  disable), the empty manifest, `continue` missing, `CLAUDE_CODE_SESSION_ID`
  unset (a distinct failure from the six boundary fields, each rejected by
  name against the generic "unknown skill" message a naive assertion could
  pass on accident — every restart row guards against that vacuous pass
  explicitly, since both "restart" and "compact" appear inside that message's
  own fixed vocabulary).
  The transition fields add their own matrix: each of `clear`/`compact`/
  `continue` missing, each with a value outside its type, the other boundary's
  transition field present, an empty or multi-line `compact` directive, a
  `continue` that is multi-line, whitespace-only, begins with `/`, or stands
  against an untyped transition — each asserting a non-zero exit naming the
  field. The six legal combinations each pin the sentinel's exact content and
  read it back through `handoff_drive_read`. Three rows are load-bearing and
  mutation-checked rather than observed passing: the held/armed pair over one
  fixture (never hold ⟹ the held row alone reds; hold whatever the sentinel
  types ⟹ the types-nothing row alone reds), and `handoff-approved`'s bare-name
  row, which is the only one a `100644` entry point would fail. The held state
  adds its owner: the checkpoint naming the session, `handoff-approved`
  refusing another session's held file, and — in `tests/hook-test.bats` — the
  sweep's own pair, where the dead-session row was green in the red phase (an
  owned state line did not parse yet) and is mutation-checked afterwards
  against the same-session row that must stay green.
  Session-root drift is covered across all three: `tests/test_worktree_root.py`
  for the branch matrix (including the containment rule that keeps a submodule
  `inside`), `tests/hook-test.bats` for `handoff_root_read`'s labels, the fast
  path labelling its own branch, `session-pointer.sh`, and the drift report's
  episode semantics, and `tests/test_checkpoint.py` for the `HANDOFF_ROOT`
  refusals plus the load-bearing negative — a drifted cwd gets nothing
  written into its `.claude/`, mutation-checked against the old `$PWD`
  fallback. The pointer sweep's two guard-rails are load-bearing and each
  mutation-checked twice: a
  file the plugin did not write, and one a directory deeper, both survive
  (widen the name filter, drop `-maxdepth 1`), and another session's fresh
  files survive (drop `-mtime +7`). Those guard-rails reach as far as their
  fixture: the foreign file is named `somebody-elses-file`, so widening the
  filter to any `handoff-`-prefixed name is not caught.
  The context-size threshold adds fourteen rows to `tests/hook-test.bats` over a
  synthetic transcript fixture (`usage_entry` builds one assistant entry,
  `compact_boundary` the flagged compaction entry;
  `run_context_threshold` drives the hook), plus three on `session-pointer.sh`
  for the re-arm and its scoping. Three negatives are load-bearing and
  mutation-checked rather than observed passing, each paired with a positive
  over the same fixture: the subagent skip, the marker gate, and the compaction
  boundary with no newer sample. Disable any
  guard and the negative must go red while *"over threshold: nudges and writes
  the marker"* stays green. The boundary's two companion rows (a newer sample
  under and over the threshold) pass under the old unscoped `last` too, since
  taking the newest number is already right whenever a newer number exists;
  they are regression guards, and the mutation check is what says so — it reds
  the no-newer-sample row alone. The invocation-path row asserts — a
  script `hooks.json` never names runs at no point, and every other row would
  still pass. The re-arm's own scoping row (*"leaves another session's context
  marker alone"*) cannot go red before the `rm -f` it guards exists, so it is
  verified by mutation afterwards rather than in the red phase.
  The compaction driver is covered in `tests/hook-test.bats`, unaffected by
  the 2026-08-10 Python split since every script it drives here stayed bash:
  the `handoff_drive_read` shape matrix,
  `stop-drive.sh` / `load-compact.sh` / `load-handoff.sh` on
  `source: "clear"` / `report-watcher-failure.sh`,
  and — since the states became content — the four state gates, each paired
  with the positive that already existed over the same fixture: `stop-drive.sh`
  ignoring a `pending`, each loader ignoring an `armed`, and the sweep leaving
  a `pending` alone. Three of the four are mutation-checked (`stop-drive.sh`,
  `load-compact.sh`, `report-watcher-failure.sh`), and so are `load-handoff.sh`'s
  conjunct and `handoff_drive_arm`'s no-temp-left-behind row — the last two
  because both were green in the red phase, the arm rows having failed at 127
  rather than on an assertion, which proves nothing.
  The `restart` kind adds its own rows to `tests/hook-test.bats`: the shape
  matrix (`clear`'s shape, `/exit`/`claude --resume` in the two command
  slots), `handoff_resume_command` (argv replay with `--resume` appended, an
  embedded-space argument surviving whole via a NUL-separated fixture file
  substituting for `/proc/<pid>/cmdline` — `/proc` itself cannot be faked —
  and the no-source-readable fallback), `stop-drive.sh`'s argv composition and
  stale-exited-marker clearing (asserted through the not-in-tmux paste path,
  a synchronous seam, rather than by waiting on the detached walker), the new
  `session-end.sh` hook (silent absent a pending `restart`, writes the marker
  when one is pending, worktree-scoped), and the new `load-restart.sh` hook
  mirrored against `load-compact.sh`'s own matrix but with one added negative
  — a task file present still injects no frame, which is the whole reason a
  restart costs no context.
  The walker and the pane predicates that used to be `tests/watcher-test.bats`
  ported whole to pytest with the 2026-08-10 split (see
  `docs/changelog/2026-08-10-python-split.md`), never trimmed:
  `tests/test_watcher_lib.py` (24 tests) covers the pure predicates
  (`is_busy`, `is_typing`, `is_unknown_command`), `transcript_prompt_count`,
  `transcript_title_count`, and the `watcher_fail` recording, plus that the
  four confirmation primitives (`submit_exited` since 2026-08-10) return
  rather than raise on a non-delivery.
  `tests/test_drive_when_idle.py` (23 tests) drives `drive_when_idle.py`
  end-to-end via subprocess against the tmux stub (`tests/conftest.py`'s
  `TmuxStub` fixture, replacing the bats `make_stub`/`on_enter` helpers):
  the recognition read-back, the unrecognized-command clear, the
  never-typed-while-composing gate, the four confirmation primitives, and
  the multi-line sequence and stop-on-first-failure behavior. `/exit` and the
  `claude --resume` shell-line path (2026-08-10) add five rows: `/exit`
  confirming and failing, the shell line proceeding against pane text that
  would fail `_drive_line`'s composer checks (demonstrating the bypass is
  real, not just untested), its settle being configurable, and the full
  `/exit`-then-`claude --resume` sequence running in order. Two rows there
  are load-bearing and mutation-checked: the FR-H re-idle gate, asserted on
  the *delay* between two literal sends rather than on suppression
  (`wait_for_idle` falls through on timeout by design, so a busy pane is
  typed into eventually), and the confirmation primitives returning rather
  than raising, echoed from the predicate suite. The same holds
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

@memory/ddaanet/shared-claude.md
