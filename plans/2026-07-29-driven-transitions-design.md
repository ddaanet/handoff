# Driven transitions — design

Splits the drive-the-TUI half out of `precompact` into its own skill, adds
the symmetric skill for the `/clear` boundary, and retrofits transcript
confirmation onto the rename watcher that both depend on.

## Problem

`precompact` does two jobs its name claims only the first of: it prepares
for a compaction, and it drives one. Three consequences.

**There is no prepare-only path for the compact boundary.** Outside tmux the
hooks do degrade — `stop-compact.sh` emits both lines for the user to paste
— but that is a fallback contradicted by the skill body it runs under, which
lists "telling the user to run `/compact`" as an anti-pattern and asserts
that "invoking precompact **is** the authorization to compact". A user who
wants to read the memory writes before compacting, or who is in the VS Code
extension, has no skill whose contract matches what will actually happen.

**`handoff` has no driven counterpart.** A mid-task context reset — clear
the window, keep the frame, carry on — is a routine need with no support:
the user types `/clear` by hand and then retypes a resumption prompt into
the fresh session, which is exactly the typing `precompact` exists to
eliminate at the other boundary.

**The asymmetry is unprincipled.** Both boundaries re-inject the same frame
(`handoff_frame()`, shared by both loaders precisely so they cannot drift).
One is driven end to end and the other is not, for no reason in the design.

## The four entry points

| boundary | prepare only | prepare + drive |
|---|---|---|
| compaction | `precompact` | `compact-and-continue` |
| clear | `handoff` | `clear-and-continue` |

`autoname` is unchanged — rename only, neither boundary.

The names are the plugin's own vocabulary: `docs/design.md` already
describes the flow as *commit memory → compact → continue*, and
`precompact`'s frontmatter as *an attended "compact and continue" driven end
to end*. They are long, and that is affordable for commands that are
tab-completed and invoked once per boundary.

## Why `clear-and-continue` is not the poor cousin

The plugin's thesis is that the frame is the irreducible residual — that
what has to cross a session boundary is `## Current task`, `## Open
decisions`, and `## Remaining`, and that everything else is either durable
in memory or reconstructable from the tree. `clear-and-continue` is that
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
capability question (is there a tmux pane?) and a preference one (does the
operator want to read the memory writes before paying for a compaction?).
Both prepare-only skills therefore still end aimed at continuation; they
just hand over the keystrokes.

Two consequences follow, and they are the price of honouring the old
argument rather than overruling it — FR-G and the inversion in FR-B below.

The rest of the 2026-07-20 rationale is untouched: memory still commits
before the summariser runs, because the checkpoint call is in the
prepare-only half.

## Requirements

