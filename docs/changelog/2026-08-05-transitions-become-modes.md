# Transitions become modes of the two boundary skills (2026-08-05)

`handoff-continue` and `compact-continue` are deleted. What they added over
their siblings — the transition command and the continuation prompt — becomes
two payload fields, decided by the base skill the same way `commit` already
was. `skill` collapses to `"handoff"` and `"precompact"`, the checkpoint
composes the sentinel itself, and a `held` state plus `bin/handoff-approved`
carry the case where a memory approval must be answered before anything is
typed.

## The defect

Four skills, two boundaries. The pair at each boundary differed only in
whether the transition was typed, and that difference cost:

- **Routing.** Six trigger phrases per description, each one naming the
  sibling it is not. "compact and continue" reaching `precompact` produces a
  prepared compaction nobody runs; "prepare compact" reaching
  `compact-continue` compacts a session the user meant to keep.
- **Duplication.** The arming discipline, the seam rules and the
  anti-patterns were stated twice, once per driven skill, and the sentinel's
  line shape was stated in prose in both.
- **Expressiveness.** The cross product was not covered. There was no way to
  drive a transition without a continuation prompt, because the driven skills
  treated the prompt as intrinsic.

The base skills already carried a mode field. `commit` was added when the
same shape appeared for memory routing: one fact the agent supplies,
everything downstream deterministic. The transition is that shape again.

## The contract

`rename` stays required under `handoff` and forbidden under `precompact`,
which is what still makes a `handoff` call that forgot its title an error
rather than a silent non-rename. Two new fields join it, both **required**
with no default — a default is the answer given by an agent that never
considered the question, and considering it is the whole contribution:

| | `handoff` | `precompact` |
|---|---|---|
| transition | `clear`: `true` \| `false` | `compact`: `false` \| `true` \| `"<directive>"` |
| continuation | `continue`: `null` \| one line of prose | `continue`: `null` \| one line of prose |

The transition field is named after the command it types, and its value is
that command's argument. `false` does not mean "no sentinel" — it means the
command is not typed:

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
rather than a silent drop. The checkpoint validates `continue` itself — a
single non-blank line with no leading `/` — and the `compact` directive
string for the first two, because it writes the sentinel directly and
`write-drive.sh` never sees the result.

`compact-continue` asserted "continuation is intrinsic: compact ⟹ continue",
reasoning that nobody compacts before stopping. That was a fact about the
skill's contract, not about the transition — a prepared compaction followed
by a stop was always reachable by typing `/compact` by hand. `compact:true
continue:null` makes it expressible, and the claim goes.

## Commit awareness narrows

`with-commit` becomes: **the ask this checkpoint serves implies a commit.**

The rule it replaces counted a commit landing in a later session, because
the question was framed as where the memory belongs rather than whether
anything present decides it. That is unanswerable in the prepare-only modes.
Asked whether some commit will eventually carry the change, the agent has no
evidence in front of it and guesses — a coin flip on a field the schema
requires an answer to. Asked whether the request in front of it implies a
commit, it has the request.

Under a driven transition the two readings coincide: anything the ask implies
happens before the command is typed. The prepare-only modes are where the old
rule sent the agent looking past the end of the request.

The test is interpretation, not a keyword. "handoff and amend" and "handoff
and ci" both imply a commit and contain neither the word nor a substring of
it, so this stays a judgement the skill body asks for rather than a match the
checkpoint could make.

The hazard the old rule walked into is what makes the "even in a later
session" clause the part that has to go. Withholding gitlore's trigger file
defers the memory commit to a parent commit's pre-commit hook; if that commit
is on the far side of a `/clear`, no live session owes it, the approved
summary goes unread, and any memory write in the new session stales the
summary and aborts the commit that would have collected it. A commit named in
the continuation prompt is on that far side, so it is not evidence of
`with-commit`. This also unifies with the ordering rule the driven skills
carried — the commit lands before the sentinel is armed — which is the same
constraint stated from the other side.

The ask stops at the transition under both kinds. A compaction keeps the
session, so a commit named in its continuation prompt would in fact have a
live pre-commit hook to collect the memory — but the rule does not split on
that. One sentence that holds for every mode is worth more than one correctly
deferred memory commit, and if the compact case turns out to be a practical
limitation it can be carved out then, against evidence.

This supersedes the corresponding paragraph of
[Commit awareness](2026-07-25-commit-awareness.md).

## Mechanics

### The checkpoint composes the sentinel

It has the kind (from `skill`), the title, the transition and the
continuation, so it builds the whole file — and then reads its own output
back through `handoff_drive_read` before returning, so the composer and the
parser cannot drift. Every other reader of that file runs in a later turn,
inside a hook, where a rejection is a silent no-op.

