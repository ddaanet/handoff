# Transitions become modes of the two boundary skills — design (2026-08-02)

Removes `handoff-continue` and `compact-continue`. What they added over their
siblings — the transition command and the continuation prompt — becomes two
payload fields, decided by the base skill the same way `commit` already is.

Lands after
[one transition, one file, explicit state](2026-08-03-transition-state-machine-design.md),
whose state field is what the deferred-arming case below writes into.

## Problem

Four skills, two boundaries. The pair at each boundary differs only in whether
the transition is typed, and that difference costs:

- **Routing.** Six trigger phrases per description, each one naming the sibling
  it is not. "compact and continue" reaching `precompact` produces a prepared
  compaction nobody runs; "prepare compact" reaching `compact-continue` compacts
  a session the user meant to keep.
- **Duplication.** The arming discipline, the seam rules and the anti-patterns
  are stated twice, once per driven skill, and the sentinel's line shape is
  stated in prose in both.
- **Expressiveness.** The cross product is not covered. There is no way to drive
  a transition without a continuation prompt, because the driven skills treat
  the prompt as intrinsic.

The base skills already carry a mode field. `commit` was added when the same
shape appeared for memory routing: one fact the agent supplies, everything
downstream deterministic. The transition is that shape again.

## The contract

`skill` collapses to two values, `"handoff"` and `"precompact"`. `rename` stays
required under `handoff` and forbidden under `precompact`, which is what still
makes a `handoff` call that forgot its title an error rather than a silent
non-rename.

Two new fields, both **required** — no default. A default is the answer given by
an agent that never considered the question, and considering it is the whole
contribution:

| | `handoff` | `precompact` |
|---|---|---|
| transition | `clear`: `true` \| `false` | `compact`: `false` \| `true` \| `"<directive>"` |
| continuation | `continue`: `null` \| one line of prose | `continue`: `null` \| one line of prose |

The transition field is named after the command it types, and its value is that
command's argument: `/clear` takes none, so it is a bool; `/compact` takes an
optional focus directive, so it is a bool or the directive itself.

`false` does not mean "no sentinel". It means the command is not typed:

```
handoff     clear:false          continue:null   prepare only
handoff     clear:true           continue:null   clear, then stop
handoff     clear:true           continue:"…"    clear and continue
precompact  compact:false        continue:null   prepare only
precompact  compact:true|"…"     continue:null   compact, then stop
precompact  compact:true|"…"     continue:"…"    compact and continue
```

One error class beyond the per-field ones: `continue` non-null while the
transition is not typed. Nothing would type it, so it is a schema violation
rather than a silent drop.

The checkpoint validates `continue` itself — non-empty after whitespace
stripping, a single line, no leading `/` — and the `compact` directive string
for the first two. It has to: it writes the sentinel directly, so
`write-drive.sh` never sees the result.

### Commit-awareness narrows

`with-commit` becomes: **a commit lands in this session, before the
transition.**

The rule it replaces counted a commit landing in a later session, because the
question was framed as where the memory belongs rather than when it lands. Under
a driven clear that framing breaks. Withholding gitlore's trigger file defers
the memory commit to a parent commit's pre-commit hook; if the parent commit is
on the far side of a `/clear`, no live session owes it, the approved summary
goes unread, and any memory write in the new session stales the summary and
aborts the commit that would have collected it.

So a continuation prompt asking for a commit is evidence of `without-commit`,
not of `with-commit`. This also unifies with the ordering rule the driven skills
already carried — the commit lands before the sentinel is written — which is the
same constraint stated from the other side.

Compaction is unaffected: it stays in-session, so a commit after it is still
this session's.

This supersedes the corresponding paragraph of
`docs/changelog/2026-07-25-commit-awareness.md`.

### Retired claim

`compact-continue` asserted "continuation is intrinsic: compact ⟹ continue",
reasoning that nobody compacts before stopping. That was a fact about the
skill's contract, not about the transition — a prepared compaction followed by a
stop was always reachable by typing `/compact` by hand. `compact:true
continue:null` makes it expressible, and the claim goes.

## Mechanics

### The checkpoint composes the sentinel

It has the kind (from `skill`), the title, the transition and the continuation,
so it builds the whole file. It then validates its own output through
`handoff_drive_read` before writing, so the composer and the parser cannot
drift.

No skill body restates the line shapes. Both "exactly N lines" blocks disappear
with the skills that held them.

### Held versus armed

`held` is the state the machine was left room for. Write the sentinel in it iff
the sentinel **types something** and a memory directive was emitted:

```
types nothing (rename kind, bare compact marker)  -> armed   always
types something, no memory gate                   -> armed   fires at this turn's Stop
types something, memory gate emitted              -> held    + arming instruction
```

The condition names the hazard rather than its trigger. The hazard is
keystrokes reaching a pane whose turn is about to end on an approval question: a
sentinel armed alongside that question clears or compacts away the very
conversation the answer applies to. A sentinel that types nothing has no such
hazard, so the two non-typing kinds keep today's behaviour exactly — and a
prepare-only precompact cannot lose its FR-G marker by forgetting a second call.

Only the memory gate defers. The SDD ledger nudge and the todo suppression are
acts, not questions; `Stop` comes after them either way.