**FR-A — `precompact` stops before the compaction.** It writes no
`.claude/autocompact`, arms nothing, and touches no tmux. Its final reply
reports readiness. The two anti-patterns that currently forbid this
("telling the user to run `/compact`"; "invoking precompact is the
authorization to compact") move to `compact-and-continue`.

**FR-B — both prepare-only skills report readiness in the final reply**,
and only when the checkpoint printed no directive still awaiting an answer.

For `handoff`, one line, reflecting the commit-awareness answer — the
routine wrap-up is `/handoff` → `/commit` → `/clear`, so a bare "Ready to
/clear" steps over the commit.

For `precompact`, **both lines, in a fenced block**: the `/compact
[directive]` and the continuation prompt. This inverts the existing rule
that the continuation is authored silently and never reprinted. That rule is
correct where a watcher types the line visibly into the pane, making a
preview the same text twice with no veto value. With nothing typing it, an
unprinted continuation is a line the operator cannot run — the skill would
have authored the resume and then swallowed it. The rule stays, unchanged,
in `compact-and-continue`.

**FR-G — frame injection at `SessionStart(compact)` decouples from the
driven path.** `load-compact.sh` currently returns before assembling the
frame when there is no `autocompact.pending`, so a hand-typed `/compact` —
the entire prepare-only path — re-injects nothing. Frame injection gates on
a frame existing; only the continuation gates on the pending file.

**FR-C — `compact-and-continue` is `precompact`'s protocol plus the
`.claude/autocompact` write.** No new machinery below the skill layer.

**FR-D — `clear-and-continue` is `handoff`'s protocol plus a
`.claude/autoclear` write**, and it does *not* let the checkpoint write
`.claude/autorename`.

**FR-E — one watcher owns the whole driven-clear keystroke sequence.**
`/rename <title>` then `/clear`, serially, from a single process. Nothing
else may type into the composer while it runs.

**FR-F — the rename watcher confirms via the session transcript.** Landed
first, so FR-E builds on a confirmed primitive rather than inheriting the
one exception `docs/design.md` already flags.

## Architecture

### FR-F first: rename confirmation

`rename-when-idle.sh` today confirms by grepping the visible pane for the
first 20 characters of the title. That needle matches whenever the title
text is already on screen for any other reason — the composer's own echo,
the skill's reply naming the title it chose — so the check can pass without
a rename having happened. It is the last pane-derived did-it-take-effect
predicate in the plugin, and `docs/design.md` calls it unfinished by age
rather than by principle.

`/rename` writes a dedicated transcript entry (verified against a live
transcript, 2026-07-29):

```json
{"type":"custom-title","customTitle":"<title>","sessionId":"…"}
```

New predicate in `_rename-lib.sh`, beside `transcript_prompt_count`:

- `transcript_title_count <transcript> <title>` — counts entries with
  `type == "custom-title"` and `customTitle` equal to the title. An exact
  match on a dedicated field, so it is *stronger* than the prose
  confirmation's substring-over-user-entries form. The harness's own
  auto-titling writes `type: "ai-title"` and therefore cannot false-positive.
  Prints an integer; `0` on an unset or unreadable path, never an error —
  same contract as `transcript_prompt_count`.
- `rename_confirmed <title>` — baseline the count, send, poll, retry the
  Enter alone, return non-zero on timeout. Same shape as
  `submit_confirmed_or_fail`, including the long unhurried phase (the entry
  is written when the harness processes the command, not when the keystroke
  lands), but a **predicate**: it records nothing and never exits.
- `rename_confirmed_or_fail <title> <reason>` — the terminal wrapper
  (predicate, then `watcher_fail`), for `rename-when-idle.sh`, whose rename
  is the whole job. `clear-when-idle.sh` calls the predicate instead,
  because it has a second step to suppress.

`write-rename.sh` and `bash-post.sh` export `HANDOFF_TRANSCRIPT` from their
payload's `transcript_path` before spawning, joining the two exports they
already do (`HANDOFF_FAIL_FILE`, and `HANDOFF_PENDING_FILE` in
`stop-compact.sh`). The hook owns the path; the watcher stays ignorant of
the layout.

With this landed, no watcher reads the pane to decide whether an action took
effect. The pane is consulted only for the two gates where it is the sole
witness — `is_typing` and `is_unknown_command`, both about whether it is
safe to type *into* the composer.

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
requires `rename` under the former. `clear-and-continue` cannot use either:
it needs `handoff`'s directive composition, but a `rename` in the payload
makes the checkpoint write `.claude/autorename`, which `bash-post.sh`
consumes by spawning the rename watcher *during the turn* — the exact
composer contention FR-E exists to prevent.

So `skill` takes four values and names the skill again, honestly. The
directive composition keys on the **boundary** derived from it:

| `skill` | boundary | `rename` |
|---|---|---|
| `handoff` | clear | required |
| `clear-and-continue` | clear | forbidden |
| `precompact` | compact | forbidden |
| `compact-and-continue` | compact | forbidden |

Boundary decides what `checkpoint.sh` composes — memory directive then todo
suppression for clear, memory directive then SDD ledger nudge for compact —
so the two skills at each boundary cannot drift in what they tell the agent.
`rename` is required exactly where the checkpoint is the thing that renames.

### `.claude/autoclear`

Two lines, mirroring `autocompact`'s role as the armed-transition sentinel:

- **Line 1** — the session title, verbatim, as `/rename` will type it.
- **Line 2** — the continuation prompt: one line of prose, same contract as
  `autocompact`'s line 2 (one Enter is one submit, so an embedded newline
  submits early).

`/clear` itself is not a line in the file. `autocompact`'s line 1 varies
because `/compact <directive>` takes a focus instruction; `/clear` takes no
argument, so writing it down would be ceremony, and the filename already
says which command is armed.

### Hooks

Three new scripts, four changed, plus the shared constants.

**`_lib.sh`** — `HANDOFF_REL_CLEAR`, `HANDOFF_REL_CLEAR_PENDING`,
`HANDOFF_REL_CLEAR_FAILED` beside their `COMPACT` counterparts, and
`handoff_clear_read` beside `handoff_compact_read` (two lines rather than
two-with-a-slash-command-first, so it is a sibling, not a parameterisation —
the validation rules genuinely differ).

