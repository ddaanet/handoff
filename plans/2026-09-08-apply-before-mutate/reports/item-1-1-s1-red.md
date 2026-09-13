# Item 1.1, slice 1 — RED

Scope: `tests/test_checkpoint.py` only. `scripts/checkpoint.py` untouched (see
"SUT unchanged" below).

## What changed

Four existing rows extended in place (renamed to state the second claim they
now make), one new row added — all in `tests/test_checkpoint.py`, adjacent to
each other (the block that used to sit at the old
`test_todo_edit_replaces_first_occurrence_stages_w` location):

- `test_todo_edit_replaces_first_occurrence_stages_w` →
  `test_todo_edit_and_task_clear_both_apply_manifest_records_d_and_w` — now
  writes a pre-existing `.claude/handoff-task.md` fixture before the call and
  asserts it is gone afterward, plus the manifest's lines being exactly
  `["D .claude/handoff-task.md", "W .claude/handoff-todo.md"]`.
- `test_todo_edit_old_string_absent_errors` →
  `test_todo_edit_old_string_absent_errors_task_file_survives` — adds the
  task-file fixture and asserts it survives with its original bytes, plus no
  `checkpoint-manifest`.
- `test_todo_edit_old_string_ambiguous_errors` →
  `test_todo_edit_old_string_ambiguous_errors_task_file_survives` — adds the
  task-file fixture, asserts the todo file is unchanged (new assertion — the
  original test didn't check this), the task file survives, and no manifest.
- `test_todo_edit_requested_file_missing_errors` →
  `test_todo_edit_requested_file_missing_errors_task_file_survives` — adds the
  task-file fixture, asserts it survives, and no manifest.
- `test_todo_edit_emptying_the_list_removes_it_manifest_records_d` — new. Same
  task-file fixture; an edit whose replacement leaves the todo body as
  `## Remaining\n\n` (empty under `is_empty_body`). Asserts exit 0, the todo
  file gone, and `D .claude/handoff-todo.md` present in the manifest
  (membership, since the manifest also carries the task's `D`).

None of the renamed/new names are cited elsewhere in the repo outside this
file (matches the outline's grep-verified claim).

## SUT unchanged

```
$ git diff --stat scripts/checkpoint.py
```
produced no output — empty diffstat, confirming byte-for-byte unchanged.

## Red evidence (the three negatives)

Ran `pytest tests/test_checkpoint.py -k "todo_edit" -v`. Each negative was
first confirmed to reach its surviving-task-file assertion (every assertion
ahead of it in the test body — including "todo file bytes unchanged" and the
stderr checks — passed), then failed there with a `FileNotFoundError` raised
by `Path.read_text()` because `apply_task` had already deleted the file
before `apply_todo` raised. This is the red the slice wants: not a missing
fixture (the file was written, then deleted by the SUT), and not the
no-manifest assertion (that one is never reached in either version).

### `test_todo_edit_old_string_absent_errors_task_file_survives`

Failing line: `assert (repo / ".claude" / "handoff-task.md").read_text() == task_before`

```
E       FileNotFoundError: [Errno 2] No such file or directory: '.../repo/.claude/handoff-task.md'
```

(Preceding assertions in the same test — returncode == 2, "old_string" and
"not found" in stderr, "keep this" in the todo file — all passed.)

### `test_todo_edit_old_string_ambiguous_errors_task_file_survives`

Failing line: `assert (repo / ".claude" / "handoff-task.md").read_text() == task_before`

```
E       FileNotFoundError: [Errno 2] No such file or directory: '.../repo/.claude/handoff-task.md'
```

(Preceding assertions — returncode == 2, "old_string"/"ambiguous" in stderr,
todo file unchanged — all passed.)

### `test_todo_edit_requested_file_missing_errors_task_file_survives`

Failing line: `assert (repo / ".claude" / "handoff-task.md").read_text() == task_before`

```
E       FileNotFoundError: [Errno 2] No such file or directory: '.../repo/.claude/handoff-task.md'
```

(Preceding assertions — returncode == 2, "todo.old_string"/"does not exist"
in stderr — all passed.)

## Characterisation rows (green, as expected)

`test_todo_edit_and_task_clear_both_apply_manifest_records_d_and_w` and
`test_todo_edit_emptying_the_list_removes_it_manifest_records_d` both pass
against unchanged `checkpoint.py` — they characterize behavior the restructure
must preserve and earn their evidence by mutation once the implementation
lands, not by failing now.

## Full suite

```
$ pytest tests/test_checkpoint.py -q
...
3 failed, 136 passed in 22.97s
```

Only the three intended negatives fail; nothing else in the file regressed.

## Git state

```
$ git status --porcelain
 M tests/test_checkpoint.py
```

Only the test file is modified. No commit made.

## Superseded evidence — 2026-09-13

The red output recorded above is what the run produced at the time and is left
as written. The three negatives were since restructured — an explicit
`assert task_path.is_file()` ahead of the bytes comparison — so their red is
now a failed assertion naming the surviving-task-file claim rather than a
`FileNotFoundError` raised by `read_text()`. The current output, the ruling
behind the change, and three further fixes are in
`plans/2026-09-08-apply-before-mutate/reports/item-1-1-s1-test-review.md`.

One sentence above is wrong looking forward: "not the no-manifest assertion
(that one is never reached in either version)" holds only of the pre-GREEN
code. Once the plan/apply split lands, the negatives run to completion and that
assertion is reached.
