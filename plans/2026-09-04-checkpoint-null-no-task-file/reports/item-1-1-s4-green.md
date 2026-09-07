# Item 1.1, slice 4 — GREEN report

## Implementation

Applied exactly the two-edit shape the slice 1 code review prescribed, to
both `apply_task` and `apply_todo` in `scripts/checkpoint.py`:

- Hoisted `existed = path.is_file()` above the `if action == "clear":` line
  in each function (it was previously sampled only inside that branch).
- Made the write route's empty-body `D` line conditional on `existed`:
  `return [f"D {HANDOFF_REL_TASK}"] if existed else []` (and the `_TODO`
  equivalent).
- In `apply_todo`, the hoist made the `edit` route's own `path.is_file()`
  check redundant; replaced it with the hoisted `existed` rather than leaving
  both stats.

No other lines touched. `git diff scripts/checkpoint.py` is a 10-line diff,
matching the report's prediction.

## Rows made green, one at a time

```
$ pytest tests/test_checkpoint.py -k "test_task_write_only_headings_never_existed_no_d" -v
1 passed

$ pytest tests/test_checkpoint.py -k "test_todo_write_no_items_never_existed_no_d" -v
1 passed
```

Both paired rows (`..._pre_existing_removed_manifest_records_d`) stayed
green throughout — checked as part of the full-file run below.

## Full suite

```
$ pytest tests/test_checkpoint.py -q
124 passed
```

## `just precommit`

Full gate, run to completion:

- `shellcheck -x`, manifest/settings lint, ruff / `ruff format --check` /
  docformatter / mypy / ty over the Python: all clean.
- `bats tests/hook-test.bats tests/checkpoint.bats`: **159 tests, all ok**
  (`1..159`).
- `pytest`: **214 passed, 11 deselected** (the `live`-marker
  `tests/test_tui_conformance.py` rows, correctly excluded from precommit).

No regression elsewhere in the suite — watched the whole run, not just
`test_checkpoint.py`.

## Commit

```
2ee1fbf 🐛 Item 1.1/4 — an empty body still removes, and D still records only a real removal
```

Contains `scripts/checkpoint.py`, `tests/test_checkpoint.py`, and both slice 4
reports (`item-1-1-s4-red.md`, `item-1-1-s4-test-review.md`). Working tree is
clean after the commit (`git status --porcelain` empty); no
`.claude/handoff-task.md` / `.claude/handoff-todo.md` appeared staged this
run, so nothing was left for a hook to have touched.

## Deviations from the dispatch

None. The implementation shape, scope, and done criteria were followed as
specified.
