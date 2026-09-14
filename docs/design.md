# handoff — Design

Living document. States what this plugin is, how it works today, and why
each standing decision was made. Present tense throughout: when a decision
is reversed, this document is rewritten rather than annotated.

The write-time record of every design change lives in `changelog/`, one
file per change, dated, indexed by [`changelog.md`](changelog.md). Those files are never
edited after the fact — they say what was true and what was believed when
they were written, which is what makes them worth keeping.

Last updated: 2026-09-07.

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

## Requirements

These labels are cited throughout `CLAUDE.md`, the skill bodies and the
scripts' own comments, so they are fixed points: the numbering is never
compacted, and a requirement that dies leaves its number retired rather than
reused. They arrived from two plans with independent numbering, which is why
the driven-transition pair is lettered — `FR-G` and `FR-H` would have
collided as numbers.

**The write path.**

- **FR1** — One entry point, `handoff-checkpoint`, serves every skill that
  writes. Which boundary is in play is a payload field, not a separate
  binary.
- **FR2** — The payload is JSON on stdin, validated against a schema. A
  violation exits non-zero and names the offending field and what was wrong.
- **FR3** — `handoff-task.md` is written only by the checkpoint. An agent
  `Write`/`Edit` to that path is denied. `.claude/autodrive` is held to the
  same rule.
- **FR4** — `handoff-todo.md` is a scratch list by design. The agent edits it
  freely all session; the checkpoint is only the wrap-up path.
- **FR5** — The todo payload supports incremental update:
  `{"action": "edit", "old_string": …, "new_string": …}` as well as content
  written whole. The task file is authored whole, so it has no edit action
  and the schema refuses one.
- **FR6** — A file whose body is empty is removed, and the removal staged.
  File present ⟹ content pending. Empty is what is left once blank lines and
  ATX headings are taken out, a heading being markdown's own — so a shebang,
  a `#tag`, or a `# comment` inside an indented code block are all content,
  and a line of spaces is not.
  [A heading is not a leading `#`](changelog/2026-09-14-a-heading-is-not-a-leading-hash.md)
- **FR7** — Everything the checkpoint writes is staged with `git add -f`,
  deletions included. The checkpoint cannot do it itself (NFR1), so it
  records the paths in `.claude/checkpoint-manifest` and `PostToolUse(Bash)`
  stages them.
- **FR8** — The checkpoint composes `.claude/autodrive` from the transition
  fields — every line that gets typed, including the `/rename` that sets the
  session title.
- **FR9** — Directive output — the memory gate and the SDD ledger nudge — is
  composed in a fixed order, memory first.

**The driven transition.**

- **FR-G** — The prepare-only compact path re-injects the frame. Nothing is
  typed, but the transition is *expected*, and that expectation is what
  `SessionStart(compact)` gates re-injection on — otherwise a hand-typed
  `/compact` would re-inject nothing.
- **FR-H** — A multi-line sequence re-gates on idle between lines.
  Confirming one can take `CONSUME_TIMEOUT` (300s) and the pane is live
  throughout, so nothing is typed without a fresh idle wait and a fresh
  composer check.

**Constraints.**

- **NFR1** — No git or tmux work runs in the agent's sandboxed Bash. A
  sandboxed `git add` can stage successfully while stranding
  `.git/index.lock`, which fails the *next* command — in the routine wrap-up,
  the user's `/commit` — naming a git process that does not exist; and tmux
  is unreachable there at all. This is a constraint, not a preference.
- **NFR2** — The `PostToolUse(Bash)` and `PreToolUse(Bash)` hooks fire on
  every Bash call in every session with the plugin installed. Their negative
  case is one jq parse plus, respectively, one `stat` and one substring test.
  Neither resolves the root unless it has already matched.
- **NFR3** — Skill bodies get shorter, not longer. The checkpoint exists to
  move mechanism out of prose.

**FR12 is gitlore's, not this plugin's** — the registration of the
`gitlore-memory` submodule in `.gitmodules` as the activation gate. It is
cited here because the memory directive keys on it; the rest of gitlore's
numbering has no meaning in this repo.

## Architecture

Five skills, one write path, eleven hooks, and two files that cross a
boundary.

### The seam

`.claude/handoff-task.md` and `.claude/handoff-todo.md` are the durable
side. Both are git-tracked (force-added by a hook; both are listed in
`.gitignore` so *only* a hook can add them). Both are injected verbatim at
`SessionStart`, task first, under one timestamp header — the *frame*,
assembled in memory by `handoff_frame()` in `scripts/_lib.sh` and shared by
the two loaders so the two transitions cannot drift.

- **`handoff-task.md`** — `## Current task` alone. Written **only** by the
  checkpoint; a direct agent Write or Edit is denied by `write-guard.sh`. A
  snapshot of a moment.
