# One transition, one file, explicit state — design (2026-08-03)

There is exactly one transition in flight at a time, and its state is encoded in
the filename. Three names, three states, one object. This makes the state a
field.

No behaviour changes. It is preparation for
[transitions become modes](2026-08-02-transition-modes-design.md), which adds a
fourth state and would otherwise add a fourth filename.

## Problem

`.claude/autodrive`, `.claude/autodrive.pending` and — as that design first
proposed it — `.claude/autodrive.held` are not three files. They are one object
at three points in its life, and every consumer reads the point it cares about
by choosing a filename:

```
stop-drive.sh            gates on autodrive          (armed)
load-handoff.sh          gates on autodrive.pending  (in flight, kind clear)
load-compact.sh          gates on autodrive.pending  (in flight, kind compact)
report-watcher-failure   gates on autodrive          (armed, outlived its turn)
```

The transitions between those points are `mv` calls, so the machine exists but
is spelled out nowhere: no file names its own state, and reading the code means
reconstructing which `mv` in which hook produced which name. Adding a state
means adding a name and touching every gate.

## The machine

```
held  --handoff-approved-->  armed  --Stop-->  pending  --SessionStart-->  gone
```

`held` arrives with the modes design; this pass builds `armed` and `pending`
and leaves the parser ready for a third value.

One file, `.claude/autodrive`, in every state. Line 1 becomes the state, line 2
the kind, and the command and prose lines follow as they do today:

```
armed
clear
/rename Some Title
/clear
pick up the release per the task file
```

One fact per line, which is the file's existing idiom. The kind still fixes the
shape of everything below it, and every command literal stays pinned to its
slot.

### Transitions

| from → to | performed by | how |
|---|---|---|
| (none) → armed | `checkpoint.sh`, `autoname` | writes the file |
| armed → pending | `stop-drive.sh` | rewrites line 1, then spawns the before-lines |
| armed → gone | `stop-drive.sh` | for kind `rename`, which no loader would ever clear |
| pending → gone | `load-handoff.sh`, `load-compact.sh` | deletes, then spawns the after-lines |
| armed → gone | `report-watcher-failure.sh` | the sweep: armed at a `UserPromptSubmit` never armed |

Each gate becomes a state check where it is a filename choice today.
`stop-drive.sh` ignores anything not `armed`, so a file in flight cannot be
re-armed — the guarantee its consume-before-spawn ordering gives today, stated
directly. Each loader still consumes only its own kind, and now only in state
`pending`, so a `clear` overtaken by a threshold auto-compaction is still left
alone. The sweep still fires only on `armed`: a `pending` file is legitimate for
the whole `Stop` → `SessionStart` window.

### What does not change

**The walker.** It confirms a transition by waiting for `$HANDOFF_PENDING_FILE`
to *disappear*, and pending → gone is still a deletion — of `.claude/autodrive`
now rather than `.claude/autodrive.pending`. The spawning hook exports the path,
as it does today, so the walker still never learns the file's shape or which
command belongs to which kind.

**`.claude/autodrive.failed`.** It is not a state of the transition. It is a
report about one that is already gone, written by a detached process at a moment
when the live file may legitimately describe a different transition. Folding it
in puts a racing writer on the object. It stays its own file, drained at
`UserPromptSubmit`.

**The every-turn fast path.** `Stop` and `UserPromptSubmit` fire on every turn
and exit on the file's absence, which is unchanged. The file now exists during
the transition window in state `pending`, but that window is one turn boundary
wide and both hooks already parse when the file is present.

## Implementation

`_lib.sh`:

- `handoff_drive_read` sets `DRIVE_STATE` alongside `DRIVE_KIND`, and rejects a
  state outside `armed`/`pending` with the same one-phrase `DRIVE_ERR` shape as
  every other constraint. Callers gate on the value; the parser does not know
  which caller wants which state.
- `handoff_drive_arm <file> <state>` rewrites line 1 and replaces the file
  atomically — write a sibling temp file, then `mv`. Concurrent readers exist
  (the loaders and `Stop` parse; the walker stats), so a partial file must never
  be observable. Shared by `stop-drive.sh` and, in the next pass,
  `handoff-approved`.
- `HANDOFF_REL_DRIVE_PENDING` is deleted.

`checkpoint.sh` and `skills/autoname/SKILL.md` write the state line. `autoname`
keeps writing the file directly, so `write-drive.sh` keeps validating what the
agent authors.

`stop-drive.sh` replaces its `mv`-or-`rm` branch with an arm-or-delete branch on
the same `handoff_drive_has_source` predicate, and exports
`HANDOFF_PENDING_FILE` as the one path.

Both loaders gate on `DRIVE_STATE == pending` in addition to their kind.

`report-watcher-failure.sh` sweeps on `DRIVE_STATE == armed`. Its message keeps
saying what it says today — a transition that never armed — because that is
still what the state means at that moment.

No migration. A session mid-transition across the upgrade would see a file it
cannot parse and report it malformed, which is the correct outcome for a user
base of one.

## Tests

`tests/hook-test.bats` carries the shape matrix, so every row gains the state
line. The rows this pass adds are the state gates, each one paired with the
positive that already exists:

- `stop-drive.sh` arms an `armed` file and ignores a `pending` one.
- `load-handoff.sh` consumes a `pending` `clear` and ignores an `armed` one;
  same for `load-compact.sh` and `compact`.
- `report-watcher-failure.sh` sweeps an `armed` file and leaves a `pending` one.
- `handoff_drive_read` rejects an unknown state, naming it.
- The armed → pending rewrite preserves every line below the first.

`tests/watcher-test.bats` is unchanged: `submit_consumed` still waits on a path
it is handed.

## Docs

`docs/changelog/2026-08-03-one-transition-one-file.md` plus its index line;
`docs/design.md`'s driving-the-TUI section; `CLAUDE.md`'s entries for `_lib.sh`,
`stop-drive.sh`, both loaders and `report-watcher-failure.sh`.

## Rejected alternatives

- **State and kind on one line (`armed clear`).** Keeps today's line numbering,
  so the parser's slot errors need no renumbering. Rejected: the file is
  one-fact-per-line everywhere else, and the saving is in the diff rather than
  in the result.
- **Route `autoname` through the checkpoint, making it the sole writer.** Would
  let `write-drive.sh` collapse into a `write-guard.sh` deny, since no agent
  would ever author the file. It is a real simplification and a third change:
  it alters `autoname`'s contract — today a single `Write` and no Bash — and it
  belongs in its own pass if it is wanted.
- **Fold `.failed` in as a fourth state.** Puts a detached writer on a file a
  live session may have rewritten. See above.
- **Leave the filenames and add `.held`.** The state machine stays implicit and
  the next state added pays this question again.
