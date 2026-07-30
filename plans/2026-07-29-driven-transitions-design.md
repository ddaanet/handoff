# Driven transitions — design

Splits the drive-the-TUI half out of `precompact` into its own skill, adds
the symmetric skill for the `/clear` boundary, and replaces the three
one-off TUI drivers with a single armed-transition mechanism that both
depend on.

Revised 2026-07-30 after review; the first draft gave the clear boundary its
own parallel pipeline (`autoclear`, `stop-clear.sh`, `clear-when-idle.sh`).
See *A parallel pipeline per transition* under rejected alternatives.

## Problem

`precompact` does two jobs its name claims only the first of: it prepares
for a compaction, and it drives one. Three consequences.

**There is no prepare-only path for the compact boundary.** `precompact`
flushes memory and updates the task and todo files, and then also authors
the compact directive and the continuation prompt and arms them. An operator
who wants only the first half has no skill for it. And the second half's
contract does not hold everywhere it runs: outside tmux `stop-compact.sh`
emits the two lines to paste, which the skill body it runs under lists as an
anti-pattern — "telling the user to run `/compact`" — while asserting that
"invoking precompact **is** the authorization to compact".

**`handoff` has no driven counterpart.** A mid-task context reset — clear
the window, keep the frame, carry on — is a routine need with no support:
the user types `/clear` by hand and then retypes a resumption prompt into
the fresh session, which is exactly the typing `precompact` exists to
eliminate at the other boundary.

**The asymmetry is unprincipled.** Both boundaries re-inject the same frame
(`handoff_frame()`, shared by both loaders precisely so they cannot drift).
One is driven end to end and the other is not, for no reason in the design.

And one the first draft surfaced by trying to add the fourth entry point:

**The armed transition is a singleton modelled as N files.** One composer,
one session, at most one transition in flight — but the transition's
identity lives in the *filename* (`autorename`, `autocompact`), so the
invariant has nowhere to live and each instance costs a full parallel
pipeline: a constant pair, a validator, a `Stop` arm, a watcher, a failure
channel, a stale sweep. At two instances that duplication was affordable.
The third is where it stops being.

## The four entry points

| boundary | prepare only | prepare + drive |
|---|---|---|
| compaction | `precompact` | `compact-continue` |
| clear | `handoff` | `handoff-continue` |

`autoname` is unchanged in scope — rename only, neither boundary.

The names are the plugin's own vocabulary: `docs/design.md` already
describes the flow as *commit memory → compact → continue*, and
`precompact`'s frontmatter as *an attended "compact and continue" driven end
to end*. The conjunction stays in the prose and out of the name: the
identifier is the boundary and the ending, and `and` distinguishes nothing.
`precompact-continue` would name the preparation twice, so the compact row's
driven name is built on the command rather than on its sibling.

The two skills at a boundary are triggered apart by vocabulary, not by
inference from the situation:

| phrasing | skill |
|---|---|
| "prepare clear", "end", "handoff" | `handoff` |
| "continue after clear", "continue in new session", "handoff, clear, continue" | `handoff-continue` |
| "prepare compaction", "precompact" | `precompact` |
| "compact and continue", "do this after compact" | `compact-continue` |