The arming instruction is composed with the memory directive, since that is the
only thing that ever holds a sentinel back.

### `handoff-approved`

A `bin/` shim on the same shape as `handoff-checkpoint`: self-locates, execs
`scripts/approved.sh`. No stdin, no arguments.

- Reads the session root pointer, refusing on its absence with the same message
  the checkpoint uses.
- Moves the sentinel from `held` to `armed`, through the same
  `handoff_drive_arm` the `Stop` hook uses.
- Exits 2 naming the state it found when the file is absent or not `held`.
- No git, no tmux (NFR1). It rewrites one file in the agent's own worktree.

A stale `held` file is inert: no gate fires on that state, only
`handoff-approved` leaves it, and the next checkpoint call overwrites the file
outright. So nothing sweeps it — it legitimately survives the turn boundary the
approval round trip costs, which is exactly what
`report-watcher-failure.sh`'s sweep rule keys on for `armed`.

### `handoff_drive_read` widens

`held` joins the accepted states, and the continuation line becomes optional on
both driven kinds:

```
rename   2 lines                     (unchanged)
compact  1, 2 or 3 lines             (was 1 or 3)
clear    3 or 4 lines                (was 4)
```

Line counts exclude the state line the previous pass added.

Each command literal stays pinned to its slot, and a prose line still may not
begin with `/`.

Neither loader changes. `load-handoff.sh` already guards its spawn on a
non-empty after-array, and `load-compact.sh`'s FR-G branch already handles an
empty one by injecting the frame and spawning nothing. Both paths gain test
coverage they did not have for a driven kind.

## Skills

`skills/handoff-continue/` and `skills/compact-continue/` are deleted.

`handoff/SKILL.md`:

- Step 1 decides the transition alongside commit awareness — whether the command
  is typed, and whether a continuation prompt follows — and carries the narrowed
  `with-commit` rule.
- Step 3's payload gains `clear` and `continue`.
- Step 4 (follow the directive) is unchanged; the directive may now name
  `handoff-approved`.
- Step 5 reports what the boundary is ready for, or that the transition is
  armed.
- The seam section stays where it is: it is what both boundaries read.
- The deleted skills' anti-patterns fold in, scoped to the driven modes.

`precompact/SKILL.md` takes the same treatment, and loses its step 4 — the
sentinel is the checkpoint's write now, not the skill's.

Both descriptions absorb their sibling's trigger phrases and drop the
cross-references that named it.

`autoname` is untouched: it writes a `rename` sentinel directly with the Write
tool, which is why `write-drive.sh` keeps its validation path.

## Tests

`tests/checkpoint.bats`:

- The field matrix: each new field missing, each with a value outside its type,
  `continue` non-null against an untyped transition, `compact:""`, a
  multi-line `continue`, a `continue` beginning with `/`. Each asserts a
  non-zero exit and that the message names the field.
- The six legal combinations, each asserting the sentinel's exact content —
  which pins the positive for both branches below.
- The held/armed branch as a pair over one fixture: with a memory gate pending
  the sentinel is written `held`, without one it is written `armed`. The rows
  above pin the rest of the file, so each of these asserts one line.
- The two non-typing kinds land `armed` even with a memory gate pending.
- `handoff-approved`: no file (exit 2, message names the absence), a file in
  `armed` (exit 2, message names the state), a file in `held` (becomes `armed`,
  every other line preserved), no root pointer (refused), and the invocation
  path — a `100644` shim never runs, and every other row would pass without it.
- `skill` accepting exactly two values, `rename` still forbidden under
  `precompact`.

`tests/hook-test.bats`:

- The widened `handoff_drive_read` shapes and their rejections: a 3-line
  `clear`, a 2-line `compact`, and the line counts that remain illegal.
- `load-handoff.sh` on `source: "clear"` with a continuation-less `clear`
  pending: frame injected, nothing spawned.
- `load-compact.sh` with a continuation-less `compact` pending: same.

## Docs

Written in the same pass, not as follow-up:

- `docs/changelog/2026-08-02-transitions-become-modes.md` plus its index line.
- `docs/design.md` — the skill roster, one-channel-one-writer, driving the TUI,
  and the commit-awareness decision.
- `CLAUDE.md` — the layout section's four skill entries become two, plus the
  checkpoint, `_lib.sh` and testing entries.
- `README.md` — the user-facing skill list.
- `skills/handoff/references/design.md`.

## Rejected alternatives

- **The skill keeps writing the sentinel.** Minimal diff, but the payload fields
  would then be advisory: the checkpoint could validate the combination and
  nothing more, and the line shapes would stay in prose in two skill bodies.
  Arming discipline would stay a rule the agent is asked to follow rather than
  one the code enforces.
- **The checkpoint prints the sentinel content for the agent to write when
  deferring.** No held file and no second command, at the cost of transcription
  through the model on the one path where correctness matters most.
- **A second full checkpoint call carrying the resolved gate.** Deadlocks: under
  `with-commit` the memory worktree is still dirty when the gate is resolved, so
  the second call re-emits the same directive and refuses to arm again.
- **`--arm` as a flag on `handoff-checkpoint`.** Overloads a command whose
  contract is "read a payload on stdin" with one that reads nothing.
