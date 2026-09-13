# Nothing is written until both halves resolve (2026-09-13)

`main()` applied the task half, then the todo half. The todo half can fail:
an `edit` against a file that is not there, an `old_string` that matches
nothing, an `old_string` that matches twice. Each of those is an `err()`
that exits 2 on the spot — and by then the task half had already run.

So a wrap-up whose todo half is malformed removed `handoff-task.md`, wrote no
manifest, staged nothing, and reported an error naming only
`todo.old_string`. The frame is gone; the message says the list could not be
edited. Nothing on either channel connects the two.

`task: {"action": "clear"}` beside a `todo` `{"action": "edit", …}` is not an
exotic payload. It is the ordinary boundary where the task finished — so the
frame is cleared — and the scratch list has leftovers to fold in. Every
`edit` failure mode is reachable there, and the one the schema cannot catch
is the likeliest: an `old_string` composed from what the agent remembers of a
file it edited earlier in the session.

## The change

Each half resolves to a `FilePlan` — the path, the act (`write`, `remove` or
nothing), the body when there is one, and the manifest lines that record it —
and every failure the wrap-up's own write path raises happens while
resolving. Only once both plans exist does anything touch the disk.

```
plan_task ─┐
           ├─ every err() lives here ──► apply both ──► write_manifest
plan_todo ─┘
```

`plan_task` and `plan_todo` replace `apply_task`/`apply_todo`; `apply_edit`
becomes `edited_body`, returning the replacement instead of writing it, which
is what lets its two `err()` sites run in the plan phase. `_plan_file` is the
shared resolver — it samples existence, applies FR6's emptiness rule, and is
the one place a plan naming an act is produced, so a plan cannot claim a `D`
it will not perform. `todo`'s `keep` short-circuits ahead of it to the empty
plan, which names no act and takes no stat: FR4's guarantee is that a call
silent about the list leaves it alone. `apply_plan` performs the write or the
unlink and has no failure branch; that is the point. `main()` builds both
plans, applies both, then hands `write_manifest` the concatenated lines.

Two things sit outside the guarantee, and it is stated with them in view
rather than written wider than it lands. An `OSError` from the filesystem
strands a half-applied wrap-up exactly as before, and nothing here reaches
it. And `compose_sentinel`'s read-back `err()` still fires after both halves
are applied — not a counterexample, since `write_manifest` has already run by
then, so the mutation is recorded and `bash-post.sh` stages it. The
guarantee's subject is the two halves and their manifest, not every `err()`
reachable from `main()`.

## Rejected

**Hoist the two `edit` checks ahead of the task half.** The smallest fix: run
the file-absent check and the occurrence count before `apply_task`, leave the
ordering itself alone. It removes today's triggers and nothing else — the
next apply-time failure anyone adds reopens the defect, silently, because
there is no structure saying where a failure may live, only a rule someone
had to remember. It also counts `old_string`'s occurrences in a second place,
which can drift from the place that acts on the count.

**Write the manifest for whatever was applied, then exit.** This records the
loss and stages it, rather than hiding it. The task file is git-tracked, so a
frame that reached a commit is recoverable from `HEAD` — but that recovery
is left to a user who has to notice the deletion first, and a frame written
by a wrap-up that never reached a commit is gone outright. A checkpoint that
reports the deletion it did not intend is not better than one that hides it.

## What falls out

`apply_todo` used to write the edited body, read it back, and unlink the file
when the read-back was empty — the file being the only place the computed
body existed. With the body in hand at plan time, the emptiness test reads a
value on both halves, and an empty body is never written first on either.
The end state on disk is identical, so this is a code shape rather than an
observable. What was missing was the coverage: the empty-body rows drove the
`write` route alone, and `edit`-to-empty — the route whose existence was the
whole reason the emptiness test read a file — had none. It has one now, so
the behaviour whose rationale this change deletes is pinned rather than
assumed.