- **`handoff-todo.md`** — `## Open decisions` when any remain, plus
  `## Remaining`, open items only. A scratch list the agent edits directly
  all session; the wrap-up only folds in the final remainder. A ledger, not
  a snapshot — open decisions live here rather than in the task file
  because they get revisited and resolved mid-session, same as any other
  open item.

The frame carries no session id, no transcript, no file list, and no
commit/push status. The working set comes from the harness's own
`gitStatus` block at load time.

### One channel, one writer

Both wrap-up skills decide their content and then make exactly one Bash
call: `handoff-checkpoint`, a PATH-resident shim (`bin/`) over
`scripts/checkpoint.py`, taking the whole wrap-up as a schema-validated
JSON payload on stdin — `skill`, `commit`, the boundary's transition field,
`continue`, `rename` at the clear boundary, and `task` / `todo` as a tagged
union: the file's content directly as a string, or an object naming an
action. `task` takes `{"action": "clear"}`; `todo` also takes
`{"action": "keep"}` and `{"action": "edit", "old_string": …,
"new_string": …}`. The task file is authored whole at every boundary, so it
has no edit action, and no keep — a boundary with nothing to carry says so
with `clear`, which is the case an agent used to reach for `null` and get
silence. Both keys are required by key presence: `null` and an absent key
are each a named error, because a spelling that quietly does the wrong
thing is the defect this shape exists to prevent — a wrong one has to fail
loudly rather than acquire a meaning. The action object holds to the same
rule inside itself: its own `action` is read by key presence, so an explicit
`null` is reported as the value it is rather than as an omission, and any key
the named action does not take is a named error rather than a silent
discard. Ignoring one reopens the defect one level down — an agent told
`must be "clear", got "write"` that corrects only the action leaves its
`content` in place, and the frame is removed with nothing said. The payload's
own key set is closed the same way, a level up: a key outside the union any
skill takes is named rather than discarded, since a *misspelled required* key
already fails by key presence while a *superfluous* one — `tasks` beside a
well-formed `task` and `todo` — did not. That check is flat rather than
per-skill, because every known key under a skill that forbids it is already
rejected upstream by a message naming the skill or the transition, and a
per-skill check has no point to run but ahead of those, where it would
replace their wording with a generic one. What is left for it is a key
belonging to no skill's vocabulary, which has nothing skill-specific to say
about it. The two
`required` messages name the whole vocabulary for the same reason: that
branch is what an out-of-date producer sending the retired
`{"file_path": …, "content": …}` shape lands on, so it has to say what to
write instead. There is no `file_path` —
`plan_task`/`plan_todo` compose the real path from `HANDOFF_ROOT`, so a
payload-supplied one would ask the agent to derive a path from a root it
cannot read, only to be checked against the one the write uses anyway. A
violation exits non-zero naming the offending field. The wrap-up is applied
whole or not at all: both halves resolve to a plan — the path, the act, the
body and the manifest lines that record it — before either file is touched,
so every failure the two halves raise leaves the disk as it was.
[The payload names its actions](changelog/2026-09-07-the-payload-names-its-actions.md),
[Nothing is written until both halves resolve](changelog/2026-09-13-nothing-is-written-until-both-halves-resolve.md),
[The vocabulary is closed at both levels](changelog/2026-09-14-the-vocabulary-is-closed-at-both-levels.md)

It gets its root from `HANDOFF_ROOT`, injected into the command's
environment by a `PreToolUse(Bash)` hook (`inject-checkpoint-root.sh`) that
matches any command containing `handoff-checkpoint` or `handoff-approved`,
resolves the root fresh from the payload `cwd`, and rewrites the command to
`export HANDOFF_ROOT=<quoted>; <original>` via `updatedInput` — `export …;`
rather than a bare `VAR=…` prefix, so the value survives a batched command.
The checkpoint refuses when it is unset or not a directory, naming the
unrecognised-invocation cause. Resolving on every call, at the moment the
value is used, replaces an earlier session-keyed pointer file sampled once at
`SessionStart`: `SessionStart(resume)` fires with the *resuming* process's
cwd, before the harness moves the session into its own project dir, so a
sample taken there could stamp the wrong repo onto a pointer read later in
the same session. See
[`docs/changelog/2026-08-10-checkpoint-root-via-updatedinput.md`](changelog/2026-08-10-checkpoint-root-via-updatedinput.md).

