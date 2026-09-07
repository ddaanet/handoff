# The payload names its actions (2026-09-07)

On 2026-09-02, under handoff 0.13.1, a session finished publishing a release
and wrote its wrap-up. The task frame the next session loaded still said the
release was unpublished. Nothing had failed: the checkpoint exited 0, the
manifest was written, the hook staged what the manifest named. The agent had
sent `"task": null`, meaning "there is nothing more to say about the task",
and the checkpoint read that as "do not touch the task file" — so the stale
frame from an earlier boundary survived, and was injected as current.

Both readings are defensible, which is the defect. `null` is the JSON value an
agent reaches for when a field has nothing in it, and the two skill bodies
said so in as many words: *`task` and `todo` are each the file's content, or
`null` when there is nothing to say for that file*. For `todo` — a scratch
list the agent edits all session, where a call that says nothing about the
list must not wipe it (FR4) — leaving it alone is right. For `task` it is
the opposite of right, because a task frame is authored whole at every
boundary: nothing to say means the frame is finished, and a finished frame
should be removed, not preserved. One spelling, two fields, opposite correct
meanings, and no way for the schema to tell which the agent meant.

`null` was made a no-op deliberately, three months earlier
([`{"content": null}` is a no-op](2026-07-27-content-null-is-a-no-op.md)),
and for a good reason at the time: key-presence validation was treating an
explicit `null` as supplied content, so the literal four-character string
`null` was being written into the task file. That fix was right about the
symptom and wrong about the remedy — it gave `null` a meaning instead of
taking it away, and the meaning it gave was the one that is correct for one
field and silently wrong for the other.

## The change

`task` and `todo` become a tagged union. Each carries the file's content
directly as a string, or an object naming an action:

- `task`: `"<content>"` or `{"action": "clear"}`.
- `todo`: `"<content>"`, `{"action": "clear"}`, `{"action": "keep"}`, or
  `{"action": "edit", "old_string": …, "new_string": …}`.

The asymmetry is now in the vocabulary rather than in a shared spelling's
two meanings. `todo` has `keep` because FR4 requires it. `task` has no
`keep` because there is no boundary at which preserving an old frame is
right, and no `edit` because the frame is authored whole.

Both keys are required by **key presence**, with no default. `null` and an
absent key are each a named schema error on both fields. That is the whole
point: the defect was an agent choosing a spelling that quietly did the
wrong thing, so a wrong spelling has to fail loudly rather than acquire a
meaning. This costs a gate in `main` — `validate_*`/`apply_*` are now wrapped
in `if skill in ("handoff", "precompact")`, since `autoname` and `restart`
carry neither field and would otherwise exit 2 naming `task`.

`file_path` goes with it. `apply_task`/`apply_todo` already composed the real
path from `HANDOFF_ROOT`; the field was validated against a constant and then
discarded, so it asked the agent to derive a path from a root it cannot read
in order to have it checked against the one the code would have used anyway.

Removal becomes unlink-if-present on both routes — the explicit `clear` and a
body empty under `is_empty_body` — with existence sampled before any write, so
a `D` manifest line records only a removal that actually happened. The old
code wrote an empty body, unlinked it, and emitted `D` unconditionally; that
phantom `D` was one of two routes to `bash-post.sh`'s `git add` failing with
`did not match any files` on a path that was never in the index.

## Rejected

**Error on `null`, keep everything else.** The minimal schema change: leave
the Write/Edit form shape alone and make `null` a validation error. It fixes
the reported incident and leaves the field's two spellings for "absent"
(`null`, key omitted) still meaning different things, and leaves `file_path`
still asking for a path only to check it against a constant. The union is
more change than the incident strictly demands, and is what makes the next
ambiguity of this class unrepresentable rather than merely caught.

**Document the `""` workaround.** An empty-string content already removes the
file, via `is_empty_body`. So the skill bodies could simply have said: to
clear the task file, send `""`. This is the cheapest fix and the worst one —
it leaves the trap in place and adds a rule the agent must remember at exactly
the moment it is under context pressure, which is when wrap-up runs. A
contract that depends on remembering a convention is the thing being replaced.

**Make `null` delete.** This was this change's own approach until 2026-09-07,
and it is the one a future reader will re-propose, because it is the smallest
diff that fixes the incident: keep `null`, flip its meaning for `task` from
no-op to remove. It fails on `todo`, where `null` must stay a no-op (FR4), so
it delivers a payload in which one spelling means "remove" on one field and
"leave alone" on the other — the original defect with its polarity changed,
and now with a precedent making it look intentional.

**Bare magic-string sentinels.** `"@empty"`, or `"clear"`, as the value of
`task` rather than `{"action": "clear"}`. This was the first shape considered
at the proof pass. It reinstates the defect class one spelling along: a typo
in a bare token is indistinguishable from content and is written as content,
so `"claer"` becomes the task frame's body, silently — exactly the failure
mode `null` had. `{"action": "emty"}` is a schema error naming the field,
because the object shape is what makes the value's role explicit enough to
check.

**Keep `file_path` as a cross-project guard.** It did do something: the
schema rejected a `file_path` outside `$root/.claude/`, which would catch a
payload composed against the wrong repo. But the guard was checking the
agent's copy of a value the code never used — `HANDOFF_ROOT` is injected by
`inject-checkpoint-root.sh` and is what the write actually resolves against,
so a drifted session was already writing to the right place and the guard
could only ever reject a correct write. The real coverage lives in
`test_drifted_cwd_writes_injected_root_never_cwd`, which asserts that a
drifted cwd gets nothing written into its own `.claude/`.

## What this reverses

[`{"content": null}` is a no-op, not "content supplied"](2026-07-27-content-null-is-a-no-op.md)
— the entry that gave `null` its no-op meaning. Its diagnosis stands: an
explicit `null` was being written into the file as the literal string `null`,
and that had to stop. What does not stand is the remedy of assigning `null` a
meaning, which is what put a single spelling in front of two fields whose
correct behaviours are opposite.