**`write-clear.sh`** (PostToolUse(Write|Edit)) — validates only: exactly two
lines, both non-empty. Never spawns, never deletes; the file must survive to
`Stop`. A malformed file gets a `systemMessage` plus an imperative
`additionalContext` so the agent fixes it in the same turn rather than
hitting a silent no-op at `Stop`. Path matching is the consume-time
cross-project guard, same shape as `write-compact.sh`.

**`stop-clear.sh`** (`Stop`) — renames `autoclear` → `autoclear.pending`
*before* spawning, so a later `Stop` cannot re-arm, then spawns
`clear-when-idle.sh` with `HANDOFF_FAIL_FILE`, `HANDOFF_PENDING_FILE`, and
`HANDOFF_TRANSCRIPT` exported. Outside tmux it emits both lines to paste and
removes the pending file, exactly as `stop-compact.sh` does.

**`clear-when-idle.sh`** — the single watcher of FR-E:

1. `wait_for_idle`, then bail via `watcher_fail` if `is_typing`.
2. Type `/rename <title>`; test with the `rename_confirmed` predicate. On
   failure, `watcher_fail` — `/clear` is never typed, so a rename that did
   not land costs a wrong title and nothing else. This is why the predicate
   has to exist separately from its terminal wrapper.
3. Type `/clear` with `send-keys -l` and **no** Enter, read back whether the
   TUI rendered command recognition, `C-u` and abort if it rendered `No
   commands match`, then `submit_consumed_or_fail`. Confirmation is
   `autoclear.pending` disappearing, which `SessionStart(clear)` is what
   does — the same arrangement `compact-when-idle.sh` uses, against the
   same authoritative signal.

Steps 2 and 3 need `rename_confirmed_or_fail` to *not* be terminal, unlike
the existing `submit_*` pair which `exit`. It takes a non-terminal form
(returns non-zero, records nothing) and the watcher decides; the terminal
wrapper stays for `rename-when-idle.sh`.

**`load-compact.sh`** — FR-G. Today it consumes `autoclear`'s counterpart
and *then* assembles the frame, all behind one early return on the pending
file. The two concerns separate:

- **Frame** — injected whenever `handoff_frame` produces one, pending file
  or not. This serves the prepare-only path, and it also closes a gap the
  original design accepted knowingly: the same hook fires for
  *auto*-compaction, which today re-injects nothing. Compaction is the one
  boundary where the frame is withheld, and `load-handoff.sh` already
  injects unconditionally at the other two. The anomaly was the gate, not
  the injection.
- **Continuation** — spawned only on a consumed `autoclear`-equivalent
  pending file, exactly as now. A hand-typed or automatic compaction must
  still type nothing.

The `systemMessage` splits along the same line: the "will resume with …"
wording belongs to the continuation branch, and the frame branch reports
size and age the way `load-handoff.sh` does.

**`load-handoff.sh`** — gains the continuation. On `source == "clear"` with
an `autoclear.pending` present: consume it, spawn `continue-when-idle.sh`
with the *new* session's `transcript_path`. Silent on `startup`, and silent
on a `clear` with no pending file (a hand-typed `/clear` fires the same
hook).

Ordering hazard: the script currently `exit 0`s when `handoff_frame` finds
nothing to inject. The pending consume and the spawn must happen **before**
that gate, or a driven clear with an empty task file strands the pending
file and never continues.

**`report-watcher-failure.sh`** — gains the `autoclear` channel:
`autoclear.failed`, a stranded `autoclear.pending` on failure only, and the
stale bare `autoclear` sweep. The two channels differ only in filename, so
this is a loop over a pair, not a third copy of the body.

**`hooks.json`** — `write-clear.sh` joins the `PostToolUse(Write|Edit)`
array; `stop-clear.sh` joins `Stop`. Eleven hooks, from nine.

**`.gitignore`** — `.claude/autoclear*`, beside the `autorename*` and
`autocompact*` lines and for the same reason: a driver file that exists for
part of one turn and is consumed by a hook.

### Non-tmux

Both driven skills degrade the way `stop-compact.sh` already does — emit the
lines for the user to paste. But that is now a fallback with a first-class
alternative: outside tmux the *supported* answer is the prepare-only skill,
and the driven skills' descriptions say so rather than promising machinery
that will not run.

## Rejected alternatives