No skill body restates the line shapes. Both "exactly N lines" blocks
disappeared with the skills that held them.

### Held versus armed

`held` is the state the previous pass left room for. The sentinel is written
in it iff it **types a transition** and a memory directive was emitted:

```
types nothing (rename kind, bare compact marker)  -> armed   always
types a transition, no memory gate                -> armed   fires at this turn's Stop
types a transition, memory gate emitted           -> held    + arming instruction
```

The condition names the hazard rather than its trigger. The hazard is
keystrokes reaching a pane whose turn is about to end on an approval
question: a sentinel armed alongside that question clears or compacts away
the very conversation the answer applies to. A sentinel that types nothing
has no such hazard, so the two non-typing kinds keep the old behaviour
exactly — and a prepare-only precompact cannot lose its expectation marker by
forgetting a second call.

Only the memory gate defers. The SDD ledger nudge and the todo suppression
are acts, not questions; `Stop` comes after them either way.

The arming instruction is composed onto the memory directive, since that is
the only thing that ever holds a sentinel back.

### `handoff-approved`

A single executable at `bin/handoff-approved` — the whole script, not a shim.
No stdin, no arguments.

`handoff-checkpoint` is a shim over `scripts/checkpoint.sh` because that
script is 300 lines that source two helpers and are driven directly by bats;
`bin/` holds the PATH-visible name and nothing else. Neither reason reaches
here. This script is short enough to read whole, its only caller would be its
own shim, and `bin/*` is already inside the `shellcheck -x` line, so sourcing
`../scripts/_lib.sh` from here lints exactly as it does from `scripts/`. It
self-locates from `$0` the same way the shim does. What it still needs from
outside is the *project* root, and that arrives through the same session
pointer the checkpoint reads.

It moves the sentinel from `held` to `armed` through the same
`handoff_drive_arm` the `Stop` hook uses, exits 2 naming the state it found
when the file is absent or not `held`, and does no git and no tmux (NFR1) —
it rewrites one file in the agent's own worktree.

A stale `held` file is inert: no gate fires on that state, only
`handoff-approved` leaves it, and the next checkpoint call overwrites the
file outright. So nothing sweeps it — it legitimately survives the turn
boundary the approval round trip costs, which is why
`report-watcher-failure.sh`'s sweep now names the states it takes instead of
taking anything that is not `pending`.

### `handoff_drive_read` widens

`held` joins the accepted states, and the continuation line becomes optional
on both driven kinds:

```
rename   2 lines                     (unchanged)
compact  1, 2 or 3 lines             (was 1 or 3)
clear    3 or 4 lines                (was 4)
```

Line counts exclude the state line. Each command literal stays pinned to its
slot, and a prose line still may not begin with `/`.

Neither loader changed. `load-handoff.sh` already guarded its spawn on a
non-empty after-array, and `load-compact.sh`'s prepare-only branch already
handled an empty one by injecting the frame and spawning nothing. Both paths
gained the test coverage they did not have for a driven kind.

### The context-size nudge follows the rename

`context-threshold.sh` named `/handoff:compact-continue`, which no longer
exists. It names `/handoff:precompact` and asks for the compaction to be
carried out — the skill reads the transition decision off the ask, so naming
the skill alone would have turned every threshold crossing into a prepared
compaction nobody runs, which is the routing defect above, reintroduced by
the one caller that is not a person.

## Rejected alternatives

- **The skill keeps writing the sentinel.** Minimal diff, but the payload
  fields would then be advisory: the checkpoint could validate the
  combination and nothing more, and the line shapes would stay in prose in
  two skill bodies. Arming discipline would stay a rule the agent is asked to
  follow rather than one the code enforces.
- **The checkpoint prints the sentinel content for the agent to write when
  deferring.** No held file and no second command, at the cost of
  transcription through the model on the one path where correctness matters
  most.
- **A second full checkpoint call carrying the resolved gate.** Deadlocks:
  under `with-commit` the memory worktree is still dirty when the gate is
  resolved, so the second call re-emits the same directive and refuses to arm
  again.
- **`--arm` as a flag on `handoff-checkpoint`.** Overloads a command whose
  contract is "read a payload on stdin" with one that reads nothing.
- **Routing `autoname` through the checkpoint too**, making it the sole
  writer of the sentinel and collapsing `write-drive.sh` into a
  `write-guard.sh` deny. A deliberate third pass, not a refusal: `autoname`
  makes no checkpoint call at all today, and giving it one means deciding
  what a rename-only payload looks like.
