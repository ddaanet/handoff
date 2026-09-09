# Outline — nothing is written until both halves resolve

Source: `plans/2026-09-04-checkpoint-null-no-task-file/reports/deliverable-review.md`
§C1 and §m3, with remedy (b) chosen by my human partner.
Classification: Moderate / Production — see `classification.md`.

## Scope

`main()` applies the task half, then the todo half. The todo half can fail —
an `edit` against a file that is not there, an `old_string` that matches
nothing or matches twice — and its `err()` exits 2 on the spot, before
`write_manifest`. The task half has already run.

So a wrap-up whose todo half is malformed removes `handoff-task.md`, writes no
manifest, stages nothing, and reports an error naming only `todo.old_string`.
`task: {"action": "clear"}` with `todo: {"action": "edit", …}` is not an exotic
payload — it is a boundary where the task finished and the list has leftovers.

The checkpoint applies a wrap-up whole or not at all. Each half resolves to a
**plan** — the path, what to do to it, and the manifest lines that record it —
and every failure the checkpoint raises itself happens while resolving. Only
once both plans exist does anything touch the disk. An `OSError` from the
filesystem is outside the guarantee: it strands a half-applied wrap-up exactly
as today, and nothing in this change reaches it.

```
plan_task ─┐
           ├─ every err() lives here ──► apply both ──► write_manifest
plan_todo ─┘
```

**IN:** `scripts/checkpoint.py` (the apply phase), `tests/test_checkpoint.py`,
`docs/changelog/` + its index, `docs/design.md`, `CLAUDE.md`.

**OUT:** the validators (`validate_task`/`validate_todo` and the union's
vocabulary — untouched, and their messages must not move), `bash-post.sh` and
the manifest format, the sentinel composer, `_checkpoint_lib.py`
(`is_empty_body` is called from a new place, not changed), both SKILL.md
bodies — a producer sending a valid payload cannot observe this change, and
the `edit` preconditions they now state were added earlier in this session.
The remaining pass-2 minors (m5, m7, m12, m14, and the cosmetic set) are not
in scope here.

## Decisions this outline applies

1. **Plan, then apply — not a hoisted precondition.** The report's remedy (a)
   moves `apply_todo`'s two `edit` checks ahead of `apply_task`, which removes
   today's two triggers and leaves the ordering itself unchanged: the next
   apply-time failure anyone adds reopens the defect, silently. It also counts
   `old_string`'s occurrences in a second place, which can drift from the
   place that acts on the count. Remedy (b) states the guarantee structurally,
   so there is no rule to remember when the code next grows.
2. **Remedy (c) is rejected outright.** Writing the manifest for whatever was
   applied before exiting records the loss and stages it. The task file is
   git-tracked, so a frame that reached a commit is recoverable from `HEAD` —
   but that recovery is left to a user who must notice the deletion first, and
   a frame written by a wrap-up that never reached a commit is gone outright.
   A checkpoint that reports the deletion it did not intend is not better than
   one that hides it.
3. **`apply_edit` becomes a body computation, and is renamed for it.** It
   returns the edited content instead of writing it, which is what lets its
   two `err()` sites run in the plan phase. The name goes with the behavior —
   no alias, and every in-repo citation by name moves in the same pass:
   `apply_edit`'s two docstrings (`checkpoint.py:364`,
   `test_checkpoint.py:538`), and `apply_todo`'s own, whose two references to
   `apply_task` describe behavior this change inverts.
4. **m3 falls out rather than being fixed beside it.** `apply_todo` currently
   writes the body, reads it back, and unlinks it when the read-back is empty.
   With the edited body in hand at plan time, the emptiness test reads a value
   rather than a file, and an empty body is never written. This is a code
   shape, not an observable: the final state on disk is identical either way,
   so it gets no test of its own. But the existing empty-body rows drive the
   `write` route alone, and `edit`-to-empty — which `apply_todo`'s docstring
   names as the whole reason the emptiness test reads the file — has no row.
   The slice adds it, so the behavior whose rationale this change deletes is
   pinned rather than assumed.
5. **`keep` still touches nothing, not even a stat.** FR4's guarantee is that
   a call silent about the list leaves it alone; the plan for `keep` is the
   empty plan, resolved without looking at the filesystem.

## Per-file changes

