# handoff — Design

Living document. States what this plugin is, how it works today, and why
each standing decision was made. Present tense throughout: when a decision
is reversed, this document is rewritten rather than annotated.

The write-time record of every design change lives in `changelog/`, one
file per change, dated, indexed by [`changelog.md`](changelog.md). Those files are never
edited after the fact — they say what was true and what was believed when
they were written, which is what makes them worth keeping.

Last updated: 2026-07-28.

## Problem

When a Claude Code session grows long or a user wants to `/clear` mid-task,
some state is worth preserving for the successor agent. Existing solutions
either over-capture (full-transcript summaries that drift) or under-capture
(nothing at all, relying on the user to re-explain).

The goal here is to identify the *irreducible residual* — what state
actually needs crossing the `/clear` boundary given everything else the
Claude Code ecosystem already handles — and build the minimum machinery
for it.

## Research — SOTA for session handoff (April 2026)

Four dominant families observed in the wild:

### 1. In-session auto-compaction

Claude Code `/compact`, Codex CLI, OpenCode. LLM summarises the full
trajectory at a threshold (80–95%), fresh context resumes with the
summary. Differ only in what's kept alongside the summary.

- Claude Code: summary only
- Codex CLI: summary + recent ~20k tokens
- OpenCode: summary + pruned tool outputs, last ~40k tokens protected

All acknowledge cumulative accuracy loss across multiple compactions.

### 2. Manual structured handoff

Amp handoff, jdhodges' CLAUDE.md + HANDOVER.md pattern. User-directed,
explicit. Typical envelope:

```
Goal / Status / Context / Decisions made / What to avoid /
Open questions / Next step
```

Often paired with a durable `HANDOVER.md` that survives across sessions.
This is SOTA for *cross-session* continuity. The existing `/ddaa:handoff`
skill in the `ddaa` plugin targets this pattern (claude.ai-oriented).

### 3. Structured note-taking / memory tools

Anthropic memory tool beta, Cursor/ChatGPT memory, Cline/Copilot "memory
bank". Agent writes to files outside the context, reads them at session
start. Claude Code auto-memory is this family.

### 4. Sub-agent isolation

Parent delegates to sub-agents with a clean minimal-viable-context
envelope; sub-agents return 1–2k-token summaries. LangGraph supervisor
patterns, OpenAI Agents SDK handoffs.

LangChain's framing — **write / select / compress / isolate** — is the
cleanest mental model for judging a given design.

## Analysis — what is the residual after auto-memory + harness?

Memory + harness + training already supply:

| SOTA field | Handled by |
|---|---|
| Context (durable) | auto-memory |
| Decisions (durable) | auto-memory |
| What to avoid | auto-memory (feedback files) |
| Goal (meta-level) | auto-memory (project files) |
| Status | code + `git status` |
| Conversation arc | session JSONL (orthogonal, used via `claude -c`) |

What's reconstructible from state:

| Field | Reconstruction |
|---|---|
| Agent responses | re-derive from intent + code state |
| Tool results | re-run |
| Files touched | the harness's own `gitStatus` block at load time |

What's irreducible:

- **current_task** — a pointer to what was in progress
- **open_decisions** — unmade choices still blocking progress

Plus one that is reconstructible only by *model inference*, which is a
different thing:

- **the undone half of a task list** — a decomposition is judgment, and
  after a compaction it is re-derived from a paraphrase with real error
  probability, failing silently by redoing finished work. See
  [Reconstructable is two categories, not
  one](changelog/2026-07-22-a-place-for-the-todo-list.md).

The original analysis carried a fourth category — the last N verbatim user
prompts, as "the only unreconstructable conversational signal" ([the
argument, in full](changelog/2026-05-19-original-activation-and-loading.md)).
It was implemented, shipped, and withdrawn: a faithful transcript does not
read as a report about a past session, it reads as *memory*, and the successor
narrates a prior session's work as its own. See [Task frame drops the
transcript and file list](changelog/2026-07-17-task-frame-drops-transcript.md).

