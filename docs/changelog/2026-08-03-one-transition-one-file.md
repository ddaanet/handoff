# One transition, one file, explicit state (2026-08-03)

There is exactly one transition in flight at a time, and its state was encoded
in the filename. `.claude/autodrive` and `.claude/autodrive.pending` are not
two files — they are one object at two points in its life, and every consumer
read the point it cared about by choosing a name:

```
stop-drive.sh            gates on autodrive          (armed)
load-handoff.sh          gates on autodrive.pending  (in flight, kind clear)
load-compact.sh          gates on autodrive.pending  (in flight, kind compact)
report-watcher-failure   gates on autodrive          (armed, outlived its turn)
```

The transitions between those points were `mv` calls, so the machine existed
but was spelled out nowhere: no file named its own state, and reading the code
meant reconstructing which `mv` in which hook produced which name. Adding a
state meant adding a name and touching every gate — which is what
[transitions become modes](../../plans/2026-08-02-transition-modes-design.md)
was about to do, with a `.held` that a user's approval promotes to `.armed`.
Three names for one object was the moment to stop.

## The machine

```
held  --handoff-approved-->  armed  --Stop-->  pending  --SessionStart-->  gone
```

`held` arrives with the modes design; this pass builds `armed` and `pending`
and leaves the parser ready for a third value. One file, `.claude/autodrive`,
in every state. Line 1 is the state, line 2 the kind, and the command and prose
lines follow as they did:

```
armed
clear
/rename Some Title
/clear
pick up the release per the task file
```

**Line 1 rather than a suffix on the kind line.** `armed clear` on one line
would have kept today's line numbering, so the parser's slot errors would need
no renumbering and the diff would be smaller. Rejected: the file is
one-fact-per-line everywhere else — the kind, each keystroke, the prose — and
the saving is in the diff rather than in the result. The kind still fixes the
shape of everything below it, and every command literal stays pinned to its
slot, so a sentinel still cannot be made to type something it does not name.

Each gate becomes a state check where it was a filename choice.
`stop-drive.sh` ignores anything not `armed`, which states directly the
guarantee its consume-before-spawn ordering gave implicitly: a transition in
flight cannot be re-armed, and that window is real — the walker submits each of
its lines as an ordinary prompt, and each one ends a turn. Each loader still
consumes only its own kind, and now only in state `pending`, so a `clear`
overtaken by a threshold auto-compaction is still left alone. The sweep fires
only on `armed`: a `pending` file is legitimate for the whole `Stop` →
`SessionStart` window.

`handoff_drive_arm <file> <state>` rewrites line 1 and replaces the file
atomically — a sibling temp, then `mv`. Concurrent readers exist (both loaders
and `Stop` parse; the walker stats), so a partial file must never be observable
under the real name. It preserves everything below line 1 without knowing the
kind's shape, which is what lets one helper serve `Stop` and, next pass,
`handoff-approved`.

## What does not change

**The walker.** It confirms a transition by waiting for
`$HANDOFF_PENDING_FILE` to *disappear*, and pending → gone is still a deletion
— of `.claude/autodrive` now rather than `.claude/autodrive.pending`. The
spawning hook exports the path, as before, so the walker still never learns the
file's shape or which command belongs to which kind. Its environment variable
keeps its name: it is a contract with an unchanged process.

**`.claude/autodrive.failed`.** It is not a state of the transition. It is a
report about one that is already gone, written by a detached process at a
moment when the live file may legitimately describe a different transition.
Folding it in as a fourth state puts a racing writer on the object. It stays
its own file, drained at `UserPromptSubmit`.

**The every-turn fast path.** `Stop` and `UserPromptSubmit` fire on every turn
and exit on the file's absence, which is unchanged. The file now exists during
the transition window in state `pending`, but that window is one turn boundary
wide and both hooks already parsed when the file was present.

## What does change, beyond the collapse

**The agent's channel is arm-only.** Before, a wrong state was unrepresentable:
the agent wrote a filename and `write-drive.sh` matched exactly one. Collapsing
the family turns that into a content error, and an agent-written `pending`
would be silently inert — `stop-drive.sh` ignores it, no loader consumes a kind
it does not own, the sweep exempts `pending` — so it would survive every gate
until something overwrote it. `write-drive.sh` holds the channel it validates
to `armed` and says why: every state after that is a hook's to write. The
parser itself stays permissive, because which state a caller wants is the
caller's business, and it serves the `Stop` gate, both loaders and the sweep
with one answer.

**A malformed file that reached `pending` is now swept.** The sweep parses the
file, so a sentinel that will not parse needs an explicit disposition; it is
discarded, which is what the bare-filename gate did. Previously only a loader
removed a malformed `.pending` and the sweep never touched it. It is
unreachable in practice — `stop-drive.sh` discards a malformed file before it
can reach `pending` — but the "never sweep a file in flight" invariant now has
this exception, and the sweep's agent-facing note says both things it can mean.

**No migration.** A session mid-transition across the upgrade sees a file it
cannot parse and reports it malformed, which is the correct outcome for a user
base of one. A `.claude/autodrive.pending` left on disk from before is
referenced by nothing and swept by nothing; a pre-upgrade walker still waiting
on that path times out into a spurious non-delivery report. Neither is worth a
back-compat branch.

## Rejected alternatives

- **Route `autoname` through `handoff-checkpoint`, making the checkpoint the
  sole writer of the sentinel.** `write-drive.sh` would collapse into a
  `write-guard.sh` deny, since no agent would ever author the file — and the
  arm-only rule above would have nowhere it needed to live. It is a real
  simplification, and a third change: it alters `autoname`'s contract, today a
  single `Write` and no Bash. Deferred to its own pass, not refused.
- **Fold `.failed` in as a fourth state.** Puts a detached writer on a file a
  live session may have rewritten. See above.
- **Leave the filenames and add `.held`.** The state machine stays implicit and
  the next state added pays this question again.
