# Overflow deserves the same persistence (2026-07-23)

`handoff-todo.md` is force-added by `write-stage.sh` like the task file, and
its deletion staged by the wipe like the task file's. The one property that
distinguished the two files is gone.

The todo file exists because task lists were being crammed into
`handoff-task.md`. That split was hygiene — two shapes of content, two
templates, two sections of one frame — and persistence quietly followed the
file rather than the content. Overflow from a tracked artifact is still that
artifact's content.

Neither reason given for the exception survives being stated against the
flow. The pairing argument — the task file earns history by sitting next to
a gitlore memory commit — is about a *moment*: one skill invocation writes
both files and commits the memory. Both halves share the pairing or neither
does. The churn argument imported a cost from where it was measured: the
five-commit status line was expensive because gitlore's per-commit approval
gate charged for every move. In the main repo the todo file changes only
when a skill rewrites it, which is exactly when the task file changes, and
that churn was already priced and accepted ([Read-time
assembly](2026-06-05-read-time-assembly.md), "Wipe-churn").

The positive case is the trail's completeness. `## Current task` and
`## Remaining` are two sections of one snapshot; tracking one and discarding
the other puts half a frame in history — and the discarded half is the one
naming work not yet done, which is what a reader of the trail is looking for.
Nor is the file a mutating ledger in the sense that argued against versioning
it: it is rewritten whole at a boundary and holds the open set at that instant.
It is a snapshot with a different subject.

There is a durability point too, smaller but real. At `/clear` the remainder is
the only copy of the decomposition that crosses. Untracked, it is one
`git clean` — or one clone, one machine — from gone, with nothing to recover it
from.

Unchanged: the file still holds **open items only**. History records the list
narrowing; the file never carries completion state, which is the rule that
keeps a done item from re-injecting as outstanding.

Mechanically this is one call site each. `handoff_match_target` is already
variadic, so `write-stage.sh` covers both files in the one jq parse the
Write/Edit hot path allows; `_wipe-emit.sh` collects the removed tracked paths
and stages them in a single `git add -f`. Both stay listed in `.gitignore`, so
only the hook adds them and an incidental `git add .` still cannot.