Those categories constitute the artifact this plugin produces. Everything
else on the SOTA list is already handled, or reconstructible from code /
git / memory.

## Architecture

Five skills, one write path, eight hooks, and two files that cross a
boundary.

### The seam

`.claude/handoff-task.md` and `.claude/handoff-todo.md` are the durable
side. Both are git-tracked (force-added by a hook; both are listed in
`.gitignore` so *only* a hook can add them). Both are injected verbatim at
`SessionStart`, task first, under one timestamp header — the *frame*,
assembled in memory by `handoff_frame()` in `scripts/_lib.sh` and shared by
the two loaders so the two transitions cannot drift.

- **`handoff-task.md`** — `## Current task`, and `## Open decisions` when
  any remain. Written **only** by the checkpoint; a direct agent Write or
  Edit is denied by `write-guard.sh`. A snapshot of a moment.
- **`handoff-todo.md`** — `## Remaining`, open items only. A scratch list
  the agent edits directly all session; the wrap-up only folds in the final
  remainder. A ledger, not a snapshot.

The frame carries no session id, no transcript, no file list, and no
commit/push status. The working set comes from the harness's own
`gitStatus` block at load time.

### One channel, one writer

Both wrap-up skills decide their content and then make exactly one Bash
call: `handoff-checkpoint`, a PATH-resident shim (`bin/`) over
`scripts/checkpoint.sh`, taking the whole wrap-up as a schema-validated
JSON payload on stdin — `skill`, `commit`, optional `rename`, and `task` /
`todo` in the harness's own tool-call shape: `file_path` + `content` for a
Write, or — for `todo` alone — `file_path` + `old_string`/`new_string` for
an Edit. The task file is authored whole at every boundary, so it takes no
Edit form and the schema refuses one. A violation exits non-zero naming the
offending field.

It gets its root from the pointer `SessionStart` published, keyed by
`CLAUDE_CODE_SESSION_ID`, and refuses when there is none — a live session
always has one, so its absence is abnormal, and the old fallback to `$PWD`
was silently wrong whenever the session cwd had drifted.