The checkpoint applies the writes, removes any file whose resulting body is
empty, composes `.claude/autodrive` from the transition fields, leaves
`.claude/checkpoint-manifest` behind, and prints a directive on stdout. It **changes no git state** and touches tmux not at all — it
queries git read-only and stops there: it runs in the agent's
sandboxed Bash, where `git add` can leave `.git/index.lock` behind and fail
the *next* command (which in the routine wrap-up is the user's `/commit`),
and where tmux is unreachable. `PostToolUse(Bash)` (`bash-post.sh`) consumes
the manifest instead — `git add -f` for every listed path, deletions
included, and a path it could not stage named on both channels rather than
dropped from the counts — that name carries the whole report, a hook's stderr
on `exit 0` reaching neither audience. A root that is not a git repository at
all is separated ahead of the loop and reported once rather than once per
path: nothing there can be staged, and nothing is wrong. A `D` line for a
path `git ls-files` does not list is skipped rather than attempted: both
files are gitignored, so nothing but a hook ever stages them, and a `git
reset` since the last checkpoint — or a file the user wrote by hand — leaves
the path untracked, so this call's removal emits a `D` for something the
index never held. `git add -f` exits 128 there with `did not match any
files`, and that is the one benign failure in this loop. The guard's own exit
status is read rather than inferred from its empty output, a failing `ls-files`
being a repository `add` could not have staged into either. Staging is all it does: a sentinel the checkpoint
wrote is armed at `Stop` like any other, so spawning the walker here would
type into a live turn, which is the one thing the `Stop` gate exists to
prevent.

`file present ⟹ content pending` is an invariant two writers enforce
(`checkpoint.py` and `write-stage.sh`, the latter through a
`_checkpoint_lib.py --is-empty-body` subprocess spawn so the two cannot
disagree about what counts as empty), not an instruction the agent has to
remember. `checkpoint.py` and `_checkpoint_lib.py` (with `drive_when_idle.py`
and `_watcher_lib.py` below) are a 2026-08-10 Python port of what was
`checkpoint.sh` + `_checkpoint-lib.sh`: both did bash's worst work —
structured data, not text streams — and both run once per boundary, never on
a hot path, so the interpreter-startup tax lands where it is cheapest to pay.
The six event hooks that fire on every tool call stay bash. See
[`docs/changelog/2026-08-10-python-split.md`](changelog/2026-08-10-python-split.md).

### The skills

One skill per boundary, plus the rename and the restart:

| boundary | skill | transition field |
|---|---|---|
| compaction | `/handoff:precompact` | `compact`: `false` \| `true` \| `"<directive>"` |
| clear | `/handoff:handoff` | `clear`: `false` \| `true` |

`/handoff:restart` is a fourth, separate skill rather than a third row in
this table — it shares the driven-transition machinery below (a `kind` in
the same sentinel, the same walker) but not the boundary shape: no commit
awareness, no task/todo drafting, no prepare-only reading, because nothing
inside a live session can adopt an upgraded plugin, hook, MCP server, or
`settings.json` — those resolve once, at process startup, so exit-and-relaunch
is the only remedy and it is always typed, never merely prepared. See
"Driving the TUI" below for the kind itself.

`/handoff:pending` is a fifth skill with no design surface at all: it reports
the `## Current task`, `## Open decisions` and `## Remaining` sections of the
frame already injected into context, making no tool call and writing no file.
It appears nowhere else in this document because there is nothing else to say
about it.

The judgment is per-boundary, not per-drive-mode: commit awareness, memory
capture, the task/todo drafting rules and the file-vs-prompt seam are
identical whether or not the agent types the command afterwards. So whether
the transition is typed is a **field of the payload**, decided the way
`commit` already is — one fact the agent supplies, everything downstream
deterministic — rather than a skill of its own.

A separate driven skill per boundary was the earlier shape, and it cost
routing (six trigger phrases each, every one naming the sibling it was not,
so "compact and continue" reaching `precompact` produced a prepared
compaction nobody ran), duplication (the arming discipline and the sentinel's
line shapes stated twice in prose), and expressiveness: driving a transition
*without* a continuation prompt was unreachable, because the driven skills
treated the prompt as intrinsic. The fields cover the cross product:

```
handoff     clear:false          continue:null   prepare only
handoff     clear:true           continue:null   clear, then stop
handoff     clear:true           continue:"…"    clear and continue
precompact  compact:false        continue:null   prepare only
precompact  compact:true|"…"     continue:null   compact, then stop
precompact  compact:true|"…"     continue:"…"    compact and continue
```

The transition field is named after the command it types, and its value is
that command's argument: `/clear` takes none, so it is a bool; `/compact`
takes an optional focus directive, so it is a bool or the directive itself.
`false` does not mean "no sentinel" — it means the command is not typed.

What the separate skills bought, and what this gives up, is that the
transition was settled by *which name the description matched* rather than
by reading the request: a misread now drives a transition where only
preparation was asked for. The fields are required and have no default, so
the question is at least always asked; and the prepare-only wording is the
larger half of both descriptions, since that is the reading a bare
"handoff" or "precompact" should get.

- **`/handoff:autoname`** — rename only, neither boundary. Decides a title
  and calls the checkpoint with `{"skill": "autoname", "rename": …}`, the
  whole payload. Every other field is a schema error under it, and no
  directive is composed — its description promises no memory write, and a
  memory directive is an instruction to make one. For `/btw` side
  conversations and any session worth a name while the main thread stays
  live.
- **`/handoff:restart`** — exit and relaunch, neither boundary either. Its
  whole payload is `{"skill": "restart", "continue": …}`: no title (a
  restart renames nothing), no task/todo, no commit awareness, and every
  boundary field is a schema error under it by the same key-presence rule
  autoname uses. No directive is composed, for the same reason as autoname —
  nothing here implies a memory write. Unlike autoname it does carry
  `continue`, since a restart can still be handed a continuation prompt for
  the far side.

### Driving the TUI

A **driven transition** is a sequence of lines to type, plus the
`SessionStart` source that confirms it happened:

| kind | typed before | typed after | confirming source |
|---|---|---|---|
| `rename` | `/rename <title>` | — | — |
| `compact` | `/compact [directive]` | continuation prose, if any | `compact` |
| `clear` | `/rename <title>`, `/clear` | continuation prose, if any | `clear` |
| `compact` (prepared) | — | — | `compact` |
| `restart` | `/exit`, `claude --resume <sid…>` | continuation prose, if any | `resume` |

`restart`'s shape mirrors `clear`'s exactly — two required before-lines, one
optional after-line — but crosses a boundary neither other kind does: its
second before-line is typed into a bare shell, not the Claude Code TUI, once
`/exit` has actually torn the process down. `checkpoint.py` composes only
`claude --resume <sid>` (the session id from `CLAUDE_CODE_SESSION_ID`; it has
no view of the process's own argv), and that is the whole line: it is typed
exactly as composed, and nothing fills in flags.

The bare name is what makes that sufficient. The shell resolves it through
PATH, so every launcher shim the original invocation went through runs again
and contributes what it contributes — here, one prepending `--plugin-dir
<repo root>` and gitlore's prepending `--settings
'{"autoMemoryDirectory":…}'`. Re-entering them is also the only way to
restore what is not on a command line at all: gitlore's shim `export`s
`GITLORE_LAUNCHED=1`, which its own anti-double-inject guard reads. A shim
`exec`s the real binary, so it occupies no process of its own and cannot be
found by inspecting the tree — running it again is the only handle on it.

Replaying the exiting process's argv is what this replaced, and the reason is
that the two compose badly: that argv already contains what the shims
injected, so replaying it hands them a line they then inject into again —
one more copy of every flag per restart, growing without bound. Dropping the
replay costs a flag typed by hand on an install with no shim to resupply it,
which is now silently lost, and takes with it the `/proc` parent-chain walk
that existed only to read those flags.
[The relaunch stops replaying argv](changelog/2026-08-14-the-relaunch-stops-replaying-argv.md)

`stop-drive.sh` touches no line of a `restart` sentinel, then. Its one
restart-specific act is to clear a stale `.claude/autodrive.exited` before it
arms and spawns, so an earlier, only-partly-successful attempt's leftover
cannot let this one's `/exit` confirmation false-positive.

The after-line is optional on both driven kinds, because typing the
transition and submitting a prompt into what it opens are separate
decisions.

One sentinel, `.claude/autodrive`, whose first line is its **state** and
second line the kind. The states are `held` → `armed` → `pending` → gone,
and every one after the first is a hook's to write. `checkpoint.py` is the
file's one writer — it composes the sentinel and reads its own output back
through the parser, so composer and parser cannot drift, and a direct agent
Write or Edit is denied at `PreToolUse`. The remaining lines are the **literal keystrokes**, so
the walker never needs to know which command belongs to which kind;
validation anchors it instead — the *n*th line of kind *k* must begin with
the expected command literal, so the file cannot be made to type something
else. One fact per line throughout.

Mid-turn input has four distinct classes, and prose — not the slash command
— is the dangerous one: it is injected into the running turn's next model
call. So no line is ever typed from inside a live turn. `Stop`
(`stop-drive.sh`) arms the before-lines, rewriting the sentinel's state from
`armed` to `pending` *before* spawning; a later `Stop` acts only on `armed`,
so it cannot re-arm one in flight. The transition's own `SessionStart`
consumes that file — only in state `pending`, and only of its own kind — and
spawns the after-line. One walker,
`drive_when_idle.py`, serves every case: wait for idle, type, confirm,
re-gate on idle, next line. A line that fails to confirm stops the sequence,
which is what makes a `/rename` that never lands under kind `clear` cost a
wrong title and nothing more.

Confirmation dispatches on the **command**, not the kind — which is what
lets `/rename` appear in two kinds with two different fates, and carries the
recognition check for free, since any line beginning `/` takes the
type-read-back-Enter path. Four primitives: a `custom-title` transcript
entry for `/rename`, the sentinel disappearing for `/compact`, `/clear` and
`claude --resume …` — a `SessionStart` is what removes it in every case,
though the TUI lines ask delivery and confirmation as one question
(`submit_consumed`) while the relaunch splits them (`submit_launched`, then
`wait_for_consumed`: see below) — a genuine
user-prompt transcript entry for prose, and `.claude/autodrive.exited`
appearing for `/exit` — the one primitive with the opposite polarity, since
`SessionEnd` can only ever create that marker, never remove one that
predates the attempt. The walker reads the pane only where the pane is the
sole witness — gating *typing into* the composer (`composer_has_user_text`,
`line_landed`, `is_unknown_command`). Nothing that asks whether an action
*took effect* looks at it. Each carries no opinion about the chrome around
what it reads: `line_landed` asks whether the composer holds the line just
typed, rather than whether it holds anything — an idle composer is never
empty, since the TUI paints a faint suggestion into it — and the pre-send bail
keys on the **cursor**, the only signal that separates that suggestion from
something a person typed, with the composer's start column derived from the
captured line rather than pinned to today's layout. Both poll rather than
sampling once: the pane does not always repaint within `VERIFY_DELAY`, and
read once, a late repaint is indistinguishable from a swallowed keystroke.
Their fixtures are captures from a live TUI, and `just tui-conformance`
asserts those captures still match one — a hand-written fixture is how a
predicate comes to be tested against its own premise, which is what let
`is_typing` sit inverted against a U+00A0 composer gap while its suite stayed
green. [Composer predicates match the real
pane](changelog/2026-08-13-predicates-match-the-real-pane.md)

Every TUI submit sends Enter, retries three times fast, then waits without
pressing again — a registered Enter can take far longer than `VERIFY_DELAY`
to reach its signal, and a composer that already took the first would submit
the turn twice. Delivery and confirmation are one question there: the only
evidence the keystroke arrived is the thing it caused.

The relaunch line separates them, which is what a shell prompt allows. The
pane's foreground leaving the shell says the line ran, and says it
immediately, so Enter repeats only while the shell is still in front and the
happy path presses once. Confirmation — the sentinel going, which the resumed
session's `SessionStart` does — is then waited for without touching the pane.
Retrying against that signal instead is guaranteed to press again before it
can arrive, since a whole Claude Code boot sits in between, and those presses
land in a starting session where an Enter answers whatever dialog is on
screen rather than costing an empty prompt line.
[The relaunch presses Enter once](changelog/2026-08-14-relaunch-presses-once.md)
Neither suite reaches the whole path: confirming a `/compact` needs a real
compaction, so the submit primitives are proven only by driving a transition
for real against the change that touched them. That dogfood is part of
landing such a change, not a follow-up to it — until 2026-08-13 the Enter-and-
confirm path had never once executed in production, because every driven line
aborted at the composer check before reaching it, and its unit suite was green
throughout. [The first driven transition to
land](changelog/2026-08-13-first-driven-transition-lands.md)
The first end-to-end restart dogfood, 2026-08-15, found the next thing only
that path could show: `/exit` and the relaunch landed, but the continuation
line — driven by a second, separate walker that `load-restart.sh` spawns at
`SessionStart(resume)` — did not. `_drive_line`'s budget (near-instant
`wait_for_idle`, a 0.5s verify sleep, a 3s landing poll) was sized for driving
a TUI that is already running, true for `/compact`/`/clear`'s continuations
since their `SessionStart` fires on a live process, but `restart`'s
continuation is the one case that budget faces a process that has just exec'd
and has no composer yet — measured at 3.9s for a bare launch of this plugin's
own hook chain to render one. `wait_for_composer` polls for the `❯` glyph's
mere presence, ahead of every other check in `_drive_line`, and is a no-op
mid-session, where the composer is already there. [The continuation waits for
the composer to
exist](changelog/2026-08-15-continuation-waits-for-the-composer-to-exist.md)

`claude --resume …` skips those composer checks entirely: it
targets a bare shell once `/exit` is confirmed, where neither the `❯`
composer glyph nor the "No commands match" text exist, and neither is a
reliable signal of a shell's own readiness across every user's shell prompt.
What stands in is the pane's own foreground command. Claude Code stops
consuming input well before it releases the terminal, and a keystroke sent
inside that window is dropped leaving no trace, so the line waits until
`#{pane_current_command}` reads as something other than the baseline sampled
before the sequence began. `HANDOFF_WATCHER_SHELL_SETTLE` survives that gate
as a bounded residual: the shell still redraws its prompt once it has the
foreground back, and that part is not separately observable.
[Restart drive repair](changelog/2026-08-13-restart-drive-repair.md)

Which line that is, the walker decides from the line itself — it is handed
literal keystrokes and knows no kinds. It parses the line as a shell word list
and matches argv[0]'s basename against `claude`, with `--resume` among the
arguments. A parse rather than a prefix test on the one spelling that reaches
it today: while `stop-drive.sh` rewrote the slot into the exiting process's
argv, argv[0] was the resolved binary, so the line began with `/` and read as
a slash command — the prefix test recognized only the shape nothing typed. The
`--resume` conjunct keeps a continuation prompt that opens with the word
`claude` as prose.
[Dispatch on the command, not the prefix](changelog/2026-08-14-resume-line-dispatch.md)

A detached walker's exit status is read by nothing, so non-delivery is
written to `.claude/autodrive.failed` and reported by
`report-watcher-failure.sh` at the next `UserPromptSubmit` — the first
moment anything can act on the news. That hook also sweeps a sentinel still
in state `armed`, left by a turn that ended on Esc or a crash:
`UserPromptSubmit` is the exact discriminator, since it cannot fire between
the write and that turn's own `Stop`. A file that will not parse is swept
too — it describes no transition anyone can complete. `held` is exempt while
it belongs to the session at the prompt, and that is why the sweep names its
states rather than taking anything that is not `pending`.

The prepare-only compact path arms the kind line alone. Nothing is typed,
but the transition is *expected*, and that expectation is what
`SessionStart(compact)` gates the frame's re-injection on — otherwise a
hand-typed `/compact` re-injects nothing.

`load-restart.sh` (`SessionStart(resume)`) never assembles or injects the
task-frame the way `load-compact.sh` and `load-handoff.sh` do: `--resume`
already restores the full prior conversation on its own, so there is nothing
for a frame to hand a summariser's paraphrase back to. The only effect there
is firing whatever continuation was typed after the resume — which is the
whole reason a restart costs no context at all.

A restart that fails partway has no live session to report into: if `/exit`
itself never lands, the original session is still up and its own next
`UserPromptSubmit` reports the non-delivery as usual; if `/exit` succeeds but
the resume command then fails, that session is gone, and the report waits —
`report-watcher-failure.sh`'s files are project-scoped, so whatever session
next opens in that directory drains `.claude/autodrive.failed` at its own
first `UserPromptSubmit`, however much later that is. A deferred report, not
a lost one.

### Held: a transition an approval has not released

The hazard a memory approval creates is keystrokes reaching a pane whose
turn is about to end on a question: a transition armed alongside that
question clears or compacts away the very conversation the answer applies
to. So the checkpoint writes a sentinel in `held` exactly when it **types
anything at all** and a memory directive was emitted, and composes the
instruction to release it onto the end of that directive.
`bin/handoff-approved` is the one command that leaves the state, through the
same `handoff_drive_arm` the `Stop` hook uses.

The condition names the hazard rather than its trigger, and the hazard is
the keystrokes, not which transition they carry. An untyped handoff types no
transition but still types `/rename`, into the same pane, racing the same
answer — so it holds too. What is exempt is the sentinel that types nothing
at all: the bare compact marker, which would otherwise lose the expectation
`SessionStart(compact)` gates the frame's re-injection on to a gate it has
no reason to wait on. Only the memory gate defers: the ledger nudge and the
todo boundary are acts, not questions, and `Stop` comes after them either
way.

`held` is the one state that outlives the turn that wrote it, so it is the
one that names its owner — the session whose approval it waits on, carried
on line 1 as `held <session-id>`. That approval arrives in that session or
not at all: once another session is taking prompts in the repo, the file is
abandoned, and `report-watcher-failure.sh` sweeps it exactly as it sweeps a
stale `armed` one. Without the name it would stay armable indefinitely, and
`handoff-approved` — which verifies the state and nothing else — would drive
a dead session's `/rename` and `/clear` into a live conversation.
`handoff_drive_arm` replaces line 1 whole, so leaving `held` drops the owner
with it, which is right: past the approval there is no outstanding one, and
no state below `held` accepts an owner.

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
there, and a `$PWD` fallback is wrong in exactly the drift case. So a
`PreToolUse(Bash)` hook (`inject-checkpoint-root.sh`) resolves the root the
same way, at the moment a `handoff-checkpoint` or `handoff-approved`
invocation is about to run, and injects it as `HANDOFF_ROOT` into that one
command via `updatedInput`. An earlier design published the root once per
session instead, at `SessionStart`, to a session-keyed pointer file the
checkpoint's Bash could address blind. That sample was taken at the one
moment the cwd does not yet belong to the session —
`SessionStart(resume)` fires with the *resuming* process's cwd, before the
harness moves the session into its own project dir — so it could stamp a
stale or wrong repo onto a pointer a live session then read for its whole
remaining lifetime. Resolving per call has no such moment. See
[`docs/changelog/2026-08-10-checkpoint-root-via-updatedinput.md`](changelog/2026-08-10-checkpoint-root-via-updatedinput.md).

The drift marker is the plugin's remaining state outside a project, and it
has no owner that outlives the session. `session-pointer.sh` sweeps it (and
whatever stale root-pointer files the retired mechanism already left on
disk) on every `SessionStart`, deleting files older than seven days, scoped
by name to what this plugin writes and by `-maxdepth 1` to the level it
writes them at — the directory is shared and holds files this plugin never
wrote. A `SessionEnd` hook would clean up only the ends that fire one, which
is the opposite of the set that strands a file.

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

`ledger_path` is the one-row registry of foreign workflow-owned
progress ledgers (currently superpowers SDD). It detects **liveness**, not
presence: the current layout glob plus an identity first line, most-recent
mtime among several, fail open. Both the nudge and the todo-file boundary
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
  pointer), and pinning to a tag makes upgrades explicit — the pinned
  version is `plugin-dev/VERSION`, which is the vendored tree's own record
  of it rather than a copy here that would rot at the next update.
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
— *does the ask this call serves imply a commit?* — is a fact about the
conversation that no script can see, and everything downstream of the answer
is deterministic. It changes what memory *says* (under `with-commit`, bodies
state present-tense truth, because a body phrased as pending is false the
moment the change exists and gets re-injected that way) and where the memory
commit *lands*. The transition fields are the same shape, which is why they
are fields and not skills.
[Commit awareness](changelog/2026-07-25-commit-awareness.md),
[Transitions become modes](changelog/2026-08-05-transitions-become-modes.md)

**Ask the question the request can answer.** The rule this replaced counted
a commit landing in a later session, because it framed the question as where
the memory belongs rather than whether anything present decides it — and
that is unanswerable in the prepare-only modes, where the agent has no
evidence in front of it and guesses. It is also the hazard: withholding
gitlore's trigger defers the memory commit to a parent commit's pre-commit
hook, and a commit on the far side of a `/clear` is owed by no live session,
so the approved summary goes unread and the next session's memory write
stales it. The ask stops at the transition, uniformly — a compaction keeps
the session alive, so a commit named in *its* continuation prompt would in
fact have a live hook, but one sentence that holds for every mode is worth
more than one correctly deferred memory commit.
[Transitions become modes](changelog/2026-08-05-transitions-become-modes.md)

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

**The transition carries its own state.** There is exactly one transition in
flight at a time, and two filenames were one object at two points in its
life — so every gate read the point it cared about by choosing a name, and
the machine between them existed only as `mv` calls scattered across four
hooks. Line 1 of `.claude/autodrive` is the state and the gates are state
checks, which is the same guarantee stated directly: `Stop` will not re-arm
something already in flight, and the sweep will not take something
legitimately mid-window. Adding a state is now a value, not a filename and
four new gates. The state being content rather than a name also makes a
wrong one writable, which is why the file has a single writer: the
checkpoint composes it, and a direct agent Write or Edit is denied outright.
[One transition, one file, explicit
state](changelog/2026-08-03-one-transition-one-file.md)

**Observability is not gated on the happy path.** A clean run says nothing
about whether a dirty one would be noticed, and the failing run is exactly
the one nobody is watching. Every non-delivery path a watcher can observe
itself writes a reason to a file. Nothing is inferred from state that is
legitimately present (a file in state `pending` during the whole Stop →
compaction window): a false-positive-free signal is worth the tail of
watchers killed outright.
[A detached watcher's failure has to become a
file](changelog/2026-07-20-watcher-failure-becomes-a-file.md)

**A foreign tool's state file is detected by liveness, not presence.**
Layouts move and the old path becomes a declared stray; abandoned files are
never cleaned up. Presence alone false-positives, and the harm is a directive
naming another plan's file as this session's ledger. Detection is read-only
and fails open.
[An orphaned ledger hijacks the
handoff](changelog/2026-07-26-orphaned-ledger.md)

**A foreign ledger scopes the todo file; it does not replace it.** An SDD
ledger holds the tasks of one plan and is deleted with it. `handoff-todo.md`
holds work outstanding across sessions, most of it belonging to no plan and
often to another repository. Only their overlap — the plan's own tasks,
copied across — can drift, so only the overlap is excluded. Standing the
whole file down discards every item no ledger will ever carry, in the one
direction a `/clear` cannot recover.
[The ledger and the todo file are different
scopes](changelog/2026-08-08-ledger-and-todo-are-different-scopes.md)

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

**A context-size nudge was tried and dropped.** `PostToolBatch` fired once a
session's prompt crossed a fixed threshold, injecting a directive naming
`/handoff:precompact`. Dropped rather than fixed: it fired too early on a
prompt that was already large for legitimate reasons, and once right after a
driven compaction against a context the boundary had just shrunk. Sometimes
followed, sometimes ignored — the net was more trouble than the nudge earned.
[Nudge the boundary at a context-size
threshold](changelog/2026-08-01-context-threshold-trigger.md),
[A compaction invalidates every sample above
it](changelog/2026-08-09-samples-are-scoped-to-the-compaction.md), and
[the removal](changelog/2026-08-10-drop-context-threshold-nudge.md).

**Deciding makes zero tool calls.** `handoff`'s Step 1 and Step 3 both decide
from the conversation already in context — the agent already holds
everything it needs, and a Read/Bash/Grep call there duplicates work
`handoff-checkpoint` does internally while risking action on state gone
stale by write time. A live session read the rule seconds beforehand and
still `cat`-ed both task files "to check": a general verify-before-acting
habit overrode an instruction that read as descriptive rather than binding.
The rule is now one standing prohibition ahead of both steps, phrased as an
imperative on the next action, with the reason stated inline and a matching
`## Anti-patterns` entry.
[Deciding makes zero tool calls, stated
once](changelog/2026-08-11-decide-with-zero-tool-calls.md)

**Nothing about the exiting process is read.** A driven restart once
identified it by a bounded parent-chain walk, to replay its argv — `$PPID`
inside a hook is the `/bin/sh -c` wrapper Claude Code spawns, whose argv is
the hook command line, so the naive reading relaunched the hook itself. The
walk fixed that and the replay then compounded the launcher's flags one copy
per restart, so both are gone: the line is composed from the session id alone,
and the one thing still needed from that process — the moment it lets go of
the terminal — is read from the pane, not from the process table.
[The relaunch stops replaying argv](changelog/2026-08-14-the-relaunch-stops-replaying-argv.md)

## Rejected alternatives

**A bare magic-string sentinel for the payload's actions** — `"@empty"` or
`"clear"` as the value of `task`, instead of `{"action": "clear"}`. It
reinstates the defect class it was meant to retire, one spelling along: a
typo in a bare token is indistinguishable from content, so `"claer"` is
written to the file as the task frame's body, silently, exactly as `null`
silently meant "no-op". `{"action": "emty"}` is a schema error naming the
field, because the object shape is what makes the value's role explicit
enough to check. This is the first shape considered at the proof pass, and
the one a future session will re-propose.
[The payload names its actions](changelog/2026-09-07-the-payload-names-its-actions.md)

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

**Accepting SDD's pre-6.2.0 flat ledger path for back-compatibility** — it
honours the bug, since the current skill guarantees such a file is somebody
else's leftover. Gating on the named plan file still existing was rejected
too: it false-negatives on a plan that landed and was tidied away.
[An orphaned ledger hijacks the
handoff](changelog/2026-07-26-orphaned-ledger.md)

**Letting the plan's tasks live in both files**, tracked in the ledger and
mirrored into `handoff-todo.md` — two records of one thing drift, and the
stale one gets believed. Excluding the overlap costs nothing, which is why
the boundary is drawn there rather than around the file.
[The ledger and the todo file are different
scopes](changelog/2026-08-08-ledger-and-todo-are-different-scopes.md)

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
doc sentence), and **`autocompact`/`autoclear` as skill names** (collides
with the harness's own threshold auto-compaction, a real named feature).
[Driven transitions](changelog/2026-07-29-driven-transitions.md)

**Keeping the sentinel a skill-body write** once the transition became a
payload field — a minimal diff, but the fields would then be advisory: the
checkpoint could validate the combination and nothing more, the line shapes
would stay as prose in two skill bodies, and arming discipline would stay a
rule the agent is asked to follow rather than one the code enforces. Also
rejected: **printing the sentinel for the agent to write when deferring**
(transcription through the model on the one path where correctness matters
most), **a second full checkpoint call carrying the resolved gate** (it
deadlocks — under `with-commit` the memory worktree is still dirty when the
gate resolves, so the second call re-emits the same directive and refuses to
arm), and **`--arm` as a flag on `handoff-checkpoint`** (overloads a command
whose contract is "read a payload on stdin" with one that reads nothing).
[Transitions become modes](changelog/2026-08-05-transitions-become-modes.md)

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

**Every way of identifying the exiting `claude` process** — its argv was once
replayed as the relaunch line, and three candidates were weighed for finding
it: the hook script's grandparent (the `/bin/sh -c` wrapper survives or is
exec-optimised away at the shell's discretion, so a fixed depth is the same
brittleness under a different constant), a parent-chain walk by argv[0]
basename (shipped, then withdrawn), and tmux's `#{pane_pid}` (exact and
indifferent to the process's name, but the composer ran before the tmux check
and had to serve the not-in-tmux paste path too, where there is no pane to
ask). The whole question is closed rather than settled: the line is composed
from the session id alone, so nothing identifies that process at all.
[Restart drive repair](changelog/2026-08-13-restart-drive-repair.md),
[The relaunch stops replaying argv](changelog/2026-08-14-the-relaunch-stops-replaying-argv.md)

**Lengthening `HANDOFF_WATCHER_SHELL_SETTLE`** — tuning a constant against
an unbounded shutdown. The failure returns under load, and it is silent: the
pane looks untouched.
[Restart drive repair](changelog/2026-08-13-restart-drive-repair.md)

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
