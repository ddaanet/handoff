# Item 1.1, slice 4 — RED report

## Scope confirmation

`scripts/checkpoint.py` is byte-identical to `HEAD`:

```
$ git diff --stat scripts/checkpoint.py
(empty)
```

Only `tests/test_checkpoint.py` changed:

```
$ git status --porcelain
 M tests/test_checkpoint.py
```

## What changed

The two existing tests were each split into a pre-existing/never-existed pair,
following the shape of `test_task_clear_removes_pre_existing_file_manifest_records_d`
/ `test_task_clear_never_existed_writes_nothing_no_d` already in the file:

- `test_task_write_only_headings_removed_manifest_records_d` (was at :632) →
  - `test_task_write_only_headings_pre_existing_removed_manifest_records_d`
    (pre-creates `.claude/handoff-task.md` with stale content; same assertions
    as the original test — `D` recorded)
  - `test_task_write_only_headings_never_existed_no_d` (no pre-existing file;
    asserts nothing on disk **and** that `handoff-task.md` appears nowhere —
    neither `W` nor `D` — in the manifest text, plus that the manifest file
    itself is present)
- `test_todo_write_no_items_removed_manifest_records_d` (was at :673) → the
  same pair for `.claude/handoff-todo.md`, using a `## Remaining` body with no
  items as the empty-body trigger.

Both never-existed halves assert `"<filename>" not in manifest_text` (broader
than membership-in-splitlines, per the slice 3 review note: the never-existed
case is the one place a broader absence is the stronger claim, since a
substring match would also catch a stray `W` line). The pre-existing halves
keep the exact `"D <path>" in text.splitlines()` form already used elsewhere
in the file.

## Red run

```
$ pytest tests/test_checkpoint.py -k "test_task_write_only_headings or test_todo_write_no_items" -v
```

```
tests/test_checkpoint.py::test_task_write_only_headings_pre_existing_removed_manifest_records_d PASSED [ 25%]
tests/test_checkpoint.py::test_task_write_only_headings_never_existed_no_d FAILED [ 50%]
tests/test_checkpoint.py::test_todo_write_no_items_pre_existing_removed_manifest_records_d PASSED [ 75%]
tests/test_checkpoint.py::test_todo_write_no_items_never_existed_no_d FAILED [100%]

=================================== FAILURES ===================================
_______________ test_task_write_only_headings_never_existed_no_d _______________

tmp_path = PosixPath('/tmp/pytest-of-david/pytest-27/test_task_write_only_headings_1')

    def test_task_write_only_headings_never_existed_no_d(tmp_path: Path) -> None:
        repo = make_repo(tmp_path)
        payload = {
            "skill": "handoff",
            "commit": "with-commit",
            "rename": "T",
            "clear": False,
            "continue": None,
            "task": task_content("## Current task\n\n## Open decisions\n"),
            "todo": todo_keep(),
        }
        result = run_checkpoint(repo, payload)
        assert result.returncode == 0
        assert not (repo / ".claude" / "handoff-task.md").exists()
        assert (repo / ".claude" / "checkpoint-manifest").is_file()
>       assert (
            "handoff-task.md" not in (repo / ".claude" / "checkpoint-manifest").read_text()
        )
E       AssertionError: assert 'handoff-task.md' not in 'D .claude/h...ff-task.md\n'
E         
E         'handoff-task.md' is contained here:
E           D .claude/handoff-task.md

tests/test_checkpoint.py:670: AssertionError
_________________ test_todo_write_no_items_never_existed_no_d __________________

tmp_path = PosixPath('/tmp/pytest-of-david/pytest-27/test_todo_write_no_items_never0')

    def test_todo_write_no_items_never_existed_no_d(tmp_path: Path) -> None:
        repo = make_repo(tmp_path)
        payload = {
            "skill": "handoff",
            "commit": "with-commit",
            "rename": "T",
            "clear": False,
            "continue": None,
            "task": task_clear(),
            "todo": todo_content("## Remaining\n"),
        }
        result = run_checkpoint(repo, payload)
        assert result.returncode == 0
        assert not (repo / ".claude" / "handoff-todo.md").exists()
        assert (repo / ".claude" / "checkpoint-manifest").is_file()
>       assert (
            "handoff-todo.md" not in (repo / ".claude" / "checkpoint-manifest").read_text()
        )
E       AssertionError: assert 'handoff-todo.md' not in 'D .claude/h...ff-todo.md\n'
E         
E         'handoff-todo.md' is contained here:
E           D .claude/handoff-todo.md

tests/test_checkpoint.py:734: AssertionError
=========================== short test summary info ============================
FAILED tests/test_checkpoint.py::test_task_write_only_headings_never_existed_no_d
FAILED tests/test_checkpoint.py::test_todo_write_no_items_never_existed_no_d
================= 2 failed, 2 passed, 120 deselected in 0.78s ==================
```

## Verdict per row

- `test_task_write_only_headings_pre_existing_removed_manifest_records_d` —
  **PASSED**, as expected: this is the unchanged contract (the original
  test's assertions, now against a fixture that actually pre-creates the
  file it claims to be "pre-existing").
- `test_task_write_only_headings_never_existed_no_d` — **FAILED on its
  assertion**: the manifest contains `D .claude/handoff-task.md` for a file
  that never existed on disk, exactly the phantom-`D` defect described in the
  dispatch (`apply_task`'s write route at `scripts/checkpoint.py:350-353`
  unlinks and returns `D` unconditionally, without checking prior existence).
- `test_todo_write_no_items_pre_existing_removed_manifest_records_d` —
  **PASSED**, same reasoning as the task case.
- `test_todo_write_no_items_never_existed_no_d` — **FAILED on its
  assertion**, same phantom-`D` defect in `apply_todo`'s write route
  (`scripts/checkpoint.py:381-383`).

Both failures are failed assertions (`AssertionError` on the manifest-content
check), not missing symbols or unrelated schema rejections — a genuine red.

## Lint on the test file alone

```
$ ruff check tests/test_checkpoint.py
All checks passed!
$ ruff format --check tests/test_checkpoint.py
1 file already formatted
$ mypy tests/test_checkpoint.py
(no output — clean)
```

## Working tree

```
$ git status --porcelain
 M tests/test_checkpoint.py
```

Only the test file changed; no commit made. `just precommit` was not run to
completion (suite is red by design).
