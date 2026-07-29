# A stale autocompact is one a later turn can see (2026-07-22)

`stop-compact.sh` checked only that `.claude/autocompact` existed. Its header
claimed the fail-safe direction for free: *"Stop does NOT fire on an Esc
interrupt, so an interrupted turn cannot arm the compaction."* True of the
interrupted turn, and silent about the file outliving it. The write is validated
by `PostToolUse` in the same turn, so the file is on disk the instant it is
written; if that turn then ends on an Esc, a crash, or a quit, nothing removes
it. The next turn that *does* end normally arms it — days later, in another
session, on unrelated work — driving a stale `/compact <old directive>` and a
stale continuation prompt into a conversation they were never written for. The
`mv` to `.pending` before spawning correctly blocks re-arming *within* a
session, which is likely what made the whole class feel handled.

The first shape considered was a session sidecar: stamp `session_id` at
validation time, refuse to arm on mismatch. It misses the most likely trigger.
Esc leaves the file in the *same* session, so the id matches and the next Stop
arms it anyway. Recency would patch that, but a timeout is a guess about how
long a turn may run, and a wrong guess silently drops a wanted compaction.

There is an exact discriminator, and it is structural. An autocompact is armed
at the `Stop` of the turn that writes it, and `Stop` renames it away. A turn
begins with a `UserPromptSubmit`. So a `UserPromptSubmit` that can *see* a bare
`autocompact` is by construction a turn later than the one that wrote it, and
that file never armed. No timestamp, no session id, no heuristic: the sweep
lives in `report-watcher-failure.sh`, which already owns compaction-state
reconciliation at prompt time, and reports on both channels like the watcher
failures it sits beside.

Two boundaries the sweep must respect. Prose injected into a still-running turn
fires `UserPromptSubmit` mid-turn, which could see a legitimately-written file;
that fails in the safe direction — the compaction is cancelled and said so,
rather than deferred into unrelated work. And the sweep must not touch
`.pending`: that file is legitimate for the whole `Stop` → compaction window,
and that window *contains* the watcher's own `/compact` submit, which is itself
a `UserPromptSubmit`. Clearing it on the evidence of a stale `autocompact` would
race `SessionStart(compact)` and kill a live continuation. Only a
watcher-observed failure clears `.pending`.

Adding `autocompact` to `_wipe-emit.sh`'s list was considered as a complement
and dropped. The wipe runs on skill re-activation, which the lingering-file
scenario does not involve, and a second mechanism covering a strict subset is
the vestigial half-measure the cleanup rule exists to prevent.