**Naming them `compact` and `clear`** — skills are namespaced, so `/compact`
reaches the builtin regardless and the user types `/handoff:compact` either
way. The short name is never available, so the collision is paid for in
every doc sentence and every disambiguation the model has to make, and
nothing is bought.

**`autocompact` / `autoclear` as the skill names** — short, symmetric, and
consistent with `autoname`/`autorename`, but `autocompact` collides with the
harness's own threshold auto-compaction, a real named feature. The sentinel
files keep those names; the skills do not take them.

**One skill per boundary with a prepare/drive mode argument** — the skill
description is what triggers invocation, so the mode would be inferred from
phrasing. A false positive compacts or clears a session where the user asked
only for preparation. Separate names exist to make the trigger crisp in
exactly the case where getting it wrong is destructive-shaped.

**Driven clear skipping the rename** — mechanically simplest, and it leaves
untitled sessions in the history at precisely the moments that generate the
most of them.

**Two independent watchers sequenced by confirmation** — contention for one
composer, and the arming would have to wait on a detached process whose exit
status nothing reads. Every serialisation available is a file handshake
between processes that could just be one process.

**Renaming the payload's `skill` field to `boundary`** — more honest than
four values mapping two-to-one would have been, but the four-value form is
honest too, and a rename ripples through `checkpoint.bats`'s whole
validation matrix for a documentation-sized gain.

## Testing

`tests/checkpoint.bats` — extend the existing per-literal matrix: each of
the four `skill` values accepted, an unknown one rejected naming the field,
`rename` required under `handoff` and rejected under each of the other
three, and the boundary derivation asserted through the directive output
(clear-boundary values compose memory-then-todo-suppression; compact-boundary
values compose memory-then-SDD-nudge). The load-bearing assertion is that
`clear-and-continue` writes no `.claude/autorename`, and it is
mutation-checked rather than observed passing.

`tests/hook-test.bats` — `write-clear.sh` (well-formed, one line, three
lines, empty line, cross-project path), `stop-clear.sh` (absent file,
malformed, well-formed arms and renames to `.pending`, non-tmux branch),
`load-handoff.sh` on `source: "clear"` (pending present with a frame,
pending present with **no** frame — the ordering hazard above, and the
regression this file exists to catch — pending absent, `source: "startup"`
with a pending file present, which must not consume it), and
`report-watcher-failure.sh` over the second channel.

`load-compact.sh` gets its own matrix for FR-G, because the regression it
guards is a silent one — a frame that stops being injected fails by the
successor knowing less, not by anything going red: pending present with a
frame (both), pending present with no frame (continuation only), **pending
absent with a frame** (frame only, no spawn — the prepare-only path, and the
row that would have caught the defect), pending absent with no frame
(silent).

`tests/rename-test.bats` — `transcript_title_count` against fixture
transcripts (matching entry, `ai-title` entry with the same text, wrong
title, absent file, malformed line), `rename_confirmed_or_fail` in both
forms, and `clear-when-idle.sh`'s sequencing: rename failure stops before
`/clear`, `No commands match` triggers `C-u` and abort, both non-delivery
paths reach `watcher_fail`. The tmux stub and the shortened
`HANDOFF_WATCHER_*` tunables already in `setup()` cover the new watcher.

## Documentation

Landing this rewrites, in the same pass:

- `docs/design.md` — "The three skills" becomes five; "Driving the TUI"
  gains the clear sequence and loses the rename-watcher exception paragraph
  (FR-F closes it); the standing decision *Nothing that asks whether an
  action took effect reads the pane* becomes unqualified.
- `docs/changelog/2026-07-29-driven-transitions.md` plus its index line in
  `docs/changelog.md`.
- `docs/changelog/2026-07-20-precompact-drives-the-compaction.md` — a
  `> **Superseded 2026-07-29**` blockquote heading the affected section,
  scoped to the one point that actually changed: the driving moves to a
  separate skill, so `precompact` no longer arms the compaction and the
  hands-off ending it reversed returns as a *first-class* ending rather than
  the unconsidered caution it was. Everything else in that entry — memory
  committing before the summariser runs, the one interactive pause, the
  ordering constraint on the `autocompact` write — carries over unchanged to
  `compact-and-continue`. It already carries a 2026-07-25 supersession on a
  different point; this is a second, and they do not overlap.
- `CLAUDE.md` — the skill inventory, the hook inventory (nine → eleven), the
  script list, and the second-flow paragraph, which becomes two flows.
- `README.md` — the user-facing four-entry-point table.