The vocabularies are disjoint on the word that carries the decision —
*prepare*/*end* against *continue* — and the bare boundary word falls to the
prepare-only skill. An operator who wants the other default sets it in a
user memory or a `CLAUDE.local.md`. The plugin ships no nudge either way:
that default is one operator's habit, not a property of the boundary.

## Why `handoff-continue` is not the poor cousin

The plugin's thesis is that the frame is the irreducible residual — that
what has to cross a session boundary is `## Current task`, `## Open
decisions`, and `## Remaining`, and that everything else is either durable
in memory or reconstructable from the tree. `handoff-continue` is that
thesis applied to a mid-task reset: no summarisation cost, and none of the
cumulative accuracy loss `docs/design.md` records every compaction family
acknowledging. What it gives up is everything the frame does not carry.

For a session with a well-maintained task file it is the better reset, and
it should be built and described as the primary one rather than as
compaction's shadow.

## Answering the merge

The 2026-07-20 change went the other way deliberately, and its argument
stands: **continuation is intrinsic to compacting.** Nobody compacts before
a `/clear` or before stopping, so invoking a compact-boundary skill is
already the decision to compact *and continue*, and "stopping short of it
just made the operator type two things the skill had already worked out."

That argument is about intent, and the split does not touch it. What it does
not establish is that the *agent* must be the one typing — which is a
capability question, is there a tmux pane, and nothing else.

It is not a question of whether the operator wants to see the memory writes
first. The gitlore gate is inside both prepare-only skills already: it
prints the memory submodule's `git status`, requires the summary be
presented as a blockquote and approved before any file is written, and
`precompact`'s arming rule forbids the sentinel from sharing a turn with
that question. Reading the writes before paying for a compaction is not a
preference the split serves — it is mandatory and it already happens.

Both prepare-only skills therefore still end aimed at continuation; they
just hand over the keystrokes.

One consequence follows, and it is the price of honouring the old argument
rather than overruling it — FR-G below.

The rest of the 2026-07-20 rationale is untouched: memory still commits
before the summariser runs, because the checkpoint call is in the
prepare-only half.

## Requirements

**FR-A — `precompact` prepares and stops.** The memory flush, the task and
todo files, and the FR-G expectation marker. No compact directive, no
continuation prompt, no keystrokes, no tmux. The two anti-patterns that
currently forbid stopping there ("telling the user to run `/compact`";
"invoking precompact is the authorization to compact") move to
`compact-continue`.

The split is a claim about naming honesty, not about capability. The
compact directive and the continuation prompt are worth having with no pane
to type them into — the operator pastes them — and authoring them is exactly
what `compact-continue` adds. `precompact` today under-delivers against its
own name because it also drives; reduced to preparation it is honest, and
the driven skill's name states the increment.

**FR-B — both prepare-only skills report readiness in the final reply**,
and only when the checkpoint printed no directive still awaiting an answer.
One line each, reflecting the commit-awareness answer — the routine wrap-up
is `/handoff` → `/commit` → `/clear`, so a bare "Ready to /clear" steps over
the commit.

Neither prints a `/compact` line or a continuation prompt: `precompact` has
none to print, and in `compact-continue` the existing rule stands unchanged
— the continuation is authored silently, and `stop-drive.sh` is the single
producer of the pasteable form, from the sentinel, in order.

**FR-C — `compact-continue` is `precompact`'s protocol plus the
sentinel write.** No new machinery below the skill layer.

**FR-D — `handoff-continue` is `handoff`'s protocol, plus the sentinel
write, plus `precompact`'s arming discipline.** The last clause is not
decoration. `handoff` arms nothing, so it carries neither of the two rules
`precompact/SKILL.md:70-80` needs: *never in the same turn as a question the
directive requires*, and *the commit lands before the sentinel is written*.
Both apply here and neither is inherited.

The normal path is safe by construction — `handoff-continue` runs *after*
`handoff` has settled the gitlore gate, so the checkpoint prints no
directive and case 1 (`handoff` → `/commit` → `handoff-continue`) and case
2 (`handoff` → `handoff-continue`, memory committed standalone via the
trigger) both have a turn for everything. The rules exist for the cold
invocation, where `handoff-continue` is the first thing at the boundary:
dirty memory raises an approval question that ends the turn, and a sentinel
written alongside it clears away the conversation the answer applies to.
A cold `with-commit` invocation additionally clears before the commit it
asserts is coming, leaving `.claude/gitlore-memory-message` owed to a commit
nobody makes.

`handoff-continue` does *not* pass `rename` to the checkpoint: the
sentinel carries the title, as one of its lines.

**FR-E — one sentinel, one arm, one walker.** At most one driven transition
is armed per session, and the file's existence is what says so. The
transition's identity moves from the filename into the file. See
*Architecture*.

**FR-F — every typed line confirms against a harness-authoritative
signal.** The rename is the last exception (`rename-when-idle.sh` greps the
pane for the title's first 20 characters, which matches whenever the title
is on screen for any other reason — the composer's own echo, the skill's
reply naming the title it chose). Closing it is a precondition for the
walker, not a follow-up: the walker's whole structure is a confirmation per
line.

**FR-G — the prepare-only compact path re-injects the frame.**
`load-compact.sh` returns before assembling the frame when there is no
pending file, so a hand-typed `/compact` re-injects nothing. The prepare-only
skill therefore arms a sentinel with an *empty* line sequence: nothing is
typed, but the transition is expected, and the loader's existing gate fires.

The gate itself does not change. Injecting on any compaction whose frame
merely exists is a distinct proposal — see rejected alternatives.

**FR-H — a multi-line sequence re-gates on idle between lines.** Confirming
a line can take minutes (`CONSUME_TIMEOUT` is 300s), and the pane is live
throughout. Nothing may be typed without a fresh `wait_for_idle` and a
fresh `is_typing` check.

## Architecture

### The driven transition

A driven transition is **a sequence of lines to type, and the
`SessionStart` source that confirms the transition happened.**

| kind | lines typed before | lines typed after | confirming source |
|---|---|---|---|
| `rename` | `/rename <title>` | — | — |
| `compact` | `/compact [directive]` | continuation prose | `compact` |
| `clear` | `/rename <title>`, `/clear` | continuation prose | `clear` |
| `compact` (prepared) | — | — | `compact` |

One sentinel, `.claude/autodrive`. Line 1 is the kind; the kind fixes the
shape, so the remaining lines need no separator and each kind keeps its own
validation rules — which genuinely differ, and are the reason the first
draft reached for siblings.

```
clear
/rename Driven Transitions Design
/clear
pick up the driven-transitions implementation per the task file
```

```
compact
/compact focus on the hook wiring
continue with the watcher tests per the task file
```

```
rename
/rename Driven Transitions Design
```

The lines are the literal keystrokes, including `/rename` and `/clear`.
That is the inversion the singleton buys: while the filename named the
transition, writing the command down was ceremony; now it is the content,
and the walker must not know which command any kind uses. Validation still
anchors it — the *n*th line of kind *k* must begin with the expected command
literal, so the file cannot be made to type something else.

`autorename`'s body changes shape accordingly: a bare title becomes
`/rename <title>` under a `rename` kind line. Old filenames get no
back-compat branch.

### Confirmation dispatches on the command, not the kind

Three primitives, one per command class, all already present or specified:

| line | confirmed by |
|---|---|
| `/rename <t>` | a `custom-title` transcript entry with `customTitle == <t>` |
| `/compact`, `/clear` | `.pending` disappearing, which the confirming `SessionStart` does |
| prose | a genuine user-prompt transcript entry (`transcript_prompt_count`) |

Dispatching on the command rather than the kind is what makes `/rename`
work in two kinds with two different fates — terminal under `rename`,
followed by `/clear` under `clear`. It also carries the recognition check
(`is_unknown_command`) for free: any line beginning `/` gets the
type-read-back-Enter path, prose gets the direct one.

The `custom-title` entry is the FR-F primitive:

```json
{"type":"custom-title","customTitle":"<title>","sessionId":"…"}
```

Verified against a live transcript 2026-07-29. `transcript_title_count
<transcript> <title>` counts entries with `type == "custom-title"` and an
exact `customTitle` match — stronger than the prose confirmation's
substring form, and the harness's own auto-titling writes `type:
"ai-title"` so it cannot false-positive. Prints an integer; `0` on an unset
or unreadable path, never an error.

**All three primitives become predicates.** The existing pair
(`submit_consumed_or_fail`, `submit_confirmed_or_fail`) `exit` from inside a
helper, which is only safe as a watcher's final statement — the sole reason
the first draft needed a terminal and a non-terminal form of each. One
walker deciding failure for the whole sequence removes the distinction:
predicates return, `watcher_fail` is called once, at the top.

### The walker

`drive-when-idle.sh`, spawned detached, replaces `compact-when-idle.sh`,
`rename-when-idle.sh` and `continue-when-idle.sh`:

1. `wait_for_idle`; `watcher_fail` if `is_typing`.
2. Type the line. If it begins `/`: `send-keys -l` with no Enter, read back
   `is_unknown_command`, `C-u` and `watcher_fail` if the TUI refused it,
   else Enter. Otherwise Enter directly.
3. Confirm by the command's primitive. On failure, `watcher_fail` — the
   remaining lines are never typed, which is what makes a failed `/rename`
   under kind `clear` cost a wrong title and nothing more.
4. More lines? Back to 1 (FR-H).

The loader spawns the same walker for the after-lines, with a one-line
sequence. There is one watcher script, not four.

### Arming

`.pending` means **a transition is in flight, awaiting its
`SessionStart`.** So `stop-drive.sh` moves the sentinel to `.pending` only
for a kind that has a confirming source, and deletes it outright for
`rename`, which no loader consumes. Either way the move or the delete
happens *before* the spawn, so a later `Stop` cannot re-arm.

An empty before-sequence (FR-G) arms nothing and spawns nothing — the
`.pending` file alone is the whole effect.

### Hooks

Nine become eight, and three scripts are deleted rather than kept as shims.

- **`write-drive.sh`** (PostToolUse(Write|Edit)) — validates the sentinel
  only: kind known, shape legal for the kind, command literals in place.
  Never spawns, never deletes; the file must survive to `Stop`. A malformed
  file gets a `systemMessage` plus an imperative `additionalContext` so the
  agent fixes it in the same turn rather than hitting a silent no-op at
  `Stop`. Path matching is the consume-time cross-project guard. Replaces
  `write-compact.sh` and absorbs `write-rename.sh`'s validation half.
- **`stop-drive.sh`** (`Stop`) — arms, as above. Outside tmux it emits the
  lines to paste and clears the sentinel, as `stop-compact.sh` does today.
  Replaces `stop-compact.sh`.
- **`drive-when-idle.sh`** — the walker. Replaces the three watchers.
- **`load-handoff.sh`** (`SessionStart(startup|clear)`) — gains the
  after-lines. On `source == "clear"` with a `.pending` of kind `clear`:
  consume it and spawn the walker with the after-line and this session's
  `transcript_path`. Silent on `startup`, and on a `clear` with no pending
  file (a hand-typed `/clear` fires the same hook).

  Ordering hazard: the script `exit 0`s when `handoff_frame` finds nothing
  to inject. The consume and the spawn must precede that gate, or a driven
  clear with an empty task file strands the pending file and never
  continues. The script also stops being a pure assembler — its header
  comment promises "silent no-op when the task file is missing or empty" and
  "exits 0 on every path", and both need rewriting.
- **`load-compact.sh`** (`SessionStart(compact)`) — unchanged in structure.
  It already consumes `.pending`, injects the frame, and spawns for the
  after-line; under FR-G an empty after-line means inject and type nothing.
- **`report-watcher-failure.sh`** — one channel instead of two:
  `.claude/autodrive.failed`, one stranded-`.pending` clear on failure, one
  stale bare `autodrive` sweep.
- **`bash-post.sh`** — loses its rename-watcher spawn entirely. A
  checkpoint-written sentinel is armed at `Stop` like any other; the hook
  keeps only manifest staging. `write-rename.sh` goes with it.
- **`_lib.sh`** — five constants (`RENAME`, `RENAME_FAILED`, `COMPACT`,
  `COMPACT_PENDING`, `COMPACT_FAILED`) become three (`DRIVE`,
  `DRIVE_PENDING`, `DRIVE_FAILED`). `handoff_compact_read` becomes
  `handoff_drive_read`, returning the kind and the two line lists.
- **`_rename-lib.sh`** → **`_watcher-lib.sh`**. The name was already wrong
  (its own header says "every detached watcher … despite the name").
- **`hooks.json`** — `write-drive.sh` replaces `write-compact.sh` in the
  `PostToolUse(Write|Edit)` array, `write-rename.sh` leaves it,
  `stop-drive.sh` replaces `stop-compact.sh` on `Stop`.
- **`.gitignore`** — `.claude/autodrive*` replaces the `autorename*` and
  `autocompact*` lines.

### Skill bodies: delegation, not duplication

The judgment is per-boundary, not per-drive-mode. Commit awareness, memory
capture, the task/todo drafting rules, the seam between what belongs in the
file and what belongs in the prompt — all of it is identical whether or not
the agent types the command afterwards.

So it stays in one file per boundary. `handoff/SKILL.md` and
`precompact/SKILL.md` keep the full protocol; the two driven skills are
short bodies that execute the sibling's protocol by reference and then arm.
The precedent exists: `precompact/SKILL.md` already sends the reader to
`../handoff/SKILL.md` for the templates.

The cost is one extra file read per driven invocation. That is the right
trade against two drifting copies of the load-bearing prose — the
commit-awareness rule and the file-vs-prompt seam are the paragraphs the
whole design rests on, and a design where they exist twice is a design where
they will eventually disagree.

### The payload's `skill` field grows to four values

`checkpoint.sh` validates `skill` as one of `handoff` or `precompact`, and
requires `rename` under the former. `handoff-continue` needs `handoff`'s
directive composition without a `rename` — the title belongs in the
sentinel. So `skill` takes four values and names the skill again, honestly.
The directive composition keys on the **boundary** derived from it:

| `skill` | boundary | `rename` |
|---|---|---|
| `handoff` | clear | required |
| `handoff-continue` | clear | forbidden |
| `precompact` | compact | forbidden |
| `compact-continue` | compact | forbidden |

Boundary decides what `checkpoint.sh` composes — memory directive then todo
suppression for clear, memory directive then SDD ledger nudge for compact —
so the two skills at each boundary cannot drift in what they tell the agent.

The alternative is to keep two values and make `rename` merely optional
under `handoff`, at zero cost to the enum or the test matrix. What that
loses is the check that a `handoff` invocation which forgot its title is an
error rather than a silent non-rename, and that check is worth four values.

### Non-tmux

Both driven skills degrade the way `stop-compact.sh` already does —
`stop-drive.sh` emits the sentinel's lines for the operator to paste. That
stays the supported answer: the pane decides who types, not which skill is
right. Capability is settled at `Stop`, from `TMUX`/`TMUX_PANE`, long after
the skill body has run, so it was never something a skill could branch on.
An operator with no pane who wants a compact directive and a continuation
prompt still invokes `compact-continue`; the prepare-only skills author
neither line and cannot stand in.

### The clear boundary confirms exactly like the compact one

Measured in a tmux pane 2026-07-30, against a throwaway workspace whose only
hook logged the raw `SessionStart` payload:

- `/clear` mints a new session id and a new transcript file. The startup
  session was `1a8d2bf3…`; the `clear` payload reported `85b5eb48…`, and a
  second `.jsonl` appeared beside the first.
- `SessionStart(clear)`'s `transcript_path` is the **new** session's, and
  the file already exists when the hook runs. (The payload omits `model`,
  which `startup` carries; nothing here reads it.)
- `transcript_prompt_count` against that path baselines at 0 and reaches 1
  when a prose line is submitted into the fresh session.

So `load-handoff.sh` exports `HANDOFF_TRANSCRIPT` from its own payload
exactly as `load-compact.sh` does, and the after-line's confirmation needs
nothing the compact path did not already need.

The same pane confirmed FR-F's primitive: `/rename Probe Title Alpha` wrote
one `{"type":"custom-title","customTitle":"Probe Title Alpha"}` entry, and
the two `ai-title` entries in the same transcript are the harness's own
auto-titling — a distinct `type`, so an exact `custom-title` match cannot
false-positive on it.

## Rejected alternatives

**A parallel pipeline per transition** — the first draft: `.claude/autoclear`
beside `autocompact`, `write-clear.sh`, `stop-clear.sh`,
`clear-when-idle.sh`, a second failure channel, a second stale sweep, and
`_lib.sh` constants "beside their `COMPACT` counterparts". Two `Stop` hooks
then race for one composer whenever both sentinels exist, and the
at-most-one-armed invariant is represented nowhere — it is a symptom of
duplicating a singleton, not a hazard to guard against. Sibling-over-
parameterisation is house style (`handoff_clear_read` was to be "a sibling,
not a parameterisation — the validation rules genuinely differ"), and the
rules do differ, which is why the kind line survives into the unified
format. What does not differ is the pipeline around them.

**Omitting `/clear` from the sentinel body** — "`/compact <directive>` takes
a focus instruction; `/clear` takes no argument, so writing it down would be
ceremony, and the filename already says which command is armed." True while
the filename named the transition. Under one sentinel the lines to type are
the content, and a walker that infers commands from a kind is the
duplication back again in a table.

**Injecting the frame on any compaction where one exists** — the first
draft's FR-G, offered as also closing a knowingly-accepted gap: auto-
compaction re-injects nothing today. But `handoff-task.md` is durable and
git-tracked and sits on disk across days of unrelated work, so this injects
a stale frame into every threshold compaction in every session in the repo —
unrequested, mid-session, alongside a summary of the actual current work.
That is the manufactured-false-continuity failure the 2026-07-17 entry was
written about, and unlike `startup` there is no turn zero and no visible
`saved 3d ago` for the user to dismiss it at. The asymmetry is principled
after all: compaction is the one boundary the harness enters on its own, so
it is the one boundary that needs a signal of intent. The empty-sequence
sentinel is that signal. Revisitable on its own argument.

**Prepare-only with a driven continuation** — a sentinel whose before-lines
are empty but whose after-line is not: the user pastes `/compact`, the
machinery types the resume. Cheap and appealing, but FR-A's contract is
"touches no tmux", and a skill that types one of the two lines has no
sentence that describes it.

**Naming them `compact` and `clear`** — skills are namespaced, so `/compact`
reaches the builtin regardless and the user types `/handoff:compact` either
way. The short name is never available, so the collision is paid for in
every doc sentence and every disambiguation the model has to make, and
nothing is bought.

**`autocompact` / `autoclear` as the skill names** — short, symmetric, and
consistent with `autoname`/`autorename`, but `autocompact` collides with the
harness's own threshold auto-compaction, a real named feature. The sentinel
keeps the `auto` prefix; the skills do not take it.

**One skill per boundary with a prepare/drive mode argument** — the skill
description is what triggers invocation, so the mode would be inferred from
phrasing. A false positive compacts or clears a session where the user asked
only for preparation. Separate names exist to make the trigger crisp in
exactly the case where getting it wrong is destructive-shaped, and the
trigger vocabulary above is what keeps it crisp.

**Driven clear skipping the rename** — mechanically simplest, and it leaves
untitled sessions in the history at precisely the moments that generate the
most of them.

**Two independent watchers sequenced by confirmation** — contention for one
composer, and the arming would have to wait on a detached process whose exit
status nothing reads. Every serialisation available is a file handshake
between processes that could just be one process. Under FR-E this stops
being a choice: there is one walker.

**Renaming the payload's `skill` field to `boundary`** — the four-value form
is honest, and a rename ripples through `checkpoint.bats`'s whole validation
matrix for a documentation-sized gain.

## Testing

`tests/checkpoint.bats` — extend the existing per-literal matrix: each of
the four `skill` values accepted, an unknown one rejected naming the field,
`rename` required under `handoff` and rejected under each of the other
three, and the boundary derivation asserted through the directive output
(clear-boundary values compose memory-then-todo-suppression; compact-boundary
values compose memory-then-SDD-nudge). The load-bearing assertion is that
`handoff-continue` writes no sentinel of kind `rename`, and it is
mutation-checked rather than observed passing.

`tests/hook-test.bats` —

- `handoff_drive_read` over the per-kind shape matrix: each kind
  well-formed; wrong line count for the kind; a command literal that does
  not match the kind's *n*th slot; an empty prose line; an unknown kind;
  the empty-sequence `compact` form (legal); a bare title with no kind line
  (the old `autorename` shape, which must fail).
- `write-drive.sh` over the same matrix plus a cross-project path.
- `stop-drive.sh`: absent file; malformed; a kind with a confirming source
  arms and renames to `.pending`; kind `rename` arms and *deletes* the
  sentinel; an empty before-sequence arms without spawning; the non-tmux
  branch emits the sentinel's lines in order.
- `load-handoff.sh` on `source: "clear"`: pending present with a frame;
  pending present with **no** frame (the ordering hazard, and the regression
  this row exists to catch); pending absent; `source: "startup"` with a
  pending file present, which must not consume it.
- `report-watcher-failure.sh` over the single channel.

`load-compact.sh` keeps its matrix — the regression it guards is silent, a
frame that stops being injected failing by the successor knowing less rather
than by anything going red: pending present with a frame and an after-line
(both); pending present with no frame (after-line only); pending present
with an empty after-line (frame only, no spawn — the FR-G prepare-only row);
pending absent (silent, and *no* frame — the row that pins the rejected
inject-always variant).

`tests/rename-test.bats` → `tests/watcher-test.bats` —

- `transcript_title_count` against fixture transcripts: matching entry; an
  `ai-title` entry with the same text; wrong title; absent file; malformed
  line.
- each confirmation primitive as a predicate: returns rather than exits,
  records nothing.
- the walker's sequencing: a failed line stops the sequence (kind `clear`
  with a rename that never confirms must never type `/clear`); `No commands
  match` triggers `C-u` and a stop; every non-delivery path reaches
  `watcher_fail` exactly once; and **the re-idle gate** (FR-H, and
  mutation-checked, since a missing re-gate passes every other test in the
  file) — with the stub reporting busy from the first line onward, the
  second line's send must be *delayed* by a full `TIMEOUT`, not suppressed.
  `wait_for_idle` deliberately falls through when it times out; `is_typing`
  is the hard gate, and a pane that is busy without a composed prompt is
  typed into eventually. So the assertion is on the gap between the two
  literal sends, which a missing re-gate collapses to nothing.

The tmux stub and the shortened `HANDOFF_WATCHER_*` tunables already in
`setup()` cover the walker.

## Documentation

Landing this rewrites, in the same pass:

- `docs/design.md` — "The three skills" becomes five. "Driving the TUI" is
  rewritten around the sequence model, and loses the rename-watcher
  exception paragraph; the standing decision *Nothing that asks whether an
  action took effect reads the pane* becomes unqualified. A new standing
  decision states the singleton: the armed transition is one file whose body
  names the transition, because at most one can be in flight and the file is
  where that invariant lives.
- `docs/changelog/2026-07-29-driven-transitions.md` plus its index line in
  `docs/changelog.md`.
- `docs/changelog/2026-07-20-precompact-drives-the-compaction.md` — a
  `> **Superseded 2026-07-29**` blockquote heading the affected section,
  scoped to the one point that actually changed: the driving moves to a
  separate skill, so `precompact` no longer arms the compaction and the
  hands-off ending it reversed returns as a *first-class* ending rather than
  the unconsidered caution it was. Everything else in that entry — memory
  committing before the summariser runs, the one interactive pause, the
  ordering constraint on the sentinel write — carries over unchanged to
  `compact-continue`. It already carries a 2026-07-25 supersession on a
  different point; this is a second, and they do not overlap.
- `CLAUDE.md` — the skill inventory, the hook inventory (nine → eight), the
  script list (three watchers and two write hooks collapse; `_rename-lib.sh`
  is renamed), and the second-flow paragraph, which becomes one flow with
  four entry points.
- `README.md` — the user-facing four-entry-point table.