The checkpoint applies the writes, removes any file whose resulting body is
empty, leaves `.claude/checkpoint-manifest` behind, and prints a directive
on stdout. It **changes no git state** and touches tmux not at all — it
queries git read-only and stops there: it runs in the agent's
sandboxed Bash, where `git add` can leave `.git/index.lock` behind and fail
the *next* command (which in the routine wrap-up is the user's `/commit`),
and where tmux is unreachable. `PostToolUse(Bash)` (`bash-post.sh`) consumes
the manifest instead — `git add -f` for every listed path, deletions
included, plus the rename watcher spawn.

`file present ⟹ content pending` is an invariant two writers enforce
(`checkpoint.sh` and `write-stage.sh`, sharing `checkpoint_is_empty_body`),
not an instruction the agent has to remember.

### The five skills

Two boundaries, and at each one a skill that prepares and a skill that also
carries the transition out:

| boundary | prepare only | prepare + drive |
|---|---|---|
| compaction | `/handoff:precompact` | `/handoff:compact-continue` |
| clear | `/handoff:handoff` | `/handoff:handoff-continue` |

The judgment is per-boundary, not per-drive-mode: commit awareness, memory
capture, the task/todo drafting rules and the file-vs-prompt seam are
identical whether or not the agent types the command afterwards. So each
boundary's full protocol lives in one file — `handoff/SKILL.md` and
`precompact/SKILL.md` — and the two driven skills are short bodies that
execute their sibling's protocol by reference and then arm. The alternative
is two drifting copies of the paragraphs the whole design rests on.

The pair at each boundary is told apart by trigger vocabulary, not by
inferring the situation from context: *prepare* and *end* against
*continue*, with the bare boundary word falling to the prepare-only skill.
An operator who wants the other default sets it in a user memory or a
`CLAUDE.local.md`; the plugin ships no nudge, because that default is one
operator's habit rather than a property of the boundary.

- **`/handoff:autoname`** — rename only, neither boundary. Decides a title
  and writes the sentinel with the Write tool. For `/btw` side
  conversations and any session worth a name while the main thread stays
  live.

### Driving the TUI

A **driven transition** is a sequence of lines to type, plus the
`SessionStart` source that confirms it happened:

| kind | typed before | typed after | confirming source |
|---|---|---|---|
| `rename` | `/rename <title>` | — | — |
| `compact` | `/compact [directive]` | continuation prose | `compact` |
| `clear` | `/rename <title>`, `/clear` | continuation prose | `clear` |
| `compact` (prepared) | — | — | `compact` |

One sentinel, `.claude/autodrive`, whose first line is the kind. The
remaining lines are the **literal keystrokes**, so the walker never needs to
know which command belongs to which kind; validation anchors it instead —
the *n*th line of kind *k* must begin with the expected command literal, so
the file cannot be made to type something else.

Mid-turn input has four distinct classes, and prose — not the slash command
— is the dangerous one: it is injected into the running turn's next model
call. So no line is ever typed from inside a live turn. `Stop`
(`stop-drive.sh`) arms the before-lines, moving the sentinel to `.pending`
*before* spawning so a later `Stop` cannot re-arm; the transition's own
`SessionStart` consumes that file and spawns the after-line. One walker,
`drive-when-idle.sh`, serves every case: wait for idle, type, confirm,
re-gate on idle, next line. A line that fails to confirm stops the sequence,
which is what makes a `/rename` that never lands under kind `clear` cost a
wrong title and nothing more.

Confirmation dispatches on the **command**, not the kind — which is what
lets `/rename` appear in two kinds with two different fates, and carries the
recognition check for free, since any line beginning `/` takes the
type-read-back-Enter path. Three primitives: a `custom-title` transcript
entry for `/rename`, the `.pending` file disappearing for `/compact` and
`/clear`, a genuine user-prompt transcript entry for prose. The walker reads
the pane only where the pane is the sole witness — gating *typing into* the
composer (`is_typing`, `is_unknown_command`). Nothing that asks whether an
action *took effect* looks at it.

A detached walker's exit status is read by nothing, so non-delivery is
written to `.claude/autodrive.failed` and reported by
`report-watcher-failure.sh` at the next `UserPromptSubmit` — the first
moment anything can act on the news. That hook also sweeps a bare
`.claude/autodrive` left by a turn that ended on Esc or a crash:
`UserPromptSubmit` is the exact discriminator, since it cannot fire between
the write and that turn's own `Stop`.

The prepare-only compact path arms the kind line alone. Nothing is typed,
but the transition is *expected*, and that expectation is what
`SessionStart(compact)` gates the frame's re-injection on — otherwise a
hand-typed `/compact` re-injects nothing.

### Scoping

Every cwd-scoped hook anchors on `handoff_root()` — the enclosing linked
git-worktree root derived from on-disk `.git` linkage
(`scripts/worktree_root.py`), falling back to `CLAUDE_PROJECT_DIR` — never
the raw hook-input `.cwd` (drifts with `cd` and `/add-dir`) and never
`CLAUDE_PROJECT_DIR` directly (pinned to the main tree in a worktree
session). So a worktree session owns its own `.claude/`. The resolution is
short-circuited in bash for the trivial cases, so the every-turn hooks skip
the `python3` spawn.

The resolver also reports **which branch** produced that answer — `inside`,
`worktree`, `foreign`, `unrelated` — because the root alone collapses four
different situations into one. `handoff_root_read()` sets the caller's
`HANDOFF_ROOT` and `HANDOFF_ROOT_BRANCH` (the `handoff_drive_read` idiom);
`handoff_root()` is the printing form, since every other caller captures it
in a `$(...)` where a global would die with the subshell. Containment beats
the branch the walk took: a submodule or vendored checkout inside the
project is `inside`, not `foreign`.

The last two labels are **drift** — the session cwd has left the launch repo
while the root, and every handoff file under it, has not. Nothing else
announces that: the environment block, `gitStatus` and the project
`CLAUDE.md` all follow cwd. `report-watcher-failure.sh` reports it at
`UserPromptSubmit`, where the root is resolved every turn anyway, because
drift can be transient and a later gate would see nothing while the split
was live for the whole blip. One report per episode: a marker holds the
destination last announced, and returning clears it.

The agent's own Bash cannot do any of this — `CLAUDE_PROJECT_DIR` is unset
there, and a `$PWD` fallback is wrong in exactly the drift case. So
`SessionStart` publishes the resolved root, on a wildcard matcher
(`session-pointer.sh`, the only hook that reaches `resume`), as one line at
`/tmp/claude/handoff-root-<session_id>` — a literal path both sides can
address blind, since the two share no environment but the session id, and
the checkpoint cannot read a file under the root it is trying to find.

That pointer and the drift marker beside it are the plugin's only state
outside a project, and neither has an owner that outlives the session. So
the producer sweeps: right after publishing, `session-pointer.sh` deletes
files older than seven days, scoped by name to the two it writes and by
`-maxdepth 1` to the level it writes them at — the directory is shared and
holds files this plugin never wrote. A `SessionEnd` hook would clean up
only the ends that fire one, which is the opposite of the set that strands
a file. The trade is that a session open seven days without any
`SessionStart` loses its pointer, and finds out when the checkpoint refuses
and names the restart that republishes one.

`handoff_match_target()` is the shared preamble of every path-scoped hook:
one jq parse, basename fast-path, root resolution, and resolved-path
comparison, variadic over (basename, rel) pairs — the jq spawn is on the
Write/Edit hot path, so N files must stay one parse. It distinguishes "other
file" from "basename matched but cross-project", which only `write-guard.sh`
denies. That comparison is the cross-project security boundary.

### The gitlore seam

The checkpoint's directive is the plugin's one seam with
[gitlore](https://github.com/ddaanet/gitlore). When the `gitlore-memory`
submodule is registered and dirty, it instructs the agent to summarize → get
approval → write `.claude/gitlore-memory-message`, and — only under
`without-commit` — `.claude/gitlore-commit-memory`. That trigger file is the
entire difference between the two paths: written, gitlore's `PostToolBatch`
commits memory standalone; withheld, the parent commit's pre-commit hook
folds it into the source commit. Both are file writes, which sidesteps the
sandbox and the auto-mode classifier. The coupling is two IPC filenames plus
one advertised `git config` key — `gitlore.memoryApprovalClauseFile`, whose
value is the file holding the approval wording the directive quotes, so the
wording has one owner instead of a copy per consumer. Never gitlore
internals.

`checkpoint_ledger_path` is the one-row registry of foreign workflow-owned
progress ledgers (currently superpowers SDD). It detects **liveness**, not
presence: the current layout glob plus an identity first line, most-recent
mtime among several, fail open. Both the nudge and the todo-file suppression
interpolate what it prints, so they cannot disagree about what exists.

### Release infrastructure delegated to claude-plugin-dev

The `release` recipe and the `version-guard.sh` PreToolUse hook live
in the [claude-plugin-dev](https://github.com/ddaanet/claude-plugin-dev)
toolkit, vendored at `plugin-dev/` via `git subtree`. Rationale:

- The release dance — clean-tree check, version bump, tag, push, GH
  release, marketplace bump, plus a guard that refuses agent-driven
  version edits — is identical across every plugin we ship. Inlining
  it in each consumer's justfile produces drift; vendoring the source
  of truth keeps the contract one file.
- `git subtree --squash` rather than a submodule keeps the toolkit
  files visible in this repo's tree (no extra clone, no fragile
  pointer), and pinning to a tag (`v0.4.0`) makes upgrades explicit.
- The toolkit's `release.just` requires consumers to define two
  recipes: `precommit`, the per-plugin checks that must pass before
  every commit, and `prerelease`, the gate `release` actually depends
  on. handoff's `precommit` lints its own manifests, syntax-checks
  scripts, and runs the handoff-specific hook + pytest suites; its
  `prerelease` is exactly `precommit`. The indirection exists so a
  plugin whose release gate is wider than its commit gate — slow or
  paid checks — can widen `prerelease` without slowing every commit.
- The release recipe also bumps the plugin's entry in the sibling
  `claude-plugins` marketplace repo (path from `$MARKETPLACE_DIR`,
  set in `.envrc`) and pushes that repo. A tag without a marketplace
  bump is invisible to end-users, so the recipe treats both pushes as
  one atomic release.

Updates: `just update-plugin-dev vX.Y.Z` (recipe imported from
`release.just`).

## Design decisions

**Extraction is deterministic; judgment is the agent's.** The plugin
captures the two fields `/compact`, Session Memory, and training cannot
supply. It does not add a third summarisation layer.

**The task file is checkpoint-only; the todo file is not.** They look alike
and are not. The task file is authored fresh from the conversation at every
boundary, so a prior copy on disk is only something to be read, extended, or
partially edited instead of replaced — hence one writer and a hard guard.
The todo file is a ledger the agent maintains all session; wiping it
destroys the half of the frame a `/clear` discards outright, and after a
compaction the context it would be re-authored from is a paraphrase. One
protocol for both was an artifact of their sharing one activation hook.
[One channel, one writer](changelog/2026-07-27-one-channel-one-writer.md)

**Both files are tracked, and for the same reason.** `handoff-task.md` pairs
with a gitlore memory commit as an in-history record; `## Current task` and
`## Remaining` are two sections of one snapshot, and tracking one while
discarding the other puts half a frame in history — the half naming work not
yet done, which is what a reader of the trail is looking for.
[Overflow deserves the same
persistence](changelog/2026-07-23-overflow-deserves-persistence.md)

**Commit/push status never appears in either file.** The routine wrap-up is
`/handoff` then `/commit`, so any bookkeeping written at handoff time is
falsified by the very next action, lands in history, and is re-injected
stale. This is a content problem, fixed at the template level — the template
has no slot for it — not a remembered prohibition. The legitimate case
("changed X but not committed because tests are red") is an open decision,
stated as the *why*.
[Commit status excluded from the task
frame](changelog/2026-06-24-commit-status-excluded.md)

**The frame carries no transcript.** Verbatim prior exchanges arrive in
conversational grammar and are read as memory, not as a report; the hazard
scales with volume, and trimming changes length, not register.
[Task frame drops the transcript and file
list](changelog/2026-07-17-task-frame-drops-transcript.md)

**The agent supplies one fact; the code owns the branch.** Commit awareness
— *is a commit going to carry this session's memory?* — is a fact about the
conversation and the tree that no script can see, and everything downstream
of the answer is deterministic. It changes what memory *says* (under
`with-commit`, bodies state present-tense truth, because a body phrased as
pending is false the moment the change exists and gets re-injected that way)
and where the memory commit *lands*.
[Commit awareness](changelog/2026-07-25-commit-awareness.md)

**Withholding is a mechanism.** The standalone memory commit is reachable
only through one filename, and the `with-commit` directive's reader is a
fresh agent with no other source for it — so saying nothing makes that path
unreachable, while a prohibition would introduce the concept it forbids. The
same cut removes mechanism a reader cannot act on: it does not sit inert, it
gets verified and narrated back.
[Commit awareness](changelog/2026-07-25-commit-awareness.md)

**A directive is correct only where in the turn it lands.** handoff runs its
checkpoint in the same turn as the writes — deliberately, so the snapshot
costs one round trip — so a directive about *how to write them* arrives
after they exist. precompact reads its directive before it writes. Shared
prompt text is shared only where the flows agree; naming the safe route is
the load-bearing half of any prohibition.
[A directive must fit where in the turn it
lands](changelog/2026-07-22-directive-fits-where-it-lands.md)

**Hooks are mechanical; anything requiring judgment is in a skill.** A
`PreCompact` hook cannot run an agent turn. A probe cannot see the agent's
task list. Detection that would need a transcript scrape — activation,
commit intent, the todo list — is either asked of the agent or not asked at
all, because keying on tool names in JSONL is a maintenance trap the harness
has already sprung once.

**Nothing that asks whether an action took effect reads the pane.** Every
pane-derived predicate is a guess about undocumented chrome, and three
independent ones failed: a stale scrollback timer reading as busy, a queued
submit showing no spinner, a 103-second compaction showing none either.
Confirmation comes from harness-authoritative signals — a file the
transition's own `SessionStart` consumes, or the session transcript. The
rule holds without exception: the rename was the last holdout, confirming by
grepping the pane for the title's first 20 characters, which matches
whenever the title is on screen for any other reason. It now counts
`custom-title` entries in the transcript, and the harness's own auto-titling
writes a distinct `type`, so an exact match cannot false-positive on it.
[The submit signal, a third
time](changelog/2026-07-22-confirm-the-compaction.md)

**The armed transition is one file whose body names the transition.** One
composer, one session, at most one transition in flight — so the invariant
needs somewhere to live, and the filename is not it. While identity sat in
the name (`autorename`, `autocompact`), each instance cost a full parallel
pipeline: a constant pair, a validator, a `Stop` arm, a watcher, a failure
channel, a stale sweep. Two `Stop` hooks would then race for one composer
whenever both files existed, and nothing anywhere represented the fact that
they could not both be armed. Moving the kind into the body makes the
invariant structural, and collapses three watchers into one walker.
[Driven transitions](changelog/2026-07-29-driven-transitions.md)

**Observability is not gated on the happy path.** A clean run says nothing
about whether a dirty one would be noticed, and the failing run is exactly
the one nobody is watching. Every non-delivery path a watcher can observe
itself writes a reason to a file. Nothing is inferred from state that is
legitimately present (a `.pending` during the whole Stop → compaction
window): a false-positive-free signal is worth the tail of watchers killed
outright.
[A detached watcher's failure has to become a
file](changelog/2026-07-20-watcher-failure-becomes-a-file.md)

**A foreign tool's state file is detected by liveness, not presence.**
Layouts move and the old path becomes a declared stray; abandoned files are
never cleaned up. Presence alone false-positives, and here the harm is the
*suppression* — deferring the real remainder to an abandoned ledger. Detection
is read-only and fails open.
[An orphaned ledger hijacks the
handoff](changelog/2026-07-26-orphaned-ledger.md)

**The design names no todo tool.** The harness's task-list family is behind
a server-side killswitch and has already changed generations once; an
affordance that can vanish between two sessions on the same binary cannot be
a dependency. The file is the ledger, whatever tracker is live is a cache,
and the cache may legitimately hold more (identity, ordering, per-item
history) because that surplus is boundary-local.
[A place for the todo list](changelog/2026-07-22-a-place-for-the-todo-list.md)

**With nothing to approve, the wrap-up completes in a single turn.** No
detection round-trip exists between deciding and writing: the checkpoint is
unconditional, and it decides for itself whether memory or a ledger is in
play. When memory *is* pending, the directive asks for approval — a user
response, which ends the turn — and a driven skill therefore arms the
sentinel only in the turn after the answer, or it would compact or clear
away the conversation the answer applies to. Any rebalancing of the gitlore
seam must preserve both halves.

## Rejected alternatives

**Loading via an `@.claude/handoff.md` reference** — the reference is
resident in every turn and cannot be conditional. `SessionStart` +
`additionalContext` injects once, only when there is something to inject.
[Original design](changelog/2026-05-19-original-activation-and-loading.md)

**A generated `handoff.md` artifact** — a non-versioned twin shadowing a
versionable source, which also inlined raw transcript into anything that
committed it. The frame is assembled in memory at read time instead.
[Read-time assembly](changelog/2026-06-05-read-time-assembly.md)

**A `PreCompact` hook for the memory flush** — hooks are mechanical and the
flush is judgment; `PreCompact(manual)` can annotate or block a compaction
but cannot run an agent turn.
[Session compaction](changelog/2026-07-12-session-compaction.md)

**Merging handoff into gitlore**, **moving the checkpoint into gitlore**
behind a `command -v` lookup, and **gitlore superseding handoff** — distinct
timescales and machinery for the first; the detection round-trip the
packaging exists to avoid for the second; for the third, supersession means
gitlore carries all of handoff's machinery, vendored and kept in sync.
[Session compaction](changelog/2026-07-12-session-compaction.md)

**Live `git status` in `load-handoff.sh`**, and **reorder + amend** (commit,
regenerate the handoff, amend) — the first adds a git shell-out to a pure
assembler for a content problem; the second reopens a closed artifact and
breaks the paired in-history record. Machinery to make a wrong fact accurate.
[Commit status excluded from the task
frame](changelog/2026-06-24-commit-status-excluded.md)

**Trusting the raw `.cwd` field**, or recording the root via
`WorktreeCreate`/`CwdChanged` — the first drifts with `cd` and `/add-dir`;
the second is observational, with no clean per-worktree storage, and fragile
against the stateless `.git` walk.
[Per-worktree handoff
root](changelog/2026-06-09-per-worktree-handoff-root.md)

**A session-id sidecar or a recency timeout for a stale sentinel** —
the most likely trigger is an Esc in the *same* session, so the id matches
and the next `Stop` arms it anyway; a timeout is a guess about how long a
turn may run, and a wrong guess silently drops a wanted compaction.
[A stale autocompact is one a later turn can
see](changelog/2026-07-22-stale-autocompact.md)

**Detecting commit awareness in the checkpoint, and defaulting the answer**
— a transcript scrape is the maintenance trap this design already refuses,
and a slash-command name is not the question; a default is the answer given
by an agent that has not thought about it, and thinking about it is the
entire contribution. A third mode value would branch identically and only
rename a shade of prose.
[Commit awareness](changelog/2026-07-25-commit-awareness.md)

**Injecting the remainder at the first `UserPromptSubmit`** to place a new
user task ahead of it — position is a weak lever (recency argues the other
way), explicit conditional wording is the strong one, and it needs a
once-per-session latch on a per-turn hook.
[A place for the todo list](changelog/2026-07-22-a-place-for-the-todo-list.md)

**Accepting SDD's pre-6.2.0 flat ledger path for back-compatibility**, and
**dropping the todo suppression altogether** — the first honours the bug,
since the current skill guarantees such a file is somebody else's leftover;
for the second, the two-ledgers-drift rationale is sound and the defect was
in the detection, not the policy. Gating on the named plan file still
existing was rejected too: it false-negatives on a plan that landed and was
tidied away.
[An orphaned ledger hijacks the
handoff](changelog/2026-07-26-orphaned-ledger.md)

**Merging the `PostToolUse(Write|Edit)` scripts** into one — they share a
preamble, now factored into `handoff_match_target()`, but not a job.
[Consolidation pass](changelog/2026-07-20-consolidation-pass.md)

**A parallel pipeline per transition** — the driven clear's first draft:
`.claude/autoclear` beside `autocompact`, its own validator, `Stop` arm,
watcher, failure channel and stale sweep. Sibling-over-parameterisation is
house style and the per-kind validation rules genuinely do differ, which is
why the kind line survives into the unified format. What does not differ is
the pipeline around them. Also rejected: **omitting `/clear` from the
sentinel body** as ceremony (true only while the filename named the
transition), **naming the skills `compact` and `clear`** (namespaced anyway,
so the short name is never available and the collision is paid for in every
doc sentence), **`autocompact`/`autoclear` as skill names** (collides with
the harness's own threshold auto-compaction, a real named feature), and
**one skill per boundary with a prepare/drive mode argument** — the
description is what triggers invocation, so the mode would be inferred from
phrasing, and a false positive compacts or clears a session where the user
asked only for preparation.
[Driven transitions](changelog/2026-07-29-driven-transitions.md)

**Injecting the frame on any compaction where one exists**, closing the
auto-compaction gap for free — but `handoff-task.md` is durable and
git-tracked and sits on disk across days of unrelated work, so this injects
a stale frame into every threshold compaction in every session in the repo,
unrequested and mid-session. The asymmetry is principled: compaction is the
one boundary the harness enters on its own, so it is the one that needs a
signal of intent. Also rejected: **prepare-only with a driven continuation**
— a sentinel whose before-lines are empty but whose after-line is not. Cheap
and appealing, but a skill that types one of the two lines has no sentence
that describes it.
[Driven transitions](changelog/2026-07-29-driven-transitions.md)

## Non-goals

- **Summarising the conversation.** Claude Code already has
  `/compact` (manual and automatic-at-threshold) and Session Memory
  (background summaries surfaced in the transcript). The model is
  trained to handle compacted context. This plugin does not add a
  third summarisation layer — it captures only the two fields those
  mechanisms cannot supply (current task, open decisions).
- **Cross-session thread management.** Auto-memory persists durable
  state across sessions; `claude -c` continues a specific session.
  This plugin addresses the single `/clear` transition, not multi-day
  thread juggling.
- **Validating markdown structure at write time.** `handoff-checkpoint`
  validates the JSON envelope, not the markdown content inside it; the
  templates in `SKILL.md` are trusted, not schema-checked.
- **Replacing `/ddaa:handoff`.** Different target (claude.ai vs
  Claude Code), different scope (full-session summary vs residual task
  frame). Non-overlapping.
- **Claude.ai portability.** The plugin depends on session JSONL,
  Claude Code hooks, and filesystem — all Claude Code-specific. A
  claude.ai variant would need an entirely different mechanism.

## Relationship to `/ddaa:handoff`

`/ddaa:handoff` in the `ddaa` plugin is a claude.ai-oriented full-session
summariser (75–150 line markdown document intended for pasting into a new
web conversation). It is SOTA family #2, manual structured handoff.

This plugin is narrower: Claude Code-only, `/clear`-focused, mechanical
extraction + minimal judgment. Non-overlapping. Both can coexist.

## Changelog

[`changelog.md`](changelog.md) — one line per design change, newest first,
each linking the full write-time record under `changelog/`.

## References

- LangChain's context engineering framing:
  `https://www.langchain.com/blog/context-engineering-for-agents`
- Anthropic on long-horizon agents:
  `https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents`
- Context compaction comparison (Claude Code / Codex / OpenCode / Amp):
  `https://gist.github.com/badlogic/cd2ef65b0697c4dbe2d13fbecb0a0a5f`
- jdhodges handoff pattern:
  `https://www.jdhodges.com/blog/ai-session-handoffs-keep-context-across-conversations/`
- Session JSONL format, community-maintained reference:
  `https://claude-dev.tools/docs/jsonl-format`
- Maintained session-transcript parser (code as format reference):
  `https://github.com/simonw/claude-code-transcripts`
- Hooks reference (PreCompact matchers/output, SessionStart `compact`):
  `https://code.claude.com/docs/en/hooks`