### `scripts/checkpoint.py`

- A `FilePlan` — the path, the act (`write` / `remove` / nothing), the body
  when there is one, and the manifest lines. Frozen, and its three shapes are
  produced in one place so a plan cannot claim a `D` it will not perform.
- `plan_task(root, action, content) -> FilePlan` and
  `plan_todo(root, action, content, old, new) -> FilePlan`, replacing
  `apply_task`/`apply_todo`. Each resolves its action to a body, then hands it
  to the shared resolver that applies FR6 — an empty body is a removal — and
  samples existence so `D` records only a removal that will actually happen.
  `todo`'s `keep` short-circuits ahead of that resolver, straight to the empty
  plan: it must not reach a rule that reads an absent body as a removal, and it
  takes no stat (D5).
- `apply_edit` → `edited_body(field, path, old, new) -> str`: same two `err()`
  sites, returns the replacement instead of writing it.
- `apply_plan(plan) -> None`: performs the write or the unlink. It has no
  failure branch; that is the point.
- `main()`: build both plans, then apply both, then `write_manifest` with the
  concatenated lines. `write_manifest` stays unconditional — the empty
  manifest is `bash-post.sh`'s presence gate (FR7).

### `tests/test_checkpoint.py`

Five rows, over one fixture that differs only in the trigger:

- a pre-existing task file plus `task: {"action": "clear"}` and a `todo` edit
  whose `old_string` matches nothing → exit 2 naming `todo.old_string`, the
  **task file still present with its original bytes**, the todo file
  unchanged, and no manifest;
- the same, with an `old_string` that matches twice → exit 2 naming
  `todo.old_string` and `ambiguous`, task file still present;
- the same, with the todo file absent → exit 2 naming `todo.old_string` and
  `does not exist`, task file still present;
- the positive over the same fixture — an `old_string` that matches — → exit
  0, task file removed, todo edited, manifest carrying `D` for the task and
  `W` for the todo;
- an `edit` whose replacement leaves the body empty under `is_empty_body` →
  exit 0, todo file removed, `D` for the todo in the manifest — the route
  `apply_todo`'s docstring names as the reason the emptiness test reads the
  file at all.

The first three are the red: today they fail on the surviving-task-file
assertion, not on a missing symbol. The fifth is green today — it
characterizes behavior the restructure must preserve, so it is mutation-checked
rather than observed passing. Manufacture no red by relocating the test —
mutate `checkpoint.py` in place and restore by inverting the edit.

### Docs

- `docs/changelog/<date>-nothing-is-written-until-both-halves-resolve.md`,
  dated the day the change lands rather than the day this outline was written —
  the defect, the three remedies weighed, and why the structural one won. No
  `> **Superseded**` header on the 2026-09-07 entry: that entry's decisions all
  stand, and this is the ordering they were applied within.
- `docs/changelog.md` — its index line, newest first.
- `docs/design.md` §One channel, one writer — one sentence stating the
  guarantee positively, and the `apply_task`/`apply_todo` citation in that
  section's `file_path` paragraph (`:240`) rewired to the plan/apply names.
  Present tense, no account of what the code used to do.
- `CLAUDE.md`'s `checkpoint.py` bullet — it claims existence is sampled before
  any write (`:543`), which has to become true of the plan phase rather than of
  the apply. It names no functions, so nothing else in it moves.

## Dependencies and order

Code and tests are one TDD slice (red on the three negatives, then the
restructure). Docs follow the code, in the same commit — the changelog entry
states what landed, and this repo's convention puts the entry, its index line
and the invalidated design prose in the same pass rather than as follow-up.

## Verification

- `just precommit` green: jq manifests, `shellcheck -x`, ruff/docformatter/
  mypy/ty, `bats tests/*.bats`, `pytest`.
- The three negatives red before the restructure, on their surviving-task-file
  assertion — recorded, not asserted after the fact.
- Mutation check on the ordering: move `apply_plan(task_plan)` back above
  `plan_todo` and confirm the three negatives red again and nothing else does.
- Mutation check on the empty-body route: drop the emptiness test from the
  shared resolver and confirm the `edit`-to-empty row reds alone.
- After each mutation, restore by inverting the exact edit, then prove the
  restore — grep for the mutated text and re-run the suite to green before
  continuing.
