# The ledger and the todo file are different scopes (2026-08-08)

A live workflow-owned ledger stood `handoff-todo.md` down completely. The
handoff directive said so outright — *"that file is the ledger:
`.claude/handoff-todo.md` must not exist alongside it — delete it if you have
already written it"* — and the precompact nudge folded the same prohibition
into its last line.

That is one word too broad, and the word is *ledger*. Both files were called
one, so a sentence saying "that file is the ledger" made them the same object.
They are not:

- A superpowers SDD ledger holds the tasks **of one plan being executed**, and
  dies with it — SDD deletes the workspace when the plan's final whole-branch
  review comes back clean.
- `handoff-todo.md` holds work outstanding **across sessions**, most of it
  belonging to no plan at all. This repo's own copy carries fifteen items,
  most of them for other repositories; not one of them would ever appear in an
  SDD ledger, and no plan's completion retires them.

So a session that starts executing a plan loses every one of them, and it
loses them in the direction that cannot be recovered: `handoff-todo.md` is the
half of the frame a `/clear` discards outright, and after a compaction the
context it would be re-authored from is a paraphrase.

The hazard the old rule was built on is real, but it is only the **overlap**.
Copying the plan's own task list into the todo file leaves two records of one
thing, and the stale one gets believed. Excluding the overlap costs nothing;
excluding the file costs everything the ledger will never carry.

The directives now state a scope boundary. The plan's tasks live in the
ledger; `handoff-todo.md` holds only work outstanding outside the plan. Each
still names one act, per [Commit
awareness](2026-07-25-commit-awareness.md)'s rule that a directive states acts
and not mechanism, and the two differ where they always did — precompact reads
its directive *before* the writes it drives, so "keep them out" lands in time,
while handoff's arrives in the same turn as them and has to name the removal
as well.

`checkpoint_todo_suppression` becomes `checkpoint_todo_boundary`. The old name
asserted the retired policy, and a name that argues for the wrong rule
survives every rewrite of the text under it.

## What still stands

Liveness detection, unchanged and for a sharper reason. A stray file at SDD's
pre-6.2.0 flat path used to suppress the todo file in a session running no SDD
at all; it would now tell that session to move "the plan's tasks" into a
ledger describing somebody else's plan. The failure is smaller and the
detection is the same.

[An orphaned ledger hijacks the handoff](2026-07-26-orphaned-ledger.md)
rejected *"dropping the suppression altogether"* on the grounds that the
two-ledgers-drift rationale was sound and the defect was in the detection
rather than the policy. Half of that holds: the rationale is sound, and it
justifies excluding the plan's tasks from the todo file — not the file. The
alternative that entry weighed was all-or-nothing, and the scoped middle was
never on the table.
