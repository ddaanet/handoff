# Item 1.1 slice 1 report — RED

## Scope touched

`tests/test_checkpoint.py`, `pyproject.toml` only. `scripts/checkpoint.py`
untouched (`git diff --stat` confirms only the two in-scope files changed).

## What changed

- Flipped the five factory bodies (`task_content`, `task_clear`,
  `todo_content`, `todo_keep`, `todo_edit`) to the new tagged-union shapes and
  dropped the `repo` parameter from all five signatures; updated all 15
  `*_content`/`todo_edit` call sites (11 `*_content`, 4 `todo_edit`) to drop
  the now-gone first argument.
- Deleted the `[[tool.mypy.overrides]]` block in `pyproject.toml` (the
  `func-returns-value` override Item 0.1 added — dead now that the factories
  return dicts/strings instead of `None`).
- Deleted the eight rows named in the item: the whole `{"content": null}
  no-ops` section (4 tests + its header), `test_task_file_path_outside_claude_errors`,
  `test_todo_file_path_outside_claude_errors`,
  `test_todo_content_and_old_string_together_errors`,
  `test_drifted_cwd_task_path_under_cwd_rejected`.
  `test_task_with_old_string_new_string_errors`, `test_todo_only_old_string_errors`
  and `test_todo_only_new_string_errors` were left exactly as they were (still
  literal dicts) per the item's instruction.
- Amended `test_task_write_creates_file_manifest_records_w` and
  `test_todo_write_creates_file_manifest_records_w` to assert exact content
  equality instead of substring containment.
- Added `test_task_clear_removes_pre_existing_file_manifest_records_d` and
  `test_task_clear_never_existed_writes_nothing_no_d` as a pair over one
  fixture (pre-existing vs. never-existed) exercising `{"action": "clear"}`.
- Renamed `test_todo_null_untouched_list_left_alone` to
  `test_todo_keep_leaves_pre_existing_list_alone` (body unchanged; it already
  called `todo_keep()`, which now emits `{"action": "keep"}`).

## Collected count

`pytest tests/test_checkpoint.py --collect-only -q` → **107 tests collected**
(113 before this slice, minus the 8 deleted rows, plus the 2 new clear-pair
rows = 107, as expected).

## The five slice tests — each fails on its own assertion

All five fail at `assert result.returncode == 0`, against the unchanged
validator's `must be an object or null` / `task.file_path: required`
rejections — genuine assertion-level reds, not errors or missing symbols.

1. `test_task_write_creates_file_manifest_records_w` — `tests/test_checkpoint.py:512`:
   ```
   assert result.returncode == 0
   AssertionError: assert 2 == 0
   stderr: 'handoff-checkpoint: task: must be an object or null\n'
   ```
2. `test_task_clear_removes_pre_existing_file_manifest_records_d` — `tests/test_checkpoint.py:538`:
   ```
   assert result.returncode == 0
   AssertionError: assert 2 == 0
   stderr: 'handoff-checkpoint: task.file_path: required\n'
   ```
3. `test_task_clear_never_existed_writes_nothing_no_d` — `tests/test_checkpoint.py:558`:
   ```
   assert result.returncode == 0
   AssertionError: assert 2 == 0
   stderr: 'handoff-checkpoint: task.file_path: required\n'
   ```
4. `test_todo_write_creates_file_manifest_records_w` — `tests/test_checkpoint.py:599`:
   ```
   assert result.returncode == 0
   AssertionError: assert 2 == 0
   stderr: 'handoff-checkpoint: task.file_path: required\n'
   ```
   (fails on the `task` field first, since `task_clear()` now sends
   `{"action": "clear"}` and the unchanged `validate_task` still requires
   `file_path`.)
5. `test_todo_keep_leaves_pre_existing_list_alone` — `tests/test_checkpoint.py:718`:
   ```
   assert result.returncode == 0
   AssertionError: assert 2 == 0
   stderr: 'handoff-checkpoint: task.file_path: required\n'
   ```

## Other red

`pytest tests/test_checkpoint.py -q` → **52 failed, 55 passed** out of 107
collected. Subtracting the slice's own 5 tests: **47 other tests are red** —
the baseline the GREEN dispatch works down to zero. (Every failing payload in
the suite now sends the new tagged-union shape through `task_clear()`/
`todo_keep()`/`task_content()`/`todo_content()`/`todo_edit()`, so any test
whose payload construction touches these factories reds against the
unchanged validator, exactly as expected.)

## Lint

Ran over the two changed files:
- `ruff check tests/test_checkpoint.py pyproject.toml` — All checks passed.
- `ruff format --check tests/test_checkpoint.py` — one reformat needed
  (a parenthesization in the new `test_task_clear_never_existed_writes_nothing_no_d`
  body); applied with `ruff format`, now clean.
- `mypy tests/test_checkpoint.py` — clean (no output, `error_summary = false`).

No `just precommit` run — the suite is red by design; that gate belongs to
this slice's GREEN dispatch.

## Commit

None — per Done criteria, tests and the `pyproject.toml` edit stay
uncommitted; GREEN commits them together with the implementation.
